defmodule Cass.Catalog.Product do
  @moduledoc """
  An item offered in the marketplace catalog.

  Everything sold on CASS is a Product. A product always belongs to a category
  and represents one of five product types: `digital`, `smm`, `ai`, `service`,
  or `physical`. The type does not change the fundamental shape of a product; it
  selects validation, presentation, purchasing configuration (through
  `Cass.Catalog.ProductVariant`), and fulfillment behavior
  (`Cass.Fulfillment`).

  Lifecycle (`status`):

    * `:draft` — can be edited freely; never served publicly.
    * `:published` — served publicly when `visibility` is `:public` or
      `:unlisted` and `published_at` has been reached. The slug is frozen.
    * `:archived` — excluded from all public queries and immutable.

  Visibility:

    * `:public` — discoverable in listings and directly accessible.
    * `:unlisted` — accessible by direct slug but excluded from listings and
      marked `noindex` on the public page.
    * `:private` — never accessible through any public route.

  Ownership:

    * `owner_id == nil` — a **platform-owned** product: the platform's own
      catalog, created by a trusted server path (seeds, operator tasks) and
      manageable only by an admin.
    * `owner_id == <user id>` — the product belongs to that account, which may
      manage it along with admins.

  Ownership is independent of `product_type`: any of the five product types
  may be platform-owned or owned by a user. It is also independent of
  `Cass.Accounts` roles: `:vendor` and `:admin` grant the *capability* to own
  and manage, while `owner_id` records *whose* product it is. A plain customer
  can never become an owner, so ownership never leaks into the public catalog.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Catalog.{Category, ProductVariant}

  schema "cass_products" do
    field :name, :string
    field :slug, :string
    field :product_type, Ecto.Enum, values: [:digital, :smm, :ai, :service, :physical]
    field :status, Ecto.Enum, values: [:draft, :published, :archived], default: :draft
    field :visibility, Ecto.Enum, values: [:public, :unlisted, :private], default: :private
    field :featured, :boolean, default: false
    field :short_description, :string
    field :description, :string
    field :seo_title, :string
    field :seo_description, :string
    field :canonical_url, :string
    field :published_at, :utc_datetime

    belongs_to :category, Category, foreign_key: :category_id

    # `owner_id` is a plain nullable field, so a product with no owner — a
    # platform-owned product — is valid rather than incomplete; nothing in the
    # changesets marks it required. The association is only populated by
    # `Cass.Catalog` (owner-scoped management reads), and `owner_id` is never
    # part of the cast list, so no request can name the account a product
    # belongs to.
    belongs_to :owner, User

    has_many :variants, ProductVariant, foreign_key: :product_id
    has_many :active_variants, ProductVariant, foreign_key: :product_id

    timestamps(type: :utc_datetime)
  end

  @slug_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc """
  Returns true when the product has no owner, i.e. it belongs to the platform.
  """
  def platform_owned?(%__MODULE__{owner_id: nil}), do: true
  def platform_owned?(%__MODULE__{}), do: false

  @doc """
  Builds the changeset for creating a product.

  `owner_id` is deliberately absent from the cast list, alongside `category_id`,
  `status`, and `published_at`: it is set programmatically by
  `Cass.Catalog.create_product/2` (as `nil`, for a platform-owned product) or by
  `Cass.Catalog.create_owned_product/3` (from the authenticated scope's user).
  Passing `owner_id` in `attrs` therefore has no effect.
  """
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :slug,
      :product_type,
      :visibility,
      :featured,
      :short_description,
      :description,
      :seo_title,
      :seo_description,
      :canonical_url
    ])
    |> validate_required([:name, :slug, :product_type])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:slug, min: 2, max: 120)
    |> validate_format(:slug, @slug_regex,
      message: "must be lowercase letters, numbers, and single hyphens"
    )
    |> validate_length(:short_description, max: 200)
    |> validate_length(:description, max: 4000)
    |> validate_canonical_url()
    |> unique_constraint(:slug)
    |> assoc_constraint(:owner)
  end

  @doc false
  def update_changeset(product, attrs) do
    product
    |> changeset(attrs)
    |> validate_modifiable(product)
    |> validate_slug_immutable(product)
  end

  defp validate_canonical_url(changeset) do
    case get_change(changeset, :canonical_url) do
      nil ->
        changeset

      url ->
        if Regex.match?(~r/\Ahttps?:\/\//i, url) and match?({:ok, _}, URI.new(url)) do
          changeset
        else
          add_error(changeset, :canonical_url, "must be an absolute http(s) URL")
        end
    end
  end

  defp validate_modifiable(changeset, %{status: :archived}) do
    add_error(changeset, :base, "archived products cannot be modified")
  end

  defp validate_modifiable(changeset, %{status: _}), do: changeset

  defp validate_slug_immutable(changeset, %{status: status})
       when status in [:published, :archived] do
    if get_change(changeset, :slug) do
      add_error(changeset, :slug, "cannot be changed once the product is published")
    else
      changeset
    end
  end

  defp validate_slug_immutable(changeset, %{status: _}), do: changeset
end
