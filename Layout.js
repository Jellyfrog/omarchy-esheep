// Where a pet may walk, and where one monitor's floor leads to the next.
//
// Kept free of QML for the same reason as Engine.js: the interesting part is
// arithmetic over monitor rectangles, and that is worth testing against real
// layouts (side by side, stacked, mismatched heights, a gap in the middle)
// rather than by plugging in a second screen and squinting.
//
// Two coordinate spaces appear here. Screens and areas are in the compositor's
// layout coordinates -- what Hyprland calls the monitor's position. A pet walks
// in *area-local* coordinates: (0, 0) is the top-left of its own monitor's
// walkable area. An exit carries the translation between one area's coordinates
// and its neighbour's, which is all the pet needs to keep walking across the
// seam.

// How far apart two screen edges may be and still count as touching. Monitor
// positions are whole layout pixels, so this only absorbs the odd rounding.
var GAP = 4

// The part of a screen a pet is allowed to walk: the whole thing, less the
// strip the Omarchy bar occupies. Omarchy has no taskbar along the bottom, so
// unless the bar is down there, the bottom of the screen is the floor.
function areaFor(screen, barEdge, barStrip) {
  var area = { x: screen.x, y: screen.y, width: screen.width, height: screen.height }
  if (!(barStrip > 0)) return area
  if (barEdge === "top") { area.y += barStrip; area.height -= barStrip }
  else if (barEdge === "bottom") { area.height -= barStrip }
  else if (barEdge === "left") { area.x += barStrip; area.width -= barStrip }
  else if (barEdge === "right") { area.width -= barStrip }
  return area
}

function overlaps(aStart, aSize, bStart, bSize) {
  return bStart < aStart + aSize && bStart + bSize > aStart
}

function touches(edge, other) {
  return Math.abs(edge - other) <= GAP
}

// One doorway out of a monitor, described in the coordinates of the monitor
// being left: `dx`/`dy` translate a position from this area into the
// neighbour's, and `span` is the doorway's extent along the shared edge --
// the stretch of that edge with the neighbour's walkable area behind it. The
// engine only asks "is the pet inside the span"; the doorway's shape has one
// owner, here.
//
// Adjacency is decided on the screens rather than the areas, because a bar
// down one side insets every monitor's area and would otherwise leave a
// bar-wide canyon between two screens that are physically touching.
function exitBetween(from, to, axis) {
  var dx = from.area.x - to.area.x
  var dy = from.area.y - to.area.y
  return {
    screen: to.name,
    dx: dx,
    dy: dy,
    span: axis === "x"
      ? { start: -dx, end: -dx + to.area.width }
      : { start: -dy, end: -dy + to.area.height }
  }
}

// The walkable areas of every screen, plus what lies past each of their edges.
//
// `screens` is a list of { name, x, y, width, height } in layout coordinates --
// Quickshell's screen objects pass straight in; the copy into plain numbers
// happens here and nowhere else. Only sideways and upward exits are produced:
// the bottom of a screen is the ground a pet stands on, so there is no walking
// down through it.
function layoutFor(screens, barEdge, barStrip) {
  var list = []
  var areas = {}
  var exits = {}
  var i

  for (i = 0; i < screens.length; i++) {
    var screen = screens[i]
    if (!screen || !screen.name) continue
    var entry = {
      name: String(screen.name),
      x: Number(screen.x),
      y: Number(screen.y),
      width: Number(screen.width),
      height: Number(screen.height),
      area: areaFor(screen, barEdge, barStrip)
    }
    if (!(entry.area.width > 0) || !(entry.area.height > 0)) continue
    list.push(entry)
    areas[entry.name] = entry.area
    exits[entry.name] = { left: [], right: [], up: [] }
  }

  for (i = 0; i < list.length; i++) {
    var mine = list[i]
    for (var j = 0; j < list.length; j++) {
      if (i === j) continue
      var other = list[j]

      // Side by side, and sharing some height: two screens that touch only at
      // a corner are not a doorway.
      if (overlaps(mine.y, mine.height, other.y, other.height)) {
        if (touches(mine.x + mine.width, other.x)) exits[mine.name].right.push(exitBetween(mine, other, "y"))
        if (touches(other.x + other.width, mine.x)) exits[mine.name].left.push(exitBetween(mine, other, "y"))
      }

      // Stacked, and sharing some width. Only upward: a pet climbing the top
      // edge carries on onto the screen above, while the floor stays solid.
      if (overlaps(mine.x, mine.width, other.x, other.width)) {
        if (touches(other.y + other.height, mine.y)) exits[mine.name].up.push(exitBetween(mine, other, "x"))
      }
    }

    // Top to bottom (left to right for skylights), so a pet on a seam shared
    // by two neighbours meets them in a stable, geometric order.
    var bySpan = function(a, b) { return a.span.start - b.span.start }
    exits[mine.name].left.sort(bySpan)
    exits[mine.name].right.sort(bySpan)
    exits[mine.name].up.sort(bySpan)
  }

  return { areas: areas, exits: exits }
}

// Which screen the next pet should appear on.
//
// The least crowded one, rather than whichever monitor happens to have focus.
// Pets drift downhill -- roaming carries them onto the screen with the lower
// floor, and they only come back by climbing the seam -- so spawning every pet
// in one place left the other screens empty. Ties go to `preferred`, which
// keeps the first pet turning up where you are looking.
function spawnScreen(areas, counts, preferred) {
  var names = []
  for (var name in areas) names.push(name)
  if (names.length === 0) return ""
  names.sort()
  var best = names.indexOf(preferred) !== -1 ? preferred : names[0]
  var least = counts && counts[best] ? counts[best] : 0
  for (var i = 0; i < names.length; i++) {
    var here = counts && counts[names[i]] ? counts[names[i]] : 0
    if (here < least) { best = names[i]; least = here }
  }
  return best
}

// Which screen a point falls on, for dropping a dragged pet.
function screenAt(areas, x, y) {
  for (var name in areas) {
    var area = areas[name]
    if (x >= area.x && x < area.x + area.width && y >= area.y && y < area.y + area.height) return name
  }
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    areaFor: areaFor,
    layoutFor: layoutFor,
    spawnScreen: spawnScreen,
    screenAt: screenAt
  }
}
