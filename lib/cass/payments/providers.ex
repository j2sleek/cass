defmodule Cass.Payments.Providers do
  @moduledoc """
  The registry of payment providers configured for CASS.

  Providers live in application configuration, not in code switches, so a new
  provider is enabled by shipping its adapter and adding an entry to
  `config :cass, Cass.Payments`:

      config :cass, Cass.Payments,
        providers: [
          paystack: [
            module: Cass.Payments.Providers.Paystack,
            enabled: true
          ]
        ]

  The registry resolves a provider *atom* (the value stored in
  `payment.provider`) to its adapter module. An entry that exists but is
  disabled resolves as unknown, so a turned-off provider is indistinguishable
  from one that was never configured — callers must not learn about disabled
  providers.
  """

  alias Cass.Payments.Provider

  @doc "Returns the provider atoms that are configured and enabled."
  @spec enabled() :: [Provider.name()]
  def enabled do
    for {name, opts} <- configured(),
        Keyword.get(opts, :enabled, true) do
      name
    end
  end

  @doc """
  Resolves `name` (an atom or its string form) to its adapter module.

  Returns `{:ok, module}` only for a configured and enabled provider, and
  `{:error, :unknown_provider}` otherwise.
  """
  @spec resolve(Provider.name() | String.t()) :: {:ok, module()} | {:error, :unknown_provider}
  def resolve(name) when is_atom(name), do: resolve(Atom.to_string(name))

  def resolve(name) when is_binary(name) do
    case Enum.find(configured(), fn {entry, _opts} -> Atom.to_string(entry) == name end) do
      {_entry, opts} when is_list(opts) ->
        if Keyword.get(opts, :enabled, true) do
          case Keyword.get(opts, :module) do
            nil -> {:error, :unknown_provider}
            module -> {:ok, module}
          end
        else
          {:error, :unknown_provider}
        end

      _none ->
        {:error, :unknown_provider}
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
    Application.get_env(:cass, Cass.Payments, []) |> Keyword.get(:providers, [])
  end
end
