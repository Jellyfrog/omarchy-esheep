import QtQuick
import Quickshell
import Quickshell.Hyprland

// The ledges the pet can stand on, and the monitors it should stay off.
//
// Hyprland reports window geometry through `j/clients`, which Quickshell
// exposes as `lastIpcObject` on each toplevel. That object is only refreshed
// on request, so this asks for one whenever something happens that could have
// moved a window, plus a slow tick while pets are out: dragging a window emits
// no events until the drag ends, and a pet standing on one should ride along.
Item {
  id: tracker

  // Off entirely when no pet is looking, so an idle shell does no IPC.
  property bool active: false
  // A pet is standing on a window right now, so its geometry matters at
  // pointer speed rather than at housekeeping speed.
  property bool tracking: false
  // Whether the geometry poll is worth running. It catches window drags, which
  // emit no events until they end, so it only matters while a pet is on screen
  // to ride along. Hyprland events still refresh the tracker either way.
  property bool polling: true

  // [{ key, x, y, width, height, monitor, stacking }] in Hyprland's layout
  // coordinates, covering only windows that are actually on screen.
  property var windows: []
  // { monitorName: true } for monitors showing something fullscreen.
  property var fullscreenMonitors: ({})
  // { monitorName: workspaceId } for the ordinary workspace each monitor shows.
  // A pet pinned to a workspace reads this to know whether anyone is looking at
  // it. The special workspace is deliberately left out: a scratchpad pulled up
  // over workspace 3 does not make the pets on 3 go away.
  property var activeWorkspaces: ({})

  // Bumped whenever `windows` is republished, so callers can cache anything
  // derived from it and know when the derivation is stale.
  property int revision: 0

  readonly property int idleInterval: 1500
  readonly property int trackingInterval: 200

  // Ask Hyprland for fresh geometry. Requests are coalesced: a burst of events
  // (a workspace switch moves every window at once) collapses into one round
  // trip. The reply is asynchronous and lands in `lastIpcObject`, which emits
  // nothing the model as a whole can be bound to, so the rebuild follows on a
  // short delay after that.
  function refresh() {
    if (!active) return
    request.restart()
  }

  Timer {
    id: request
    interval: 40
    repeat: false
    onTriggered: {
      Hyprland.refreshToplevels()
      settle.restart()
    }
  }

  function rebuild() {
    if (!active) {
      if (windows.length > 0) windows = []
      if (Object.keys(fullscreenMonitors).length > 0) fullscreenMonitors = ({})
      if (Object.keys(activeWorkspaces).length > 0) activeWorkspaces = ({})
      return
    }

    // Only windows on a workspace someone is looking at count. Monitors carry
    // both a normal active workspace and, when one is pulled up, a special
    // one; a scratchpad terminal is as walkable as anything else.
    var visibleWorkspaces = ({})
    var activeIds = ({})
    var monitors = []
    try { monitors = Hyprland.monitors.values } catch (e) { monitors = [] }
    for (var m = 0; m < monitors.length; m++) {
      var monitor = monitors[m]
      if (!monitor) continue
      if (monitor.activeWorkspace) {
        visibleWorkspaces[String(monitor.activeWorkspace.id)] = monitor.name
        activeIds[String(monitor.name)] = String(monitor.activeWorkspace.id)
      }
      var raw = monitor.lastIpcObject
      var special = raw && raw.specialWorkspace ? raw.specialWorkspace : null
      if (special && special.id !== undefined && String(special.name || "") !== "")
        visibleWorkspaces[String(special.id)] = monitor.name
    }

    var toplevels = []
    try { toplevels = Hyprland.toplevels.values } catch (e) { toplevels = [] }

    var rects = []
    var fullscreen = ({})
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel) continue
      var object = toplevel.lastIpcObject
      if (!object || !object.at || !object.size) continue
      if (object.mapped === false || object.hidden === true) continue

      var workspaceId = object.workspace && object.workspace.id !== undefined
        ? String(object.workspace.id) : ""
      if (!visibleWorkspaces.hasOwnProperty(workspaceId)) continue

      var width = Number(object.size[0])
      var height = Number(object.size[1])
      if (!(width > 0) || !(height > 0)) continue

      var monitorName = visibleWorkspaces[workspaceId]
      if (object.fullscreen === true || Number(object.fullscreen) >= 2) fullscreen[monitorName] = true

      rects.push({
        key: String(object.address || toplevel.address || ("window" + i)),
        x: Math.round(Number(object.at[0])),
        y: Math.round(Number(object.at[1])),
        width: Math.round(width),
        height: Math.round(height),
        monitor: monitorName,
        // Focus order doubles as a front-to-back ranking: Hyprland raises the
        // window you last focused, and tiled windows never overlap anyway.
        stacking: Number(object.focusHistoryID === undefined ? i : object.focusHistoryID)
      })
    }

    // Switching workspace can leave every rectangle where it was, so this is
    // published before the early return below rather than with the geometry.
    if (!same(activeIds, activeWorkspaces)) activeWorkspaces = activeIds

    // Geometry is re-read several times a second; only publish when something
    // actually changed, or every pet's world would be rebuilt on each poll.
    if (same(rects, windows) && same(fullscreen, fullscreenMonitors)) return
    windows = rects
    fullscreenMonitors = fullscreen
    revision++
  }

  // Field-by-field, which beats serializing both sides to compare them: it
  // allocates nothing and stops at the first difference.
  function same(next, previous) {
    if (Array.isArray(next)) {
      if (!Array.isArray(previous) || next.length !== previous.length) return false
      for (var i = 0; i < next.length; i++) {
        var a = next[i]
        var b = previous[i]
        if (a.key !== b.key || a.x !== b.x || a.y !== b.y) return false
        if (a.width !== b.width || a.height !== b.height) return false
        if (a.stacking !== b.stacking || a.monitor !== b.monitor) return false
      }
      return true
    }
    var nextKeys = Object.keys(next)
    if (nextKeys.length !== Object.keys(previous).length) return false
    for (var k = 0; k < nextKeys.length; k++) {
      if (previous[nextKeys[k]] !== next[nextKeys[k]]) return false
    }
    return true
  }

  function fullscreenOn(monitorName) {
    return fullscreenMonitors[String(monitorName)] === true
  }

  // "" while the tracker has not answered yet, which callers read as "unknown"
  // rather than as a workspace no pet belongs to.
  function activeWorkspaceOn(monitorName) {
    var id = activeWorkspaces[String(monitorName)]
    return id === undefined ? "" : String(id)
  }

  // Windows on one monitor, moved into that monitor's area-local coordinates.
  //
  // Every pet on a monitor asks for the same list on every tick, so the answer
  // is built once per monitor and handed out until the geometry changes.
  property var translated: ({})

  function windowsIn(area, monitorName) {
    var key = monitorName + "@" + revision + ":" + area.x + "," + area.y
    var cached = translated[key]
    if (cached) return cached

    var out = []
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (monitorName && w.monitor && w.monitor !== monitorName) continue
      out.push({
        key: w.key,
        x: w.x - area.x,
        y: w.y - area.y,
        width: w.width,
        height: w.height,
        stacking: w.stacking
      })
    }
    // One entry per monitor: a new revision replaces the whole table rather
    // than growing it.
    if (translated.revision !== revision) translated = ({ revision: revision })
    translated[key] = out
    return out
  }

  onActiveChanged: {
    if (active) refresh()
    else rebuild()
  }

  Timer {
    interval: tracker.tracking ? tracker.trackingInterval : tracker.idleInterval
    running: tracker.active && tracker.polling
    repeat: true
    triggeredOnStart: true
    onTriggered: tracker.refresh()
  }

  Timer {
    id: settle
    interval: 60
    repeat: false
    onTriggered: tracker.rebuild()
  }

  Connections {
    target: Hyprland

    // Events that can move, resize, open or close something the pet cares
    // about. Title changes are the loud exception -- every shell prompt and
    // every browser tab switch sends one, and none of them move a window.
    function onRawEvent(event) {
      if (!tracker.active) return
      var name = String(event.name || "")
      if (name.indexOf("windowtitle") === 0) return
      if (name.indexOf("window") === -1 && name.indexOf("workspace") === -1
        && name.indexOf("fullscreen") === -1 && name.indexOf("monitor") === -1) return
      tracker.refresh()
    }
  }

  // Windows appearing and disappearing changes the model itself.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { if (tracker.active) settle.restart() }
  }

  Component.onCompleted: if (active) refresh()
}
