defmodule Cass.Accounts.Scope do
  @moduledoc """
  The scope of the caller, used throughout the app for authorization and logging.

  `CassWeb.UserAuth` resolves the scope **server-side** on every request (from
  the signed session cookie, and from the `cass_users_tokens` row it points at)
  and assigns it as `:current_scope` on the `Plug.Conn` and on the LiveView
  socket. Nothing in the request — query string, form params, headers, or cookie
  contents — is ever trusted to carry a user identity or role.

  ## What a scope is

  A scope is a `%Scope{}` with two fields:

    * `:user` — the resolved `Cass.Accounts.User`, or `nil` for a guest. It is
      `nil` for guests too, so there is a single struct to pattern match on
      rather than two shapes (`nil` or a struct) threaded through every
      template and guard. Use `authenticated?/1` to ask whether anybody is
      signed in.
    * `:roles` — a `MapSet` of role atoms (`:admin`, `:vendor`) loaded from
      `cass_user_roles` by `for_user/1`. Empty for guests and for ordinary
      customers; having no role *is* being a customer, which is why there is no
      `:customer` role.

  ## Roles are read fresh on every scope

  `for_user/1` issues its own query for the roles, so a grant or a revoke takes
  effect the next time a scope is built (next HTTP request, or next LiveView
  mount) and never has to wait for a cookie to expire. Nothing about the roles
  is cached in the session, which is what keeps a revoked admin from staying an
  admin in an open tab until the token expires.

  ## Asking questions about a scope

  `authenticated?/1`, `admin?/1`, `vendor?/1`, and `role?/2` all accept `nil`,
  so a caller never has to guard the guest case first:

      if Scope.admin?(@current_scope), do: ...

  Route and LiveView guards are built on the same predicates, so "is this
  allowed" is answered in exactly one place (see `CassWeb.UserAuth`).
  """
  alias Cass.Accounts.User
  alias Cass.Accounts.UserRole

  defstruct user: nil, roles: MapSet.new()

  @typedoc """
  A resolved caller.

  `:user` is `nil` for guests; `:roles` is a `MapSet` of
  `Cass.Accounts.UserRole.role/0` atoms.
  """
  @type t :: %__MODULE__{user: User.t() | nil, roles: MapSet.t(UserRole.role())}

  @doc """
  Builds a scope for the given user, loading their roles from the database.

  `nil` yields a guest scope without touching the database.

  ## Examples

      iex> Cass.Accounts.Scope.for_user(nil)
      %Cass.Accounts.Scope{user: nil, roles: MapSet.new()}

  """
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{} = user) do
    for_user(user, Cass.Accounts.list_user_roles(user))
  end

  def for_user(nil), do: %__MODULE__{}

  @doc "Builds a scope from an already-loaded list or set of role atoms."
  @spec for_user(User.t(), [UserRole.role()] | MapSet.t(UserRole.role())) :: t()
  def for_user(%User{} = user, roles) when is_list(roles) do
    %__MODULE__{user: user, roles: MapSet.new(roles)}
  end

  def for_user(%User{} = user, %MapSet{} = roles) do
    %__MODULE__{user: user, roles: roles}
  end

  @doc """
  Returns true when somebody is signed in.

  ## Examples

      iex> Cass.Accounts.Scope.authenticated?(%Cass.Accounts.Scope{})
      false

  """
  @spec authenticated?(t() | nil) :: boolean()
  def authenticated?(%__MODULE__{user: %User{}}), do: true
  def authenticated?(_scope), do: false

  @doc """
  Returns true when the caller holds the `:admin` role.

  Guests are never admins.
  """
  @spec admin?(t() | nil) :: boolean()
  def admin?(%__MODULE__{roles: roles}), do: MapSet.member?(roles, :admin)
  def admin?(_scope), do: false

  @doc """
  Returns true when the caller holds the `:vendor` role.

  An admin is not implicitly a vendor: a vendor account is a seller, and that
  is a separate grant.
  """
  @spec vendor?(t() | nil) :: boolean()
  def vendor?(%__MODULE__{roles: roles}), do: MapSet.member?(roles, :vendor)
  def vendor?(_scope), do: false

  @doc """
  Returns true when the caller holds the given role.

  ## Examples

      iex> Cass.Accounts.Scope.role?(%Cass.Accounts.Scope{}, :admin)
      false

  """
  @spec role?(t() | nil, UserRole.role()) :: boolean()
  def role?(%__MODULE__{roles: roles}, role) when is_atom(role) do
    MapSet.member?(roles, role)
  end

  def role?(_scope, _role), do: false
end
