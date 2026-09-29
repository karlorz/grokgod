#!/bin/sh
set -eu

# Verify the dedicated Rust patch-validation workflow contract without cloning
# grok-build or invoking Cargo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/rust-patch-validation.yml"
TEST_WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

echo "=== Running Rust Patch Validation Workflow Contract Tests ==="

python3 - "$WORKFLOW" "$TEST_WORKFLOW" <<'PY'
import re
import sys
from pathlib import Path

workflow_path = Path(sys.argv[1])
test_workflow_path = Path(sys.argv[2])

assert workflow_path.is_file(), f"missing workflow: {workflow_path}"
content = workflow_path.read_text()
test_content = test_workflow_path.read_text()

def require(needle: str, message: str) -> None:
    assert needle in content, message

require("name: Rust Patch Validation", "workflow name must remain explicit")
require("workflow_dispatch:", "workflow_dispatch trigger missing")
require("push:", "push trigger missing")
require("pull_request:", "pull_request trigger missing")
require("branches:\n      - main", "push trigger must be limited to main")
assert content.count("- 'patches/**'") == 2, "patch path must cover push and pull_request"
assert content.count("- 'install.sh'") == 2, (
    "install.sh path must cover push and pull_request because it defines PINNED_BASE_SHA"
)
assert content.count("- '.github/workflows/rust-patch-validation.yml'") == 2, (
    "workflow path must cover push and pull_request"
)

require("permissions:\n  contents: read", "permissions must be contents: read")
require("group: rust-patch-validation-${{ github.ref }}", "concurrency must be scoped by ref")
require("cancel-in-progress: true", "superseded runs must be canceled")
require("runs-on: ubuntu-24.04", "validation must use the pinned Ubuntu runner")

timeout_match = re.search(r"^\s*timeout-minutes:\s*(\d+)\s*$", content, re.MULTILINE)
assert timeout_match, "bounded job timeout missing"
timeout = int(timeout_match.group(1))
assert 90 <= timeout <= 120, f"timeout must be 90-120 minutes, got {timeout}"

require("uses: dtolnay/rust-toolchain@stable", "Rust setup action missing")
require('toolchain: "1.94.0"', "Rust toolchain must be exactly 1.94.0")
require('"rustc 1.94.0 "*', "rustc 1.94.0 runtime assertion missing")
require("rustc --version", "rustc version output missing")
require("cargo --version", "cargo version output missing")
require("uses: taiki-e/install-action@v2", "established dotslash installer missing")
require("tool: dotslash", "dotslash install input missing")
require("dotslash --version", "dotslash version output missing")

for package in ("build-essential", "pkg-config", "cmake", "libssl-dev"):
    require(package, f"Linux build dependency missing: {package}")

require("grep '^PINNED_BASE_SHA=' install.sh", "PINNED_BASE_SHA must be sourced from install.sh")
require("^[0-9a-f]{40}$", "PINNED_BASE_SHA must be validated as an exact SHA")
require('fetch --depth 1 origin "$PIN_SHA"', "pinned commit must be fetched shallowly")
require('checkout --detach "$PIN_SHA"', "pinned commit must be checked out detached")
require('actual_sha="$(git -C grok-build rev-parse HEAD)"', "checked-out SHA verification missing")
require('"$actual_sha" != "$PIN_SHA"', "checked-out SHA must be compared with the pin")
assert "origin/main" not in content, "validation must not target moving origin/main"

require("find \"$GITHUB_WORKSPACE/patches\"", "patch discovery must use the checked-out repository")
require("sort -z", "patches must be sorted deterministically")
require("No patch files found", "empty patch set must fail closed")
require('git -C grok-build apply --check "$patch_file"', "each patch must be apply-checked")
require('git -C grok-build apply "$patch_file"', "each checked patch must be applied")

require('CARGO_BUILD_JOBS: "1"', "Cargo build jobs must be limited to one")
require('CARGO_PROFILE_TEST_CODEGEN_UNITS: "1"', "test codegen units must be limited to one")
require('CARGO_INCREMENTAL: "0"', "incremental compilation must be disabled")
require(
    "CARGO_TARGET_DIR: ${{ github.workspace }}/.cargo-target/rust-patch-validation",
    "Cargo target directory must stay inside the runner workspace",
)

broad = "cargo test -p xai-grok-pager --lib credit_limit"
exact = (
    "cargo test -p xai-grok-pager --lib "
    "app::dispatch::tests::settings::set_default_model_idempotent_when_already_current -- --exact"
)
require(broad, "focused credit_limit library test missing")
require(exact, "exact idempotent model-selection regression test missing")
assert content.count("cargo test -p xai-grok-pager --lib") == 2, (
    "workflow must contain exactly the two focused pager library test commands"
)

registry_tests = (
    "registry::types::tests::non_pi_finalized_contract_snapshot_is_unchanged",
    "registry::types::tests::sanitize_enum_arrays_recurses_and_removes_empty_keywords",
    "registry::types::tests::finalized_generated_schemas_advertise_string_only_enums",
)
for test_name in registry_tests:
    require(
        f"cargo test -p xai-grok-tools --lib {test_name} -- --exact",
        f"exact xai-grok-tools registry test missing: {test_name}",
    )
assert content.count("cargo test -p xai-grok-tools --lib") == len(registry_tests), (
    "workflow must contain exactly the three focused xai-grok-tools registry test commands"
)

lower = content.lower()
for forbidden in (
    "cargo test --workspace",
    "cargo test --all",
    "cargo test --all-targets",
    "cargo build",
    "cargo check",
    "docker",
    "actions/cache",
):
    assert forbidden not in lower, f"forbidden broad/heavy workflow operation present: {forbidden}"

wire_command = "sh tests/release/test_rust_patch_validation_workflow.sh"
assert wire_command in test_content, "workflow contract test is not wired into .github/workflows/test.yml"

print("PASS: triggers, permissions, concurrency, and timeout")
print("PASS: exact toolchain, dotslash, and Linux dependency setup")
print("PASS: pinned SHA fetch/verification and sequential fail-closed patching")
print("PASS: memory-safe Cargo environment and focused --lib filters")
print("PASS: no full-workspace Cargo operation, target cache, or Docker")
print("PASS: contract test is wired into the repository test workflow")
PY

echo "=== Rust Patch Validation Workflow Contract Tests Passed ==="
