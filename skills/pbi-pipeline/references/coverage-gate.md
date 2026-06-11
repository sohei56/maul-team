# Coverage Gate Reference

How the Developer (conductor) runs tests, measures coverage, audits
pragma exclusions, and evaluates Pass criteria.

## Configuration source

Default: `.scrum/config.json`. Reference: `.scrum-config.example.json`.

Per-PBI override: design doc may contain a fenced YAML block with the
language tag `yaml runtime-override` inside the `Test Strategy Hints`
section. Developer deep-merges over the project default for that PBI
only.

## Language reference matrix

| Language | Test runner | Coverage tool | C1 |
|---|---|---|---|
| Python | pytest | coverage.py `--branch` | yes |
| TypeScript | vitest | c8 `--all --branches` | yes (c8 0.7+) |
| Go | go test | go test -covermode=count + gocov-xml | C0 only |
| Rust | cargo test | cargo-llvm-cov `--mcdc` | partial |
| Java | JUnit | JaCoCo `branch=true` | yes |
| Bash | bats | bashcov | partial |

For partial-C1 languages, `.scrum/config.json` MUST declare relaxed
threshold (e.g., `"c1_threshold": 0.95`); ad-hoc relaxation is
forbidden.

## Measurement sequence (Phase 2 Step 2)

(a) **Test + coverage run**

```bash
CFG=".scrum/config.json"
RUN_CMD="$(jq -r '.coverage_tool.command' "$CFG")"
mapfile -t RUN_ARGS < <(jq -r '.coverage_tool.run_args[]' "$CFG")
"$RUN_CMD" "${RUN_ARGS[@]}"
EX=$?
# nonzero EX is OK here (tests may have failed) — failures recorded
# in subsequent steps. Tool-launch failure → escalate.
```

(b) **Coverage report generation**

```bash
mapfile -t REPORT_ARGS < <(jq -r '.coverage_tool.report_args[]' "$CFG")
REPORT_PATH=".scrum/pbi/$PBI_ID/metrics/coverage-r$ROUND.json"
"$RUN_CMD" "${REPORT_ARGS[@]}" "$REPORT_PATH"
```

(c) **Normalize coverage to common schema**

Read raw output → transform into the schema documented in
`docs/contracts/coverage-rN.schema.json`. Overwrite `$REPORT_PATH`.

(d) **Normalize test results**

Read junit XML or json → transform into the schema in
`docs/contracts/test-results-rN.schema.json`. Write to
`.scrum/pbi/$PBI_ID/metrics/test-results-r$ROUND.json`.

(e) **Pragma audit**

```bash
PATTERN="$(jq -r '.pragma_pattern' "$CFG")"
# Grep all test files for $PATTERN; for each match, capture file:line +
# look at the line above and the inline part of the line for the reason
# text. Build pragma-audit-r{n}.json per spec 6.6.
```

(f) **AC coverage map (written by pbi-ut-author, not the conductor)**

`.scrum/pbi/$PBI_ID/ut/ac-coverage-r{n}.json` is emitted by
`pbi-ut-author` at the end of each impl+UT Round (see
`agents/pbi-ut-author.md` § "AC coverage map" for full schema and
rules). Shape (summary):

```json
{
  "pbi_id": "pbi-NNN",
  "round": 1,
  "criteria": [
    {
      "index": 1,
      "text": "<verbatim AC text>",
      "tests": ["<file>::<test-name>"]
    }
  ]
}
```

This file is the input to the AC coverage gate that the conductor
evaluates in Step 4 of `impl-ut-stage.md` § "Aggregate Pass criteria"
(every `criteria[].tests` non-empty AND no listed test id appears in
`test-results-r{n}.json` `failures[]`). It is also an input to
`codex-ut-reviewer` (Review Criterion #2) and to the Sprint-end
`requirement-conformance-reviewer`.

## Pass criteria evaluation

```bash
evaluate_pass() {
  local cov="$1" tests="$2" pragma="$3" impl_rev="$4" ut_rev="$5" cfg="$6"
  local c0_th c1_th
  c0_th=$(jq -r '.c0_threshold // 100' "$cfg")
  c1_th=$(jq -r '.c1_threshold // 100' "$cfg")
  local failed exec_err uncaught
  failed=$(jq '.totals.failed' "$tests")
  exec_err=$(jq '.totals.exec_errors' "$tests")
  uncaught=$(jq '.totals.uncaught_exceptions' "$tests")
  [[ "$failed" -eq 0 && "$exec_err" -eq 0 && "$uncaught" -eq 0 ]] || { echo "test_failures"; return 1; }

  local c0 c1_supp c1
  c0=$(jq '.totals.c0.percent' "$cov")
  c1_supp=$(jq '.totals.c1.supported' "$cov")
  c1=$(jq '.totals.c1.percent' "$cov")
  awk "BEGIN{exit !($c0 >= $c0_th)}" || { echo "c0_below"; return 1; }
  if [[ "$c1_supp" == "true" ]]; then
    awk "BEGIN{exit !($c1 >= $c1_th)}" || { echo "c1_below"; return 1; }
  fi

  jq -e '.exclusions | all(.reason_source != "missing")' "$pragma" > /dev/null \
    || { echo "pragma_unjustified"; return 1; }

  grep -q '^\*\*Verdict: PASS\*\*' "$impl_rev" || { echo "impl_review_fail"; return 1; }
  grep -q '^\*\*Verdict: PASS\*\*' "$ut_rev" || { echo "ut_review_fail"; return 1; }

  return 0
}
```

## Coverage skip (project-wide)

When `coverage_tool == null` in `.scrum/config.json`:

- Skip steps (a)-(c)
- Still run tests via `test_runner` and produce test-results
- Skip coverage_status check in Pass criteria
- Design doc preamble MUST record skip reason
- codex-design-reviewer FAILs if reason missing
