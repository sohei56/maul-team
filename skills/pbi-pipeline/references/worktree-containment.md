# Worktree Containment Verification

Conductor-side post-round check that no producer sub-agent
(pbi-designer, pbi-implementer, pbi-ut-author) leaked a write into
the MAIN repo checkout instead of the PBI worktree.

## Why this exists

Task-spawned sub-agents resolve bare relative paths against whatever
cwd the harness gives them — which can be the main checkout. The
leaked file then misses the PBI branch, dirties main, and blocks the
per-PBI merge. Target-project retrospectives logged this leak across
**11 Sprints**; prompt-level rules alone did not converge it (a
single bare path token still leaks), so the conductor verifies
deterministically after every producer round. The two defenses are
complementary: the `{worktree_path}` prompt rule prevents most leaks,
this check catches the rest before the commit.

## Procedure

Snapshot the main checkout's status BEFORE spawning producers and
compare AFTER they return — pre-existing drift in main (another PBI's
leak, operator edits) must not be misattributed to this Round.

```bash
# Main repo root, derived from the worktree (git-common-dir points at
# the main checkout's .git).
MAIN_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
snapshot_main() { git -C "$MAIN_ROOT" status --porcelain -uall | sort; }

# 1. Immediately before the producer spawn(s) of this Round:
MAIN_SNAP_BEFORE="$(snapshot_main)"

# 2. Spawn producers, wait for return (see design-stage.md /
#    impl-ut-stage.md).

# 3. Immediately after they return, before commit-pbi.sh:
LEAKED="$(comm -13 <(printf '%s\n' "$MAIN_SNAP_BEFORE") <(snapshot_main))"
```

`.scrum/**` never appears here (gitignored in main), so shared-SSOT
artifact writes cannot false-positive.

## On a non-empty `LEAKED`

1. **Log it** (facts, not narration):
   ```bash
   .scrum/scripts/append-pbi-log.sh "$PBI_ID" "$STAGE" "$n" warn \
     "worktree_leak: <comma-separated paths>"
   ```
2. **Relocate each leaked path into the worktree** (worktree root =
   the conductor's cwd, `$WT` below):
   - `?? <path>` (untracked in main): if `$WT/<path>` does not exist,
     `mkdir -p` its directory and `mv "$MAIN_ROOT/<path>" "$WT/<path>"`.
     If `$WT/<path>` already exists, diff the two, merge the leaked
     content into the worktree copy manually, then delete the main
     copy.
   - ` M <path>` (tracked file modified in main): copy the modified
     content into `$WT/<path>` (merge manually if the worktree copy
     also changed), then restore main:
     `git -C "$MAIN_ROOT" checkout -- "<path>"`.
3. **Re-verify**: recompute the comparison; it MUST now be empty.
4. Proceed with the normal Round flow (`commit-pbi.sh` etc.). The
   relocated files are committed with the Round like any other
   artifact.

If the same producer leaks again in the following Round, treat it as
a recurring defect, not noise: name it in the next round's feedback
file so the producer prompt gap (a path source you pasted relative,
e.g. `catalog_targets`) gets fixed, and report it to the SM in the
Round summary.

## Scope

- Runs after **producer** spawns only (design Round Step 1, impl/UT
  Round Step 1). Reviewer spawns are read-only by contract and pin
  their reads to `{worktree_path}`; they are not snapshot-checked.
- This is a detection net, not a sandbox: it catches honest path
  mistakes, which is the observed failure mode.
