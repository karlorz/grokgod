#Requires -Version 7.0
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
    Requires PowerShell 7 or newer; there is no Windows PowerShell 5.1 path.
    Preserves exact arguments and exit codes.
    Consumes raw $args directly to avoid named parameter binding on dashed arguments.
#>

# Enforce strict parsing
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Hard PowerShell 7 floor, enforced before any config/cache/status/update/
# passthrough side effect. #Requires -Version 7.0 above already rejects a
# 5.1 parse; this runtime guard covers hosts that load the script in ways
# that bypass #Requires (dot-source, Invoke-Expression) and prints the
# remediation hint instead of a generic parse error.
if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine("error: grok-shim.ps1 requires PowerShell 7 or newer; this host runs $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion).")
    [Console]::Error.WriteLine("hint: install PowerShell 7 with: winget install --id Microsoft.PowerShell -e")
    [Console]::Error.WriteLine("hint: the grokgod launcher always invokes this shim through a verified pwsh.exe.")
    exit 1
}

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

# Remaining application arguments. Launchers forward %* directly to
# pwsh -File, so $args is already the CRT-split token list.
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
    # A null backup file name makes File.Replace throw ArgumentException on
    # .NET Framework (Windows PowerShell 5.1); a real (then removed) backup
    # works on both .NET Framework and modern .NET.
    $backupPath = "$path.bak.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
        $content = "CHECKED_AT=$checkedAt`n"
        if (Test-ReleaseVersion $version) { $content += "VERSION=$version`n" }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, $content, $utf8NoBom)
        if (Test-Path -LiteralPath $path) {
            [System.IO.File]::Replace($tempPath, $path, $backupPath)
        } else {
            [System.IO.File]::Move($tempPath, $path)
        }
        return $true
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
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
    $hostExe = $null
    try {
        # Same verified PowerShell 7 engine the updater uses: the running
        # engine by construction, or a validated POWERSHELL_EXE override.
        $hostExe = Resolve-GrokgodEngine
    } catch {
        [Console]::Error.WriteLine("error: detached update refresh skipped: $_")
        return
    }
    try {
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
        # Isolate the detached refresh from the caller's pipes. A refresh
        # child that inherited the launcher stdout/stderr (for example from a
        # Node child_process caller with piped stdio) would keep the caller's
        # pipe open after the launcher exits, so EOF would be delayed until
        # the refresh finished. Redirect every stream, close our stdin copy
        # so the child sees immediate EOF, and drain stdout/stderr so the
        # child can never block on a full pipe.
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Arguments = ConvertTo-WindowsCommandLine -ArgumentList $refreshArgs
        $refreshProc = [System.Diagnostics.Process]::Start($psi)
        try { $refreshProc.StandardInput.Close() } catch {}
        [void]$refreshProc.StandardOutput.ReadToEndAsync()
        [void]$refreshProc.StandardError.ReadToEndAsync()
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
# Helper: bounded PowerShell engine version probe
# -----------------------------------------------------------------------------
# Runs '<Path> -NoProfile -Command $PSVersionTable.PSVersion.ToString()' with
# a bounded total lifetime and returns the first output line on success.
# Returns $null when the candidate cannot start, exceeds the budget, exits
# non-zero, or holds EOF past the drain window (held-stdin children get EOF
# immediately because our stdin copy is closed right after start). Drains
# begin BEFORE the wait so a noisy-stderr candidate cannot deadlock; the
# deadline covers wait + drain + cleanup together. On timeout only the
# directly owned probe PID is killed (pwsh -Command spawns no children for
# this probe). Readers and process handle are disposed on every path.
function Get-GrokgodEngineVersion([string]$Path, [int]$TimeoutMs) {
    $proc = $null
    # The deadline watch starts BEFORE process setup so Start() cost counts
    # against the budget too.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Path
        $psi.Arguments = '-NoProfile -Command "$PSVersionTable.PSVersion.ToString()"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.Close() } catch {}
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -lt 0) { $remaining = 0 }
        if (-not $proc.WaitForExit($remaining)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        # Each sequential drain wait recomputes the remaining budget so the
        # pair can never consume more than the total deadline. Both pipes
        # must reach EOF: a descendant holding only stderr is still failure.
        $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -lt 0) { $remaining = 0 }
        $outDrained = $false
        try { $outDrained = $outTask.Wait($remaining) } catch { $outDrained = $false }
        $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -lt 0) { $remaining = 0 }
        $errDrained = $false
        try { $errDrained = $errTask.Wait($remaining) } catch { $errDrained = $false }
        if (-not $outDrained -or -not $errDrained) { return $null }
        if ($proc.ExitCode -ne 0) { return $null }
        $out = [string]$outTask.Result
        if (-not $out) { return $null }
        return (($out -split "`r?`n")[0]).Trim()
    } catch {
        return $null
    } finally {
        if ($proc) {
            try { $proc.StandardInput.Dispose() } catch {}
            try { $proc.StandardOutput.Dispose() } catch {}
            try { $proc.StandardError.Dispose() } catch {}
            try { $proc.Dispose() } catch {}
        }
    }
}

# -----------------------------------------------------------------------------
# Helper: resolve the verified PowerShell 7 engine for child processes
# -----------------------------------------------------------------------------
# Every child the shim spawns (updater, detached refresh) must run under the
# SAME verified PowerShell 7 engine family — never a PSEdition guess and
# never powershell.exe. Resolution order:
#   1. POWERSHELL_EXE override: honored ONLY when it names a real pwsh that
#      provably runs and reports >= 7. An override naming powershell.exe or
#      any WindowsPowerShell\v1.0 path is a blocking error with remediation
#      (it would reintroduce the exact 5.1 fallback this shim forbids).
#   2. Otherwise the currently running engine's absolute path. The gate at
#      script entry guarantees this process IS PowerShell 7+, so the path is
#      verified by construction.
function Resolve-GrokgodEngine {
    $override = [string]$env:POWERSHELL_EXE
    if ($override) {
        $name = [System.IO.Path]::GetFileName($override)
        if ($name -ieq 'powershell.exe' -or $override -imatch 'WindowsPowerShell\\v1\.0') {
            throw "POWERSHELL_EXE points at '$override', which is Windows PowerShell 5.1. grokgod requires PowerShell 7 or newer; remove the override or point it at a pwsh.exe (winget install --id Microsoft.PowerShell -e)."
        }
        $version = Get-GrokgodEngineVersion -Path $override -TimeoutMs 8000
        $parsed = $null
        try { $parsed = [version]$version } catch { $parsed = $null }
        if ($parsed -and $parsed.Major -ge 7) { return $override }
        throw "POWERSHELL_EXE override '$override' is not a runnable PowerShell 7+ engine (probe returned '$version'). Fix or remove the override."
    }
    $current = $null
    try { $current = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $current = $null }
    if (-not $current) { $current = [string]$PSHOME + "\pwsh.exe" }
    return $current
}

# -----------------------------------------------------------------------------
# Machine / protocol launch classification
# -----------------------------------------------------------------------------
# These forms must reach the patched binary with zero update-check side
# effects (no cache reads or writes, no cached wrapper notice, no detached
# network refresh, no network dependency of any kind):
#   grok --version | -V
#   grok --help | -h | help
#   grok models
#   grok inspect
#   grok agent stdio
# A small set of recognized global flags may precede the form (for example
# `grok -m flash-max agent stdio`); each consumes exactly one value token.
# Matching is exact per token over the whole remaining argument list: an
# argument VALUE that merely contains the text "agent stdio" is never
# classified as a protocol launch.
function Test-MachineProtocolLaunch([string[]]$argsList) {
    # Walk a cursor past recognized leading global flags instead of
    # repeatedly re-slicing a copy of the argument list.
    $i = 0
    $count = $argsList.Count
    while ($i -lt $count) {
        $t = [string]$argsList[$i]
        if ($t -eq "--minimal") {
            $i += 1
        } elseif ($t -eq "-m" -or $t -eq "--model" -or $t -eq "--agent") {
            # A value-taking flag with no value is not a clean machine form.
            if (($i + 2) -gt $count) { return $false }
            $i += 2
        } elseif ($t -match '^--model=' -or $t -match '^--agent=') {
            $i += 1
        } else {
            break
        }
    }

    $rest = $count - $i
    if ($rest -eq 1) {
        $t = [string]$argsList[$i]
        if ($t -eq "--version" -or $t -eq "-V" -or $t -eq "--help" -or $t -eq "-h" -or
            $t -eq "help" -or $t -eq "models" -or $t -eq "inspect") {
            return $true
        }
    } elseif ($rest -eq 2) {
        if ([string]$argsList[$i] -eq "agent" -and [string]$argsList[$i + 1] -eq "stdio") {
            return $true
        }
    }
    return $false
}

# -----------------------------------------------------------------------------
# Helper: Read Version from Binary via execution (bounded probe)
# -----------------------------------------------------------------------------
# Probe contract:
#   - One total budget ($totalBudgetMs, 4000ms) measured from process start:
#     the 3000ms wait, the post-exit drains, the kill, and handle teardown
#     each consume only the time remaining in that total. Never unbounded.
#   - stdout and stderr are drained concurrently via ReadToEndAsync so a
#     child that saturates one pipe cannot deadlock the probe before the
#     budget elapses. The candidate's stdin is redirected and closed right
#     after start so a held-EOF child sees immediate EOF.
#   - On timeout the kill is supervised and bounded: taskkill runs as an
#     OWNED helper process whose WaitForExit gets only the remaining
#     cleanup budget; on helper overrun the helper is killed and the owned
#     root PID is killed directly as the fallback. Only processes rooted at
#     the probe PID we started are touched — no CIM enumeration, no foreign
#     processes.
#   - Descendant limit (honest): taskkill /T reaches only descendants still
#     attached to the owned root's tree. A grandchild that detached (own
#     console, reparented, or outliving a root that already exited) can
#     survive the tree kill; nothing here enumerates or kills foreign
#     processes, so such an orphan is left for the OS/caller watchdog.
#   - A grandchild that inherits the probe pipe and holds EOF open cannot
#     extend the probe: once the direct child exits, the async drains get
#     only the time left in the total budget; after that the probe returns
#     through the normal contract (version unknown -> $null).
function Stop-OwnedProbeProcess([System.Diagnostics.Process]$proc, [int]$cleanupBudgetMs) {
    if (-not $proc) { return }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $proc.HasExited) {
            # Supervised tree kill: taskkill is an owned child bounded by the
            # remaining cleanup budget, never a synchronous & invocation.
            $tk = $null
            try {
                $tpsi = New-Object System.Diagnostics.ProcessStartInfo
                $tpsi.FileName = 'taskkill.exe'
                $tpsi.Arguments = "/T /F /PID $($proc.Id)"
                $tpsi.UseShellExecute = $false
                $tpsi.CreateNoWindow = $true
                $tpsi.RedirectStandardOutput = $true
                $tpsi.RedirectStandardError = $true
                $tk = [System.Diagnostics.Process]::Start($tpsi)
                # Fire-and-forget drains keep the helper's pipes from
                # blocking it; their content is never used, so nothing here
                # waits on them past the supervised WaitForExit above.
                [void]$tk.StandardOutput.ReadToEndAsync()
                [void]$tk.StandardError.ReadToEndAsync()
                $remain = $cleanupBudgetMs - [int]$watch.ElapsedMilliseconds
                if ($remain -gt 0) {
                    [void]$tk.WaitForExit($remain)
                } else {
                    try { $tk.Kill() } catch {}
                }
            } catch {
                # taskkill unavailable or failed to start: the direct
                # owned-PID kill below is the fallback.
            } finally {
                if ($tk) {
                    try { if (-not $tk.HasExited) { $tk.Kill() } } catch {}
                    try { $tk.StandardOutput.Dispose() } catch {}
                    try { $tk.StandardError.Dispose() } catch {}
                    try { $tk.Dispose() } catch {}
                }
            }
        }
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch {}
        }
        $remain = $cleanupBudgetMs - [int]$watch.ElapsedMilliseconds
        if ($remain -gt 0) {
            try { [void]$proc.WaitForExit($remain) } catch {}
        }
    } catch {}
}

function Get-BinaryReportedVersion([string]$exePath) {
    if (-not (Test-Path -LiteralPath $exePath)) { return $null }
    # Total budget from process start: 3000ms wait + 1000ms drain/cleanup
    # tail. The watch starts BEFORE process setup and every stage below
    # consumes only the time remaining in the total.
    $probeWaitMs = 3000
    $totalBudgetMs = 4000
    $proc = $null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exePath
        $psi.Arguments = "--version"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Immediate EOF for the candidate: a fixture that waits on stdin can
        # never hold this probe open.
        try { $proc.StandardInput.Close() } catch {}

        # Begin concurrent drains before the wait so neither pipe can fill.
        # stderr content is unused, but drain completion is required: a
        # descendant that holds only stderr is still a held-EOF failure.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($probeWaitMs)
        if (-not $exited) {
            $remain = $totalBudgetMs - [int]$watch.ElapsedMilliseconds
            if ($remain -lt 0) { $remain = 0 }
            Stop-OwnedProbeProcess -proc $proc -cleanupBudgetMs $remain
            return $null
        }

        # Direct child exited; each sequential drain wait recomputes the
        # remaining budget so a fixture- or grandchild-held pipe cannot
        # extend the probe. A true Wait already implies IsCompleted; only
        # fault/cancel need checks.
        $drainMs = $totalBudgetMs - [int]$watch.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $outDrained = $false
        $outText = $null
        if ($stdoutTask.Wait($drainMs) -and -not $stdoutTask.IsFaulted -and -not $stdoutTask.IsCanceled) {
            $outText = $stdoutTask.Result
            $outDrained = $true
        }
        $drainMs = $totalBudgetMs - [int]$watch.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $errDrained = $false
        try { $errDrained = $stderrTask.Wait($drainMs) -and -not $stderrTask.IsFaulted -and -not $stderrTask.IsCanceled } catch { $errDrained = $false }
        if (-not $outDrained -or -not $errDrained) { return $null }
        if ($proc.ExitCode -eq 0 -and $outText -ne $null) {
            $line = ($outText -split "[\r\n]+") | Where-Object { $_ -match '\S' } | Select-Object -First 1
            if ($line) { return $line.Trim() }
        }
        return $null
    } catch {}
    finally {
        if ($proc) {
            try { $proc.StandardInput.Dispose() } catch {}
            try { $proc.StandardOutput.Dispose() } catch {}
            try { $proc.StandardError.Dispose() } catch {}
            try { $proc.Dispose() } catch {}
        }
    }
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
        } elseif ($arg -match '^(--|-)(release)$') {
            # No-op: release is default mode on Windows, do not pass -Release to install.ps1
        } elseif ($arg -match '^(--|-)(uninstall)$') {
            [Console]::Error.WriteLine("error: uninstall cannot be invoked through grok update. Use .\install.ps1 -Uninstall directly.")
            exit 1
        } elseif ($arg -match '^(--|-)(prefix|prefix=.*)$') {
            [Console]::Error.WriteLine("error: prefix modifications cannot be invoked through grok update.")
            exit 1
        } else {
            [Console]::Error.WriteLine("error: unrecognized or disallowed update argument '$arg'")
            [Console]::Error.WriteLine("allowed arguments: --version <tag>, --release, --no-upgrade, --force")
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

    # Execute the updater through the SAME verified PowerShell 7 engine this
    # shim is running under (or a validated POWERSHELL_EXE override). There
    # is deliberately no PSEdition-based powershell.exe fallback: an
    # override pointing at Windows PowerShell 5.1 fails right here with an
    # explicit blocking error instead of downgrading the updater.
    $pwshExe = Resolve-GrokgodEngine

    $updaterArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $updaterPath) + $parsedArgs

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwshExe
    $psi.UseShellExecute = $false

    $psi.Arguments = ConvertTo-WindowsCommandLine -ArgumentList $updaterArgs

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.WaitForExit()
        exit $proc.ExitCode
    } finally {
        try { $proc.Dispose() } catch {}
    }
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
# Machine/protocol launches (--version, -V, help forms, models, inspect,
# agent stdio) bypass the release update check entirely: no cache reads or
# writes, no cached wrapper notice, no detached network refresh.
$machineOrProtocol = Test-MachineProtocolLaunch -argsList $cmdArgs
if ($subcommand -ne "cache" -and -not $machineOrProtocol) {
    Invoke-ReleaseUpdateCheck
}
Invoke-PatchedExecutable -argsList $cmdArgs
