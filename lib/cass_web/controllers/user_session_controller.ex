defmodule CassWeb.UserSessionController do
  @moduledoc """
  Creates and destroys browser sessions.

  Log in deliberately answers with a single generic error for both unknown
  addresses and wrong passwords, and does not disclose which one it was.
  """
  use CassWeb, :controller

  alias Cass.Accounts
  alias CassWeb.UserAuth

  def create(conn, %{"user" => user_params}) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether
      # the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, Cass.Accounts.User.email_max_length()))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You have been logged out.")
    |> UserAuth.log_out_user()
  end
end
