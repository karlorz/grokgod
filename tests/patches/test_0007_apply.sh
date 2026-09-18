#!/bin/sh
set -eu

# test_0007_apply.sh: Verify 0007-hosted-web-search-splice-decouple.patch exists
# and applies cleanly against PINNED_BASE_SHA.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0007="$REPO_ROOT/patches/0007-hosted-web-search-splice-decouple.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SCRIPT" >&2
  exit 1
fi
PIN_SHORT="$(printf '%s' "$PIN_SHA" | cut -c1-8)"

REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
if [ "${CI:-0}" = "1" ]; then
  REAL_GROK_BUILD="/nonexistent"
fi

echo "=== Running 0007 Hosted Web Search Splice Decouple Patch Tests ==="

if [ ! -s "$PATCH_0007" ]; then
  echo "FAIL: 0007 patch file not found or empty: $PATCH_0007" >&2
  exit 1
fi
echo "PASS: Patch 0007 file exists and is non-empty"

# Keep the three insertion hunks narrow so upstream memory-v2 reshaping does not
# make this patch reject. Parse the patch once and require shared anchors to be
# actual space-prefixed context lines, not unrelated additions or removals.
python3 - "$PATCH_0007" <<'PY'
from pathlib import Path
import sys

patch_path = Path(sys.argv[1])
lines = patch_path.read_text(encoding="utf-8").splitlines()
hunks = []
current_file = None
current_hunk = None

for line in lines:
    if line.startswith("diff --git "):
        current_file = line.split(" b/", 1)[1]
        current_hunk = None
    elif current_file is not None and line.startswith("@@ "):
        current_hunk = {"file": current_file, "lines": []}
        hunks.append(current_hunk)
    elif current_hunk is not None:
        current_hunk["lines"].append(line)

targets = [
    (
        "crates/codegen/xai-grok-shell/src/session/acp_session_impl/spawn.rs",
        "+        hosted_web_search_disabled: disable_web_search,",
        (
            "        web_search_config: web_search_config.clone(),",
            "        web_search_domains,",
        ),
    ),
    (
        "crates/codegen/xai-grok-shell/src/session/agent_rebuild.rs",
        "+    pub hosted_web_search_disabled: bool,",
        (
            "    pub web_search_config: WebSearchConfig,",
            "    pub web_search_domains: Option<xai_grok_sampling_types::WebSearchOptions>,",
        ),
    ),
    (
        "crates/codegen/xai-grok-shell/src/session/agent_rebuild.rs",
        "+        hosted_web_search_disabled: false,",
        (
            "        web_search_config: WebSearchConfig::default(),",
            "        web_search_domains: None,",
        ),
    ),
]

for file_name, expected_added, anchors in targets:
    matches = [
        hunk
        for hunk in hunks
        if hunk["file"] == file_name and expected_added in hunk["lines"]
    ]
    if len(matches) != 1:
        raise AssertionError(
            f"expected exactly one {file_name} hunk containing {expected_added!r}; "
            f"found {len(matches)}"
        )

    context = [line[1:] for line in matches[0]["lines"] if line.startswith(" ")]
    missing = [anchor for anchor in anchors if anchor not in context]
    if missing:
        raise AssertionError(
            f"{file_name} insertion lost space-prefixed context anchor(s): {missing!r}"
        )
    if any("memory_v2_access" in line for line in context):
        raise AssertionError(
            f"{file_name} insertion hunk must not use memory_v2_access context"
        )

print("PASS: 0007 insertion hunks preserve shared anchors without memory_v2_access context")
PY

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0007-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  git -C "$TMP_WT" apply --check "$PATCH_0007" || {
    echo "FAIL: 0007 patch failed to apply cleanly to $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0007 applies cleanly to $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0007 Tests Passed ==="
