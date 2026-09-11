pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../views"

// First-run wizard (spec section 29, cut to 3 steps — see Milestone 2
// plan: remote/Tailscale detection is deferred to Milestone 3, where the
// Connection Manager actually exists to use it).
//
// Deliberately owns its own `step` state rather than deriving it from
// Panel's isConfigured: once the user reaches step 3, saving already
// happened (so a shell restart correctly skips onboarding next time), but
// the "you're done" screen must stay visible until they click Finish, not
// disappear the instant isConfigured flips true.
Column {
  id: root

  property var configStore: null
  property var secretStore: null
  property color foreground: Color.foreground

  signal finished()

  property int step: 1
  property string addressInput: "http://tower.local"
  property string keyInput: ""
  property string pendingBaseUrl: ""
  // Local until the config is written on Finish — there is nothing to read
  // it back from yet. Only meaningful for an https address, so the control
  // only appears for one.
  property bool allowSelfSigned: false
  readonly property bool _httpsPending: /^https:/i.test(root.pendingBaseUrl)
  property string pendingGraphqlUrl: ""
  property bool saving: false
  property string saveError: ""

  // Pasting into a single-line field can carry newlines along; strip them
  // at the boundary so what the field shows is what actually gets used.
  function cleanInput(value) {
    return String(value).replace(/[\r\n\t]/g, "")
  }

  function normalizeAddress(input) {
    var trimmed = (input || "").trim().replace(/\/+$/, "")
    if (trimmed === "") return { baseUrl: "", graphqlUrl: "" }
    if (!/^https?:\/\//i.test(trimmed)) trimmed = "http://" + trimmed
    var graphqlUrl = /\/graphql$/i.test(trimmed) ? trimmed : trimmed + "/graphql"
    return { baseUrl: trimmed, graphqlUrl: graphqlUrl }
  }

  // Shared between the buttons' onClicked and each field's onAccepted (so
  // pressing Enter does the same thing as clicking the button next to it,
  // and still respects the same enabled/validation gate).
  function goToStep2() {
    if (root.addressInput.trim() === "") return
    var normalized = root.normalizeAddress(root.addressInput)
    root.pendingBaseUrl = normalized.baseUrl
    root.pendingGraphqlUrl = normalized.graphqlUrl
    root.keyInput = ""
    connectionTest.testState = "idle"
    root.step = 2
  }

  function runTest() {
    if (root.keyInput.trim() === "" || connectionTest.testState === "testing") return
    connectionTest.run(root.pendingGraphqlUrl, root.keyInput)
  }

  function saveAndFinish() {
    if (connectionTest.testState !== "success" || root.saving) return
    root.saving = true
    root.saveError = ""
    root.secretStore.store(root.keyInput, function(ok) {
      root.saving = false
      if (!ok) {
        root.saveError = "Could not save the API key to the system keyring."
        return
      }
      root.configStore.save({
        serverUrl: root.pendingBaseUrl,
        graphqlUrl: root.pendingGraphqlUrl,
        hostname: connectionTest.resultHostname,
        unraidVersion: connectionTest.resultVersion,
        allowSelfSigned: root.allowSelfSigned
      })
      root.step = 3
    })
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(16)

  // ---------------------------------------------------------------- Step 1
  Column {
    width: parent.width
    visible: root.step === 1
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: "Connect to Unraid"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    PanelSectionHeader { text: "SERVER ADDRESS"; foreground: root.foreground }

    TextField {
      id: addressField
      width: parent.width
      text: root.addressInput
      foreground: root.foreground
      onTextChanged: {
        var cleaned = root.cleanInput(text)
        if (cleaned !== text) text = cleaned
        root.addressInput = cleaned
      }
      onAccepted: root.goToStep2()
    }

    Button {
      text: "Continue"
      bordered: true
      foreground: root.foreground
      enabled: root.addressInput.trim() !== ""
      onClicked: root.goToStep2()
    }
  }

  // ---------------------------------------------------------------- Step 2
  Column {
    width: parent.width
    visible: root.step === 2
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: "API key"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: root.pendingBaseUrl
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    TextField {
      id: keyField
      width: parent.width
      password: true
      text: root.keyInput
      foreground: root.foreground
      onTextChanged: {
        var cleaned = root.cleanInput(text)
        if (cleaned !== text) text = cleaned
        root.keyInput = cleaned
      }
      onAccepted: connectionTest.testState === "success" ? root.saveAndFinish() : root.runTest()
    }

    Text {
      textFormat: Text.PlainText
      visible: root.saveError !== ""
      text: root.saveError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: "Test connection"
        bordered: true
        foreground: root.foreground
        enabled: root.keyInput.trim() !== "" && connectionTest.testState !== "testing"
        onClicked: root.runTest()
      }

      Button {
        text: "Back"
        bordered: true
        foreground: root.foreground
        onClicked: root.step = 1
      }

      Button {
        text: root.saving ? "Saving…" : "Continue"
        bordered: true
        foreground: root.foreground
        enabled: connectionTest.testState === "success" && !root.saving
        onClicked: root.saveAndFinish()
      }
    }

    // Offered rather than pre-checked: Unraid's HTTPS listener almost always
    // carries a self-signed certificate, but trusting one is the user's call
    // to make, not a default to inherit.
    Row {
      spacing: Style.space(8)
      visible: root._httpsPending

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "Allow self-signed certificate"
        color: Qt.darker(root.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: root.allowSelfSigned ? "On" : "Off"
        bordered: true
        selected: root.allowSelfSigned
        foreground: root.foreground
        onClicked: {
          root.allowSelfSigned = !root.allowSelfSigned
          connectionTest.testState = "idle"
        }
      }
    }

    ConnectionTest {
      id: connectionTest
      width: parent.width
      allowSelfSigned: root.allowSelfSigned
    }
  }

  // ---------------------------------------------------------------- Step 3
  Column {
    width: parent.width
    visible: root.step === 3
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: connectionTest.resultHostname + " is ready."
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Column {
      width: parent.width
      spacing: Style.space(4)

      Text { textFormat: Text.PlainText; text: "Local access       ✓"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body }
      Text { textFormat: Text.PlainText; text: "API                ✓"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body }
    }

    Button {
      text: "Finish"
      bordered: true
      foreground: root.foreground
      onClicked: root.finished()
    }
  }
}
