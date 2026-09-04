import QtQuick
import "Model.js" as Model

// Owns the plugin's application state (spec section 35). Milestone 1 only
// ever holds mock data — no GraphQL, no polling, no connection handling.
// Views bind to these properties so later milestones can swap mockState()
// for real query results without touching view code.
QtObject {
  id: root

  property var connection: Model.mockState().connection
  property var system: Model.mockState().system
  property var metrics: Model.mockState().metrics
  property var arrayInfo: Model.mockState().array
  property var docker: Model.mockState().docker
  property var vms: Model.mockState().vms
  property var notifications: Model.mockState().notifications

  readonly property int unreadNotificationCount: Model.unreadCount(notifications)

  readonly property var sortedContainers: docker && docker.containers
    ? Model.sortContainers(docker.containers)
    : []

  // No-op in Milestone 1 — real polling/refresh logic lands in Milestone 3/4.
  function refresh() {}
  function refreshDocker() {}
  function refreshVms() {}
  function refreshNotifications() {}
}
