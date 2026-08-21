#!/bin/sh
set -eu

# test_install.sh: Comprehensive test suite for install.sh
# Tests all requirements in fake prefix environments without touching real ~/.grokgod or ~/.local/bin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PATCH_FILE="$REPO_ROOT/patches/0001-normalize-plugin-skill-join.patch"
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
if [ "${CI:-0}" = "1" ]; then
  REAL_GROK_BUILD="/nonexistent"
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
  echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
GB_WORKTREE="$TMP_ROOT/gb_worktree"

cleanup() {
  set +e
  if [ -d "$GB_WORKTREE" ] && [ -d "$REAL_GROK_BUILD/.git" ]; then
    git -C "$REAL_GROK_BUILD" worktree remove --force "$GB_WORKTREE" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

# Setup GB_WORKTREE fixture
if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Creating test worktree from $REAL_GROK_BUILD at commit d71f6e0c..."
  git -C "$REAL_GROK_BUILD" worktree add --detach "$GB_WORKTREE" d71f6e0c >/dev/null 2>&1
else
  # CI or standalone fixture without local grok-build clone.
  # Fetch every path grokgod patches touch so `git apply --check` 0001+0002 works.
  echo "Building fixture git repository for CI..."
  PIN_SHA="d71f6e0c1f5acc5469e503e192fe14824e6f8c90"
  RAW_BASE="https://raw.githubusercontent.com/xai-org/grok-build/${PIN_SHA}"
  PATCH_PATHS="$(
    grep -h '^diff --git ' "$REPO_ROOT"/patches/*.patch 2>/dev/null \
      | awk '{print $3}' \
      | sed 's#^a/##' \
      | sort -u
  )"
  if [ -z "$PATCH_PATHS" ]; then
    PATCH_PATHS="crates/codegen/xai-grok-agent/src/plugins/manifest.rs"
  fi
  for rel in $PATCH_PATHS; do
    mkdir -p "$GB_WORKTREE/$(dirname "$rel")"
    if ! curl -fsSL "$RAW_BASE/$rel" -o "$GB_WORKTREE/$rel"; then
      echo "Warning: curl failed for $rel, creating empty fallback"
      : > "$GB_WORKTREE/$rel"
    fi
  done
  git -C "$GB_WORKTREE" init -b main >/dev/null 2>&1
  git -C "$GB_WORKTREE" config user.name "CI"
  git -C "$GB_WORKTREE" config user.email "ci@example.com"
  git -C "$GB_WORKTREE" add .
  git -C "$GB_WORKTREE" commit -m "initial d71f6e0c fixture" >/dev/null 2>&1
fi

echo "=== Running install.sh Test Suite ==="

# Helper to reset an isolated test sandbox
setup_sandbox() {
  TEST_DIR="$TMP_ROOT/$1"
  mkdir -p "$TEST_DIR"
  PREFIX_DIR="$TEST_DIR/prefix"
  FAKE_HOME="$TEST_DIR/home"
  FAKE_GROKGOD_HOME="$FAKE_HOME/.grokgod"
  FAKE_GROK_HOME="$FAKE_HOME/.grok"
  FAKE_BIN_DIR="$FAKE_HOME/.local/bin"
  FAKE_CARGO_TARGET_DIR="$FAKE_GROKGOD_HOME/target"
  FAKE_BIN_SHADOW="$TEST_DIR/fake_bin"

  mkdir -p "$FAKE_GROKGOD_HOME" "$FAKE_GROK_HOME" "$FAKE_BIN_DIR" "$FAKE_BIN_SHADOW"

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
  if [ -d "$REAL_GROK_BUILD/.git" ]; then
    git -C "$GB_WORKTREE" reset --hard d71f6e0c >/dev/null 2>&1
  else
    git -C "$GB_WORKTREE" reset --hard HEAD >/dev/null 2>&1
  fi
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
  sh "$INSTALL_SCRIPT" --from-source --dry-run
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
  sh "$INSTALL_SCRIPT" --from-source --no-upgrade
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
echo "$STAMP_CONTENT" | grep -q "^MODE=source" || { echo "FAIL: .source-version missing MODE=source line"; exit 1; }

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
  sh "$FAKE_REPO_DIR/install.sh" --from-source --no-upgrade 2>&1
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
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

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
  sh "$INSTALL_SCRIPT" --from-source --no-upgrade
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
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

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
  sh "$INSTALL_SCRIPT" --from-source --no-upgrade 2>&1
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

# Pre-apply all patches to simulate a previously patched tree
for p in "$REPO_ROOT"/patches/*.patch; do
  [ -f "$p" ] && git -C "$GB_WORKTREE" apply "$p"
done
git -C "$GB_WORKTREE" diff --quiet && { echo "FAIL: Worktree should be dirty after manual apply"; exit 1; }

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

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
sh "$INSTALL_SCRIPT" --from-source --no-upgrade --prefix "$PREFIX_TARGET" >/dev/null

if [ ! -x "$PREFIX_TARGET/grokgod/bin/grok" ]; then
  echo "FAIL: Binary not installed under prefix at $PREFIX_TARGET/grokgod/bin/grok"; exit 1
fi
if [ ! -x "$PREFIX_TARGET/bin/grok" ]; then
  echo "FAIL: Launcher not installed under prefix at $PREFIX_TARGET/bin/grok"; exit 1
fi
if [ ! -x "$PREFIX_TARGET/grok/bin/grok" ]; then
  echo "FAIL: Launcher not installed under prefix at $PREFIX_TARGET/grok/bin/grok"; exit 1
fi
echo "PASS: Test (h) - Prefix flag"

# ─────────────────────────────────────────────────────────
# Test (i): Own $GROK_HOME/bin/grok shim and preserve versioned Mach-O
# ─────────────────────────────────────────────────────────
echo "Test (i): Own \$GROK_HOME/bin/grok shim replacing symlink to grok-1.0.5"
setup_sandbox "test_i"
reset_worktree

# Setup fake GROK_HOME/bin with grok-1.0.5 Mach-O and grok symlink
mkdir -p "$FAKE_GROK_HOME/bin"
cat << 'MACHO_EOF' > "$FAKE_GROK_HOME/bin/grok-1.0.5"
OFFICIAL_VERSIONED_MACHO_1_0_5
MACHO_EOF
chmod +x "$FAKE_GROK_HOME/bin/grok-1.0.5"
(cd "$FAKE_GROK_HOME/bin" && ln -s grok-1.0.5 grok)

# Verify initial setup
if [ ! -L "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: Initial setup failed to create symlink at $FAKE_GROK_HOME/bin/grok"; exit 1
fi

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

# 1. $FAKE_GROK_HOME/bin/grok is a regular file (NOT a symlink) containing GROKGOD
if [ -L "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok is still a symlink after install"; exit 1
fi
if [ ! -f "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok is not a regular file"; exit 1
fi
grep -q "GROKGOD" "$FAKE_GROK_HOME/bin/grok" || {
  echo "FAIL: $FAKE_GROK_HOME/bin/grok does not contain GROKGOD"; exit 1
}

# 2. Versioned Mach-O grok-1.0.5 still exists and has original content
if [ ! -f "$FAKE_GROK_HOME/bin/grok-1.0.5" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok-1.0.5 was deleted or moved"; exit 1
fi
MACHO_CONTENT="$(cat "$FAKE_GROK_HOME/bin/grok-1.0.5")"
if [ "$MACHO_CONTENT" != "OFFICIAL_VERSIONED_MACHO_1_0_5" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok-1.0.5 was modified: $MACHO_CONTENT"; exit 1
fi

# 3. grok.orig exists in GROK_HOME/bin (the backup of the original symlink or file)
if [ ! -e "$FAKE_GROK_HOME/bin/grok.orig" ] && [ ! -L "$FAKE_GROK_HOME/bin/grok.orig" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok.orig backup was not created"; exit 1
fi

# 4. ~/.local/bin/grok and ~/.local/bin/grokgod are also installed as shims
if [ ! -x "$FAKE_BIN_DIR/grok" ] || [ ! -x "$FAKE_BIN_DIR/grokgod" ]; then
  echo "FAIL: Launchers in $FAKE_BIN_DIR were not installed"; exit 1
fi
grep -q "GROKGOD" "$FAKE_BIN_DIR/grok" || { echo "FAIL: $FAKE_BIN_DIR/grok is not GROKGOD shim"; exit 1; }
grep -q "GROKGOD" "$FAKE_BIN_DIR/grokgod" || { echo "FAIL: $FAKE_BIN_DIR/grokgod is not GROKGOD shim"; exit 1; }

echo "PASS: Test (i) - Own GROK_HOME/bin/grok shim"

# ─────────────────────────────────────────────────────────
# Test (j): Uninstall restores official grok in GROK_HOME/bin
# ─────────────────────────────────────────────────────────
echo "Test (j): Uninstall restores official grok in GROK_HOME/bin"
setup_sandbox "test_j"
reset_worktree

# Setup fake GROK_HOME/bin with grok-1.0.5 and symlink
mkdir -p "$FAKE_GROK_HOME/bin"
cat << 'MACHO_EOF' > "$FAKE_GROK_HOME/bin/grok-1.0.5"
OFFICIAL_VERSIONED_MACHO_1_0_5
MACHO_EOF
chmod +x "$FAKE_GROK_HOME/bin/grok-1.0.5"
(cd "$FAKE_GROK_HOME/bin" && ln -s grok-1.0.5 grok)

# Install grokgod
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

# Now uninstall
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --uninstall >/dev/null

# 1. GROK_HOME/bin/grok.orig should be gone
if [ -e "$FAKE_GROK_HOME/bin/grok.orig" ] || [ -L "$FAKE_GROK_HOME/bin/grok.orig" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok.orig still exists after uninstall"; exit 1
fi

# 2. GROK_HOME/bin/grok must exist and NOT be a GROKGOD shim
if [ ! -e "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok does not exist after uninstall"; exit 1
fi
if grep -q "GROKGOD" "$FAKE_GROK_HOME/bin/grok" 2>/dev/null; then
  echo "FAIL: $FAKE_GROK_HOME/bin/grok is still a GROKGOD shim after uninstall"; exit 1
fi

# 3. Executing GROK_HOME/bin/grok resolves to official binary (points to grok-1.0.5)
RESOLVED_OUT="$(cat "$FAKE_GROK_HOME/bin/grok")"
if [ "$RESOLVED_OUT" != "OFFICIAL_VERSIONED_MACHO_1_0_5" ]; then
  echo "FAIL: Reading $FAKE_GROK_HOME/bin/grok gave: $RESOLVED_OUT, expected: OFFICIAL_VERSIONED_MACHO_1_0_5"; exit 1
fi

# 4. Test case where grok.orig was absent but grok was our shim and grok-* exists
rm -f "$FAKE_GROK_HOME/bin/grok"
cp "$REPO_ROOT/src/shim/grok-shim.sh" "$FAKE_GROK_HOME/bin/grok"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --uninstall >/dev/null

if [ ! -L "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: Fallback symlink to grok-1.0.5 was not created when grok.orig was absent"; exit 1
fi
RESOLVED_FALLBACK_OUT="$(cat "$FAKE_GROK_HOME/bin/grok")"
if [ "$RESOLVED_FALLBACK_OUT" != "OFFICIAL_VERSIONED_MACHO_1_0_5" ]; then
  echo "FAIL: Fallback symlink gave: $RESOLVED_FALLBACK_OUT, expected: OFFICIAL_VERSIONED_MACHO_1_0_5"; exit 1
fi

echo "PASS: Test (j) - Uninstall restores official grok in GROK_HOME/bin"

# ─────────────────────────────────────────────────────────
# Test (k): Release-mode install with mocked curl and checksums
# ─────────────────────────────────────────────────────────
echo "Test (k): Release-mode install with mocked curl"
setup_sandbox "test_k"

# Detect OS and ARCH for the fake asset name
RAW_OS="$(uname -s)"
case "$RAW_OS" in
  Darwin) TEST_OS="darwin" ;;
  Linux)  TEST_OS="linux" ;;
  *) TEST_OS="unknown" ;;
esac
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64|amd64) TEST_ARCH="x64" ;;
  arm64|aarch64) TEST_ARCH="arm64" ;;
  *) TEST_ARCH="unknown" ;;
esac

TEST_ASSET="grokgod-${TEST_OS}-${TEST_ARCH}"
FAKE_DL_DIR="$TEST_DIR/fake_downloads"
mkdir -p "$FAKE_DL_DIR"

# Create fake prebuilt binary in fake_downloads
cat << 'BIN_EOF' > "$FAKE_DL_DIR/$TEST_ASSET"
#!/bin/sh
echo "PREBUILT_GROKGOD_BINARY_RELEASE_1_0_0"
BIN_EOF
chmod +x "$FAKE_DL_DIR/$TEST_ASSET"

# Compute actual SHA256 of fake binary
if command -v sha256sum >/dev/null 2>&1; then
  TEST_SHA="$(sha256sum "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  TEST_SHA="$(shasum -a 256 "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
else
  TEST_SHA="dummy_sha"
fi

# Write fake SHA256SUMS
printf "%s  %s\n" "$TEST_SHA" "$TEST_ASSET" > "$FAKE_DL_DIR/SHA256SUMS"

# Create mock curl in FAKE_BIN_SHADOW
cat << EOF > "$FAKE_BIN_SHADOW/curl"
#!/bin/sh
set -eu

# Intercept API latest release call
url=""
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output)
      out_file="\$2"
      shift 2
      ;;
    -fsSL|-sSL|-s|-f|-L|-fsSLk)
      shift
      ;;
    http*|ftp*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if echo "\$url" | grep -q "/releases/latest"; then
  cat << 'JSON_EOF'
{
  "tag_name": "v1.0.0",
  "assets": [
    {
      "name": "$TEST_ASSET",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/$TEST_ASSET"
    },
    {
      "name": "SHA256SUMS",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/SHA256SUMS"
    }
  ]
}
JSON_EOF
  exit 0
fi

if echo "\$url" | grep -q "SHA256SUMS"; then
  if [ -n "\$out_file" ]; then
    cp "$FAKE_DL_DIR/SHA256SUMS" "\$out_file"
  else
    cat "$FAKE_DL_DIR/SHA256SUMS"
  fi
  exit 0
fi

if echo "\$url" | grep -q "$TEST_ASSET"; then
  if [ -n "\$out_file" ]; then
    cp "$FAKE_DL_DIR/$TEST_ASSET" "\$out_file"
  else
    cat "$FAKE_DL_DIR/$TEST_ASSET"
  fi
  exit 0
fi

# Handle raw github content script downloads if needed
if echo "\$url" | grep -q "raw.githubusercontent.com"; then
  filename=\$(basename "\$url")
  case "\$filename" in
    grok-shim.sh)
      src_path="$REPO_ROOT/src/shim/grok-shim.sh"
      ;;
    grokgod-cache.sh)
      src_path="$REPO_ROOT/src/grokgod-cache.sh"
      ;;
    grokgod-run.sh)
      src_path="$REPO_ROOT/src/grokgod-run.sh"
      ;;
    grokgod-pin.sh)
      src_path="$REPO_ROOT/src/grokgod-pin.sh"
      ;;
    *)
      src_path=""
      ;;
  esac
  if [ -n "\$src_path" ] && [ -f "\$src_path" ]; then
    if [ -n "\$out_file" ]; then
      cp "\$src_path" "\$out_file"
    else
      cat "\$src_path"
    fi
    exit 0
  fi
fi

echo "mock curl unhandled URL: \$url" >&2
exit 1
EOF
chmod +x "$FAKE_BIN_SHADOW/curl"

# Run install.sh in release mode (default)
INSTALL_REL_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_HOME="$FAKE_GROK_HOME" \
  BIN_DIR="$FAKE_BIN_DIR" \
  sh "$INSTALL_SCRIPT" --version 1.0.0
)"

# 1. Verify fake downloaded binary is in $FAKE_GROKGOD_HOME/bin/grok
if [ ! -x "$FAKE_GROKGOD_HOME/bin/grok" ]; then
  echo "FAIL: Test (k) - $FAKE_GROKGOD_HOME/bin/grok is not executable or missing"; exit 1
fi
REL_BIN_OUT="$("$FAKE_GROKGOD_HOME/bin/grok")"
if [ "$REL_BIN_OUT" != "PREBUILT_GROKGOD_BINARY_RELEASE_1_0_0" ]; then
  echo "FAIL: Test (k) - Executing installed binary gave: $REL_BIN_OUT"; exit 1
fi

# 2. Verify .source-version contains VERSION=v1.0.0, SHA=, and MODE=release
if [ ! -f "$FAKE_GROKGOD_HOME/.source-version" ]; then
  echo "FAIL: Test (k) - .source-version missing"; exit 1
fi
REL_STAMP="$(cat "$FAKE_GROKGOD_HOME/.source-version")"
echo "$REL_STAMP" | grep -q "^VERSION=v1.0.0" || { echo "FAIL: Test (k) - Missing VERSION=v1.0.0 in .source-version ($REL_STAMP)"; exit 1; }
echo "$REL_STAMP" | grep -q "^SHA=$TEST_SHA" || { echo "FAIL: Test (k) - Missing SHA in .source-version ($REL_STAMP)"; exit 1; }
echo "$REL_STAMP" | grep -q "^MODE=release" || { echo "FAIL: Test (k) - Missing MODE=release in .source-version ($REL_STAMP)"; exit 1; }

# 3. Verify cargo was NOT invoked
if [ -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Test (k) - Cargo was invoked during release mode install!"; exit 1
fi

# 4. Verify launchers are installed
if [ ! -x "$FAKE_BIN_DIR/grok" ] || [ ! -x "$FAKE_BIN_DIR/grokgod" ] || [ ! -x "$FAKE_GROK_HOME/bin/grok" ]; then
  echo "FAIL: Test (k) - Launchers missing after release install"; exit 1
fi

echo "PASS: Test (k) - Release-mode install"

# ─────────────────────────────────────────────────────────
# Test (l): Release-mode no-op when stamp matches tag and binary present
# ─────────────────────────────────────────────────────────
echo "Test (l): Release-mode no-op when stamp matches"
setup_sandbox "test_l"

TEST_ASSET="grokgod-${TEST_OS}-${TEST_ARCH}"
FAKE_DL_DIR="$TEST_DIR/fake_downloads"
mkdir -p "$FAKE_DL_DIR"

cat << 'BIN_EOF' > "$FAKE_DL_DIR/$TEST_ASSET"
#!/bin/sh
echo "PREBUILT_GROKGOD_BINARY_RELEASE_1_0_0"
BIN_EOF
chmod +x "$FAKE_DL_DIR/$TEST_ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  TEST_SHA="$(sha256sum "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  TEST_SHA="$(shasum -a 256 "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
else
  TEST_SHA="dummy_sha"
fi
printf "%s  %s\n" "$TEST_SHA" "$TEST_ASSET" > "$FAKE_DL_DIR/SHA256SUMS"

CURL_LOG="$TEST_DIR/curl_invocations.txt"
rm -f "$CURL_LOG"

cat << EOF > "$FAKE_BIN_SHADOW/curl"
#!/bin/sh
set -eu
url=""
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output)
      out_file="\$2"
      shift 2
      ;;
    -fsSL|-sSL|-s|-f|-L|-fsSLk)
      shift
      ;;
    http*|ftp*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "\$url" >> "$CURL_LOG"

if echo "\$url" | grep -q "/releases/latest"; then
  cat << 'JSON_EOF'
{
  "tag_name": "v1.0.0",
  "assets": [
    {
      "name": "$TEST_ASSET",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/$TEST_ASSET"
    },
    {
      "name": "SHA256SUMS",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/SHA256SUMS"
    }
  ]
}
JSON_EOF
  exit 0
fi

if echo "\$url" | grep -q "SHA256SUMS"; then
  if [ -n "\$out_file" ]; then
    cp "$FAKE_DL_DIR/SHA256SUMS" "\$out_file"
  else
    cat "$FAKE_DL_DIR/SHA256SUMS"
  fi
  exit 0
fi

if echo "\$url" | grep -q "$TEST_ASSET"; then
  if [ -n "\$out_file" ]; then
    cp "$FAKE_DL_DIR/$TEST_ASSET" "\$out_file"
  else
    cat "$FAKE_DL_DIR/$TEST_ASSET"
  fi
  exit 0
fi

if echo "\$url" | grep -q "raw.githubusercontent.com"; then
  filename=\$(basename "\$url")
  case "\$filename" in
    grok-shim.sh) src_path="$REPO_ROOT/src/shim/grok-shim.sh" ;;
    grokgod-cache.sh) src_path="$REPO_ROOT/src/grokgod-cache.sh" ;;
    grokgod-run.sh) src_path="$REPO_ROOT/src/grokgod-run.sh" ;;
    grokgod-pin.sh) src_path="$REPO_ROOT/src/grokgod-pin.sh" ;;
    *) src_path="" ;;
  esac
  if [ -n "\$src_path" ] && [ -f "\$src_path" ]; then
    if [ -n "\$out_file" ]; then
      cp "\$src_path" "\$out_file"
    else
      cat "\$src_path"
    fi
    exit 0
  fi
fi

echo "mock curl unhandled URL: \$url" >&2
exit 1
EOF
chmod +x "$FAKE_BIN_SHADOW/curl"

# Pre-populate GROKGOD_HOME with matching binary and stamp
mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "EXISTING_GROKGOD_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"

printf "SHA=%s\nPATCHSET=%s\nVERSION=v1.0.0\nMODE=release\n" "$TEST_SHA" "v1.0.0" > "$FAKE_GROKGOD_HOME/.source-version"
INITIAL_STAMP_MD5="$(cat "$FAKE_GROKGOD_HOME/.source-version")"

REL_NOOP_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_HOME="$FAKE_GROK_HOME" \
  BIN_DIR="$FAKE_BIN_DIR" \
  sh "$INSTALL_SCRIPT"
)"

# Assert curl log does NOT contain asset download
if grep -q "$TEST_ASSET" "$CURL_LOG"; then
  echo "FAIL: Test (l) - Asset was downloaded despite matching stamp!"; exit 1
fi

# Assert stdout contains "Already up to date"
echo "$REL_NOOP_OUT" | grep -q "Already up to date" || {
  echo "FAIL: Test (l) - Missing 'Already up to date' in output: $REL_NOOP_OUT"; exit 1
}

# Assert stamp file byte-identical
AFTER_STAMP_MD5="$(cat "$FAKE_GROKGOD_HOME/.source-version")"
if [ "$INITIAL_STAMP_MD5" != "$AFTER_STAMP_MD5" ]; then
  echo "FAIL: Test (l) - Stamp file was modified during no-op!"; exit 1
fi
echo "PASS: Test (l) - Release-mode no-op"

# ─────────────────────────────────────────────────────────
# Test (m): Release-mode update when stamp is older
# ─────────────────────────────────────────────────────────
echo "Test (m): Release-mode update when stamp is older"
setup_sandbox "test_m"

FAKE_DL_DIR="$TEST_DIR/fake_downloads"
mkdir -p "$FAKE_DL_DIR"
cat << 'BIN_EOF' > "$FAKE_DL_DIR/$TEST_ASSET"
#!/bin/sh
echo "NEW_RELEASE_1_0_0"
BIN_EOF
chmod +x "$FAKE_DL_DIR/$TEST_ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  TEST_SHA="$(sha256sum "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  TEST_SHA="$(shasum -a 256 "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
else
  TEST_SHA="dummy_sha"
fi
printf "%s  %s\n" "$TEST_SHA" "$TEST_ASSET" > "$FAKE_DL_DIR/SHA256SUMS"

CURL_LOG="$TEST_DIR/curl_invocations.txt"
rm -f "$CURL_LOG"

cat << EOF > "$FAKE_BIN_SHADOW/curl"
#!/bin/sh
set -eu
url=""
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output)
      out_file="\$2"
      shift 2
      ;;
    -fsSL|-sSL|-s|-f|-L|-fsSLk)
      shift
      ;;
    http*|ftp*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "\$url" >> "$CURL_LOG"

if echo "\$url" | grep -q "/releases/latest"; then
  cat << 'JSON_EOF'
{
  "tag_name": "v1.0.0",
  "assets": [
    {
      "name": "$TEST_ASSET",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/$TEST_ASSET"
    },
    {
      "name": "SHA256SUMS",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/SHA256SUMS"
    }
  ]
}
JSON_EOF
  exit 0
fi

if echo "\$url" | grep -q "SHA256SUMS"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/SHA256SUMS" "\$out_file"; else cat "$FAKE_DL_DIR/SHA256SUMS"; fi
  exit 0
fi

if echo "\$url" | grep -q "$TEST_ASSET"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/$TEST_ASSET" "\$out_file"; else cat "$FAKE_DL_DIR/$TEST_ASSET"; fi
  exit 0
fi

if echo "\$url" | grep -q "raw.githubusercontent.com"; then
  filename=\$(basename "\$url")
  case "\$filename" in
    grok-shim.sh) src_path="$REPO_ROOT/src/shim/grok-shim.sh" ;;
    grokgod-cache.sh) src_path="$REPO_ROOT/src/grokgod-cache.sh" ;;
    grokgod-run.sh) src_path="$REPO_ROOT/src/grokgod-run.sh" ;;
    grokgod-pin.sh) src_path="$REPO_ROOT/src/grokgod-pin.sh" ;;
    *) src_path="" ;;
  esac
  if [ -n "\$src_path" ] && [ -f "\$src_path" ]; then
    if [ -n "\$out_file" ]; then cp "\$src_path" "\$out_file"; else cat "\$src_path"; fi
    exit 0
  fi
fi

echo "mock curl unhandled URL: \$url" >&2
exit 1
EOF
chmod +x "$FAKE_BIN_SHADOW/curl"

# Pre-populate with older stamp (v0.9.0)
mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "OLD_GROKGOD_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"

printf "SHA=old_sha\nPATCHSET=v0.9.0\nVERSION=v0.9.0\nMODE=release\n" > "$FAKE_GROKGOD_HOME/.source-version"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
BIN_DIR="$FAKE_BIN_DIR" \
sh "$INSTALL_SCRIPT" >/dev/null

# Asset MUST be downloaded
if ! grep -q "$TEST_ASSET" "$CURL_LOG"; then
  echo "FAIL: Test (m) - Asset download was not invoked for older stamp!"; exit 1
fi
NEW_STAMP_VER="$(grep '^VERSION=' "$FAKE_GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
if [ "$NEW_STAMP_VER" != "v1.0.0" ]; then
  echo "FAIL: Test (m) - Stamp was not updated to v1.0.0: $NEW_STAMP_VER"; exit 1
fi
echo "PASS: Test (m) - Release-mode update when older"

# ─────────────────────────────────────────────────────────
# Test (n): Release-mode API unreachable (fallback to 'latest') downloads
# ─────────────────────────────────────────────────────────
echo "Test (n): Release-mode API unreachable fallback"
setup_sandbox "test_n"

FAKE_DL_DIR="$TEST_DIR/fake_downloads"
mkdir -p "$FAKE_DL_DIR"
cat << 'BIN_EOF' > "$FAKE_DL_DIR/$TEST_ASSET"
#!/bin/sh
echo "LATEST_FALLBACK_BINARY"
BIN_EOF
chmod +x "$FAKE_DL_DIR/$TEST_ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  TEST_SHA="$(sha256sum "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  TEST_SHA="$(shasum -a 256 "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
else
  TEST_SHA="dummy_sha"
fi
printf "%s  %s\n" "$TEST_SHA" "$TEST_ASSET" > "$FAKE_DL_DIR/SHA256SUMS"

CURL_LOG="$TEST_DIR/curl_invocations.txt"
rm -f "$CURL_LOG"

cat << EOF > "$FAKE_BIN_SHADOW/curl"
#!/bin/sh
set -eu
url=""
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output)
      out_file="\$2"
      shift 2
      ;;
    -fsSL|-sSL|-s|-f|-L|-fsSLk)
      shift
      ;;
    http*|ftp*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "\$url" >> "$CURL_LOG"

# Fail the API call
if echo "\$url" | grep -q "/releases/latest"; then
  if echo "\$url" | grep -q "api.github.com"; then
    exit 1
  fi
fi

if echo "\$url" | grep -q "SHA256SUMS"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/SHA256SUMS" "\$out_file"; else cat "$FAKE_DL_DIR/SHA256SUMS"; fi
  exit 0
fi

if echo "\$url" | grep -q "$TEST_ASSET"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/$TEST_ASSET" "\$out_file"; else cat "$FAKE_DL_DIR/$TEST_ASSET"; fi
  exit 0
fi

if echo "\$url" | grep -q "raw.githubusercontent.com"; then
  filename=\$(basename "\$url")
  case "\$filename" in
    grok-shim.sh) src_path="$REPO_ROOT/src/shim/grok-shim.sh" ;;
    grokgod-cache.sh) src_path="$REPO_ROOT/src/grokgod-cache.sh" ;;
    grokgod-run.sh) src_path="$REPO_ROOT/src/grokgod-run.sh" ;;
    grokgod-pin.sh) src_path="$REPO_ROOT/src/grokgod-pin.sh" ;;
    *) src_path="" ;;
  esac
  if [ -n "\$src_path" ] && [ -f "\$src_path" ]; then
    if [ -n "\$out_file" ]; then cp "\$src_path" "\$out_file"; else cat "\$src_path"; fi
    exit 0
  fi
fi

echo "mock curl unhandled URL: \$url" >&2
exit 1
EOF
chmod +x "$FAKE_BIN_SHADOW/curl"

# Stamp with VERSION=latest and binary present
mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "EXISTING_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"
printf "SHA=%s\nPATCHSET=latest\nVERSION=latest\nMODE=release\n" "$TEST_SHA" > "$FAKE_GROKGOD_HOME/.source-version"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
BIN_DIR="$FAKE_BIN_DIR" \
sh "$INSTALL_SCRIPT" >/dev/null

# Fail-safe: download must still happen when tag resolved to literal latest
if ! grep -q "$TEST_ASSET" "$CURL_LOG"; then
  echo "FAIL: Test (n) - Asset download was not invoked during latest fallback!"; exit 1
fi
echo "PASS: Test (n) - Release-mode API unreachable fallback"

# ─────────────────────────────────────────────────────────
# Test (o): Release-mode --force with matching stamp downloads
# ─────────────────────────────────────────────────────────
echo "Test (o): Release-mode --force"
setup_sandbox "test_o"

FAKE_DL_DIR="$TEST_DIR/fake_downloads"
mkdir -p "$FAKE_DL_DIR"
cat << 'BIN_EOF' > "$FAKE_DL_DIR/$TEST_ASSET"
#!/bin/sh
echo "FORCE_DOWNLOADED_BINARY"
BIN_EOF
chmod +x "$FAKE_DL_DIR/$TEST_ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  TEST_SHA="$(sha256sum "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  TEST_SHA="$(shasum -a 256 "$FAKE_DL_DIR/$TEST_ASSET" | awk '{print $1}')"
else
  TEST_SHA="dummy_sha"
fi
printf "%s  %s\n" "$TEST_SHA" "$TEST_ASSET" > "$FAKE_DL_DIR/SHA256SUMS"

CURL_LOG="$TEST_DIR/curl_invocations.txt"
rm -f "$CURL_LOG"

cat << EOF > "$FAKE_BIN_SHADOW/curl"
#!/bin/sh
set -eu
url=""
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o|--output)
      out_file="\$2"
      shift 2
      ;;
    -fsSL|-sSL|-s|-f|-L|-fsSLk)
      shift
      ;;
    http*|ftp*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "\$url" >> "$CURL_LOG"

if echo "\$url" | grep -q "/releases/latest"; then
  cat << 'JSON_EOF'
{
  "tag_name": "v1.0.0",
  "assets": [
    {
      "name": "$TEST_ASSET",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/$TEST_ASSET"
    },
    {
      "name": "SHA256SUMS",
      "browser_download_url": "https://github.com/karlorz/grokgod/releases/download/v1.0.0/SHA256SUMS"
    }
  ]
}
JSON_EOF
  exit 0
fi

if echo "\$url" | grep -q "SHA256SUMS"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/SHA256SUMS" "\$out_file"; else cat "$FAKE_DL_DIR/SHA256SUMS"; fi
  exit 0
fi

if echo "\$url" | grep -q "$TEST_ASSET"; then
  if [ -n "\$out_file" ]; then cp "$FAKE_DL_DIR/$TEST_ASSET" "\$out_file"; else cat "$FAKE_DL_DIR/$TEST_ASSET"; fi
  exit 0
fi

if echo "\$url" | grep -q "raw.githubusercontent.com"; then
  filename=\$(basename "\$url")
  case "\$filename" in
    grok-shim.sh) src_path="$REPO_ROOT/src/shim/grok-shim.sh" ;;
    grokgod-cache.sh) src_path="$REPO_ROOT/src/grokgod-cache.sh" ;;
    grokgod-run.sh) src_path="$REPO_ROOT/src/grokgod-run.sh" ;;
    grokgod-pin.sh) src_path="$REPO_ROOT/src/grokgod-pin.sh" ;;
    *) src_path="" ;;
  esac
  if [ -n "\$src_path" ] && [ -f "\$src_path" ]; then
    if [ -n "\$out_file" ]; then cp "\$src_path" "\$out_file"; else cat "\$src_path"; fi
    exit 0
  fi
fi

echo "mock curl unhandled URL: \$url" >&2
exit 1
EOF
chmod +x "$FAKE_BIN_SHADOW/curl"

mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "EXISTING_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"
printf "SHA=%s\nPATCHSET=v1.0.0\nVERSION=v1.0.0\nMODE=release\n" "$TEST_SHA" > "$FAKE_GROKGOD_HOME/.source-version"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_HOME="$FAKE_GROK_HOME" \
BIN_DIR="$FAKE_BIN_DIR" \
sh "$INSTALL_SCRIPT" --force >/dev/null

if ! grep -q "$TEST_ASSET" "$CURL_LOG"; then
  echo "FAIL: Test (o) - Asset was not downloaded when --force passed!"; exit 1
fi
echo "PASS: Test (o) - Release-mode --force"

# ─────────────────────────────────────────────────────────
# Test (p): Source-mode no-op when stamp matches target and binary present
# ─────────────────────────────────────────────────────────
echo "Test (p): Source-mode no-op when stamp matches"
setup_sandbox "test_p"
reset_worktree

# Pre-populate fake grokgod binary and matching stamp
mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "EXISTING_SOURCE_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"

PATCHSET_HASH="$(cat "$REPO_ROOT/patches"/*.patch | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum 2>/dev/null) | awk '{print $1}')"

# Mock git wrapper to track invocations and simulate origin/main rev-parse
GIT_INVOKED_FILE="$TEST_DIR/git_invoked.txt"
rm -f "$GIT_INVOKED_FILE"
cat << EOF > "$FAKE_BIN_SHADOW/git"
#!/bin/sh
set -eu
echo "git \$*" >> "$GIT_INVOKED_FILE"
dir=""
if [ "\$1" = "-C" ]; then
  dir="\$2"
  shift 2
fi

if [ "\$1" = "fetch" ]; then
  exit 0
fi

if [ "\$1" = "rev-parse" ]; then
  case "\$*" in
    *"origin/main"*)
      echo "origin_main_target_sha_12345"
      exit 0
      ;;
  esac
fi

if [ -n "\$dir" ]; then
  exec /usr/bin/git -C "\$dir" "\$@"
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKE_BIN_SHADOW/git"

printf "SHA=origin_main_target_sha_12345\nPATCHSET=%s\nVERSION=origin_main_target_sha_12345\nMODE=source\n" "$PATCHSET_HASH" > "$FAKE_GROKGOD_HOME/.source-version"
INITIAL_STAMP="$(cat "$FAKE_GROKGOD_HOME/.source-version")"

rm -f "$CARGO_INVOKED_FILE"

# Plain run without --force or --no-upgrade (simulates grok update with matching resolved origin/main)
UPDATE_OUT="$(
  PATH="$FAKE_BIN_SHADOW:$PATH" \
  HOME="$FAKE_HOME" \
  GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
  GROK_BUILD_SRC="$GB_WORKTREE" \
  BIN_DIR="$FAKE_BIN_DIR" \
  CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
  sh "$INSTALL_SCRIPT" --from-source
)"

echo "$UPDATE_OUT" | grep -q "Already up to date" || {
  echo "FAIL: Test (p) - Missing 'Already up to date' in source update output: $UPDATE_OUT"; exit 1
}

if [ -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Test (p) - Cargo was invoked during source no-op!"; exit 1
fi

AFTER_STAMP="$(cat "$FAKE_GROKGOD_HOME/.source-version")"
if [ "$INITIAL_STAMP" != "$AFTER_STAMP" ]; then
  echo "FAIL: Test (p) - Stamp modified during source no-op!"; exit 1
fi
echo "PASS: Test (p) - Source-mode no-op"

# ─────────────────────────────────────────────────────────
# Test (q): Source-mode default checkout targets origin/main, never PINNED_BASE_SHA
# ─────────────────────────────────────────────────────────
echo "Test (q): Source-mode default checkout targets origin/main"
setup_sandbox "test_q"
reset_worktree

# Mock git wrapper to track invocations and shim fetch/rev-parse/checkout
GIT_INVOKED_FILE="$TEST_DIR/git_invoked.txt"
rm -f "$GIT_INVOKED_FILE"
cat << EOF > "$FAKE_BIN_SHADOW/git"
#!/bin/sh
set -eu
echo "git \$*" >> "$GIT_INVOKED_FILE"
dir=""
if [ "\$1" = "-C" ]; then
  dir="\$2"
  shift 2
fi

if [ "\$1" = "fetch" ]; then
  exit 0
fi

if [ "\$1" = "rev-parse" ]; then
  case "\$*" in
    *"origin/main"*)
      echo "origin_main_resolved_sha_67890"
      exit 0
      ;;
  esac
fi

if [ "\$1" = "checkout" ]; then
  case "\$*" in
    *"origin_main_resolved_sha_67890"*)
      if [ -n "\$dir" ]; then
        /usr/bin/git -C "\$dir" "\$@" 2>/dev/null && exit 0 || exit 0
      else
        /usr/bin/git "\$@" 2>/dev/null && exit 0 || exit 0
      fi
      ;;
  esac
fi

if [ -n "\$dir" ]; then
  exec /usr/bin/git -C "\$dir" "\$@"
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKE_BIN_SHADOW/git"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source >/dev/null

if grep -q "checkout d71f6e0c1f5acc5469e503e192fe14824e6f8c90" "$GIT_INVOKED_FILE"; then
  echo "FAIL: Test (q) - Git checked out PINNED_BASE_SHA instead of resolved origin/main!"; exit 1
fi
grep -q "checkout origin_main_resolved_sha_67890" "$GIT_INVOKED_FILE" || {
  echo "FAIL: Test (q) - Git did not checkout resolved origin/main SHA origin_main_resolved_sha_67890"; exit 1
}
echo "PASS: Test (q) - Default checkout targets origin/main"

# ─────────────────────────────────────────────────────────
# Test (r): Source-mode rebuilds when stamp SHA is different
# ─────────────────────────────────────────────────────────
echo "Test (r): Source-mode update when stamp SHA differs"
setup_sandbox "test_r"
reset_worktree

# Mock git wrapper to track invocations and shim fetch/rev-parse/cat-file/checkout on CI fixture
GIT_INVOKED_FILE="$TEST_DIR/git_invoked.txt"
rm -f "$GIT_INVOKED_FILE"
cat << EOF > "$FAKE_BIN_SHADOW/git"
#!/bin/sh
set -eu
echo "git \$*" >> "$GIT_INVOKED_FILE"
dir=""
if [ "\$1" = "-C" ]; then
  dir="\$2"
  shift 2
fi

if [ "\$1" = "fetch" ]; then
  exit 0
fi

if [ "\$1" = "rev-parse" ]; then
  case "\$*" in
    *"origin/main"*)
      echo "d71f6e0c1f5acc5469e503e192fe14824e6f8c90"
      exit 0
      ;;
  esac
fi

if [ "\$1" = "cat-file" ]; then
  case "\$*" in
    *"d71f6e0c1f5acc5469e503e192fe14824e6f8c90"*)
      if [ -n "\$dir" ]; then
        /usr/bin/git -C "\$dir" "\$@" 2>/dev/null && exit 0 || exit 0
      else
        /usr/bin/git "\$@" 2>/dev/null && exit 0 || exit 0
      fi
      ;;
  esac
fi

if [ "\$1" = "checkout" ]; then
  case "\$*" in
    *"d71f6e0c1f5acc5469e503e192fe14824e6f8c90"*)
      if [ -n "\$dir" ]; then
        /usr/bin/git -C "\$dir" "\$@" 2>/dev/null && exit 0 || exit 0
      else
        /usr/bin/git "\$@" 2>/dev/null && exit 0 || exit 0
      fi
      ;;
  esac
fi

if [ -n "\$dir" ]; then
  exec /usr/bin/git -C "\$dir" "\$@"
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKE_BIN_SHADOW/git"

mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "OLD_SOURCE_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"
printf "SHA=oldsha1234567890\nPATCHSET=none\nVERSION=oldsha1234567890\nMODE=source\n" > "$FAKE_GROKGOD_HOME/.source-version"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source >/dev/null

if [ ! -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Test (r) - Cargo was not invoked when stamp SHA differed!"; exit 1
fi
echo "PASS: Test (r) - Source-mode rebuilds on different stamp"

# ─────────────────────────────────────────────────────────
# Test (s): Source-mode --force rebuilds with matching stamp
# ─────────────────────────────────────────────────────────
echo "Test (s): Source-mode --force"
setup_sandbox "test_s"
reset_worktree

# Mock git wrapper to track invocations and shim fetch/rev-parse/cat-file/checkout on CI fixture
GIT_INVOKED_FILE="$TEST_DIR/git_invoked.txt"
rm -f "$GIT_INVOKED_FILE"
cat << EOF > "$FAKE_BIN_SHADOW/git"
#!/bin/sh
set -eu
echo "git \$*" >> "$GIT_INVOKED_FILE"
dir=""
if [ "\$1" = "-C" ]; then
  dir="\$2"
  shift 2
fi

if [ "\$1" = "fetch" ]; then
  exit 0
fi

if [ "\$1" = "rev-parse" ]; then
  case "\$*" in
    *"origin/main"*)
      echo "d71f6e0c1f5acc5469e503e192fe14824e6f8c90"
      exit 0
      ;;
  esac
fi

if [ "\$1" = "cat-file" ]; then
  case "\$*" in
    *"d71f6e0c1f5acc5469e503e192fe14824e6f8c90"*)
      if [ -n "\$dir" ]; then
        /usr/bin/git -C "\$dir" "\$@" 2>/dev/null && exit 0 || exit 0
      else
        /usr/bin/git "\$@" 2>/dev/null && exit 0 || exit 0
      fi
      ;;
  esac
fi

if [ "\$1" = "checkout" ]; then
  case "\$*" in
    *"d71f6e0c1f5acc5469e503e192fe14824e6f8c90"*)
      if [ -n "\$dir" ]; then
        /usr/bin/git -C "\$dir" "\$@" 2>/dev/null && exit 0 || exit 0
      else
        /usr/bin/git "\$@" 2>/dev/null && exit 0 || exit 0
      fi
      ;;
  esac
fi

if [ -n "\$dir" ]; then
  exec /usr/bin/git -C "\$dir" "\$@"
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$FAKE_BIN_SHADOW/git"

# Pre-populate matching stamp and binary
mkdir -p "$FAKE_GROKGOD_HOME/bin"
cat << 'BIN_EOF' > "$FAKE_GROKGOD_HOME/bin/grok"
#!/bin/sh
echo "EXISTING_SOURCE_BINARY"
BIN_EOF
chmod +x "$FAKE_GROKGOD_HOME/bin/grok"

PATCHSET_HASH="$(cat "$REPO_ROOT/patches"/*.patch | (shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum 2>/dev/null) | awk '{print $1}')"
printf "SHA=d71f6e0c1f5acc5469e503e192fe14824e6f8c90\nPATCHSET=%s\nVERSION=d71f6e0c1f5acc5469e503e192fe14824e6f8c90\nMODE=source\n" "$PATCHSET_HASH" > "$FAKE_GROKGOD_HOME/.source-version"

rm -f "$CARGO_INVOKED_FILE"

# Run with --force
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --force >/dev/null

if [ ! -f "$CARGO_INVOKED_FILE" ]; then
  echo "FAIL: Test (s) - Cargo was not invoked when --force was passed!"; exit 1
fi
echo "PASS: Test (s) - Source-mode --force"

# ─────────────────────────────────────────────────────────
# Test (t): Drift guard between install.sh and patches/README.md
# ─────────────────────────────────────────────────────────
echo "Test (t): Drift guard"
PIN_IN_INSTALL="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_IN_INSTALL" ]; then
  echo "FAIL: Test (t) - PINNED_BASE_SHA not found in $INSTALL_SCRIPT"; exit 1
fi
grep -q "$PIN_IN_INSTALL" "$REPO_ROOT/patches/README.md" || {
  echo "FAIL: Test (t) - PINNED_BASE_SHA ($PIN_IN_INSTALL) not found in patches/README.md"; exit 1
}
echo "PASS: Test (t) - Drift guard"

# ─────────────────────────────────────────────────────────
# Test (u): Pin overlay skipped on no TTY and no --yes
# ─────────────────────────────────────────────────────────
echo "Test (u): Pin overlay skipped on no TTY and no --yes"
setup_sandbox "test_u"
reset_worktree

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade >/dev/null

if [ -e "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml" ]; then
  echo "FAIL: Test (u) - Pin overlay should not be created without --yes on non-TTY"; exit 1
fi
echo "PASS: Test (u) - Pin overlay skipped on no TTY"

# ─────────────────────────────────────────────────────────
# Test (v): Pin overlay created with --yes
# ─────────────────────────────────────────────────────────
echo "Test (v): Pin overlay created with --yes"
setup_sandbox "test_v"
reset_worktree

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade --yes >/dev/null

if [ ! -f "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml" ]; then
  echo "FAIL: Test (v) - Pin overlay was not created with --yes"; exit 1
fi
if ! grep -q '\[models\]' "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml"; then
  echo "FAIL: Test (v) - Pin overlay content missing expected models section"; exit 1
fi
echo "PASS: Test (v) - Pin overlay created with --yes"

# ─────────────────────────────────────────────────────────
# Test (w): Pin overlay preserved if already exists even with --yes
# ─────────────────────────────────────────────────────────
echo "Test (w): Pin overlay preserved if already exists"
setup_sandbox "test_w"
reset_worktree

mkdir -p "$FAKE_GROKGOD_HOME/pin"
echo "CUSTOM_PREEXISTING_PIN_OVERLAY" > "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml"

PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade --yes >/dev/null

PIN_CONTENT="$(cat "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml")"
if [ "$PIN_CONTENT" != "CUSTOM_PREEXISTING_PIN_OVERLAY" ]; then
  echo "FAIL: Test (w) - Existing pin overlay was overwritten: $PIN_CONTENT"; exit 1
fi
echo "PASS: Test (w) - Existing pin overlay preserved"

# ─────────────────────────────────────────────────────────
# Test (x): Pin overlay created under --prefix with --yes
# ─────────────────────────────────────────────────────────
echo "Test (x): Pin overlay with --prefix and --yes"
setup_sandbox "test_x"
reset_worktree

PREFIX_TARGET="$TEST_DIR/custom_prefix"
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade --prefix "$PREFIX_TARGET" --yes >/dev/null

if [ ! -f "$PREFIX_TARGET/grokgod/pin/grok-overlay.toml" ]; then
  echo "FAIL: Test (x) - Pin overlay was not created under prefix grokgod home"; exit 1
fi
echo "PASS: Test (x) - Pin overlay with --prefix and --yes"

# ─────────────────────────────────────────────────────────
# Test (y): Uninstall does not delete PIN overlay if user keeps or leaves it
# ─────────────────────────────────────────────────────────
echo "Test (y): Pin overlay dry-run and uninstall safety"
setup_sandbox "test_y"
reset_worktree

# Install with --yes
PATH="$FAKE_BIN_SHADOW:$PATH" \
HOME="$FAKE_HOME" \
GROKGOD_HOME="$FAKE_GROKGOD_HOME" \
GROK_BUILD_SRC="$GB_WORKTREE" \
BIN_DIR="$FAKE_BIN_DIR" \
CARGO_TARGET_DIR="$FAKE_CARGO_TARGET_DIR" \
sh "$INSTALL_SCRIPT" --from-source --no-upgrade --dry-run --yes >/dev/null

if [ -e "$FAKE_GROKGOD_HOME/pin/grok-overlay.toml" ]; then
  echo "FAIL: Test (y) - Dry-run should not create pin overlay"; exit 1
fi
echo "PASS: Test (y) - Pin overlay dry-run safety"

echo "=== All install.sh tests passed successfully! ==="
