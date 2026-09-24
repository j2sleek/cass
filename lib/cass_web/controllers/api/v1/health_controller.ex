defmodule CassWeb.Api.V1.HealthController do
  use CassWeb, :controller

  @doc """
  Read-only health check.

  Returns `200` when the application is serving and the database responds,
  and `503` (with a structured body) when the application is up but the
  database is unavailable. Connection failures never reveal credentials or
  stack traces.
  """
  def show(conn, _params) do
    payload = Cass.Health.payload()

    conn
    |> put_status(if(payload.status == "ok", do: 200, else: 503))
    |> json(payload)
  end
end
