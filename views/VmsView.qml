pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import "../components"

// Virtual machine list (spec section 21). Same row pattern as Docker, no
// search/update badge. Clicking a row opens its detail view, where the
// controls live (spec sections 22-24).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal domainSelected(string domainId)

  readonly property var _vms: service ? service.vms : ({ available: false, domains: [] })
  readonly property int _runningCount: (root._vms.domains || []).filter(function(v) { return v.state === "RUNNING" }).length

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Item {
    width: parent.width
    implicitHeight: vmsTitle.implicitHeight

    Text {
      id: vmsTitle
      textFormat: Text.PlainText
      anchors.left: parent.left
      text: "VIRTUAL MACHINES"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
    }

    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      visible: root._vms.available
      text: root._runningCount + " / " + (root._vms.domains || []).length
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  ErrorState {
    width: parent.width
    visible: !root._vms.available
    title: "Virtual machines unavailable"
    message: root.service && root.service.vmsErrorMessage !== ""
      ? root.service.vmsErrorMessage
      : "The server is online, but the VM API did not respond."
    actionLabel: "Retry"
    foreground: root.foreground
    onActionTriggered: if (root.service) root.service.refreshVms()
  }

  EmptyState {
    width: parent.width
    visible: root._vms.available && (root._vms.domains || []).length === 0
    message: "No virtual machines found."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root._vms.available
    spacing: 0

    Repeater {
      model: root._vms.domains || []

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
          healthState: row.modelData.state === "RUNNING" ? "HEALTHY" : (row.modelData.state === "PAUSED" ? "NOTICE" : "OFFLINE")
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
          text: row.modelData.stateLabel.toUpperCase()
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
          onClicked: root.domainSelected(row.modelData.id)
        }
      }
    }
  }
}
