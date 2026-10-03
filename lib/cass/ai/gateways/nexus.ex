defmodule Cass.Ai.Gateways.Nexus do
  @moduledoc """
  The Nexus AI Gateway adapter.

  Implements `Cass.Ai.Gateway` against the Nexus gateway's OpenAI-compatible
  `POST /v1/chat/completions`, using the project's `Req` HTTP client. The adapter
  is deliberately dumb: it receives an already-authorized, already-quota-checked
  `model` and `prompt`, makes one HTTP request, and returns the normalized
  `Cass.Ai.Completion` (or an atom reason). It never touches the database and
  never re-checks a credit — those decisions live in `Cass.Ai`.

  ## Configuration

  Defined under `config :cass, :nexus_ai`:

    * `:api_key` — the gateway API key (from `NEXUS_AI_API_KEY` in production,
      `runtime.exs`; dummy values in dev/test).
    * `:base_url` — defaults to `http://localhost:8000`.
    * `:model` — the model to request when the purchased variant does not pin
      one. The gateway routes an unspecified model itself.
    * `:req_options` — extra `Req` options, used by the test suite to route
      requests through `Req.Test` (`plug: {Req.Test, :nexus_ai}`).

  ## Credentials never leave the server

  The key is read from config and sent in a header; it is never logged, never
  included in a `Cass.Ai.Completion`, never surfaced in `Access`, and never
  written to the `cass_ai_runs` log. The per-provider model credentials live on
  the gateway behind this key — CASS never holds them, which is the whole reason
  the boundary exists.

  ## Error mapping

  The gateway's HTTP status is collapsed into the closed `Cass.Ai.Gateway`
  reason vocabulary so no provider string escapes the adapter:

      401 / 403 → :unauthorized     (CASS's key is wrong or lacks CHAT)
      429       → :rate_limited     (the gateway is shedding load)
      404       → :invalid_request  (the requested model is not routable)
      400       → :invalid_request
      5xx, timeout, transport → :unavailable or :error

  `:invalid_request` is the one case that names *our* fault rather than the
  gateway's, because it is the only one CASS can fix by choosing a different
  model.
  """
  @behaviour Cass.Ai.Gateway

  alias Cass.Ai.Completion

  require Logger

  @default_base_url "http://localhost:8000"
  @default_model "default"

  @impl true
  def name, do: :nexus

  @doc """
  A key is the only thing that makes this adapter usable.

  Fails closed: with `NEXUS_AI_API_KEY` unset in production, `runtime.exs` sets
  the value to `nil` rather than omitting it, so "absent" and "blank" are both
  answered `false` here — and `Cass.Ai.available?/0` disables the buyer's run
  button instead of letting every submission round-trip to a 401 and a refund.
  """
  @impl true
  def configured? do
    case api_key() do
      key when is_binary(key) -> String.trim(key) != ""
      _not_a_key -> false
    end
  end

  @impl true
  def complete(model, prompt, opts \\ [])

  def complete(model, prompt, opts)
      when is_binary(prompt) and prompt != "" and
             (is_binary(model) or is_nil(model)) and is_list(opts) do
    if String.trim(prompt) == "" do
      {:error, :invalid_request}
    else
      post_chat(model, prompt)
    end
  end

  def complete(_model, _prompt, _opts), do: {:error, :invalid_request}

  defp post_chat(model, prompt) do
    body = %{
      model: model || configured_model(),
      messages: [%{role: "user", content: prompt}],
      stream: false
    }

    case post("/v1/chat/completions", body) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        parse_completion(response_body, model)

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :unauthorized}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} when status in [400, 404, 422] ->
        {:error, :invalid_request}

      {:ok, %{status: status}} when status >= 500 ->
        # The gateway's problem, not the buyer's: surfaced as :unavailable so the
        # credit is refunded and the UI can say "try again" rather than
        # "you did something wrong".
        Logger.warning("nexus gateway responded #{status}")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.warning("nexus gateway request failed: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  # The gateway's OpenAI-shaped response. We read only the fields CASS needs and
  # treat anything unexpected as :unavailable rather than guessing: a malformed
  # body must never become a completion shown to a buyer as if it were a real
  # answer.
  #
  # Clause order matters here — the `usage`-bearing clause must come first, or a
  # response that *has* usage would fall through to the simpler one and lose the
  # counters that make a run auditable.
  defp parse_completion(%{"choices" => choices, "usage" => usage}, model)
       when is_list(choices) do
    case extract_usage(usage) do
      {prompt_tokens, completion_tokens} ->
        case first_content(choices) do
          content when is_binary(content) and content != "" ->
            {:ok,
             %Completion{
               content: content,
               model: model,
               prompt_tokens: prompt_tokens,
               completion_tokens: completion_tokens
             }}

          _empty ->
            {:error, :unavailable}
        end

      :none ->
        parse_completion(%{"choices" => choices}, model)
    end
  end

  defp parse_completion(%{"choices" => choices}, model) when is_list(choices) do
    case first_content(choices) do
      content when is_binary(content) and content != "" ->
        {:ok, %Completion{content: content, model: model}}

      _empty ->
        {:error, :unavailable}
    end
  end

  defp parse_completion(_body, _model), do: {:error, :unavailable}

  defp first_content([%{"message" => %{"content" => content}} | _rest]) when is_binary(content),
    do: content

  defp first_content(_choices), do: nil

  defp extract_usage(%{"prompt_tokens" => p, "completion_tokens" => c})
       when is_integer(p) and is_integer(c),
       do: {p, c}

  defp extract_usage(_usage), do: :none

  defp post(path, body) do
    Req.post(req_options(),
      url: base_url() <> path,
      json: body,
      headers: req_headers(),
      receive_timeout: 30_000
    )
  end

  defp req_headers do
    [{"content-type", "application/json"}, {"authorization", "Bearer " <> api_key()}]
  end

  # `nil` is treated as absent rather than concatenated, so a missing key in
  # production produces a `:unauthorized` refusal instead of a `FunctionClauseError`
  # in the middle of string interpolation.
  defp api_key do
    case Keyword.get(config(), :api_key) do
      key when is_binary(key) -> key
      _missing -> ""
    end
  end

  defp base_url do
    config() |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")
  end

  defp configured_model do
    Keyword.get(config(), :model, @default_model)
  end

  defp req_options, do: Keyword.get(config(), :req_options, [])

  defp config, do: Application.get_env(:cass, :nexus_ai, [])
end
