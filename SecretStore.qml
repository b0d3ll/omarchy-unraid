import QtQuick
import Quickshell
import Quickshell.Io

// API key storage via the Secret Service (spec section 40) — verified
// working on this machine against the running gnome-keyring-daemon.
//
// The key is handed to `secret-tool` through a process-local environment
// variable, not argv and not QML `Process.write()` — Quickshell's Process
// type has no exposed way to close the stdin write channel, so a
// write()-then-wait-for-EOF approach would leave `secret-tool store`
// blocked forever. An env var never appears in argv/`ps`, and reading it
// back requires the same privilege (same-uid or root via /proc/<pid>/environ)
// that reading a piped fd in flight would have required anyway.
Item {
  id: root

  readonly property string serviceId: "io.github.b0d3ll.omarchy-unraid"
  readonly property string label: "Omarchy Unraid API Key"
  readonly property var lookupArgs: ["secret-tool", "lookup", "service", serviceId, "account", "default"]
  readonly property var clearArgs: ["secret-tool", "clear", "service", serviceId, "account", "default"]

  property bool checked: false
  property bool present: false

  // Assigning Process.environment REPLACES the process's entire
  // environment rather than adding to it — confirmed by reproducing the
  // failure directly: `secret-tool` needs DBUS_SESSION_BUS_ADDRESS to
  // reach the session's Secret Service and fails with "Cannot autolaunch
  // D-Bus" without it. Every Process that needs a custom env var has to
  // layer it on top of this, not replace the environment outright.
  function sessionEnv(extra) {
    var base = {
      PATH: Quickshell.env("PATH"),
      HOME: Quickshell.env("HOME"),
      USER: Quickshell.env("USER"),
      DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
      DISPLAY: Quickshell.env("DISPLAY"),
      WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY")
    }
    for (var key in extra) base[key] = extra[key]
    return base
  }

  function store(key, onDone) {
    storeProc.command = ["bash", "-c",
      "printf '%s' \"$OMARCHY_UNRAID_SECRET\" | secret-tool store --label=\"" + root.label + "\" service " + root.serviceId + " account default"]
    storeProc.environment = root.sessionEnv({ "OMARCHY_UNRAID_SECRET": key })
    storeProc._onDone = onDone || null
    storeProc.running = true
  }

  function clear(onDone) {
    clearProc._onDone = onDone || null
    clearProc.running = true
  }

  // Fetches the key and hands it to `callback(key)` without ever assigning
  // it to a QML property — so it can't end up bound into a Text label, a
  // log, or plugin debug output.
  function fetchForUse(callback) {
    fetchProc._callback = callback
    fetchProc.running = true
  }

  function recheckPresence() {
    presenceProc.running = true
  }

  Process {
    id: presenceProc
    command: root.lookupArgs
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.present = exitCode === 0
      root.checked = true
    }
  }

  Process {
    id: fetchProc
    command: root.lookupArgs
    property var _callback: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = text
        if (fetchProc._callback) fetchProc._callback(value)
        fetchProc._callback = null
      }
    }
  }

  Process {
    id: storeProc
    property var _onDone: null
    onExited: function(exitCode) {
      root.present = exitCode === 0
      root.checked = true
      if (storeProc._onDone) storeProc._onDone(exitCode === 0)
      storeProc._onDone = null
      // Environment carries the secret only for this one invocation —
      // clear it immediately so it doesn't linger in the Process object.
      storeProc.environment = {}
    }
  }

  Process {
    id: clearProc
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
