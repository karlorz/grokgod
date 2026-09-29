#!/bin/sh
set -eu

# test_generated_installers.sh: runner for the generated-installer contract suite.
# Kept alongside the other tests/<dir>/test_*.sh entrypoints so CI can invoke it
# the same way as every other suite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Running Generated Installer Contract Suite ==="
python3 "$REPO_ROOT/tests/installer/test_generated_installers.py"
echo "=== Generated Installer Contract Suite Passed ==="
