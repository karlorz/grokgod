#!/bin/sh
set -eu

# test_shim.sh: Standalone tests for grok-shim.sh
# Requires NO root, does NOT touch real ~/.local/bin or ~/.grokgod.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

if [ ! -f "$SHIM_SRC" ]; then
  echo "FAIL: shim not found at $SHIM_SRC" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# Set up test environment inside TMP_DIR
TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
TEST_GROKGOD_SRC="$TMP_DIR/grokgod_repo"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_GROKGOD_SRC" "$TEST_HOME/.local/bin"

# 1. Setup fake grok binary in TEST_GROKGOD_HOME/bin/grok
FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"
INVOCATION_COUNT_FILE="$TMP_DIR/fake_bin_invocations.txt"
echo "0" > "$INVOCATION_COUNT_FILE"

cat << 'EOF' > "$FAKE_BIN"
#!/bin/sh
set -eu
count=$(cat "$TMP_DIR/fake_bin_invocations.txt")
echo "$((count + 1))" > "$TMP_DIR/fake_bin_invocations.txt"
echo "FAKE_BIN_CALLED"
echo "GROK_DISABLE_AUTOUPDATER=${GROK_DISABLE_AUTOUPDATER:-NOT_SET}"
echo "ARGS:$*"
EOF
chmod +x "$FAKE_BIN"

# Helper to run the shim with fake env
run_shim() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" "$@"
}

echo "=== Running Shim Tests ==="

# Test 1: Passthrough with flags and env var check
echo "Test 1: Passthrough with arguments and auto-updater disable check"
echo "0" > "$INVOCATION_COUNT_FILE"
OUT="$(run_shim hello --flag "arg with spaces")"
echo "$OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: Fake bin was not called"; exit 1; }
echo "$OUT" | grep -q "GROK_DISABLE_AUTOUPDATER=1" || { echo "FAIL: GROK_DISABLE_AUTOUPDATER=1 not visible in target"; exit 1; }
echo "$OUT" | grep -q "ARGS:hello --flag arg with spaces" || { echo "FAIL: Arguments not preserved ($OUT)"; exit 1; }
INV_COUNT="$(cat "$INVOCATION_COUNT_FILE")"
if [ "$INV_COUNT" -ne 1 ]; then
  echo "FAIL: Expected 1 invocation, got $INV_COUNT"; exit 1
fi
echo "PASS: Test 1"

# Test 2: Update dispatch to install.sh (including arguments and exit code)
echo "Test 2: Update dispatch"
cat << 'EOF' > "$TEST_GROKGOD_SRC/install.sh"
#!/bin/sh
echo "INSTALL_CALLED:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/install.sh"

UPDATE_OUT="$(run_shim update --release v1.0)"
echo "$UPDATE_OUT" | grep -q "INSTALL_CALLED:--release v1.0" || { echo "FAIL: install.sh not called with args ($UPDATE_OUT)"; exit 1; }

# Test 2b: Update dispatch exit code passthrough (e.g. failing with 42)
cat << 'EOF' > "$TEST_GROKGOD_SRC/install.sh"
#!/bin/sh
exit 42
EOF
chmod +x "$TEST_GROKGOD_SRC/install.sh"

set +e
run_shim update
STATUS_CODE=$?
set -eu
if [ "$STATUS_CODE" -ne 42 ]; then
  echo "FAIL: Expected exit code 42 from install.sh, got $STATUS_CODE"; exit 1
fi
echo "PASS: Test 2"

# Test 3: Status subcommand
echo "Test 3: Status subcommand"
echo "v1.0.0-test" > "$TEST_GROKGOD_HOME/.source-version"
# Put a fake GROKGOD shim at ~/.local/bin/grok
echo "# GROKGOD shim" > "$TEST_HOME/.local/bin/grok"

STATUS_OUT="$(run_shim status)"
echo "$STATUS_OUT" | grep -q "target binary: $TEST_GROKGOD_HOME/bin/grok" || { echo "FAIL: status output missing target binary"; exit 1; }
echo "$STATUS_OUT" | grep -q "target binary exists: yes" || { echo "FAIL: status output missing exists check"; exit 1; }
echo "$STATUS_OUT" | grep -q "source-version: v1.0.0-test" || { echo "FAIL: status output missing source-version"; exit 1; }
echo "$STATUS_OUT" | grep -q "~/.local/bin/grok is grokgod shim: yes" || { echo "FAIL: status output missing shim check"; exit 1; }
echo "$STATUS_OUT" | grep -q "free disk:" || { echo "FAIL: status output missing free disk"; exit 1; }
echo "PASS: Test 3"

# Test 4: Missing binary check
echo "Test 4: Missing binary handling"
MISSING_GROKGOD_HOME="$TMP_DIR/nonexistent_grokgod_home"
set +e
MISSING_ERR="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$MISSING_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  sh "$SHIM_SRC" some-command 2>&1
)"
MISSING_STATUS=$?
set -eu
if [ "$MISSING_STATUS" -ne 127 ]; then
  echo "FAIL: Expected exit code 127 on missing binary, got $MISSING_STATUS"; exit 1
fi
echo "$MISSING_ERR" | grep -i -q "grokgod update" || { echo "FAIL: Stderr did not mention 'grokgod update' ($MISSING_ERR)"; exit 1; }
echo "PASS: Test 4"

# Test 5: Cache dispatch
echo "Test 5: Cache dispatch"
# 5a: When grokgod-cache.sh does not exist
set +e
CACHE_ERR="$(run_shim cache 2>&1)"
CACHE_STATUS=$?
set -eu
if [ "$CACHE_STATUS" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 when grokgod-cache.sh not found, got $CACHE_STATUS"; exit 1
fi
echo "$CACHE_ERR" | grep -q "grokgod cache not installed" || { echo "FAIL: Unexpected cache missing message ($CACHE_ERR)"; exit 1; }

# 5b: When grokgod-cache.sh exists
mkdir -p "$TEST_GROKGOD_SRC/src"
cat << 'EOF' > "$TEST_GROKGOD_SRC/src/grokgod-cache.sh"
#!/bin/sh
echo "CACHE_SCRIPT_CALLED:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/src/grokgod-cache.sh"

CACHE_OUT="$(run_shim cache --clean)"
echo "$CACHE_OUT" | grep -q "CACHE_SCRIPT_CALLED:--clean" || { echo "FAIL: grokgod-cache.sh not called properly ($CACHE_OUT)"; exit 1; }
echo "PASS: Test 5"

# Test 6: No PATH recursion / Absolute path exec check
echo "Test 6: No PATH recursion verification"
echo "0" > "$INVOCATION_COUNT_FILE"
# Shadow grok on PATH with a recursive trap that fails if executed
PATH_SHADOW_DIR="$TMP_DIR/path_shadow"
mkdir -p "$PATH_SHADOW_DIR"
cat << 'EOF' > "$PATH_SHADOW_DIR/grok"
#!/bin/sh
echo "FAIL: PATH lookup was invoked for grok!" >&2
exit 99
EOF
chmod +x "$PATH_SHADOW_DIR/grok"

OUT_PATH_TEST="$(
  PATH="$PATH_SHADOW_DIR:$PATH" \
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" test-recursion
)"
echo "$OUT_PATH_TEST" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: Target binary not called"; exit 1; }
INV_COUNT="$(cat "$INVOCATION_COUNT_FILE")"
if [ "$INV_COUNT" -ne 1 ]; then
  echo "FAIL: Target binary was called $INV_COUNT times, expected exactly 1"; exit 1
fi
echo "PASS: Test 6"

# Test 7: Status persist inventory block
echo "Test 7: Status persist inventory block"
# 7a: applied and wrapper
printf "SHA=fake\nPATCHSET=v1.0.3\nVERSION=v1.0.3\nMODE=source\n" > "$TEST_GROKGOD_HOME/.source-version"
mkdir -p "$TEST_GROKGOD_SRC/src"
touch "$TEST_GROKGOD_SRC/src/grokgod-run.sh"

STATUS_PERSIST_OUT="$(run_shim status)"
echo "$STATUS_PERSIST_OUT" | grep -q "^persist:" || { echo "FAIL: status output missing persist header ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0001-normalize-plugin-skill-join: applied" || { echo "FAIL: status output missing applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0002-plan-mode-extra-writable: applied" || { echo "FAIL: status output missing 0002 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  overlay-pin: wrapper" || { echo "FAIL: status output missing overlay-pin wrapper ($STATUS_PERSIST_OUT)"; exit 1; }

# 7b: missing and missing
rm -f "$TEST_GROKGOD_HOME/.source-version" "$TEST_GROKGOD_SRC/src/grokgod-run.sh"
STATUS_MISSING_OUT="$(run_shim status)"
echo "$STATUS_MISSING_OUT" | grep -q "^persist:" || { echo "FAIL: status output missing persist header ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0001-normalize-plugin-skill-join: missing" || { echo "FAIL: status output missing patch missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0002-plan-mode-extra-writable: missing" || { echo "FAIL: status output missing 0002 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  overlay-pin: missing" || { echo "FAIL: status output missing overlay-pin missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "PASS: Test 7"

echo "Test 8: argv0 sessions — grok passthrough, grokgod wrapper"
mkdir -p "$TEST_GROKGOD_SRC/src"
cat << 'EOF' > "$TEST_GROKGOD_SRC/src/grokgod-sessions.sh"
#!/bin/sh
echo "SESSIONS_WRAPPER:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/src/grokgod-sessions.sh"
BIND="$TMP_DIR/argv0bin"
mkdir -p "$BIND"
cp "$SHIM_SRC" "$BIND/grok"
cp "$SHIM_SRC" "$BIND/grokgod"
chmod +x "$BIND/grok" "$BIND/grokgod"

echo "0" > "$INVOCATION_COUNT_FILE"
GROK_SESS_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  "$BIND/grok" sessions list --limit 2
)"
echo "$GROK_SESS_OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: grok sessions did not reach binary ($GROK_SESS_OUT)"; exit 1; }
echo "$GROK_SESS_OUT" | grep -q "ARGS:sessions list --limit 2" || { echo "FAIL: grok sessions args lost ($GROK_SESS_OUT)"; exit 1; }
echo "$GROK_SESS_OUT" | grep -q "SESSIONS_WRAPPER" && { echo "FAIL: grok sessions hit wrapper ($GROK_SESS_OUT)"; exit 1; }

GOD_SESS_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  "$BIND/grokgod" sessions prune --help
)"
echo "$GOD_SESS_OUT" | grep -q "SESSIONS_WRAPPER:prune --help" || { echo "FAIL: grokgod sessions missed wrapper ($GOD_SESS_OUT)"; exit 1; }
echo "$GOD_SESS_OUT" | grep -q "FAKE_BIN_CALLED" && { echo "FAIL: grokgod sessions hit grok binary ($GOD_SESS_OUT)"; exit 1; }
echo "PASS: Test 8"

echo "=== All tests passed successfully! ==="
