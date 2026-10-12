pragma ComponentBehavior: Bound

// VolumeOsd.qml — left-edge volume OSD: state + glyph only.
//
// The audio data flow is untouched (Pipewire sink binding, step, mute
// toggle); rendering, animation and input live in EdgeOsd, which this file
// feeds state to (value/warn — latest state wins) and reacts to its events.
// The glyph painter lives here: the UI layer owns icon → pixels.

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Scope {
    id: root

    final readonly property real step: 0.05
    property bool suppressed: false       // held off while the screen is locked
    final property PwNode sink: Pipewire.defaultAudioSink
    readonly property real value: sink && sink.audio ? sink.audio.volume : 0
    readonly property bool muted: sink && sink.audio ? sink.audio.muted : false

    PwObjectTracker {
        objects: [root.sink]
    }

    function adjust(direction: int): void {
        if (!sink || !sink.audio)
            return
        sink.audio.volume = Math.max(0, Math.min(1, value + direction * step))
    }

    function toggleMute(): void {
        if (sink && sink.audio)
            sink.audio.muted = !muted
    }

    // ---------- glyph: a curvy horn (every corner rounded, flares bowed) so
    // it matches the widget's curves; red + slashed when muted or at zero ----
    function drawGlyph(ctx, cx: real, cy: real, ink: string, warn: bool): void {
        ctx.fillStyle = ink
        ctx.beginPath()
        ctx.moveTo(cx - 9, cy + 4.5)
        ctx.quadraticCurveTo(cx - 9, cy + 3, cx - 7, cy + 3)         // rounded back corner (top)
        ctx.lineTo(cx - 5.2, cy + 3)
        ctx.quadraticCurveTo(cx - 4, cy + 3, cx - 2.7, cy + 1.5)     // rounded flare junction (top)
        ctx.quadraticCurveTo(cx - 0.2, cy - 1.1, cx + 1.3, cy - 1.9) // top flare bows outward like a horn
        ctx.quadraticCurveTo(cx + 2.5, cy - 2, cx + 2.5, cy - 0.5)   // rounded cone tip (top)
        ctx.lineTo(cx + 2.5, cy + 12.5)                              // cone opening
        ctx.quadraticCurveTo(cx + 2.5, cy + 14, cx + 1.3, cy + 14)   // rounded cone tip (bottom)
        ctx.quadraticCurveTo(cx - 0.2, cy + 13.1, cx - 2.7, cy + 10.5) // bottom flare bows outward
        ctx.quadraticCurveTo(cx - 4, cy + 9, cx - 5.2, cy + 9)       // rounded flare junction (bottom)
        ctx.lineTo(cx - 7, cy + 9)
        ctx.quadraticCurveTo(cx - 9, cy + 9, cx - 9, cy + 7.5)       // rounded back corner (bottom)
        ctx.closePath()
        ctx.fill()

        ctx.strokeStyle = ink
        ctx.lineCap = "round"
        // the sound waves are ALWAYS drawn; muting only adds the slash arc on
        // top, so the glyph keeps its identity instead of losing the waves
        ctx.lineWidth = 1.6
        ctx.beginPath()
        ctx.arc(cx + 4, cy + 6, 3.2, -Math.PI / 3, Math.PI / 3, false)
        ctx.stroke()
        ctx.beginPath()
        ctx.arc(cx + 4, cy + 6, 5.8, -Math.PI / 3, Math.PI / 3, false)
        ctx.stroke()
        if (warn) {
            // mute / zero volume: a swooshing slash arc through the glyph
            // (same motif as the brightness zero slash)
            ctx.lineWidth = 2
            ctx.beginPath()
            ctx.moveTo(cx - 10, cy - 3)
            ctx.quadraticCurveTo(cx, cy + 8.5, cx + 10, cy + 15)
            ctx.stroke()
        }
    }

    Variants {
        model: Quickshell.screens

        EdgeOsd {
            required property ShellScreen modelData
            targetScreen: modelData
            edge: 0
            kind: "osdVolume"
            value: root.value
            warn: root.muted || root.value <= 0.001
            suppressed: root.suppressed
            paintGlyph: root.drawGlyph
            onWheelMoved: direction => root.adjust(direction)
            onActivated: root.toggleMute()
        }
    }
}
