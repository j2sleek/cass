defmodule Cass.PaymentsTest do
  @moduledoc """
  The Payments boundary: snapshotting money from the order, idempotent
  initialization, provider failure recording, and signature-verified webhook
  reconciliation that moves orders to `:paid` only when payment succeeded for
  the exact snapshot amount.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Payments
  alias Cass.Payments.{Payment, Providers}

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    %{category: category}
  end

  defp scope_for(:customer), do: Scope.for_user(user_fixture())

  defp checkout_product!(category) do
    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(owner, category, %{
        name: "TikTok Followers",
        slug: "tiktok-followers",
        product_type: :smm,
        visibility: :public
      })

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "1,000",
        sku: "TIK-#{System.unique_integer([:positive])}",
        price_cents: 499,
        currency: "USD",
        stock: 100,
        sort_order: 1
      })

    %{owner: owner, product: product, variant: variant}
  end

  defp place_order(buyer, category, quantity \\ 1) do
    %{variant: variant} = checkout_product!(category)

    {:ok, order} =
      Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: quantity}])

    %{order: order, variant: variant}
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

  describe "provider resolution" do
    test "resolves a configured adapter and refuses anything else" do
      assert {:ok, Cass.Payments.Providers.Paystack} = Payments.provider(:paystack)
      assert {:ok, Cass.Payments.Providers.Paystack} = Payments.provider("paystack")
      assert {:error, :unknown_provider} = Payments.provider(:stripe)
      assert {:error, :unknown_provider} = Payments.provider("stripe")
    end

    test "exposes the closed status vocabulary" do
      assert Payments.payment_statuses() ==
               [:pending, :processing, :succeeded, :failed, :cancelled, :expired, :refunded]
    end
  end

  describe "initialize_payment/3" do
    test "snapshots the order total and returns the hosted checkout", %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, success_init_stub())

      assert {:ok, %{payment: payment, order: returned_order, checkout_url: checkout_url}} =
               Payments.initialize_payment(buyer, order.id)

      assert checkout_url =~ "https://checkout.paystack.com/PY-"
      assert returned_order.status == :awaiting_payment

      assert payment.provider == "paystack"
      assert payment.provider_reference =~ ~r/\APY-[A-Z2-7]{13}\z/
      assert payment.amount_cents == 499
      assert payment.currency == "USD"
      assert payment.status == :processing
      assert payment.metadata["access_code"] == "ACC-1"
    end

    test "passes the snapshot amount, currency, email, and reference to the provider",
         %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, fn conn ->
        body = Req.Test.raw_body(conn) |> Jason.decode!()
        assert body["email"] == buyer.user.email
        assert body["amount"] == 499
        assert body["currency"] == "USD"
        assert body["reference"] =~ ~r/\APY-[A-Z2-7]{13}\z/

        Req.Test.json(conn, %{
          "status" => true,
          "data" => %{
            "authorization_url" => "https://checkout.paystack.com/abc",
            "reference" => body["reference"],
            "id" => 2,
            "domain" => "test"
          }
        })
      end)

      assert {:ok, %{payment: payment}} = Payments.initialize_payment(buyer, order.id)
      assert payment.status == :processing
    end

    test "re-initializing an order reuses the live attempt (idempotent)", %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, success_init_stub())

      assert {:ok, %{checkout_url: first_url, payment: payment}} =
               Payments.initialize_payment(buyer, order.id)

      # The second call must not hit the provider (stub would be called twice) —
      # use `expect` to prove the provider is contacted exactly once.
      Req.Test.stub(:paystack, fn _ ->
        flunk("the provider must not be contacted on reuse")
      end)

      assert {:ok, %{checkout_url: second_url, payment: second_payment}} =
               Payments.initialize_payment(buyer, order.id)

      assert second_url == first_url
      assert second_payment.id == payment.id
      assert Repo.aggregate(Payment, :count) == 1
    end

    test "a foreign or unknown order id is the same not-found", %{category: category} do
      buyer = scope_for(:customer)
      stranger = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      assert {:error, :not_found} = Payments.initialize_payment(stranger, order.id)
      assert {:error, :not_found} = Payments.initialize_payment(buyer, 987_654_321)
      assert {:error, :not_found} = Payments.initialize_payment(Scope.for_user(nil), order.id)
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "an order that is not awaiting payment is refused", %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)
      {:ok, %Order{}} = Orders.mark_order_paid(order.id)

      assert {:error, changeset} = Payments.initialize_payment(buyer, order.id)
      assert "the order is not awaiting payment" in errors_on(changeset).base
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "a provider failure records the attempt and refuses via a generic message",
         %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, %{"status" => false, "message" => "Invalid API key"})
      end)

      assert {:error, changeset} = Payments.initialize_payment(buyer, order.id)
      assert "payments are temporarily unavailable" in errors_on(changeset).base

      assert [payment] = Repo.all(Payment)
      assert payment.status == :failed
      assert payment.failure_reason == "Invalid API key"
      assert payment.amount_cents == 499
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "a retry after a terminal failure creates a fresh attempt", %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, %{"status" => false, "message" => "Declined"})
      end)

      assert {:error, _} = Payments.initialize_payment(buyer, order.id)

      Req.Test.stub(:paystack, success_init_stub())

      assert {:ok, %{payment: payment}} = Payments.initialize_payment(buyer, order.id)
      assert payment.status == :processing
      assert Repo.aggregate(Payment, :count) == 2
    end
  end

  describe "handle_webhook/3" do
    setup %{category: category} do
      buyer = scope_for(:customer)
      %{order: order} = place_order(buyer, category)

      Req.Test.stub(:paystack, success_init_stub())
      assert {:ok, %{payment: payment}} = Payments.initialize_payment(buyer, order.id)
      %{buyer: buyer, order: order, payment: payment}
    end

    test "a verified success pays the payment and the order together",
         %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "success", 499, "USD")

      assert :ok =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      succeeded = Repo.get!(Payment, payment.id)
      assert succeeded.status == :succeeded
      assert succeeded.paid_at != nil
      assert succeeded.payment_method == "card"

      paid_order = Repo.get!(Order, order.id)
      assert paid_order.status == :paid
    end

    test "a duplicate success webhook is an idempotent no-op",
         %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "success", 499, "USD")
      headers = %{"x-paystack-signature" => sign(body)}

      assert :ok = Payments.handle_webhook(:paystack, body, headers)
      assert :ok = Payments.handle_webhook(:paystack, body, headers)

      assert Repo.get!(Payment, payment.id).status == :succeeded
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "an amount mismatch refuses to pay anything", %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "success", 501, "USD")

      assert {:error, :amount_mismatch} =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      assert Repo.get!(Payment, payment.id).status == :processing
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "a currency mismatch refuses to pay anything", %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "success", 499, "EUR")

      assert {:error, :amount_mismatch} =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      assert Repo.get!(Payment, payment.id).status == :processing
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "an unknown reference is refused", %{order: order} do
      body = charge_payload("PY-UNKNOWN-REF", "success", 499, "USD")

      assert {:error, :unknown_payment} =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "a reported failure moves only the payment to a terminal state",
         %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "failed", 499, "USD")

      assert :ok =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      failed = Repo.get!(Payment, payment.id)
      assert failed.status == :failed
      assert failed.failure_reason =~ "provider reported failed"

      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "an invalid signature is refused and nothing changes",
         %{order: order, payment: payment} do
      body = charge_payload(payment.provider_reference, "success", 499, "USD")
      headers = %{"x-paystack-signature" => Base.encode16(:crypto.strong_rand_bytes(32))}

      assert {:error, :invalid_signature} = Payments.handle_webhook(:paystack, body, headers)

      assert Repo.get!(Payment, payment.id).status == :processing
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "an irrelevant event is acknowledged and changes nothing",
         %{order: order, payment: payment} do
      body =
        Jason.encode!(%{"event" => "transfer.success", "data" => %{"reference" => "TRF_1"}})

      assert :ok =
               Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

      assert Repo.get!(Payment, payment.id).status == :processing
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "an unknown provider is reported for the webhook" do
      body = charge_payload("PY-UNKNOWN-REF", "success", 499, "USD")
      assert {:error, :unknown_provider} = Payments.handle_webhook(:stripe, body, %{})
    end
  end

  describe "provider registry" do
    test "lists the configured and enabled providers" do
      assert :paystack in Providers.enabled()
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
