defmodule Cass.Payments.Payment do
  @moduledoc """
  A single payment attempt recorded by `Cass.Payments`.

  A payment belongs to an order and records *one* attempt to collect that
  order's server-derived total. Retrying after a terminal failure creates a
  new attempt, so an order can have many payment rows; `provider_reference` is
  the idempotency key.

  ## Lifecycle

  The status is an explicit state machine, the same CHECK-enforced vocabulary
  the migration declares, and only reached through `Cass.Payments` — never
  written directly and never chosen by a client:

    * `:pending` — attempt created, not yet handed to the provider.
    * `:processing` — handed to the provider, waiting on the customer/hosted checkout.
    * `:succeeded` — the provider reports a confirmed capture and the order was paid.
    * `:failed` — initialization or capture failed (terminal).
    * `:cancelled` — abandoned or cancelled by the customer (terminal).
    * `:expired` — reserved for the future expiry capability.
    * `:refunded` — reserved for the future refund capability.

  `:expired` and `:refunded` are part of the vocabulary today so the database
  schema never needs to change later, but nothing in this milestone writes them.

  Like the order item snapshots, `amount_cents`/`currency` are copied from the
  order at the moment the attempt starts, so a later re-pricing can never make
  a payment diverge from what was actually owed.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Orders.Order

  @statuses [:pending, :processing, :succeeded, :failed, :cancelled, :expired, :refunded]

  @doc "Returns the closed vocabulary of payment statuses."
  def statuses, do: @statuses

  schema "cass_payments" do
    belongs_to :order, Order

    field :provider, :string
    field :provider_reference, :string
    field :amount_cents, :integer, default: 0
    field :currency, :string, default: "USD"
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :payment_method, :string
    field :checkout_url, :string
    field :failure_reason, :string
    field :metadata, :map, default: %{}
    field :paid_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :provider,
      :provider_reference,
      :amount_cents,
      :currency,
      :status,
      :payment_method,
      :checkout_url,
      :failure_reason,
      :metadata,
      :paid_at,
      :expires_at
    ])
    |> validate_required([:provider, :amount_cents, :currency])
    |> validate_length(:provider, min: 1, max: 40)
    |> validate_length(:provider_reference, max: 100)
    |> validate_length(:payment_method, max: 60)
    |> validate_length(:failure_reason, max: 500)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/\A[A-Z]{3}\z/, message: "must be an ISO 4217 code")
    |> validate_metadata()
    |> assoc_constraint(:order)
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
