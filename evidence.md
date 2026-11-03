# Evidence — Windows/T3 process integration (static checkpoint)

## Scope and provenance

- **Base (unchanged parent):** `4e082afa1dcb7e3ba14f81bd52696c922bf3997c`
- **Branch:** `windows-t3-process-integration`
- **Workspace:** `e209e01c-d64a-4f77-a292-e8405cea33b4::/Users/karlchow/orca/workspaces/src/windows-t3-process-integration`
- **Checkpoint commit:** the local commit on this branch that introduced this evidence file. Exact SHA is reported to the coordinator as `git rev-parse HEAD` after that commit (do not copy a SHA from an older evidence snapshot).
- **Code tree** (index minus this evidence file): `6b44e471982c0443e9e4c1f12cbc6807b6ddcf23`
- **Code archive sha256** (`git archive` of that tree): `94557953e6cef02dc9c01a9b9b1f8c23b82f18fc17f7a138bc3e11fc429c79d3`
- **Host:** macOS dev host. Native Windows execution is **pending** on MSI-1 `%TEMP%` fixtures and localhost fixtures; this checkpoint is static-only.
- **No release / no deploy / no push:** nothing was pushed, tagged, published, installed, or merged. Live T3 settings and the patched binary on MSI-1 were not touched.

Prior tree identities in older evidence (`925f0adc…` / `86dc51f3…` / `tree2.tar`) are historical. They do not describe these bytes.

## Static results on these bytes

| Check | Result |
| --- | --- |
| `node src/installer/build.mjs --check` | 6/6 ok |
| `node src/installer/cut.mjs --check` | 6/6 ok |
| `sh tests/installer/test_generated_installers.sh` | 72 pass / 0 fail |
| `sh tests/shim/test_shim_windows.sh` | 228 pass / 0 fail |
| `sh tests/install/test_install_windows.sh` | 217 pass / 0 fail |
| `install.sh` / `src/shim/grok-shim.sh` | unchanged vs base (POSIX generated artifacts not rewritten) |

POSIX `tests/install/test_install.sh` was not re-run: `install.sh` bytes match base.

## What changed on this checkpoint

1. **SAFE ARGV.** Removed `GROKGOD_LAUNCHER_TAIL`, `__grokgod_launcher_tail`, and `ConvertFrom-WindowsCommandLine`. Canonical launchers (`LauncherHelpers.ps1.in` and both CMD templates) use `setlocal DisableDelayedExpansion` and forward `%*` directly to `pwsh -File`. The Node fixture driver applies the proven CRT quote/backslash encoding then twice CMD-metachar escaping with `windowsVerbatimArguments: true` (root audit `/tmp/grokgod-argv-audit`, 4/4 exact). Native argv cases (empty, spaces, embedded quote, trailing slash, standalone meta, Unicode, literal `%VAR%`, combined quote+metachar, leading flags, sentinel never executed) are in `tests/shim/test_shim_windows.ps1` and are **not yet run natively**.
2. **Canonical PS7 resolver/probe.** `src/installer/shared/ps7-version-probe.ps1.part` and `ps7-resolver.ps1.part` are compiled into both `install.ps1` and `LauncherHelpers.ps1`. `build.mjs` `SHARED_INCLUDE_RE` accepts hyphenated function names. `cut.mjs` round-trips both functions. Lossless-merge checks confirm the two generated copies match the shared source. Files were untracked, not gitignored; they are added. Bootstrap helpers are inlined before the installer PS7 gate (no external installed-source dependency).
3. **Deadlines.** Installer `Stop-GrokgodOwnedProcessTree` no longer does unconditional `tkOut.Wait(250)`; drains are fire-and-forget with stream disposal. Preflight stopwatch starts before `Process.Start`; remaining budget is recomputed before WaitForExit and each drain. Shared version probe WaitForExit uses remaining budget. Status intended 3s + documented cleanup and installer 5s + cleanup are unchanged in contract. Fail-closed empty version / held EOF / nonzero preflight is preserved.
4. **PS7.** Shim still rejects PS<7 before side effects. Updater/refresh still uses `Resolve-GrokgodEngine` (verified absolute PS7, never powershell.exe fallback). Group 9 now overrides both `ProgramFiles` roots to empty fixture dirs in the **child env only**, uses a discovery-only launcher for missing/broken/<7, keeps baked-valid PS7, and proves genuine standard discovery from the verified engine path. Host-dependent skip removed.
5. **Docs.** README dispatcher section describes direct `%*` + caller CRT/CMD escaping. T3 direct patched-exe + `GROK_DISABLE_AUTOUPDATER=1`, host selection, and release/patchset vs bundled vs official version vocabulary remain. Original wrapper timeout remains unresolved; direct-path mitigation remains the verified mitigation. No MSYS/T3-expansion invention.

## Key file sha256 (working tree)

- `src/shim/grok-shim.ps1` `69e4b86883cdf9b6f9e72235f6b4716c33ce8defc87b1083d6d96828b597465a`
- `src/shim/LauncherHelpers.ps1` `7ff491c5c2d0e0a007e7ac9529020152b3d7d2106efb00a4be4f58db7e730285`
- `src/shim/templates/grok.cmd.template` `4d9ad730c48dda166536611e8c056bf525ce0fee71ba8155026146beead4917f`
- `src/shim/templates/grokgod.cmd.template` `c9dac15eb83cb30ff9cb8ff1d444af5c80a49378fe47501595d7976189f1b4d9`
- `install.ps1` `cd6916b4f78162321c6fdd22d4c580ca7713ffa47a0867dee6e83bd7c08786b4`
- `src/installer/shared/ps7-resolver.ps1.part` `12f4655da43c9ac32e771cfd2562c23059407f3f350115c7e6bf4d7bbd69f383`
- `src/installer/shared/ps7-version-probe.ps1.part` `68a4ff9c1498e19230ea1b242ddd6e63172bc2a7780f33d4f3bb6845b24a8bec`
- `tests/shim/launcher_fixture_driver.js` `06d20daa1aab43ba93c6c424c1ec4a9a166b93cda3a47c8071969ab4af90a1f6`
- `tests/shim/test_shim_windows.ps1` `631352dc7092ebf640177613cf52df2cd56be9c60d3ca88a8fd960ba10779ffa`
- `tests/shim/test_shim_windows.py` `4bb6db5da15954d18a9b249a1cdb84fc3636b922b68b21bd1d869cb6552b3d88`
- `tests/install/test_install_windows.py` `8a66476a82f345b79d56498bd4f034618612840a2f347c8f91b62a645a6f1e1b`

## Historical native baseline (superseded as acceptance; retained as history)

wt3v6 on an earlier tree: **139 pass / 8 fail**. Root independently classified those 8 as cached-notice exact stderr + detached refresh + six prerequisite/baked-path assertions. The handoff claim that 7 were harness ExitCode-after-Dispose and 1 was flaky is **unproven**; this checkpoint does not relabel them. All 8 must be retested on **these** bytes. Do not infer a pass from wt3v6.

## Explicitly pending (native)

Run on identical source bytes (this checkpoint SHA) in MSI-1 `%TEMP%` only and localhost fixtures, **argv + group-9 prerequisite first**, then the broad battery:

- `pwsh -NoProfile -File tests/shim/test_shim_windows.ps1` (argv 6.7/6.8 including sentinel-never-executed; group 9 missing/broken/<7/baked/standard discovery)
- `pwsh -NoProfile -File tests/install/test_install_windows.ps1`
- Startup samples via `tests/shim/measure_launcher_startup.ps1` on isolated fixture env with output/exit checked
- Double-pwsh spawn (CMD probe then shim) efficiency: **deferred** until measured on these bytes. Historical ~1.4 s vs T3 4 s is historical only.
- Hanging prerequisite CMD candidate: `ps-engine-probe.cmd.part` documents that cmd.exe has no wait-with-timeout; a powershell.exe babysitter was rejected. **No production bound is claimed from the caller watchdog.** Targeted native hang proof remains pending/deferred with that rationale.
- PSParser parse-only of edited PowerShell files on Windows
- Draft PR / Windows CI: root ownership
- Live flash-max install/test: root ownership
- Version bump / tag / release: root ownership

## Invariants held

- No `patches/` or Rust edits, no Docker, no secrets, no live T3/PATH changes, no worker push/PR/merge/tag.
- Generated artifacts produced only via `node src/installer/build.mjs`.
- Current T3 direct binary + `GROK_DISABLE_AUTOUPDATER=1` setup is preserved (not modified this turn).
