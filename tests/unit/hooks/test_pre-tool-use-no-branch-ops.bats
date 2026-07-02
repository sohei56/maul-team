#!/usr/bin/env bats
setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  HOOK="$PROJECT_ROOT/hooks/pre-tool-use-no-branch-ops.sh"
}

@test "blocks: git checkout -b" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git checkout -b foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git switch -c" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch -c foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git branch newname" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git branch newname\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: direct git merge" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git merge other\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git push" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git rebase" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C merge" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 merge main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git --git-dir rebase" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --git-dir=.git --work-tree=. rebase main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -c branch create" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -c color.ui=always branch feature-x\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "allows: git status" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git log --oneline" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log --oneline\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: branch op via .scrum/scripts/ wrapper" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\".scrum/scripts/merge-pbi.sh pbi-001\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks: non-Bash tools pass through" {
  run bash -c "echo '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"x\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

# `git -C <path> <verb>` form: prior regex only matched `git <verb>` and
# silently let raw merge/push/rebase from worktrees through.
@test "blocks: git -C wt checkout -b" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 checkout -b foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C wt switch -c" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 switch -c foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C wt branch newname" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 branch newname\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C wt merge" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 merge other\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C wt push" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 push origin foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git -C wt rebase" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 rebase main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "allows: git -C wt status" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C .scrum/worktrees/pbi-001 status\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks: git --git-dir=.git merge" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --git-dir=.git merge other\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: git --work-tree=. push" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git --work-tree=. push origin main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

# Read-only / recovery helpers that share a prefix with blocked verbs.
@test "allows: git merge-base" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git merge-base main HEAD\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git mergetool" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git mergetool\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git rebase --abort" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase --abort\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git rebase --continue" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase --continue\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "allows: git rebase --skip" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase --skip\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks: git rebase -i HEAD~3" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git rebase -i HEAD~3\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

# Compound-command bypass regression: a blocked verb hidden behind a shell
# statement boundary must still be caught segment-by-segment.
@test "blocks: cd x && git merge foo (compound &&)" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd x && git merge foo\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: true; git push origin main (compound ;)" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true; git push origin main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

@test "blocks: echo | git rebase main (pipe)" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo | git rebase main\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

# The wrapper allowlist is not inherited by compound segments: a lone wrapper
# call is allowed, but a wrapper followed by a blocked git verb still blocks.
@test "allows: bash .scrum/scripts/merge-pbi.sh wrapper" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash .scrum/scripts/merge-pbi.sh pbi-001\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}

@test "blocks: .scrum/scripts/merge-pbi.sh pbi-001 && git push" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\".scrum/scripts/merge-pbi.sh pbi-001 && git push\"}}' | $HOOK"
  [ "$status" -ne 0 ]
}

# A compound command whose segments are all benign still passes.
@test "allows: cd x && git status (compound, no blocked verb)" {
  run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd x && git status\"}}' | $HOOK"
  [ "$status" -eq 0 ]
}
