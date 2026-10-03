defmodule Cass.Ai.Gateways do
  @moduledoc """
  The registry of AI gateways configured for CASS.

  Gateways live in application configuration, not in a code switch, so a new one
  is enabled by shipping its adapter and adding an entry to `config :cass, Cass.Ai`:

      config :cass, Cass.Ai,
        gateways: [
          nexus: [module: Cass.Ai.Gateways.Nexus, enabled: true]
        ]

  The registry resolves a gateway *atom* to its adapter module. An entry that
  exists but is disabled resolves as unknown, so a turned-off gateway is
  indistinguishable from one that was never configured — callers must not be
  able to learn which gateways exist but are off.

  This mirrors `Cass.Payments.Providers` exactly, including the reasoning for
  why the indirection exists at all: with one adapter, a registry of one looks
  like speculative scaffolding, but the AI boundary has a second obligation the
  payment one does not — the *provider key lives only on the gateway*, so the
  choice of which gateway to call is a security decision, not a cosmetic one, and
  it belongs in configuration where it can be changed without a deploy of code.
  """

  @doc "Returns the gateway atoms that are configured and enabled."
  @spec enabled() :: [Cass.Ai.Gateway.name()]
  def enabled do
    for {name, opts} <- configured(),
        Keyword.get(opts, :enabled, true) do
      name
    end
  end

  @doc """
  Resolves `name` to its adapter module.

  Returns `{:ok, module}` only for a configured and enabled gateway, and
  `{:error, :unknown_gateway}` otherwise.
  """
  @spec resolve(Cass.Ai.Gateway.name() | String.t()) ::
          {:ok, module()} | {:error, :unknown_gateway}
  def resolve(name) when is_atom(name), do: resolve(Atom.to_string(name))

  def resolve(name) when is_binary(name) do
    case Enum.find(configured(), fn {entry, _opts} -> Atom.to_string(entry) == name end) do
      {_entry, opts} when is_list(opts) ->
        if Keyword.get(opts, :enabled, true) do
          case Keyword.get(opts, :module) do
            nil -> {:error, :unknown_gateway}
            module -> {:ok, module}
          end
        else
          {:error, :unknown_gateway}
        end

      _none ->
        {:error, :unknown_gateway}
    end
  end

  @doc "Returns the options configured for `name`, or `:error` when not configured."
  @spec options(atom()) :: keyword() | :error
  def options(name) when is_atom(name) do
    case Keyword.get(configured(), name) do
      nil -> :error
      opts -> opts
    end
  end

  defp configured do
    Application.get_env(:cass, Cass.Ai, []) |> Keyword.get(:gateways, [])
  end
end
