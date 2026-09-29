defmodule Cass.Orders.OrderItem do
  @moduledoc """
  A single purchased line of an order.

  An order item is a **historical snapshot**: the `product_name`, `variant_name`,
  `sku`, `unit_price_cents`, `currency`, and `metadata` are copied from the
  catalog at checkout time, so later edits to the product or variant (renames,
  re-pricing, archiving) never rewrite what a customer actually bought.

  `product_variant_id` still references the variant that was purchased
  (`on_delete: :restrict` preserves history), and `metadata` snapshots the
  variant's `config` (string-keyed JSONB) so type-specific purchase details
  survive catalog changes.

  The line total is `unit_price_cents * quantity`, always integer cents, and is
  never stored separately; the order's `total_cents` is the server-side sum.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Catalog.ProductVariant
  alias Cass.Orders.Order

  @max_quantity 100_000

  @doc "The largest quantity a single order line may carry."
  def max_quantity, do: @max_quantity

  schema "cass_order_items" do
    field :product_name, :string
    field :variant_name, :string
    field :sku, :string
    field :unit_price_cents, :integer
    field :currency, :string, default: "USD"
    field :quantity, :integer
    field :metadata, :map, default: %{}

    belongs_to :order, Order
    belongs_to :product_variant, ProductVariant

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the line total in integer minor units: `unit_price_cents * quantity`.
  """
  def line_total_cents(%__MODULE__{unit_price_cents: unit, quantity: quantity}) do
    unit * quantity
  end

  @doc false
  def changeset(order_item, attrs) do
    order_item
    |> cast(attrs, [
      :product_name,
      :variant_name,
      :sku,
      :unit_price_cents,
      :currency,
      :quantity,
      :metadata
    ])
    |> validate_required([:product_name, :variant_name, :unit_price_cents, :currency, :quantity])
    |> validate_length(:product_name, min: 1, max: 120)
    |> validate_length(:variant_name, min: 1, max: 120)
    |> validate_length(:sku, max: 60)
    |> validate_number(:unit_price_cents, greater_than_or_equal_to: 0)
    |> validate_number(:quantity, greater_than: 0, less_than_or_equal_to: @max_quantity)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/, message: "must be an ISO 4217 code")
    |> validate_metadata()
    |> assoc_constraint(:order)
    |> assoc_constraint(:product_variant)
  end

  defp validate_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil ->
        changeset

      metadata when is_map(metadata) ->
        if Enum.all?(metadata, fn {key, _value} -> is_binary(key) end) do
          changeset
        else
          add_error(changeset, :metadata, "must use string keys")
        end

      _other ->
        add_error(changeset, :metadata, "must be an object")
    end
  end
end
