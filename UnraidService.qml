import QtQuick
import Quickshell.Io
import qs.Commons
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
  property var connectionManager: null
  property bool panelOpen: false

  // The one seam the connection manager slots into: which URL is current.
  //
  // When a manager is attached it is the *only* authority, even while it
  // hasn't picked an endpoint yet (queries simply wait). An earlier
  // version fell back to configStore.graphqlUrl whenever the manager's
  // pick was empty, which meant traffic could quietly go somewhere other
  // than the chosen endpoint — during testing that masked a deliberately
  // broken endpoint and reported it as healthy.
  readonly property string endpoint: connectionManager
    ? connectionManager.activeGraphqlUrl
    : (configStore ? configStore.graphqlUrl : "")
  readonly property bool active: endpoint !== "" && secretStore !== null && secretStore.present

  // Spec section 34: offline shows cached values and disables controls.
  readonly property bool offline: connectionManager ? connectionManager.offline : root.unreachable

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
  // The per-disk lists ride along with the array summary, so they share its
  // query, its failure state and its freshness.
  readonly property var arrayDisks: arrayInfo.drives
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

  function domainById(id) {
    var list = vms.domains || []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  // -------------------------------------------------------------- actions
  //
  // One place that runs a mutation and then re-reads the truth (spec
  // section 45): lock, mutate, refresh, report. A mutation's own reply is
  // ignored beyond its error status — something mid-restart reports
  // whatever state it happens to be in at that instant, so the next poll
  // of the resource is the authority.
  //
  // Docker and VM actions share the slot and the request because they
  // share the one GraphQlRequest anyway, which serialises them regardless.
  // Views read the scope-specific aliases below, so each only ever sees
  // its own pending action.
  property var actionPending: null // { scope, kind, id, name }

  readonly property var dockerActionPending:
    (actionPending && actionPending.scope === "docker") ? actionPending : null
  readonly property var vmActionPending:
    (actionPending && actionPending.scope === "vm") ? actionPending : null

  // Latched once the server refuses a control: a read-only key won't start
  // working mid-session, so there's no point leaving the buttons armed
  // (spec section 39). Tracked per scope, since a key can perfectly well
  // be allowed to control one and not the other.
  property bool dockerControlsForbidden: false
  property bool vmControlsForbidden: false

  signal dockerActionFinished(string name, string kind, bool ok, string message)
  signal vmActionFinished(string name, string kind, bool ok, string message)

  function dockerAction(kind, container) {
    if (!container || actionPending || dockerControlsForbidden) return
    var query = kind === "start" ? Api.mutationDockerStart(container.id)
      : kind === "stop" ? Api.mutationDockerStop(container.id)
      : kind === "restart" ? Api.mutationDockerRestart(container.id)
      : ""
    if (query === "") return
    actionPending = { scope: "docker", id: container.id, kind: kind, name: container.name }
    actionRequest.send(query)
  }

  function vmAction(kind, domain) {
    if (!domain || actionPending || vmControlsForbidden) return
    var query = kind === "start" ? Api.mutationVmStart(domain.id)
      : kind === "stop" ? Api.mutationVmStop(domain.id)
      : kind === "reboot" ? Api.mutationVmReboot(domain.id)
      : kind === "pause" ? Api.mutationVmPause(domain.id)
      : kind === "resume" ? Api.mutationVmResume(domain.id)
      : kind === "forceStop" ? Api.mutationVmForceStop(domain.id)
      : ""
    if (query === "") return
    actionPending = { scope: "vm", id: domain.id, kind: kind, name: domain.name }
    actionRequest.send(query)
  }

  // ------------------------------------------------------- notifications

  property var notificationActionPending: null

  signal notificationArchived(string title, bool ok, string message)

  function archiveNotification(item) {
    if (!item || notificationActionPending) return
    notificationActionPending = { id: item.id, title: item.title }
    archiveRequest.send(Api.mutationArchiveNotification(item.id))
  }

  // Spec section 43: notify only for *newly observed* warnings and alerts,
  // and never twice for the same notification id.
  //
  // The first poll seeds the seen-set instead of announcing everything —
  // otherwise every shell restart would re-announce a backlog the user
  // already knows about.
  property bool desktopNotificationsEnabled: configStore
    ? configStore.desktopNotifications : false
  property var _seenNotificationIds: ({})
  property bool _notificationsSeeded: false

  function _handleNotifications() {
    var items = root.notifications || []
    if (!root._notificationsSeeded) {
      var seed = {}
      for (var i = 0; i < items.length; i++) seed[items[i].id] = true
      root._seenNotificationIds = seed
      root._notificationsSeeded = true
      return
    }

    var seen = {}
    for (var k in root._seenNotificationIds) seen[k] = root._seenNotificationIds[k]
    for (var j = 0; j < items.length; j++) {
      var item = items[j]
      if (seen[item.id]) continue
      seen[item.id] = true
      if (root.desktopNotificationsEnabled) root._sendDesktopNotification(item)
    }
    root._seenNotificationIds = seen
  }

  function _sendDesktopNotification(item) {
    var critical = item.importance === "ALERT"
    // execArgv, not a shell string: the title and description come from
    // the server. --exec makes clicking the notification open the panel
    // on the Alerts tab.
    Util.execArgv(["omarchy-notification-send",
      "--app-name", "Unraid",
      "-g", critical ? "󰀦" : "󰀨",
      "-u", critical ? "critical" : "normal",
      (root.system.hostname !== "" ? root.system.hostname : "Unraid") + " — " + item.title,
      item.subject !== "" ? item.subject : item.description,
      "--exec", "omarchy-shell", "io.github.b0d3ll.omarchy-unraid", "openAlerts"])
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
  // Distinguishes "waiting for the first reply" from "the array genuinely
  // has no disks", so the Storage view can say the right one.
  readonly property bool arrayPending: !arrayQuery.hasData && !arrayQuery.failing

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

  // Data old enough that showing it without saying so would be
  // misleading — spec section 5's STALE. Deliberately judged on the age of
  // the data rather than on whether a query just failed: the connection
  // manager may still be working through endpoints, and one failed poll
  // doesn't make the numbers on screen wrong yet.
  //
  // Computed on a timer rather than as a binding: a binding on Date.now()
  // has nothing to invalidate it, so it would answer once and then never
  // change its mind.
  property bool stale: false
  // Recomputed alongside it, because "updated just now" in the header was
  // otherwise frozen at whatever it said when the poll landed.
  property string lastSuccessLabel: "never"
  // Same trap, and it used to be a binding: `uptime` is the age of a boot
  // timestamp that never changes, so the binding evaluated once and then
  // held that answer for the life of the shell. Invisible while it only
  // appeared in Settings; not once Overview shows it.
  property string uptime: ""

  function _refreshAges() {
    stale = everLoaded && (Date.now() - lastSuccess > 180000)
    lastSuccessLabel = Model.relativeTime(lastSuccess)
    uptime = Api.uptimeSince(system.bootTime)
  }

  onLastSuccessChanged: _refreshAges()
  // bootTime arrives with the first system poll, which lands between ticks.
  onSystemChanged: root.uptime = Api.uptimeSince(root.system.bootTime)

  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root._refreshAges()
  }

  readonly property var connection: ({
    state: !root.active ? "DISCONNECTED"
      : root.authFailed ? "AUTH_FAILED"
      : root.offline ? "OFFLINE"
      : connectionManager ? connectionManager.connectionState
      : (root.everLoaded ? "CONNECTED" : "PROBING"),
    // The badge shows which transport is carrying the connection, which
    // is now a real answer rather than an assumption.
    type: root.offline ? "OFFLINE"
      : (connectionManager && connectionManager.activeType !== "")
        ? connectionManager.activeType : "LAN",
    name: (connectionManager && connectionManager.activeName !== "")
      ? connectionManager.activeName : "LAN",
    endpoint: (connectionManager && connectionManager.activeEndpoint)
      ? connectionManager.activeEndpoint.baseUrl
      : (configStore ? configStore.serverUrl : ""),
    latencyMs: connectionManager ? connectionManager.latencyMs : -1,
    lastSuccess: root.lastSuccess
  })


  // Follows the *active* endpoint: on Tailscale, a notification should
  // open over Tailscale rather than at a LAN address that isn't reachable.
  function notificationUrl(link) {
    return Api.notificationUrl(root.connection.endpoint, link)
  }

  // ------------------------------------------------------------- discovery
  //
  // Proposes endpoints; never adopts them (spec section 42). Two sources,
  // because neither is sufficient alone: the server advertises its LAN
  // names but — verified on a real 7.3.2 box — no remote URL at all, while
  // the local Tailscale client knows the tailnet address the server itself
  // never mentions.

  property var discovered: []
  property bool discovering: false
  property string discoveryNote: ""

  function discoverEndpoints() {
    if (discovering) return
    discovering = true
    discovered = []
    discoveryNote = ""
    _discoveryPending = 2
    accessUrlsRequest.send(Api.QUERY_ACCESS_URLS)
    tailscaleProc.running = true
  }

  property int _discoveryPending: 0

  function _addDiscovered(list) {
    if (!list || list.length === 0) return
    var existing = []
    var configured = endpointList
    for (var i = 0; i < configured.length; i++) existing.push(configured[i].graphqlUrl)
    for (var j = 0; j < discovered.length; j++) existing.push(discovered[j].graphqlUrl)

    var merged = discovered.slice()
    for (var k = 0; k < list.length; k++) {
      if (existing.indexOf(list[k].graphqlUrl) >= 0) continue
      existing.push(list[k].graphqlUrl)
      merged.push(list[k])
    }
    discovered = merged
  }

  function _finishDiscoveryStep() {
    _discoveryPending = Math.max(0, _discoveryPending - 1)
    if (_discoveryPending > 0) return
    discovering = false
    if (discovered.length === 0) {
      discoveryNote = "No new endpoints found. The server advertises only the "
        + "address you already use, and no matching Tailscale peer was seen."
    }
  }

  readonly property var endpointList: configStore ? (configStore.endpoints || []) : []

  function addEndpoint(endpoint) {
    if (!configStore || !endpoint) return
    var list = endpointList.slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].graphqlUrl === endpoint.graphqlUrl) return
    }
    list.push(endpoint)
    configStore.saveEndpoints(list)
    discovered = discovered.filter(function(d) { return d.graphqlUrl !== endpoint.graphqlUrl })
  }

  function removeEndpoint(id) {
    if (!configStore) return
    configStore.saveEndpoints(endpointList.filter(function(e) { return e.id !== id }))
  }

  function setEndpointEnabled(id, enabled) {
    if (!configStore) return
    configStore.saveEndpoints(endpointList.map(function(e) {
      return e.id === id ? Object.assign({}, e, { enabled: enabled }) : e
    }))
  }

  // Priority is what the selector orders by, so moving an endpoint is just
  // renumbering the list after a swap.
  function moveEndpoint(id, delta) {
    if (!configStore) return
    var list = endpointList.slice().sort(function(a, b) { return a.priority - b.priority })
    var index = -1
    for (var i = 0; i < list.length; i++) if (list[i].id === id) index = i
    var target = index + delta
    if (index < 0 || target < 0 || target >= list.length) return
    var moved = list[index]
    list[index] = list[target]
    list[target] = moved
    configStore.saveEndpoints(list.map(function(e, n) {
      return Object.assign({}, e, { priority: n })
    }))
  }

  // ---------------------------------------------------------------- actions

  function refresh() {
    // Spec section 33: Refresh forces an immediate connection retry, not
    // just a re-poll. Without this, hitting Refresh while offline did
    // nothing until the backoff timer came round again — up to five
    // minutes later.
    if (connectionManager) connectionManager.probeNow()
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
    id: accessUrlsRequest
    endpoint: root.endpoint
    secretStore: root.secretStore

    onSucceeded: function(data, errors) {
      var existing = []
      for (var i = 0; i < root.endpointList.length; i++) existing.push(root.endpointList[i].graphqlUrl)
      root._addDiscovered(Api.accessUrlCandidates(Api.normalizeAccessUrls(data), existing))
      root._finishDiscoveryStep()
    }

    onFailed: function(reason, message) {
      root.discoveryNote = "Could not ask the server for its addresses: " + message
      root._finishDiscoveryStep()
    }
  }

  // Same commands Omarchy's own tailscale plugin uses
  // (plugins/panels/tailscale/Service.qml). A stopped or absent client
  // simply yields no candidates rather than being an error — Tailscale is
  // optional (spec section 29).
  Process {
    id: tailscaleProc
    command: ["tailscale", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var existing = []
        for (var i = 0; i < root.endpointList.length; i++) existing.push(root.endpointList[i].graphqlUrl)
        root._addDiscovered(Api.tailscaleCandidates(text, root.system.hostname, existing))
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root._finishDiscoveryStep() }
  }

  GraphQlRequest {
    id: archiveRequest
    endpoint: root.endpoint
    secretStore: root.secretStore

    onSucceeded: function(data, errors) {
      var pending = root.notificationActionPending || ({})
      root.notificationActionPending = null
      var first = errors && errors.length > 0 ? errors[0] : null
      if (first) {
        root.notificationArchived(pending.title || "Notification", false, first.message)
        return
      }
      notificationsQuery.refresh()
      root.notificationArchived(pending.title || "Notification", true, "")
    }

    onFailed: function(reason, message) {
      var pending = root.notificationActionPending || ({})
      root.notificationActionPending = null
      root.notificationArchived(pending.title || "Notification", false, message)
    }
  }

  GraphQlRequest {
    id: actionRequest
    endpoint: root.endpoint
    secretStore: root.secretStore

    onSucceeded: function(data, errors) {
      var pending = root.actionPending || ({})
      root.actionPending = null
      // Mutations answer HTTP 200 with an errors array on refusal, so a
      // reply arriving is not the same as the action having happened.
      var first = errors && errors.length > 0 ? errors[0] : null
      if (first) {
        root._reportActionFailure(pending, first.message,
          first.extensions ? first.extensions.code : "")
        return
      }
      if (pending.scope === "vm") {
        vmsQuery.refresh()
        root.vmActionFinished(pending.name || "VM", pending.kind || "", true, "")
      } else {
        dockerQuery.refresh()
        root.dockerActionFinished(pending.name || "Container", pending.kind || "", true, "")
      }
    }

    onFailed: function(reason, message) {
      var pending = root.actionPending || ({})
      root.actionPending = null
      root._reportActionFailure(pending, message, reason === "rejected" ? "REJECTED" : "")
    }
  }

  function _reportActionFailure(pending, message, code) {
    var isVm = pending.scope === "vm"
    var subject = pending.name || (isVm ? "VM" : "Container")
    var forbidden = /forbidden|not allowed|permission/i.test(message || "")
      || code === "FORBIDDEN"

    if (forbidden) {
      if (isVm) {
        root.vmControlsForbidden = true
        root.vmActionFinished(subject, pending.kind || "", false,
          "The API key isn't allowed to control VMs.")
      } else {
        root.dockerControlsForbidden = true
        root.dockerActionFinished(subject, pending.kind || "", false,
          "The API key isn't allowed to control Docker.")
      }
      return
    }

    if (isVm) root.vmActionFinished(subject, pending.kind || "", false, message)
    else root.dockerActionFinished(subject, pending.kind || "", false, message)
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
    // metrics and array are the two resources a healthy server always
    // answers, so they're the ones whose reachability is allowed to move
    // the connection manager. A Docker or VM outage must never trigger a
    // failover (spec section 11).
    onOutcome: function(ok, reason, forEndpoint) {
      if (!root.connectionManager) return
      if (ok) root.connectionManager.reportSuccess(forEndpoint)
      else root.connectionManager.reportFailure(reason, forEndpoint)
    }
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
    onOutcome: function(ok, reason, forEndpoint) {
      if (!root.connectionManager) return
      if (ok) root.connectionManager.reportSuccess(forEndpoint)
      else root.connectionManager.reportFailure(reason, forEndpoint)
    }
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
    onLoaded: root._handleNotifications()
    queryString: Api.QUERY_NOTIFICATIONS
    endpoint: root.endpoint
    secretStore: root.secretStore
    active: root.active
    panelOpen: root.panelOpen
    intervalOpen: 15000
    intervalClosed: 30000
  }
}
