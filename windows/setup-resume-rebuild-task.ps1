<#
.SYNOPSIS
Registers a Task Scheduler task that forces an immediate Terminus screen
rebuild whenever Windows resumes from sleep, so a device polling shortly
after a Wake-on-LAN wake doesn't get whatever screen was already stale
when the desktop went to sleep.

.DESCRIPTION
Must run elevated. Triggers on the standard Windows "system resumed from
sleep" event (Power-Troubleshooter, Event ID 1 in the System log) -- fires
regardless of what caused the wake (Wake-on-LAN, a scheduled wake, manual
power button), so it isn't tied to wol.koplugin's own timing at all.

See trigger-rebuild-on-resume.ps1's own header comment for *why* this is
needed -- short version, Terminus's scheduler discards missed poll ticks
rather than catching up on them when the process was paused, so simply
shortening the poll interval (README step 6) doesn't guarantee freshness
right after a wake.

Deploys a local copy of trigger-rebuild-on-resume.ps1 under
%LOCALAPPDATA% and points the task at that, rather than at the repo's own
\\wsl.localhost\... path directly -- confirmed live that a task run under
S4U logon (non-interactive, no desktop session) can't reliably load a
script from a \\wsl.localhost\... UNC path: the task completed instantly
with no error, but none of the target script's own code ever ran (not
even its first line), across two different script versions, while
running the exact same file directly in an interactive session worked
both times. A local path sidesteps needing the WSL 9P redirector to be
available in that session at all. Re-run this script after editing
trigger-rebuild-on-resume.ps1 to redeploy the local copy.

.PARAMETER RepoPath
UNC path to the wsl-trmnl-selfhost repo. Defaults to this machine's own
WSL-native path.

.EXAMPLE
.\setup-resume-rebuild-task.ps1
#>
param(
    [string]$RepoPath = "\\wsl.localhost\Ubuntu\home\michael\wsl-trmnl-selfhost"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Run this from an elevated (Administrator) PowerShell window."
    exit 1
}

$sourceScriptPath = Join-Path $RepoPath "windows\trigger-rebuild-on-resume.ps1"
if (-not (Test-Path $sourceScriptPath)) {
    Write-Error "Could not find $sourceScriptPath -- pass -RepoPath if this repo isn't at the default location."
    exit 1
}

$localDir = Join-Path $env:LOCALAPPDATA "wsl-trmnl-selfhost"
New-Item -ItemType Directory -Path $localDir -Force | Out-Null
$scriptPath = Join-Path $localDir "trigger-rebuild-on-resume.ps1"
Copy-Item -Path $sourceScriptPath -Destination $scriptPath -Force
Write-Host "Deployed $sourceScriptPath -> $scriptPath"

$taskName = "WSL-Podman-ResumeRebuild"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

# New-ScheduledTaskTrigger has no built-in "on resume from sleep" trigger
# type -- this builds the same custom event-log trigger Task Scheduler's
# own GUI produces for "On an event" -> System log ->
# Microsoft-Windows-Power-Troubleshooter -> Event ID 1.
$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
"@
$trigger.Enabled = $true

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force `
    -Description "Forces an immediate Terminus screen rebuild on resume from sleep, so a device polling right after a Wake-on-LAN wake doesn't get a stale pre-sleep screen." | Out-Null

Write-Host "Registered task '$taskName':"
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State
Write-Host ""
Write-Host "Test it without a real sleep/wake cycle:"
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Then check $env:TEMP\trmnl-resume-rebuild.log for the result."
