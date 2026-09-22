#!/bin/sh
set -eu

# grokgod-eval.sh — isolated DeepSeek benchmark chat.
# Wrapper, not a grok-build source patch. Uses a private GROK_HOME so plugins,
# memory, MCP, and ~/.grok/agents overlays from the daily harness do not load.

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROKGOD_BIN="${GROKGOD_BIN:-$GROKGOD_HOME/bin/grok}"
GROKGOD_SRC="${GROKGOD_SRC:-}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
if [ -z "$GROKGOD_SRC" ]; then
  case "$SCRIPT_DIR" in
    */src) GROKGOD_SRC="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)" ;;
    *) GROKGOD_SRC="$SCRIPT_DIR" ;;
  esac
fi

EVAL_HOME="${GROKGOD_EVAL_HOME:-$GROKGOD_HOME/eval-home}"
MODEL="deepseek-v4-flash"
DRY_RUN=0
RESET=0

usage() {
  cat << 'EOF' >&2
Usage:
  grokgod eval [--dry-run] [--reset] [--home DIR] [--model ID] [-- [GROK_ARGS...]]

Isolated DeepSeek Harness **Minimal** (极简模式) chat. Daily grok stays
Standard. Sets GROK_HOME to a clean eval home: no plugins, no memory, no MCP,
`--agent minimal`. Native vision is prompt-attached images, not read_file.

Options:
  --dry-run     Print env and argv, do not exec grok
  --reset       Re-seed eval-home files from examples/eval-home
  --home DIR    Eval GROK_HOME (default: $GROKGOD_HOME/eval-home)
  --model ID    Model id (default: deepseek-v4-flash)
  --            Extra args forwarded to grok
  -h, --help    Show this help

Auth: export CLIAPI_API_KEY or NEW_API_KEY. Do not put api_key in the eval home.

Vision: paste or @-attach the image. Do not type "read /path/to.jpg".
EOF
  exit 1
}

has_model_flag() {
  _prev=""
  for _a in "$@"; do
    case "$_a" in
      -m|--model) return 0 ;;
      --model=*) return 0 ;;
    esac
    case "$_prev" in
      -m|--model) return 0 ;;
    esac
    _prev="$_a"
  done
  return 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --)
      shift
      break
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --home)
      [ $# -ge 2 ] || { echo "error: --home requires a directory" >&2; exit 1; }
      EVAL_HOME="$2"
      shift 2
      ;;
    --model)
      [ $# -ge 2 ] || { echo "error: --model requires an id" >&2; exit 1; }
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "error: unrecognized option '$1'" >&2
      usage
      ;;
  esac
done

TEMPLATE="$GROKGOD_SRC/examples/eval-home"
if [ ! -d "$TEMPLATE" ]; then
  echo "error: eval-home template missing: $TEMPLATE" >&2
  echo "hint: run from the grokgod checkout, or reinstall with install.sh --no-upgrade" >&2
  exit 1
fi
if [ ! -f "$TEMPLATE/config.toml" ] || [ ! -f "$TEMPLATE/agents/minimal.md" ]; then
  echo "error: eval-home template incomplete: $TEMPLATE" >&2
  exit 1
fi

seed_eval_home() {
  force="$1"
  mkdir -p "$EVAL_HOME/agents"
  if [ "$force" = "1" ] || [ ! -f "$EVAL_HOME/config.toml" ]; then
    cp "$TEMPLATE/config.toml" "$EVAL_HOME/config.toml"
  fi
  if [ "$force" = "1" ] || [ ! -f "$EVAL_HOME/pager.toml" ]; then
    if [ -f "$TEMPLATE/pager.toml" ]; then
      cp "$TEMPLATE/pager.toml" "$EVAL_HOME/pager.toml"
    fi
  fi
  if [ "$force" = "1" ] || [ ! -f "$EVAL_HOME/agents/minimal.md" ]; then
    cp "$TEMPLATE/agents/minimal.md" "$EVAL_HOME/agents/minimal.md"
  fi
  if [ "$force" = "1" ]; then
    rm -f "$EVAL_HOME/agents/deepseek-eval.md"
  fi
  if [ -f "$TEMPLATE/assets/vision-probe.jpg" ]; then
    mkdir -p "$EVAL_HOME/assets"
    if [ "$force" = "1" ] || [ ! -f "$EVAL_HOME/assets/vision-probe.jpg" ]; then
      cp "$TEMPLATE/assets/vision-probe.jpg" "$EVAL_HOME/assets/vision-probe.jpg"
    fi
  fi
}

seed_eval_home "$RESET"

if [ ! -x "$GROKGOD_BIN" ]; then
  echo "error: grokgod binary not found or not executable at $GROKGOD_BIN" >&2
  echo "hint: run 'grokgod update' to build/install" >&2
  exit 127
fi

# Isolation: do not inherit the daily overlay or Orca pin.
unset GROK_CONFIG_PATH GROK_CONFIG || true

export GROK_HOME="$EVAL_HOME"
export GROK_MEMORY=0
export GROK_SUBAGENTS=0
export GROK_DISABLE_AUTOUPDATER=1

set -- --no-leader --no-memory --no-subagents --no-plan --disable-web-search \
  --agent minimal --sandbox read-only --permission-mode dontAsk --minimal \
  "$@"

if ! has_model_flag "$@"; then
  set -- -m "$MODEL" "$@"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "GROK_HOME=$GROK_HOME"
  echo "GROK_MEMORY=$GROK_MEMORY"
  echo "GROK_SUBAGENTS=$GROK_SUBAGENTS"
  echo "GROK_DISABLE_AUTOUPDATER=$GROK_DISABLE_AUTOUPDATER"
  echo "GROK_CONFIG_PATH=${GROK_CONFIG_PATH:-}"
  echo "MODEL=$MODEL"
  printf 'ARGV:%s' "$GROKGOD_BIN"
  for _a in "$@"; do
    printf ' %s' "$_a"
  done
  printf '\n'
  if [ -z "${CLIAPI_API_KEY:-}" ] && [ -z "${NEW_API_KEY:-}" ]; then
    echo "hint: export CLIAPI_API_KEY or NEW_API_KEY before a real run" >&2
  fi
  exit 0
fi

if [ -z "${CLIAPI_API_KEY:-}" ] && [ -z "${NEW_API_KEY:-}" ]; then
  echo "error: set CLIAPI_API_KEY or NEW_API_KEY (eval home has no api_key)" >&2
  exit 1
fi

exec "$GROKGOD_BIN" "$@"
