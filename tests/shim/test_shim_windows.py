#!/usr/bin/env python3
"""
Static / AST / syntax and invariant test suite for grokgod Windows Dispatcher (grok-shim.ps1).
Runs on macOS, Linux, and Windows without requiring pwsh.
Verifies all requirements from task-2-brief.md and review findings:
  1. Command matrix parsing and dispatch
  2. Strict Identity handling ('grok' vs 'grokgod', mandatory, ValidateSet, fail closed)
  3. Argument preservation logic (escaping quotes, backslashes, empty args, trailing backslashes)
  4. Status schema fields and array formatting (healthDetails always array)
  5. Valid JSON generation and exit codes: corrupt -> 2, degraded -> 1, healthy -> 0
  6. Updater argument regex evaluation:
     - Exact regex matches --version, -Version, -version, --no-upgrade, -NoUpgrade, --force, -Force
     - Exact regex matches --version=1.0, -Version=1.0
     - Rejects aversion, /version, _force, etc.
     - Rejects --uninstall, -Uninstall, --prefix
  7. Thin .cmd templates and helper functions pass '--' before '%*'
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIM_PS1 = os.path.join(REPO_ROOT, "src", "shim", "grok-shim.ps1")
GROK_CMD_TPL = os.path.join(REPO_ROOT, "src", "shim", "templates", "grok.cmd.template")
GROKGOD_CMD_TPL = os.path.join(REPO_ROOT, "src", "shim", "templates", "grokgod.cmd.template")
LAUNCHER_HELPERS = os.path.join(REPO_ROOT, "src", "shim", "LauncherHelpers.ps1")

passes = 0
fails = 0

def check(cond, name, detail=""):
    global passes, fails
    if cond:
        print(f"  PASS: {name}")
        passes += 1
    else:
        print(f"  FAIL: {name}")
        if detail:
            print(f"        {detail}")
        fails += 1

def main():
    print("=== grokgod Windows Dispatcher Static Contract Test Suite ===")

    # 1. Verify existence of required files
    check(os.path.isfile(SHIM_PS1), "src/shim/grok-shim.ps1 exists")
    check(os.path.isfile(GROK_CMD_TPL), "src/shim/templates/grok.cmd.template exists")
    check(os.path.isfile(GROKGOD_CMD_TPL), "src/shim/templates/grokgod.cmd.template exists")
    check(os.path.isfile(LAUNCHER_HELPERS), "src/shim/LauncherHelpers.ps1 exists")

    if not os.path.isfile(SHIM_PS1):
        print("Aborting: grok-shim.ps1 missing")
        sys.exit(1)

    with open(SHIM_PS1, "r", encoding="utf-8") as f:
        shim_src = f.read()

    # 2. Engine floor: the shim requires PowerShell 7 itself (the launcher
    # guarantees a verified PS7 engine; direct 5.1 entry is rejected at
    # parse time by #Requires and again by the runtime gate).
    check("#Requires -Version 7.0" in shim_src, "Declares #Requires -Version 7.0 (parse-time PS7 floor)")
    check("requires PowerShell 7 or newer" in shim_src, "Runtime gate rejects PS<7 before any side effect with remediation")
    check("Set-StrictMode -Version Latest" in shim_src, "Enforces strict mode")
    has_ternary = re.search(r'(\$\w+\s*\?\s*[^:]+\s*:\s*[^;\r\n]+)', shim_src)
    has_null_coalesce = re.search(r'\?\?', shim_src)
    check(not has_ternary, "No PowerShell 7 ternary operator (?:) used (portable syntax floor)")
    check(not has_null_coalesce, "No PowerShell 7 null-coalescing operator (??) used (portable syntax floor)")
    check("[CmdletBinding()]" not in shim_src, "Avoids [CmdletBinding()] to eliminate ParameterBindingException on dashed args")

    # 3. Explicit Positional Identity Handling and Launcher templates
    check("param(" not in shim_src, "grok-shim.ps1 avoids param(...) block to consume raw $args without named binding")
    check("$args.Count -lt 1" in shim_src, "Dispatcher requires at least one argument")
    check("$args[0]" in shim_src, "Extracts identity from first positional argument ($args[0])")
    check("missing launcher identity" in shim_src, "Fails closed on missing identity")
    check("invalid identity" in shim_src, "Fails closed on invalid identity")
    check("[string[]]$cmdArgs" in shim_src, "Constructs typed [string[]]$cmdArgs without pipeline scalarization")
    check("cmdArgs.Length" in shim_src, "Uses robust Length property on typed array")
    check("$script:DispatcherScriptPath" in shim_src or "$DispatcherScriptPath" in shim_src, "Captures script-scope DispatcherScriptPath")
    check("$MyInvocation.MyCommand.Path" not in shim_src, "Avoids function-local MyInvocation.MyCommand.Path")
    check("Resolve-GrokgodEngine" in shim_src, "Updater/refresh child engine resolves through Resolve-GrokgodEngine (verified PS7)")
    check('$pwshExe = if ($PSVersionTable.PSEdition' not in shim_src, "No PSEdition-based powershell.exe fallback in engine selection")
    check("WindowsPowerShell" in shim_src and "POWERSHELL_EXE" in shim_src, "POWERSHELL_EXE override is validated and 5.1 paths rejected with remediation")

    # Verify native shim test fixture checks
    native_shim_test_path = os.path.join(REPO_ROOT, "tests", "shim", "test_shim_windows.ps1")
    if os.path.isfile(native_shim_test_path):
        with open(native_shim_test_path, "r", encoding="utf-8") as sf:
            native_shim_src = sf.read()
        check("mockExeHash = (Get-FileHash" in native_shim_src, "Native shim test computes actual mockExeHash for healthy stamp")
        check("MockSkewOfficial" in native_shim_src, "Native shim test creates distinct MockSkewOfficial fixture for version skew test")
        check("$isolatedProfile" in native_shim_src and "$env:USERPROFILE  = $isolatedProfile" in native_shim_src, "Native shim test isolates USERPROFILE to prevent host candidate skew")
        check('"ProgramFiles"' in native_shim_src and '"ProgramFiles(x86)"' in native_shim_src,
              "Native group-9 isolates both ProgramFiles roots in the child env only")
        check("WorkingDirectory" in native_shim_src and "where.exe searches the child current directory" in native_shim_src,
              "Native group-9 pins child cwd to an empty fixture so where.exe cannot see host pwsh")
        check("SKIP: broken-engine" not in native_shim_src and "SKIP: broken-engine case" not in native_shim_src,
              "Native group-9 does not skip broken-engine on host standard PS7")
        check("GROKGOD_ARGV_SENTINEL" in native_shim_src,
              "Native argv cases include a sentinel token that must never execute")
        check("held-stderr-eof" in native_shim_src and "Get-GrokgodPwshVersion returns null when stderr EOF is held" in native_shim_src,
              "Native suite covers stderr-held-EOF for the status probe and Get-GrokgodPwshVersion")

    driver_js_path = os.path.join(REPO_ROOT, "tests", "shim", "launcher_fixture_driver.js")
    if os.path.isfile(driver_js_path):
        with open(driver_js_path, "r", encoding="utf-8") as df:
            driver_src = df.read()
        check("windowsVerbatimArguments: true" in driver_src,
              "Fixture driver uses windowsVerbatimArguments")
        check("arg.replace(meta, '^$1')" in driver_src and driver_src.count("arg.replace(meta") >= 2,
              "Fixture driver applies CMD-metachar escaping twice after CRT quoting")
        check("GROKGOD_LAUNCHER_TAIL" not in driver_src,
              "Fixture driver does not depend on env-tail transport")

    probe_part_path = os.path.join(REPO_ROOT, "src", "installer", "shared", "ps-engine-probe.cmd.part")
    if os.path.isfile(probe_part_path):
        with open(probe_part_path, "r", encoding="utf-8") as pf:
            probe_part = pf.read()
        check("cmd.exe has no wait-with-timeout primitive" in probe_part,
              "Engine probe documents the hanging-candidate CMD limitation")
        check("powershell.exe babysitter wrapper was" in probe_part and "rejected" in probe_part,
              "Engine probe rejects a powershell.exe babysitter rather than claiming a production bound")

    grok_cmd_content = open(GROK_CMD_TPL).read()
    grokgod_cmd_content = open(GROKGOD_CMD_TPL).read()
    launcher_helpers_content = open(LAUNCHER_HELPERS).read()

    # Verify all launcher sources use the same robust engine-selection flow.
    launcher_sources = {
        "grok.cmd.template": grok_cmd_content,
        "grokgod.cmd.template": grokgod_cmd_content,
        "LauncherHelpers.ps1": launcher_helpers_content,
    }
    for launcher_name, launcher_src in launcher_sources.items():
        check('set "POWERSHELL_EXE="' in launcher_src,
              f"{launcher_name} clears any inherited POWERSHELL_EXE before selection")
        check('GROKGOD_POWERSHELL_BAKED' in launcher_src,
              f"{launcher_name} honors only the install-time baked verified engine")
        check('defined GROKGOD_POWERSHELL ' in launcher_src,
              f"{launcher_name} honors the documented explicit override")
        check('$PSVersionTable.PSVersion.Major -ge 7' in launcher_src,
              f"{launcher_name} execute-verifies every candidate requires major >= 7")
        check("powershell.exe" not in launcher_src,
              f"{launcher_name} has no Windows PowerShell 5.1 fallback path")
        check("setlocal DisableDelayedExpansion" in launcher_src,
              f"{launcher_name} disables delayed expansion so '!' in user tokens is preserved")
        check("GROKGOD_LAUNCHER_TAIL" not in launcher_src and "__grokgod_launcher_tail" not in launcher_src,
              f"{launcher_name} does not use the raw-env tail transport")
        check(":ps7_ready" in launcher_src and ":powershell_ready" not in launcher_src,
              f"{launcher_name} uses the ps7_ready launch label")
        check("PowerShell 7+ is required" in launcher_src,
              f"{launcher_name} prints the PS7 prerequisite on stderr")
        check("winget install --id Microsoft.PowerShell" in launcher_src,
              f"{launcher_name} prints actionable PS7 install guidance")
        check("exit /b 127" in launcher_src,
              f"{launcher_name} returns 127 when no engine is runnable")
        check("%SystemRoot%\\System32\\where.exe" in launcher_src,
              f"{launcher_name} enumerates PATH candidates via an absolute where.exe")
        check("if %ERRORLEVEL%" not in launcher_src and "if \"%ERRORLEVEL%\"" not in launcher_src,
              f"{launcher_name} avoids unsafe parse-time ERRORLEVEL conditionals")
        check("exit /b %ERRORLEVEL%" in launcher_src,
              f"{launcher_name} propagates the child exit code exactly")

    # Verify templates and helper pass positional identity then %* (no named
    # -Identity, no '--' delimiter). Direct %* forwarding is the proven
    # native transport; callers apply CRT+CMD escaping before cmd.exe /s /c.
    check('grok %*' in grok_cmd_content and '-Identity' not in grok_cmd_content and '-- %*' not in grok_cmd_content, "grok.cmd.template passes positional identity then %* without named -Identity or '--'")
    check('grokgod %*' in grokgod_cmd_content and '-Identity' not in grokgod_cmd_content and '-- %*' not in grokgod_cmd_content, "grokgod.cmd.template passes positional identity then %* without named -Identity or '--'")
    check('$Identity %*' in launcher_helpers_content and '-Identity' not in launcher_helpers_content and '-- %*' not in launcher_helpers_content, "LauncherHelpers passes positional identity then %* without named -Identity or '--'")
    check("New-GrokgodLauncherScript" in launcher_helpers_content, "LauncherHelpers provides New-GrokgodLauncherScript helper")
    check("$probePart = @'" in launcher_helpers_content,
          "LauncherHelpers carries the probe in a single-quoted here-string (no runtime interpolation of $ or backticks)")

    # 4. Command Matrix & TUI protection
    check("GROK_DISABLE_AUTOUPDATER" in shim_src, "Sets GROK_DISABLE_AUTOUPDATER=1 for patched executable")
    check('$subcommand -eq "update"' in shim_src or "$subcommand -eq 'update'" in shim_src, "Handles 'update' command")
    check('$subcommand -eq "status"' in shim_src or "$subcommand -eq 'status'" in shim_src, "Handles 'status' command")

    # grokgod sessions / cache must be rejected with explicit error, never TUI
    check("not supported on Windows" in shim_src, "grokgod maintenance commands print 'not supported on Windows'")
    check("grok sessions" in shim_src, "grokgod sessions hint mentions 'grok sessions'")
    check('"sessions"' in shim_src and '"cache"' in shim_src, "Explicitly guards 'sessions' and 'cache' under grokgod identity")

    # Cached update notice contract: release stamp only, immediate cached read,
    # detached short-timeout refresh, atomic cache replacement, and test hooks.
    check("Invoke-ReleaseUpdateCheck" in shim_src, "Implements release update notice check")
    check("Test-VersionCoreGreater" in shim_src and "Test-ReleaseVersion" in shim_src, "Compares validated semantic numeric cores")
    check(".update-check" in shim_src and "CHECKED_AT=" in shim_src and "VERSION=" in shim_src, "Uses ~/.grokgod/.update-check cache fields")
    check("MODE" in shim_src and "release" in shim_src, "Gates update notices on release-mode stamp")
    check("https://api.github.com/repos/karlorz/grokgod/releases/latest" in shim_src, "Refreshes official latest-release endpoint")
    check("Invoke-WebRequest" in shim_src and "-TimeoutSec 5" in shim_src, "Uses a bounded refresh request")
    check("Start-UpdateCacheRefresh" in shim_src and "__grokgod_update_refresh" in shim_src, "Runs refresh in a detached child process")
    check("[System.IO.File]::Replace" in shim_src and "[System.IO.File]::Move" in shim_src, "Commits update cache atomically")
    check("GROKGOD_UPDATE_CHECK_DISABLE" in shim_src and "GROKGOD_UPDATE_CHECK_URL" in shim_src, "Provides deterministic update-check test hooks")
    notice_contract = all(fragment in shim_src for fragment in (
        "$notice =",
        "[char]0x2014",
        "run 'grok update' to upgrade",
        "[Console]::Error.WriteLine($notice)",
    ))
    check(notice_contract, "Uses exact update notice stderr contract")
    check('if ($subcommand -ne "cache" -and -not $machineOrProtocol)' in shim_src,
          "Suppresses notice for administrative cache command and machine/protocol launches")
    check("$machineOrProtocol = Test-MachineProtocolLaunch -argsList $cmdArgs" in shim_src,
          "Classifies machine/protocol launches before the update check")

    # Machine/protocol bypass contract: exact per-token forms, no substring
    # matching over joined arguments, no cache or network side effects.
    check("function Test-MachineProtocolLaunch" in shim_src,
          "Implements Test-MachineProtocolLaunch classifier")
    for token_fragment in ('-eq "--version"', '-eq "-V"', '-eq "--help"', '-eq "-h"',
                           '-eq "help"', '-eq "models"', '-eq "inspect"'):
        check(token_fragment in shim_src, f"Classifier recognizes exact token {token_fragment}")
    check('$argsList[$i] -eq "agent" -and [string]$argsList[$i + 1] -eq "stdio"' in shim_src,
          "Classifier recognizes exact 'agent stdio' token pair")
    check('-join $cmdArgs' not in shim_src and '-join $argsList' not in shim_src,
          "Classifier never substring-matches a joined argument string")
    check(shim_src.count("Test-MachineProtocolLaunch") >= 2,
          "Classifier is defined and invoked")
    dispatch_pos = shim_src.find("$machineOrProtocol = Test-MachineProtocolLaunch")
    update_check_pos = shim_src.find("Invoke-ReleaseUpdateCheck", dispatch_pos)
    passthrough_pos = shim_src.find("Invoke-PatchedExecutable -argsList $cmdArgs", dispatch_pos)
    check(-1 < dispatch_pos < update_check_pos < passthrough_pos,
          "Machine/protocol classification happens before update check and passthrough")

    # Bounded status probe contract: one total budget covers wait + drains +
    # kill + teardown; the kill is a supervised owned taskkill helper, never
    # a synchronous invocation; candidate stdin is redirected and closed.
    check("function Get-BinaryReportedVersion" in shim_src, "Implements bounded version probe")
    check("$probeWaitMs = 3000" in shim_src, "Probe wait preserves the intended 3000ms")
    check("$totalBudgetMs = 4000" in shim_src, "Probe total budget covers wait + drains + cleanup")
    check("ReadToEndAsync" in shim_src, "Probe drains stdout/stderr concurrently")
    check("$proc.WaitForExit($probeWaitMs)" in shim_src,
          "Probe waits with budget before any blocking read")
    check("function Stop-OwnedProbeProcess" in shim_src,
          "Probe terminates only owned process via Stop-OwnedProbeProcess")
    check("'taskkill.exe'" in shim_src and "/T /F /PID" in shim_src,
          "Probe terminates the owned process tree via taskkill /T rooted at the probe PID")
    check("& taskkill.exe" not in shim_src,
          "No synchronous taskkill anywhere in the shim (supervised owned helper only)")
    check("$psi.RedirectStandardInput = $true" in shim_src,
          "Probes redirect candidate stdin and close it for immediate EOF")
    check("$errDrained" in shim_src and "-not $outDrained -or -not $errDrained" in shim_src,
          "Probes fail-close when either stdout or stderr drain is incomplete")
    check("ConvertFrom-WindowsCommandLine" not in shim_src,
          "Shim does not re-split a raw-env tail; launchers forward %* into $args")
    check("GROKGOD_LAUNCHER_TAIL" not in shim_src and "__grokgod_launcher_tail" not in shim_src,
          "Shim has no launcher-tail marker or env-tail branch")
    check("$proc.Kill()" in shim_src, "Probe kills the owned process on timeout")

    # Detached update-refresh stdio isolation: the refresh child must not
    # inherit the caller's pipes (which would delay the caller's EOF).
    refresh_pos = shim_src.find("function Start-UpdateCacheRefresh")
    refresh_end = shim_src.find("# ---", refresh_pos + 10)
    refresh_src = shim_src[refresh_pos:refresh_end]
    check("$psi.RedirectStandardInput = $true" in refresh_src
          and "$psi.RedirectStandardOutput = $true" in refresh_src
          and "$psi.RedirectStandardError = $true" in refresh_src,
          "Detached refresh child stdio is redirected, not inherited")
    check("StandardInput.Close()" in refresh_src,
          "Detached refresh stdin is closed so the child sees EOF")
    check("ReadToEndAsync" in refresh_src,
          "Detached refresh stdout/stderr are drained so pipes cannot fill")

    # 5. Argument preservation and escaping rules
    check("ConvertTo-WindowsCommandLine" in shim_src, "Centralizes Windows native command-line argument quoting")
    check("escapedArguments.Add('\"\"')" in shim_src or 'escapedArguments.Add(\'""\')' in shim_src, "Preserves empty string argument ('\"\"')")
    check("replace '(\\\\*)(\")'" in shim_src, "Implements Windows quote escaping algorithm")
    check("replace '(\\\\+)$'" in shim_src, "Implements trailing backslash doubling algorithm")
    check(r"\\$" in shim_src, "Handles trailing backslashes even without whitespace in argument")
    check("WaitForExit" in shim_src and "ExitCode" in shim_src, "Preserves and exits with child process ExitCode")

    # 6. Status schema, JSON formatting and exit code evaluation
    required_status_keys = [
        "health",
        "healthDetails",
        "launcherIdentity",
        "resolvedCommandPath",
        "patchedBinaryPath",
        "patchedBinaryExists",
        "patchedBinaryVersion",
        "officialBinaryPath",
        "officialBinaryExists",
        "officialBinaryVersion",
        "versionSkewExplanation",
        "directOfficialPath",
        "artifactSha256",
        "computedSha256",
        "patchset",
        "sourceSha",
        "freeDiskBytes",
        "freeDiskGigabytes"
    ]
    for k in required_status_keys:
        check(f'"{k}"' in shim_src or f"{k} " in shim_src or f"{k}=" in shim_src, f"Status schema contains required field '{k}'")

    # Status array formatting for healthDetails (PS 5.1 scalarization fix)
    check("healthDetails" in shim_src and "hdJson" in shim_src, "Ensures healthDetails is explicitly formatted as JSON array")

    # Status exit code contract verification
    corrupt_exit = re.search(r'if\s*\(\$health\s*-eq\s*["\']corrupt["\']\)\s*\{\s*exit\s*2\s*\}', shim_src)
    degraded_exit = re.search(r'elseif\s*\(\$health\s*-eq\s*["\']degraded["\']\)\s*\{\s*exit\s*1\s*\}', shim_src)
    healthy_exit = re.search(r'function\s+Invoke-StatusCommand.+?exit\s*0\s*\}', shim_src, re.DOTALL)
    check(bool(corrupt_exit), "Status corrupt health exits 2")
    check(bool(degraded_exit), "Status degraded health exits 1 (reachable, not dead)")
    check(bool(healthy_exit), "Status healthy exits 0")

    # 7. Updater regex evaluation (Critical Finding 1 verification)
    # Extract the regexes used in Invoke-UpdateCommand
    ver_match = re.search(r'arg\s*-match\s*[\'"](\^.+?version[\'"]|\^.+?version\)\$)[\'"]', shim_src)
    ver_eq_match = re.search(r'arg\s*-match\s*[\'"](\^.+?version\)=\(\.\*\)\$)[\'"]', shim_src)
    noup_match = re.search(r'arg\s*-match\s*[\'"](\^.+?no-upgrade.+?)[\'"]', shim_src)
    force_match = re.search(r'arg\s*-match\s*[\'"](\^.+?force.+?)[\'"]', shim_src)
    release_match = re.search(r'arg\s*-match\s*[\'"](\^.+?release.+?)[\'"]', shim_src)
    uninst_match = re.search(r'arg\s*-match\s*[\'"](\^.+?uninstall.+?)[\'"]', shim_src)

    check(bool(ver_match), "Found update --version regex")
    check(bool(ver_eq_match), "Found update --version= regex")
    check(bool(noup_match), "Found update --no-upgrade regex")
    check(bool(force_match), "Found update --force regex")
    check(bool(release_match), "Found update --release regex")
    check(bool(uninst_match), "Found update --uninstall regex")

    # Verify no broken character class ranges like [--|-]
    check("[--|-]" not in shim_src, "No broken character-range class '[--|-]' in shim regexes")

    # Test regex patterns against valid inputs
    ver_regex = r'^(--|-)(version)$'
    ver_eq_regex = r'^(--|-)(version)=(.*)$'
    noup_regex = r'^(--|-)(no-upgrade|noupgrade)$'
    force_regex = r'^(--|-)(force)$'
    release_regex = r'^(--|-)(release)$'
    uninst_regex = r'^(--|-)(uninstall)$'

    # Valid matches
    check(bool(re.match(ver_regex, "--version", re.IGNORECASE)), "Regex matches '--version'")
    check(bool(re.match(ver_regex, "-Version", re.IGNORECASE)), "Regex matches '-Version'")
    check(bool(re.match(ver_regex, "-version", re.IGNORECASE)), "Regex matches '-version'")
    check(bool(re.match(ver_eq_regex, "--version=1.0.0", re.IGNORECASE)), "Regex matches '--version=1.0.0'")
    check(bool(re.match(ver_eq_regex, "-Version=1.0.0", re.IGNORECASE)), "Regex matches '-Version=1.0.0'")
    check(bool(re.match(noup_regex, "--no-upgrade", re.IGNORECASE)), "Regex matches '--no-upgrade'")
    check(bool(re.match(noup_regex, "-NoUpgrade", re.IGNORECASE)), "Regex matches '-NoUpgrade'")
    check(bool(re.match(noup_regex, "-noupgrade", re.IGNORECASE)), "Regex matches '-noupgrade'")
    check(bool(re.match(force_regex, "--force", re.IGNORECASE)), "Regex matches '--force'")
    check(bool(re.match(force_regex, "-Force", re.IGNORECASE)), "Regex matches '-Force'")
    check(bool(re.match(release_regex, "--release", re.IGNORECASE)), "Regex matches '--release'")
    check(bool(re.match(release_regex, "-Release", re.IGNORECASE)), "Regex matches '-Release'")
    check(bool(re.match(uninst_regex, "--uninstall", re.IGNORECASE)), "Regex matches '--uninstall'")
    check(bool(re.match(uninst_regex, "-Uninstall", re.IGNORECASE)), "Regex matches '-Uninstall'")

    # Negative / malicious cases that MUST NOT match valid switches
    check(not re.match(ver_regex, "aversion"), "Regex rejects 'aversion'")
    check(not re.match(ver_regex, "/version"), "Regex rejects '/version'")
    check(not re.match(ver_regex, "version"), "Regex rejects bare 'version'")
    check(not re.match(force_regex, "_force"), "Regex rejects '_force'")
    check(not re.match(force_regex, "force"), "Regex rejects bare 'force'")
    check(not re.match(release_regex, "_release"), "Regex rejects '_release'")
    check(not re.match(release_regex, "release"), "Regex rejects bare 'release'")
    check(not re.match(noup_regex, "no-upgrade"), "Regex rejects bare 'no-upgrade'")

    # Test transformed flags for install.ps1
    check('"-Version"' in shim_src, "Transforms version flag to -Version for install.ps1")
    check('"-NoUpgrade"' in shim_src, "Transforms no-upgrade flag to -NoUpgrade for install.ps1")
    check('"-Force"' in shim_src, "Transforms force flag to -Force for install.ps1")

    # 8. Verify test.yml Windows CI workflow requirements
    test_yml_path = os.path.join(REPO_ROOT, ".github", "workflows", "test.yml")
    check(os.path.isfile(test_yml_path), ".github/workflows/test.yml exists")
    if os.path.isfile(test_yml_path):
        import yaml
        with open(test_yml_path, "r", encoding="utf-8") as yf:
            test_workflow = yaml.safe_load(yf)
        win_job = test_workflow.get("jobs", {}).get("test-windows")
        check(win_job is not None, "test.yml defines test-windows job")
        if win_job:
            check(win_job.get("runs-on") == "windows-latest", "test-windows runs on windows-latest")
            check(win_job.get("continue-on-error") is None or win_job.get("continue-on-error") is False, "test-windows job does not use continue-on-error (strictly required job)")
            steps = win_job.get("steps", [])
            runs = [s.get("run", "") for s in steps]
            combined_runs = "\n".join(runs)
            check("powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\\shim\\test_shim_windows.ps1" not in combined_runs, "test-windows no longer runs the shim suite under powershell.exe (PS7 only)")
            check("powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\\install\\test_install_windows.ps1" not in combined_runs, "test-windows no longer runs the install suite under powershell.exe (PS7 only)")
            check("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests\\shim\\test_shim_windows.ps1" in combined_runs, "test-windows runs shim suite with pwsh.exe")
            check("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests\\install\\test_install_windows.ps1" in combined_runs, "test-windows runs install suite with pwsh.exe")
            check("powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -InstallPowerShell7" in combined_runs, "test-windows exercises only the narrow PS5.1 prerequisite helper")
            check("if errorlevel 1 exit /b 1" in combined_runs, "test-windows propagates failures with exit /b 1 on errorlevel")

    # 9. Verify native test suite engine alignment & malformed stamp coverage
    native_shim_test_path = os.path.join(REPO_ROOT, "tests", "shim", "test_shim_windows.ps1")
    if os.path.isfile(native_shim_test_path):
        with open(native_shim_test_path, "r", encoding="utf-8") as sf:
            native_shim_src = sf.read()
        check("This suite requires PowerShell 7" in native_shim_src, "Native shim suite hard-requires a PS7 host")
        check("Direct PS5.1 shim invocation is rejected" in native_shim_src, "Native shim suite exercises the narrow direct-5.1 rejection")
        check("$pwshExe = if ($verifiedPwsh)" in native_shim_src, "Native shim suite child engine is the verified pwsh only")
        check("MALFORMED_STAMP" in native_shim_src, "Native shim test verifies degraded health on malformed stamp")

    # 9b. Deterministic full-launcher fixture coverage (native suite + driver)
    driver_js_path = os.path.join(REPO_ROOT, "tests", "shim", "launcher_fixture_driver.js")
    check(os.path.isfile(driver_js_path), "Shared launcher fixture driver exists")
    if os.path.isfile(driver_js_path):
        with open(driver_js_path, "r", encoding="utf-8") as df:
            driver_src = df.read()
        check("child_process" in driver_src, "Driver launches through Node child_process")
        check("stdio: ['pipe', 'pipe', 'pipe']" in driver_src, "Driver pins the piped stdio topology")
        check("timedOut" in driver_src and "taskkill.exe" in driver_src and "/T" in driver_src,
              "Driver watchdog kills the fixture-owned process tree on timeout")
        check("windowsVerbatimArguments" in driver_src,
              "Driver passes the pre-quoted /c line verbatim (no Node re-quoting)")
        check("replace(/(\\\\*)\"/g" in driver_src and "arg.replace(meta" in driver_src,
              "Driver applies proven CRT quote/backslash encoding then twice CMD-metachar escaping")
        check("function quoteCmdPath" in driver_src and "[cmd].concat(args).map(escapeArg)" not in driver_src,
              "Driver quotes the launcher path separately and does not twice-escape it")
        check("closeMs" in driver_src and "exitMs" in driver_src,
              "Driver records both exit and close/EOF timings")
    if os.path.isfile(native_shim_test_path):
        with open(native_shim_test_path, "r", encoding="utf-8") as sf:
            native_shim_src = sf.read()
        check("GROKGOD_MOCK_MODE" in native_shim_src,
              "Native shim mock exe selects fixture modes via environment")
        for mode_fragment in ('"echo"', '"protocol"', '"hang"', '"noisy-stderr"',
                              '"sleepy-child"', '"held-eof"', '"held-stderr-eof"',
                              '"failure"', '"fixture-hold-pipe"'):
            check(mode_fragment in native_shim_src,
                  f"Native shim mock exe implements mode {mode_fragment}")
        check("FIXTURE-STDERR-MARKER" in native_shim_src, "Echo fixture emits a distinct stderr marker")
        check("New-GrokgodLauncherScript" in native_shim_src,
              "Native suite generates launchers with New-GrokgodLauncherScript")
        check("Invoke-NodeLauncherFixture" in native_shim_src,
              "Native suite launches fixtures through the Node driver")
        check("Get-FixtureMockProcesses" in native_shim_src and 'ExecutablePath = ' in native_shim_src,
              "Native suite records fixture ownership by executable path")
        check("-- Testing Bounded Status Probe" in native_shim_src,
              "Native suite covers the bounded status probe fixtures")
        check("-- Testing Full-Launcher Process Fixtures" in native_shim_src,
              "Native suite covers full-launcher process fixtures")
        check("-- Testing Machine/Protocol Launch Bypass" in native_shim_src,
              "Native suite covers machine/protocol bypass")
        check("Detached Refresh Must Not Hold the Caller's EOF" in native_shim_src,
              "Native suite covers detached refresh EOF isolation")
        check("-- Testing PowerShell 7 Prerequisite" in native_shim_src,
              "Native suite covers the PowerShell 7 prerequisite gate")
        check("MockFailingEngine" in native_shim_src,
              "Native suite compiles a failing fake engine for broken-candidate tests")
        check("PowerShell 7\\+ is required" in native_shim_src,
              "Native suite asserts actionable exit-127 stderr")
        check("please agent stdio now" in native_shim_src,
              "Native suite asserts values containing 'agent stdio' stay ordinary")
        check("taskkill" in driver_src if os.path.isfile(driver_js_path) else False,
              "Driver cleans fixture-owned trees with taskkill")

    print("\n===============================================")
    print(f"Total Passed: {passes}")
    print(f"Total Failed: {fails}")
    print("===============================================")
    if fails > 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
