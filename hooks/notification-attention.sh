#!/usr/bin/env bash
# notification-attention.sh — Notification / Stop / UserPromptSubmit hook
#
# Records "Claude is blocked on the human" into .scrum/attention.json so an
# external UI (the Mac app) can raise a banner without reading transcripts.
#
# Event roles:
#   Notification      — the harness says the user is needed. Writes
#                       attention.json with pending:true. `notification_type`
#                       is `permission_prompt` (a tool permission dialog went
#                       unanswered) or `idle_prompt` (the turn ended and no
#                       prompt arrived within the harness idle window).
#   Stop              — turn end. Records {prompt_id, last_assistant_message}
#                       to .scrum/attention-context.json. The idle_prompt
#                       Notification that may follow carries the same
#                       prompt_id but only a generic message, so this is how
#                       the banner recovers Claude's actual closing text.
#   UserPromptSubmit  — the human answered. Clears pending.
#
# Contract for .scrum/attention.json (consumed by the Mac app — do not
# change without changing the consumer):
#   {"pending": bool, "type": "permission_prompt"|"idle_prompt",
#    "message": str, "agent": str (optional), "updated_at": iso8601}
# A missing / unparseable file, or pending != true, all mean "nothing is
# waiting".
#
# This hook is best-effort telemetry: every path exits 0. That matters most
# on UserPromptSubmit, where a non-zero exit would feed hook output back into
# the session (exit 2 would block the user's prompt outright). For the same
# reason nothing here is ever written to stdout — UserPromptSubmit stdout is
# injected into the model's context.
#
# Writes go to .scrum/ relative to $PWD, matching dashboard-event.sh. In a PBI
# worktree .scrum is a symlink to the shared SSOT, so the file lands in the
# one place the UI watches.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/validate.sh
. "$HOOK_DIR/lib/validate.sh"

ATTENTION_FILE=".scrum/attention.json"
CONTEXT_FILE=".scrum/attention-context.json"
SESSION_MAP=".scrum/session-map.json"
# Banner text cap, in codepoints (jq slices by codepoint, so a multi-byte
# message is never cut mid-character the way `head -c` would).
MESSAGE_MAX_CHARS=200

PAYLOAD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a scalar field out of the hook payload. Empty on any failure.
payload_get() {
  printf '%s' "$PAYLOAD" | jq -r "$1 // empty" 2>/dev/null || true
}

# atomic_write <file> <json_text>
# tmp sibling + mv, so a reader polling the file never sees a partial write.
atomic_write() {
  local file="$1" content="$2" tmp
  ensure_scrum_dir
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# Map a session id to a teammate display name via .scrum/session-map.json
# (maintained by dashboard-event.sh). That map is keyed by the SHORTENED id,
# so try the raw id, the first UUID segment, and the first 8 chars — the three
# forms dashboard-event.sh::shorten_id can produce. Empty when unknown, which
# is a normal outcome: only sessions that emitted a named event are mapped.
resolve_agent() {
  local sid="$1"
  [ -n "$sid" ] || return 0
  [ -f "$SESSION_MAP" ] || return 0
  jq -r --arg sid "$sid" --arg seg "${sid%%-*}" --arg eight "${sid:0:8}" \
    '.[$sid] // .[$seg] // .[$eight] // empty' "$SESSION_MAP" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

# Stop → remember what this turn ended with, keyed by prompt_id.
record_context() {
  local json
  json="$(printf '%s' "$PAYLOAD" | jq -c \
    --arg ts "$(get_timestamp)" \
    --argjson max "$MESSAGE_MAX_CHARS" '
    {
      prompt_id: (.prompt_id // ""),
      last_assistant_message: (
        (.last_assistant_message // "")
        | if (. | length) > $max then (.[0:$max] + "…") else . end
      ),
      recorded_at: $ts
    }' 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  atomic_write "$CONTEXT_FILE" "$json"
}

# Notification → raise the banner.
record_attention() {
  local ntype msg prompt_id sid agent ctx_prompt_id ctx_msg json

  ntype="$(payload_get '.notification_type')"
  case "$ntype" in
    permission_prompt|idle_prompt) ;;
    # Unknown / absent type: every Notification means the human is needed, and
    # the consumer only branches on the two known values. Degrade to the
    # generic one rather than emit a type nothing downstream understands.
    *) ntype="idle_prompt" ;;
  esac

  msg="$(payload_get '.message')"

  # An idle_prompt's own message is generic ("Claude is waiting for your
  # input"). When the preceding Stop was for the same prompt_id, its closing
  # message is what the user actually needs to see.
  if [ "$ntype" = "idle_prompt" ]; then
    prompt_id="$(payload_get '.prompt_id')"
    if [ -n "$prompt_id" ] && [ -f "$CONTEXT_FILE" ]; then
      ctx_prompt_id="$(jq -r '.prompt_id // empty' "$CONTEXT_FILE" 2>/dev/null || true)"
      if [ "$ctx_prompt_id" = "$prompt_id" ]; then
        ctx_msg="$(jq -r '.last_assistant_message // empty' "$CONTEXT_FILE" 2>/dev/null || true)"
        [ -n "$ctx_msg" ] && msg="$ctx_msg"
      fi
    fi
  fi

  [ -n "$msg" ] || msg="Claude is waiting for your input"

  sid="$(payload_get '.session_id')"
  agent="$(resolve_agent "$sid")"

  json="$(jq -nc \
    --arg type "$ntype" \
    --arg msg "$msg" \
    --arg agent "$agent" \
    --arg ts "$(get_timestamp)" \
    --argjson max "$MESSAGE_MAX_CHARS" '
    {
      pending: true,
      type: $type,
      message: ($msg | if (. | length) > $max then (.[0:$max] + "…") else . end)
    }
    + (if $agent == "" then {} else {agent: $agent} end)
    + {updated_at: $ts}' 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  atomic_write "$ATTENTION_FILE" "$json"
}

# UserPromptSubmit → the human replied; lower the banner. No file means no
# banner was ever raised, so there is nothing to clear.
clear_attention() {
  local ts json
  [ -f "$ATTENTION_FILE" ] || return 0
  ts="$(get_timestamp)"
  json="$(jq -c --arg ts "$ts" '.pending = false | .updated_at = $ts' \
    "$ATTENTION_FILE" 2>/dev/null)" || json=""
  if [ -z "$json" ]; then
    # File is corrupt or not an object. Replace it with a minimal cleared
    # record rather than leave a possibly-stale pending:true behind.
    json="$(jq -nc --arg ts "$ts" '{pending: false, updated_at: $ts}' 2>/dev/null)" || return 0
  fi
  atomic_write "$ATTENTION_FILE" "$json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  command -v jq >/dev/null 2>&1 || return 0

  # `-t 0` guards a manual TTY invocation from blocking on cat, the same
  # defensive pattern stop-dispatch.sh / completion-gate.sh use.
  if [ ! -t 0 ]; then
    PAYLOAD="$(cat 2>/dev/null || true)"
  fi
  [ -n "$PAYLOAD" ] || return 0
  printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1 || return 0

  case "$(payload_get '.hook_event_name')" in
    Stop)             record_context ;;
    Notification)     record_attention ;;
    UserPromptSubmit) clear_attention ;;
  esac
}

# Invoked under `|| true` so a mid-flight failure can never surface as a
# non-zero hook exit (see the header note on UserPromptSubmit).
main || true
exit 0
