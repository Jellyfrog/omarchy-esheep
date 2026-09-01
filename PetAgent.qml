import QtQuick
import "Engine.js" as Engine

// One pet: the plain-object state Engine.js walks, plus the timer that walks
// it. Non-visual -- every surface that can see this pet draws it from the
// properties published here, so a pet dragged across a monitor edge keeps one
// identity and one animation.
Item {
  id: agent
  visible: false

  property var host: null            // the Pet.qml overlay that owns this pet
  property var definition: null      // the parsed pet.json
  property string screenName: ""     // the monitor whose area it walks
  property bool isChild: false
  property int childDepth: 0
  // Where this pet starts: a child is placed by its parent's animation, a
  // grown pet by the pet file's own spawn rules (an empty object).
  property var spawnOptions: ({})

  // The workspace this pet belongs to, captured when it spawns and re-captured
  // when it moves to another monitor. Empty until Hyprland has answered once.
  property string workspaceId: ""
  // False when this pet is pinned to a workspace nobody is looking at.
  readonly property bool onCurrentWorkspace: host ? host.petOnCurrentWorkspace(agent) : true

  // Pets stop walking while their monitor is showing something fullscreen, or
  // shows another workspace: a paused pet costs nothing. `running` stops the
  // tick timer outright, so pets on workspaces you are not looking at do no
  // work at all. Being switched off needs no term of its own -- that is a pet
  // count of zero, and no pet exists to ask.
  property bool running: host
    ? (onCurrentWorkspace && !host.fullscreenOn(screenName))
    : false

  // What this pet's monitor is showing. A pet created before Hyprland has
  // answered has no pin yet, and adopts the first answer that arrives.
  readonly property string monitorWorkspace: host ? host.currentWorkspaceOn(screenName) : ""
  onMonitorWorkspaceChanged: {
    if (workspaceId === "" && monitorWorkspace !== "") workspaceId = monitorWorkspace
  }

  // A pet that walks or is dragged onto another monitor joins whatever
  // workspace that monitor is showing, instead of vanishing.
  //
  // An answer Hyprland has not given yet clears the pin rather than keeping the
  // old one: an empty pin shows the pet, and onMonitorWorkspaceChanged adopts
  // the answer the moment it arrives. Holding on to the workspace it had on the
  // monitor it just left would hide it on arrival instead -- the one outcome
  // crossing a monitor edge must never produce.
  onScreenNameChanged: {
    if (!host) return
    workspaceId = host.currentWorkspaceOn(screenName)
  }

  // The engine's mutable pet, kept as a plain object so Engine.js stays
  // testable without QML.
  property var petState: null
  property int randS: 0

  // What the views draw.
  property real petX: 0
  property real petY: 0
  property int frame: 0
  property bool mirrored: false
  property real alpha: 1
  property real verticalOffset: 0
  property bool dragging: false
  // On its way out: playing its farewell, and no longer counted against the
  // number of pets the user asked for. Owned by the engine, mirrored here
  // because a plain JS object cannot notify QML on its own.
  property bool leaving: false
  readonly property bool onWindow: petState ? String(petState.windowKey || "") !== "" : false

  signal died()

  function world() {
    return host ? host.worldFor(agent) : null
  }

  // The engine's pet object is the authority; these mirrors exist because a
  // plain JS object cannot notify QML on its own. `screen` included: a
  // crossing renames the pet's monitor inside Engine.tick, and the views
  // follow it through here.
  function sync() {
    if (!petState) return
    petX = petState.x
    petY = petState.y
    mirrored = petState.flipped === true
    dragging = petState.dragging === true
    leaving = petState.leaving === true
    if (petState.screen && petState.screen !== screenName) screenName = petState.screen
  }

  // A pet exists as soon as it is asked for, and starts walking as soon as
  // there is somewhere to walk -- which is not the same moment when a monitor
  // is still being configured, right after login or a hotplug.
  readonly property bool worldReady: host !== null && host.definition !== null
    && host.areaFor(screenName) !== null

  function start() {
    if (petState || !worldReady) return
    var scene = world()
    if (!scene) return
    scene.randS = randS
    petState = Engine.createPet(definition, scene, spawnOptions)
    petState.isChild = isChild
    petState.screen = screenName
    randS = scene.randS
    sync()
    frame = 0
    schedule(60)
  }

  onWorldReadyChanged: start()
  Component.onCompleted: start()

  function step() {
    if (!running || !definition || !petState) return
    var scene = world()
    if (!scene) { schedule(400); return }

    scene.randS = randS
    var result = Engine.tick(petState, definition, scene, Math.random)
    randS = scene.randS

    frame = result.frame
    alpha = result.opacity
    verticalOffset = result.offsetY
    sync()

    if (result.children && result.children.length > 0 && host) host.spawnChildren(agent, result.children)

    if (result.dead) {
      died()
      return
    }
    schedule(result.interval)
  }

  // The pointer takes over: the pet plays its drag animation in place until
  // it is let go.
  function grab() {
    if (!petState) return
    var scene = world()
    if (!scene) return
    Engine.grab(petState, definition, scene)
    sync()
    schedule(16)
  }

  // Position while dragging, in the walkable area's coordinates.
  function dragTo(areaX, areaY) {
    if (!petState) return
    petState.x = Math.round(areaX)
    petState.y = Math.round(areaY)
    sync()
  }

  // Renaming the pet's monitor goes through the engine's pet, which is the
  // authority sync() mirrors from -- a bare write to screenName would be
  // undone on the next tick.
  function relocate(name) {
    if (petState) petState.screen = String(name)
    screenName = String(name)
  }

  // Dropped over another monitor: rename, then take the drop position in the
  // new area's coordinates.
  function moveTo(name, areaX, areaY) {
    if (!petState) return
    relocate(name)
    dragTo(areaX, areaY)
  }

  function release() {
    if (!petState) return
    var scene = world()
    if (!scene) return
    Engine.release(petState, definition, scene)
    sync()
    schedule(16)
  }

  // Send the pet off with its farewell animation, or straight away when the
  // pet file has none. The engine bounds how long a goodbye may take.
  function dismiss() {
    leaving = true
    if (!petState) { died(); return }
    var scene = world()
    if (!scene || !Engine.dismiss(petState, definition, scene)) {
      died()
      return
    }
    sync()
    schedule(16)
  }

  // Intervals come from the pet file in milliseconds; the speed setting
  // stretches them, and nothing runs faster than a frame.
  function schedule(interval) {
    if (!running) return
    var speed = host && host.speed > 0 ? host.speed : 1
    clock.interval = Math.max(8, Math.round(Number(interval) / speed))
    clock.restart()
  }

  Timer {
    id: clock
    repeat: false
    onTriggered: agent.step()
  }

  onRunningChanged: {
    if (running) schedule(60)
    else clock.stop()
  }
}
