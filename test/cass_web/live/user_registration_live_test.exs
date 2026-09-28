defmodule CassWeb.UserRegistrationLiveTest do
  @moduledoc """
  Tests for the registration page.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Cass.Accounts
  alias Cass.Repo

  describe "the registration page" do
    test "is reachable by guests and renders the form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/users/register")

      assert has_element?(view, "#registration-card")
      assert has_element?(view, "#registration-form")
      assert html =~ "Create your account"
    end

    test "renders email, password and confirmation inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")

      assert has_element?(view, ~s|#registration-form input[name="user[email]"]|)
      assert has_element?(view, ~s|#registration-form input[name="user[password]"]|)
      assert has_element?(view, ~s|#registration-form input[name="user[password_confirmation]"]|)
    end

    test "sends a signed-in user to their settings", %{conn: conn} do
      user = user_fixture()

      assert {:error, {:redirect, %{to: path}}} =
               conn |> log_in_user(user) |> live(~p"/users/register")

      assert path == ~p"/users/settings"
    end
  end

  describe "the submit button" do
    test "renders the caller-provided type as the sole type attribute" do
      # Regression: the button component used to render a hardcoded
      # `type="button"` followed by the splatted `type="submit"`, and browsers
      # honor the first duplicate attribute, so submit buttons never submitted.
      html =
        render_component(&CassWeb.CoreComponents.button/1, %{
          type: "submit",
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Create account" end}]
        })

      assert Regex.scan(~r/\btype=/, html) |> length() == 1
      assert html =~ ~s(type="submit")
      refute html =~ ~s(type="button")
    end

    test "renders the create-account button as a real submit button on the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/register")

      [button_tag] =
        Regex.scan(~r{<button[^>]*phx-disable-with="Creating account\.\.\."[^>]*>}, html)
        |> List.flatten()

      assert Regex.scan(~r/\btype=/, button_tag) |> length() == 1
      assert button_tag =~ ~s(type="submit")
      refute button_tag =~ ~s(type="button")
    end
  end

  describe "validating the form" do
    test "rejects a short password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")

      html =
        view
        |> form("#registration-form", user: %{email: valid_user_email(), password: "short"})
        |> render_change()

      assert html =~ "should be at least 12 character(s)"
    end

    test "rejects a mismatched confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")

      html =
        view
        |> form("#registration-form",
          user: %{
            email: valid_user_email(),
            password: valid_user_password(),
            password_confirmation: "something else entirely"
          }
        )
        |> render_change()

      assert html =~ "does not match password"
    end

    test "does not create an account while validating", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")
      email = valid_user_email()

      view
      |> form("#registration-form", user: %{email: email, password: "short"})
      |> render_change()

      refute Accounts.get_user_by_email(email)
    end
  end

  describe "registering" do
    test "creates the account, issues a confirmation link and goes to the login page", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      result =
        view
        |> form("#registration-form", user: registration_attributes(email))
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} = result

      user = Accounts.get_user_by_email(email)
      assert user
      refute user.confirmed_at

      token = Repo.get_by(Accounts.UserToken, user_id: user.id, context: "confirm")
      assert token.sent_to == email
    end

    test "stores the password hashed, never in plaintext", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()
      password = valid_user_password()

      view
      |> form("#registration-form", user: registration_attributes(email))
      |> render_submit()

      user = Accounts.get_user_by_email(email)
      stored = Repo.get!(Accounts.User, user.id)

      refute stored.hashed_password == password
      assert stored.hashed_password =~ "pbkdf2"
      assert Accounts.get_user_by_email_and_password(email, password)
    end

    test "does not create a session for the new account", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      view
      |> form("#registration-form", user: registration_attributes(email))
      |> render_submit()

      user = Accounts.get_user_by_email(email)
      refute Repo.get_by(Accounts.UserToken, user_id: user.id, context: "session")
    end

    test "shows an error for an address that is already registered", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/users/register")

      html =
        view
        |> form("#registration-form", user: registration_attributes(user.email))
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end

  # The rendered form submits all of its own inputs, so a successful submission
  # has to carry the confirmation field too.
  defp registration_attributes(email) do
    %{
      email: email,
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    }
  end
end
