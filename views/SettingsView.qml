pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

// Placeholder — Server/Connections/Authentication/Behavior/About land in
// Milestone 2 once there's real configuration to show (spec section 28).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  readonly property var _sections: ["Server", "Connections", "Authentication", "Behavior", "About"]

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Repeater {
    model: root._sections

    Column {
      id: section
      required property string modelData
      width: root.width
      spacing: Style.space(4)

      PanelSectionHeader { text: section.modelData.toUpperCase(); foreground: root.foreground }

      Text {
        textFormat: Text.PlainText
        text: "Coming in Milestone 2"
        color: Qt.darker(root.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
