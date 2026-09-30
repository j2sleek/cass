defmodule Cass.Fulfillment.IntegrationTest do
  @moduledoc """
  The whole purchase chain, end to end and in order:

      checkout → payment capture → paid order → delivery → entitlement

  Driven through the real boundaries (`Cass.Orders.create_order/2`,
  `Cass.Payments.initialize_payment/3` with a stubbed provider, a
  signature-verified webhook, then `Cass.Fulfillment`/``Cass.Entitlements``), so
  the assertions hold against the same sequence production takes. Two properties
  matter as much as the happy path:

    * a capture alone creates **no** delivery — the paid order is the
      precondition, and the trigger is a separate, explicit step;
    * a forged webhook body changes nothing, so the chain only ever advances
      through a verified capture.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Payments
  alias Cass.Repo

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  setup do
    buyer = Scope.for_user(user_fixture())
    category = category_fixture()
    {_product, variant} = published_variant_fixture(category, product_name: "Chain Widget")

    {:ok, order} = Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 3}])

    %{buyer: buyer, category: category, order: order, variant: variant}
  end

  test "checkout → verified capture → paid order → delivery → entitlement", ctx do
    # 1. Checkout reserves stock and snapshots the price.
    assert ctx.order.status == :awaiting_payment
    assert Repo.get!(Cass.Catalog.ProductVariant, ctx.variant.id).stock == 97

    # 2. The payment boundary initializes an attempt with the provider.
    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, ctx.order.id)
    assert payment.status == :processing

    # 3. A verified success webhook pays the payment and the order together, and
    #    by itself creates no delivery.
    body = charge_payload(payment.provider_reference, "success", 1497, "USD")

    assert :ok = Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})
    assert Repo.get!(Order, ctx.order.id).status == :paid
    assert Repo.aggregate(FulfillmentRecord, :count) == 0
    assert Repo.aggregate(Entitlement, :count) == 0

    # 4. The trigger reads the authoritative paid order and owes one delivery per
    #    purchased line.
    assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert fulfillment.status == :pending
    assert fulfillment.kind == :digital
    assert fulfillment.product_type == :digital
    assert fulfillment.user_id == ctx.buyer.user.id
    assert Repo.aggregate(Entitlement, :count) == 0

    # 5. Delivery completes, and the grant appears in the same call.
    assert {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)
    assert Repo.aggregate(Entitlement, :count) == 0

    assert {:ok, fulfillment} = Fulfillment.mark_fulfilled(fulfillment)
    assert fulfillment.status == :fulfilled
    assert fulfillment.delivered_at != nil

    entitlement = Repo.preload(fulfillment, :entitlement).entitlement
    assert entitlement.status == :active
    assert entitlement.user_id == ctx.buyer.user.id
    assert entitlement.product_name == "Chain Widget"
    assert entitlement.quantity == 3
    assert entitlement.fulfillment_id == fulfillment.id

    # 6. The buyer can see both halves of what they bought.
    assert [mine] = Fulfillment.list_for_customer(ctx.buyer)
    assert mine.id == fulfillment.id
    assert [granted] = Entitlements.list_for_customer(ctx.buyer)
    assert granted.id == entitlement.id
    assert [from_order] = Fulfillment.list_for_order(ctx.buyer, ctx.order.id)
    assert from_order.id == fulfillment.id
  end

  test "replaying the whole trigger sequence changes nothing", ctx do
    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, ctx.order.id)
    body = charge_payload(payment.provider_reference, "success", 1497, "USD")
    headers = %{"x-paystack-signature" => sign(body)}

    assert :ok = Payments.handle_webhook(:paystack, body, headers)

    assert {:ok, [first]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, first} = Fulfillment.mark_processing(first)
    assert {:ok, first} = Fulfillment.mark_fulfilled(first)

    # The duplicated webhook and the retried worker both run again.
    assert :ok = Payments.handle_webhook(:paystack, body, headers)
    assert {:ok, [second]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, second} = Fulfillment.mark_fulfilled(second)

    # A completed delivery is terminal: the retry cannot even re-claim it.
    assert {:error, _changeset} = Fulfillment.mark_processing(second)

    assert first.id == second.id
    assert Repo.aggregate(FulfillmentRecord, :count) == 1
    assert Repo.aggregate(Entitlement, :count) == 1
    assert Repo.aggregate(Cass.Payments.Payment, :count) == 1
  end

  test "an unsigned or mismatched capture leaves the chain unfulfilled", ctx do
    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, ctx.order.id)
    body = charge_payload(payment.provider_reference, "success", 1497, "USD")

    assert {:error, _reason} =
             Payments.handle_webhook(:paystack, body, %{
               "x-paystack-signature" => "not-a-signature"
             })

    assert {:error, _reason} =
             Payments.handle_webhook(:paystack, body, %{
               "x-paystack-signature" => sign("tampered")
             })

    assert Repo.get!(Order, ctx.order.id).status == :awaiting_payment
    assert {:error, changeset} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert "the order has not been paid" in errors_on(changeset).base
    assert Repo.aggregate(FulfillmentRecord, :count) == 0
  end

  test "a failed delivery leaves the purchase owed and grants nothing", ctx do
    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, ctx.order.id)
    body = charge_payload(payment.provider_reference, "success", 1497, "USD")
    assert :ok = Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

    assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)
    assert {:ok, failed} = Fulfillment.mark_failed(fulfillment, "provider refused the request")
    assert failed.status == :failed
    assert failed.failure_reason == "provider refused the request"
    assert Repo.aggregate(Entitlement, :count) == 0

    # The retry succeeds and the purchase finally grants.
    assert {:ok, retrying} = Fulfillment.mark_processing(failed)
    assert {:ok, delivered} = Fulfillment.mark_fulfilled(retrying)
    assert delivered.status == :fulfilled
    entitlement = Repo.preload(delivered, :entitlement).entitlement
    assert entitlement.status == :active
  end

  test "cancelling a delivery keeps the paid order owed and grants nothing", ctx do
    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, ctx.order.id)
    body = charge_payload(payment.provider_reference, "success", 1497, "USD")
    assert :ok = Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

    assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, cancelled} = Fulfillment.mark_cancelled(fulfillment)
    assert cancelled.status == :cancelled

    # Cancelling never orphans a grant, and the payment is untouched: a refund
    # is a later, separate decision.
    assert Repo.aggregate(Entitlement, :count) == 0
    assert Repo.get!(Order, ctx.order.id).status == :paid
    assert Repo.get!(Cass.Payments.Payment, payment.id).status == :succeeded
  end

  test "each purchased line of a mixed order is delivered on its own", ctx do
    {_digital, digital_variant} = published_variant_fixture(ctx.category, product_type: :digital)
    {_service, service_variant} = published_variant_fixture(ctx.category, product_type: :service)

    {:ok, order} =
      Orders.create_order(ctx.buyer, [
        %{product_variant_id: digital_variant.id, quantity: 1},
        %{product_variant_id: service_variant.id, quantity: 1}
      ])

    Req.Test.stub(:paystack, success_init_stub())
    assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, order.id)
    body = charge_payload(payment.provider_reference, "success", 998, "USD")
    assert :ok = Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

    assert {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
    assert fulfillments |> Enum.map(& &1.kind) |> Enum.sort() == [:digital, :manual]

    # The automated line is fulfilled by code; the service line waits for a human,
    # and only the completed line carries a grant.
    [digital, manual] = Enum.sort_by(fulfillments, & &1.kind, :desc)
    assert {:ok, processing} = Fulfillment.mark_processing(digital)
    assert {:ok, delivered} = Fulfillment.mark_fulfilled(processing)
    assert Repo.preload(delivered, :entitlement).entitlement.status == :active
    assert Repo.get!(FulfillmentRecord, manual.id).status == :pending

    assert [granted] = Repo.all(Ecto.Query.from(e in Entitlement, where: e.order_id == ^order.id))
    assert granted.order_item_id == digital.order_item_id
  end

  defp success_init_stub do
    fn conn ->
      body = Req.Test.raw_body(conn) |> Jason.decode!()

      Req.Test.json(conn, %{
        "status" => true,
        "message" => "ok",
        "data" => %{
          "authorization_url" => "https://checkout.paystack.com/#{body["reference"]}",
          "access_code" => "ACC-1",
          "reference" => body["reference"],
          "id" => 1,
          "domain" => "test"
        }
      })
    end
  end

  defp charge_payload(reference, status, amount, currency) do
    Jason.encode!(%{
      "event" => "charge.success",
      "data" => %{
        "id" => 77_241_310,
        "reference" => reference,
        "status" => status,
        "amount" => amount,
        "currency" => currency,
        "paid_at" => "2026-09-29T12:00:00.000Z",
        "channel" => "card"
      }
    })
  end

  defp sign(body), do: Base.encode16(:crypto.mac(:hmac, :sha512, @secret_key, body), case: :lower)
end
