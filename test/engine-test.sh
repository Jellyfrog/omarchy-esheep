#!/bin/bash
# Unit tests for Engine.js and a sanity pass over every shipped pet asset.
# Needs node; no compositor, no Quickshell, no display.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

{
  node_prelude
  cat <<'JS'
const Engine = require(path.join(root, 'Engine.js'))

const world = makeWorld()
const vars = Engine.variablesFor(world, { x: 100, y: 200 })

// ---- expressions -----------------------------------------------------------

assertEqual(Engine.evaluate('2+3*4', vars), 14, 'evaluator respects precedence')
assertEqual(Engine.evaluate('(2+3)*4', vars), 20, 'evaluator respects parentheses')
assertEqual(Engine.evaluate('-imageW', vars), -40, 'evaluator applies unary minus')
assertEqual(Engine.evaluate('areaH-imageH', vars), 1040, 'evaluator resolves the floor expression')
assertEqual(Engine.evaluate('screenW+10', vars), 1930, 'evaluator resolves an off-screen spawn')
assertEqual(Engine.evaluate('imageX-imageW*0.9', vars), 64, 'evaluator resolves a child offset')
assertEqual(Engine.evaluate('randS*2', vars), 100, 'randS holds still within a spawn')
assertEqual(Engine.evaluate('int(7/2)', vars), 3, 'evaluator truncates with int()')
assertEqual(Engine.evaluate('23+(Convert(screenW/2,System.Int32)%30)/7', vars, true),
  23, 'evaluator handles the .NET Convert() cast some pets carry')
assertEqual(Engine.evaluate('5/0', vars), 0, 'evaluator survives division by zero')
assertEqual(Engine.evaluate('nonsense+1', vars), 1, 'unknown names read as zero when lenient')
assertThrows(() => Engine.evaluate('nonsense+1', vars, true), 'unknown names throw when strict')
assertThrows(() => Engine.evaluate('2+', vars), 'a truncated expression throws')
assertThrows(() => Engine.evaluate('2 $ 3', vars), 'an illegal character throws')

const randoms = new Set()
const liveWorld = { ...world, random: Math.random }
for (let i = 0; i < 200; i++) randoms.add(Engine.evaluate('random', Engine.variablesFor(liveWorld, null)))
assert(randoms.size > 1, 'random is redrawn on every evaluation')
assert([...randoms].every(v => v >= 0 && v <= 99), 'random stays within 0..99')

// ---- weighted selection ----------------------------------------------------

assertEqual(Engine.onlyMask('window'), Engine.ONLY.WINDOW, 'only="window" maps to the window flag')
assertEqual(Engine.onlyMask('horizontal+'), Engine.ONLY.HORIZONTAL_PLUS,
  'only="horizontal+" covers horizontal and window')
assertEqual(Engine.onlyMask(''), Engine.ONLY.NONE, 'a missing only= is unrestricted')

const exits = [
  { id: 11, probability: 2, only: 'window' },
  { id: 35, probability: 10, only: 'taskbar' },
  { id: 1, probability: 90 }
]
// NONE is "no restriction to apply" rather than "nowhere in particular", so a
// pet that is neither on a window nor on the floor can still take any exit --
// the same rule the Windows original uses.
assertEqual(Engine.pickNext(exits, Engine.ONLY.NONE, rolls([0.5])), 1,
  'an unplaced pet weighs every exit')
assertEqual(Engine.pickNext(exits, Engine.ONLY.TASKBAR, rolls([0.01])), 35,
  'a pet on the floor can take the taskbar exit')
assertEqual(Engine.pickNext(exits, Engine.ONLY.WINDOW, rolls([0.01])), 11,
  'a pet on a window can take the window exit')
assertEqual(Engine.pickNext([], Engine.ONLY.NONE, rolls([0.5])), -1,
  'an empty exit list asks for a respawn')
assertEqual(Engine.pickNext([{ id: 7, probability: 5, only: 'window' }], Engine.ONLY.TASKBAR, rolls([0.5])), -1,
  'a list with nothing eligible where the pet stands asks for a respawn')
assertEqual(Engine.pickNext(exits, Engine.ONLY.TASKBAR, rolls([0.99])), 1,
  'a pet on the floor never takes a window-only exit')

// Probabilities are shares of the total, so a roll lands in the matching band.
const bands = [{ id: 1, probability: 25 }, { id: 2, probability: 75 }]
assertEqual(Engine.pickWeighted(bands, 0.1).id, 1, 'a low roll lands in the first band')
assertEqual(Engine.pickWeighted(bands, 0.9).id, 2, 'a high roll lands in the wider band')

// ---- sequences -------------------------------------------------------------

const def = walkerDef()

const walk = Engine.resolveAnimation(def, 1, world, { x: 0, y: 0 })
assertEqual(walk.totalSteps, 6, 'repeat from the top replays every frame')
assertDeepEqual([0, 1, 2, 3, 4, 5].map(s => Engine.frameAt(walk, s)), [2, 3, 2, 3, 2, 3],
  'frames cycle through the repeat window')
assertEqual(Engine.stepValues(walk, 0).interval, 200, 'interval starts at the start value')
assertEqual(Engine.stepValues(walk, 6).interval, 100, 'interval reaches the end value')
assertClose(Engine.stepValues(walk, 3).opacity, 0.75, 0.001, 'opacity interpolates across the sequence')

const repeatFromLater = Engine.resolveAnimation({
  animations: {
    '1': {
      id: 1, name: 'x',
      start: { x: '0', y: '0', interval: '100' },
      end: { x: '0', y: '0', interval: '100' },
      sequence: { repeat: '2', repeatFrom: 1, frames: [4, 5, 6], action: '', next: [] }
    }
  }
}, 1, world, { x: 0, y: 0 })
assertEqual(repeatFromLater.totalSteps, 5, 'repeat from a later frame drops one frame per lap')
assertDeepEqual([0, 1, 2, 3, 4].map(s => Engine.frameAt(repeatFromLater, s)), [4, 5, 6, 6, 5],
  'a partial repeat replays the tail with upstream\'s wrap')

// ---- walking ---------------------------------------------------------------

// The same pet, plus a farewell animation, for the dismissal tests.
const defWithKill = JSON.parse(JSON.stringify(def))
defWithKill.animations['9'] = {
  id: 9, name: 'kill',
  start: { x: '-2', y: '0', interval: '100' },
  end: { x: '-2', y: '0', interval: '100' },
  sequence: { repeat: '2', repeatFrom: 0, frames: [70], action: '', next: [{ id: 1, probability: 100 }] },
  border: [{ id: 1, probability: 100 }],
  gravity: [{ id: 5, probability: 100 }]
}
defWithKill.special = { fall: 5, drag: 1, kill: 9, sync: 1 }

function petAt(x, y, animationId) {
  const pet = Engine.createPet(def, world, { x, y, animationId, flipped: false })
  return pet
}

const walker = petAt(500, 1040, 1)
const before = walker.x
Engine.tick(walker, def, { ...world }, rolls([0.5]))
assertEqual(walker.x, before - 2, 'a walking pet moves by its start x each step')
assertEqual(walker.y, 1040, 'a pet on the floor stays on the floor')

// Walking into the left edge of the screen takes the vertical border exit.
const atEdge = petAt(1, 1040, 1)
const edgeResult = Engine.tick(atEdge, def, { ...world }, rolls([0.5]))
assertEqual(atEdge.animationId, 2, 'hitting the left edge starts the border animation')
assertEqual(atEdge.x, 0, 'the pet is pinned to the edge it hit')
assertEqual(edgeResult.children.length, 1, 'an animation with a child spawns one')
assertEqual(edgeResult.children[0].animationId, 1, 'the child starts on its own animation')

// The flip action turns the pet around, and a turned pet walks the other way.
const turner = petAt(0, 1040, 2)
for (let i = 0; i < 4 && !turner.flipped; i++) Engine.tick(turner, def, { ...world }, rolls([0.5]))
assert(turner.flipped, 'the flip action turns the pet around')
const facingRight = { ...turner, animationId: 1, animationStep: 0, resolved: null, x: 100, y: 1040 }
Engine.tick(facingRight, def, { ...world }, rolls([0.5]))
assertEqual(facingRight.x, 102, 'a turned pet walks in the opposite direction')

// Nothing underfoot: gravity hands the pet to the fall animation.
const midair = petAt(500, 300, 1)
Engine.tick(midair, def, { ...world }, rolls([0.5]))
assertEqual(midair.animationId, 5, 'a pet with nothing under it starts falling')

// A pet a couple of pixels above the floor settles instead of falling.
const nearFloor = petAt(500, 1038, 1)
Engine.tick(nearFloor, def, { ...world }, rolls([0.5]))
assertEqual(nearFloor.animationId, 1, 'a pet just above the floor keeps walking')
assertEqual(nearFloor.y, 1040, 'a pet just above the floor settles onto it')

// A magnified pet covers proportionally more ground per step.
assertEqual(Engine.scaleDelta(-2, 2), -4, 'movement scales with the sprite')
assertEqual(Engine.scaleDelta(-1, 0.5), -1, 'a moving pet keeps moving at small scales')
assertEqual(Engine.scaleDelta(0, 3), 0, 'a standing pet stays put at any scale')
const big = Engine.createPet(def, { ...world, scale: 2 }, { x: 500, y: 1000, animationId: 1 })
Engine.tick(big, def, { ...world, scale: 2 }, rolls([0.5]))
assertEqual(big.x, 496, 'a doubled pet walks at double speed')

// Everything tick() reports is in the same magnified pixels the pet walks in,
// so the QML never has to rescale part of the answer.
const offsetDef = JSON.parse(JSON.stringify(def))
offsetDef.animations['1'].start.offsetY = '3'
offsetDef.animations['1'].end.offsetY = '3'
const lifted = Engine.createPet(offsetDef, { ...world, scale: 2 }, { x: 500, y: 1040, animationId: 1 })
assertEqual(Engine.tick(lifted, offsetDef, { ...world, scale: 2 }, rolls([0.5])).offsetY, 6,
  'the vertical offset comes back scaled with the sprite')

// ---- windows ---------------------------------------------------------------

const withWindow = {
  ...world,
  windows: [{ key: 'a', x: 400, y: 600, width: 800, height: 400, stacking: 0 }]
}

const faller = petAt(500, 500, 5)
let landed = null
for (let i = 0; i < 20 && faller.animationId === 5; i++) landed = Engine.tick(faller, def, withWindow, rolls([0.5]))
assertEqual(faller.y, 560, 'a falling pet lands on the top edge of a window')
assertEqual(faller.windowKey, 'a', 'a landed pet remembers the window it stands on')
assertEqual(faller.animationId, 1, 'landing on a window starts the window border animation')
assertEqual(landed.offsetY, 0, 'landing clears any vertical offset')

// Falling past the sides of a window ignores it.
const beside = petAt(100, 500, 5)
for (let i = 0; i < 5; i++) Engine.tick(beside, def, withWindow, rolls([0.5]))
assertEqual(beside.windowKey, '', 'a pet falling beside a window never lands on it')
assert(beside.y > 540, 'a pet falling beside a window keeps falling')

// The pet may hang half a sprite over the edge before it misses.
assert(Engine.landingWindow(withWindow, { x: 385, y: 555 }, 10) !== null,
  'a pet overhanging the window edge still lands on it')
assert(Engine.landingWindow(withWindow, { x: 340, y: 555 }, 10) === null,
  'a pet past the overhang misses the window')
assert(Engine.landingWindow(withWindow, { x: 500, y: 10 }, 10) === null,
  'a pet near the top of the area does not land on anything')

// A window in front hides the one behind it.
const stacked = {
  ...world,
  windows: [
    { key: 'back', x: 400, y: 600, width: 800, height: 400, stacking: 1 },
    { key: 'front', x: 300, y: 500, width: 900, height: 500, stacking: 0 }
  ]
}
assertEqual(Engine.topWindowAt(stacked, 500, 700).key, 'front', 'the front-most window wins a lookup')
assert(Engine.landingWindow(stacked, { x: 500, y: 555 }, 20) === null,
  'a pet does not land on a window that something covers')

// Walking off the end of a window drops the pet.
const onWindow = petAt(401, 560, 1)
onWindow.windowKey = 'a'
onWindow.trackedWindow = { key: 'a', x: 400, y: 600, width: 800, height: 400 }
Engine.tick(onWindow, def, withWindow, rolls([0.5]))
assertEqual(onWindow.animationId, 2, 'reaching the edge of a window starts the border animation')
assertEqual(onWindow.x, 400, 'the pet is pinned to the window edge it hit')
assertEqual(onWindow.windowKey, 'a', 'turning around on a window keeps the pet on it')

// A window that moves carries its passenger.
const rider = petAt(500, 560, 1)
rider.windowKey = 'a'
rider.trackedWindow = { key: 'a', x: 400, y: 600, width: 800, height: 400 }
const moved = { ...world, windows: [{ key: 'a', x: 450, y: 620, width: 800, height: 400, stacking: 0 }] }
Engine.tick(rider, def, moved, rolls([0.5]))
assertEqual(rider.y, 580, 'a pet rides a window that moves')
assertEqual(rider.x, 548, 'a riding pet keeps walking while it rides')

// A window that closes drops its passenger.
const stranded = petAt(500, 560, 1)
stranded.windowKey = 'a'
stranded.trackedWindow = { key: 'a', x: 400, y: 600, width: 800, height: 400 }
Engine.tick(stranded, def, { ...world, windows: [] }, rolls([0.5]))
assertEqual(stranded.windowKey, '', 'a closed window releases the pet standing on it')
assertEqual(stranded.animationId, 5, 'a released pet starts falling')

// Window walking can be switched off entirely.
const ignoring = petAt(500, 500, 5)
Engine.tick(ignoring, def, { ...withWindow, walkOnWindows: false }, rolls([0.5]))
assertEqual(ignoring.y, 510, 'with window walking off the pet falls past windows')

// ---- drag, release, respawn ------------------------------------------------

const dragged = petAt(500, 1040, 1)
Engine.grab(dragged, def, world)
assert(dragged.dragging, 'grabbing the pet sets it dragging')
const dragTick = Engine.tick(dragged, def, world, rolls([0.5]))
assertEqual(dragged.x, 500, 'a dragged pet does not walk on its own')
assertEqual(dragTick.interval, 50, 'a dragged pet animates on a fixed interval')
Engine.release(dragged, def, world)
assertEqual(dragged.dragging, false, 'releasing the pet clears the drag')
assertEqual(dragged.animationId, 5, 'a released pet falls')

// An animation with a border exit is pinned to the edge instead of leaving.
const bouncer = petAt(1, 1040, 1)
Engine.tick(bouncer, def, world, rolls([0.5]))
assertEqual(bouncer.x, 0, 'a pet with a border exit is caught by the edge')

// One without walks off, and is respawned once it is well clear of the area.
// A dismissed pet keeps dying: nothing it walks into can restart it.
const dying = Engine.createPet(defWithKill, { ...world }, { x: 1, y: 1040, animationId: 1 })
assert(Engine.dismiss(dying, defWithKill, world), 'a pet with a farewell animation plays it')
assertEqual(dying.animationId, 9, 'dismissing starts the kill animation')
var dyingTicks = 0
var dyingResult = null
for (; dyingTicks < 40; dyingTicks++) {
  dyingResult = Engine.tick(dying, defWithKill, world, rolls([0.5]))
  if (dyingResult.dead) break
  assertQuiet(dying.animationId === 9, 'a dying pet stays dying')
}
assert(dyingResult && dyingResult.dead, 'a dismissed pet is gone once its farewell is over')
assert(dying.leaving, 'the engine, not the caller, remembers that a pet is leaving')

// The farewell is bounded in the engine rather than by a timer in the QML, so
// a pet file cannot keep a dismissed pet on screen.
const slowGoodbye = JSON.parse(JSON.stringify(defWithKill))
slowGoodbye.animations['9'].sequence.repeat = '10000'
slowGoodbye.animations['9'].start.interval = '100'
slowGoodbye.animations['9'].end.interval = '100'
const slowlyDying = Engine.createPet(slowGoodbye, world, { x: 500, y: 1040, animationId: 1 })
Engine.dismiss(slowlyDying, slowGoodbye, world)
assert(slowlyDying.resolved.totalSteps <= 50,
  'a farewell with an absurd repeat count is capped to a few seconds',
  `totalSteps: ${slowlyDying.resolved.totalSteps}`)

// A dismissed pet is gone, not recycled, however it leaves the screen.
const wanderingOff = Engine.createPet(defWithKill, world, { x: -500, y: 1040, animationId: 8 })
Engine.dismiss(wanderingOff, defWithKill, world)
wanderingOff.animationId = 8
wanderingOff.resolved = null
assert(Engine.tick(wanderingOff, defWithKill, world, rolls([0.5])).dead,
  'a leaving pet that walks off the edge dies rather than respawning')
assertEqual(Engine.dismiss(petAt(500, 1040, 1), def, world), false,
  'a pet file with no farewell animation just leaves')

assert(Engine.outOfWorld({ x: -500, y: 1040 }, world), 'a pet three sprites past the edge is out of the world')
assert(!Engine.outOfWorld({ x: -60, y: 1040 }, world), 'a pet just off screen is still in the world')

const lost = petAt(-500, 1040, 8)
const lostResult = Engine.tick(lost, def, world, rolls([0.5]))
assert(lostResult.respawned, 'a pet far outside the area respawns')
assertEqual(lost.x, 1930, 'a respawned pet is placed by the spawn rules')
assertEqual(lost.windowKey, '', 'a respawned pet forgets the window it was on')

const ending = petAt(500, 1040, 8)
Engine.tick(ending, def, world, rolls([0.5]))
const endResult = Engine.tick(ending, def, world, rolls([0.5]))
assert(endResult.respawned, 'a sequence with no eligible exit respawns the pet')

const lostChild = Engine.createPet(def, world, { x: -500, y: 1040, animationId: 8, isChild: true })
const childResult = Engine.tick(lostChild, def, world, rolls([0.5]))
assert(childResult.dead, 'a child that wanders off is removed instead of respawning')

const endingChild = Engine.createPet(def, world, { x: 500, y: 1040, animationId: 8, isChild: true })
Engine.tick(endingChild, def, world, rolls([0.5]))
assert(Engine.tick(endingChild, def, world, rolls([0.5])).dead,
  'a child disappears when its animation runs out')

// ---- shipped assets --------------------------------------------------------

const assetsDir = path.join(root, 'assets')
const pets = fs.readdirSync(assetsDir).filter(name =>
  fs.existsSync(path.join(assetsDir, name, 'pet.json')))

assert(pets.length > 0, 'the plugin ships at least one pet')
assert(pets.indexOf('esheep') !== -1, 'the default eSheep pet is present')

for (const name of pets) {
  const dir = path.join(assetsDir, name)
  const pet = JSON.parse(fs.readFileSync(path.join(dir, 'pet.json'), 'utf8'))
  const image = pet.image || {}

  assert(fs.existsSync(path.join(dir, image.file || 'sprites.png')),
    `${name}: the sprite sheet named by pet.json exists`)
  assert(image.frameWidth > 0 && image.frameHeight > 0, `${name}: frames have a size`)
  assertEqual(image.frameWidth * image.tilesX, image.width, `${name}: tiles divide the sheet width`)
  assertEqual(image.frameHeight * image.tilesY, image.height, `${name}: tiles divide the sheet height`)

  const petWorld = makeWorld({ imageWidth: image.frameWidth, imageHeight: image.frameHeight })
  const petVars = Engine.variablesFor(petWorld, { x: 10, y: 10 })

  // Every expression in the file has to parse with the same evaluator the
  // shell uses, or the pet would silently walk to (0, 0) at runtime.
  let expressions = 0
  const check = (expression, where) => {
    expressions++
    try {
      const value = Engine.evaluate(expression, petVars, true)
      if (!isFinite(value)) throw new Error('not finite')
    } catch (e) {
      fail(`${name}: ${where} evaluates ("${expression}")`, e.message)
    }
  }

  const frameCount = image.tilesX * image.tilesY
  const ids = Object.keys(pet.animations)
  assert(ids.length > 0, `${name}: has animations`)

  for (const id of ids) {
    const animation = pet.animations[id]
    assertEqual(String(animation.id), id, `${name}: animation ${id} is keyed by its own id`)
    for (const which of ['start', 'end']) {
      const values = animation[which]
      check(values.x, `animation ${id} ${which}.x`)
      check(values.y, `animation ${id} ${which}.y`)
      check(values.interval, `animation ${id} ${which}.interval`)
      check(values.offsetY, `animation ${id} ${which}.offsetY`)
      check(values.opacity, `animation ${id} ${which}.opacity`)
    }
    check(animation.sequence.repeat, `animation ${id} repeat`)

    const badFrame = (animation.sequence.frames || []).find(f => !(f >= 0 && f < frameCount))
    assert(badFrame === undefined,
      `${name}: animation ${id} frames are inside the sheet`,
      `frame ${badFrame} is outside 0..${frameCount - 1}`)

    const exits = [].concat(animation.sequence.next || [], animation.border || [], animation.gravity || [])
    const dangling = exits.find(exit => pet.animations[String(exit.id)] === undefined)
    assert(dangling === undefined,
      `${name}: animation ${id} exits point at animations that exist`,
      dangling ? `animation ${id} points at missing animation ${dangling.id}` : '')

    const resolved = Engine.resolveAnimation(pet, Number(id), petWorld, { x: 0, y: 0 })
    assert(resolved !== null && resolved.totalSteps >= 1,
      `${name}: animation ${id} resolves to at least one step`)
  }

  assert((pet.spawns || []).length > 0, `${name}: has at least one spawn`)
  for (const entry of pet.spawns) {
    check(entry.x, `spawn ${entry.id} x`)
    check(entry.y, `spawn ${entry.id} y`)
    const missing = (entry.next || []).find(exit => pet.animations[String(exit.id)] === undefined)
    assert(missing === undefined, `${name}: spawn ${entry.id} starts a real animation`)
  }

  for (const child of pet.childs || []) {
    check(child.x, `child of ${child.animationId} x`)
    check(child.y, `child of ${child.animationId} y`)
    assert(pet.animations[String(child.next)] !== undefined,
      `${name}: child of animation ${child.animationId} starts a real animation`)
  }

  assert(expressions > 0, `${name}: expressions were checked`)

  // A pet has to be able to walk for a while without falling over: no
  // exceptions, no NaN coordinates, no animation id that leads nowhere.
  const roaming = Engine.createPet(pet, petWorld, {})
  let ticks = 0
  try {
    for (; ticks < 4000; ticks++) {
      const outcome = Engine.tick(roaming, pet, petWorld, Math.random)
      if (!isFinite(roaming.x) || !isFinite(roaming.y)) throw new Error(`position went to ${roaming.x},${roaming.y}`)
      if (!isFinite(outcome.interval) || outcome.interval < 1) throw new Error(`interval was ${outcome.interval}`)
      if (!(outcome.frame >= 0 && outcome.frame < frameCount)) throw new Error(`frame ${outcome.frame} is off the sheet`)
      if (outcome.dead) break
    }
    pass(`${name}: walks ${ticks} steps without breaking`)
  } catch (e) {
    fail(`${name}: walks without breaking`, `after ${ticks} steps: ${e.message}`)
  }

  // The same walk with windows in the way, so the landing and riding paths
  // get exercised on real pet data too.
  const busy = {
    ...petWorld,
    windows: [
      { key: 'w1', x: 200, y: 500, width: 700, height: 500, stacking: 1 },
      { key: 'w2', x: 950, y: 300, width: 800, height: 700, stacking: 0 }
    ]
  }
  const climber = Engine.createPet(pet, busy, {})
  let stood = false
  try {
    for (let i = 0; i < 4000; i++) {
      const outcome = Engine.tick(climber, pet, busy, Math.random)
      if (climber.windowKey) stood = true
      if (outcome.dead) break
    }
    pass(`${name}: walks ${stood ? 'and stands on windows ' : ''}without breaking around windows`)
  } catch (e) {
    fail(`${name}: walks without breaking around windows`, e.message)
  }
}

// ---- walking up the seam onto a higher screen ------------------------------

// Two screens edge to edge whose floors do not line up: the pet's own screen
// is the taller one, so its floor sits below the bottom edge of the neighbour.
// Walking sideways can never reach that neighbour -- there is no screen beside
// the pet at that height -- so it climbs the seam and steps across when the
// neighbour's floor is level with it. Numbers are a real pair of monitors: a
// 1440x900 laptop at y=400 beside a 3440x1440 ultrawide at y=0, bar 36 high.
const seam = { screen: 'eDP-1', dx: 1440, dy: -400, span: { start: 400, end: 1264 } }
const cliff = makeWorld({
  width: 3440, height: 1404,
  exits: { left: [seam], right: [], up: [] }
})
const floorY = cliff.height - cliff.imageHeight

assertEqual(Engine.climbExitFor(cliff, 'left', floorY), null,
  'a pet on the floor is below a neighbour whose own floor is higher',
  'this is the case the sideways check already refuses, and why the pet climbs at all')
assertEqual(Engine.climbExitFor(cliff, 'left', 1225), null,
  'and is still below it one pixel short of level')
assertEqual(Engine.climbExitFor(cliff, 'left', 1224), seam,
  'the doorway opens once the whole sprite fits beside the neighbour')

// A span ends at the neighbour's floor, so the highest position that passes
// puts the pet exactly on that floor once it is translated across. That is what
// makes the arrival a step onto the ground rather than a drop out of the air.
assertEqual(1224 + seam.dy, 864 - 40,
  'and stepping across from there lands the pet on the neighbour\'s floor')

// The strict fit is the point: exitFor would let the pet through while it still
// hung below the neighbour's bottom edge, and it would arrive mid-air.
assert(Engine.climbExitFor(cliff, 'left', 1264) === null,
  'the sprite has to fit inside the span, not merely touch it')

// An edge with nothing behind it is still a wall, so a pet climbing the outside
// of the leftmost screen keeps climbing.
const lonely = makeWorld({ width: 3440, height: 1404, exits: { left: [], right: [], up: [] } })
assertEqual(Engine.climbExitFor(lonely, 'left', 1224), null,
  'an outer edge stays a wall, so wall-climbing is untouched')

// ---- and the same thing through tick() -------------------------------------

// The real sheep, climbing the real seam. It hits the wall walking, the pet
// file sends it up the vertical border exit (animation 37, vertical_walk_up,
// which moves -2 a step and hugs the wall), and it steps across on its own.
//
// Seeded, because the walk that carries the sheep to the wall is random and a
// suite that sometimes waits is a suite nobody trusts. The rule itself is
// pinned by the climbExitFor cases above; this proves the whole path joins up.
{
  const sheep = JSON.parse(fs.readFileSync(path.join(root, 'assets', 'esheep', 'pet.json'), 'utf8'))
  let seed = 1
  const roll = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296 }
  const world = makeWorld({
    width: 3440, height: 1404,
    exits: { left: [seam], right: [], up: [] },
    random: roll
  })
  const pet = Engine.createPet(sheep, world, {})
  pet.screen = 'DP-7'
  let crossedTo = '', landedAt = -1
  for (let i = 0; i < 40000; i++) {
    const out = Engine.tick(pet, sheep, world, roll)
    if (out.crossed) { crossedTo = out.crossed; landedAt = pet.y; break }
    if (out.dead) break
  }
  assertEqual(crossedTo, 'eDP-1',
    'the sheep climbs the seam and steps onto the higher screen',
    'without this the lowest screen is somewhere pets go and never leave')
  assertEqual(landedAt, 824, 'arriving on the neighbour\'s floor, not above it')
}

JS
} | node
