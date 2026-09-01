# BlueTune — Project Setup + Phased Feature Roadmap

## Context

We already built a working prototype KDE Plasma 6 tray widget (named
BlueTune, plasmoid id `org.rupesh.bluetune`; originally prototyped and
briefly named "BT Audio Info"/`org.rupesh.btaudioinfo`, renamed once the
widget grew past info-only) at
`~/.local/share/plasma/plasmoids/org.rupesh.bluetune/` that shows the
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

## Part 1 — Project Setup (done)

1. ~~Create `~/Projects/bt-audio-widget/`.~~
2. ~~Move the existing plasmoid files into it as the source of truth~~
   (`metadata.json`, `contents/ui/main.qml`,
   `contents/scripts/bt-audio-info.sh`).
3. ~~Symlink `~/.local/share/plasma/plasmoids/org.rupesh.bluetune` to
   the project folder~~ — standard KDE plasmoid dev workflow, edits are
   live in Plasma immediately. (Renamed from `org.rupesh.btaudioinfo`
   once the widget grew past info-only and was rebranded "BlueTune".)
4. ~~Add `README.md` + `.gitignore`.~~
5. ~~`git init`, initial commit.~~
6. GitHub remote — not yet done; still needs `gh auth login` run
   interactively by the user, then `gh repo create` + push whenever
   they want to do it.

## Part 2 — Feature Roadmap (design now, build incrementally, one stage per session)

Each stage below is a separate future work session/commit, verified in
the live panel before moving to the next.

**Stage A — UI modernization (done)**
Pure `contents/ui/main.qml` presentation refactor: replaced hardcoded
`opacity: 0.6/0.7` secondary-text hacks with reactive Kirigami theme
color roles (`Kirigami.Theme.disabledTextColor`,
`positiveTextColor`/`neutralTextColor`/`negativeTextColor` for
battery-level color coding), added a per-battery-level icon
(`battery-0XX-symbolic`, stepped in tens per Breeze's icon set) and a
connected-state checkmark per device card. No behavior or data-source
change — confirms the widget looks native and responds live to a
system light/dark/accent theme change before any BluezQt migration work
begins.

**Stage B — Migrate device state to BluezQt (done)**
Replaced the `bluetoothctl devices/info` parsing in `main.qml` with
`import org.kde.bluezqt as BluezQt`, binding directly to
`BluezQt.Manager.connectedDevices` for name/battery/icon — filtered to
audio devices via `device.icon.startsWith("audio")` (BlueZ's icon
taxonomy: `audio-card`/`audio-headset`/`audio-headphones`). Rewrote
`bt-audio-info.sh` to do *only* the codec + sample-format lookup via
`pactl list sinks` (no `bluetoothctl` calls left in it at all), keyed by
MAC address and merged into the BluezQt device list in QML
(`root.codecFor(address)`). Verified end-to-end live against a real
connected device (OnePlus Buds 4, 100% battery, `lhdc_v5`, `s24le 2ch
48000Hz`) via `plasmawindowed` — name/battery are now instant/reactive,
no 5s polling for that part; the poll timer remains solely to refresh
codec/format, which still has no D-Bus/property equivalent.

Confirmed API surface (read from
`/usr/lib/qt6/qml/org/kde/bluezqt/bluezqtextensionplugin.qmltypes`,
`bluez-qt 6.29.0`): `Manager.usableAdapter/adapters/devices/connectedDevices`;
`Adapter.powered/discoverable/discoverableTimeout/pairable/startDiscovery()/
stopDiscovery()/removeDevice(device)`; `Device.name/icon/paired(ro)/
trusted/connected(ro)/battery.percentage/adapter/connectToDevice()/
disconnectFromDevice()/pair()/cancelPairing()` — all mutating calls
return an async `BluezQt.PendingCall` (`isFinished`/`error`/`errorText`/
`finished` signal).

**Stage C — Connect / Disconnect (done)**
Added a Connect/Disconnect button per device card in `main.qml`
(`deviceCard.toggleConnection()`), calling `device.connectToDevice()` /
`device.disconnectFromDevice()` and connecting to the returned
`BluezQt.PendingCall`'s `finished` signal to clear a busy spinner
(`PlasmaComponents3.BusyIndicator`) and surface `errorText` on failure.
Note: since `audioDevices` is still built from
`Manager.connectedDevices` only (Stage B), every card currently shown is
already connected, so only the Disconnect branch is reachable today —
the button already reads the generic `device.connected` state so it
starts working for the Connect case for free once Stage E lists
paired-but-disconnected devices too.

Gotcha found during implementation: the `finished` callback closure
captures the delegate (`deviceCard`) by id, but a *successful* disconnect
removes the device from `connectedDevices`, which recomputes
`audioDevices` and destroys that delegate before the callback runs —
guard with `if (!deviceCard) return;` at the top of the callback or it
throws on the dangling reference.

Verified live: disconnected the real OnePlus Buds 4 via the equivalent
BlueZ operation and confirmed the widget's card disappeared instantly
with no poll delay (proving the `Manager.connectedDevices` binding is
truly reactive), then reconnected and confirmed the card reappeared with
correct battery/codec/format and the button read "Disconnect" again.

**Stage D — Trust / Forget / Adapter toggles (done)**
- Trust toggle: a `Trusted` checkbox per device card writing
  `device.trusted = checked`.
- Forget device: a `Forget` button per device card opening a
  `Kirigami.PromptDialog` (`forgetDialog`, modeled on BlueDevil's own
  `/usr/lib/qt6/qml/org/kde/bluedevil/components/ForgetDeviceDialog.qml`)
  that calls `device.adapter.removeDevice(device)` on confirm — note
  it's an *Adapter* method, not a Device method.
- Adapter power toggle: a `Bluetooth` switch in the header writing
  `BluezQt.Manager.usableAdapter.powered = checked`.
- Discoverable toggle: a `Discoverable` switch, same pattern, only
  visible while the adapter is powered (mirrors that Bluetooth can't be
  discoverable while off).

Gotcha found during implementation: binding a `Switch`/`CheckBox`'s
`checked` directly to a backend property (`checked: adapter.powered`)
breaks the binding permanently the first time the user toggles it —
`AbstractButton.toggle()` does an imperative write that severs a plain
QML binding, so external state changes (e.g. Bluetooth powered off from
outside the widget) would stop being reflected after one click. Fixed
with an explicit `Binding { target: ...; property: "checked"; value: ...;
restoreMode: Binding.RestoreBinding }` for all three toggles (power,
discoverable, trusted) — `RestoreBinding` re-asserts the binding once its
source properties change again, which is exactly this case.

Verified live: toggled Discoverable on/off and Bluetooth power off/on via
the equivalent BlueZ operations (only device on this adapter is the
audio one, so no other peripherals at risk) — both switches tracked the
real state correctly with no manual re-sync, the Discoverable row
correctly hid itself while powered off, and the device list/earbuds
recovered fully after powering back on and reconnecting. Trust and
Forget were verified by code review only (same proven `Binding` pattern;
untrusting/unpairing the real device wasn't worth the recovery hassle
for this check).

**Stage E — Show all paired devices + Add New Device (done)**
`audioDevices` now builds from `BluezQt.Manager.devices` (all paired/
known devices) instead of `Manager.connectedDevices`, so
paired-but-disconnected audio devices stay listed with a Connect button
rather than disappearing — needed for real BlueDevil parity, since
BlueDevil shows the full device list, not just connected. Connected
devices are sorted to the top. `hasAudioDevice`/tray status/tooltip use
a separate `connectedAudioDevices` (filtered) so the tray icon still only
reflects actually-connected devices. Added an "Add New Device" button
that launches the confirmed-present `/usr/bin/bluedevil-wizard` (existing
BlueDevil pairing UI) via a second `P5Support.DataSource` (`launcher`),
rather than reimplementing PIN/passkey agent handling ourselves — avoids
the default-agent conflict entirely (BlueDevil's `bluedevil.so` kded
daemon is already the system's default BlueZ pairing agent).

Verified live: disconnected the real OnePlus Buds 4 and confirmed the
card stayed visible with a "Connect" button (battery/codec/format rows
correctly hidden since not connected), reconnected via the equivalent
BlueZ operation and confirmed it flipped back to "Disconnect" with full
info restored. Also launched `bluedevil-wizard` directly to confirm it
starts cleanly (then closed it — didn't leave a stray wizard window
open).

This completes the original 5-stage roadmap — the widget now covers
info display, connect/disconnect, trust/forget, adapter power/discoverable,
and add-device, matching BlueDevil's core feature set while still
showing the audio detail (codec/sample format) BlueDevil never did.

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

## Post-roadmap: rebrand + general Bluetooth manager scope (done)

The 5-stage roadmap above only ever listed *audio* devices. Once it was
complete, the widget was rebranded and broadened:

- Renamed "BT Audio Info"/`org.rupesh.btaudioinfo` → **BlueTune**/
  `org.rupesh.bluetune` (metadata, dev symlink, docs all updated
  together — the old symlink was removed and a new one created, checked
  first that nothing referenced the old id in the live panel config so
  nothing was orphaned).
- Added `"X-Plasma-NotificationAreaCategory": "Hardware"` to
  `metadata.json` — this is the actual metadata key (confirmed by
  checking KDE Connect's own `metadata.json`) that makes a plasmoid a
  proper System Tray entry (appears in the tray's Entries list, can be
  toggled shown/hidden) rather than only addable by manually dragging it
  onto the panel.
- Icon changed from the audio-headset glyph to a generic Bluetooth glyph
  (`preferences-system-bluetooth`) in `metadata.json`, and
  `preferences-system-bluetooth-activated-symbolic` /
  `-inactive-symbolic` in the tray icon (now reflects adapter
  powered-on/off, not "audio device connected/not") — matches that the
  widget covers all Bluetooth devices now, not just audio.
- **Scope broadened to all paired Bluetooth devices**, not just audio
  ones: `root.devices` iterates `BluezQt.Manager.devices` with no type
  filter (previously filtered to `icon.indexOf("audio") === 0`).
  `connectedDevices`/`hasConnectedDevice` (renamed from
  `connectedAudioDevices`/`hasAudioDevice`) drive tray status generically.
- **Per-device-type icons**: `root.deviceIconMap` whitelists the fixed
  set of icon names BlueZ's `bluetoothd` actually emits (from its
  `device_get_icon()`: audio-card/headset/headphones,
  camera-photo/video, computer, input-gaming/keyboard/mouse/tablet,
  modem, network-wireless, phone, printer, scanner) against names
  verified present in Breeze/Breeze-Dark, substituting where one didn't
  exist (`modem` → `network-modem`), and falling back to the generic
  Bluetooth glyph for anything else/unset. **Limitation**: neither
  classic Bluetooth Class-of-Device nor the freedesktop icon-naming spec
  distinguish "earbuds" from "headset" — there's no separate icon asset
  for earbuds in Breeze, so true wireless earbuds intentionally show the
  same `audio-headset` glyph as a corded headset. A finer LE GATT
  Appearance-based distinction was considered and rejected: BlueZ's own
  icon algorithm already folds Appearance into the same fixed icon-name
  set above, so there's no additional resolution to gain, and no
  non-audio Bluetooth device was on hand to test any Appearance-based
  logic against — decided not to ship an unverifiable heuristic.
- Actual brand/vendor logos (e.g. a Sony logo) were explicitly ruled out:
  BlueZ exposes no vendor-logo data over D-Bus, no Linux icon theme
  ships trademarked brand logos, and fetching them from an external
  service would add a network dependency, leak device names off-device,
  and carry real trademark/redistribution risk — flagged to the user
  and declined in favor of the icon-mapping approach above.
- **Codec/sample-format rows now always render for audio devices**
  (`modelData.isAudio`, computed from `deviceIconMap`) instead of hiding
  when absent — they show "No codec info"/"No sample format info" in
  `disabledTextColor` when the device has no active PipeWire sink (e.g.
  paired but disconnected). Non-audio devices never show these rows at
  all, since the fields are meaningless for them.

Verified live: confirmed the new tray-icon window glyph is generic
Bluetooth (not a headset), and confirmed the "no codec info" fallback
renders correctly by disconnecting the real earbuds (codec/sampleSpec
go `null` but the device — and now the codec/format rows with fallback
text — stay visible, per the Stage E all-devices-list behavior), then
reconnected and confirmed full info returns. No second Bluetooth device
was available to test a non-audio icon category (mouse/keyboard/phone)
end-to-end — that path is covered by the `deviceIconMap` whitelist logic
and `qmllint`, not a live device.

## Post-roadmap: device card redesign (done)

Explored 4 layout options as an HTML mockup (Breeze-styled, using real +
mock devices) before touching `main.qml` — user picked "Compact pills"
and asked for two changes on top of it:

- Adapter power toggle moved to sit directly beside the "BlueTune"
  heading in the header row (was its own "Bluetooth" label + switch row
  below it, now removed).
- Per-device row: dropped the `⋮` overflow-menu idea entirely. Instead,
  a `go-down-symbolic`/`go-up-symbolic` chevron `PlasmaComponents3.ToolButton`
  toggles `deviceCard.expanded`, revealing a footer row with Forget
  (icon-only, left) and a Trusted checkbox (right) — nothing hidden
  behind a menu, just a tap-to-reveal row.
- Battery and codec/format now render as `Kirigami.Chip` pills
  (`closable: false; interactive: false` for a non-interactive display
  chip) instead of separate stacked rows — `iconMask: true` is required
  on the battery chip for `icon.color` (the severity color-coding) to
  actually apply, since `Kirigami.Chip`'s icon only tints when treated as
  a mask. Note Chip's label text color is hardcoded to
  `Platform.Theme.textColor` in its template — it can't be recolored
  per-instance, which is why the "no codec" empty state uses a plain
  dim `Label` instead of a chip (an empty-state pill would've looked odd
  anyway).

Verified live via `plasmawindowed`: header toggle renders beside the
title and reflects real adapter state; confirmed the expand/collapse
interaction by temporarily forcing `expanded: true` as a default (no
click-simulation tool available in this environment), screenshotting to
confirm Forget-left/Trusted-right, then reverting immediately. The real
earbuds happened to go to sleep mid-session (`br-connection-page-timeout`
on reconnect attempts) — confirmed this is real hardware state via
`bluetoothctl info`, not a regression; the disconnected-device view
(Connect button, "No codec info", battery chip hidden) still rendered
correctly regardless.

Also produced a **pairing-code reference template** (numeric-comparison
confirm dialog + fixed-PIN entry dialog) per request, added to the same
mockup as a clearly-marked "reference only, not wired up" section —
deliberately not implemented in `main.qml`. Answering a real BlueZ
pairing-agent prompt would mean registering our own agent, which would
conflict system-wide with BlueDevil's `bluedevil.so` (already the
default agent) for every pairing request, not just BlueTune's — the
existing decision to launch `bluedevil-wizard` for "Add New Device"
instead stands unless BlueTune is ever meant to fully replace BlueDevil
rather than sit alongside it.

## Post-roadmap: pixel-level fit-and-finish pass (done)

After comparing a live screenshot against the design mockup, several
concrete gaps were fixed in `main.qml`:

- **`Kirigami.Chip` dropped entirely** for the battery/codec pills —
  its label color is hardcoded to the theme's normal text color in the
  component template (confirmed by reading
  `kirigami/controls/Chip.qml`), so the battery percentage rendered
  plain white instead of green/amber/red no matter what `icon.color`
  was set to. Replaced with plain `Rectangle`-based pills (rounded via
  `radius: height / 2`, sized from an inner `RowLayout`'s
  `implicitWidth`/`implicitHeight`) so both the icon *and* the label
  text share one `pillColor` property — now the whole battery pill
  (icon, text, border) recolors by severity, matching the mockup.
- **Header**: removed `Layout.fillWidth` from the "BlueTune" heading and
  added a trailing spacer `Item` after the power switch instead — the
  switch now sits immediately after the title text rather than being
  pushed to the popup's far right edge.
- **Discoverable moved out of the header entirely**, down into the
  footer area alongside "Add New Device" (a `Kirigami.Separator` marks
  the boundary) — both adapter-level, occasional-use controls now live
  together at the bottom, away from the always-relevant device list.
- **Card background overridden** on `Kirigami.AbstractCard` (`Rectangle`
  with `radius: 7`, `Kirigami.Theme.alternateBackgroundColor` fill,
  1px `disabledTextColor` border) instead of leaving Kirigami's default
  `DefaultCardBackground` (which uses the platform's own
  `Kirigami.Units.cornerRadius` and a plainer contrast level) — gives a
  more pronounced rounded-card look matching the mockup, at the cost of
  no longer perfectly tracking a user's system-wide corner-radius/style
  setting the way an unmodified `AbstractCard` would.
- **Font and per-device icon choice were deliberately left alone**:
  the widget already inherits Plasma's configured system font (no
  `font.family` was ever set anywhere in `main.qml`) — hardcoding a
  specific typeface would override the user's own font choice, which
  goes against how a native desktop widget is supposed to behave; the
  mockup's Noto Sans just happens to be Breeze's own shipped default, so
  the two should already coincide. `audio-x-generic` was kept for the
  codec pill icon (already verified present, and the standard
  freedesktop mimetype icon for "generic audio," which is exactly what
  a codec/format label represents) rather than swapped for something
  like `note-symbolic`, which is KDE's sticky-note/memo icon, not a
  musical note — a swap there would've been a wrong icon in the name of
  finding *a* music-shaped icon.

Verified live via `plasmawindowed`: screenshots saved to
`/tmp/.../scratchpad/screenshots/bluetune-v3-{collapsed,expanded}.png`
and sent to the user (rather than deleted, per explicit request to keep
a record to annotate against) — confirm toggle position, pill severity
coloring, card corners, and the expanded Forget-left/Trusted-right
footer all match the target design. Screenshots now live in
`screenshots/` inside the project itself (gitignored) rather than
`~/Pictures` — the user's preference once they realized the project
directory was the more sensible home for them.

## Post-roadmap: capsules, sizing, panel icon + badge (done)

Further refinement pass, all in `main.qml`:

- **Codec split into two pills**: previously one pill combined codec +
  sample spec text; now a codec pill ("LHDC_V5") and a separate format
  pill via new `root.shortSampleSpec(spec)` (parses pactl's
  `"s24le 2ch 48000Hz"` down to `"24-bit/48kHz"` — bit depth is the
  first number in the string since the encoding token always comes
  first; sample rate is whatever precedes `Hz`, divided by 1000). Both
  pills use `Kirigami.Theme.highlightColor` (icon+text+border) to read
  as "this feature is active/enabled," distinct from the battery pill's
  severity-based coloring.
- **Widget size roughly doubled**: the old `Layout.minimumWidth:
  gridUnit*16` was never actually the binding constraint — natural
  content width already exceeded it, so doubling that number alone only
  grew the popup from ~630px to ~706px. Fixed by also setting
  `implicitWidth`/`implicitHeight` explicitly (not just `Layout.minimumWidth/Height`),
  which was needed to stop a real bug: without it, the *window* resized
  to the new minimum but the ColumnLayout content didn't stretch to
  match, leaving a blank white gap on the right. Calibrated to
  `gridUnit*62` to land at ~2x (1246px) the original ~630px.
- **Panel icon doubled**: `Kirigami.Units.iconSizes.small` (16) →
  `.medium` (32) for the `compactRepresentation` — these two tokens are
  exactly 2x apart on this system, a convenient match for "double the
  size."
- **Connected-device-count badge** added to the compact icon (bottom-right,
  `Kirigami.Theme.highlightColor` circle, visible when
  `connectedDevices.length > 0`). Found and fixed a real bug here: the
  badge `Rectangle` set `implicitHeight` instead of `height` — a plain
  `Rectangle` (not managed by a Layout) never reads `implicitHeight` to
  size itself, so it rendered at zero height and was invisible.
- **Forget button**: icon changed from `edit-delete-remove-symbolic`
  (renders as a red X/cross) to `user-trash-symbolic` (an actual bin),
  and it's no longer icon-only — it shows the "Forget" label too.
- **Trust control**: `CheckBox` → `Switch`, kept at the right end of the
  expanded footer row (Forget stays left).
- **Spacing pass**: bumped several `Kirigami.Units.smallSpacing` values
  to `largeSpacing` — the pills row, the card's own `Layout.margins`,
  the outer `ColumnLayout`'s `spacing`, and the footer section's margins
  — since components read as too close together.

### Debugging notes worth preserving

Verifying the panel icon changes turned into a real investigation,
documented here so a future session doesn't repeat it:

1. **A confirmed, separate real bug was found along the way**:
   `font.pointSize: PlasmaComponents3.Label.font.pointSize * 0.9` is
   invalid — it treats the *type name* `PlasmaComponents3.Label` as if
   it were a live instance with its own `.font`, which doesn't exist,
   throwing `TypeError: Cannot read property 'pointSize' of undefined`
   at runtime on every load (confirmed via `journalctl --user -u
   plasma-plasmashell.service`, not caught by `qmllint`). Fixed by using
   `Kirigami.Theme.defaultFont.pointSize * 0.9` instead — this pattern
   had been copy-pasted across 4 spots since Stage A and silently
   broken the whole time.
2. **Removing + re-adding a panel widget via Plasma's scripting console
   (`panel.addWidget()` / `appletObj.remove()`) does NOT reliably force
   a fresh QML reload.** Multiple remove/re-add cycles after editing
   `main.qml` kept showing stale behavior. Only a genuine
   `systemctl --user restart plasma-plasmashell.service` guaranteed the
   new code was actually running — confirmed by adding a deliberately
   obvious diagnostic (`Rectangle { anchors.fill: parent; color: "red"
   }`, no visibility condition) to `compactRepresentation` and seeing it
   only appear after a real restart, never after any number of
   scripted remove/re-adds.
3. **Self-correction**: initially misidentified a bluetooth+badge icon
   already present in the system tray as "our widget's badge working" —
   it was actually KDE's own pre-existing `org.kde.plasma.bluetooth`
   systray applet (visible in `~/.config/plasma-org.kde.plasma.desktop-appletsrc`'s
   `knownItems`/`extraItems`, unrelated to `org.rupesh.bluetune`). There
   was never an actual duplicate instance of BlueTune — only ever one,
   directly on the panel. Corrected this to the user rather than letting
   the false confirmation stand.
4. Verification method for the live panel throughout: never took a raw
   full-desktop screenshot (would expose open windows/browser
   tabs/taskbar). Instead, queried the panel's own `frameGeometry` via
   `panels()[0].frameGeometry` through the same scripting console, then
   `spectacle -f -b` (full screen, background) piped directly into
   `magick ... -crop <panel-geometry>` so only the thin panel strip
   ever got read/viewed — the full-desktop capture was deleted
   immediately after cropping, unread.

## Post-roadmap: pill padding + window resize (partially verified)

Requested: more internal room in the battery/codec/format pills, popup
width halved, popup height doubled (both relative to the previous pass).

- Pill padding: inner padding around each pill's `RowLayout` bumped from
  `smallSpacing`/`largeSpacing` to `largeSpacing`/`largeSpacing * 2`
  (height/width respectively) for all three pills.
- Width: `gridUnit*62` → `gridUnit*31` (half). Height:
  `gridUnit*4 + count*gridUnit*8` → `gridUnit*8 + count*gridUnit*16`
  (double).

**`plasmawindowed` gotchas hit while verifying this (both now known,
neither is a `main.qml` bug):**
- It persists window geometry across launches in
  `~/.config/plasmawindowedrc` (`[Applets][4][Configuration] geometry=...`)
  — a *stale remembered size* silently overrides whatever
  `Layout.minimumWidth/Height` the QML currently requests, exactly the
  same class of surprise as the plasmashell qmlcache issue from the
  previous round. Delete this file before trusting any width/height
  test in this tool.
- It also has its own `~/.cache/plasmawindowed/qmlcache/`.
- Even with both cleared, a small persistent gap/edge-mismatch appeared
  around the popup's right/bottom edge in this tool specifically
  whenever the requested size didn't closely match content's natural
  size in either direction (too big *or* too small) — added
  `Layout.preferredWidth`/`Layout.preferredHeight` alongside
  `Layout.minimumWidth/Height` and `implicitWidth/Height` (belt-and-braces;
  `Layout.preferredWidth/Height` is the more standard property for this
  purpose). This didn't visibly change plasmawindowed's small edge
  artifact, but is more correct regardless and worth keeping.
- **Confirmed via measured pixel dimensions**: width did shrink
  correctly across three tests (630 baseline → ~1246 doubled →
  ~688 halved), tracking the requested ratios. **Height could not be
  confirmed** — it stayed ~658px across every test regardless of the
  `Layout.minimumHeight`/`preferredHeight`/`implicitHeight` formula,
  suggesting this tool's window height comes from somewhere else
  entirely (a harness default, not a genuine size negotiation) — this
  was true even before this session's changes (see the original Stage E
  screenshots). The real Plasma panel popup should be checked directly
  by the user for whether height doubling actually took effect, since
  `plasmawindowed` isn't a reliable judge of this dimension.

**Incident**: mid-verification, the KWin window-activation script failed
silently once (the target window wasn't focused yet) and a screenshot
briefly captured the user's actual browser (a YouTube video) instead of
the test window. Caught by checking dimensions before viewing on every
subsequent screenshot (630×658-ish expected vs. ~1750×1500 actual was
the tell) — the browser capture was deleted immediately and never acted
on further. Re-confirms the standing practice: **always check
`file <path>` dimensions match the expected small popup size before
`Read`-ing any screenshot from this tool.**

## Post-roadmap: unified device card + real panel popup-size persistence (done)

Restructured the device list from N individual `Kirigami.AbstractCard`s
into **one** outer card containing all device rows stacked inside it
(`Kirigami.Separator` between entries, none after the last), per
request — a new device connecting adds a row inside the existing card
rather than a new card of its own. Each row now has:
- A hover-only gradient highlight (`HoverHandler` + a `Rectangle` with a
  horizontal `Gradient`, faded in/out via `Behavior on opacity` — not a
  flat color swap).
- Reduced opacity (`0.55`) for the whole row's content when
  `!modelData.connected`, on top of the existing Connect/Disconnect
  button and hidden pills already differing by state — makes
  disconnected devices read as visually "inactive" at a glance.

Also: the Discoverable/Add-New-Device footer was consolidated onto a
single row (Add New Device left, Discoverable label+switch grouped
together on the right — previously `Layout.fillWidth: true` on the
*label* pushed the switch away to the far edge; fixed by removing that
and pushing both right via a leading `Item { Layout.fillWidth: true }`
instead), and the `Item { Layout.fillHeight: true }` spacer was moved to
sit *before* this footer (was after it) so the footer stays pinned to
the bottom of the popup instead of trailing the device card with empty
space below it.

**Found a second confirmed real bug while restarting to verify**:
`text: modelData.codec.toUpperCase()` crashed with `TypeError: Cannot
call method 'toUpperCase' of null` — even though that pill's `visible`
was `false` for a null codec. QML evaluates child property bindings
regardless of an ancestor's `visible` state; `visible: false` only
skips rendering, not binding evaluation. This fired reliably right after
a plasmashell restart, in the brief window before the first `pactl`
poll populates `codecInfo` (codec starts `null` for every device,
including connected audio ones). Fixed with `(modelData.codec ||
"").toUpperCase()`. **Lesson: gate a value with `|| ""`/`|| null` at the
point of use, not just via the sibling `visible:` condition** — the two
are unrelated in QML.

**Also found**: the *real* panel widget persists its own popup size the
same way `plasmawindowed` does — `popupWidth`/`popupHeight` under
`[Containments][N][Applets][<id>][Configuration]` in
`~/.config/plasma-org.kde.plasma.desktop-appletsrc`. Cleared via
`kwriteconfig6 ... --key popupWidth --delete` (and `popupHeight`) before
the width-halving change would have any visible effect — this is why
"window width is still large" was reported even after the QML change
had already landed on a previous restart.

Built and published an **icon-picker artifact** showing real (not
recreated) Breeze SVGs for 3 alternative Bluetooth glyphs plus the
existing one, so the user can pick a replacement by name rather than
by description.

## Post-roadmap: icon selection from the picker (done)

User picked from the icon artifact: "Clean rune"
(`network-bluetooth-symbolic`) for the header icon beside "BlueTune",
and a new 3-state scheme for the panel/tray icon via a single
`root.panelIconName` computed property:
- adapter not powered → `preferences-system-bluetooth-inactive-symbolic`
  (unchanged from before)
- powered, ≥1 device connected → `network-wireless-bluetooth-symbolic`
  (the "wireless signal" option), paired with the existing count badge
- powered, no device connected → `network-bluetooth-symbolic` (clean
  rune, same as the header)

Verified live via the panel-strip-crop technique (this time using the
*correct* geometry source — see the API-mixup note below). The count
badge showed "2", which looked suspicious at first but was real: the
user had both their OnePlus Buds 4 *and* an Acer BT Keyboard connected
— incidentally a good live confirmation that the all-device-types
broadening from an earlier stage actually works end-to-end, not just
for audio devices.

**API mixup worth flagging**: `panels()[0].frameGeometry` (and
`.geometry`) both threw `TypeError: Cannot read property 'x' of
undefined` — `panels()` is a `org.kde.PlasmaShell.evaluateScript`
(Plasma Shell scripting) function, and its Panel objects don't expose
geometry that way. The actual panel geometry comes from **KWin's**
scripting console instead: `workspace.windowList()`, filtered to
`resourceClass === "plasmashell" && !normalWindow`, then `.frameGeometry`
on that window object. Don't reach for `panels()` when the goal is
pixel geometry — it's the wrong API for that.

## Post-roadmap: sizing/padding/color tuning (done)

- Popup: 15% narrower / 30% shorter than the previous pass — added
  `popupWidthUnits`/`popupHeightUnits` readonly properties on the
  `fullRepresentation` root (`31 * 0.85`, `(8 + count*16) * 0.7`)
  instead of repeating the arithmetic across 6 `Layout.*`/`implicit*`
  properties.
- Panel icon doubled again: `iconSizes.medium` (32) → `.huge` (64),
  another exact-2x token match.
- Badge/icon overlap fixed: `anchors.rightMargin: parent.width * 0.2` on
  the panel icon (not `width * 0.2` — that would've been a binding loop,
  since `anchors.fill` is what determines `width` in the first place).
  Verified live via the panel-strip crop: badge now sits cleanly beside
  the glyph, no overlap.
- Header icon (beside "BlueTune") now colors by adapter state:
  `Kirigami.Theme.highlightColor` (blue) when powered,
  `negativeTextColor` (red) when off — confirms `Kirigami.Icon` (the
  top-level component, unlike the lower-level `Primitives.Icon` used
  inside `Kirigami.Chip`) recolors `-symbolic` icons via a plain `color:`
  binding with no `isMask` needed, consistent with the battery pill icon
  earlier in this file.

Noted but not fixed (matches earlier panel-icon-sizing findings): the
panel visibly clamps the icon's *rendered* height to the panel's own
thickness (30px here) regardless of the `iconSizes.huge` request — the
size increase shows up more as extra reserved width (which is exactly
what made room for the badge padding) than a dramatically taller glyph.
This is a Plasma panel-icon-slot constraint, not something fixable from
`main.qml`.

## Post-roadmap: reverted icon padding/size (done)

User asked to undo the previous tuning: removed the
`anchors.rightMargin` right-inset on the panel icon and dropped it back
from `iconSizes.huge` (64) to `.medium` (32) — half of `.huge`, back to
where it was two stages ago. Verified via `journalctl` (clean restart,
no errors) and confirmed the widget is still on the panel.

## Post-roadmap: icon iterations + a real "can't turn Bluetooth on" bug (done)

Quick follow-ups: padding removed then re-added (net no-op, user
changed their mind), panel icon bumped to `iconSizes.medium * 1.3`
(+30%). Then, per user feedback, dropped
`network-wireless-bluetooth-symbolic` entirely as the "connected" panel
icon — its built-in wifi-style signal arcs read as a second Wi-Fi icon
sitting next to the systray's real one, confirmed by cropping and
comparing both icons side by side live. `root.panelIconName` now only
has two states (off vs. on), both using the clean rune
(`network-bluetooth-symbolic`); connected-vs-not is communicated by the
count badge alone.

**Real functional bug reported and fixed**: turning Bluetooth on via the
header switch did nothing when the adapter was already off. Root cause:
`BluezQt.Manager.usableAdapter` only returns a value when *some* adapter
is already powered — it's `null` on an all-off system, so
`if (BluezQt.Manager.usableAdapter) { ...powered = checked... }` never
even ran. A chicken-and-egg null-guard: the very code meant to power
the adapter on could never fire, because powering on was gated on the
adapter already being powered on. This affected every `usableAdapter`
call site (power switch, discoverable switch — moot there since that
row is hidden when off, header icon color, `panelIconName`), not just
one.

Fixed with a new `root.adapter` computed property: `Manager.usableAdapter
|| Manager.adapters[0]` — `Manager.adapters` lists every adapter
regardless of power state (BlueZ adapter D-Bus objects persist whether
powered or not; only `usableAdapter`'s own selection logic excludes
unpowered ones). All 8 `BluezQt.Manager.usableAdapter` call sites in
`main.qml` now go through `root.adapter` instead. Verified via a clean
plasmashell restart with no runtime errors; the actual click-through
(does the switch now really power the adapter on) needs the user to
confirm, since there's no way to synthesize a click in this environment.

## Code review fixes + full UI rebuild (done)

A `/code-review` run (background fork, ~2 combined runs) surfaced real
bugs before publishing. On inspecting the actual `main.qml` on disk to
apply them, found it had regressed/never advanced past roughly the
Stage D/E state above — none of the "Post-roadmap" UI work documented
below it (unified card, hover-gradient rows, pill rectangles, tray
badge, `panelIconName`, the `root.adapter` fix itself) was actually
present in the file, despite being fully documented here and in
`CLAUDE.md`. Root cause not established (no stash, only one git commit
in history) — treated as ground truth being the file on disk, not the
docs, and rebuilt from this file's own history rather than assuming the
docs were right.

**Bug fixes applied** (verified via `qmllint` + a clean plasmashell
restart with no `journalctl` errors):
- Battery icon capped at the "090" tier even at 100% battery
  (`Math.min(9, ...)` off-by-one) — fixed to `Math.min(100, ...)`, now
  reaches `battery-100-symbolic` (confirmed present in Breeze-Dark).
- `codecInfo` was reassigned to a brand-new array every 5s poll tick
  regardless of whether the data changed, forcing the device-list
  Repeater to destroy/recreate every row delegate every tick and
  silently lose in-progress Connect/Disconnect busy-state. Fixed by only
  reassigning when `JSON.stringify` of the new/old data actually
  differs.
- Fallback icon for an unrecognized device type was
  `preferences-system-bluetooth-activated-symbolic` (implies "on"),
  contradicting a simultaneously-dimmed disconnected row. Switched to
  the neutral `preferences-system-bluetooth-symbolic`.
- Tray tooltip could show a stray unlabeled blank line for a connected
  non-audio device with no battery/codec. Fixed to always prefix each
  line with the device's name.
- `bt-audio-info.sh` re-ran and re-parsed the entire `pactl list sinks`
  dump once per matched sink instead of once total — now captured once
  outside the loop; verified the script's JSON output is unchanged.
- Restored the `root.adapter` fallback (see the entry above) — the file
  on disk had regressed to calling `BluezQt.Manager.usableAdapter`
  directly at all 6 call sites, reintroducing the exact "turning
  Bluetooth on doesn't work from an all-off state" bug that was already
  found and fixed once.

**UI rebuilt from this file** (per the "Post-roadmap" sections below),
re-derived from this document since the working file didn't have it:
unified single `Kirigami.AbstractCard` with `Kirigami.Separator` between
device rows; hover-only gradient highlight per row
(`HoverHandler` + `Gradient` + `Behavior on opacity`); `opacity: 0.55`
on a disconnected row's content; expand/collapse chevron
(`go-down-symbolic`/`go-up-symbolic`) revealing a footer with Forget
(`user-trash-symbolic` + label, left) and a Trusted `Switch` (right);
battery/codec/format as plain `Rectangle`-based pills (battery colored
by severity, codec/format in `Kirigami.Theme.highlightColor`) — codec
and format now split into two pills via a new
`root.shortSampleSpec(spec)` (parses `"s24le 2ch 48000Hz"` → `"24-bit/48kHz"`);
header with the power switch beside "BlueTune" and a trailing spacer;
footer row with Add New Device (left) and Discoverable (right), pinned
to the bottom via `Item { Layout.fillHeight: true }` placed before it;
popup sized via `popupWidthUnits`/`popupHeightUnits` (`31 * 0.85`,
`(8 + count*16) * 0.7`) applied to `Layout.minimum/preferred/implicit`
together; compact tray icon at `iconSizes.medium * 1.3` with a 5%
right-inset and a count badge.

**Verified live**:
- `qmllint` clean, no `journalctl` runtime errors after a fresh
  plasmashell restart.
- Full dropdown checked via `plasmawindowed` (geometry/cache cleared
  first): unified card renders both the connected OnePlus Buds 4 (green
  90% battery pill, LHDC_V5 codec pill, 24-bit/48kHz format pill,
  Disconnect button) and the disconnected Acer BT Keyboard (dimmed,
  Connect button, no pills) exactly as documented.
- Tray icon checked via the panel-strip-crop technique: the clean-rune
  glyph (`network-bluetooth-symbolic`) renders correctly with no
  wifi-arc confusion. **The count badge does not currently render in
  the real System Tray slot** — see the new gotcha in `CLAUDE.md`. Not
  yet root-caused; flagged rather than silently claimed working, since
  `plasmawindowed` can't be used to check `compactRepresentation` at
  all.
