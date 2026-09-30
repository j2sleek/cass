defmodule Cass.CommerceFixtures do
  @moduledoc """
  Test helpers for the purchase → payment → fulfillment path.

  These build the real thing rather than stubbing it: a real category, a real
  vendor-owned product, a real published variant, a real checkout, and — where
  a test needs a paid order — a real `Cass.Orders.mark_order_paid/1` transition,
  which is the same call `Cass.Payments` makes after a verified capture. Nothing
  here reaches into the database to fabricate a half-built order, so a test that
  starts from a "paid order" is standing on exactly the state the Payments
  boundary produces.

  The `Cass.AccountsFixtures` helpers are reused for the accounts involved: the
  seller is a vendor, the buyer is an ordinary customer, and roles are granted
  explicitly.
  """

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders
  alias Cass.Repo

  @doc "Returns a fresh, active root category."
  def category_fixture do
    unique = System.unique_integer([:positive])

    {:ok, category} =
      Catalog.create_category(%{name: "Category #{unique}", slug: "category-#{unique}"})

    category
  end

  @doc """
  Returns a published, purchasable `{product, variant}` pair for a vendor seller.

  Options: `:product_type` (default `:digital`), `:price_cents` (default `499`),
  `:config` (default `%{}`), `:stock` (default `100`), `:product_name`, and
  `:sku`.
  """
  def published_variant_fixture(category, opts \\ []) do
    unique = System.unique_integer([:positive])
    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(
        owner,
        category,
        %{
          name: Keyword.get(opts, :product_name, "Product #{unique}"),
          slug: "product-#{unique}",
          product_type: Keyword.get(opts, :product_type, :digital),
          visibility: :public
        }
      )

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "Default",
        sku: Keyword.get(opts, :sku, "SKU-#{unique}"),
        price_cents: Keyword.get(opts, :price_cents, 499),
        currency: "USD",
        stock: Keyword.get(opts, :stock, 100),
        sort_order: 1,
        config: Keyword.get(opts, :config, %{})
      })

    {product, variant}
  end

  @doc """
  Returns an `:awaiting_payment` order for `buyer` buying `quantity` of `variant`.
  """
  def order_fixture(buyer, variant, quantity \\ 1) do
    {:ok, order} =
      Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: quantity}])

    order
  end

  @doc """
  Returns a **paid** order, transitioned through `Cass.Orders.mark_order_paid/1`
  — the boundary call `Cass.Payments` makes once a capture is verified.
  """
  def paid_order_fixture(buyer, variant, quantity \\ 1) do
    order = order_fixture(buyer, variant, quantity)
    {:ok, paid} = Orders.mark_order_paid(order.id)
    Repo.preload(paid, :order_items)
  end

  @doc """
  Returns a **paid** order that mixes several purchased lines, in the given order.

  One line per variant at quantity 1, so a test can assert that every line owes
  its own delivery without depending on prices or stock arithmetic.
  """
  def mixed_paid_order_fixture(buyer, variants) do
    lines = Enum.map(variants, &%{product_variant_id: &1.id, quantity: 1})
    {:ok, order} = Orders.create_order(buyer, lines)
    {:ok, paid} = Orders.mark_order_paid(order.id)
    Repo.preload(paid, :order_items)
  end
end
