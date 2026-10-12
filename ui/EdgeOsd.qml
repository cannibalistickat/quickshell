pragma ComponentBehavior: Bound

// EdgeOsd.qml — the ONE edge-OSD renderer (v4 visual style from the design
// spec's OsdSurface.qml), vertically centered on its screen edge.
//
// Data flow is unchanged from the previous version: the services (VolumeOsd,
// BrightnessOsd) still feed value/warn and still receive wheelMoved /
// activated, and the show/hide trigger still consumes Backend cursor
// notifications — presentation and trigger POLICY only live here: the OSD
// arms on active motion toward its edge (not mere presence), and the pill
// expands only under direct hover over its own footprint.
//
// Renderer: ONE scene-graph Shape node (CurveRenderer) drawing mound, pill
// and fill as four stacked ShapePaths — a single render batch whose
// distance-field AA is computed in one pass, so boundaries between rim,
// capsule and fill cannot seam (separate Shape items antialias against
// different buffers — that is where hairlines come from). Path properties
// are driven directly by animated state: the scene graph re-tessellates per
// frame with no repaint step, no JS per frame, and zero idle cost (the old
// shader redrew the whole surface every cursor tick). The fill swap variants
// gate on fill color (ShapePath has no visibility flag in this Qt), so the
// hidden one rasterizes nothing. Only the glyph is painterly:
// a tiny 24×22 Canvas that repaints solely when the ink color flips (a warn
// change — an event, never an animation tick).
//
// Geometry doctrine (from the spec):
//   - Minimal anchor set: one edge anchor = vertically centered. The window
//     never moves during value transitions (the old per-cursor margins.top
//     reposition was a Wayland surface resize per mouse-motion — gone).
//   - Window frozen at the EXPANDED size: animations happen inside the
//     frozen canvas, never as surface resizes.
//   - Edge-local drawing mirrored in one transform: every shape is written
//     with x = 0 at the screen edge; for the right edge a Scale flip maps
//     edge-local x to window x, so the mound hugs the right edge and the
//     pill grows leftward into the screen — one transform, zero re-derived
//     geometry.
//   - The bloom: on show, a dot at the edge's vertical center stretches up
//     and down (yScale), the width fill rides along quietly. Hide is EXACTLY
//     that played backwards — same durations, reversed targets, mirrored
//     easing (OutQuint rewound is InQuint), the opacity fade covering the
//     tail as the appear fade covers the head.
//   - Edge attachment: the mound's edge-side anchors sit OVERHANGING past
//     the surface boundary (x = -edgeOh, clipped away by the window). A
//     distance field cannot reach 100% coverage in the ~1px inside its own
//     outline, so a path boundary welded exactly at x = 0 paints a 1px
//     translucent column — and the bloom's xScale slide makes it flicker
//     like a sliver detaching from the edge. With the overhang the visible
//     edge column is deep interior at every animated frame; nothing ever
//     touches the clip boundary. (No x drift either: fractional art.x would
//     resample the whole field off the edge for the same tear.)
//   - Map settle: the sliver no transform can cause. The spec mapped its
//     surface ONCE precisely because a fresh Wayland layer surface takes a
//     frame or two to settle into place — blooming during that race shows a
//     1px gap that snaps, and it is the SURFACE moving, so no art-side fix
//     touches it. Mapping here is on demand (an always-live surface would
//     swallow edge clicks), so the bloom waits one settle tick after a
//     fresh map: the placement race runs while the art is still opacity 0.
//   - Surface namespace "quickshell:<kind>": the dedicated Hyprland
//     layerrule (no_anim/blur off — compositor must not double-animate what
//     QML already owns) matches on precisely these names.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Shell.Backend

PanelWindow {
    id: root

    required property ShellScreen targetScreen
    required property int edge
    required property string kind
    required property real value
    required property bool warn
    // Glyph hook — the service's painter: (ctx, cx, cy, ink, warn). The
    // shared code provides the slot, the ink color and the expand fade.
    property var paintGlyph: null

    signal wheelMoved(int direction)
    signal activated()

    final readonly property int leftEdge: 0
    final readonly property int rightEdge: 1
    final readonly property bool isLeft: edge === leftEdge

    // ---------- trigger / lifecycle ----------
    // The OSD must not pop up from mere presence at the edge (parked cursor,
    // corner grabs) — it arms only on cursor MOTION toward this edge inside
    // the approach band. Backend already dedupes and sends ONE notify per
    // real change, so every localCursorX delta IS movement: direction test
    // + latch, no polling, no timers on the hot path.
    final readonly property int hideDelay: 2000

    readonly property real localCursorX: Backend.cursorX - targetScreen.x
    readonly property real localCursorY: Backend.cursorY - targetScreen.y
    readonly property bool cursorInside:
        Backend.cursorValid
        && localCursorX >= 0
        && localCursorX <= targetScreen.width
        && localCursorY >= 0
        && localCursorY <= targetScreen.height
    // approach band = the window's own depth from the screen edge (~100px,
    // well before the 65px pill footprint becomes reachable)
    readonly property bool inEdgeBand:
        cursorInside
        && (isLeft
            ? localCursorX <= triggerW
            : localCursorX >= targetScreen.width - triggerW)
    property real cursorXPrev: 0        // previous x, for the direction test
    property bool motionArmed: false    // latched by a flick toward the edge
    property bool suppressed: false     // held off by an external owner (lock screen)

    // Two independent reveal reasons, split so a fullscreen game can't be
    // peeked at by accident yet still answers its keybinds:
    //   * MOTION / hover  — suppressed while this screen runs a fullscreen
    //     window, so a game's edge-hugging cursor can neither summon nor
    //     expand the OSD.
    //   * a value CHANGE (the pulse) — always allowed, even in fullscreen, so
    //     a brightness/volume keypress still pops the idle pill.
    // A plain binding tracks the Hyprland monitor -> activeWorkspace ->
    // hasFullscreen chain (all NOTIFY-backed Q_PROPERTYs), so `fullscreen`
    // flips the instant a client on this screen's active workspace enters or
    // leaves fullscreen — no polling, no QsProperty.
    readonly property bool fullscreen: {
        const mon = Hyprland.monitorFor(targetScreen)
        const ws = mon ? mon.activeWorkspace : null
        return ws ? ws.hasFullscreen : false
    }

    readonly property bool held: !suppressed
        && (pulseHold
            || (!fullscreen && ((motionArmed && inEdgeBand) || hover.containsMouse)))
    property bool shown: false

    // Pulse: a value/warn change forces the idle OSD on screen. Short coalesce
    // hold (a held key fires many changes) + the normal hideDelay tail, so it
    // lingers ~hideDelay after the LAST change then blooms away. primed ignores
    // the initial value binding wired at startup.
    property bool primed: false
    property bool pulseHold: false
    function pulse(): void {
        if (!primed)
            return
        pulseHold = true
        pulseTimer.restart()
    }
    onValueChanged: pulse()
    onWarnChanged: pulse()

    Timer {
        id: pulseTimer
        interval: 400
        repeat: false
        onTriggered: root.pulseHold = false
    }

    onLocalCursorXChanged: {
        const from = cursorXPrev
        cursorXPrev = localCursorX
        if (!cursorInside)
            return                     // another screen: keep prev fresh, no verdict
        const towardEdge = isLeft ? localCursorX < from : localCursorX > from
        if (towardEdge && inEdgeBand && !fullscreen)
            motionArmed = true         // active flick into the band: arm and show
        else if (!inEdgeBand || fullscreen)
            motionArmed = false        // left the band, or went fullscreen: disarm
    }

    // ---------- tunables — THE one copy (services must not redeclare) ----------
    final readonly property int triggerW: 200      // motion-arming band depth (read from the Backend cursor, NOT the surface) — a flick registers well before the pill is reachable
    final readonly property int osdW: 71           // pill slot: expanded pill + outline (pillLeft 8 + cardW 57 + outlineW 6)
    final readonly property int hitW: osdW + 4     // SURFACE width = only the expanded pill's footprint (+4px clip guard). Was triggerW, whose ~200px-wide invisible hitbox swallowed clicks/scroll on any window beside the edge while the OSD was shown.
    final readonly property real edgeOh: 6         // overhang: the mound's edge-side anchors sit this far PAST the screen edge (clipped) so the surface's first pixel column is always deep interior — see the attachment doctrine above
    final readonly property int pillH: 264         // pill height — constant; centered on screen
    final readonly property int osdH: pillH + 2 * Math.ceil(outlineW + (pillLeft + cardW / 2) * bowAspect)  // window height — FROZEN at the expanded size
    final readonly property int pillLeft: 8        // pill's offset from the screen edge — it grows inward on hover
    final readonly property int barW: 18           // pill width when idle (skinny capsule)
    final readonly property int cardW: 57          // pill width when hovered
    final readonly property real outlineW: 6       // black outline around the pill
    final readonly property int pillInset: 1       // pill drawn this many px inside its outline slot
    final readonly property real bowAspect: 1.2    // swoosh drop per px of landing span — THE curve knob
    final readonly property string pillFill: "#3b3d42"   // pill interior (dark gray)
    final readonly property string fillInk: "#f4f4f6"    // fill indicator (white)
    final readonly property string iconRed: "#c3204f"    // glyph ink when warning

    // ---------- animated state ----------
    // expand: 0 = skinny pill, 1 = expanded pill — the only property the
    // hover animation touches; every geometry below is a pure binding.
    final property real expand: 0
    // A hover-leave that lands WHILE the pill is still opening must not reverse
    // mid-flight (that freezes it half-open on a fast flick) — this latches the
    // leave so expandAnim reaches full width first, then collapses.
    property bool pendingCollapse: false
    // dispFill glides toward value — latest-state-wins: rapid pushes (40→45→
    // 50) animate once toward the newest truth, never queue per notch.
    final property real dispFill: value
    Behavior on dispFill {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }

    final readonly property real pillW: barW + (cardW - barW) * expand
    final readonly property real moundH: outlineW + (pillLeft + pillW / 2) * bowAspect
    final readonly property real restXScale: 0.9          // width fills in as subtle secondary motion
    // Hidden y scale: an epsilon, never 0 — a zero-scale transform matrix is
    // non-invertible, and Qt renders the fold as a smeared 1px line.
    final readonly property real restYScale: 0.0001

    // ---------- frozen-window geometry (edge-local: x = 0 is the screen edge) ----------
    final readonly property real wy0: (osdH - pillH) / 2        // pill top — fixed, centered
    final readonly property real wy1: wy0 + pillH               // pill bottom
    final readonly property real wSy: Math.max(0, wy0 - moundH) // fin spring point on the screen edge
    final readonly property real wDrop: wy0 - outlineW - wSy    // swoosh drop: edge spring down to the lip
    // fixed handle factors render the idle and expanded swooshes as the EXACT
    // same profile — no per-state easing needed
    final readonly property real wC1y: wSy + wDrop * 0.10
    final readonly property real wC2x: (pillLeft + pillW / 2) * 0.18
    // the pill's inner slot (white fill + hairline seal live here)
    final readonly property real gx: pillLeft + pillInset
    final readonly property real gy: wy0 + pillInset
    final readonly property real gw: pillW - 2 * pillInset      // animates with expand
    final readonly property real gh: pillH - 2 * pillInset
    final readonly property real gr: gw / 2                     // true capsule radius at every width
    // the white fill: height gh·dispFill rising from the pill's bottom
    final readonly property real fillH: gh * Math.max(0, Math.min(1, dispFill))
    final readonly property real fillTop: gy + gh - fillH
    final readonly property real capCx: gx + gw / 2
    final readonly property real capCy: gy + gh - gr
    // chord half-width of the fill's top edge on the bottom cap
    final readonly property real fillDx: Math.sqrt(Math.max(0,
            gr * gr - Math.max(0, fillTop - capCy) * Math.max(0, fillTop - capCy)))
    // glyph ink — flips only on warn changes (the one glyph repaint trigger)
    final readonly property color glyphInk: warn ? iconRed : "#17181d"
    // expansion fires ONLY over the pill's own footprint — osdW deep at the
    // edge and pillH tall — not anywhere in the wider approach band
    readonly property bool pillHovered: !fullscreen
        && hover.containsMouse
        && hover.mouseY >= wy0 && hover.mouseY <= wy1
        && (isLeft ? hover.mouseX <= osdW : hover.mouseX >= width - osdW)

    // ---------- surface ----------
    screen: targetScreen
    visible: shown
    exclusionMode: ExclusionMode.Ignore
    focusable: false
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell:" + kind   // matches the dedicated Hyprland layerrule

    anchors {
        left: isLeft
        right: !isLeft
    }                              // single-edge anchor = vertically centered
    implicitWidth: hitW
    implicitHeight: osdH

    // ---------- visibility (same state flow as before, new animations) ----------
    function syncVisibility(): void {
        if (held) {
            hideDelayTimer.stop()
            hideAnim.stop()
            if (shown) {
                settleTimer.stop()       // surface already mapped and settled
                appearAnim.restart()     // resumes from current values — an interrupted hide just reverses
            } else {
                shown = true             // FRESH MAP — placement is not settled yet
                settleTimer.restart()    // bloom only after the surface has committed in place
            }
        } else if (shown) {
            // Do NOT stop appearAnim here: a flick that leaves mid-bloom should
            // still finish opening (then the hide delay + rewind run) instead of
            // freezing half-stretched, which is what the old stop() caused. Only
            // cancel the pre-bloom settle wait; appear/hide then sequence cleanly
            // because appear (360ms) finishes well before the 2s hide delay fires.
            settleTimer.stop()
            hideDelayTimer.restart()
        }
    }

    onHeldChanged: syncVisibility()
    onScreenChanged: syncVisibility()

    // Suppression must be INSTANT: collapse to the hidden resting state in
    // the same tick (no rewind animation, no hide delay), so a lock can never
    // be trailed by a lingering OSD. Clearing it re-runs the normal policy.
    onSuppressedChanged: {
        if (suppressed) {
            appearAnim.stop()
            settleTimer.stop()
            hideDelayTimer.stop()
            hideAnim.stop()
            art.opacity = 0
            artScale.xScale = root.restXScale
            artScale.yScale = root.restYScale
            expandAnim.stop()
            root.expand = 0
            root.pendingCollapse = false
            motionArmed = false
            pulseHold = false
            pulseTimer.stop()
            shown = false
        } else {
            cursorXPrev = localCursorX
            syncVisibility()
        }
    }
    Component.onCompleted: {
        cursorXPrev = localCursorX
        syncVisibility()
        primed = true                 // from here on a real value/warn change pulses
    }

    onPillHoveredChanged: {
        if (pillHovered) {
            // fresh hover (even mid-collapse): re-target to full, drop any queued collapse
            pendingCollapse = false
            expandAnim.to = 1
            expandAnim.restart()
        } else if (expandAnim.to === 1 && expand < 1) {
            // left BEFORE it reached full: don't reverse (half-open freeze) — let
            // expandAnim finish to 1, then collapse via its onFinished.
            pendingCollapse = true
        } else {
            expandAnim.to = 0
            expandAnim.restart()
        }
    }

    Timer {
        id: hideDelayTimer
        interval: root.hideDelay
        repeat: false
        onTriggered: {
            if (!root.held && root.shown)
                hideAnim.restart()
        }
    }

    // The spec's map-once invariant, adapted to on-demand mapping: the
    // compositor/Qt placement of a freshly mapped layer surface settles
    // within its first committed frames; starting the bloom on that same
    // tick is what looked like a 1px sliver detaching and snapping at the
    // edge — the surface itself moving, invisible to any transform. One
    // event-driven 20 ms wait (≈2 frames at 120Hz, ≥1 at 60Hz) per fresh
    // map; opacity is still 0 across it, so nothing is painted late and no
    // animation tick is spent waiting.
    Timer {
        id: settleTimer
        interval: 20
        repeat: false
        onTriggered: {
            if (root.held && root.shown)
                appearAnim.restart()
        }
    }

    ParallelAnimation {
        id: appearAnim
        // the bloom: a dot at the edge's vertical center stretches into two
        // lines running up and down; OutQuint = quick start, long silky
        // deceleration. No x drift: the edge-origin scale already pins the
        // shape to the screen edge at every frame (see attachment doctrine).
        NumberAnimation { target: artScale; property: "yScale"; to: 1; duration: 360; easing.type: Easing.OutQuint }
        NumberAnimation { target: artScale; property: "xScale"; to: 1; duration: 360; easing.type: Easing.OutQuint }
        NumberAnimation { target: art; property: "opacity"; to: 1; duration: 200; easing.type: Easing.OutCubic }
    }

    ParallelAnimation {
        id: hideAnim
        // The appear animation played backwards: identical durations, the
        // same tracks with reversed endpoints, and mirrored easing (OutQuint
        // rewound reads as InQuint); the opacity holds then fades late, so
        // it covers the tail exactly as appear covers the head.
        // Both OSDs therefore exit on the exact motion curve they entered on.
        NumberAnimation { target: artScale; property: "yScale"; to: root.restYScale; duration: 360; easing.type: Easing.InQuint }
        NumberAnimation { target: artScale; property: "xScale"; to: root.restXScale; duration: 360; easing.type: Easing.InQuint }
        SequentialAnimation {      // the appear opacity fade [0,200] rewound: hold [0,160], fade [160,360]
            NumberAnimation { target: art; property: "opacity"; to: 1; duration: 160 }
            NumberAnimation { target: art; property: "opacity"; to: 0; duration: 200; easing.type: Easing.InCubic }
        }
        onFinished: {              // fires only on natural completion — stop() (re-show) leaves state untouched
            artScale.yScale = root.restYScale
            artScale.xScale = root.restXScale
            root.expand = 0
            if (!root.held) {
                root.shown = false
                root.motionArmed = false   // fully reset: the next appearance needs a fresh flick
            }
            // reset runs while the art is invisible, so snapping the
            // transform back is unseen — the next show blooms from the dot
        }
    }

    NumberAnimation {
        id: expandAnim
        target: root
        property: "expand"
        duration: 240
        easing.type: Easing.OutCubic
        // a latched hover-leave collapses only AFTER the expand reaches full,
        // so a quick flick always shows the fully-opened pill before it shuts
        onFinished: {
            if (root.pendingCollapse && root.expand >= 1) {
                root.pendingCollapse = false
                expandAnim.to = 0
                expandAnim.restart()
            }
        }
    }

    Item {
        id: art
        anchors.fill: parent
        opacity: 0
        transform: Scale {
            id: artScale
            origin.x: root.isLeft ? 0 : art.width   // the screen edge
            origin.y: art.height / 2                // the vertical center — the dot the OSD blooms from
            xScale: root.restXScale
            yScale: root.restYScale                 // collapsed to the dot; grows outward on show
        }

        Item {
            id: flip
            anchors.fill: parent
            transform: Scale {
                origin.x: flip.width / 2
                origin.y: flip.height / 2
                xScale: root.isLeft ? 1 : -1
            }

            // ---- everything in ONE Shape: mound (black rim with the two
            // ---- swooshes), pill capsule, and the two fill variants below.
            // One node → one render batch, one distance-field AA pass —
            // overlapping shapes in different items would antialias against
            // separate buffers and grow hairline seams at their borders.
            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer   // self-antialiasing — no offscreen layer

                // the mound: taller than the pill at the screen edge,
                // flowing into it with one continuous swoosh. Each swoosh
                // springs off the screen edge, dives down and flattens onto
                // the cap apex, topping out outlineW above the pill — that
                // lip is the extra black outline. The window never resizes:
                // the fins grow inside the frozen canvas.
                ShapePath {
                    fillColor: "black"
                    strokeWidth: 0              // default stroke is a 1px WHITE line — must be killed
                    pathHints: ShapePath.PathSolid | ShapePath.PathNonIntersecting
                    startX: -root.edgeOh        // fins spring off the edge from PAST the clip
                    startY: 0                   // boundary — kills the 1px AA sliver there

                    PathCubic {                       // tight dive off the edge into a round quarter-bow,
                        control1X: -root.edgeOh       // flattening onto the pill's top lip
                        control1Y: root.wC1y
                        control2X: root.wC2x
                        control2Y: root.wy0 - root.outlineW
                        x: root.pillLeft + root.pillW / 2
                        y: root.wy0 - root.outlineW
                    }
                    PathArc {                         // rim over the top cap (radius r + ow)
                        x: root.pillLeft + root.pillW + root.outlineW
                        y: root.wy0 + root.pillW / 2
                        radiusX: root.pillW / 2 + root.outlineW
                        radiusY: root.pillW / 2 + root.outlineW
                        direction: PathArc.Clockwise
                    }
                    PathLine {                        // rim down the outer side
                        x: root.pillLeft + root.pillW + root.outlineW
                        y: root.wy1 - root.pillW / 2
                    }
                    PathArc {                         // rim under the bottom cap
                        x: root.pillLeft + root.pillW / 2
                        y: root.wy1 + root.outlineW
                        radiusX: root.pillW / 2 + root.outlineW
                        radiusY: root.pillW / 2 + root.outlineW
                        direction: PathArc.Clockwise
                    }
                    PathCubic {                       // mirrored swoosh back to the edge;
                        control1X: root.wC2x          // closePath is implicit on fill: up the overhang line
                        control1Y: root.wy1 + root.outlineW
                        control2X: -root.edgeOh
                        control2Y: root.osdH - root.wC1y
                        x: -root.edgeOh
                        y: root.osdH - root.wSy
                    }
                }

                // the pill: dark-gray capsule, stretches on hover. Drawn
                // pillInset px inside its outline slot and concentric with
                // the mound's rim; the 1px round-join stroke is the hairline
                // seal keeping white fill meeting the rim seam-free.
                ShapePath {
                    fillColor: root.pillFill
                    strokeColor: "black"
                    strokeWidth: 1
                    joinStyle: ShapePath.RoundJoin
                    pathHints: ShapePath.PathSolid | ShapePath.PathNonIntersecting

                    // true capsule (radius = width/2) at every width
                    startX: root.gx + root.gr
                    startY: root.gy
                    PathLine { x: root.gx + root.gw - root.gr; y: root.gy }
                    PathArc { x: root.gx + root.gw; y: root.gy + root.gr
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                    PathLine { x: root.gx + root.gw; y: root.gy + root.gh - root.gr }
                    PathArc { x: root.gx + root.gw - root.gr; y: root.gy + root.gh
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                    PathLine { x: root.gx + root.gr; y: root.gy + root.gh }
                    PathArc { x: root.gx; y: root.gy + root.gh - root.gr
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                    PathLine { x: root.gx; y: root.gy + root.gr }
                    PathArc { x: root.gx + root.gr; y: root.gy
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                }

                // the fill: white, rising from the bottom. Two complete
                // variants swap at fillH = gr where their geometry coincides
                // (seam-free): below the cap radius the top edge is a chord
                // of the bottom cap; at/above it the region is a rectangle
                // over the straight sides plus the 180° bottom cap. The
                // inactive variant is gated to a transparent fill (a
                // ShapePath has no visibility flag) — the swap happens once
                // per glide, at the threshold where the two agree.
                ShapePath {
                    fillColor: root.fillH > 0.001 && root.fillH < root.gr
                               ? root.fillInk : "transparent"
                    strokeWidth: 0              // no default white stroke
                    pathHints: ShapePath.PathSolid | ShapePath.PathNonIntersecting

                    startX: root.capCx - root.fillDx
                    startY: root.fillTop
                    PathArc { x: root.capCx + root.fillDx; y: root.fillTop
                              radiusX: root.gr; radiusY: root.gr
                              direction: PathArc.Counterclockwise }
                }
                ShapePath {
                    fillColor: root.fillH >= root.gr ? root.fillInk : "transparent"
                    strokeWidth: 0              // no default white stroke
                    pathHints: ShapePath.PathSolid | ShapePath.PathNonIntersecting

                    startX: root.gx
                    startY: root.fillTop
                    PathLine { x: root.gx + root.gw; y: root.fillTop }
                    PathLine { x: root.gx + root.gw; y: root.capCy }
                    PathArc { x: root.gx + root.gw - root.gr; y: root.gy + root.gh
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                    PathArc { x: root.gx; y: root.capCy
                              radiusX: root.gr; radiusY: root.gr; direction: PathArc.Clockwise }
                }
            }

            // ---- glyph: service-supplied painter in the shared slot. The
            // glyph's pixels never animate — only its opacity (the expand
            // fade) and position ride the expand animation, so this tiny
            // Canvas repaints ONLY when the ink color flips (warn changes).
            Canvas {
                id: glyphCanvas
                width: 24
                height: 22
                x: root.pillLeft + root.pillW / 2 - 12   // slot center cx = pillLeft + pw/2
                y: root.wy1 - 28 - 4                     // slot center cy = pill bottom − 28
                visible: root.expand > 0.02 && root.paintGlyph !== null
                opacity: root.expand
                renderStrategy: Canvas.Immediate

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)   // fresh ink each paint
                    // canvas-local (12, 4) IS the slot's (cx, cy)
                    root.paintGlyph(ctx, 12, 4, root.glyphInk, root.warn)
                }
                onWidthChanged: requestPaint()
            }
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton

        // Actions land ONLY when the pill is expanded under direct hover.
        // While idle, or with the cursor merely in the wide approach band, the
        // surface must not act on (nor swallow) clicks / wheel — those events
        // pass through untouched so nothing happens to the OSD.
        onWheel: event => {
            if (!root.pillHovered)
                return
            const direction = event.angleDelta.y > 0
                ? 1
                : event.angleDelta.y < 0 ? -1 : 0
            if (direction !== 0)
                root.wheelMoved(direction)
            event.accepted = true
        }

        onClicked: if (root.pillHovered) root.activated()
    }

    // glyph repaint triggers: the only content changes a glyph ever gets
    onPaintGlyphChanged: glyphCanvas.requestPaint()
    onGlyphInkChanged: glyphCanvas.requestPaint()
}
