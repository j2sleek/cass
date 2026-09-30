defmodule Cass.EntitlementsTest do
  @moduledoc """
  The Entitlement boundary: an entitlement exists only because a paid order's
  delivery completed, the purchase is snapshotted, revocation is a withdrawal
  rather than a deletion, and reads are owner-or-admin.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment
  alias Cass.Repo

  setup do
    category = category_fixture()
    buyer = Scope.for_user(user_fixture())
    {product, variant} = published_variant_fixture(category, product_name: "Snapshot Widget")
    order = paid_order_fixture(buyer, variant, 2)
    {:ok, [fulfillment]} = Fulfillment.create_for_paid_order(order)
    {:ok, fulfillment} = Fulfillment.mark_processing(fulfillment)
    {:ok, fulfillment} = Fulfillment.mark_fulfilled(fulfillment)
    entitlement = Repo.preload(fulfillment, :entitlement).entitlement
    order_item = Repo.preload(fulfillment, :order_item).order_item

    %{
      category: category,
      buyer: buyer,
      product: product,
      variant: variant,
      order: order,
      order_item: order_item,
      fulfillment: fulfillment,
      entitlement: entitlement
    }
  end

  describe "granting" do
    test "mark_fulfilled/1 grants exactly one entitlement for the purchase", ctx do
      assert %Entitlement{} = ctx.entitlement
      assert ctx.entitlement.status == :active
      assert ctx.entitlement.fulfillment_id == ctx.fulfillment.id
      assert ctx.entitlement.order_item_id == ctx.order_item.id
      assert ctx.entitlement.order_id == ctx.order.id
      assert ctx.entitlement.user_id == ctx.buyer.user.id
      assert ctx.entitlement.granted_at != nil
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "the grant snapshots the purchase from the order item", ctx do
      entitlement = ctx.entitlement

      assert entitlement.product_name == "Snapshot Widget"
      assert entitlement.variant_name == ctx.order_item.variant_name
      assert entitlement.sku == ctx.order_item.sku
      assert entitlement.quantity == 2
      assert entitlement.product_type == :digital
      assert entitlement.metadata == ctx.order_item.metadata
      assert entitlement.expires_at == nil
      assert entitlement.revoked_at == nil
    end

    test "a later catalog edit cannot rewrite what the buyer bought", ctx do
      product = Repo.preload(ctx.product, :owner)

      {:ok, renamed} =
        Catalog.update_product(Scope.for_user(product.owner), product, %{
          name: "Renamed Widget"
        })

      assert renamed.name == "Renamed Widget"
      assert ctx.entitlement.product_name == "Snapshot Widget"
    end

    test "granting again for the same purchase returns the stored grant", ctx do
      assert {:ok, again} = Entitlements.grant_for_fulfillment(ctx.fulfillment, ctx.order_item)
      assert again.id == ctx.entitlement.id
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "a different delivery claiming the same line is refused, not answered with its grant",
         ctx do
      # Idempotency belongs to one delivery re-asking for its own grant. A
      # *different* delivery naming the same purchased line is a collision, and
      # returning the other delivery's grant would tell the caller it owns a
      # record that is not its own. A hand-built struct with no delivery id at all
      # is refused here too, rather than reaching the insert with a null
      # `fulfillment_id` and raising out of the database.
      for wrong <- [0, nil, 987_654_321] do
        assert {:error, changeset} =
                 Entitlements.grant_for_fulfillment(
                   %{ctx.fulfillment | id: wrong},
                   ctx.order_item
                 )

        assert "the entitlement does not match the purchase it claims" in errors_on(changeset).base
      end

      assert Repo.aggregate(Entitlement, :count) == 1
      assert Repo.get!(Entitlement, ctx.entitlement.id).fulfillment_id == ctx.fulfillment.id
    end

    test "refuses a grant whose delivery does not belong to the purchased line", ctx do
      stranger = order_fixture(ctx.buyer, ctx.variant)
      other_item = Repo.preload(stranger, :order_items).order_items |> hd()

      assert {:error, changeset} = Entitlements.grant_for_fulfillment(ctx.fulfillment, other_item)
      assert "the entitlement does not match the purchase it claims" in errors_on(changeset).base
    end

    test "refuses a malformed pairing without writing anything", ctx do
      for call <- [
            fn -> Entitlements.grant_for_fulfillment(ctx.fulfillment, nil) end,
            fn -> Entitlements.grant_for_fulfillment(nil, ctx.order_item) end,
            fn -> Entitlements.grant_for_fulfillment(ctx.fulfillment, :line) end
          ] do
        assert {:error, changeset} = call.()

        assert "the entitlement does not match the purchase it claims" in errors_on(changeset).base
      end

      assert Repo.aggregate(Entitlement, :count) == 1
    end
  end

  describe "revoking" do
    test "records when and why, and reports the grant as inactive", ctx do
      assert {:ok, revoked} = Entitlements.revoke_entitlement(ctx.entitlement, "refund issued")
      assert revoked.status == :revoked
      assert revoked.revoked_reason == "refund issued"
      assert revoked.revoked_at != nil
      refute Entitlement.active?(revoked)
    end

    test "is a withdrawal, not a deletion: the purchase provenance survives", ctx do
      assert {:ok, revoked} = Entitlements.revoke_entitlement(ctx.entitlement, "refund issued")
      assert revoked.id == ctx.entitlement.id
      assert revoked.product_name == ctx.entitlement.product_name
      assert Repo.get(Entitlement, ctx.entitlement.id).status == :revoked
      assert Repo.aggregate(Entitlement, :count) == 1
    end

    test "is idempotent", ctx do
      assert {:ok, first} = Entitlements.revoke_entitlement(ctx.entitlement, "refund issued")
      assert {:ok, second} = Entitlements.revoke_entitlement(first, "refund issued")
      assert second.revoked_at == first.revoked_at
    end

    test "a long reason is truncated instead of rejected", ctx do
      assert {:ok, revoked} =
               Entitlements.revoke_entitlement(ctx.entitlement, String.duplicate("x", 900))

      assert byte_size(revoked.revoked_reason) == 500
    end

    test "refuses to revoke an already-revoked grant through a different reason", ctx do
      assert {:ok, revoked} = Entitlements.revoke_entitlement(ctx.entitlement, "first reason")
      assert {:ok, same} = Entitlements.revoke_entitlement(revoked, "second reason")
      assert same.revoked_reason == "first reason"
    end

    test "refuses anything that is not a revocation", ctx do
      for call <- [
            fn -> Entitlements.revoke_entitlement(ctx.entitlement, nil) end,
            fn -> Entitlements.revoke_entitlement(ctx.entitlement, :refunded) end,
            fn -> Entitlements.revoke_entitlement(%Entitlement{status: :cancelled}, "why") end,
            fn -> Entitlements.revoke_entitlement(nil, "why") end
          ] do
        assert {:error, changeset} = call.()

        assert "the entitlement cannot be revoked from its current status" in errors_on(changeset).base
      end

      assert Repo.get(Entitlement, ctx.entitlement.id).status == :active
    end

    test "refuses a grant that is not a stored row, in every status", ctx do
      # Revocation is a withdrawal of a row that exists. A hand-built struct has
      # nothing to withdraw, so it is refused rather than echoed back or raised on.
      for status <- [:active, :expired, :revoked] do
        assert {:error, changeset} =
                 Entitlements.revoke_entitlement(
                   %{ctx.entitlement | id: nil, status: status},
                   "why"
                 )

        assert "the entitlement cannot be revoked from its current status" in errors_on(changeset).base
      end

      assert Repo.get(Entitlement, ctx.entitlement.id).status == :active
    end
  end

  describe "active?/1" do
    test "an active grant without an expiry is live" do
      assert Entitlement.active?(%Entitlement{status: :active, expires_at: nil})
    end

    test "an active grant whose expiry has passed is not live" do
      past = DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(1, :minute) |> DateTime.truncate(:second)

      refute Entitlement.active?(%Entitlement{status: :active, expires_at: past})
      assert Entitlement.active?(%Entitlement{status: :active, expires_at: future})
    end

    test "nothing but an active, unelapsed grant is live" do
      for status <- [:revoked, :expired] do
        refute Entitlement.active?(%Entitlement{status: status})
      end

      refute Entitlement.active?(%Entitlement{status: :cancelled})
    end
  end

  describe "authorization" do
    test "a buyer sees their own entitlements", ctx do
      assert [mine] = Entitlements.list_for_customer(ctx.buyer)
      assert mine.id == ctx.entitlement.id
      assert Entitlements.get_entitlement(ctx.buyer, ctx.entitlement.id).id == ctx.entitlement.id
    end

    test "a buyer never sees another buyer's entitlement", ctx do
      stranger = Scope.for_user(user_fixture())

      assert Entitlements.list_for_customer(stranger) == []
      assert Entitlements.get_entitlement(stranger, ctx.entitlement.id) == nil
      assert Entitlements.list_for_order(stranger, ctx.order.id) == []
    end

    test "a missing entitlement and somebody else's are indistinguishable", ctx do
      stranger = Scope.for_user(user_fixture())

      assert Entitlements.get_entitlement(stranger, ctx.entitlement.id) ==
               Entitlements.get_entitlement(stranger, 987_654_321)
    end

    test "an admin sees every entitlement", ctx do
      admin = Scope.for_user(admin_fixture())

      assert [theirs] = Entitlements.list_for_customer(admin)
      assert theirs.id == ctx.entitlement.id
      assert Entitlements.get_entitlement(admin, ctx.entitlement.id).id == ctx.entitlement.id
    end

    test "a guest sees nothing", ctx do
      guest = Scope.for_user(nil)

      assert Entitlements.list_for_customer(guest) == []
      assert Entitlements.get_entitlement(guest, ctx.entitlement.id) == nil
      assert Entitlements.list_for_order(guest, ctx.order.id) == []
    end

    test "a vendor gets no extra visibility", ctx do
      vendor = Scope.for_user(vendor_fixture())

      assert Entitlements.list_for_customer(vendor) == []
      assert Entitlements.get_entitlement(vendor, ctx.entitlement.id) == nil
    end

    test "ids that are not entitlements are refused, not raised on", ctx do
      for id <- [nil, :active, "abc", "12abc", ""] do
        assert Entitlements.get_entitlement(ctx.buyer, id) == nil
      end

      assert Entitlements.list_for_customer(nil) == []
      assert Entitlements.list_for_order(nil, ctx.order.id) == []
    end

    test "an order listing is only as wide as the order the scope may see", ctx do
      assert [mine] = Entitlements.list_for_order(ctx.buyer, ctx.order.id)
      assert mine.id == ctx.entitlement.id
      assert Entitlements.list_for_order(ctx.buyer, 987_654_321) == []
    end
  end

  describe "database invariants" do
    test "the database refuses a second entitlement for the same purchased line", ctx do
      duplicate =
        %Entitlement{}
        |> Entitlement.changeset(%{
          product_type: :digital,
          product_name: "Snapshot Widget",
          variant_name: "Default",
          quantity: 1,
          status: :active,
          granted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:fulfillment_id, ctx.fulfillment.id)
        |> Ecto.Changeset.put_change(:order_id, ctx.order.id)
        |> Ecto.Changeset.put_change(:order_item_id, ctx.order_item.id)
        |> Ecto.Changeset.put_change(:user_id, ctx.buyer.user.id)

      assert {:error, changeset} = Repo.insert(duplicate)
      assert "has already been taken" in errors_on(changeset).order_item_id

      # Nothing follows this statement, since the failed statement aborts the
      # surrounding sandbox transaction.
      assert_raise Postgrex.Error, ~r/cass_entitlements_order_item_id_index/, fn ->
        Repo.query!(
          """
          INSERT INTO cass_entitlements
            (fulfillment_id, order_id, order_item_id, user_id, product_type, product_name,
             variant_name, quantity, status, granted_at, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, 'digital', 'Snapshot Widget', 'Default', 1, 'active', NOW(), NOW(), NOW())
          """,
          [ctx.fulfillment.id, ctx.order.id, ctx.order_item.id, ctx.buyer.user.id]
        )
      end
    end

    test "the database refuses a second entitlement from the same delivery", ctx do
      second_item =
        order_fixture(ctx.buyer, ctx.variant)
        |> Repo.preload(:order_items)
        |> Map.fetch!(:order_items)
        |> hd()

      duplicate =
        %Entitlement{}
        |> Entitlement.changeset(%{
          product_type: :digital,
          product_name: "Snapshot Widget",
          variant_name: "Default",
          quantity: 1,
          status: :active,
          granted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ecto.Changeset.put_change(:fulfillment_id, ctx.fulfillment.id)
        |> Ecto.Changeset.put_change(:order_id, ctx.order.id)
        |> Ecto.Changeset.put_change(:order_item_id, second_item.id)
        |> Ecto.Changeset.put_change(:user_id, ctx.buyer.user.id)

      assert {:error, changeset} = Repo.insert(duplicate)
      assert "has already been taken" in errors_on(changeset).fulfillment_id
    end

    test "the database refuses a status outside the vocabulary", ctx do
      assert_raise Postgrex.Error, ~r/cass_entitlements_status_check/, fn ->
        Repo.query!("UPDATE cass_entitlements SET status = 'pending' WHERE id = $1", [
          ctx.entitlement.id
        ])
      end
    end
  end
end
