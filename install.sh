#!/bin/sh
set -eu

# grokgod install.sh - POSIX sh installer / patch wrapper for grok-build
# Usage: install.sh [--version TAG_OR_SHA] [--from-source] [--no-upgrade] [--force] [--yes] [--uninstall] [--dry-run] [--prefix DIR]
# ---------------------------------------------------------------------------
# GENERATED FILE - do not edit by hand.
# Source: src/installer/templates/install.sh.in + src/installer/shared/*
# Regenerate: node src/installer/build.mjs    Verify: node src/installer/build.mjs --check
# ---------------------------------------------------------------------------

GROKGOD_REPO="${GROKGOD_REPO:-https://github.com/karlorz/grokgod}"
GROKGOD_VERSION="${GROKGOD_VERSION:-}"

# Base commit that source patches were authored against (mirrors patches/README.md)
PINNED_BASE_SHA=97f190f644ae1ba07fd6ee185ef54c650e142666

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$GROKGOD_HOME/target}"
DF_CMD="${DF_CMD:-df}"

MIN_FREE_GB=15
WARN_FREE_GB=10
MIN_FREE_KB=$((MIN_FREE_GB * 1024 * 1024))
WARN_FREE_KB=$((WARN_FREE_GB * 1024 * 1024))

CLI_VERSION=""
FROM_SOURCE=""
NO_UPGRADE=0
FORCE=0
YES=0
UNINSTALL=0
DRY_RUN=0
PREFIX=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
SHIM_SRC=""

# Set when this run produced a new binary candidate to activate.
MANIFEST_INSTALLED=0
CANDIDATE_SRC=""
STAMP_CONTENT=""
MANIFEST_SHA=""
MANIFEST_VERSION=""
MANIFEST_PATCHSET=""
MANIFEST_SOURCE_SHA=""
MANIFEST_ASSET_SHA=""
MANIFEST_MODE=""

log_info() {
  printf "  \033[0;32m✓\033[0m %s\n" "$1"
}

log_warn() {
  printf "  \033[0;33m!\033[0m %s\n" "$1" >&2
}

log_err() {
  printf "  \033[0;31m✗\033[0m %s\n" "$1" >&2
}

COMPAT_ISSUE_URL="https://github.com/karlorz/grokgod/issues?q=is%3Aopen+label%3Acompat-broken"
COMPAT_ISSUE_TITLE="compat-daily: source patches do not apply to grok-build origin/main"

short_sha() {
  printf '%s' "${1:-}" | cut -c1-8
}

local_pager_version() {
  _toml="${GROK_BUILD_SRC:-}/crates/codegen/xai-grok-pager-bin/Cargo.toml"
  if [ -f "$_toml" ]; then
    grep '^version' "$_toml" | head -n 1 | sed 's/^version *= *"//;s/".*//'
  fi
}

stamp_sha() {
  if [ -f "$GROKGOD_HOME/.source-version" ]; then
    grep '^SHA=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true
  fi
}

live_grok_version_line() {
  if [ -x "$GROKGOD_HOME/bin/grok" ]; then
    _v="$("$GROKGOD_HOME/bin/grok" --version 2>/dev/null | head -n 1 || true)"
    case "$_v" in
      grok\ *) printf '%s' "$_v" ;;
    esac
  fi
}

log_live_untouched() {
  _sha="$(stamp_sha)"
  _short="$(short_sha "$_sha")"
  _ver="$(live_grok_version_line)"
  # grok --version already includes its SHA, e.g. "grok 1.0.24 (75810042ca27)".
  if [ -n "$_ver" ]; then
    log_err "Live binary untouched: ${_ver} in $GROKGOD_HOME/bin/grok."
  elif [ -n "$_short" ]; then
    log_err "Live binary untouched: ${_short} in $GROKGOD_HOME/bin/grok."
  else
    log_err "Live binary untouched."
  fi
}

log_compat_abort() {
  _pname="$1"
  _how="$2"
  _tshort="$(short_sha "${TARGET_SHA:-}")"
  _tver="$(local_pager_version)"
  log_err "Compatibility: persist patch ${_pname}"
  if [ -n "$_tver" ] && [ -n "$_tshort" ]; then
    log_err "${_how} grok-build ${_tshort} (${_tver})."
  elif [ -n "$_tshort" ]; then
    log_err "${_how} grok-build ${_tshort}."
  else
    log_err "${_how} grok-build."
  fi
  log_err "This is grokgod/upstream drift, not a grok-build installer failure."
  log_err "Patches after ${_pname} were not tested (first failure stops the run)."
  log_live_untouched
  log_err "CI tracker: ${COMPAT_ISSUE_URL}"
  log_err "  title: ${COMPAT_ISSUE_TITLE}"
  if [ -n "$_tshort" ]; then
    log_err "Next: rebase that patch against ${_tshort}. A second grok update will not help until it applies."
  else
    log_err "Next: rebase that patch. A second grok update will not help until it applies."
  fi
}

log_leftover_abort() {
  log_err "$1"
  log_err "This is usually persist-dev leftover or a previous aborted update that applied some patches, then failed."
  log_err "This is NOT the CI compat-broken miss."
  log_live_untouched
  if [ -n "${GROK_BUILD_SRC:-}" ] && command -v git >/dev/null 2>&1; then
    _dirty="$(git -C "$GROK_BUILD_SRC" diff --name-only 2>/dev/null | tr '\n' ' ')"
    if [ -n "$_dirty" ]; then
      log_err "Dirty paths: $_dirty"
    fi
  fi
  log_err "Next: inspect and resolve git status in $GROK_BUILD_SRC (operator-owned), then retry grok update."
}

log_build_abort() {
  log_err "Build failure after patches applied; not a persist-patch compatibility miss."
  log_err "Cargo build failed. Aborting (fail-closed)."
  log_live_untouched
}

log_step() {
  printf "\033[1m==> %s\033[0m\n" "$1"
}

log_dry() {
  printf "  \033[0;34m[dry-run]\033[0m %s\n" "$1"
}

# ─────────────────────────────────────────────────────────
# TRANSACTION: destination-volume staging, atomic activation,
# rollback to prior state on any pre-commit failure.
# Mirrors the Windows installer's transaction discipline.
# ─────────────────────────────────────────────────────────
TX_ACTIVE=0
TX_COMMITTED=0
TX_ROLLING_BACK=0
TX_DIR=""
TX_NOTED=""
TX_SEQ=0

# Failure injection for rollback coverage. Windows-compatible point names
# (activation, launcher-grok, launcher-grokgod, stamp) plus POSIX-only points
# for the staged candidate and the config/agent/pin writes.
fail_after() {
  _pt="${GROKGOD_INSTALL_FAIL_AFTER:-}"
  if [ -n "$_pt" ] && [ "$_pt" = "$1" ]; then
    log_err "Simulated failure injected after step '$1' (GROKGOD_INSTALL_FAIL_AFTER=$_pt)"
    exit 1
  fi
}

tx_init() {
  [ "$TX_ACTIVE" -eq 1 ] && return 0
  mkdir -p "$GROKGOD_HOME" 2>/dev/null || true
  # Staging lives on the destination volume so activation is a same-filesystem rename.
  TX_DIR="$(mktemp -d "$GROKGOD_HOME/.tx-XXXXXX" 2>/dev/null || true)"
  if [ -z "$TX_DIR" ] || [ ! -d "$TX_DIR" ]; then
    TX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grokgod-tx-XXXXXX" 2>/dev/null || true)"
  fi
  if [ -z "$TX_DIR" ] || [ ! -d "$TX_DIR" ]; then
    log_err "Could not create a transaction staging directory (fail-closed)."
    exit 1
  fi
  : > "$TX_DIR/journal"
  TX_ACTIVE=1
  TX_COMMITTED=0
  TX_ROLLING_BACK=0
  TX_NOTED=""
  TX_SEQ=0
  trap 'tx_exit' EXIT
  trap 'tx_signal 129' HUP
  trap 'tx_signal 130' INT
  trap 'tx_signal 143' TERM
}

# Resolve a symlink chain so an atomic rewrite updates the link's target and
# leaves the link itself in place. The old appending code wrote through the link.
resolve_write_target() {
  _p="$1"
  _hops=0
  while [ -L "$_p" ] && [ "$_hops" -lt 16 ]; do
    _link="$(readlink "$_p" 2>/dev/null || true)"
    [ -n "$_link" ] || break
    case "$_link" in
      /*) _p="$_link" ;;
      *) _p="$(dirname "$_p")/$_link" ;;
    esac
    _hops=$((_hops + 1))
  done
  printf '%s' "$_p"
}

# Prepare an atomic rewrite of $1 (possibly a symlink).
# Notes the resolved target for rollback and seeds a sibling temp file from the
# existing bytes so the original mode survives the rename. Echoes the temp path.
rewrite_stage() {
  _dst="$(resolve_write_target "$1")"
  _d="$(dirname "$_dst")"
  mkdir -p "$_d" 2>/dev/null || true
  if [ "${TX_ACTIVE:-0}" -eq 1 ]; then
    tx_note "$_dst"
  fi
  _t="$_d/.grokgod-rewrite.$$"
  rm -f "$_t" 2>/dev/null || true
  if [ -f "$_dst" ]; then
    cp -p "$_dst" "$_t" 2>/dev/null || {
      rm -f "$_t" 2>/dev/null || true
      log_err "Could not stage a rewrite of $_dst (fail-closed)."
      exit 1
    }
  fi
  printf '%s' "$_t"
}

# Atomic activation of a rewrite staged by rewrite_stage.
rewrite_commit() {
  _t="$1"
  _cfg="$2"
  _dst="$(resolve_write_target "$_cfg")"
  if ! mv -f "$_t" "$_dst" 2>/dev/null; then
    rm -f "$_t" 2>/dev/null || true
    log_err "Could not activate a rewrite of $_dst (fail-closed)."
    exit 1
  fi
}

# Record a path's prior state before the transaction mutates it.
# Snapshots use cp -P so rollback restores a symlink as a symlink.
# A no-op outside an active transaction, so helpers stay usable standalone.
tx_note() {
  [ "${TX_ACTIVE:-0}" -eq 1 ] || return 0
  case "$TX_NOTED" in
    *"|$1|"*) return 0 ;;
  esac
  if [ -e "$1" ] || [ -L "$1" ]; then
    TX_SEQ=$((TX_SEQ + 1))
    _snap="$TX_DIR/snap.$TX_SEQ"
    if ! cp -Pp "$1" "$_snap" 2>/dev/null; then
      log_err "Could not snapshot $1 for rollback (fail-closed)."
      exit 1
    fi
    # A short write (ENOSPC on a fallback staging volume) must not become a
    # truncated "restore" later. Symlinks are recreated as links, not sized.
    if [ ! -L "$1" ]; then
      _src_size="$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]' || true)"
      _snap_size="$(wc -c < "$_snap" 2>/dev/null | tr -d '[:space:]' || true)"
      if [ -z "$_snap_size" ] || [ "$_src_size" != "$_snap_size" ]; then
        rm -f "$_snap" 2>/dev/null || true
        log_err "Snapshot of $1 is incomplete (fail-closed)."
        exit 1
      fi
    fi
    printf 'S\t%s\t%s\n' "$1" "$_snap" >> "$TX_DIR/journal"
  else
    printf 'C\t%s\n' "$1" >> "$TX_DIR/journal"
  fi
  # Recorded only after the snapshot/item is durable, so an interrupted
  # tx_note leaves the path un-noted rather than half-noted.
  TX_NOTED="$TX_NOTED|$1|"
}

# Take the prior contents of $1 into the transaction journal by RENAME, so a
# write-only/unreadable official binary can still be preserved (cp needs read
# permission; mv only needs the directory). The caller immediately replaces $1
# with new content, which is what makes the rename safe.
# No-op outside an active transaction, so helpers stay usable standalone.
tx_take() {
  [ "${TX_ACTIVE:-0}" -eq 1 ] || return 0
  case "$TX_NOTED" in
    *"|$1|"*) return 0 ;;
  esac
  if [ -e "$1" ] || [ -L "$1" ]; then
    TX_SEQ=$((TX_SEQ + 1))
    _snap="$TX_DIR/moved.$TX_SEQ"
    if ! mv -f "$1" "$_snap" 2>/dev/null; then
      log_err "Could not take $1 for rollback (fail-closed)."
      exit 1
    fi
    printf 'M\t%s\t%s\n' "$1" "$_snap" >> "$TX_DIR/journal"
    TX_NOTED="$TX_NOTED|$1|"
  else
    tx_note "$1"
  fi
}

# Atomic create/replace: stage a sibling temp file, then rename over the target.
tx_write() {
  _src="$1"
  _dst="$2"
  _mode="${3:-}"
  _dir="$(dirname "$_dst")"
  mkdir -p "$_dir"
  tx_note "$_dst"
  _tmp="$_dir/.grokgod-tmp.$$"
  if ! cp "$_src" "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    log_err "Could not stage $_dst (fail-closed)."
    exit 1
  fi
  if [ -n "$_mode" ]; then
    chmod "$_mode" "$_tmp" 2>/dev/null || true
  fi
  if ! mv -f "$_tmp" "$_dst" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    log_err "Could not activate $_dst (fail-closed)."
    exit 1
  fi
}

# Atomically move an already-staged temp file onto its destination.
tx_rename() {
  _tmp="$1"
  _dst="$2"
  tx_note "$_dst"
  if ! mv -f "$_tmp" "$_dst" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    log_err "Could not activate $_dst (fail-closed)."
    exit 1
  fi
}

# Reverse replay of the journal: restore snapshots, remove created paths.
tx_rollback() {
  [ "$TX_ACTIVE" -eq 1 ] || return 0
  [ "$TX_ROLLING_BACK" -eq 1 ] && return 0
  TX_ROLLING_BACK=1
  # Ignore further signals for the duration: a second Ctrl-C must not abort a
  # half-finished restore and strand the tree without its snapshots.
  trap '' INT TERM HUP

  if [ -s "$TX_DIR/journal" ]; then
    log_err "Transaction failed. Rolling back to prior state..."
    awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' \
      "$TX_DIR/journal" > "$TX_DIR/journal.rev" 2>/dev/null || :
    _tab="$(printf '\t')"
    if [ -s "$TX_DIR/journal.rev" ]; then
      while IFS="$_tab" read -r _kind _path _snap || [ -n "$_kind" ]; do
        case "$_kind" in
          S)
            if [ -n "$_snap" ] && { [ -f "$_snap" ] || [ -L "$_snap" ]; }; then
              _rdir="$(dirname "$_path")"
              mkdir -p "$_rdir" 2>/dev/null || true
              if cp -Pp "$_snap" "$_rdir/.grokgod-restore.$$" 2>/dev/null &&
                 mv -f "$_rdir/.grokgod-restore.$$" "$_path" 2>/dev/null; then
                log_info "Rolled back: $_path"
              else
                rm -f "$_rdir/.grokgod-restore.$$" 2>/dev/null || true
                log_err "Rollback could not restore $_path"
              fi
            fi
            ;;
          M)
            # The original file was preserved by rename, not by copy.
            if [ -n "$_snap" ] && { [ -f "$_snap" ] || [ -L "$_snap" ]; }; then
              rm -f "$_path" 2>/dev/null || true
              if mv -f "$_snap" "$_path" 2>/dev/null; then
                log_info "Rolled back: $_path"
              else
                log_err "Rollback could not move $_snap back to $_path"
              fi
            fi
            ;;
          C)
            rm -f "$_path" 2>/dev/null || true
            log_info "Rolled back (removed): $_path"
            ;;
        esac
      done < "$TX_DIR/journal.rev"
    fi
  fi

  # Staged candidates and temp files were never part of prior state.
  rm -f "$GROKGOD_HOME/bin/candidate-$$" 2>/dev/null || true
  rm -f "$GROKGOD_HOME/bin/.grokgod-tmp.$$" 2>/dev/null || true
  rm -f "$GROKGOD_HOME/.source-version.grokgod-tmp.$$" 2>/dev/null || true
  rm -f "$GROKGOD_HOME/manifest.json.grokgod-tmp.$$" 2>/dev/null || true
  rm -f "$BIN_DIR/.grokgod-tmp.$$" "$BIN_DIR/.grokgod-orig.$$" "$BIN_DIR/.grokgod-restore.$$" "$BIN_DIR/grok.orig.prev" 2>/dev/null || true
  rm -f "$GROK_HOME/.grokgod-tmp.$$" "$GROK_HOME/.grokgod-restore.$$" 2>/dev/null || true
  rm -f "$GROK_HOME/bin/.grokgod-tmp.$$" "$GROK_HOME/bin/.grokgod-restore.$$" "$GROK_HOME/bin/grok.orig.prev" 2>/dev/null || true
  rm -f "$GROK_HOME/agents/.grokgod-tmp.$$" "$GROK_HOME/agents/.grokgod-restore.$$" 2>/dev/null || true
  rm -f "$GROK_HOME/config.toml.grokgod-rewrite.$$" "$GROK_HOME/.grokgod-rewrite.$$" 2>/dev/null || true
  rm -f "$GROK_HOME/config.toml.grokgod-plan-mode.tmp" 2>/dev/null || true
  rm -f "$GROK_HOME/config.toml.grokgod-workflows-builtins.tmp" 2>/dev/null || true
  rm -f "$GROK_HOME/config.toml.grokgod-status-line.tmp" 2>/dev/null || true

  hash -r 2>/dev/null || true
  TX_ACTIVE=0
  return 0
}

tx_cleanup() {
  if [ -n "$TX_DIR" ] && [ -d "$TX_DIR" ]; then
    rm -rf "$TX_DIR" 2>/dev/null || true
  fi
  TX_DIR=""
}

tx_exit() {
  _st=$?
  set +e
  if [ "$TX_ACTIVE" -eq 1 ] && [ "$TX_COMMITTED" -eq 0 ]; then
    tx_rollback
  fi
  tx_cleanup
  exit "$_st"
}

tx_signal() {
  _st="$1"
  set +e
  log_err "Interrupted; rolling back."
  tx_rollback
  tx_cleanup
  exit "$_st"
}

# Commit point: prior state is no longer restorable.
tx_commit() {
  TX_COMMITTED=1
  TX_ACTIVE=0
  tx_cleanup
  rm -f "$BIN_DIR/grok.orig.prev" "$GROK_HOME/bin/grok.orig.prev" 2>/dev/null || true
}

# Strict SHA256SUMS matcher: print the single hash whose filename field is
# exactly $1. Fail closed on zero or multiple matching entries. No fallback.
#
# NUL bytes are rejected up front: BSD awk truncates each record at the first
# NUL, so a sums file with an embedded NUL can hide a duplicate entry from the
# match counter and be read differently by different awk implementations.
asset_sha_from_sums() {
  if [ ! -f "$2" ]; then
    return 1
  fi
  if ! LC_ALL=C tr -d '\000' < "$2" 2>/dev/null | cmp -s - "$2" 2>/dev/null; then
    return 1
  fi
  awk -v expected="$1" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (substr(line, 1, 1) == "#") next
      n = split(line, f, /[[:space:]]+/)
      if (n != 2) next
      hash = tolower(f[1])
      if (length(hash) != 64) next
      if (hash ~ /[^0-9a-f]/) next
      name = f[2]
      sub(/^\*/, "", name)
      if (name != expected) next
      matches++
      if (matches == 1) found = hash
    }
    END {
      if (matches != 1) exit 1
      print found
    }
  ' "$2"
}

# SHA-256 of a file on stdout, or empty when no hashing tool is available.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || true
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || true
  fi
}

# Guard for the "already up to date" fast paths. A run killed between
# activation and the commit point (SIGKILL, power loss) leaves the live binary
# newer than the stamp and the manifest. Without this check that torn state is
# declared healthy forever. Only release stamps carry a binary hash (source
# stamps carry a git commit id), so every other case is treated as a match.
# Returns 0 when the recorded hash matches, and 0 when the stamp carries no
# usable hash or no hashing tool exists (best effort).
live_binary_matches_stamp() {
  _stamp_mode="$(grep '^MODE=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
  [ "$_stamp_mode" = "release" ] || return 0
  _stamp_sha="$(grep '^SHA=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$_stamp_sha" ] || return 0
  _live_sha="$(file_sha256 "$GROKGOD_HOME/bin/grok")"
  [ -n "$_live_sha" ] || return 0
  [ "$_stamp_sha" = "$_live_sha" ]
}

# Run the staged candidate once before it can replace anything live.
preflight_candidate() {
  _cand="$1"
  _label="$2"
  if [ ! -f "$_cand" ]; then
    log_err "Preflight failed: staged candidate missing at $_cand (fail-closed)."
    exit 1
  fi
  [ -x "$_cand" ] || chmod +x "$_cand" 2>/dev/null || true
  if ! _out="$("$_cand" --version 2>/dev/null)"; then
    log_err "Preflight failed: candidate $_label did not report --version successfully (fail-closed)."
    exit 1
  fi
  _first="$(printf '%s\n' "$_out" | head -n 1)"
  if [ -z "$_first" ]; then
    log_err "Preflight failed: candidate $_label printed no version line (fail-closed)."
    exit 1
  fi
  log_info "Preflight verified candidate: $_first"
}

# Parse CLI arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      if [ $# -lt 2 ]; then
        log_err "--version requires an argument"
        exit 1
      fi
      CLI_VERSION="$2"
      shift 2
      ;;
    --from-source)
      FROM_SOURCE=1
      shift
      ;;
    --no-upgrade)
      NO_UPGRADE=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --yes|-y)
      YES=1
      shift
      ;;
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --prefix)
      if [ $# -lt 2 ]; then
        log_err "--prefix requires a DIR argument"
        exit 1
      fi
      PREFIX="$2"
      GROKGOD_HOME="$PREFIX/grokgod"
      GROK_HOME="$PREFIX/grok"
      BIN_DIR="$PREFIX/bin"
      CARGO_TARGET_DIR="$GROKGOD_HOME/target"
      shift 2
      ;;
    -h|--help)
      echo "Usage: install.sh [--version TAG_OR_SHA] [--from-source] [--no-upgrade] [--force] [--yes] [--uninstall] [--dry-run] [--prefix DIR]"
      exit 0
      ;;
    *)
      log_err "Unknown option: $1"
      echo "Usage: install.sh [--version TAG_OR_SHA] [--from-source] [--no-upgrade] [--force] [--yes] [--uninstall] [--dry-run] [--prefix DIR]" >&2
      exit 1
      ;;
  esac
done

# Determine install mode: "release" (default) or "source"
INSTALLED_MODE=""
if [ -f "$GROKGOD_HOME/.source-version" ]; then
  INSTALLED_MODE="$(grep '^MODE=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
fi

if [ "$FROM_SOURCE" = "1" ]; then
  MODE="source"
elif [ -n "$FROM_SOURCE" ] && [ "$FROM_SOURCE" = "0" ]; then
  MODE="release"
elif [ "$INSTALLED_MODE" = "source" ]; then
  MODE="source"
else
  MODE="release"
fi

if [ "$MODE" = "source" ]; then
  GROK_BUILD_SRC="${GROK_BUILD_SRC:-$HOME/Desktop/code/grok-build}"
  VERSION_SHA="$CLI_VERSION"
else
  if [ -n "$CLI_VERSION" ]; then
    GROKGOD_VERSION="$CLI_VERSION"
  fi
fi

# Helper: check available disk space in KB on directory or parent
get_free_kb() {
  check_dir="$1"
  while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ] && [ "$check_dir" != "." ]; do
    check_dir="$(dirname "$check_dir")"
  done
  if [ ! -d "$check_dir" ]; then
    check_dir="/"
  fi
  # Use POSIX df output: line 2, column 4 (Available blocks in 1K)
  $DF_CMD -P -k "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}'
}

fast_forward_or_reset_grokgod_src() {
  repo="$1"
  upstream="$(git -C "$repo" rev-parse origin/main 2>/dev/null || true)"
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"

  if [ -z "$upstream" ] || [ -z "$head" ]; then
    echo "grokgod: could not resolve upstream or HEAD at $repo" >&2
    return 1
  fi

  # 1. If head is not upstream and head is not an ancestor of upstream:
  if [ "$head" != "$upstream" ] && ! git -C "$repo" merge-base --is-ancestor "$head" "$upstream" 2>/dev/null; then
    echo "grokgod: src has local commits (not fast-forward) at $repo" >&2
    return 1
  fi

  # 2. Otherwise classify the worktree with no mutations yet:
  has_tracked_changes=0
  tab="$(printf '\t')"

  diff_out="$(git -C "$repo" diff --name-status --no-renames HEAD 2>/dev/null || true)"
  if [ -n "$diff_out" ]; then
    has_tracked_changes=1
    while IFS="$tab" read -r status path || [ -n "$status" ]; do
      [ -z "$status" ] && continue
      case "$status" in
        D)
          if git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          ;;
        A|M|T)
          if [ ! -f "$repo/$path" ]; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          if ! git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          if ! git -C "$repo" show "origin/main:$path" 2>/dev/null | cmp -s "$repo/$path" -; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          ;;
        *)
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
          ;;
      esac
    done << EOF_DIFF
$diff_out
EOF_DIFF
  fi

  blockers=""
  untracked_out="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null || true)"
  if [ -n "$untracked_out" ]; then
    while IFS= read -r path || [ -n "$path" ]; do
      [ -z "$path" ] && continue
      cur="$path"
      while [ "$cur" != "." ] && [ "$cur" != "/" ]; do
        cur="$(dirname "$cur")"
        [ "$cur" = "." ] || [ "$cur" = "/" ] && break
        if git -C "$repo" cat-file -e "origin/main:$cur" 2>/dev/null; then
          if [ -d "$repo/$cur" ]; then
            echo "grokgod: src differs from origin/main: $cur" >&2
            return 1
          fi
        fi
      done

      if git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
        if [ -d "$repo/$path" ]; then
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
        if [ ! -f "$repo/$path" ]; then
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
        if git -C "$repo" show "origin/main:$path" 2>/dev/null | cmp -s "$repo/$path" -; then
          if [ -z "$blockers" ]; then
            blockers="$path"
          else
            blockers="$blockers
$path"
          fi
        else
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
      fi
    done << EOF_UNTRACKED
$untracked_out
EOF_UNTRACKED
  fi

  # 3. If there was any tracked change or any matching untracked blocker:
  if [ "$has_tracked_changes" -eq 1 ] || [ -n "$blockers" ]; then
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null 2>&1; then
      echo "grokgod: src is detached; refusing to reset $repo" >&2
      return 1
    fi
    if [ -n "$blockers" ]; then
      while IFS= read -r b_file || [ -n "$b_file" ]; do
        [ -z "$b_file" ] && continue
        rm -f "$repo/$b_file"
      done << EOF_BLOCKERS
$blockers
EOF_BLOCKERS
    fi
    if ! git -C "$repo" reset --hard origin/main >/dev/null 2>&1; then
      echo "grokgod: src reset failed at $repo" >&2
      return 1
    fi
    return 0
  fi

  # 4. If the tree had no tracked changes and no blockers:
  git -C "$repo" pull --ff-only
}

# ff-only pull or clean reset of the installed grokgod src (never the developer
# checkout unless it is also GROKGOD_SRC). Skip when unset or not a git repo.
sync_installed_grokgod_src() {
  if [ -z "${GROKGOD_SRC:-}" ] || [ ! -d "$GROKGOD_SRC/.git" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Would git -C $GROKGOD_SRC pull --ff-only"
    return 0
  fi
  log_step "Syncing grokgod src at $GROKGOD_SRC..."
  if ! git -C "$GROKGOD_SRC" fetch origin; then
    log_err "Failed to fetch grokgod src origin in $GROKGOD_SRC"
    log_live_untouched
    exit 1
  fi
  if ! fast_forward_or_reset_grokgod_src "$GROKGOD_SRC"; then
    log_err "This is not leftover grok-build dirt and not the CI compat-broken miss."
    log_live_untouched
    log_err "Next: inspect $GROKGOD_SRC and rebase/ff onto origin, then retry grok update."
    exit 1
  fi
}

# Helper: sha256 of a file, empty when no tool is available.
manifest_file_sha256() {
  _mf_path="$1"
  [ -f "$_mf_path" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$_mf_path" 2>/dev/null | awk '{print $1}' || true
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$_mf_path" 2>/dev/null | awk '{print $1}' || true
  else
    printf ''
  fi
}

manifest_classify_signature() {
  _sig_path="${1:-}"
  if [ -z "$_sig_path" ] || [ ! -e "$_sig_path" ]; then
    printf 'absent'
    return 0
  fi
  if [ "$(uname -s 2>/dev/null || true)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then
    printf 'unsupported'
    return 0
  fi
  _sig_out="$(codesign -dv "$_sig_path" 2>&1 || true)"
  case "$_sig_out" in
    *"code object is not signed at all"*) printf 'unsigned' ;;
    *"Signature=adhoc"*) printf 'adhoc' ;;
    *"Authority="*) printf 'signed' ;;
    *) printf 'unknown' ;;
  esac
  return 0
}

manifest_json_escape() {
  printf '%s' "${1:-}" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g' 2>/dev/null || true
}

# POSIX artifact manifest: records WHAT was installed (the activated binary's
# post-codesign digest, platform, mode, patchset and signature) next to the
# stamp. Supplementary and best-effort: a manifest failure must never fail an
# otherwise good install, and the stamp stays authoritative for install.sh.
# This is the only manifest schema install.sh writes; there is no separate
# ownership manifest.
#
# write_artifact_manifest <mode> <version> <patchset> <sourceSha> <assetSha> [out]
#
# The artifact digest is computed from the live $GROKGOD_HOME/bin/grok, which
# is the post-codesign file the transaction activated; the stamp cannot supply
# it (a release stamp holds the pre-codesign download digest, a source stamp a
# git commit). Callers pass the destination so the commit point can stage the
# bytes in a sibling temp and rename them atomically.
write_artifact_manifest() {
  _wm_mode="${1:-}"
  _wm_version="${2:-}"
  _wm_patchset="${3:-}"
  _wm_source_sha="${4:-}"
  _wm_asset_sha="${5:-}"
  _wm_out="${6:-$GROKGOD_HOME/manifest.json}"

  # Set only on the successful write path, so callers never announce (or
  # rename) a manifest that was not produced.
  ARTIFACT_MANIFEST_WROTE=0

  [ -d "$GROKGOD_HOME" ] || return 0

  _wm_target="$GROKGOD_HOME/bin/grok"
  _wm_artifact_sha="$(manifest_file_sha256 "$_wm_target")"
  # An unusable recorded digest is worse than no manifest: status would have
  # to treat it as corrupt. Skip recording and leave the stamp authoritative.
  case "$(printf '%s\n' "$_wm_artifact_sha" | LC_ALL=C grep -c '^[0-9a-f]\{64\}$' 2>/dev/null || true)" in
    1) : ;;
    *)
      log_warn "Skipping artifact manifest: no readable /bin/grok digest at $GROKGOD_HOME/bin/grok"
      return 0
      ;;
  esac
  _wm_signature="$(manifest_classify_signature "$_wm_target")"
  _wm_installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  _wm_installed_epoch="$(date -u +%s 2>/dev/null || true)"
  case "$_wm_installed_epoch" in
    ''|*[!0-9]*) _wm_installed_epoch=null ;;
  esac

  if ! {
    printf '{\n'
    printf '  "formatVersion": 1,\n'
    printf '  "platform": "posix",\n'
    printf '  "installedAt": "%s",\n' "$(manifest_json_escape "$_wm_installed_at")"
    printf '  "installedAtEpoch": %s,\n' "$_wm_installed_epoch"
    printf '  "mode": "%s",\n' "$(manifest_json_escape "$_wm_mode")"
    printf '  "version": "%s",\n' "$(manifest_json_escape "$_wm_version")"
    printf '  "patchset": "%s",\n' "$(manifest_json_escape "$_wm_patchset")"
    printf '  "sourceSha": "%s",\n' "$(manifest_json_escape "$_wm_source_sha")"
    printf '  "assetSha256": "%s",\n' "$(manifest_json_escape "$_wm_asset_sha")"
    printf '  "artifactSha256": "%s",\n' "$(manifest_json_escape "$_wm_artifact_sha")"
    printf '  "signature": "%s",\n' "$(manifest_json_escape "$_wm_signature")"
    printf '  "targetExe": "%s",\n' "$(manifest_json_escape "$_wm_target")"
    printf '  "grokgodHome": "%s"\n' "$(manifest_json_escape "$GROKGOD_HOME")"
    printf '}\n'
  } > "$_wm_out" 2>/dev/null; then
    rm -f "$_wm_out" 2>/dev/null || true
    log_warn "Could not write artifact manifest at $_wm_out"
    return 0
  fi
  ARTIFACT_MANIFEST_WROTE=1
  return 0
}

# True only when write_artifact_manifest produced a manifest, so the caller
# does not announce or activate a record that was never written.
artifact_manifest_recorded() {
  [ "${ARTIFACT_MANIFEST_WROTE:-0}" = "1" ]
}

# Helper: compute SHA of patch set
compute_patchset_id() {
  patch_files=""
  if [ -d "$PATCHES_DIR" ]; then
    # Match *.patch files in alphabetical order
    for p in "$PATCHES_DIR"/*.patch; do
      if [ -f "$p" ]; then
        patch_files="$patch_files $p"
      fi
    done
  fi
  if [ -z "$patch_files" ]; then
    echo "none"
  else
    # Concatenate all patch files and compute SHA256 / SHA1
    if command -v shasum >/dev/null 2>&1; then
      cat $patch_files | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
      cat $patch_files | sha256sum | awk '{print $1}'
    elif command -v cksum >/dev/null 2>&1; then
      cat $patch_files | cksum | awk '{print $1}'
    else
      echo "present"
    fi
  fi
}

# ─────────────────────────────────────────────────────────
# 1. UNINSTALL FLOW
# ─────────────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
  log_step "Uninstalling grokgod..."

  # a. Restore grok in BIN_DIR
  if [ -f "$BIN_DIR/grok.orig" ] || [ -L "$BIN_DIR/grok.orig" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "Restore backup: mv $BIN_DIR/grok.orig $BIN_DIR/grok"
    else
      mv "$BIN_DIR/grok.orig" "$BIN_DIR/grok"
      log_info "Restored original grok binary: $BIN_DIR/grok.orig -> $BIN_DIR/grok"
    fi
  elif [ -f "$BIN_DIR/grok" ] && grep -q "GROKGOD" "$BIN_DIR/grok" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "Remove grokgod shim: rm $BIN_DIR/grok"
    else
      rm -f "$BIN_DIR/grok"
      log_info "Removed grokgod shim: $BIN_DIR/grok"
    fi
  fi

  # b. Remove grokgod launcher in BIN_DIR if ours
  if [ -f "$BIN_DIR/grokgod" ]; then
    if grep -q "GROKGOD" "$BIN_DIR/grokgod" 2>/dev/null || [ ! -s "$BIN_DIR/grokgod" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Remove grokgod launcher: rm $BIN_DIR/grokgod"
      else
        rm -f "$BIN_DIR/grokgod"
        log_info "Removed grokgod launcher: $BIN_DIR/grokgod"
      fi
    fi
  fi

  # c. Restore grok in GROK_HOME/bin
  if [ -f "$GROK_HOME/bin/grok.orig" ] || [ -L "$GROK_HOME/bin/grok.orig" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "Restore GROK_HOME backup: mv $GROK_HOME/bin/grok.orig $GROK_HOME/bin/grok"
    else
      mv "$GROK_HOME/bin/grok.orig" "$GROK_HOME/bin/grok"
      log_info "Restored original grok binary: $GROK_HOME/bin/grok.orig -> $GROK_HOME/bin/grok"
    fi
  elif [ -f "$GROK_HOME/bin/grok" ] && grep -q "GROKGOD" "$GROK_HOME/bin/grok" 2>/dev/null; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "Remove grokgod shim from GROK_HOME: rm $GROK_HOME/bin/grok"
    else
      rm -f "$GROK_HOME/bin/grok"
      log_info "Removed grokgod shim: $GROK_HOME/bin/grok"
    fi

    # If official grok-* Mach-O exists, recreate symlink to latest grok-*
    latest_grok=""
    if [ -d "$GROK_HOME/bin" ]; then
      for candidate in "$GROK_HOME/bin"/grok-*; do
        if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
          latest_grok="$candidate"
        fi
      done
    fi
    if [ -n "$latest_grok" ]; then
      target_rel="$(basename "$latest_grok")"
      if [ "$DRY_RUN" -eq 1 ]; then
        log_dry "Recreate symlink to official grok: ln -sf $target_rel $GROK_HOME/bin/grok"
      else
        ln -sf "$target_rel" "$GROK_HOME/bin/grok"
        log_info "Recreated symlink to official binary: $GROK_HOME/bin/grok -> $target_rel"
      fi
    fi
  fi

  # d. Remove GROKGOD_HOME
  if [ -d "$GROKGOD_HOME" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_dry "Remove GROKGOD_HOME: rm -rf $GROKGOD_HOME"
    else
      rm -rf "$GROKGOD_HOME"
      log_info "Removed grokgod directory: $GROKGOD_HOME"
    fi
  fi

  # e. Flush shell cache best-effort
  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Flush shell command hash table: hash -r"
  else
    hash -r 2>/dev/null || true
    log_info "Shell command cache flushed"
  fi

  log_info "Uninstallation complete."
  exit 0
fi

# ─────────────────────────────────────────────────────────
# 2. DISK GUARD (Pre-build / Pre-install)
# ─────────────────────────────────────────────────────────
parent_dir="$(dirname "$GROKGOD_HOME")"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$parent_dir"
fi

free_kb="$(get_free_kb "$parent_dir")"
if [ -n "$free_kb" ] && [ "$free_kb" -ge 0 ] 2>/dev/null; then
  if [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
    free_gb=$(awk -v kb="$free_kb" 'BEGIN { printf "%.2f", kb / (1024 * 1024) }')
    log_err "Insufficient disk space: ${free_gb} GB available, minimum ${MIN_FREE_GB} GB required."
    log_err "Please free up disk space before installing grokgod."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────
# DRY-RUN MODE FLOW
# ─────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  log_step "Running dry-run checks..."

  if [ "$MODE" = "source" ]; then
    if [ ! -d "$GROK_BUILD_SRC" ]; then
      log_err "GROK_BUILD_SRC directory not found: $GROK_BUILD_SRC"
      exit 1
    fi

    if [ "$NO_UPGRADE" -eq 0 ]; then
      if [ -n "$VERSION_SHA" ]; then
        log_dry "Check git commit exists: git -C $GROK_BUILD_SRC cat-file -e ${VERSION_SHA}^{commit}"
        if ! git -C "$GROK_BUILD_SRC" cat-file -e "${VERSION_SHA}^{commit}" 2>/dev/null; then
          log_err "Commit '${VERSION_SHA}' does not exist in $GROK_BUILD_SRC"
          exit 1
        fi
        log_dry "Would checkout commit: git -C $GROK_BUILD_SRC checkout $VERSION_SHA"
      else
        log_dry "Would fetch: git -C $GROK_BUILD_SRC fetch origin"
        dry_checkout_ref="origin/main"
        if [ -d "$GROK_BUILD_SRC/.git" ]; then
          main_tip="$(git -C "$GROK_BUILD_SRC" rev-parse --verify refs/heads/main 2>/dev/null || true)"
          origin_tip="$(git -C "$GROK_BUILD_SRC" rev-parse --verify origin/main 2>/dev/null || true)"
          if [ -n "$main_tip" ] && [ "$main_tip" = "$origin_tip" ]; then
            dry_checkout_ref="main"
          fi
        fi
        if [ "$dry_checkout_ref" = "main" ]; then
          log_dry "Would checkout main: git -C $GROK_BUILD_SRC checkout main"
        else
          log_dry "Would checkout origin/main: git -C $GROK_BUILD_SRC checkout origin/main"
        fi
      fi
    else
      log_dry "Skipping git fetch/checkout (--no-upgrade)"
    fi

    patch_list=""
    if [ -d "$PATCHES_DIR" ]; then
      for p in "$PATCHES_DIR"/*.patch; do
        if [ -f "$p" ]; then
          patch_list="$patch_list $p"
        fi
      done
    fi

    if [ -n "$patch_list" ]; then
      # If working tree is clean, test cumulative patching in a temporary detached worktree
      dry_tmp=""
      if [ -d "$GROK_BUILD_SRC/.git" ]; then
        dry_tmp="$(mktemp -d /tmp/grokgod-dry-XXXXXX 2>/dev/null || true)"
        if [ -n "$dry_tmp" ]; then
          rmdir "$dry_tmp" 2>/dev/null || true
          if ! git -C "$GROK_BUILD_SRC" worktree add --detach "$dry_tmp" HEAD >/dev/null 2>&1; then
            rm -rf "$dry_tmp" 2>/dev/null || true
            dry_tmp=""
          fi
        fi
      fi

      for p in $patch_list; do
        log_dry "Would test and apply patch: $p"
        if [ -n "$dry_tmp" ] && git -C "$dry_tmp" apply --check "$p" 2>/dev/null && git -C "$dry_tmp" apply "$p" 2>/dev/null; then
          log_dry "  -> patch $(basename "$p") applies cleanly"
        elif git -C "$GROK_BUILD_SRC" apply --check "$p" 2>/dev/null; then
          log_dry "  -> patch $(basename "$p") applies cleanly"
        elif git -C "$GROK_BUILD_SRC" apply -R --check "$p" 2>/dev/null; then
          log_dry "  -> patch $(basename "$p") is already applied (reversibly clean)"
        else
          log_warn "  -> patch $(basename "$p") dry-run check failed against current working tree"
        fi
      done

      if [ -n "$dry_tmp" ]; then
        git -C "$dry_tmp" worktree remove --force "$dry_tmp" >/dev/null 2>&1 || git -C "$GROK_BUILD_SRC" worktree remove --force "$dry_tmp" >/dev/null 2>&1 || rm -rf "$dry_tmp" 2>/dev/null || true
      fi
    else
      log_dry "No patches found; would build stock"
    fi

    log_dry "Would build: CARGO_TARGET_DIR=$CARGO_TARGET_DIR CARGO_INCREMENTAL=0 cargo build --release -p xai-grok-pager-bin (in $GROK_BUILD_SRC)"
    log_dry "Would copy binary: cp $CARGO_TARGET_DIR/release/xai-grok-pager $GROKGOD_HOME/bin/grok"
    log_dry "Would stamp: $GROKGOD_HOME/.source-version (MODE=source)"
  else
    # Release mode dry-run
    raw_os="$(uname -s)"
    case "$raw_os" in
      Darwin) OS="darwin" ;;
      Linux)  OS="linux" ;;
      *) OS="unknown" ;;
    esac

    raw_arch="$(uname -m)"
    case "$raw_arch" in
      x86_64|amd64) ARCH="x64" ;;
      arm64|aarch64) ARCH="arm64" ;;
      *) ARCH="unknown" ;;
    esac

    ASSET="grokgod-${OS}-${ARCH}"
    log_dry "Would detect platform: ${OS}-${ARCH} (asset: ${ASSET})"
    log_dry "Would resolve download URL from $GROKGOD_REPO (version: ${GROKGOD_VERSION:-latest})"
    log_dry "Would download and verify SHA256 checksums"
    log_dry "Would install prebuilt binary to $GROKGOD_HOME/bin/grok"
    log_dry "Would stamp: $GROKGOD_HOME/.source-version (MODE=release)"
  fi

  log_dry "Would install launchers: $BIN_DIR/grok, $BIN_DIR/grokgod, and $GROK_HOME/bin/grok"
  log_info "Dry-run completed successfully (no changes made)."
  exit 0
fi

# ─────────────────────────────────────────────────────────
# RELEASE MODE (Prebuilt binary)
# ─────────────────────────────────────────────────────────
if [ "$MODE" = "release" ]; then
  raw_os="$(uname -s)"
  case "$raw_os" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux" ;;
    *)
      log_err "Unsupported operating system: $raw_os"
      exit 1
      ;;
  esac

  raw_arch="$(uname -m)"
  case "$raw_arch" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)
      log_err "Unsupported architecture: $raw_arch"
      exit 1
      ;;
  esac

  ASSET="grokgod-${OS}-${ARCH}"
  REPO_PATH="$(printf "%s" "$GROKGOD_REPO" | sed 's|https://github.com/||; s|\.git$||')"

  TAG_NAME=""
  DOWNLOAD_URL=""
  SUMS_URL=""

  if [ -z "$GROKGOD_VERSION" ] || [ "$GROKGOD_VERSION" = "latest" ]; then
    API_URL="https://api.github.com/repos/${REPO_PATH}/releases/latest"
    RELEASE_JSON="$(curl -fsSL "$API_URL" 2>/dev/null || true)"

    if [ -n "$RELEASE_JSON" ] && command -v python3 >/dev/null 2>&1; then
      DOWNLOAD_URL="$(printf "%s" "$RELEASE_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for a in data.get('assets', []):
        if a.get('name') == '$ASSET':
            print(a.get('browser_download_url', ''))
            break
except Exception:
    pass
" 2>/dev/null || true)"
      TAG_NAME="$(printf "%s" "$RELEASE_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tag_name', ''))
except Exception:
    pass
" 2>/dev/null || true)"
    fi

    if [ -z "$DOWNLOAD_URL" ] && [ -n "$RELEASE_JSON" ]; then
      DOWNLOAD_URL="$(printf "%s" "$RELEASE_JSON" | grep -o "https://[^\"]*/releases/download/[^\"]*/${ASSET}" | head -n 1 || true)"
      TAG_NAME="$(printf "%s" "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/"tag_name": *"//; s/"//' || true)"
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
      DOWNLOAD_URL="https://github.com/${REPO_PATH}/releases/latest/download/${ASSET}"
      SUMS_URL="https://github.com/${REPO_PATH}/releases/latest/download/SHA256SUMS"
      TAG_NAME="${TAG_NAME:-latest}"
    else
      SUMS_URL="$(printf "%s" "$DOWNLOAD_URL" | sed "s|/${ASSET}$|/SHA256SUMS|")"
      TAG_NAME="${TAG_NAME:-latest}"
    fi
  else
    if [ "${GROKGOD_VERSION#v}" != "$GROKGOD_VERSION" ]; then
      TAG_NAME="$GROKGOD_VERSION"
    else
      TAG_NAME="v$GROKGOD_VERSION"
    fi
    DOWNLOAD_URL="https://github.com/${REPO_PATH}/releases/download/${TAG_NAME}/${ASSET}"
    SUMS_URL="https://github.com/${REPO_PATH}/releases/download/${TAG_NAME}/SHA256SUMS"
  fi

  NEED_DOWNLOAD=1
  if [ "$FORCE" -eq 0 ] && [ -x "$GROKGOD_HOME/bin/grok" ] && [ -f "$GROKGOD_HOME/.source-version" ]; then
    STAMP_VER="$(grep '^VERSION=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
    if [ "$NO_UPGRADE" -eq 1 ]; then
      if [ -n "$GROKGOD_VERSION" ] && [ "$GROKGOD_VERSION" != "latest" ]; then
        if [ "$STAMP_VER" = "$TAG_NAME" ] || [ "$STAMP_VER" = "$GROKGOD_VERSION" ] || [ "$STAMP_VER" = "v$GROKGOD_VERSION" ]; then
          log_info "Matching installed version ($STAMP_VER) found and binary exists."
          log_info "Fast-path: skipping download (--no-upgrade), updating launchers only."
          NEED_DOWNLOAD=0
        fi
      else
        log_info "Installed binary exists ($STAMP_VER)."
        log_info "Fast-path: skipping download (--no-upgrade), updating launchers only."
        NEED_DOWNLOAD=0
      fi
    elif [ -n "$TAG_NAME" ] && [ "$TAG_NAME" != "latest" ] && [ "$STAMP_VER" = "$TAG_NAME" ]; then
      # A run killed between activation and the commit point leaves the live
      # binary newer than the stamp while the version still matches. Declaring
      # that healthy would keep the stale metadata forever, so reinstall.
      if live_binary_matches_stamp; then
        log_info "Already up to date (VERSION=$TAG_NAME)"
        NEED_DOWNLOAD=0
      else
        log_warn "Live grok does not match the recorded stamp (interrupted install?); reinstalling."
      fi
    fi
  fi

  if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    log_step "Downloading prebuilt binary $ASSET ($TAG_NAME)..."
    TMP_DL="$(mktemp -d)"

    if ! curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DL/$ASSET"; then
      log_err "Failed to download $ASSET from $DOWNLOAD_URL"
      rm -rf "$TMP_DL"
      exit 1
    fi

    if ! curl -fsSL "$SUMS_URL" -o "$TMP_DL/SHA256SUMS" 2>/dev/null; then
      ALT_SUMS="https://github.com/${REPO_PATH}/releases/download/${TAG_NAME}/SHA256SUMS"
      if ! curl -fsSL "$ALT_SUMS" -o "$TMP_DL/SHA256SUMS" 2>/dev/null; then
        log_err "Failed to download SHA256SUMS from $SUMS_URL"
        rm -rf "$TMP_DL"
        exit 1
      fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL_SHA="$(sha256sum "$TMP_DL/$ASSET" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      ACTUAL_SHA="$(shasum -a 256 "$TMP_DL/$ASSET" | awk '{print $1}')"
    else
      log_err "Neither sha256sum nor shasum is available for checksum verification."
      rm -rf "$TMP_DL"
      exit 1
    fi

    EXPECTED_SHA="$(asset_sha_from_sums "$ASSET" "$TMP_DL/SHA256SUMS" || true)"

    if [ -z "$EXPECTED_SHA" ]; then
      log_err "SHA256SUMS must contain exactly one entry for $ASSET (fail-closed)."
      log_err "Sums file: $SUMS_URL"
      rm -rf "$TMP_DL"
      exit 1
    fi

    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      log_err "Checksum verification failed for $ASSET (fail-closed)."
      log_err "Expected: $EXPECTED_SHA"
      log_err "Actual:   $ACTUAL_SHA"
      rm -rf "$TMP_DL"
      exit 1
    fi
    log_info "Checksum verified: $ACTUAL_SHA"

    # Stage the candidate on the destination volume and preflight it.
    # Activation happens later, inside the transaction, by same-filesystem
    # rename so a failure can never leave a partial live binary.
    mkdir -p "$GROKGOD_HOME/bin"
    tx_init
    CANDIDATE_SRC="$GROKGOD_HOME/bin/candidate-$$"
    rm -f "$CANDIDATE_SRC" 2>/dev/null || true
    if ! cp "$TMP_DL/$ASSET" "$CANDIDATE_SRC" 2>/dev/null; then
      log_err "Could not stage candidate at $CANDIDATE_SRC (fail-closed)."
      rm -rf "$TMP_DL"
      exit 1
    fi
    rm -rf "$TMP_DL"
    chmod +x "$CANDIDATE_SRC"
    if [ "$(uname -s)" = "Darwin" ]; then
      codesign -s - --force "$CANDIDATE_SRC" 2>/dev/null || true
    fi
    fail_after stage

preflight_candidate "$CANDIDATE_SRC" "$ASSET"
    fail_after preflight

    # Deferred to the transactional commit point, where the manifest is built
    # from the activated post-codesign binary and both writes roll back together.
    STAMP_CONTENT="$(printf "SHA=%s\nPATCHSET=%s\nVERSION=%s\nMODE=release\n" "$ACTUAL_SHA" "$TAG_NAME" "$TAG_NAME")"
    MANIFEST_INSTALLED=1
    MANIFEST_SHA="$ACTUAL_SHA"
    MANIFEST_VERSION="$TAG_NAME"
    MANIFEST_PATCHSET="$TAG_NAME"
    MANIFEST_SOURCE_SHA="$ACTUAL_SHA"
    MANIFEST_ASSET_SHA="$ACTUAL_SHA"
    MANIFEST_MODE="release"
  fi

  # Resolve runtime scripts
  if [ -z "${GROKGOD_SRC:-}" ]; then
    if [ -d "$GROKGOD_HOME/src" ]; then
      GROKGOD_SRC="$GROKGOD_HOME/src"
      if command -v git >/dev/null 2>&1 && [ -d "$GROKGOD_SRC/.git" ]; then
        git -C "$GROKGOD_SRC" pull --quiet 2>/dev/null || true
      fi
    elif [ -f "$SCRIPT_DIR/src/shim/grok-shim.sh" ]; then
      GROKGOD_SRC="$SCRIPT_DIR"
    else
      log_step "Fetching grokgod runtime scripts..."
      if command -v git >/dev/null 2>&1 && git clone --depth 1 "$GROKGOD_REPO" "$GROKGOD_HOME/src" 2>/dev/null; then
        GROKGOD_SRC="$GROKGOD_HOME/src"
        log_info "Cloned grokgod scripts to $GROKGOD_HOME/src"
      else
        log_info "Fetching runtime scripts from repository..."
        mkdir -p "$GROKGOD_HOME/src/src/shim"
        RAW_TAG="${TAG_NAME:-main}"
        if [ "$RAW_TAG" = "latest" ]; then RAW_TAG="main"; fi
        RAW_BASE="https://raw.githubusercontent.com/${REPO_PATH}/${RAW_TAG}"

        curl -fsSL "$RAW_BASE/src/shim/grok-shim.sh" -o "$GROKGOD_HOME/src/src/shim/grok-shim.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/shim/grok-shim.sh" -o "$GROKGOD_HOME/src/src/shim/grok-shim.sh" || {
          log_err "Failed to download grok-shim.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-cache.sh" -o "$GROKGOD_HOME/src/src/grokgod-cache.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-cache.sh" -o "$GROKGOD_HOME/src/src/grokgod-cache.sh" || {
          log_err "Failed to download grokgod-cache.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-run.sh" -o "$GROKGOD_HOME/src/src/grokgod-run.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-run.sh" -o "$GROKGOD_HOME/src/src/grokgod-run.sh" || {
          log_err "Failed to download grokgod-run.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-pin.sh" -o "$GROKGOD_HOME/src/src/grokgod-pin.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-pin.sh" -o "$GROKGOD_HOME/src/src/grokgod-pin.sh" || {
          log_err "Failed to download grokgod-pin.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-sessions.sh" -o "$GROKGOD_HOME/src/src/grokgod-sessions.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-sessions.sh" -o "$GROKGOD_HOME/src/src/grokgod-sessions.sh" || {
          log_err "Failed to download grokgod-sessions.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-eval.sh" -o "$GROKGOD_HOME/src/src/grokgod-eval.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-eval.sh" -o "$GROKGOD_HOME/src/src/grokgod-eval.sh" || {
          log_err "Failed to download grokgod-eval.sh (fail-closed)."
          exit 1
        }
        curl -fsSL "$RAW_BASE/src/grokgod-eval-health.sh" -o "$GROKGOD_HOME/src/src/grokgod-eval-health.sh" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/src/grokgod-eval-health.sh" -o "$GROKGOD_HOME/src/src/grokgod-eval-health.sh" || {
          log_err "Failed to download grokgod-eval-health.sh (fail-closed)."
          exit 1
        }
        mkdir -p "$GROKGOD_HOME/src/examples"
        curl -fsSL "$RAW_BASE/examples/orca-pin.toml" -o "$GROKGOD_HOME/src/examples/orca-pin.toml" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/examples/orca-pin.toml" -o "$GROKGOD_HOME/src/examples/orca-pin.toml" 2>/dev/null || true
        # Patch registry drives the shim persist block; optional (status degrades
        # to the non-patch persist lines when it cannot be fetched).
        mkdir -p "$GROKGOD_HOME/src/patches"
        curl -fsSL "$RAW_BASE/patches/registry.tsv" -o "$GROKGOD_HOME/src/patches/registry.tsv" 2>/dev/null || \
        curl -fsSL "https://raw.githubusercontent.com/${REPO_PATH}/main/patches/registry.tsv" -o "$GROKGOD_HOME/src/patches/registry.tsv" 2>/dev/null || \
        rm -f "$GROKGOD_HOME/src/patches/registry.tsv"
        chmod +x "$GROKGOD_HOME/src/src/shim/grok-shim.sh" "$GROKGOD_HOME/src/src/grokgod-cache.sh" "$GROKGOD_HOME/src/src/grokgod-run.sh" "$GROKGOD_HOME/src/src/grokgod-pin.sh" "$GROKGOD_HOME/src/src/grokgod-sessions.sh" "$GROKGOD_HOME/src/src/grokgod-eval.sh" "$GROKGOD_HOME/src/src/grokgod-eval-health.sh"
        GROKGOD_SRC="$GROKGOD_HOME/src"
        log_info "Downloaded runtime scripts to $GROKGOD_HOME/src"
      fi
    fi
  fi

  if [ -n "${GROKGOD_SRC:-}" ] && [ -f "$GROKGOD_SRC/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$GROKGOD_SRC/src/shim/grok-shim.sh"
  elif [ -f "$SCRIPT_DIR/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$SCRIPT_DIR/src/shim/grok-shim.sh"
  elif [ -f "$GROKGOD_HOME/src/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$GROKGOD_HOME/src/src/shim/grok-shim.sh"
  else
    log_err "Shim template not found."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────
# SOURCE MODE (Local git + cargo build)
# ─────────────────────────────────────────────────────────
if [ "$MODE" = "source" ]; then
  if [ ! -d "$GROK_BUILD_SRC" ]; then
    log_err "Source directory not found: $GROK_BUILD_SRC"
    exit 1
  fi

  TARGET_SHA=""
  if [ "$NO_UPGRADE" -eq 0 ]; then
    log_step "Fetching upstream changes in $GROK_BUILD_SRC..."
    git -C "$GROK_BUILD_SRC" fetch origin || {
      log_err "Failed to fetch from origin in $GROK_BUILD_SRC"
      exit 1
    }

    if [ -n "$VERSION_SHA" ]; then
      log_info "Verifying commit $VERSION_SHA exists..."
      if ! git -C "$GROK_BUILD_SRC" cat-file -e "${VERSION_SHA}^{commit}" 2>/dev/null; then
        log_err "Commit '$VERSION_SHA' does not exist in $GROK_BUILD_SRC"
        exit 1
      fi
      TARGET_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse "${VERSION_SHA}^{commit}" 2>/dev/null || echo "$VERSION_SHA")"
    else
      TARGET_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse origin/main 2>/dev/null || true)"
      if [ -z "$TARGET_SHA" ]; then
        log_err "Failed to resolve origin/main in $GROK_BUILD_SRC"
        exit 1
      fi
    fi
  else
    TARGET_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse HEAD 2>/dev/null || echo "unknown")"
  fi

  sync_installed_grokgod_src
  NOW_PATCHSET="$(compute_patchset_id)"
  EARLY_NOOP=0
  if [ "$FORCE" -eq 0 ] && [ -x "$GROKGOD_HOME/bin/grok" ] && [ -f "$GROKGOD_HOME/.source-version" ]; then
    STAMP_SHA="$(grep '^SHA=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
    STAMP_PATCHSET="$(grep '^PATCHSET=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
    if [ "$NO_UPGRADE" -eq 1 ]; then
      if [ "$STAMP_SHA" = "$TARGET_SHA" ] && [ "$STAMP_PATCHSET" = "$NOW_PATCHSET" ]; then
        log_info "Matching stamp found (SHA=$TARGET_SHA, PATCHSET=$NOW_PATCHSET) and binary exists."
        log_info "Fast-path: skipping cargo build, updating launchers only."
        EARLY_NOOP=1
      fi
    elif [ "$STAMP_SHA" = "$TARGET_SHA" ] && [ "$STAMP_PATCHSET" = "$NOW_PATCHSET" ] \
        && live_binary_matches_stamp; then
      log_info "Already up to date (SHA=$STAMP_SHA, PATCHSET=$STAMP_PATCHSET)"
      EARLY_NOOP=1
    fi
  fi

  if [ "$EARLY_NOOP" -eq 1 ]; then
    NEED_BUILD=0
  else
    if [ "$NO_UPGRADE" -eq 0 ]; then
      log_info "Checking out target commit $TARGET_SHA..."
      checkout_ref="$TARGET_SHA"
      if [ -z "$VERSION_SHA" ]; then
        main_sha="$(git -C "$GROK_BUILD_SRC" rev-parse --verify refs/heads/main 2>/dev/null || true)"
        if [ -n "$main_sha" ] && [ "$main_sha" = "$TARGET_SHA" ]; then
          checkout_ref="main"
        fi
      fi
      git -C "$GROK_BUILD_SRC" checkout "$checkout_ref" || {
        log_err "Failed to checkout $checkout_ref"
        exit 1
      }
    fi
    NEED_BUILD=1
  fi

  if [ "$NEED_BUILD" -eq 1 ]; then
    log_step "Verifying clean working tree in $GROK_BUILD_SRC..."
    if ! git -C "$GROK_BUILD_SRC" diff --quiet 2>/dev/null; then
      patch_files=""
      if [ -d "$PATCHES_DIR" ]; then
        for p in "$PATCHES_DIR"/*.patch; do
          if [ -f "$p" ]; then
            patch_files="$patch_files $p"
          fi
        done
      fi

      # Newest-first: reverse every patch whose reverse-check succeeds.
      # Skip (do not stop on) patches that are not in the working tree, so a
      # leftover 0001–(N-1) stack still reverses after grokgod adds patch N.
      rev_patch_files=""
      for p in $patch_files; do
        rev_patch_files="$p $rev_patch_files"
      done

      suffix_files=""
      if [ -n "$rev_patch_files" ]; then
        log_info "Previous grokgod patches detected in working tree; reversing newest reverseable suffix..."
        for p in $rev_patch_files; do
          if git -C "$GROK_BUILD_SRC" apply -R --check "$p" 2>/dev/null; then
            git -C "$GROK_BUILD_SRC" apply -R "$p" || {
              log_err "Failed to reverse prior patch $p"
              exit 1
            }
            suffix_files="$suffix_files $p"
          fi
        done
      fi

      if [ -z "$suffix_files" ]; then
        log_leftover_abort "Local leftover: working tree in $GROK_BUILD_SRC is dirty and is not a clean grokgod patch stack."
        exit 1
      fi
      if ! git -C "$GROK_BUILD_SRC" diff --quiet 2>/dev/null; then
        log_leftover_abort "Local leftover: working tree in $GROK_BUILD_SRC is still dirty after reversing patches."
        exit 1
      fi
    fi

    patch_files=""
    if [ -d "$PATCHES_DIR" ]; then
      for p in "$PATCHES_DIR"/*.patch; do
        if [ -f "$p" ]; then
          patch_files="$patch_files $p"
        fi
      done
    fi

    if [ -n "$patch_files" ]; then
      log_step "Testing and applying source patches..."
      for p in $patch_files; do
        log_info "Testing patch: $(basename "$p")"
        if ! git -C "$GROK_BUILD_SRC" apply --check "$p"; then
          log_compat_abort "$(basename "$p")" "does not apply to"
          exit 1
        fi
        log_info "Applying patch: $(basename "$p")"
        if ! git -C "$GROK_BUILD_SRC" apply "$p"; then
          log_compat_abort "$(basename "$p")" "failed to apply to"
          exit 1
        fi
      done
    else
      log_info "No patch files found in $PATCHES_DIR; proceeding with stock build."
    fi

    log_step "Building xai-grok-pager-bin in release mode..."
    (
      cd "$GROK_BUILD_SRC"
      # Incremental off to prevent accumulating ~/.grokgod/target/release/incremental standing state
      CARGO_TARGET_DIR="$CARGO_TARGET_DIR" CARGO_INCREMENTAL=0 cargo build --release -p xai-grok-pager-bin
    ) || {
      log_build_abort
      exit 1
    }

    # Stage the candidate on the destination volume and preflight it.
    # Activation happens later, inside the transaction, by same-filesystem
    # rename so a failure can never leave a partial live binary.
    BUILT_BIN="$CARGO_TARGET_DIR/release/xai-grok-pager"
    if [ ! -f "$BUILT_BIN" ]; then
      log_err "Built binary not found at $BUILT_BIN"
      exit 1
    fi
    mkdir -p "$GROKGOD_HOME/bin"
    tx_init
    CANDIDATE_SRC="$GROKGOD_HOME/bin/candidate-$$"
    rm -f "$CANDIDATE_SRC" 2>/dev/null || true
    if ! cp "$BUILT_BIN" "$CANDIDATE_SRC" 2>/dev/null; then
      log_err "Could not stage candidate at $CANDIDATE_SRC (fail-closed)."
      exit 1
    fi
    chmod +x "$CANDIDATE_SRC"
    if [ "$(uname -s)" = "Darwin" ]; then
      codesign -s - --force "$CANDIDATE_SRC" 2>/dev/null || true
    fi
    fail_after stage

    preflight_candidate "$CANDIDATE_SRC" "source build"
    fail_after preflight

    CURRENT_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse HEAD 2>/dev/null || echo "unknown")"
    # Source stamps record a git commit, not a download digest; the artifact
    # digest is computed from the activated binary at the commit point.
    STAMP_CONTENT="$(printf "SHA=%s\nPATCHSET=%s\nVERSION=%s\nMODE=source\n" "$CURRENT_SHA" "$NOW_PATCHSET" "$CURRENT_SHA")"
    MANIFEST_INSTALLED=1
    MANIFEST_SHA="$CURRENT_SHA"
    MANIFEST_VERSION="$CURRENT_SHA"
    MANIFEST_PATCHSET="$NOW_PATCHSET"
    MANIFEST_SOURCE_SHA="$CURRENT_SHA"
    MANIFEST_ASSET_SHA=""
    MANIFEST_MODE="source"

    if [ -n "$VERSION_SHA" ]; then
      UPSTREAM_ORIGIN_MAIN="$(git -C "$GROK_BUILD_SRC" rev-parse origin/main 2>/dev/null || true)"
      if [ -n "$UPSTREAM_ORIGIN_MAIN" ] && [ "$CURRENT_SHA" != "$UPSTREAM_ORIGIN_MAIN" ]; then
        log_warn "Installed build is pinned behind origin/main ($CURRENT_SHA vs $UPSTREAM_ORIGIN_MAIN). Run unpinned 'grok update' to catch up."
      fi
    fi
  fi

  # Sync runtime files from a grokgod checkout into GROKGOD_HOME/src.
  # PATH `grok update` execs $GROKGOD_HOME/src/install.sh; skip self-copy
  # (macOS `cp src src` exits 1: "are identical (not copied)").
  if [ -f "$SCRIPT_DIR/src/shim/grok-shim.sh" ] && [ -d "$SCRIPT_DIR/patches" ] \
      && [ "$SCRIPT_DIR" != "$GROKGOD_HOME/src" ]; then
    mkdir -p "$GROKGOD_HOME/src"
    cp "$SCRIPT_DIR/install.sh" "$GROKGOD_HOME/src/install.sh"

    mkdir -p "$GROKGOD_HOME/src/patches"
    for pf in "$SCRIPT_DIR"/patches/*.patch; do
      if [ -f "$pf" ]; then
        cp "$pf" "$GROKGOD_HOME/src/patches/"
      fi
    done
    if [ -f "$SCRIPT_DIR/patches/README.md" ]; then
      cp "$SCRIPT_DIR/patches/README.md" "$GROKGOD_HOME/src/patches/README.md"
    fi
    # Registry drives the shim persist block; the installed src tree needs it.
    if [ -f "$SCRIPT_DIR/patches/registry.tsv" ]; then
      cp "$SCRIPT_DIR/patches/registry.tsv" "$GROKGOD_HOME/src/patches/registry.tsv"
    fi

    mkdir -p "$GROKGOD_HOME/src/src" "$GROKGOD_HOME/src/src/shim"
    for sf in "$SCRIPT_DIR"/src/*.sh; do
      if [ -f "$sf" ]; then
        cp "$sf" "$GROKGOD_HOME/src/src/"
      fi
    done
    chmod +x "$GROKGOD_HOME/src/src"/*.sh 2>/dev/null || true
    if [ -f "$SCRIPT_DIR/src/shim/grok-shim.sh" ]; then
      cp "$SCRIPT_DIR/src/shim/grok-shim.sh" "$GROKGOD_HOME/src/src/shim/grok-shim.sh"
      chmod +x "$GROKGOD_HOME/src/src/shim/grok-shim.sh"
    fi

    mkdir -p "$GROKGOD_HOME/src/examples"
    for ef in "$SCRIPT_DIR"/examples/*.toml; do
      if [ -f "$ef" ]; then
        cp "$ef" "$GROKGOD_HOME/src/examples/"
      fi
    done
    if [ -d "$SCRIPT_DIR/examples/eval-home" ]; then
      mkdir -p "$GROKGOD_HOME/src/examples/eval-home/agents"
      if [ -f "$SCRIPT_DIR/examples/eval-home/config.toml" ]; then
        cp "$SCRIPT_DIR/examples/eval-home/config.toml" "$GROKGOD_HOME/src/examples/eval-home/config.toml"
      fi
      if [ -f "$SCRIPT_DIR/examples/eval-home/pager.toml" ]; then
        cp "$SCRIPT_DIR/examples/eval-home/pager.toml" "$GROKGOD_HOME/src/examples/eval-home/pager.toml"
      fi
      if [ -f "$SCRIPT_DIR/examples/eval-home/agents/minimal.md" ]; then
        cp "$SCRIPT_DIR/examples/eval-home/agents/minimal.md" "$GROKGOD_HOME/src/examples/eval-home/agents/minimal.md"
      fi
      if [ -f "$SCRIPT_DIR/examples/eval-home/README.md" ]; then
        cp "$SCRIPT_DIR/examples/eval-home/README.md" "$GROKGOD_HOME/src/examples/eval-home/README.md"
      fi
      if [ -f "$SCRIPT_DIR/examples/eval-home/assets/vision-probe.jpg" ]; then
        mkdir -p "$GROKGOD_HOME/src/examples/eval-home/assets"
        cp "$SCRIPT_DIR/examples/eval-home/assets/vision-probe.jpg" "$GROKGOD_HOME/src/examples/eval-home/assets/vision-probe.jpg"
      fi
    fi
    if [ -f "$SCRIPT_DIR/examples/daily-minimal/minimal.md" ]; then
      mkdir -p "$GROKGOD_HOME/src/examples/daily-minimal"
      cp "$SCRIPT_DIR/examples/daily-minimal/minimal.md" "$GROKGOD_HOME/src/examples/daily-minimal/minimal.md"
    fi
    log_info "Synced runtime files to $GROKGOD_HOME/src"
  fi

  if [ -f "$SCRIPT_DIR/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$SCRIPT_DIR/src/shim/grok-shim.sh"
  elif [ -n "${GROKGOD_SRC:-}" ] && [ -f "$GROKGOD_SRC/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$GROKGOD_SRC/src/shim/grok-shim.sh"
  elif [ -f "$GROKGOD_HOME/src/src/shim/grok-shim.sh" ]; then
    SHIM_SRC="$GROKGOD_HOME/src/src/shim/grok-shim.sh"
  else
    log_err "Shim template not found."
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────
# LAUNCHERS (ClawGod write_launcher pattern)
# ─────────────────────────────────────────────────────────
if [ ! -f "$SHIM_SRC" ]; then
  log_err "Shim template not found at $SHIM_SRC"
  exit 1
fi

# Begin the transaction now that every fail-closed precheck has passed and the
# candidate (if any) is staged and preflighted. Everything below is
# snapshot-backed and rolled back on any later failure.
tx_init

# Atomically activate the staged candidate binary. Same-filesystem rename keeps
# the live path either wholly old or wholly new.
if [ "$MANIFEST_INSTALLED" -eq 1 ]; then
  log_step "Activating candidate binary to $GROKGOD_HOME/bin/grok..."
  tx_rename "$CANDIDATE_SRC" "$GROKGOD_HOME/bin/grok"
  if [ "$MODE" = "source" ]; then
    log_info "Binary installed successfully."
  fi
  fail_after activation
fi

log_step "Installing shim launchers to $BIN_DIR and $GROK_HOME/bin..."
mkdir -p "$BIN_DIR"
mkdir -p "$GROK_HOME/bin"

write_launcher() {
  target="$1"
  is_grok_cmd="$2" # 1 if target is grok, 0 if grokgod

  dir="$(dirname "$target")"
  mkdir -p "$dir"

  # Backup logic for official grok binary / symlink. grok.orig is a durable
  # artifact of a committed install (uninstall restores from it). The backup is
  # a rename into grok.orig so it works for a write-only/unreadable official
  # binary; rollback renames the bytes straight back from grok.orig, which is
  # the one location that survives a failed run.
  if [ "$is_grok_cmd" -eq 1 ]; then
    if [ -e "$target" ] || [ -L "$target" ]; then
      # If it's a regular file containing GROKGOD, it's our shim -> no backup needed
      if [ ! -L "$target" ] && grep -q "GROKGOD" "$target" 2>/dev/null; then
        : # Already our shim
      else
        # It's an official binary or official symlink: replace this run's
        # grok.orig. A pre-existing backup is moved aside as grok.orig.prev and
        # only dropped once the run commits.
        _grok_orig_prev="$dir/grok.orig.prev"
        if [ -e "$_grok_orig_prev" ] || [ -L "$_grok_orig_prev" ]; then
          tx_take "$_grok_orig_prev"
          if [ -e "$_grok_orig_prev" ] || [ -L "$_grok_orig_prev" ]; then
            log_err "Could not clear $_grok_orig_prev for the durable backup (fail-closed)."
            exit 1
          fi
        fi
        _grok_orig_prior=0
        if [ -e "$dir/grok.orig" ] || [ -L "$dir/grok.orig" ]; then
          _grok_orig_prior=1
          if ! mv -f "$dir/grok.orig" "$_grok_orig_prev" 2>/dev/null; then
            log_err "Could not move aside the existing $dir/grok.orig (fail-closed)."
            exit 1
          fi
        fi
        # Journal the replacement pair in the order reverse replay needs: the
        # prior backup first, then the official binary. Rollback replays in
        # reverse, so the official lands back at $target and the prior backup
        # back at grok.orig. Rename needs only directory permission, so a
        # write-only/unreadable official binary is restorable and nothing here
        # reads the bytes.
        if [ "$_grok_orig_prior" -eq 1 ]; then
          printf 'M\t%s\t%s\n' "$dir/grok.orig" "$_grok_orig_prev" >> "$TX_DIR/journal"
          TX_NOTED="$TX_NOTED|$dir/grok.orig|"
        fi
        printf 'M\t%s\t%s\n' "$target" "$dir/grok.orig" >> "$TX_DIR/journal"
        TX_NOTED="$TX_NOTED|$target|"
        if ! mv -f "$target" "$dir/grok.orig" 2>/dev/null; then
          log_err "Could not back up existing grok at $target (fail-closed)."
          exit 1
        fi
        log_info "Backed up existing grok: $target -> $dir/grok.orig"
      fi
    fi
  fi

  # tx_write stages a sibling temp file and renames over the target, so we
  # never write through an existing symlink and never expose a partial file.
  tx_write "$SHIM_SRC" "$target" 755
  log_info "Installed launcher: $target"
}

write_launcher "$BIN_DIR/grok" 1
fail_after launcher-grok
write_launcher "$BIN_DIR/grokgod" 0
fail_after launcher-grokgod
write_launcher "$GROK_HOME/bin/grok" 1
fail_after launcher-grokhome

# Flush shell hash cache
hash -r 2>/dev/null || true

# ─────────────────────────────────────────────────────────
# DAILY MINIMAL AGENT SETUP
# ─────────────────────────────────────────────────────────
maybe_install_daily_minimal() {
  target="$GROK_HOME/agents/minimal.md"
  template=""
  if [ -f "$SCRIPT_DIR/examples/daily-minimal/minimal.md" ]; then
    template="$SCRIPT_DIR/examples/daily-minimal/minimal.md"
  elif [ -n "${GROKGOD_SRC:-}" ] && [ -f "$GROKGOD_SRC/examples/daily-minimal/minimal.md" ]; then
    template="$GROKGOD_SRC/examples/daily-minimal/minimal.md"
  elif [ -f "$GROKGOD_HOME/src/examples/daily-minimal/minimal.md" ]; then
    template="$GROKGOD_HOME/src/examples/daily-minimal/minimal.md"
  fi

  if [ -z "$template" ]; then
    log_warn "Daily minimal agent template not found (examples/daily-minimal/minimal.md); skipping."
    return 0
  fi

  mkdir -p "$GROK_HOME/agents"
  tx_write "$template" "$target" 644
  log_info "Installed daily minimal agent to $target"
}

maybe_install_daily_minimal
fail_after agent

# ─────────────────────────────────────────────────────────
# PIN OVERLAY SETUP
# ─────────────────────────────────────────────────────────
maybe_install_pin_overlay() {
  PIN="$GROKGOD_HOME/pin/grok-overlay.toml"

  if [ -f "$PIN" ]; then
    log_info "pin overlay already present: $PIN"
    return 0
  fi

  template=""
  if [ -n "${GROKGOD_SRC:-}" ] && [ -f "$GROKGOD_SRC/examples/grok-overlay.toml" ]; then
    template="$GROKGOD_SRC/examples/grok-overlay.toml"
  elif [ -f "$SCRIPT_DIR/examples/grok-overlay.toml" ]; then
    template="$SCRIPT_DIR/examples/grok-overlay.toml"
  elif [ -f "$GROKGOD_HOME/src/examples/grok-overlay.toml" ]; then
    template="$GROKGOD_HOME/src/examples/grok-overlay.toml"
  fi

  if [ -z "$template" ]; then
    log_warn "Pin overlay template not found (examples/grok-overlay.toml); skipping pin overlay installation."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Would copy pin overlay template: $template -> $PIN"
    return 0
  fi

  if [ "$YES" -eq 1 ]; then
    mkdir -p "$GROKGOD_HOME/pin"
    tx_write "$template" "$PIN" 644
    log_info "Installed default pin overlay to $PIN"
    return 0
  fi

  if [ -t 0 ]; then
    printf "Install default pin overlay to %s? [y/N] " "$PIN"
    read -r ans || ans=""
    case "$ans" in
      [yY]|[yY][eE][sS])
        mkdir -p "$GROKGOD_HOME/pin"
        tx_write "$template" "$PIN" 644
        log_info "Installed default pin overlay to $PIN"
        ;;
      *)
        log_info "Skipping pin overlay installation."
        ;;
    esac
    return 0
  fi

  log_info "no TTY; pass --yes to install pin template ($PIN)"
  return 0
}

maybe_install_pin_overlay
fail_after pin

# Merge [plan_mode] implement_via_subagents = true into ~/.grok/config.toml
# when the key is absent. Overlay GROK_CONFIG_PATH cannot carry this table.
maybe_merge_plan_mode_config() {
  cfg="$GROK_HOME/config.toml"
  if grep -q '^[[:space:]]*implement_via_subagents[[:space:]]*=' "$cfg" 2>/dev/null; then
    log_info "plan_mode implement_via_subagents already set in $cfg"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Would merge [plan_mode] implement_via_subagents = true into $cfg"
    return 0
  fi
  mkdir -p "$GROK_HOME"
  if [ -f "$cfg" ] && grep -q '^[[:space:]]*\[plan_mode\]' "$cfg"; then
    tmp="$(rewrite_stage "$cfg")"
    awk '
      BEGIN { added=0 }
      /^[[:space:]]*\[plan_mode\]/ && added==0 {
        print
        print "implement_via_subagents = true"
        added=1
        next
      }
      { print }
    ' "$cfg" > "$tmp"
    rewrite_commit "$tmp" "$cfg"
    log_info "Merged implement_via_subagents = true into existing [plan_mode] in $cfg"
    return 0
  fi
  # Same-directory temp + rename so config.toml is never half-written.
  tmp="$(rewrite_stage "$cfg")"
  {
    if [ -f "$cfg" ] && [ -s "$cfg" ]; then
      cat "$cfg"
      printf '\n'
    fi
    printf '[plan_mode]\nimplement_via_subagents = true\n'
  } > "$tmp"
  rewrite_commit "$tmp" "$cfg"
  log_info "Wrote [plan_mode] implement_via_subagents = true to $cfg"
}

maybe_merge_plan_mode_config

# Merge [workflows.builtins] deep-research = false into ~/.grok/config.toml
# when the key is missing so the operator plugin can own /deep-research.
maybe_merge_workflows_builtins_config() {
  cfg="$GROK_HOME/config.toml"
  if grep -q '^[[:space:]]*deep-research[[:space:]]*=' "$cfg" 2>/dev/null; then
    log_info "workflows.builtins deep-research already set in $cfg"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Would merge [workflows.builtins] deep-research = false into $cfg"
    return 0
  fi
  mkdir -p "$GROK_HOME"
  if [ -f "$cfg" ] && grep -q '^[[:space:]]*\[workflows\.builtins\]' "$cfg"; then
    tmp="$(rewrite_stage "$cfg")"
    awk '
      BEGIN { added=0 }
      /^[[:space:]]*\[workflows\.builtins\]/ && added==0 {
        print
        print "deep-research = false"
        added=1
        next
      }
      { print }
    ' "$cfg" > "$tmp"
    rewrite_commit "$tmp" "$cfg"
    log_info "Merged deep-research = false into existing [workflows.builtins] in $cfg"
    return 0
  fi
  # Same-directory temp + rename so config.toml is never half-written.
  tmp="$(rewrite_stage "$cfg")"
  {
    if [ -f "$cfg" ] && [ -s "$cfg" ]; then
      cat "$cfg"
      printf '\n'
    fi
    printf '[workflows.builtins]\ndeep-research = false\n'
  } > "$tmp"
  rewrite_commit "$tmp" "$cfg"
  log_info "Wrote [workflows.builtins] deep-research = false to $cfg"
}

maybe_merge_workflows_builtins_config

# Merge [ui.status_line] builtin "compacts" into ~/.grok/config.toml.
# Overlay GROK_CONFIG_PATH cannot carry this table (command-injection strip).
# Missing section: seed type=builtin with model/turn-timer/session-name/compacts.
# Existing builtin items without "compacts": append, preserving order.
# Leave command/disabled/off/none/hidden, missing type, and builtin-without-items.
maybe_merge_status_line_config() {
  cfg="$GROK_HOME/config.toml"
  action="seed"
  if [ -f "$cfg" ]; then
    action="$(awk '
      function trim(s) {
        gsub(/\r/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      function type_value(s,   q, i) {
        sub(/^[[:space:]]*type[[:space:]]*=[[:space:]]*/, "", s)
        s = trim(s)
        q = substr(s, 1, 1)
        if (q == "\"" || q == "\047") {
          s = substr(s, 2)
          i = index(s, q)
          if (i > 0) s = substr(s, 1, i - 1)
        } else {
          if (match(s, /[[:space:]#;]/)) s = substr(s, 1, RSTART - 1)
        }
        return tolower(trim(s))
      }
      function line_has_compacts(s) {
        return (s ~ /"compacts"/) || (s ~ /\047compacts\047/)
      }
      BEGIN {
        section = 0
        found_section = 0
        type_val = ""
        has_items = 0
        has_compacts = 0
        in_items = 0
      }
      {
        raw = $0
        gsub(/\r/, "", raw)
      }
      /^[[:space:]]*\[[^]]+\]/ {
        if (raw ~ /^[[:space:]]*\[ui\.status_line\][[:space:]]*$/) {
          section = 1
          found_section = 1
          in_items = 0
          next
        }
        section = 0
        in_items = 0
        next
      }
      section == 1 && /^[[:space:]]*#/ { next }
      section == 1 && /^[[:space:]]*type[[:space:]]*=/ {
        type_val = type_value(raw)
      }
      section == 1 && /^[[:space:]]*items[[:space:]]*=/ {
        has_items = 1
        in_items = 1
      }
      in_items {
        if (line_has_compacts(raw)) has_compacts = 1
        if (raw ~ /\]/) in_items = 0
      }
      END {
        if (!found_section) { print "seed"; exit }
        if (type_val == "") { print "leave"; exit }
        if (type_val == "disabled" || type_val == "off" || type_val == "none" || type_val == "hidden") {
          print "leave"; exit
        }
        if (type_val != "builtin") { print "leave"; exit }
        if (!has_items) { print "leave"; exit }
        if (has_compacts) { print "has-compacts"; exit }
        print "append"
      }
    ' "$cfg")"
  fi
  case "$action" in
    has-compacts)
      log_info "ui.status_line items already includes compacts in $cfg"
      return 0
      ;;
    leave)
      return 0
      ;;
    seed|append) ;;
    *)
      action="seed"
      ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    log_dry "Would merge [ui.status_line] builtin items with \"compacts\" into $cfg"
    return 0
  fi
  mkdir -p "$GROK_HOME"
  if [ "$action" = "append" ]; then
    tmp="$(rewrite_stage "$cfg")"
    awk '
      function trim(s) {
        gsub(/\r/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      function last_index(s, ch,   i, p) {
        p = 0
        for (i = 1; i <= length(s); i++) {
          if (substr(s, i, 1) == ch) p = i
        }
        return p
      }
      function leading_ws(s,   i, c) {
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c != " " && c != "\t") return substr(s, 1, i - 1)
        }
        return s
      }
      function ensure_comma(s,   t) {
        t = s
        sub(/[[:space:]]+$/, "", t)
        if (t ~ /,$/) return s
        return t ","
      }
      function rewrite_inline(s,   obr, cbr, pre, inner, post, t) {
        obr = index(s, "[")
        cbr = last_index(s, "]")
        if (obr == 0 || cbr == 0 || cbr < obr) return s
        pre = substr(s, 1, obr)
        inner = substr(s, obr + 1, cbr - obr - 1)
        post = substr(s, cbr)
        t = inner
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
        if (t == "") return pre "\"compacts\"" post
        if (t ~ /,$/) return pre inner " \"compacts\"" post
        return pre inner ", \"compacts\"" post
      }
      function insert_before_close_bracket(s,   cbr, pre, post, t) {
        cbr = last_index(s, "]")
        if (cbr == 0) return s ", \"compacts\""
        pre = substr(s, 1, cbr - 1)
        post = substr(s, cbr)
        t = trim(pre)
        if (t == "") return pre "\"compacts\"" post
        if (t ~ /,$/) return pre " \"compacts\"" post
        return pre ", \"compacts\"" post
      }
      function is_bare_close(s,   t) {
        t = trim(s)
        sub(/[;#].*$/, "", t)
        t = trim(t)
        return (t == "]")
      }
      {
        lines[++n] = $0
      }
      END {
        sec_start = 0
        sec_end = n
        for (i = 1; i <= n; i++) {
          t = lines[i]
          gsub(/\r/, "", t)
          if (t ~ /^[[:space:]]*\[ui\.status_line\][[:space:]]*$/) {
            sec_start = i
            sec_end = n
            for (j = i + 1; j <= n; j++) {
              u = lines[j]
              gsub(/\r/, "", u)
              if (u ~ /^[[:space:]]*\[[^]]+\]/) {
                sec_end = j - 1
                break
              }
            }
            break
          }
        }
        items_start = 0
        items_end = 0
        if (sec_start > 0) {
          for (i = sec_start; i <= sec_end; i++) {
            t = lines[i]
            gsub(/\r/, "", t)
            if (t ~ /^[[:space:]]*items[[:space:]]*=/) {
              items_start = i
              if (index(t, "[") > 0 && index(t, "]") > 0) {
                items_end = i
              } else {
                for (j = i; j <= sec_end; j++) {
                  u = lines[j]
                  gsub(/\r/, "", u)
                  if (j > i && index(u, "]") > 0) {
                    items_end = j
                    break
                  }
                }
              }
              break
            }
          }
        }
        if (items_start == 0 || items_end == 0) {
          for (i = 1; i <= n; i++) print lines[i]
          exit
        }
        for (i = 1; i <= n; i++) {
          if (i == items_start) {
            if (items_start == items_end) {
              print rewrite_inline(lines[i])
            } else if (is_bare_close(lines[items_end])) {
              print lines[items_start]
              last_item = 0
              for (j = items_end - 1; j > items_start; j--) {
                t = trim(lines[j])
                if (t == "" || t ~ /^#/) continue
                last_item = j
                break
              }
              indent = "    "
              if (last_item > 0) {
                ws = leading_ws(lines[last_item])
                if (ws != "") indent = ws
              }
              for (j = items_start + 1; j <= items_end - 1; j++) {
                if (j == last_item) print ensure_comma(lines[j])
                else print lines[j]
              }
              print indent "\"compacts\","
              print lines[items_end]
            } else {
              for (j = items_start; j < items_end; j++) print lines[j]
              print insert_before_close_bracket(lines[items_end])
            }
            i = items_end
            continue
          }
          print lines[i]
        }
      }
    ' "$cfg" > "$tmp"
    rewrite_commit "$tmp" "$cfg"
    log_info "Merged \"compacts\" into existing [ui.status_line] items in $cfg"
    return 0
  fi
  # Same-directory temp + rename so config.toml is never half-written.
  tmp="$(rewrite_stage "$cfg")"
  {
    if [ -f "$cfg" ] && [ -s "$cfg" ]; then
      cat "$cfg"
      printf '\n'
    fi
    printf '%s\n' '[ui.status_line]'
    printf '%s\n' 'type = "builtin"'
    printf '%s\n' 'items = ['
    printf '%s\n' '    "model",'
    printf '%s\n' '    "turn-timer",'
    printf '%s\n' '    "session-name",'
    printf '%s\n' '    "compacts",'
    printf '%s\n' ']'
  } > "$tmp"
  rewrite_commit "$tmp" "$cfg"
  log_info "Wrote [ui.status_line] builtin items including \"compacts\" to $cfg"
}

maybe_merge_status_line_config
fail_after config

# ─────────────────────────────────────────────────────────
# COMMIT POINT
# manifest.json and then .source-version are the last files written.
# Before this, any failure rolls the whole transaction back; after
# it, the new state is authoritative and rollback must not run.
# ─────────────────────────────────────────────────────────
if [ "$MANIFEST_INSTALLED" -eq 1 ]; then
  # The artifact manifest is built from the activated post-codesign binary and
  # staged as a sibling temp before the atomic rename, so a reader never sees a
  # half-written document.
  _manifest_tmp="$GROKGOD_HOME/manifest.json.grokgod-tmp.$$"
  tx_note "$GROKGOD_HOME/manifest.json"
  write_artifact_manifest "$MANIFEST_MODE" "$MANIFEST_VERSION" "$MANIFEST_PATCHSET" \
    "$MANIFEST_SOURCE_SHA" "$MANIFEST_ASSET_SHA" "$_manifest_tmp"
  if artifact_manifest_recorded; then
    if ! mv -f "$_manifest_tmp" "$GROKGOD_HOME/manifest.json" 2>/dev/null; then
      rm -f "$_manifest_tmp" 2>/dev/null || true
      log_warn "Could not commit artifact manifest at $GROKGOD_HOME/manifest.json"
    else
      log_info "Wrote artifact manifest to $GROKGOD_HOME/manifest.json"
    fi
  fi
  rm -f "$_manifest_tmp" 2>/dev/null || true
  fail_after manifest

  tx_note "$GROKGOD_HOME/.source-version"
  _stamp_tmp="$GROKGOD_HOME/.source-version.grokgod-tmp.$$"
  printf '%s\n' "$STAMP_CONTENT" > "$_stamp_tmp"
  mv -f "$_stamp_tmp" "$GROKGOD_HOME/.source-version"
  log_info "Stamped version to $GROKGOD_HOME/.source-version (VERSION=$MANIFEST_VERSION, SHA=$MANIFEST_SHA, MODE=$MANIFEST_MODE)"
  fail_after stamp
fi

tx_commit

# ─────────────────────────────────────────────────────────
# POST-BUILD DISK WARN
# ─────────────────────────────────────────────────────────
free_kb_post="$(get_free_kb "$GROKGOD_HOME")"
if [ -n "$free_kb_post" ] && [ "$free_kb_post" -ge 0 ] 2>/dev/null; then
  if [ "$free_kb_post" -lt "$WARN_FREE_KB" ]; then
    free_gb_post=$(awk -v kb="$free_kb_post" 'BEGIN { printf "%.2f", kb / (1024 * 1024) }')
    log_warn "Low disk space warning: ${free_gb_post} GB remaining (threshold: ${WARN_FREE_GB} GB)."
  fi
fi

log_info "grokgod installation complete!"
