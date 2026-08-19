## Step-3 tests: melee w/ strength scaling, spear reach, durability, mutual
## kills, projectiles (hit, wall-block, ammo, recovery), poison DoT + first-aid
## denial, net immobilize, kill credit, determinism.

import std/json
import battle_royal/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(seed = 42): Sim =
  let cfg = parseSimConfig(%*{"seed": seed, "max_ticks": 4000, "freeze_ticks": 48},
                           fixedSeed)
  initSim(cfg)

proc skipFreeze(s: var Sim) =
  while s.phase == phCountdown:
    s.step()

proc clearGroundAt(s: var Sim, p: Pos) =
  var kept: seq[GroundItem] = @[]
  for g in s.ground:
    if not (g.pos == p): kept.add(g)
  s.ground = kept

proc place(s: var Sim, slot: int, x, y: int) =
  s.agents[slot].pos = Pos(x: x, y: y)

proc clearRect(s: var Sim, x0, x1, y0, y1: int) =
  ## test helper: flatten seeded rocks/bushes + sweep ground items so
  ## placements are geography-independent
  for y in y0 .. y1:
    for x in x0 .. x1:
      if s.arena.tiles[y][x] in {tkRock, tkBush}:
        s.arena.tiles[y][x] = tkGround
      s.clearGroundAt(Pos(x: x, y: y))

block bare_hands_scaling:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(9, 12, 9, 11)
  s.place(0, 10, 10)
  s.place(1, 11, 10)          # E of agent 0
  s.agents[0].stats.strength = 10
  let hpBefore = s.agents[1].hpCenti
  s.submitAction(AgentId(0), Action(kind: akAttack, dir: dE))
  s.step()
  # 5 dmg * 1.5 = 7.5 HP = 750 centi
  doAssert hpBefore - s.agents[1].hpCenti == 750

block spear_reach:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(9, 13, 19, 21)
  s.place(2, 10, 20)
  s.place(3, 12, 20)          # 2 tiles E
  s.agents[2].hand = iSpear
  s.agents[2].handDur = 40
  let hp = s.agents[3].hpCenti
  s.submitAction(AgentId(2), Action(kind: akAttack, dir: dE))
  s.step()
  doAssert hp - s.agents[3].hpCenti == 1200      # 12 dmg x1.0
  doAssert s.agents[2].handDur == 39
  # bare hands can NOT reach 2 tiles
  var s2 = mkSim()
  s2.skipFreeze()
  s2.clearRect(9, 13, 29, 31)
  s2.place(4, 10, 30)
  s2.place(5, 12, 30)
  let hp5 = s2.agents[5].hpCenti
  s2.submitAction(AgentId(4), Action(kind: akAttack, dir: dE))
  s2.step()
  doAssert s2.agents[5].hpCenti == hp5

block durability_break:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(4, 7, 4, 6)
  s.place(6, 5, 5)
  s.place(7, 6, 5)
  s.agents[6].hand = iSword
  s.agents[6].handDur = 1
  s.agents[7].hpCenti = MaxHpCenti
  s.submitAction(AgentId(6), Action(kind: akAttack, dir: dE))
  s.step()
  doAssert s.agents[6].hand == iNone             # broke after last swing

block mutual_kill:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(39, 42, 39, 41)
  s.place(8, 40, 40)
  s.place(9, 41, 40)
  s.agents[8].hpCenti = 100                       # 1 HP each
  s.agents[9].hpCenti = 100
  s.submitAction(AgentId(8), Action(kind: akAttack, dir: dE))
  s.submitAction(AgentId(9), Action(kind: akAttack, dir: dW))
  s.step()
  doAssert not s.agents[8].alive and not s.agents[9].alive
  doAssert s.agents[8].kills == 1 and s.agents[9].kills == 1
  doAssert s.agents[8].deathTick == s.agents[9].deathTick

block bow_and_arrows:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(9, 17, 39, 41)
  s.place(10, 10, 40)
  s.place(11, 15, 40)         # 5 tiles E, within bow range 8
  s.clearGroundAt(Pos(x: 15, y: 40))
  s.agents[10].hand = iBow
  s.agents[10].pack[0] = PackSlot(item: iArrows, n: 2)
  s.agents[11].stats.athleticism = 0   # test-only: dodge chance 0, deterministic hit              # 2% dodge, seed-stable hit
  let hp = s.agents[11].hpCenti
  s.submitAction(AgentId(10), Action(kind: akAttack, dir: dE))
  s.step()                                        # spawn + advance 2
  s.step()                                        # advance to 4
  s.step()                                        # reaches tile 5-6: hit
  doAssert hp - s.agents[11].hpCenti == 1400      # arrow 14 dmg
  doAssert s.agents[10].pack[0].n == 1            # ammo consumed
  # no ammo -> no shot
  s.agents[10].pack[0] = PackSlot()
  s.agents[10].attackReadyTick = 0
  s.submitAction(AgentId(10), Action(kind: akAttack, dir: dE))
  let projCount = s.projectiles.len
  s.step()
  doAssert s.projectiles.len == projCount

block wall_blocks_projectile:
  var s = mkSim()
  s.skipFreeze()
  # shoot straight into the fortress wall from outside
  s.place(12, 24, 17)         # north of fortress, wall at y=20 col 24 is mouth!
  s.place(12, 22, 17)         # col 22 wall at y=20
  s.agents[12].hand = iBow
  s.agents[12].pack[0] = PackSlot(item: iArrows, n: 1)
  s.submitAction(AgentId(12), Action(kind: akAttack, dir: dS))
  s.step()
  s.step()
  doAssert s.projectiles.len == 0                 # died on the wall

block knife_stack_and_recovery:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(9, 17, 43, 45)
  s.place(13, 10, 44)
  s.agents[13].hand = iKnives
  s.agents[13].handN = 2
  s.submitAction(AgentId(13), Action(kind: akAttack, dir: dE))
  s.step()
  doAssert s.agents[13].handN == 1
  # let it fly to range end (5 tiles) -> recoverable ground knife
  for _ in 0 ..< 3: s.step()
  var found = false
  for g in s.ground:
    if g.item == iKnives and g.pos.y == 44 and g.pos.x > 10:
      found = true
  doAssert found

block poison_and_first_aid_denial:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(29, 35, 4, 6)
  s.place(14, 30, 5)
  s.place(15, 33, 5)
  s.clearGroundAt(Pos(x: 33, y: 5))
  s.agents[14].hand = iBlowgun
  s.agents[14].pack[0] = PackSlot(item: iDarts, n: 1)
  s.agents[15].stats.intelligence = 5             # duration 12*(20-5)=180
  s.agents[15].stats.athleticism = 0   # test-only: dodge chance 0, deterministic hit
  s.submitAction(AgentId(14), Action(kind: akAttack, dir: dE))
  s.step(); s.step()                              # dart travels 2/tick: hit
  doAssert s.agents[15].poisonUntil > 0
  let afterHit = s.agents[15].hpCenti
  doAssert MaxHpCenti - afterHit == 400           # 4 impact dmg
  # first-aid can never complete under poison pulses
  s.agents[15].pack[0] = PackSlot(item: iFirstAid, n: 1)
  s.submitAction(AgentId(15), Action(kind: akUse, invSlot: 0))
  s.step()
  doAssert s.agents[15].channeling.kind == chConsume
  var cancelled = false
  for _ in 0 ..< 60:
    s.step()
    if s.agents[15].channeling.kind == chNone:
      cancelled = true
      break
  doAssert cancelled
  doAssert s.agents[15].pack[0].item == iFirstAid # kit kept
  # total poison damage: pulses of 2 HP every 24t until expiry
  var s2 = mkSim()
  s2.skipFreeze()
  s2.clearRect(9, 11, 9, 11)
  s2.place(0, 10, 10)
  s2.agents[0].stats.intelligence = 10            # duration 120 -> 5 pulses
  s2.agents[0].poisonUntil = s2.tick + 120
  s2.agents[0].poisonAppliedTick = s2.tick
  s2.agents[0].poisonFrom = 1
  let hp0 = s2.agents[0].hpCenti
  for _ in 0 ..< 130: s2.step()
  doAssert hp0 - s2.agents[0].hpCenti == 4 * PoisonPulseCenti  # pulses at 24,48,72,96 (120 expired)

block net_immobilize:
  var s = mkSim()
  s.skipFreeze()
  s.clearRect(19, 24, 43, 45)
  s.place(1, 20, 44)
  s.place(2, 22, 44)
  s.clearGroundAt(Pos(x: 22, y: 44))
  s.agents[1].hand = iNet
  s.agents[1].handN = 1
  s.agents[2].stats.athleticism = 0   # test-only: dodge chance 0, deterministic hit
  s.submitAction(AgentId(1), Action(kind: akAttack, dir: dE))
  s.step()
  doAssert s.agents[2].nettedUntil > s.tick       # netted
  let posBefore = s.agents[2].pos
  s.submitAction(AgentId(2), Action(kind: akMove, dir: dE))
  s.step()
  doAssert s.agents[2].pos == posBefore           # cannot move
  # but CAN attack
  s.place(1, 21, 44)
  s.submitAction(AgentId(2), Action(kind: akAttack, dir: dW))
  let hp1 = s.agents[1].hpCenti
  s.step()
  doAssert s.agents[1].hpCenti < hp1

block determinism_with_combat:
  var a = mkSim()
  var b = mkSim()
  for t in 0 ..< 300:
    for s in [addr a, addr b]:
      if t == 60: s[].submitAction(AgentId(0), Action(kind: akMove, dir: dW))
      if t == 80: s[].submitAction(AgentId(0), Action(kind: akAttack, dir: dW))
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

echo "t_step3 ok"
