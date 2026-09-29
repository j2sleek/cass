defmodule CassWeb.Plug.RawBodyReader do
  @moduledoc """
  Captures the raw (unparsed) request body for later signature verification.

  Plugged in as the `:body_reader` of `Plug.Parsers` in `CassWeb.Endpoint`, this
  delegates to the normal `Plug.Conn.read_body/2` and additionally stashes the
  accumulated bytes in `conn.private[:cass_webhook_raw_body]`. Webhook
  controllers read that key and hand it to the payment provider adapter, which
  verifies the provider signature (e.g. Paystack's HMAC-SHA512) over exactly
  these raw bytes — signature checks over re-encoded JSON are fragile, so the
  plain bytes must survive parsing untouched.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      put_in(
        conn.private[:cass_webhook_raw_body],
        (conn.private[:cass_webhook_raw_body] || "") <> body
      )

    {:ok, body, conn}
  end
end
