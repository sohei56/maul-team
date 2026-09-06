#!/usr/bin/env bash
# statusline.sh — Claude Code status line for the current Scrum phase.
# Claude Code supplies session JSON on stdin; Scrum progress is read from the
# small, local .scrum JSON files and emitted as a compact multi-line status.
set -euo pipefail

STATE_FILE=".scrum/state.json"
BACKLOG_FILE=".scrum/backlog.json"
SPRINT_FILE=".scrum/sprint.json"
CONFIG_FILE=".scrum/config.json"

# A missing jq must not break Claude Code's status line. There is no reliable
# way to interpret the Scrum JSON without it, so retain the useful shape and
# make the unavailable data explicit.
if ! command -v jq >/dev/null 2>&1; then
  echo "No active Sprint | Phase: unavailable (jq missing)"
  echo "Backlog: unavailable (jq missing)"
  echo "Scrum Master | phase:unavailable"
  exit 0
fi

valid_json() {
  # All Scrum state files have an object at their top level. Treat other
  # syntactically-valid JSON values as invalid data before field access; this
  # also prevents jq type errors from escaping under set -e.
  [ -f "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

phase_label() {
  case "$1" in
    new) echo "New" ;;
    requirements_sprint) echo "Requirement Definition" ;;
    backlog_created) echo "Backlog Created" ;;
    sprint_planning) echo "Sprint Planning" ;;
    pbi_pipeline_active) echo "PBI Development" ;;
    review) echo "Cross Review" ;;
    sprint_review) echo "Sprint Review" ;;
    retrospective) echo "Retrospective" ;;
    integration_sprint) echo "Integration Tests" ;;
    uat_release) echo "UAT & Release" ;;
    complete) echo "Complete" ;;
    *) echo "$1" ;;
  esac
}

phase="unknown"
sprint_id=""
if valid_json "$STATE_FILE"; then
  phase="$(jq -r 'if (.phase | type) == "string" then .phase else "unknown" end' "$STATE_FILE")"
  sprint_id="$(jq -r 'if (.current_sprint_id | type) == "string" then .current_sprint_id else empty end' "$STATE_FILE")"
elif [ ! -f "$STATE_FILE" ]; then
  phase="no project"
fi
phase_ui="$(phase_label "$phase")"

# --- Sprint overview ---
if valid_json "$SPRINT_FILE" && [ -n "$sprint_id" ]; then
  sprint_num="${sprint_id#sprint-}"
  sprint_goal="$(jq -r '
    if (.goal | type) == "string" and (.goal | length) > 0
    then .goal else "No goal" end
  ' "$SPRINT_FILE" | tr '\n\t' '  ' | cut -c1-40)"

  total=0
  done_count=0
  if valid_json "$BACKLOG_FILE"; then
    total="$(jq -r --arg sid "$sprint_id" '
      [(.items // [])[]?
       | select(type == "object" and .sprint_id == $sid and .status != "cancelled")]
      | length
    ' "$BACKLOG_FILE" 2>/dev/null || echo 0)"
    done_count="$(jq -r --arg sid "$sprint_id" '
      [(.items // [])[]?
       | select(type == "object" and .sprint_id == $sid and .status == "done")]
      | length
    ' "$BACKLOG_FILE" 2>/dev/null || echo 0)"
  fi

  echo "Sprint $sprint_num \"$sprint_goal\" | Phase: $phase_ui [$phase] | $done_count/$total PBIs done"
else
  echo "No active Sprint | Phase: $phase_ui [$phase]"
fi

# --- Backlog summary ---
if valid_json "$BACKLOG_FILE"; then
  backlog_summary="$(jq -r '
    (.items // []) as $items
    | if ($items | type) != "array" then "invalid"
      else "\($items | length) items (\([$items[] | select(type == "object" and .status == "refined")] | length) refined, \([$items[] | select(type == "object" and .status == "draft")] | length) draft)"
      end
  ' "$BACKLOG_FILE" 2>/dev/null || echo "invalid")"
  echo "Backlog: $backlog_summary"
elif [ -f "$BACKLOG_FILE" ]; then
  echo "Backlog: unavailable (invalid JSON)"
else
  echo "Backlog: not created"
fi

# --- Phase-specific agent progress ---
if [ "$phase" = "pbi_pipeline_active" ]; then
  if valid_json "$SPRINT_FILE"; then
    dev_count="$(jq -r 'if (.developers | type) == "array" then (.developers | length) else 0 end' "$SPRINT_FILE")"
  else
    dev_count=0
  fi

  if [ "$dev_count" -eq 0 ]; then
    echo "Developers | none assigned"
  elif valid_json "$BACKLOG_FILE"; then
    # backlog.json is the sole source of truth for PBI progress. Include both
    # current_pbi and the full allocation, because a Developer can own more
    # than one PBI during a Sprint.
    jq -r --slurpfile backlog "$BACKLOG_FILE" '
      def string_array:
        if type == "array" then map(select(type == "string")) else [] end;
      def backlog_items:
        (($backlog[0].items // [])
         | if type == "array" then . else [] end);
      def pbi_status($pbi):
        ([backlog_items[]
          | select(type == "object" and .id == $pbi)
          | .status | select(type == "string")][0] // "unknown");
      (.developers // [])[]
      | . as $dev
      | (($dev.assigned_work.implement // []) | string_array) as $assigned
      | (if ($dev.current_pbi | type) == "string" then $dev.current_pbi else null end) as $current
      | ([$current] + $assigned | map(select(. != null)) | unique) as $pbis
      | "Developer \(if ($dev.id | type) == "string" then $dev.id else "unknown" end)"
        + " | status:\(if ($dev.status | type) == "string" then $dev.status else "unknown" end)"
        + " | current:\($current // "none")"
        + " | assigned:\(if ($assigned | length) > 0 then ($assigned | join(",")) else "none" end)"
        + " | progress:\(if ($pbis | length) > 0 then ($pbis | map(. + "=" + pbi_status(.)) | join(",")) else "unassigned" end)"
    ' "$SPRINT_FILE" 2>/dev/null || echo "Developers | unavailable (invalid data)"
  else
    jq -r '
      def string_array:
        if type == "array" then map(select(type == "string")) else [] end;
      (.developers // [])[]
      | . as $dev
      | (($dev.assigned_work.implement // []) | string_array) as $assigned
      | (if ($dev.current_pbi | type) == "string" then $dev.current_pbi else null end) as $current
      | ([$current] + $assigned | map(select(. != null)) | unique) as $pbis
      | "Developer \(if ($dev.id | type) == "string" then $dev.id else "unknown" end)"
        + " | status:\(if ($dev.status | type) == "string" then $dev.status else "unknown" end)"
        + " | current:\($current // "none")"
        + " | assigned:\(if ($assigned | length) > 0 then ($assigned | join(",")) else "none" end)"
        + " | progress:\(if ($pbis | length) > 0 then ($pbis | map(. + "=unknown") | join(",")) else "unassigned" end)"
    ' "$SPRINT_FILE" 2>/dev/null || echo "Developers | unavailable (invalid data)"
  fi
else
  echo "Scrum Master | phase:$phase_ui [$phase]"

  po_mode="human"
  if valid_json "$CONFIG_FILE"; then
    po_mode="$(jq -r 'if .po_mode == "agent" then "agent" else "human" end' "$CONFIG_FILE")"
  fi
  if [ "$po_mode" = "agent" ]; then
    # There is no durable per-PO lifecycle file. The project phase is the
    # available progress state for this persistent orchestration role.
    echo "Product Owner | mode:agent | phase:$phase_ui [$phase]"
  fi
fi
