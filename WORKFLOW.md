---
tracker:
  kind: github
  repo: smalldreamcollective/roll-your-own-symphony
  api_key: $GITHUB_TOKEN
  active_states:
    - ready
  terminal_states:
    - closed
    - done

polling:
  interval_ms: 30000

workspace:
  root: /tmp/symphony-workspaces/roll-your-own
  hooks:
    after_create: |
      git clone https://$GITHUB_TOKEN@github.com/smalldreamcollective/roll-your-own-symphony.git .
    before_run: |
      git fetch origin
      git pull --rebase origin main || true

agent:
  kind: claude
  model: claude-sonnet-4-6
  max_turns: 30
  max_concurrent_agents: 2

server:
  port: 4000
---
You are a coding agent working on the `roll-your-own-symphony` Elixir project.

This is an Elixir/OTP implementation of Symphony — a long-running daemon that polls an issue
tracker, creates per-issue workspaces, and runs a coding agent session for each issue.

## Issue {{ issue.identifier }}: {{ issue.title }}
{% if issue.description %}
{{ issue.description }}
{% endif %}

**State:** {{ issue.state }}
{% if issue.labels %}
**Labels:** {{ issue.labels | join: ", " }}
{% endif %}
{% if attempt %}
**Note:** This is retry attempt {{ attempt }}. Review any previous work before continuing.
{% endif %}

## Project context

- Implementation lives in `symphony/` — an Elixir/OTP Mix project
- Run tests: `cd symphony && mix test`
- Run a single test file: `mix test test/symphony/config_test.exs`
- Key modules: `Symphony.Orchestrator`, `Symphony.Worker`, `Symphony.AgentRunner`, `Symphony.WorkspaceManager`, `Symphony.Prompt`, `Symphony.Config`, `Symphony.Tracker.GitHub`, `Symphony.Tracker.Linear`
- SPEC.md is the source of truth for intended behaviour

## Instructions

1. Read SPEC.md and the relevant source files to understand the context.
2. Implement the change or fix described in the issue.
3. Run `cd symphony && mix test` — all tests must pass.
4. Commit your changes on a branch named `feat/{{ issue.identifier | remove: "#" }}-<short-slug>` or `fix/...`.
5. Push the branch and use `github_api` to open a pull request targeting `main`.
6. Add the `done` label to the issue using `github_api`.

Work methodically. Do not ask for clarification — use your best judgement.
