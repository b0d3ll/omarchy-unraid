pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"

// One VM's detail view (spec sections 22-24). Which controls appear
// depends on the state: a running VM can be rebooted, stopped, paused or
// force-stopped; a stopped one can only be started; a paused one resumes.
//
// The domain type only exposes id/name/state/uuid on a real server — no
// memory, vcpu, autostart or template fields — so this view stays as
// sparse as the spec's own wireframe rather than inventing rows. The uuid
// isn't shown either: it's already inside the id, it's long enough to
// crowd a 440px panel, and nothing in the spec asks for it.
Column {
  id: root

  property var service: null
  property string domainId: ""
  property color foreground: Color.foreground

  signal backRequested()
  signal confirmRequested(string message, string confirmText, string kind)

  // Keyboard cursor over the view's buttons. An explicit list rather than
  // Qt's focus chain: these sit in separate sections with their own
  // visibility rules, and an array states the traversal order out loud
  // instead of leaving it implied by declaration order in three places.
  //
  // `visible` already accounts for ancestors — a button inside a hidden Row
  // reports false — so that filter is all the gating this needs.
  property int cursorIndex: -1
  readonly property var _cursorTargets:
    root._buttons.filter(function(b) { return b && b.visible })

  function moveCursor(delta) {
    var n = root._cursorTargets.length
    if (n === 0) return
    root.cursorIndex = root.cursorIndex < 0
      ? (delta > 0 ? 0 : n - 1)
      : Math.max(0, Math.min(n - 1, root.cursorIndex + delta))
  }

  function activateCursor() {
    var target = root._cursorTargets[root.cursorIndex]
    if (target && target.enabled) target.clicked()
  }

  function buttonHasCursor(button) {
    return root._cursorTargets[root.cursorIndex] === button
  }

  readonly property var _buttons: [backButton, startButton, resumeButton, rebootButton, stopButton, pauseButton, resetButton, forceStopButton]

  readonly property var domain: service ? service.domainById(domainId) : null
  readonly property var _pending: service ? service.vmActionPending : null
  readonly property bool _busy: root._pending !== null && root._pending !== undefined
  readonly property bool _forbidden: service ? service.vmControlsForbidden : false
  // Spec section 34: while offline the panel shows cached state, and
  // acting on it would be acting on a guess.
  readonly property bool _offline: service ? service.offline : false

  readonly property string _state: root.domain ? root.domain.state : ""
  readonly property string _stateLabel: root.domain ? root.domain.stateLabel : ""
  readonly property bool _running: root._state === "RUNNING"
  readonly property bool _paused: root._state === "PAUSED" || root._state === "PMSUSPENDED"

  function pendingLabel(kind, idle) {
    if (root._pending && root._pending.kind === kind) {
      switch (kind) {
        case "start": return "Starting…"
        case "stop": return "Stopping…"
        case "reboot": return "Rebooting…"
        case "pause": return "Pausing…"
        case "resume": return "Resuming…"
        case "forceStop": return "Forcing…"
      }
    }
    return idle
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(14)

  Button {
    id: backButton
    hasCursor: root.buttonHasCursor(backButton)
    text: "← Virtual Machines"
    foreground: root.foreground
    onClicked: root.backRequested()
  }

  EmptyState {
    width: parent.width
    visible: !root.domain
    message: "This VM is no longer in the list."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root.domain !== null
    spacing: Style.space(12)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      elide: Text.ElideRight
      text: root.domain ? root.domain.name : ""
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Row {
      spacing: Style.space(6)

      StatusDot {
        anchors.verticalCenter: parent.verticalCenter
        healthState: root._running ? "HEALTHY" : root._paused ? "NOTICE" : "OFFLINE"
      }

      Text {
        textFormat: Text.PlainText
        text: root._stateLabel
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    Column {
      width: parent.width
      spacing: Style.space(6)

      PanelSectionHeader { text: "CONTROLS"; foreground: root.foreground }

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
          text: "This API key can read but not control VMs. Grant it VM update "
            + "permission in Unraid under Settings → Management Access → API Keys."
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

      // Starting a stopped VM and pausing/resuming a running one aren't
      // destructive, so they act immediately; stop and reboot confirm
      // first (spec section 24).
      Row {
        spacing: Style.space(8)
        visible: !root._forbidden && !root._offline

        Button {
          visible: !root._running && !root._paused
          id: startButton
          hasCursor: root.buttonHasCursor(startButton)
          text: root.pendingLabel("start", "Start")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.service.vmAction("start", root.domain)
        }

        Button {
          visible: root._paused
          id: resumeButton
          hasCursor: root.buttonHasCursor(resumeButton)
          text: root.pendingLabel("resume", "Resume")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.service.vmAction("resume", root.domain)
        }

        Button {
          visible: root._running
          id: rebootButton
          hasCursor: root.buttonHasCursor(rebootButton)
          text: root.pendingLabel("reboot", "Reboot")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Reboot " + root.domain.name + "?\n\nThe VM will restart its guest operating system.",
            "Reboot", "reboot")
        }

        Button {
          visible: root._running || root._paused
          id: stopButton
          hasCursor: root.buttonHasCursor(stopButton)
          text: root.pendingLabel("stop", "Stop")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Stop " + root.domain.name + "?\n\nThe VM will be asked to shut down cleanly.",
            "Stop", "stop")
        }
      }
    }

    // Less-used and more dangerous actions, kept out of the main row so
    // force stop isn't a neighbour of the everyday buttons.
    Column {
      width: parent.width
      visible: !root._forbidden && !root._offline && (root._running || root._paused)
      spacing: Style.space(6)

      PanelSectionHeader { text: "MORE"; foreground: root.foreground }

      Row {
        spacing: Style.space(8)

        Button {
          visible: root._running
          id: pauseButton
          hasCursor: root.buttonHasCursor(pauseButton)
          text: root.pendingLabel("pause", "Pause")
          bordered: true
          foreground: root.foreground
          enabled: !root._busy
          onClicked: root.service.vmAction("pause", root.domain)
        }

        // libvirt's `reset` is the case's reset button: the machine is
        // yanked back to POST with no shutdown sequence at all. Confirmed
        // for the same reason force stop is, and worded so the difference
        // from Reboot is the first thing read.
        Button {
          // Running only, like Pause. libvirt's reset acts on a live
          // domain; a stopped VM has nothing to reset.
          visible: root._running
          id: resetButton
          hasCursor: root.buttonHasCursor(resetButton)
          text: root.pendingLabel("reset", "Reset")
          bordered: true
          foreground: Color.urgent
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Reset " + root.domain.name + "?\n\nThis restarts it immediately without "
              + "shutting down first, like the reset button on a PC. Unsaved work is lost.",
            "Reset", "reset")
        }

        // Spec section 24 wants this one spelled out: it's the equivalent
        // of pulling the power cable, so the confirmation says so in those
        // terms rather than asking a vague "are you sure".
        Button {
          id: forceStopButton
          hasCursor: root.buttonHasCursor(forceStopButton)
          text: root.pendingLabel("forceStop", "Force stop")
          bordered: true
          foreground: Color.urgent
          enabled: !root._busy
          onClicked: root.confirmRequested(
            "Force stop " + root.domain.name + "?\n\nThis is equivalent to cutting power "
              + "and may cause data loss.",
            "Force stop", "forceStop")
        }
      }
    }
  }
}
