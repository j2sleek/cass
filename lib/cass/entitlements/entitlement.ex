defmodule Cass.Entitlements.Entitlement do
  @moduledoc """
  A buyer's durable authorization to use something they purchased.

  An entitlement is the *result* of a successful purchase, not a step in
  delivering it. Fulfillment answers "how does this get to the buyer?";
  an entitlement answers "is this buyer allowed to use it, and until when?".
  The distinction is what lets a delivery be retried, re-run through a different
  mechanism, or hand off to a human without touching the grant.

  ## Lifecycle

    * `:active` — the grant stands.
    * `:revoked` — withdrawn (support/refund path), with `revoked_at` and
      `revoked_reason` recorded.
    * `:expired` — reserved for the later time-bounded capability; nothing
      writes it in this milestone.

  `:expired` is part of the vocabulary so the schema never has to change when
  duration-based grants (an AI plan valid for 30 days) arrive, mirroring how
  `Cass.Payments.Payment` reserves `:expired`/`:refunded`. The read path is
  already honest about an elapsed `expires_at` before anything writes the
  status: `active?/1` reports `false` for an `:active` entitlement whose
  `expires_at` has passed, so no caller can mistake a lapsed grant for a live
  one.

  ## Historical integrity

  The purchase is **snapshotted**: `product_name`, `variant_name`, `sku`,
  `quantity`, `product_type`, and `metadata` are copied from the immutable order
  item at grant time. Renaming, re-pricing, deactivating, or archiving the
  product afterwards cannot rewrite what this buyer bought, and the row is
  readable years later without joining back into the catalog.

  ## Uniqueness

  An entitlement is 1:1 with a purchase (`order_item_id`, unique) and 1:1 with
  the delivery that granted it (`fulfillment_id`, unique). Repeated fulfillment
  processing therefore cannot grant the same purchase twice, and the database —
  not an application-level read-then-write — is what enforces it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Fulfillment.Fulfillment
  alias Cass.Orders.{Order, OrderItem}

  @statuses [:active, :revoked, :expired]

  @doc "Returns the closed vocabulary of entitlement statuses."
  def statuses, do: @statuses

  schema "cass_entitlements" do
    field :product_type, Ecto.Enum, values: [:digital, :smm, :ai, :service]
    field :product_name, :string
    field :variant_name, :string
    field :sku, :string
    field :quantity, :integer
    field :metadata, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :granted_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revoked_reason, :string

    belongs_to :fulfillment, Fulfillment
    belongs_to :order, Order
    belongs_to :order_item, OrderItem
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns true when this entitlement currently authorizes something.

  An `:active` entitlement whose `expires_at` has already elapsed is not active,
  so a read is correct even before the later expiry capability writes the
  `:expired` status.

  ## Examples

      iex> Cass.Entitlements.Entitlement.active?(%Cass.Entitlements.Entitlement{status: :active})
      true

      iex> Cass.Entitlements.Entitlement.active?(%Cass.Entitlements.Entitlement{status: :revoked})
      false

  """
  def active?(%__MODULE__{status: :active} = entitlement), do: not elapsed?(entitlement)
  def active?(%__MODULE__{}), do: false

  @doc false
  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :product_type,
      :product_name,
      :variant_name,
      :sku,
      :quantity,
      :metadata,
      :status,
      :granted_at,
      :expires_at,
      :revoked_at,
      :revoked_reason
    ])
    |> validate_required([
      :product_type,
      :product_name,
      :variant_name,
      :quantity,
      :status,
      :granted_at
    ])
    |> validate_length(:product_name, min: 1, max: 120)
    |> validate_length(:variant_name, min: 1, max: 120)
    |> validate_length(:sku, max: 60)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_length(:revoked_reason, max: 500)
    |> validate_metadata()
    |> foreign_key_constraint(:fulfillment)
    |> foreign_key_constraint(:order)
    |> foreign_key_constraint(:order_item)
    |> foreign_key_constraint(:user)
    # The idempotency guards: one purchase, one entitlement, granted by one
    # delivery.
    |> unique_constraint(:order_item_id)
    |> unique_constraint(:fulfillment_id)
  end

  defp elapsed?(%__MODULE__{expires_at: nil}), do: false

  defp elapsed?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
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
