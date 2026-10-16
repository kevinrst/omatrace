import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "RewindClient.js" as Client

Item {
  id: root

  property var store: null

  property string tab: "cpu"
  property string filter: ""
  property int selectedPid: -1

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color subtle: Color.muted
  readonly property color cardBorder: Util.alpha(Color.foreground, 0.1)

  readonly property var snap: (store && (store.selectedSnapshot || store.snapshot)) || Client.mockSnapshot()
  readonly property var sys: snap.system
  readonly property bool historyMode: store ? store.historyMode : false

  // System-wide chart series: raw values + daemon index per bar.
  readonly property var series: {
    if (!store) return {vals: [], idx: [], max: 100, labels: []}
    var h = (root.tab === "cpu" ? store.cpuHist : (root.tab === "ram" ? store.ramHist : store.netHist)) || []
    var vals = h.map(function(p) { return p.v })
    var idx = h.map(function(p) { return p.idx })
    if (root.tab === "cpu") return finishCpu(vals, idx)
    if (root.tab === "ram") {
      var total = (store.snapshot && store.snapshot.system.ram_total) || 1
      return {vals: vals, idx: idx, max: total, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBytes(total * r) })}
    }
    var nm = Math.max(store.netMax, 1)
    return {vals: vals, idx: idx, max: nm, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBps(nm * r) })}
  }

  // Selected process series (from proc_history points).
  readonly property var procSeries: {
    var pts = (store && store.procPoints) || []
    var vals = pts.map(function(p) { return root.tab === "cpu" ? p.cpu : (root.tab === "ram" ? p.ram : p.net) })
    if (root.tab === "cpu") return finishCpu(vals, [])
    if (root.tab === "ram") {
      var total = (store && store.snapshot && store.snapshot.system.ram_total) || 1
      return {vals: vals, idx: [], max: total, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBytes(total * r) })}
    }
    var nm = 1
    for (var i = 0; i < vals.length; i++) nm = Math.max(nm, vals[i])
    return {vals: vals, idx: [], max: nm, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBps(nm * r) })}
  }

  function finishCpu(vals, idx) {
    var peak = 1
    for (var i = 0; i < vals.length; i++) peak = Math.max(peak, vals[i])
    var ceil = Math.min(100, Math.ceil(peak * 1.2 / 10) * 10)
    return {vals: vals, idx: idx, max: ceil, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Math.round(ceil * r) + "%" })}
  }

  function fmtVal(tab, proc) {
    if (tab === "cpu") return (proc.cpu || 0).toFixed(1) + "%"
    if (tab === "ram") return Client.fmtBytes(proc.ram || 0)
    return Client.fmtBps(proc.net || 0)
  }

  function fmtTime(ts) {
    var d = new Date(ts)
    function p(n) { return (n < 10 ? "0" : "") + n }
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
  }

  function open(tab) {
    if (tab) root.tab = tab
    root.selectedPid = -1
    if (store) { store.clearProc(); store.backToLive() }
    window.visible = true
  }
  function close() { window.visible = false }

  function filteredProcesses() {
    var list = ((snap && snap.processes) || []).slice()
    if (root.filter) {
      var f = root.filter.toLowerCase()
      list = list.filter(function(p) { return (p.name || "").toLowerCase().indexOf(f) >= 0 })
    }
    var k = root.tab
    list.sort(function(a, b) { return (b[k] || 0) - (a[k] || 0) })
    return list.slice(0, 100)
  }

  function selectedProcess() {
    if (root.selectedPid < 0) return null
    var list = (snap && snap.processes) || []
    for (var i = 0; i < list.length; i++)
      if (list[i].pid === root.selectedPid) return list[i]
    return null
  }

  function selectProcess(pid) {
    root.selectedPid = pid
    if (store) store.fetchProcHistory(pid)
  }

  function confirmKill(pid, name, force) {
    killDialog.pid = pid
    killDialog.procName = name
    killDialog.force = force
    killDialog.opened = true
  }

  FloatingWindow {
    id: window
    title: "Rewind"
    color: root.background
    implicitWidth: 780
    implicitHeight: 640
    minimumSize: Qt.size(600, 500)

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.selectedPid >= 0) root.selectedPid = -1
          else root.close()
          event.accepted = true
        }
      }

      // Window outline — same spec as the popup border.
      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: Color.popups.border
        radius: Style.cornerRadius
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        // Top row: back button in detail view, timestamp in history
        // mode. Hidden entirely when empty — no dead space.
        RowLayout {
          Layout.fillWidth: true
          Layout.preferredHeight: 36
          visible: root.selectedPid >= 0 || root.historyMode
          Button {
            text: "‹ Back"
            visible: root.selectedPid >= 0
            onClicked: { root.selectedPid = -1; if (store) store.clearProc() }
          }
          Item { Layout.fillWidth: true; visible: root.selectedPid >= 0 }
          Text {
            textFormat: Text.PlainText
            visible: root.historyMode
            text: root.historyMode ? root.fmtTime(snap.ts_ms) : ""
            color: root.subtle
            font.family: Style.font.family
            font.pixelSize: 12
          }
        }

        // Tabs (Kova pill style)
        RowLayout {
          Layout.alignment: Qt.AlignHCenter
          Layout.preferredHeight: 36
          spacing: 4
          Repeater {
            model: [["cpu", "CPU"], ["ram", "Memory"], ["net", "Network"]]
            delegate: Button {
              required property var modelData
              text: modelData[1]
              onClicked: root.tab = modelData[0]
            }
          }
        }

        // Chart card
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 196
          color: "transparent"
          border.width: 1
          border.color: root.cardBorder
          radius: Style.cornerRadius
          clip: true

          Bars {
            anchors.fill: parent
            anchors.margins: 12
            values: root.selectedPid < 0 ? root.series.vals : root.procSeries.vals
            max: root.selectedPid < 0 ? root.series.max : root.procSeries.max
            yLabels: root.selectedPid < 0 ? root.series.labels : root.procSeries.labels
            selectedIndex: store ? store.selectedPos : -1
            interactive: root.selectedPid < 0
            onBarClicked: function(pos) {
              if (!store) return
              if (pos === store.selectedPos) store.backToLive()
              else if (root.series.idx[pos] !== undefined)
                store.fetchIndex(root.series.idx[pos], pos)
            }
            onBackgroundClicked: { if (store) store.backToLive() }
          }
        }

        // Current values line
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: "CPU " + (sys.cpu_percent || 0).toFixed(0) + "%    "
            + "RAM " + Client.fmtBytes(sys.ram_used || 0) + " / " + Client.fmtBytes(sys.ram_total || 1) + "    "
            + "NET ↓" + Client.fmtBps((sys.net || {}).down_bps || 0) + " ↑" + Client.fmtBps((sys.net || {}).up_bps || 0) + "    "
            + "LOAD " + (sys.load_avg_1 || 0).toFixed(2)
          color: root.subtle
          font.family: Style.font.family
          font.pixelSize: 12
        }

        PanelSeparator {
          Layout.fillWidth: true
        }

        // ---- Process list view ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 8
          visible: root.selectedPid < 0

          TextField {
            Layout.fillWidth: true
            placeholderText: "Filter processes…"
            onTextChanged: root.filter = text
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "transparent"
            border.width: 1
            border.color: root.cardBorder
            radius: Style.cornerRadius

            ListView {
              anchors.fill: parent
              anchors.margins: 8
              clip: true
              model: root.filteredProcesses()
              delegate: MouseArea {
                required property var modelData
                width: ListView.view.width - 16
                height: row.height
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectProcess(modelData.pid)

                RowLayout {
                  id: row
                  width: parent.width
                  spacing: 8
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.fmtVal(root.tab, modelData)
                    color: root.subtle
                    font.family: Style.font.family
                    font.pixelSize: 12
                    Layout.preferredWidth: 72
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }
            }
          }
        }

        // ---- Process detail view ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 8
          visible: root.selectedPid >= 0

          RowLayout {
            Layout.fillWidth: true
            Text {
              textFormat: Text.PlainText
              text: root.selectedProcess() ? root.selectedProcess().name : ("PID " + root.selectedPid)
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: 15
              font.bold: true
              Layout.fillWidth: true
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: {
              var p = root.selectedProcess()
              if (!p) return "process exited"
              var s = "PID " + p.pid
              if (p.exe_path) s += "    " + p.exe_path
              if (p.started_at) s += "    started " + Client.fmtDateTime(p.started_at * 1000)
              return s
            }
            color: root.subtle
            font.family: Style.font.family
            font.pixelSize: 11
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: {
              var p = root.selectedProcess()
              if (!p) return ""
              return "CPU " + (p.cpu || 0).toFixed(1) + "%    RAM " + Client.fmtBytes(p.ram || 0) + "    NET " + Client.fmtBps(p.net || 0)
            }
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: 13
          }

          Item { Layout.fillWidth: true; Layout.fillHeight: true }

          RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
              text: "End"
              onClicked: {
                var p = root.selectedProcess()
                root.confirmKill(root.selectedPid, p ? p.name : ("PID " + root.selectedPid), false)
              }
            }
            Button {
              text: "Kill"
              onClicked: {
                var p = root.selectedProcess()
                root.confirmKill(root.selectedPid, p ? p.name : ("PID " + root.selectedPid), true)
              }
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: killDialog
      property int pid: 0
      property string procName: ""
      property bool force: false
      message: (force ? "Force kill " : "End ") + procName + " (" + pid + ")?"
      confirmText: force ? "Kill" : "End"
      onCanceled: killDialog.opened = false
      onConfirmed: {
        killDialog.opened = false
        if (root.store && root.store.sock.connected)
          root.store.sock.write(JSON.stringify({method: "kill", pid: killDialog.pid, signal: killDialog.force ? "kill" : "term"}) + "\n")
      }
    }
  }
}
