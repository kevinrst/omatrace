import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "OmatraceClient.js" as Client

Panel {
  id: root
  moduleName: "kevin.omatrace"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var store: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    if (store) store.pollLatest()
    root.controller.show()
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function openDashboard(tab) {
    root.close()
    if (hostWidget && typeof hostWidget.openDashboard === "function")
      hostWidget.openDashboard(tab)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(340)
    contentHeight: panel.fittedContentHeight(innerColumn.implicitHeight + Style.space(16) * 2)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: innerColumn
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(10)

        // Metric rows (preview only — no header)
        Repeater {
          model: [
            {tab: "cpu", label: "CPU", value: store && store.snapshot ? Math.round(store.snapshot.system.cpu_percent) + "%" : "—", hist: store ? store.cpuHist : [], max: 100},
            {tab: "ram", label: "MEMORY", value: store && store.snapshot ? Client.fmtBytes(store.snapshot.system.ram_used) : "—", hist: store ? store.ramHist : [], max: store && store.snapshot ? store.snapshot.system.ram_total : 1},
            {tab: "net", label: "NETWORK", value: store && store.snapshot && store.snapshot.system.net ? Client.fmtBps(store.snapshot.system.net.down_bps + store.snapshot.system.net.up_bps) : "—", hist: store ? store.netHist : [], max: store ? Math.max(store.netMax, 1) : 1},
            {tab: "disk", label: "DISK I/O", value: store && store.snapshot && store.snapshot.system.disk ? Client.fmtBps(store.snapshot.system.disk.read_bps + store.snapshot.system.disk.write_bps) : "—", hist: store ? store.diskHist : [], max: store ? Math.max(store.diskMax, 1) : 1}
          ]
          delegate: Item {
            required property var modelData
            width: parent.width
            height: 62

            Row {
              anchors.fill: parent
              anchors.rightMargin: 12
              spacing: 12

              Column {
                width: 118
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Color.muted
                  font.family: root.contentFontFamily
                  font.pixelSize: 11
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.value
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: 21
                  font.bold: true
                }
              }

              Bars {
                width: parent.width - 130
                height: 62
                values: modelData.hist.map(function(p) { return p.v })
                max: modelData.max
                showLabels: false
                miniBars: 30
                interactive: false
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openDashboard(modelData.tab)
            }
          }
        }

        // Disk footer (capacity only)
        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: store && store.snapshot ? ("DISK  " + Client.fmtBytes(store.snapshot.system.disk.used) + " / " + Client.fmtBytes(store.snapshot.system.disk.total)) : "DISK  —"
          color: Color.muted
          font.family: root.contentFontFamily
          font.pixelSize: 11
        }
      }
    }
  }
}
