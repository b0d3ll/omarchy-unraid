.pragma library

// GraphQL operations and response normalization.
//
// Every query here was verified against a real Unraid 7.3.2 server (API
// 4.37.3) rather than taken from the spec — several spec queries don't
// match that version (see normalizeSystem for the versions path). Keeping
// the operations as plain strings in one pure-JS file also means
// tests/no-disk-queries.sh can evaluate it and check the disk-sleep
// invariant against the operations that actually get sent.
//
// DISK-SLEEP INVARIANT (spec section 51): no query in this file may ever
// reach the top-level `disks`/`disk` root, or ask for `smartStatus` /
// `temperature` on the `Disk` type. Those go through the API's DisksService,
// which shells out to `smartctl` and systeminformation's `diskLayout()` —
// that is what wakes sleeping HDDs. Nothing here runs on a user gesture, so
// nothing here may touch them. `tests/no-disk-queries.sh` enforces it.
//
// `array { parities/disks/caches }` is explicitly NOT part of that ban, and
// the original blanket rule against the word `disks` was wider than the real
// hazard. Verified in the API's own source (unraid/api,
// api/src/core/modules/array/get-array-data.ts and
// api/src/store/state-parsers/slots.ts): every ArrayDisk field — `temp` and
// `isSpinning` included — is read straight out of the emhttp state the API
// already holds in memory, parsed from `/var/local/emhttp/disks.ini`. It
// issues no device I/O at all; it is the same data the Unraid Main page
// renders, and `temp` comes back null for a parked disk rather than spinning
// it up to answer. Confirmed against this server: seven disks stayed in
// standby across repeated polls.
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

// Per-disk state (spec section 26). Safe to poll — see the disk-sleep note
// above. `numReads`/`numWrites` are deliberately left out: the state parser
// hardcodes both to 0, so requesting them would render a confident lie.
// `color` is skipped for the same reason (always null on 7.3.2).
var DISK_FIELDS = "idx name device type status rotational temp isSpinning "
  + "numErrors fsType fsSize fsFree fsUsed size transport warning critical"

// Unraid's own defaults from Settings > Disk Settings, used when a disk
// reports no thresholds of its own — which is what this server does for
// every disk, since they are only written once you change them.
var DEFAULT_DISK_WARN_C = 45
var DEFAULT_DISK_CRIT_C = 55

// The per-disk lists ride along with the array summary rather than being a
// separate, view-gated query. They have to: the bar's health dot is derived
// from disk status now (see arrayDiskCounts), and that dot is on screen
// whether or not anyone has the Storage tab open. Same `array` root, so it
// is one round trip either way.
var QUERY_ARRAY = "{ array { state capacity { kilobytes { used free total } } "
  + "parityCheckStatus { status progress speed date duration } "
  + "parities { " + DISK_FIELDS + " } "
  + "disks { " + DISK_FIELDS + " } "
  + "caches { " + DISK_FIELDS + " } } "
  + "vars { mdNumDisks mdNumDisabled mdNumInvalid mdNumMissing } }"

// Parity history. Its own operation and its own slow poll: it takes no
// arguments, so the server sends every check it has ever logged (~100 rows,
// 8.5 KB here) and there is no way to ask for less. It also changes a few
// times a month at most, so anything faster than minutes is pure waste.
//
// This is the only honest source for "was the last check clean". The
// per-check `errors` here is parsed from the parity log; the one on
// `array.parityCheckStatus` is never assigned a value at all (see
// normalizeParity).
var QUERY_PARITY_HISTORY = "{ parityHistory { date duration status errors } }"

// iconUrl/shell are deliberately not requested: nothing renders container
// icons yet and `shell` is only needed once M5 adds a console, and they
// roughly double the payload across 30 containers.
var QUERY_DOCKER = "{ docker { containers { id names state status autoStart isUpdateAvailable webUiUrl } } }"

var QUERY_VMS = "{ vms { domains { id name state } } }"

// `list(type: UNREAD)` rather than `warningsAndAlerts`, so INFO notices come
// through too. Without them the panel showed "Disk-Clear started" as a
// warning and silently dropped the "Disk-Clear finished (0 errors)" notice
// that resolved it — the alarm stayed on screen with its own all-clear
// filtered out. The filter's type/offset/limit are all non-null, and
// omitting `importance` is what widens it to every level.
var QUERY_NOTIFICATIONS = "{ notifications { overview { unread { info warning alert total } } "
  + "list(filter: { type: UNREAD, offset: 0, limit: 50 }) "
  + "{ id title subject description importance link timestamp formattedTimestamp } } }"

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

// Archiving is a top-level mutation, not under a `notifications` root
// (verified against a real server), and it returns the notification.
function mutationArchiveNotification(id) {
  return "mutation { archiveNotification(id: " + JSON.stringify(id) + ") { id } }"
}

var NOTIFICATION_IMPORTANCE = { INFO: true, WARNING: true, ALERT: true }

// `importance` is nullable, and omitting it archives every unread notice —
// which is exactly what the Notices list's "All" filter means.
//
// GraphQL enum values cannot be quoted, so this is the one argument in this
// file that is concatenated into a document without JSON.stringify around
// it. Hence the whitelist: an unrecognised value drops the argument rather
// than being pasted into the operation.
function mutationArchiveAll(importance) {
  var key = String(importance || "")
  var arg = NOTIFICATION_IMPORTANCE[key] ? "(importance: " + key + ")" : ""
  return "mutation { archiveAll" + arg + " { unread { info warning alert total } } }"
}

// ------------------------------------------------- array/parity operations
//
// parityCheck's four mutations return the `JSON` scalar, so they take no
// selection set — `{ parityCheck { pause } }` is the whole document. Verified
// against the live schema rather than assumed: a selection set on a scalar
// is a validation error, not something the server tolerates.
//
// `start` takes a required Boolean. false is a read-only check that reports
// what it found; true writes corrections back to parity as it goes. Two
// separate callers rather than a shared one with a flag, because "check" and
// "check and rewrite parity" are not the same decision.

function mutationParityStart(correcting) {
  return "mutation { parityCheck { start(correct: " + (correcting === true) + ") } }"
}

function mutationParityPause() { return "mutation { parityCheck { pause } }" }
function mutationParityResume() { return "mutation { parityCheck { resume } }" }
function mutationParityCancel() { return "mutation { parityCheck { cancel } }" }

var ARRAY_DESIRED_STATE = { START: true, STOP: true }

// `desiredState` is an enum and so cannot be quoted — same whitelist as
// mutationArchiveAll, for the same reason. An unrecognised value yields an
// empty document that the caller refuses to send rather than something
// half-built.
//
// The reply is read only for its error status; the array's real state comes
// from the next poll (spec section 45). Encryption is out of scope for v0.2:
// ArrayStateInput also takes decryptionPassword/decryptionKeyfile, and a
// server with an encrypted array will refuse START without them and say so.
function mutationArraySetState(desiredState) {
  var key = String(desiredState || "")
  if (!ARRAY_DESIRED_STATE[key]) return ""
  return "mutation { array { setState(input: { desiredState: " + key + " }) { state } } }"
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
// The API also exposes `reset`, which libvirt defines as an immediate hard
// reset — the reset button on the case, not a reboot. No shutdown sequence
// runs, so it belongs with forceStop rather than with reboot.
function mutationVmReset(id) { return mutationVm("reset", id) }

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

// The API hands out two different kilobytes on the same objects, so they get
// two converters rather than one that is quietly wrong for half its callers.
//
// `fsSize`/`fsFree`/`fsUsed` — and therefore `array.capacity.kilobytes`,
// which is just their sum — are converted from KiB to decimal KB by the
// API's own state parser before they leave the server
// (toNumberOrNullConvert(..., { startingUnit: 'KiB', endUnit: 'KB' })), so
// they are already powers of ten. Treating them as KiB here overstated the
// array by 2.4% — this box reported 14.7 TB for ten disks that add up to
// 14.4 TB.
function kbToTb(kilobytes) {
  var kb = num(kilobytes)
  if (kb === null) return null
  return kb / 1e9
}

// `size` is the raw slot size and does NOT go through that conversion: it
// stays in 1K (KiB) blocks, exactly as emhttp wrote it.
function kibToTb(kibiblocks) {
  var kib = num(kibiblocks)
  if (kib === null) return null
  return (kib * 1024) / 1e12
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

// The Disabled / Missing / Invalid / Cache counters.
//
// Derived from per-disk status whenever the disk lists are present, because
// `vars` and the disk list can flatly disagree: this server reports
// mdNumDisabled 1 and mdNumInvalid 1 while every single disk reports
// DISK_OK, with the array started and a clean parity check behind it. The
// API passes those numbers through from var.ini untouched
// (state-parsers/var.ts is a plain toNumber of each field), so the
// disagreement is emhttp's own bookkeeping, not a transport bug. Per-disk
// status is what the Unraid Main page draws, so it wins — and it also
// answers `cacheDevices`, which `vars` returns as NaN on a server with
// pools (surfacing as a partial GraphQL error plus a null field).
//
// `vars` stays the fallback for a server that answers the summary but not
// the disk lists, so nothing regresses if the lists ever go missing.
function arrayDiskCounts(drives, vars) {
  if (!drives.available) {
    return {
      disks: num(vars.mdNumDisks, null),
      disabled: num(vars.mdNumDisabled, null),
      invalid: num(vars.mdNumInvalid, null),
      missing: num(vars.mdNumMissing, null),
      // `vars` has no usable pool count. cacheNumDevices is the legacy
      // single-cache figure and answers NaN on any server with named pools
      // — a partial GraphQL error on every single array poll, for a number
      // that then rendered as "—" anyway. Dropped from the query; without
      // the pool list there is simply no answer, and null says so.
      cacheDevices: null,
      derived: false
    }
  }

  function countStatus(statuses) {
    return drives.all.filter(function(d) { return statuses.indexOf(d.status) >= 0 }).length
  }

  return {
    // Parity plus data slots, which is what mdNumDisks counts.
    disks: drives.parities.length + drives.disks.length,
    disabled: countStatus(["DISK_DSBL", "DISK_NP_DSBL", "DISK_DSBL_NEW"]),
    // DISK_WRONG — the wrong drive sitting in a slot — has no counter of its
    // own in `vars`. It belongs here rather than being silently dropped.
    invalid: countStatus(["DISK_INVALID", "DISK_WRONG"]),
    missing: countStatus(["DISK_NP_MISSING"]),
    cacheDevices: drives.caches.length,
    derived: true
  }
}

function normalizeArray(data) {
  var a = (data && data.array) || {}
  var vars = (data && data.vars) || {}
  var kb = (a.capacity && a.capacity.kilobytes) || {}
  var parity = a.parityCheckStatus || {}
  var drives = arrayDrives(data)
  var counts = arrayDiskCounts(drives, vars)
  return {
    state: a.state || "",
    // The per-disk lists, under their own key: `disks` at this level is
    // already the slot *count*, and two different `disks` on one object is
    // the kind of thing that gets read wrong exactly once.
    drives: drives,
    capacity: {
      usedTb: kbToTb(kb.used),
      freeTb: kbToTb(kb.free),
      totalTb: kbToTb(kb.total),
      usedPercent: (num(kb.total, 0) > 0) ? (100 * num(kb.used, 0) / num(kb.total, 1)) : null
    },
    disks: counts.disks,
    disabled: counts.disabled,
    invalid: counts.invalid,
    missing: counts.missing,
    cacheDevices: counts.cacheDevices,
    // Whether those five came from the disk list or from `vars`.
    countsDerived: counts.derived,
    parityCheckStatus: normalizeParity(parity),
    stateLabel: arrayStateLabel(a.state)
  }
}

// `running`, `paused`, `correcting` and `errors` exist on the ParityCheck
// type but the API never assigns them: getParityCheckStatus (unraid/api,
// api/src/core/modules/array/parity-check-status.ts) returns only status,
// speed, date, duration and progress, so the other four are always null.
//
// Reading them as booleans therefore meant `running` was permanently false,
// and the parity progress bar on Overview was dead code that could not fire
// during a real check. `errors` was worse than dead: `num(parity.errors, 0)`
// turned a null into a confident 0, so "Errors: 0" was printed whether or
// not the last check had found any. Real error counts live in
// parityHistory, which parses the log.
//
// Status is populated, and it carries RUNNING and PAUSED, so derive from it.
function normalizeParity(parity) {
  var status = parity.status || ""
  return {
    status: status,
    running: status === "RUNNING",
    paused: status === "PAUSED",
    progress: num(parity.progress, 0),
    speed: parity.speed || "",
    // The *start* of the last check — `duration` runs from here to the end.
    startedAt: parity.date ? Date.parse(parity.date) : null,
    durationSeconds: num(parity.duration, null)
  }
}

// Newest first, defensively: the server already returns them that way, but
// "the last check" is too load-bearing to leave to the server's ordering.
function normalizeParityHistory(data) {
  var rows = (data && data.parityHistory) || []
  var checks = rows.map(function(r) {
    return {
      // Unlike parityCheckStatus.date, this one is when the check FINISHED.
      finishedAt: r.date ? Date.parse(r.date) : null,
      durationSeconds: num(r.duration, null),
      status: r.status || "",
      errors: num(r.errors, null)
    }
  }).filter(function(c) { return c.finishedAt !== null })
  checks.sort(function(a, b) { return b.finishedAt - a.finishedAt })
  return {
    available: !!(data && data.parityHistory),
    last: checks.length > 0 ? checks[0] : null,
    count: checks.length
  }
}

// "1 h 39 min" / "12 min" from a duration in seconds.
function formatDuration(seconds) {
  var total = num(seconds, null)
  if (total === null || total <= 0) return ""
  var hours = Math.floor(total / 3600)
  var minutes = Math.round((total % 3600) / 60)
  if (hours === 0) return minutes + " min"
  if (minutes === 0) return hours + " h"
  return hours + " h " + minutes + " min"
}

// ArrayState comes straight from emhttp's mdState, and "Started"/"Stopped"
// is the Unraid webGUI's own wording for it — its Main page footer reads
// "Array Started". The other nine are error states the view used to render
// raw, so a server with a missing parity disk announced itself as
// "PARITY_NOT_BIGGEST".
var ARRAY_STATE_LABELS = {
  STARTED: "Started",
  STOPPED: "Stopped",
  NEW_ARRAY: "New array",
  RECON_DISK: "Rebuilding disk",
  DISABLE_DISK: "Disk disabled",
  SWAP_DSBL: "Swapping disabled disk",
  INVALID_EXPANSION: "Invalid expansion",
  PARITY_NOT_BIGGEST: "Parity disk too small",
  TOO_MANY_MISSING_DISKS: "Too many missing disks",
  NEW_DISK_TOO_SMALL: "New disk too small",
  NO_DATA_DISKS: "No data disks"
}

function arrayStateLabel(state) {
  var key = String(state || "")
  if (key === "") return "—"
  return ARRAY_STATE_LABELS[key] || key.charAt(0) + key.slice(1).toLowerCase().replace(/_/g, " ")
}

// ArrayDiskStatus spellings, in the order the Main page words them.
// DISK_NP is an empty slot, not a fault.
var DISK_STATUS_LABELS = {
  DISK_OK: "OK",
  DISK_NP: "No device",
  DISK_NP_MISSING: "Missing",
  DISK_INVALID: "Invalid",
  DISK_WRONG: "Wrong disk",
  DISK_DSBL: "Disabled",
  DISK_NP_DSBL: "Disabled, missing",
  DISK_DSBL_NEW: "Disabled, new",
  DISK_NEW: "New"
}

function diskStatusLabel(status) {
  var key = String(status || "")
  return DISK_STATUS_LABELS[key] || key.replace(/^DISK_/, "").replace(/_/g, " ") || "Unknown"
}

// Four states, not a boolean: an SSD reports isSpinning true forever, which
// is true but meaningless, and a drive with no `spundown` in the ini reports
// null. Only rotational media gets a spin verdict at all.
function diskSpinState(disk) {
  if (disk.rotational !== true) return "SOLID"
  if (disk.isSpinning === true) return "SPINNING"
  if (disk.isSpinning === false) return "STANDBY"
  return "UNKNOWN"
}

function normalizeDisk(d) {
  var fsSize = num(d.fsSize, null)
  var fsUsed = num(d.fsUsed, null)
  var errors = num(d.numErrors, 0)
  var status = d.status || ""
  var disk = {
    idx: num(d.idx, 0),
    name: d.name || "",
    device: d.device || "",
    // DATA | PARITY | CACHE | BOOT | FLASH
    kind: d.type || "",
    status: status,
    statusLabel: diskStatusLabel(status),
    healthy: (status === "DISK_OK" || status === "DISK_NP") && errors === 0,
    rotational: d.rotational === true,
    // null while the disk is parked: emhttp writes "*" into disks.ini rather
    // than reading the drive to answer, so this is an absence of data, not a
    // temperature of zero.
    temp: num(d.temp, null),
    isSpinning: (d.isSpinning === true || d.isSpinning === false) ? d.isSpinning : null,
    errors: errors,
    fsType: d.fsType || "",
    transport: d.transport || "",
    warnTempC: num(d.warning, DEFAULT_DISK_WARN_C),
    critTempC: num(d.critical, DEFAULT_DISK_CRIT_C),
    sizeTb: kibToTb(d.size),
    totalTb: kbToTb(fsSize),
    usedTb: fsSize === null ? null : kbToTb(fsUsed),
    freeTb: fsSize === null ? null : kbToTb(d.fsFree),
    usedPercent: (fsSize !== null && fsSize > 0 && fsUsed !== null)
      ? (100 * fsUsed / fsSize) : null
  }
  disk.spinState = diskSpinState(disk)
  return disk
}

function arrayDrives(data) {
  var a = (data && data.array) || {}
  var parities = (a.parities || []).map(normalizeDisk)
  var disks = (a.disks || []).map(normalizeDisk)
  var caches = (a.caches || []).map(normalizeDisk)
  var all = parities.concat(disks, caches)

  function countState(state) {
    return all.filter(function(d) { return d.spinState === state }).length
  }
  var spinning = countState("SPINNING")
  var standby = countState("STANDBY")

  // The warmest disk that is actually reporting a temperature. A parked
  // disk has none — the server never woke it to measure — so it is skipped
  // rather than counted as cold, and an array that is entirely asleep
  // yields null instead of a figure nobody measured.
  var hottest = null
  for (var i = 0; i < all.length; i++) {
    var d = all[i]
    if (d.temp === null) continue
    if (hottest === null || d.temp > hottest.temp) hottest = d
  }

  return {
    // A server with no array at all answers with empty lists rather than
    // null, so "did the query land" has to be asked of the reply itself.
    available: !!(a.parities || a.disks || a.caches),
    parities: parities,
    disks: disks,
    caches: caches,
    all: all,
    spinning: spinning,
    standby: standby,
    // Denominator for "3 of 11 spinning": SSDs are excluded, since they are
    // never anything else.
    spinnable: spinning + standby,
    hottest: hottest,
    problems: all.filter(function(d) { return !d.healthy }).length
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
        state: c.state || "",
        stateLabel: containerStateLabel(c.state),
        status: c.status || "",
        autoStart: c.autoStart === true,
        updateAvailable: c.isUpdateAvailable === true,
        webUiUrl: c.webUiUrl || ""
      }
    })
  }
}

// ContainerState is Docker's vocabulary. Unraid's own Docker page words
// these as started/stopped/paused, and the panel already speaks that way
// for VMs and the array, so a stopped container should not be the one place
// still shouting EXITED. RESTARTING and DEAD aren't in the enum but are
// real Docker states that Model.dockerStateRank already sorts for, so they
// get labels too rather than falling through.
var CONTAINER_STATE_LABELS = {
  RUNNING: "Running",
  PAUSED: "Paused",
  EXITED: "Stopped",
  RESTARTING: "Restarting",
  DEAD: "Dead"
}

function containerStateLabel(state) {
  var key = String(state || "")
  if (key === "") return "Unknown"
  return CONTAINER_STATE_LABELS[key] || key.charAt(0) + key.slice(1).toLowerCase().replace(/_/g, " ")
}

// VmState is libvirt's own domain-state enum, handed through unchanged, so
// an off VM reports SHUTOFF. Unraid's VM manager calls that "Stopped", which
// is the word used here — "Offline" would suggest the VM can't be reached,
// rather than that it simply isn't running.
var VM_STATE_LABELS = {
  NOSTATE: "Unknown",
  RUNNING: "Running",
  IDLE: "Idle",
  PAUSED: "Paused",
  SHUTDOWN: "Shutting down",
  SHUTOFF: "Stopped",
  CRASHED: "Crashed",
  PMSUSPENDED: "Suspended"
}

function vmStateLabel(state) {
  var key = String(state || "")
  if (key === "") return "Unknown"
  return VM_STATE_LABELS[key] || key.charAt(0) + key.slice(1).toLowerCase().replace(/_/g, " ")
}

function normalizeVms(data) {
  var domains = (data && data.vms && data.vms.domains) || []
  return {
    available: !!(data && data.vms && data.vms.domains),
    domains: domains.map(function(d) {
      var state = d.state || "NOSTATE"
      return {
        id: d.id,
        name: d.name || "unnamed",
        state: state,
        stateLabel: vmStateLabel(state)
      }
    })
  }
}

function notificationNeedsAttention(item) {
  return item.importance === "WARNING" || item.importance === "ALERT"
}

function normalizeNotifications(data) {
  var n = (data && data.notifications) || {}
  var unread = (n.overview && n.overview.unread) || {}
  var items = n.list || []
  // Newest first, defensively — the server already answers in that order,
  // but both the Notices list and Overview's RECENT slice off the front of
  // this, so the ordering is load-bearing.
  var normalized = items.map(normalizeNotification).sort(function(a, b) {
    return (b.timestamp || 0) - (a.timestamp || 0)
  })
  return {
    // Everything unread, INFO included — what the Notices list renders.
    // Callers that care about severity read each item's `needsAttention`
    // rather than a pre-filtered second list, which only ever had one
    // consumer and then lost it.
    items: normalized,
    unread: {
      info: num(unread.info, 0),
      warning: num(unread.warning, 0),
      alert: num(unread.alert, 0),
      total: num(unread.total, 0)
    }
  }
}

function normalizeNotification(item) {
  return {
    id: item.id,
    title: item.title || "",
    subject: item.subject || "",
    description: item.description || "",
    importance: item.importance || "INFO",
    needsAttention: notificationNeedsAttention(item),
    // `subject` is the event ("Docker Auto Update", "Disk-Clear finished
    // (0 errors)"); `title` is the component that raised it ("Community
    // Applications"), which repeats across every notice it sends. Compact
    // rows that have room for one line want the subject.
    summary: item.subject || item.title || "",
    // `link` is relative on a real server ("/Main") — callers prefix
    // it with the configured base URL.
    link: item.link || "",
    timestamp: item.timestamp ? Date.parse(item.timestamp) : null,
    formattedTimestamp: item.formattedTimestamp || ""
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
