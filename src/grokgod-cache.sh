#!/bin/sh
set -eu

# grokgod-cache.sh - grokgod disk cache reporting and guarded cleanup subcommand
# Usage: grokgod cache [report | clean [--yes] | --auto-clean | help | -h | --help]

# Safety guard: refuse to operate if GROKGOD_HOME is empty or "/"
# Note: If GROKGOD_HOME is unset or set to empty string explicitly, check both
if [ "${GROKGOD_HOME+x}" = "x" ] && [ -z "$GROKGOD_HOME" ]; then
  echo "error: GROKGOD_HOME is empty (refusing to operate for safety)" >&2
  exit 1
fi

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
DF_CMD="${DF_CMD:-df}"
WARN_FREE_GB=10
WARN_FREE_KB=$((WARN_FREE_GB * 1024 * 1024))

if [ -z "$GROKGOD_HOME" ] || [ "$GROKGOD_HOME" = "/" ]; then
  echo "error: GROKGOD_HOME is empty or '/' (refusing to operate for safety)" >&2
  exit 1
fi

TARGET_DIR="$GROKGOD_HOME/target"
CARGO_REGISTRY="$HOME/.cargo/registry"
CARGO_GIT="$HOME/.cargo/git"

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

# Helper: get human readable free disk line
get_free_disk_line() {
  check_dir="$GROKGOD_HOME"
  while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ] && [ "$check_dir" != "." ]; do
    check_dir="$(dirname "$check_dir")"
  done
  if [ ! -d "$check_dir" ]; then
    check_dir="/"
  fi
  $DF_CMD -h "$check_dir" 2>/dev/null | tail -n 1 || true
}

# Helper: get human size of a path (if exists)
get_size() {
  path="$1"
  if [ -e "$path" ]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}'
  else
    echo "none"
  fi
}

show_help() {
  echo "Usage: grokgod cache [COMMAND | OPTION]"
  echo ""
  echo "Commands:"
  echo "  report            Print cache sizes, free disk space, and warnings (default)"
  echo "  clean [--yes]     Remove target directory ($TARGET_DIR)"
  echo "  help, -h, --help  Show this help text"
  echo ""
  echo "Options:"
  echo "  --auto-clean      Clean target directory if free disk < ${WARN_FREE_GB} GiB; otherwise report"
  echo "  --yes, -y         Skip confirmation prompt for clean"
}

do_report() {
  echo "grokgod cache report:"
  if [ -d "$TARGET_DIR" ]; then
    target_sz="$(get_size "$TARGET_DIR")"
    echo "  target dir:       $TARGET_DIR ($target_sz)"
  else
    echo "  target dir:       $TARGET_DIR (does not exist)"
  fi

  if [ -d "$GROKGOD_HOME" ]; then
    home_sz="$(get_size "$GROKGOD_HOME")"
    echo "  grokgod home:     $GROKGOD_HOME ($home_sz)"
  else
    echo "  grokgod home:     $GROKGOD_HOME (does not exist)"
  fi

  GROK_HOME="${GROK_HOME:-${HOME:-}/.grok}"
  SESSIONS_DIR="$GROK_HOME/sessions"
  echo ""
  echo "grok sessions:"
  if [ -n "$GROK_HOME" ] && [ "$GROK_HOME" != "/" ] && [ -d "$SESSIONS_DIR" ]; then
    sess_sz="$(get_size "$SESSIONS_DIR")"
    echo "  sessions dir:     $SESSIONS_DIR ($sess_sz)"
    now_s="$(date +%s)"
    n_sess=0
    n_lt1=0
    n_1_7=0
    n_7_14=0
    n_14_30=0
    n_gt30=0
    for cwd_key in "$SESSIONS_DIR"/*; do
      [ -d "$cwd_key" ] || continue
      for sid_dir in "$cwd_key"/*; do
        [ -d "$sid_dir" ] || continue
        sid="$(basename "$sid_dir")"
        echo "$sid" | grep -E -q '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || continue
        n_sess=$((n_sess + 1))
        mt=""
        # BSD `stat -f %m` is mtime. GNU `stat -f` is --file-system and
        # succeeds with a prose dump, so `|| stat -c` never runs on Linux CI.
        mt="$(stat -f %m "$sid_dir" 2>/dev/null || true)"
        case "$mt" in
          ''|*[!0-9]*) mt="$(stat -c %Y "$sid_dir" 2>/dev/null || echo "")" ;;
        esac
        if [ -z "$mt" ]; then
          continue
        fi
        age=$((now_s - mt))
        if [ "$age" -lt 86400 ]; then
          n_lt1=$((n_lt1 + 1))
        elif [ "$age" -lt 604800 ]; then
          n_1_7=$((n_1_7 + 1))
        elif [ "$age" -lt 1209600 ]; then
          n_7_14=$((n_7_14 + 1))
        elif [ "$age" -lt 2592000 ]; then
          n_14_30=$((n_14_30 + 1))
        else
          n_gt30=$((n_gt30 + 1))
        fi
      done
    done
    echo "  session dirs:     $n_sess"
    echo "  session age:      <1d=$n_lt1  1-7d=$n_1_7  7-14d=$n_7_14  14-30d=$n_14_30  >30d=$n_gt30"
  else
    echo "  sessions dir:     $SESSIONS_DIR (does not exist)"
  fi

  echo ""
  echo "cargo cache (read-only):"
  if [ -d "$CARGO_REGISTRY" ]; then
    reg_sz="$(get_size "$CARGO_REGISTRY")"
    echo "  cargo registry:   $CARGO_REGISTRY ($reg_sz)"
  else
    echo "  cargo registry:   $CARGO_REGISTRY (does not exist)"
  fi

  if [ -d "$CARGO_GIT" ]; then
    git_sz="$(get_size "$CARGO_GIT")"
    echo "  cargo git:        $CARGO_GIT ($git_sz)"
  else
    echo "  cargo git:        $CARGO_GIT (does not exist)"
  fi

  echo ""
  free_line="$(get_free_disk_line)"
  echo "free disk: $free_line"

  free_kb="$(get_free_kb "$GROKGOD_HOME")"
  if [ -n "$free_kb" ] && [ "$free_kb" -ge 0 ] 2>/dev/null; then
    if [ "$free_kb" -lt "$WARN_FREE_KB" ]; then
      free_gb=$(awk -v kb="$free_kb" 'BEGIN { printf "%.2f", kb / (1024 * 1024) }')
      echo "warning: Low disk space! Only ${free_gb} GiB free (threshold: ${WARN_FREE_GB} GiB)." >&2
    fi
  fi
}

do_clean() {
  auto_mode="${1:-0}"
  force_yes="${2:-0}"

  if [ ! -d "$TARGET_DIR" ]; then
    echo "Target directory $TARGET_DIR does not exist; nothing to clean."
    return 0
  fi

  target_sz="$(get_size "$TARGET_DIR")"

  if [ "$auto_mode" -eq 1 ]; then
    echo "Auto-cleaning $TARGET_DIR ($target_sz) due to low disk space..."
  elif [ "$force_yes" -eq 1 ]; then
    echo "Removing $TARGET_DIR ($target_sz)..."
  else
    # Interactive confirmation check
    if [ ! -t 0 ]; then
      echo "error: stdin is not a tty and --yes was not specified. Aborting." >&2
      exit 1
    fi
    printf "Remove %s (%s)? [y/N] " "$TARGET_DIR" "$target_sz"
    read -r answer || answer="n"
    case "$answer" in
      [yY]|[yY][eE][sS])
        echo "Removing $TARGET_DIR ($target_sz)..."
        ;;
      *)
        echo "Clean aborted."
        exit 1
        ;;
    esac
  fi

  rm -rf "$TARGET_DIR"
  echo "Freed estimated: $target_sz"
  new_free_line="$(get_free_disk_line)"
  echo "New free disk: $new_free_line"
}

# Main command line parser
action=""
yes_flag=0

while [ $# -gt 0 ]; do
  case "$1" in
    report)
      if [ -z "$action" ]; then action="report"; fi
      shift
      ;;
    clean)
      action="clean"
      shift
      ;;
    --auto-clean)
      action="auto-clean"
      shift
      ;;
    --yes|-y)
      yes_flag=1
      shift
      ;;
    help|-h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

if [ -z "$action" ]; then
  action="report"
fi

case "$action" in
  report)
    do_report
    ;;
  clean)
    do_clean 0 "$yes_flag"
    ;;
  auto-clean)
    free_kb="$(get_free_kb "$GROKGOD_HOME")"
    if [ -n "$free_kb" ] && [ "$free_kb" -ge 0 ] 2>/dev/null && [ "$free_kb" -lt "$WARN_FREE_KB" ]; then
      do_clean 1 1
    else
      echo "free space OK, nothing to do"
    fi
    ;;
esac
