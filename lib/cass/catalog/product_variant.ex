defmodule Cass.Catalog.ProductVariant do
  @moduledoc """
  A purchasable configuration of a product.

  A product is *what* is being sold; a variant is *how* it can be bought. A
  product with a single fixed configuration has exactly one active variant; a
  product with several configurations (a Steam top-up in several denominations,
  a TikTok-followers product in several quantities, an AI plan in several
  durations) has one active variant per configuration.

  All pricing lives here, never on the product: `price_cents` is the integer
  minor-unit price (e.g. `1250` is $12.50) in `currency`, and `stock` is `nil`
  when the configuration has unlimited supply. `config` is a JSONB map holding
  product-type-specific purchasable metadata (SMM quantities/platform, AI
  provider/model/duration, service requirements) — deliberately loose until a
  field provably needs to be queried relationally.

  `active` controls purchasability: only active variants may be bought, and an
  inactive variant is never returned by the purchasable read (`:active` is also
  enforced by the future checkout boundary).

  Variant management follows the same authorization model as products:
  `product_id` is never cast from params (it is resolved to a `%Product{}`
  first, and `owner_id`-style security is inherited from the product's owner),
  and every mutation takes a `Cass.Accounts.Scope` that must be allowed to
  manage the parent product.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Catalog.Product

  schema "cass_product_variants" do
    field :name, :string
    field :sku, :string
    field :price_cents, :integer
    field :currency, :string, default: "USD"
    field :stock, :integer
    field :active, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :config, :map, default: %{}

    belongs_to :product, Product, foreign_key: :product_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns true when the variant may be purchased.

  Currently this is exactly the `active` flag. Once checkout exists it will
  additionally require the owning product to be published, which the public
  query layer already guarantees on its way in.
  """
  def purchasable?(%__MODULE__{} = variant), do: variant.active

  @doc false
  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [
      :name,
      :sku,
      :price_cents,
      :currency,
      :stock,
      :active,
      :sort_order,
      :config
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:sku, max: 60)
    |> validate_length(:currency, max: 3)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/, message: "must be an ISO 4217 code")
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:stock, greater_than_or_equal_to: 0)
    |> validate_number(:sort_order, greater_than_or_equal_to: 0)
    |> validate_config()
    |> unique_constraint(:name, name: :cass_product_variants_product_name_index)
    |> unique_constraint(:sku, name: :cass_product_variants_sku_index)
    |> assoc_constraint(:product)
  end

  # `:map` fields must have string keys for JSONB. A map with non-string keys
  # would silently collide at the database, so reject it early with a readable
  # error instead.
  defp validate_config(changeset) do
    case get_change(changeset, :config) do
      nil ->
        changeset

      config when is_map(config) ->
        if Enum.all?(config, fn {key, _value} -> is_binary(key) end) do
          changeset
        else
          add_error(changeset, :config, "must use string keys")
        end

      _other ->
        add_error(changeset, :config, "must be an object")
    end
  end
end
