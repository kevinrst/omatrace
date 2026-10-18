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
  readonly property color dim: Qt.darker(contentForeground, 1.5)

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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(innerColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // The content holder is already inset by the card padding, so the
      // column fills it directly.
      Column {
        id: innerColumn
        anchors.fill: parent
        spacing: Style.space(8)

        // One metric per row: label + value, sparkline underneath. Hover
        // wash signals the row is a button into the dashboard.
        Repeater {
          model: [
            {tab: "cpu", label: "CPU", value: store && store.snapshot ? Math.round(store.snapshot.system.cpu_percent) + "%" : "—", hist: store ? store.cpuHist : [], max: 100},
            {tab: "ram", label: "MEMORY", value: store && store.snapshot ? Client.fmtBytes(store.snapshot.system.ram_used) : "—", hist: store ? store.ramHist : [], max: store && store.snapshot ? store.snapshot.system.ram_total : 1},
            {tab: "net", label: "NETWORK", value: store && store.snapshot && store.snapshot.system.net ? Client.fmtBps(store.snapshot.system.net.down_bps + store.snapshot.system.net.up_bps) : "—", hist: store ? store.netHist : [], max: store ? Math.max(store.netMax, 1) : 1},
            {tab: "disk", label: "DISK I/O", value: store && store.snapshot && store.snapshot.system.disk ? Client.fmtBps(store.snapshot.system.disk.read_bps + store.snapshot.system.disk.write_bps) : "—", hist: store ? store.diskHist : [], max: store ? Math.max(store.diskMax, 1) : 1}
          ]
          delegate: MouseArea {
            id: metricRow
            required property var modelData
            width: parent.width
            height: metricLabel.implicitHeight + Style.space(6) + spark.height + Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openDashboard(modelData.tab)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.contentForeground, Color.accent)
              opacity: metricRow.containsMouse ? 1 : 0
            }

            Column {
              id: metricBody
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)

              Item {
                width: parent.width
                height: Math.max(metricLabel.implicitHeight, metricValue.implicitHeight)
                Text {
                  id: metricLabel
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: metricRow.modelData.label
                  color: root.dim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
                Text {
                  id: metricValue
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: metricRow.modelData.value
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
              }
              Item { width: parent.width; height: Style.space(6) }
              Bars {
                id: spark
                width: parent.width
                height: 30
                values: metricRow.modelData.hist.map(function(p) { return p.v })
                max: metricRow.modelData.max
                showLabels: false
                miniBars: 30
                interactive: false
              }
            }
          }
        }
      }
    }
  }
}
