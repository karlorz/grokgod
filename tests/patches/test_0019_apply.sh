#!/bin/sh
set -eu

# Verify the plan-mode globset dependency contract, plus stacked apply.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0019="$REPO_ROOT/patches/0019-plan-mode-globset-dependency.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SCRIPT" >&2
  exit 1
fi
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0019 plan-mode globset dependency patch tests ==="
[ -s "$PATCH_0019" ] || { echo "FAIL: 0019 patch missing or empty" >&2; exit 1; }

for needle in \
  'crates/codegen/xai-grok-shell/Cargo.toml' \
  ' glob = { workspace = true }' \
  ' regex = { workspace = true }'; do
  grep -Fq "$needle" "$PATCH_0019" || {
    echo "FAIL: missing 0019 contract needle: $needle" >&2
    exit 1
  }
done

[ "$(grep -c '^diff --git ' "$PATCH_0019")" -eq 1 ] || {
  echo "FAIL: 0019 must modify exactly one upstream manifest" >&2
  exit 1
}
if grep '^diff --git ' "$PATCH_0019" | grep -Fvq \
  'crates/codegen/xai-grok-shell/Cargo.toml'; then
  echo "FAIL: 0019 must stay in the xai-grok-shell manifest" >&2
  exit 1
fi
[ "$(grep -c '^+globset = { workspace = true }$' "$PATCH_0019")" -eq 1 ] || {
  echo "FAIL: 0019 must add exactly one workspace globset dependency" >&2
  exit 1
}
[ "$(grep -c '^+' "$PATCH_0019")" -eq 2 ] || {
  echo "FAIL: 0019 must not add content beyond the manifest header and globset dependency" >&2
  exit 1
}

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0019-wt-XXXXXX)"
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
    [ "$stripped" -le 18 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0019" || {
    echo "FAIL: 0019 does not apply after 0001-0018 at $PIN_SHA" >&2
    exit 1
  }
  git -C "$TMP_WT" apply "$PATCH_0019"
  cargo metadata --no-deps --format-version 1 \
    --manifest-path "$TMP_WT/Cargo.toml" > "$TMP_WT/metadata.json"
  python3 - "$TMP_WT/metadata.json" << 'PY' || {
import json
import sys

metadata = json.load(open(sys.argv[1]))
shell = next(package for package in metadata["packages"] if package["name"] == "xai-grok-shell")
assert "globset" in {dependency["name"] for dependency in shell["dependencies"]}
PY
    echo "FAIL: cargo metadata did not resolve globset for xai-grok-shell" >&2
    exit 1
  }
  echo "PASS: 0019 applies after 0001-0018 and resolves globset at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0019 tests passed ==="
