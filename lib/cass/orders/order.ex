defmodule Cass.Orders.Order do
  @moduledoc """
  An order placed in the marketplace.

  An order belongs to the account that placed it (`user_id`, never a client
  input) and exists to snapshot the commercial facts of a purchase. Its `total_cents`
  is the server-derived sum of its order item line totals, computed inside the
  `Cass.Orders.create_order/2` transaction — it is never accepted from the client.

  ## Lifecycle

  The order status is an explicit state machine suitable for the upcoming
  Payments and Fulfillment milestones:

    * `:awaiting_payment` — created by checkout, stock reserved, awaiting payment.
    * `:paid` — payment captured.
    * `:processing` — fulfillment in progress.
    * `:completed` — delivered.
    * `:cancelled` — cancelled before delivery (terminal).
    * `:failed` — payment failed (terminal).

  This milestone implements creation (`:awaiting_payment`) and the vocabulary;
  the transitions are consumed by the later Payments milestone.

  The `:number` is a server-generated, globally unique human-facing reference.
  Order history is immutable: nothing here edits or archives an order, and the
  foreign keys use `on_delete: :restrict` so history cannot be silently
  destroyed by deleting an account or a catalog row.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Orders.OrderItem
  alias Cass.Payments.Payment

  @statuses [:awaiting_payment, :paid, :processing, :completed, :cancelled, :failed]

  @doc "Returns the closed vocabulary of order statuses."
  def statuses, do: @statuses

  # An order reaches `:paid` only through `Cass.Payments`, so every status after
  # it is downstream of a proven payment and implies the order was paid. The
  # fulfillment boundary uses this to ask "has this order been paid?" without
  # re-implementing (or second-guessing) the order state machine: a
  # `:processing`/`:completed` order is still a paid order, while
  # `:awaiting_payment`, `:cancelled`, and `:failed` are not.
  @paid_statuses [:paid, :processing, :completed]

  @doc """
  Returns the statuses that can only be reached after the order was paid.

  ## Examples

      iex> Cass.Orders.Order.paid_statuses()
      [:paid, :processing, :completed]

  """
  def paid_statuses, do: @paid_statuses

  schema "cass_orders" do
    field :number, :string
    field :status, Ecto.Enum, values: @statuses, default: :awaiting_payment
    field :total_cents, :integer, default: 0
    field :currency, :string, default: "USD"

    belongs_to :user, User

    has_many :order_items, OrderItem, foreign_key: :order_id
    has_many :payments, Payment, foreign_key: :order_id
    has_many :fulfillments, Cass.Fulfillment.Fulfillment, foreign_key: :order_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns true when the order's status implies payment has been proven.

  ## Examples

      iex> Cass.Orders.Order.paid?(%Cass.Orders.Order{status: :paid})
      true

      iex> Cass.Orders.Order.paid?(%Cass.Orders.Order{status: :awaiting_payment})
      false

  """
  def paid?(%__MODULE__{status: status}), do: status in @paid_statuses
  def paid?(_order), do: false

  @doc false
  def changeset(order, attrs) do
    order
    |> cast(attrs, [:number, :status, :total_cents, :currency])
    |> validate_required([:number, :status, :total_cents, :currency])
    |> validate_length(:number, max: 40)
    |> validate_number(:total_cents, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/, message: "must be an ISO 4217 code")
    |> unique_constraint(:number)
  end
end
