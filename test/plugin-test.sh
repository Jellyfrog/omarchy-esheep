#!/bin/bash
# Checks the plugin the way Omarchy will when it loads it: the manifest schema,
# the entry points, the files the QML reaches for, and the shipped assets.
#
# `omarchy plugin validate .` runs the real thing on an Omarchy box; this runs
# anywhere node does, which is where the plugin gets edited.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# No symlinks anywhere: the plugin loader rejects them outright.
if find "$ROOT" -path "$ROOT/.git" -prune -o -type l -print | grep -q .; then
  echo "not ok - the plugin directory contains a symlink" >&2
  find "$ROOT" -path "$ROOT/.git" -prune -o -type l -print >&2
  exit 1
fi
echo "ok - no symlinks in the plugin directory"

{
  node_prelude
  cat <<'JS'
// ---- manifest --------------------------------------------------------------

const manifestPath = path.join(root, 'manifest.json')
assert(fs.existsSync(manifestPath), 'the plugin has a manifest.json at its root')

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))

assertEqual(manifest.schemaVersion, 1, 'the manifest declares schema version 1')
for (const field of ['id', 'name', 'version', 'kinds', 'entryPoints']) {
  assert(manifest[field] !== undefined, `the manifest declares ${field}`)
}

const id = String(manifest.id)
assert(/^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/.test(id),
  'the plugin id is namespaced as <owner>.<name>', `id: ${id}`)
assert(id.indexOf('omarchy.') !== 0, 'the plugin id stays out of the reserved omarchy namespace')
assert(id.indexOf('/') === -1 && id.indexOf('..') === -1, 'the plugin id is a safe path component')

assert(Array.isArray(manifest.kinds) && manifest.kinds.length > 0, 'the manifest declares at least one kind')
const knownKinds = ['bar-widget', 'panel', 'overlay', 'menu', 'service', 'bar']
for (const kind of manifest.kinds) {
  assert(knownKinds.indexOf(kind) !== -1, `kind "${kind}" is one the shell knows`)
  const entry = manifest.entryPoints[kind === 'bar-widget' ? 'barWidget' : kind]
  assert(typeof entry === 'string' && entry.length > 0, `kind "${kind}" has an entry point`)
  if (typeof entry !== 'string') continue
  assert(entry.charAt(0) !== '/' && entry.indexOf('..') === -1,
    `the ${kind} entry point is a safe relative path`)
  assert(fs.existsSync(path.join(root, entry)), `the ${kind} entry point ${entry} exists`)
}

// A pet that walks all session long has to be mounted all session long.
assertEqual(manifest.keepLoaded, true, 'the overlay stays loaded between summons')

const widget = manifest.barWidget || {}
assert(typeof widget.displayName === 'string' && widget.displayName.length > 0,
  'the bar widget has a display name')
assert(['left', 'center', 'right'].indexOf(String(widget.defaultSection)) !== -1,
  'the bar widget has a valid default section')
assertEqual(widget.allowMultiple, false, 'only one eSheep widget belongs on the bar')

// ---- settings stay in step -------------------------------------------------

const Settings = require(path.join(root, 'Settings.js'))
const lint = require(path.join(root, 'test', 'qml-lint.js'))
const defaults = widget.defaults || {}

for (const key of Object.keys(Settings.DEFAULTS)) {
  assert(defaults[key] !== undefined, `the manifest documents the "${key}" default`)
  assertEqual(JSON.stringify(defaults[key]), JSON.stringify(Settings.DEFAULTS[key]),
    `the manifest and Settings.js agree on "${key}"`)
}

const schema = widget.schema || []
const schemaKeys = schema.map(field => String(field.key))
for (const key of Object.keys(Settings.DEFAULTS)) {
  assert(schemaKeys.indexOf(key) !== -1, `the schema exposes "${key}"`)
}
for (const field of schema) {
  assert(typeof field.label === 'string' && field.label.length > 0,
    `schema field "${field.key}" has a label`)
  assert(Settings.DEFAULTS[field.key] !== undefined,
    `schema field "${field.key}" is a setting the plugin actually reads`)

  // A bound the manifest offers that Settings.js would clamp away is a
  // setting the user can pick and never get.
  if (field.min !== undefined) {
    const atMin = {}
    atMin[field.key] = field.min
    assertEqual(Settings.normalize(atMin)[field.key], field.min,
      `schema field "${field.key}" can actually be set to its minimum`)
  }
  if (field.max !== undefined) {
    const atMax = {}
    atMax[field.key] = field.max
    assertEqual(Settings.normalize(atMax)[field.key], field.max,
      `schema field "${field.key}" can actually be set to its maximum`)
  }
}

// A boolean has to survive arriving as a string -- see toBool in Settings.js
// for why one does. The spellings are the shell's own, from Style.boolToken.
const booleanReadings = [
  [true, true], ['true', true], ['True', true], [1, true], ['1', true],
  ['yes', true], ['on', true], [' true ', true],
  [false, false], ['false', false], ['False', false], [0, false], ['0', false],
  ['no', false], ['off', false], [' false ', false]
]

for (const field of schema.filter(entry => entry.type === 'boolean')) {
  const key = String(field.key)
  // Anything that is not a spelling of on or off falls back to the default,
  // the way a bad pet id or a number out of range already does.
  const junk = ['maybe', '', 'null', {}, []].map(value => [value, Settings.DEFAULTS[key]])

  for (const [written, want] of booleanReadings.concat(junk)) {
    const entry = {}
    entry[key] = written
    assertQuiet(Settings.normalize(entry)[key] === want,
      `the "${key}" setting reads ${JSON.stringify(written)} as ${want}`)
  }
  pass(`the "${key}" setting reads a string boolean the way bar set writes one`)
}

// Read through normalize, every one of those on-spellings is indistinguishable
// from the fallback -- each boolean setting defaults to true. So the helper is
// asked directly, with the fallback set against the answer both ways.
for (const [written, want] of booleanReadings) {
  assertQuiet(Settings.toBool(written, !want) === want,
    `toBool reads ${JSON.stringify(written)} as ${want} over a contrary default`)
}
pass('toBool reads every spelling the shell accepts, whichever way the default points')

for (const junk of ['maybe', '', 'null', {}, []]) {
  assertQuiet(Settings.toBool(junk, true) === true && Settings.toBool(junk, false) === false,
    `toBool falls back on ${JSON.stringify(junk)}`)
}
pass('toBool falls back on anything that is not a spelling of on or off')

// And the coercion is not just tolerated on the way in: the next write through
// the panel stores a real boolean, so a string never settles into shell.json.
const coerced = Settings.merge({ id: id, walkOnWindows: 'false' }, id, {})
assertEqual(coerced.walkOnWindows, false,
  'a string boolean is rewritten as a real one on the next write')

// ---- the workspace lock beats roaming --------------------------------------

// The two settings pull against each other, so one of them has to win in a way
// both halves of the plugin agree on. Settings.roamingPermitted is where that
// is said, and these hold it to saying the same thing to the panel that greys
// the toggle out and to the overlay that decides where a pet may walk.
assertEqual(Settings.roamingPermitted({ lockToWorkspace: true }), false,
  'roaming is not permitted while the workspace lock is on')
assertEqual(Settings.roamingPermitted({ lockToWorkspace: false }), true,
  'roaming is permitted once the lock is off')

// And the answer both halves actually walk by: the setting after the lock has
// had its say, asked in one place so the toggle and the pets cannot disagree.
assertEqual(Settings.roamingOn({ roamMonitors: true, lockToWorkspace: true }), false,
  'the lock switches roaming off however the setting is stored')
assertEqual(Settings.roamingOn({ roamMonitors: false, lockToWorkspace: false }), false,
  'and an unlocked pet still needs the setting on')
assertEqual(Settings.roamingOn({ roamMonitors: true, lockToWorkspace: false }), true,
  'both together are what makes a pet roam')

// A stock shell.json has both on, so a rule applied only when the panel is
// clicked would leave every untouched install contradicting itself.
assert(Settings.DEFAULTS.lockToWorkspace === true
  && Settings.roamingPermitted(Settings.normalize({})) === false,
  'a stock config roams nowhere, because the lock ships on',
  'otherwise the shipped defaults disagree and the greyed-out toggle lies')

const petEnum = schema.find(field => field.key === 'pet')
const petIndex = JSON.parse(fs.readFileSync(path.join(root, 'assets', 'pets.json'), 'utf8'))
const shipped = petIndex.pets.map(pet => String(pet.id)).sort()
assert(petEnum && Array.isArray(petEnum.options), 'the pet setting offers a list of pets')
if (petEnum && Array.isArray(petEnum.options)) {
  assertEqual(petEnum.options.slice().sort().join(','), shipped.join(','),
    'the pet list in the manifest matches the pets on disk')
}
assert(shipped.indexOf(String(Settings.DEFAULTS.pet)) !== -1,
  'the default pet is one of the shipped pets')

// The pet id names a directory under assets/ and is writable with `omarchy bar
// set` and by hand in shell.json, so anything that is not a plain folder name
// falls back to the default rather than reaching the filesystem.
for (const hostile of ['../escape', 'a/b', '..', '.hidden', 'UPPER', 'name with space']) {
  assertEqual(Settings.normalize({ pet: hostile }).pet, Settings.DEFAULTS.pet,
    `a pet id of ${JSON.stringify(hostile)} never becomes a path`)
}
for (const pet of shipped) {
  assertEqual(Settings.normalize({ pet: pet }).pet, pet,
    `the shipped pet id "${pet}" passes the same gate`)
}

// The sprite-sheet name out of a parsed pet.json guards the same
// Qt.resolvedUrl sink, through the same module.
for (const hostile of ['../up.png', 'a/b.png', '.hidden', '']) {
  assertEqual(Settings.safeFileName(hostile, 'sprites.png'), 'sprites.png',
    `a sheet name of ${JSON.stringify(hostile)} never becomes a path`)
}
assertEqual(Settings.safeFileName('sprites.png', 'x'), 'sprites.png',
  'the real sheet name passes the file-name gate')

// ---- the retired `enabled` setting -----------------------------------------

// 1.0.0 stored a separate on/off flag. It has to keep meaning "no pets" for
// anyone upgrading, and it has to stop meaning anything the moment they ask
// for pets again -- the migration runs on what is stored, never on what the
// caller just asked for.
const legacyOff = { id: id, enabled: false }

assertEqual(Settings.read({ plugins: [legacyOff] }, id).count, 0,
  'a stored enabled:false still reads as no pets')

// Read back rather than inspected directly: merge drops a value equal to the
// default, so "one pet" is stored as the absence of a count.
const reEnabled = Settings.merge(legacyOff, id, { count: 1 })
assertEqual(Settings.normalize(reEnabled).count, 1,
  'asking for a pet on a legacy entry is not swallowed by the migration')
assertEqual(reEnabled.enabled, undefined,
  'the retired key is dropped on the next write')

const untouched = Settings.merge(legacyOff, id, {})
assertEqual(untouched.count, 0,
  'a legacy entry nobody has touched keeps meaning no pets')
assertEqual(untouched.enabled, undefined,
  'and loses the retired key anyway')

// ---- assets ----------------------------------------------------------------

const assetsDir = path.join(root, 'assets')
const dirs = fs.readdirSync(assetsDir).filter(name =>
  fs.statSync(path.join(assetsDir, name)).isDirectory())

assertEqual(dirs.slice().sort().join(','), shipped.join(','),
  'every pet directory is listed in pets.json and vice versa')

for (const pet of petIndex.pets) {
  const dir = path.join(assetsDir, String(pet.id))
  assert(fs.existsSync(path.join(dir, 'pet.json')), `${pet.id}: pet.json is present`)
  assert(fs.existsSync(path.join(dir, 'sprites.png')), `${pet.id}: the sprite sheet is present`)
  if (pet.icon) assert(fs.existsSync(path.join(dir, String(pet.icon))), `${pet.id}: the icon is present`)
  const definition = JSON.parse(fs.readFileSync(path.join(dir, 'pet.json'), 'utf8'))
  assertEqual(String(definition.id), String(pet.id), `${pet.id}: pet.json agrees with the index`)
  assertEqual(Number(pet.frameWidth), Number(definition.image.frameWidth),
    `${pet.id}: the index reports the real frame width`)
}

// ---- QML -------------------------------------------------------------------

const qmlFiles = fs.readdirSync(root).filter(name => name.endsWith('.qml'))
assert(qmlFiles.length > 0, 'the plugin ships QML')

// Types used by name have to resolve to a file in this directory, since a
// plugin folder is its own implicit QML module.
const localTypes = qmlFiles.map(name => name.replace(/\.qml$/, ''))
const externalTypes = new Set([
  // qs.Ui and qs.Commons come from the shell itself.
  'Panel', 'BarIconButton', 'KeyboardPanel', 'PanelKeyCatcher', 'PanelSectionHeader',
  'PanelSeparator', 'PanelActionButton', 'PanelSlider', 'PanelHero', 'Toggle', 'Dropdown',
  'Style', 'Color', 'Border', 'Util',
  // Qt and Quickshell.
  'Item', 'Image', 'Text', 'Column', 'Row', 'Rectangle', 'Timer', 'Component',
  'Repeater', 'Loader', 'Connections', 'MouseArea', 'Scale', 'Behavior',
  'PanelWindow', 'Region', 'Variants', 'FileView', 'Quickshell', 'Hyprland'
])

for (const file of qmlFiles) {
  const source = fs.readFileSync(path.join(root, file), 'utf8')
  // Only whole-line comments, so a `//` inside a string or regex literal is
  // not mistaken for one. Strings are deliberately left in: the import and type
  // scans further down read them.
  const stripped = source.replace(/^\s*\/\/.*$/gm, '')
  // Counted over the string-blanked lines instead, so a brace or bracket inside
  // a string literal cannot make a balanced file look unbalanced.
  const scannable = lint.scannableLines(source).join('\n')

  // Settings are configured through the bar widget, the settings panel, and
  // `omarchy bar set` -- one stored entry, three doors onto it. A private IPC
  // target would be a fourth with its own vocabulary and its own bugs, so the
  // plugin deliberately declares none.
  assert(!/\bIpcHandler\b/.test(scannable),
    `${file}: declares no private IPC target`)

  assertEqual((scannable.match(/{/g) || []).length, (scannable.match(/}/g) || []).length,
    `${file}: braces balance`)
  assertEqual((scannable.match(/\(/g) || []).length, (scannable.match(/\)/g) || []).length,
    `${file}: parentheses balance`)

  // Both of these fail silently at runtime and are reported by nothing else --
  // see test/qml-lint.js, which is itself tested by test/qml-lint-test.sh.
  for (const dupe of lint.duplicateProperties(source)) {
    fail(`${file}: property "${dupe.name}" is declared once`,
      `line ${dupe.line} repeats the declaration on line ${dupe.first}`)
  }
  pass(`${file}: no property is declared twice in one object`)

  for (const self of lint.selfBindings(source)) {
    fail(`${file}: no property is bound to itself`,
      `line ${self.line}: \`${self.name}: ${self.name}\` binds the property to itself`)
  }
  pass(`${file}: no property is bound to itself`)

  // Every JS file a QML file imports has to be there.
  const jsImports = stripped.match(/import\s+"([^"]+\.js)"/g) || []
  for (const line of jsImports) {
    const target = line.match(/"([^"]+)"/)[1]
    assert(fs.existsSync(path.join(root, target)), `${file}: imports ${target}, which exists`)
  }

  // Types declared inline with `component Foo: Bar {}` are local to the file.
  const inlineTypes = [...stripped.matchAll(/\bcomponent\s+([A-Z][A-Za-z0-9_]*)\s*:/g)].map(m => m[1])

  // Types instantiated at the top of a line: `Foo {`.
  const used = new Set()
  for (const match of stripped.matchAll(/(?:^|\n)\s*([A-Z][A-Za-z0-9_]*)\s*\{/g)) used.add(match[1])
  for (const type of used) {
    if (externalTypes.has(type) || inlineTypes.indexOf(type) !== -1) continue
    assert(localTypes.indexOf(type) !== -1,
      `${file}: uses ${type}, which resolves`,
      `${type} is neither a local .qml file nor a known shell/Qt type`)
  }
}

// The bar sizes a widget's slot from the item's own implicitWidth, and a
// `Panel` root is a bare Item: `anchors.fill: parent` sizes the button from the
// root, never the root from the button. A widget that does not forward its
// button's implicit size gets a zero-width slot and simply never appears --
// with nothing logged, because nothing failed.
const barWidgetPath = path.join(root, manifest.entryPoints.barWidget)
const barWidgetRoot = lint.rootBindings(fs.readFileSync(barWidgetPath, 'utf8'))
for (const property of ['implicitWidth', 'implicitHeight']) {
  assert(barWidgetRoot.has(property),
    `the bar widget's root binds ${property}`,
    'without it the bar gives the widget a zero-sized slot and the icon never shows')
}

// ---- a drag survives the monitor seam --------------------------------------

// PetView draws one pet on one surface, and it carries the MouseArea that holds
// a drag. A Qt item that goes invisible loses its mouse grab, so the moment the
// root's `visible` was used to cull the copies that fall off this monitor, the
// grab died as the pet cleared its own screen: it dropped on the spot, and the
// engine then walked it back to the edge it came from. Painting belongs on the
// sprite; the root must stay visible so the grab outlives the crossing.
const petView = fs.readFileSync(path.join(root, 'PetView.qml'), 'utf8')
const petViewRoot = lint.rootBindings(petView)
assert(!petViewRoot.has('visible'),
  'the pet view never culls itself, only its sprite',
  'an invisible item loses its mouse grab, which drops a pet dragged across a monitor edge')
assert(/visible:\s*view\.paintable/.test(petView),
  'the sprite is what gets culled instead')

// The other half of the same split: input is gated on `interactive`, which has
// to know about the workspace lock. A pet pinned to a workspace nobody is
// looking at is not drawn, and if it kept its input region it would go on
// swallowing clicks meant for the window it is invisibly standing in front of.
const interactive = petView.match(/property bool interactive:([^\n]*\n(?:\s+&&[^\n]*\n)*)/)
assert(interactive !== null, 'the pet view declares what makes a pet interactive')
if (interactive) {
  assert(interactive[1].indexOf('onCurrentWorkspace') !== -1,
    'a pet on a workspace nobody is watching gives its input region back',
    'otherwise it leaves an invisible dead zone that eats clicks')
}

// ---- the panel says one thing about roaming --------------------------------

// The workspace lock and roaming contradict, so the panel dims roaming while
// the lock is on. The keyboard cursor has to agree: a dimmed toggle Enter can
// still land on would write a setting the overlay refuses to honour.
const panelSource = fs.readFileSync(path.join(root, 'BarWidget.qml'), 'utf8')
assert(/\.concat\(canRoam \?/.test(panelSource),
  'the keyboard cursor skips the roaming toggle while it is dimmed')
assert(/enabled: root\.canRoam/.test(panelSource),
  'and the roaming toggle is dimmed on the same term')

// `actions` is documented as being in the order the controls are drawn, and the
// cursor is unusable if it is not.
const drawn = ['walkOnWindows', 'lockToWorkspace', 'roamMonitors']
  .map(key => ({ key, at: panelSource.indexOf('root.cursorOn("' + key + '")') }))
for (const entry of drawn) {
  assert(entry.at !== -1, `the panel draws a "${entry.key}" control`)
}
const cursorOrder = panelSource.match(/readonly property var actions:[\s\S]*?\n\n/)[0]
for (let i = 1; i < drawn.length; i++) {
  assert(drawn[i - 1].at < drawn[i].at,
    `"${drawn[i - 1].key}" is drawn before "${drawn[i].key}"`,
    'the keyboard cursor walks `actions` in this order, so the panel must too')
  assert(cursorOrder.indexOf(drawn[i - 1].key) < cursorOrder.indexOf(drawn[i].key),
    `the cursor reaches "${drawn[i - 1].key}" before "${drawn[i].key}"`)
}

// The overlay and the widget have to agree on where the settings live, or the
// panel would edit one entry while the pets read another.
const overlay = fs.readFileSync(path.join(root, 'Pet.qml'), 'utf8')
const barWidget = fs.readFileSync(path.join(root, 'BarWidget.qml'), 'utf8')
assert(overlay.indexOf(id) !== -1, 'the overlay falls back to the manifest id')
assert(barWidget.indexOf(id) !== -1, 'the bar widget falls back to the manifest id')
assert(overlay.indexOf('Settings.js') !== -1 && barWidget.indexOf('Settings.js') !== -1,
  'both halves read settings through Settings.js')

// The shell calls close() on every panel plugin whenever it tears the plugin
// host down -- which it does on ANY plugin reload, not just this one. A close()
// that persists unconditionally therefore empties the pet count every time any
// plugin on the box changes on disk, and the pets never come back.
//
// Checked for the guard rather than against a particular way of writing, since
// close() reaches the setting through setEnabled(): asking "does it not say
// updateSettings" would pass no matter what close() did.
const closeBody = overlay.match(/function close\(\)\s*\{([^}]*)\}/)
assert(closeBody !== null, 'the overlay declares a close() with a readable body')
if (closeBody) {
  assert(closeBody[1].indexOf('pluginReloading') !== -1,
    'close() tells the reload teardown from a real request',
    'without it every plugin reload on the box switches the pets off for good')
  assert(overlay.indexOf('"pluginReloading" in shell') !== -1,
    'and treats a shell without that flag as a reason not to persist',
    'a missing flag reads as "not reloading", which is the failure it guards against')
}

// The shell calls open/close and reads `opened` on a panel plugin.
for (const member of ['function open(', 'function close(', 'property bool opened']) {
  assert(overlay.indexOf(member) !== -1, `the overlay implements the panel contract: ${member}`)
}

// ---- docs ------------------------------------------------------------------

const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8')
assert(readme.indexOf(id) !== -1, 'the README names the plugin id')
for (const pet of petIndex.pets) {
  assert(readme.indexOf(String(pet.id)) !== -1, `the README lists the ${pet.id} pet`)
}
// `omarchy bar set` is the documented way to change a setting, so the README's
// key table is the page a user types from. It restates what the manifest
// declares, and the manifest is already held to Settings.js -- this is the one
// copy that could drift in silence.
// A row in the table, not a mention anywhere: several of these keys are named
// in the prose above it, so 'appears in the file' would pass on a table the
// key had been dropped from.
for (const field of schema) {
  const row = new RegExp('^\\| `' + field.key + '` \\|', 'm')
  assertQuiet(row.test(readme), `the README documents the ${field.key} setting`)
}
pass('the README documents every setting the manifest declares')

assert(fs.existsSync(path.join(root, 'preview.png')), 'the plugin ships a preview image')
assert(fs.existsSync(path.join(root, 'LICENSE')), 'the plugin ships its license')
assert(fs.existsSync(path.join(root, 'ATTRIBUTION.md')), 'the plugin credits the upstream sprites')
JS
} | node
