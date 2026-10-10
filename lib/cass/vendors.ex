defmodule Cass.Vendors do
  @moduledoc """
  The Vendors context: seller profiles and the onboarding application that
  creates them.

  This is the account lifecycle counterpart to `Cass.Catalog`'s product
  ownership. `Cass.Catalog` answers *whose* a product is and who may manage it;
  this context answers what a seller is *called* and how an account becomes one.

  ## Applying does not grant anything

  An account applies by submitting a `Cass.Vendors.VendorProfile`
  (`save_profile/2`). Doing so writes a `:pending` profile and nothing else — it
  grants no role and is never shown publicly. An **admin** reviews it through
  `approve_profile/2` or `reject_profile/2`. Approval is the one place that
  grants the `:vendor` role, and it does so by calling
  `Cass.Accounts.grant_user_role/2` with a fixed role for the account the
  profile already belongs to. No request can name a role or a target account, so
  the "no escalation path" rule of `Cass.Accounts` still holds; approval is
  simply a trusted admin action, like the bootstrap task.

  ## The status the owner cannot write

  `save_profile/2` derives the status from the caller's own roles: an account
  that already holds `:vendor` (granted out of band by an operator) has its
  edits stay `:approved`, and everyone else's edits are `:pending`. Editing a
  `:rejected` profile therefore resubmits it. The role, not the form, is what
  approves a seller.

  ## Public identity

  `public_name/1` returns the approved `display_name` for a user, or `nil`. It
  is safe to call on any `Cass.Accounts.User`, preloaded or not: an unloaded or
  absent profile simply yields `nil`, and the storefront falls back to a handle
  derived from the email address (the pre-existing behavior).
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Accounts.User
  alias Cass.Repo
  alias Cass.Vendors.VendorProfile

  @doc "Returns the closed vocabulary of profile statuses."
  defdelegate statuses, to: VendorProfile

  ## Reads

  @doc """
  Returns the signed-in account's profile, or `nil`.

  A guest has no profile, and so does an account that never applied.
  """
  @spec get_profile(Scope.t() | nil) :: VendorProfile.t() | nil
  def get_profile(%Scope{user: %User{} = user}), do: get_profile_for_user(user)
  def get_profile(_scope), do: nil

  @doc "Returns the profile belonging to `user`, or `nil`."
  @spec get_profile_for_user(User.t() | nil) :: VendorProfile.t() | nil
  def get_profile_for_user(%User{id: user_id}), do: Repo.get_by(VendorProfile, user_id: user_id)
  def get_profile_for_user(_user), do: nil

  @doc """
  Lists every profile for review, newest first.

  Admin-only: a non-admin (or guest) scope gets `[]`, so the review surface is
  not reachable by guessing a path or by calling the context directly.
  """
  @spec list_profiles(Scope.t() | nil) :: [VendorProfile.t()]
  def list_profiles(%Scope{} = scope) do
    if Scope.admin?(scope) do
      VendorProfile
      |> order_by([p], desc: p.inserted_at, desc: p.id)
      |> preload(:user)
      |> Repo.all()
    else
      []
    end
  end

  def list_profiles(_scope), do: []

  @doc """
  Fetches a profile by id for review, returning `nil` unless the caller is an
  admin.
  """
  @spec get_reviewable_profile(Scope.t() | nil, term()) :: VendorProfile.t() | nil
  def get_reviewable_profile(%Scope{} = scope, profile_id) do
    if Scope.admin?(scope) do
      case normalize_id(profile_id) do
        nil -> nil
        id -> Repo.get(VendorProfile, id)
      end
    end
  end

  def get_reviewable_profile(_scope, _profile_id), do: nil

  ## Writes

  @doc """
  Returns a changeset for the profile text, for use in a form.

  The status and `user_id` are not cast, so a live form can validate the text
  without ever rendering a writable status.
  """
  @spec change_profile(VendorProfile.t(), map()) :: Ecto.Changeset.t()
  def change_profile(%VendorProfile{} = profile, attrs \\ %{}) do
    VendorProfile.changeset(profile, attrs)
  end

  @doc """
  Creates or updates the signed-in account's profile.

  The `user_id` is taken from the scope and the status is derived from the
  caller's roles (see the module doc); neither is cast, so a submitted `user_id`
  or `status` is ignored. A guest is refused with `{:error, :not_authenticated}`.

  Returns `{:ok, profile}` / `{:error, changeset}` / `{:error, :not_authenticated}`.
  """
  @spec save_profile(Scope.t() | nil, map()) ::
          {:ok, VendorProfile.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_authenticated}
  def save_profile(%Scope{} = scope, attrs) do
    if Scope.authenticated?(scope) do
      profile = get_profile(scope) || %VendorProfile{}

      profile
      |> VendorProfile.changeset(attrs)
      |> Ecto.Changeset.put_change(:user_id, scope.user.id)
      |> Ecto.Changeset.put_change(:status, status_for(scope))
      |> Repo.insert_or_update()
    else
      {:error, :not_authenticated}
    end
  end

  def save_profile(_scope, _attrs), do: {:error, :not_authenticated}

  @doc """
  Approves a profile and grants its account the `:vendor` role.

  Admin-only. The status change and the role grant happen in one transaction, so
  a profile can never be marked approved without the role that lets the account
  act as a seller. Returns `{:ok, profile}` / `{:error, :not_authorized}` /
  `{:error, changeset}`.
  """
  @spec approve_profile(Scope.t() | nil, VendorProfile.t()) ::
          {:ok, VendorProfile.t()} | {:error, :not_authorized} | {:error, Ecto.Changeset.t()}
  def approve_profile(%Scope{} = scope, %VendorProfile{} = profile) do
    if Scope.admin?(scope) do
      Repo.transact(fn ->
        with {:ok, profile} <-
               profile |> VendorProfile.status_changeset(:approved) |> Repo.update(),
             :ok <- Accounts.grant_user_role(Accounts.get_user!(profile.user_id), :vendor) do
          {:ok, profile}
        end
      end)
    else
      {:error, :not_authorized}
    end
  end

  def approve_profile(_scope, _profile), do: {:error, :not_authorized}

  @doc """
  Rejects a profile.

  Admin-only. The seller's text is left untouched (only the status changes), and
  the account may edit the profile to resubmit it. Rejecting does not revoke an
  existing `:vendor` role; revocation is a separate action
  (`Cass.Accounts.revoke_user_role/2`).
  """
  @spec reject_profile(Scope.t() | nil, VendorProfile.t()) ::
          {:ok, VendorProfile.t()} | {:error, :not_authorized} | {:error, Ecto.Changeset.t()}
  def reject_profile(%Scope{} = scope, %VendorProfile{} = profile) do
    if Scope.admin?(scope) do
      profile |> VendorProfile.status_changeset(:rejected) |> Repo.update()
    else
      {:error, :not_authorized}
    end
  end

  def reject_profile(_scope, _profile), do: {:error, :not_authorized}

  ## Public identity

  @doc """
  Returns the approved public display name of `user`, or `nil`.

  Only an `:approved` profile contributes a name, and only a non-empty one. An
  account without a profile, or with a `:pending`/`:rejected` one, returns
  `nil`; the storefront then falls back to the email-derived handle it used
  before profiles existed.
  """
  @spec public_name(User.t() | term()) :: String.t() | nil
  def public_name(%User{vendor_profile: %VendorProfile{status: :approved, display_name: name}})
      when is_binary(name) and name != "" do
    name
  end

  def public_name(_user), do: nil

  ## Internals

  # A form cannot decide its own status: it follows the role the account already
  # holds. A vendor keeps `:approved`; anybody else (a new applicant, a
  # resubmission after rejection, or an account whose role was revoked) is
  # `:pending` until an admin says otherwise.
  defp status_for(%Scope{} = scope) do
    if Scope.vendor?(scope), do: :approved, else: :pending
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _not_a_number -> nil
    end
  end

  defp normalize_id(_id), do: nil
end
