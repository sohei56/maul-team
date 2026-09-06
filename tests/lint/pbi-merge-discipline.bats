#!/usr/bin/env bats
# tests/lint/pbi-merge-discipline.bats — the Scrum Master is Delegate mode,
# but a failing merge is exactly where the temptation to inspect appears.
# Pin the merge-specific inspection prohibitions in the pbi-merge skill:
# no worktree reads/edits, no conflict-marker search, no project toolchain,
# no raw worktree git, and no delegating the inspection to an explorer.
# Prompt obligation, not a machine gate — so pin the wording that carries it.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SKILL="$PROJECT_ROOT/skills/pbi-merge/SKILL.md"
  # The prohibitions only bind if they sit inside § Strict Rules; a section
  # floating elsewhere in the file is not the rule.
  STRICT="$(awk '/^## Strict Rules/{f=1} f' "$SKILL" | tr '\n' ' ')"
}

@test "Forbidden Inspection Actions lives under Strict Rules" {
  printf '%s' "$STRICT" | grep -F -q '### Forbidden Inspection Actions'
}

@test "the section points at the general Delegate-mode rule instead of restating it" {
  printf '%s' "$STRICT" | grep -F -q '../../agents/scrum-master.md` § Scrum Master judgment'
}

@test "forbids reading or editing PBI worktree files" {
  printf '%s' "$STRICT" | grep -F -q 'Never read files under `.scrum/worktrees/<pbi-id>/`'
  printf '%s' "$STRICT" | grep -F -q 'never edit them to resolve a conflict'
  printf '%s' "$STRICT" | grep -F -q 'state.merge_failure.paths` is the only inspection artifact'
}

@test "forbids conflict-marker search" {
  printf '%s' "$STRICT" | grep -F -q 'Never search worktree files for conflict markers'
  printf '%s' "$STRICT" | grep -F -q '<<<<<<'
}

@test "forbids running the project toolchain to judge a failure" {
  printf '%s' "$STRICT" | grep -F -q 'Never run the project toolchain to judge a failure'
  printf '%s' "$STRICT" | grep -F -q 'python3 -c'
  printf '%s' "$STRICT" | grep -F -q 'source .venv/bin/activate'
  printf '%s' "$STRICT" | grep -F -q 'no test / lint / build command'
}

@test "forbids raw worktree git including read-only subcommands" {
  printf '%s' "$STRICT" | grep -F -q 'Never run raw `git -C .scrum/worktrees/<pbi-id>'
  printf '%s' "$STRICT" | grep -F -q 'read-only'
}

@test "closes the explorer escape hatch" {
  printf '%s' "$STRICT" | grep -F -q 'Never route around these by spawning a `scrum-explorer`'
  printf '%s' "$STRICT" | grep -F -q 'merge diagnosis stays with the assigned'
}

@test "routes a blocked action to the Developer rather than to nothing" {
  printf '%s' "$STRICT" | grep -F -q 'stop and SendMessage the Developer'
}

@test "the assertions are not vacuous (negative fixture)" {
  local fixture slice
  fixture="$BATS_TEST_TMPDIR/no-discipline.md"
  cat > "$fixture" <<'FIXTURE'
## Forbidden Inspection Actions

Inspect the worktree freely when a merge fails.

## Strict Rules

- Never invoke `git merge` directly. The wrapper handles all git
  operations.
FIXTURE
  slice="$(awk '/^## Strict Rules/{f=1} f' "$fixture" | tr '\n' ' ')"
  # A section placed outside § Strict Rules does not satisfy the check,
  # and the individual prohibitions are absent entirely.
  ! printf '%s' "$slice" | grep -F -q '### Forbidden Inspection Actions'
  ! printf '%s' "$slice" | grep -F -q 'Never read files under `.scrum/worktrees/<pbi-id>/`'
  ! printf '%s' "$slice" | grep -F -q 'Never run the project toolchain to judge a failure'
  ! printf '%s' "$slice" | grep -F -q 'Never route around these by spawning a `scrum-explorer`'
}
