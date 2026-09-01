// Shared TAP-ish assertions for the node test suites. Both suites print
// `ok - ...` / `not ok - ...` lines and exit non-zero if anything failed.

var failures = 0

function fail(description, detail) {
  if (detail) console.error(detail)
  console.error("not ok - " + description)
  failures++
}

function pass(description) {
  console.log("ok - " + description)
}

function assert(condition, description, detail) {
  if (!condition) fail(description, detail)
  else pass(description)
}

// Like assert, but silent on success: for checks inside a loop, where one line
// per iteration would bury the rest of the run.
function assertQuiet(condition, description, detail) {
  if (!condition) fail(description, detail)
}

function assertEqual(actual, expected, description) {
  assert(actual === expected, description, "expected: " + expected + "\nactual:   " + actual)
}

function assertClose(actual, expected, tolerance, description) {
  assert(Math.abs(actual - expected) <= tolerance, description,
    "expected: " + expected + " (+/- " + tolerance + ")\nactual:   " + actual)
}

function assertDeepEqual(actual, expected, description) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), description,
    "expected: " + JSON.stringify(expected) + "\nactual:   " + JSON.stringify(actual))
}

function assertThrows(fn, description) {
  var threw = false
  try { fn() } catch (e) { threw = true }
  assert(threw, description)
}

// A deterministic stand-in for Math.random so weighted picks and spawns are
// reproducible: hand it the sequence of rolls the test wants.
function rolls(values) {
  var i = 0
  return function() { return values[i++ % values.length] }
}

process.on("exit", function() { if (failures > 0) process.exitCode = 1 })

module.exports = {
  fail: fail,
  pass: pass,
  assert: assert,
  assertQuiet: assertQuiet,
  assertEqual: assertEqual,
  assertClose: assertClose,
  assertDeepEqual: assertDeepEqual,
  assertThrows: assertThrows,
  rolls: rolls
}
