#!/bin/sh
set -eu

# test_orca_pin.sh: Standalone tests for Orca-aware shim overlay injection
# and grokgod pin check --expect-orca-pin.
# Uses isolated sandbox in mktemp -d, never touches live files or live PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIN_SRC="$REPO_ROOT/src/grokgod-pin.sh"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

if [ ! -f "$PIN_SRC" ] || [ ! -f "$SHIM_SRC" ]; then
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
TEST_GROKGOD_SRC="$TMP_DIR/grokgod_repo"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_GROKGOD_HOME/pin" "$TEST_GROKGOD_SRC" "$TEST_HOME/.local/bin"

FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"
INVOCATIONS_FILE="$TMP_DIR/invocations.txt"
touch "$INVOCATIONS_FILE"

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

echo "--- INVOCATION ---" >> "$TMP_DIR/invocations.txt"
echo "GROK_CONFIG_PATH=${GROK_CONFIG_PATH:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "ORCA_WORKSPACE_ID=${ORCA_WORKSPACE_ID:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "ARGS:$*" >> "$TMP_DIR/invocations.txt"
echo "FAKE_BIN_SUCCESS"
EOF
chmod +x "$FAKE_BIN"

run_shim() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" "$@"
}

run_pin() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  sh "$PIN_SRC" "$@"
}

echo "=== Running Orca Pin Test Suite ==="

# ─────────────────────────────────────────────────────────
# Test (a): ORCA_WORKSPACE_ID set + overlay file exists → GROK_CONFIG_PATH exported
# ─────────────────────────────────────────────────────────
echo "Test (a): ORCA_WORKSPACE_ID set + overlay file exists -> GROK_CONFIG_PATH exported"
cat << 'EOF' > "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
[models]
default = "flash-max"
EOF
> "$INVOCATIONS_FILE"

OUT_A="$(ORCA_WORKSPACE_ID="orca-ws-123" run_shim "hello" "--flag")"
echo "$OUT_A" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin not called in Test (a)"; exit 1; }
grep -q "GROK_CONFIG_PATH=$TEST_GROKGOD_HOME/pin/orca-pin.toml" "$INVOCATIONS_FILE" || {
  echo "FAIL: GROK_CONFIG_PATH not exported in Test (a)"; cat "$INVOCATIONS_FILE"; exit 1
}
echo "PASS: Test (a)"

# ─────────────────────────────────────────────────────────
# Test (b): ORCA_WORKSPACE_ID set + overlay file missing → GROK_CONFIG_PATH NOT set
# ─────────────────────────────────────────────────────────
echo "Test (b): ORCA_WORKSPACE_ID set + overlay file missing -> GROK_CONFIG_PATH NOT set"
rm -f "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
> "$INVOCATIONS_FILE"

OUT_B="$(ORCA_WORKSPACE_ID="orca-ws-123" run_shim "hello")"
echo "$OUT_B" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin not called in Test (b)"; exit 1; }
grep -q "GROK_CONFIG_PATH=NOT_SET" "$INVOCATIONS_FILE" || {
  echo "FAIL: GROK_CONFIG_PATH was set unexpectedly in Test (b)"; cat "$INVOCATIONS_FILE"; exit 1
}
echo "PASS: Test (b)"

# ─────────────────────────────────────────────────────────
# Test (c): ORCA_WORKSPACE_ID unset + overlay file exists → GROK_CONFIG_PATH NOT set
# ─────────────────────────────────────────────────────────
echo "Test (c): ORCA_WORKSPACE_ID unset + overlay file exists -> GROK_CONFIG_PATH NOT set"
cat << 'EOF' > "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
[models]
default = "flash-max"
EOF
> "$INVOCATIONS_FILE"

OUT_C="$(ORCA_WORKSPACE_ID="" run_shim "hello")"
echo "$OUT_C" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin not called in Test (c)"; exit 1; }
grep -q "GROK_CONFIG_PATH=NOT_SET" "$INVOCATIONS_FILE" || {
  echo "FAIL: GROK_CONFIG_PATH was set unexpectedly in Test (c)"; cat "$INVOCATIONS_FILE"; exit 1
}
echo "PASS: Test (c)"

# ─────────────────────────────────────────────────────────
# Test (d): GROK_CONFIG_PATH already set by caller → NOT overwritten
# ─────────────────────────────────────────────────────────
echo "Test (d): GROK_CONFIG_PATH already set by caller -> NOT overwritten"
> "$INVOCATIONS_FILE"

OUT_D="$(ORCA_WORKSPACE_ID="orca-ws-123" GROK_CONFIG_PATH="/custom/caller/config.toml" run_shim "hello")"
echo "$OUT_D" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin not called in Test (d)"; exit 1; }
grep -q "GROK_CONFIG_PATH=/custom/caller/config.toml" "$INVOCATIONS_FILE" || {
  echo "FAIL: GROK_CONFIG_PATH was overwritten in Test (d)"; cat "$INVOCATIONS_FILE"; exit 1
}
echo "PASS: Test (d)"

# ─────────────────────────────────────────────────────────
# Test (e): pin check --expect-orca-pin flash-max → exit 0 when file has default = "flash-max"
# ─────────────────────────────────────────────────────────
echo "Test (e): pin check --expect-orca-pin flash-max -> exit 0"
cat << 'EOF' > "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
[models]
default = "flash-max"
EOF

OUT_E="$(run_pin check --expect-orca-pin flash-max)"
echo "$OUT_E" | grep -q "pin_check ok orca_pin default_model=flash-max" || {
  echo "FAIL: Expected success output in Test (e), got: $OUT_E"
  exit 1
}
echo "PASS: Test (e)"

# ─────────────────────────────────────────────────────────
# Test (f): pin check --expect-orca-pin flash-max → exit 1 when file missing
# ─────────────────────────────────────────────────────────
echo "Test (f): pin check --expect-orca-pin flash-max -> exit 1 when file missing"
rm -f "$TEST_GROKGOD_HOME/pin/orca-pin.toml"

set +e
ERR_F="$(run_pin check --expect-orca-pin flash-max 2>&1)"
STATUS_F=$?
set -eu
if [ "$STATUS_F" -ne 1 ]; then
  echo "FAIL: Expected exit 1 in Test (f), got $STATUS_F"
  exit 1
fi
echo "$ERR_F" | grep -q "pin_check fail orca_pin_missing" || {
  echo "FAIL: Expected fail orca_pin_missing in Test (f), got: $ERR_F"
  exit 1
}
echo "PASS: Test (f)"

# ─────────────────────────────────────────────────────────
# Test (g): pin check --expect-orca-pin flash-max → exit 1 when file has different default
# ─────────────────────────────────────────────────────────
echo "Test (g): pin check --expect-orca-pin flash-max -> exit 1 when file has different default"
cat << 'EOF' > "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
[models]
default = "grok-4.6"
EOF

set +e
ERR_G="$(run_pin check --expect-orca-pin flash-max 2>&1)"
STATUS_G=$?
set -eu
if [ "$STATUS_G" -ne 1 ]; then
  echo "FAIL: Expected exit 1 in Test (g), got $STATUS_G"
  exit 1
fi
echo "$ERR_G" | grep -q "pin_check fail orca_pin default_model=grok-4.6 expect=flash-max" || {
  echo "FAIL: Expected fail orca_pin default_model mismatch in Test (g), got: $ERR_G"
  exit 1
}
echo "PASS: Test (g)"

# ─────────────────────────────────────────────────────────
# Test (h): status shows orca-pin: enabled when file exists, disabled when missing
# ─────────────────────────────────────────────────────────
echo "Test (h): status shows orca-pin: enabled / disabled"
# h1: when file exists
cat << 'EOF' > "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
[models]
default = "flash-max"
EOF

STATUS_H1="$(run_shim status)"
echo "$STATUS_H1" | grep -q "  orca-pin: enabled" || {
  echo "FAIL: Expected 'orca-pin: enabled' in Test (h1), got: $STATUS_H1"
  exit 1
}

# h2: when file missing
rm -f "$TEST_GROKGOD_HOME/pin/orca-pin.toml"
STATUS_H2="$(run_shim status)"
echo "$STATUS_H2" | grep -q "  orca-pin: disabled" || {
  echo "FAIL: Expected 'orca-pin: disabled' in Test (h2), got: $STATUS_H2"
  exit 1
}
echo "PASS: Test (h)"

echo "=== All Orca Pin tests passed successfully! ==="
