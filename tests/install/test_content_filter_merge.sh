#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"

echo "=== Running content-filter config merge tests ==="

[ -f "$INSTALL_SCRIPT" ] || { echo "FAIL: install.sh missing" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

sed -n '/^maybe_merge_content_filter_config() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/fn.sh"
grep -q '^maybe_merge_content_filter_config() {' "$TMP/fn.sh" || {
  echo "FAIL: could not extract maybe_merge_content_filter_config" >&2
  exit 1
}
sed -n '/^resolve_write_target() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/helpers.sh"
sed -n '/^rewrite_stage() {/,/^}/p' "$INSTALL_SCRIPT" >> "$TMP/helpers.sh"
sed -n '/^rewrite_commit() {/,/^}/p' "$INSTALL_SCRIPT" >> "$TMP/helpers.sh"

run_merge() {
  name="$1"
  home="$TMP/$name"
  mkdir -p "$home"
  dry="${2:-0}"
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
  printf '\nmaybe_merge_content_filter_config\n' >> "$TMP/run-$name.sh"
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

# 1. Missing config.toml seed
run_merge missing >/dev/null
cat > "$TMP/expected-missing.toml" <<'EOF'
[compat.content_filter]
action = "retry_then_error"
max_retries = 3
EOF
assert_file_eq "$TMP/missing/config.toml" "$TMP/expected-missing.toml" "missing config.toml seed"
echo "PASS: missing config.toml writes [compat.content_filter] retry_then_error + max_retries=3"

# 2. Existing action preserved, max_retries added
mkdir -p "$TMP/custom"
cat > "$TMP/custom/config.toml" <<'EOF'
[compat.content_filter]
action = "notice"
EOF
run_merge custom >/dev/null
cat > "$TMP/expected-custom.toml" <<'EOF'
[compat.content_filter]
action = "notice"
max_retries = 3
EOF
assert_file_eq "$TMP/custom/config.toml" "$TMP/expected-custom.toml" "custom action preserved and max_retries added"
echo "PASS: existing action is preserved and max_retries=3 added"

# 3. Existing max_retries preserved, action added (max-only)
mkdir -p "$TMP/max_only"
cat > "$TMP/max_only/config.toml" <<'EOF'
[compat.content_filter]
max_retries = 5
EOF
run_merge max_only >/dev/null
cat > "$TMP/expected-max-only.toml" <<'EOF'
[compat.content_filter]
max_retries = 5
action = "retry_then_error"
EOF
assert_file_eq "$TMP/max_only/config.toml" "$TMP/expected-max-only.toml" "max-only preserved and action added"
echo "PASS: existing max_retries preserved and action added"

# 4. Empty section merged
mkdir -p "$TMP/empty_section"
cat > "$TMP/empty_section/config.toml" <<'EOF'
[compat.content_filter]
EOF
run_merge empty_section >/dev/null
cat > "$TMP/expected-empty.toml" <<'EOF'
[compat.content_filter]
action = "retry_then_error"
max_retries = 3
EOF
assert_file_eq "$TMP/empty_section/config.toml" "$TMP/expected-empty.toml" "empty section merged"
echo "PASS: empty [compat.content_filter] gets retry_then_error + max_retries=3"

# 5. Both set preserved unchanged
mkdir -p "$TMP/both_set"
cat > "$TMP/both_set/config.toml" <<'EOF'
[compat.content_filter]
action = "error"
max_retries = 1
EOF
cp "$TMP/both_set/config.toml" "$TMP/both_set.before"
run_merge both_set >/dev/null
assert_file_eq "$TMP/both_set/config.toml" "$TMP/both_set.before" "both set preserved"
echo "PASS: existing action and max_retries left unchanged"

# 6. Middle section with sections before and after
mkdir -p "$TMP/middle_sec"
cat > "$TMP/middle_sec/config.toml" <<'EOF'
[before_section]
key1 = "val1"

[compat.content_filter]

[after_section]
key2 = "val2"
EOF
run_merge middle_sec >/dev/null
cat > "$TMP/expected-middle.toml" <<'EOF'
[before_section]
key1 = "val1"

[compat.content_filter]

action = "retry_then_error"
max_retries = 3
[after_section]
key2 = "val2"
EOF
assert_file_eq "$TMP/middle_sec/config.toml" "$TMP/expected-middle.toml" "middle section merged correctly"
echo "PASS: middle section correctly merged with adjacent sections preserved"

# 7. Unrelated action and max_retries in other sections
mkdir -p "$TMP/unrelated"
cat > "$TMP/unrelated/config.toml" <<'EOF'
[other_sec]
action = "unrelated_action"
max_retries = 99

[compat.content_filter]

[tail_sec]
action = "tail_action"
EOF
run_merge unrelated >/dev/null
cat > "$TMP/expected-unrelated.toml" <<'EOF'
[other_sec]
action = "unrelated_action"
max_retries = 99

[compat.content_filter]

action = "retry_then_error"
max_retries = 3
[tail_sec]
action = "tail_action"
EOF
assert_file_eq "$TMP/unrelated/config.toml" "$TMP/expected-unrelated.toml" "unrelated keys in other sections ignored"
echo "PASS: unrelated action/max_retries in other sections do not spoof detection"

# 8. Idempotence test
mkdir -p "$TMP/idempotent"
cat > "$TMP/idempotent/config.toml" <<'EOF'
[before]
a = 1

[compat.content_filter]
action = "notice"
EOF
run_merge idempotent >/dev/null
cp "$TMP/idempotent/config.toml" "$TMP/idempotent.once"
run_merge idempotent >/dev/null
assert_file_eq "$TMP/idempotent/config.toml" "$TMP/idempotent.once" "merge is idempotent"
echo "PASS: merge is fully idempotent across multiple passes"

# 9. Dry-run test
mkdir -p "$TMP/dry_run"
cat > "$TMP/dry_run/config.toml" <<'EOF'
[compat.content_filter]
EOF
cp "$TMP/dry_run/config.toml" "$TMP/dry_run.before"
out="$(run_merge dry_run 1)"
assert_file_eq "$TMP/dry_run/config.toml" "$TMP/dry_run.before" "dry-run does not modify config"
echo "$out" | grep -q 'DRY Would merge \[compat\.content_filter\] defaults into' || {
  echo "FAIL: dry-run log message missing" >&2
  exit 1
}
echo "PASS: dry-run does not write and logs expected message"

echo "=== content-filter config merge tests passed ==="
