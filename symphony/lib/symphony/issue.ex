defmodule Symphony.Issue do
  @moduledoc "Normalized issue record from the tracker."

  @type blocker :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          state: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t(),
          branch_name: String.t() | nil,
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [blocker()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    labels: [],
    blocked_by: [],
    created_at: nil,
    updated_at: nil
  ]
end
