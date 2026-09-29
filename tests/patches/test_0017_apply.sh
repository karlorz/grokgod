#!/bin/sh
set -eu

# Verify welcome logo chat-assistant accent patch contracts, plus stacked apply.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0017="$REPO_ROOT/patches/0017-welcome-logo-chat-accent.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SCRIPT" >&2
  exit 1
fi
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0017 welcome-logo-chat-accent patch tests ==="
[ -s "$PATCH_0017" ] || { echo "FAIL: 0017 patch missing or empty" >&2; exit 1; }

for needle in \
  'views/welcome/logo.rs' \
  'let base = theme.accent_assistant;' \
  'const SHINE: f32 = 1.0;'; do
  grep -q "$needle" "$PATCH_0017" || {
    echo "FAIL: missing 0017 contract needle: $needle" >&2
    exit 1
  }
done

if grep '^[+]' "$PATCH_0017" | grep -q 'const SHINE: f32 = 0.33'; then
  echo "FAIL: 0017 patch must not keep SHINE = 0.33 in added lines" >&2
  exit 1
fi

# Art files stay stock: no logo05.txt or logo07.txt additions/changes
if grep -q 'diff --git.*logo0[57]\.txt' "$PATCH_0017"; then
  echo "FAIL: 0017 must not modify logo art files" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0017-wt-XXXXXX)"
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
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 16 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0017" || {
    echo "FAIL: 0017 does not apply after 0001-0016 at $PIN_SHA" >&2
    exit 1
  }
  echo "PASS: 0017 applies after 0001-0016 at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0017 tests passed ==="
