# BT Audio Widget

A KDE Plasma 6 tray widget showing the connected Bluetooth audio
device's name, battery %, codec, and sample format — information KDE's
own BlueDevil applet doesn't display.

## Install / dev setup

Symlink this folder into Plasma's plasmoid directory so edits apply live:

```bash
ln -s "$(pwd)" ~/.local/share/plasma/plasmoids/org.rupesh.btaudioinfo
```

Then in Plasma: right-click panel → *Add Widgets…* → search "BT Audio
Info" → drag onto the panel or into the system tray.

## Layout

- `metadata.json` — plasmoid manifest (KPackage)
- `contents/ui/main.qml` — widget UI (compact tray icon + dropdown)
- `contents/scripts/bt-audio-info.sh` — polls `bluetoothctl` + `pactl`
  for connected device / battery / codec, outputs JSON

## Status

Info-only (read state, no controls yet). See `PLAN.md` for the feature
roadmap — connect/disconnect, pairing, power/discoverable toggles,
forget device — being added incrementally on top of `org.kde.bluezqt`.
