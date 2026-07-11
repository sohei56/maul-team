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
just set `websearch_attempted true`), the **conductor** runs the web
search itself (it has the `WebSearch` tool; the impl / UT sub-agents do
not) and prepends the following section — filled in with what it found —
to `feedback/impl-r{n+1}.md` **and** `feedback/ut-r{n+1}.md`. Omit it
entirely on every other Round. List only the recurring web-searchable
technical error(s) — the verbatim error `type` + `message` (and
`stack_trace` first frame if present), or the `:error_handling` finding
text. Do NOT list assertion failures or spec/style findings here.

````markdown
## Web-search remediation (REQUIRED this round)

The following technical error has recurred unresolved across the last
two Rounds. The conductor researched it via web search; apply the
findings below and do not retry the previous approach unchanged.

- {type}: {message}
  {first stack frame, if any}

Root cause (from web research): {conductor's finding}
Verified fix guidance: {conductor's finding}
Sources: {source URL(s)}
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

## Integrity-stage revert input

When the per-PBI **Integrity stage** (`integrity-stage.md`) FAILs (any
Critical/High across the 5 aspects — or aspects 1 + 5 for kind=docs)
and no escalate gate fires, the conductor reverts to `in_progress_impl`
and folds the integrity findings into the next Round's feedback. The
conductor is in-process and holds the findings directly (the aggregate
at `.scrum/pbi/<id>/metrics/integrity-r{n}.json`), so it appends them
to the next Round's feedback files with no separate drop file.

At the start of the next impl Round — right after
`n=$(begin-impl-round.sh "$PBI_ID")` — append the integrity
Critical/High findings under a dedicated section to **both** per-Round
feedback files (impl-only for kind=docs, which has no UT agent):

````markdown
## Integrity findings (per-PBI aspect review, Round {n-1})

The following Critical/High findings from the per-PBI Integrity stage
must be resolved. Each is tagged with its aspect and criterion_key;
interpret which apply to your side (impl vs UT).

- [{severity}] [{aspect}] {file}:{lines} ({criterion_key}) — {description}
````

The aspect reviewers do not pre-split impl vs UT concerns — both
sub-agents receive the same findings and each interprets which lines
are its job. A `functional-quality` or
`requirement-conformance` finding about missing test evidence is the
UT agent's to fix; an implementation-correctness or security finding is
the impl agent's. For **kind=docs** there is no `ut-r{n}.md`; the
findings go only to `impl-r{n}.md` and the next Round re-runs
`pbi-implementer` alone.
