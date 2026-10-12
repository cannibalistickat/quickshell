pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Shell.Backend

Scope {
    id: root

    final readonly property url topWallpaper: "file:///home/alice/Pictures/Wallpapers/Claret.png"
    final readonly property url bottomWallpaper: "file:///home/alice/Pictures/Wallpapers/Claret2.png"
    final readonly property real lightRadius: 200
    final readonly property real maxZoom: 4
    final readonly property real zoomStep: 0.25
    final readonly property real maxPanPixels: 20

    Variants {
        model: Quickshell.screens

        Scope {
            id: monitor
            required property ShellScreen modelData
            property real zoom: 1

            Behavior on zoom {
                NumberAnimation {
                    duration: 200
                    easing.type: Easing.OutCubic
                }
            }

            readonly property real cursorX: Backend.cursorX - modelData.x
            readonly property real cursorY: Backend.cursorY - modelData.y
            readonly property point cursorUv: Qt.point(
                Math.max(0, Math.min(1, cursorX / modelData.width)),
                Math.max(0, Math.min(1, cursorY / modelData.height)))

            PanelWindow {
                id: surface
                screen: monitor.modelData

                WlrLayershell.layer: WlrLayer.Background
                WlrLayershell.namespace: "quickshell:wallpapers"
                exclusionMode: ExclusionMode.Ignore
                surfaceFormat.opaque: true
                color: "transparent"

                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }

                Image {
                    id: bottom
                    anchors.fill: parent
                    source: root.bottomWallpaper
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(
                        Math.round(width * surface.devicePixelRatio),
                        Math.round(height * surface.devicePixelRatio))
                }

                Image {
                    id: top
                    anchors.fill: parent
                    source: root.topWallpaper
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(
                        Math.round(width * surface.devicePixelRatio),
                        Math.round(height * surface.devicePixelRatio))
                }

                ShaderEffect {
                    anchors.fill: parent
                    blending: false

                    final property variant texBottom: bottom
                    final property variant texTop: top
                    final property vector2d uCursor: Qt.vector2d(
                        monitor.cursorUv.x,
                        monitor.cursorUv.y)
                    final property vector2d uSize: Qt.vector2d(width, height)
                    final property real uRadius: root.lightRadius
                    final property real uZoom: monitor.zoom
                    final property vector2d uPanOffset: Qt.vector2d(
                        ((monitor.cursorUv.x - 0.5) * 2 / monitor.modelData.width) * root.maxPanPixels,
                        ((monitor.cursorUv.y - 0.5) * 2 / monitor.modelData.height) * root.maxPanPixels)
                    final property vector2d uPanReserve: Qt.vector2d(
                        Math.max(0.001, 1 - (2 * root.maxPanPixels / Math.max(1, width))),
                        Math.max(0.001, 1 - (2 * root.maxPanPixels / Math.max(1, height))))
                    final property real uInvZoom: 1 / Math.max(1, uZoom)
                    final property vector2d uBottomScale: Qt.vector2d(
                        bottom.paintedWidth > 0
                            ? Math.min(1, width / bottom.paintedWidth)
                            : 1,
                        bottom.paintedHeight > 0
                            ? Math.min(1, height / bottom.paintedHeight)
                            : 1)
                    final property vector2d uTopScale: Qt.vector2d(
                        top.paintedWidth > 0
                            ? Math.min(1, width / top.paintedWidth)
                            : 1,
                        top.paintedHeight > 0
                            ? Math.min(1, height / top.paintedHeight)
                            : 1)

                    fragmentShader: Qt.resolvedUrl("shaders/flashlight.frag.qsb")
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: event => {
                        const notches = event.angleDelta.y / 120
                        monitor.zoom = Math.max(
                            1,
                            Math.min(
                                root.maxZoom,
                                monitor.zoom + notches * root.zoomStep))
                        event.accepted = true
                    }
                }
            }
        }
    }
}
