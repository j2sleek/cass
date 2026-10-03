defmodule Cass.Fulfillment.Worker do
  @moduledoc """
  The asynchronous delivery worker: turns one paid `:pending` fulfillment into a
  delivered purchase with a live entitlement.

  ## Why a worker at all

  Delivery used to be driven by whoever happened to hold a paid order, which
  meant a buyer's access depended on that one request succeeding. Moving it here
  means the purchase is recorded and the delivery is *queued*, in the same
  transaction, and the queue carries the work to completion afterwards. A crash
  between capture and delivery is no longer a lost purchase.

  ## What the worker does not do

  It performs no I/O and holds no locks across a network call. It re-reads the
  row, claims it, and calls the domain transitions — the actual grant and AI
  credit issuance happen inside `Cass.Fulfillment.mark_fulfilled/1`, which is
  already transactional. So there is nothing here that can half-deliver, and no
  external provider this worker can block on.

  ## Eligibility and authorization

  Only `:digital` and `:ai` are automated, decided by
  `Cass.Fulfillment.automatable?/1`. Anything else is a **permanent** failure:
  retrying cannot conjure a vendor integration, and marking a `:smm` or manual
  purchase complete without a real delivery would be a lie the buyer then pays
  for. Those rows stay `:pending` for a human, exactly as before this milestone.

  The job also re-verifies, on every run, that the order is still paid. A queued
  job can outlive the order it belongs to, and a cancelled order must never
  produce an entitlement.

  ## Idempotency

  A duplicate job — from a replayed webhook, a sweep, or a retry — is harmless:

    * `mark_fulfilled/1` on an already-`:fulfilled` row is a no-op;
    * a `:pending` row that another job already claimed is refused here, not
      blindly re-delivered;
    * the entitlement and credit balance grants are unique-indexed
      (`order_item_id`, `entitlement_id`), so even a genuine double-grant race
      cannot double-issue.

  ## Retry policy

  Returns, never raises, so Oban's own retry schedule is the only thing deciding
  how often we try again. The distinction that matters is *retryable* versus
  *permanent*, expressed by the return value: `{:error, reason}` retries with
  backoff, `{:cancel, reason}` stops immediately.

    * `:ok` — delivered, or the purchase was already delivered.
    * `{:cancel, :no_content}` — nothing exists for this id; a payload that will
      never work, so it is cancelled rather than retried eight times.
    * `{:cancel, :unsupported}` — a kind with no automation. Retrying cannot
      conjure a vendor integration, and the row stays `:pending` for a human.
    * `{:cancel, :order_not_paid}` — the order was cancelled/refunded before we
      got here. The purchase is genuinely no longer owed, so retrying would only
      re-check a fact that cannot change back.
    * `{:error, :contended}` — another job owns this row right now. Retried with
      backoff, since it resolves as soon as the other job commits.
    * `{:error, :retry}` — an unexpected internal failure; retried with backoff.

  ## Timeout, and why the sweep threshold is what it is

  `timeout/1` bounds a single attempt at 60 seconds. The work is a few database
  round trips and no I/O, so 60s is already generous; Oban kills and retries past
  it. That bound is what makes `RecoverySweep`'s 15-minute staleness threshold
  sound: a claim older than 15 minutes cannot belong to a live attempt, because
  no live attempt outlives 60 seconds plus Oban's own shutdown grace.

  Args carry only `{"fulfillment_id" => integer}`. No prompts, credentials, or
  customer data are ever placed in the queue.
  """

  use Oban.Worker, queue: :fulfillment, max_attempts: 8

  # Overriding `timeout/1` rather than passing `timeout:` to `use`, because the
  # option is not one Oban accepts there — and this way the bound applies to
  # every job this worker produces, however it was inserted (webhook path,
  # recovery sweep, or a future caller), with no insert site able to forget it.
  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(60)

  require Logger

  alias Cass.Fulfillment
  alias Cass.Fulfillment.Fulfillment, as: FulfillmentRecord
  alias Cass.Orders
  alias Cass.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fulfillment_id" => id, "reclaim" => true}})
      when is_integer(id) do
    run(id, reclaim: true)
  end

  def perform(%Oban.Job{args: %{"fulfillment_id" => id}}) when is_integer(id) do
    run(id, reclaim: false)
  end

  # Only the *shape* of the payload is logged — which keys arrived — never their
  # values. A payload we do not recognise is either corrupt or hostile, and the
  # key names are enough to diagnose it without writing an attacker's data (or
  # a customer's) into the log.
  def perform(%Oban.Job{args: args}) do
    Logger.warning(
      "Cass.Fulfillment.Worker received an unrecognised job payload (keys: #{inspect(Map.keys(args))})"
    )

    {:cancel, :no_content}
  end

  defp run(id, opts) do
    with {:ok, fulfillment} <- fetch(id),
         :ok <- check_paid(fulfillment),
         :ok <- check_automatable(fulfillment),
         {:ok, claimed} <- claim(fulfillment, opts) do
      deliver(claimed)
    else
      # Nothing left to do. Success, not failure: this job had already run.
      {:error, :already_fulfilled} -> :ok
      # Permanent: each of these is a fact about the world that no retry can
      # change, so the job is cancelled instead of burning its attempts.
      {:error, :no_content} -> {:cancel, :no_content}
      {:error, :order_not_paid} -> {:cancel, :order_not_paid}
      {:error, :unsupported} -> {:cancel, :unsupported}
      # Transient: another job owns the row right now, or something inside the
      # domain call failed. Back off and try again.
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(id) do
    case Repo.get(FulfillmentRecord, id) do
      nil -> {:error, :no_content}
      fulfillment -> {:ok, fulfillment}
    end
  end

  # Re-asks the paid-order authority rather than trusting the row's order_id. A
  # job can sit in the queue long after an order was cancelled or refunded, and
  # a grant is only ever legitimate for a paid order.
  defp check_paid(%FulfillmentRecord{order_id: order_id}) do
    case Orders.get_paid_order(order_id) do
      {:ok, _order} -> :ok
      {:error, _reason} -> {:error, :order_not_paid}
    end
  end

  defp check_automatable(%FulfillmentRecord{kind: kind}) do
    if Fulfillment.automatable?(kind), do: :ok, else: {:error, :unsupported}
  end

  # Claims the delivery before delivering it. `:pending` is the normal claim and
  # `:failed` is a retry.
  #
  # A row that is already `:fulfilled` is reported as `:ok` with nothing to do:
  # a duplicate job must not look like a failure, because Oban would then retry
  # a purchase that is genuinely delivered. A row that is `:processing` is
  # reported as contended — another job is mid-flight, and both converge on the
  # unique-indexed grant in `mark_fulfilled/1`.
  defp claim(%FulfillmentRecord{status: status} = fulfillment, _opts)
       when status in [:pending, :failed] do
    case Fulfillment.mark_processing(fulfillment) do
      {:ok, claimed} -> {:ok, claimed}
      {:error, _changeset} -> {:error, :contended}
    end
  end

  defp claim(%FulfillmentRecord{status: :fulfilled}, _opts), do: {:error, :already_fulfilled}

  # A `:processing` row belongs to whichever job claimed it. A *reclaim* job —
  # enqueued by `Cass.Fulfillment.RecoverySweep` only after the row sat
  # untouched past the staleness threshold — takes ownership back, because the
  # previous owner is gone. An ordinary duplicate job does not: it reports
  # contention and lets Oban's retry settle it.
  #
  # `mark_processing/1` on an already-`:processing` row is idempotent, so the
  # reclaim writes nothing and simply proceeds to deliver. If the previous owner
  # turns out to be alive after all, both jobs converge on `mark_fulfilled/1`,
  # whose grants are unique-indexed — so the loser cannot double-grant.
  defp claim(%FulfillmentRecord{status: :processing} = fulfillment, reclaim: true),
    do: {:ok, fulfillment}

  defp claim(%FulfillmentRecord{} = _fulfillment, reclaim: _reclaim), do: {:error, :contended}

  # `mark_fulfilled/1` is where the entitlement and any AI credit balance are
  # granted, transactionally. Everything this worker decides is a question about
  # *when* to call it; the call itself is the domain's business.
  defp deliver(%FulfillmentRecord{} = fulfillment) do
    case Fulfillment.mark_fulfilled(fulfillment) do
      {:ok, delivered} ->
        # Delivered, so the order may now be complete. This is deliberately
        # outside `mark_fulfilled/1`'s transaction: order status is a summary of
        # *all* of an order's lines, and only the last one to land can settle it.
        # `mark_order_completed/1` is idempotent and conservative, so calling it
        # on every successful delivery needs no coordination and no read lock.
        settle_order(delivered)

        Logger.info("Cass.Fulfillment.Worker delivered a purchase",
          fulfillment_id: fulfillment.id,
          kind: fulfillment.kind
        )

        :ok

      {:error, changeset} ->
        # Refused rather than delivered. This is expected when another job won
        # the race, and is reported as contention so it retries quietly instead
        # of recording a failure against a purchase that was in fact delivered.
        Logger.info("Cass.Fulfillment.Worker could not complete a delivery",
          fulfillment_id: fulfillment.id,
          reason: base_error(changeset)
        )

        {:error, :contended}
    end
  end

  # Best-effort: an order that cannot be settled is a reporting gap, never a
  # delivery failure. The entitlement and credits are already committed by this
  # point, so raising here would make Oban retry a purchase that is genuinely
  # delivered and re-deliver it. `:not_complete` simply means another line of
  # this order is still owed.
  defp settle_order(%FulfillmentRecord{order_id: order_id}) do
    case Orders.mark_order_completed(order_id) do
      {:ok, _order} ->
        :ok

      {:error, reason} ->
        Logger.debug("Cass.Fulfillment.Worker left the order incomplete",
          order_id: order_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp base_error(%Ecto.Changeset{errors: errors}) do
    Keyword.get_values(errors, :base) |> List.flatten() |> Enum.join("; ")
  end
end
