#!/usr/bin/env bash
# scripts/scrum/lib/git-guards.sh — pre-flight git invariants shared by
# merge-pbi.sh / merge-main-into-pbi.sh / safe-switch-to-main.sh.
# Requires lib/errors.sh sourced first.

if [ "${_SCRUM_GIT_GUARDS_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi
_SCRUM_GIT_GUARDS_SH_LOADED=1

# assert_scrum_untracked
# Refuse to proceed when `.scrum/` is tracked in the main repo's git index.
# Branch switches with tracked `.scrum/` silently delete state files that
# only exist on the current branch — the recovery instruction below is the
# same as the inline checks this helper replaces.
assert_scrum_untracked() {
  if [ -n "$(git ls-files .scrum/ 2>/dev/null)" ]; then
    fail E_INVALID_ARG ".scrum/ is tracked in git — runtime state must stay untracked. Recover with: git rm -r --cached .scrum/ && echo '.scrum/' >> .gitignore"
  fi
}

# assert_clean_worktree [-C <dir>] [hint]
# Refuse if the (specified) worktree has staged/modified/deleted tracked-file
# changes. Untracked files are ignored — `.scrum/` is untracked by design.
# Without `-C <dir>`, checks the current worktree. `hint` is an optional
# trailing clause appended after " — " to guide the caller's recovery.
assert_clean_worktree() {
  local dir="" hint=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) [ "$#" -ge 2 ] || fail E_INVALID_ARG "assert_clean_worktree -C requires a directory"
          dir="$2"; shift 2 ;;
      *)  hint="$1"; shift ;;
    esac
  done
  local dirty
  if [ -n "$dir" ]; then
    dirty="$(git -C "$dir" status --porcelain | grep -v '^??' || true)"
  else
    dirty="$(git status --porcelain | grep -v '^??' || true)"
  fi
  if [ -n "$dirty" ]; then
    local where="${dir:-working tree}"
    fail E_INVALID_ARG "$where has uncommitted tracked changes${hint:+ — $hint}"
  fi
}

# merge_colliding_dirt <branch>
# Merge-scoped variant of the clean-tree check. Echoes (newline-separated) the
# tracked working-tree dirty paths in the CURRENT worktree that the impending
# merge of <branch> would ALSO modify — i.e. the paths for which the merge is
# genuinely unsafe (git's own merge would refuse to overwrite them).
#
# Why this exists: a blanket "main must be 100% clean" check strands an
# unrelated PBI merge behind working-tree drift the merge never touches (a
# leaked catalog spec, a framework-file edit on a disjoint path). Such drift
# recurred across real autonomous runs and halted whole Sprints. Dirt that is
# disjoint from the merge's file set cannot be clobbered by `git merge`, so it
# should not block the merge.
#
# Output contract (so callers can branch without re-running git):
#   (empty)        — tree clean, or all dirt is disjoint from the merge set
#   __NO_BASE__    — no merge base with <branch>; caller should fall back to
#                    a strict refusal (cannot scope safely)
#   <paths…>       — the colliding tracked paths (merge is unsafe)
#
# Untracked files are always ignored (.scrum/ is untracked by design). The
# dirty set is taken from `git diff --name-only HEAD` (tracked changes vs
# HEAD, staged + unstaged), which yields clean newline-separated paths.
merge_colliding_dirt() {
  local branch="$1"
  local dirty
  dirty="$(git diff --name-only HEAD 2>/dev/null || true)"
  [ -z "$dirty" ] && return 0
  local base
  base="$(git merge-base HEAD "$branch" 2>/dev/null || true)"
  if [ -z "$base" ]; then
    printf '__NO_BASE__\n'
    return 0
  fi
  local merge_set
  merge_set="$(git diff --name-only "$base" "$branch" 2>/dev/null || true)"
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s\n' "$merge_set" | grep -Fxq -- "$f"; then
      printf '%s\n' "$f"
    fi
  done <<EOF
$dirty
EOF
}
