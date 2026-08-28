#!/bin/bash
# Forces an immediate Terminus screen rebuild. Invoked by
# windows/trigger-rebuild-on-resume.ps1 -- see that file's header comment
# for why this exists. Kept as a real script file, invoked with plain
# positional args, rather than a bash command string built up in
# PowerShell: a value containing spaces (EXTENSION_LABEL="Week and
# Weather") does not reliably survive being marshaled as a single -c
# string across the PowerShell -> wsl.exe -> bash boundary -- confirmed
# the hard way (it silently split into separate words, and the whole
# script errored out immediately with $CONTAINER before docker cp/exec
# ever ran). Plain argv entries don't have this problem.
set -e

container="$1"
repo="$2"
ext_name="$3"
ext_label="$4"
exchange_url="$5"
model_id="$6"

for _ in 1 2 3 4 5 6; do
    state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)
    if [ "$state" = "true" ]; then break; fi
    sleep 5
done

docker cp "$repo/terminus/api/manage_extension.rb" "$container:/tmp/manage_extension.rb"
docker cp "$repo/liquid/full.terminus.liquid" "$container:/tmp/full.terminus.liquid"
docker exec \
    -e EXTENSION_NAME="$ext_name" \
    -e EXTENSION_LABEL="$ext_label" \
    -e TEMPLATE_FILE=/tmp/full.terminus.liquid \
    -e EXCHANGE_URL="$exchange_url" \
    -e INTERVAL=15 -e UNIT=minute -e BUILD_MODEL_ID="$model_id" \
    "$container" bash -c 'cd /app && bundle exec ruby /tmp/manage_extension.rb'
