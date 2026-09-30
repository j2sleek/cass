defmodule CassWeb.FulfillmentWebTest do
  @moduledoc """
  Milestone 7 across the real web stack.

  Everything else about the delivery chain is proven in the contexts. This file
  exists to prove the two claims those tests cannot make on their own:

    1. the chain is actually *wired* to the money — a real signed
       `POST /webhooks/paystack` is what makes an order payable for delivery,
       and completing a real delivery is what grants the buyer a record. The
       contexts are called directly in their own tests, so nothing else would
       catch a controller that paid the order without the delivery chain ever
       being able to see it;

    2. the delivery and entitlement records stay private to the buyer's own
       surfaces — a guest is stopped by the router, and a signed-in stranger is
       given the same not-found page as a nonexistent id, not a leaked order.

  The fulfillment trigger is still a deliberate server-side boundary call, as
  documented: there is no delivery route to press, and no worker, so this file
  calls `Cass.Fulfillment` where a worker would. What is asserted is the
  invariant (one payment pays the order, one delivery per line, one grant per
  delivery) rather than the timing.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Cass.DataCase, only: [errors_on: 1]

  alias Cass.Accounts.Scope
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders.Order
  alias Cass.Payments.Payment
  alias Cass.Repo

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  setup do
    {:ok, category} = Cass.Catalog.create_category(%{name: "Delivery", slug: "delivery"})
    vendor = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Cass.Catalog.create_owned_product(vendor, category, %{
        name: "Delivered Widget",
        slug: "delivered-widget",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product} = Cass.Catalog.publish_product(vendor, product)

    {:ok, variant} =
      Cass.Catalog.create_variant(vendor, product, %{
        name: "Tier",
        sku: "WEB-#{System.unique_integer([:positive])}",
        price_cents: 1500,
        currency: "USD",
        stock: 5,
        sort_order: 1
      })

    %{variant: variant}
  end

  describe "the paid order to delivery chain, over HTTP" do
    test "a real checkout, pay, and signed webhook is what makes a line deliverable", %{
      variant: variant
    } do
      buyer = user_fixture()
      conn = log_in_user(build_conn(), buyer)

      # 1. Checkout, through the real controller with a real session.
      conn = post(conn, "/orders", %{"product_variant_id" => variant.id, "quantity" => 1})
      order_id = redirected_order_id(conn)
      order = Repo.get!(Order, order_id)
      assert redirected_to(conn, 302) == ~p"/orders/#{order.id}"
      assert order.status == :awaiting_payment

      # Nothing is owed before the money arrives.
      assert {:error, changeset} = Fulfillment.create_for_paid_order(order)
      assert "the order has not been paid" in errors_on(changeset).base
      assert Repo.aggregate(FulfillmentRecord, :count) == 0

      # 2. Pay, through the real controller (provider HTTP stubbed).
      reference_url = "https://checkout.paystack.com/pay-#{order.id}"
      Req.Test.stub(:paystack, stub_reference(reference_url))

      conn = conn |> recycle() |> post("/orders/#{order.id}/pay")
      assert redirected_to(conn, 302) == reference_url
      assert [payment] = Repo.all(Payment)
      assert payment.status == :processing

      # Still not payable: an attempt is not a payment.
      assert {:error, changeset} = Fulfillment.create_for_paid_order(Repo.get!(Order, order.id))
      assert "the order has not been paid" in errors_on(changeset).base

      # 3. The provider webhook, signed with the real secret, pays the order.
      assert post_webhook(payment) |> response(200) == "ok"
      assert Repo.get!(Order, order.id).status == :paid

      # 4. Now, and only now, the paid order owes a delivery per line.
      assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(Repo.get!(Order, order.id))
      assert fulfillment.status == :pending
      assert fulfillment.user_id == buyer.id
      assert fulfillment.product_type == :digital

      # A pending delivery has not granted anything yet.
      assert Repo.aggregate(Entitlement, :count) == 0

      assert {:ok, claimed} = Fulfillment.mark_processing(fulfillment)
      assert {:ok, delivered} = Fulfillment.mark_fulfilled(claimed)
      assert delivered.status == :fulfilled
      assert delivered.delivered_at != nil

      # 5. Completion is what grants the buyer a record of what they own.
      assert [entitlement] = Repo.all(Entitlement)
      assert entitlement.status == :active
      assert entitlement.fulfillment_id == fulfillment.id
      assert entitlement.user_id == buyer.id
      assert entitlement.product_name == "Delivered Widget"
      assert entitlement.quantity == 1

      # The buyer's own order page reflects the paid order and offers nothing
      # further to pay.
      {:ok, view, _html} = live(log_in_user(build_conn(), buyer), ~p"/orders/#{order.id}")
      assert has_element?(view, "h1", order.number)
      assert has_element?(view, "span", "paid")
      assert has_element?(view, "#order-items")
      refute has_element?(view, "#pay-form")
    end

    test "replaying the webhook and the trigger never duplicates money, delivery, or grant",
         %{variant: variant} do
      buyer = user_fixture()
      conn = log_in_user(build_conn(), buyer)

      conn = post(conn, "/orders", %{"product_variant_id" => variant.id, "quantity" => 2})
      order = Repo.get!(Order, redirected_order_id(conn))

      Req.Test.stub(:paystack, stub_reference("https://checkout.paystack.com/replay"))

      conn = conn |> recycle() |> post("/orders/#{order.id}/pay")
      assert redirected_to(conn, 302)
      [payment] = Repo.all(Payment)

      # The provider retries its webhook, as providers do.
      for _attempt <- 1..3 do
        assert post_webhook(payment) |> response(200) == "ok"
      end

      # The trigger is retried, as a crash-looping worker would be.
      {:ok, [first]} = Fulfillment.create_for_paid_order(Repo.get!(Order, order.id))
      {:ok, [again]} = Fulfillment.create_for_paid_order(Repo.get!(Order, order.id))
      assert again.id == first.id

      # ... and so are the transitions.
      {:ok, claimed} = Fulfillment.mark_processing(first)
      {:ok, claimed_again} = Fulfillment.mark_processing(claimed)
      assert claimed_again.id == claimed.id
      {:ok, delivered} = Fulfillment.mark_fulfilled(claimed)
      {:ok, delivered_again} = Fulfillment.mark_fulfilled(delivered)
      assert delivered_again.id == delivered.id
      assert delivered_again.delivered_at == delivered.delivered_at
      assert delivered_again.updated_at == delivered.updated_at

      assert Repo.aggregate(Payment, :count) == 1
      assert Repo.aggregate(FulfillmentRecord, :count) == 1
      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "a paid order for a line that cannot be delivered is never silently granted",
         %{variant: variant} do
      buyer = user_fixture()
      conn = log_in_user(build_conn(), buyer)

      conn = post(conn, "/orders", %{"product_variant_id" => variant.id, "quantity" => 1})
      order = Repo.get!(Order, redirected_order_id(conn))
      {:ok, order} = Cass.Orders.mark_order_paid(order.id)

      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, failed} = Fulfillment.mark_failed(processing, "provider rejected the order")

      assert failed.status == :failed
      assert Repo.aggregate(Entitlement, :count) == 0

      # A failed delivery can be retried, and only a completion grants.
      {:ok, retried} = Fulfillment.mark_processing(failed)
      assert retried.status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0

      {:ok, delivered} = Fulfillment.mark_fulfilled(retried)
      assert delivered.status == :fulfilled
      assert Repo.aggregate(Entitlement, :count) == 1
    end
  end

  describe "who can see a paid order that is being delivered" do
    setup %{variant: variant} do
      buyer = user_fixture()
      conn = log_in_user(build_conn(), buyer)

      conn = post(conn, "/orders", %{"product_variant_id" => variant.id, "quantity" => 1})
      order = Repo.get!(Order, redirected_order_id(conn))

      {:ok, order} = Cass.Orders.mark_order_paid(order.id)
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(fulfillment)

      %{buyer: buyer, order: Repo.get!(Order, order.id), fulfillment: fulfillment}
    end

    test "the buyer sees their own delivered order", %{buyer: buyer, order: order} do
      {:ok, view, _html} = live(log_in_user(build_conn(), buyer), ~p"/orders/#{order.id}")

      assert has_element?(view, "h1", order.number)
      assert has_element?(view, "#order-items")
      assert has_element?(view, "span", "paid")
      refute has_element?(view, "#not-found")
    end

    test "a signed-in stranger gets the same not-found page as a nonexistent id", %{
      order: order
    } do
      {:ok, view, _html} =
        live(log_in_user(build_conn(), user_fixture()), ~p"/orders/#{order.id}")

      assert has_element?(view, "#not-found")

      {:ok, other_view, _html} =
        live(log_in_user(build_conn(), user_fixture()), ~p"/orders/987654321")

      assert has_element?(other_view, "#not-found")
    end

    test "a guest is stopped by the router and learns nothing about the order" do
      conn = get(build_conn(), ~p"/orders")
      assert redirected_to(conn, 302) == ~p"/users/log-in"
    end

    test "a guest cannot reach the order page either", %{order: order} do
      conn = get(build_conn(), ~p"/orders/#{order.id}")
      assert redirected_to(conn, 302) == ~p"/users/log-in"
    end

    test "an admin can read any order", %{order: order} do
      {:ok, view, _html} =
        live(log_in_user(build_conn(), admin_fixture()), ~p"/orders/#{order.id}")

      assert has_element?(view, "h1", order.number)
      refute has_element?(view, "#not-found")
    end
  end

  describe "the delivery and entitlement records are not a public API" do
    test "there is no route that hands out deliveries or grants" do
      buyer = user_fixture()
      conn = log_in_user(build_conn(), buyer)

      for path <- [
            "/fulfillments",
            "/entitlements",
            "/api/v1/fulfillments",
            "/api/v1/entitlements",
            "/orders/1/fulfillments"
          ] do
        response = conn |> recycle() |> get(path) |> response(404)

        # Not even an authenticated buyer can ask for a delivery or a grant.
        refute response =~ "pending"
        refute response =~ "active"
      end

      # The 404s above are the router declining, not a session that quietly
      # failed: the same signed-in buyer reaches their own order surface fine.
      assert log_in_user(build_conn(), buyer)
             |> get(~p"/orders")
             |> html_response(200) =~ "Orders"
    end

    test "the orders list never exposes another buyer's delivered line", %{variant: variant} do
      buyer = user_fixture()

      {:ok, own} =
        Cass.Orders.create_order(Scope.for_user(buyer), [
          %{product_variant_id: variant.id, quantity: 1}
        ])

      {:ok, own} = Cass.Orders.mark_order_paid(own.id)

      {:ok, stranger} =
        Cass.Orders.create_order(Scope.for_user(user_fixture()), [
          %{product_variant_id: variant.id, quantity: 1}
        ])

      {:ok, stranger} = Cass.Orders.mark_order_paid(stranger.id)
      {:ok, [foreign]} = Fulfillment.create_for_paid_order(stranger)
      {:ok, foreign} = Fulfillment.mark_processing(foreign)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(foreign)

      {:ok, view, _html} = live(log_in_user(build_conn(), buyer), ~p"/orders")

      assert has_element?(view, ~s|a[href="/orders/#{own.id}"]|, own.number)
      refute has_element?(view, ~s|a[href="/orders/#{stranger.id}"]|)
      assert has_element?(view, "#orders")
    end
  end

  # Reads the order id out of the redirect the checkout controller issues.
  defp redirected_order_id(conn) do
    conn
    |> redirected_to()
    |> String.split("/")
    |> List.last()
    |> String.to_integer()
  end

  defp post_webhook(payment) do
    body =
      Jason.encode!(%{
        "event" => "charge.success",
        "data" => %{
          "id" => 77_241_311,
          "reference" => payment.provider_reference,
          "status" => "success",
          "amount" => payment.amount_cents,
          "currency" => payment.currency,
          "paid_at" => "2026-09-30T12:00:00.000Z",
          "channel" => "card"
        }
      })

    request =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    post(request, "/webhooks/paystack", body)
  end

  defp stub_reference(reference) do
    fn conn ->
      body = Req.Test.raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "status" => true,
        "message" => "ok",
        "data" => %{
          "authorization_url" => reference,
          "access_code" => "ACC-9",
          "reference" => body["reference"],
          "id" => 42,
          "domain" => "test"
        }
      })
    end
  end

  defp sign(body) do
    Base.encode16(:crypto.mac(:hmac, :sha512, @secret_key, body), case: :lower)
  end
end
