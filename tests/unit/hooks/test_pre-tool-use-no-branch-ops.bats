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
