## Deterministic sim core — step 1 scope: freeze, mines, ignition, movement,
## deaths, events, tick hash. Resolution order per DESIGN §1.2 (part of spec).

import std/[json, tables]
import prng, types, arena

type
  ActionKind* = enum
    akNone, akMove

  Action* = object
    kind*: ActionKind
    dir*: Dir8

  AppliedInput* = object
    tick*: int
    slot*: int
    payload*: string           # canonical JSON of the applied action

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
    tick*: int
    phase*: Phase
    ignitionTick*: int
    events*: seq[Event]        # events emitted THIS tick (cleared each tick)
    inputLog*: seq[AppliedInput]
    hashes*: seq[(int, uint64)]
    winnerSlot*: int           # -1 until decided
    pendingActions: array[16, Action]
    pendingSet: array[16, bool]

proc allocDeadlineTick*(s: Sim): int = s.cfg.freezeTicks - 24

proc moveCooldown*(a: Agent): int = 16 - a.stats.speed

proc parseSimConfig*(node: JsonNode, mintSeed: proc(): uint64): SimConfig =
  ## seed OPTIONAL (DESIGN §17.1): absent -> minted via callback (OS entropy at
  ## the boundary, never inside the sim).
  result.maxTicks = node{"max_ticks"}.getInt(9120)
  result.freezeTicks = node{"freeze_ticks"}.getInt(240)
  if node.hasKey("seed"):
    result.seed = uint64(node["seed"].getBiggestInt())
    result.seedWasMinted = false
  else:
    result.seed = mintSeed()
    result.seedWasMinted = true

proc effectiveConfigJson*(cfg: SimConfig, original: JsonNode): string =
  ## Complete effective config for the replay header (owner directive):
  ## minted seed written in, runner tokens stripped.
  var eff = copy(original)
  eff["seed"] = %int64(cfg.seed)
  if eff.hasKey("tokens"):
    eff.delete("tokens")
  $eff

proc initSim*(cfg: SimConfig): Sim =
  result.cfg = cfg
  result.rng = initPrng(cfg.seed)
  result.arena = buildArena(result.rng)   # PRNG order: rocks first (§15.1)
  result.tick = 0
  result.phase = phCountdown
  result.ignitionTick = cfg.freezeTicks
  result.winnerSlot = -1
  for i in 0 .. 15:
    result.agents[i] = Agent(
      slot: AgentId(i), alive: true, pos: Pedestals[i],
      hpCenti: MaxHpCenti, stats: Stats(speed: 5, strength: 5, intelligence: 5, athleticism: 5),
      moveReadyTick: 0, attackReadyTick: 0, deathTick: -1)

proc submitAction*(s: var Sim, slot: AgentId, act: Action) =
  ## First action per slot per tick wins (DESIGN §1.2.1); later ones dropped.
  if not s.pendingSet[slot]:
    s.pendingActions[slot] = act
    s.pendingSet[slot] = true

proc actionJson(act: Action): string =
  case act.kind
  of akNone: """{"do":"none"}"""
  of akMove: """{"do":"move","dir":"""" & $act.dir & """"}"""

proc emit(s: var Sim, kind: EventKind, slot = -1, pos = Pos(x: -1, y: -1), data = "") =
  s.events.add(Event(tick: s.tick, kind: kind, slot: slot, pos: pos, data: data))

proc agentAt(s: Sim, p: Pos): int =
  for i in 0 .. 15:
    if s.agents[i].alive and s.agents[i].pos == p:
      return i
  -1

proc resolveMovement(s: var Sim) =
  ## DESIGN §1.2 step 3: swaps forbidden; contested tiles row-major, PRNG winner;
  ## blocked propagation to fixpoint; pure rotations move.
  var intent: array[16, PendingMove]
  for i in 0 .. 15:
    let a = s.agents[i]
    if not a.alive or not s.pendingSet[i] or s.pendingActions[i].kind != akMove:
      continue
    if s.tick < a.moveReadyTick:
      continue
    let target = a.pos + s.pendingActions[i].dir
    if not inBounds(target) or blocksMovement(s.arena.tile(target)):
      continue
    intent[i] = PendingMove(slot: AgentId(i), target: target, active: true)

  # (b) swaps: both stay
  for i in 0 .. 15:
    if not intent[i].active: continue
    for j in i + 1 .. 15:
      if not intent[j].active: continue
      if intent[i].target == s.agents[j].pos and intent[j].target == s.agents[i].pos:
        intent[i].active = false
        intent[j].active = false

  # (c) contested target tiles, row-major, PRNG winner
  var contenders = initTable[int, seq[int]]()   # key = y*ArenaSize+x
  for i in 0 .. 15:
    if intent[i].active:
      let key = intent[i].target.y * ArenaSize + intent[i].target.x
      contenders.mgetOrPut(key, @[]).add(i)
  var keys: seq[int] = @[]
  for k in contenders.keys: keys.add(k)
  # deterministic row-major order
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

  # (d) blocked propagation to fixpoint; rotations survive
  var changed = true
  while changed:
    changed = false
    for i in 0 .. 15:
      if not intent[i].active: continue
      let occ = s.agentAt(intent[i].target)
      if occ >= 0 and occ != i:
        # occupied by a non-mover or a stayer -> blocked; movers pending are fine
        if not intent[occ].active:
          intent[i].active = false
          changed = true

  # execute all surviving moves simultaneously
  var newPos: array[16, Pos]
  for i in 0 .. 15:
    newPos[i] = s.agents[i].pos
  for i in 0 .. 15:
    if intent[i].active:
      newPos[i] = intent[i].target
  for i in 0 .. 15:
    if intent[i].active:
      let a = addr s.agents[i]
      let wasOnPedestal = s.arena.tile(a.pos) == tkPedestal
      a.pos = newPos[i]
      a.moveReadyTick = s.tick + moveCooldown(a[])
      # §1.1: leaving your pedestal during countdown = mine
      if s.phase == phCountdown and wasOnPedestal:
        a.hpCenti = 0
        s.emit(evMineExplosion, i, a.pos)

proc resolveDeaths(s: var Sim) =
  for i in 0 .. 15:
    let a = addr s.agents[i]
    if a.alive and a.hpCenti <= 0:
      a.alive = false
      a.deathTick = s.tick
      s.emit(evDeathFireworks, i, a.pos)
      s.emit(evBoom, i, a.pos)

proc aliveCount*(s: Sim): int =
  for a in s.agents:
    if a.alive: inc result

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
  for w in s.rng.state():
    fnv1a(h, w)
  h

proc step*(s: var Sim) =
  ## One tick, DESIGN §1.2 order. Caller submits actions before step().
  if s.phase == phEnded:
    return
  s.events.setLen(0)

  # 1. log applied inputs (exactly one entry per slot that submitted)
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

  # 4-7. combat/projectiles/effects/items — later steps.

  # 8. deaths
  s.resolveDeaths()

  # 9. win check + bookkeeping (<=1 handles mutual-kill-to-zero: winner -1,
  # placement decided by the §12.1 tiebreak in the scoring step)
  if s.aliveCount() <= 1 and s.phase == phLive:
    for i in 0 .. 15:
      if s.agents[i].alive:
        s.winnerSlot = i
    s.phase = phEnded
    s.emit(evMatchEnd, s.winnerSlot)
  elif s.tick + 1 >= s.cfg.maxTicks:
    # cap: everyone alive dies at the cap tick (ranking in step 8 of Phase C)
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
