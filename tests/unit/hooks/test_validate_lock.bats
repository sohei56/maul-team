#!/usr/bin/env bats
# tests/unit/hooks/test_validate_lock.bats
#
# First direct tests of the directory-lock helpers in hooks/lib/validate.sh
# (_json_mtime_of / _json_lock_is_stale / _json_acquire_lock, and the
# json_update_atomic path that depends on them).
#
# Why a PATH-shimmed `stat`: the two stat dialects cannot both be exercised
# on one machine, and the failure mode being pinned only appears on the GNU
# side. GNU stat reads `-f` as --file-system and treats `%m` as a FILE NAME,
# so it prints a multi-line filesystem block on stdout AND exits non-zero —
# a naive `stat -f %m || stat -c %Y` chain concatenates that block with the
# epoch, and the caller's `$((now - mtime))` then resolves `File` as a
# variable, killing the whole hook process under `set -u`. Every helper call
# below therefore runs in a `bash -euo pipefail` subshell, the way hooks run.
#
# Staleness is driven by $STUB_MTIME (what the shimmed stat reports) rather
# than by aging real directories: JSON_LOCK_STALE_SEC is env-overridable
# (validate.sh), so the arithmetic is pinned exactly instead of approximately.

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  LIB="$PROJECT_ROOT/hooks/lib/validate.sh"
  export LIB
  TEST_TMP="$(mktemp -d /tmp/claude/validate-lock.XXXXXX 2>/dev/null \
    || mktemp -d "${TMPDIR:-/tmp}/validate-lock.XXXXXX")"
  cd "$TEST_TMP" || exit 1
  mkdir -p .scrum
  STUB_DIR="$TEST_TMP/stub"
  mkdir -p "$STUB_DIR"
  NOW="$(date +%s)"
  # Shell diagnostics are localized; the assertions below match on their
  # text, so pin the locale rather than the developer's environment.
  export LC_ALL=C
  # Keep the acquire loop short: 0.2s / 0.05s → ~5 polls before timeout.
  export JSON_LOCK_TIMEOUT_SEC=0.2
  export JSON_LOCK_POLL_SEC=0.05
  export JSON_LOCK_STALE_SEC=30
}

teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# ---------------------------------------------------------------------------
# stat shims
# ---------------------------------------------------------------------------

# use_stat_stub <gnu|bsd|broken>
use_stat_stub() {
  case "$1" in
    gnu)
      cat > "$STUB_DIR/stat" <<'STUB'
#!/usr/bin/env bash
# GNU-shaped stat. `-f` is --file-system, so `%m` is read as a file NAME:
# the bogus operand errors on stderr, the real operand prints a filesystem
# block on stdout, and the exit status is non-zero. `-c %Y` prints the epoch.
case "${1:-}" in
  -f)
    echo "stat: cannot read file system information for '%m': No such file or directory" >&2
    printf '  File: "%s"\n' "${3:-?}"
    printf '    ID: 802h/2050d Namelen: 255     Type: ext2/ext3\n'
    printf 'Block size: 4096       Fundamental block size: 4096\n'
    printf 'Blocks: Total: 61897344   Free: 47996151   Available: 44839303\n'
    exit 1
    ;;
  -c)
    printf '%s\n' "${STUB_MTIME:-0}"
    exit 0
    ;;
esac
exit 1
STUB
      ;;
    bsd)
      cat > "$STUB_DIR/stat" <<'STUB'
#!/usr/bin/env bash
# BSD-shaped stat (macOS): `-f <fmt>` prints the formatted value; `-c` is
# not a BSD flag and dies with a usage message.
case "${1:-}" in
  -f)
    printf '%s\n' "${STUB_MTIME:-0}"
    exit 0
    ;;
  -c)
    echo "stat: illegal option -- c" >&2
    exit 1
    ;;
esac
exit 1
STUB
      ;;
    broken)
      cat > "$STUB_DIR/stat" <<'STUB'
#!/usr/bin/env bash
# Neither dialect available (busybox-ish / stat absent): always fails, and
# prints nothing on stdout.
echo "stat: unsupported" >&2
exit 1
STUB
      ;;
    *)
      return 1
      ;;
  esac
  chmod +x "$STUB_DIR/stat"
}

# run_lib <snippet> — source validate.sh under the same shell options hooks
# use and evaluate <snippet>. The shimmed stat wins over the system one.
run_lib() {
  PATH="$STUB_DIR:$PATH" bash -euo pipefail -c ". \"\$LIB\"
$1"
}

# Print STALE / FRESH for a lock dir, never letting a non-zero return trip -e.
stale_probe() {
  run_lib "if _json_lock_is_stale \"$1\"; then echo STALE; else echo FRESH; fi"
}

acquire_probe() {
  run_lib "if _json_acquire_lock \"$1\"; then echo ACQUIRED; else echo TIMEOUT; fi"
}

# ---------------------------------------------------------------------------
# V1-V4: _json_lock_is_stale across stat dialects
# ---------------------------------------------------------------------------

@test "V1 GNU-shaped stat + old lock → stale, and the shell does NOT abort" {
  use_stat_stub gnu
  mkdir -p .scrum/a.lock.d
  export STUB_MTIME=$((NOW - 300))
  run stale_probe ".scrum/a.lock.d"
  # The regression this pins: the naive `stat -f %m || stat -c %Y` chain
  # concatenates the filesystem block with the epoch and $(( )) dies under -u.
  # "File:" is the first token of that block — matching it is locale-proof;
  # the "unbound variable" arm is the message bash 3.2+ actually prints.
  [[ "$output" != *"File:"* ]]
  [[ "$output" != *"unbound variable"* ]]
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "V2 GNU-shaped stat + fresh lock → not stale" {
  use_stat_stub gnu
  mkdir -p .scrum/b.lock.d
  export STUB_MTIME="$NOW"
  run stale_probe ".scrum/b.lock.d"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

@test "V3 BSD-shaped stat decides both ways (macOS path unchanged)" {
  use_stat_stub bsd
  mkdir -p .scrum/c.lock.d

  export STUB_MTIME=$((NOW - 300))
  run stale_probe ".scrum/c.lock.d"
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]

  export STUB_MTIME="$NOW"
  run stale_probe ".scrum/c.lock.d"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

@test "V4 both stat dialects fail → not stale (fail-safe)" {
  use_stat_stub broken
  mkdir -p .scrum/d.lock.d
  run stale_probe ".scrum/d.lock.d"
  [ "$status" -eq 0 ]
  # Unknown mtime must NOT be read as "infinitely old": breaking a live
  # lock corrupts the file, waiting out a dead one costs one timeout.
  [ "$output" = "FRESH" ]
}

# ---------------------------------------------------------------------------
# V5-V6: _json_mtime_of in isolation
# ---------------------------------------------------------------------------

@test "V5 _json_mtime_of returns a pure integer under either dialect" {
  mkdir -p .scrum/e.lock.d
  export STUB_MTIME=1750000000

  use_stat_stub bsd
  run run_lib '_json_mtime_of ".scrum/e.lock.d"'
  [ "$status" -eq 0 ]
  [ "$output" = "1750000000" ]

  use_stat_stub gnu
  run run_lib '_json_mtime_of ".scrum/e.lock.d"'
  [ "$status" -eq 0 ]
  # Not "…Available: 44839303\n1750000000" — the block must be rejected.
  [ "$output" = "1750000000" ]
}

@test "V6 _json_mtime_of emits 0 for a missing path and for unusable stat" {
  use_stat_stub gnu
  export STUB_MTIME=1750000000
  run run_lib '_json_mtime_of ".scrum/does-not-exist.lock.d"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  use_stat_stub broken
  mkdir -p .scrum/f.lock.d
  run run_lib '_json_mtime_of ".scrum/f.lock.d"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# V7-V8: _json_acquire_lock
# ---------------------------------------------------------------------------

@test "V7 GNU-shaped stat: a stale lock is broken and the lock acquired" {
  use_stat_stub gnu
  mkdir -p .scrum/g.lock.d
  export STUB_MTIME=$((NOW - 300))
  run acquire_probe ".scrum/g.lock.d"
  [[ "$output" != *"unbound variable"* ]]
  [ "$status" -eq 0 ]
  # Pre-fix this spun to TIMEOUT (or died); the lock must actually be broken.
  [ "$output" = "ACQUIRED" ]
  [ -d .scrum/g.lock.d ]
}

@test "V8 GNU-shaped stat: a fresh lock is not broken (acquire times out)" {
  use_stat_stub gnu
  mkdir -p .scrum/h.lock.d
  export STUB_MTIME="$NOW"
  run acquire_probe ".scrum/h.lock.d"
  [ "$status" -eq 0 ]
  [ "$output" = "TIMEOUT" ]
  [ -d .scrum/h.lock.d ]
}

# ---------------------------------------------------------------------------
# V9: end-to-end through json_update_atomic
# ---------------------------------------------------------------------------

@test "V9 json_update_atomic updates through a stale lock under GNU stat" {
  use_stat_stub gnu
  echo '{"n":1}' > .scrum/t.json
  mkdir -p .scrum/t.json.lock.d
  export STUB_MTIME=$((NOW - 300))

  run run_lib 'if json_update_atomic ".scrum/t.json" ".n = 2"; then echo OK; else echo FAIL; fi'
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]

  run jq -r '.n' .scrum/t.json
  [ "$output" = "2" ]
  [ ! -d .scrum/t.json.lock.d ]
  shopt -s nullglob
  set -- .scrum/t.json.tmp.*
  [ "$#" -eq 0 ]
}
