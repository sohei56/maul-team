#!/usr/bin/env bash
# Remove or bound only artifacts classified Remove in docs/artifact-policy.md.
# Dry-run is the default. Usage: cleanup-artifacts.sh [--apply]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/activity.sh
source "$HERE/lib/activity.sh"

MODE=dry-run
case "${1:-}" in
  "") ;;
  --apply) MODE=apply ;;
  *) printf 'usage: cleanup-artifacts.sh [--apply]\n' >&2; exit 64 ;;
esac

ROOT="$(pwd -P)"
SCRUM="$ROOT/.scrum"
MAX_LOG_BYTES="${SCRUM_ARTIFACT_MAX_LOG_BYTES:-1048576}"
MIN_LOCK_AGE="${SCRUM_ARTIFACT_MIN_LOCK_AGE_SEC:-3600}"

case "$ROOT" in
  */stock-bo-monitoring-system|*/stock-bo-monitoring-system/*)
    printf '[cleanup-artifacts] protected fixture/project root: %s\n' "$ROOT" >&2
    exit 0
    ;;
esac
[ -d "$SCRUM" ] || exit 0
printf '%s' "$MAX_LOG_BYTES" | grep -Eq '^[1-9][0-9]*$' || { printf 'invalid SCRUM_ARTIFACT_MAX_LOG_BYTES\n' >&2; exit 64; }
printf '%s' "$MIN_LOCK_AGE" | grep -Eq '^[0-9]+$' || { printf 'invalid SCRUM_ARTIFACT_MIN_LOCK_AGE_SEC\n' >&2; exit 64; }

remove_path() {
  local path="$1"
  case "$path" in
    */stock-bo-monitoring-system/.scrum|*/stock-bo-monitoring-system/.scrum/*)
      printf '[cleanup-artifacts] protected: %s\n' "$path" >&2; return 0 ;;
  esac
  if [ "$MODE" = apply ]; then rm -rf -- "$path"; fi
  printf '%s\t%s\n' "$MODE" "${path#"$ROOT/"}"
}

# Return 0 only when the process is confirmed absent, 1 when it exists, and 2
# when its state cannot be verified. `kill -0` may fail with EPERM for a live
# process, so its failure alone is never sufficient evidence for deletion.
process_confirmed_dead() {
  local pid="$1" kill_output kill_status ps_output ps_status
  kill_status=0
  kill_output="$(LC_ALL=C kill -0 "$pid" 2>&1)" || kill_status=$?
  [ "$kill_status" -ne 0 ] || return 1
  # Bash on macOS/Linux reports ESRCH distinctly. This remains usable when a
  # restricted environment blocks ps entirely.
  case "$kill_output" in *"No such process"*) return 0 ;; esac
  # Any other failure may be EPERM. Ask ps rather than interpreting it as
  # death; if ps itself is unavailable or denied, retain the lock.
  command -v ps >/dev/null 2>&1 || return 2
  ps_status=0
  ps_output="$(ps -p "$pid" -o pid= 2>/dev/null)" || ps_status=$?
  ps_output="$(printf '%s' "$ps_output" | tr -d '[:space:]')"
  if [ -n "$ps_output" ]; then return 1; fi
  # BSD and procps ps use 1 for a valid query with no matching process.
  case "$ps_status" in 0|1) return 0 ;; *) return 2 ;; esac
}

# Successful rollups no longer need raw process streams.
if [ -d "$SCRUM/rollups" ]; then
  while IFS= read -r -d '' status_path; do
    status="$(tr '[:upper:]' '[:lower:]' < "$status_path" | tr -d '[:space:]')"
    case "$status" in
      success|passed)
        run_dir="${status_path%/status}"
        [ ! -f "$run_dir/stdout" ] || remove_path "$run_dir/stdout"
        [ ! -f "$run_dir/stderr" ] || remove_path "$run_dir/stderr"
        ;;
    esac
  done < <(find "$SCRUM/rollups" -mindepth 2 -maxdepth 2 -type f -name status -print0)
fi

# Generated content inside PBI worktrees. find does not follow the .scrum link.
if [ -d "$SCRUM/worktrees" ]; then
  while IFS= read -r -d '' generated; do remove_path "$generated"; done < <(
    find "$SCRUM/worktrees" -mindepth 2 -type d \
      \( -name .venv -o -name .cache -o -name .pytest_cache -o -name .mypy_cache \
         -o -name .ruff_cache -o -name __pycache__ -o -name build -o -name dist -o -name out \) \
      -prune -print0
  )
fi

# A posted body duplicates the issue; its sidecar remains as the local index.
if [ -d "$SCRUM/framework-issues" ]; then
  while IFS= read -r -d '' meta; do
    if grep -q '^status=posted$' "$meta"; then
      draft="${meta%.meta}.md"
      [ ! -f "$draft" ] || remove_path "$draft"
    fi
  done < <(find "$SCRUM/framework-issues" -maxdepth 1 -type f -name '*.meta' -print0)
fi

# Bound runtime logs in place. Evidence directories are intentionally excluded.
while IFS= read -r -d '' log; do
  size="$(wc -c < "$log" | tr -d ' ')"
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    printf '%s\t%s\n' "$MODE" "${log#"$ROOT/"} (keep newest $MAX_LOG_BYTES bytes)"
    if [ "$MODE" = apply ]; then
      tmp="${log}.cleanup.$$"
      tail -c "$MAX_LOG_BYTES" "$log" > "$tmp"
      mv "$tmp" "$log"
    fi
  fi
done < <(
  find "$SCRUM" -maxdepth 1 -type f -name '*.log' -print0
  [ ! -d "$SCRUM/logs" ] || find "$SCRUM/logs" -maxdepth 1 -type f -name '*.log' -print0
)

# A lock is removable only when old enough and its recorded owner is dead.
if [ -d "$SCRUM/locks" ]; then
  now="$(date +%s)"
  while IFS= read -r -d '' lock; do
    pid_file="$lock/owner.pid"
    [ -f "$pid_file" ] || continue
    pid="$(tr -d '[:space:]' < "$pid_file")"
    printf '%s' "$pid" | grep -Eq '^[1-9][0-9]*$' || continue
    mtime="$(mtime_of "$lock")"
    [ "$mtime" -gt 0 ] || continue
    [ $((now - mtime)) -ge "$MIN_LOCK_AGE" ] || continue
    if process_confirmed_dead "$pid"; then remove_path "$lock"; fi
  done < <(find "$SCRUM/locks" -mindepth 1 -maxdepth 1 -type d -name '*.lock.d' -print0)
fi
