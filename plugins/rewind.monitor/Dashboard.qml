import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "RewindClient.js" as Client

// Full dashboard window: live charts, timeline scrub, process filter, kill.
Panel {
  id: root
  moduleName: "rewind.monitor"
  ipcTarget: "rewind.monitor"

  property var snapshot: Client.mockSnapshot()
  property int histLen: 0
  property int histIndex: -1  // -1 = live
  property string filter: ""
  property string sortBy: "cpu"
  property bool offline: true

  function request(obj) {
    if (sock.connectionState === Socket.Connected)
      sock.write(JSON.stringify(obj) + "\n");
  }
  function pollLatest() { request({method: "latest"}); }
  function pollIndex(i) { request({method: "get", index: i}); }

  Socket {
    id: sock
    path: "/run/user/1000/rewind.sock"
    connected: true
  }

  Connections {
    target: sock
    function onDataReceived() {
      var lines = sock.readAll().split("\n");
      for (var i in lines) {
        if (!lines[i]) continue;
        try {
          var msg = JSON.parse(lines[i]);
          if (msg.snapshot) {
            root.snapshot = msg.snapshot;
            root.offline = false;
            if (msg.len !== undefined) root.histLen = msg.len;
          }
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 2000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: { if (root.histIndex < 0) root.pollLatest(); }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 12

    RowLayout {
      Text {
        text: root.offline ? "Rewind (offline — start rewindd)" : "Rewind — " + new Date(root.snapshot.ts_ms).toLocaleTimeString()
        color: Style.colors.text
        font.pixelSize: 16
      }
      Item { Layout.fillWidth: true }
      TextField {
        placeholderText: "Filter processes…"
        onTextChanged: root.filter = text
      }
      ComboBox {
        model: ["cpu", "ram", "net"]
        onCurrentTextChanged: root.sortBy = currentText
      }
      Button {
        text: root.histIndex < 0 ? "Live" : "Back to live"
        onClicked: { root.histIndex = -1; root.pollLatest(); }
      }
    }

    // Timeline scrub: index into the snapshot ring (Kova MetricGraph equivalent)
    RowLayout {
      Text { text: "Timeline:"; color: Style.colors.subtle }
      Slider {
        Layout.fillWidth: true
        from: 0; to: Math.max(0, root.histLen - 1); stepSize: 1
        value: root.histIndex < 0 ? root.histLen - 1 : root.histIndex
        onMoved: { root.histIndex = Math.round(value); root.pollIndex(root.histIndex); }
      }
    }

    // Charts row: CPU / RAM / NET bars (simple canvas sparklines for v1)
    RowLayout {
      Layout.fillWidth: true
      ColumnLayout {
        Text { text: "CPU " + (root.snapshot.system.cpu_percent || 0).toFixed(0) + "%"; color: Style.colors.text }
        Text { text: "RAM " + Client.fmtBytes(root.snapshot.system.ram_used || 0) + " / " + Client.fmtBytes(root.snapshot.system.ram_total || 1); color: Style.colors.text }
        Text { text: "NET ↓" + Client.fmtBps((root.snapshot.system.net || {}).down_bps || 0) + " ↑" + Client.fmtBps((root.snapshot.system.net || {}).up_bps || 0); color: Style.colors.text }
        Text { text: "LOAD " + (root.snapshot.system.load_avg_1 || 0).toFixed(2); color: Style.colors.subtle }
        Text {
          text: root.snapshot.system.temp_max_c ? ("TEMP " + root.snapshot.system.temp_max_c.toFixed(0) + "°C") : "TEMP n/a"
          color: Style.colors.subtle
        }
      }
    }

    // Process table with filter + sort + kill (confirm)
    ListView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      model: filteredProcesses()
      delegate: RowLayout {
        width: ListView.view.width
        Text { text: modelData.name; color: Style.colors.text; Layout.fillWidth: true; elide: Text.ElideRight }
        Text { text: (modelData.cpu || 0).toFixed(1) + "%"; color: Style.colors.subtle; Layout.preferredWidth: 60 }
        Text { text: Client.fmtBytes(modelData.ram || 0); color: Style.colors.subtle; Layout.preferredWidth: 70 }
        Button {
          text: "End"
          onClicked: confirmKill(modelData.pid, modelData.name, false)
        }
        Button {
          text: "Kill"
          onClicked: confirmKill(modelData.pid, modelData.name, true)
        }
      }
    }
  }

  function filteredProcesses() {
    var list = (root.snapshot.processes || []).slice();
    if (root.filter) {
      var f = root.filter.toLowerCase();
      list = list.filter(function(p) { return (p.name || "").toLowerCase().indexOf(f) >= 0; });
    }
    list.sort(function(a, b) { return (b[root.sortBy] || 0) - (a[root.sortBy] || 0); });
    return list.slice(0, 100);
  }

  function confirmKill(pid, name, force) {
    // QML confirm dialog; daemon only acts on explicit user action.
    killDialog.pid = pid;
    killDialog.procName = name;
    killDialog.force = force;
    killDialog.open();
  }

  Dialog {
    id: killDialog
    property int pid: 0
    property string procName: ""
    property bool force: false
    title: (force ? "Force kill " : "End ") + procName + " (" + pid + ")?"
    standardButtons: Dialog.Ok | Dialog.Cancel
    onAccepted: root.request({method: "kill", pid: killDialog.pid, signal: killDialog.force ? "kill" : "term"})
  }
}
