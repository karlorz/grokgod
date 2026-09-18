#Requires -Version 5.1
<#
.SYNOPSIS
    grokgod Transactional Windows Installer and Lifecycle Manager
.DESCRIPTION
    Installs, updates, and uninstalls the prebuilt grokgod binary and Windows wrappers
    with full transactional safety:
      - Fail-closed early rejection of Windows ARM64 before any network operation
      - Fail-closed prefix overlap validation (never touches or overlaps official %USERPROFILE%\.grok)
      - Exact SHA256 checksum matching (single matching line for grokgod-windows-x64.exe)
      - Preflight validation of candidate binary (--version) before live mutation
      - Active/stale lock detection and atomic acquisition
      - Locked/running target binary detection with fail-closed message
      - Destination-volume sibling staging with bounded backups of all mutated files
      - Rollback to pristine prior state upon any failure or failure injection point
      - Durable manifest backups for clean uninstall restoration without clobbering restored files
      - Transaction journal persisted to manifest.json and install.journal
      - Self-contained bootstrap (downloads shims and updater when invoked via irm ... | iex)
      - Manifest-recorded ownership and commit point (manifest and .source-version written last)
      - Manifest-based clean uninstall restoring backups and never touching official grok.exe
.EXAMPLE
    .\install.ps1
    .\install.ps1 -Version 1.0.26
    .\install.ps1 -NoUpgrade
    .\install.ps1 -Force
    .\install.ps1 -Uninstall
#>
param(
    [string]$Version = "latest",
    [switch]$NoUpgrade,
    [switch]$Force,
    [switch]$Uninstall,
    [string]$Prefix = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure UTF-8 output encoding to avoid Unicode mojibake on Windows PowerShell 5.1
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Constants
$PINNED_BASE_SHA = "482711333c7195dc16a272777f86086d615e2afb"
$REPO_DEFAULT    = "karlorz/grokgod"
$TARGET_ASSET    = "grokgod-windows-x64.exe"

# Environment overrides
if ($env:GROKGOD_VERSION -and $Version -eq "latest") { $Version = $env:GROKGOD_VERSION }
if ($env:GROKGOD_NO_UPGRADE -eq "1") { $NoUpgrade = [switch]$true }
if ($env:GROKGOD_FORCE -eq "1") { $Force = [switch]$true }
$Repo = if ($env:GROKGOD_REPO) { $env:GROKGOD_REPO } else { $REPO_DEFAULT }

# Safe console messages (ASCII markers prevent console code page mojibake)
function Write-OK($msg)   { [Console]::Out.WriteLine("  [OK] $msg") }
function Write-Err($msg)  { [Console]::Error.WriteLine("  [ERR] $msg") }
function Write-Dim($msg)  { [Console]::Out.WriteLine("    $msg") }
function Write-Step($msg) { [Console]::Out.WriteLine("==> $msg") }

Write-Host "`n  grokgod Transactional Installer (Windows)`n"

# -----------------------------------------------------------------------------
# 1. Architecture Check (Reject ARM64 before any network access)
# -----------------------------------------------------------------------------
$procArch = $env:PROCESSOR_ARCHITECTURE
$arch6432 = $env:PROCESSOR_ARCHITEW6432
if (($procArch -and $procArch.ToUpper() -eq "ARM64") -or ($arch6432 -and $arch6432.ToUpper() -eq "ARM64")) {
    Write-Err "Unsupported platform: Windows ARM64 is not supported for grokgod in this delivery."
    Write-Err "Supported platform: Windows x64 (x86_64) only."
    exit 1
}

# -----------------------------------------------------------------------------
# 2. Path Resolution & Prefix Overlap Guard
# -----------------------------------------------------------------------------
function Normalize-DirPath([string]$p) {
    if (-not $p) { return "" }
    try {
        $full = [System.IO.Path]::GetFullPath($p)
        return $full.TrimEnd('\', '/')
    } catch {
        return $p.TrimEnd('\', '/')
    }
}

$OfficialGrokDirs = @()
$OfficialGrokExes = @()
if ($env:USERPROFILE) {
    $OfficialGrokDirs += Join-Path $env:USERPROFILE ".grok"
    $OfficialGrokExes += Join-Path $env:USERPROFILE ".grok\bin\grok.exe"
}
if ($env:LOCALAPPDATA) {
    $OfficialGrokDirs += Join-Path $env:LOCALAPPDATA "Programs\grok"
    $OfficialGrokDirs += Join-Path $env:LOCALAPPDATA "grok"
    $OfficialGrokExes += Join-Path $env:LOCALAPPDATA "Programs\grok\grok.exe"
    $OfficialGrokExes += Join-Path $env:LOCALAPPDATA "grok\grok.exe"
}

$GrokgodHome = ""
$BinDir      = ""

if ($Prefix) {
    $normPrefix = Normalize-DirPath $Prefix
    foreach ($officialDir in $OfficialGrokDirs) {
        $normOfficial = Normalize-DirPath $officialDir
        if ($normPrefix.Equals($normOfficial, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normPrefix.StartsWith($normOfficial + "\", [System.StringComparison]::OrdinalIgnoreCase) -or
            $normOfficial.StartsWith($normPrefix + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Err "Prefix rejection: Prefix '$Prefix' overlaps official grok home '$officialDir'."
            Write-Err "grokgod must not be installed into, under, or above an official Grok directory."
            exit 1
        }
    }
    $GrokgodHome = Join-Path $Prefix "grokgod"
    $BinDir      = Join-Path $Prefix "bin"
} else {
    $GrokgodHome = if ($env:GROKGOD_HOME) { $env:GROKGOD_HOME } else { Join-Path $env:USERPROFILE ".grokgod" }
    $BinDir      = if ($env:GROKGOD_BIN_DIR) { $env:GROKGOD_BIN_DIR } else { Join-Path $env:USERPROFILE ".local\bin" }
}

$GrokgodBinDir = Join-Path $GrokgodHome "bin"
$TargetExe     = Join-Path $GrokgodBinDir "grokgod.exe"
$StampFile     = Join-Path $GrokgodHome ".source-version"
$ManifestFile  = Join-Path $GrokgodHome "manifest.json"
$JournalFile   = Join-Path $GrokgodHome "install.journal"
$LockFile      = Join-Path $GrokgodHome "install.lock"
$BackupDir     = Join-Path $GrokgodHome "backups"

# Guard against accidental official grok mutation
function Assert-NotOfficialGrok([string]$filePath) {
    if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) { return }
    try {
        $checkFull = [System.IO.Path]::GetFullPath($filePath)
        foreach ($officialExe in $OfficialGrokExes) {
            $offFull = [System.IO.Path]::GetFullPath($officialExe)
            if ($checkFull.Equals($offFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to mutate official Grok executable at $filePath"
            }
        }
    } catch {
        if ($_.ToString() -match "Refusing to mutate") { throw $_ }
    }
}

# -----------------------------------------------------------------------------
# 3. Failure Injection Helper
# -----------------------------------------------------------------------------
function Test-FailureInjection([string]$point) {
    $inj = $env:GROKGOD_INSTALL_FAIL_AFTER
    if ($inj -and $inj.Trim().Equals($point, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Simulated failure injected after step '$point' (GROKGOD_INSTALL_FAIL_AFTER=$inj)"
    }
}

# -----------------------------------------------------------------------------
# 4. Lock Management (Atomic mutual exclusion & stale lock detection)
# -----------------------------------------------------------------------------
$script:HasLock = $false

function Acquire-InstallLock {
    if (-not (Test-Path -LiteralPath $GrokgodHome)) {
        New-Item -ItemType Directory -Force -Path $GrokgodHome | Out-Null
    }

    if (Test-Path -LiteralPath $LockFile) {
        $activeLockPid = $null
        try {
            $lines = Get-Content -LiteralPath $LockFile -ErrorAction Stop
            foreach ($line in $lines) {
                if ($line -match '^PID=(\d+)') {
                    $activeLockPid = [int]$matches[1]
                    break
                }
            }
        } catch {
            Write-Err "Another process holds an active lock on $LockFile"
            exit 1
        }

        if ($activeLockPid) {
            $isRunning = $false
            try {
                $proc = [System.Diagnostics.Process]::GetProcessById($activeLockPid)
                if ($proc -and -not $proc.HasExited) {
                    $isRunning = $true
                }
            } catch {
                $isRunning = $false
            }

            if ($isRunning) {
                Write-Err "Another installation or update process (PID $activeLockPid) is currently active."
                Write-Err "Lock file: $LockFile"
                exit 1
            } else {
                Write-Dim "Detected stale lock file from PID $activeLockPid. Clearing."
                Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            $lockAge = (Get-Date) - (Get-Item -LiteralPath $LockFile).LastWriteTime
            if ($lockAge.TotalMinutes -gt 10) {
                Write-Dim "Detected expired lock file. Clearing."
                Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Err "Installer lock file exists: $LockFile"
                exit 1
            }
        }
    }

    try {
        $fs = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $lockContent = "PID=$PID`r`nACQUIRED=" + (Get-Date).ToString("o") + "`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($lockContent)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        $fs.Close()
        $fs.Dispose()
        $script:HasLock = $true
    } catch {
        Write-Err "Failed to acquire exclusive installation lock at $LockFile : $_"
        exit 1
    }
}

function Release-InstallLock {
    if ($script:HasLock -and (Test-Path -LiteralPath $LockFile)) {
        try {
            $lines = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue
            if ($lines -match "^PID=$PID") {
                Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        $script:HasLock = $false
    }
}

# -----------------------------------------------------------------------------
# 5. Binary Lock Check
# -----------------------------------------------------------------------------
function Test-FileIsLocked([string]$filePath) {
    if (-not (Test-Path -LiteralPath $filePath)) { return $false }
    try {
        $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($fs) {
            $fs.Close()
            $fs.Dispose()
        }
        return $false
    } catch {
        return $true
    }
}

# -----------------------------------------------------------------------------
# 6. Manifest & State Helpers
# -----------------------------------------------------------------------------
function Read-Manifest {
    if (Test-Path -LiteralPath $ManifestFile) {
        try {
            $content = Get-Content -LiteralPath $ManifestFile -Raw -ErrorAction SilentlyContinue
            if ($content) {
                return (ConvertFrom-Json $content -ErrorAction SilentlyContinue)
            }
        } catch {}
    }
    return $null
}

function Write-ManifestFile($obj) {
    $json = $obj | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $ManifestFile -Value $json -Encoding UTF8
}

function Get-StampDict {
    $dict = @{}
    if (Test-Path -LiteralPath $StampFile) {
        try {
            $lines = Get-Content -LiteralPath $StampFile -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '^([^=]+)=(.*)$') {
                    $dict[$matches[1].Trim()] = $matches[2].Trim()
                }
            }
        } catch {}
    }
    return $dict
}

# Collision-safe deterministic backup naming
function Get-DurableBackupPath([string]$targetPath) {
    $norm = (Normalize-DirPath $targetPath).ToLower()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    $hashStr = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").Substring(0, 12).ToLower()
    $leaf = [System.IO.Path]::GetFileName($targetPath)
    return (Join-Path $BackupDir "$leaf-$hashStr.bak")
}

# -----------------------------------------------------------------------------
# 7. Uninstall Logic (Manifest-based)
# -----------------------------------------------------------------------------
if ($Uninstall) {
    Write-Step "Uninstalling grokgod..."
    Acquire-InstallLock
    try {
        $manifest = Read-Manifest
        $restoredPaths = @{}

        if ($manifest) {
            Write-Dim "Found ownership manifest (version $($manifest.formatVersion))."

            # 1. Restore backups recorded in manifest
            if ($manifest.backups) {
                foreach ($prop in $manifest.backups.PSObject.Properties) {
                    $origTarget = $prop.Name
                    $backupFile = $prop.Value
                    Assert-NotOfficialGrok $origTarget
                    if ($backupFile -and (Test-Path -LiteralPath $backupFile)) {
                        Write-Dim "Restoring backup: $backupFile -> $origTarget"
                        $targetParent = Split-Path -Path $origTarget -Parent
                        if (-not (Test-Path -LiteralPath $targetParent)) {
                            New-Item -ItemType Directory -Force -Path $targetParent | Out-Null
                        }
                        Copy-Item -LiteralPath $backupFile -Destination $origTarget -Force
                        Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
                        $restoredPaths[$origTarget.ToLower()] = $true
                        $restoredPaths[(Normalize-DirPath $origTarget).ToLower()] = $true
                        Write-OK "Restored $origTarget"
                    }
                }
            }

            # 2. Remove files recorded in manifest (ONLY IF NOT RESTORED ABOVE)
            if ($manifest.files) {
                foreach ($f in $manifest.files) {
                    Assert-NotOfficialGrok $f
                    $fNorm = (Normalize-DirPath $f).ToLower()
                    if ($restoredPaths.ContainsKey($fNorm) -or $restoredPaths.ContainsKey($f.ToLower())) {
                        Write-Dim "Preserving restored file: $f"
                        continue
                    }
                    if (Test-Path -LiteralPath $f) {
                        Write-Dim "Removing manifest-owned file: $f"
                        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                        Write-OK "Removed $f"
                    }
                }
            }
        } else {
            Write-Dim "No manifest found; checking known launcher locations..."
            $legacyGrokCmd    = Join-Path $BinDir "grok.cmd"
            $legacyGrokgodCmd = Join-Path $BinDir "grokgod.cmd"
            $grokOrigCmd      = Join-Path $BinDir "grok.orig.cmd"

            if (Test-Path -LiteralPath $grokOrigCmd) {
                Assert-NotOfficialGrok $legacyGrokCmd
                Move-Item -LiteralPath $grokOrigCmd -Destination $legacyGrokCmd -Force
                Write-OK "Restored original grok launcher ($legacyGrokCmd)"
            } elseif ((Test-Path -LiteralPath $legacyGrokCmd) -and (Select-String -Path $legacyGrokCmd -Pattern "grok-shim\.ps1|grokgod" -Quiet -ErrorAction SilentlyContinue)) {
                Assert-NotOfficialGrok $legacyGrokCmd
                Remove-Item -LiteralPath $legacyGrokCmd -Force
                Write-OK "Removed grok launcher ($legacyGrokCmd)"
            }

            if (Test-Path -LiteralPath $legacyGrokgodCmd) {
                Remove-Item -LiteralPath $legacyGrokgodCmd -Force
                Write-OK "Removed grokgod launcher ($legacyGrokgodCmd)"
            }

            if (Test-Path -LiteralPath $TargetExe) {
                Remove-Item -LiteralPath $TargetExe -Force -ErrorAction SilentlyContinue
                Write-OK "Removed $TargetExe"
            }
        }

        # Clean up manifest, stamp, journal
        if (Test-Path -LiteralPath $ManifestFile) {
            Remove-Item -LiteralPath $ManifestFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $StampFile) {
            Remove-Item -LiteralPath $StampFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $JournalFile) {
            Remove-Item -LiteralPath $JournalFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $BackupDir) {
            Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Clean empty directories if left empty
        if ((Test-Path -LiteralPath $GrokgodBinDir) -and ((Get-ChildItem -LiteralPath $GrokgodBinDir -Force | Measure-Object).Count -eq 0)) {
            Remove-Item -LiteralPath $GrokgodBinDir -Force -ErrorAction SilentlyContinue
        }
        $shimDir = Join-Path $GrokgodHome "shim"
        if (Test-Path -LiteralPath $shimDir) {
            Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $installedScript = Join-Path $GrokgodHome "install.ps1"
        if (Test-Path -LiteralPath $installedScript) {
            Remove-Item -LiteralPath $installedScript -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $GrokgodHome) -and ((Get-ChildItem -LiteralPath $GrokgodHome -Force | Measure-Object).Count -eq 0)) {
            Remove-Item -LiteralPath $GrokgodHome -Force -ErrorAction SilentlyContinue
        }

        Write-OK "grokgod uninstalled successfully."
    } finally {
        Release-InstallLock
    }
    exit 0
}

# -----------------------------------------------------------------------------
# 8. Check Running / Locked Target Executable
# -----------------------------------------------------------------------------
if (Test-Path -LiteralPath $TargetExe) {
    if (Test-FileIsLocked $TargetExe) {
        Write-Err "Target executable is currently running or locked by another process:"
        Write-Err "  $TargetExe"
        Write-Err "Please close any running grok or grokgod sessions before installing or updating."
        exit 1
    }
}

# -----------------------------------------------------------------------------
# 9. Tag & Version Resolution
# -----------------------------------------------------------------------------
$Tag = if ($Version -eq "latest") { "latest" } elseif ($Version -match "^v") { $Version } else { "v$Version" }
$Stamp = Get-StampDict
$CurrentSha = if ($Stamp.ContainsKey("SHA")) { $Stamp["SHA"] } else { "" }

# Idempotence check: if -NoUpgrade is specified and target exists
if ($NoUpgrade -and (Test-Path -LiteralPath $TargetExe) -and -not $Force) {
    Write-OK "Existing binary found at $TargetExe. Skipping download (-NoUpgrade)."
    exit 0
}

# Acquire installation lock
Acquire-InstallLock

# Ensure grokgod directories exist
New-Item -ItemType Directory -Force -Path $GrokgodHome   | Out-Null
New-Item -ItemType Directory -Force -Path $GrokgodBinDir| Out-Null
New-Item -ItemType Directory -Force -Path $BinDir       | Out-Null
New-Item -ItemType Directory -Force -Path $BackupDir    | Out-Null

# -----------------------------------------------------------------------------
# 10. Download & Verification in Temp Directory
# -----------------------------------------------------------------------------
$BaseUrl = if ($env:GROKGOD_DOWNLOAD_BASE_URL) {
    $env:GROKGOD_DOWNLOAD_BASE_URL.TrimEnd('/')
} elseif ($Tag -eq "latest") {
    "https://github.com/$Repo/releases/latest/download"
} else {
    "https://github.com/$Repo/releases/download/$Tag"
}

$CandidateSibling = Join-Path $GrokgodBinDir "candidate-$([Guid]::NewGuid().ToString('N')).exe"
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "grokgod-install-$([Guid]::NewGuid().ToString('N'))"
$ActualHash = ""
$IsAlreadyUpToDate = $false

New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    $DownloadedExe  = Join-Path $TmpDir $TARGET_ASSET
    $DownloadedSums = Join-Path $TmpDir "SHA256SUMS"

    $DlUrl   = "$BaseUrl/$TARGET_ASSET"
    $SumsUrl = "$BaseUrl/SHA256SUMS"

    Write-Step "Downloading $TARGET_ASSET and SHA256SUMS from $BaseUrl ..."
    try {
        Invoke-WebRequest -Uri $DlUrl -OutFile $DownloadedExe -UseBasicParsing
        Invoke-WebRequest -Uri $SumsUrl -OutFile $DownloadedSums -UseBasicParsing
    } catch {
        throw "Failed to download release assets from $BaseUrl : $_"
    }

    if (-not (Test-Path -LiteralPath $DownloadedExe) -or -not (Test-Path -LiteralPath $DownloadedSums)) {
        throw "Download failed: required files missing in $TmpDir."
    }

    # Checksum parsing: parse SHA256SUMS for TARGET_ASSET and runtime scripts
    $SumsContent = Get-Content -LiteralPath $DownloadedSums -ErrorAction Stop
    $ChecksumMap = @{}

    foreach ($line in $SumsContent) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed -split '\s+', 2
        if ($parts.Count -ge 2) {
            $hashPart = $parts[0].Trim().ToLower()
            $filePart = $parts[1].Trim().TrimStart('*')
            if ($ChecksumMap.ContainsKey($filePart)) {
                throw "Verification failed: Multiple checksum entries found for '$filePart' in SHA256SUMS."
            }
            $ChecksumMap[$filePart] = $hashPart
        }
    }

    if (-not $ChecksumMap.ContainsKey($TARGET_ASSET)) {
        throw "Verification failed: No checksum entry found for '$TARGET_ASSET' in SHA256SUMS."
    }

    $ExpectedHash = $ChecksumMap[$TARGET_ASSET]
    $ActualHash   = (Get-FileHash -LiteralPath $DownloadedExe -Algorithm SHA256).Hash.ToLower()

    if ($ActualHash -ne $ExpectedHash) {
        throw "Checksum verification failed for $TARGET_ASSET (fail-closed). Expected: $ExpectedHash, Actual: $ActualHash"
    }
    Write-OK "Checksum verified: $ActualHash"

    # Preflight candidate execution: run --version before ANY live mutation
    Write-Step "Running candidate preflight verification ($TARGET_ASSET --version)..."
    $candidateVer = ""
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $DownloadedExe
        $psi.Arguments = "--version"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(5000) | Out-Null
        if ($proc.ExitCode -eq 0) {
            $candidateVer = ($out -split "[\r\n]+") | Where-Object { $_ -match '\S' } | Select-Object -First 1
        } else {
            throw "Preflight failed: candidate exited with code $($proc.ExitCode). StdErr: $err"
        }
    } catch {
        throw "Preflight failed to execute candidate: $_"
    }

    Write-OK "Preflight verified candidate binary: $candidateVer"

    # Check if already up to date when not forced
    if (-not $Force -and (Test-Path -LiteralPath $TargetExe) -and ($CurrentSha -eq $ActualHash)) {
        $IsAlreadyUpToDate = $true
    } else {
        # Stage candidate as sibling on DESTINATION VOLUME ($GrokgodBinDir)
        Copy-Item -LiteralPath $DownloadedExe -Destination $CandidateSibling -Force

        # Stage and verify runtime scripts in destination volume prior to live activation
        $RequiredRuntimeScripts = @("grok-shim.ps1", "LauncherHelpers.ps1", "install.ps1")
        $RuntimeStagedFiles = @{}

        # Resolve invariant local source locations once for all runtime assets.
        $repoRootLocal = if ($PSScriptRoot) {
            if (Test-Path (Join-Path $PSScriptRoot "src\shim\grok-shim.ps1")) {
                $PSScriptRoot
            } elseif (Test-Path (Join-Path $PSScriptRoot "..\..\src\shim\grok-shim.ps1")) {
                Normalize-DirPath (Join-Path $PSScriptRoot "..\..")
            } elseif (Test-Path (Join-Path $PSScriptRoot "..\src\shim\grok-shim.ps1")) {
                Normalize-DirPath (Join-Path $PSScriptRoot "..")
            } else { "" }
        } else { "" }
        $thisInvPath = $MyInvocation.MyCommand.Path
        $externalInstallSource = $null
        if ($thisInvPath -and (Test-Path -LiteralPath $thisInvPath)) {
            $normThis = Normalize-DirPath $thisInvPath
            $normInstalledSelf = Normalize-DirPath (Join-Path $GrokgodHome "install.ps1")
            if (-not $normThis.Equals($normInstalledSelf, [System.StringComparison]::OrdinalIgnoreCase)) {
                $externalInstallSource = $thisInvPath
            }
        }

        foreach ($scriptName in $RequiredRuntimeScripts) {
            $stagedScriptPath = Join-Path $GrokgodHome "bin\candidate-$scriptName-$([Guid]::NewGuid().ToString('N')).ps1"

            # Check local source candidates first (e.g. repo checkout or $env:GROKGOD_SRC)
            # IMPORTANT: Do NOT read existing destination files ($installedShimPs1 etc) as upgrade candidates!
            $foundLocal = $null
            $candidatesToCheck = @()
            if ($repoRootLocal) {
                if ($scriptName -eq "install.ps1") {
                    $candidatesToCheck += (Join-Path $repoRootLocal "install.ps1")
                } else {
                    $candidatesToCheck += (Join-Path $repoRootLocal "src\shim\$scriptName")
                }
            }
            if ($env:GROKGOD_SRC) {
                if ($scriptName -eq "install.ps1") {
                    $candidatesToCheck += (Join-Path $env:GROKGOD_SRC "install.ps1")
                } else {
                    $candidatesToCheck += (Join-Path $env:GROKGOD_SRC "src\shim\$scriptName")
                }
            }
            # Only use the invocation path if it is an external repo checkout, NOT an installed copy.
            if ($scriptName -eq "install.ps1" -and $externalInstallSource) {
                $candidatesToCheck += $externalInstallSource
            }

            foreach ($cand in $candidatesToCheck) {
                if ($cand -and (Test-Path -LiteralPath $cand)) {
                    $foundLocal = $cand
                    break
                }
            }

            if ($foundLocal) {
                Copy-Item -LiteralPath $foundLocal -Destination $stagedScriptPath -Force
            } else {
                # Download from release base URL
                $scriptDlUrl = "$BaseUrl/$scriptName"
                Write-Dim "Downloading runtime asset $scriptName from $scriptDlUrl ..."
                $tmpScriptDl = Join-Path $TmpDir $scriptName
                try {
                    Invoke-WebRequest -Uri $scriptDlUrl -OutFile $tmpScriptDl -UseBasicParsing
                } catch {
                    throw "Failed to download required runtime asset '$scriptName' from $scriptDlUrl : $_"
                }
                if (-not (Test-Path -LiteralPath $tmpScriptDl)) {
                    throw "Download failed for runtime asset '$scriptName'."
                }

                # Verify checksum against SHA256SUMS fail-closed
                if (-not $ChecksumMap.ContainsKey($scriptName)) {
                    throw "Verification failed: No checksum entry found for runtime asset '$scriptName' in SHA256SUMS."
                }
                $expScriptHash = $ChecksumMap[$scriptName]
                $actScriptHash = (Get-FileHash -LiteralPath $tmpScriptDl -Algorithm SHA256).Hash.ToLower()
                if ($actScriptHash -ne $expScriptHash) {
                    throw "Checksum verification failed for runtime asset $scriptName (fail-closed). Expected: $expScriptHash, Actual: $actScriptHash"
                }
                Write-OK "Verified runtime asset checksum: $scriptName ($actScriptHash)"
                Copy-Item -LiteralPath $tmpScriptDl -Destination $stagedScriptPath -Force
            }

            $RuntimeStagedFiles[$scriptName] = $stagedScriptPath
        }
    }
} catch {
    Write-Err $_
    Release-InstallLock
    exit 1
} finally {
    if (Test-Path -LiteralPath $TmpDir) {
        Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($IsAlreadyUpToDate) {
    Write-OK "Already up to date ($ActualHash). Skipping mutation."
    Release-InstallLock
    exit 0
}

# -----------------------------------------------------------------------------
# 11. Transactional Activation & Rollback Engine
# -----------------------------------------------------------------------------
$TxStagingDir = Join-Path $GrokgodHome "backups\tx-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $TxStagingDir | Out-Null

$TxJournal = @()
function Tx-Log($msg) {
    $script:TxJournal += ("[" + (Get-Date).ToString("o") + "] " + $msg)
}

# Load prior manifest (to preserve original pre-grokgod backups on update)
$PriorManifest = Read-Manifest
$DurableBackups = @{}
if ($PriorManifest -and $PriorManifest.backups) {
    foreach ($prop in $PriorManifest.backups.PSObject.Properties) {
        $DurableBackups[$prop.Name] = $prop.Value
    }
}

$TxSnapshots       = @{}   # TargetPath -> StagingSnapshotPath (for rollback of this tx)
$TxCreatedFiles    = @()   # Paths newly created during this transaction
$NewDurableBackups = @()   # New durable backups created during this transaction

function Tx-BackupTarget([string]$path, [bool]$PreserveOnUninstall = $false) {
    Assert-NotOfficialGrok $path
    if (Test-Path -LiteralPath $path) {
        # Rollback snapshot for this transaction.
        $snapName = [Guid]::NewGuid().ToString('N') + ".snap"
        $snapPath = Join-Path $TxStagingDir $snapName
        Copy-Item -LiteralPath $path -Destination $snapPath -Force
        $script:TxSnapshots[$path] = $snapPath
        Tx-Log "Snapshotted $path -> $snapPath"

        # Durable backups are only for pre-existing user-owned launchers.
        if ($PreserveOnUninstall -and -not $script:DurableBackups.ContainsKey($path)) {
            $bpath = Get-DurableBackupPath $path
            Copy-Item -LiteralPath $path -Destination $bpath -Force
            $script:DurableBackups[$path] = $bpath
            $script:NewDurableBackups += $bpath
            Tx-Log "Created durable backup $path -> $bpath"
        }
    } else {
        $script:TxCreatedFiles += $path
        Tx-Log "Marked $path as newly created"
    }
}

function Tx-Rollback {
    Write-Err "Transaction failed. Initiating automatic rollback..."
    Tx-Log "Initiating rollback"

    # 1. Remove newly created files
    foreach ($f in $script:TxCreatedFiles) {
        Assert-NotOfficialGrok $f
        if (Test-Path -LiteralPath $f) {
            try {
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                Write-Dim "Rollback removed created file: $f"
            } catch {}
        }
    }

    # 2. Restore modified files from transaction snapshots
    foreach ($targetPath in $script:TxSnapshots.Keys) {
        $snap = $script:TxSnapshots[$targetPath]
        Assert-NotOfficialGrok $targetPath
        if (Test-Path -LiteralPath $snap) {
            try {
                Copy-Item -LiteralPath $snap -Destination $targetPath -Force
                Write-Dim "Rollback restored: $targetPath"
            } catch {
                Write-Err "Rollback failed to restore $targetPath : $_"
            }
        }
    }

    # 3. Clean up new durable backups created during this aborted transaction
    foreach ($db in $script:NewDurableBackups) {
        if (Test-Path -LiteralPath $db) {
            Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue
        }
    }

    # 4. Clean up candidate sibling and staged runtime files
    if (Test-Path -LiteralPath $CandidateSibling) {
        Remove-Item -LiteralPath $CandidateSibling -Force -ErrorAction SilentlyContinue
    }
    if ($RuntimeStagedFiles) {
        foreach ($sf in $RuntimeStagedFiles.Values) {
            if ($sf -and (Test-Path -LiteralPath $sf)) {
                Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 5. Clean up TxStagingDir
    if (Test-Path -LiteralPath $TxStagingDir) {
        Remove-Item -LiteralPath $TxStagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Err "Rollback complete. System returned to pristine prior state."
}

try {
    Write-Step "Creating transaction snapshots of prior components..."
    Tx-BackupTarget $TargetExe
    Tx-BackupTarget $StampFile
    Tx-BackupTarget $ManifestFile
    Tx-BackupTarget $JournalFile

    $grokCmdPath    = Join-Path $BinDir "grok.cmd"
    $grokgodCmdPath = Join-Path $BinDir "grokgod.cmd"
    Tx-BackupTarget $grokCmdPath $true
    Tx-BackupTarget $grokgodCmdPath $true

    $installedShimDir = Join-Path $GrokgodHome "shim"
    $installedShimPs1 = Join-Path $installedShimDir "grok-shim.ps1"
    $installedHelpers = Join-Path $installedShimDir "LauncherHelpers.ps1"
    $installedSelf    = Join-Path $GrokgodHome "install.ps1"

    Tx-BackupTarget $installedShimPs1
    Tx-BackupTarget $installedHelpers
    Tx-BackupTarget $installedSelf

    # Failure injection point: 'backup'
    Test-FailureInjection "backup"

    # -------------------------------------------------------------------------
    # Activation: Move sibling candidate to target binary
    # -------------------------------------------------------------------------
    Write-Step "Activating candidate binary..."
    Assert-NotOfficialGrok $TargetExe
    Move-Item -LiteralPath $CandidateSibling -Destination $TargetExe -Force
    Tx-Log "Moved candidate to $TargetExe"

    # Failure injection point: 'activation'
    Test-FailureInjection "activation"

    # -------------------------------------------------------------------------
    # Install Wrapper Runtime into grokgod home
    # -------------------------------------------------------------------------
    Write-Step "Installing wrapper runtime to $installedShimDir ..."
    New-Item -ItemType Directory -Force -Path $installedShimDir | Out-Null

    # Move staged runtime scripts into place (guaranteeing refresh on upgrade)
    Move-Item -LiteralPath $RuntimeStagedFiles["grok-shim.ps1"] -Destination $installedShimPs1 -Force
    Move-Item -LiteralPath $RuntimeStagedFiles["LauncherHelpers.ps1"] -Destination $installedHelpers -Force
    Move-Item -LiteralPath $RuntimeStagedFiles["install.ps1"] -Destination $installedSelf -Force

    Tx-Log "Installed wrapper runtime scripts"

    # -------------------------------------------------------------------------
    # Launcher Generation via New-GrokgodLauncherScript
    # -------------------------------------------------------------------------
    Write-Step "Generating command launchers via LauncherHelpers..."
    . $installedHelpers

    Assert-NotOfficialGrok $grokCmdPath
    Assert-NotOfficialGrok $grokgodCmdPath

    $grokCmdContent = New-GrokgodLauncherScript -Identity "grok" -ShimPath $installedShimPs1
    $grokgodCmdContent = New-GrokgodLauncherScript -Identity "grokgod" -ShimPath $installedShimPs1

    Set-Content -LiteralPath $grokCmdPath -Value $grokCmdContent -Encoding ASCII
    Tx-Log "Wrote launcher $grokCmdPath"
    # Failure injection point: 'launcher-grok'
    Test-FailureInjection "launcher-grok"

    Set-Content -LiteralPath $grokgodCmdPath -Value $grokgodCmdContent -Encoding ASCII
    Tx-Log "Wrote launcher $grokgodCmdPath"
    # Failure injection point: 'launcher-grokgod'
    Test-FailureInjection "launcher-grokgod"

    # -------------------------------------------------------------------------
    # Stamp & Manifest Generation (Commit Point: Written Last)
    # -------------------------------------------------------------------------
    Write-Step "Writing .source-version and manifest (commit point)..."
    $stampContent = @"
SHA=$ActualHash
PATCHSET=$Tag
VERSION=$PINNED_BASE_SHA
MODE=release
"@
    Set-Content -LiteralPath $StampFile -Value $stampContent -Encoding ASCII
    Tx-Log "Wrote $StampFile"
    # Failure injection point: 'stamp'
    Test-FailureInjection "stamp"

    # Persist transaction journal to install.journal
    Tx-Log "Committing transaction"
    Set-Content -LiteralPath $JournalFile -Value ($script:TxJournal -join "`r`n") -Encoding UTF8

    # Compile manifest
    $allOwnedFiles = @(
        $TargetExe,
        $StampFile,
        $ManifestFile,
        $JournalFile,
        $grokCmdPath,
        $grokgodCmdPath,
        $installedShimPs1,
        $installedHelpers,
        $installedSelf
    )

    $manifestObj = [PSCustomObject]@{
        formatVersion   = 1
        installedAt     = (Get-Date).ToString("o")
        artifactSha256  = $ActualHash
        patchset        = $Tag
        sourceSha       = $PINNED_BASE_SHA
        mode            = "release"
        targetExe       = $TargetExe
        binDir          = $BinDir
        grokgodHome     = $GrokgodHome
        files           = $allOwnedFiles
        backups         = $script:DurableBackups
        journal         = $script:TxJournal
    }

    Write-ManifestFile $manifestObj
    Tx-Log "Committed manifest $ManifestFile"

    # Cleanup temporary transaction snapshots on success (durable backups remain in $BackupDir)
    if (Test-Path -LiteralPath $TxStagingDir) {
        Remove-Item -LiteralPath $TxStagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $CandidateSibling) {
        Remove-Item -LiteralPath $CandidateSibling -Force -ErrorAction SilentlyContinue
    }
    Release-InstallLock

    Write-OK "grokgod Windows installation succeeded!"
    Write-OK "Installed binary:    $TargetExe"
    Write-OK "Installed launchers: $grokCmdPath and $grokgodCmdPath"
    Write-OK "Stamp recorded:      SHA=$ActualHash PATCHSET=$Tag VERSION=$PINNED_BASE_SHA"
    exit 0

} catch {
    Write-Err "Installation failed: $_"
    Tx-Rollback
    Release-InstallLock
    exit 1
}
