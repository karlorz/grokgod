#!/bin/sh
set -eu

# grokgod-sessions.sh — attended prune of grok session dirs via official CLI
# Usage: grokgod sessions prune [--dry-run] [--yes|-y] [--max-age Nd]

if [ "${GROK_HOME+x}" = "x" ] && [ -z "$GROK_HOME" ]; then
  echo "error: GROK_HOME is empty (refusing to operate for safety)" >&2
  exit 1
fi

if [ -z "${GROK_HOME:-}" ]; then
  if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
    echo "error: GROK_HOME is empty (refusing to operate for safety)" >&2
    exit 1
  fi
  GROK_HOME="$HOME/.grok"
fi

if [ -z "$GROK_HOME" ] || [ "$GROK_HOME" = "/" ]; then
  echo "error: GROK_HOME is empty or '/' (refusing to operate for safety)" >&2
  exit 1
fi

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
SESSIONS_ROOT="$GROK_HOME/sessions"
DEFAULT_MAX_AGE="7d"

is_uuid() {
  echo "$1" | grep -E -q '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

dir_mtime() {
  # BSD `stat -f %m` is mtime. GNU `stat -f` is --file-system and succeeds
  # with a prose dump, so `|| stat -c` never runs. Keep only a digit epoch.
  mt="$(stat -f %m "$1" 2>/dev/null || true)"
  case "$mt" in
    ''|*[!0-9]*) mt="$(stat -c %Y "$1" 2>/dev/null || echo "")" ;;
  esac
  echo "$mt"
}

dir_size() {
  if [ -e "$1" ]; then
    du -sh "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "none"
  fi
}

parse_max_age_secs() {
  raw="$1"
  case "$raw" in
    [0-9]*d)
      days="${raw%d}"
      case "$days" in
        ''|*[!0-9]*) return 1 ;;
      esac
      echo $((days * 86400))
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

age_label() {
  age="$1"
  if [ "$age" -lt 86400 ]; then
    echo "${age}s"
  else
    echo "$((age / 86400))d"
  fi
}

show_help() {
  echo "Usage: grokgod sessions prune [--dry-run] [--yes] [--max-age Nd]"
  echo ""
  echo "List or delete old grok session dirs under \$GROK_HOME/sessions."
  echo "Deletes only via 'grok sessions delete <id>'. Never rm -rf."
  echo "Default is dry-run. Default --max-age is ${DEFAULT_MAX_AGE}."
  echo "Only 'grokgod sessions' is this wrapper; 'grok sessions' stays official."
}

resolve_grok_bin() {
  if command -v grok >/dev/null 2>&1; then
    command -v grok
    return 0
  fi
  if [ -x "${GROKGOD_HOME}/bin/grok" ]; then
    echo "${GROKGOD_HOME}/bin/grok"
    return 0
  fi
  return 1
}

list_candidates() {
  max_secs="$1"
  now_s="$(date +%s)"
  if [ ! -d "$SESSIONS_ROOT" ]; then
    return 0
  fi
  for cwd_key in "$SESSIONS_ROOT"/*; do
    [ -d "$cwd_key" ] || continue
    cwd_base="$(basename "$cwd_key")"
    for sid_dir in "$cwd_key"/*; do
      [ -d "$sid_dir" ] || continue
      sid="$(basename "$sid_dir")"
      if ! is_uuid "$sid"; then
        echo "warning: skip non-uuid session dir: $sid_dir" >&2
        continue
      fi
      if [ -n "${GROK_SESSION_ID:-}" ] && [ "$sid" = "$GROK_SESSION_ID" ]; then
        continue
      fi
      mt="$(dir_mtime "$sid_dir")"
      if [ -z "$mt" ]; then
        echo "warning: skip unreadable mtime: $sid_dir" >&2
        continue
      fi
      age=$((now_s - mt))
      if [ "$age" -lt "$max_secs" ]; then
        continue
      fi
      sz="$(dir_size "$sid_dir")"
      printf '%s\t%s\t%s\t%s\n' "$sid" "$cwd_base" "$(age_label "$age")" "$sz"
    done
  done
}

do_prune() {
  dry_run="$1"
  force_yes="$2"
  max_age_raw="$3"

  if ! max_secs="$(parse_max_age_secs "$max_age_raw")"; then
    echo "error: invalid --max-age '$max_age_raw' (want Nd, e.g. 7d)" >&2
    exit 1
  fi

  if [ "$dry_run" -eq 0 ] && [ "$force_yes" -eq 0 ]; then
    if [ ! -t 0 ]; then
      echo "error: stdin is not a tty and --yes was not specified. Aborting." >&2
      exit 1
    fi
    printf "Delete old sessions (max-age %s) via grok sessions delete? [y/N] " "$max_age_raw"
    read -r answer || answer="n"
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *)
        echo "Prune aborted."
        exit 1
        ;;
    esac
  fi

  cand_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$cand_file'" EXIT INT TERM
  list_candidates "$max_secs" > "$cand_file" || true

  if [ ! -s "$cand_file" ]; then
    echo "no matching sessions older than $max_age_raw"
    return 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo "dry-run (max-age $max_age_raw):"
    echo "id	cwd	age	size"
    cat "$cand_file"
    return 0
  fi

  if ! grok_bin="$(resolve_grok_bin)"; then
    echo "error: grok not found (need grok sessions delete)" >&2
    exit 1
  fi

  failed=0
  deleted=0
  while IFS="$(printf '\t')" read -r sid cwd_base age_h sz; do
    [ -n "$sid" ] || continue
    if "$grok_bin" sessions delete "$sid"; then
      deleted=$((deleted + 1))
    else
      echo "error: grok sessions delete failed: $sid (cwd=$cwd_base age=$age_h size=$sz)" >&2
      failed=$((failed + 1))
    fi
  done < "$cand_file"

  echo "deleted via grok sessions delete: $deleted (failed: $failed)"
  if [ "$failed" -ne 0 ]; then
    exit 1
  fi
}

action=""
dry_run=1
force_yes=0
max_age="$DEFAULT_MAX_AGE"
explicit_yes=0

if [ $# -eq 0 ]; then
  show_help
  exit 1
fi

cmd="$1"
shift || true

case "$cmd" in
  prune)
    action="prune"
    ;;
  help|-h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "Unknown argument: $cmd (only 'prune' is supported)" >&2
    show_help >&2
    exit 1
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --yes|-y)
      force_yes=1
      explicit_yes=1
      dry_run=0
      shift
      ;;
    --max-age)
      if [ -z "${2:-}" ]; then
        echo "error: --max-age requires Nd" >&2
        exit 1
      fi
      max_age="$2"
      shift 2
      ;;
    --max-age=*)
      max_age="${1#--max-age=}"
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

# --dry-run after --yes keeps dry-run (safe default if both passed last-wins
# except we already processed in order; if user passed --yes only, dry_run=0)
if [ "$explicit_yes" -eq 0 ]; then
  dry_run=1
fi

do_prune "$dry_run" "$force_yes" "$max_age"
