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
  [ "$(basename "$0")" = "grok" ] || return 0

  stamp="$GROKGOD_HOME/.source-version"
  [ -f "$stamp" ] || return 0
  installed_mode="$(grep '^MODE=' "$stamp" 2>/dev/null | cut -d= -f2- || true)"
  installed_version="$(grep '^VERSION=' "$stamp" 2>/dev/null | cut -d= -f2- || true)"
  [ "$installed_mode" = "release" ] || return 0
  is_release_version "$installed_version" || return 0

  update_cache="$GROKGOD_HOME/.update-check"
  checked_at=""
  cached_version=""
  if [ -f "$update_cache" ]; then
    checked_at="$(grep '^CHECKED_AT=' "$update_cache" 2>/dev/null | cut -d= -f2- || true)"
    cached_version="$(grep '^VERSION=' "$update_cache" 2>/dev/null | cut -d= -f2- || true)"
  fi

  if is_release_version "$cached_version" && version_core_greater "$cached_version" "$installed_version"; then
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
