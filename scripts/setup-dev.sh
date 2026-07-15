#!/usr/bin/env bash
# setup-dev.sh — Contributor setup: install dev dependencies + user setup
# Usage: sh scripts/setup-dev.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Maul Team: Contributor Setup ==="
echo ""

# --- Install dev dependencies ---
missing=()

if ! command -v bats >/dev/null 2>&1; then
  missing+=("bats-core")
fi
if ! command -v jq >/dev/null 2>&1; then
  missing+=("jq")
fi
if ! command -v yq >/dev/null 2>&1; then
  missing+=("yq")
fi
if ! command -v shellcheck >/dev/null 2>&1; then
  missing+=("shellcheck")
fi
if ! command -v ruff >/dev/null 2>&1; then
  missing+=("ruff")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "Installing missing dev dependencies: ${missing[*]}"
  if command -v brew >/dev/null 2>&1; then
    brew install "${missing[@]}"
  else
    echo "Error: Homebrew not found. Please install the following manually:" >&2
    printf "  - %s\n" "${missing[@]}" >&2
    echo "" >&2
    echo "On Debian/Ubuntu:" >&2
    echo "  sudo apt install bats jq shellcheck" >&2
    echo "  # yq: see https://github.com/mikefarah/yq#install" >&2
    echo "  # ruff: pip install ruff  (or see https://docs.astral.sh/ruff/installation/)" >&2
    exit 1
  fi
else
  echo "All dev dependencies already installed."
fi

# --- Initialize git submodules (bats-support, bats-assert) ---
echo ""
echo "Initializing test helper submodules..."
cd "$PROJECT_ROOT"
git submodule update --init --recursive

# --- Run user setup (preserving the framework repo's own settings.json) ---
# setup-user.sh overwrites .claude/settings.json with the target-project
# template, but the framework repo's settings.json is COMMITTED config: it
# carries the env / sandbox / permissions blocks and registers exactly one
# hook — pre-tool-use-scrum-state-guard.sh — which CLAUDE.md § Git workflow
# requires to stay active here (this repo writes to .scrum/ during
# integration tests).  The target-project hook set would error in this repo
# (no scrum-start.sh runtime), so we snapshot the committed settings before
# setup-user.sh runs and restore them afterwards, leaving them untouched.
echo ""
echo "Running end-user setup..."
settings_file="$PROJECT_ROOT/.claude/settings.json"
settings_snapshot=""
if [ -f "$settings_file" ]; then
  settings_snapshot="$(mktemp)"
  cp "$settings_file" "$settings_snapshot"
fi
sh "$SCRIPT_DIR/setup-user.sh"
if [ -n "$settings_snapshot" ]; then
  cp "$settings_snapshot" "$settings_file"   # cp (not mv) keeps the file's mode
  rm -f "$settings_snapshot" "${settings_file}.bak"
  echo ""
  echo "Restored the framework repo's committed .claude/settings.json"
  echo "  (env/sandbox/permissions + scrum-state-guard hook preserved)."
fi

# --- Replace hook copies with symlinks for development ---
# setup-user.sh copies hook files, but contributors need symlinks so edits
# to hooks/ are immediately reflected without re-running setup.
echo "Replacing hook copies with symlinks for development..."
hooks_dir="$PROJECT_ROOT/.claude/hooks"
rm -rf "$hooks_dir"
mkdir -p "$hooks_dir"
for hook_file in "$PROJECT_ROOT/hooks/"*.sh; do
  if [ -f "$hook_file" ]; then
    ln -s "../../hooks/$(basename "$hook_file")" "$hooks_dir/$(basename "$hook_file")"
  fi
done
# Symlink the lib directory
ln -s "../../hooks/lib" "$hooks_dir/lib"
echo "  Symlinked .claude/hooks/ → hooks/ for live development."

echo ""
echo "Probing JSON Schema validator..."
if validator="$("$SCRIPT_DIR/scrum/lib/check-validator.sh" 2>&1)"; then
  echo "  Validator: $validator"
else
  echo "  $validator" >&2
fi

echo ""
echo "=== Contributor setup complete ==="
echo ""
echo "Verify with:"
echo "  bats tests/unit/ tests/lint/"
echo "  shellcheck scrum-start.sh scripts/*.sh scripts/lib/*.sh hooks/*.sh hooks/lib/*.sh"
echo "  ruff check dashboard/"
