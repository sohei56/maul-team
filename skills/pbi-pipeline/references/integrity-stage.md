# PBI Integrity Stage Reference

The per-PBI **Integrity stage** is the final quality gate a PBI clears
before ready-to-merge. It runs the 5 cross-cutting review aspects
(requirement-conformance, functional-quality, security,
maintainability, docs-consistency) against **this one PBI's increment**
— "PBI integrity". These aspects used to run Sprint-end across all
merged PBIs; they now run per-PBI, here, so a defect is caught while
its author's context is still live. Whole-repo / cross-PBI review
("product integrity") is the Sprint-end **codebase audit's** job, not
this stage's.

## Placement in the pipeline

The Integrity stage runs **once per Round, at the tail of the Round's
terminal stage, immediately before `mark-pbi-ready-to-merge.sh`**:

```
kind=code:  ... UT Run PASS ──▶ [Integrity stage] ──▶ ready-to-merge
                                      │ FAIL
                                      ▼
                              in_progress_impl (next Round)

kind=docs:  ... impl-reviewer PASS ──▶ [Integrity stage] ──▶ ready-to-merge
                                             │ FAIL
                                             ▼
                                     in_progress_impl (next Round)
```

It does **not** have its own backlog status value (the 12-value enum
is fixed). It executes while the backlog status is still the Round's
terminal stage — `in_progress_ut_run` for kind=code, `in_progress_pbi_review`
for kind=docs — and only advances the status when it either hands off
(`mark-pbi-ready-to-merge.sh` → `in_progress_merge`) or reverts
(`update-backlog-status.sh <pbi> in_progress_impl`).

The Round counter is the existing `impl_round` (`$n`). The Integrity
stage does **not** introduce a counter. A FAIL loops through
`begin-impl-round.sh` exactly like a PBI Review FAIL or UT Run FAIL,
so the hard cap (`impl_round >= 5`) bounds the Integrity retry loop
with no new counter regime. See `termination-gates.md` § Integrity
stage.

## Aspect set by kind

| kind | Aspects spawned |
|---|---|
| code | all 5: requirement-conformance, functional-quality, security, maintainability, docs-consistency |
| docs | 2 only: requirement-conformance (aspect 1) + docs-consistency (aspect 5) |

The kind=docs subset is parity with the old Sprint-end rule (a docs
PBI was only ever evaluated against aspects 1 and 5). functional-quality,
security, and maintainability are code-only and are never spawned for a
docs PBI.

## Reviewer model & backing

The five aspect reviewers are Claude-backed (`model: opus` in their
frontmatter) — **not** codex-backed. The codex preflight
(`sub-agent-prompts.md` § Conductor codex preflight) does **not** apply
here; spawn them with no `model` override. The
`reviewer-stall-fallback.md` codex-stall protocol also does not apply
(there is no codex to hang). These reviewers are **message-based**:
they have no `Write` tool and return their review as their final
assistant message; the conductor reads the returned message directly
from the synchronous `Agent` call (no review file for the reviewer to
persist, so the "completed-but-unpersisted" branch is moot).

They return **markdown**, not the pbi-pipeline JSON envelope. The
envelope's `criterion_key` enum
(`docs/contracts/pbi-pipeline-envelope.schema.json`) is
codex-reviewer-specific and does not cover the aspect vocabularies, so
each aspect reports a `**Verdict: PASS | FAIL**` line plus a markdown
Findings list carrying its own `criterion_key`. The conductor parses
the Verdict line and Findings from each returned message and
synthesizes the structured aggregate itself (Step I-4).

## Stage procedure (kind=code — all 5 aspects)

Entry: control reaches here from `impl-ut-stage.md` Step 4 UT Run
PASS, with `$n` = current `impl_round` and backlog status
`in_progress_ut_run`.

### Step I-1: Capture the review snapshot

The worktree is quiescent during this stage — the conductor spawns
reviewers and waits; no producer sub-agent runs concurrently — so a
single snapshot capture is stable and no pin-mismatch respawn loop is
needed (unlike the impl/UT review stages, where parallel Rounds can
move HEAD mid-review).

```bash
WT=".scrum/worktrees/$PBI_ID"
REVIEW_SHA="$(git -C "$WT" rev-parse HEAD)"
BASE_SHA="$(jq -r '.base_sha' .scrum/sprint.json)"
PATHS_TOUCHED="$(jq -r --arg id "$PBI_ID" \
  '.items[] | select(.id==$id) | .paths_touched[]?' .scrum/backlog.json)"
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" start integrity
```

`{review_sha}` and `{base_sha}` are passed to every aspect reviewer as
the diff bounds; `paths_touched` limits the diff to this PBI's files.

### Step I-2: Pass-A static analysis (maintainability input)

Before spawning, the conductor runs **Pass-A intra-file lint over this
PBI's diff files only** (not the whole repo) and writes the aggregate
to the per-PBI metrics path the maintainability reviewer reads:

```bash
OUT=".scrum/pbi/$PBI_ID/metrics/static-analysis-r$n.json"
# Diff-scoped file list, split by language:
CHANGED="$(git -C "$WT" diff --name-only "$BASE_SHA".."$REVIEW_SHA" -- $PATHS_TOUCHED)"
PY_FILES="$(echo "$CHANGED" | grep -E '\.py$' || true)"
SH_FILES="$(echo "$CHANGED" | grep -E '\.sh$' || true)"
# Python → ruff F401,F841,ARG,B ; Shell → shellcheck ; both emit JSON.
#   (cd "$WT" && ruff check --select F401,F841,ARG,B --output-format json $PY_FILES)
#   (cd "$WT" && shellcheck -f json $SH_FILES)
# Normalize both tools' output into one static-analysis-r$n.json matching
# agents/maintainability-reviewer.md § Receives (one tools[] entry per
# tool; kind ∈ {unused_import,unused_variable,unused_argument,dead_branch,
# other}; F401→unused_import, F841→unused_variable, ARG→unused_argument,
# else other). On any tool failure set that tools[].exit_code non-zero and
# keep going. If no py/shell files match, set skipped_reason and continue —
# the reviewer degrades gracefully (static_analysis_status=unavailable).
```

This mirrors the old Sprint-end Pass A, re-scoped to the PBI diff. The
whole-repo Pass-B / `vulture` reachability scan is **not** run here —
that `unused_export` class is the Sprint-end audit's redundancy axis.

### Step I-3: Spawn the aspect reviewers in parallel

Issue all 5 `Agent` calls in a single message (Claude Code parallel
execution), **synchronous** (`run_in_background: false`), no `model`
override. Prompts come from `sub-agent-prompts.md` § Integrity aspect
reviewers, with `{review_sha}`, `{base_sha}`, `{paths_touched}`, and
(maintainability only) the static-analysis path filled in.

```text
Agent(subagent_type="requirement-conformance-reviewer", prompt=<...>)
Agent(subagent_type="functional-quality-reviewer",      prompt=<...>)
Agent(subagent_type="security-reviewer",                prompt=<...>)
Agent(subagent_type="maintainability-reviewer",         prompt=<...>)
Agent(subagent_type="docs-consistency-reviewer",        prompt=<...>)
```

Wait for all to return (the synchronous calls themselves — never a
hand-rolled poll loop; see `reviewer-stall-fallback.md` § Bounded
waiting). If a reviewer returns **without a parseable `**Verdict:**`
line** (or an empty/garbled message), respawn that ONE reviewer once
with the identical prompt; if the second attempt is still unparseable,
escalate via the existing flow with
`escalation_reason=reviewer_unavailable` (`update-pbi-state.sh` +
`update-backlog-status.sh escalated` + `notify_sm_escalation`).

### Step I-4: Aggregate findings + compute verdict

Parse each returned message's `**Verdict:**` line and its markdown
Findings list (`- #k [Severity] [File:Lines] [criterion_key] —
Description`). For each finding synthesize the signature
`{file}:{line_start}-{line_end}:{criterion_key}` and record its
`severity` + `aspect`. Union across the aspects and persist the
aggregate so the next Round can compare (termination gates):

```bash
AGG=".scrum/pbi/$PBI_ID/metrics/integrity-r$n.json"
# AGG = { "round": n, "aspects": ["requirement-conformance", ...],
#         "findings": [ { "signature": "<file>:<s>-<e>:<criterion_key>",
#                         "severity": "critical|high|medium|low",
#                         "aspect": "<aspect>", "description": "..." }, ... ] }
```

This aggregate is the conductor's own artifact — it is NOT a sub-agent
envelope and is not bound by `pbi-pipeline-envelope.schema.json`, so
the aspect criterion_keys are free to use each aspect's vocabulary.

**Integrity verdict** — deterministic:

```text
FAIL  if any finding across any aspect has severity ∈ {critical, high}
PASS  otherwise
```

Medium/Low findings are recorded in the consolidated doc only — they
do **not** fail the stage.

### Step I-5a: PASS → author the consolidated doc + hand off

Write the consolidated review doc to the **exact** path
`.scrum/reviews/<pbi-id>-review.md` (the DoD path `hooks/quality-gate.sh`
gates on) via heredoc, following the pipeline's file-persistence
pattern. Embed each aspect's returned markdown section verbatim:

```bash
mkdir -p .scrum/reviews
DOC=".scrum/reviews/$PBI_ID-review.md"
cat > "$DOC" <<EOF
# PBI Integrity Review — $PBI_ID

Reviewed-Head: $REVIEW_SHA
Round: $n
Verdict: PASS

$(: "each aspect's returned markdown section, in aspect order")
$REQUIREMENT_CONFORMANCE_SECTION
$FUNCTIONAL_QUALITY_SECTION
$SECURITY_SECTION
$MAINTAINABILITY_SECTION
$DOCS_CONSISTENCY_SECTION

## Non-blocking findings (Medium/Low)

$(: "list any Medium/Low findings for the record")
EOF

.scrum/scripts/set-backlog-item-field.sh "$PBI_ID" review_doc_path "$DOC"
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" gate "integrity PASS → ready-to-merge"
```

Then return to `impl-ut-stage.md` Step 4 Success branch, which writes
the stage summaries and runs `mark-pbi-ready-to-merge.sh`. `review_doc_path`
is now set and the file exists, satisfying the quality-gate DoD before
status becomes `in_progress_merge`.

### Step I-5b: FAIL → revert through existing feedback-routing

A FAIL routes exactly like a PBI Review / UT Run FAIL. **First**
evaluate the termination gates on the aggregated integrity findings
(see `termination-gates.md` § Integrity stage — Success is already
ruled out, then Stagnation / Divergence / Hard cap on the union). If an
escalate gate fires:

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" escalation_reason "<reason>"
.scrum/scripts/update-backlog-status.sh "$PBI_ID" escalated
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" gate "escalate → <reason>"
notify_sm_escalation "$PBI_ID" "<reason>"
```

Otherwise revert to impl for the next Round and build feedback (see
`feedback-routing.md` § Integrity-stage revert input — the Critical/High
findings fold into `impl-r{n+1}.md` and `ut-r{n+1}.md`, each sub-agent
interpreting which lines apply to it):

```bash
.scrum/scripts/update-pbi-state.sh "$PBI_ID" impl_status fail
.scrum/scripts/update-backlog-status.sh "$PBI_ID" in_progress_impl
.scrum/scripts/append-pbi-log.sh "$PBI_ID" pbi_review "$n" gate "integrity FAIL → next round"
# Loop back to impl-ut-stage.md "Pipeline entry"; begin-impl-round.sh returns n+1.
```

## Stage procedure (kind=docs — aspects 1 + 5 only)

Entry: control reaches here from `impl-ut-stage.md` Step 4 with the
single impl-reviewer PASS and backlog status `in_progress_pbi_review`.

Identical to the kind=code procedure with these reductions:

- **Step I-2 (Pass-A static analysis) is skipped** — maintainability
  is not spawned for docs PBIs, and a docs diff has no source to lint.
- **Step I-3** spawns only `requirement-conformance-reviewer` and
  `docs-consistency-reviewer` (both carry a kind=docs branch in their
  agent definitions — semantic AC satisfaction + parent-fix
  verification against `.scrum/reviews/<parent-pbi-id>-review.md`).
- **Step I-5b FAIL** folds findings into `impl-r{n+1}.md` ONLY (there
  is no `ut-r{n+1}.md` for a docs PBI); the next impl Round re-runs
  `pbi-implementer` alone.
- Verdict, consolidated-doc authoring, and `review_doc_path` handoff
  are identical.

## Why this stage exists

The 5 aspects catch defect classes the codex impl/UT reviewers do not:
requirement traceability, OWASP security, structural maintainability,
and doc-impl drift. Running them per-PBI (rather than once at
Sprint-end) means each finding lands while the PBI's own worktree,
design, and author-context are live and cheaply fixable through the
same Round loop, instead of after N PBIs have already merged. It also
lets the Sprint-end review shrink to a pure whole-repo audit ("product
integrity") that no longer re-derives per-PBI conformance.
