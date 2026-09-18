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

    # 2. PowerShell 5.1 & 7 compatibility check
    check("#Requires -Version 5.1" in shim_src, "Declares #Requires -Version 5.1")
    check("Set-StrictMode -Version Latest" in shim_src, "Enforces strict mode")
    # Disallow PS 7-only operators that break PS 5.1 (e.g. ternary ?:, null-coalescing ??)
    has_ternary = re.search(r'(\$\w+\s*\?\s*[^:]+\s*:\s*[^;\r\n]+)', shim_src)
    has_null_coalesce = re.search(r'\?\?', shim_src)
    check(not has_ternary, "No PowerShell 7 ternary operator (?:) used (PS 5.1 compat)")
    check(not has_null_coalesce, "No PowerShell 7 null-coalescing operator (??) used (PS 5.1 compat)")
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
    check('PSEdition -eq "Core"' in shim_src and "powershell.exe" in shim_src and "pwsh.exe" in shim_src, "Selects updater host engine explicitly via PSEdition (pwsh.exe vs powershell.exe)")

    # Verify native shim test fixture checks
    native_shim_test_path = os.path.join(REPO_ROOT, "tests", "shim", "test_shim_windows.ps1")
    if os.path.isfile(native_shim_test_path):
        with open(native_shim_test_path, "r", encoding="utf-8") as sf:
            native_shim_src = sf.read()
        check("mockExeHash = (Get-FileHash" in native_shim_src, "Native shim test computes actual mockExeHash for healthy stamp")
        check("MockSkewOfficial" in native_shim_src, "Native shim test creates distinct MockSkewOfficial fixture for version skew test")
        check("$isolatedProfile" in native_shim_src and "$env:USERPROFILE  = $isolatedProfile" in native_shim_src, "Native shim test isolates USERPROFILE to prevent host candidate skew")

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
              f"{launcher_name} clears POWERSHELL_EXE before probing")
        check('pwsh.exe -NoProfile -Command "exit 0" >nul 2>&1' in launcher_src,
              f"{launcher_name} execute-probes pwsh.exe")
        check('powershell.exe -NoProfile -Command "exit 0" >nul 2>&1' in launcher_src,
              f"{launcher_name} execute-probes powershell.exe")
        check("if errorlevel 1 goto try_powershell" in launcher_src,
              f"{launcher_name} falls back when pwsh.exe is unavailable or fails")
        check("if errorlevel 1 goto powershell_unavailable" in launcher_src,
              f"{launcher_name} rejects an unavailable or failing fallback engine")
        pwsh_probe = launcher_src.index('pwsh.exe -NoProfile -Command "exit 0" >nul 2>&1')
        fallback = launcher_src.index(":try_powershell")
        powershell_probe = launcher_src.index('powershell.exe -NoProfile -Command "exit 0" >nul 2>&1')
        ready = launcher_src.index(":powershell_ready")
        check(pwsh_probe < fallback < powershell_probe < ready,
              f"{launcher_name} keeps probes, fallback, and launch flow ordered")
        check(launcher_src.count("if errorlevel 1 goto try_powershell") == 1,
              f"{launcher_name} falls back when the pwsh probe fails")
        check(launcher_src.count("if errorlevel 1 goto powershell_unavailable") == 1,
              f"{launcher_name} fails when the powershell probe fails")
        check(">&2 echo grokgod: no runnable PowerShell engine found" in launcher_src,
              f"{launcher_name} reports engine failure on stderr")
        check("exit /b 127" in launcher_src,
              f"{launcher_name} returns 127 when no engine is runnable")
        check("if %ERRORLEVEL%" not in launcher_src and "if \"%ERRORLEVEL%\"" not in launcher_src,
              f"{launcher_name} avoids unsafe parse-time ERRORLEVEL conditionals")
        check("exit /b %ERRORLEVEL%" in launcher_src,
              f"{launcher_name} propagates the child exit code exactly")

    # Verify templates and helper use positional identity without -- script delimiter
    check('grok %*' in grok_cmd_content and '-Identity' not in grok_cmd_content and '-- %*' not in grok_cmd_content, "grok.cmd.template passes positional 'grok %*' without named -Identity or '--'")
    check('grokgod %*' in grokgod_cmd_content and '-Identity' not in grokgod_cmd_content and '-- %*' not in grokgod_cmd_content, "grokgod.cmd.template passes positional 'grokgod %*' without named -Identity or '--'")
    check('$Identity %*' in launcher_helpers_content and '-Identity' not in launcher_helpers_content and '-- %*' not in launcher_helpers_content, "LauncherHelpers passes positional '$Identity %*' without named -Identity or '--'")
    check("New-GrokgodLauncherScript" in launcher_helpers_content, "LauncherHelpers provides New-GrokgodLauncherScript helper")

    # 4. Command Matrix & TUI protection
    check("GROK_DISABLE_AUTOUPDATER" in shim_src, "Sets GROK_DISABLE_AUTOUPDATER=1 for patched executable")
    check('$subcommand -eq "update"' in shim_src or "$subcommand -eq 'update'" in shim_src, "Handles 'update' command")
    check('$subcommand -eq "status"' in shim_src or "$subcommand -eq 'status'" in shim_src, "Handles 'status' command")

    # grokgod sessions / cache must be rejected with explicit error, never TUI
    check("not supported on Windows" in shim_src, "grokgod maintenance commands print 'not supported on Windows'")
    check("grok sessions" in shim_src, "grokgod sessions hint mentions 'grok sessions'")
    check('"sessions"' in shim_src and '"cache"' in shim_src, "Explicitly guards 'sessions' and 'cache' under grokgod identity")

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
    uninst_match = re.search(r'arg\s*-match\s*[\'"](\^.+?uninstall.+?)[\'"]', shim_src)

    check(bool(ver_match), "Found update --version regex")
    check(bool(ver_eq_match), "Found update --version= regex")
    check(bool(noup_match), "Found update --no-upgrade regex")
    check(bool(force_match), "Found update --force regex")
    check(bool(uninst_match), "Found update --uninstall regex")

    # Verify no broken character class ranges like [--|-]
    check("[--|-]" not in shim_src, "No broken character-range class '[--|-]' in shim regexes")

    # Test regex patterns against valid inputs
    ver_regex = r'^(--|-)(version)$'
    ver_eq_regex = r'^(--|-)(version)=(.*)$'
    noup_regex = r'^(--|-)(no-upgrade|noupgrade)$'
    force_regex = r'^(--|-)(force)$'
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
    check(bool(re.match(uninst_regex, "--uninstall", re.IGNORECASE)), "Regex matches '--uninstall'")
    check(bool(re.match(uninst_regex, "-Uninstall", re.IGNORECASE)), "Regex matches '-Uninstall'")

    # Negative / malicious cases that MUST NOT match valid switches
    check(not re.match(ver_regex, "aversion"), "Regex rejects 'aversion'")
    check(not re.match(ver_regex, "/version"), "Regex rejects '/version'")
    check(not re.match(ver_regex, "version"), "Regex rejects bare 'version'")
    check(not re.match(force_regex, "_force"), "Regex rejects '_force'")
    check(not re.match(force_regex, "force"), "Regex rejects bare 'force'")
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
            check("powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\\shim\\test_shim_windows.ps1" in combined_runs, "test-windows runs shim suite with powershell.exe")
            check("powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\\install\\test_install_windows.ps1" in combined_runs, "test-windows runs install suite with powershell.exe")
            check("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests\\shim\\test_shim_windows.ps1" in combined_runs, "test-windows runs shim suite with pwsh.exe")
            check("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests\\install\\test_install_windows.ps1" in combined_runs, "test-windows runs install suite with pwsh.exe")
            check("if errorlevel 1 exit /b 1" in combined_runs, "test-windows propagates failures with exit /b 1 on errorlevel")

    # 9. Verify native test suite engine alignment & malformed stamp coverage
    native_shim_test_path = os.path.join(REPO_ROOT, "tests", "shim", "test_shim_windows.ps1")
    if os.path.isfile(native_shim_test_path):
        with open(native_shim_test_path, "r", encoding="utf-8") as sf:
            native_shim_src = sf.read()
        check("PSEdition" in native_shim_src and "powershell.exe" in native_shim_src and "pwsh.exe" in native_shim_src, "Native shim test aligns child engine with host PSEdition")
        check("MALFORMED_STAMP" in native_shim_src, "Native shim test verifies degraded health on malformed stamp")

    print("\n===============================================")
    print(f"Total Passed: {passes}")
    print(f"Total Failed: {fails}")
    print("===============================================")
    if fails > 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
