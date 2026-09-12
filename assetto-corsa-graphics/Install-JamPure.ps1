<#
.SYNOPSIS
    Installs the JamPure graphics pack for Assetto Corsa (Content Manager + CSP + Pure).

.DESCRIPTION
    Copies every part of the pack to the folder Assetto Corsa / Content Manager
    expects it in:

      ppfilters\*.ini                 -> <AC>\system\cfg\ppfilters\
      ppfilters\Pure scripts\*.lua    -> <AC>\system\cfg\ppfilters\Pure scripts\
      pure-config\*.ini               -> <AC>\extension\config-ext\Pure\
      csp-presets\*.ini               -> %LOCALAPPDATA%\AcTools Content Manager\Presets\Custom Shaders Patch\
      cm-video-presets\*.cmpreset     -> %LOCALAPPDATA%\AcTools Content Manager\Presets\Video Settings\

    The Assetto Corsa folder is found through the Steam registry entry and
    steamapps\libraryfolders.vdf. Pass -AcRoot if it lives somewhere else.

.PARAMETER AcRoot
    Path to the assettocorsa folder (the one that contains acs.exe).

.PARAMETER WhatIf
    Show what would be copied without touching anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-JamPure.ps1

.EXAMPLE
    .\Install-JamPure.ps1 -AcRoot "D:\Games\assettocorsa" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AcRoot
)

$ErrorActionPreference = 'Stop'
$packRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-AcRoot {
    $candidates = @()

    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in 'SteamPath', 'InstallPath') {
                if ($props.$name) { $candidates += ($props.$name -replace '/', '\') }
            }
        } catch { }
    }

    $libraries = @()
    foreach ($steam in $candidates | Select-Object -Unique) {
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in Get-Content $vdf) {
                if ($line -match '^\s*"path"\s+"(.+)"\s*$') {
                    $libraries += ($Matches[1] -replace '\\\\', '\')
                }
            }
        }
    }

    foreach ($lib in $libraries | Select-Object -Unique) {
        $ac = Join-Path $lib 'steamapps\common\assettocorsa'
        if (Test-Path (Join-Path $ac 'acs.exe')) { return $ac }
    }
    return $null
}

if (-not $AcRoot) { $AcRoot = Find-AcRoot }
if (-not $AcRoot -or -not (Test-Path (Join-Path $AcRoot 'acs.exe'))) {
    throw "Could not find Assetto Corsa. Run again with -AcRoot 'X:\path\to\assettocorsa'."
}

$cmPresets = Join-Path $env:LOCALAPPDATA 'AcTools Content Manager\Presets'

$jobs = @(
    @{ From = 'ppfilters\*.ini';               To = Join-Path $AcRoot 'system\cfg\ppfilters' },
    @{ From = 'ppfilters\Pure scripts\*.lua';  To = Join-Path $AcRoot 'system\cfg\ppfilters\Pure scripts' },
    @{ From = 'pure-config\*.ini';             To = Join-Path $AcRoot 'extension\config-ext\Pure' },
    @{ From = 'csp-presets\*.ini';             To = Join-Path $cmPresets 'Custom Shaders Patch' },
    @{ From = 'cm-video-presets\*.cmpreset';   To = Join-Path $cmPresets 'Video Settings' }
)

Write-Host "Assetto Corsa : $AcRoot"
Write-Host "CM presets    : $cmPresets"
Write-Host ''

$copied = 0
foreach ($job in $jobs) {
    $source = Join-Path $packRoot $job.From
    $files = Get-ChildItem -Path $source -File -ErrorAction SilentlyContinue
    if (-not $files) { continue }

    if (-not (Test-Path $job.To)) {
        if ($PSCmdlet.ShouldProcess($job.To, 'Create folder')) {
            New-Item -ItemType Directory -Path $job.To -Force | Out-Null
        }
    }

    foreach ($file in $files) {
        $target = Join-Path $job.To $file.Name
        if ($PSCmdlet.ShouldProcess($target, "Copy $($file.Name)")) {
            Copy-Item -Path $file.FullName -Destination $target -Force
            $copied++
        }
        Write-Host ("  {0,-34} -> {1}" -f $file.Name, $job.To)
    }
}

Write-Host ''
Write-Host "Done. $copied file(s) copied."
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Content Manager > Settings > Custom Shaders Patch > WeatherFX: keep Pure selected (Pure LCS or Pure Gamma).'
Write-Host '  2. Content Manager > Settings > Video > presets (top right): load "JamPure Ultra" or "JamPure Balanced".'
Write-Host '  3. Content Manager > Settings > Custom Shaders Patch > presets (top right): load "JamPure_CSP_Ultra" or "JamPure_CSP_Balanced".'
Write-Host '  4. In game: Pure Config app > Main tab > Load > JamPure_pure_config.ini.'
