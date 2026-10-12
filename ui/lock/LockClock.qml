pragma ComponentBehavior: Bound
// LockClock.qml — the red LED clock from the poo/ art: clock.png case with
// DotMatrix digits laid over the face, tilted like the web original
// (perspective rotateX 11 / rotateY -10 / rotateZ -3).

import QtQuick

Item {
    id: root

    property string timeText: "--:--"

    FontLoader { id: dotMatrix; source: "assets/font/LED Dot-Matrix.ttf" }

    Image {
        id: shell
        anchors.fill: parent
        source: "assets/img/clock.png"
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: true
        mipmap: true
    }

    // The clock art already has its perspective BAKED IN: the navy face is drawn
    // angled — tilted ~5 deg (right side up) and seen slightly from above. A flat
    // 2D text can't sit on that projective plane if we ALSO 3D-tilt the whole
    // item (that double-tilted the art and left the text on a different, flat
    // plane — the "weird" look). So we leave the art as drawn and rotate ONLY the
    // digits onto the face: a small lean-back (rotateX) + the face's in-plane tilt
    // (rotateZ), both pivoting about the navy-face centroid (ox, oy).
    Item {
        id: screen
        anchors.fill: parent
        readonly property real ox: width * 0.508     // navy-face centroid x
        readonly property real oy: height * 0.575    // navy-face centroid y (below centre)

        Text {
            id: digits
            anchors.centerIn: parent
            anchors.verticalCenterOffset: parent.height * 0.075
            anchors.horizontalCenterOffset: -parent.width * 0.02
            font.family: dotMatrix.name
            font.pixelSize: root.height * 0.44
            color: "#e4e27e"
            text: root.timeText
            // soft phosphor breathing like the web original
            SequentialAnimation on opacity {
                running: true; loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 0.94; duration: 900 }
                NumberAnimation { from: 0.94; to: 1.0; duration: 1100 }
            }
        }
        Text {
            anchors.centerIn: digits
            font.family: dotMatrix.name
            font.pixelSize: root.height * 0.44
            color: "#e4e27e"
            opacity: 0.25
            scale: 1.04
            text: digits.text
        }

        transform: [
            Rotation { origin.x: screen.ox; origin.y: screen.oy; axis.x: 1; axis.y: 0; axis.z: 0; angle: 9 },
            Rotation { origin.x: screen.ox; origin.y: screen.oy; axis.x: 0; axis.y: 0; axis.z: 1; angle: -5 }
        ]
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: root.timeText = Qt.formatTime(new Date(), "HH:mm")
    }
}
