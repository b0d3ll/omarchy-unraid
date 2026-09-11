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

  // Keyboard cursor over the quick actions — the only things here that do
  // something when activated. See VmDetailView for the shape.
  property int cursorIndex: -1
  readonly property var _buttons: [webuiButton, terminalButton]
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

  readonly property var _metrics: service ? service.metrics : ({})
  readonly property var _cores: (root._metrics && root._metrics.cores) || []
  // Collapsed by default: 40 bars is a lot of panel to spend on something
  // you only look at when the total already told you to.
  property bool cpuExpanded: false
  // Same idea for RAM. There is no per-DIMM figure in the API — the nearest
  // useful thing is what the one number is actually made of.
  property bool ramExpanded: false
  readonly property var _array: service ? service.arrayInfo : ({})
  readonly property var _capacity: (root._array && root._array.capacity) || ({})
  readonly property var _parity: (root._array && root._array.parityCheckStatus) || ({})
  readonly property var _lastParity: service ? service.lastParityCheck : null
  readonly property var _hottest:
    (service && service.arrayDisks) ? service.arrayDisks.hottest : null
  // Thresholds are the disk's own where Unraid has them, otherwise Unraid's
  // defaults (45/55) — see Api.js. Colouring against each disk's own figures
  // rather than one global number is what keeps a pool NVMe, which idles
  // warmer than a platter, from being judged by a platter's standard.
  readonly property bool _hotWarn:
    root._hottest !== null && root._hottest.temp >= root._hottest.warnTempC
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
  // Five, not three: a notice that resolves an alarm arrives after it, so a
  // three-row window could show the all-clear with the warning it answers
  // already pushed off the end — or, on a chatty day, neither.
  readonly property var _recent: service ? service.notifications.slice(0, 5) : []

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

    // A temperature is not a percentage of anything, so it reads as a value
    // rather than a bar. It sits with the other counts instead, under
    // Docker. The dot appears only once the disk is past its own warning
    // threshold, so a normal reading is quiet.
    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "Hottest disk"
      statusState: root._hotWarn ? "CRITICAL" : ""
      headline: root._hottest !== null ? root._hottest.temp + " °C" : "—"
      subline: root._hottest !== null
        ? root._hottest.name
        : "all disks in standby"
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

        // The whole header is the hit area, not a separate control: there
        // is nothing else on this row to click, and a dedicated button
        // would be smaller than the thing it toggles.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          enabled: root._cores.length > 0
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cpuExpanded = !root.cpuExpanded
        }

        Text {
          id: cpuTitle
          textFormat: Text.PlainText
          anchors.left: parent.left
          // The caret is the affordance — without it nothing says the row
          // does anything, and a core breakdown nobody knows about is the
          // same as not having one.
          text: root._cores.length > 0
            ? (root.cpuExpanded ? "CPU ▾" : "CPU ▸")
            : "CPU"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          text: (root._metrics.cpuPercent !== null && root._metrics.cpuPercent !== undefined
              ? root._metrics.cpuPercent + "%" : "—")
            + (root._cores.length > 0 ? "  ·  " + root._cores.length + " cores" : "")
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

      // One column per core, bottom-aligned, height by load. Widths are
      // derived from the core count rather than fixed, so this stays honest
      // on a 4-core box and on a 128-core one.
      Item {
        width: parent.width
        visible: root.cpuExpanded && root._cores.length > 0
        implicitHeight: visible ? Style.space(30) : 0

        Row {
          id: coreRow
          anchors.fill: parent
          spacing: Math.max(1, Math.round(parent.width / (root._cores.length * 4)))

          Repeater {
            model: root._cores

            Item {
              id: core
              required property int modelData
              // parent.parent would land on the Row, not the delegate — the
              // id is the only thing that reliably names it from in here.
              readonly property real load: Math.min(100, Math.max(0, core.modelData))

              width: (coreRow.width - coreRow.spacing * (root._cores.length - 1))
                / Math.max(1, root._cores.length)
              height: coreRow.height

              // Track first, then fill — the same two-layer shape as
              // ProgressBar. Without the track an idle machine drew forty
              // one-pixel stubs, which read as a dashed rule rather than as
              // forty cores doing nothing.
              Rectangle {
                anchors.fill: parent
                radius: width / 3
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              }

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                // A floor of one pixel so a fully idle core still shows a
                // tip rather than vanishing into its own track.
                height: Math.max(1, core.height * core.load / 100)
                radius: width / 3
                color: core.load >= 90 ? Color.urgent : Color.accent

                Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
              }
            }
          }
        }
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: ramTitle.implicitHeight

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          enabled: root._metrics.ramTotalGb ? true : false
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.ramExpanded = !root.ramExpanded
        }

        Text {
          id: ramTitle
          textFormat: Text.PlainText
          anchors.left: parent.left
          text: root._metrics.ramTotalGb
            ? (root.ramExpanded ? "RAM ▾" : "RAM ▸")
            : "RAM"
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

      // What the single number is made of. "In use" and "Available" sum to
      // the total; cache is called out separately because it counts as
      // used by Linux and as available by anything that needs it, and
      // saying so is the whole reason this breakdown is worth a click.
      Grid {
        width: parent.width
        visible: root.ramExpanded && root._metrics.ramTotalGb
        columns: 2
        columnSpacing: Style.space(12)
        rowSpacing: Style.space(2)
        topPadding: Style.space(4)
        leftPadding: Style.space(2)

        Text { textFormat: Text.PlainText; text: "In use"; color: Qt.darker(root.foreground, 1.6); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; text: root.fmt(root._metrics.ramUsedGb, 0, " GB"); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }

        Text { textFormat: Text.PlainText; text: "Cache"; color: Qt.darker(root.foreground, 1.6); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; text: root.fmt(root._metrics.ramCacheGb, 0, " GB") + "  (reclaimable)"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }

        Text { textFormat: Text.PlainText; text: "Available"; color: Qt.darker(root.foreground, 1.6); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text { textFormat: Text.PlainText; text: root.fmt(root._metrics.ramAvailableGb, 0, " GB"); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }

        Text { textFormat: Text.PlainText; text: "Swap"; color: Qt.darker(root.foreground, 1.6); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text {
          textFormat: Text.PlainText
          text: root._metrics.swapConfigured
            ? root.fmt(root._metrics.swapUsedGb, 0) + " / " + root.fmt(root._metrics.swapTotalGb, 0, " GB")
            : "none configured"
          color: (root._metrics.swapPercent || 0) > 50 ? Color.urgent : root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.italic: !root._metrics.swapConfigured
        }
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
            ? root.fmt(root._capacity.usedTb) + " / " + root.fmt(root._capacity.totalTb, 1, " TB")
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
        id: webuiButton
        hasCursor: root.buttonHasCursor(webuiButton)
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
        id: terminalButton
        hasCursor: root.buttonHasCursor(terminalButton)
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

        // RECENT now draws from every unread notice, not just warnings, so
        // the entry that resolves an alarm shows up right under it.
        Text {
          textFormat: Text.PlainText
          text: entry.modelData.needsAttention ? "⚠" : "✓"
          color: entry.modelData.needsAttention ? Color.urgent : Color.accent
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
            text: entry.modelData.summary
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
