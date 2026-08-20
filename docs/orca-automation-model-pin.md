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
| **(d) Shim Overlay Injection** | Export `GROK_CONFIG_PATH=~/.grokgod/pin/orca-pin.toml` when `ORCA_WORKSPACE_ID` is set | Scoped to Orca-launched grok sessions without modifying global config or Orca settings | **Available (Phase 1 opt-in)** via `~/.grokgod/pin/orca-pin.toml` |

### 2.1 Shim Overlay Injection (Mechanism d)

When Orca launches grok (in both interactive Orca tabs and Orca automations), Orca injects `ORCA_WORKSPACE_ID` into the execution environment.

The grokgod shim (`src/shim/grok-shim.sh`) checks for this environment variable during passthrough execution:
- If `ORCA_WORKSPACE_ID` is non-empty, `GROK_CONFIG_PATH` is not already set by the caller, and `~/.grokgod/pin/orca-pin.toml` exists, the shim exports `GROK_CONFIG_PATH="$GROKGOD_HOME/pin/orca-pin.toml"`.
- Grok merges this overlay on top of `~/.grok/config.toml` at startup, pinning the model for all Orca-spawned sessions without altering `config.toml` or requiring Orca settings modifications.
- Callers who explicitly set `GROK_CONFIG_PATH` retain their custom overlay (shim does not overwrite caller-specified values).
- The opt-in template is provided at `examples/orca-pin.toml`. Copy it to `~/.grokgod/pin/orca-pin.toml` to activate.
- Status and assertions: `grok status` displays `orca-pin: enabled/disabled`, and `grokgod pin check --expect-orca-pin <model>` provides fail-closed assertion support.

## 3. Findings (2026-08-20 Probes)

Empirical observation from external automation probes:
1. `/model <x>` as the first line of an automation prompt executes before the internal model registry finishes loading asynchronously. This results in errors such as `Unknown model: flash-max` and `Unknown model: grok-4.5`, causing the rest of the prompt to never be submitted and the automation run to hang indefinitely.
2. Interactive post-startup `/model flash-max` works reliably via picker once the session TUI is fully initialized.
3. Headless automation sessions (`grok -- <prompt>`) inherit the global default model from `~/.grok/config.toml` (verified via footer `flash-max (max)`, 372K context window, and `current_model_id` in `~/.grok/sessions/<cwd-slug>/<session-id>/summary.json`).

## 4. Recommended Pattern

To ensure automated runs execute with the correct model fail-closed:
1. **Global Default Pin**: Set `[models] default = "flash-max"` in `~/.grok/config.toml`.
2. **Precheck Assertion**: Configure the Orca automation `--precheck` field:
   ```sh
   $HOME/.local/bin/grokgod pin check --expect-default flash-max --expect-no-overlay
   ```
   *Exit 0 allows the automation run to proceed; non-zero hard-skips the run.*
   
   Verified Orca semantics (2026-08-20):
   - **Scheduler fires**: Non-zero exit records status `skipped_precheck` and populates `precheckResult` (`command`, `exitCode`, `stderr`, `durationMs`).
   - **Manual fires**: `orca automations run <id>` bypasses precheck entirely (`precheckResult` remains null) and dispatches directly to an agent session.
   - **Drift protection**: Operator changes to `~/.grok/config.toml` `[models] default` (e.g. moving between models mid-day) fail closed into skipped runs rather than wrong-model execution.
3. **Prompt Step-0 Guard**: Include an in-prompt fail-closed verification step at step 0 to confirm runtime model identity before taking actions.

## 5. Rollback

To rollback the Weekly Dev Cache Scan prompt to the wrapper script version:
```sh
orca automations edit 0bbdc998-… --prompt "$(cat ~/.orca/automations/weekly-dev-cache-scan/archive/orca-wrapper-prompt.txt)"
```

## 6. Upstream Watch

- `stablyai/orca` Issue #13843: Support per-automation environment variables (`agentEnv`).
- `stablyai/orca` PR #11873: Support per-automation CLI arguments (`agentArgs`).
