defmodule Cass.Fulfillment do
  @moduledoc """
  The fulfillment boundary: how a sold product is delivered.

  The Catalog describes **what** is being sold
  (`Cass.Catalog.Product` → `Cass.Catalog.ProductVariant`). Fulfillment
  determines **how** a completed order is delivered. The intended chain is:

      Product → Order → Fulfillment

  with kind determined by the product's type:

    * `:digital` → instant delivery of a file, access, or license
    * `:smm` → automated delivery through a provider API
    * `:ai` → entitlement/credits issued through the Nexus AI Gateway
    * `:service` → manual fulfillment by a human

  No order tables, checkout, payment, or provider integrations exist in this
  milestone. This module only pins down the vocabulary so the boundary stays
  explicit: `kind_for/1` is the single place a product type maps to a
  fulfillment kind, and the future `Cass.Orders`/`Cass.Fulfillment.*`
  implementers will hang off it.
  """
  alias Cass.Catalog.Product

  @kind_by_type %{
    digital: :digital,
    smm: :smm,
    ai: :ai,
    service: :manual
  }

  @doc """
  Returns the fulfillment kind that delivers a product, either from a
  `%Product{}` (via its `product_type`) or directly from a product type atom.

  Unknown or future types fall back to `:manual` so the boundary degrades
  safely instead of raising.
  """
  def kind_for(%Product{} = product) do
    kind_for(product.product_type)
  end

  def kind_for(product_type) when product_type in [:digital, :smm, :ai, :service] do
    Map.fetch!(@kind_by_type, product_type)
  end

  def kind_for(_product_type), do: :manual
end
