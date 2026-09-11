pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Api.js" as Api
import "../Model.js" as Model

// "Is my Unraid server OK, and what do I want to do about it" — spec
// section 10. Live data as of Milestone 4.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal toastRequested(string message)

  readonly property var _metrics: service ? service.metrics : ({})
  readonly property var _array: service ? service.arrayInfo : ({})
  readonly property var _capacity: (root._array && root._array.capacity) || ({})
  readonly property var _parity: (root._array && root._array.parityCheckStatus) || ({})
  readonly property var _lastParity: service ? service.lastParityCheck : null
  readonly property int _parityErrors:
    (root._lastParity && root._lastParity.errors !== null) ? root._lastParity.errors : 0

  // One line tying the array's health to when it was last verified — the
  // array tile answers "is it up" and this answers "and is that trustworthy".
  readonly property string _parityLine: {
    if (root._parity.running) return "Parity check running"
    if (root._parity.paused) return "Parity check paused"
    if (!root._lastParity) {
      return root.service && root.service.parityHistory.available
        ? "Never parity checked" : ""
    }
    var when = Model.relativeTime(root._lastParity.finishedAt)
    if (root._lastParity.status !== "COMPLETED") {
      return "Parity " + root._lastParity.status.toLowerCase() + " · " + when
    }
    return (root._parityErrors > 0
      ? "Parity: " + root._parityErrors + " error(s)"
      : "Parity clean") + " · " + when
  }
  readonly property var _system: service ? service.system : ({})
  readonly property var _docker: service ? service.docker : ({})
  readonly property var _vms: service ? service.vms : ({})
  readonly property int _unread: service ? service.unreadNotificationCount : 0
  readonly property var _recent: service ? service.notifications.slice(0, 3) : []

  readonly property int _diskProblems:
    (root._array.disabled || 0) + (root._array.missing || 0) + (root._array.invalid || 0)
  // Disabled/invalid disks are also what a routine clear or rebuild looks
  // like, so they get the calmer treatment; a missing disk, unread
  // warnings and parity errors keep the urgent one.
  readonly property bool _urgent: root._unread > 0
    || (root._array.missing || 0) > 0
    || root._parityErrors > 0
  readonly property bool _attention: root._urgent || root._diskProblems > 0

  // The live speed arrives as a bare number of MB/s ("143"), so it needs its
  // unit back; a zero means the check isn't moving and is worth nothing.
  readonly property string _paritySpeed: {
    var raw = String(root._parity.speed || "").trim()
    if (raw === "" || raw === "0") return ""
    return /[a-z]/i.test(raw) ? raw : raw + " MB/s"
  }

  function fmt(value, digits, suffix) {
    if (value === null || value === undefined || isNaN(value)) return "—"
    return value.toFixed(digits === undefined ? 1 : digits) + (suffix || "")
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(16)

  // ---------------------------------------------------------- health banner
  Column {
    width: parent.width
    visible: root._attention
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: root._urgent ? "ATTENTION NEEDED" : "ARRAY MAINTENANCE"
      color: root._urgent ? Color.urgent : Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      font.letterSpacing: 1.0
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      text: {
        var parts = []
        if (root._diskProblems > 0) {
          var disk = []
          if ((root._array.disabled || 0) > 0) disk.push(root._array.disabled + " disabled")
          if ((root._array.missing || 0) > 0) disk.push(root._array.missing + " missing")
          if ((root._array.invalid || 0) > 0) disk.push(root._array.invalid + " invalid")
          parts.push("Array disks: " + disk.join(", "))
        }
        if (root._parityErrors > 0) parts.push(root._parityErrors + " parity error(s)")
        if (root._unread > 0) parts.push(root._unread + (root._unread === 1 ? " unread warning" : " unread warnings"))
        return parts.join(" · ")
      }
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ---------------------------------------------------------------- 2x2 grid
  Grid {
    width: parent.width
    columns: 2
    columnSpacing: Style.space(16)
    rowSpacing: Style.space(14)

    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "Array"
      statusState: root._array.state !== "STARTED" ? "NOTICE"
        : (root._array.missing || 0) > 0 ? "CRITICAL"
        : root._diskProblems > 0 ? "NOTICE"
        : "HEALTHY"
      headline: root._array.stateLabel || "—"
      // A disk needing attention outranks parity trivia; otherwise the tile
      // carries the last check.
      subline: root._diskProblems > 0
        ? root._diskProblems + " disk(s) need attention"
        : root._parityLine
      foreground: root.foreground
    }

    // Storage used to sit here as "5.0 / 14.4 TB", which never said which
    // number was which — it reads equally well as free space. It moved down
    // to the CPU/RAM group, where the bar underneath settles the question.
    // Version and uptime take the slot: they answer "which build am I
    // looking at, and has it rebooted" without a trip to Settings.
    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "Unraid"
      headline: root._system.unraidVersion !== "" ? root._system.unraidVersion : "—"
      subline: root.service && root.service.uptime !== ""
        ? "Up " + root.service.uptime
        : ""
      foreground: root.foreground
    }

    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "Docker"
      statusState: root._docker.available ? "" : "WARNING"
      headline: root._docker.available
        ? root._docker.containers.filter(function(c) { return c.state === "RUNNING" }).length
          + " / " + root._docker.containers.length + " running"
        : "Unavailable"
      foreground: root.foreground
    }

    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "VMs"
      statusState: root._vms.available ? "" : "WARNING"
      headline: root._vms.available
        ? root._vms.domains.filter(function(v) { return v.state === "RUNNING" }).length
          + " / " + root._vms.domains.length + " running"
        : "Unavailable"
      foreground: root.foreground
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  // -------------------------------------------------------------- CPU / RAM
  Column {
    width: parent.width
    spacing: Style.space(10)

    Column {
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: cpuTitle.implicitHeight

        Text {
          id: cpuTitle
          textFormat: Text.PlainText
          anchors.left: parent.left
          text: "CPU"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: root._metrics.cpuPercent !== null && root._metrics.cpuPercent !== undefined
            ? root._metrics.cpuPercent + "%" : "—"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ProgressBar {
        width: parent.width
        value: root._metrics.cpuPercent || 0
        fillColor: Color.accent
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: ramTitle.implicitHeight

        Text {
          id: ramTitle
          textFormat: Text.PlainText
          anchors.left: parent.left
          text: "RAM"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        // Derived from the same total/available figures as the percentage,
        // so the label can't contradict the bar (see Api.normalizeMetrics).
        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: root._metrics.ramTotalGb
            ? root.fmt(root._metrics.ramUsedGb, 0) + " / " + root.fmt(root._metrics.ramTotalGb, 0, " GB")
            : "—"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ProgressBar {
        width: parent.width
        value: root._metrics.ramPercent || 0
        fillColor: Color.accent
      }
    }

    // Same shape as CPU and RAM, which is the point: next to a bar that is
    // 35% full, "5.0 / 14.4 TB used" can only be read one way.
    Column {
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: storageTitle.implicitHeight

        Text {
          id: storageTitle
          textFormat: Text.PlainText
          anchors.left: parent.left
          text: "STORAGE"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: root._capacity.totalTb
            ? root.fmt(root._capacity.usedTb) + " / " + root.fmt(root._capacity.totalTb, 1, " TB used")
            : "—"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      ProgressBar {
        width: parent.width
        value: root._capacity.usedPercent || 0
        fillColor: Color.accent
      }
    }
  }

  // ------------------------------------------------------------- Parity bar
  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: root._parity.running === true

    Text {
      textFormat: Text.PlainText
      text: "PARITY CHECK"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.0
    }

    ProgressBar {
      width: parent.width
      value: root._parity.progress || 0
      fillColor: Color.accent
    }

    // No error count here: the API reports errors only once a check has
    // finished and been written to the parity log, so a running check has
    // nothing truthful to say about them.
    Text {
      textFormat: Text.PlainText
      text: Math.round(root._parity.progress || 0) + "%"
        + (root._paritySpeed !== "" ? " · " + root._paritySpeed : "")
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  // ------------------------------------------------------------ quick actions
  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader { text: "QUICK ACTIONS"; foreground: root.foreground }

    Row {
      spacing: Style.space(8)

      Button {
        text: "WebUI"
        bordered: true
        foreground: root.foreground
        enabled: root.service && root.service.connection.endpoint !== ""
        // execArgv, not bar.run(): the URL comes from user config, and
        // execArgv passes argv through positional parameters so nothing in
        // it can be re-tokenized by a shell (qs.Commons/Util.qml:62).
        onClicked: Util.execArgv(["omarchy-launch-browser", root.service.connection.endpoint])
      }

      Button {
        text: "Terminal"
        bordered: true
        foreground: root.foreground
        enabled: root.service && Api.hostFromUrl(root.service.connection.endpoint) !== ""
        onClicked: Util.execArgv(["omarchy-launch-terminal", "ssh",
          "root@" + Api.hostFromUrl(root.service.connection.endpoint)])
      }
    }
  }

  // ----------------------------------------------------------------- recent
  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: root._recent.length > 0

    PanelSectionHeader { text: "RECENT"; foreground: root.foreground }

    Repeater {
      model: root._recent

      Row {
        id: entry
        required property var modelData
        width: root.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: entry.modelData.importance === "WARNING" || entry.modelData.importance === "ALERT" ? "⚠" : "✓"
          color: entry.modelData.importance === "WARNING" || entry.modelData.importance === "ALERT" ? Color.urgent : Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Column {
          width: parent.width - Style.space(24)
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: entry.modelData.title
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            text: Model.relativeTime(entry.modelData.timestamp)
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
