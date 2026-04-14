defmodule Symphony.ConfigTest do
  use ExUnit.Case, async: true

  alias Symphony.Config

  describe "defaults" do
    test "poll_interval_ms defaults to 30000" do
      assert Config.poll_interval_ms(%{}) == 30_000
    end

    test "max_concurrent_agents defaults to 10" do
      assert Config.max_concurrent_agents(%{}) == 10
    end

    test "max_turns defaults to 20" do
      assert Config.max_turns(%{}) == 20
    end

    test "agent_model defaults to qwen3:8b" do
      assert Config.agent_model(%{}) == "qwen3:8b"
    end

    test "ollama_url defaults to localhost" do
      assert Config.ollama_url(%{}) == "http://localhost:11434"
    end

    test "active_states defaults to open" do
      assert Config.tracker_active_states(%{}) == ["open"]
    end

    test "terminal_states defaults include closed" do
      assert "closed" in Config.tracker_terminal_states(%{})
    end
  end

  describe "env-var resolution" do
    test "resolves $VAR in api_key" do
      System.put_env("TEST_LINEAR_KEY", "test-token-123")
      cfg = %{"tracker" => %{"api_key" => "$TEST_LINEAR_KEY"}}
      assert Config.tracker_api_key(cfg) == "test-token-123"
    after
      System.delete_env("TEST_LINEAR_KEY")
    end

    test "returns literal value when no $ prefix" do
      cfg = %{"tracker" => %{"api_key" => "literal-key"}}
      assert Config.tracker_api_key(cfg) == "literal-key"
    end

    test "returns nil when $VAR is unset" do
      System.delete_env("UNSET_VAR_SYMPHONY")
      cfg = %{"tracker" => %{"api_key" => "$UNSET_VAR_SYMPHONY"}}
      assert Config.tracker_api_key(cfg) == nil
    end
  end

  describe "integer coercion" do
    test "parses string integers" do
      cfg = %{"polling" => %{"interval_ms" => "5000"}}
      assert Config.poll_interval_ms(cfg) == 5_000
    end

    test "uses default for invalid string" do
      cfg = %{"polling" => %{"interval_ms" => "not-a-number"}}
      assert Config.poll_interval_ms(cfg) == 30_000
    end
  end

  describe "workspace_root" do
    test "expands ~ in path" do
      cfg = %{"workspace" => %{"root" => "~/symphony_ws"}}
      root = Config.workspace_root(cfg)
      assert String.starts_with?(root, System.get_env("HOME"))
    end

    test "resolves $VAR path" do
      System.put_env("SYMPHONY_WS_ROOT", "/tmp/test_ws")
      cfg = %{"workspace" => %{"root" => "$SYMPHONY_WS_ROOT"}}
      assert Config.workspace_root(cfg) == "/tmp/test_ws"
    after
      System.delete_env("SYMPHONY_WS_ROOT")
    end

    test "preserves bare relative names (no path separator)" do
      cfg = %{"workspace" => %{"root" => "my_workspaces"}}
      assert Config.workspace_root(cfg) == "my_workspaces"
    end
  end

  describe "validate_for_dispatch" do
    test "returns :ok with valid config" do
      System.put_env("MY_LINEAR_KEY", "token")

      workflow = {:ok, %{config: %{
        "tracker" => %{
          "kind" => "linear",
          "api_key" => "$MY_LINEAR_KEY",
          "project_slug" => "my-project"
        }
      }}}

      assert Config.validate_for_dispatch(workflow) == :ok
    after
      System.delete_env("MY_LINEAR_KEY")
    end

    test "errors on missing tracker kind" do
      workflow = {:ok, %{config: %{}}}
      assert Config.validate_for_dispatch(workflow) == {:error, :missing_tracker_kind}
    end

    test "errors on unsupported tracker kind" do
      workflow = {:ok, %{config: %{"tracker" => %{"kind" => "jira"}}}}
      assert Config.validate_for_dispatch(workflow) == {:error, {:unsupported_tracker_kind, "jira"}}
    end

    test "accepts github as a valid tracker kind" do
      workflow = {:ok, %{config: %{
        "tracker" => %{"kind" => "github", "api_key" => "tok", "repo" => "o/r"}
      }}}
      assert Config.validate_for_dispatch(workflow) == :ok
    end

    test "errors on github kind without repo" do
      workflow = {:ok, %{config: %{
        "tracker" => %{"kind" => "github", "api_key" => "tok"}
      }}}
      assert Config.validate_for_dispatch(workflow) == {:error, :missing_tracker_repo}
    end

    test "errors on missing api_key" do
      workflow = {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}}}
      assert Config.validate_for_dispatch(workflow) == {:error, :missing_tracker_api_key}
    end

    test "propagates workflow load errors" do
      assert Config.validate_for_dispatch({:error, :missing_workflow_file}) ==
               {:error, :missing_workflow_file}
    end

    test "errors on max_concurrent_agents_by_state ignoring invalid entries" do
      cfg = %{
        "agent" => %{
          "max_concurrent_agents_by_state" => %{
            "In Progress" => 3,
            "Todo" => "bad",
            "Review" => -1
          }
        }
      }

      result = Config.max_concurrent_agents_by_state(cfg)
      assert result == %{"in progress" => 3}
    end
  end
end
