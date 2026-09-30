defmodule Cass.Delivery do
  @moduledoc """
  The Delivery & Access boundary: how a buyer's entitlement is *exercised*.

  The chain built so far proves a purchase and records the right it created:

      paid order → order item → fulfillment → entitlement

  An entitlement answers **"does this customer hold the right?"** This context
  answers the separate question **"how is that right exercised?"** and the two
  are never collapsed:

      entitlement → delivery / access

  Keeping them apart is what lets the delivery *mechanism* change — a different
  provider, a real object store, a human handoff — without touching a single
  ownership, revocation, or purchase-history fact. Revocation withdraws the
  right (an `Entitlement` fact); it does not have to know what that right was
  being used for.

  ## No new table, deliberately

  Delivery introduces **no schema, no migration, and no new table**. Every input
  an access decision needs is already stored, and stored immutably:

    * `Cass.Fulfillment.Fulfillment` — the delivery obligation, its lifecycle,
      and `kind`: the delivery *mechanism*, resolved once from the purchased
      product's type and snapshotted so a catalog edit cannot rewrite how a past
      purchase must be delivered;
    * `Cass.Entitlements.Entitlement` — the buyer's right, its status, its
      `expires_at`, and the immutable purchase snapshot *including* the
      catalog-controlled delivery instructions (`metadata`, copied from
      `ProductVariant.config` at checkout).

  A `cass_deliveries` table would therefore re-store `user_id`, `order_id`,
  `order_item_id`, and `product_type`, and would need a second lifecycle beside
  the one `Cass.Fulfillment` already owns — a denormalization with no
  corresponding new fact. The provider-facing half of delivery (a real object
  store, an SMM API, an AI gateway) genuinely will need persistent state, and
  `Cass.Fulfillment.Fulfillment` documents where that belongs: a
  delivery-attached table, added when the first provider needs it. That is a
  later milestone, not this one.

  ## Idempotency

  Access is a **pure read**: no rows are written, so there is no read-then-write
  window and nothing to double-insert. The representation is a deterministic
  function of the immutable purchase ids and the server's signing secret, so
  two calls for the same entitlement return byte-identical results — a retried
  request, a concurrent tab, and a re-render all show the buyer the same thing.
  The derivation is private and pinned by test through `authorize_access/2`.

  ## The access check is the authorization

  `authorize_access/2` is the single authoritative decision, and it is the only
  place that turns a right into a capability. It composes three facts, in this
  order, and grants only when all three hold:

      authenticated scope  +  active entitlement  +  exercisable mechanism

  Ownership is resolved through `Cass.Entitlements.get_entitlement/2`, which
  applies the same owner-or-admin rule as the catalog, orders, payments, and
  fulfillment contexts before this context ever sees a row. Nothing here reads a
  user id from a parameter: the only identity in play is the
  `Cass.Accounts.Scope` that `CassWeb.UserAuth` resolved server-side from the
  session. That is why a caller cannot forge ownership by supplying a
  `user_id`, a `customer_id`, or an `owner_id` — there is no field to supply it
  in.

  Entitlement state is centralized too: the check calls
  `Cass.Entitlements.Entitlement.active?/1` rather than re-reading
  `status == :active`. That single predicate is what already accounts for a
  lapsed `expires_at` before anything writes the `:expired` status, so a revoked
  or elapsed grant cannot be exercised, and no controller or LiveView has to
  reimplement the rule to get it right.

  ## Enumeration resistance

  Every refusal is one indistinguishable `:base` error — the same shape the
  catalog, orders, payments, fulfillment, and entitlements contexts already use.
  An unknown entitlement, somebody else's, a revoked one, an elapsed one, and one
  whose mechanism is not yet exercisable are all refused identically, and the web
  layer renders all of them as the same not-found state. A probe cannot learn
  whether an id exists, let alone why access was refused.

  ## Delivery kinds

  Kinds are **not** re-invented here. `Cass.Fulfillment.kind` is the one
  taxonomy, and `kinds/0` and `kind_for/1` delegate to it, so there is no
  second product-classification system to drift:

      digital → instant delivery of a file, access, or license
      smm     → automated delivery through a provider API
      ai      → entitlement/credits issued through the AI gateway
      manual  → fulfillment performed by a human

  ## Mechanisms: the contract is established, one is implemented

  A kind answers *what kind of delivery this is*; a **mechanism** answers *what
  this context can actually hand over right now*. `mechanism_for/1` is the
  single extension point, and the distinction is what keeps this milestone
  honest — the vocabulary already covers the marketplace's four product
  categories, while exactly one of them is exercisable:

      :digital → :access_code  (implemented)
      :smm     → not yet exercisable
      :ai      → not yet exercisable
      :manual  → not yet exercisable

  The unimplemented kinds refuse access rather than inventing a placeholder
  capability. Each is a small, local addition to `mechanism_for/1` plus its
  representation in `Cass.Delivery.Access` once a real mechanism exists — with
  no change to Orders, Payments, Fulfillment, or Entitlements, which is the
  property this milestone exists to establish.

  ## No provider abstraction yet

  There is deliberately no `Cass.Delivery.Provider` behaviour and no provider
  registry, because exactly one mechanism is implemented and a registry of one
  is speculative scaffolding. `Cass.Payments.Provider` is the precedent for when
  that stops being true: it is justified by two adapters and a configuration
  surface. `mechanism_for/1` is where the second mechanism lands; the behaviour
  arrives with it.

  ## Redaction

  An access capability is a response, so it is assembled from named,
  whitelisted fields and never by passing catalog metadata through. This matters
  because `metadata` is a free-form JSONB map a vendor controls, so it may
  legitimately contain anything the vendor typed into their product config.

  The consequence is structural: a vendor who puts an API key, an internal token,
  or a storage URL in their product config cannot leak it to a buyer, because the
  access path reads **no free-form metadata at all** — it is assembled from the
  entitlement's typed columns, and the only variable is a delivery code this
  server derives. There is no "redirect to a configured URL" path to abuse, now
  or later: a real download will have to be a signed, server-issued grant, which
  is a deliberate later-milestone decision.

  Return conventions: `{:ok, %Access{}}` / `{:error, changeset}`.
  """
  alias Cass.Accounts.Scope
  alias Cass.Delivery.Access
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Fulfillment

  @refused "this purchase cannot be accessed"

  # Crockford-style base32: digits plus unambiguous letters (no I, L, O, or U),
  # so a code read aloud or retyped by a buyer is not misread.
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @code_groups 4
  @code_group_length 4

  @doc "Returns the closed vocabulary of delivery kinds."
  defdelegate kinds(), to: Fulfillment, as: :kinds

  @doc """
  Returns the delivery kind for a product or product type.

  Delegates to `Cass.Fulfillment.kind_for/1` so the mapping exists in exactly one
  place; this context resolves a mechanism from that kind, it does not decide
  what the kind is.

  ## Examples

      iex> Cass.Delivery.kind_for(:ai)
      :ai

      iex> Cass.Delivery.kind_for(:service)
      :manual

  """
  defdelegate kind_for(product_or_type), to: Fulfillment

  @doc """
  Returns the exercisable mechanism for a delivery kind, or `nil` when this
  milestone has no mechanism for it.

  This is the extension point. Adding a second mechanism means adding a clause
  here and the matching representation in `Cass.Delivery.Access` — nothing in
  Orders, Payments, Fulfillment, or Entitlements moves.

  ## Examples

      iex> Cass.Delivery.mechanism_for(:digital)
      :access_code

      iex> Cass.Delivery.mechanism_for(:smm)
      nil

  """
  def mechanism_for(:digital), do: :access_code
  def mechanism_for(kind) when kind in [:smm, :ai, :manual], do: nil
  def mechanism_for(_kind), do: nil

  @doc """
  Authorizes `scope` to exercise the entitlement identified by
  `entitlement_id`, returning the capability it grants.

  This is the one authoritative access decision in the application. It grants
  only when all of the following hold:

    * `scope` is an authenticated `Cass.Accounts.Scope` resolved server-side
      from the session (a guest is refused);
    * the entitlement belongs to that scope — an owner, or an admin, resolved
      through `Cass.Entitlements.get_entitlement/2`, which is owner-or-admin;
    * the entitlement is currently active, per
      `Cass.Entitlements.Entitlement.active?/1`, so a **revoked** grant and a
      grant whose `expires_at` has **elapsed** are both refused;
    * its delivery kind has a mechanism this context can actually issue.

  Returns `{:ok, %Access{}}`, or `{:error, changeset}` with one
  indistinguishable `:base` message for every refusal — unknown id, somebody
  else's id, revoked, elapsed, or not yet exercisable. A caller cannot use the
  response to learn which, and the web layer renders all of them as the same
  not-found state.

  This function takes no other identity: there is no `user_id` argument a
  browser could populate, so ownership cannot be forged from a request.
  """
  def authorize_access(%Scope{} = scope, entitlement_id) do
    with {:ok, entitlement} <- fetch(scope, entitlement_id),
         {:ok, fulfillment} <- delivery_for(entitlement),
         {:ok, mechanism} <- exercisable(fulfillment.kind) do
      {:ok, build_access(entitlement, fulfillment, mechanism)}
    end
  end

  def authorize_access(_scope, _entitlement_id), do: refuse()

  ## Internals

  # Ownership is not re-decided here: `Entitlements` applies the owner-or-admin
  # rule and already returns `nil` for a foreign *and* for an unknown id, which
  # is exactly the indistinguishability this context must preserve.
  defp fetch(%Scope{} = scope, entitlement_id) do
    case Entitlements.get_entitlement(scope, entitlement_id) do
      %Entitlement{} = entitlement ->
        # A guest scope resolves to `nil` here, and an idle grant fails the
        # centralized predicate, so both are refused with the same changeset.
        if Scope.authenticated?(scope) and Entitlement.active?(entitlement) do
          {:ok, entitlement}
        else
          refuse()
        end

      nil ->
        refuse()
    end
  end

  # The mechanism is a property of the delivery that granted the right, not of
  # the entitlement, so the grant is followed back to its fulfillment, which
  # `Cass.Entitlements` preloads on the same authorized read.
  #
  # An un-preloaded grant is refused rather than resolved with a second,
  # out-of-band read. Nothing on this path needs to work around a missing
  # association: the only public entry point always arrives from `fetch/2`, so
  # taking that shortcut would only open a way to read a delivery that the
  # authorization read did not already cover.
  defp delivery_for(%Entitlement{fulfillment: %Fulfillment.Fulfillment{} = fulfillment}) do
    {:ok, fulfillment}
  end

  defp delivery_for(_entitlement), do: refuse()

  defp exercisable(kind) do
    case mechanism_for(kind) do
      nil -> refuse()
      mechanism -> {:ok, mechanism}
    end
  end

  # Built from named, typed columns only. The purchase's `metadata` map is never
  # read on the access path, so no vendor-authored value — a key, a token, a URL
  # — can reach a buyer, and there is no filter here to get wrong later.
  defp build_access(%Entitlement{} = entitlement, fulfillment, mechanism) do
    %Access{
      entitlement_id: entitlement.id,
      kind: fulfillment.kind,
      product_type: entitlement.product_type,
      product_name: entitlement.product_name,
      variant_name: entitlement.variant_name,
      sku: entitlement.sku,
      quantity: entitlement.quantity,
      mechanism: mechanism,
      access_code: credential(entitlement, mechanism),
      granted_at: entitlement.granted_at,
      expires_at: entitlement.expires_at
    }
  end

  defp credential(%Entitlement{} = entitlement, :access_code),
    do: derive_code(entitlement.order_item_id)

  defp credential(_entitlement, _mechanism), do: nil

  # `XXXX-XXXX-XXXX-XXXX` from the first 80 bits of an HMAC over the immutable
  # purchased-line id, in a base32 alphabet a buyer can retype. 80 bits is
  # exactly 16 five-bit symbols, so the encoding needs no padding.
  #
  # This is a **local, self-contained stand-in** for whatever a real product
  # would use — a license-key service, a signed download grant, an SMM order
  # reference. It exists so the access boundary is exercisable and testable end
  # to end without an external provider, and it is deliberately the only
  # credential this milestone issues.
  #
  # It is **private on purpose**. A public "give me the code for this
  # entitlement" function would be a second, authority-free way to mint a
  # credential for any entitlement struct a caller happened to hold, which would
  # quietly become the real access decision and bypass every check in
  # `authorize_access/2`. Derivation is therefore reachable only from an
  # entitlement that has already passed authorization.
  #
  # The properties it rests on, all pinned by test: deterministic per purchase
  # (a retried request or a second tab shows the same code), unforgeable
  # without the server secret, and an HMAC output that reveals nothing about
  # that secret.
  defp derive_code(order_item_id) do
    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        access_secret(),
        "cass-delivery:order-item:#{order_item_id}"
      )

    digest
    |> binary_part(0, div(@code_groups * @code_group_length * 5, 8))
    |> base32()
    |> format_code()
  end

  defp base32(bytes) do
    total_bits = byte_size(bytes) * 8
    integer = :binary.decode_unsigned(bytes)

    for index <- 0..(div(total_bits, 5) - 1) do
      # Most significant group first, so the leading character carries the
      # highest entropy rather than being zero. The alphabet is a charlist, so
      # each index has to become its own one-byte binary before joining.
      shift = total_bits - (index + 1) * 5
      <<Enum.at(@alphabet, Bitwise.band(Bitwise.bsr(integer, shift), 0x1F))>>
    end
    |> IO.iodata_to_binary()
  end

  defp format_code(code) do
    code
    |> String.graphemes()
    |> Enum.chunk_every(@code_group_length)
    |> Enum.map_join("-", &Enum.join/1)
  end

  # A signing secret is required to issue a credential, and it is injected per
  # environment the same way the payment secret is. It is read per call rather
  # than baked in at compile time, so a rotated secret takes effect without a
  # recompile, and so a missing value is caught at the moment of issue instead
  # of at boot.
  defp access_secret do
    case Application.get_env(:cass, Cass.Delivery, []) |> Keyword.get(:access_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        secret

      _missing ->
        raise """
        Cass.Delivery access secret is not configured.

        Set `DELIVERY_ACCESS_SECRET` and pass it through `config/runtime.exs`, or
        configure a development/test key in `config/dev.exs`/`config/test.exs`.
        """
    end
  end

  # The single shape of a refusal, matching every other context: a `:base`
  # changeset that never distinguishes the reason, so a caller cannot tell an
  # unknown id from a foreign one from a revoked one.
  #
  # The changeset is anchored on `%Entitlement{}` because the entitlement is the
  # thing that cannot be accessed, and because `Cass.Delivery.Access` is
  # deliberately *not* an `Ecto.Schema` — it is a read-only response with no
  # table behind it, so there is nothing to run a changeset against. This
  # changeset carries the message and nothing else.
  defp refuse do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(%Entitlement{}), :base, @refused)}
  end
end
