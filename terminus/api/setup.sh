#!/bin/bash
# Automates Model + Device + Playlist creation/update via Terminus's real,
# documented REST API (doc/api.adoc in a Terminus checkout), and wires them
# together with your extension's already-built screen. Safe to re-run --
# every step finds-or-creates by matching name/MAC rather than blindly
# creating duplicates.
#
# What this does NOT cover: Extensions and Exchanges have no REST API at
# all in Terminus (checked directly against its routes: app/actions/api/
# has devices, models, playlists, screens, setup, display, log, firmware --
# no extensions). Create the Extension + Exchange once via the UI (see the
# main README), Build it for the model this script creates, then run this.
# manage_extension.rb in this directory automates that step too, but uses
# Terminus's internal Ruby classes rather than a stable public API -- see
# its own header comment before reaching for it.
set -euo pipefail

: "${TERMINUS_URL:?set TERMINUS_URL, e.g. http://192.168.0.192:2300}"
: "${TERMINUS_LOGIN:?set TERMINUS_LOGIN to your Terminus admin email}"
: "${TERMINUS_PASSWORD:?set TERMINUS_PASSWORD to your Terminus admin password}"
: "${DEVICE_MAC:?set DEVICE_MAC, e.g. AA:BB:CC:DD:EE:FF}"
MODEL_LABEL="${MODEL_LABEL:-Kindle 4}"
MODEL_NAME="${MODEL_NAME:-kindle_4}"
MODEL_WIDTH="${MODEL_WIDTH:-800}"
MODEL_HEIGHT="${MODEL_HEIGHT:-600}"
EXTENSION_NAME="${EXTENSION_NAME:-week_and_weather}"
PLAYLIST_NAME="${PLAYLIST_NAME:-$EXTENSION_NAME}"

command -v jq >/dev/null || { echo "jq is required (installed by wsl/bootstrap.sh)." >&2; exit 1; }

echo "Logging in to $TERMINUS_URL..."
TOKEN=$(curl -sS -X POST "$TERMINUS_URL/login" \
  -H "Content-Type: application/json" \
  -d "{\"login\":\"$TERMINUS_LOGIN\",\"password\":\"$TERMINUS_PASSWORD\"}" \
  | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
  echo "Login failed -- check TERMINUS_URL/TERMINUS_LOGIN/TERMINUS_PASSWORD." >&2
  exit 1
fi

auth() { curl -sS -H "Authorization: $TOKEN" -H "Content-Type: application/json" "$@"; }

echo "Model '$MODEL_NAME'..."
MODEL_ID=$(auth "$TERMINUS_URL/api/models" | jq -r --arg n "$MODEL_NAME" '.data[] | select(.name == $n) | .id' | head -1)
if [ -z "$MODEL_ID" ]; then
  MODEL_ID=$(auth -X POST "$TERMINUS_URL/api/models" -d "{
    \"model\": {
      \"name\": \"$MODEL_NAME\",
      \"label\": \"$MODEL_LABEL\",
      \"mime_type\": \"image/png\",
      \"colors\": 4,
      \"bit_depth\": 2,
      \"rotation\": 0,
      \"width\": $MODEL_WIDTH,
      \"height\": $MODEL_HEIGHT,
      \"css\": {\"classes\": {}, \"variables\": []}
    }
  }" | jq -r '.data.id')
  echo "  created, id $MODEL_ID"
else
  echo "  already exists, id $MODEL_ID"
fi

echo "Device $DEVICE_MAC..."
DEVICE_ID=$(auth "$TERMINUS_URL/api/devices" | jq -r --arg m "$DEVICE_MAC" '.data[] | select(.mac_address == $m) | .id' | head -1)
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID=$(auth -X POST "$TERMINUS_URL/api/devices" -d "{
    \"device\": {\"model_id\": $MODEL_ID, \"mac_address\": \"$DEVICE_MAC\"}
  }" | jq -r '.data.id')
  echo "  created, id $DEVICE_ID"
else
  auth -X PUT "$TERMINUS_URL/api/devices/$DEVICE_ID" -d "{\"device\": {\"model_id\": $MODEL_ID}}" > /dev/null
  echo "  already exists, id $DEVICE_ID (model set to $MODEL_ID)"
fi
DEVICE_API_KEY=$(auth "$TERMINUS_URL/api/devices/$DEVICE_ID" | jq -r '.data.api_key')

echo "Looking for extension screen 'extension-$EXTENSION_NAME' built for model $MODEL_ID..."
SCREEN_ID=$(auth "$TERMINUS_URL/api/screens" | jq -r --arg n "extension-$EXTENSION_NAME" --argjson m "$MODEL_ID" \
  '.data[] | select(.name == $n and .model_id == $m) | .id' | head -1)
if [ -z "$SCREEN_ID" ]; then
  echo "" >&2
  echo "No screen found. Create the Extension + Exchange via the UI (or manage_extension.rb)," >&2
  echo "Build it for model id $MODEL_ID, then re-run this script." >&2
  exit 1
fi
echo "  found, id $SCREEN_ID"

echo "Playlist '$PLAYLIST_NAME'..."
PLAYLIST_ID=$(auth "$TERMINUS_URL/api/playlists" | jq -r --arg n "$PLAYLIST_NAME" '.data[] | select(.name == $n) | .id' | head -1)
if [ -z "$PLAYLIST_ID" ]; then
  PLAYLIST_ID=$(auth -X POST "$TERMINUS_URL/api/playlists" -d "{
    \"playlist\": {\"name\": \"$PLAYLIST_NAME\", \"label\": \"$MODEL_LABEL\", \"items\": [{\"screen_id\": \"$SCREEN_ID\"}]}
  }" | jq -r '.data.id')
  echo "  created, id $PLAYLIST_ID"
else
  echo "  already exists, id $PLAYLIST_ID (not re-adding the screen -- edit it via the UI if needed)"
fi

auth -X PUT "$TERMINUS_URL/api/devices/$DEVICE_ID" -d "{\"device\": {\"playlist_id\": $PLAYLIST_ID}}" > /dev/null
echo ""
echo "Done. Device id $DEVICE_ID, API key: $DEVICE_API_KEY"
echo "Put that key in the trmnl.koplugin config on the Kindle."
