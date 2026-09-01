import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "Engine.js" as Engine
import "Layout.js" as Layout
import "Settings.js" as Settings

// The pet overlay: one transparent layer-shell surface per monitor, a pet per
// walking sheep, and the glue that tells each pet how big its world is.
//
// This is the plugin's `panel` entry point. It is keepLoaded, so it mounts
// with the shell and stays mounted; `omarchy-shell shell toggle <id>` flips
// the pets on and off rather than loading and unloading the plugin.
Item {
  id: root

  // ---- injected by the shell host
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "jellyfrog.esheep"

  // ---- settings, read straight from the shell's live config
  readonly property var config: shell ? shell.shellConfig : null
  readonly property var settings: Settings.read(config, pluginId)

  readonly property string petId: settings.pet
  readonly property int petCount: settings.count
  // There is no separate on/off: asking for no pets is what "off" means.
  readonly property bool petsEnabled: petCount > 0
  readonly property real petScale: settings.scale
  readonly property real speed: settings.speed
  readonly property bool walkOnWindows: settings.walkOnWindows
  readonly property bool hideOnFullscreen: settings.hideOnFullscreen
  readonly property bool allowChildren: settings.allowChildren
  readonly property bool avoidBar: settings.avoidBar
  // Not the stored setting alone: the workspace lock beats roaming, and
  // Settings.roamingOn folds the two together. Asked here rather than only in
  // the panel, so a shell.json that was never opened -- where both ship on --
  // behaves the way the greyed-out toggle says it does.
  readonly property bool roamMonitors: Settings.roamingOn(settings)
  readonly property bool lockToWorkspace: settings.lockToWorkspace

  // Never more than this many sprites alive at once, however enthusiastically
  // an animation spawns children.
  readonly property int hardLimit: 32
  readonly property int maxChildDepth: 5

  // Settings are stored, not held: writing them through the shell is what
  // makes them survive a restart, and what lets the bar widget and the
  // overlay see the same values.
  function updateSettings(changes) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    shell.updateEntryInline(pluginId, Settings.patch(config, pluginId, changes))
    return true
  }

  // Sending the pets away means asking for none, and bringing them back asks
  // for one; Settings.countFor is the one place that says so. Writing only on a
  // real change keeps a close() that changes nothing from rewriting shell.json
  // and re-broadcasting the config to every other plugin in the shell.
  function setEnabled(on) {
    var next = Settings.countFor(on, petCount)
    if (next === petCount) return false
    return updateSettings({ count: next })
  }

  // ---- the panel contract the shell host calls into
  readonly property bool opened: petsEnabled
  function open(payloadJson) { setEnabled(true) }
  function toggle() { setEnabled(!petsEnabled) }

  // The shell calls close() on every panel plugin twice over: once when the
  // user asks, and once on each plugin reload, when it tears the whole plugin
  // host down -- a reload of any plugin on the box, not just this one. Only
  // the first is a request, and `pluginReloading` is what tells them apart.
  //
  // Guarded on the flag being there at all rather than on its value: were a
  // later shell to drop it, a missing flag reads as "not reloading" and close()
  // would empty the count on every reload, silently, which is the bug this
  // guard exists to prevent. Not persisting is the safe way to be wrong.
  readonly property bool canTellReload: shell !== null && ("pluginReloading" in shell)
  onCanTellReloadChanged: if (shell !== null && !canTellReload)
    console.warn("esheep: no pluginReloading on this shell; close() will not send the pets away")

  function close() {
    if (!canTellReload || shell.pluginReloading) return
    setEnabled(false)
  }

  // ---------------------------------------------------------------- pet file

  property var definition: null
  property string definitionError: ""

  readonly property int frameWidth: definition && definition.image ? Number(definition.image.frameWidth) : 40
  readonly property int frameHeight: definition && definition.image ? Number(definition.image.frameHeight) : 40
  readonly property int sheetWidth: definition && definition.image ? Number(definition.image.width) : 0
  readonly property int sheetHeight: definition && definition.image ? Number(definition.image.height) : 0
  readonly property int tilesX: definition && definition.image ? Number(definition.image.tilesX) : 1
  readonly property int tilesY: definition && definition.image ? Number(definition.image.tilesY) : 1

  // The pet's picture and the pet's hitbox are the same rectangle: the views
  // draw this and the engine collides with it.
  readonly property int spriteWidth: Math.round(frameWidth * petScale)
  readonly property int spriteHeight: Math.round(frameHeight * petScale)
  // The file name comes out of parsed JSON, so it gets the same gate the pet
  // id does, from the same place.
  readonly property string sheetFile: Settings.safeFileName(
    definition && definition.image ? definition.image.file : "", "sprites.png")
  readonly property url sheetUrl: definition
    ? Qt.resolvedUrl("assets/" + petId + "/" + sheetFile)
    : ""

  FileView {
    id: petFile
    path: Qt.resolvedUrl("assets/" + root.petId + "/pet.json")
    printErrors: false
    watchChanges: true
    onLoaded: {
      try {
        root.definition = JSON.parse(text())
        root.definitionError = ""
      } catch (e) {
        root.definition = null
        root.definitionError = "could not parse " + path + ": " + e
        console.warn("esheep: " + root.definitionError)
      }
    }
    onLoadFailed: {
      root.definition = null
      root.definitionError = "could not read " + path
      console.warn("esheep: " + root.definitionError)
    }
    onFileChanged: reload()
  }

  // A different pet is a different sprite sheet and a different animation
  // graph, so the pets on screen are replaced rather than reskinned.
  onDefinitionChanged: {
    clearPets()
    Qt.callLater(syncPets)
  }

  // ---------------------------------------------------------------- monitors

  readonly property string barPosition: {
    if (shell && shell.bar && shell.bar.position) return String(shell.bar.position)
    var bar = config && config.bar ? config.bar : null
    return bar && bar.position ? String(bar.position) : "top"
  }

  // How much of the screen the bar occupies. An auto-hidden bar occupies
  // none of it, so the pets get the whole screen back while it is away.
  readonly property int barStrip: {
    if (!avoidBar) return 0
    if (shell && shell.bar) return shell.bar.barHidden ? 0 : Math.max(0, Number(shell.bar.barSize))
    return barPosition === "left" || barPosition === "right"
      ? Style.bar.sizeVertical
      : Style.bar.sizeHorizontal
  }

  // The walkable rectangle of every monitor, and the doorways between them.
  //
  // Screen geometry and the bar strip change roughly never, while this is read
  // by every pet on every tick and by every view on every frame, so it is
  // measured once per change and handed out as shared objects. Layout owns the
  // copy into plain numbers; Quickshell's screen objects pass straight in.
  readonly property var layout: Layout.layoutFor(Quickshell.screens, barPosition, barStrip)

  readonly property var areas: layout.areas

  function areaFor(screenName) {
    var area = areas[screenName]
    if (area) return area
    // A pet whose monitor just went away falls back to whichever is left.
    var names = Object.keys(areas)
    return names.length > 0 ? areas[names[0]] : null
  }

  // What lies past the edges of one monitor. Empty when roaming is off, which
  // is all it takes to fence every pet onto the screen it spawned on.
  readonly property var noExits: ({ left: [], right: [], up: [] })

  function exitsFor(screenName) {
    if (!roamMonitors) return noExits
    return layout.exits[screenName] || noExits
  }

  // Everything Engine.js needs to know about the world this pet lives in. The
  // window list is shared between every pet on the same monitor rather than
  // rebuilt per pet per tick.
  function worldFor(agent) {
    if (!agent || !definition) return null
    var area = areaFor(agent.screenName)
    if (!area || area.width <= 0 || area.height <= 0) return null
    return {
      width: area.width,
      height: area.height,
      imageWidth: spriteWidth,
      imageHeight: spriteHeight,
      windows: walkOnWindows ? tracker.windowsIn(area, agent.screenName) : emptyWindows,
      walkOnWindows: walkOnWindows,
      exits: exitsFor(agent.screenName),
      scale: petScale,
      randS: agent.randS,
      random: Math.random
    }
  }

  readonly property var emptyWindows: []

  function screenNameAt(x, y) {
    return Layout.screenAt(areas, x, y)
  }

  readonly property string focusedScreenName: {
    var monitor = Hyprland.focusedMonitor
    if (monitor && monitor.name) return String(monitor.name)
    var screens = Quickshell.screens
    return screens.length > 0 ? screens[0].name : ""
  }

  function fullscreenOn(screenName) {
    return hideOnFullscreen && tracker.fullscreenOn(screenName)
  }

  // The workspace a monitor is showing right now, or "" before Hyprland has
  // answered. Reading `activeWorkspaces` here is what makes the bindings that
  // call this re-evaluate on a workspace switch.
  function currentWorkspaceOn(screenName) {
    return tracker.activeWorkspaces && screenName
      ? tracker.activeWorkspaceOn(screenName) : ""
  }

  // Whether anyone is looking at the workspace this pet was pinned to. Unknown
  // answers show the pet: a pet is never hidden because Hyprland was slow.
  function petOnCurrentWorkspace(agent) {
    if (!lockToWorkspace || !agent) return true
    var pinned = String(agent.workspaceId || "")
    if (pinned === "") return true
    var current = currentWorkspaceOn(agent.screenName)
    return current === "" || current === pinned
  }

  // Pets that someone could actually see. `running` is already the one place
  // that decides whether a pet is being simulated -- off-workspace and
  // fullscreen both land there -- so this asks it rather than restating the
  // same conditions and drifting from them later.
  readonly property bool anyPetVisible: {
    for (var i = 0; i < pets.length; i++) {
      if (pets[i] && pets[i].running) return true
    }
    return false
  }

  // ------------------------------------------------------------------- pets

  property var pets: []

  Component {
    id: agentComponent
    PetAgent {}
  }

  // Pets the user asked for. Children an animation brought along are guests,
  // and a pet already playing its farewell has said its goodbyes.
  function adultCount() {
    var total = 0
    for (var i = 0; i < pets.length; i++) {
      if (pets[i] && !pets[i].isChild && !pets[i].leaving) total++
    }
    return total
  }

  // Where the next pet appears. Not simply the focused monitor: pets drift
  // downhill onto the screen with the lower floor, so putting every one of them
  // where you happen to be looking left the other screens empty. Layout.spawnScreen
  // owns the choice; children are not counted, since they arrive beside a parent
  // rather than being asked for.
  function spawnScreenName() {
    var counts = {}
    for (var i = 0; i < pets.length; i++) {
      var agent = pets[i]
      if (!agent || agent.isChild) continue
      counts[agent.screenName] = (counts[agent.screenName] || 0) + 1
    }
    return Layout.spawnScreen(areas, counts, focusedScreenName) || focusedScreenName
  }

  function addPet(screenName, options) {
    if (!definition) return null
    if (pets.length >= hardLimit) return null
    var agent = agentComponent.createObject(root, {
      host: root,
      definition: definition,
      screenName: screenName || focusedScreenName,
      workspaceId: root.currentWorkspaceOn(screenName || focusedScreenName),
      isChild: !!(options && options.isChild),
      childDepth: (options && options.childDepth) || 0,
      // A pet created while its monitor is still being measured waits for a
      // world instead of failing; PetAgent starts itself when one exists.
      spawnOptions: options && options.spawn ? options.spawn : ({})
    })
    if (!agent) return null
    agent.died.connect(function() { removePet(agent) })
    pets = pets.concat([agent])
    return agent
  }

  function removePet(agent) {
    if (!agent) return
    var next = []
    for (var i = 0; i < pets.length; i++) if (pets[i] !== agent) next.push(pets[i])
    if (next.length === pets.length) return
    pets = next
    agent.destroy()
  }

  function clearPets() {
    var current = pets
    pets = []
    for (var i = 0; i < current.length; i++) if (current[i]) current[i].destroy()
  }

  function syncPets() {
    if (!definition || petCount <= 0) {
      if (pets.length > 0) clearPets()
      return
    }
    while (adultCount() < petCount) {
      if (!addPet(spawnScreenName(), {})) break
    }
    while (adultCount() > petCount) {
      var last = null
      for (var i = pets.length - 1; i >= 0; i--) {
        if (pets[i] && !pets[i].isChild && !pets[i].leaving) { last = pets[i]; break }
      }
      if (!last) break
      last.dismiss()
    }
  }

  function spawnChildren(parent, children) {
    if (!parent || !allowChildren || parent.childDepth >= maxChildDepth) return
    for (var i = 0; i < children.length; i++) {
      var child = children[i]
      addPet(parent.screenName, {
        isChild: true,
        childDepth: parent.childDepth + 1,
        spawn: {
          x: child.x,
          y: child.y,
          animationId: child.animationId,
          flipped: child.flipped,
          isChild: true
        }
      })
    }
  }

  // Dropped on another monitor: keep the pet where the pointer left it by
  // re-expressing its position in the new area's coordinates.
  function moveToScreen(agent, screenName, globalX, globalY) {
    if (!agent || !screenName || agent.screenName === screenName) return
    var area = areaFor(screenName)
    if (!area) return
    agent.moveTo(screenName, globalX - area.x, globalY - area.y)
  }

  function dismissPet(agent) {
    if (!agent || agent.leaving) return
    // The pet leaves first, so it stops counting before the new count comes
    // back through shell.json -- otherwise syncPets would send a second one
    // away to make up the difference.
    agent.dismiss()
    // Taking one away is a decision about how many pets there are, so it
    // sticks: the count follows the sheep out the door.
    if (!agent.isChild && petCount > 0) updateSettings({ count: petCount - 1 })
  }

  // `petsEnabled` is a reading of `petCount`, so the count is the only edge
  // there is to listen for.
  onPetCountChanged: syncPets()

  // A pet whose monitor was unplugged has nowhere to walk; put it back on one
  // that exists rather than leaving it stranded off screen.
  Connections {
    target: Quickshell
    function onScreensChanged() {
      for (var i = 0; i < root.pets.length; i++) {
        var agent = root.pets[i]
        if (agent && !root.areas[agent.screenName]) agent.relocate(root.focusedScreenName)
      }
    }
  }

  // ---------------------------------------------------------------- windows

  WindowTracker {
    id: tracker
    active: root.pets.length > 0
      && (root.walkOnWindows || root.hideOnFullscreen || root.lockToWorkspace)
    // Workspace and fullscreen changes arrive as Hyprland events either way, so
    // stopping the poll while every pet is hidden costs no responsiveness.
    polling: root.anyPetVisible
    tracking: {
      for (var i = 0; i < root.pets.length; i++) {
        if (root.pets[i] && (root.pets[i].onWindow || root.pets[i].dragging)) return true
      }
      return false
    }
  }

  // ---------------------------------------------------------------- surfaces

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PetSurface {
        required property var modelData
        host: root
        screen: modelData
        screenName: modelData ? modelData.name : ""
      }
    }
  }

  Component.onCompleted: Qt.callLater(syncPets)
}
