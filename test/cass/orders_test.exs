defmodule Cass.OrdersTest do
  @moduledoc """
  The checkout boundary: what may be purchased, what is snapshotted, who is
  allowed to read it, and how every money/stock value stays server-derived.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders
  alias Cass.Orders.{Order, OrderItem}

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    %{category: category}
  end

  defp scope_for(:admin), do: Scope.for_user(admin_fixture())
  defp scope_for(:vendor), do: Scope.for_user(vendor_fixture())
  defp scope_for(:customer), do: Scope.for_user(user_fixture())
  defp scope_for(:guest), do: Scope.for_user(nil)

  defp product_attrs do
    %{name: "TikTok Followers", slug: "tiktok-followers", product_type: :smm, visibility: :public}
  end

  defp owned_product!(scope, category, overrides \\ %{}) do
    {:ok, product} =
      Catalog.create_owned_product(scope, category, Map.merge(product_attrs(), overrides))

    {:ok, product} = Catalog.publish_product(scope, product)
    product
  end

  defp variant_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "1,000",
        sku: "TIK-#{System.unique_integer([:positive])}",
        price_cents: 499,
        currency: "USD",
        stock: 100,
        sort_order: 1,
        config: %{"platform" => "tiktok", "target_type" => "followers"}
      },
      overrides
    )
  end

  defp checkout_product!(category) do
    owner = scope_for(:vendor)
    product = owned_product!(owner, category)
    {:ok, variant} = Catalog.create_variant(owner, product, variant_attrs())
    %{owner: owner, product: product, variant: variant}
  end

  describe "placing an order (checkout)" do
    test "creates an awaiting_payment order snapshotting exactly what was bought",
         %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      assert {:ok, order} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 2}])

      assert order.user_id == buyer.user.id
      assert order.status == :awaiting_payment
      assert order.currency == "USD"
      assert order.total_cents == 499 * 2
      assert order.number =~ ~r/\AC-[A-Z2-7]{10}\z/

      assert [item] = order.order_items
      assert item.product_name == "TikTok Followers"
      assert item.variant_name == "1,000"
      assert item.sku == variant.sku
      assert item.unit_price_cents == 499
      assert item.currency == "USD"
      assert item.quantity == 2
      assert item.metadata == %{"platform" => "tiktok", "target_type" => "followers"}
      assert item.product_variant_id == variant.id
      assert OrderItem.line_total_cents(item) == 998
    end

    test "the stored total always equals the server-computed line total",
         %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 3}])

      assert order.total_cents == 499 * 3
      assert Orders.order_total_cents(order) == order.total_cents
    end

    test "repeated variant ids are combined into a single line", %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      {:ok, order} =
        Orders.create_order(buyer, [
          %{product_variant_id: variant.id, quantity: 2},
          %{product_variant_id: variant.id, quantity: 3}
        ])

      assert [item] = order.order_items
      assert item.quantity == 5
      assert order.total_cents == 499 * 5
    end

    test "a multi-variant order aggregates every line and refuses mixed currencies",
         %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product, variant: first} = checkout_product!(category)

      {:ok, second} = Catalog.create_variant(owner, product, variant_attrs(%{name: "10,000"}))

      {:ok, eur} =
        Catalog.create_variant(
          owner,
          product,
          variant_attrs(%{name: "EUR Tier", price_cents: 1000, currency: "EUR"})
        )

      # Same-currency lines are fine and total server-side.
      {:ok, order} =
        Orders.create_order(buyer, [
          %{product_variant_id: first.id, quantity: 1},
          %{product_variant_id: second.id, quantity: 2}
        ])

      assert order.total_cents == 499 + 499 * 2
      assert order.currency == "USD"
      assert Enum.map(order.order_items, & &1.variant_name) |> Enum.sort() == ["1,000", "10,000"]

      # A single-currency order is the only kind: USD + EUR is refused wholesale.
      assert {:error, changeset} =
               Orders.create_order(buyer, [
                 %{product_variant_id: first.id, quantity: 1},
                 %{product_variant_id: eur.id, quantity: 1}
               ])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base
    end

    test "a customer buys without needing any vendor role", %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      assert {:ok, order} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      assert order.user_id == buyer.user.id
    end

    test "a refusal for malformed requests is the same generic error", %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      for bad_request <- [
            [],
            [%{}],
            [%{product_variant_id: variant.id}],
            [%{quantity: 1}],
            [%{product_variant_id: variant.id, quantity: 0}],
            [%{product_variant_id: variant.id, quantity: -1}],
            [%{product_variant_id: variant.id, quantity: "abc"}],
            [%{product_variant_id: variant.id, quantity: 100_001}],
            [%{product_variant_id: "not-a-number", quantity: 1}],
            "not a list"
          ] do
        assert {:error, changeset} = Orders.create_order(buyer, bad_request)
        assert "the order request is invalid" in errors_on(changeset).base
      end
    end

    test "guest checkout is refused without leaking why", %{category: category} do
      %{variant: variant} = checkout_product!(category)

      assert {:error, changeset} =
               Orders.create_order(scope_for(:guest), [
                 %{product_variant_id: variant.id, quantity: 1}
               ])

      assert "you must be signed in to place an order" in errors_on(changeset).base
    end
  end

  describe "eligibility for purchase" do
    test "an inactive or unknown variant is that same unavailable refusal",
         %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product} = checkout_product!(category)
      {:ok, variant} = Catalog.create_variant(owner, product, variant_attrs(%{name: "Retired"}))
      {:ok, _variant} = Catalog.update_variant(owner, variant, %{active: false})

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: 987_654_321, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base
    end

    test "a draft product and an archived product are refused", %{category: category} do
      buyer = scope_for(:customer)
      vendor = scope_for(:vendor)

      {:ok, draft_product} =
        Catalog.create_owned_product(
          vendor,
          category,
          Map.put(product_attrs(), :slug, "draft-followers")
        )

      {:ok, draft_variant} = Catalog.create_variant(vendor, draft_product, variant_attrs())
      assert draft_product.status == :draft

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: draft_variant.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base

      %{owner: owner, product: product, variant: variant} = checkout_product!(category)
      {:ok, _} = Catalog.archive_product(owner, product)

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base
    end

    test "a published but private product cannot be purchased; an unlisted one can",
         %{category: category} do
      buyer = scope_for(:customer)
      vendor = scope_for(:vendor)

      {:ok, private_product} =
        Catalog.create_owned_product(
          vendor,
          category,
          Map.merge(product_attrs(), %{slug: "private-followers", visibility: :private})
        )

      {:ok, _} = Catalog.publish_product(vendor, private_product)
      {:ok, private_variant} = Catalog.create_variant(vendor, private_product, variant_attrs())

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: private_variant.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base

      {:ok, unlisted_product} =
        Catalog.create_owned_product(
          vendor,
          category,
          Map.merge(product_attrs(), %{slug: "unlisted-followers", visibility: :unlisted})
        )

      {:ok, _} = Catalog.publish_product(vendor, unlisted_product)
      {:ok, unlisted_variant} = Catalog.create_variant(vendor, unlisted_product, variant_attrs())

      assert {:ok, %Order{}} =
               Orders.create_order(buyer, [
                 %{product_variant_id: unlisted_variant.id, quantity: 1}
               ])
    end

    test "a product in an archived category is refused", %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)
      {:ok, _archived} = Catalog.archive_category(category)

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base
    end

    test "an unpriced variant cannot be purchased", %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product} = checkout_product!(category)

      {:ok, free} =
        Catalog.create_variant(owner, product, variant_attrs(%{name: "Free", price_cents: nil}))

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: free.id, quantity: 1}])

      assert "an item in the order is not available for purchase" in errors_on(changeset).base
    end
  end

  describe "stock" do
    test "a successful purchase decrements finite stock exactly once", %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, variant: variant} = checkout_product!(category)
      {:ok, variant} = Catalog.update_variant(owner, variant, %{stock: 6})

      assert {:ok, _order} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 2}])

      assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 4
    end

    test "an unlimited variant needs no stock to buy", %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product} = checkout_product!(category)

      {:ok, unlimited} =
        Catalog.create_variant(owner, product, variant_attrs(%{name: "Unlimited", stock: nil}))

      assert {:ok, _order} =
               Orders.create_order(buyer, [%{product_variant_id: unlimited.id, quantity: 5}])

      assert is_nil(Cass.Repo.get!(Catalog.ProductVariant, unlimited.id).stock)
    end

    test "insufficient stock refuses and leaves the order and stock untouched",
         %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, variant: variant} = checkout_product!(category)
      {:ok, variant} = Catalog.update_variant(owner, variant, %{stock: 5})

      assert {:error, changeset} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 6}])

      assert "an item in the order is out of stock" in errors_on(changeset).base
      assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 5
      assert Orders.list_orders(buyer) == []
    end

    test "exactly-on-available stock succeeds and leaves zero behind", %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, variant: variant} = checkout_product!(category)
      {:ok, variant} = Catalog.update_variant(owner, variant, %{stock: 3})

      assert {:ok, _order} =
               Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 3}])

      assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 0
    end

    test "a failure on one line rolls the whole order and every reservation back",
         %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product, variant: available} = checkout_product!(category)
      {:ok, scarce} = Catalog.create_variant(owner, product, variant_attrs(%{name: "Scarce"}))
      {:ok, scarce} = Catalog.update_variant(owner, scarce, %{stock: 1})

      assert {:error, changeset} =
               Orders.create_order(buyer, [
                 %{product_variant_id: available.id, quantity: 1},
                 %{product_variant_id: scarce.id, quantity: 2}
               ])

      assert "an item in the order is out of stock" in errors_on(changeset).base
      # The valid first line must not have kept its reservation: no items, no order.
      assert Cass.Repo.get!(Catalog.ProductVariant, available.id).stock == 100
      assert Cass.Repo.get!(Catalog.ProductVariant, scarce.id).stock == 1
      assert Orders.list_orders(buyer) == []
    end
  end

  describe "snapshot stability" do
    test "later catalog edits never rewrite what was purchased", %{category: category} do
      buyer = scope_for(:customer)
      %{owner: owner, product: product, variant: variant} = checkout_product!(category)

      {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 2}])
      [item] = order.order_items

      original = %{
        name: item.product_name,
        variant: item.variant_name,
        sku: item.sku,
        price: item.unit_price_cents
      }

      {:ok, _} = Catalog.update_product(owner, product, %{name: "Renamed Later"})

      {:ok, _} =
        Catalog.update_variant(owner, variant, %{name: "Recounted", price_cents: 999_99, stock: 0})

      assert order = Orders.get_order(buyer, order.id)
      [item] = order.order_items

      assert item.product_name == original.name
      assert item.variant_name == original.variant
      assert item.sku == original.sku
      assert item.unit_price_cents == original.price
      assert order.total_cents == original.price * 2
    end
  end

  describe "authorized reading" do
    setup %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)
      {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])
      %{buyer: buyer, order: order}
    end

    test "the buyer sees the order; a stranger and a guest see nothing",
         %{buyer: buyer, order: order} do
      stranger = scope_for(:customer)

      assert [listed] = Orders.list_orders(buyer)
      assert listed.id == order.id

      assert Orders.list_orders(stranger) == []
      assert Orders.get_order(stranger, order.id) == nil

      assert Orders.list_orders(scope_for(:guest)) == []
      assert Orders.get_order(scope_for(:guest), order.id) == nil
    end

    test "an admin sees every order including the buyer's", %{buyer: buyer, order: order} do
      admin = scope_for(:admin)

      assert Enum.map(Orders.list_orders(admin), & &1.id) |> Enum.member?(order.id)
      assert Orders.get_order(admin, order.id).id == order.id

      # The admin still cannot read the buyer's session; the order row is enough.
      assert Orders.get_order(admin, order.id).user_id == buyer.user.id
    end

    test "an unknown or malformed id is nil, the same as a foreign order",
         %{buyer: buyer, order: order} do
      assert Orders.get_order(buyer, 987_654_321) == nil
      assert Orders.get_order(buyer, "987654321") == nil
      assert Orders.get_order(buyer, "maybe-a-slug") == nil
      assert Orders.get_order(buyer, nil) == nil
      assert Orders.get_order(nil, order.id) == nil
    end

    test "get_order accepts numeric strings", %{buyer: buyer, order: order} do
      assert Orders.get_order(buyer, Integer.to_string(order.id)).id == order.id
    end
  end

  describe "tamper resistance and money authority" do
    test "a client-supplied price, total, currency, or ownership is ignored",
         %{category: category} do
      buyer = scope_for(:customer)
      other = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)

      {:ok, order} =
        Orders.create_order(buyer, [
          %{
            product_variant_id: variant.id,
            quantity: "2",
            price_cents: "1",
            total_cents: "1",
            currency: "EUR",
            user_id: other.user.id,
            product_name: "Fake",
            variant_name: "Fake"
          }
        ])

      assert order.user_id == buyer.user.id
      assert order.currency == "USD"

      [item] = order.order_items
      assert item.unit_price_cents == 499
      assert item.currency == "USD"
      assert item.product_name == "TikTok Followers"
      assert order.total_cents == 499 * 2
    end

    test "the changesets refuse negative money and impossible quantities" do
      assert {:error, cs} =
               Cass.Repo.insert(
                 Order.changeset(%Order{}, %{
                   number: "C-X",
                   status: :awaiting_payment,
                   total_cents: -1,
                   currency: "USD"
                 })
               )

      assert "must be greater than or equal to 0" in errors_on(cs).total_cents

      assert {:error, cs} =
               Cass.Repo.insert(
                 OrderItem.changeset(%OrderItem{}, %{
                   product_name: "P",
                   variant_name: "V",
                   unit_price_cents: -5,
                   currency: "USD",
                   quantity: 0,
                   metadata: %{}
                 })
               )

      assert "must be greater than or equal to 0" in errors_on(cs).unit_price_cents
      assert "must be greater than 0" in errors_on(cs).quantity
    end

    test "item metadata must be a string-keyed object" do
      cs =
        OrderItem.changeset(%OrderItem{}, %{
          product_name: "P",
          variant_name: "V",
          unit_price_cents: 5,
          currency: "USD",
          quantity: 1,
          metadata: %{"ok" => true}
        })

      assert cs.valid?

      cs =
        OrderItem.changeset(%OrderItem{}, %{
          product_name: "P",
          variant_name: "V",
          unit_price_cents: 5,
          currency: "USD",
          quantity: 1,
          metadata: %{platform: "tiktok"}
        })

      refute cs.valid?
      assert "must use string keys" in errors_on(cs).metadata
    end

    test "an order item must point at a real order, and a snapshot at a real variant",
         %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)
      {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      base_item = %{
        product_name: "P",
        variant_name: "V",
        unit_price_cents: 5,
        currency: "USD",
        quantity: 1,
        metadata: %{}
      }

      # A snapshot that names a real variant but a bogus order.
      order_refusal =
        %OrderItem{}
        |> OrderItem.changeset(base_item)
        |> Ecto.Changeset.put_change(:order_id, 987_654_321)
        |> Ecto.Changeset.put_change(:product_variant_id, variant.id)

      assert {:error, order_refusal} = Cass.Repo.insert(order_refusal)
      assert {:order, {"does not exist", opts}} = List.keyfind(order_refusal.errors, :order, 0)
      assert is_list(opts)

      # A snapshot that joins a real order to a bogus variant.
      variant_refusal =
        %OrderItem{}
        |> OrderItem.changeset(base_item)
        |> Ecto.Changeset.put_change(:order_id, order.id)
        |> Ecto.Changeset.put_change(:product_variant_id, 987_654_321)

      assert {:error, variant_refusal} = Cass.Repo.insert(variant_refusal)

      assert {:product_variant, {"does not exist", opts}} =
               List.keyfind(variant_refusal.errors, :product_variant, 0)

      assert is_list(opts)
    end
  end

  describe "mark_order_paid/1" do
    setup %{category: category} do
      buyer = scope_for(:customer)
      %{variant: variant} = checkout_product!(category)
      {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])
      %{order: order}
    end

    test "moves an awaiting_payment order to paid", %{order: order} do
      assert {:ok, paid} = Orders.mark_order_paid(order.id)
      assert paid.id == order.id
      assert paid.status == :paid
      assert Cass.Repo.get!(Order, order.id).status == :paid
    end

    test "accepts a struct or an id", %{order: order} do
      assert {:ok, %Order{status: :paid}} = Orders.mark_order_paid(order)
      assert Cass.Repo.get!(Order, order.id).status == :paid
    end

    test "is idempotent for an already paid order", %{order: order} do
      assert {:ok, %Order{status: :paid}} = Orders.mark_order_paid(order.id)
      assert {:ok, %Order{status: :paid}} = Orders.mark_order_paid(order.id)
    end

    test "refuses any other status with the order untouched", %{order: order} do
      {1, _} =
        Cass.Repo.update_all(
          from(o in Order, where: o.id == ^order.id),
          set: [status: :cancelled]
        )

      assert {:error, changeset} = Orders.mark_order_paid(order.id)
      assert "the order cannot be paid from its current status" in errors_on(changeset).base
      assert Cass.Repo.get!(Order, order.id).status == :cancelled
    end

    test "a bogus id is reported distinctly", %{} do
      assert {:error, :order_not_found} = Orders.mark_order_paid(987_654_321)
      assert {:error, :order_not_found} = Orders.mark_order_paid(nil)
    end
  end
end
