#!/bin/sh
set -eu

# Verify patch 0022 terminates the background process group and applies cleanly
# against pinned terminal.rs source.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0022="$REPO_ROOT/patches/0022-background-task-process-group-cleanup.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '\"' | tr -d "'" || true)"
[ -n "$PIN_SHA" ] || { echo "FAIL: PINNED_BASE_SHA missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0022 background task process group cleanup patch tests ==="
[ -s "$PATCH_0022" ] || { echo "FAIL: 0022 patch missing or empty" >&2; exit 1; }

# Python structural assertions
python3 - "$PATCH_0022" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
expected = {
    "crates/codegen/xai-grok-tools/src/computer/local/terminal.rs",
}
assert set(files) == expected, f"0022 must touch only terminal.rs: {files!r}"
assert len(files) == len(expected), "0022 must contain exactly one diff per expected file"

for needle in (
    "owned_group_has_members",
    "background_group_cleanup_after_wrapper_term",
    "background_group_cleanup_after_wrapper_exit",
    "has_live_members()",
):
    assert needle in patch, f"missing cleanup regression contract: {needle}"

print("PASS: 0022 touches exactly terminal.rs and satisfies structural contract")
PY

# Verify diff application against pinned terminal.rs using a narrow temporary tree
if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_TREE="$(mktemp -d -t grokgod-test-0022-tree-XXXXXX)"
  cleanup() {
    rm -rf "$TMP_TREE"
  }
  trap cleanup EXIT INT TERM

  # Create a narrow repo containing only the pinned terminal.rs source
  git -C "$TMP_TREE" init -q -b main
  git -C "$TMP_TREE" config user.name "CI"
  git -C "$TMP_TREE" config user.email "ci@example.com"
  mkdir -p "$TMP_TREE/crates/codegen/xai-grok-tools/src/computer/local"
  git -C "$REAL_GROK_BUILD" show "${PIN_SHA}:crates/codegen/xai-grok-tools/src/computer/local/terminal.rs" \
    > "$TMP_TREE/crates/codegen/xai-grok-tools/src/computer/local/terminal.rs"
  git -C "$TMP_TREE" add .
  git -C "$TMP_TREE" commit -qm "pinned terminal.rs"

  git -C "$TMP_TREE" apply --check "$PATCH_0022" || {
    echo "FAIL: 0022 does not apply cleanly to pinned terminal.rs at $PIN_SHA" >&2
    exit 1
  }
  git -C "$TMP_TREE" apply "$PATCH_0022"
  echo "PASS: 0022 applies cleanly to pinned terminal.rs at $PIN_SHA"

  # Optional behavioral test if opt-in and disk headroom permits
  if [ "${RUN_BEHAVIORAL_CARGO_TESTS:-0}" = "1" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      df -Pk /System/Volumes/Data | awk 'NR==2 {gsub(/%/, "", $5); if ($5 >= 90 || $4 < 15728640) exit 1}' || {
        echo "FAIL: disk headroom is below the build threshold" >&2
        exit 1
      }
    fi
    echo "Running process-group cleanup regression tests..."
    (cd "$REAL_GROK_BUILD" && CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 \
      CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2 cargo test --offline -p xai-grok-tools \
      --lib background_group_cleanup -- --nocapture)
  fi
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0022 tests passed ==="
