#!/bin/bash
# Usage: set-bt-rate.sh <rate_hz> <bluez_card> <profile>
# Sets WirePlumber's BlueZ default rate (read only at startup, so it needs a
# WirePlumber restart), then reconnects the card's device and restores its
# A2DP profile so the new rate is negotiated. The setting is global: it applies
# to every Bluetooth audio device, not just this one.
set -u
rate="$1"; card="$2"; profile="$3"
case "$rate" in 44100|48000|96000) ;; *) echo "unsupported rate: $rate" >&2; exit 1 ;; esac
case "$card" in bluez_card.*) ;; *) echo "bad card: $card" >&2; exit 1 ;; esac
mac=$(sed -E 's/^bluez_card\.//; s/_/:/g' <<< "$card")

dir="$HOME/.config/wireplumber/wireplumber.conf.d"
mkdir -p "$dir"
rm -f "$dir/51-bt-lhdc-96k.conf"
cat > "$dir/51-bt-default-rate.conf" <<CONF
# Written by the BlueTune widget (set-bt-rate.sh).
monitor.bluez.properties = {
  bluez5.default.rate = $rate
}
CONF

systemctl --user restart wireplumber.service
sleep 5
bluetoothctl disconnect "$mac" >/dev/null 2>&1
sleep 3
bluetoothctl connect "$mac" >/dev/null 2>&1
sleep 6
pactl set-card-profile "$card" "$profile"
