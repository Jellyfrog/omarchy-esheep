#!/bin/bash
# Monitor layout: walkable areas, and the doorways between screens that let a
# pet wander from one to the next. Needs node; no compositor.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

{
  node_prelude

  cat <<'JS'
const Layout = require(path.join(root, 'Layout.js'))
const Engine = require(path.join(root, 'Engine.js'))

// ---- walkable areas --------------------------------------------------------

const screen = { name: 'DP-1', x: 0, y: 0, width: 1920, height: 1080 }

assertDeepEqual(Layout.areaFor(screen, 'top', 0), { x: 0, y: 0, width: 1920, height: 1080 },
  'without a bar the whole screen is walkable')
assertDeepEqual(Layout.areaFor(screen, 'top', 26), { x: 0, y: 26, width: 1920, height: 1054 },
  'a top bar pushes the ceiling down')
assertDeepEqual(Layout.areaFor(screen, 'bottom', 26), { x: 0, y: 0, width: 1920, height: 1054 },
  'a bottom bar raises the floor')
assertDeepEqual(Layout.areaFor(screen, 'left', 28), { x: 28, y: 0, width: 1892, height: 1080 },
  'a left bar moves the left wall in')
assertDeepEqual(Layout.areaFor(screen, 'right', 28), { x: 0, y: 0, width: 1892, height: 1080 },
  'a right bar moves the right wall in')

// ---- side by side ----------------------------------------------------------

const sideBySide = [
  { name: 'DP-1', x: 0, y: 0, width: 1920, height: 1080 },
  { name: 'DP-2', x: 1920, y: 0, width: 1920, height: 1080 }
]
const plain = Layout.layoutFor(sideBySide, 'top', 0)

assertEqual(plain.exits['DP-1'].right.length, 1, 'the left screen has a doorway on its right')
assertEqual(plain.exits['DP-1'].right[0].screen, 'DP-2', 'and it leads to the screen beside it')
assertEqual(plain.exits['DP-1'].left.length, 0, 'the leftmost screen has nothing to its left')
assertEqual(plain.exits['DP-2'].left[0].screen, 'DP-1', 'the doorway works in both directions')
assertEqual(plain.exits['DP-1'].up.length, 0, 'side-by-side screens are not stacked')

// The translation re-expresses a position, so the pet does not move in the
// world when it changes which monitor measures it.
const doorway = plain.exits['DP-1'].right[0]
assertEqual(doorway.dx, -1920, 'crossing right subtracts the screen you are leaving')
assertEqual(doorway.dy, 0, 'aligned screens need no vertical shift')
assertEqual(1900 + doorway.dx + plain.areas['DP-2'].x, 1900 + plain.areas['DP-1'].x,
  'a pet keeps its place in the world when it crosses')

// ---- a bar down the side ---------------------------------------------------

// Every area is inset by a vertical bar, so the areas no longer touch even
// though the screens do. Adjacency has to be decided on the screens.
const withSideBar = Layout.layoutFor(sideBySide, 'left', 28)
assertEqual(withSideBar.exits['DP-1'].right.length, 1,
  'a bar down the side does not wall the screens off from each other')

// The pet holds its global position across the seam, so it walks the bar-wide
// strip between the two areas rather than jumping over it.
const barred = withSideBar.exits['DP-1'].right[0]
const beforeCrossing = withSideBar.areas['DP-1'].x + 1850
const afterCrossing = withSideBar.areas['DP-2'].x + (1850 + barred.dx)
assertEqual(afterCrossing, beforeCrossing,
  'a pet crossing past a side bar stays where it was in the world')

// ---- mismatched heights and offsets ----------------------------------------

// A 1080p screen beside a 1440p one, bottoms aligned: the small screen sits
// 360px lower in the layout.
const mixed = Layout.layoutFor([
  { name: 'DP-1', x: 0, y: 360, width: 1920, height: 1080 },
  { name: 'DP-2', x: 1920, y: 0, width: 2560, height: 1440 }
], 'top', 0)

assertEqual(mixed.exits['DP-1'].right[0].dy, 360, 'a screen sitting lower shifts the crossing up')
assertEqual(mixed.exits['DP-2'].left[0].dy, -360, 'and the reverse crossing shifts back down')

// ---- corners, gaps and stacks ----------------------------------------------

// Touching only at a corner is not a doorway.
const corner = Layout.layoutFor([
  { name: 'A', x: 0, y: 0, width: 1920, height: 1080 },
  { name: 'B', x: 1920, y: 1080, width: 1920, height: 1080 }
], 'top', 0)
assertEqual(corner.exits['A'].right.length, 0, 'screens meeting at a corner are not a doorway')
assertEqual(corner.exits['A'].up.length, 0, 'nor are they stacked')

// A gap in the layout is a gap the pet cannot cross.
const gapped = Layout.layoutFor([
  { name: 'A', x: 0, y: 0, width: 1920, height: 1080 },
  { name: 'B', x: 2200, y: 0, width: 1920, height: 1080 }
], 'top', 0)
assertEqual(gapped.exits['A'].right.length, 0, 'a gap between screens is not a doorway')

// Stacked screens: upward only, because the bottom of a screen is the ground.
const stacked = Layout.layoutFor([
  { name: 'TOP', x: 0, y: 0, width: 1920, height: 1080 },
  { name: 'BOTTOM', x: 0, y: 1080, width: 1920, height: 1080 }
], 'top', 0)
assertEqual(stacked.exits['BOTTOM'].up.length, 1, 'the lower screen has a way up')
assertEqual(stacked.exits['BOTTOM'].up[0].screen, 'TOP', 'and it leads to the one above')
assertEqual(stacked.exits['TOP'].up.length, 0, 'there is nothing above the top screen')
assertEqual(stacked.exits['TOP'].right.length, 0, 'stacked screens are not side by side')

// Three screens: the middle one has a doorway either way.
const three = Layout.layoutFor([
  { name: 'A', x: 0, y: 0, width: 1920, height: 1080 },
  { name: 'B', x: 1920, y: 0, width: 1920, height: 1080 },
  { name: 'C', x: 3840, y: 0, width: 1920, height: 1080 }
], 'top', 0)
assertEqual(three.exits['B'].left[0].screen, 'A', 'the middle screen leads back to the first')
assertEqual(three.exits['B'].right[0].screen, 'C', 'and on to the third')
assertEqual(three.exits['A'].right.length, 1, 'a screen two along is not adjacent')

// Two portrait screens stacked to the right of one landscape screen: both are
// doorways off the same edge, and which one a pet takes depends on its height.
const twoOnTheRight = Layout.layoutFor([
  { name: 'WIDE', x: 0, y: 0, width: 1920, height: 2160 },
  { name: 'TOP', x: 1920, y: 0, width: 1080, height: 1080 },
  { name: 'LOW', x: 1920, y: 1080, width: 1080, height: 1080 }
], 'top', 0)
assertEqual(twoOnTheRight.exits['WIDE'].right.length, 2, 'one edge can have two doorways')
assertDeepEqual(twoOnTheRight.exits['WIDE'].right.map(e => e.screen), ['TOP', 'LOW'],
  'doorways are ordered top to bottom along the edge')
assertDeepEqual(twoOnTheRight.exits['WIDE'].right.map(e => [e.span.start, e.span.end]),
  [[0, 1080], [1080, 2160]],
  'each doorway knows its own stretch of the shared edge')

// ---- the pet actually walks through ---------------------------------------

const petWorld = makeWorld({ exits: plain.exits['DP-1'] })

const def = walkerDef()

// Walking off the left edge of the right-hand screen lands on the left-hand one.
const leftward = { ...petWorld, exits: plain.exits['DP-2'] }
const walker = Engine.createPet(def, leftward, { x: 1, y: 1040, animationId: 1, screen: 'DP-2' })
const crossing = Engine.tick(walker, def, leftward, rolls([0.5]))
assertEqual(crossing.crossed, 'DP-1', 'a pet reaching the screen edge crosses to the neighbour')
assertEqual(walker.screen, 'DP-1', 'the pet itself knows which monitor measures it now')
assertEqual(walker.x, 1919, 'and arrives at the far side of it, still in step')
assertEqual(walker.y, 1040, 'at the same height it left')
assertEqual(walker.animationId, 1, 'without breaking stride into a turn')

// The same walk with no neighbour turns around, exactly as before.
const fenced = { ...petWorld, exits: { left: [], right: [], up: [] } }
const bouncer = Engine.createPet(def, fenced, { x: 1, y: 1040, animationId: 1 })
const bounce = Engine.tick(bouncer, def, fenced, rolls([0.5]))
assertEqual(bounce.crossed, '', 'a screen with nothing beside it has no doorway')
assertEqual(bouncer.animationId, 2, 'so the pet turns around at the edge')
assertEqual(bouncer.x, 0, 'pinned to the edge it hit')

// Roaming switched off is the same as having no neighbours.
const homebody = Engine.createPet(def, fenced, { x: 1, y: 1040, animationId: 1 })
Engine.tick(homebody, def, fenced, rolls([0.5]))
assertEqual(homebody.animationId, 2, 'a pet with roaming off stays on its own screen')

// Screens of different heights, aligned at the bottom -- the common desk
// setup. The floors line up in the layout, so the pet walks across the seam
// without a step at all.
const bottomAligned = Layout.layoutFor([
  { name: 'SMALL', x: 0, y: 360, width: 1920, height: 1080 },
  { name: 'BIG', x: 1920, y: 0, width: 2560, height: 1440 }
], 'top', 0)
const smallWorld = { ...petWorld, exits: bottomAligned.exits['SMALL'] }
const acrossTheDesk = Engine.createPet(def, smallWorld, { x: 1918, y: 1040, animationId: 1 })
acrossTheDesk.flipped = true                // walking right
const stepped = Engine.tick(acrossTheDesk, def, smallWorld, rolls([0.5]))
assertEqual(stepped.crossed, 'BIG', 'the pet walks onto the bigger screen next to it')
assertEqual(acrossTheDesk.y, 1400, 'and keeps its footing: both floors are the same line')

// Where the floors do not line up, the pet arrives on the floor it can reach
// rather than below the bottom of the new screen.
const topAligned = Layout.layoutFor([
  { name: 'TALL', x: 0, y: 0, width: 1920, height: 1440 },
  { name: 'SHORT', x: 1920, y: 0, width: 1920, height: 1080 }
], 'top', 0)
const tallWorld = { ...petWorld, height: 1440, exits: topAligned.exits['TALL'] }
const stepUp = Engine.createPet(def, tallWorld, { x: 1918, y: 1050, animationId: 1 })
stepUp.flipped = true
const shortWorld = { ...petWorld, exits: topAligned.exits['SHORT'] }
const steppedUp = Engine.tick(stepUp, def, tallWorld, rolls([0.5]))
assertEqual(steppedUp.crossed, 'SHORT', 'the pet crosses where the two screens overlap')
// Arrival is only a translation; the solid floor settles it on the next tick,
// the first one measured in the new monitor's world.
Engine.tick(stepUp, def, shortWorld, rolls([0.5]))
assertEqual(stepUp.y, 1040, 'and settles onto the shorter screen\'s floor a tick later')

// Below that overlap there is nothing to walk onto: a pet on the floor of the
// tall screen, level with the void beside the short one, turns around.
const belowTheEdge = Engine.createPet(def, tallWorld, { x: 1918, y: 1400, animationId: 1 })
belowTheEdge.flipped = true
const noFloorThere = Engine.tick(belowTheEdge, def, tallWorld, rolls([0.5]))
assertEqual(noFloorThere.crossed, '', 'a pet below the neighbouring screen finds no doorway')
assertEqual(belowTheEdge.animationId, 2, 'so it turns around at the edge')

// A neighbour that does not reach the pet's height is not a doorway: walking
// along the floor of a tall screen past a monitor mounted above it hits a wall.
const above = Layout.layoutFor([
  { name: 'TALL', x: 0, y: 0, width: 1920, height: 2160 },
  { name: 'HIGH', x: 1920, y: 0, width: 1920, height: 1080 }
], 'top', 0)
const highWorld = { ...petWorld, height: 2160, exits: above.exits['TALL'] }
const lowWalker = Engine.createPet(def, highWorld, { x: 1918, y: 2120, animationId: 1 })
lowWalker.flipped = true
const blocked = Engine.tick(lowWalker, def, highWorld, rolls([0.5]))
assertEqual(blocked.crossed, '', 'a neighbour out of reach is not a doorway')
assertEqual(lowWalker.animationId, 2, 'so the pet turns around instead')

// A pet standing on a window turns at the window's edge; it steps off the
// ledge before it can cross a screen.
const ledgeWorld = {
  ...petWorld,
  windows: [{ key: 'w', x: 1700, y: 600, width: 220, height: 400, stacking: 0 }],
  exits: plain.exits['DP-1']
}
const onLedge = Engine.createPet(def, ledgeWorld, { x: 1880, y: 560, animationId: 1 })
onLedge.flipped = true
onLedge.windowKey = 'w'
onLedge.trackedWindow = { key: 'w', x: 1700, y: 600, width: 220, height: 400 }
const atLedgeEnd = Engine.tick(onLedge, def, ledgeWorld, rolls([0.5]))
assertEqual(atLedgeEnd.crossed, '', 'a pet on a window does not cross a screen edge')
assertEqual(onLedge.x, 1880, 'it stops at the end of the window it is standing on')

// Crossing forgets the window it was standing on, which belongs to the old
// monitor.
const carrier = Engine.createPet(def, leftward, { x: 1, y: 1040, animationId: 1 })
carrier.windowKey = 'stale'
carrier.trackedWindow = { key: 'stale', x: 0, y: 0, width: 10, height: 10 }
Engine.tick(carrier, def, leftward, rolls([0.5]))
assertEqual(carrier.windowKey, '', 'a pet lets go of its ledge when it changes monitor')

// Two screens, a pet walking left forever: it should end up somewhere sane on
// one of them rather than lost between the two.
const worlds = { 'DP-1': { ...petWorld, exits: plain.exits['DP-1'] }, 'DP-2': { ...petWorld, exits: plain.exits['DP-2'] } }
let where = 'DP-2'
const roamer = Engine.createPet(def, worlds[where], { x: 1000, y: 1040, animationId: 1 })
let crossings = 0
for (let i = 0; i < 3000; i++) {
  const outcome = Engine.tick(roamer, def, worlds[where], Math.random)
  if (outcome.crossed) { where = outcome.crossed; crossings++ }
  assertQuiet(roamer.x > -200 && roamer.x < worlds[where].width + 200,
    'a roaming pet stays near the screen it is on', `x: ${roamer.x} on ${where}`)
}
assert(crossings > 0, `a pet crossed between monitors ${crossings} times in 3000 steps`)

// ---- where the next pet appears --------------------------------------------

// Pets drift downhill: with roaming on they walk onto the screen with the lower
// floor and, until they climb back, stay there. Spawning every pet on whichever
// monitor happens to have focus therefore left the other screens empty. The
// next pet goes to the least crowded screen instead.
const twoScreens = Layout.layoutFor([
  { name: 'A', x: 0, y: 0, width: 1000, height: 1000 },
  { name: 'B', x: 1000, y: 0, width: 1000, height: 1000 }
], 'top', 0).areas

assertEqual(Layout.spawnScreen(twoScreens, {}, 'B'), 'B',
  'the first pet appears on the monitor you are looking at')
assertEqual(Layout.spawnScreen(twoScreens, { B: 1 }, 'B'), 'A',
  'the second one goes to the screen that has none')
assertEqual(Layout.spawnScreen(twoScreens, { A: 1, B: 1 }, 'B'), 'B',
  'and an even split puts the next one back where you are looking')
assertEqual(Layout.spawnScreen(twoScreens, { A: 3, B: 1 }, 'A'), 'B',
  'the least crowded screen wins over the focused one')

// A focused monitor the layout does not know about -- unplugged a moment ago --
// must not send the pet to a screen that is not there.
assertEqual(Layout.spawnScreen(twoScreens, {}, 'GONE'), 'A',
  'an unknown focused screen falls back to one that exists')
assertEqual(Layout.spawnScreen({}, {}, 'A'), '',
  'and no screens at all is answered honestly')

JS
} | node
