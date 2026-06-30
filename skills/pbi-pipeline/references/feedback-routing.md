# Feedback Routing Reference

How the Developer (conductor) builds the per-Round feedback files for
impl and UT agents after a FAIL judgment.

## Routing matrix

| Source | impl agent | UT agent |
|---|---|---|
| impl-reviewer findings | ✓ | – |
| ut-reviewer findings | – | ✓ |
| Test failures (assertion / exec error / uncaught) | ✓ | ✓ |
| Coverage gap — branch unreachable from tests | – | ✓ |
| Coverage gap — implementation dead code | ✓ | – |

## Test failure framing (sent to both)

- **For impl agent:** "Verify your code matches the design, assuming
  tests are correct. If a test asserts behavior the design specifies
  and your code violates it, fix the code."
- **For UT agent:** "Verify your tests match the design's interface,
  assuming impl is correct. If a test asserts behavior NOT in the
  design (or stricter than designed), fix the test."

## Dead-code detection (Developer-side)

For each uncovered branch in `coverage-r{n}.json.files[].uncovered_branches`:

- Read the source line. If it contains a known dead-code marker
  (`raise NotImplementedError`, `panic!()`, `unreachable!()`,
  `assert False`, constant-false comparison) → **route to impl** as
  dead-code finding.
- Otherwise → **route to UT** as missing-test finding.
- If you can't tell → **route to both** (low-cost: each agent will
  no-op if not its concern).

## Web-search remediation (conditional)

When the technical-error-recurrence gate fired this Round (see
`termination-gates.md` § Technical-error recurrence — i.e. the conductor
just set `websearch_attempted true`), prepend the following section to
`feedback/impl-r{n+1}.md` **and** `feedback/ut-r{n+1}.md`. Omit it
entirely on every other Round. List only the recurring web-searchable
technical error(s) — the verbatim error `type` + `message` (and
`stack_trace` first frame if present), or the `:error_handling` finding
text. Do NOT list assertion failures or spec/style findings here.

````markdown
## Web-search remediation (REQUIRED this round)

The following technical error has recurred unresolved across the last
two Rounds. Before editing any code, use the `WebSearch` tool to
research it (error text, library name + version, framework). Cite what
you found and apply a fix grounded in it — do not retry the previous
approach unchanged.

- {type}: {message}
  {first stack frame, if any}
````

## Feedback file template — `feedback/impl-r{n+1}.md`

````markdown
# Impl Feedback for Round {n+1}

{Web-search remediation section here when the gate fired this Round}

## impl-reviewer findings (Round {n})

{For each Critical/High finding from impl/review-r{n}.md, list:}
- [{severity}] {file}:{lines} — {description}

## Test failures (Round {n})

{For each failure in test-results-r{n}.json.failures, list:}
- {test_id}: {type} — {message}
  Framing: Verify your code matches the design. If the test asserts
  behavior the design specifies and your code violates it, fix the code.

## Implementation dead-code warnings

{For each branch routed to impl, list:}
- {file}:{line} — {dead-code marker found}: consider removing the
  unreachable branch.
````

## Feedback file template — `feedback/ut-r{n+1}.md`

````markdown
# UT Feedback for Round {n+1}

{Web-search remediation section here when the gate fired this Round}

## ut-reviewer findings (Round {n})

{For each Critical/High finding from ut/review-r{n}.md, list:}
- [{severity}] {file}:{lines} — {description}

## Test failures (Round {n})

{Same list as impl FB but with UT-side framing:}
- {test_id}: {type} — {message}
  Framing: Verify your tests match the design interface. If the test
  asserts behavior NOT in the design (or stricter than designed),
  fix the test.

## Coverage gaps (need new tests)

{For each uncovered branch routed to UT, list:}
- {file}:{line} (branch from line {from} to line {to}, condition
  {condition}) — add a test that exercises this branch.

## Pragma exclusions to revisit

{For each pragma exclusion with reason_source == "missing" in
pragma-audit-r{n}.json, list:}
- {file}:{line} — exclusion has no inline-comment reason. Either
  remove the exclusion (and add a test) or add a justifying reason.
````

## Cross Review revert input

When a Sprint-end Cross Review aspect 1/2/3 FAIL reverts a PBI to
`in_progress_impl`, the `cross-review` skill drops a single
Round-independent file at
`.scrum/pbi/{pbi_id}/feedback/from-cross-review.md` (a copy of the
per-PBI digest, `.scrum/reviews/{pbi_id}-review.md`). The skill
cannot pre-pick a Round number — `begin-impl-round.sh` owns that.

The conductor MUST, at the start of the next impl Round (i.e. right
after `n=$(begin-impl-round.sh "$PBI_ID")`), fold this file into both
per-Round feedback files and then archive it so subsequent Rounds do
not double-consume the same findings:

```bash
SRC=".scrum/pbi/${PBI_ID}/feedback/from-cross-review.md"
if [ -f "$SRC" ]; then
  for tgt in "impl-r${n}.md" "ut-r${n}.md"; do
    {
      printf '\n## Cross Review feedback (Sprint-end aspect 1/2/3)\n\n'
      cat "$SRC"
    } >> ".scrum/pbi/${PBI_ID}/feedback/${tgt}"
  done
  mv "$SRC" ".scrum/pbi/${PBI_ID}/feedback/from-cross-review.r${n}.archived.md"
fi
```

Both impl and UT agents receive the same Cross Review findings — the
aspect reviewers do not pre-split impl vs UT concerns, so it is the
sub-agents' job to interpret which lines apply to them.
