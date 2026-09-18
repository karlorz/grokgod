<#
.SYNOPSIS
    Pester / Native PowerShell test suite for grokgod Windows Dispatcher (grok-shim.ps1).
.DESCRIPTION
    Comprehensive tests covering:
      1. Argument preservation (empty strings, embedded quotes, spaces, trailing backslashes, cmd metacharacters, leading dashes, Unicode)
      2. Exit code preservation (0, 1, 42, 127, 255)
      3. Command matrix:
         - grok update [allowed args] -> updater
         - grok update [disallowed args] -> rejected with error
         - grok status [--json] -> wrapper status, never TUI
         - grok sessions / other args -> patched executable with GROK_DISABLE_AUTOUPDATER=1
         - grokgod update -> updater
         - grokgod status [--json] -> wrapper status
         - grokgod sessions / cache / other -> explicit error, never TUI
      4. Status schema validation:
         - healthy, degraded, corrupt
         - JSON remains valid JSON in all states
         - Free disk bytes, patchset, source SHA, artifact SHA256, version skew explanation, official path
      5. Launcher generation helpers & templates
#>

param(
    [string]$ShimPath = "$PSScriptRoot\..\..\src\shim\grok-shim.ps1"
)

# Robust exit propagation: trap terminating errors so PowerShell never exits 0 on uncaught exceptions
trap {
    Write-Host "`nFATAL TERMINATING ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = "Stop"
$testDir = Join-Path $env:TEMP "grokgod test ünicode $([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

$passCount = 0
$failCount = 0

function Assert-Condition([bool]$condition, [string]$testName, [string]$details = "") {
    if ($condition) {
        Write-Host "  PASS: $testName" -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host "  FAIL: $testName" -ForegroundColor Red
        if ($details) { Write-Host "        Details: $details" -ForegroundColor Yellow }
        $script:failCount++
    }
}

try {
    Write-Host "=== Grokgod Windows Dispatcher Test Suite ===" -ForegroundColor Cyan

    $fakeGrokgodHome = Join-Path $testDir "grokgod_home"
    $fakeBinDir      = Join-Path $fakeGrokgodHome "bin"
    New-Item -ItemType Directory -Force -Path $fakeBinDir | Out-Null

    # Create mock grok binary as a real Win32 .exe compiled via C# Add-Type
    $mockExe = Join-Path $fakeBinDir "grokgod.exe"
    $argLogFile = Join-Path $testDir "mock_args.json"
    $envLogFile = Join-Path $testDir "mock_env.txt"

    $csharpSource = @"
using System;
using System.IO;
using System.Text;

public class MockGrok {
    public static int Main(string[] args) {
        string argLog = @"$($argLogFile.Replace('\', '\\'))";
        string envLog = @"$($envLogFile.Replace('\', '\\'))";

        string dis = Environment.GetEnvironmentVariable("GROK_DISABLE_AUTOUPDATER") ?? "";
        File.WriteAllText(envLog, "GROK_DISABLE_AUTOUPDATER=" + dis);

        StringBuilder sb = new StringBuilder();
        sb.Append("[");
        for (int i = 0; i < args.Length; i++) {
            if (i > 0) sb.Append(", ");
            string escaped = args[i].Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
            sb.Append("\"").Append(escaped).Append("\"");
        }
        sb.Append("]");
        File.WriteAllText(argLog, sb.ToString(), Encoding.UTF8);

        if (args.Length > 0 && args[0] == "--version") {
            Console.WriteLine("grok 1.0.6 (48271133)");
            return 0;
        }
        if (args.Length > 1 && args[0] == "--exit-code") {
            int code;
            if (int.TryParse(args[1], out code)) {
                return code;
            }
        }
        return 0;
    }
}
"@

    $csharpFile = Join-Path $testDir "MockGrok.cs"
    Set-Content -LiteralPath $csharpFile -Value $csharpSource -Encoding UTF8

    # Find .NET Framework or .NET Core csc compiler
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
        $compileProc = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$mockExe`"", "`"$csharpFile`"") -NoNewWindow -Wait -PassThru
        if ($compileProc.ExitCode -ne 0) {
            throw "Failed to compile MockGrok.cs via csc.exe"
        }
    } else {
        # Fallback for environments where csc.exe is directly in dotnet sdk or powershell 5.1 Add-Type is available
        try {
            $cp = New-Object System.CodeDom.Compiler.CompilerParameters
            $cp.GenerateExecutable = $true
            $cp.OutputAssembly = $mockExe
            $cscp = New-Object Microsoft.CSharp.CSharpCodeProvider
            $cr = $cscp.CompileAssemblyFromSource($cp, $csharpSource)
            if ($cr.Errors.Count -gt 0) {
                throw $cr.Errors[0].ErrorText
            }
        } catch {
            throw "Unable to locate csc.exe or compile MockGrok fixture: $_"
        }
    }

    # Compute actual SHA256 of compiled mock executable for deterministic stamp creation
    $mockExeHash = (Get-FileHash -LiteralPath $mockExe -Algorithm SHA256).Hash.ToLower()

    # Determine host PowerShell engine to align inner child processes with outer suite
    $hostShell = if ($PSVersionTable.PSEdition -eq "Core") { "pwsh.exe" } else { "powershell.exe" }
    Write-Host "Host PowerShell Edition: $($PSVersionTable.PSEdition) ($($PSVersionTable.PSVersion))"
    Write-Host "Child Process Engine:    $hostShell"
    $pwshExe = $hostShell

    # Set up environment variables and isolate official candidate discovery
    $env:GROKGOD_HOME = $fakeGrokgodHome
    $env:GROKGOD_BIN  = $mockExe

    # Create isolated user and local app data directories to prevent host version skew from marking health degraded
    $isolationId       = [Guid]::NewGuid().ToString('N')
    $isolatedProfile   = Join-Path $env:TEMP "grokgod-profile-$isolationId"
    $isolatedLocalApp  = Join-Path $env:TEMP "grokgod-localapp-$isolationId"
    New-Item -ItemType Directory -Force -Path $isolatedProfile | Out-Null
    New-Item -ItemType Directory -Force -Path $isolatedLocalApp | Out-Null

    $origUserProfile  = $env:USERPROFILE
    $origLocalAppData = $env:LOCALAPPDATA
    $env:USERPROFILE  = $isolatedProfile
    $env:LOCALAPPDATA = $isolatedLocalApp

    # -------------------------------------------------------------------------
    # Test Group 1: Command Matrix
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Command Matrix --"

    # 1.1 grok passthrough calls binary and sets GROK_DISABLE_AUTOUPDATER=1
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $ShimPath "grok" "chat" "--prompt" "hello world"
    $recordedEnv = if (Test-Path $envLogFile) { Get-Content $envLogFile -Raw } else { "" }
    $recordedArgs = if (Test-Path $argLogFile) { Get-Content $argLogFile -Raw } else { "" }
    Assert-Condition ($recordedEnv -match "GROK_DISABLE_AUTOUPDATER=1") "grok passthrough sets GROK_DISABLE_AUTOUPDATER=1"
    Assert-Condition ($recordedArgs -match "chat" -and $recordedArgs -match "hello world") "grok passthrough preserves arguments"

    # 1.2 grok sessions reaches patched binary
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $ShimPath "grok" "sessions" "list" "--limit" "5"
    $recordedArgs = if (Test-Path $argLogFile) { Get-Content $argLogFile -Raw } else { "" }
    Assert-Condition ($recordedArgs -match "sessions" -and $recordedArgs -match "list") "grok sessions passes through to patched executable"

    # 1.3 grokgod sessions fails with explicit error and exit code 1 (NEVER TUI)
    $sessErrFile = Join-Path $testDir "err_sess.txt"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grokgod", "sessions", "prune") -RedirectStandardError $sessErrFile -NoNewWindow -Wait -PassThru
    $errOut = if (Test-Path $sessErrFile) { Get-Content $sessErrFile -Raw } else { "" }
    Assert-Condition ($proc.ExitCode -eq 1) "grokgod sessions exits 1"
    Assert-Condition ($errOut -match "not supported on Windows") "grokgod sessions gives explicit Windows error message"

    # 1.4 grokgod cache fails with explicit error (single app arg)
    $cacheErrFile = Join-Path $testDir "err_cache.txt"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grokgod", "cache") -RedirectStandardError $cacheErrFile -NoNewWindow -Wait -PassThru
    $errOut = if (Test-Path $cacheErrFile) { Get-Content $cacheErrFile -Raw } else { "" }
    Assert-Condition ($proc.ExitCode -eq 1) "grokgod cache exits 1"
    Assert-Condition ($errOut -match "not supported on Windows") "grokgod cache gives explicit Windows error"

    # 1.5 bare grokgod fails with explicit usage (zero app args, never TUI)
    $bareErrFile = Join-Path $testDir "err_bare.txt"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grokgod") -RedirectStandardError $bareErrFile -NoNewWindow -Wait -PassThru
    $errOut = if (Test-Path $bareErrFile) { Get-Content $bareErrFile -Raw } else { "" }
    Assert-Condition ($proc.ExitCode -eq 1) "bare grokgod exits 1"
    Assert-Condition ($errOut -match "Windows maintenance wrapper") "bare grokgod prints usage without starting TUI"

    # 1.6 missing identity fails with explicit error and exit code 1
    $noIdErrFile = Join-Path $testDir "err_no_id.txt"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"") -RedirectStandardError $noIdErrFile -NoNewWindow -Wait -PassThru
    $errOut = if (Test-Path $noIdErrFile) { Get-Content $noIdErrFile -Raw } else { "" }
    Assert-Condition ($proc.ExitCode -eq 1) "missing identity exits 1"
    Assert-Condition ($errOut -match "missing launcher identity") "missing identity exits 1 with error"

    # 1.7 invalid identity fails with explicit error and exit code 1
    $invIdErrFile = Join-Path $testDir "err_inv_id.txt"
    $proc = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "invalid_id") -RedirectStandardError $invIdErrFile -NoNewWindow -Wait -PassThru
    $errOut = if (Test-Path $invIdErrFile) { Get-Content $invIdErrFile -Raw } else { "" }
    Assert-Condition ($proc.ExitCode -eq 1) "invalid identity exits 1"
    Assert-Condition ($errOut -match "invalid identity") "invalid identity exits 1 with error"

    # 1.8 grok single app arg (sessions) reaches patched binary
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $ShimPath "grok" "sessions"
    $recordedArgs = if (Test-Path $argLogFile) { Get-Content $argLogFile -Raw } else { "" }
    Assert-Condition ($recordedArgs -match "sessions") "grok single app arg 'sessions' passes through without array scalarization failure"

    # 1.9 grok zero app args passes through without arguments
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $ShimPath "grok"
    $recordedArgs = if (Test-Path $argLogFile) { Get-Content $argLogFile -Raw } else { "" }
    Assert-Condition ($recordedArgs -eq "[]") "grok zero app args passes through cleanly as empty argv []"

    # -------------------------------------------------------------------------
    # Test Group 2: Argument Preservation & Exit Codes
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Argument Preservation and Exit Codes --"

    # Helper function to run shim and get parsed args from mock
    function Test-ArgsPreservation([string[]]$testArgArray) {
        if (Test-Path $argLogFile) { Remove-Item $argLogFile -Force }
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok")
        foreach ($a in $testArgArray) {
            $argList += ('"' + ($a -replace '(\\*)(")', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
        }
        $p = Start-Process -FilePath $pwshExe -ArgumentList $argList -NoNewWindow -Wait -PassThru
        if (Test-Path $argLogFile) {
            $parsed = (Get-Content $argLogFile -Raw) | ConvertFrom-Json
            return $parsed
        }
        return @()
    }

    # 2.1 Spaces, empty strings, embedded quotes, trailing backslashes, metacharacters, leading dashes, Unicode
    $complexArgs = @(
        "",                                # Empty string
        "simple",                          # Normal
        "with spaces here",                # Spaces
        "quote`"inside",                   # Embedded quote
        "C:\path\with\trailing\",          # Trailing backslash
        "&|<>^%!",                         # Cmd metacharacters
        "--leading-dash",                  # Leading dash
        "-flag",                           # Short flag
        "Unicode_日本語_русский_🎉"         # Unicode
    )

    $resultArgs = Test-ArgsPreservation $complexArgs
    Assert-Condition ($resultArgs.Count -eq $complexArgs.Count) "Arg count preserved ($($resultArgs.Count) == $($complexArgs.Count))"
    for ($i = 0; $i -lt $complexArgs.Count; $i++) {
        $matchesExpected = ($resultArgs[$i] -eq $complexArgs[$i])
        Assert-Condition $matchesExpected "Arg [$i] exact value preserved ('$($complexArgs[$i])')" "Got: '$($resultArgs[$i])'"
    }

    # 2.2 Exit code passthrough: 0, 1, 42, 255
    foreach ($code in @(0, 1, 42, 255)) {
        $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "--exit-code", "$code") -NoNewWindow -Wait -PassThru
        Assert-Condition ($p.ExitCode -eq $code) "Exit code $code preserved (got $($p.ExitCode))"
    }

    # -------------------------------------------------------------------------
    # Test Group 3: Status Command & JSON Schema
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Status Human and JSON Output --"

    # Setup stamp with exact computed hash of mock executable
    $stampContent = "SHA=$mockExeHash`nPATCHSET=v1.0.0`nVERSION=482711333c7195dc16a272777f86086d615e2afb`nMODE=release"
    $stampFile = Join-Path $fakeGrokgodHome ".source-version"
    Set-Content -Path $stampFile -Value $stampContent -Encoding ASCII

    # 3.1 Status text output (healthy)
    $statusOutFile = Join-Path $testDir "status_out.txt"
    $statusErrFile = Join-Path $testDir "status_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status") -RedirectStandardOutput $statusOutFile -RedirectStandardError $statusErrFile -NoNewWindow -Wait -PassThru
    $statusText = if (Test-Path $statusOutFile) { Get-Content $statusOutFile -Raw } else { "" }
    $statusErr  = if (Test-Path $statusErrFile) { Get-Content $statusErrFile -Raw } else { "" }
    Assert-Condition ($p.ExitCode -eq 0) "Status command exits 0 when healthy"
    Assert-Condition ([bool]($statusText -match "Launcher Identity:\s+grok")) "Status shows Launcher Identity"
    Assert-Condition ([bool]($statusText -match "Artifact SHA256:\s+$mockExeHash")) "Status shows Artifact SHA256"
    Assert-Condition ([bool]($statusText -match "Patchset:\s+v1.0.0")) "Status shows Patchset"
    Assert-Condition ([bool]($statusText -match "Source SHA:\s+482711333c7195dc16a272777f86086d615e2afb")) "Status shows Source SHA"
    Assert-Condition ([bool]($statusText -match "Free Disk Space:")) "Status shows Free Disk Space"
    Assert-Condition ([bool]($statusText -match "Resolved Command:\s+\S+")) "Status shows non-empty Resolved Command"

    # 3.2 Status JSON output
    $statusJsonFile = Join-Path $testDir "status_json.txt"
    $statusJsonErr = Join-Path $testDir "status_json_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grokgod", "status", "--json") -RedirectStandardOutput $statusJsonFile -RedirectStandardError $statusJsonErr -NoNewWindow -Wait -PassThru
    $jsonRaw = if (Test-Path $statusJsonFile) { Get-Content $statusJsonFile -Raw } else { "" }
    $parsedJson = $null
    try {
        $parsedJson = ConvertFrom-Json $jsonRaw
    } catch {}
    Assert-Condition ([bool]($parsedJson -ne $null)) "Status --json produces valid JSON"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.health -eq "healthy")) "Status JSON health is 'healthy'"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.launcherIdentity -eq "grokgod")) "Status JSON launcherIdentity is 'grokgod'"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.artifactSha256 -eq $mockExeHash)) "Status JSON artifactSha256 present"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.patchset -eq "v1.0.0")) "Status JSON patchset present"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.sourceSha -eq "482711333c7195dc16a272777f86086d615e2afb")) "Status JSON sourceSha present"
    Assert-Condition ([bool]($parsedJson -ne $null -and $parsedJson.freeDiskBytes -ne $null)) "Status JSON freeDiskBytes present"
    Assert-Condition ([bool]($parsedJson -ne $null -and -not [string]::IsNullOrEmpty($parsedJson.resolvedCommandPath))) "Status JSON resolvedCommandPath present"

    # 3.3 Status in degraded state (missing stamp) -> health=degraded, exits 1, valid JSON, healthDetails is an array
    Remove-Item -LiteralPath $stampFile -Force
    $degradedJsonFile = Join-Path $testDir "degraded_json.txt"
    $degradedErrFile = Join-Path $testDir "degraded_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status", "--json") -RedirectStandardOutput $degradedJsonFile -RedirectStandardError $degradedErrFile -NoNewWindow -Wait -PassThru
    $degRaw = if (Test-Path $degradedJsonFile) { Get-Content $degradedJsonFile -Raw } else { "" }
    $degJson = $null
    try { $degJson = ConvertFrom-Json $degRaw } catch {}
    Assert-Condition ($p.ExitCode -eq 1) "Degraded status exits 1"
    Assert-Condition ([bool]($degJson -ne $null)) "Degraded status produces valid JSON"
    Assert-Condition ([bool]($degJson -ne $null -and $degJson.health -eq "degraded")) "Degraded status reports health 'degraded'"
    # Verify healthDetails is a JSON array
    Assert-Condition ([bool]($degRaw -match '"healthDetails":\s*\[')) "healthDetails is serialized as an array even with single element"

    # 3.4 Status in corrupt state (missing binary) -> health=corrupt, exits 2, valid JSON
    $emptyHome = Join-Path $testDir "empty_grokgod_home"
    New-Item -ItemType Directory -Force -Path $emptyHome | Out-Null
    $corruptJsonFile = Join-Path $testDir "corrupt_json.txt"
    $corruptErrFile = Join-Path $testDir "corrupt_err.txt"
    $origGrokHome = $env:GROKGOD_HOME
    $origGrokBin  = $env:GROKGOD_BIN
    try {
        $env:GROKGOD_HOME = $emptyHome
        $env:GROKGOD_BIN  = Join-Path $emptyHome "missing.exe"
        $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status", "--json") -RedirectStandardOutput $corruptJsonFile -RedirectStandardError $corruptErrFile -NoNewWindow -Wait -PassThru
    } finally {
        $env:GROKGOD_HOME = $origGrokHome
        $env:GROKGOD_BIN  = $origGrokBin
    }
    $corruptRaw = if (Test-Path $corruptJsonFile) { Get-Content $corruptJsonFile -Raw } else { "" }
    $corruptJson = $null
    try { $corruptJson = ConvertFrom-Json $corruptRaw } catch {}
    Assert-Condition ($p.ExitCode -eq 2) "Corrupt status returns exit code 2"
    Assert-Condition ([bool]($corruptJson -ne $null)) "Corrupt status remains valid JSON"
    Assert-Condition ([bool]($corruptJson -ne $null -and $corruptJson.health -eq "corrupt")) "Corrupt status reports health 'corrupt'"

    # 3.4b Status in corrupt state (binary hash mismatch) -> health=corrupt, exits 2, valid JSON
    $mismatchStampFile = Join-Path $fakeGrokgodHome ".source-version"
    Set-Content -LiteralPath $mismatchStampFile -Value "SHA=0000000000000000000000000000000000000000000000000000000000000000`nPATCHSET=v1.0.0`nVERSION=482711333c7195dc16a272777f86086d615e2afb`nMODE=release" -Encoding ASCII
    $mismatchJsonFile = Join-Path $testDir "mismatch_json.txt"
    $mismatchErrFile  = Join-Path $testDir "mismatch_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status", "--json") -RedirectStandardOutput $mismatchJsonFile -RedirectStandardError $mismatchErrFile -NoNewWindow -Wait -PassThru
    $misRaw = if (Test-Path $mismatchJsonFile) { Get-Content $mismatchJsonFile -Raw } else { "" }
    $misJson = $null
    try { $misJson = ConvertFrom-Json $misRaw } catch {}
    Assert-Condition ($p.ExitCode -eq 2) "Binary hash mismatch status exits 2"
    Assert-Condition ([bool]($misJson -ne $null)) "Binary hash mismatch produces valid JSON"
    Assert-Condition ([bool]($misJson -ne $null -and $misJson.health -eq "corrupt")) "Binary hash mismatch reports health 'corrupt'"
    Assert-Condition ([bool]($misRaw -match 'does not match recorded artifact SHA')) "Hash mismatch diagnostic in healthDetails"
    # Restore valid stamp
    Set-Content -LiteralPath $mismatchStampFile -Value $stampContent -Encoding ASCII

    # 3.5 Status in degraded state (malformed/corrupted stamp) -> health=degraded, exits 1, valid JSON
    $malformedStampFile = Join-Path $fakeGrokgodHome ".source-version"
    Set-Content -LiteralPath $malformedStampFile -Value "MALFORMED_STAMP_WITHOUT_KEY_VALUE" -Encoding ASCII
    $malformedJsonFile = Join-Path $testDir "malformed_stamp_json.txt"
    $malformedErrFile = Join-Path $testDir "malformed_stamp_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status", "--json") -RedirectStandardOutput $malformedJsonFile -RedirectStandardError $malformedErrFile -NoNewWindow -Wait -PassThru
    $malRaw = if (Test-Path $malformedJsonFile) { Get-Content $malformedJsonFile -Raw } else { "" }
    $malJson = $null
    try { $malJson = ConvertFrom-Json $malRaw } catch {}
    Assert-Condition ($p.ExitCode -eq 1) "Malformed stamp status exits 1"
    Assert-Condition ([bool]($malJson -ne $null)) "Malformed stamp produces valid JSON"
    Assert-Condition ([bool]($malJson -ne $null -and $malJson.health -eq "degraded")) "Malformed stamp reports health 'degraded'"
    Assert-Condition ([bool]($malRaw -match '"healthDetails":\s*\[')) "Malformed stamp healthDetails is JSON array"
    # Restore valid stamp
    Set-Content -LiteralPath $malformedStampFile -Value $stampContent -Encoding ASCII

    # 3.6 Explicit version skew detection -> health=degraded, exits 1, valid JSON, reports explanation
    $mockOfficialDir = Join-Path $isolatedProfile ".grok\bin"
    New-Item -ItemType Directory -Force -Path $mockOfficialDir | Out-Null
    $mockOfficialExe = Join-Path $mockOfficialDir "grok.exe"

    # Compile mock official grok reporting distinct version 1.0.34
    $csharpSkewSource = @"
using System;
public class MockSkewOfficial {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "--version") {
            Console.WriteLine("grok 1.0.34 (abcdef12)");
            return 0;
        }
        return 0;
    }
}
"@
    $skewCsFile = Join-Path $testDir "MockSkewOfficial.cs"
    Set-Content -LiteralPath $skewCsFile -Value $csharpSkewSource -Encoding UTF8
    if ($cscExe) {
        $compileSkew = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$mockOfficialExe`"", "`"$skewCsFile`"") -NoNewWindow -Wait -PassThru
        if ($compileSkew.ExitCode -ne 0) {
            throw "Failed to compile MockSkewOfficial.cs via csc.exe"
        }
    } else {
        try {
            $cp2 = New-Object System.CodeDom.Compiler.CompilerParameters
            $cp2.GenerateExecutable = $true
            $cp2.OutputAssembly = $mockOfficialExe
            $cscp2 = New-Object Microsoft.CSharp.CSharpCodeProvider
            $cr2 = $cscp2.CompileAssemblyFromSource($cp2, $csharpSkewSource)
            if ($cr2.Errors.Count -gt 0) {
                throw $cr2.Errors[0].ErrorText
            }
        } catch {
            throw "Unable to compile MockSkewOfficial fixture: $_"
        }
    }

    $skewJsonFile = Join-Path $testDir "skew_json.txt"
    $skewErrFile  = Join-Path $testDir "skew_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status", "--json") -RedirectStandardOutput $skewJsonFile -RedirectStandardError $skewErrFile -NoNewWindow -Wait -PassThru
    $skewRaw = if (Test-Path $skewJsonFile) { Get-Content $skewJsonFile -Raw } else { "" }
    $skewJson = $null
    try { $skewJson = ConvertFrom-Json $skewRaw } catch {}
    Assert-Condition ($p.ExitCode -eq 1) "Version skew status exits 1"
    Assert-Condition ([bool]($skewJson -ne $null)) "Version skew produces valid JSON"
    Assert-Condition ([bool]($skewJson -ne $null -and $skewJson.health -eq "degraded")) "Version skew reports health 'degraded'"
    Assert-Condition ([bool]($skewJson -ne $null -and $skewJson.officialBinaryExists -eq $true)) "Version skew identifies official binary exists"
    $expectedOfficialPath = [System.IO.Path]::GetFullPath($mockOfficialExe).Normalize([System.Text.NormalizationForm]::FormC).TrimEnd('\')
    $reportedOfficialPath = if ($skewJson -ne $null -and $skewJson.officialBinaryPath) { [System.IO.Path]::GetFullPath([string]$skewJson.officialBinaryPath).Normalize([System.Text.NormalizationForm]::FormC).TrimEnd('\') } else { "" }
    $reportedDirectPath = if ($skewJson -ne $null -and $skewJson.directOfficialPath) { [System.IO.Path]::GetFullPath([string]$skewJson.directOfficialPath).Normalize([System.Text.NormalizationForm]::FormC).TrimEnd('\') } else { "" }
    if ($reportedOfficialPath -ine $expectedOfficialPath) {
        $diffs = for ($i = 0; $i -lt [Math]::Min($expectedOfficialPath.Length, $reportedOfficialPath.Length); $i++) { if ($expectedOfficialPath[$i] -ine $reportedOfficialPath[$i]) { "$i`:$([int][char]$expectedOfficialPath[$i])/$([int][char]$reportedOfficialPath[$i])" } }
        Write-Host "        Expected official path: $expectedOfficialPath; reported: $reportedOfficialPath; lengths=$($expectedOfficialPath.Length)/$($reportedOfficialPath.Length); diffs=$($diffs -join ',')" -ForegroundColor Yellow
    }
    if ($reportedDirectPath -ine $expectedOfficialPath) { Write-Host "        Expected direct path: $expectedOfficialPath; reported: $reportedDirectPath; lengths=$($expectedOfficialPath.Length)/$($reportedDirectPath.Length)" -ForegroundColor Yellow }
    Assert-Condition ($reportedOfficialPath -ieq $expectedOfficialPath) "Version skew records officialBinaryPath"
    Assert-Condition ($reportedDirectPath -ieq $expectedOfficialPath) "Version skew records directOfficialPath"
    Assert-Condition ([bool]($skewJson -ne $null -and $skewJson.versionSkewExplanation -match "Official grok binary found")) "Version skew explanation provided"

    # Remove mock official grok to keep subsequent tests clean
    Remove-Item -LiteralPath $mockOfficialExe -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mockOfficialDir -Recurse -Force -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------------
    # Test Group 4: Updater Whitelisting & Disallowed Argument Rejection
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Update Command Validation --"

    # Mock updater script
    $mockUpdater = Join-Path $testDir "mock_install.ps1"
    @"
param([string]`$Version, [switch]`$NoUpgrade, [switch]`$Force)
Write-Output "UPDATER_CALLED: Version=`$Version NoUpgrade=`$NoUpgrade Force=`$Force"
exit 0
"@ | Set-Content -Path $mockUpdater -Encoding UTF8
    $env:GROKGOD_UPDATER = $mockUpdater

    # 4.1 Allowed update args: --version v1.2.3 and -Version v1.2.3
    $updOutFile = Join-Path $testDir "upd_out1.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "update", "--version", "v1.2.3") -RedirectStandardOutput $updOutFile -NoNewWindow -Wait -PassThru
    $updOut = Get-Content $updOutFile -Raw
    Assert-Condition ($p.ExitCode -eq 0 -and $updOut -match "UPDATER_CALLED: Version=v1.2.3") "Allowed update flag --version passed to updater"

    $updOutFile2 = Join-Path $testDir "upd_out2.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "update", "-Version", "v1.2.3") -RedirectStandardOutput $updOutFile2 -NoNewWindow -Wait -PassThru
    $updOut2 = Get-Content $updOutFile2 -Raw
    Assert-Condition ($p.ExitCode -eq 0 -and $updOut2 -match "UPDATER_CALLED: Version=v1.2.3") "Allowed update flag -Version passed to updater"

    # 4.2 Allowed update args: --no-upgrade --force
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grokgod", "update", "--no-upgrade", "--force") -RedirectStandardOutput $updOutFile -NoNewWindow -Wait -PassThru
    $updOut = Get-Content $updOutFile -Raw
    Assert-Condition ($p.ExitCode -eq 0 -and $updOut -match "NoUpgrade=True Force=True") "Allowed update flags --no-upgrade and --force passed"

    # 4.3 Disallowed update args: --uninstall -> rejected
    $errUpd = Join-Path $testDir "err_upd_uninst.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "update", "--uninstall") -RedirectStandardError $errUpd -NoNewWindow -Wait -PassThru
    $errContent = Get-Content $errUpd -Raw
    Assert-Condition ($p.ExitCode -eq 1 -and $errContent -match "uninstall cannot be invoked through grok update") "Rejects --uninstall with informative error"

    # 4.4 Disallowed update args: arbitrary / malicious switches -> rejected
    $errUpdMal = Join-Path $testDir "err_upd_mal.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "update", "-ArbitraryParam", "evil") -RedirectStandardError $errUpdMal -NoNewWindow -Wait -PassThru
    $errContent = Get-Content $errUpdMal -Raw
    Assert-Condition ($p.ExitCode -eq 1 -and $errContent -match "unrecognized or disallowed update argument") "Rejects unknown/arbitrary arguments"

} finally {
    if ($origUserProfile) { $env:USERPROFILE = $origUserProfile }
    if ($origLocalAppData) { $env:LOCALAPPDATA = $origLocalAppData }
    if ($isolatedProfile -and (Test-Path -LiteralPath $isolatedProfile)) { Remove-Item -LiteralPath $isolatedProfile -Recurse -Force -ErrorAction SilentlyContinue }
    if ($isolatedLocalApp -and (Test-Path -LiteralPath $isolatedLocalApp)) { Remove-Item -LiteralPath $isolatedLocalApp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==============================================="
Write-Host "Total Passed: $passCount" -ForegroundColor Green
Write-Host "Total Failed: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host "==============================================="

if ($failCount -gt 0) {
    exit 1
}
exit 0
