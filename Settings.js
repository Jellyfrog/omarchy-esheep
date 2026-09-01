// Reading and writing the plugin's slice of ~/.config/omarchy/shell.json.
//
// Omarchy stores a plugin's settings inline on the one entry that enables it:
// a bar layout entry for a bar widget, or an entry in `plugins[]` for
// everything else. Both the pet overlay and the bar widget need the same
// values, so the lookup lives here rather than in either of them.

var MAX_PETS = 12

var DEFAULTS = {
  // Folder name under assets/.
  pet: "esheep",
  // How many pets walk around. Children they bring along are extra.
  count: 1,
  // Sprite magnification. The sheep is drawn at 40x40, which is small on a
  // large or high-density screen.
  scale: 1,
  // Multiplies the animation speed; 2 is a pet in a hurry.
  speed: 1,
  // Land on and walk along the top edge of Hyprland windows.
  walkOnWindows: true,
  // Get out of the way when something goes fullscreen.
  hideOnFullscreen: true,
  // Let animations bring in the extra pets they were drawn with.
  allowChildren: true,
  // Treat the Omarchy bar as the edge of the world instead of walking under it.
  avoidBar: true,
  // Walk from one monitor onto the next where they touch, instead of turning
  // around at the edge of the screen the pet spawned on.
  roamMonitors: true,
  // Keep each pet on the workspace it spawned on, instead of floating over
  // every workspace the way a layer-shell surface does by default.
  lockToWorkspace: true
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// Where in shell.json this plugin's entry lives, if anywhere.
function entryFor(config, id) {
  if (!isPlainObject(config)) return null
  var key = String(id)
  var sections = ["left", "center", "right"]
  var bar = isPlainObject(config.bar) ? config.bar : null
  var layout = bar && isPlainObject(bar.layout) ? bar.layout : null
  for (var s = 0; s < sections.length; s++) {
    var entries = layout ? layout[sections[s]] : null
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      if (isPlainObject(entries[i]) && String(entries[i].id) === key) return entries[i]
    }
  }
  if (Array.isArray(config.plugins)) {
    for (var j = 0; j < config.plugins.length; j++) {
      if (isPlainObject(config.plugins[j]) && String(config.plugins[j].id) === key) return config.plugins[j]
    }
  }
  return null
}

// A pet id doubles as a directory name under assets/, and it arrives from
// places anything on the machine can write: `omarchy bar set`, a hand-edited
// shell.json. Only a plain folder name may pass -- the same shape the
// converter's slugify produces -- so "../../../somewhere" never reaches
// Qt.resolvedUrl. Mirrors the shell's own PluginRegistry entry-point check.
function safePetId(value, fallback) {
  var id = String(value === undefined || value === null ? "" : value)
  return /^[a-z0-9][a-z0-9-]*$/.test(id) ? id : fallback
}

// `omarchy bar set <id> <key> <value>` is how this plugin is scripted, and the
// shell stores a bare value as the JSON string it parsed unless the caller
// remembers --json. So "false" turns up where false was meant. Reading it as
// the non-empty string it is would leave the setting on and the command
// reporting success while doing nothing -- the worst way for a setting to
// fail, since there is nothing to see.
//
// The accepted spellings are the shell's own, from Style.boolToken: whatever
// Omarchy reads as off anywhere else has to read as off here too, or the
// silence just moves to a different word. Anything not on the list falls back,
// the way an out-of-range number does.
function toBool(value, fallback) {
  if (value === true || value === false) return value
  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  return fallback
}

// The same suspicion for a file name out of parsed JSON: a plain name with no
// separators, or the fallback. The regex admits no '/' or '\\', so nothing
// that passes can traverse.
function safeFileName(value, fallback) {
  var name = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) ? name : fallback
}

// 1.0.0 kept a separate on/off flag beside the count. Anything still carrying
// it is translated once, here, on the way in: switched off means a count of
// none, and the key is dropped so nothing downstream has to know the old name.
//
// This runs on the stored entry only. Folding it in anywhere further down would
// let a retired flag override what a caller is asking for right now.
function migrate(entry) {
  if (!isPlainObject(entry) || entry.enabled === undefined) return entry
  var out = {}
  for (var key in entry) if (key !== "enabled") out[key] = entry[key]
  if (entry.enabled === false) out.count = 0
  return out
}

// The workspace lock and monitor roaming pull against each other: a pet that
// walks onto the next monitor joins whatever workspace that monitor is
// showing, so it cannot also stay on the one it appeared on. The lock wins.
//
// Said here once, so the panel that greys the roaming toggle out and the
// overlay that decides where a pet may walk cannot drift apart -- and said
// about the values rather than about the stored entry, so a shell.json that
// was never touched obeys it too.
function roamingPermitted(values) {
  return !toBool(values ? values.lockToWorkspace : undefined, DEFAULTS.lockToWorkspace)
}

// Whether pets actually roam: the stored setting, once the lock has had its
// say. Both halves ask this rather than pairing the setting with the rule
// themselves, so the toggle cannot show one answer while the pets walk another.
function roamingOn(values) {
  return toBool(values ? values.roamMonitors : undefined, DEFAULTS.roamMonitors)
    && roamingPermitted(values)
}

// The count that means on, or off. On is a floor of one rather than a memory:
// the count you had is deliberately not restored, so there is no shadow copy of
// it to keep in step. Every switch -- the panel, the bar button, the pet
// picker -- asks here rather than restating it.
function countFor(on, current) {
  return on ? Math.max(1, Math.round(clampNumber(current, 0, MAX_PETS, 0))) : 0
}

function clampNumber(value, low, high, fallback) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.min(high, Math.max(low, number))
}

// One stored entry merged over the defaults, with every value clamped to
// something the pet can actually live with. A hand-edited shell.json is a
// normal way to configure Omarchy, so nothing here trusts its input.
function normalize(entry) {
  if (!isPlainObject(entry)) entry = {}
  var values = {}
  for (var key in DEFAULTS) {
    var value = entry[key] === undefined || entry[key] === null ? DEFAULTS[key] : entry[key]
    values[key] = typeof DEFAULTS[key] === "boolean" ? toBool(value, DEFAULTS[key]) : value
  }
  values.pet = safePetId(values.pet, DEFAULTS.pet)
  values.count = Math.round(clampNumber(values.count, 0, MAX_PETS, DEFAULTS.count))
  values.scale = clampNumber(values.scale, 0.5, 6, DEFAULTS.scale)
  values.speed = clampNumber(values.speed, 0.25, 4, DEFAULTS.speed)
  return values
}

// The same, looked up from a whole shell.json.
function read(config, id) {
  return normalize(migrate(entryFor(config, id)))
}

// One or more changed values folded into the stored entry. Bounds are applied
// here rather than at each call site, so a writer can just say what it wants --
// `count: count + 1` stops at MAX_PETS on its own. Values equal to the default
// are dropped, so a stock setup keeps a stock shell.json.
function merge(entry, id, changes) {
  var merged = {}
  var key
  var stored = migrate(entry)
  if (isPlainObject(stored)) {
    for (key in stored) if (key !== "id") merged[key] = stored[key]
  }
  for (key in changes) if (key !== "id") merged[key] = changes[key]

  var bounded = normalize(merged)
  var next = { id: String(id) }
  for (key in merged) next[key] = bounded[key] === undefined ? merged[key] : bounded[key]
  for (key in DEFAULTS) {
    if (next[key] !== undefined && next[key] === DEFAULTS[key]) delete next[key]
  }
  return next
}

// The same, against a whole shell.json.
function patch(config, id, changes) {
  return merge(entryFor(config, id), id, changes)
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_PETS: MAX_PETS,
    DEFAULTS: DEFAULTS,
    entryFor: entryFor,
    migrate: migrate,
    countFor: countFor,
    roamingPermitted: roamingPermitted,
    roamingOn: roamingOn,
    safePetId: safePetId,
    toBool: toBool,
    safeFileName: safeFileName,
    normalize: normalize,
    read: read,
    merge: merge,
    patch: patch
  }
}
