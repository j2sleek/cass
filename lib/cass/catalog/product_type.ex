defmodule Cass.Catalog.ProductType do
  @moduledoc """
  Storefront presentation for the closed product-type vocabulary.

  The vocabulary itself is owned by `Cass.Catalog.Product` (and mirrored by the
  `cass_products_product_type_check` constraint); this module only turns a type
  into the copy the storefront shows, so the product card, the product page, and
  the catalog filters cannot drift apart. `delivery_hint/1` is the buyer-facing
  counterpart of the delivery mechanism `Cass.Fulfillment.kind_for/1` resolves,
  expressed in plain language ("Ships to you" for a physical `:physical` product)
  rather than as an internal delivery kind.
  """

  @labels %{
    digital: "Digital",
    smm: "SMM",
    ai: "AI",
    service: "Service",
    physical: "Physical"
  }

  @delivery_hints %{
    digital: "Instant download",
    smm: "Handled by a specialist",
    ai: "Instant access",
    service: "Handled by a specialist",
    physical: "Ships to you"
  }

  @doc "Returns the short label shown next to a product type."
  def label(type), do: Map.get(@labels, type, "Product")

  @doc "Returns the delivery hint shown to set expectations before purchase."
  def delivery_hint(type), do: Map.get(@delivery_hints, type, "Delivered after purchase")
end
