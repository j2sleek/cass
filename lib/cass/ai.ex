defmodule Cass.Ai do
  @moduledoc """
  The `:ai` leg: what an AI purchase grants, and how a run spends it.

  ## The chain

      paid order → fulfillment → entitlement → credit balance → run

  An AI entitlement is granted exactly like any other (`Cass.Fulfillment`), and
  then, in the **same transaction**, this context issues its credit pool. Because
  the insert is `ON CONFLICT DO NOTHING` against the unique index on
  `entitlement_id`, re-running fulfillment — a retry, a duplicate webhook, a
  second worker — returns the existing balance and grants nothing extra. The
  invariant is the same one `Cass.Entitlements` rests on: an entitlement can
  never exist without the balance it implies, and a balance can never exist
  without the entitlement that paid for it.

  ## Credits come from the purchase, not from the catalog

  `granted_credits/1` reads the **ordered variant's** snapshotted `config` —
  the same immutable `metadata` the entitlement already carries — so re-pricing
  or editing the product afterwards cannot change what a buyer already paid for.
  A variant that pins nothing usable gets **zero** credits rather than a default:
  a silent default would let a misconfigured product sell access to a metered
  capability it never promised.

  ## Spending is atomic

  A run does not read the balance, decide, and write back. It issues one
  conditional `UPDATE ... WHERE consumed < granted`, and the row that comes back
  is the proof the spend happened. Two runs racing for the last credit cannot
  both win — the loser's update matches no rows, which is how `:no_credits` is
  detected. See `Cass.Ai.CreditBalance`.

  ## Authorization

  `complete/3` takes the same `Cass.Accounts.Scope` every other context does and
  reaches the entitlement through `Cass.Entitlements.get_entitlement/2`, so
  ownership, revocation, and expiry are decided in exactly one place. There is no
  `user_id` argument and nothing reads an identity from the request: a foreign or
  unknown entitlement id is refused identically to an unentitled one, and a
  **credit is not consumed** for a refusal.

  ## Rate limiting and logging

  Every attempt writes a `Cass.Ai.Run`, including the ones CASS refuses before
  anything leaves the process — a limiter that cannot see its own refusals is
  blind to exactly the traffic it exists to catch. Attempts are counted per
  buyer over a sliding window (`config :cass, Cass.Ai, rate_limit:`), and the
  rate limiter is checked **before** the credit is spent, so a throttled caller
  is not charged for being throttled.

  ## What this context deliberately does not do

  It does not stream, does not price tokens, does not cache completions, and does
  not retry a failed gateway call. A retry is a *new* run and costs a *new*
  credit; refunding a credit on gateway failure is handled explicitly below
  rather than being an automatic side effect.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.Scope
  alias Cass.Ai.{Completion, CreditBalance, Gateway, Gateways, Run}
  alias Cass.Entitlements
  alias Cass.Entitlements.Entitlement
  alias Cass.Repo

  @default_rate_limit [max_runs: 10, window_seconds: 60]
  @refused "this AI purchase cannot be run"
  @no_credits "you have no AI credits left"
  @throttled "you are sending requests too quickly"
  @too_long "that prompt is too long"

  # Enforced here, not only by the panel's `maxlength`. A `maxlength` is a
  # courtesy to a buyer's typing; this is the rule, and the only place that can
  # hold when the request arrives from anything other than that form.
  @max_prompt_chars 8_000

  # `config["credits"]` — the vendor's declared pool for the ordered variant.
  @credits_key "credits"
  @model_key "model"

  @doc """
  Issues the credit pool an entitlement is owed, idempotently.

  Called by `Cass.Fulfillment.mark_fulfilled/1` inside the fulfillment
  transaction, and only for an `:ai` delivery: a digital or manual purchase gets
  no balance, so *the absence of a row* is what "not metered" means.

  `ON CONFLICT DO NOTHING` makes this safe to call repeatedly — a retried
  delivery or a duplicate webhook returns the existing balance rather than
  creating a second pool, which is what keeps "one purchase, one pool" a
  database guarantee instead of a convention.
  """
  @spec issue_credits(Entitlement.t()) :: {:ok, CreditBalance.t()}
  def issue_credits(%Entitlement{product_type: :ai} = entitlement) do
    attrs = %{
      entitlement_id: entitlement.id,
      user_id: entitlement.user_id,
      granted: granted_credits(entitlement)
    }

    %CreditBalance{}
    |> CreditBalance.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: :entitlement_id,
      returning: true
    )
    |> case do
      # `ON CONFLICT DO NOTHING` returns no fields, so the existing row is read
      # back. It is inside the same transaction as the conflict, so it observes
      # the committed-or-in-flight winner rather than racing it.
      {:ok, %CreditBalance{id: nil}} -> {:ok, fetch_balance(entitlement.id)}
      {:ok, %CreditBalance{} = balance} -> {:ok, balance}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def issue_credits(%Entitlement{}), do: {:ok, nil}

  @doc """
  The credits `entitlement` is owed, read from its snapshotted purchase.

  Reads the ordered variant's `config`, which the entitlement carries
  immutably. Anything that is not a non-negative integer is **zero**, not a
  default: a misconfigured product must fail closed rather than hand out a pool
  its vendor never priced.
  """
  @spec granted_credits(Entitlement.t()) :: non_neg_integer()
  def granted_credits(%Entitlement{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @credits_key) do
      credits when is_integer(credits) and credits >= 0 -> credits
      _anything_else -> 0
    end
  end

  def granted_credits(%Entitlement{}), do: 0

  @doc """
  The model this entitlement's runs request.

  Server-chosen from the purchase snapshot when the variant pins one, otherwise
  the gateway's default. A model name is never taken from a request body: it
  decides which provider model absorbs the cost, so it has to be something the
  buyer bought rather than something they typed.
  """
  @spec model_for(Entitlement.t()) :: String.t() | nil
  def model_for(%Entitlement{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @model_key) do
      model when is_binary(model) and model != "" -> model
      _anything_else -> nil
    end
  end

  def model_for(%Entitlement{}), do: nil

  @doc """
  Runs `prompt` on behalf of `scope` against `entitlement_id`, spending one credit.

  This is the whole authorization story in one function, in a fixed order, and
  the order is the design:

    1. **Authorize.** The entitlement is reached through
       `Cass.Entitlements.get_entitlement/2`, so a guest, a foreign id, an
       unknown id, a revoked grant, and an elapsed one are all refused the same
       way and cost nothing.
    2. **Check the rate limit.** A throttled caller is refused *before* a credit
       is spent, so being throttled never costs a buyer a credit.
    3. **Spend.** One conditional `UPDATE` moves the balance; if it matches no
       row the pool is empty and the run is refused.
    4. **Call the gateway.** Outside any transaction, so a slow HTTP call never
       holds a database lock or a row lock open.
    5. **Settle.** The run row records the outcome and, on gateway failure, the
       credit is given back — a buyer is not charged for CASS's outage.

  Returns `{:ok, %Completion{}}` or `{:error, changeset}` whose `:base` message
  is one of the shared refusals, so a caller cannot distinguish "not yours" from
  "not entitled to run this".
  """
  @spec complete(Scope.t(), pos_integer() | String.t(), String.t()) ::
          {:ok, Completion.t()} | {:error, Ecto.Changeset.t()}
  def complete(%Scope{} = scope, entitlement_id, prompt)
      when (is_integer(entitlement_id) or is_binary(entitlement_id)) and is_binary(prompt) do
    cond do
      not authorized?(scope) ->
        refuse()

      blank?(prompt) ->
        refuse()

      too_long?(prompt) ->
        refusal(@too_long)

      true ->
        run_prompt(scope, entitlement_id, prompt)
    end
  end

  def complete(_scope, _entitlement_id, _prompt), do: refuse()

  @doc """
  The buyer's remaining credits for `entitlement_id`, or `nil` when they hold no
  balance for it.

  Returns `nil` — not zero — for an entitlement that is not theirs, is unknown,
  is not active, or is not metered. A caller therefore cannot use this to learn
  whether an id exists, and the `nil`/balance distinction is the same one
  `Cass.Entitlements.get_entitlement/2` already draws.
  """
  @spec balance(Scope.t(), pos_integer() | String.t()) :: CreditBalance.t() | nil
  def balance(%Scope{} = scope, entitlement_id) do
    with %Entitlement{id: id} <- authorized_entitlement(scope, entitlement_id),
         %CreditBalance{} = balance <- fetch_balance(id) do
      balance
    else
      _not_held -> nil
    end
  end

  def balance(_scope, _entitlement_id), do: nil

  @doc "The name of the configured gateway, or `nil` when none is enabled."
  @spec gateway_name() :: Gateway.name() | nil
  def gateway_name do
    case Gateways.enabled() do
      [name | _rest] -> name
      [] -> nil
    end
  end

  @doc "Whether a run could reach a gateway at all right now."
  @spec available?() :: boolean()
  def available? do
    case gateway() do
      # `configured?/0` is optional, so an adapter that omits it is assumed
      # usable — but one that implements it gets the final say. A registered
      # gateway missing its API key is not an available gateway, and reporting it
      # as available would offer the buyer a button that only ever refuses.
      {:ok, module} -> not function_exported?(module, :configured?, 0) or module.configured?()
      :error -> false
    end
  end

  @doc """
  The buyer's most recent runs for `entitlement_id`, newest first.

  Scoped through the same authorization read as `balance/2`, so this cannot
  widen what a caller may see. Only the outcome and its reason are exposed —
  never a prompt or a completion.
  """
  @spec recent_runs(Scope.t(), pos_integer() | String.t(), pos_integer()) :: [Run.t()]
  def recent_runs(scope, entitlement_id, limit \\ 10)

  def recent_runs(%Scope{} = scope, entitlement_id, limit)
      when is_integer(limit) and limit > 0 do
    case authorized_entitlement(scope, entitlement_id) do
      %Entitlement{id: id} ->
        Repo.all(
          from r in Run,
            where: r.entitlement_id == ^id,
            order_by: [desc: r.id],
            limit: ^limit
        )

      nil ->
        []
    end
  end

  def recent_runs(_scope, _entitlement_id, _limit), do: []

  ## Internals

  defp run_prompt(scope, entitlement_id, prompt) do
    with %Entitlement{} = entitlement <- authorized_entitlement(scope, entitlement_id),
         %CreditBalance{} = held <- fetch_balance(entitlement.id) do
      charge_and_dispatch(entitlement, held, prompt)
    else
      # Not theirs, unknown, revoked, elapsed, or not metered — all the same
      # refusal, and deliberately *not* logged: there is no balance to attribute
      # an attempt to, and a run row must never be written for an entitlement
      # this scope could not see.
      nil ->
        refuse()
    end
  end

  defp charge_and_dispatch(%Entitlement{} = entitlement, %CreditBalance{} = balance, prompt) do
    cond do
      # Checked *before* spending, so a gateway that cannot possibly answer
      # costs the buyer nothing and never occupies a run-log slot as a paid
      # attempt. `dispatch/3` still refunds for failures that happen after this
      # point — a gateway can go away between the two checks.
      not available?() ->
        _log(balance, :refused, "gateway not configured", String.length(prompt))
        refusal(@refused)

      true ->
        case enforce_rate_limit(balance) do
          :ok ->
            spend_and_dispatch(entitlement, balance, prompt)

          {:error, :rate_limited} ->
            _log(balance, :refused, @throttled, String.length(prompt))
            refusal(@throttled)
        end
    end
  end

  defp spend_and_dispatch(%Entitlement{} = entitlement, %CreditBalance{} = balance, prompt) do
    case spend(balance) do
      {:ok, %CreditBalance{} = charged} ->
        dispatch(entitlement, charged, prompt)

      {:error, :no_credits} ->
        _log(balance, :refused, @no_credits, 0)
        refusal(@no_credits)
    end
  end

  # The gateway call itself, deliberately outside a transaction. `spend/1`
  # committed; nothing here holds a lock while the network is in flight.
  defp dispatch(%Entitlement{} = entitlement, %CreditBalance{} = balance, prompt) do
    model = model_for(entitlement)
    chars = String.length(prompt)

    case gateway() do
      {:ok, module} ->
        case module.complete(model, prompt) do
          {:ok, %Completion{} = completion} ->
            _log(balance, :succeeded, nil, chars, model)
            {:ok, completion}

          {:error, reason} ->
            # CASS's own failure, so the credit goes back: a buyer is never
            # charged for a gateway outage or a throttled gateway.
            refund(balance)
            _log(balance, :failed, to_string(reason), chars, model)
            refusal(@refused)
        end

      :error ->
        refund(balance)
        _log(balance, :refused, "no gateway configured", chars, model)
        refusal(@refused)
    end
  end

  defp spend(%CreditBalance{id: id}) do
    query =
      from b in CreditBalance,
        where: b.id == ^id and b.consumed < b.granted

    case Repo.update_all(query, inc: [consumed: 1]) do
      {1, _rows} -> {:ok, reload_balance(id)}
      {0, _rows} -> {:error, :no_credits}
    end
  end

  # Give back a credit for a run that failed downstream. Guarded on `consumed > 0`
  # so it can never push the pair below zero, and idempotent in the sense that a
  # balance already at zero is simply left alone.
  defp refund(%CreditBalance{id: id}) do
    query = from b in CreditBalance, where: b.id == ^id and b.consumed > 0
    Repo.update_all(query, inc: [consumed: -1])
    :ok
  end

  # By primary key, unlike `fetch_balance/1` above: `spend/1` deals in balance ids,
  # and reading back by `entitlement_id` would silently return some *other* row's
  # balance and hide the miss as a `%CreditBalance{}` match.
  defp reload_balance(id), do: Repo.get(CreditBalance, id)

  # A sliding window over the log the rate limiter already writes: count this
  # buyer's attempts against this balance since the cutoff. No in-memory state,
  # so the limit holds across nodes and restarts.
  defp enforce_rate_limit(%CreditBalance{id: id, user_id: user_id}) do
    {max_runs, window_seconds} = rate_limit()
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)

    attempts =
      Repo.one(
        from r in Run,
          where:
            r.credit_balance_id == ^id and r.user_id == ^user_id and
              r.inserted_at > ^cutoff,
          select: count(r.id)
      )

    if is_integer(max_runs) and attempts >= max_runs do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp rate_limit do
    configured = Application.get_env(:cass, __MODULE__, []) |> Keyword.get(:rate_limit, [])

    {Keyword.get(configured, :max_runs, Keyword.get(@default_rate_limit, :max_runs)),
     Keyword.get(configured, :window_seconds, Keyword.get(@default_rate_limit, :window_seconds))}
  end

  # Written on every outcome, including refusals, and never fatal: losing an audit
  # row must not turn a successful run into an error for the buyer.
  defp _log(%CreditBalance{} = balance, status, reason, chars, model \\ nil) do
    result =
      %Run{}
      |> Run.changeset(%{
        credit_balance_id: balance.id,
        entitlement_id: balance.entitlement_id,
        user_id: balance.user_id,
        status: status,
        model: model,
        prompt_chars: chars,
        refusal_reason: reason
      })
      |> Repo.insert()

    if match?({:ok, _}, result), do: track_run(balance, result, chars, model)

    result
  end

  # Analytics observer: never raises, never blocks a run. Counts one attempt per
  # audit row, including refused ones, which is what makes "how often do buyers
  # hit the rate limit / run out of credits?" answerable.
  defp track_run(%CreditBalance{} = balance, {:ok, run}, chars, model) do
    Cass.Analytics.track("ai_run", %{
      user_id: balance.user_id,
      subject_type: "ai_run",
      subject_id: run.id,
      metadata: %{
        "status" => run.status,
        "model" => model,
        "prompt_chars" => chars
      }
    })
  end

  defp fetch_balance(entitlement_id) do
    Repo.one(from b in CreditBalance, where: b.entitlement_id == ^entitlement_id)
  end

  # Ownership, revocation, and expiry are decided by Entitlements, not here —
  # this context adds no second definition of "may see it".
  defp authorized_entitlement(%Scope{} = scope, entitlement_id) do
    case Entitlements.get_entitlement(scope, entitlement_id) do
      %Entitlement{} = entitlement ->
        if Scope.authenticated?(scope) and Entitlement.active?(entitlement) do
          entitlement
        else
          nil
        end

      nil ->
        nil
    end
  end

  defp authorized?(%Scope{} = scope), do: Scope.authenticated?(scope)

  defp blank?(prompt), do: String.trim(prompt) == ""

  defp too_long?(prompt), do: String.length(prompt) > @max_prompt_chars

  defp gateway do
    case gateway_name() do
      nil -> :error
      name -> Gateways.resolve(name)
    end
  end

  # Every refusal is a two-tuple, matching `complete/3`'s contract and every other
  # context in this codebase. The changeset carries the message in `:base`, so a
  # caller can render it with the usual `Phoenix.Component.used_input?`/`error` path
  # without knowing which refusal it got.
  defp refusal(message) do
    {:error, %Ecto.Changeset{valid?: false, errors: [base: {message, []}]}}
  end

  defp refuse, do: refusal(@refused)
end
