#!/bin/bash
# Outputs JSON array of connected Bluetooth audio devices with battery + codec info.
# Used by the org.rupesh.btaudioinfo Plasma widget.

set -uo pipefail

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

devices=$(bluetoothctl devices Connected 2>/dev/null)

entries=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    mac=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | cut -d' ' -f3-)
    [ -z "$mac" ] && continue

    info=$(bluetoothctl info "$mac" 2>/dev/null)

    battery=$(echo "$info" | grep -oP 'Battery Percentage:.*\(\K\d+(?=\))')
    [ -z "$battery" ] && battery="null"

    icon=$(echo "$info" | grep -oP 'Icon:\s*\K.*')
    is_audio="false"
    echo "$info" | grep -qi "Audio Sink\|Handsfree\|Headset" && is_audio="true"

    codec="null"
    samplespec="null"
    mac_us=$(echo "$mac" | tr ':' '_')
    sink_info=$(pactl list sinks 2>/dev/null | grep -A 20 "bluez_output.${mac_us}\." )
    if [ -n "$sink_info" ]; then
        c=$(echo "$sink_info" | grep -oP 'api\.bluez5\.codec = "\K[^"]+' | head -1)
        ss=$(echo "$sink_info" | grep -m1 "Sample Specification:" | sed 's/.*Sample Specification:\s*//')
        [ -n "$c" ] && codec="\"$(json_escape "$c")\""
        [ -n "$ss" ] && samplespec="\"$(json_escape "$ss")\""
    fi

    name_esc=$(json_escape "$name")
    icon_esc=$(json_escape "${icon:-audio-headset-bluetooth}")

    entries+=("{\"name\":\"$name_esc\",\"mac\":\"$mac\",\"battery\":$battery,\"isAudio\":$is_audio,\"codec\":$codec,\"sampleSpec\":$samplespec,\"icon\":\"$icon_esc\"}")
done <<< "$devices"

IFS=,
echo "[${entries[*]:-}]"
