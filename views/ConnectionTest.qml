import QtQuick
import qs.Commons
import Quickshell
import Quickshell.Io

// Shared "test connection" widget — used by onboarding Step 2 (testing a
// key the user just typed, not yet stored) and Settings' Authentication
// "Test permissions" (testing the already-stored key). Runs the Health
// probe from spec section 32 via curl.
//
// The API key is handed to curl through a header config file supplied via
// bash process substitution (`-K <(...)`), built from an environment
// variable — never argv, so it never shows up in `ps`/`/proc/<pid>/cmdline`.
// Known limitation: a key containing a literal `"` would break curl's own
// config-file quoting; Unraid API keys are opaque tokens and don't, so
// this isn't handled specially.
//
// Unraid's GraphQL API answers with HTTP 200 even on auth failure — the
// real status lives in `errors[0].extensions.originalError.statusCode`,
// with `data: null`. `curl -f` never sees a 4xx/5xx to fail on for that
// case, so success/rejection is told apart by inspecting the JSON body,
// not just the exit code. Confirmed against a real Unraid 7.2 box.
Column {
  id: root

  property string testState: "idle" // idle | testing | success | failure
  property string resultHostname: ""
  property string resultVersion: ""
  property string failureReason: "" // "unreachable" | "rejected"
  property string failureMessage: ""

  signal succeeded(string hostname, string version)
  signal failed(string reason, string message)

  // Assigning Process.environment REPLACES the process's entire
  // environment rather than adding to it — this broke every real-world
  // test (curl/bash lost PATH/HOME, among other things) until it was
  // caught: see SecretStore.qml's sessionEnv() for the same fix and the
  // reasoning behind it.
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
    for (var k in extra) base[k] = extra[k]
    return base
  }

  function run(url, key) {
    root.testState = "testing"
    root.failureMessage = ""
    var curlConfig = 'header = "x-api-key: ' + key + '"\n' + 'header = "Content-Type: application/json"\n'
    var query = JSON.stringify({ query: "{ online vars { name version } }" })
    testProc.environment = root.sessionEnv({
      "OMARCHY_UNRAID_CURL_CONFIG": curlConfig,
      "OMARCHY_UNRAID_QUERY": query,
      "OMARCHY_UNRAID_URL": url
    })
    testProc.command = ["bash", "-c",
      'curl -fsS --max-time 6 -K <(printf \'%s\' "$OMARCHY_UNRAID_CURL_CONFIG") -X POST --data "$OMARCHY_UNRAID_QUERY" "$OMARCHY_UNRAID_URL"']
    testProc.running = true
  }

  spacing: Style.space(8)
  width: parent ? parent.width : implicitWidth

  Row {
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      visible: root.testState === "testing"
      text: "Testing connection…"
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      visible: root.testState === "success"
      text: "✓ Connected to " + root.resultHostname + (root.resultVersion !== "" ? " — Unraid " + root.resultVersion : "")
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      visible: root.testState === "failure"
      text: root.failureMessage
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      width: root.width
    }
  }

  Process {
    id: testProc

    // `.text()` on a StdioCollector is only safe to call from that same
    // collector's own onStreamFinished — calling it from Process.onExited
    // threw "Property 'text' ... is not a function" against a real server
    // (the collector isn't guaranteed to have finished flushing by then).
    // So each collector caches its own text, onExited only records the
    // exit code, and _finish() runs once all three have reported in,
    // regardless of what order they arrive in.
    property int lastExitCode: -1
    property string lastStdout: ""
    property string lastStderr: ""
    property bool _exited: false
    property bool _stdoutDone: false
    property bool _stderrDone: false

    function _finish() {
      if (!_exited || !_stdoutDone || !_stderrDone) return
      _exited = false
      _stdoutDone = false
      _stderrDone = false

      var exitCode = testProc.lastExitCode
      if (exitCode === 0 || exitCode === 22) {
        var parsed = null
        try { parsed = JSON.parse(testProc.lastStdout) } catch (e) { parsed = null }
        var vars = parsed && parsed.data && parsed.data.vars ? parsed.data.vars : null
        var firstError = parsed && parsed.errors && parsed.errors.length > 0 ? parsed.errors[0] : null
        var errorStatus = firstError && firstError.extensions && firstError.extensions.originalError
          ? firstError.extensions.originalError.statusCode : null

        if (parsed && parsed.data && parsed.data.online && vars) {
          root.testState = "success"
          root.resultHostname = vars.name || ""
          root.resultVersion = vars.version || ""
          root.succeeded(root.resultHostname, root.resultVersion)
        } else if (firstError && (errorStatus === 401 || errorStatus === 403)) {
          root.testState = "failure"
          root.failureReason = "rejected"
          root.failureMessage = "The server rejected the API key (" + firstError.message + ")."
          root.failed(root.failureReason, root.failureMessage)
        } else if (firstError) {
          root.testState = "failure"
          root.failureReason = "rejected"
          root.failureMessage = "The server responded with an error: " + firstError.message
          root.failed(root.failureReason, root.failureMessage)
        } else {
          root.testState = "failure"
          root.failureReason = "rejected"
          root.failureMessage = "Reachable, but the response didn't look like an Unraid GraphQL API."
          root.failed(root.failureReason, root.failureMessage)
        }
      } else {
        root.testState = "failure"
        root.failureReason = "unreachable"
        var stderrText = testProc.lastStderr.trim()
        root.failureMessage = "Could not reach the server at that address."
          + (stderrText !== "" ? " (" + stderrText + ")" : " (curl exit " + exitCode + ")")
        root.failed(root.failureReason, root.failureMessage)
      }
    }

    onExited: function(exitCode) {
      testProc.lastExitCode = exitCode
      testProc._exited = true
      testProc._finish()
    }

    stdout: StdioCollector {
      id: outCollector
      waitForEnd: true
      onStreamFinished: {
        testProc.lastStdout = text
        testProc._stdoutDone = true
        testProc._finish()
      }
    }
    stderr: StdioCollector {
      id: errCollector
      waitForEnd: true
      onStreamFinished: {
        testProc.lastStderr = text
        testProc._stderrDone = true
        testProc._finish()
      }
    }
  }
}
