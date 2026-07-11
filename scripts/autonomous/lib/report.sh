#!/usr/bin/env bash
# Markdown backticks inside literal printf strings are not parameter
# expansions; silence the noisy SC2016 warnings file-wide (the directive
# must precede the first command to apply to the whole file).
# shellcheck disable=SC2016
# scripts/autonomous/lib/report.sh — morning-report + notify helpers for
# the autonomous-PO watchdog (Ralph Loop).
#
# Sourced by scripts/autonomous/watchdog.sh. Exposes:
#
#   generate_morning_report <exit_reason>
#     Writes .scrum/reports/autonomous-run-<run_id>.md summarising the run:
#     end reason, final phase, completed Sprint goals (sprint-history.json),
#     PBI buckets (done / escalated / blocked), iteration count and total cost
#     (autonomy.json), attention.md excerpt if present, and pointers to each
#     iter-N.json output file.
#
#   run_notify <exit_code>
#     If config has a non-null autonomous.notify_command, execute it via
#     `bash -c`. Never let the notify command's failure propagate.
#
# Design notes:
#   - Bash 3.2 compatible (no associative arrays).
#   - Fail-open: a missing input file degrades gracefully ("unknown" or
#     "no data") instead of aborting the report.
#   - All reads tolerate malformed JSON via `jq … 2>/dev/null || echo …`.

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_AUTON_REPORT_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_AUTON_REPORT_SH_LOADED=1

# Shared fall-through JSON scalar reader (jq_cfg_or). Sourced here so this
# lib stays self-contained even though watchdog.sh also sources jq-read.sh
# (double-source guarded).
# shellcheck source=../../lib/jq-read.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/jq-read.sh"

# Files (overridable by the watchdog if it ever needs to redirect).
: "${AUTON_REPORT_AUTONOMY_FILE:=.scrum/autonomy.json}"
: "${AUTON_REPORT_STATE_FILE:=.scrum/state.json}"
: "${AUTON_REPORT_SPRINT_HISTORY:=.scrum/sprint-history.json}"
: "${AUTON_REPORT_BACKLOG_FILE:=.scrum/backlog.json}"
: "${AUTON_REPORT_CONFIG_FILE:=.scrum/config.json}"
: "${AUTON_REPORT_ATTENTION_FILE:=.scrum/po/attention.md}"
: "${AUTON_REPORT_DIR:=.scrum/reports}"
: "${AUTON_REPORT_ITER_DIR:=.scrum/autonomous}"

# _jq_safe <file> <expr> <fallback>
# Run jq on <file>; if the file is missing or unparseable, or the value is
# empty / literal "null", echo <fallback>. Thin alias over the shared
# jq_cfg_or (scripts/lib/jq-read.sh), kept so the many call sites here and
# in watchdog.sh read naturally.
_jq_safe() {
  jq_cfg_or "$1" "$2" "$3"
}

# generate_morning_report <exit_reason>
generate_morning_report() {
  local exit_reason="${1:-unknown}"
  local run_id started_at lead_sid iteration total_cost final_phase
  local report_path

  run_id="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.run_id' 'unknown-run')"
  started_at="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.started_at' 'unknown')"
  lead_sid="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.lead_session_id // "n/a"' 'n/a')"
  iteration="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.iteration // 0' '0')"
  total_cost="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.total_cost_usd // 0' '0')"
  final_phase="$(_jq_safe "$AUTON_REPORT_STATE_FILE" '.phase // "unknown"' 'unknown')"
  local last_failure_reason last_failure_at
  last_failure_reason="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.last_failure.reason // empty' '')"
  last_failure_at="$(_jq_safe "$AUTON_REPORT_AUTONOMY_FILE" '.last_failure.at // empty' '')"

  mkdir -p "$AUTON_REPORT_DIR"
  report_path="${AUTON_REPORT_DIR}/autonomous-run-${run_id}.md"

  # Body assembled into a temp file via append; using heredoc per block keeps
  # the markdown legible and avoids one massive interpolated string.
  : > "$report_path"
  # Note: format strings start with `-` (markdown list item), so every printf
  # uses `--` to end option parsing — required on Bash 3.2 / older builds.
  {
    printf '# Autonomous PO Run Report\n\n'
    printf -- '- **Run ID**: `%s`\n' "$run_id"
    printf -- '- **Started**: %s\n' "$started_at"
    printf -- '- **Exit reason**: %s\n' "$exit_reason"
    printf -- '- **Final workflow phase**: `%s`\n' "$final_phase"
    printf -- '- **Iterations**: %s\n' "$iteration"
    printf -- '- **Total cost (USD)**: %s\n' "$total_cost"
    printf -- '- **Last lead session id**: `%s`\n' "$lead_sid"
    # last_failure surfaces the most recent watchdog/Stop-hook failure
    # so the morning report has a single visible reason — without this
    # the field would be write-only state on .scrum/autonomy.json
    # (docs/autonomous-mode.md promises operators can see it here).
    if [ -n "$last_failure_reason" ]; then
      printf -- '- **Last failure**: `%s` at `%s`\n' "$last_failure_reason" "${last_failure_at:-unknown}"
    fi
    printf '\n'
  } >> "$report_path"

  # --- Completed Sprints ---
  printf '## Completed Sprints\n\n' >> "$report_path"
  if [ -f "$AUTON_REPORT_SPRINT_HISTORY" ] && jq empty "$AUTON_REPORT_SPRINT_HISTORY" >/dev/null 2>&1; then
    local sprint_count
    sprint_count="$(jq -r '(.sprints // []) | length' "$AUTON_REPORT_SPRINT_HISTORY" 2>/dev/null || echo 0)"
    if [ "${sprint_count:-0}" -gt 0 ]; then
      jq -r '
        (.sprints // [])
        | to_entries[]
        | "- **Sprint #" + ((.key + 1) | tostring) + "** (`" + (.value.id // "n/a") + "`)"
          + " — status=" + (.value.status // "unknown")
          + ", goal=" + ((.value.goal // "(no goal)") | tostring)
      ' "$AUTON_REPORT_SPRINT_HISTORY" 2>/dev/null >> "$report_path" || true
    else
      printf -- '- _No completed Sprints recorded._\n' >> "$report_path"
    fi
  else
    printf -- '- _No `sprint-history.json` yet._\n' >> "$report_path"
  fi
  printf '\n' >> "$report_path"

  # --- PBI buckets ---
  printf '## PBI Status Buckets\n\n' >> "$report_path"
  if [ -f "$AUTON_REPORT_BACKLOG_FILE" ] && jq empty "$AUTON_REPORT_BACKLOG_FILE" >/dev/null 2>&1; then
    local statuses
    local bucket
    # Quoted "done" so shellcheck does not flag the loop word as the closing
    # keyword of the surrounding `do … done`.
    for bucket in "done" escalated blocked cancelled; do
      printf '### %s\n\n' "$bucket" >> "$report_path"
      statuses="$(jq -r --arg s "$bucket" '
        [(.items // [])[] | select((.status // "") == $s)
          | "- `" + (.id // "n/a") + "` — " + ((.title // "(no title)") | tostring)]
        | (if length == 0 then ["- _none_"] else . end)
        | .[]
      ' "$AUTON_REPORT_BACKLOG_FILE" 2>/dev/null || echo "- _none_")"
      printf '%s\n\n' "$statuses" >> "$report_path"
    done
  else
    printf -- '- _No `backlog.json` yet._\n\n' >> "$report_path"
  fi

  # --- Attention items ---
  printf '## Attention items\n\n' >> "$report_path"
  if [ -f "$AUTON_REPORT_ATTENTION_FILE" ]; then
    printf -- '```markdown\n' >> "$report_path"
    cat "$AUTON_REPORT_ATTENTION_FILE" >> "$report_path" 2>/dev/null || true
    printf '\n```\n\n' >> "$report_path"
  else
    printf -- '_No attention.md produced this run._\n\n' >> "$report_path"
  fi

  # --- Iteration output pointers ---
  printf '## Iteration outputs\n\n' >> "$report_path"
  if [ -d "$AUTON_REPORT_ITER_DIR" ]; then
    local f any=0
    # Bash 3.2-compatible glob loop with explicit no-match guard
    for f in "$AUTON_REPORT_ITER_DIR"/iter-*.json; do
      [ -e "$f" ] || continue
      any=1
      printf -- '- `%s`\n' "$f" >> "$report_path"
    done
    if [ "$any" = "0" ]; then
      printf -- '- _No iteration output files._\n' >> "$report_path"
    fi
  else
    printf -- '- _No `%s` directory._\n' "$AUTON_REPORT_ITER_DIR" >> "$report_path"
  fi
  printf '\n' >> "$report_path"

  printf '%s\n' "$report_path"
}

# run_notify <exit_code>
run_notify() {
  local exit_code="${1:-0}"
  [ -f "$AUTON_REPORT_CONFIG_FILE" ] || return 0
  local cmd
  cmd="$(jq -r '.autonomous.notify_command // empty' "$AUTON_REPORT_CONFIG_FILE" 2>/dev/null || true)"
  [ -n "$cmd" ] || return 0

  # Run the notify command under bash -c so users can use pipes / vars.
  # Pass exit code as $WATCHDOG_EXIT for the command.
  WATCHDOG_EXIT="$exit_code" bash -c "$cmd" >/dev/null 2>&1 || \
    printf 'watchdog: notify_command exited non-zero (ignored)\n' >&2

  return 0
}
