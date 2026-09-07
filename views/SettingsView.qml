pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui
import "../components"
import ".." as Plugin
import "../Api.js" as Api

// Server/Connections/Authentication are real now (spec section 28).
// Behavior and About stay placeholders — Behavior's refresh-interval/
// cache toggles depend on the polling that doesn't exist until Milestone
// 3/4, and About doesn't need content before there's a public release.
Column {
  id: root

  property var service: null
  property var configStore: null
  property var secretStore: null
  property color foreground: Color.foreground

  property bool editingServer: false
  property string editServerInput: ""
  property bool editingKey: false
  property string editKeyInput: ""

  // See SetupView's cleanInput(): a pasted value can carry newlines, and
  // a newline in the API key breaks the curl config the test builds.
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

  // Endpoints sorted the way the selector will actually try them, so the
  // list on screen is the priority order rather than insertion order.
  readonly property var _endpoints: {
    var list = (root.service ? root.service.endpointList : []).slice()
    return list.sort(function(a, b) {
      var pa = typeof a.priority === "number" ? a.priority : 999
      var pb = typeof b.priority === "number" ? b.priority : 999
      return pa - pb
    })
  }

  readonly property var _discovered: root.service ? root.service.discovered : []

  // Per-endpoint reachability results, keyed by endpoint id. The server
  // advertising an address doesn't mean this machine can reach it —
  // `tower.local` is advertised but needs an mDNS resolver the client may
  // not have — so each one can be checked before you rely on it.
  property var endpointProbes: ({})

  function testEndpoint(endpoint) {
    if (!endpoint) return
    var next = {}
    for (var k in root.endpointProbes) next[k] = root.endpointProbes[k]
    next[endpoint.id] = "testing"
    root.endpointProbes = next
    endpointProbe.probeId = endpoint.id
    endpointProbe.endpoint = endpoint.graphqlUrl
    endpointProbe.send(Api.QUERY_HEALTH)
  }

  function _recordProbe(id, verdict) {
    var next = {}
    for (var k in root.endpointProbes) next[k] = root.endpointProbes[k]
    next[id] = verdict
    root.endpointProbes = next
  }

  Plugin.GraphQlRequest {
    id: endpointProbe
    secretStore: root.secretStore
    timeoutSeconds: 4

    property string probeId: ""

    onSucceeded: function(data, errors) {
      root._recordProbe(endpointProbe.probeId, (data && data.online) ? "ok" : "odd")
    }
    onFailed: function(reason, message) {
      root._recordProbe(endpointProbe.probeId, reason === "unreachable" ? "unreachable" : "rejected")
    }
  }

  // "Add" rather than "Save": there's a list now, so a typed address
  // becomes another candidate instead of replacing the server.
  function saveServer() {
    if (root.editServerInput.trim() === "" || !root.service) return
    var normalized = root.normalizeAddress(root.editServerInput)
    root.service.addEndpoint({
      id: "custom-" + Date.now(),
      type: "CUSTOM",
      name: "Custom",
      baseUrl: normalized.baseUrl,
      graphqlUrl: normalized.graphqlUrl,
      priority: root._endpoints.length,
      enabled: true
    })
    root.editServerInput = ""
    root.editingServer = false
  }

  function testKey() {
    if (root.editKeyInput.trim() === "" || testWidget.testState === "testing") return
    testWidget.run(root.configStore.graphqlUrl, root.editKeyInput)
  }

  function saveKey() {
    if (testWidget.testState !== "success") return
    root.secretStore.store(root.editKeyInput, function(ok) {
      if (ok) {
        root.configStore.save({ hostname: testWidget.resultHostname, unraidVersion: testWidget.resultVersion })
        root.editingKey = false
      }
    })
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(16)

  // ------------------------------------------------------------- SERVER
  Column {
    width: parent.width
    spacing: Style.space(4)

    PanelSectionHeader { text: "SERVER"; foreground: root.foreground }

    // Live values once a poll has landed (spec section 50); the stored
    // values from onboarding fill in until then.
    Grid {
      columns: 2
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(4)
      visible: root.configStore && root.configStore.hostname !== ""

      Text { textFormat: Text.PlainText; text: "Name"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: root.service ? root.service.system.hostname : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: "Unraid"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: root.service ? root.service.system.unraidVersion : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; visible: apiVersionValue.text !== ""; text: "API"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { id: apiVersionValue; textFormat: Text.PlainText; visible: text !== ""; text: root.service ? root.service.system.apiVersion : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; visible: uptimeValue.text !== ""; text: "Uptime"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { id: uptimeValue; textFormat: Text.PlainText; visible: text !== ""; text: root.service ? root.service.uptime : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
    }

    Text {
      textFormat: Text.PlainText
      visible: !root.configStore || root.configStore.hostname === ""
      text: "Not configured"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // --------------------------------------------------------- CONNECTIONS
  //
  // The endpoint list is the connection config now (spec sections 28, 30):
  // priority order is what the selector walks, so reordering here is what
  // decides "try LAN first, fall back to Tailscale".
  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader { text: "CONNECTIONS"; foreground: root.foreground }

    EmptyState {
      width: parent.width
      visible: root._endpoints.length === 0
      message: "No endpoints configured."
      foreground: root.foreground
    }

    Repeater {
      model: root._endpoints

      Column {
        id: endpointRow
        required property var modelData
        readonly property bool isActive: root.service
          && root.service.connection.endpoint === endpointRow.modelData.baseUrl
          && !root.service.offline

        width: root.width
        spacing: Style.space(2)

        Row {
          spacing: Style.space(6)
          width: parent.width

          Text {
            textFormat: Text.PlainText
            text: endpointRow.modelData.name || endpointRow.modelData.type
            color: endpointRow.modelData.enabled ? root.foreground : Qt.darker(root.foreground, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: endpointRow.isActive
          }

          StatusBadge {
            visible: endpointRow.isActive
            anchors.verticalCenter: parent.verticalCenter
            text: root.service && root.service.connection.latencyMs >= 0
              ? "LIVE · " + root.service.connection.latencyMs + " MS"
              : "LIVE"
            emphasized: true
            foreground: root.foreground
          }

          StatusBadge {
            visible: !endpointRow.modelData.enabled
            anchors.verticalCenter: parent.verticalCenter
            text: "OFF"
            foreground: root.foreground
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideMiddle
          text: endpointRow.modelData.baseUrl
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          visible: text !== ""
          text: {
            switch (root.endpointProbes[endpointRow.modelData.id]) {
              case "ok": return "Reachable from this machine."
              case "unreachable": return "Not reachable from this machine — the address may need "
                + "a VPN or a resolver this client doesn't have."
              case "rejected": return "Reached it, but the API key was refused."
              case "odd": return "Answered, but not like an Unraid API."
              default: return ""
            }
          }
          color: root.endpointProbes[endpointRow.modelData.id] === "ok"
            ? Qt.darker(root.foreground, 1.4) : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)

          Button {
            text: "↑"
            foreground: root.foreground
            onClicked: root.service.moveEndpoint(endpointRow.modelData.id, -1)
          }

          Button {
            text: "↓"
            foreground: root.foreground
            onClicked: root.service.moveEndpoint(endpointRow.modelData.id, 1)
          }

          Button {
            text: endpointRow.modelData.enabled ? "Disable" : "Enable"
            foreground: root.foreground
            onClicked: root.service.setEndpointEnabled(endpointRow.modelData.id,
              !endpointRow.modelData.enabled)
          }

          Button {
            text: {
              var v = root.endpointProbes[endpointRow.modelData.id]
              return v === "testing" ? "Testing…" : "Test"
            }
            foreground: root.foreground
            onClicked: root.testEndpoint(endpointRow.modelData)
          }

          Button {
            // Removing the only endpoint would leave nothing to connect
            // to, which is a worse state than a disabled one.
            visible: root._endpoints.length > 1
            text: "Remove"
            foreground: Color.urgent
            onClicked: root.service.removeEndpoint(endpointRow.modelData.id)
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground; strength: 0.06 }
      }
    }

    // ----------------------------------------------------------- discovery
    Row {
      spacing: Style.space(8)
      visible: !root.editingServer

      Button {
        text: root.service && root.service.discovering ? "Detecting…" : "Detect endpoints"
        bordered: true
        foreground: root.foreground
        enabled: root.service && !root.service.discovering
        onClicked: root.service.discoverEndpoints()
      }

      Button {
        text: "Add manually"
        bordered: true
        foreground: root.foreground
        onClicked: {
          root.editServerInput = ""
          root.editingServer = true
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WordWrap
      visible: root.service && root.service.discoveryNote !== ""
      text: root.service ? root.service.discoveryNote : ""
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // Discovery proposes; it never adopts (spec section 42).
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: root._discovered.length > 0

      PanelSectionHeader { text: "DETECTED"; foreground: root.foreground }

      Repeater {
        model: root._discovered

        Row {
          id: candidateRow
          required property var modelData
          width: root.width
          spacing: Style.space(6)

          Column {
            width: parent.width - Style.space(80)
            spacing: 0

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: candidateRow.modelData.name
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideMiddle
              text: candidateRow.modelData.baseUrl
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            text: "Add"
            bordered: true
            foreground: root.foreground
            onClicked: root.service.addEndpoint(candidateRow.modelData)
          }
        }
      }
    }

    // Manual add, reusing the address field and normalisation that
    // onboarding uses.
    Column {
      width: parent.width
      visible: root.editingServer
      spacing: Style.space(6)

      TextField {
        id: serverField
        width: parent.width
        placeholderText: "http://tower.local"
        text: root.editServerInput
        foreground: root.foreground
        onTextChanged: {
          var cleaned = root.cleanInput(text)
          if (cleaned !== text) text = cleaned
          root.editServerInput = cleaned
        }
        onAccepted: root.saveServer()
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: "Add"
          bordered: true
          foreground: root.foreground
          enabled: root.editServerInput.trim() !== ""
          onClicked: root.saveServer()
        }

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.foreground
          onClicked: root.editingServer = false
        }
      }
    }
  }

  // ------------------------------------------------------- AUTHENTICATION
  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader { text: "AUTHENTICATION"; foreground: root.foreground }

    Row {
      visible: !root.editingKey
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.secretStore && root.secretStore.present ? "API key: Configured ✓" : "API key: Not set"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        text: "Replace key"
        bordered: true
        foreground: root.foreground
        onClicked: {
          root.editKeyInput = ""
          testWidget.testState = "idle"
          root.editingKey = true
        }
      }

      Button {
        text: "Test permissions"
        bordered: true
        foreground: root.foreground
        enabled: root.secretStore && root.secretStore.present && root.configStore && root.configStore.graphqlUrl !== ""
        onClicked: {
          testWidget.testState = "idle"
          root.secretStore.fetchForUse(function(key) {
            testWidget.run(root.configStore.graphqlUrl, key)
          })
        }
      }
    }

    Column {
      width: parent.width
      visible: root.editingKey
      spacing: Style.space(6)

      TextField {
        id: keyField
        width: parent.width
        password: true
        text: root.editKeyInput
        foreground: root.foreground
        onTextChanged: {
          var cleaned = root.cleanInput(text)
          if (cleaned !== text) text = cleaned
          root.editKeyInput = cleaned
        }
        onAccepted: testWidget.testState === "success" ? root.saveKey() : root.testKey()
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: "Test connection"
          bordered: true
          foreground: root.foreground
          enabled: root.editKeyInput.trim() !== "" && testWidget.testState !== "testing"
          onClicked: root.testKey()
        }

        Button {
          text: "Save"
          bordered: true
          foreground: root.foreground
          enabled: testWidget.testState === "success"
          onClicked: root.saveKey()
        }

        Button {
          text: "Cancel"
          bordered: true
          foreground: root.foreground
          onClicked: root.editingKey = false
        }
      }
    }

    ConnectionTest {
      id: testWidget
      width: parent.width
    }
  }

  // ------------------------------------------------------------ BEHAVIOR
  Column {
    width: parent.width
    spacing: Style.space(4)
    PanelSectionHeader { text: "BEHAVIOR"; foreground: root.foreground }
    Text {
      textFormat: Text.PlainText
      text: "Coming in Milestone 3"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  // --------------------------------------------------------------- ABOUT
  Column {
    width: parent.width
    spacing: Style.space(4)
    PanelSectionHeader { text: "ABOUT"; foreground: root.foreground }
    Text {
      textFormat: Text.PlainText
      text: "Unraid Companion 0.1.0"
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }
}
