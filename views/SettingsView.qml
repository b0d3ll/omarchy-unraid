pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Ui

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

  function normalizeAddress(input) {
    var trimmed = (input || "").trim().replace(/\/+$/, "")
    if (trimmed === "") return { baseUrl: "", graphqlUrl: "" }
    if (!/^https?:\/\//i.test(trimmed)) trimmed = "http://" + trimmed
    var graphqlUrl = /\/graphql$/i.test(trimmed) ? trimmed : trimmed + "/graphql"
    return { baseUrl: trimmed, graphqlUrl: graphqlUrl }
  }

  function saveServer() {
    if (root.editServerInput.trim() === "") return
    var normalized = root.normalizeAddress(root.editServerInput)
    root.configStore.save({ serverUrl: normalized.baseUrl, graphqlUrl: normalized.graphqlUrl })
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

    Grid {
      columns: 2
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(4)
      visible: root.configStore && root.configStore.hostname !== ""

      Text { textFormat: Text.PlainText; text: "Name"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: root.configStore ? root.configStore.hostname : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: "Unraid"; color: Qt.darker(root.foreground, 1.4); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: root.configStore ? root.configStore.unraidVersion : ""; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
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
  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader { text: "CONNECTIONS"; foreground: root.foreground }

    Row {
      visible: !root.editingServer
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.configStore && root.configStore.serverUrl !== "" ? root.configStore.serverUrl : "Not set"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        text: "Edit"
        bordered: true
        foreground: root.foreground
        onClicked: {
          root.editServerInput = root.configStore ? root.configStore.serverUrl : ""
          root.editingServer = true
        }
      }
    }

    Column {
      width: parent.width
      visible: root.editingServer
      spacing: Style.space(6)

      TextField {
        id: serverField
        width: parent.width
        text: root.editServerInput
        foreground: root.foreground
        onTextChanged: root.editServerInput = text
        onAccepted: root.saveServer()
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: "Save"
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
        onTextChanged: root.editKeyInput = text
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
