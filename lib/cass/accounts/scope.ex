defmodule Cass.Accounts.Scope do
  @moduledoc """
  The scope of the caller, used throughout the app for authorization and logging.

  `CassWeb.UserAuth` resolves the scope **server-side** on every request (from
  the signed session cookie, and from the `cass_users_tokens` row it points
  at) and assigns it as `:current_scope` on the `Plug.Conn` and on the
  LiveView socket. Nothing in the request — query string, form params, headers,
  or cookie contents — is ever trusted to carry a user identity or role.

  Milestone 3 Phase 1 deliberately keeps the struct to a single field: the
  resolved `user`, or `nil` for guests. Authorization data (roles, vendor or
  admin flags) is **not** part of this phase; it is added in later Milestone 3
  phases as its own concern so it can never be smuggled in through the session.
  """
  alias Cass.Accounts.User

  defstruct user: nil

  @doc """
  Builds a scope for the given user.

  Returns `nil` for `nil`, which is what the browser pipeline assigns to
  guests.
  """
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
