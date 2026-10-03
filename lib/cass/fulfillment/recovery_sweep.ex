defmodule Cass.Fulfillment.RecoverySweep do
  @moduledoc """
  Re-enqueues fulfillments that were abandoned mid-flight.

  ## The hole this closes

  A fulfillment row that reaches `:processing` and then loses its worker — the
  node died, the job was killed, the box was OOM-killed — is a purchase that was
  paid for and never delivered, with nothing left in the queue to retry it. Oban
  cannot help: it only knows about jobs, and the job is gone.

  This periodic job finds those rows and puts them back. It runs every five
  minutes via `config/config.exs`.

  ## Staleness threshold

  A `:processing` row is only considered abandoned once it has been untouched
  for `abandoned_after_seconds` (15 minutes in production, configurable, and 60
  seconds in test). The threshold is deliberately far larger than any real
  delivery attempt, because the cost of a premature reclaim is small but not
  zero: two workers on one row. That is handled safely (see below), whereas a
  delivery that never runs at all is a customer who paid and got nothing.

  Note that `:processing` is set by the claim, and the *entire* automated
  delivery — claim, grant, credits — happens inside one job execution with no
  network I/O. So in practice a `:processing` row is only ever seen in this
  state because the worker died, not because it is slow.

  ## Why reclaiming is safe

  Reclaiming does **not** reset the row to `:pending`; that would need a
  `locked_at` column and a lease to expire. Instead the sweep just enqueues a
  fresh job for the row and lets the *worker's* own eligibility and transition
  checks run again:

    * the row is re-read, its order re-checked for `:paid`, and its kind
      re-checked for automation — identical checks to a first delivery;
    * `mark_processing/1` on a `:processing` row is idempotent, so a reclaimed
      job claims the work it already owns;
    * if a genuinely live job is still running, both jobs converge on
      `mark_fulfilled/1`, which grants against a **unique index** on
      `order_item_id` — so the loser gets the winner's grant, never a second
      one;
    * if the row already reached `:fulfilled`, the reclaim is a plain no-op.

  ## Concurrent sweeps

  Two sweeps running at once (a slow sweep overlapping the next tick, or two
  nodes) is harmless: both may select the same row and both may enqueue, and
  duplicate jobs are a no-op as described above. Oban's `unique` option further
  collapses a duplicate that is already queued but not yet running. This is a
  deliberate trade — at-least-once re-enqueue in exchange for not needing a
  lease column on the hot delivery row.

  ## Log hygiene

  Logs how many jobs were enqueued, how many candidates were considered, and the
  threshold in force — counts and ids only. No customer data, no prompts, no
  credentials.
  """

  use Oban.Worker, queue: :sweep, max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Cass.Fulfillment.Worker, as: FulfillmentWorker
  alias Cass.Fulfillment.Fulfillment
  alias Cass.Repo

  @default_abandoned_after_seconds 900

  @doc """
  Returns the staleness threshold in use, in seconds.

  Defaults to 15 minutes. Read from application config so an operator can tune
  recovery without a code change.
  """
  def abandoned_after_seconds do
    :cass
    |> Application.get_env(Cass.Fulfillment, [])
    |> Keyword.get(:abandoned_after_seconds, @default_abandoned_after_seconds)
  end

  @doc """
  Returns the compiled-in default threshold, ignoring application config.

  This is the *production* figure, as opposed to `abandoned_after_seconds/0`
  which reflects whatever is configured right now. Exposed so the relationship
  between the threshold and the worker's attempt timeout can be asserted rather
  than only described.
  """
  def default_abandoned_after_seconds, do: @default_abandoned_after_seconds

  @doc """
  Re-enqueues every `:processing` fulfillment abandoned for longer than the
  configured threshold.

  Returns the number of jobs *actually inserted*. A candidate whose reclaim job
  is already queued collapses into that job and is not counted, so the number is
  the work done, not the work considered.
  """
  @spec sweep(pos_integer) :: non_neg_integer
  def sweep(limit \\ 500) when is_integer(limit) and limit > 0 do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-abandoned_after_seconds(), :second)
      |> DateTime.truncate(:second)

    case abandoned_fulfillment_ids(cutoff, limit) do
      [] ->
        Logger.debug("Cass.Fulfillment.RecoverySweep found nothing to reclaim")
        0

      ids ->
        enqueued = enqueue(ids)

        Logger.info("Cass.Fulfillment.RecoverySweep re-enqueued abandoned fulfillments",
          enqueued: enqueued,
          considered: length(ids),
          stale_after_seconds: abandoned_after_seconds()
        )

        enqueued
    end
  end

  @doc """
  Returns the ids of `:processing` fulfillments untouched since `cutoff`.

  Rows still within the staleness threshold are excluded, so a delivery that is
  merely slow is never reclaimed. Ordered oldest-first so a large backlog drains
  from the rows that have waited longest.
  """
  def abandoned_fulfillment_ids(cutoff, limit \\ 500) do
    Repo.all(
      from f in Fulfillment,
        where: f.status == :processing and f.updated_at < ^cutoff,
        order_by: [asc: f.updated_at, asc: f.id],
        limit: ^limit,
        select: f.id
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, sweep()}
  end

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(120)

  # Inserts one job per reclaimed row, and reports how many were inserted.
  #
  # `Oban.insert/2` is used rather than `insert_all/3` because the basic engine
  # only applies unique-job constraints on a single insert: a duplicate reclaim
  # of a row that already has a job queued collapses into that existing job
  # instead of adding a redundant one. In `insert_all/3` every row would go in.
  #
  # `fields: [:args, :worker]` keys uniqueness on the fulfillment id within this
  # worker, which is exactly the granularity we want: two sweeps reclaiming the
  # same row dedupe, while a legitimate reclaim of a *different* row is never
  # suppressed.
  #
  # The period is 10 minutes, deliberately *longer* than the 5-minute cron tick.
  # Oban scopes a uniqueness conflict to jobs inserted within that period, so a
  # period equal to the tick interval would let a sweep that runs a few seconds
  # late past the boundary and insert a duplicate. Two ticks of margin removes the
  # race. This is a load-shedding optimisation, not a correctness mechanism:
  # correctness comes from the guarded transitions and unique-indexed grants in
  # the worker, so a duplicate that slips through anyway is harmless.
  defp enqueue(ids) do
    Enum.count(ids, fn id ->
      # `"reclaim" => true` tells the worker this row's previous owner is gone,
      # so it may take over a `:processing` claim instead of reporting
      # contention. Everything else the worker checks is unchanged.
      job =
        FulfillmentWorker.new(%{"fulfillment_id" => id, "reclaim" => true},
          unique: [fields: [:args, :worker], period: 600]
        )

      case Oban.insert(job) do
        # A uniqueness conflict is not an error and not an insert: Oban returns
        # the *existing* job flagged `conflict?: true`. The reclaim is already
        # queued, so this is a success for the purchase and must not be counted.
        {:ok, %{conflict?: true}} ->
          false

        {:ok, _inserted} ->
          true

        {:error, changeset} ->
          # A real insert failure. Log it rather than swallowing it, and never
          # let one bad row stop the others.
          Logger.warning("Cass.Fulfillment.RecoverySweep could not enqueue a reclaim",
            fulfillment_id: id,
            reason: inspect(changeset.errors)
          )

          false
      end
    end)
  end
end
