import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omatrace bar widget: single icon. Click toggles the metrics popup
// anchored to the icon; metric rows open the centered dashboard.
BarWidget {
  id: root
  moduleName: "kevin.omatrace"

  readonly property string iconGlyph: ""

  readonly property bool opened: popupLoader.item ? popupLoader.item.opened === true : false

  function open() { if (popupLoader.item) popupLoader.item.open() }
  function close() { if (popupLoader.item) popupLoader.item.close() }
  function togglePanel() { if (popupLoader.item) popupLoader.item.toggle() }

  function openDashboard(tab) {
    if (dashboard.item) dashboard.item.open(tab)
  }

  function injectPanel() {
    var target = popupLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("store" in target) target.store = store
  }

  function injectDashboard() {
    var target = dashboard.item
    if (!target) return
    if ("store" in target) target.store = store
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  OmatraceData {
    id: store
  }

  Loader {
    id: popupLoader
    active: true
    source: Qt.resolvedUrl("Popup.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Loader {
    id: dashboard
    active: true
    source: Qt.resolvedUrl("Dashboard.qml")
    visible: false
    onLoaded: {
      root.injectDashboard()
      Qt.callLater(root.injectDashboard)
    }
  }

  IpcHandler {
    target: "kevin.omatrace"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
