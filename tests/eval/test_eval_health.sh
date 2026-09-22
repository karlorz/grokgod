#!/bin/sh
set -eu

unset GROK_CONFIG_PATH GROK_CONFIG ORCA_WORKTREE_ID ORCA_WORKSPACE_ID CLIAPI_API_KEY NEW_API_KEY || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HEALTH_SRC="$REPO_ROOT/src/grokgod-eval-health.sh"
EVAL_SRC="$REPO_ROOT/src/grokgod-eval.sh"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"
PROBE="$REPO_ROOT/examples/eval-home/assets/vision-probe.jpg"

[ -f "$HEALTH_SRC" ] || { echo "FAIL: grokgod-eval-health.sh missing" >&2; exit 1; }
[ -f "$PROBE" ] || { echo "FAIL: vision probe image missing" >&2; exit 1; }
sh -n "$HEALTH_SRC" || { echo "FAIL: health script syntax" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

TEST_HOME="$TMP_DIR/home"
mkdir -p "$TEST_HOME/.grok"
cat << 'EOF' > "$TEST_HOME/.grok/config.toml"
[model.deepseek-v4-flash]
model = "deepseek-v4.1-flash"
api_key = "sk-test-fixture"

[model.kimi-k3]
api_key = "sk-test-kimi"

[model.flash-max]
api_key = "sk-test-flash"

[model.other]
api_key = "sk-other"
EOF

run_health() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_HOME/.grokgod" \
  GROKGOD_SRC="$REPO_ROOT" \
  sh "$HEALTH_SRC" "$@"
}

echo "=== grokgod eval-health tests ==="

echo "Test 1: dry-run defaults to deepseek-v4-flash, auth from config"
OUT1="$(run_health --dry-run)"
echo "$OUT1" | grep -q "MODEL=deepseek-v4-flash" || { echo "FAIL: default model ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q "AUTH_SOURCE=config" || { echo "FAIL: auth source ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q "PROBE_IMAGE=" || { echo "FAIL: probe path missing ($OUT1)"; exit 1; }
echo "$OUT1" | grep -qi "sk-test" && { echo "FAIL: dry-run leaked key material"; exit 1; }
echo "PASS: Test 1"

echo "Test 2: environment key wins over config"
OUT2="$(NEW_API_KEY=test-env run_health --dry-run)"
echo "$OUT2" | grep -q "AUTH_SOURCE=env" || { echo "FAIL: env auth not preferred ($OUT2)"; exit 1; }
echo "PASS: Test 2"

echo "Test 3: no env and no config fails closed"
EMPTY_HOME="$TMP_DIR/empty-home"
mkdir -p "$EMPTY_HOME"
set +e
ERR3="$(HOME="$EMPTY_HOME" GROKGOD_SRC="$REPO_ROOT" sh "$HEALTH_SRC" --dry-run 2>&1)"
ST3=$?
set -eu
[ "$ST3" -eq 0 ] && { echo "FAIL: expected auth failure, got success ($ERR3)"; exit 1; }
echo "$ERR3" | grep -q "api_key" || { echo "FAIL: missing auth message ($ERR3)"; exit 1; }
echo "PASS: Test 3"

echo "Test 4: positional and --model override"
OUT4="$(run_health kimi-k3 --dry-run)"
echo "$OUT4" | grep -q "MODEL=kimi-k3" || { echo "FAIL: positional model ($OUT4)"; exit 1; }
OUT4B="$(run_health --model flash-max --dry-run)"
echo "$OUT4B" | grep -q "MODEL=flash-max" || { echo "FAIL: --model flag ($OUT4B)"; exit 1; }
echo "PASS: Test 4"

echo "Test 5: missing sibling eval wrapper fails"
LONE_DIR="$TMP_DIR/lone"
mkdir -p "$LONE_DIR"
cp "$HEALTH_SRC" "$LONE_DIR/"
set +e
ERR5="$(HOME="$TEST_HOME" NEW_API_KEY=test sh "$LONE_DIR/grokgod-eval-health.sh" --dry-run 2>&1)"
ST5=$?
set -eu
[ "$ST5" -eq 0 ] && { echo "FAIL: expected wrapper-missing failure ($ERR5)"; exit 1; }
echo "$ERR5" | grep -q "eval wrapper missing" || { echo "FAIL: wrapper message ($ERR5)"; exit 1; }
echo "PASS: Test 5"

echo "Test 6: eval wrapper seeds the probe image"
TEST_GROKGOD_HOME="$TMP_DIR/seed-home/.grokgod"
mkdir -p "$TEST_GROKGOD_HOME/bin"
cat << 'EOF' > "$TEST_GROKGOD_HOME/bin/grok"
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_GROKGOD_HOME/bin/grok"
HOME="$TMP_DIR/seed-home" \
GROKGOD_HOME="$TEST_GROKGOD_HOME" \
GROKGOD_SRC="$REPO_ROOT" \
GROKGOD_BIN="$TEST_GROKGOD_HOME/bin/grok" \
  sh "$EVAL_SRC" --dry-run >/dev/null
[ -f "$TEST_GROKGOD_HOME/eval-home/assets/vision-probe.jpg" ] || { echo "FAIL: probe image not seeded"; exit 1; }
echo "PASS: Test 6"

echo "Test 7: shim dispatches grokgod eval-health"
STUB_SRC="$TMP_DIR/stub-src"
mkdir -p "$STUB_SRC/src"
cat << 'EOF' > "$STUB_SRC/src/grokgod-eval-health.sh"
#!/bin/sh
echo "HEALTH_STUB:$*"
exit 0
EOF
chmod +x "$STUB_SRC/src/grokgod-eval-health.sh"
SHIM_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_HOME/.grokgod" \
  GROKGOD_SRC="$STUB_SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent" \
  sh "$SHIM_SRC" eval-health --dry-run
)"
echo "$SHIM_OUT" | grep -q "HEALTH_STUB:--dry-run" || { echo "FAIL: shim eval-health dispatch ($SHIM_OUT)"; exit 1; }
echo "PASS: Test 7"

echo "Test 8: vision probe result is persisted redacted and without secrets"
TEST8_HOME="$TMP_DIR/health-home"
TEST8_GROKGOD_HOME="$TEST8_HOME/.grokgod"
mkdir -p "$TEST8_GROKGOD_HOME/bin"
cat << 'EOF' > "$TEST8_GROKGOD_HOME/bin/grok"
#!/bin/sh
exit 0
EOF
chmod +x "$TEST8_GROKGOD_HOME/bin/grok"
# Same seed path as Test 6: the eval wrapper seeds the probe image.
HOME="$TEST8_HOME" \
GROKGOD_HOME="$TEST8_GROKGOD_HOME" \
GROKGOD_SRC="$REPO_ROOT" \
GROKGOD_BIN="$TEST8_GROKGOD_HOME/bin/grok" \
  sh "$EVAL_SRC" --dry-run >/dev/null
cat << 'EOF' > "$TEST8_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo '{"text":"PONG agent label sk-should-redact","stopReason":"end_turn","sessionId":"sess-health-1"}'
exit 0
EOF
chmod +x "$TEST8_GROKGOD_HOME/bin/grok"
set +e
OUT8="$(
  HOME="$TEST8_HOME" \
  GROKGOD_HOME="$TEST8_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  GROKGOD_BIN="$TEST8_GROKGOD_HOME/bin/grok" \
  NEW_API_KEY=sk-env-should-redact \
    sh "$HEALTH_SRC" 2>"$TMP_DIR/test8.err"
)"
ST8=$?
set -eu
[ "$ST8" -eq 0 ] || { echo "FAIL: health exit $ST8 ($OUT8) ($(cat "$TMP_DIR/test8.err"))"; exit 1; }
echo "$OUT8" | grep -q "EVAL_HEALTH" || { echo "FAIL: missing EVAL_HEALTH line ($OUT8)"; exit 1; }
echo "$OUT8" | grep -q "end_turn" || { echo "FAIL: missing stopReason in stdout ($OUT8)"; exit 1; }
echo "$OUT8" | grep -E -q "sk-should-redact|sk-env-should-redact" && { echo "FAIL: stdout leaked key material"; exit 1; }
VISION_FILE="$TEST8_GROKGOD_HOME/eval-home/health/vision.json"
[ -f "$VISION_FILE" ] || { echo "FAIL: vision result not persisted at $VISION_FILE"; exit 1; }
grep -q '"stopReason": "end_turn"' "$VISION_FILE" || { echo "FAIL: stopReason not persisted ($(cat "$VISION_FILE"))"; exit 1; }
grep -q 'sess-health-1' "$VISION_FILE" || { echo "FAIL: sessionId not persisted ($(cat "$VISION_FILE"))"; exit 1; }
grep -q 'PONG' "$VISION_FILE" || { echo "FAIL: full text not persisted ($(cat "$VISION_FILE"))"; exit 1; }
grep -q 'agent' "$VISION_FILE" || { echo "FAIL: vision label not persisted ($(cat "$VISION_FILE"))"; exit 1; }
grep -E -q 'sk-should-redact|sk-env-should-redact' "$VISION_FILE" && { echo "FAIL: persisted file leaked key material"; exit 1; }
grep -q '\[REDACTED\]' "$VISION_FILE" || { echo "FAIL: expected redaction marker ($(cat "$VISION_FILE"))"; exit 1; }
ls "$TEST8_GROKGOD_HOME/eval-home/health/"vision-*.json >/dev/null 2>&1 || { echo "FAIL: timestamped sibling missing"; exit 1; }
echo "PASS: Test 8"

echo "Test 9: dry-run does not create the health file"
TEST9_HOME="$TMP_DIR/dryrun-home"
TEST9_GROKGOD_HOME="$TEST9_HOME/.grokgod"
mkdir -p "$TEST9_GROKGOD_HOME/bin"
cat << 'EOF' > "$TEST9_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "GROK_CALLED:$*" >&2
exit 0
EOF
chmod +x "$TEST9_GROKGOD_HOME/bin/grok"
HOME="$TEST9_HOME" \
GROKGOD_HOME="$TEST9_GROKGOD_HOME" \
GROKGOD_SRC="$REPO_ROOT" \
GROKGOD_BIN="$TEST9_GROKGOD_HOME/bin/grok" \
  sh "$EVAL_SRC" --dry-run >/dev/null
[ ! -e "$TEST9_GROKGOD_HOME/eval-home/health" ] || { echo "FAIL: health dir present before dry-run"; exit 1; }
set +e
OUT9="$(
  HOME="$TEST9_HOME" \
  GROKGOD_HOME="$TEST9_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  GROKGOD_BIN="$TEST9_GROKGOD_HOME/bin/grok" \
  NEW_API_KEY=sk-env-should-redact \
    sh "$HEALTH_SRC" --dry-run 2>&1
)"
ST9=$?
set -eu
[ "$ST9" -eq 0 ] || { echo "FAIL: dry-run exit $ST9 ($OUT9)"; exit 1; }
echo "$OUT9" | grep -q "MODEL=" || { echo "FAIL: dry-run output missing MODEL ($OUT9)"; exit 1; }
echo "$OUT9" | grep -q "GROK_CALLED" && { echo "FAIL: dry-run called grok"; exit 1; }
[ ! -e "$TEST9_GROKGOD_HOME/eval-home/health/vision.json" ] || { echo "FAIL: dry-run created the health file"; exit 1; }
echo "PASS: Test 9"

echo "Test 10: unwritable health dir exits 1 without secrets"
TEST10_HOME="$TMP_DIR/unwritable-home"
TEST10_GROKGOD_HOME="$TEST10_HOME/.grokgod"
mkdir -p "$TEST10_GROKGOD_HOME/bin"
cat << 'EOF' > "$TEST10_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo '{"text":"PONG agent label sk-should-redact","stopReason":"end_turn","sessionId":"sess-health-1"}'
exit 0
EOF
chmod +x "$TEST10_GROKGOD_HOME/bin/grok"
HOME="$TEST10_HOME" \
GROKGOD_HOME="$TEST10_GROKGOD_HOME" \
GROKGOD_SRC="$REPO_ROOT" \
GROKGOD_BIN="$TEST10_GROKGOD_HOME/bin/grok" \
  sh "$EVAL_SRC" --dry-run >/dev/null
# A regular file where the health directory must go makes the write fail.
: > "$TEST10_GROKGOD_HOME/eval-home/health"
set +e
ERR10="$(
  HOME="$TEST10_HOME" \
  GROKGOD_HOME="$TEST10_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  GROKGOD_BIN="$TEST10_GROKGOD_HOME/bin/grok" \
  NEW_API_KEY=sk-env-should-redact \
    sh "$HEALTH_SRC" 2>&1
)"
ST10=$?
set -eu
[ "$ST10" -eq 0 ] && { echo "FAIL: expected failure when the health dir is unwritable ($ERR10)"; exit 1; }
echo "$ERR10" | grep -q "cannot write vision result" || { echo "FAIL: missing write error ($ERR10)"; exit 1; }
echo "$ERR10" | grep -E -q "sk-should-redact|sk-env-should-redact" && { echo "FAIL: error path leaked key material"; exit 1; }
echo "PASS: Test 10"

echo "=== grokgod eval-health tests passed ==="
