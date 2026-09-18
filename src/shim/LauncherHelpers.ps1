<#
.SYNOPSIS
    Launcher generation helper for grokgod Windows installation (Task 3 helper).
.DESCRIPTION
    Generates thin .cmd launchers that invoke grok-shim.ps1 with positional identity.
#>
function New-GrokgodLauncherScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("grok", "grokgod")]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$ShimPath
    )

    $normalizedShim = $ShimPath.Trim()
    $template = @"
@echo off
rem grokgod thin launcher for Windows ($Identity)
setlocal

set "POWERSHELL_EXE="
pwsh.exe -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 goto try_powershell
set "POWERSHELL_EXE=pwsh.exe"
goto powershell_ready

:try_powershell
powershell.exe -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 goto powershell_unavailable
set "POWERSHELL_EXE=powershell.exe"
goto powershell_ready

:powershell_unavailable
>&2 echo grokgod: no runnable PowerShell engine found (pwsh.exe or powershell.exe)
exit /b 127

:powershell_ready

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "$normalizedShim" $Identity %*
exit /b %ERRORLEVEL%
"@
    return $template
}
