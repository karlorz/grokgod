#Requires -Version 5.1
<#
.SYNOPSIS
    grokgod Installer for Windows (EXPERIMENTAL)
.DESCRIPTION
    Installs prebuilt grokgod binary on Windows (x64/arm64) with shims.
.EXAMPLE
    irm https://github.com/karlorz/grokgod/releases/latest/download/install.ps1 | iex
    # or
    .\install.ps1 -Version 1.0.0
    .\install.ps1 -NoUpgrade
    .\install.ps1 -Uninstall
#>
param(
    [string]$Version = "latest",
    [switch]$NoUpgrade,
    [switch]$Uninstall,
    [string]$Prefix = ""
)

$ErrorActionPreference = "Stop"

if ($env:GROKGOD_VERSION -and $Version -eq "latest") { $Version = $env:GROKGOD_VERSION }
if ($env:GROKGOD_NO_UPGRADE -eq "1") { $NoUpgrade = [switch]$true }

$GrokgodDir = if ($Prefix) { Join-Path $Prefix "grokgod" } else { Join-Path $env:USERPROFILE ".grokgod" }
$BinDir     = if ($Prefix) { Join-Path $Prefix "bin" } else { Join-Path $env:USERPROFILE ".local\bin" }
$Repo       = "karlorz/grokgod"

function Write-OK($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Dim($msg)  { Write-Host "  $msg" -ForegroundColor DarkGray }

Write-Host "`n  grokgod Installer (Windows - EXPERIMENTAL)`n"

# ─── Uninstall ────────────────────────────────────────
if ($Uninstall) {
    $grokCmd = Join-Path $BinDir "grok.cmd"
    $grokOrig = Join-Path $BinDir "grok.orig.cmd"
    if (Test-Path $grokOrig) {
        Move-Item -Force $grokOrig $grokCmd
        Write-OK "Restored original grok launcher ($grokCmd)"
    } elseif ((Test-Path $grokCmd) -and (Select-String -Path $grokCmd -Pattern "grokgod" -Quiet -ErrorAction SilentlyContinue)) {
        Remove-Item -Force $grokCmd
        Write-OK "Removed grok launcher ($grokCmd)"
    }

    $grokgodCmd = Join-Path $BinDir "grokgod.cmd"
    if (Test-Path $grokgodCmd) {
        Remove-Item -Force $grokgodCmd
        Write-OK "Removed grokgod launcher ($grokgodCmd)"
    }

    if (Test-Path $GrokgodDir) {
        Remove-Item -Recurse -Force $GrokgodDir
        Write-OK "Removed grokgod directory ($GrokgodDir)"
    }
    Write-OK "grokgod uninstalled successfully"
    exit 0
}

# ─── Architecture Detection ───────────────────────────
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") { "arm64" } else { "x64" }
$assetName = "grokgod-windows-$arch.exe"
$targetDir = Join-Path $GrokgodDir "bin"
$targetExe = Join-Path $targetDir "grokgod.exe"
$stampFile = Join-Path $GrokgodDir ".source-version"

New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir    | Out-Null

# ─── Handle -NoUpgrade ────────────────────────────────
if ($NoUpgrade -and (Test-Path $targetExe)) {
    Write-OK "Existing binary found. Skipping download (-NoUpgrade)."
} else {
    $tmpDir = Join-Path $env:TEMP "grokgod-install-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        $tag = if ($Version -eq "latest") { "latest" } elseif ($Version -match "^v") { $Version } else { "v$Version" }
        $baseUrl = if ($tag -eq "latest") { "https://github.com/$Repo/releases/latest/download" } else { "https://github.com/$Repo/releases/download/$tag" }
        $dlUrl   = "$baseUrl/$assetName"
        $sumsUrl = "$baseUrl/SHA256SUMS"
        $destExe = Join-Path $tmpDir $assetName
        $destSums= Join-Path $tmpDir "SHA256SUMS"

        Write-Dim "Downloading $assetName from $dlUrl ..."
        Invoke-WebRequest -Uri $dlUrl -OutFile $destExe -UseBasicParsing
        Invoke-WebRequest -Uri $sumsUrl -OutFile $destSums -UseBasicParsing

        $actualHash = (Get-FileHash -Path $destExe -Algorithm SHA256).Hash.ToLower()
        $sumLines   = Get-Content $destSums
        $expectedHash = $null
        foreach ($line in $sumLines) {
            if ($line -match "$assetName") {
                $expectedHash = ($line -split '\s+')[0].ToLower()
                break
            }
        }
        if (-not $expectedHash -and $sumLines.Count -gt 0) {
            $expectedHash = ($sumLines[0] -split '\s+')[0].ToLower()
        }

        if (-not $expectedHash -or $actualHash -ne $expectedHash) {
            Write-Err "Checksum verification failed for $assetName (fail-closed)."
            Write-Err "Expected: $expectedHash; Actual: $actualHash"
            exit 1
        }
        Write-OK "Checksum verified: $actualHash"

        Move-Item -Force $destExe $targetExe
        Set-Content -Path $stampFile -Value "SHA=$actualHash`nPATCHSET=$tag`nVERSION=$tag`nMODE=release" -Encoding ASCII
        Write-OK "Binary installed to $targetExe"
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# ─── Install Command Shims ────────────────────────────
$cmdContent = @"
@echo off
set GROK_DISABLE_AUTOUPDATER=1
"$targetExe" %*
"@

$grokCmd = Join-Path $BinDir "grok.cmd"
$grokgodCmd = Join-Path $BinDir "grokgod.cmd"

if ((Test-Path $grokCmd) -and (-not (Select-String -Path $grokCmd -Pattern "GROK_DISABLE_AUTOUPDATER" -Quiet -ErrorAction SilentlyContinue))) {
    $grokOrig = Join-Path $BinDir "grok.orig.cmd"
    Move-Item -Force $grokCmd $grokOrig
    Write-OK "Backed up original grok command to $grokOrig"
}

Set-Content -Path $grokCmd -Value $cmdContent -Encoding ASCII
Set-Content -Path $grokgodCmd -Value $cmdContent -Encoding ASCII
Write-OK "Installed shims: $grokCmd and $grokgodCmd"
Write-OK "grokgod Windows installation complete!"
