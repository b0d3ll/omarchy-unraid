.pragma library

// Pure presentation helpers. The mock server state that lived here through
// Milestones 1–2 is gone — UnraidService now polls the real API and
// normalizes it in Api.js. What's left is sorting and formatting that has
// no reason to touch QML, kept here so it stays trivially testable.

// Docker sort order per spec section 15: problems, exited, paused, running,
// then alphabetical within a state.
function dockerStateRank(state) {
  switch (state) {
    case "RESTARTING": return 0
    case "DEAD": return 0
    case "EXITED": return 1
    case "PAUSED": return 2
    case "RUNNING": return 3
    default: return 4
  }
}

function sortContainers(containers) {
  return (containers || []).slice().sort(function(a, b) {
    var ra = dockerStateRank(a.state)
    var rb = dockerStateRank(b.state)
    if (ra !== rb) return ra - rb
    return a.name.localeCompare(b.name)
  })
}

// Coarse "N minutes/hours/days ago" label for notification and connection
// timestamps (spec sections 8, 27, 34). Accepts an epoch in milliseconds.
function relativeTime(timestampMs) {
  if (!timestampMs) return "never"
  var diffMs = Date.now() - timestampMs
  var minutes = Math.floor(diffMs / 60000)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}
