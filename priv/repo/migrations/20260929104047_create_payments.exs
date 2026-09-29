defmodule Cass.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  # The payment boundary for the marketplace: every payment attempt against a
  # payment provider is recorded as a row in `cass_payments`, owned by the
  # order it pays for. Money is never invented here: `amount_cents` and
  # `currency` are snapshotted from the order's server-derived total at the
  # moment the attempt starts, and the provider is only ever asked to collect
  # exactly that amount.
  #
  # Details that only implementation variants:
  #
  #   * `provider` is a plain string, not a CHECK-constrained vocabulary, so a
  #     future provider can be enabled without a migration. The closed set of
  #     *statuses* is the state machine both this milestone and any future one
  #     enforce at the boundary.
  #   * `provider_reference` is our own reference, generated before the provider
  #     is contacted and passed through to it as the custom reference, so a
  #     webhook, a verify call, and our row always agree on who is being paid.
  #     The partial unique index on `(provider, provider_reference)` is the
  #     database-level idempotency guard: the same provider + reference can only
  #     ever produce one payment.
  #   * `order_id` is a plain index (not unique) because retrying a payment
  #     after a terminal failure creates a *new* attempt for the same order.
  #
  # Order history rules are kept: an order that has any payment attempt cannot
  # be deleted (`on_delete: :restrict`).

  def up do
    create table(:cass_payments) do
      add :order_id,
          references(:cass_orders, on_delete: :restrict, on_update: :update_all),
          null: false

      # The payment provider, e.g. "paystack" (a plain string on purpose).
      add :provider, :string, null: false
      # Our own reference, generated server-side and passed to the provider as
      # its custom reference. nullable only because the schema permits it; the
      # boundary always sets it.
      add :provider_reference, :string

      # Snapshot of the order total in integer minor units, frozen at the
      # moment the attempt starts. Never read from the client.
      add :amount_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "USD"

      add :status, :string, null: false, default: "pending"

      # Where the customer is sent to complete payment (hosted checkout), plus
      # loose bookkeeping that never authorizes anything.
      add :payment_method, :string
      add :checkout_url, :string
      add :failure_reason, :string
      add :paid_at, :utc_datetime
      add :expires_at, :utc_datetime

      # Provider-specific details (access codes, transaction ids, and so on),
      # string-keyed JSONB, never used to make authorization decisions.
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_payments, :cass_payments_status_check,
             check:
               "status in ('pending', 'processing', 'succeeded', 'failed', 'cancelled', 'expired', 'refunded')"
           )

    create constraint(:cass_payments, :cass_payments_amount_cents_check,
             check: "amount_cents >= 0"
           )

    create index(:cass_payments, [:order_id])
    create index(:cass_payments, [:status])

    create unique_index(:cass_payments, [:provider, :provider_reference],
             where: "provider_reference is not null"
           )
  end

  def down do
    drop table(:cass_payments)
  end
end
