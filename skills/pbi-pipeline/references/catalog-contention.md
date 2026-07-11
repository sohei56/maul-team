# Catalog Contention Reference

How parallel PBI pipelines coordinate writes to shared catalog specs
under `docs/design/specs/`. 3-layer defense.

## Layer 1: Sprint planning pre-separation (primary defense)

SM records `catalog_targets[]` per PBI in `backlog.json` during sprint
planning. PBIs with overlapping `catalog_targets` MUST NOT be assigned
to different developers in parallel. SM either:

- Assigns overlapping PBIs to the same Developer (sequential), or
- Splits the PBI to remove overlap.

This is enforced in `skills/sprint-planning/SKILL.md`. Verify in your
own pipeline run via:

```bash
my_pbi_targets="$(jq -r --arg id "$PBI_ID" '.items[] | select(.id == $id) | .catalog_targets[]?' .scrum/backlog.json)"
```

## Layer 2: Runtime exclusion via mkdir lock (backstop)

Before writing to a catalog spec, acquire a per-spec directory lock.
The pbi-designer agent does this; the conductor enforces by inspecting
designer's reported actions.

`mkdir` is atomic on POSIX filesystems and needs no `flock` — this
mirrors the framework's portable lock idiom (`scripts/scrum/lib/atomic.sh`
`_acquire_lock`, and merge-pbi's `merge.lock.d`). All locks share the
single root `.scrum/locks/`; name families cannot collide (wrapper
locks end `.json.lock.d`, the merge lock is `merge.lock.d`, catalog
locks are `catalog-*.lock.d`). `flock` and the Bash-4.1 `exec {FD}>`
redirect are unavailable on stock macOS, so this protocol uses `mkdir`
and runs on Bash 3.2:

```bash
_catalog_lock_dir() {
  local spec_path="$1" lock_id
  lock_id="$(echo "$spec_path" | sed 's|/|_|g')"
  printf '%s\n' ".scrum/locks/catalog-${lock_id}.lock.d"
}
acquire_catalog_lock() {
  local lock_dir; lock_dir="$(_catalog_lock_dir "$1")"
  mkdir -p .scrum/locks
  local deadline=$(( $(date +%s) + 60 ))   # 60s timeout
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 124  # timeout
    fi
    sleep 0.2
  done
  return 0
}
release_catalog_lock() {
  rmdir "$(_catalog_lock_dir "$1")" 2>/dev/null || true
}
```

Timeout (60s) → escalate with `escalation_reason: catalog_lock_timeout`.
Unlike `flock`, a `mkdir` lock does NOT auto-release on process death —
a Developer that dies mid-write leaves the `.lock.d` directory behind
(a stale lock). See § Stale lock cleanup.

## Layer 3: Conflict detection via mtime (last resort)

After releasing the lock, verify nothing else wrote in between:

```bash
verify_no_conflict() {
  local spec_path="$1" mtime_before="$2"
  local mtime_now
  mtime_now="$(stat -f %m "$spec_path" 2>/dev/null || stat -c %Y "$spec_path")"
  [ "$mtime_now" = "$mtime_before" ]
}
```

If conflict detected: discard the change, log event, retry once. On
second conflict: escalate `catalog_lock_timeout`.

## Stale lock cleanup

A `mkdir` lock does NOT auto-release on process exit (unlike `flock`).
If a Developer dies mid-write, its
`.scrum/locks/catalog-<spec_id>.lock.d` directory survives and blocks
the next writer until the 60s timeout, which escalates as
`catalog_lock_timeout`. On that escalation the SM force-releases by
`rmdir`-ing the stale lock dir (see
`skills/pbi-escalation-handler/SKILL.md` § Response Matrix
`catalog_lock_timeout` row) and retries. The SM may also sweep
`.scrum/locks/` for orphaned `catalog-*.lock.d` directories
periodically (scope the sweep to the `catalog-` prefix — the state
wrappers' `*.json.lock.d` and merge-pbi's `merge.lock.d` share this
root and are held only for the duration of a live write).
