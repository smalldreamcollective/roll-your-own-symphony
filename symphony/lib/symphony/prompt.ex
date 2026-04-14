defmodule Symphony.Prompt do
  @moduledoc """
  Renders the per-issue prompt from the workflow template.

  Uses Solid (Liquid-compatible) with strict unknown-variable and
  unknown-filter checking per spec §5.4.
  """

  @default_prompt "You are working on an issue from Linear."

  @doc """
  Render the prompt for a given issue and attempt number.

  Returns {:ok, prompt_string} | {:error, reason}.
  """
  def render(prompt_template, issue, attempt) do
    template_str =
      if is_nil(prompt_template) or String.trim(prompt_template) == "" do
        @default_prompt
      else
        prompt_template
      end

    assigns = build_assigns(issue, attempt)

    case Solid.parse(template_str) do
      {:error, reason} ->
        {:error, {:template_parse_error, reason}}

      {:ok, template} ->
        case Solid.render(template, assigns, strict_variables: true, strict_filters: true) do
          {:ok, result, _errors} ->
            {:ok, IO.iodata_to_binary(result)}

          {:error, errors, _partial} ->
            {:error, {:template_render_error, errors}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_assigns(issue, attempt) do
    issue_map = %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "branch_name" => issue.branch_name,
      "url" => issue.url,
      "labels" => issue.labels,
      "blocked_by" =>
        Enum.map(issue.blocked_by, fn b ->
          %{"id" => b.id, "identifier" => b.identifier, "state" => b.state}
        end),
      "created_at" => format_dt(issue.created_at),
      "updated_at" => format_dt(issue.updated_at)
    }

    base = %{"issue" => issue_map}

    if is_nil(attempt) do
      base
    else
      Map.put(base, "attempt", attempt)
    end
  end

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
