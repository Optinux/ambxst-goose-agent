import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.config
import qs.modules.components
import qs.modules.services
import qs.modules.theme

StyledRect {
    id: root
    variant: "internalbg"
    radius: Styling.radius(4)

    implicitHeight: contentCol.implicitHeight + 16
    Layout.fillWidth: true
    Layout.preferredHeight: implicitHeight
    Layout.alignment: Qt.AlignTop

    ColumnLayout {
        id: contentCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Image {
                source: GooseAgentService.iconPath
                sourceSize: Qt.size(16, 16)
                width: 16
                height: 16
                smooth: true
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1

                Text {
                    text: GooseAgentService.running
                        ? GooseAgentService.currentStatus
                        : (GooseContextService.summaryLabel || "Goose Desktop Context Ready")
                    color: Colors.overBackground
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    font.weight: Font.Medium
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }

                Text {
                    visible: GooseAgentService.currentCommand.length > 0
                    text: "$ " + GooseAgentService.currentCommand
                    color: Colors.primary
                    font.family: "monospace"
                    font.pixelSize: Styling.fontSize(-2)
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            // Live active-workspace / total open-window badge (click to force refresh)
            StyledRect {
                variant: "common"
                radius: Styling.radius(2)
                visible: !GooseAgentService.running
                implicitWidth: winCountText.implicitWidth + 10
                implicitHeight: 22

                Text {
                    id: winCountText
                    anchors.centerIn: parent
                    text: GooseContextService.activeWorkspaceWindowCount + "/" + GooseContextService.windowCount + " win"
                    color: Colors.overSurfaceVariant
                    font.family: "monospace"
                    font.pixelSize: Styling.fontSize(-2)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: GooseContextService.captureSnapshot()
                }
            }

            // One-click screenshot button for vision analysis
            StyledRect {
                variant: GooseAgentService.pendingScreenshotPath.length > 0 ? "focus" : "common"
                radius: Styling.radius(2)
                visible: !GooseAgentService.running
                implicitWidth: shotLabel.implicitWidth + 12
                implicitHeight: 22

                Text {
                    id: shotLabel
                    anchors.centerIn: parent
                    text: GooseAgentService.capturingScreenshot
                        ? "..."
                        : (GooseAgentService.pendingScreenshotPath.length > 0 ? "Shot ✓" : "Shot")
                    color: GooseAgentService.pendingScreenshotPath.length > 0 ? Colors.primary : Colors.overSurface
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    font.weight: Font.Medium
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: GooseAgentService.captureScreenshot()
                }
            }

            // Step counter chip while/after running
            StyledRect {
                variant: "common"
                radius: Styling.radius(2)
                visible: GooseAgentService.totalSteps > 0
                implicitWidth: stepCountText.implicitWidth + 10
                implicitHeight: 22

                Text {
                    id: stepCountText
                    anchors.centerIn: parent
                    text: GooseAgentService.completedSteps + "/" + GooseAgentService.totalSteps
                    color: Colors.overSurfaceVariant
                    font.family: "monospace"
                    font.pixelSize: Styling.fontSize(-2)
                }
            }

            // Stop button while running
            StyledRect {
                variant: "focus"
                radius: Styling.radius(2)
                visible: GooseAgentService.running
                implicitWidth: stopLabel.implicitWidth + 12
                implicitHeight: 22

                Text {
                    id: stopLabel
                    anchors.centerIn: parent
                    text: "Stop"
                    color: Colors.error
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: GooseAgentService.stop()
                }
            }
        }

        // Attached screenshot thumbnail preview strip
        StyledRect {
            variant: "common"
            radius: Styling.radius(2)
            visible: GooseAgentService.pendingScreenshotPath.length > 0
            Layout.fillWidth: true
            implicitHeight: shotRow.implicitHeight + 8

            RowLayout {
                id: shotRow
                anchors.fill: parent
                anchors.margins: 4
                spacing: 8

                Image {
                    source: GooseAgentService.pendingScreenshotPath.length > 0
                        ? ("file://" + GooseAgentService.pendingScreenshotPath)
                        : ""
                    cache: false
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(96, 54)
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 32
                    smooth: true
                }

                Text {
                    text: "Screenshot attached for vision"
                    color: Colors.overSurface
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                StyledRect {
                    variant: "internalbg"
                    radius: Styling.radius(2)
                    implicitWidth: 20
                    implicitHeight: 20

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: Colors.overSurfaceVariant
                        font.pixelSize: Styling.fontSize(-2)
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: GooseAgentService.clearScreenshot()
                    }
                }
            }
        }

        // Screenshot error banner (if grim is missing)
        Text {
            visible: GooseAgentService.screenshotError.length > 0
            text: GooseAgentService.screenshotError
            color: Colors.error
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-2)
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        // Progress bar
        Rectangle {
            Layout.fillWidth: true
            height: 3
            radius: 2
            visible: GooseAgentService.running || GooseAgentService.totalSteps > 0
            color: Qt.rgba(1, 1, 1, 0.12)
            clip: true

            Rectangle {
                id: progressFill
                height: parent.height
                radius: 2
                color: GooseAgentService.lastError ? Colors.error : Colors.primary
                width: GooseAgentService.progress >= 0
                    ? parent.width * Math.min(1, GooseAgentService.progress)
                    : parent.width * 0.35
                x: 0

                SequentialAnimation on x {
                    running: GooseAgentService.running && GooseAgentService.progress < 0
                    loops: Animation.Infinite
                    NumberAnimation {
                        from: -progressFill.width
                        to: progressFill.parent.width
                        duration: 1100
                        easing.type: Easing.InOutQuad
                    }
                }

                Behavior on width {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }
            }
        }

        // Scrollable live command log
        Flickable {
            visible: GooseAgentService.stepsModel.count > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(stepsCol.implicitHeight, 180)
            contentWidth: width
            contentHeight: stepsCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: stepsCol
                width: parent.width
                spacing: 4

                Repeater {
                    model: GooseAgentService.stepsModel

                    delegate: StyledRect {
                        id: stepCard
                        variant: "common"
                        radius: Styling.radius(2)
                        Layout.fillWidth: true
                        implicitHeight: stepCol.implicitHeight + 8

                        property bool expanded: false

                        ColumnLayout {
                            id: stepCol
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 3

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    text: model.status === "done" ? "✓"
                                        : (model.status === "error" ? "✕" : "◌")
                                    color: model.status === "done" ? Colors.primary
                                        : (model.status === "error" ? Colors.error : Colors.secondary)
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Bold
                                }

                                Text {
                                    text: model.commandText
                                    color: Colors.overSurface
                                    font.family: "monospace"
                                    font.pixelSize: Styling.fontSize(-2)
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }

                            Text {
                                visible: stepCard.expanded && model.outputPreview.length > 0
                                text: model.outputPreview
                                color: Colors.overSurfaceVariant
                                font.family: "monospace"
                                font.pixelSize: Styling.fontSize(-3)
                                wrapMode: Text.WrapAnywhere
                                Layout.fillWidth: true
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: stepCard.expanded = !stepCard.expanded
                        }
                    }
                }
            }
        }
    }
}
