// The QML checks the shell will not make for you.
//
// Each one here exists because it caught something that shipped: a duplicate
// property name that stopped a type compiling, a `foo: foo` that bound itself
// to undefined, a bar widget with no implicit size that the bar laid out at
// zero pixels. None of them is reported by `qmllint`, and all of them fail
// silently at runtime -- a panel that never loads, a pet that never draws, an
// icon that is simply not there.
//
// They are functions over source text rather than assertions so that they can
// be tested themselves: a lint that has quietly stopped catching things looks
// exactly like a lint that passes. See qml-lint-test.sh.

// Lines with whole-line comments and string contents blanked, numbering intact.
// The walks below track brace depth to know which object they are inside, and a
// `{` inside a string literal would put that count out by one and quietly blind
// every later check in the file -- so the strings go first.
function scannableLines(source) {
  return String(source).split('\n').map(function (line) {
    if (/^\s*\/\//.test(line)) return ''
    return line.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/'(?:[^'\\]|\\.)*'/g, "''")
  })
}

// A name declared twice in one object is a compile error, and QML reports it
// only as the enclosing type being "unavailable" -- from the file that *used*
// the type, not the file that broke. Walk the braces so two sibling objects may
// each declare the same name, as QML allows.
//
// Returns [{ name, line, first }].
function duplicateProperties(source) {
  const lines = scannableLines(source)
  const scopes = [new Map()]
  const found = []
  for (let n = 0; n < lines.length; n++) {
    const declaration = lines[n].match(
      /^\s*(?:readonly\s+|default\s+|required\s+)*property\s+(?:var|[A-Za-z_][A-Za-z0-9_.<>]*)\s+([a-zA-Z_][A-Za-z0-9_]*)/)
    if (declaration) {
      const name = declaration[1]
      const scope = scopes[scopes.length - 1]
      if (scope.has(name)) found.push({ name: name, line: n + 1, first: scope.get(name) })
      else scope.set(name, n + 1)
    }
    for (const brace of lines[n].match(/[{}]/g) || []) {
      if (brace === '{') scopes.push(new Map())
      else if (scopes.length > 1) scopes.pop()
    }
  }
  return found
}

// `foo: foo` reads as "take the outer foo", but QML resolves the right-hand
// side against the object's own properties first, so it binds to itself and
// stays undefined. Nothing errors -- the guards downstream quietly turn
// everything off.
//
// Returns [{ name, line }].
function selfBindings(source) {
  const lines = scannableLines(source)
  const found = []
  for (let n = 0; n < lines.length; n++) {
    const self = lines[n].match(/^\s*([a-zA-Z_][A-Za-z0-9_]*)\s*:\s*([a-zA-Z_][A-Za-z0-9_]*)\s*$/)
    if (self && self[1] === self[2]) found.push({ name: self[1], line: n + 1 })
  }
  return found
}

// The names bound in the root object's own body. The bar sizes a widget's slot
// from the item's own implicitWidth, and a `Panel` root is a bare Item:
// `anchors.fill: parent` sizes the button from the root, never the root from
// the button. A widget that does not forward its button's implicit size gets a
// zero-width slot and simply never appears -- with nothing logged, because
// nothing failed.
function rootBindings(source) {
  const names = new Set()
  let depth = 0
  for (const line of scannableLines(source)) {
    // Depth 1 is the root object's own body.
    if (depth === 1) {
      const binding = line.match(/^\s*([a-zA-Z_][A-Za-z0-9_.]*)\s*:/)
      if (binding) names.add(binding[1])
    }
    for (const brace of line.match(/[{}]/g) || []) depth += brace === '{' ? 1 : -1
  }
  return names
}

module.exports = {
  scannableLines: scannableLines,
  duplicateProperties: duplicateProperties,
  selfBindings: selfBindings,
  rootBindings: rootBindings
}
