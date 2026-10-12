pragma ComponentBehavior: Bound
// LockScreen.qml — ZZZ anniversary TV-ad login screen, ported from the
// web project at ~/Downloads/poo (see ui/lock/LockTv.qml for the tube).
//
// Trigger: SUPER+L / hypridle write "lock\n" to the unix socket below
// (socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/quickshell-lock). Auth is PAM via
// `sudo -k -S -p ""` — password is written to stdin only, never argv.
//
// The background art is the original room; the drawn CRT glass sits at a
// measured position in the 8192x2576 image, so the live TV is mapped through
// the same PreserveAspectCrop transform the Image uses and lands exactly
// inside the bezel on any screen shape.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Shell.Backend
import "lock"

Scope {
    id: root

    // ---------- state ----------
    property bool locked: false
    property string typed: ""
    property bool denied: false
    property bool busy: false
    property string pendingPw: ""
    readonly property bool preview: Quickshell.env("QS_LOCK_PREVIEW") === "1"
    readonly property string who: (Quickshell.env("USER") || "user")
        + "@" + (Quickshell.env("HOSTNAME") || "laen")

    // the screen the cursor was on when the lock dropped gets the keyboard
    property int activeScreen: 0

    // ---------- socket trigger ----------
    // client: printf 'lock\n' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/quickshell-lock
    function handleMsg(msg: string): void {
        const verb = msg.trim()
        if (verb === "unlock" || verb === "cancel")
            root.forceUnlock()
        else
            root.lock()          // "lock" / "toggle" / anything else
    }

    SocketServer {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quickshell-lock"
        active: true
        handler: Socket {
            parser: SplitParser {
                onRead: data => root.handleMsg(data)
            }
        }
    }

    // ---------- audio (fire-and-forget pool) ----------
    function play(rel: string): void {
        const p = sfxPool[sfxIdx % sfxPool.length]
        sfxIdx = (sfxIdx + 1) % sfxPool.length
        p.command = ["pw-play", "--", Qt.resolvedUrl("lock/" + rel)]
        p.startDetached()
    }
    property int sfxIdx: 0
    component Sfx: Process {}
    Sfx { id: sfx0 }
    Sfx { id: sfx1 }
    Sfx { id: sfx2 }
    readonly property var sfxPool: [sfx0, sfx1, sfx2]

    // ---------- authentication ----------
    // PAM gate: -k forces a fresh challenge, -S reads the password from stdin
    // (never argv), -p "" silences the prompt. Correct pw runs /bin/true -> 0.
    Process {
        id: authProc
        command: ["sudo", "-k", "-S", "-p", "", "/bin/true"]
        stdinEnabled: true
        onStarted: authProc.write(root.pendingPw + "\n")
        // `exited` fires for exec failures too (nonzero code), so a separate
        // error hook is unnecessary — reject() is the single failure path.
        onExited: (exitCode, exitStatus) => {
            if (!root.busy)
                return
            root.busy = false
            authGuard.stop()
            if (exitCode === 0)
                tvPowerOff()
            else
                root.reject()
        }
    }
    Timer {
        id: authGuard
        interval: 8000
        onTriggered: { authProc.signal(15); root.busy = false; root.reject() }
    }

    function submitPassword(): void {
        if (root.busy || root.typed.length === 0)
            return
        if (root.preview) {
            root.play("assets/snd/light_switch.mp3")
            root.windows.forEach(w => w.tv.powerOff())
            finishTimer.start()
            return
        }
        root.pendingPw = root.typed
        // NB: do NOT clear root.typed here. The buffer is the pill's only
        // feedback, so the dots must stay put while auth is in flight (busy)
        // that the user reads "it's checking" without any text. reject() clears
        // it on a wrong password (a silent reset); a correct one closes the
        // window, so the lingering dots never have a chance to matter.
        root.busy = true
        authGuard.start()
        authProc.running = true
    }

    function reject(): void {
        root.denied = true
        root.typed = ""
        root.play("assets/snd/tv_static.mp3")
        root.windows.forEach(w => w.tv.burst(0.85, 900))
        denyReset.restart()
    }
    Timer { id: denyReset; interval: 1800; onTriggered: root.denied = false }

    function tvPowerOff(): void {
        root.windows.forEach(w => w.tv.powerOff())
        finishTimer.start()
    }
    Timer {
        id: finishTimer
        interval: 480
        onTriggered: root.locked = false
    }

    function forceUnlock(): void {
        root.busy = false
        authGuard.stop()
        root.denied = false
        root.typed = ""
        root.locked = false
    }

    function lock(): void {
        if (root.locked)
            return
        root.typed = ""
        root.denied = false
        root.busy = false
        // pick the screen under the cursor for the keyboard grab
        const cx = Backend.cursorX, cy = Backend.cursorY
        root.activeScreen = 0
        for (let i = 0; i < Quickshell.screens.length; ++i) {
            const s = Quickshell.screens[i]
            if (cx >= s.x && cx < s.x + s.width && cy >= s.y && cy < s.y + s.height)
                root.activeScreen = i
        }
        root.locked = true
    }

    // ---------- per-screen windows ----------
    // Variants.instances is the readonly QObject list (JS array in bindings)
    readonly property var windows: winVar.instances

    Variants {
        id: winVar
        model: Quickshell.screens

        LockWin {}
    }

    // ---------------------------------------------------------------------
    component LockWin: PanelWindow {
        id: win
        required property ShellScreen modelData
        readonly property ShellScreen targetScreen: modelData
        readonly property int screenIndex: Quickshell.screens.indexOf(targetScreen)
        property alias tv: tv

        // ---- intro cinematic (camera pull-back) ----
        // The viewer STARTS immersed INSIDE the TV screen — the tube is magnified
        // past the display edges (square glass, no bezel) — then the camera dollies
        // back to reveal the whole TV set in the room. This is done by scaling ONE
        // world layer about the tube's centre (`camScale`, below) — the tube keeps a
        // fixed geometry and its video stays native inside it, so nothing reads as
        // "the picture shrinking". introT drives the pull back: it defaults to 0 so
        // the very first mapped frame is already fullscreen (no glass flash), holds
        // for `introHoldMs` (1s), then eases 0 → 1 (InOutSine) over `introZoomMs`
        // (2s) so the camera settles at 3s — exactly when the opening fades out and
        // the tube hands off to the shuffled channel videos (LockTv). Fixed timing,
        // independent of clip length. Pure transform on ONE property — the scene
        // graph re-reads
        // camScale, no per-frame JS. A SequentialAnimation (explicit from/to) owns
        // the change so it can never strand the start framing the way a Behavior +
        // restart() could.
        property real introT: 0.0
        property bool introDone: false      // true once the tube has settled
        function lerp(a: real, b: real, t: real): real { return a + (b - a) * t }
        final readonly property int introHoldMs: 1000   // fullscreen hold leg (0→1s)
        // Fixed dolly-out leg (1s→3s): same camStart→1.0 distance, just faster than
        // the old clip-length-driven leg, still eased (InOutSine). The whole intro is
        // a tight 3s regardless of how long the opening clip actually is.
        final readonly property int introZoomMs: 2000
        function playIntro(): void {
            win.introT = 0.0            // snap to the immersive fullscreen start
            win.introDone = false       // pill + text stay hidden until it settles
            introTimeline.restart()     // then dolly the camera back on the timed leg
        }
        SequentialAnimation {
            id: introTimeline
            PauseAnimation { duration: win.introHoldMs }
            NumberAnimation {
                target: win
                property: "introT"
                from: 0.0
                to: 1.0
                duration: win.introZoomMs   // fixed 2s dolly-out (settles at 3s)
                easing.type: Easing.InOutSine
            }
            onFinished: win.introDone = true    // unlock the pill, text + input
        }
        onVisibleChanged: if (visible) win.playIntro()
        Component.onCompleted: if (win.visible) win.playIntro()

        screen: targetScreen
        visible: root.locked
        color: "black"
        focusable: true

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:lockScreen"
        WlrLayershell.keyboardFocus:
            visible && screenIndex === root.activeScreen
                ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // ---- cursor parallax on the WHOLE SCENE (room + TV + clock) ----
        // In poo/ the background image, the clock and the .tv_container are all
        // siblings inside #background-container — one unit — so panning that
        // container drifts room, TV and clock TOGETHER. We mirror that: the same
        // roomPanX/roomPanY offset is applied to the room image, the tube and the
        // clock, so they read as a single connected scene under the cursor rather
        // than a TV floating independently. The image is overscanned by roomPan on
        // every side so the pan never reveals an edge.
        readonly property real curU: Math.max(0, Math.min(1,
            (Backend.cursorX - targetScreen.x) / targetScreen.width))
        readonly property real curV: Math.max(0, Math.min(1,
            (Backend.cursorY - targetScreen.y) / targetScreen.height))
        final readonly property real roomPan: 34
        // frozen (0) during the intro so the fullscreen start can't reveal an edge;
        // it eases in from centre once the camera settles (introDone) via Behavior
        property real roomPanX: introDone ? (curU - 0.5) * 2 * roomPan : 0
        property real roomPanY: introDone ? (curV - 0.5) * 2 * roomPan : 0
        Behavior on roomPanX { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on roomPanY { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // ---- art → window mapping (mirror the room's PreserveAspectCrop) ----
        readonly property real imgW: 8192
        readonly property real imgH: 2576
        readonly property real roomW: width + 2 * roomPan
        readonly property real roomH: height + 2 * roomPan
        readonly property real fitScale: Math.max(roomW / imgW, roomH / imgH)
        readonly property real fitOffX: (roomW - imgW * fitScale) / 2
        readonly property real fitOffY: (roomH - imgH * fitScale) / 2
        // image fraction → window coords at REST (pan 0, room origin -roomPan)
        function mapX(fx: real): real { return -roomPan + fitOffX + fx * imgW * fitScale }
        function mapY(fy: real): real { return -roomPan + fitOffY + fy * imgH * fitScale }
        // The live video fills the TV SCREEN (the artwork's transparent cutout,
        // ~1.32:1 — squarer than it first looks). glassMeas is the measured cutout
        // bounding box in the 8192x2576 art (its ~50%-alpha edge); a small UNIFORM
        // inset (scale 0.96) keeps the picture just INSIDE the bezel with a thin
        // dark margin — like the inspo — while preserving that square shape.
        final readonly property real screenScaleW: 0.96   // slight inset: sits inside the bezel, not over it
        final readonly property real screenScaleH: 0.96   // (uniform keeps the square shape)
        final readonly property real glassNudgeX: 0       // centred on the screen
        final readonly property real glassExtendLeft: 0   // symmetric — no bias
        readonly property rect glassMeas: Qt.rect(
            mapX(0.4026), mapY(0.2500), mapX(0.5972) - mapX(0.4026), mapY(0.7143) - mapY(0.2500))
        readonly property rect glass: {
            const m = glassMeas
            const w = m.width * screenScaleW
            const h = m.height * screenScaleH
            const ext = w * glassExtendLeft
            const cx = m.x + m.width / 2 + glassNudgeX
            return Qt.rect(cx - w / 2 - ext, m.y + (m.height - h) / 2, w + ext, h)
        }
        // pre-computed tube centre (static) — reused by the camera pivot each frame
        // so the Scale origin never re-derives glass.x/width/2 at runtime
        readonly property real glassCx: glass.x + glass.width / 2
        readonly property real glassCy: glass.y + glass.height / 2
        // painted play/pause transport button on the TV body just below the glass;
        // measured in the 8192x2576 art and mapped through the same crop so the
        // live hit-area + glow land exactly on the drawn glyph at any screen shape
        readonly property rect pauseBtn: Qt.rect(
            mapX(0.6359), mapY(0.8414),
            mapX(0.6603) - mapX(0.6359), mapY(0.9191) - mapY(0.8414))

        // ---- camera pull-back ----
        // The TV is a fixed object in the room; the opening dollies ONE camera
        // back over the whole scene instead of rescaling the tube. camStart is the
        // START magnification. max() (not min()) gives COVER: the tube is scaled
        // past BOTH display dimensions so it fills the screen edge-to-edge with no
        // bezel or room visible — a true immersive fullscreen at introT=0 (the glass
        // mask is square there, so the corners reach the display corners). The 1.02
        // margin absorbs the tube's small off-centre offset and any AA hairline so no
        // gap can appear, and parallax is frozen during the intro so it can't reveal
        // an edge either. camScale eases this down to 1.0 (the settled room view).
        readonly property real camStart:
            Math.max(width / glass.width, height / glass.height) * 1.02
        readonly property real camScale: lerp(camStart, 1.0, introT)

        // Everything the camera looks at lives in this one scaled layer.
        Item {
            id: world
            anchors.fill: parent
            transform: Scale {
                // pivot on the (parallaxed) tube centre so the zoom stays locked
                // to the TV as the whole scene drifts under the cursor
                origin.x: win.glassCx + win.roomPanX
                origin.y: win.glassCy + win.roomPanY
                xScale: win.camScale
                yScale: win.camScale
            }

            Image {
                id: room
                x: -win.roomPan + win.roomPanX
                y: -win.roomPan + win.roomPanY
                width: win.roomW
                height: win.roomH
                source: "lock/assets/img/zzz_background_crt_cutout_blur.png"
                sourceSize: Qt.size(4096, 1288)   // already-blurred art: half-res is free
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                mipmap: true
            }

            LockTv {
                id: tv
                // parallaxes WITH the room (one scene unit, per poo/); the video
                // rides inside the tube so it follows automatically, and the tube
                // clip keeps it contained throughout the camera pull-back
                x: win.glass.x + win.roomPanX
                y: win.glass.y + win.roomPanY
                width: win.glass.width
                height: win.glass.height
                dpr: win.devicePixelRatio
                introT: win.introT
                ready: win.introDone
                powered: root.locked
                typed: root.typed
                denied: root.denied
                busy: root.busy
                userLabel: root.who
                cursorLocal: Qt.point(Backend.cursorX - targetScreen.x,
                                      Backend.cursorY - targetScreen.y)
                onPoweredOn: file => root.play(file)
                onAccepted: file => { root.play(file) }
                onSubmitRequested: root.submitPassword()
            }

            LockClock {
                opacity: win.introDone ? 1.0 : 0.0   // reveal the clock once settled
                Behavior on opacity { NumberAnimation { duration: 360 } }
                width: win.glass.width * 0.52
                height: width * (363 / 810)
                // glued to the room: same parallax offset as the tube + art
                x: win.glass.x + win.glass.width * 0.97 - width / 2 + win.roomPanX
                y: win.glass.y - win.glass.height * 0.375 - height / 2 + win.roomPanY
            }

            // ---- pause / transport button (below the glass, on the TV body) ----
            // Sits exactly on the painted play-pause glyph: hover → glows white;
            // click → pauses the channel video and the glow latches on; leave it
            // alone → the glow fades back out. The glyph is a play-triangle plus
            // two bars, traced in white with a soft canvas glow.
            Item {
                id: pauseBtn
                x: win.pauseBtn.x + win.roomPanX
                y: win.pauseBtn.y + win.roomPanY
                width: win.pauseBtn.width
                height: win.pauseBtn.height
                opacity: (pauseHover.containsMouse || tv.paused) ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                }

                Canvas {
                    anchors.fill: parent
                    antialiasing: true
                    onPaint: {
                        const c = getContext("2d")
                        c.clearRect(0, 0, width, height)
                        c.shadowColor = "#ffffff"
                        c.shadowBlur = Math.max(5, width * 0.16)
                        c.fillStyle = "#ffffff"
                        // traced to the painted glyph's measured box-fractions: a
                        // right-pointing triangle on the left, two thin bars on the
                        // right (the whole glyph sits a touch right-of-centre)
                        c.beginPath()
                        c.moveTo(0.275 * width, 0.363 * height)
                        c.lineTo(0.275 * width, 0.633 * height)
                        c.lineTo(0.530 * width, 0.498 * height)
                        c.closePath()
                        c.fill()
                        c.fillRect(0.615 * width, 0.353 * height, 0.040 * width, 0.290 * height)
                        c.fillRect(0.690 * width, 0.348 * height, 0.035 * width, 0.305 * height)
                    }
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()
                }
                MouseArea {
                    id: pauseHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tv.togglePause()
                }
            }
        }

        // ---- keyboard ----
        Item {
            id: keys
            anchors.fill: parent
            focus: win.visible
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape && root.preview) {
                    root.forceUnlock()
                    event.accepted = true
                    return
                }
                if (!root.locked || root.busy)
                    return
                // Password entry is disabled until the pill is BOTH on screen
                // (intro finished + cursor near it) AND clicked-to-focus: the
                // field never grabs the keyboard on its own. Swallow the key
                // without touching the buffer otherwise.
                if (!tv.pillShown || !tv.pillFocused) {
                    event.accepted = true
                    return
                }
                if (event.key === Qt.Key_Backspace) {
                    root.typed = root.typed.slice(0, -1)
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.submitPassword()
                    event.accepted = true
                } else if (event.text.length === 1 && event.text.charCodeAt(0) >= 0x20
                           && event.text.charCodeAt(0) !== 0x7f) {
                    if (root.typed.length < 64) {
                        if (root.denied)
                            root.denied = false
                        root.typed += event.text
                    }
                    event.accepted = true
                } else {
                    event.accepted = true    // swallow everything else
                }
            }
        }
    }
}
