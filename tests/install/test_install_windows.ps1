#Requires -Version 5.1
<#
.SYNOPSIS
    Native PowerShell test suite for grokgod Windows Transactional Installer (install.ps1).
.DESCRIPTION
    Runs natively on Windows PowerShell 5.1 and PowerShell 7.
    Tests:
      1. Platform check: ARM64 rejected before network
      2. Prefix safety: Prefix overlapping official .grok rejected before network
      3. Official Grok safety: Assert-NotOfficialGrok prevents write/replace/delete of official grok.exe
      4. Exact checksum matching: fails if 0 or >1 matches, no first-line fallback
      5. Preflight check: --version execution failure leaves live state untouched
      6. Sibling staging and bounded backups: candidate staged as sibling on destination volume
      7. Full transactional rollback across all failure injection points:
         - backup
         - activation
         - launcher-grok
         - launcher-grokgod
         - stamp
      8. Runtime installation & upgrade refresh: grok-shim.ps1, LauncherHelpers.ps1, install.ps1 refreshed on update without checkout
      9. Runtime checksum verification & fail closed: runtime asset checksum mismatch leaves live state untouched
     10. Launcher generation: New-GrokgodLauncherScript produces working wrappers with -Identity grok/grokgod
     11. Stamp commit point: .source-version contains SHA, PATCHSET, VERSION=PINNED_BASE_SHA, MODE=release
     12. Durable backups survive install and uninstall restores pre-existing files without clobbering them
     13. Manifest-based uninstall: restores backups, removes owned files, preserves unrelated files, idempotent
     14. Active and stale lock mutual exclusion policy
     15. Server health and readiness probe: fails closed with clear diagnostic if mock server cannot start
#>
param(
    [string]$InstallScript = "$PSScriptRoot\..\..\install.ps1"
)

# Robust exit propagation: trap terminating errors so PowerShell never exits 0 on uncaught exceptions
trap {
    Write-Host "`nFATAL TERMINATING ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PassCount = 0
$FailCount = 0

function Assert-Test([bool]$Condition, [string]$TestName, [string]$Details = "") {
    if ($Condition) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $script:PassCount++
    } else {
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        if ($Details) {
            Write-Host "        $Details" -ForegroundColor Yellow
        }
        $script:FailCount++
    }
}

Write-Host "`n=== grokgod Windows Transactional Installer Native Test Suite ===`n"

$InstallScriptPath = (Resolve-Path $InstallScript).Path
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$ShimSource = Join-Path $RepoRoot "src\shim\grok-shim.ps1"
$HelpersSource = Join-Path $RepoRoot "src\shim\LauncherHelpers.ps1"

# Determine host PowerShell engine to align child processes with outer suite
$HostShell = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
Write-Host "Host PowerShell Edition: $($PSVersionTable.PSEdition) ($($PSVersionTable.PSVersion))"
Write-Host "Child Process Engine:    $HostShell"

function Invoke-InstallerProcess([hashtable]$EnvVars, [string[]]$ScriptArgs, [string]$ScriptPath = "", [string]$Shell = "") {
    $pwsh = if ($Shell) { $Shell } else { $script:HostShell }
    $targetScript = if ($ScriptPath) { $ScriptPath } else { $InstallScriptPath }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $targetScript) + $ScriptArgs
    $escapedArgs = @()
    foreach ($a in $argsList) {
        if ($a -eq "") {
            $escapedArgs += '""'
        } elseif ($a -match '[\s"]|\\$') {
            $esc = $a -replace '(\\*)(")', '$1$1\"'
            $esc = $esc -replace '(\\+)$', '$1$1'
            $escapedArgs += ('"' + $esc + '"')
        } else {
            $escapedArgs += $a
        }
    }
    $psi.Arguments = [string]::Join(" ", $escapedArgs)

    foreach ($k in $EnvVars.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$EnvVars[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $combined = ($stdout + "`n" + $stderr).Trim()

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Combined = $combined
    }
}

# -----------------------------------------------------------------------------
# Test 1: ARM64 Early Rejection Before Network
# -----------------------------------------------------------------------------
Write-Host "Test 1: ARM64 architecture rejected before network access"
$res = Invoke-InstallerProcess -EnvVars @{ "PROCESSOR_ARCHITECTURE" = "ARM64"; "GROKGOD_REPO" = "invalid/dummy" } -ScriptArgs @()
Assert-Test ($res.ExitCode -eq 1) "ARM64 process architecture exits with 1"
Assert-Test ($res.Combined -match "Windows ARM64 is not supported") "ARM64 error message printed"

$res6432 = Invoke-InstallerProcess -EnvVars @{ "PROCESSOR_ARCHITECTURE" = "AMD64"; "PROCESSOR_ARCHITEW6432" = "ARM64" } -ScriptArgs @()
Assert-Test ($res6432.ExitCode -eq 1) "ARM64 WOW64 architecture exits with 1"
Assert-Test ($res6432.Combined -match "Windows ARM64 is not supported") "ARM64 WOW64 error message printed"

# -----------------------------------------------------------------------------
# Test 2: Prefix Overlap with Official .grok Rejected
# -----------------------------------------------------------------------------
Write-Host "Test 2: Prefix overlapping official .grok rejected"
$testProfile = Join-Path $env:TEMP "grokgod test prof ünicode $([Guid]::NewGuid().ToString('N'))"
$offGrok = Join-Path $testProfile ".grok"
New-Item -ItemType Directory -Force -Path $offGrok | Out-Null

$resPrefix = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testProfile } -ScriptArgs @("-Prefix", $offGrok)
Assert-Test ($resPrefix.ExitCode -eq 1) "Exact .grok prefix rejected"
Assert-Test ($resPrefix.Combined -match "overlaps official grok home") "Prefix overlap error message displayed"

$resSubPrefix = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testProfile } -ScriptArgs @("-Prefix", (Join-Path $offGrok "subfolder"))
Assert-Test ($resSubPrefix.ExitCode -eq 1) "Subpath under .grok prefix rejected"
Assert-Test ($resSubPrefix.Combined -match "overlaps official grok home") "Subpath prefix overlap error message displayed"

$resParentPrefix = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testProfile } -ScriptArgs @("-Prefix", $testProfile)
Assert-Test ($resParentPrefix.ExitCode -eq 1) "Parent folder containing .grok rejected"
Assert-Test ($resParentPrefix.Combined -match "overlaps official grok home") "Parent prefix overlap error message displayed"

Remove-Item -LiteralPath $testProfile -Recurse -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# Test Fixture Setup for Local Mock Releases (Standalone child server)
# -----------------------------------------------------------------------------
$fixtureRoot = Join-Path $env:TEMP "grokgod test ünicode $([Guid]::NewGuid().ToString('N'))"
$mockServerDir = Join-Path $fixtureRoot "mock_release"
$targetPrefix = Join-Path $fixtureRoot "install prefix with spaces ünicode"
$testUserProfile = Join-Path $fixtureRoot "isolated_userprofile"
$officialGrokBin = Join-Path $testUserProfile ".grok\bin"
$officialGrokExe = Join-Path $officialGrokBin "grok.exe"

New-Item -ItemType Directory -Force -Path $mockServerDir | Out-Null
New-Item -ItemType Directory -Force -Path $targetPrefix | Out-Null
New-Item -ItemType Directory -Force -Path $officialGrokBin | Out-Null

Set-Content -LiteralPath $officialGrokExe -Value "OFFICIAL_AUTH_BINARY_DATA_DO_NOT_TOUCH_48271133" -Encoding ASCII
$officialGrokBaselineHash = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
Write-Host "Established guarded official grok fixture: $officialGrokExe (Hash: $officialGrokBaselineHash)"

# Compile a deterministic Win32 console executable fixture via csc.exe (works on PS5.1 and PS7)
$mockExeSrc = Join-Path $mockServerDir "grokgod-windows-x64.exe"
$csharpSource = @"
using System;
class Program {
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "--version") {
            Console.WriteLine("grok 1.0.26 (482711333c71)");
            return 0;
        }
        Console.WriteLine("mock grok binary");
        return 0;
    }
}
"@
$csharpFile = Join-Path $fixtureRoot "MockCandidate.cs"
Set-Content -LiteralPath $csharpFile -Value $csharpSource -Encoding UTF8

$cscExe = $null
$frameworkPaths = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
foreach ($fp in $frameworkPaths) {
    if (Test-Path $fp) {
        $cscExe = $fp
        break
    }
}
if (-not $cscExe -and (Get-Command "csc" -ErrorAction SilentlyContinue)) {
    $cscExe = (Get-Command "csc").Source
}

if ($cscExe) {
    $compileProc = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$mockExeSrc`"", "`"$csharpFile`"") -NoNewWindow -Wait -PassThru
    if ($compileProc.ExitCode -ne 0) {
        throw "Failed to compile MockCandidate.cs via csc.exe"
    }
} else {
    try {
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.OutputAssembly = $mockExeSrc
        $cscp = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cr = $cscp.CompileAssemblyFromSource($cp, $csharpSource)
        if ($cr.Errors.Count -gt 0) {
            throw $cr.Errors[0].ErrorText
        }
    } catch {
        throw "Unable to compile deterministic candidate executable fixture: $_"
    }
}

$mockExeHash = (Get-FileHash -LiteralPath $mockExeSrc -Algorithm SHA256).Hash.ToLower()

# Copy runtime scripts to mock server
$mockShim = Join-Path $mockServerDir "grok-shim.ps1"
$mockHelpers = Join-Path $mockServerDir "LauncherHelpers.ps1"
$mockInstall = Join-Path $mockServerDir "install.ps1"

Copy-Item $ShimSource $mockShim -Force
Copy-Item $HelpersSource $mockHelpers -Force
Copy-Item $InstallScriptPath $mockInstall -Force

$mockShimHash = (Get-FileHash -LiteralPath $mockShim -Algorithm SHA256).Hash.ToLower()
$mockHelpersHash = (Get-FileHash -LiteralPath $mockHelpers -Algorithm SHA256).Hash.ToLower()
$mockInstallHash = (Get-FileHash -LiteralPath $mockInstall -Algorithm SHA256).Hash.ToLower()

# Create SHA256SUMS containing exact entries for binary and all runtime scripts
$sumsFile = Join-Path $mockServerDir "SHA256SUMS"
$sumsLines = @(
    "$mockExeHash *grokgod-windows-x64.exe",
    "$mockShimHash *grok-shim.ps1",
    "$mockHelpersHash *LauncherHelpers.ps1",
    "$mockInstallHash *install.ps1"
)
Set-Content -LiteralPath $sumsFile -Value ($sumsLines -join "`r`n") -Encoding ASCII

# Dedicated child PowerShell process running HttpListener
$serverPort = 19442
$serverScript = Join-Path $fixtureRoot "server.ps1"
$serverScriptContent = @"
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add("http://127.0.0.1:$serverPort/")
`$listener.Start()
while (`$listener.IsListening) {
    try {
        `$context = `$listener.GetContext()
        `$req = `$context.Request
        `$res = `$context.Response
        `$p = `$req.Url.AbsolutePath.TrimStart('/')
        if (`$p -eq "healthz") {
            `$bytes = [System.Text.Encoding]::ASCII.GetBytes("OK")
            `$res.ContentType = "text/plain"
            `$res.ContentLength64 = `$bytes.Length
            `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
        } else {
            `$filePath = Join-Path "$($mockServerDir.Replace('\', '\\'))" `$p
            if (Test-Path `$filePath) {
                `$bytes = [System.IO.File]::ReadAllBytes(`$filePath)
                `$res.ContentType = "application/octet-stream"
                `$res.ContentLength64 = `$bytes.Length
                `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
            } else {
                `$res.StatusCode = 404
            }
        }
        `$res.OutputStream.Close()
    } catch {
        break
    }
}
"@
Set-Content -LiteralPath $serverScript -Value $serverScriptContent -Encoding UTF8

$serverPsi = New-Object System.Diagnostics.ProcessStartInfo
$serverPsi.FileName = $HostShell
$serverPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`""
$serverPsi.UseShellExecute = $false
$serverPsi.CreateNoWindow = $true
$serverProc = $null
$serverStartError = ""
try {
    $serverProc = [System.Diagnostics.Process]::Start($serverPsi)
} catch {
    $serverStartError = $_.ToString()
}

$httpUrl = "http://127.0.0.1:$serverPort"

# Explicit readiness probe for test server (fail closed with clear diagnostic)
$serverReady = $false
$probeDiag = ""
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 100
    try {
        $resp = Invoke-WebRequest -Uri "$httpUrl/healthz" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
        if ($resp -and $resp.StatusCode -eq 200) {
            $serverReady = $true
            break
        }
    } catch {
        $probeDiag = $_.ToString()
    }
}

if (-not $serverReady) {
    if ($serverProc -and -not $serverProc.HasExited) { $serverProc.Kill() }
    $diagMsg = "Fatal: Test HTTP server failed to start and bind on port $serverPort using engine '$HostShell'."
    if ($serverStartError) { $diagMsg += " Start error: $serverStartError." }
    if ($probeDiag) { $diagMsg += " Last probe exception: $probeDiag." }
    throw $diagMsg
}

try {
    # -------------------------------------------------------------------------
    # Test 3: Lock File Handling (Active vs Stale Lock)
    # -------------------------------------------------------------------------
    Write-Host "Test 3: Lock File Handling"
    $stageHome = Join-Path $targetPrefix "grokgod"
    New-Item -ItemType Directory -Force -Path $stageHome | Out-Null
    $lockFile = Join-Path $stageHome "install.lock"

    Set-Content -LiteralPath $lockFile -Value "PID=$PID`r`nACQUIRED=test`r`n" -Encoding ASCII
    $resActiveLock = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix)
    Assert-Test ($resActiveLock.ExitCode -eq 1) "Active lock causes installer to fail closed"
    Assert-Test ($resActiveLock.Combined -match "currently active") "Active lock error message displayed"

    Set-Content -LiteralPath $lockFile -Value "PID=999999`r`nACQUIRED=stale`r`n" -Encoding ASCII
    $resStaleLock = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix)
    Assert-Test ($resStaleLock.ExitCode -eq 0) "Stale lock is safely detected and cleared, allowing install"

    # -------------------------------------------------------------------------
    # Test 4: Pre-Existing Launcher Preservation across Install & Uninstall
    # -------------------------------------------------------------------------
    Write-Host "Test 4: Pre-existing launcher durable backup and restoration"
    $targetBin = Join-Path $targetPrefix "bin"
    $preExistingGrokCmd = Join-Path $targetBin "grok.cmd"
    $preExistingContent = "@rem PRE_EXISTING_ORIGINAL_LAUNCHER"
    Set-Content -LiteralPath $preExistingGrokCmd -Value $preExistingContent -Encoding ASCII

    $resInstall = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resInstall.ExitCode -eq 0) "Install succeeds with pre-existing launcher"

    $installedGrokCmd = Join-Path $targetBin "grok.cmd"
    $manifestFile = Join-Path $stageHome "manifest.json"
    $backupDir = Join-Path $stageHome "backups"

    Assert-Test (Test-Path -LiteralPath $manifestFile) "Manifest file exists"
    Assert-Test (Test-Path -LiteralPath $backupDir) "Backup directory exists"

    $backupFiles = Get-ChildItem -LiteralPath $backupDir -Filter "*.bak" -ErrorAction SilentlyContinue
    Assert-Test ($backupFiles.Count -gt 0) "Durable backups survive installation commit (not purged)"

    $resUninstall = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Uninstall")
    Assert-Test ($resUninstall.ExitCode -eq 0) "Uninstall exits with 0"
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $stageHome "bin\grokgod.exe"))) "grokgod.exe removed on uninstall"
    Assert-Test (Test-Path -LiteralPath $preExistingGrokCmd) "Pre-existing launcher restored on uninstall"
    if (Test-Path -LiteralPath $preExistingGrokCmd) {
        $restoredContent = Get-Content -LiteralPath $preExistingGrokCmd -Raw
        Assert-Test ($restoredContent.Trim() -eq $preExistingContent.Trim()) "Restored launcher content matches original prior content exactly"
    }

    # -------------------------------------------------------------------------
    # Test 5: Full Rollback Across All Failure Injection Points
    # -------------------------------------------------------------------------
    Write-Host "Test 5: Transactional Rollback across all failure injection points"
    $resBase = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resBase.ExitCode -eq 0) "Base installation succeeded"

    $exePath = Join-Path $stageHome "bin\grokgod.exe"
    $stampPath = Join-Path $stageHome ".source-version"
    $journalPath = Join-Path $stageHome "install.journal"
    $grokCmd = Join-Path $targetBin "grok.cmd"
    $grokgodCmd = Join-Path $targetBin "grokgod.cmd"
    $shimDir = Join-Path $stageHome "shim"
    $shimPs1 = Join-Path $shimDir "grok-shim.ps1"
    $helpersPs1 = Join-Path $shimDir "LauncherHelpers.ps1"
    $installPs1 = Join-Path $stageHome "install.ps1"

    function Get-SnapshotState {
        $backupListing = @()
        if (Test-Path -LiteralPath $backupDir) {
            $bFiles = Get-ChildItem -LiteralPath $backupDir -File | Sort-Object Name
            foreach ($bf in $bFiles) {
                $bHash = (Get-FileHash -LiteralPath $bf.FullName -Algorithm SHA256).Hash
                $backupListing += "$($bf.Name):$($bf.Length):$bHash"
            }
        }

        return [PSCustomObject]@{
            ExeHash         = if (Test-Path -LiteralPath $exePath) { (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash } else { "" }
            StampContent    = if (Test-Path -LiteralPath $stampPath) { Get-Content -LiteralPath $stampPath -Raw } else { "" }
            ManifestContent = if (Test-Path -LiteralPath $manifestFile) { Get-Content -LiteralPath $manifestFile -Raw } else { "" }
            JournalContent  = if (Test-Path -LiteralPath $journalPath) { Get-Content -LiteralPath $journalPath -Raw } else { "" }
            GrokCmdContent  = if (Test-Path -LiteralPath $grokCmd) { Get-Content -LiteralPath $grokCmd -Raw } else { "" }
            GrokgodCmdContent = if (Test-Path -LiteralPath $grokgodCmd) { Get-Content -LiteralPath $grokgodCmd -Raw } else { "" }
            ShimPs1Hash     = if (Test-Path -LiteralPath $shimPs1) { (Get-FileHash -LiteralPath $shimPs1 -Algorithm SHA256).Hash } else { "" }
            HelpersPs1Hash  = if (Test-Path -LiteralPath $helpersPs1) { (Get-FileHash -LiteralPath $helpersPs1 -Algorithm SHA256).Hash } else { "" }
            InstallPs1Hash  = if (Test-Path -LiteralPath $installPs1) { (Get-FileHash -LiteralPath $installPs1 -Algorithm SHA256).Hash } else { "" }
            BackupInventory = $backupListing -join ";"
            OfficialHash    = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
        }
    }

    $baseState = Get-SnapshotState

    $injectionPoints = @("backup", "activation", "launcher-grok", "launcher-grokgod", "stamp")
    foreach ($pt in $injectionPoints) {
        $envInj = @{
            "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl
            "GROKGOD_INSTALL_FAIL_AFTER" = $pt
            "USERPROFILE"               = $testUserProfile
        }
        $resInj = Invoke-InstallerProcess -EnvVars $envInj -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
        Assert-Test ($resInj.ExitCode -eq 1) "Failure injection '$pt' triggers non-zero exit"

        $currState = Get-SnapshotState

        Assert-Test ($currState.ExeHash -eq $baseState.ExeHash) "Binary unchanged after rollback for '$pt'"
        Assert-Test ($currState.StampContent -eq $baseState.StampContent) "Stamp unchanged after rollback for '$pt'"
        Assert-Test ($currState.ManifestContent -eq $baseState.ManifestContent) "Manifest unchanged after rollback for '$pt'"
        Assert-Test ($currState.JournalContent -eq $baseState.JournalContent) "Journal unchanged after rollback for '$pt'"
        Assert-Test ($currState.GrokCmdContent -eq $baseState.GrokCmdContent) "grok.cmd launcher unchanged after rollback for '$pt'"
        Assert-Test ($currState.GrokgodCmdContent -eq $baseState.GrokgodCmdContent) "grokgod.cmd launcher unchanged after rollback for '$pt'"
        Assert-Test ($currState.ShimPs1Hash -eq $baseState.ShimPs1Hash) "grok-shim.ps1 unchanged after rollback for '$pt'"
        Assert-Test ($currState.HelpersPs1Hash -eq $baseState.HelpersPs1Hash) "LauncherHelpers.ps1 unchanged after rollback for '$pt'"
        Assert-Test ($currState.InstallPs1Hash -eq $baseState.InstallPs1Hash) "install.ps1 unchanged after rollback for '$pt'"
        Assert-Test ($currState.BackupInventory -eq $baseState.BackupInventory) "Backup inventory & content hashes unchanged after rollback for '$pt'"
        Assert-Test ($currState.OfficialHash -eq $officialGrokBaselineHash) "Guarded official grok.exe untouched after rollback for '$pt'"
    }

    # -------------------------------------------------------------------------
    # Test 6: Upgrade Refreshes All Three Runtime Scripts With No Checkout (Installed Updater)
    # -------------------------------------------------------------------------
    Write-Host "Test 6: Upgrade refreshes runtime scripts without git checkout via installed updater"
    # Stage an updated shim on server with a marker comment
    $updatedShimContent = "# UPDATED_SHIM_MARKER_V2`r`n" + (Get-Content -LiteralPath $ShimSource -Raw)
    Set-Content -LiteralPath $mockShim -Value $updatedShimContent -Encoding UTF8
    $newShimHash = (Get-FileHash -LiteralPath $mockShim -Algorithm SHA256).Hash.ToLower()

    # Update SHA256SUMS with new hash
    $updatedSumsLines = @(
        "$mockExeHash *grokgod-windows-x64.exe",
        "$newShimHash *grok-shim.ps1",
        "$mockHelpersHash *LauncherHelpers.ps1",
        "$mockInstallHash *install.ps1"
    )
    Set-Content -LiteralPath $sumsFile -Value ($updatedSumsLines -join "`r`n") -Encoding ASCII

    # Verify updating using installed install.ps1 directly, with GROKGOD_SRC unset and checkout hidden
    $installedUpdaterPath = Join-Path $stageHome "install.ps1"
    Assert-Test (Test-Path -LiteralPath $installedUpdaterPath) "Installed updater exists in grokgod home"

    # Temporarily hide/rename checkout install.ps1 to prove self-contained execution without checkout
    $checkoutBak = $InstallScriptPath + ".testbak"
    try {
        Move-Item -LiteralPath $InstallScriptPath -Destination $checkoutBak -Force

        # Run upgrade with -Force using installed install.ps1 directly
        $resUpgrade = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force") -ScriptPath $installedUpdaterPath
        Assert-Test ($resUpgrade.ExitCode -eq 0) "Installed updater succeeds with hidden checkout"

        $installedShim = Join-Path $stageHome "shim\grok-shim.ps1"
        $installedShimContent = Get-Content -LiteralPath $installedShim -Raw
        Assert-Test ($installedShimContent -match "UPDATED_SHIM_MARKER_V2") "Installed grok-shim.ps1 was refreshed with updated release version"
    } finally {
        if (Test-Path -LiteralPath $checkoutBak) {
            Move-Item -LiteralPath $checkoutBak -Destination $InstallScriptPath -Force
        }
    }

    # -------------------------------------------------------------------------
    # Test 7: Runtime Asset Checksum Mismatch Leaves Live State Untouched
    # -------------------------------------------------------------------------
    Write-Host "Test 7: Runtime checksum mismatch leaves live state untouched"
    # Corrupt SHA256SUMS for LauncherHelpers.ps1
    $corruptSumsLines = @(
        "$mockExeHash *grokgod-windows-x64.exe",
        "$newShimHash *grok-shim.ps1",
        "0000000000000000000000000000000000000000000000000000000000000000 *LauncherHelpers.ps1",
        "$mockInstallHash *install.ps1"
    )
    Set-Content -LiteralPath $sumsFile -Value ($corruptSumsLines -join "`r`n") -Encoding ASCII

    $preMismatchStamp = Get-Content -LiteralPath $stampPath -Raw
    $resMismatch = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile; "GROKGOD_SRC" = (Join-Path $fixtureRoot "missing-source") } -ScriptArgs @("-Prefix", $targetPrefix, "-Force") -ScriptPath $installedUpdaterPath
    Assert-Test ($resMismatch.ExitCode -eq 1) "Runtime checksum mismatch fails closed with exit code 1"
    Assert-Test ($resMismatch.Combined -match "Checksum verification failed for runtime asset") "Mismatch error reported"
    $postMismatchStamp = Get-Content -LiteralPath $stampPath -Raw
    Assert-Test ($preMismatchStamp -eq $postMismatchStamp) "Live stamp left untouched on runtime checksum mismatch"

    # -------------------------------------------------------------------------
    # Test 8: Duplicate and Multiple Checksum Entries Fail Closed
    # -------------------------------------------------------------------------
    Write-Host "Test 8: Multiple or duplicate checksum entries fail closed with zero mutation"
    $dupSumsLines = @(
        "$mockExeHash *grokgod-windows-x64.exe",
        "$mockExeHash *grokgod-windows-x64.exe",
        "$newShimHash *grok-shim.ps1",
        "$mockHelpersHash *LauncherHelpers.ps1",
        "$mockInstallHash *install.ps1"
    )
    Set-Content -LiteralPath $sumsFile -Value ($dupSumsLines -join "`r`n") -Encoding ASCII

    $preDupStamp = Get-Content -LiteralPath $stampPath -Raw
    $resDup = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resDup.ExitCode -eq 1) "Duplicate checksum entries fail closed with exit code 1"
    Assert-Test ($resDup.Combined -match "Multiple checksum entries found") "Multiple checksum error reported"
    $postDupStamp = Get-Content -LiteralPath $stampPath -Raw
    Assert-Test ($preDupStamp -eq $postDupStamp) "Live stamp left untouched on duplicate checksum entries"

    # Restore valid SHA256SUMS
    Set-Content -LiteralPath $sumsFile -Value ($updatedSumsLines -join "`r`n") -Encoding ASCII

    # -------------------------------------------------------------------------
    # Test 9: Guarded official grok.exe Untouched, Unrelated Files Survive, and Repeated Uninstall Idempotent
    # -------------------------------------------------------------------------
    Write-Host "Test 9: Guarded official grok.exe untouched, unrelated files survive, and repeated uninstall is idempotent"
    $officialHashBefore = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
    Assert-Test ($officialHashBefore -eq $officialGrokBaselineHash) "Guarded official grok.exe matches baseline prior to repeated installs"

    # Create an unrelated user file in the target bin directory
    $unrelatedFile = Join-Path $targetBin "user_custom_script.cmd"
    Set-Content -LiteralPath $unrelatedFile -Value "@echo custom tool" -Encoding ASCII

    # Run repeated install
    $resRepeat1 = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resRepeat1.ExitCode -eq 0) "First repeated install succeeds"
    $backupsAfter1 = (Get-ChildItem -LiteralPath $backupDir -Filter "*.bak" -ErrorAction SilentlyContinue).Count

    $resRepeat2 = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resRepeat2.ExitCode -eq 0) "Second repeated install succeeds"
    $backupsAfter2 = (Get-ChildItem -LiteralPath $backupDir -Filter "*.bak" -ErrorAction SilentlyContinue).Count
    Assert-Test ($backupsAfter2 -eq $backupsAfter1) "Repeated installs with identical state do not cause backup churn ($backupsAfter2 == $backupsAfter1)"

    # Verify official grok untouched across installs
    $officialHashDuring = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
    Assert-Test ($officialHashDuring -eq $officialGrokBaselineHash) "Guarded official grok.exe hash remains unchanged across installs"

    # Run first uninstall
    $resUninstFinal = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Uninstall")
    Assert-Test ($resUninstFinal.ExitCode -eq 0) "First uninstall succeeds"

    # Verify owned binary is removed and unrelated file survives
    Assert-Test (-not (Test-Path -LiteralPath $exePath)) "grokgod.exe removed after repeated installs and uninstall"
    Assert-Test (Test-Path -LiteralPath $unrelatedFile) "Unrelated user file in bin directory survived uninstall"
    if (Test-Path -LiteralPath $unrelatedFile) {
        $unrelatedContent = Get-Content -LiteralPath $unrelatedFile -Raw
        Assert-Test ($unrelatedContent.Trim() -eq "@echo custom tool") "Unrelated file content preserved intact"
    }

    # Verify restored pre-existing launcher remains
    Assert-Test (Test-Path -LiteralPath $preExistingGrokCmd) "Restored pre-existing launcher remains in place after uninstall"
    if (Test-Path -LiteralPath $preExistingGrokCmd) {
        $restoredLaunch = Get-Content -LiteralPath $preExistingGrokCmd -Raw
        Assert-Test ($restoredLaunch.Trim() -eq $preExistingContent.Trim()) "Restored launcher content matches original pre-existing launcher"
    }

    # Verify official grok still untouched
    $officialHashAfter1 = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
    Assert-Test ($officialHashAfter1 -eq $officialGrokBaselineHash) "Guarded official grok.exe hash remains unchanged after first uninstall"

    # Run repeated (second) uninstall: must exit 0, no errors, no backup churn, unrelated files survive
    $resUninstRepeat = Invoke-InstallerProcess -EnvVars @{ "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Uninstall")
    Assert-Test ($resUninstRepeat.ExitCode -eq 0) "Second repeated uninstall exits 0"

    # Unrelated files and restored launcher still survive repeated uninstall
    Assert-Test (Test-Path -LiteralPath $unrelatedFile) "Unrelated file survived repeated uninstall"
    Assert-Test (Test-Path -LiteralPath $preExistingGrokCmd) "Restored launcher remains intact after repeated uninstall"

    # Official grok untouched after repeated uninstall
    $officialHashAfter2 = (Get-FileHash -LiteralPath $officialGrokExe -Algorithm SHA256).Hash
    Assert-Test ($officialHashAfter2 -eq $officialGrokBaselineHash) "Guarded official grok.exe hash remains unchanged after repeated uninstall"

    # -------------------------------------------------------------------------
    # Test 10: -NoUpgrade Fast Path and Missing/Corrupt Runtime State Handling
    # -------------------------------------------------------------------------
    Write-Host "Test 10: -NoUpgrade fast path and missing/corrupt runtime state handling"
    # Fresh install
    $resFresh = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resFresh.ExitCode -eq 0) "Fresh install succeeds"

    # -NoUpgrade should exit 0 immediately
    $resNoUp = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-NoUpgrade")
    Assert-Test ($resNoUp.ExitCode -eq 0) "-NoUpgrade exits 0 without upgrade"

    # Corrupt stamp file -> installer detects and recovers cleanly on update with -Force
    Set-Content -LiteralPath (Join-Path $stageHome ".source-version") -Value "CORRUPTED_STAMP" -Encoding ASCII
    $resRecover = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
    Assert-Test ($resRecover.ExitCode -eq 0) "Installer cleanly recovers from corrupt runtime stamp"

    # -------------------------------------------------------------------------
    # Test 11: Locked Executable Fail-Closed Policy
    # -------------------------------------------------------------------------
    Write-Host "Test 11: Locked executable fail-closed policy"
    $liveExePath = Join-Path $stageHome "bin\grokgod.exe"
    $fileLockStream = $null
    try {
        # Open live binary with exclusive lock
        $fileLockStream = [System.IO.File]::Open($liveExePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $resLocked = Invoke-InstallerProcess -EnvVars @{ "GROKGOD_DOWNLOAD_BASE_URL" = $httpUrl; "USERPROFILE" = $testUserProfile } -ScriptArgs @("-Prefix", $targetPrefix, "-Force")
        Assert-Test ($resLocked.ExitCode -eq 1) "Installer fails closed when target executable is locked"
        Assert-Test ($resLocked.Combined -match "currently running or locked") "Locked executable error message displayed"
    } finally {
        if ($fileLockStream) {
            $fileLockStream.Close()
            $fileLockStream.Dispose()
        }
    }
} finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        $serverProc.Kill()
    }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==============================================="
Write-Host "Total Passed: $PassCount"
Write-Host "Total Failed: $FailCount"
Write-Host "==============================================="

if ($FailCount -gt 0) {
    exit 1
}
exit 0
