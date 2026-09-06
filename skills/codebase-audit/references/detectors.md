# codebase-audit — guard-first detectors

A **detector** is one shell command that mechanically proves a defect
**class** cannot recur. Once a class has one, the class leaves LLM audit
scope (`status: guarded`) and the machine owns it. This file is the
contract; the ledger fields and the nine ledger subcommands are in
`SKILL.md` and `docs/data-model.md`.

## Contract

- **One shell command**, run `bash -c` from the repo root with stdin
  closed. Read-only and idempotent — it must write no files.
- **Exit `0` = clean.** Exit `1..126` = violations, one per stdout line,
  ideally `path:line: message` so the merge log names the offending
  site.
- **Exit `127`, a signal, or a timeout = infrastructure failure**, never
  "clean". `run-detectors.sh` reports these as exit 2 and the merge gate
  fails the merge (fail-closed).
- **Bounded**: default 120 s, overridable per project via
  `.scrum/config.json.detectors.timeout_seconds`. Bash 3.2 has no
  portable `timeout(1)`, so the runner enforces the bound with a
  background job plus a `kill -0` poll.
- **Whole-repo scope.** A detector is not diff-scoped; it is the reason
  the class no longer needs an auditor.

Worked shape:

```bash
# violations on stdout, exit 1; silent exit 0 when clean
if grep -rn --exclude-dir=.git --exclude-dir=.scrum \
     -e 'send_notification(.*)\s*$' -- src/; then exit 1; fi
```

## Runner

```
.scrum/scripts/run-detectors.sh [--check <identity>] [--json]
```

Exit `0` clean / `1` violations / `2` could-not-execute / `64` usage.
No ledger or no guarded class → prints nothing, exits 0 (`--json` still
emits a document with an empty `detectors` array). It records results
nowhere: `merge-pbi.sh` turns a non-zero exit into
`merge_failure.kind=detector_regression`, and `skills/smoke-test`
Step 3.5 records one `detectors` category.

`--check <identity>` runs exactly one class's detector regardless of its
status. It is the machine "wired" probe used by `update-audit-ledger.sh
set-status guarded` and by a detector PBI's own acceptance criteria.

## Writing a detector PBI

When a class is machine-checkable, Step 5 files **two** PBIs, ratchet
first, both carrying the same `--audit-identity` (so `OPEN_MATCH`
correctly refuses a third):

1. **Detector PBI** — `[codebase-audit:<sprint>:F<n>:<Sev>] detector:
   <class>`, `--kind code`, then `link-pbi --role detector`. AC:

   > A command exists that exits non-zero on a synthetic violation of
   > `<identity>` and 0 at clean HEAD; it runs in under `<N>` s and
   > writes no files. `.scrum/scripts/update-audit-ledger.sh
   > register-detector --identity <identity> --command '<cmd>' --sprint
   > <sprint>` succeeds.
   > Not closed by this check: `<occurrence kinds the detector cannot see>`.

2. **Sweep PBI** — the normal class PBI, `link-pbi --role sweep`, whose
   AC additionally names the detector's zero report.

The last AC line is mandatory: a detector is almost always narrower than
its class, and leaving that unstated is how a narrow check silently
closes a wide class.

## Promotion to `guarded`

The **SM promotes at merge**, not the Developer at PBI done — see
`skills/pbi-merge/SKILL.md` § Steps step 4. A detector registered from a
worktree names a command that does not exist on `main`, so every other
PBI merging in between would hit exit 127 and be failed by the
fail-closed gate.

`set-status guarded` is the single choke point and refuses unless all of
these hold: a non-empty `detector.command`; the deployed `merge-pbi.sh`
greps as calling `run-detectors.sh` (a stale target deployment is
refused, naming `setup-user.sh`); and a live `--check` that actually
executed (exit 0 or 1, never 2). There is no other path to `guarded`.

## Un-guarding

A broken or wrong detector is un-guarded deliberately and auditably:

```bash
.scrum/scripts/update-audit-ledger.sh set-status \
  --identity <identity> --status open
```

That returns the class to LLM audit scope. It is a PO/SM decision, never
a way to unblock a merge queue — the fail-closed gate exists precisely
because a ratchet that silently passes while broken is worse than none.
