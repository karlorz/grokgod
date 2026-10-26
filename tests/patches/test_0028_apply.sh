#!/bin/sh
set -eu

# test_0028_apply.sh: Verify 0028-ask-question-activity-ack.patch exists,
# carries the native reset acknowledgement contract, and applies cleanly
# against PINNED_BASE_SHA after 0001-0027. No cargo build is performed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0028="$REPO_ROOT/patches/0028-ask-question-activity-ack.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0028 ask_user_question activity acknowledgement patch tests ==="
[ -s "$PATCH_0028" ] || { echo "FAIL: 0028 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0028" <<'PYTEST'
import re, sys
from pathlib import Path
patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)) == 6, files
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in ('"x.ai/ask_user_question_activity"', 'UserQuestionActivity', 'reset_on_activity',
               'Duration::from_secs(2)', 'ack_rx', 'ack.send(timeout)',
               'sleep_fut.deadline()', 'activity_rx.close()',
               'timeout_accepts_legacy_metadata_without_reset_flag',
               'ack_rx.await.unwrap()', 'ack_rx.await.is_err()'):
    assert needle in added, needle
assert '"timeout": timeout' in added
print("PASS: 0028 native reset acknowledgement contract and focused tests")
PYTEST

if ! git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIP: real grok-build checkout unavailable"
  echo "=== Patch 0028 tests passed ==="
  exit 0
fi

TMP_WT="$(mktemp -d -t grokgod-test-0028-wt-XXXXXX)"
cleanup() {
  git -C "$REAL_GROK_BUILD" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHA" >/dev/null 2>&1 || {
  echo "FAIL: could not create detached worktree at $PIN_SHA" >&2
  exit 1
}
for predecessor in "$REPO_ROOT"/patches/*.patch; do
  [ -f "$predecessor" ] || continue
  [ "$predecessor" = "$PATCH_0028" ] && break
  git -C "$TMP_WT" apply --check "$predecessor"
  git -C "$TMP_WT" apply "$predecessor"
done
git -C "$TMP_WT" apply --check "$PATCH_0028"
git -C "$TMP_WT" apply "$PATCH_0028"
git -C "$TMP_WT" diff --check
echo "PASS: 0028 applies after full predecessor stack at $PIN_SHA"

echo "=== Patch 0028 tests passed ==="
