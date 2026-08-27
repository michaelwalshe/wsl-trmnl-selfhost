<#
.SYNOPSIS
Copies a koreader plugin folder from this project onto a USB-connected Kindle.

.DESCRIPTION
Auto-detects the Kindle's drive letter by looking for a "koreader\plugins"
folder on any mounted drive (Windows can reassign the letter between USB
connections, so this avoids hardcoding one). Mirrors the plugin folder with
robocopy /MIR, so removed files get cleaned up too, not just new ones added.

.PARAMETER PluginName
Which plugin folder (under this script's own directory) to deploy.
Defaults to wol.koplugin.

.PARAMETER KindleDrive
Override auto-detection, e.g. -KindleDrive F:. Only needed if auto-detect
finds none or more than one candidate drive.

.EXAMPLE
.\deploy-to-kindle.ps1
Deploys wol.koplugin to the auto-detected Kindle drive.

.EXAMPLE
.\deploy-to-kindle.ps1 -PluginName trmnl.koplugin -KindleDrive F:
#>
param(
    [string]$PluginName = "wol.koplugin",
    [string]$KindleDrive = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $KindleDrive) {
    $candidates = Get-PSDrive -PSProvider FileSystem | Where-Object {
        Test-Path (Join-Path $_.Root "koreader\plugins") -ErrorAction SilentlyContinue
    }
    if (@($candidates).Count -eq 0) {
        Write-Error "No Kindle found. Connect it over USB (check it's unlocked/not in a jailbreak menu), or pass -KindleDrive (e.g. -KindleDrive F:)."
        exit 1
    }
    if (@($candidates).Count -gt 1) {
        $names = ($candidates | ForEach-Object { "$($_.Name):" }) -join ", "
        Write-Error "Multiple drives with a koreader folder found: $names. Pass -KindleDrive to disambiguate."
        exit 1
    }
    $KindleDrive = "$($candidates[0].Name):"
}

$source = Join-Path $scriptDir $PluginName
$dest = Join-Path "$KindleDrive\koreader\plugins" $PluginName

if (-not (Test-Path $source)) {
    Write-Error "Source not found: $source"
    exit 1
}

Write-Host "Deploying $PluginName"
Write-Host "  from: $source"
Write-Host "    to: $dest"
Write-Host ""

robocopy $source $dest /MIR /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed (exit code $LASTEXITCODE) -- is the Kindle still connected?"
    exit 1
}

Write-Host "Done:"
Get-ChildItem $dest -Recurse -File | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host "Now restart KOReader on the Kindle to load the update."
exit 0
