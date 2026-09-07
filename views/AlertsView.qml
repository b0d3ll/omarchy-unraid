pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Model.js" as Model

// Notification list with an All/Warnings/Critical filter (spec section 27).
// A row click opens the notification's target in the Unraid WebUI when it
// has one; Archive clears it from the server's unread list.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal toastRequested(string message)

  readonly property var _all: service ? service.notifications : []
  readonly property var _filters: ["All", "Warnings", "Critical"]
  property int filterIndex: 0

  readonly property var _filtered: {
    if (root.filterIndex === 1) return root._all.filter(function(n) { return n.importance === "WARNING" })
    if (root.filterIndex === 2) return root._all.filter(function(n) { return n.importance === "ALERT" })
    return root._all
  }

  function openNotification(item) {
    if (!root.service) return
    var url = root.service.notificationUrl(item.link)
    if (url === "") {
      root.toastRequested("This notification has no page to open.")
      return
    }
    Util.execArgv(["omarchy-launch-browser", url])
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

      Rectangle {
        id: entry
        required property var modelData

        readonly property bool urgent: entry.modelData.importance === "WARNING"
          || entry.modelData.importance === "ALERT"

        width: root.width
        implicitHeight: entryColumn.implicitHeight + Style.space(10)
        color: entryMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

        Behavior on color { ColorAnimation { duration: 100 } }

        // Declared before the content on purpose: later siblings receive
        // input first, so a row-wide MouseArea placed after the column
        // would swallow clicks aimed at the Archive button inside it.
        MouseArea {
          id: entryMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openNotification(entry.modelData)
        }

        Column {
          id: entryColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Row {
            spacing: Style.space(6)
            width: parent.width

            Text {
              textFormat: Text.PlainText
              text: entry.urgent ? "●" : "✓"
              color: entry.urgent ? Color.urgent : Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - Style.space(24)
              elide: Text.ElideRight
              text: entry.modelData.title
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            visible: entry.modelData.subject !== ""
            text: entry.modelData.subject
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            leftPadding: Style.space(18)
          }

          Row {
            spacing: Style.space(8)
            leftPadding: Style.space(18)

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: Model.relativeTime(entry.modelData.timestamp)
                + (entry.modelData.description !== "" ? " · " + entry.modelData.description : "")
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var p = root.service ? root.service.notificationActionPending : null
                return (p && p.id === entry.modelData.id) ? "Archiving…" : "Archive"
              }
              foreground: root.foreground
              enabled: root.service && !root.service.notificationActionPending
                && !root.service.offline
              onClicked: root.service.archiveNotification(entry.modelData)
            }
          }
        }

      }
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.06 }

  Text {
    textFormat: Text.PlainText
    visible: root._all.length > 0
    text: "Click a notification to open it in the Unraid WebUI."
    color: Qt.darker(root.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
