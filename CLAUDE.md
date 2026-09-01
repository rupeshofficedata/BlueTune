# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**BlueTune** — a KDE Plasma 6 system tray widget (a "plasmoid") and general
Bluetooth manager: lists *all* paired devices (audio, input, phone,
etc.), each with connect/disconnect, trust, forget; adapter-wide
power/discoverable toggles; and an add-device flow. Audio devices
additionally show battery %, codec, and sample format — information
KDE's own BlueDevil applet doesn't display. The original 5-stage build
roadmap in `PLAN.md` was audio-only; it's since been broadened to all
device types and rebranded (see PLAN.md's "Post-roadmap" section) —
treat further work as incremental additions on top of that, not a new
phase plan.

## Dev workflow (no build step)

This is an interpreted QML/shell plasmoid — there is no compile/build/lint
command. The dev loop is: edit files → reload the widget in the live panel
→ observe.

Symlink this project into Plasma's plasmoid directory so edits apply live:

```bash
ln -s "$(pwd)" ~/.local/share/plasma/plasmoids/org.rupesh.bluetune
```

Then add it via Plasma: right-click panel → *Add Widgets…* → search
"BlueTune" → drag onto the panel or into the system tray.

To pick up QML changes after editing: **removing and re-adding the
widget from the panel is not reliable** — confirmed by testing (a
deliberately obvious `color: "red"` diagnostic added to
`compactRepresentation` didn't appear after several remove/re-add
cycles via Plasma's scripting console, with no errors either). Only a
genuine `systemctl --user restart plasma-plasmashell.service` reliably
picks up changes for an already-placed panel widget.

For iterating on `fullRepresentation` without touching the user's real
panel, use `plasmawindowed org.rupesh.bluetune` — but it is **not**
reliably fresh either, and has caught out testing twice:
- It persists window geometry across launches in
  `~/.config/plasmawindowedrc` — delete this file before trusting any
  width/height test, or it silently reuses a remembered size regardless
  of what the QML currently requests.
- It has its own QML cache at `~/.cache/plasmawindowed/qmlcache/`,
  separate from plasmashell's — clear it the same way if changes don't
  seem to show up.
- It only renders `fullRepresentation`, never
  `compactRepresentation`/the panel icon — that part can only be
  checked on the real panel (see the screenshot-safety note below).

To test the data script standalone (outputs JSON, no Plasma needed):

```bash
bash contents/scripts/bt-audio-info.sh
```

## Architecture

Split by data source: device state (name/connected/battery/trusted) is
reactive via BluezQt; codec/sample-format is polled via a shell script,
since that side has no D-Bus equivalent. QML merges the two by MAC
address.

- **`contents/ui/main.qml`** — a `PlasmoidItem` that imports
  `org.kde.bluezqt as BluezQt` and reads `BluezQt.Manager.devices`
  directly (a live, signal-backed list of *all* paired devices of any
  kind, not just connected ones or just audio ones — no polling for this
  part). `root.devices` sorts connected devices first, resolves each
  device's icon through `root.iconForDevice()` (see below), flags
  `isAudio` (true when the device's raw BlueZ icon is
  `audio-card`/`audio-headset`/`audio-headphones`), and merges in
  codec/sampleSpec from `root.codecInfo` via
  `root.codecFor(device.address)` (only ever populated for audio
  devices — nothing else has a PipeWire sink). `root.connectedDevices`
  (filtered to `d.connected`) drives the tray icon/status/tooltip
  specifically, so a paired-but-disconnected device doesn't make the
  tray show as active. `root.panelIconName` picks the tray glyph from 2
  real Breeze icons based on adapter state only:
  `preferences-system-bluetooth-inactive-symbolic` (adapter off) or
  `network-bluetooth-symbolic` (powered — same "clean rune" glyph used
  beside the "BlueTune" header title). A third, connected-specific
  `network-wireless-bluetooth-symbolic` state was tried and dropped —
  its built-in signal arcs read as a second, confusable Wi-Fi icon next
  to the systray's real one, so connected-vs-not is communicated by the
  count badge alone, not by icon choice. Renders a compact tray icon
  (`compactRepresentation`,
  `Kirigami.Units.iconSizes.medium` — doubled from `.small`, exactly 2x
  on this system — plus a `connectedDevices.length` count badge
  bottom-right) plus an expanded dropdown
  (`fullRepresentation`, sized via `Layout.minimumWidth`/`preferredWidth`/
  `implicitWidth` all set together — see the sizing gotcha below): a
  header with the adapter Powered switch immediately beside the
  "BlueTune" title (a trailing spacer `Item` absorbs the rest of the
  row's width, not the heading), then **one single `Kirigami.AbstractCard`**
  containing every device as a stacked row (`Kirigami.Separator` between
  rows, none after the last) — devices are *not* individually carded
  anymore. Each row: icon, name, Connect/Disconnect, a chevron
  (`go-down-symbolic`/`go-up-symbolic`) that toggles `deviceRow.expanded`;
  battery/codec/format each render as their own custom `Rectangle`-based
  pill (not `Kirigami.Chip` — see the gotcha below) — battery colored by
  severity, codec and format both in `Kirigami.Theme.highlightColor`;
  expanding reveals a footer row (aligned under the name, past the icon)
  with Forget (`user-trash-symbolic` + label, left) and a Trusted
  `Switch` (right). A row also has a hover-only horizontal gradient
  highlight (`HoverHandler` + `Gradient`, faded via `Behavior on
  opacity`) and drops to `opacity: 0.55` when `!modelData.connected`, on
  top of the state already differing via the Connect/Disconnect button
  label and hidden pills. Discoverable and "Add New Device" share one
  footer row below the card (Add New Device left, Discoverable
  label+switch grouped right), pinned to the bottom of the popup via a
  `Item { Layout.fillHeight: true }` placed *before* this row (not
  after) — there's no overflow/`⋮` menu anywhere, every control is
  either always visible or one tap away.
- **`root.deviceIconMap`** (in `main.qml`) whitelists the fixed set of
  icon names BlueZ's `bluetoothd` actually emits (`device_get_icon()`:
  audio-card/headset/headphones, camera-photo/video, computer,
  input-gaming/keyboard/mouse/tablet, modem, network-wireless, phone,
  printer, scanner) against names verified present in
  Breeze/Breeze-Dark, substituting where one doesn't exist (`modem` has
  no icon in this theme → mapped to `network-modem`), and falls back to
  a generic Bluetooth glyph for anything else/unset via
  `root.iconForDevice(d)`. There is intentionally no "earbuds" vs.
  "headset" distinction — neither BlueZ nor the freedesktop icon-naming
  spec have one, and Breeze ships no separate earbuds asset, so both
  render as `audio-headset`. Brand/vendor logos (e.g. an actual Sony
  icon) are out of scope: BlueZ exposes no vendor-logo data, no icon
  theme ships trademarked logos, and fetching them externally was
  explicitly declined (network dependency, device-name leakage,
  trademark/redistribution risk) — see PLAN.md's "Post-roadmap" section.
- **`contents/scripts/bt-audio-info.sh`** — the only place that touches
  `pactl`. Every 5s (via `P5Support.DataSource`, `executable` engine) it
  greps `pactl list sinks` for each `bluez_output.<mac>.<profile>` sink,
  emitting a JSON array of `{mac, codec, sampleSpec}` — codec/sampleSpec
  are `null` when a sink has no codec metadata (including when the device
  is disconnected, since there's no active sink for it). No
  `bluetoothctl` calls at all; BlueZ exposes no codec info over D-Bus
  (PipeWire/PulseAudio-only).
- **`metadata.json`** — KPackage plasmoid manifest (id
  `org.rupesh.bluetune`, min Plasma API 6.0.4).
  `X-Plasma-NotificationAreaCategory: "Hardware"` is what makes this a
  proper System Tray entry (shows in the tray's Entries list, can be
  toggled shown/hidden) rather than only addable by manually dragging it
  onto the panel — same key KDE Connect's own metadata.json uses.

### Contract between the script and the QML

`root.codecInfo` (from the script): array of `{mac, codec, sampleSpec}`,
`codec`/`sampleSpec` nullable. `root.codecFor(address)` does a
case-insensitive MAC match against it. Changing this shape means
updating both sides.

### BluezQt gotchas (confirmed against `bluez-qt 6.29.0` on this system)

- `BluezQt.Manager` is used directly as a value (`BluezQt.Manager.foo`),
  not instantiated — it's a C++-registered singleton.
- **`BluezQt.Manager.usableAdapter` is `null` whenever no adapter is
  currently powered** — it specifically selects a *powered* adapter, not
  just any adapter. This caused a real bug: the "turn Bluetooth on"
  switch's `if (BluezQt.Manager.usableAdapter) { ...powered = checked }`
  could never fire from an all-off state, since the guard it needed to
  pass required Bluetooth to already be on. Use `root.adapter` instead
  (`main.qml`) — it falls back to `BluezQt.Manager.adapters[0]` (the
  full adapter list, unfiltered by power state) when `usableAdapter` is
  null. Any new code that needs to *change* adapter power/discoverable
  state must go through something like `root.adapter`, not
  `usableAdapter` directly — `usableAdapter` is fine for read-only
  "what's currently active" checks once something is already on.
- `device.battery` is `null` for devices that don't advertise a Battery1
  D-Bus interface — always guard with `d.battery ? d.battery.percentage : null`.
- `connectToDevice()`/`disconnectFromDevice()` (and every other mutating
  call) return an async `BluezQt.PendingCall` — connect to its `finished`
  signal, don't poll `isFinished`. If your callback closure captures a
  Repeater delegate by id, guard every access with `if (!delegateId) return;`
  first: a successful disconnect removes the device from
  `connectedDevices`, which can destroy that delegate *before* `finished`
  fires (see `main.qml`'s `deviceCard.toggleConnection()`).
- Full API surface (Manager/Adapter/Device/PendingCall) is documented in
  `PLAN.md`'s Stage B section; re-derive from
  `/usr/lib/qt6/qml/org/kde/bluezqt/bluezqtextensionplugin.qmltypes` if
  it needs re-confirming on a different BlueZQt version.
- Never bind a `Switch`/`CheckBox`'s `checked` directly to a backend bool
  (`checked: adapter.powered`) — the control's own click handling does an
  imperative write that permanently breaks a plain QML binding, so it
  stops reflecting external state changes after the first click. Use an
  explicit `Binding { target: ...; property: "checked"; value: ...;
  restoreMode: Binding.RestoreBinding }` instead (see `powerSwitch`,
  `discoverableSwitch`, `trustCheck` in `main.qml`).
- **Don't use `Kirigami.Chip` for a colored display pill.** Its label
  color is hardcoded to `Platform.Theme.textColor` inside the
  component's own template (`kirigami/controls/Chip.qml`) — there is no
  public property to override it, so a chip can never fully recolor by
  severity (only its icon can, and only with `iconMask: true` set). The
  battery/codec pills in `main.qml` are therefore plain `Rectangle`s
  (`radius: height / 2`, sized from an inner `RowLayout`'s
  implicit size) with a single `pillColor` property shared by the icon,
  the label, and the border — that's the only way to get the whole pill
  (not just the icon) to reflect state.
- `Kirigami.AbstractCard`'s `background` property can be overridden
  directly (see `deviceCard` in `main.qml`) to get a specific corner
  radius/fill/border rather than the platform default
  (`DefaultCardBackground`, which follows the user's own
  `Kirigami.Units.cornerRadius`/contrast settings) — worth knowing this
  is a deliberate tradeoff (a fixed look vs. one that tracks the user's
  system style) before reaching for it again elsewhere.
- **Never write `SomeType.someProperty` where `SomeType` is a component
  name, not an id/singleton** (e.g. `PlasmaComponents3.Label.font.pointSize`).
  This was in the codebase for a while, silently throwing `TypeError:
  Cannot read property 'pointSize' of undefined` on every load
  (`qmllint` did not catch it — only visible via
  `journalctl --user -u plasma-plasmashell.service`). Use
  `Kirigami.Theme.defaultFont.pointSize` for a scaled default label size
  instead.
- **A plain `Rectangle` not managed by a Layout does not size itself
  from `implicitHeight`/`implicitWidth`** — those only drive sizing for
  Layout-managed children (which read implicit size as a fallback) or
  types that explicitly bind their own `height`/`width` to it
  internally. Setting only `implicitHeight` on a free-floating
  `Rectangle` (e.g. an absolute-positioned badge) leaves the real
  `height` at 0 — invisible, no error. Set `height`/`width` directly.
  (This bit the connected-device-count badge on the tray icon.)
- **The count badge still doesn't render in the actual System Tray
  slot**, confirmed via a panel-strip-crop screenshot with a real device
  connected (`explicit height/width` fix above notwithstanding) — the
  glyph itself renders correctly (`network-bluetooth-symbolic`, no
  wifi-arc confusion), but no colored circle/count is visible next to
  it. Same family of issue as the icon-height clamp below: the System
  Tray's own "Entries" slot appears to constrain `compactRepresentation`
  to a size that doesn't leave room for anything anchored past the
  icon's own bounds. Not yet root-caused — `plasmawindowed` can't help
  here since it never renders `compactRepresentation` at all, only the
  real panel does. Next step if revisited: check whether the System
  Tray's slot forces `clip: true` on the delegate it wraps
  `compactRepresentation` in.
- **Debugging something in `compactRepresentation` specifically**: don't
  trust "no visible change + no error" as proof the code is wrong —
  confirm you're actually running current code first (see the
  reload-reliability note above). A `color: "red"; anchors.fill: parent`
  override with no visibility condition is a good forcing function to
  rule out reload-staleness before debugging the real logic.
- **Sizing `fullRepresentation`**: set `Layout.minimumWidth/Height`,
  `Layout.preferredWidth/Height`, *and* `implicitWidth/Height` together
  to the same value — no single one of these reliably drives the popup's
  actual rendered size on its own in every case observed.
  `Layout.minimumWidth` alone was a no-op when content's natural width
  already exceeded it; adding only `implicitWidth` fixed a blank-gap
  render bug at one size but the same class of gap reappeared at a
  different (smaller) target size. `Layout.preferredWidth/Height` is the
  more standard property for this and is now set alongside the others.
  Popup **height** in particular could never be confirmed to actually
  respond to any of these via `plasmawindowed` (stayed ~658px across
  every test) — verify height changes on the real panel, not this tool.
- **The real panel also persists popup size**, same as
  `plasmawindowed`'s `plasmawindowedrc` — `popupWidth`/`popupHeight`
  under `[Containments][N][Applets][<id>][Configuration]` in
  `~/.config/plasma-org.kde.plasma.desktop-appletsrc`. If a width/height
  change to `fullRepresentation` doesn't seem to take effect on the real
  panel even after a clean `systemctl --user restart
  plasma-plasmashell.service`, check there first:
  `kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc --group
  Containments --group <N> --group Applets --group <id> --group
  Configuration --key popupWidth --delete` (and `popupHeight`).
- **A `visible: false` binding does not stop QML from evaluating that
  item's other property bindings** — it only skips rendering. `text:
  modelData.codec.toUpperCase()` inside a pill gated by `visible: !!modelData.codec`
  still threw `TypeError: Cannot call method 'toUpperCase' of null`,
  because `codec` really can be `null` (e.g. briefly on every plasmashell
  restart, before the first `pactl` poll completes). Guard the value
  itself at the point of use (`(modelData.codec || "").toUpperCase()`),
  never rely on a sibling/ancestor `visible:` condition to make a null
  access safe.

### Screenshot safety (live desktop verification)

Never assume a KWin window-activation script succeeded — it has failed
silently at least once (target window not focused when the script ran),
and the next screenshot captured the user's actual browser instead of
the test window. **Always check `file <screenshot path>` and confirm the
dimensions look like the expected small popup (roughly 600-900px on a
side) before using `Read` on it.** A screenshot anywhere near full
screen/monitor resolution (e.g. 1700x1500+, 2560x1440) means the wrong
window was captured — delete it unread and re-activate before retrying.
This applies to both `plasmawindowed` test screenshots and the
panel-strip-crop technique used for `compactRepresentation`/tray-icon
verification (crop from a full-screen `spectacle -f -b` capture using
the panel's geometry, then delete the uncropped full capture
immediately — never view it directly).

**Getting that panel geometry**: `panels()[0].frameGeometry` (and
`.geometry`) throw `TypeError: Cannot read property 'x' of undefined` —
`panels()` is `org.kde.PlasmaShell.evaluateScript`'s function and its
Panel objects don't expose geometry this way. Use **KWin's** scripting
console instead (`org.kde.kwin.Scripting.loadScript` +
`.start`): `workspace.windowList()` filtered to `resourceClass ===
"plasmashell" && !normalWindow`, then read `.frameGeometry` on that
window object. Two different scripting APIs, easy to mix up — `panels()`
et al. are for *manipulating* panels/widgets (add/remove/configure),
KWin's `workspace`/window objects are for *geometry and window state*.

## Planned direction (see `PLAN.md`)

All 5 planned stages (UI/theming, BluezQt migration, connect/disconnect,
trust/forget/adapter toggles, all-devices-list + add-device) are done,
plus a post-roadmap pass that broadened scope from audio-only to all
Bluetooth device types and rebranded to BlueTune (see PLAN.md's
"Post-roadmap" section for what changed and why). "Add New Device"
launches BlueDevil's own `bluedevil-wizard` via a second
`P5Support.DataSource` (`launcher`) rather than reimplementing a pairing
agent — BlueDevil's `bluedevil.so` is already the system's default
BlueZ pairing agent, so registering a second one would conflict with it.
