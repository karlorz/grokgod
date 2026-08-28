# grok-build Source Patches

This directory contains upstream source patches applied to `grok-build` for `grokgod`.

## Patches

- `0001-normalize-plugin-skill-join.patch`: Normalizes manifest path joins by filtering out `Component::CurDir` (`.`) components so relative paths like `"./skills/"` resolve identically to `"skills"`.
- `0002-plan-mode-extra-writable.patch`: Plan-mode extra writable globs (`[plan_mode] extra_writable_globs`) and implement-via-subagents (default **true**): extra-glob Active writes, exit reminders, and `exit_plan_mode` PlanReady/EmptyPlan strings. Does not change the canonical session `plan.md`.
- `0003-session-persist-single.patch`: Session persistence control via `[session] persist_single` (default `false`). Headless / single-turn (`grok -p`) sessions skip disk persistence unless opted in; interactive sessions always persist. Adds `session.persist_single` to overlay allowlist.
- `0004-disable-builtin-deep-research.patch`: `[workflows.builtins] deep-research` kill-switch (compiled default **true**) plus `/plugin` → Workflows Space toggle (live slash, no `/settings` row). Explicit `false` hides the compiled-in `/deep-research` workflow so a plugin skill of the same name can own the slash command. The `/plugin` row stays listed when off. Overlay allowlist `workflows.builtins.deep-research`. grokgod install merges `false` when the key is missing.
- `0005-model-tools-deny-allow.patch`: Per-model tools gating via `[model."<id>".tools]` with `deny` and `allow` plain-name lists with removal-before-request semantics on both the client function-tool surface and the hosted splice (`x_search`, hosted `web_search`). Lets BYOK gateway model entries drop `web_search`/`web_fetch` while official `api.x.ai` models retain them.
- `0006-web-search-call-tolerant-parse.patch`: Tolerant parsing of hosted search-call stream items (`web_search_call`, `x_search_call`) missing the `action` field on in-progress frames from upstream gateways, injecting a minimal default `Search` action on deserialize error and dropping unknown output-item variants with a warning instead of aborting the turn.
- `0007-hosted-web-search-splice-decouple.patch`: Decouples the server-side hosted `web_search` tool splice from the client-side `WebSearchConfig` credential check. Preserves hosted search for BYOK models when logged out while maintaining explicit `disable_web_search` kill-switch and 0005 model deny semantics.

## Target Commit

- Base commit: `grok-build` commit `9684fa3c` (`9684fa3cdbf2995e30ea8b9b637f1db008f144fc`) — origin/main at 0003 rebase + 0004. 0001/0002 still apply.

## Verification

To verify that a patch applies cleanly against the base commit:

```bash
git -C <grok-build-checkout> apply --check patches/0001-normalize-plugin-skill-join.patch
```

## Regeneration

To regenerate or update a patch:

1. Create a worktree of `grok-build` at base commit `c2ad97f8`:
   ```bash
   git -C /path/to/grok-build worktree add /tmp/grokbuild-patch-wt c2ad97f8
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
