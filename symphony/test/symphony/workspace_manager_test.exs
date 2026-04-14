defmodule Symphony.WorkspaceManagerTest do
  use ExUnit.Case, async: true

  alias Symphony.WorkspaceManager

  describe "sanitize_key/1" do
    test "allows alphanumeric, dot, dash, underscore" do
      assert WorkspaceManager.sanitize_key("ABC-123") == "ABC-123"
      assert WorkspaceManager.sanitize_key("my.issue_1") == "my.issue_1"
    end

    test "replaces disallowed characters with underscore" do
      assert WorkspaceManager.sanitize_key("ABC/123") == "ABC_123"
      assert WorkspaceManager.sanitize_key("foo bar") == "foo_bar"
      assert WorkspaceManager.sanitize_key("a:b@c!") == "a_b_c_"
    end

    test "Linear identifier format passes through unchanged" do
      assert WorkspaceManager.sanitize_key("PROJ-42") == "PROJ-42"
    end
  end

  describe "create_for_issue/2" do
    setup do
      root = Path.join(System.tmp_dir!(), "symphony_test_#{System.unique_integer()}")
      cfg = %{"workspace" => %{"root" => root}}
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root, cfg: cfg}
    end

    test "creates workspace directory", %{cfg: cfg} do
      {:ok, workspace} = WorkspaceManager.create_for_issue("PROJ-1", cfg)
      assert File.dir?(workspace.path)
      assert workspace.created_now == true
      assert workspace.workspace_key == "PROJ-1"
    end

    test "reuses existing directory without running after_create again", %{cfg: cfg} do
      {:ok, workspace1} = WorkspaceManager.create_for_issue("PROJ-2", cfg)
      assert workspace1.created_now == true

      {:ok, workspace2} = WorkspaceManager.create_for_issue("PROJ-2", cfg)
      assert workspace2.created_now == false
      assert workspace2.path == workspace1.path
    end

    test "sanitizes identifier for directory name", %{cfg: cfg} do
      {:ok, workspace} = WorkspaceManager.create_for_issue("PROJ/99", cfg)
      assert String.ends_with?(workspace.path, "PROJ_99")
    end
  end

  describe "path_for/2" do
    test "returns expected path without creating directory" do
      root = "/tmp/test_ws"
      cfg = %{"workspace" => %{"root" => root}}
      path = WorkspaceManager.path_for("ABC-1", cfg)
      assert path == "/tmp/test_ws/ABC-1"
      # Directory should NOT be created
      refute File.exists?(path)
    end
  end
end
