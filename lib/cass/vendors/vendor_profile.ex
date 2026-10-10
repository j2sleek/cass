defmodule Cass.Vendors.VendorProfile do
  @moduledoc """
  A seller profile: the public identity an account sells under, and the record
  of its onboarding application.

  A profile is optional — most accounts never have one — and an account has at
  most one (`user_id` is unique). It carries the name buyers see, an optional
  business name, a short bio, and a website, plus a lifecycle status:

    * `:pending` — an application waiting for review. It grants nothing and is
      never shown publicly.
    * `:approved` — a reviewed seller. This is the only status whose
      `display_name` is used as the public seller identity, and approving is
      also what grants the `:vendor` role (see `Cass.Vendors`).
    * `:rejected` — reviewed and declined. The account may edit the profile,
      which puts it back to `:pending` for another look.

  ## The status is not a field the owner may write

  `:status` and `:user_id` are deliberately absent from the cast list in
  `changeset/2`. The owner supplies the profile text through
  `Cass.Vendors.save_profile/2`, and the status is written programmatically
  (derived from the caller's roles, or set by an admin decision), so no form
  parameter can mark a profile approved or claim a different account. The
  database mirrors the closed vocabulary with
  `cass_vendor_profiles_status_check`.

  ## Display name

  `display_name` is the only profile field that reaches the public storefront;
  it is rendered next to a sold product instead of a handle derived from the
  owner's email. It is therefore required, length-bounded, and only read while
  the profile is `:approved`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User

  @statuses [:pending, :approved, :rejected]

  @display_name_min_length 2
  @display_name_max_length 60
  @business_name_max_length 120
  @bio_max_length 500
  @website_max_length 200
  @url_regex ~r/\Ahttps?:\/\//i

  @doc "Returns the closed vocabulary of profile statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  schema "cass_vendor_profiles" do
    field :display_name, :string
    field :business_name, :string
    field :bio, :string
    field :website, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The changeset for the profile text an account submits.

  Only the four human fields are cast, and `:display_name` is required. The
  status is applied by `Cass.Vendors` after this changeset is built, never by
  the caller, and the unique index on `user_id` is surfaced as a normal
  changeset error.
  """
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:display_name, :business_name, :bio, :website])
    |> validate_required([:display_name])
    |> validate_length(:display_name,
      min: @display_name_min_length,
      max: @display_name_max_length
    )
    |> validate_length(:business_name, max: @business_name_max_length)
    |> validate_length(:bio, max: @bio_max_length)
    |> validate_length(:website, max: @website_max_length)
    |> validate_website()
    |> unique_constraint(:user_id, name: :cass_vendor_profiles_user_id_index)
    |> check_constraint(:status, name: :cass_vendor_profiles_status_check)
  end

  @doc """
  The changeset an admin decision applies.

  Only `:status` is changed, so a review can never rewrite the seller's text.
  """
  def status_changeset(profile, status) when status in @statuses do
    profile
    |> change(status: status)
    |> check_constraint(:status, name: :cass_vendor_profiles_status_check)
  end

  @doc "Returns true when this profile is approved for public display."
  def approved?(%__MODULE__{status: :approved}), do: true
  def approved?(%__MODULE__{}), do: false

  # A website is optional; when given it must be an absolute http(s) URL, the
  # same rule `Cass.Catalog.Product` applies to a canonical URL.
  defp validate_website(changeset) do
    case get_change(changeset, :website) do
      nil ->
        changeset

      website when website in ["", nil] ->
        changeset

      website ->
        if Regex.match?(@url_regex, website) and match?({:ok, _uri}, URI.new(website)) do
          changeset
        else
          add_error(changeset, :website, "must be an absolute http(s) URL")
        end
    end
  end
end
