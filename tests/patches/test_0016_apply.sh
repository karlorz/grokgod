#!/bin/sh
set -eu

# Verify paid credit/weekly-limit and free-plan usage-limit model-switch retry
# contracts, plus stacked apply.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0016="$REPO_ROOT/patches/0016-credit-limit-switch-model.patch"
PIN_SHA="07e35a3dfeed2f200d319ef6c893b5ea286d9a51"
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0016 usage-limit switch-model patch tests ==="
[ -s "$PATCH_0016" ] || { echo "FAIL: 0016 patch missing or empty" >&2; exit 1; }

for needle in \
  'Switch model & retry' \
  'USAGE_LIMIT_SWITCH_MODEL_OPTION_ID' \
  'switch-model-and-retry' \
  'OpenCreditLimitModelPicker' \
  'open_model_arg_picker' \
  'switch_model_and_retry_option' \
  'credit_limit_model_retry_pending' \
  'dispatch_retry_credit_limit_prompt' \
  'free_usage_blocked' \
  'UpsellReason::FreeUsageLimit' \
  'free_usage_upsell_shows_upgrade_urls_then_switch_model_retry' \
  'free_usage_failure_captures_exact_prompt_before_finish_turn' \
  'free-usage prompt must survive finish_turn' \
  'free_usage_translate_local_submit_maps_upgrades_and_switch' \
  'restricted_command_translate_ignores_free_usage_switch_sentinel' \
  'free_usage_switch_model_success_retries_stashed_prompt_once' \
  'restricted-command upsell must not expose the free-usage retry action' \
  'credit_limit_model_switch_success_reuses_retry_once' \
  'credit_limit_model_switch_failure_preserves_stash_and_sends_nothing' \
  'ordinary_model_switch_never_retries_credit_limit_stash' \
  'keyboard_esc_dismisses_credit_limit_model_picker_and_preserves_prompt' \
  'mouse_window_close_dismisses_credit_limit_model_picker_and_preserves_prompt'; do
  grep -q "$needle" "$PATCH_0016" || {
    echo "FAIL: missing 0016 contract: $needle" >&2
    exit 1
  }
done

if grep '^+' "$PATCH_0016" | grep -Eiq \
  'Action::(NewSession|ExitSession|DeleteCurrentSession)|dispatch_new_session|(/new|create|close|kill|terminate)[^[:alnum:]]+session'; then
  echo "FAIL: 0016 must not automate session creation, closure, or termination" >&2
  exit 1
fi

if grep '^+' "$PATCH_0016" | grep -Eq \
  'CreditLimitUpsellClicked.*Switch|CreditLimitChoice::.*Switch'; then
  echo "FAIL: 0016 must not record the picker choice as a false CreditLimitChoice" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0016-wt-XXXXXX)"
  cleanup() {
    git -C "$REAL_GROK_BUILD" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHA" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHA" >&2
    exit 1
  }

  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 15 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0016" || {
    echo "FAIL: 0016 does not apply after 0001-0015 at $PIN_SHA" >&2
    exit 1
  }
  echo "PASS: 0016 applies after 0001-0015 at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0016 tests passed ==="
