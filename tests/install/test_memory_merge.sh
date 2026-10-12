#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"

echo "=== Running memory config merge tests ==="

[ -f "$INSTALL_SCRIPT" ] || { echo "FAIL: install.sh missing" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

sed -n '/^maybe_merge_memory_config() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/fn.sh"
grep -q '^maybe_merge_memory_config() {' "$TMP/fn.sh" || {
  echo "FAIL: could not extract maybe_merge_memory_config" >&2
  exit 1
}
sed -n '/^maybe_merge_memory_v2_config() {/,/^}/p' "$INSTALL_SCRIPT" >> "$TMP/fn.sh"
grep -q '^maybe_merge_memory_v2_config() {' "$TMP/fn.sh" || {
  echo "FAIL: could not extract maybe_merge_memory_v2_config" >&2
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
  printf '\nmaybe_merge_memory_config\nmaybe_merge_memory_v2_config\n' >> "$TMP/run-$name.sh"
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

# 1. Missing config.toml seeds both tables
run_merge missing >/dev/null
cat > "$TMP/expected-missing.toml" <<'EOF'
[memory]
enabled = false

[memory_v2]
enabled = false
EOF
assert_file_eq "$TMP/missing/config.toml" "$TMP/expected-missing.toml" "missing config.toml seeds both memory tables"
echo "PASS: missing config.toml writes [memory] and [memory_v2] enabled = false"

# 2. Empty [memory] gains enabled = false; [memory_v2] already set is untouched
mkdir -p "$TMP/empty_memory"
cat > "$TMP/empty_memory/config.toml" <<'EOF'
[memory]

[memory_v2]
enabled = true
EOF
run_merge empty_memory >/dev/null
cat > "$TMP/expected-empty-memory.toml" <<'EOF'
[memory]

enabled = false
[memory_v2]
enabled = true
EOF
assert_file_eq "$TMP/empty_memory/config.toml" "$TMP/expected-empty-memory.toml" "empty [memory] merged without touching [memory_v2]"
echo "PASS: empty [memory] gets enabled = false and an explicit [memory_v2] value is preserved"

# 3. Empty [memory_v2] gains enabled = false; [memory] already set is untouched
mkdir -p "$TMP/empty_memory_v2"
cat > "$TMP/empty_memory_v2/config.toml" <<'EOF'
[memory]
enabled = true

[memory_v2]
EOF
run_merge empty_memory_v2 >/dev/null
cat > "$TMP/expected-empty-memory-v2.toml" <<'EOF'
[memory]
enabled = true

[memory_v2]
enabled = false
EOF
assert_file_eq "$TMP/empty_memory_v2/config.toml" "$TMP/expected-empty-memory-v2.toml" "empty [memory_v2] merged without touching [memory]"
echo "PASS: empty [memory_v2] gets enabled = false and an explicit [memory] value is preserved"

# 4. Explicit enabled = true in both tables is preserved
mkdir -p "$TMP/both_true"
cat > "$TMP/both_true/config.toml" <<'EOF'
[memory]
enabled = true

[memory_v2]
enabled = true
EOF
cp "$TMP/both_true/config.toml" "$TMP/both_true.before"
run_merge both_true >/dev/null
assert_file_eq "$TMP/both_true/config.toml" "$TMP/both_true.before" "explicit enabled = true preserved"
echo "PASS: existing enabled = true in both memory tables is left unchanged"

# 5. Unrelated enabled keys in other sections do not spoof detection
mkdir -p "$TMP/unrelated"
cat > "$TMP/unrelated/config.toml" <<'EOF'
[other_sec]
enabled = true

[memory]

[memory_v2]

[tail_sec]
enabled = true
EOF
run_merge unrelated >/dev/null
cat > "$TMP/expected-unrelated.toml" <<'EOF'
[other_sec]
enabled = true

[memory]

enabled = false
[memory_v2]

enabled = false
[tail_sec]
enabled = true
EOF
assert_file_eq "$TMP/unrelated/config.toml" "$TMP/expected-unrelated.toml" "unrelated enabled keys ignored"
echo "PASS: unrelated enabled keys in other sections do not spoof detection"

# 6. Middle-section insert with sections before and after
mkdir -p "$TMP/middle_sec"
cat > "$TMP/middle_sec/config.toml" <<'EOF'
[before_section]
key1 = "val1"

[memory]

[after_section]
key2 = "val2"
EOF
run_merge middle_sec >/dev/null
cat > "$TMP/expected-middle.toml" <<'EOF'
[before_section]
key1 = "val1"

[memory]

enabled = false
[after_section]
key2 = "val2"

[memory_v2]
enabled = false
EOF
assert_file_eq "$TMP/middle_sec/config.toml" "$TMP/expected-middle.toml" "middle section merged correctly"
echo "PASS: middle section correctly merged with adjacent sections preserved"

# 7. Idempotence
mkdir -p "$TMP/idempotent"
cat > "$TMP/idempotent/config.toml" <<'EOF'
[before]
a = 1

[memory]
EOF
run_merge idempotent >/dev/null
cp "$TMP/idempotent/config.toml" "$TMP/idempotent.once"
run_merge idempotent >/dev/null
assert_file_eq "$TMP/idempotent/config.toml" "$TMP/idempotent.once" "merge is idempotent"
echo "PASS: merge is fully idempotent across multiple passes"

# 8. Dry-run writes nothing
mkdir -p "$TMP/dry_run"
cat > "$TMP/dry_run/config.toml" <<'EOF'
[memory]
EOF
cp "$TMP/dry_run/config.toml" "$TMP/dry_run.before"
out="$(run_merge dry_run 1)"
assert_file_eq "$TMP/dry_run/config.toml" "$TMP/dry_run.before" "dry-run does not modify config"
echo "$out" | grep -q 'DRY Would merge \[memory\] enabled = false into' || {
  echo "FAIL: dry-run log message for [memory] missing" >&2
  exit 1
}
echo "$out" | grep -q 'DRY Would merge \[memory_v2\] enabled = false into' || {
  echo "FAIL: dry-run log message for [memory_v2] missing" >&2
  exit 1
}
echo "PASS: dry-run does not write and logs expected messages"

# 9. Dry-run on a missing config.toml does not create the file
mkdir -p "$TMP/dry_missing"
run_merge dry_missing 1 >/dev/null
[ ! -e "$TMP/dry_missing/config.toml" ] || {
  echo "FAIL: dry-run created config.toml" >&2
  exit 1
}
echo "PASS: dry-run does not create a missing config.toml"

echo "=== memory config merge tests passed ==="
