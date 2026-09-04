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

  function containerById(id) {
    var list = docker.containers || []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  // ------------------------------------------------------- docker actions
  //
  // One place that runs a mutation and then re-reads the truth (spec
  // section 45): lock, mutate, refresh, report. The reply's own state
  // field is ignored on purpose — a container mid-restart reports
  // whatever it happens to be at that instant, so the next Docker poll is
  // the authority.

  // { id, kind } while an action is in flight, so exactly the pressed
  // button shows its pending label and its siblings lock.
  property var dockerActionPending: null
  // Latched once the server refuses a control: the key is read-only, and
  // that won't change until the user grants it Docker update permission,
  // so there's no point leaving the buttons armed (spec section 39).
  property bool dockerControlsForbidden: false

  signal dockerActionFinished(string name, string kind, bool ok, string message)

  function dockerAction(kind, container) {
    if (!container || dockerActionPending || dockerControlsForbidden) return
    var query = kind === "start" ? Api.mutationDockerStart(container.id)
      : kind === "stop" ? Api.mutationDockerStop(container.id)
      : kind === "restart" ? Api.mutationDockerRestart(container.id)
      : ""
    if (query === "") return

    dockerActionPending = { id: container.id, kind: kind, name: container.name }
    actionRequest.send(query)
  }

  readonly property var logs: Api.normalizeLogs(logsQuery.result)
  readonly property bool logsFailing: logsQuery.failing && !logsQuery.hasData
  readonly property string logsErrorMessage: logsFailing ? logsQuery.errorMessage : ""

  // Set by the panel while the logs view is open; drives both the query
  // and whether it polls at all (spec section 20: only while open).
  property string logsContainerId: ""
  function refreshLogs() { logsQuery.refresh() }

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

  GraphQlRequest {
    id: actionRequest
    endpoint: root.endpoint
    secretStore: root.secretStore

    onSucceeded: function(data, errors) {
      var pending = root.dockerActionPending || ({})
      root.dockerActionPending = null
      // Mutations answer HTTP 200 with an errors array on refusal, so a
      // reply arriving is not the same as the action having happened.
      var first = errors && errors.length > 0 ? errors[0] : null
      if (first) {
        root._reportActionFailure(pending, first.message,
          first.extensions ? first.extensions.code : "")
        return
      }
      dockerQuery.refresh()
      root.dockerActionFinished(pending.name || "Container", pending.kind || "", true, "")
    }

    onFailed: function(reason, message) {
      var pending = root.dockerActionPending || ({})
      root.dockerActionPending = null
      root._reportActionFailure(pending, message, reason === "rejected" ? "REJECTED" : "")
    }
  }

  function _reportActionFailure(pending, message, code) {
    var forbidden = /forbidden|not allowed|permission/i.test(message || "")
      || code === "FORBIDDEN"
    if (forbidden) {
      root.dockerControlsForbidden = true
      root.dockerActionFinished(pending.name || "Container", pending.kind || "", false,
        "The API key isn't allowed to control Docker.")
      return
    }
    root.dockerActionFinished(pending.name || "Container", pending.kind || "", false, message)
  }

  ResourceQuery {
    id: logsQuery
    queryString: root.logsContainerId !== "" ? Api.queryDockerLogs(root.logsContainerId, 100) : ""
    endpoint: root.endpoint
    secretStore: root.secretStore
    // Only alive while the logs view has a container selected.
    active: root.active && root.logsContainerId !== ""
    panelOpen: root.panelOpen
    intervalOpen: 5000
    intervalClosed: 0
  }

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
