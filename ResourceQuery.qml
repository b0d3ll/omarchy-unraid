import QtQuick

// One polled GraphQL resource, with its own loading/error/timestamp state
// (spec section 36). Each resource gets its own instance — and therefore
// its own request and its own Process — so a Docker outage can't take
// array data down with it, and six pollers never fight over one process.
//
// Intervals follow spec section 37: slower while the panel is closed,
// faster while it's open, and an immediate refresh when the panel opens or
// the user switches to the view that needs this resource. Failure retry is
// just the normal interval here; the escalating offline backoff from spec
// section 33 belongs to the connection manager in Milestone 3.
Item {
  id: root

  property string queryString: ""
  property string endpoint: ""
  property var secretStore: null

  // 0 disables timed polling (used for rarely-changing data like versions,
  // which is fetched on connect and on manual refresh only).
  property int intervalOpen: 0
  property int intervalClosed: 0

  property bool panelOpen: false
  property bool active: false

  property var result: null
  property var errors: []
  property bool loading: false
  property string errorReason: ""
  property string errorMessage: ""
  property real lastSuccess: 0

  readonly property bool hasData: result !== null
  readonly property bool failing: errorReason !== ""

  signal loaded(var data)

  function refresh() {
    if (!root.active || queryString === "") return
    if (request.busy) return
    loading = true
    request.send(queryString)
  }

  onActiveChanged: if (root.active) Qt.callLater(root.refresh)
  onPanelOpenChanged: if (root.panelOpen) root.refresh()

  GraphQlRequest {
    id: request
    endpoint: root.endpoint
    secretStore: root.secretStore

    onSucceeded: function(data, errors) {
      root.loading = false
      root.errorReason = ""
      root.errorMessage = ""
      root.errors = errors
      root.result = data
      root.lastSuccess = Date.now()
      root.loaded(data)
    }

    onFailed: function(reason, message) {
      root.loading = false
      root.errorReason = reason
      root.errorMessage = message
      // Deliberately keeps the previous `data` so a single failed poll
      // doesn't blank a working view — spec section 48: never blank the
      // panel while refreshing.
    }
  }

  Timer {
    interval: {
      var ms = root.panelOpen ? root.intervalOpen : root.intervalClosed
      return ms > 0 ? ms : 60000
    }
    repeat: true
    running: root.active && (root.panelOpen ? root.intervalOpen : root.intervalClosed) > 0
    onTriggered: root.refresh()
  }
}
