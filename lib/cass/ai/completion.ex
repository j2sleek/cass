defmodule Cass.Ai.Completion do
  @moduledoc """
  One gateway answer: the completed text, the model that produced it, and how
  much was spent at the provider.

  Both sides of the boundary share this struct — `Cass.Ai.Gateway.complete/3`
  returns it, `Cass.Ai` renders it — so the adapter's job is to *translate*
  whatever the gateway said into one shape, and the web layer never sees a
  provider-specific body.

  ## Why the usage counters are here but the text is logged

  `prompt_tokens`/`completion_tokens` are operational facts: they are what makes
  a cost or abuse investigation possible, they come from the gateway rather than
  from the user, and they are the only honest answer to "how much did that run
  actually cost us". They belong on the run log.

  They are also **informational**. Nothing in CASS converts them into a price or
  a charge — a buyer's credit is consumed per run, not per token, because a
  token-priced market would need a rate table that is not part of this milestone.
  Carrying the counters now is what lets that be added later without a schema
  change or a backfill.
  """
  defstruct [:content, :model, :prompt_tokens, :completion_tokens]

  @type t :: %__MODULE__{
          content: String.t(),
          model: String.t() | nil,
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil
        }
end
