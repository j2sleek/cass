defmodule Cass.Entitlements do
  @moduledoc """
  The Entitlements context: what a buyer is durably authorized to use.

  A fulfillment says *how* a purchase is delivered. An entitlement says the
  purchase succeeded and the buyer may now use what they bought. Keeping the two
  apart is the point: a delivery can be retried, routed through a different
  mechanism, or handed to a human without ever touching the grant, and the grant
  keeps pointing at the purchase even after the delivery record is old history.

  ## The chain

      paid order → order item → fulfillment → entitlement

  Entitlements never decides *whether* a payment happened. It consumes a
  fulfillment, which by construction only exists for an order that reached the
  paid states (see `Cass.Fulfillment.create_for_paid_order/1`). There is no path
  into this context from a request, from `Cass.Payments`, or from a provider
  adapter.

  ## Invariants

    * **No entitlement without a completed delivery.** Entitlements are granted
      by `grant_for_fulfillment/2`, which `Cass.Fulfillment.mark_fulfilled/1`
      calls inside the same transaction as the `:fulfilled` transition. There is
      no public "grant an entitlement" call that a caller could use to invent
      one for an unpaid order.
    * **Buyer ownership.** `user_id` is copied from the fulfillment, which copied
      it from the order. Nothing in this context reads a user id from a
      parameter, and a fulfillment that does not belong to the same order item
      as the purchase it claims is refused.
    * **Idempotency.** The insert is `ON CONFLICT DO NOTHING` against the unique
      indexes on `order_item_id` and `fulfillment_id`, so repeated fulfillment
      processing returns the existing grant instead of creating a second one —
      including when two processes try to grant at the same moment.
    * **Historical integrity.** The purchase snapshot is copied from the
      immutable order item, never re-derived from mutable catalog rows.

  ## Authorization

  Reads follow the same owner-or-admin rule as `Cass.Orders` and
  `Cass.Fulfillment`: an account sees its own entitlements, an admin sees all,
  a guest sees nothing, and a foreign or unknown id is `nil` — indistinguishable
  from a missing row, so entitlement ids cannot be probed. `revoke_entitlement/2`
  is a server-side boundary call (a support/refund action); no route exposes it
  in this milestone.

  Return conventions: `{:ok, record}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.Scope
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment.Fulfillment
  alias Cass.Orders
  alias Cass.Orders.{Order, OrderItem}
  alias Cass.Repo

  @inconsistent "the entitlement does not match the purchase it claims"
  @not_active "the entitlement cannot be revoked from its current status"

  @doc "Returns the closed vocabulary of entitlement statuses."
  defdelegate statuses(), to: Entitlement, as: :statuses

  @doc """
  Grants the entitlement earned by a fulfilled purchase.

  `fulfillment` must already be `:fulfilled` — the state `Cass.Fulfillment`
  reaches in the same transaction that calls this function — and `order_item`
  must be the purchased line that fulfillment belongs to. A mismatched pair is
  refused rather than partially applied, so a caller can never graft one
  purchase's grant onto another delivery.

  The purchase facts (`product_name`, `variant_name`, `sku`, `quantity`,
  `product_type`, `metadata`) are snapshotted from the order item, and
  `user_id` is taken from the fulfillment — which copied it from the paid order
  — so the grant can only ever belong to the buyer who paid.

  Returns `{:ok, entitlement}`. Calling it again for the same purchase (a retried
  delivery, a duplicate webhook, a concurrent worker) returns the **same**
  entitlement: the unique index on `order_item_id` is the authority.
  """
  def grant_for_fulfillment(%Fulfillment{} = fulfillment, %OrderItem{} = order_item) do
    if claims?(fulfillment, order_item) do
      insert_entitlement(fulfillment, order_item)
    else
      refuse(@inconsistent)
    end
  end

  def grant_for_fulfillment(_fulfillment, _order_item), do: refuse(@inconsistent)

  @doc """
  Revokes an entitlement, recording when and why.

  A withdrawal rather than a deletion: the row (and its purchase provenance)
  stays so a later support question has an answer, and `Entitlement.active?/1`
  immediately reports `false`. Idempotent — revoking an already-revoked
  entitlement is a no-op that returns the existing row.

  This is a server-side boundary call, in the same spirit as
  `Cass.Orders.mark_order_paid/1`: the web layer reaches it only once a refund
  or support flow exists, and never on behalf of a request body.
  """
  def revoke_entitlement(%Entitlement{id: id, status: :revoked} = entitlement, _reason)
      when is_integer(id) do
    {:ok, entitlement}
  end

  def revoke_entitlement(%Entitlement{id: id, status: status} = entitlement, reason)
      when is_integer(id) and status in [:active, :expired] and is_binary(reason) do
    entitlement
    |> Entitlement.changeset(%{
      status: :revoked,
      revoked_at: utc_now(),
      revoked_reason: String.slice(reason, 0, 500)
    })
    |> Repo.update()
  end

  # Anything else is not a valid revocation: there is no transition back out of
  # `:revoked`, and a caller that cannot name a reason cannot revoke at all.
  def revoke_entitlement(_entitlement, _reason), do: refuse(@not_active)

  @doc """
  Lists the entitlements `scope` is allowed to see: every entitlement for an
  admin, only the caller's own for everybody else, nothing for a guest.
  """
  def list_for_customer(%Scope{} = scope) do
    case visible_query(scope) do
      nil -> []
      query -> Repo.all(query)
    end
  end

  def list_for_customer(_scope), do: []

  @doc """
  Fetches an entitlement by id **only if** `scope` may see it, returning `nil`
  otherwise.

  A missing entitlement and somebody else's are deliberately indistinguishable.
  """
  def get_entitlement(%Scope{} = scope, entitlement_id) when is_integer(entitlement_id) do
    case visible_query(scope) do
      nil ->
        nil

      query ->
        Repo.one(from e in query, where: e.id == ^entitlement_id)
    end
  end

  def get_entitlement(%Scope{} = scope, entitlement_id) when is_binary(entitlement_id) do
    case Integer.parse(entitlement_id) do
      {entitlement_id, ""} -> get_entitlement(scope, entitlement_id)
      _not_a_number -> nil
    end
  end

  def get_entitlement(_scope, _entitlement_id), do: nil

  @doc """
  Lists the entitlements an order granted, **only if** `scope` may see that
  order.

  Order ownership is resolved through `Cass.Orders.get_order/2`, so an
  entitlement listing can never be wider than the order it came from.
  """
  def list_for_order(%Scope{} = scope, order_id) do
    case Orders.get_order(scope, order_id) do
      nil ->
        []

      %Order{id: id} ->
        Repo.all(from e in Entitlement, where: e.order_id == ^id, order_by: [asc: e.id])
    end
  end

  def list_for_order(_scope, _order_id), do: []

  ## Internals

  # The two structs must describe the same purchase, and the delivery must be a
  # stored row. `order_id` is checked as well as `order_item_id` so a
  # fulfillment and an order item from two different orders of the same buyer
  # still cannot be paired, and the `id` guard means a fabricated struct can
  # never reach the insert with a null `fulfillment_id` — it is refused with the
  # same changeset as any other inconsistency instead of raising out of the
  # database.
  defp claims?(
         %Fulfillment{id: id, order_item_id: order_item_id, order_id: order_id},
         %OrderItem{} = order_item
       )
       when is_integer(id) do
    order_item.id == order_item_id and order_item.order_id == order_id
  end

  defp claims?(_fulfillment, _order_item), do: false

  defp insert_entitlement(%Fulfillment{} = fulfillment, %OrderItem{} = order_item) do
    changeset =
      %Entitlement{}
      |> Entitlement.changeset(%{
        product_type: fulfillment.product_type,
        product_name: order_item.product_name,
        variant_name: order_item.variant_name,
        sku: order_item.sku,
        quantity: order_item.quantity,
        metadata: order_item.metadata || %{},
        status: :active,
        granted_at: utc_now()
      })
      |> Ecto.Changeset.put_change(:fulfillment_id, fulfillment.id)
      |> Ecto.Changeset.put_change(:order_id, fulfillment.order_id)
      |> Ecto.Changeset.put_change(:order_item_id, order_item.id)
      |> Ecto.Changeset.put_change(:user_id, fulfillment.user_id)

    # `ON CONFLICT DO NOTHING` is the idempotency mechanism: the unique indexes
    # decide, not a preceding read. A conflict returns a struct with no id, and
    # the stored grant is re-read — but only the one this delivery owns, so a
    # collision between two deliveries is refused instead of answered.
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :order_item_id) do
      {:ok, %Entitlement{id: nil}} -> existing_for(fulfillment, order_item)
      result -> result
    end
  end

  # Re-reads the stored grant for this purchased line and only hands it back to
  # the delivery it was actually written for. A conflict on `order_item_id` that
  # resolves to a *different* delivery's grant means two deliveries are claiming
  # one purchased line, so this refuses rather than reporting somebody else's
  # grant as this delivery's.
  defp existing_for(%Fulfillment{} = fulfillment, %OrderItem{} = order_item) do
    entitlement =
      Repo.one(
        from e in Entitlement,
          where: e.order_item_id == ^order_item.id and e.fulfillment_id == ^fulfillment.id
      )

    case entitlement do
      nil -> refuse(@inconsistent)
      stored -> {:ok, stored}
    end
  end

  defp visible_query(%Scope{} = scope) do
    cond do
      Scope.admin?(scope) ->
        read_query()

      Scope.authenticated?(scope) ->
        where(read_query(), [e], e.user_id == ^scope.user.id)

      true ->
        nil
    end
  end

  # `:fulfillment` is preloaded so a consumer that needs the delivery mechanism
  # that granted a right can follow the 1:1 `fulfillment_id` without a second
  # query — and, more importantly, without a second ownership decision. The
  # owner-or-admin filter is already applied above, so anything reached through
  # this query is already authorized; `Cass.Delivery` reuses that rather than
  # re-deriving who may read what.
  defp read_query do
    from e in Entitlement, order_by: [desc: e.granted_at, desc: e.id], preload: [:fulfillment]
  end

  # The single shape of a refusal, matching the catalog, orders, and payments
  # contexts: an `{:error, changeset}` on `:base` that never distinguishes the
  # reason.
  defp refuse(message) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(%Entitlement{}), :base, message)}
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
