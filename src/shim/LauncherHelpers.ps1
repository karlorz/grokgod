<#
.SYNOPSIS
    Launcher generation and PowerShell 7 prerequisite helpers for grokgod
    Windows installation (Task 3 helper).
.DESCRIPTION
    Generates thin .cmd launchers that invoke grok-shim.ps1 with positional
    identity, and resolves a verified runnable PowerShell 7+ engine.

    grokgod requires PowerShell 7 or newer. These helpers never fall back to
    Windows PowerShell 5.1: Resolve-GrokgodPwsh verifies every candidate by
    executing it (alias presence alone is not proof of runnability), and the
    generated launcher prints actionable install guidance and exits 127 when
    no verified engine exists.
#>

function Get-GrokgodPwshVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutMs = 8000
    )

    # Runs '<Path> -NoProfile -Command $PSVersionTable.PSVersion.ToString()'
    # with a bounded total lifetime and returns the first output line on
    # success. Returns $null when the candidate cannot start, exceeds the
    # budget, exits non-zero, or holds EOF past the drain window.
    $proc = $null
    # Deadline measured from BEFORE process setup so Start() counts too.
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
        if (-not ('GrokgodProbeStdio' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GrokgodProbeStdio {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetHandleInformation(IntPtr hObject, out uint lpdwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    public const uint HANDLE_FLAG_INHERIT = 0x00000001;
}
"@
        }
        $savedStdio = New-Object System.Collections.Generic.List[object]
        $seenStdio = @{}
        foreach ($n in @(-10, -11, -12)) {
            $h = [GrokgodProbeStdio]::GetStdHandle($n)
            if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]::new(-1)) { continue }
            $key = $h.ToInt64()
            if ($seenStdio.ContainsKey($key)) { continue }
            $flags = [uint32]0
            if (-not [GrokgodProbeStdio]::GetHandleInformation($h, [ref]$flags)) { continue }
            if (-not [GrokgodProbeStdio]::SetHandleInformation($h, [GrokgodProbeStdio]::HANDLE_FLAG_INHERIT, 0)) { continue }
            $seenStdio[$key] = $true
            [void]$savedStdio.Add([pscustomobject]@{ Handle = $h; Flags = $flags })
        }
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        } finally {
            foreach ($item in $savedStdio) {
                $bit = $item.Flags -band [GrokgodProbeStdio]::HANDLE_FLAG_INHERIT
                [void][GrokgodProbeStdio]::SetHandleInformation($item.Handle, [GrokgodProbeStdio]::HANDLE_FLAG_INHERIT, $bit)
            }
        }
        # Immediate EOF for the candidate: stdin is redirected and closed so
        # a probe waiting on inherited input can never outlive its budget.
        try { $proc.StandardInput.Close() } catch {}
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $remainWait = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($remainWait -lt 0) { $remainWait = 0 }
        if (-not $proc.WaitForExit($remainWait)) {
            try { $proc.Kill() } catch {}
            return $null
        }
        # Each sequential drain wait recomputes the remaining budget.
        # Both pipes must reach EOF: a descendant that holds only stderr
        # is still a held-EOF failure even when stdout already completed.
        $drainMs = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $outDrained = $false
        try { $outDrained = $outTask.Wait($drainMs) } catch { $outDrained = $false }
        $drainMs = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $errDrained = $false
        try { $errDrained = $errTask.Wait($drainMs) } catch { $errDrained = $false }
        if (-not $outDrained -or -not $errDrained) {
            try { $proc.Kill() } catch {}
            return $null
        }
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

function Resolve-GrokgodPwsh {
    [CmdletBinding()]
    param(
        [int]$ProbeTimeoutMs = 8000
    )

    # Returns the absolute path of a pwsh.exe that provably starts and
    # reports major version >= 7, or $null when none is found. Candidates:
    #   1. standard install locations (real binaries, never Store aliases)
    #   2. every pwsh.exe reported by where.exe (PATH order)
    # Every candidate is executed with the bounded probe in the current
    # context; a Store alias that cannot launch here is rejected, and a
    # failed candidate never short-circuits the remaining list.
    $candidates = New-Object System.Collections.Generic.List[string]
    $std = @()
    if ($env:ProgramFiles) { $std += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    if (${env:ProgramFiles(x86)}) { $std += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe') }
    foreach ($p in $std) { if (Test-Path -LiteralPath $p) { $candidates.Add($p) } }

    $whereOut = $null
    $wp = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'where.exe'
        $psi.Arguments = 'pwsh.exe'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $wp = [System.Diagnostics.Process]::Start($psi)
        try { $wp.StandardInput.Close() } catch {}
        # One 5000ms budget covers WaitForExit + both drains + kill. Each
        # wait recomputes remaining time; this is not 5000+1000+1000.
        $whereBudgetMs = 5000
        $whereWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $wOut = $wp.StandardOutput.ReadToEndAsync()
        $wErr = $wp.StandardError.ReadToEndAsync()
        $remain = $whereBudgetMs - [int]$whereWatch.ElapsedMilliseconds
        if ($remain -lt 0) { $remain = 0 }
        if ($wp.WaitForExit($remain)) {
            $remain = $whereBudgetMs - [int]$whereWatch.ElapsedMilliseconds
            if ($remain -lt 0) { $remain = 0 }
            if ($wOut.Wait($remain)) { $whereOut = [string]$wOut.Result }
        } else {
            try { $wp.Kill() } catch {}
        }
        $remain = $whereBudgetMs - [int]$whereWatch.ElapsedMilliseconds
        if ($remain -lt 0) { $remain = 0 }
        try { [void]$wErr.Wait($remain) } catch {}
    } catch { $whereOut = $null }
    finally {
        if ($wp) {
            try { $wp.StandardInput.Dispose() } catch {}
            try { $wp.StandardOutput.Dispose() } catch {}
            try { $wp.StandardError.Dispose() } catch {}
            try { $wp.Dispose() } catch {}
        }
    }
    if ($whereOut) {
        foreach ($line in ($whereOut -split "`r?`n")) {
            $t = $line.Trim()
            if ($t -and (Test-Path -LiteralPath $t)) { $candidates.Add($t) }
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        $path = $candidate
        # A Store alias is a reparse point; prefer the packaged real binary.
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $target = $null
                try { $target = ($item.Target | Select-Object -First 1) } catch { $target = $null }
                if ($target -and (Test-Path -LiteralPath $target)) { $path = $target }
            }
        } catch {}
        if ($seen.ContainsKey($path.ToLowerInvariant())) { continue }
        $seen[$path.ToLowerInvariant()] = $true
        $version = Get-GrokgodPwshVersion -Path $path -TimeoutMs $ProbeTimeoutMs
        if (-not $version) { continue }
        $parsed = $null
        try { $parsed = [version]$version } catch { $parsed = $null }
        if ($parsed -and $parsed.Major -ge 7) { return $path }
    }
    return $null
}

function New-GrokgodLauncherScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("grok", "grokgod")]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$ShimPath,

        # Optional absolute path to a Resolve-GrokgodPwsh-verified pwsh.exe.
        # Baked into the launcher (GROKGOD_POWERSHELL_BAKED) as the preferred
        # engine; the launcher's runtime verification still rejects it if it
        # stops being runnable, and discovery then applies. The path is
        # re-verified here at generation time so an arbitrary or stale value
        # can never be baked in. Empty = pure discovery launcher.
        [string]$PwshPath = "",

        # Directory that will hold the generated .cmd. Used to bind an ASCII
        # %~dp0-relative GROKGOD_SHIM_PATH so Unicode absolute shim paths are
        # never written into the ASCII launcher file.
        [string]$LauncherDirectory = ""
    )

    $normalizedShim = $ShimPath.Trim()
    if (-not (Test-Path -LiteralPath $normalizedShim)) {
        throw "ShimPath '$normalizedShim' does not exist."
    }
    $fullShim = [System.IO.Path]::GetFullPath($normalizedShim)
    $shimBindLine = ""
    if ($fullShim -notmatch '[^\x00-\x7F]') {
        # ASCII absolute path: bind it directly. This also works when the
        # launcher directory is on another drive.
        $shimBindLine = 'set "GROKGOD_SHIM_PATH=' + ($fullShim.Replace('%', '%%')) + '"'
    } elseif (-not $LauncherDirectory) {
        throw "ShimPath contains non-ASCII characters; pass -LauncherDirectory so the launcher binds a %~dp0-relative ASCII path."
    } else {
        $fullLaunch = [System.IO.Path]::GetFullPath($LauncherDirectory.Trim())
        if (-not (Test-Path -LiteralPath $fullLaunch)) {
            throw "LauncherDirectory '$LauncherDirectory' does not exist."
        }
        $fromUri = New-Object System.Uri (($fullLaunch.TrimEnd('\', '/') + '\'))
        $toUri = New-Object System.Uri $fullShim
        # Decode back to a real filesystem path: cmd "if exist" and pwsh
        # -File do not URI-decode. Only an ASCII relative suffix is safe;
        # arbitrary Unicode components fail closed instead of decoy fallback.
        $rel = [Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).OriginalString).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($rel) -or $rel.Contains(':')) {
            throw "ShimPath is not relative to LauncherDirectory; refusing silent discovery fallthrough."
        }
        if ($rel -match '[^\x00-\x7F]') {
            throw "Relative shim path from LauncherDirectory is not ASCII; refusing silent discovery fallthrough."
        }
        $shimBindLine = 'set "GROKGOD_SHIM_PATH=%~dp0' + ($rel.Replace('%', '%%')) + '"'
    }
    $bakedLine = ""
    $trimmedPwsh = $PwshPath.Trim()
    if ($trimmedPwsh) {
        # Bake only a provably runnable engine. An arbitrary or stale path
        # here would ship a launcher that 127s on first use, so the same
        # verification the launcher applies at runtime is applied at
        # generation time. Non-ASCII engine paths stay out of the ASCII
        # launcher file; discovery and GROKGOD_POWERSHELL cover those hosts.
        if ($trimmedPwsh -match '[^\x00-\x7F]') {
            $trimmedPwsh = ""
        }
        if ($trimmedPwsh) {
            if (-not (Test-Path -LiteralPath $trimmedPwsh)) {
                throw "PwshPath '$trimmedPwsh' does not exist. Resolve-GrokgodPwsh first, then pass its result."
            }
            $bakedVersion = Get-GrokgodPwshVersion -Path $trimmedPwsh
            $bakedParsed = $null
            try { $bakedParsed = [version]$bakedVersion } catch { $bakedParsed = $null }
            if (-not $bakedParsed -or $bakedParsed.Major -lt 7) {
                throw "PwshPath '$trimmedPwsh' is not a verified runnable PowerShell 7+ engine (probe returned '$bakedVersion')."
            }
            $bakedLine = 'set "GROKGOD_POWERSHELL_BAKED=' + ($trimmedPwsh.Replace('%', '%%')) + '"'
        }
    }

    # The probe block is raw cmd text containing $ and backtick characters;
    # it must ride in a single-quoted here-string so PowerShell never
    # interpolates it, then be spliced into the launcher template by literal
    # replacement. Putting the probe inside the expandable template
    # here-string interpolates $PSVersionTable and silently removes the
    # for /f usebackq backticks at runtime (observed on msi-1: every probe
    # stage failed and the launcher exited 127).
    $probePart = @'
rem --- PowerShell 7 prerequisite: locate and verify a runnable pwsh.exe ---
set "POWERSHELL_EXE="
set "PS7_STAGE=override"
:ps7_next
if "%PS7_STAGE%"=="override" goto ps7_stage_override
if "%PS7_STAGE%"=="baked" goto ps7_stage_baked
if "%PS7_STAGE%"=="pf64" goto ps7_stage_pf64
if "%PS7_STAGE%"=="pf86" goto ps7_stage_pf86
goto ps7_stage_path

:ps7_stage_override
set "PS7_STAGE=baked"
if defined GROKGOD_POWERSHELL set "POWERSHELL_EXE=%GROKGOD_POWERSHELL%"
if defined POWERSHELL_EXE goto ps7_verify
goto ps7_next

:ps7_stage_baked
set "PS7_STAGE=pf64"
if defined GROKGOD_POWERSHELL_BAKED set "POWERSHELL_EXE=%GROKGOD_POWERSHELL_BAKED%"
if defined POWERSHELL_EXE goto ps7_verify
goto ps7_next

:ps7_stage_pf64
set "PS7_STAGE=pf86"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined POWERSHELL_EXE goto ps7_verify
goto ps7_next

:ps7_stage_pf86
set "PS7_STAGE=path"
if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if defined POWERSHELL_EXE goto ps7_verify
goto ps7_next

:ps7_stage_path
set "PS7_FOUND="
for /f "usebackq delims=" %%W in (`%SystemRoot%\System32\where.exe pwsh.exe 2^>nul`) do (
    if not defined PS7_FOUND call :ps7_try_candidate "%%W"
)
if defined POWERSHELL_EXE goto ps7_ready
goto ps7_unavailable

:ps7_verify
"%POWERSHELL_EXE%" -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 7) { exit 0 } exit 1" >nul 2>nul
if not errorlevel 1 goto ps7_ready
rem Candidate failed verification; continue enumeration from the next stage.
set "POWERSHELL_EXE="
goto ps7_next

:ps7_try_candidate
rem %1 = quoted candidate path from the where.exe enumeration. A
rem subroutine is used so the candidate variable expands per call instead
rem of at parenthesized-block parse time.
set "POWERSHELL_EXE=%~1"
"%POWERSHELL_EXE%" -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 7) { exit 0 } exit 1" >nul 2>nul
if not errorlevel 1 (set "PS7_FOUND=1") else (set "POWERSHELL_EXE=")
exit /b 0

:ps7_unavailable
>&2 echo grokgod: PowerShell 7+ is required but no runnable pwsh.exe was found.
>&2 echo grokgod: install it with: winget install --id Microsoft.PowerShell -e
>&2 echo grokgod: then re-run this command.
exit /b 127
'@

    $template = @"
@echo off
rem grokgod thin launcher for Windows ($Identity) - requires PowerShell 7+
setlocal DisableDelayedExpansion
$bakedLine
$shimBindLine
if defined GROKGOD_SHIM_PATH if exist "%GROKGOD_SHIM_PATH%" goto shim_ready
set "GROKGOD_SHIM_DIR=%~dp0"
if exist "%GROKGOD_SHIM_DIR%grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%GROKGOD_SHIM_DIR%grok-shim.ps1"
    goto shim_ready
)
if exist "%GROKGOD_SHIM_DIR%..\grokgod\shim\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%GROKGOD_SHIM_DIR%..\grokgod\shim\grok-shim.ps1"
    goto shim_ready
)
if defined GROKGOD_HOME if exist "%GROKGOD_HOME%\shim\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%GROKGOD_HOME%\shim\grok-shim.ps1"
    goto shim_ready
)
if exist "%USERPROFILE%\.grokgod\shim\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%USERPROFILE%\.grokgod\shim\grok-shim.ps1"
    goto shim_ready
)
if exist "%GROKGOD_SHIM_DIR%..\grokgod\src\shim\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%GROKGOD_SHIM_DIR%..\grokgod\src\shim\grok-shim.ps1"
    goto shim_ready
)
if exist "%USERPROFILE%\.grokgod\src\shim\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%USERPROFILE%\.grokgod\src\shim\grok-shim.ps1"
    goto shim_ready
)
if exist "%USERPROFILE%\.grokgod\grok-shim.ps1" (
    set "GROKGOD_SHIM_PATH=%USERPROFILE%\.grokgod\grok-shim.ps1"
    goto shim_ready
)
set "GROKGOD_SHIM_PATH=grok-shim.ps1"
:shim_ready

__GROKGOD_PS7_PROBE__

:ps7_ready

rem Argument transport: DisableDelayedExpansion (set above) preserves "!" in
rem user tokens; %* is forwarded directly to pwsh -File. Callers that spawn
rem this launcher through cmd.exe /d /s /c must apply CRT quote/backslash
rem encoding and then twice CMD-metachar escaping with
rem windowsVerbatimArguments (see tests/shim/launcher_fixture_driver.js).
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%GROKGOD_SHIM_PATH%" $Identity %*
exit /b %ERRORLEVEL%
"@
    return ($template.Replace('__GROKGOD_PS7_PROBE__', $probePart))
}
