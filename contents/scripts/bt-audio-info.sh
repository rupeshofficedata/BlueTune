#!/bin/bash
# Outputs a JSON array of active Bluetooth audio sinks' codec + sample
# format, keyed by MAC address. Used by the org.rupesh.bluetune Plasma
# widget to enrich BluezQt's device state, since BlueZ has no codec info
# over D-Bus (it's a PipeWire/PulseAudio-side concept).

set -uo pipefail

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

sink_names=$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep '^bluez_output\.')
all_sinks=$(pactl list sinks 2>/dev/null)

entries=()
while IFS= read -r sink_name; do
    [ -z "$sink_name" ] && continue
    mac_us=$(echo "$sink_name" | sed -E 's/^bluez_output\.([0-9A-Fa-f_]+)\..*/\1/')
    mac=$(echo "$mac_us" | tr '_' ':')

    sink_info=$(echo "$all_sinks" | grep -A 20 "Name: ${sink_name}$")

    codec="null"
    samplespec="null"
    c=$(echo "$sink_info" | grep -oP 'api\.bluez5\.codec = "\K[^"]+' | head -1)
    ss=$(echo "$sink_info" | grep -m1 "Sample Specification:" | sed 's/.*Sample Specification:\s*//')
    [ -n "$c" ] && codec="\"$(json_escape "$c")\""
    [ -n "$ss" ] && samplespec="\"$(json_escape "$ss")\""

    entries+=("{\"mac\":\"$mac\",\"codec\":$codec,\"sampleSpec\":$samplespec}")
done <<< "$sink_names"

IFS=,
echo "[${entries[*]:-}]"
