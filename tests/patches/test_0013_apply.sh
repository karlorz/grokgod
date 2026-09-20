#!/bin/sh
set -eu

# Verify 0013 exists, contains the required warning contract, and applies after 0001-0012.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0013="$REPO_ROOT/patches/0013-same-session-compaction-warning.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
[ -n "$PIN_SHA" ] || { echo "FAIL: PINNED_BASE_SHA missing" >&2; exit 1; }
PIN_SHORT="$(printf '%s' "$PIN_SHA" | cut -c1-8)"
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0013 same-session compaction warning patch tests ==="
[ -s "$PATCH_0013" ] || { echo "FAIL: 0013 patch missing or empty" >&2; exit 1; }
for needle in \
  'compaction_round_warning_limit' \
  'GROK_COMPACTION_ROUND_WARNING_LIMIT' \
  'successful_compaction_count' \
  'compaction_round_count' \
  'Compacted {round_count} times in this session. Save SkillWiki progress soon.' \
  'Compacted {round_count} times in this session. Save SkillWiki progress and hand off to a new session.'; do
  grep -q "$needle" "$PATCH_0013" || { echo "FAIL: missing 0013 contract: $needle" >&2; exit 1; }
done
if grep '^+' "$PATCH_0013" | grep -Eiq '(/new|create|kill|close)[^[:alnum:]]+session|automatically[^[:alnum:]]+(create|kill|close)'; then
  echo "FAIL: 0013 must not automate session creation or termination" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0013-wt-XXXXXX)"
  CLEANUP="git -C "$REAL_GROK_BUILD" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || rm -rf "$TMP_WT""
  trap 'eval "$CLEANUP"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || { echo "FAIL: could not create verification worktree" >&2; exit 1; }
  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 12 ] || continue
    git -C "$TMP_WT" apply "$pred" || { echo "FAIL: predecessor patch failed: $base" >&2; exit 1; }
  done
  git -C "$TMP_WT" apply --check "$PATCH_0013" || { echo "FAIL: 0013 does not apply after 0001-0012" >&2; exit 1; }
  echo "PASS: 0013 applies after 0001-0012 on $PIN_SHORT"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0013 tests passed ==="
