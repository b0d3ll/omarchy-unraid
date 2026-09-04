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
  readonly property var _docker: service ? service.docker : ({})
  readonly property var _vms: service ? service.vms : ({})
  readonly property int _unread: service ? service.unreadNotificationCount : 0
  readonly property var _recent: service ? service.notifications.slice(0, 3) : []

  readonly property int _diskProblems:
    (root._array.disabled || 0) + (root._array.missing || 0) + (root._array.invalid || 0)
  readonly property bool _attention: root._unread > 0 || root._diskProblems > 0 || (root._parity.errors || 0) > 0

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
      text: "ATTENTION NEEDED"
      color: Color.urgent
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
        if ((root._parity.errors || 0) > 0) parts.push(root._parity.errors + " parity error(s)")
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
      statusState: root._array.state === "STARTED"
        ? (root._diskProblems > 0 ? "CRITICAL" : "HEALTHY")
        : "NOTICE"
      headline: root._array.state === "STARTED" ? "Started" : (root._array.state || "—")
      subline: root._diskProblems > 0
        ? root._diskProblems + " disk(s) need attention"
        : ""
      foreground: root.foreground
    }

    MetricCard {
      width: (parent.width - Style.space(16)) / 2
      label: "Storage"
      headline: root.fmt(root._capacity.usedTb) + " / " + root.fmt(root._capacity.totalTb, 1, " TB")
      subline: root._capacity.usedPercent !== null && root._capacity.usedPercent !== undefined
        ? Math.round(root._capacity.usedPercent) + "% used"
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

    Text {
      textFormat: Text.PlainText
      text: (root._parity.speed || "—") + " · " + (root._parity.errors || 0) + " errors"
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

      Button {
        text: "Refresh"
        bordered: true
        foreground: root.foreground
        onClicked: if (root.service) root.service.refresh()
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
