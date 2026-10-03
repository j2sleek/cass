defmodule Cass.Fulfillment.RecoverySweepTest do
  use Cass.DataCase, async: false

  @moduledoc """
  Tests for the periodic abandoned-fulfillment sweep.

  The sweep exists to close one specific hole: a `:processing` row whose worker
  died is a paid purchase with nothing left in the queue to deliver it. These
  tests cover the staleness threshold, the re-enqueue, and the guarantee that
  reclaiming can never double-grant.
  """

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures
  import Cass.Jobs

  alias Cass.Accounts.Scope
  alias Cass.Ai.CreditBalance
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Fulfillment.RecoverySweep
  alias Cass.Fulfillment.Worker
  alias Cass.Repo

  @stale_seconds 3600

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

  describe "the staleness threshold" do
    test "is configurable and defaults to 15 minutes" do
      # config/test.exs lowers it so these tests stay fast and deterministic.
      assert RecoverySweep.abandoned_after_seconds() == 60

      # This test mutates process-global application env, so the configured value
      # is restored afterwards. Without that, the 60s threshold from
      # config/test.exs would be gone for every test that runs later in this VM.
      configured = Application.get_env(:cass, Cass.Fulfillment)
      on_exit(fn -> Application.put_env(:cass, Cass.Fulfillment, configured) end)

      Application.put_env(:cass, Cass.Fulfillment, abandoned_after_seconds: 900)
      assert RecoverySweep.abandoned_after_seconds() == 900

      Application.delete_env(:cass, Cass.Fulfillment)
      assert RecoverySweep.abandoned_after_seconds() == 900
    end

    test "ignores a pending delivery that was never claimed" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      age_fulfillment(fulfillment.id, @stale_seconds)

      assert RecoverySweep.sweep() == 0
      assert args_for(Worker) == []
    end

    test "ignores a recently claimed delivery that may still be running" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)

      assert RecoverySweep.sweep() == 0
      assert args_for(Worker) == []
    end

    test "reclaims a claim that was abandoned long ago" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      assert RecoverySweep.sweep() == 1

      assert [%{"fulfillment_id" => id}] = args_for(Worker)
      assert id == fulfillment.id
    end
  end

  describe "reclaiming never duplicates a grant" do
    test "the reclaimed job delivers a purchase nobody had delivered" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      assert RecoverySweep.sweep() == 1
      assert [:ok] = drain_results(Worker)

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      assert delivered.status == :fulfilled
      assert Repo.preload(delivered, :entitlement).entitlement.status == :active
      assert Repo.one(CreditBalance).granted == 5
    end

    test "a reclaim of an already delivered purchase grants nothing extra" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      assert :ok = Worker.perform(%Oban.Job{args: %{"fulfillment_id" => fulfillment.id}})

      # A `:fulfilled` row is terminal, so there is nothing to reclaim at all.
      age_fulfillment(fulfillment.id, @stale_seconds)
      assert RecoverySweep.sweep() == 0
      assert drain_results(Worker) == []

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1
    end

    test "concurrent sweeps cannot double-grant" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      # Two sweeps at once, as a slow tick overlapping the next one.
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> RecoverySweep.sweep() end) end)
        |> Task.await_many(:infinity)

      assert Enum.all?(results, &(&1 in [0, 1]))

      # Whatever got queued, running it grants exactly one entitlement and one
      # balance.
      Enum.each(drain_results(Worker), fn _ -> :ok end)

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end

    test "repeated sweeps of the same row stay idempotent" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      # Two sweeps before the job runs both *see* the abandoned row, but the
      # unique-job constraint collapses the second into the first: only one job
      # is inserted, so only the first sweep reports work done.
      assert RecoverySweep.sweep() == 1
      assert RecoverySweep.sweep() == 0
      assert count_for(Worker) == 1

      assert [:ok] = drain_results(Worker)

      # Once delivered the row is terminal, so there is nothing left to reclaim.
      assert RecoverySweep.sweep() == 0

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end
  end

  describe "the reclaimed job runs the same checks as a first delivery" do
    test "a reclaimed SMM purchase is refused, not delivered" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      assert RecoverySweep.sweep() == 1
      assert [{:cancel, :unsupported}] = drain_results(Worker)

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a reclaimed purchase whose order is no longer paid is refused" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      Repo.update_all(from(o in Cass.Orders.Order, where: o.id == ^order.id),
        set: [status: "cancelled"]
      )

      assert RecoverySweep.sweep() == 1
      assert [{:cancel, :order_not_paid}] = drain_results(Worker)

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.aggregate(CreditBalance, :count) == 0
    end
  end

  describe "perform/1" do
    test "runs the sweep and reports the count" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      assert {:ok, 1} = RecoverySweep.perform(%Oban.Job{})
      assert [%{"fulfillment_id" => id}] = args_for(Worker)
      assert id == fulfillment.id
    end

    test "succeeds with nothing to do" do
      assert {:ok, 0} = RecoverySweep.perform(%Oban.Job{})
    end
  end

  describe "abandoned_fulfillment_ids/2" do
    test "returns only stale processing rows, oldest first" do
      buyer = Scope.for_user(user_fixture())

      {_order, stale_one} = pending_fulfillment(buyer, category_fixture())
      {_order, stale_two} = pending_fulfillment(buyer, category_fixture())
      {_order, fresh} = pending_fulfillment(buyer, category_fixture())

      claim!(stale_one)
      claim!(stale_two)
      claim!(fresh)

      # stale_two is the older row.
      age_fulfillment(stale_two.id, @stale_seconds + 600)
      age_fulfillment(stale_one.id, @stale_seconds)
      age_fulfillment(fresh.id, 5)

      cutoff =
        DateTime.utc_now() |> DateTime.add(-RecoverySweep.abandoned_after_seconds(), :second)

      assert RecoverySweep.abandoned_fulfillment_ids(cutoff) == [stale_two.id, stale_one.id]
    end

    test "never returns a terminal row" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, _delivered} = Fulfillment.mark_fulfilled(claim!(fulfillment))
      age_fulfillment(fulfillment.id, @stale_seconds)

      cutoff =
        DateTime.utc_now() |> DateTime.add(-RecoverySweep.abandoned_after_seconds(), :second)

      assert RecoverySweep.abandoned_fulfillment_ids(cutoff) == []
    end
  end

  describe "log hygiene" do
    test "the sweep log carries no customer data" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, @stale_seconds)

      log =
        with_log_level(:info, fn ->
          assert RecoverySweep.sweep() == 1
        end)

      assert log =~ "re-enqueued abandoned fulfillments"
      refute log =~ buyer.user.email
    end
  end

  defp with_log_level(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
