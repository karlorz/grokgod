#!/bin/sh
set -eu

# Verify patch 0021 ignores context_window downgrade on idle-resume and applies after 0001-0020.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0021="$REPO_ROOT/patches/0021-idle-resume-ignore-context-window-downgrade.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '\"' | tr -d "'" || true)"
[ -n "$PIN_SHA" ] || { echo "FAIL: PINNED_BASE_SHA missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0021 idle-resume ignore context_window downgrade patch tests ==="
[ -s "$PATCH_0021" ] || { echo "FAIL: 0021 patch missing or empty" >&2; exit 1; }

# Contract needles required by specification
for needle in \
  'Ignoring context_window downgrade from idle resume' \
  'test_e2e_idle_resume_ignores_context_window_downgrade' \
  '256_000' \
  '500_000' \
  'session_setup.rs' \
  'idle_resume_tests.rs'; do
  grep -Fq "$needle" "$PATCH_0021" || {
    echo "FAIL: missing 0021 contract needle: $needle" >&2
    exit 1
  }
done

python3 - "$PATCH_0021" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
expected = {
    "crates/codegen/xai-grok-shell/src/session/acp_session_impl/session_setup.rs",
    "crates/codegen/xai-grok-shell/src/session/acp_session_tests/idle_resume_tests.rs",
}
assert set(files) == expected, f"0021 must touch only session_setup.rs and idle_resume_tests.rs: {files!r}"
assert len(files) == len(expected), "0021 must contain exactly one diff per expected file"
print("PASS: 0021 touches exactly the expected files")
PY

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0021-wt-XXXXXX)"
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
    [ "$stripped" -le 20 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0021" || {
    echo "FAIL: 0021 does not apply after 0001-0020 at $PIN_SHA" >&2
    exit 1
  }
  git -C "$TMP_WT" apply "$PATCH_0021"
  echo "PASS: 0021 applies after 0001-0020 at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0021 tests passed ==="
