defmodule CassWeb.UserForgotPasswordLiveTest do
  @moduledoc """
  Tests for the password reset request page.

  The page must answer identically whether or not the address is registered.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Cass.Accounts
  alias Cass.Repo

  @neutral "If your email is in our system, you will receive instructions to reset your password shortly."

  describe "the password reset request page" do
    test "is reachable by guests and renders the form", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/users/reset-password")

      assert has_element?(view, "#reset-password-request-form")
      assert html =~ "Reset your password"
    end

    test "renders the email input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/reset-password")

      assert has_element?(view, ~s|#reset-password-request-form input[name="user[email]"]|)
    end
  end

  describe "requesting instructions" do
    test "issues a reset token for a known address", %{conn: conn} do
      user = user_fixture()

      view = submit_reset_request(conn, user.email)

      assert render(view) =~ @neutral
      assert Repo.get_by(Accounts.UserToken, user_id: user.id, context: "reset_password")
    end

    test "issues nothing for an unknown address but answers the same", %{conn: conn} do
      user = user_fixture()
      unknown_address = "nobody@example.com"

      known_card = conn |> submit_reset_request(user.email) |> card_html()
      unknown_card = build_conn() |> submit_reset_request(unknown_address) |> card_html()

      assert known_card == unknown_card
      refute Repo.get_by(Accounts.UserToken, sent_to: unknown_address)
    end

    test "clears the form so the address is not left on screen", %{conn: conn} do
      user = user_fixture()

      html = conn |> submit_reset_request(user.email) |> card_html()

      refute html =~ ~s|value="#{user.email}"|
    end
  end

  # Submits the request form and returns the view so the caller can inspect the
  # page as the browser would show it.
  defp submit_reset_request(conn, email) do
    {:ok, view, _html} = live(conn, ~p"/users/reset-password")

    view
    |> form("#reset-password-request-form", user: %{email: email})
    |> render_submit()

    view
  end

  # Only the card is compared between requests: the surrounding page carries
  # per-mount LiveView tokens that are expected to differ.
  defp card_html(view), do: view |> element("#forgot-password-card") |> render()
end
