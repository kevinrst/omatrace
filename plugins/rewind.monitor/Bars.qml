import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var values: [] // raw numbers
  property real max: 100
  property var yLabels: ["100%", "75%", "50%", "25%"]
  property int selectedIndex: -1 // -1 = live, nothing dimmed
  property bool interactive: false
  property bool showLabels: true
  property int miniBars: 0 // >0: show only last N values (sparklines)

  signal barClicked(int pos)
  signal backgroundClicked()

  readonly property var _vals: values || []
  readonly property var shown: miniBars > 0 ? _vals.slice(-miniBars) : _vals
  readonly property int offset: _vals.length - shown.length

  Row {
    anchors.fill: parent
    spacing: 0

    // Y labels
    Column {
      width: root.showLabels ? 44 : 0
      visible: root.showLabels
      height: parent.height
      Repeater {
        model: root.yLabels
        delegate: Text {
          required property string modelData
          text: modelData
          textFormat: Text.PlainText
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: 10
          width: 44
          height: root.height / root.yLabels.length
          verticalAlignment: Text.AlignTop
        }
      }
    }

    // Bars area
    Item {
      id: area
      width: parent.width - (root.showLabels ? 48 : 0)
      height: parent.height

      // Grid lines, evenly spaced (full chart only — minis stay clean)
      Repeater {
        model: root.showLabels ? root.yLabels.length : 0
        delegate: Rectangle {
          required property int index
          x: 0
          y: Math.round(index * area.height / root.yLabels.length)
          width: area.width
          height: 1
          color: Color.muted
          opacity: 0.25
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.interactive
        onClicked: root.backgroundClicked()
      }

      Row {
        anchors.fill: parent
        spacing: 2

        Repeater {
          id: rep
          model: root.shown
          delegate: Item {
            required property var modelData
            required property int index
            readonly property int pos: root.offset + index
            readonly property real pct: Math.min(100, Math.max((modelData / Math.max(root.max, 1)) * 100, 1.5))
            readonly property bool dimmed: root.selectedIndex >= 0 && root.selectedIndex !== pos
            readonly property bool selected: root.selectedIndex === pos

            width: Math.max(2, (area.width - (rep.count - 1) * 2) / Math.max(rep.count, 1))
            height: area.height
            opacity: dimmed ? 0.28 : 1.0

            // Bottom-anchored bar. Only the bar itself is clickable —
            // empty space above falls through to the background MouseArea.
            Item {
              id: barVisual
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: parent.height * pct / 100

              Rectangle { // soft bottom (70%)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: parent.height * 0.7
                color: Color.accent
                opacity: 0.25
              }
              Rectangle { // bright top (30%)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: parent.height * 0.3
                radius: 2
                color: Color.accent
                opacity: selected ? 1.0 : 0.9
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.interactive
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) { mouse.accepted = true; root.barClicked(pos) }
              }
            }
          }
        }
      }
    }
  }
}
