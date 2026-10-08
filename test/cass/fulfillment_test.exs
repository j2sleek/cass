defmodule Cass.FulfillmentTest do
  @moduledoc """
  The Fulfillment boundary: the kind vocabulary, the paid-order gate, the
  lifecycle state machine, and the authorization rules for reading deliveries.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders
  alias Cass.Orders.Order

  setup do
    %{category: category_fixture()}
  end

  describe "kind_for/1" do
    test "maps each product type to its fulfillment kind" do
      assert Fulfillment.kind_for(:digital) == :digital
      assert Fulfillment.kind_for(:smm) == :smm
      assert Fulfillment.kind_for(:ai) == :ai
      assert Fulfillment.kind_for(:service) == :manual
      assert Fulfillment.kind_for(:physical) == :shipping
    end

    test "accepts a product and reads its product type" do
      product = %Cass.Catalog.Product{product_type: :ai}
      assert Fulfillment.kind_for(product) == :ai
    end

    test "unknown or future types degrade to manual fulfillment" do
      assert Fulfillment.kind_for(:tickets) == :manual
    end

    test "every kind it can return is in the closed vocabulary" do
      kinds = Fulfillment.kinds()

      for product_type <- Cass.Catalog.product_types() do
        assert Fulfillment.kind_for(product_type) in kinds
      end
    end

    test "the closed vocabularies include the physical / shipping extension" do
      assert :physical in Cass.Catalog.product_types()
      assert :shipping in Fulfillment.kinds()
    end

    test "grants_entitlement?/1 is true for every kind except :shipping" do
      assert Fulfillment.grants_entitlement?(:digital)
      assert Fulfillment.grants_entitlement?(:smm)
      assert Fulfillment.grants_entitlement?(:ai)
      assert Fulfillment.grants_entitlement?(:manual)
      refute Fulfillment.grants_entitlement?(:shipping)
    end

    test "entitlement_kinds/0 is the exact set grants_entitlement?/1 admits" do
      for kind <- Fulfillment.kinds() do
        assert Fulfillment.grants_entitlement?(kind) ==
                 kind in Fulfillment.entitlement_kinds()
      end

      refute :shipping in Fulfillment.entitlement_kinds()
    end
  end

  describe "lifecycle vocabulary" do
    test "exposes the closed status and transition vocabularies" do
      assert Fulfillment.statuses() == [:pending, :processing, :fulfilled, :failed, :cancelled]

      assert Fulfillment.transitions() == %{
               pending: [:processing, :failed, :cancelled],
               processing: [:fulfilled, :failed, :cancelled],
               failed: [:processing, :cancelled],
               fulfilled: [],
               cancelled: []
             }
    end

    test "the terminal states have no way out" do
      assert Fulfillment.allowed_transitions(:fulfilled) == []
      assert Fulfillment.allowed_transitions(:cancelled) == []
      assert Fulfillment.allowed_transitions(:nonsense) == []
    end

    test "a delivery must be claimed before it can be reported complete" do
      assert Fulfillment.transition_allowed?(:pending, :processing)
      assert Fulfillment.transition_allowed?(:processing, :fulfilled)
      refute Fulfillment.transition_allowed?(:pending, :fulfilled)
    end
  end

  describe "create_for_paid_order/1" do
    test "creates a pending delivery for each purchased line of a paid order", %{
      category: category
    } do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category, product_name: "Design Suite")
      order = paid_order_fixture(buyer, variant, 2)

      assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)

      assert fulfillment.status == :pending
      assert fulfillment.kind == :digital
      assert fulfillment.product_type == :digital
      assert fulfillment.order_id == order.id
      assert fulfillment.order_item_id == hd(order.order_items).id
      assert fulfillment.user_id == buyer.user.id
      assert is_nil(fulfillment.delivered_at)
      assert Repo.preload(fulfillment, :entitlement).entitlement == nil
    end

    test "records the delivery kind of every product type", %{category: category} do
      buyer = Scope.for_user(user_fixture())

      for {product_type, kind} <- [
            {:digital, :digital},
            {:smm, :smm},
            {:ai, :ai},
            {:service, :manual}
          ] do
        {_product, variant} = published_variant_fixture(category, product_type: product_type)
        order = paid_order_fixture(buyer, variant)

        assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
        assert fulfillment.kind == kind
        assert fulfillment.product_type == product_type
      end
    end

    test "a mixed order gets one delivery per line, each with its own kind", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_digital, digital_variant} = published_variant_fixture(category, product_type: :digital)
      {_service, service_variant} = published_variant_fixture(category, product_type: :service)

      {:ok, order} =
        Orders.create_order(buyer, [
          %{product_variant_id: digital_variant.id, quantity: 1},
          %{product_variant_id: service_variant.id, quantity: 1}
        ])

      {:ok, order} = Orders.mark_order_paid(order.id)

      assert {:ok, fulfillments} = Fulfillment.create_for_paid_order(order)
      assert length(fulfillments) == 2
      assert fulfillments |> Enum.map(& &1.kind) |> Enum.sort() == [:digital, :manual]
      assert fulfillments |> Enum.map(& &1.order_item_id) |> Enum.uniq() |> length() == 2
    end

    test "the stored kind is always the one kind_for/1 maps the product type to", %{
      category: category
    } do
      buyer = Scope.for_user(user_fixture())

      for product_type <- Cass.Catalog.product_types() do
        {_product, variant} = published_variant_fixture(category, product_type: product_type)
        order = paid_order_fixture(buyer, variant)

        assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
        assert fulfillment.kind == Fulfillment.kind_for(fulfillment.product_type)
      end
    end

    test "accepts either an order struct or an order id", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)

      assert {:ok, [by_struct]} = Fulfillment.create_for_paid_order(order)
      assert {:ok, [by_id]} = Fulfillment.create_for_paid_order(order.id)
      assert by_id.id == by_struct.id
    end

    test "refuses an order that is still awaiting payment and writes nothing", %{
      category: category
    } do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = order_fixture(buyer, variant)

      assert {:error, changeset} = Fulfillment.create_for_paid_order(order)

      assert "the order has not been paid" in errors_on(changeset).base
      assert Repo.aggregate(FulfillmentRecord, :count) == 0
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "refuses a failed or cancelled order", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = order_fixture(buyer, variant)

      for status <- [:failed, :cancelled] do
        {:ok, order} = order |> Order.changeset(%{status: status}) |> Repo.update()

        assert {:error, changeset} = Fulfillment.create_for_paid_order(order)
        assert "the order has not been paid" in errors_on(changeset).base
      end

      assert Repo.aggregate(FulfillmentRecord, :count) == 0
    end

    test "an order that has advanced past :paid is still fulfilled", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)

      for status <- [:processing, :completed] do
        {:ok, order} = order |> Order.changeset(%{status: status}) |> Repo.update()

        assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
        assert fulfillment.status == :pending
      end

      assert Repo.aggregate(FulfillmentRecord, :count) == 1
    end

    test "an unknown or malformed reference is refused identically", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      paid_order_fixture(buyer, variant)

      for reference <- [987_654_321, nil, :paid, "12", "abc"] do
        assert {:error, changeset} = Fulfillment.create_for_paid_order(reference)
        assert "the order has not been paid" in errors_on(changeset).base
      end

      assert Repo.aggregate(FulfillmentRecord, :count) == 0
    end

    test "the stored order state is the authority, not the struct handed in", %{
      category: category
    } do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      unpaid = order_fixture(buyer, variant)

      # A caller that claims a different status (or no items at all) on the
      # struct it passes in cannot unlock anything: the row is re-read.
      for forged <- [Map.put(unpaid, :status, :paid), %{unpaid | order_items: []}] do
        assert {:error, changeset} = Fulfillment.create_for_paid_order(forged)
        assert "the order has not been paid" in errors_on(changeset).base
      end

      assert Repo.aggregate(FulfillmentRecord, :count) == 0
    end

    test "is idempotent: a second call returns the same delivery", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)

      assert {:ok, [first]} = Fulfillment.create_for_paid_order(order)
      assert {:ok, [second]} = Fulfillment.create_for_paid_order(order)
      assert {:ok, [third]} = Fulfillment.create_for_paid_order(order.id)

      assert first.id == second.id
      assert second.id == third.id
      assert Repo.aggregate(FulfillmentRecord, :count) == 1
    end

    test "the database refuses a second delivery for the same purchased line", %{
      category: category
    } do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)

      assert {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)

      # The changeset surfaces the conflict as a clean error...
      assert {:error, changeset} = Repo.insert(duplicate_changeset(order, fulfillment, buyer))
      assert "has already been taken" in errors_on(changeset).order_item_id

      # ...and the database itself is the authority: a raw insert that skips the
      # schema entirely is rejected by the unique index on `order_item_id`.
      # Nothing follows this statement, since the failed statement aborts the
      # surrounding sandbox transaction.
      assert_raise Postgrex.Error, ~r/cass_fulfillments_order_item_id_index/, fn ->
        Repo.query!(
          """
          INSERT INTO cass_fulfillments
            (order_id, order_item_id, user_id, kind, product_type, status, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
          """,
          [order.id, fulfillment.order_item_id, buyer.user.id, "digital", "digital", "pending"]
        )
      end
    end

    test "the database refuses a status outside the vocabulary", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)

      assert_raise Postgrex.Error, ~r/cass_fulfillments_status_check/, fn ->
        Repo.query!("UPDATE cass_fulfillments SET status = 'shipped' WHERE id = $1", [
          fulfillment.id
        ])
      end
    end
  end

  describe "lifecycle transitions" do
    setup %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      %{buyer: buyer, order: order, fulfillment: fulfillment}
    end

    test "a delivery is claimed, completed, and grants the entitlement", %{
      fulfillment: fulfillment
    } do
      assert {:ok, claimed} = Fulfillment.mark_processing(fulfillment)
      assert claimed.status == :processing
      assert Repo.aggregate(Entitlement, :count) == 0

      assert {:ok, delivered} = Fulfillment.mark_fulfilled(claimed)
      assert delivered.status == :fulfilled
      assert delivered.delivered_at != nil

      assert [entitlement] = Repo.all(Entitlement)
      assert entitlement.status == :active
      assert entitlement.fulfillment_id == fulfillment.id
      assert entitlement.order_item_id == fulfillment.order_item_id
    end

    test "a physical delivery completes without granting an entitlement", %{category: category} do
      buyer = Scope.for_user(user_fixture())
      {_product, variant} = published_variant_fixture(category, product_type: :physical)
      order = paid_order_fixture(buyer, variant)

      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
      assert fulfillment.kind == :shipping
      assert fulfillment.product_type == :physical
      assert Repo.aggregate(Entitlement, :count) == 0

      {:ok, claimed} = Fulfillment.mark_processing(fulfillment)
      assert {:ok, delivered} = Fulfillment.mark_fulfilled(claimed)
      assert delivered.status == :fulfilled
      assert delivered.delivered_at != nil

      # Handing over a parcel grants nothing in the application, so completing
      # the delivery — even twice — mints no entitlement.
      assert Repo.aggregate(Entitlement, :count) == 0
      assert {:ok, again} = Fulfillment.mark_fulfilled(delivered)
      assert again.status == :fulfilled
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "claiming is idempotent", %{fulfillment: fulfillment} do
      assert {:ok, first} = Fulfillment.mark_processing(fulfillment)
      assert {:ok, second} = Fulfillment.mark_processing(first)
      assert second.id == first.id
      assert second.status == :processing
    end

    test "completing an already completed delivery is a no-op", %{fulfillment: fulfillment} do
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, delivered} = Fulfillment.mark_fulfilled(processing)

      assert {:ok, again} = Fulfillment.mark_fulfilled(delivered)
      assert again.id == delivered.id
      assert again.status == :fulfilled
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "a pending delivery cannot be reported complete", %{fulfillment: fulfillment} do
      assert {:error, changeset} = Fulfillment.mark_fulfilled(fulfillment)
      assert "the fulfillment cannot make that transition" in errors_on(changeset).base
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a completed delivery is terminal", %{fulfillment: fulfillment} do
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)
      {:ok, delivered} = Fulfillment.mark_fulfilled(processing)

      for {transition, fun} <- [
            {:processing, &Fulfillment.mark_processing/1},
            {:failed, &Fulfillment.mark_failed(&1, "nope")},
            {:cancelled, &Fulfillment.mark_cancelled/1}
          ] do
        assert {:error, changeset} = fun.(delivered)
        assert "the fulfillment cannot make that transition" in errors_on(changeset).base
        refute transition in Fulfillment.allowed_transitions(:fulfilled)
      end

      assert Repo.get!(FulfillmentRecord, delivered.id).status == :fulfilled
    end

    test "a cancelled delivery is terminal and never grants an entitlement", %{
      fulfillment: fulfillment
    } do
      assert {:ok, cancelled} = Fulfillment.mark_cancelled(fulfillment)
      assert cancelled.status == :cancelled

      assert {:error, changeset} = Fulfillment.mark_processing(cancelled)
      assert "the fulfillment cannot make that transition" in errors_on(changeset).base

      assert {:error, _} = Fulfillment.mark_fulfilled(cancelled)
      assert Repo.aggregate(Entitlement, :count) == 0
    end

    test "a failed attempt records the reason and can be retried", %{fulfillment: fulfillment} do
      {:ok, processing} = Fulfillment.mark_processing(fulfillment)

      assert {:ok, failed} = Fulfillment.mark_failed(processing, "provider rejected the order")
      assert failed.status == :failed
      assert failed.failure_reason == "provider rejected the order"
      assert Repo.aggregate(Entitlement, :count) == 0

      assert {:ok, retried} = Fulfillment.mark_processing(failed)
      assert retried.status == :processing
      assert retried.failure_reason == "provider rejected the order"

      assert {:ok, delivered} = Fulfillment.mark_fulfilled(retried)
      assert delivered.status == :fulfilled
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "a failure reason is required", %{fulfillment: fulfillment} do
      assert {:error, changeset} = Fulfillment.mark_failed(fulfillment, nil)
      assert "the fulfillment cannot make that transition" in errors_on(changeset).base
    end

    test "a long failure reason is truncated instead of rejected", %{fulfillment: fulfillment} do
      {:ok, failed} = Fulfillment.mark_failed(fulfillment, String.duplicate("x", 900))
      assert String.length(failed.failure_reason) == 500
    end

    test "a struct that is not a stored row is refused, never raised on", %{
      fulfillment: fulfillment
    } do
      # A struct built by hand (or one whose row was deleted underneath it) has no
      # primary key to update. Every entry point must still answer with a refusal
      # rather than raising out of the database layer.
      fabricated = %{fulfillment | id: nil}

      for fun <- [
            &Fulfillment.mark_processing/1,
            &Fulfillment.mark_cancelled/1,
            &Fulfillment.mark_failed(&1, "nope")
          ] do
        assert {:error, changeset} = fun.(fabricated)
        assert "the fulfillment cannot make that transition" in errors_on(changeset).base
      end

      # Including the idempotent clauses: a `:fulfilled`/`:processing` struct with
      # no id must not be echoed back as though it were the stored delivery.
      for status <- [:processing, :fulfilled] do
        assert {:error, changeset} =
                 Fulfillment.mark_fulfilled(%{fabricated | status: status})

        assert "the fulfillment cannot make that transition" in errors_on(changeset).base

        assert {:error, changeset} =
                 Fulfillment.mark_processing(%{fabricated | status: status})

        assert "the fulfillment cannot make that transition" in errors_on(changeset).base
      end

      assert Repo.aggregate(Entitlement, :count) == 0
      assert Repo.get!(FulfillmentRecord, fulfillment.id).status == :pending
    end
  end

  describe "authorization" do
    setup %{category: category} do
      buyer = Scope.for_user(user_fixture())
      stranger = Scope.for_user(user_fixture())
      admin = Scope.for_user(admin_fixture())
      {_product, variant} = published_variant_fixture(category)
      order = paid_order_fixture(buyer, variant)
      {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)

      %{buyer: buyer, stranger: stranger, admin: admin, order: order, fulfillment: fulfillment}
    end

    test "a buyer sees their own deliveries", %{buyer: buyer, fulfillment: fulfillment} do
      assert [visible] = Fulfillment.list_for_customer(buyer)
      assert visible.id == fulfillment.id
      assert visible.order_item != nil
      assert Fulfillment.get_fulfillment(buyer, fulfillment.id).id == fulfillment.id
      assert [from_order] = Fulfillment.list_for_order(buyer, visible.order_id)
      assert from_order.id == fulfillment.id
    end

    test "another customer sees nothing", %{stranger: stranger, fulfillment: fulfillment} do
      assert Fulfillment.list_for_customer(stranger) == []
      assert Fulfillment.get_fulfillment(stranger, fulfillment.id) == nil
      assert Fulfillment.list_for_order(stranger, fulfillment.order_id) == []
    end

    test "an admin sees every delivery", %{admin: admin, fulfillment: fulfillment} do
      assert [visible] = Fulfillment.list_for_customer(admin)
      assert visible.id == fulfillment.id
      assert Fulfillment.get_fulfillment(admin, fulfillment.id).id == fulfillment.id
    end

    test "a guest sees nothing and cannot guess by id", %{fulfillment: fulfillment} do
      guest = Scope.for_user(nil)

      assert Fulfillment.list_for_customer(guest) == []
      assert Fulfillment.get_fulfillment(guest, fulfillment.id) == nil
      assert Fulfillment.get_fulfillment(guest, to_string(fulfillment.id)) == nil
    end

    test "a missing delivery and a foreign one are the same nil", %{buyer: buyer} do
      assert Fulfillment.get_fulfillment(buyer, 987_654_321) == nil
      assert Fulfillment.get_fulfillment(buyer, "not-a-number") == nil
      assert Fulfillment.get_fulfillment(buyer, nil) == nil
      assert Fulfillment.get_fulfillment(nil, 1) == nil
    end

    test "a vendor is a seller, not a delivery operator", %{fulfillment: fulfillment} do
      vendor = Scope.for_user(vendor_fixture())

      assert Fulfillment.list_for_customer(vendor) == []
      assert Fulfillment.get_fulfillment(vendor, fulfillment.id) == nil
    end
  end

  # A hand-built insert that bypasses the context, used to prove the database
  # constraints rather than the application checks.
  defp duplicate_changeset(order, fulfillment, buyer) do
    %FulfillmentRecord{}
    |> FulfillmentRecord.changeset(%{kind: :digital, product_type: :digital, status: :pending})
    |> Ecto.Changeset.put_change(:order_id, order.id)
    |> Ecto.Changeset.put_change(:order_item_id, fulfillment.order_item_id)
    |> Ecto.Changeset.put_change(:user_id, buyer.user.id)
  end
end
