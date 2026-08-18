#!/bin/sh
set -eu

# grokgod install.sh - POSIX sh installer / patch wrapper for grok-build
# Usage: install.sh [--version SHA] [--no-upgrade] [--uninstall] [--dry-run] [--prefix DIR]

# Environment variable defaults
GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
GROK_BUILD_SRC="${GROK_BUILD_SRC:-$HOME/Desktop/code/grok-build}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$GROKGOD_HOME/target}"
DF_CMD="${DF_CMD:-df}"

MIN_FREE_GB=15
WARN_FREE_GB=10
MIN_FREE_KB=$((MIN_FREE_GB * 1024 * 1024))
WARN_FREE_KB=$((WARN_FREE_GB * 1024 * 1024))

VERSION_SHA=""
NO_UPGRADE=0
UNINSTALL=0
DRY_RUN=0
PREFIX=""

# Resolve repo root directory (where install.sh resides)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
SHIM_SRC="$SCRIPT_DIR/src/shim/grok-shim.sh"

log_info() {
  printf "  \033[0;32m✓\033[0m %s\n" "$1"
}

log_warn() {
  printf "  \033[0;33m!\033[0m %s\n" "$1" >&2
}

log_err() {
  printf "  \033[0;31m✗\033[0m %s\n" "$1" >&2
}

log_step() {
  printf "\033[1m==> %s\033[0m\n" "$1"
}

log_dry() {
  printf "  \033[0;34m[dry-run]\033[0m %s\n" "$1"
}

# Parse CLI arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      if [ $# -lt 2 ]; then
        log_err "--version requires a SHA argument"
        exit 1
      fi
      VERSION_SHA="$2"
      shift 2
      ;;
    --no-upgrade)
      NO_UPGRADE=1
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
      echo "Usage: install.sh [--version SHA] [--no-upgrade] [--uninstall] [--dry-run] [--prefix DIR]"
      exit 0
      ;;
    *)
      log_err "Unknown option: $1"
      echo "Usage: install.sh [--version SHA] [--no-upgrade] [--uninstall] [--dry-run] [--prefix DIR]" >&2
      exit 1
      ;;
  esac
done

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
      # Find latest matching grok-* file (excluding grok.orig or grokgod)
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
# 2. DISK GUARD (Pre-build)
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
# 11. DRY-RUN MODE FLOW
# ─────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  log_step "Running dry-run checks..."

  # Check source directory exists
  if [ ! -d "$GROK_BUILD_SRC" ]; then
    log_err "GROK_BUILD_SRC directory not found: $GROK_BUILD_SRC"
    exit 1
  fi

  # Read-only git SHA existence check if version specified
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
      log_dry "Would checkout: git -C $GROK_BUILD_SRC checkout origin/main"
    fi
  else
    log_dry "Skipping git fetch/checkout (--no-upgrade)"
  fi

  # Check patch files
  patch_list=""
  if [ -d "$PATCHES_DIR" ]; then
    for p in "$PATCHES_DIR"/*.patch; do
      if [ -f "$p" ]; then
        patch_list="$patch_list $p"
      fi
    done
  fi

  if [ -n "$patch_list" ]; then
    for p in $patch_list; do
      log_dry "Would test and apply patch: $p"
      # Test apply --check against GROK_BUILD_SRC if clean or check feasibility
      if git -C "$GROK_BUILD_SRC" apply --check "$p" 2>/dev/null; then
        log_dry "  -> patch $(basename "$p") applies cleanly"
      elif git -C "$GROK_BUILD_SRC" apply -R --check "$p" 2>/dev/null; then
        log_dry "  -> patch $(basename "$p") is already applied (reversibly clean)"
      else
        log_warn "  -> patch $(basename "$p") dry-run check failed against current working tree"
      fi
    done
  else
    log_dry "No patches found; would build stock"
  fi

  log_dry "Would build: CARGO_TARGET_DIR=$CARGO_TARGET_DIR cargo build --release -p xai-grok-pager-bin (in $GROK_BUILD_SRC)"
  log_dry "Would copy binary: cp $CARGO_TARGET_DIR/release/xai-grok-pager $GROKGOD_HOME/bin/grok"
  log_dry "Would stamp: $GROKGOD_HOME/.source-version"
  log_dry "Would install launchers: $BIN_DIR/grok, $BIN_DIR/grokgod, and $GROK_HOME/bin/grok"
  log_info "Dry-run completed successfully (no changes made)."
  exit 0
fi

# ─────────────────────────────────────────────────────────
# 3. GIT UPGRADE / CHECKOUT
# ─────────────────────────────────────────────────────────
if [ ! -d "$GROK_BUILD_SRC" ]; then
  log_err "Source directory not found: $GROK_BUILD_SRC"
  exit 1
fi

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
    log_info "Checking out $VERSION_SHA..."
    git -C "$GROK_BUILD_SRC" checkout "$VERSION_SHA" || {
      log_err "Failed to checkout $VERSION_SHA"
      exit 1
    }
  else
    log_info "Checking out origin/main..."
    git -C "$GROK_BUILD_SRC" checkout origin/main || {
      log_err "Failed to checkout origin/main"
      exit 1
    }
  fi
fi

# ─────────────────────────────────────────────────────────
# Fast-path check for --no-upgrade
# ─────────────────────────────────────────────────────────
CURRENT_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse HEAD 2>/dev/null || echo "unknown")"
CURRENT_PATCHSET="$(compute_patchset_id)"

NEED_BUILD=1
if [ "$NO_UPGRADE" -eq 1 ] && [ -x "$GROKGOD_HOME/bin/grok" ] && [ -f "$GROKGOD_HOME/.source-version" ]; then
  STAMP_SHA="$(grep '^SHA=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
  STAMP_PATCHSET="$(grep '^PATCHSET=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
  if [ "$STAMP_SHA" = "$CURRENT_SHA" ] && [ "$STAMP_PATCHSET" = "$CURRENT_PATCHSET" ]; then
    log_info "Matching stamp found (SHA=$CURRENT_SHA, PATCHSET=$CURRENT_PATCHSET) and binary exists."
    log_info "Fast-path: skipping cargo build, updating launchers only."
    NEED_BUILD=0
  fi
fi

if [ "$NEED_BUILD" -eq 1 ]; then
  # ─────────────────────────────────────────────────────────
  # 4. VERIFY CLEAN TREE & REVERSE PRIOR PATCHES IF NEEDED
  # ─────────────────────────────────────────────────────────
  log_step "Verifying clean working tree in $GROK_BUILD_SRC..."
  if ! git -C "$GROK_BUILD_SRC" diff --quiet 2>/dev/null; then
    # Working tree is dirty. Check if it matches our patch set in reverse
    can_reverse=1
    patch_files=""
    if [ -d "$PATCHES_DIR" ]; then
      for p in "$PATCHES_DIR"/*.patch; do
        if [ -f "$p" ]; then
          patch_files="$patch_files $p"
        fi
      done
    fi

    if [ -n "$patch_files" ]; then
      # Reverse order check
      for p in $patch_files; do
        if ! git -C "$GROK_BUILD_SRC" apply -R --check "$p" 2>/dev/null; then
          can_reverse=0
          break
        fi
      done
    else
      can_reverse=0
    fi

    if [ "$can_reverse" -eq 1 ]; then
      log_info "Previous grokgod patches detected in working tree; reversing them..."
      for p in $patch_files; do
        git -C "$GROK_BUILD_SRC" apply -R "$p" || {
          log_err "Failed to reverse prior patch $p"
          exit 1
        }
      done
      # Verify tree is clean now
      if ! git -C "$GROK_BUILD_SRC" diff --quiet 2>/dev/null; then
        log_err "Working tree in $GROK_BUILD_SRC is still dirty after reversing patches. Aborting (fail-closed)."
        exit 1
      fi
    else
      log_err "Working tree in $GROK_BUILD_SRC is dirty and does not match clean grokgod patches."
      log_err "Aborting (fail-closed); please resolve git status in $GROK_BUILD_SRC."
      exit 1
    fi
  fi

  # ─────────────────────────────────────────────────────────
  # 5. APPLY PATCHES (Fail-closed)
  # ─────────────────────────────────────────────────────────
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
    # 5a. First dry-run check ALL patches
    for p in $patch_files; do
      log_info "Testing patch: $(basename "$p")"
      if ! git -C "$GROK_BUILD_SRC" apply --check "$p"; then
        log_err "Patch check failed for $(basename "$p"). Aborting (fail-closed)."
        log_err "Existing binary in $GROKGOD_HOME/bin/grok is untouched."
        exit 1
      fi
    done

    # 5b. Apply for real
    for p in $patch_files; do
      log_info "Applying patch: $(basename "$p")"
      if ! git -C "$GROK_BUILD_SRC" apply "$p"; then
        log_err "Failed to apply patch $(basename "$p"). Aborting (fail-closed)."
        exit 1
      fi
    done
  else
    log_info "No patch files found in $PATCHES_DIR; proceeding with stock build."
  fi

  # ─────────────────────────────────────────────────────────
  # 6. BUILD
  # ─────────────────────────────────────────────────────────
  log_step "Building xai-grok-pager-bin in release mode..."
  (
    cd "$GROK_BUILD_SRC"
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" cargo build --release -p xai-grok-pager-bin
  ) || {
    log_err "Cargo build failed. Aborting (fail-closed)."
    exit 1
  }

  # ─────────────────────────────────────────────────────────
  # 7. INSTALL BINARY
  # ─────────────────────────────────────────────────────────
  log_step "Installing binary to $GROKGOD_HOME/bin/grok..."
  BUILT_BIN="$CARGO_TARGET_DIR/release/xai-grok-pager"
  if [ ! -f "$BUILT_BIN" ]; then
    log_err "Built binary not found at $BUILT_BIN"
    exit 1
  fi

  mkdir -p "$GROKGOD_HOME/bin"
  cp "$BUILT_BIN" "$GROKGOD_HOME/bin/grok"
  chmod +x "$GROKGOD_HOME/bin/grok"

  if [ "$(uname -s)" = "Darwin" ]; then
    codesign -s - --force "$GROKGOD_HOME/bin/grok" 2>/dev/null || true
  fi
  log_info "Binary installed successfully."

  # ─────────────────────────────────────────────────────────
  # 8. STAMP
  # ─────────────────────────────────────────────────────────
  CURRENT_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse HEAD 2>/dev/null || echo "unknown")"
  CURRENT_PATCHSET="$(compute_patchset_id)"
  printf "SHA=%s\nPATCHSET=%s\n" "$CURRENT_SHA" "$CURRENT_PATCHSET" > "$GROKGOD_HOME/.source-version"
  log_info "Stamped version to $GROKGOD_HOME/.source-version (SHA=$CURRENT_SHA, PATCHSET=$CURRENT_PATCHSET)"
fi

# ─────────────────────────────────────────────────────────
# 9. LAUNCHERS (ClawGod write_launcher pattern)
# ─────────────────────────────────────────────────────────
log_step "Installing shim launchers to $BIN_DIR and $GROK_HOME/bin..."
mkdir -p "$BIN_DIR"
mkdir -p "$GROK_HOME/bin"

if [ ! -f "$SHIM_SRC" ]; then
  log_err "Shim template not found at $SHIM_SRC"
  exit 1
fi

write_launcher() {
  target="$1"
  is_grok_cmd="$2" # 1 if target is grok, 0 if grokgod

  dir="$(dirname "$target")"
  mkdir -p "$dir"

  # Backup logic for official grok binary / symlink
  if [ "$is_grok_cmd" -eq 1 ]; then
    if [ -e "$target" ] || [ -L "$target" ]; then
      # If it's a regular file containing GROKGOD, it's our shim -> no backup needed
      if [ ! -L "$target" ] && grep -q "GROKGOD" "$target" 2>/dev/null; then
        : # Already our shim
      else
        # It's an official binary or official symlink -> back up to grok.orig
        mv "$target" "$dir/grok.orig"
        log_info "Backed up existing grok: $target -> $dir/grok.orig"
      fi
    fi
  fi

  # CRITICAL: Always rm -f before copying so we never write through an existing symlink
  rm -f "$target"
  cp "$SHIM_SRC" "$target"
  chmod 755 "$target"
  log_info "Installed launcher: $target"
}

write_launcher "$BIN_DIR/grok" 1
write_launcher "$BIN_DIR/grokgod" 0
write_launcher "$GROK_HOME/bin/grok" 1

# Flush shell hash cache
hash -r 2>/dev/null || true

# ─────────────────────────────────────────────────────────
# 10. POST-BUILD DISK WARN
# ─────────────────────────────────────────────────────────
free_kb_post="$(get_free_kb "$GROKGOD_HOME")"
if [ -n "$free_kb_post" ] && [ "$free_kb_post" -ge 0 ] 2>/dev/null; then
  if [ "$free_kb_post" -lt "$WARN_FREE_KB" ]; then
    free_gb_post=$(awk -v kb="$free_kb_post" 'BEGIN { printf "%.2f", kb / (1024 * 1024) }')
    log_warn "Low disk space warning: ${free_gb_post} GB remaining (threshold: ${WARN_FREE_GB} GB)."
  fi
fi

log_info "grokgod installation complete!"
