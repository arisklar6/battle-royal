## Analyst telemetry feed (DESIGN §21.3 Task 3): structured JSON for the
## esports dashboard at /client/analyst. Read-only over the Sim — never
## touches state inside the determinism boundary. The interception tracker
## watches the pod pool from the server loop: a landed pod expires the tick
## its tile is looted clean (sim resolvePods), and pickup is same-tile only
## (sim resolvePickup), so the agent standing on the landing tile that tick
## is the looter.

import std/[algorithm, json]
import battle_royal/[types, arena, sim]

type
  Interception* = object
    tick*: int
    itemId*: string
    recipientSlot*: int
    looterSlot*: int           # -1 if indeterminate
    stolen*: bool              # looter exists and is not on recipient's team

  AnalystTracker* = object
    prevPods: seq[Pod]
    interceptions*: seq[Interception]

proc track*(t: var AnalystTracker, s: Sim) =
  ## Call once per tick, after s.step().
  for old in t.prevPods:
    if not old.landed:
      continue
    var stillThere = false
    for p in s.pods:
      if p.landing == old.landing and p.itemId == old.itemId and
         p.recipientSlot == old.recipientSlot:
        stillThere = true
        break
    if stillThere:
      continue
    var looter = -1
    for i in 0 .. 15:
      if s.agents[i].alive and s.agents[i].pos == old.landing:
        looter = i
        break
    t.interceptions.add(Interception(
      tick: s.tick, itemId: old.itemId, recipientSlot: old.recipientSlot,
      looterSlot: looter,
      stolen: looter >= 0 and old.recipientSlot >= 0 and
              looter != old.recipientSlot))
  t.prevPods = s.pods

proc reset*(t: var AnalystTracker) =
  t.prevPods = @[]
  t.interceptions = @[]

proc analystJson*(s: Sim, t: AnalystTracker): string =
  let places = s.computePlacements()
  let statsLocked = s.tick >= s.allocDeadlineTick()
  var agents = newJArray()
  var alive = 0
  for i in 0 ..< s.cfg.numPlayers:
    let a = s.agents[i]
    if a.alive:
      inc alive
    var e = %*{
      "slot": i,
      "name": s.cfg.playerNames[i],
      "pos": [a.pos.x, a.pos.y],
      "alive": a.alive, "hp": (if a.alive: a.hpCenti div 100 else: 0),
      "kills": a.kills, "damage_dealt": a.damageDealtCenti div 100,
      "placement": places[i],
      "projected_score": s.scoreFor(places[i]),
      "hand": $a.hand}
    if not a.alive:
      e["death_tick"] = %a.deathTick
    if statsLocked:
      e["stats"] = %*{"speed": a.stats.speed, "strength": a.stats.strength,
                       "intelligence": a.stats.intelligence,
                       "athleticism": a.stats.athleticism}
    agents.add(e)
  var purses = newJArray()
  for ti in 0 ..< s.cfg.numPlayers:
    purses.add(%*{"player": ti, "budget": s.playerBudget[ti]})
  var ticker = newJArray()
  let lo = max(0, s.sponsorLog.len - 16)
  for j in lo ..< s.sponsorLog.len:
    let g = s.sponsorLog[j]
    ticker.add(%*{"tick": g.tickRequested, "sponsor": g.sponsor,
                   "player": g.player,
                   "recipient_slot": g.recipientSlot, "item": g.itemId,
                   "target": (if g.target.x >= 0: %[g.target.x, g.target.y]
                              else: newJNull()),
                   "cost": g.cost, "status": $g.status, "reason": g.reason,
                   "balance": g.balanceAfter, "landed_tick": g.tickLanded})
  var steals = newJArray()
  let ilo = max(0, t.interceptions.len - 12)
  for j in ilo ..< t.interceptions.len:
    let ic = t.interceptions[j]
    steals.add(%*{"tick": ic.tick, "item": ic.itemId,
                   "recipient_slot": ic.recipientSlot,
                   "looter_slot": ic.looterSlot, "stolen": ic.stolen})
  # settlements: the match's death ledger, oldest first. Killer = last
  # damager (same credit rule as scoring); -1 = arena (zone/hazard/mine).
  var dead: seq[int] = @[]
  for i in 0 ..< s.cfg.numPlayers:
    if not s.agents[i].alive:
      dead.add(i)
  dead.sort(proc (x, y: int): int = s.agents[x].deathTick - s.agents[y].deathTick)
  var settlements = newJArray()
  for i in dead:
    let a = s.agents[i]
    settlements.add(%*{"tick": a.deathTick, "victim": i,
                        "killer": (if a.lastDamager != i: a.lastDamager else: -1),
                        "placement": places[i]})
  # live chat: the diplomacy layer is public by design (spec: permanently
  # public transcript) — surface the last 30 lines to the desk
  var chatArr = newJArray()
  let clo = max(0, s.talkLog.len - 30)
  for j in clo ..< s.talkLog.len:
    let t = s.talkLog[j]
    chatArr.add(%*{"tick": t.tick, "from": t.slot, "channel": $t.channel,
                    "to": t.to, "text": t.text})
  # arena static map: same tile legend as obs.nim player_config static_map
  # (. ground, # wall, R rock, F fortress_wall, P pedestal, B berry_bush)
  var arenaRows = newJArray()
  for row in staticMapRows(s.arena):
    arenaRows.add(%row)
  # next-shrink context so the desk can show the ring clock
  var nextR = s.zoneRadius()
  var shrinkT = 0
  for st in s.cfg.zone:
    if s.tick < st.doneT:
      nextR = st.rEnd
      shrinkT = st.shrinkT
      break
  $(%*{
    "type": "analyst", "tick": s.tick, "phase": $s.phase,
    "max_ticks": s.cfg.maxTicks,
    "alive": alive,
    "stats_locked": statsLocked,
    "alloc_deadline_tick": s.allocDeadlineTick(),
    "finale": s.finaleEmitted,
    "winner_slot": s.winnerSlot,
    "zone": {"radius": s.zoneRadius(), "next_radius": nextR,
             "shrink_tick": shrinkT, "damage_per_s": s.zoneDamagePerS()},
    "arena": arenaRows,
    "agents": agents, "purses": purses,
    "ticker": ticker, "interceptions": steals, "settlements": settlements,
    "chat": chatArr})
