#!/bin/sh
set -eu

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROKGOD_BIN="$GROKGOD_HOME/bin/grok"
GROK_BUILD_SRC="${GROK_BUILD_SRC:-$HOME/Desktop/code/grok-build}"

# Fall back to ~/.grokgod/src or $HOME/Desktop/code/grokgod (dev host compat)
if [ -n "${GROKGOD_SRC:-}" ]; then
  : # Keep explicitly provided GROKGOD_SRC
elif [ -d "$GROKGOD_HOME/src" ]; then
  GROKGOD_SRC="$GROKGOD_HOME/src"
elif [ -d "$HOME/Desktop/code/grokgod" ]; then
  GROKGOD_SRC="$HOME/Desktop/code/grokgod"
else
  GROKGOD_SRC="$GROKGOD_HOME/src"
fi

get_cargo_version() {
  git_ref="$1"
  raw="$(git -C "$GROK_BUILD_SRC" show "${git_ref}:crates/codegen/xai-grok-pager-bin/Cargo.toml" 2>/dev/null || true)"
  if [ -n "$raw" ]; then
    printf "%s\n" "$raw" | sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

# Evaluates source drift against local origin/main ref.
# Sets DRIFT_STATUS, INSTALLED_SHA, UPSTREAM_SHA, INSTALLED_VER, UPSTREAM_VER,
# INSTALLED_SHORT, UPSTREAM_SHORT.
compute_source_drift() {
  DRIFT_STATUS="unknown"
  INSTALLED_SHA=""
  UPSTREAM_SHA=""
  INSTALLED_VER=""
  UPSTREAM_VER=""
  INSTALLED_SHORT=""
  UPSTREAM_SHORT=""

  if [ ! -f "$GROKGOD_HOME/.source-version" ]; then
    return 0
  fi
  INSTALLED_SHA="$(grep '^SHA=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$INSTALLED_SHA" ]; then
    return 0
  fi

  if [ ! -d "$GROK_BUILD_SRC" ] || ! git -C "$GROK_BUILD_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi

  UPSTREAM_SHA="$(git -C "$GROK_BUILD_SRC" rev-parse origin/main 2>/dev/null || true)"
  if [ -z "$UPSTREAM_SHA" ]; then
    return 0
  fi

  INSTALLED_SHORT="$(printf "%.8s" "$INSTALLED_SHA")"
  UPSTREAM_SHORT="$(printf "%.8s" "$UPSTREAM_SHA")"

  if [ "$INSTALLED_SHA" = "$UPSTREAM_SHA" ]; then
    DRIFT_STATUS="current"
    return 0
  fi

  if git -C "$GROK_BUILD_SRC" merge-base --is-ancestor "$INSTALLED_SHA" "$UPSTREAM_SHA" 2>/dev/null; then
    DRIFT_STATUS="behind"
    INSTALLED_VER="$(get_cargo_version "$INSTALLED_SHA")"
    UPSTREAM_VER="$(get_cargo_version "$UPSTREAM_SHA")"
    return 0
  fi

  if git -C "$GROK_BUILD_SRC" merge-base --is-ancestor "$UPSTREAM_SHA" "$INSTALLED_SHA" 2>/dev/null; then
    DRIFT_STATUS="ahead"
    return 0
  fi

  DRIFT_STATUS="diverged"
  return 0
}

cmd="${1:-}"

case "$cmd" in
  update)
    shift || true
    # Detect mode from stamp or default to release
    MODE_ARG=""
    if [ -f "$GROKGOD_HOME/.source-version" ]; then
      INST_MODE="$(grep '^MODE=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
      if [ "$INST_MODE" = "source" ]; then
        MODE_ARG="--from-source"
      fi
    fi
    if [ -n "$MODE_ARG" ]; then
      exec sh "$GROKGOD_SRC/install.sh" "$MODE_ARG" "$@"
    else
      exec sh "$GROKGOD_SRC/install.sh" "$@"
    fi
    ;;
  status)
    echo "shim: $0"
    echo "target binary: $GROKGOD_BIN"
    if [ -e "$GROKGOD_BIN" ]; then
      echo "target binary exists: yes"
    else
      echo "target binary exists: no"
    fi

    if [ -f "$GROKGOD_HOME/.source-version" ]; then
      echo "source-version: $(cat "$GROKGOD_HOME/.source-version" 2>/dev/null)"
    else
      echo "source-version: none"
    fi

    local_grok="${HOME:-}/.local/bin/grok"
    if [ -f "$local_grok" ] && grep -q "GROKGOD" "$local_grok" 2>/dev/null; then
      echo "~/.local/bin/grok is grokgod shim: yes"
    else
      echo "~/.local/bin/grok is grokgod shim: no"
    fi

    df_dir="$GROKGOD_HOME"
    if [ ! -d "$df_dir" ]; then
      df_dir="$(dirname "$df_dir")"
    fi
    df_output="$(df -h "$df_dir" 2>/dev/null | tail -n 1 || true)"
    echo "free disk: $df_output"

    patchset_val=""
    if [ -f "$GROKGOD_HOME/.source-version" ]; then
      patchset_val="$(grep '^PATCHSET=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [ -e "$GROKGOD_BIN" ] && [ -n "$patchset_val" ]; then
      patch_status="applied"
    else
      patch_status="missing"
    fi

    if [ -f "$GROKGOD_SRC/src/grokgod-run.sh" ]; then
      overlay_status="wrapper"
    else
      overlay_status="missing"
    fi

    echo "persist:"
    echo "  0001-normalize-plugin-skill-join: $patch_status"
    echo "  0002-plan-mode-extra-writable: $patch_status"
    echo "  0003-session-persist-single: $patch_status"
    echo "  0004-disable-builtin-deep-research: $patch_status"
    echo "  0005-model-tools-deny-allow: $patch_status"
    echo "  0006-web-search-call-tolerant-parse: $patch_status"
    echo "  0007-hosted-web-search-splice-decouple: $patch_status"
    echo "  overlay-pin: $overlay_status"
    echo "  weekly-pin: global-default"
    if [ -f "$GROKGOD_HOME/pin/orca-pin.toml" ]; then
      echo "  orca-pin: enabled"
    else
      echo "  orca-pin: disabled"
    fi

    compute_source_drift
    case "$DRIFT_STATUS" in
      current)
        echo "source-drift: current ($INSTALLED_SHORT)"
        ;;
      behind)
        echo "source-drift: behind"
        if [ -n "$INSTALLED_VER" ]; then
          echo "  installed: $INSTALLED_VER ($INSTALLED_SHORT)"
        else
          echo "  installed: ($INSTALLED_SHORT)"
        fi
        if [ -n "$UPSTREAM_VER" ]; then
          echo "  origin/main: $UPSTREAM_VER ($UPSTREAM_SHORT)"
        else
          echo "  origin/main: ($UPSTREAM_SHORT)"
        fi
        echo "  hint: grok update"
        ;;
      ahead)
        echo "source-drift: ahead"
        ;;
      diverged)
        echo "source-drift: diverged"
        ;;
      *)
        echo "source-drift: unknown"
        ;;
    esac
    exit 0
    ;;
  cache)
    shift || true
    cache_script="$GROKGOD_SRC/src/grokgod-cache.sh"
    if [ -f "$cache_script" ]; then
      exec sh "$cache_script" "$@"
    else
      echo "grokgod cache not installed" >&2
      exit 1
    fi
    ;;
  pin)
    shift || true
    pin_script="$GROKGOD_SRC/src/grokgod-pin.sh"
    if [ -f "$pin_script" ]; then
      exec sh "$pin_script" "$@"
    else
      echo "grokgod pin not installed" >&2
      exit 1
    fi
    ;;
  sessions)
    # Official `grok sessions` must reach the grok binary. Only argv0 grokgod
    # runs the wrapper prune.
    if [ "$(basename "$0")" = "grokgod" ]; then
      shift || true
      sessions_script="$GROKGOD_SRC/src/grokgod-sessions.sh"
      if [ -f "$sessions_script" ]; then
        exec sh "$sessions_script" "$@"
      else
        echo "grokgod sessions not installed" >&2
        exit 1
      fi
    fi
    export GROK_DISABLE_AUTOUPDATER=1
    if [ ! -x "$GROKGOD_BIN" ]; then
      echo "error: grokgod binary not found or not executable at $GROKGOD_BIN" >&2
      echo "hint: run 'grokgod update' to build/install" >&2
      exit 127
    fi
    exec "$GROKGOD_BIN" "$@"
    ;;
  run)
    shift || true
    exec sh "$GROKGOD_SRC/src/grokgod-run.sh" "$@"
    ;;
  *)
    export GROK_DISABLE_AUTOUPDATER=1
    if [ ! -x "$GROKGOD_BIN" ]; then
      echo "error: grokgod binary not found or not executable at $GROKGOD_BIN" >&2
      echo "hint: run 'grokgod update' to build/install" >&2
      exit 127
    fi

    # Check for --version / -V to warn on stderr if source is behind origin/main
    if [ "$#" -gt 0 ] && { [ "$1" = "--version" ] || [ "$1" = "-V" ]; }; then
      compute_source_drift
      set +e
      "$GROKGOD_BIN" "$@"
      bin_exit=$?
      set -eu
      if [ "$DRIFT_STATUS" = "behind" ]; then
        if [ -n "$UPSTREAM_VER" ]; then
          echo "grokgod: source behind origin/main $UPSTREAM_VER ($UPSTREAM_SHORT); run: grok update" >&2
        else
          echo "grokgod: source behind origin/main ($UPSTREAM_SHORT); run: grok update" >&2
        fi
      fi
      exit "$bin_exit"
    fi

    # Orca automation overlay: Orca launches automations as `grok -- <prompt>`.
    # Interactive Orca grok tags (bare `grok` / `-m` / `--resume`) keep
    # config.toml default. Do NOT overwrite a caller-set GROK_CONFIG_PATH.
    ORCA_PIN_FILE="$GROKGOD_HOME/pin/orca-pin.toml"
    if [ "${1:-}" = "--" ] && [ -n "${ORCA_WORKTREE_ID:-}" ] && [ -z "${GROK_CONFIG_PATH:-}" ] && [ -f "$ORCA_PIN_FILE" ]; then
        export GROK_CONFIG_PATH="$ORCA_PIN_FILE"
    fi
    exec "$GROKGOD_BIN" "$@"
    ;;
esac
