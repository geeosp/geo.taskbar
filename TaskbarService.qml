import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

import "TaskbarModel.js" as Model

// Shared, headless state for the Windows 11-style taskbar.
//
// The bar widget (TaskbarSpacer.qml) is the input surface and geometry source;
// the overlay panel (TaskbarOverlay.qml) renders the icons. Both talk through
// this singleton so the visual layer can overflow the bar's own surface.
Item {
  id: root

  // Injected by the shell host.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null

  readonly property string moduleName: "geovane.taskbar"
  readonly property string shelfWorkspace: "special:taskbar-minimized"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy/taskbar"
  readonly property string pinnedFilePath: stateDir + "/pinned.json"

  // ------------------------------------------------------------- configuration
  //
  // Pushed by the bar widget, which owns the inline shell.json settings.
  // Defaults mirror the manifest.
  property var config: ({
    previewDelay: 350,
    iconMinSize: 16,
    iconMaxSize: 28,
    magnify: true,
    magnifyRange: 3
  })

  function configValue(key, fallback) {
    var v = root.config ? root.config[key] : undefined
    return (v === undefined || v === null) ? fallback : v
  }

  readonly property int previewDelay: Math.max(0, Number(root.configValue("previewDelay", 350)))

  // Icon size bounds. `iconMinSize` is the resting size; `iconMaxSize` is the
  // peak the wave reaches. The wave scale is derived from the ratio so the two
  // numbers are the whole story.
  readonly property int iconMinSize: {
    var v = root.configValue("iconMinSize", root.configValue("iconSize", 16))
    return Math.max(6, Math.min(64, Math.round(Number(v))))
  }
  readonly property int iconMaxSize: {
    var v = root.configValue("iconMaxSize", Math.round(root.iconMinSize * 1.75))
    return Math.max(6, Math.min(96, Math.round(Number(v))))
  }
  // Not capped by the bar height: the overlay can render past the bar, so the
  // configured size is honored. A generous sanity ceiling only.
  readonly property real iconExtent: Math.max(8, Math.min(256, Style.space(root.iconMinSize)))
  // Peak rendered size (resting size × wave scale). The bar reserves this much
  // horizontal room per slot so magnifying never overlaps a neighbour.
  readonly property real maxIconExtent: Math.max(root.iconExtent,
    Math.min(320, Style.space(root.iconMaxSize)))
  readonly property bool magnifyEnabled: {
    var m = root.configValue("magnify", true)
    if (typeof m === "boolean") return m
    var s = String(m).toLowerCase()
    return !(s === "false" || s === "0" || s === "no" || s === "off")
  }
  readonly property real magnifyScale: root.iconMaxSize > root.iconMinSize
    ? Math.max(1, Math.min(3, root.iconMaxSize / root.iconMinSize)) : 1
  readonly property real magnifyRange: Math.max(1, Math.min(8, Number(root.configValue("magnifyRange", 3))))

  function applyConfig(next) {
    if (next) root.config = next
  }

  // ---------------------------------------------------------------- live state

  property var index: null
  property var groups: []
  property string groupSignature: ""
  property var pins: []
  // Live pointer, in screen coordinates, updated on every mouse move over the
  // bar. The wave reads this directly so it follows the cursor in real time
  // instead of stepping slot to slot.
  property real pointerX: -1
  property bool pointerActive: false
  property string pointerScreen: ""
  property var lastWorkspace: ({})
  property bool persistReady: false
  property var geometryByScreen: ({})

  readonly property var windows: Hyprland.toplevels.values
  readonly property string activeAddress: Model.normalizedAddress(Hyprland.activeToplevel)

  // Geometry API, keyed by screen name so multiple bars/overlays coexist.
  function setGeometry(screenName, geo) {
    if (!screenName || !geo) return
    var next = {}
    for (var k in root.geometryByScreen) next[k] = root.geometryByScreen[k]
    next[screenName] = geo
    root.geometryByScreen = next
  }

  function geometryFor(screenName) {
    return (screenName && root.geometryByScreen[screenName]) ? root.geometryByScreen[screenName] : null
  }

  function setPointer(x, screenName) {
    root.pointerActive = true
    root.pointerX = Number(x)
    root.pointerScreen = String(screenName || "")
  }

  function clearPointer(screenName) {
    if (screenName && root.pointerScreen !== String(screenName)) return
    root.pointerActive = false
    root.pointerX = -1
    root.pointerScreen = ""
  }

  // True while the pointer is anywhere over the taskbar (bar strip or the
  // magnified-icon area above it), so the spacer keeps the preview alive.
  property bool overlayHovered: false
  function setOverlayHovered(value) { root.overlayHovered = value === true }

  // Requests from the input surface (the overlay) that need UI owned by the
  // spacer: its preview/menu/settings popups.
  signal actionRequested(string kind, int index)
  function requestAction(kind, index) { root.actionRequested(String(kind), Number(index)) }

  // --------------------------------------------------------------- model glue

  readonly property var ctx: ({
    isRelevant: function(w) { return Model.isRelevant(w, root.shelfWorkspace) },
    groupKey: function(w) { return Model.groupKey(w) },
    pinKeyFor: function(w) {
      var e = Model.entryForWindow(root.index, w)
      return e && e.id ? Model.normKey(e.id) : Model.groupKey(w)
    },
    entryForWindow: function(w) { return Model.entryForWindow(root.index, w) },
    entryForId: function(id) { return Model.entryForId(root.index, id) }
  })

  function rebuildIndex() {
    root.index = Model.buildIndex(DesktopEntries.applications.values)
  }

  function refreshGroups() {
    var next = Model.buildGroups(root.windows, root.pins, root.ctx)
    var sig = Model.groupsSignature(next)
    if (sig === root.groupSignature) return
    root.groupSignature = sig
    root.groups = next
    if (root.activeIndex >= next.length) root.activeIndex = -1
  }

  function scheduleRefresh() {
    refreshTimer.restart()
  }

  function groupByKey(key) {
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groups[i].key === key) return root.groups[i]
    }
    return null
  }

  function appName(group) {
    if (group && group.entry && group.entry.name) return String(group.entry.name)
    var key = group && group.key ? String(group.key) : ""
    var seg = key.split(".").pop()
    if (!seg) return "App"
    return seg.charAt(0).toUpperCase() + seg.slice(1)
  }

  function windowTitle(w) {
    var t = String(w && w.title ? w.title : "").trim()
    if (!t) t = "Window"
    return t.length > 28 ? t.slice(0, 25) + "..." : t
  }

  function iconFor(entry, toplevel) {
    var icon = String(entry && entry.icon ? entry.icon : "").trim()
    if (icon) {
      if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
      if (icon.charAt(0) === "/") return Util.fileUrl(icon)
      var themed = Quickshell.iconPath(icon, true)
      if (themed) return themed
    }
    var key = toplevel ? (Model.windowClass(toplevel) || Model.windowAppId(toplevel)) : ""
    if (key) {
      var direct = Quickshell.iconPath(key, true)
      if (direct) return direct
    }
    return ""
  }

  function isGroupActive(group) {
    if (!group) return false
    for (var i = 0; i < group.windows.length; i++) {
      if (Model.isActive(group.windows[i], root.activeAddress)) return true
    }
    return false
  }

  function isGroupAllMinimized(group) {
    if (!group || group.windows.length === 0) return false
    for (var i = 0; i < group.windows.length; i++) {
      var w = group.windows[i]
      if (!Model.isMinimized(w, root.shelfWorkspace) && !Model.isMinimized(w, "special:minimized")) return false
    }
    return true
  }

  // ----------------------------------------------------------------- actions

  function dispatch(expr) {
    if (expr) Util.execDetached("hyprctl dispatch " + Util.shellQuote(expr))
  }

  function addressExpr(w) {
    return "address:" + Model.normalizedAddress(w)
  }

  function activateWindow(w) {
    if (!w) return
    if (Model.isMinimized(w, root.shelfWorkspace) || Model.isMinimized(w, "special:minimized")) {
      root.restoreWindow(w)
      return
    }
    root.dispatch("hl.dsp.focus({ window = " + JSON.stringify(root.addressExpr(w)) + " })")
  }

  function restoreWindow(w) {
    var addr = Model.normalizedAddress(w)
    var ws = root.lastWorkspace[addr] || "1"
    root.dispatch("hl.dsp.window.move({ workspace = " + JSON.stringify(String(ws))
      + ", window = " + JSON.stringify(root.addressExpr(w)) + ", follow = " + JSON.stringify(true) + " })")
  }

  // Launch when closed, otherwise step to the next window of the group
  // (wrapping). A focused window is never hidden or minimized.
  function cycleGroup(group) {
    if (!group || group.windows.length === 0) return
    var wins = group.windows
    if (wins.length === 1) {
      root.activateWindow(wins[0])
      return
    }
    var idx = -1
    for (var i = 0; i < wins.length; i++) {
      if (Model.isActive(wins[i], root.activeAddress)) {
        idx = i
        break
      }
    }
    root.activateWindow(wins[(idx + 1) % wins.length])
  }

  function closeWindow(w) {
    if (w) root.dispatch("hl.dsp.window.close({ window = " + JSON.stringify(root.addressExpr(w)) + " })")
  }

  function launchApp(entry, pinId) {
    var id = entry && entry.id ? entry.id : pinId
    if (!id) return
    var lib = root.shell && root.shell.appLibrary
    if (lib && typeof lib.launch === "function") {
      lib.launch(id, entry ? entry.name : "")
      return
    }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function launchNewInstance(entry) {
    var cmd = Model.launchCommand(entry ? entry.execString : "")
    if (cmd) {
      Util.execArgv(["uwsm-app", "--", "sh", "-c", cmd])
      return
    }
    root.launchApp(entry, "")
  }

  function buildMenuItems(group) {
    var items = []
    for (var i = 0; i < group.windows.length; i++) {
      var w = group.windows[i]
      var label = (Model.isMinimized(w, root.shelfWorkspace) ? "Restore — " : "Focus — ") + root.windowTitle(w)
      items.push({ label: label, action: (function(win) { return function() { root.activateWindow(win) } })(w) })
    }
    if (group.windows.length > 1) {
      items.push({
        label: "Close all windows", destructive: true,
        action: (function(wins) {
          return function() { for (var k = 0; k < wins.length; k++) root.closeWindow(wins[k]) }
        })(group.windows.slice())
      })
    } else if (group.windows.length === 1) {
      var only = group.windows[0]
      items.push({ label: "Close", destructive: true, action: function() { root.closeWindow(only) } })
    }
    if (group.entry && group.entry.execString) {
      items.push({ label: "Open new instance", action: function() { root.launchNewInstance(group.entry) } })
    } else if (group.pinned && group.windows.length === 0) {
      items.push({ label: "Open", action: function() { root.launchApp(group.entry, group.pinId) } })
    }
    items.push({ label: group.pinned ? "Unpin from taskbar" : "Pin to taskbar", action: function() { root.togglePin(group) } })
    return items
  }

  function togglePin(group) {
    if (!group) return
    var id = group.pinId
    if (!id && group.entry && group.entry.id) id = Model.normKey(group.entry.id)
    if (!id && group.windows.length > 0) id = Model.groupKey(group.windows[0])
    if (!id) return
    var next = root.pins.slice()
    var at = next.indexOf(id)
    if (at === -1) next.push(id)
    else next.splice(at, 1)
    root.pins = next
    root.savePins()
  }

  // ------------------------------------------------------------- persistence

  function loadPins(raw) {
    var parsed = []
    try {
      var obj = JSON.parse(raw || "{}")
      if (Array.isArray(obj)) parsed = obj
      else if (obj && Array.isArray(obj.pins)) parsed = obj.pins
    } catch (e) {
      parsed = []
    }
    var seen = {}
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var id = Model.normKey(parsed[i])
      if (id && !seen[id]) {
        seen[id] = true
        out.push(id)
      }
    }
    root.pins = out
  }

  function savePins() {
    if (!root.persistReady) return
    pinnedFile.setText(JSON.stringify({ version: 1, pins: root.pins }, null, 2))
  }

  // ------------------------------------------------------------------ events

  Timer {
    id: refreshTimer
    interval: 50
    onTriggered: root.refreshGroups()
  }

  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: root.scheduleRefresh()
  }

  onWindowsChanged: root.scheduleRefresh()
  onPinsChanged: root.scheduleRefresh()
  onIndexChanged: root.scheduleRefresh()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name.indexOf("window") !== -1 || name.indexOf("workspace") !== -1
          || name === "focusedmon" || name === "urgent"
          || name === "changefloatingmode" || name === "fullscreen"
          || name === "configreloaded") {
        root.scheduleRefresh()
      }
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.rebuildIndex() }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: {
      pinnedFile.path = root.pinnedFilePath
      pinnedFile.reload()
    }
  }

  FileView {
    id: pinnedFile
    path: ""
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.persistReady = true
      root.loadPins(text())
    }
    onLoadFailed: {
      root.persistReady = true
      root.loadPins("")
    }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    root.rebuildIndex()
    root.scheduleRefresh()
  }
}
