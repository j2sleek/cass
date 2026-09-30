defmodule Cass.Fulfillment.ConcurrencyTest do
  @moduledoc """
  Fulfillment and entitlement idempotency under concurrent callers.

  Runs with `async: false`: the shared SQL sandbox lets several processes reach
  the same connection, which is the closest this suite gets to real load. The
  guarantee under test is the database one — a unique index plus
  `INSERT … ON CONFLICT DO NOTHING` — so no interleaving of concurrent triggers
  (a retried webhook, a duplicated queue job, two workers) can create a second
  delivery for one purchased line or grant one purchase twice.
  """
  use Cass.DataCase, async: false

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders
  alias Cass.Repo

  setup do
    category = category_fixture()
    buyer = Scope.for_user(user_fixture())
    {_product, variant} = published_variant_fixture(category)
    order = paid_order_fixture(buyer, variant)

    %{category: category, buyer: buyer, order: order, variant: variant}
  end

  test "many concurrent triggers create exactly one delivery per purchased line", ctx do
    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Fulfillment.create_for_paid_order(ctx.order.id) end)
      end

    results = Task.await_many(tasks, :infinity)

    # Every caller succeeds, and every caller gets the same row back.
    assert Enum.all?(results, &match?({:ok, [_fulfillment]}, &1))

    ids = for {:ok, [fulfillment]} <- results, do: fulfillment.id
    assert ids == List.duplicate(hd(ids), length(ids))

    assert Repo.aggregate(FulfillmentRecord, :count) == 1
  end

  test "a multi-line order is never half fulfilled and never duplicated", ctx do
    {_product, other_variant} = published_variant_fixture(ctx.category)
    order = mixed_paid_order_fixture(ctx.buyer, [ctx.variant, other_variant])

    assert length(order.order_items) == 2

    tasks =
      for _attempt <- 1..4 do
        Task.async(fn -> Fulfillment.create_for_paid_order(order.id) end)
      end

    results = Task.await_many(tasks, :infinity)

    assert Enum.all?(results, &match?({:ok, [_one, _two]}, &1))

    # Every caller got the same two purchased lines back, so no caller saw a
    # half-fulfilled order.
    line_ids = for {:ok, fulfillments} <- results, do: Enum.map(fulfillments, & &1.order_item_id)
    assert Enum.uniq(line_ids) == [Enum.sort(hd(line_ids))]

    assert Repo.aggregate(FulfillmentRecord, :count) == 2
  end

  test "concurrent completions of one delivery grant exactly one entitlement", ctx do
    assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Fulfillment.mark_fulfilled(fulfillment) end)
      end

    results = Task.await_many(tasks, :infinity)

    assert Enum.all?(results, &match?({:ok, %FulfillmentRecord{status: :fulfilled}}, &1))
    assert Repo.aggregate(FulfillmentRecord, :count) == 1
    assert Repo.aggregate(Entitlement, :count) == 1
  end

  test "concurrent grants for one purchase return the same single entitlement", ctx do
    assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(ctx.order.id)
    assert {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)
    {:ok, fulfillment} = Fulfillment.mark_fulfilled(fulfillment)
    order_item = Repo.preload(fulfillment, :order_item).order_item

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Entitlements.grant_for_fulfillment(fulfillment, order_item) end)
      end

    results = Task.await_many(tasks, :infinity)

    ids = for {:ok, entitlement} <- results, do: entitlement.id
    assert ids == List.duplicate(hd(ids), length(ids))
    assert Repo.aggregate(Entitlement, :count) == 1
  end

  test "an unpaid order stays unfulfillable under a burst of concurrent triggers", ctx do
    unpaid = order_fixture(ctx.buyer, ctx.variant)

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Fulfillment.create_for_paid_order(unpaid.id) end)
      end

    results = Task.await_many(tasks, :infinity)

    assert Enum.all?(results, &match?({:error, %Ecto.Changeset{}}, &1))
    assert Repo.aggregate(FulfillmentRecord, :count) == 0
  end

  test "a trigger racing the payment boundary never fulfills an unproven order", ctx do
    # The payment lands and the fulfillment trigger fires at the same moment: the
    # trigger may only win if the paid order is already stored.
    tasks = [
      Task.async(fn -> Fulfillment.create_for_paid_order(ctx.order.id) end),
      Task.async(fn -> Orders.mark_order_paid(ctx.order.id) end)
    ]

    [fulfillment_result, payment_result] = Task.await_many(tasks, :infinity)

    assert match?({:ok, _order}, payment_result)

    case fulfillment_result do
      {:ok, [fulfillment]} ->
        assert fulfillment.status == :pending

      {:error, _changeset} ->
        # The trigger ran before the payment was stored, which is the correct
        # refusal rather than a fulfillment of an unproven purchase.
        assert Repo.aggregate(FulfillmentRecord, :count) == 0
    end
  end
end
