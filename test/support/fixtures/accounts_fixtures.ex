defmodule Cass.AccountsFixtures do
  @moduledoc """
  Test helpers for creating accounts.

  Every helper returns a `%Cass.Accounts.User{}`; `valid_user_password/0` is the
  plaintext counterpart used by the authentication tests.
  """

  alias Cass.Accounts

  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"
  def valid_user_email, do: "test@example.com"
  def valid_user_password, do: "correct horse battery staple"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  @doc """
  Returns a registered user.

  ## Examples

      iex> user_fixture()
      %Cass.Accounts.User{}

      iex> user_fixture(%{email: "other@example.com"})
      %Cass.Accounts.User{email: "other@example.com"}

  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  @doc """
  Returns a user with `confirmed_at` set.
  """
  def confirmed_user_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> Cass.Repo.update!()
  end
end
