defmodule CassWeb.UserAuth do
  @moduledoc """
  Session authentication for the browser pipeline.

  ## How the current user is resolved

  1. `fetch_current_scope_for_user/2` runs in the `:browser` pipeline for every
     request. It reads the `user_token` from the **signed** session cookie (or
     from the signed "remember me" cookie) and looks it up server-side in
     `cass_users_tokens`. The resolved user is assigned as
     `:current_scope` (`Cass.Accounts.Scope`).
  2. LiveViews get the same scope through the `live_session` hooks
     `:mount_current_scope` (may be a guest) and `:require_authenticated`
     (guests are redirected to the login page).
  3. `require_authenticated_user/2` is the equivalent guard for controllers.

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
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # Renews the session id and erases the whole session to avoid fixation
  # attacks. Any data that must survive log in/log out has to be fetched before
  # and re-applied after clearing the session.
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

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

    * `:mount_current_scope` - assigns `current_scope` based on the session
      token, or `nil` when there is no valid token.
    * `:require_authenticated` - same, but redirects guests to the login page.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
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

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}),
    do: ~p"/users/settings"

  def signed_in_path(%Phoenix.LiveView.Socket{
        assigns: %{current_scope: %Scope{user: %Accounts.User{}}}
      }),
      do: ~p"/users/settings"

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
