pragma ComponentBehavior: Bound
// LockTv.qml — the CRT set of the lock screen. Everything inside the drawn
// glass of the background art is this item: the opening clip (zzz_opening.webm,
// played exactly once) pushed through ONE layer + ONE ShaderEffect pass
// (ui/shaders/lock_crt.frag) that adds noise, scanlines, roll, flicker,
// fringe, vignette, the rounded-glass mask and the power-off collapse.
//
// Doctrine (frozen architecture): presentation only. The cursor position and
// the lock state are fed in by LockScreen (which reads Backend's single
// per-change notify); nothing here talks to the compositor or the backend.
//
//  - The tube plays the opening once as the intro cinematic (a tight 3s), then
//    hands off to the user's "channels" pool (assets/channels/*) and shuffles it
//    at random — drop any video files in there and they play on the TV.
//  - The intro camera dollies back over the tube (LockScreen). The rounded-glass
//    mask radius tracks `introT`: at introT=0 the tube is a true square that the
//    camera magnifies past the display edges (immersive fullscreen, no bezel),
//    and it rounds into the CRT glass as the camera settles (introT→1).
//  - The password pill (EdgeOsd dark capsule #3b3d42) and all on-screen text
//    stay hidden until `ready` (intro finished); the pill then reveals only
//    while the cursor is within pillRange of its box, and vanishes instantly.
//  - The whole scene (room art + this tube + clock) parallaxes together as one
//    unit under the cursor (LockScreen), matching poo/ where they are siblings
//    inside #background-container. The video rides inside the tube and is clipped
//    to it, so it stays contained through the intro camera pull-back.

import QtQuick
import QtMultimedia
import Qt.labs.folderlistmodel

Item {
    id: tv
    // Containment: clip to the tube rect so the CRT pass, sheen, pill and user
    // label can never spill past the TV geometry as the
    // intro camera scales the world. All children already sit inside this rect,
    // so the clip is a guarantee, not a visual change.
    clip: true

    required property bool powered        // tube on (screen locked)
    required property string typed        // current password buffer
    required property bool denied         // last auth failed
    required property bool busy           // auth in flight
    required property real dpr            // device pixel ratio of the surface
    required property point cursorLocal   // cursor in WINDOW coords (px)

    property bool offGoing: false         // power-off animation running
    property alias userLabel: userText.who
    // Opening-clip length in ms (valid once the channel has loaded) — the
    // intro cinematic in LockScreen times its zoom-out to this so the tube
    // lands in the glass exactly as the opening loops.
    readonly property real videoDuration: tube.duration

    // ---- channel shuffle (user-drop videos in assets/channels/) ----
    readonly property url openingUrl: Qt.resolvedUrl("assets/vid/zzz_opening.webm")
    property url videoSource: openingUrl   // clip the tube is showing right now
    property real videoOpacity: 1          // cross-fade the tube between clips
    property bool swapping: false          // guard against re-entrant channel swaps
    property int lastChannel: -1           // avoid the same clip twice in a row
    property real lastPos: 0               // for loop-wrap detection (clips never stop)
    // shuffle bag: a Fisher-Yates-randomised queue of every channel index. We deal
    // one out per advance and only reshuffle once the bag runs dry, so EVERY clip
    // plays before any can repeat — no more clumped pseudo-random reruns.
    property var bag: []

    signal poweredOn(string file)
    signal accepted(string file)
    signal submitRequested()          // the solid ENTER dot was clicked

    // click-to-focus: the pill never grabs the keyboard just by appearing — the
    // user must click it (which arms it and shows the focus ring). It disarms
    // whenever the pill collapses (see onPillShownChanged below).
    property bool pillFocused: false
    // transport pause, driven by the painted play/pause button below the glass
    property bool paused: false
    function togglePause(): void {
        tv.paused = !tv.paused
        if (tv.paused) tube.pause()
        else tube.play()
    }

    // ---- intro / reveal state (driven by LockScreen's camera) ----
    property real introT: 1.0           // 0 camera zoomed-in (fullscreen) → 1 settled
    property bool ready: false          // intro finished: text + pill allowed

    // ---- tunables ----
    final readonly property real idleNoise: 0.035   // faint always-on grain, never full static
    final readonly property real pillRange: 100     // reveal radius around the pill bbox

    // ---- design tokens — extracted from ~/Downloads/poo/style/*.scss ----
    // Each value maps to a named rule in the original web project so the lock
    // screen speaks the same visual language as the source design.
    final readonly property string pillFill:   "#0d0d0d"   // near-black capsule, matching the inspo
    final readonly property string pillInk:    "#ffffff"   // pill dots ink (white)
    final readonly property string screenBg:   "#000000"   // pure black tube base so a letterboxed clip's own black bars blend seamlessly into the screen (no lighter #121010 band top/bottom)
    // Click-to-focus outline: a dark olive-gray ring, taken one step darker,
    // drawn only while the pill holds the keyboard.
    final readonly property color focusRing:   "#33322a"
    // The pill is deliberately wordless, so the old accent/status/denied inks and
    // the outline text-shadow colour are gone — the CRT static burst is the only
    // (non-textual) feedback a wrong password produces.

    // ---- shader uniforms ----
    property real t: 0
    property real noise: 0
    property real off: 0
    // The tube is a fixed glass-sized object; the intro camera dollies back over
    // it. Scaling the rounded-glass radius with introT keeps the tube a true
    // square while the camera is zoomed in (introT=0, so it fills the display
    // corner-to-corner) and only rounds it into the CRT glass as the camera
    // settles (introT→1).
    readonly property real glassRadius: 0.07 * Math.min(width, height) * dpr * introT

    // ---- pill geometry (tv-local; box mirrored to window coords for the
    // ---- proximity test, since the cursor arrives in window coords) ----
    readonly property real pillPadX: width * 0.035   // inner padding around the dots/ENTER dot
    readonly property real pillH: height * 0.115     // taller capsule to match the inspo
    readonly property real enterDotSize: pillH * 0.19
    // Hard-stuck fixed width (the original 0.46): the pill never grows. A long
    // password instead scrolls INSIDE it — the dots are right-aligned + clipped,
    // so the leftmost characters drop off as the caret advances right, exactly
    // like a too-narrow terminal.
    readonly property real pillW: width * 0.46
    readonly property real pillCX: width / 2
    readonly property real pillCY: height / 2   // perfectly centred in the tube
    readonly property rect pillBox: Qt.rect(
        tv.x + pillCX - pillW / 2, tv.y + pillCY - pillH / 2, pillW, pillH)

    function distToRect(p: point, r: rect): real {
        const dx = Math.max(r.x - p.x, 0, p.x - (r.x + r.width))
        const dy = Math.max(r.y - p.y, 0, p.y - (r.y + r.height))
        return Math.sqrt(dx * dx + dy * dy)
    }
    readonly property bool pillNear:
        powered && !offGoing && distToRect(cursorLocal, pillBox) <= pillRange
    // The pill (and its caption) only reveal once the intro has finished.
    readonly property bool pillShown: pillNear && ready

    // =====================================================================
    //  content — the tube image, one CRT pass
    // =====================================================================
    Item {
        id: content
        anchors.fill: parent
        layer.enabled: true
        layer.effect: ShaderEffect {
            property vector2d u_res: Qt.vector2d(content.width * tv.dpr, content.height * tv.dpr)
            property real u_time: tv.t
            property real u_noise: tv.noise
            property real u_off: tv.off
            property real u_radius: tv.glassRadius
            fragmentShader: "../shaders/lock_crt.frag.qsb"
        }

        // black tube base so the shader always has an opaque source
        Rectangle { anchors.fill: parent; color: tv.screenBg }

        // the tube's video: the opening clip during the intro, then the shuffled
        // channel pool (fills the tube; parallax lives on the room art, not here)
        Video {
            id: tube
            anchors.fill: parent
            source: tv.videoSource
            fillMode: VideoOutput.PreserveAspectCrop
            autoPlay: false    // never self-start: the tube only plays when the lock
                               // is actually on (see onPoweredChanged). LockTv lives in
                               // the always-created window, so autoPlay used to run the
                               // opening off-screen on a cold `qs` start — audible, unseen.
            loops: -1          // loop so a clip never dead-stops; the shuffle timer
                               // below catches each wrap to advance to the next one
            volume: tv.powered ? 1.0 : 0.0   // audible only while powered — belt-and-braces
                                             // so an invisible tube can never be heard
            opacity: tv.videoOpacity
        }
    }

    // screen highlight streak (soft glass sheen over the tube)
    Image {
        anchors.fill: parent
        source: "assets/img/screen_hightlight.png"
        sourceSize: Qt.size(Math.round(width * tv.dpr), Math.round(height * tv.dpr))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        opacity: 0.22
        visible: opacity > 0
    }

    // =====================================================================
    //  OSD layer — crisp, sits ON the glass (outside the shader pass)
    // =====================================================================
    // proximity-revealed password pill: a dark capsule of ASCII dots, centred
    // in the tube. It carries NO words at all — no caption, no status line — the
    // dots are the only feedback, so nothing ever spells out the password state.
    // It blooms from its own centre outward on reveal and collapses back on hide,
    // quick + smooth like the edge OSDs (one eased scale + a matching opacity
    // fade; the scale floors at an epsilon so the fold never smears a 1px line).
    Item {
        id: pill
        x: tv.pillCX - tv.pillW / 2
        y: tv.pillCY - tv.pillH / 2
        width: tv.pillW
        height: tv.pillH

        // grow: 0 collapsed → 1 full, driven by proximity + intro-ready. The same
        // eased curve runs forwards on reveal and backwards on hide (symmetry).
        property real grow: tv.pillShown ? 1 : 0
        Behavior on grow {
            NumberAnimation { duration: 200; easing.type: Easing.OutQuint }
        }
        opacity: grow
        visible: grow > 0.0001
        transform: Scale {
            origin.x: pill.width / 2      // scale about the pill's own centre so it
            origin.y: pill.height / 2     // grows outward from (and collapses to) the middle
            xScale: Math.max(0.0001, pill.grow)
            yScale: Math.max(0.0001, pill.grow)
        }

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: tv.pillFill
            // focus ring: only while the pill holds the keyboard (armed by a click)
            border.width: tv.pillFocused ? Math.max(2, height * 0.03) : 0
            border.color: tv.focusRing
            Behavior on border.color { ColorAnimation { duration: 140 } }

            // whole-pill click arms the field (the ENTER dot's own area wins where
            // they overlap, so a click there both focuses and submits)
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: tv.pillFocused = true
            }

            // the password dots: centred in the capsule, nudged down a couple of px
            // so the superscript Minecraft "*" sits on the visual middle line. A
            // thin LINE caret (not an underscore) blinks only while focused + idle;
            // during auth it drops so the held dots read as "checking" without words.
            Text {
                id: dots
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                anchors.left: parent.left
                anchors.leftMargin: tv.pillPadX
                anchors.right: enterDot.left
                anchors.rightMargin: tv.pillPadX
                // read left→right: dots begin at the left; only once they exceed
                // the capsule does it switch to right-align so the caret stays at
                // the right and the leftmost characters clip off (narrow terminal).
                horizontalAlignment: dots.contentWidth > dots.width ? Text.AlignRight : Text.AlignLeft
                clip: true
                font.family: cakeFont.name
                font.pixelSize: tv.height * 0.045
                color: tv.pillInk
                text: "*".repeat(tv.typed.length)
                    + (tv.pillFocused && !tv.busy && Math.floor(tv.t * 2) % 2 === 0 ? "|" : "")
            }

            // solid ENTER dot — always present on the right, never blinks. A mouse
            // fallback for the (still-working) Enter key: clicking it submits.
            Rectangle {
                id: enterDot
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: tv.pillPadX
                width: tv.enterDotSize
                height: width
                radius: width / 2
                color: tv.pillInk
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -8      // a little grab room around the dot
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { tv.pillFocused = true; tv.submitRequested() }
                }
            }
        }
    }

    // "Enter password" caption — Minecraft font, sits just above the pill and
    // reveals with it. The capsule itself stays wordless (dots only); this is
    // the prompt line, matching the inspo.
    Text {
        id: pwLabel
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: pill.top
        anchors.bottomMargin: tv.height * 0.022
        visible: tv.pillShown
        font.family: minecraftFont.name
        font.pixelSize: tv.height * 0.05
        color: "#f2f2f2"
        text: "Enter password"
    }

    // user label — hidden until the lock is interactive (post-intro)
    Text {
        id: userText
        visible: tv.ready
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: parent.height * 0.03
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: tv.height * 0.026
        color: "#5c646e"
        property string who: ""
        text: who
    }

    // =====================================================================
    //  behavior
    // =====================================================================
    // Password-dot font + the Minecraft font used by the "Enter password" caption.
    FontLoader { id: cakeFont; source: Qt.resolvedUrl("assets/font/VanillaCakeFree.ttf") }
    FontLoader { id: minecraftFont; source: Qt.resolvedUrl("assets/font/Minecraft.ttf") }

    // shader clock — only while the tube is on screen
    Timer {
        interval: 16
        repeat: true
        running: tv.visible
        triggeredOnStart: true
        onTriggered: tv.t += 0.016
    }

    // ---- channel pool: everything the user drops into assets/channels/ ----
    // FolderListModel watches the dir live, so new downloads appear without a
    // restart; we deal the pool out from a shuffled bag (every clip once before any
    // can repeat) rather than picking a fresh random index each time.
    FolderListModel {
        id: channels
        folder: Qt.resolvedUrl("assets/channels/")
        showDirs: false
        showFiles: true
        nameFilters: ["*.mp4", "*.webm", "*.mkv", "*.mov", "*.m4v", "*.avi",
                      "*.ogv", "*.ogg", "*.ts", "*.mts", "*.flv", "*.wmv",
                      "*.mpg", "*.mpeg", "*.3gp", "*.3g2"]
        // pool changed (a download landed / was removed): rebuild the bag next pick
        onCountChanged: tv.bag = []
    }
    // Fisher-Yates: fill the bag with every channel index, shuffled.
    function refillBag(): void {
        var a = []
        for (var k = 0; k < channels.count; ++k)
            a.push(k)
        for (var i = a.length - 1; i > 0; --i) {
            var j = Math.floor(Math.random() * (i + 1))
            var t = a[i]; a[i] = a[j]; a[j] = t
        }
        tv.bag = a
    }
    function pickChannel(): url {
        if (channels.count <= 0) return tv.openingUrl   // empty pool → loop the opening
        if (tv.bag.length === 0) {
            refillBag()
            // don't let a bag boundary repeat the last clip: swap the head with a
            // random other entry if it happens to match what just played
            if (channels.count > 1 && tv.bag[0] === tv.lastChannel) {
                var s = 1 + Math.floor(Math.random() * (tv.bag.length - 1))
                var tmp = tv.bag[0]; tv.bag[0] = tv.bag[s]; tv.bag[s] = tmp
            }
        }
        var idx = tv.bag.shift()
        tv.lastChannel = idx
        return channels.get(idx, "fileUrl")
    }
    // fade the current clip out, swap to a random next one, fade back in
    function advanceChannel(): void {
        if (tv.swapping) return
        tv.swapping = true
        channelFadeOut.restart()
    }
    NumberAnimation {
        id: channelFadeOut
        target: tv; property: "videoOpacity"; to: 0
        duration: 380; easing.type: Easing.InOutQuad
        onFinished: {
            tv.videoSource = tv.pickChannel()
            tube.position = 0
            tv.lastPos = 0
            tube.play()
            channelFadeIn.start()
        }
    }
    NumberAnimation {
        id: channelFadeIn
        target: tv; property: "videoOpacity"; to: 1
        duration: 380; easing.type: Easing.InOutQuad
        onFinished: tv.swapping = false
    }
    // shuffle driver: the QML Video type here exposes no media-status signal, so we
    // poll the position. Trigger the cross-fade just BEFORE the clip reaches its end
    // (the fade is 380ms, so firing ~520ms out lands the swap right as the clip
    // finishes). Reacting only AFTER the wrap — which loops:-1 makes by restarting the
    // finished clip at 0 — showed up to a poll interval + the whole fade-out of the
    // just-ended clip's beginning replaying. The wrap check stays as a fallback for
    // very short clips or a missed pre-end poll tick.
    Timer {
        interval: 100
        repeat: true
        running: tv.powered && tv.ready && !tv.swapping
        onTriggered: {
            const dur = tube.duration
            const pos = tube.position
            if (dur > 1200 && pos >= dur - 520)
                tv.advanceChannel()          // fade over the clip's own tail
            else if (dur > 0 && pos < tv.lastPos - 200)
                tv.advanceChannel()          // fallback: we missed the tail
            tv.lastPos = pos
        }
    }

    function burst(peak: real, decay: int): void {
        noiseBurst.stop()
        tv.noise = peak
        noiseBurst.from = peak
        noiseBurst.to = tv.idleNoise
        noiseBurst.duration = decay
        noiseBurst.start()
    }

    NumberAnimation {
        id: noiseBurst
        target: tv
        property: "noise"
        easing.type: Easing.OutQuart
    }

    // power sequencing: on → settle to a faint grain over a live tube;
    // off → pause decoding to honour minimum-render-work
    onPoweredChanged: {
        if (powered) {
            tv.off = 0
            tv.offGoing = false
            tv.swapping = false
            tv.paused = false
            tv.pillFocused = false
            tv.bag = []
            tv.lastChannel = -1
            tv.videoOpacity = 1
            tv.videoSource = tv.openingUrl   // the intro always opens on the cinematic
            tube.position = 0                // rewind it; the fixed 3s intro plays it
            tube.play()
            burst(1.0, 1100)
            tv.poweredOn("assets/snd/vhs_startup.mp3")
        } else {
            tube.pause()
        }
    }

    // when the intro settles (3s) fade the opening out and start the shuffle
    onReadyChanged: if (tv.ready) tv.advanceChannel()

    // the pill loses the keyboard the moment it collapses (cursor left / not
    // ready), so the next appearance always needs a fresh click to focus
    onPillShownChanged: if (!tv.pillShown) tv.pillFocused = false

    function powerOff(): void {
        tv.offGoing = true
        offAnim.restart()
    }
    NumberAnimation {
        id: offAnim
        target: tv
        property: "off"
        from: 0; to: 1
        duration: 420
        easing.type: Easing.InQuart
        onFinished: tv.accepted("assets/snd/light_switch.mp3")
    }
}
