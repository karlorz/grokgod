#!/bin/sh
set -eu

# Extract maybe_merge_status_line_config from install.sh and cover merge cases
# without running the cargo-heavy installer.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"

echo "=== Running status-line config merge tests ==="

[ -f "$INSTALL_SCRIPT" ] || { echo "FAIL: install.sh missing" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

sed -n '/^maybe_merge_status_line_config() {/,/^}/p' "$INSTALL_SCRIPT" > "$TMP/fn.sh"
grep -q '^maybe_merge_status_line_config() {' "$TMP/fn.sh" || {
  echo "FAIL: could not extract maybe_merge_status_line_config" >&2
  exit 1
}
tail -n 1 "$TMP/fn.sh" | grep -qx '}' || {
  echo "FAIL: extracted function is not closed" >&2
  exit 1
}

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
log_info() { printf 'INFO %s\n' "\$1"; }
log_dry() { printf 'DRY %s\n' "\$1"; }
EOF
  cat "$TMP/fn.sh" >> "$TMP/run-$name.sh"
  printf '\nmaybe_merge_status_line_config\n' >> "$TMP/run-$name.sh"
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

# 1. missing config.toml → writes seeded stanza including compacts
run_merge missing 0 >/dev/null
cat > "$TMP/expected-missing.toml" <<'EOF'
[ui.status_line]
type = "builtin"
items = [
    "model",
    "turn-timer",
    "session-name",
    "compacts",
]
EOF
assert_file_eq "$TMP/missing/config.toml" "$TMP/expected-missing.toml" "missing config.toml seed"
echo "PASS: missing config.toml seeds builtin items including compacts"

# 2. existing builtin items without compacts → append, preserve order
mkdir -p "$TMP/append"
cat > "$TMP/append/config.toml" <<'EOF'
[models]
default = "grok-4.6"

[ui.status_line]
type = "builtin"
items = [
    "model",
    "turn-timer",
    "session-name",
]
EOF
run_merge append 0 >/dev/null
cat > "$TMP/expected-append.toml" <<'EOF'
[models]
default = "grok-4.6"

[ui.status_line]
type = "builtin"
items = [
    "model",
    "turn-timer",
    "session-name",
    "compacts",
]
EOF
assert_file_eq "$TMP/append/config.toml" "$TMP/expected-append.toml" "append compacts"
# order: model, turn-timer, session-name, then compacts
order="$(awk '
  /^[[:space:]]*\[ui\.status_line\]/ { s=1; next }
  s && /^[[:space:]]*\[/ { exit }
  s && /^[[:space:]]*items[[:space:]]*=/ { items=1 }
  items {
    while (match($0, /"[^"]+"/)) {
      printf "%s\n", substr($0, RSTART+1, RLENGTH-2)
      $0 = substr($0, RSTART+RLENGTH)
    }
    if ($0 ~ /\]/) exit
  }
' "$TMP/append/config.toml")"
printf '%s\n' "$order" > "$TMP/got-order"
cat > "$TMP/expected-order" <<'EOF'
model
turn-timer
session-name
compacts
EOF
assert_file_eq "$TMP/got-order" "$TMP/expected-order" "append item order"
echo "PASS: builtin items appends compacts and preserves order"

# 3. already has compacts → no duplicate
mkdir -p "$TMP/has"
cat > "$TMP/has/config.toml" <<'EOF'
[ui.status_line]
type = "builtin"
items = [
    "model",
    "compacts",
    "session-name",
]
EOF
assert_unchanged has
count="$(grep -c '"compacts"' "$TMP/has/config.toml")"
[ "$count" -eq 1 ] || { echo "FAIL: duplicate compacts ($count)" >&2; exit 1; }
echo "PASS: existing compacts is left without a duplicate"

# 4. type=disabled → unchanged
mkdir -p "$TMP/disabled"
cat > "$TMP/disabled/config.toml" <<'EOF'
[ui.status_line]
type = "disabled"
items = [
    "model",
    "turn-timer",
    "session-name",
]
EOF
assert_unchanged disabled
echo "PASS: type=disabled is unchanged"

# 5. type=command → unchanged
mkdir -p "$TMP/command"
cat > "$TMP/command/config.toml" <<'EOF'
[ui.status_line]
type = "command"
command = "~/.grok/statusline.sh"
items = ["model"]
EOF
assert_unchanged command
echo "PASS: type=command is unchanged"

# 6. builtin with no items key → unchanged
mkdir -p "$TMP/noitems"
cat > "$TMP/noitems/config.toml" <<'EOF'
[ui.status_line]
type = "builtin"
EOF
assert_unchanged noitems
echo "PASS: builtin with no items key is unchanged"

echo "=== Status-line config merge tests passed ==="
