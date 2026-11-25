<#
.SYNOPSIS
Registers a Task Scheduler task that runs network-healthcheck.ps1
automatically -- on logon, on startup, on resume from sleep, and every 6
hours as a backstop -- so the LAN-reachability regressions found in the
2026-10 incident (NLA service stopped / not Automatic, missing firewall
rules) get caught and fixed without needing to be rediscovered from
scratch, even if whatever caused it once (a Windows update, or a
corporate policy push on this work-connected machine) does it again.

.DESCRIPTION
Must run elevated. Unlike the resume-rebuild task, this one genuinely
needs administrator rights to do its job (NLA/firewall changes), so it
uses RunLevel Highest rather than Limited -- Task Scheduler can grant
this non-interactively (no stored password, no UAC prompt) for a local
administrator account, which is what S4U + Highest together achieve.

Deploys a local copy of both network-healthcheck.ps1 and its
setup-network.ps1 dependency to %LOCALAPPDATA%\wsl-trmnl-selfhost\, same
reasoning as setup-resume-rebuild-task.ps1: confirmed directly in that
earlier incident that powershell.exe -File against a \\wsl.localhost\...
UNC path silently doesn't run at all under Task Scheduler's non-interactive
session -- no error, it just never executes. Re-run this script after
editing either source file to redeploy the local copies.

.PARAMETER RepoPath
UNC path to the wsl-trmnl-selfhost repo. Defaults to this machine's own
WSL-native path.

.EXAMPLE
.\setup-network-healthcheck-task.ps1
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

$localDir = Join-Path $env:LOCALAPPDATA "wsl-trmnl-selfhost"
New-Item -ItemType Directory -Path $localDir -Force | Out-Null

foreach ($file in @("network-healthcheck.ps1", "setup-network.ps1")) {
    $source = Join-Path $RepoPath "windows\$file"
    if (-not (Test-Path $source)) {
        Write-Error "Could not find $source -- pass -RepoPath if this repo isn't at the default location."
        exit 1
    }
    Copy-Item -Path $source -Destination (Join-Path $localDir $file) -Force
}
Write-Host "Deployed network-healthcheck.ps1 + setup-network.ps1 -> $localDir"

$scriptPath = Join-Path $localDir "network-healthcheck.ps1"
$taskName = "WSL-Podman-NetworkHealthcheck"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerBoot = New-ScheduledTaskTrigger -AtStartup
# [TimeSpan]::MaxValue produces a duration string Task Scheduler's XML
# schema rejects outright (confirmed live: "P99999999DT23H59M59S" ->
# "incorrectly formatted or out of range"); 10 years is the standard
# stand-in for "repeat indefinitely".
$triggerDaily = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)

# Same custom event trigger as the resume-rebuild task -- New-ScheduledTaskTrigger
# has no built-in "on resume from sleep" type.
$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$triggerResume = New-CimInstance -CimClass $triggerClass -ClientOnly
$triggerResume.Subscription = @"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
"@
$triggerResume.Enabled = $true

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger @($triggerLogon, $triggerBoot, $triggerDaily, $triggerResume) `
    -Settings $settings -Principal $principal -Force `
    -Description "Checks and fixes NLA service state + firewall rules for WSL mirrored networking -- runs on logon, startup, resume from sleep, and every 6 hours." | Out-Null

Write-Host "Registered task '$taskName':"
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State
Write-Host ""
Write-Host "Test it now:"
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Then check `$env:TEMP\wsl-trmnl-network-healthcheck.log for what it did."
