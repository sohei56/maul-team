#!/usr/bin/env bats
# Regression tests for macapp/scripts/bump-tap.sh — the Homebrew tap bump run
# by release.yml (distribution channel ③).
#
# Guards the first-push bug: `git diff` ignores untracked files and
# `commit -am` never stages a new file, so pushing the cask to an empty tap
# (or a tap that doesn't have the cask yet) silently no-op'd. The fix stages
# the cask first and diffs the index.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/macapp/scripts/bump-tap.sh"
  TAG="v9.9.9-test"
  VERSION="9.9.9-test"
  # The script reads the checksum from macapp/build/ (gitignored). Seed it.
  BUILD_DIR="$PROJECT_ROOT/macapp/build"
  SHA_FILE="$BUILD_DIR/MaulTeam-${VERSION}.dmg.sha256"
  SEEDED_SHA="0000000000000000000000000000000000000000000000000000000000000abc"
  mkdir -p "$BUILD_DIR"
  printf '%s  MaulTeam-%s.dmg\n' "$SEEDED_SHA" "$VERSION" > "$SHA_FILE"
  # A local bare repo standing in for the (empty) GitHub tap.
  BARE="$BATS_TEST_TMPDIR/tap.git"
  git init --bare -b main "$BARE" >/dev/null
}

teardown() {
  rm -f "$SHA_FILE"
}

run_bump() {
  # Point the script's internal `mktemp -d` at a writable temp (BATS_TEST_TMPDIR)
  # so the test is independent of the ambient TMPDIR.
  run env TMPDIR="$BATS_TEST_TMPDIR" TAG="$TAG" HOMEBREW_TAP_TOKEN=dummy \
    TAP_REPO="test/tap" TAP_CLONE_URL="$BARE" bash "$SCRIPT"
}

@test "bump-tap: first push to an EMPTY tap creates Casks/maul-team.rb" {
  run_bump
  [ "$status" -eq 0 ]
  # The cask must actually land in the remote (this is the bug the fix closes).
  run git -C "$BARE" show "main:Casks/maul-team.rb"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'version "9.9.9-test"'
  echo "$output" | grep -q "sha256 \"$SEEDED_SHA\""
}

@test "bump-tap: re-running with the same version is an idempotent no-op" {
  run_bump
  [ "$status" -eq 0 ]
  before="$(git -C "$BARE" rev-parse main)"
  run_bump
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "nothing to push"
  after="$(git -C "$BARE" rev-parse main)"
  [ "$before" = "$after" ]
}

@test "bump-tap: a changed checksum pushes an update commit" {
  run_bump
  [ "$status" -eq 0 ]
  before="$(git -C "$BARE" rev-parse main)"
  # Change the rendered content by changing the checksum.
  printf '%s  MaulTeam-%s.dmg\n' \
    "0000000000000000000000000000000000000000000000000000000000000def" \
    "$VERSION" > "$SHA_FILE"
  run_bump
  [ "$status" -eq 0 ]
  after="$(git -C "$BARE" rev-parse main)"
  [ "$before" != "$after" ]
  run git -C "$BARE" show "main:Casks/maul-team.rb"
  echo "$output" | grep -q "000000000000000000000000000000000000000000000000000000000000 0def" || \
    echo "$output" | grep -q "0000000000000000000000000000000000000000000000000000000000000def"
}
