<#
.SYNOPSIS
Builds full.terminus.liquid: the trmnl-calendar-weather dashboard, adapted
to run as a Terminus Extension.

.DESCRIPTION
Deliberately does not vendor a copy of trmnl-calendar-weather's full.liquid
in this repo -- that project is its own public repo with its own history,
and a copied-in snapshot would just go stale. This script concatenates:

  _terminus_header.liquid + <upstream>/src/full.liquid + _terminus_footer.liquid

into full.terminus.liquid, which is what you paste into the extension's
Template field in Terminus. Re-run this whenever trmnl-calendar-weather's
full.liquid changes upstream.

.PARAMETER UpstreamPath
Path to a local clone of usetrmnl/... no -- of your trmnl-calendar-weather
checkout. Defaults to a sibling directory next to this repo.

.EXAMPLE
.\build.ps1
.EXAMPLE
.\build.ps1 -UpstreamPath C:\path\to\trmnl-calendar-weather
#>
param(
    [string]$UpstreamPath = ""
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $UpstreamPath) {
    $UpstreamPath = Join-Path (Split-Path -Parent $scriptDir) "..\trmnl-calendar-weather" | Resolve-Path -ErrorAction SilentlyContinue
    if (-not $UpstreamPath) {
        Write-Error "Could not find a sibling trmnl-calendar-weather checkout. Pass -UpstreamPath explicitly."
        exit 1
    }
}

$upstreamFile = Join-Path $UpstreamPath "src\full.liquid"
if (-not (Test-Path $upstreamFile)) {
    Write-Error "full.liquid not found at $upstreamFile -- is -UpstreamPath a checkout of trmnl-calendar-weather?"
    exit 1
}

$header = Get-Content (Join-Path $scriptDir "_terminus_header.liquid") -Raw
$body = Get-Content $upstreamFile -Raw
$footer = Get-Content (Join-Path $scriptDir "_terminus_footer.liquid") -Raw

$outPath = Join-Path $scriptDir "full.terminus.liquid"
Set-Content -Path $outPath -Value ($header + $body + $footer) -NoNewline

Write-Host "Built $outPath from:"
Write-Host "  header: _terminus_header.liquid"
Write-Host "  body:   $upstreamFile"
Write-Host "  footer: _terminus_footer.liquid"
Write-Host ""
Write-Host "Paste its contents into the extension's Template field in Terminus."
