import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support
import org.kde.bluezqt as BluezQt

PlasmoidItem {
    id: root

    // codec/sampleSpec are keyed by MAC and come from pactl (bt-audio-info.sh) —
    // BlueZ exposes no codec info over D-Bus, so this stays a polled shell script
    // while everything else (name/connected/battery) comes reactively from BluezQt.
    property var codecInfo: []

    // BluezQt.Manager.usableAdapter is null whenever no adapter is currently
    // powered — it specifically selects a *powered* adapter, not just any
    // adapter. Code that needs to read OR change adapter state (power switch,
    // discoverable switch, icons) must go through this fallback instead, or
    // "turn Bluetooth on" can never fire from an all-off state.
    readonly property var adapter: BluezQt.Manager.usableAdapter
        || (BluezQt.Manager.adapters.length > 0 ? BluezQt.Manager.adapters[0] : null)

    function codecFor(address) {
        for (var i = 0; i < codecInfo.length; i++) {
            if (codecInfo[i].mac.toUpperCase() === address.toUpperCase()) return codecInfo[i];
        }
        return null;
    }

    // Parses pactl's "s24le 2ch 48000Hz" down to "24-bit/48kHz": bit depth is
    // the leading number in the encoding token, sample rate is whatever
    // precedes "Hz", divided by 1000.
    function shortSampleSpec(spec) {
        if (!spec) return "";
        var tokens = spec.split(" ");
        var bitMatch = tokens.length > 0 ? tokens[0].match(/(\d+)/) : null;
        var rateMatch = spec.match(/(\d+)Hz/);
        var bits = bitMatch ? bitMatch[1] : "?";
        var rate = rateMatch ? Math.round(parseInt(rateMatch[1], 10) / 1000) : "?";
        return bits + "-bit/" + rate + "kHz";
    }

    // BlueZ derives Device.icon from the classic Bluetooth Class-of-Device
    // (or LE Appearance) and only ever returns one of this fixed set of
    // freedesktop icon names (see bluetoothd's device_get_icon()). Whitelist
    // them against names actually verified present in Breeze/Breeze-Dark
    // rather than trusting the string blindly, and substitute where a name
    // doesn't exist ("modem" isn't a real icon in this theme). Note: BlueZ
    // has no distinct icon for "earbuds" vs. "headset" — both classic CoD
    // and the standard icon-naming spec only distinguish
    // headset/headphones/speaker, not earbud form factor, so true wireless
    // earbuds show the same audio-headset glyph as a regular headset.
    readonly property var deviceIconMap: ({
        "audio-card": "audio-card",
        "audio-headset": "audio-headset",
        "audio-headphones": "audio-headphones",
        "camera-photo": "camera-photo",
        "camera-video": "camera-video",
        "computer": "computer",
        "input-gaming": "input-gaming",
        "input-keyboard": "input-keyboard",
        "input-mouse": "input-mouse",
        "input-tablet": "input-tablet",
        "modem": "network-modem",
        "network-wireless": "network-wireless",
        "phone": "phone",
        "printer": "printer",
        "scanner": "scanner"
    })
    readonly property var audioIcons: ["audio-card", "audio-headset", "audio-headphones"]

    function iconForDevice(d) {
        if (d.icon && deviceIconMap[d.icon]) return deviceIconMap[d.icon];
        return "preferences-system-bluetooth-symbolic";
    }

    // All paired Bluetooth devices of any kind (audio, input, phone, etc.),
    // connected or not, so the dropdown can offer a Connect button for
    // devices that aren't currently connected. Codec/sampleSpec only ever
    // populate for audio devices (nothing else has a PipeWire sink).
    readonly property var devices: {
        var list = [];
        var devs = BluezQt.Manager.devices;
        for (var i = 0; i < devs.length; i++) {
            var d = devs[i];
            var c = codecFor(d.address) || {};
            var isAudio = d.icon && audioIcons.indexOf(d.icon) !== -1;
            list.push({
                device: d,
                name: d.name,
                icon: iconForDevice(d),
                isAudio: isAudio,
                connected: d.connected,
                battery: d.battery ? d.battery.percentage : null,
                codec: c.codec || null,
                sampleSpec: c.sampleSpec || null
            });
        }
        list.sort((a, b) => (b.connected ? 1 : 0) - (a.connected ? 1 : 0));
        return list;
    }
    readonly property var connectedDevices: devices.filter(d => d.connected)
    readonly property bool hasConnectedDevice: connectedDevices.length > 0

    // Two states only: adapter off, or the clean rune glyph while powered.
    // A third "wireless signal" connected-state icon was tried and dropped —
    // its built-in signal arcs read as a second, confusable Wi-Fi icon next
    // to the systray's real one. Connected-vs-not is communicated by the
    // count badge on the compact icon alone.
    readonly property string panelIconName: {
        if (!(root.adapter && root.adapter.powered)) {
            return "preferences-system-bluetooth-inactive-symbolic";
        }
        return "network-bluetooth-symbolic";
    }

    Plasmoid.status: hasConnectedDevice ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus

    toolTipMainText: hasConnectedDevice ? connectedDevices.map(d => d.name).join(", ") : "No Bluetooth device connected"
    toolTipSubText: {
        if (connectedDevices.length === 0) return "";
        return connectedDevices.map(d => {
            var parts = [];
            if (d.battery !== null && d.battery !== undefined) parts.push("Battery: " + d.battery + "%");
            if (d.codec) parts.push("Codec: " + d.codec);
            return parts.length > 0 ? (d.name + " — " + parts.join(" • ")) : d.name;
        }).join("\n");
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source);
            var stdout = data["stdout"] || "";
            var parsed;
            try {
                parsed = JSON.parse(stdout);
            } catch (e) {
                parsed = [];
            }
            // Only reassign when the data actually changed — codecInfo feeds
            // root.devices, which is the Repeater's model, so replacing it
            // every 5s tick even when nothing changed destroys and recreates
            // every device delegate, losing in-progress actionPending/error
            // state on whatever the user was doing.
            if (JSON.stringify(parsed) !== JSON.stringify(root.codecInfo)) {
                root.codecInfo = parsed;
            }
        }
        function run() {
            connectSource("bash " + Qt.resolvedUrl("../scripts/bt-audio-info.sh").toString().replace("file://", ""));
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: exec.run()
    }

    // Launches BlueDevil's own pairing wizard rather than reimplementing a
    // pairing agent — BlueDevil's kded daemon is already the system's
    // default BlueZ pairing agent, so registering a second one would
    // conflict with it.
    P5Support.DataSource {
        id: launcher
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source);
        }
        function run(cmd) {
            connectSource(cmd);
        }
    }

    compactRepresentation: MouseArea {
        id: compactRoot
        Layout.minimumWidth: Kirigami.Units.iconSizes.medium * 1.3
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium * 1.3
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            anchors.rightMargin: parent.width * 0.05
            source: root.panelIconName
        }

        // A plain (non-Layout-managed) Rectangle doesn't size itself from
        // implicitWidth/Height — those only drive Layout-managed children.
        // Explicit width/height are required here or the badge renders at
        // zero size, invisibly.
        Rectangle {
            visible: root.connectedDevices.length > 0
            width: Kirigami.Units.gridUnit * 0.85
            height: Kirigami.Units.gridUnit * 0.85
            radius: width / 2
            color: Kirigami.Theme.highlightColor
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            PlasmaComponents3.Label {
                anchors.centerIn: parent
                text: root.connectedDevices.length
                color: Kirigami.Theme.highlightedTextColor
                font.pixelSize: parent.height * 0.65
            }
        }
    }

    fullRepresentation: ColumnLayout {
        id: fullRoot

        readonly property real popupWidthUnits: 31 * 0.85
        readonly property real popupHeightUnits: (8 + deviceRepeater.count * 16) * 0.7 * 0.3 * 1.3 * 1.5

        Layout.minimumWidth: Kirigami.Units.gridUnit * popupWidthUnits
        Layout.minimumHeight: Kirigami.Units.gridUnit * popupHeightUnits
        Layout.preferredWidth: Kirigami.Units.gridUnit * popupWidthUnits
        Layout.preferredHeight: Kirigami.Units.gridUnit * popupHeightUnits
        implicitWidth: Kirigami.Units.gridUnit * popupWidthUnits
        implicitHeight: Kirigami.Units.gridUnit * popupHeightUnits
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "network-bluetooth-symbolic"
                color: (root.adapter && root.adapter.powered) ? Kirigami.Theme.highlightColor : Kirigami.Theme.negativeTextColor
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            Kirigami.Heading {
                level: 3
                text: "BlueTune"
            }
            PlasmaComponents3.Switch {
                id: powerSwitch
                onToggled: {
                    if (root.adapter) {
                        root.adapter.powered = checked;
                    }
                }
            }
            Binding {
                target: powerSwitch
                property: "checked"
                value: !!(root.adapter && root.adapter.powered)
                restoreMode: Binding.RestoreBinding
            }
            Item { Layout.fillWidth: true }
        }

        Kirigami.PromptDialog {
            id: forgetDialog
            property var targetDevice: null

            title: "Forget this device?"
            subtitle: targetDevice ? ("Are you sure you want to forget \"" + targetDevice.name + "\"?") : ""
            standardButtons: Kirigami.Dialog.NoButton
            customFooterActions: [
                Kirigami.Action {
                    text: "Forget Device"
                    icon.name: "user-trash-symbolic"
                    onTriggered: {
                        if (forgetDialog.targetDevice && forgetDialog.targetDevice.adapter) {
                            forgetDialog.targetDevice.adapter.removeDevice(forgetDialog.targetDevice);
                        }
                        forgetDialog.targetDevice = null;
                    }
                },
                Kirigami.Action {
                    text: "Cancel"
                    icon.name: "dialog-cancel-symbolic"
                    onTriggered: forgetDialog.close()
                }
            ]
        }

        PlasmaComponents3.Label {
            visible: deviceRepeater.count === 0
            text: "No paired Bluetooth devices"
            color: Kirigami.Theme.disabledTextColor
            Layout.margins: Kirigami.Units.largeSpacing
        }

        // One single card holds every device row (Kirigami.Separator between
        // them, none after the last) — a newly connected device adds a row
        // inside this card rather than a new card of its own.
        Kirigami.AbstractCard {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.largeSpacing
            visible: deviceRepeater.count > 0

            background: Rectangle {
                radius: 10
                color: Kirigami.Theme.alternateBackgroundColor
                border.width: 1
                border.color: Kirigami.Theme.disabledTextColor
            }

            contentItem: ColumnLayout {
                spacing: 0

                Repeater {
                    id: deviceRepeater
                    model: root.devices

                    delegate: ColumnLayout {
                        id: deviceRow
                        Layout.fillWidth: true
                        spacing: 0

                        property bool expanded: false
                        property bool actionPending: false
                        property string actionError: ""

                        function toggleConnection() {
                            actionError = "";
                            actionPending = true;
                            var call = modelData.device.connected
                                ? modelData.device.disconnectFromDevice()
                                : modelData.device.connectToDevice();
                            call.finished.connect(function () {
                                // deviceRow may already be destroyed here: a
                                // successful disconnect removes the device
                                // from connectedDevices, which recomputes
                                // devices and drops this delegate before this
                                // callback runs.
                                if (!deviceRow) return;
                                deviceRow.actionPending = false;
                                if (call.error) {
                                    deviceRow.actionError = call.errorText;
                                }
                            });
                        }

                        Item {
                            id: rowBlock
                            Layout.fillWidth: true
                            implicitHeight: rowBlockContent.implicitHeight

                            // Whole-row click target: toggles expand/collapse
                            // from anywhere in the row's empty space. Sits
                            // behind the Connect/Disconnect button (declared
                            // later below), which still gets its own clicks
                            // first since later siblings paint and hit-test
                            // on top. Also drives the hover tint below, since
                            // a HoverHandler here would get its "hovered"
                            // state blocked while the pointer is over a child
                            // button's own internal hover handling.
                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: deviceRow.expanded = !deviceRow.expanded
                            }

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: 6
                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: Kirigami.Theme.highlightColor }
                                    GradientStop { position: 1.0; color: "transparent" }
                                }
                                opacity: rowMouse.containsMouse ? 0.30 : 0
                            }

                            // Groups the header row and the expanded
                            // Forget/Trusted footer into one block so the
                            // hover tint/click target above (sized to this
                            // ColumnLayout's implicit height) spans both,
                            // instead of stopping at the header.
                            ColumnLayout {
                                id: rowBlockContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                spacing: 0

                            RowLayout {
                                id: rowContent
                                Layout.fillWidth: true
                                Layout.margins: Kirigami.Units.largeSpacing * 1.4
                                spacing: Kirigami.Units.largeSpacing * 1.5
                                opacity: modelData.connected ? 1.0 : 0.55

                                Kirigami.Icon {
                                    source: modelData.icon
                                    Layout.alignment: Qt.AlignTop
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.largeSpacing * 1.6

                                    PlasmaComponents3.Label {
                                        text: modelData.name
                                        font.bold: true
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }

                                    RowLayout {
                                        spacing: Kirigami.Units.largeSpacing * 1.3
                                        Layout.fillWidth: true

                                        Rectangle {
                                            id: batteryPill
                                            visible: modelData.battery !== null && modelData.battery !== undefined
                                            property color pillColor: {
                                                if (modelData.battery > 50) return Kirigami.Theme.positiveTextColor;
                                                if (modelData.battery > 20) return Kirigami.Theme.neutralTextColor;
                                                return Kirigami.Theme.negativeTextColor;
                                            }
                                            radius: height / 2
                                            color: Kirigami.Theme.alternateBackgroundColor
                                            border.width: 1
                                            border.color: pillColor
                                            implicitWidth: batteryPillContent.implicitWidth + Kirigami.Units.largeSpacing * 2 * 0.75
                                            implicitHeight: batteryPillContent.implicitHeight + Kirigami.Units.largeSpacing * 0.75

                                            RowLayout {
                                                id: batteryPillContent
                                                anchors.centerIn: parent
                                                spacing: Kirigami.Units.smallSpacing * 1.4
                                                Kirigami.Icon {
                                                    source: "battery-" + (Math.min(100, Math.floor((modelData.battery || 0) / 10) * 10)).toString().padStart(3, '0') + "-symbolic"
                                                    color: batteryPill.pillColor
                                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small * 0.75
                                                }
                                                PlasmaComponents3.Label {
                                                    text: (modelData.battery || 0) + "%"
                                                    color: batteryPill.pillColor
                                                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.7
                                                }
                                            }
                                        }

                                        Rectangle {
                                            visible: modelData.isAudio && !!modelData.codec
                                            radius: height / 2
                                            color: Kirigami.Theme.alternateBackgroundColor
                                            border.width: 1
                                            border.color: Kirigami.Theme.highlightColor
                                            implicitWidth: codecPillContent.implicitWidth + Kirigami.Units.largeSpacing * 2 * 0.75
                                            implicitHeight: codecPillContent.implicitHeight + Kirigami.Units.largeSpacing * 0.75

                                            RowLayout {
                                                id: codecPillContent
                                                anchors.centerIn: parent
                                                spacing: Kirigami.Units.smallSpacing * 1.4
                                                Kirigami.Icon {
                                                    source: "audio-x-generic"
                                                    color: Kirigami.Theme.highlightColor
                                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small * 0.75
                                                }
                                                PlasmaComponents3.Label {
                                                    text: (modelData.codec || "").toUpperCase()
                                                    color: Kirigami.Theme.highlightColor
                                                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.7
                                                }
                                            }
                                        }

                                        Rectangle {
                                            visible: modelData.isAudio && !!modelData.sampleSpec
                                            radius: height / 2
                                            color: Kirigami.Theme.alternateBackgroundColor
                                            border.width: 1
                                            border.color: Kirigami.Theme.highlightColor
                                            implicitWidth: formatPillContent.implicitWidth + Kirigami.Units.largeSpacing * 2 * 0.75
                                            implicitHeight: formatPillContent.implicitHeight + Kirigami.Units.largeSpacing * 0.75

                                            RowLayout {
                                                id: formatPillContent
                                                anchors.centerIn: parent
                                                spacing: Kirigami.Units.smallSpacing * 1.4
                                                Kirigami.Icon {
                                                    source: "waveform-symbolic"
                                                    color: Kirigami.Theme.highlightColor
                                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.75
                                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small * 0.75
                                                }
                                                PlasmaComponents3.Label {
                                                    text: root.shortSampleSpec(modelData.sampleSpec)
                                                    color: Kirigami.Theme.highlightColor
                                                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 0.7
                                                }
                                            }
                                        }

                                        PlasmaComponents3.Label {
                                            visible: modelData.isAudio && !modelData.codec
                                            text: "No codec info"
                                            color: Kirigami.Theme.disabledTextColor
                                        }
                                        PlasmaComponents3.Label {
                                            visible: modelData.isAudio && !modelData.sampleSpec
                                            text: "No sample format info"
                                            color: Kirigami.Theme.disabledTextColor
                                        }
                                    }

                                    PlasmaComponents3.Label {
                                        visible: !!deviceRow.actionError
                                        text: deviceRow.actionError
                                        color: Kirigami.Theme.negativeTextColor
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                    }
                                }

                                PlasmaComponents3.BusyIndicator {
                                    visible: deviceRow.actionPending
                                    running: visible
                                    Layout.alignment: Qt.AlignTop
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                }
                                PlasmaComponents3.Button {
                                    text: modelData.device.connected ? "Disconnect" : "Connect"
                                    enabled: !deviceRow.actionPending
                                    Layout.alignment: Qt.AlignTop
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 5.2 * 0.85
                                    onClicked: deviceRow.toggleConnection()
                                }
                                PlasmaComponents3.ToolButton {
                                    // A real button (not a custom
                                    // Rectangle+Icon) so its pressed/active
                                    // look matches the other buttons in the
                                    // row natively, per the reference
                                    // screenshot's bordered chevron style.
                                    icon.name: deviceRow.expanded ? "go-up-symbolic" : "go-down-symbolic"
                                    checked: deviceRow.expanded
                                    Layout.alignment: Qt.AlignTop
                                    onClicked: deviceRow.expanded = !deviceRow.expanded
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                visible: deviceRow.expanded
                                Layout.leftMargin: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.largeSpacing * 2
                                Layout.rightMargin: Kirigami.Units.largeSpacing
                                Layout.bottomMargin: Kirigami.Units.largeSpacing

                                PlasmaComponents3.Button {
                                    text: "Forget"
                                    icon.name: "user-trash-symbolic"
                                    onClicked: {
                                        forgetDialog.targetDevice = modelData.device;
                                        forgetDialog.open();
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                PlasmaComponents3.Label { text: "Trusted" }
                                PlasmaComponents3.Switch {
                                    id: trustSwitch
                                    onToggled: {
                                        if (modelData.device) modelData.device.trusted = checked;
                                    }
                                }
                                Binding {
                                    target: trustSwitch
                                    property: "checked"
                                    value: !!(modelData.device && modelData.device.trusted)
                                    restoreMode: Binding.RestoreBinding
                                }
                            }
                            }
                        }

                        Kirigami.Separator {
                            Layout.fillWidth: true
                            visible: index < deviceRepeater.count - 1
                        }
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.margins: Kirigami.Units.largeSpacing
            Layout.fillWidth: true

            PlasmaComponents3.Button {
                text: "Add New Device"
                icon.name: "list-add"
                onClicked: launcher.run("bluedevil-wizard")
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Label {
                text: "Discoverable"
                visible: !!(root.adapter && root.adapter.powered)
            }
            PlasmaComponents3.Switch {
                id: discoverableSwitch
                visible: !!(root.adapter && root.adapter.powered)
                onToggled: {
                    if (root.adapter) {
                        root.adapter.discoverable = checked;
                    }
                }
            }
            Binding {
                target: discoverableSwitch
                property: "checked"
                value: !!(root.adapter && root.adapter.discoverable)
                restoreMode: Binding.RestoreBinding
            }
        }
    }
}
