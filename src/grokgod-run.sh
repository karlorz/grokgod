#!/bin/sh
set -eu

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
GROKGOD_BIN="${GROKGOD_BIN:-$GROKGOD_HOME/bin/grok}"

automation_root=""
overlay_file=""
prompt_file=""
prompt_text=""
dry_run=0

usage() {
  cat << 'EOF' >&2
Usage:
  grokgod run --automation-root DIR [--prompt-file FILE | --prompt "text"] [--dry-run] [-- [GROK_ARGS...]]
  grokgod run --overlay FILE [--prompt-file FILE | --prompt "text"] [--dry-run] [-- [GROK_ARGS...]]

Options:
  --automation-root DIR   Directory containing grok-overlay.toml and launchd-prompt.txt
  --overlay FILE          Explicit path to overlay TOML file
  --prompt-file FILE      Explicit path to prompt file
  --prompt "text"         Inline prompt string
  --dry-run               Print env and argv that would be executed and exit 0
  --                      Pass all subsequent arguments directly to grok (before -p)
  -h, --help              Show this help message
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --)
      shift
      break
      ;;
    --automation-root)
      [ $# -ge 2 ] || { echo "error: --automation-root requires a directory argument" >&2; exit 1; }
      automation_root="$2"
      shift 2
      ;;
    --overlay)
      [ $# -ge 2 ] || { echo "error: --overlay requires a file argument" >&2; exit 1; }
      overlay_file="$2"
      shift 2
      ;;
    --prompt-file)
      [ $# -ge 2 ] || { echo "error: --prompt-file requires a file argument" >&2; exit 1; }
      prompt_file="$2"
      shift 2
      ;;
    --prompt)
      [ $# -ge 2 ] || { echo "error: --prompt requires a text argument" >&2; exit 1; }
      prompt_text="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
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

if [ -z "$automation_root" ] && [ -z "$overlay_file" ]; then
  echo "error: either --automation-root or --overlay must be specified" >&2
  exit 1
fi

if [ -n "$automation_root" ] && [ -n "$overlay_file" ]; then
  echo "error: cannot specify both --automation-root and --overlay" >&2
  exit 1
fi

if [ -n "$prompt_file" ] && [ -n "$prompt_text" ]; then
  echo "error: cannot specify both --prompt-file and --prompt" >&2
  exit 1
fi

# Resolve automation_root to absolute path and validate
if [ -n "$automation_root" ]; then
  case "$automation_root" in
    /*) abs_automation_root="$automation_root" ;;
    *)  abs_automation_root="$PWD/$automation_root" ;;
  esac

  # Normalize trailing slashes (except root '/')
  while [ "$abs_automation_root" != "/" ] && [ "${abs_automation_root%/}" != "$abs_automation_root" ]; do
    abs_automation_root="${abs_automation_root%/}"
  done

  # Safety check: reject DIR == $HOME or DIR == ~/.grok or DIR == ~/.grokgod
  real_home="${HOME:-}"
  while [ -n "$real_home" ] && [ "$real_home" != "/" ] && [ "${real_home%/}" != "$real_home" ]; do
    real_home="${real_home%/}"
  done

  if [ -n "$real_home" ]; then
    if [ "$abs_automation_root" = "$real_home" ]; then
      echo "error: automation root cannot be \$HOME ($real_home)" >&2
      exit 1
    fi
    if [ "$abs_automation_root" = "$real_home/.grok" ]; then
      echo "error: automation root cannot be ~/.grok ($real_home/.grok)" >&2
      exit 1
    fi
    if [ "$abs_automation_root" = "$real_home/.grokgod" ]; then
      echo "error: automation root cannot be ~/.grokgod ($real_home/.grokgod)" >&2
      exit 1
    fi
  fi

  if [ ! -d "$abs_automation_root" ]; then
    echo "error: automation root directory does not exist: $abs_automation_root" >&2
    exit 1
  fi

  target_overlay="$abs_automation_root/grok-overlay.toml"
  if [ ! -f "$target_overlay" ]; then
    echo "error: missing grok-overlay.toml in automation root: $abs_automation_root" >&2
    exit 1
  fi

  # Default prompt file if neither --prompt-file nor --prompt was given
  if [ -z "$prompt_file" ] && [ -z "$prompt_text" ]; then
    prompt_file="$abs_automation_root/launchd-prompt.txt"
  fi
else
  # --overlay was specified
  case "$overlay_file" in
    /*) target_overlay="$overlay_file" ;;
    *)  target_overlay="$PWD/$overlay_file" ;;
  esac

  if [ ! -f "$target_overlay" ]; then
    echo "error: overlay file does not exist: $target_overlay" >&2
    exit 1
  fi
fi

# Overlay content guard: reject files containing forbidden sections/keys indicating a full config.toml copy
# Forbidden: ^\[mcp_servers\], ^\[auth\], ^\[plugins\], ^\[subagents, or api_key
# Ignore comment lines starting with '#'
if grep -v '^[[:space:]]*#' "$target_overlay" | grep -E -q '^[[:space:]]*\[mcp_servers\]|^[[:space:]]*\[auth\]|^[[:space:]]*\[plugins\]|^[[:space:]]*\[subagents|api_key'; then
  echo "error: overlay file contains forbidden sections or keys (mcp_servers, auth, plugins, subagents, or api_key): $target_overlay" >&2
  exit 1
fi

# Determine final prompt text
if [ -n "$prompt_text" ]; then
  final_prompt="$prompt_text"
elif [ -n "$prompt_file" ]; then
  case "$prompt_file" in
    /*) abs_prompt_file="$prompt_file" ;;
    *)  abs_prompt_file="$PWD/$prompt_file" ;;
  esac

  if [ ! -f "$abs_prompt_file" ]; then
    echo "error: prompt file does not exist: $abs_prompt_file" >&2
    exit 1
  fi

  final_prompt="$(cat "$abs_prompt_file")"
else
  echo "error: no prompt provided (must provide --prompt, --prompt-file, or launchd-prompt.txt in automation root)" >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  echo "GROK_CONFIG_PATH=$target_overlay"
  if [ $# -gt 0 ]; then
    echo "EXEC: $GROKGOD_BIN $* -p $final_prompt"
  else
    echo "EXEC: $GROKGOD_BIN -p $final_prompt"
  fi
  exit 0
fi

export GROK_CONFIG_PATH="$target_overlay"
exec "$GROKGOD_BIN" "$@" -p "$final_prompt"
