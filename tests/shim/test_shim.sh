#!/bin/sh
set -eu

# Isolate from a host Orca grok session that may export GROK_CONFIG_PATH.
unset GROK_CONFIG_PATH GROK_CONFIG ORCA_WORKTREE_ID ORCA_WORKSPACE_ID || true

# test_shim.sh: Standalone tests for grok-shim.sh
# Requires NO root, does NOT touch real ~/.local/bin or ~/.grokgod.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

if [ ! -f "$SHIM_SRC" ]; then
  echo "FAIL: shim not found at $SHIM_SRC" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# Set up test environment inside TMP_DIR
TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
TEST_GROKGOD_SRC="$TMP_DIR/grokgod_repo"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_GROKGOD_SRC" "$TEST_HOME/.local/bin"

# 1. Setup fake grok binary in TEST_GROKGOD_HOME/bin/grok
FAKE_BIN="$TEST_GROKGOD_HOME/bin/grok"
INVOCATION_COUNT_FILE="$TMP_DIR/fake_bin_invocations.txt"
echo "0" > "$INVOCATION_COUNT_FILE"

cat << 'EOF' > "$FAKE_BIN"
#!/bin/sh
set -eu
count=$(cat "$TMP_DIR/fake_bin_invocations.txt")
echo "$((count + 1))" > "$TMP_DIR/fake_bin_invocations.txt"
echo "FAKE_BIN_CALLED"
echo "GROK_DISABLE_AUTOUPDATER=${GROK_DISABLE_AUTOUPDATER:-NOT_SET}"
echo "ARGS:$*"
EOF
chmod +x "$FAKE_BIN"

# Helper to run the shim with fake env
run_shim() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  GROK_BUILD_SRC="${TEST_GROK_BUILD_SRC:-$TMP_DIR/nonexistent_grok_build}" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" "$@"
}

echo "=== Running Shim Tests ==="

# Test 1: Passthrough with flags and env var check
echo "Test 1: Passthrough with arguments and auto-updater disable check"
echo "0" > "$INVOCATION_COUNT_FILE"
OUT="$(run_shim hello --flag "arg with spaces")"
echo "$OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: Fake bin was not called"; exit 1; }
echo "$OUT" | grep -q "GROK_DISABLE_AUTOUPDATER=1" || { echo "FAIL: GROK_DISABLE_AUTOUPDATER=1 not visible in target"; exit 1; }
echo "$OUT" | grep -q "ARGS:hello --flag arg with spaces" || { echo "FAIL: Arguments not preserved ($OUT)"; exit 1; }
INV_COUNT="$(cat "$INVOCATION_COUNT_FILE")"
if [ "$INV_COUNT" -ne 1 ]; then
  echo "FAIL: Expected 1 invocation, got $INV_COUNT"; exit 1
fi
echo "PASS: Test 1"

# Test 2: Update dispatch to install.sh (including arguments and exit code)
echo "Test 2: Update dispatch"
cat << 'EOF' > "$TEST_GROKGOD_SRC/install.sh"
#!/bin/sh
echo "INSTALL_CALLED:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/install.sh"

UPDATE_OUT="$(run_shim update --release v1.0)"
echo "$UPDATE_OUT" | grep -q "INSTALL_CALLED:--release v1.0" || { echo "FAIL: install.sh not called with args ($UPDATE_OUT)"; exit 1; }

# Test 2b: Update dispatch exit code passthrough (e.g. failing with 42)
cat << 'EOF' > "$TEST_GROKGOD_SRC/install.sh"
#!/bin/sh
exit 42
EOF
chmod +x "$TEST_GROKGOD_SRC/install.sh"

set +e
run_shim update
STATUS_CODE=$?
set -eu
if [ "$STATUS_CODE" -ne 42 ]; then
  echo "FAIL: Expected exit code 42 from install.sh, got $STATUS_CODE"; exit 1
fi

# Test 2c: update ff-only pulls a behind GROKGOD_SRC git repo before exec
echo "Test 2c: Update ff-only pulls behind GROKGOD_SRC"
SHIM_ORIGIN="$TMP_DIR/shim_origin"
SHIM_BEHIND="$TMP_DIR/shim_behind"
mkdir -p "$SHIM_ORIGIN"
git -C "$SHIM_ORIGIN" init -b main >/dev/null 2>&1
git -C "$SHIM_ORIGIN" config user.name "CI"
git -C "$SHIM_ORIGIN" config user.email "ci@example.com"
printf '%s\n' '#!/bin/sh' 'echo INSTALL_OLD' > "$SHIM_ORIGIN/install.sh"
chmod +x "$SHIM_ORIGIN/install.sh"
git -C "$SHIM_ORIGIN" add install.sh
git -C "$SHIM_ORIGIN" commit -m "old src" >/dev/null 2>&1
OLD_SHIM_SHA="$(git -C "$SHIM_ORIGIN" rev-parse HEAD)"
printf '%s\n' '#!/bin/sh' 'echo INSTALL_NEW' > "$SHIM_ORIGIN/install.sh"
git -C "$SHIM_ORIGIN" add install.sh
git -C "$SHIM_ORIGIN" commit -m "new src" >/dev/null 2>&1
git clone --quiet "$SHIM_ORIGIN" "$SHIM_BEHIND"
git -C "$SHIM_BEHIND" reset --hard "$OLD_SHIM_SHA" >/dev/null 2>&1
SHIM_PULL_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$SHIM_BEHIND" \
  GROK_BUILD_SRC="${TEST_GROK_BUILD_SRC:-$TMP_DIR/nonexistent_grok_build}" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" update
)"
echo "$SHIM_PULL_OUT" | grep -q "INSTALL_NEW" || {
  echo "FAIL: Test 2c - expected pulled install.sh ($SHIM_PULL_OUT)"; exit 1
}
echo "$SHIM_PULL_OUT" | grep -q "INSTALL_OLD" && {
  echo "FAIL: Test 2c - ran stale src install.sh ($SHIM_PULL_OUT)"; exit 1
}
echo "PASS: Test 2"
echo "PASS: Test 2c"

# Test 2d: behind clone whose tracked file is dirty but byte-identical to origin/main,
# plus an untracked file that matches a file origin added, plus an untracked file origin does not have.
echo "Test 2d: Update dirty tracked match + blocker match + unique untracked"
SHIM_ORIGIN_2D="$TMP_DIR/shim_origin_2d"
SHIM_BEHIND_2D="$TMP_DIR/shim_behind_2d"
mkdir -p "$SHIM_ORIGIN_2D"
git -C "$SHIM_ORIGIN_2D" init -b main >/dev/null 2>&1
git -C "$SHIM_ORIGIN_2D" config user.name "CI"
git -C "$SHIM_ORIGIN_2D" config user.email "ci@example.com"
printf '%s\n' '#!/bin/sh' 'echo INSTALL_OLD' > "$SHIM_ORIGIN_2D/install.sh"
printf '%s\n' 'tracked old' > "$SHIM_ORIGIN_2D/tracked.txt"
chmod +x "$SHIM_ORIGIN_2D/install.sh"
git -C "$SHIM_ORIGIN_2D" add install.sh tracked.txt
git -C "$SHIM_ORIGIN_2D" commit -m "old src" >/dev/null 2>&1
OLD_SHIM_2D_SHA="$(git -C "$SHIM_ORIGIN_2D" rev-parse HEAD)"

printf '%s\n' '#!/bin/sh' 'echo INSTALL_NEW' > "$SHIM_ORIGIN_2D/install.sh"
printf '%s\n' 'tracked new' > "$SHIM_ORIGIN_2D/tracked.txt"
printf '%s\n' 'blocker from origin' > "$SHIM_ORIGIN_2D/blocker.txt"
git -C "$SHIM_ORIGIN_2D" add install.sh tracked.txt blocker.txt
git -C "$SHIM_ORIGIN_2D" commit -m "new src" >/dev/null 2>&1
ORIGIN_2D_SHA="$(git -C "$SHIM_ORIGIN_2D" rev-parse HEAD)"

git clone --quiet "$SHIM_ORIGIN_2D" "$SHIM_BEHIND_2D"
git -C "$SHIM_BEHIND_2D" reset --hard "$OLD_SHIM_2D_SHA" >/dev/null 2>&1

# Tracked file dirty but byte-identical to origin/main
printf '%s\n' 'tracked new' > "$SHIM_BEHIND_2D/tracked.txt"
# Untracked file that matches a file origin added
printf '%s\n' 'blocker from origin' > "$SHIM_BEHIND_2D/blocker.txt"
# Untracked file origin does not have
printf '%s\n' 'unique eval notes' > "$SHIM_BEHIND_2D/deepseek-eval.md"

SHIM_2D_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$SHIM_BEHIND_2D" \
  GROK_BUILD_SRC="${TEST_GROK_BUILD_SRC:-$TMP_DIR/nonexistent_grok_build}" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" update
)"
echo "$SHIM_2D_OUT" | grep -q "INSTALL_NEW" || {
  echo "FAIL: Test 2d - expected pulled install.sh ($SHIM_2D_OUT)"; exit 1
}
echo "$SHIM_2D_OUT" | grep -q "INSTALL_OLD" && {
  echo "FAIL: Test 2d - ran stale src install.sh ($SHIM_2D_OUT)"; exit 1
}
SHIM_2D_HEAD="$(git -C "$SHIM_BEHIND_2D" rev-parse HEAD)"
if [ "$SHIM_2D_HEAD" != "$ORIGIN_2D_SHA" ]; then
  echo "FAIL: Test 2d - HEAD ($SHIM_2D_HEAD) does not equal origin ($ORIGIN_2D_SHA)"; exit 1
fi
if [ ! -f "$SHIM_BEHIND_2D/deepseek-eval.md" ] || [ "$(cat "$SHIM_BEHIND_2D/deepseek-eval.md")" != "unique eval notes" ]; then
  echo "FAIL: Test 2d - unique untracked file was lost or corrupted"; exit 1
fi
echo "PASS: Test 2d"

# Test 2e: behind clone, one tracked file differs from origin. update exits non-zero,
# does not print INSTALL_NEW, the differing bytes are still in the file, HEAD is still the old commit.
echo "Test 2e: Update differing tracked file fails closed"
SHIM_BEHIND_2E="$TMP_DIR/shim_behind_2e"
git clone --quiet "$SHIM_ORIGIN_2D" "$SHIM_BEHIND_2E"
git -C "$SHIM_BEHIND_2E" reset --hard "$OLD_SHIM_2D_SHA" >/dev/null 2>&1
printf '%s\n' 'local differing tracked edit' > "$SHIM_BEHIND_2E/tracked.txt"

set +e
SHIM_2E_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$SHIM_BEHIND_2E" \
  GROK_BUILD_SRC="${TEST_GROK_BUILD_SRC:-$TMP_DIR/nonexistent_grok_build}" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" update 2>&1
)"
SHIM_2E_STATUS=$?
set -eu
if [ "$SHIM_2E_STATUS" -eq 0 ]; then
  echo "FAIL: Test 2e - expected non-zero exit from shim update ($SHIM_2E_OUT)"; exit 1
fi
echo "$SHIM_2E_OUT" | grep -q "INSTALL_NEW" && {
  echo "FAIL: Test 2e - unexpectedly ran new install.sh ($SHIM_2E_OUT)"; exit 1
}
echo "$SHIM_2E_OUT" | grep -q "grokgod: src differs from origin/main: tracked.txt" || {
  echo "FAIL: Test 2e - missing expected differing message ($SHIM_2E_OUT)"; exit 1
}
if [ "$(cat "$SHIM_BEHIND_2E/tracked.txt")" != "local differing tracked edit" ]; then
  echo "FAIL: Test 2e - differing tracked file modified"; exit 1
fi
SHIM_2E_HEAD="$(git -C "$SHIM_BEHIND_2E" rev-parse HEAD)"
if [ "$SHIM_2E_HEAD" != "$OLD_SHIM_2D_SHA" ]; then
  echo "FAIL: Test 2e - HEAD modified from old commit ($SHIM_2E_HEAD vs $OLD_SHIM_2D_SHA)"; exit 1
fi
echo "PASS: Test 2e"

# Test 2f: behind clone plus one local commit not on origin. update exits non-zero,
# that commit is still HEAD, no reset.
echo "Test 2f: Update behind clone with local commits fails closed"
SHIM_BEHIND_2F="$TMP_DIR/shim_behind_2f"
git clone --quiet "$SHIM_ORIGIN_2D" "$SHIM_BEHIND_2F"
git -C "$SHIM_BEHIND_2F" reset --hard "$OLD_SHIM_2D_SHA" >/dev/null 2>&1
printf '%s\n' 'local unique commit' > "$SHIM_BEHIND_2F/local_file.txt"
git -C "$SHIM_BEHIND_2F" add local_file.txt
git -C "$SHIM_BEHIND_2F" commit -m "local commit" >/dev/null 2>&1
LOCAL_2F_SHA="$(git -C "$SHIM_BEHIND_2F" rev-parse HEAD)"

set +e
SHIM_2F_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$SHIM_BEHIND_2F" \
  GROK_BUILD_SRC="${TEST_GROK_BUILD_SRC:-$TMP_DIR/nonexistent_grok_build}" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" update 2>&1
)"
SHIM_2F_STATUS=$?
set -eu
if [ "$SHIM_2F_STATUS" -eq 0 ]; then
  echo "FAIL: Test 2f - expected non-zero exit from shim update ($SHIM_2F_OUT)"; exit 1
fi
echo "$SHIM_2F_OUT" | grep -q "INSTALL_NEW" && {
  echo "FAIL: Test 2f - unexpectedly ran new install.sh ($SHIM_2F_OUT)"; exit 1
}
echo "$SHIM_2F_OUT" | grep -q "grokgod: src has local commits (not fast-forward)" || {
  echo "FAIL: Test 2f - missing expected local commits message ($SHIM_2F_OUT)"; exit 1
}
SHIM_2F_HEAD="$(git -C "$SHIM_BEHIND_2F" rev-parse HEAD)"
if [ "$SHIM_2F_HEAD" != "$LOCAL_2F_SHA" ]; then
  echo "FAIL: Test 2f - HEAD changed from local commit ($SHIM_2F_HEAD vs $LOCAL_2F_SHA)"; exit 1
fi
echo "PASS: Test 2f"

# Test 3: Status subcommand
echo "Test 3: Status subcommand"
echo "v1.0.0-test" > "$TEST_GROKGOD_HOME/.source-version"
# Put a fake GROKGOD shim at ~/.local/bin/grok
echo "# GROKGOD shim" > "$TEST_HOME/.local/bin/grok"

STATUS_OUT="$(run_shim status)"
echo "$STATUS_OUT" | grep -q "target binary: $TEST_GROKGOD_HOME/bin/grok" || { echo "FAIL: status output missing target binary"; exit 1; }
echo "$STATUS_OUT" | grep -q "target binary exists: yes" || { echo "FAIL: status output missing exists check"; exit 1; }
echo "$STATUS_OUT" | grep -q "source-version: v1.0.0-test" || { echo "FAIL: status output missing source-version"; exit 1; }
echo "$STATUS_OUT" | grep -q "~/.local/bin/grok is grokgod shim: yes" || { echo "FAIL: status output missing shim check"; exit 1; }
echo "$STATUS_OUT" | grep -q "free disk:" || { echo "FAIL: status output missing free disk"; exit 1; }
echo "$STATUS_OUT" | grep -q "source-drift: unknown" || { echo "FAIL: status output missing source-drift: unknown ($STATUS_OUT)"; exit 1; }
echo "PASS: Test 3"

# Test 4: Missing binary check
echo "Test 4: Missing binary handling"
MISSING_GROKGOD_HOME="$TMP_DIR/nonexistent_grokgod_home"
set +e
MISSING_ERR="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$MISSING_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  sh "$SHIM_SRC" some-command 2>&1
)"
MISSING_STATUS=$?
set -eu
if [ "$MISSING_STATUS" -ne 127 ]; then
  echo "FAIL: Expected exit code 127 on missing binary, got $MISSING_STATUS"; exit 1
fi
echo "$MISSING_ERR" | grep -i -q "grokgod update" || { echo "FAIL: Stderr did not mention 'grokgod update' ($MISSING_ERR)"; exit 1; }
echo "PASS: Test 4"

# Test 5: Cache dispatch
echo "Test 5: Cache dispatch"
# 5a: When grokgod-cache.sh does not exist
set +e
CACHE_ERR="$(run_shim cache 2>&1)"
CACHE_STATUS=$?
set -eu
if [ "$CACHE_STATUS" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 when grokgod-cache.sh not found, got $CACHE_STATUS"; exit 1
fi
echo "$CACHE_ERR" | grep -q "grokgod cache not installed" || { echo "FAIL: Unexpected cache missing message ($CACHE_ERR)"; exit 1; }

# 5b: When grokgod-cache.sh exists
mkdir -p "$TEST_GROKGOD_SRC/src"
cat << 'EOF' > "$TEST_GROKGOD_SRC/src/grokgod-cache.sh"
#!/bin/sh
echo "CACHE_SCRIPT_CALLED:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/src/grokgod-cache.sh"

CACHE_OUT="$(run_shim cache --clean)"
echo "$CACHE_OUT" | grep -q "CACHE_SCRIPT_CALLED:--clean" || { echo "FAIL: grokgod-cache.sh not called properly ($CACHE_OUT)"; exit 1; }

# 5c: Pin dispatch when grokgod-pin.sh missing
set +e
PIN_ERR="$(run_shim pin check 2>&1)"
PIN_STATUS=$?
set -eu
if [ "$PIN_STATUS" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 when grokgod-pin.sh not found, got $PIN_STATUS"; exit 1
fi
echo "$PIN_ERR" | grep -q "grokgod pin not installed" || { echo "FAIL: Unexpected pin missing message ($PIN_ERR)"; exit 1; }

# 5d: Pin dispatch when grokgod-pin.sh exists
cat << 'EOF' > "$TEST_GROKGOD_SRC/src/grokgod-pin.sh"
#!/bin/sh
echo "PIN_SCRIPT_CALLED:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/src/grokgod-pin.sh"

PIN_OUT="$(run_shim pin check --expect-default test)"
echo "$PIN_OUT" | grep -q "PIN_SCRIPT_CALLED:check --expect-default test" || { echo "FAIL: grokgod-pin.sh not called properly ($PIN_OUT)"; exit 1; }
echo "PASS: Test 5"

# Test 6: No PATH recursion / Absolute path exec check
echo "Test 6: No PATH recursion verification"
echo "0" > "$INVOCATION_COUNT_FILE"
# Shadow grok on PATH with a recursive trap that fails if executed
PATH_SHADOW_DIR="$TMP_DIR/path_shadow"
mkdir -p "$PATH_SHADOW_DIR"
cat << 'EOF' > "$PATH_SHADOW_DIR/grok"
#!/bin/sh
echo "FAIL: PATH lookup was invoked for grok!" >&2
exit 99
EOF
chmod +x "$PATH_SHADOW_DIR/grok"

OUT_PATH_TEST="$(
  PATH="$PATH_SHADOW_DIR:$PATH" \
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  sh "$SHIM_SRC" test-recursion
)"
echo "$OUT_PATH_TEST" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: Target binary not called"; exit 1; }
INV_COUNT="$(cat "$INVOCATION_COUNT_FILE")"
if [ "$INV_COUNT" -ne 1 ]; then
  echo "FAIL: Target binary was called $INV_COUNT times, expected exactly 1"; exit 1
fi
echo "PASS: Test 6"

# Test 7: Status persist inventory block
echo "Test 7: Status persist inventory block"
# 7a: applied and wrapper
printf "SHA=fake\nPATCHSET=v1.0.3\nVERSION=v1.0.3\nMODE=source\n" > "$TEST_GROKGOD_HOME/.source-version"
mkdir -p "$TEST_GROKGOD_SRC/src"
touch "$TEST_GROKGOD_SRC/src/grokgod-run.sh"

STATUS_PERSIST_OUT="$(run_shim status)"
echo "$STATUS_PERSIST_OUT" | grep -q "^persist:" || { echo "FAIL: status output missing persist header ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0001-normalize-plugin-skill-join: applied" || { echo "FAIL: status output missing applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0002-plan-mode-extra-writable: applied" || { echo "FAIL: status output missing 0002 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0003-session-persist-single: applied" || { echo "FAIL: status output missing 0003 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0004-disable-builtin-deep-research: applied" || { echo "FAIL: status output missing 0004 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0005-model-tools-deny-allow: applied" || { echo "FAIL: status output missing 0005 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0006-web-search-call-tolerant-parse: applied" || { echo "FAIL: status output missing 0006 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0007-hosted-web-search-splice-decouple: applied" || { echo "FAIL: status output missing 0007 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0008-claude-permissions-import-gate: applied" || { echo "FAIL: status output missing 0008 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0009-deepseek-chat-fix: applied" || { echo "FAIL: status output missing 0009 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0010-deepseek-chat-compact-lenient: applied" || { echo "FAIL: status output missing 0010 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0011-ask-question-timeout-action: applied" || { echo "FAIL: status output missing 0011 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0012-protoc-dependency-output-portable: applied" || { echo "FAIL: status output missing 0012 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0013-same-session-compaction-warning: applied" || { echo "FAIL: status output missing 0013 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0014-deepseek-tool-image-hoist: applied" || { echo "FAIL: status output missing 0014 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  0015-cli-model-ephemeral: applied" || { echo "FAIL: status output missing 0015 applied patch ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  overlay-pin: wrapper" || { echo "FAIL: status output missing overlay-pin wrapper ($STATUS_PERSIST_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  eval-home: missing" || { echo "FAIL: status output missing eval-home missing before touch ($STATUS_PERSIST_OUT)"; exit 1; }
touch "$TEST_GROKGOD_SRC/src/grokgod-eval.sh"
STATUS_EVAL_OUT="$(run_shim status)"
echo "$STATUS_EVAL_OUT" | grep -q "  eval-home: wrapper" || { echo "FAIL: status output missing eval-home wrapper ($STATUS_EVAL_OUT)"; exit 1; }
echo "$STATUS_PERSIST_OUT" | grep -q "  weekly-pin: global-default" || { echo "FAIL: status output missing weekly-pin ($STATUS_PERSIST_OUT)"; exit 1; }

# 7b: missing and missing
rm -f "$TEST_GROKGOD_HOME/.source-version" "$TEST_GROKGOD_SRC/src/grokgod-run.sh" "$TEST_GROKGOD_SRC/src/grokgod-eval.sh"
STATUS_MISSING_OUT="$(run_shim status)"
echo "$STATUS_MISSING_OUT" | grep -q "^persist:" || { echo "FAIL: status output missing persist header ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0001-normalize-plugin-skill-join: missing" || { echo "FAIL: status output missing patch missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0002-plan-mode-extra-writable: missing" || { echo "FAIL: status output missing 0002 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0003-session-persist-single: missing" || { echo "FAIL: status output missing 0003 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0004-disable-builtin-deep-research: missing" || { echo "FAIL: status output missing 0004 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0005-model-tools-deny-allow: missing" || { echo "FAIL: status output missing 0005 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0006-web-search-call-tolerant-parse: missing" || { echo "FAIL: status output missing 0006 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0007-hosted-web-search-splice-decouple: missing" || { echo "FAIL: status output missing 0007 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0008-claude-permissions-import-gate: missing" || { echo "FAIL: status output missing 0008 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0009-deepseek-chat-fix: missing" || { echo "FAIL: status output missing 0009 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0010-deepseek-chat-compact-lenient: missing" || { echo "FAIL: status output missing 0010 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0011-ask-question-timeout-action: missing" || { echo "FAIL: status output missing 0011 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0012-protoc-dependency-output-portable: missing" || { echo "FAIL: status output missing 0012 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0013-same-session-compaction-warning: missing" || { echo "FAIL: status output missing 0013 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0014-deepseek-tool-image-hoist: missing" || { echo "FAIL: status output missing 0014 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  0015-cli-model-ephemeral: missing" || { echo "FAIL: status output missing 0015 missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  overlay-pin: missing" || { echo "FAIL: status output missing overlay-pin missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  eval-home: missing" || { echo "FAIL: status output missing eval-home missing state ($STATUS_MISSING_OUT)"; exit 1; }
echo "$STATUS_MISSING_OUT" | grep -q "  weekly-pin: global-default" || { echo "FAIL: status output missing weekly-pin ($STATUS_MISSING_OUT)"; exit 1; }
echo "PASS: Test 7"

echo "Test 8: argv0 sessions — grok passthrough, grokgod wrapper"
mkdir -p "$TEST_GROKGOD_SRC/src"
cat << 'EOF' > "$TEST_GROKGOD_SRC/src/grokgod-sessions.sh"
#!/bin/sh
echo "SESSIONS_WRAPPER:$*"
exit 0
EOF
chmod +x "$TEST_GROKGOD_SRC/src/grokgod-sessions.sh"
BIND="$TMP_DIR/argv0bin"
mkdir -p "$BIND"
cp "$SHIM_SRC" "$BIND/grok"
cp "$SHIM_SRC" "$BIND/grokgod"
chmod +x "$BIND/grok" "$BIND/grokgod"

echo "0" > "$INVOCATION_COUNT_FILE"
GROK_SESS_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  TMP_DIR="$TMP_DIR" \
  "$BIND/grok" sessions list --limit 2
)"
echo "$GROK_SESS_OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: grok sessions did not reach binary ($GROK_SESS_OUT)"; exit 1; }
echo "$GROK_SESS_OUT" | grep -q "ARGS:sessions list --limit 2" || { echo "FAIL: grok sessions args lost ($GROK_SESS_OUT)"; exit 1; }
echo "$GROK_SESS_OUT" | grep -q "SESSIONS_WRAPPER" && { echo "FAIL: grok sessions hit wrapper ($GROK_SESS_OUT)"; exit 1; }

GOD_SESS_OUT="$(
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="$TEST_GROKGOD_SRC" \
  "$BIND/grokgod" sessions prune --help
)"
echo "$GOD_SESS_OUT" | grep -q "SESSIONS_WRAPPER:prune --help" || { echo "FAIL: grokgod sessions missed wrapper ($GOD_SESS_OUT)"; exit 1; }
echo "$GOD_SESS_OUT" | grep -q "FAKE_BIN_CALLED" && { echo "FAIL: grokgod sessions hit grok binary ($GOD_SESS_OUT)"; exit 1; }
echo "PASS: Test 8"

# Test 9: Source drift status and --version / -V warning
echo "Test 9: Source drift detection"
FAKE_REPO="$TMP_DIR/fake_grok_build"
mkdir -p "$FAKE_REPO"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" config user.email "test@example.com"
git -C "$FAKE_REPO" config user.name "Test User"
git -C "$FAKE_REPO" config commit.gpgsign false

mkdir -p "$FAKE_REPO/crates/codegen/xai-grok-pager-bin"
cat << 'EOF' > "$FAKE_REPO/crates/codegen/xai-grok-pager-bin/Cargo.toml"
[package]
name = "xai-grok-pager-bin"
version = "1.0.8"
EOF
git -C "$FAKE_REPO" add .
git -C "$FAKE_REPO" commit -q -m "Commit 1 (1.0.8)"
SHA1="$(git -C "$FAKE_REPO" rev-parse HEAD)"
SHA1_SHORT="$(printf "%.8s" "$SHA1")"

# Create a second commit with updated Cargo.toml version
cat << 'EOF' > "$FAKE_REPO/crates/codegen/xai-grok-pager-bin/Cargo.toml"
[package]
name = "xai-grok-pager-bin"
version = "1.0.10"
EOF
git -C "$FAKE_REPO" add .
git -C "$FAKE_REPO" commit -q -m "Commit 2 (1.0.10)"
SHA2="$(git -C "$FAKE_REPO" rev-parse HEAD)"
SHA2_SHORT="$(printf "%.8s" "$SHA2")"

# Set up fake origin/main ref
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main "$SHA2"

# 9a: Upstream SHA equals stamp SHA -> current (<shortsha>)
printf "SHA=%s\nPATCHSET=test\nVERSION=test\nMODE=source\n" "$SHA2" > "$TEST_GROKGOD_HOME/.source-version"
OUT_CURRENT="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim status)"
echo "$OUT_CURRENT" | grep -q "source-drift: current ($SHA2_SHORT)" || {
  echo "FAIL: Expected 'source-drift: current ($SHA2_SHORT)', got: $OUT_CURRENT"
  exit 1
}

# Also verify --version has clean stderr when current
OUT_VER_CURRENT="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim --version 2>&1)"
echo "$OUT_VER_CURRENT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: --version did not call binary"; exit 1; }
echo "$OUT_VER_CURRENT" | grep -q "source behind" && { echo "FAIL: --version should not warn when current"; exit 1; }

# 9b: Installed stamp is ancestor of origin/main -> behind
printf "SHA=%s\nPATCHSET=test\nVERSION=test\nMODE=source\n" "$SHA1" > "$TEST_GROKGOD_HOME/.source-version"
OUT_BEHIND="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim status)"
echo "$OUT_BEHIND" | grep -q "source-drift: behind" || {
  echo "FAIL: Expected 'source-drift: behind', got: $OUT_BEHIND"
  exit 1
}
echo "$OUT_BEHIND" | grep -q "installed: 1.0.8 ($SHA1_SHORT)" || {
  echo "FAIL: Expected installed: 1.0.8 ($SHA1_SHORT), got: $OUT_BEHIND"
  exit 1
}
echo "$OUT_BEHIND" | grep -q "origin/main: 1.0.10 ($SHA2_SHORT)" || {
  echo "FAIL: Expected origin/main: 1.0.10 ($SHA2_SHORT), got: $OUT_BEHIND"
  exit 1
}
echo "$OUT_BEHIND" | grep -q "hint: grok update" || {
  echo "FAIL: Expected hint: grok update, got: $OUT_BEHIND"
  exit 1
}

# 9c: --version / -V warning when behind
VER_ERR_FILE="$TMP_DIR/ver_err.txt"
VER_OUT="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim --version 2>"$VER_ERR_FILE")"
echo "$VER_OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: --version did not output binary stdout"; exit 1; }
VER_ERR="$(cat "$VER_ERR_FILE")"
echo "$VER_ERR" | grep -q "grokgod: source behind origin/main 1.0.10 ($SHA2_SHORT); run: grok update" || {
  echo "FAIL: Expected warning on stderr, got: $VER_ERR"
  exit 1
}

# Also test -V flag
V_ERR_FILE="$TMP_DIR/v_err.txt"
V_OUT="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim -V 2>"$V_ERR_FILE")"
echo "$V_OUT" | grep -q "FAKE_BIN_CALLED" || { echo "FAIL: -V did not output binary stdout"; exit 1; }
V_ERR="$(cat "$V_ERR_FILE")"
echo "$V_ERR" | grep -q "grokgod: source behind origin/main 1.0.10 ($SHA2_SHORT); run: grok update" || {
  echo "FAIL: Expected warning on stderr for -V, got: $V_ERR"
  exit 1
}

# 9d: Ahead
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main "$SHA1"
printf "SHA=%s\nPATCHSET=test\nVERSION=test\nMODE=source\n" "$SHA2" > "$TEST_GROKGOD_HOME/.source-version"
OUT_AHEAD="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim status)"
echo "$OUT_AHEAD" | grep -q "source-drift: ahead" || {
  echo "FAIL: Expected 'source-drift: ahead', got: $OUT_AHEAD"
  exit 1
}
echo "$OUT_AHEAD" | grep -q "hint:" && { echo "FAIL: Ahead should not have hint"; exit 1; }

# 9e: Diverged
git -C "$FAKE_REPO" checkout -q -b branch-diverge "$SHA1"
cat << 'EOF' > "$FAKE_REPO/diverge.txt"
diverged content
EOF
git -C "$FAKE_REPO" add diverge.txt
git -C "$FAKE_REPO" commit -q -m "Diverged commit"
SHA_DIV="$(git -C "$FAKE_REPO" rev-parse HEAD)"
git -C "$FAKE_REPO" update-ref refs/remotes/origin/main "$SHA2"
printf "SHA=%s\nPATCHSET=test\nVERSION=test\nMODE=source\n" "$SHA_DIV" > "$TEST_GROKGOD_HOME/.source-version"
OUT_DIV="$(TEST_GROK_BUILD_SRC="$FAKE_REPO" run_shim status)"
echo "$OUT_DIV" | grep -q "source-drift: diverged" || {
  echo "FAIL: Expected 'source-drift: diverged', got: $OUT_DIV"
  exit 1
}

echo "PASS: Test 9"

echo "=== All tests passed successfully! ==="
