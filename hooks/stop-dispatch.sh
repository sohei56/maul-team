#!/usr/bin/env bash
# stop-dispatch.sh — Single Stop-hook entry point.
#
# Replaces the previous two-entry Stop registration (completion-gate.sh +
# dashboard-event.sh) with one dispatcher that:
#   1. forwards the Stop payload to dashboard-event.sh (best-effort —
#      dashboard logging must never block session exit), and
#   2. forwards the same payload to completion-gate.sh and propagates its
#      exit code (0 allow, 2 block).
#
# Why a dispatcher: Claude Code prints each registered Stop hook in the
# session UI, and the dashboard-event entry shows up as a duplicate Stop
# notification next to the gate. Folding them under one command removes
# that visual noise while keeping both behaviours.
#
# stdin is consumed exactly once, then replayed to each child. We do NOT
# source the children — they have their own `set -euo pipefail` and trap
# conventions, so we keep them isolated as subprocesses.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_HOOK="$HOOK_DIR/dashboard-event.sh"
COMPLETION_HOOK="$HOOK_DIR/completion-gate.sh"

# Read stdin once — only if something is actually piped in. Without the
# `-t 0` guard, running the dispatcher manually on a TTY would block on
# `cat`, which is the same defensive pattern completion-gate.sh uses.
payload=""
if [ ! -t 0 ]; then
  payload="$(cat 2>/dev/null || true)"
fi

# 1) Dashboard append (best-effort). The gate decision must never be
# starved by dashboard append failures (corrupted JSON, disk full, etc.),
# so we discard the child's exit status. Run dashboard FIRST so the
# Stop event is recorded even if the gate decides to exit 2 below — the
# gate path raises exit 2 via `exit`, which would prevent any "after"
# script from running.
if [ -x "$DASHBOARD_HOOK" ]; then
  printf '%s' "$payload" | "$DASHBOARD_HOOK" >/dev/null 2>&1 || true
fi

# 2) Completion gate — propagate its exit code verbatim. `set -e` is
# intentionally OFF (we use `set -uo pipefail` above) because we want to
# capture the gate's non-zero exit without aborting the dispatcher first.
if [ -x "$COMPLETION_HOOK" ]; then
  printf '%s' "$payload" | "$COMPLETION_HOOK"
  exit $?
fi

# No completion gate present — default to allow.
exit 0
