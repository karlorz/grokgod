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
  cat > "$TMP/run-$name.sh" <<EOF
#!/bin/sh
set -eu
DRY_RUN=0
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

run_merge missing >/dev/null
cat > "$TMP/expected-missing.toml" <<'EOF'
[compat.content_filter]
action = "error"
EOF
assert_file_eq "$TMP/missing/config.toml" "$TMP/expected-missing.toml" "missing config.toml seed"
echo "PASS: missing config.toml writes [compat.content_filter] action=error"

mkdir -p "$TMP/custom"
cat > "$TMP/custom/config.toml" <<'EOF'
[compat.content_filter]
action = "notice"
EOF
cp "$TMP/custom/config.toml" "$TMP/custom.before"
run_merge custom >/dev/null
assert_file_eq "$TMP/custom/config.toml" "$TMP/custom.before" "custom action preserved"
echo "PASS: existing action is preserved"

mkdir -p "$TMP/empty_section"
cat > "$TMP/empty_section/config.toml" <<'EOF'
[compat.content_filter]
EOF
run_merge empty_section >/dev/null
cat > "$TMP/expected-empty.toml" <<'EOF'
[compat.content_filter]
action = "error"
EOF
assert_file_eq "$TMP/empty_section/config.toml" "$TMP/expected-empty.toml" "empty section merged"
echo "PASS: empty [compat.content_filter] gets action=error"

echo "=== content-filter config merge tests passed ==="
