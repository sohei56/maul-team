#!/usr/bin/env bats

setup() {
  TEST_TMP="$(mktemp -d /tmp/claude/state-mgmt-test.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/state-mgmt-test.XXXXXX")"
  cd "$TEST_TMP" || exit 1
}

teardown() { rm -rf "$TEST_TMP"; }

# Inline copy of update_state from references/state-management.md
update_state() {
  local pbi_dir="$1"; shift
  local jq_expr="$1"; shift
  local now; now="$(date -Iseconds)"
  jq --arg now "$now" "$jq_expr | .updated_at = \$now" \
    "$pbi_dir/state.json" > "$pbi_dir/state.json.tmp"
  mv "$pbi_dir/state.json.tmp" "$pbi_dir/state.json"
}

@test "atomic update preserves untouched fields" {
  mkdir -p .scrum/pbi/pbi-001
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{ "pbi_id": "pbi-001", "design_round": 0,
  "impl_round": 0, "design_status": "pending",
  "impl_status": "pending", "ut_status": "pending",
  "coverage_status": "pending", "escalation_reason": null,
  "started_at": "2026-05-02T12:00:00+09:00",
  "updated_at": "2026-05-02T12:00:00+09:00" }
EOF
  update_state .scrum/pbi/pbi-001 '.design_round = 1 | .design_status = "in_review"'
  jq -e '.design_round == 1 and .design_status == "in_review" and .impl_status == "pending"' \
    .scrum/pbi/pbi-001/state.json
}

@test "atomic update changes updated_at" {
  mkdir -p .scrum/pbi/pbi-001
  cat > .scrum/pbi/pbi-001/state.json <<'EOF'
{ "updated_at": "2026-05-02T12:00:00+09:00" }
EOF
  sleep 1
  update_state .scrum/pbi/pbi-001 '.'
  new_ts=$(jq -r '.updated_at' .scrum/pbi/pbi-001/state.json)
  [ "$new_ts" != "2026-05-02T12:00:00+09:00" ]
}
