#!/bin/bash
# Outputs a JSON array, one entry per Bluetooth audio card, keyed by MAC:
#   {mac, codec, sampleSpec, card, activeProfile, profiles:[{name, desc}]}
# codec/sampleSpec come from the card's active bluez sink (null if none);
# profiles lists the card's A2DP profiles so the widget can offer a codec
# switch (pactl set-card-profile <card> <name>). Used by the
# org.rupesh.bluetune Plasma widget — BlueZ has no codec info over D-Bus
# (it's a PipeWire/PulseAudio-side concept).

set -uo pipefail

# Raw A2DP codec config bytes per MAC, straight from BlueZ's MediaTransport1
# (PipeWire only exposes its own graph format, e.g. 48 kHz, not the rate
# actually negotiated with the earbuds). Decoded in jq below.
transports='{}'
while IFS= read -r path; do
    [ -z "$path" ] && continue
    mac=$(sed -E 's#.*/dev_([0-9A-F_]+)/.*fd[0-9]+$#\1#; s/_/:/g' <<< "$path")
    cfg=$(busctl --system --json=short get-property org.bluez "$path" org.bluez.MediaTransport1 Configuration 2>/dev/null | jq -c '.data') || continue
    [ -n "$cfg" ] && transports=$(jq -c --arg m "$mac" --argjson c "$cfg" '.[$m]=$c' <<< "$transports")
done < <(busctl --system tree org.bluez --list 2>/dev/null | grep -E '/dev_[0-9A-F_]+/.*fd[0-9]+$')

jq -n -c --argjson tr "$transports" \
    --slurpfile cards <(pactl --format=json list cards 2>/dev/null || echo '[]') \
    --slurpfile sinks <(pactl --format=json list sinks 2>/dev/null || echo '[]') '
  [ $cards[0][] | select(.name | startswith("bluez_card.")) | . as $c
    | ($c.properties["api.bluez5.address"] // ($c.name | ltrimstr("bluez_card.") | gsub("_"; ":"))) as $mac
    | ([ $sinks[0][] | select(.name | startswith("bluez_output." + ($c.name | ltrimstr("bluez_card.")))) ] | first // null) as $s
    | { mac: $mac,
        codec: ($s.properties["api.bluez5.codec"] // null),
        sampleSpec: ($s.sample_specification // null),
        # LHDC v5 config = vendor(4) codec(2) freq bitrate_and_depth frame/ver features reserved
        link: (($tr[$mac] // null) as $b
               | if ($s.properties["api.bluez5.codec"] == "lhdc_v5") and ($b | length) == 11 then
                   { rate: ({"32":44100,"16":48000,"4":96000,"1":192000}[($b[6] | tostring)] // null),
                     bits: ({"2":24,"4":16}[(($b[7] % 8) | tostring)] // null),
                     maxKbps: ({"0":1000,"1":400,"2":500,"3":900}[((($b[7] / 16 | floor) % 4) | tostring)]) }
                 else null end),
        card: $c.name,
        activeProfile: $c.active_profile,
        profiles: [ $c.profiles | to_entries[] | select(.key | startswith("a2dp")) | select(.value.available != false)
                    | {name: .key, desc: .value.description} ] } ]'
