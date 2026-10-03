defmodule Cass.Ai.Run do
  @moduledoc """
  One attempt to spend an AI credit — the audit trail `docs/security.md` asks for.

  A row is written whether the attempt **succeeded**, **failed** at the gateway,
  or was **refused** by CASS before any request left the process. That is the
  point of the table: a rate limiter that cannot see its own refusals is blind to
  exactly the traffic it exists to catch, so `:refused` is a first-class outcome
  rather than an absence of a row.

  ## What is deliberately not here

  Neither the prompt nor the completion. `prompt_chars` records how much text
  was submitted, which is enough to size an abuse signal and costs nothing in
  privacy; storing the strings would quietly turn an operational log into a
  store of whatever users typed, kept indefinitely, on rows that a support
  investigation can read. Content belongs to the user and to the gateway.

  The same reasoning applies to `model`: it is recorded because knowing *which*
  model absorbed a request is the first question of a cost investigation, and it
  is server-chosen from the ordered variant's snapshotted config, so it is not
  attacker-controlled free text.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Ai.CreditBalance
  alias Cass.Entitlements.Entitlement

  @statuses [:succeeded, :failed, :refused]

  @doc "Returns the closed vocabulary of run outcomes."
  def statuses, do: @statuses

  schema "cass_ai_runs" do
    field :status, Ecto.Enum, values: @statuses
    field :model, :string
    field :prompt_chars, :integer
    field :refusal_reason, :string

    belongs_to :credit_balance, CreditBalance
    belongs_to :entitlement, Entitlement
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer(),
          credit_balance_id: pos_integer(),
          entitlement_id: pos_integer(),
          user_id: pos_integer(),
          status: atom(),
          model: String.t() | nil,
          prompt_chars: non_neg_integer() | nil,
          refusal_reason: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :credit_balance_id,
      :entitlement_id,
      :user_id,
      :status,
      :model,
      :prompt_chars,
      :refusal_reason
    ])
    |> validate_required([:credit_balance_id, :entitlement_id, :user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:prompt_chars, greater_than_or_equal_to: 0)
    # Truncated rather than rejected: a long reason must still be loggable, and
    # the column is what an operator reads.
    |> update_change(:refusal_reason, &truncate_reason/1)
    |> foreign_key_constraint(:credit_balance_id)
    |> foreign_key_constraint(:entitlement_id)
    |> foreign_key_constraint(:user_id)
  end

  defp truncate_reason(nil), do: nil
  defp truncate_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 100)
end
