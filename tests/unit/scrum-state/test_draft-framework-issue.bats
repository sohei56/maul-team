#!/usr/bin/env bats
# tests/unit/scrum-state/test_draft-framework-issue.bats
#
# The sanitizer is the whole risk surface of the upstream leg: everything it
# lets through is published to a public repo the moment a human says yes. So
# both directions are pinned — what it must reject (target identifiers, home
# paths, project-derived tokens, operator-declared domain terms) and what it
# must NOT reject (placeholder ids, the framework's own name, short accidental
# substrings), because an over-blocking sanitizer is routed around rather than
# fixed.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  TEST_TMP="$(mktemp -d /tmp/claude/draft-fw.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/draft-fw.XXXXXX")"
  # Work inside a distinctively-named child dir: `basename $PWD` is one of the
  # derived project tokens, so the name must be one no other fixture text uses.
  TARGET="$TEST_TMP/zorblatt"
  mkdir -p "$TARGET/.scrum"
  cd "$TARGET" || exit 1
  SCRIPT="$PROJECT_ROOT/scripts/scrum/draft-framework-issue.sh"
  DRAFT=".scrum/framework-issues/sprint-001-01.md"
  META=".scrum/framework-issues/sprint-001-01.meta"
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# draft [extra flags...] — the five required text fields, all leak-free.
# Any flag passed here overrides nothing; callers add flags to extend, and
# pass their own --title/--why/... only in the rejection tests (last wins).
draft() {
  "$SCRIPT" \
    --sprint sprint-001 \
    --identity retrospective::no-upstream-path \
    --title "Retrospective cannot report a framework defect upstream" \
    --summary "The ceremony records improvements locally and stops there." \
    --where ".claude/skills/retrospective/SKILL.md (framework source: skills/retrospective/SKILL.md)" \
    --why "A framework defect found during the ceremony is never seen by the maintainer, so it recurs every cycle." \
    --improvement "Add a drafting step that emits a sanitized issue body." \
    "$@"
}

# quiet_draft — same, with the advisory `gh` line dropped. `run` merges stderr
# into $output, so stdout-exactness assertions need the redirect INSIDE the
# command under test.
quiet_draft() {
  draft "$@" 2>/dev/null
}

# --- Happy path -----------------------------------------------------------

@test "draft-framework-issue: creates body + sidecar and prints the path" {
  run quiet_draft
  [ "$status" -eq 0 ]
  [ "$output" = "$DRAFT" ]
  [ -f "$DRAFT" ]
  [ -f "$META" ]

  grep -q '^# Retrospective cannot report a framework defect upstream$' "$DRAFT"
  grep -q '^## Summary$' "$DRAFT"
  grep -q '^## Where in the framework$' "$DRAFT"
  grep -q '^## Why it is a problem$' "$DRAFT"
  grep -q '^## Proposed improvement$' "$DRAFT"
  grep -q '^## Observed frequency$' "$DRAFT"
  grep -q '^Observed 1 time(s) in one target project\.$' "$DRAFT"

  run grep -c '^occurrences=1$' "$META"
  [ "$output" = "1" ]
  run grep -c '^status=draft$' "$META"
  [ "$output" = "1" ]
  run grep -c '^occurrence_sprints=sprint-001$' "$META"
  [ "$output" = "1" ]
}

@test "draft-framework-issue: the postable body carries no Sprint id" {
  draft 2>/dev/null
  # The whole reason for the body/.meta split — the sidecar keeps it instead.
  run grep -q 'sprint-001' "$DRAFT"
  [ "$status" -ne 0 ]
  run grep -q '^sprint_id=sprint-001$' "$META"
  [ "$status" -eq 0 ]
}

@test "draft-framework-issue: stderr carries a runnable gh command for the default origin" {
  run bash -c "cd '$TARGET' && '$SCRIPT' \
    --sprint sprint-001 --identity retrospective::no-upstream-path \
    --title 'A framework defect has no upstream path' \
    --where '.claude/skills/retrospective/SKILL.md' \
    --why 'It recurs every cycle.' \
    --improvement 'Emit a sanitized issue body.' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh issue create --repo sohei56/maul-team"* ]]
  [[ "$output" == *"--body-file .scrum/framework-issues/sprint-001-01.md"* ]]
}

@test "draft-framework-issue: --summary is optional and its section is then absent" {
  run bash -c "cd '$TARGET' && '$SCRIPT' \
    --sprint sprint-001 --identity retrospective::no-upstream-path \
    --title 'A framework defect has no upstream path' \
    --where '.claude/skills/retrospective/SKILL.md' \
    --why 'It recurs every cycle.' \
    --improvement 'Emit a sanitized issue body.' 2>/dev/null"
  [ "$status" -eq 0 ]
  run grep -q '^## Summary$' "$DRAFT"
  [ "$status" -ne 0 ]
  run grep -q '^## Why it is a problem$' "$DRAFT"
  [ "$status" -eq 0 ]
}

# --- Rejections (six classes) --------------------------------------------

@test "draft-framework-issue: rejects a PBI id" {
  run draft --why "The pipeline stalled on pbi-007 and never resumed."
  [ "$status" -eq 64 ]
  [[ "$output" == *"--why"* ]]
  [[ "$output" == *"pbi-007"* ]]
  [ ! -f "$DRAFT" ]
}

@test "draft-framework-issue: rejects a Sprint id" {
  run draft --title "Cross-review failed again in sprint-12"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--title"* ]]
  [[ "$output" == *"sprint-12"* ]]
}

@test "draft-framework-issue: rejects imp- / dec- / us- ids too" {
  run draft --improvement "Link the entry to imp-0042 as the change-process does."
  [ "$status" -eq 64 ]
  [[ "$output" == *"imp-0042"* ]]

  run draft --improvement "Reference dec-0009 in the rationale."
  [ "$status" -eq 64 ]
  [[ "$output" == *"dec-0009"* ]]

  run draft --improvement "The walkthrough skipped us-014 entirely."
  [ "$status" -eq 64 ]
  [[ "$output" == *"us-014"* ]]
}

@test "draft-framework-issue: rejects a home-anchored absolute path" {
  run draft --where "/Users/alice/projects/thing/.claude/skills/retrospective"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--where"* ]]
  [[ "$output" == *"home-anchored path"* ]]
}

@test "draft-framework-issue: rejects a token derived from the project directory name" {
  run draft --why "The zorblatt team hit this twice."
  [ "$status" -eq 64 ]
  [[ "$output" == *"--why"* ]]
  [[ "$output" == *"project-derived token"* ]]
  [[ "$output" == *"zorblatt"* ]]
}

@test "draft-framework-issue: rejects a token derived from a git remote" {
  git init -q .
  git remote add origin https://github.com/acme-corp/widgetron.git
  run draft --improvement "Teach the wrapper about widgetron's layout."
  [ "$status" -eq 64 ]
  [[ "$output" == *"widgetron"* ]]

  run draft --improvement "Ask the acme-corp maintainers first."
  [ "$status" -eq 64 ]
  [[ "$output" == *"acme-corp"* ]]
}

@test "draft-framework-issue: rejects an operator-declared domain term" {
  printf '%s\n' '{"framework_issue":{"forbidden_tokens":["auction","order engine"]}}' \
    > .scrum/config.json
  run draft --why "The auction flow was blocked for a whole cycle."
  [ "$status" -eq 64 ]
  [[ "$output" == *"operator-declared domain term"* ]]
  [[ "$output" == *"auction"* ]]
}

@test "draft-framework-issue: reports every violation in one pass" {
  # Fail-fast would cost an autonomous run one round trip per leak.
  run draft \
    --title "Cross-review failed in sprint-12" \
    --why "Reproduced under /Users/alice/work and again on pbi-007."
  [ "$status" -eq 64 ]
  [[ "$output" == *"--title"* ]]
  [[ "$output" == *"--why"* ]]
  [[ "$output" == *"sprint-12"* ]]
  [[ "$output" == *"pbi-007"* ]]
  [[ "$output" == *"/Users/alice"* ]]
  # And the recipe that tells the author what to write instead.
  [[ "$output" == *"Keep the count, drop the identifier"* ]]
}

@test "draft-framework-issue: rejects a leaked identity, not just the prose" {
  run draft --identity sprint-12::stalled-pipeline
  [ "$status" -eq 64 ]
  [[ "$output" == *"--identity"* ]]
}

# --- Non-rejections (over-blocking regression guards) --------------------

@test "draft-framework-issue: accepts the framework's own placeholder ids" {
  run quiet_draft --why "The step names the item as pbi-NNN and the Sprint as sprint-NNN."
  [ "$status" -eq 0 ]
  [ -f "$DRAFT" ]
}

@test "draft-framework-issue: accepts naming the framework itself" {
  run quiet_draft --improvement "Fix it in maul-team's retrospective skill."
  [ "$status" -eq 0 ]
  [ -f "$DRAFT" ]
}

@test "draft-framework-issue: a short accidental substring of the project name is not a token" {
  # "zor" is 3 chars — below the length floor, so it never becomes a token.
  run quiet_draft --why "The zor prefix collides with nothing here."
  [ "$status" -eq 0 ]
  [ -f "$DRAFT" ]
}

@test "draft-framework-issue: generic words are never derived as project tokens" {
  mkdir -p "$TEST_TMP/project/.scrum"
  run bash -c "cd '$TEST_TMP/project' && '$SCRIPT' \
    --sprint sprint-001 --identity retrospective::no-upstream-path \
    --title 'A framework defect has no upstream path' \
    --where '.claude/skills/retrospective/SKILL.md' \
    --why 'The project loses the finding at ceremony end.' \
    --improvement 'Emit a sanitized issue body.' 2>/dev/null"
  [ "$status" -eq 0 ]
}

# --- Identity dedup -------------------------------------------------------

@test "draft-framework-issue: a repeat identity bumps occurrences instead of drafting again" {
  draft 2>/dev/null
  run bash -c "cd '$TARGET' && '$SCRIPT' \
    --sprint sprint-002 --identity retrospective::no-upstream-path \
    --title 'Same failure, later Sprint' \
    --where '.claude/skills/retrospective/SKILL.md' \
    --why 'It happened again.' \
    --improvement 'Emit a sanitized issue body.' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "$DRAFT" ]

  run bash -c "ls .scrum/framework-issues/*.md | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  run grep -c '^occurrences=2$' "$META"
  [ "$output" = "1" ]
  run grep -c '^occurrence_sprints=sprint-001,sprint-002$' "$META"
  [ "$output" = "1" ]
  run grep -c '^Observed 2 time(s) in one target project\.$' "$DRAFT"
  [ "$output" = "1" ]
  # The first draft's wording stands; the bump does not re-render the body.
  run grep -q 'Same failure, later Sprint' "$DRAFT"
  [ "$status" -ne 0 ]
}

@test "draft-framework-issue: a repeat within the same Sprint does not duplicate the sprint list" {
  draft 2>/dev/null
  draft 2>/dev/null
  run grep -c '^occurrence_sprints=sprint-001$' "$META"
  [ "$output" = "1" ]
  run grep -c '^occurrences=2$' "$META"
  [ "$output" = "1" ]
}

@test "draft-framework-issue: a different identity gets its own numbered draft" {
  draft 2>/dev/null
  run bash -c "cd '$TARGET' && '$SCRIPT' \
    --sprint sprint-001 --identity merge-queue::silent-skip \
    --title 'The merge gate skips silently when unconfigured' \
    --where '.scrum/scripts/merge-pbi.sh' \
    --why 'A broken suite reaches main unnoticed.' \
    --improvement 'Escalate the WARN.' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = ".scrum/framework-issues/sprint-001-02.md" ]
}

# --- Self-hosting guard ---------------------------------------------------

@test "draft-framework-issue: refuses to run inside the framework repo (git remote)" {
  git init -q .
  git remote add origin git@github.com:sohei56/maul-team.git
  run draft
  [ "$status" -eq 64 ]
  [[ "$output" == *"framework itself"* ]]
  [ ! -f "$DRAFT" ]
}

@test "draft-framework-issue: refuses to run inside the framework repo (deploy stamp root)" {
  printf '{"framework_sha":"abc1234","framework_root":"%s"}\n' "$(pwd -P)" \
    > .scrum/deploy-stamp.json
  run draft
  [ "$status" -eq 64 ]
  [[ "$output" == *"framework itself"* ]]
}

# --- Deploy-stamp integration --------------------------------------------

@test "draft-framework-issue: records the deployed framework rev and origin" {
  printf '%s\n' '{"framework_sha":"abc1234def0","framework_origin":"someone/maul-team-fork","framework_root":"/elsewhere"}' \
    > .scrum/deploy-stamp.json
  run bash -c "cd '$TARGET' && '$SCRIPT' \
    --sprint sprint-001 --identity retrospective::no-upstream-path \
    --title 'A framework defect has no upstream path' \
    --where '.claude/skills/retrospective/SKILL.md' \
    --why 'It recurs every cycle.' \
    --improvement 'Emit a sanitized issue body.' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--repo someone/maul-team-fork"* ]]
  grep -q 'framework rev `abc1234def0`' "$DRAFT"
  run grep -c '^framework_sha=abc1234def0$' "$META"
  [ "$output" = "1" ]
}

# --- Agent-mode attention queue ------------------------------------------

@test "draft-framework-issue: agent mode queues one attention entry, deduped by draft path" {
  printf '%s\n' '{"po_mode":"agent"}' > .scrum/config.json
  draft 2>/dev/null
  [ -f .scrum/po/attention.md ]
  run grep -c -- "$DRAFT" .scrum/po/attention.md
  [ "$output" = "1" ]
  # Untagged: a pending draft must never block release_decision=go.
  run grep -q 'release-blocking' .scrum/po/attention.md
  [ "$status" -ne 0 ]

  draft 2>/dev/null
  run grep -c -- "$DRAFT" .scrum/po/attention.md
  [ "$output" = "1" ]
}

@test "draft-framework-issue: human mode writes no attention entry" {
  printf '%s\n' '{"po_mode":"human"}' > .scrum/config.json
  draft 2>/dev/null
  [ ! -f .scrum/po/attention.md ]
}

@test "draft-framework-issue: absent config defaults to human mode" {
  draft 2>/dev/null
  [ ! -f .scrum/po/attention.md ]
}

# --- --record-posted ------------------------------------------------------

@test "draft-framework-issue: --record-posted flips status and stores the url" {
  draft 2>/dev/null
  run "$SCRIPT" --record-posted "$DRAFT" --url "https://github.com/sohei56/maul-team/issues/91"
  [ "$status" -eq 0 ]
  [ "$output" = "$DRAFT" ]
  run grep -c '^status=posted$' "$META"
  [ "$output" = "1" ]
  run grep -c '^posted_url=https://github.com/sohei56/maul-team/issues/91$' "$META"
  [ "$output" = "1" ]
  # Bookkeeping survives the rewrite.
  run grep -c '^identity=retrospective::no-upstream-path$' "$META"
  [ "$output" = "1" ]
  run grep -c '^occurrences=1$' "$META"
  [ "$output" = "1" ]
}

@test "draft-framework-issue: --record-posted on an unknown draft fails E_FILE_MISSING" {
  run "$SCRIPT" --record-posted ".scrum/framework-issues/sprint-009-01.md" \
    --url "https://github.com/sohei56/maul-team/issues/91"
  [ "$status" -eq 67 ]
  [[ "$output" == *"no such draft"* ]]
}

@test "draft-framework-issue: --record-posted rejects a malformed url" {
  draft 2>/dev/null
  run "$SCRIPT" --record-posted "$DRAFT" --url "not-a-url"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --url"* ]]
  run grep -c '^status=draft$' "$META"
  [ "$output" = "1" ]
}

@test "draft-framework-issue: --record-posted requires --url" {
  draft 2>/dev/null
  run "$SCRIPT" --record-posted "$DRAFT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"requires --url"* ]]
}

# --- Argument validation --------------------------------------------------

@test "draft-framework-issue: rejects missing required flags" {
  run "$SCRIPT" --sprint sprint-001
  [ "$status" -eq 64 ]
  [[ "$output" == *"--identity required"* ]]
}

@test "draft-framework-issue: rejects a bad --sprint" {
  run draft --sprint nope
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --sprint"* ]]
}

@test "draft-framework-issue: rejects a malformed --identity" {
  run draft --identity "skills/retrospective/SKILL.md:94"
  [ "$status" -eq 64 ]
  [[ "$output" == *"bad --identity"* ]]
}

@test "draft-framework-issue: rejects an unknown flag" {
  run draft --force
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown flag"* ]]
}
