defmodule CassWeb.UserAuth do
  @moduledoc """
  Session authentication for the browser pipeline.

  ## How the current user is resolved

  1. `fetch_current_scope_for_user/2` runs in the `:browser` pipeline for every
     request. It reads the `user_token` from the **signed** session cookie (or
     from the signed "remember me" cookie) and looks it up server-side in
     `cass_users_tokens`. The resolved user **and its roles** are assigned as
     `:current_scope` (`Cass.Accounts.Scope`).
  2. LiveViews get the same scope through the `live_session` hooks
     `:mount_current_scope` (may be a guest) and `:require_authenticated`
     (guests are redirected to the login page).
  3. `require_authenticated_user/2` is the equivalent guard for controllers.

  ## Roles

  `Cass.Accounts.Scope` loads the roles of the resolved user from
  `cass_user_roles` every time a scope is built, so a grant or a revoke applies
  on the next request (or the next LiveView mount) without touching the session.
  The guards below (`require_admin_user/2`, `require_vendor_user/2`,
  `require_vendor_or_admin_user/2`, and the `:require_admin` / `:require_vendor` /
  `:require_vendor_or_admin` LiveView hooks) are the only supported way
  to express a role requirement: they keep the decision in `Scope`, instead of
  spreading `Repo` queries and `user_roles` comparisons through every controller
  and LiveView. `/manage/products` (Milestone 3 Phase 3) is the first user of
  the vendor-or-admin requirement, because owning and managing products is open
  to either role while the storefront is open to neither.

  Nothing about the caller is ever read from the request body, query string, or
  from client-writable state other than the *signed* session cookie, and no
  authorization data is carried in the session: the session holds only an
  opaque, random session token.

  ## Session safety

    * the session is **renewed** (new id, contents cleared) whenever a session
      is created, so a fixated pre-login session id cannot be reused;
    * logging out deletes the session token server-side, clears the whole
      session, drops the remember-me cookie, and disconnects the LiveView
      sockets that were using that token;
    * cookies are `HttpOnly` and `SameSite=Lax` by default, and additionally
      `secure: true` in production (see `config/prod.exs`);
    * CSRF protection stays on through the `:browser` pipeline's
      `protect_from_forgery`, so every state-changing browser form is a
      Phoenix form with a CSRF token.
  """
  use CassWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Cass.Accounts
  alias Cass.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in Cass.Accounts.UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_cass_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax",
    http_only: true,
    secure: Application.compile_env(:cass, :secure_cookies, false)
  ]

  # How old the session token should be before a new one is issued. When a
  # request is made with a session token older than this value, a new session
  # token is created and the session and remember-me cookies are updated with
  # it. Setting this to a value greater than `@max_cookie_age_in_days` disables
  # reissuing completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path or falls back to
  `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> delete_session(:user_return_to)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  The session is cleared, the session token is deleted in the database, the
  remember-me cookie is dropped, and any LiveView connected with the token is
  disconnected.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      CassWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Reissues the session token when it is older than the configured age.

  The scope is rebuilt from the database on every call, so a role granted or
  revoked since the last request is picked up here.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  defp maybe_reissue_user_session_token(conn, user, token, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      # The superseded token is deleted rather than just overwritten in the
      # cookie, so a copy of the old cookie cannot be replayed after the
      # reissue.
      Accounts.delete_user_session_token(token)
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens and
  # storing them safely in the session and cookies. When the session is
  # created, rather than extended, `renew_session/2` clears the session to avoid
  # fixation attacks.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew the session if the user is already logged in, to prevent CSRF
  # errors or data being lost in tabs that are still open.
  defp renew_session(conn, user) do
    if authenticated_as?(conn, user) do
      conn
    else
      # Renews the session id and erases the whole session to avoid fixation
      # attacks. Any data that must survive log in/log out has to be fetched
      # before and re-applied after clearing the session.
      delete_csrf_token()

      conn
      |> configure_session(renew: true)
      |> clear_session()
    end
  end

  # Written as a body rather than a guard because `current_scope` is a
  # `%Scope{}` for every request in the `:browser` pipeline, including guests.
  # Log out passes `nil` here, which is never "already logged in", so the whole
  # session is renewed.
  defp authenticated_as?(conn, %Accounts.User{id: user_id}) do
    match?(%{current_scope: %Scope{user: %Accounts.User{id: ^user_id}}}, conn.assigns)
  end

  defp authenticated_as?(_conn, _user), do: false

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.

  Used after a password change or reset, which revokes every token of the user.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      CassWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "cass_users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating `current_scope` in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - assigns `current_scope` (with the user's roles
      loaded from the database) based on the session token, or a guest scope
      when there is no valid token.
    * `:require_authenticated` - same, but redirects guests to the login page.
    * `:require_admin` - same, but also requires the `:admin` role. A signed-in
      user without the role is redirected away with a "not authorized" message.
    * `:require_vendor` - same, but also requires the `:vendor` role.
    * `:require_vendor_or_admin` - same, but requires the `:vendor` **or** the
      `:admin` role. This is the gate for surfaces that either kind of account
      may use (the product management area); it does not make an admin a vendor,
      it just admits both.

  Role hooks are attached to a `live_session`, so listing one in the router
  applies it to every route in that session:

      live_session :require_admin,
        on_mount: [{CassWeb.UserAuth, :require_admin}] do
        live "/admin", AdminLive
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    authorize(mount_current_scope(socket, session), :authenticated)
  end

  def on_mount(:require_admin, _params, session, socket) do
    authorize(mount_current_scope(socket, session), :admin)
  end

  def on_mount(:require_vendor, _params, session, socket) do
    authorize(mount_current_scope(socket, session), :vendor)
  end

  def on_mount(:require_vendor_or_admin, _params, session, socket) do
    authorize(mount_current_scope(socket, session), :vendor_or_admin)
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _inserted_at} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  defp authorize(socket, requirement) do
    case socket.assigns do
      %{current_scope: scope} ->
        if authorized?(scope, requirement) do
          {:cont, socket}
        else
          {:halt, deny(socket, scope)}
        end
    end
  end

  defp deny(socket, scope) do
    if Scope.authenticated?(scope) do
      socket
      |> Phoenix.LiveView.put_flash(:error, "You are not authorized to access this page.")
      |> Phoenix.LiveView.redirect(to: signed_in_path(socket))
    else
      socket
      |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
      |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")
    end
  end

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: scope}}), do: signed_in_path_for(scope)

  def signed_in_path(%Phoenix.LiveView.Socket{assigns: %{current_scope: scope}}),
    do: signed_in_path_for(scope)

  def signed_in_path(_), do: ~p"/"

  defp signed_in_path_for(%Scope{user: %Accounts.User{}}), do: ~p"/users/settings"
  defp signed_in_path_for(_scope), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    require_role(conn, :authenticated)
  end

  @doc """
  Plug for routes that require the `:admin` role.

  Guests are sent to the login page with the current path remembered for after
  log in; a signed-in user without the role is redirected to their settings
  page with a "not authorized" message.
  """
  def require_admin_user(conn, _opts) do
    require_role(conn, :admin)
  end

  @doc """
  Plug for routes that require the `:vendor` role.

  Guests are sent to the login page with the current path remembered for after
  log in; a signed-in user without the role is redirected to their settings
  page with a "not authorized" message.
  """
  def require_vendor_user(conn, _opts) do
    require_role(conn, :vendor)
  end

  @doc """
  Plug for routes that require the `:vendor` **or** the `:admin` role.

  This is the gate for surfaces both kinds of account may use, such as the
  product management area. Denied callers get exactly the same treatment as
  with the single-role guards: a guest is sent to the login page with the
  destination remembered, and a signed-in account without either role is
  redirected to its settings page with a "not authorized" message.
  """
  def require_vendor_or_admin_user(conn, _opts) do
    require_role(conn, :vendor_or_admin)
  end

  defp require_role(conn, requirement) do
    case conn.assigns do
      %{current_scope: scope} ->
        if authorized?(scope, requirement) do
          conn
        else
          conn
          |> put_flash(:error, denied_message(scope))
          |> maybe_store_return_to(scope)
          |> redirect(to: denied_path(conn, scope))
          |> halt()
        end

      _assigns ->
        raise "expected @current_scope to be assigned, got: #{inspect(conn.assigns)}"
    end
  end

  # The one place that answers "may this caller do this?" for the role guards,
  # so the LiveView hooks and the controller plugs cannot drift apart.
  defp authorized?(scope, :authenticated), do: Scope.authenticated?(scope)

  defp authorized?(scope, :vendor_or_admin),
    do: Scope.admin?(scope) or Scope.vendor?(scope)

  defp authorized?(scope, role), do: Scope.role?(scope, role)

  defp denied_message(scope) do
    if Scope.authenticated?(scope),
      do: "You are not authorized to access this page.",
      else: "You must log in to access this page."
  end

  defp denied_path(conn, scope) do
    if Scope.authenticated?(scope), do: signed_in_path(conn), else: ~p"/users/log-in"
  end

  defp maybe_store_return_to(conn, scope) do
    if Scope.authenticated?(scope) do
      conn
    else
      maybe_store_return_to(conn)
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
