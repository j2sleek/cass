defmodule Cass.Fulfillment.Fulfillment do
  @moduledoc """
  One delivery obligation: something a paid order owes its buyer.

  A fulfillment is the answer to "what still has to happen for this purchase to
  be complete". It is created **only** from a paid order
  (`Cass.Fulfillment.create_for_paid_order/1`) and is deliberately *not* a copy
  of the order: it is one row per purchased line, because a single order may mix
  a digital product (`:digital`), an SMM order (`:smm`), an AI plan (`:ai`),
  and a human-performed service (`:manual`), a shipped parcel (`:shipping`), or
  a mix of all of them in one order.

  ## What it records

    * `kind` — the **delivery mechanism**, from the closed
      `Cass.Fulfillment.kinds/0` vocabulary, derived from the purchased
      product's type by `Cass.Fulfillment.kind_for/1`. It is stored (rather than
      recomputed on every read) so a delivery worker can dispatch on it with a
      single query, and it is snapshotted so a later catalog change cannot
      rewrite how a past purchase must be delivered.
    * `product_type` — what was **bought**, from the catalog's product-type
      vocabulary. `kind` is always `Cass.Fulfillment.kind_for(product_type)`;
      that relationship is a domain invariant enforced at creation and covered
      by tests.
    * `user_id` — the buyer the delivery is owed to, copied from the order. Like
      `orders.user_id` it is written programmatically and is never cast from
      input, so no caller can redirect somebody's delivery.
    * `order_id` / `order_item_id` — the purchase this obligation belongs to, and
      the unique idempotency key: one purchase can only ever owe one delivery.

  ## Lifecycle

  An explicit, small state machine, mirrored by the `status` CHECK constraint:

      pending    → processing | failed | cancelled
      processing → fulfilled | failed | cancelled
      failed     → processing | cancelled        (a failed attempt may be retried)
      fulfilled  → (terminal)
      cancelled  → (terminal)

  Every transition is explicit and reversible-free: `fulfilled` is terminal, so
  a completed delivery can never be walked backwards into a state that would
  hide the entitlement it granted, and `cancelled` is terminal because a
  cancelled delivery is never resumed. `pending → fulfilled` is deliberately
  *not* a legal transition: a delivery is claimed (`processing`) before it is
  reported complete, so an instant digital download still follows the same
  auditable path as a manual service.

  Reaching `:fulfilled` is what grants the buyer's entitlement, inside the same
  transaction as the transition itself (`Cass.Fulfillment.mark_fulfilled/1`), so
  an entitlement can never exist for a delivery that was not established, and a
  delivery can never be reported complete without its grant.

  The provider-facing half of fulfillment (an SMM API call, a license-key
  provider, an AI gateway, a download link) is **not** in this schema or this
  milestone. A future `cass_fulfillment_deliveries`-style table hangs off
  `order_item_id` without changing anything here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Entitlements.Entitlement
  alias Cass.Orders.{Order, OrderItem}

  @kinds [:digital, :smm, :ai, :manual, :shipping]
  @product_types [:digital, :smm, :ai, :service, :physical]
  @statuses [:pending, :processing, :fulfilled, :failed, :cancelled]

  @transitions %{
    pending: [:processing, :failed, :cancelled],
    processing: [:fulfilled, :failed, :cancelled],
    failed: [:processing, :cancelled],
    fulfilled: [],
    cancelled: []
  }

  @doc "Returns the closed vocabulary of delivery kinds."
  def kinds, do: @kinds

  @doc "Returns the closed vocabulary of statuses."
  def statuses, do: @statuses

  @doc "Returns the allowed transitions as a `%{from => [to]}` map."
  def transitions, do: @transitions

  @doc "Returns the statuses `status` may move to (empty when it is terminal)."
  def allowed_transitions(status) when is_map_key(@transitions, status),
    do: Map.fetch!(@transitions, status)

  def allowed_transitions(_status), do: []

  @doc """
  Returns true when `from → to` is an allowed transition.

  ## Examples

      iex> Cass.Fulfillment.Fulfillment.transition_allowed?(:pending, :processing)
      true

      iex> Cass.Fulfillment.Fulfillment.transition_allowed?(:pending, :fulfilled)
      false

  """
  def transition_allowed?(from, to), do: to in allowed_transitions(from)

  schema "cass_fulfillments" do
    field :kind, Ecto.Enum, values: @kinds
    field :product_type, Ecto.Enum, values: @product_types
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :failure_reason, :string
    field :delivered_at, :utc_datetime

    belongs_to :order, Order
    belongs_to :order_item, OrderItem
    belongs_to :user, User

    has_one :entitlement, Entitlement

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(fulfillment, attrs) do
    fulfillment
    |> cast(attrs, [:kind, :product_type, :status, :failure_reason, :delivered_at])
    |> validate_required([:kind, :product_type, :status])
    |> validate_length(:failure_reason, max: 500)
    |> foreign_key_constraint(:order)
    |> foreign_key_constraint(:order_item)
    |> foreign_key_constraint(:user)
    # The database-level idempotency guard: one purchased line, one delivery.
    |> unique_constraint(:order_item_id)
  end
end
