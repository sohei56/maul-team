#!/usr/bin/env bash
# scripts/scrum/update-audit-ledger.sh — the sole writer of
# .scrum/audit-ledger.json, the codebase-audit defect-CLASS ledger.
#
# Usage:
#   update-audit-ledger.sh <subcommand> [flags]
#     upsert-class      --identity <k> --sprint <sprint-id> [--axis a,b]
#                       [--severity critical|high|low]
#     add-occurrences   --identity <k> --sprint <sprint-id> --from <file.json>
#                       [--replace]
#     set-status        --identity <k> --status open|sweeping|guarded|accepted|closed
#                       [--dec-id dec-NNNN] [--evidence <text>]
#     add-exclusion     --identity <k> --path <p> [--symbol <s>] --reason <text>
#                       --dec-id dec-NNNN [--round <r>]
#     link-pbi          --identity <k> --pbi pbi-NNN --role sweep|detector
#     confirm-seen      --identity <k> --sprint <sprint-id>
#     register-detector --identity <k> --command <cmd> --sprint <sprint-id>
#                       [--scope-caveat <text>]
#     list              [--status <s>] [--format tsv|json]   # read-only, no lock
#
# The ledger holds one entry per defect class the audit has ever seen, keyed by
# the same `audit_identity` backlog.json carries. Its purpose is cross-round
# class IDENTITY and occurrence retention — NOT issuance suppression. Schema:
# docs/contracts/scrum-state/audit-ledger.schema.json. Direct edits are blocked
# by pre-tool-use-scrum-state-guard.sh, so this wrapper is the only write path.
#
# Invariants this wrapper enforces (each one mechanizes a measured failure):
#   1. Identity is validated for FORM on every --identity and never repaired.
#      Silent normalization is how false cross-round matches get created.
#   2. `upsert-class` never changes `status`; it unions `axis`, raises
#      `severity` monotonically (low < high < critical, never lowers), and
#      stamps `last_confirmed_sprint`.
#   3. `add-occurrences` is a UNION keyed on (path, symbol). An occurrence not
#      present in the new input keeps its old `last_seen_sprint` rather than
#      vanishing; `--replace` is the explicit correction path.
#   4. `set-status guarded` is the single choke point for "this class is owned
#      by a detector", and it refuses unless ALL of: (a) `detector.command` is
#      non-empty; (b) the DEPLOYED merge path is wired — the sibling
#      merge-pbi.sh greps as invoking run-detectors.sh; (c) the runner actually
#      EXECUTED the check (exit 0 clean or 1 violations; 2 = could not execute,
#      64 = usage / unknown identity, and every other code is refused); (d) the
#      check's exit and timestamp are re-stamped in the same write. A ledger
#      that says `guarded` while no gate runs is the exact failure this exists
#      to prevent.
#   5. `set-status accepted` requires a --dec-id that EXISTS in
#      .scrum/po/decisions.json with kind ∈ {defect_triage, spec_clarification}
#      — the only two kinds whose semantics are "this finding is not being
#      fixed".
#   6. `set-status closed` requires ≥1 linked PBI at status `done` AND either a
#      wired detector whose --check is clean (exit 0) or an explicit
#      --evidence (the re-runnable zero-check from the AC).
#   7. `set-status sweeping` requires ≥1 linked PBI that is not done/cancelled.
#   8. `add-exclusion` applies the same --dec-id existence check as (5).
#   9. `link-pbi` requires the id to exist in .scrum/backlog.json.
#  10. `register-detector` runs --check immediately through the same runner; a
#      command that could not execute (exit 2) is refused, so an unverified
#      detector can never be registered. Status is untouched — promotion to
#      `guarded` is a separate, separately-auditable call.
#
# Enum allow-lists (axis / severity / status / pbi_ids[].role) are read from the
# deployed schema at runtime rather than hardcoded, matching lib/queries.sh
# `backlog_status_enum` — a hardcoded copy drifts when the enum grows.
#
# The runner path is `$SCRUM_RUN_DETECTORS` when set, else the sibling
# run-detectors.sh; the override exists for tests.
#
# The store file is created on first mutating call (initial content
# `{"classes": [], "updated_at": <now>}`) and `.scrum/` is created
# automatically. Mutating subcommands echo the identity on stdout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"
# shellcheck source=lib/queries.sh
source "$HERE/lib/queries.sh"

PATHF=".scrum/audit-ledger.json"
BACKLOG=".scrum/backlog.json"
DECISIONS=".scrum/po/decisions.json"
# The only PO decision kinds whose semantics are "this finding is not being
# fixed" (po-decisions.schema.json `kind` enum).
SUPPRESSION_KINDS="defect_triage|spec_clarification"

USAGE="usage: update-audit-ledger.sh <subcommand> [flags]
  upsert-class      --identity <k> --sprint <sprint-id> [--axis a,b] [--severity critical|high|low]
  add-occurrences   --identity <k> --sprint <sprint-id> --from <file.json> [--replace]
  set-status        --identity <k> --status open|sweeping|guarded|accepted|closed [--dec-id dec-NNNN] [--evidence <text>]
  add-exclusion     --identity <k> --path <p> [--symbol <s>] --reason <text> --dec-id dec-NNNN [--round <r>]
  link-pbi          --identity <k> --pbi pbi-NNN --role sweep|detector
  confirm-seen      --identity <k> --sprint <sprint-id>
  register-detector --identity <k> --command <cmd> --sprint <sprint-id> [--scope-caveat <text>]
  list              [--status <s>] [--format tsv|json]"

SUB="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi

case "$SUB" in
  -h|--help|help) printf '%s\n' "$USAGE"; exit 0 ;;
  "") printf '%s\n' "$USAGE" >&2; fail E_INVALID_ARG "subcommand required" ;;
esac

IDENTITY=""
SPRINT=""
AXIS=""
SEVERITY=""
FROM=""
REPLACE="false"
STATUS=""
DEC_ID=""
EVIDENCE=""
EVIDENCE_SET="false"
OCC_PATH=""
SYMBOL=""
SYMBOL_SET="false"
REASON=""
ROUND=""
PBI=""
ROLE=""
COMMAND=""
SCOPE_CAVEAT=""
SCOPE_CAVEAT_SET="false"
FORMAT="tsv"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity)      IDENTITY="$2"; shift 2 ;;
    --sprint)        SPRINT="$2"; shift 2 ;;
    --axis)          AXIS="$2"; shift 2 ;;
    --severity)      SEVERITY="$2"; shift 2 ;;
    --from)          FROM="$2"; shift 2 ;;
    --replace)       REPLACE="true"; shift 1 ;;
    --status)        STATUS="$2"; shift 2 ;;
    --dec-id)        DEC_ID="$2"; shift 2 ;;
    --evidence)      EVIDENCE="$2"; EVIDENCE_SET="true"; shift 2 ;;
    --path)          OCC_PATH="$2"; shift 2 ;;
    --symbol)        SYMBOL="$2"; SYMBOL_SET="true"; shift 2 ;;
    --reason)        REASON="$2"; shift 2 ;;
    --round)         ROUND="$2"; shift 2 ;;
    --pbi)           PBI="$2"; shift 2 ;;
    --role)          ROLE="$2"; shift 2 ;;
    --command)       COMMAND="$2"; shift 2 ;;
    --scope-caveat)  SCOPE_CAVEAT="$2"; SCOPE_CAVEAT_SET="true"; shift 2 ;;
    --format)        FORMAT="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

SCHEMA="$(resolve_schema_dir)/audit-ledger.schema.json"

# --- schema-derived enums ---------------------------------------------------

# _schema_enum <jq_path_expr> <label>
# Print one enum value per line, read from the deployed schema. Never hardcode
# a parallel copy: the schema is the sole authority (lib/queries.sh discipline).
_schema_enum() {
  local expr="$1" label="$2" out
  out="$(jq -r "$expr" "$SCHEMA" 2>/dev/null || true)"
  [ -n "$out" ] || fail E_SCHEMA "cannot read $label enum from $(basename "$SCHEMA")"
  printf '%s\n' "$out"
}

_axis_enum() {
  _schema_enum '.properties.classes.items.properties.axis.items.enum[]' axis
}
_severity_enum() {
  _schema_enum '.properties.classes.items.properties.severity.enum[] | select(. != null)' severity
}
_status_enum() {
  _schema_enum '.properties.classes.items.properties.status.enum[]' status
}
_role_enum() {
  _schema_enum '.properties.classes.items.properties.pbi_ids.items.properties.role.enum[]' role
}

# --- shared helpers ---------------------------------------------------------

# _json_str <value> — a properly escaped JSON string literal for interpolation
# into an atomic_write expression (atomic_write binds only $now, so free-form
# text has to arrive pre-escaped, exactly as append-po-decision.sh does).
_json_str() { jq -n --arg v "$1" '$v'; }

# _json_str_or_null <value> — same, but "" becomes JSON null.
_json_str_or_null() { jq -n --arg v "$1" 'if $v == "" then null else $v end'; }

_require_identity() {
  [ -n "$IDENTITY" ] || fail E_INVALID_ARG "--identity required"
  # Invariant 1: validate the FORM, reject on a miss, never repair.
  assert_audit_identity "$IDENTITY" --identity
}

_require_sprint() {
  [ -n "$SPRINT" ] || fail E_INVALID_ARG "--sprint required"
  assert_sprint_id "$SPRINT" --sprint
}

_ensure_ledger() {
  mkdir -p "$(dirname "$PATHF")"
  if [ ! -f "$PATHF" ]; then
    local now; now="$(_iso_utc_now)"
    # Seeded through atomic_create so the first write is schema-validated and
    # lands via temp+mv, matching every atomic_write that follows.
    # shellcheck disable=SC2016  # $now is a jq -n binding, not a shell variable
    atomic_create "$PATHF" "$SCHEMA" '{classes: [], updated_at: $now}' --arg now "$now"
  fi
}

_require_class() {
  [ -f "$PATHF" ] || fail E_INVALID_ARG \
    "no ledger at $PATHF — transcribe the class first: update-audit-ledger.sh upsert-class --identity '$IDENTITY' --sprint <sprint-id>"
  jq -e --arg k "$IDENTITY" 'any(.classes[]?; .identity == $k)' "$PATHF" >/dev/null 2>&1 || fail E_INVALID_ARG \
    "unknown class '$IDENTITY' in $PATHF — transcribe it first: update-audit-ledger.sh upsert-class --identity '$IDENTITY' --sprint <sprint-id>"
}

# _class_field <jq_expr_on_class> — read one value off the addressed class.
_class_field() {
  jq -r --arg k "$IDENTITY" "first(.classes[] | select(.identity == \$k) | $1) // \"\"" "$PATHF"
}

# _linked_pbi_statuses — the backlog status of every PBI linked to the class,
# one per line. A link whose PBI is absent from the backlog yields a blank line
# (callers filter blanks), so a missing backlog degrades to "no linked work"
# rather than blowing up inside jq.
_linked_pbi_statuses() {
  jq -r --arg k "$IDENTITY" \
    'first(.classes[] | select(.identity == $k)) | .pbi_ids[]?.id' "$PATHF" \
  | while IFS= read -r id; do
      [ -n "$id" ] || continue
      get_pbi_status "$id" "$BACKLOG" ""
      printf '\n'
    done
}

# _apply_to_class <inner_jq> — atomic_write of a per-class mutation. `$now` is
# bound by atomic_write and usable inside <inner_jq>.
_apply_to_class() {
  local ident_json; ident_json="$(_json_str "$IDENTITY")"
  atomic_write "$PATHF" \
    ".classes |= map(if .identity == $ident_json then ($1) else . end)" \
    "$SCHEMA"
}

# --- detector runner --------------------------------------------------------

_runner_path() { printf '%s' "${SCRUM_RUN_DETECTORS:-$HERE/run-detectors.sh}"; }

# _assert_runner_present — refuse when the runner is not deployed. Naming
# setup-user.sh is the actionable half: a stale target deployment is the most
# likely reason the file is absent.
_assert_runner_present() {
  local runner; runner="$(_runner_path)"
  [ -x "$runner" ] || fail E_INVALID_ARG \
    "detector runner not executable: $runner — re-deploy the framework wrappers (scripts/setup-user.sh) before promoting a class to guarded"
}

# _run_check <identity> — echo the runner's exit code. The runner's space is
# 0 = clean, 1 = violations, 2 = could not execute, 64 = usage / unknown
# identity. Only 0 and 1 mean the detector actually RAN; every other code
# (including a runner that is itself broken and exits something else) is
# treated as "did not execute" and refused, because a ratchet that silently
# passes when its detector is broken is worse than no ratchet.
_run_check() {
  local runner rc=0
  runner="$(_runner_path)"
  "$runner" --check "$1" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- subcommands ------------------------------------------------------------

case "$SUB" in

  upsert-class)
    _require_identity
    _require_sprint

    AXIS_JSON='[]'
    if [ -n "$AXIS" ]; then
      AXIS_ENUM="$(_axis_enum)"
      # Bash 3.2: split on commas through a subshell loop, no arrays needed.
      AXIS_LINES="$(printf '%s' "$AXIS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)"
      [ -n "$AXIS_LINES" ] || fail E_INVALID_ARG "--axis is empty after parsing: $AXIS"
      while IFS= read -r a; do
        printf '%s\n' "$AXIS_ENUM" | grep -Fxq "$a" || fail E_INVALID_ARG \
          "bad --axis value: $a (allowed: $(printf '%s' "$AXIS_ENUM" | tr '\n' ' ' | sed 's/ $//'))"
      done <<< "$AXIS_LINES"
      AXIS_JSON="$(printf '%s\n' "$AXIS_LINES" | json_lines_to_array)"
    fi

    if [ -n "$SEVERITY" ]; then
      SEV_ENUM="$(_severity_enum)"
      printf '%s\n' "$SEV_ENUM" | grep -Fxq "$SEVERITY" || fail E_INVALID_ARG \
        "bad --severity: $SEVERITY (allowed: $(printf '%s' "$SEV_ENUM" | tr '\n' ' ' | sed 's/ $//'))"
    fi

    _ensure_ledger

    IDENT_JSON="$(_json_str "$IDENTITY")"
    SPRINT_JSON="$(_json_str "$SPRINT")"
    SEV_JSON="$(_json_str_or_null "$SEVERITY")"

    # Severity is raised monotonically and never lowered: a class re-rated
    # lower in a later round is still, historically, as bad as its worst
    # sighting, and the Integration-entry block predicate reads the field.
    # shellcheck disable=SC2016  # $now is bound by atomic_write
    EXPR="
      def rank: if . == \"critical\" then 3 elif . == \"high\" then 2 elif . == \"low\" then 1 else 0 end;
      if any(.classes[]?; .identity == $IDENT_JSON)
      then .classes |= map(
        if .identity == $IDENT_JSON
        then .axis = (((.axis // []) + $AXIS_JSON) | unique)
             | (if $SEV_JSON != null and (($SEV_JSON | rank) > ((.severity // null) | rank))
                then .severity = $SEV_JSON else . end)
             | .last_confirmed_sprint = $SPRINT_JSON
        else . end)
      else .classes += [{
        identity: $IDENT_JSON,
        axis: $AXIS_JSON,
        severity: $SEV_JSON,
        status: \"open\",
        occurrences: [],
        exclusions: [],
        detector: null,
        pbi_ids: [],
        first_seen_sprint: $SPRINT_JSON,
        last_confirmed_sprint: $SPRINT_JSON,
        closed_evidence: null
      }]
      end"

    atomic_write "$PATHF" "$EXPR" "$SCHEMA"
    printf '%s\n' "$IDENTITY"
    ;;

  add-occurrences)
    _require_identity
    _require_sprint
    [ -n "$FROM" ] || fail E_INVALID_ARG "--from <file.json> required"
    [ -f "$FROM" ] || fail E_FILE_MISSING "$FROM"
    _require_class

    jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (has("path") and (.path | type) == "string" and (.path | length) > 0)
        and ((keys_unsorted | map(select(. != "path" and . != "symbol" and . != "note"))) | length) == 0
        and ((.symbol == null) or ((.symbol | type) == "string"))
        and ((.note == null) or ((.note | type) == "string"))
      )' "$FROM" >/dev/null 2>&1 || fail E_INVALID_ARG \
      "--from $FROM must be a JSON array of {path, symbol?, note?} with a non-empty string path"

    INC_JSON="$(jq -c '[ .[] | {path: .path, symbol: (.symbol // null), note: (.note // null)} ]' "$FROM")"
    IDENT_JSON="$(_json_str "$IDENTITY")"
    SPRINT_JSON="$(_json_str "$SPRINT")"

    # UNION on (path, symbol): a stale occurrence stays visible with its old
    # last_seen_sprint instead of vanishing — "did the sweep shrink?" is only
    # answerable if nothing is silently dropped. --replace is the correction
    # path and drops unseen entries on purpose.
    EXPR="
      $INC_JSON as \$inc
      | .classes |= map(
          if .identity == $IDENT_JSON
          then .occurrences = (
                 ((.occurrences // [])
                   | map(. as \$o | select(($REPLACE | not)
                       or (\$inc | any(.path == \$o.path and (.symbol // null) == (\$o.symbol // null)))))
                   | map(. as \$o | if (\$inc | any(.path == \$o.path and (.symbol // null) == (\$o.symbol // null)))
                         then .last_seen_sprint = $SPRINT_JSON else . end))
                 + ((.occurrences // [])  as \$old
                   | \$inc
                   | map(. as \$i | select((\$old | any(.path == \$i.path and (.symbol // null) == (\$i.symbol // null))) | not))
                   | map(. + {first_seen_sprint: $SPRINT_JSON, last_seen_sprint: $SPRINT_JSON})))
          else . end)"

    atomic_write "$PATHF" "$EXPR" "$SCHEMA"
    printf '%s\n' "$IDENTITY"
    ;;

  set-status)
    _require_identity
    [ -n "$STATUS" ] || fail E_INVALID_ARG "--status required"
    STATUS_ENUM="$(_status_enum)"
    printf '%s\n' "$STATUS_ENUM" | grep -Fxq "$STATUS" || fail E_INVALID_ARG \
      "bad --status: $STATUS (allowed: $(printf '%s' "$STATUS_ENUM" | tr '\n' ' ' | sed 's/ $//'))"
    _require_class

    EXTRA=""   # additional per-status mutation, applied in the SAME write

    case "$STATUS" in
      sweeping)
        # Invariant 7: "being swept" means work is actually in flight.
        LIVE="$(_linked_pbi_statuses | grep -vE '^(done|cancelled)?$' | grep -c . || true)"
        [ "${LIVE:-0}" -gt 0 ] || fail E_INVALID_ARG \
          "cannot set '$IDENTITY' to sweeping: no linked PBI is open (link one with link-pbi --role sweep, or file it first)"
        ;;

      guarded)
        # Invariant 4 (a): a detector command must be on record.
        DET_CMD="$(_class_field '.detector.command')"
        [ -n "$DET_CMD" ] || fail E_INVALID_ARG \
          "cannot set '$IDENTITY' to guarded: no detector registered (run register-detector first)"

        # Invariant 4 (b): the DEPLOYED merge path must actually call the
        # runner. A ledger that claims guarded while merge-pbi.sh never
        # invokes run-detectors.sh is precisely the measured failure — the
        # class leaves LLM audit scope and nothing takes over.
        MERGE_SH="$HERE/merge-pbi.sh"
        [ -f "$MERGE_SH" ] || fail E_INVALID_ARG \
          "cannot set '$IDENTITY' to guarded: $MERGE_SH not found — re-deploy the framework wrappers (scripts/setup-user.sh)"
        grep -q 'run-detectors.sh' "$MERGE_SH" || fail E_INVALID_ARG \
          "cannot set '$IDENTITY' to guarded: the deployed $MERGE_SH does not invoke run-detectors.sh, so no gate would run — re-deploy the framework wrappers (scripts/setup-user.sh)"

        # Invariant 4 (c): the check must have EXECUTED (0 clean / 1
        # violations). Exit 2 means the runner could not run the command.
        _assert_runner_present
        RC="$(_run_check "$IDENTITY")"
        case "$RC" in
          0|1) ;;
          *) fail E_INVALID_ARG \
               "cannot set '$IDENTITY' to guarded: $(_runner_path) --check exited $RC (the detector did not execute; 0=clean, 1=violations are the only verified outcomes)" ;;
        esac

        # Invariant 4 (d): re-stamp the verification in the same write, so the
        # stamp can never be a boolean somebody typed.
        # shellcheck disable=SC2016  # $now is bound by atomic_write
        EXTRA=" | .detector.verified_at = \$now | .detector.verified_exit = $RC"
        ;;

      accepted)
        # Invariant 5: an acceptance is a persisted "not being fixed"; it must
        # cite a decision that exists and whose kind carries that meaning.
        [ -n "$DEC_ID" ] || fail E_INVALID_ARG \
          "set-status accepted requires --dec-id (an acceptance with no decision record silently loses its own justification)"
        assert_dec_id_exists "$DEC_ID" "$DECISIONS" "$SUPPRESSION_KINDS"
        ;;

      closed)
        # Invariant 6, first half: something has to have actually been done.
        DONE_N="$(_linked_pbi_statuses | grep -cx 'done' || true)"
        [ "${DONE_N:-0}" -gt 0 ] || fail E_INVALID_ARG \
          "cannot close '$IDENTITY': no linked PBI is done (link the sweep PBI with link-pbi and finish it first)"

        # Second half: either a clean detector run or a recorded zero-check.
        # Closing on neither is what the measured 3/11 re-ignition rate buys.
        if [ "$EVIDENCE_SET" = "true" ]; then
          [ -n "$EVIDENCE" ] || fail E_INVALID_ARG "--evidence must not be empty"
          EV_JSON="$(_json_str "$EVIDENCE")"
          EXTRA=" | .closed_evidence = $EV_JSON"
        else
          DET_CMD="$(_class_field '.detector.command')"
          [ -n "$DET_CMD" ] || fail E_INVALID_ARG \
            "cannot close '$IDENTITY': no --evidence and no registered detector (record the re-runnable zero-check from the AC with --evidence)"
          _assert_runner_present
          RC="$(_run_check "$IDENTITY")"
          [ "$RC" = "0" ] || fail E_INVALID_ARG \
            "cannot close '$IDENTITY': $(_runner_path) --check exited $RC (only a clean run, exit 0, closes a class without --evidence)"
          # shellcheck disable=SC2016  # $now is bound by atomic_write
          EXTRA=" | .detector.verified_at = \$now | .detector.verified_exit = 0"
        fi
        ;;
    esac

    STATUS_JSON="$(_json_str "$STATUS")"
    _apply_to_class ".status = $STATUS_JSON$EXTRA"
    printf '%s\n' "$IDENTITY"
    ;;

  add-exclusion)
    _require_identity
    [ -n "$OCC_PATH" ] || fail E_INVALID_ARG "--path required"
    [ -n "$REASON" ]   || fail E_INVALID_ARG "--reason required"
    [ -n "$DEC_ID" ]   || fail E_INVALID_ARG "--dec-id required"
    # Invariant 8: same existence check as set-status accepted.
    assert_dec_id_exists "$DEC_ID" "$DECISIONS" "$SUPPRESSION_KINDS"
    _require_class

    if [ "$SYMBOL_SET" = "true" ]; then
      SYMBOL_JSON="$(_json_str_or_null "$SYMBOL")"
    else
      SYMBOL_JSON="null"
    fi
    EXCL_JSON="$(
      jq -nc --arg p "$OCC_PATH" --argjson sym "$SYMBOL_JSON" --arg r "$REASON" \
        --arg d "$DEC_ID" --arg rd "$ROUND" \
        '{path: $p, symbol: $sym, reason: $r, dec_id: $d,
          round: (if $rd == "" then null else $rd end)}'
    )"

    # Upsert on (path, symbol): re-waiving the same occurrence replaces the
    # record rather than stacking a second one, so `exclusions[]` stays a set
    # of live waivers and the newest dec_id is the one that governs.
    EXPR_INNER=".exclusions = (((.exclusions // []) | map(select(.path != ($EXCL_JSON).path or (.symbol // null) != ($EXCL_JSON).symbol))) + [$EXCL_JSON])"
    _apply_to_class "$EXPR_INNER"
    printf '%s\n' "$IDENTITY"
    ;;

  link-pbi)
    _require_identity
    [ -n "$PBI" ]  || fail E_INVALID_ARG "--pbi required"
    [ -n "$ROLE" ] || fail E_INVALID_ARG "--role required"
    assert_pbi_id "$PBI" --pbi
    ROLE_ENUM="$(_role_enum)"
    printf '%s\n' "$ROLE_ENUM" | grep -Fxq "$ROLE" || fail E_INVALID_ARG \
      "bad --role: $ROLE (allowed: $(printf '%s' "$ROLE_ENUM" | tr '\n' ' ' | sed 's/ $//'))"
    # Invariant 9: a link to a PBI that does not exist is a dangling claim of
    # work, and `set-status closed`/`sweeping` both read the link.
    pbi_in_backlog "$PBI" "$BACKLOG" || fail E_INVALID_ARG \
      "--pbi $PBI is not in $BACKLOG (file the PBI through add-backlog-item.sh first)"
    _require_class

    LINK_JSON="$(jq -nc --arg id "$PBI" --arg role "$ROLE" '{id: $id, role: $role}')"
    _apply_to_class ".pbi_ids = (((.pbi_ids // []) | map(select(.id != ($LINK_JSON).id))) + [$LINK_JSON])"
    printf '%s\n' "$IDENTITY"
    ;;

  confirm-seen)
    _require_identity
    _require_sprint
    _require_class
    SPRINT_JSON="$(_json_str "$SPRINT")"
    _apply_to_class ".last_confirmed_sprint = $SPRINT_JSON"
    printf '%s\n' "$IDENTITY"
    ;;

  register-detector)
    _require_identity
    _require_sprint
    [ -n "$COMMAND" ] || fail E_INVALID_ARG "--command required"
    _require_class
    _assert_runner_present

    CMD_JSON="$(_json_str "$COMMAND")"
    SPRINT_JSON="$(_json_str "$SPRINT")"
    if [ "$SCOPE_CAVEAT_SET" = "true" ]; then
      CAVEAT_JSON="$(_json_str_or_null "$SCOPE_CAVEAT")"
    else
      CAVEAT_JSON="null"
    fi
    PREV_DETECTOR="$(jq -c --arg k "$IDENTITY" \
      'first(.classes[] | select(.identity == $k) | .detector) // null' "$PATHF")"

    # Invariant 10: the runner reads the command out of the ledger, so the
    # command has to land before it can be probed. It lands with
    # `verified_exit: 2` — the runner's own "could not execute" code, i.e. an
    # honest "not verified yet" — and is rolled back if the probe never runs.
    # shellcheck disable=SC2016  # $now is bound by atomic_write
    _apply_to_class ".detector = {command: $CMD_JSON, registered_sprint: $SPRINT_JSON, verified_at: \$now, verified_exit: 2, scope_caveat: $CAVEAT_JSON}"

    RC="$(_run_check "$IDENTITY")"
    case "$RC" in
      0|1)
        # shellcheck disable=SC2016  # $now is bound by atomic_write
        _apply_to_class ".detector.verified_at = \$now | .detector.verified_exit = $RC"
        ;;
      *)
        _apply_to_class ".detector = $PREV_DETECTOR"
        fail E_INVALID_ARG \
          "detector for '$IDENTITY' did not execute ($(_runner_path) --check exited $RC) — registration rolled back; an unverified detector must never be on record"
        ;;
    esac
    printf '%s\n' "$IDENTITY"
    ;;

  list)
    case "$FORMAT" in
      tsv|json) ;;
      *) fail E_INVALID_ARG "bad --format: $FORMAT (expected tsv or json)" ;;
    esac
    if [ -n "$STATUS" ]; then
      STATUS_ENUM="$(_status_enum)"
      printf '%s\n' "$STATUS_ENUM" | grep -Fxq "$STATUS" || fail E_INVALID_ARG \
        "bad --status: $STATUS (allowed: $(printf '%s' "$STATUS_ENUM" | tr '\n' ' ' | sed 's/ $//'))"
    fi
    # Read-only: no lock, no seeding. An absent ledger is an empty ledger —
    # a reporter must never be the thing that creates state.
    if [ ! -f "$PATHF" ]; then
      if [ "$FORMAT" = "json" ]; then printf '[]\n'; fi
      exit 0
    fi
    if [ "$FORMAT" = "json" ]; then
      jq --arg s "$STATUS" '[ .classes[]? | select($s == "" or .status == $s) ]' "$PATHF"
    else
      jq -r --arg s "$STATUS" '
        .classes[]?
        | select($s == "" or .status == $s)
        | [ .identity,
            .status,
            (.severity // "-"),
            ((.axis // []) | if length == 0 then "-" else join(",") end),
            ((.occurrences // []) | length | tostring),
            (if (.detector // null) == null then "-" else .detector.command end),
            .first_seen_sprint,
            (.last_confirmed_sprint // "-") ]
        | @tsv' "$PATHF"
    fi
    ;;

  *)
    printf '%s\n' "$USAGE" >&2
    fail E_INVALID_ARG "unknown subcommand: $SUB"
    ;;
esac
