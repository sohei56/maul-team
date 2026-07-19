#!/usr/bin/env bash
# scripts/scrum/migrate-state.sh — bring existing .scrum/ state up to the
# deployed framework version: run every state migration, then validate the
# state files against the deployed schemas.
#
# scrum-start.sh runs this on every launch (right after setup-user.sh has
# refreshed .scrum/scripts/ and the schemas) and BEFORE the team is spawned —
# a failure here aborts the launch instead of letting agents run on drifted
# state and fail mid-Sprint in confusing ways.
#
# Migration contract (migrations/NNN-<slug>.sh, executed in lexical order):
#   - cwd is the target project root; only argument is an optional --dry-run
#   - idempotent: a second run is a no-op. There is no version cursor —
#     EVERY migration runs on EVERY launch, so keep the no-op path cheap
#     (a jq read, not a rewrite)
#   - missing target files are a clean no-op (exit 0), never an error
#   - rewrites are schema-validated before replacing the original
#     (reuse 001's apply_migration_with_args pattern)
#   - a breaking schema change ships its migration in the same commit;
#     the NNN prefix provides stable ordering, nothing more. A forgotten
#     migration is caught loudly by the validation phase below.
#
# Usage: migrate-state.sh [--dry-run|--check]
#   (none)     run migrations, then validate (exit 65 listing every offender)
#   --dry-run  forward to migrations (print planned changes); skip validation
#   --check    skip migrations; validate only
#
# Validation policy: wrapper-written SSOT files must match their schema
# (blocking). Hook-owned hot-path files (communications/dashboard/autonomy/
# stop-gate) are validated but only WARN — their writers deliberately skip
# per-append re-validation (docs/contracts/scrum-state/README.md), and a
# telemetry glitch must not brick a launch.
#
# Exit codes: 0 ok/nothing-to-do; 64 usage; 65 validation failure;
# a failing migration's own exit code otherwise. Requires bash (the sourced
# libs use BASH_SOURCE) — invoke as `bash migrate-state.sh` or directly.
set -euo pipefail

MODE=run
case "${1:-}" in
  "")        : ;;
  --dry-run) MODE=dry ;;
  --check)   MODE=check ;;
  *) echo "usage: $0 [--dry-run|--check]" >&2; exit 64 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

if [ ! -d .scrum ]; then
  echo "[migrate-state] no .scrum/ in $PWD — nothing to migrate"
  exit 0
fi

# Locate scrum-state schemas (source repo layout, then deployed target layout
# where setup-user.sh copies them — shared probe in lib/atomic.sh).
SCHEMA_DIR="$(resolve_schema_dir)"

MIGRATIONS_DIR="$HERE/migrations"

# --- Phase 1: migrations, lexical order -------------------------------------
if [ "$MODE" != "check" ]; then
  DRY_FLAG=""
  [ "$MODE" = "dry" ] && DRY_FLAG="--dry-run"
  for m in "$MIGRATIONS_DIR"/*.sh; do
    [ -e "$m" ] || continue
    rc=0
    # shellcheck disable=SC2086  # DRY_FLAG is empty or one flag
    bash "$m" $DRY_FLAG || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "[migrate-state] migration FAILED: $(basename "$m") (exit $rc) — launch must not proceed" >&2
      exit "$rc"
    fi
  done
fi

if [ "$MODE" = "dry" ]; then
  echo "[migrate-state] dry-run: validation skipped"
  exit 0
fi

# --- Phase 2: validate existing state files against the deployed schemas ----
# "<file> <schema_basename>" pairs. Missing files are skipped (fresh projects
# and never-used optional stores flow through untouched).
STRICT_MAP=".scrum/state.json state.schema.json
.scrum/sprint.json sprint.schema.json
.scrum/backlog.json backlog.schema.json
.scrum/config.json config.schema.json
.scrum/improvements.json improvements.schema.json
.scrum/sprint-history.json sprint-history.schema.json
.scrum/test-results.json test-results.schema.json
.scrum/po/decisions.json po-decisions.schema.json"

WARN_MAP=".scrum/communications.json communications.schema.json
.scrum/dashboard.json dashboard.schema.json
.scrum/autonomy.json autonomy.schema.json
.scrum/stop-gate.json stop-gate.schema.json"

# _check_one <json_path> <schema_basename>
# Prints "<file>: <validator error>" and returns 1 on violation; silent 0 on
# valid or missing file.
_check_one() {
  local json="$1" schema="$SCHEMA_DIR/$2" err
  [ -f "$json" ] || return 0
  if ! err="$(_validate_against_schema "$json" "$schema" 2>&1)"; then
    printf '%s: %s' "$json" "$err"
    return 1
  fi
  return 0
}

FAILED=""
N_BAD=0
while read -r f s; do
  [ -n "$f" ] || continue
  line=""
  if ! line="$(_check_one "$f" "$s")"; then
    FAILED="${FAILED}${line}
"
    N_BAD=$((N_BAD + 1))
  fi
done <<< "$STRICT_MAP"

for p in .scrum/pbi/*/state.json; do
  [ -e "$p" ] || continue
  line=""
  if ! line="$(_check_one "$p" "pbi-state.schema.json")"; then
    FAILED="${FAILED}${line}
"
    N_BAD=$((N_BAD + 1))
  fi
done

while read -r f s; do
  [ -n "$f" ] || continue
  line=""
  if ! line="$(_check_one "$f" "$s")"; then
    printf '[migrate-state] WARN (hook-owned, non-blocking): %s\n' "$line" >&2
  fi
done <<< "$WARN_MAP"

if [ "$N_BAD" -gt 0 ]; then
  printf '%s' "$FAILED" >&2
  fail E_SCHEMA "$N_BAD state file(s) violate the deployed schemas (see lines above) — migrate or fix them before launching; deployed framework rev: .scrum/deploy-stamp.json"
fi

echo "[migrate-state] ok: migrations applied, state matches deployed schemas"
