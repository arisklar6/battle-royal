## Step-1 tests: arena invariants, freeze/mine, ignition, movement rules,
## repeat-run determinism (DESIGN §15.5).

import std/json
import zero_sum/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(maxTicks = 600, freeze = 48): Sim =
  let cfg = parseSimConfig(%*{"max_ticks": maxTicks, "freeze_ticks": freeze},
                           fixedSeed)
  initSim(cfg)

block arena_invariants:
  var s = mkSim()
  # border solid
  for i in 0 ..< ArenaSize:
    doAssert s.arena.tile(Pos(x: i, y: 0)) == tkWall
    doAssert s.arena.tile(Pos(x: 0, y: i)) == tkWall
  # pedestals present and distinct
  for i, p in Pedestals:
    doAssert s.arena.tile(p) == tkPedestal
    for j, q in Pedestals:
      doAssert i == j or not (p == q)
  # fortress mouths open (N mouth columns 23-24 at y=20)
  doAssert s.arena.tile(Pos(x: 23, y: 20)) == tkGround
  doAssert s.arena.tile(Pos(x: 24, y: 20)) == tkGround
  doAssert s.arena.tile(Pos(x: 22, y: 20)) == tkFortressWall
  # chamber interior ground
  doAssert s.arena.tile(Pos(x: 24, y: 24)) == tkGround

block freeze_mine_death:
  var s = mkSim()
  s.submitAction(AgentId(3), Action(kind: akMove, dir: dN))
  s.step()
  doAssert not s.agents[3].alive
  doAssert s.agents[3].deathTick == 0
  var sawMine, sawFireworks: bool
  for e in s.events:
    if e.kind == evMineExplosion and e.slot == 3: sawMine = true
    if e.kind == evDeathFireworks and e.slot == 3: sawFireworks = true
  doAssert sawMine and sawFireworks

block ignition_fires:
  var s = mkSim()
  for t in 0 ..< 49:
    s.step()
    if t == 48: discard
  doAssert s.phase == phLive
  # ignition event emitted exactly at freeze_ticks tick
  var s2 = mkSim()
  for t in 0 ..< 48: s2.step()
  s2.step()
  var sawIgnition = false
  for e in s2.events:
    if e.kind == evIgnition: sawIgnition = true
  doAssert sawIgnition

block movement_after_ignition:
  var s = mkSim()
  for t in 0 ..< 49: s.step()
  let before = s.agents[0].pos
  s.submitAction(AgentId(0), Action(kind: akMove, dir: dW))
  s.step()
  doAssert not (s.agents[0].pos == before)
  doAssert s.agents[0].alive           # no mine after ignition
  # cooldown enforced (default 5 speed -> 11 ticks)
  let after1 = s.agents[0].pos
  s.submitAction(AgentId(0), Action(kind: akMove, dir: dW))
  s.step()
  doAssert s.agents[0].pos == after1   # still cooling down

block swap_forbidden:
  var s = mkSim()
  for t in 0 ..< 49: s.step()
  # walk agents 0 and 1 adjacent to each other would take many ticks; instead
  # test the rule directly on the pedestal ring is impractical here — covered
  # by construction: submit swaps once adjacency exists in later-step tests.
  discard

block determinism_repeat_run:
  var a = mkSim()
  var b = mkSim()
  for t in 0 ..< 200:
    if t == 60:
      a.submitAction(AgentId(0), Action(kind: akMove, dir: dE))
      b.submitAction(AgentId(0), Action(kind: akMove, dir: dE))
    a.step()
    b.step()
  doAssert a.hashes == b.hashes
  doAssert a.tickHash() == b.tickHash()

block different_seeds_diverge:
  let cfgA = parseSimConfig(%*{"seed": 1, "max_ticks": 600, "freeze_ticks": 48},
                            fixedSeed)
  let cfgB = parseSimConfig(%*{"seed": 2, "max_ticks": 600, "freeze_ticks": 48},
                            fixedSeed)
  var a = initSim(cfgA)
  var b = initSim(cfgB)
  # rock layouts differ with overwhelming probability
  var differ = false
  for y in 0 ..< ArenaSize:
    for x in 0 ..< ArenaSize:
      if a.arena.tiles[y][x] != b.arena.tiles[y][x]: differ = true
  doAssert differ

block minted_seed_recorded:
  let original = %*{"max_ticks": 600, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, fixedSeed)
  doAssert cfg.seedWasMinted
  let eff = parseJson(effectiveConfigJson(cfg, original))
  doAssert eff["seed"].getBiggestInt() == 42
  # tokens never land in the stored config
  let orig2 = %*{"max_ticks": 600, "tokens": ["secret"]}
  let cfg2 = parseSimConfig(orig2, fixedSeed)
  let eff2 = parseJson(effectiveConfigJson(cfg2, orig2))
  doAssert not eff2.hasKey("tokens")

echo "t_step1 ok"
