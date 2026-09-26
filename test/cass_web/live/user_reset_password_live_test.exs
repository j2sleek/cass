defmodule CassWeb.UserResetPasswordLiveTest do
  @moduledoc """
  Tests for the page that chooses a new password from a reset link.
  """
  use CassWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Cass.Accounts
  alias Cass.Repo

  describe "the reset page" do
    test "renders the form for a valid token", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_reset_password_token(user)

      {:ok, view, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert has_element?(view, "#reset-password-form")
      assert html =~ "Choose a new password"
    end

    test "offers no form for a token that was never issued", %{conn: conn} do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      {:ok, view, html} = live(conn, ~p"/users/reset-password/#{token}")

      refute has_element?(view, "#reset-password-form")
      assert html =~ "invalid or it has expired"
      assert has_element?(view, ~s|a[href="/users/reset-password"]|)
    end

    test "offers no form for an expired token", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_reset_password_token(user)
      expire_reset_token(user)

      {:ok, view, html} = live(conn, ~p"/users/reset-password/#{token}")

      refute has_element?(view, "#reset-password-form")
      assert html =~ "invalid or it has expired"
    end

    test "is not signed in and shows no account information", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_reset_password_token(user)

      {:ok, _view, html} = live(conn, ~p"/users/reset-password/#{token}")

      refute html =~ user.email
    end
  end

  describe "choosing a new password" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_reset_password_token(user)
      %{user: user, token: token}
    end

    test "stores the new password and goes to the login page", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
      new_password = "a brand new passphrase"

      result =
        view
        |> form("#reset-password-form",
          user: %{password: new_password, password_confirmation: new_password}
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = result
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "revokes every session of the account", %{conn: conn, user: user, token: token} do
      session_token = Accounts.generate_user_session_token(user)
      {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
      new_password = "a brand new passphrase"

      view
      |> form("#reset-password-form",
        user: %{password: new_password, password_confirmation: new_password}
      )
      |> render_submit()

      refute Accounts.get_user_by_session_token(session_token)
    end

    test "consumes the token so the link cannot be replayed", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")
      new_password = "a brand new passphrase"

      view
      |> form("#reset-password-form",
        user: %{password: new_password, password_confirmation: new_password}
      )
      |> render_submit()

      refute Accounts.get_user_by_valid_reset_password_token(token)

      {:ok, _view, html} = build_conn() |> live(~p"/users/reset-password/#{token}")
      assert html =~ "invalid or it has expired"
    end

    test "keeps the token usable after a failed attempt", %{conn: conn, user: user, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")

      html =
        view
        |> form("#reset-password-form",
          user: %{password: "short", password_confirmation: "other"}
        )
        |> render_submit()

      assert html =~ "should be at least 12 character(s)"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_valid_reset_password_token(token)
    end

    test "refuses a mismatched confirmation", %{conn: conn, user: user, token: token} do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password/#{token}")

      html =
        view
        |> form("#reset-password-form",
          user: %{password: "a brand new passphrase", password_confirmation: "something else"}
        )
        |> render_submit()

      assert html =~ "does not match password"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  defp expire_reset_token(user) do
    query =
      from(token in Accounts.UserToken,
        where: token.user_id == ^user.id and token.context == "reset_password"
      )

    Repo.update_all(query, set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -30, :day)])
  end
end
