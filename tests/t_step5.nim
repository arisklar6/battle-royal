## Step-5 tests: zone radius formula, damage cadence + ATH scale, flood
## impassability, firestorm, warnings, zone-driven match end, determinism.

import std/json
import battle_royal/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

let CompressedZone = %*{"schedule": [
  [96, 120, 216, 24, 12, 2],
  [264, 288, 384, 12, 0, 30]]}

proc mkFull(): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 9120, "freeze_ticks": 240},
                         fixedSeed))

proc mkFast(events: JsonNode = newJArray()): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 600, "freeze_ticks": 48,
                            "zone": CompressedZone, "events": events},
                         fixedSeed))

block radius_formula_default:
  var s = mkFull()
  # before stage 1 shrink: full radius, no damage
  s.tick = 1631
  doAssert s.zoneRadius() == 24
  s.tick = 1440
  doAssert s.zoneDamagePerS() == 1          # damage starts at warn
  s.tick = 1439
  doAssert s.zoneDamagePerS() == 0
  # shrink interpolation: stage 1 (24->19 over 1632..2064, span 432, delta 5)
  s.tick = 1632
  doAssert s.zoneRadius() == 24             # floor(0)
  s.tick = 1632 + 87                        # ceil(432/5): floor crosses 1
  doAssert s.zoneRadius() == 23             # first decrement
  s.tick = 2064
  doAssert s.zoneRadius() == 19             # exact at doneT
  # full closure exactly at 7536
  s.tick = 7535
  doAssert s.zoneRadius() >= 1
  s.tick = 7536
  doAssert s.zoneRadius() == 0
  s.tick = 9000
  doAssert s.zoneRadius() == 0
  doAssert s.zoneDamagePerS() == 24

block zone_damage_applied:
  var s = mkFast()
  while s.phase == phCountdown: s.step()
  # place agent far outside r=12 after stage-1 closes (tick 216+)
  while s.tick < 240: s.step()
  doAssert s.zoneRadius() == 12
  s.agents[0].pos = Pos(x: 2, y: 2)          # far corner, outside
  s.agents[0].stats.athleticism = 5
  s.agents[1].pos = Pos(x: 24, y: 24)        # center, inside
  let hp0 = s.agents[0].hpCenti
  let hp1 = s.agents[1].hpCenti
  # run to the next mod-24 tick
  while s.tick mod 24 != 0: s.step()
  s.step()                                    # this tick includes application? cadence check below
  while s.tick mod 24 != 1: s.step()          # ensure at least one application passed
  doAssert s.agents[0].hpCenti < hp0
  doAssert s.agents[1].hpCenti == hp1
  # exact scale: 2 HP/s at ATH 5 -> 200*85/100 = 170 centi per application
  let taken = hp0 - s.agents[0].hpCenti
  doAssert taken mod 170 == 0

block flood_blocks_and_damages:
  let events = %*[{"kind": "flood", "rect": [10, 10, 14, 14],
                   "from_tick": 60, "duration": 480}]
  var s = mkFast(events)
  while s.phase == phCountdown: s.step()
  while s.tick < 61: s.step()
  # agent outside flood cannot step in
  s.agents[2].pos = Pos(x: 9, y: 12)
  s.agents[2].stats.athleticism = 10
  s.submitAction(AgentId(2), Action(kind: akMove, dir: dE))
  let before = s.agents[2].pos
  s.step()
  doAssert s.agents[2].pos == before
  # agent caught inside takes 4 HP/s scaled and may walk out
  s.agents[3].pos = Pos(x: 12, y: 12)
  s.agents[3].stats.athleticism = 10
  let hp3 = s.agents[3].hpCenti
  for _ in 0 ..< 25: s.step()
  doAssert s.agents[3].hpCenti < hp3
  doAssert (hp3 - s.agents[3].hpCenti) mod 280 == 0   # 400*70/100
  s.agents[3].moveReadyTick = 0
  s.submitAction(AgentId(3), Action(kind: akMove, dir: dW))
  s.step()
  s.agents[3].moveReadyTick = 0
  s.submitAction(AgentId(3), Action(kind: akMove, dir: dW))
  s.step()
  s.agents[3].moveReadyTick = 0
  s.submitAction(AgentId(3), Action(kind: akMove, dir: dW))
  s.step()
  doAssert s.agents[3].pos.x < 12                     # escaped westward

block warnings_emitted:
  let events = %*[{"kind": "firestorm", "center": [30, 30], "radius": 4,
                   "from_tick": 200, "duration": 100}]
  var s = mkFast(events)
  var sawZoneWarn, sawEventWarn: bool
  for _ in 0 ..< 300:
    s.step()
    for e in s.events:
      if e.kind == evZoneWarning and e.tick == 96: sawZoneWarn = true
      if e.kind == evEventWarning and e.tick == 80: sawEventWarn = true
  doAssert sawZoneWarn and sawEventWarn

block firestorm_damage:
  let events = %*[{"kind": "firestorm", "center": [30, 30], "radius": 4,
                   "from_tick": 72, "duration": 240}]
  var s = mkFast(events)
  while s.phase == phCountdown: s.step()
  while s.tick < 73: s.step()
  s.agents[4].pos = Pos(x: 30, y: 30)
  s.agents[4].stats.athleticism = 10
  let hp = s.agents[4].hpCenti
  for _ in 0 ..< 25: s.step()
  doAssert (hp - s.agents[4].hpCenti) mod 420 == 0    # 600*70/100
  doAssert hp > s.agents[4].hpCenti

block zone_ends_match:
  var s = mkFast()
  var guard = 0
  while s.phase != phEnded and guard < 700:
    s.step()
    inc guard
  doAssert s.phase == phEnded
  # zone at radius 0 + 30 HP/s must resolve well before the 600 cap
  doAssert s.tick < 600 or s.winnerSlot >= 0

block determinism_with_zone:
  var a = mkFast()
  var b = mkFast()
  for _ in 0 ..< 500:
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

echo "t_step5 ok"
