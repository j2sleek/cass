defmodule CassWeb.PaymentsWebhookController do
  @moduledoc """
  Provider webhook entry points.

  These routes live **outside** the browser pipeline on purpose: a webhook is
  not a browser session (no cookies, no CSRF), and it is authorized not by a
  session but by the provider's signature, which the adapter verifies over the
  raw body before the boundary trusts anything.

  The response code is deliberately coarse:

    * `200` — accepted (a `charge.success`, an irrelevant event, or a no-op
      duplicate), so the provider stops retrying;
    * `400` — the signature does not verify: the payload is not from us;
    * `404` — a correctly signed payload but for an unknown reference, which
      mirrors how the rest of the app refuses probes.

  Order/payment details are never leaked in a webhook response body.
  """

  use CassWeb, :controller

  alias Cass.Payments

  def paystack(conn, _params) do
    raw_body = conn.private[:cass_webhook_raw_body] || ""
    headers = Map.new(conn.req_headers)

    case Payments.handle_webhook(:paystack, raw_body, headers) do
      :ok ->
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 400, "invalid signature")

      {:error, _reason} ->
        send_resp(conn, 404, "not found")
    end
  end
end
