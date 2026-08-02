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
# shellcheck source=lib/dashboard.sh
. "$HOOK_DIR/lib/dashboard.sh"   # resolve_agent_display_name (session-map lookup)

ATTENTION_FILE=".scrum/attention.json"
CONTEXT_FILE=".scrum/attention-context.json"
# Banner text cap, in codepoints (jq slices by codepoint, so a multi-byte
# message is never cut mid-character the way `head -c` would).
MESSAGE_MAX_CHARS=200

PAYLOAD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# attention_atomic_write <file> <json_text>
# tmp sibling + mv, so a reader polling the file never sees a partial write.
# Named apart from scripts/scrum/lib/atomic.sh::atomic_write, which shares
# nothing with it beyond the idea (that one takes a jq expression, a lock and
# a schema). The two are never sourced together, but the bare name invited
# the reader to assume they were the same helper.
attention_atomic_write() {
  local file="$1" content="$2" tmp
  ensure_scrum_dir
  tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
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
  attention_atomic_write "$CONTEXT_FILE" "$json"
}

# Notification → raise the banner.
record_attention() {
  local ntype msg prompt_id sid agent ctx_prompt_id ctx_msg json

  ntype="$(payload_get "$PAYLOAD" '.notification_type')"
  case "$ntype" in
    permission_prompt|idle_prompt) ;;
    # Unknown / absent type: every Notification means the human is needed, and
    # the consumer only branches on the two known values. Degrade to the
    # generic one rather than emit a type nothing downstream understands.
    *) ntype="idle_prompt" ;;
  esac

  msg="$(payload_get "$PAYLOAD" '.message')"

  # An idle_prompt's own message is generic ("Claude is waiting for your
  # input"). When the preceding Stop was for the same prompt_id, its closing
  # message is what the user actually needs to see.
  if [ "$ntype" = "idle_prompt" ]; then
    prompt_id="$(payload_get "$PAYLOAD" '.prompt_id')"
    if [ -n "$prompt_id" ] && [ -f "$CONTEXT_FILE" ]; then
      ctx_prompt_id="$(jq -r '.prompt_id // empty' "$CONTEXT_FILE" 2>/dev/null || true)"
      if [ "$ctx_prompt_id" = "$prompt_id" ]; then
        ctx_msg="$(jq -r '.last_assistant_message // empty' "$CONTEXT_FILE" 2>/dev/null || true)"
        [ -n "$ctx_msg" ] && msg="$ctx_msg"
      fi
    fi
  fi

  [ -n "$msg" ] || msg="Claude is waiting for your input"

  sid="$(payload_get "$PAYLOAD" '.session_id')"
  # Empty when the session was never named — the banner then omits `agent`.
  agent="$(resolve_agent_display_name "$sid")"

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
  attention_atomic_write "$ATTENTION_FILE" "$json"
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
  attention_atomic_write "$ATTENTION_FILE" "$json"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  command -v jq >/dev/null 2>&1 || return 0

  PAYLOAD="$(read_hook_payload)"
  [ -n "$PAYLOAD" ] || return 0
  printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1 || return 0

  case "$(payload_get "$PAYLOAD" '.hook_event_name')" in
    Stop)             record_context ;;
    Notification)     record_attention ;;
    UserPromptSubmit) clear_attention ;;
  esac
}

# Invoked under `|| true` so a mid-flight failure can never surface as a
# non-zero hook exit (see the header note on UserPromptSubmit).
main || true
exit 0
