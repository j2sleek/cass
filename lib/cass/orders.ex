defmodule Cass.Orders do
  @moduledoc """
  The Orders context: transactional checkout and order reads.

  ## Checkout

  `create_order/2` is the checkout API. It takes the caller's
  `Cass.Accounts.Scope` and a minimal list of requested line items — each a map
  with exactly `product_variant_id` and `quantity` — and does everything else
  server-side, atomically:

    1. resolves the requested variants from the database;
    2. verifies each variant is `active` and purchasable, its product is
       published, sale-eligible (`:public`/`:unlisted` visibility, active
       category, `published_at` due), and it is priced;
    3. reads the authoritative `price_cents` and `currency` from the variant;
    4. computes line totals (`unit_price_cents * quantity`) and the order total
       (the sum) in integer cents, never trusting a value from the client;
    5. snapshots the commercial facts (product name, variant name, SKU, price,
       currency, and the variant's `config` as `metadata`) into order items so
       catalog edits can never rewrite history;
    6. reserves stock with an atomic conditional `UPDATE ... WHERE stock >= qty`
       so concurrent purchases cannot oversell;
    7. inserts the order and its items inside one transaction, rolling
       everything back (stock included) if any step fails.

  The order's `status` starts at `:awaiting_payment`; payment and fulfillment
  milestones own the later transitions.

  ## What the client can never provide

  `product_name`, `variant_name`, `sku`, `price`, `currency`, the order total,
  `product_id`, ownership, and stock are never read from the request. The
  database is authoritative. The only inputs are variant ids and quantities.

  ## Authorization

  Purchasing is a *customer* action and is deliberately independent of the
  catalog's vendor-management rules: any authenticated account may buy, and
  `create_order/2` refuses guests. Reading orders follows the ownership
  convention of the catalog context: an account sees its own orders, an admin
  sees all, and a foreign or unknown order id is `nil` (`get_order/2`) — the
  same non-enumerable shape a missing order has, so order ids cannot be probed.

  Return conventions: `{:ok, order}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.Scope
  alias Cass.Catalog.ProductVariant
  alias Cass.Fulfillment.Fulfillment
  alias Cass.Orders.{Order, OrderItem}
  alias Cass.Repo

  @not_signed_in "you must be signed in to place an order"
  @invalid_request "the order request is invalid"
  @not_available "an item in the order is not available for purchase"
  @out_of_stock "an item in the order is out of stock"

  @doc """
  Places an order (checkout) for `requested_items` on behalf of `scope`.

  `requested_items` is a list of maps, each with only
  `product_variant_id` (integer or numeric string) and `quantity` (integer).
  Repeated ids are combined. Everything else is resolved server-side inside a
  single transaction, so a failure rolls back the order, its items, and the
  stock reservations together.

  ## Examples

      iex> create_order(scope, [%{product_variant_id: 2, quantity: 3}])
      {:ok, %Order{}}

      iex> create_order(scope, [%{"product_variant_id" => "2", "quantity" => "0"}])
      {:error, %Ecto.Changeset{}}

  """
  def create_order(%Scope{} = scope, requested_items) when is_list(requested_items) do
    if Scope.authenticated?(scope) do
      Repo.transact(fn ->
        with {:ok, cart} <- prepare_cart(requested_items),
             {:ok, cart} <- reserve_stock(cart),
             {:ok, order} <- place_order(scope, cart) do
          {:ok, order}
        else
          {:error, _changeset} = error -> error
        end
      end)
    else
      refusal(%Order{}, @not_signed_in)
    end
  end

  def create_order(_scope, _requested_items) do
    refusal(%Order{}, @invalid_request)
  end

  @doc "Lists the orders `scope` is allowed to see: every order for an admin, only the caller's own for everybody else, nothing for a guest."
  def list_orders(%Scope{} = scope) do
    case orders_query(scope) do
      nil -> []
      query -> Repo.all(query)
    end
  end

  def list_orders(_scope), do: []

  @doc """
  Fetches an order by id **only if** `scope` may see it, returning `nil`
  otherwise.

  A missing order and somebody else's order are deliberately indistinguishable.
  """
  def get_order(%Scope{} = scope, order_id) when is_integer(order_id) do
    case orders_query(scope) do
      nil ->
        nil

      query ->
        Repo.one(from o in query, where: o.id == ^order_id)
    end
  end

  def get_order(%Scope{} = scope, order_id) when is_binary(order_id) do
    case Integer.parse(order_id) do
      {order_id, ""} -> get_order(scope, order_id)
      _not_a_number -> nil
    end
  end

  def get_order(_scope, _order_id), do: nil

  @doc """
  Recomputes an order's total from its snapshot order items, in integer cents.

  Checkout stores exactly this value in `order.total_cents`; this function is
  how callers and tests assert the stored total matches the items.
  """
  def order_total_cents(%Order{order_items: order_items}) do
    Enum.reduce(order_items, 0, fn item, acc -> acc + OrderItem.line_total_cents(item) end)
  end

  @doc """
  Marks an order as `:paid`.

  This is the *one* exit from `:awaiting_payment`, and it is owned by the
  Payments boundary: `Cass.Payments` calls it only after a verified provider
  capture and commits it in the same transaction as the payment becoming
  `:succeeded`. Provider adapters and client code never call it directly.

  It is idempotent for an already-`:paid` order (a repeated webhook is
  harmless) and refuses every other state.
  """
  def mark_order_paid(order_id) when is_integer(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :order_not_found}
      order -> mark_order_paid(order)
    end
  end

  def mark_order_paid(%Order{status: :awaiting_payment} = order) do
    order
    |> Order.changeset(%{status: :paid})
    |> Repo.update()
  end

  def mark_order_paid(%Order{status: :paid} = order), do: {:ok, order}

  def mark_order_paid(%Order{} = order) do
    refusal(order, "the order cannot be paid from its current status")
  end

  def mark_order_paid(_order_id), do: {:error, :order_not_found}

  @doc """
  Fetches an order for a server-side caller that may only act on a **paid** order.

  This is the seam the Fulfillment boundary consumes: payment verification stays
  inside `Cass.Payments`, and everything downstream of a capture asks this
  function instead of reading `cass_orders` itself or re-deciding what "paid"
  means. `Cass.Fulfillment.create_for_paid_order/1` uses it as its authoritative
  gate, so an order that never reached the paid states can never produce a
  fulfillment or an entitlement.

  The order is returned with its snapshot items preloaded (fulfillment is
  created per purchased line). Because the paid statuses are downstream-only,
  an order that has advanced to `:processing`/`:completed` still counts as paid.

  Returns `{:ok, order}`, or:

    * `{:error, :order_not_found}` — no such order (or a malformed id);
    * `{:error, :not_paid}` — the order exists but is not paid.

  This function is intentionally **not** scope-based: like `mark_order_paid/1`
  it is a boundary-to-boundary call made by trusted server code, never by a
  request. Reading an order *for a user* stays `get_order/2`.
  """
  def get_paid_order(order_id) when is_integer(order_id) do
    case Repo.get(Order, order_id) do
      nil ->
        {:error, :order_not_found}

      %Order{} = order ->
        if Order.paid?(order) do
          {:ok, Repo.preload(order, :order_items)}
        else
          {:error, :not_paid}
        end
    end
  end

  def get_paid_order(_order_id), do: {:error, :order_not_found}

  ## Checkout internals

  @doc """
  Marks a paid order `:completed`, once every delivery it owes has been delivered.

  The *only* further exit from `:paid`, and it is deliberately conservative: the
  order advances when **all** of its fulfillments are `:fulfilled`, and never
  otherwise. A terminal-but-unsuccessful delivery (`:failed` or `:cancelled`)
  does not count as success — the purchase is still owed, so the order is not
  complete and support can retry it. Any `:pending` or `:processing` line also
  blocks completion, which is what makes this safe to call early and repeatedly.

  Partially fulfilled orders therefore stay `:paid`. That is the honest state: the
  customer owns a mix of delivered and undelivered lines, and the order is only
  finished when the last line lands.

  Concurrency-safe and idempotent:

    * an already-`:completed` order is returned unchanged, so the delivery worker
    can call this on every successful delivery without coordinating;
    * the `:paid → :completed` write is a conditional `UPDATE` on
    `cass_orders.status`, and the "are all deliveries fulfilled?" test runs
    first in the same transaction, so two workers completing the last two lines
    concurrently cannot both decide on a half-updated view;
    * a concurrent cancel/refund that wins the race causes this to refuse rather
    than resurrect a cancelled order.

  Returns `{:ok, order}`, or:

    * `{:error, :order_not_found}` — no such order;
    * `{:error, :not_paid}` — the order is not in a paid state;
    * `{:error, :not_complete}` — at least one delivery is not `:fulfilled`.

  Payment state is never touched: a completed order keeps its `:succeeded`
  payment and stays refundable, because a refund is a separate, later decision.
  """
  def mark_order_completed(order_id) when is_integer(order_id) do
    Repo.transact(fn ->
      case lock_order(order_id) do
        nil -> {:error, :order_not_found}
        %Order{status: :completed} = order -> {:ok, order}
        %Order{} = order -> complete_paid_order(order)
      end
    end)
  end

  def mark_order_completed(_order_id), do: {:error, :order_not_found}

  # The row lock is what makes the read-then-write below safe: two workers
  # completing the last two lines concurrently serialize here, so the second one
  # observes the first one's commit rather than a half-updated view.
  defp lock_order(order_id) do
    Repo.one(from o in Order, where: o.id == ^order_id, lock: "FOR UPDATE")
  end

  defp complete_paid_order(%Order{status: :paid} = order) do
    if all_fulfillments_fulfilled?(order.id) do
      complete(order)
    else
      {:error, :not_complete}
    end
  end

  defp complete_paid_order(%Order{}), do: {:error, :not_paid}

  # Both counts, deliberately: an order with *no* fulfillments has nothing
  # undelivered and so trivially "all fulfilled" on the unfulfilled query alone.
  # Requiring at least one row is what stops an order that owes nothing from
  # being completed by a delivery event it was never part of.
  defp all_fulfillments_fulfilled?(order_id) do
    unfulfilled =
      Repo.exists?(
        from f in Fulfillment,
          where: f.order_id == ^order_id and f.status != :fulfilled,
          select: 1
      )

    any = Repo.exists?(from f in Fulfillment, where: f.order_id == ^order_id, select: 1)

    any and not unfulfilled
  end

  defp complete(%Order{id: id}) do
    query =
      from o in Order,
        where: o.id == ^id and o.status == :paid

    {count, _} =
      Repo.update_all(query,
        set: [status: :completed, updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

    case count do
      1 -> {:ok, Repo.get!(Order, id)}
      _other -> {:error, :not_paid}
    end
  end

  # Combines duplicated variant ids and validates the shape of every requested
  # item. Produces `%{variant_id => quantity}`.
  defp prepare_cart(requested_items) do
    Enum.reduce_while(requested_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case normalize_request(item) do
        {:ok, id, quantity} ->
          {:cont, {:ok, Map.update(acc, id, quantity, &(&1 + quantity))}}

        :error ->
          {:halt, refusal(%Order{}, @invalid_request)}
      end
    end)
    |> case do
      {:ok, %{} = requested} when map_size(requested) > 0 -> resolve_cart(requested)
      {:ok, %{}} -> refusal(%Order{}, @invalid_request)
      error -> error
    end
  end

  defp normalize_request(%{product_variant_id: id, quantity: quantity}),
    do: normalize_request_values(id, quantity)

  defp normalize_request(%{"product_variant_id" => id, "quantity" => quantity}),
    do: normalize_request_values(id, quantity)

  defp normalize_request(_item), do: :error

  defp normalize_request_values(id, quantity) do
    with {:ok, id} <- positive_integer(id),
         {:ok, quantity} <- positive_integer(quantity),
         :ok <- quantity_within_bound(quantity) do
      {:ok, id, quantity}
    else
      _ -> :error
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp quantity_within_bound(quantity),
    do: if(quantity <= OrderItem.max_quantity(), do: :ok, else: :error)

  # Resolves the variant ids to their current rows and builds the snapshot
  # lines. A missing, inactive, unpriced, or non-sale-eligible variant is the
  # same generic refusal, so a probe cannot learn what a catalog exposes.
  defp resolve_cart(requested) do
    ids = Map.keys(requested)
    now = utc_now()

    variants =
      Repo.all(
        from v in ProductVariant,
          where: v.id in ^ids,
          preload: [product: :category]
      )

    lines =
      Enum.reduce_while(requested, {:ok, []}, fn {id, quantity}, {:ok, acc} ->
        case Enum.find(variants, &(&1.id == id)) do
          nil ->
            {:halt, refusal(%Order{}, @not_available)}

          variant ->
            case purchasable_line(variant, quantity, now) do
              {:ok, line} -> {:cont, {:ok, [line | acc]}}
              {:error, _changeset} = error -> {:halt, error}
            end
        end
      end)

    case lines do
      {:ok, lines} ->
        finalize_cart(lines)

      error ->
        error
    end
  end

  defp purchasable_line(%ProductVariant{} = variant, quantity, now) do
    product = variant.product

    if ProductVariant.purchasable?(variant) and
         product.status == :published and
         product.visibility in [:public, :unlisted] and
         product.category.status == :active and
         due?(product.published_at, now) and
         not is_nil(variant.price_cents) do
      {:ok,
       %{
         variant: variant,
         product: product,
         quantity: quantity,
         product_name: product.name,
         variant_name: variant.name,
         sku: variant.sku,
         unit_price_cents: variant.price_cents,
         currency: variant.currency,
         metadata: variant.config || %{},
         line_total_cents: variant.price_cents * quantity
       }}
    else
      refusal(%Order{}, @not_available)
    end
  end

  # The order must be single-currency: every line's currency comes from its
  # variant, and unless they agree the entire check-out is refused rather than
  # guessing an order currency.
  defp finalize_cart(lines) do
    case Enum.map(lines, & &1.currency) |> Enum.uniq() do
      [currency] ->
        total =
          Enum.reduce(lines, 0, fn line, acc -> acc + line.line_total_cents end)

        {:ok, %{lines: lines, total_cents: total, currency: currency}}

      _currencies ->
        refusal(%Order{}, @not_available)
    end
  end

  # Stock is reserved with an atomic conditional update. The `WHERE`
  # `stock >= quantity` means the row is only changed when sufficient stock is
  # left, and because the UPDATE itself holds the row lock, two concurrent
  # purchases of the same variant serialize: whoever commits first decrements,
  # and the loser's UPDATE re-evaluates against the new value and affects 0
  # rows. Unlimited variants (`stock IS NULL`) need no decrement.
  defp reserve_stock(%{lines: lines} = cart) do
    Enum.reduce_while(lines, {:ok, cart}, fn line, {:ok, cart} ->
      case decrement_stock(line) do
        :ok -> {:cont, {:ok, cart}}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  defp decrement_stock(%{variant: %ProductVariant{stock: nil}}), do: :ok

  defp decrement_stock(%{variant: variant, quantity: quantity}) do
    query =
      from v in ProductVariant,
        where:
          v.id == ^variant.id and v.active == true and not is_nil(v.stock) and
            v.stock >= ^quantity,
        update: [set: [stock: fragment("stock - ?", ^quantity)]]

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> refusal(%Order{}, @out_of_stock)
    end
  end

  defp place_order(%Scope{} = scope, %{lines: lines, total_cents: total, currency: currency}) do
    order_changeset =
      %Order{}
      |> Order.changeset(%{
        number: generate_order_number(),
        status: :awaiting_payment,
        total_cents: total,
        currency: currency
      })
      |> Ecto.Changeset.put_change(:user_id, scope.user.id)

    with {:ok, order} <- Repo.insert(order_changeset),
         {:ok, order} <- insert_order_items(order, lines) do
      {:ok, Repo.preload(order, :order_items)}
    end
  end

  defp insert_order_items(order, lines) do
    Enum.reduce_while(lines, {:ok, order}, fn line, {:ok, order} ->
      changeset =
        %OrderItem{}
        |> OrderItem.changeset(line)
        |> Ecto.Changeset.put_change(:order_id, order.id)
        |> Ecto.Changeset.put_change(:product_variant_id, line.variant.id)

      case Repo.insert(changeset) do
        {:ok, _item} -> {:cont, {:ok, order}}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  defp generate_order_number do
    "C-" <> Base.encode32(:crypto.strong_rand_bytes(6), case: :upper, padding: false)
  end

  ## Authorization and shared internals

  defp orders_query(%Scope{} = scope) do
    cond do
      Scope.admin?(scope) ->
        orders_read_query()

      Scope.authenticated?(scope) ->
        where(orders_read_query(), [o], o.user_id == ^scope.user.id)

      true ->
        nil
    end
  end

  defp orders_read_query do
    from o in Order, order_by: [desc: o.inserted_at, desc: o.id], preload: :order_items
  end

  # The single shape of a checkout/authorization refusal, matching the catalog
  # context: an `{:error, changeset}` on `:base` that never distinguishes the
  # reason an item is unavailable.
  defp refusal(struct, message) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(struct), :base, message)}
  end

  defp due?(nil, _now), do: true
  defp due?(published_at, now), do: DateTime.compare(published_at, now) != :gt

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
