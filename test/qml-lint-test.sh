#!/bin/bash
# Tests for the QML checks themselves.
#
# Every check in qml-lint.js exists because the thing it looks for shipped once
# and broke the plugin silently. A check that has stopped catching its bug reads
# exactly like one that passes, so each is fed the bug it was written for and
# has to find it -- and fed a legitimate near-miss and has to stay quiet.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

{
  node_prelude
  cat <<'JS'
const lint = require(path.join(root, 'test', 'qml-lint.js'))

// ---- duplicate property names ----------------------------------------------

// The one that shipped: PetAgent declared `leaving` twice, so the type never
// compiled and Pet.qml could not instantiate it.
const duped = lint.duplicateProperties(`Item {
  property bool leaving: false
  property real petX: 0
  property bool leaving: false
}`)
assertEqual(duped.length, 1, 'a name declared twice in one object is found')
if (duped.length) {
  assertEqual(duped[0].name, 'leaving', 'the duplicate is named')
  assertEqual(duped[0].line, 4, 'and reported at the line that repeats it')
  assertEqual(duped[0].first, 2, 'alongside the line that first declared it')
}

// QML allows two sibling objects to each declare the same name.
assertEqual(lint.duplicateProperties(`Item {
  Timer { property int interval: 1 }
  Timer { property int interval: 2 }
}`).length, 0, 'the same name in two sibling objects is allowed')

assertEqual(lint.duplicateProperties(`Item {
  property bool a: false
  Timer { property bool a: true }
}`).length, 0, 'a nested object may shadow a name from its parent')

// A `{` inside a string used to push a scope that never closed, which put the
// depth out by one and blinded every check after it in the file.
const afterString = lint.duplicateProperties(`Item {
  property real a: 0
  property string hint: "an opening brace { in a string"
  property real a: 1
}`)
assertEqual(afterString.length, 1, 'a brace inside a string does not blind the walk')

// ---- self-bindings ---------------------------------------------------------

// The one that shipped: PetSurface's delegate said `surface: surface`, which
// QML resolved against the delegate's own property, so it was undefined and no
// pet was ever drawn.
const selfs = lint.selfBindings(`PetView {
  agent: modelData
  surface: surface
}`)
assertEqual(selfs.length, 1, 'a property bound to itself is found')
if (selfs.length) {
  assertEqual(selfs[0].name, 'surface', 'the self-bound property is named')
  assertEqual(selfs[0].line, 3, 'and reported at its line')
}

assertEqual(lint.selfBindings(`PetView {
  surface: petSurface
  host: surface.host
}`).length, 0, 'binding to a differently named id is not flagged')

// ---- root bindings ---------------------------------------------------------

// The one that shipped: BarWidget never forwarded its button's implicit size,
// so the bar gave the slot zero width and the icon never appeared.
const withoutSize = lint.rootBindings(`Panel {
  moduleName: "x"
  BarIconButton {
    implicitWidth: 10
    implicitHeight: 10
  }
}`)
assert(!withoutSize.has('implicitWidth'),
  'a size bound only on a child does not count as the root binding it')

const withSize = lint.rootBindings(`Panel {
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  BarIconButton { id: button }
}`)
assert(withSize.has('implicitWidth') && withSize.has('implicitHeight'),
  'a size bound on the root object is found')

// ---- the shipped files still pass ------------------------------------------

for (const file of fs.readdirSync(root).filter(name => name.endsWith('.qml'))) {
  const source = fs.readFileSync(path.join(root, file), 'utf8')
  assertQuiet(lint.duplicateProperties(source).length === 0,
    `${file}: declares no name twice in one object`,
    JSON.stringify(lint.duplicateProperties(source)))
  assertQuiet(lint.selfBindings(source).length === 0,
    `${file}: binds no property to itself`,
    JSON.stringify(lint.selfBindings(source)))
}
pass('every shipped QML file passes the checks')
JS
} | node
