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
      6. Bounded status probe fixtures (version/empty/failure/hang/noisy-stderr/sleepy-child/held-eof)
      7. Full-launcher process fixtures via Node child_process (version/echo/protocol/failure/hang/noisy-stderr)
      8. Machine/protocol launch bypass (no cache read/write, no notice, no network;
         unrecognized leading flags and 'agent stdio' inside argument values stay ordinary)
      9. Detached refresh stdio isolation (caller EOF not held by the refresh child)
     10. PowerShell 7 prerequisite (verified runnable pwsh baked or discovered;
         broken/missing engine -> actionable exit 127, no Windows PowerShell fallback)
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

    # Create mock grok binary as a real Win32 .exe compiled via C# Add-Type.
    # Modes are selected with the GROKGOD_MOCK_MODE environment variable so the
    # same .exe can play every deterministic fixture role for both the
    # bounded status probe and the full-launcher (Node child_process) tests.
    $mockExe = Join-Path $fakeBinDir "grokgod.exe"
    $argLogFile = Join-Path $testDir "mock_args.json"
    $envLogFile = Join-Path $testDir "mock_env.txt"
    $launchLogFile = Join-Path $testDir "mock_launch.log"

    $csharpSource = @"
using System;
using System.IO;
using System.Text;
using System.Threading;

public class MockGrok {
    static void AppendLaunch(string logPath, string mode, string[] args) {
        if (String.IsNullOrEmpty(logPath)) { return; }
        try {
            StringBuilder sb = new StringBuilder();
            sb.Append(System.Diagnostics.Process.GetCurrentProcess().Id);
            sb.Append("|").Append(mode);
            foreach (string a in args) { sb.Append("|").Append(a.Length); }
            sb.Append("\n");
            File.AppendAllText(logPath, sb.ToString());
        } catch {}
    }

    public static int Main(string[] args) {
        string mode = Environment.GetEnvironmentVariable("GROKGOD_MOCK_MODE") ?? "";
        string argLog = @"$($argLogFile.Replace('\', '\\'))";
        string envLog = @"$($envLogFile.Replace('\', '\\'))";
        string launchLog = @"$($launchLogFile.Replace('\', '\\'))";

        AppendLaunch(launchLog, mode, args);

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

        // Fixture-only child role: hold the inherited pipes open, then exit.
        // Selected by argv (not the inherited mode env) so held-eof children
        // never recurse into mode dispatch.
        if (args.Length > 0 && args[0] == "fixture-hold-pipe") {
            int seconds = 5;
            if (args.Length > 1) { int.TryParse(args[1], out seconds); }
            Thread.Sleep(seconds * 1000);
            return 0;
        }

        if (mode == "echo") {
            Console.Error.WriteLine("FIXTURE-STDERR-MARKER");
            Stream stdin = Console.OpenStandardInput();
            Stream stdout = Console.OpenStandardOutput();
            byte[] buffer = new byte[65536];
            int read;
            while ((read = stdin.Read(buffer, 0, buffer.Length)) > 0) {
                stdout.Write(buffer, 0, read);
                stdout.Flush();
            }
            return 0;
        }

        if (mode == "protocol") {
            string line;
            using (StreamReader sr = new StreamReader(Console.OpenStandardInput())) {
                line = sr.ReadLine();
            }
            string payload = line ?? "";
            StringBuilder resp = new StringBuilder();
            resp.Append("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"capabilities\":{},\"echoLength\":");
            resp.Append(payload.Length);
            resp.Append("}}");
            Console.Out.WriteLine(resp.ToString());
            return 0;
        }

        if (mode == "hang") {
            Thread.Sleep(60000);
            Console.WriteLine("grok 1.0.6 (48271133)");
            return 0;
        }

        if (mode == "noisy-stderr") {
            Stream err = Console.OpenStandardError();
            byte[] chunk = new byte[8192];
            for (int i = 0; i < chunk.Length; i++) { chunk[i] = (byte)('a' + (i % 26)); }
            for (int i = 0; i < 16; i++) { err.Write(chunk, 0, chunk.Length); err.Flush(); }
            Console.Out.WriteLine("grok 1.0.6 (48271133)");
            return 0;
        }

        if (mode == "sleepy-child" || mode == "held-eof" || mode == "held-stderr-eof") {
            Console.Out.WriteLine("grok 1.0.6 (48271133)");
            Console.Out.Flush();
            int holdSeconds = (mode == "sleepy-child") ? 5 : 120;
            var child = new System.Diagnostics.Process();
            child.StartInfo.FileName = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
            child.StartInfo.Arguments = "fixture-hold-pipe " + holdSeconds;
            child.StartInfo.UseShellExecute = false;
            if (mode == "held-stderr-eof") {
                // Keep stdout free to EOF; only stderr stays inherited.
                child.StartInfo.RedirectStandardOutput = true;
                child.StartInfo.RedirectStandardInput = true;
            }
            child.Start();
            if (mode == "held-stderr-eof") {
                try { child.StandardInput.Close(); } catch {}
            }
            return 0;
        }

        if (mode == "failure") {
            int code = 1;
            string codeEnv = Environment.GetEnvironmentVariable("MOCK_EXIT_CODE");
            if (!String.IsNullOrEmpty(codeEnv)) { int.TryParse(codeEnv, out code); }
            return code;
        }

        if (args.Length > 0 && args[0] == "--version") {
            if (mode == "empty") { return 0; }
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

    # PS7-only suite: the suite itself must be hosted by PowerShell 7, and
    # every child it spawns runs under a real pwsh. There is deliberately no
    # powershell.exe child path — the only 5.1 surface is the narrow direct-
    # entry rejection test below.
    Write-Host "Host PowerShell Edition: $($PSVersionTable.PSEdition) ($($PSVersionTable.PSVersion))"
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
        throw "This suite requires PowerShell 7+; host is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }
    # Prefer a Resolve-GrokgodPwsh-verified real pwsh.exe over the bare
    # hosting-shell name: on Store-based hosts `pwsh.exe` is a WindowsApps
    # alias stub whose activation/console proxy can fail or mangle redirected
    # output in non-interactive contexts. The verified path is the same
    # engine the launcher bakes in.
    $verifiedPwsh = $null
    try {
        . (Join-Path (Resolve-Path "$PSScriptRoot\..\..").Path "src\shim\LauncherHelpers.ps1")
        $verifiedPwsh = Resolve-GrokgodPwsh
    } catch { $verifiedPwsh = $null }
    $pwshExe = if ($verifiedPwsh) { $verifiedPwsh } else { (Get-Command pwsh.exe -ErrorAction Stop).Source }
    Write-Host "Child Process Engine:    $pwshExe"

    # Narrow Windows PowerShell 5.1 entry test (the only powershell.exe
    # surface in this suite): a direct 5.1 invocation of the shim must be
    # rejected before any config/status side effect. Skipped when the host
    # has no powershell.exe.
    $legacyShell = $null
    try { $legacyShell = (Get-Command powershell.exe -ErrorAction Stop).Source } catch { $legacyShell = $null }
    if ($legacyShell) {
        $rejOut = Join-Path $testDir "ps5_reject_out.txt"
        $rejErr = Join-Path $testDir "ps5_reject_err.txt"
        $rp = Start-Process -FilePath $legacyShell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "status") -RedirectStandardOutput $rejOut -RedirectStandardError $rejErr -NoNewWindow -Wait -PassThru
        $rejErrText = if (Test-Path -LiteralPath $rejErr) { (Get-Content -LiteralPath $rejErr -Raw) } else { "" }
        Assert-Condition ($rp.ExitCode -ne 0) "Direct PS5.1 shim invocation is rejected with a nonzero exit (got $($rp.ExitCode))"
        Assert-Condition ($rejErrText -match "PowerShell 7") "PS5.1 rejection names the PowerShell 7 requirement"
    } else {
        Write-Host "  SKIP: powershell.exe not present for the narrow 5.1 rejection test" -ForegroundColor Yellow
    }

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
    $origUpdateCheckDisable = $env:GROKGOD_UPDATE_CHECK_DISABLE
    $env:USERPROFILE  = $isolatedProfile
    $env:LOCALAPPDATA = $isolatedLocalApp
    $env:GROKGOD_UPDATE_CHECK_DISABLE = "1"

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

    # 2.3 Cached release notice is exact and does not alter native exit status.
    # Captured stderr goes through Get-Content, which in Windows PowerShell 5.1
    # decodes without a BOM using the host's default code page, so the UTF-8
    # em dash the launcher writes can arrive as mojibake (for example the three
    # characters U+00E2 U+20AC U+201D for the bytes E2 80 94 under CP1252).
    # Normalize the known decodings back to U+2014, and guard the empty-file
    # $null that 5.1 hands back before any method call.
    function Get-CapturedStderr([string]$filePath) {
        if (-not (Test-Path -LiteralPath $filePath)) { return "" }
        # Raw bytes, UTF-8 only. The shim writes the notice as UTF-8 to the
        # stderr handle; no console-codepage heuristics.
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        if ($bytes.Length -eq 0) { return "" }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strictUtf8.GetString($bytes).Trim()
        return $text
    }

    $noticeStamp = Join-Path $fakeGrokgodHome ".source-version"
    $noticeCache = Join-Path $fakeGrokgodHome ".update-check"
    $noticeNow = [Int64][Math]::Floor(([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse('1970-01-01T00:00:00Z')).TotalSeconds)
    Set-Content -LiteralPath $noticeStamp -Value "SHA=$mockExeHash`nPATCHSET=v1.2.3`nVERSION=v1.2.3-preview.1`nMODE=release" -Encoding ASCII
    Set-Content -LiteralPath $noticeCache -Value "CHECKED_AT=$noticeNow`nVERSION=v2.0.0-rc.1" -Encoding ASCII
    $noticeErrFile = Join-Path $testDir "update_notice_err.txt"
    $env:GROKGOD_UPDATE_CHECK_DISABLE = "0"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "--exit-code", "42") -RedirectStandardError $noticeErrFile -NoNewWindow -Wait -PassThru
    $noticeErr = Get-CapturedStderr $noticeErrFile
    # Build the em dash by code point so Windows PowerShell 5.1 can parse this
    # UTF-8 test source even when it is loaded using the system code page.
    $expectedNotice = "[grokgod] v2.0.0-rc.1 available (installed: v1.2.3-preview.1) " + [char]0x2014 + " run 'grok update' to upgrade"
    Assert-Condition ($p.ExitCode -eq 42) "Update notice preserves native exit code 42"
    Assert-Condition ($noticeErr -eq $expectedNotice) "Cached update notice matches exact stderr contract" $noticeErr
    $noticeBytes = [System.IO.File]::ReadAllBytes($noticeErrFile)
    $foundUtf8Dash = $false
    for ($bi = 0; $bi -le $noticeBytes.Length - 3; $bi++) {
        if ($noticeBytes[$bi] -eq 0xE2 -and $noticeBytes[$bi + 1] -eq 0x80 -and $noticeBytes[$bi + 2] -eq 0x94) {
            $foundUtf8Dash = $true
            break
        }
    }
    Assert-Condition $foundUtf8Dash "Update notice stderr contains UTF-8 U+2014 bytes E2-80-94" ([BitConverter]::ToString($noticeBytes))
    # The equality above is the full contract; these pin its ASCII semantics and
    # the single-line shape so a mojibake-only failure cannot hide a payload bug.
    foreach ($fragment in @("[grokgod] v2.0.0-rc.1 available", "(installed: v1.2.3-preview.1)", "run 'grok update' to upgrade")) {
        Assert-Condition ($noticeErr.Contains($fragment)) "Update notice contains '$fragment'"
    }
    Assert-Condition (($noticeErr.Split("`n").Count -eq 1) -and (-not $noticeErr.Contains("`r"))) "Update notice is exactly one line"

    # Same numeric core (suffix-only difference), source mode, and administrative
    # cache dispatch remain silent.
    Set-Content -LiteralPath $noticeCache -Value "CHECKED_AT=$noticeNow`nVERSION=v1.2.3" -Encoding ASCII
    $silentErrFile = Join-Path $testDir "update_notice_silent_err.txt"
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "chat") -RedirectStandardError $silentErrFile -NoNewWindow -Wait -PassThru
    $silentErr = Get-CapturedStderr $silentErrFile
    Assert-Condition ([string]::IsNullOrEmpty($silentErr)) "Equal numeric version core emits no notice"
    Set-Content -LiteralPath $noticeStamp -Value "SHA=$mockExeHash`nPATCHSET=v1.2.3`nVERSION=v1.2.3`nMODE=source" -Encoding ASCII
    Set-Content -LiteralPath $noticeCache -Value "CHECKED_AT=$noticeNow`nVERSION=v9.0.0" -Encoding ASCII
    Remove-Item -LiteralPath $silentErrFile -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "chat") -RedirectStandardError $silentErrFile -NoNewWindow -Wait -PassThru
    $silentErr = Get-CapturedStderr $silentErrFile
    Assert-Condition ([string]::IsNullOrEmpty($silentErr)) "Source mode emits no update notice"
    Set-Content -LiteralPath $noticeStamp -Value "SHA=$mockExeHash`nPATCHSET=v1.2.3`nVERSION=v1.2.3`nMODE=release" -Encoding ASCII
    Remove-Item -LiteralPath $silentErrFile -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $pwshExe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ShimPath`"", "grok", "cache") -RedirectStandardError $silentErrFile -NoNewWindow -Wait -PassThru
    $silentErr = Get-CapturedStderr $silentErrFile
    Assert-Condition ([string]::IsNullOrEmpty($silentErr)) "Administrative cache command emits no update notice"
    $env:GROKGOD_UPDATE_CHECK_DISABLE = "1"

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

    # -------------------------------------------------------------------------
    # Test Group 5: Bounded Status Probe Fixtures
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Bounded Status Probe (probe-side fixtures) --"

    $RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

    function Get-FixtureMockProcesses {
        try {
            return @(Get-CimInstance -ClassName Win32_Process -Filter "ExecutablePath = '$mockExe'" -ErrorAction SilentlyContinue)
        } catch {
            return @()
        }
    }

    function Stop-FixtureMockProcesses {
        $procs = Get-FixtureMockProcesses
        foreach ($fp in $procs) {
            try { (Get-Process -Id $fp.ProcessId -ErrorAction SilentlyContinue).Kill() } catch {}
        }
        return $procs.Count
    }

    function Invoke-ShimStatusJson([hashtable]$ExtraEnv, [int]$TimeoutMs = 30000) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $pwshExe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ShimPath`" grok status --json"
        foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.Close() } catch {}
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { & taskkill.exe /T /F /PID $proc.Id 2>$null | Out-Null } catch {}
            try { $proc.Kill() } catch {}
            Stop-FixtureMockProcesses | Out-Null
        }
        # Wall-clock includes drains through caller EOF. A descendant holding
        # inherited pipes cannot extend this past TimeoutMs: after the drain
        # slice, kill only fixture-owned mock PIDs recorded from this exe.
        $drainMs = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $outDone = $false
        try { $outDone = $outTask.Wait($drainMs) } catch { $outDone = $false }
        $drainMs = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($drainMs -lt 0) { $drainMs = 0 }
        $errDone = $false
        try { $errDone = $errTask.Wait($drainMs) } catch { $errDone = $false }
        if (-not $outDone -or -not $errDone) {
            Stop-FixtureMockProcesses | Out-Null
            $drainMs = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($drainMs -lt 0) { $drainMs = 0 }
            try { $outDone = $outTask.Wait($drainMs) } catch {}
            $drainMs = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($drainMs -lt 0) { $drainMs = 0 }
            try { $errDone = $errTask.Wait($drainMs) } catch {}
        }
        $stdout = $null
        if ($outDone -and -not $outTask.IsFaulted -and -not $outTask.IsCanceled) { $stdout = [string]$outTask.Result }
        $stderr = $null
        if ($errDone -and -not $errTask.IsFaulted -and -not $errTask.IsCanceled) { $stderr = [string]$errTask.Result }
        $exitCode = $null
        try { if ($proc.HasExited) { $exitCode = $proc.ExitCode } } catch {}
        try { $proc.StandardInput.Dispose() } catch {}
        try { $proc.StandardOutput.Dispose() } catch {}
        try { $proc.StandardError.Dispose() } catch {}
        try { $proc.Dispose() } catch {}
        $sw.Stop()
        $parsed = $null
        try { $parsed = ($stdout | ConvertFrom-Json) } catch {}
        return [PSCustomObject]@{
            ExitCode = $exitCode
            ElapsedMs = $sw.ElapsedMilliseconds
            StdOut = $stdout
            StdErr = $stderr
            Json = $parsed
            Health = if ($parsed) { [string]$parsed.health } else { "<unparsed>" }
            Version = if ($parsed) { $parsed.patchedBinaryVersion } else { "<unparsed>" }
            TimedOut = (-not $exited -or -not $outDone -or -not $errDone)
            DrainComplete = ($outDone -and $errDone)
        }
    }

    # Healthy stamp for all probe fixtures (same compiled exe hash).
    Set-Content -LiteralPath $stampFile -Value $stampContent -Encoding ASCII

    # 5.1 version mode -> first nonempty line reported, healthy
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "version" }
    Assert-Condition ($r.ExitCode -eq 0 -and $r.Health -eq "healthy") "Probe version mode keeps status healthy"
    Assert-Condition ($r.Version -eq "grok 1.0.6 (48271133)") "Probe version mode reports version"

    # 5.2 empty output -> version null, healthy, bounded
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "empty" }
    Assert-Condition ($r.ExitCode -eq 0 -and $r.Health -eq "healthy") "Probe empty-output mode keeps status healthy"
    Assert-Condition ($r.Version -eq $null) "Probe empty-output mode reports null version"

    # 5.3 nonzero exit -> version null, healthy
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "failure"; "MOCK_EXIT_CODE" = "42" }
    Assert-Condition ($r.Version -eq $null) "Probe nonzero-exit mode reports null version"

    # 5.4 hang (sleeps past probe deadline) -> bounded return, null version, no survivor
    Stop-FixtureMockProcesses | Out-Null
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "hang" }
    Assert-Condition ($r.ElapsedMs -lt 10000) "Probe hang mode returns bounded ($($r.ElapsedMs)ms)" "budget 3000ms + cleanup 750ms + startup"
    Assert-Condition ($r.Version -eq $null) "Probe hang mode reports null version"
    Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Probe hang mode leaves no surviving fixture process"

    # 5.5 noisy stderr (exceeds pipe buffer before stdout/exit) -> version still captured
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "noisy-stderr" }
    Assert-Condition ($r.Version -eq "grok 1.0.6 (48271133)") "Probe noisy-stderr mode reports version (concurrent drain)"

    # 5.6 sleepy child (parent prints version, exits; child holds EOF 5s) -> bounded, null version
    Stop-FixtureMockProcesses | Out-Null
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "sleepy-child" }
    Assert-Condition ($r.ElapsedMs -lt 10000) "Probe sleepy-child returns bounded ($($r.ElapsedMs)ms)"
    Assert-Condition ($r.Version -eq $null) "Probe sleepy-child reports null version (EOF not held open past budget)"
    Start-Sleep -Seconds 7
    Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Probe sleepy-child leaves no surviving fixture process after child expires"

    # 5.7 held EOF (fixture-owned descendant holds the pipe 120s) -> bounded, null, cleanup kills holder
    Stop-FixtureMockProcesses | Out-Null
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "held-eof" }
    Assert-Condition ($r.ElapsedMs -lt 10000) "Probe held-eof returns bounded ($($r.ElapsedMs)ms)"
    Assert-Condition ($r.DrainComplete -eq $true) "Probe held-eof caller drains reach EOF within the helper budget"
    Assert-Condition ($r.Version -eq $null) "Probe held-eof reports null version"
    $killed = Stop-FixtureMockProcesses
    Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Probe held-eof fixture cleanup leaves no surviving fixture process"

    # 5.8 stderr-only held EOF: stdout delivers a version line, a descendant
    # holds stderr. Fail-closed (null version), bounded.
    Stop-FixtureMockProcesses | Out-Null
    $r = Invoke-ShimStatusJson -ExtraEnv @{ "GROKGOD_MOCK_MODE" = "held-stderr-eof" }
    Assert-Condition ($r.ElapsedMs -lt 10000) "Probe held-stderr-eof returns bounded ($($r.ElapsedMs)ms)"
    Assert-Condition ($r.DrainComplete -eq $true) "Probe held-stderr-eof caller drains reach EOF within the helper budget"
    Assert-Condition ($r.Version -eq $null) "Probe held-stderr-eof reports null version (stderr drain incomplete)"
    $killed = Stop-FixtureMockProcesses
    Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Probe held-stderr-eof fixture cleanup leaves no surviving fixture process"

    # -------------------------------------------------------------------------
    # Test Group 6: Full-Launcher Process Fixtures via Node child_process
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Full-Launcher Process Fixtures (Node child_process topology) --"

    $nodeExe = $null
    try { $nodeExe = (Get-Command node -ErrorAction Stop).Source } catch { $nodeExe = $null }

    # Generate launchers with New-GrokgodLauncherScript into the isolated home.
    $helpersSource = Join-Path $RepoRoot "src\shim\LauncherHelpers.ps1"
    . $helpersSource
    $launcherDir = Join-Path $testDir "launchers"
    New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
    $resolvedShim = (Resolve-Path $ShimPath).Path
    $grokLauncher = Join-Path $launcherDir "grok.cmd"
    # Bake the verified engine path when one was resolved; the launcher
    # then works even where PATH cannot see pwsh (e.g. non-interactive
    # provider spawns). Discovery-only launcher when unresolvable.
    $bakedPwsh = ""
    if ($verifiedPwsh) { $bakedPwsh = $verifiedPwsh }
    Set-Content -LiteralPath $grokLauncher -Value (New-GrokgodLauncherScript -Identity grok -ShimPath $resolvedShim -PwshPath $bakedPwsh) -Encoding ASCII
    if ($verifiedPwsh) {
        Write-Host "  Launcher engine: $verifiedPwsh (verified)"
    } else {
        Write-Host "  Launcher engine: discovery (no verified pwsh resolved)" -ForegroundColor Yellow
    }
    $driverJs = Join-Path $RepoRoot "tests\shim\launcher_fixture_driver.js"

    function Get-DriverEnv([string]$mode) {
        $m = @{
            "GROKGOD_HOME" = $fakeGrokgodHome
            "GROKGOD_BIN" = $mockExe
            "GROKGOD_SHIM_PATH" = $resolvedShim
            "GROKGOD_UPDATE_CHECK_DISABLE" = "1"
            "USERPROFILE" = $isolatedProfile
            "LOCALAPPDATA" = $isolatedLocalApp
        }
        if ($mode) { $m["GROKGOD_MOCK_MODE"] = $mode }
        return $m
    }

    if (-not $nodeExe) {
        Write-Host "  SKIP: node.exe not found; full-launcher fixture group requires Node.js" -ForegroundColor Yellow
    } else {
        Write-Host "Node driver engine: $nodeExe"

        function Invoke-NodeLauncherFixture([string]$cmdPath, [hashtable]$EnvMap, [string[]]$ArgTokens, [string]$stdinB64 = "", [int]$TimeoutMs = 15000) {
            $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
            $argsFile = Join-Path $testDir ("driver_args_" + [Guid]::NewGuid().ToString('N') + ".json")
            $envFile = Join-Path $testDir ("driver_env_" + [Guid]::NewGuid().ToString('N') + ".json")
            # The unary comma keeps the array/hashtable intact on the pipeline:
            # without it, ConvertTo-Json sees a single-element array's element
            # (or nothing for an empty one) and emits a non-array JSON value.
            # Serialize the token array element-by-element: pipeline-based
            # ConvertTo-Json unwraps single-element arrays differently on
            # Windows PowerShell 5.1 (emits the bare string, not a JSON
            # array), which the driver rejects. Per-element scalar
            # serialization emits a deterministic JSON array on every engine
            # and preserves empty tokens as "".
            $argsJson = "[" + (($ArgTokens | ForEach-Object { ConvertTo-Json -InputObject ([string]$_) -Compress }) -join ",") + "]"
            [System.IO.File]::WriteAllText($argsFile, $argsJson, $noBomUtf8)
            [System.IO.File]::WriteAllText($envFile, (,$EnvMap | ConvertTo-Json -Compress), $noBomUtf8)
            $argList = @("`"$driverJs`"", "--cmd", "`"$cmdPath`"", "--args-file", "`"$argsFile`"", "--env-file", "`"$envFile`"", "--timeout-ms", "$TimeoutMs")
            if ($stdinB64) { $argList += @("--stdin-b64", "`"$stdinB64`"") }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $nodeExe
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.Arguments = [string]::Join(" ", $argList)
            $proc = [System.Diagnostics.Process]::Start($psi)
            # Outer concurrent-drain watchdog: async reads run while the
            # process is bounded by the driver's own watchdog plus its hard
            # cap. The blocking ReadToEnd-before-WaitForExit pattern is
            # avoided so a node/driver failure cannot hang the suite.
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $exited = $proc.WaitForExit($TimeoutMs + 30000)
            if (-not $exited) {
                try { & taskkill.exe /T /F /PID $proc.Id 2>$null | Out-Null } catch {}
                try { $proc.Kill() } catch {}
            }
            $stdout = $null
            try { if ($outTask.Wait(5000) -and -not $outTask.IsFaulted -and -not $outTask.IsCanceled) { $stdout = [string]$outTask.Result } } catch {}
            try { if ($errTask.Wait(5000) -and -not $errTask.IsFaulted -and -not $errTask.IsCanceled) { $errTask.Result | Out-Null } } catch {}
            try { $proc.Close() } catch {}
            $parsed = $null
            try { $parsed = ($stdout.Trim() | ConvertFrom-Json) } catch {}
            return $parsed
        }

        # 6.1 version through the full launcher
        Stop-FixtureMockProcesses | Out-Null
        if (Test-Path $launchLogFile) { Remove-Item $launchLogFile -Force }
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "") -ArgTokens @("--version")
        Assert-Condition ($res -ne $null) "Launcher fixture driver returned a report (version)"
        if ($res) {
            Assert-Condition ($res.ok -eq $true -and $res.exitCode -eq 0) "Full-launcher --version exits 0 (got exit=$($res.exitCode) error=$($res.error))"
            $driverStdout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stdoutB64))
            Assert-Condition ($driverStdout -match "grok 1\.0\.6 \(48271133\)") "Full-launcher --version prints version"
            Assert-Condition ($res.closeMs -ne $null -and $res.closeMs -lt 15000) "Full-launcher --version close is bounded ($($res.closeMs)ms)"
        }

        # 6.2 echo mode: stdin passes through EOF with exact bytes, distinct stderr marker
        $echoBytes = [byte[]]@(0, 1, 2, 10, 13, 250, 251, 65, 66, 67)
        $echoB64 = [Convert]::ToBase64String($echoBytes)
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "echo") -ArgTokens @("echo") -stdinB64 $echoB64
        Assert-Condition ($res -ne $null) "Launcher fixture driver returned a report (echo)"
        if ($res) {
            $roundtrip = [Convert]::FromBase64String($res.stdoutB64)
            $byteExact = ($roundtrip.Length -eq $echoBytes.Length)
            if ($byteExact) { for ($i = 0; $i -lt $echoBytes.Length; $i++) { if ($roundtrip[$i] -ne $echoBytes[$i]) { $byteExact = $false; break } } }
            Assert-Condition $byteExact "Full-launcher echo preserves exact stdout bytes through EOF"
            $driverStderr = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stderrB64))
            Assert-Condition ($driverStderr -match "FIXTURE-STDERR-MARKER") "Full-launcher echo carries distinct stderr marker"
            Assert-Condition ($res.exitCode -eq 0) "Full-launcher echo exits 0"
        }

        # 6.3 protocol mode: minimal initialize gets an NDJSON response
        $initLine = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
        $initB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($initLine + "`n"))
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "protocol") -ArgTokens @("agent", "stdio") -stdinB64 $initB64
        Assert-Condition ($res -ne $null) "Launcher fixture driver returned a report (protocol)"
        if ($res) {
            $protoOut = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stdoutB64))
            $protoLine = ($protoOut -split "`n")[0]
            $protoJson = $null
            try { $protoJson = ($protoLine | ConvertFrom-Json) } catch {}
            Assert-Condition ($protoJson -ne $null -and $protoJson.jsonrpc -eq "2.0") "Full-launcher protocol mode answers NDJSON initialize"
            Assert-Condition ($res.exitCode -eq 0) "Full-launcher protocol mode exits 0"
        }

        # 6.4 failure modes: exit codes preserved, exactly one launch recorded
        foreach ($code in @(1, 42, 255)) {
            if (Test-Path $launchLogFile) { Remove-Item $launchLogFile -Force }
            $envMap = Get-DriverEnv "failure"
            $envMap["MOCK_EXIT_CODE"] = "$code"
            $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap $envMap -ArgTokens @("chat")
            $launchCount = if (Test-Path $launchLogFile) { @(Get-Content $launchLogFile | Where-Object { $_ -match '\S' }).Count } else { 0 }
            Assert-Condition ($res -ne $null -and $res.exitCode -eq $code) "Full-launcher failure mode exits $code (got $(if ($res) { $res.exitCode } else { 'no report' }))"
            Assert-Condition ($launchCount -eq 1) "Full-launcher failure mode records exactly one launch (no rerun)"
        }

        # 6.5 hang mode: watchdog bounds the run, tree kill leaves no survivors
        Stop-FixtureMockProcesses | Out-Null
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "hang") -ArgTokens @("chat") -TimeoutMs 12000
        Assert-Condition ($res -ne $null -and $res.timedOut -eq $true) "Full-launcher hang mode hits the driver watchdog"
        if ($res) {
            Assert-Condition ($res.closeMs -ne $null -and $res.closeMs -lt 25000) "Full-launcher hang mode close is bounded ($($res.closeMs)ms)"
        }
        Start-Sleep -Milliseconds 500
        Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Full-launcher hang mode leaves no surviving fixture process"

        # 6.6 noisy-stderr mode: stderr saturated past pipe buffer, version still delivered
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "noisy-stderr") -ArgTokens @("--version")
        Assert-Condition ($res -ne $null -and $res.exitCode -eq 0) "Full-launcher noisy-stderr exits 0"
        if ($res) {
            Assert-Condition ($res.stderrLen -ge 131072) "Full-launcher noisy-stderr saturated the pipe ($($res.stderrLen) bytes)"
            $driverStdout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stdoutB64))
            Assert-Condition ($driverStdout -match "grok 1\.0\.6 \(48271133\)") "Full-launcher noisy-stderr still delivers version"
        }
        Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Full-launcher fixtures leave no surviving fixture process"

        # 6.6b Node parent observes whole-call EOF for status --json while a
        # fixture descendant holds the probe pipes 120s. closeMs is the
        # external caller completion, not the inner probe stopwatch.
        Stop-FixtureMockProcesses | Out-Null
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap (Get-DriverEnv "held-eof") -ArgTokens @("status", "--json") -TimeoutMs 15000
        Assert-Condition ($res -ne $null -and $res.timedOut -eq $false) "Node parent held-eof status does not hit the driver watchdog"
        if ($res) {
            Assert-Condition ($res.closeMs -ne $null -and $res.closeMs -lt 10000) "Node parent held-eof close is bounded ($($res.closeMs)ms)"
            $eofGap = $res.closeMs - $res.exitMs
            Assert-Condition ($eofGap -lt 3000) "Node parent held-eof exit-to-close gap is small ($eofGap ms)"
        }
        Stop-FixtureMockProcesses | Out-Null
        Assert-Condition (@(Get-FixtureMockProcesses).Count -eq 0) "Node parent held-eof leaves no surviving fixture process"

        # 6.7 launcher-level argument preservation. Direct %* forwarding
        # plus the driver's CRT quote/backslash then twice CMD-metachar
        # escaping (windowsVerbatimArguments) is the proven native
        # transport. The argv log is the receipt; a sentinel token must
        # remain data and never execute.
        if (Test-Path $argLogFile) { Remove-Item $argLogFile -Force }
        $launcherArgs = @(
            "",
            "with spaces",
            'quote"inside',
            "C:\path\with\trailing\",
            "&|<>^%!",
            "Unicode_日本語_🧪",
            "%GROKGOD_AUDIT_LITERAL%",
            'a" & echo GROKGOD_ARGV_SENTINEL',
            "& echo GROKGOD_ARGV_SENTINEL"
        )
        $argvEnv = Get-DriverEnv ""
        $argvEnv["GROKGOD_AUDIT_LITERAL"] = "EXPANDED"
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap $argvEnv -ArgTokens $launcherArgs
        Assert-Condition ($res -ne $null -and $res.ok -eq $true) "Driver reports ok for the argv case"
        Assert-Condition ($res -ne $null -and $res.exitCode -eq 0) "Driver argv case child exits 0"
        Assert-Condition ($res -ne $null -and $res.timedOut -eq $false) "Driver argv case does not hit the watchdog"
        Assert-Condition ($res -ne $null -and $res.closeMs -ne $null) "Driver argv case reports close timing"
        $driverStdout = ""
        $driverStderr = ""
        if ($res) {
            try { $driverStdout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stdoutB64)) } catch {}
            try { $driverStderr = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stderrB64)) } catch {}
        }
        Assert-Condition ($driverStdout -notmatch '(?m)^GROKGOD_ARGV_SENTINEL$' -and $driverStderr -notmatch '(?m)^GROKGOD_ARGV_SENTINEL$') "Argv sentinel is never executed as a command"
        $recordedArgs = $null
        if (Test-Path $argLogFile) { try { $recordedArgs = (Get-Content $argLogFile -Raw | ConvertFrom-Json) } catch {} }
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs.Count -eq 9) "Full-launcher preserves argument count through cmd"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[0] -eq "") "Full-launcher preserves empty arguments"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[1] -eq "with spaces") "Full-launcher preserves spaces in arguments"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[2] -eq 'quote"inside') "Full-launcher preserves embedded quotes exactly"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[3] -eq "C:\path\with\trailing\") "Full-launcher preserves trailing backslashes"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[4] -eq "&|<>^%!") "Full-launcher preserves cmd metacharacters"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[5] -eq "Unicode_日本語_🧪") "Full-launcher preserves supplementary Unicode"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[6] -eq "%GROKGOD_AUDIT_LITERAL%") "Full-launcher preserves literal %VAR% without expansion"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[7] -eq 'a" & echo GROKGOD_ARGV_SENTINEL') "Full-launcher preserves combined quote+metachar as one token"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[8] -eq "& echo GROKGOD_ARGV_SENTINEL") "Full-launcher preserves standalone metachar token"

        # 6.8 leading flags plus a sentinel token: the shim sees identity
        # then the full argv, and the sentinel still does not execute.
        if (Test-Path $argLogFile) { Remove-Item $argLogFile -Force }
        $flagArgs = @("-m", "flash-max", "agent", "stdio", 'a" & echo GROKGOD_ARGV_SENTINEL')
        $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap $argvEnv -ArgTokens $flagArgs
        Assert-Condition ($res -ne $null -and $res.exitCode -eq 0) "Leading-flag argv case exits 0"
        $driverStdout = ""
        $driverStderr = ""
        if ($res) {
            try { $driverStdout = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stdoutB64)) } catch {}
            try { $driverStderr = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($res.stderrB64)) } catch {}
        }
        Assert-Condition ($driverStdout -notmatch '(?m)^GROKGOD_ARGV_SENTINEL$' -and $driverStderr -notmatch '(?m)^GROKGOD_ARGV_SENTINEL$') "Leading-flag sentinel is never executed"
        $recordedArgs = $null
        if (Test-Path $argLogFile) { try { $recordedArgs = (Get-Content $argLogFile -Raw | ConvertFrom-Json) } catch {} }
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs.Count -eq 5) "Leading-flag argv preserves count"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[0] -eq "-m" -and $recordedArgs[1] -eq "flash-max" -and $recordedArgs[2] -eq "agent" -and $recordedArgs[3] -eq "stdio") "Leading-flag argv preserves flag tokens"
        Assert-Condition ($recordedArgs -ne $null -and $recordedArgs[4] -eq 'a" & echo GROKGOD_ARGV_SENTINEL') "Leading-flag argv preserves the sentinel token"
    }

    # -------------------------------------------------------------------------
    # Test Group 7: Machine/Protocol Launch Bypass (no cache, no network)
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing Machine/Protocol Launch Bypass --"

    $bypassListenerProc = $null
    try {
        $bypassRequestLog = Join-Path $testDir "bypass_request.log"
        Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
        $bypassPort = 19443
        $bypassListenerScript = Join-Path $testDir "bypass_listener.ps1"
        @"
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add("http://127.0.0.1:$bypassPort/")
`$listener.Start()
while (`$listener.IsListening) {
    try {
        `$context = `$listener.GetContext()
        `$req = `$context.Request
        `$res = `$context.Response
        `$p = `$req.Url.AbsolutePath
        [System.IO.File]::AppendAllText("$($bypassRequestLog.Replace('\', '\\'))", `$p + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
        if (`$p -eq "/slow") { Start-Sleep -Seconds 8 }
        `$body = '{"tag_name":"v2.0.0"}'
        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$body)
        `$res.ContentType = "application/json"
        `$res.ContentLength64 = `$bytes.Length
        `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
        `$res.OutputStream.Close()
    } catch { break }
}
"@ | Set-Content -LiteralPath $bypassListenerScript -Encoding UTF8

        $bypassPsi = New-Object System.Diagnostics.ProcessStartInfo
        $bypassPsi.FileName = $pwshExe
        $bypassPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$bypassListenerScript`""
        $bypassPsi.UseShellExecute = $false
        $bypassPsi.CreateNoWindow = $true
        $bypassListenerProc = [System.Diagnostics.Process]::Start($bypassPsi)
        $bypassBaseUrl = "http://127.0.0.1:$bypassPort"
        $listenerReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 100
            try {
                $resp = Invoke-WebRequest -Uri "$bypassBaseUrl/warmup" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
                if ($resp -and $resp.StatusCode -eq 200) { $listenerReady = $true; break }
            } catch {}
        }
        Assert-Condition $listenerReady "Bypass test listener became ready"

        function Invoke-ShimWithEnv([string[]]$ShimArgs, [hashtable]$ExtraEnv, [string]$stderrFile) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $pwshExe
            $psi.UseShellExecute = $false
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$ShimPath`""
            foreach ($a in $ShimArgs) {
                if ($a -match '[\s"]|\\$') {
                    $esc = $a -replace '(\\*)(")', '$1$1\"'
                    $esc = $esc -replace '(\\+)$', '$1$1'
                    $argString += ' "' + $esc + '"'
                } else {
                    $argString += " " + $a
                }
            }
            $psi.Arguments = $argString
            foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit(30000) | Out-Null
            $stderr = $proc.StandardError.ReadToEnd()
            if ($stderrFile) { Set-Content -LiteralPath $stderrFile -Value $stderr -Encoding UTF8 }
            return [PSCustomObject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
        }

        function Reset-BypassCache([Int64]$checkedAt) {
            # Release-mode stamp with an eligible installed version so the
            # update-notice gate actually engages during these tests.
            Set-Content -LiteralPath $stampFile -Value "SHA=$mockExeHash`nPATCHSET=v1.0.0`nVERSION=v1.0.0`nMODE=release" -Encoding ASCII
            Set-Content -LiteralPath $noticeCache -Value "CHECKED_AT=$checkedAt`nVERSION=v2.0.0" -Encoding ASCII
        }

        function Read-BypassRequests {
            if (Test-Path $bypassRequestLog) { return @(Get-Content $bypassRequestLog | Where-Object { $_ -match '\S' }) }
            return @()
        }

        # The detached refresh child fires shortly AFTER the caller exits, so
        # request assertions poll briefly instead of racing the child's engine
        # startup + HTTP round trip.
        function Wait-BypassRequest([string]$needle, [int]$timeoutMs = 8000) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
            while ([DateTime]::UtcNow -lt $deadline) {
                if (@(Read-BypassRequests) -contains $needle) { return $true }
                Start-Sleep -Milliseconds 250
            }
            return $false
        }

        $bypassEnv = @{
            "GROKGOD_UPDATE_CHECK_URL" = ($bypassBaseUrl.TrimEnd('/') + '/')
            "GROKGOD_UPDATE_CHECK_DISABLE" = "0"
            "GROKGOD_MOCK_MODE" = "version"
        }

        # 7.0 control: ordinary interactive path with stale cache fires the refresh
        Reset-BypassCache -checkedAt 1
        Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
        $controlErr = Join-Path $testDir "bypass_control_err.txt"
        $res = Invoke-ShimWithEnv -ShimArgs @("grok", "chat") -ExtraEnv $bypassEnv -stderrFile $controlErr
        $cacheAfterControl = Get-Content $noticeCache -Raw
        Assert-Condition (Wait-BypassRequest "/") "Ordinary path fires the detached refresh (request logged)"
        Assert-Condition ($cacheAfterControl -match 'CHECKED_AT=[0-9]{9,}') "Ordinary path advances the refresh timestamp"
        Assert-Condition ((Get-CapturedStderr $controlErr) -match '\[grokgod\] v2\.0\.0 available') "Ordinary path prints the cached update notice"

        # 7.0b Same process: stale-cache ordinary chat starts the isolated
        # refresh helper then mock passthrough, with stdout and stderr merged
        # to one OS handle (cmd 2>&1). Proves inherit flags are restored
        # even when GetStdHandle(STD_OUTPUT)==GetStdHandle(STD_ERROR).
        Reset-BypassCache -checkedAt 1
        Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
        $mergedOut = Join-Path $testDir "merged_stdout_stderr.txt"
        if (Test-Path -LiteralPath $mergedOut) { Remove-Item -LiteralPath $mergedOut -Force }
        $inner = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" grok chat >"{2}" 2>&1' -f $pwshExe, $ShimPath, $mergedOut
        $mpsi = New-Object System.Diagnostics.ProcessStartInfo
        $mpsi.FileName = (Join-Path $env:SystemRoot "System32\cmd.exe")
        $mpsi.Arguments = "/d /s /c `"$inner`""
        $mpsi.UseShellExecute = $false
        $mpsi.CreateNoWindow = $true
        $mpsi.EnvironmentVariables["GROKGOD_HOME"] = $fakeGrokgodHome
        $mpsi.EnvironmentVariables["GROKGOD_BIN"] = $mockExe
        $mpsi.EnvironmentVariables["GROKGOD_UPDATE_CHECK_URL"] = ($bypassBaseUrl.TrimEnd('/') + '/')
        $mpsi.EnvironmentVariables["GROKGOD_UPDATE_CHECK_DISABLE"] = "0"
        $mpsi.EnvironmentVariables["GROKGOD_MOCK_MODE"] = "noisy-stderr"
        $mpsi.EnvironmentVariables["USERPROFILE"] = $isolatedProfile
        $mpsi.EnvironmentVariables["LOCALAPPDATA"] = $isolatedLocalApp
        $mproc = [System.Diagnostics.Process]::Start($mpsi)
        $mergedExited = $mproc.WaitForExit(30000)
        if (-not $mergedExited) {
            try { & taskkill.exe /T /F /PID $mproc.Id 2>$null | Out-Null } catch {}
            try { $mproc.Kill() } catch {}
        }
        $mergedExit = $null
        try { if ($mproc.HasExited) { $mergedExit = $mproc.ExitCode } } catch {}
        try { $mproc.Dispose() } catch {}
        Assert-Condition $mergedExited "Merged 2>&1 ordinary path returns before the 30s owned-root watchdog"
        $mergedBytes = @()
        if (Test-Path -LiteralPath $mergedOut) { $mergedBytes = [System.IO.File]::ReadAllBytes($mergedOut) }
        $mergedText = ""
        if ($mergedBytes.Length -gt 0) {
            $mergedText = ([Text.UTF8Encoding]::new($false, $true)).GetString($mergedBytes)
        }
        Assert-Condition ($mergedExit -eq 0) "Merged 2>&1 ordinary path preserves mock exit 0 after helper (got $mergedExit)"
        Assert-Condition ($mergedText -match 'grok 1\.0\.6 \(48271133\)') "Merged 2>&1 ordinary path delivers mock version stdout after helper"
        Assert-Condition ($mergedText -match '\[grokgod\] v2\.0\.0 available') "Merged 2>&1 ordinary path still emits the cached notice"
        Assert-Condition (Wait-BypassRequest "/") "Merged 2>&1 ordinary path fires the detached refresh"

        # 7.1 machine/protocol forms: no notice, no cache write, no network
        $machineForms = @(
            @("grok", "--version"),
            @("grok", "-V"),
            @("grok", "--help"),
            @("grok", "-h"),
            @("grok", "help"),
            @("grok", "models"),
            @("grok", "inspect"),
            @("grok", "agent", "stdio"),
            @("grok", "-m", "flash-max", "agent", "stdio"),
            @("grok", "--minimal", "--version"),
            @("grok", "--model=flash-max", "agent", "stdio")
        )
        $bypassPass = $true
        foreach ($form in $machineForms) {
            Reset-BypassCache -checkedAt 1
            Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
            $cacheBefore = Get-Content $noticeCache -Raw
            $formErrFile = Join-Path $testDir ("bypass_err_" + ($form -join "_").Replace("-", "x") + ".txt")
            $res = Invoke-ShimWithEnv -ShimArgs $form -ExtraEnv $bypassEnv -stderrFile $formErrFile
            $cacheAfter = Get-Content $noticeCache -Raw
            $formErr = Get-CapturedStderr $formErrFile
            $requests = @(Read-BypassRequests).Count
            if ($formErr -match '\[grokgod\]') { $bypassPass = $false; Write-Host "        notice leaked on $($form -join ' '): $formErr" -ForegroundColor Yellow }
            if ($cacheAfter -ne $cacheBefore) { $bypassPass = $false; Write-Host "        cache mutated on $($form -join ' ')" -ForegroundColor Yellow }
            if ($requests -ne 0) { $bypassPass = $false; Write-Host "        network fired on $($form -join ' ')" -ForegroundColor Yellow }
        }
        Assert-Condition $bypassPass "Machine/protocol forms bypass cache, notice, and network"

        # 7.2 future-dated cache stays untouched on machine paths
        Reset-BypassCache -checkedAt 9999999999
        $cacheBefore = Get-Content $noticeCache -Raw
        $res = Invoke-ShimWithEnv -ShimArgs @("grok", "--version") -ExtraEnv $bypassEnv
        $cacheAfter = Get-Content $noticeCache -Raw
        Assert-Condition ($cacheAfter -eq $cacheBefore) "Machine path leaves future-dated cache untouched"

        # 7.3 value containing 'agent stdio' is NOT a protocol launch
        Reset-BypassCache -checkedAt 1
        Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
        $valueErr = Join-Path $testDir "bypass_value_err.txt"
        $res = Invoke-ShimWithEnv -ShimArgs @("grok", "chat", "--prompt", "please agent stdio now") -ExtraEnv $bypassEnv -stderrFile $valueErr
        $cacheAfterValue = Get-Content $noticeCache -Raw
        Assert-Condition ($cacheAfterValue -match 'CHECKED_AT=[0-9]{9,}') "Argument value containing 'agent stdio' stays on the ordinary path (cache advanced)"
        Assert-Condition ((Get-CapturedStderr $valueErr) -match '\[grokgod\] v2\.0\.0 available') "Ordinary path for value containing 'agent stdio' still shows notice"

        # 7.4 an UNRECOGNIZED leading flag is not part of the machine/protocol
        # grammar: the invocation must fall back to the ordinary path (cache
        # advanced, notice shown), never silently bypass the update check.
        Reset-BypassCache -checkedAt 1
        $bogusErr = Join-Path $testDir "bypass_bogus_err.txt"
        $res = Invoke-ShimWithEnv -ShimArgs @("grok", "--definitely-not-a-real-flag", "--version") -ExtraEnv $bypassEnv -stderrFile $bogusErr
        $cacheAfterBogus = Get-Content $noticeCache -Raw
        Assert-Condition ($cacheAfterBogus -match 'CHECKED_AT=[0-9]{9,}') "Unrecognized leading flag stays on the ordinary path (cache advanced)"
        Assert-Condition ((Get-CapturedStderr $bogusErr) -match '\[grokgod\] v2\.0\.0 available') "Unrecognized leading flag still shows the cached notice"

        # ---------------------------------------------------------------------
        # Test Group 8: Detached Refresh Must Not Hold the Caller's EOF
        # ---------------------------------------------------------------------
        Write-Host "`n-- Testing Detached Refresh stdio Isolation Through the Launcher --"

        if (-not $nodeExe) {
            Write-Host "  SKIP: node.exe not found; EOF isolation fixture requires Node.js" -ForegroundColor Yellow
        } else {
            # Stale cache forces a refresh; the slow endpoint keeps the refresh
            # child alive ~8s after the launcher exits. The caller must see
            # stdout/stderr EOF immediately, not when the refresh child exits.
            Reset-BypassCache -checkedAt 1
            Set-Content -LiteralPath $bypassRequestLog -Value "" -Encoding ASCII
            $slowEnv = Get-DriverEnv "version"
            $slowEnv["GROKGOD_UPDATE_CHECK_URL"] = ($bypassBaseUrl.TrimEnd('/') + '/slow')
            Remove-Item Env:GROKGOD_UPDATE_CHECK_DISABLE -ErrorAction SilentlyContinue
            $slowEnv.Remove("GROKGOD_UPDATE_CHECK_DISABLE")
            $res = Invoke-NodeLauncherFixture -cmdPath $grokLauncher -EnvMap $slowEnv -ArgTokens @("chat") -TimeoutMs 25000
            $eofGap = $res.closeMs - $res.exitMs
            Assert-Condition ($res.exitCode -eq 0) "Launcher exits 0 while refresh child is still running"
            Assert-Condition (Wait-BypassRequest "/slow") "Detached refresh fired against the slow endpoint"
            Assert-Condition ($eofGap -lt 3000) "Caller EOF is not held by the detached refresh (exit->close gap $($eofGap)ms)"
        }

        # Restore the disabled-update-check isolation for any later runs
        $env:GROKGOD_UPDATE_CHECK_DISABLE = "1"
    } finally {
        if ($bypassListenerProc -and -not $bypassListenerProc.HasExited) {
            try { $bypassListenerProc.Kill() } catch {}
        }
    }

    # -------------------------------------------------------------------------
    # Test Group 9: Launcher Engine Probe Fallbacks
    # -------------------------------------------------------------------------
    Write-Host "`n-- Testing PowerShell 7 Prerequisite (launcher engine selection) --"

    $failingEngineSrc = @"
using System;
public class MockFailingEngine {
    public static int Main(string[] args) { return 1; }
}
"@
    $failingCsFile = Join-Path $testDir "MockFailingEngine.cs"
    Set-Content -LiteralPath $failingCsFile -Value $failingEngineSrc -Encoding UTF8
    $failingEngineExe = Join-Path $testDir "MockFailingEngine.exe"
    if ($cscExe) {
        $compileFailEngine = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$failingEngineExe`"", "`"$failingCsFile`"") -NoNewWindow -Wait -PassThru
        if ($compileFailEngine.ExitCode -ne 0) { throw "Failed to compile MockFailingEngine.cs" }
    } else {
        $cp3 = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp3.GenerateExecutable = $true
        $cp3.OutputAssembly = $failingEngineExe
        $cscp3 = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cr3 = $cscp3.CompileAssemblyFromSource($cp3, $failingEngineSrc)
        if ($cr3.Errors.Count -gt 0) { throw $cr3.Errors[0].ErrorText }
    }

    $fakeEngineDir = Join-Path $testDir "fake engines"
    New-Item -ItemType Directory -Force -Path $fakeEngineDir | Out-Null
    Copy-Item $failingEngineExe (Join-Path $fakeEngineDir "pwsh.exe") -Force

    function Invoke-LauncherWithPath([string]$cmdPath, [string]$childPath, [string[]]$ArgTokens, [hashtable]$ExtraEnv, [string]$WorkingDirectory) {
        $argString = "/d /s /c `"`"$cmdPath`""
        foreach ($a in $ArgTokens) { $argString += " " + $a }
        $argString += "`""
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $env:SystemRoot "System32\cmd.exe")
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        # where.exe searches the child current directory before PATH. Keep
        # cwd on an empty fixture so host PSHOME/workspace pwsh.exe cannot
        # satisfy discovery. Production launchers are unchanged.
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.EnvironmentVariables["PATH"] = $childPath
        foreach ($clearKey in @("GROKGOD_POWERSHELL", "GROKGOD_POWERSHELL_BAKED")) {
            if ($psi.EnvironmentVariables.ContainsKey($clearKey) -and -not $ExtraEnv.ContainsKey($clearKey)) {
                $psi.EnvironmentVariables.Remove($clearKey)
            }
        }
        foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Concurrent-drain watchdog: async reads while the launcher is
        # bounded; a stuck tree is killed at the owned root PID.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit(30000)
        if (-not $exited) {
            try { & taskkill.exe /T /F /PID $proc.Id 2>$null | Out-Null } catch {}
            try { $proc.Kill() } catch {}
        }
        $stdout = $null
        try { if ($outTask.Wait(5000) -and -not $outTask.IsFaulted -and -not $outTask.IsCanceled) { $stdout = [string]$outTask.Result } } catch {}
        $stderr = ""
        try { if ($errTask.Wait(5000) -and -not $errTask.IsFaulted -and -not $errTask.IsCanceled) { $stderr = [string]$errTask.Result } } catch {}
        # Capture the exit code BEFORE Close/Dispose: once the handle is
        # released, ExitCode renders empty. (Root cause of the wt3v6 group-9
        # failures: every case reported an empty exit code here.)
        $exitCode = $null
        try { $exitCode = $proc.ExitCode } catch {}
        try { $proc.Close() } catch {}
        try { $proc.Dispose() } catch {}
        $whereChild = ""
        try {
            $wpsi = New-Object System.Diagnostics.ProcessStartInfo
            $wpsi.FileName = "$env:SystemRoot\System32\where.exe"
            $wpsi.Arguments = "pwsh.exe"
            $wpsi.UseShellExecute = $false
            $wpsi.RedirectStandardOutput = $true
            $wpsi.RedirectStandardError = $true
            $wpsi.CreateNoWindow = $true
            if ($WorkingDirectory) { $wpsi.WorkingDirectory = $WorkingDirectory }
            $wpsi.EnvironmentVariables["PATH"] = $childPath
            foreach ($k in $ExtraEnv.Keys) { $wpsi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
            $wp = [System.Diagnostics.Process]::Start($wpsi)
            $whereChild = $wp.StandardOutput.ReadToEnd()
            $wp.WaitForExit(5000) | Out-Null
            try { $wp.Dispose() } catch {}
        } catch { $whereChild = "where-failed: $_" }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            StdOut = [string]$stdout
            StdErr = [string]$stderr
            WorkingDirectory = $WorkingDirectory
            ChildPath = $childPath
            WherePwsh = $whereChild
            EnvProgramFiles = [string]$ExtraEnv["ProgramFiles"]
            EnvProgramFilesX86 = [string]$ExtraEnv["ProgramFiles(x86)"]
            EnvProgramW6432 = [string]$ExtraEnv["ProgramW6432"]
            CmdText = (Get-Content -LiteralPath $cmdPath -Raw)
            ParentGrokgodPwsh = [string]$env:GROKGOD_POWERSHELL
            ParentBaked = [string]$env:GROKGOD_POWERSHELL_BAKED
            PsiHasOverride = $psi.EnvironmentVariables.ContainsKey("GROKGOD_POWERSHELL")
            PsiHasBaked = $psi.EnvironmentVariables.ContainsKey("GROKGOD_POWERSHELL_BAKED")
        }
    }

    $emptyPf64 = Join-Path $testDir "empty-pf64"
    $emptyPf86 = Join-Path $testDir "empty-pf86"
    New-Item -ItemType Directory -Force -Path $emptyPf64, $emptyPf86 | Out-Null
    $emptyPathDir = Join-Path $testDir "empty path"
    New-Item -ItemType Directory -Force -Path $emptyPathDir | Out-Null
    $system32Only = Join-Path $env:SystemRoot "System32"

    # Discovery-only launcher: group 9.1/9.2/9.4 must not inherit a baked
    # engine from the group-6 launcher, or isolation would never 127.
    $discoveryLauncher = Join-Path $launcherDir "grok-discovery.cmd"
    Set-Content -LiteralPath $discoveryLauncher -Value (New-GrokgodLauncherScript -Identity grok -ShimPath $resolvedShim) -Encoding ASCII

    $oldEngineSrc = @"
using System;
public class MockOldEngine {
    public static int Main(string[] args) {
        Console.WriteLine("5.1.22621.2506");
        return 1;
    }
}
"@
    $oldCsFile = Join-Path $testDir "MockOldEngine.cs"
    Set-Content -LiteralPath $oldCsFile -Value $oldEngineSrc -Encoding UTF8
    $oldEngineExe = Join-Path $testDir "MockOldEngine.exe"
    if ($cscExe) {
        $compileOldEngine = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$oldEngineExe`"", "`"$oldCsFile`"") -NoNewWindow -Wait -PassThru
        if ($compileOldEngine.ExitCode -ne 0) { throw "Failed to compile MockOldEngine.cs" }
    } else {
        $cp4 = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp4.GenerateExecutable = $true
        $cp4.OutputAssembly = $oldEngineExe
        $cscp4 = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cr4 = $cscp4.CompileAssemblyFromSource($cp4, $oldEngineSrc)
        if ($cr4.Errors.Count -gt 0) { throw $cr4.Errors[0].ErrorText }
    }
    $oldEngineDir = Join-Path $testDir "old engine"
    New-Item -ItemType Directory -Force -Path $oldEngineDir | Out-Null
    Copy-Item $oldEngineExe (Join-Path $oldEngineDir "pwsh.exe") -Force

    $engineEnv = @{
        "GROKGOD_HOME" = $fakeGrokgodHome
        "GROKGOD_BIN" = $mockExe
        "GROKGOD_SHIM_PATH" = $resolvedShim
        "GROKGOD_UPDATE_CHECK_DISABLE" = "1"
        "USERPROFILE" = $isolatedProfile
        "LOCALAPPDATA" = $isolatedLocalApp
        "ProgramFiles" = $emptyPf64
        "ProgramFiles(x86)" = $emptyPf86
        "ProgramW6432" = $emptyPf64
    }

    # 9.1 PATH-resolved pwsh fails the runnable/>=7 verification -> the
    # launcher refuses with actionable guidance (no silent 5.1 fallback).
    # Both ProgramFiles roots are empty fixture dirs in the CHILD env only,
    # so a host standard install cannot satisfy discovery.
    $res = Invoke-LauncherWithPath -cmdPath $discoveryLauncher -childPath $fakeEngineDir -ArgTokens @("--version") -ExtraEnv $engineEnv -WorkingDirectory $emptyPathDir
    if ($res.ExitCode -ne 127) {
        Write-Host "GROUP9-DIAG broken: exit=$($res.ExitCode) cwd=$($res.WorkingDirectory) PATH=$($res.ChildPath) PF=$($res.EnvProgramFiles) PF86=$($res.EnvProgramFilesX86) W6432=$($res.EnvProgramW6432)"
        Write-Host "GROUP9-DIAG where.exe pwsh: $($res.WherePwsh)"
        Write-Host "GROUP9-DIAG cmd: $($res.CmdText)"
        Write-Host "GROUP9-DIAG stderr: $($res.StdErr)"
    }
    Assert-Condition ($res.ExitCode -eq 127) "Broken pwsh verification exits 127 (got $($res.ExitCode))"
    Assert-Condition ($res.StdErr -match "PowerShell 7\+ is required") "Broken pwsh prints actionable prerequisite stderr"
    Assert-Condition ($res.StdErr -match "winget install") "Actionable stderr names the winget install command"

    # 9.1b candidate that starts and reports <7 is rejected the same way.
    $res = Invoke-LauncherWithPath -cmdPath $discoveryLauncher -childPath $oldEngineDir -ArgTokens @("--version") -ExtraEnv $engineEnv -WorkingDirectory $emptyPathDir
    if ($res.ExitCode -ne 127) {
        Write-Host "GROUP9-DIAG old: exit=$($res.ExitCode) cwd=$($res.WorkingDirectory) PATH=$($res.ChildPath) where=$($res.WherePwsh) stderr=$($res.StdErr)"
    }
    Assert-Condition ($res.ExitCode -eq 127) "pwsh <7 verification exits 127 (got $($res.ExitCode))"
    Assert-Condition ($res.StdErr -match "PowerShell 7\+ is required") "pwsh <7 prints actionable prerequisite stderr"

    # 9.2 no pwsh anywhere on PATH and no standard ProgramFiles install.
    $res = Invoke-LauncherWithPath -cmdPath $discoveryLauncher -childPath $emptyPathDir -ArgTokens @("--version") -ExtraEnv $engineEnv -WorkingDirectory $emptyPathDir
    if ($res.ExitCode -ne 127) {
        Write-Host "GROUP9-DIAG missing: exit=$($res.ExitCode) cwd=$($res.WorkingDirectory) PATH=$($res.ChildPath) PF=$($res.EnvProgramFiles) W6432=$($res.EnvProgramW6432) parentOverride=$($res.ParentGrokgodPwsh) psiHasOverride=$($res.PsiHasOverride) psiHasBaked=$($res.PsiHasBaked)"
        Write-Host "GROUP9-DIAG where.exe pwsh: $($res.WherePwsh)"
        Write-Host "GROUP9-DIAG cmd: $($res.CmdText)"
        Write-Host "GROUP9-DIAG stderr: $($res.StdErr)"
    }
    Assert-Condition ($res.ExitCode -eq 127) "No pwsh on PATH exits 127 (got $($res.ExitCode))"
    Assert-Condition ($res.StdErr -match "PowerShell 7\+ is required") "No pwsh on PATH prints actionable prerequisite stderr"

    # 9.3 launcher with a baked verified engine path works even when PATH
    # cannot resolve pwsh and ProgramFiles is empty (the non-interactive
    # provider-spawn case).
    if ($verifiedPwsh) {
        $bakedLauncher = Join-Path $launcherDir "grok-baked.cmd"
        Set-Content -LiteralPath $bakedLauncher -Value (New-GrokgodLauncherScript -Identity grok -ShimPath $resolvedShim -PwshPath $verifiedPwsh) -Encoding ASCII
        $res = Invoke-LauncherWithPath -cmdPath $bakedLauncher -childPath $system32Only -ArgTokens @("--version") -ExtraEnv $engineEnv -WorkingDirectory $emptyPathDir
        Assert-Condition ($res.ExitCode -eq 0 -and $res.StdOut -match "grok 1\.0\.6") "Baked verified pwsh works with pwsh-free PATH"
    } else {
        throw "This suite requires a verified runnable PowerShell 7 engine to bake and to prove standard discovery."
    }

    # 9.4 genuine standard discovery: child PATH cannot resolve pwsh, but a
    # standard ProgramFiles layout derived from the verified engine (not
    # inherited host globals) still launches.
    $stdEnv = $engineEnv.Clone()
    if ($verifiedPwsh -match '(?i)[\\/]PowerShell[\\/]7[\\/]pwsh\.exe$') {
        $pfRoot = Split-Path (Split-Path (Split-Path $verifiedPwsh -Parent) -Parent) -Parent
        if ($pfRoot -eq [string]${env:ProgramFiles(x86)}) {
            $stdEnv["ProgramFiles(x86)"] = $pfRoot
            $stdEnv["ProgramFiles"] = $emptyPf64
        } else {
            $stdEnv["ProgramFiles"] = $pfRoot
            $stdEnv["ProgramW6432"] = $pfRoot
            $stdEnv["ProgramFiles(x86)"] = $emptyPf86
        }
        $expectStdPwsh = Join-Path $pfRoot "PowerShell\7\pwsh.exe"
        $res = Invoke-LauncherWithPath -cmdPath $discoveryLauncher -childPath $system32Only -ArgTokens @("--version") -ExtraEnv $stdEnv -WorkingDirectory $emptyPathDir
        if (-not ($res.ExitCode -eq 0 -and $res.StdOut -match "grok 1\.0\.6")) {
            Write-Host "GROUP9-DIAG std: exit=$($res.ExitCode) verified=$verifiedPwsh pfRoot=$pfRoot expect=$expectStdPwsh exists=$(Test-Path -LiteralPath $expectStdPwsh)"
            Write-Host "GROUP9-DIAG std cwd=$($res.WorkingDirectory) PATH=$($res.ChildPath) W6432=$($res.EnvProgramW6432) where=$($res.WherePwsh)"
            Write-Host "GROUP9-DIAG std stdout=$($res.StdOut)"
            Write-Host "GROUP9-DIAG std stderr=$($res.StdErr)"
            Write-Host "GROUP9-DIAG std cmd=$($res.CmdText)"
        }
        Assert-Condition ($res.ExitCode -eq 0 -and $res.StdOut -match "grok 1\.0\.6") "Standard ProgramFiles discovery finds verified pwsh with pwsh-free PATH"
    } else {
        $pwshDir = Split-Path $verifiedPwsh -Parent
        $res = Invoke-LauncherWithPath -cmdPath $discoveryLauncher -childPath $pwshDir -ArgTokens @("--version") -ExtraEnv $engineEnv -WorkingDirectory $emptyPathDir
        Assert-Condition ($res.ExitCode -eq 0 -and $res.StdOut -match "grok 1\.0\.6") "PATH discovery finds verified pwsh when it is not under PowerShell\7"
    }

    # 9.5 Get-GrokgodPwshVersion fail-closes when stdout completes but a
    # descendant holds stderr EOF.
    $heldSrc = @"
using System;
using System.Diagnostics;
using System.Threading;
public class MockHeldStderrEngine {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "hold") {
            Thread.Sleep(120000);
            return 0;
        }
        Console.Out.WriteLine("7.4.6");
        Console.Out.Flush();
        var child = new Process();
        child.StartInfo.FileName = Process.GetCurrentProcess().MainModule.FileName;
        child.StartInfo.Arguments = "hold";
        child.StartInfo.UseShellExecute = false;
        child.StartInfo.RedirectStandardOutput = true;
        child.StartInfo.RedirectStandardInput = true;
        child.Start();
        try { child.StandardInput.Close(); } catch {}
        return 0;
    }
}
"@
    $heldCs = Join-Path $testDir "MockHeldStderrEngine.cs"
    Set-Content -LiteralPath $heldCs -Value $heldSrc -Encoding UTF8
    $heldExe = Join-Path $testDir "MockHeldStderrEngine.exe"
    if ($cscExe) {
        $compileHeld = Start-Process -FilePath $cscExe -ArgumentList @("/nologo", "/target:exe", "`"/out:$heldExe`"", "`"$heldCs`"") -NoNewWindow -Wait -PassThru
        if ($compileHeld.ExitCode -ne 0) { throw "Failed to compile MockHeldStderrEngine.cs" }
    } else {
        $cp5 = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp5.GenerateExecutable = $true
        $cp5.OutputAssembly = $heldExe
        $cscp5 = New-Object Microsoft.CSharp.CSharpCodeProvider
        $cr5 = $cscp5.CompileAssemblyFromSource($cp5, $heldSrc)
        if ($cr5.Errors.Count -gt 0) { throw $cr5.Errors[0].ErrorText }
    }
    $heldSw = [System.Diagnostics.Stopwatch]::StartNew()
    $heldVer = Get-GrokgodPwshVersion -Path $heldExe -TimeoutMs 3000
    $heldSw.Stop()
    Assert-Condition ($heldVer -eq $null) "Get-GrokgodPwshVersion returns null when stderr EOF is held"
    Assert-Condition ($heldSw.ElapsedMilliseconds -lt 8000) "Get-GrokgodPwshVersion stderr-held case is bounded ($($heldSw.ElapsedMilliseconds)ms)"
    try {
        Get-CimInstance -ClassName Win32_Process -Filter "ExecutablePath = '$($heldExe.Replace('\','\\'))'" -ErrorAction SilentlyContinue | ForEach-Object {
            try { (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).Kill() } catch {}
        }
    } catch {}

} finally {
    if ($origUserProfile) { $env:USERPROFILE = $origUserProfile }
    if ($origLocalAppData) { $env:LOCALAPPDATA = $origLocalAppData }
    if ($origUpdateCheckDisable -ne $null) {
        $env:GROKGOD_UPDATE_CHECK_DISABLE = $origUpdateCheckDisable
    } else {
        Remove-Item Env:GROKGOD_UPDATE_CHECK_DISABLE -ErrorAction SilentlyContinue
    }
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
