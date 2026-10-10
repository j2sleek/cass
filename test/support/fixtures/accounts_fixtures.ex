defmodule Cass.AccountsFixtures do
  @moduledoc """
  Test helpers for creating accounts.

  Every helper returns a `%Cass.Accounts.User{}`; `valid_user_password/0` is the
  plaintext counterpart used by the authentication tests.

  Accounts are created **without** any role. Roles are a separate grant
  (`role_fixture/2`), mirroring the application: nothing is an admin or a
  vendor until something explicitly makes it one.
  """

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Vendors

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
  Returns a registered user with no roles.

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

  @doc """
  Returns a user holding `role`.

  ## Examples

      iex> admin_fixture()
      %Cass.Accounts.User{}

      iex> user_fixture() |> role_fixture(:vendor) |> Cass.Accounts.list_user_roles()
      [:vendor]

  """
  def role_fixture(user, role) do
    :ok = Accounts.grant_user_role(user, role)
    user
  end

  @doc """
  Returns a new user holding `role`.
  """
  def user_with_role_fixture(role, attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> role_fixture(role)
  end

  @doc "Returns a new admin."
  def admin_fixture(attrs \\ %{}), do: user_with_role_fixture(:admin, attrs)

  @doc "Returns a new vendor."
  def vendor_fixture(attrs \\ %{}), do: user_with_role_fixture(:vendor, attrs)

  @doc "Returns a fresh, unique seller display name."
  def unique_vendor_display_name,
    do: "Vendor #{System.unique_integer([:positive])}"

  @doc """
  Returns a seller profile for `user` (default: a fresh account), created
  through `Cass.Vendors.save_profile/2`.

  Because the fixture goes through the real write path, the status follows the
  account's roles exactly as the application does: a `:vendor` account's profile
  is `:approved`, and everybody else's is `:pending`. Pass profile text such as
  `%{display_name: "Ada's Shop"}` to override the generated name.
  """
  def vendor_profile_fixture(user \\ nil, attrs \\ %{}) do
    user = user || user_fixture()
    scope = Scope.for_user(user)

    attrs = Enum.into(attrs, %{display_name: unique_vendor_display_name()})

    {:ok, profile} = Vendors.save_profile(scope, attrs)
    profile
  end

  @doc """
  Returns an `:approved` profile for `user` (default: a fresh account), driven
  through the real admin approval path so the account also holds `:vendor`.

  The returned profile has its `:user` preloaded.
  """
  def approved_vendor_profile_fixture(user \\ nil, attrs \\ %{}) do
    user = user || user_fixture()
    profile = vendor_profile_fixture(user, attrs)
    admin = admin_fixture()

    {:ok, approved} = Vendors.approve_profile(Scope.for_user(admin), profile)
    Cass.Repo.preload(approved, :user)
  end
end
