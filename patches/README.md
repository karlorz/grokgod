# grok-build Source Patches

This directory contains upstream source patches applied to `grok-build` for `grokgod`.

DeepSeek **benchmark isolation** is not a numbered patch: use wrapper
`grokgod eval` (`src/grokgod-eval.sh`, persist `eval-home`). Wire-format
DeepSeek fixes remain `0009` and `0010`.

## Patches

- `0001-normalize-plugin-skill-join.patch`: Normalizes manifest path joins by filtering out `Component::CurDir` (`.`) components so relative paths like `"./skills/"` resolve identically to `"skills"`.
- `0002-plan-mode-extra-writable.patch`: Plan-mode extra writable globs (`[plan_mode] extra_writable_globs`) and implement-via-subagents (default **true**): extra-glob Active writes, exit reminders, and `exit_plan_mode` PlanReady/EmptyPlan strings. Does not change the canonical session `plan.md`.
- `0003-session-persist-single.patch`: Session persistence control via `[session] persist_single` (default `false`). Headless / single-turn (`grok -p`) sessions skip disk persistence unless opted in; interactive sessions always persist. Adds `session.persist_single` to overlay allowlist.
- `0004-disable-builtin-deep-research.patch`: `[workflows.builtins] deep-research` kill-switch (compiled default **true**) plus `/plugin` → Workflows Space toggle (live slash, no `/settings` row). Explicit `false` hides the compiled-in `/deep-research` workflow so a plugin skill of the same name can own the slash command. The `/plugin` row stays listed when off. Overlay allowlist `workflows.builtins.deep-research`. grokgod install merges `false` when the key is missing.
- `0005-model-tools-deny-allow.patch`: Per-model tools gating via `[model."<id>".tools]` with `deny` and `allow` plain-name lists with removal-before-request semantics on both the client function-tool surface and the hosted splice (`x_search`, hosted `web_search`). Lets BYOK gateway model entries drop `web_search`/`web_fetch` while official `api.x.ai` models retain them.
- `0006-web-search-call-tolerant-parse.patch`: Tolerant parsing of hosted search-call stream items (`web_search_call`, `x_search_call`) missing the `action` field on in-progress frames from upstream gateways, injecting a minimal default `Search` action on deserialize error and dropping unknown output-item variants with a warning instead of aborting the turn.
- `0007-hosted-web-search-splice-decouple.patch`: Decouples the server-side hosted `web_search` tool splice from the client-side `WebSearchConfig` credential check. Preserves hosted search for BYOK models when logged out while maintaining explicit `disable_web_search` kill-switch and 0005 model deny semantics.
- `0008-claude-permissions-import-gate.patch`: `[compat.claude] permissions` gate (default true, env `GROK_CLAUDE_PERMISSIONS_ENABLED`) to skip Claude settings permissions resolution so host Claude deny rules do not block grok native tools.
- `0009-deepseek-chat-fix.patch`: Chat Completions usage `u32` fields accept JSON `null` as 0 via `deserialize_null_default`, so DeepSeek/Poe/CPA trailers with `reasoning_tokens: null` (and sibling usage ints) do not abort the turn.
- `0010-deepseek-chat-compact-lenient.patch`: Chat Completions SSE compact-JSON lenient parse (sibling of 0006 in `client.rs`). Allowlisted retry for missing/`null` `choices[].index` (and empty `delta` / usage ints) so CPA/Poe wrappers cannot force a new patch per omitted key. Does not invent `id`/`model`/`created`. Stacked after 0001–0009.
- `0011-ask-question-timeout-action.patch`: `[toolset.ask_user_question] timeout_action = "decline" | "recommended"` (default `decline`) plus env `GROK_ASK_USER_QUESTION_TIMEOUT_ACTION`. Timeout + `recommended` auto-selects `(Recommended)` labels (first match on single-select, all marked on multi-select) with honest auto-select tool text. Also includes idle-reset: `[toolset.ask_user_question] timeout_reset_on_activity = true` (default `true`, env `GROK_ASK_USER_QUESTION_TIMEOUT_IDLE_RESET`), restarting timeout on user key/click/focus-regain activity via ACP `x.ai/ask_user_question_activity`. No `/settings` row. Stacked after 0001–0010 because docs/persist/config_tests already carry earlier patches.
- `0012-protoc-dependency-output-portable.patch`: Makes `xai-proto-build` protoc dependency discovery portable by replacing Unix-only `/dev/stdout` and `/dev/null` output paths with temporary files. Parses the Make dependency target separator without breaking Windows drive letters, allowing native Windows release builds.
- `0013-same-session-compaction-warning.patch`: Counts successful same-session compactions separately from legacy attempt telemetry, persists the count, and shows an existing prompt-adjacent warning at the configurable limit (default 3; `0` disables). At the next round it recommends saving SkillWiki progress and handing off to a new session. Builtin status-line item `compacts` always paints `C0`, `C1`, … from that count (amber at the limit); grokgod install merges it into `~/.grok/config.toml`. Overlay allowlist `[session] compaction_round_warning_limit`. It does not add a default context footer or create/close sessions.
- `0014-deepseek-tool-image-hoist.patch`: Hoists tool-result images into an immediately following user message (`Attached image(s) from tool result:`) when `input_modalities` includes `"image"`, allowing DeepSeek and OpenAI Chat Completions endpoints to consume tool-returned images without protocol errors.

## Target Commit

- Base commit: `grok-build` commit `07e35a3d` (`07e35a3dfeed2f200d319ef6c893b5ea286d9a51`) — origin/main 1.0.41; patches 0001–0014 are authored/rebased against this base. Source mode still tracks the moving `origin/main`; this is the patch-authorship/release pin.

## Verification

To verify that a patch applies cleanly against the base commit:

```bash
git -C <grok-build-checkout> apply --check patches/0001-normalize-plugin-skill-join.patch
```

## Regeneration

To regenerate or update a patch:

1. Create a worktree of `grok-build` at base commit `07e35a3d`:
   ```bash
   git -C /path/to/grok-build worktree add /tmp/grokbuild-patch-wt 07e35a3d
   ```
2. Apply changes and create the patch:
   ```bash
   git -C /tmp/grokbuild-patch-wt diff > patches/0001-normalize-plugin-skill-join.patch
   ```
3. Test applying in a clean verification worktree:
   ```bash
   git -C /tmp/grokbuild-verify-wt apply --check patches/0001-normalize-plugin-skill-join.patch
   ```

## Fail-Closed Policy

All patch applications must fail closed: if `git apply --check` or `git apply` exits with a non-zero status, build pipelines must halt immediately without building or distributing modified binaries.
