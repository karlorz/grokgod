#!/bin/sh
set -eu

# Extract maybe_merge_ask_user_question_config from install.sh and cover merge cases
# without running the cargo-heavy installer.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"

echo "=== Running ask_user_question config merge tests ==="

[ -f "$INSTALL_SCRIPT" ] || { echo "FAIL: install.sh missing" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

sed -n '/^maybe_merge_ask_user_question_config() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/fn.sh"
grep -q '^maybe_merge_ask_user_question_config() {' "$TMP/fn.sh" || {
  echo "FAIL: could not extract maybe_merge_ask_user_question_config" >&2
  exit 1
}
tail -n 1 "$TMP/fn.sh" | grep -qx '}' || {
  echo "FAIL: extracted function is not closed" >&2
  exit 1
}

sed -n '/^resolve_write_target() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/helpers.sh"
sed -n '/^rewrite_stage() {/,/^}/p' "$INSTALL_SCRIPT" >> "$TMP/helpers.sh"
sed -n '/^rewrite_commit() {/,/^}/p' "$INSTALL_SCRIPT" >> "$TMP/helpers.sh"
for fn_name in resolve_write_target rewrite_stage rewrite_commit; do
  grep -q "^${fn_name}() {" "$TMP/helpers.sh" || {
    echo "FAIL: could not extract ${fn_name} from install.sh" >&2
    exit 1
  }
done

run_merge() {
  name="$1"
  dry="${2:-0}"
  home="$TMP/$name"
  mkdir -p "$home"
  cat > "$TMP/run-$name.sh" <<EOF
#!/bin/sh
set -eu
DRY_RUN=$dry
GROK_HOME="$home"
TX_ACTIVE=0
log_info() { printf 'INFO %s\n' "\$1"; }
log_dry() { printf 'DRY %s\n' "\$1"; }
log_err() { printf 'ERR %s\n' "\$1" >&2; }
tx_note() { return 0; }
EOF
  cat "$TMP/helpers.sh" >> "$TMP/run-$name.sh"
  cat "$TMP/fn.sh" >> "$TMP/run-$name.sh"
  printf '\nmaybe_merge_ask_user_question_config\n' >> "$TMP/run-$name.sh"
  sh "$TMP/run-$name.sh"
}

assert_file_eq() {
  got="$1"
  expected="$2"
  msg="$3"
  if ! cmp -s "$got" "$expected"; then
    echo "FAIL: $msg" >&2
    echo "--- got ---" >&2
    cat "$got" >&2
    echo "--- expected ---" >&2
    cat "$expected" >&2
    exit 1
  fi
}

assert_unchanged() {
  name="$1"
  before="$TMP/$name/config.toml"
  cp "$before" "$TMP/$name.before"
  run_merge "$name" 0 >/dev/null
  assert_file_eq "$before" "$TMP/$name.before" "$name: config.toml changed"
}

# 1. missing config.toml -> writes full stanza
run_merge missing 0 >/dev/null
cat > "$TMP/expected-missing.toml" <<'EOF'
[toolset.ask_user_question]
timeout_enabled = true
timeout_secs = 120
timeout_action = "recommended"
timeout_reset_on_activity = true
EOF
assert_file_eq "$TMP/missing/config.toml" "$TMP/expected-missing.toml" "missing config.toml seed"
echo "PASS: missing config.toml writes full ask_user_question stanza"

# 2. existing timeout_secs = 30 stays, other missing keys get merged
mkdir -p "$TMP/custom_secs"
cat > "$TMP/custom_secs/config.toml" <<'EOF'
[models]
default = "grok-4.6"

[toolset.ask_user_question]
timeout_secs = 30
EOF
run_merge custom_secs 0 >/dev/null
cat > "$TMP/expected-custom-secs.toml" <<'EOF'
[models]
default = "grok-4.6"

[toolset.ask_user_question]
timeout_secs = 30
timeout_enabled = true
timeout_action = "recommended"
timeout_reset_on_activity = true
EOF
assert_file_eq "$TMP/custom_secs/config.toml" "$TMP/expected-custom-secs.toml" "custom timeout_secs preserved"
echo "PASS: custom timeout_secs is preserved while missing keys are added"

# 3. missing timeout_action gets recommended
mkdir -p "$TMP/missing_action"
cat > "$TMP/missing_action/config.toml" <<'EOF'
[toolset.ask_user_question]
timeout_enabled = true
timeout_secs = 120
timeout_reset_on_activity = true
EOF
run_merge missing_action 0 >/dev/null
cat > "$TMP/expected-missing-action.toml" <<'EOF'
[toolset.ask_user_question]
timeout_enabled = true
timeout_secs = 120
timeout_reset_on_activity = true
timeout_action = "recommended"
EOF
assert_file_eq "$TMP/missing_action/config.toml" "$TMP/expected-missing-action.toml" "missing timeout_action added"
echo "PASS: missing timeout_action gets recommended"

# 4. all four present is a no-op
mkdir -p "$TMP/all_present"
cat > "$TMP/all_present/config.toml" <<'EOF'
[toolset.ask_user_question]
timeout_enabled = false
timeout_secs = 60
timeout_action = "decline"
timeout_reset_on_activity = false
EOF
assert_unchanged all_present
echo "PASS: all four keys present is a no-op"

# 5. section between other sections merges correctly without corrupting next section
mkdir -p "$TMP/middle_section"
cat > "$TMP/middle_section/config.toml" <<'EOF'
[models]
default = "grok-4.6"

[toolset.ask_user_question]
timeout_secs = 45

[ui.status_line]
type = "builtin"
EOF
run_merge middle_section 0 >/dev/null
cat > "$TMP/expected-middle-section.toml" <<'EOF'
[models]
default = "grok-4.6"

[toolset.ask_user_question]
timeout_secs = 45
timeout_enabled = true
timeout_action = "recommended"
timeout_reset_on_activity = true

[ui.status_line]
type = "builtin"
EOF
assert_file_eq "$TMP/middle_section/config.toml" "$TMP/expected-middle-section.toml" "middle section merge"
echo "PASS: middle section merges without corrupting subsequent sections"

echo "=== ask_user_question config merge tests passed ==="
