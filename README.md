# roll-your-own-symphony

An Elixir/OTP implementation of [Symphony](https://github.com/openai/symphony) — a long-running daemon that polls an issue tracker, creates per-issue workspaces, and runs a coding agent session for each issue.

## Background

Symphony is an open specification (see [`SPEC.md`](SPEC.md)) published by OpenAI for building coding agent orchestration services. The idea: instead of manually running an agent against a ticket, Symphony watches your issue tracker continuously, spins up an isolated workspace per issue, runs an agent, and hands off the result (a PR, a label change, a comment) without you supervising it.

The [reference implementation](https://github.com/openai/symphony/tree/main/elixir) targets Codex and Linear. This is an independent port that trades those assumptions for broader flexibility.

## How this implementation differs

| | OpenAI reference | This implementation |
|---|---|---|
| **Language** | Elixir 1.19 / OTP 28 | Elixir 1.19 / OTP 28 |
| **Issue tracker** | Linear only | GitHub Issues, Linear, or local (for testing) |
| **Agent backend** | Codex (app-server protocol) | Ollama, Claude (Anthropic API), or Codex |
| **Dashboard** | Phoenix LiveView | Lightweight Bandit/Plug JSON API |
| **Workspace clone** | Git CLI via hook | Git CLI via `after_create` hook (HTTPS + token) |
| **State model** | Linear named states | GitHub: label-based states; Linear: named states |

The GitHub Issues tracker derives issue state from labels — any open issue with a label matching an `active_states` entry is a candidate for dispatch.

## Requirements

- Elixir 1.19.5 and Erlang/OTP 28 (managed via [asdf](https://asdf-vm.com/))
- A GitHub personal access token (for GitHub Issues tracker)
- [Ollama](https://ollama.com/) running locally, or an Anthropic API key (depending on agent choice)

## Installation

**1. Install the correct Elixir/Erlang versions**

```bash
cd roll-your-own-symphony
asdf install erlang 28.3
asdf install elixir 1.19.5-otp-28
```

**2. Install dependencies**

```bash
cd symphony
mix deps.get
```

**3. Build the escript**

```bash
mix escript.build
```

This produces a `symphony` binary in the `symphony/` directory.

**4. Create your `.env` file**

```bash
cp .env.example .env   # if you have one, or create it manually
```

```bash
# symphony/.env
GITHUB_TOKEN=your_token_here
```

**5. Create the start script**

Create `symphony/start.sh`:

```bash
#!/bin/zsh -l
cd "$(dirname "$0")"

set -a
. ./.env
set +a

mix escript.build --quiet 2>/dev/null
exec ./symphony "$@"
```

```bash
chmod +x symphony/start.sh
```

## Configuration

Symphony is configured entirely through a `WORKFLOW.md` file in your target repository. It contains YAML front matter (service config) and a Markdown body (the per-issue prompt template).

### GitHub Issues example

```yaml
---
tracker:
  kind: github
  repo: your-org/your-repo
  api_key: $GITHUB_TOKEN
  active_states:
    - ready          # issues with this label will be picked up
  terminal_states:
    - closed         # native GitHub closed state
    - done           # issues with this label are considered finished

polling:
  interval_ms: 30000

workspace:
  root: /tmp/symphony-workspaces
  hooks:
    after_create: |
      git clone https://$GITHUB_TOKEN@github.com/your-org/your-repo.git .
      git checkout -b issue/{{ issue.identifier | replace: "#", "" }}

agent:
  kind: ollama
  model: your-model-name
  max_turns: 20

server:
  port: 4000
---
You are a coding agent working on a GitHub issue.

## Issue {{ issue.identifier }}: {{ issue.title }}
{% if issue.description %}
{{ issue.description }}
{% endif %}

## Instructions

1. Read the relevant code and understand the context.
2. Make the necessary changes.
3. Run tests if a test suite exists.
4. Commit and push your branch.
5. Open a pull request using the `github_api` tool.
6. Add the `done` label to the issue when complete.
```

### Key config options

| Key | Default | Description |
|---|---|---|
| `tracker.kind` | — | `github`, `linear`, or `local` |
| `tracker.repo` | — | GitHub only: `owner/repo` |
| `tracker.api_key` | — | Token; use `$VAR` to read from environment |
| `tracker.active_states` | — | States/labels that trigger dispatch |
| `tracker.terminal_states` | — | States/labels that indicate finished work |
| `polling.interval_ms` | `30000` | How often to poll the tracker |
| `workspace.root` | — | Directory where per-issue workspaces are created |
| `workspace.hooks.after_create` | — | Shell command run after workspace is created |
| `agent.kind` | — | `ollama`, `claude`, or `codex` |
| `agent.model` | — | Model name |
| `agent.max_turns` | `20` | Maximum agent turns per issue |
| `agent.max_concurrent_agents` | `10` | Concurrency limit |
| `server.port` | — | Port for the status API (optional) |

### GitHub state model

GitHub Issues have no named workflow states. Symphony maps them via labels:

- `active_states: ["open"]` — any open issue is a candidate
- `active_states: ["ready"]` — only open issues with a `ready` label
- `terminal_states: ["closed"]` — GitHub's native closed state
- `terminal_states: ["done"]` — issues with a `done` label

### Environment variable indirection

Any config value can reference an environment variable using `$VAR` syntax:

```yaml
tracker:
  api_key: $GITHUB_TOKEN
```

## Running

```bash
./symphony/start.sh --workflow /path/to/your-repo/WORKFLOW.md --port 4000
```

If `--workflow` is omitted, Symphony looks for `WORKFLOW.md` in the current directory.

Symphony runs in the foreground and logs to stdout. It will:

1. Load and validate the `WORKFLOW.md`
2. Start polling the tracker on the configured interval
3. Dispatch an agent for each eligible issue
4. Keep running until you stop it (`Ctrl+C`)

The start script rebuilds the escript on each run, so any source changes are picked up automatically.

## Testing locally with the local tracker

The `local` tracker reads issues from a directory of YAML files — no external services needed. Use it to verify your prompt and workspace hooks before pointing Symphony at a real tracker.

**1. Configure your WORKFLOW.md with `kind: local`:**

```yaml
tracker:
  kind: local
  issues_dir: ../issues
  active_states:
    - Todo
  terminal_states:
    - Done
    - Cancelled
```

**2. Create test issues with `new_issue.sh`:**

```bash
# Non-interactive — title and description as arguments
./new_issue.sh "Fix the login bug" "Users cannot log in with uppercase emails."

# Single argument — prompts for description interactively
./new_issue.sh "Refactor the auth module"

# No arguments — fully interactive
./new_issue.sh
```

Issues are written to the `issues/` directory as YAML files and picked up on the next poll. The agent marks an issue done by editing its `state` field to `Done`.

## Status API

When `--port` is set (or `server.port` is configured), a simple status API is available:

```bash
curl http://localhost:4000/api/v1/state
```

Returns JSON with running agents, retry queue, token totals, and timestamps.
