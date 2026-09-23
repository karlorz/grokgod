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
- `0004` — `[workflows.builtins] deep-research` (default on). Set `false` in
  config or `/plugin` → Workflows Space to hide the compiled-in workflow so
  plugin `deep-research:deep-research` can own `/deep-research` in the same
  session. Install merges `false` when the key is missing. No `/settings` row.

Local headed grokgod real-session tests use `grok -m flash-max` (see
[AGENTS.md](AGENTS.md)). Orca desktop v1.4.206-1 selects the automation model
from its published model field (`-m`), reasoning effort, and optional agent
profile. The old Saturday pin overlay and its `grokgod pin check` precheck are
deprecated as of 2026-09-23; `GROK_CONFIG_PATH` via `grokgod run` remains for
the disabled DEV-TEST fixture and future per-job pins.

```sh
sh install.sh                                                # release mode: download prebuilt binary + shims
sh install.sh --from-source                                  # source mode: fetch latest origin/main + apply patches + rebuild
sh install.sh --from-source --version <sha>                  # source mode: checkout specific tag/SHA + apply patches + rebuild
sh install.sh --no-upgrade                                   # re-apply / restore launchers, skip fetch/checkout/build
sh install.sh --force                                        # rebuild / re-download even when already current
sh install.sh --uninstall                                    # restore grok.orig
grok update                                                  # check latest upstream origin/main; re-apply patches + rebuild; no-op "Already up to date" when current
                                                             # (release: compares release tag; source: resolved origin/main SHA+patchset)
grok status                                                  # shim ownership + .source-version
grokgod status [--json]                                      # detailed status & health inspection (POSIX & Windows)
grokgod cache report                                         # disk / target size + ~/.grok/sessions age buckets
grokgod sessions prune                                       # dry-run old sessions; --yes --max-age 7d uses grok sessions delete
grokgod pin check [--expect-default M] [--expect-no-overlay] [--expect-orca-pin M]  # fail-closed pin precheck assertion
```

### Windows Dispatcher & Command Matrix

On Windows, `grok.cmd` and `grokgod.cmd` forward commands with positional identity to `src/shim/grok-shim.ps1` (e.g. `"%POWERSHELL_EXE%" ... -File "grok-shim.ps1" grok %*`):
- `grok update [allowed args]` -> invokes installed updater (`install.ps1`). Allowed flags: `--version <tag>`, `--no-upgrade`, `--force`. Rejects `--uninstall`, prefix modifications, and unrecognized arguments.
- `grok status [--json]` / `grokgod status [--json]` -> wrapper status inspection (never launches TUI).
- `grok [args]` (including `grok sessions ...`) -> passes through arguments unchanged to the patched `grokgod.exe` with `GROK_DISABLE_AUTOUPDATER=1`.
- `grokgod update [allowed args]` -> wrapper update.
- `grokgod sessions`, `grokgod cache`, `grokgod run`, `grokgod pin`, `grokgod eval`, `grokgod eval-health`, or bare `grokgod` -> explicit Windows error and guidance, **never falling through to the interactive TUI**.

#### Status Schema & Health States

`grok status --json` or `grokgod status --json` outputs a structured JSON document:
- `health`: `"healthy"`, `"degraded"`, or `"corrupt"`.
- `healthDetails`: Array of diagnostic notices and health failure reasons.
- `launcherIdentity`: `"grok"` or `"grokgod"`.
- `resolvedCommandPath`: Path to the executing script.
- `patchedBinaryPath`, `patchedBinaryExists`, `patchedBinaryVersion`: Wrapper executable details.
- `officialBinaryPath`, `officialBinaryExists`, `officialBinaryVersion`: Official grok binary details when detected.
- `versionSkewExplanation`: Explains version skew between patched and official binaries, advising how to run official directly via `directOfficialPath`.
- `artifactSha256`, `computedSha256`, `patchset`, `sourceSha`, `mode`: Packaging metadata.
- `freeDiskBytes`, `freeDiskGigabytes`: Free disk space available.

Corrupt states (e.g. missing patched binary, hash mismatch) return a non-zero exit code while maintaining valid, well-formed JSON.

### Windows Transactional Installer (`install.ps1`)

The Windows installer provides transactional install, update, and uninstall semantics for Windows x64 (`PowerShell 5.1` and `PowerShell 7` compatible):
- **Platform Check**: Fails closed immediately on Windows ARM64 before any network access (Windows x64 only).
- **Prefix Safety**: Rejects `-Prefix` values that overlap the official `.grok` tree (`%USERPROFILE%\.grok` or child/parent directories).
- **Official Grok Invariant**: Never opens for write, renames, replaces, or deletes official `%USERPROFILE%\.grok\bin\grok.exe`.
- **Exact Checksum Verification**: Enforces exactly one checksum entry in `SHA256SUMS` matching `grokgod-windows-x64.exe` exactly. No regex substring matching or first-line fallback.
- **Preflight Check**: Executes candidate `--version` prior to any live target mutation.
- **Destination-Volume Sibling Staging**: Stages candidate binary on the target volume (`candidate-<guid>.exe`) with bounded backups of prior components.
- **Transactional Rollback**: Reverts completely to pristine prior state if candidate preflight fails, target is locked/running, or any failure occurs.
- **Manifest Commit Point**: Commits `.source-version` (`SHA=...`, `PATCHSET=...`, `VERSION=07e35a3dfeed2f200d319ef6c893b5ea286d9a51`, `MODE=release`) and `manifest.json` last.
- **Clean Uninstall**: `install.ps1 -Uninstall` restores backups recorded in the manifest, deletes manifest-owned files, and preserves unrelated files.

Source mode tracks upstream `origin/main` on bare `grok update` (fetching latest,
re-applying persist patches, and rebuilding), mirroring ClawGod's `@latest`
lifecycle. `--version <sha>` locks to a specific commit. `--no-upgrade` skips
fetch and checkout to re-apply / restore launchers on the current tree.

Patch authorship base SHA: `07e35a3dfeed2f200d319ef6c893b5ea286d9a51` (`patches/README.md`). Source mode still tracks moving `origin/main`; this authorship pin is not the source-mode update target. Session-start
checks: [docs/RUNBOOK-session-start.md](docs/RUNBOOK-session-start.md) (auto-load
via [AGENTS.md](AGENTS.md)). Persist inventory (keep vs phase-out):
[docs/patch-inventory.md](docs/patch-inventory.md).

## grokgod eval (DeepSeek benchmark home)

Isolated chat for model evaluation. Not a grok-build source patch and not `GROK_CONFIG_PATH` (that overlay cannot turn plugins or memory off).

```sh
export CLIAPI_API_KEY=...   # or NEW_API_KEY
grokgod eval                # TUI in ~/.grokgod/eval-home
grokgod eval --dry-run
grokgod eval -- --verbatim -p "hello"
```

Seeds `~/.grokgod/eval-home` from [`examples/eval-home`](examples/eval-home): empty plugin enable list, memory off, DeepSeek **Minimal** agent (`--agent minimal`, `promptMode: full`). Daily grok stays **Standard**. Launch flags: `--no-memory --no-subagents --no-plan --disable-web-search --sandbox read-only --minimal -m deepseek-v4-flash`. CLI `--minimal` is TUI screen mode, not the preset name.

Paste or `@`-attach images for native DeepSeek vision. Do not type `read /path/to.jpg` — `read_file` is a path placeholder, which is why a full grok-build session POSTed the screenshot to Poe.

`--reset` re-copies the templates. `--home DIR` uses another empty home. Interactive daily grok is unchanged (`~/.grok/config.toml`). POSIX only; Windows `grokgod eval` errors closed.

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
- **Interactive Isolation**: Interactive shim execution (bare `grok ...`, `grok -m ...`, `grok --resume`) never sets `GROK_CONFIG_PATH`. Historically, for Orca automation runs (`ORCA_WORKTREE_ID` set and argv `grok -- <prompt>`), the shim injects the opt-in `~/.grokgod/pin/orca-pin.toml` overlay if present (see `examples/orca-pin.toml` and [docs/orca-automation-model-pin.md](docs/orca-automation-model-pin.md)); this overlay is deprecated as of 2026-09-23. The current model path is the Orca automation model field on desktop v1.4.206-1. Interactive Orca grok tags keep the `config.toml` default.
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

v1 live on this host (2026-08-21): `~/.local/bin/grok` and `$GROK_HOME/bin/grok` are the shim (Orca/agentCommand `grok` is covered because we own `$GROK_HOME/bin/grok` as well as `~/.local/bin/grok`);
`~/.grokgod/bin/grok` is the patched binary (`grok 1.0.6 (19d42e35)`).
Bare `grok update` tracks grok-build `origin/main` and re-applies persist patches.
Post-v1 overlay pin (`grokgod run`) is implemented; Saturday schedulers stay
OFF unless you pick a path.
