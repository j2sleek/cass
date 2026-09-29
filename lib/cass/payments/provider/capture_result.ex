defmodule Cass.Payments.Provider.CaptureResult do
  @moduledoc """
  The normalized description of a confirmed or refused capture.

  Produced by `Cass.Payments.Provider.verify_payment/1` and by
  `Cass.Payments.Provider.parse_webhook/2` for payment events. `provider_reference`
  is the reference the capture is for (our own, which we passed to the provider):
  it is how `Cass.Payments` finds the payment row. `amount_cents`/`currency`,
  when present, are cross-checked against the payment snapshot before the order
  is ever paid.
  """

  @type t :: %__MODULE__{
          provider_reference: String.t(),
          status: Cass.Payments.Payment.status(),
          amount_cents: non_neg_integer() | nil,
          currency: String.t() | nil,
          paid_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct [
    :provider_reference,
    :status,
    :amount_cents,
    :currency,
    :paid_at,
    metadata: %{}
  ]
end
