defmodule CassWeb.UserConfirmationControllerTest do
  @moduledoc """
  Tests for account confirmation and email change confirmation links.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts
  alias Cass.Repo

  describe "GET /users/confirm/:token" do
    setup do
      %{user: user_fixture()}
    end

    test "confirms the account and does not log the user in", %{conn: conn, user: user} do
      token = Accounts.generate_user_confirmation_token(user)

      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed"
      refute get_session(conn, :user_token)
      assert Repo.get!(Accounts.User, user.id).confirmed_at
    end

    test "the token is single use", %{conn: conn, user: user} do
      token = Accounts.generate_user_confirmation_token(user)

      conn = get(conn, ~p"/users/confirm/#{token}")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirmed"

      conn = build_conn() |> get(~p"/users/confirm/#{token}")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
    end

    test "a token that was never issued is rejected", %{conn: conn} do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
    end

    test "a link only affects the account it was issued for", %{conn: conn, user: user} do
      token = Accounts.generate_user_confirmation_token(user)
      other = user_fixture()

      get(conn, ~p"/users/confirm/#{token}")

      refute Repo.get!(Accounts.User, other.id).confirmed_at
    end
  end

  describe "GET /users/settings/confirm-email/:token" do
    setup do
      user = user_fixture()

      %{conn: log_in_user(build_conn(), user), user: user}
    end

    test "applies the pending email change", %{conn: conn, user: user} do
      new_email = unique_user_email()
      token = Accounts.generate_user_change_email_token(user, new_email)

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "changed successfully"
      assert Repo.get!(Accounts.User, user.id).email == new_email
    end

    test "keeps the session intact", %{conn: conn, user: user} do
      token = Accounts.generate_user_change_email_token(user, unique_user_email())

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert get_session(conn, :user_token)
    end

    test "a token that was never issued is rejected", %{conn: conn} do
      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
    end

    test "a token issued for another account is rejected", %{conn: conn} do
      other = user_fixture()
      token = Accounts.generate_user_change_email_token(other, unique_user_email())

      conn = get(conn, ~p"/users/settings/confirm-email/#{token}")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or it has expired"
    end

    test "a guest is sent to the login page", %{user: user} do
      new_email = unique_user_email()
      token = Accounts.generate_user_change_email_token(user, new_email)

      conn = build_conn() |> get(~p"/users/settings/confirm-email/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) =~ "confirm-email"

      # The pending change is not applied until a signed-in session applies it.
      assert Repo.get!(Accounts.User, user.id).email == user.email
      assert Accounts.get_user_by_email(new_email) == nil
    end
  end
end
