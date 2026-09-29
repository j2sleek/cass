defmodule CassWeb.PaymentsWebhookControllerTest do
  @moduledoc """
  The provider webhook endpoint over the HTTP stack: raw-body capture, signature
  gating (400), reconciliation (200 with the order paid), unknown references
  (404), and coarse responses that never leak payment details.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Payments
  alias Cass.Payments.Payment
  alias Cass.Repo

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(owner, category, %{
        name: "Webhook Product",
        slug: "webhook-product",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "Tier",
        sku: "WH-#{System.unique_integer([:positive])}",
        price_cents: 1500,
        currency: "USD",
        stock: 5,
        sort_order: 1
      })

    buyer = Scope.for_user(Cass.AccountsFixtures.user_fixture())
    {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

    # Start a real payment attempt through the boundary (stubbed HTTP), so the
    # webhook below reconciles against a genuine row.
    Req.Test.stub(:paystack, fn conn ->
      body = Req.Test.raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{
          "authorization_url" => "https://checkout.paystack.com/wh",
          "reference" => body["reference"],
          "id" => 1,
          "domain" => "test"
        }
      })
    end)

    assert {:ok, %{payment: payment}} = Payments.initialize_payment(buyer, order.id)
    %{buyer: buyer, order: order, payment: payment, variant: variant}
  end

  test "a verified charge.success pays the order and acknowledges", %{
    order: order,
    payment: payment
  } do
    body = charge_payload(payment.provider_reference, 1500, "USD")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    conn = post(conn, "/webhooks/paystack", body)

    assert response(conn, 200) == "ok"
    assert Repo.get!(Order, order.id).status == :paid
    assert Repo.get!(Payment, payment.id).status == :succeeded
  end

  test "a duplicate success webhook is acknowledged without touching anything", %{
    order: order,
    payment: payment
  } do
    body = charge_payload(payment.provider_reference, 1500, "USD")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    conn = post(conn, "/webhooks/paystack", body)
    assert response(conn, 200) == "ok"

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    conn = post(conn, "/webhooks/paystack", body)
    assert response(conn, 200) == "ok"

    assert Repo.aggregate(Payment, :count) == 1
    assert Repo.get!(Order, order.id).status == :paid
  end

  test "a bad signature is refused with 400 and changes nothing", %{
    order: order,
    payment: payment
  } do
    body = charge_payload(payment.provider_reference, 1500, "USD")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", Base.encode16(:crypto.strong_rand_bytes(32)))

    conn = post(conn, "/webhooks/paystack", body)

    assert response(conn, 400) == "invalid signature"
    assert Repo.get!(Payment, payment.id).status == :processing
    assert Repo.get!(Order, order.id).status == :awaiting_payment
  end

  test "a missing signature is refused with 400" do
    body = charge_payload("PY-ANY", 1500, "USD")

    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = post(conn, "/webhooks/paystack", body)

    assert response(conn, 400) == "invalid signature"
  end

  test "a correctly signed but unknown reference is a 404", %{order: order} do
    body = charge_payload("PY-NOT-OURS", 1500, "USD")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    conn = post(conn, "/webhooks/paystack", body)

    assert response(conn, 404) == "not found"
    assert Repo.get!(Order, order.id).status == :awaiting_payment
  end

  test "a signature-verified irrelevant event is acknowledged", %{
    order: order,
    payment: payment
  } do
    body = Jason.encode!(%{"event" => "transfer.success", "data" => %{"reference" => "TRF_1"}})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", sign(body))

    conn = post(conn, "/webhooks/paystack", body)

    assert response(conn, 200) == "ok"
    assert Repo.get!(Payment, payment.id).status == :processing
    assert Repo.get!(Order, order.id).status == :awaiting_payment
  end

  defp charge_payload(reference, amount, currency) do
    Jason.encode!(%{
      "event" => "charge.success",
      "data" => %{
        "id" => 77_241_310,
        "reference" => reference,
        "status" => "success",
        "amount" => amount,
        "currency" => currency,
        "paid_at" => "2026-09-29T12:00:00.000Z",
        "channel" => "card"
      }
    })
  end

  defp sign(body), do: Base.encode16(:crypto.mac(:hmac, :sha512, @secret_key, body), case: :lower)
end
