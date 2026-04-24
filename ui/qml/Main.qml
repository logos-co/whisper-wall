import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// WhisperWall — anonymous bidding board UI.
// Expects a `backend` context property of type WhisperWallBackend.

Rectangle {
    id: root
    width: 480
    height: 640
    color: "#0f1117"

    // ── Palette ───────────────────────────────────────────────────────────────
    readonly property color colBg:       "#0f1117"
    readonly property color colSurface:  "#1a1d27"
    readonly property color colBorder:   "#2d3148"
    readonly property color colPrimary:  "#7c6ef5"
    readonly property color colSuccess:  "#3ecf8e"
    readonly property color colWarning:  "#f5a623"
    readonly property color colError:    "#e05252"
    readonly property color colText:     "#e8e9f0"
    readonly property color colMuted:    "#6b7280"
    readonly property int   radius:      12

    // ── Toast notification ────────────────────────────────────────────────────
    Rectangle {
        id: toast
        anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 24 }
        width: toastLabel.implicitWidth + 32
        height: 40
        radius: 20
        color: toastSuccess ? root.colSuccess : root.colError
        opacity: 0
        z: 10

        property bool toastSuccess: true

        Label {
            id: toastLabel
            anchors.centerIn: parent
            color: "#fff"
            font.pixelSize: 13
        }

        SequentialAnimation {
            id: toastAnim
            NumberAnimation { target: toast; property: "opacity"; to: 1; duration: 200 }
            PauseAnimation { duration: 3000 }
            NumberAnimation { target: toast; property: "opacity"; to: 0; duration: 400 }
        }

        function show(msg, success) {
            toast.toastSuccess = success
            toastLabel.text = msg
            toastAnim.restart()
        }
    }

    Connections {
        target: backend
        function onTxSuccess(operation, txHash) {
            toast.show("✓ " + operation + " — " + txHash.substring(0, 12) + "…", true)
        }
        function onTxError(operation, error) {
            toast.show("✗ " + error, false)
        }
    }

    // ── Main layout ───────────────────────────────────────────────────────────
    ColumnLayout {
        anchors { fill: parent; margins: 20 }
        spacing: 16

        // Header
        RowLayout {
            Layout.fillWidth: true
            Label {
                text: "WhisperWall"
                color: root.colPrimary
                font { pixelSize: 22; bold: true }
            }
            Item { Layout.fillWidth: true }
            // Whisper counter badge
            Rectangle {
                width: countLabel.implicitWidth + 16
                height: 26
                radius: 13
                color: root.colSurface
                border.color: root.colBorder
                Label {
                    id: countLabel
                    anchors.centerIn: parent
                    text: backend.whisperCount + " whispers"
                    color: root.colMuted
                    font.pixelSize: 12
                }
            }
        }

        // ── Wall display card ─────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 180
            radius: root.radius
            color: root.colSurface
            border.color: backend.latestWhisper !== "" ? root.colPrimary : root.colBorder
            border.width: backend.latestWhisper !== "" ? 2 : 1

            ColumnLayout {
                anchors { fill: parent; margins: 20 }
                spacing: 8

                Label {
                    text: backend.wallExists ? "Current whisper" : "Wall not initialized"
                    color: root.colMuted
                    font.pixelSize: 11
                    font.uppercase: true
                    font.letterSpacing: 1
                }

                Label {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    text: backend.latestWhisper !== "" ? backend.latestWhisper
                                                       : "— empty wall —"
                    color: backend.latestWhisper !== "" ? root.colText : root.colMuted
                    font { pixelSize: backend.latestWhisper !== "" ? 20 : 16; italic: backend.latestWhisper === "" }
                    wrapMode: Text.WordWrap
                    verticalAlignment: Text.AlignVCenter
                }

                RowLayout {
                    spacing: 12
                    visible: backend.wallExists
                    Label {
                        text: "Last tip"
                        color: root.colMuted
                        font.pixelSize: 12
                    }
                    Rectangle {
                        width: tipValueLabel.implicitWidth + 12
                        height: 22
                        radius: 4
                        color: root.colWarning + "33"
                        border.color: root.colWarning + "88"
                        Label {
                            id: tipValueLabel
                            anchors.centerIn: parent
                            text: backend.lastTip + " tokens"
                            color: root.colWarning
                            font { pixelSize: 12; bold: true }
                        }
                    }
                }
            }
        }

        // ── Action panel ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: actionColumn.implicitHeight + 32
            radius: root.radius
            color: root.colSurface
            border.color: root.colBorder

            ColumnLayout {
                id: actionColumn
                anchors { fill: parent; margins: 16 }
                spacing: 12

                // Tab selector: Whisper / Overwrite / Admin
                RowLayout {
                    spacing: 8
                    Repeater {
                        model: ["Whisper", "Overwrite", "Admin"]
                        delegate: Rectangle {
                            width: tabLabel.implicitWidth + 20
                            height: 30
                            radius: 6
                            color: actionTabs.currentIndex === index ? root.colPrimary : "transparent"
                            border.color: actionTabs.currentIndex === index ? "transparent" : root.colBorder

                            Label {
                                id: tabLabel
                                anchors.centerIn: parent
                                text: modelData
                                color: actionTabs.currentIndex === index ? "#fff" : root.colMuted
                                font.pixelSize: 13
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: actionTabs.currentIndex = index
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }

                StackLayout {
                    id: actionTabs
                    Layout.fillWidth: true
                    currentIndex: 0

                    // ── Whisper (free, wall must be empty) ────────────────────
                    ColumnLayout {
                        spacing: 10
                        Label {
                            text: backend.latestWhisper === ""
                                ? "Wall is empty — be the first to whisper."
                                : "Wall already has a message. Use Overwrite to replace it."
                            color: root.colMuted
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                        WwTextField { id: whisperSigner;  placeholderText: "Your account ID (Public/...)" }
                        WwTextField { id: whisperMsg;     placeholderText: "Your whisper…" }
                        WwButton {
                            text: "Whisper"
                            accent: true
                            enabled: !backend.busy && whisperSigner.text !== "" && whisperMsg.text !== "" && backend.latestWhisper === ""
                            onClicked: backend.whisper(whisperSigner.text.trim(), whisperMsg.text.trim())
                        }
                    }

                    // ── Overwrite (paid, tip must exceed last_tip) ────────────
                    ColumnLayout {
                        spacing: 10
                        Label {
                            text: "Tip must exceed " + backend.lastTip + " to overwrite."
                            color: root.colMuted
                            font.pixelSize: 12
                            Layout.fillWidth: true
                        }
                        WwTextField { id: overwriteSigner; placeholderText: "Your account ID (Public/... or Private/...)" }
                        WwTextField { id: overwriteMsg;    placeholderText: "New message…" }
                        WwTextField {
                            id: overwriteTip
                            placeholderText: "Tip amount (tokens)"
                            inputMethodHints: Qt.ImhDigitsOnly
                        }
                        WwButton {
                            text: "Overwrite"
                            accent: true
                            enabled: !backend.busy && overwriteSigner.text !== "" && overwriteMsg.text !== "" && overwriteTip.text !== ""
                            onClicked: backend.overwrite(
                                overwriteSigner.text.trim(),
                                overwriteMsg.text.trim(),
                                overwriteTip.text.trim())
                        }
                    }

                    // ── Admin panel ───────────────────────────────────────────
                    ColumnLayout {
                        spacing: 10
                        Label {
                            text: "Admin operations (requires admin account)."
                            color: root.colMuted
                            font.pixelSize: 12
                            Layout.fillWidth: true
                        }

                        // Initialize
                        Label { text: "Initialize wall"; color: root.colText; font.pixelSize: 13 }
                        WwTextField { id: initAdmin; placeholderText: "Admin account ID" }
                        WwButton {
                            text: "Initialize"
                            enabled: !backend.busy && initAdmin.text !== ""
                            onClicked: backend.initialize(initAdmin.text.trim())
                        }

                        Rectangle { height: 1; Layout.fillWidth: true; color: root.colBorder }

                        // Drain jar
                        Label { text: "Drain jar"; color: root.colText; font.pixelSize: 13 }
                        WwTextField { id: drainAdmin;     placeholderText: "Admin account ID" }
                        WwTextField { id: drainRecipient; placeholderText: "Recipient account ID" }
                        WwButton {
                            text: "Drain"
                            enabled: !backend.busy && drainAdmin.text !== "" && drainRecipient.text !== ""
                            onClicked: backend.drainJar(drainAdmin.text.trim(), drainRecipient.text.trim())
                        }
                    }
                }
            }
        }

        // ── Status bar ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: backend.busy || backend.lastError !== "" || backend.lastTxHash !== ""

            BusyIndicator {
                width: 20; height: 20
                running: backend.busy
                visible: backend.busy
                palette.dark: root.colPrimary
            }

            Label {
                text: backend.busy      ? "Submitting…"
                    : backend.lastError !== "" ? "Error: " + backend.lastError
                    : "OK — " + backend.lastTxHash.substring(0, 16) + "…"
                color: backend.lastError !== "" ? root.colError : root.colMuted
                font.pixelSize: 12
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            // Refresh button
            Rectangle {
                width: 28; height: 28
                radius: 6
                color: "transparent"
                border.color: root.colBorder
                Label {
                    anchors.centerIn: parent
                    text: "↻"
                    color: root.colMuted
                    font.pixelSize: 16
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: backend.refreshState()
                    cursorShape: Qt.PointingHandCursor
                }
            }
        }

        Item { Layout.fillHeight: true }
    }

    // ── Shared component definitions ──────────────────────────────────────────

    component WwTextField: TextField {
        Layout.fillWidth: true
        color: root.colText
        placeholderTextColor: root.colMuted
        font.pixelSize: 14
        leftPadding: 12
        rightPadding: 12
        background: Rectangle {
            radius: 8
            color: root.colBg
            border.color: parent.activeFocus ? root.colPrimary : root.colBorder
            border.width: parent.activeFocus ? 2 : 1
        }
    }

    component WwButton: Rectangle {
        id: btn
        Layout.fillWidth: true
        height: 40
        radius: 8
        property string text: ""
        property bool accent: false
        property bool enabled: true
        signal clicked

        color: !enabled       ? root.colBorder
             : accent         ? root.colPrimary
                              : root.colSurface
        border.color: accent || !enabled ? "transparent" : root.colBorder

        Behavior on color { ColorAnimation { duration: 100 } }

        Label {
            anchors.centerIn: parent
            text: btn.text
            color: btn.enabled ? "#fff" : root.colMuted
            font { pixelSize: 14; bold: btn.accent }
        }

        MouseArea {
            anchors.fill: parent
            enabled: btn.enabled
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (btn.enabled) btn.clicked()
        }
    }
}
