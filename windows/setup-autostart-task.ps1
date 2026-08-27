<#
.SYNOPSIS
Registers a Task Scheduler task that boots the WSL distro at both Windows
startup and logon, so systemd inside it (and trmnl-stack.service) can bring
the containers back up automatically.

.DESCRIPTION
Must run elevated. Uses the S4U logon type deliberately: it runs as your
user account without needing your password stored, and -- unlike a plain
"At log on" trigger -- also works when nobody actually logs into Windows,
which matters after a Wake-on-LAN wake where the machine comes back up
unattended.

Both triggers are registered on the same task (Logon and Startup) so it
fires however the machine comes back: a normal interactive boot, or an
unattended remote wake.

.PARAMETER DistroName
The WSL distro to boot. Defaults to "Ubuntu".

.EXAMPLE
.\setup-autostart-task.ps1
#>
param(
    [string]$DistroName = "Ubuntu"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Run this from an elevated (Administrator) PowerShell window."
    exit 1
}

$taskName = "WSL-Podman-Autostart"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $DistroName -- true"
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerBoot = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($triggerLogon, $triggerBoot) `
    -Settings $settings -Principal $principal -Force `
    -Description "Boots the $DistroName WSL distro at both Windows startup and logon (S4U, no login required) so systemd + Podman + the Terminus TRMNL server come up automatically." | Out-Null

Write-Host "Registered task '$taskName':"
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State
(Get-ScheduledTask -TaskName $taskName).Triggers | ForEach-Object { $_.CimClass.CimClassName }
