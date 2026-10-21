#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0026="$REPO_ROOT/patches/0026-cua-turn-end-release.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0026 Computer Use turn release patch tests ==="
[ -s "$PATCH_0026" ] || { echo "FAIL: 0026 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0026" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)), "duplicate file diff"
assert len(files) == 12, f"unexpected changed-file count: {files!r}"
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in (
    "notify_cua_turn_ended",
    "release_computer_use",
    "ComputerUseIPCCodexTurnEndedRequest",
    "x-codex-turn-metadata",
    "cua_cleanup_timeout_disables_connection",
    "cua_cleanup_tool_is_hidden_and_mac_bridge_runs_after_notification",
    "requires turn_ended",
):
    assert needle in added, f"missing release contract: {needle}"
print("PASS: 0026 Computer Use release contracts")
PY

verify_sky_bridge() {
  node --input-type=module - "$1/crates/codegen/xai-grok-mcp/src/cua_sky_service.mjs" <<'JS'
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
const root = await fs.mkdtemp(path.join(os.tmpdir(), "grok-sky-release-test-"));
try {
  const pkg = path.join(root, "node_modules/@oai/sky");
  await fs.mkdir(path.join(pkg, "targets/mac"), { recursive: true });
  await fs.writeFile(path.join(pkg, "package.json"), JSON.stringify({
    name: "@oai/sky", type: "module", exports: { "./service": "./service.js" }
  }));
  await fs.writeFile(path.join(pkg, "service.js"), `
    export const handleRpc = async request => ({ delegated: request });
    export const classifyError = error => ({ classified: error.message });
  `);
  await fs.writeFile(path.join(pkg, "targets/mac/native-pipe.js"), `
    export class MacNativePipeTransport {
      static async create(name) {
        globalThis.skyTransportCreates.push(name);
        const instance = { isClosed: false, request: async payload => {
          globalThis.skyReleaseRequests.push(payload); return { released: true };
        }};
        globalThis.skyTransport = instance;
        return instance;
      }
    }
  `);
  process.env.NODE_REPL_NODE_MODULE_DIRS = path.join(root, "node_modules");
  globalThis.skyTransportCreates = [];
  globalThis.skyReleaseRequests = [];
  const service = await import(pathToFileURL(process.argv[2]).href);
  assert.deepEqual(await service.handleRpc({ type: "ordinary" }), { delegated: { type: "ordinary" } });
  assert.deepEqual(service.classifyError(new Error("test")), { classified: "test" });
  await assert.rejects(service.handleRpc({ type: "grok_turn_ended", sessionId: "", turnId: "t" }));
  const release = { type: "grok_turn_ended", sessionId: "s", turnId: "t" };
  assert.deepEqual(await service.handleRpc(release), { released: true });
  await service.handleRpc(release);
  assert.deepEqual(globalThis.skyTransportCreates, ["CodexComputerUseIPC-5"]);
  assert.deepEqual(globalThis.skyReleaseRequests[0], {
    requestType: "ComputerUseIPCCodexTurnEndedRequest",
    request: { threadID: "s", turnID: "t" },
    codexMetadata: { session_id: "s", turn_id: "t" }, timeoutSeconds: 2
  });
  globalThis.skyTransport.isClosed = true;
  await service.handleRpc(release);
  assert.equal(globalThis.skyTransportCreates.length, 2);
  console.log("PASS: Sky bridge delegates ordinary APIs and releases the matching native turn");
} finally {
  await fs.rm(root, { recursive: true, force: true });
}
JS
}

if git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  TMP_WT="$(mktemp -d -t grokgod-test-0026-wt-XXXXXX)"
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
    [ "$predecessor" = "$PATCH_0026" ] && break
    git -C "$TMP_WT" apply --check "$predecessor"
    git -C "$TMP_WT" apply "$predecessor"
  done
  git -C "$TMP_WT" apply --check "$PATCH_0026"
  git -C "$TMP_WT" apply "$PATCH_0026"
  git -C "$TMP_WT" diff --check
  verify_sky_bridge "$TMP_WT"
  echo "PASS: 0026 applies after full predecessor stack at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
  # Still apply-check against a throwaway clone if present.
  if git -C /tmp/grok-build-2bdd1d6a rev-parse --git-dir >/dev/null 2>&1; then
    TMP_WT="$(mktemp -d -t grokgod-test-0026-clone-XXXXXX)"
    git -C /tmp/grok-build-2bdd1d6a worktree add --detach "$TMP_WT" "$PIN_SHA" >/dev/null
    cleanup() { git -C /tmp/grok-build-2bdd1d6a worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true; }
    trap cleanup EXIT INT TERM
    for predecessor in "$REPO_ROOT"/patches/*.patch; do
      [ -f "$predecessor" ] || continue
      [ "$predecessor" = "$PATCH_0026" ] && break
      git -C "$TMP_WT" apply --check "$predecessor"
      git -C "$TMP_WT" apply "$predecessor"
    done
    git -C "$TMP_WT" apply --check "$PATCH_0026"
    git -C "$TMP_WT" apply "$PATCH_0026"
    git -C "$TMP_WT" diff --check
  verify_sky_bridge "$TMP_WT"
    echo "PASS: 0026 applies after full predecessor stack on /tmp clone"
  fi
fi

echo "=== Patch 0026 tests passed ==="
