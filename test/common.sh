# Shared preamble for the node test suites: locate the plugin, require node.
# Sourced, not run.

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")/.." && pwd)
export ROOT

command -v node >/dev/null || {
  echo "not ok - node is required to run these tests" >&2
  exit 1
}

# Everything each suite's node heredoc needs before its own first line.
node_prelude() {
  cat <<'JS'
const fs = require('fs')
const path = require('path')
const root = process.env.ROOT
const {
  fail, pass, assert, assertQuiet, assertEqual, assertClose,
  assertDeepEqual, assertThrows, rolls
} = require(path.join(root, 'test', 'harness.js'))
const { makeWorld, walkerDef } = require(path.join(root, 'test', 'fixtures.js'))
JS
}
