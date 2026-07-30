## Deterministic sim core. Steps 1-2: freeze/mines/ignition/movement + loot,
## inventory, forage. Resolution order per DESIGN Â§1.2 (part of the spec).
## PRNG consumption order (Â§15.1): rocks -> crate positions -> crate contents
## -> bushes -> tier-1 -> tier-2, then per-tick in Â§1.2 step order.

import std/[json, tables]
import prng, types, arena

type
  ActionKind* = enum
    akNone, akMove, akPickup, akDrop, akUse, akInteract

  Action* = object
    kind*: ActionKind
    dir*: Dir8
    invSlot*: int              # SlotHand / SlotBody / 0..3 (drop, use)

  AppliedInput* = object
    tick*: int
    slot*: int
    payload*: string

  SimConfig* = object
    seed*: uint64
    seedWasMinted*: bool
    maxTicks*: int
    freezeTicks*: int

  Sim* = object
    cfg*: SimConfig
    rng*: Prng
    arena*: Arena
    agents*: array[16, Agent]
    ground*: seq[GroundItem]
    bushes*: seq[Bush]
    projectiles*: seq[Projectile]
    tick*: int
    phase*: Phase
    ignitionTick*: int
    events*: seq[Event]
    inputLog*: seq[AppliedInput]
    hashes*: seq[(int, uint64)]
    winnerSlot*: int
    pendingActions: array[16, Action]
    pendingSet: array[16, bool]

proc allocDeadlineTick*(s: Sim): int = s.cfg.freezeTicks - 24
proc moveCooldown*(a: Agent): int = 16 - a.stats.speed

# ---------------------------------------------------------------- config

proc parseSimConfig*(node: JsonNode, mintSeed: proc(): uint64): SimConfig =
  result.maxTicks = node{"max_ticks"}.getInt(9120)
  result.freezeTicks = node{"freeze_ticks"}.getInt(240)
  if node.hasKey("seed"):
    result.seed = uint64(node["seed"].getBiggestInt())
    result.seedWasMinted = false
  else:
    result.seed = mintSeed()
    result.seedWasMinted = true

proc effectiveConfigJson*(cfg: SimConfig, original: JsonNode): string =
  var eff = copy(original)
  eff["seed"] = %int64(cfg.seed)
  if eff.hasKey("tokens"):
    eff.delete("tokens")
  $eff

# ---------------------------------------------------------------- loot gen

proc groundAt*(s: Sim, p: Pos): seq[int] =
  for i, g in s.ground:
    if g.pos == p:
      result.add(i)

proc bushAt*(s: Sim, p: Pos): int =
  for i, b in s.bushes:
    if b.pos == p:
      return i
  -1

proc dropGround(s: var Sim, p: Pos, item: ItemId, n = 1, durability = 0) =
  if item == iNone or n <= 0:
    return
  s.ground.add(GroundItem(pos: p, item: item, n: n, durability: durability))

proc freeLootTile(s: var Sim, rLo2, rHi2, spacing: int,
                  taken: var seq[Pos]): Pos =
  ## Seeded rejection sampling for a ground tile in a Euclidean ring.
  const C = ArenaSize div 2
  for _ in 0 ..< 400:
    let x = 2 + s.rng.rand(ArenaSize - 4)
    let y = 2 + s.rng.rand(ArenaSize - 4)
    let d2 = (x - C) * (x - C) + (y - C) * (y - C)
    if d2 < rLo2 or d2 > rHi2:
      continue
    let p = Pos(x: x, y: y)
    if s.arena.tile(p) != tkGround:
      continue
    var ok = true
    for t in taken:
      if abs(t.x - x) < spacing and abs(t.y - y) < spacing:
        ok = false
    if ok:
      taken.add(p)
      return p
  Pos(x: -1, y: -1)

proc rollCrate(s: var Sim, p: Pos) =
  let r = s.rng.rand(100)
  if r < 25: s.dropGround(p, iRations, 2)
  elif r < 40: s.dropGround(p, iKnives, 4)
  elif r < 55: s.dropGround(p, iArrows, 6)
  elif r < 65: s.dropGround(p, iDarts, 4)
  elif r < 75: s.dropGround(p, iNet, 1)
  elif r < 85: s.dropGround(p, iBackpack, 1)
  elif r < 95: s.dropGround(p, iSpear, 1, def(iSpear).durability)
  else: s.dropGround(p, iFirstAid, 1)

proc chamberTiles(): seq[Pos] =
  for y in ChamberLo .. ChamberHi:
    for x in ChamberLo .. ChamberHi:
      result.add(Pos(x: x, y: y))

proc mouthTiles(): array[4, Pos] =
  ## One tier-2 spawn tile just inside each mouth (N, E, S, W).
  [Pos(x: 23, y: FortressLo + 1), Pos(x: FortressHi - 1, y: 23),
   Pos(x: 24, y: FortressHi - 1), Pos(x: FortressLo + 1, y: 24)]

proc generateLoot(s: var Sim) =
  # crate positions, then contents
  var taken: seq[Pos] = @[]
  var crates: seq[Pos] = @[]
  for _ in 0 ..< 20:
    let p = s.freeLootTile(81, 196, 3, taken)     # ring 9..14
    if p.x >= 0:
      crates.add(p)
  for p in crates:
    s.rollCrate(p)
  # bushes
  var bushTaken: seq[Pos] = @[]
  for _ in 0 ..< 12:
    let p = s.freeLootTile(324, 484, 3, bushTaken) # ring 18..22
    if p.x >= 0:
      s.arena.tiles[p.y][p.x] = tkBush
      s.bushes.add(Bush(pos: p, charges: 1 + s.rng.rand(3)))
  # tier-1: 6 distinct chamber tiles
  var chamber = chamberTiles()
  var t1: seq[Pos] = @[]
  for _ in 0 ..< 6:
    let idx = s.rng.rand(chamber.len)
    t1.add(chamber[idx])
    chamber.delete(idx)
  s.dropGround(t1[0], iSword, 1, def(iSword).durability)
  s.dropGround(t1[1], iSword, 1, def(iSword).durability)
  s.dropGround(t1[2], iBow, 1)
  s.dropGround(t1[2], iArrows, 12)
  s.dropGround(t1[3], iBlowgun, 1)
  s.dropGround(t1[3], iDarts, 8)
  s.dropGround(t1[4], iFirstAid, 1)
  s.dropGround(t1[5], iCamo, 1)
  # tier-2: seeded assignment of 4 items to the 4 mouths
  var mouthItems = @[(iSpear, 1, def(iSpear).durability), (iNet, 1, 0),
                     (iKnives, 6, 0), (iFirstAid, 1, 0)]
  let mouths = mouthTiles()
  for m in 0 .. 3:
    let idx = s.rng.rand(mouthItems.len)
    let (it, n, dur) = mouthItems[idx]
    mouthItems.delete(idx)
    s.dropGround(mouths[m], it, n, dur)

# ---------------------------------------------------------------- init

proc initSim*(cfg: SimConfig): Sim =
  result.cfg = cfg
  result.rng = initPrng(cfg.seed)
  result.arena = buildArena(result.rng)
  result.tick = 0
  result.phase = phCountdown
  result.ignitionTick = cfg.freezeTicks
  result.winnerSlot = -1
  for i in 0 .. 15:
    result.agents[i] = Agent(
      slot: AgentId(i), alive: true, pos: Pedestals[i],
      hpCenti: MaxHpCenti,
      stats: Stats(speed: 5, strength: 5, intelligence: 5, athleticism: 5),
      moveReadyTick: 0, attackReadyTick: 0, deathTick: -1,
      lastDamager: -1)
  result.generateLoot()

# ---------------------------------------------------------------- actions

proc submitAction*(s: var Sim, slot: AgentId, act: Action) =
  if not s.pendingSet[slot]:
    s.pendingActions[slot] = act
    s.pendingSet[slot] = true

proc actionJson(act: Action): string =
  case act.kind
  of akNone: """{"do":"none"}"""
  of akMove: """{"do":"move","dir":"""" & $act.dir & """"}"""
  of akPickup: """{"do":"pickup"}"""
  of akDrop: """{"do":"drop","slot":""" & $act.invSlot & "}"
  of akUse: """{"do":"use","slot":""" & $act.invSlot & "}"
  of akInteract: """{"do":"interact"}"""

proc emit(s: var Sim, kind: EventKind, slot = -1, pos = Pos(x: -1, y: -1),
          data = "") =
  s.events.add(Event(tick: s.tick, kind: kind, slot: slot, pos: pos, data: data))

proc agentAt(s: Sim, p: Pos): int =
  for i in 0 .. 15:
    if s.agents[i].alive and s.agents[i].pos == p:
      return i
  -1

# ---------------------------------------------------------------- movement

proc resolveMovement(s: var Sim) =
  var intent: array[16, PendingMove]
  for i in 0 .. 15:
    let a = s.agents[i]
    if not a.alive or not s.pendingSet[i] or s.pendingActions[i].kind != akMove:
      continue
    if s.tick < a.moveReadyTick or s.tick < a.nettedUntil:
      continue
    let target = a.pos + s.pendingActions[i].dir
    if not inBounds(target) or blocksMovement(s.arena.tile(target)):
      continue
    intent[i] = PendingMove(slot: AgentId(i), target: target, active: true)

  for i in 0 .. 15:
    if not intent[i].active: continue
    for j in i + 1 .. 15:
      if not intent[j].active: continue
      if intent[i].target == s.agents[j].pos and intent[j].target == s.agents[i].pos:
        intent[i].active = false
        intent[j].active = false

  var contenders = initTable[int, seq[int]]()
  for i in 0 .. 15:
    if intent[i].active:
      contenders.mgetOrPut(intent[i].target.y * ArenaSize + intent[i].target.x,
                           @[]).add(i)
  var keys: seq[int] = @[]
  for k in contenders.keys: keys.add(k)
  for pass in 0 ..< keys.len:
    for j in 0 ..< keys.len - 1 - pass:
      if keys[j] > keys[j + 1]:
        let t = keys[j]; keys[j] = keys[j + 1]; keys[j + 1] = t
  for k in keys:
    let group = contenders[k]
    if group.len > 1:
      let winner = group[s.rng.rand(group.len)]
      for slot in group:
        if slot != winner:
          intent[slot].active = false

  var changed = true
  while changed:
    changed = false
    for i in 0 .. 15:
      if not intent[i].active: continue
      let occ = s.agentAt(intent[i].target)
      if occ >= 0 and occ != i and not intent[occ].active:
        intent[i].active = false
        changed = true

  for i in 0 .. 15:
    if intent[i].active:
      let a = addr s.agents[i]
      let wasOnPedestal = s.arena.tile(a.pos) == tkPedestal
      a.pos = intent[i].target
      a.moveReadyTick = s.tick + moveCooldown(a[])
      if s.phase == phCountdown and wasOnPedestal:
        a.hpCenti = 0
        s.emit(evMineExplosion, i, a.pos)

# ---------------------------------------------------------------- inventory

proc tryPack(a: var Agent, item: ItemId, n: var int, durability: int): bool =
  ## Merge into stacks, then first free slot. Returns true if ANY amount landed.
  result = false
  let d = def(item)
  if d.stackMax > 1:
    for idx in 0 ..< a.packSlots:
      if a.pack[idx].item == item and a.pack[idx].n < d.stackMax:
        let take = min(n, d.stackMax - a.pack[idx].n)
        a.pack[idx].n += take
        n -= take
        result = result or take > 0
        if n == 0: return
  for idx in 0 ..< a.packSlots:
    if a.pack[idx].item == iNone:
      let take = min(n, d.stackMax)
      a.pack[idx] = PackSlot(item: item, n: take, durability: durability)
      n -= take
      result = result or take > 0
      if n == 0: return

proc resolvePickup(s: var Sim, i: int) =
  let a = addr s.agents[i]
  let here = s.groundAt(a.pos)
  if here.len == 0:
    return
  let gi = here[0]
  var g = s.ground[gi]
  let d = def(g.item)
  var tookAll = false
  case d.kind
  of ikMelee, ikRanged, ikThrown:
    if a.hand == iNone:
      a.hand = g.item
      a.handN = g.n
      a.handDur = g.durability
      tookAll = true
    elif a.hand == g.item and d.kind == ikThrown and a.handN < d.stackMax:
      let take = min(g.n, d.stackMax - a.handN)
      a.handN += take
      g.n -= take
      tookAll = g.n == 0
    else:
      var n = g.n
      discard tryPack(a[], g.item, n, g.durability)
      g.n = n
      tookAll = n == 0
  of ikGear:
    if a.body == iNone:
      a.body = g.item
      tookAll = true
    else:
      var n = g.n
      discard tryPack(a[], g.item, n, 0)
      g.n = n
      tookAll = n == 0
  of ikConsumable, ikAmmo:
    var n = g.n
    discard tryPack(a[], g.item, n, 0)
    g.n = n
    tookAll = n == 0
  if tookAll:
    s.ground.delete(gi)
  else:
    s.ground[gi] = g

proc unequipBodyToGround(s: var Sim, i: int) =
  ## Dropping/replacing a backpack sheds overflow slots 2..3 (DESIGN Â§3.1).
  let a = addr s.agents[i]
  if a.body == iNone:
    return
  s.dropGround(a.pos, a.body, 1)
  if a.body == iBackpack:
    for idx in 2 .. 3:
      if a.pack[idx].item != iNone:
        s.dropGround(a.pos, a.pack[idx].item, a.pack[idx].n, a.pack[idx].durability)
        a.pack[idx] = PackSlot()
  a.body = iNone

proc resolveDrop(s: var Sim, i: int, invSlot: int) =
  let a = addr s.agents[i]
  case invSlot
  of SlotHand:
    if a.hand != iNone:
      s.dropGround(a.pos, a.hand, max(1, a.handN), a.handDur)
      a.hand = iNone; a.handN = 0; a.handDur = 0
  of SlotBody:
    s.unequipBodyToGround(i)
  else:
    if invSlot in 0 .. 3 and a.pack[invSlot].item != iNone:
      s.dropGround(a.pos, a.pack[invSlot].item, a.pack[invSlot].n,
                   a.pack[invSlot].durability)
      a.pack[invSlot] = PackSlot()

proc resolveUse(s: var Sim, i: int, invSlot: int) =
  let a = addr s.agents[i]
  if invSlot notin 0 .. 3 or invSlot >= a[].packSlots:
    return
  let slotItem = a.pack[invSlot].item
  if slotItem == iNone:
    return
  let d = def(slotItem)
  case d.kind
  of ikMelee, ikRanged, ikThrown:
    # equip swap: hand <-> pack slot (DESIGN Â§3.1); brief attack lockout
    let oldHand = a.hand
    let oldN = a.handN
    let oldDur = a.handDur
    a.hand = slotItem
    a.handN = a.pack[invSlot].n
    a.handDur = a.pack[invSlot].durability
    if oldHand == iNone:
      a.pack[invSlot] = PackSlot()
    else:
      a.pack[invSlot] = PackSlot(item: oldHand, n: oldN, durability: oldDur)
    a.attackReadyTick = max(a.attackReadyTick, s.tick + 6)
  of ikGear:
    let newBody = slotItem
    a.pack[invSlot] = PackSlot()
    s.unequipBodyToGround(i)
    a.body = newBody
  of ikConsumable:
    a.channeling = Channeling(kind: chConsume, item: slotItem, packIdx: invSlot,
                        doneTick: s.tick + d.useTicks)
  of ikAmmo:
    discard

proc resolveInteract(s: var Sim, i: int) =
  let a = addr s.agents[i]
  let bi = s.bushAt(a.pos)
  if bi >= 0 and s.bushes[bi].charges > 0 and a.channeling.kind == chNone:
    a.channeling = Channeling(kind: chForage, item: iRations, packIdx: -1,
                        doneTick: s.tick + 24)

proc resolveChannels(s: var Sim) =
  for i in 0 .. 15:
    let a = addr s.agents[i]
    if not a.alive or a.channeling.kind == chNone or s.tick < a.channeling.doneTick:
      continue
    case a.channeling.kind
    of chConsume:
      let idx = a.channeling.packIdx
      if idx in 0 .. 3 and a.pack[idx].item == a.channeling.item and a.pack[idx].n > 0:
        a.hpCenti = min(MaxHpCenti, a.hpCenti + def(a.channeling.item).heal * 100)
        dec a.pack[idx].n
        if a.pack[idx].n == 0:
          a.pack[idx] = PackSlot()
    of chForage:
      let bi = s.bushAt(a.pos)
      if bi >= 0 and s.bushes[bi].charges > 0:
        dec s.bushes[bi].charges
        var n = 1
        # INT double-yield roll arrives with step 4 stat effects
        discard tryPack(a[], iRations, n, 0)
        if n > 0:
          s.dropGround(a.pos, iRations, n)
    of chNone:
      discard
    a.channeling = Channeling()

# ---------------------------------------------------------------- deaths

proc dropAllInventory(s: var Sim, i: int) =
  let a = addr s.agents[i]
  if a.hand != iNone:
    s.dropGround(a.pos, a.hand, max(1, a.handN), a.handDur)
    a.hand = iNone; a.handN = 0; a.handDur = 0
  if a.body != iNone:
    s.dropGround(a.pos, a.body, 1)
    a.body = iNone
  for idx in 0 .. 3:
    if a.pack[idx].item != iNone:
      s.dropGround(a.pos, a.pack[idx].item, a.pack[idx].n, a.pack[idx].durability)
      a.pack[idx] = PackSlot()

proc resolveDeaths(s: var Sim) =
  for i in 0 .. 15:
    let a = addr s.agents[i]
    if a.alive and a.hpCenti <= 0:
      a.alive = false
      a.deathTick = s.tick
      s.dropAllInventory(i)
      s.emit(evDeathFireworks, i, a.pos)
      s.emit(evBoom, i, a.pos)

proc aliveCount*(s: Sim): int =
  for a in s.agents:
    if a.alive: inc result

# ---------------------------------------------------------------- hash

proc fnv1a(h: var uint64, v: uint64) {.inline.} =
  var x = v
  for _ in 0 .. 7:
    h = (h xor (x and 0xFF)) * 0x100000001B3'u64
    x = x shr 8

proc tickHash*(s: Sim): uint64 =
  var h = 0xCBF29CE484222325'u64
  fnv1a(h, uint64(s.tick))
  fnv1a(h, uint64(ord(s.phase)))
  for a in s.agents:
    fnv1a(h, uint64(a.pos.x))
    fnv1a(h, uint64(a.pos.y))
    fnv1a(h, uint64(cast[uint32](int32(a.hpCenti))))
    fnv1a(h, uint64(ord(a.alive)))
    fnv1a(h, uint64(cast[uint32](int32(a.deathTick))))
    fnv1a(h, uint64(ord(a.hand)))
    fnv1a(h, uint64(cast[uint32](int32(a.handN))))
    fnv1a(h, uint64(cast[uint32](int32(a.handDur))))
    fnv1a(h, uint64(ord(a.body)))
    for ps in a.pack:
      fnv1a(h, uint64(ord(ps.item)))
      fnv1a(h, uint64(cast[uint32](int32(ps.n))))
      fnv1a(h, uint64(cast[uint32](int32(ps.durability))))
    fnv1a(h, uint64(ord(a.channeling.kind)))
    fnv1a(h, uint64(cast[uint32](int32(a.channeling.doneTick))))
  for g in s.ground:
    fnv1a(h, uint64(g.pos.x))
    fnv1a(h, uint64(g.pos.y))
    fnv1a(h, uint64(ord(g.item)))
    fnv1a(h, uint64(cast[uint32](int32(g.n))))
  for b in s.bushes:
    fnv1a(h, uint64(cast[uint32](int32(b.charges))))
  for w in s.rng.state():
    fnv1a(h, w)
  h

# ---------------------------------------------------------------- tick

proc step*(s: var Sim) =
  if s.phase == phEnded:
    return
  s.events.setLen(0)
  for i in 0 .. 15:
    s.agents[i].damageTakenCenti = 0

  # 1. log applied inputs
  for i in 0 .. 15:
    if s.pendingSet[i] and s.agents[i].alive:
      s.inputLog.add(AppliedInput(tick: s.tick, slot: i,
        payload: actionJson(s.pendingActions[i])))

  # 2. phase transitions
  if s.phase == phCountdown and s.tick == s.ignitionTick:
    s.phase = phLive
    s.emit(evIgnition, -1, Pos(x: ArenaSize div 2, y: ArenaSize div 2))

  # 3. movement
  s.resolveMovement()

  # 4-6. combat, projectiles, effects â€” step 3 of the build plan.

  # 7. item verbs: completions first, then pickups, then drops/use/interact
  s.resolveChannels()
  if s.phase == phLive:
    for i in 0 .. 15:
      if not s.pendingSet[i] or not s.agents[i].alive:
        continue
      case s.pendingActions[i].kind
      of akPickup: s.resolvePickup(i)
      of akDrop: s.resolveDrop(i, s.pendingActions[i].invSlot)
      of akUse: s.resolveUse(i, s.pendingActions[i].invSlot)
      of akInteract: s.resolveInteract(i)
      else: discard

  # 8. deaths
  s.resolveDeaths()

  # 9. win check + bookkeeping
  if s.aliveCount() <= 1 and s.phase == phLive:
    for i in 0 .. 15:
      if s.agents[i].alive:
        s.winnerSlot = i
    s.phase = phEnded
    s.emit(evMatchEnd, s.winnerSlot)
  elif s.tick + 1 >= s.cfg.maxTicks:
    for i in 0 .. 15:
      if s.agents[i].alive:
        s.agents[i].hpCenti = 0
    s.resolveDeaths()
    s.phase = phEnded
    s.emit(evMatchEnd, -1)

  s.hashes.add((s.tick, s.tickHash()))
  for i in 0 .. 15:
    s.pendingSet[i] = false
  inc s.tick


