#!/bin/sh
set -eu

# Live install of the daily Minimal agent. Uses a temp prefix and the
# --no-upgrade fast path so cargo does not run and the real ~/.grok is untouched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
TEMPLATE="$REPO_ROOT/examples/daily-minimal/minimal.md"
EVAL_TEMPLATE="$REPO_ROOT/examples/eval-home/agents/minimal.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$INSTALL_SCRIPT" ] || fail "install.sh missing"
[ -f "$TEMPLATE" ] || fail "daily template missing"
[ -f "$EVAL_TEMPLATE" ] || fail "eval template missing"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

patchset_id() {
  patch_files=""
  for p in "$REPO_ROOT"/patches/*.patch; do
    if [ -f "$p" ]; then
      patch_files="$patch_files $p"
    fi
  done
  if [ -z "$patch_files" ]; then
    echo "none"
    return 0
  fi
  # shellcheck disable=SC2086
  cat $patch_files | shasum -a 256 | awk '{print $1}'
}

make_src_repo() {
  src="$1"
  mkdir -p "$src"
  git -C "$src" init -b main >/dev/null
  git -C "$src" config user.name "grokgod-test"
  git -C "$src" config user.email "grokgod-test@example.com"
  echo "fixture" > "$src/README"
  git -C "$src" add README
  git -C "$src" commit -m "fixture" >/dev/null
  git -C "$src" rev-parse HEAD
}

prepare_fast_path() {
  home="$1"
  grokgod_home="$home/.grokgod"
  src="$2"
  sha="$(git -C "$src" rev-parse HEAD)"
  patchset="$(patchset_id)"
  mkdir -p "$grokgod_home/bin" "$home/.grok" "$home/.local/bin"
  printf '#!/bin/sh\necho mock-grok\n' > "$grokgod_home/bin/grok"
  chmod +x "$grokgod_home/bin/grok"
  printf 'SHA=%s\nPATCHSET=%s\nVERSION=%s\nMODE=source\n' "$sha" "$patchset" "$sha" > "$grokgod_home/.source-version"
}

run_install() {
  home="$1"
  src="$2"
  shift 2
  env -u GROKGOD_SRC \
    HOME="$home" \
    GROKGOD_HOME="$home/.grokgod" \
    GROK_HOME="$home/.grok" \
    GROK_BUILD_SRC="$src" \
    BIN_DIR="$home/.local/bin" \
    CARGO_TARGET_DIR="$home/.grokgod/target" \
    sh "$INSTALL_SCRIPT" --from-source --no-upgrade "$@"
}

echo "=== Live install: daily minimal agent ==="

SRC="$(mktemp -d "$TMP_DIR/src.XXXXXX")"
SHA="$(make_src_repo "$SRC")"
HOME_A="$TMP_DIR/home-a"
prepare_fast_path "$HOME_A" "$SRC"

OUT="$(run_install "$HOME_A" "$SRC" --yes)"
printf '%s\n' "$OUT" | grep -q "Fast-path: skipping cargo build" || fail "expected fast path, got: $OUT"
printf '%s\n' "$OUT" | grep -q "Installed daily minimal agent" || fail "installer did not report the daily agent"
printf '%s\n' "$OUT" | grep -q "grokgod installation complete" || fail "install did not complete"

INSTALLED="$HOME_A/.grok/agents/minimal.md"
[ -f "$INSTALLED" ] || fail "daily agent was not installed"
cmp -s "$TEMPLATE" "$INSTALLED" || fail "installed agent differs from examples/daily-minimal/minimal.md"

SYNCED="$HOME_A/.grokgod/src/examples/daily-minimal/minimal.md"
[ -f "$SYNCED" ] || fail "daily agent was not synced into grokgod src examples"
cmp -s "$TEMPLATE" "$SYNCED" || fail "synced daily agent differs from the template"

EVAL_SYNCED="$HOME_A/.grokgod/src/examples/eval-home/agents/minimal.md"
[ -f "$EVAL_SYNCED" ] || fail "eval agent was not synced"
cmp -s "$EVAL_TEMPLATE" "$EVAL_SYNCED" || fail "synced eval agent differs from the write-free template"
if cmp -s "$INSTALLED" "$EVAL_SYNCED"; then
  fail "daily agent and eval agent are the same file"
fi

echo "STALE" > "$INSTALLED"
run_install "$HOME_A" "$SRC" --yes >/dev/null
cmp -s "$TEMPLATE" "$INSTALLED" || fail "second install did not replace a stale daily agent"

echo "=== Live install: dry-run does not write the agent ==="
HOME_B="$TMP_DIR/home-b"
prepare_fast_path "$HOME_B" "$SRC"
DRY="$(run_install "$HOME_B" "$SRC" --dry-run)"
printf '%s\n' "$DRY" | grep -q "Dry-run completed successfully" || fail "dry-run did not complete"
if [ -e "$HOME_B/.grok/agents/minimal.md" ]; then
  fail "dry-run wrote the daily agent"
fi

echo "PASS: live daily minimal install (fixture sha ${SHA})"
