#!/usr/bin/env bats
# tests/lint/audit-ledger-wiring.bats — the class ledger must stay wired into
# the audit's instruction surface.
#
# `.scrum/audit-ledger.json` only pays for itself if four links hold at once:
# the auditors are handed it (identities + scope), the SM transcribes every
# class into it BEFORE the report, the filed PBIs link back to their class,
# and each AC declares what its zero-check does not close. Prose drifts
# silently and each broken link restores a measured failure — identity drift,
# occurrence loss through prose, a class recorded closed by a check narrower
# than the class. Pin them here.
#
# Wrapper internals are NOT pinned here: the SSOT for the flags and refusals
# is `.scrum/scripts/update-audit-ledger.sh --help`. This lint only checks
# that the skill calls subcommands that exist in the frozen list.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AUDIT="${PROJECT_ROOT}/skills/codebase-audit/SKILL.md"
  AXES="${PROJECT_ROOT}/skills/codebase-audit/references/axes.md"
  CROSS_REVIEW="${PROJECT_ROOT}/skills/cross-review/SKILL.md"

  # Frozen CLI surface of scripts/scrum/update-audit-ledger.sh. A skill that
  # names anything else is instructing a call that cannot run.
  FROZEN_SUBCOMMANDS=(
    upsert-class add-occurrences set-status add-exclusion
    link-pbi confirm-seen register-detector list
  )
  # The calls this skill must actually make.
  REQUIRED_SUBCOMMANDS=(
    upsert-class add-occurrences link-pbi set-status add-exclusion
    register-detector
  )
}

# --- predicates (run against the real skill AND a negative fixture) ---------

section() {  # <file> <start-regex> <end-regex>
  awk -v s="$2" -v e="$3" '$0 ~ s {f=1} $0 ~ e {f=0} f' "$1"
}

step1_names_ledger() {
  section "$1" '^### Step 1 —' '^### Step 2 —' | grep -qF 'audit-ledger.json'
}

step3a_exists() {
  grep -q '^### Step 3a —' "$1"
}

# The whole point of Step 3a: the ledger write precedes the report write.
step3a_transcribes_before_report() {
  local body occ rep
  body="$(section "$1" '^### Step 3a —' '^### Step 4 —')"
  occ="$(printf '%s\n' "$body" | grep -nF 'add-occurrences' | head -1 | cut -d: -f1)"
  rep="$(printf '%s\n' "$body" | grep -nF 'cat > "$REPORT" <<' | head -1 | cut -d: -f1)"
  [ -n "$occ" ] || return 1
  [ -n "$rep" ] || return 1
  [ "$occ" -lt "$rep" ]
}

ac_template_declares_residue() {
  grep -qF 'Not closed by this check' "$1"
}

scope_table_covers_every_status() {
  local body st
  body="$(section "$1" '^### Step 1 —' '^### Step 2 —')"
  for st in open sweeping guarded closed accepted; do
    printf '%s\n' "$body" | grep -qF "\`${st}\`" || return 1
  done
}

strict_rule_pins_transcription() {
  local body flat
  body="$(section "$1" '^## Strict Rules' '^## Exit Criteria')"
  flat="$(printf '%s\n' "$body" | tr '\n' ' ' | tr -s ' ')"
  printf '%s' "$flat" | grep -qF 'audit-ledger.json' || return 1
  printf '%s' "$flat" | grep -qF 'in Step 3a — **before** `$REPORT` is written' || return 1
  printf '%s' "$flat" | grep -qF 'byte-for-byte' || return 1
}

used_subcommands() {
  grep -oE 'update-audit-ledger\.sh[[:space:]]+[a-z][a-z-]*' "$1" \
    | sed -E 's/^.*[[:space:]]//' | sort -u
}

unknown_subcommands() {
  local sc known f
  while IFS= read -r sc; do
    [ -n "$sc" ] || continue
    known=0
    for f in "${FROZEN_SUBCOMMANDS[@]}"; do
      [ "$sc" = "$f" ] && known=1
    done
    [ "$known" -eq 1 ] || printf '%s\n' "$sc"
  done <<EOF
$(used_subcommands "$1")
EOF
}

# --- the real instruction surface ------------------------------------------

@test "Step 1 read set hands the auditors the ledger" {
  step1_names_ledger "$AUDIT" || {
    echo "Step 1 read set no longer names .scrum/audit-ledger.json" >&2
    return 1
  }
}

@test "Step 1 scope table names all five ledger statuses" {
  # A missing status is an auditor silently guessing whether a class is
  # still theirs — the guarded/closed distinction is the whole G-2 premise.
  scope_table_covers_every_status "$AUDIT" || {
    echo "Step 1 scope table no longer covers open/sweeping/guarded/closed/accepted" >&2
    return 1
  }
}

@test "Step 1 tells the auditor to cite dec_id when disputing an exclusion" {
  local body
  body="$(section "$AUDIT" '^### Step 1 —' '^### Step 2 —')"
  printf '%s\n' "$body" | grep -qF 'exclusions[]' || {
    echo "Step 1 no longer hands the per-occurrence exclusion set" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -qF 'dec_id' || {
    echo "Step 1 no longer requires the dec_id citation when disputing a waiver" >&2
    return 1
  }
}

@test "Step 3a exists between Step 3 and Step 4" {
  step3a_exists "$AUDIT" || {
    echo "the mechanical transcription step (Step 3a) is gone" >&2
    return 1
  }
  local l3 l3a l4
  l3="$(grep -n '^### Step 3 —' "$AUDIT" | head -1 | cut -d: -f1)"
  l3a="$(grep -n '^### Step 3a —' "$AUDIT" | head -1 | cut -d: -f1)"
  l4="$(grep -n '^### Step 4 —' "$AUDIT" | head -1 | cut -d: -f1)"
  [ "$l3" -lt "$l3a" ] && [ "$l3a" -lt "$l4" ] || {
    echo "Step 3a is not between Step 3 and Step 4 (${l3}/${l3a}/${l4})" >&2
    return 1
  }
}

@test "Step 3a transcribes occurrences before the report heredoc" {
  # Reversed order is the measured failure: the report becomes the transport
  # and the occurrence list is what gets lost.
  step3a_transcribes_before_report "$AUDIT" || {
    echo "Step 3a no longer calls add-occurrences before writing \$REPORT" >&2
    return 1
  }
}

@test "Step 3a writes its transcription artifact inside the guard carve-out" {
  local body
  body="$(section "$AUDIT" '^### Step 3a —' '^### Step 4 —')"
  printf '%s\n' "$body" | grep -qF '.scrum/reviews/audit-occurrences-s' || {
    echo "Step 3a no longer persists the occurrence sets under .scrum/reviews/" >&2
    return 1
  }
}

@test "the class AC template declares what its zero-check does not close" {
  ac_template_declares_residue "$AUDIT" || {
    echo "the AC template lost the mandatory 'Not closed by this check:' line" >&2
    return 1
  }
}

@test "Step 5 links the filed PBI to its class with a role" {
  local body
  body="$(section "$AUDIT" '^### Step 5 —' '^### Step 6 —')"
  printf '%s\n' "$body" | grep -qF -- '--role sweep' || {
    echo "Step 5 no longer links the filed class PBI with --role sweep" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -qF -- '--status sweeping' || {
    echo "Step 5 no longer moves the class to sweeping once it has a PBI" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -qF -- '--role detector' || {
    echo "Step 5 lost the detector half of the issuance pair" >&2
    return 1
  }
}

@test "Step 5 re-opens the class on a REGRESSION instead of only filing" {
  local body
  body="$(section "$AUDIT" '^### Step 5 —' '^### Step 6 —')"
  printf '%s\n' "$body" | grep -qF -- '--status open' || {
    echo "the [REGRESSION] path no longer returns the class to open" >&2
    return 1
  }
}

@test "a suppressing verdict is recorded on the class with its dec_id" {
  grep -qF -- '--status accepted --dec-id' "$AUDIT" || {
    echo "a PO defer/reject no longer sets the class to accepted with its dec_id" >&2
    return 1
  }
  grep -qF -- 'add-exclusion' "$AUDIT" || {
    echo "the per-occurrence waiver path (add-exclusion) is gone" >&2
    return 1
  }
}

@test "a Strict Rule pins transcription-before-report and byte-for-byte reuse" {
  strict_rule_pins_transcription "$AUDIT" || {
    echo "Strict Rules no longer pin the ledger-before-report ordering" >&2
    return 1
  }
}

@test "every wrapper subcommand the skill names exists in the frozen list" {
  local unknown
  unknown="$(unknown_subcommands "$AUDIT")"
  [ -z "$unknown" ] || {
    echo "codebase-audit calls update-audit-ledger.sh subcommands that do not exist:" >&2
    echo "$unknown" >&2
    return 1
  }
  local want
  for want in "${REQUIRED_SUBCOMMANDS[@]}"; do
    used_subcommands "$AUDIT" | grep -qx "$want" || {
      echo "codebase-audit no longer calls '$want'" >&2
      return 1
    }
  done
}

@test "the skill points at the wrapper and detector contract instead of restating them" {
  grep -qF 'update-audit-ledger.sh --help' "$AUDIT" || {
    echo "the skill no longer points at the wrapper for its subcommand signatures" >&2
    return 1
  }
  grep -qF 'references/detectors.md' "$AUDIT" || {
    echo "the skill no longer points at the detector contract" >&2
    return 1
  }
}

@test "axes.md makes the ledger the identity source of truth" {
  grep -qF 'audit-ledger.json' "$AXES" || {
    echo "axes.md identity field no longer names the ledger" >&2
    return 1
  }
  grep -q 'REUSE, never re-mint' "$AXES" || {
    echo "axes.md identity field no longer mandates reuse" >&2
    return 1
  }
  grep -qF 'byte-for-byte' "$AXES" || {
    echo "axes.md no longer requires byte-for-byte reuse of an existing identity" >&2
    return 1
  }
}

@test "axes.md gives the auditor the exclusion set and the dec_id dispute route" {
  grep -qF 'exclusions[]' "$AXES" || {
    echo "axes.md no longer tells the auditor about per-occurrence exclusions" >&2
    return 1
  }
  grep -qF 'dec_id' "$AXES" || {
    echo "axes.md no longer requires citing dec_id when disputing an exclusion" >&2
    return 1
  }
}

@test "cross-review hands the ledger to the audit it invokes" {
  grep -qF '.scrum/audit-ledger.json' "$CROSS_REVIEW" || {
    echo "cross-review no longer lists the ledger among the audit's inputs" >&2
    return 1
  }
}

# --- negative fixture: the predicates must actually be able to fail --------

@test "every predicate fails on a fixture that breaks it" {
  local fx="${BATS_TEST_TMPDIR}/bad-SKILL.md"
  cat > "$fx" <<'FIXTURE'
### Step 1 — Assemble the shared read set

Collect the PBI summary. No ledger here.

| status | auditor scope |
|---|---|
| `open` | in scope |

### Step 2 — Announce, spawn the 4 auditors, wait

### Step 3 — Synthesize + dedup + classify → report

### Step 3a — Transcribe the classes into the ledger, then write the report

```bash
cat > "$REPORT" <<'MD'
MD
.scrum/scripts/update-audit-ledger.sh add-occurrences --identity x --from f
.scrum/scripts/update-audit-ledger.sh set-severity --identity x --severity high
```

### Step 4 — Route findings (PO)

### Step 5 — Route the spec verdict, then file PBIs

## Strict Rules

- Nothing is pinned here.

## Exit Criteria
FIXTURE

  ! step1_names_ledger "$fx" || {
    echo "step1_names_ledger passed on a fixture with no ledger" >&2; return 1; }
  ! scope_table_covers_every_status "$fx" || {
    echo "scope_table_covers_every_status passed on a one-row table" >&2; return 1; }
  ! step3a_transcribes_before_report "$fx" || {
    echo "step3a_transcribes_before_report passed with the report written first" >&2; return 1; }
  ! ac_template_declares_residue "$fx" || {
    echo "ac_template_declares_residue passed with no residue line" >&2; return 1; }
  ! strict_rule_pins_transcription "$fx" || {
    echo "strict_rule_pins_transcription passed on an empty Strict Rules section" >&2; return 1; }
  # Step 3a heading alone must not be mistaken for a wired Step 3a.
  step3a_exists "$fx" || {
    echo "fixture is malformed: it should still carry a Step 3a heading" >&2; return 1; }
  [ "$(unknown_subcommands "$fx")" = "set-severity" ] || {
    echo "unknown_subcommands did not flag the invented subcommand; got:" >&2
    unknown_subcommands "$fx" >&2
    return 1
  }
}
