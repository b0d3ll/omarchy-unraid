#!/usr/bin/env node
// Unit tests for Selection.js — the endpoint selection and retry policy.
//
// These cover the spec's own acceptance tests A-D (sections 55), which are
// the whole point of Milestone 3 and are awkward to stage physically:
// "leave home" and "come home again" would otherwise mean actually walking
// out of the house with the laptop and hoping the timing lines up.
//
// Run from the repo root:  node tests/selection.test.js

const S = require("../Selection.js")

let passed = 0
let failed = 0

function check(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    passed++
    console.log(`  ok   ${name}`)
  } else {
    failed++
    console.log(`  FAIL ${name}\n         expected ${e}\n         actual   ${a}`)
  }
}

// The setup this is all designed around: LAN preferred, Tailscale as the
// fallback for when you're not at home.
function endpoints() {
  return [
    { id: "lan", type: "LAN", graphqlUrl: "http://10.0.0.10/graphql", priority: 0, enabled: true },
    { id: "ts", type: "TAILSCALE", graphqlUrl: "http://100.64.0.1/graphql", priority: 1, enabled: true }
  ]
}

console.log("\nordering and eligibility")
check("candidates are priority-ordered",
  S.candidates(endpoints()).map(e => e.id), ["lan", "ts"])
check("a disabled endpoint is never a candidate",
  S.candidates([
    { id: "lan", graphqlUrl: "u", priority: 0, enabled: false },
    { id: "ts", graphqlUrl: "u", priority: 1, enabled: true }
  ]).map(e => e.id), ["ts"])
check("an endpoint without a url is not a candidate",
  S.candidates([{ id: "broken", priority: 0, enabled: true }]).map(e => e.id), [])
check("with nothing configured the verdict is offline",
  S.decide({ endpoints: [], activeId: null }).action, "offline")
check("first run picks the highest-priority endpoint",
  S.decide({ endpoints: endpoints(), activeId: null }).endpointId, "lan")
check("an active endpoint that got disabled is abandoned",
  S.decide({
    endpoints: [
      { id: "lan", graphqlUrl: "u", priority: 0, enabled: false },
      { id: "ts", graphqlUrl: "u", priority: 1, enabled: true }
    ],
    activeId: "lan"
  }).endpointId, "ts")

console.log("\ntest A — healthy LAN stays put (spec section 55 A)")
check("no failures means keep",
  S.decide({ endpoints: endpoints(), activeId: "lan", failures: {} }).action, "keep")
check("one failure is not enough to move",
  S.decide({ endpoints: endpoints(), activeId: "lan", failures: { lan: 1 } }).action, "keep")

console.log("\ntest B — leave the house (spec section 55 B)")
const leaving = S.decide({ endpoints: endpoints(), activeId: "lan", failures: { lan: 2 } })
check("two consecutive failures triggers failover", leaving.action, "switch")
check("failover lands on Tailscale", leaving.endpointId, "ts")
check("...and says why", leaving.reason, "failover")

console.log("\ntest C — nothing reachable at all (spec section 55 C)")
const bothDown = { endpoints: endpoints(), activeId: "lan", failures: { lan: 2, ts: 2 } }
check("every endpoint failing means offline", S.decide(bothDown).action, "offline")
check("backoff step 1", S.retryDelay({ offlineAttempts: 0 }), 15000)
check("backoff step 2", S.retryDelay({ offlineAttempts: 1 }), 30000)
check("backoff step 3", S.retryDelay({ offlineAttempts: 2 }), 60000)
check("backoff step 4", S.retryDelay({ offlineAttempts: 3 }), 120000)
check("backoff step 5", S.retryDelay({ offlineAttempts: 4 }), 300000)
check("backoff holds at five minutes and never grows further",
  S.retryDelay({ offlineAttempts: 99 }), 300000)
check("the offline verdict carries the delay to wait",
  S.decide(Object.assign({ offlineAttempts: 2 }, bothDown)).retryDelayMs, 60000)

console.log("\ntest D — come home again (spec section 55 D)")
const onTailscale = { endpoints: endpoints(), activeId: "ts", failures: {} }
check("a working Tailscale link is not abandoned just because LAN exists",
  S.decide(onTailscale).action, "keep")
check("one successful LAN probe does NOT move us back (anti-flap)",
  S.decide(Object.assign({ promotions: { lan: 1 } }, onTailscale)).action, "keep")
const promoted = S.decide(Object.assign({ promotions: { lan: 2 } }, onTailscale))
check("two consecutive LAN probes do move us back", promoted.action, "switch")
check("...back to LAN", promoted.endpointId, "lan")
check("...and says why", promoted.reason, "promote")
check("a flapping probe that fails resets the promotion counter",
  S.recordProbe({ lan: 1 }, "lan", false).lan, 0)
check("consecutive probe successes accumulate",
  S.recordProbe({ lan: 1 }, "lan", true).lan, 2)

console.log("\npromotion never runs downhill")
check("while on LAN there is nothing better to probe for",
  S.promotionTargets(endpoints(), "lan").map(e => e.id), [])
check("while on Tailscale, LAN is the promotion target",
  S.promotionTargets(endpoints(), "ts").map(e => e.id), ["lan"])
check("a lower-priority endpoint is never promoted over the active one",
  S.bestPromotable(endpoints(), "lan", { ts: 99 }), null)

console.log("\nfailure bookkeeping")
check("failures accumulate per endpoint",
  S.recordFailure({ lan: 1 }, "lan").lan, 2)
check("a success clears that endpoint's failures",
  S.recordSuccess({ lan: 5 }, "lan").lan, 0)
check("a success for one endpoint leaves the other's count alone",
  S.recordSuccess({ lan: 5, ts: 3 }, "lan").ts, 3)
check("bookkeeping does not mutate the input",
  (() => { const before = { lan: 1 }; S.recordFailure(before, "lan"); return before.lan })(), 1)

console.log(`\n${passed} passed, ${failed} failed\n`)
process.exit(failed === 0 ? 0 : 1)
