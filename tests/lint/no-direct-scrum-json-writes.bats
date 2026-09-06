#!/usr/bin/env bats
# tests/lint/no-direct-scrum-json-writes.bats — the instruction surface must
# not TELL an agent to write .scrum SSOT json directly.
#
# `hooks/pre-tool-use-scrum-state-guard.sh` blocks such a write at runtime, but
# only at the moment the agent runs it: a skill or agent definition that says
# `jq … > .scrum/backlog.json` still ships, still gets read, and only fails
# once an agent obeys it — mid-ceremony, as a hook block the agent must then
# recover from. This lint moves that failure left, to the authoring step.
#
# Scope: the DEPLOYED instruction surface only — `skills/**/*.md`,
# `agents/*.md`, `rules/*.md` (what `scripts/setup-user.sh` copies into a
# target project). `docs/**` is deliberately excluded: the wrapper map in
# docs/MIGRATION-scrum-state-tools.md quotes raw writes on purpose, in its
# "before" column.
#
# Protected paths and their carve-outs mirror the hook (pinned by the drift
# test below). Note which files are NOT exempt: the hot-path runtime json
# (stop-gate/attention/runtime/dashboard/deploy-stamp) is written by hook
# processes and by scrum-start.sh, i.e. outside every file scanned here — an
# *instruction* telling an agent to write one would be blocked by the guard
# like any other raw write, so it is a violation here too.
#
# The detector is deliberately dumb (a fixed set of shell write forms over
# command-looking text) and is exercised by a fixture in this file, so a
# regression that neuters it fails loudly instead of passing vacuously.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  GUARD="${PROJECT_ROOT}/hooks/pre-tool-use-scrum-state-guard.sh"
}

# ---------------------------------------------------------------------------
# Carve-outs — must stay identical to is_exempt_artifact() in the hook.
# These are agent-authored review/metric ARTIFACTS with no wrapper; they are
# written directly by design, and no SSOT file lives under them.
# ---------------------------------------------------------------------------
LINT_EXEMPT=(
  '.scrum/reviews/*.json'
  '.scrum/pbi/*/metrics/*.json'
  '.scrum/pbi/*/ut/*.json'
)

# ---------------------------------------------------------------------------
# Allowlist — legitimate exceptions, "<path>:<line>: <why>" one per entry.
# Empty today: the deployed instruction surface routes every SSOT write
# through a `.scrum/scripts/*.sh` wrapper. An entry belongs here ONLY when no
# wrapper exists for the target file; name the missing wrapper in the comment.
# ---------------------------------------------------------------------------
ALLOWLIST=()

# Path token: a non-space run containing `.scrum/` and ending in `.json`,
# stopping at shell/markdown delimiters so a trailing backtick or `;` is not
# swallowed into the filename.
SCRUM_JSON='[^[:space:]]*\.scrum/[^[:space:];|&)"'"'"'`]*\.json'

# Reduce a markdown file to command-looking text: "<lineno><TAB><text>".
# Fenced blocks contribute every line; unfenced lines contribute only their
# inline-code spans, each span separately (adjacent spans are NOT joined —
# "`<sprint-id>` = `.scrum/sprint.json.id`" must not read as a redirect).
# Anti-pattern demonstrations are dropped: a fence whose opening line or two
# preceding lines carry a negative marker, and any single line carrying one.
# Only text that names a `.scrum/…json` path is emitted (every other line is
# uninteresting, and the whole surface is a few thousand lines).
extract_commands() {
  awk '
    function want(s) { return (index(s, ".scrum/") && index(s, ".json")) }
    function neg(s) {
      return (s ~ /❌/ || s ~ /[Dd]o not/ || s ~ /[Dd]on.t/ \
           || s ~ /[Nn]ever/ || s ~ /[Mm][Uu][Ss][Tt] [Nn][Oo][Tt]/ \
           || s ~ /[Aa]nti-pattern/ || s ~ /[Bb]locked/ \
           || s ~ /[Ff]orbidden/ || s ~ /[Ww]rong/ || s ~ /[Rr]emoved/ \
           || s ~ /[Ii]nstead of/ || s ~ /[Nn]o longer/ || s ~ /bypass/)
    }
    /^[[:space:]]*```/ {
      if (infence) { infence = 0; next }
      infence = 1
      skip = neg($0) || neg(prev1) || neg(prev2)
      next
    }
    {
      if (infence) {
        if (!skip && !neg($0) && want($0)) print NR "\t" $0
      } else if (!neg($0)) {
        n = split($0, span, "`")
        for (i = 2; i <= n; i += 2) if (want(span[i])) print NR "\t" span[i]
      }
      prev2 = prev1; prev1 = $0
    }
  ' "$1"
}

is_exempt_path() {
  local d="$1" pat
  for pat in "${LINT_EXEMPT[@]}"; do
    # shellcheck disable=SC2254  # $pat is a glob on purpose
    case "$d" in *$pat) return 0 ;; esac
  done
  return 1
}

is_allowlisted() {
  local key="$1" entry
  for entry in ${ALLOWLIST+"${ALLOWLIST[@]}"}; do
    case "$entry" in "$key":*) return 0 ;; esac
  done
  return 1
}

# Write destinations in one command, one per line. Six classes:
#   1 redirect  `> f` / `>> f`      (an arrow `->`/`=>` is not a redirect)
#   2 tee/sponge
#   3 mv/cp into the path
#   4 in-place editors + truncate   (the operand IS the write target)
#   5 rm/unlink                     (a raw delete bypasses the wrapper too)
#   6 python/node open-for-write    (open(…,'w'), json.dump, writeFileSync)
# For 4/5/6 the operand is not positional, so every .scrum json token in the
# command counts as a target — same convention as the hook.
write_dests() {
  local cmd="$1"
  printf '%s\n' "$cmd" | grep -oE "(^|[^-=])>>?[[:space:]]*$SCRUM_JSON" \
    | sed -E 's/.*>>?[[:space:]]*//'
  printf '%s\n' "$cmd" \
    | grep -oE "(^|[^[:alnum:]_-])(tee|sponge)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$SCRUM_JSON" \
    | sed -E 's/.*[[:space:]]//'
  printf '%s\n' "$cmd" \
    | grep -oE "(^|[^[:alnum:]_-])(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+$SCRUM_JSON" \
    | sed -E 's/.*[[:space:]]//'
  if printf '%s' "$cmd" | grep -qE "(^|[^[:alnum:]_-])(jq[[:space:]]+-i|sed[[:space:]]+-i|awk[[:space:]]+-i[[:space:]]+inplace|truncate[[:space:]])"; then
    printf '%s\n' "$cmd" | grep -oE "$SCRUM_JSON"
  fi
  if printf '%s' "$cmd" | grep -qE "(^|[^[:alnum:]_-])(rm|unlink)[[:space:]]"; then
    printf '%s\n' "$cmd" | grep -oE "$SCRUM_JSON"
  fi
  if printf '%s' "$cmd" | grep -qE "open\([^)]*\.scrum/[^)]*,[[:space:]]*['\"][wa]" \
     || printf '%s' "$cmd" | grep -qE "(writeFileSync|json\.dump|write_text)\("; then
    printf '%s\n' "$cmd" | grep -oE "$SCRUM_JSON"
  fi
}

# Scan an instruction surface rooted at $1. Emits "<relpath>:<line>: <dest> — <cmd>".
scan_instruction_surface() {
  local root="$1" f rel no cmd d seen tab
  tab="$(printf '\t')"
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    while IFS="$tab" read -r no cmd; do
      seen=""
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        # Drop any leading `$PWD/`, `./` or `open('` noise before `.scrum/`.
        d=".scrum/${d##*.scrum/}"
        # One report per (line, destination) — the classes overlap.
        case "$seen" in *"|$d|"*) continue ;; esac
        seen="$seen|$d|"
        is_exempt_path "$d" && continue
        is_allowlisted "${rel}:${no}" && continue
        printf '%s:%s: %s — %s\n' "$rel" "$no" "$d" \
          "$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//' | cut -c1-120)"
      done <<EOF
$(write_dests "$cmd")
EOF
    done < <(extract_commands "$f")
  done < <(find "$root/skills" "$root/agents" "$root/rules" -name '*.md' 2>/dev/null | sort)
}

# ---------------------------------------------------------------------------
# Negative self-test: the detector must actually fire (GitHub issue #97 —
# a guard only ever shown passing proves nothing).
# ---------------------------------------------------------------------------

@test "detector flags every direct-write class in a fixture" {
  local root="${BATS_TEST_TMPDIR}/bad"
  mkdir -p "$root/skills/demo" "$root/agents" "$root/rules"
  cat > "$root/skills/demo/SKILL.md" <<'FIXTURE'
# Fixture — every line below MUST be flagged.

```bash
echo '{}' > .scrum/backlog.json
printf '%s' "$X" >> .scrum/sprint.json
cat payload.json | tee .scrum/pbi/pbi-001/state.json
cp /tmp/new.json .scrum/config.json
jq '.phase = "x"' .scrum/state.json > /tmp/s && mv /tmp/s .scrum/state.json
jq -i '.a = 1' .scrum/improvements.json
rm .scrum/test-results.json
python3 -c "import json; json.dump(d, open('.scrum/dashboard.json','w'))"
```
FIXTURE
  local out
  out="$(scan_instruction_surface "$root")"
  local expected=(
    '.scrum/backlog.json'
    '.scrum/sprint.json'
    '.scrum/pbi/pbi-001/state.json'
    '.scrum/config.json'
    '.scrum/state.json'
    '.scrum/improvements.json'
    '.scrum/test-results.json'
    '.scrum/dashboard.json'
  )
  local e
  for e in "${expected[@]}"; do
    printf '%s\n' "$out" | grep -qF ": $e — " || {
      echo "detector MISSED a direct write to $e" >&2
      echo "--- detector output ---" >&2
      echo "$out" >&2
      return 1
    }
  done
  # 8 fixture lines, one destination each.
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 8 ] || {
    echo "expected 8 findings, got:" >&2
    echo "$out" >&2
    return 1
  }
}

@test "detector ignores prose, reads, wrappers, carve-outs and anti-patterns" {
  local root="${BATS_TEST_TMPDIR}/good"
  mkdir -p "$root/skills/demo" "$root/agents" "$root/rules"
  cat > "$root/skills/demo/SKILL.md" <<'FIXTURE'
# Fixture — nothing below may be flagged.

The SM reads `.scrum/backlog.json`, then calls
`.scrum/scripts/update-backlog-status.sh --pbi <id> --status merged`.
(`<sprint-id>` = `.scrum/sprint.json.id`.)

```bash
# read-only
jq -r '.id' .scrum/sprint.json 2>/dev/null
SPRINT="$(jq -r '.sprint_id' .scrum/state.json)"
.scrum/scripts/init-state.sh
rm -rf .scrum/worktrees/"$PBI_ID"
# Data flow: hooks -> .scrum/dashboard.json -> dashboard
# carve-outs: agent-authored artifacts, no wrapper exists
jq -n '{findings: []}' > .scrum/reviews/static-analysis-r1.json
cat cov.json > .scrum/pbi/pbi-001/metrics/coverage-r1.json
cat map.json > .scrum/pbi/pbi-001/ut/ac-coverage-r1.json
```

❌ Do not bootstrap state by hand:

```bash
echo '{"phase":"new"}' > .scrum/state.json
```
FIXTURE
  cat > "$root/agents/demo.md" <<'FIXTURE'
Direct edits (`jq -i` on `.scrum/sprint.json`) are blocked by the guard.
FIXTURE
  local out
  out="$(scan_instruction_surface "$root")"
  [ -z "$out" ] || {
    echo "false positives:" >&2
    echo "$out" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# The rule itself.
# ---------------------------------------------------------------------------

@test "no skill/agent/rule instructs a direct .scrum json write" {
  local out
  out="$(scan_instruction_surface "$PROJECT_ROOT")"
  [ -z "$out" ] || {
    echo "Instruction text writes .scrum SSOT json without a wrapper." >&2
    echo "Route it through .scrum/scripts/*.sh (see the wrapper map in" >&2
    echo "docs/MIGRATION-scrum-state-tools.md), or allowlist it in this" >&2
    echo "file naming the wrapper that does not exist yet." >&2
    echo "$out" >&2
    return 1
  }
}

@test "carve-outs stay identical to the runtime guard's" {
  # Drift here is silent and one-directional: the hook grows an exemption,
  # this lint keeps rejecting the newly-legal write (or the reverse, and the
  # lint waves through what the hook still blocks).
  local from_guard from_lint
  from_guard="$(awk '/^is_exempt_artifact\(\)/{f=1} f && /^}/{exit} f' "$GUARD" \
    | grep -oE '\.scrum/[^)[:space:]]*\.json' | sort -u)"
  from_lint="$(printf '%s\n' "${LINT_EXEMPT[@]}" | sort -u)"
  [ -n "$from_guard" ] || {
    echo "could not read is_exempt_artifact() from $GUARD" >&2
    return 1
  }
  [ "$from_guard" = "$from_lint" ] || {
    echo "guard carve-outs and lint carve-outs diverged" >&2
    echo "guard: $from_guard" >&2
    echo "lint:  $from_lint" >&2
    return 1
  }
}
