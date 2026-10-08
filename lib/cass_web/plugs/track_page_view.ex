defmodule CassWeb.Plugs.TrackPageView do
  @moduledoc """
  Records a `page_view` analytics event for browser GET requests.

  The plug is deliberately conservative about what it records and never fails a
  request:

  * only `GET` requests, and only those asking for HTML, are tracked;
  * the developer tools (`/dev/…`) are skipped;
  * every value is length-capped (`Cass.Analytics` caps again on the way in).

  It also issues a stable, anonymous **visitor id** stored in the encrypted,
  signed Phoenix session (`cass_visitor_id`). The id contains no personal data;
  it exists only to count distinct visitors across requests without a login.
  Nothing from the request other than the id, path, referrer, and user agent is
  stored.

  Note: navigation *within* a LiveView does not re-run this plug (there is no new
  document request), so this plug counts document loads. LiveView pages emit
  their own higher-level events (`search`, `product_view`) from `handle_params/3`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Cass.Analytics

  @session_key "cass_visitor_id"
  @max_header 512

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if trackable?(conn) do
      {visitor_id, conn} = ensure_visitor(conn)

      Analytics.track("page_view", %{
        visitor_id: visitor_id,
        user_id: current_scope_user_id(conn),
        path: conn.request_path,
        referrer: header(conn, "referer"),
        user_agent: header(conn, "user-agent"),
        metadata: %{"method" => conn.method}
      })

      conn
    else
      conn
    end
  end

  # A document request: a GET that the browser asked to render as HTML, and not
  # an internal tooling path.
  defp trackable?(conn) do
    conn.method == "GET" and
      not String.starts_with?(conn.request_path, "/dev/") and
      accepts_html?(conn)
  end

  defp accepts_html?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] ->
        String.contains?(accept, "text/html") or String.contains?(accept, "*/*")

      [] ->
        true
    end
  end

  defp ensure_visitor(conn) do
    case get_session(conn, @session_key) do
      nil ->
        id = Ecto.UUID.generate()
        {id, put_session(conn, @session_key, id)}

      id ->
        {id, conn}
    end
  end

  defp current_scope_user_id(%{assigns: %{current_scope: %{user: %{id: id}}}}), do: id
  defp current_scope_user_id(_conn), do: nil

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> String.slice(value, 0, @max_header)
      [] -> nil
    end
  end
end
