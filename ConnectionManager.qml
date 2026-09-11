import QtQuick
import "Api.js" as Api
import "Selection.js" as Selection

// Picks which endpoint the plugin talks to, and keeps picking it as the
// network changes underneath (spec sections 30-33). The whole point is
// that walking out of the house needs no interaction: LAN stops
// answering, this moves to Tailscale, and coming home moves back.
//
// The decisions themselves live in Selection.js as pure functions so they
// can be unit-tested (tests/selection.test.js covers the spec's own
// acceptance tests A-D). This file is the machinery around them: the
// probe, the counters, the timers.
//
// Which endpoint is live is in-memory only. Persisting it would mean a
// config file write on every network blip; the endpoint *list* is what's
// worth keeping on disk.
Item {
  id: root

  property var configStore: null
  property var secretStore: null
  readonly property bool allowSelfSigned:
    configStore ? configStore.allowSelfSigned : false
  property bool panelOpen: false

  readonly property var endpoints: configStore ? (configStore.endpoints || []) : []

  property string activeId: ""
  readonly property var activeEndpoint: Selection.findById(endpoints, activeId)
  readonly property string activeGraphqlUrl: activeEndpoint ? activeEndpoint.graphqlUrl : ""
  readonly property string activeType: activeEndpoint ? activeEndpoint.type : ""
  readonly property string activeName: activeEndpoint ? activeEndpoint.name : ""

  // "CONNECTING" until something answers, "CONNECTED" on the preferred
  // endpoint, "DEGRADED" when running on a fallback, "OFFLINE" when
  // nothing answers at all.
  readonly property string connectionState: {
    if (endpoints.length === 0) return "OFFLINE"
    if (offline) return "OFFLINE"
    if (lastSuccess === 0) return "CONNECTING"
    // Mid-failover the current pick is already known to be failing, so
    // reporting CONNECTED just because it's the preferred endpoint would
    // be wrong.
    if ((failures[activeId] || 0) > 0) return "CONNECTING"
    var best = Selection.candidates(endpoints)[0]
    if (best && best.id !== activeId) return "DEGRADED"
    return "CONNECTED"
  }

  property bool offline: false
  property real lastSuccess: 0
  property int latencyMs: -1

  // Per-endpoint consecutive failure and probe-success counters. Kept as
  // plain objects so Selection.js can reason about them without knowing
  // anything about QML.
  property var failures: ({})
  property var promotions: ({})
  property int offlineAttempts: 0

  signal switched(string fromId, string toId, string reason)

  // ------------------------------------------------------------- reporting
  //
  // Real data queries report their outcome here, so a failing endpoint is
  // noticed by actual traffic rather than only by the next dedicated
  // probe — that's the difference between failing over in seconds and
  // failing over in a minute.

  function reportSuccess(forEndpoint) {
    if (activeId === "") return
    if (!_isForActive(forEndpoint)) return
    failures = Selection.recordSuccess(failures, activeId)
    lastSuccess = Date.now()
    offline = false
    offlineAttempts = 0
    retryTimer.stop()
    _evaluate()
  }

  function reportFailure(reason, forEndpoint) {
    if (activeId === "") return
    // A reply from a request sent before the last failover says nothing
    // about the endpoint we're on now.
    if (!_isForActive(forEndpoint)) return
    // Only reachability counts toward failover. A rejected key or a
    // malformed reply means we reached the right box and it said no —
    // switching endpoints wouldn't help and would just hide the problem.
    if (reason !== "unreachable") return
    failures = Selection.recordFailure(failures, activeId)
    _evaluate()
  }

  // An absent endpoint means the caller didn't track one; accept it
  // rather than silently dropping every report.
  function _isForActive(forEndpoint) {
    if (!forEndpoint || forEndpoint === "") return true
    return forEndpoint === activeGraphqlUrl
  }

  function probeNow() {
    offlineAttempts = 0
    _probeActive()
    _probePromotionTargets()
  }

  // --------------------------------------------------------------- internals

  function _evaluate() {
    var verdict = Selection.decide({
      endpoints: endpoints,
      activeId: activeId,
      failures: failures,
      promotions: promotions,
      offlineAttempts: offlineAttempts
    })

    if (verdict.action === "switch" && verdict.endpointId !== activeId) {
      var from = activeId
      activeId = verdict.endpointId
      // A fresh endpoint starts with a clean slate, and the promotion
      // credit that got it here is spent.
      failures = Selection.recordSuccess(failures, activeId)
      promotions = Selection.recordProbe(promotions, activeId, false)
      offline = false
      latencyMs = -1
      root.switched(from, activeId, verdict.reason)
      return
    }

    if (verdict.action === "offline") {
      offline = true
      retryTimer.interval = verdict.retryDelayMs
      retryTimer.restart()
    }

    // Deliberately does NOT clear `offline` here. A "keep" verdict only
    // means "don't switch yet" — after an offline retry sweep resets the
    // counters, the first single failure produces "keep", and clearing the
    // flag on that basis had the panel announcing CONNECTED to an address
    // that answers nothing. Only an actual success ends being offline,
    // which is reportSuccess()'s job.
  }

  // Takes the endpoint *object* rather than reading activeGraphqlUrl,
  // because that's a binding derived from activeId: read it immediately
  // after assigning activeId and it can still hold the previous value,
  // since QML hasn't re-evaluated the binding yet. That bit here — a probe
  // went to the old (working) address while being labelled with the new
  // (broken) endpoint's id, so the broken one was credited with a 127 ms
  // success and the plugin flapped between the two.
  function _probeEndpoint(endpoint) {
    if (!endpoint || !endpoint.graphqlUrl) return
    // Bail out before touching the bookkeeping: send() refuses while a
    // request is in flight, so relabelling first would misattribute a
    // reply that's still on its way.
    if (probe.busy) return
    probe.probeId = endpoint.id
    probe.startedAt = Date.now()
    probe.endpoint = endpoint.graphqlUrl
    probe.send(Api.QUERY_HEALTH)
  }

  function _probeActive() {
    _probeEndpoint(Selection.findById(endpoints, activeId))
  }

  // Probe the endpoints ranked above the current one, so a recovered LAN
  // can earn its way back (spec section 31). Only one at a time — the
  // request object serialises anyway.
  function _probePromotionTargets() {
    var targets = Selection.promotionTargets(endpoints, activeId)
    if (targets.length === 0) return
    // Same ordering rule as _probeActive: check busy before relabelling.
    if (promotionProbe.busy) return
    promotionProbe.probeId = targets[0].id
    promotionProbe.endpoint = targets[0].graphqlUrl
    promotionProbe.send(Api.QUERY_HEALTH)
  }

  onEndpointsChanged: {
    if (activeId === "" || !Selection.isSelectable(endpoints, activeId)) _evaluate()
  }

  Component.onCompleted: _evaluate()

  GraphQlRequest {
    id: probe
    secretStore: root.secretStore
    allowSelfSigned: root.allowSelfSigned
    timeoutSeconds: 2

    property string probeId: ""
    property real startedAt: 0

    onSucceeded: function(data, errors) {
      if (probe.probeId !== root.activeId) return
      root.latencyMs = Math.max(0, Math.round(Date.now() - probe.startedAt))
      root.reportSuccess()
    }

    onFailed: function(reason, message) {
      if (probe.probeId !== root.activeId) return
      root.latencyMs = -1
      root.reportFailure(reason)
    }
  }

  GraphQlRequest {
    id: promotionProbe
    secretStore: root.secretStore
    allowSelfSigned: root.allowSelfSigned
    timeoutSeconds: 2

    property string probeId: ""

    onSucceeded: function(data, errors) {
      root.promotions = Selection.recordProbe(root.promotions, promotionProbe.probeId, true)
      // A recovered endpoint shouldn't stay marked as failing, or the
      // switch would be refused the moment it's promoted.
      root.failures = Selection.recordSuccess(root.failures, promotionProbe.probeId)
      root._evaluate()
    }

    onFailed: function(reason, message) {
      root.promotions = Selection.recordProbe(root.promotions, promotionProbe.probeId, false)
    }
  }

  // Steady-state probe. Slower while the panel is closed, and only needed
  // at all to notice a *better* endpoint returning or to keep latency
  // fresh — ordinary failures already arrive via reportFailure().
  Timer {
    interval: root.panelOpen ? 15000 : 60000
    repeat: true
    running: root.endpoints.length > 0 && !root.offline
    onTriggered: {
      root._probeActive()
      root._probePromotionTargets()
    }
  }

  // Offline retry, on the spec's escalating ladder rather than hammering
  // a network that isn't there.
  Timer {
    id: retryTimer
    interval: 15000
    repeat: false
    onTriggered: {
      // Only sweep while actually offline, and stop the moment we aren't.
      // An earlier version rescheduled unconditionally, so a single
      // offline moment left this running forever — every few seconds it
      // wiped the failure counters and yanked the active endpoint back to
      // the highest-priority one whether or not that one worked, which is
      // precisely the flapping the hysteresis exists to prevent.
      if (!root.offline) {
        retryTimer.stop()
        return
      }

      root.offlineAttempts = root.offlineAttempts + 1
      // Give every endpoint another chance, then probe the best one. The
      // endpoint object is passed along rather than re-read from the
      // activeId binding, which wouldn't have caught up yet.
      root.failures = ({})
      var best = Selection.candidates(root.endpoints)[0]
      if (best) {
        root.activeId = best.id
        root._probeEndpoint(best)
      }
      root._probePromotionTargets()
      retryTimer.interval = Selection.retryDelay({ offlineAttempts: root.offlineAttempts })
      retryTimer.restart()
    }
  }

  // Opening the panel forces an immediate retry (spec section 33).
  onPanelOpenChanged: if (panelOpen) probeNow()
}
