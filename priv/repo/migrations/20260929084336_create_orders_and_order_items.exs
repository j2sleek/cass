defmodule Cass.Repo.Migrations.CreateOrdersAndOrderItems do
  use Ecto.Migration

  # The transactional order foundation: an order is a snapshot of the
  # commercial facts decided at checkout. Order items record the product/variant
  # *names*, SKU, unit price, currency, and quantity as they were at the moment
  # the order was placed, so later catalog edits or archiving never rewrite
  # history. Both orders and order items refuse destructive deletes:
  # `on_delete: :restrict` means an account that has ordered, or a variant that
  # has been purchased, cannot simply be deleted — history stays intact.
  #
  # The order lifecycle is `awaiting_payment → paid → processing → completed`
  # with `cancelled`/`failed` as terminal words, enforced by a CHECK constraint
  # mirrored by the `Cass.Orders.Order` enum.
  #
  # The variant tables also gain CHECK constraints on `stock` and `price_cents`:
  # checkout decrements stock with an atomic conditional `WHERE stock >= qty`
  # update, and these constraints are the database's second line of defence so a
  # successful purchase can never push stock or price below zero.

  def up do
    create table(:cass_orders) do
      # Human-facing order reference (e.g. `C-8K4XQ2M1NR`), server-generated,
      # globally unique. Never a client input.
      add :number, :string, null: false

      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      add :status, :string, null: false, default: "awaiting_payment"
      # Authoritative order total in integer minor units, derived server-side
      # from the order items. Never taken from the client.
      add :total_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "USD"

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_orders, :cass_orders_status_check,
             check:
               "status in ('awaiting_payment', 'paid', 'processing', 'completed', 'cancelled', 'failed')"
           )

    create constraint(:cass_orders, :cass_orders_total_cents_check, check: "total_cents >= 0")

    create unique_index(:cass_orders, [:number])
    create index(:cass_orders, [:user_id])
    create index(:cass_orders, [:status])

    create table(:cass_order_items) do
      add :order_id,
          references(:cass_orders, on_delete: :restrict, on_update: :update_all),
          null: false

      add :product_variant_id,
          references(:cass_product_variants, on_delete: :restrict, on_update: :update_all),
          null: false

      # Commercial snapshots, frozen at checkout time.
      add :product_name, :string, null: false
      add :variant_name, :string, null: false
      add :sku, :string
      add :unit_price_cents, :integer, null: false
      add :currency, :string, null: false, default: "USD"
      add :quantity, :integer, null: false
      # Type-specific purchase metadata captured from the variant config
      # (string keys only), so what was actually purchased survives catalog
      # edits.
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_order_items, :cass_order_items_unit_price_cents_check,
             check: "unit_price_cents >= 0"
           )

    create constraint(:cass_order_items, :cass_order_items_quantity_check, check: "quantity > 0")

    create index(:cass_order_items, [:order_id])
    create index(:cass_order_items, [:product_variant_id])

    # Second line of defence for the checkout stock invariant: a successful
    # purchase can never decrement stock below zero, even against a direct write.
    create constraint(:cass_product_variants, :cass_product_variants_stock_check,
             check: "stock is null or stock >= 0"
           )

    create constraint(:cass_product_variants, :cass_product_variants_price_cents_check,
             check: "price_cents is null or price_cents >= 0"
           )
  end

  def down do
    drop constraint(:cass_product_variants, :cass_product_variants_price_cents_check)
    drop constraint(:cass_product_variants, :cass_product_variants_stock_check)

    drop table(:cass_order_items)
    drop table(:cass_orders)
  end
end
