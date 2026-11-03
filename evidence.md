# Evidence - Windows/T3 process integration

## Current revision (acceptance candidate)

- **Base (unchanged parent):** `4e082afa1dcb7e3ba14f81bd52696c922bf3997c`
- **Branch:** `windows-t3-process-integration`
- **Current commit:** `9b7e4384baa53cfe7b92a7393589170b70becc32` (local; root owns push/CI/release)
- **Archive sha256** (`git archive --format=tar.gz HEAD`): `dcf13307868915909b65449ef819e5ee54132c33fabaa11507951c257f928653`
- **Native host:** MSI-1, `%TEMP%` fixtures only, packaged PowerShell 7.6.9
  (`C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.9.0_x64__8wekyb3d8bbwe\pwsh.exe`).
- **Native status:** focused PS7 smoke PASS (12/12). The full same-SHA
  shim + install + measure battery is **pending root review of this revision**;
  no completion is claimed for it here.
- **No release / no deploy / no push:** nothing was pushed, tagged, published,
  installed, or merged from this worktree.

## Static results on 9b7e438

| Check | Result |
| --- | --- |
| `node src/installer/build.mjs --check` | 6/6 ok |
| `node src/installer/cut.mjs --check` | 6/6 ok |
| `tests/installer/test_generated_installers.py` | 72 pass / 0 fail |
| `tests/shim/test_shim_windows.py` | 253 pass / 0 fail |
| `tests/install/test_install_windows.py` | 242 pass / 0 fail |

## Native PS7 smoke on 9b7e438 (PASS)

| Case | Result |
| --- | --- |
| Plain `ToArray()` + caller `@(...).Count`, empty / one / two | 0 / 1 / 2 PASS |
| Launcher in a Unicode `Prefix\bin`, `%~dp0` relative shim bind, no `GROKGOD_SHIM_PATH` | exit 0, intended shim token PASS |
| ASCII relative dir + literal `100%.ps1` shim filename | binds `100%%.ps1`, exit 0 PASS |
| Non-ASCII relative suffix (arbitrary Unicode shim filename) | generator throws, no decoy discovery PASS |

The installed-style launcher check removes `GROKGOD_SHIM_PATH`; the launcher
must resolve the exact shim from `%~dp0..\grokgod\shim\grok-shim.ps1`.

## Historical native runs (superseded, retained as history)

All runs used the same packaged PS7 7.6.9 on MSI-1 and `%TEMP%` fixtures.
`shim`/`install` are native pass/fail totals; `measure` is the full-launcher
median over 5 valid samples.

| Tree | Shim | Install | Measure median |
| --- | --- | --- | --- |
| `c3f4c3b` | 180 / 0 | 205 / 13 | 1211.0 ms |
| `c3033a0` | 180 / 0 | fatal at Test 15 Count | 1153.9 ms |
| `c9be664` | 179 / 1 | 218 / 3 | 1236.8 ms |
| `19170da` | 179 / 1 | 218 / 3 | 1242.1 ms |

- The c9/19170 three "survivor" FAILs were a **test nesting bug**, not live
  processes: `return ,@()` nested inside caller `@(f).Count` yields 1 even for
  empty. Root proved this on native PS7. 9b7e438 returns a plain `ToArray()`
  and proves 0/1/2 counts.
- The c9/19170 shim 179/1 was `Merged 2>&1 ordinary path fires the detached
  refresh`. The merged case now uses its own `GROKGOD_HOME`/stamp/`.update-check`
  so the control case's detached writer cannot erase its stale cache. Cause is
  not claimed; the final battery must show the assertion passing.
- c303 install stopped after a `StrictMode` `Count` fatal in the then-new
  survivor helper; 9b7e438 fixes the helper and its callers.

## Owned descendant and external-close evidence

- **Shared probe external close (root-run on c303):** Node -> PS7 ->
  `Get-GrokgodPwshVersion` against a fake engine spawning a 120 s stderr
  holder. Result: null version, probe 3080 ms, caller exit 4119 ms, close
  4120 ms, EOF gap 1 ms, no watchdog. Root cleaned only fixture-logged PIDs.
- **Job-object candidate ownership:** the candidate is created with
  `CREATE_SUSPENDED`, assigned to a kill-on-close job, its `Process.Handle`
  retained, then resumed. Streams are constructed before resume; job
  ownership transfers only after every reader exists; failure paths dispose
  the job/process. No CIM and no `Process.Kill(true)` tree enumeration.
- **Final same-SHA no-survivor receipts:** pending the reviewed full battery.
  Test 15/15b/15c read the mock launch-log PIDs and assert none remain alive.

## Hanging-CMD prerequisite limitation

`ps-engine-probe.cmd` documents that cmd.exe has no wait-with-timeout
primitive. A `powershell.exe` babysitter was rejected. The caller's own
watchdog (test driver, suite supervisor, or interactive user) owns a
pathological hanging `pwsh.exe` candidate. No production bound is claimed for
that case.

## Key file sha256 on 9b7e438

- `install.ps1` `0d60925a07844db739043eee6dac6e88a267555f336199f570208b08c04a7fff`
- `src/shim/grok-shim.ps1` `9ab5156598987813a6c1f6072378721f93f97797569d8f2c10627ef276ac49dd`
- `src/shim/LauncherHelpers.ps1` `7561ca91370e1c9fca605903f7631e853ae1549e56e751696bfc2a1a03976846`
- `src/shim/templates/grok.cmd.template` `f84176a9cd84a5aa01e3d041efb1b09cf38adcfb8a61d3fb368c51413c3ed389`
- `src/shim/templates/grokgod.cmd.template` `546cd2897a15f41f894e482abd92c13ee701b78703023530efac4c63adbce96e`
- `src/installer/shared/ps7-version-probe.ps1.part` `aca3cd1aed4346cfcea018cf49231f235cd3d39ec62d065514b4c267568cd914`
- `src/installer/shared/ps7-resolver.ps1.part` `c33f752906b78b3cb5851ead364c3deb279217c7dd2f0feb02c60adae5b6eff4`
- `tests/shim/test_shim_windows.ps1` `b06f018a41ea24234a3f0f8a51298ff6f2af46e7fa4f7492c1d315ddbaee241e`
- `tests/install/test_install_windows.ps1` `3b734acb5f7f45d23084e3b5b59cd7ef74dd70db385dd42890d8573778c95339`

## What changed since the root-pushed c3 baseline

1. **SAFE ARGV retained.** `setlocal DisableDelayedExpansion`, direct `%*`
   forwarding, caller CRT quote/backslash then twice CMD-metachar escaping
   with `windowsVerbatimArguments`. Native argv cases are in the shim suite.
2. **Canonical PS7 resolver/probe retained.** Shared parts compile into
   `install.ps1` and `LauncherHelpers.ps1`; the shared probe now clears stdio
   inherit flags around its own `Process.Start` and kills on an incomplete
   drain.
3. **Bounded candidate ownership.** Kill-on-close job assigned while the
   candidate is suspended; retained process handle; streams before resume;
   job transfer after readers; fail-closed pipe-inherit clearing. No CIM, no
   tree-enumeration kill fallback.
4. **Unicode launchers.** ASCII absolute shim paths bind directly (cross-drive
   safe, `%` doubled). Non-ASCII absolute paths bind a decoded ASCII
   `%~dp0`-relative suffix from `LauncherDirectory`; an unrepresentable suffix
   throws instead of falling through to discovery. The installer and fast path
   pass the real `BinDir`. Test 14 drives the installed `Prefix\bin\grok.cmd`
   with `GROKGOD_BIN` and `GROKGOD_SHIM_PATH` removed.
5. **Test contracts.** Test 16 asserts `Prefix\grokgod\bin\grokgod.exe`; Test
   15 survivor checks use recorded mock PIDs with plain-array counts; the
   merged 2>&1 case has an isolated home.
6. **Docs/guidance.** Windows Terminal guidance names `pwsh.exe`, rejects
   Windows PowerShell 5.1, and is printed after successful installs.

## History (labeled, superseded)

The sections below describe earlier checkpoints. They are retained for
provenance and do not describe 9b7e438.

### Static checkpoint (base 4e082afa)

- Code tree `6b44e471982c0443e9e4c1f12cbc6807b6ddcf23`,
  archive `94557953e6cef02dc9c01a9b9b1f8c23b82f18fc17f7a138bc3e11fc429c79d3`.
- Static only; native Windows execution was pending.
- SAFE ARGV, canonical PS7 resolver/probe, deadline changes, PS7 gate, docs.

### stderr-held EOF fail-closed (earlier follow-up)

- Both stdout and stderr drains must complete; `where.exe` uses one 5000 ms
  remaining budget.
- Static on those bytes: build 6/6, cut 6/6, generated 72/0, shim py 231/0,
  install py 219/0. Native pending at that time.

### Driver path quoting and PS7 workflow step name

- CI on `b1d9b49`: release workflow expected the old Windows PowerShell 5.1
  job step name; the driver twice-escaped the launcher path.
- Static after that follow-up: shim py 232/0, release workflow 9/9.

### Group-9 child cwd isolation (test-only)

- Group-9 child processes use an empty fixture cwd so `where.exe` cannot see
  host PSHOME/workspace `pwsh.exe`. Static shim py 233/0.

### wt3v6 native baseline (earlier tree)

- 139 pass / 8 fail on an earlier tree. Root classified the 8 as cached-notice
  exact stderr + detached refresh + prerequisite/baked-path assertions. That
  baseline does not describe 9b7e438.

## Invariants held

- No `patches/` or Rust edits, no Docker, no secrets, no live T3/PATH changes,
  no worker push/PR/merge/tag.
- Generated artifacts produced only via `node src/installer/build.mjs`.
- Root owns CI, release, live install, and push.
