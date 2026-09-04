import QtQuick
import qs.Commons
import qs.Ui

// Transient bottom-of-panel confirmation ("Jellyfin restarted") — spec
// section 18, 45. Call show(text) to display it for a few seconds.
BorderSurface {
  id: root

  property string message: ""

  function show(text) {
    message = text
    hideTimer.restart()
    opacity = 1
  }

  anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
  implicitWidth: label.implicitWidth + Style.space(24)
  implicitHeight: label.implicitHeight + Style.space(16)
  radius: Style.cornerRadius
  color: Color.popups.background
  borderSpec: Border.controlSpec("normal", Color.foreground, Color.accent)
  opacity: 0
  visible: opacity > 0

  Behavior on opacity { NumberAnimation { duration: 160 } }

  Timer {
    id: hideTimer
    interval: 2500
    onTriggered: root.opacity = 0
  }

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.message
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
