pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"

// Array/capacity/parity summary (spec section 25), live as of Milestone 4.
// MUST stay disk-sleep safe: nothing here queries per-disk or SMART data.
// "Load disk details" only asks Panel.qml to raise the shared warning
// dialog (spec section 26) — see Api.js for the invariant and
// tests/no-disk-queries.sh for the check that enforces it.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal loadDiskDetailsRequested()

  readonly property var _array: service ? service.arrayInfo : ({})
  readonly property var _parity: (root._array && root._array.parityCheckStatus) || ({})
  readonly property var _capacity: (root._array && root._array.capacity) || ({})

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
      text: root._array.state === "STARTED" ? "Started" : (root._array.state || "—")
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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

  // Disk counters. Disabled/missing/invalid are the whole reason this view
  // exists, so a non-zero count is coloured as urgent rather than left to
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
    // Reports NaN on servers without a cache pool, so "—" is the honest
    // rendering rather than a made-up 0.
    Text { textFormat: Text.PlainText; text: root.count(root._array.cacheDevices); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  Column {
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader { text: "PARITY"; foreground: root.foreground }

    Text {
      textFormat: Text.PlainText
      text: root._parity.running
        ? "Running · " + (root._parity.progress || 0) + "% · " + (root._parity.speed || "—")
        : (root._parity.status ? "Last check: " + root._parity.status : "No check running")
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      text: "Errors: " + (root._parity.errors || 0)
      color: (root._parity.errors || 0) > 0 ? Color.urgent : Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  Button {
    text: "Load disk details"
    bordered: true
    foreground: root.foreground
    onClicked: root.loadDiskDetailsRequested()
  }
}
