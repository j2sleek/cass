defmodule Cass.Payments.Providers.Paystack do
  @moduledoc """
  The Paystack payment adapter.

  Implements `Cass.Payments.Provider` against the Paystack REST API using the
  project's `Req` HTTP client. The adapter is intentionally dumb: it receives
  the already-snapshot amount/currency plus our own `provider_reference`, talks
  to Paystack, and returns the normalized shapes of the `Cass.Payments.Provider`
  behaviour. It never touches `Cass.Orders` or the database.

  ## Configuration

  Defined under `config :cass, :paystack`:

    * `:secret_key` — the Paystack secret key (from `PAYSTACK_SECRET_KEY` in
      production, `runtime.exs`; dummy values in dev/test).
    * `:base_url` — defaults to `https://api.paystack.co`.
    * `:req_options` — extra `Req` options, used by the test suite to route
      requests through `Req.Test` (`plug: {Req.Test, :paystack}`).

  ## Webhook verification

  Paystack signs the raw request body with HMAC-SHA512 (hex) using the secret
  key, delivered in the `x-paystack-signature` header. `parse_webhook/2`
  recomputes and comparison-checks it before trusting any payload field, so a
  webhook can never be forged by somebody who does not hold the secret.

  ## Amounts

  Paystack prices in the minor unit of the currency (kobo for NGN, cents for
  USD): the exact integer `amount_cents` this application already uses. The
  currency is passed through unchanged.
  """

  @behaviour Cass.Payments.Provider

  alias Cass.Payments.Provider.{CaptureResult, InitResult}

  @default_base_url "https://api.paystack.co"

  @impl true
  def initialize_payment(email, amount_cents, currency, provider_reference)
      when is_binary(email) and is_integer(amount_cents) and is_binary(currency) and
             is_binary(provider_reference) do
    body = %{
      email: email,
      amount: amount_cents,
      currency: currency,
      reference: provider_reference,
      channels: ["card", "bank", "ussd", "qr", "mobile_money", "bank_transfer"]
    }

    with {:ok, response} <- post("/transaction/initialize", body: body) do
      case response.body do
        %{"status" => true, "data" => %{} = data} when map_size(data) > 0 ->
          {:ok,
           %InitResult{
             provider_reference: Map.get(data, "reference", provider_reference),
             checkout_url: Map.get(data, "authorization_url"),
             expires_at: nil,
             metadata: %{
               "access_code" => Map.get(data, "access_code"),
               "transaction_id" => Map.get(data, "id"),
               "domain" => Map.get(data, "domain")
             }
           }}

        %{"message" => message} ->
          {:error, {:paystack_refused, message}}

        _other ->
          {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def verify_payment(provider_reference) when is_binary(provider_reference) do
    with {:ok, response} <- get("/transaction/verify/#{URI.encode(provider_reference)}") do
      case response.body do
        %{"status" => true, "data" => %{} = data} when map_size(data) > 0 ->
          {:ok,
           %CaptureResult{
             provider_reference: provider_reference,
             status: paystack_status(Map.get(data, "status")),
             amount_cents: Map.get(data, "amount"),
             currency: Map.get(data, "currency"),
             paid_at: parse_paid_at(Map.get(data, "paid_at")),
             metadata: %{"transaction_id" => Map.get(data, "id")}
           }}

        %{"message" => message} ->
          {:error, {:paystack_refused, message}}

        _other ->
          {:error, :unexpected_response}
      end
    end
  end

  @impl true
  def parse_webhook(raw_body, headers) when is_binary(raw_body) do
    with :ok <- verify_signature(raw_body, signature_header(headers)) do
      decode_event(raw_body)
    end
  end

  @impl true
  def name, do: :paystack

  @impl true
  def capabilities, do: [:checkout, :webhook, :verify]

  ## Webhook internals

  defp signature_header(headers) when is_map(headers) do
    case Map.get(headers, "x-paystack-signature") do
      nil -> Map.get(headers, "x_paystack_signature")
      signature -> signature
    end
  end

  defp verify_signature(_raw_body, nil), do: {:error, :invalid_signature}

  defp verify_signature(raw_body, signature) when is_binary(signature) do
    expected =
      :crypto.mac(:hmac, :sha512, secret_key(), raw_body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp decode_event(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"event" => event, "data" => %{} = data}} ->
        case event do
          "charge.success" -> charge_success(data)
          _other -> {:ok, :ignored}
        end

      {:ok, _other_shape} ->
        {:error, :invalid_payload}

      {:error, _error} ->
        {:error, :invalid_payload}
    end
  end

  defp charge_success(data) do
    status = paystack_status(Map.get(data, "status"))

    {:ok,
     %CaptureResult{
       provider_reference: Map.get(data, "reference", ""),
       status: status,
       amount_cents: Map.get(data, "amount"),
       currency: Map.get(data, "currency"),
       paid_at: parse_paid_at(Map.get(data, "paid_at")),
       metadata: %{
         "paystack_event" => "charge.success",
         "transaction_id" => Map.get(data, "id"),
         "provider_status" => Map.get(data, "status"),
         "channel" => Map.get(data, "channel")
       }
     }}
  end

  # Paystack delivery statuses toward our state machine. `abandoned` is a
  # customer that started but never completed the checkout, so it is our
  # `:cancelled`; anything else is reported as failed, never as succeeded.
  defp paystack_status("success"), do: :succeeded
  defp paystack_status("abandoned"), do: :cancelled
  defp paystack_status("failed"), do: :failed
  defp paystack_status(_other), do: :failed

  defp parse_paid_at(nil), do: nil

  defp parse_paid_at(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_paid_at(_other), do: nil

  ## HTTP internals

  defp post(path, body: body) do
    with {:ok, response} <- Req.post(request(), url: path, json: body) do
      {:ok, response}
    end
  end

  defp get(path) do
    with {:ok, response} <- Req.get(request(), url: path) do
      {:ok, response}
    end
  end

  defp request do
    Req.new(request_options())
  end

  defp request_options do
    Keyword.merge(
      [base_url: base_url(), auth: {:bearer, secret_key()}],
      configured() |> Keyword.get(:req_options, [])
    )
  end

  defp configured, do: Application.get_env(:cass, :paystack, [])

  defp base_url, do: Keyword.get(configured(), :base_url, @default_base_url)

  defp secret_key do
    case Keyword.get(configured(), :secret_key) do
      key when is_binary(key) and bit_size(key) > 0 ->
        key

      _missing ->
        raise """
        Paystack secret key is not configured.

        Set `PAYSTACK_SECRET_KEY` and pass it through `config/runtime.exs`, or
        configure a development/test key in `config/dev.exs`/`config/test.exs`.
        """
    end
  end
end
