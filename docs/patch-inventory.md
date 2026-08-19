# grokgod persist inventory (2026-08-19)

ClawGod-style tracking of what grokgod **must** re-apply after `grok update`,
versus wrapper behavior, versus work we will not keep. This file is the
inventory. Persist status is exposed via the `grok status` persist block
(`0001-normalize-plugin-skill-join: applied|missing`, `overlay-pin: wrapper|missing`).

## Keep — grok-build source patch (re-apply on update)

| ID | File | What | Why persist |
|----|------|------|-------------|
| `0001` | `patches/0001-normalize-plugin-skill-join.patch` | Filter `Component::CurDir` in `manifest.rs` skill joins so `"./skills/"` registers | Official `grok update` replaces the Mach-O; without this, installed plugin skill paths 404 |

Base SHA: see `patches/README.md` (`d71f6e0c`). Fail closed on `git apply --check`.

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
