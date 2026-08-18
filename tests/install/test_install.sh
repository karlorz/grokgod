#!/bin/sh
set -eu

# test_install.sh: Comprehensive test suite for install.sh
# Tests all requirements in fake prefix environments without touching real ~/.grokgod or ~/.local/bin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PATCH_FILE="$REPO_ROOT/patches/0001-normalize-plugin-skill-join.patch"
REAL_GROK_BUILD="/Users/karlchow/Desktop/code/grok-build"

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
GB_WORKTREE="$TMP_ROOT/gb_worktree"

cleanup() {
  set +e
  if [ -d "$GB_WORKTREE" ]; then
    git -C "$REAL_GROK_BUILD" worktree remove --force "$GB_WORKTREE" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

# Create a clean detached worktree from the real grok-build at commit d71f6e0c
echo "Creating test worktree from $REAL_GROK_BUILD at commit d71f6e0c..."
git -C "$REAL_GROK_BUILD" worktree add --detach "$GB_WORKTREE" d71f6e0c >/dev/null 2>&1

echo "=== Running install.sh Test Suite ==="

# Helper to reset an isolated test sandbox
setup_sandbox() {
  TEST_DIR="$TMP_ROOT/$1"
  mkdir -p "$TEST_DIR"
  PREFIX_DIR="$TEST_DIR/prefix"
  FAKE_HOME="$TEST_DIR/home"
  FAKE_GROKGOD_HOME="$FAKE_HOME/.grokgod"
  FAKE_BIN_DIR="$FAKE_HOME/.local/bin"
  FAKE_CARGO_TARGET_DIR="$FAKE_GROKGOD_HOME/target"
  FAKE_BIN_SHADOW="$TEST_DIR/fake_bin"

  mkdir -p "$FAKE_GROKGOD_HOME" "$FAKE_BIN_DIR" "$FAKE_BIN_SHADOW"

  # Create mock cargo in FAKE_BIN_SHADOW
  CARGO_INVOKED_FILE="$TEST_DIR/cargo_invoked.txt"
  rm -f "$CARGO_INVOKED_FILE"
  cat << EOF > "$FAKE_BIN_SHADOW/cargo"
#!/bin/sh
set -eu
echo "cargo invoked with: \$*" >> "$CARGO_INVOKED_FILE"
# Write fake built binary
if [ -n "\${CARGO_TARGET_DIR:-}" ]; then
  mkdir -p "\$CARGO_TARGET_DIR/release"
  cat << 'BIN_EOF' > "\$CARGO_TARGET_DIR/release/xai-grok-pager"
#!/bin/sh
echo "MOCK_BUILT_GROK_BINARY"
BIN_EOF
  chmod +x "\$CARGO_TARGET_DIR/release/xai-grok-pager"
fi
exit 0
EOF
  chmod +x "$FAKE_BIN_SHADOW/cargo"
}

# Helper to reset gb_worktree to clean HEAD
reset_worktree() {
  git -C "$GB_WORKTREE" reset --hard d71f6e0c >/dev/null 2>&1
  git -C "$GB_WORKTREE" clean -fdx >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────
# Test (a): Dry-run prints actions and touches nothing outside /tmp
# ─────────────────────────────────────────────────────────
echo "Test (a): Dry-run mode"
setup_sandbox "test_a"
reset_worktree

DRY_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --dry-run
)"

echo "$DRY_OUT" | grep -q "Dry-run completed successfully" || { echo "FAIL: Expected dry-run success message"; exit 1; }
echo "$DRY_OUT" | grep -q "Would test and apply patch" || { echo "FAIL: Expected patch test dry-run line"; exit 1; }

# Verify nothing was written to fake dirs
if [ -e "$FAKE_GROKGOD_HOME/bin/grok" ]; then
  echo "FAIL: Dry-run created binary in GROKGOD_HOME"; exit 1
fi
if [ -e "$FAKE_BIN_DIR/grok" ]; then
  echo "FAIL: Dry-run created launcher in BIN_DIR"; exit 1
fi
if [ -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Dry-run invoked cargo"; exit 1
fi
echo "PASS: Test (a) - Dry-run"

# ─────────────────────────────────────────────────────────
# Test (b): Fresh install with mocks
# ─────────────────────────────────────────────────────────
echo "Test (b): Fresh install with mocks"
setup_sandbox "test_b"
reset_worktree

INSTALL_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --no-upgrade
)"

# 1. Verify fake binary copied and executable
if [ ! -x "$FAKE_GROKGOD_HOME/bin/grok" ]; then
  echo "FAIL: $FAKE_GROKGOD_HOME/bin/grok is not executable or missing"; exit 1
fi
BIN_OUTPUT="$("$FAKE_GROKGOD_HOME/bin/grok")"
if [ "$BIN_OUTPUT" != "MOCK_BUILT_GROK_BINARY" ]; then
  echo "FAIL: Installed binary content mismatch: $BIN_OUTPUT"; exit 1
fi

# 2. Verify stamps in .source-version
if [ ! -f "$FAKE_GROKGOD_HOME/.source-version" ]; then
  echo "FAIL: .source-version missing"; exit 1
fi
STAMP_CONTENT="$(cat "$FAKE_GROKGOD_HOME/.source-version")"
echo "$STAMP_CONTENT" | grep -q "^SHA=" || { echo "FAIL: .source-version missing SHA line"; exit 1; }
echo "$STAMP_CONTENT" | grep -q "^PATCHSET=" || { echo "FAIL: .source-version missing PATCHSET line"; exit 1; }

# 3. Verify shim launchers installed at BIN_DIR/grok and BIN_DIR/grokgod
if [ ! -x "$FAKE_BIN_DIR/grok" ]; then
  echo "FAIL: $FAKE_BIN_DIR/grok launcher not installed"; exit 1
fi
if [ ! -x "$FAKE_BIN_DIR/grokgod" ]; then
  echo "FAIL: $FAKE_BIN_DIR/grokgod launcher not installed"; exit 1
fi
grep -q "GROKGOD" "$FAKE_BIN_DIR/grok" || { echo "FAIL: $FAKE_BIN_DIR/grok is not the grokgod shim"; exit 1; }
grep -q "GROKGOD" "$FAKE_BIN_DIR/grokgod" || { echo "FAIL: $FAKE_BIN_DIR/grokgod is not the grokgod shim"; exit 1; }

# 4. Verify launcher runs target binary
LAUNCHER_OUT="$(
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  sh "$FAKE_BIN_DIR/grok"
)"
if [ "$LAUNCHER_OUT" != "MOCK_BUILT_GROK_BINARY" ]; then
  echo "FAIL: Executing launcher produced unexpected output: $LAUNCHER_OUT"; exit 1
fi
echo "PASS: Test (b) - Fresh install"

# ─────────────────────────────────────────────────────────
# Test (c): Fail-closed on corrupt patch
# ─────────────────────────────────────────────────────────
echo "Test (c): Fail-closed on corrupt patch"
setup_sandbox "test_c"
reset_worktree

# Pre-place an existing binary in fake GROKGOD_HOME
mkdir -p "$FAKE_GROKGOD_HOME/bin"
echo "EXISTING_GOOD_BINARY" > "$FAKE_GROKGOD_HOME/bin/grok"
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"

# Create a temporary fake repo copy with a corrupt patch
FAKE_REPO_DIR="$TEST_DIR/fake_repo"
mkdir -p "$FAKE_REPO_DIR/patches" "$FAKE_REPO_DIR/src/shim"
cp "$REPO_ROOT/src/shim/grok-shim.sh" "$FAKE_REPO_DIR/src/shim/"
cp "$INSTALL_SCRIPT" "$FAKE_REPO_DIR/install.sh"
# Corrupt patch
cat << 'EOF' > "$FAKE_REPO_DIR/patches/0001-corrupt.patch"
--- a/nonexistent_file.rs
+++ b/nonexistent_file.rs
@@ -1,3 +1,3 @@
-invalid context line that fails check
+some change
EOF

set +e
FAIL_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$FAKE_REPO_DIR/install.sh" --no-upgrade 2>&1
)"
FAIL_STATUS=$?
set -eu

if [ "$FAIL_STATUS" -eq 0 ]; then
  echo "FAIL: Expected install.sh to fail on corrupt patch, but exited 0"; exit 1
fi

# Verify existing binary was untouched
if [ ! -f "$FAKE_GROKGOD_HOME/bin/grok" ]; then
  echo "FAIL: Pre-existing binary was deleted!"; exit 1
fi
EXISTING_CONTENT="$(cat "$FAKE_GROKGOD_HOME/bin/grok")"
if [ "$EXISTING_CONTENT" != "EXISTING_GOOD_BINARY" ]; then
  echo "FAIL: Pre-existing binary was modified!"; exit 1
fi
echo "PASS: Test (c) - Fail-closed on corrupt patch"

# ─────────────────────────────────────────────────────────
# Test (d): --no-upgrade fast path
# ─────────────────────────────────────────────────────────
echo "Test (d): --no-upgrade fast path"
setup_sandbox "test_d"
reset_worktree

# First run: regular fresh install (invokes cargo)
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --no-upgrade >/dev/null

if [ ! -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Cargo was not invoked on first install"; exit 1
fi

# Reset cargo invoked marker
rm -f "$CARGO_INVOKED_FILE"

# Second run: --no-upgrade with matching stamp and binary
SECOND_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --no-upgrade
)"

echo "$SECOND_OUT" | grep -q "Fast-path: skipping cargo build" || { echo "FAIL: Expected fast-path message in output ($SECOND_OUT)"; exit 1; }

if [ -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Cargo was invoked during fast path run!"; exit 1
fi
echo "PASS: Test (d) - Fast path skips build"

# ─────────────────────────────────────────────────────────
# Test (e): Uninstall restores grok.orig and cleans up
# ─────────────────────────────────────────────────────────
echo "Test (e): Uninstall restores grok.orig"
setup_sandbox "test_e"
reset_worktree

# Set up an official grok binary
echo "ORIGINAL_OFFICIAL_GROK" > "$FAKE_BIN_DIR/grok"
chmod +x "$FAKE_BIN_DIR/grok"

# Run install to back it up to grok.orig and install shim
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --no-upgrade >/dev/null

if [ ! -f "$FAKE_BIN_DIR/grok.orig" ]; then
  echo "FAIL: grok.orig backup was not created"; exit 1
fi
ORIG_BACKUP="$(cat "$FAKE_BIN_DIR/grok.orig")"
if [ "$ORIG_BACKUP" != "ORIGINAL_OFFICIAL_GROK" ]; then
  echo "FAIL: grok.orig content mismatch: $ORIG_BACKUP"; exit 1
fi

# Run uninstall
UNINSTALL_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --uninstall
)"

# Verify grok.orig was restored to grok
if [ -e "$FAKE_BIN_DIR/grok.orig" ]; then
  echo "FAIL: grok.orig still exists after uninstall"; exit 1
fi
if [ ! -f "$FAKE_BIN_DIR/grok" ]; then
  echo "FAIL: $FAKE_BIN_DIR/grok missing after uninstall"; exit 1
fi
RESTORED_CONTENT="$(cat "$FAKE_BIN_DIR/grok")"
if [ "$RESTORED_CONTENT" != "ORIGINAL_OFFICIAL_GROK" ]; then
  echo "FAIL: Restored grok content mismatch: $RESTORED_CONTENT"; exit 1
fi

# Verify grokgod launcher removed
if [ -e "$FAKE_BIN_DIR/grokgod" ]; then
  echo "FAIL: $FAKE_BIN_DIR/grokgod was not removed"; exit 1
fi

# Verify GROKGOD_HOME removed
if [ -d "$FAKE_GROKGOD_HOME" ]; then
  echo "FAIL: $FAKE_GROKGOD_HOME was not removed"; exit 1
fi
echo "PASS: Test (e) - Uninstall"

# ─────────────────────────────────────────────────────────
# Test (f): Disk guard aborts on low disk space
# ─────────────────────────────────────────────────────────
echo "Test (f): Disk guard aborts on low space"
setup_sandbox "test_f"
reset_worktree

# Create a mock df script returning 1000 KB (less than 15 GB = 15728640 KB)
cat << 'EOF' > "$FAKE_BIN_SHADOW/mock_df"
#!/bin/sh
cat << 'OUT_EOF'
Filesystem   1024-blocks      Used Available Capacity  Mounted on
/dev/mock        1000000    999000      1000      99%  /
OUT_EOF
EOF
chmod +x "$FAKE_BIN_SHADOW/mock_df"

set +e
DISK_ERR="$(
  DF_CMD="$FAKE_BIN_SHADOW/mock_df" \
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --no-upgrade 2>&1
)"
DISK_STATUS=$?
set -eu

if [ "$DISK_STATUS" -eq 0 ]; then
  echo "FAIL: Expected install.sh to abort on low disk space, but exited 0"; exit 1
fi
echo "$DISK_ERR" | grep -q "Insufficient disk space" || { echo "FAIL: Expected disk error message ($DISK_ERR)"; exit 1; }
echo "PASS: Test (f) - Disk guard"

# ─────────────────────────────────────────────────────────
# Test (g): Dirty tree reversal handling
# ─────────────────────────────────────────────────────────
echo "Test (g): Dirty tree with prior patch is automatically reversed and applied"
setup_sandbox "test_g"
reset_worktree

# Pre-apply patch to simulate a previously patched tree
git -C "$GB_WORKTREE" apply "$PATCH_FILE"
git -C "$GB_WORKTREE" diff --quiet && { echo "FAIL: Worktree should be dirty after manual apply"; exit 1; }

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --no-upgrade >/dev/null

if [ ! -x "$FAKE_GROKGOD_HOME/bin/grok" ]; then
  echo "FAIL: Expected successful install on previously patched tree"; exit 1
fi
echo "PASS: Test (g) - Dirty tree reversal"

# ─────────────────────────────────────────────────────────
# Test (h): --prefix flag support
# ─────────────────────────────────────────────────────────
echo "Test (h): --prefix support"
setup_sandbox "test_h"
reset_worktree

PREFIX_TARGET="$TEST_DIR/custom_prefix"
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
sh "$INSTALL_SCRIPT" --no-upgrade --prefix "$PREFIX_TARGET" >/dev/null

if [ ! -x "$PREFIX_TARGET/grokgod/bin/grok" ]; then
  echo "FAIL: Binary not installed under prefix at $PREFIX_TARGET/grokgod/bin/grok"; exit 1
fi
if [ ! -x "$PREFIX_TARGET/bin/grok" ]; then
  echo "FAIL: Launcher not installed under prefix at $PREFIX_TARGET/bin/grok"; exit 1
fi
echo "PASS: Test (h) - Prefix flag"

echo "=== All install.sh tests passed successfully! ==="
