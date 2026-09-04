pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "components"
import "views"
import "Model.js" as Model

// Bar-widget entry point (manifest.entryPoints.barWidget = "Panel.qml"),
// same single-file pattern as the built-in power/clock plugins: this one
// file is both the bar button and the popup content, so no separate
// BarWidget.qml + Loader indirection is needed (that split exists in
// weather because of its settings-form injection, which this plugin
// doesn't need).
Panel {
  id: root
  moduleName: "io.github.b0d3ll.omarchy-unraid"
  ipcTarget: "io.github.b0d3ll.omarchy-unraid"
  // manageIpc left at its true default — the base Panel's own IpcHandler
  // (open/close/show/hide/toggle) covers everything this plugin needs.
  // Overriding it to own a custom IpcHandler (as weather/power do) is only
  // required once a milestone adds extra IPC methods of its own.

  property UnraidService service: UnraidService {}

  // "overview" | "docker" | "vms" | "storage" | "alerts" | "settings" — not
  // a tab-index because Settings is reached via the gear, not the tab row
  // (spec section 9: "Do not make Settings a sixth primary tab").
  property string activeView: "overview"

  readonly property var _tabs: [
    { key: "overview", label: "Overview" },
    { key: "docker", label: "Docker" },
    { key: "vms", label: "VMs" },
    { key: "storage", label: "Storage" },
    { key: "alerts", label: "Alerts" }
  ]

  // Milestone 1 health state: mock data is always reachable, so this only
  // reflects unread notifications / an in-progress parity check. Real
  // priority ladder (AUTH_ERROR > OFFLINE > CRITICAL > ...) arrives with
  // the connection manager in Milestone 3.
  readonly property string healthState: {
    if (service.unreadNotificationCount > 0) return "WARNING"
    if (service.arrayInfo.parityCheckStatus && service.arrayInfo.parityCheckStatus.running) return "NOTICE"
    return "HEALTHY"
  }

  readonly property string healthLabel: {
    switch (healthState) {
      case "WARNING": return "Attention needed"
      case "NOTICE": return "Parity check running"
      default: return "Healthy"
    }
  }

  implicitWidth: widgetButton.implicitWidth
  implicitHeight: widgetButton.implicitHeight

  WidgetButton {
    id: widgetButton
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.service.system.hostname + " — " + root.healthLabel + " — " + root.service.connection.type
    implicitWidth: barRow.implicitWidth + scaledHorizontalMargin * 2
    onPressed: function(b) { root.toggle() }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        text: "󰒋"
        color: widgetButton.foreground
        font.family: widgetButton.fontFamily
        font.pixelSize: widgetButton.fontSize
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.service.system.hostname
        color: widgetButton.foreground
        font.family: widgetButton.fontFamily
        font.pixelSize: widgetButton.fontSize
        anchors.verticalCenter: parent.verticalCenter
      }

      StatusDot {
        anchors.verticalCenter: parent.verticalCenter
        healthState: root.healthState
      }
    }
  }

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: widgetButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: keyboardPanel.fittedContentWidth(Style.space(440))
    // Natural height (fixed header + current tab's own content) capped at
    // 680px or the available screen height, whichever is smaller (spec
    // section 7). Short tabs (Settings, VMs) shrink the popup instead of
    // leaving dead space; tall tabs (Docker with many containers) hit the
    // cap and scroll internally via the ScrollView below.
    readonly property real naturalContentHeight: headerArea.height + (viewLoader.item ? viewLoader.item.implicitHeight : 0)
    contentHeight: keyboardPanel.fittedContentHeight(naturalContentHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        id: headerArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: hero.implicitHeight + tabRow.implicitHeight + separator1.height + separator2.height + Style.space(20)

        Column {
          anchors.fill: parent
          spacing: Style.space(10)

          PanelHero {
            id: hero
            width: parent.width
            title: root.service.system.hostname
            detail: root.service.connection.type
            meta: root.healthLabel + " · updated " + Model.relativeTime(root.service.connection.lastSuccess)
            foreground: root.barForeground
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰒋"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: PanelActionButton {
              iconText: "⚙"
              tooltipText: "Settings"
              foreground: root.barForeground
              onClicked: root.activeView = "settings"
            }
          }

          PanelSeparator { id: separator1; width: parent.width; foreground: root.barForeground }

          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root._tabs

              Button {
                required property var modelData
                text: modelData.key === "alerts" && root.service.unreadNotificationCount > 0
                  ? modelData.label + " (" + root.service.unreadNotificationCount + ")"
                  : modelData.label
                bordered: true
                selected: root.activeView === modelData.key
                foreground: root.barForeground
                onClicked: root.activeView = modelData.key
              }
            }
          }

          PanelSeparator { id: separator2; width: parent.width; foreground: root.barForeground }
        }
      }

      ScrollView {
        id: scrollView
        anchors.top: headerArea.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Loader {
          id: viewLoader
          width: scrollView.availableWidth
          sourceComponent: {
            switch (root.activeView) {
              case "docker": return dockerViewComponent
              case "vms": return vmsViewComponent
              case "storage": return storageViewComponent
              case "alerts": return alertsViewComponent
              case "settings": return settingsViewComponent
              default: return overviewViewComponent
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: diskConfirm
      anchors.fill: parent
      message: "Disk details\n\nSome current Unraid API versions may wake sleeping HDDs when detailed disk information is requested."
      cancelText: "Cancel"
      confirmText: "Load details"
      onCanceled: diskConfirm.opened = false
      onConfirmed: {
        diskConfirm.opened = false
        toast.show("Disk details view is coming once background polling is added.")
      }
    }

    Toast {
      id: toast
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
    }
  }

  Component {
    id: overviewViewComponent
    OverviewView {
      service: root.service
      foreground: root.barForeground
      onOpenWebUiRequested: toast.show("WebUI link needs a configured endpoint — coming in Milestone 2.")
      onOpenTerminalRequested: toast.show("SSH shortcut needs a configured host — coming in Milestone 2.")
    }
  }

  Component {
    id: dockerViewComponent
    DockerView {
      service: root.service
      foreground: root.barForeground
      onToastRequested: function(message) { toast.show(message) }
    }
  }

  Component {
    id: vmsViewComponent
    VmsView {
      service: root.service
      foreground: root.barForeground
      onToastRequested: function(message) { toast.show(message) }
    }
  }

  Component {
    id: storageViewComponent
    StorageView {
      service: root.service
      foreground: root.barForeground
      onLoadDiskDetailsRequested: diskConfirm.opened = true
    }
  }

  Component {
    id: alertsViewComponent
    AlertsView {
      service: root.service
      foreground: root.barForeground
    }
  }

  Component {
    id: settingsViewComponent
    SettingsView {
      service: root.service
      foreground: root.barForeground
    }
  }
}
