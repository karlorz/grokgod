#!/bin/sh
set -eu

# Thin shell entry point so this suite slots into the repo's `sh tests/<dir>/test_*.sh`
# convention, CI matrix, and local muscle memory.
#
# Everything of substance lives in test_tui_smoke.py; this wrapper's only job is
# to pick an interpreter and forward arguments. Exit code 77 means "skipped"
# (no PTY support, or no grok binary installed) and is passed through unchanged
# so callers can distinguish skip from failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "SKIP: no python3 on PATH" >&2
  exit 77
fi

exec "$PY" "$SCRIPT_DIR/test_tui_smoke.py" "$@"
