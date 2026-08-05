## Deterministic sim core. Steps 1-2: freeze/mines/ignition/movement + loot,
## inventory, forage. Resolution order per DESIGN §1.2 (part of the spec).
## PRNG consumption order (§15.1): rocks -> crate positions -> crate contents
## -> bushes -> tier-1 -> tier-2, then per-tick in §1.2 step order.

import std/[json, tables]
import prng, types, arena

type
  ActionKind* = enum
    akNone, akMove, akAttack, akPickup, akDrop, akUse, akInteract

  Action* = object
    kind*: ActionKind
    dir*: Dir8
    invSlot*: int              # SlotHand / SlotBody / 0..3 (drop, use)

  AppliedInput* = object
    tick*: int
    slot*: int
    payload*: string

  ZoneStage* = object
    warnT*, shrinkT*, doneT*: int
    rStart*, rEnd*: int
    dmgPerS*: int              # whole HP per second, ATH-scaled on application

  EventCfgKind* = enum
    ecFlood = "flood", ecFirestorm = "firestorm"

  ScriptedEvent* = object
    kind*: EventCfgKind
    rect*: array[4, int]       # flood: x0,y0,x1,y1
    center*: Pos               # firestorm
    radius*: int
    fromTick*: int
    duration*: int

  ScriptedGift* = object
    tick*: int
    team*: int                 # 0..7
    recipientSlot*: int        # legacy targeting (v0.1 replay compat)
    target*: Pos               # tile targeting (v0.2); x = -1 when unused
    itemId*: string            # catalog key

  SponsorConfig* = object
    live*: bool
    budgetPerTeam*: int
    shopOpensTick*: int
    scriptedGifts*: seq[ScriptedGift]

  SimConfig* = object
    seed*: uint64
    seedWasMinted*: bool
    maxTicks*: int
    freezeTicks*: int
    zone*: seq[ZoneStage]
    events*: seq[ScriptedEvent]
    playerNames*: seq[string]
    sponsor*: SponsorConfig

  GiftStatus* = enum
    gsAccepted = "accepted", gsRejected = "rejected"

  GiftRecord* = object
    tickRequested*: int
    tickLanded*: int           # -1 until landed / for rejects
    sponsor*: string
    team*: int
    recipientSlot*: int        # -1 for tile-targeted (v0.2) gifts
    target*: Pos               # requested tile; x = -1 for legacy gifts
    itemId*: string
    cost*: int
    status*: GiftStatus
    reason*: string            # rejection reason, "" for accepts
    balanceAfter*: int

  Pod* = object
    landing*: Pos
    itemId*: string
    recipientSlot*: int
    spawnTick*: int
    landsTick*: int
    landed*: bool

  GiftOutcome* = object
    accepted*: bool
    reason*: string
    cost*: int
    balance*: int
    landsTick*: int
    landing*: Pos

  TalkChannel* = enum
    tcBroadcast = "broadcast", tcTeam = "team", tcDm = "dm"

  TalkMsg* = object
    tick*: int
    slot*: int
    channel*: TalkChannel
    to*: int                   # dm target, -1 otherwise
    text*: string

  TalkResult* = enum
    tkAccepted, tkRateLimited, tkRejected

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
    eventHistory*: seq[Event]
    talkLog*: seq[TalkMsg]
    inbox*: array[16, seq[TalkMsg]]   # delivered THIS tick (previous tick's talk)
    lastTalkTick: array[16, int]
    talkQueue: seq[TalkMsg]
    inputLog*: seq[AppliedInput]
    hashes*: seq[(int, uint64)]
    winnerSlot*: int
    teamBudget*: array[8, int]
    lastGiftTick*: array[8, int]   # tile-gift lockout bookkeeping (v0.2)
    sponsorLog*: seq[GiftRecord]
    pods*: seq[Pod]
    finaleEmitted*: bool
    lastActionResult*: array[16, string]
    inStep: bool
    pendingEvents: seq[Event]      # emitted between ticks by live gift intake;
                                   # spliced into the next tick
    pendingActions: array[16, Action]
    pendingSet: array[16, bool]

proc allocDeadlineTick*(s: Sim): int = s.cfg.freezeTicks - 24
proc giftLockoutRemaining*(s: Sim, teamIdx: int): int =
  ## Ticks until the team may buy the next tile-targeted package.
  max(0, GiftLockoutTicks - (s.tick - s.lastGiftTick[teamIdx]))
proc moveCooldown*(a: Agent): int = 16 - a.stats.speed
proc visionRadius*(a: Agent): int = 5 + (a.stats.intelligence + 1) div 2
proc hazardScaled*(a: Agent, centi: int): int =
  ## Zone/event damage after athleticism reduction (DESIGN §5.2).
  centi * (100 - 3 * a.stats.athleticism) div 100

type AllocResult* = enum
  arAccepted, arRejectedInvalid, arRejectedDuplicate, arRejectedLate

# ---------------------------------------------------------------- config

const DefaultZone*: array[7, ZoneStage] = [
  ## DESIGN §7.1, DECIDED fast ~5-min close. Every boundary a multiple of 24.
  ZoneStage(warnT: 1440, shrinkT: 1632, doneT: 2064, rStart: 24, rEnd: 19, dmgPerS: 1),
  ZoneStage(warnT: 2352, shrinkT: 2544, doneT: 2976, rStart: 19, rEnd: 15, dmgPerS: 2),
  ZoneStage(warnT: 3264, shrinkT: 3456, doneT: 3888, rStart: 15, rEnd: 11, dmgPerS: 4),
  ZoneStage(warnT: 4176, shrinkT: 4368, doneT: 4800, rStart: 11, rEnd: 8, dmgPerS: 6),
  ZoneStage(warnT: 5088, shrinkT: 5280, doneT: 5712, rStart: 8, rEnd: 5, dmgPerS: 8),
  ZoneStage(warnT: 6000, shrinkT: 6192, doneT: 6624, rStart: 5, rEnd: 3, dmgPerS: 16),
  ZoneStage(warnT: 6912, shrinkT: 7104, doneT: 7536, rStart: 3, rEnd: 0, dmgPerS: 24)]

proc parseSimConfig*(node: JsonNode, mintSeed: proc(): uint64): SimConfig =
  result.maxTicks = node{"max_ticks"}.getInt(9120)
  result.freezeTicks = node{"freeze_ticks"}.getInt(240)
  if node.hasKey("seed"):
    result.seed = cast[uint64](node["seed"].getBiggestInt())
    result.seedWasMinted = false
  else:
    result.seed = mintSeed()
    result.seedWasMinted = true
  # Structural validation raises ValueError with a plain message — callers
  # turn that into a clean non-zero exit, never a stack trace. The platform
  # schema catches most of this for hosted play; local and future
  # commissioner-override configs bypass the schema entirely.
  if result.maxTicks < 100 or result.maxTicks > 20000:
    raise newException(ValueError, "config: max_ticks must be 100..20000")
  if result.freezeTicks < 1 or result.freezeTicks >= result.maxTicks:
    raise newException(ValueError, "config: freeze_ticks out of range")
  if node.hasKey("zone") and node["zone"].hasKey("schedule"):
    for row in node["zone"]["schedule"]:
      if row.kind != JArray or row.len < 6:
        raise newException(ValueError,
          "config: zone.schedule rows must be 6-int arrays " &
          "[warn, shrink, done, r_start, r_end, damage_per_s]")
      result.zone.add(ZoneStage(
        warnT: row[0].getInt(), shrinkT: row[1].getInt(), doneT: row[2].getInt(),
        rStart: row[3].getInt(), rEnd: row[4].getInt(), dmgPerS: row[5].getInt()))
  else:
    for st in DefaultZone:
      result.zone.add(st)
  for st in result.zone:
    if st.warnT < 0 or st.shrinkT < st.warnT or st.doneT <= st.shrinkT:
      # doneT == shrinkT would divide by zero in zoneRadius
      raise newException(ValueError,
        "config: zone stage needs 0 <= warn <= shrink < done (got " &
        $st.warnT & "/" & $st.shrinkT & "/" & $st.doneT & ")")
    if st.rEnd < 0 or st.rEnd > st.rStart:
      raise newException(ValueError,
        "config: zone stage needs 0 <= r_end <= r_start")
  result.sponsor.budgetPerTeam = 300
  result.sponsor.shopOpensTick = 1680
  if node.hasKey("sponsor"):
    let sp = node["sponsor"]
    result.sponsor.live = sp{"live"}.getBool(false)
    result.sponsor.budgetPerTeam = sp{"budget_per_team"}.getInt(300)
    result.sponsor.shopOpensTick = sp{"shop_opens_tick"}.getInt(1680)
    if sp.hasKey("scripted_gifts"):
      for g in sp["scripted_gifts"]:
        var teamIdx = -1
        let teamStr = g{"team"}.getStr("")
        for ti, tn in TeamNames:
          if tn == teamStr:
            teamIdx = ti
        var tgt = Pos(x: -1, y: -1)
        if g.hasKey("target") and g["target"].kind == JArray and
           g["target"].len == 2:
          tgt = Pos(x: g["target"][0].getInt(-1), y: g["target"][1].getInt(-1))
        result.sponsor.scriptedGifts.add(ScriptedGift(
          tick: g{"tick"}.getInt(),
          team: (if teamIdx >= 0: teamIdx else: g{"team"}.getInt(-1)),
          recipientSlot: g{"recipient_slot"}.getInt(-1),
          target: tgt,
          itemId: g{"item_id"}.getStr("")))
  const DefaultNames = [
    "Adino", "Tryphena",       # team A
    "Carpus", "Tazkia",        # team B
    "Luqman", "Sherah",        # team C
    "Karna", "Damaris",        # team D
    "Archippus", "Balqees",    # team E
    "Kaysan", "Urvasi",        # team F
    "Sanjaya", "Tirzah",       # team G
    "Zimri", "Bhishma"]        # team H
  for i in 0 .. 15:
    result.playerNames.add(DefaultNames[i])
  if node.hasKey("players"):
    for i, p in node["players"].elems:
      if i < 16 and p.kind == JObject and p{"name"}.getStr("").len > 0:
        result.playerNames[i] = p["name"].getStr()
  if node.hasKey("events"):
    for e in node["events"]:
      var ev = ScriptedEvent(fromTick: e{"from_tick"}.getInt(),
                             duration: e{"duration"}.getInt())
      if ev.duration <= 0:
        raise newException(ValueError, "config: event duration must be > 0")
      if e{"kind"}.getStr() == "flood":
        ev.kind = ecFlood
        if e{"rect"} == nil or e["rect"].kind != JArray or e["rect"].len < 4:
          raise newException(ValueError,
            "config: flood event needs rect [x0, y0, x1, y1]")
        for i in 0 .. 3:
          ev.rect[i] = e["rect"][i].getInt()
      else:
        ev.kind = ecFirestorm
        if e{"center"} == nil or e["center"].kind != JArray or
           e["center"].len < 2:
          raise newException(ValueError,
            "config: firestorm event needs center [x, y]")
        ev.center = Pos(x: e["center"][0].getInt(), y: e["center"][1].getInt())
        ev.radius = e{"radius"}.getInt()
      result.events.add(ev)
  if result.sponsor.budgetPerTeam < 0 or result.sponsor.shopOpensTick < 0:
    raise newException(ValueError,
      "config: sponsor budget/shop_opens_tick must be >= 0")

proc effectiveConfigJson*(cfg: SimConfig, original: JsonNode): string =
  ## Complete effective config for the replay header: minted seed written in,
  ## ALL auth material stripped (runner tokens + sponsor tokens — gifts replay
  ## from the input log, so the secrets are never needed downstream).
  var eff = copy(original)
  # cast, not convert: a full-64-bit seed must round-trip through JSON int64
  # (parse side wraps back via uint64 cast — deterministic both ways)
  eff["seed"] = %cast[int64](cfg.seed)
  if eff.hasKey("tokens"):
    eff.delete("tokens")
  if eff.hasKey("sponsor") and eff["sponsor"].kind == JObject and
     eff["sponsor"].hasKey("sponsor_tokens"):
    eff["sponsor"].delete("sponsor_tokens")
  $eff

# ---------------------------------------------------------------- zone/events

proc zoneRadius*(s: Sim): int =
  ## Pinned formula (DESIGN §7.1): piecewise; during a stage's shrink window
  ## r(t) = rStart - floor((t-shrinkT)*(rStart-rEnd)/(doneT-shrinkT)).
  if s.cfg.zone.len == 0:
    return ArenaSize
  result = s.cfg.zone[0].rStart
  for st in s.cfg.zone:
    if s.tick >= st.doneT:
      result = st.rEnd
    elif s.tick >= st.shrinkT:
      result = st.rStart -
        ((s.tick - st.shrinkT) * (st.rStart - st.rEnd)) div (st.doneT - st.shrinkT)
      break
    else:
      break

proc zoneDamagePerS*(s: Sim): int =
  ## Stage k's damage applies from its warn tick until stage k+1's warn tick;
  ## no damage before stage 1 warns.
  result = 0
  for st in s.cfg.zone:
    if s.tick >= st.warnT:
      result = st.dmgPerS

proc insideZone*(s: Sim, p: Pos): bool =
  let r = s.zoneRadius()
  if r <= 0:
    # Full closure: NO safe tile after the last stage completes (spec §3).
    # Without this, the center tile satisfies 0 <= 0 and standing on
    # (24,24) is a provably dominant endgame — the ring never resolves.
    return false
  let dx = p.x - ArenaSize div 2
  let dy = p.y - ArenaSize div 2
  dx * dx + dy * dy <= r * r

proc eventActive(ev: ScriptedEvent, tick: int): bool =
  tick >= ev.fromTick and tick < ev.fromTick + ev.duration

proc floodedAt*(s: Sim, p: Pos): bool =
  for ev in s.cfg.events:
    if ev.kind == ecFlood and eventActive(ev, s.tick) and
       p.x >= ev.rect[0] and p.y >= ev.rect[1] and
       p.x <= ev.rect[2] and p.y <= ev.rect[3]:
      return true

proc inFirestorm(s: Sim, p: Pos): bool =
  for ev in s.cfg.events:
    if ev.kind == ecFirestorm and eventActive(ev, s.tick):
      let dx = p.x - ev.center.x
      let dy = p.y - ev.center.y
      if dx * dx + dy * dy <= ev.radius * ev.radius:
        return true

proc eventJson(ev: ScriptedEvent): string =
  case ev.kind
  of ecFlood:
    """{"kind":"flood","rect":[""" & $ev.rect[0] & "," & $ev.rect[1] & "," &
      $ev.rect[2] & "," & $ev.rect[3] & """],"from_tick":""" & $ev.fromTick &
      ""","duration":""" & $ev.duration & "}"
  of ecFirestorm:
    """{"kind":"firestorm","center":[""" & $ev.center.x & "," & $ev.center.y &
      """],"radius":""" & $ev.radius & ""","from_tick":""" & $ev.fromTick &
      ""","duration":""" & $ev.duration & "}"

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
    result.lastTalkTick[i] = -24
    result.lastActionResult[i] = "ok"
  for t in 0 .. 7:
    result.teamBudget[t] = cfg.sponsor.budgetPerTeam
    result.lastGiftTick[t] = -GiftLockoutTicks
  result.generateLoot()

# ---------------------------------------------------------------- actions

proc submitAction*(s: var Sim, slot: AgentId, act: Action) =
  if not s.pendingSet[slot]:
    s.pendingActions[slot] = act
    s.pendingSet[slot] = true

proc submitAllocation*(s: var Sim, slot: AgentId, st: Stats): AllocResult =
  ## First valid allocation wins and is immutable (DESIGN §5.1). Applied and
  ## input-logged immediately; a retry after a lost ack must be safe.
  if s.agents[slot].statsLocked:
    return arRejectedDuplicate
  if s.tick > s.allocDeadlineTick() or s.phase != phCountdown:
    return arRejectedLate
  let vals = [st.speed, st.strength, st.intelligence, st.athleticism]
  var sum = 0
  for v in vals:
    if v < 1 or v > 10:
      return arRejectedInvalid
    sum += v
  if sum > 20:
    return arRejectedInvalid
  s.agents[slot].stats = st
  s.agents[slot].statsLocked = true
  s.inputLog.add(AppliedInput(tick: s.tick, slot: int(slot),
    payload: """{"allocate_stats":{"speed":""" & $st.speed &
             ""","strength":""" & $st.strength &
             ""","intelligence":""" & $st.intelligence &
             ""","athleticism":""" & $st.athleticism & "}}"))
  arAccepted

proc actionJson(act: Action): string =
  case act.kind
  of akNone: """{"do":"none"}"""
  of akMove: """{"do":"move","dir":"""" & $act.dir & """"}"""
  of akAttack: """{"do":"attack","dir":"""" & $act.dir & """"}"""
  of akPickup: """{"do":"pickup"}"""
  of akDrop: """{"do":"drop","slot":""" & $act.invSlot & "}"
  of akUse: """{"do":"use","slot":""" & $act.invSlot & "}"
  of akInteract: """{"do":"interact"}"""

proc emit(s: var Sim, kind: EventKind, slot = -1, pos = Pos(x: -1, y: -1),
          data = "") =
  ## Inside step(): lands in this tick's events. Between ticks (gift intake):
  ## deferred and spliced into the NEXT step so the events reset cannot eat it.
  let e = Event(tick: s.tick, kind: kind, slot: slot, pos: pos, data: data)
  if s.inStep:
    s.events.add(e)
    s.eventHistory.add(e)
  else:
    s.pendingEvents.add(e)

proc sanitizeTalk*(text: string): string =
  ## Printable ASCII only (0x20-0x7E), max 120 chars (DESIGN §10.4).
  for c in text:
    if result.len >= 120:
      break
    if ord(c) >= 0x20 and ord(c) <= 0x7E:
      result.add(c)

proc submitTalk*(s: var Sim, slot: AgentId, channel: TalkChannel,
                 to: int, text: string): TalkResult =
  if not s.agents[slot].alive or s.phase == phEnded:
    return tkRejected
  if channel == tcDm and (to < 0 or to > 15 or to == int(slot)):
    return tkRejected
  if s.tick - s.lastTalkTick[slot] < 24:
    s.lastActionResult[slot] = "rate_limited"
    return tkRateLimited
  let clean = sanitizeTalk(text)
  if clean.len == 0:
    return tkRejected
  s.lastTalkTick[slot] = s.tick
  let msg = TalkMsg(tick: s.tick, slot: int(slot), channel: channel,
                    to: (if channel == tcDm: to else: -1), text: clean)
  s.talkLog.add(msg)
  s.talkQueue.add(msg)
  var toJson = if channel == tcDm: $to else: "null"
  s.inputLog.add(AppliedInput(tick: s.tick, slot: int(slot),
    payload: """{"talk":{"channel":"""" & $channel & """","to":""" & toJson &
             ""","text":""" & escapeJson(clean) & "}}"))
  tkAccepted

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
      s.lastActionResult[i] = "cooldown"
      continue
    let target = a.pos + s.pendingActions[i].dir
    if not inBounds(target) or blocksMovement(s.arena.tile(target)):
      s.lastActionResult[i] = "blocked"
      continue
    if s.floodedAt(target) and not s.floodedAt(a.pos):
      s.lastActionResult[i] = "blocked"
      continue                 # may move OFF flooded tiles, never ONTO them
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
          s.lastActionResult[slot] = "blocked"

  var changed = true
  while changed:
    changed = false
    for i in 0 .. 15:
      if not intent[i].active: continue
      let occ = s.agentAt(intent[i].target)
      if occ >= 0 and occ != i and not intent[occ].active:
        intent[i].active = false
        s.lastActionResult[i] = "blocked"
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
    s.lastActionResult[i] = "no_target"
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
    s.lastActionResult[i] = "inventory_full"

proc unequipBodyToGround(s: var Sim, i: int) =
  ## Dropping/replacing a backpack sheds overflow slots 2..3 (DESIGN §3.1).
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
    s.lastActionResult[i] = "malformed"
    return
  if a.channeling.kind != chNone:
    s.lastActionResult[i] = "cooldown"   # re-issued use is NOT a restart
    return
  let slotItem = a.pack[invSlot].item
  if slotItem == iNone:
    s.lastActionResult[i] = "no_target"
    return
  let d = def(slotItem)
  case d.kind
  of ikMelee, ikRanged, ikThrown:
    # equip swap: hand <-> pack slot (DESIGN §3.1); brief attack lockout
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
  elif a.channeling.kind == chNone:
    s.lastActionResult[i] = "no_target"

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
        # INT double-yield: 5·INT in 100 (DESIGN §5.2), match PRNG
        var n = if s.rng.chance(5 * a.stats.intelligence): 2 else: 1
        discard tryPack(a[], iRations, n, 0)
        if n > 0:
          s.dropGround(a.pos, iRations, n)
    of chNone:
      discard
    a.channeling = Channeling()

# ---------------------------------------------------------------- combat

proc meleeMult(a: Agent): int = 5 + a.stats.strength   # x/10 (DESIGN §5.2)

proc applyDamage(s: var Sim, victim: int, centi: int, source: int,
                 label = "") =
  let v = addr s.agents[victim]
  if not v.alive or centi <= 0:
    return
  v.hpCenti -= centi
  v.damageTakenCenti += centi
  v.damageSources.add((
    (if label.len > 0: label
     elif source >= 0: "P" & $source
     else: "environment"), centi))
  if source >= 0:
    v.lastDamager = source
    s.agents[source].damageDealtCenti += centi
  # ANY damage cancels a first-aid channel (kit kept — DESIGN §3.2)
  if v.channeling.kind == chConsume and v.channeling.item == iFirstAid:
    v.channeling = Channeling()

proc bowDraw(a: Agent): int = 18 - a.stats.athleticism div 2

proc spawnProjectile(s: var Sim, shooter: int, dir: Dir8, kind: ItemId) =
  s.projectiles.add(Projectile(
    pos: s.agents[shooter].pos, dir: dir, kind: kind, shooter: shooter,
    remaining: (if kind == iArrows: def(iBow).rng
                elif kind == iDarts: def(iBlowgun).rng
                else: def(s.agents[shooter].hand).rng)))

proc takeAmmo(a: var Agent, ammo: ItemId): bool =
  for idx in 0 ..< a.packSlots:
    if a.pack[idx].item == ammo and a.pack[idx].n > 0:
      dec a.pack[idx].n
      if a.pack[idx].n == 0:
        a.pack[idx] = PackSlot()
      return true
  false

proc resolveMelee(s: var Sim) =
  if s.phase != phLive:
    return
  for i in 0 .. 15:
    if not s.pendingSet[i] or s.pendingActions[i].kind != akAttack:
      continue
    let a = addr s.agents[i]
    if not a.alive:
      continue
    if s.tick < a.attackReadyTick:
      s.lastActionResult[i] = "cooldown"
      continue
    let dir = s.pendingActions[i].dir
    let w = a.hand
    let d = def(w)
    case d.kind
    of ikMelee:
      var hit = -1
      var probe = a.pos
      for _ in 1 .. d.rng:
        probe = probe + dir
        if not inBounds(probe) or blocksSight(s.arena.tile(probe)):
          break
        let t = s.agentAt(probe)
        if t >= 0:
          hit = t
          break
      a.attackReadyTick = s.tick + d.cooldown
      a.camoRevealedUntil = s.tick + CamoRevealTicks
      # durability counts SWINGS, hit or miss (DESIGN §3.2 "40 swings")
      if w != iNone:
        dec a.handDur
      if hit >= 0:
        s.applyDamage(hit, d.damage * 100 * meleeMult(a[]) div 10, i)
      else:
        s.lastActionResult[i] = "no_target"
      if w != iNone and a.handDur <= 0:
        a.hand = iNone
        a.handN = 0
    of ikRanged:
      let ammo = ammoFor(w)
      if not takeAmmo(a[], ammo):
        s.lastActionResult[i] = "no_ammo"
        continue
      s.spawnProjectile(i, dir, ammo)
      a.attackReadyTick = s.tick + (if w == iBow: bowDraw(a[]) else: d.cooldown)
      a.camoRevealedUntil = s.tick + CamoRevealTicks
    of ikThrown:
      if a.handN <= 0:
        s.lastActionResult[i] = "no_ammo"
        continue
      dec a.handN
      s.spawnProjectile(i, dir, w)
      a.attackReadyTick = s.tick + d.cooldown
      a.camoRevealedUntil = s.tick + CamoRevealTicks
      if a.handN == 0:
        a.hand = iNone
    else:
      discard

proc projectileDamage(kind: ItemId): int =
  case kind
  of iArrows: def(iBow).damage
  of iDarts: def(iBlowgun).damage
  of iKnives: def(iKnives).damage
  else: 0

proc applyPoison(s: var Sim, victim, shooter: int) =
  let v = addr s.agents[victim]
  v.poisonUntil = s.tick + 12 * (20 - v.stats.intelligence)
  v.poisonAppliedTick = s.tick
  v.poisonFrom = shooter

proc advanceProjectiles(s: var Sim) =
  ## 2 tiles/tick, spawn order. Range-end -> recoverable ground item;
  ## wall/agent hit -> gone. Dodge (2·ATH in 100, match PRNG) passes through.
  var kept: seq[Projectile] = @[]
  for pIdx in 0 ..< s.projectiles.len:
    var p = s.projectiles[pIdx]
    var dead = false
    for _ in 0 ..< 2:
      if dead or p.remaining <= 0:
        break
      let next = p.pos + p.dir
      if not inBounds(next) or blocksSight(s.arena.tile(next)):
        dead = true
        break
      p.pos = next
      dec p.remaining
      let t = s.agentAt(next)
      if t >= 0 and t != p.shooter:
        if s.rng.rand(100) < 2 * s.agents[t].stats.athleticism:
          continue                       # dodged: passes through
        case p.kind
        of iNet:
          s.agents[t].nettedUntil = s.tick + NetTicks
        of iDarts:
          s.applyDamage(t, projectileDamage(p.kind) * 100, p.shooter)
          if s.agents[t].alive:
            s.applyPoison(t, p.shooter)
        else:
          s.applyDamage(t, projectileDamage(p.kind) * 100, p.shooter)
        dead = true
        break
    if not dead:
      if p.remaining <= 0:
        s.dropGround(p.pos, p.kind, 1)   # spent projectile is lootable
      else:
        kept.add(p)
  s.projectiles = kept

proc resolveHazards(s: var Sim) =
  ## Zone + scripted-event damage, once per 24 ticks, ATH-scaled, sourceless.
  if s.phase != phLive or s.tick mod 24 != 0:
    return
  let zoneDmg = s.zoneDamagePerS()
  for i in 0 .. 15:
    let a = addr s.agents[i]
    if not a.alive:
      continue
    if zoneDmg > 0 and not s.insideZone(a.pos):
      s.applyDamage(i, hazardScaled(a[], zoneDmg * 100), -1, "zone")
    if s.floodedAt(a.pos):
      s.applyDamage(i, hazardScaled(a[], 400), -1, "flood")
    if s.inFirestorm(a.pos):
      s.applyDamage(i, hazardScaled(a[], 600), -1, "firestorm")

proc emitHazardWarnings(s: var Sim) =
  for st in s.cfg.zone:
    if s.tick == st.warnT:
      s.emit(evZoneWarning, -1, Pos(x: ArenaSize div 2, y: ArenaSize div 2),
        """{"r_start":""" & $st.rStart & ""","r_end":""" & $st.rEnd &
        ""","shrink_tick":""" & $st.shrinkT & ""","done_tick":""" & $st.doneT &
        ""","damage_per_s":""" & $st.dmgPerS & "}")
  for ev in s.cfg.events:
    if s.tick == ev.fromTick - 120:
      s.emit(evEventWarning, -1, Pos(x: -1, y: -1), eventJson(ev))

proc resolvePoisonPulses(s: var Sim) =
  for i in 0 .. 15:
    let a = addr s.agents[i]
    if not a.alive or a.poisonUntil <= s.tick:
      continue
    let dt = s.tick - a.poisonAppliedTick
    if dt > 0 and dt mod PoisonPulsePeriod == 0:
      s.applyDamage(i, PoisonPulseCenti, a.poisonFrom, "poison")

# ---------------------------------------------------------------- sponsor

proc podReservedAt(s: Sim, p: Pos): bool =
  for pod in s.pods:
    if pod.landing == p:
      return true

proc landingFree(s: Sim, p: Pos): bool =
  inBounds(p) and not blocksMovement(s.arena.tile(p)) and
    s.agentAt(p) < 0 and not s.podReservedAt(p)

proc ringTiles(origin: Pos, r: int): seq[Pos] =
  ## Chebyshev ring walk: start (x, y-r), clockwise (DESIGN §9.3.3).
  var p = Pos(x: origin.x, y: origin.y - r)
  result.add(p)
  for (dx, dy, steps) in [(1, 0, r), (0, 1, 2 * r), (-1, 0, 2 * r),
                          (0, -1, 2 * r), (1, 0, r - 1)]:
    for _ in 0 ..< steps:
      p = Pos(x: p.x + dx, y: p.y + dy)
      result.add(p)

proc findLandingTile(s: Sim, origin: Pos): Pos =
  ## DESIGN §9.3.3 pinned spiral: rings r=0..3 first-free wins; fallback keeps
  ## the SAME ring enumeration outward (min d2, ties broken by ring order).
  if s.landingFree(origin):
    return origin
  for r in 1 .. 3:
    for q in ringTiles(origin, r):
      if s.landingFree(q):
        return q
  # global min d2 with ring-enumeration tiebreak (strict < keeps the earliest
  # tile in ring-outward walk order). A ring r's minimum possible d2 is r*r,
  # so stop once r*r exceeds the best found.
  var best = Pos(x: -1, y: -1)
  var bestD2 = int.high
  for r in 4 ..< ArenaSize:
    if best.x >= 0 and r * r > bestD2:
      break
    for q in ringTiles(origin, r):
      if s.landingFree(q):
        let dx = q.x - origin.x
        let dy = q.y - origin.y
        let d2 = dx * dx + dy * dy
        if d2 < bestD2:
          bestD2 = d2
          best = q
  best

proc requestGift*(s: var Sim, sponsor: string, teamIdx: int,
                  recipientSlot: int, itemId: string,
                  target: Pos = Pos(x: -1, y: -1)): GiftOutcome =
  ## Atomic (DESIGN §9.1): full-cost accept or zero-effect reject. Both logged.
  ## Two targeting modes:
  ##  - tile (v0.2, target.x >= 0): sponsor picks the landing tile; the pinned
  ##    spiral finds the nearest free tile. One purchase per team per
  ##    GiftLockoutTicks. recipientSlot is recorded as -1.
  ##  - recipient (v0.1 legacy, target.x < 0): pod lands near the recipient.
  ##    NO lockout — scripted recipient gifts keep their original semantics.
  let tileMode = target.x >= 0
  var rec = GiftRecord(tickRequested: s.tick, tickLanded: -1, sponsor: sponsor,
                       team: teamIdx,
                       recipientSlot: (if tileMode: -1 else: recipientSlot),
                       target: (if tileMode: target else: Pos(x: -1, y: -1)),
                       itemId: itemId, status: gsRejected)
  template reject(why: string): GiftOutcome =
    rec.reason = why
    rec.balanceAfter = (if teamIdx in 0 .. 7: s.teamBudget[teamIdx] else: 0)
    s.sponsorLog.add(rec)
    GiftOutcome(accepted: false, reason: why, balance: rec.balanceAfter)
  if s.phase == phEnded or teamIdx notin 0 .. 7:
    return reject("malformed")
  if tileMode:
    if not inBounds(target):
      return reject("malformed")
  elif recipientSlot notin 0 .. 15:
    return reject("malformed")
  let (known, gift) = giftLookup(itemId)
  if not known:
    return reject("unknown_item")
  if s.tick < s.cfg.sponsor.shopOpensTick:
    return reject("shop_locked")
  if tileMode and s.tick - s.lastGiftTick[teamIdx] < GiftLockoutTicks:
    return reject("lockout")
  if not tileMode:
    if not s.agents[recipientSlot].alive:
      return reject("recipient_dead")
    if team(AgentId(recipientSlot)) != teamIdx:
      return reject("not_own_team")
  if s.teamBudget[teamIdx] < gift.price:
    return reject("insufficient_funds")

  s.teamBudget[teamIdx] -= gift.price
  if tileMode:
    s.lastGiftTick[teamIdx] = s.tick
  let origin = (if tileMode: target else: s.agents[recipientSlot].pos)
  let landing = s.findLandingTile(origin)
  let landsTick = s.tick + 120
  s.pods.add(Pod(landing: landing, itemId: itemId,
                 recipientSlot: rec.recipientSlot, spawnTick: s.tick,
                 landsTick: landsTick))
  rec.status = gsAccepted
  rec.cost = gift.price
  rec.balanceAfter = s.teamBudget[teamIdx]
  s.sponsorLog.add(rec)
  s.emit(evGiftIncoming, rec.recipientSlot, landing,
    """{"item":"""" & itemId & """","lands_tick":""" & $landsTick &
    ""","recipient":""" & $rec.recipientSlot & "}")
  GiftOutcome(accepted: true, cost: gift.price, balance: s.teamBudget[teamIdx],
              landsTick: landsTick, landing: landing)

proc resolvePods(s: var Sim) =
  # landings
  for i in 0 ..< s.pods.len:
    if not s.pods[i].landed and s.tick >= s.pods[i].landsTick:
      s.pods[i].landed = true
      let (_, gift) = giftLookup(s.pods[i].itemId)
      for (item, n) in gift.contents:
        s.dropGround(s.pods[i].landing, item, n, def(item).durability)
      s.emit(evGiftLanded, s.pods[i].recipientSlot, s.pods[i].landing,
        """{"item":"""" & s.pods[i].itemId & """"}""")
      # record landing tick on the matching accepted gift
      for j in countdown(s.sponsorLog.len - 1, 0):
        if s.sponsorLog[j].status == gsAccepted and
           s.sponsorLog[j].tickLanded < 0 and
           s.sponsorLog[j].recipientSlot == s.pods[i].recipientSlot and
           s.sponsorLog[j].itemId == s.pods[i].itemId:
          s.sponsorLog[j].tickLanded = s.tick
          break
  # expire landed pods once their tile is looted clean
  var kept: seq[Pod] = @[]
  for pod in s.pods:
    if pod.landed and s.groundAt(pod.landing).len == 0:
      discard
    else:
      kept.add(pod)
  s.pods = kept

proc processScriptedGifts(s: var Sim) =
  ## Scripted gifts pass the IDENTICAL validation pipeline (DESIGN §9.3.1).
  for g in s.cfg.sponsor.scriptedGifts:
    if g.tick == s.tick:
      discard s.requestGift("script", g.team, g.recipientSlot, g.itemId,
                            g.target)

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
      # kill credit: last damager, mutual kills count for both (DESIGN §4)
      if a.lastDamager >= 0 and a.lastDamager != i:
        inc s.agents[a.lastDamager].kills
      s.dropAllInventory(i)
      s.emit(evDeathFireworks, i, a.pos)
      s.emit(evBoom, i, a.pos)

proc aliveCount*(s: Sim): int =
  for a in s.agents:
    if a.alive: inc result

proc aliveTeamCount*(s: Sim): int =
  var seen: array[8, bool]
  for a in s.agents:
    if a.alive:
      seen[team(a.slot)] = true
  for t in seen:
    if t: inc result

# ---------------------------------------------------------------- scoring

# DESIGN §12.1 (DECIDED: standard table, +1/kill).
const PlacementPoints*: array[16, int] =
  [15, 12, 10, 8, 7, 6, 5, 4, 3, 3, 2, 2, 1, 1, 0, 0]

proc computePlacements*(s: Sim): array[16, int] =
  ## Placement 1..16: reverse death order; same-tick ties broken by higher
  ## damage dealt, then lower slot (DESIGN §12.1). Winner (alive) is place 1.
  var order: seq[int] = @[]
  for i in 0 .. 15:
    order.add(i)
  # sort: alive first, then deathTick desc, damage desc, slot asc
  proc better(a, b: int): bool =
    let x = s.agents[a]
    let y = s.agents[b]
    if x.alive != y.alive: return x.alive
    if x.deathTick != y.deathTick: return x.deathTick > y.deathTick
    if x.damageDealtCenti != y.damageDealtCenti:
      return x.damageDealtCenti > y.damageDealtCenti
    a < b
  for i in 1 ..< order.len:                # insertion sort: stable, tiny n
    var j = i
    while j > 0 and better(order[j], order[j - 1]):
      let t = order[j]; order[j] = order[j - 1]; order[j - 1] = t
      dec j
  for place, slot in order:
    result[slot] = place + 1

proc scoreFor*(placement, kills: int): int =
  PlacementPoints[placement - 1] + kills

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
  for a in s.agents:
    fnv1a(h, uint64(cast[uint32](int32(a.poisonUntil))))
    fnv1a(h, uint64(cast[uint32](int32(a.nettedUntil))))
    fnv1a(h, uint64(cast[uint32](int32(a.kills))))
    fnv1a(h, uint64(cast[uint32](int32(a.damageDealtCenti))))
  for p in s.projectiles:
    fnv1a(h, uint64(p.pos.x))
    fnv1a(h, uint64(p.pos.y))
    fnv1a(h, uint64(ord(p.kind)))
    fnv1a(h, uint64(cast[uint32](int32(p.remaining))))
  for g in s.ground:
    fnv1a(h, uint64(g.pos.x))
    fnv1a(h, uint64(g.pos.y))
    fnv1a(h, uint64(ord(g.item)))
    fnv1a(h, uint64(cast[uint32](int32(g.n))))
  for b in s.bushes:
    fnv1a(h, uint64(cast[uint32](int32(b.charges))))
  for i in 0 .. 15:
    fnv1a(h, uint64(cast[uint32](int32(s.lastTalkTick[i]))))
  fnv1a(h, uint64(s.talkLog.len))
  for t in 0 .. 7:
    fnv1a(h, uint64(cast[uint32](int32(s.teamBudget[t]))))
  for pod in s.pods:
    fnv1a(h, uint64(pod.landing.x))
    fnv1a(h, uint64(pod.landing.y))
    fnv1a(h, uint64(cast[uint32](int32(pod.landsTick))))
    fnv1a(h, uint64(ord(pod.landed)))
  # NOTE: sponsorLog deliberately NOT hashed — rejected requests are audit
  # records, not sim state, and rejects are not input-logged; hashing them
  # would make live-vs-replay hashes diverge on any rejected live request.
  # Accepted-gift effects are fully covered by teamBudget + pods + ground.
  for w in s.rng.state():
    fnv1a(h, w)
  h

# ---------------------------------------------------------------- tick

proc step*(s: var Sim) =
  if s.phase == phEnded:
    return
  s.events.setLen(0)
  s.inStep = true
  # splice events emitted between ticks (gift intake) into THIS tick
  for e in s.pendingEvents:
    var ev = e
    ev.tick = s.tick
    s.events.add(ev)
    s.eventHistory.add(ev)
  s.pendingEvents.setLen(0)
  for i in 0 .. 15:
    s.agents[i].damageTakenCenti = 0
    s.agents[i].damageSources.setLen(0)
    if s.pendingSet[i]:
      s.lastActionResult[i] = "ok"   # provisional; resolvers downgrade it
    s.inbox[i].setLen(0)

  # deliver last tick's talk (DESIGN §10.4: next-tick delivery, sender echoed)
  var undelivered: seq[TalkMsg] = @[]
  for msg in s.talkQueue:
    if msg.tick == s.tick - 1:
      case msg.channel
      of tcBroadcast:
        for i in 0 .. 15:
          if s.agents[i].alive:
            s.inbox[i].add(msg)
      of tcTeam:
        for i in 0 .. 15:
          if s.agents[i].alive and team(AgentId(i)) == team(AgentId(msg.slot)):
            s.inbox[i].add(msg)
      of tcDm:
        if s.agents[msg.to].alive:
          s.inbox[msg.to].add(msg)
        if s.agents[msg.slot].alive:
          s.inbox[msg.slot].add(msg)
    elif msg.tick >= s.tick:
      undelivered.add(msg)
  s.talkQueue = undelivered

  # 1. log applied inputs
  for i in 0 .. 15:
    if s.pendingSet[i] and s.agents[i].alive:
      s.inputLog.add(AppliedInput(tick: s.tick, slot: i,
        payload: actionJson(s.pendingActions[i])))

  # 2. phase transitions
  if s.phase == phCountdown and s.tick == s.allocDeadlineTick() + 1:
    # missing/invalid by deadline -> default build stays (5/5/5/5), logged
    for i in 0 .. 15:
      if not s.agents[i].statsLocked:
        s.inputLog.add(AppliedInput(tick: s.tick, slot: i,
          payload: """{"allocate_stats":"defaulted"}"""))
  if s.phase == phCountdown and s.tick == s.ignitionTick:
    s.phase = phLive
    s.emit(evIgnition, -1, Pos(x: ArenaSize div 2, y: ArenaSize div 2))
  s.emitHazardWarnings()
  s.processScriptedGifts()

  # 3. movement
  s.resolveMovement()

  # 4. melee attacks (positions post-move; mutual hits both land)
  s.resolveMelee()

  # 5. projectiles
  s.advanceProjectiles()

  # 6. DoT effects (net expiry is passive via nettedUntil) + hazards
  s.resolvePoisonPulses()
  s.resolveHazards()

  # 7. item verbs: pod landings first (same-tick lootable), then completions,
  # pickups, drops/use/interact
  s.resolvePods()
  s.resolveChannels()
  for i in 0 .. 15:
    if not s.pendingSet[i] or not s.agents[i].alive:
      continue
    let kind = s.pendingActions[i].kind
    if s.phase != phLive:
      if kind in {akAttack, akPickup, akDrop, akUse, akInteract}:
        s.lastActionResult[i] = "frozen"   # §1.1: ignored during countdown
      continue
    case kind
    of akPickup: s.resolvePickup(i)
    of akDrop: s.resolveDrop(i, s.pendingActions[i].invSlot)
    of akUse: s.resolveUse(i, s.pendingActions[i].invSlot)
    of akInteract: s.resolveInteract(i)
    else: discard

  # 8. deaths
  s.resolveDeaths()

  # 9. win check + bookkeeping (FFA finale: one team left, >=2 alive)
  if s.phase == phLive and not s.finaleEmitted and
     s.aliveTeamCount() == 1 and s.aliveCount() >= 2:
    s.finaleEmitted = true
    s.emit(evFinale, -1, Pos(x: ArenaSize div 2, y: ArenaSize div 2))
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
  s.inStep = false
  inc s.tick

# ---------------------------------------------------------------- input JSON

proc parseDir(v: string): (bool, Dir8) =
  for d in Dir8:
    if $d == v:
      return (true, d)
  (false, dN)

proc applyInputJson*(s: var Sim, slot: AgentId, j: JsonNode) =
  ## Canonical application of one zero_sum.player.v1 wire payload.
  if j == nil or j.kind != JObject:
    return
  let wireType = j{"type"}.getStr("")
  if wireType == "talk" and j.hasKey("channel"):
    let chStr = j{"channel"}.getStr("")
    var ch = tcBroadcast
    if chStr == $tcTeam: ch = tcTeam
    elif chStr == $tcDm: ch = tcDm
    elif chStr != $tcBroadcast: return
    discard s.submitTalk(slot, ch, j{"to"}.getInt(-1), j{"text"}.getStr(""))
    return
  if wireType == "allocate_stats" and j.hasKey("speed"):
    discard s.submitAllocation(slot, Stats(
      speed: j{"speed"}.getInt(), strength: j{"strength"}.getInt(),
      intelligence: j{"intelligence"}.getInt(),
      athleticism: j{"athleticism"}.getInt()))
    return
  if wireType == "action" and j.hasKey("do"):
    let verb = j["do"].getStr("")
    case verb
    of "move", "attack":
      let (ok, d) = parseDir(j{"dir"}.getStr(""))
      if ok:
        s.submitAction(slot, Action(
          kind: (if verb == "move": akMove else: akAttack), dir: d))
    of "pickup": s.submitAction(slot, Action(kind: akPickup))
    of "interact": s.submitAction(slot, Action(kind: akInteract))
    of "drop": s.submitAction(slot, Action(kind: akDrop, invSlot: j{"slot"}.getInt(-99)))
    of "use": s.submitAction(slot, Action(kind: akUse, invSlot: j{"slot"}.getInt(-99)))
    of "none": s.submitAction(slot, Action(kind: akNone))
    else: s.lastActionResult[slot] = "malformed"
  else:
    s.lastActionResult[slot] = "malformed"

proc noteMalformedInput*(s: var Sim, slot: AgentId) =
  ## Server-side hook for unparseable payloads (never a disconnect, §10).
  s.lastActionResult[slot] = "malformed"
