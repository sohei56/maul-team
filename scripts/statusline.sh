#!/usr/bin/env bash
# statusline.sh — Claude Code status line (compact 3-line view)
# Reads session JSON from stdin and .scrum/ state files from disk.
# Outputs 3 ANSI-formatted lines for the status line display.
set -euo pipefail

STATE_FILE=".scrum/state.json"
BACKLOG_FILE=".scrum/backlog.json"
SPRINT_FILE=".scrum/sprint.json"

# --- Line 1: Sprint overview ---
if [ -f "$STATE_FILE" ]; then
  phase="$(jq -r '.phase // "unknown"' "$STATE_FILE")"
  sprint_id="$(jq -r '.current_sprint_id // empty' "$STATE_FILE")"
else
  phase="no project"
  sprint_id=""
fi

if [ -f "$SPRINT_FILE" ] && [ -n "$sprint_id" ] && [ "$sprint_id" != "null" ]; then
  sprint_num="${sprint_id#sprint-}"
  sprint_goal="$(jq -r '.goal // "No goal"' "$SPRINT_FILE" | cut -c1-40)"

  # Count completed PBIs. OD-4 single-source: derive Sprint membership from
  # `backlog.items where sprint_id == current_sprint`; `sprint.pbi_ids` is
  # gone.
  if [ -f "$BACKLOG_FILE" ]; then
    total="$(jq -r --arg sid "$sprint_id" \
      '[.items[] | select(.sprint_id == $sid)] | length' \
      "$BACKLOG_FILE" 2>/dev/null || echo "0")"
    done_count="$(jq -r --arg sid "$sprint_id" \
      '[.items[] | select(.sprint_id == $sid and .status == "done")] | length' \
      "$BACKLOG_FILE" 2>/dev/null || echo "0")"
  else
    total=0
    done_count=0
  fi

  echo "Sprint $sprint_num \"$sprint_goal\" | Phase: $phase | $done_count/$total PBIs done"
else
  echo "No active Sprint | Phase: $phase"
fi

# --- Line 2: Backlog summary ---
if [ -f "$BACKLOG_FILE" ]; then
  total_items="$(jq '.items | length' "$BACKLOG_FILE")"
  refined="$(jq '[.items[] | select(.status == "refined")] | length' "$BACKLOG_FILE")"
  draft="$(jq '[.items[] | select(.status == "draft")] | length' "$BACKLOG_FILE")"
  echo "Backlog: $total_items items ($refined refined, $draft draft)"
else
  echo "Backlog: not created"
fi

# --- Line 3: Agent activity ---
if [ -f "$SPRINT_FILE" ]; then
  # Build agent status string
  agent_parts="SM:active"

  # Read developer statuses
  dev_count="$(jq '.developers | length' "$SPRINT_FILE" 2>/dev/null || echo "0")"
  if [ "$dev_count" -gt 0 ]; then
    for i in $(seq 0 $((dev_count - 1))); do
      dev_id="$(jq -r ".developers[$i].id" "$SPRINT_FILE")"
      dev_status="$(jq -r ".developers[$i].status" "$SPRINT_FILE")"
      dev_num="Dev${dev_id#dev-}"

      # Get first implementation PBI for context
      impl_pbi="$(jq -r ".developers[$i].assigned_work.implement[0] // empty" "$SPRINT_FILE")"
      if [ -n "$impl_pbi" ] && [ "$dev_status" = "active" ]; then
        pbi_short="PBI-${impl_pbi#pbi-}"
        agent_parts="$agent_parts $dev_num:$dev_status($pbi_short)"
      else
        agent_parts="$agent_parts $dev_num:$dev_status"
      fi
    done
  fi

  echo "Agents: $agent_parts"
else
  echo "Agents: SM:active"
fi
