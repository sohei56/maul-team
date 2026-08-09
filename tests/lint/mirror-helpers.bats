#!/usr/bin/env bats
# tests/lint/mirror-helpers.bats — pin the documented hand-synced mirror
# helpers so silent drift fails CI (OD-1 ruling: lint-pin over deploy-layout
# change). The codebase deliberately duplicates a few helpers per process
# family (hooks deploy to .claude/hooks/, wrappers to .scrum/scripts/,
# daemons run in-place — the "no-cross-source convention"); each copy carries
# a "keep in sync" comment. These tests grep the CURRENT file layout (robust
# to line-number drift; sensitive to body drift) and assert the mirrored
# bodies still agree. A one-sided edit of any mirror fails here — either
# propagate it to every copy or revisit the mirror strategy.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# --- 1. In-flight PBI filter (behavioral, highest value) --------------------
# scripts/scrum/lib/activity.sh (in_flight_snapshot — the one home for the
# filter in the scripts/ family, sourced both by the deployed wrappers and
# in-place by scripts/stall-watchdog.sh) and hooks/completion-gate.sh (inline
# jq in the pbi_pipeline_active branch) must agree on what "in-flight" means:
# status starts with in_progress_ AND is not in_progress_merge. If the two
# disagree, the stall watchdog and the Stop gate diverge on liveness.

# Extract the in_progress_-excluded status names a file's jq filter carries
# (the `!= "in_progress_x"` selects), sorted one per line.
_excluded_statuses() {
  grep -o '!= *"in_progress_[a-z_]*"' "$1" \
    | grep -o 'in_progress_[a-z_]*' | sort -u
}

@test "mirror-helpers: in-flight filter predicates agree (activity.sh vs completion-gate)" {
  local act="$PROJECT_ROOT/scripts/scrum/lib/activity.sh"
  local cg="$PROJECT_ROOT/hooks/completion-gate.sh"

  # Both sides use the startswith predicate, exactly once each — a second
  # occurrence would mean the filter got re-duplicated within a file.
  [ "$(grep -c 'startswith("in_progress_")' "$act")" -eq 1 ]
  [ "$(grep -c 'startswith("in_progress_")' "$cg")" -eq 1 ]

  # The daemon no longer carries its own copy: it sources activity.sh. A
  # re-appearance here would be the third copy the extraction removed.
  [ "$(grep -c 'startswith("in_progress_")' "$PROJECT_ROOT/scripts/stall-watchdog.sh")" -eq 0 ]

  # The exclusion sets must be identical (currently: in_progress_merge only).
  local excl_act excl_cg
  excl_act="$(_excluded_statuses "$act")"
  excl_cg="$(_excluded_statuses "$cg")"
  [ -n "$excl_act" ]
  [ "$excl_act" = "$excl_cg" ] || {
    echo "in-flight exclusion sets diverged:" >&2
    echo "  activity.sh:     $excl_act" >&2
    echo "  completion-gate: $excl_cg" >&2
    return 1
  }
  # Pin the current semantic: in_progress_merge is the (sole) exclusion.
  printf '%s\n' "$excl_act" | grep -Fxq "in_progress_merge"
}

# --- 2. get_pbi_status jq body ----------------------------------------------
# scripts/scrum/lib/queries.sh::get_pbi_status and hooks/lib/validate.sh::
# get_pbi_status_from_backlog carry the identical jq filter (only the default
# arg differs). Extract each filter line and compare verbatim.

# Print the single-quoted jq filter on the first line containing the
# id-select, with the surrounding quotes / continuation stripped.
_pbi_status_filter() {
  grep -m1 'select(.id == \$id)' "$1" | sed "s/^[[:space:]]*'//; s/'.*\$//"
}

@test "mirror-helpers: get_pbi_status jq filter identical (queries.sh vs validate.sh)" {
  local a b
  a="$(_pbi_status_filter "$PROJECT_ROOT/scripts/scrum/lib/queries.sh")"
  b="$(_pbi_status_filter "$PROJECT_ROOT/hooks/lib/validate.sh")"
  [ -n "$a" ]
  [ "$a" = "$b" ] || {
    echo "get_pbi_status jq filter diverged:" >&2
    echo "  queries.sh:  $a" >&2
    echo "  validate.sh: $b" >&2
    return 1
  }
}

# --- 3. Timestamp format ----------------------------------------------------
# Five mirror definitions of the ISO-8601 UTC helper exist by design
# (validate.sh get_timestamp is authoritative). All must carry the same
# format string so every SSOT writer stamps identically.

@test "mirror-helpers: ISO-8601 timestamp format identical in all five mirrors" {
  local fmt='date -u +"%Y-%m-%dT%H:%M:%SZ"'
  local f
  for f in \
    hooks/lib/validate.sh \
    scripts/lib/time.sh \
    scripts/scrum/lib/atomic.sh \
    hooks/lib/autonomy.sh \
    hooks/lib/stop-gate-state.sh; do
    grep -Fq "$fmt" "$PROJECT_ROOT/$f" || {
      echo "$f no longer carries the canonical timestamp format '$fmt'" >&2
      return 1
    }
  done
}

# The mirror functions themselves still exist under their documented names —
# a rename would silently detach a mirror from the pin above.
@test "mirror-helpers: timestamp mirror functions exist under documented names" {
  grep -q '^get_timestamp()'   "$PROJECT_ROOT/hooks/lib/validate.sh"
  grep -q '^iso_utc_now()'     "$PROJECT_ROOT/scripts/lib/time.sh"
  grep -q '^_iso_utc_now()'    "$PROJECT_ROOT/scripts/scrum/lib/atomic.sh"
  grep -q '^_autonomy_now()'   "$PROJECT_ROOT/hooks/lib/autonomy.sh"
  grep -q '^_stop_gate_now()'  "$PROJECT_ROOT/hooks/lib/stop-gate-state.sh"
}

# --- 4. Portable mtime idiom ------------------------------------------------
# Two copies of the BSD/GNU mtime read exist by design (scripts/ family vs
# hooks/lib). Both must VALIDATE each stat candidate as a pure integer before
# using it: on Linux, GNU stat reads `-f %m` as "filesystem status of a file
# named %m" and prints a multi-line block with a nonzero exit, so the naive
# `stat -f %m … || stat -c %Y …` chain concatenates garbage with the real
# epoch and blows up the caller's arithmetic. We pin the SHAPE (both stat
# forms + the integer guard) rather than compare bodies verbatim, because the
# function names and the doc-snippet early returns legitimately differ.

@test "mirror-helpers: both mtime copies validate stat output as a pure integer" {
  local f
  for f in scripts/scrum/lib/activity.sh hooks/lib/validate.sh; do
    grep -Fq 'stat -f %m' "$PROJECT_ROOT/$f" || {
      echo "$f lost the BSD stat candidate ('stat -f %m')" >&2
      return 1
    }
    grep -Fq 'stat -c %Y' "$PROJECT_ROOT/$f" || {
      echo "$f lost the GNU stat candidate ('stat -c %Y')" >&2
      return 1
    }
    grep -Fq "''|*[!0-9]*)" "$PROJECT_ROOT/$f" || {
      echo "$f lost the pure-integer guard (\"''|*[!0-9]*)\")" >&2
      return 1
    }
  done
}

# Durability pin: catch a future re-introduction of the unvalidated chain
# anywhere in the three trees that carry shell (including the snippets
# skills/ hand to agents, which get pasted into real commands).
@test "mirror-helpers: no naive 'stat -f %m || stat -c %Y' chain anywhere" {
  run grep -rn 'stat -f %m[^|]*|| *stat -c %Y' \
    "$PROJECT_ROOT/hooks" "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/skills"
  [ "$status" -ne 0 ] || {
    echo "unvalidated stat fallback chain found (aborts hooks on Linux):" >&2
    echo "$output" >&2
    return 1
  }
}
