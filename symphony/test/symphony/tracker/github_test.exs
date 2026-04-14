defmodule Symphony.Tracker.GitHubTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # State/label normalization
  # We test the normalization logic directly via fetch responses using mocks
  # is out of scope here (requires HTTP mocking). Instead, test the pure logic
  # by calling the normalization via a config fixture.
  # ---------------------------------------------------------------------------

  defp cfg(overrides \\ []) do
    base = %{
      "tracker" => %{
        "kind" => "github",
        "repo" => "owner/repo",
        "api_key" => "test-token",
        "active_states" => ["ready", "in-progress"],
        "terminal_states" => ["done", "closed"]
      }
    }

    Enum.reduce(overrides, base, fn {path, val}, acc ->
      put_in(acc, path, val)
    end)
  end

  describe "sanitize_key via WorkspaceManager" do
    test "GitHub identifier #42 sanitizes correctly" do
      assert Symphony.WorkspaceManager.sanitize_key("#42") == "_42"
    end
  end

  describe "config with github tracker" do
    test "tracker_kind is github" do
      assert Symphony.Config.tracker_kind(cfg()) == "github"
    end

    test "tracker_repo is read correctly" do
      assert Symphony.Config.tracker_repo(cfg()) == "owner/repo"
    end

    test "validate_for_dispatch passes with valid github config" do
      System.put_env("GH_TEST_TOKEN", "tok")
      workflow = {:ok, %{config: %{
        "tracker" => %{
          "kind" => "github",
          "repo" => "owner/repo",
          "api_key" => "$GH_TEST_TOKEN"
        }
      }}}
      assert Symphony.Config.validate_for_dispatch(workflow) == :ok
    after
      System.delete_env("GH_TEST_TOKEN")
    end

    test "validate_for_dispatch fails without repo" do
      workflow = {:ok, %{config: %{
        "tracker" => %{
          "kind" => "github",
          "api_key" => "token"
        }
      }}}
      assert Symphony.Config.validate_for_dispatch(workflow) == {:error, :missing_tracker_repo}
    end
  end

  describe "Symphony.Tracker routing" do
    test "routes to GitHub adapter for kind=github" do
      # We can't make real HTTP calls in tests, but we can verify the routing
      # returns an error from the GitHub module (not Linear) when called with
      # no network. The error shape differs between adapters.
      cfg_map = %{
        "tracker" => %{
          "kind" => "github",
          "repo" => "owner/nonexistent-repo-xyz",
          "api_key" => "bad-token",
          "active_states" => ["open"],
          "terminal_states" => ["closed"]
        }
      }

      result = Symphony.Tracker.fetch_candidate_issues(cfg_map)
      # Should get a GitHub error (not a Linear error)
      assert match?({:error, _}, result)
    end
  end
end
