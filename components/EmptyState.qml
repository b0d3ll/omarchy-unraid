import QtQuick
import qs.Commons

// Centered "nothing here" message — no Docker containers, no VMs, no
// alerts (spec section 49).
Item {
  id: root

  property string message: ""
  property color foreground: Color.foreground

  implicitHeight: label.implicitHeight + Style.space(24)

  Text {
    id: label
    anchors.centerIn: parent
    width: parent.width - Style.space(24)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: root.message
    color: Qt.darker(root.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
}
