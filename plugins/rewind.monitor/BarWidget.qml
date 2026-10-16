import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "RewindClient.js" as Client

// Compact bar widget: CPU% + RAM% + sparkline. Click opens dashboard panel.
BarWidget {
  id: root
  moduleName: "rewind.monitor"

  property real cpu: 0
  property real ram: 0
  property var cpuHist: []
  property bool offline: true

  implicitWidth: row.implicitWidth + 16
  implicitHeight: 28

  Socket {
    id: sock
    path: "/run/user/1000/rewind.sock"
    connected: true
    onConnectionStateChanged: root.offline = (sock.connectionState !== Socket.Connected)
  }

  function poll() {
    if (sock.connectionState === Socket.Connected) {
      sock.write('{"method":"latest"}\n');
    } else {
      root.offline = true;
    }
  }

  Connections {
    target: sock
    function onDataReceived() {
      var chunk = sock.readAll();
      var lines = chunk.split("\n");
      for (var i in lines) {
        if (!lines[i]) continue;
        try {
          var msg = JSON.parse(lines[i]);
          if (msg.snapshot && msg.snapshot.system) {
            root.cpu = msg.snapshot.system.cpu_percent;
            var rt = msg.snapshot.system.ram_total || 1;
            root.ram = msg.snapshot.system.ram_used / rt * 100;
            root.offline = false;
          }
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 2000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.poll()
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 8
    Text {
      text: "◉ " + Math.round(root.cpu) + "%  " + Math.round(root.ram) + "%"
      color: root.offline ? Style.colors.subtle : Style.colors.text
      font.pixelSize: 12
    }
  }

  MouseArea {
    anchors.fill: parent
    onClicked: Quickshell.ipc.call("omarchy.shell", "summon", { target: "rewind.monitor", args: {} })
    ToolTip.text: root.offline ? "Rewind offline — click to open" : "Rewind — click for timeline"
  }
}
