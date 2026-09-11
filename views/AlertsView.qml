pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Model.js" as Model

// Unread notification list with an All/Info/Warnings/Critical filter (spec
// section 27). A row click opens the notification's target in the Unraid
// WebUI when it has one; Archive clears it from the server's unread list.
//
// This used to list warnings and alerts only, which meant a notice could
// resolve an alarm without the panel ever saying so — "Disk-Clear started"
// stayed on screen as a warning while "Disk-Clear finished (0 errors)" was
// filtered out. INFO notices are marked with an accent tick (the palette's
// only "this is fine" colour; Omarchy defines no green — see StatusDot).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal toastRequested(string message)

  readonly property var _all: service ? service.notifications : []
  readonly property var _filters: ["All", "Info", "Warnings", "Critical"]
  property int filterIndex: 0

  readonly property var _importanceForFilter: ["", "INFO", "WARNING", "ALERT"]
  readonly property var _emptyMessages: [
    "No unread notifications.", "No unread notices.",
    "No unread warnings.", "No unread alerts."
  ]

  readonly property var _filtered: {
    var want = root._importanceForFilter[root.filterIndex] || ""
    if (want === "") return root._all
    return root._all.filter(function(n) { return n.importance === want })
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
    message: root._emptyMessages[root.filterIndex] || "No unread notifications."
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

        readonly property bool urgent: entry.modelData.needsAttention

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
              // Accent, not a dimmed foreground: an INFO notice is usually
              // the all-clear for something, and reading it as greyed-out
              // filler was half the reason it went unnoticed.
              color: entry.urgent ? Color.urgent : Color.accent
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

          // Anchored rather than a Row: the meta line carries the server's
          // `description`, which can run to a full sentence ("Duration: 1
          // hour, 38 minutes, 47 seconds. Average speed…"). In a Row that
          // pushed Archive off the right edge of the panel, out of reach —
          // rare while only warnings were listed, routine now that
          // Community Applications' update notices are here too.
          Item {
            width: parent.width
            implicitHeight: Math.max(meta.implicitHeight, archive.implicitHeight)

            Text {
              id: meta
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.right: archive.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: Model.relativeTime(entry.modelData.timestamp)
                + (entry.modelData.description !== "" ? " · " + entry.modelData.description : "")
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              id: archive
              anchors.right: parent.right
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
