# BT Audio Widget — Project Setup + Phased Feature Roadmap

## Context

We already built a working prototype KDE Plasma 6 tray widget at
`~/.local/share/plasma/plasmoids/org.rupesh.btaudioinfo/` that shows the
connected Bluetooth audio device's name, battery %, codec, and sample
format (currently confirmed working with the OnePlus Buds 4 on LHDC v5).
It was built quickly in-place to prove the concept; it currently has no
version control and lives only in the KDE data directory, mixed in with
other installed plasmoids.

The user wants this formalized into a proper project (own folder, git,
GitHub remote) and wants the next phase — adding control features
(connect/disconnect, pairing, power/discoverable toggle, forget device) —
approached with real planning rather than more ad hoc edits, since the
long-term goal (stated earlier) is to reach BlueDevil-equivalent
functionality "one feature at a time."

Research (via Explore agent, reading live QML plugin sources and
`busctl introspect` against this machine's BlueZ 5.87) found:

- `org.kde.bluezqt` is a **public, stable KF6 QML module** already
  installed (`/usr/lib/qt6/qml/org/kde/bluezqt/`) that exposes
  `BluezQt.Manager` (adapters/devices), `BluezQt.Adapter`
  (`powered`, `discoverable`, `startDiscovery()`, `removeDevice()`), and
  `BluezQt.Device` (`connected`, `paired`, `trusted`, `battery.percentage`,
  `connectToDevice()`, `disconnectFromDevice()`, `pair()`). This is the
  same framework BlueDevil itself is built on. It should replace our
  current `bluetoothctl`-text-scraping for device state — reactive
  properties instead of a 5s poll, and far less fragile.
- BlueZ has **no codec information over D-Bus** — A2DP codec is a
  PipeWire/PulseAudio-side concept. `pactl list sinks` stays necessary
  for the codec/sample-format part no matter what.
- The Bluetooth **pairing agent** (PIN/passkey prompts) is C++-only, not
  exposed to QML at all, and BlueDevil's `bluedevil.so` kded daemon is
  already registered as the system's default pairing agent. Registering
  our own agent would steal that and break BlueDevil's own pairing flow.
  Rather than reimplement an agent, "add new device" should just launch
  BlueDevil's own existing wizard binary (`/usr/bin/bluedevil-wizard`,
  confirmed present) — zero conflict, zero reimplementation.
- No polkit gate on `org.bluez` for this user (checked `bluetooth.conf`),
  so `Powered`/`Discoverable`/connect/disconnect/trust/forget all work as
  a normal user with no privilege escalation needed.

## Part 1 — Project Setup (do now)

1. Create `~/Projects/bt-audio-widget/`.
2. Move the existing plasmoid files into it as the source of truth:
   - `metadata.json`
   - `contents/ui/main.qml`
   - `contents/scripts/bt-audio-info.sh`
3. Replace `~/.local/share/plasma/plasmoids/org.rupesh.btaudioinfo` with a
   **symlink** to `~/Projects/bt-audio-widget` — this is the standard KDE
   plasmoid dev workflow: edits in the project folder are live in Plasma
   immediately, no install/copy step needed.
4. Add a short `README.md` (what it is, how to add it to the panel, repo
   layout) and a minimal `.gitignore` (editor swap/backup files).
5. `git init`, initial commit.
6. Create the GitHub repo `bt-audio-widget` (public) via `gh repo create`
   and push. **Blocker:** `gh auth status` currently shows not logged in
   — before this step the user needs to run `gh auth login` interactively
   (suggest via `!gh auth login` in the terminal) since it requires a
   browser/device-code flow I can't drive. I'll do the `gh repo create`
   + push once that's done; if the user wants to skip GitHub for this
   session, I'll leave the local repo committed and do the remote step
   later.

## Part 2 — Feature Roadmap (design now, build incrementally later)

Each phase below is a separate future work session/commit, verified in
the live panel before moving to the next. Not building all of this now —
this section is the agreed roadmap so future work has a clear plan to
follow.

**Phase 2 — Migrate device state to BluezQt (no new user-facing features)**
Replace the `bluetoothctl devices/info` parsing in
`bt-audio-info.sh`/QML with `import org.kde.bluezqt as BluezQt` and bind
directly to `BluezQt.Manager.connectedDevices` for name/battery/paired/
connected state. Keep the existing shell-script approach *only* for the
codec + sample-format lookup (`pactl list sinks`), since that has no
D-Bus equivalent. Net effect: instant/reactive updates instead of 5s
polling, more robust parsing. No visible feature change yet — this is
the foundation the rest of the roadmap builds on.

**Phase 3 — Connect / Disconnect**
Add a button per device in the dropdown calling
`device.connectToDevice()` / `device.disconnectFromDevice()`
(`BluezQt.PendingCall`, async — show a connecting/disconnecting spinner
state, mirroring the pattern BlueDevil's own
`DevicesStateProxyModel` uses for transient UI state).

**Phase 4 — Trust / Forget / Adapter toggles**
- Trust toggle: `device.trusted = true/false`.
- Forget device: `device.adapter.removeDevice(device)` (note: it's an
  *Adapter* method, not a Device method).
- Adapter power toggle: `BluezQt.Manager.usableAdapter.powered`.
- Discoverable toggle: `adapter.discoverable` (+ `discoverableTimeout`).

**Phase 5 — Add New Device**
A button that launches `bluedevil-wizard` (existing BlueDevil pairing
UI) rather than reimplementing PIN/passkey agent handling ourselves —
avoids the default-agent conflict entirely.

## Verification

- After Part 1: confirm the symlinked plasmoid still loads and functions
  identically in the live panel (same info display, same 5s refresh) —
  proves the move/symlink didn't break anything before we touch any code.
- After Part 1: confirm `git log` shows the initial commit and (if `gh
  auth login` was completed) that the GitHub repo exists and has the
  pushed commit.
- Each roadmap phase (2-5), when actually implemented in a future
  session: reload the widget in the panel and manually exercise the new
  control (connect/disconnect a real device, toggle power/discoverable
  and confirm via `bluetoothctl show`, forget a device and confirm it
  disappears from `bluetoothctl devices`) before moving to the next phase.
