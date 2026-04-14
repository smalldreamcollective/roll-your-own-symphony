defmodule Symphony.WorkflowLoaderTest do
  use ExUnit.Case, async: true

  alias Symphony.WorkflowLoader

  describe "parse/1" do
    test "parses YAML front matter and prompt body" do
      content = """
      ---
      tracker:
        kind: linear
        project_slug: my-project
      ---
      You are working on {{ issue.identifier }}.
      """

      {:ok, result} = WorkflowLoader.parse(content)
      assert get_in(result.config, ["tracker", "kind"]) == "linear"
      assert result.prompt_template == "You are working on {{ issue.identifier }}."
    end

    test "no front matter — treats entire content as prompt" do
      content = "Just do the work."
      {:ok, result} = WorkflowLoader.parse(content)
      assert result.config == %{}
      assert result.prompt_template == "Just do the work."
    end

    test "empty front matter is valid" do
      content = "---\n---\nSome prompt."
      {:ok, result} = WorkflowLoader.parse(content)
      assert result.config == %{}
      assert result.prompt_template == "Some prompt."
    end

    test "trims whitespace from prompt body" do
      content = "---\nfoo: bar\n---\n\n  Hello.\n\n"
      {:ok, result} = WorkflowLoader.parse(content)
      assert result.prompt_template == "Hello."
    end

    test "non-map YAML returns error" do
      content = "---\n- item1\n- item2\n---\nPrompt."
      assert {:error, :workflow_front_matter_not_a_map} = WorkflowLoader.parse(content)
    end

    test "invalid YAML returns parse error" do
      content = "---\nfoo: : bad\n---\nPrompt."
      assert {:error, {:workflow_parse_error, _}} = WorkflowLoader.parse(content)
    end
  end

  describe "load/1" do
    test "returns error for missing file" do
      assert WorkflowLoader.load("/nonexistent/path/WORKFLOW.md") ==
               {:error, :missing_workflow_file}
    end

    test "loads and parses a real file" do
      path = Path.join(System.tmp_dir!(), "test_workflow_#{System.unique_integer()}.md")

      File.write!(path, """
      ---
      tracker:
        kind: linear
      ---
      Test prompt.
      """)

      {:ok, result} = WorkflowLoader.load(path)
      File.rm(path)
      assert get_in(result.config, ["tracker", "kind"]) == "linear"
      assert result.prompt_template == "Test prompt."
    end
  end
end
