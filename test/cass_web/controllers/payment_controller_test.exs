defmodule CassWeb.PaymentControllerTest do
  @moduledoc """
  `POST /orders/:id/pay` through the browser stack: authorization by scope,
  server-side money, external redirect to the hosted checkout, and generic
  refusals that never leak why something could not be paid.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders
  alias Cass.Payments.Payment
  alias Cass.Repo

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
        sku: "PAY-#{System.unique_integer([:positive])}",
        price_cents: 2000,
        currency: "USD",
        stock: 5,
        sort_order: 1
      })

    %{variant: variant, owner: owner}
  end

  test "a guest cannot pay and is sent to log in", %{variant: variant} do
    {:ok, order} = create_order(variant)

    conn = post(build_conn(), "/orders/#{order.id}/pay")

    assert redirected_to(conn, 302) == ~p"/users/log-in"
    assert Repo.aggregate(Payment, :count) == 0
  end

  test "the owner is sent to the hosted checkout with a server-snapshot payment",
       %{variant: variant} do
    buyer = user_fixture()
    {:ok, order} = create_order_for(variant, buyer)

    reference_url = "https://checkout.paystack.com/pay-#{order.id}"
    Req.Test.stub(:paystack, stub_reference(reference_url))

    conn = log_in_user(build_conn(), buyer)

    conn = post(conn, "/orders/#{order.id}/pay")

    assert redirected_to(conn, 302) == reference_url
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == nil

    assert [payment] = Repo.all(Payment)
    assert payment.order_id == order.id
    assert payment.provider == "paystack"
    assert payment.status == :processing
    assert payment.amount_cents == 2000
    assert payment.currency == "USD"

    assert Repo.get!(Cass.Orders.Order, order.id).status == :awaiting_payment
  end

  test "a second pay request reuses the same attempt, contacting the provider once",
       %{variant: variant} do
    buyer = user_fixture()
    {:ok, order} = create_order_for(variant, buyer)

    reference_url = "https://checkout.paystack.com/once-#{order.id}"

    Req.Test.expect(:paystack, 1, fn conn ->
      body = Req.Test.raw_body(conn) |> Jason.decode!()
      Req.Test.json(conn, success_body(body["reference"], reference_url))
    end)

    conn = log_in_user(build_conn(), buyer)

    conn = post(conn, "/orders/#{order.id}/pay")
    assert redirected_to(conn, 302) == reference_url

    conn = post(conn, "/orders/#{order.id}/pay")
    assert redirected_to(conn, 302) == reference_url
    assert Repo.aggregate(Payment, :count) == 1
  end

  test "a stranger cannot pay somebody else's order", %{variant: variant} do
    buyer = user_fixture()
    {:ok, order} = create_order_for(variant, buyer)

    %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})

    conn = post(conn, "/orders/#{order.id}/pay")

    assert redirected_to(conn, 302) == ~p"/orders"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "that order could not be paid"
    assert Repo.aggregate(Payment, :count) == 0
  end

  test "an unknown order id fails with the same generic message", %{} do
    %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})

    conn = post(conn, "/orders/987654321/pay")

    assert redirected_to(conn, 302) == ~p"/orders"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "that order could not be paid"
    assert Repo.aggregate(Payment, :count) == 0
  end

  test "an already-paid order is refused back onto its page", %{variant: variant} do
    buyer = user_fixture()
    {:ok, order} = create_order_for(variant, buyer)

    {:ok, %Cass.Orders.Order{}} = Orders.mark_order_paid(order.id)

    conn = log_in_user(build_conn(), buyer)

    conn = post(conn, "/orders/#{order.id}/pay")

    assert redirected_to(conn, 302) == "/orders/#{order.id}"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "the order is not awaiting payment"
    assert Repo.aggregate(Payment, :count) == 0
  end

  test "a provider failure shows a generic message and records the failed attempt",
       %{variant: variant} do
    buyer = user_fixture()
    {:ok, order} = create_order_for(variant, buyer)

    Req.Test.stub(:paystack, fn conn ->
      Req.Test.json(conn, %{"status" => false, "message" => "Declined"})
    end)

    conn = log_in_user(build_conn(), buyer)

    conn = post(conn, "/orders/#{order.id}/pay")

    assert redirected_to(conn, 302) == "/orders/#{order.id}"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "payments are temporarily unavailable"

    assert [payment] = Repo.all(Payment)
    assert payment.status == :failed
    assert payment.failure_reason == "Declined"
  end

  defp create_order(variant) do
    buyer = user_fixture()
    create_order_for(variant, buyer)
  end

  defp create_order_for(variant, user) do
    Orders.create_order(Scope.for_user(user), [%{product_variant_id: variant.id, quantity: 1}])
  end

  defp stub_reference(reference) do
    fn conn ->
      body = Req.Test.raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, success_body(body["reference"], reference))
    end
  end

  defp success_body(echoed_reference, authorization_url) do
    %{
      "status" => true,
      "message" => "ok",
      "data" => %{
        "authorization_url" => authorization_url,
        "access_code" => "ACC-9",
        "reference" => echoed_reference,
        "id" => 42,
        "domain" => "test"
      }
    }
  end
end
