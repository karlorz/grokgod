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

where pwsh >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "POWERSHELL_EXE=pwsh"
) else (
    set "POWERSHELL_EXE=powershell"
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "$normalizedShim" $Identity %*
exit /b %ERRORLEVEL%
"@
    return $template
}
