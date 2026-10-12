pragma ComponentBehavior: Bound

// BrightnessOsd.qml — right-edge brightness OSD: state + glyph only.
//
// The brightness data flow is untouched (Backend.brightness, changeBrightness,
// toggleBrightness); rendering, animation and input live in EdgeOsd, which
// this file feeds state to (value/warn — latest state wins) and reacts to its
// events. The glyph painter lives here: the UI layer owns icon → pixels.

import QtQuick
import Quickshell
import qs.Shell.Backend

Scope {
    id: root

    final readonly property real step: 0.05
    property bool suppressed: false       // held off while the screen is locked
    readonly property real value: Backend.brightness
    readonly property bool warn: value <= 0.001

    function adjust(direction: int): void {
        Backend.changeBrightness(direction)
    }

    function toggle(): void {
        Backend.toggleBrightness()
    }

    // ---------- glyph: sun disc with short round-capped rays, matching the
    // volume OSD's glyph slot (curvy, every edge soft); red with the swooshing
    // slash when the screen is at zero brightness ----
    function drawGlyph(ctx, cx: real, cy: real, ink: string, warn: bool): void {
        ctx.fillStyle = ink
        ctx.beginPath()
        ctx.arc(cx, cy + 6, 4.5, 0, Math.PI * 2, false)
        ctx.fill()

        ctx.strokeStyle = ink
        ctx.lineCap = "round"
        if (warn) {
            // zero brightness: the rays are replaced by one swooshing slash
            // arc through the glyph — the same motif as the mute slash
            ctx.lineWidth = 2
            ctx.beginPath()
            ctx.moveTo(cx - 10, cy - 3)
            ctx.quadraticCurveTo(cx, cy + 8.5, cx + 10, cy + 15)
            ctx.stroke()
        } else {
            ctx.lineWidth = 1.6
            for (let i = 0; i < 8; i++) {
                const a = i * Math.PI / 4
                const rx1 = cx + 6.6 * Math.cos(a)
                const ry1 = cy + 6 + 6.6 * Math.sin(a)
                const rx2 = cx + 9.2 * Math.cos(a)
                const ry2 = cy + 6 + 9.2 * Math.sin(a)
                ctx.beginPath()
                ctx.moveTo(rx1, ry1)
                ctx.lineTo(rx2, ry2)
                ctx.stroke()
            }
        }
    }

    Variants {
        model: Quickshell.screens

        EdgeOsd {
            required property ShellScreen modelData
            targetScreen: modelData
            edge: 1
            kind: "osdBrightness"
            value: root.value
            warn: root.warn
            suppressed: root.suppressed
            paintGlyph: root.drawGlyph
            onWheelMoved: direction => root.adjust(direction)
            onActivated: root.toggle()
        }
    }

}
