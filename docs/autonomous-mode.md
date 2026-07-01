# Autonomous PO Mode (Ralph Loop)

Operational guide for running the Scrum team without a human Product
Owner at the keyboard. When `po_mode == "agent"`, an autonomous
`product-owner` teammate takes every PO decision in place of the
human, and an outer watchdog process re-launches the Scrum Master
headlessly until the project reaches `state.json.phase == complete`
or a safety valve trips.

This document covers operation only. Normative contracts live in:

- [`docs/contracts/scrum-state/config.schema.json`](contracts/scrum-state/config.schema.json) — `po_mode`, `po`, `autonomous` keys.
- [`docs/contracts/scrum-state/autonomy.schema.json`](contracts/scrum-state/autonomy.schema.json) — watchdog runtime state.
- [`docs/contracts/scrum-state/po-decisions.schema.json`](contracts/scrum-state/po-decisions.schema.json) — append-only PO decision log.
- [`agents/product-owner.md`](../agents/product-owner.md) — PO teammate role, communication protocol, `kind` enum.
- [`rules/scrum-context.md`](../rules/scrum-context.md) § PO seat resolution — invariant routing rules.

## Overview

```text
        outer loop (Bash, ~hours)               inner loop (Claude session, ~minutes)
   ┌──────────────────────────────────┐     ┌──────────────────────────────────────┐
   │ scripts/autonomous/watchdog.sh   │ ──► │ claude -p --agent scrum-master ...   │
   │   safety valves, cost ledger,    │     │   reads .scrum/, runs ceremonies,    │
   │   rate-limit backoff, morning    │     │   delegates PO calls to              │
   │   report                         │ ◄── │   product-owner teammate             │
   └──────────────────────────────────┘     └──────────────────────────────────────┘
              ▲                                              │
              │ Stop hook releases when phase                │ PO decisions persist to
              │ advances or a checkpoint is hit              │ .scrum/po/decisions.json
              │ (retrospective / integration_sprint          │ (append-only, dec-NNNN)
              │  passed / complete / breaker)                ▼
              │                                       .scrum/state.json
              │                                       .scrum/backlog.json
              └────── morning report → .scrum/reports/autonomous-run-<run_id>.md
```

Two co-operating loops:

1. **Outer (watchdog).** `scripts/autonomous/watchdog.sh` runs once
   per autonomous run. Each iteration spawns a fresh headless
   Claude session, waits for it to exit, then accounts for cost,
   progress, and rate-limit signals before deciding whether to
   continue or stop.
2. **Inner (Claude session).** Each session is short-lived. The
   Stop hook (`completion-gate.sh`) keeps the session alive across
   intermediate work but allows exit at deterministic checkpoints
   (retrospective complete / integration_sprint passed / circuit
   breaker tripped / `phase == complete`). Between iterations,
   memory survives only via `.scrum/` SSOT files — in-process
   teammates do not persist across sessions.

## Prerequisites

The same prerequisites as interactive mode plus a small autonomy
overlay:

- Claude Code CLI on `PATH` with Agent Teams support
  (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set process-scoped by
  `scrum-start.sh` — users do not need to export it).
- Python 3.9+ with `textual` and `watchdog` packages (TUI dashboard).
- `jq` on `PATH` (required by every script under
  `scripts/scrum/` and `scripts/autonomous/`).
- A product brief at `docs/product/brief.md`, or supplied via
  `--brief <file>` on first run. The autonomous PO expands the
  brief into `docs/product/vision.md` during the Requirements
  Sprint; without a brief there is nothing to anchor YAGNI
  decisions against. **If no brief exists and you launch on a TTY,
  `scrum-start.sh` runs the [`create-brief`](../skills/create-brief/SKILL.md)
  skill first** — an interactive pre-flight session that co-authors
  `docs/product/brief.md` with you, then chains straight into the
  watchdog when you exit. On a non-TTY run (e.g. `--no-attach`, piped
  stdin) there is no human to interview, so a missing brief is still a
  hard error — supply `--brief <file>`.
- `.scrum/config.json.po_mode == "agent"` (set automatically by
  `scrum-start.sh --autonomous`).

Optional but recommended:

- A working `tmux` (the watchdog runs in the main pane; the TUI
  dashboard renders in the side pane).
- `codex` CLI for Layer-1 cross-model PBI review (the
  `codex-{design,impl,ut}-reviewer` sub-agents fall back to a
  Claude-based review without it).
- Playwright MCP (configured by `setup-user.sh` when `npx` is
  available) for browser-driven UAT in the
  [`po-acceptance`](../skills/po-acceptance/SKILL.md) skill.

## Starting an autonomous run

```bash
# Bootstrap a brand-new project (no .scrum/state.json yet):
sh /path/to/claude-scrum-team/scrum-start.sh --autonomous \
  --brief docs/product/brief.md \
  --max-sprints 3 --max-hours 12

# Resume an existing autonomous run:
sh /path/to/claude-scrum-team/scrum-start.sh --autonomous

# Overnight unattended run:
sh /path/to/claude-scrum-team/scrum-start.sh --autonomous --no-attach
```

Flags accepted by `scrum-start.sh`:

| Flag | Effect |
|---|---|
| `--autonomous` | Launches `scripts/autonomous/watchdog.sh` in the main pane instead of an interactive Claude session. Sets `po_mode = "agent"` and merges defaults into `.scrum/config.json.autonomous`. |
| `--brief <file>` | Copied to `docs/product/brief.md` if that file does not already exist. The PO teammate uses it as the YAGNI anchor. **Required on a new non-TTY run**; on a TTY, omitting it triggers the interactive `create-brief` pre-flight instead of erroring. |
| `--max-sprints N` | Overrides `.scrum/config.json.autonomous.max_sprints`. |
| `--max-hours H` | Overrides `.scrum/config.json.autonomous.max_wall_clock_hours`. |
| `--po-model <name>` | Sets the model used by the `product-owner` teammate. CLI aliases (`opus`, `sonnet`, `haiku`) or a specific model ID. Applied by patching `.claude/agents/product-owner.md` frontmatter `model:` before launch. The deployed file IS the SSOT — there is no shadow key in `.scrum/config.json`. The deployed value is captured before each `setup-user.sh` overwrite, so a prior `--po-model` choice persists across re-runs. Default `opus`. Rejected outside autonomous mode (exit 2) because the product-owner teammate is not spawned in human mode. |
| `--bypass-permissions` | Sets `autonomous.permission_mode = bypassPermissions` (default `dontAsk`). See [Permission model](#permission-model) — this is a destructive switch. |
| `--no-attach` | Skips `tmux attach-session` after launching. The session runs in the background; attach later with `tmux attach-session -t scrum-team-<basename>-<hash>`. |

On a new project the script needs a brief at
`docs/product/brief.md`. It is resolved in this order: (1) an
existing canonical brief is reused as-is; (2) an explicit `--brief
<file>` is copied into place; (3) on a **TTY with no brief**, the
interactive `create-brief` pre-flight co-authors one before the
watchdog starts; (4) on a **non-TTY with no brief**, the script
exits with code 2. The brief is copied / written **only when**
`docs/product/brief.md` does not already exist — re-runs preserve
the existing file.

#### Brief co-authoring pre-flight (`create-brief`)

When a new autonomous run finds no brief and a human is present
(stdin is a TTY), `scrum-start.sh` launches an interactive Claude
session that invokes the [`create-brief`](../skills/create-brief/SKILL.md)
skill. The skill interviews you one topic at a time (problem,
users, falsifiable success metrics, scope in/out, constraints,
priorities, risks), quality-gates the draft against product-brief
best practices, and writes `docs/product/brief.md`. When you exit
that session, the same pane chains straight into the watchdog — so
the brief you just wrote becomes the PO's YAGNI anchor with no
re-run needed. If you exit **without** writing a brief, the launch
aborts cleanly instead of running the PO with no anchor. The skill
is also usable standalone any time via `/create-brief`.

### Interactive wizard

When stdin is a TTY (no pipe/redirect) and `--autonomous` is given,
any setting **not** supplied via CLI flag is prompted at startup:

```text
Autonomous mode configuration (press Enter to accept defaults):
  Product brief file [docs/product/brief.md]:
  Maximum number of sprints [5]:
  Maximum wall-clock hours [8]:
  Product Owner model [opus]:
  Bypass permissions [y/N]:
```

Each default in `[…]` is the **prior value** for that setting:

- `--max-sprints`, `--max-hours`, `--bypass-permissions` defaults
  come from `.scrum/config.json.autonomous.*` (or the built-in
  default when the key is absent).
- `--po-model` default comes from `.claude/agents/product-owner.md`
  `model:` (captured before `setup-user.sh` overwrites it), or
  `opus` if the deployed file does not exist yet.

This means a re-run remembers your last choices and you can press
Enter through every prompt for a no-touch resume. The wizard is
automatically skipped when stdin is not a TTY (cron / pipe / bats
integration tests) — the CLI flags + prior values in
`.scrum/config.json` / the deployed agent file remain authoritative
in that case. It is also skipped under `SCRUM_START_DRY_RUN=1`.

## Config reference

`.scrum/config.json` keys consumed by autonomous mode (schema:
[`docs/contracts/scrum-state/config.schema.json`](contracts/scrum-state/config.schema.json)):

```json
{
  "po_mode": "agent",
  "po": {
    "max_clarification_rounds": 2,
    "max_integration_cycles": 3
  },
  "autonomous": {
    "max_iterations":               50,
    "max_wall_clock_hours":          8,
    "max_sprints":                   8,
    "max_consecutive_failures":      3,
    "stop_block_budget_per_phase":   8,
    "permission_mode":      "dontAsk",
    "notify_command":                null,
    "fallback_model":                null
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `po_mode` | `"human"` | When `"agent"`, every PO-approval point in every Scrum skill is routed to the `product-owner` teammate rather than the human user. Absence of the key behaves identically to `"human"`. |
| `po.max_clarification_rounds` | `2` (PO uses this when key absent) | How many `PO_CLARIFY` round-trips the PO may run before it must commit a binding decision with `assumption=true`. See [`agents/product-owner.md`](../agents/product-owner.md) § Anti-loop rules. |
| `po.max_integration_cycles` | (no default; advisory) | Max defect-fix loops the autonomous PO will tolerate before issuing `release_decision=no_go` and parking the run. |
| `autonomous.max_iterations` | `50` | Hard cap on watchdog iterations. Exceeded → exit 2 (`max_iterations_exceeded`). |
| `autonomous.max_wall_clock_hours` | `8` | Hard wall-clock budget for the whole run. Exceeded → exit 2. |
| `autonomous.max_sprints` | `8` | Number of Sprints to run **this launch**, counted from the `sprint-history.json.sprints` length captured at watchdog startup (the *baseline*, persisted as `autonomy.json.sprint_baseline`) — **not** a cumulative cap. The watchdog stops once history reaches `baseline + max_sprints`. Example: a project with 10 Sprints in history launched with `max_sprints=8` runs through Sprint 18. Exit 2. |
| `autonomous.max_consecutive_failures` | `3` | Number of consecutive zero-progress iterations (or non-zero Claude exit codes, or tripped circuit breakers) before the watchdog gives up. Exit 1. |
| `autonomous.stop_block_budget_per_phase` | `8` | **Autonomous mode only.** Per workflow phase, how many times the Stop hook may block exit before tripping the circuit breaker. Resets when the phase changes. Used by `completion-gate.sh`. In **human mode** the gate ignores this key and instead fingerprint-dedups blocks via `.scrum/stop-gate.json` (first identical block exits 2, repeats allow exit); teammate liveness is monitored by the external `scripts/stall-watchdog.sh` daemon. |
| `autonomous.permission_mode` | `"dontAsk"` | One of `dontAsk` \| `bypassPermissions`. `bypassPermissions` skips every confirmation prompt, including destructive writes outside the allowlist — only use it when running in a throwaway worktree. |
| `autonomous.notify_command` | `null` | Shell command run at the end of the run with `WATCHDOG_EXIT=<exit-code>` in env. Useful for desktop notification / Slack ping. Failures are swallowed. |
| `autonomous.fallback_model` | `null` | Passed to `claude -p --fallback-model` when set. The CLI falls back to this model when the primary model is unavailable. |

The PO teammate's model is **not** stored in `.scrum/config.json`. Its
single source of truth is the `model:` field in
`.claude/agents/product-owner.md` (the deployed copy that the Claude
Code agent parser reads at teammate spawn). The `--po-model` flag on
`scrum-start.sh --autonomous` (or the interactive wizard, see below)
patches that line in place. The deployed file value is captured before
each `setup-user.sh` overwrite so a prior `--po-model` choice persists
across re-runs without a shadow key in config.

## Observing a run

Three independent surfaces, all read-only:

- **`tmux attach-session -t <session>`** — Main pane shows the
  watchdog's per-iteration banner (`watchdog: iteration N
  (phase=X, sid=...)`) and the inner Claude session's last few
  characters before exit. Side pane shows the live TUI dashboard
  (panels for Sprint overview / PBI board / Work Log). Session
  name is
  `scrum-team-<sanitized-basename>-<pwd-hash>`. With `--no-attach`,
  `scrum-start.sh` prints the name.
- **`.scrum/autonomous/iter-<N>.json`** — Raw JSON output of the
  N-th `claude -p` call, including `total_cost_usd`,
  `permission_denials`, and the final assistant message. Pair with
  `.scrum/autonomous/iter-<N>.err` for stderr.
- **`.scrum/dashboard.json` / `.scrum/communications.json`** —
  Append-only event logs that the TUI dashboard renders. Useful
  when the watchdog is running headless: `jq '.events[-20:]'
  .scrum/dashboard.json`.

The watchdog also writes `.scrum/autonomy.json` with the current
iteration, run-id, and `total_cost_usd`. `lead_session_id` is the
session uuid issued by the watchdog for the current iteration (the
Stop hook compares against this to distinguish lead from teammate
sessions).

## Morning review

When the watchdog exits, it writes
`.scrum/reports/autonomous-run-<run_id>.md` summarizing the run
and (when configured) invokes `autonomous.notify_command`. The
report contains:

- Run metadata (run_id, started_at, exit reason, final phase,
  iterations, total cost, last lead session id).
- Completed Sprints from `.scrum/sprint-history.json`.
- PBI status buckets: `done`, `escalated`, `blocked`.
- An inline copy of `.scrum/po/attention.md` (human-only items).
- Pointers to every `iter-<N>.json` so you can drill in.

For day-to-day reviews:

```bash
# Recent PO decisions:
jq '.decisions[-10:]' .scrum/po/decisions.json

# Just the release-blockers:
jq '.decisions[] | select(.kind=="release_decision")' .scrum/po/decisions.json

# Per-PBI demo acceptance trail:
jq '.decisions[] | select(.kind=="demo_acceptance" and .pbi_id=="pbi-007")' \
   .scrum/po/decisions.json

# Anything the PO marked under best-effort assumption:
jq '.decisions[] | select(.assumption==true)' .scrum/po/decisions.json
```

`.scrum/po/attention.md` is the human-only queue. The PO appends
numbered entries here for matters it must defer (credentials,
billing, legal, production deploy). Entries tagged
`release-blocking: yes` block `release_decision=go`. Drain this
queue before the next run.

## Safety valves and circuit breakers

The watchdog enforces four global bounds and one per-phase one:

1. `max_iterations` — hard cap on outer-loop turns.
2. `max_wall_clock_hours` — hard cap from `started_at`.
3. `max_sprints` — Sprints run this launch, i.e. `sprint-history.json.sprints`
   length minus the baseline captured at startup (`autonomy.json.sprint_baseline`).
4. `max_consecutive_failures` — three consecutive zero-progress
   iterations (no change in `phase | sprint_id | <pbi-id>:<status>`
   set) trips a give-up.

There is **no USD spend cap**: the watchdog records
`total_cost_usd` in `autonomy.json` and the morning report for
observability only. Spend ceilings are expected to live in the
operator's Claude subscription plan (and the API limit itself
becomes the wait-and-resume trigger described below).

One more guard for the inner loop:

- `stop_block_budget_per_phase` — **autonomous mode only.**
  `completion-gate.sh` increments a counter every time it blocks
  exit in the same phase. On the N+1-th block in the same phase it
  records `.circuit_breaker_tripped = {phase, at}` in
  `autonomy.json` and allows exit. The watchdog reads the breaker
  and treats the iteration as a no-progress failure. In human
  mode this counter is not maintained: `completion-gate.sh`
  fingerprint-dedups identical blocks via `.scrum/stop-gate.json`
  and an external `scripts/stall-watchdog.sh` daemon handles
  teammate liveness.

### Rate-limit / usage-limit handling

When the inner Claude session ends because of a rate-limit, usage-
limit, or overload error, the watchdog **waits and resumes** rather
than counting it as a failure. Detection sources:

- The captured `iter-<N>.json` result envelope, when `is_error =
  true` and the `subtype` or `errors[]` payload matches
  `rate.?limit|usage.?limit|overload|429|too.?many` (case-insensitive).
- `.scrum/dashboard.json` `stop_failure` events newer than the
  current iteration's start, with the same pattern.

The watchdog tries to extract a reset time from the error payload —
ISO 8601 timestamps, `reset(s)? in N (hour|minute|second)s?` phrases,
or 10-digit unix epochs. If one is found, it sleeps until that time
plus 60s jitter (capped at 6 hours). Otherwise it sleeps for
`DEFAULT_RATE_LIMIT_WAIT_SECS` (1 hour). The iteration counter is
**not** advanced for a wait, so a long rate-limit window does not
burn through `max_iterations`; `max_wall_clock_hours` remains the
runaway protection.

There is no rate-limit streak ceiling — the watchdog waits as long
as it takes.

### Watchdog exit codes

| Code | Meaning |
|---|---|
| `0` | `state.json.phase == complete` was observed at the top of an iteration. Workflow finished. |
| `1` | `max_consecutive_failures` was reached. The run is parked — investigate via the morning report. |
| `2` | A safety valve tripped (`max_iterations`, `max_wall_clock_hours`, `max_sprints`). The run is parked. |
| `3` | Configuration error (most commonly `.scrum/autonomy.json` is missing — run `scrum-start.sh --autonomous` first). |

## Permission model

`autonomous.permission_mode` controls the inner CLI session's
permission prompts:

- **`dontAsk`** (default). The CLI takes the project's
  `.claude/settings.json` permissions allowlist at face value and
  never prompts the user. Anything the allowlist does not cover is
  *denied*; the assistant must request the permission explicitly
  (visible as a `permission_denials` entry in
  `iter-<N>.json`). This is the recommended setting — combined
  with the path-guard hook for the `product-owner` teammate (writes
  limited to `docs/product/**` and `.scrum/po/**`) it gives a
  reasonably tight blast radius.
- **`bypassPermissions`** (via `--bypass-permissions`). The CLI
  skips all permission checks. Use only when running inside a
  disposable worktree / container. The Scrum-state guard and
  path-guard hooks still apply; everything else (raw Bash, Web
  fetches, MCP servers) is allowed. **Warning:** combined with
  Playwright MCP this means the PO teammate can drive a real
  browser and make outbound network calls without any prompt.

`setup-user.sh` registers `mcp__playwright` in the project's
permission allowlist by default. The PO teammate is exempt from
the `Bash`-block branch of the path-guard hook (it must launch
the app under test for `po-acceptance`). All other PO writes are
fenced to `docs/product/**` and `.scrum/po/**`.

## Smoke spike before first real run

Before pointing the autonomous mode at a real project, validate
that `claude -p` + Agent Teams + the Stop gate actually behave as
this guide claims on your machine. The pieces under test are:

- Headless `claude -p` accepts `--agent scrum-master`,
  `--session-id`, `--permission-mode`, `--fallback-model`, and
  `--output-format json`.
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is honoured in a
  headless session (the SM can `SendMessage` and spawn the PO
  teammate).
- The Stop hook (`completion-gate.sh`) returns exit 2 with a
  block reason while there is forward work, and the watchdog
  responds by recycling the session.

Suggested smoke procedure (run once, in a throwaway directory):

1. `mkdir -p ~/tmp/scrum-spike && cd ~/tmp/scrum-spike`
2. `cat > brief.md <<'EOF'` ... a 30-line product brief for a
   trivial app (e.g., a CLI todo with one feature) ... `EOF`
3. `sh /path/to/claude-scrum-team/scrum-start.sh --autonomous \`
   `  --brief brief.md --max-sprints 1 --max-hours 1 \`
   `  --max-sprints 1 --no-attach`
4. Tail `tmux capture-pane -t scrum-team-... -p` and
   `.scrum/dashboard.json` while the watchdog runs.
5. Confirm three signals: an iteration banner appears in stderr;
   `.scrum/state.json.phase` advances past `new`; the PO teammate
   writes at least one entry to `.scrum/po/decisions.json`.
6. Either let it finish (`exit 0`) or kill it after one Sprint
   completes. Inspect the morning report at
   `.scrum/reports/autonomous-run-*.md`.

If any step fails — most commonly because a CLI flag has been
renamed in a newer Claude Code release, or Agent Teams headless is
broken on your version — fall back to the degraded plan in the
next section before trying again on the real project.

## Known constraints and fallbacks

- **In-process teammates do not survive session restarts.** The
  watchdog assumes the lead SM session will respawn the PO and
  Developers via the Liveness Protocol at the start of each
  iteration. Without that, the SM will appear stuck. See
  `agents/scrum-master.md` § Autonomous PO Mode.
- **`--teammate-mode in-process` is not used in headless mode.**
  The CLI accepts the flag (verified 2026-06) but it is undocumented
  in `claude --help`; the watchdog omits it because there is no
  human in the tmux pane to navigate split panes. The interactive
  entry point still passes it.
- **Stop-hook checkpoint coverage.** Today the hook allows exit at
  `retrospective`, `integration_sprint`, `complete`, and a
  **rollover `backlog_created`** (one that follows a completed Sprint,
  i.e. `sprint-history.json` is non-empty — the recycle point created
  by the Retrospective's sprint-continuation handshake), plus when
  the circuit breaker trips. The *initial* `backlog_created`
  (post-Requirements, empty Sprint history) still blocks so the SM
  proceeds straight into the first Sprint Planning. If a future
  change adds a phase that should also recycle the session, update
  `completion-gate.sh`'s `autonomous_intercept_or_allow` case table;
  otherwise iterations stall on `stop_block_budget_per_phase` until
  the breaker fires.
- **End-of-Sprint continuation is a PO decision.** A Retrospective
  must not leave `state.json.phase` at `retrospective`: that phase
  never advances on its own, so the watchdog's `progress_hash` stays
  constant and the run is (wrongly) judged `no_progress` until the
  consecutive-failure breaker kills it. The fix: the Retrospective's
  final step (`retrospective` skill Step 8) asks the PO a
  `kind=sprint_continuation` decision
  (`next_sprint` / `integration_sprint` / `complete`) and advances
  the phase accordingly (`backlog_created` / `integration_sprint` /
  `complete`). The PO owns this call because it hinges on
  Product-Goal completion. See `agents/product-owner.md`
  § Sprint continuation.
- **Fallback when headless Agent Teams misbehaves.** If a CLI
  release breaks the headless Agent Teams path (e.g., teammates
  cannot be spawned from `-p` sessions), the operational fallback
  is to drop autonomous mode and run the interactive entry point
  in a long-lived tmux pane with `po_mode=agent` still set in
  config: the Stop hook still drives "do X next" prompts via
  `completion-gate.sh`, the PO teammate still files decisions,
  and the human in the loop is reduced to occasional `Enter`
  presses to keep the inner session alive. This loses the cost
  accounting and morning report but preserves the audit trail.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `watchdog: .scrum/autonomy.json missing — run scrum-start.sh --autonomous first.` (exit 3) | Watchdog ran without `scrum-start.sh --autonomous` bootstrap. | Run `scrum-start.sh --autonomous` once to set `po_mode=agent`, default `autonomous.*` keys, and initialize `.scrum/autonomy.json`. |
| `Error: --autonomous on a new project requires --brief <file>.` (exit 2) | First run with no `.scrum/state.json` and no brief, on a **non-TTY** invocation (no human to interview). | Provide `--brief docs/product/brief.md` (or any path), or re-run on a TTY to co-author one via the `create-brief` pre-flight. |
| `watchdog: rate-limit detected; sleeping <N>s until reset` / `... no reset time parsed — sleeping <N>s` | Inner session hit the API rate limit / usage limit / overload error. Watchdog is waiting until the limit resets (advertised reset time + 60s jitter, capped at 6h) or `DEFAULT_RATE_LIMIT_WAIT_SECS` (1h) when no reset time was parseable. | Wait. The iteration counter is not advanced; `max_wall_clock_hours` is the only runaway protection. To resume sooner, kill the watchdog and rerun `scrum-start.sh --autonomous` once your subscription quota refills. |
| `watchdog: K consecutive failures — giving up.` (exit 1) | Three consecutive iterations made no progress (no phase/PBI status change), or the inner Claude session kept failing, or the circuit breaker tripped K times. | Inspect `.scrum/autonomous/iter-<N>.json`, `iter-<N>.err`, and `.scrum/autonomy.json.last_failure`. Common causes: missing PO context (no `docs/product/brief.md`), a deadlocked Stop hook (check `completion-gate.sh` logs in `.scrum/hooks.log`), or persistent CLI errors that aren't rate-limits (those would have triggered the wait branch instead). |
| `watchdog: max_sprints (N) reached` (exit 2) | The watchdog ran `N` Sprints this launch (history reached `baseline + N`). | This is "successful park", not a failure — review the morning report and either declare the product done manually or relaunch to grant another `N`-Sprint budget from the new baseline. |
| PO teammate keeps appending to `.scrum/po/attention.md` and the run halts. | The PO is correctly deferring human-only items (credentials, legal, billing). | Resolve the items, drain `attention.md`, then resume with `scrum-start.sh --autonomous`. |
| `release_decision=go requires .scrum/test-results.json` from `append-po-decision.sh`. | PO tried to call `release_decision=go` without a green smoke-test run. | Run the `smoke-test` skill (Integration Sprint), confirm `overall_status ∈ {passed, passed_with_skips}`, then retry. |
| Stop hook logs `Circuit breaker tripped for phase 'X'`. | Same phase blocked exit more than `stop_block_budget_per_phase` times. | The SM is stuck in `X`. Inspect the most recent `iter-N.json` for the assistant's last action and unblock manually (advance `state.json.phase`, resolve a stuck PBI, drain `attention.md`). The watchdog clears the breaker on the next iteration. |
