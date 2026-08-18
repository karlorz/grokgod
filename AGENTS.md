# AGENTS.md - grokgod

ClawGod-style persist wrapper for official Grok Build (Rust). Source patches in
`patches/`, PATH shim + installer in `src/` and `install.sh`, tests in `tests/`.

## Session-start runbook (MANDATORY, run once)

Before any other work in this repo, read and run
[`docs/RUNBOOK-session-start.md`](docs/RUNBOOK-session-start.md):

1. Disk watch (host volume is tight; cargo builds eat GBs)
2. Upstream patch watch (is our manifest.rs normalize fixed upstream?)
3. Live state sanity (shim ownership of `~/.local/bin/grok`)
4. Overlay pin facts (GROK_CONFIG_PATH, never `-m`; schedulers stay OFF)
5. Release CI facts (`macos-13` retired -> `macos-15-intel`; dotslash required
   for vendored `bin/protoc`; release job gates on required legs)

Report anomalies in your first substantive reply. Do not auto-fix beyond what
the runbook lists.

## Hard rules

- Never write production code on the parent agent - implementation goes to
  subagents; parent verifies results.
- Never run cache-cleaner `--apply`, never enable the Saturday schedulers
  (Orca automation or launchd) without explicit user instruction.
- Never modify `patches/` or rebuild unless the user approves or
  `grokgod update` flow requires it.
- `~/.grokgod/overlays.toml` is test fixtures only; production code must not
  read it. The live overlay lives under
  `~/.orca/automations/weekly-dev-cache-scan/grok-overlay.toml`.
- No Docker. No secrets in this repo.
- grok-build checkout showing `manifest.rs` modified is EXPECTED (our applied
  patch); `install.sh` handles reverse/re-apply on update.

## Repo map

- `install.sh` - ClawGod-style installer: fetch, `git apply --check`
  fail-closed, `CARGO_TARGET_DIR=~/.grokgod/target`, 15 GiB disk guard,
  launcher install, uninstall/restore.
- `patches/` - source patches against xai-org/grok-build (base SHA in
  `patches/README.md`).
- `src/shim/grok-shim.sh` - PATH shim: update/status/cache/run dispatch,
  absolute-path exec, `GROK_DISABLE_AUTOUPDATER=1`.
- `src/grokgod-run.sh` - overlay pin runner (`GROK_CONFIG_PATH`).
- `src/grokgod-cache.sh` - disk report + guarded clean.
- `tests/` - run each suite standalone with `sh tests/<dir>/test_*.sh`.
