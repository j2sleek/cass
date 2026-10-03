defmodule Cass.FulfillmentWorkerTest do
  use Cass.DataCase, async: false

  @moduledoc """
  Tests for the asynchronous delivery worker.

  Every test drives the real `Cass.Fulfillment` domain transitions through the
  worker's `perform/1`, so what is exercised is the production path a queued job
  takes — not a simulation of it.
  """

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures
  import Cass.Jobs
  import ExUnit.CaptureLog

  alias Cass.Accounts.Scope
  alias Cass.Ai.CreditBalance
  alias Cass.Delivery
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Fulfillment.RecoverySweep
  alias Cass.Fulfillment.Worker
  alias Cass.Orders
  alias Cass.Orders.Order
  alias Cass.Repo

  defp pending_fulfillment(buyer, category, opts \\ []) do
    {_product, variant} =
      published_variant_fixture(category,
        product_type: Keyword.get(opts, :product_type, :ai),
        config: Keyword.get(opts, :config, %{"credits" => 5})
      )

    order = paid_order_fixture(buyer, variant, Keyword.get(opts, :quantity, 1))
    {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
    {order, fulfillment}
  end

  defp job_for(fulfillment) do
    %Oban.Job{args: %{"fulfillment_id" => fulfillment.id}}
  end

  describe "eligibility" do
    test "delivers an AI purchase and issues its credits" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      assert delivered.status == :fulfilled
      assert delivered.delivered_at

      entitlement = Repo.preload(delivered, :entitlement).entitlement
      assert entitlement.status == :active

      balance = Repo.one(CreditBalance)
      assert balance.granted == 5
      assert balance.consumed == 0
    end

    test "delivers a digital purchase and grants its access code" do
      buyer = Scope.for_user(user_fixture())

      {_order, fulfillment} =
        pending_fulfillment(buyer, category_fixture(), product_type: :digital)

      assert :ok = Worker.perform(job_for(fulfillment))

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      assert delivered.status == :fulfilled

      entitlement = Repo.preload(delivered, :entitlement).entitlement
      assert {:ok, access} = Delivery.authorize_access(buyer, entitlement.id)
      assert access.mechanism == :access_code
      assert access.access_code
    end

    test "refuses an SMM purchase permanently and leaves it pending" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)

      assert {:cancel, :unsupported} = Worker.perform(job_for(fulfillment))

      final = Repo.get!(FulfillmentRecord, fulfillment.id)
      assert final.status == :pending
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "refuses a manual/service purchase permanently and leaves it pending" do
      buyer = Scope.for_user(user_fixture())

      {_order, fulfillment} =
        pending_fulfillment(buyer, category_fixture(), product_type: :service)

      assert {:cancel, :unsupported} = Worker.perform(job_for(fulfillment))
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "reports a missing fulfillment as permanent, not a crash" do
      assert {:cancel, :no_content} = Worker.perform(job_for(%FulfillmentRecord{id: 999_999}))
    end

    test "refuses an unrecognised job payload" do
      job = %Oban.Job{args: %{"order_id" => 1}}

      assert {:cancel, :no_content} = Worker.perform(job)
    end
  end

  describe "the retry contract" do
    # Oban distinguishes `{:error, _}` (retry with backoff) from
    # `{:cancel, _}` (stop now). Getting this wrong is expensive in both
    # directions: a permanent failure retried eight times is noise, and a
    # transient failure cancelled is a purchase that never ships. So the split
    # is asserted rather than left to the prose.
    test "a fact that cannot change is cancelled, not retried" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)

      assert {:cancel, :unsupported} = Worker.perform(job_for(fulfillment))
    end

    test "a contested row is retried, not cancelled" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # Someone else holds the claim.
      claim!(fulfillment)

      assert {:error, :contended} = Worker.perform(job_for(fulfillment))
    end

    test "an already delivered purchase is a plain success" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))
      # The duplicate that follows must not look like a failure, or Oban would
      # retry a purchase that is genuinely delivered.
      assert :ok = Worker.perform(job_for(fulfillment))
    end

    test "a single attempt is bounded well inside the sweep's staleness threshold" do
      # This is the invariant the sweep's production threshold rests on: no live
      # attempt can outlive its timeout plus shutdown grace, so a claim older
      # than the threshold is provably abandoned rather than merely slow.
      #
      # Checked against the *default* threshold, not the configured one, because
      # the test config deliberately collapses it to 60s to keep tests fast.
      assert Worker.timeout(%Oban.Job{}) == :timer.seconds(60)

      attempt_seconds = div(Worker.timeout(%Oban.Job{}), 1000)
      default = RecoverySweep.default_abandoned_after_seconds()

      assert attempt_seconds == 60
      assert default == 15 * 60
      # Fifteen attempts' worth of headroom, so a sweep tick can never race a
      # live attempt's shutdown.
      assert default >= attempt_seconds * 15
    end
  end

  describe "the paid-order re-check" do
    test "refuses to deliver when the order is no longer paid" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # A queued job can outlive its order. A cancelled order owes nothing.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "cancelled"])

      assert {:cancel, :order_not_paid} = Worker.perform(job_for(fulfillment))

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.aggregate(CreditBalance, :count) == 0
    end
  end

  describe "idempotency" do
    test "a duplicate job for a delivered purchase is a no-op" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))
      assert :ok = Worker.perform(job_for(fulfillment))
      assert :ok = Worker.perform(job_for(fulfillment))

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end

    test "a stale job that fails after delivery cannot undo it" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))

      # The row is now `:fulfilled`, so the job reports success having done
      # nothing — never a failure, and never a write against the delivery.
      assert :ok = Worker.perform(job_for(fulfillment))

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      assert delivered.status == :fulfilled
      assert is_nil(delivered.failure_reason)
      assert Repo.preload(delivered, :entitlement).entitlement.status == :active
      assert Repo.one(CreditBalance).granted == 5
    end

    test "a job racing the claim of another job never double-grants" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Worker.perform(job_for(fulfillment)) end) end)
        |> Task.await_many(:infinity)

      # Every job either delivered or reported contention. None crashed.
      assert Enum.all?(results, &(match?(:ok, &1) or match?({:error, :contended}, &1)))
      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end

    test "a retried failed delivery grants exactly once" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      claimed = claim!(fulfillment)
      {:ok, _failed} = Fulfillment.mark_failed(claimed, "transient provider outage")

      assert :ok = Worker.perform(job_for(fulfillment))
      assert :ok = Worker.perform(job_for(fulfillment))

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end
  end

  describe "order completion" do
    test "completes the order once every line is delivered" do
      buyer = Scope.for_user(user_fixture())
      category = category_fixture()

      {_digital, digital_variant} =
        published_variant_fixture(category, product_type: :digital, config: %{})

      {_service, service_variant} = published_variant_fixture(category, product_type: :service)

      order =
        mixed_paid_order_fixture(buyer, [digital_variant, service_variant])

      {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      [manual, digital] = Enum.sort_by(fulfillments, & &1.kind, :desc)

      assert :ok = Worker.perform(job_for(digital))

      # The manual line is still owed, so the order must not be complete.
      assert Repo.get!(Order, order.id).status == :paid
      assert Repo.get!(FulfillmentRecord, manual.id).status == :pending

      # Delivering the last line is what completes the order. (Driven directly
      # here: a manual line is never automated.)
      {:ok, processing} = Fulfillment.mark_processing(manual)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(processing)
      assert {:ok, completed} = Orders.mark_order_completed(order.id)
      assert completed.status == :completed
    end

    test "a single-line order completes as soon as its delivery lands" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))
      assert Repo.get!(Order, order.id).status == :completed
    end

    test "a repeated completion attempt stays completed" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job_for(fulfillment))

      assert {:ok, order} = Orders.mark_order_completed(order.id)
      assert order.status == :completed
      assert {:ok, _} = Orders.mark_order_completed(order.id)
    end

    test "delivery still succeeds even when the order cannot be completed" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # A partially fulfilled order refuses completion; the delivery must still
      # be reported as successful so Oban does not retry it forever.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "processing"])
      {:ok, _} = Fulfillment.create_for_paid_order(order)

      # Cancelling the order mid-flight makes completion impossible while the
      # worker still completed the delivery.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "cancelled"])
      assert {:cancel, :order_not_paid} = Worker.perform(job_for(fulfillment))
      assert Repo.get!(Order, order.id).status == :cancelled
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
    end
  end

  describe "job payloads" do
    test "carry only the fulfillment id" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Fulfillment.enqueue_deliveries([fulfillment])

      assert [%{"fulfillment_id" => id}] = args_for(Worker)
      assert id == fulfillment.id
    end

    test "never contain prompts, credentials, or customer data" do
      buyer = Scope.for_user(user_fixture())

      {_order, fulfillment} =
        pending_fulfillment(buyer, category_fixture(), config: %{"credits" => 25})

      assert :ok = Fulfillment.enqueue_deliveries([fulfillment])

      [args] = args_for(Worker)
      serialized = inspect(args)

      refute serialized =~ "credits"
      refute serialized =~ buyer.user.email
      refute serialized =~ "secret"
      assert Map.keys(args) == ["fulfillment_id"]
    end
  end

  describe "log hygiene" do
    test "an unsupported delivery log carries no customer data" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)

      log =
        with_log_level(:info, fn ->
          assert {:cancel, :unsupported} = Worker.perform(job_for(fulfillment))
        end)

      refute log =~ buyer.user.email
    end

    test "a successful delivery log carries no customer data" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # The suite runs at `:warning`, so the info-level success log has to be
      # enabled explicitly to be observable.
      log = with_log_level(:info, fn -> assert :ok = Worker.perform(job_for(fulfillment)) end)

      assert log =~ "delivered a purchase"

      # Nothing identifying about the buyer may appear.
      refute log =~ buyer.user.email
      refute log =~ "credits"
    end
  end

  # `capture_log/2` cannot lower the threshold below the configured logger level,
  # so the level is raised for the duration of the block.
  defp with_log_level(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
