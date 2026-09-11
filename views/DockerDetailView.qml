pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"

// One container's detail view (spec section 17). Start / Stop / Restart,
// Open WebUI, and a way into the logs. Remove, image updates, template
// editing and a console are explicit non-goals for v0.1.
//
// The container is looked up by id from the live list on every change
// rather than copied in, so a restart that's still settling updates this
// view by itself as Docker polls land.
Column {
  id: root

  property var service: null
  property string containerId: ""
  property color foreground: Color.foreground

  signal backRequested()
  signal logsRequested()
  // Stop/Restart are disruptive, so they ask Panel.qml to raise the shared
  // confirmation dialog rather than acting immediately (spec section 19).
  signal confirmRequested(string message, string confirmText, string kind)

  readonly property var container: service ? service.containerById(containerId) : null
  readonly property var _pending: service ? service.dockerActionPending : null
  readonly property bool _busy: root._pending !== null && root._pending !== undefined
  readonly property bool _forbidden: service ? service.dockerControlsForbidden : false
  // Spec section 34: while offline the panel shows cached state, and
  // acting on it would be acting on a guess.
  readonly property bool _offline: service ? service.offline : false
  readonly property bool _running: root.container && root.container.state === "RUNNING"

  function pendingLabel(kind, idle) {
    if (root._pending && root._pending.kind === kind) {
      return kind === "start" ? "Starting…" : kind === "stop" ? "Stopping…" : "Restarting…"
    }
    return idle
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(14)

  // --------------------------------------------------------------- back row
  Button {
    text: "← Docker"
    foreground: root.foreground
    onClicked: root.backRequested()
  }

  EmptyState {
    width: parent.width
    visible: !root.container
    message: "This container is no longer in the list."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root.container !== null
    spacing: Style.space(12)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      elide: Text.ElideRight
      text: root.container ? root.container.name : ""
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Row {
      spacing: Style.space(6)

      StatusDot {
        anchors.verticalCenter: parent.verticalCenter
        healthState: root._running ? "HEALTHY"
          : (root.container && root.container.state === "EXITED") ? "OFFLINE" : "WARNING"
      }

      Text {
        textFormat: Text.PlainText
        text: root.container ? root.container.stateLabel : ""
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      StatusBadge {
        visible: root.container && root.container.updateAvailable
        anchors.verticalCenter: parent.verticalCenter
        text: "UPDATE"
        emphasized: true
        foreground: root.foreground
      }
    }

    Grid {
      width: parent.width
      columns: 2
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(4)

      Text { textFormat: Text.PlainText; text: "Status"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text {
        textFormat: Text.PlainText
        text: root.container && root.container.status !== "" ? root.container.status : "—"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text { textFormat: Text.PlainText; text: "Autostart"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text {
        textFormat: Text.PlainText
        text: root.container && root.container.autoStart ? "Enabled" : "Disabled"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Button {
      visible: root.container && root.container.webUiUrl !== ""
      text: "Open WebUI"
      bordered: true
      foreground: root.foreground
      // execArgv keeps a container-supplied URL out of a shell's hands.
      onClicked: Util.execArgv(["omarchy-launch-browser", root.container.webUiUrl])
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    // ---------------------------------------------------------- controls
    Column {
      width: parent.width
      spacing: Style.space(6)

      PanelSectionHeader { text: "CONTROLS"; foreground: root.foreground }

      // Spec section 39: when the key can't control Docker, say so
      // specifically instead of leaving dead buttons armed.
      Column {
        width: parent.width
        visible: root._forbidden
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: "Controls unavailable"
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "This API key can read but not control Docker. Grant it Docker "
            + "update permission in Unraid under Settings → Management Access → API Keys."
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root._offline && !root._forbidden
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Controls are unavailable while the server is unreachable."
        color: Qt.darker(root.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Row {
        spacing: Style.space(8)
        visible: !root._forbidden && !root._offline

        // Starting something that is stopped is not disruptive, so it
        // runs without a confirmation (spec section 19).
        Button {
          visible: !root._running
          text: root.pendingLabel("start", "Start")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.service.dockerAction("start", root.container)
        }

        Button {
          visible: root._running
          text: root.pendingLabel("restart", "Restart")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Restart " + root.container.name + "?\n\nThe service will be briefly unavailable.",
            "Restart", "restart")
        }

        Button {
          visible: root._running
          text: root.pendingLabel("stop", "Stop")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Stop " + root.container.name + "?\n\nThe container will remain stopped until started again.",
            "Stop", "stop")
        }
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    Column {
      width: parent.width
      spacing: Style.space(6)

      PanelSectionHeader { text: "TOOLS"; foreground: root.foreground }

      Button {
        text: "Logs"
        bordered: true
        foreground: root.foreground
        onClicked: root.logsRequested()
      }
    }
  }
}
