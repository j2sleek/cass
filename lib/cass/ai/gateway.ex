defmodule Cass.Ai.Gateway do
  @moduledoc """
  The behaviour every AI gateway adapter implements, and the shapes it returns.

  This is the boundary between CASS and the outside world, and it exists for the
  same reason `Cass.Payments.Provider` does: so that `Cass.Ai` — credit
  accounting, rate limiting, authorization — can be written once and tested
  without a network, and so that replacing the gateway is a new adapter plus a
  config entry rather than a rewrite of the domain.

  ## What an adapter is, and is not, allowed to do

  An adapter is a **transport**: it takes an already-authorized, already-quota-
  checked request and turns it into an HTTP call and a normalized result. It
  never touches the database, never re-checks credits, and never decides who may
  call. Those decisions belong to `Cass.Ai`, and an adapter that could see them
  would be a second place for the same rule to be got wrong.

  It also never *streams* and never returns provider-specific structure. A run is
  one request, one result — the smallest thing that supports the product. Adding
  streaming later is an additive change to this behaviour, not a rewrite of it.

  ## Return conventions

      {:ok, %Cass.Ai.Completion{}}   the gateway answered
      {:error, :unavailable | :refused | :rate_limited | :unauthorized | :invalid_request | :error}

  Error reasons are atoms, never provider strings, so `Cass.Ai` can map them onto
  its own refusal vocabulary and so a caller cannot learn anything about the
  gateway's internals from a message it did not write.
  """
  alias Cass.Ai.Completion

  @typedoc "A gateway adapter's configured name, e.g. `:nexus`."
  @type name :: atom()

  @type reason ::
          :unavailable | :refused | :rate_limited | :unauthorized | :invalid_request | :error

  @doc "Runs one prompt through `model` and returns the completed text."
  @callback complete(model :: String.t(), prompt :: String.t(), opts :: keyword()) ::
              {:ok, Completion.t()} | {:error, reason()}

  @doc "The adapter's own identity, for logs and for `Cass.Ai.gateway_name/0`."
  @callback name() :: name()

  @doc """
  Whether this adapter has everything it needs to make a call.

  Optional, because an adapter may need no configuration at all — but `Nexus`
  does, and a registered gateway with no API key is not a usable gateway. Without
  this callback, `Cass.Ai.available?/0` can only answer "is an adapter
  registered", which reports `true` for a deployment whose key is missing: the
  button is live, the run fails, and the buyer's credit is refunded a second later
  by a refusal that looks like an outage.

  Adapters that need no credentials may omit it; callers must treat absence as
  "assumed configured".
  """
  @callback configured?() :: boolean()

  @optional_callbacks name: 0, configured?: 0
end
