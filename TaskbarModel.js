// Pure helpers for the Windows 11-style taskbar: window identity, grouping,
// and desktop-entry/icon resolution. No QML imports here so it stays testable.

function normalizedAddress(toplevel) {
  if (!toplevel || !toplevel.address) return ""
  var address = String(toplevel.address)
  return address.indexOf("0x") === 0 ? address : "0x" + address
}

function ipcOf(toplevel) {
  return toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : {}
}

function windowClass(toplevel) {
  var ipc = ipcOf(toplevel)
  var cls = String(ipc.class || ipc.initialClass || "").trim()
  if (!cls) cls = windowAppId(toplevel)
  return cls
}

function windowAppId(toplevel) {
  if (!toplevel || !toplevel.wayland) return ""
  return String(toplevel.wayland.appId || "").trim()
}

// Canonical form used for both grouping keys and stored pin ids.
function normKey(value) {
  var s = String(value || "").trim().toLowerCase()
  if (s.slice(-8) === ".desktop") s = s.slice(0, -8)
  return s
}

// A window's own key, independent of any desktop entry.
function groupKey(toplevel) {
  return normKey(windowClass(toplevel) || windowAppId(toplevel))
}

function workspaceName(toplevel) {
  return toplevel && toplevel.workspace ? String(toplevel.workspace.name || "") : ""
}

function isMinimized(toplevel, shelfWorkspace) {
  return !!toplevel && workspaceName(toplevel) === String(shelfWorkspace || "")
}

// Windows that belong on the taskbar: mapped, identified, and either on a
// normal workspace or on the minimize shelf / Omarchy's own minimized shelf.
function isRelevant(toplevel, shelfWorkspace) {
  if (!toplevel || !toplevel.address) return false
  if (toplevel.hidden === true) return false
  var ipc = ipcOf(toplevel)
  if (Number(ipc.hidden) === 1) return false
  if (!windowClass(toplevel) && !windowAppId(toplevel)) return false
  var name = workspaceName(toplevel)
  if (name.indexOf("special:") === 0
      && name !== String(shelfWorkspace || "")
      && name !== "special:minimized") return false
  return true
}

function isActive(toplevel, activeAddress) {
  var addr = normalizedAddress(toplevel)
  return addr !== "" && addr === String(activeAddress || "")
}

// ------------------------------------------------------------------ identity

// Build lookup tables from the DesktopEntries list. First entry wins per key so
// the most specific (id) beats the fuzzier (name/exec) fallbacks.
function buildIndex(entries) {
  var byId = {}
  var byStartup = {}
  var byExec = {}
  var byName = {}
  for (var i = 0; i < (entries ? entries.length : 0); i++) {
    var e = entries[i]
    if (!e || e.noDisplay) continue
    var id = normKey(e.id)
    if (id && !byId[id]) byId[id] = e
    var sc = normKey(e.startupClass)
    if (sc && !byStartup[sc]) byStartup[sc] = e
    var command = String(e.command || e.execString || "").trim()
    var first = command.split(/\s+/)[0] || ""
    var base = normKey(first.slice(first.lastIndexOf("/") + 1))
    if (base && !byExec[base]) byExec[base] = e
    var name = normKey(e.name)
    if (name && !byName[name]) byName[name] = e
  }
  return { byId: byId, byStartup: byStartup, byExec: byExec, byName: byName }
}

function lookup(index, key) {
  if (!index || !key) return null
  return index.byId[key]
    || index.byStartup[key]
    || index.byExec[key]
    || index.byName[key]
    || null
}

function entryForWindow(index, toplevel) {
  if (!index) return null
  return lookup(index, normKey(windowClass(toplevel)))
    || lookup(index, normKey(windowAppId(toplevel)))
}

function entryForId(index, id) {
  if (!index) return null
  return lookup(index, normKey(id))
}

// ------------------------------------------------------------------ grouping

// ctx = {
//   isRelevant(w), groupKey(w), pinKeyFor(w), entryForWindow(w), entryForId(id)
// }
function buildGroups(windows, pins, ctx) {
  var running = []
  var byKey = {}

  for (var i = 0; i < (windows ? windows.length : 0); i++) {
    var w = windows[i]
    if (!ctx.isRelevant(w)) continue
    var key = ctx.pinKeyFor(w) || ctx.groupKey(w)
    if (!key) continue
    var g = byKey[key]
    if (!g) {
      g = { key: key, windows: [], entry: null }
      byKey[key] = g
      running.push(g)
    }
    g.windows.push(w)
    if (!g.entry) g.entry = ctx.entryForWindow(w)
  }

  var out = []
  var used = {}
  for (var p = 0; p < (pins ? pins.length : 0); p++) {
    var id = normKey(pins[p])
    if (!id) continue
    var pinned = byKey[id] || null
    used[id] = true
    out.push({
      key: id,
      pinId: id,
      pinned: true,
      running: !!pinned,
      windows: pinned ? pinned.windows : [],
      entry: (pinned && pinned.entry) || ctx.entryForId(id)
    })
  }

  for (var r = 0; r < running.length; r++) {
    var g2 = running[r]
    if (used[g2.key]) continue
    out.push({
      key: g2.key,
      pinId: "",
      pinned: false,
      running: true,
      windows: g2.windows,
      entry: g2.entry
    })
  }

  return out
}

// Stable signature so the widget only rebuilds its model when something that
// matters changed.
function groupsSignature(groups) {
  var parts = []
  for (var i = 0; i < (groups ? groups.length : 0); i++) {
    var g = groups[i]
    var addrs = []
    for (var w = 0; w < g.windows.length; w++) {
      var win = g.windows[w]
      addrs.push(normalizedAddress(win) + "@" + workspaceName(win)
        + ":" + (win.activated === true ? "a" : ""))
    }
    parts.push((g.pinned ? "P" : "R") + g.key + "[" + addrs.join(",") + "]")
  }
  return parts.join("|")
}

// ------------------------------------------------------------------ launching

// Strip freedesktop field codes from an Exec= line so we can start a fresh
// process instead of asking an existing D-Bus instance to focus.
function launchCommand(rawExec) {
  if (!rawExec) return ""
  return String(rawExec)
    .replace(/%%/g, "\u0000")
    .replace(/%[UuFfDdNniIcCkKvm]/g, "")
    .replace(/\u0000/g, "%")
    .replace(/\s{2,}/g, " ")
    .trim()
}
