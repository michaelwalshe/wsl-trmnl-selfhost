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

Re-copies manage_extension.rb and the built template into the container on
every run rather than assuming they're still there from a previous setup
step -- cheap, and avoids depending on container filesystem state
surviving between runs. Runs everything as a single script inside WSL
(rather than passing Windows paths to individual `wsl.exe -- docker ...`
calls) since a Windows-style UNC path passed as an argument to a command
that runs natively inside WSL doesn't get translated -- it's simply
malformed there.

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
    # Single-quoted here-string: nothing here is interpolated by
    # PowerShell, so $(...), $state, $i etc. below are all plain bash,
    # untouched until the .Replace() calls fill in the __TOKEN__ placeholders.
    $bashScript = @'
set -e
for i in 1 2 3 4 5 6; do
  state=$(docker inspect -f '{{.State.Running}}' __CONTAINER__ 2>/dev/null || echo false)
  if [ "$state" = "true" ]; then break; fi
  sleep 5
done
docker cp __REPO__/terminus/api/manage_extension.rb __CONTAINER__:/tmp/manage_extension.rb
docker cp __REPO__/liquid/full.terminus.liquid __CONTAINER__:/tmp/full.terminus.liquid
docker exec \
  -e EXTENSION_NAME=__EXT_NAME__ \
  -e "EXTENSION_LABEL=__EXT_LABEL__" \
  -e TEMPLATE_FILE=/tmp/full.terminus.liquid \
  -e EXCHANGE_URL=__EXCHANGE_URL__ \
  -e INTERVAL=15 -e UNIT=minute -e BUILD_MODEL_ID=__MODEL_ID__ \
  __CONTAINER__ bash -c 'cd /app && bundle exec ruby /tmp/manage_extension.rb'
'@

    $bashScript = $bashScript.Replace("__CONTAINER__", $ContainerName).
        Replace("__REPO__", $WslRepoPath).
        Replace("__EXT_NAME__", $ExtensionName).
        Replace("__EXT_LABEL__", $ExtensionLabel).
        Replace("__EXCHANGE_URL__", $ExchangeUrl).
        Replace("__MODEL_ID__", $ModelId)

    & wsl.exe -d Ubuntu -- bash -c $bashScript *>> $logFile

    "$(Get-Date -Format o) done, exit code $LASTEXITCODE" | Out-File -FilePath $logFile -Append
}
catch {
    "$(Get-Date -Format o) ERROR: $_" | Out-File -FilePath $logFile -Append
    exit 1
}
