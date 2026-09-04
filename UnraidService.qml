import QtQuick
import "Model.js" as Model

// Owns the plugin's application state (spec section 35). Milestone 1 only
// ever held mock data. Milestone 2 widens one seam: once onboarding has
// learned a real server's identity (via ConfigStore), the hostname/version
// shown in the bar and header are real — everything else (Docker, VMs,
// array, metrics, notifications) stays mock until Milestone 4 wires actual
// GraphQL queries. Views never notice the difference; they just bind to
// `system`/`connection` like always.
QtObject {
  id: root

  property var configStore: null

  readonly property var _mock: Model.mockState()

  readonly property var system: {
    var base = root._mock.system
    if (!configStore || configStore.hostname === "") return base
    return {
      hostname: configStore.hostname,
      unraidVersion: configStore.unraidVersion !== "" ? configStore.unraidVersion : base.unraidVersion,
      apiVersion: base.apiVersion
    }
  }

  readonly property var connection: {
    var base = root._mock.connection
    if (!configStore || configStore.serverUrl === "") return base
    return {
      state: base.state,
      type: base.type,
      name: base.name,
      endpoint: configStore.serverUrl,
      latencyMs: base.latencyMs,
      lastSuccess: base.lastSuccess
    }
  }

  property var metrics: _mock.metrics
  property var arrayInfo: _mock.array
  property var docker: _mock.docker
  property var vms: _mock.vms
  property var notifications: _mock.notifications

  readonly property int unreadNotificationCount: Model.unreadCount(notifications)

  readonly property var sortedContainers: docker && docker.containers
    ? Model.sortContainers(docker.containers)
    : []

  // No-op in Milestone 2 — real polling/refresh logic lands in Milestone 4.
  function refresh() {}
  function refreshDocker() {}
  function refreshVms() {}
  function refreshNotifications() {}
}
