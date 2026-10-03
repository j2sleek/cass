defmodule Cass.Orders.MarkOrderCompletedTest do
  use Cass.DataCase, async: false

  @moduledoc """
  Tests for `Cass.Orders.mark_order_completed/1`.

  The rule under test is deliberately conservative: an order is complete only
  when *every* delivery it owes is `:fulfilled`. A terminal-but-unsuccessful line
  (`:failed`, `:cancelled`) does not count, so a partially fulfilled order stays
  `:paid` and remains repairable by support.
  """

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Payments
  alias Cass.Repo

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  defp order_with_lines(buyer, category, types) do
    variants =
      Enum.map(types, fn type ->
        {_product, variant} = published_variant_fixture(category, product_type: type)
        variant
      end)

    mixed_paid_order_fixture(buyer, variants)
  end

  # Captures a payment for `order` the way a buyer does, through the real
  # Payments boundary with a stubbed provider, and asserts the capture landed.
  # Returns the `:succeeded` payment row.
  defp captured_payment(buyer, order, amount_cents) do
    Req.Test.stub(:paystack, success_init_stub())

    assert {:ok, %{payment: payment}} = Payments.initialize_payment(buyer, order.id)
    body = charge_payload(payment.provider_reference, "success", amount_cents, "USD")

    assert :ok =
             Payments.handle_webhook(:paystack, body, %{"x-paystack-signature" => sign(body)})

    Repo.get!(Cass.Payments.Payment, payment.id)
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

  defp fulfill!(fulfillment) do
    {:ok, processing} = Fulfillment.mark_processing(fulfillment)
    {:ok, delivered} = Fulfillment.mark_fulfilled(processing)
    delivered
  end

  describe "a fully delivered order" do
    test "moves from paid to completed" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)

      fulfill!(fulfillment)

      assert {:ok, completed} = Orders.mark_order_completed(order.id)
      assert completed.status == :completed
    end

    test "completes a multi-line order only when the last line lands" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :digital, :digital])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)

      [first, second, third] = fulfillments

      fulfill!(first)
      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)

      fulfill!(second)
      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid

      fulfill!(third)
      assert {:ok, order} = Orders.mark_order_completed(order.id)
      assert order.status == :completed
    end
  end

  describe "a partially fulfilled order" do
    test "stays paid while any line is still pending" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :service])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [digital, manual] = Enum.sort_by(fulfillments, & &1.kind, :desc)

      fulfill!(digital)

      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid

      # The delivered line still granted its entitlement: a partial delivery is
      # not a rollback.
      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.get!(Cass.Fulfillment.Fulfillment, manual.id).status == :pending
    end

    test "stays paid while a line is still processing" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :digital])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [first, second] = fulfillments

      fulfill!(first)
      {:ok, _claimed} = Fulfillment.mark_processing(second)

      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "does not treat a failed line as complete" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :digital])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [first, second] = fulfillments

      fulfill!(first)
      {:ok, processing} = Fulfillment.mark_processing(second)
      {:ok, _failed} = Fulfillment.mark_failed(processing, "provider refused")

      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "does not treat a cancelled line as complete" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :service])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [digital, manual] = Enum.sort_by(fulfillments, & &1.kind, :desc)

      fulfill!(digital)
      {:ok, _cancelled} = Fulfillment.mark_cancelled(manual)

      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid
    end

    test "a failed line can still be retried and then complete the order" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:ai, :ai])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [first, second] = fulfillments

      fulfill!(first)
      {:ok, processing} = Fulfillment.mark_processing(second)
      {:ok, _failed} = Fulfillment.mark_failed(processing, "transient outage")
      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)

      # The retry succeeds, and now the order may complete.
      fulfill!(second)
      assert {:ok, order} = Orders.mark_order_completed(order.id)
      assert order.status == :completed
      assert Repo.aggregate(Entitlement, :count) == 2
    end
  end

  describe "idempotency and refusals" do
    test "an already completed order is returned unchanged" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      fulfill!(fulfillment)

      assert {:ok, first} = Orders.mark_order_completed(order.id)
      assert {:ok, second} = Orders.mark_order_completed(order.id)
      assert second.status == :completed
      assert second.updated_at == first.updated_at
    end

    test "refuses an order that was never paid" do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category_fixture(), product_type: :digital)
      order = order_fixture(buyer, variant)

      assert {:error, :not_paid} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :awaiting_payment
    end

    test "refuses a missing order" do
      assert {:error, :order_not_found} = Orders.mark_order_completed(999_999)
      assert {:error, :order_not_found} = Orders.mark_order_completed("not-an-id")
    end

    test "refuses an order whose deliveries do not exist yet" do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category_fixture(), product_type: :digital)
      order = paid_order_fixture(buyer, variant, 1)

      # Paid, but `create_for_paid_order/1` has not run, so the order owes
      # nothing recorded and cannot be declared complete.
      assert Repo.aggregate(Cass.Fulfillment.Fulfillment, :count) == 0
      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :paid
    end
  end

  describe "payment and refund state are preserved" do
    test "a completed order keeps its succeeded payment" do
      buyer = Scope.for_user(user_fixture())
      category = category_fixture()

      {_product, variant} = published_variant_fixture(category, product_type: :digital)
      order = order_fixture(buyer, variant)
      payment = captured_payment(buyer, order, 499)

      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order.id)
      fulfill!(fulfillment)
      assert {:ok, _} = Orders.mark_order_completed(order.id)

      # Completing an order is not a refund: the payment stays `:succeeded`.
      assert Repo.get!(Cass.Payments.Payment, payment.id).status == :succeeded
      assert Repo.get!(Order, order.id).status == :completed
    end
  end

  describe "concurrency" do
    test "concurrent completion attempts land exactly one completed order" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :digital])
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      Enum.each(fulfillments, &fulfill!/1)

      results =
        1..6
        |> Enum.map(fn _ -> Task.async(fn -> Orders.mark_order_completed(order.id) end) end)
        |> Task.await_many(:infinity)

      # Every caller sees success — the transition is idempotent — and the row
      # ends up completed exactly once.
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Repo.get!(Order, order.id).status == :completed
      assert Repo.aggregate(Entitlement, :count) == 2
    end

    test "a stale completion cannot resurrect a cancelled order" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      fulfill!(fulfillment)

      # A refund/cancel wins the race between the fulfillment completing and the
      # completion being applied.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "cancelled"])

      assert {:error, :not_paid} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :cancelled
    end

    test "two workers completing the last two lines at once both land correctly" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital, :digital])
      {:ok, [first, second]} = Fulfillment.create_for_paid_order(order)

      # Each line is delivered, and the completion is attempted, from its own
      # process — the real shape of two Oban jobs finishing together.
      tasks =
        [first, second]
        |> Enum.map(fn fulfillment ->
          Task.async(fn ->
            fulfill!(fulfillment)
            Orders.mark_order_completed(order.id)
          end)
        end)

      results = Task.await_many(tasks, :infinity)

      # Both succeed: the winner transitions, the loser sees `:completed` and
      # returns the same order. Neither observes a half-applied state.
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Repo.get!(Order, order.id).status == :completed

      # And each line was delivered exactly once: two grants, not three.
      assert Repo.aggregate(FulfillmentRecord, :count) == 2
      assert Repo.aggregate(Entitlement, :count) == 2
    end

    test "a completion racing a cancel resolves to exactly one outcome" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      fulfill!(fulfillment)

      complete = Task.async(fn -> Orders.mark_order_completed(order.id) end)

      cancel =
        Task.async(fn ->
          Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "cancelled"])
        end)

      assert {:ok, _} = Task.await(complete, :infinity)
      assert {1, _} = Task.await(cancel, :infinity)

      # Whichever won, the row is in exactly one state and never flips back.
      final = Repo.get!(Order, order.id)
      assert final.status in [:completed, :cancelled]

      # And re-running completion after a cancel still refuses.
      if final.status == :cancelled do
        assert {:error, :not_paid} = Orders.mark_order_completed(order.id)
        assert Repo.get!(Order, order.id).status == :cancelled
      end
    end
  end

  describe "the paid family is not one state here" do
    test "an order in :processing is never completed by this function" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      fulfill!(fulfillment)

      # Every line is delivered, so the only thing blocking completion is that
      # this order is `:processing` rather than `:paid`.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "processing"])

      assert {:error, :not_paid} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :processing
    end

    test "an order that reached :completed stays :completed" do
      buyer = Scope.for_user(user_fixture())
      order = order_with_lines(buyer, category_fixture(), [:digital])
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      fulfill!(fulfillment)

      assert {:ok, completed} = Orders.mark_order_completed(order.id)
      assert completed.status == :completed

      # Idempotent, and still refuses nothing about its own end state.
      assert {:ok, again} = Orders.mark_order_completed(order.id)
      assert again.id == order.id
      assert again.status == :completed
    end
  end

  describe "after a real payment" do
    test "an order with a delivered AI purchase completes and keeps its credits" do
      buyer = Scope.for_user(user_fixture())
      category = category_fixture()

      {_product, variant} =
        published_variant_fixture(category, product_type: :ai, config: %{"credits" => 12})

      order = order_fixture(buyer, variant)
      payment = captured_payment(buyer, order, 499)

      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order.id)
      fulfill!(fulfillment)

      assert {:ok, completed} = Orders.mark_order_completed(order.id)
      assert completed.status == :completed

      balance = Repo.one(Cass.Ai.CreditBalance)
      assert balance.granted == 12
      assert Repo.get!(Cass.Payments.Payment, payment.id).status == :succeeded
    end
  end

  describe "end to end" do
    test "the webhook chain leaves a paid order pending until a delivery lands" do
      buyer = Scope.for_user(user_fixture())
      category = category_fixture()

      {_product, variant} = published_variant_fixture(category, product_type: :digital)
      order = order_fixture(buyer, variant)

      # An unpaid order refuses fulfillment outright.
      assert {:error, _changeset} = Fulfillment.create_for_paid_order(order.id)

      # A verified capture pays the order and creates its deliveries at once.
      payment = captured_payment(buyer, order, 499)
      assert Repo.get!(Order, order.id).status == :paid
      assert payment.status == :succeeded

      # The order now owes a delivery, so it is not complete yet.
      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order.id)
      [fulfillment] = fulfillments
      assert {:error, :not_complete} = Orders.mark_order_completed(order.id)

      fulfill!(fulfillment)
      assert {:ok, _} = Orders.mark_order_completed(order.id)
      assert Repo.get!(Order, order.id).status == :completed
    end
  end
end
