// The viewer's tile size must follow the stream, not a constant:
//   node tests/t_client_scale.js
//
// Two things in global_client.html reason in tiles while operating on the
// map layer's WIRE pixels: the motion-tween gate and the director camera.
// Both used hardcoded numbers derived from RS=2, and both fail *silently* —
// the tween one by snapping every agent to its destination, which no frame
// dump can show and no screenshot can catch. So this test slices the real
// declarations out of the page (same technique as t_cockpit_prompt.js) and
// runs them against the viewport widths the server actually announces.

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('node:assert/strict');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'game', 'client', 'global_client.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function grab(re, what) {
  const m = script.match(re);
  if (!m) {
    throw new Error('could not slice ' + what + ' out of global_client.html');
  }
  return m[0];
}

const core = [
  grab(/const ArenaTiles=\d+;/, 'ArenaTiles'),
  grab(/let mapTilePx=\d+;/, 'mapTilePx'),
  grab(/function noteMapViewport\(width\)\{[\s\S]*?\n\}/, 'noteMapViewport'),
  grab(/function dirTilePx\(\)\{.*?\}/, 'dirTilePx'),
].join('\n');

// The gate itself, lifted verbatim so a change to the literal breaks here.
const gateLine = grab(/const lerpMax=.*?;/, 'lerpMax');
const context = vm.createContext({});
vm.runInContext(core + '\nfunction lerpMax(){' + gateLine +
  '\nreturn lerpMax;}\n', context);

function tilePx(viewportWidth) {
  return vm.runInContext(
    'noteMapViewport(' + viewportWidth + '); mapTilePx;', context);
}
function maxTween(viewportWidth) {
  vm.runInContext('noteMapViewport(' + viewportWidth + ');', context);
  return vm.runInContext('lerpMax();', context);
}

// WorldPx (48 tiles x 6 px) x RS, i.e. what render.nim's map viewport
// announces at each render scale.
const cases = [
  {rs: 1, viewport: 288, tile: 6},
  {rs: 2, viewport: 576, tile: 12},
  {rs: 4, viewport: 1152, tile: 24},
  {rs: 8, viewport: 2304, tile: 48},
];

for (const c of cases) {
  assert.equal(tilePx(c.viewport), c.tile,
    'RS=' + c.rs + ': one tile should be ' + c.tile + ' wire px');

  const cap = maxTween(c.viewport);
  // An agent moves at most one tile per tick, on either axis, and its
  // label / hp band ride a couple of pixels off its origin.
  assert.ok(c.tile <= cap,
    'RS=' + c.rs + ': a one-tile step (' + c.tile +
    ' px) must still tween, cap was ' + cap);
  // A jump of two tiles is a teleport (or a projectile at 2 tiles/tick)
  // and must snap rather than slide across the board.
  assert.ok(2 * c.tile > cap,
    'RS=' + c.rs + ': a two-tile jump must snap, cap was ' + cap);
}

// The director speaks tiles at the analyst feed and pixels at the canvas.
// Before this was derived, it centred on half the intended coordinate at
// RS=2 and would have been a quarter of it at RS=4.
vm.runInContext('noteMapViewport(1152);', context);
assert.equal(vm.runInContext('dirTilePx();', context), 24,
  'director must convert tiles with the live wire tile size');

// The old bug, stated as a test: 14 was "one tile plus 2" at RS=2 only.
assert.ok(maxTween(1152) > 14,
  'the tween cap must not be pinned to the RS=2 value');

console.log('t_client_scale ok');
