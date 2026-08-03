// Golden test for the cockpit's game-plan interpreter (node --test-free,
// stdlib only):  node tests/t_cockpit_prompt.js
//
// The interpreter is pure and lives inline in cockpit.html, so the test
// slices the deterministic declarations straight out of the page — no
// duplicated copy to drift, no DOM needed. A failed slice throws, which
// is itself the signal that the page was restructured.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'game', 'client', 'cockpit.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function grab(re, what) {
  const m = script.match(re);
  if (!m) throw new Error('could not slice ' + what + ' out of cockpit.html');
  return m[0];
}
const core = [
  grab(/const OPEN_CHIP = \{[\s\S]*?\};/, 'OPEN_CHIP'),
  grab(/const clamp = .*?;/, 'clamp'),
  grab(/function defaultPolicy\(\) \{[\s\S]*?\n\}/, 'defaultPolicy'),
  grab(/const PLAN_PLACEHOLDER =[\s\S]*?';/, 'PLAN_PLACEHOLDER'),
  grab(/const LOOT_CUES = \[[\s\S]*?\]\];/, 'LOOT_CUES'),
  grab(/function interpretPrompt\([\s\S]*?\n\}/, 'interpretPrompt'),
  grab(/function chipsFor\([\s\S]*?\n\}/, 'chipsFor'),
].join('\n');
// evaluated in a bare context with no require/process reachable: the input
// is this repo's own page, and the sandbox keeps that boundary explicit
const api = vm.createContext({});
// top-level `const` stays lexical (unlike function declarations, it never
// lands on the context object) — hand the values over explicitly
vm.runInContext(core + '\nglobalThis.PLAN_PLACEHOLDER = PLAN_PLACEHOLDER;',
                api, {filename: 'cockpit.html:interpreter'});
if (typeof api.PLAN_PLACEHOLDER !== 'string' || !api.PLAN_PLACEHOLDER.length)
  throw new Error('PLAN_PLACEHOLDER did not survive the slice');

let failures = 0;
function check(label, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { console.log('  ok   ' + label); return; }
  console.log('  FAIL ' + label + '\n       got  ' + g + '\n       want ' + w);
  failures++;
}

// 1. the placeholder is advice, not a parser fixture: every clause lands,
//    all seven fields are exercised, and nothing self-cancels
console.log('placeholder parse');
const ph = api.interpretPrompt(api.PLAN_PLACEHOLDER).policy;
check('opening', ph.opening, 'fortress');
check('aggression', ph.aggression, 7);
check('heal_at', ph.heal_at, 60);
check('flee_at', ph.flee_at, 30);
check('ring_margin', ph.ring_margin, 3);
check('loot_priority', ph.loot_priority, ['sword', 'first_aid']);
check('finale', ph.finale, 'fight');
// a fight finale never raises the flee threshold, so flee_at stands as written
check('no flee/finale contradiction',
  api.chipsFor(ph).some(c => c.includes('finale') && c.includes('flee')), false);

// 2. when the finale DOES override flee_at, the chip has to disclose it
console.log('finale override disclosure');
const evadeNever = api.interpretPrompt(
  'never flee, and at the finale spare your partner').policy;
check('evade + never flee -> policy',
  [evadeNever.flee_at, evadeNever.finale], [0, 'evade']);
check('evade + never flee -> chip',
  api.chipsFor(evadeNever)[3], 'never flees — except at the finale');
const evadeNum = api.interpretPrompt(
  'flee below 40, show your partner mercy at the end').policy;
check('evade + threshold -> policy',
  [evadeNum.flee_at, evadeNum.finale], [40, 'evade']);
check('evade + threshold -> chip',
  api.chipsFor(evadeNum)[3], 'flees below 40 — always at the finale');
check('fight finale keeps the plain chip',
  api.chipsFor(api.interpretPrompt('flee below 40, win alone').policy)[3],
  'flees below 40');

// 3. chips always describe the whole policy
console.log('chip coverage');
check('seven chips', api.chipsFor(api.interpretPrompt('').policy).length, 7);

if (failures) {
  console.log('\nt_cockpit_prompt FAILED (' + failures + ')');
  process.exit(1);
}
console.log('\nt_cockpit_prompt ok');
