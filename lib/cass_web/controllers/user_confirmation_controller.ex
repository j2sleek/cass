defmodule CassWeb.UserConfirmationController do
  @moduledoc """
  Consumes email confirmation links.

  These are plain controller redirects on purpose: a confirmation link is
  followed from an email client, possibly with no JavaScript and no warm
  session, and it must work on the very first request.

  Consuming a link never authenticates anybody. It only stamps
  `confirmed_at` (or applies a pending email change) on the account the token
  was issued for, so a confirmation link that leaks cannot be turned into a
  session.
  """
  use CassWeb, :controller

  alias Cass.Accounts

  @doc "Confirms a newly registered account."
  def show(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Your account is confirmed. You can sign in now.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Confirmation link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Applies a pending email change.

  Requires an authenticated session *and* the token mailed to the new address,
  so both the old and the new mailbox must be under the account holder's
  control.
  """
  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email address changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end
end
