import QtQuick
import qs.Commons

// Horizontal capacity/progress bar used for CPU, RAM, storage, and parity
// progress (spec sections 10, 12, 13, 25).
Item {
  id: root

  property real value: 0 // 0..100
  property color trackColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
  property color fillColor: Color.accent
  property real barHeight: Style.space(8)

  implicitHeight: barHeight
  implicitWidth: Style.space(200)

  Rectangle {
    id: track
    anchors.fill: parent
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    radius: height / 2
    width: track.width * Math.max(0, Math.min(100, root.value)) / 100
    color: root.fillColor

    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
  }
}
