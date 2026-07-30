## Step-2 tests: loot generation, pickup routing, equip/swap, backpack
## overflow, forage, death drops, determinism with item verbs.

import std/json
import zero_sum/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(seed = 42): Sim =
  let cfg = parseSimConfig(%*{"seed": seed, "max_ticks": 2000, "freeze_ticks": 48},
                           fixedSeed)
  initSim(cfg)

proc skipFreeze(s: var Sim) =
  while s.phase == phCountdown:
    s.step()

proc teleport(s: var Sim, slot: int, p: Pos) =
  ## test helper: place agent directly
  s.agents[slot].pos = p

block loot_generated:
  var s = mkSim()
  # tier-1: chamber contains exactly 2 swords, 1 bow, 12 arrows, 1 blowgun,
  # 8 darts, 1 first aid, 1 camo
  var swords, bows, arrows, camo: int
  for g in s.ground:
    if g.pos.x in ChamberLo .. ChamberHi and g.pos.y in ChamberLo .. ChamberHi:
      case g.item
      of iSword: inc swords
      of iBow: inc bows
      of iArrows: arrows += g.n
      of iCamo: inc camo
      else: discard
  doAssert swords == 2 and bows == 1 and arrows == 12 and camo == 1
  doAssert s.bushes.len > 0
  for b in s.bushes:
    doAssert b.charges in 1 .. 3
    doAssert s.arena.tile(b.pos) == tkBush

block pickup_routing:
  var s = mkSim()
  s.skipFreeze()
  # drop a sword under agent 0, pick it up -> hand
  let p = s.agents[0].pos
  s.ground.add(GroundItem(pos: p, item: iSword, n: 1, durability: 40))
  s.submitAction(AgentId(0), Action(kind: akPickup))
  s.step()
  doAssert s.agents[0].hand == iSword
  doAssert s.agents[0].handDur == 40
  # second weapon routes to pack
  s.ground.add(GroundItem(pos: p, item: iSpear, n: 1, durability: 40))
  s.submitAction(AgentId(0), Action(kind: akPickup))
  s.step()
  doAssert s.agents[0].pack[0].item == iSpear
  # equip swap: use pack slot 0 -> spear to hand, sword to pack
  s.submitAction(AgentId(0), Action(kind: akUse, invSlot: 0))
  s.step()
  doAssert s.agents[0].hand == iSpear
  doAssert s.agents[0].pack[0].item == iSword

block pack_capacity:
  var s = mkSim()
  s.skipFreeze()
  let p = s.agents[1].pos
  # no backpack: 2 slots. fill with rations stacks + overflow rejected
  s.ground.add(GroundItem(pos: p, item: iRations, n: 5))
  s.submitAction(AgentId(1), Action(kind: akPickup))
  s.step()
  s.ground.add(GroundItem(pos: p, item: iFirstAid, n: 2))
  s.submitAction(AgentId(1), Action(kind: akPickup))
  s.step()
  s.ground.add(GroundItem(pos: p, item: iDarts, n: 4))
  s.submitAction(AgentId(1), Action(kind: akPickup))
  s.step()
  doAssert s.agents[1].pack[0].item == iRations and s.agents[1].pack[0].n == 5
  doAssert s.agents[1].pack[1].item == iFirstAid
  # darts had nowhere to go (slots 2..3 need backpack) -> still on ground
  var dartsOnGround = false
  for g in s.ground:
    if g.pos == p and g.item == iDarts and g.n == 4:
      dartsOnGround = true
  doAssert dartsOnGround

block backpack_overflow_drop:
  var s = mkSim()
  s.skipFreeze()
  let p = s.agents[2].pos
  var a = addr s.agents[2]
  a.body = iBackpack
  a.pack[2] = PackSlot(item: iRations, n: 3)
  a.pack[3] = PackSlot(item: iDarts, n: 2)
  # equip camo from pack slot 0 -> backpack drops, overflow slots drop
  a.pack[0] = PackSlot(item: iCamo, n: 1)
  s.submitAction(AgentId(2), Action(kind: akUse, invSlot: 0))
  s.step()
  doAssert s.agents[2].body == iCamo
  var sawPack, sawRations, sawDarts: bool
  for g in s.ground:
    if g.pos == p:
      if g.item == iBackpack: sawPack = true
      if g.item == iRations and g.n == 3: sawRations = true
      if g.item == iDarts and g.n == 2: sawDarts = true
  doAssert sawPack and sawRations and sawDarts
  doAssert s.agents[2].pack[2].item == iNone and s.agents[2].pack[3].item == iNone

block forage:
  var s = mkSim()
  s.skipFreeze()
  let bushPos = s.bushes[0].pos
  let before = s.bushes[0].charges
  s.teleport(3, bushPos)
  s.submitAction(AgentId(3), Action(kind: akInteract))
  s.step()
  doAssert s.agents[3].channeling.kind == chForage
  for _ in 0 ..< 24:
    s.step()
  doAssert s.bushes[0].charges == before - 1
  doAssert s.agents[3].pack[0].item == iRations

block eating_heals:
  var s = mkSim()
  s.skipFreeze()
  var a = addr s.agents[4]
  a.hpCenti = 5000
  a.pack[0] = PackSlot(item: iRations, n: 1)
  s.submitAction(AgentId(4), Action(kind: akUse, invSlot: 0))
  s.step()
  for _ in 0 ..< 24:
    s.step()
  doAssert s.agents[4].hpCenti == 6500      # +15 HP
  doAssert s.agents[4].pack[0].item == iNone

block death_drops:
  var s = mkSim()
  s.skipFreeze()
  var a = addr s.agents[5]
  a.hand = iSword; a.handN = 1; a.handDur = 12
  a.body = iBackpack
  a.pack[0] = PackSlot(item: iRations, n: 2)
  let p = a.pos
  a.hpCenti = 0
  s.step()
  doAssert not s.agents[5].alive
  var sawSword, sawPack, sawRations: bool
  for g in s.ground:
    if g.pos == p:
      if g.item == iSword and g.durability == 12: sawSword = true
      if g.item == iBackpack: sawPack = true
      if g.item == iRations and g.n == 2: sawRations = true
  doAssert sawSword and sawPack and sawRations

block determinism_with_items:
  var a = mkSim()
  var b = mkSim()
  for t in 0 ..< 400:
    for s in [addr a, addr b]:
      if t == 60:
        s[].submitAction(AgentId(0), Action(kind: akMove, dir: dW))
      if t == 100:
        s[].submitAction(AgentId(0), Action(kind: akPickup))
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

block hash_covers_inventory:
  var a = mkSim()
  var b = mkSim()
  b.agents[0].pack[0] = PackSlot(item: iRations, n: 1)
  doAssert a.tickHash() != b.tickHash()

echo "t_step2 ok"


