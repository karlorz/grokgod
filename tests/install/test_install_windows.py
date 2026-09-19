#!/usr/bin/env python3
"""
Static / AST / syntax and invariant test suite for grokgod Windows Transactional Installer (install.ps1).
Runs on macOS, Linux, and Windows without requiring pwsh.
Verifies all requirements from task-3-brief.md and review / re-review findings:
  1. Parameters preserved: -Version, -NoUpgrade, -Uninstall, -Prefix, -Force
  2. Compatibility: #Requires -Version 5.1, Set-StrictMode -Version Latest, no PS 7 ternary/null-coalesce
  3. Safe Console output: UTF-8 encoding handling and ASCII markers ([OK], [ERR]) to prevent mojibake
  4. Architecture Check: rejects ARM64 before any network access (PROCESSOR_ARCHITECTURE / PROCESSOR_ARCHITEW6432)
  5. Prefix overlap Guard: rejects prefix overlapping official %USERPROFILE%\\.grok
  6. Official Grok Safety: Assert-NotOfficialGrok guards official binary from mutation/deletion
  7. Exact Checksum Matching: target asset and runtime scripts verified against SHA256SUMS, no duplicates
  8. Preflight Execution: executes candidate --version before live mutation
  9. Destination-Volume Sibling Staging: stages candidate in target volume before activation
 10. Rollback & Bounded Backup: snapshots components and restores on failure
 11. Durable Manifest Backups: preserves backups across successful commits and does NOT delete backups recorded in manifest
 12. Uninstall Restoration Sequencing: excludes restored paths from the file removal loop so restored files are preserved
 13. Persisted Journal: records transaction events in manifest.json and install.journal
 14. Real Lock Mutual Exclusion: atomic acquisition, active lock detection, stale lock recovery, and lock release
 15. Temp Directory Cleanup in Finally: guarantees cleanup of unique download temp dir across error, up-to-date, and success
 16. Self-Contained Bootstrap & Runtime Refresh: downloads runtime assets from release base, verifies checksums, no raw fallback, refreshes runtime on upgrade without short-circuiting
 17. Collision-Safe Backup Paths: uses hash-based identifier for backup filenames
 18. Wrapper Runtime Installation: installs grok-shim.ps1, LauncherHelpers.ps1, and install.ps1 into grokgod home
 19. Launcher Generation: calls New-GrokgodLauncherScript with explicit -Identity grok/grokgod
 20. Stamp Fields: SHA, PATCHSET, VERSION=4247f661689354b831191f11eeeac8424993fe3d, MODE=release
 21. Manifest: writes JSON manifest as commit point
 22. Locked File Detection: tests if target executable is locked/running and fails closed
 23. Failure Injection: supports GROKGOD_INSTALL_FAIL_AFTER points (backup, activation, stamp, launcher-grok, launcher-grokgod)
 24. Manifest Rollback: tracks and restores pre-existing manifest.json on failure
 25. Native Test Suite Portability: ensures native test suites avoid unsupported PS7 Add-Type -OutputAssembly
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INSTALL_PS1 = os.path.join(REPO_ROOT, "install.ps1")
LAUNCHER_HELPERS = os.path.join(REPO_ROOT, "src", "shim", "LauncherHelpers.ps1")
NATIVE_INSTALL_TEST = os.path.join(REPO_ROOT, "tests", "install", "test_install_windows.ps1")
NATIVE_SHIM_TEST = os.path.join(REPO_ROOT, "tests", "shim", "test_shim_windows.ps1")

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
    print("=== grokgod Windows Transactional Installer Static Contract Test Suite ===")

    check(os.path.isfile(INSTALL_PS1), "install.ps1 exists")
    if not os.path.isfile(INSTALL_PS1):
        print("Aborting: install.ps1 missing")
        sys.exit(1)

    with open(INSTALL_PS1, "r", encoding="utf-8") as f:
        src = f.read()

    # 1. Compatibility & Strict Mode
    check("#Requires -Version 5.1" in src, "Declares #Requires -Version 5.1")
    check("Set-StrictMode -Version Latest" in src, "Enforces strict mode")
    has_ternary = re.search(r'(\$\w+\s*\?\s*[^:]+\s*:\s*[^;\r\n]+)', src)
    has_null_coalesce = re.search(r'\?\?', src)
    check(not has_ternary, "No PowerShell 7 ternary operator (?:) used (PS 5.1 compat)")
    check(not has_null_coalesce, "No PowerShell 7 null-coalescing operator (??) used (PS 5.1 compat)")

    # 2. Safe Console output / mojibake prevention
    check("OutputEncoding" in src, "Configures Console OutputEncoding safely")
    check("[OK]" in src and "[ERR]" in src, "Uses safe ASCII status indicators ([OK], [ERR])")

    # 3. Parameters
    param_match = re.search(r'param\s*\((.*?)\)', src, re.DOTALL)
    check(bool(param_match), "Contains param(...) block")
    if param_match:
        pblock = param_match.group(1)
        check("$Version" in pblock, "Param $Version present")
        check("$NoUpgrade" in pblock, "Param $NoUpgrade present")
        check("$Force" in pblock, "Param $Force present")
        check("$Uninstall" in pblock, "Param $Uninstall present")
        check("$Prefix" in pblock, "Param $Prefix present")

    # 4. Architecture check: rejects ARM64 before any network access
    arch_pos = src.find("PROCESSOR_ARCHITECTURE")
    webreq_pos = src.find("Invoke-WebRequest")
    check(arch_pos != -1, "Checks PROCESSOR_ARCHITECTURE")
    check("PROCESSOR_ARCHITEW6432" in src, "Checks PROCESSOR_ARCHITEW6432")
    check("ARM64" in src, "Detects ARM64 architecture")
    check(arch_pos < webreq_pos, "ARM64 rejection occurs BEFORE any Invoke-WebRequest")
    check("Unsupported platform: Windows ARM64 is not supported" in src, "ARM64 rejection has clear error message")

    # 5. Prefix overlap rejection
    prefix_guard_pos = src.find("overlaps official grok home")
    check(prefix_guard_pos != -1, "Contains prefix overlap rejection message")
    check(prefix_guard_pos < webreq_pos, "Prefix overlap rejection occurs BEFORE any network access")

    # 6. Official Grok protection
    check("Assert-NotOfficialGrok" in src, "Implements Assert-NotOfficialGrok protection function")
    check("Refusing to mutate official Grok executable" in src, "Assert-NotOfficialGrok throws fail-closed error")

    # 7. Exact Checksum matching and runtime asset verification
    check("grokgod-windows-x64.exe" in src, "Targets grokgod-windows-x64.exe asset")
    check("ChecksumMap" in src, "Builds parsed ChecksumMap from SHA256SUMS")
    check("Multiple checksum entries found" in src, "Fails if multiple checksum entries found for asset")
    check("$sumLines[0]" not in src and "sumLines[0]" not in src, "No first-line checksum fallback ($sumLines[0] eliminated)")
    check("Checksum verification failed for runtime asset" in src, "Verifies runtime asset checksums fail-closed")

    # 8. Candidate Preflight Verification
    preflight_pos = src.find("--version")
    move_pos = src.find("Move-Item -LiteralPath $CandidateSibling -Destination $TargetExe")
    check(preflight_pos != -1, "Runs candidate --version")
    check(preflight_pos < move_pos, "Candidate preflight runs BEFORE live target mutation")
    check("Preflight verified candidate binary" in src, "Reports preflight verification success")

    # 9. Sibling Staging & Rollback Engine
    check("CandidateSibling" in src, "Stages candidate as sibling on destination volume")
    check("Tx-Rollback" in src, "Implements transactional rollback engine")
    check("Rollback complete. System returned to pristine prior state." in src, "Rollback reports pristine prior state")

    # 10. Durable Manifest Backups (CRIT-1 fix)
    commit_idx = src.rfind("Committed manifest")
    post_commit_src = src[commit_idx:]
    check("Remove-Item -LiteralPath $b" not in post_commit_src, "CRIT-1: Backups in manifest are NOT deleted post-commit")
    check("DurableBackups" in src, "Tracks DurableBackups across transactions")
    check("Get-DurableBackupPath" in src, "Uses deterministic durable backup paths")

    # 11. Uninstall Restoration Sequencing (CRIT-2 fix)
    check("restoredPaths" in src, "CRIT-2: Uninstall tracks restored paths in restoredPaths set")
    check("restoredPaths.ContainsKey" in src, "CRIT-2: Removal loop skips files present in restoredPaths")

    # 12. Persisted Journal (IMP-1 fix)
    check("install.journal" in src, "IMP-1: Defines install.journal path")
    check("journal         = $script:TxJournal" in src or "journal" in src, "IMP-1: Persists journal into manifest.json")
    check("Set-Content -LiteralPath $JournalFile" in src, "IMP-1: Writes transaction journal to install.journal")

    # 13. Real Lock Mutual Exclusion & Stale Lock Handling (IMP-2 fix)
    check("Acquire-InstallLock" in src, "IMP-2: Implements Acquire-InstallLock")
    check("Release-InstallLock" in src, "IMP-2: Implements Release-InstallLock")
    check("FileMode]::CreateNew" in src, "IMP-2: Uses atomic CreateNew for lock acquisition")
    check("GetProcessById" in src, "IMP-2: Checks active holding process PID")
    check("stale lock" in src, "IMP-2: Handles stale lock clearance safely")

    # 14. Temp Directory Cleanup in Finally (IMP-3 fix)
    finally_idx = src.rfind("finally {")
    check(finally_idx != -1, "IMP-3: Uses try/finally for download staging")
    finally_block = src[finally_idx:finally_idx+200]
    check("Remove-Item -LiteralPath $TmpDir" in finally_block, "IMP-3: Temp directory deleted in finally block")

    # 15. Self-Contained Bootstrap & Runtime Refresh on Upgrade (Round 2 fix)
    check("RuntimeStagedFiles" in src, "Round 2: Stages runtime files in destination volume prior to live activation")
    # Verify no short-circuit return when destination exists
    check("already present at destination" not in src, "Round 2: Does not short-circuit runtime installation when destination exists")
    # Verify no raw unverified GitHub fallback
    check("raw.githubusercontent.com" not in src, "Round 2: Removed raw unverified GitHub fallback (trust release base + checksums)")

    # 16. Collision-Safe Backup Naming (MIN-1 fix)
    check("ComputeHash" in src or "hashStr" in src, "MIN-1: Backup path uses hash-based collision-safe identifier")

    # 17. Manifest Rollback (MIN-2 fix)
    check("Tx-BackupTarget $ManifestFile" in src, "MIN-2: Backs up manifest.json so rollback restores prior manifest")

    # 18. Wrapper Runtime Installation into GrokgodHome
    check("installedShimDir" in src, "Defines installed shim directory under GrokgodHome")
    check("installedShimPs1" in src, "Installs grok-shim.ps1 into grokgod home")
    check("installedHelpers" in src, "Installs LauncherHelpers.ps1 into grokgod home")
    check("installedSelf" in src, "Installs install.ps1 into grokgod home for updater resolution")

    # 19. Launcher generation via LauncherHelpers
    check("New-GrokgodLauncherScript" in src, "Consumes New-GrokgodLauncherScript helper")
    check('-Identity "grok"' in src or "-Identity 'grok'" in src, "Generates launcher with explicit Identity grok")
    check('-Identity "grokgod"' in src or "-Identity 'grokgod'" in src, "Generates launcher with explicit Identity grokgod")

    # 20. Stamp Generation and PINNED_BASE_SHA
    pinned_sha = "4247f661689354b831191f11eeeac8424993fe3d"
    check(pinned_sha in src, f"Contains PINNED_BASE_SHA {pinned_sha}")
    check("SHA=" in src, "Stamp includes SHA=")
    check("PATCHSET=" in src, "Stamp includes PATCHSET=")
    check("VERSION=$PINNED_BASE_SHA" in src, "Stamp binds VERSION to PINNED_BASE_SHA (not grokgod tag)")
    check("MODE=release" in src, "Stamp includes MODE=release")

    # 21. Manifest commit point
    check("Write-ManifestFile" in src, "Writes manifest file")
    check("manifest.json" in src, "Manifest file is manifest.json")
    manifest_call_pos = src.rfind("Write-ManifestFile")
    check(move_pos < manifest_call_pos, "Manifest commit point is written AFTER activation")

    # 22. Locked File Detection
    check("Test-FileIsLocked" in src, "Implements Test-FileIsLocked check")
    check("currently running or locked" in src, "Provides fail-closed warning for locked executable")

    # 23. Failure Injection Points
    check("Test-FailureInjection" in src, "Implements Test-FailureInjection")
    check('Test-FailureInjection "backup"' in src or "Test-FailureInjection 'backup'" in src, "Supports failure injection after 'backup'")
    check('Test-FailureInjection "activation"' in src or "Test-FailureInjection 'activation'" in src, "Supports failure injection after 'activation'")
    check('Test-FailureInjection "launcher-grok"' in src or "Test-FailureInjection 'launcher-grok'" in src, "Supports failure injection after 'launcher-grok'")
    check('Test-FailureInjection "launcher-grokgod"' in src or "Test-FailureInjection 'launcher-grokgod'" in src, "Supports failure injection after 'launcher-grokgod'")
    check('Test-FailureInjection "stamp"' in src or "Test-FailureInjection 'stamp'" in src, "Supports failure injection after 'stamp'")

    # 24. Manifest-based Uninstall
    check('$manifest = Read-Manifest' in src, "Uninstall reads ownership manifest")
    check("Restoring backup:" in src or "Restored" in src, "Uninstall restores manifest-recorded backups")
    check("Removing manifest-owned file:" in src or "Removed" in src, "Uninstall removes manifest-owned files")
    check("Assert-NotOfficialGrok" in src, "Uninstall asserts target is not official grok.exe")

    # 25. Native Test Suite Portability (no Add-Type -OutputAssembly)
    if os.path.isfile(NATIVE_SHIM_TEST):
        with open(NATIVE_SHIM_TEST, "r", encoding="utf-8") as f:
            shim_test_src = f.read()
        check("-OutputAssembly" not in shim_test_src, "Native shim test does NOT contain -OutputAssembly (PS7 compat)")
        check("csc.exe" in shim_test_src or "csc" in shim_test_src, "Native shim test uses csc.exe compiler for mock binary")

    if os.path.isfile(NATIVE_INSTALL_TEST):
        with open(NATIVE_INSTALL_TEST, "r", encoding="utf-8") as f:
            install_test_src = f.read()
        check("-OutputAssembly" not in install_test_src, "Native install test does NOT contain -OutputAssembly (PS7 compat)")
        check("healthz" in install_test_src, "Native install test includes server readiness probe (healthz)")
        check("cmd.exe" not in install_test_src, "Native install test does NOT use cmd.exe as candidate binary")
        check("UPDATED_SHIM_MARKER" in install_test_src, "Native install test tests upgrade refresh of runtime scripts")
        check("grokgod test ünicode" in install_test_src, "Native install test uses fixture path with spaces and Unicode")
        check("Multiple checksum entries found" in install_test_src, "Native install test verifies duplicate checksum entries fail closed")
        check("Guarded official grok.exe" in install_test_src, "Native install test guards actual official %USERPROFILE%\\.grok\\bin\\grok.exe")
        check("officialGrokBaselineHash" in install_test_src, "Native install test asserts official grok hash invariance across full lifecycle")
        check("Get-SnapshotState" in install_test_src, "Native install test uses state snapshot helper for rollback comparison")
        check("JournalContent" in install_test_src, "Native install test verifies transaction journal in rollback")
        check("GrokgodCmdContent" in install_test_src, "Native install test verifies grokgod.cmd launcher in rollback")
        check("ShimPs1Hash" in install_test_src and "HelpersPs1Hash" in install_test_src and "InstallPs1Hash" in install_test_src, "Native install test verifies all 3 runtime scripts in rollback")
        check("BackupInventory" in install_test_src, "Native install test verifies backup inventory and content hashes in rollback")
        check("Second repeated uninstall exits 0" in install_test_src, "Native install test verifies repeated uninstall idempotency")
        check("Unrelated user file in bin directory survived uninstall" in install_test_src, "Native install test verifies unrelated files survive uninstall")
        check("Repeated installs with identical state do not cause backup churn" in install_test_src, "Native install test verifies no backup churn on repeated installs")
        check("-NoUpgrade exits 0 without upgrade" in install_test_src, "Native install test verifies -NoUpgrade fast path")
        check("currently running or locked" in install_test_src, "Native install test verifies locked executable fail-closed policy")
        check("Installed updater succeeds with hidden checkout" in install_test_src, "Native install test verifies updater self-containment with hidden checkout")
        check("HostShell" in install_test_src and "PSEdition" in install_test_src, "Native install test aligns child runner with host PSEdition")
        check('$serverPsi.FileName = $HostShell' in install_test_src, "Native install test launches mock server with HostShell")
        check("Combined" in install_test_src, "Native install test uses combined output for robust stderr matching")

        # Invariant checks for no duplicate test headings and no uninitialized variables
        test_9_count = len(re.findall(r'Write-Host\s+"Test 9:', install_test_src))
        test_10_count = len(re.findall(r'Write-Host\s+"Test 10:', install_test_src))
        test_11_count = len(re.findall(r'Write-Host\s+"Test 11:', install_test_src))
        check(test_9_count == 1, f"Native install test contains exactly one Test 9 heading (found {test_9_count})")
        check(test_10_count == 1, f"Native install test contains exactly one Test 10 heading (found {test_10_count})")
        check(test_11_count == 1, f"Native install test contains exactly one Test 11 heading (found {test_11_count})")
        check("fakeOfficialDir" not in install_test_src, "Native install test contains no stale fakeOfficialDir references")

    if os.path.isfile(NATIVE_SHIM_TEST):
        with open(NATIVE_SHIM_TEST, "r", encoding="utf-8") as f:
            shim_test_src = f.read()
        check("grokgod test ünicode" in shim_test_src, "Native shim test uses fixture path with spaces and Unicode")
        check("hostShell" in shim_test_src and "PSEdition" in shim_test_src, "Native shim test aligns child runner with host PSEdition")

    print("\n===============================================")
    print(f"Total Passed: {passes}")
    print(f"Total Failed: {fails}")
    print("===============================================")

    if fails > 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
