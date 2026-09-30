defmodule Cass.Repo.Migrations.CreateFulfillmentsAndEntitlements do
  use Ecto.Migration

  # The post-payment domain: what a paid order must deliver
  # (`cass_fulfillments`) and what the buyer is durably authorized to use
  # (`cass_entitlements`).
  #
  # The chain is strictly one-directional and the foreign keys enforce it:
  #
  #     order → order_item → fulfillment → entitlement
  #
  # `cass_fulfillments` is one row per *purchased line*, not per order: a single
  # order may mix a digital product and a human-performed service, and those
  # need different delivery mechanisms. The unique index on `order_item_id` is
  # therefore the database-level idempotency guard — one purchase can only ever
  # owe one delivery — and it is what makes `create_for_paid_order/1` safe under
  # concurrent invocation (the insert is `ON CONFLICT DO NOTHING`, never a
  # read-then-write).
  #
  # `kind` (`:digital`/`:smm`/`:ai`/`:manual`) is the delivery mechanism and
  # `product_type` (`:digital`/`:smm`/`:ai`/`:service`) is what was bought. Both
  # are closed vocabularies mirrored by CHECK constraints, matching the pattern
  # used for product types, order statuses, and payment statuses. The
  # relationship between them (`kind == kind_for(product_type)`) is a domain
  # invariant, enforced and tested in `Cass.Fulfillment`, not by the database.
  #
  # An entitlement is the buyer's durable authorization, so it snapshots the
  # purchase (`product_name`, `variant_name`, `sku`, `quantity`, `product_type`,
  # `metadata`) instead of re-deriving it from mutable catalog rows later. It is
  # 1:1 with the purchase (`order_item_id`) *and* with the delivery that granted
  # it (`fulfillment_id`): both are unique, so neither repeated fulfillment
  # processing nor a duplicated delivery can grant a second entitlement.
  #
  # As everywhere else in the schema, every foreign key is `on_delete: :restrict`
  # and the order chain is immutable: a purchase, its delivery obligation, and
  # the grant it produced can never be silently destroyed by deleting a catalog
  # row, an order, or an account.

  def up do
    create table(:cass_fulfillments) do
      add :order_id,
          references(:cass_orders, on_delete: :restrict, on_update: :update_all),
          null: false

      add :order_item_id,
          references(:cass_order_items, on_delete: :restrict, on_update: :update_all),
          null: false

      # The buyer the delivery is owed to, copied from the order at creation
      # time. Written programmatically by `Cass.Fulfillment`, never cast from
      # input, exactly like `orders.user_id`.
      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      # Delivery mechanism, from the closed `Cass.Fulfillment` vocabulary.
      add :kind, :string, null: false
      # What was purchased, from the closed product-type vocabulary. Snapshotted
      # so the delivery record stays self-describing if the catalog changes.
      add :product_type, :string, null: false

      add :status, :string, null: false, default: "pending"
      add :failure_reason, :string, size: 500
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_fulfillments, :cass_fulfillments_kind_check,
             check: "kind in ('digital', 'smm', 'ai', 'manual')"
           )

    create constraint(:cass_fulfillments, :cass_fulfillments_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )

    create constraint(:cass_fulfillments, :cass_fulfillments_status_check,
             check: "status in ('pending', 'processing', 'fulfilled', 'failed', 'cancelled')"
           )

    # The idempotency guard: one purchase, one delivery obligation.
    create unique_index(:cass_fulfillments, [:order_item_id])
    create index(:cass_fulfillments, [:order_id])
    create index(:cass_fulfillments, [:user_id])
    create index(:cass_fulfillments, [:status])

    create table(:cass_entitlements) do
      # Provenance: the delivery that granted this authorization.
      add :fulfillment_id,
          references(:cass_fulfillments, on_delete: :restrict, on_update: :update_all),
          null: false

      add :order_id,
          references(:cass_orders, on_delete: :restrict, on_update: :update_all),
          null: false

      add :order_item_id,
          references(:cass_order_items, on_delete: :restrict, on_update: :update_all),
          null: false

      # The buyer the entitlement belongs to — always the order's owner.
      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      # Historical snapshot of the purchase, frozen at grant time. Never
      # re-derived from `cass_products`/`cass_product_variants`, so renaming,
      # re-pricing, or archiving the catalog later cannot rewrite what the buyer
      # bought.
      add :product_type, :string, null: false
      add :product_name, :string, null: false
      add :variant_name, :string, null: false
      add :sku, :string
      add :quantity, :integer, null: false
      add :metadata, :map, null: false, default: %{}

      add :status, :string, null: false, default: "active"
      add :granted_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :revoked_reason, :string, size: 500

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_entitlements, :cass_entitlements_status_check,
             check: "status in ('active', 'revoked', 'expired')"
           )

    create constraint(:cass_entitlements, :cass_entitlements_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )

    create constraint(:cass_entitlements, :cass_entitlements_quantity_check,
             check: "quantity > 0"
           )

    # One entitlement per purchase, and one per delivery: repeated fulfillment
    # processing can never grant the same thing twice.
    create unique_index(:cass_entitlements, [:order_item_id])
    create unique_index(:cass_entitlements, [:fulfillment_id])
    create index(:cass_entitlements, [:order_id])
    create index(:cass_entitlements, [:user_id])
    create index(:cass_entitlements, [:status])
  end

  def down do
    drop table(:cass_entitlements)
    drop table(:cass_fulfillments)
  end
end
