#!/usr/bin/env bash
# status-gate.sh — PreToolUse hook
# Gates tools by current Scrum project phase and enforces design catalog
# governance. Reads .scrum/state.json for the current project phase,
# docs/design/catalog.md for document type validation,
# docs/design/catalog-config.json for enablement state, and the hook event
# JSON (Claude Code PreToolUse payload) from stdin.
# Outputs a permissionDecision JSON object.
#
# Note: this hook reads the project-level Scrum phase from .scrum/state.json
# (which retains its `phase` field for the Sprint state machine:
# sprint_planning, pbi_pipeline_active, review, sprint_review, ...). It is
# unrelated to the per-PBI 12-value status enum stored in
# .scrum/backlog.json.items[].status.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

STATE_FILE=".scrum/state.json"
CATALOG_FILE="docs/design/catalog.md"
CONFIG_FILE="docs/design/catalog-config.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

allow() {
  jq -n '{"decision": "allow"}'
  exit 0
}

deny() {
  local reason="$1"
  log_hook "status-gate" "WARN" "Denied: $reason"
  jq -n --arg r "${HOOK_NOTIFICATION_PREFIX} ${reason}" '{"decision": "deny", "reason": $r}'
  exit 0
}

# Check whether a file path targets source code (not metadata / config).
# Source files live outside .scrum/, docs/, agents/, skills/,
# hooks/, scripts/, dashboard/, tests/, and common dot-directories.
is_source_file() {
  local path="$1"
  case "$path" in
    .scrum/*|docs/*|agents/*|skills/*|hooks/*|scripts/*|dashboard/*|tests/*) return 1 ;;
    .git/*|.claude/*|.github/*) return 1 ;;
    *.md|*.json|*.yaml|*.yml|*.toml|*.cfg|*.ini|*.editorconfig|LICENSE*|.gitignore|.gitmodules|.shellcheckrc) return 1 ;;
    *) return 0 ;;
  esac
}

# Check whether a target path is under docs/design/specs/
is_design_spec_path() {
  local path="$1"
  case "$path" in
    docs/design/specs/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract the spec ID (e.g. "S-001") from the basename of a spec path.
# Echoes empty string if the basename does not match the spec ID pattern.
# Spec files follow: docs/design/specs/{category}/{id}-{slug}.md
extract_spec_id() {
  local filename spec_id
  filename="$(basename "$1")"
  spec_id="$(echo "$filename" | sed -E 's/^([A-Z]+-[0-9]+)-.*/\1/')"
  if [ -z "$spec_id" ] || [ "$spec_id" = "$filename" ]; then
    echo ""
    return
  fi
  echo "$spec_id"
}

# Check whether a spec ID exists in catalog.md (any table row).
has_catalog_entry() {
  local spec_id
  spec_id="$(extract_spec_id "$1")"
  [ -z "$spec_id" ] && return 1
  [ -f "$CATALOG_FILE" ] || return 1
  grep -qE "\\|\\s*${spec_id}\\s*\\|" "$CATALOG_FILE" 2>/dev/null
}

# Check whether a spec ID is enabled in catalog-config.json.
is_enabled_in_config() {
  local spec_id
  spec_id="$(extract_spec_id "$1")"
  [ -z "$spec_id" ] && return 1
  [ -f "$CONFIG_FILE" ] || return 1
  jq -e --arg id "$spec_id" '.enabled | index($id) != null' "$CONFIG_FILE" >/dev/null 2>&1
}

# Extract target file path from tool_input JSON.
# For Write/Edit/MultiEdit tools, the path is in "file_path".
# For Bash tool, we cannot reliably parse — return empty.
get_target_path() {
  local tool_name="$1"
  local tool_input="$2"

  case "$tool_name" in
    Write|Edit|MultiEdit)
      echo "$tool_input" | jq -r '.file_path // empty' 2>/dev/null
      ;;
    *)
      echo ""
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Read hook event JSON from stdin
hook_event="$(cat)"

tool_name="$(echo "$hook_event" | jq -r '.tool_name // empty')"

# Fast path: only mutating file tools are gated. All others→allow immediately.
# This avoids reading state.json, catalog.md, catalog-config.json on every
# Read/Grep/Glob/Bash call — the biggest hook overhead source.
if [ "$tool_name" != "Write" ] && [ "$tool_name" != "Edit" ] && [ "$tool_name" != "MultiEdit" ]; then
  allow
fi

tool_input="$(echo "$hook_event" | jq -c '.tool_input // {}')"

# If state file does not exist, allow everything (project not initialized)
if [ ! -f "$STATE_FILE" ]; then
  allow
fi

# Read phase from state file — allow if file is unreadable (race condition
# with concurrent writes, or file is being created for the first time)
phase="$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null)" || allow

# Get the target file path (if determinable)
target_path="$(get_target_path "$tool_name" "$tool_input")"

# Normalize target_path to a root-anchored relative form: strip $PWD/ (or a
# leading "./"), collapse /./, and strip a leading .scrum/worktrees/<pbi>/
# prefix so worktree-relative paths match the same root-anchored globs
# (docs/design/specs/*, source-file gating). See lib/validate.sh.
if [ -n "$target_path" ]; then
  target_path="$(project_rel_path "$target_path")"
fi

# ---------------------------------------------------------------------------
# Phase gating rules
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# From here: only Write/Edit/MultiEdit tools reach this code (fast path above
# short-circuits everything else, including Bash). The fast-path guarantees
# tool_name ∈ {Write,Edit,MultiEdit}, so `tool_input.file_path` is always
# present and `get_target_path` returns it verbatim. An empty target_path at
# this point would mean a malformed payload — treat as defensive allow to
# avoid blocking legitimate edits on a payload glitch (no path = no scope
# to gate against).
# ---------------------------------------------------------------------------
if [ -z "$target_path" ]; then
  allow
fi

# ---------------------------------------------------------------------------
# pbi_pipeline_active phase: agent-specific path gating
# ---------------------------------------------------------------------------
if [ "$phase" = "pbi_pipeline_active" ]; then
  agent_name="$(echo "$hook_event" | jq -r '.agent_name // empty')"

  case "$agent_name" in
    pbi-designer)
      # catalog.md is always read-only — fall through to the catalog.md rule below
      case "$target_path" in
        docs/design/catalog.md) ;;
        *)
          # pbi-designer may write anywhere else (specs, .scrum/pbi/, src/, etc.)
          allow
          ;;
      esac
      ;;
    pbi-implementer|pbi-ut-author)
      # Deny writes to docs/design/specs/; allow everything else
      if is_design_spec_path "$target_path"; then
        deny "pbi_pipeline_active phase: $agent_name cannot write to docs/design/specs/. Only pbi-designer may write specs."
      fi
      allow
      ;;
    codex-design-reviewer|codex-impl-reviewer|codex-ut-reviewer)
      # Reviewers may only write to .scrum/pbi/*
      case "$target_path" in
        .scrum/pbi/*) allow ;;
        *) deny "pbi_pipeline_active phase: $agent_name may only write to .scrum/pbi/." ;;
      esac
      ;;
    *)
      # Unknown agents fall through to existing gating rules below
      ;;
  esac
fi

# Source code gating: only review and pbi_pipeline_active phases allow source edits
if is_source_file "$target_path"; then
  case "$phase" in
    review|pbi_pipeline_active) ;;
    *) deny "$phase phase: source code changes not allowed. Only permitted during pbi_pipeline_active/review." ;;
  esac
fi

# Catalog governance: catalog.md is read-only
case "$target_path" in
  docs/design/catalog.md)
    deny "catalog.md is read-only. Update docs/design/catalog-config.json instead." ;;
esac

# Design spec governance: require catalog entry + enabled config
if is_design_spec_path "$target_path"; then
  if ! has_catalog_entry "$target_path"; then
    deny "Cannot write '$target_path' — no matching entry in docs/design/catalog.md."
  fi
  if ! is_enabled_in_config "$target_path"; then
    deny "Cannot write '$target_path' — not enabled in docs/design/catalog-config.json."
  fi
fi

# All specific gating handled above — allow everything else
allow
