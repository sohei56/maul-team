# codebase-audit — auditor protocol + axis prompts

The Scrum Master spawns one `Agent`-tool auditor per axis, in parallel.
This file holds the shared protocol, the finding-return schema, and the
four axis-specific prompt templates. Paste the **Common protocol** head
plus **one** axis section into each auditor's prompt, and append the
shared read set (enabled specs, requirements, PBI summary, most recent
`static-analysis-r*.json` path) assembled in SKILL.md Step 2.

---

## Common protocol (prepend to every auditor)

You are a read-only auditor of the **whole repository at HEAD** — the
accumulated codebase across all Sprints so far, not a diff. Your job is
to find defects that diff-scoped reviews structurally cannot see.

Rules:

- **Read-only. Never edit** any file — no code, docs, specs, or state.
  If you are tempted to fix something, record it as a finding instead.
- **Whole-repo scope.** Do not restrict yourself to recently changed
  files. The value of this pass is in what accumulated across Sprints.
- **Sweep to zero.** When you find a defect, generalize it to its
  defect **class** (the rule violated / the guard missing / the drift
  pattern) and search the whole repo for every other instance BEFORE
  reporting — grep for the pattern, then reason about variants a grep
  would miss. Report ONE finding per class with the complete occurrence
  list, never one finding per site. A class reported from a single site
  without a sweep is the primary cause of audit churn: the remaining
  sites resurface Sprint after Sprint as "new" findings.
- **Evidence discipline.** Every finding needs a concrete `file:line`
  anchor and the observed fact. Keep **fact** and **interpretation**
  strictly separate — never present a hypothesis as an observation.
- **Confidence.** State High/Medium/Low confidence per finding. When
  you cannot verify reachability or intent from the code + specs, say
  so and lower the confidence rather than asserting.
- **Do not re-derive per-PBI review context.** Per-PBI and Sprint-diff
  review already ran; assume in-diff correctness was checked. Spend
  your budget on cross-cutting and accumulated defects.
- **No spec invention.** "Enabled specs" = the IDs in
  `docs/design/catalog-config.json`. Behavior absent from an enabled
  spec and from `requirements.md` is out of scope for conformance
  judgments (but coded-but-unspecified behavior IS a redundancy /
  spec-gap signal — see the relevant axes).

**Return format.** Return your findings **as your final assistant
message** — do NOT write any file. The Scrum Master synthesizes and
persists the report. Use this schema per finding:

```
### <F-local-id> <one-line title>
- axis: spec-conformance | logic-defect | redundancy | product-security
- severity_hint: Critical | High | Medium | Low   (SM may re-rank on dedup)
- location: <path>:<line> (primary occurrence)
- occurrences: <path>:<line> — <symbol>   (one line per instance the
  sweep found — ALL of them; a genuinely single-site defect lists one)
- sweep: <the searches + reasoning establishing the occurrence list is
  complete — patterns tried, variants considered; "single-site by
  construction" only when the defect cannot recur elsewhere>
- identity: <stable defect-CLASS key — a single-site defect uses
  <path>::<symbol-or-anchor>; a multi-site class uses a stable class
  slug like <rule-or-guard>::<pattern>. Never line numbers, which
  drift between Sprints; the SM uses this for cross-Sprint dedup>
- fact: <what is literally observed in the code/spec — no inference>
- interpretation: <why it is a defect; the failure it causes>
- confidence: High | Medium | Low
- proposed_fix: <one line; becomes the PBI AC seed>
```

End with a one-line summary: `<n> findings (<c> Critical, <h> High, <m>
Medium, <l> Low)`. If you found nothing, say so explicitly — an empty
result is a valid, useful outcome.

---

## Axis A — `spec-conformance`

Compare the **implementation** against the **enabled design specs** and
`requirements.md`. Hunt three failure classes:

1. **Divergence** — code whose observable behavior contradicts an
   enabled spec or a requirement (wrong default, wrong ordering, a
   state transition the spec forbids, a return shape the spec does not
   allow). Anchor to both the spec line and the code line.
2. **Coded-but-unspecified behavior** — production code paths that
   implement behavior no enabled spec or requirement asks for. This is
   often **dead code that is also a spec gap**: either the requirement
   was dropped and the code should go, or the code is real and the
   spec is missing. Flag it and say which you believe, with confidence.
3. **Spec-vs-spec conflict** — two enabled design docs mandating
   contradictory behavior for the same interface / rule / state.
   **Before flagging, read `.scrum/po/decisions.json`** and check for
   an adjudication of that conflict (a `spec_clarification` /
   `change_request` / `scope_change` decision that resolves it). If the
   PO already decided, it is **not** a finding — the code should follow
   the decision, and you check that instead. Only unadjudicated
   contradictions are findings.

Map each finding to the PBI(s) whose `paths_touched` / area it lands in
(reverse-lookup from the PBI summary) so the SM can scope a fix PBI.

Severity guide: a divergence that breaks a core AC or an unadjudicated
conflict that makes correct behavior undefined → Critical; a divergence
that changes observable behavior on a primary path → High;
coded-but-unspecified dead paths → Medium unless they execute in
production.

---

## Axis B — `logic-defect`

Hunt the **I/O orchestration and wiring layer** — the glue between
pure functions and the outside world (config loading, request
handlers, schedulers, persistence calls, external-service clients,
CLI/entrypoint wiring). **The pure-function layer is usually
well-covered by unit tests; the yield is in the wiring**, precisely
because unit tests mock those boundaries out. Focus there.

Look for:

- **Feature-disabling production defaults** — a default config /
  flag / constant value that silently turns a feature off in
  production (e.g. a batch size of 0, a `dry_run=True` default, a
  disabled scheduler, an empty allowlist that blocks everything).
- **Boundaries unit tests mock out** — logic that only executes against
  the real DB / queue / HTTP / clock / filesystem and therefore was
  never actually exercised: missing pagination (a `fetch` that reads
  only the first page), missing locking / race windows on shared
  state, unbounded retries, off-by-one on real timestamps.
- **Silent failures** — swallowed exceptions (`except: pass`, catch
  blocks that log-and-continue when they must abort), an overly broad
  caught exception type that masks a real error, ignored return codes,
  writes whose failure is never checked, results discarded silently.
- **Edge cases in scheduling / state transitions** — transitions
  missing a guard, terminal states that can be re-entered, a scheduler
  that double-fires or drops ticks, ordering assumptions that don't
  hold under concurrency.

For each: name the exact production path and the input/condition that
triggers the defect. Distinguish **fact** (the code as written) from
**interpretation** (the failure it produces). A silent data-loss or
feature-off-in-prod defect on a core path is Critical/High; a
secondary-path edge case is Medium.

---

## Axis C — `redundancy`

Find code and docs that are **dead, duplicated, or stale**, with
grounded evidence — not a single grep.

- **Dead code / unused exports.** When a
  `.scrum/reviews/static-analysis-r*.json` file was provided, **cite it
  as ground truth** for unused symbols and build on it — both its
  intra-file lint hits (`ruff F401/F841/ARG` / `shellcheck`) and its
  whole-repo reachability entries (`kind: unused_export`, produced by
  `vulture` or the project-declared
  `.scrum/config.json.static_analysis.commands[]` tools). When it is absent, you may
  still flag suspected-dead code, but you MUST give a reachability
  argument (no caller across the repo, not an entry point, not
  referenced by config/registration) and mark the finding **lower
  confidence**. Never assert "unused" from one grep with no
  reachability reasoning.
- **Cross-PBI duplicate implementations.** The same logic implemented
  more than once — typically because two PBIs from different Sprints
  each built it without seeing the other. These are High when the
  copies will drift out of sync (a bug fixed in one and not the other
  changes behavior). Anchor every copy's `file:line` and describe the
  shared behavior.
- **Stale comments / docstrings.** Comments or docstrings that no
  longer match the code they describe — a docstring claiming a
  parameter the signature dropped, a comment describing removed
  behavior. Medium when actively misleading, Low when merely noise.
  Enumerate these **exhaustively in one class finding** (the SM batches
  all documentation drift into a single per-audit PBI): a partial list
  guarantees the leftovers resurface at the next audit.

Duplicate-vs-drift caution: roughly a third of apparent "redundancy" is
actually a real bug (two copies that already diverged). When two copies
differ, that difference is a **logic-defect-class** finding, not mere
redundancy — raise the severity and say which copy is correct if you
can tell.

---

## Axis D — `product-security`

Audit the **product-wide security integrity** of the whole codebase —
the security defects that emerge only when you look across component and
PBI boundaries. The per-PBI pipeline already ran a **diff-local**
security aspect review on each PBI's own change; **do not re-review
single-PBI diff-local security** (an injection in one function a diff
review would have caught). Your yield is entirely in the seams:

- **Authorization boundaries spanning components/PBIs.** A route,
  handler, or entry point added in one PBI whose authorization / access
  check lives in — or was supposed to live in — another PBI's code. Look
  for endpoints with no reachable authz guard, roles checked in some
  paths but not sibling paths, and privilege boundaries that only hold
  if two independently-built components agree (and don't). Anchor the
  unprotected entry point AND where the check should be.
- **Data flows crossing trust boundaries.** Untrusted input (network,
  user, external service, file) that reaches a sink (DB, shell, eval,
  filesystem path, template, response) through a path that spans
  functions/modules built separately — so no single diff saw the whole
  flow. Name the source, the sink, and the unsanitized hops between.
- **Secrets / credential handling across the codebase.** Hardcoded
  secrets, tokens or keys logged / echoed / persisted in plaintext,
  credentials passed through insecure channels, secrets committed to
  config or fixtures. Grep-plus-reasoning across the whole tree, not one
  file.
- **Injection surfaces at integration points.** SQL / command / path /
  template / header injection where the tainting and the sink are in
  different modules, or where an integration boundary (an API call, a
  queue message, a stub seam) reintroduces untrusted data downstream of
  the PBI that validated it.
- **Missing security controls no single PBI owned.** A control the
  product needs as a whole — auth on an admin surface, rate limiting,
  CSRF/output encoding, TLS enforcement, resource limits — that no
  individual PBI was responsible for, so nobody built it. These are
  gaps *between* PBIs; flag them and name the requirement/spec anchor if
  one exists, else say it is an unowned gap.

Severity: an exploitable cross-component authz bypass, an unsanitized
untrusted-input-to-dangerous-sink flow, or a live exposed secret →
Critical; a missing product-wide control on a sensitive surface or a
plausible-but-unconfirmed injection seam → High; defense-in-depth gaps
on secondary paths → Medium. Keep **fact** (the code/flow as written)
separate from **interpretation** (the exploit it enables), and mark
confidence honestly when you cannot trace a full flow end-to-end.

Out of scope (explicit): single-PBI diff-local security issues, generic
best-practice nits with no reachable exploit, and third-party
dependency CVEs (a different tool's job) — unless the dependency is
wired in a way that itself creates a cross-component exposure.
