#!/bin/sh
set -eu

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROKGOD_BIN="$GROKGOD_HOME/bin/grok"
GROKGOD_SRC="${GROKGOD_SRC:-$HOME/Desktop/code/grokgod}"

cmd="${1:-}"

case "$cmd" in
  update)
    shift || true
    exec sh "$GROKGOD_SRC/install.sh" "$@"
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
  *)
    export GROK_DISABLE_AUTOUPDATER=1
    if [ ! -x "$GROKGOD_BIN" ]; then
      echo "error: grokgod binary not found or not executable at $GROKGOD_BIN" >&2
      echo "hint: run 'grokgod update' to build/install" >&2
      exit 127
    fi
    exec "$GROKGOD_BIN" "$@"
    ;;
esac
