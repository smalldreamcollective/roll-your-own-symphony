defmodule Symphony.Tracker.LocalTest do
  use ExUnit.Case, async: true

  alias Symphony.Tracker.Local

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony_local_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp cfg(dir, overrides \\ %{}) do
    Map.merge(
      %{
        "tracker" => %{
          "kind" => "local",
          "issues_dir" => dir,
          "active_states" => ["Todo", "In Progress"],
          "terminal_states" => ["Done", "Cancelled"]
        }
      },
      overrides
    )
  end

  defp write_issue(dir, filename, content) do
    File.write!(Path.join(dir, filename), content)
  end

  describe "fetch_candidate_issues/1" do
    test "returns issues in active states", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "1"
      identifier: "ISSUE-1"
      title: "Fix login bug"
      state: "Todo"
      """)

      write_issue(dir, "ISSUE-2.yaml", """
      id: "2"
      identifier: "ISSUE-2"
      title: "Add dark mode"
      state: "In Progress"
      """)

      write_issue(dir, "ISSUE-3.yaml", """
      id: "3"
      identifier: "ISSUE-3"
      title: "Old task"
      state: "Done"
      """)

      {:ok, issues} = Local.fetch_candidate_issues(cfg(dir))
      identifiers = Enum.map(issues, & &1.identifier)

      assert "ISSUE-1" in identifiers
      assert "ISSUE-2" in identifiers
      refute "ISSUE-3" in identifiers
    end

    test "returns empty list when issues_dir does not exist" do
      {:ok, issues} = Local.fetch_candidate_issues(cfg("/nonexistent/path"))
      assert issues == []
    end

    test "returns empty list when directory has no yaml files", %{dir: dir} do
      File.write!(Path.join(dir, "notes.txt"), "ignore me")
      {:ok, issues} = Local.fetch_candidate_issues(cfg(dir))
      assert issues == []
    end

    test "skips files missing required fields", %{dir: dir} do
      write_issue(dir, "bad.yaml", """
      id: "bad"
      identifier: "BAD-1"
      state: "Todo"
      """)

      write_issue(dir, "good.yaml", """
      id: "good"
      identifier: "GOOD-1"
      title: "A valid issue"
      state: "Todo"
      """)

      {:ok, issues} = Local.fetch_candidate_issues(cfg(dir))
      assert length(issues) == 1
      assert hd(issues).identifier == "GOOD-1"
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns issues matching the given ids", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "1"
      identifier: "ISSUE-1"
      title: "Task one"
      state: "In Progress"
      """)

      write_issue(dir, "ISSUE-2.yaml", """
      id: "2"
      identifier: "ISSUE-2"
      title: "Task two"
      state: "Todo"
      """)

      {:ok, issues} = Local.fetch_issue_states_by_ids(cfg(dir), ["1"])
      assert length(issues) == 1
      assert hd(issues).id == "1"
      assert hd(issues).state == "In Progress"
    end

    test "returns empty list when no ids match", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "1"
      identifier: "ISSUE-1"
      title: "Task one"
      state: "Todo"
      """)

      {:ok, issues} = Local.fetch_issue_states_by_ids(cfg(dir), ["999"])
      assert issues == []
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns only issues matching given states", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "1"
      identifier: "ISSUE-1"
      title: "Done task"
      state: "Done"
      """)

      write_issue(dir, "ISSUE-2.yaml", """
      id: "2"
      identifier: "ISSUE-2"
      title: "Active task"
      state: "Todo"
      """)

      {:ok, issues} = Local.fetch_issues_by_states(cfg(dir), ["Done"])
      assert length(issues) == 1
      assert hd(issues).identifier == "ISSUE-1"
    end
  end

  describe "normalization" do
    test "normalizes all fields correctly", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "42"
      identifier: "ISSUE-42"
      title: "Full issue"
      description: "A description"
      state: "Todo"
      priority: 2
      labels:
        - Backend
        - Urgent
      url: "http://example.com/issues/42"
      """)

      {:ok, [issue]} = Local.fetch_candidate_issues(cfg(dir))
      assert issue.id == "42"
      assert issue.identifier == "ISSUE-42"
      assert issue.title == "Full issue"
      assert issue.description == "A description"
      assert issue.state == "Todo"
      assert issue.priority == 2
      assert issue.labels == ["backend", "urgent"]
      assert issue.url == "http://example.com/issues/42"
    end

    test "uses filename stem as id when id field is absent", %{dir: dir} do
      write_issue(dir, "MY-ISSUE.yaml", """
      identifier: "MY-ISSUE"
      title: "No id field"
      state: "Todo"
      """)

      {:ok, [issue]} = Local.fetch_candidate_issues(cfg(dir))
      assert issue.id == "MY-ISSUE"
    end

    test "state comparison is case-insensitive", %{dir: dir} do
      write_issue(dir, "ISSUE-1.yaml", """
      id: "1"
      identifier: "ISSUE-1"
      title: "Mixed case"
      state: "in progress"
      """)

      cfg_map = cfg(dir, %{"tracker" => %{
        "kind" => "local",
        "issues_dir" => dir,
        "active_states" => ["In Progress"],
        "terminal_states" => ["Done"]
      }})

      {:ok, issues} = Local.fetch_candidate_issues(cfg_map)
      assert length(issues) == 1
    end
  end

  describe "validate_for_dispatch" do
    test "local tracker passes validation without api_key" do
      workflow = {:ok, %{config: %{
        "tracker" => %{"kind" => "local", "issues_dir" => "./issues"}
      }}}
      assert Symphony.Config.validate_for_dispatch(workflow) == :ok
    end
  end
end
