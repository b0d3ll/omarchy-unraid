import QtQuick
import qs.Commons
import qs.Ui

// Header pill showing the active transport — LAN / TAILSCALE / VPN / CUSTOM
// / OFFLINE (spec sections 8, 30). Hover/click reveals endpoint details via
// the tooltipText the caller supplies.
BorderSurface {
  id: root

  property string connectionType: "OFFLINE"
  property color foreground: Color.foreground
  property string tooltipText: ""

  implicitWidth: label.implicitWidth + Style.space(16)
  implicitHeight: label.implicitHeight + Style.space(6)
  radius: height / 2
  color: "transparent"
  borderSpec: Border.controlSpec(mouse.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.connectionType
    color: root.connectionType === "OFFLINE" ? Color.muted : root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 0.6
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
  }
}
