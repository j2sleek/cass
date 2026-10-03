defmodule Cass.FulfillmentGuardedTransitionTest do
  use Cass.DataCase, async: false

  @moduledoc """
  Regression tests for the guarded `mark_failed/2` and `mark_cancelled/1`
  transitions.

  These reproduce the exact stale-struct race found in the Milestone 12
  architecture audit: two processes hold a `:processing` struct for the *same*
  fulfillment row, one completes the delivery, and the other then fails. Before
  the fix the loser wrote its stale status back over the delivered row and the
  purchase was reported as failed while its entitlement and AI credits stayed
  live.
  """

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Ai.CreditBalance
  alias Cass.Delivery
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
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

  describe "mark_failed/2 with a stale struct" do
    test "cannot downgrade a fulfilled AI delivery" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      # Worker A claims and completes the delivery.
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(processing)

      # Worker B still holds the `:processing` struct and its delivery fails.
      assert {:error, changeset} = Fulfillment.mark_failed(processing, "gateway exploded")
      assert "the fulfillment cannot make that transition" in errors_on(changeset).base

      final = Repo.get!(FulfillmentRecord, fulfillment.id)

      assert final.status == :fulfilled
      assert is_nil(final.failure_reason)
      assert final.delivered_at

      # The grant and the credit balance survive the refused write untouched.
      entitlement = Repo.preload(final, :entitlement).entitlement
      assert entitlement.status == :active
      assert Repo.aggregate(Entitlement, :count) == 1

      balance = Repo.one(CreditBalance)
      assert balance.granted == 5
      assert balance.consumed == 0
    end

    test "cannot downgrade a fulfilled digital delivery" do
      buyer = Scope.for_user(user_fixture())

      {_order, fulfillment} =
        pending_fulfillment(buyer, category_fixture(), product_type: :digital)

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(processing)

      assert {:error, _changeset} = Fulfillment.mark_failed(processing, "late failure")
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :fulfilled
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "a stale cancel cannot downgrade a fulfilled delivery" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(processing)

      assert {:error, _changeset} = Fulfillment.mark_cancelled(processing)
      final = Repo.get!(FulfillmentRecord, fulfillment.id)

      assert final.status == :fulfilled
      assert Repo.preload(final, :entitlement).entitlement.status == :active
    end

    test "still records a failure when the row really is processing" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)

      assert {:ok, failed} = Fulfillment.mark_failed(processing, "provider refused")
      assert failed.status == :failed
      assert failed.failure_reason == "provider refused"
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "still records a failure when the row really is pending" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      assert {:ok, failed} = Fulfillment.mark_failed(fulfillment, "no vendor configured")
      assert failed.status == :failed
      assert failed.failure_reason == "no vendor configured"
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :failed
    end

    test "only the first of two concurrent failures writes" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)

      results =
        1..6
        |> Enum.map(fn i ->
          Task.async(fn -> Fulfillment.mark_failed(processing, "attempt #{i}") end)
        end)
        |> Task.await_many(:infinity)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :failed
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a failed delivery is still retryable and grants exactly once" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, _failed} = Fulfillment.mark_failed(processing, "transient outage")

      {:ok, reclaimed} = Fulfillment.mark_processing(fulfillment)
      {:ok, _delivered} = Fulfillment.mark_fulfilled(reclaimed)

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.one(CreditBalance).granted == 5
    end
  end

  describe "buyer-visible outcome" do
    test "the buyer keeps access after a refused stale failure" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, delivered} = Fulfillment.mark_fulfilled(processing)
      entitlement = Repo.preload(delivered, :entitlement).entitlement

      assert {:error, _} = Fulfillment.mark_failed(processing, "gateway exploded")

      # The refused write must not have revoked or hidden the grant.
      assert {:ok, access} = Delivery.authorize_access(buyer, entitlement.id)
      assert access.entitlement_id == entitlement.id
      assert Repo.preload(entitlement, :fulfillment).fulfillment.status == :fulfilled
    end
  end

  describe "a grant that fails inside mark_fulfilled/1" do
    test "rolls the status write back rather than committing an entitlement-less delivery" do
      buyer = Scope.for_user(user_fixture())
      {_order, fulfillment} = pending_fulfillment(buyer, category_fixture())

      {:ok, processing} = Fulfillment.mark_processing(fulfillment)

      # Fail the grant *after* the status write has already succeeded, by
      # pointing the delivery at a different order so `Entitlements.claims?/2`
      # refuses the pair. This is the only way to reach the failure window.
      {_product, variant} =
        published_variant_fixture(category_fixture(),
          product_type: :ai,
          config: %{"credits" => 5}
        )

      other_order = paid_order_fixture(Scope.for_user(user_fixture()), variant, 1)

      Repo.update_all(
        from(f in FulfillmentRecord, where: f.id == ^processing.id),
        set: [order_id: other_order.id]
      )

      assert {:error, %Ecto.Changeset{}} = Fulfillment.mark_fulfilled(processing)

      # The `:fulfilled` write is inside the same transaction as the grant, so
      # the failure must take it back down. Committing here would leave the
      # purchase reported as delivered while granting no access at all.
      assert Repo.get!(FulfillmentRecord, processing.id).status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0
    end
  end
end
