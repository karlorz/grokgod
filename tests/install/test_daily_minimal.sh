#!/bin/sh
set -eu

# test_daily_minimal.sh: Static assertions for the Orca daily Minimal agent
# and its installation hook in install.sh. Does NOT invoke install.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DAILY_MINIMAL="$REPO_ROOT/examples/daily-minimal/minimal.md"
EVAL_MINIMAL="$REPO_ROOT/examples/eval-home/agents/minimal.md"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

frontmatter_list() {
  key="$1"
  file="$2"
  sed -n "/^$key:/,/^[^[:space:]]/p" "$file" | sed -n 's/^  - //p'
}

frontmatter_val() {
  key="$1"
  file="$2"
  awk -F': ' -v k="$key" '$1 == k { print $2; exit }' "$file" | tr -d '\r"'
}

echo "=== Running daily minimal tests ==="

# 1. examples/daily-minimal/minimal.md exists
[ -f "$DAILY_MINIMAL" ] || fail "examples/daily-minimal/minimal.md does not exist"

# 2. Daily minimal tools list includes read_file so search_replace can start
DAILY_TOOLS="$(frontmatter_list tools "$DAILY_MINIMAL")"
EXPECTED_DAILY_TOOLS=$(cat << 'EOF'
todo_write
read_file
write
search_replace
EOF
)
[ "$DAILY_TOOLS" = "$EXPECTED_DAILY_TOOLS" ] || fail "daily minimal tools mismatch: got $(printf '%s' "$DAILY_TOOLS" | tr '\n' ' ')"

# 3. Daily minimal permissionMode is acceptEdits
DAILY_PERM="$(frontmatter_val permissionMode "$DAILY_MINIMAL")"
[ "$DAILY_PERM" = "acceptEdits" ] || fail "daily minimal permissionMode is '$DAILY_PERM', expected 'acceptEdits'"

# 4. Daily minimal disallowedTools keeps shell and MCP off, and does not deny read_file
DAILY_DISALLOWED="$(frontmatter_list disallowedTools "$DAILY_MINIMAL")"
for tool in search_tool use_tool Bash run_terminal_cmd; do
  printf '%s\n' "$DAILY_DISALLOWED" | grep -qx "$tool" || fail "daily minimal disallowedTools missing $tool"
done
if printf '%s\n' "$DAILY_DISALLOWED" | grep -qx read_file; then
  fail "daily minimal must allow read_file so search_replace can start"
fi

# 5. examples/eval-home/agents/minimal.md exists
[ -f "$EVAL_MINIMAL" ] || fail "examples/eval-home/agents/minimal.md does not exist"

# 6. Eval template tools list is exactly todo_write
EVAL_TOOLS="$(frontmatter_list tools "$EVAL_MINIMAL")"
[ "$EVAL_TOOLS" = "todo_write" ] || fail "eval minimal tools mismatch: got $(printf '%s' "$EVAL_TOOLS" | tr '\n' ' ')"

# 7. Eval template permissionMode is dontAsk
EVAL_PERM="$(frontmatter_val permissionMode "$EVAL_MINIMAL")"
[ "$EVAL_PERM" = "dontAsk" ] || fail "eval minimal permissionMode is '$EVAL_PERM', expected 'dontAsk'"

# 8. Eval template tools list does not contain write or search_replace
for unwanted in write search_replace; do
  if printf '%s\n' "$EVAL_TOOLS" | grep -qx "$unwanted"; then
    fail "eval minimal tools unexpectedly contains $unwanted"
  fi
done

# 9. install.sh contains the string examples/daily-minimal/minimal.md
[ -f "$INSTALL_SCRIPT" ] || fail "install.sh not found at $INSTALL_SCRIPT"
grep -q "examples/daily-minimal/minimal.md" "$INSTALL_SCRIPT" || fail "install.sh does not contain 'examples/daily-minimal/minimal.md'"

# 10. install.sh copies the daily template onto $GROK_HOME/agents/minimal.md
grep -q 'target="\$GROK_HOME/agents/minimal.md"' "$INSTALL_SCRIPT" || fail "install.sh does not set the daily agent target"
grep -q 'cp "\$template" "\$target"' "$INSTALL_SCRIPT" || fail "install.sh does not copy the daily template onto that target"

echo "PASS: daily minimal assertions verified"
