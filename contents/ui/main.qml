import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property var devices: []
    readonly property bool hasAudioDevice: devices.some(d => d.isAudio)

    Plasmoid.status: hasAudioDevice ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus

    toolTipMainText: hasAudioDevice ? devices.filter(d => d.isAudio).map(d => d.name).join(", ") : "No Bluetooth audio device connected"
    toolTipSubText: {
        var audioDevs = devices.filter(d => d.isAudio);
        if (audioDevs.length === 0) return "";
        return audioDevs.map(d => {
            var parts = [];
            if (d.battery !== null && d.battery !== undefined) parts.push("Battery: " + d.battery + "%");
            if (d.codec) parts.push("Codec: " + d.codec);
            return parts.join(" • ");
        }).join("\n");
    }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source);
            var stdout = data["stdout"] || "";
            try {
                root.devices = JSON.parse(stdout);
            } catch (e) {
                root.devices = [];
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

    compactRepresentation: MouseArea {
        id: compactRoot
        Layout.minimumWidth: Kirigami.Units.iconSizes.small
        Layout.minimumHeight: Kirigami.Units.iconSizes.small
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: root.hasAudioDevice ? "audio-headset-bluetooth" : "bluetooth-active"
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 2 + (audioRepeater.count * Kirigami.Units.gridUnit * 4)
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            level: 3
            text: "Bluetooth Audio"
            Layout.margins: Kirigami.Units.smallSpacing
        }

        PlasmaComponents3.Label {
            visible: audioRepeater.count === 0
            text: "No Bluetooth audio device connected"
            opacity: 0.6
            Layout.margins: Kirigami.Units.smallSpacing
        }

        Repeater {
            id: audioRepeater
            model: root.devices.filter(d => d.isAudio)

            delegate: Kirigami.AbstractCard {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing

                contentItem: ColumnLayout {
                    spacing: Kirigami.Units.smallSpacing / 2

                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Icon {
                            source: modelData.icon || "audio-headset-bluetooth"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        }
                        PlasmaComponents3.Label {
                            text: modelData.name
                            font.bold: true
                            Layout.fillWidth: true
                        }
                    }

                    PlasmaComponents3.Label {
                        visible: modelData.battery !== null && modelData.battery !== undefined
                        text: "Battery: " + modelData.battery + "%"
                    }
                    PlasmaComponents3.Label {
                        visible: !!modelData.codec
                        text: "Codec: " + modelData.codec
                    }
                    PlasmaComponents3.Label {
                        visible: !!modelData.sampleSpec
                        text: "Format: " + modelData.sampleSpec
                        opacity: 0.7
                        font.pointSize: PlasmaComponents3.Label.font.pointSize * 0.9
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
