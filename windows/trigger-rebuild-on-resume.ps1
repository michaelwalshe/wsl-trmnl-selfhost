<#
.SYNOPSIS
Forces an immediate Terminus screen rebuild -- meant to run automatically
on resume from sleep (see setup-resume-rebuild-task.ps1), not run by hand.

.DESCRIPTION
Why this exists: Terminus's scheduler (sidekiq-scheduler, backed by
rufus-scheduler) discards missed occurrences by default rather than
catching up on them (rufus-scheduler defaults to discard_past = true --
confirmed directly in its own source, lib/rufus/scheduler.rb). So a poll
tick missed while the desktop was asleep is simply skipped: the next
rebuild still waits for the next aligned interval boundary (e.g. the next
:00/:15/:30/:45 past the hour for a 15-minute schedule), which can be
almost a full interval away regardless of how long the desktop was
actually asleep. A device woken via Wake-on-LAN (see
koreader/wol.koplugin) typically polls within seconds of the desktop
waking, so without this, the served image can be stale by however long
the desktop was asleep -- not bounded to the poll interval the way it is
during normal always-on operation.

The actual rebuild logic lives in the sibling resume-rebuild.sh, run as a
real script file with plain positional arguments -- passing the same
logic as a bash command *string* built up in PowerShell was tried first
and is NOT reliable: a value containing spaces
(EXTENSION_LABEL="Week and Weather") does not survive being marshaled as
a single -c argument across the PowerShell -> wsl.exe -> bash boundary,
confirmed live (it silently split into separate shell words and the
script errored out before doing anything). This also re-copies
manage_extension.rb and the built template into the container on every
run rather than assuming they're still there from a previous setup step.

.PARAMETER WslRepoPath
Path to the repo as WSL itself sees it. Defaults to the WSL-native
location this project assumes throughout (~/wsl-trmnl-selfhost).

.PARAMETER ExtensionName / ExtensionLabel / ExchangeUrl / ModelId
Must match what was used when the extension was first created (README
step 6). ModelId is the Terminus Model id to rebuild for (find it via
`terminus/api/setup.sh`'s output, or the Models page in the Terminus UI).
#>
param(
    [string]$WslRepoPath = "~/wsl-trmnl-selfhost",
    [string]$ExtensionName = "week_and_weather",
    [string]$ExtensionLabel = "Week and Weather",
    [string]$ExchangeUrl = "http://192.168.0.192:8090/data",
    [string]$ModelId = "55",
    [string]$ContainerName = "terminus-web-1"
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $env:TEMP "trmnl-resume-rebuild.log"
"$(Get-Date -Format o) starting" | Out-File -FilePath $logFile -Append

try {
    # Linux-native path, same reasoning as WslRepoPath itself: this runs
    # inside WSL via wsl.exe, so it needs a path WSL can resolve -- not the
    # Windows-side UNC path this script's own file lives at.
    $shScript = "$WslRepoPath/windows/resume-rebuild.sh"

    & wsl.exe -d Ubuntu -- bash $shScript $ContainerName $WslRepoPath $ExtensionName $ExtensionLabel $ExchangeUrl $ModelId *>> $logFile

    "$(Get-Date -Format o) done, exit code $LASTEXITCODE" | Out-File -FilePath $logFile -Append
}
catch {
    "$(Get-Date -Format o) ERROR: $_" | Out-File -FilePath $logFile -Append
    exit 1
}
