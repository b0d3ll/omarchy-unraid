import QtQuick
import qs.Commons
import qs.Ui

// One tile in the Overview 2x2 grid (Array / Storage / Docker / VMs — spec
// section 10-11). Shows a small-caps label, an optional status dot, a
// headline value, and a dim subline.
Item {
  id: root

  property string label: ""
  property string statusState: "" // StatusDot state, empty hides the dot
  property string headline: ""
  property string subline: ""
  property color foreground: Color.foreground

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader {
      text: root.label.toUpperCase()
      foreground: root.foreground
    }

    Row {
      spacing: Style.space(6)

      StatusDot {
        visible: root.statusState !== ""
        healthState: root.statusState
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.headline
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.subline !== ""
      text: root.subline
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: parent.width
    }
  }
}
