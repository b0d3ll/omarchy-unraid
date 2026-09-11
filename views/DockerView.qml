pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"

// Container list (spec sections 15-16), live as of Milestone 4.
// Start/stop/restart and the detail view land in Milestone 5 — rows are
// display-only here and say so on click.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal containerSelected(string containerId)

  readonly property var _docker: service ? service.docker : ({ available: false, containers: [] })
  readonly property var _sorted: service ? service.sortedContainers : []
  readonly property var _filtered: {
    var query = searchField.text.toLowerCase().trim()
    if (query === "") return root._sorted
    return root._sorted.filter(function(c) { return c.name.toLowerCase().indexOf(query) >= 0 })
  }
  // See VmsView for the contract; the only difference here is that the row
  // set is the *filtered* one, so searching re-aims the cursor.
  property int cursorIndex: -1

  // Passes the item itself, not coordinates: a row's y is relative to
  // the Column it sits in, which is several parents away from the
  // flickable that would have to scroll. Only Panel can map between them.
  signal cursorRevealRequested(var item)

  function moveCursor(delta) {
    if (root._filtered.length === 0) return
    root.cursorIndex = root.cursorIndex < 0
      ? 0
      : Math.max(0, Math.min(root._filtered.length - 1, root.cursorIndex + delta))
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root._filtered.length) return
    root.containerSelected(root._filtered[root.cursorIndex].id)
  }

  // A search that shortens the list must not leave the cursor pointing past
  // the end of it.
  onCursorIndexChanged: if (root.cursorIndex >= root._filtered.length) root.cursorIndex = -1

  readonly property int _runningCount:
    (root._docker.containers || []).filter(function(c) { return c.state === "RUNNING" }).length
  readonly property int _updateCount:
    (root._docker.containers || []).filter(function(c) { return c.updateAvailable }).length

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
        + (root._updateCount > 0 ? "  ·  " + root._updateCount + " update(s)" : "")
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
    message: root.service && root.service.dockerErrorMessage !== ""
      ? root.service.dockerErrorMessage
      : "The server is online, but the Docker API did not respond."
    actionLabel: "Retry"
    foreground: root.foreground
    onActionTriggered: if (root.service) root.service.refreshDocker()
  }

  EmptyState {
    width: parent.width
    visible: root._docker.available && root._filtered.length === 0
    message: searchField.text.trim() !== ""
      ? "No containers match that search."
      : "No Docker containers found."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root._docker.available
    spacing: 0

    Repeater {
      model: root._filtered

      CursorSurface {
        id: row
        required property var modelData
        required property int index

        width: root.width
        height: Style.space(36)
        foreground: root.foreground
        hasCursor: root.cursorIndex === row.index

        onHasCursorChanged: if (row.hasCursor) root.cursorRevealRequested(row)

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
          anchors.right: updateBadge.visible ? updateBadge.left : badge.left
          anchors.rightMargin: Style.space(8)
          elide: Text.ElideRight
          text: row.modelData.name
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        StatusBadge {
          id: updateBadge
          visible: row.modelData.updateAvailable
          anchors.right: badge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: "UPDATE"
          emphasized: true
          foreground: root.foreground
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
          onContainsMouseChanged: if (containsMouse) root.cursorIndex = row.index
          cursorShape: Qt.PointingHandCursor
          onClicked: root.containerSelected(row.modelData.id)
        }
      }
    }
  }
}
