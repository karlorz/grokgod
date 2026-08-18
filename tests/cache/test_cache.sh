#!/bin/sh
set -eu

# test_cache.sh: Standalone test suite for grokgod-cache.sh
# Tests reporting, clean confirmation, --auto-clean, mock df, and safety guards.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_SCRIPT="$REPO_ROOT/src/grokgod-cache.sh"

if [ ! -f "$CACHE_SCRIPT" ]; then
  echo "FAIL: grokgod-cache.sh not found at $CACHE_SCRIPT" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# Helper: setup sandbox
setup_sandbox() {
  NAME="$1"
  SANDBOX_DIR="$TMP_DIR/$NAME"
  mkdir -p "$SANDBOX_DIR/home" "$SANDBOX_DIR/home/.grokgod/target" "$SANDBOX_DIR/home/.cargo/registry" "$SANDBOX_DIR/home/.cargo/git"
  # Populate target dir with fake files
  echo "cargo target cache dummy build artifact" > "$SANDBOX_DIR/home/.grokgod/target/dummy_build.o"
  echo "registry cached crate" > "$SANDBOX_DIR/home/.cargo/registry/dummy_crate.crate"
  echo "git cached repo" > "$SANDBOX_DIR/home/.cargo/git/dummy_git_obj"
  echo "$SANDBOX_DIR"
}

# Create a mock df script returning custom available KB
create_mock_df() {
  DEST_FILE="$1"
  AVAIL_KB="$2"
  cat << EOF > "$DEST_FILE"
#!/bin/sh
cat << 'OUT_EOF'
Filesystem   1024-blocks      Used Available Capacity  Mounted on
/dev/mock        100000000 10000000   ${AVAIL_KB}      10%  /mock
OUT_EOF
EOF
  chmod +x "$DEST_FILE"
}

echo "=== Running grokgod-cache.sh Test Suite ==="

# ─────────────────────────────────────────────────────────
# Test 1: report prints sizes and exits 0 (assert output contains "target")
# ─────────────────────────────────────────────────────────
echo "Test 1: report prints sizes and exits 0"
S1="$(setup_sandbox "test_1")"
OUT1="$(
  HOME="$S1/home" \
  GROKGOD_HOME="$S1/home/.grokgod" \
  sh "$CACHE_SCRIPT" report
)"
echo "$OUT1" | grep -q "target" || { echo "FAIL: report output does not contain 'target': $OUT1"; exit 1; }
echo "$OUT1" | grep -q "grokgod cache report" || { echo "FAIL: report output does not contain header: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "cargo registry" || { echo "FAIL: report output does not contain 'cargo registry': $OUT1"; exit 1; }
echo "$OUT1" | grep -q "free disk:" || { echo "FAIL: report output does not contain 'free disk': $OUT1"; exit 1; }

# Also test default invocation with no arguments
OUT1_DEFAULT="$(
  HOME="$S1/home" \
  GROKGOD_HOME="$S1/home/.grokgod" \
  sh "$CACHE_SCRIPT"
)"
echo "$OUT1_DEFAULT" | grep -q "target" || { echo "FAIL: default invocation output does not contain 'target': $OUT1_DEFAULT"; exit 1; }
echo "PASS: Test 1 - report"

# ─────────────────────────────────────────────────────────
# Test 2: clean --yes removes the dir
# ─────────────────────────────────────────────────────────
echo "Test 2: clean --yes removes target directory"
S2="$(setup_sandbox "test_2")"
TARGET_DIR_2="$S2/home/.grokgod/target"
if [ ! -d "$TARGET_DIR_2" ]; then
  echo "FAIL: Sandbox target dir was not created"; exit 1
fi

OUT2="$(
  HOME="$S2/home" \
  GROKGOD_HOME="$S2/home/.grokgod" \
  sh "$CACHE_SCRIPT" clean --yes
)"
if [ -d "$TARGET_DIR_2" ]; then
  echo "FAIL: clean --yes did not remove target directory"; exit 1
fi
echo "$OUT2" | grep -q "Freed estimated:" || { echo "FAIL: clean output missing freed estimate: $OUT2"; exit 1; }
echo "$OUT2" | grep -q "New free disk:" || { echo "FAIL: clean output missing new free disk: $OUT2"; exit 1; }
echo "PASS: Test 2 - clean --yes"

# ─────────────────────────────────────────────────────────
# Test 3: clean without --yes and stdin=/dev/null does NOT remove (non-tty abort) and exits non-zero
# ─────────────────────────────────────────────────────────
echo "Test 3: clean without --yes and non-tty aborts"
S3="$(setup_sandbox "test_3")"
TARGET_DIR_3="$S3/home/.grokgod/target"

set +e
OUT3="$(
  HOME="$S3/home" \
  GROKGOD_HOME="$S3/home/.grokgod" \
  sh "$CACHE_SCRIPT" clean < /dev/null 2>&1
)"
STATUS3=$?
set -eu

if [ "$STATUS3" -eq 0 ]; then
  echo "FAIL: Expected non-zero exit code on clean without --yes from non-tty"; exit 1
fi
if [ ! -d "$TARGET_DIR_3" ]; then
  echo "FAIL: Target dir was removed despite abort!"; exit 1
fi
echo "$OUT3" | grep -q "stdin is not a tty" || { echo "FAIL: Output missing non-tty message: $OUT3"; exit 1; }
echo "PASS: Test 3 - clean non-tty abort"

# ─────────────────────────────────────────────────────────
# Test 4: --auto-clean with low free (mock df via DF_CMD) removes target
# ─────────────────────────────────────────────────────────
echo "Test 4: --auto-clean with low free space removes target"
S4="$(setup_sandbox "test_4")"
TARGET_DIR_4="$S4/home/.grokgod/target"
MOCK_DF_LOW="$S4/mock_df_low"
# 5 GB free = 5 * 1024 * 1024 = 5242880 KB (< 10 GB threshold)
create_mock_df "$MOCK_DF_LOW" 5242880

OUT4="$(
  DF_CMD="$MOCK_DF_LOW" \
  HOME="$S4/home" \
  GROKGOD_HOME="$S4/home/.grokgod" \
  sh "$CACHE_SCRIPT" --auto-clean
)"
if [ -d "$TARGET_DIR_4" ]; then
  echo "FAIL: --auto-clean did not remove target directory when free < 10 GiB"; exit 1
fi
echo "$OUT4" | grep -q "Auto-cleaning" || { echo "FAIL: --auto-clean missing auto-cleaning notice: $OUT4"; exit 1; }
echo "$OUT4" | grep -q "Freed estimated:" || { echo "FAIL: --auto-clean missing freed estimate: $OUT4"; exit 1; }
echo "PASS: Test 4 - --auto-clean on low disk"

# ─────────────────────────────────────────────────────────
# Test 5: --auto-clean with plenty free leaves target intact
# ─────────────────────────────────────────────────────────
echo "Test 5: --auto-clean with plenty free space leaves target intact"
S5="$(setup_sandbox "test_5")"
TARGET_DIR_5="$S5/home/.grokgod/target"
MOCK_DF_HIGH="$S5/mock_df_high"
# 50 GB free = 50 * 1024 * 1024 = 52428800 KB (> 10 GB threshold)
create_mock_df "$MOCK_DF_HIGH" 52428800

OUT5="$(
  DF_CMD="$MOCK_DF_HIGH" \
  HOME="$S5/home" \
  GROKGOD_HOME="$S5/home/.grokgod" \
  sh "$CACHE_SCRIPT" --auto-clean
)"
if [ ! -d "$TARGET_DIR_5" ]; then
  echo "FAIL: --auto-clean removed target directory when free space was plenty!"; exit 1
fi
echo "$OUT5" | grep -q "free space OK, nothing to do" || { echo "FAIL: Missing OK notice: $OUT5"; exit 1; }
echo "PASS: Test 5 - --auto-clean with plenty free space"

# ─────────────────────────────────────────────────────────
# Test 6: Safety: GROKGOD_HOME="" or "/" -> refuses (exit non-zero)
# ─────────────────────────────────────────────────────────
echo "Test 6: Safety guards on empty and root GROKGOD_HOME"
set +e
OUT6_EMPTY="$(
  GROKGOD_HOME="" \
  sh "$CACHE_SCRIPT" report 2>&1
)"
STATUS6_EMPTY=$?

OUT6_ROOT="$(
  GROKGOD_HOME="/" \
  sh "$CACHE_SCRIPT" report 2>&1
)"
STATUS6_ROOT=$?
set -eu

if [ "$STATUS6_EMPTY" -eq 0 ]; then
  echo "FAIL: Expected non-zero exit for empty GROKGOD_HOME"; exit 1
fi
echo "$OUT6_EMPTY" | grep -q "refusing to operate for safety" || { echo "FAIL: Missing safety message for empty GROKGOD_HOME: $OUT6_EMPTY"; exit 1; }

if [ "$STATUS6_ROOT" -eq 0 ]; then
  echo "FAIL: Expected non-zero exit for root GROKGOD_HOME"; exit 1
fi
echo "$OUT6_ROOT" | grep -q "refusing to operate for safety" || { echo "FAIL: Missing safety message for root GROKGOD_HOME: $OUT6_ROOT"; exit 1; }
echo "PASS: Test 6 - Safety guards"

# ─────────────────────────────────────────────────────────
# Test 7: Help text option
# ─────────────────────────────────────────────────────────
echo "Test 7: Help command"
OUT7="$(sh "$CACHE_SCRIPT" help)"
echo "$OUT7" | grep -q "Usage: grokgod cache" || { echo "FAIL: help output missing usage text: $OUT7"; exit 1; }
echo "PASS: Test 7 - Help command"

echo "=== All grokgod-cache.sh tests passed successfully! ==="
