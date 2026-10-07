defmodule CassWeb.OrderControllerTest do
  @moduledoc """
  The checkout entry point (`POST /orders`) through the browser stack: guests
  are stopped by `require_authenticated_user`, and signed-in accounts get an
  order server-side or a generic refusal, never any client-chosen money.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders

  setup do
    unique = System.unique_integer([:positive])

    {:ok, category} =
      Catalog.create_category(%{name: "Digital #{unique}", slug: "digital-#{unique}"})

    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(owner, category, %{
        name: "Controller Product",
        slug: "controller-product-#{System.unique_integer([:positive])}",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "Tier",
        sku: "CTRL-#{System.unique_integer([:positive])}",
        price_cents: 1250,
        currency: "USD",
        stock: 5,
        sort_order: 1
      })

    %{variant: variant, owner: owner}
  end

  test "a guest cannot post an order and is sent to log in", %{variant: variant} do
    conn = build_conn()

    conn =
      post(conn, ~p"/orders", %{
        "product_variant_id" => to_string(variant.id),
        "quantity" => "1"
      })

    assert redirected_to(conn, 302) == ~p"/users/log-in"
    assert Orders.list_orders(Scope.for_user(nil)) == []
  end

  test "a signed-in customer places an order and lands on its page", %{variant: variant} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})

    conn =
      post(conn, ~p"/orders", %{
        "product_variant_id" => to_string(variant.id),
        "quantity" => "2"
      })

    scope = Scope.for_user(user)
    assert [order] = Orders.list_orders(scope)
    assert order.total_cents == 1250 * 2
    assert order.status == :awaiting_payment
    assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 3

    assert redirected_to(conn, 302) == ~p"/orders/#{order.id}"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Order #{order.number} placed."
  end

  test "an invalid quantity is a generic refusal, nothing is written", %{variant: variant} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})

    conn =
      post(conn, ~p"/orders", %{
        "product_variant_id" => to_string(variant.id),
        "quantity" => "0"
      })

    assert redirected_to(conn, 302) == ~p"/orders"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "the order request is invalid"
    assert Orders.list_orders(Scope.for_user(user)) == []
    assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 5
  end

  test "a missing variant is the same generic unavailable refusal" do
    %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})
    conn = post(conn, ~p"/orders", %{"product_variant_id" => "987654321", "quantity" => "1"})

    assert redirected_to(conn, 302) == ~p"/orders"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "an item in the order is not available for purchase"
  end

  test "malformed params are refused without writing anything", %{variant: variant} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})

    conn =
      post(conn, ~p"/orders", %{
        "order" => %{"requested_items" => [%{"quantity" => "1"}]}
      })

    assert redirected_to(conn, 302) == ~p"/orders"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "the order request is invalid"
    assert Orders.list_orders(Scope.for_user(user)) == []
    assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 5
  end
end
