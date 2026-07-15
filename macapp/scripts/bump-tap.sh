#!/usr/bin/env bash
#
# MaulTeam for Mac
# Copyright (c) 2026 sohei56. All rights reserved.
#
# Source-available; NOT covered by this repository's MIT License.
# See macapp/LICENSE for terms.
#
# bump-tap.sh — render the Homebrew cask for the current Release and push it to
# the personal tap (distribution channel ③). Runs in release.yml AFTER the DMG
# and its .sha256 are built and uploaded.
#
# Inputs (env):
#   TAG                 git tag of the Release, e.g. v1.4.3   (required)
#   HOMEBREW_TAP_TOKEN  PAT with push access to the tap repo  (required)
#   TAP_REPO            owner/repo of the tap (default sohei56/homebrew-tap)
#
# Reads macapp/build/MaulTeam-<version>.dmg.sha256 (produced by the Checksums
# step), renders macapp/homebrew/maul-team.rb, and commits it to the tap as
# Casks/maul-team.rb. No-ops the push if the rendered cask is unchanged.
set -euo pipefail

: "${TAG:?set TAG to the Release tag (e.g. v1.4.3)}"
: "${HOMEBREW_TAP_TOKEN:?set HOMEBREW_TAP_TOKEN (PAT with push access to the tap)}"
TAP_REPO="${TAP_REPO:-sohei56/homebrew-tap}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${TAG#v}"
TEMPLATE="$ROOT/macapp/homebrew/maul-team.rb"
SHA_FILE="$ROOT/macapp/build/MaulTeam-${VERSION}.dmg.sha256"

[ -f "$TEMPLATE" ] || { echo "Error: cask template not found at $TEMPLATE" >&2; exit 1; }
[ -f "$SHA_FILE" ] || { echo "Error: checksum not found at $SHA_FILE — run the DMG + Checksums steps first" >&2; exit 1; }

# The .sha256 line is "<64-hex>  MaulTeam-<v>.dmg"; take the hash field.
SHA256="$(awk '{print $1}' "$SHA_FILE")"
case "$SHA256" in
  [0-9a-f]*) [ "${#SHA256}" -eq 64 ] || { echo "Error: bad sha256 '$SHA256'" >&2; exit 1; } ;;
  *) echo "Error: bad sha256 '$SHA256'" >&2; exit 1 ;;
esac

echo "==> rendering cask: version=$VERSION sha256=${SHA256:0:12}…"
RENDERED="$(sed -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA256__/${SHA256}/g" "$TEMPLATE")"

# Explicit template so mktemp honours $TMPDIR (macOS `mktemp -d` without a
# template ignores TMPDIR and always uses the Darwin per-user temp dir).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maul-tap.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Clone URL is overridable for tests (point it at a local bare repo). In
# production it is the token-authenticated tap on GitHub.
TAP_CLONE_URL="${TAP_CLONE_URL:-https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${TAP_REPO}.git}"
echo "==> cloning $TAP_REPO"
git clone --depth 1 "$TAP_CLONE_URL" "$WORK/tap"

mkdir -p "$WORK/tap/Casks"
CASK="$WORK/tap/Casks/maul-team.rb"
printf '%s\n' "$RENDERED" > "$CASK"

cd "$WORK/tap"
# Stage the cask BEFORE the up-to-date check. `git diff` ignores untracked
# files, and `commit -am` only stages already-tracked modifications — so on a
# first-ever push (empty tap, or a tap without this cask yet) the old
# `git diff --quiet` returned "no diff" and the script silently no-op'd, never
# creating the cask. Staging first, then diffing the index, makes the
# first-add and the update paths both commit, while an unchanged cask still
# no-ops.
git add Casks/maul-team.rb
if git diff --cached --quiet; then
  echo "==> cask already at $VERSION — nothing to push"
  exit 0
fi

git -c user.name="maul-team-release-bot" \
    -c user.email="release-bot@users.noreply.github.com" \
    commit -m "chore(cask): maul-team ${VERSION}"
git push origin HEAD
echo "==> pushed maul-team ${VERSION} to $TAP_REPO"
