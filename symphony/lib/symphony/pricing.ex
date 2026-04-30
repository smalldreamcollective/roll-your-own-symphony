defmodule Symphony.Pricing do
  @moduledoc """
  Bundled model pricing table for estimating monetary cost of agent runs.

  Prices are in USD per token. To update when providers change pricing,
  edit the @prices map below. Prices were last verified 2026-04-30.

  For models not in the table, cost estimation is unavailable and Symphony
  falls back to token-only budgeting with a warning logged once per session.

  See issue #20 for the future real-time pricing upgrade path.
  """

  require Logger

  # {input_usd_per_token, output_usd_per_token}
  @prices %{
    # Anthropic Claude 4.x
    "claude-opus-4-7"              => {15.0 / 1_000_000,  75.0 / 1_000_000},
    "claude-sonnet-4-6"            => { 3.0 / 1_000_000,  15.0 / 1_000_000},
    "claude-haiku-4-5-20251001"    => { 0.8 / 1_000_000,   4.0 / 1_000_000},
    # Anthropic Claude 3.x (legacy)
    "claude-3-5-sonnet-20241022"   => { 3.0 / 1_000_000,  15.0 / 1_000_000},
    "claude-3-5-haiku-20241022"    => { 0.8 / 1_000_000,   4.0 / 1_000_000},
    "claude-3-opus-20240229"       => {15.0 / 1_000_000,  75.0 / 1_000_000},
    # OpenAI
    "gpt-4o"                       => { 2.5 / 1_000_000,  10.0 / 1_000_000},
    "gpt-4o-mini"                  => { 0.15 / 1_000_000,  0.6 / 1_000_000},
    "gpt-4-turbo"                  => {10.0 / 1_000_000,  30.0 / 1_000_000},
    "o1"                           => {15.0 / 1_000_000,  60.0 / 1_000_000},
    "o1-mini"                      => { 3.0 / 1_000_000,  12.0 / 1_000_000},
    "o3-mini"                      => { 1.1 / 1_000_000,   4.4 / 1_000_000},
  }

  @doc """
  Estimate USD cost for a given number of input and output tokens.
  Returns {:ok, usd} or {:unavailable, reason} if the model is unknown.
  Logs a warning once (caller should deduplicate if calling in a tight loop).
  """
  def estimate_cost(model, input_tokens, output_tokens) when is_binary(model) do
    case Map.get(@prices, model) do
      nil ->
        Logger.warning("no pricing data for model=#{model} — monetary budget will not be enforced")
        {:unavailable, :unknown_model}

      {input_rate, output_rate} ->
        cost = input_tokens * input_rate + output_tokens * output_rate
        {:ok, Float.round(cost, 6)}
    end
  end

  @doc "Returns true if pricing is known for this model."
  def known?(model), do: Map.has_key?(@prices, model)

  @doc "Returns the full pricing table for introspection."
  def table, do: @prices
end
