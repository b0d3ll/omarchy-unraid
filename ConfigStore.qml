import QtQuick
import Quickshell
import Quickshell.Io

// Non-secret configuration (spec section 40) — server URL and last-known
// identity, persisted as plain JSON. The API key never lives here; see
// SecretStore.qml.
//
// Uses FileView's own text()/setText() rather than a JsonAdapter: nothing
// in this codebase (first-party included) actually uses JsonAdapter, so
// there's no local example to verify its property-sync behavior against.
// Plain text()/JSON.parse and setText()/JSON.stringify is the same
// approach weather/Panel.qml uses for reading its location file, just
// applied to both read and write.
Item {
  id: root

  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarchy-unraid"
  readonly property string configPath: configDir + "/config.json"

  property bool loaded: false
  // serverUrl/graphqlUrl describe the *preferred* endpoint. They're kept
  // because onboarding, the header and Settings all still talk in terms
  // of "the server address", and because a config written by an earlier
  // version has only these. Which endpoint is actually live right now is
  // ConnectionManager's business and is never written to disk — failover
  // would otherwise mean a file write on every network blip.
  property string serverUrl: ""
  property string graphqlUrl: ""
  property string hostname: ""
  property string unraidVersion: ""
  property string apiVersion: ""
  property string lastTestedAt: ""

  // [{ id, type, name, baseUrl, graphqlUrl, priority, enabled }]
  property var endpoints: []

  function applyJson(text) {
    var data = {}
    try { data = JSON.parse(text || "{}") } catch (e) { data = {} }
    root.serverUrl = typeof data.serverUrl === "string" ? data.serverUrl : ""
    root.graphqlUrl = typeof data.graphqlUrl === "string" ? data.graphqlUrl : ""
    root.hostname = typeof data.hostname === "string" ? data.hostname : ""
    root.unraidVersion = typeof data.unraidVersion === "string" ? data.unraidVersion : ""
    root.apiVersion = typeof data.apiVersion === "string" ? data.apiVersion : ""
    root.lastTestedAt = typeof data.lastTestedAt === "string" ? data.lastTestedAt : ""
    root.endpoints = root._migrateEndpoints(data)
    root.loaded = true
  }

  // A config written before Milestone 3 has a single serverUrl and no
  // endpoint list; turn that into one LAN entry rather than losing the
  // server the user already set up.
  function _migrateEndpoints(data) {
    var list = Array.isArray(data.endpoints) ? data.endpoints : []
    var cleaned = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!e || typeof e.graphqlUrl !== "string" || e.graphqlUrl === "") continue
      cleaned.push({
        id: String(e.id || ("endpoint-" + i)),
        type: String(e.type || "CUSTOM"),
        name: String(e.name || e.type || "Endpoint"),
        baseUrl: String(e.baseUrl || ""),
        graphqlUrl: String(e.graphqlUrl),
        priority: typeof e.priority === "number" ? e.priority : i,
        enabled: e.enabled !== false
      })
    }
    if (cleaned.length > 0) return cleaned

    if (typeof data.graphqlUrl === "string" && data.graphqlUrl !== "") {
      return [{
        id: "lan",
        type: "LAN",
        name: "LAN",
        baseUrl: typeof data.serverUrl === "string" ? data.serverUrl : "",
        graphqlUrl: data.graphqlUrl,
        priority: 0,
        enabled: true
      }]
    }
    return []
  }

  function saveEndpoints(list) {
    save({ endpoints: list })
  }

  // Persist the given fields (server identity learned during setup/test).
  // Called with the full set every time — this store only ever holds one
  // server's worth of state (spec section 2: v0.1 is single-server).
  property string _pendingWrite: ""

  function save(fields) {
    var data = {
      serverUrl: fields.serverUrl !== undefined ? fields.serverUrl : root.serverUrl,
      graphqlUrl: fields.graphqlUrl !== undefined ? fields.graphqlUrl : root.graphqlUrl,
      hostname: fields.hostname !== undefined ? fields.hostname : root.hostname,
      unraidVersion: fields.unraidVersion !== undefined ? fields.unraidVersion : root.unraidVersion,
      apiVersion: fields.apiVersion !== undefined ? fields.apiVersion : root.apiVersion,
      lastTestedAt: fields.lastTestedAt !== undefined ? fields.lastTestedAt : root.lastTestedAt,
      endpoints: fields.endpoints !== undefined ? fields.endpoints : root.endpoints
    }
    applyJson(JSON.stringify(data))
    // mkdir must finish before the write lands, or a truly fresh install
    // (no ~/.config/omarchy-unraid yet) races setText() against a missing
    // parent directory — so the write happens in mkdirProc.onExited, not
    // here.
    root._pendingWrite = JSON.stringify(data, null, 2)
    mkdirProc.command = ["mkdir", "-p", root.configDir]
    mkdirProc.running = true
  }

  function clear() {
    save({ serverUrl: "", graphqlUrl: "", hostname: "", unraidVersion: "",
      apiVersion: "", lastTestedAt: "", endpoints: [] })
  }

  Process {
    id: mkdirProc
    onExited: function() {
      configFile.setText(root._pendingWrite)
      root._pendingWrite = ""
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyJson(text())
    onLoadFailed: root.applyJson("")
    onFileChanged: reload()
  }
}
