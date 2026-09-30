#!/bin/sh
set -eu

# Verify patch 0020 is a tests-only API migration and applies after 0001-0019.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0020="$REPO_ROOT/patches/0020-switch-model-complete-test-model-choice.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '\"' | tr -d "'" || true)"
[ -n "$PIN_SHA" ] || { echo "FAIL: PINNED_BASE_SHA missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0020 SwitchModelComplete test-model-choice patch tests ==="
[ -s "$PATCH_0020" ] || { echo "FAIL: 0020 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0020" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
expected = {
    "crates/codegen/xai-grok-pager/src/app/dispatch/tests/billing.rs",
    "crates/codegen/xai-grok-pager/src/app/dispatch/tests/task_result.rs",
}
assert set(files) == expected, f"0020 must touch only test files: {files!r}"
assert len(files) == len(expected), "0020 must contain exactly one diff per test file"

for hunk in re.split(r"(?=^@@ )", patch, flags=re.MULTILINE):
    if "SwitchModelComplete" not in hunk:
        continue
    added = "\n".join(
        line for line in hunk.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )
    assert not re.search(r"^\+\s*(?:model_id|effort)\s*:", added, re.MULTILINE), (
        "0020 must not add removed model_id:/effort: fields inside SwitchModelComplete hunks"
    )

assert "choice: ModelChoice::new(" in patch, "0020 must migrate constructors to ModelChoice"
print("PASS: 0020 is limited to pager test files and adds no model_id:/effort: fields")
PY

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0020-wt-XXXXXX)"
  cleanup() {
    git -C "$REAL_GROK_BUILD" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHA" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHA" >&2
    exit 1
  }

  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in *[!0-9]*) continue ;; esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 19 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0020" || {
    echo "FAIL: 0020 does not apply after 0001-0019 at $PIN_SHA" >&2
    exit 1
  }
  git -C "$TMP_WT" apply "$PATCH_0020"
  echo "PASS: 0020 applies after 0001-0019 at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0020 tests passed ==="
