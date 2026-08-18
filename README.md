# grokgod

ClawGod-style **wrapper** for official [Grok Build](https://github.com/xai-org/grok-build).

Official `grok update` replaces the Mach-O binary. One-off local patches die. `grokgod` re-applies persist steps on launch.

## Not ClawGod’s engine

ClawGod extracts `cli.js` from a Bun standalone and regex-patches JavaScript. Grok is a native Rust binary (`~/.grok/bin/grok`). There is nothing to extract. This repo copies only the **lifecycle**: wrapper name, version stamp, re-apply, keep official `grok` unpatched.

## v1 (not implemented yet)

`grokgod apply` — rewrite installed plugin manifests:

- `"skills": "./skills/"` → `"skills"`
- `"skills": "./"` → omit or `"skills"` when a `skills/` dir exists

Then `grokgod` execs official `grok` with the same argv.

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

Bootstrap only (2026-08-18). No launcher on PATH yet.
