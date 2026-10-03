defmodule Cass.Fulfillment.QueueSecurityTest do
  use Cass.DataCase, async: false

  @moduledoc """
  Security properties of the asynchronous delivery queue.

  These are the claims that matter most once work leaves the request cycle:

    * **no privilege escalation** — the queue carries an opaque id, and every
      write still goes through the domain boundaries that were already
      authorized. Nothing in a job payload can make the worker skip a check.
    * **no data leakage** — no prompt, credential, customer email, or order
      snapshot reaches `oban_jobs`, and no such data is logged.
    * **no delivery for unpaid orders** — a queued job re-verifies the paid
      order on every run, so a cancelled or refunded purchase never grants.
    * **no grant after cancellation** — cancelling a delivery mid-flight cannot
      be undone by an in-flight job.
  """

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures
  import Cass.Jobs

  alias Cass.Accounts.Scope
  alias Cass.Ai.CreditBalance
  alias Cass.Delivery
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Fulfillment.Worker
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

  defp job(id, extra \\ %{}) do
    %Oban.Job{args: Map.merge(%{"fulfillment_id" => id}, extra)}
  end

  describe "job payloads are opaque" do
    test "contain exactly one integer id and nothing else" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Fulfillment.enqueue_deliveries([fulfillment])

      [args] = args_for(Worker)
      assert args == %{"fulfillment_id" => fulfillment.id}
      assert is_integer(args["fulfillment_id"])
    end

    test "the whole oban_jobs row is free of identifying data" do
      buyer = Scope.for_user(user_fixture())

      {_order, fulfillment} =
        pending_fulfillment(buyer, category_fixture(), config: %{"credits" => 99})

      assert :ok = Fulfillment.enqueue_deliveries([fulfillment])

      [job_row] = all_jobs()
      serialized = inspect(job_row)

      refute serialized =~ buyer.user.email
      refute serialized =~ "credits"
      refute serialized =~ "secret"
      refute serialized =~ to_string(buyer.user.id)
      # The job is for the fulfillment, and carries nothing else.
      assert job_row.args == %{"fulfillment_id" => fulfillment.id}
    end

    test "a malformed payload is refused without acting on it" do
      # No fulfillment id at all.
      assert {:cancel, :no_content} = Worker.perform(%Oban.Job{args: %{}})
      assert {:cancel, :no_content} = Worker.perform(%Oban.Job{args: %{"id" => 1}})

      # A non-integer id cannot reach `Repo.get/2`.
      assert {:cancel, :no_content} = Worker.perform(%Oban.Job{args: %{"fulfillment_id" => "1"}})
      assert {:cancel, :no_content} = Worker.perform(%Oban.Job{args: %{"fulfillment_id" => nil}})

      assert Repo.aggregate(FulfillmentRecord, :count) == 0
      assert Repo.aggregate(Entitlement, :count) == 0
    end
  end

  describe "the paid-order check cannot be skipped" do
    test "a job cannot deliver a purchase whose order was cancelled" do
      buyer = Scope.for_user(user_fixture())
      {order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # A refund/cancel wins before the queue runs.
      Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [status: "cancelled"])

      assert {:cancel, :order_not_paid} = Worker.perform(job(fulfillment.id))

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.aggregate(CreditBalance, :count) == 0
    end

    test "a job cannot deliver a purchase whose order was never paid" do
      buyer = Scope.for_user(user_fixture())
      category = category_fixture()

      {_product, variant} =
        published_variant_fixture(category, product_type: :ai, config: %{"credits" => 5})

      {:ok, order} =
        Cass.Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: 1}])

      # Fabricate a delivery row for an unpaid order, the way a hostile or
      # corrupted queue payload would try to.
      {:ok, fulfillment} =
        Repo.insert(%FulfillmentRecord{
          kind: :ai,
          product_type: :ai,
          status: :pending,
          order_id: order.id,
          order_item_id: hd(order.order_items).id,
          user_id: buyer.user.id
        })

      assert {:cancel, :order_not_paid} = Worker.perform(job(fulfillment.id))
      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.aggregate(CreditBalance, :count) == 0
    end
  end

  describe "a granted entitlement is never silently revoked by a job" do
    test "a failed job cannot revoke or hide a delivered purchase" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job(fulfillment.id))

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      entitlement = Repo.preload(delivered, :entitlement).entitlement

      # `fulfillment` is a stale `:pending` copy: it was captured before the
      # worker delivered. A stale job reporting failure must be refused, both
      # from that copy and from a freshly read row.
      assert {:error, _changeset} = Fulfillment.mark_failed(fulfillment, "the worker died")

      assert {:error, _changeset} =
               Fulfillment.mark_failed(
                 Repo.get!(FulfillmentRecord, fulfillment.id),
                 "late failure"
               )

      assert {:error, _changeset} = Fulfillment.mark_cancelled(fulfillment)

      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :fulfilled
      assert Repo.reload(entitlement).status == :active
      assert {:ok, _access} = Delivery.authorize_access(buyer, entitlement.id)
    end

    test "cancelling a delivered purchase is still refused" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job(fulfillment.id))
      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)

      assert {:error, _changeset} = Fulfillment.mark_cancelled(delivered)

      entitlement = Repo.preload(delivered, :entitlement).entitlement
      assert entitlement.status == :active
      assert {:ok, _} = Delivery.authorize_access(buyer, entitlement.id)
    end
  end

  describe "the queue does not widen what a scope can read" do
    test "a job delivers for the order's own buyer, never another" do
      buyer = Scope.for_user(user_fixture())
      stranger = Scope.for_user(user_fixture())

      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert :ok = Worker.perform(job(fulfillment.id))
      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)

      entitlement = Repo.preload(delivered, :entitlement).entitlement

      # The buyer may exercise the grant; a stranger may not.
      assert {:ok, _} = Delivery.authorize_access(buyer, entitlement.id)
      assert {:error, _} = Delivery.authorize_access(stranger, entitlement.id)
      assert {:error, _} = Delivery.authorize_access(Scope.for_user(nil), entitlement.id)

      # And scope-based reads are still owner-or-admin.
      assert [_mine] = Fulfillment.list_for_customer(buyer)
      assert Fulfillment.list_for_customer(stranger) == []
    end

    test "the grant is owned by the order's user, not by anything in the job" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # A hostile payload cannot redirect the grant to another account: the only
      # input is a fulfillment id, and `user_id` is never read from args.
      assert :ok = Worker.perform(job(fulfillment.id, %{"user_id" => 999_999, "admin" => true}))

      delivered = Repo.get!(FulfillmentRecord, fulfillment.id)
      entitlement = Repo.preload(delivered, :entitlement).entitlement

      assert entitlement.user_id == buyer.user.id
      assert delivered.user_id == buyer.user.id
    end
  end

  describe "audit logs stay free of customer data" do
    test "delivery logs contain ids and kinds only" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      log = capture_at_info(fn -> assert :ok = Worker.perform(job(fulfillment.id)) end)

      assert log =~ "delivered a purchase"
      refute log =~ buyer.user.email
      refute log =~ "credits"
    end

    test "refusal logs contain ids and reasons only" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)

      log =
        capture_at_info(fn ->
          assert {:cancel, :unsupported} = Worker.perform(job(fulfillment.id))
        end)

      refute log =~ buyer.user.email
    end

    test "an unrecognised payload logs only the argument keys" do
      log =
        capture_at_warning(fn -> Worker.perform(%Oban.Job{args: %{"secret" => "hunter2"}}) end)

      assert log =~ "unrecognised job payload"
      assert log =~ "secret"
      # The *value* never reaches the log, only which keys were present.
      refute log =~ "hunter2"
    end

    test "the sweep logs counts, never customer data" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      claim!(fulfillment)
      age_fulfillment(fulfillment.id, 3600)

      log = capture_at_info(fn -> assert Cass.Fulfillment.RecoverySweep.sweep() == 1 end)

      assert log =~ "re-enqueued abandoned fulfillments"
      refute log =~ buyer.user.email
    end
  end

  describe "credits cannot be issued without a grant" do
    test "a balance exists only alongside its entitlement" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert Repo.aggregate(CreditBalance, :count) == 0

      assert :ok = Worker.perform(job(fulfillment.id))

      # Both halves, or neither: the balance is created in the same transaction
      # as the grant.
      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.aggregate(CreditBalance, :count) == 1

      balance = Repo.one(CreditBalance)
      entitlement = Repo.one(Entitlement)
      assert balance.entitlement_id == entitlement.id
      assert balance.granted == 5
    end

    test "an unsupported delivery never issues credits" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture(), product_type: :smm)

      assert {:cancel, :unsupported} = Worker.perform(job(fulfillment.id))

      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.aggregate(CreditBalance, :count) == 0
    end

    test "the entitlement list a buyer sees matches the queue's work" do
      buyer = Scope.for_user(user_fixture())
      {_order, _fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert Entitlements.list_for_customer(buyer) == []
      assert [_] = Repo.all(FulfillmentRecord)
    end
  end

  defp capture_at_info(fun), do: capture_at(:info, fun)

  defp capture_at_warning(fun), do: capture_at(:warning, fun)

  defp capture_at(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
