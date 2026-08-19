# grokgod persist inventory (docs only, 2026-08-19)

ClawGod-style tracking of what grokgod **must** re-apply after `grok update`,
versus wrapper behavior, versus work we will not keep. This file is the
inventory. Catalog/automation of apply+verify (the ClawGod `patch.mjs` analog)
waits on `/grill-with-docs`. Do not add or remove source patches from this
list without that grill.

## Keep — grok-build source patch (re-apply on update)

| ID | File | What | Why persist |
|----|------|------|-------------|
| `0001` | `patches/0001-normalize-plugin-skill-join.patch` | Filter `Component::CurDir` in `manifest.rs` skill joins so `"./skills/"` registers | Official `grok update` replaces the Mach-O; without this, installed plugin skill paths 404 |

Base SHA: see `patches/README.md` (`d71f6e0c`). Fail closed on `git apply --check`.

## Keep — wrapper, not a source patch

| ID | Mechanism | What | Why persist |
|----|-----------|------|-------------|
| `ORCA-PIN` | `src/grokgod-run.sh` + automation-root `grok-overlay.toml` | Export `GROK_CONFIG_PATH` and exec/run `grok -p` (never `-m`) | Orca 1.4.184 has no per-automation env. Interactive grok must stay on `~/.grok/config.toml`. |

Production overlay lives under the automation root (Weekly:
`~/.orca/automations/weekly-dev-cache-scan/grok-overlay.toml`). 
`~/.grokgod/overlays.toml` is test fixtures only.

## Phase out — wrapper workaround, not a source patch

| ID | Mechanism | What | Why drop |
|----|-----------|------|----------|
| `ORCA-RESUME` | `grokgod run --orca-resume-tag` (commits `090119d`, `e239bb8`) | Pre-create Orca tab + waiter + `grok --resume <uuid>` | Achieved the request on DEV-TEST run 2. Durable resume is an Orca product gap (in-app history like Codex, or spawn `--resume`). Do not ship as v1 persist. |

Removal of the flag, waiter, automation prompt bit, and tests is a later
change **after** grill-with-docs. Until then the flag may stay in the tree
so Saturday still has a workaround.

## Not patches

- PATH shim (`src/shim/grok-shim.sh`) and installer (`install.sh`)
- `grokgod cache`
- Official binary stays at `grok.orig`; we never Mach-O hex-edit
