# grokgod persist inventory (2026-08-19)

ClawGod-style tracking of what grokgod **must** re-apply after `grok update`,
versus wrapper behavior, versus work we will not keep. This file is the
inventory. Persist status is exposed via the `grok status` persist block
(`0001-normalize-plugin-skill-join: applied|missing`, `0002-plan-mode-extra-writable: applied|missing`, `0003-session-persist-single: applied|missing`, `0004-disable-builtin-deep-research: applied|missing`, `0005-model-tools-deny-allow: applied|missing`, `0006-web-search-call-tolerant-parse: applied|missing`, `0007-hosted-web-search-splice-decouple: applied|missing`, `overlay-pin: wrapper|missing`).

## Keep — grok-build source patch (re-apply on update)

| ID | File | What | Why persist |
|----|------|------|-------------|
| `0001` | `patches/0001-normalize-plugin-skill-join.patch` | Filter `Component::CurDir` in `manifest.rs` skill joins so `"./skills/"` registers | Official `grok update` replaces the Mach-O; without this, installed plugin skill paths 404 |
| `0002` | `patches/0002-plan-mode-extra-writable.patch` | Plan-mode extra writable globs + implement-via-subagents (exit reminders + PlanReady/EmptyPlan after `a`) | Session plan.md is the only native writable path; PRD markdown (work items, `docs/superpowers/`) is rejected while Active; stock PlanReady said “start coding” |
| `0003` | `patches/0003-session-persist-single.patch` | Single-turn session persistence toggle via `[session] persist_single` (default `false`) + overlay allowlist | Stock grok writes disk sessions on every headless run, causing unbounded session growth on automated jobs; `persist_single = false` skips headless persistence while interactive sessions always persist |
| `0004` | `patches/0004-disable-builtin-deep-research.patch` | `[workflows.builtins] deep-research` (compiled default on) + `/plugin` Workflows Space (live slash); overlay allowlist; no `/settings` row | Compiled-in `/deep-research` occupies the slash name so plugin `deep-research:deep-research` cannot advertise bare `/deep-research`. Stock `[workflows] enabled = false` kills every workflow. |
| `0005` | `patches/0005-model-tools-deny-allow.patch` | Per-model `[model."<id>".tools]` `deny`/`allow` lists with removal-before-request semantics on client function tools and hosted splice | BYOK gateways 400 when `web_search` is present in `tools[]` and waste turns under `web_fetch`; global switches disable tools for official `api.x.ai` models too. Per-model removal lets gateway models drop unhandled tools while official models keep them. |
| `0006` | `patches/0006-web-search-call-tolerant-parse.patch` | Tolerant parse for hosted search calls missing `action` or unknown item variants in SSE stream | Upstream gateways emit `web_search_call` / `x_search_call` without `action` on in-progress frames, crashing strict deserialization with missing field `action`. Injection preserves turn continuity. |
| `0007` | `patches/0007-hosted-web-search-splice-decouple.patch` | Decouple hosted web_search splice from client-side xAI credential gate | Upstream gates the server-side splice on client `WebSearchConfig::is_enabled()`, which resolves through xAI credentials. Logging out silently strips hosted search from BYOK entries whose backend serves it. |

Base SHA: see `patches/README.md` (`9684fa3c`). Fail closed on `git apply --check`. Daily CI `.github/workflows/compat-daily.yml` runs `git apply --check` of `patches/*.patch` against latest `xai-org/grok-build` `origin/main`.

## Keep — wrapper, not a source patch

| ID | Mechanism | What | Why persist |
|----|-----------|------|-------------|
| `ORCA-PIN` | Official `GROK_CONFIG_PATH` env + `src/grokgod-run.sh` runner | Export `GROK_CONFIG_PATH` and exec/run `grok -p` (never `-m`) | Mechanism is official GROK_CONFIG_PATH; grokgod run sets it. Host overlay is operator/template (`examples/grok-overlay.toml`), not Weekly tree on every host. Orca 1.4.184 has no per-automation env. Interactive grok must stay on `~/.grok/config.toml`. |

Production overlay lives under the automation root (Weekly:
`~/.orca/automations/weekly-dev-cache-scan/grok-overlay.toml`) or host pin (`~/.grokgod/pin/grok-overlay.toml`). 
`~/.grokgod/overlays.toml` is test fixtures only.

## Removed — wrapper workaround, not a source patch

| ID | Mechanism | What | Why drop |
|----|-----------|------|----------|
| `ORCA-RESUME` | `grokgod run --orca-resume-tag` (introduced `090119d`, `e239bb8`) | Pre-create Orca tab + waiter + `grok --resume <uuid>` | Achieved the request on DEV-TEST run 2. Durable resume is an Orca product gap (in-app history like Codex, or spawn `--resume`). Flag, waiter, and tests deleted in this working tree; removal lands next commit. |

## Not patches

- PATH shim (`src/shim/grok-shim.sh`) and installer (`install.sh`)
- `grokgod cache`
- Official binary stays at `grok.orig`; we never Mach-O hex-edit
