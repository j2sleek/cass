defmodule Cass.Delivery.Access do
  @moduledoc """
  What a buyer is actually allowed to *do* with an entitlement.

  An entitlement says the purchase succeeded and the buyer holds the right
  (`Cass.Entitlements.Entitlement`). This struct is the answer to the next
  question: how is that right exercised? It is the only thing the web layer
  renders, and it is deliberately **not** the entitlement re-serialized — it is
  a narrowed, validated view of it.

  ## Why a separate shape

  Delivery is a different concern from ownership, and the two have opposite
  disclosure rules:

    * an entitlement is a *record*, so it is complete — it snapshots the
      purchase exactly as it was bought;
    * an access capability is a *response*, so it carries only what the holder
      needs to use the right, and nothing else.

  Keeping them apart is what makes the redaction in `Cass.Delivery` a
  structural property rather than a promise: `Cass.Delivery` builds this struct
  from named fields, so there is no code path by which an unvetted column — a
  credential, an internal URL, a payment reference — can reach a response. The
  struct has no field to put one in.

  ## Fields

    * `:entitlement_id` — the grant that authorized this capability.
    * `:kind` — the delivery mechanism (`Cass.Delivery.kinds/0`).
    * `:product_type` — what was bought, snapshotted.
    * `:product_name` / `:variant_name` / `:sku` / `:quantity` — the immutable
      purchase, as granted.
    * `:mechanism` — how the right is exercised here, from the implemented
      mechanism for `kind`.
    * `:access_code` — the exercisable credential, for mechanisms that issue
      one. `nil` for mechanisms that do not.
    * `:granted_at` / `:expires_at` — when the right was granted and, for a
      time-bounded one, when it lapses. `expires_at` is reported even when it
      has passed: the holder is entitled to know *why* access stopped.

  The struct carries no secret. An access code is the product the buyer paid
  for, not infrastructure: it is derived from the server's signing secret, so
  the secret itself can never appear here, and no field is ever populated from
  raw catalog metadata (see `Cass.Delivery`).
  """
  @derive {Inspect, except: [:access_code]}
  defstruct [
    :entitlement_id,
    :kind,
    :product_type,
    :product_name,
    :variant_name,
    :sku,
    :quantity,
    :mechanism,
    :access_code,
    :granted_at,
    :expires_at
  ]

  @type t :: %__MODULE__{
          entitlement_id: pos_integer(),
          kind: atom(),
          product_type: atom(),
          product_name: String.t(),
          variant_name: String.t(),
          sku: String.t() | nil,
          quantity: pos_integer(),
          mechanism: atom(),
          access_code: String.t() | nil,
          granted_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }

  @doc """
  Returns true when this capability issues a credential the buyer can present.

  ## Examples

      iex> Cass.Delivery.Access.credential?(%Cass.Delivery.Access{mechanism: :access_code})
      true

      iex> Cass.Delivery.Access.credential?(%Cass.Delivery.Access{mechanism: :download})
      false

  """
  def credential?(%__MODULE__{mechanism: :access_code}), do: true
  def credential?(%__MODULE__{}), do: false
end
