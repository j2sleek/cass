defmodule CassWeb.OrdersLiveTest do
  @moduledoc """
  The signed-in orders pages (`/orders`, `/orders/:id`) and the minimal
  purchase surface on the public product page that feeds checkout.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(owner, category, %{
        name: "Live Product",
        slug: "live-product",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "Starter",
        sku: "LIVE-#{System.unique_integer([:positive])}",
        price_cents: 990,
        currency: "USD",
        stock: 5,
        sort_order: 1
      })

    %{owner: owner, product: product, variant: variant, category: category}
  end

  defp place_order(variant, user) do
    {:ok, order} =
      Orders.create_order(Scope.for_user(user), [%{product_variant_id: variant.id, quantity: 2}])

    order
  end

  describe "/orders index" do
    test "an account with no orders sees the empty state" do
      %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})
      {:ok, view, _html} = live(conn, "/orders")

      assert has_element?(view, "h1", "Orders")
      assert has_element?(view, "#orders-empty")
    end

    test "a signed-in account sees only its own orders", %{variant: variant} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})
      order = place_order(variant, user)
      _stranger_order = place_order(variant, user_fixture())

      {:ok, view, _html} = live(conn, "/orders")

      assert has_element?(view, "#order-#{order.id}")
      assert has_element?(view, "a[href='/orders/#{order.id}']")
      assert has_element?(view, "div", order.number)
    end
  end

  describe "/orders/:id show" do
    test "the buyer sees the order, its snapshot lines, and the server total",
         %{variant: variant} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})
      order = place_order(variant, user)

      {:ok, view, _html} = live(conn, "/orders/#{order.id}")

      assert has_element?(view, "h1", order.number)
      assert has_element?(view, "#order-items")
      assert has_element?(view, "div", "Live Product")
      assert has_element?(view, "div", "Starter")
      assert has_element?(view, "#order-subtotal")
      assert has_element?(view, "#order-total", "USD 19.80")
      assert has_element?(view, "span", "awaiting_payment")
    end

    test "a foreign or unknown order id renders the not-found state", %{variant: variant} do
      %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})

      stranger_order = place_order(variant, user_fixture())

      {:ok, view, _html} = live(conn, "/orders/#{stranger_order.id}")
      assert has_element?(view, "#not-found")
      refute has_element?(view, "h1", stranger_order.number)

      {:ok, view, _html} = live(conn, "/orders/987654321")
      assert has_element?(view, "#not-found")
    end

    test "an admin can view any order", %{variant: variant} do
      order = place_order(variant, user_fixture())
      admin_conn = log_in_user(build_conn(), admin_fixture())

      {:ok, view, _html} = live(admin_conn, "/orders/#{order.id}")

      assert has_element?(view, "h1", order.number)
      assert has_element?(view, "#order-items")
    end
  end

  describe "public product purchase surface" do
    test "a signed-in shopper gets the buy form for an active variant",
         %{variant: variant} do
      %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})
      {:ok, view, _html} = live(conn, "/catalog/products/live-product")

      assert has_element?(view, "#buy-panel")
      assert has_element?(view, "#buy-form")
      assert has_element?(view, "#buy-button")
      assert has_element?(view, "select[name='product_variant_id'] option[value='#{variant.id}']")
      assert has_element?(view, "input[name='quantity']")

      refute has_element?(
               view,
               "div",
               "Purchase and delivery options for this product are coming soon"
             )
    end

    test "a guest gets a sign-in prompt instead of the buy form" do
      {:ok, view, _html} = live(build_conn(), "/catalog/products/live-product")

      assert has_element?(view, "#buy-sign-in")
      assert has_element?(view, "#product-log-in-link", "Log in")
      refute has_element?(view, "#buy-form")
      refute has_element?(view, "div", "coming soon")
    end

    test "a product without active variants keeps the coming-soon box" do
      {:ok, category} = Catalog.create_category(%{name: "Tools", slug: "tools"})
      owner = Scope.for_user(vendor_fixture())

      {:ok, product} =
        Catalog.create_owned_product(owner, category, %{
          name: "Variantless",
          slug: "variantless-product",
          product_type: :ai,
          visibility: :public
        })

      {:ok, _} = Catalog.publish_product(owner, product)

      {:ok, view, _html} = live(build_conn(), "/catalog/products/variantless-product")

      assert has_element?(
               view,
               "div",
               "Purchase and delivery options for this product are coming soon as the marketplace grows."
             )

      refute has_element?(view, "#buy-panel")
      refute has_element?(view, "#buy-sign-in")
    end
  end
end
