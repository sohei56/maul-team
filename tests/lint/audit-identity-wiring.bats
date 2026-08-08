#!/usr/bin/env bats
# tests/lint/audit-identity-wiring.bats — the cross-Sprint dedup key must stay
# wired end to end.
#
# The key is only useful if all four links hold at once: the schema declares
# the field, the auditors are given it, they are told to reuse it, and the SM
# matches on it exactly. Breaking any one link restores the failure this
# machinery exists to prevent — the same defect class filed again every Sprint
# under a fresh name. Prose drifts silently, so pin it here.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AUDIT_SKILL="${PROJECT_ROOT}/skills/codebase-audit/SKILL.md"
  AXES="${PROJECT_ROOT}/skills/codebase-audit/references/axes.md"
  SCHEMA="${PROJECT_ROOT}/docs/contracts/scrum-state/backlog.schema.json"
}

@test "audit read set hands audit_identity to the auditors" {
  # Without this the agent that mints the key cannot see the keys it minted
  # before, which is exactly how identity drift starts.
  grep -q 'audit_identity' "$AUDIT_SKILL" || {
    echo "codebase-audit/SKILL.md no longer mentions audit_identity" >&2
    return 1
  }
  # Scope the check to the Step 1 section so a passing mention elsewhere in the
  # skill cannot stand in for the read set actually carrying the field.
  local step1
  step1="$(awk '/^### Step 1 —/{f=1} /^### Step 2 —/{f=0} f' "$AUDIT_SKILL")"
  printf '%s' "$step1" | grep -q 'audit_identity' || {
    echo "Step 1 read set no longer lists audit_identity among the PBI summary fields" >&2
    return 1
  }
}

@test "audit filing passes --audit-identity to the wrapper" {
  grep -q -- '--audit-identity "\${IDENTITY}"' "$AUDIT_SKILL" || {
    echo "Step 5 filing template no longer passes --audit-identity" >&2
    return 1
  }
}

@test "audit dedup matches the audit_identity field exactly" {
  grep -q '\.audit_identity == \$aid' "$AUDIT_SKILL" || {
    echo "Step 5 dedup no longer matches on the audit_identity field" >&2
    return 1
  }
  # A substring match on the description is what used to fail: one character of
  # drift and the duplicate sailed through.
  ! grep -q 'contains($aid)' "$AUDIT_SKILL" || {
    echo "Step 5 dedup reintroduced the description substring match" >&2
    return 1
  }
}

@test "audit dedup treats cancelled as not-open (symmetry with the block-check)" {
  # Step 1b excludes done AND cancelled. If Step 5 only excludes done, a
  # descoped PBI suppresses its class forever and can never be a REGRESSION.
  grep -q 'status != "done" and .status != "cancelled"' "$AUDIT_SKILL" || {
    echo "Step 5 open-match no longer excludes cancelled" >&2
    return 1
  }
}

@test "axes.md mandates the normalized identity form and byte-for-byte reuse" {
  grep -q 'REUSE, never re-mint' "$AXES" || {
    echo "axes.md identity field no longer mandates reuse of an existing key" >&2
    return 1
  }
  grep -q 'lower-case kebab' "$AXES" || {
    echo "axes.md identity field no longer states the normalization rule" >&2
    return 1
  }
}

@test "schema pattern and axes.md agree that paths are not identities" {
  run jq -r '.properties.items.items.properties.audit_identity.pattern' "$SCHEMA"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  grep -q 'NEVER a file path' "$AXES" || {
    echo "axes.md no longer forbids path-shaped identities that the schema rejects" >&2
    return 1
  }
}

@test "the DOCS batch has a fixed identity so batches cannot pile up" {
  grep -q 'docs-drift::stale-references' "$AUDIT_SKILL" || {
    echo "the DOCS batch no longer declares its fixed identity" >&2
    return 1
  }
}
