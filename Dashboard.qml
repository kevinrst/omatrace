import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "OmatraceClient.js" as Client

Item {
  id: root

  property var store: null

  property string tab: "cpu"
  property string filter: ""
  property int selectedPid: -1
  property string selectedGroup: ""
  // Group keys with their subprocess list expanded.
  property var expanded: ({})

  readonly property bool inProcess: root.selectedPid >= 0
  readonly property bool inApp: !root.inProcess && root.selectedGroup !== ""
  readonly property bool inDetail: root.inProcess || root.inApp
  // Chevron cell width, shared by the row layout and the hit test.
  readonly property real disclosureWidth: Style.space(16)

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color subtle: Color.muted

  readonly property var snap: (store && (store.selectedSnapshot || store.snapshot)) || Client.mockSnapshot()
  readonly property var sys: snap.system
  readonly property bool historyMode: store ? store.historyMode : false

  // System-wide chart series: raw values + daemon index per bar.
  readonly property var series: {
    if (!store) return {vals: [], idx: [], max: 100, labels: []}
    var h = (root.tab === "cpu" ? store.cpuHist
      : root.tab === "ram" ? store.ramHist
      : root.tab === "net" ? store.netHist : store.diskHist) || []
    var vals = h.map(function(p) { return p.v })
    var idx = h.map(function(p) { return p.idx })
    if (root.tab === "cpu") return finishCpu(vals, idx)
    if (root.tab === "ram") {
      var total = (store.snapshot && store.snapshot.system.ram_total) || 1
      return {vals: vals, idx: idx, max: total, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBytes(total * r) })}
    }
    var nm = Math.max(root.tab === "net" ? store.netMax : store.diskMax, 1)
    return {vals: vals, idx: idx, max: nm, labels: [1, 0.75, 0.5, 0.25].map(function(r) { return Client.fmtBps(nm * r) })}
  }

  // Selected process series (from proc_history points).
  readonly property var procSeries: {
    var pts = (store && store.procPoints) || []
    var vals = pts.map(function(p) {
      return root.tab === "cpu" ? p.cpu
        : root.tab === "ram" ? p.ram
        : root.tab === "net" ? p.net : p.disk
    })
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
    if (tab === "net") return Client.fmtBps(proc.net || 0)
    return Client.fmtBps(proc.disk || 0)
  }

  function fmtTime(ts) {
    var d = new Date(ts)
    function p(n) { return (n < 10 ? "0" : "") + n }
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
  }

  function open(tab) {
    if (tab) root.tab = tab
    root.selectedPid = -1
    root.selectedGroup = ""
    if (store) { store.clearProc(); store.backToLive() }
    window.visible = true
  }
  function close() { window.visible = false }

  function back() {
    if (root.inProcess) {
      root.selectedPid = -1
      if (root.selectedGroup) root.fetchGroupSeries()
      else if (store) store.clearProc()
    } else {
      root.selectedGroup = ""
      if (store) store.clearProc()
    }
  }

  function pruneSelection() {
    if (!root.inDetail || !store || store.historyMode) return
    if (root.inProcess && root.selectedProcess()) return
    if (!root.inProcess && root.selectedGroupData()) return
    if (root.inProcess && root.selectedGroup && root.selectedGroupData()) {
      root.back()
      return
    }
    root.selectedPid = -1
    root.selectedGroup = ""
    store.clearProc()
  }

  // Process grouping 
  function groupKey(p) {
    return p.exe_path ? "exe:" + p.exe_path : "name:" + (p.name || "?")
  }

  function metricOfSelf(p) {
    if (root.tab === "cpu") return p.self_cpu || 0
    if (root.tab === "ram") return p.self_ram || 0
    if (root.tab === "net") return p.self_net || 0
    return p.self_disk || 0
  }

  // The app's main process: the member whose parent is not in the group.
  function groupRoot(g) {
    var pids = {}
    for (var i = 0; i < g.members.length; i++) pids[g.members[i].pid] = true
    for (var j = 0; j < g.members.length; j++) {
      var m = g.members[j]
      if (!pids[m.parent_pid]) return m
    }
    return g.members[0]
  }

  function rootName(g) {
    var r = groupRoot(g)
    return (r && r.name) || g.key
  }

  function groupMatches(g) {
    var f = root.filter.toLowerCase()
    if (g.label.toLowerCase().indexOf(f) >= 0) return true
    for (var i = 0; i < g.members.length; i++) {
      if ((g.members[i].name || "").toLowerCase().indexOf(f) >= 0) {
        g.forced = true
        return true
      }
    }
    return false
  }

  function processGroups(applyFilter) {
    var list = ((snap && snap.processes) || [])
    var map = {}
    var keys = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      var k = groupKey(p)
      var g = map[k]
      if (!g) {
        g = {key: k, label: "", icon_path: "", members: [],
             cpu: 0, ram: 0, net: 0, disk: 0, forced: false}
        map[k] = g
        keys.push(k)
      }
      if (p.app_name) g.label = p.app_name
      if (!g.icon_path && p.icon_path) g.icon_path = p.icon_path
      g.members.push(p)
      g.cpu += p.self_cpu || 0
      g.ram += p.self_ram || 0
      g.net += p.self_net || 0
      g.disk += p.self_disk || 0
    }
    var out = []
    for (var j = 0; j < keys.length; j++) {
      var grp = map[keys[j]]
      if (!grp.label) grp.label = rootName(grp)
      if (applyFilter && root.filter && !groupMatches(grp)) continue
      out.push(grp)
    }
    return out
  }

  function selectedGroupData() {
    if (!root.selectedGroup) return null
    var gs = root.processGroups(false)
    for (var i = 0; i < gs.length; i++)
      if (gs[i].key === root.selectedGroup) return gs[i]
    return null
  }

  function selectGroup(key) {
    root.selectedGroup = key
    root.selectedPid = -1
    root.fetchGroupSeries()
  }

  function selectProcess(pid) {
    root.selectedPid = pid
    if (store) store.fetchProcHistory(pid)
  }

  function fetchGroupSeries() {
    var g = root.selectedGroupData()
    if (!g || !store) return
    var pids = []
    for (var i = 0; i < g.members.length; i++) pids.push(g.members[i].pid)
    store.fetchGroupHistory(pids, root.groupRoot(g).pid)
  }

  // An app's processes: its main process first, then by the active metric.
  function groupMemberRows() {
    var g = root.selectedGroupData()
    if (!g) return []
    var mainPid = root.groupRoot(g).pid
    var ms = g.members.slice()
    ms.sort(function(a, b) {
      if ((a.pid === mainPid) !== (b.pid === mainPid)) return a.pid === mainPid ? -1 : 1
      return root.metricOfSelf(b) - root.metricOfSelf(a)
    })
    var rows = []
    for (var i = 0; i < ms.length; i++) {
      var m = ms[i]
      rows.push({pid: m.pid, label: m.name, icon_path: m.icon_path, main: m.pid === mainPid,
                 cpu: m.self_cpu || 0, ram: m.self_ram || 0, net: m.self_net || 0, disk: m.self_disk || 0})
    }
    return rows
  }

  function isOpen(g) {
    return g.members.length > 1 && (g.forced || root.expanded[g.key] === true)
  }

  function toggleGroup(key) {
    var e = {}
    for (var k in root.expanded) e[k] = root.expanded[k]
    e[key] = !(e[key] === true)
    root.expanded = e
  }

  // The chevron's strip discloses a group; the rest of the row opens it.
  function rowIndent(modelData) {
    return modelData.kind === "proc" ? Style.space(12) : 0
  }

  function rowHit(modelData, x) {
    return modelData.kind === "group" && modelData.count > 1
        && x <= root.rowIndent(modelData) + root.disclosureWidth
  }

  function activateRow(modelData, x) {
    if (root.rowHit(modelData, x)) {
      root.toggleGroup(modelData.key)
    } else if (modelData.kind === "group" && modelData.count > 1) {
      root.selectGroup(modelData.key)
    } else if (modelData.pid >= 0) {
      root.selectProcess(modelData.pid)
    }
  }

  function processRows() {
    var groups = processGroups(true)
    var k = root.tab
    groups.sort(function(a, b) { return (b[k] || 0) - (a[k] || 0) })
    groups = groups.slice(0, 40)
    var rows = []
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      var multi = g.members.length > 1
      var open = isOpen(g)
      rows.push({kind: "group", key: g.key, label: g.label, icon_path: g.icon_path,
                 pid: multi ? -1 : g.members[0].pid, count: g.members.length, expanded: open,
                 cpu: g.cpu, ram: g.ram, net: g.net, disk: g.disk})
      if (!open) continue
      var members = g.members.slice()
      members.sort(function(a, b) { return root.metricOfSelf(b) - root.metricOfSelf(a) })
      for (var j = 0; j < members.length; j++) {
        var m = members[j]
        rows.push({kind: "proc", key: "pid:" + m.pid, label: m.name, icon_path: m.icon_path,
                   pid: m.pid, count: 1, expanded: false,
                   cpu: m.self_cpu || 0, ram: m.self_ram || 0, net: m.self_net || 0, disk: m.self_disk || 0})
      }
    }
    return rows
  }

  function selectedProcess() {
    if (root.selectedPid < 0) return null
    var list = (snap && snap.processes) || []
    for (var i = 0; i < list.length; i++)
      if (list[i].pid === root.selectedPid) return list[i]
    return null
  }

  // Detail header/metadata for whichever view is open.
  function detailTitle() {
    if (root.inApp) {
      var g = root.selectedGroupData()
      return g ? g.label : "app"
    }
    var p = root.selectedProcess()
    return p ? p.name : ("PID " + root.selectedPid)
  }

  function detailIcon() {
    if (root.inApp) {
      var g = root.selectedGroupData()
      return g ? g.icon_path : ""
    }
    var p = root.selectedProcess()
    return p ? p.icon_path : ""
  }

  function detailMetrics() {
    if (root.inApp) {
      var g = root.selectedGroupData()
      if (!g) return ""
      return "CPU " + g.cpu.toFixed(1) + "%    RAM " + Client.fmtBytes(g.ram)
        + "    NET " + Client.fmtBps(g.net) + "    DISK " + Client.fmtBps(g.disk)
    }
    var p = root.selectedProcess()
    if (!p) return ""
    return "CPU " + (p.cpu || 0).toFixed(1) + "%    RAM " + Client.fmtBytes(p.ram || 0)
      + "    NET " + Client.fmtBps(p.net || 0) + "    DISK " + Client.fmtBps(p.disk || 0)
  }

  // What End and Kill act on; the app's main process leads the list.
  function killTarget() {
    if (root.inApp) {
      var g = root.selectedGroupData()
      if (!g) return null
      var pids = [root.groupRoot(g).pid]
      for (var i = 0; i < g.members.length; i++)
        if (g.members[i].pid !== pids[0]) pids.push(g.members[i].pid)
      return {pids: pids, name: g.label}
    }
    if (root.selectedPid < 0) return null
    var p = root.selectedProcess()
    return {pids: [root.selectedPid], name: p ? p.name : ("PID " + root.selectedPid)}
  }

  function confirmKill(force) {
    var t = root.killTarget()
    if (!t) return
    killDialog.pids = t.pids
    killDialog.procName = t.name
    killDialog.force = force
    killDialog.opened = true
  }

  function killMessage() {
    var pids = killDialog.pids
    var verb = killDialog.force ? "Force kill " : "End "
    if (pids.length <= 1) return verb + killDialog.procName + " (" + (pids[0] || 0) + ")?"
    if (pids.length === 2) return verb + killDialog.procName + " and 1 other process?"
    return verb + killDialog.procName + " and its " + (pids.length - 1) + " other processes?"
  }

  Connections {
    target: root.store
    function onSnapshotChanged() { root.pruneSelection() }
    function onHistoryModeChanged() { root.pruneSelection() }
    function onKilled(count) { if (count > 0) root.back() }
  }

  // KPI tiles: whole-system numbers, or the selection's when a view is open.
  readonly property var kpiTiles: {
    var net = (sys && sys.net) || {}
    var disk = (sys && sys.disk) || {}
    if (root.inDetail) {
      var g = root.inApp ? root.selectedGroupData() : null
      var p = root.inProcess ? root.selectedProcess() : null
      var s = g || p
      if (!s) return []
      return [
        {label: "CPU", value: (s.cpu || 0).toFixed(1) + "%", sub: p ? "PID " + p.pid : g.members.length + " PROCESSES"},
        {label: "MEMORY", value: Client.fmtBytes(s.ram || 0), sub: p ? "SELF RSS" : "SUM OF SELF"},
        {label: "NETWORK", value: Client.fmtBps(s.net || 0), sub: "EST. SHARE"},
        {label: "DISK I/O", value: Client.fmtBps(s.disk || 0), sub: "OWN I/O"}
      ]
    }
    return [
      {label: "CPU", value: (sys.cpu_percent || 0).toFixed(0) + "%", sub: "LOAD " + (sys.load_avg_1 || 0).toFixed(2)},
      {label: "MEMORY", value: Client.fmtBytes(sys.ram_used || 0), sub: "/ " + Client.fmtBytes((sys && sys.ram_total) || 1)},
      {label: "NETWORK", value: Client.fmtBps(net.down_bps || 0), sub: "↑ " + Client.fmtBps(net.up_bps || 0)},
      {label: "DISK I/O", value: Client.fmtBps(disk.read_bps || 0), sub: "↑ " + Client.fmtBps(disk.write_bps || 0)}
    ]
  }

  function tabLabel(t) {
    return t === "cpu" ? "CPU" : t === "ram" ? "RAM" : t === "net" ? "NETWORK" : "DISK I/O"
  }

  // Header meta lines for the detail view: count/identity on the first
  // line, then the start time before the path so long paths elide and
  // the time always stays visible.
  readonly property string metaLine1: {
    if (!root.inDetail) return ""
    if (root.inApp) {
      var g = root.selectedGroupData()
      var r = g ? root.groupRoot(g) : null
      return g ? g.members.length + " PROCESSES · MAIN PID " + r.pid : ""
    }
    var p = root.selectedProcess()
    return p ? "PID " + p.pid : "PROCESS EXITED"
  }
  readonly property string metaLine2: {
    var r = null
    if (root.inApp) {
      var g = root.selectedGroupData()
      r = g ? root.groupRoot(g) : null
    } else {
      r = root.selectedProcess()
    }
    if (!r) return ""
    var t = r.started_at ? "STARTED " + Client.fmtDateTime(r.started_at * 1000).toUpperCase() : ""
    if (r.exe_path) t += (t ? "  ·  " : "") + r.exe_path
    return t
  }

  FloatingWindow {
    id: window
    title: "Omatrace"
    visible: false 
    color: root.background
    implicitWidth: 680
    implicitHeight: 640
    minimumSize: Qt.size(600, 500)

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (killDialog.opened) {
          if (killDialog.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (root.inDetail) root.back()
          else root.close()
          event.accepted = true
        }
      }

      // Window frame — same border spec as the popup cards.
      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: Color.popups.border
        radius: Style.cornerRadius
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // Header: back button and the selected app/process.
        RowLayout {
          Layout.fillWidth: true
          visible: root.inDetail
          spacing: Style.space(8)
          Button {
            visible: root.inDetail
            text: "‹ Back"
            fontSize: Style.font.caption
            onClicked: root.back()
          }
          Image {
            visible: root.inDetail && root.detailIcon() !== ""
            source: root.inDetail && root.detailIcon() ? "file://" + encodeURI(root.detailIcon()) : ""
            sourceSize.width: 48
            sourceSize.height: 48
            Layout.preferredWidth: 20
            Layout.preferredHeight: 20
            smooth: true
            asynchronous: true
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              text: root.detailTitle()
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              visible: text !== ""
              text: root.metaLine1
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              elide: Text.ElideRight
              visible: text !== ""
              text: root.metaLine2
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Tabs: one segmented pill per metric. While scrubbing history,
        // the snapshot time sits on the right with a button back to live.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)
          Repeater {
            model: [["cpu", "CPU"], ["ram", "Memory"], ["net", "Network"], ["disk", "Disk"]]
            // Outlined pill; the selected tab uses the theme accent.
            delegate: MouseArea {
              required property var modelData
              readonly property bool active: root.tab === modelData[0]
              implicitWidth: pillLabel.implicitWidth + Style.space(10) * 2
              implicitHeight: pillLabel.implicitHeight + Style.space(6) * 2
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.tab = modelData[0]

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: parent.pressed ? Style.pressedFillFor(root.foreground, Color.accent)
                  : parent.active ? Style.selectedAccentFill
                  : parent.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent)
                  : "transparent"
                border.width: 1
                border.color: parent.active ? Color.accent
                  : parent.containsMouse ? Style.hoverBorderFor(root.foreground, Color.accent)
                  : Style.normalBorderFor(root.foreground, Color.accent)
              }
              Text {
                id: pillLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData[1]
                color: parent.active ? Color.accent : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
          Item { Layout.fillWidth: true }
          Row {
            visible: root.historyMode
            spacing: Style.space(6)
            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmtTime(snap.ts_ms)
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Button {
              text: "Live"
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              onClicked: { if (store) store.backToLive() }
            }
          }
        }

        // Chart
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 196
          color: "transparent"
          radius: Style.cornerRadius
          clip: true

          Bars {
            anchors.fill: parent
            anchors.margins: 12
            values: root.inDetail ? root.procSeries.vals : root.series.vals
            max: root.inDetail ? root.procSeries.max : root.series.max
            yLabels: root.inDetail ? root.procSeries.labels : root.series.labels
            selectedIndex: store ? store.selectedPos : -1
            interactive: !root.inDetail
            onBarClicked: function(pos) {
              if (!store) return
              if (pos === store.selectedPos) store.backToLive()
              else if (root.series.idx[pos] !== undefined)
                store.fetchIndex(root.series.idx[pos], pos)
            }
            onBackgroundClicked: { if (store) store.backToLive() }
          }
        }

        // KPI tiles: whole system, or the selection when a view is open.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Repeater {
            model: root.kpiTiles
            delegate: Rectangle {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredHeight: 64
              radius: Style.cornerRadius
              color: Style.normalFillFor(root.foreground, Color.accent)
              border.width: 1
              border.color: Util.alpha(root.foreground, 0.06)
              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: 1
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.subtle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                  Layout.fillWidth: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.value
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.display
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Text {
                  visible: modelData.sub !== ""
                  textFormat: Text.PlainText
                  text: modelData.sub
                  color: root.subtle
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        // ---- Process list view ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 8
          visible: !root.inDetail

          TextField {
            Layout.fillWidth: true
            placeholderText: "Filter apps…"
            onTextChanged: root.filter = text
          }

          Item {
            Layout.fillWidth: true
            implicitHeight: Math.max(listHeader.implicitHeight, listValue.implicitHeight)
            PanelSectionHeader {
              id: listHeader
              text: "PROCESS"
              foreground: root.foreground
              fontFamily: Style.font.family
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: listValue
              textFormat: Text.PlainText
              text: root.tabLabel(root.tab)
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "transparent"
            radius: Style.cornerRadius

            ListView {
              anchors.fill: parent
              anchors.margins: 8
              clip: true
              model: root.processRows()
              delegate: MouseArea {
                required property var modelData
                width: ListView.view.width - 16
                height: listRow.implicitHeight + Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) { root.activateRow(modelData, mouse.x) }

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: Style.hoverFillFor(root.foreground, Color.accent)
                  opacity: parent.containsMouse ? 1 : 0
                }

                RowLayout {
                  id: listRow
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  Item {
                    Layout.preferredWidth: root.disclosureWidth
                    Layout.leftMargin: root.rowIndent(modelData)
                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      visible: modelData.kind === "group" && modelData.count > 1
                      text: modelData.expanded ? "󰅀" : "󰅂"
                      color: root.subtle
                      font.family: Style.font.family
                      font.pixelSize: 12
                    }
                  }
                  Image {
                    source: modelData.icon_path ? "file://" + encodeURI(modelData.icon_path) : ""
                    sourceSize.width: 32
                    sourceSize.height: 32
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    opacity: modelData.kind === "group" ? 1.0 : 0.55
                    smooth: true
                    asynchronous: true
                    cache: true
                  }
                  TextMetrics {
                    id: nameMetrics
                    font.family: Style.font.family
                    text: modelData.label
                    font.pixelSize: modelData.kind === "group" ? Style.font.body : Style.font.bodySmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: modelData.kind === "group" ? root.foreground : root.subtle
                    font.family: Style.font.family
                    font.pixelSize: modelData.kind === "group" ? Style.font.body : Style.font.bodySmall
                    Layout.fillWidth: true
                    Layout.maximumWidth: nameMetrics.advanceWidth + 4
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: modelData.kind === "group" && modelData.count > 1
                    text: "×" + modelData.count
                    color: root.subtle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignVCenter
                  }
                  Item {
                    Layout.fillWidth: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.fmtVal(root.tab, modelData)
                    color: root.subtle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    Layout.preferredWidth: 72
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }
            }
          }
        }

        // ---- Detail view: an app or a single process ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(6)
          visible: root.inDetail

          Item {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(8)
            visible: root.inApp
            implicitHeight: Math.max(memberHeader.implicitHeight, memberValue.implicitHeight)
            PanelSectionHeader {
              id: memberHeader
              text: "PROCESSES"
              foreground: root.foreground
              fontFamily: Style.font.family
              anchors.left: parent.left
              anchors.leftMargin: 8
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: memberValue
              textFormat: Text.PlainText
              text: root.tabLabel(root.tab)
              color: root.subtle
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.inApp
            color: "transparent"
            radius: Style.cornerRadius

            ListView {
              anchors.fill: parent
              anchors.margins: 8
              clip: true
              model: root.groupMemberRows()
              delegate: MouseArea {
                required property var modelData
                width: ListView.view.width - 16
                height: memberRow.implicitHeight + Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectProcess(modelData.pid)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: Style.hoverFillFor(root.foreground, Color.accent)
                  opacity: parent.containsMouse ? 1 : 0
                }

                RowLayout {
                  id: memberRow
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  Image {
                    source: modelData.icon_path ? "file://" + encodeURI(modelData.icon_path) : ""
                    sourceSize.width: 32
                    sourceSize.height: 32
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    Layout.alignment: Qt.AlignVCenter
                    opacity: 0.55
                    smooth: true
                    asynchronous: true
                    cache: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }
                  // Keeps its width when hidden so the columns stay aligned.
                  Item {
                    Layout.preferredWidth: 44
                    // MAIN chip, only on the app's main process.
                    Rectangle {
                      visible: modelData.main
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: mainTag.implicitWidth + Style.space(8)
                      height: mainTag.implicitHeight + Style.space(3)
                      radius: 3
                      color: Style.selectedAccentFill
                      Text {
                        id: mainTag
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "MAIN"
                        color: Color.accent
                        font.family: Style.font.family
                        font.pixelSize: Math.max(9, Style.font.caption - 2)
                        font.bold: true
                        font.letterSpacing: 1
                      }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.pid
                    color: root.subtle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    Layout.preferredWidth: 48
                    horizontalAlignment: Text.AlignRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.fmtVal(root.tab, modelData)
                    color: root.subtle
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    Layout.preferredWidth: 72
                    horizontalAlignment: Text.AlignRight
                  }
                }
              }
            }
          }

          Item { Layout.fillWidth: true; Layout.fillHeight: true; visible: !root.inApp }

          RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
              text: "End"
              onClicked: root.confirmKill(false)
            }
            Button {
              text: "Kill"
              foreground: Color.urgent
              onClicked: root.confirmKill(true)
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: killDialog
      // Without anchors the dialog is zero-sized and never shows.
      anchors.fill: parent
      property var pids: []
      property string procName: ""
      property bool force: false
      message: root.killMessage()
      confirmText: killDialog.force ? "Kill" : "End"
      onCanceled: killDialog.opened = false
      onConfirmed: {
        killDialog.opened = false
        if (root.store) root.store.kill(killDialog.pids, killDialog.force)
      }
    }
  }
}
