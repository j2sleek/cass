defmodule Cass.Analytics.Writer do
  @moduledoc """
  Buffers analytics events in memory and flushes them to Postgres in batches.

  Recording is a `GenServer.cast/2`, so a request never waits for an insert, and
  several hundred events become one `INSERT ... VALUES (...), (...), ...` rather
  than several hundred statements. The buffer is flushed when it reaches
  `@batch_size` events or after `@flush_interval` milliseconds, whichever comes
  first, so a quiet marketplace still lands its events promptly.

  The trade-off is deliberate: **a crash can lose the buffered events.** That is
  acceptable — these rows measure the product, they do not make it work — and it
  is why `Cass.Analytics.track/2` also swallows write failures instead of
  propagating them.

  In `:test` the writer is disabled (`config :cass, Cass.Analytics, writer: false`)
  so events are inserted synchronously inside the test's Ecto sandbox
  transaction and roll back with the test; see `Cass.Analytics.track/2`.
  """
  use GenServer
  require Logger

  alias Cass.Analytics

  @name __MODULE__
  @batch_size 200
  @flush_interval 2_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Enqueues one already-built event map for the next flush."
  @spec record(map()) :: :ok
  def record(event) when is_map(event) do
    GenServer.cast(@name, {:record, event})
  end

  @impl true
  def init(_opts) do
    {:ok, %{buffer: [], timer: nil}}
  end

  @impl true
  def handle_cast({:record, event}, state) do
    state = %{state | buffer: [event | state.buffer]}

    state =
      if length(state.buffer) >= @batch_size do
        flush(state)
      else
        schedule(state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, flush(state)}
  end

  defp schedule(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, @flush_interval)}
  end

  defp schedule(state), do: state

  defp flush(%{buffer: []} = state) do
    %{state | timer: cancel(state.timer)}
  end

  defp flush(state) do
    events = Enum.reverse(state.buffer)
    _ = Analytics.record_many(events)
    %{state | buffer: [], timer: cancel(state.timer)}
  end

  defp cancel(nil), do: nil

  defp cancel(ref) do
    Process.cancel_timer(ref)
    nil
  end
end
