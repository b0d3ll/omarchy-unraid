import QtQuick
import qs.Commons

// Small filled circle communicating the plugin's internal health state
// (spec section 5). Omarchy's palette only defines foreground/accent/
// urgent/muted (see Commons/Color.qml) — there is no theme-independent
// green/amber/red, so severity is expressed with that vocabulary instead
// of inventing a separate color scheme.
Rectangle {
  id: root

  property string healthState: "HEALTHY" // HEALTHY, NOTICE, WARNING, CRITICAL, AUTH_ERROR, OFFLINE, STALE, CONNECTING
  property real size: Style.space(8)

  function colorForState(s) {
    switch (s) {
      case "CRITICAL":
      case "AUTH_ERROR":
        return Color.urgent
      case "WARNING":
        return Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.75)
      case "NOTICE":
        return Color.accent
      case "OFFLINE":
      case "STALE":
      case "CONNECTING":
        return Color.muted
      default:
        return Color.accent
    }
  }

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size
  radius: size / 2
  color: colorForState(healthState)

  Behavior on color { ColorAnimation { duration: 160 } }

  SequentialAnimation on opacity {
    running: root.healthState === "CONNECTING" || root.healthState === "STALE"
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
    NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
  }
}
