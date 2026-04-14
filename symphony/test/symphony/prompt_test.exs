defmodule Symphony.PromptTest do
  use ExUnit.Case, async: true

  alias Symphony.{Prompt, Issue}

  defp issue(overrides \\ []) do
    struct(
      Issue,
      Keyword.merge(
        [
          id: "issue-1",
          identifier: "PROJ-1",
          title: "Fix the bug",
          description: "Something is broken",
          priority: 1,
          state: "In Progress",
          labels: ["backend", "urgent"],
          blocked_by: [],
          branch_name: nil,
          url: "https://linear.app/issue/PROJ-1"
        ],
        overrides
      )
    )
  end

  describe "render/3" do
    test "renders issue fields into template" do
      template = "Working on {{ issue.identifier }}: {{ issue.title }}"
      {:ok, result} = Prompt.render(template, issue(), nil)
      assert result == "Working on PROJ-1: Fix the bug"
    end

    test "renders attempt when provided" do
      template = "Attempt: {{ attempt }}"
      {:ok, result} = Prompt.render(template, issue(), 2)
      assert result == "Attempt: 2"
    end

    test "attempt is absent from context when nil" do
      # strict_variables means accessing attempt when nil should error
      template = "Attempt: {{ attempt }}"
      # Without attempt in context, Solid strict mode returns error or empty
      result = Prompt.render(template, issue(), nil)
      assert match?({:error, _}, result)
    end

    test "uses default prompt when template is empty" do
      {:ok, result} = Prompt.render("", issue(), nil)
      assert result == "You are working on an issue from Linear."
    end

    test "uses default prompt when template is nil" do
      {:ok, result} = Prompt.render(nil, issue(), nil)
      assert result == "You are working on an issue from Linear."
    end

    test "renders labels array" do
      template = "Labels: {% for label in issue.labels %}{{ label }} {% endfor %}"
      {:ok, result} = Prompt.render(template, issue(), nil)
      assert result == "Labels: backend urgent "
    end

    test "renders blocked_by array" do
      blocker = %{id: "b1", identifier: "PROJ-0", state: "In Progress"}
      i = issue(blocked_by: [blocker])
      template = "Blockers: {% for b in issue.blocked_by %}{{ b.identifier }}{% endfor %}"
      {:ok, result} = Prompt.render(template, i, nil)
      assert result == "Blockers: PROJ-0"
    end

    test "returns error on unknown variable in strict mode" do
      template = "{{ unknown_var }}"
      assert {:error, _} = Prompt.render(template, issue(), nil)
    end
  end
end
