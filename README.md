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

## Generated installers

The installers copy ClawGod's *build* though: `install.sh`, `install.ps1`,
`src/shim/grok-shim.sh` and the Windows launcher sources are generated, not
hand-maintained.

```
src/installer/
  constants.json                 # SHAs, repo slug, asset names — one home
  shared/fast-forward-repo.sh    # the grok-build ff/reset classifier
  shared/classify-signature.sh   # the codesign signature classifier
  shared/ps-engine-probe.cmd.part# PowerShell engine selection for .cmd launchers
  templates/*.in                 # per-target text with {{GROKGOD:...}} holes
  build.mjs                      # compiles the committed artifacts
  cut.mjs                        # re-derives templates from the committed bytes
tests/installer/                 # contract suite for the above
```

```sh
node src/installer/build.mjs          # regenerate the committed artifacts
node src/installer/build.mjs --check  # drift guard: fails if they are stale
```

The generated artifacts stay committed, so release assets, `irm | iex` and
`curl | sh` are unchanged. CI runs `--check` before the test suites, and
`tests/installer/test_generated_installers.sh` covers the pipeline itself:
artifact bytes, constants, text contracts (one trailing newline, LF, ASCII for
the PowerShell targets, exec bit) and proof that tampering with either a
generated artifact or a canonical source is actually detected. See
[`docs/adr/0005-generated-installers.md`](docs/adr/0005-generated-installers.md).

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
sh install.sh --release                                      # force GitHub prebuilt; overrides MODE=source stamp
sh install.sh --from-source                                  # source mode: fetch latest origin/main + apply patches + rebuild
sh install.sh --from-source --version <sha>                  # source mode: checkout specific tag/SHA + apply patches + rebuild
sh install.sh --no-upgrade                                   # re-apply / restore launchers, skip fetch/checkout/build
sh install.sh --force                                        # rebuild / re-download even when already current
sh install.sh --uninstall                                    # restore grok.orig
grok update                                                  # check latest upstream origin/main; re-apply patches + rebuild; no-op "Already up to date" when current
                                                             # (release: compares release tag; source: resolved origin/main SHA+patchset)
grok update --release                                        # same via shim (production on a dual-use machine)
grok update --from-source                                    # lab cargo rebuild
grok status                                                  # shim ownership + .source-version
grokgod status [--json]                                      # detailed status & health inspection (POSIX & Windows)
                                                             # POSIX --json: schema + health exit codes 0/1/2 (see below)
grokgod cache report                                         # disk / target size + ~/.grok/sessions age buckets
grokgod sessions prune                                       # dry-run old sessions; --yes --max-age 7d uses grok sessions delete
grokgod pin check [--expect-default M] [--expect-no-overlay] [--expect-orca-pin M]  # fail-closed pin precheck assertion
```

Release-mode installs also perform a cached update check on ordinary `grok`
launches. If the last successful refresh found a newer semantic release, the
shim immediately writes this notice to stderr without changing arguments or
the native process exit status:

```text
[grokgod] vNEW available (installed: vOLD) — run 'grok update' to upgrade
```

The GitHub `releases/latest` cache lives at `~/.grokgod/.update-check`. Its
network refresh is detached from startup, bounded by a short timeout, and its
attempt time is recorded before launch to enforce a 24-hour interval. Refresh
failures are silent. Source-mode
installs and the `update`, `status`, and `cache` administrative commands never
show the notice.

### POSIX Status & Artifact Manifest

`grok status` / `grokgod status` prints the human-readable report (shim path,
target binary, `.source-version`, launcher ownership, `persist:` inventory,
`source-drift`). `grokgod status --json` (or `grok status --json`, `-json`)
instead prints one JSON document on stdout and nothing on stderr:

```sh
grokgod status --json | python3 -m json.tool
```

The human report is unchanged by `--json`; any other trailing argument (for
example `status --verbose`) still selects the human report. Exit codes are
opt-in with the JSON document: `0` healthy, `1` degraded, `2` corrupt. The
human report keeps its unconditional `0`.

`health` is `healthy` (exit `0`), `degraded` (exit `1`), or `corrupt`
(exit `2`). A home installed before the manifest existed stays `healthy`:
health is only ever downgraded by the binary being missing/unreadable, a
recorded artifact digest that disagrees with the installed file, a missing or
malformed stamp, or a missing hashing tool.

Fields (exact order): `schemaVersion`, `health`, `healthDetails`, `mode`,
`version`, `sourceSha`, `patchset`, `patchStatus`, `persist`,
`launcherIdentity`, `resolvedCommandPath`, `launcherPath`,
`launcherOwnership`, `patchedBinaryPath`, `patchedBinaryExists`,
`patchedBinaryVersion`, `officialBinaryPath`, `officialBinaryExists`,
`officialBinaryVersion`, `artifactSha256`, `computedSha256`, `hashAlgorithm`,
`artifactHashMatchesRecord`, `signature`, `recordedSignature`,
`signatureVerified`, `manifestPath`, `manifestExists`, `manifestValid`,
`manifestDetail`, `installedAt`, `freeDiskBytes`, `freeDiskGigabytes`,
`sourceDrift`, `sourceDriftInstalled`, `sourceDriftUpstream`.

Value vocabularies: `healthDetails` is always an array of diagnostic strings
(empty when healthy), `patchStatus` is `applied`/`missing`,
`launcherOwnership` is `shim`/`foreign`/`absent`, `signature` is
`adhoc`/`signed`/`unsigned`/`unsupported`,
`artifactHashMatchesRecord`/`signatureVerified` are `true`/`false`/`null`, and
`persist` lists the 20 source patches plus `overlay-pin`, `eval-home`,
`weekly-pin`, and `orca-pin` with the same statuses as the human report.

`patchedBinaryVersion`, `officialBinary*` are `null`/`false` on POSIX: status
never executes the target binary (that would risk launching the TUI) and there
is no official-binary resolver outside Windows.

#### Artifact Manifest (`~/.grokgod/manifest.json`)

Install/update commit points write a POSIX artifact manifest next to the stamp
(release and source modes, after the binary is installed and ad-hoc signed).
It records `formatVersion`, `platform: "posix"`, `installedAt`,
`installedAtEpoch`, `mode`, `version`, `patchset`, `sourceSha`,
`assetSha256` (the downloaded asset digest; empty in source mode),
`artifactSha256` (the digest of the installed binary, computed **after**
codesign), `signature`, `targetExe`, and `grokgodHome`. It is written
atomically and best-effort: a manifest failure never fails an otherwise
successful install (a host with neither `sha256sum` nor `shasum` skips the
manifest and leaves the stamp authoritative), and `install.sh` never reads it —
`.source-version` remains the single source of truth for install/update
decisions. See
[`docs/adr/0006-posix-artifact-manifest.md`](docs/adr/0006-posix-artifact-manifest.md).

`grok update` records the manifest; a home installed before this change has
none, and `status --json` reports `manifestExists: false` with an explanatory
`manifestDetail` while staying `healthy` (stamp-only behavior, unchanged).
`artifactSha256` is taken from the manifest only: a release stamp holds the
pre-codesign download digest and a source stamp holds a git commit, so neither
can be compared against the installed file. A manifest is only trusted when it
is unmistakably ours (object-shaped, exactly one `formatVersion: 1`, exactly
one `platform: "posix"`, exactly one `artifactSha256`); anything else —
truncated JSON, arbitrary bytes, or the Windows installer's `manifest.json` —
is reported as invalid in `manifestDetail` and otherwise ignored.

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
- **Manifest Commit Point**: Commits `.source-version` (`SHA=...`, `PATCHSET=...`, `VERSION=2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8`, `MODE=release`) and `manifest.json` last.
- **Daily Minimal Agent**: Installs and updates the daily Minimal agent into `%USERPROFILE%\.grok\agents\minimal.md` (or `$env:GROK_HOME\agents\minimal.md`) from `examples/daily-minimal/minimal.md` (or release asset `daily-minimal.md`). This cooperating user agent is preserved on uninstall (never tracked in `manifest.files`). Official Grok invariant remains: never mutate `%USERPROFILE%\.grok\bin\grok.exe`.
- **Post-Update Convergence**: When updating an existing installation, if the newly installed `install.ps1` bytes change, the installer invokes that updated script once in a lightweight `-Finalize` mode after transaction commit and lock release. In finalize mode, the updated script downloads and verifies assets for the resolved release tag/base URL without downloading or preflighting binaries, rewriting launchers, acquiring transaction locks, or recursing. If installer bytes did not change, finalize is not spawned. Finalize errors propagate as nonzero exits with actionable diagnostics while leaving the committed binary intact. *Migration truth*: the first release containing this mechanism cannot retroactively update v1.0.38's currently executing updater during its own run; this first-hop boundary means the convergence mechanism activates reliably on subsequent updates from mechanism-equipped versions.
- **Clean Uninstall**: `install.ps1 -Uninstall` restores backups recorded in the manifest, deletes manifest-owned files, and preserves unrelated files.

Source mode tracks upstream `origin/main` on bare `grok update` (fetching latest,
re-applying persist patches, and rebuilding), mirroring ClawGod's `@latest`
lifecycle. `--version <sha>` locks to a specific commit. `--no-upgrade` skips
fetch and checkout to re-apply / restore launchers on the current tree. Both
POSIX modes record `~/.grokgod/manifest.json` (see
[POSIX Status & Artifact Manifest](#posix-status--artifact-manifest));
uninstall removes `~/.grokgod` wholesale, so the POSIX manifest deliberately
carries no owned-file or backup lists.

Patch authorship base SHA: `2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8` (`patches/README.md`). Source mode still tracks moving `origin/main`; this authorship pin is not the source-mode update target. Session-start
checks: [docs/RUNBOOK-session-start.md](docs/RUNBOOK-session-start.md) (auto-load
via [AGENTS.md](AGENTS.md)). Persist inventory (keep vs phase-out):
[docs/patch-inventory.md](docs/patch-inventory.md). Machine-readable patch list:
[`patches/registry.tsv`](patches/registry.tsv) — it drives the `grok status`
persist block and is validated by `tests/patches/test_registry.sh` (see
[`docs/adr/0007-machine-readable-patch-registry.md`](docs/adr/0007-machine-readable-patch-registry.md)).

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

`--reset` re-copies the templates. `--home DIR` uses another empty home. Interactive daily grok is unchanged (`~/.grok/config.toml`). POSIX only; Windows `grokgod eval` errors closed. Orca `grok --agent minimal` loads `~/.grok/agents/minimal.md`, installed from `examples/daily-minimal/minimal.md` (`write`, `search_replace`, `permissionMode: acceptEdits`). The eval-home agent stays write-free.

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
- **Interactive Isolation**: Shim execution never sets `GROK_CONFIG_PATH` from a leftover `orca-pin.toml`. Orca automations select the model on the automation record (`-m`). Interactive grok tags keep the `config.toml` default.
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
