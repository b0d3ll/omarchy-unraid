import QtQuick
import qs.Commons
// Qualified so the root directory's Panel.qml can't shadow qs.Ui's Panel.
import ".." as Plugin
import "../Api.js" as Api

// Shared "test connection" widget — used by onboarding Step 2 (testing a
// key the user just typed, not yet stored) and Settings' Authentication
// "Test permissions" (testing the already-stored key).
//
// All the curl/keyring/parsing machinery lives in GraphQlRequest now, so
// this file is just the health probe plus its status line.
Column {
  id: root

  property string testState: "idle" // idle | testing | success | failure
  property string resultHostname: ""
  property string resultVersion: ""
  property string failureReason: "" // "unreachable" | "rejected" | "malformed"
  property string failureMessage: ""

  // Set to reuse the key already in the keyring; leave empty to test a
  // key passed straight into run().
  property var secretStore: null
  property bool allowSelfSigned: false

  signal succeeded(string hostname, string version)
  signal failed(string reason, string message)

  function run(url, key) {
    root.testState = "testing"
    root.failureMessage = ""
    request.endpoint = url
    request.send(Api.QUERY_HEALTH, key || "")
  }

  spacing: Style.space(8)
  width: parent ? parent.width : implicitWidth

  Plugin.GraphQlRequest {
    id: request
    secretStore: root.secretStore
    allowSelfSigned: root.allowSelfSigned

    onSucceeded: function(data, errors) {
      var vars = data && data.vars ? data.vars : null
      if (data && data.online && vars) {
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
    }

    onFailed: function(reason, message) {
      root.testState = "failure"
      root.failureReason = reason
      root.failureMessage = message
      root.failed(reason, message)
    }
  }

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
}
