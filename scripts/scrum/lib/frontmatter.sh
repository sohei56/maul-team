#!/usr/bin/env bash
# scripts/scrum/lib/frontmatter.sh — read / patch one key in the YAML
# frontmatter of an agent definition (.claude/agents/*.md).
# Sourced by scripts/scrum/agent-models.sh (patch) and
# scripts/scrum/migrations/009-seed-agent-models.sh (capture).
#
# "Frontmatter" is the block between the first two `---` lines. Both helpers
# look only at the FIRST `^<key>:` line inside that block: a `model:` in the
# Markdown body or in a nested mapping is never touched. Neither helper
# inserts a key — an agent whose frontmatter has no `model:` (scrum-explorer,
# ceremony-operator inherit the parent's model by design) must stay that way.

if [ "${_SCRUM_FRONTMATTER_SH_LOADED:-}" = "1" ]; then
  # shellcheck disable=SC2317  # `|| true` is reachable when `return` fails (script not sourced)
  return 0 2>/dev/null || true
fi
_SCRUM_FRONTMATTER_SH_LOADED=1

# capture_frontmatter_key <file> <key>
# Print the value of the first `<key>:` line in <file>'s frontmatter, with
# surrounding whitespace and one matching pair of quotes stripped. Returns 1
# (prints nothing) when the file is missing or the key is absent.
capture_frontmatter_key() {
  local file="$1" key="$2" value
  [ -f "$file" ] || return 1
  value="$(FM_KEY="$key" awk '
    BEGIN { depth = 0; key = ENVIRON["FM_KEY"] }
    /^---$/ { depth++; if (depth > 1) exit; next }
    depth == 1 && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (length(v) >= 2 && ((substr(v, 1, 1) == "\"" && substr(v, length(v)) == "\"") \
          || (substr(v, 1, 1) == "\x27" && substr(v, length(v)) == "\x27")))
        v = substr(v, 2, length(v) - 2)
      print v; found = 1; exit
    }
    END { exit (found ? 0 : 1) }
  ' "$file")" || return 1
  printf '%s\n' "$value"
}

# patch_frontmatter_key <file> <key> <value>
# Replace the first `<key>:` line in <file>'s frontmatter with `<key>: <value>`
# via tmp+mv (same-directory tmp so the mv is atomic). Returns 1 and leaves the
# file untouched when the file is missing or the key is absent — callers that
# treat "nothing to patch" as fine append `|| true`.
patch_frontmatter_key() {
  local file="$1" key="$2" value="$3" tmp
  [ -f "$file" ] || return 1
  tmp="${file}.tmp.$$.${RANDOM}"
  if FM_KEY="$key" FM_VAL="$value" awk '
    BEGIN { depth = 0; done = 0; key = ENVIRON["FM_KEY"]; val = ENVIRON["FM_VAL"] }
    /^---$/ { depth++; print; next }
    depth == 1 && !done && index($0, key ":") == 1 { print key ": " val; done = 1; next }
    { print }
    END { exit (done ? 0 : 1) }
  ' "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}
