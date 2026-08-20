# grokgod

ClawGod-style **wrapper** for official [Grok Build](https://github.com/xai-org/grok-build).

Official `grok update` replaces the Mach-O binary. One-off local patches die. `grokgod` re-applies persist steps on launch.

## Install

### macOS / Linux (Prebuilt Binary)

```sh
curl -fsSL https://github.com/karlorz/grokgod/releases/latest/download/install.sh | bash
```

### Windows (PowerShell - EXPERIMENTAL)

```powershell
irm https://github.com/karlorz/grokgod/releases/latest/download/install.ps1 | iex
```

### Build from Source

To build from local source using `cargo` (legacy mode):

```sh
sh install.sh --from-source
```

## Not ClawGod’s engine

ClawGod extracts `cli.js` from a Bun standalone and regex-patches JavaScript. Grok is a native Rust binary (`~/.grok/bin/grok`). There is nothing to extract. This repo copies only the **lifecycle**: wrapper name, version stamp, re-apply, keep official `grok` unpatched.

## v1 (live)

PATH `grok` / `grokgod` is the shim. Engine fixes are source patches plus
`cargo build --release -p xai-grok-pager-bin`. Not plugin.json rewrite, not
Mach-O hex.

- `0001` — `manifest.rs` filters `Component::CurDir` after `plugin_root.join`
- `0002` — plan-mode extra writable globs + `implement_via_subagents` (default
  true). Skills may write matching PRD markdown while plan mode is Active.
  After `a`, PlanReady tells the model to spawn second-tier implementers
  (not “start coding”). Canonical session `plan.md` is unchanged.

Local headed grokgod real-session tests use `grok -m flash-max` (see
[AGENTS.md](AGENTS.md)). The Saturday Weekly pin is the global `~/.grok/config.toml`
default `flash-max` (top-thread), asserted fail-closed by a `grokgod pin check`
precheck on the Orca automation; the `GROK_CONFIG_PATH` overlay via `grokgod run`
was retired for Weekly 2026-08-20 and remains for the disabled DEV-TEST fixture
and future per-job pins.

```sh
sh install.sh                                                # release mode: download prebuilt binary + shims
sh install.sh --from-source                                  # source mode: fetch + apply patches + rebuild
sh install.sh --no-upgrade                                   # re-apply / restore launchers, skip download/build
sh install.sh --force                                        # rebuild / re-download even when already current
sh install.sh --uninstall                                    # restore grok.orig
grok update                                                  # check latest; no-op "Already up to date" when current
                                                             # (release: compares release tag; source: SHA+patchset)
grok status                                                  # shim ownership + .source-version
grokgod cache report                                         # disk / target size + ~/.grok/sessions age buckets
grokgod sessions prune                                       # dry-run old sessions; --yes --max-age 7d uses grok sessions delete
grokgod pin check [--expect-default M] [--expect-no-overlay]  # fail-closed automation precheck assertion
```

Source mode pins base `d71f6e0c1f5acc5469e503e192fe14824e6f8c90` (never silently tracks
`origin/main`); `grok update --version <sha>` is the deliberate base-bump path.

Pinned grok-build SHA: `d71f6e0c1f5acc5469e503e192fe14824e6f8c90`. Session-start
checks: [docs/RUNBOOK-session-start.md](docs/RUNBOOK-session-start.md) (auto-load
via [AGENTS.md](AGENTS.md)). Persist inventory (keep vs phase-out):
[docs/patch-inventory.md](docs/patch-inventory.md).

## grokgod run (overlay pin)

`grokgod run` executes an automation run configured with a TOML config overlay and a prompt.
(Note: Weekly Dev Cache Scan overlay execution was retired 2026-08-20 in favor of the global config default pin; see [docs/orca-automation-model-pin.md](docs/orca-automation-model-pin.md) for the current automation pin architecture.)

### For Agents

Everyday agent usage runs stock `grok` (via PATH shim / patched binary). Pin a specific overlay only if `GROK_CONFIG_PATH` is explicitly set in the environment or if an automation prompt directs execution through `grokgod run`.

### Usage

```sh
# Run with automation root directory (expects DIR/grok-overlay.toml and DIR/launchd-prompt.txt)
grokgod run --automation-root /path/to/automation-dir

# Explicit prompt file or prompt string
grokgod run --automation-root DIR --prompt-file /path/to/prompt.txt
grokgod run --automation-root DIR --prompt "your prompt text"

# Explicit overlay file path (or --pin)
grokgod run --overlay /path/to/overlay.toml --prompt "your prompt text"
grokgod run --pin /path/to/overlay.toml --prompt "your prompt text"

# Dry run inspection (prints GROK_CONFIG_PATH and exec command without running)
grokgod run --automation-root DIR --dry-run
```

### Overlay Pin Mechanics & Rules

- **Official Env First**: Grok Build 1.0.5 natively supports `GROK_CONFIG_PATH=<toml> grok` for full interactive TUI sessions and headless `-p` runs as an overlay layer atop `~/.grok/config.toml`. This is official grok-build functionality, not a grokgod TUI patch.
- **Automation Helper**: `grokgod run --pin` / `--overlay` / `--automation-root` serves as the `-p` helper and enforces file/security guards. It sets `GROK_CONFIG_PATH` before invoking `$GROKGOD_BIN -p "<prompt>"`. It never passes `-m` (which is the wrong API).
- **Interactive Isolation**: Interactive shim execution (bare `grok ...`) never sets `GROK_CONFIG_PATH`.
- **Safety Guards**:
  - Rejects `--automation-root` set to `$HOME`, `~/.grok`, or `~/.grokgod`.
  - Rejects overlays containing forbidden full-config sections or keys (`[mcp_servers]`, `[auth]`, `[plugins]`, `[subagents]`, or `api_key`).
- **Template & Host Locations**:
  - Template provided at [`examples/grok-overlay.toml`](examples/grok-overlay.toml) → optional host pin at `~/.grokgod/pin/grok-overlay.toml` (installer may offer to copy if missing; unattended with `--yes`).
  - We do not ship the Weekly Orca overlay as the product; host overlays remain operator-owned.
  - `~/.grokgod/overlays.toml` is reserved for test fixtures only; production code never reads it.
  - Inspect layers with `grok inspect` or `grok models` (never paste raw inspect JSON containing secrets).

## Wiki

Vault project: `~/wiki/projects/grokgod/`

Known issue: `~/wiki/raw/transcripts/2026-08-18-bug-grok-official-update-wipes-local-patches.md`

Issue catalog: `~/wiki/projects/grokgod/requirements/2026-08-18-grok-build-wiki-issue-catalog.md`

## Status

v1 live on this host (2026-08-18): `~/.local/bin/grok` and `$GROK_HOME/bin/grok` are the shim (Orca/agentCommand `grok` is covered because we own `$GROK_HOME/bin/grok` as well as `~/.local/bin/grok`);
`~/.grokgod/bin/grok` is the patched binary (`grok 1.0.5 (d71f6e0c)`).
Post-v1 overlay pin (`grokgod run`) is implemented; Saturday schedulers stay
OFF unless you pick a path.
