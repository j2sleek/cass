defmodule Cass.Fulfillment do
  @moduledoc """
  The Fulfillment context: what a paid order still owes, and how it is delivered.

  The Catalog describes **what** is being sold
  (`Cass.Catalog.Product` → `Cass.Catalog.ProductVariant`). Orders record what
  the customer bought. Payments prove the money arrived. This context answers the
  two remaining questions, in order:

      what must be delivered?  → a `Cass.Fulfillment.Fulfillment` per purchased line
      what may the buyer use?   → a `Cass.Entitlements.Entitlement`

  The chain is strictly one-directional:

      paid order → order item → fulfillment → entitlement

  and each arrow is a database foreign key, so a row can never exist without the
  one it depends on.

  ## The authority is the paid order

  `create_for_paid_order/1` is the only way a fulfillment comes into existence,
  and it asks `Cass.Orders.get_paid_order/1` — not its own judgment — whether
  the money is proven. The two halves of the rule are therefore impossible to
  get wrong:

    * **An unpaid order can never be fulfilled.** Payment verification stays
      inside `Cass.Payments` (only it can move an order to `:paid`, and only it
      verifies a provider signature). This context never talks to a payment
      provider, never sees a webhook body, and never re-checks an amount; it only
      consumes the authoritative order state.
    * **Fulfillment never runs in reverse.** Nothing in `Cass.Payments` or
      `Cass.Orders` calls into here. A capture does not create fulfillments
      implicitly; the paid order is the precondition and a future trigger
      (webhook handler, worker, admin action) decides *when* to act on it.

  ## Idempotency

  `create_for_paid_order/1` is safe to call any number of times, from any number
  of processes at once. The mechanism is a unique index plus
  `INSERT … ON CONFLICT DO NOTHING` — never a read-then-write:

    * `cass_fulfillments.order_item_id` is **unique**, so one purchased line can
      only ever owe one delivery, and a losing race gets the winner's row back
      instead of a duplicate;
    * every line of a multi-line order is written in one transaction, so an
      order is never half-fulfilled;
    * `mark_fulfilled/1` grants the entitlement with the same technique against
      `cass_entitlements.order_item_id`, inside the transition's own
      transaction, so retried or concurrent delivery cannot grant twice.

  Duplicate calls are *not* errors: the second call returns the same records with
  the same ids. The same shape is used for the lifecycle transitions
  (`mark_fulfilled/1` on an already-fulfilled delivery is a no-op), so a retried
  job or a replayed trigger can simply run again.

  ## Kinds

  `kind_for/1` remains the single place a product type maps to a delivery kind:

    * `:digital` → instant delivery of a file, access, or license
    * `:smm`     → automated delivery through a provider API
    * `:ai`      → entitlement/credits issued through the Nexus AI Gateway
    * `:service` → manual fulfillment by a human

  The resolved `kind` is stored on the fulfillment, so a delivery worker can
  dispatch on it with one query and a later catalog edit cannot rewrite how a
  past purchase must be delivered. No provider integration exists yet: this
  milestone stops at the domain boundary, with `kind` recorded and the lifecycle
  driven explicitly.

  ## Authorization

  Reads follow the same owner-or-admin rule as `Cass.Orders`: an account sees
  its own fulfillments, an admin sees all, a guest sees nothing, and a foreign
  or unknown id is `nil` — indistinguishable from a missing row. Writes
  (`create_for_paid_order/1`, the `mark_*` transitions) are server-side boundary
  calls with no scope, in the same spirit as `Cass.Orders.mark_order_paid/1`:
  they are not reachable from a request, and no route exposes them in this
  milestone. A vendor is a seller, not a delivery operator, so the vendor role
  grants no extra visibility here.

  Return conventions: `{:ok, record | [record]}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.Scope
  alias Cass.Ai
  alias Cass.Catalog
  alias Cass.Catalog.Product
  alias Cass.Delivery
  alias Cass.Entitlements
  alias Cass.Fulfillment.Fulfillment
  alias Cass.Fulfillment.Worker
  alias Cass.Orders
  alias Cass.Orders.{Order, OrderItem}
  alias Cass.Repo

  @not_paid "the order has not been paid"
  @nothing_to_fulfill "the order has no items to fulfill"
  @unknown_variant "the purchased item is no longer resolvable"
  @invalid_transition "the fulfillment cannot make that transition"

  @kind_by_type %{
    digital: :digital,
    smm: :smm,
    ai: :ai,
    service: :manual
  }

  @doc "Returns the closed vocabulary of delivery kinds."
  defdelegate kinds(), to: Fulfillment, as: :kinds

  @doc "Returns the closed vocabulary of fulfillment statuses."
  defdelegate statuses(), to: Fulfillment, as: :statuses

  @doc "Returns the allowed status transitions as a `%{from => [to]}` map."
  defdelegate transitions(), to: Fulfillment, as: :transitions

  @doc "Returns the statuses `status` may move to (empty when it is terminal)."
  defdelegate allowed_transitions(status), to: Fulfillment

  @doc "Returns true when `from → to` is an allowed transition."
  defdelegate transition_allowed?(from, to), to: Fulfillment

  @doc """
  Returns the delivery kinds this application can hand over automatically.

  A delivery is only automated when `Cass.Delivery.mechanism_for/1` reports a
  mechanism for its kind — the same function that decides whether a buyer can
  ever exercise a grant. `:digital` and `:ai` both qualify today; `:smm` and
  `:manual` (a `:service` purchase) do not, and are therefore left `:pending`
  for a human until their integration exists.

  This is the eligibility authority for `Cass.Fulfillment.Worker`: a job for a
  kind outside this list is refused rather than "delivered" by a no-op, so a
  manual purchase can never be silently marked complete by automation.
  """
  def automatable_kinds do
    for kind <- Fulfillment.kinds(), Delivery.mechanism_for(kind) != nil, do: kind
  end

  @doc """
  Returns true when `kind` may be delivered automatically by this application.

  ## Examples

      iex> Cass.Fulfillment.automatable?(:digital)
      true

      iex> Cass.Fulfillment.automatable?(:ai)
      true

      iex> Cass.Fulfillment.automatable?(:smm)
      false

      iex> Cass.Fulfillment.automatable?(:manual)
      false
  """
  def automatable?(kind) do
    kind in automatable_kinds()
  end

  @doc """
  Enqueues one `Cass.Fulfillment.Worker` job per automatable delivery.

  Called from inside the payment transaction that creates the deliveries, which
  is what makes the queue and the capture atomic: the job rows are written in the
  same transaction and roll back with it. A purchase therefore cannot be paid for
  without its delivery being queued, and no outbox or reconciliation pass is
  involved.

  Non-automatable kinds (`:smm`, `:manual`) are skipped rather than queued to do
  nothing — they stay `:pending` for a human, as before.

  Idempotent in the sense that matters: inserting a duplicate job is harmless
  (`mark_fulfilled/1` and the unique indexes make a duplicate delivery a no-op),
  and a replayed webhook that re-runs `create_for_paid_order/1` gets the same
  existing rows back rather than creating new ones.

  Returns `:ok`, or `{:error, changeset}` when a job could not be inserted — which
  propagates out through the payment transaction so a capture is never committed
  without its deliveries queued.
  """
  def enqueue_deliveries(fulfillments) when is_list(fulfillments) do
    Enum.reduce_while(
      Enum.filter(fulfillments, &automatable?(&1.kind)),
      :ok,
      fn fulfillment, :ok ->
        case Oban.insert(Worker.new(worker_args(fulfillment))) do
          {:ok, _job} -> {:cont, :ok}
          {:error, %Ecto.Changeset{} = changeset} -> {:halt, {:error, changeset}}
        end
      end
    )
  end

  defp worker_args(%Fulfillment{id: id}) when is_integer(id), do: %{"fulfillment_id" => id}

  @doc """
  Returns the fulfillment kind that delivers a product, either from a
  `%Product{}` (via its `product_type`) or directly from a product type atom.

  This is the one place the mapping lives: `create_for_paid_order/1` resolves the
  purchased product's type through `Cass.Catalog.get_product_type_for_variant/1`
  and stores the result, so no other code has to re-derive a delivery mechanism
  (and the Catalog never has to know about delivery).

  Unknown or future types fall back to `:manual` so the boundary degrades
  safely instead of raising.

  ## Examples

      iex> Cass.Fulfillment.kind_for(:ai)
      :ai

      iex> Cass.Fulfillment.kind_for(:service)
      :manual

  """
  def kind_for(%Product{} = product) do
    kind_for(product.product_type)
  end

  def kind_for(product_type)
      when product_type in [:digital, :smm, :ai, :service],
      do: Map.fetch!(@kind_by_type, product_type)

  def kind_for(_product_type), do: :manual

  @doc """
  Creates the deliveries an authoritative **paid** order still owes.

  Accepts an `%Order{}` or an order id; in both cases the *stored* order state is
  what decides, so a stale struct (or a forged one) can never unlock a
  fulfillment for an order that was not paid.

  One fulfillment is created per purchased line — an order mixing a digital
  product and a human-performed service gets a `:digital` and a `:manual`
  delivery — each `:pending`, owned by the order's buyer, and typed by
  `kind_for/1`.

  Returns `{:ok, fulfillments}` (the order's full set, oldest line first), or:

    * `{:error, changeset}` — the order does not exist, is not paid, has no
      items, or a purchased variant can no longer be resolved. The message never
      distinguishes those cases, and nothing is written.

  Calling it again for the same order is a no-op that returns the same records:
  the unique index on `order_item_id` is the idempotency authority, so a payment
  webhook, a background job, an admin retry, and a concurrent duplicate all end
  up with exactly one delivery per purchased line.
  """
  def create_for_paid_order(%Order{id: order_id}) when is_integer(order_id) do
    create_for_paid_order(order_id)
  end

  def create_for_paid_order(order_id) when is_integer(order_id) do
    case Orders.get_paid_order(order_id) do
      {:ok, order} -> create_fulfillments_for(order)
      {:error, _reason} -> refuse(@not_paid)
    end
  end

  def create_for_paid_order(_order), do: refuse(@not_paid)

  @doc """
  Transitions a delivery to `:processing` — it has been claimed for delivery.

  Idempotent, and the only way out of `:pending` (and back out of a `:failed`
  attempt, for a retry).

  Decided by the database like every other transition, so a caller holding a
  struct that has since moved on cannot push it back into `:processing`: a
  delivery that is already `:fulfilled` or `:cancelled` is refused, not
  reopened.
  """
  def mark_processing(%Fulfillment{id: id} = fulfillment) when is_integer(id) do
    case Repo.get(Fulfillment, id) do
      %Fulfillment{status: :processing} = current ->
        {:ok, current}

      _not_claimed_yet ->
        resolve_race(
          guarded_transition(fulfillment, :processing, [:pending, :failed], %{}),
          id,
          :processing
        )
    end
  end

  def mark_processing(_fulfillment), do: refuse(@invalid_transition)

  @doc """
  Transitions a delivery to `:fulfilled` and grants the buyer's entitlement.

  Both writes happen in one transaction, in this order: the delivery is reported
  complete, and the entitlement is granted for the purchase it delivered. So:

    * an entitlement never exists for a delivery that was not established (the
      grant rolls back with the transition);
    * a delivery is never reported complete without the grant it implies;
    * a retry or a concurrent duplicate grants nothing extra — the unique index
      on `cass_entitlements.order_item_id` returns the existing grant.

  For an **`:ai`** delivery a third write happens in that same transaction: the
  credit pool the grant implies (`Cass.Ai.issue_credits/1`). It is in the
  transaction rather than beside it precisely so the two cannot diverge — an
  entitlement a buyer can see but cannot spend (or a pool with no entitlement to
  authorize it) would be a state no other context can repair, because nothing
  else re-runs a completed delivery. Non-AI deliveries are unaffected; they
  grant no balance, and the *absence* of one is what "not metered" means.

  Idempotent: a delivery that is already `:fulfilled` is returned unchanged
  instead of being re-delivered or re-granted. Refuses a `:pending` delivery (a
  delivery is claimed before it is reported complete) and every terminal or
  unreachable state.

  The `:processing` requirement is a `WHERE` clause, not a check on the struct
  passed in: an in-flight job that has been cancelled underneath it is refused
  here instead of resurrecting a terminal delivery and granting it a second time.
  """
  def mark_fulfilled(%Fulfillment{id: id} = fulfillment) when is_integer(id) do
    Repo.transact(fn ->
      with {:ok, _} <-
             guarded_transition(fulfillment, :fulfilled, [:processing], %{
               delivered_at: utc_now()
             }),
           {:ok, fulfilled} <- reload_with_order_item(id) do
        with {:ok, entitlement} <-
               Entitlements.grant_for_fulfillment(fulfilled, fulfilled.order_item),
             {:ok, _balance} <- Ai.issue_credits(entitlement) do
          {:ok, fulfilled}
        end
      else
        {:error, _} = refusal -> resolve_race(refusal, id, :fulfilled)
      end
    end)
  end

  def mark_fulfilled(%Fulfillment{}), do: refuse(@invalid_transition)

  # A guarded transition can lose a race with a concurrent worker that already
  # reached the same status. That is a success, not a refusal: the caller asked
  # for the delivery to *be* in `to`, and it is.
  defp resolve_race({:ok, _} = ok, _id, _to), do: ok

  defp resolve_race({:error, _} = refusal, id, to) do
    case Repo.get(Fulfillment, id) do
      %Fulfillment{status: ^to} = current -> {:ok, current}
      _moved_somewhere_else -> refusal
    end
  end

  @doc """
  Records that a delivery attempt failed, with a reason.

  A failed attempt is not terminal: `mark_processing/1` can claim it again for a
  retry. No entitlement is granted, and the purchase stays owed.

  A late failure from a job whose delivery already finished is refused — see
  `guarded_transition/4`.
  """
  def mark_failed(%Fulfillment{} = fulfillment, reason) when is_binary(reason) do
    guarded_transition(fulfillment, :failed, [:pending, :processing], %{
      failure_reason: String.slice(reason, 0, 500)
    })
  end

  def mark_failed(%Fulfillment{}, _reason), do: refuse(@invalid_transition)

  @doc """
  Cancels a delivery: it will not be attempted again.

  Terminal — nothing reopens a cancelled delivery — and no entitlement is ever
  granted for it, so cancelling can never leave a grant behind. A delivery that
  already completed (`:fulfilled`) is terminal too and cannot be cancelled, which
  is what keeps a granted entitlement from being orphaned by a later cancel.
  """
  def mark_cancelled(%Fulfillment{} = fulfillment) do
    guarded_transition(fulfillment, :cancelled, [:pending, :processing, :failed], %{})
  end

  @doc """
  Lists the deliveries `scope` is allowed to see: every delivery for an admin,
  only the caller's own for everybody else, nothing for a guest.
  """
  def list_for_customer(%Scope{} = scope) do
    case visible_query(scope) do
      nil -> []
      query -> Repo.all(query)
    end
  end

  def list_for_customer(_scope), do: []

  @doc """
  Fetches a delivery by id **only if** `scope` may see it, returning `nil`
  otherwise.

  A missing delivery and somebody else's are deliberately indistinguishable.
  """
  def get_fulfillment(%Scope{} = scope, fulfillment_id) when is_integer(fulfillment_id) do
    case visible_query(scope) do
      nil ->
        nil

      query ->
        Repo.one(from f in query, where: f.id == ^fulfillment_id)
    end
  end

  def get_fulfillment(%Scope{} = scope, fulfillment_id) when is_binary(fulfillment_id) do
    case Integer.parse(fulfillment_id) do
      {fulfillment_id, ""} -> get_fulfillment(scope, fulfillment_id)
      _not_a_number -> nil
    end
  end

  def get_fulfillment(_scope, _fulfillment_id), do: nil

  @doc """
  Lists the deliveries of one order, **only if** `scope` may see that order.

  Order ownership is resolved through `Cass.Orders.get_order/2`, so a delivery
  listing can never be wider than the order it belongs to.
  """
  def list_for_order(%Scope{} = scope, order_id) do
    case Orders.get_order(scope, order_id) do
      nil ->
        []

      %Order{id: id} ->
        Repo.all(from f in Fulfillment, where: f.order_id == ^id, order_by: [asc: f.id])
    end
  end

  def list_for_order(_scope, _order_id), do: []

  ## Creation internals

  defp create_fulfillments_for(%Order{order_items: []}) do
    refuse(@nothing_to_fulfill)
  end

  defp create_fulfillments_for(%Order{order_items: items} = order) do
    Repo.transact(fn ->
      items
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, fulfillments} ->
        case insert_fulfillment(order, item) do
          {:ok, fulfillment} -> {:cont, {:ok, [fulfillment | fulfillments]}}
          {:error, _changeset} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fulfillments} -> {:ok, Enum.reverse(fulfillments)}
        {:error, _changeset} = error -> error
      end
    end)
  end

  # The purchase's product type is the only thing read from the catalog, and only
  # as a single atom: the delivery mechanism is derived from it here and stored,
  # so nothing downstream has to ask the catalog again.
  defp insert_fulfillment(%Order{} = order, %OrderItem{} = item) do
    case Catalog.get_product_type_for_variant(item.product_variant_id) do
      {:ok, product_type} ->
        order
        |> fulfillment_changeset(item, product_type)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :order_item_id)
        |> case do
          # `ON CONFLICT DO NOTHING` skips the row, so Ecto returns the struct
          # without its id: another process already owes this delivery, and its
          # row is the answer.
          {:ok, %Fulfillment{id: nil}} -> existing_fulfillment(item)
          result -> result
        end

      {:error, :unknown_variant} ->
        refuse(@unknown_variant)
    end
  end

  defp fulfillment_changeset(%Order{} = order, %OrderItem{} = item, product_type) do
    %Fulfillment{}
    |> Fulfillment.changeset(%{
      kind: kind_for(product_type),
      product_type: product_type,
      status: :pending
    })
    |> Ecto.Changeset.put_change(:order_id, order.id)
    |> Ecto.Changeset.put_change(:order_item_id, item.id)
    |> Ecto.Changeset.put_change(:user_id, order.user_id)
  end

  defp existing_fulfillment(%OrderItem{} = item) do
    case Repo.one(from f in Fulfillment, where: f.order_item_id == ^item.id) do
      nil -> refuse(@unknown_variant)
      fulfillment -> {:ok, fulfillment}
    end
  end

  ## Lifecycle internals

  # One place performs a transition, so the allowed-transition check and the
  # write can never disagree.
  #
  # Unlike a struct-based transition, this re-reads the row and gates the update
  # on the status it is *actually* in: the allowed-from states become a `WHERE`
  # clause, not a check on the struct handed in. That is what makes an in-flight
  # job safe — a delivery that has been cancelled or fulfilled underneath it
  # updates zero rows and is refused, instead of resurrecting a terminal row and
  # granting its entitlement a second time.
  defp guarded_transition(%Fulfillment{id: id}, to, allowed_from, changes)
       when is_integer(id) do
    query =
      from f in Fulfillment,
        where: f.id == ^id and f.status in ^allowed_from

    # `changes` may not carry its own `:status`, otherwise it would land after
    # the guarded value and quietly win. Filter it out of the caller's changes
    # before appending them.
    assignments =
      [status: dump_status(to), updated_at: utc_now()] ++
        for {field, value} <- changes, field != :status, do: {field, value}

    case Repo.update_all(query, set: assignments) do
      {1, _} -> reload(id)
      {0, _} -> refuse(@invalid_transition)
    end
  end

  # A struct that is not a stored row has nothing to write to. Refusing it here
  # — before `Repo.update_all/2` could raise on a missing primary key — keeps the
  # lifecycle total: every entry point answers `{:ok, _}` or
  # `{:error, changeset}` and none of them raises, whatever it is handed.
  defp guarded_transition(_fulfillment, _to, _allowed_from, _changes) do
    refuse(@invalid_transition)
  end

  # `update_all/2` takes raw (already dumped) values, so the atom has to be
  # dumped the same way `Ecto.Type` would dump it for a changeset.
  defp dump_status(status) do
    {:ok, dumped} = Ecto.Type.dump(Fulfillment.__schema__(:type, :status), status)
    dumped
  end

  defp reload(id) do
    case Repo.get(Fulfillment, id) do
      nil -> refuse(@invalid_transition)
      fulfillment -> {:ok, fulfillment}
    end
  end

  defp reload_with_order_item(id) do
    case Repo.one(from f in Fulfillment, where: f.id == ^id, preload: [:order_item]) do
      nil -> refuse(@invalid_transition)
      fulfillment -> {:ok, fulfillment}
    end
  end

  ## Authorization internals

  defp visible_query(%Scope{} = scope) do
    cond do
      Scope.admin?(scope) ->
        read_query()

      Scope.authenticated?(scope) ->
        where(read_query(), [f], f.user_id == ^scope.user.id)

      true ->
        nil
    end
  end

  defp read_query do
    from f in Fulfillment,
      order_by: [asc: f.inserted_at, asc: f.id],
      preload: [:order_item, :entitlement]
  end

  # The single shape of a refusal, matching the catalog, orders, and payments
  # contexts: an `{:error, changeset}` on `:base` that never distinguishes the
  # reason.
  defp refuse(message) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(%Fulfillment{}), :base, message)}
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
