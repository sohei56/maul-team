#!/usr/bin/env bats
# Issue #93 (2), decision A: the state guard's Bash command-text scan is
# a guardrail against honest mistakes, NOT a sandbox against
# obfuscation. Text-scanning a shell command diverges — every closed
# hole opens a larger one, and each hardening pass over-blocks
# legitimate commands. The structural Write/Edit `file_path` checks are
# the real protection. So the Bash pattern set is frozen, and this lint
# pins its inventory: a "just one more regex" change fails here and has
# to be argued as a design decision instead of landing as a fix.

# Matchers in the guard's `Bash)` case arm: every `sgrep '<regex>'` call
# plus every `[[ "$cmd" =~ ... ]]` test (4 + 6 at the freeze).
# raise only with a design decision (Issue #93 (2), decision A)
EXPECTED_BASH_MATCHERS=10

# Blocking detectors in that arm: `block_unless_all_exempt` invocations
# (redirect/tee/sponge, mv/cp, in-place edit + truncate, rm/unlink).
# Counted separately so a new detector written with some other matcher
# shape (a `case`, a `grep -q`) still trips the freeze.
# raise only with a design decision (Issue #93 (2), decision A)
EXPECTED_BASH_DETECTORS=4

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="${PROJECT_ROOT}/hooks/pre-tool-use-scrum-state-guard.sh"
}

# Print the `Bash)` case arm of guard file "$1" with comment lines
# dropped: from the arm label to its terminating `;;`. Comments are
# stripped so prose *about* a pattern is never counted as one.
_bash_branch() {
  awk '/^[[:space:]]*Bash\)[[:space:]]*$/ { f = 1 }
       f && !/^[[:space:]]*#/ { print }
       f && /^[[:space:]]*;;[[:space:]]*$/ { exit }' "$1"
}

_count_matchers() {
  local branch sgreps regexes
  branch="$(_bash_branch "$1")"
  sgreps="$(printf '%s\n' "$branch" | grep -c "sgrep '" || true)"
  regexes="$(printf '%s\n' "$branch" | grep -cF '[[ "$cmd" =~' || true)"
  echo $((sgreps + regexes))
}

_count_detectors() {
  _bash_branch "$1" | grep -c 'block_unless_all_exempt' || true
}

@test "guard Bash branch is extractable (anchor still matches)" {
  # Without this, a renamed case arm would silently yield an empty
  # branch and the counts below would compare 0 against 0.
  run _bash_branch "$GUARD"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *'block_unless_all_exempt'* ]]
}

@test "Bash matcher count is frozen at the decided inventory" {
  local n
  n="$(_count_matchers "$GUARD")"
  [ "$n" -eq "$EXPECTED_BASH_MATCHERS" ] || {
    echo "Bash matchers: $n, frozen at $EXPECTED_BASH_MATCHERS."
    echo "Issue #93 (2) decision A: the pattern set is frozen; a change"
    echo "is a design decision, not a hardening PR (CLAUDE.md § Git"
    echo "workflow)."
    false
  }
}

@test "Bash blocking-detector count is frozen at the decided inventory" {
  local n
  n="$(_count_detectors "$GUARD")"
  [ "$n" -eq "$EXPECTED_BASH_DETECTORS" ] || {
    echo "Bash detectors: $n, frozen at $EXPECTED_BASH_DETECTORS."
    echo "Issue #93 (2) decision A: adding a blocking branch is a design"
    echo "decision, not a hardening PR (CLAUDE.md § Git workflow)."
    false
  }
}

@test "lint rejects a guard with one extra Bash matcher" {
  local bad="${BATS_TEST_TMPDIR}/guard-extra-matcher.sh"
  awk '/truncate\[\[:space:\]\]/ {
         print "       || [[ \"$cmd\" =~ python[[:space:]]+-c ]] \\" }
       { print }' "$GUARD" > "$bad"
  grep -qF 'python[[:space:]]+-c' "$bad"

  [ "$(_count_matchers "$bad")" -eq $((EXPECTED_BASH_MATCHERS + 1)) ]
  [ "$(_count_matchers "$bad")" -ne "$EXPECTED_BASH_MATCHERS" ]
  # The extra matcher adds no detector — the two counts are independent.
  [ "$(_count_detectors "$bad")" -eq "$EXPECTED_BASH_DETECTORS" ]
}

@test "lint rejects a guard with one extra blocking detector" {
  local bad="${BATS_TEST_TMPDIR}/guard-extra-detector.sh"
  awk '{ print }
       /block_unless_all_exempt "\$rm_dests"/ {
         print "    [ -n \"$x_dests\" ] && block_unless_all_exempt \\" }' \
    "$GUARD" > "$bad"
  grep -qF '"$x_dests"' "$bad"

  [ "$(_count_detectors "$bad")" -eq $((EXPECTED_BASH_DETECTORS + 1)) ]
  [ "$(_count_detectors "$bad")" -ne "$EXPECTED_BASH_DETECTORS" ]
}

@test "guard header states the freeze and cites the decision" {
  local header
  header="$(sed -n '1,60p' "$GUARD")"
  printf '%s' "$header" | grep -qF 'FROZEN'
  printf '%s' "$header" | grep -qF 'Issue #93 (2), decision A'
  printf '%s' "$header" | grep -qF 'CLAUDE.md § Git workflow'
  printf '%s' "$header" | grep -qF 'not a hardening PR'
}

@test "CLAUDE.md records the same frozen-pattern scope" {
  local doc
  doc="$(tr '\n' ' ' < "${PROJECT_ROOT}/CLAUDE.md" | tr -s ' ')"
  printf '%s' "$doc" | grep -qF 'That pattern set is frozen'
  printf '%s' "$doc" | grep -qF 'Issue #93 (2), decision A'
}
