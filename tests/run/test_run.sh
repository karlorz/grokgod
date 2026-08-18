#!/bin/sh
set -eu

# test_run.sh: Standalone tests for grokgod run (--automation-root and --overlay)
# Uses isolated sandbox in mktemp -d, never touches live files or live PATH.

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

TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_HOME/.grok" "$TEST_HOME/.local/bin"

FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"
INVOCATIONS_FILE="$TMP_DIR/invocations.txt"
touch "$INVOCATIONS_FILE"

cat << 'EOF' > "$FAKE_BIN"
#!/bin/sh
set -eu
echo "--- INVOCATION ---" >> "$TMP_DIR/invocations.txt"
echo "GROK_CONFIG_PATH=${GROK_CONFIG_PATH:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "GROK_DISABLE_AUTOUPDATER=${GROK_DISABLE_AUTOUPDATER:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "ARGS:$*" >> "$TMP_DIR/invocations.txt"
echo "FAKE_BIN_SUCCESS"
EOF
chmod +x "$FAKE_BIN"

run_grokgod() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" "$@"
}

echo "=== Running grokgod run Test Suite ==="

# ─────────────────────────────────────────────────────────
# Test 1: Happy path with --automation-root
# ─────────────────────────────────────────────────────────
echo "Test 1: Happy path with --automation-root"
AUTO_DIR_1="$TMP_DIR/auto1"
mkdir -p "$AUTO_DIR_1"
cat << 'EOF' > "$AUTO_DIR_1/grok-overlay.toml"
[models]
default = "grok-beta"
EOF
echo "Perform weekly cache scan prompt" > "$AUTO_DIR_1/launchd-prompt.txt"

> "$INVOCATIONS_FILE"
OUT1="$(run_grokgod run --automation-root "$AUTO_DIR_1")"
echo "$OUT1" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 1 ($OUT1)"; exit 1; }

grep -q "GROK_CONFIG_PATH=$AUTO_DIR_1/grok-overlay.toml" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH not set correctly in Test 1"; cat "$INVOCATIONS_FILE"; exit 1; }
grep -q "ARGS:-p Perform weekly cache scan prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Target binary args incorrect in Test 1"; cat "$INVOCATIONS_FILE"; exit 1; }

# Check that -m is NOT anywhere in ARGS
if grep "ARGS:" "$INVOCATIONS_FILE" | grep -E -q '(^|[[:space:]])-m([[:space:]]|$)'; then
  echo "FAIL: '-m' found in target binary arguments in Test 1!"; cat "$INVOCATIONS_FILE"; exit 1
fi
echo "PASS: Test 1"

# ─────────────────────────────────────────────────────────
# Test 1b: --dry-run prints env+argv and does NOT invoke fake bin
# ─────────────────────────────────────────────────────────
echo "Test 1b: --dry-run prints env and argv without invoking binary"
> "$INVOCATIONS_FILE"
OUT1B="$(run_grokgod run --automation-root "$AUTO_DIR_1" --dry-run)"
echo "$OUT1B" | grep -q "GROK_CONFIG_PATH=$AUTO_DIR_1/grok-overlay.toml" || { echo "FAIL: dry-run missing GROK_CONFIG_PATH ($OUT1B)"; exit 1; }
echo "$OUT1B" | grep -q "EXEC: .* -p Perform weekly cache scan prompt" || { echo "FAIL: dry-run missing EXEC line ($OUT1B)"; exit 1; }
echo "$OUT1B" | grep -q "RESUME:" || { echo "FAIL: dry-run missing RESUME line ($OUT1B)"; exit 1; }
echo "$OUT1B" | grep -q "grok sessions list" || { echo "FAIL: dry-run missing 'grok sessions list' ($OUT1B)"; exit 1; }

if [ -s "$INVOCATIONS_FILE" ]; then
  echo "FAIL: Fake bin was invoked during --dry-run!"; cat "$INVOCATIONS_FILE"; exit 1
fi
echo "PASS: Test 1b"

# ─────────────────────────────────────────────────────────
# Test 2: Bare grok passthrough does NOT set GROK_CONFIG_PATH
# ─────────────────────────────────────────────────────────
echo "Test 2: Bare grok passthrough does not set GROK_CONFIG_PATH"
> "$INVOCATIONS_FILE"
OUT2="$(run_grokgod "echo hello")"
echo "$OUT2" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 2"; exit 1; }

grep -q "GROK_CONFIG_PATH=NOT_SET" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH was unexpectedly set in bare grok passthrough"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 2"

# ─────────────────────────────────────────────────────────
# Test 3: Missing grok-overlay.toml -> exit 1
# ─────────────────────────────────────────────────────────
echo "Test 3: Missing grok-overlay.toml in automation root"
AUTO_DIR_NO_OVERLAY="$TMP_DIR/auto_no_overlay"
mkdir -p "$AUTO_DIR_NO_OVERLAY"
echo "Prompt only" > "$AUTO_DIR_NO_OVERLAY/launchd-prompt.txt"

set +e
ERR3="$(run_grokgod run --automation-root "$AUTO_DIR_NO_OVERLAY" 2>&1)"
STATUS3=$?
set -eu

if [ "$STATUS3" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for missing grok-overlay.toml, got $STATUS3"; exit 1
fi
echo "$ERR3" | grep -q "missing grok-overlay.toml" || { echo "FAIL: Missing error message for missing overlay ($ERR3)"; exit 1; }
echo "PASS: Test 3"

# ─────────────────────────────────────────────────────────
# Test 4: DIR == $HOME -> exit 1, DIR == ~/.grok -> exit 1, DIR == ~/.grokgod -> exit 1
# ─────────────────────────────────────────────────────────
echo "Test 4: Safety rejects DIR == \$HOME, ~/.grok, ~/.grokgod"
set +e
ERR4_HOME="$(run_grokgod run --automation-root "$TEST_HOME" 2>&1)"
STATUS4_HOME=$?

ERR4_GROK="$(run_grokgod run --automation-root "$TEST_HOME/.grok" 2>&1)"
STATUS4_GROK=$?

ERR4_GROKGOD="$(run_grokgod run --automation-root "$TEST_HOME/.grokgod" 2>&1)"
STATUS4_GROKGOD=$?
set -eu

if [ "$STATUS4_HOME" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for DIR == \$HOME, got $STATUS4_HOME"; exit 1
fi
echo "$ERR4_HOME" | grep -q "automation root cannot be \$HOME" || { echo "FAIL: Bad error for \$HOME ($ERR4_HOME)"; exit 1; }

if [ "$STATUS4_GROK" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for DIR == ~/.grok, got $STATUS4_GROK"; exit 1
fi
echo "$ERR4_GROK" | grep -q "automation root cannot be ~/.grok" || { echo "FAIL: Bad error for ~/.grok ($ERR4_GROK)"; exit 1; }

if [ "$STATUS4_GROKGOD" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for DIR == ~/.grokgod, got $STATUS4_GROKGOD"; exit 1
fi
echo "$ERR4_GROKGOD" | grep -q "automation root cannot be ~/.grokgod" || { echo "FAIL: Bad error for ~/.grokgod ($ERR4_GROKGOD)"; exit 1; }
echo "PASS: Test 4"

# ─────────────────────────────────────────────────────────
# Test 5: Overlay content guard (reject [mcp_servers], api_key, etc.)
# ─────────────────────────────────────────────────────────
echo "Test 5: Overlay content guard"
AUTO_DIR_FORBIDDEN="$TMP_DIR/auto_forbidden"
mkdir -p "$AUTO_DIR_FORBIDDEN"
echo "Dummy prompt" > "$AUTO_DIR_FORBIDDEN/launchd-prompt.txt"

# 5a: [mcp_servers]
cat << 'EOF' > "$AUTO_DIR_FORBIDDEN/grok-overlay.toml"
[mcp_servers]
foo = "bar"
EOF
set +e
ERR5A="$(run_grokgod run --automation-root "$AUTO_DIR_FORBIDDEN" 2>&1)"
STATUS5A=$?
set -eu
if [ "$STATUS5A" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for [mcp_servers], got $STATUS5A"; exit 1
fi
echo "$ERR5A" | grep -q "forbidden sections or keys" || { echo "FAIL: Error missing forbidden notice ($ERR5A)"; exit 1; }

# 5b: api_key
cat << 'EOF' > "$AUTO_DIR_FORBIDDEN/grok-overlay.toml"
[general]
api_key = "secret"
EOF
set +e
ERR5B="$(run_grokgod run --automation-root "$AUTO_DIR_FORBIDDEN" 2>&1)"
STATUS5B=$?
set -eu
if [ "$STATUS5B" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for api_key, got $STATUS5B"; exit 1
fi
echo "$ERR5B" | grep -q "forbidden sections or keys" || { echo "FAIL: Error missing forbidden notice ($ERR5B)"; exit 1; }

# 5c: [auth]
cat << 'EOF' > "$AUTO_DIR_FORBIDDEN/grok-overlay.toml"
[auth]
token = "abc"
EOF
set +e
ERR5C="$(run_grokgod run --automation-root "$AUTO_DIR_FORBIDDEN" 2>&1)"
STATUS5C=$?
set -eu
if [ "$STATUS5C" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for [auth], got $STATUS5C"; exit 1
fi

# 5d: [plugins]
cat << 'EOF' > "$AUTO_DIR_FORBIDDEN/grok-overlay.toml"
[plugins]
enabled = true
EOF
set +e
ERR5D="$(run_grokgod run --automation-root "$AUTO_DIR_FORBIDDEN" 2>&1)"
STATUS5D=$?
set -eu
if [ "$STATUS5D" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for [plugins], got $STATUS5D"; exit 1
fi

# 5e: [subagents]
cat << 'EOF' > "$AUTO_DIR_FORBIDDEN/grok-overlay.toml"
[subagents.models]
gp = "sonnet"
EOF
set +e
ERR5E="$(run_grokgod run --automation-root "$AUTO_DIR_FORBIDDEN" 2>&1)"
STATUS5E=$?
set -eu
if [ "$STATUS5E" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for [subagents], got $STATUS5E"; exit 1
fi

echo "PASS: Test 5 - content guard rejections"

# ─────────────────────────────────────────────────────────
# Test 6: Comment line containing forbidden keyword is NOT rejected
# ─────────────────────────────────────────────────────────
echo "Test 6: Comment line containing forbidden keyword passes"
AUTO_DIR_COMMENT="$TMP_DIR/auto_comment"
mkdir -p "$AUTO_DIR_COMMENT"
cat << 'EOF' > "$AUTO_DIR_COMMENT/grok-overlay.toml"
# [mcp_servers] mentioned in comment
# api_key is also mentioned here
[models]
default = "grok-beta"
EOF
echo "Valid prompt text" > "$AUTO_DIR_COMMENT/launchd-prompt.txt"

OUT6="$(run_grokgod run --automation-root "$AUTO_DIR_COMMENT")"
echo "$OUT6" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Comment containing forbidden keyword was rejected ($OUT6)"; exit 1; }
echo "PASS: Test 6"

# ─────────────────────────────────────────────────────────
# Test 7: --overlay FILE explicit path works same as automation-root
# ─────────────────────────────────────────────────────────
echo "Test 7: --overlay FILE explicit path"
EXPLICIT_DIR="$TMP_DIR/explicit"
mkdir -p "$EXPLICIT_DIR"
cat << 'EOF' > "$EXPLICIT_DIR/my-custom-overlay.toml"
[models]
default = "grok-2"
EOF
echo "Explicit prompt" > "$EXPLICIT_DIR/my-prompt.txt"

> "$INVOCATIONS_FILE"
OUT7="$(run_grokgod run --overlay "$EXPLICIT_DIR/my-custom-overlay.toml" --prompt-file "$EXPLICIT_DIR/my-prompt.txt")"
echo "$OUT7" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 7"; exit 1; }

grep -q "GROK_CONFIG_PATH=$EXPLICIT_DIR/my-custom-overlay.toml" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH not set to explicit file in Test 7"; cat "$INVOCATIONS_FILE"; exit 1; }
grep -q "ARGS:-p Explicit prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Prompt file not read in Test 7"; cat "$INVOCATIONS_FILE"; exit 1; }

# Also test inline --prompt with --overlay
> "$INVOCATIONS_FILE"
OUT7B="$(run_grokgod run --overlay "$EXPLICIT_DIR/my-custom-overlay.toml" --prompt "inline test prompt")"
echo "$OUT7B" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 7b"; exit 1; }
grep -q "ARGS:-p inline test prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Inline prompt not passed in Test 7b"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 7"

# ─────────────────────────────────────────────────────────
# Test 8: Prompt file missing -> exit 1 (unless --prompt given)
# ─────────────────────────────────────────────────────────
echo "Test 8: Missing prompt handling"
AUTO_DIR_NO_PROMPT="$TMP_DIR/auto_no_prompt"
mkdir -p "$AUTO_DIR_NO_PROMPT"
cat << 'EOF' > "$AUTO_DIR_NO_PROMPT/grok-overlay.toml"
[models]
default = "grok-beta"
EOF

set +e
ERR8A="$(run_grokgod run --automation-root "$AUTO_DIR_NO_PROMPT" 2>&1)"
STATUS8A=$?

ERR8B="$(run_grokgod run --overlay "$AUTO_DIR_NO_PROMPT/grok-overlay.toml" --prompt-file "$AUTO_DIR_NO_PROMPT/nonexistent.txt" 2>&1)"
STATUS8B=$?
set -eu

if [ "$STATUS8A" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for missing default launchd-prompt.txt, got $STATUS8A"; exit 1
fi
echo "$ERR8A" | grep -q "prompt" || { echo "FAIL: Missing error message about prompt ($ERR8A)"; exit 1; }

if [ "$STATUS8B" -ne 1 ]; then
  echo "FAIL: Expected exit 1 for missing explicit --prompt-file, got $STATUS8B"; exit 1
fi
echo "$ERR8B" | grep -q "prompt file does not exist" || { echo "FAIL: Missing error message for nonexistent prompt file ($ERR8B)"; exit 1; }

# But providing --prompt inline works even without launchd-prompt.txt
OUT8C="$(run_grokgod run --automation-root "$AUTO_DIR_NO_PROMPT" --prompt "override prompt")"
echo "$OUT8C" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Inline prompt failed when launchd-prompt.txt was absent"; exit 1; }
echo "PASS: Test 8"

# ─────────────────────────────────────────────────────────
# Test 9: Pass-through args after '--' appear before -p in child argv
# ─────────────────────────────────────────────────────────
echo "Test 9: Pass-through args after '--' appear before -p"
> "$INVOCATIONS_FILE"
OUT9="$(run_grokgod run --automation-root "$AUTO_DIR_1" -- --always-approve --cwd "$TMP_DIR/custom_cwd")"
echo "$OUT9" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 9 ($OUT9)"; exit 1; }

grep -q "GROK_CONFIG_PATH=$AUTO_DIR_1/grok-overlay.toml" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH not set correctly in Test 9"; cat "$INVOCATIONS_FILE"; exit 1; }
grep -q "ARGS:--always-approve --cwd $TMP_DIR/custom_cwd -p Perform weekly cache scan prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Target binary args incorrect in Test 9"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 9"

# ─────────────────────────────────────────────────────────
# Test 10: GROK_CONFIG_PATH exported when pass-through present with --overlay
# ─────────────────────────────────────────────────────────
echo "Test 10: GROK_CONFIG_PATH exported with --overlay and pass-through args"
> "$INVOCATIONS_FILE"
OUT10="$(run_grokgod run --overlay "$EXPLICIT_DIR/my-custom-overlay.toml" --prompt "test 10" -- --backend remote --model grok-3)"
echo "$OUT10" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 10 ($OUT10)"; exit 1; }

grep -q "GROK_CONFIG_PATH=$EXPLICIT_DIR/my-custom-overlay.toml" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH not set correctly in Test 10"; cat "$INVOCATIONS_FILE"; exit 1; }
grep -q "ARGS:--backend remote --model grok-3 -p test 10" "$INVOCATIONS_FILE" || { echo "FAIL: Target binary args incorrect in Test 10"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 10"

# ─────────────────────────────────────────────────────────
# Test 11: No pass-through regression guard (argv exactly as before)
# ─────────────────────────────────────────────────────────
echo "Test 11: No pass-through regression guard"
> "$INVOCATIONS_FILE"
OUT11="$(run_grokgod run --automation-root "$AUTO_DIR_1")"
echo "$OUT11" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 11 ($OUT11)"; exit 1; }
grep -q "ARGS:-p Perform weekly cache scan prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Target binary args incorrect in Test 11"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 11"

# ─────────────────────────────────────────────────────────
# Test 12: Bare trailing '--' (no args) is identical to no '--'
# ─────────────────────────────────────────────────────────
echo "Test 12: Bare trailing '--' without args"
> "$INVOCATIONS_FILE"
OUT12="$(run_grokgod run --automation-root "$AUTO_DIR_1" --)"
echo "$OUT12" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: Fake bin was not called in Test 12 ($OUT12)"; exit 1; }
grep -q "GROK_CONFIG_PATH=$AUTO_DIR_1/grok-overlay.toml" "$INVOCATIONS_FILE" || { echo "FAIL: GROK_CONFIG_PATH not set correctly in Test 12"; cat "$INVOCATIONS_FILE"; exit 1; }
grep -q "ARGS:-p Perform weekly cache scan prompt" "$INVOCATIONS_FILE" || { echo "FAIL: Target binary args incorrect in Test 12"; cat "$INVOCATIONS_FILE"; exit 1; }
echo "PASS: Test 12"

# ─────────────────────────────────────────────────────────
# Test 13: --dry-run prints final argv including pass-through args
# ─────────────────────────────────────────────────────────
echo "Test 13: --dry-run prints argv including pass-through args"
> "$INVOCATIONS_FILE"
OUT13="$(run_grokgod run --automation-root "$AUTO_DIR_1" --dry-run -- --always-approve --cwd "$TMP_DIR/custom_cwd")"
echo "$OUT13" | grep -q "GROK_CONFIG_PATH=$AUTO_DIR_1/grok-overlay.toml" || { echo "FAIL: dry-run missing GROK_CONFIG_PATH ($OUT13)"; exit 1; }
echo "$OUT13" | grep -q "EXEC: .* --always-approve --cwd $TMP_DIR/custom_cwd -p Perform weekly cache scan prompt" || { echo "FAIL: dry-run missing pass-through args in EXEC line ($OUT13)"; exit 1; }

if [ -s "$INVOCATIONS_FILE" ]; then
  echo "FAIL: Fake bin was invoked during --dry-run in Test 13!"; cat "$INVOCATIONS_FILE"; exit 1
fi
echo "PASS: Test 13"

echo "=== All grokgod run tests passed successfully! ==="
