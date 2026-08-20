# AGENTS.md - grokgod

ClawGod-style persist wrapper for official Grok Build (Rust). Source patches in
`patches/`, PATH shim + installer in `src/` and `install.sh`, tests in `tests/`.

## Session-start runbook (MANDATORY, run once)

Before any other work in this repo, read and run
[`docs/RUNBOOK-session-start.md`](docs/RUNBOOK-session-start.md):

1. Disk watch (host volume is tight; cargo builds eat GBs)
2. Upstream patch watch (is our manifest.rs normalize fixed upstream?)
3. Live state sanity (shim ownership of `~/.local/bin/grok`)
4. Pin facts: interactive default is ~/.grok/config.toml (currently grok-4.6).
   Orca automations (Daily 04136086, Weekly f91e2fc7) launch `grok -- <prompt>`
   and get ~/.grokgod/pin/orca-pin.toml flash-max via the shim. `--agent grok`
   tags do not. Precheck is `grokgod pin check --expect-orca-pin flash-max`
   (do not use --expect-no-overlay on this path). grokgod run remains for the
   disabled DEV-TEST fixture. Historical Weekly id 0bbdc998 is retired.
   launchd retired. Codex Scheduled copies stay PAUSED.
5. Release CI facts (`macos-13` retired -> `macos-15-intel`; dotslash required
   for vendored `bin/protoc`; release job gates on required legs)
6. Local real-session tests use `flash-max` (`grok -m flash-max`), not grok-4.6

Report anomalies in your first substantive reply. Do not auto-fix beyond what
the runbook lists.

## Hard rules

- Never write production code on the parent agent - implementation goes to
  subagents; parent verifies results.
- Never run cache-cleaner `--apply`. Saturday scheduler path was DECIDED
  2026-08-19: Orca automation `0bbdc998` is the single trigger (enabled);
  launchd is retired — never re-enable launchd while the Orca automation is
  on, and never disable the Orca automation without user instruction.
- Never modify `patches/` or rebuild unless the user approves or
  `grokgod update` flow requires it.
- `~/.grokgod/overlays.toml` is test fixtures only; production code must not
  read it. The Weekly overlay
  (`~/.orca/automations/weekly-dev-cache-scan/grok-overlay.toml`) was retired
  2026-08-20 (pin is now the global config default); the file is kept in place
  for the disabled DEV-TEST fixture.
- No Docker. No secrets in this repo.
- grok-build checkout showing `manifest.rs` modified is EXPECTED (our applied
  patch); `install.sh` handles reverse/re-apply on update.
- Local grokgod real-session tests (headed Orca TUI / interactive grok against
  the live patched binary) MUST use model `flash-max`: `grok -m flash-max`
  (or `/model flash-max` after launch). Do not test on grok-4.6. This is
  separate from Saturday overlay pin (`GROK_CONFIG_PATH`; that path still
  never uses `-m`).

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
