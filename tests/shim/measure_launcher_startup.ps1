#Requires -Version 5.1
<#
.SYNOPSIS
    Measure grokgod Windows launcher startup latency.
.DESCRIPTION
    Records repeated full-launcher and direct-native startup samples on the
    same host and prints a min/median/mean/max table. Used by the
    windows-t3-process-integration evidence to compare the full launcher
    (cmd -> PS7 engine probe -> PowerShell shim -> native binary) against
    direct-shim and direct native baselines, and to check the T3 4-second
    full-launcher --version budget on reference Windows hardware.

    Run natively on Windows (a Resolve-GrokgodPwsh-verified pwsh.exe is
    required for the direct-shim category; the full-launcher category uses
    the canonical probe and reports when no engine verifies):
        pwsh.exe -NoProfile -ExecutionPolicy Bypass -File tests\shim\measure_launcher_startup.ps1

    Measurement contract:
      * Every category is bound to an isolated fixture GROKGOD_HOME/BIN; the
        caller's environment is snapshotted and restored in finally.
      * The launcher is generated with New-GrokgodLauncherScript and the
        actual launcher-selected engine (verified pwsh path, or the 127
        guidance path when none verifies) is reported.
      * Each sample must exit 0 and print the fixture version line; samples
        that fail either check are purged from the statistics and counted,
        so a hanging or mis-targeted engine cannot yield a plausible median.

    No assertions fail the run; breaches of the T3 budget are reported as
    warnings because CI watchdogs are intentionally more generous.
#>
param(
    [int]$Samples = 15,
    [string]$ShimPath = "$PSScriptRoot\..\..\src\shim\grok-shim.ps1",
    [string]$LauncherDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$workDir = Join-Path $env:TEMP "grokgod-measure-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$grokgodHome = Join-Path $workDir "home"
New-Item -ItemType Directory -Force -Path (Join-Path $grokgodHome "bin") | Out-Null

try {
    # --- Fixture environment binding (all categories) ------------------------
    # Snapshot and bind before any measurement; finally restores the
    # caller's environment exactly.
    $envBackup = @{
        "GROKGOD_HOME" = $env:GROKGOD_HOME
        "GROKGOD_BIN"  = $env:GROKGOD_BIN
    }
    $env:GROKGOD_HOME = $grokgodHome
    $env:GROKGOD_BIN  = Join-Path $grokgodHome "bin\grokgod.exe"

    # --- Fixture: minimal version-reporting native exe -----------------------
    $mockExe = Join-Path $grokgodHome "bin\grokgod.exe"
    $csharpSource = @"
using System;
class MeasureMock {
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "--version") {
            Console.WriteLine("grok 9.9.9-measure (fixture)");
            return 0;
        }
        return 0;
    }
}
"@
    $csharpFile = Join-Path $workDir "MeasureMock.cs"
    Set-Content -LiteralPath $csharpFile -Value $csharpSource -Encoding UTF8
    $cscExe = $null
    foreach ($fp in @("$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe")) {
        if (Test-Path $fp) { $cscExe = $fp; break }
    }
    if (-not $cscExe -and (Get-Command "csc" -ErrorAction SilentlyContinue)) { $cscExe = (Get-Command "csc").Source }
    if ($cscExe) {
        $compile = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$mockExe`"", "`"$csharpFile`"") -NoNewWindow -Wait -PassThru
        if ($compile.ExitCode -ne 0) { throw "Failed to compile MeasureMock.cs" }
    } else {
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.OutputAssembly = $mockExe
        $cscp = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cr = $cscp.CompileAssemblyFromSource($cp, $csharpSource)
        if ($cr.Errors.Count -gt 0) { throw $cr.Errors[0].ErrorText }
    }

    # --- Generate the full launcher with the canonical helper ----------------
    if (-not $LauncherDir) { $LauncherDir = Join-Path $workDir "launchers" }
    New-Item -ItemType Directory -Force -Path $LauncherDir | Out-Null
    $helpersSource = Join-Path $RepoRoot "src\shim\LauncherHelpers.ps1"
    . $helpersSource
    $resolvedShim = (Resolve-Path $ShimPath).Path

    # Report the actual launcher-selected engine: resolve and verify it the
    # same way the suites do, then bake it into the generated launcher. The
    # runtime probe inside the launcher re-verifies before every use.
    $verifiedPwsh = $null
    try { $verifiedPwsh = Resolve-GrokgodPwsh } catch { $verifiedPwsh = $null }

    $grokLauncher = Join-Path $LauncherDir "grok.cmd"
    Set-Content -LiteralPath $grokLauncher -Value (New-GrokgodLauncherScript -Identity grok -ShimPath $resolvedShim -PwshPath ([string]$verifiedPwsh) -LauncherDirectory $LauncherDir) -Encoding ASCII

    if ($verifiedPwsh) {
        $engineReport = "verified pwsh: $verifiedPwsh"
    } else {
        $engineReport = "none verified - full-launcher samples exercise the 127 guidance path"
    }

    # Each sample must exit 0 and print the fixture version line; timings
    # from samples failing either check are purged and reported.
    $versionPattern = '^grok \d+\.\d+\.\d+'
    function Measure-Category([string]$name, [scriptblock]$body) {
        $times = New-Object System.Collections.Generic.List[double]
        $invalid = 0
        for ($i = 0; $i -lt $Samples; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $out = & $body 2>$null
            $exitCode = $LASTEXITCODE
            $sw.Stop()
            $firstLine = [string](@($out) | Select-Object -First 1)
            if ($exitCode -eq 0 -and $firstLine -match $versionPattern) {
                $times.Add($sw.Elapsed.TotalMilliseconds)
            } else {
                $invalid++
            }
        }
        $obj = [PSCustomObject]@{
            Category = $name
            Samples  = $Samples
            Valid    = $times.Count
            Invalid  = $invalid
            MinMs    = $null
            MedianMs = $null
            MeanMs   = $null
            MaxMs    = $null
        }
        if ($times.Count -gt 0) {
            $sorted = @($times | Sort-Object)
            $obj.MinMs    = [math]::Round($sorted[0], 1)
            $obj.MaxMs    = [math]::Round($sorted[$sorted.Count - 1], 1)
            $obj.MedianMs = [math]::Round($sorted[[int]($sorted.Count / 2)], 1)
            $obj.MeanMs   = [math]::Round((($sorted | Measure-Object -Average).Average), 1)
        }
        return $obj
    }

    Write-Host "=== grokgod launcher startup measurement ==="
    Write-Host "Host:    $env:COMPUTERNAME (host shell $($PSVersionTable.PSVersion))"
    Write-Host "Engine:  $engineReport"
    Write-Host "Fixture: $grokgodHome"
    Write-Host "Samples: $Samples per category"

    $results = @()
    $results += Measure-Category "full-launcher (cmd -> probe -> shim -> native)" {
        & cmd.exe /d /s /c "`"$grokLauncher`" --version"
    }
    if ($verifiedPwsh) {
        $directShell = $verifiedPwsh
        $results += Measure-Category "direct-shim (verified pwsh -File shim grok --version)" {
            & $directShell -NoProfile -ExecutionPolicy Bypass -File $resolvedShim grok --version
        }
    } else {
        $results += [PSCustomObject]@{
            Category = "direct-shim (verified pwsh -File shim grok --version)"
            Samples  = $Samples
            Valid    = 0
            Invalid  = 0
            MinMs    = $null
            MedianMs = $null
            MeanMs   = $null
            MaxMs    = $null
        }
        Write-Warning "No Resolve-GrokgodPwsh-verified pwsh.exe on this host; direct-shim category unsupported (purged)."
    }
    $results += Measure-Category "direct-native (mock.exe --version)" {
        & $mockExe --version
    }

    $results | Format-Table -AutoSize

    $full = @($results | Where-Object { $_.Category -like "full-launcher*" })[0]
    if ($full.Valid -eq 0) {
        Write-Warning "Full-launcher category had 0 valid samples on this host; timing unsupported here."
    } elseif ($full.MedianMs -gt 4000) {
        Write-Warning "Full-launcher median ($($full.MedianMs)ms) exceeds T3's 4-second reference budget. CI watchdogs are more generous; report the distinction in evidence."
    } else {
        Write-Host "T3 reference check: full-launcher median $($full.MedianMs)ms is within the 4-second budget ($($full.Valid)/$($full.Samples) valid samples)."
    }
} finally {
    foreach ($key in $envBackup.Keys) {
        if ($null -eq $envBackup[$key]) {
            Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$key" -Value $envBackup[$key]
        }
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
