#!/usr/bin/env bash
# bump-tap.sh — render the Homebrew cask for the current Release and push it to
# the personal tap (distribution channel ③). Runs in release.yml AFTER the DMG
# and its .sha256 are built and uploaded.
#
# Inputs (env):
#   TAG                 git tag of the Release, e.g. v1.4.3   (required)
#   HOMEBREW_TAP_TOKEN  PAT with push access to the tap repo  (required)
#   TAP_REPO            owner/repo of the tap (default sohei56/homebrew-tap)
#
# Reads macapp/build/ScrumTeam-<version>.dmg.sha256 (produced by the Checksums
# step), renders macapp/homebrew/scrum-team.rb, and commits it to the tap as
# Casks/scrum-team.rb. No-ops the push if the rendered cask is unchanged.
set -euo pipefail

: "${TAG:?set TAG to the Release tag (e.g. v1.4.3)}"
: "${HOMEBREW_TAP_TOKEN:?set HOMEBREW_TAP_TOKEN (PAT with push access to the tap)}"
TAP_REPO="${TAP_REPO:-sohei56/homebrew-tap}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${TAG#v}"
TEMPLATE="$ROOT/macapp/homebrew/scrum-team.rb"
SHA_FILE="$ROOT/macapp/build/ScrumTeam-${VERSION}.dmg.sha256"

[ -f "$TEMPLATE" ] || { echo "Error: cask template not found at $TEMPLATE" >&2; exit 1; }
[ -f "$SHA_FILE" ] || { echo "Error: checksum not found at $SHA_FILE — run the DMG + Checksums steps first" >&2; exit 1; }

# The .sha256 line is "<64-hex>  ScrumTeam-<v>.dmg"; take the hash field.
SHA256="$(awk '{print $1}' "$SHA_FILE")"
case "$SHA256" in
  [0-9a-f]*) [ "${#SHA256}" -eq 64 ] || { echo "Error: bad sha256 '$SHA256'" >&2; exit 1; } ;;
  *) echo "Error: bad sha256 '$SHA256'" >&2; exit 1 ;;
esac

echo "==> rendering cask: version=$VERSION sha256=${SHA256:0:12}…"
RENDERED="$(sed -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA256__/${SHA256}/g" "$TEMPLATE")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> cloning $TAP_REPO"
git clone --depth 1 "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${TAP_REPO}.git" "$WORK/tap"

mkdir -p "$WORK/tap/Casks"
CASK="$WORK/tap/Casks/scrum-team.rb"
printf '%s\n' "$RENDERED" > "$CASK"

cd "$WORK/tap"
if git diff --quiet -- Casks/scrum-team.rb; then
  echo "==> cask already at $VERSION — nothing to push"
  exit 0
fi

git -c user.name="scrum-team-release-bot" \
    -c user.email="release-bot@users.noreply.github.com" \
    commit -am "chore(cask): scrum-team ${VERSION}"
git push origin HEAD
echo "==> pushed scrum-team ${VERSION} to $TAP_REPO"
