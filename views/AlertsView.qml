pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Model.js" as Model

// Notification list with an All/Warnings/Critical filter (spec section 27).
// Archive/detail actions land once Milestone 7 wires the real API.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  readonly property var _all: service ? service.notifications : []
  readonly property var _filters: ["All", "Warnings", "Critical"]
  property int filterIndex: 0

  readonly property var _filtered: {
    if (root.filterIndex === 1) return root._all.filter(function(n) { return n.importance === "WARNING" })
    if (root.filterIndex === 2) return root._all.filter(function(n) { return n.importance === "ALERT" })
    return root._all
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Row {
    spacing: Style.space(8)

    Repeater {
      model: root._filters

      Button {
        required property int index
        required property string modelData
        text: modelData
        bordered: true
        selected: root.filterIndex === index
        foreground: root.foreground
        onClicked: root.filterIndex = index
      }
    }
  }

  EmptyState {
    width: parent.width
    visible: root._filtered.length === 0
    message: "No warnings or alerts."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: root._filtered

      Column {
        id: entry
        required property var modelData
        width: root.width
        spacing: Style.space(2)

        Row {
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: entry.modelData.importance === "WARNING" || entry.modelData.importance === "ALERT" ? "●" : "✓"
            color: entry.modelData.importance === "WARNING" || entry.modelData.importance === "ALERT" ? Color.urgent : Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            text: entry.modelData.title
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.relativeTime(entry.modelData.timestamp)
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          leftPadding: Style.space(18)
        }

        PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.06 }
      }
    }
  }
}
