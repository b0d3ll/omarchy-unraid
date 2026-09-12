import QtQuick
import Quickshell
import Quickshell.Io
import "Exec.js" as Exec

// API key storage via the Secret Service (spec section 40) — verified
// working on this machine against the running gnome-keyring-daemon.
//
// The key goes to `secret-tool` on stdin: written with Process.write(),
// then `stdinEnabled = false` to close the channel so the tool sees EOF
// and returns. An earlier version claimed Quickshell had no way to close
// that channel and passed the key through a process-local environment
// variable instead; `stdinEnabled` is writable, so that is no longer true
// — and the environment was the worse place for it, because it sits in
// /proc/<pid>/environ for the life of the process.
//
// secret-tool is addressed by absolute path (see Exec.js). It is handed
// the credential, so resolving it through an inherited $PATH would mean a
// single writable directory ahead of /usr/bin could capture the key.
Item {
  id: root

  readonly property string serviceId: "io.github.b0d3ll.omarchy-unraid"
  readonly property string label: "Omarchy Unraid API Key"
  readonly property var lookupArgs: [Exec.SECRET_TOOL, "lookup", "service", serviceId, "account", "default"]
  readonly property var clearArgs: [Exec.SECRET_TOOL, "clear", "service", serviceId, "account", "default"]
  readonly property var storeArgs: [Exec.SECRET_TOOL, "store", "--label=" + label, "service", serviceId, "account", "default"]

  property bool checked: false
  property bool present: false

  // Assigning Process.environment REPLACES the process's entire
  // environment rather than adding to it — confirmed by reproducing the
  // failure directly: `secret-tool` needs DBUS_SESSION_BUS_ADDRESS to
  // reach the session's Secret Service and fails with "Cannot autolaunch
  // D-Bus" without it.
  //
  // PATH is deliberately absent: every program here is started by absolute
  // path, so passing one would only give a substituted binary somewhere to
  // come from.
  function sessionEnv() {
    return {
      HOME: Quickshell.env("HOME"),
      USER: Quickshell.env("USER"),
      DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
      DISPLAY: Quickshell.env("DISPLAY"),
      WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY")
    }
  }

  // An API key never legitimately contains whitespace, and a pasted one
  // often carries a trailing newline — which then breaks the curl config
  // file the connection test builds. Scrub it here so nothing downstream
  // ever sees it, on both the way in and the way back out (so a key
  // stored dirty by an earlier version self-heals on read).
  function sanitizeKey(key) {
    return String(key).replace(/[\r\n\t]/g, "").trim()
  }

  function store(key, onDone) {
    storeProc.command = root.storeArgs
    storeProc.environment = root.sessionEnv()
    storeProc._onDone = onDone || null
    storeProc._secret = root.sanitizeKey(key)
    storeProc.stdinEnabled = true
    storeProc.running = true
  }

  function clear(onDone) {
    clearProc._onDone = onDone || null
    clearProc.running = true
  }

  // Fetches the key and hands it to `callback(key)` without ever assigning
  // it to a QML property — so it can't end up bound into a Text label, a
  // log, or plugin debug output.
  //
  // Concurrent callers are coalesced into one keyring lookup. This matters:
  // six polled resources ask for the key at almost the same moment, and an
  // earlier single-callback version silently dropped five of them — those
  // requests then sat "busy" forever and never retried, so five of six
  // views stayed empty while one worked.
  property var _pendingCallbacks: []

  function fetchForUse(callback) {
    if (callback) root._pendingCallbacks.push(callback)
    if (fetchProc.running) return
    fetchProc.running = true
  }

  function _deliverKey(value) {
    var callbacks = root._pendingCallbacks
    root._pendingCallbacks = []
    for (var i = 0; i < callbacks.length; i++) callbacks[i](value)
  }

  function recheckPresence() {
    presenceProc.running = true
  }

  Process {
    id: presenceProc
    environment: root.sessionEnv()
    command: root.lookupArgs
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.present = exitCode === 0
      root.checked = true
    }
  }

  Process {
    id: fetchProc
    environment: root.sessionEnv()
    command: root.lookupArgs
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._deliverKey(root.sanitizeKey(text))
    }
    // If the lookup fails outright there may be no stdout to finish, so
    // waiting callers would hang. Deliver an empty key instead, which
    // callers surface as "no API key stored" rather than never answering.
    onExited: function(exitCode) {
      if (exitCode !== 0) root._deliverKey("")
    }
  }

  Process {
    id: storeProc
    property var _onDone: null
    property string _secret: ""

    // Write on started, not before: the channel does not exist until the
    // process does. Closing stdin straight after is what makes secret-tool
    // return — it reads until EOF.
    onStarted: {
      storeProc.write(storeProc._secret)
      storeProc._secret = ""
      storeProc.stdinEnabled = false
    }

    onExited: function(exitCode) {
      root.present = exitCode === 0
      root.checked = true
      if (storeProc._onDone) storeProc._onDone(exitCode === 0)
      storeProc._onDone = null
      storeProc._secret = ""
      storeProc.environment = {}
    }
  }

  Process {
    id: clearProc
    environment: root.sessionEnv()
    command: root.clearArgs
    property var _onDone: null
    onExited: function(exitCode) {
      root.present = false
      if (clearProc._onDone) clearProc._onDone(exitCode === 0)
      clearProc._onDone = null
    }
  }

  Component.onCompleted: recheckPresence()
}
