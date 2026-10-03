defmodule Cass.Fulfillment.QueueIntegrationTest do
  @moduledoc """
  The purchase chain with the asynchronous queue in the middle:

      checkout → payment capture → paid order → **queued** → delivery → entitlement

  Driven through the real boundaries, including a stubbed provider and a
  signature-verified webhook, so the assertions hold against the same sequence
  production takes. The properties that matter here:

    * the delivery job is queued inside the capture transaction, so a capture
      that committed is a capture whose delivery is queued — and a capture that
      rolls back queues nothing;
    * only `:digital` and `:ai` are queued, and only those become `:fulfilled`;
    * an AI purchase receives its entitlement *and* its credits from the same
      job, exactly once;
    * a replayed webhook does not double-queue, double-deliver, or
      double-issue credits.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures
  import Cass.Jobs

  alias Cass.Accounts.Scope
  alias Cass.Ai.CreditBalance
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Fulfillment.Worker
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Payments
  alias Cass.Payments.Payment
  alias Cass.Repo

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  setup do
    buyer = Scope.for_user(user_fixture())
    category = category_fixture()

    %{buyer: buyer, category: category}
  end

  defp checkout(buyer, category, opts) do
    {_product, variant} = published_variant_fixture(category, opts)

    {:ok, order} =
      Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

    {order, variant}
  end

  defp capture!(buyer, order, variant, quantity \\ 1) do
    assert {:ok, %{payment: payment}} = init_payment(buyer, order)

    amount = quantity * Repo.get!(Cass.Catalog.ProductVariant, variant.id).price_cents
    deliver_capture!(payment, amount)
  end

  defp init_payment(buyer, order) do
    Req.Test.stub(:paystack, success_init_stub())
    Payments.initialize_payment(buyer, order.id)
  end

  defp deliver_capture!(payment, amount) do
    body = charge_payload(payment.provider_reference, "success", amount, "USD")

    assert :ok = Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

    Repo.get!(Payment, payment.id)
  end

  describe "the capture queues the delivery" do
    test "a verified capture queues exactly one job for a digital purchase", ctx do
      {order, variant} = checkout(ctx.buyer, ctx.category, product_type: :digital)

      assert count_for(Worker) == 0

      capture!(ctx.buyer, order, variant)
      assert Repo.get!(Order, order.id).status == :paid

      assert [fulfillment] = Repo.all(FulfillmentRecord)
      assert fulfillment.status == :pending

      # Queued in the same transaction as the capture. Nothing delivered yet.
      assert [%{"fulfillment_id" => id}] = args_for(Worker)
      assert id == fulfillment.id
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "the job carries nothing but the fulfillment id", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 9})

      capture!(ctx.buyer, order, variant)

      [args] = args_for(Worker)
      assert Map.keys(args) == ["fulfillment_id"]
      refute inspect(args) =~ "credits"
      refute inspect(args) =~ ctx.buyer.user.email
    end

    test "an unverified capture queues nothing", ctx do
      {order, _variant} = checkout(ctx.buyer, ctx.category, product_type: :digital)

      Req.Test.stub(:paystack, success_init_stub())
      assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, order.id)

      # Correct shape, wrong signature.
      body = charge_payload(payment.provider_reference, "success", 499, "USD")

      assert {:error, _reason} =
               Payments.handle_webhook(:paystack, body, %{
                 "x-paystack-signature" => sign("tampered")
               })

      assert Repo.get!(Order, order.id).status == :awaiting_payment
      assert Repo.aggregate(FulfillmentRecord, :count) == 0
      assert count_for(Worker) == 0
    end

    test "a replayed capture queues no second job", ctx do
      {order, _variant} = checkout(ctx.buyer, ctx.category, product_type: :digital)

      Req.Test.stub(:paystack, success_init_stub())
      assert {:ok, %{payment: payment}} = Payments.initialize_payment(ctx.buyer, order.id)
      body = charge_payload(payment.provider_reference, "success", 499, "USD")
      headers = %{"x-paystack-signature" => sign(body)}

      assert :ok = Payments.handle_webhook(:paystack, body, headers)
      assert :ok = Payments.handle_webhook(:paystack, body, headers)
      assert :ok = Payments.handle_webhook(:paystack, body, headers)

      assert Repo.aggregate(FulfillmentRecord, :count) == 1
      assert count_for(Worker) == 1
    end
  end

  describe "running the queued job" do
    test "delivers a digital purchase and grants its access code", ctx do
      {order, variant} = checkout(ctx.buyer, ctx.category, product_type: :digital)
      capture!(ctx.buyer, order, variant)

      assert [:ok] = drain_results(Worker)

      [fulfillment] = Repo.all(FulfillmentRecord)
      assert fulfillment.status == :fulfilled
      assert fulfillment.delivered_at

      entitlement = Repo.preload(fulfillment, :entitlement).entitlement
      assert entitlement.status == :active

      # The order settles once its only line is delivered.
      assert Repo.get!(Order, order.id).status == :completed
    end

    test "delivers an AI purchase with exactly its credits", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 40})

      capture!(ctx.buyer, order, variant)
      assert [:ok] = drain_results(Worker)

      [fulfillment] = Repo.all(FulfillmentRecord)
      assert fulfillment.status == :fulfilled

      entitlement = Repo.preload(fulfillment, :entitlement).entitlement
      assert entitlement.status == :active

      # Credits come from the snapshotted config, not multiplied by quantity.
      balance = Repo.one(CreditBalance)
      assert balance.granted == 40
      assert balance.consumed == 0
      assert Repo.get!(Order, order.id).status == :completed
    end

    test "the delivered AI purchase is immediately usable by the buyer", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 3})

      capture!(ctx.buyer, order, variant)
      assert [:ok] = drain_results(Worker)

      [fulfillment] = Repo.all(FulfillmentRecord)
      entitlement = Repo.preload(fulfillment, :entitlement).entitlement

      # The grant authorizes AI access and spends from the delivered balance.
      Req.Test.stub(:nexus_ai, success_completion_stub("hi there"))
      assert {:ok, _completion} = Cass.Ai.complete(ctx.buyer, entitlement.id, "hi there")
      assert Repo.one(CreditBalance).consumed == 1
    end
  end

  describe "unsupported kinds stay manual" do
    test "an SMM purchase is left pending and unqueued", ctx do
      {order, variant} = checkout(ctx.buyer, ctx.category, product_type: :smm)
      capture!(ctx.buyer, order, variant)

      # The delivery is recorded, but there is nothing to automate it.
      assert [fulfillment] = Repo.all(FulfillmentRecord)
      assert fulfillment.kind == :smm
      assert fulfillment.status == :pending
      assert count_for(Worker) == 0

      # And it is not complete: the purchase is still owed.
      assert Repo.get!(Order, order.id).status == :paid
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a service purchase is left pending and unqueued", ctx do
      {order, variant} = checkout(ctx.buyer, ctx.category, product_type: :service)
      capture!(ctx.buyer, order, variant)

      [fulfillment] = Repo.all(FulfillmentRecord)
      assert fulfillment.kind == :manual
      assert fulfillment.status == :pending
      assert count_for(Worker) == 0
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "a mixed order queues only the automatable line", ctx do
      {_d, digital} = published_variant_fixture(ctx.category, product_type: :digital)
      {_s, service} = published_variant_fixture(ctx.category, product_type: :service)

      {:ok, order} =
        Orders.create_order(ctx.buyer, [
          %{product_variant_id: digital.id, quantity: 1},
          %{product_variant_id: service.id, quantity: 1}
        ])

      # Both lines together are what the capture must be for.
      total =
        Repo.get!(Cass.Catalog.ProductVariant, digital.id).price_cents +
          Repo.get!(Cass.Catalog.ProductVariant, service.id).price_cents

      assert {:ok, %{payment: payment}} = init_payment(ctx.buyer, order)
      deliver_capture!(payment, total)

      assert Repo.aggregate(FulfillmentRecord, :count) == 2

      # Exactly one job: the manual line must never be automated.
      assert count_for(Worker) == 1
      [fulfillment] = Repo.all(FulfillmentRecord) |> Enum.filter(&(&1.kind == :digital))
      assert [%{"fulfillment_id" => id}] = args_for(Worker)
      assert id == fulfillment.id

      assert [:ok] = drain_results(Worker)
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :fulfilled

      # The order still owes the manual line, so it is not complete.
      assert Repo.get!(Order, order.id).status == :paid
      assert Repo.aggregate(Entitlement, :count) == 1
    end
  end

  describe "duplicate execution cannot double-deliver" do
    test "running the queued job repeatedly grants and issues once", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 7})

      capture!(ctx.buyer, order, variant)

      # Drain once, then re-queue the same work by hand several times.
      assert [:ok] = drain_results(Worker)
      assert Repo.aggregate(Entitlement, :count) == 1

      [fulfillment] = Repo.all(FulfillmentRecord)

      results =
        1..5
        |> Enum.map(fn _ ->
          Worker.perform(%Oban.Job{args: %{"fulfillment_id" => fulfillment.id}})
        end)

      assert Enum.all?(results, &(&1 == :ok))
      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1
      assert Repo.one(CreditBalance).granted == 7
    end

    test "a worker crash between claim and delivery is recovered by the sweep", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 15})

      capture!(ctx.buyer, order, variant)
      [fulfillment] = Repo.all(FulfillmentRecord)

      # The worker claimed the row, then the process died before delivering.
      claim!(fulfillment)
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0

      # Nothing was queued by the crash, so the sweep is what saves the purchase.
      age_fulfillment(fulfillment.id, 3600)
      assert Cass.Fulfillment.RecoverySweep.sweep() == 1

      # Both the original queued job and the sweep's reclaim are drained. The
      # original reports contention (the row is `:processing` and it was not
      # enqueued as a reclaim); the reclaim is what delivers.
      assert [{:error, :contended}, :ok] = drain_results(Worker)

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :fulfilled
      assert Repo.one(CreditBalance).granted == 15
      assert Repo.get!(Order, order.id).status == :completed
    end
  end

  describe "buyer-visible state after asynchronous delivery" do
    test "the purchase page shows the delivered purchase once the job has run", ctx do
      {order, variant} =
        checkout(ctx.buyer, ctx.category, product_type: :ai, config: %{"credits" => 4})

      capture!(ctx.buyer, order, variant)

      # Before the job runs, the buyer owns a pending delivery and no grant.
      assert [pending] = Fulfillment.list_for_customer(ctx.buyer)
      assert pending.status == :pending
      assert Entitlements.list_for_customer(ctx.buyer) == []

      assert [:ok] = drain_results(Worker)

      assert [delivered] = Fulfillment.list_for_customer(ctx.buyer)
      assert delivered.status == :fulfilled
      assert [granted] = Entitlements.list_for_customer(ctx.buyer)
      assert granted.status == :active
    end
  end

  defp success_completion_stub(text) do
    fn conn ->
      Req.Test.json(conn, %{
        "id" => "chatcmpl-test",
        "model" => "fast",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]
      })
    end
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
          "id" => 1
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
        "paid_at" => "2026-10-01T12:00:00.000Z",
        "channel" => "card"
      }
    })
  end

  defp sign(body), do: Base.encode16(:crypto.mac(:hmac, :sha512, @secret_key, body), case: :lower)
end
