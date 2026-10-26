#!/bin/sh
set -eu

# test_0027_apply.sh: Verify 0027-ask-question-timeout-metadata.patch exists,
# carries the additive countdown wire contract, and applies cleanly against
# PINNED_BASE_SHA after 0001-0026 (0011 owns the timeout params; this patch
# only adds the optional wire field).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0027="$REPO_ROOT/patches/0027-ask-question-timeout-metadata.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0027 ask_user_question timeout metadata patch tests ==="
[ -s "$PATCH_0027" ] || { echo "FAIL: 0027 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0027" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)), "duplicate file diff"
assert len(files) == 5, f"unexpected changed-file count: {files!r}"
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in (
    "deadline_unix_ms",
    "deadlineUnixMs",
    "skip_serializing_if = \"Option::is_none\"",
    "pub fn timeout_metadata",
    "pub fn ask_user_question_timeout",
    "timeout: request.timeout",
    "ext_request_omits_timeout_when_absent",
    "ext_request_deserializes_without_timeout",
    "timeout_metadata_rejects_overflowing_deadline",
    "request_carries_resolved_countdown_metadata",
):
    assert needle in added, f"missing countdown contract: {needle}"
# Backward compatibility: the wire field must be optional on deserialize.
assert '#[serde(default, skip_serializing_if = "Option::is_none")]' in added, (
    "timeout must be an optional, omitted-when-absent wire field"
)
print("PASS: 0027 countdown wire contract and focused tests")
PY

if ! git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIP: real grok-build checkout unavailable"
  echo "=== Patch 0027 tests passed ==="
  exit 0
fi

TMP_WT="$(mktemp -d -t grokgod-test-0027-wt-XXXXXX)"
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
  [ "$predecessor" = "$PATCH_0027" ] && break
  git -C "$TMP_WT" apply --check "$predecessor"
  git -C "$TMP_WT" apply "$predecessor"
done
git -C "$TMP_WT" apply --check "$PATCH_0027"
git -C "$TMP_WT" apply "$PATCH_0027"
git -C "$TMP_WT" diff --check
echo "PASS: 0027 applies after full predecessor stack at $PIN_SHA"

# The countdown deadline derives from the same budget the native timer uses, so
# the wire field can never disagree with the authoritative timeout.
grep -q "params.timeout_metadata()" "$TMP_WT/crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs" || {
  echo "FAIL: tool request must carry params.timeout_metadata()" >&2
  exit 1
}
grep -q "fn timeout_metadata" "$TMP_WT/crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs" || {
  echo "FAIL: timeout_metadata resolver missing" >&2
  exit 1
}
echo "PASS: native timer and countdown share one params resolution"

echo "=== Patch 0027 tests passed ==="
