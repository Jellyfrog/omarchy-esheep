// The synthetic pet the unit suites walk: a minimal animation graph with one
// of everything the engine reacts to (a walk with border and gravity exits, a
// turn that flips, a fall, a walk-off with no exits, a spawn, a child), and
// the world it walks in. One copy, shared, so a change to the engine's
// contract is a change to one fixture.

function makeWorld(overrides) {
  return Object.assign({
    width: 1920,
    height: 1080,
    imageWidth: 40,
    imageHeight: 40,
    windows: [],
    walkOnWindows: true,
    randS: 50,
    random: function() { return 0.5 }
  }, overrides)
}

// Plain objects merge key by key; arrays and scalars replace. Enough to let a
// suite override one field of one animation without restating the rest.
function deepMerge(base, overrides) {
  for (var key in overrides) {
    var value = overrides[key]
    if (value !== null && typeof value === "object" && !Array.isArray(value)
      && base[key] !== null && typeof base[key] === "object" && !Array.isArray(base[key])) {
      deepMerge(base[key], value)
    } else {
      base[key] = value
    }
  }
  return base
}

function walkerDef(overrides) {
  var def = {
    animations: {
      '1': {
        id: 1,
        name: 'walk',
        start: { x: '-2', y: '0', interval: '200', offsetY: '0', opacity: '1.0' },
        end: { x: '-2', y: '0', interval: '100', offsetY: '0', opacity: '0.5' },
        sequence: { repeat: '2', repeatFrom: 0, frames: [2, 3], action: '', next: [{ id: 1, probability: 100 }] },
        border: [{ id: 2, probability: 100 }],
        gravity: [{ id: 5, probability: 100 }]
      },
      '2': {
        id: 2,
        name: 'turn',
        start: { x: '0', y: '0', interval: '200' },
        end: { x: '0', y: '0', interval: '200' },
        sequence: { repeat: '0', repeatFrom: 0, frames: [9, 10], action: 'flip', next: [{ id: 1, probability: 100 }] }
      },
      '5': {
        id: 5,
        name: 'fall',
        start: { x: '0', y: '10', interval: '40' },
        end: { x: '0', y: '10', interval: '40' },
        sequence: { repeat: '5', repeatFrom: 0, frames: [133], action: '', next: [{ id: 1, probability: 100 }] },
        border: [{ id: 1, probability: 100 }]
      },
      '8': {
        id: 8,
        name: 'leave',
        start: { x: '-2', y: '0', interval: '100' },
        end: { x: '-2', y: '0', interval: '100' },
        sequence: { repeat: '0', repeatFrom: 0, frames: [2], action: '', next: [] }
      }
    },
    spawns: [{ id: 1, probability: 100, x: 'screenW+10', y: 'areaH-imageH', next: [{ id: 1, probability: 100 }] }],
    childs: [{ animationId: 2, x: 'imageX-imageW', y: 'imageY', next: 1 }],
    special: { fall: 5, drag: 1, kill: -1, sync: 1 }
  }
  return deepMerge(def, overrides || {})
}

module.exports = {
  makeWorld: makeWorld,
  walkerDef: walkerDef
}
