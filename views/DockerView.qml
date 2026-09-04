pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Model.js" as Model

// Container list (spec sections 15-16). Detail/start/stop/restart land in
// Milestone 5 — rows are display-only in Milestone 1 and surface a toast
// explaining that on click.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal toastRequested(string message)

  readonly property var _docker: service ? service.docker : ({ available: false, containers: [] })
  readonly property var _filtered: {
    var list = Model.sortContainers(root._docker.containers || [])
    var query = searchField.text.toLowerCase().trim()
    if (query === "") return list
    return list.filter(function(c) { return c.name.toLowerCase().indexOf(query) >= 0 })
  }
  readonly property int _runningCount: (root._docker.containers || []).filter(function(c) { return c.state === "RUNNING" }).length

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Item {
    width: parent.width
    implicitHeight: dockerTitle.implicitHeight

    Text {
      id: dockerTitle
      textFormat: Text.PlainText
      anchors.left: parent.left
      text: "DOCKER"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      visible: root._docker.available
      text: root._runningCount + " / " + (root._docker.containers || []).length
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  TextField {
    id: searchField
    width: parent.width
    visible: root._docker.available
    placeholderText: "Search containers…"
    foreground: root.foreground
  }

  ErrorState {
    width: parent.width
    visible: !root._docker.available
    title: "Docker unavailable"
    message: "The server is online, but the Docker API did not respond."
    actionLabel: "Retry"
    foreground: root.foreground
    onActionTriggered: if (root.service) root.service.refreshDocker()
  }

  EmptyState {
    width: parent.width
    visible: root._docker.available && root._filtered.length === 0
    message: "No Docker containers found."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root._docker.available
    spacing: 0

    Repeater {
      model: root._filtered

      Rectangle {
        id: row
        required property var modelData

        width: root.width
        height: Style.space(36)
        color: rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        Behavior on color { ColorAnimation { duration: 100 } }

        StatusDot {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          healthState: row.modelData.state === "RUNNING" ? "HEALTHY" : (row.modelData.state === "EXITED" ? "OFFLINE" : "WARNING")
        }

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: badge.left
          anchors.rightMargin: Style.space(8)
          elide: Text.ElideRight
          text: row.modelData.name
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        StatusBadge {
          id: badge
          anchors.right: chevron.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: row.modelData.state
          foreground: root.foreground
        }

        Text {
          id: chevron
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: ">"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toastRequested("Container detail view is coming in Milestone 5.")
        }
      }
    }
  }
}
