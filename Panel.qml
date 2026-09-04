pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "components"
import "views"
import "onboarding"
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

  property ConfigStore configStore: ConfigStore {}
  property SecretStore secretStore: SecretStore {}
  property UnraidService service: UnraidService { configStore: root.configStore }

  // "loading" | "setup" | "overview" | "docker" | "vms" | "storage" |
  // "alerts" | "settings". Not a tab-index because Settings is reached via
  // the gear, not the tab row (spec section 9), and setup/loading replace
  // the whole panel body (header + tabs included) rather than being a tab.
  property string activeView: "loading"

  // Decided once, the first time both stores finish their async startup
  // read (FileView load, secret-tool presence check) — not a live
  // `isConfigured ? ... : ...` binding, because that would yank the user
  // out of onboarding's "you're done" screen (step 3) the instant
  // SecretStore.store()/ConfigStore.save() succeed, before they click
  // Finish. See onboarding/SetupView.qml's header comment.
  readonly property bool bootstrapping: !configStore.loaded || !secretStore.checked
  readonly property bool isConfigured: configStore.serverUrl !== "" && secretStore.present
  property bool _initialViewChosen: false

  function _chooseInitialViewIfReady() {
    if (bootstrapping || _initialViewChosen) return
    _initialViewChosen = true
    activeView = isConfigured ? "overview" : "setup"
  }

  onBootstrappingChanged: _chooseInitialViewIfReady()
  Component.onCompleted: _chooseInitialViewIfReady()

  readonly property bool inFullPanelFlow: activeView === "loading" || activeView === "setup"

  readonly property var _tabs: [
    { key: "overview", label: "Overview" },
    { key: "docker", label: "Docker" },
    { key: "vms", label: "VMs" },
    { key: "storage", label: "Storage" },
    { key: "alerts", label: "Alerts" }
  ]

  // Milestone 2 health state: mock dashboard data is always "reachable",
  // so this only reflects unread notifications / an in-progress parity
  // check, or that setup hasn't happened yet. Real priority ladder
  // (AUTH_ERROR > OFFLINE > CRITICAL > ...) arrives with the connection
  // manager in Milestone 3.
  readonly property string healthState: {
    if (!isConfigured) return "NOTICE"
    if (service.unreadNotificationCount > 0) return "WARNING"
    if (service.arrayInfo.parityCheckStatus && service.arrayInfo.parityCheckStatus.running) return "NOTICE"
    return "HEALTHY"
  }

  readonly property string healthLabel: {
    if (!isConfigured) return "Not configured"
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
        text: root.isConfigured ? root.service.system.hostname : "Unraid"
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
    // Natural height caps at 680px or the available screen height (spec
    // section 7). During setup/loading there's no header/tabs, so the
    // full-panel-flow content drives height on its own.
    readonly property real naturalContentHeight: root.inFullPanelFlow
      ? (fullPanelLoader.item ? fullPanelLoader.item.implicitHeight : Style.space(160))
      : headerArea.height + (viewLoader.item ? viewLoader.item.implicitHeight : 0)
    contentHeight: keyboardPanel.fittedContentHeight(naturalContentHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // ---------------------------------------------------- loading/setup
      ScrollView {
        id: fullPanelScroll
        anchors.fill: parent
        visible: root.inFullPanelFlow
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Loader {
          id: fullPanelLoader
          width: fullPanelScroll.availableWidth
          sourceComponent: root.activeView === "setup" ? setupViewComponent : loadingViewComponent
        }
      }

      // --------------------------------------------------- normal tab UI
      Item {
        id: normalContent
        anchors.fill: parent
        visible: !root.inFullPanelFlow

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
    id: loadingViewComponent
    Column {
      width: parent ? parent.width : implicitWidth
      spacing: Style.space(8)
      Text {
        textFormat: Text.PlainText
        text: "Loading…"
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }

  Component {
    id: setupViewComponent
    SetupView {
      configStore: root.configStore
      secretStore: root.secretStore
      foreground: root.barForeground
      onFinished: root.activeView = "overview"
    }
  }

  Component {
    id: overviewViewComponent
    OverviewView {
      service: root.service
      foreground: root.barForeground
      onOpenWebUiRequested: toast.show("WebUI link needs a configured endpoint — coming in Milestone 3.")
      onOpenTerminalRequested: toast.show("SSH shortcut needs a configured host — coming in Milestone 3.")
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
      configStore: root.configStore
      secretStore: root.secretStore
      foreground: root.barForeground
    }
  }
}
