import QtQuick
import qs.Commons
import qs.Ui

// Actionable error message with an optional retry/settings action (spec
// section 44) — "Docker status unavailable", "API key rejected", etc.
Item {
  id: root

  property string title: ""
  property string message: ""
  property string actionLabel: ""
  property color foreground: Color.foreground

  signal actionTriggered()

  implicitHeight: column.implicitHeight + Style.space(20)

  Column {
    id: column
    anchors.centerIn: parent
    width: parent.width - Style.space(24)
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.title
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: root.message !== ""
      text: root.message
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Button {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.actionLabel !== ""
      bordered: true
      text: root.actionLabel
      foreground: root.foreground
      onClicked: root.actionTriggered()
    }
  }
}
