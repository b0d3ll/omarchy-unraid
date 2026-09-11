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
  // See VmsView for the contract. Two differences here: the row set is the
  // *filtered* one, so searching re-aims the cursor, and the search box is
  // itself the first cursor target. It is the first thing on screen, so
  // walking down from the top should reach it before the list — which is
  // what makes it findable without knowing any shortcut.
  //
  // Index 0 is the search box; 1..n are rows, offset by one.
  property int cursorIndex: -1

  readonly property bool _searchTargetable: root._docker.available
  readonly property int _searchOffset: root._searchTargetable ? 1 : 0
  readonly property int _cursorCount: root._filtered.length + root._searchOffset
  readonly property bool _searchHasCursor:
    root._searchTargetable && root.cursorIndex === 0

  function rowHasCursor(index) {
    return root.cursorIndex === index + root._searchOffset
  }

  // `/` from anywhere in the tab, the way every keyboard-driven list does it.
  function focusSearch() {
    if (!root._searchTargetable) return
    root.cursorIndex = 0
    searchField.forceActiveFocus()
  }

  // Escape hands the keyboard back before it backs out of the view, so the
  // first press leaves the field rather than closing the panel under you.
  function releaseKeyboard() {
    if (!searchField.activeFocus) return false
    searchField.focus = false
    return true
  }

  // Passes the item itself, not coordinates: a row's y is relative to
  // the Column it sits in, which is several parents away from the
  // flickable that would have to scroll. Only Panel can map between them.
  signal cursorRevealRequested(var item)

  function moveCursor(delta) {
    // Leaving the field by arrow also gives the keyboard back, or the next
    // thing typed would still land in the search box.
    if (searchField.activeFocus) searchField.focus = false
    if (root._cursorCount === 0) return
    root.cursorIndex = root.cursorIndex < 0
      ? (delta > 0 ? 0 : root._cursorCount - 1)
      : Math.max(0, Math.min(root._cursorCount - 1, root.cursorIndex + delta))
  }

  function activateCursor() {
    if (root.cursorIndex < 0) return
    if (root._searchHasCursor) { searchField.forceActiveFocus(); return }
    var row = root.cursorIndex - root._searchOffset
    if (row < 0 || row >= root._filtered.length) return
    root.containerSelected(root._filtered[row].id)
  }

  // A search that shortens the list must not leave the cursor pointing past
  // the end of it.
  onCursorIndexChanged: if (root.cursorIndex >= root._cursorCount) root.cursorIndex = -1

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
    placeholderText: "Search containers…  (/)"
    foreground: root.foreground
    hasCursor: root._searchHasCursor
    // Hover writes to the same index as the keyboard, so mouse and keys
    // can never light two things at once.
    onHoveredChanged: if (hovered) root.cursorIndex = 0
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
        hasCursor: root.rowHasCursor(row.index)

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
          onContainsMouseChanged: if (containsMouse) root.cursorIndex = row.index + root._searchOffset
          cursorShape: Qt.PointingHandCursor
          onClicked: root.containerSelected(row.modelData.id)
        }
      }
    }
  }
}
