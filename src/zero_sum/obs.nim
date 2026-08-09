## Observation builder — zero_sum.player.v1 (DESIGN §10). Pure function of
## sim state; the server serializes whatever this returns.

import std/json
import types, arena, sim

proc losClear(s: Sim, a, b: Pos): bool =
  ## Bresenham between tile centers; blocked by walls/rocks/fortress.
  var x0 = a.x
  var y0 = a.y
  let dx = abs(b.x - x0)
  let dy = -abs(b.y - y0)
  let sx = (if x0 < b.x: 1 else: -1)
  let sy = (if y0 < b.y: 1 else: -1)
  var err = dx + dy
  while true:
    if not (x0 == a.x and y0 == a.y) and not (x0 == b.x and y0 == b.y):
      if blocksSight(s.arena.tile(Pos(x: x0, y: y0))):
        return false
    if x0 == b.x and y0 == b.y:
      break
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x0 += sx
    if e2 <= dx:
      err += dx
      y0 += sy
  true

proc canSee*(s: Sim, viewer: int, target: int): bool =
  ## Vision + camo (DESIGN §3.2/§6): camo caps detection at 4 (still) / 7
  ## (moved in last 24t) unless revealed by attacking.
  let v = s.agents[viewer]
  let t = s.agents[target]
  let dx = v.pos.x - t.pos.x
  let dy = v.pos.y - t.pos.y
  let d2 = dx * dx + dy * dy
  var radius = visionRadius(v)
  if t.body == iCamo and s.tick >= t.camoRevealedUntil:
    let moved = t.moveReadyTick > s.tick - 24 + moveCooldown(t)
    let cap = (if moved: 7 else: 4)
    if cap < radius:
      radius = cap
  if d2 > radius * radius:
    return false
  s.losClear(v.pos, t.pos)

proc tileVisible(s: Sim, viewer: int, p: Pos): bool =
  let v = s.agents[viewer]
  let dx = v.pos.x - p.x
  let dy = v.pos.y - p.y
  let r = visionRadius(v)
  if dx * dx + dy * dy > r * r:
    return false
  s.losClear(v.pos, p)

proc hpBand(hpCenti: int): string =
  if hpCenti > 6600: "healthy"
  elif hpCenti >= 3300: "hurt"
  else: "critical"

proc handJson(a: Agent): JsonNode =
  if a.hand == iNone:
    %*{"id": "none"}
  else:
    var h = %*{"id": $a.hand}
    if def(a.hand).durability > 0:
      h["durability"] = %a.handDur
    if def(a.hand).kind == ikThrown:
      h["n"] = %a.handN
    h

proc effectsJson(s: Sim, a: Agent): JsonNode =
  result = newJArray()
  if a.poisonUntil > s.tick:
    result.add(%*{"id": "poison", "ticks_left": a.poisonUntil - s.tick})
  if a.nettedUntil > s.tick:
    result.add(%*{"id": "netted", "ticks_left": a.nettedUntil - s.tick})
  if a.channeling.kind != chNone:
    result.add(%*{"id": "channeling", "item": $a.channeling.item,
                  "done_tick": a.channeling.doneTick})
  if a.body == iCamo and s.tick < a.camoRevealedUntil:
    result.add(%*{"id": "camo_revealed",
                  "ticks_left": a.camoRevealedUntil - s.tick})

proc roughDirection(fromP, toP: Pos): string =
  ## 8-way compass from observer to source (boom cue, DESIGN §10.3).
  let dx = toP.x - fromP.x
  let dy = toP.y - fromP.y
  if dx == 0 and dy == 0:
    return "here"
  let ns = (if dy < -abs(dx) div 2: "N" elif dy > abs(dx) div 2: "S" else: "")
  let ew = (if dx > abs(dy) div 2: "E" elif dx < -abs(dy) div 2: "W" else: "")
  result = ns & ew
  if result.len == 0:
    result = (if dx > 0: "E" else: "W")

proc eventJsonNode(s: Sim, viewer: int, e: Event): JsonNode =
  ## Wire event: snake_case type token, kind-specific fields at TOP level
  ## (DESIGN §10.3). Boom carries only a rough observer-relative direction.
  result = %*{"type": $e.kind}
  if e.kind == evBoom:
    result["direction"] = %roughDirection(s.agents[viewer].pos, e.pos)
    return
  if e.slot >= 0:
    result["slot"] = %e.slot
  if e.pos.x >= 0:
    result["pos"] = %[e.pos.x, e.pos.y]
  if e.data.len > 0:
    try:
      let d = parseJson(e.data)
      if d.kind == JObject:
        for k, v in d.pairs:
          result[k] = v
      else:
        result["data"] = d
    except CatchableError:
      result["data"] = %e.data

proc zoneJson(s: Sim): JsonNode =
  var warnT = 0
  var shrinkT = 0
  var nextR = s.zoneRadius()
  for st in s.cfg.zone:
    if s.tick < st.doneT:
      warnT = st.warnT
      shrinkT = st.shrinkT
      nextR = st.rEnd
      break
  %*{"center": [ArenaSize div 2, ArenaSize div 2], "radius": s.zoneRadius(),
     "next_radius": nextR, "warn_tick": warnT, "shrink_tick": shrinkT,
     "damage_per_s": s.zoneDamagePerS()}

proc playerConfigJson*(s: Sim, slot: int): string =
  var pedArr = newJArray()
  for p in Pedestals:
    pedArr.add(%[p.x, p.y])
  var rows = newJArray()
  for row in staticMapRows(s.arena):
    rows.add(%row)
  var catalog = newJObject()
  for (key, g) in GiftCatalog:
    catalog[key] = %g.price
  var items = newJArray()
  for id in ItemId:
    if id == iNone: continue
    let d = def(id)
    items.add(%*{"id": $id, "kind": $d.kind, "damage": d.damage,
                 "range": d.rng, "cooldown": d.cooldown,
                 "durability": d.durability, "stack_max": d.stackMax,
                 "use_ticks": d.useTicks, "heal": d.heal})
  var zoneArr = newJArray()
  for st in s.cfg.zone:
    zoneArr.add(%[st.warnT, st.shrinkT, st.doneT, st.rStart, st.rEnd, st.dmgPerS])
  $(%*{
    "type": "player_config", "protocol": "zero_sum.player.v1",
    "slot": slot, "team": teamName(AgentId(slot)),
    "teammate_slot": int(teammate(AgentId(slot))),
    "name": s.cfg.playerNames[slot],
    "arena": {"size": ArenaSize, "static_map": rows,
              "legend": {".": "ground", "#": "wall", "R": "rock",
                          "F": "fortress_wall", "P": "pedestal", "B": "berry_bush"},
              "pedestals": pedArr},
    "freeze": {"ends_tick": s.ignitionTick,
               "alloc_deadline_tick": s.allocDeadlineTick(),
               "pedestal_mine_rule":
                 "leaving your pedestal tile before ignition is instant death"},
    "stats": {"budget": 20, "min": 1, "max": 10, "default": [5, 5, 5, 5]},
    "items": items,
    "zone_schedule": zoneArr,
    "tick_rate": 24, "max_ticks": s.cfg.maxTicks,
    "ignition_tick": s.ignitionTick,
    "sponsor": {"enabled": true,
                 "budget_per_team": s.cfg.sponsor.budgetPerTeam,
                 "shop_opens_tick": s.cfg.sponsor.shopOpensTick,
                 "catalog": catalog}})

proc observationJson*(s: Sim, slot: int): string =
  let me = s.agents[slot]
  var pack = newJArray()
  for idx in 0 ..< 4:
    if idx >= me.packSlots:
      break
    let ps = me.pack[idx]
    if ps.item == iNone:
      pack.add(newJNull())
    else:
      var e = %*{"id": $ps.item, "n": ps.n}
      if def(ps.item).durability > 0:
        e["durability"] = %ps.durability
      pack.add(e)
  var agentsArr = newJArray()
  for i in 0 .. 15:
    if i == slot or not s.agents[i].alive:
      continue
    if s.canSee(slot, i):
      let o = s.agents[i]
      agentsArr.add(%*{"slot": i, "team": teamName(AgentId(i)),
        "pos": [o.pos.x, o.pos.y], "hp_band": hpBand(o.hpCenti),
        "hand": $o.hand,
        "body": (if o.body == iNone: newJNull() else: %($o.body)),
        "netted": o.nettedUntil > s.tick,
        "poisoned": o.poisonUntil > s.tick,
        "channeling": o.channeling.kind != chNone})
  var itemsArr = newJArray()
  for g in s.ground:
    if s.tileVisible(slot, g.pos):
      var e = %*{"id": $g.item, "n": g.n, "pos": [g.pos.x, g.pos.y]}
      if def(g.item).durability > 0:
        e["durability"] = %g.durability
      itemsArr.add(e)
  var podsArr = newJArray()
  for pod in s.pods:
    podsArr.add(%*{"pos": [pod.landing.x, pod.landing.y],
                   "item": pod.itemId, "landed": pod.landed,
                   "lands_tick": pod.landsTick,
                   "recipient_slot": pod.recipientSlot})
  var bushArr = newJArray()
  for b in s.bushes:
    if s.tileVisible(slot, b.pos):
      bushArr.add(%*{"pos": [b.pos.x, b.pos.y], "charges": b.charges})
  var projArr = newJArray()
  for p in s.projectiles:
    if s.tileVisible(slot, p.pos):
      let kindTok =
        case p.kind
        of iArrows: "arrow"
        of iDarts: "dart"
        of iKnives: "knife"
        of iNet: "net"
        else: $p.kind
      projArr.add(%*{"pos": [p.pos.x, p.pos.y], "dir": $p.dir,
                     "kind": kindTok, "shooter": p.shooter})
  var eventsArr = newJArray()
  for e in s.events:
    eventsArr.add(eventJsonNode(s, slot, e))
  var dmgTaken = newJArray()
  for (src, centi) in me.damageSources:
    dmgTaken.add(%*{"source": src, "amount": centi.float / 100.0})
  var chatArr = newJArray()
  for m in s.inbox[slot]:
    chatArr.add(%*{"tick": m.tick, "from": m.slot, "channel": $m.channel,
                   "to": (if m.channel == tcDm: %m.to else: newJNull()),
                   "text": m.text})
  $(%*{
    "type": "observation", "tick": s.tick,
    "phase": $s.phase,
    "you": {"pos": [me.pos.x, me.pos.y],
            "hp": me.hpCenti div 100,
            "stats": {"speed": me.stats.speed, "strength": me.stats.strength,
                       "intelligence": me.stats.intelligence,
                       "athleticism": me.stats.athleticism},
            "hand": handJson(me),
            "body": (if me.body == iNone: newJNull() else: %($me.body)),
            "pack": pack,
            "effects": effectsJson(s, me),
            "damage_taken": dmgTaken,
            "kills": me.kills,
            "damage_dealt": me.damageDealtCenti div 100,
            "move_ready_in": max(0, me.moveReadyTick - s.tick),
            "attack_ready_in": max(0, me.attackReadyTick - s.tick),
            "action_result": s.lastActionResult[slot]},
    "visible": {"agents": agentsArr, "items": itemsArr, "pods": podsArr,
                 "bushes": bushArr, "projectiles": projArr},
    "zone": zoneJson(s),
    "events": eventsArr,
    "chat": chatArr})

proc finalJson*(s: Sim, slot: int): string =
  let places = s.computePlacements()
  let me = s.agents[slot]
  $(%*{"type": "final", "placement": places[slot], "kills": me.kills,
       "score": s.episodeScore(places, AgentId(slot)),
       "score_final": s.phase == phEnded,
       "winner_slot": s.winnerSlot, "match_ticks": s.tick,
       "reason": (if me.alive and s.winnerSlot == slot: "winner"
                  elif s.phase == phEnded: "match_over"
                  else: "eliminated")})
