#!/bin/sh
set -eu

# grokgod-pin.sh - assertion and inspection command for grok model pin
# Usage: grokgod pin check [--expect-default <model>] [--expect-no-overlay]

usage() {
  cat << 'EOF' >&2
Usage:
  grokgod pin check [--expect-default <model>] [--expect-no-overlay]
  grokgod pin help | -h | --help

Options:
  --expect-default <model>   Assert that the default model matches <model>
  --expect-no-overlay        Assert that GROK_CONFIG_PATH and GROK_CONFIG are not set
  -h, --help                 Show this help message
EOF
  exit 2
}

if [ $# -lt 1 ]; then
  usage
fi

subcmd="$1"
shift

case "$subcmd" in
  check)
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    ;;
esac

expect_default=""
expect_no_overlay=0

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-default)
      if [ $# -lt 2 ]; then
        echo "error: --expect-default requires a model argument" >&2
        usage
      fi
      expect_default="$2"
      shift 2
      ;;
    --expect-no-overlay)
      expect_no_overlay=1
      shift
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

# Resolve grok binary
GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROK_BIN=""
if [ -x "$GROKGOD_HOME/bin/grok" ]; then
  GROK_BIN="$GROKGOD_HOME/bin/grok"
elif command -v grok >/dev/null 2>&1; then
  GROK_BIN="$(command -v grok)"
else
  echo "error: grok binary not found in $GROKGOD_HOME/bin/grok or PATH" >&2
  exit 127
fi

# Run grok models and parse default model
models_out="$("$GROK_BIN" models 2>/dev/null)" || {
  echo "error: failed to execute '$GROK_BIN models'" >&2
  exit 1
}

actual_default="$(printf "%s\n" "$models_out" | sed -n -E 's/^[[:space:]]*Default model:[[:space:]]+([^[:space:]]+).*/\1/p' | head -n 1)"
if [ -z "$actual_default" ]; then
  echo "error: unable to parse Default model from grok models output" >&2
  exit 1
fi

# Flagless mode
if [ -z "$expect_default" ] && [ "$expect_no_overlay" -eq 0 ]; then
  cfg_path_set="false"
  cfg_set="false"
  if [ -n "${GROK_CONFIG_PATH:-}" ]; then cfg_path_set="true"; fi
  if [ -n "${GROK_CONFIG:-}" ]; then cfg_set="true"; fi
  echo "pin_check facts default_model=$actual_default GROK_CONFIG_PATH_set=$cfg_path_set GROK_CONFIG_set=$cfg_set"
  exit 0
fi

# Assertion checks
if [ "$expect_no_overlay" -eq 1 ]; then
  if [ -n "${GROK_CONFIG_PATH:-}" ]; then
    echo "pin_check fail overlay_env_set GROK_CONFIG_PATH=${GROK_CONFIG_PATH}" >&2
    exit 1
  fi
  if [ -n "${GROK_CONFIG:-}" ]; then
    echo "pin_check fail overlay_env_set GROK_CONFIG=${GROK_CONFIG}" >&2
    exit 1
  fi
fi

if [ -n "$expect_default" ]; then
  if [ "$actual_default" != "$expect_default" ]; then
    echo "pin_check fail default_model=$actual_default expect=$expect_default" >&2
    exit 1
  fi
fi

echo "pin_check ok default_model=$actual_default"
exit 0
