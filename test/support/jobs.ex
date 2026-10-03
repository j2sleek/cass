defmodule Cass.Jobs do
  @moduledoc """
  Test helpers for the Oban-backed fulfillment queue.

  Oban runs in `:manual` mode for the whole suite (see `config/test.exs`), so no
  job ever executes unless a test asks for it. That is what lets the payment
  tests assert that a job was queued inside the capture transaction without a
  worker racing the assertion, while these helpers let the worker, sweep, and
  retry tests actually run jobs.

  Everything here operates inside the caller's Ecto sandbox transaction, so
  drained jobs and the rows they write roll back with the test.
  """

  import Ecto.Query, warn: false

  alias Cass.Repo

  @doc """
  Returns every queued job, oldest first.

  Use this to assert what *was* enqueued rather than running anything.
  """
  def all_jobs do
    Repo.all(from j in Oban.Job, order_by: [asc: j.id])
  end

  @doc """
  Returns the queued jobs for one worker module.
  """
  def jobs_for(worker) when is_atom(worker) do
    # `Oban.Worker.to_string/1` is what Oban itself stores (it strips the
    # `Elixir.` prefix), so this is the exact value in `oban_jobs.worker`.
    name = Oban.Worker.to_string(worker)

    Repo.all(from j in Oban.Job, where: j.worker == ^name, order_by: [asc: j.id])
  end

  @doc """
  Returns the args of every queued job for `worker`.
  """
  def args_for(worker) do
    worker |> jobs_for() |> Enum.map(& &1.args)
  end

  @doc """
  Returns how many jobs are queued for `worker`.
  """
  def count_for(worker) do
    name = Oban.Worker.to_string(worker)
    Repo.one(from j in Oban.Job, where: j.worker == ^name, select: count(j.id))
  end

  @doc """
  Runs every queued job for `worker` synchronously and returns the results.

  Each `perform/1` is invoked exactly as Oban would, so a worker that returns an
  error tuple is recorded as a failed execution — which is what the retry and
  crash tests need to observe.
  """
  def drain(worker) when is_atom(worker) do
    worker
    |> jobs_for()
    |> Enum.map(fn job ->
      result = worker.perform(job)
      record(worker, job, result)
      {job, result}
    end)
  end

  @doc """
  Drains every queued job for `worker` and returns only the result tuples.
  """
  def drain_results(worker) do
    worker |> drain() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Drains `worker` until a job succeeds or `max_rounds` are exhausted.

  Models Oban's retry loop closely enough for the tests that care about
  eventual delivery: a job that reports `:contended` is retried, a job that
  reports a permanent error stops.
  """
  def drain_until(worker, max_rounds \\ 5) do
    Enum.reduce_while(1..max_rounds//1, [], fn _round, results ->
      case drain_results(worker) do
        [] -> {:halt, Enum.reverse(results)}
        results -> {:cont, Enum.reverse(results)}
      end
    end)
  end

  @doc """
  Marks a queued job as executed, so a later `drain/1` does not see it again.

  Mirrors what Oban does after a successful `perform/1`.
  """
  def complete!(job) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    job
  end

  @doc """
  Ages a fulfillment row's `updated_at` backwards, simulating a worker that
  claimed it and then died.

  The recovery sweep only reclaims a `:processing` row older than the configured
  staleness threshold, so tests move the row rather than waiting.
  """
  def age_fulfillment(fulfillment_id, seconds) do
    Repo.update_all(
      from(f in Cass.Fulfillment.Fulfillment, where: f.id == ^fulfillment_id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
    )
  end

  @doc """
  Puts a fulfillment row into `:processing`, as a live worker would.
  """
  def claim!(fulfillment) do
    {:ok, claimed} = Cass.Fulfillment.mark_processing(fulfillment)
    claimed
  end

  defp record(_worker, job, :ok), do: complete!(job)

  defp record(_worker, job, {:ok, _value}), do: complete!(job)

  defp record(worker, job, {:error, reason}) do
    # Matches Oban's own accounting so a failed execution is visible and cannot
    # be drained twice by accident.
    attempt = job.attempt + 1
    discarded = attempt >= worker.__opts__()[:max_attempts]

    Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [attempt: attempt, state: if(discarded, do: "discarded", else: "retryable")]
    )

    reason
  end

  defp record(_worker, _job, other), do: other
end
