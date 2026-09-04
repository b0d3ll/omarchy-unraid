import QtQuick
import qs.Commons
import qs.Ui

// Small pill label for discrete states — Docker/VM row state ("RUNNING",
// "EXITED"), alert importance, etc. (spec sections 15, 21, 27).
BorderSurface {
  id: root

  property string text: ""
  property color foreground: Color.foreground
  property bool emphasized: false

  implicitWidth: label.implicitWidth + Style.space(16)
  implicitHeight: label.implicitHeight + Style.space(6)
  radius: height / 2
  color: emphasized ? Style.selectedFillFor(foreground, Color.accent) : "transparent"
  borderSpec: Border.controlSpec("normal", foreground, Color.accent)

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
