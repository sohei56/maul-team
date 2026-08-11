#!/usr/bin/env bash
# Generate a compact, derived Sprint-end index without replacing current readers.
set -euo pipefail

ROOT="$(pwd -P)"
case "$ROOT" in
  */stock-bo-monitoring-system|*/stock-bo-monitoring-system/*)
    printf '[generate-sprint-index] protected fixture/project root: %s\n' "$ROOT" >&2
    exit 0
    ;;
esac
HISTORY="$ROOT/.scrum/sprint-history.json"
OUTPUT="$ROOT/.scrum/sprint-index.md"
[ -f "$HISTORY" ] || { printf '[generate-sprint-index] missing .scrum/sprint-history.json\n' >&2; exit 66; }
jq -e '.sprints | type == "array"' "$HISTORY" >/dev/null

mkdir -p "$ROOT/.scrum"
tmp="${OUTPUT}.tmp.$$"
trap 'rm -f "$tmp"' EXIT
{
  printf '# Sprint index\n\n'
  printf '%s\n\n' "Derived from \`.scrum/sprint-history.json\`; authoritative evidence remains at its fixed paths."
  printf '| Sprint | Goal | Completed | PBIs |\n'
  printf '|---|---|---|---|\n'
  jq -r '.sprints[] | [
    .id,
    ((.goal // "") | gsub("[|\\n\\r]"; " ")),
    (.completed_at // "—"),
    (if has("pbis_completed") then ((.pbis_completed|tostring) + "/" + (.pbis_total|tostring)) else "—" end)
  ] | "| " + join(" | ") + " |"' "$HISTORY"
} > "$tmp"
mv "$tmp" "$OUTPUT"
trap - EXIT
printf '%s\n' '.scrum/sprint-index.md'
