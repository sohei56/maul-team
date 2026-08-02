#!/usr/bin/env bash
# fake-codex.sh — test stub mimicking `codex exec` for integration tests.
# Usage (matches scripts/lib/codex-invoke.sh):
#   fake-codex.sh exec --sandbox read-only --skip-git-repo-check \
#     --output-last-message <verdict_file> - < <instructions_file>
# Behavior: reads instructions from stdin (discarded), writes a
# deterministic verdict to the --output-last-message file (falling
# back to STDOUT when the flag is absent), and emits transcript
# chatter + a token-usage line on stdout/stderr — the caller
# (codex_review_or_fallback) captures both into its log file.
# Override behavior via FAKE_CODEX_VERDICT (PASS or FAIL) and
# FAKE_CODEX_FINDINGS (newline-separated "signature|severity|criterion|description").
set -euo pipefail

# Fast-path the availability probe: codex_is_available (codex-invoke.sh)
# runs `$cmd --version` before every review call.
[ "${1:-}" = "--version" ] && { echo "codex-cli 0.0-stub"; exit 0; }

# Assert the subcommand switched to `exec` (was `review` in the old
# broken invocation).
[ "${1:-}" = "exec" ] || { echo "fake-codex: expected 'exec' subcommand, got '${1:-}'" >&2; exit 1; }

# Extract the --output-last-message target (the real codex writes its
# final agent message there; empty when the flag is absent).
last_message_file=""
prev=""
for arg in "$@"; do
  [ "$prev" = "--output-last-message" ] && last_message_file="$arg"
  prev="$arg"
done

# Drain stdin (the instructions) so codex's stdin contract is honored.
cat >/dev/null || true

verdict="${FAKE_CODEX_VERDICT:-PASS}"

emit_verdict() {
  echo "## Review: fake-codex stub"
  echo ""
  echo "**Verdict: $verdict**"
  echo ""
  echo "### Findings"
  if [ -n "${FAKE_CODEX_FINDINGS:-}" ]; then
    n=0
    while IFS='|' read -r _sig sev crit desc; do
      n=$((n+1))
      echo "- #$n [$sev] [stub] [$crit] — $desc"
    done <<< "$FAKE_CODEX_FINDINGS"
  else
    echo "No findings."
  fi
  echo ""
  echo "### Summary"
  echo "Stub review: $verdict"
  echo ""
  echo '```json'
  if [ -n "${FAKE_CODEX_FINDINGS:-}" ]; then
    findings_json="$(echo "$FAKE_CODEX_FINDINGS" | jq -Rsn '
      [inputs | select(. != "") | split("|") | {
        signature: .[0], severity: .[1], criterion_key: .[2],
        file_path: (.[0] | split(":")[0]),
        line_start: 1, line_end: 1,
        description: .[3]
      }]
    ')"
  else
    findings_json="[]"
  fi
  jq -n --arg v "$verdict" --argjson findings "$findings_json" '{
    status: (if $v == "PASS" then "pass" else "fail" end),
    summary: ("Stub review: " + $v),
    verdict: $v,
    findings: $findings,
    next_actions: [],
    artifacts: []
  }'
  echo '```'
}

if [ -n "$last_message_file" ]; then
  emit_verdict > "$last_message_file"
else
  emit_verdict
fi

# Transcript chatter, mimicking the real codex exec session output that
# codex_review_or_fallback routes into its diagnostic log.
echo "fake-codex: transcript chatter (stdout)"
echo "fake-codex: progress chatter (stderr)" >&2
echo "tokens used: 1234"

exit 0
