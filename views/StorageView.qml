import QtQuick
import qs.Commons
import qs.Ui
import "../components"

// Array/capacity/parity summary (spec section 25). MUST stay disk-sleep
// safe: no per-disk or SMART query runs from this view automatically —
// "Load disk details" only requests confirmation from Panel.qml, which
// owns the shared warning dialog (spec section 26).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground

  signal loadDiskDetailsRequested()

  readonly property var _array: service ? service.arrayInfo : ({})
  readonly property var _parity: root._array.parityCheckStatus || ({})
  readonly property var _capacity: root._array.capacity || ({})
  readonly property real _usedFraction: root._capacity.totalTb ? (100 * root._capacity.usedTb / root._capacity.totalTb) : 0

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(14)

  PanelSectionHeader { text: "ARRAY"; foreground: root.foreground }

  Row {
    spacing: Style.space(6)
    StatusDot { anchors.verticalCenter: parent.verticalCenter; healthState: root._array.state === "STARTED" ? "HEALTHY" : "NOTICE" }
    Text {
      textFormat: Text.PlainText
      text: root._array.state === "STARTED" ? "Started" : (root._array.state || "Unknown")
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
      text: root._capacity.usedTb !== undefined
        ? root._capacity.usedTb.toFixed(1) + " TB used"
        : "—"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: root._capacity.totalTb !== undefined
        ? root._capacity.totalTb.toFixed(1) + " TB total · " + root._capacity.freeTb.toFixed(1) + " TB free"
        : ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    ProgressBar {
      width: parent.width
      value: root._usedFraction
      fillColor: Color.accent
    }
  }

  Grid {
    width: parent.width
    columns: 2
    columnSpacing: Style.space(16)
    rowSpacing: Style.space(6)

    Text { textFormat: Text.PlainText; text: "Array disks"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: String(root._array.disks || 0); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; horizontalAlignment: Text.AlignRight }
    Text { textFormat: Text.PlainText; text: "Disabled"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: String(root._array.disabled || 0); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: "Missing"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: String(root._array.missing || 0); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: "Cache devices"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    Text { textFormat: Text.PlainText; text: String(root._array.cacheDevices || 0); color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  Column {
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader { text: "PARITY"; foreground: root.foreground }

    Text {
      textFormat: Text.PlainText
      text: root._parity.running
        ? "Running · " + root._parity.progress + "% · " + root._parity.speed
        : "No check running"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      visible: root._parity.errors !== undefined
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
