#!/usr/bin/env bash
# setup-user.sh — End user setup: validate prerequisites and prepare project
# Usage: sh scripts/setup-user.sh
# Called by both scrum-start.sh and setup-dev.sh
# NEVER modifies ~/.claude/ or any global settings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$(pwd)"

# copy_tree <source_glob> <target_dir> [executable_bool]
# Copies each file matching the unquoted source glob into target_dir,
# creating target_dir first. Sets executable bit when executable_bool=true.
copy_tree() {
  local source_glob="$1"
  local target_dir="$2"
  local make_exec="${3:-false}"
  mkdir -p "$target_dir"
  for f in $source_glob; do
    [ -e "$f" ] || continue
    cp "$f" "$target_dir/"
    if [ "$make_exec" = "true" ]; then
      chmod +x "$target_dir/$(basename "$f")"
    fi
  done
}

# ensure_gitignore_excludes_scrum
# Idempotently appends `.scrum` and `.scrum/` to TARGET_DIR/.gitignore so that
# runtime state cannot be accidentally tracked. Past incident: when .scrum/
# was tracked, branch switches silently removed branch-local state files.
# Behavior:
#   - Never overwrites existing content; append-only.
#   - Skips entries already present (whole-line match via grep -Fxq).
#   - Creates .gitignore if missing.
ensure_gitignore_excludes_scrum() {
  local gitignore_file="$TARGET_DIR/.gitignore"
  local header="# Claude Scrum Team runtime state (must stay untracked)"
  local entries=('.scrum' '.scrum/')
  local missing=()
  local entry

  for entry in "${entries[@]}"; do
    if [ ! -f "$gitignore_file" ] || ! grep -Fxq "$entry" "$gitignore_file"; then
      missing+=("$entry")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "  .gitignore already excludes .scrum — no changes."
    return 0
  fi

  [ -f "$gitignore_file" ] || : > "$gitignore_file"

  # Ensure file ends with newline before appending (portable on macOS).
  if [ -s "$gitignore_file" ] \
     && [ "$(tail -c1 "$gitignore_file" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
    printf '\n' >> "$gitignore_file"
  fi

  if ! grep -Fxq "$header" "$gitignore_file" 2>/dev/null; then
    [ -s "$gitignore_file" ] && printf '\n' >> "$gitignore_file"
    printf '%s\n' "$header" >> "$gitignore_file"
  fi

  for entry in "${missing[@]}"; do
    printf '%s\n' "$entry" >> "$gitignore_file"
  done

  echo "  Updated $gitignore_file: added ${missing[*]}"
}

echo "=== claude-scrum-team: Project Setup ==="
echo ""

# --- Validate prerequisites ---

# shellcheck source=lib/check-python.sh
. "$SCRIPT_DIR/lib/check-python.sh"
check_claude_cli
check_python_prereqs

echo "Prerequisites OK: Claude Code, Python $PYTHON_VERSION, textual, watchdog"

# Try to install tmux if missing (optional — dashboard degrades to status line without it)
if ! command -v tmux >/dev/null 2>&1; then
  echo ""
  echo "tmux not found — attempting to install (recommended for TUI dashboard)..."
  if command -v brew >/dev/null 2>&1; then
    brew install tmux && echo "  tmux installed successfully." || echo "  Warning: tmux install failed. The status line fallback will be used." >&2
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y tmux && echo "  tmux installed successfully." || echo "  Warning: tmux install failed. The status line fallback will be used." >&2
  else
    echo "  Could not install tmux automatically (no brew or apt-get found)." >&2
    echo "  Install manually for the full TUI dashboard, or continue without it." >&2
  fi
fi

echo ""

# --- Copy agent definitions ---
echo "Copying agent definitions to $TARGET_DIR/.claude/agents/..."
copy_tree "$PROJECT_ROOT/agents/*.md" "$TARGET_DIR/.claude/agents"

# --- Copy skill definitions ---
echo "Copying skill definitions to $TARGET_DIR/.claude/skills/..."
for skill_dir in "$PROJECT_ROOT/skills"/*/; do
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$TARGET_DIR/.claude/skills/$skill_name"
  if [ -f "$skill_dir/SKILL.md" ]; then
    cp "$skill_dir/SKILL.md" "$TARGET_DIR/.claude/skills/$skill_name/"
  fi
  # Copy references/ subdirectory if present (pbi-pipeline pattern)
  if [ -d "$skill_dir/references" ]; then
    mkdir -p "$TARGET_DIR/.claude/skills/$skill_name/references"
    cp "$skill_dir/references/"*.md "$TARGET_DIR/.claude/skills/$skill_name/references/" 2>/dev/null || true
  fi
done

# --- Copy hook scripts ---
echo "Copying hook scripts to $TARGET_DIR/.claude/hooks/..."
copy_tree "$PROJECT_ROOT/hooks/*.sh" "$TARGET_DIR/.claude/hooks" true
copy_tree "$PROJECT_ROOT/hooks/lib/*.sh" "$TARGET_DIR/.claude/hooks/lib"

# --- Copy shared rules ---
# `.claude/rules/*.md` is auto-loaded by Claude Code at session start for the
# main session, sub-agents, and Agent Teams teammates — every Scrum agent
# reads them. Contains the cross-cutting Scrum context (team map, SSOT
# locations, communication protocol, uncertainty handling).
echo "Copying shared rules to $TARGET_DIR/.claude/rules/..."
copy_tree "$PROJECT_ROOT/rules/*.md" "$TARGET_DIR/.claude/rules"

# --- Copy non-hook shared agent helpers ---
# `scripts/lib/codex-invoke.sh` is sourced by codex-* reviewer agents during
# PBI-pipeline review steps. It is not a hook helper, so it lives outside
# `.claude/hooks/lib/`. The codex-design-reviewer.md instruction sources it
# at `scripts/lib/codex-invoke.sh` (relative to project root).
echo "Copying agent helpers to $TARGET_DIR/scripts/lib/..."
copy_tree "$PROJECT_ROOT/scripts/lib/*.sh" "$TARGET_DIR/scripts/lib"

# --- Ensure .scrum/ is gitignored (must run BEFORE any .scrum/ write) ---
echo "Ensuring .scrum/ is gitignored in $TARGET_DIR..."
ensure_gitignore_excludes_scrum

# --- Copy scrum-state SSOT wrappers ---
# pre-tool-use-scrum-state-guard blocks raw writes to .scrum/*.json. Without
# the wrappers, agents have no permitted way to mutate state.
# Deploy under .scrum/scripts/ to keep framework artifacts out of the user's
# scripts/ tree (where they were easy to confuse with project deliverables).
echo "Copying scrum-state wrappers to $TARGET_DIR/.scrum/scripts/..."
copy_tree "$PROJECT_ROOT/scripts/scrum/*.sh" "$TARGET_DIR/.scrum/scripts" true
copy_tree "$PROJECT_ROOT/scripts/scrum/lib/*.sh" "$TARGET_DIR/.scrum/scripts/lib"

# --- Copy PBI Pipeline configuration template ---
# Provide .scrum-config.example.json so users can copy it to .scrum/config.json
# and adapt to their project's test_runner / coverage_tool. Only copies if the
# example template is missing in the target.
if [ -f "$PROJECT_ROOT/.scrum-config.example.json" ] && [ ! -f "$TARGET_DIR/.scrum-config.example.json" ]; then
  cp "$PROJECT_ROOT/.scrum-config.example.json" "$TARGET_DIR/"
  echo "  Copied .scrum-config.example.json (copy to .scrum/config.json and adapt)"
fi

# --- Copy contract JSON Schemas (PBI Pipeline artifacts) ---
if [ -d "$PROJECT_ROOT/docs/contracts" ]; then
  mkdir -p "$TARGET_DIR/docs/contracts"
  cp "$PROJECT_ROOT/docs/contracts/"*.schema.json "$TARGET_DIR/docs/contracts/" 2>/dev/null || true
fi
# --- Copy scrum-state SSOT schemas ---
# Required by scripts/scrum/migrate-legacy.sh (and any hand-run validation).
if [ -d "$PROJECT_ROOT/docs/contracts/scrum-state" ]; then
  mkdir -p "$TARGET_DIR/docs/contracts/scrum-state"
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/"*.schema.json \
     "$TARGET_DIR/docs/contracts/scrum-state/" 2>/dev/null || true
fi

# --- Copy design catalog ---
echo "Copying design catalog to $TARGET_DIR/docs/design/..."
mkdir -p "$TARGET_DIR/docs/design"
cp "$PROJECT_ROOT/docs/design/catalog.md" "$TARGET_DIR/docs/design/"
# Copy default catalog config if none exists yet (preserve existing project config)
if [ ! -f "$TARGET_DIR/docs/design/catalog-config.json" ]; then
  cp "$PROJECT_ROOT/docs/design/catalog-config.json" "$TARGET_DIR/docs/design/"
  echo "  Created default catalog-config.json"
else
  echo "  catalog-config.json already exists — preserving project configuration"
fi

# --- Configure settings.json ---
echo "Configuring $TARGET_DIR/.claude/settings.json..."

settings_file="$TARGET_DIR/.claude/settings.json"

# Always write settings.json with current hook configuration.
# If the file already exists, back it up so user customizations aren't lost.
if [ -f "$settings_file" ]; then
  cp "$settings_file" "${settings_file}.bak"
  echo "  Backed up existing settings.json to settings.json.bak"
fi

cat > "$settings_file" << 'SETTINGS_EOF'
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Edit",
      "Bash(*)",
      "Glob",
      "Grep",
      "Agent",
      "WebFetch",
      "WebSearch",
      "Bash(codex *)",
      "mcp__context7",
      "mcp__playwright"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-context.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-use-scrum-state-guard.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-use-no-branch-ops.sh"
          }
        ]
      },
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/status-gate.sh"
          }
        ]
      },
      {
        "matcher": "Read|Write|Edit|MultiEdit|Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-tool-use-path-guard.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|Agent|SendMessage",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-dispatch.sh"
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/quality-gate.sh"
          },
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-context.sh"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-failure.sh"
          },
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ],
    "FileChanged": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/dashboard-event.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
echo "  Written settings.json with hook configuration."

# --- Configure standard MCP servers (context7 + Playwright) ---
# These are the Claude Scrum Team standard MCP servers. Both are added
# unconditionally if npx is available:
#   - context7: fetches up-to-date library/framework docs (needs no
#     credentials; useful across every ceremony).
#   - playwright: browser E2E in Integration Sprint. The smoke-test and
#     po-acceptance skills gracefully skip browser flows when it is absent,
#     so adding it is safe — it only activates when a running app is detected.
# Existing entries are preserved (//=); only missing servers are added.

if command -v npx >/dev/null 2>&1; then
  echo ""
  echo "Configuring standard MCP servers (context7, Playwright)..."
  mcp_file="$TARGET_DIR/.mcp.json"

  if [ -f "$mcp_file" ]; then
    # Create the temp file alongside the target (not in $TMPDIR) so the
    # subsequent mv is a same-directory rename and the step does not depend
    # on the system temp dir being writable (sandboxed CI / restricted
    # environments). Mirrors the atomic-write pattern used in scrum-start.sh
    # and the .scrum/scripts wrappers.
    tmp_mcp="$(mktemp "${mcp_file}.tmp.XXXXXX")"
    if jq '
      .mcpServers.context7 //= {"type": "stdio", "command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
      | .mcpServers.playwright //= {"type": "stdio", "command": "npx", "args": ["@anthropic-ai/mcp-playwright"]}
    ' "$mcp_file" > "$tmp_mcp" 2>/dev/null; then
      mv "$tmp_mcp" "$mcp_file"
      echo "  Ensured context7 + Playwright MCP in existing .mcp.json"
    else
      rm -f "$tmp_mcp"
      echo "  WARN: could not update existing .mcp.json (jq missing or invalid JSON)"
    fi
  else
    cat > "$mcp_file" << 'MCP_EOF'
{
  "mcpServers": {
    "context7": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    },
    "playwright": {
      "type": "stdio",
      "command": "npx",
      "args": ["@anthropic-ai/mcp-playwright"]
    }
  }
}
MCP_EOF
    echo "  Created .mcp.json with context7 + Playwright MCP"
  fi
else
  echo ""
  echo "Note: npx not found — skipping MCP configuration."
  echo "  Install Node.js to enable context7 docs + browser E2E testing."
fi

# --- Check Codex CLI for cross-model code review ---
# The codex-{design,impl,ut}-reviewer sub-agents call `codex` directly via
# CLI for per-PBI cross-model review (Layer 1 in the PBI Pipeline). When
# codex is not installed, those sub-agents fall back to Claude-based review.
# Sprint-end cross-review (Layer 2) is independent of codex and runs the
# 5 aspect-specialized reviewer sub-agents regardless.

if command -v codex >/dev/null 2>&1; then
  echo ""
  echo "Codex CLI detected — cross-model code review enabled."
else
  echo ""
  echo "Note: codex not found — code review will use Claude fallback."
  echo "  Install: npm i -g @openai/codex && codex login"
fi

# --- Configure status line ---
# Status line config goes in settings.json or .claude/settings.local.json
# The statusline.sh script is referenced by path

echo ""
echo "=== Setup complete ==="
echo ""
echo "Project configured at: $TARGET_DIR"
echo "  .claude/agents/     — Agent definitions"
echo "  .claude/skills/     — Skill definitions"
echo "  .claude/hooks/      — Hook scripts"
echo "  .claude/rules/      — Cross-cutting Scrum context loaded by every agent"
echo "  docs/design/            — Design catalog and configuration"
echo "  .claude/settings.json — Hook and status line configuration"
