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
  property string serverUrl: ""
  property string graphqlUrl: ""
  property string hostname: ""
  property string unraidVersion: ""
  property string apiVersion: ""
  property string lastTestedAt: ""

  function applyJson(text) {
    var data = {}
    try { data = JSON.parse(text || "{}") } catch (e) { data = {} }
    root.serverUrl = typeof data.serverUrl === "string" ? data.serverUrl : ""
    root.graphqlUrl = typeof data.graphqlUrl === "string" ? data.graphqlUrl : ""
    root.hostname = typeof data.hostname === "string" ? data.hostname : ""
    root.unraidVersion = typeof data.unraidVersion === "string" ? data.unraidVersion : ""
    root.apiVersion = typeof data.apiVersion === "string" ? data.apiVersion : ""
    root.lastTestedAt = typeof data.lastTestedAt === "string" ? data.lastTestedAt : ""
    root.loaded = true
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
      lastTestedAt: fields.lastTestedAt !== undefined ? fields.lastTestedAt : root.lastTestedAt
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
    save({ serverUrl: "", graphqlUrl: "", hostname: "", unraidVersion: "", apiVersion: "", lastTestedAt: "" })
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
