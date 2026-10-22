#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0025="$REPO_ROOT/patches/0025-mcp-elicitation-persist.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0025 MCP elicitation persist patch tests ==="
[ -s "$PATCH_0025" ] || { echo "FAIL: 0025 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0025" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)), "duplicate file diff"
assert len(files) == 10, f"unexpected changed-file count: {files!r}"
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in (
    "McpElicitPersistScope",
    "normalize_persist_offer",
    "parse_mcp_elicit_ext_response",
    "elicit_result_from_wire_offered",
    "accept_result_with_persist",
    '["session", "always"]',
    "form_persist_offer_from_sky_meta",
    "persist_selection_must_be_offered",
    "persist is not allowed on decline/cancel",
):
    assert needle in added, f"missing persist contract: {needle}"
print("PASS: 0025 persist offer/accept/MCP meta contracts")
PY

if ! git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1 &&
   git -C /tmp/grok-build-2bdd1d6a rev-parse --git-dir >/dev/null 2>&1; then
  REAL_GROK_BUILD=/tmp/grok-build-2bdd1d6a
fi

if git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  TMP_WT="$(mktemp -d -t grokgod-test-0025-wt-XXXXXX)"
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
    [ "$predecessor" = "$PATCH_0025" ] && break
    git -C "$TMP_WT" apply --check "$predecessor"
    git -C "$TMP_WT" apply "$predecessor"
  done
  git -C "$TMP_WT" apply --check "$PATCH_0025"
  git -C "$TMP_WT" apply "$PATCH_0025"
  git -C "$TMP_WT" diff --check
  echo "PASS: 0025 applies after full predecessor stack at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0025 tests passed ==="
