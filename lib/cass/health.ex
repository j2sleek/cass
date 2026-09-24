defmodule Cass.Health do
  @moduledoc """
  Health-check helpers used by the public API health endpoint.

  This is a deliberately small context. It lets the health endpoint
  distinguish application availability (the process is serving) from
  database availability (Ecto can execute a trivial query) without
  revealing any connection details.
  """

  @check_timeout 2_000

  @doc """
  Returns `true` when the configured repository can execute a trivial
  query within a short timeout.

  A failed check is treated as an unhealthy database. Errors are swallowed
  on purpose so no connection details leak to the caller.
  """
  @spec database_up?() :: boolean()
  def database_up? do
    case Cass.Repo.query("SELECT 1", [], timeout: @check_timeout) do
      {:ok, _result} -> true
      _ -> false
    end
  end

  @doc """
  Returns a map describing the current application health.
  """
  @spec payload() :: map()
  def payload do
    db_up = database_up?()
    started = Application.get_env(:cass, :started_monotonic, System.monotonic_time())
    uptime_seconds = System.convert_time_unit(System.monotonic_time() - started, :native, :second)

    %{
      status: if(db_up, do: "ok", else: "degraded"),
      service: "cass",
      version: to_string(Application.spec(:cass, :vsn)),
      environment: to_string(Application.get_env(:cass, :environment, :unknown)),
      database: %{status: if(db_up, do: "up", else: "down")},
      uptime_seconds: uptime_seconds,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
