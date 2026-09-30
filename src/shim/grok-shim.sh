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

# Persist lines come from the machine-readable registry (patches/registry.tsv):
# `id<TAB>name<TAB>file` rows whose `name` is the status key. The registry lives
# beside the patches in the installed src tree; an unusable registry (absent,
# unreadable, older install) simply omits the numbered lines instead of failing
# or truncating `grok status`.
resolve_registry_path() {
  for _candidate in \
    "${GROKGOD_SRC:-}/patches/registry.tsv" \
    "$GROKGOD_HOME/src/patches/registry.tsv"
  do
    if [ -n "$_candidate" ] && [ -f "$_candidate" ] && [ -r "$_candidate" ]; then
      printf "%s\n" "$_candidate"
      return 0
    fi
  done
  return 1
}

# Prints one `  <name>: <status>` line per registered patch, in registry order.
# Only 4-digit unique ids are accepted, so a truncated, duplicated, or otherwise
# damaged registry never renders a wrong or repeated patch line; a read failure
# degrades to printing nothing (status still completes).
print_registry_persist() {
  _reg_path="$1"
  _reg_status="$2"
  awk -v status="$_reg_status" '
    BEGIN { FS = "\t" }
    length($1) == 4 && $1 ~ /^[0-9]+$/ && NF == 3 && !seen[$1]++ {
      printf "  %s: %s\n", $2, status
    }
  ' "$_reg_path" 2>/dev/null || true
}

# Prints the registry patch `name` values, one per line, in registry order.
# Shares print_registry_persist's acceptance rules so the JSON inventory and
# the human block can never disagree about which rows are real.
registry_persist_names() {
  _rn_path="$1"
  awk '
    BEGIN { FS = "\t" }
    length($1) == 4 && $1 ~ /^[0-9]+$/ && NF == 3 && !seen[$1]++ { print $2 }
  ' "$_rn_path" 2>/dev/null || true
}

fast_forward_or_reset_repo() {
  repo="$1"
  upstream="$(git -C "$repo" rev-parse origin/main 2>/dev/null || true)"
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"

  if [ -z "$upstream" ] || [ -z "$head" ]; then
    echo "grokgod: could not resolve upstream or HEAD at $repo" >&2
    return 1
  fi

  # 1. If head is not upstream and head is not an ancestor of upstream:
  if [ "$head" != "$upstream" ] && ! git -C "$repo" merge-base --is-ancestor "$head" "$upstream" 2>/dev/null; then
    echo "grokgod: src has local commits (not fast-forward) at $repo" >&2
    return 1
  fi

  # 2. Otherwise classify the worktree with no mutations yet:
  has_tracked_changes=0
  tab="$(printf '\t')"

  diff_out="$(git -C "$repo" diff --name-status --no-renames HEAD 2>/dev/null || true)"
  if [ -n "$diff_out" ]; then
    has_tracked_changes=1
    while IFS="$tab" read -r status path || [ -n "$status" ]; do
      [ -z "$status" ] && continue
      case "$status" in
        D)
          if git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          ;;
        A|M|T)
          if [ ! -f "$repo/$path" ]; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          if ! git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          if ! git -C "$repo" show "origin/main:$path" 2>/dev/null | cmp -s "$repo/$path" -; then
            echo "grokgod: src differs from origin/main: $path" >&2
            return 1
          fi
          ;;
        *)
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
          ;;
      esac
    done << EOF_DIFF
$diff_out
EOF_DIFF
  fi

  blockers=""
  untracked_out="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null || true)"
  if [ -n "$untracked_out" ]; then
    while IFS= read -r path || [ -n "$path" ]; do
      [ -z "$path" ] && continue

      if git -C "$repo" cat-file -e "origin/main:$path" 2>/dev/null; then
        if [ -d "$repo/$path" ]; then
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
        if [ ! -f "$repo/$path" ]; then
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
        if git -C "$repo" show "origin/main:$path" 2>/dev/null | cmp -s "$repo/$path" -; then
          if [ -z "$blockers" ]; then
            blockers="$path"
          else
            blockers="$blockers
$path"
          fi
        else
          echo "grokgod: src differs from origin/main: $path" >&2
          return 1
        fi
      else
        cur="$path"
        while [ "$cur" != "." ] && [ "$cur" != "/" ]; do
          cur="$(dirname "$cur")"
          [ "$cur" = "." ] || [ "$cur" = "/" ] && break
          if git -C "$repo" cat-file -e "origin/main:$cur" 2>/dev/null; then
            if [ -d "$repo/$cur" ]; then
              echo "grokgod: src differs from origin/main: $cur" >&2
              return 1
            fi
          fi
        done
      fi
    done << EOF_UNTRACKED
$untracked_out
EOF_UNTRACKED
  fi

  # 3. If there was any tracked change or any matching untracked blocker:
  if [ "$has_tracked_changes" -eq 1 ] || [ -n "$blockers" ]; then
    if ! git -C "$repo" symbolic-ref -q HEAD >/dev/null 2>&1; then
      echo "grokgod: src is detached; refusing to reset $repo" >&2
      return 1
    fi
    if [ -n "$blockers" ]; then
      while IFS= read -r b_file || [ -n "$b_file" ]; do
        [ -z "$b_file" ] && continue
        rm -f "$repo/$b_file"
      done << EOF_BLOCKERS
$blockers
EOF_BLOCKERS
    fi
    if ! git -C "$repo" reset --hard origin/main >/dev/null 2>&1; then
      echo "grokgod: src reset failed at $repo" >&2
      return 1
    fi
    return 0
  fi

  # 4. If the tree had no tracked changes and no blockers:
  git -C "$repo" pull --ff-only
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

is_release_version() {
  printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$'
}

version_core_greater() {
  candidate="$1"
  installed="$2"

  if ! is_release_version "$candidate" || ! is_release_version "$installed"; then
    return 1
  fi

  candidate_core="$(printf '%s\n' "$candidate" | sed 's/^v\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*$/\1.\2.\3/')"
  installed_core="$(printf '%s\n' "$installed" | sed 's/^v\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*$/\1.\2.\3/')"

  old_ifs="$IFS"
  IFS=.
  set -- $candidate_core
  candidate_major="$1"
  candidate_minor="$2"
  candidate_patch="$3"
  set -- $installed_core
  installed_major="$1"
  installed_minor="$2"
  installed_patch="$3"
  IFS="$old_ifs"

  for pair in \
    "$candidate_major:$installed_major" \
    "$candidate_minor:$installed_minor" \
    "$candidate_patch:$installed_patch"
  do
    candidate_part="${pair%%:*}"
    installed_part="${pair#*:}"
    candidate_part="$(printf '%s\n' "$candidate_part" | sed 's/^0*//')"
    installed_part="$(printf '%s\n' "$installed_part" | sed 's/^0*//')"
    [ -n "$candidate_part" ] || candidate_part=0
    [ -n "$installed_part" ] || installed_part=0

    if [ "${#candidate_part}" -gt "${#installed_part}" ]; then
      return 0
    fi
    if [ "${#candidate_part}" -lt "${#installed_part}" ]; then
      return 1
    fi
    if [ "$candidate_part" != "$installed_part" ]; then
      highest="$(printf '%s\n%s\n' "$candidate_part" "$installed_part" | LC_ALL=C sort | tail -n 1)"
      [ "$highest" = "$candidate_part" ]
      return
    fi
  done

  return 1
}

write_update_cache() {
  checked_at="$1"
  cached_version="$2"
  update_cache="$GROKGOD_HOME/.update-check"
  update_tmp="$update_cache.tmp.$$"

  umask 077
  {
    printf 'CHECKED_AT=%s\n' "$checked_at"
    if [ -n "$cached_version" ]; then
      printf 'VERSION=%s\n' "$cached_version"
    fi
  } > "$update_tmp" || return 1
  mv -f "$update_tmp" "$update_cache"
}

maybe_notice_and_refresh_update() {
  [ "${GROKGOD_UPDATE_CHECK_DISABLE:-0}" != "1" ] || return 0
  [ "${0##*/}" = "grok" ] || return 0

  stamp="$GROKGOD_HOME/.source-version"
  [ -f "$stamp" ] || return 0
  installed_mode=""
  installed_version=""
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      MODE) installed_mode="$value" ;;
      VERSION) installed_version="$value" ;;
    esac
  done < "$stamp"
  [ "$installed_mode" = "release" ] || return 0
  is_release_version "$installed_version" || return 0

  update_cache="$GROKGOD_HOME/.update-check"
  checked_at=""
  cached_version=""
  if [ -f "$update_cache" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
      case "$key" in
        CHECKED_AT) checked_at="$value" ;;
        VERSION) cached_version="$value" ;;
      esac
    done < "$update_cache"
  fi

  # Equal tags are the common warm-cache path; skip the core comparison.
  if [ "$cached_version" != "$installed_version" ] &&
    is_release_version "$cached_version" &&
    version_core_greater "$cached_version" "$installed_version"; then
    printf '%s\n' "[grokgod] $cached_version available (installed: $installed_version) — run 'grok update' to upgrade" >&2
  fi

  now="$(date +%s 2>/dev/null || true)"
  case "$now" in
    ''|*[!0-9]*) refresh_due=1 ;;
    *) case "$checked_at" in
      ''|*[!0-9]*) refresh_due=1 ;;
      *)
      if [ "$now" -ge "$checked_at" ] && [ "$((now - checked_at))" -lt 86400 ]; then
        refresh_due=0
      else
        refresh_due=1
      fi
      ;;
    esac
      ;;
  esac
  [ "$refresh_due" -eq 1 ] || return 0
  [ -n "$now" ] || return 0

  # Record this 24-hour refresh window before detaching. Preserve only a valid
  # cached tag so a failed request stays silent without retrying every launch.
  if ! is_release_version "$cached_version"; then
    cached_version=""
  fi
  write_update_cache "$now" "$cached_version" 2>/dev/null || return 0

  update_url="${GROKGOD_UPDATE_CHECK_URL:-https://api.github.com/repos/karlorz/grokgod/releases/latest}"
  (
    response="$(curl -fsSL --connect-timeout 2 --max-time 5 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: grokgod' "$update_url" 2>/dev/null)" || exit 0
    latest_version="$(printf '%s\n' "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    is_release_version "$latest_version" || exit 0
    write_update_cache "$now" "$latest_version" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
}

# ─────────────────────────────────────────────────────────
# STRUCTURED STATUS (`status --json`)
# ─────────────────────────────────────────────────────────
# Additive to the frozen human-readable status body. POSIX sh only: no
# arrays, no `local`, no `[[`, no process substitution. Every external
# command is guarded so `set -eu` never aborts mid-document.

MANIFEST_FILE="$GROKGOD_HOME/manifest.json"

NEWLINE_CHAR="
"

# Drop bytes that would be emitted raw inside a JSON string and break the
# document for any UTF-8 consumer: only well-formed UTF-8 survives. iconv -c
# keeps valid multi-byte text; if it is unavailable or reports an error, every
# non-ASCII byte is stripped instead. The fallback must NOT be reached through
# a `||` on the pipeline (iconv already wrote its partial output by then).
sanitize_utf8() {
  SANITIZE_IN="${1:-}"
  SANITIZE_OUT=""
  SANITIZE_OK=1
  if command -v iconv >/dev/null 2>&1; then
    SANITIZE_OUT="$(printf '%s' "$SANITIZE_IN" | LC_ALL=C iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
    SANITIZE_OK=$?
  fi
  if [ "$SANITIZE_OK" -eq 0 ]; then
    printf '%s' "$SANITIZE_OUT"
  else
    printf '%s' "$SANITIZE_IN" | LC_ALL=C tr -d '\200-\377' 2>/dev/null || printf '%s' "$SANITIZE_IN"
  fi
  return 0
}

json_escape_line() {
  sanitize_utf8 "${1:-}" | LC_ALL=C sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g' \
    -e 's/'"$(printf '\r')"'/\\r/g' \
    -e 's/'"$(printf '\t')"'/\\t/g' \
    -e 's/[[:cntrl:]]//g' 2>/dev/null || true
}

# Escape an arbitrary value (possibly multi-line) into a JSON string body.
# Embedded newlines become the two-character escape \n so nothing raw ever
# reaches stdout. Empty input yields empty output and returns 0.
json_escape() {
  JSON_ESC_SEP=""
  JSON_ESC_OUT=""
  while IFS= read -r JSON_ESC_LINE || [ -n "$JSON_ESC_LINE" ]; do
    JSON_ESC_OUT="$JSON_ESC_OUT$JSON_ESC_SEP$(json_escape_line "$JSON_ESC_LINE")"
    JSON_ESC_SEP='\n'
  done <<EOF_JSON_ESCAPE
${1:-}
EOF_JSON_ESCAPE
  printf '%s' "$JSON_ESC_OUT"
}

json_string() {
  printf '"%s"' "$(json_escape "${1:-}")"
}

json_string_or_null() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    json_string "$1"
  fi
}

# json_string_array <count> <newline-separated blob>
json_string_array() {
  JSON_ARR_COUNT="${1:-0}"
  case "$JSON_ARR_COUNT" in
    ''|*[!0-9]*) JSON_ARR_COUNT=0 ;;
  esac
  if [ "$JSON_ARR_COUNT" -le 0 ]; then
    printf '[]'
    return 0
  fi
  JSON_ARR_SEP=""
  printf '['
  while IFS= read -r JSON_ARR_LINE || [ -n "$JSON_ARR_LINE" ]; do
    printf '%s' "$JSON_ARR_SEP"
    json_string "$JSON_ARR_LINE"
    JSON_ARR_SEP=", "
  done <<EOF_JSON_ARRAY
${2:-}
EOF_JSON_ARRAY
  printf ']'
}

json_bool() {
  if [ "${1:-0}" = "1" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_number_or_null() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Accepts a non-negative decimal (integer or fixed-point), else null.
json_decimal_or_null() {
  case "${1:-}" in
    ''|*[!0-9.]*) printf 'null' ;;
    *.) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# sha256 of a regular file, or empty when it cannot be computed.
# hash_tool_available probes for the tool in the CURRENT shell (see usage in
# emit_status_json): a command substitution runs in a subshell, so a flag set
# inside file_sha256 would never reach the caller.
file_sha256() {
  JSON_SHA_PATH="${1:-}"
  [ -f "$JSON_SHA_PATH" ] || { printf ''; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$JSON_SHA_PATH" 2>/dev/null | awk '{print $1}' || true
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$JSON_SHA_PATH" 2>/dev/null | awk '{print $1}' || true
  else
    printf ''
  fi
}

hash_tool_available() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1
}

# Exactly 64 lowercase hex characters, one line. Implemented with grep under
# LC_ALL=C because a UTF-8 collation folds 'A'..'F' into the [0-9a-f] range on
# some hosts (bash-as-sh on macOS) and not others (dash on Linux).
is_sha256_hex() {
  printf '%s\n' "${1:-}" | LC_ALL=C grep -cx '[0-9a-f]\{64\}' >/dev/null 2>&1
}

is_readable_regular_file() {
  [ -f "${1:-}" ] && [ -r "${1:-}" ]
}

classify_signature() {
  _sig_path="${1:-}"
  if [ -z "$_sig_path" ] || [ ! -e "$_sig_path" ]; then
    printf 'absent'
    return 0
  fi
  if [ "$(uname -s 2>/dev/null || true)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then
    printf 'unsupported'
    return 0
  fi
  _sig_out="$(codesign -dv "$_sig_path" 2>&1 || true)"
  case "$_sig_out" in
    *"code object is not signed at all"*) printf 'unsigned' ;;
    *"Signature=adhoc"*) printf 'adhoc' ;;
    *"Authority="*) printf 'signed' ;;
    *) printf 'unknown' ;;
  esac
  return 0
}

free_disk_bytes() {
  JSON_DF_DIR="${1:-}"
  while [ -n "$JSON_DF_DIR" ] && [ ! -d "$JSON_DF_DIR" ] && [ "$JSON_DF_DIR" != "/" ] && [ "$JSON_DF_DIR" != "." ]; do
    JSON_DF_DIR="$(dirname "$JSON_DF_DIR")"
  done
  [ -n "$JSON_DF_DIR" ] && [ -d "$JSON_DF_DIR" ] || JSON_DF_DIR="/"
  JSON_DF_KB="$(df -P -k "$JSON_DF_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  case "$JSON_DF_KB" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$((JSON_DF_KB * 1024))" ;;
  esac
}

# Anchored extraction of one manifest string field. Values written by
# install.sh never contain a raw double quote, so `[^"]*` is exact.
manifest_field() {
  JSON_MF_KEY="${1:-}"
  [ -n "$JSON_MF_KEY" ] || return 0
  [ -f "$MANIFEST_FILE" ] || return 0
  sed -n "s/^[[:space:]]*\"${JSON_MF_KEY}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" \
    "$MANIFEST_FILE" 2>/dev/null | head -n 1 || true
}

manifest_number_field() {
  JSON_MFN_KEY="${1:-}"
  [ -n "$JSON_MFN_KEY" ] || return 0
  [ -f "$MANIFEST_FILE" ] || return 0
  sed -n "s/^[[:space:]]*\"${JSON_MFN_KEY}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" \
    "$MANIFEST_FILE" 2>/dev/null | head -n 1 || true
}

manifest_key_count() {
  JSON_MFC_KEY="${1:-}"
  [ -n "$JSON_MFC_KEY" ] || { printf '0'; return 0; }
  [ -f "$MANIFEST_FILE" ] || { printf '0'; return 0; }
  JSON_MFC_COUNT="$(grep -c "\"${JSON_MFC_KEY}\"" "$MANIFEST_FILE" 2>/dev/null || true)"
  case "$JSON_MFC_COUNT" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$JSON_MFC_COUNT" ;;
  esac
}

# A manifest is only trusted when it is unmistakably OUR layout: a
# brace-wrapped object whose fields are one-per-line and comma-separated
# (exactly what install.sh writes), carrying exactly one formatVersion 1 and
# exactly one platform "posix". A truncated file, arbitrary garbage, a
# missing/trailing comma, or the Windows installer's own manifest.json (no
# platform field) is reported invalid and status falls back to stamp-only
# behavior exactly as before this change.
manifest_state() {
  MF_EXISTS=0
  MF_VALID=0
  MF_DETAIL=""
  MF_PLATFORM=""
  MF_FORMAT_VERSION=""
  MF_INSTALLED_AT=""
  MF_ARTIFACT_SHA=""
  MF_ASSET_SHA=""
  MF_RECORDED_SIG=""
  MF_MODE=""
  MF_VERSION=""
  MF_PATCHSET=""
  MF_SOURCE_SHA=""

  if [ ! -f "$MANIFEST_FILE" ]; then
    MF_DETAIL="Artifact manifest missing at: $MANIFEST_FILE"
    return 0
  fi
  MF_EXISTS=1

  MF_FIRST="$(awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; exit }' "$MANIFEST_FILE" 2>/dev/null || true)"
  MF_LAST="$(awk 'NF { line=$0 } END { if (line != "") { sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line); print line } }' "$MANIFEST_FILE" 2>/dev/null || true)"
  if [ "$MF_FIRST" != "{" ] || [ "$MF_LAST" != "}" ]; then
    MF_DETAIL="Artifact manifest malformed at: $MANIFEST_FILE (not a JSON object)"
    return 0
  fi
  # Structural gate: every line between the opening brace and the closing
  # brace must end with a comma, except the last field before the brace. This
  # rejects missing separators, trailing commas, and multi-object files, which
  # a per-key sed extraction cannot see.
  MF_SEPARATOR_ERRORS="$(awk '
    { line=$0; sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line) }
    line == "" || line == "{" || line == "}" { next }
    { fields[++n] = line }
    END {
      bad = 0
      for (i = 1; i <= n; i++) {
        comma = (substr(fields[i], length(fields[i]), 1) == ",")
        if (i < n && !comma) bad++
        if (i == n && comma) bad++
      }
      print bad + 0
    }
  ' "$MANIFEST_FILE" 2>/dev/null || true)"
  if [ "$MF_SEPARATOR_ERRORS" != "0" ]; then
    MF_DETAIL="Artifact manifest malformed at: $MANIFEST_FILE (fields are not comma-separated one per line)"
    return 0
  fi

  MF_FORMAT_VERSION="$(manifest_number_field formatVersion)"
  MF_PLATFORM="$(manifest_field platform)"
  if [ "$(manifest_key_count formatVersion)" != "1" ] || [ "$MF_FORMAT_VERSION" != "1" ]; then
    MF_DETAIL="Artifact manifest malformed at: $MANIFEST_FILE (formatVersion is not exactly 1)"
    return 0
  fi
  if [ "$(manifest_key_count platform)" != "1" ] || [ "$MF_PLATFORM" != "posix" ]; then
    MF_DETAIL="Artifact manifest malformed at: $MANIFEST_FILE (platform is not exactly posix)"
    return 0
  fi
  if [ "$(manifest_key_count artifactSha256)" != "1" ]; then
    MF_DETAIL="Artifact manifest malformed at: $MANIFEST_FILE (artifactSha256 is missing or duplicated)"
    return 0
  fi

  MF_VALID=1
  MF_INSTALLED_AT="$(manifest_field installedAt)"
  MF_MODE="$(manifest_field mode)"
  MF_VERSION="$(manifest_field version)"
  MF_PATCHSET="$(manifest_field patchset)"
  MF_SOURCE_SHA="$(manifest_field sourceSha)"
  MF_ASSET_SHA="$(manifest_field assetSha256)"
  MF_RECORDED_SIG="$(manifest_field signature)"
  MF_ARTIFACT_SHA="$(manifest_field artifactSha256)"
  return 0
}

status_detail_add() {
  if [ "$STATUS_DETAIL_COUNT" -eq 0 ]; then
    STATUS_DETAILS="${1:-}"
  else
    STATUS_DETAILS="$STATUS_DETAILS
${1:-}"
  fi
  STATUS_DETAIL_COUNT=$((STATUS_DETAIL_COUNT + 1))
}

status_json_requested() {
  case "${1:-}" in
    --json|-json) return 0 ;;
    *) return 1 ;;
  esac
}

# Emits exactly one JSON document (one line plus trailing newline) on stdout
# and returns the health exit code: healthy 0, degraded 1, corrupt 2.
# Nothing is ever written to stderr, in any state, including malformed input.
emit_status_json() {
  STATUS_DETAILS=""
  STATUS_DETAIL_COUNT=0
  STATUS_HEALTH="healthy"

  manifest_state

  # --- stamp ---------------------------------------------------------------
  # All stamp reads run under LC_ALL=C: a byte that is not valid in the host
  # locale would otherwise make cut/tr write a diagnostic to stderr, which the
  # JSON contract forbids ("nothing on stderr in any state").
  STAMP_FILE="$GROKGOD_HOME/.source-version"
  STAMP_CRLF=0
  STAMP_SHA=""
  STAMP_PATCHSET=""
  STAMP_VERSION=""
  STAMP_MODE=""
  if [ -f "$STAMP_FILE" ]; then
    # LC_ALL=C on every read: a byte that is invalid in the host locale would
    # otherwise make cut/tr write a diagnostic to stderr, which the JSON
    # contract forbids ("nothing on stderr in any state").
    STAMP_SHA="$(LC_ALL=C sed -n 's/^SHA=//p' "$STAMP_FILE" 2>/dev/null || true)"
    STAMP_PATCHSET="$(LC_ALL=C sed -n 's/^PATCHSET=//p' "$STAMP_FILE" 2>/dev/null || true)"
    STAMP_VERSION="$(LC_ALL=C sed -n 's/^VERSION=//p' "$STAMP_FILE" 2>/dev/null || true)"
    STAMP_MODE="$(LC_ALL=C sed -n 's/^MODE=//p' "$STAMP_FILE" 2>/dev/null || true)"
    # Tolerate a CRLF stamp (a Windows checkout of a POSIX home) instead of
    # reporting "MODE is not source|release" over a trailing carriage return.
    case "${STAMP_SHA}${STAMP_PATCHSET}${STAMP_VERSION}${STAMP_MODE}" in
      *"$(printf '\r')"*)
        STAMP_CRLF=1
        STAMP_SHA="$(printf '%s\n' "$STAMP_SHA" | LC_ALL=C tr -d '\r')"
        STAMP_PATCHSET="$(printf '%s\n' "$STAMP_PATCHSET" | LC_ALL=C tr -d '\r')"
        STAMP_VERSION="$(printf '%s\n' "$STAMP_VERSION" | LC_ALL=C tr -d '\r')"
        STAMP_MODE="$(printf '%s\n' "$STAMP_MODE" | LC_ALL=C tr -d '\r')"
        ;;
    esac
  fi

  STAMP_SHA_DUPLICATED=0
  for STAMP_VALUE_NAME in SHA PATCHSET VERSION MODE; do
    case "$STAMP_VALUE_NAME" in
      SHA) STAMP_VALUE_SEEN="$STAMP_SHA" ;;
      PATCHSET) STAMP_VALUE_SEEN="$STAMP_PATCHSET" ;;
      VERSION) STAMP_VALUE_SEEN="$STAMP_VERSION" ;;
      *) STAMP_VALUE_SEEN="$STAMP_MODE" ;;
    esac
    case "$STAMP_VALUE_SEEN" in
      *"$NEWLINE_CHAR"*)
        status_detail_add "Stamp has duplicate ${STAMP_VALUE_NAME}= lines at: $STAMP_FILE"
        [ "$STAMP_VALUE_NAME" = "SHA" ] && STAMP_SHA_DUPLICATED=1
        ;;
    esac
  done

  # --- binary --------------------------------------------------------------
  JSON_BIN_EXISTS=0
  [ -e "$GROKGOD_BIN" ] && JSON_BIN_EXISTS=1
  JSON_BIN_HASHABLE=0
  is_readable_regular_file "$GROKGOD_BIN" && JSON_BIN_HASHABLE=1
  JSON_COMPUTED_SHA=""
  JSON_HASH_ALGORITHM=""
  JSON_HASH_TOOL_AVAILABLE=0
  hash_tool_available && JSON_HASH_TOOL_AVAILABLE=1
  if [ "$JSON_BIN_HASHABLE" -eq 1 ]; then
    JSON_COMPUTED_SHA="$(file_sha256 "$GROKGOD_BIN")"
    if [ -n "$JSON_COMPUTED_SHA" ]; then
      JSON_HASH_ALGORITHM="sha256"
    fi
  fi

  # Expected digest comes from the manifest only: release-mode stamps record
  # the pre-codesign download digest and source-mode stamps record a git
  # commit, so neither can be compared against the installed file. A valid
  # manifest whose recorded digest is unusable is NOT treated as "nothing to
  # verify" — that would let artifactSha256 tampering read as healthy.
  JSON_EXPECTED_SHA=""
  JSON_EXPECTED_SHA_UNUSABLE=0
  if [ "$MF_VALID" -eq 1 ]; then
    if is_sha256_hex "$MF_ARTIFACT_SHA"; then
      JSON_EXPECTED_SHA="$MF_ARTIFACT_SHA"
    else
      JSON_EXPECTED_SHA_UNUSABLE=1
    fi
  fi

  # --- health (first match wins) -------------------------------------------
  if [ "$JSON_BIN_EXISTS" -eq 0 ]; then
    STATUS_HEALTH="corrupt"
    status_detail_add "Patched binary missing at: $GROKGOD_BIN"
  elif [ "$JSON_EXPECTED_SHA_UNUSABLE" -eq 1 ]; then
    STATUS_HEALTH="corrupt"
    status_detail_add "Artifact manifest records an unusable artifactSha256 (not a 64-character hex digest) at: $MANIFEST_FILE"
  elif [ -n "$JSON_EXPECTED_SHA" ] && [ -n "$JSON_COMPUTED_SHA" ] && [ "$JSON_COMPUTED_SHA" != "$JSON_EXPECTED_SHA" ]; then
    STATUS_HEALTH="corrupt"
    status_detail_add "Patched binary SHA256 ($JSON_COMPUTED_SHA) does not match recorded artifact SHA ($JSON_EXPECTED_SHA)"
  elif [ "$JSON_BIN_HASHABLE" -eq 0 ]; then
    # Present but not a readable regular file (directory, symlink loop, mode).
    # The recorded artifact cannot be verified against it: fail closed.
    STATUS_HEALTH="corrupt"
    status_detail_add "Patched binary is not a readable regular file at: $GROKGOD_BIN"
  elif [ "$JSON_HASH_TOOL_AVAILABLE" -eq 0 ]; then
    STATUS_HEALTH="degraded"
    status_detail_add "sha256 tool unavailable; binary integrity was not verified (install sha256sum or shasum)"
  elif [ ! -f "$STAMP_FILE" ]; then
    STATUS_HEALTH="degraded"
    status_detail_add "Stamp file missing at: $STAMP_FILE"
  elif [ -z "$STAMP_SHA" ]; then
    STATUS_HEALTH="degraded"
    status_detail_add "Stamp file is malformed or missing recorded SHA at: $STAMP_FILE"
  elif [ "$STAMP_SHA_DUPLICATED" -eq 1 ]; then
    # A duplicated SHA= makes every grep-based reader see a multi-line value;
    # fail closed instead of reporting a garbage digest as healthy. (The
    # generic duplicate detail above already names the offending line.)
    STATUS_HEALTH="degraded"
  elif [ "$STAMP_MODE" != "source" ] && [ "$STAMP_MODE" != "release" ]; then
    STATUS_HEALTH="degraded"
    status_detail_add "Stamp MODE is missing or not source|release at: $STAMP_FILE (read: '$STAMP_MODE')"
  elif [ "$STAMP_MODE" = "release" ] && ! is_sha256_hex "$STAMP_SHA"; then
    STATUS_HEALTH="degraded"
    status_detail_add "Stamp SHA is not a 64-character lowercase hex digest: $STAMP_SHA"
  fi

  # --- non-decisional observations -----------------------------------------
  if [ "$MF_EXISTS" -eq 0 ]; then
    status_detail_add "$MF_DETAIL"
  elif [ "$MF_VALID" -eq 0 ]; then
    status_detail_add "$MF_DETAIL"
  fi
  if [ "$MF_VALID" -eq 1 ]; then
    # Skip the comparison when SHA is duplicated: the raw value spans lines and
    # would split one detail into two healthDetails entries. The duplicate is
    # already reported on its own.
    if [ "$STAMP_SHA_DUPLICATED" -eq 0 ] \
        && [ -n "$STAMP_SHA" ] && [ -n "$MF_SOURCE_SHA" ] && [ "$STAMP_SHA" != "$MF_SOURCE_SHA" ]; then
      status_detail_add "Stamp SHA ($STAMP_SHA) does not match manifest sourceSha ($MF_SOURCE_SHA)"
    fi
  elif [ -z "$JSON_EXPECTED_SHA" ] && [ -n "$STAMP_SHA" ]; then
    status_detail_add "Integrity not verified (no valid manifest); run grok update to record one"
  fi

  # --- signature -----------------------------------------------------------
  JSON_LIVE_SIG="$(classify_signature "$GROKGOD_BIN")"
  JSON_SIG_VERIFIED="null"
  if [ -n "$MF_RECORDED_SIG" ]; then
    if [ "$MF_RECORDED_SIG" = "$JSON_LIVE_SIG" ]; then
      JSON_SIG_VERIFIED="true"
    else
      JSON_SIG_VERIFIED="false"
      status_detail_add "Signature recorded as '$MF_RECORDED_SIG' but observed '$JSON_LIVE_SIG'"
    fi
  fi

  # --- launcher ownership --------------------------------------------------
  JSON_LAUNCHER_PATH="${HOME:-}/.local/bin/grok"
  if [ ! -f "$JSON_LAUNCHER_PATH" ]; then
    JSON_LAUNCHER_OWNERSHIP="absent"
  elif grep -q "GROKGOD" "$JSON_LAUNCHER_PATH" 2>/dev/null; then
    JSON_LAUNCHER_OWNERSHIP="shim"
  else
    JSON_LAUNCHER_OWNERSHIP="foreign"
  fi

  JSON_LAUNCHER_IDENTITY="$(basename "$0" 2>/dev/null || true)"

  # --- patch inventory -----------------------------------------------------
  JSON_PATCH_STATUS="missing"
  if [ "$JSON_BIN_EXISTS" -eq 1 ] && [ -n "$STAMP_PATCHSET" ]; then
    JSON_PATCH_STATUS="applied"
  fi
  JSON_OVERLAY_STATUS="missing"
  [ -f "$GROKGOD_SRC/src/grokgod-run.sh" ] && JSON_OVERLAY_STATUS="wrapper"
  JSON_EVAL_HOME_STATUS="missing"
  [ -f "$GROKGOD_SRC/src/grokgod-eval.sh" ] && JSON_EVAL_HOME_STATUS="wrapper"
  JSON_ORCA_PIN_STATUS="absent"
  [ -f "$GROKGOD_HOME/pin/orca-pin.toml" ] && JSON_ORCA_PIN_STATUS="present, not applied"

  # The numbered lines come from the machine-readable registry, exactly as the
  # human report renders them; the fixed non-patch lines follow.
  JSON_PERSIST=""
  JSON_PERSIST_COUNT=0
  if JSON_REGISTRY_PATH="$(resolve_registry_path)"; then
    JSON_PERSIST="$(registry_persist_names "$JSON_REGISTRY_PATH" | while IFS= read -r _rn; do
      [ -n "$_rn" ] || continue
      printf '%s: %s\n' "$_rn" "$JSON_PATCH_STATUS"
    done)"
    JSON_PERSIST_COUNT="$(printf '%s\n' "$JSON_PERSIST" | LC_ALL=C grep -c '[^[:space:]]' 2>/dev/null || true)"
    case "$JSON_PERSIST_COUNT" in
      ''|*[!0-9]*) JSON_PERSIST_COUNT=0 ;;
    esac
  fi
  # Fixed count: json_string_array joins every line of the blob, and a build
  # without grep/patch tools must not silently emit an empty inventory.
  JSON_PERSIST_TAIL="overlay-pin: $JSON_OVERLAY_STATUS
eval-home: $JSON_EVAL_HOME_STATUS
weekly-pin: global-default
orca-pin: $JSON_ORCA_PIN_STATUS"
  if [ "$JSON_PERSIST_COUNT" -gt 0 ]; then
    JSON_PERSIST="$JSON_PERSIST
$JSON_PERSIST_TAIL"
  else
    JSON_PERSIST="$JSON_PERSIST_TAIL"
  fi
  JSON_PERSIST_COUNT=$((JSON_PERSIST_COUNT + 4))

  # --- drift + disk --------------------------------------------------------
  # DRIFT_STATUS is pre-set: compute_source_drift is skipped entirely when git
  # is unavailable, and `set -u` would otherwise abort mid-document.
  DRIFT_STATUS="unknown"
  JSON_DRIFT_INSTALLED=""
  JSON_DRIFT_UPSTREAM=""
  if command -v git >/dev/null 2>&1; then
    compute_source_drift
    JSON_DRIFT_INSTALLED="$INSTALLED_SHORT"
    JSON_DRIFT_UPSTREAM="$UPSTREAM_SHORT"
  fi

  JSON_FREE_BYTES="$(free_disk_bytes "$GROKGOD_HOME")"
  JSON_FREE_GB=""
  if [ -n "$JSON_FREE_BYTES" ]; then
    JSON_FREE_GB="$(awk -v b="$JSON_FREE_BYTES" 'BEGIN { printf "%.2f", b / 1073741824 }' 2>/dev/null || true)"
  fi

  JSON_MATCHES_RECORD="null"
  if [ -n "$JSON_EXPECTED_SHA" ] && [ -n "$JSON_COMPUTED_SHA" ]; then
    if [ "$JSON_COMPUTED_SHA" = "$JSON_EXPECTED_SHA" ]; then
      JSON_MATCHES_RECORD="true"
    else
      JSON_MATCHES_RECORD="false"
    fi
  fi

  JSON_HASH_ALGORITHM_OR_NULL="$(json_string_or_null "$JSON_HASH_ALGORITHM")"

  # Stamp first, manifest as the fallback: `sourceSha` mirrors the Windows
  # vocabulary, where the stamp VERSION maps to sourceSha, so `version` and
  # `sourceSha` carry the same value by design.
  JSON_MODE_OUT="$STAMP_MODE"
  [ -n "$JSON_MODE_OUT" ] || JSON_MODE_OUT="$MF_MODE"
  JSON_VERSION_OUT="$STAMP_VERSION"
  [ -n "$JSON_VERSION_OUT" ] || JSON_VERSION_OUT="$MF_VERSION"
  JSON_PATCHSET_OUT="$STAMP_PATCHSET"
  [ -n "$JSON_PATCHSET_OUT" ] || JSON_PATCHSET_OUT="$MF_PATCHSET"

  # --- render --------------------------------------------------------------
  printf '{'
  printf '"schemaVersion":1'
  printf ',"health":%s' "$(json_string "$STATUS_HEALTH")"
  printf ',"healthDetails":%s' "$(json_string_array "$STATUS_DETAIL_COUNT" "$STATUS_DETAILS")"
  printf ',"mode":%s' "$(json_string_or_null "$JSON_MODE_OUT")"
  printf ',"version":%s' "$(json_string_or_null "$JSON_VERSION_OUT")"
  printf ',"sourceSha":%s' "$(json_string_or_null "$MF_SOURCE_SHA")"
  printf ',"patchset":%s' "$(json_string_or_null "$JSON_PATCHSET_OUT")"
  printf ',"patchStatus":%s' "$(json_string "$JSON_PATCH_STATUS")"
  printf ',"persist":%s' "$(json_string_array "$JSON_PERSIST_COUNT" "$JSON_PERSIST")"
  printf ',"launcherIdentity":%s' "$(json_string_or_null "$JSON_LAUNCHER_IDENTITY")"
  printf ',"resolvedCommandPath":%s' "$(json_string "$0")"
  printf ',"launcherPath":%s' "$(json_string "$JSON_LAUNCHER_PATH")"
  printf ',"launcherOwnership":%s' "$(json_string "$JSON_LAUNCHER_OWNERSHIP")"
  printf ',"patchedBinaryPath":%s' "$(json_string "$GROKGOD_BIN")"
  printf ',"patchedBinaryExists":%s' "$(json_bool "$JSON_BIN_EXISTS")"
  printf ',"patchedBinaryVersion":null'
  printf ',"officialBinaryPath":null'
  printf ',"officialBinaryExists":false'
  printf ',"officialBinaryVersion":null'
  printf ',"artifactSha256":%s' "$(json_string_or_null "$JSON_EXPECTED_SHA")"
  printf ',"computedSha256":%s' "$(json_string_or_null "$JSON_COMPUTED_SHA")"
  printf ',"hashAlgorithm":%s' "$JSON_HASH_ALGORITHM_OR_NULL"
  printf ',"artifactHashMatchesRecord":%s' "$JSON_MATCHES_RECORD"
  printf ',"signature":%s' "$(json_string "$JSON_LIVE_SIG")"
  printf ',"recordedSignature":%s' "$(json_string_or_null "$MF_RECORDED_SIG")"
  printf ',"signatureVerified":%s' "$JSON_SIG_VERIFIED"
  printf ',"manifestPath":%s' "$(json_string "$MANIFEST_FILE")"
  printf ',"manifestExists":%s' "$(json_bool "$MF_EXISTS")"
  printf ',"manifestValid":%s' "$(json_bool "$MF_VALID")"
  printf ',"manifestDetail":%s' "$(json_string_or_null "$MF_DETAIL")"
  printf ',"installedAt":%s' "$(json_string_or_null "$MF_INSTALLED_AT")"
  printf ',"freeDiskBytes":%s' "$(json_number_or_null "$JSON_FREE_BYTES")"
  printf ',"freeDiskGigabytes":%s' "$(json_decimal_or_null "$JSON_FREE_GB")"
  printf ',"sourceDrift":%s' "$(json_string "$DRIFT_STATUS")"
  printf ',"sourceDriftInstalled":%s' "$(json_string_or_null "$JSON_DRIFT_INSTALLED")"
  printf ',"sourceDriftUpstream":%s' "$(json_string_or_null "$JSON_DRIFT_UPSTREAM")"
  printf '}\n'

  case "$STATUS_HEALTH" in
    corrupt) return 2 ;;
    degraded) return 1 ;;
    *) return 0 ;;
  esac
}

cmd="${1:-}"

case "$cmd" in
  update)
    shift || true
    # Scan arguments for explicit mode overrides
    HAS_RELEASE=0
    HAS_SOURCE=0
    for update_arg in "$@"; do
      case "$update_arg" in
        --release)
          HAS_RELEASE=1
          ;;
        --from-source)
          HAS_SOURCE=1
          ;;
      esac
    done

    if [ "$HAS_RELEASE" = "1" ] && [ "$HAS_SOURCE" = "1" ]; then
      echo "grokgod: --release and --from-source cannot be combined" >&2
      exit 1
    fi

    # Detect mode from arguments or stamp, defaulting to release
    MODE_ARG=""
    if [ "$HAS_RELEASE" = "0" ] && [ "$HAS_SOURCE" = "0" ] && [ -f "$GROKGOD_HOME/.source-version" ]; then
      INST_MODE="$(grep '^MODE=' "$GROKGOD_HOME/.source-version" 2>/dev/null | cut -d= -f2- || true)"
      if [ "$INST_MODE" = "source" ]; then
        MODE_ARG="--from-source"
      fi
    fi
    if [ -d "$GROKGOD_SRC/.git" ]; then
      if ! git -C "$GROKGOD_SRC" fetch origin >/dev/null 2>&1; then
        echo "grokgod: failed to fetch origin at $GROKGOD_SRC" >&2
        echo "grokgod: live binary untouched; rebase/ff onto origin, then retry grok update" >&2
        exit 1
      fi
      if ! fast_forward_or_reset_repo "$GROKGOD_SRC"; then
        echo "grokgod: live binary untouched; rebase/ff onto origin, then retry grok update" >&2
        exit 1
      fi
    fi
    if [ -n "$MODE_ARG" ]; then
      exec sh "$GROKGOD_SRC/install.sh" "$MODE_ARG" "$@"
    else
      exec sh "$GROKGOD_SRC/install.sh" "$@"
    fi
    ;;
  status)
    # Opt-in structured output. Arguments are only inspected, never consumed,
    # so every existing invocation (including `status <anything else>`) keeps
    # the byte-identical human report below.
    STATUS_JSON=0
    for status_arg in "$@"; do
      if status_json_requested "$status_arg"; then
        STATUS_JSON=1
      fi
    done
    if [ "$STATUS_JSON" -eq 1 ]; then
      STATUS_JSON_CODE=0
      emit_status_json || STATUS_JSON_CODE=$?
      exit "$STATUS_JSON_CODE"
    fi

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

    if [ -f "$GROKGOD_SRC/src/grokgod-eval.sh" ]; then
      eval_home_status="wrapper"
    else
      eval_home_status="missing"
    fi

    echo "persist:"
    if registry_path="$(resolve_registry_path)"; then
      print_registry_persist "$registry_path" "$patch_status"
    fi
    echo "  overlay-pin: $overlay_status"
    echo "  eval-home: $eval_home_status"
    echo "  weekly-pin: global-default"
    if [ -f "$GROKGOD_HOME/pin/orca-pin.toml" ]; then
      echo "  orca-pin: present, not applied"
    else
      echo "  orca-pin: absent"
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
    maybe_notice_and_refresh_update
    exec "$GROKGOD_BIN" "$@"
    ;;
  run)
    shift || true
    exec sh "$GROKGOD_SRC/src/grokgod-run.sh" "$@"
    ;;
  eval)
    shift || true
    eval_script="$GROKGOD_SRC/src/grokgod-eval.sh"
    if [ -f "$eval_script" ]; then
      exec sh "$eval_script" "$@"
    else
      echo "grokgod eval not installed" >&2
      exit 1
    fi
    ;;
  eval-health)
    shift || true
    health_script="$GROKGOD_SRC/src/grokgod-eval-health.sh"
    if [ -f "$health_script" ]; then
      exec sh "$health_script" "$@"
    else
      echo "grokgod eval-health not installed" >&2
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

    maybe_notice_and_refresh_update

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

    # Orca automations select the model with -m. Do not overlay orca-pin.toml.
    exec "$GROKGOD_BIN" "$@"
    ;;
esac
