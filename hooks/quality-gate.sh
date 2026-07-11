#!/usr/bin/env bash
# quality-gate.sh — TaskCompleted hook
# Enforces the Definition of Done (DoD) for completed PBIs.
# Reads hook event JSON from stdin.  Checks PBI status, design docs,
# test files, linter availability, and review docs.
# Outputs exit code 0 (pass) with warnings to stderr — does NOT hard-block.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

BACKLOG_FILE=".scrum/backlog.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

warn() {
  stderr_log "quality-gate" "WARNING" "$1"
}

info() {
  stderr_log "quality-gate" "INFO" "$1"
}

# Extract PBI ID from hook event.  The TaskCompleted payload may contain
# a pbi_id or we attempt to infer from the task output.
get_pbi_id_from_event() {
  local event="$1"
  # Try direct pbi_id field
  local pbi_id
  pbi_id="$(echo "$event" | jq -r '.pbi_id // empty' 2>/dev/null)"
  if [ -n "$pbi_id" ]; then
    echo "$pbi_id"
    return
  fi

  # Try extracting from task output or session context
  pbi_id="$(echo "$event" | jq -r '.task_output.pbi_id // empty' 2>/dev/null)"
  if [ -n "$pbi_id" ]; then
    echo "$pbi_id"
    return
  fi

  echo ""
}

# Get PBI data from backlog by ID
get_pbi() {
  local pbi_id="$1"
  if [ ! -f "$BACKLOG_FILE" ]; then
    echo "{}"
    return
  fi
  jq --arg id "$pbi_id" '.items[] | select(.id == $id)' "$BACKLOG_FILE" 2>/dev/null || echo "{}"
}

# Check if design documents exist for a PBI
check_design_docs() {
  local pbi_id="$1"
  local pbi_data="$2"

  local doc_count
  doc_count="$(echo "$pbi_data" | jq '.design_doc_paths | length' 2>/dev/null || echo "0")"

  if [ "$doc_count" = "0" ]; then
    warn "PBI ${pbi_id}: No design documents linked. DoD requires a design document for each PBI."
    return 1
  fi

  # Check that each linked design doc file actually exists
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
    warn "PBI ${pbi_id}: Linked design documents not found on disk: ${missing_docs}"
    return 1
  fi

  info "PBI ${pbi_id}: Design documents present."
  return 0
}

# Check if test files exist (heuristic: look for test files in tests/)
check_tests_exist() {
  local pbi_id="$1"

  # Look for any test files in the tests/ directory
  local test_count=0
  if [ -d "tests" ]; then
    # Count test files (bats for shell, test_*.py for python, *_test.* generic)
    test_count="$(find tests -type f \( -name "*.bats" -o -name "test_*.py" -o -name "*_test.*" -o -name "test_*.*" \) 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [ "$test_count" = "0" ]; then
    warn "PBI ${pbi_id}: No test files found in tests/ directory. DoD requires unit tests."
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
    # Files changed vs default branch (main/master), plus any uncommitted changes
    local base_branch
    base_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")"
    local merge_base
    merge_base="$(git merge-base "$base_branch" HEAD 2>/dev/null || echo "")"
    if [ -n "$merge_base" ]; then
      { git diff --name-only "$merge_base" HEAD -- "*.${ext}" 2>/dev/null; git diff --name-only -- "*.${ext}" 2>/dev/null; } | sort -u
    else
      # No merge base (e.g., initial branch) — fall back to all tracked files
      git ls-files -- "*.${ext}" 2>/dev/null
    fi
  else
    # Not a git repo — fall back to find
    find . -name "*.${ext}" -type f 2>/dev/null
  fi
}

# Run a linter against changed files of a given extension. Echoes a
# space-separated list of files that failed the linter (empty on pass).
# Usage: check_linter_on_extension <linter_cmd> <ext> <linter_args...>
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

# Check if code passes linter (if linter tools are available)
# Scopes checks to files changed in the current branch, not all project files.
check_linter() {
  local pbi_id="$1"
  local linter_available=false
  local linter_passed=true
  local failed

  if command -v shellcheck >/dev/null 2>&1; then
    linter_available=true
    if ! failed="$(check_linter_on_extension shellcheck sh)"; then
      warn "PBI ${pbi_id}: shellcheck reported issues in: ${failed}"
      linter_passed=false
    fi
  fi

  if command -v ruff >/dev/null 2>&1; then
    linter_available=true
    if ! failed="$(check_linter_on_extension ruff py check --quiet)"; then
      warn "PBI ${pbi_id}: ruff reported issues in: ${failed}"
      linter_passed=false
    fi
  fi

  if [ "$linter_available" = "false" ]; then
    warn "PBI ${pbi_id}: No linter available (shellcheck, ruff). Skipping lint check."
    return 0
  fi

  if [ "$linter_passed" = "true" ]; then
    info "PBI ${pbi_id}: Linter checks passed."
    return 0
  fi

  return 1
}

# Check if the per-PBI Integrity review document exists for the PBI
check_review_doc() {
  local pbi_id="$1"
  local pbi_data="$2"

  local review_doc_path
  review_doc_path="$(echo "$pbi_data" | jq -r '.review_doc_path // empty' 2>/dev/null)"

  if [ -z "$review_doc_path" ] || [ "$review_doc_path" = "null" ]; then
    warn "PBI ${pbi_id}: No review document path set. DoD requires the per-PBI Integrity review."
    return 1
  fi

  if [ ! -f "$review_doc_path" ]; then
    warn "PBI ${pbi_id}: Review document not found at '${review_doc_path}'."
    return 1
  fi

  info "PBI ${pbi_id}: Integrity review document present."
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Read hook event JSON from stdin
hook_event="$(cat)"

pbi_id="$(get_pbi_id_from_event "$hook_event")"

if [ -z "$pbi_id" ]; then
  info "No PBI ID found in hook event. Skipping DoD checks."
  exit 0
fi

if ! validate_json_file "$BACKLOG_FILE" "items"; then
  warn "Cannot verify DoD for PBI ${pbi_id} — backlog.json missing or invalid."
  exit 0
fi

pbi_data="$(get_pbi "$pbi_id")"

if [ "$pbi_data" = "{}" ] || [ -z "$pbi_data" ]; then
  warn "PBI ${pbi_id} not found in backlog. Skipping DoD checks."
  exit 0
fi

info "Running Definition of Done checks for PBI ${pbi_id}..."

warning_count=0

# DoD Check 1: Design document exists
if ! check_design_docs "$pbi_id" "$pbi_data"; then
  warning_count=$((warning_count + 1))
fi

# DoD Check 2: Implementation follows design — cannot verify programmatically, skip
# (Noted for manual review)

# DoD Check 3: Unit tests exist
if ! check_tests_exist "$pbi_id"; then
  warning_count=$((warning_count + 1))
fi

# DoD Check 4: Code passes linter
if ! check_linter "$pbi_id"; then
  warning_count=$((warning_count + 1))
fi

# DoD Check 5: Per-PBI Integrity review completed
if ! check_review_doc "$pbi_id" "$pbi_data"; then
  warning_count=$((warning_count + 1))
fi

if [ "$warning_count" -gt 0 ]; then
  warn "PBI ${pbi_id}: ${warning_count} DoD warning(s) found. Review above warnings before marking as complete."
else
  info "PBI ${pbi_id}: All DoD checks passed."
fi

# Always exit 0 — DoD warnings are advisory, not blocking
exit 0
