<#
.SYNOPSIS
Opens the firewall for WSL2 mirrored-networking traffic on the given ports,
and makes sure the network adapter is categorised Private.

.DESCRIPTION
Must run elevated (Administrator). Mirrored networking makes WSL2 share the
host's real LAN IP -- which means inbound traffic to a container's port is
now genuine inbound network traffic subject to Windows' normal firewall
handling, not the loopback-like NAT forwarding used in default WSL2 mode.
Two separate layers both apply and both need a rule:

  1. The Hyper-V firewall (New-NetFirewallHyperVRule) -- specific to
     mirrored-mode WSL traffic, and only allows ICMP/mDNS inbound by
     default.
  2. The regular Windows Defender Firewall -- and its default inbound
     action depends on whether the adapter is categorised Private or
     Public. A cable/wifi adapter on a home network sometimes ends up
     marked Public, which blocks new inbound connections by default; this
     script switches it to Private rather than opening the port on Public,
     since Private is the more correct classification for a home LAN
     regardless of this project.

.PARAMETER InterfaceAlias
Which network adapter to reclassify as Private. Defaults to "Ethernet";
pass your own if you're on WiFi or a differently-named adapter (check with
Get-NetAdapter).

.PARAMETER Ports
TCP ports to open. Defaults to 2300 (Terminus) and 8090 (the data service)
-- both need to be reachable, since Terminus (inside WSL) calls the data
service (also inside WSL) via the host's LAN IP under mirrored networking,
not true loopback, so this self-to-self traffic is also subject to the
same firewall layers.

.EXAMPLE
.\setup-network.ps1
.EXAMPLE
.\setup-network.ps1 -InterfaceAlias "Wi-Fi" -Ports 2300,8090,9000
#>
param(
    [string]$InterfaceAlias = "Ethernet",
    [int[]]$Ports = @(2300, 8090)
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Run this from an elevated (Administrator) PowerShell window."
    exit 1
}

foreach ($port in $Ports) {
    $name = "WSL mirrored networking ($port)"
    if (Get-NetFirewallHyperVRule -DisplayName $name -ErrorAction SilentlyContinue) {
        Write-Host "Hyper-V firewall rule for port $port already exists, skipping."
    } else {
        New-NetFirewallHyperVRule -Name "WSL-$port" -DisplayName $name `
            -Direction Inbound -Protocol TCP -LocalPorts $port -Action Allow -Enabled True | Out-Null
        Write-Host "Added Hyper-V firewall rule for port $port."
    }

    $stdName = "WSL mirrored networking, standard firewall ($port)"
    if (Get-NetFirewallRule -DisplayName $stdName -ErrorAction SilentlyContinue) {
        Write-Host "Standard firewall rule for port $port already exists, skipping."
    } else {
        New-NetFirewallRule -DisplayName $stdName -Direction Inbound -Protocol TCP `
            -LocalPort $port -Action Allow -Profile Private,Domain | Out-Null
        Write-Host "Added standard firewall rule for port $port (Private/Domain profiles only)."
    }
}

$category = (Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias).NetworkCategory
if ($category -eq "Private") {
    Write-Host "$InterfaceAlias is already Private."
} else {
    Write-Host "$InterfaceAlias is currently $category -- setting to Private..."
    Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private
    Write-Host "Done."
}

Write-Host ""
Write-Host "Verify from another device on your LAN (not this machine -- self-to-self"
Write-Host "traffic can behave differently): http://<this-machine-LAN-IP>:2300"
