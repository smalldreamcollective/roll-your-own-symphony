# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Workflow

Every change follows the SDC issue-first workflow:

1. **Create an issue** — use `gh issue create` or `./github_issue.sh`
2. **Start work** — `./start-work.sh <issue-number>` — creates a branch and draft PR
3. **Make changes** — on the branch; run `cd symphony && mix test` before committing
4. **Review** — run `/review-pr <number>` before merging
5. **Merge** — after CI passes and review is clean

Branch naming: `feat/<n>-<slug>`, `fix/<n>-<slug>`, `docs/<n>-<slug>`, `chore/<n>-<slug>`

Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`

Never commit directly to `main`.

## Implementation

The implementation lives in `symphony/` — an Elixir/OTP application.

### Commands

```bash
cd symphony

mix deps.get          # install dependencies
mix compile           # compile
mix test              # run all tests
mix test test/symphony/config_test.exs   # run a single test file
mix run               # start (requires WORKFLOW.md in cwd)
mix run -- --workflow /path/to/WORKFLOW.md --port 4000
```

The app starts but does not dispatch until a valid `WORKFLOW.md` is present — missing/invalid workflow is logged and the tick loop retries each poll interval.

### OTP Process Tree

```
Symphony.Supervisor (one_for_one)
├── Symphony.WorkflowLoader  (GenServer) — parses WORKFLOW.md, watches file, notifies Orchestrator on change
├── Symphony.Orchestrator    (GenServer) — owns all scheduling state; spawns worker Tasks
└── Bandit HTTP server       (optional, started when --port or server.port is set)
```

Workers are plain `spawn`-ed processes monitored with `Process.monitor/1`. Each worker runs `Symphony.Worker.run/4`, which calls `Symphony.AgentRunner.run/5`, which opens an Elixir `Port` to the Codex subprocess.

### Module Responsibilities

| Module | Role |
|---|---|
| `Symphony.Config` | Typed getters over raw workflow config map. All defaults and `$VAR` resolution live here. |
| `Symphony.WorkflowLoader` | GenServer: loads/parses `WORKFLOW.md`, file-watches via `FileSystem`, holds `{:ok, workflow} \| {:error, reason}`. |
| `Symphony.Tracker.Linear` | Stateless HTTP functions against Linear GraphQL. Three operations: `fetch_candidate_issues`, `fetch_issues_by_states`, `fetch_issue_states_by_ids`. |
| `Symphony.WorkspaceManager` | Pure filesystem functions: create, reuse, remove workspaces; run lifecycle hooks via `Port`. |
| `Symphony.Prompt` | Renders the Liquid template from `WORKFLOW.md` using `Solid` with strict mode. |
| `Symphony.Worker` | Task body: workspace → before_run hook → AgentRunner → after_run hook. |
| `Symphony.AgentRunner` | HTTP agent loop against Ollama (`/api/chat`). Sends tool results back to model until no more tool calls. Tools: `bash` (runs in workspace), `linear_graphql`. High-trust: bash auto-executed, errors returned as tool content so model can retry. |
| `Symphony.Orchestrator` | GenServer owning all state: running map, claimed set, retry map, token totals. Handles `:tick`, `:DOWN`, `{:retry_timer, id}`, `{:codex_event, id, event}`, `{:workflow_reloaded, result}`. |
| `Symphony.Server.Router` | Optional Plug router: `GET /`, `GET /api/v1/state`, `GET /api/v1/:id`, `POST /api/v1/refresh`. |

## What This Is

This is a from-scratch implementation of **Symphony** — a long-running daemon that polls a Linear issue tracker, creates per-issue workspaces, and runs a Codex coding-agent session for each issue. The sole source of truth for what to build is `SPEC.md`.

There is no implementation yet. If you are starting work, read `SPEC.md` in full before writing code.

## Key Concepts From the Spec

### WORKFLOW.md Contract

The service is configured entirely through a `WORKFLOW.md` file in the target project's repo. It contains YAML front matter (service config) and a Markdown body (the per-issue prompt template). There is no separate config file. The service watches this file and hot-reloads it without restart.

### Orchestration State vs. Tracker State

Two distinct state spaces:

- **Tracker states** — `Todo`, `In Progress`, `Done`, etc. (what Linear reports)
- **Orchestrator claim states** — `Unclaimed → Claimed → Running / RetryQueued → Released` (what the service tracks internally)

Dispatch eligibility is determined by tracker state; internal bookkeeping uses the claim state. See SPEC.md §7.

### Worker Turn Loop

A worker is not one-shot. After each Codex turn completes, the worker re-checks the issue's tracker state and starts another turn on the **same thread** (with only continuation guidance, not the full prompt again) until the issue leaves an active state or `agent.max_turns` is reached. After a clean worker exit, the orchestrator schedules a short 1-second continuation retry to check again. See SPEC.md §7.1.

### Safety Invariants (Non-Negotiable)

- The coding agent subprocess **must** run with `cwd == workspace_path`
- `workspace_path` must be a strict sub-path of `workspace_root` (normalized, no traversal)
- Workspace directory names are sanitized: only `[A-Za-z0-9._-]` allowed

See SPEC.md §9.5.

### Codex App-Server Protocol

The agent runner speaks a JSON-RPC-like line-delimited protocol over stdio with the Codex process. Startup sequence: `initialize` → `initialized` (notification) → `thread/start` → `turn/start`. See SPEC.md §10 for the full protocol contract.

## Architecture Layers (From the Spec)

| Layer | Responsibility |
|---|---|
| Workflow Loader | Parse `WORKFLOW.md` front matter and prompt body |
| Config Layer | Typed getters, env-var indirection (`$VAR`), defaults, hot-reload |
| Issue Tracker Client | Linear GraphQL adapter; normalizes to stable `Issue` model |
| Orchestrator | Poll tick, claim state, concurrency, retries, reconciliation |
| Workspace Manager | Sanitize keys, create/reuse dirs, run lifecycle hooks |
| Agent Runner | Launch Codex subprocess, speak app-server protocol, stream events |
| Status Surface (optional) | Operator-visible runtime view |

## Config Defaults Worth Remembering

- `polling.interval_ms`: 30000
- `agent.max_concurrent_agents`: 10
- `agent.max_turns`: 20
- `agent.max_retry_backoff_ms`: 300000 (5 min)
- `codex.turn_timeout_ms`: 3600000 (1 hr)
- `codex.stall_timeout_ms`: 300000 (5 min)
- `hooks.timeout_ms`: 60000
- Backoff formula: `min(10000 * 2^(attempt-1), max_retry_backoff_ms)`
- Continuation retry after clean exit: 1000 ms fixed

## Linear Integration

- GraphQL endpoint: `https://api.linear.app/graphql`
- Auth via `LINEAR_API_KEY` env var (or `$VAR` indirection in front matter)
- Required field: `tracker.project_slug`
- Dispatch blocker rule: if issue state is `Todo`, do not dispatch if any blocker is non-terminal

## Workspace Hook Failure Semantics

| Hook | On Failure |
|---|---|
| `after_create` | Fatal — abort workspace creation |
| `before_run` | Fatal — abort run attempt |
| `after_run` | Log and ignore |
| `before_remove` | Log and ignore |
