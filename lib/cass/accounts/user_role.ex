defmodule Cass.Accounts.UserRole do
  @moduledoc """
  A role granted to a CASS account.

  Roles are the *only* authorization input in this phase, and they are stored
  in `cass_user_roles` (a join table, not a column on `cass_users`) so that an
  account can hold several at once. The vocabulary is closed and is owned by
  this module: `:admin` and `:vendor`. There is deliberately no `:customer`
  role — the absence of any role already means "signed-in customer".

  ## The vocabulary is enforced in the database too

  `changeset/2` rejects any role outside `@roles`, and the
  `cass_user_roles_role_check` constraint in the migration rejects the same set
  independently of the application. Adding a role therefore requires a
  migration, exactly like the token contexts in the Phase 1 auth migration, and
  a bad value can never reach a `Scope` by any route — including a crafted
  database write.

  ## Roles are read on every request, never from the client

  `Cass.Accounts.Scope` loads a user's roles from this table server-side each
  time a scope is built, so a grant or revoke takes effect on the next request
  (or LiveView mount) with no session, cookie, or param involvement. See
  `docs/security.md`.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Cass.Accounts.User
  alias Cass.Accounts.UserRole

  @roles [:admin, :vendor]
  @role_strings Map.new(@roles, &{Atom.to_string(&1), &1})

  @typedoc "A role owned by `Cass.Accounts.UserRole`."
  @type role :: :admin | :vendor

  @typedoc """
  A role as it is written: the atom form, or its string form as it arrives from
  a CLI flag, an env var, or a form.
  """
  @type role_input :: role() | String.t()

  schema "cass_user_roles" do
    field :role, :string
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  The complete, closed set of roles, in display order.

  This is the single source of truth for the application vocabulary; the
  database check constraint mirrors it.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Parses user-supplied input into a role atom, or `:error`.

  Only the strings this module already knows are turned into atoms, so a
  hostile value such as `"role\": ~w[rce admin]"}` can never be interned (no
  `String.to_atom/1`, no `String.to_existing_atom/1` on untrusted input).

  ## Examples

      iex> Cass.Accounts.UserRole.parse("admin")
      {:ok, :admin}

      iex> Cass.Accounts.UserRole.parse(" Vendor ")
      {:ok, :vendor}

      iex> Cass.Accounts.UserRole.parse("superuser")
      :error

  """
  @spec parse(term()) :: {:ok, role()} | :error
  def parse(role) when is_binary(role) do
    case Map.fetch(@role_strings, String.trim(role) |> String.downcase()) do
      {:ok, role} -> {:ok, role}
      :error -> :error
    end
  end

  def parse(role) when role in @roles, do: {:ok, role}
  def parse(_role), do: :error

  @doc "Returns true when the given input is one of the known roles."
  @spec valid?(term()) :: boolean()
  def valid?(role) do
    match?({:ok, _role}, parse(role))
  end

  @doc """
  A changeset for granting a role.

  Only `:role` is cast, under either an atom or a string key, and it accepts
  either the atom or the string form of a role. The `user_id` is **never**
  cast: callers set it on the struct they build (see
  `Cass.Accounts.grant_user_role/2`), so a request can never name the account a
  role is written against.
  """
  def changeset(%__MODULE__{} = user_role, attrs) do
    user_role
    |> cast(stringify_role_attr(attrs), [:role])
    |> validate_required([:role, :user_id])
    |> normalize_role()
    |> validate_role()
    |> assoc_constraint(:user)
    |> unique_constraint([:user_id, :role], name: :cass_user_roles_user_id_role_index)
    |> check_constraint(:role, name: :cass_user_roles_role_check)
  end

  @doc """
  A query for the roles of a user, ordered by role name.

  Ordering by the stored string keeps the result stable across processes (and
  matches the order of `roles/0`).
  """
  def query_for_user(%User{id: user_id}) do
    from r in UserRole, where: r.user_id == ^user_id, order_by: [asc: r.role]
  end

  # Ecto will not cast an atom into a string field, so the atom form a role
  # takes in application code (`:admin`) is turned into a string before the
  # cast. Only atoms become strings here; nothing is ever interned from input.
  defp stringify_role_attr(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, role} when key in [:role, "role"] and is_atom(role) and not is_nil(role) ->
        {key, Atom.to_string(role)}

      pair ->
        pair
    end)
  end

  defp stringify_role_attr(attrs), do: attrs

  defp normalize_role(changeset) do
    case get_change(changeset, :role) do
      role when is_binary(role) -> update_change(changeset, :role, &normalize_role_string/1)
      _role -> changeset
    end
  end

  defp normalize_role_string(role), do: role |> String.trim() |> String.downcase()

  defp validate_role(changeset) do
    case get_field(changeset, :role) do
      role when is_binary(role) ->
        case Map.fetch(@role_strings, role) do
          {:ok, role} -> put_change(changeset, :role, Atom.to_string(role))
          :error -> add_error(changeset, :role, "is not a known role")
        end

      _role ->
        changeset
    end
  end
end
