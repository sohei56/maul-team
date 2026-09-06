#!/usr/bin/env bash
# Deterministic Integrity-stage aggregate validation and termination gates.
# Source this file after lib/errors.sh.

if [ "${_SCRUM_INTEGRITY_GATES_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # sourced-file guard; reachable on a second source
  return 0 2>/dev/null || true
fi
_SCRUM_INTEGRITY_GATES_SH_LOADED=1

# integrity_validate_aggregate <path> [expected-round]
# Rejects malformed signatures and unknown aspects before any state transition.
integrity_validate_aggregate() {
  local aggregate="$1" expected_round="${2:-}"
  [ -f "$aggregate" ] || fail E_FILE_MISSING "$aggregate"

  jq -e --arg expected "$expected_round" '
    def valid_aspect:
      . == "requirement-conformance"
      or . == "functional-quality"
      or . == "security"
      or . == "maintainability"
      or . == "docs-consistency";
    type == "object"
    and (.round | type == "number" and floor == . and . >= 0)
    and ($expected == "" or .round == ($expected | tonumber))
    and (.aspects | type == "array" and all(.[]; valid_aspect))
    and (.aspects | length == (unique | length))
    and (.findings | type == "array")
    and (.aspects as $aspects
      | all(.findings[]; .aspect as $aspect | $aspects | index($aspect) != null))
    and all(.findings[];
      (.signature | type == "string"
        and test("^.+:[0-9]+-[0-9]+:[a-z_]+$"))
      and (.severity == "critical" or .severity == "high"
        or .severity == "medium" or .severity == "low")
      and (.aspect | type == "string" and valid_aspect)
      and ((.file_path? // null) == null
        or (.file_path | type == "string"
          and .signature
            == (.file_path + ":" + (.line_start | tostring) + "-"
              + (.line_end | tostring) + ":" + .criterion_key)))
    )
  ' "$aggregate" >/dev/null 2>&1 \
    || fail E_SCHEMA "invalid Integrity aggregate: $aggregate (bad round, finding, signature, or aspect)"
}

# integrity_validate_aggregate_for_kind <path> <expected-round> <kind>
# `.aspects` records every spawned reviewer, including reviewers with zero
# findings, so validate it against the stage contract rather than deriving it
# from the finding union.
integrity_validate_aggregate_for_kind() {
  local aggregate="$1" expected_round="$2" kind="$3" expected_aspects
  integrity_validate_aggregate "$aggregate" "$expected_round"
  case "$kind" in
    code)
      expected_aspects='["docs-consistency","functional-quality","maintainability","requirement-conformance","security"]'
      ;;
    docs)
      expected_aspects='["docs-consistency","requirement-conformance"]'
      ;;
    *) fail E_SCHEMA "unknown PBI kind for Integrity gate: $kind" ;;
  esac
  jq -e --argjson expected "$expected_aspects" \
    '(.aspects | sort) == $expected' "$aggregate" >/dev/null 2>&1 \
    || fail E_SCHEMA "Integrity aggregate aspects do not match kind=$kind contract: $aggregate"
}

integrity_round_from_filename() {
  local path="$1" base round
  base="${path##*/}"
  case "$base" in integrity-r*.json) ;; *) fail E_SCHEMA "bad Integrity aggregate filename: $path" ;; esac
  round="${base#integrity-r}"
  round="${round%.json}"
  case "$round" in ''|*[!0-9]*) fail E_SCHEMA "bad Integrity aggregate filename round: $path" ;; esac
  printf '%s\n' "$round"
}

# Print the anchor path embedded in a validated signature.
integrity_signature_anchor() {
  printf '%s\n' "$1" | sed -E 's/:[0-9]+-[0-9]+:[a-z_]+$//'
}

# integrity_divergence_class <kind> <aspect> <signature>
# Prints increment or sync_lag. Validation is deliberately central: callers
# cannot trust a conductor-authored divergence_class in the aggregate.
integrity_divergence_class() {
  local kind="$1" aspect="$2" signature="$3" anchor
  case "$kind" in
    docs) printf '%s\n' increment; return ;;
    code) ;;
    *) fail E_SCHEMA "unknown PBI kind for Integrity gate: $kind" ;;
  esac

  case "$aspect" in
    functional-quality|security|maintainability)
      printf '%s\n' increment
      ;;
    docs-consistency)
      printf '%s\n' sync_lag
      ;;
    requirement-conformance)
      anchor="$(integrity_signature_anchor "$signature")"
      case "$anchor" in
        *.md) printf '%s\n' sync_lag ;;
        *)    printf '%s\n' increment ;;
      esac
      ;;
    *) fail E_SCHEMA "unknown Integrity aspect: $aspect" ;;
  esac
}

integrity_blocking_signatures() {
  jq -r '.findings[]
    | select(.severity == "critical" or .severity == "high")
    | .signature' "$1" | LC_ALL=C sort -u
}

integrity_divergence_count() {
  local aggregate="$1" kind="$2" count=0 severity aspect signature class
  while IFS=$'\t' read -r severity aspect signature; do
    [ -n "$signature" ] || continue
    case "$severity" in critical|high) ;; *) continue ;; esac
    class="$(integrity_divergence_class "$kind" "$aspect" "$signature")"
    [ "$class" = increment ] && count=$((count + 1))
  done < <(jq -r '.findings[] | [.severity, .aspect, .signature] | @tsv' "$aggregate")
  printf '%s\n' "$count"
}

# integrity_gate_outcome <kind> <round> <current> [previous]
# Prints next_round, stagnation, divergence, or max_rounds.
integrity_gate_outcome() {
  local kind="$1" round="$2" current="$3" previous="${4:-}"
  local current_sigs previous_sigs current_count previous_count previous_round

  case "$round" in ''|*[!0-9]*) fail E_INVALID_ARG "round must be a non-negative integer: $round" ;; esac
  case "$kind" in code|docs) ;; *) fail E_SCHEMA "unknown PBI kind for Integrity gate: $kind" ;; esac
  integrity_validate_aggregate_for_kind "$current" "$round" "$kind"

  # A FAIL resolver must never be used for a non-blocking aggregate.
  [ "$(jq '[.findings[] | select(.severity == "critical" or .severity == "high")] | length' "$current")" -gt 0 ] \
    || fail E_INVALID_ARG "Integrity FAIL aggregate contains no critical/high finding: $current"

  if [ -n "$previous" ]; then
    previous_round="$(integrity_round_from_filename "$previous")"
    integrity_validate_aggregate_for_kind "$previous" "$previous_round" "$kind"
    current_sigs="$(integrity_blocking_signatures "$current")"
    previous_sigs="$(integrity_blocking_signatures "$previous")"
    if [ -n "$(comm -12 <(printf '%s\n' "$current_sigs") <(printf '%s\n' "$previous_sigs"))" ]; then
      printf '%s\n' stagnation
      return
    fi

    current_count="$(integrity_divergence_count "$current" "$kind")"
    previous_count="$(integrity_divergence_count "$previous" "$kind")"
    if [ "$current_count" -gt "$previous_count" ]; then
      printf '%s\n' divergence
      return
    fi
  fi

  if [ "$round" -ge 5 ]; then
    printf '%s\n' max_rounds
  else
    printf '%s\n' next_round
  fi
}
