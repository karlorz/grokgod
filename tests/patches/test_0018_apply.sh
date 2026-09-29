#!/bin/sh
set -eu

# Verify Gemini-compatible generated enum schema contracts, plus stacked apply.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0018="$REPO_ROOT/patches/0018-gemini-option-enum-null-schema.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SCRIPT" >&2
  exit 1
fi
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0018 Gemini enum schema patch tests ==="
[ -s "$PATCH_0018" ] || { echo "FAIL: 0018 patch missing or empty" >&2; exit 1; }

for needle in \
  'crates/codegen/xai-grok-tools/src/registry/types.rs' \
  'sanitize_enum_arrays(&mut value);' \
  'fn sanitize_enum_arrays(value: &mut serde_json::Value)' \
  'value.as_str().is_some_and(|value| !value.is_empty())' \
  'object.remove("enum");' \
  'enum cleanup must not change nullable type semantics' \
  'finalized_generated_schemas_advertise_string_only_enums' \
  'Some(&["pending", "in_progress", "completed", "cancelled"])' \
  'capability_mode must remain skipped' \
  'send_feedback' \
  'send_subagent_message' \
  'delivery must retain its nullable branch'; do
  grep -Fq "$needle" "$PATCH_0018" || {
    echo "FAIL: missing 0018 contract needle: $needle" >&2
    exit 1
  }
done

[ "$(grep -c '^diff --git ' "$PATCH_0018")" -eq 1 ] || {
  echo "FAIL: 0018 must modify exactly one upstream source file" >&2
  exit 1
}
if grep '^diff --git ' "$PATCH_0018" | grep -Fvq \
  'crates/codegen/xai-grok-tools/src/registry/types.rs'; then
  echo "FAIL: 0018 must stay in the generated schema path" >&2
  exit 1
fi
if grep '^[+]' "$PATCH_0018" | grep -Eq \
  'deserialize|parse_input|ToolInput|payload'; then
  echo "FAIL: 0018 must not rewrite tool-call payload handling" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0018-wt-XXXXXX)"
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
    [ "$stripped" -le 17 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0018" || {
    echo "FAIL: 0018 does not apply after 0001-0017 at $PIN_SHA" >&2
    exit 1
  }
  echo "PASS: 0018 applies after 0001-0017 at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0018 tests passed ==="
