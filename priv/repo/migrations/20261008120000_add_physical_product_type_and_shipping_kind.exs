defmodule Cass.Repo.Migrations.AddPhysicalProductTypeAndShippingKind do
  use Ecto.Migration

  # Extends two closed vocabularies so the marketplace can carry physical goods
  # without a later rewrite:
  #
  #   * `cass_products.product_type` and the two snapshot tables
  #     (`cass_fulfillments.product_type`, `cass_entitlements.product_type`) gain
  #     `physical`, the product type for something that must be shipped;
  #   * `cass_fulfillments.kind` gains `shipping`, the delivery mechanism
  #     `Cass.Fulfillment.kind_for(:physical)` resolves to.
  #
  # The `kind == kind_for(product_type)` relationship stays a domain invariant
  # enforced and tested in `Cass.Fulfillment`, not by the database — exactly as
  # before. A `:shipping` delivery is not automatable (`Cass.Delivery.mechanism_for/1`
  # has no in-app mechanism for a parcel) and, unlike every other kind, reaching
  # `:fulfilled` grants no entitlement: there is nothing in the application for
  # the buyer to exercise once the goods are handed over.
  #
  # CHECK constraints cannot be altered in place, so each is dropped and
  # recreated. `down/0` restores the pre-physical vocabulary; it is safe to run
  # only while no `physical`/`shipping` rows exist, which is the state a rollback
  # of this milestone returns to.

  def up do
    drop constraint(:cass_products, :cass_products_product_type_check)

    create constraint(:cass_products, :cass_products_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service', 'physical')"
           )

    drop constraint(:cass_fulfillments, :cass_fulfillments_kind_check)

    create constraint(:cass_fulfillments, :cass_fulfillments_kind_check,
             check: "kind in ('digital', 'smm', 'ai', 'manual', 'shipping')"
           )

    drop constraint(:cass_fulfillments, :cass_fulfillments_product_type_check)

    create constraint(:cass_fulfillments, :cass_fulfillments_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service', 'physical')"
           )

    drop constraint(:cass_entitlements, :cass_entitlements_product_type_check)

    create constraint(:cass_entitlements, :cass_entitlements_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service', 'physical')"
           )
  end

  def down do
    drop constraint(:cass_products, :cass_products_product_type_check)

    create constraint(:cass_products, :cass_products_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )

    drop constraint(:cass_fulfillments, :cass_fulfillments_kind_check)

    create constraint(:cass_fulfillments, :cass_fulfillments_kind_check,
             check: "kind in ('digital', 'smm', 'ai', 'manual')"
           )

    drop constraint(:cass_fulfillments, :cass_fulfillments_product_type_check)

    create constraint(:cass_fulfillments, :cass_fulfillments_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )

    drop constraint(:cass_entitlements, :cass_entitlements_product_type_check)

    create constraint(:cass_entitlements, :cass_entitlements_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )
  end
end
