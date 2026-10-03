defmodule Cass.Ai.CreditBalance do
  @moduledoc """
  What an AI purchase grants its buyer to spend: one credit pool, 1:1 with the
  entitlement that granted it.

  The row exists only for `:ai` entitlements. A digital or manual purchase has
  no pool because it grants no metered capability — the *absence* of a row is
  what "this purchase is not metered" means, rather than a zero-valued row that
  two different code paths could disagree about.

  ## `granted` / `consumed`, never `remaining`

  The balance is stored as the pair the purchase defined (`granted`) and the
  running total it has spent (`consumed`). `remaining` is deliberately **not** a
  column: it is `granted - consumed`, computed by `Cass.Ai` in one place. A
  stored `remaining` would be a second source of truth that a bug could
  desynchronize from the pair, and it would still need the pair underneath to
  make spending atomic.

  ## Spending is atomic and unconditional

  A run does not read this row, decide, and write back. It issues one
  conditional `UPDATE`:

      UPDATE cass_ai_credit_balances
         SET consumed = consumed + 1
       WHERE id = $1 AND consumed < granted
      RETURNING *

  Two buyers' runs racing for the last credit cannot both win — the second
  `UPDATE` matches no row, which is how `Cass.Ai` distinguishes "spent" from
  "empty". The `consumed <= granted` CHECK constraint is the database-level
  backstop for the same invariant.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Ai.Run
  alias Cass.Entitlements.Entitlement

  schema "cass_ai_credit_balances" do
    field :granted, :integer, default: 0
    field :consumed, :integer, default: 0

    belongs_to :entitlement, Entitlement
    belongs_to :user, User
    has_many :runs, Run

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer(),
          entitlement_id: pos_integer(),
          user_id: pos_integer(),
          granted: non_neg_integer(),
          consumed: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  The credits still available to spend: `granted - consumed`.

  ## Examples

      iex> Cass.Ai.CreditBalance.remaining(%Cass.Ai.CreditBalance{granted: 5, consumed: 2})
      3

      iex> Cass.Ai.CreditBalance.remaining(%Cass.Ai.CreditBalance{granted: 5, consumed: 5})
      0

  """
  def remaining(%__MODULE__{granted: granted, consumed: consumed})
      when is_integer(granted) and is_integer(consumed) do
    granted - consumed
  end

  def remaining(%__MODULE__{}), do: 0

  @doc """
  Changeset for issuing a pool.

  `granted` is only ever set from the *ordered variant's* snapshotted config by
  `Cass.Ai.issue_credits/1`, never cast from a request body: it is the thing the
  buyer paid for, so a client must not be able to name it. The non-negative
  constraint here mirrors the database CHECK constraint, so an impossible value
  fails in the changeset rather than at the database.
  """
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:entitlement_id, :user_id, :granted])
    |> validate_required([:entitlement_id, :user_id, :granted])
    |> validate_number(:granted, greater_than_or_equal_to: 0)
    |> unique_constraint(:entitlement_id, name: :cass_ai_credit_balances_entitlement_id_index)
  end
end
