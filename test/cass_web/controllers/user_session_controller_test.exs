defmodule CassWeb.UserSessionControllerTest do
  @moduledoc """
  Tests for creating and destroying browser sessions.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts
  alias Cass.Repo
  alias CassWeb.UserAuth

  @remember_me_cookie "_cass_web_user_remember_me"

  describe "POST /users/log-in" do
    setup do
      %{user: user_fixture()}
    end

    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id)
      assert redirected_to(conn) == ~p"/"

      session_cookie = conn.resp_cookies["_cass_key"]
      assert session_cookie.http_only
      assert session_cookie.same_site == "Lax"
      refute session_cookie.secure
    end

    test "puts no role data in the session cookie", %{conn: conn, user: user} do
      :ok = Accounts.grant_user_role(user, :admin)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      # The admin role is resolved from `cass_user_roles` on every request; the
      # session carries the opaque token, the socket topic derived from it, and
      # the flash, and nothing else — so there is nothing in the cookie to
      # tamper with or replay.
      session = conn.private[:plug_session]

      assert Enum.sort(Map.keys(session)) == ["live_socket_id", "phoenix_flash", "user_token"]
      refute inspect(session) =~ "admin"
      refute inspect(session) =~ to_string(user.id)
    end

    test "ignores role parameters in the log in form", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "role" => "admin",
            "roles" => %{"0" => "admin"},
            "admin" => "true"
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Accounts.list_user_roles(user) == []
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies[@remember_me_cookie]
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"

      conn = conn |> recycle() |> delete(~p"/users/log-out")
      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/catalog/products/some-product")
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/catalog/products/some-product"
      refute get_session(conn, :user_return_to)
    end

    test "does not log in with an unregistered email", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "unknown@example.com", "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
    end

    test "does not log in with a wrong password", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "definitely not the password"}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
    end

    test "answers unknown addresses and wrong passwords identically", %{conn: conn, user: user} do
      unknown =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "unknown@example.com", "password" => "whatever"}
        })

      wrong_password =
        post(build_conn(), ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "whatever"}
        })

      assert Phoenix.Flash.get(unknown.assigns.flash, :error) ==
               Phoenix.Flash.get(wrong_password.assigns.flash, :error)

      assert redirected_to(unknown) == redirected_to(wrong_password)
    end

    test "echoes the submitted email back, truncated to the maximum length", %{conn: conn} do
      long = String.duplicate("a", 500) <> "@example.com"

      conn =
        post(conn, ~p"/users/log-in", %{"user" => %{"email" => long, "password" => "wrong"}})

      assert String.length(Phoenix.Flash.get(conn.assigns.flash, :email)) == 160
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> delete(~p"/users/log-out")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "works for a guest as well", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "revokes the token so the old cookie cannot be replayed", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:user_token, token)
        |> delete(~p"/users/log-out")

      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user_by_session_token(token)
      refute Repo.get_by(Accounts.UserToken, token: token, context: "session")
    end
  end

  describe "protected pages" do
    setup do
      %{user: user_fixture()}
    end

    test "a guest is redirected and the destination is replayed after login", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, ~p"/users/settings")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/users/settings"

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/users/settings"
      assert get_session(conn, :user_return_to) == nil
      assert get_session(conn, :user_token)
    end

    test "a failed login keeps the destination for the next attempt", %{conn: conn} do
      conn =
        conn
        |> get(~p"/users/settings")
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => valid_user_email(), "password" => valid_user_password()}
        })

      # The address above belongs to no account, so the login fails and the
      # destination survives.
      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/users/settings"
      refute get_session(conn, :user_token)
    end

    test "a guest sees the login page", %{conn: conn} do
      conn = get(conn, ~p"/users/log-in")
      assert html_response(conn, 200) =~ "Sign in"
    end
  end

  describe "forgery protection" do
    test "a state changing request without a CSRF token is rejected", %{conn: conn} do
      conn = put_private(conn, :plug_skip_csrf_protection, false)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "someone@example.com", "password" => "whatever"}
        })
      end
    end

    test "the browser form carries a CSRF token", %{conn: conn} do
      assert conn |> get(~p"/users/log-in") |> html_response(200) =~ "_csrf_token"
    end
  end

  describe "the log out form" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "logs the user out when a browser submits it", %{conn: conn} do
      # What the rendered form sends: POST plus the `_method` override and a
      # token. Plug.MethodOverride turns it into the declared DELETE.
      conn =
        post(conn, ~p"/users/log-out", %{
          "_method" => "delete",
          "_csrf_token" => Plug.CSRFProtection.get_csrf_token()
        })

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies["_cass_web_user_remember_me"]
    end
  end

  describe "signed_in_path/1" do
    test "is the settings page for a resolved scope", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> UserAuth.fetch_current_scope_for_user([])

      assert UserAuth.signed_in_path(conn) == ~p"/users/settings"
    end
  end
end
