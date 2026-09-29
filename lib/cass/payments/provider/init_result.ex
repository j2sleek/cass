defmodule Cass.Payments.Provider.InitResult do
  @moduledoc """
  The normalized result of a provider initialization.

  Returned (as `{:ok, %Cass.Payments.Provider.InitResult{}}`) by
  `Cass.Payments.Provider.initialize_payment/4`. `provider_reference` is the
  reference the provider accepted (which the boundary generated and passed in),
  `checkout_url` is where the customer is sent to complete payment, `expires_at`
  is the optional hosted-session expiry, and `metadata` carries provider-specific
  details solely for audit/UI display.
  """

  @type t :: %__MODULE__{
          provider_reference: String.t(),
          checkout_url: String.t(),
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct [:provider_reference, :checkout_url, :expires_at, metadata: %{}]
end
