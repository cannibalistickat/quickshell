import QtQuick
import Quickshell
import Quickshell.Io
Scope {
    readonly property string out: Quickshell.env("QS_PROBE_OUT")
    function put(s) { const x = new XMLHttpRequest; x.open("PUT", "file://" + out, false); x.send(s + "\n" + (put.acc ?? "")); put.acc = (put.acc ?? "") + s + "\n" }
    Socket { id: s
        Component.onCompleted: {
            put("ADDR:" + String(s.address))
            put("EXECUTE:" + typeof Process.execute + " START:" + typeof Process.startProcess)
            try { const r = Process.execute("echo", ["hi"]); put("EXECRES:" + JSON.stringify(r)) } catch (e) { put("EXECERR:" + e) }
            Qt.quit()
        }
    }
}
