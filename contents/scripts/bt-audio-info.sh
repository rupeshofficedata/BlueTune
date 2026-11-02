#!/bin/bash
# Outputs a JSON array, one entry per Bluetooth audio card, keyed by MAC:
#   {mac, codec, sampleSpec, card, activeProfile, profiles:[{name, desc}]}
# codec/sampleSpec come from the card's active bluez sink (null if none);
# profiles lists the card's A2DP profiles so the widget can offer a codec
# switch (pactl set-card-profile <card> <name>). Used by the
# org.rupesh.bluetune Plasma widget — BlueZ has no codec info over D-Bus
# (it's a PipeWire/PulseAudio-side concept).

set -uo pipefail

jq -n -c \
    --slurpfile cards <(pactl --format=json list cards 2>/dev/null || echo '[]') \
    --slurpfile sinks <(pactl --format=json list sinks 2>/dev/null || echo '[]') '
  [ $cards[0][] | select(.name | startswith("bluez_card.")) | . as $c
    | ($c.properties["api.bluez5.address"] // ($c.name | ltrimstr("bluez_card.") | gsub("_"; ":"))) as $mac
    | ([ $sinks[0][] | select(.name | startswith("bluez_output." + ($c.name | ltrimstr("bluez_card.")))) ] | first // null) as $s
    | { mac: $mac,
        codec: ($s.properties["api.bluez5.codec"] // null),
        sampleSpec: ($s.sample_specification // null),
        card: $c.name,
        activeProfile: $c.active_profile,
        profiles: [ $c.profiles | to_entries[] | select(.key | startswith("a2dp")) | select(.value.available != false)
                    | {name: .key, desc: .value.description} ] } ]'
