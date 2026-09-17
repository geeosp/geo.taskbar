import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Visual half of the taskbar. One click-through layer surface per monitor
// renders the app icons, running indicators, and the magnification wave.
//
// The surface is only as tall as the icons ever get (plus a small margin), not
// a full-screen overlay: that keeps the composited area small so the wave stays
// smooth, and it still lets icons grow past the bar edge.
//
// The wave mirrors macOSMagnifyingDock (wdg.dock): slots stay fixed and never
// reflow; the pointer drives a raised-cosine falloff, and the extra width of
// each magnified icon is turned into transform-only horizontal offsets spread
// outward from the row centre. Both scale and offset follow the pointer with a
// SmoothedAnimation, so motion is continuous rather than stepped.
Item {
  id: root

  // Injected by the shell host (panel kind).
  property var service: null
  property var shell: null
  property var manifest: null

  readonly property string moduleName: "geo.taskbar"

  property var svc: null

  function resolveService() {
    if (root.service) {
      root.svc = root.service
      return
    }
    if (root.shell && typeof root.shell.ensureService === "function")
      root.svc = root.shell.ensureService(root.moduleName)
  }

  onServiceChanged: root.resolveService()
  onShellChanged: root.resolveService()
  Component.onCompleted: root.resolveService()

  Timer {
    interval: 400
    repeat: true
    running: root.svc === null
    onTriggered: root.resolveService()
  }

  function geoFor(screen) {
    return root.svc ? root.svc.geometryFor(screen.name) : null
  }

  function groups() {
    return root.svc ? root.svc.groups : []
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: panel

        required property var modelData
        readonly property var geo: root.geoFor(modelData)
        readonly property bool bottom: panel.geo ? panel.geo.position === "bottom" : true
        readonly property bool horizontal: panel.geo
          ? (panel.geo.position === "top" || panel.geo.position === "bottom") : false

        // Tall enough to contain the peak icon before it starts to overflow.
        readonly property real stripH: root.svc
          ? Math.max(root.svc.maxIconExtent, panel.geo ? panel.geo.barH : 0) + Style.space(10)
          : 80
        readonly property real stripTop: panel.bottom && panel.geo
          ? (panel.geo.screenH - panel.stripH) : 0
        readonly property real iconSize: root.svc ? root.svc.iconExtent : 16
        readonly property real baselineY: panel.geo
          ? (panel.geo.barTopY + panel.geo.barH - Style.space(5) - panel.stripTop) : 0
        readonly property real indicatorY: panel.geo
          ? (panel.geo.barTopY + panel.geo.barH - Style.space(2) - panel.stripTop) : 0

        // Fast, velocity-preserving follow, as in the reference dock.
        readonly property int followDuration: 90
        readonly property int followEasingTime: 28

        screen: modelData
        visible: panel.geo !== null && panel.horizontal
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "omarchy-taskbar-overlay"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: !panel.bottom
          bottom: panel.bottom
          left: true
          right: true
        }
        implicitHeight: panel.stripH

        // Input region: exactly the taskbar row, across the full strip height so
        // the magnified-icon area above the bar is hoverable too. Every other
        // bar widget stays reachable outside this horizontal span.
        readonly property real hoverX: panel.geo ? (panel.geo.rowStartX - Style.space(4)) : 0
        readonly property real hoverW: (panel.geo && root.groups().length > 0)
          ? (root.groups().length * panel.geo.step - Style.space(1) + Style.space(8)) : 0
        mask: Region {
          x: Math.round(panel.hoverX)
          y: 0
          width: Math.round(panel.hoverW)
          height: Math.round(panel.stripH)
        }

        property int hoverIndex: -1

        readonly property bool waveHere: root.svc && root.svc.magnifyEnabled
          && root.svc.pointerActive && root.svc.pointerScreen === modelData.name

        function baseCenter(i) {
          return panel.geo
            ? (panel.geo.rowStartX + i * panel.geo.step + panel.geo.slotSize / 2) : 0
        }

        // Nearest icon to a window-local x, or -1 if the pointer is between
        // icons / in the trailing empty space.
        function indexAtX(x) {
          var n = root.groups().length
          if (!panel.geo || n === 0) return -1
          var best = -1
          var bestD = Infinity
          for (var i = 0; i < n; i++) {
            // Base centres, matching the magnification peak: the icon that
            // grows under the pointer is the one a click/preview targets.
            var d = Math.abs(panel.baseCenter(i) - x)
            if (d < bestD) {
              bestD = d
              best = i
            }
          }
          var scaleF = (best >= 0 && panel.layout.scales[best] !== undefined) ? panel.layout.scales[best] : 1
          var halfW = panel.iconSize * scaleF / 2 + Style.space(3)
          return bestD <= halfW ? best : -1
        }

        function updateHover(x) {
          if (!root.svc) return
          root.svc.setOverlayHovered(true)
          root.svc.setPointer(x, modelData.name)
          var idx = panel.indexAtX(x)
          if (idx !== panel.hoverIndex) {
            panel.hoverIndex = idx
            if (idx >= 0) root.svc.requestAction("preview", idx)
            else root.svc.requestAction("previewEnd", -1)
          }
        }

        function endHover() {
          if (!root.svc) return
          root.svc.setOverlayHovered(false)
          root.svc.clearPointer(modelData.name)
          if (panel.hoverIndex !== -1) {
            panel.hoverIndex = -1
            root.svc.requestAction("previewEnd", -1)
          }
        }

        function handleClick(x, button) {
          if (!root.svc) return
          var idx = panel.indexAtX(x)
          if (button === Qt.RightButton) {
            if (idx >= 0) root.svc.requestAction("menu", idx)
            else root.svc.requestAction("settings", -1)
            return
          }
          if (idx < 0) return
          var g = root.groups()[idx]
          if (!g) return
          if (button === Qt.LeftButton) {
            if (g.windows.length === 0) root.svc.launchApp(g.entry, g.pinId)
            else root.svc.cycleGroup(g)
          } else if (button === Qt.MiddleButton && g.windows.length > 0) {
            root.svc.closeWindow(g.windows[0])
          }
        }

        // Raised-cosine bell: continuous slope at both ends, wider shoulder
        // than smoothstep so neighbours join the wave smoothly.
        function scaleFromDistance(dist) {
          var radius = Math.max(1, root.svc.magnifyRange) * panel.geo.step
          if (dist >= radius) return 1
          var norm = dist / radius
          var cosine = Math.cos(norm * Math.PI / 2)
          return 1 + (root.svc.magnifyScale - 1) * cosine * cosine
        }

        // Transform-only offsets for a centred row of fixed slots: each
        // magnified icon's extra width is spread half to either side so the
        // wave stays centred and neighbours never collide.
        readonly property var layout: {
          var n = root.groups().length
          var result = { scales: [], offsets: [] }
          if (n === 0 || !panel.geo) return result
          var active = panel.waveHere
          var extras = []
          var total = 0
          for (var i = 0; i < n; i++) {
            var s = active ? panel.scaleFromDistance(Math.abs(panel.baseCenter(i) - root.svc.pointerX)) : 1
            result.scales.push(s)
            var extra = Math.max(0, (s - 1) * panel.iconSize * 0.82)
            extras.push(extra)
            total += extra
          }
          var cursor = -total / 2
          for (var j = 0; j < n; j++) {
            result.offsets.push(cursor + extras[j] / 2)
            cursor += extras[j]
          }
          return result
        }

        Repeater {
          model: root.groups()

          Item {
            id: tile
            required property var modelData
            required property int index
            readonly property var group: modelData
            readonly property real scaleFactor: (panel.layout.scales[index] !== undefined)
              ? panel.layout.scales[index] : 1
            readonly property real centerX: panel.baseCenter(index)
              + ((panel.layout.offsets[index] !== undefined) ? panel.layout.offsets[index] : 0)
            readonly property bool active: root.svc ? root.svc.isGroupActive(group) : false
            readonly property bool allMinimized: root.svc ? root.svc.isGroupAllMinimized(group) : false

            Rectangle {
              visible: tile.active
              x: Math.round(tile.centerX - panel.iconSize / 2 - Style.space(4))
              y: Math.round(panel.baselineY - panel.iconSize - Style.space(3))
              width: Math.round(panel.iconSize + Style.space(8))
              height: Math.round(panel.iconSize + Style.space(6))
              radius: Math.min(Style.cornerRadius, Style.space(4))
              color: Util.alpha(Color.accent, 0.20)
              Behavior on x {
                SmoothedAnimation {
                  velocity: -1
                  duration: panel.followDuration
                  maximumEasingTime: panel.followEasingTime
                }
              }
            }

            Image {
              id: icon
              width: panel.iconSize
              height: panel.iconSize
              x: Math.round(tile.centerX - width / 2)
              y: Math.round(panel.baselineY - height)
              transformOrigin: Item.Bottom
              scale: tile.scaleFactor
              source: root.svc ? root.svc.iconFor(tile.group.entry,
                tile.group.windows.length > 0 ? tile.group.windows[0] : null) : ""
              sourceSize.width: Math.round(panel.iconSize * 3 * Screen.devicePixelRatio)
              sourceSize.height: Math.round(panel.iconSize * 3 * Screen.devicePixelRatio)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true

              Behavior on x {
                SmoothedAnimation {
                  velocity: -1
                  duration: panel.followDuration
                  maximumEasingTime: panel.followEasingTime
                }
              }
              Behavior on scale {
                SmoothedAnimation {
                  velocity: -1
                  duration: panel.followDuration
                  maximumEasingTime: panel.followEasingTime
                }
              }
            }

            Row {
              id: indicator
              visible: tile.group.windows.length > 0
              x: Math.round(tile.centerX - width / 2)
              y: Math.round(panel.indicatorY)
              spacing: Style.space(1)

              Behavior on x {
                SmoothedAnimation {
                  velocity: -1
                  duration: panel.followDuration
                  maximumEasingTime: panel.followEasingTime
                }
              }

              Repeater {
                model: Math.max(1, Math.min(4, tile.group.windows.length))

                Rectangle {
                  width: Style.space(4)
                  height: Math.max(2, Style.space(1))
                  radius: height / 2
                  color: tile.allMinimized
                    ? Util.alpha(Color.foreground, 0.40)
                    : (tile.active ? Color.accent : Util.alpha(Color.accent, 0.65))
                  Behavior on color { ColorAnimation { duration: 100 } }
                }
              }
            }
          }
        }

        // Input over the taskbar row (masked above). Local x == screen x.
        MouseArea {
          id: inputArea
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
          onEntered: panel.updateHover(inputArea.mouseX)
          onPositionChanged: function(mouse) { panel.updateHover(mouse.x) }
          onExited: panel.endHover()
          onClicked: function(mouse) { panel.handleClick(mouse.x, mouse.button) }
        }
      }
    }
  }
}
