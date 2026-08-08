#!/usr/bin/env bash
# scripts/scrum/draft-framework-issue.sh — draft a sanitized, postable GitHub
# issue body for a framework-attributable finding raised in a Retrospective.
#
# Usage:
#   draft-framework-issue.sh \
#     --sprint <sprint-id> --identity <class>::<pattern> \
#     --title <text> --where <text> --why <text> --improvement <text> \
#     [--summary <text>] [--frequency <text>]
#
#   draft-framework-issue.sh --record-posted <draft-path> --url <issue-url>
#
# Writes two files per draft:
#   .scrum/framework-issues/<sprint-id>-NN.md    the postable body, ONLY that
#   .scrum/framework-issues/<sprint-id>-NN.meta  key=value, local bookkeeping
#
# The split is the whole point. `gh issue create --body-file <draft>` publishes
# that file verbatim, so a `sprint:` header inside it would publish the target
# project's Sprint ID — the exact leak this wrapper exists to prevent. An HTML
# comment does not help; it is still in the public issue source. Everything the
# operator needs locally (which Sprint, which framework rev, whether it was
# posted) therefore lives in the `.meta` sidecar and is unpublishable by
# construction rather than by discipline. The sidecar is key=value rather than
# JSON, so it carries no schema, needs no migration, and is not matched by
# pre-tool-use-scrum-state-guard.sh.
#
# stdout: the draft path, one line (nothing else).
# stderr: a ready-to-run `gh issue create` command, so framework-origin
#         resolution lives in shell rather than in skill prose.
#
# Cross-Sprint dedup reuses the codebase-audit `<class>::<pattern>` identity
# grammar (assert_audit_identity). A second call with an identity that already
# has a draft does NOT write a second file: it bumps the occurrence count and
# rewrites the body's frequency line, because observed frequency is the
# evidence a maintainer needs and draft spam is not. The text flags on such a
# call are still sanitized but are not re-rendered — the first draft's wording
# stands.
#
# NON-GOAL. The four sanitizer checks below reject target identifiers,
# home-anchored paths, tokens derived from this project's own name, and
# operator-declared domain terms. They cannot detect a private business rule
# paraphrased in plain English, or a retrospective quote reworded. This is a
# guardrail against honest mistakes, not a sandbox against a determined leak —
# the human review gate in `skills/retrospective/SKILL.md` Step 4b is what
# actually authorizes publication, which is why that step renders the full body
# in chat rather than just a path. There is deliberately no --force.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/errors.sh
source "$HERE/lib/errors.sh"
# shellcheck source=lib/atomic.sh
source "$HERE/lib/atomic.sh"

DRAFT_DIR=".scrum/framework-issues"
# Where a draft is posted when nothing better is known. A target project cannot
# discover the framework's repo by itself (a bundled macapp deploy has no .git
# and its own git remote points at the TARGET), so the only trustworthy source
# is the deploy stamp setup-user.sh writes; this constant is the floor.
DEFAULT_ORIGIN="sohei56/maul-team"
# Tokens too generic to be evidence of anything, plus the framework's own
# names — a draft that discusses the framework must be free to name it.
GENERIC_TOKENS="src app main test tests work repo project code data"
FRAMEWORK_TOKENS="maul-team claude-scrum-team"

SPRINT=""
IDENTITY=""
TITLE=""
SUMMARY=""
WHERE=""
WHY=""
IMPROVEMENT=""
FREQUENCY=""
RECORD_POSTED=""
URL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sprint)         SPRINT="$2"; shift 2 ;;
    --identity)       IDENTITY="$2"; shift 2 ;;
    --title)          TITLE="$2"; shift 2 ;;
    --summary)        SUMMARY="$2"; shift 2 ;;
    --where)          WHERE="$2"; shift 2 ;;
    --why)            WHY="$2"; shift 2 ;;
    --improvement)    IMPROVEMENT="$2"; shift 2 ;;
    --frequency)      FREQUENCY="$2"; shift 2 ;;
    --record-posted)  RECORD_POSTED="$2"; shift 2 ;;
    --url)            URL="$2"; shift 2 ;;
    *) fail E_INVALID_ARG "unknown flag: $1" ;;
  esac
done

# --- Shared helpers -------------------------------------------------------

# _meta_get <meta-path> <key> — echo the value of one key=value line.
_meta_get() {
  sed -n "s/^$2=//p" "$1" | head -n1
}

# _shq <text> — single-quote <text> for pasting into a shell command line.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _normalize_origin <git-url> — reduce any remote URL form to `owner/repo`.
# Handles git@host:o/r.git, https://host/o/r.git, ssh://git@host/o/r. Echoes
# nothing when the input has fewer than two path segments.
_normalize_origin() {
  printf '%s' "$1" \
    | sed -e 's/\.git$//' -e 's#^[A-Za-z+]*://##' -e 's/^[^@/]*@//' \
    | awk -F'[:/]' 'NF >= 2 { printf "%s/%s", $(NF - 1), $NF }' \
    | tr '[:upper:]' '[:lower:]'
}

# _resolve_origin — echo the framework repo as `owner/repo`. The deploy stamp
# is the only target-side source that can be right; local git remotes describe
# the TARGET, never the framework.
_resolve_origin() {
  local origin=""
  if [ -f ".scrum/deploy-stamp.json" ]; then
    origin="$(jq -r '.framework_origin // ""' .scrum/deploy-stamp.json 2>/dev/null || true)"
  fi
  case "$origin" in
    ""|null) printf '%s' "$DEFAULT_ORIGIN" ;;
    *)       printf '%s' "$origin" ;;
  esac
}

# --- --record-posted mode -------------------------------------------------

if [ -n "$RECORD_POSTED" ]; then
  [ -n "$URL" ] || fail E_INVALID_ARG "--record-posted requires --url"
  META_PATH="${RECORD_POSTED%.md}.meta"
  [ -f "$RECORD_POSTED" ] || fail E_FILE_MISSING "no such draft: $RECORD_POSTED"
  [ -f "$META_PATH" ] || fail E_FILE_MISSING "draft has no sidecar: $META_PATH"
  printf '%s' "$URL" | grep -Eq '^https://[A-Za-z0-9.-]+/[^[:space:]]+$' \
    || fail E_INVALID_ARG "bad --url: $URL (expected an https:// issue URL)"

  POSTED_TMP="$META_PATH.tmp.$$"
  {
    printf 'identity=%s\n'           "$(_meta_get "$META_PATH" identity)"
    printf 'sprint_id=%s\n'          "$(_meta_get "$META_PATH" sprint_id)"
    printf 'framework_sha=%s\n'      "$(_meta_get "$META_PATH" framework_sha)"
    printf 'drafted_at=%s\n'         "$(_meta_get "$META_PATH" drafted_at)"
    printf 'occurrences=%s\n'        "$(_meta_get "$META_PATH" occurrences)"
    printf 'occurrence_sprints=%s\n' "$(_meta_get "$META_PATH" occurrence_sprints)"
    printf 'status=posted\n'
    printf 'posted_url=%s\n'         "$URL"
  } > "$POSTED_TMP"
  mv "$POSTED_TMP" "$META_PATH"
  printf '%s\n' "$RECORD_POSTED"
  exit 0
fi

# --- Drafting mode: argument validation -----------------------------------

[ -n "$SPRINT" ]      || fail E_INVALID_ARG "--sprint required"
[ -n "$IDENTITY" ]    || fail E_INVALID_ARG "--identity required"
[ -n "$TITLE" ]       || fail E_INVALID_ARG "--title required"
[ -n "$WHERE" ]       || fail E_INVALID_ARG "--where required"
[ -n "$WHY" ]         || fail E_INVALID_ARG "--why required"
[ -n "$IMPROVEMENT" ] || fail E_INVALID_ARG "--improvement required"
if [ -n "$URL" ]; then
  fail E_INVALID_ARG "--url is only valid with --record-posted"
fi

assert_sprint_id "$SPRINT" --sprint
assert_audit_identity "$IDENTITY" --identity

ORIGIN="$(_resolve_origin)"

# --- Self-hosting guard ---------------------------------------------------
# Filing a framework issue FROM the framework is a category error: the finding
# belongs in this repo's own backlog, where it can be scheduled. Fail loudly
# rather than exit 0 doing nothing, so the mistake is visible in the ceremony.
LOCAL_ORIGIN="$(_normalize_origin "$(git remote get-url origin 2>/dev/null || true)")"
if [ -n "$LOCAL_ORIGIN" ] && [ "$LOCAL_ORIGIN" = "$ORIGIN" ]; then
  fail E_INVALID_ARG \
    "this project is the framework itself ($ORIGIN) — file it as a normal backlog item, not an upstream issue"
fi
if [ -f ".scrum/deploy-stamp.json" ]; then
  STAMP_ROOT="$(jq -r '.framework_root // ""' .scrum/deploy-stamp.json 2>/dev/null || true)"
  if [ -n "$STAMP_ROOT" ] && [ "$STAMP_ROOT" != "null" ] && [ -d "$STAMP_ROOT" ] \
     && [ "$(cd "$STAMP_ROOT" && pwd -P)" = "$(pwd -P)" ]; then
    fail E_INVALID_ARG \
      "this project is the framework itself (deploy-stamp framework_root == \$PWD) — file it as a normal backlog item, not an upstream issue"
  fi
fi

# --- Token derivation -----------------------------------------------------
# Everything that names THIS project: the working directory, and the owner /
# repo segments of every git remote. Host names (anything with a dot) are
# dropped so `github.com` never becomes a forbidden word. Case-folded once
# here so every comparison below is a plain substring test.
PROJECT_TOKENS="$(
  {
    basename "$PWD"
    git remote -v 2>/dev/null \
      | awk '{print $2}' \
      | sed -e 's/\.git$//' -e 's#^[A-Za-z+]*://##' -e 's/^[^@/]*@//' \
      | tr ':' '/' | tr '/' '\n' \
      | grep -v '\.' || true
  } \
    | tr '[:upper:]' '[:lower:]' \
    | awk 'length($0) >= 4' \
    | sort -u
)"
# Drop the generic words and the framework's own names.
for _skip in $GENERIC_TOKENS $FRAMEWORK_TOKENS; do
  PROJECT_TOKENS="$(printf '%s\n' "$PROJECT_TOKENS" | grep -Fxv -- "$_skip" || true)"
done

# Operator-declared domain terms. The only mechanical defense against the leak
# class nothing else catches — a business noun that is meaningless outside this
# project. No length floor: the operator declared it deliberately.
FORBIDDEN_TOKENS=""
if [ -f ".scrum/config.json" ]; then
  FORBIDDEN_TOKENS="$(
    jq -r '.framework_issue.forbidden_tokens // [] | .[]' .scrum/config.json 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' || true
  )"
fi

# --- Sanitization ---------------------------------------------------------
# Every violation is collected and reported in one pass. Fail-fast would cost
# an autonomous run one round trip per leak, and a stalled ceremony is worse
# than a long error message.
VIOLATIONS=""

_scan_field() {
  local label="$1" value="$2" hit tok folded
  [ -n "$value" ] || return 0
  folded="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  # (1) Target identifiers. The framework's own placeholders are the
  # letter forms (pbi-NNN, sprint-NNN) and survive by construction: a
  # concrete number after the dash can only have come from a real project.
  hit="$(printf '%s' "$value" \
    | grep -Eio '(^|[^a-z0-9])(pbi|sprint|imp|dec|us)-[0-9]+' \
    | head -n1 | sed 's/^[^A-Za-z]*//' || true)"
  if [ -n "$hit" ]; then
    VIOLATIONS="${VIOLATIONS}  ${label}: target identifier \`${hit}\`
"
  fi

  # (2) Home-anchored absolute paths — the operator's username and the
  # project path leak together.
  hit="$(printf '%s' "$value" \
    | grep -Eio '(/users/|/home/)[^/[:space:]]+' | head -n1 || true)"
  if [ -n "$hit" ]; then
    VIOLATIONS="${VIOLATIONS}  ${label}: home-anchored path \`${hit}\`
"
  fi

  # (3) Tokens derived from this project's own name.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if printf '%s' "$folded" | grep -Fq -- "$tok"; then
      VIOLATIONS="${VIOLATIONS}  ${label}: project-derived token \`${tok}\`
"
    fi
  done <<EOF
$PROJECT_TOKENS
EOF

  # (4) Operator-declared domain terms.
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if printf '%s' "$folded" | grep -Fq -- "$tok"; then
      VIOLATIONS="${VIOLATIONS}  ${label}: operator-declared domain term \`${tok}\`
"
    fi
  done <<EOF
$FORBIDDEN_TOKENS
EOF
}

_scan_field --identity "$IDENTITY"
_scan_field --title "$TITLE"
_scan_field --summary "$SUMMARY"
_scan_field --where "$WHERE"
_scan_field --why "$WHY"
_scan_field --improvement "$IMPROVEMENT"
_scan_field --frequency "$FREQUENCY"

if [ -n "$VIOLATIONS" ]; then
  fail E_INVALID_ARG "draft would publish target-project data:
${VIOLATIONS}Keep the count, drop the identifier: write \"recurred across 3 Sprints\", not the Sprint ID. Describe the framework's behavior, never this project's use of it."
fi

# --- Create or bump -------------------------------------------------------

mkdir -p "$DRAFT_DIR"

FRAMEWORK_SHA=unknown
if [ -f ".scrum/deploy-stamp.json" ]; then
  FRAMEWORK_SHA="$(jq -r '.framework_sha // "unknown"' .scrum/deploy-stamp.json 2>/dev/null || echo unknown)"
  [ -n "$FRAMEWORK_SHA" ] || FRAMEWORK_SHA=unknown
fi

EXISTING_META=""
for _m in "$DRAFT_DIR"/*.meta; do
  [ -e "$_m" ] || continue
  if [ "$(_meta_get "$_m" identity)" = "$IDENTITY" ]; then
    EXISTING_META="$_m"
    break
  fi
done

if [ -n "$EXISTING_META" ]; then
  DRAFT_PATH="${EXISTING_META%.meta}.md"
  OCCURRENCES="$(( $(_meta_get "$EXISTING_META" occurrences) + 1 ))"
  OCC_SPRINTS="$(_meta_get "$EXISTING_META" occurrence_sprints)"
  case ",$OCC_SPRINTS," in
    *",$SPRINT,"*) ;;
    *) OCC_SPRINTS="${OCC_SPRINTS:+$OCC_SPRINTS,}$SPRINT" ;;
  esac

  BUMP_TMP="$EXISTING_META.tmp.$$"
  {
    printf 'identity=%s\n'           "$IDENTITY"
    printf 'sprint_id=%s\n'          "$(_meta_get "$EXISTING_META" sprint_id)"
    printf 'framework_sha=%s\n'      "$(_meta_get "$EXISTING_META" framework_sha)"
    printf 'drafted_at=%s\n'         "$(_meta_get "$EXISTING_META" drafted_at)"
    printf 'occurrences=%s\n'        "$OCCURRENCES"
    printf 'occurrence_sprints=%s\n' "$OCC_SPRINTS"
    printf 'status=%s\n'             "$(_meta_get "$EXISTING_META" status)"
    printf 'posted_url=%s\n'         "$(_meta_get "$EXISTING_META" posted_url)"
  } > "$BUMP_TMP"
  mv "$BUMP_TMP" "$EXISTING_META"

  # Rewrite only the machine-managed count line; any operator prose from
  # --frequency on the first draft is left untouched.
  BODY_TMP="$DRAFT_PATH.tmp.$$"
  awk -v n="$OCCURRENCES" \
    '/^Observed [0-9]+ time\(s\) in one target project\.$/ {
       printf "Observed %s time(s) in one target project.\n", n; next
     } { print }' "$DRAFT_PATH" > "$BODY_TMP"
  mv "$BODY_TMP" "$DRAFT_PATH"
else
  # NN = zero-padded count of this Sprint's existing drafts + 1.
  SEQ=1
  for _f in "$DRAFT_DIR/$SPRINT"-*.md; do
    [ -e "$_f" ] || continue
    SEQ=$((SEQ + 1))
  done
  DRAFT_PATH="$(printf '%s/%s-%02d.md' "$DRAFT_DIR" "$SPRINT" "$SEQ")"
  META_PATH="${DRAFT_PATH%.md}.meta"
  OCCURRENCES=1

  {
    printf '# %s\n' "$TITLE"
    if [ -n "$SUMMARY" ]; then
      printf '\n## Summary\n\n%s\n' "$SUMMARY"
    fi
    printf '\n## Where in the framework\n\n%s\n' "$WHERE"
    printf '\n## Why it is a problem\n\n%s\n' "$WHY"
    printf '\n## Proposed improvement\n\n%s\n' "$IMPROVEMENT"
    printf '\n## Observed frequency\n\n'
    printf 'Observed %s time(s) in one target project.\n' "$OCCURRENCES"
    if [ -n "$FREQUENCY" ]; then
      printf '%s\n' "$FREQUENCY"
    fi
    printf '\n---\n\n'
    # shellcheck disable=SC2016  # the backticks are Markdown code spans, not a subshell
    printf 'Observed on framework rev `%s`. Filed from a Maul Team\n' "$FRAMEWORK_SHA"
    printf 'retrospective; target-project details are intentionally omitted.\n'
  } > "$DRAFT_PATH"

  {
    printf 'identity=%s\n'           "$IDENTITY"
    printf 'sprint_id=%s\n'          "$SPRINT"
    printf 'framework_sha=%s\n'      "$FRAMEWORK_SHA"
    printf 'drafted_at=%s\n'         "$(_iso_utc_now)"
    printf 'occurrences=%s\n'        "$OCCURRENCES"
    printf 'occurrence_sprints=%s\n' "$SPRINT"
    printf 'status=draft\n'
    printf 'posted_url=\n'
  } > "$META_PATH"
fi

# --- Agent-mode attention queue ------------------------------------------
# Publishing to a public repo is human-only in both modes, so agent mode never
# posts and never asks the PO. Queueing it here (rather than in the skill) is
# what lets the ceremony step stay mode-agnostic; the entry is untagged, so it
# never blocks release_decision=go. Deduped by the draft path, so an occurrence
# bump does not re-queue. Mirrors merge-pbi.sh's unconfigured-gate notice.
PO_MODE="$(jq -r '.po_mode // "human"' .scrum/config.json 2>/dev/null || echo human)"
if [ "$PO_MODE" = "agent" ]; then
  ATTN_FILE=".scrum/po/attention.md"
  if ! grep -qF "$DRAFT_PATH" "$ATTN_FILE" 2>/dev/null; then
    mkdir -p .scrum/po
    printf -- '- [%s] framework issue draft awaiting human review: %s — review the body, then post it yourself with: gh issue create --repo %s --title %s --body-file %s\n' \
      "$(_iso_utc_now)" "$DRAFT_PATH" "$ORIGIN" "$(_shq "$TITLE")" "$DRAFT_PATH" \
      >> "$ATTN_FILE"
  fi
fi

# stderr carries the command; stdout stays a single machine-readable path.
DRAFT_TITLE="$(sed -n '1s/^# //p' "$DRAFT_PATH")"
printf '[draft-framework-issue] read the body in full, obtain permission, then post with:\n  gh issue create --repo %s --title %s --body-file %s\n' \
  "$ORIGIN" "$(_shq "$DRAFT_TITLE")" "$DRAFT_PATH" >&2

printf '%s\n' "$DRAFT_PATH"
