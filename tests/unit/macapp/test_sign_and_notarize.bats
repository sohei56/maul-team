#!/usr/bin/env bats
# Regression tests for the notary round trip in macapp/scripts/sign-and-notarize.sh.
#
# Guards the transient-network failure that broke a release run: notarytool had
# already logged "Successfully uploaded file" when the STATUS POLL died with
# NSURLErrorDomain Code=-1009 ("The Internet connection appears to be offline"),
# so a submission Apple had accepted failed the job. The script now submits
# without --wait and re-polls the submission id under a bounded backoff, while
# still failing immediately on a real Apple verdict.
#
# The tests source the script (SIGN_NOTARIZE_SOURCED=1) and drive only the
# notary functions against a fake `xcrun` on PATH — nothing is built, signed or
# sent anywhere. NOTARY_BACKOFF_BASE=0 keeps the sleeps instantaneous.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$PROJECT_ROOT/macapp/scripts/sign-and-notarize.sh"
  FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  CALLS="$FAKE_DIR/calls"
  SUBMISSION_ID="11111111-2222-3333-4444-555555555555"
  ARTIFACT="$BATS_TEST_TMPDIR/MaulTeam-9.9.9.dmg"
  mkdir -p "$FAKE_DIR" "$BATS_TEST_TMPDIR/bin"
  : > "$CALLS"
  : > "$ARTIFACT"

  # Fake `xcrun`: records every invocation, then replays scripted notarytool
  # responses. Counters live in files so they survive the command substitutions
  # the script runs each call in.
  cat > "$BATS_TEST_TMPDIR/bin/xcrun" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
[ "${1:-}" = "notarytool" ] || exit 0
sub="${2:-}"
arg="${3:-}"
# Human output unless the script actually passed --output-format.
case " $* " in
  *" --output-format "*) fmt=json ;;
  *) fmt=human ;;
esac
offline='Error: HTTPError(statusCode: nil, error: Error Domain=NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline." UserInfo={NSErrorFailingURLStringKey=https://appstoreconnect.apple.com/notary/v2/submissions})'
bump() {
  n=$(( $(cat "$FAKE_DIR/n_$1" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_DIR/n_$1"
  echo "$n"
}
case "$sub" in
  submit)
    n="$(bump submit)"
    if [ "$n" -le "${FAKE_SUBMIT_NET_FAILS:-0}" ]; then
      echo "Conducting pre-submission checks and initiating connection to the Apple notary service..."
      echo "$offline" >&2
      exit 1
    fi
    if [ "$fmt" = json ]; then
      printf '{"id":"%s","message":"Successfully uploaded file","path":"%s"}\n' \
        "$FAKE_SUBMISSION_ID" "$arg"
    else
      printf 'Submission ID received\n  id: %s\nSuccessfully uploaded file\n  path: %s\n' \
        "$FAKE_SUBMISSION_ID" "$arg"
    fi
    ;;
  wait)
    n="$(bump wait)"
    if [ "$n" -le "${FAKE_WAIT_NET_FAILS:-0}" ]; then
      echo "Waiting for processing to complete."
      echo "$offline" >&2
      exit 1
    fi
    if [ "$fmt" = json ]; then
      printf '{"id":"%s","status":"%s","message":"Processing complete"}\n' \
        "$arg" "${FAKE_WAIT_STATUS:-Accepted}"
    else
      printf 'Processing complete\n  id: %s\n  status: %s\n' \
        "$arg" "${FAKE_WAIT_STATUS:-Accepted}"
    fi
    # Deliberately exit 0 even for Invalid: notarytool has reported a rejected
    # submission with a zero status, so the script must judge the verdict text.
    exit 0
    ;;
  log)
    printf '{"issues":[{"message":"fake notary log"}]}\n'
    ;;
esac
exit 0
SHIM
  chmod +x "$BATS_TEST_TMPDIR/bin/xcrun"

  # Sources the script with its main block disabled, resolves credentials the
  # real way, then calls one notary function. `set --` first so the sourced
  # script does not read this driver's argv as its MODE.
  cat > "$BATS_TEST_TMPDIR/driver.sh" <<'DRIVER'
#!/bin/sh
fn="$1"
arg="${2:-}"
set --
export SIGN_NOTARIZE_SOURCED=1
. "$SIGN_NOTARIZE_SH"
resolve_notary_auth
if [ -n "$arg" ]; then "$fn" "$arg"; else "$fn"; fi
DRIVER

  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Drive a notary function through the driver script. Leading NAME=VALUE
# arguments are per-test environment; the first non-assignment argument starts
# the function name and its argument.
drive() {
  local envs=()
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  run env PATH="$PATH" \
    TMPDIR="$BATS_TEST_TMPDIR" \
    FAKE_DIR="$FAKE_DIR" \
    FAKE_SUBMISSION_ID="$SUBMISSION_ID" \
    SIGN_NOTARIZE_SH="$SCRIPT" \
    NOTARY_BACKOFF_BASE=0 \
    "${envs[@]}" \
    sh "$BATS_TEST_TMPDIR/driver.sh" "$@"
}

count_calls() {
  grep -c "^notarytool $1 " "$CALLS" || true
}

@test "notary: a dropped status poll is retried and the submission still passes" {
  drive NOTARY_PROFILE=scrum-notary FAKE_WAIT_NET_FAILS=1 notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  # One upload, two polls: the -1009 poll is re-driven against the same id.
  [ "$(count_calls submit)" -eq 1 ]
  [ "$(count_calls wait)" -eq 2 ]
  [[ "$output" == *"transient notarytool wait failure (attempt 1/5)"* ]]
  [[ "$output" == *"$SUBMISSION_ID"* ]]
  # Also the regression guard for the EXIT trap: a profile-mode run writes no
  # temp key, and the trap must not turn that into a non-zero exit.
}

@test "notary: an Invalid verdict fails fast and is never retried" {
  drive NOTARY_PROFILE=scrum-notary FAKE_WAIT_STATUS=Invalid notary_submit "$ARTIFACT"
  [ "$status" -ne 0 ]
  # Exactly one poll — Apple answered, so there is nothing to retry.
  [ "$(count_calls wait)" -eq 1 ]
  [[ "$output" != *"transient notarytool wait failure"* ]]
  [[ "$output" == *"final verdict"* ]]
  # The notary log is dumped so the rejection is diagnosable from the CI log.
  [ "$(count_calls log)" -eq 1 ]
}

@test "notary: an Accepted verdict is required, not merely a zero exit status" {
  drive NOTARY_PROFILE=scrum-notary FAKE_WAIT_STATUS=Rejected notary_submit "$ARTIFACT"
  # The fake exits 0; only the verdict text distinguishes this from success.
  [ "$status" -ne 0 ]
}

@test "notary: a dropped upload is retried until an id comes back" {
  drive NOTARY_PROFILE=scrum-notary FAKE_SUBMIT_NET_FAILS=2 notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(count_calls submit)" -eq 3 ]
  [ "$(count_calls wait)" -eq 1 ]
  [[ "$output" == *"transient notarytool submit failure (attempt 2/5)"* ]]
}

@test "notary: NOTARY_MAX_ATTEMPTS bounds the poll retries" {
  drive NOTARY_PROFILE=scrum-notary FAKE_WAIT_NET_FAILS=99 NOTARY_MAX_ATTEMPTS=3 \
    notary_submit "$ARTIFACT"
  [ "$status" -ne 0 ]
  [ "$(count_calls wait)" -eq 3 ]
  [[ "$output" == *"after 3 attempt(s)"* ]]
}

@test "notary: keychain-profile credentials reach every notarytool call" {
  drive NOTARY_PROFILE=scrum-notary FAKE_WAIT_NET_FAILS=1 notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  # submit + 2 waits, each carrying the profile and no key flags.
  [ "$(grep -c -- '--keychain-profile scrum-notary' "$CALLS")" -eq 3 ]
  ! grep -q -- '--key-id' "$CALLS"
}

@test "notary: key-id/issuer/p8 credentials reach every notarytool call" {
  key="$BATS_TEST_TMPDIR/AuthKey_TEST.p8"
  : > "$key"
  drive NOTARY_KEY_PATH="$key" NOTARY_KEY_ID=KEYID12345 \
    NOTARY_ISSUER_ID=1234abcd-issuer notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "--key $key --key-id KEYID12345 --issuer 1234abcd-issuer" "$CALLS")" -eq 2 ]
  ! grep -q -- '--keychain-profile' "$CALLS"
}

@test "notary: a base64 NOTARY_KEY_P8 is decoded, used, and cleaned up" {
  # The CI credential mode: the temp key file must exist during the run and be
  # removed by the EXIT trap without disturbing the exit status.
  #
  # resolve_notary_auth uses `mktemp -t`, and on macOS that lands in the Darwin
  # per-user temp dir REGARDLESS of $TMPDIR — so the test cannot redirect it and
  # has to skip where that directory is not writable (e.g. a sandboxed runner).
  mktemp -t maul-notary-probe >/dev/null 2>&1 \
    || skip "mktemp -t cannot write to this platform's temp dir"
  drive NOTARY_KEY_P8="$(printf 'fake-p8-bytes' | base64)" NOTARY_KEY_ID=KEYID12345 \
    NOTARY_ISSUER_ID=1234abcd-issuer notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  keyfile="$(sed -n 's/.*--key \([^ ]*\) --key-id.*/\1/p' "$CALLS" | head -1)"
  [ -n "$keyfile" ]
  [ ! -e "$keyfile" ]
}

@test "notary: the submission id is parsed from notarytool's human output too" {
  # NOTARY_OUTPUT_FORMAT= drops --output-format; the fake then prints the
  # `  id: <uuid>` form, which the parser must still handle.
  drive NOTARY_PROFILE=scrum-notary NOTARY_OUTPUT_FORMAT= notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  ! grep -q -- '--output-format' "$CALLS"
  [[ "$output" == *"notarytool wait ($SUBMISSION_ID)"* ]]
}

@test "notary: --output-format json is passed by default" {
  drive NOTARY_PROFILE=scrum-notary notary_submit "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--output-format json' "$CALLS")" -eq 2 ]
}
