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

PATH `grok` / `grokgod` is the shim. Engine fix is a source patch on
`manifest.rs` (filter `Component::CurDir` after `plugin_root.join`) plus
`cargo build --release -p xai-grok-pager-bin`. Not plugin.json rewrite, not
Mach-O hex.

```sh
sh install.sh                  # release mode: download prebuilt binary + shims
sh install.sh --from-source    # source mode: fetch + apply patches + rebuild
sh install.sh --no-upgrade     # re-apply / restore launchers, skip download/build
sh install.sh --force          # rebuild / re-download even when already current
sh install.sh --uninstall      # restore grok.orig
grok update                    # check latest; no-op "Already up to date" when current
                               # (release: compares release tag; source: SHA+patchset)
grok status                    # shim ownership + .source-version
grokgod cache report           # disk / target size
```

Source mode pins base `d71f6e0c1f5acc5469e503e192fe14824e6f8c90` (never silently tracks
`origin/main`); `grok update --version <sha>` is the deliberate base-bump path.

Pinned grok-build SHA: `d71f6e0c1f5acc5469e503e192fe14824e6f8c90`. Session-start
checks: [docs/RUNBOOK-session-start.md](docs/RUNBOOK-session-start.md) (auto-load
via [AGENTS.md](AGENTS.md)). Persist inventory (keep vs phase-out):
[docs/patch-inventory.md](docs/patch-inventory.md).

## grokgod run (overlay pin)

`grokgod run` executes an automation run configured with a TOML config overlay and a prompt.

### Usage

```sh
# Run with automation root directory (expects DIR/grok-overlay.toml and DIR/launchd-prompt.txt)
grokgod run --automation-root /path/to/automation-dir

# Explicit prompt file or prompt string
grokgod run --automation-root DIR --prompt-file /path/to/prompt.txt
grokgod run --automation-root DIR --prompt "your prompt text"

# Explicit overlay file path
grokgod run --overlay /path/to/overlay.toml --prompt "your prompt text"

# PHASE-OUT: Orca resume workaround (hit the request; durable fix is Orca-side)
grokgod run --automation-root DIR --orca-resume-tag

# Dry run inspection (prints GROK_CONFIG_PATH and exec command without running)
grokgod run --automation-root DIR --dry-run
```

### Overlay Pin Mechanics & Rules

- **Pin API**: Sets the `GROK_CONFIG_PATH` environment variable pointing to the overlay TOML file, then invokes `$GROKGOD_BIN -p "<prompt>"`. Never passes `-m` (which is the wrong API).
- **Interactive Isolation**: Interactive shim execution (bare `grok ...`) never sets `GROK_CONFIG_PATH`.
- **Safety Guards**:
  - Rejects `--automation-root` set to `$HOME`, `~/.grok`, or `~/.grokgod`.
  - Rejects overlays containing forbidden full-config sections or keys (`[mcp_servers]`, `[auth]`, `[plugins]`, `[subagents]`, or `api_key`).
- **Overlay Locations**:
  - `~/.grokgod/overlays.toml` is reserved for test fixtures only; production code never reads it.
  - The live overlay home is the Weekly Dev Cache Scan automation directory.

## Wiki

Vault project: `~/wiki/projects/grokgod/`

Known issue: `~/wiki/raw/transcripts/2026-08-18-bug-grok-official-update-wipes-local-patches.md`

Issue catalog: `~/wiki/projects/grokgod/requirements/2026-08-18-grok-build-wiki-issue-catalog.md`

## Status

v1 live on this host (2026-08-18): `~/.local/bin/grok` and `$GROK_HOME/bin/grok` are the shim (Orca/agentCommand `grok` is covered because we own `$GROK_HOME/bin/grok` as well as `~/.local/bin/grok`);
`~/.grokgod/bin/grok` is the patched binary (`grok 1.0.5 (d71f6e0c)`).
Post-v1 overlay pin (`grokgod run`) is implemented; Saturday schedulers stay
OFF unless you pick a path.
