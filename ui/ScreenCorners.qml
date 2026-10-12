pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

Scope {
    id: root

    final readonly property int radius: 23

    component CornerGraphic: Shape {
        required property int corner
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            id: path
            strokeWidth: 0
            fillColor: "#000000"
            pathHints: ShapePath.PathSolid | ShapePath.PathNonIntersecting
            startX: (corner & Edges.Left) ? 0 : root.radius
            startY: (corner & Edges.Top) ? 0 : root.radius

            PathAngleArc {
                moveToStart: false
                centerX: root.radius - path.startX
                centerY: root.radius - path.startY
                radiusX: root.radius
                radiusY: root.radius
                startAngle:
                    corner === (Edges.Top | Edges.Left) ? 180
                    : corner === (Edges.Top | Edges.Right) ? -90
                    : corner === (Edges.Bottom | Edges.Left) ? 90
                    : 0
                sweepAngle: 90
            }

            PathLine { x: path.startX; y: path.startY }
        }
    }

    component CornerWindow: PanelWindow {
        required property ShellScreen targetScreen
        required property int corner
        required property bool fullscreen

        id: cornerWindow
        screen: targetScreen
        visible: !fullscreen
        exclusionMode: ExclusionMode.Ignore
        mask: Region { item: null }
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:screenCorners"

        anchors {
            top: (corner & Edges.Top) !== 0
            bottom: (corner & Edges.Bottom) !== 0
            left: (corner & Edges.Left) !== 0
            right: (corner & Edges.Right) !== 0
        }

        implicitWidth: root.radius
        implicitHeight: root.radius

        CornerGraphic { corner: cornerWindow.corner }
    }

    QtObject {
        id: fullscreenState
        property int generation: 0
    }

    Variants {
        model: ToplevelManager.toplevels.values

        Connections {
            required property Toplevel modelData
            target: modelData
            function onFullscreenChanged(): void { fullscreenState.generation++ }
            function onScreensChanged(): void { fullscreenState.generation++ }
        }
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: screenState
            required property ShellScreen modelData

            readonly property bool fullscreen: {
                fullscreenState.generation
                const windows = ToplevelManager.toplevels.values
                for (const window of windows) {
                    if (window.fullscreen
                        && (window.screens.length === 0 || window.screens.includes(screenState.modelData)))
                        return true
                }
                return false
            }

            CornerWindow { targetScreen: screenState.modelData; corner: Edges.Top | Edges.Left; fullscreen: screenState.fullscreen }
            CornerWindow { targetScreen: screenState.modelData; corner: Edges.Top | Edges.Right; fullscreen: screenState.fullscreen }
            CornerWindow { targetScreen: screenState.modelData; corner: Edges.Bottom | Edges.Left; fullscreen: screenState.fullscreen }
            CornerWindow { targetScreen: screenState.modelData; corner: Edges.Bottom | Edges.Right; fullscreen: screenState.fullscreen }
        }
    }
}
