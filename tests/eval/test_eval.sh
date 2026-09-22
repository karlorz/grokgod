#!/bin/sh
set -eu

unset GROK_CONFIG_PATH GROK_CONFIG ORCA_WORKTREE_ID ORCA_WORKSPACE_ID CLIAPI_API_KEY NEW_API_KEY || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVAL_SRC="$REPO_ROOT/src/grokgod-eval.sh"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

[ -f "$EVAL_SRC" ] || { echo "FAIL: grokgod-eval.sh missing" >&2; exit 1; }
[ -f "$REPO_ROOT/examples/eval-home/config.toml" ] || { echo "FAIL: eval-home template missing" >&2; exit 1; }
[ -f "$REPO_ROOT/examples/eval-home/agents/minimal.md" ] || { echo "FAIL: minimal agent missing" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
mkdir -p "$TEST_GROKGOD_HOME/bin"

FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"
INVOCATIONS="$TMP_DIR/invocations.txt"
touch "$INVOCATIONS"

cat << 'EOF' > "$FAKE_BIN"
#!/bin/sh
set -eu
echo "--- INVOCATION ---" >> "$TMP_DIR/invocations.txt"
echo "GROK_HOME=${GROK_HOME:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "GROK_MEMORY=${GROK_MEMORY:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "GROK_SUBAGENTS=${GROK_SUBAGENTS:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "GROK_CONFIG_PATH=${GROK_CONFIG_PATH:-}" >> "$TMP_DIR/invocations.txt"
echo "GROK_DISABLE_AUTOUPDATER=${GROK_DISABLE_AUTOUPDATER:-NOT_SET}" >> "$TMP_DIR/invocations.txt"
echo "ARGS:$*" >> "$TMP_DIR/invocations.txt"
echo "FAKE_BIN_SUCCESS"
EOF
chmod +x "$FAKE_BIN"

run_eval() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$REPO_ROOT" \
  GROKGOD_BIN="$FAKE_BIN" \
  TMP_DIR="$TMP_DIR" \
  sh "$EVAL_SRC" "$@"
}

echo "=== grokgod eval tests ==="

echo "Test 1: dry-run seeds home and does not exec grok"
> "$INVOCATIONS"
OUT1="$(run_eval --dry-run)"
echo "$OUT1" | grep -q "GROK_HOME=$TEST_GROKGOD_HOME/eval-home" || { echo "FAIL: dry-run GROK_HOME ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q "GROK_MEMORY=0" || { echo "FAIL: dry-run GROK_MEMORY ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q -- "--agent minimal" || { echo "FAIL: dry-run missing agent ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q -- "--no-memory" || { echo "FAIL: dry-run missing --no-memory ($OUT1)"; exit 1; }
echo "$OUT1" | grep -q -- "-m deepseek-v4-flash" || { echo "FAIL: dry-run missing default model ($OUT1)"; exit 1; }
[ ! -s "$INVOCATIONS" ] || { echo "FAIL: dry-run executed grok"; cat "$INVOCATIONS"; exit 1; }
[ -f "$TEST_GROKGOD_HOME/eval-home/config.toml" ] || { echo "FAIL: eval-home config not seeded"; exit 1; }
[ -f "$TEST_GROKGOD_HOME/eval-home/agents/minimal.md" ] || { echo "FAIL: eval agent not seeded"; exit 1; }
grep -Eiq '(^|[[:space:]])api_key[[:space:]]*=' "$TEST_GROKGOD_HOME/eval-home/config.toml" && { echo "FAIL: eval config contains api_key assignment"; exit 1; }
echo "PASS: Test 1"

echo "Test 2: missing API key fails closed"
set +e
ERR2="$(run_eval 2>&1)"
ST2=$?
set -eu
if [ "$ST2" -eq 0 ]; then
  echo "FAIL: expected auth failure, got success ($ERR2)"; exit 1
fi
echo "$ERR2" | grep -q "CLIAPI_API_KEY or NEW_API_KEY" || { echo "FAIL: missing key message ($ERR2)"; exit 1; }
echo "PASS: Test 2"

echo "Test 3: exec with NEW_API_KEY and isolation env"
> "$INVOCATIONS"
OUT3="$(NEW_API_KEY=test-key run_eval -- --verbatim -p hello)"
echo "$OUT3" | grep -q "FAKE_BIN_SUCCESS" || { echo "FAIL: grok not exec'd ($OUT3)"; exit 1; }
grep -q "GROK_HOME=$TEST_GROKGOD_HOME/eval-home" "$INVOCATIONS" || { echo "FAIL: GROK_HOME not set"; cat "$INVOCATIONS"; exit 1; }
grep -q "GROK_MEMORY=0" "$INVOCATIONS" || { echo "FAIL: GROK_MEMORY not 0"; cat "$INVOCATIONS"; exit 1; }
grep -q "GROK_SUBAGENTS=0" "$INVOCATIONS" || { echo "FAIL: GROK_SUBAGENTS not 0"; cat "$INVOCATIONS"; exit 1; }
grep "GROK_CONFIG_PATH=" "$INVOCATIONS" | grep -qv "GROK_CONFIG_PATH=$" && { echo "FAIL: GROK_CONFIG_PATH leaked"; cat "$INVOCATIONS"; exit 1; }
grep -q -- "--agent minimal" "$INVOCATIONS" || { echo "FAIL: agent flag missing"; cat "$INVOCATIONS"; exit 1; }
grep -q -- "--sandbox read-only" "$INVOCATIONS" || { echo "FAIL: sandbox missing"; cat "$INVOCATIONS"; exit 1; }
grep -q -- "--verbatim -p hello" "$INVOCATIONS" || { echo "FAIL: extra args lost"; cat "$INVOCATIONS"; exit 1; }
echo "PASS: Test 3"

echo "Test 4: caller -m is not overridden"
> "$INVOCATIONS"
NEW_API_KEY=test-key run_eval -- -m flash-max -p hi >/dev/null
if grep "ARGS:" "$INVOCATIONS" | grep -q "deepseek-v4-flash"; then
  echo "FAIL: default model added despite -m"; cat "$INVOCATIONS"; exit 1
fi
grep -q -- "-m flash-max" "$INVOCATIONS" || { echo "FAIL: caller -m lost"; cat "$INVOCATIONS"; exit 1; }
echo "PASS: Test 4"

echo "Test 5: --reset restores template after local edit"
echo "MUTATED" > "$TEST_GROKGOD_HOME/eval-home/config.toml"
echo "stale" > "$TEST_GROKGOD_HOME/eval-home/agents/deepseek-eval.md"
NEW_API_KEY=test-key run_eval --reset --dry-run >/dev/null
grep -q "MUTATED" "$TEST_GROKGOD_HOME/eval-home/config.toml" && { echo "FAIL: --reset did not replace config"; exit 1; }
grep -q "deepseek-v4-flash" "$TEST_GROKGOD_HOME/eval-home/config.toml" || { echo "FAIL: --reset did not restore template"; exit 1; }
[ -f "$TEST_GROKGOD_HOME/eval-home/agents/deepseek-eval.md" ] && { echo "FAIL: --reset left stale deepseek-eval agent"; exit 1; }
[ -f "$TEST_GROKGOD_HOME/eval-home/agents/minimal.md" ] || { echo "FAIL: --reset missing minimal agent"; exit 1; }
echo "PASS: Test 5"

echo "Test 6: shim dispatches grokgod eval"
mkdir -p "$TEST_GROKGOD_HOME"
EVAL_STUB="$TMP_DIR/eval-stub.sh"
cat << 'EOF' > "$EVAL_STUB"
#!/bin/sh
echo "EVAL_STUB:$*"
exit 0
EOF
chmod +x "$EVAL_STUB"
# Point GROKGOD_SRC at a stub tree
STUB_SRC="$TMP_DIR/stub-src"
mkdir -p "$STUB_SRC/src"
cp "$EVAL_STUB" "$STUB_SRC/src/grokgod-eval.sh"
SHIM_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$STUB_SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent" \
  sh "$SHIM_SRC" eval --dry-run --model x
)"
echo "$SHIM_OUT" | grep -q "EVAL_STUB:--dry-run --model x" || { echo "FAIL: shim eval dispatch ($SHIM_OUT)"; exit 1; }
echo "PASS: Test 6"

echo "Test 7: minimal agent denies search_tool and use_tool"
MINIMAL_TEMPLATE="$REPO_ROOT/examples/eval-home/agents/minimal.md"
MINIMAL_SEEDED="$TEST_GROKGOD_HOME/eval-home/agents/minimal.md"
frontmatter_list() {
  sed -n "/^$1:/,/^[^[:space:]]/p" "$2" | sed -n 's/^  - //p'
}
[ -f "$MINIMAL_SEEDED" ] || { echo "FAIL: seeded minimal agent missing before dry-run"; exit 1; }
run_eval --dry-run >/dev/null
TOOLS_ENTRIES="$(frontmatter_list tools "$MINIMAL_TEMPLATE")"
[ "$TOOLS_ENTRIES" = "todo_write" ] || { echo "FAIL: minimal tools is not todo_write only ($TOOLS_ENTRIES)"; exit 1; }
TEMPLATE_DENY="$(frontmatter_list disallowedTools "$MINIMAL_TEMPLATE")"
for denied_tool in search_tool use_tool; do
  printf '%s\n' "$TEMPLATE_DENY" | grep -qx "$denied_tool" || { echo "FAIL: minimal disallowedTools missing $denied_tool"; exit 1; }
done
SEEDED_DENY="$(frontmatter_list disallowedTools "$MINIMAL_SEEDED")"
[ -n "$SEEDED_DENY" ] || { echo "FAIL: seeded minimal has no disallowedTools"; exit 1; }
[ "$SEEDED_DENY" = "$TEMPLATE_DENY" ] || { echo "FAIL: seeded minimal disallowedTools differs from template"; exit 1; }
echo "PASS: Test 7"

echo "=== grokgod eval tests passed ==="
