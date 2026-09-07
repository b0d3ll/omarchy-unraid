pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "components"
import "views"
import "onboarding"

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
  property ConnectionManager connectionManager: ConnectionManager {
    configStore: root.configStore
    secretStore: root.secretStore
    panelOpen: root.opened && !root.inFullPanelFlow
  }
  property UnraidService service: UnraidService {
    configStore: root.configStore
    secretStore: root.secretStore
    connectionManager: root.connectionManager
    // Polling slows down while the panel is closed (spec section 37).
    panelOpen: root.opened && !root.inFullPanelFlow
  }

  // "loading" | "setup" | "overview" | "docker" | "dockerDetail" |
  // "dockerLogs" | "vms" | "vmDetail" | "storage" | "alerts" | "settings". Not a
  // tab-index because Settings is reached via the gear, not the tab row
  // (spec section 9), and setup/loading replace the whole panel body
  // (header + tabs included) rather than being a tab.
  property string activeView: "loading"

  // Which container / VM the subviews are showing.
  property string selectedContainerId: ""
  property string selectedDomainId: ""

  // A tab stays lit while you're inside one of its subviews.
  function tabIsActive(key) {
    if (key === "docker") return activeView.indexOf("docker") === 0
    if (key === "vms") return activeView === "vms" || activeView === "vmDetail"
    return activeView === key
  }

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

  // Spec section 5's priority ladder, complete now that the connection
  // manager can tell "never loaded" (CONNECTING) from "unreachable but we
  // still have data to show" (STALE).
  readonly property string healthState: {
    if (!isConfigured) return "NOTICE"
    if (service.authFailed) return "AUTH_ERROR"
    // The connection manager is the single authority on reachability.
    // Reading a separate "both core queries failed" signal here as well
    // produced contradictions — DEGRADED-but-working reported as OFFLINE,
    // because the queries' last error lingers until the next success.
    //
    // Offline with nothing cached is worse than offline with data: the
    // former shows an empty panel, the latter shows the last known state
    // and says how old it is (spec section 34).
    if (service.offline) return service.everLoaded ? "STALE" : "OFFLINE"
    if (!service.everLoaded) return "CONNECTING"
    if (service.stale) return "STALE"
    var array = service.arrayInfo
    var parity = array.parityCheckStatus || ({})
    // A missing disk is unambiguous — the drive isn't there. Disabled and
    // invalid disks are not: they're also what a routine disk-clear or
    // rebuild looks like while it runs, so they're a notice rather than an
    // alarm. The label still names the actual condition, so nothing is
    // hidden, only de-escalated.
    if ((array.missing || 0) > 0) return "CRITICAL"
    if (service.notificationSummary.unread.alert > 0) return "CRITICAL"
    if ((parity.errors || 0) > 0) return "WARNING"
    if (service.notificationSummary.unread.warning > 0) return "WARNING"
    if ((array.disabled || 0) > 0 || (array.invalid || 0) > 0) return "NOTICE"
    if (parity.running || (array.state !== "" && array.state !== "STARTED")) return "NOTICE"
    return "HEALTHY"
  }

  readonly property string healthLabel: {
    if (!isConfigured) return "Not configured"
    var array = service.arrayInfo
    var parity = array.parityCheckStatus || ({})
    switch (healthState) {
      case "AUTH_ERROR": return "API key rejected"
      case "OFFLINE": return "Unreachable"
      case "STALE": return "Stale · last seen " + service.lastSuccessLabel
      case "CRITICAL":
        if ((array.missing || 0) > 0) return "Array disk missing"
        return "Alert needs attention"
      case "WARNING": return "Attention needed"
      case "NOTICE":
        if ((array.disabled || 0) > 0) return "Array disk disabled"
        if ((array.invalid || 0) > 0) return "Array disk rebuilding"
        if (parity.running) return "Parity check running"
        if (array.state !== "" && array.state !== "STARTED") return "Array " + array.state.toLowerCase()
        return "Notice"
      case "CONNECTING": return "Connecting…"
      default: return "Healthy"
    }
  }

  // Spec section 37: entering a view refreshes that view's resource at
  // once. Leaving the logs view clears the container id, which is what
  // stops the 5-second log polling (spec section 20).
  onActiveViewChanged: {
    service.logsContainerId = activeView === "dockerLogs" ? selectedContainerId : ""
    if (!service.active) return
    switch (activeView) {
      case "overview": service.refreshMetrics(); service.refreshArray(); break
      case "docker":
      case "dockerDetail": service.refreshDocker(); break
      case "vms":
      case "vmDetail": service.refreshVms(); break
      case "storage": service.refreshArray(); break
      case "alerts": service.refreshNotifications(); break
    }
  }

  // Raised by a view that wants confirmation before acting (spec section
  // 19); the dialog itself is shared, so it carries what to do on confirm.
  property var pendingConfirm: null

  function askConfirm(message, confirmText, action) {
    pendingConfirm = { message: message, confirmText: confirmText, action: action }
    confirmDialog.opened = true
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
              meta: root.healthLabel + " · updated " + root.service.lastSuccessLabel
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
              // The transport badge moved out of the hero's `detail` pill
              // and into the trailing row so it can carry a tooltip —
              // spec section 8 wants hovering it to reveal the endpoint
              // and latency rather than showing the address permanently.
              trailingControl: Row {
                spacing: Style.space(8)

                ConnectionBadge {
                  anchors.verticalCenter: parent.verticalCenter
                  connectionType: root.service.connection.type
                  foreground: root.barForeground
                  tooltipText: {
                    var c = root.service.connection
                    var lines = []
                    if (c.state === "OFFLINE") {
                      lines.push("Offline — last seen " + root.service.lastSuccessLabel)
                    } else {
                      lines.push("Connected via " + (c.name !== "" ? c.name : c.type))
                    }
                    if (c.endpoint !== "") lines.push(c.endpoint)
                    if (c.latencyMs >= 0) lines.push("Latency: " + c.latencyMs + " ms")
                    return lines.join("\n")
                  }
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "⚙"
                  tooltipText: "Settings"
                  foreground: root.barForeground
                  onClicked: root.activeView = "settings"
                }
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
                  selected: root.tabIsActive(modelData.key)
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
                case "dockerDetail": return dockerDetailViewComponent
                case "dockerLogs": return dockerLogsViewComponent
                case "vms": return vmsViewComponent
                case "vmDetail": return vmDetailViewComponent
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

    // Shared by the disk-details warning and the Docker stop/restart
    // confirmations — whatever raised it supplies the message and what to
    // run on confirm.
    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      message: root.pendingConfirm ? root.pendingConfirm.message : ""
      cancelText: "Cancel"
      confirmText: root.pendingConfirm ? root.pendingConfirm.confirmText : "Confirm"
      onCanceled: {
        confirmDialog.opened = false
        root.pendingConfirm = null
      }
      onConfirmed: {
        var action = root.pendingConfirm ? root.pendingConfirm.action : null
        confirmDialog.opened = false
        root.pendingConfirm = null
        if (action) action()
      }
    }

    Toast {
      id: toast
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
    }
  }

  // Spec section 45: report the outcome once the server has confirmed it.
  Connections {
    target: root.service

    function onDockerActionFinished(name, kind, ok, message) {
      if (ok) {
        var verb = kind === "start" ? "started" : kind === "stop" ? "stopped" : "restarted"
        toast.show(name + " " + verb)
      } else {
        toast.show(message !== "" ? message : name + " could not be " + kind + "ed")
      }
    }

    function onVmActionFinished(name, kind, ok, message) {
      if (ok) {
        var verb = kind === "start" ? "started"
          : kind === "stop" ? "stopped"
          : kind === "reboot" ? "rebooted"
          : kind === "pause" ? "paused"
          : kind === "resume" ? "resumed"
          : "force stopped"
        toast.show(name + " " + verb)
      } else {
        toast.show(message !== "" ? message : name + " could not be " + kind + "ed")
      }
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
      onToastRequested: function(message) { toast.show(message) }
    }
  }

  Component {
    id: dockerViewComponent
    DockerView {
      service: root.service
      foreground: root.barForeground
      onToastRequested: function(message) { toast.show(message) }
      onContainerSelected: function(containerId) {
        root.selectedContainerId = containerId
        root.activeView = "dockerDetail"
      }
    }
  }

  Component {
    id: dockerDetailViewComponent
    DockerDetailView {
      service: root.service
      containerId: root.selectedContainerId
      foreground: root.barForeground
      onBackRequested: root.activeView = "docker"
      onLogsRequested: root.activeView = "dockerLogs"
      onConfirmRequested: function(message, confirmText, kind) {
        root.askConfirm(message, confirmText, function() {
          root.service.dockerAction(kind, root.service.containerById(root.selectedContainerId))
        })
      }
    }
  }

  Component {
    id: dockerLogsViewComponent
    DockerLogsView {
      service: root.service
      containerId: root.selectedContainerId
      foreground: root.barForeground
      onBackRequested: root.activeView = "dockerDetail"
    }
  }

  Component {
    id: vmsViewComponent
    VmsView {
      service: root.service
      foreground: root.barForeground
      onToastRequested: function(message) { toast.show(message) }
      onDomainSelected: function(domainId) {
        root.selectedDomainId = domainId
        root.activeView = "vmDetail"
      }
    }
  }

  Component {
    id: vmDetailViewComponent
    VmDetailView {
      service: root.service
      domainId: root.selectedDomainId
      foreground: root.barForeground
      onBackRequested: root.activeView = "vms"
      onConfirmRequested: function(message, confirmText, kind) {
        root.askConfirm(message, confirmText, function() {
          root.service.vmAction(kind, root.service.domainById(root.selectedDomainId))
        })
      }
    }
  }

  Component {
    id: storageViewComponent
    StorageView {
      service: root.service
      foreground: root.barForeground
      onLoadDiskDetailsRequested: root.askConfirm(
        "Disk details\n\nSome current Unraid API versions may wake sleeping HDDs when detailed disk information is requested.",
        "Load details",
        function() { toast.show("Disk details view is coming once background polling is added.") })
    }
  }

  Component {
    id: alertsViewComponent
    AlertsView {
      service: root.service
      foreground: root.barForeground
      onToastRequested: function(message) { toast.show(message) }
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
