pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import "../Api.js" as Api
import "../Model.js" as Model

// Array/capacity/parity summary plus the per-disk list (spec sections
// 25-26).
//
// The disk list is disk-sleep safe and needs no warning dialog: the API
// answers `array { parities/disks/caches }` out of the emhttp state it
// already holds in memory, so a parked drive stays parked and simply
// reports no temperature. The evidence for that is in Api.js's header, and
// tests/no-disk-queries.sh still guards the queries that genuinely do wake
// disks (the top-level `disks` root and anything SMART).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  readonly property var _array: service ? service.arrayInfo : ({})
  readonly property var _parity: (root._array && root._array.parityCheckStatus) || ({})
  readonly property var _capacity: (root._array && root._array.capacity) || ({})
  readonly property var _disks: service ? service.arrayDisks : null
  readonly property var _lastParity: service ? service.lastParityCheck : null
  readonly property bool _started: root._array.state === "STARTED"
  readonly property var _pending: root.service ? root.service.storageActionPending : null
  readonly property bool _busy: root._pending !== null
  readonly property bool _controlsUsable: root.service !== null
    && !root.service.storageControlsForbidden && !root.service.offline

  signal confirmRequested(string message, string confirmText, string kind)

  // "Starting…" on the button that was pressed, so a slow array start is
  // visibly in progress rather than looking like a dead click.
  function pendingLabel(kind, label) {
    return (root._pending && root._pending.kind === kind) ? label + "…" : label
  }
  readonly property bool _historyAvailable:
    root.service !== null && root.service.parityHistory.available

  readonly property string _paritySpeed: {
    var raw = String(root._parity.speed || "").trim()
    if (raw === "" || raw === "0") return ""
    return /[a-z]/i.test(raw) ? raw : raw + " MB/s"
  }

  function fmt(value, digits, suffix) {
    if (value === null || value === undefined || isNaN(value)) return "—"
    return value.toFixed(digits === undefined ? 1 : digits) + (suffix || "")
  }

  function count(value) {
    return (value === null || value === undefined) ? "—" : String(value)
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(14)

  ErrorState {
    width: parent.width
    visible: root.service && root.service.arrayErrorMessage !== ""
    title: "Array status unavailable"
    message: root.service ? root.service.arrayErrorMessage : ""
    actionLabel: "Retry"
    foreground: root.foreground
    onActionTriggered: if (root.service) root.service.refreshArray()
  }

  PanelSectionHeader { text: "ARRAY"; foreground: root.foreground }

  Row {
    spacing: Style.space(6)
    StatusDot {
      anchors.verticalCenter: parent.verticalCenter
      healthState: root._array.state === "STARTED" ? "HEALTHY" : "NOTICE"
    }
    Text {
      textFormat: Text.PlainText
      text: root._array.stateLabel || "—"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  Row {
    spacing: Style.space(8)
    visible: root._controlsUsable && root._array.state !== ""

    // Stopping the array unmounts every share and takes Docker and the VMs
    // down with it, so it says that rather than asking "are you sure".
    // Starting is not destructive and goes straight through.
    Button {
      visible: root._started
      text: root.pendingLabel("arrayStop", "Stop array")
      bordered: true
      foreground: Color.urgent
      enabled: !root._busy
      onClicked: root.confirmRequested(
        "Stop the array?\n\nEvery share is unmounted, and all Docker containers "
          + "and VMs stop with it. Anything writing to the array right now will "
          + "be interrupted.",
        "Stop array", "arrayStop")
    }

    Button {
      visible: !root._started
      text: root.pendingLabel("arrayStart", "Start array")
      bordered: true
      foreground: root.foreground
      enabled: !root._busy
      onClicked: root.service.storageAction("arrayStart")
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: root.fmt(root._capacity.usedTb, 1, " TB used")
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: root.fmt(root._capacity.totalTb, 1, " TB total") + " · " + root.fmt(root._capacity.freeTb, 1, " TB free")
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    ProgressBar {
      width: parent.width
      value: root._capacity.usedPercent || 0
      fillColor: Color.accent
    }
  }

  // Disk counters, counted from the per-disk status in the list below
  // rather than read off `vars` — the two disagree on this server, and the
  // status is the one the Unraid Main page draws (see arrayDiskCounts in
  // Api.js). A non-zero count is coloured as urgent rather than left to
  // blend in with the healthy rows.
  Grid {
    width: parent.width
    columns: 2
    columnSpacing: Style.space(16)
    rowSpacing: Style.space(6)

    Text { textFormat: Text.PlainText; text: "Array disks"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: root.count(root._array.disks); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }

    Text { textFormat: Text.PlainText; text: "Disabled"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text {
      textFormat: Text.PlainText
      text: root.count(root._array.disabled)
      color: (root._array.disabled || 0) > 0 ? Color.urgent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: (root._array.disabled || 0) > 0
    }

    Text { textFormat: Text.PlainText; text: "Missing"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text {
      textFormat: Text.PlainText
      text: root.count(root._array.missing)
      color: (root._array.missing || 0) > 0 ? Color.urgent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: (root._array.missing || 0) > 0
    }

    Text { textFormat: Text.PlainText; text: "Invalid"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text {
      textFormat: Text.PlainText
      text: root.count(root._array.invalid)
      color: (root._array.invalid || 0) > 0 ? Color.urgent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: (root._array.invalid || 0) > 0
    }

    Text { textFormat: Text.PlainText; text: "Cache devices"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    // Counted from the pool list. `vars.cacheNumDevices` answers NaN on this
    // server — a partial GraphQL error and a null field — which rendered as
    // "—" even though there are plainly two pool devices.
    Text { textFormat: Text.PlainText; text: root.count(root._array.cacheDevices); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  Column {
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader { text: "PARITY"; foreground: root.foreground }

    Text {
      textFormat: Text.PlainText
      text: {
        if (root._parity.running) {
          return "Running · " + Math.round(root._parity.progress || 0) + "%"
            + (root._paritySpeed !== "" ? " · " + root._paritySpeed : "")
        }
        if (root._parity.paused) return "Paused · " + Math.round(root._parity.progress || 0) + "%"
        if (root._lastParity) {
          var line = "Last check: " + Model.relativeTime(root._lastParity.finishedAt)
          var took = Api.formatDuration(root._lastParity.durationSeconds)
          if (root._lastParity.status !== "COMPLETED") {
            line += " · " + root._lastParity.status.toLowerCase()
          }
          return took !== "" ? line + " · took " + took : line
        }
        return root._historyAvailable ? "Never checked" : "Last check: —"
      }
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    // The error count comes from the parity log via parityHistory, not from
    // array.parityCheckStatus — the API never fills that one in, so the "0"
    // this line used to print was invented rather than read.
    Text {
      textFormat: Text.PlainText
      visible: !root._parity.running && !root._parity.paused
      text: {
        if (!root._lastParity || root._lastParity.errors === null) return "Errors: unknown"
        return "Errors: " + root._lastParity.errors
      }
      color: (root._lastParity && root._lastParity.errors > 0)
        ? Color.urgent : Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Item { width: 1; height: Style.space(2) }

    Row {
      spacing: Style.space(8)
      visible: root._controlsUsable && root._started

      // A check reads every disk end to end for hours, which spins up the
      // whole array — the one thing this plugin otherwise works hard to
      // avoid — so the confirmation says so plainly.
      Button {
        visible: !root._parity.running && !root._parity.paused
        text: root.pendingLabel("parityCheck", "Check")
        bordered: true
        foreground: root.foreground
        enabled: !root._busy
        onClicked: root.confirmRequested(
          "Start a parity check?\n\nThis reads every disk end to end, so all of "
            + "them spin up and stay up for hours. It reports errors without "
            + "changing anything.",
          "Start check", "parityCheck")
      }

      // Distinct from the read-only check on purpose: this rewrites parity
      // from the data disks, which is the wrong move if a data disk is the
      // one that is wrong.
      Button {
        visible: !root._parity.running && !root._parity.paused
        text: root.pendingLabel("parityCorrect", "Check & correct")
        bordered: true
        foreground: Color.urgent
        enabled: !root._busy
        onClicked: root.confirmRequested(
          "Start a correcting parity check?\n\nSame as a check, but it rewrites "
            + "parity wherever it disagrees with the data disks. If a data disk "
            + "is the one at fault, this writes the fault into parity.",
          "Start correcting", "parityCorrect")
      }

      Button {
        visible: root._parity.running
        text: root.pendingLabel("parityPause", "Pause")
        bordered: true
        foreground: root.foreground
        enabled: !root._busy
        onClicked: root.service.storageAction("parityPause")
      }

      Button {
        visible: root._parity.paused
        text: root.pendingLabel("parityResume", "Resume")
        bordered: true
        foreground: root.foreground
        enabled: !root._busy
        onClicked: root.service.storageAction("parityResume")
      }

      Button {
        visible: root._parity.running || root._parity.paused
        text: root.pendingLabel("parityCancel", "Cancel")
        bordered: true
        foreground: Color.urgent
        enabled: !root._busy
        onClicked: root.confirmRequested(
          "Cancel the parity check?\n\nProgress is lost — the next check starts "
            + "from the beginning.",
          "Cancel check", "parityCancel")
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      visible: root.service !== null && root.service.storageControlsForbidden
      text: "This API key can read the array but not control it. Grant it array "
        + "update permission in Unraid → Settings → Management Access → API Keys."
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  // ------------------------------------------------------------- disks

  Item {
    width: parent.width
    implicitHeight: disksHeader.implicitHeight

    PanelSectionHeader { id: disksHeader; text: "DISKS"; foreground: root.foreground }

    // Spun-up count is the thing worth knowing at a glance, and it counts
    // only rotational drives — an SSD is never anything but "spinning", so
    // including them would inflate the number into meaninglessness.
    Text {
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.baseline: disksHeader.baseline
      visible: root._disks !== null && root._disks.available && root._disks.spinnable > 0
      text: root._disks ? (root._disks.spinning + " of " + root._disks.spinnable + " spinning") : ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // The disk list shares the array query, so its failure is already
  // reported by the "Array status unavailable" box at the top of the view —
  // repeating it here would just say the same thing twice.
  EmptyState {
    width: parent.width
    visible: root.service && root.service.arrayErrorMessage === ""
      && (!root._disks || !root._disks.available || root._disks.all.length === 0)
    message: (root.service && root.service.arrayPending)
      ? "Loading disks…"
      : "The server reported no disks."
    foreground: root.foreground
  }

  Column {
    width: parent.width
    visible: root._disks !== null && root._disks.available
    spacing: Style.space(10)

    Repeater {
      model: [
        { label: "Parity", key: "parities" },
        { label: "Array", key: "disks" },
        { label: "Pools", key: "caches" }
      ]

      Column {
        id: group
        required property var modelData
        readonly property var rows: (root._disks && root._disks[group.modelData.key]) || []

        width: parent.width
        visible: group.rows.length > 0
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: group.modelData.label
          color: Qt.darker(root.foreground, 1.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          bottomPadding: Style.space(2)
        }

        Repeater {
          model: group.rows

          DiskRow {
            required property var modelData
            width: group.width
            disk: modelData
            foreground: root.foreground
          }
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    visible: root._disks !== null && root._disks.available && root._disks.standby > 0
    text: "Read from the server's cached disk state, so drives in standby stay asleep — "
      + "which is also why they report no temperature."
    color: Qt.darker(root.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}
