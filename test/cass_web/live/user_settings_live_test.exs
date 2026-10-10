defmodule CassWeb.UserSettingsLiveTest do
  @moduledoc """
  Tests for the account settings page.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cass.CommerceFixtures, only: [category_fixture: 0]

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Repo

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "access" do
    test "a guest is sent to the login page", %{conn: _conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/users/settings")
    end

    test "renders the current address and both forms", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "#email-form")
      assert has_element?(view, "#password-form")
      assert has_element?(view, "#log-out-form")
      assert render(view) =~ user.email
    end

    test "the log out form reaches the session controller", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # Both the page and the nav must submit a real DELETE: the router only
      # declares `delete "/users/log-out"`, and the hidden override is what
      # makes the browser's POST arrive as one.
      for form_id <- ["#log-out-form", "#log-out-nav-form"] do
        assert has_element?(
                 view,
                 ~s|#{form_id}[action="/users/log-out"][method="post"] input[name="_csrf_token"]|
               )

        assert has_element?(
                 view,
                 ~s|#{form_id} input[name="_method"][value="delete"]|
               )
      end
    end
  end

  describe "changing the email address" do
    test "asks for a confirmation instead of applying the change", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      new_email = unique_user_email()

      html =
        view
        |> form("#email-form",
          user: %{email: new_email},
          current_password: valid_user_password()
        )
        |> render_submit()

      assert html =~ "A link to confirm your email change has been sent"
      # Not applied yet: the new mailbox has to confirm first.
      assert Repo.get!(Accounts.User, user.id).email == user.email

      token =
        Repo.get_by(Accounts.UserToken, user_id: user.id, context: "change:#{user.email}")

      assert token.sent_to == new_email
    end

    test "refuses a wrong current password and issues no token", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#email-form",
          user: %{email: unique_user_email()},
          current_password: "not the password"
        )
        |> render_submit()

      assert html =~ "is not valid"
      refute Repo.get_by(Accounts.UserToken, user_id: user.id, context: "change:#{user.email}")
    end

    test "refuses an address that is already taken", %{conn: conn} do
      other = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#email-form",
          user: %{email: other.email},
          current_password: valid_user_password()
        )
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end

  describe "changing the password" do
    test "stores the new hash and keeps this session signed in", %{conn: conn, user: user} do
      session_token = get_session(conn, :user_token)
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      new_password = "an entirely different passphrase"

      html =
        view
        |> form("#password-form",
          user: %{password: new_password, password_confirmation: new_password},
          current_password: valid_user_password()
        )
        |> render_submit()

      assert html =~ "Password updated"

      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      assert Accounts.get_user_by_email_and_password(user.email, new_password)

      # The session that made the change survives, so the page stays usable.
      assert Accounts.get_user_by_session_token(session_token)
      assert render(view) =~ user.email
    end

    test "revokes the other sessions of the account", %{conn: conn, user: user} do
      other_session = Accounts.generate_user_session_token(user)
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      new_password = "an entirely different passphrase"

      view
      |> form("#password-form",
        user: %{password: new_password, password_confirmation: new_password},
        current_password: valid_user_password()
      )
      |> render_submit()

      refute Accounts.get_user_by_session_token(other_session)
    end

    test "refuses a wrong current password", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#password-form",
          user: %{
            password: "an entirely different passphrase",
            password_confirmation: "an entirely different passphrase"
          },
          current_password: "not the password"
        )
        |> render_submit()

      assert html =~ "is not valid"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "refuses a mismatched confirmation", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#password-form",
          user: %{
            password: "an entirely different passphrase",
            password_confirmation: "something else entirely"
          },
          current_password: valid_user_password()
        )
        |> render_submit()

      assert html =~ "does not match password"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "sessions" do
    test "lists where the account is signed in and marks this device", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      [session] = Accounts.list_user_sessions(user)
      assert has_element?(view, "#session-#{session.id}")
      assert has_element?(view, "#session-#{session.id}", "This device")
      # The current session cannot be revoked from the list.
      refute has_element?(view, "#revoke-session-#{session.id}")
    end

    test "revokes another session but keeps this one", %{conn: conn, user: user} do
      other_token = Accounts.generate_user_session_token(user)
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      other = Enum.find(Accounts.list_user_sessions(user), &(&1.token == other_token))
      assert has_element?(view, "#revoke-session-#{other.id}")

      view
      |> element("#revoke-session-#{other.id}")
      |> render_click()

      refute Accounts.get_user_by_session_token(other_token)
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token))
      refute has_element?(view, "#session-#{other.id}")
    end

    test "signs out everywhere and returns to the login page", %{conn: conn, user: user} do
      other_token = Accounts.generate_user_session_token(user)
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      result =
        view
        |> element("#sign-out-everywhere")
        |> render_click()

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = result
      assert Accounts.list_user_sessions(user) == []
      refute Accounts.get_user_by_session_token(other_token)
      refute Accounts.get_user_by_session_token(get_session(conn, :user_token))
    end
  end

  describe "deleting the account" do
    test "refuses a confirmation that does not match the address", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#delete-account-form", user: %{confirmation: "not-my-address@example.com"})
        |> render_submit()

      assert html =~ "does not match your account"
      refute Repo.get!(Accounts.User, user.id).deleted_at
    end

    test "deactivates the account on a matching address and returns home", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      result =
        view
        |> form("#delete-account-form", user: %{confirmation: user.email})
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/"}}} = result
      assert Repo.get!(Accounts.User, user.id).deleted_at
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "refuses to delete an account that still owns products", %{conn: conn, user: user} do
      Scope.for_user(user) |> create_owned_product()

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      html =
        view
        |> form("#delete-account-form", user: %{confirmation: user.email})
        |> render_submit()

      assert html =~ "still owns products"
      refute Repo.get!(Accounts.User, user.id).deleted_at
    end
  end

  # Grants `:vendor` to the scope's account and creates one owned product, so
  # account deletion has something to refuse.
  defp create_owned_product(scope) do
    unique = System.unique_integer([:positive])
    :ok = Accounts.grant_user_role(scope.user, :vendor)

    {:ok, _product} =
      Catalog.create_owned_product(Scope.for_user(scope.user), category_fixture(), %{
        name: "Widget #{unique}",
        slug: "widget-#{unique}",
        product_type: :digital,
        visibility: :unlisted
      })
  end
end
