// The desktop pet's brain, kept free of QML and Wayland so it can be unit
// tested under node (test/engine-test.sh).
//
// A pet is a plain object walking a rectangular world in area-local pixels:
// (0, 0) is the top-left of the walkable area and `world.height` is the floor.
// Every decision the pet makes -- which animation follows this one, whether it
// just hit a border, whether the window it was standing on moved out from
// under it -- happens in `tick()`. The QML side only measures the world,
// paints the frame `tick()` asks for, and schedules the next call.
//
// The animation format is desktopPet's (https://github.com/Adrianotiger/desktopPet),
// converted to JSON by tools/build-pets.py. Behavior follows the Windows
// original: values are expressions re-evaluated when an animation starts,
// movement interpolates from `start` to `end` across the sequence, and each
// animation carries three sets of exits -- sequence end, border hit, and loss
// of ground -- each a weighted list filtered by where the pet currently is.

// Where the pet is, as a bitmask. `only="..."` on a <next> restricts that exit
// to a location; an exit without one is always eligible.
var ONLY = {
  NONE: 0x7F,
  TASKBAR: 0x01,
  WINDOW: 0x02,
  HORIZONTAL: 0x04,
  HORIZONTAL_PLUS: 0x06,
  VERTICAL: 0x08
}

function onlyMask(name) {
  switch (String(name === undefined || name === null ? "" : name).toLowerCase()) {
    case "taskbar": return ONLY.TASKBAR
    case "window": return ONLY.WINDOW
    case "horizontal": return ONLY.HORIZONTAL
    case "horizontal+": return ONLY.HORIZONTAL_PLUS
    case "vertical": return ONLY.VERTICAL
    default: return ONLY.NONE
  }
}

// ---------------------------------------------------------------- expressions
//
// Pet files write geometry as arithmetic over a handful of names:
// `areaH-imageH`, `random*(screenW-imageW-50)/100+25`. The Windows build hands
// those to DataTable.Compute and the web build to eval(); neither is something
// to run inside a long-lived shell process, so this is a small recursive
// descent parser over + - * / %, parentheses, and int().

// Pet files reuse the same handful of expression strings across hundreds of
// values ("0" alone appears 286 times in eSheep), and an animation change
// re-reads eleven of them. Tokenizing is therefore cached by source text; the
// cache is bounded by the distinct expressions in the loaded pet files.
var tokenCache = Object.create(null)

function tokenize(expression) {
  var source = String(expression === undefined || expression === null ? "" : expression)
  var cached = tokenCache[source]
  if (cached) return cached
  var tokens = []
  var i = 0
  while (i < source.length) {
    var c = source.charAt(i)
    if (c === " " || c === "\t" || c === "\n" || c === "\r") { i++; continue }
    if ("+-*/%(),".indexOf(c) !== -1) { tokens.push({ type: c }); i++; continue }
    if (c >= "0" && c <= "9" || c === ".") {
      var number = ""
      while (i < source.length && (source.charAt(i) >= "0" && source.charAt(i) <= "9" || source.charAt(i) === ".")) {
        number += source.charAt(i)
        i++
      }
      tokens.push({ type: "number", value: parseFloat(number) })
      continue
    }
    if (/[A-Za-z_]/.test(c)) {
      var name = ""
      // `System.Int32` shows up inside Convert() casts in a few community pets,
      // so a dot is part of a name rather than a syntax error.
      while (i < source.length && /[A-Za-z_0-9.]/.test(source.charAt(i))) {
        name += source.charAt(i)
        i++
      }
      tokens.push({ type: "name", value: name })
      // An expression with no names always evaluates to the same number, so
      // the result can be cached alongside the tokens.
      tokens.hasName = true
      continue
    }
    throw new Error("unexpected character '" + c + "' in expression: " + source)
  }
  tokenCache[source] = tokens
  return tokens
}

// A name the caller did not bind evaluates to 0, and throws in strict mode --
// which is how the asset test catches a typo in a new pet file.
function evaluate(expression, vars, strict) {
  var tokens = tokenize(expression)
  var position = 0
  // An omitted optional value (a <start> without <offsety>, say) is zero
  // rather than a parse error.
  if (tokens.length === 0) return 0
  if (!tokens.hasName && tokens.value !== undefined) return tokens.value

  function peek() { return position < tokens.length ? tokens[position] : null }
  function next() { return position < tokens.length ? tokens[position++] : null }

  function parsePrimary() {
    var token = next()
    if (!token) throw new Error("unexpected end of expression: " + expression)
    if (token.type === "number") return token.value
    if (token.type === "-") return -parsePrimary()
    if (token.type === "+") return parsePrimary()
    if (token.type === "(") {
      var inner = parseSum()
      var closing = next()
      if (!closing || closing.type !== ")") throw new Error("missing ')' in expression: " + expression)
      return inner
    }
    if (token.type === "name") {
      var upcoming = peek()
      if (upcoming && upcoming.type === "(") {
        next()
        var args = []
        if (peek() && peek().type !== ")") {
          args.push(parseSum())
          while (peek() && peek().type === ",") {
            next()
            args.push(parseSum())
          }
        }
        var end = next()
        if (!end || end.type !== ")") throw new Error("missing ')' after " + token.value + "()")
        return callFunction(token.value, args, expression, strict)
      }
      // A type name used as a bare argument (`Convert(x, System.Int32)`)
      // carries no value of its own.
      if (/^System\./.test(token.value)) return 0
      var value = vars ? vars[token.value] : undefined
      if (value === undefined || value === null) {
        if (strict) throw new Error("unknown name '" + token.value + "' in expression: " + expression)
        return 0
      }
      return typeof value === "function" ? Number(value()) : Number(value)
    }
    throw new Error("unexpected token '" + token.type + "' in expression: " + expression)
  }

  function parseProduct() {
    var value = parsePrimary()
    for (;;) {
      var token = peek()
      if (!token || (token.type !== "*" && token.type !== "/" && token.type !== "%")) return value
      next()
      var rhs = parsePrimary()
      if (token.type === "*") value = value * rhs
      else if (token.type === "/") value = rhs === 0 ? 0 : value / rhs
      else value = rhs === 0 ? 0 : value % rhs
    }
  }

  function parseSum() {
    var value = parseProduct()
    for (;;) {
      var token = peek()
      if (!token || (token.type !== "+" && token.type !== "-")) return value
      next()
      var rhs = parseProduct()
      value = token.type === "+" ? value + rhs : value - rhs
    }
  }

  var result = parseSum()
  if (position < tokens.length) throw new Error("trailing tokens in expression: " + expression)
  result = isFinite(result) ? result : 0
  if (!tokens.hasName) tokens.value = result
  return result
}

function callFunction(name, args, expression, strict) {
  var first = args.length > 0 ? args[0] : 0
  switch (String(name).toLowerCase()) {
    // `Convert(x, System.Int32)` is a .NET cast a few pets picked up from the
    // online editor; the extra argument is the target type.
    case "convert":
    case "int": return first < 0 ? Math.ceil(first) : Math.floor(first)
    case "abs": return Math.abs(first)
    case "round": return Math.round(first)
    case "min": return Math.min.apply(null, args)
    case "max": return Math.max.apply(null, args)
  }
  if (strict) throw new Error("unknown function '" + name + "' in expression: " + expression)
  return 0
}

// Scale a per-step movement, keeping a moving pet moving: rounding a single
// pixel down to nothing at half scale would freeze the slowest animations.
function scaleDelta(value, scale) {
  if (!value) return 0
  var scaled = value * scale
  var rounded = scaled < 0 ? -Math.round(-scaled) : Math.round(scaled)
  if (rounded === 0) return value < 0 ? -1 : 1
  return rounded
}

// Truncation toward zero, matching the (int) casts the original applies to
// every computed coordinate.
function toInt(value) {
  var number = Number(value)
  if (!isFinite(number)) return 0
  return number < 0 ? Math.ceil(number) : Math.floor(number)
}

// The variable bindings an expression sees. `random` is redrawn on every
// evaluation, `randS` stays fixed for the life of a spawn, and the image and
// screen names describe the pet and the area it lives in.
function variablesFor(world, pet) {
  var random = world && typeof world.random === "function" ? world.random : Math.random
  return {
    screenW: world.width,
    screenH: world.height,
    areaW: world.width,
    areaH: world.height,
    imageW: world.imageWidth,
    imageH: world.imageHeight,
    imageX: pet ? pet.x : 0,
    imageY: pet ? pet.y : 0,
    scale: world.scale === undefined ? 1 : world.scale,
    randS: world.randS === undefined ? 0 : world.randS,
    random: function() { return Math.floor(random() * 100) }
  }
}

// ------------------------------------------------------------------ selection

function pickWeighted(entries, roll) {
  if (!entries || entries.length === 0) return null
  var total = 0
  var i
  for (i = 0; i < entries.length; i++) total += Math.max(0, Number(entries[i].probability) || 0)
  if (total <= 0) return entries[0]
  var target = roll * total
  var sum = 0
  for (i = 0; i < entries.length; i++) {
    sum += Math.max(0, Number(entries[i].probability) || 0)
    if (sum >= target) return entries[i]
  }
  return entries[entries.length - 1]
}

// Pick one exit from a <next> list, honoring `only=` against where the pet is.
// Returns -1 when the list has nothing eligible, which is the signal to
// respawn (or, for a child, to disappear).
function pickNext(entries, where, random) {
  if (!entries || entries.length === 0) return -1
  var eligible = []
  for (var i = 0; i < entries.length; i++) {
    var mask = onlyMask(entries[i].only)
    if (mask !== ONLY.NONE && (mask & where) === 0) continue
    eligible.push(entries[i])
  }
  var chosen = pickWeighted(eligible, random())
  return chosen ? Number(chosen.id) : -1
}

function pickSpawn(def, random) {
  return pickWeighted(def.spawns || [], random())
}

// ------------------------------------------------------------------ sequences

// Resolve one animation's expressions into numbers. The original re-evaluates
// them every time an animation starts, which is what makes `repeat` values
// like "random/10+20" vary from one walk to the next.
function resolveAnimation(def, animationId, world, pet) {
  var animation = def.animations[String(animationId)]
  if (!animation) return null
  var vars = variablesFor(world, pet)
  var sequence = animation.sequence || {}
  var frames = sequence.frames || []
  var repeatFrom = Math.max(0, Number(sequence.repeatFrom) || 0)
  var repeat = Math.max(0, toInt(evaluate(sequence.repeat, vars)))

  // Faithful to the original's two branches: repeating from a later frame
  // drops one frame per lap, repeating from the top does not.
  var totalSteps = repeatFrom > 0
    ? frames.length + (frames.length - repeatFrom - 1) * repeat
    : frames.length + frames.length * repeat

  // A missing <end> holds the <start> values, which is how the original
  // reader treats an animation that does not accelerate.
  function step(which) {
    var values = animation[which] || animation.start || {}
    function value(name, fallback) {
      var raw = values[name]
      return raw === undefined || raw === null || raw === "" ? fallback : raw
    }
    return {
      x: toInt(evaluate(value("x", "0"), vars)),
      y: toInt(evaluate(value("y", "0"), vars)),
      interval: Math.max(1, toInt(evaluate(value("interval", "1000"), vars))),
      offsetY: toInt(evaluate(value("offsetY", "0"), vars)),
      opacity: evaluate(value("opacity", "1.0"), vars)
    }
  }

  return {
    id: Number(animation.id),
    name: animation.name || "",
    start: step("start"),
    end: step("end"),
    frames: frames,
    repeatFrom: repeatFrom,
    totalSteps: Math.max(1, totalSteps),
    action: sequence.action || "",
    next: sequence.next || [],
    border: animation.border || [],
    gravity: animation.gravity || []
  }
}

// Which tile the sequence shows at this step, including the repeat window.
//
// The wrap is upstream's arithmetic, quirk and all: repeating from a later
// frame replays the tail back-to-front on the first lap. Eight of eSheep's
// animations were drawn against that behavior, so matching it matters more
// than tidying it.
function frameAt(resolved, step) {
  var frames = resolved.frames
  if (frames.length === 0) return 0
  if (step < frames.length) return frames[Math.max(0, step)]
  var window = frames.length - resolved.repeatFrom
  if (window <= 0) return frames[frames.length - 1]
  return frames[((step - frames.length + resolved.repeatFrom) % window) + resolved.repeatFrom]
}

// Interval, opacity and offset run across the whole sequence; movement runs
// across one step fewer, so the last step lands exactly on the end value.
function interpolate(from, to, step, totalSteps) {
  if (totalSteps <= 0) return from
  return from + (to - from) * step / totalSteps
}

function stepValues(resolved, step) {
  var total = resolved.totalSteps
  return {
    interval: Math.max(1, Math.round(interpolate(resolved.start.interval, resolved.end.interval, step, total))),
    opacity: interpolate(resolved.start.opacity, resolved.end.opacity, step, total),
    offsetY: interpolate(resolved.start.offsetY, resolved.end.offsetY, step, total)
  }
}

function movementFor(resolved, step) {
  var x = resolved.start.x
  var y = resolved.start.y
  if (resolved.totalSteps > 1) {
    var span = resolved.totalSteps - 1
    x += (resolved.end.x - resolved.start.x) * step / span
    y += (resolved.end.y - resolved.start.y) * step / span
  }
  return { x: toInt(x), y: toInt(y) }
}

// --------------------------------------------------------------------- world

// The doorway on one edge that a span of `size` at `pos` may pass through.
//
// `world.exits` comes from Layout, which owns the doorway's shape: each exit
// carries the span of the shared edge with a walkable neighbour behind it, so
// the only question left here is whether the pet is inside one.
//
// `strict` asks for the whole sprite inside the span rather than merely
// touching it. Both crossings ask the same question of the same list and
// differ only in how much of the pet has to be through the door, so they share
// the walk and part on that one term.
function exitAcross(world, edge, pos, size, strict) {
  var candidates = world.exits ? world.exits[edge] : null
  if (!candidates) return null
  for (var i = 0; i < candidates.length; i++) {
    var span = candidates[i].span
    var fits = strict
      ? pos >= span.start && pos + size <= span.end
      : pos + size > span.start && pos < span.end
    if (fits) return candidates[i]
  }
  return null
}

// What lies past one edge of this monitor, for a pet walking into it. Touching
// the doorway is enough: the pet is already moving through.
function exitFor(world, edge, pet) {
  return edge === "up"
    ? exitAcross(world, edge, pet.x, world.imageWidth, false)
    : exitAcross(world, edge, pet.y, world.imageHeight, false)
}

// The doorway a pet climbing the side of its screen may step through, for a
// sprite whose top would be at `y`.
//
// Stricter, because the pet is arriving sideways onto a floor rather than
// carrying on through: the whole sprite has to fit inside the neighbour's
// span. A span ends at the neighbour's floor, so the highest position that
// passes is exactly that floor -- the pet arrives standing on the ground
// rather than hanging in the air beside it.
function climbExitFor(world, edge, y) {
  return exitAcross(world, edge, y, world.imageHeight, true)
}

// Which side of its screen the pet is climbing, if either. `wall` is the same
// pair of edges the sideways check is bounded by, so there is one notion of
// where the world stops. The border handler snaps a pet that walks into a wall
// flush against it, so a climb that follows keeps it there.
function climbingEdge(wall, pet, imageWidth) {
  if (pet.x <= wall.left) return "left"
  if (pet.x + imageWidth >= wall.right) return "right"
  return ""
}

// Step through: the pet holds its place in the world and has it re-expressed
// in the monitor it is arriving on. Arrival is only a translation -- landing
// on the new monitor's floor, or falling to it, is the ordinary floor and
// gravity machinery's job on the next tick.
function crossInto(pet, exit, dx, dy) {
  pet.x += dx + exit.dx
  pet.y += dy + exit.dy
  pet.screen = exit.screen
  pet.animationStep++
  // Whatever it was standing on belongs to the monitor it just left.
  pet.windowKey = ""
  pet.trackedWindow = null
  return exit.screen
}

function windowByKey(world, key) {
  var windows = world.windows || []
  for (var i = 0; i < windows.length; i++) if (windows[i].key === key) return windows[i]
  return null
}

// The window the pet would see if it looked straight down at (x, y): the
// front-most one covering that point. `stacking` is a front-to-back rank, so
// the smallest one wins.
function topWindowAt(world, x, y) {
  var windows = world.windows || []
  var best = null
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    if (x < w.x || x > w.x + w.width) continue
    if (y < w.y || y > w.y + w.height) continue
    if (!best || Number(w.stacking || 0) < Number(best.stacking || 0)) best = w
  }
  return best
}

// A window whose top edge the pet crosses while falling `dy` pixels this step.
// The pet may hang half off either side -- the original allows a half sprite of
// overhang -- and never lands on something in the top 20px of the area, which
// keeps it off windows that are flush with the top of the screen.
function landingWindow(world, pet, dy) {
  if (!world.walkOnWindows) return null
  var footY = pet.y + world.imageHeight
  var windows = world.windows || []
  var best = null
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    if (footY >= w.y || footY + dy < w.y) continue
    if (pet.x < w.x - world.imageWidth / 2) continue
    if (pet.x + world.imageWidth > w.x + w.width + world.imageWidth / 2) continue
    if (pet.y <= 20) continue
    if (!best || w.y < best.y) best = w
  }
  if (!best) return null
  // Landing on a window that something else covers would put the pet on a
  // ledge it cannot see.
  var front = topWindowAt(world, pet.x + world.imageWidth / 2, best.y + 1)
  if (front && front.key !== best.key) return null
  return best
}

// Is the pet still standing on this window, or has it walked off the end?
function standingOn(world, pet, w) {
  if (!w) return false
  if (pet.x + world.imageWidth < w.x) return false
  if (pet.x > w.x + w.width) return false
  var front = topWindowAt(world, pet.x + world.imageWidth / 2, w.y + 1)
  return !front || front.key === w.key
}

// -------------------------------------------------------------------- spawning

// Place a pet according to one of the pet file's <spawn> entries. `randS` is
// drawn here because the format promises it stays put until the next spawn.
function spawn(def, world, pet, random) {
  var chosen = pickSpawn(def, random)
  if (!chosen) return null
  world.randS = Math.floor(random() * 100)
  var vars = variablesFor(world, pet)
  var placed = {
    x: toInt(evaluate(chosen.x, vars)),
    y: toInt(evaluate(chosen.y, vars)),
    animationId: pickNext(chosen.next, ONLY.NONE, random)
  }
  if (placed.animationId < 0) placed.animationId = firstAnimationId(def)
  return placed
}

function firstAnimationId(def) {
  var ids = Object.keys(def.animations || {})
  return ids.length > 0 ? Number(ids[0]) : -1
}

function specialAnimation(def, name, fallback) {
  var special = def.special || {}
  var id = special[name]
  return id === undefined || id === null ? fallback : Number(id)
}

// Children are separate pets a parent brings along for one animation (the
// sheep dragged in by a rope, the one that walks in from the other side).
// A flipped parent mirrors the child's offset so it appears on the correct
// side, which is why `imageW` flips sign here.
function childrenFor(def, animationId, world, pet) {
  var out = []
  var childs = def.childs || []
  for (var i = 0; i < childs.length; i++) {
    var child = childs[i]
    if (Number(child.animationId) !== Number(animationId)) continue
    var vars = variablesFor(world, pet)
    out.push({
      x: toInt(evaluate(mirrorIfFlipped(child.x, pet.flipped), vars)),
      y: toInt(evaluate(mirrorIfFlipped(child.y, pet.flipped), vars)),
      animationId: Number(child.next),
      flipped: !pet.flipped
    })
  }
  return out
}

function mirrorIfFlipped(expression, flipped) {
  var text = String(expression === undefined || expression === null ? "0" : expression)
  if (!flipped) return text
  if (text.indexOf("-imageW") !== -1) return text.split("-imageW").join("+imageW")
  return text.split("imageW").join("(0-imageW)")
}

// ------------------------------------------------------------------ the tick
//
// One animation step. `pet` is updated in place; the return value tells the
// caller what to paint, when to come back, and whether anything was born or
// died along the way.

function beginAnimation(pet, def, world, animationId) {
  var resolved = resolveAnimation(def, animationId, world, pet)
  if (!resolved) return null
  pet.animationId = resolved.id
  pet.animationStep = 0
  pet.resolved = resolved
  return resolved
}

function respawn(pet, def, world, random) {
  var placed = spawn(def, world, pet, random)
  if (!placed) return null
  pet.x = placed.x
  pet.y = placed.y
  pet.windowKey = ""
  pet.flipped = false
  return beginAnimation(pet, def, world, placed.animationId)
}

// Starting over: a parent gets a fresh spawn, a child (or a pet on its way
// out) is simply gone. Every path that runs out of animations lands here.
function restart(pet, def, world, random, result) {
  if (pet.isChild || pet.leaving || !respawn(pet, def, world, random)) {
    result.dead = true
    return result
  }
  result.respawned = true
  result.frame = frameAt(pet.resolved, 0)
  result.interval = pet.resolved.start.interval
  return result
}

// Well past the edge of the world in any direction. The margin is three
// sprites, which is far enough that a pet deliberately walking off screen gets
// to finish the walk before it is recycled.
function outOfWorld(pet, world) {
  var marginX = world.imageWidth * 3
  var marginY = world.imageHeight * 3
  return pet.x + world.imageWidth < -marginX
    || pet.x > world.width + marginX
    || pet.y + world.imageHeight < -marginY
    || pet.y > world.height + marginY
}

function tick(pet, def, world, random) {
  random = random || Math.random
  var result = { interval: 100, frame: 0, opacity: 1, offsetY: 0, children: [], respawned: false, dead: false, crossed: "" }

  var resolved = pet.resolved
  if (!resolved || resolved.id !== pet.animationId) {
    resolved = resolveAnimation(def, pet.animationId, world, pet)
    if (!resolved) return restart(pet, def, world, random, result)
    pet.resolved = resolved
  }

  // Movement is authored for a 1:1 sprite, so a magnified pet has to cover
  // proportionally more ground or it crawls. Everything tick() reports back is
  // in the same magnified, area-local pixels the pet walks in.
  var moveScale = world.scale === undefined ? 1 : world.scale

  result.frame = frameAt(resolved, pet.animationStep)
  var values = stepValues(resolved, pet.animationStep)
  result.interval = values.interval
  result.opacity = values.opacity
  result.offsetY = values.offsetY * moveScale

  // While the pointer holds the pet, the drag animation plays in place and the
  // caller owns the position.
  if (pet.dragging) {
    pet.animationStep++
    result.interval = 50
    return result
  }

  // The floor is solid: nothing is ever below it. Crossing onto a monitor
  // whose floor sits higher, or any other odd arrival, settles here rather
  // than each producer of positions clamping for itself.
  var solidFloor = world.height - world.imageHeight
  if (pet.y > solidFloor) pet.y = solidFloor

  var move = movementFor(resolved, pet.animationStep)
  var dx = scaleDelta(pet.flipped ? -move.x : move.x, moveScale)
  var dy = scaleDelta(move.y, moveScale)

  var startedNew = false
  var escaping = false

  function start(animationId) {
    if (animationId < 0) return false
    // A pet that has said goodbye takes no new animation: a border or gravity
    // exit mid-farewell would leave it walking around dismissed.
    if (pet.leaving) return false
    var next = beginAnimation(pet, def, world, animationId)
    if (!next) return false
    resolved = next
    startedNew = true
    var born = childrenFor(def, animationId, world, pet)
    for (var i = 0; i < born.length; i++) result.children.push(born[i])
    return true
  }

  // Nothing underfoot. The floor is the bottom of the area; the ledge is
  // whichever window the pet is standing on.
  function applyGravity(dy) {
    var floorY = world.height - world.imageHeight
    if (!pet.windowKey) {
      if (pet.y + dy >= floorY) return dy
      // Three pixels of slack: a pet a hair above the floor settles onto it
      // instead of starting a fall.
      if (pet.y + dy + 3 >= floorY) return floorY - pet.y
      start(pickNext(resolved.gravity, ONLY.NONE, random))
      return dy
    }

    var current = windowByKey(world, pet.windowKey)
    var moved = !!(current && pet.trackedWindow && windowMoved(pet.trackedWindow, current))
    // A window that moved carries a walking pet along; one that vanished, or
    // that the pet has walked off, drops it.
    if (moved && resolved.start.x !== 0) {
      pet.x += current.x - pet.trackedWindow.x
      pet.y += current.y - pet.trackedWindow.y
      return dy
    }
    if (current && !moved && standingOn(world, pet, current)) return dy
    pet.windowKey = ""
    start(pickNext(resolved.gravity, ONLY.WINDOW, random))
    return dy
  }

  // ---- horizontal borders: the pet is walled in by the window it stands on,
  //      or by the sides of the area when it is on the floor.
  var standing = pet.windowKey ? windowByKey(world, pet.windowKey) : null
  if (pet.windowKey && !standing) pet.windowKey = ""

  var wall = standing
    ? { only: ONLY.WINDOW, left: standing.x, right: standing.x + standing.width }
    : { only: ONLY.VERTICAL, left: 0, right: world.width }

  if (dx !== 0) {
    var pastWall = dx < 0
      ? pet.x + dx < wall.left
      : pet.x + dx + world.imageWidth > wall.right
    if (pastWall) {
      // A screen edge with a monitor behind it is a doorway, not a wall.
      var doorway = standing ? null : exitFor(world, dx < 0 ? "left" : "right", pet)
      if (doorway) {
        result.crossed = crossInto(pet, doorway, dx, 0)
        return result
      }
      if (start(pickNext(resolved.border, wall.only, random))) {
        pet.x = dx < 0 ? wall.left : wall.right - world.imageWidth
        dx = 0
      } else if (standing) {
        // Nothing up here turns it around, so it walks off the end.
        pet.windowKey = ""
      } else {
        escaping = true
      }
    }
  }

  // ---- vertical borders: the floor (Omarchy has no taskbar to stand on, so
  //      the bottom of the walkable area is the ground), the top edge, and the
  //      top edge of any window in the way.
  if (!startedNew && !escaping) {
    if (dy > 0) {
      if (pet.y + dy > world.height - world.imageHeight) {
        if (start(pickNext(resolved.border, ONLY.TASKBAR, random))) {
          pet.y = world.height - world.imageHeight
          result.offsetY = 0
          dy = 0
        }
      } else {
        var landing = landingWindow(world, pet, dy)
        if (landing && start(pickNext(resolved.border, ONLY.WINDOW, random))) {
          pet.y = landing.y - world.imageHeight
          pet.windowKey = landing.key
          result.offsetY = 0
          dy = 0
          // An animation that was already falling hands the pet back to
          // gravity rather than gluing it to this window.
          if (resolved.start.y !== 0) pet.windowKey = ""
        }
      }
    } else if (dy < 0) {
      // Climbing the seam. The sideways check only fires while the pet is
      // moving sideways, and there is no screen beside a pet standing on the
      // floor of the taller of two screens -- so without this a pet could only
      // ever reach a neighbour whose floor was level with or below its own, and
      // the lowest screen became somewhere pets went and never left. A pet
      // holding on to a window is climbing that, not the screen.
      var edge = pet.windowKey ? "" : climbingEdge(wall, pet, world.imageWidth)
      var landing = edge ? climbExitFor(world, edge, pet.y + dy) : null
      if (landing) {
        result.crossed = crossInto(pet, landing, 0, dy)
        return result
      }
      if (pet.y + dy < 0) {
        var skylight = exitFor(world, "up", pet)
        if (skylight) {
          result.crossed = crossInto(pet, skylight, 0, dy)
          return result
        }
        if (start(pickNext(resolved.border, ONLY.HORIZONTAL, random))) { pet.y = 0; dy = 0 }
        else escaping = true
      }
    }
  }

  // ---- sequence over, or nothing left to hold the pet up
  if (pet.animationStep >= resolved.totalSteps) {
    if (resolved.action === "flip") pet.flipped = !pet.flipped
    // The goodbye is over.
    if (pet.leaving) { result.dead = true; return result }

    var where = ONLY.NONE
    if (pet.windowKey) where = ONLY.WINDOW
    else if (pet.y + world.imageHeight + dy >= world.height - 2) where = ONLY.TASKBAR

    var nextId = outOfWorld(pet, world) ? -1 : pickNext(resolved.next, where, random)
    if (!start(nextId)) return restart(pet, def, world, random, result)
  } else if (resolved.gravity && resolved.gravity.length > 0) {
    dy = applyGravity(dy)
  }

  if (startedNew) {
    result.interval = 1
    result.frame = frameAt(resolved, 0)
    result.offsetY = resolved.start.offsetY * moveScale
    result.opacity = resolved.start.opacity
  }

  pet.x += dx
  pet.y += dy
  // A fresh animation is already sitting on its first step: the original
  // rewinds the counter when it switches, so the next tick draws step 0 with
  // the new animation's own interval.
  if (!startedNew) pet.animationStep++
  pet.trackedWindow = pet.windowKey ? cloneRect(windowByKey(world, pet.windowKey)) : null

  // A pet that wandered well past the edge without an exit animation gets a
  // fresh spawn rather than walking to infinity.
  if (!result.dead && outOfWorld(pet, world)) return restart(pet, def, world, random, result)

  return result
}

function windowMoved(before, now) {
  return before.x !== now.x || before.y !== now.y || before.width !== now.width
}

function cloneRect(w) {
  return w ? { key: w.key, x: w.x, y: w.y, width: w.width, height: w.height } : null
}

// A fresh pet, placed by the pet file's own spawn rules.
function createPet(def, world, options) {
  var random = (world && typeof world.random === "function") ? world.random : Math.random
  var pet = {
    x: 0,
    y: 0,
    // Which monitor's area the coordinates are measured in. Opaque to the
    // engine beyond being carried across a crossing; the caller names it.
    screen: options && options.screen ? String(options.screen) : "",
    animationId: -1,
    animationStep: 0,
    flipped: false,
    dragging: false,
    leaving: false,
    windowKey: "",
    trackedWindow: null,
    isChild: !!(options && options.isChild),
    resolved: null
  }
  if (options && options.animationId !== undefined) {
    pet.x = options.x || 0
    pet.y = options.y || 0
    pet.flipped = !!(options && options.flipped)
    beginAnimation(pet, def, world, options.animationId)
  } else {
    respawn(pet, def, world, random)
  }
  return pet
}

// Pick up the pet: the drag animation plays until the pointer lets go.
function grab(pet, def, world) {
  pet.dragging = true
  pet.windowKey = ""
  pet.trackedWindow = null
  beginAnimation(pet, def, world, specialAnimation(def, "drag", pet.animationId))
}

// Let go: the pet falls from wherever it was dropped.
function release(pet, def, world) {
  pet.dragging = false
  beginAnimation(pet, def, world, specialAnimation(def, "fall", pet.animationId))
}

// How long a goodbye is allowed to take. `repeat` comes out of the pet file, so
// without a ceiling a farewell could run for minutes with the pet already
// counted as gone; by time rather than by steps, so every farewell any real pet
// file authors (0.6s to 3.5s across the ones shipped here) plays out in full.
var FAREWELL_BUDGET_MS = 5000

// Send the pet away. It plays the farewell animation from its file and stops
// accepting new ones, so the next sequence end is the end of the pet. Returns
// false when the file has no farewell, and the caller can drop it immediately.
function dismiss(pet, def, world) {
  pet.leaving = true
  var kill = specialAnimation(def, "kill", -1)
  if (kill < 0 || !beginAnimation(pet, def, world, kill)) return false

  var resolved = pet.resolved
  var perStep = Math.max(1, (resolved.start.interval + resolved.end.interval) / 2)
  resolved.totalSteps = Math.max(
    resolved.frames.length,
    Math.min(resolved.totalSteps, Math.ceil(FAREWELL_BUDGET_MS / perStep))
  )
  return true
}

if (typeof module !== "undefined") {
  // The QML side calls createPet/tick/grab/release/dismiss; the rest is
  // exported for the tests, which check the pieces individually.
  module.exports = {
    ONLY: ONLY,
    onlyMask: onlyMask,
    evaluate: evaluate,
    scaleDelta: scaleDelta,
    variablesFor: variablesFor,
    pickWeighted: pickWeighted,
    pickNext: pickNext,
    resolveAnimation: resolveAnimation,
    frameAt: frameAt,
    stepValues: stepValues,
    topWindowAt: topWindowAt,
    landingWindow: landingWindow,
    climbExitFor: climbExitFor,
    outOfWorld: outOfWorld,
    createPet: createPet,
    tick: tick,
    grab: grab,
    release: release,
    dismiss: dismiss
  }
}
