<#
.SYNOPSIS
Checks and fixes the causes behind the 2026-10 "Terminus unreachable from
the LAN" incident, so it doesn't need rediscovering from scratch if it
recurs: the Network Location Awareness service stopped or not set to
Automatic startup, and missing Hyper-V/standard firewall rules for WSL's
mirrored networking.

.DESCRIPTION
Must run elevated. Meant to run unattended on a schedule (see
setup-network-healthcheck-task.ps1) as well as by hand -- idempotent, safe
to run anytime, logs what it actually changed (if anything) to
%TEMP%\wsl-trmnl-network-healthcheck.log. A run that finds nothing wrong
logs one line, not the full detail, so the log doesn't balloon from
routine scheduled runs.

Deliberately does NOT try to verify reachability itself by requesting
http://<this-machine's-own-LAN-IP> -- confirmed live during the incident
that this kind of self-to-self test is unreliable (loopback/hairpin-NAT
behaviour) even when everything is actually fine, and chasing that was a
real dead end. Checks the underlying preconditions directly instead.

.PARAMETER InterfaceAlias
Passed straight through to setup-network.ps1 -- see that script's own help.

.PARAMETER Ports
Passed straight through to setup-network.ps1 -- see that script's own help.
#>
param(
    [string]$InterfaceAlias = "Ethernet",
    [int[]]$Ports = @(2300, 8090)
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $env:TEMP "wsl-trmnl-network-healthcheck.log"
function Log($msg) { "$(Get-Date -Format o) $msg" | Out-File -FilePath $logFile -Append }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Log "ERROR: not running elevated, cannot check/fix NLA or firewall."
    Write-Error "Run this from an elevated (Administrator) PowerShell window."
    exit 1
}

try {
    $changed = @()

    # NLA: found stopped with its startup type flipped to Manual once
    # already (cause unknown -- possibly a Windows update or a corporate
    # policy push on this work-connected machine). Both conditions
    # silently break Windows Firewall's ability to apply our
    # Private-profile-scoped rules, even though the rules themselves look
    # fine.
    $nla = Get-Service -Name NlaSvc
    if ($nla.StartType -ne "Automatic") {
        Set-Service -Name NlaSvc -StartupType Automatic
        $changed += "NlaSvc StartType was $($nla.StartType) -> Automatic"
    }
    $nla = Get-Service -Name NlaSvc
    if ($nla.Status -ne "Running") {
        Start-Service -Name NlaSvc
        $changed += "NlaSvc was $($nla.Status) -> started"
    }

    # Firewall (both layers) + adapter category: reuse the same idempotent
    # logic from initial setup rather than duplicating it here. Deployed
    # alongside this script by setup-network-healthcheck-task.ps1.
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $setupNetwork = Join-Path $scriptDir "setup-network.ps1"
    $output = & $setupNetwork -InterfaceAlias $InterfaceAlias -Ports $Ports 2>&1 | Out-String
    if ($output -match "Added|setting to Private") {
        $changed += "setup-network.ps1 made changes:`n$output"
    }

    if ($changed.Count -gt 0) {
        Log "Fixed:`n$($changed -join "`n")"
    } else {
        Log "OK, nothing to fix."
    }
}
catch {
    Log "ERROR: $_"
    exit 1
}
