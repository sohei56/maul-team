#!/usr/bin/env bash
# check-python.sh — Shared prerequisite checks
# Sourced by scrum-start.sh and setup-user.sh to avoid duplication.
#
# Provides:
#   check_claude_cli         — Verify Claude Code CLI on PATH (exits 1 on failure)
#   check_claude_cli_version — Warn (do not exit) when below MIN_CLAUDE_VERSION
#   check_python_prereqs     — Verify Python 3.9+ and TUI packages (exits 3 on failure)
#
# On success: exports PYTHON_VERSION (e.g. "3.12").

# Guard against double-sourcing
# shellcheck disable=SC2317
if [ "${_CHECK_PYTHON_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_CHECK_PYTHON_LOADED=1

# Minimum recommended Claude Code version. The PBI pipeline (Developer
# spawns pbi-designer / pbi-implementer / pbi-ut-author / codex-*-reviewer)
# requires sub-agents to spawn further sub-agents, which the upstream
# changelog records as unlocked in Claude Code 2.1.172. On older versions
# the Developer's tool surface lacks Agent / Task and the pipeline halts
# at the design stage.
MIN_CLAUDE_VERSION="2.1.172"

# Verify Claude Code CLI is available
check_claude_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "Error: Claude Code CLI not found on PATH." >&2
    echo "Install it: https://docs.anthropic.com/en/docs/claude-code/overview" >&2
    exit 1
  fi
}

# Warn (do not exit) when Claude Code is older than MIN_CLAUDE_VERSION.
# Silently skips when the version string cannot be parsed (e.g. a CI
# stub returning a non-semver string, or a vendor wrapper).
check_claude_cli_version() {
  local version lowest
  version="$(claude --version 2>/dev/null | awk '{print $1}')"
  # Only act on values that look like a semver triple at the start.
  # Stubs returning 'stub-claude 0.0.1' or vendor wrappers fall through.
  if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
    return 0
  fi
  lowest="$(printf '%s\n%s\n' "$version" "$MIN_CLAUDE_VERSION" | sort -V | head -1)"
  # version >= MIN_CLAUDE_VERSION iff MIN is the lowest of the pair, or equal.
  if [ "$version" = "$MIN_CLAUDE_VERSION" ] || [ "$lowest" = "$MIN_CLAUDE_VERSION" ]; then
    return 0
  fi
  cat >&2 <<EOF
Warning: Claude Code $version is older than the recommended $MIN_CLAUDE_VERSION.
  Sub-agents spawning further sub-agents was unlocked in Claude Code
  $MIN_CLAUDE_VERSION. On older versions the Developer cannot spawn the
  pbi-pipeline specialist sub-agents (pbi-designer / pbi-implementer /
  pbi-ut-author / codex-*-reviewer) and the PBI pipeline halts at design.

  Upgrade (Homebrew — the stock 'claude-code' cask is frozen at 2.1.153):
    brew uninstall --cask claude-code
    brew install --cask claude-code@latest

  Or native installer:
    curl -fsSL https://claude.ai/install.sh | bash

  Continuing — Requirement Definition and ceremonies that do not spawn
  sub-agents will still run.
EOF
}

check_python_prereqs() {
  # 1. python3 on PATH
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Python 3.9+ not found on PATH." >&2
    echo "Install Python: https://www.python.org/downloads/" >&2
    exit 3
  fi

  # 2. Version >= 3.9
  PYTHON_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  export PYTHON_VERSION
  local major minor
  major="$(echo "$PYTHON_VERSION" | cut -d. -f1)"
  minor="$(echo "$PYTHON_VERSION" | cut -d. -f2)"
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 9 ]; }; then
    echo "Error: Python 3.9+ required, found Python $PYTHON_VERSION." >&2
    exit 3
  fi

  # 3. TUI packages — auto-install if missing
  # jsonschema is required so the dashboard validates .scrum/*.json against
  # docs/contracts/scrum-state/*.schema.json. Without it, validation silently
  # bypasses and stale/legacy state renders as empty panels.
  local missing_pkgs=""
  if ! python3 -c "import textual" 2>/dev/null; then
    missing_pkgs="textual"
  fi
  if ! python3 -c "import watchdog" 2>/dev/null; then
    missing_pkgs="${missing_pkgs:+${missing_pkgs} }watchdog"
  fi
  if ! python3 -c "import jsonschema" 2>/dev/null; then
    missing_pkgs="${missing_pkgs:+${missing_pkgs} }jsonschema"
  fi
  if [ -n "$missing_pkgs" ]; then
    echo "Installing missing Python package(s): ${missing_pkgs}..."
    local pip_err
    # shellcheck disable=SC2086
    if pip_err="$(python3 -m pip install --quiet $missing_pkgs 2>&1)"; then
      echo "  Installed successfully."
    elif printf '%s' "$pip_err" | grep -q -e "externally-managed" -e "PEP 668"; then
      # Homebrew/system Python (PEP 668) refuses pip without --break-system-packages.
      # Retry once with that flag — the TUI deps are user-scope tooling, not OS-managed.
      echo "  System Python is externally-managed; retrying with --break-system-packages..."
      # shellcheck disable=SC2086
      if python3 -m pip install --quiet --break-system-packages $missing_pkgs; then
        echo "  Installed successfully."
      else
        _check_python_install_failed "$missing_pkgs"
      fi
    else
      printf '%s\n' "$pip_err" >&2
      _check_python_install_failed "$missing_pkgs"
    fi
  fi
}

_check_python_install_failed() {
  local pkgs="$1"
  echo "Error: Failed to install Python package(s): ${pkgs}" >&2
  echo "" >&2
  echo "Try installing manually:" >&2
  echo "  pip install ${pkgs}" >&2
  echo "or, on Homebrew/system Python (PEP 668):" >&2
  echo "  pip install --break-system-packages ${pkgs}" >&2
  echo "or use a project venv:" >&2
  echo "  python3 -m venv .venv && .venv/bin/pip install ${pkgs}" >&2
  exit 3
}
