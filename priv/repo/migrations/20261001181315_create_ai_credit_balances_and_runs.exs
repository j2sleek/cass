defmodule Cass.Repo.Migrations.CreateAiCreditBalancesAndRuns do
  use Ecto.Migration

  # The `:ai` leg of fulfillment: what an AI purchase grants the buyer to spend
  # (`cass_ai_credit_balances`) and the audit trail of every attempt to spend it
  # (`cass_ai_runs`).
  #
  # `cass_ai_credit_balances` is 1:1 with the entitlement that granted it (the
  # unique index on `entitlement_id` is the idempotency key, the same pattern as
  # `cass_fulfillments.order_item_id` and `cass_entitlements.order_item_id`
  # before it). One AI purchase is one credit pool: quantity is a purchase
  # property, not something to multiply out into N rows, because a buyer's
  # balance is a single number and a single spend decision.
  #
  # The balance is *stored* as `granted` and `consumed` rather than a derived
  # `remaining` column. A derived column is a cache of `granted - consumed` that
  # a bug can desynchronize; a stored pair cannot, because `remaining` is
  # computed in exactly one place (`Cass.Ai`) and the pair is what the
  # conditional `UPDATE` below moves atomically. Spending is therefore an
  # atomic conditional update —
  #
  #     UPDATE ... SET consumed = consumed + 1 WHERE id = ? AND consumed < granted
  #
  # — never a read-then-write, so N concurrent runs can never oversell the pool.
  # The CHECK constraint is the database-level backstop for the same invariant,
  # and it is why `consumed < granted` is enforced twice on purpose: once as the
  # guard that makes the update atomic, once as the constraint that makes a bug
  # impossible to commit even if the guard is dropped.
  #
  # `cass_ai_runs` is one row per *attempt*, written whether the attempt
  # succeeded, failed at the gateway, or was refused by CASS before it left the
  # building. That is deliberate: docs/security.md requires CASS to rate-limit
  # and log every AI call, and a rate limiter that cannot see its own refusals is
  # blind to exactly the traffic it exists to catch. Refusals are recorded with
  # the reason in `refusal_reason` and never carry the prompt, so the log is an
  # abuse signal without becoming a store of what users typed.
  #
  # As everywhere else in the schema, every foreign key is `on_delete: :restrict`
  # and nothing here may be used to walk backwards from a credit balance to a
  # product row the catalog can rewrite.

  def up do
    create table(:cass_ai_credit_balances) do
      add :entitlement_id,
          references(:cass_entitlements, on_delete: :restrict, on_update: :update_all),
          null: false

      # The buyer the balance belongs to — always the entitlement's owner,
      # copied programmatically and never cast from input.
      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      # The pool the purchase bought, snapshotted at grant time from the ordered
      # variant's config (`Cass.Ai.granted_credits/1`). A later catalog edit
      # cannot rewrite what a buyer already paid for.
      add :granted, :integer, null: false, default: 0

      # How much of it has been spent. Never negative and never more than
      # `granted`; both are enforced by the CHECK constraint below.
      add :consumed, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cass_ai_credit_balances, [:entitlement_id])

    create constraint(:cass_ai_credit_balances, :cass_ai_credit_balances_granted_check,
             check: "granted >= 0"
           )

    create constraint(:cass_ai_credit_balances, :cass_ai_credit_balances_consumed_check,
             check: "consumed >= 0 and consumed <= granted"
           )

    create table(:cass_ai_runs) do
      add :credit_balance_id,
          references(:cass_ai_credit_balances, on_delete: :restrict, on_update: :update_all),
          null: false

      add :entitlement_id,
          references(:cass_entitlements, on_delete: :restrict, on_update: :update_all),
          null: false

      # The account that made the attempt. Denormalized from the balance so an
      # abuse query never has to join, and so a balance row can never be used to
      # attribute a run to somebody else.
      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      add :status, :string, null: false

      # The model the gateway was asked for. Server-chosen from the ordered
      # variant's config, never from the request body.
      add :model, :string

      # Deliberately NOT the prompt or the completion. `prompt_chars` is enough
      # to size an abuse signal and costs nothing in privacy; the text itself
      # would make this table a store of whatever users typed.
      add :prompt_chars, :integer

      add :refusal_reason, :string, size: 100

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_ai_runs, :cass_ai_runs_status_check,
             check: "status in ('succeeded', 'failed', 'refused')"
           )

    create constraint(:cass_ai_runs, :cass_ai_runs_prompt_chars_check,
             check: "prompt_chars is null or prompt_chars >= 0"
           )

    # The rate limiter's access pattern: "this buyer's attempts in the last
    # minute", newest first.
    create index(:cass_ai_runs, [:user_id, :inserted_at])
  end

  def down do
    drop table(:cass_ai_runs)
    drop table(:cass_ai_credit_balances)
  end
end
