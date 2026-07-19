#!/usr/bin/env bash
# quality-gate.sh — TaskCompleted hook
# Enforces the Definition of Done (DoD) for completed PBIs.
#
# Fires on every task completion (TaskCompleted has no matcher). The only
# fields we may rely on from the payload are the documented ones —
# common: session_id, transcript_path, cwd, hook_event_name;
# task:   task_id, task_name, task_status (always "completed").
# Additional fields are UNSPECIFIED, so the PBI id is recovered by scanning
# task_name (and, defensively, task_id) for a `[Pp][Bb][Ii]-[0-9]+` token.
#
# Exit policy:
#   * No PBI id in the task            -> exit 0, silent (never block a
#                                         non-PBI task).
#   * PBI id found but backlog missing
#     / unreadable / id not in backlog -> exit 0, advisory stderr note
#                                         (never block on infrastructure
#                                         absence).
#   * PBI found, all DoD checks pass    -> exit 0.
#   * PBI found, one+ DoD check fails,
#     status claims pipeline completion -> exit 2, one combined stderr
#                                         message listing every failed
#                                         check and the PBI id (blocks).
#   * PBI found, one+ DoD check fails,
#     status is mid-/pre-pipeline       -> exit 0, same combined message
#                                         as an ADVISORY stderr note.
#
# Blocking is status-scoped: DoD is only claimable at merge-readiness, so a
# failed check hard-blocks (exit 2) ONLY when items[].status is one of
# {in_progress_merge, awaiting_cross_review, cross_review, done}. For any
# other (mid-pipeline / pre-pipeline) status, per-stage task completions must
# not hard-block — the same message is emitted as advisory and exit is 0.
#
# DoD checks are kind-aware (backlog items[].kind, default "code"):
#   kind=code : design docs, test files, linter, Integrity review doc.
#   kind=docs : Integrity review doc only — design-doc and test-file
#               checks are skipped (docs PBIs legitimately have neither;
#               see skills/pbi-pipeline/SKILL.md § kind=docs).
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

BACKLOG_FILE=".scrum/backlog.json"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

info() {
  stderr_log "quality-gate" "INFO" "$1"
}

# Emit a single BLOCKED message and exit 2 — thin binding over validate.sh's
# hook_block (the mandated block path), passing the message as <what> with no
# separate remediation arg (the message carries its own remediation line).
block() {
  hook_block "quality-gate" "$1"
}

# ---------------------------------------------------------------------------
# PBI id extraction / lookup
# ---------------------------------------------------------------------------

# Scan a string for the first `[Pp][Bb][Ii]-[0-9]+` token and echo it verbatim
# (original casing). Echoes nothing when there is no match. Bash 3.2 =~ /
# BASH_REMATCH only — no external processes.
extract_pbi_id() {
  local text="$1"
  if [[ "$text" =~ ([Pp][Bb][Ii]-[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Get PBI data from backlog by id, matching case-insensitively (message /
# task prefixes use upper-case PBI-NNN; the backlog stores canonical
# lower-case pbi-NNN). Echoes the item JSON, or "{}" when not found.
get_pbi() {
  local pbi_id="$1"
  if [ ! -f "$BACKLOG_FILE" ]; then
    echo "{}"
    return
  fi
  jq --arg id "$pbi_id" \
    '.items[] | select((.id | ascii_downcase) == ($id | ascii_downcase))' \
    "$BACKLOG_FILE" 2>/dev/null || echo "{}"
}

# ---------------------------------------------------------------------------
# DoD checks
#
# Contract for every check_* function:
#   * success -> log an INFO line to stderr, print nothing to stdout, return 0.
#   * failure -> print a concise one-line reason to stdout, return 1.
# The caller captures stdout via command substitution and, on non-zero,
# collects the reason into the combined block message.
# ---------------------------------------------------------------------------

# kind=code: design documents are linked in the backlog and exist on disk.
check_design_docs() {
  local pbi_id="$1"
  local pbi_data="$2"

  local doc_count
  doc_count="$(echo "$pbi_data" | jq '.design_doc_paths | length' 2>/dev/null || echo "0")"

  if [ "$doc_count" = "0" ]; then
    printf 'no design document linked (DoD requires a design document)'
    return 1
  fi

  local missing_docs=""
  while IFS= read -r doc_path; do
    [ -z "$doc_path" ] && continue
    if [ ! -f "$doc_path" ]; then
      missing_docs="${missing_docs}${missing_docs:+, }${doc_path}"
    fi
  done <<EOF
$(echo "$pbi_data" | jq -r '.design_doc_paths[]? // empty' 2>/dev/null)
EOF

  if [ -n "$missing_docs" ]; then
    printf 'linked design document(s) not found on disk: %s' "$missing_docs"
    return 1
  fi

  info "PBI ${pbi_id}: Design documents present."
  return 0
}

# kind=code: at least one test file exists (heuristic scan of tests/).
check_tests_exist() {
  local pbi_id="$1"

  local test_count=0
  if [ -d "tests" ]; then
    test_count="$(find tests -type f \( -name "*.bats" -o -name "test_*.py" -o -name "*_test.*" -o -name "test_*.*" \) 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [ "$test_count" = "0" ]; then
    printf 'no test files found in tests/ (DoD requires unit tests)'
    return 1
  fi

  info "PBI ${pbi_id}: Found ${test_count} test file(s)."
  return 0
}

# Get files changed in the current branch (scoped to PBI work).
# Falls back to all files if git is unavailable or not in a repo.
get_changed_files() {
  local ext="$1"
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local base_branch
    base_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")"
    local merge_base
    merge_base="$(git merge-base "$base_branch" HEAD 2>/dev/null || echo "")"
    if [ -n "$merge_base" ]; then
      { git diff --name-only "$merge_base" HEAD -- "*.${ext}" 2>/dev/null; git diff --name-only -- "*.${ext}" 2>/dev/null; } | sort -u
    else
      git ls-files -- "*.${ext}" 2>/dev/null
    fi
  else
    find . -name "*.${ext}" -type f 2>/dev/null
  fi
}

# Run a linter against changed files of a given extension. Echoes a
# comma-separated list of files that failed (empty on pass).
# Returns 0 if the linter is unavailable (caller treats as no-op).
check_linter_on_extension() {
  local cmd="$1"
  local ext="$2"
  shift 2
  command -v "$cmd" >/dev/null 2>&1 || return 0

  local files failed=""
  files="$(get_changed_files "$ext")"
  [ -n "$files" ] || return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$f" ] || continue
    if ! "$cmd" "$@" "$f" >/dev/null 2>&1; then
      failed="${failed}${failed:+, }${f}"
    fi
  done <<EOF
$files
EOF
  if [ -n "$failed" ]; then
    printf '%s' "$failed"
    return 1
  fi
  return 0
}

# kind=code: changed shell/python files pass their linters (when available).
# No linter available, or no changed files of that type -> pass (no-op).
check_linter() {
  local pbi_id="$1"
  local linter_available=false
  local reasons="" failed

  if command -v shellcheck >/dev/null 2>&1; then
    linter_available=true
    if ! failed="$(check_linter_on_extension shellcheck sh)"; then
      reasons="${reasons}${reasons:+; }shellcheck issues in: ${failed}"
    fi
  fi

  if command -v ruff >/dev/null 2>&1; then
    linter_available=true
    if ! failed="$(check_linter_on_extension ruff py check --quiet)"; then
      reasons="${reasons}${reasons:+; }ruff issues in: ${failed}"
    fi
  fi

  if [ "$linter_available" = "false" ]; then
    info "PBI ${pbi_id}: No linter available (shellcheck, ruff). Skipping lint check."
    return 0
  fi

  if [ -n "$reasons" ]; then
    printf 'linter reported issues (%s)' "$reasons"
    return 1
  fi

  info "PBI ${pbi_id}: Linter checks passed."
  return 0
}

# Both kinds: the per-PBI Integrity review document is recorded and on disk.
check_review_doc() {
  local pbi_id="$1"
  local pbi_data="$2"

  local review_doc_path
  review_doc_path="$(echo "$pbi_data" | jq -r '.review_doc_path // empty' 2>/dev/null)"

  if [ -z "$review_doc_path" ] || [ "$review_doc_path" = "null" ]; then
    printf 'no Integrity review document recorded (review_doc_path unset)'
    return 1
  fi

  if [ ! -f "$review_doc_path" ]; then
    printf 'Integrity review document not found at %s' "$review_doc_path"
    return 1
  fi

  info "PBI ${pbi_id}: Integrity review document present."
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

hook_event="$(cat)"

task_name="$(printf '%s' "$hook_event" | jq -r '.task_name // empty' 2>/dev/null || echo "")"
task_id="$(printf '%s' "$hook_event" | jq -r '.task_id // empty' 2>/dev/null || echo "")"

raw_pbi_id="$(extract_pbi_id "$task_name")"
[ -n "$raw_pbi_id" ] || raw_pbi_id="$(extract_pbi_id "$task_id")"

# No PBI id anywhere -> unrelated task. Never block.
if [ -z "$raw_pbi_id" ]; then
  exit 0
fi

# Canonical forms: upper-case for display, lower-case for the (case-insensitive)
# backlog lookup.
pbi_display="$(printf '%s' "$raw_pbi_id" | tr '[:lower:]' '[:upper:]')"
pbi_lookup="$(printf '%s' "$raw_pbi_id" | tr '[:upper:]' '[:lower:]')"

# Backlog missing / unreadable -> advisory only, do not block.
if ! validate_json_file "$BACKLOG_FILE" "items" >/dev/null 2>&1; then
  info "PBI ${pbi_display}: backlog.json missing or unreadable — skipping DoD checks (advisory, not blocking)."
  exit 0
fi

pbi_data="$(get_pbi "$pbi_lookup")"

# PBI id not present in the backlog -> advisory only, do not block.
if [ "$pbi_data" = "{}" ] || [ -z "$pbi_data" ]; then
  info "PBI ${pbi_display}: not found in backlog — skipping DoD checks (advisory, not blocking)."
  exit 0
fi

kind="$(printf '%s' "$pbi_data" | jq -r '.kind // "code"' 2>/dev/null || echo "code")"
[ -n "$kind" ] && [ "$kind" != "null" ] || kind="code"

pbi_status="$(printf '%s' "$pbi_data" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")"
[ -n "$pbi_status" ] && [ "$pbi_status" != "null" ] || pbi_status="unknown"

info "Running kind=${kind} Definition of Done checks for PBI ${pbi_display} (status=${pbi_status})..."

# Collect failure reasons; each check prints its reason to stdout on failure.
failures=""
add_failure() {
  failures="${failures}${failures:+
  }- $1"
}

if [ "$kind" = "docs" ]; then
  # kind=docs DoD: design-doc and test-file checks do not apply.
  if ! reason="$(check_review_doc "$pbi_display" "$pbi_data")"; then
    add_failure "$reason"
  fi
else
  # kind=code DoD.
  if ! reason="$(check_design_docs "$pbi_display" "$pbi_data")"; then
    add_failure "$reason"
  fi
  if ! reason="$(check_tests_exist "$pbi_display")"; then
    add_failure "$reason"
  fi
  if ! reason="$(check_linter "$pbi_display")"; then
    add_failure "$reason"
  fi
  if ! reason="$(check_review_doc "$pbi_display" "$pbi_data")"; then
    add_failure "$reason"
  fi
fi

if [ -n "$failures" ]; then
  msg="PBI ${pbi_display} (kind=${kind}, status=${pbi_status}) failed Definition of Done checks:
  ${failures}"
  case "$pbi_status" in
    in_progress_merge|awaiting_cross_review|cross_review|done)
      # Merge-readiness+: DoD is claimable, so a failure hard-blocks.
      block "${msg}
  Resolve these before marking the PBI complete." ;;
  esac
  # Mid-/pre-pipeline status: DoD not yet claimable — advise, do not block.
  info "${msg}
  (advisory only — status=${pbi_status}; DoD is claimable at merge-readiness, not mid-pipeline.)"
  exit 0
fi

info "PBI ${pbi_display}: All DoD checks passed."
exit 0
