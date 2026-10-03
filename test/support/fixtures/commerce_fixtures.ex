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
  alias Cass.Entitlements
  alias Cass.Fulfillment
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

  @doc """
  Returns an active entitlement for `buyer`, produced the real way: a paid
  order, the delivery the order owed, and the grant that delivery completed.

  The whole chain is driven through its own contexts — `create_for_paid_order/1`,
  `mark_processing/1`, `mark_fulfilled/1` — so a test that starts from
  "this buyer holds a grant" is standing on exactly the state a live purchase
  produces, with no row fabricated and no status hand-set.

  Returns `%{buyer:, order:, fulfillment:, entitlement:}`. Pass
  `product_type: :smm`/`:ai`/`:service` to exercise a non-exercisable delivery
  kind, or `config:` to put vendor-authored keys into the purchase metadata.
  """
  def granted_entitlement_fixture(buyer, category, opts \\ []) do
    {_product, variant} =
      published_variant_fixture(category,
        product_type: Keyword.get(opts, :product_type, :digital),
        config: Keyword.get(opts, :config, %{})
      )

    order = paid_order_fixture(buyer, variant, Keyword.get(opts, :quantity, 1))
    # One line was bought, so exactly one delivery and one grant exist.
    [fulfillment] = fulfill_order!(order)

    %{
      buyer: buyer,
      order: order,
      fulfillment: fulfillment,
      entitlement: Repo.preload(fulfillment, :entitlement).entitlement
    }
  end

  @doc """
  Drives every line of a paid order through `:fulfilled` and returns the
  deliveries, oldest line first.
  """
  def fulfill_order!(order) do
    {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)

    Enum.map(fulfillments, fn fulfillment ->
      {:ok, claimed} = Fulfillment.mark_processing(fulfillment)
      {:ok, delivered} = Fulfillment.mark_fulfilled(claimed)
      delivered
    end)
  end

  @doc """
  Revokes the grant for a fulfilled delivery through the real boundary call, the
  way a refund or support action would.
  """
  def revoke_fixture(%{fulfillment: fulfillment} = context) do
    entitlement = Repo.preload(fulfillment, :entitlement).entitlement
    {:ok, revoked} = Entitlements.revoke_entitlement(entitlement, "refund issued")
    Map.put(context, :entitlement, revoked)
  end

  @doc """
  Moves a grant's `expires_at` into the past and returns the elapsed entitlement.

  Nothing in this milestone writes the `:expired` status yet, so a test that
  needs "the buyer held this, but the window closed" gets there by moving the
  clock on the row. The status stays `:active` on purpose: that is exactly the
  state `active?/1` is required to reject, so leaving it active tests the
  elapsed check rather than a status check.
  """
  def expire_entitlement_fixture(entitlement) do
    elapsed = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)

    entitlement
    |> Ecto.Changeset.change(expires_at: elapsed)
    |> Repo.update!()
  end
end
