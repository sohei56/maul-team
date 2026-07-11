#!/usr/bin/env bash
# scripts/scrum/mark-pbi-ready-to-merge.sh — Developer-side handoff wrapper.
# Computes paths_touched (base..HEAD), atomically sets head_sha/ready_at/
# paths_touched on pbi-state.json, then sets backlog status to in_progress_merge.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

[ "$#" -eq 1 ] || fail E_INVALID_ARG "usage: mark-pbi-ready-to-merge.sh <pbi-id>"
PBI="$1"
assert_pbi_id "$PBI"

read_pbi_worktree_state "$PBI"
[ -n "$PBI_BASE_SHA" ] || fail E_INVALID_ARG "state.base_sha unset"
STATE=".scrum/pbi/$PBI/state.json"

HEAD="$(git -C "$PBI_WT" rev-parse HEAD)"
PATHS=()
# --diff-filter=AMR: include Added, Modified, Renamed paths only.
# Excluding Deleted paths prevents `merge-pbi.sh` artifact_missing
# false-positives when a PBI intentionally deletes files (the deleted
# paths would otherwise be recorded in `paths_touched` and then trip
# the `git ls-files --error-unmatch` artifact check post-merge).
while IFS= read -r line; do
  PATHS+=("$line")
done < <(git -C "$PBI_WT" diff --name-only --diff-filter=AMR "$PBI_BASE_SHA..HEAD")
if [ "${#PATHS[@]}" -eq 0 ]; then
  fail E_INVALID_ARG "no commits beyond base — refusing to mark ready_to_merge"
fi

# Deleted paths (--diff-filter=D) are collected SEPARATELY from PATHS. They are
# deliberately kept OUT of paths_touched (which stays AMR-only, so merge-pbi.sh
# does not flag an intentionally deleted file as artifact_missing), but the
# kind=docs boundary below must still inspect them: a docs PBI that DELETES a
# non-.md file (e.g. foo.sh) is as much a scope violation as one that adds code.
DELETED=()
while IFS= read -r line; do
  DELETED+=("$line")
done < <(git -C "$PBI_WT" diff --name-only --diff-filter=D "$PBI_BASE_SHA..HEAD")

# kind=docs PBIs are confined to *.md by design. A docs PBI that touches a
# non-.md path means either the PBI was mis-classified at refinement, or
# the implementer scope-crept into code. Either way the right move is to
# escalate to the SM rather than silently grant ready_to_merge: the
# UT/coverage gates were skipped under the docs contract, so a code change
# would slip through without test coverage.
BACKLOG=".scrum/backlog.json"
KIND="code"
if [ -f "$BACKLOG" ]; then
  KIND="$(jq -r --arg id "$PBI" '
    (.items[] | select(.id == $id) | .kind) // "code"
  ' "$BACKLOG")"
fi
if [ "$KIND" = "docs" ]; then
  NON_MD=()
  for p in "${PATHS[@]}"; do
    case "$p" in
      *.md) ;;
      *) NON_MD+=("$p") ;;
    esac
  done
  # Deletions of non-.md files are boundary violations too (see DELETED above).
  if [ "${#DELETED[@]}" -gt 0 ]; then
    for p in "${DELETED[@]}"; do
      case "$p" in
        *.md) ;;
        *) NON_MD+=("$p") ;;
      esac
    done
  fi
  if [ "${#NON_MD[@]}" -gt 0 ]; then
    printf >&2 '[mark-pbi-ready-to-merge] kind_mismatch for %s: non-.md paths touched:\n' "$PBI"
    for p in "${NON_MD[@]}"; do printf >&2 '  - %s\n' "$p"; done
    "$HERE/update-pbi-state.sh" "$PBI" escalation_reason kind_mismatch
    if pbi_in_backlog "$PBI" "$BACKLOG"; then
      "$HERE/update-backlog-status.sh" "$PBI" escalated
    fi
    fail E_INVALID_ARG "kind=docs PBI must not touch non-.md paths (see above; status set to escalated)"
  fi
fi

# Build paths_touched array literal for jq.
PATHS_JSON="$(printf '%s\n' "${PATHS[@]}" | jq -R . | jq -s .)"
NOW="$(_iso_utc_now)"

EXPR=".head_sha = \"$HEAD\""
EXPR="$EXPR | .ready_at = \"$NOW\""
EXPR="$EXPR | .paths_touched = $PATHS_JSON"

atomic_write "$STATE" "$EXPR" "$ROOT/docs/contracts/scrum-state/pbi-state.schema.json"

# Update backlog status to in_progress_merge (silently skip if PBI not in backlog).
# (BACKLOG was already resolved above for the kind boundary check.)
if pbi_in_backlog "$PBI" "$BACKLOG"; then
  "$HERE/update-backlog-status.sh" "$PBI" in_progress_merge
fi

printf '[mark-pbi-ready-to-merge] %s @ %s (%d paths)\n' "$PBI" "$HEAD" "${#PATHS[@]}"
