#!/usr/bin/env bats
# Issue #96: design review returned `missing_ac_mapping` against design
# docs whose mapping table carried every criterion verbatim, and one
# case traced to the conductor abbreviating the ACs in the reviewer's
# prompt. Pins the two fixes: the reviewer reads the ACs from the
# backlog record (never a prompt paste), and every `missing_ac_mapping`
# finding carries a byte-level comparison in the review file.

# The same contract is pinned for the Integrity stage's aspect-1
# (requirement-conformance) reviewer, which asserts unmapped/unmet ACs
# from the very same record.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  AGENT="${PROJECT_ROOT}/agents/codex-design-reviewer.md"
  ASPECT1="${PROJECT_ROOT}/agents/requirement-conformance-reviewer.md"
  PROMPTS="${PROJECT_ROOT}/skills/pbi-pipeline/references/sub-agent-prompts.md"
}

# Print the lines under heading "$2" of file "$1", up to the next `## `.
_section() {
  awk -v h="$2" 'index($0, h) == 1 { f = 1; next }
                 f && /^## / { exit }
                 f { print }' "$1"
}

# Join stdin onto one line so a check never depends on where prose wraps.
_flat() { tr '\n' ' ' | tr -s ' '; }

# The contract, as a function of (agent_file, prompts_file) so the same
# checks can be run against a deliberately broken copy. Prints the
# violated rule and returns 1 on the first failure.
ac_evidence_lint() {
  local agent="$1" prompts="$2" reviewer receives criterion6 flow
  reviewer="$(_section "$prompts" '## codex-design-reviewer prompt' | _flat)"
  receives="$(_section "$agent" '## Receives' | _flat)"
  criterion6="$(awk '/^6\. \*\*AC Mapping completeness\*\*/ { f = 1 }
                     /^7\. \*\*Library Selection/ { f = 0 }
                     f' "$agent" | _flat)"
  flow="$(_section "$agent" '## Processing Flow' | _flat)"

  # 1. The reviewer prompt no longer hands over a conductor paste.
  if printf '%s' "$reviewer" | grep -qF 'paste backlog.json entry'; then
    echo "prompt template still pastes the backlog entry"; return 1
  fi
  # 2. It names the backlog record and the read that fetches it.
  printf '%s' "$reviewer" | grep -qF '.scrum/backlog.json' || {
    echo "prompt template does not name .scrum/backlog.json"; return 1; }
  printf '%s' "$reviewer" \
    | grep -qF "jq '.items[] | select(.id==\"{pbi_id}\")' .scrum/backlog.json" || {
    echo "prompt template lacks the jq read instruction"; return 1; }
  # 3. The path is justified as worktree-relative via the .scrum symlink.
  printf '%s' "$reviewer" | grep -qF 'worktree root' || {
    echo "prompt template does not state the path is worktree-relative"
    return 1; }
  printf '%s' "$reviewer" | grep -qF '`.scrum` symlink' || {
    echo "prompt template does not cite the .scrum symlink"; return 1; }
  # 4. Comparing against a prompt-side summary is forbidden.
  printf '%s' "$reviewer" | grep -qF 'never against any' || {
    echo "prompt template does not forbid summary comparison"; return 1; }
  # 5. Unreadable AC source is an error envelope, not a FAIL verdict.
  printf '%s' "$reviewer" | grep -qF 'status=error envelope, not a FAIL verdict' || {
    echo "prompt template does not route a missing entry to the error path"
    return 1; }

  # 6. The agent definition reads the entry itself.
  printf '%s' "$receives" \
    | grep -qF "jq '.items[] | select(.id==\"<pbi-id>\")' .scrum/backlog.json" || {
    echo "agent § Receives lacks the jq read"; return 1; }
  printf '%s' "$receives" | grep -qF 'never compare against a summary' || {
    echo "agent § Receives does not forbid summary comparison"; return 1; }
  # 7. Per-criterion evidence obligation on every missing_ac_mapping.
  printf '%s' "$criterion6" | grep -qF '**Evidence obligation.**' || {
    echo "criterion 6 has no evidence obligation"; return 1; }
  local token
  for token in 'the exact AC text' 'the exact string(s) you searched' \
               'the matching mapping-table row' 'the literal word `absent`'; do
    printf '%s' "$criterion6" | grep -qF "$token" || {
      echo "evidence obligation is missing: $token"; return 1; }
  done
  printf '%s' "$criterion6" \
    | grep -qF 'malformed — drop it rather than report it' || {
    echo "evidence obligation does not make an unevidenced finding malformed"
    return 1; }
  # 8. Processing Flow reads the entry and has the error path.
  printf '%s' "$flow" | grep -qF 'backlog_entry_unreadable' || {
    echo "processing flow lacks the backlog_entry_unreadable error path"
    return 1; }
  printf '%s' "$flow" | grep -qF 'never a FAIL' || {
    echo "processing flow does not exclude a FAIL verdict on a bad read"
    return 1; }
  return 0
}

@test "shipped agent + prompt template satisfy the AC-evidence contract" {
  run ac_evidence_lint "$AGENT" "$PROMPTS"
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "lint rejects a template that pastes the entry back in" {
  local bad_prompts="${BATS_TEST_TMPDIR}/prompts.md"
  sed "s|^ *jq '\.items\[\].*|{paste backlog.json entry for {pbi_id}}|" \
    "$PROMPTS" > "$bad_prompts"
  grep -qF 'paste backlog.json entry for {pbi_id}' "$bad_prompts"

  run ac_evidence_lint "$AGENT" "$bad_prompts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pastes the backlog entry"* ]]
}

@test "lint rejects an agent definition stripped of its evidence obligation" {
  local bad_agent="${BATS_TEST_TMPDIR}/agent.md"
  grep -vF '**Evidence obligation.**' "$AGENT" > "$bad_agent"

  run ac_evidence_lint "$bad_agent" "$PROMPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no evidence obligation"* ]]
}

@test "lint rejects an evidence obligation missing a comparison element" {
  local bad_agent="${BATS_TEST_TMPDIR}/agent-partial.md"
  sed 's/the exact string(s) you searched/whatever you looked for/' \
    "$AGENT" > "$bad_agent"

  run ac_evidence_lint "$bad_agent" "$PROMPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing: the exact string(s) you searched"* ]]
}

@test "lint rejects a bad AC read routed to FAIL instead of the error path" {
  local bad_agent="${BATS_TEST_TMPDIR}/agent-noerr.md"
  grep -vF 'backlog_entry_unreadable' "$AGENT" > "$bad_agent"

  run ac_evidence_lint "$bad_agent" "$PROMPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"backlog_entry_unreadable error path"* ]]
}

@test "removal is scoped to the reviewer: the designer still gets the entry" {
  local designer
  designer="$(_section "$PROMPTS" '## pbi-designer prompt')"
  printf '%s' "$designer" | grep -qF '{paste backlog.json entry for {pbi_id}}'
}

# --- Integrity stage, aspect-1 (requirement-conformance) ----------------
# Same contract, same reason: the aspect-1 reviewer asserts unmapped
# (`missing_requirement`) and unmet (`semantic_ac_unmet`) ACs, so it must
# read them from the record rather than trust a conductor paste, and must
# evidence every such finding.

aspect1_evidence_lint() {
  local agent="$1" prompts="$2" skeleton receives criteria
  skeleton="$(_section "$prompts" '## Integrity aspect reviewers' | _flat)"
  receives="$(_section "$agent" '## Receives' | _flat)"
  criteria="$(_section "$agent" '## Review Criteria' | _flat)"

  # 1. The shared aspect skeleton no longer hands over a conductor paste.
  if printf '%s' "$skeleton" | grep -qF 'paste backlog.json entry'; then
    echo "aspect prompt skeleton still pastes the backlog entry"; return 1
  fi
  # 2. It names the record and the read that fetches it.
  printf '%s' "$skeleton" \
    | grep -qF "jq '.items[] | select(.id==\"{pbi_id}\")' .scrum/backlog.json" || {
    echo "aspect prompt skeleton lacks the jq read instruction"; return 1; }
  # 3. The path is justified as worktree-relative via the .scrum symlink.
  printf '%s' "$skeleton" | grep -qF 'worktree root' || {
    echo "aspect prompt skeleton does not state the path is worktree-relative"
    return 1; }
  printf '%s' "$skeleton" | grep -qF '`.scrum` symlink' || {
    echo "aspect prompt skeleton does not cite the .scrum symlink"; return 1; }
  # 4. Comparing against a prompt-side summary is forbidden.
  printf '%s' "$skeleton" | grep -qF 'never against any' || {
    echo "aspect prompt skeleton does not forbid summary comparison"
    return 1; }
  # 5. An unread AC is not a failed AC (no fabricated finding).
  printf '%s' "$skeleton" | grep -qF 'report NO AC-conformance finding' || {
    echo "aspect prompt skeleton does not route an unreadable record away"
    echo "from an AC-conformance finding"
    return 1; }

  # 6. The aspect-1 agent definition reads the entry itself.
  printf '%s' "$receives" \
    | grep -qF "jq '.items[] | select(.id==\"<pbi-id>\")' .scrum/backlog.json" || {
    echo "aspect-1 § Receives lacks the jq read"; return 1; }
  printf '%s' "$receives" | grep -qF 'never compare against a summary' || {
    echo "aspect-1 § Receives does not forbid summary comparison"; return 1; }
  # 7. Per-criterion evidence obligation, kept in sync with criterion 6
  #    of codex-design-reviewer.
  printf '%s' "$criteria" | grep -qF '**Evidence obligation (both kinds).**' || {
    echo "aspect-1 has no evidence obligation"; return 1; }
  local token
  for token in 'the exact AC text' 'the exact string(s) you searched' \
               'the literal word `absent`' 'missing_requirement' \
               'semantic_ac_unmet' '§ Review Criteria 6'; do
    printf '%s' "$criteria" | grep -qF "$token" || {
      echo "aspect-1 evidence obligation is missing: $token"; return 1; }
  done
  printf '%s' "$criteria" \
    | grep -qF 'malformed — drop it rather than report it' || {
    echo "aspect-1 obligation does not make an unevidenced finding malformed"
    return 1; }
  return 0
}

# Rewrite only the Integrity section's jq read back into a paste, so the
# fixture proves the aspect check is independent of the reviewer check.
_paste_back_aspect1() {
  awk '/^## Integrity aspect reviewers/ { in_sec = 1 }
       in_sec && /jq .\.items\[\]/ {
         print "{paste backlog.json entry for {pbi_id}}"; next }
       { print }' "$1"
}

@test "aspect-1 agent + prompt skeleton satisfy the AC-evidence contract" {
  run aspect1_evidence_lint "$ASPECT1" "$PROMPTS"
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "lint rejects an aspect skeleton that pastes the entry back in" {
  local bad_prompts="${BATS_TEST_TMPDIR}/prompts-aspect.md"
  _paste_back_aspect1 "$PROMPTS" > "$bad_prompts"
  grep -qF 'paste backlog.json entry for {pbi_id}' "$bad_prompts"

  run aspect1_evidence_lint "$ASPECT1" "$bad_prompts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skeleton still pastes the backlog entry"* ]]

  # Scoped: the codex-design-reviewer contract is untouched by it.
  run ac_evidence_lint "$AGENT" "$bad_prompts"
  [ "$status" -eq 0 ] || echo "$output"
  [ "$status" -eq 0 ]
}

@test "lint rejects an aspect-1 definition stripped of its obligation" {
  local bad_agent="${BATS_TEST_TMPDIR}/aspect1.md"
  grep -vF '**Evidence obligation (both kinds).**' "$ASPECT1" > "$bad_agent"

  run aspect1_evidence_lint "$bad_agent" "$PROMPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no evidence obligation"* ]]
}

@test "lint rejects an aspect-1 definition that drops the record read" {
  local bad_agent="${BATS_TEST_TMPDIR}/aspect1-noread.md"
  grep -vF 'select(.id=="<pbi-id>")' "$ASPECT1" > "$bad_agent"

  run aspect1_evidence_lint "$bad_agent" "$PROMPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"§ Receives lacks the jq read"* ]]
}
