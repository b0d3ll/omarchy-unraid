// Endpoint selection and retry policy (spec sections 30-33).
//
// Deliberately pure functions with no QML in them: this is the fiddliest
// logic in the plugin, and the scenarios that matter most — walking out of
// the house, coming back — are awkward to stage physically but trivial to
// assert against a function. tests/selection.test.js runs it under node.
//
// No `.pragma library` here (node can't parse it) and an export guard at
// the bottom, so the same file loads in both QML and node. Everything is
// pure, so QML getting its own copy per import costs nothing.

// Spec section 33's ladder, capped at five minutes.
var RETRY_STEPS_MS = [15000, 30000, 60000, 120000, 300000]

// How many consecutive failures before abandoning a working endpoint, and
// how many consecutive successes before returning to a better one. Both
// are 2 on purpose (spec section 31): one bad poll shouldn't move us, and
// one lucky poll shouldn't move us back either — that's what makes a
// flapping link stay put instead of oscillating.
var FAILURES_BEFORE_SWITCH = 2
var SUCCESSES_BEFORE_PROMOTE = 2

// Endpoints in the order they should be tried: enabled only, by ascending
// priority, with a stable tiebreak so the order can't wobble between calls.
function candidates(endpoints) {
  return (endpoints || [])
    .filter(function(e) { return e && e.enabled !== false && e.graphqlUrl })
    .slice()
    .sort(function(a, b) {
      var pa = typeof a.priority === "number" ? a.priority : 999
      var pb = typeof b.priority === "number" ? b.priority : 999
      if (pa !== pb) return pa - pb
      return String(a.id || "").localeCompare(String(b.id || ""))
    })
}

function findById(endpoints, id) {
  var list = endpoints || []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) return list[i]
  return null
}

function priorityOf(endpoints, id) {
  var e = findById(endpoints, id)
  if (!e) return 999
  return typeof e.priority === "number" ? e.priority : 999
}

// Is `id` still a legitimate choice — present and enabled?
function isSelectable(endpoints, id) {
  var list = candidates(endpoints)
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return true
  return false
}

// The single decision function. Takes the whole world as data and returns
// what to do, so every branch is reachable from a test.
//
//   state: {
//     endpoints, activeId,
//     failures: { <id>: n },   // consecutive failures per endpoint
//     promotions: { <id>: n }, // consecutive probe successes for a better endpoint
//     offlineAttempts: n       // consecutive full sweeps that found nothing
//   }
//
// Returns { action, endpointId, retryDelayMs, reason }
//   action: "keep" | "switch" | "offline" | "probe"
function decide(state) {
  var endpoints = (state && state.endpoints) || []
  var failures = (state && state.failures) || {}
  var promotions = (state && state.promotions) || {}
  var activeId = state ? state.activeId : null
  var list = candidates(endpoints)

  if (list.length === 0) {
    return { action: "offline", endpointId: null, retryDelayMs: retryDelay(state), reason: "no-endpoints" }
  }

  // Nothing chosen yet, or the choice was removed/disabled underneath us.
  if (!activeId || !isSelectable(endpoints, activeId)) {
    return { action: "switch", endpointId: list[0].id, retryDelayMs: 0, reason: "no-active" }
  }

  var activeFailures = failures[activeId] || 0

  // The current endpoint is still answering. The only reason to move is a
  // *better* one having proved itself repeatedly (spec section 31's
  // "switch back only after two consecutive probes").
  if (activeFailures < FAILURES_BEFORE_SWITCH) {
    var better = bestPromotable(endpoints, activeId, promotions)
    if (better) {
      return { action: "switch", endpointId: better, retryDelayMs: 0, reason: "promote" }
    }
    return { action: "keep", endpointId: activeId, retryDelayMs: 0, reason: "healthy" }
  }

  // The current endpoint has failed enough times. Walk the list in
  // priority order and take the first one that isn't also failing.
  for (var i = 0; i < list.length; i++) {
    var candidate = list[i]
    if (candidate.id === activeId) continue
    if ((failures[candidate.id] || 0) < FAILURES_BEFORE_SWITCH) {
      return { action: "switch", endpointId: candidate.id, retryDelayMs: 0, reason: "failover" }
    }
  }

  // Everything known is failing.
  return { action: "offline", endpointId: activeId, retryDelayMs: retryDelay(state), reason: "all-failing" }
}

// A higher-priority endpoint that has passed enough consecutive probes to
// be trusted again. Returns null while on the best endpoint already, which
// is the common case.
function bestPromotable(endpoints, activeId, promotions) {
  var activePriority = priorityOf(endpoints, activeId)
  var list = candidates(endpoints)
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    if (e.id === activeId) continue
    var p = typeof e.priority === "number" ? e.priority : 999
    if (p >= activePriority) continue // not actually better
    if ((promotions[e.id] || 0) >= SUCCESSES_BEFORE_PROMOTE) return e.id
  }
  return null
}

// While running on something other than the preferred endpoint, the better
// ones need probing periodically or they'd never earn a promotion.
function shouldProbeForPromotion(endpoints, activeId) {
  if (!activeId) return false
  return priorityOf(endpoints, activeId) > priorityOf(endpoints, candidates(endpoints)[0] ? candidates(endpoints)[0].id : activeId)
}

// Which endpoints are worth probing in the background right now: the ones
// ranked above the active choice.
function promotionTargets(endpoints, activeId) {
  var activePriority = priorityOf(endpoints, activeId)
  return candidates(endpoints).filter(function(e) {
    var p = typeof e.priority === "number" ? e.priority : 999
    return e.id !== activeId && p < activePriority
  })
}

// Spec section 33: 15s, 30s, 60s, 120s, 300s, then hold at 300s.
function retryDelay(state) {
  var attempts = (state && state.offlineAttempts) || 0
  var index = Math.max(0, Math.min(attempts, RETRY_STEPS_MS.length - 1))
  return RETRY_STEPS_MS[index]
}

// Bookkeeping helpers, kept here so the counters can't drift apart from
// the rules that read them.
function recordFailure(failures, id) {
  var next = shallowCopy(failures)
  if (id) next[id] = (next[id] || 0) + 1
  return next
}

function recordSuccess(failures, id) {
  var next = shallowCopy(failures)
  if (id) next[id] = 0
  return next
}

function recordProbe(promotions, id, ok) {
  var next = shallowCopy(promotions)
  if (!id) return next
  next[id] = ok ? (next[id] || 0) + 1 : 0
  return next
}

function shallowCopy(obj) {
  var out = {}
  for (var k in obj) out[k] = obj[k]
  return out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    RETRY_STEPS_MS: RETRY_STEPS_MS,
    FAILURES_BEFORE_SWITCH: FAILURES_BEFORE_SWITCH,
    SUCCESSES_BEFORE_PROMOTE: SUCCESSES_BEFORE_PROMOTE,
    candidates: candidates,
    findById: findById,
    priorityOf: priorityOf,
    isSelectable: isSelectable,
    decide: decide,
    bestPromotable: bestPromotable,
    shouldProbeForPromotion: shouldProbeForPromotion,
    promotionTargets: promotionTargets,
    retryDelay: retryDelay,
    recordFailure: recordFailure,
    recordSuccess: recordSuccess,
    recordProbe: recordProbe
  }
}
