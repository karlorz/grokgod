#!/bin/sh
set -eu

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROKGOD_BIN="$GROKGOD_HOME/bin/grok"

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
    echo "  overlay-pin: $overlay_status"
    echo "  weekly-pin: global-default"
    if [ -f "$GROKGOD_HOME/pin/orca-pin.toml" ]; then
      echo "  orca-pin: enabled"
    else
      echo "  orca-pin: disabled"
    fi
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
