defmodule CassWeb.UserAuthTest do
  @moduledoc """
  Tests for `CassWeb.UserAuth`: how the current scope is resolved from the
  signed session, and the guards for pages that need a signed-in user.
  """
  use CassWeb.ConnCase, async: true

  import Ecto.Query

  alias Cass.Accounts
  alias Cass.Accounts.UserToken
  alias Cass.Repo
  alias CassWeb.UserAuth

  @remember_me_cookie "_cass_web_user_remember_me"

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, CassWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: user_fixture(), conn: conn}
  end

  describe "fetch_current_scope_for_user/2" do
    test "assigns a guest scope when there is no session", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])

      assert conn.assigns.current_scope == nil
    end

    test "assigns the user of a valid session token", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.email == user.email
    end

    test "a deleted session token resolves to a guest scope", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      :ok = Accounts.delete_user_session_token(token)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
    end

    test "an unknown session token resolves to a guest scope", %{conn: conn} do
      conn =
        conn
        |> put_session(:user_token, "not-a-token")
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope == nil
    end

    test "resumes a session from the signed remember me cookie", %{conn: conn, user: user} do
      logged_in =
        conn
        |> assign(:current_scope, nil)
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      cookie = logged_in.resp_cookies[@remember_me_cookie]

      resumed_conn =
        conn
        |> put_req_cookie(@remember_me_cookie, cookie.value)
        |> UserAuth.fetch_current_scope_for_user([])

      assert resumed_conn.assigns.current_scope.user.id == user.id
      assert get_session(resumed_conn, :user_token)
      assert get_session(resumed_conn, :user_remember_me) == true
    end

    test "reissues the session token once it is older than a week", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      old_inserted_at =
        DateTime.add(DateTime.utc_now(:second), -8, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      Repo.update_all(
        from(t in UserToken, where: t.token == ^token),
        set: [inserted_at: old_inserted_at]
      )

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      new_token = get_session(conn, :user_token)
      assert new_token
      assert new_token != token
      assert Accounts.get_user_by_session_token(new_token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "keeps a fresh session token", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert get_session(conn, :user_token) == token
    end
  end

  describe "log_in_user/3" do
    test "stores a session token and redirects", %{conn: conn, user: user} do
      conn = conn |> assign(:current_scope, nil) |> UserAuth.log_in_user(user)

      # A guest has no scope yet, so the fallback landing page is the catalog.
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)

      assert get_session(conn, :live_socket_id) ==
               "cass_users_sessions:#{Base.url_encode64(get_session(conn, :user_token))}"
    end

    test "renews the session, dropping anything that was in it", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, nil)
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user)

      refute get_session(conn, :to_be_removed)
      assert get_session(conn, :user_token)
    end

    test "redirects to the stored return path and clears it", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, nil)
        |> put_session(:user_return_to, "/catalog")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == "/catalog"
      refute get_session(conn, :user_return_to)
    end

    test "writes a signed, HttpOnly, SameSite=Lax remember me cookie", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, nil)
        |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      cookie = conn.resp_cookies[@remember_me_cookie]

      assert cookie.max_age == 14 * 24 * 60 * 60
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      assert cookie.value != get_session(conn, :user_token)
    end

    test "does not write a remember me cookie by default", %{conn: conn, user: user} do
      conn = conn |> assign(:current_scope, nil) |> UserAuth.log_in_user(user)
      refute conn.resp_cookies[@remember_me_cookie]
    end

    test "keeps other session data when the same user signs in again", %{conn: conn, user: user} do
      previous_token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, previous_token)
        |> put_session(:to_be_kept, "value")
        |> UserAuth.fetch_current_scope_for_user([])

      conn = UserAuth.log_in_user(conn, user)

      assert get_session(conn, :to_be_kept) == "value"
      assert get_session(conn, :user_token) != previous_token
    end
  end

  describe "log_out_user/1" do
    test "erases the session, deletes the token and drops the cookie", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> assign(:current_scope, nil)
        |> put_session(:user_token, token)
        |> put_session(:to_be_removed, "value")
        |> put_resp_cookie(@remember_me_cookie, "signed-value", max_age: 60)
        |> UserAuth.log_out_user()

      refute get_session(conn, :user_token)
      refute get_session(conn, :to_be_removed)
      refute Accounts.get_user_by_session_token(token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "require_authenticated_user/2" do
    test "redirects a guest to the login page", %{conn: conn} do
      conn =
        conn
        |> assign(:current_scope, nil)
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
    end

    test "stores the current path for a guest", %{conn: conn} do
      conn =
        %{conn | path_info: ["catalog", "products", "some-product"]}
        |> assign(:current_scope, nil)
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert get_session(conn, :user_return_to) == "/catalog/products/some-product"
    end

    test "does not store a return path for a non-GET request", %{conn: conn} do
      conn =
        conn
        |> assign(:current_scope, nil)
        |> fetch_flash()
        |> Map.put(:method, "POST")
        |> UserAuth.require_authenticated_user([])

      refute get_session(conn, :user_return_to)
    end

    test "lets a signed-in user through", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> UserAuth.fetch_current_scope_for_user([])
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "signed_in_path/1" do
    test "points a signed-in conn at the settings page", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> UserAuth.fetch_current_scope_for_user([])

      assert UserAuth.signed_in_path(conn) == ~p"/users/settings"
    end

    test "points a guest at the catalog", %{conn: conn} do
      assert UserAuth.signed_in_path(conn) == ~p"/"
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts on the topic of every revoked token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      other = Accounts.generate_user_session_token(user)

      CassWeb.Endpoint.subscribe(Base.url_encode64(token) |> then(&"cass_users_sessions:#{&1}"))

      UserAuth.disconnect_sessions([
        %UserToken{context: "session", token: token},
        %UserToken{context: "session", token: other}
      ])

      assert_received %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "cass_users_sessions:" <> _
      }
    end
  end
end
