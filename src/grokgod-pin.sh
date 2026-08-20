#!/bin/sh
set -eu

# grokgod-pin.sh - assertion and inspection command for grok model pin
# Usage: grokgod pin check [--expect-default <model>] [--expect-no-overlay] [--expect-orca-pin <model>]

usage() {
  cat << 'EOF' >&2
Usage:
  grokgod pin check [--expect-default <model>] [--expect-no-overlay] [--expect-orca-pin <model>]
  grokgod pin help | -h | --help

Options:
  --expect-default <model>    Assert that the default model matches <model>
  --expect-no-overlay         Assert that GROK_CONFIG_PATH and GROK_CONFIG are not set
  --expect-orca-pin <model>   Assert that orca-pin.toml exists and pins <model>
  -h, --help                  Show this help message
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
expect_orca_pin=""

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
    --expect-orca-pin)
      if [ $# -lt 2 ]; then
        echo "error: --expect-orca-pin requires a model argument" >&2
        usage
      fi
      expect_orca_pin="$2"
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

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"

# Check orca-pin if requested
if [ -n "$expect_orca_pin" ]; then
  orca_pin_file="$GROKGOD_HOME/pin/orca-pin.toml"
  if [ ! -f "$orca_pin_file" ]; then
    echo "pin_check fail orca_pin_missing" >&2
    exit 1
  fi
  orca_pin_default="$(sed -n -E 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$orca_pin_file" | head -n 1)"
  if [ "$orca_pin_default" != "$expect_orca_pin" ]; then
    echo "pin_check fail orca_pin default_model=${orca_pin_default:-none} expect=$expect_orca_pin" >&2
    exit 1
  fi
  if [ -z "$expect_default" ] && [ "$expect_no_overlay" -eq 0 ]; then
    echo "pin_check ok orca_pin default_model=$expect_orca_pin"
    exit 0
  fi
fi

# Resolve grok binary
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
if [ -z "$expect_default" ] && [ "$expect_no_overlay" -eq 0 ] && [ -z "$expect_orca_pin" ]; then
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

if [ -n "$expect_orca_pin" ]; then
  echo "pin_check ok default_model=$actual_default orca_pin default_model=$expect_orca_pin"
else
  echo "pin_check ok default_model=$actual_default"
fi
exit 0
