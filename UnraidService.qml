import QtQuick
import "Api.js" as Api
import "Model.js" as Model

// Owns the plugin's application state (spec section 35). Milestones 1–2
// served mock data here; this is the real thing — six independently polled
// GraphQL resources, normalized into exactly the properties the views were
// already binding to, so the views needed shape fixes rather than rewrites.
//
// Every resource keeps its own failure state on purpose. Docker or VMs
// being unavailable must never read as "the server is offline" (spec
// section 11 and acceptance tests E/F), so overall reachability is judged
// only on `metrics` + `array`, which a healthy server always answers.
Item {
  id: root

  property var configStore: null
  property var secretStore: null
  property bool panelOpen: false

  readonly property string endpoint: configStore ? configStore.graphqlUrl : ""
  readonly property bool active: endpoint !== "" && secretStore !== null && secretStore.present

  // --------------------------------------------------------- view-facing

  readonly property var system: {
    var base = Api.normalizeSystem(systemQuery.result)
    // Fall back to what onboarding already learned, so the bar shows the
    // right hostname before the first poll lands.
    if (base.hostname === "" && configStore) base.hostname = configStore.hostname
    if (base.unraidVersion === "" && configStore) base.unraidVersion = configStore.unraidVersion
    return base
  }

  readonly property var metrics: Api.normalizeMetrics(metricsQuery.result)
  readonly property var arrayInfo: Api.normalizeArray(arrayQuery.result)
  readonly property var docker: Api.normalizeDocker(dockerQuery.result)
  readonly property var vms: Api.normalizeVms(vmsQuery.result)

  readonly property var notificationSummary: Api.normalizeNotifications(notificationsQuery.result)
  readonly property var notifications: notificationSummary.items
  // The server's own unread counters, rather than counting the returned
  // list — the list is warnings+alerts only, the counters cover all kinds.
  readonly property int unreadNotificationCount:
    notificationSummary.unread.warning + notificationSummary.unread.alert

  readonly property var sortedContainers: Model.sortContainers(docker.containers)

  readonly property string dockerErrorMessage:
    (!docker.available && dockerQuery.failing) ? dockerQuery.errorMessage : ""
  readonly property string vmsErrorMessage:
    (!vms.available && vmsQuery.failing) ? vmsQuery.errorMessage : ""
  readonly property string arrayErrorMessage:
    (!arrayQuery.hasData && arrayQuery.failing) ? arrayQuery.errorMessage : ""

  // ------------------------------------------------------ connection state

  readonly property bool authFailed: systemQuery.errorReason === "rejected"
    || metricsQuery.errorReason === "rejected"
    || arrayQuery.errorReason === "rejected"
    || notificationsQuery.errorReason === "rejected"

  // Judged on the two resources a healthy server always answers, so a
  // Docker/VM subsystem outage is never mistaken for the server being down.
  readonly property bool unreachable: metricsQuery.errorReason === "unreachable"
    && arrayQuery.errorReason === "unreachable"

  readonly property real lastSuccess: Math.max(
    metricsQuery.lastSuccess, arrayQuery.lastSuccess, dockerQuery.lastSuccess,
    vmsQuery.lastSuccess, notificationsQuery.lastSuccess, systemQuery.lastSuccess)

  readonly property bool everLoaded: lastSuccess > 0

  readonly property var connection: ({
    state: !root.active ? "DISCONNECTED"
      : root.authFailed ? "AUTH_FAILED"
      : root.unreachable ? "OFFLINE"
      : root.everLoaded ? "CONNECTED_LAN" : "PROBING",
    // Endpoint discovery and LAN/Tailscale switching arrive with the
    // connection manager (Milestone 3); until then the configured server
    // is by definition the local one.
    type: root.unreachable ? "OFFLINE" : "LAN",
    name: "LAN",
    endpoint: configStore ? configStore.serverUrl : "",
    latencyMs: null,
    lastSuccess: root.lastSuccess
  })

  readonly property string uptime: Api.uptimeSince(system.bootTime)

  function notificationUrl(link) {
    return Api.notificationUrl(configStore ? configStore.serverUrl : "", link)
  }

  // ---------------------------------------------------------------- actions

  function refresh() {
    systemQuery.refresh()
    metricsQuery.refresh()
    arrayQuery.refresh()
    dockerQuery.refresh()
    vmsQuery.refresh()
    notificationsQuery.refresh()
  }

  function refreshMetrics() { metricsQuery.refresh() }
  function refreshArray() { arrayQuery.refresh() }
  function refreshDocker() { dockerQuery.refresh() }
  function refreshVms() { vmsQuery.refresh() }
  function refreshNotifications() { notificationsQuery.refresh() }

  // ------------------------------------------------------------- resources

  // Versions and boot time don't change while the shell runs, so the
  // system query has no interval — it runs on connect and manual refresh.
  ResourceQuery {
    id: systemQuery
    queryString: Api.QUERY_SYSTEM
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
  }

  ResourceQuery {
    id: metricsQuery
    queryString: Api.QUERY_METRICS
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 10000
    intervalClosed: 60000
  }

  ResourceQuery {
    id: arrayQuery
    queryString: Api.QUERY_ARRAY
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 15000
    intervalClosed: 60000
  }

  ResourceQuery {
    id: dockerQuery
    queryString: Api.QUERY_DOCKER
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 10000
    intervalClosed: 60000
  }

  ResourceQuery {
    id: vmsQuery
    queryString: Api.QUERY_VMS
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 10000
    intervalClosed: 60000
  }

  ResourceQuery {
    id: notificationsQuery
    queryString: Api.QUERY_NOTIFICATIONS
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 15000
    intervalClosed: 30000
  }
}
