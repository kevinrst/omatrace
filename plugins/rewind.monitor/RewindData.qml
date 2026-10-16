import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  property var snapshot: null
  property var cpuHist: [] // [{v, idx}]
  property var ramHist: []
  property var netHist: []
  property int histLen: 0
  property bool offline: true
  property real netMax: 1

  // Snapshot selected by clicking a chart bar. Null = live.
  property var selectedSnapshot: null
  property int selectedPos: -1

  property var _pending: ({})

  // Per-process sparkline for the drill-down view.
  property int procPid: -1
  property var procPoints: [] // [{ts_ms, cpu, ram, net}]
  property int _pendingPid: -1

  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/rewind.sock"

  readonly property var liveSnapshot: selectedSnapshot || snapshot
  readonly property bool historyMode: selectedSnapshot !== null

  function pollLatest() {
    if (sock.connected) sock.write('{"method":"latest"}\n')
    else offline = true
  }

  function fetchIndex(idx, pos) {
    var p = _pending
    p[idx] = (pos === undefined) ? -1 : pos
    _pending = p
    if (sock.connected) sock.write(JSON.stringify({method: "get", index: idx}) + "\n")
  }

  function fetchProcHistory(pid) {
    procPid = pid
    procPoints = []
    _pendingPid = pid
    if (sock.connected) sock.write(JSON.stringify({method: "proc_history", pid: pid}) + "\n")
  }

  function clearProc() {
    procPid = -1
    procPoints = []
    _pendingPid = -1
  }

  function backToLive() {
    selectedSnapshot = null
    selectedPos = -1
    _pending = ({})
    pollLatest()
  }

  function pushCapped(arr, entry) {
    var next = arr.concat([entry])
    while (next.length > 60) next.shift()
    return next
  }

  Socket {
    id: sock
    path: root.socketPath
    connected: true
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (!line) return
        var msg = null
        try { msg = JSON.parse(String(line)) } catch (e) { return }
        if (!msg || !msg.ok) return
        // Per-process sparkline answering a drill-down (trimmed to the
        // same 60-bar window as the main chart).
        if (msg.points && root._pendingPid >= 0) {
          root.procPoints = msg.points.slice(-60)
          root._pendingPid = -1
          return
        }
        if (!msg.snapshot) {
          if (msg.index !== undefined) root.backToLive()
          return
        }

        if (msg.index !== undefined) {
          var pos = root._pending[msg.index]
          var p = root._pending
          delete p[msg.index]
          root._pending = p
          root.selectedSnapshot = msg.snapshot
          root.selectedPos = (pos === undefined) ? -1 : pos
          return
        }
        // Live snapshot (only when not scrubbing history).
        if (root.historyMode || !msg.snapshot.system) return
        var sys = msg.snapshot.system
        root.snapshot = msg.snapshot
        root.offline = false
        if (msg.len !== undefined) {
          root.histLen = msg.len
          var idx = msg.len - 1
          root.cpuHist = root.pushCapped(root.cpuHist, {v: sys.cpu_percent || 0, idx: idx})
          root.ramHist = root.pushCapped(root.ramHist, {v: sys.ram_used || 0, idx: idx})
          root.netHist = root.pushCapped(root.netHist, {v: (sys.net ? (sys.net.down_bps + sys.net.up_bps) : 0), idx: idx})
          var m = 1
          for (var i = 0; i < root.netHist.length; i++) m = Math.max(m, root.netHist[i].v)
          root.netMax = m
        }
      }
    }
    onConnectionStateChanged: {
      if (!sock.connected) root.offline = true
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.historyMode) root.pollLatest()
    }
  }
}
