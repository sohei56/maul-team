#!/usr/bin/env bash
# setup-user.sh — End user setup: validate prerequisites and prepare project
# Usage: sh scripts/setup-user.sh
# Called by both scrum-start.sh and setup-dev.sh
# NEVER modifies ~/.claude/ or any global settings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$(pwd)"

# --- Deploy manifest (versioned; drives stale-file pruning on upgrade) ---
# Every framework file setup-user.sh writes UNDER .claude/ is accumulated
# here (as target-relative paths) and persisted to .claude/.maul-manifest.
# On the next deploy, paths present in the OLD manifest but absent from the
# NEW deploy set are pruned, so renamed/deleted framework files do not linger
# in targets forever. Only .claude/ paths are tracked and pruned — files
# deployed OUTSIDE .claude/ (schemas under docs/contracts/, the design
# catalog) are intentionally NOT tracked and NOT pruned (they may coexist
# with user-authored content in shared dirs and are safer left in place).
MANIFEST_VERSION=1
# Newline-delimited list of target-relative paths under .claude/. Bash 3.2
# has no associative arrays, so a newline-delimited string + grep -Fxq is the
# portable membership primitive used throughout the prune step below.
DEPLOYED_UNDER_CLAUDE=""

# manifest_add <target-relative-path>
# Record one deployed .claude/ file for the manifest.
manifest_add() {
  DEPLOYED_UNDER_CLAUDE="${DEPLOYED_UNDER_CLAUDE}${1}
"
}

# copy_tree <source_dir> <pattern> <target_dir> [executable_bool] [manifest_rel_dir]
# Copies each file in source_dir matching the glob pattern into target_dir,
# creating target_dir first. Sets executable bit when executable_bool=true.
# When manifest_rel_dir is given (a target-relative dir under .claude/), each
# copied file is recorded in the deploy manifest as
# "<manifest_rel_dir>/<basename>".
# source_dir and pattern are separate arguments so the directory part stays
# quoted during expansion: a single unquoted glob word-splits on spaces and
# silently copies NOTHING when the framework lives under a path like
# "~/Library/Application Support/…" (the Mac app's extracted bundle).
copy_tree() {
  local source_dir="$1"
  local pattern="$2"
  local target_dir="$3"
  local make_exec="${4:-false}"
  local manifest_rel="${5:-}"
  mkdir -p "$target_dir"
  for f in "$source_dir"/$pattern; do
    [ -e "$f" ] || continue
    cp "$f" "$target_dir/"
    if [ "$make_exec" = "true" ]; then
      chmod +x "$target_dir/$(basename "$f")"
    fi
    if [ -n "$manifest_rel" ]; then
      manifest_add "$manifest_rel/$(basename "$f")"
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
  local header="# Maul Team runtime state (must stay untracked)"
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

echo "=== Maul Team: Project Setup ==="
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
copy_tree "$PROJECT_ROOT/agents" "*.md" "$TARGET_DIR/.claude/agents" false ".claude/agents"

# --- Copy skill definitions ---
echo "Copying skill definitions to $TARGET_DIR/.claude/skills/..."
for skill_dir in "$PROJECT_ROOT/skills"/*/; do
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$TARGET_DIR/.claude/skills/$skill_name"
  if [ -f "$skill_dir/SKILL.md" ]; then
    cp "$skill_dir/SKILL.md" "$TARGET_DIR/.claude/skills/$skill_name/"
    manifest_add ".claude/skills/$skill_name/SKILL.md"
  fi
  # Copy references/ subdirectory if present (pbi-pipeline pattern)
  if [ -d "$skill_dir/references" ]; then
    mkdir -p "$TARGET_DIR/.claude/skills/$skill_name/references"
    for ref in "$skill_dir/references/"*.md; do
      [ -e "$ref" ] || continue
      cp "$ref" "$TARGET_DIR/.claude/skills/$skill_name/references/"
      manifest_add ".claude/skills/$skill_name/references/$(basename "$ref")"
    done
  fi
done

# --- Copy hook scripts ---
echo "Copying hook scripts to $TARGET_DIR/.claude/hooks/..."
copy_tree "$PROJECT_ROOT/hooks" "*.sh" "$TARGET_DIR/.claude/hooks" true ".claude/hooks"
copy_tree "$PROJECT_ROOT/hooks/lib" "*.sh" "$TARGET_DIR/.claude/hooks/lib" false ".claude/hooks/lib"

# --- Copy shared rules ---
# `.claude/rules/*.md` is auto-loaded by Claude Code at session start for the
# main session, sub-agents, and Agent Teams teammates — every Scrum agent
# reads them. Contains the cross-cutting Scrum context (team map, SSOT
# locations, communication protocol, uncertainty handling).
echo "Copying shared rules to $TARGET_DIR/.claude/rules/..."
copy_tree "$PROJECT_ROOT/rules" "*.md" "$TARGET_DIR/.claude/rules" false ".claude/rules"

# --- Copy runtime-doc subset (framework prose cited by deployed agents/skills) ---
# Deployed agents and skills reference framework prose (data-model, contracts,
# autonomous-mode) via relative paths. Those docs are NOT part of the normal
# deploy, so the references dangle in targets. Deploy exactly the cited subset
# under .claude/docs/, MIRRORING the source subtree, so `../docs/<path>` (from
# .claude/agents/*.md) and `../../docs/<path>` (from .claude/skills/<name>/*.md)
# resolve identically in the source repo and in targets.
echo "Copying runtime-doc subset to $TARGET_DIR/.claude/docs/..."
mkdir -p "$TARGET_DIR/.claude/docs/contracts"
# top-level docs → .claude/docs/<name>
for doc in data-model.md autonomous-mode.md; do
  if [ -f "$PROJECT_ROOT/docs/$doc" ]; then
    cp "$PROJECT_ROOT/docs/$doc" "$TARGET_DIR/.claude/docs/$doc"
    manifest_add ".claude/docs/$doc"
  fi
done
# contract docs → .claude/docs/contracts/<name>
for doc in agent-interfaces.md sub-agents.md; do
  if [ -f "$PROJECT_ROOT/docs/contracts/$doc" ]; then
    cp "$PROJECT_ROOT/docs/contracts/$doc" "$TARGET_DIR/.claude/docs/contracts/$doc"
    manifest_add ".claude/docs/contracts/$doc"
  fi
done

# --- Copy non-hook shared agent helpers ---
# `scripts/lib/codex-invoke.sh` is sourced by codex-* reviewer agents during
# PBI-pipeline review steps. It is not a hook helper, so it lives outside
# `.claude/hooks/lib/`. The codex-design-reviewer.md instruction sources it
# at `scripts/lib/codex-invoke.sh` (relative to project root).
echo "Copying agent helpers to $TARGET_DIR/scripts/lib/..."
copy_tree "$PROJECT_ROOT/scripts/lib" "*.sh" "$TARGET_DIR/scripts/lib"

# --- Ensure .scrum/ is gitignored (must run BEFORE any .scrum/ write) ---
echo "Ensuring .scrum/ is gitignored in $TARGET_DIR..."
ensure_gitignore_excludes_scrum

# --- Copy scrum-state SSOT wrappers ---
# pre-tool-use-scrum-state-guard blocks raw writes to .scrum/*.json. Without
# the wrappers, agents have no permitted way to mutate state.
# Deploy under .scrum/scripts/ to keep framework artifacts out of the user's
# scripts/ tree (where they were easy to confuse with project deliverables).
#
# Clean-slate deploy: .scrum/scripts/ is framework-owned (no user files live
# here), so stale wrappers from renamed/removed framework scripts are deleted
# rather than left to linger — an old wrapper that keeps answering with
# outdated behavior is exactly the drift class behind the `cancelled`
# incident (docs/MIGRATION-scrum-state-tools.md § State migrations).
echo "Copying scrum-state wrappers to $TARGET_DIR/.scrum/scripts/..."
rm -f "$TARGET_DIR/.scrum/scripts/"*.sh \
      "$TARGET_DIR/.scrum/scripts/lib/"*.sh \
      "$TARGET_DIR/.scrum/scripts/migrations/"*.sh
copy_tree "$PROJECT_ROOT/scripts/scrum" "*.sh" "$TARGET_DIR/.scrum/scripts" true
copy_tree "$PROJECT_ROOT/scripts/scrum/lib" "*.sh" "$TARGET_DIR/.scrum/scripts/lib"
copy_tree "$PROJECT_ROOT/scripts/scrum/migrations" "*.sh" "$TARGET_DIR/.scrum/scripts/migrations" true

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
# Required by scripts/scrum/migrate-state.sh (and any hand-run validation).
if [ -d "$PROJECT_ROOT/docs/contracts/scrum-state" ]; then
  mkdir -p "$TARGET_DIR/docs/contracts/scrum-state"
  cp "$PROJECT_ROOT/docs/contracts/scrum-state/"*.schema.json \
     "$TARGET_DIR/docs/contracts/scrum-state/" 2>/dev/null || true
fi

# --- Deploy stamp ---
# Record WHICH framework revision the wrappers/schemas in this target came
# from, so a stale deployment is diagnosable from inside the target ("the
# wrapper rejects a documented value" → check the stamp, re-run setup) instead
# of being misread as a missing feature. Written by this launcher process
# (outside agent tool calls, like .scrum/runtime.json), so the scrum-state
# guard never intercepts it; agents must not write it. Enumerated in
# docs/contracts/scrum-state/README.md.
# Revision sources, most-trustworthy first:
#   1. .framework-rev — content marker baked by macapp/scripts/make-app.sh
#      into the bundled framework (a `git archive` extraction has no .git,
#      and its content is exactly the committed rev → never dirty).
#   2. git HEAD — but only when PROJECT_ROOT is itself the repo toplevel;
#      without that guard, `git -C` on a non-repo extraction walks UP the
#      directory tree and stamps the sha of whatever unrelated ancestor
#      repo it finds.
FRAMEWORK_SHA=unknown
FRAMEWORK_DIRTY=false
if [ -f "$PROJECT_ROOT/.framework-rev" ]; then
  FRAMEWORK_SHA="$(cut -c1-12 "$PROJECT_ROOT/.framework-rev" | head -n1)"
  [ -n "$FRAMEWORK_SHA" ] || FRAMEWORK_SHA=unknown
elif [ "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$PROJECT_ROOT" && pwd -P)" ]; then
  FRAMEWORK_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ "$FRAMEWORK_SHA" != "unknown" ] \
     && [ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then
    FRAMEWORK_DIRTY=true
  fi
fi
STAMP_TMP="$TARGET_DIR/.scrum/deploy-stamp.json.tmp.$$"
jq -n \
  --arg sha "$FRAMEWORK_SHA" \
  --argjson dirty "$FRAMEWORK_DIRTY" \
  --arg at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg root "$PROJECT_ROOT" \
  '{framework_sha: $sha, framework_dirty: $dirty, deployed_at: $at, framework_root: $root}' \
  > "$STAMP_TMP"
mv "$STAMP_TMP" "$TARGET_DIR/.scrum/deploy-stamp.json"
echo "  Deploy stamp: framework $FRAMEWORK_SHA (dirty=$FRAMEWORK_DIRTY) -> .scrum/deploy-stamp.json"

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
      "mcp__playwright",
      "mcp__chrome-devtools"
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "$CLAUDE_PROJECT_DIR/.claude/statusline.sh"
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
        "matcher": "Write|Edit|Bash",
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
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/status-gate.sh"
          }
        ]
      },
      {
        "matcher": "Read|Write|Edit|Bash",
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
        "matcher": "Write|Edit|Agent|SendMessage",
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
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
echo "  Written settings.json with hook configuration."

# --- Configure standard MCP servers (context7 + Playwright + Chrome DevTools) ---
# These are the Maul Team standard MCP servers. All three are added
# unconditionally if npx is available:
#   - context7: fetches up-to-date library/framework docs (needs no
#     credentials; useful across every ceremony).
#   - playwright: browser E2E in Integration Sprint. The smoke-test and
#     po-acceptance skills gracefully skip browser flows when it is absent,
#     so adding it is safe — it only activates when a running app is detected.
#   - chrome-devtools: console/network inspection and performance traces for
#     UAT / claude-manual testing. Same as playwright, the relevant skills
#     gracefully skip when it is absent.
# Existing entries are preserved (//=); only missing servers are added.

if command -v npx >/dev/null 2>&1; then
  echo ""
  echo "Configuring standard MCP servers (context7, Playwright, Chrome DevTools)..."
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
      | .mcpServers["chrome-devtools"] //= {"type": "stdio", "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"]}
    ' "$mcp_file" > "$tmp_mcp" 2>/dev/null; then
      mv "$tmp_mcp" "$mcp_file"
      echo "  Ensured context7 + Playwright + Chrome DevTools MCP in existing .mcp.json"
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
    },
    "chrome-devtools": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest"]
    }
  }
}
MCP_EOF
    echo "  Created .mcp.json with context7 + Playwright + Chrome DevTools MCP"
  fi
else
  echo ""
  echo "Note: npx not found — skipping MCP configuration."
  echo "  Install Node.js to enable context7 docs + browser E2E testing."
fi

# --- Check Codex CLI for cross-model code review ---
# The codex-{design,impl,ut}-reviewer sub-agents call `codex` directly via
# CLI for per-PBI cross-model review in the PBI pipeline, and the Integrity
# stage's functional-quality / security aspect reviewers run an in-reviewer
# codex second opinion on top of their own Claude review. When codex is not
# installed, Round reviews fall back to Claude-based review and the two
# Integrity aspects proceed Claude-only. Everything else is
# codex-independent: the remaining 3 Integrity aspects, and Sprint-end
# cross-review (an audit-only 4-axis codebase-audit).
# check_codex_cli (scripts/lib/check-python.sh, sourced above) owns the
# probe + install hint; it is silent when codex is present, so the
# detected-confirmation line must be guarded here.

echo ""
if command -v codex >/dev/null 2>&1; then
  echo "Codex CLI detected — cross-model code review enabled."
else
  check_codex_cli
fi

# --- Deploy status line script ---
# The settings.json heredoc above registers a statusLine command at
# $CLAUDE_PROJECT_DIR/.claude/statusline.sh, so the script must exist there
# and be executable.
echo ""
echo "Deploying status line script to $TARGET_DIR/.claude/statusline.sh..."
cp "$PROJECT_ROOT/scripts/statusline.sh" "$TARGET_DIR/.claude/statusline.sh"
chmod +x "$TARGET_DIR/.claude/statusline.sh"
manifest_add ".claude/statusline.sh"

# --- Prune stale framework files + write the new deploy manifest ---
# All .claude/ framework files for this deploy are now on disk and recorded in
# DEPLOYED_UNDER_CLAUDE. Compare against the previous manifest and remove any
# .claude/ path that was deployed before but is not in this deploy set
# (renamed/deleted framework agents, skills, references, hooks, docs). Only
# paths listed in the OLD manifest are ever removed — user-authored files
# under .claude/ are never in a manifest, so they are untouchable.
prune_and_write_manifest() {
  local manifest_file="$TARGET_DIR/.claude/.maul-manifest"
  local new_paths old_paths
  # Sorted, de-duplicated new deploy set (drop blank lines).
  new_paths="$(printf '%s' "$DEPLOYED_UNDER_CLAUDE" | grep -v '^$' | LC_ALL=C sort -u)"

  if [ -f "$manifest_file" ]; then
    # Old manifest paths: strip comment/blank lines.
    old_paths="$(grep -v -e '^#' -e '^[[:space:]]*$' "$manifest_file" || true)"

    # Guard: refuse to prune if any old path is absolute or contains a `..`
    # segment — a corrupt/tampered manifest must never drive deletions
    # outside the intended .claude/ subtree.
    if printf '%s\n' "$old_paths" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
      echo "  WARN: previous manifest contains an unsafe path (absolute or '..') — skipping prune." >&2
    else
      local removed_dirs=""
      local p
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # Prune only under .claude/ (defensive: manifest is .claude-only by
        # construction, but never act on anything outside it).
        case "$p" in
          .claude/*) ;;
          *) continue ;;
        esac
        # Keep paths still in the current deploy set.
        if printf '%s\n' "$new_paths" | grep -Fxq "$p"; then
          continue
        fi
        if [ -e "$TARGET_DIR/$p" ]; then
          rm -f "$TARGET_DIR/$p"
          echo "  Pruned stale framework file: $p"
        fi
        # Remember skill sub-dirs so we can drop them when they go empty.
        case "$p" in
          .claude/skills/*)
            removed_dirs="${removed_dirs}$(dirname "$p")
"
            ;;
        esac
      done <<EOF
$old_paths
EOF

      # Best-effort removal of now-empty skill dirs (deepest first, so a
      # references/ subdir is removed before its parent skill dir). rmdir
      # only succeeds on empty dirs, so this can never delete user content.
      if [ -n "$removed_dirs" ]; then
        local d
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          case "$d" in
            .claude/skills/*) rmdir "$TARGET_DIR/$d" 2>/dev/null || true ;;
          esac
        done <<EOF
$(printf '%s' "$removed_dirs" | grep -v '^$' | awk '{ print length, $0 }' | LC_ALL=C sort -rn | cut -d' ' -f2-)
EOF
      fi
    fi
  fi

  # Write the new manifest (sorted, versioned header).
  {
    echo "# maul-team deploy manifest v${MANIFEST_VERSION}"
    echo "# One target-relative path per line for every .claude/ file this"
    echo "# deploy wrote. Used to prune stale framework files on the next"
    echo "# deploy. Files outside .claude/ (docs/contracts schemas, design"
    echo "# catalog) are intentionally NOT tracked here and never pruned."
    echo "# Do not edit by hand."
    printf '%s\n' "$new_paths"
  } > "$manifest_file"
  echo "  Wrote deploy manifest ($(printf '%s\n' "$new_paths" | grep -c . ) files): .claude/.maul-manifest"
}
prune_and_write_manifest

echo ""
echo "=== Setup complete ==="
echo ""
echo "Project configured at: $TARGET_DIR"
echo "  .claude/agents/     — Agent definitions"
echo "  .claude/skills/     — Skill definitions"
echo "  .claude/hooks/      — Hook scripts"
echo "  .claude/rules/      — Cross-cutting Scrum context loaded by every agent"
echo "  .claude/docs/       — Framework prose cited by agents/skills (data-model, contracts, autonomous-mode)"
echo "  docs/design/            — Design catalog and configuration"
echo "  .claude/settings.json — Hook and status line configuration"
