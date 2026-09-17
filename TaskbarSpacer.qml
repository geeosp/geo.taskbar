import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Bar half of the taskbar: a placeholder that reserves the dock's footprint in
// the bar and owns all pointer input (hover, click, tooltips, previews, jump
// list). It draws no icons itself — TaskbarOverlay.qml renders those in a layer
// that can overflow the bar.
BarWidget {
  id: root

  moduleName: "geovane.taskbar"

  // ensureService() can return null while the service singleton is still
  // mounting; retrying re-evaluates `svc` until it lands.
  Timer {
    id: serviceRetry
    property int tries: 0
    interval: 200
    repeat: true
    running: root.svc === null
    onTriggered: serviceRetry.tries++
  }

  readonly property var svc: {
    var _ = serviceRetry.tries
    if (!bar || !bar.shell) return null
    // The capability-scoped shell exposes serviceFor(); ensureService() is
    // host-only. Fall back to it in case the surface changes.
    if (typeof bar.shell.serviceFor === "function") {
      var found = bar.shell.serviceFor(moduleName)
      if (found) return found
    }
    if (typeof bar.shell.ensureService === "function") return bar.shell.ensureService(moduleName)
    return null
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var s = String(value).toLowerCase()
    if (s === "true" || s === "1" || s === "yes" || s === "on") return true
    if (s === "false" || s === "0" || s === "no" || s === "off") return false
    return fallback
  }

  readonly property var cfg: ({
    previewDelay: Number(setting("previewDelay", 350)),
    iconMinSize: root.curMin,
    iconMaxSize: root.curMax,
    magnify: root.curMagnify,
    magnifyRange: root.curRange
  })

  onCfgChanged: if (root.svc) root.svc.applyConfig(root.cfg)
  onSvcChanged: {
    if (!root.svc) return
    root.svc.applyConfig(root.cfg)
    root.publishGeometry()
  }

  // Settings live in this widget's inline shell.json entry.
  readonly property int curMin: Math.max(6, Math.min(64,
    Math.round(Number(setting("iconMinSize", setting("iconSize", 16))))))
  readonly property int curMax: Math.max(6, Math.min(96,
    Math.round(Number(setting("iconMaxSize", Math.round(root.curMin * 1.75))))))
  readonly property int curRange: Math.max(1, Math.min(8, Math.round(Number(setting("magnifyRange", 3)))))
  readonly property bool curMagnify: root.boolSetting("magnify", true)

  // Persist the full inline settings object (updateEntryInline replaces the
  // entry) and let the shell reload propagate it back through `setting()`.
  function persistSettings(overrides) {
    var next = {
      previewDelay: Math.round(Number(setting("previewDelay", 350))),
      iconMinSize: root.curMin,
      iconMaxSize: root.curMax,
      magnify: root.curMagnify,
      magnifyRange: root.curRange
    }
    for (var k in overrides) next[k] = overrides[k]
    if (next.iconMaxSize < next.iconMinSize) next.iconMaxSize = next.iconMinSize
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  readonly property var groups: root.svc ? root.svc.groups : []
  readonly property int previewDelay: root.svc ? root.svc.previewDelay : Number(setting("previewDelay", 350))

  // Slots are spaced for the resting icon size; the overlay reflows icons
  // outward from whichever one is magnified, so spacing follows the live size.
  // The magnified icon stays anchored at its own slot, so clicks still land on
  // the app under the pointer.
  readonly property real iconSize: root.svc ? root.svc.iconExtent : 16
  readonly property real maxIconSize: root.svc ? root.svc.maxIconExtent : root.iconSize
  readonly property real slotW: Math.max(root.barSize, root.iconSize + Style.space(4))
  readonly property real slotH: root.barSize

  readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property var barContent: root.barWindow ? root.barWindow.contentItem : null
  readonly property var windowScreen: root.barWindow ? root.barWindow.screen : null
  readonly property string screenName: root.windowScreen ? root.windowScreen.name : ""

  // Reactive transform: makes the geometry binding below track bar/section
  // layout changes, not just the first evaluation.
  TransformWatcher {
    id: watcher
    a: root.barContent
    b: root
  }

  // Screen-space geometry published to the service for the overlay to place
  // icons against.
  readonly property var geo: {
    var _a = watcher.transform
    var _b = root.groups.length
    if (!root.barWindow || !root.barContent) return null
    var p = root.mapToItem(root.barContent, 0, 0)
    var screenW = root.windowScreen ? root.windowScreen.width : 0
    var screenH = root.windowScreen ? root.windowScreen.height : 0
    var barH = root.barWindow.height
    var barTopY = (root.bar && root.bar.position === "top") ? p.y : (screenH - barH) + p.y
    return {
      valid: true,
      screenName: root.screenName,
      screenW: screenW,
      screenH: screenH,
      barTopY: barTopY,
      barH: barH,
      position: root.bar ? root.bar.position : "top",
      rowStartX: p.x,
      step: root.slotW + Style.space(1),
      slotSize: root.slotW
    }
  }

  onGeoChanged: root.publishGeometry()
  function publishGeometry() {
    if (root.svc && root.geo) root.svc.setGeometry(root.screenName, root.geo)
  }

  implicitWidth: slotRow.implicitWidth
  implicitHeight: slotRow.implicitHeight
  visible: root.groups.length > 0

  Component.onCompleted: root.publishGeometry()

  function appName(group) { return root.svc ? root.svc.appName(group) : "" }

  function onSlotClicked(group) {
    root.closeMenu()
    if (!root.svc || !group) return
    if (group.windows.length === 0) {
      root.svc.launchApp(group.entry, group.pinId)
      return
    }
    root.svc.cycleGroup(group)
  }

  // ---------------------------------------------------------- preview state

  property string hoverKey: ""
  property string pendingKey: ""
  property Item pendingAnchor: null
  property string previewKey: ""
  property Item previewAnchor: null
  property bool stickyPreview: false

  readonly property var previewGroup: (root.previewKey && root.svc) ? root.svc.groupByKey(root.previewKey) : null
  readonly property int previewCount: root.previewGroup ? root.previewGroup.windows.length : 0
  readonly property int previewColumns: Math.max(1, Math.min(4, root.previewCount))
  // 2x the previous preview size (the popup window is twice as large).
  readonly property real tileWidth: Style.space(336)
  readonly property real tileHeight: Style.space(208)
  readonly property real previewContentWidth: {
    var cols = root.previewColumns
    return cols * root.tileWidth + (cols - 1) * Style.space(6)
  }
  readonly property real previewContentHeight: {
    var rows = Math.max(1, Math.ceil(root.previewCount / root.previewColumns))
    var cell = root.tileHeight + Style.space(22)
    return rows * cell + (rows - 1) * Style.space(6)
  }

  function previewSuppressed() {
    return root.menuKey !== "" || root.settingsOpen
  }

  function schedulePreview(chip, group) {
    if (!group || !group.running || root.previewSuppressed()) return
    root.pendingKey = group.key
    root.pendingAnchor = chip
    previewTimer.restart()
  }

  // Live pointer tracking for the wave. A per-slot HoverHandler reports the
  // cursor position continuously; the count guards against enter/exit ordering
  // when crossing slots.
  property int pointerHoverCount: 0

  function pointerEntered() {
    root.pointerHoverCount++
  }

  function pointerLeft() {
    root.pointerHoverCount = Math.max(0, root.pointerHoverCount - 1)
    if (root.pointerHoverCount === 0 && root.svc) root.svc.clearPointer(root.screenName)
  }

  function pointerMoved(slotItem, localX) {
    if (!root.svc || !root.geo) return
    root.svc.setPointer(root.geo.rowStartX + slotItem.x + localX, root.screenName)
  }

  // Anchor item for a group index (the slot reserves one child per group).
  function slotAt(index) {
    if (index < 0 || index >= slotRow.children.length) return root
    return slotRow.children[index]
  }

  // UI requests raised by the overlay's input surface.
  Connections {
    target: root.svc
    function onActionRequested(kind, index) {
      if (!root.svc) return
      if (kind === "previewEnd") {
        hideTimer.restart()
        return
      }
      if (kind === "settings") {
        root.openSettings(root)
        return
      }
      var groups = root.svc.groups
      if (index < 0 || index >= groups.length) return
      var group = groups[index]
      if (kind === "menu") root.openMenu(root.slotAt(index), group)
      else if (kind === "preview") root.schedulePreview(root.slotAt(index), group)
    }
  }

  function slotHovered(chip, index, group) {
    if (!group) return
    root.pointerEntered()
    root.pointerMoved(chip, chip.width / 2)
    root.hoverKey = group.key
    if (root.previewKey !== group.key) {
      if (root.previewKey !== "") root.closePreview()
      root.schedulePreview(chip, group)
    } else {
      hideTimer.stop()
    }
  }

  function slotExited(index, group) {
    root.pointerLeft()
    if (group && root.previewKey === group.key && !root.stickyPreview) hideTimer.restart()
  }

  function closePreview() {
    previewTimer.stop()
    hideTimer.stop()
    root.pendingKey = ""
    root.pendingAnchor = null
    root.previewKey = ""
    root.previewAnchor = null
    root.hoverKey = ""
    root.stickyPreview = false
  }

  Timer {
    id: previewTimer
    interval: root.previewDelay
    onTriggered: {
      root.previewAnchor = root.pendingAnchor
      root.previewKey = root.pendingKey
      root.pendingAnchor = null
      root.pendingKey = ""
    }
  }

  Timer {
    id: hideTimer
    interval: 160
    // Stay open while the pointer is anywhere on the taskbar (bar strip or the
    // magnified-icon area above it) or over the popup itself.
    onTriggered: {
      if (previewCard.containsMouse) return
      if (root.svc && root.svc.overlayHovered) return
      root.closePreview()
    }
  }

  // ------------------------------------------------------------ jump list

  property string menuKey: ""
  property Item menuAnchor: null
  property var menuItems: []

  property bool settingsOpen: false
  property Item settingsAnchor: root

  function openMenu(chip, group) {
    root.closeSettings()
    root.closePreview()
    if (!root.svc || !group) return
    root.menuKey = group.key
    root.menuAnchor = chip
    var items = root.svc.buildMenuItems(group)
    // Defer: the settings popup takes its own focus grab, and opening it in the
    // same tick the menu releases its grab makes the compositor clear it at
    // once, so it would flash and vanish.
    items.push({
      label: "Taskbar settings…",
      action: function() { Qt.callLater(function() { root.openSettings(chip) }) }
    })
    root.menuItems = items
  }

  function openSettings(anchor) {
    root.closeMenu()
    root.closePreview()
    root.settingsAnchor = anchor || root
    root.settingsOpen = true
  }

  function closeSettings() {
    root.settingsOpen = false
  }

  // Right-click on empty taskbar space opens settings directly.
  MouseArea {
    id: emptySpaceArea
    anchors.fill: parent
    acceptedButtons: Qt.RightButton | Qt.LeftButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.openSettings(root)
    }
  }

  // Root-level position tracking: receives hover across the whole row (icons
  // included), so the wave follows the cursor even if the per-slot handler is
  // filtered by the button's own mouse area.
  HoverHandler {
    id: rowPointer
    onPointChanged: {
      if (root.svc && root.geo)
        root.svc.setPointer(root.geo.rowStartX + rowPointer.point.position.x, root.screenName)
    }
  }

  function closeMenu() {
    root.menuKey = ""
    root.menuAnchor = null
    root.menuItems = []
  }

  // ------------------------------------------------------------------- slots

  Row {
    id: slotRow
    spacing: Style.space(1)

    Repeater {
      model: root.groups

      WidgetButton {
        id: slot

        required property var modelData
        required property int index
        readonly property var group: modelData

        bar: root.bar
        text: ""
        labelVisible: false
        hasVisualContent: true
        keepSpace: true
        fixedWidth: root.slotW
        fixedHeight: root.slotH
        tooltipText: root.group ? (root.group.windows.length === 0 ? root.appName(root.group) : "") : ""

        onTooltipHoveredChanged: {
          if (tooltipHovered) root.slotHovered(slot, slot.index, slot.group)
          else root.slotExited(slot.index, slot.group)
        }
        onPressed: function(button) {
          if (button === Qt.RightButton) root.openMenu(slot, slot.group)
          else if (button === Qt.LeftButton) root.onSlotClicked(slot.group)
        }

        // Position refinement only; enter/exit lifecycle comes from the button's
        // proven hover signal so it can't desync.
        HoverHandler {
          id: slotPointer
          onPointChanged: root.pointerMoved(slot, slotPointer.point.position.x)
        }

        Component.onDestruction: {
          if (root.menuAnchor === slot) root.closeMenu()
          if (root.previewAnchor === slot) root.closePreview()
        }
      }
    }

    // Empty taskbar space: right-click here opens settings.
    Item {
      width: Style.space(8)
      height: root.barSize
    }
  }

  QtObject {
    id: previewOwner
    function close() { root.closePreview() }
  }

  // Invisible anchor placed at the top of the tallest the icons can grow. The
  // preview hangs from it (above the bar), so it never shares space with the
  // magnified icons.
  Item {
    id: previewAnchorProxy
    width: root.previewAnchor ? root.previewAnchor.width : 1
    height: 1
    x: root.previewAnchor ? root.previewAnchor.x : 0
    y: root.height - Style.space(5) - root.maxIconSize
  }

  PopupCard {
    id: previewCard

    anchorItem: (root.bar && root.bar.position === "bottom")
      ? previewAnchorProxy : (root.previewAnchor || root)
    bar: root.bar
    owner: previewOwner
    triggerMode: root.stickyPreview ? "click" : "hover"
    open: root.previewKey !== "" && root.previewGroup !== null && root.previewGroup.windows.length > 0
      && !root.previewSuppressed()
    contentWidth: previewCard.fittedContentWidth(root.previewContentWidth)
    contentHeight: previewCard.fittedContentHeight(root.previewContentHeight)
    padding: Style.space(8)

    onContainsMouseChanged: {
      if (previewCard.containsMouse) hideTimer.stop()
      else if (root.previewKey !== "" && !root.stickyPreview) hideTimer.restart()
    }

    Grid {
      columns: root.previewColumns
      spacing: Style.space(6)

      Repeater {
        model: root.previewGroup ? root.previewGroup.windows : []

        Item {
          id: tile
          required property var modelData
          width: root.tileWidth
          height: root.tileHeight + Style.space(22)

          Rectangle {
            id: thumb
            width: parent.width
            height: root.tileHeight
            radius: Style.space(4)
            clip: true
            color: Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.08)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(28)
              source: root.svc ? root.svc.iconFor(null, tile.modelData) : ""
              fillMode: Image.PreserveAspectFit
              opacity: thumbView.hasContent ? 0 : 0.6
            }

            ScreencopyView {
              id: thumbView
              anchors.fill: parent
              captureSource: tile.modelData ? tile.modelData.wayland : null
              live: previewCard.open
              paintCursor: false
            }

            Rectangle {
              anchors.fill: parent
              radius: thumb.radius
              color: "transparent"
              border.width: tileHover.hovered ? Math.max(1, Style.space(1)) : 0
              border.color: tileHover.hovered ? Color.accent : "transparent"
              Behavior on border.color { ColorAnimation { duration: 80 } }
            }

            Rectangle {
              id: closeButton
              width: Style.space(16)
              height: Style.space(16)
              radius: width / 2
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.topMargin: Style.space(3)
              anchors.rightMargin: Style.space(3)
              color: closeHover.hovered
                ? Color.urgent
                : Util.alpha(root.bar ? root.bar.background : Color.background, 0.75)
              opacity: tileHover.hovered ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 100 } }
              Behavior on color { ColorAnimation { duration: 100 } }

              Text {
                anchors.centerIn: parent
                text: "\u00d7"
                color: closeHover.hovered
                  ? (root.bar ? root.bar.background : Color.background)
                  : (root.bar ? root.bar.barForeground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              HoverHandler { id: closeHover }
              TapHandler { onTapped: if (root.svc) root.svc.closeWindow(tile.modelData) }
            }

            HoverHandler { id: tileHover }
            TapHandler {
              onTapped: {
                if (closeHover.hovered) return
                if (root.svc) root.svc.activateWindow(tile.modelData)
                root.closePreview()
              }
            }
          }

          Text {
            anchors.top: thumb.bottom
            anchors.topMargin: Style.space(3)
            width: parent.width
            text: root.svc ? root.svc.windowTitle(tile.modelData) : ""
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  QtObject {
    id: menuOwner
    function close() { root.closeMenu() }
  }

  PopupCard {
    id: menuCard

    anchorItem: root.menuAnchor || root
    bar: root.bar
    owner: menuOwner
    triggerMode: "click"
    open: root.menuKey !== "" && root.menuItems.length > 0
    contentWidth: menuCard.fittedContentWidth(Style.space(240))
    contentHeight: menuCard.fittedContentHeight(menuColumn.implicitHeight, Style.space(420))
    padding: Style.space(6)

    Column {
      id: menuColumn
      width: parent.width
      spacing: Style.space(2)

      Repeater {
        model: root.menuItems

        Rectangle {
          id: menuRow
          required property var modelData
          width: menuColumn.width
          height: Style.space(28)
          radius: Style.space(4)
          color: rowHover.hovered
            ? Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.12)
            : "transparent"
          Behavior on color { ColorAnimation { duration: 100 } }

          HoverHandler { id: rowHover }

          TapHandler {
            onTapped: {
              var action = menuRow.modelData.action
              root.closeMenu()
              if (action) action()
            }
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: menuRow.modelData.label
            textFormat: Text.PlainText
            color: menuRow.modelData.destructive
              ? Color.urgent
              : (root.bar ? root.bar.barForeground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  QtObject {
    id: settingsOwner
    function close() { root.closeSettings() }
  }

  // Settings window: opened by right-clicking an icon (via its jump list) or
  // the empty taskbar space.
  PopupCard {
    id: settingsCard

    anchorItem: root.settingsAnchor || root
    bar: root.bar
    owner: settingsOwner
    triggerMode: "click"
    open: root.settingsOpen
    contentWidth: settingsCard.fittedContentWidth(Style.space(320))
    contentHeight: settingsCard.fittedContentHeight(settingsColumn.implicitHeight, Style.space(520))
    padding: Style.space(14)

    Column {
      id: settingsColumn
      width: parent.width
      spacing: Style.space(12)

      Text {
        text: "Taskbar settings"
        textFormat: Text.PlainText
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      NumberField {
        width: parent.width
        label: "Smallest icon size (px)"
        from: 8
        to: 64
        value: root.curMin
        foreground: root.bar ? root.bar.barForeground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onModified: function(value) { root.persistSettings({ iconMinSize: value }) }
      }

      NumberField {
        width: parent.width
        label: "Biggest icon size (px)"
        from: 8
        to: 96
        value: root.curMax
        foreground: root.bar ? root.bar.barForeground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onModified: function(value) { root.persistSettings({ iconMaxSize: value }) }
      }

      NumberField {
        width: parent.width
        label: "Wave falloff (neighbours)"
        from: 1
        to: 8
        value: root.curRange
        foreground: root.bar ? root.bar.barForeground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onModified: function(value) { root.persistSettings({ magnifyRange: value }) }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: parent.width - magnifySwitch.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          text: "Magnify on hover"
          textFormat: Text.PlainText
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        ToggleSwitch {
          id: magnifySwitch
          anchors.verticalCenter: parent.verticalCenter
          checked: root.curMagnify
          foreground: root.bar ? root.bar.barForeground : Color.foreground
          onToggled: root.persistSettings({ magnify: !root.curMagnify })
        }
      }

      Text {
        width: parent.width
        text: "The pointer grows an icon to the biggest size and eases neighbours down to the smallest."
        wrapMode: Text.WordWrap
        color: Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.65)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

}
