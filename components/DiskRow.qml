import QtQuick
import qs.Commons

// One drive in the Storage view's disk list — parity, data disk or pool
// member, all the same shape.
//
// The spin state carries most of the meaning here, so it gets two channels
// rather than a badge nobody reads: the dot goes muted while a drive is
// parked, and the temperature column — which is genuinely empty for a
// parked drive, because the server never woke it to measure — says
// "standby" in that gap instead of an em dash that could equally mean
// "unknown".
Item {
  id: root

  property var disk: null
  property color foreground: Color.foreground

  readonly property bool _standby: root.disk && root.disk.spinState === "STANDBY"
  readonly property bool _problem: root.disk && !root.disk.healthy
  readonly property bool _hasUsage: root.disk && root.disk.usedPercent !== null

  // Gigabytes below the terabyte mark: a 240 GB pool SSD rendered as
  // "0.24 TB" is three characters of precision pretending to be a size.
  function fmtSize(tb) {
    if (tb === null || tb === undefined || isNaN(tb)) return "—"
    return tb < 1 ? (tb * 1000).toFixed(0) + " GB" : tb.toFixed(2) + " TB"
  }

  implicitHeight: Style.space(_hasUsage ? 34 : 26)
  height: implicitHeight

  StatusDot {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)
    healthState: root._problem ? "CRITICAL" : (root._standby ? "OFFLINE" : "HEALTHY")
  }

  Row {
    id: identity
    anchors.left: parent.left
    anchors.leftMargin: Style.space(18)
    anchors.top: parent.top
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.disk ? root.disk.name : ""
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.disk ? root.disk.device : ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    StatusBadge {
      anchors.verticalCenter: parent.verticalCenter
      visible: root._problem
      text: root.disk ? root.disk.statusLabel.toUpperCase() : ""
      emphasized: true
      foreground: Color.urgent
    }
  }

  Row {
    id: readings
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(10)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: {
        if (!root.disk) return ""
        if (root.disk.temp !== null) return root.disk.temp + "°C"
        return root._standby ? "standby" : "—"
      }
      color: root._standby ? Qt.darker(root.foreground, 1.6) : Qt.darker(root.foreground, 1.2)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.italic: root._standby
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      // Parity carries no filesystem, so it reports its raw size and
      // nothing else — there is no "used" to show.
      text: root.disk
        ? (root._hasUsage
            ? root.fmtSize(root.disk.usedTb) + " / " + root.fmtSize(root.disk.totalTb)
            : root.fmtSize(root.disk.sizeTb))
        : ""
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  ProgressBar {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(18)
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(6)
    visible: root._hasUsage
    barHeight: Style.space(3)
    value: root.disk && root.disk.usedPercent !== null ? root.disk.usedPercent : 0
    fillColor: root._problem ? Color.urgent
      : (root._standby ? Qt.darker(Color.accent, 1.5) : Color.accent)
  }
}
