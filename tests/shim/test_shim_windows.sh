#!/bin/sh
set -eu

# test_shim_windows.sh: Static and syntax validation runner for grokgod Windows dispatcher
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Running Windows Shim Verification ==="
python3 "$REPO_ROOT/tests/shim/test_shim_windows.py"
echo "=== Windows Shim Verification Passed ==="
