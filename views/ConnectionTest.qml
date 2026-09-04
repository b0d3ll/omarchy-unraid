import QtQuick
import qs.Commons
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
Column {
  id: root

  property string testState: "idle" // idle | testing | success | failure
  property string resultHostname: ""
  property string resultVersion: ""
  property string failureReason: "" // "unreachable" | "rejected"
  property string failureMessage: ""

  signal succeeded(string hostname, string version)
  signal failed(string reason, string message)

  function run(url, key) {
    root.testState = "testing"
    root.failureMessage = ""
    var curlConfig = 'header = "x-api-key: ' + key + '"\n' + 'header = "Content-Type: application/json"\n'
    var query = JSON.stringify({ query: "{ online vars { name version } }" })
    testProc.environment = {
      "OMARCHY_UNRAID_CURL_CONFIG": curlConfig,
      "OMARCHY_UNRAID_QUERY": query,
      "OMARCHY_UNRAID_URL": url
    }
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
    stdout: StdioCollector {
      id: outCollector
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var parsed = null
        try { parsed = JSON.parse(outCollector.text()) } catch (e) { parsed = null }
        var vars = parsed && parsed.data && parsed.data.vars ? parsed.data.vars : null
        if (parsed && parsed.data && parsed.data.online && vars) {
          root.testState = "success"
          root.resultHostname = vars.name || ""
          root.resultVersion = vars.version || ""
          root.succeeded(root.resultHostname, root.resultVersion)
        } else {
          root.testState = "failure"
          root.failureReason = "rejected"
          root.failureMessage = "Reachable, but the response didn't look like an Unraid GraphQL API."
          root.failed(root.failureReason, root.failureMessage)
        }
      } else if (exitCode === 22) {
        root.testState = "failure"
        root.failureReason = "rejected"
        root.failureMessage = "The server responded, but rejected the request — check the API key."
        root.failed(root.failureReason, root.failureMessage)
      } else {
        root.testState = "failure"
        root.failureReason = "unreachable"
        root.failureMessage = "Could not reach the server at that address."
        root.failed(root.failureReason, root.failureMessage)
      }
    }
  }
}
