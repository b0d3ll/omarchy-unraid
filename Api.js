.pragma library

// GraphQL operations and response normalization.
//
// Every query here was verified against a real Unraid 7.3.2 server (API
// 4.37.3) rather than taken from the spec — several spec queries don't
// match that version (see normalizeSystem for the versions path). Keeping
// the operations as plain strings in one pure-JS file also means
// tests/no-disk-queries.sh can statically prove the disk-sleep invariant.
//
// DISK-SLEEP INVARIANT (spec section 51): no query in this file may ever
// contain `disks`, `array { disks }` or `metrics { temperature }`. Those
// can wake sleeping HDDs, and nothing here runs on a user gesture — it all
// runs on a background timer. Disk details stay explicitly user-initiated.
//
// Resource roots are kept in separate operations on purpose (spec section
// 36): a Docker or VM subsystem being unavailable must not take array or
// metrics data down with it. `array` + `vars` share one operation because
// both are always-available storage state (the spec's own section 25
// example pairs them), and likewise `info` + `vars{name,version}` are one
// identity operation.

// Connectivity probe (spec section 32) — the smallest query that proves
// both reachability and a working API key.
var QUERY_HEALTH = "{ online vars { name version } }"

var QUERY_SYSTEM = "{ info { versions { core { unraid api } } os { uptime } } vars { name version } }"

var QUERY_METRICS = "{ metrics { cpu { percentTotal } memory { total used available percentTotal } } }"

var QUERY_ARRAY = "{ array { state capacity { kilobytes { used free total } } "
  + "parityCheckStatus { status progress errors speed correcting paused running } } "
  + "vars { mdNumDisks mdNumDisabled mdNumInvalid mdNumMissing cacheNumDevices } }"

// iconUrl/shell are deliberately not requested: nothing renders container
// icons yet and `shell` is only needed once M5 adds a console, and they
// roughly double the payload across 30 containers.
var QUERY_DOCKER = "{ docker { containers { id names state status autoStart isUpdateAvailable webUiUrl } } }"

var QUERY_VMS = "{ vms { domains { id name state } } }"

var QUERY_NOTIFICATIONS = "{ notifications { overview { unread { info warning alert total } } "
  + "warningsAndAlerts { id title subject description importance link timestamp formattedTimestamp } } }"

// ------------------------------------------------------- docker operations
//
// Container ids are composite ("<serverId>:<containerId>"), so they're
// embedded with JSON.stringify rather than string-concatenated — that
// escapes anything in the id instead of letting it break the document.
//
// The mutations return a full DockerContainer (id/state/status/names are
// all valid on it, verified against a real server). The reply is still
// only used for its error status: spec section 45 wants the new state
// confirmed by re-reading the resource, not taken from the mutation.

function mutationDockerStart(id) {
  return "mutation { docker { start(id: " + JSON.stringify(id) + ") { id state status } } }"
}

function mutationDockerStop(id) {
  return "mutation { docker { stop(id: " + JSON.stringify(id) + ") { id state status } } }"
}

function mutationDockerRestart(id) {
  return "mutation { docker { restart(id: " + JSON.stringify(id) + ") { id state status } } }"
}

// ------------------------------------------------------ endpoint discovery
//
// What the server itself advertises (spec section 29 step 3). On a real
// 7.3.2 box this returns only LAN-shaped entries — DEFAULT/LAN/MDNS —
// and no WIREGUARD, so this alone can't find a remote path; the local
// Tailscale client fills that gap (see tailscaleCandidates below).
var QUERY_ACCESS_URLS = "{ network { accessUrls { type name ipv4 ipv6 } } }"

function normalizeAccessUrls(data) {
  var urls = (data && data.network && data.network.accessUrls) || []
  return urls.map(function(u) {
    return {
      type: u.type || "",
      name: u.name || "",
      ipv4: u.ipv4 || "",
      ipv6: u.ipv6 || ""
    }
  })
}

function normalizeBaseUrl(url) {
  var trimmed = String(url || "").trim().replace(/\/+$/, "")
  if (trimmed === "") return ""
  if (!/^https?:\/\//i.test(trimmed)) trimmed = "http://" + trimmed
  return trimmed
}

function graphqlUrlFor(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  if (base === "") return ""
  return /\/graphql$/i.test(base) ? base : base + "/graphql"
}

function makeEndpoint(id, type, name, baseUrl, priority) {
  var base = normalizeBaseUrl(baseUrl)
  return {
    id: id,
    type: type,
    name: name,
    baseUrl: base,
    graphqlUrl: graphqlUrlFor(base),
    priority: priority,
    enabled: true
  }
}

// Server-advertised candidates worth offering. The IP entry is usually
// already configured, so the valuable one is the mDNS name: it keeps
// working when DHCP hands the server a different address. WAN entries are
// deliberately ignored — spec section 41 says never reach for a public
// URL automatically.
function accessUrlCandidates(urls, existingGraphqlUrls) {
  var seen = {}
  for (var i = 0; i < (existingGraphqlUrls || []).length; i++) seen[existingGraphqlUrls[i]] = true
  var out = []
  for (var j = 0; j < (urls || []).length; j++) {
    var u = urls[j]
    var type = String(u.type || "").toUpperCase()
    if (type !== "LAN" && type !== "MDNS" && type !== "DEFAULT") continue
    if (!u.ipv4) continue
    var candidate = makeEndpoint("lan-" + type.toLowerCase() + "-" + j, "LAN",
      u.name || type, u.ipv4, 10 + j)
    if (candidate.graphqlUrl === "" || seen[candidate.graphqlUrl]) continue
    seen[candidate.graphqlUrl] = true
    out.push(candidate)
  }
  return out
}

// Match a Tailscale peer to this server by its short DNS name against the
// configured hostname — `tower.tail….ts.net` vs `Tower`. Mirrors what
// Omarchy's own tailscale plugin does in
// plugins/panels/tailscale/Model.js (shortDnsName / filterIPv4 on 100.*).
//
// Conservative on purpose (spec section 42): a peer that merely looks
// VPN-ish is not assumed to be the server, and what comes back here is a
// *proposal* for the user to confirm, never something adopted silently.
function tailscaleCandidates(statusJson, hostname, existingGraphqlUrls) {
  var seen = {}
  for (var i = 0; i < (existingGraphqlUrls || []).length; i++) seen[existingGraphqlUrls[i]] = true

  var status = null
  try { status = JSON.parse(statusJson || "") } catch (e) { return [] }
  if (!status) return []

  var want = String(hostname || "").trim().toLowerCase()
  if (want === "") return []

  var peers = status.Peer || {}
  var out = []
  for (var key in peers) {
    var peer = peers[key]
    if (!peer) continue
    var short = shortDnsName(peer.DNSName)
    if (short.toLowerCase() !== want) continue
    var ips = peer.TailscaleIPs || []
    for (var j = 0; j < ips.length; j++) {
      // IPv4 in the tailnet range only; a bare IPv6 literal would need
      // bracketing and buys nothing here.
      if (!/^100\./.test(String(ips[j]))) continue
      var candidate = makeEndpoint("tailscale-" + short, "TAILSCALE",
        "Tailscale (" + short + ")", "http://" + ips[j], 20)
      if (seen[candidate.graphqlUrl]) continue
      seen[candidate.graphqlUrl] = true
      out.push(candidate)
      break
    }
  }
  return out
}

function shortDnsName(name) {
  var clean = String(name || "")
  if (clean.charAt(clean.length - 1) === ".") clean = clean.slice(0, -1)
  if (clean === "") return ""
  return clean.split(".")[0] || clean
}

// ----------------------------------------------------------- vm operations
//
// These sit under `vm` (singular) even though the query root is `vms`, and
// they return a scalar rather than an object — both verified against a
// real server. start/stop/reboot/pause/resume/forceStop all exist.

function mutationVm(kind, id) {
  return "mutation { vm { " + kind + "(id: " + JSON.stringify(id) + ") } }"
}

function mutationVmStart(id) { return mutationVm("start", id) }
function mutationVmStop(id) { return mutationVm("stop", id) }
function mutationVmReboot(id) { return mutationVm("reboot", id) }
function mutationVmPause(id) { return mutationVm("pause", id) }
function mutationVmResume(id) { return mutationVm("resume", id) }
function mutationVmForceStop(id) { return mutationVm("forceStop", id) }

// Logs are readable with a plain read-only key, unlike the mutations above.
function queryDockerLogs(id, tail) {
  var lines = num(tail, 100)
  return "{ docker { logs(id: " + JSON.stringify(id) + ", tail: " + lines + ") "
    + "{ cursor lines { timestamp message } } } }"
}

function normalizeLogs(data) {
  var logs = (data && data.docker && data.docker.logs) || null
  if (!logs) return { available: false, lines: [] }
  return {
    available: true,
    cursor: logs.cursor || "",
    lines: (logs.lines || []).map(function(line) {
      return {
        timestamp: line.timestamp ? Date.parse(line.timestamp) : null,
        message: line.message || ""
      }
    })
  }
}

// "13:23:04" for a log line's gutter.
function clockTime(timestampMs) {
  if (!timestampMs) return "--:--:--"
  var d = new Date(timestampMs)
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
}

// ---------------------------------------------------------------- helpers

function num(value, fallback) {
  // null/undefined must fall through to the caller's fallback rather than
  // become 0 — Number(null) is 0, which would render a server that reports
  // no cache pool as "0 cache devices" instead of "unknown".
  if (value === null || value === undefined) return fallback === undefined ? null : fallback
  var n = Number(value)
  return isFinite(n) ? n : (fallback === undefined ? null : fallback)
}

// Capacity arrives as strings of 1K blocks ("13196212077"), so convert via
// bytes to keep the arithmetic honest.
function kbToTb(kilobytes) {
  var kb = num(kilobytes)
  if (kb === null) return null
  return (kb * 1024) / 1e12
}

// `names` is an array whose entries carry Docker's leading slash
// (["/jackett"]). Fall back to a short id so a row is never blank.
function containerName(container) {
  var names = container && container.names
  if (names && names.length > 0 && names[0]) return String(names[0]).replace(/^\/+/, "")
  var id = container && container.id ? String(container.id) : ""
  var short = id.indexOf(":") >= 0 ? id.split(":").pop() : id
  return short.substring(0, 12) || "unknown"
}

// ------------------------------------------------------------ normalizers
//
// Each takes the `data` object of a GraphQL reply and returns the shape the
// views bind to. All of them tolerate missing/null branches, because a
// partial reply (data alongside errors) is normal on real servers.

function normalizeSystem(data) {
  var info = (data && data.info) || {}
  var core = (info.versions && info.versions.core) || {}
  var vars = (data && data.vars) || {}
  return {
    hostname: vars.name || "",
    // Prefer info.versions.core.unraid, fall back to vars.version — both
    // report 7.3.2 on a real server; the spec's info.versions.unraid does
    // not exist there at all.
    unraidVersion: core.unraid || vars.version || "",
    apiVersion: core.api || "",
    // os.uptime is the boot timestamp, not a duration.
    bootTime: (info.os && info.os.uptime) || ""
  }
}

function normalizeMetrics(data) {
  var m = (data && data.metrics) || {}
  var cpu = m.cpu || {}
  var mem = m.memory || {}
  var total = num(mem.total, 0)
  var available = num(mem.available, 0)
  // memory.percentTotal is (total - available) / total on a real server —
  // NOT used/total, since `used` counts cache and disagrees with the
  // percentage. Derive the label from the same figures as the bar so the
  // number and the percentage can't contradict each other.
  var usedBytes = total > 0 ? Math.max(0, total - available) : num(mem.used, 0)
  return {
    cpuPercent: Math.round(num(cpu.percentTotal, 0)),
    ramPercent: Math.round(num(mem.percentTotal, 0)),
    ramUsedGb: total > 0 ? usedBytes / 1e9 : null,
    ramTotalGb: total > 0 ? total / 1e9 : null
  }
}

function normalizeArray(data) {
  var a = (data && data.array) || {}
  var vars = (data && data.vars) || {}
  var kb = (a.capacity && a.capacity.kilobytes) || {}
  var parity = a.parityCheckStatus || {}
  return {
    state: a.state || "",
    capacity: {
      usedTb: kbToTb(kb.used),
      freeTb: kbToTb(kb.free),
      totalTb: kbToTb(kb.total),
      usedPercent: (num(kb.total, 0) > 0) ? (100 * num(kb.used, 0) / num(kb.total, 1)) : null
    },
    disks: num(vars.mdNumDisks, null),
    disabled: num(vars.mdNumDisabled, null),
    invalid: num(vars.mdNumInvalid, null),
    missing: num(vars.mdNumMissing, null),
    // Returns NaN on servers without a cache pool, which surfaces as a
    // partial GraphQL error plus a null field — render it as unknown.
    cacheDevices: num(vars.cacheNumDevices, null),
    parityCheckStatus: {
      status: parity.status || "",
      // running/paused/correcting/errors come back null (not false/0) when
      // no check is in progress.
      running: parity.running === true,
      paused: parity.paused === true,
      correcting: parity.correcting === true,
      progress: num(parity.progress, 0),
      speed: parity.speed || "",
      errors: num(parity.errors, 0)
    }
  }
}

function normalizeDocker(data) {
  var containers = (data && data.docker && data.docker.containers) || []
  return {
    available: !!(data && data.docker && data.docker.containers),
    containers: containers.map(function(c) {
      return {
        id: c.id,
        name: containerName(c),
        state: c.state || "UNKNOWN",
        status: c.status || "",
        autoStart: c.autoStart === true,
        updateAvailable: c.isUpdateAvailable === true,
        webUiUrl: c.webUiUrl || ""
      }
    })
  }
}

function normalizeVms(data) {
  var domains = (data && data.vms && data.vms.domains) || []
  return {
    available: !!(data && data.vms && data.vms.domains),
    domains: domains.map(function(d) {
      return { id: d.id, name: d.name || "unnamed", state: d.state || "UNKNOWN" }
    })
  }
}

function normalizeNotifications(data) {
  var n = (data && data.notifications) || {}
  var unread = (n.overview && n.overview.unread) || {}
  var items = n.warningsAndAlerts || []
  return {
    unread: {
      info: num(unread.info, 0),
      warning: num(unread.warning, 0),
      alert: num(unread.alert, 0),
      total: num(unread.total, 0)
    },
    items: items.map(function(item) {
      return {
        id: item.id,
        title: item.title || "",
        subject: item.subject || "",
        description: item.description || "",
        importance: item.importance || "INFO",
        // `link` is relative on a real server ("/Main") — callers prefix
        // it with the configured base URL.
        link: item.link || "",
        timestamp: item.timestamp ? Date.parse(item.timestamp) : null,
        formattedTimestamp: item.formattedTimestamp || ""
      }
    })
  }
}

// Absolute URL for a notification's relative `link`.
function notificationUrl(baseUrl, link) {
  if (!link) return ""
  if (/^https?:\/\//i.test(link)) return link
  var base = String(baseUrl || "").replace(/\/+$/, "")
  return base + (link.charAt(0) === "/" ? link : "/" + link)
}

// Bare host for an ssh target, from a configured base URL.
function hostFromUrl(url) {
  return String(url || "")
    .replace(/^https?:\/\//i, "")
    .replace(/[:\/?#].*$/, "")
}

// "3 days" / "16 hours" from the boot timestamp os.uptime reports.
function uptimeSince(bootTimestamp) {
  if (!bootTimestamp) return ""
  var boot = Date.parse(bootTimestamp)
  if (!isFinite(boot)) return ""
  var minutes = Math.floor((Date.now() - boot) / 60000)
  if (minutes < 60) return minutes + " min"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour" : " hours")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day" : " days")
}
