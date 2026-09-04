pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Api.js" as Api

// Container logs (spec section 20). 100 lines, monospace, manual Refresh
// plus a 5-second auto-refresh that only runs while this view is open —
// the polling itself is owned by UnraidService's logs resource, which is
// gated on `logsContainerId` being set.
//
// No live WebSocket streaming in v0.1.
Column {
  id: root

  property var service: null
  property string containerId: ""
  property color foreground: Color.foreground

  signal backRequested()

  readonly property var container: service ? service.containerById(containerId) : null
  readonly property var _logs: service ? service.logs : ({ available: false, lines: [] })

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Button {
    text: "← " + (root.container ? root.container.name : "Docker")
    foreground: root.foreground
    onClicked: root.backRequested()
  }

  Item {
    width: parent.width
    implicitHeight: logsTitle.implicitHeight

    Text {
      id: logsTitle
      textFormat: Text.PlainText
      anchors.left: parent.left
      text: "LOGS"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
    }

    Button {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "Refresh"
      foreground: root.foreground
      onClicked: if (root.service) root.service.refreshLogs()
    }
  }

  ErrorState {
    width: parent.width
    visible: root.service && root.service.logsErrorMessage !== ""
    title: "Logs unavailable"
    message: root.service ? root.service.logsErrorMessage : ""
    actionLabel: "Retry"
    foreground: root.foreground
    onActionTriggered: if (root.service) root.service.refreshLogs()
  }

  EmptyState {
    width: parent.width
    visible: root._logs.available && root._logs.lines.length === 0
    message: "This container hasn't logged anything."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: root._logs.lines

      Row {
        id: line
        required property var modelData
        width: root.width
        spacing: Style.space(8)

        Text {
          id: stamp
          textFormat: Text.PlainText
          text: Api.clockTime(line.modelData.timestamp)
          color: Qt.darker(root.foreground, 1.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - stamp.width - Style.space(8)
          wrapMode: Text.Wrap
          text: line.modelData.message
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
