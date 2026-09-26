defmodule CassWeb.UserLoginLiveTest do
  @moduledoc """
  Tests for the login page.

  The form posts to `CassWeb.UserSessionController.create/2`, so the outcome of
  a successful sign in is covered by the controller test. What matters here is
  that the page posts to the right place, carries the CSRF token of the browser
  form, and offers the two ways in.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "the login page" do
    test "is reachable by guests and renders the form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, "#login-card")
      assert has_element?(view, "#login-form")
      assert html =~ "Sign in"
    end

    test "posts to the session controller with a CSRF token", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(
               view,
               ~s|#login-form[action="/users/log-in"][method="post"] input[name="_csrf_token"]|
             )
    end

    test "renders the email and password inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, ~s|#login-form input[name="user[email]"]|)
      assert has_element?(view, ~s|#login-form input[name="user[password]"]|)
    end

    test "offers a sign in that keeps the session for 14 days", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(
               view,
               ~s|#login-form button[name="user[remember_me]"][value="true"]|,
               "stay signed in"
             )
    end

    test "links to registration and to the password reset request", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(view, ~s|a[href="/users/register"]|)
      assert has_element?(view, ~s|#forgot-password-link[href="/users/reset-password"]|)
    end

    test "sends a signed-in user to their settings", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               conn |> log_in_user(user_fixture()) |> live(~p"/users/log-in")

      assert path == ~p"/users/settings"
    end

    test "pre-fills the email left in the flash by a failed attempt", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session("phoenix_flash", %{"error" => "Invalid email or password"})
        |> put_session("phoenix_flash", %{"email" => "half-remembered@example.com"})

      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(
               view,
               ~s|#login-form input[name="user[email]"][value="half-remembered@example.com"]|
             )
    end
  end

  describe "submitting the form" do
    test "hands the submission to the browser", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      html =
        view
        |> form("#login-form", user: %{email: "someone@example.com", password: "whatever"})
        |> render_submit()

      # A trigger action is what makes the real browser perform the POST; the
      # LiveView itself must not try to navigate.
      assert html =~ "phx-trigger-action"
    end
  end
end
