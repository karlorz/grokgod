#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Running Windows Installer Verification Suite ==="
python3 "$REPO_ROOT/tests/install/test_install_windows.py"
echo "=== Windows Installer Verification Passed ==="
