#Requires -Version 5.1
<#
.SYNOPSIS
    grokgod Windows Dispatcher / Shim
.DESCRIPTION
    Dispatches commands for grok and grokgod launchers on Windows:
      - grok update [allowed args] -> installed updater
      - grok status [--json] -> wrapper status, never TUI
      - grok [any other args] (including grok sessions ...) -> patched binary with GROK_DISABLE_AUTOUPDATER=1
      - grokgod update [allowed args] -> wrapper update
      - grokgod status [--json] -> wrapper status
      - grokgod sessions / cache / other unsupported maintenance -> explicit Windows error, never TUI
    Preserves exact arguments and exit codes.
    Consumes raw $args directly to avoid named parameter binding on dashed arguments in PS 5.1/7.
#>

# Enforce strict parsing
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Capture dispatcher script path reliably at script scope
$DispatcherScriptPath = if ($PSCommandPath) {
    $PSCommandPath
} elseif ($MyInvocation -and $MyInvocation.PSCommandPath) {
    $MyInvocation.PSCommandPath
} else {
    ""
}

# Dispatcher requires at least one argument: the launcher identity ('grok' or 'grokgod')
if ($args.Count -lt 1) {
    [Console]::Error.WriteLine("error: missing launcher identity. First argument must be 'grok' or 'grokgod'.")
    exit 1
}

$Identity = [string]$args[0]
$normIdentity = "$Identity".ToLower().Trim()
if ($normIdentity -ne "grok" -and $normIdentity -ne "grokgod" -and $normIdentity -ne "__grokgod_update_refresh") {
    [Console]::Error.WriteLine("error: invalid identity '$Identity'. First argument must be 'grok' or 'grokgod'.")
    exit 1
}

# Remaining application arguments
[string[]]$cmdArgs = @()
if ($args -and $args.Count -gt 1) {
    for ($i = 1; $i -lt $args.Count; $i++) {
        $cmdArgs += [string]$args[$i]
    }
}

# -----------------------------------------------------------------------------
# Configuration & Paths
# -----------------------------------------------------------------------------
$GrokgodHome = if ($env:GROKGOD_HOME) { $env:GROKGOD_HOME } else { Join-Path $env:USERPROFILE ".grokgod" }
$PatchedExe  = if ($env:GROKGOD_BIN)  { $env:GROKGOD_BIN }  else { Join-Path $GrokgodHome "bin\grokgod.exe" }
$StampFile   = Join-Path $GrokgodHome ".source-version"
$ManifestFile = Join-Path $GrokgodHome "manifest.json"

# Candidate official grok locations on Windows:
# 1. Official installer default in LocalAppData: %LOCALAPPDATA%\Programs\grok\grok.exe
# 2. User profile default: %USERPROFILE%\.grok\bin\grok.exe
# 3. %LOCALAPPDATA%\grok\grok.exe
function Find-OfficialGrok {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA "Programs\grok\grok.exe"
        $candidates += Join-Path $env:LOCALAPPDATA "grok\grok.exe"
    }
    if ($env:USERPROFILE) {
        $candidates += Join-Path $env:USERPROFILE ".grok\bin\grok.exe"
    }
    foreach ($cand in $candidates) {
        if (Test-Path -LiteralPath $cand) {
            # Make sure it is not pointing back to our own patched binary
            try {
                $candFull = (Get-Item -LiteralPath $cand).FullName
                $patchFull = if (Test-Path -LiteralPath $PatchedExe) { (Get-Item -LiteralPath $PatchedExe).FullName } else { "" }
                if ($candFull -ne $patchFull) {
                    return $candFull
                }
            } catch {
                return $cand
            }
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# Helper: Free Disk Bytes
# -----------------------------------------------------------------------------
function Get-FreeDiskBytes([string]$targetPath) {
    try {
        $checkPath = $targetPath
        while (-not (Test-Path -LiteralPath $checkPath) -and -not [string]::IsNullOrEmpty($checkPath)) {
            $parent = Split-Path -Path $checkPath -Parent
            if ($parent -eq $checkPath) { break }
            $checkPath = $parent
        }
        if (-not (Test-Path -LiteralPath $checkPath)) {
            $checkPath = $env:SystemDrive
            if (-not $checkPath) { $checkPath = "C:" }
            $checkPath += "\"
        }
        $full = [System.IO.Path]::GetFullPath($checkPath)
        $driveLetter = [System.IO.Path]::GetPathRoot($full)
        if ($driveLetter) {
            $drive = New-Object System.IO.DriveInfo($driveLetter)
            if ($drive.IsReady) {
                return $drive.AvailableFreeSpace
            }
        }
    } catch {}
    return $null
}

# -----------------------------------------------------------------------------
# Helper: Stamp Parsing
# -----------------------------------------------------------------------------
function Get-StampMap([string]$path) {
    $map = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $lines = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '^([^=]+)=(.*)$') {
                    $key = $matches[1].Trim()
                    $val = $matches[2].Trim()
                    $map[$key] = $val
                }
            }
        } catch {}
    }
    return $map
}

# -----------------------------------------------------------------------------
# Helpers: Release Update Notice (cached immediately, refresh detached)
# -----------------------------------------------------------------------------
function Test-ReleaseVersion([string]$version) {
    return [bool]($version -match '^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$')
}

function Test-VersionCoreGreater([string]$candidate, [string]$installed) {
    if (-not (Test-ReleaseVersion $candidate) -or -not (Test-ReleaseVersion $installed)) {
        return $false
    }

    [void]($candidate -match '^v([0-9]+)\.([0-9]+)\.([0-9]+)')
    $candidateCore = @($matches[1], $matches[2], $matches[3])
    [void]($installed -match '^v([0-9]+)\.([0-9]+)\.([0-9]+)')
    $installedCore = @($matches[1], $matches[2], $matches[3])
    for ($i = 0; $i -lt 3; $i++) {
        $candidatePart = $candidateCore[$i].TrimStart([char]'0')
        $installedPart = $installedCore[$i].TrimStart([char]'0')
        if ($candidatePart.Length -eq 0) { $candidatePart = '0' }
        if ($installedPart.Length -eq 0) { $installedPart = '0' }
        if ($candidatePart.Length -gt $installedPart.Length) { return $true }
        if ($candidatePart.Length -lt $installedPart.Length) { return $false }
        $comparison = [string]::CompareOrdinal($candidatePart, $installedPart)
        if ($comparison -gt 0) { return $true }
        if ($comparison -lt 0) { return $false }
    }
    return $false
}

function Get-UpdateCacheData([string]$path) {
    $data = @{ CheckedAt = $null; Version = $null }
    if (-not (Test-Path -LiteralPath $path)) { return $data }
    try {
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ($line -match '^CHECKED_AT=([0-9]+)$') { $data.CheckedAt = [Int64]$matches[1] }
            if ($line -match '^VERSION=(.+)$') { $data.Version = [string]$matches[1] }
        }
    } catch {}
    return $data
}

function Set-UpdateCache([string]$path, [Int64]$checkedAt, [string]$version) {
    $tempPath = "$path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        $content = "CHECKED_AT=$checkedAt`n"
        if (Test-ReleaseVersion $version) { $content += "VERSION=$version`n" }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, $content, $utf8NoBom)
        if (Test-Path -LiteralPath $path) {
            [System.IO.File]::Replace($tempPath, $path, $null)
        } else {
            [System.IO.File]::Move($tempPath, $path)
        }
        return $true
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-UpdateCacheRefresh([string]$cachePath, [string]$url, [Int64]$checkedAt) {
    try {
        $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'grokgod' }
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers $headers -TimeoutSec 5 -ErrorAction Stop
        $payload = ConvertFrom-Json ([string]$response.Content) -ErrorAction Stop
        $latestVersion = [string]$payload.tag_name
        if (Test-ReleaseVersion $latestVersion) {
            [void](Set-UpdateCache -path $cachePath -checkedAt $checkedAt -version $latestVersion)
        }
    } catch {}
}

function Start-UpdateCacheRefresh([string]$cachePath, [string]$url, [Int64]$checkedAt) {
    try {
        $hostExe = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not $hostExe -or -not $script:DispatcherScriptPath) { return }
        $refreshArgs = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:DispatcherScriptPath,
            '__grokgod_update_refresh', $cachePath, $url, ([string]$checkedAt)
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $hostExe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.Arguments = ConvertTo-WindowsCommandLine -ArgumentList $refreshArgs
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {}
}

function Invoke-ReleaseUpdateCheck {
    if ($env:GROKGOD_UPDATE_CHECK_DISABLE -eq '1') { return }

    $stamp = Get-StampMap -path $StampFile
    if (-not $stamp.ContainsKey('MODE') -or -not $stamp.ContainsKey('VERSION')) { return }
    $installedVersion = [string]$stamp['VERSION']
    if ([string]$stamp['MODE'] -ne 'release' -or -not (Test-ReleaseVersion $installedVersion)) { return }

    $cachePath = Join-Path $GrokgodHome '.update-check'
    $cache = Get-UpdateCacheData -path $cachePath
    $cachedVersion = [string]$cache.Version
    if ((Test-ReleaseVersion $cachedVersion) -and (Test-VersionCoreGreater $cachedVersion $installedVersion)) {
        $notice = '[grokgod] ' + $cachedVersion + ' available (installed: ' + $installedVersion + ') ' + [char]0x2014 + " run 'grok update' to upgrade"
        [Console]::Error.WriteLine($notice)
    }

    $unixEpoch = [DateTimeOffset]::Parse('1970-01-01T00:00:00Z')
    $now = [Int64][Math]::Floor(([DateTimeOffset]::UtcNow - $unixEpoch).TotalSeconds)
    $refreshDue = ($cache.CheckedAt -eq $null -or $cache.CheckedAt -gt $now -or ($now - [Int64]$cache.CheckedAt) -ge 86400)
    if (-not $refreshDue) { return }

    # Record this refresh window atomically before spawning the network child.
    $preservedVersion = if (Test-ReleaseVersion $cachedVersion) { $cachedVersion } else { $null }
    if (-not (Set-UpdateCache -path $cachePath -checkedAt $now -version $preservedVersion)) { return }
    $updateUrl = if ($env:GROKGOD_UPDATE_CHECK_URL) { $env:GROKGOD_UPDATE_CHECK_URL } else { 'https://api.github.com/repos/karlorz/grokgod/releases/latest' }
    Start-UpdateCacheRefresh -cachePath $cachePath -url $updateUrl -checkedAt $now
}

# -----------------------------------------------------------------------------
# Helper: Windows native command-line argument quoting
# -----------------------------------------------------------------------------
function ConvertTo-WindowsCommandLine([string[]]$ArgumentList) {
    $escapedArguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $ArgumentList) {
        if ($argument -eq "") {
            [void]$escapedArguments.Add('""')
        } elseif ($argument -match '[\s"]|\\$') {
            $escaped = $argument -replace '(\\*)(")', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            [void]$escapedArguments.Add(('"' + $escaped + '"'))
        } else {
            [void]$escapedArguments.Add($argument)
        }
    }
    return [string]::Join(" ", $escapedArguments.ToArray())
}

# -----------------------------------------------------------------------------
# Helper: Read Version from Binary via execution
# -----------------------------------------------------------------------------
function Get-BinaryReportedVersion([string]$exePath) {
    if (-not (Test-Path -LiteralPath $exePath)) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exePath
        $psi.Arguments = "--version"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit(3000) | Out-Null
        if ($proc.ExitCode -eq 0) {
            $line = ($out -split "[\r\n]+") | Where-Object { $_ -match '\S' } | Select-Object -First 1
            if ($line) { return $line.Trim() }
        }
    } catch {}
    return $null
}

# -----------------------------------------------------------------------------
# Status Command
# -----------------------------------------------------------------------------
function Invoke-StatusCommand([bool]$AsJson) {
    $stamp = Get-StampMap -path $StampFile
    $patchExists = Test-Path -LiteralPath $PatchedExe
    $stampExists = Test-Path -LiteralPath $StampFile

    $artifactSha = $null
    $patchset    = $null
    $sourceSha   = $null
    $mode        = $null

    if ($stampExists) {
        if ($stamp.ContainsKey("SHA"))      { $artifactSha = $stamp["SHA"] }
        if ($stamp.ContainsKey("PATCHSET")) { $patchset    = $stamp["PATCHSET"] }
        if ($stamp.ContainsKey("VERSION"))  { $sourceSha   = $stamp["VERSION"] }
        if ($stamp.ContainsKey("MODE"))     { $mode        = $stamp["MODE"] }
    }

    # If manifest.json exists, load any supplemental metadata
    if (Test-Path -LiteralPath $ManifestFile) {
        try {
            $manifestRaw = Get-Content -LiteralPath $ManifestFile -Raw -ErrorAction SilentlyContinue
            if ($manifestRaw) {
                $manifestObj = ConvertFrom-Json $manifestRaw -ErrorAction SilentlyContinue
                if ($manifestObj) {
                    if (-not $artifactSha -and $manifestObj.artifactSha256) { $artifactSha = $manifestObj.artifactSha256 }
                    if (-not $patchset -and $manifestObj.patchset) { $patchset = $manifestObj.patchset }
                    if (-not $sourceSha -and $manifestObj.sourceSha) { $sourceSha = $manifestObj.sourceSha }
                }
            }
        } catch {}
    }

    # Health evaluation:
    # - healthy: binary exists, stamp exists and has SHA, binary SHA matches stamp (or binary is intact)
    # - degraded: binary exists, but official binary is also present and newer / version skew, OR stamp missing
    # - corrupt: binary missing or binary file exists but SHA mismatch / execution fails
    $health = "healthy"
    $healthDetails = @()
    $computedSha = $null

    if (-not $patchExists) {
        $health = "corrupt"
        $healthDetails += "Patched binary missing at: $PatchedExe"
    } else {
        try {
            $fileHash = Get-FileHash -LiteralPath $PatchedExe -Algorithm SHA256 -ErrorAction Stop
            $computedSha = $fileHash.Hash.ToLower()
        } catch {
            $health = "corrupt"
            $healthDetails += "Failed to compute hash for patched binary: $_"
        }

        if (-not $stampExists) {
            if ($health -ne "corrupt") { $health = "degraded" }
            $healthDetails += "Stamp file missing at: $StampFile"
        } elseif (-not $artifactSha) {
            if ($health -ne "corrupt") { $health = "degraded" }
            $healthDetails += "Stamp file is malformed or missing recorded SHA at: $StampFile"
        } elseif ($computedSha -and ($computedSha -ne $artifactSha.ToLower())) {
            $health = "corrupt"
            $healthDetails += "Patched binary SHA256 ($computedSha) does not match recorded artifact SHA ($artifactSha)"
        }
    }

    $patchedVer = if ($patchExists) { Get-BinaryReportedVersion -exePath $PatchedExe } else { $null }
    $officialExe = Find-OfficialGrok
    $officialVer = if ($officialExe) { Get-BinaryReportedVersion -exePath $officialExe } else { $null }

    # Version skew evaluation
    $skewExplanation = $null
    if ($officialExe) {
        if ($patchedVer -and $officialVer -and ($patchedVer -ne $officialVer)) {
            if ($health -eq "healthy") { $health = "degraded" }
            $skewExplanation = "Official grok binary found at '$officialExe' reports '$officialVer', while wrapper binary reports '$patchedVer'. To run official directly, execute '$officialExe'."
            $healthDetails += $skewExplanation
        } else {
            $skewExplanation = "Official grok binary found at '$officialExe' ($officialVer)."
        }
    } else {
        $skewExplanation = "No official grok binary detected in standard locations."
    }

    $freeBytes = Get-FreeDiskBytes -targetPath $GrokgodHome
    $freeGb = if ($freeBytes -ne $null) { [math]::Round($freeBytes / 1GB, 2) } else { $null }

    # Resolved command path and launcher identity
    $resolvedCmd = $script:DispatcherScriptPath

    $statusData = [ordered]@{
        health                  = $health
        healthDetails           = $healthDetails
        launcherIdentity        = $Identity
        resolvedCommandPath     = $resolvedCmd
        patchedBinaryPath       = $PatchedExe
        patchedBinaryExists     = $patchExists
        patchedBinaryVersion    = $patchedVer
        officialBinaryPath      = $officialExe
        officialBinaryExists    = ($officialExe -ne $null)
        officialBinaryVersion   = $officialVer
        versionSkewExplanation  = $skewExplanation
        directOfficialPath      = $officialExe
        artifactSha256          = $artifactSha
        computedSha256          = $computedSha
        patchset                = $patchset
        sourceSha               = $sourceSha
        mode                    = $mode
        freeDiskBytes           = $freeBytes
        freeDiskGigabytes       = $freeGb
    }

    if ($AsJson) {
        $json = $statusData | ConvertTo-Json -Depth 5
        # Ensure healthDetails is always serialized as a JSON array [ ... ]
        # PowerShell 5.1 ConvertTo-Json scalarizes single-element arrays or serializes empty arrays as null.
        $hdElements = @()
        foreach ($hd in $healthDetails) {
            $esc = $hd.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
            $hdElements += ('"' + $esc + '"')
        }
        $hdJson = "[" + [string]::Join(", ", $hdElements) + "]"
        $json = $json -replace '(?s)("healthDetails":\s*)(?:\[.*?\]|null|".*?")(?=,\s*"|\s*})', "`$1$hdJson"
        [Console]::Out.WriteLine($json)
    } else {
        [Console]::Out.WriteLine("grokgod Windows Status")
        [Console]::Out.WriteLine("-----------------------")
        [Console]::Out.WriteLine("Health:                  $health")
        if ($healthDetails.Count -gt 0) {
            foreach ($d in $healthDetails) {
                [Console]::Out.WriteLine("  Notice:                $d")
            }
        }
        [Console]::Out.WriteLine("Launcher Identity:       $Identity")
        [Console]::Out.WriteLine("Resolved Command:        $resolvedCmd")
        [Console]::Out.WriteLine("Patched Binary:          $PatchedExe")
        [Console]::Out.WriteLine("  Exists:                $patchExists")
        [Console]::Out.WriteLine("  Version:               $patchedVer")
        [Console]::Out.WriteLine("  Artifact SHA256:       $artifactSha")
        [Console]::Out.WriteLine("  Computed SHA256:       $computedSha")
        [Console]::Out.WriteLine("  Patchset:              $patchset")
        [Console]::Out.WriteLine("  Source SHA:            $sourceSha")
        [Console]::Out.WriteLine("Official Binary:         $(if ($officialExe) { $officialExe } else { 'none' })")
        [Console]::Out.WriteLine("  Version:               $officialVer")
        [Console]::Out.WriteLine("Version Skew:            $skewExplanation")
        [Console]::Out.WriteLine("Direct Official Path:    $(if ($officialExe) { $officialExe } else { 'none' })")
        [Console]::Out.WriteLine("Free Disk Space:         $(if ($freeGb -ne $null) { "$freeGb GB ($freeBytes bytes)" } else { 'unknown' })")
    }

    # Health evaluation exit code contract:
    # corrupt -> exit 2
    # degraded -> exit 1
    # healthy -> exit 0
    if ($health -eq "corrupt") {
        exit 2
    } elseif ($health -eq "degraded") {
        exit 1
    }
    exit 0
}

# -----------------------------------------------------------------------------
# Helper: Resolve Installed Updater
# -----------------------------------------------------------------------------
function Resolve-UpdaterPath {
    # 1. Environment variable override
    if ($env:GROKGOD_UPDATER -and (Test-Path -LiteralPath $env:GROKGOD_UPDATER)) {
        return (Get-Item -LiteralPath $env:GROKGOD_UPDATER).FullName
    }

    # 2. Check layout relative to GrokgodHome or repo src
    $candidates = @(
        (Join-Path $GrokgodHome "install.ps1"),
        (Join-Path $GrokgodHome "src\install.ps1")
    )
    if ($env:GROKGOD_SRC) {
        $candidates += (Join-Path $env:GROKGOD_SRC "install.ps1")
    }
    # Script directory / workspace
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot "..\..\install.ps1")
        $candidates += (Join-Path $PSScriptRoot "install.ps1")
    }

    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path -LiteralPath $cand)) {
            return (Get-Item -LiteralPath $cand).FullName
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
# Update Command
# -----------------------------------------------------------------------------
function Invoke-UpdateCommand([string[]]$argsList) {
    # Whitelist of allowed flags for dispatcher update:
    # Allowed:
    #   --version <val>, -Version <val>, -version <val>
    #   --version=<val>, -Version=<val>, -version=<val>
    #   --no-upgrade, -NoUpgrade, -no-upgrade, --noupgrade, -noupgrade
    #   --force, -Force, -force
    # Explicitly reject:
    #   --uninstall, -Uninstall, prefix overrides, arbitrary script/pwsh params

    $parsedArgs = @()
    $i = 0
    while ($i -lt $argsList.Count) {
        $arg = $argsList[$i]
        if ($arg -match '^(--|-)(version)$') {
            if ($i + 1 -ge $argsList.Count) {
                [Console]::Error.WriteLine("error: $arg requires an argument")
                exit 1
            }
            $i++
            $val = $argsList[$i]
            $parsedArgs += @("-Version", $val)
        } elseif ($arg -match '^(--|-)(version)=(.*)$') {
            $val = $matches[3]
            $parsedArgs += @("-Version", $val)
        } elseif ($arg -match '^(--|-)(no-upgrade|noupgrade)$') {
            $parsedArgs += "-NoUpgrade"
        } elseif ($arg -match '^(--|-)(force)$') {
            $parsedArgs += "-Force"
        } elseif ($arg -match '^(--|-)(uninstall)$') {
            [Console]::Error.WriteLine("error: uninstall cannot be invoked through grok update. Use .\install.ps1 -Uninstall directly.")
            exit 1
        } elseif ($arg -match '^(--|-)(prefix|prefix=.*)$') {
            [Console]::Error.WriteLine("error: prefix modifications cannot be invoked through grok update.")
            exit 1
        } else {
            [Console]::Error.WriteLine("error: unrecognized or disallowed update argument '$arg'")
            [Console]::Error.WriteLine("allowed arguments: --version <tag>, --no-upgrade, --force")
            exit 1
        }
        $i++
    }

    $updaterPath = Resolve-UpdaterPath
    if (-not $updaterPath) {
        [Console]::Error.WriteLine("error: installed updater script not found.")
        [Console]::Error.WriteLine("hint: ensure install.ps1 is located in '$GrokgodHome' or set GROKGOD_UPDATER.")
        exit 1
    }

    # Execute updater via powershell
    $pwshExe = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }

    $updaterArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $updaterPath) + $parsedArgs

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwshExe
    $psi.UseShellExecute = $false

    $psi.Arguments = ConvertTo-WindowsCommandLine -ArgumentList $updaterArgs

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# -----------------------------------------------------------------------------
# Helper: Passthrough to Patched Binary with exact argument preservation
# -----------------------------------------------------------------------------
function Invoke-PatchedExecutable([string[]]$argsList) {
    if (-not (Test-Path -LiteralPath $PatchedExe)) {
        [Console]::Error.WriteLine("error: grokgod binary not found or not executable at $PatchedExe")
        [Console]::Error.WriteLine("hint: run 'grokgod update' to build/install")
        exit 127
    }

    # Official autoupdater MUST be disabled for patched binary
    $env:GROK_DISABLE_AUTOUPDATER = "1"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PatchedExe
    $psi.UseShellExecute = $false

    $psi.Arguments = ConvertTo-WindowsCommandLine -ArgumentList $argsList

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# -----------------------------------------------------------------------------
# Main Dispatcher Logic
# -----------------------------------------------------------------------------
$subcommand = if ($cmdArgs.Count -gt 0) { $cmdArgs[0] } else { "" }

# Private detached refresh entry point. It is intentionally not exposed by the
# launchers and never starts the native grok process.
if ($normIdentity -eq "__grokgod_update_refresh") {
    if ($cmdArgs.Count -eq 3) {
        $refreshCheckedAt = 0L
        if ([Int64]::TryParse($cmdArgs[2], [ref]$refreshCheckedAt)) {
            Invoke-UpdateCacheRefresh -cachePath $cmdArgs[0] -url $cmdArgs[1] -checkedAt $refreshCheckedAt
        }
    }
    exit 0
}

# 1. Update dispatch
if ($subcommand -eq "update") {
    [string[]]$updateRest = @()
    if ($cmdArgs.Length -gt 1) {
        for ($i = 1; $i -lt $cmdArgs.Length; $i++) {
            $updateRest += [string]$cmdArgs[$i]
        }
    }
    Invoke-UpdateCommand -argsList $updateRest
}

# 2. Status dispatch
if ($subcommand -eq "status") {
    $asJson = $false
    for ($idx = 1; $idx -lt $cmdArgs.Length; $idx++) {
        if ($cmdArgs[$idx] -eq "--json" -or $cmdArgs[$idx] -eq "-json") {
            $asJson = $true
        }
    }
    Invoke-StatusCommand -AsJson ([bool]$asJson)
}

# 3. Identity-based differentiation for other commands
if ($normIdentity -eq "grokgod") {
    # On grokgod:
    # 'sessions', 'cache', 'run', 'pin', or other maintenance commands are not supported on Windows,
    # or must fail with explicit Windows error, NEVER TUI!
    if ($subcommand -eq "sessions") {
        [Console]::Error.WriteLine("error: 'grokgod sessions' is not supported on Windows.")
        [Console]::Error.WriteLine("hint: use 'grok sessions' to manage sessions via the grok executable.")
        exit 1
    }
    if ($subcommand -in @("cache", "run", "pin", "eval", "eval-health")) {
        [Console]::Error.WriteLine("error: 'grokgod $subcommand' is not supported on Windows.")
        exit 1
    }

    # Bare 'grokgod' or unrecognized grokgod command:
    # Prevent falling through to interactive TUI
    if ($subcommand -eq "") {
        [Console]::Error.WriteLine("grokgod: Windows maintenance wrapper.")
        [Console]::Error.WriteLine("Usage: grokgod status [--json] | grokgod update [options]")
        [Console]::Error.WriteLine("For grok CLI usage, run 'grok'.")
        exit 1
    } else {
        [Console]::Error.WriteLine("error: unrecognized grokgod maintenance command '$subcommand'.")
        [Console]::Error.WriteLine("hint: run 'grokgod status' or 'grokgod update'. To run grok, use 'grok $subcommand'.")
        exit 1
    }
}

# 4. For 'grok':
# All other arguments, including 'grok sessions ...', go directly to the patched binary
# with GROK_DISABLE_AUTOUPDATER=1.
if ($subcommand -ne "cache") {
    Invoke-ReleaseUpdateCheck
}
Invoke-PatchedExecutable -argsList $cmdArgs
