#!/usr/bin/env bats
# tests/lint/audit-severity-wiring.bats — audit severity is a three-level
# FIELD, and two neighbouring scales must not be swept along with it.
#
# The field only works if the chain holds end to end: the schema declares the
# three values, the wrapper derives its allow-list from that schema, the
# block predicate reads the field instead of the title, and the PO is
# permitted to rule on the findings. Two lookalike scales sit next to it —
# `axes.md`'s `confidence: High | Medium | Low` and the pipeline envelope's
# lowercase 4-value `severity` — and a careless sweep mangles both, so their
# non-touch is pinned here too.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AUDIT_SKILL="${PROJECT_ROOT}/skills/codebase-audit/SKILL.md"
  AXES="${PROJECT_ROOT}/skills/codebase-audit/references/axes.md"
  SCHEMA="${PROJECT_ROOT}/docs/contracts/scrum-state/backlog.schema.json"
  ENVELOPE="${PROJECT_ROOT}/docs/contracts/pbi-pipeline-envelope.schema.json"
  ADD_ITEM="${PROJECT_ROOT}/scripts/scrum/add-backlog-item.sh"
  PO="${PROJECT_ROOT}/agents/product-owner.md"
}

@test "the severity table declares exactly Critical / High / Low" {
  for level in '| **Critical** |' '| **High** |' '| **Low** |'; do
    grep -qF "$level" "$AUDIT_SKILL" || {
      echo "codebase-audit severity table lost the row: $level" >&2
      return 1
    }
  done
  grep -qF '| **Medium** |' "$AUDIT_SKILL" && {
    echo "codebase-audit severity table reintroduced Medium" >&2
    return 1
  }
  return 0
}

@test "Medium survives in skills/codebase-audit only as a confidence level" {
  # The retired severity level must be gone, but `confidence: High | Medium |
  # Low` is a separate 3-level axis that happens to share two words with it.
  local offenders
  offenders="$(grep -rn 'Medium' "${PROJECT_ROOT}/skills/codebase-audit/" \
    | grep -iv 'confidence' || true)"
  [ -z "$offenders" ] || {
    echo "Medium still used as a severity in skills/codebase-audit:" >&2
    echo "$offenders" >&2
    return 1
  }
}

@test "the severity ordering is stated (two mechanisms compare levels)" {
  grep -qF 'low < high < critical' "$AUDIT_SKILL" || {
    echo "codebase-audit no longer states the low < high < critical ordering" >&2
    return 1
  }
}

@test "the Step 1b block predicate reads the field, not the title" {
  grep -qF '.audit_severity // "high") != "low"' "$AUDIT_SKILL" || {
    echo "Step 1b no longer selects on the audit_severity field" >&2
    return 1
  }
  ! grep -qF 'test(":(Critical|High)' "$AUDIT_SKILL" || {
    echo "Step 1b reintroduced the title-regex severity match" >&2
    return 1
  }
}

@test "the Step 5 filing template passes --audit-severity" {
  grep -q -- '--audit-severity "\${SEV}"' "$AUDIT_SKILL" || {
    echo "Step 5 filing template no longer passes --audit-severity" >&2
    return 1
  }
}

@test "axes.md offers three severity hints and keeps the confidence scale intact" {
  grep -qF 'severity_hint: Critical | High | Low' "$AXES" || {
    echo "axes.md severity_hint is no longer the 3-value scale" >&2
    return 1
  }
  grep -qF 'confidence: High | Medium | Low' "$AXES" || {
    echo "axes.md confidence scale was swept along with severity" >&2
    return 1
  }
}

@test "the pipeline envelope keeps its separate 4-value lowercase severity" {
  run jq -r '.. | objects | select(has("severity")) | .severity.enum // empty | @csv' "$ENVELOPE"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"critical","high","medium","low"'* ]]
}

@test "backlog.schema.json declares audit_severity with the three values" {
  run jq -r '.properties.items.items.properties.audit_severity.enum | map(tostring) | join(",")' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ "$output" = "critical,high,low,null" ]
}

@test "add-backlog-item derives the severity allow-list from the schema" {
  # Mirrors no-hardcoded-status-enum.bats: a hardcoded parallel copy drifts
  # the moment the schema changes, which is the `cancelled` incident again.
  grep -q 'backlog_audit_severity_enum' "$ADD_ITEM" || {
    echo "add-backlog-item.sh no longer derives audit_severity from the schema" >&2
    return 1
  }
  ! grep -qE 'critical\|high\|low\)' "$ADD_ITEM" || {
    echo "add-backlog-item.sh hardcoded a parallel severity allow-list" >&2
    return 1
  }
}

@test "product-owner keeps both halves: audit triage granted, gates still barred" {
  # A sweep that deletes the whole paragraph must fail, not silently widen or
  # narrow the PO's authority.
  # Wrap-tolerant: both sentences span line breaks in the source.
  local flat
  flat="$(tr '\n' ' ' < "$PO" | tr -s ' ')"
  printf '%s' "$flat" | grep -q 'does\*\* rule on audit-finding triage' || {
    echo "product-owner.md no longer grants audit-finding triage authority" >&2
    return 1
  }
  printf '%s' "$flat" | grep -q "cannot change the audit's \*\*gate semantics\*\*" || {
    echo "product-owner.md no longer withholds the audit's gate semantics" >&2
    return 1
  }
  for key in coverage merge_regression path_guard; do
    grep -qF "\`$key\`" "$PO" || {
      echo "product-owner.md no longer bars weakening: $key" >&2
      return 1
    }
  done
}
