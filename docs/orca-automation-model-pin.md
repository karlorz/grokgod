# Orca Automation Model Pin Architecture

## 1. Problem (ORCA-PIN)

Orca 1.4.x automations lack per-job configuration for environment variables (`agentEnv`) and custom CLI arguments (`agentArgs`). When an automation triggers, Orca launches grok directly as `grok -- <prompt>`.

Because automations run unattended, runs must guarantee they execute against the intended model (e.g. `flash-max`) without relying on interactive model selection or fragile runtime workarounds.

## 2. Pin Mechanisms

| Mechanism | Description | Scope / Behavior | Status |
|---|---|---|---|
| **(a) Global Config Default** | Set `[models] default = "flash-max"` in `~/.grok/config.toml` | Global to all standard interactive and headless grok invocations | **Active / Production** (used for Weekly scan) |
| **(b) Orca Global Argv** | Set `agentDefaultArgs.grok = ["-m", "flash-max"]` in Orca settings | Global across all Orca grok tabs and automations | Flip-proof across profile changes, but too broad (not applied) |
| **(c) GROK_CONFIG_PATH Overlay** | Run via `grokgod run --automation-root DIR` / `grokgod run --pin` | Per-job isolated overlay TOML via official environment variable | **Retired for Weekly 2026-08-20**; retained for DEV-TEST fixture & per-job pins |
| **(d) Shim Overlay Injection** | Export `GROK_CONFIG_PATH=~/.grokgod/pin/orca-pin.toml` when `ORCA_WORKTREE_ID` is set and argv is `grok -- <prompt>` | Scoped to Orca automation runs without affecting interactive grok tags, modifying global config, or Orca settings | **Available (Phase 1 opt-in)** via `~/.grokgod/pin/orca-pin.toml` |

### 2.1 Shim Overlay Injection (Mechanism d)

When Orca launches grok, Orca injects `ORCA_WORKTREE_ID` into the execution environment. Orca automations launch specifically with the argv signature `grok -- <prompt>`, whereas interactive agent tabs launch as bare `grok`, `grok -m ...`, or `grok --resume`.

The grokgod shim (`src/shim/grok-shim.sh`) checks for these conditions during passthrough execution:
- If argv starts with `--` (`$1 = "--"`), `ORCA_WORKTREE_ID` is non-empty, `GROK_CONFIG_PATH` is not already set by the caller, and `~/.grokgod/pin/orca-pin.toml` exists, the shim exports `GROK_CONFIG_PATH="$GROKGOD_HOME/pin/orca-pin.toml"`.
- Grok merges this overlay on top of `~/.grok/config.toml` at startup, pinning the model only for Orca automation runs (`grok -- <prompt>`). Interactive Orca grok tabs continue using the `config.toml` default.
- Callers who explicitly set `GROK_CONFIG_PATH` retain their custom overlay (shim does not overwrite caller-specified values).
- The opt-in template is provided at `examples/orca-pin.toml`. Copy it to `~/.grokgod/pin/orca-pin.toml` to activate.
- Status and assertions: `grok status` displays `orca-pin: enabled/disabled`, and `grokgod pin check --expect-orca-pin <model>` provides fail-closed assertion support.

## 3. Findings (2026-08-20 Probes)

Empirical observation from external automation probes:
1. `/model <x>` as the first line of an automation prompt executes before the internal model registry finishes loading asynchronously. This results in errors such as `Unknown model: flash-max` and `Unknown model: grok-4.5`, causing the rest of the prompt to never be submitted and the automation run to hang indefinitely.
2. Interactive post-startup `/model flash-max` works reliably via picker once the session TUI is fully initialized.
3. Before orca-pin, `grok -- <prompt>` inherited `config.toml` `[models] default`. After orca-pin, automations (`grok -- <prompt>` + `ORCA_WORKTREE_ID`) merge `~/.grokgod/pin/orca-pin.toml` (`flash-max`). Interactive Orca grok tags do not.
4. (2026-08-21) Pinning every Orca grok tab from `ORCA_WORKTREE_ID` alone was a leak: `--agent grok` / `terminal create grok` stuck on `flash-max`. Guard is now `$1 = "--"`.

## 4. Recommended Pattern (2026-08-21)

Keep interactive grok and Orca automations on **different** models:

1. **Interactive default** lives in `~/.grok/config.toml` `[models] default`
   (currently `grok-4.6`). New Orca grok tags use this. Do **not** set the
   global default to `flash-max` just to pin automations — that was mechanism
   (a) and it leaked into every tab.
2. **Automation pin** is mechanism (d): opt-in `~/.grokgod/pin/orca-pin.toml`
   (`default = "flash-max"`). The shim applies it only to `grok -- <prompt>`.
3. **Precheck** on the Orca automation:
   ```sh
   $HOME/.local/bin/grokgod pin check --expect-orca-pin flash-max
   ```
   Scheduler: non-zero exit records `skipped_precheck`. Manual
   `orca automations run` bypasses precheck (`precheckResult` null) and
   still gets the overlay at process start because argv is `grok -- <prompt>`.
4. **Prompt step-0 guard** remains defense in depth. Never put `/model …` as
   the first line of an automation prompt (startup registry race).

Do **not** use `--expect-default flash-max --expect-no-overlay` on the
current Weekly/Daily path: the overlay **is** set for automations, and the
config default is **not** flash-max.

## 5. Rollback

To rollback the Weekly Dev Cache Scan prompt to the wrapper script version:
```sh
orca automations edit 0bbdc998-… --prompt "$(cat ~/.orca/automations/weekly-dev-cache-scan/archive/orca-wrapper-prompt.txt)"
```

## 6. Upstream Watch

- `stablyai/orca` Issue #13843: Support per-automation environment variables (`agentEnv`).
- `stablyai/orca` PR #11873: Support per-automation CLI arguments (`agentArgs`).
