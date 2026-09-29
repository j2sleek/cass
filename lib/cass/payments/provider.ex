defmodule Cass.Payments.Provider do
  @moduledoc """
  The contract every payment provider adapter must fulfil.

  A provider adapter turns a concrete external service (the Paystack API, a
  Stripe API, ...) into a small closed shape so `Cass.Payments` can stay
  provider-neutral. Adapters:

    * never touch `Cass.Orders`, the database, or authorization — they receive
      already-snapshot values and return normalized results;
    * never decide anything about order or payment status beyond the portal
      their result maps speak (`:succeeded`/`:failed`/`:cancelled` for capture,
      plus the normalized `initialize_payment/4` result);
    * are responsible for verifying the authenticity of anything they report,
      most notably webhook signatures.

  Result shapes are the `Cass.Payments.Provider.InitResult` and
  `Cass.Payments.Provider.CaptureResult` structs, defined here so both sides of
  the boundary agree on the data contract.
  """
  alias Cass.Payments.Provider.{CaptureResult, InitResult}

  @typedoc "The provider's name as stored in `payment.provider` (e.g. `:paystack`)."
  @type name :: atom()

  @typedoc "Provider capabilities, drawn from a reserved vocabulary (future-proofing)."
  @type capability :: :checkout | :webhook | :verify | :refund

  @doc "The provider's name as stored in `payment.provider` (e.g. `:paystack`)."
  @callback name() :: name()

  @doc """
  Initializes a checkout with the provider for an exact amount and our reference.

  `email` is the customer's, `amount_cents`/`currency` are the order's
  server-derived snapshot (always minor units), and `provider_reference` is the
  reference CASS generated, passed through as the provider's custom reference so
  webhooks and verifies can be matched back to our row.
  """
  @callback initialize_payment(
              email :: String.t(),
              amount_cents :: non_neg_integer(),
              currency :: String.t(),
              provider_reference :: String.t()
            ) :: {:ok, InitResult.t()} | {:error, term()}

  @doc "Asks the provider directly about the state of a previous reference."
  @callback verify_payment(provider_reference :: String.t()) ::
              {:ok, CaptureResult.t()} | {:error, term()}

  @doc """
  Parses and *verifies* a raw webhook payload.

  Adapters are responsible for checking the authenticity of the payload (for
  example HMAC-SHA512 for Paystack) before trusting anything in it. Returns
  `{:ok, :ignored}` for events that are not a payment capture, `{:ok, capture}`
  for a verified capture, or `{:error, :invalid_signature}` (or another reason)
  when the payload cannot be trusted.
  """
  @callback parse_webhook(raw_body :: binary(), headers :: map()) ::
              {:ok, :ignored} | {:ok, CaptureResult.t()} | {:error, term()}

  @doc "Returns the capabilities this adapter currently implements."
  @callback capabilities() :: [capability()]
end
