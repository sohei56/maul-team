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

# --- Run user setup ---
echo ""
echo "Running end-user setup..."
sh "$SCRIPT_DIR/setup-user.sh"

# --- Remove hook registration from settings.json for development ---
# setup-user.sh registers hooks in .claude/settings.json, but those hooks
# are meant for target projects running under scrum-start.sh.  When
# developing Maul Team itself there is no .scrum/state.json and the
# hooks would error on every tool use.  Keep the hook *files* symlinked for
# testing, but strip the hook registrations so they don't fire.
echo ""
echo "Removing hook registrations from .claude/settings.json (dev mode)..."
settings_file="$PROJECT_ROOT/.claude/settings.json"
if [ -f "$settings_file" ]; then
  tmp_settings="$(mktemp)"
  jq 'del(.hooks)' "$settings_file" > "$tmp_settings" && mv "$tmp_settings" "$settings_file"
  echo "  Removed hooks config — hooks will not fire during development."
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
