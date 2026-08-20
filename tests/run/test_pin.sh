#!/bin/sh
set -eu

# test_pin.sh: Standalone tests for grokgod pin check
# Uses isolated sandbox in mktemp -d, never touches live files or live PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIN_SRC="$REPO_ROOT/src/grokgod-pin.sh"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

if [ ! -f "$PIN_SRC" ] && [ ! -f "$SHIM_SRC" ]; then
  echo "FAIL: required source files not found" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_HOME/.grok" "$TEST_HOME/.local/bin"

FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"

cat << 'EOF' > "$FAKE_BIN"
#!/bin/sh
set -eu
cmd="${1:-}"
if [ "$cmd" = "models" ]; then
  cat << 'MODELS_EOF'
You are logged in with grok.com.

Default model: flash-max

Available models:
  - grok-4.6
  - grok-4.5
  * flash-max (default)
  - sonnet
MODELS_EOF
  exit 0
fi
echo "MOCK_GROK_UNKNOWN_COMMAND:$*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN"

run_pin() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  TMP_DIR="$TMP_DIR" \
  sh "$PIN_SRC" "$@"
}

run_shim_pin() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" pin "$@"
}

echo "=== Running grokgod pin Test Suite ==="

# ─────────────────────────────────────────────────────────
# Test (a): Matching --expect-default exits 0 and prints ok
# ─────────────────────────────────────────────────────────
echo "Test (a): Matching --expect-default exits 0 and prints ok"
OUT_A="$(run_pin check --expect-default flash-max)"
echo "$OUT_A" | grep -q "^pin_check ok default_model=flash-max$" || {
  echo "FAIL: Expected 'pin_check ok default_model=flash-max', got '$OUT_A'"
  exit 1
}
echo "PASS: Test (a)"

# ─────────────────────────────────────────────────────────
# Test (b): Mismatching --expect-default exits 1 and prints fail on stderr
# ─────────────────────────────────────────────────────────
echo "Test (b): Mismatching --expect-default exits 1"
set +e
ERR_B="$(run_pin check --expect-default grok-4.6 2>&1)"
STATUS_B=$?
set -eu
if [ "$STATUS_B" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for model mismatch, got $STATUS_B"
  exit 1
fi
echo "$ERR_B" | grep -q "pin_check fail default_model=flash-max expect=grok-4.6" || {
  echo "FAIL: Unexpected error output for mismatch: $ERR_B"
  exit 1
}
echo "PASS: Test (b)"

# ─────────────────────────────────────────────────────────
# Test (c): --expect-no-overlay fails when overlay env set, passes when unset
# ─────────────────────────────────────────────────────────
echo "Test (c): --expect-no-overlay behavior"
# c1: Unset env -> passes
OUT_C1="$(run_pin check --expect-default flash-max --expect-no-overlay)"
echo "$OUT_C1" | grep -q "^pin_check ok default_model=flash-max$" || {
  echo "FAIL: Expected ok when overlay unset, got '$OUT_C1'"
  exit 1
}

# c2: GROK_CONFIG_PATH set -> fails exit 1
set +e
ERR_C2="$(GROK_CONFIG_PATH="/tmp/fake-overlay.toml" run_pin check --expect-default flash-max --expect-no-overlay 2>&1)"
STATUS_C2=$?
set -eu
if [ "$STATUS_C2" -ne 1 ]; then
  echo "FAIL: Expected exit 1 when GROK_CONFIG_PATH set with --expect-no-overlay, got $STATUS_C2"
  exit 1
fi
echo "$ERR_C2" | grep -q "pin_check fail overlay_env_set GROK_CONFIG_PATH=/tmp/fake-overlay.toml" || {
  echo "FAIL: Unexpected error output for GROK_CONFIG_PATH: $ERR_C2"
  exit 1
}

# c3: GROK_CONFIG set -> fails exit 1
set +e
ERR_C3="$(GROK_CONFIG="/tmp/fake-grok-config.toml" run_pin check --expect-no-overlay 2>&1)"
STATUS_C3=$?
set -eu
if [ "$STATUS_C3" -ne 1 ]; then
  echo "FAIL: Expected exit 1 when GROK_CONFIG set with --expect-no-overlay, got $STATUS_C3"
  exit 1
fi
echo "$ERR_C3" | grep -q "pin_check fail overlay_env_set GROK_CONFIG=/tmp/fake-grok-config.toml" || {
  echo "FAIL: Unexpected error output for GROK_CONFIG: $ERR_C3"
  exit 1
}
echo "PASS: Test (c)"

# ─────────────────────────────────────────────────────────
# Test (d): Flagless pin check prints facts exit 0
# ─────────────────────────────────────────────────────────
echo "Test (d): Flagless pin check prints facts exit 0"
OUT_D="$(run_pin check)"
echo "$OUT_D" | grep -q "default_model=flash-max" || {
  echo "FAIL: Flagless check missing default_model: '$OUT_D'"
  exit 1
}
echo "$OUT_D" | grep -q "GROK_CONFIG_PATH=" || echo "$OUT_D" | grep -q "overlay_env_set=" || echo "$OUT_D" | grep -q "GROK_CONFIG_PATH_set=" || {
  echo "FAIL: Flagless check missing env facts: '$OUT_D'"
  exit 1
}
echo "PASS: Test (d)"

# ─────────────────────────────────────────────────────────
# Test (e): Unknown subcommand / args / missing value exits 2
# ─────────────────────────────────────────────────────────
echo "Test (e): Unknown subcommand, args, missing value exits 2"
# e1: unknown subcommand
set +e
ERR_E1="$(run_pin unknown 2>&1)"
STATUS_E1=$?
set -eu
if [ "$STATUS_E1" -ne 2 ]; then
  echo "FAIL: Expected exit 2 for unknown subcommand, got $STATUS_E1"
  exit 1
fi

# e2: no subcommand
set +e
ERR_E2="$(run_pin 2>&1)"
STATUS_E2=$?
set -eu
if [ "$STATUS_E2" -ne 2 ]; then
  echo "FAIL: Expected exit 2 for empty subcommand, got $STATUS_E2"
  exit 1
fi

# e3: missing --expect-default value
set +e
ERR_E3="$(run_pin check --expect-default 2>&1)"
STATUS_E3=$?
set -eu
if [ "$STATUS_E3" -ne 2 ]; then
  echo "FAIL: Expected exit 2 for missing --expect-default value, got $STATUS_E3"
  exit 1
fi

# e4: unknown flag
set +e
ERR_E4="$(run_pin check --unknown-flag 2>&1)"
STATUS_E4=$?
set -eu
if [ "$STATUS_E4" -ne 2 ]; then
  echo "FAIL: Expected exit 2 for unknown flag, got $STATUS_E4"
  exit 1
fi
echo "PASS: Test (e)"

# ─────────────────────────────────────────────────────────
# Test (f): Shim dispatches 'pin' to script
# ─────────────────────────────────────────────────────────
echo "Test (f): Shim dispatches pin subcommand"
SHIM_OUT="$(run_shim_pin check --expect-default flash-max)"
echo "$SHIM_OUT" | grep -q "^pin_check ok default_model=flash-max$" || {
  echo "FAIL: Shim pin check dispatch failed, got '$SHIM_OUT'"
  exit 1
}
echo "PASS: Test (f)"

# ─────────────────────────────────────────────────────────
# Test (g): Binary resolution - PATH fallback when GROKGOD_HOME/bin/grok missing
# ─────────────────────────────────────────────────────────
echo "Test (g): Binary resolution fallback to PATH"
PATH_BIN_DIR="$TMP_DIR/path_bin"
mkdir -p "$PATH_BIN_DIR"
cp "$FAKE_BIN" "$PATH_BIN_DIR/grok"
chmod +x "$PATH_BIN_DIR/grok"

OUT_G="$(
  PATH="$PATH_BIN_DIR:$PATH" \
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TMP_DIR/empty_grokgod" \
  GROKGOD_SRC="$REPO_ROOT" \
  sh "$PIN_SRC" check --expect-default flash-max
)"
echo "$OUT_G" | grep -q "^pin_check ok default_model=flash-max$" || {
  echo "FAIL: PATH fallback failed, got '$OUT_G'"
  exit 1
}

# When neither exists -> exit 127
set +e
ERR_G2="$(
  PATH="/nonexistent" \
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TMP_DIR/empty_grokgod" \
  GROKGOD_SRC="$REPO_ROOT" \
  sh "$PIN_SRC" check --expect-default flash-max 2>&1
)"
STATUS_G2=$?
set -eu
if [ "$STATUS_G2" -ne 127 ]; then
  echo "FAIL: Expected exit 127 when grok binary not found, got $STATUS_G2"
  exit 1
fi
echo "PASS: Test (g)"

echo "=== All grokgod pin tests passed successfully! ==="
