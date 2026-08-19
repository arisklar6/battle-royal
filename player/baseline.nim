## Battle Royal baseline player (DESIGN §18), FFA survival meta: kills
## score nothing — placement and the podium are the only pay. So the bot's
## whole doctrine is outliving: obey the ring, keep distance, heal early,
## fight only when cornered or to finish an adjacent critical threat, and
## use the arena-wide chat to talk its way out of fights it can only lose
## points by taking. Certify/demo quality, not competitive strength.
##
## COACH MODE (local play): when COACH_POLICY_FILE + COACH_SLOT are set, the
## bot reads the human coach's pre-match plan — stat allocation and strategy
## knobs — and executes it. The human never drives the seat mid-match; the
## coached bot is still a policy program (v0.2 AI-only invariant holds).

import std/[json, os]
import whisky

type
  Coach = object
    active: bool
    stats: array[4, int]        # speed/strength/intelligence/athleticism
    opening: string             # center | fortress | outer | forage
    aggression: int             # 0..10
    healAt: int                 # heal when hp below this (and safe)
    fleeAt: int                 # flee visible enemies below this hp
    ringMargin: int             # stay this far inside the next radius
    lootPriority: seq[string]
    finaleMode: string          # fight | evade

  Ctx = object
    slot: int
    numPlayers: int
    aliveEst: int               # numPlayers minus death fireworks seen
    arenaSize: int
    staticMap: seq[string]
    coach: Coach
    finaleOn: bool
    # talk bookkeeping: the transcript is the game's public record —
    # a silent bot is a bug, not a style
    lastTalkTick: int
    lastContactTick: int
    lastHurtTick: int
    lastGiftTick: int
    saidPlan: bool
    saidFinale: bool
    saidPodium: bool

proc defaultCoach(): Coach =
  ## Survival-meta defaults: speed to disengage, athleticism to shrug off
  ## the hazards that kill more brains than blades, low aggression because
  ## a kill is worth exactly zero points.
  Coach(active: false, stats: [7, 3, 5, 5], opening: "center",
        aggression: 3, healAt: 70, fleeAt: 55, ringMargin: 2,
        lootPriority: @[], finaleMode: "smart")

proc loadCoach(): Coach =
  result = defaultCoach()
  let path = getEnv("COACH_POLICY_FILE")
  let slotStr = getEnv("COACH_SLOT")
  if path.len == 0 or slotStr.len == 0 or not fileExists(path):
    return
  try:
    let j = parseJson(readFile(path))
    let ss = j{"slots"}{slotStr}
    if ss != nil and ss.kind == JObject:
      result.stats = [clamp(ss{"speed"}.getInt(7), 1, 10),
                      clamp(ss{"strength"}.getInt(3), 1, 10),
                      clamp(ss{"intelligence"}.getInt(5), 1, 10),
                      clamp(ss{"athleticism"}.getInt(5), 1, 10)]
    let p = j{"policy"}
    if p != nil and p.kind == JObject:
      result.opening = p{"opening"}.getStr("center")
      result.aggression = clamp(p{"aggression"}.getInt(3), 0, 10)
      result.healAt = clamp(p{"heal_at"}.getInt(70), 0, 100)
      result.fleeAt = clamp(p{"flee_at"}.getInt(55), 0, 100)
      result.ringMargin = clamp(p{"ring_margin"}.getInt(2), 0, 4)
      result.finaleMode = p{"finale"}.getStr("smart")
      if p{"loot_priority"} != nil and p{"loot_priority"}.kind == JArray:
        for it in p["loot_priority"]:
          result.lootPriority.add(it.getStr())
    result.active = true
    echo "coach policy loaded for slot ", slotStr
  except CatchableError:
    echo "coach policy unreadable, using defaults"

proc blockedAt(c: Ctx, x, y: int): bool =
  if x < 0 or y < 0 or x >= c.arenaSize or y >= c.arenaSize:
    return true
  c.staticMap[y][x] in {'#', 'R', 'F'}

const DirNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const Dx = [0, 1, 1, 1, 0, -1, -1, -1]
const Dy = [-1, -1, 0, 1, 1, 1, 0, -1]

proc dirToward(c: Ctx, fx, fy, tx, ty: int): int =
  ## Greedy 8-dir step toward target; picks the unblocked dir minimizing
  ## remaining distance. -1 when boxed in.
  var best = -1
  var bestD = int.high
  for d in 0 .. 7:
    let nx = fx + Dx[d]
    let ny = fy + Dy[d]
    if c.blockedAt(nx, ny):
      continue
    let dd = (nx - tx) * (nx - tx) + (ny - ty) * (ny - ty)
    if dd < bestD:
      bestD = dd
      best = d
  best

proc dirAway(c: Ctx, fx, fy, tx, ty: int): int =
  var best = -1
  var bestD = -1
  for d in 0 .. 7:
    let nx = fx + Dx[d]
    let ny = fy + Dy[d]
    if c.blockedAt(nx, ny):
      continue
    let dd = (nx - tx) * (nx - tx) + (ny - ty) * (ny - ty)
    if dd > bestD:
      bestD = dd
      best = d
  best

proc dirAwaySafe(c: Ctx, fx, fy, ex, ey, cx, cy, maxR: int): int =
  ## Evade WITHOUT backing into the fire: of the unblocked steps that stay
  ## within maxR of the zone centre, take the one that opens the most
  ## distance from the enemy. Plain dirAway walked bots into the ring.
  var best = -1
  var bestD = -1
  for d in 0 .. 7:
    let nx = fx + Dx[d]
    let ny = fy + Dy[d]
    if c.blockedAt(nx, ny):
      continue
    if (nx - cx) * (nx - cx) + (ny - cy) * (ny - cy) > maxR * maxR:
      continue
    let dd = (nx - ex) * (nx - ex) + (ny - ey) * (ny - ey)
    if dd > bestD:
      bestD = dd
      best = d
  if best >= 0: best else: c.dirAway(fx, fy, ex, ey)

proc alignedDir(fx, fy, tx, ty: int): int =
  ## Straight 8-dir line from (fx,fy) to (tx,ty), or -1.
  let dx = tx - fx
  let dy = ty - fy
  if dx == 0 and dy == 0:
    return -1
  if dx == 0 or dy == 0 or abs(dx) == abs(dy):
    let sx = (if dx > 0: 1 elif dx < 0: -1 else: 0)
    let sy = (if dy > 0: 1 elif dy < 0: -1 else: 0)
    for d in 0 .. 7:
      if Dx[d] == sx and Dy[d] == sy:
        return d
  -1

proc weaponRank(id: string): int =
  case id
  of "sword": 6
  of "spear": 5
  of "bow": 4
  of "knives": 3
  of "blowgun": 2
  of "net": 1
  else: 0

proc maybeTalk(c: var Ctx, m: JsonNode, ws: WebSocket) =
  ## Event-driven chatter. FFA diplomacy carries at any distance, so the
  ## bot negotiates instead of narrating: kills pay nothing and it says so
  ## to anyone who gets close. The sim rate-limits to 1 msg/s; we stay
  ## sparser so the transcript reads as intent, not spam.
  let tick = m{"tick"}.getInt(0)
  if tick - c.lastTalkTick < 96:
    return
  let you = m["you"]
  let x = you["pos"][0].getInt()
  let y = you["pos"][1].getInt()
  let hp = you["hp"].getInt()

  template say(channelArg: string, toArg: int, textArg: string) =
    ws.send($(%*{"type": "talk", "channel": channelArg, "to": toArg,
                 "text": textArg}), TextMessage)
    c.lastTalkTick = tick
    return

  for e in m{"events"}.getElems():
    case e{"type"}.getStr()
    of "ignition":
      if not c.saidPlan:
        c.saidPlan = true
        if c.coach.aggression >= 8:
          say("broadcast", -1, "good luck everyone. you will need it")
        else:
          say("broadcast", -1,
              "blood pays nothing here. stay out of my way and we all place")
    of "finale":
      if not c.saidFinale:
        c.saidFinale = true
        if c.coach.finaleMode == "evade":
          say("broadcast", -1, "i wont swing first. the ring can pick the winner")
        else:
          say("broadcast", -1, "two of us left. no hard feelings")
    of "gift_landed":
      if tick - c.lastGiftTick > 240 and e{"pos"} != nil:
        let gx = e["pos"][0].getInt()
        let gy = e["pos"][1].getInt()
        if (gx - x) * (gx - x) + (gy - y) * (gy - y) <= 144:
          c.lastGiftTick = tick
          say("broadcast", -1, "the drop at (" & $gx & "," & $gy &
              ") is spoken for. contest it and we both lose points")
    else:
      discard

  if c.aliveEst == 3 and not c.saidPodium:
    c.saidPodium = true
    say("broadcast", -1, "podium locked. every fight now is minus points - let the ring settle it")
  if hp < 25 and tick - c.lastHurtTick > 480:
    c.lastHurtTick = tick
    say("broadcast", -1, "im no threat to anyone. finishing me buys you nothing")
  if tick - c.lastContactTick > 240:
    for a in m["visible"]["agents"]:
      let slot = a["slot"].getInt()
      c.lastContactTick = tick
      say("dm", slot, "i see you P" & $slot &
          ". kills score zero - walk away and outlive someone else")

proc decide(c: var Ctx, m: JsonNode): JsonNode =
  ## Survival doctrine, in strict priority: the ring kills more agents than
  ## agents do, distance is the only armour that costs nothing, and the
  ## only fights worth taking are the ones that end an adjacent threat.
  let you = m["you"]
  let pos = you["pos"]
  let x = pos[0].getInt()
  let y = pos[1].getInt()
  let hp = you["hp"].getInt()
  let handId = you["hand"]{"id"}.getStr("none")
  let phase = m["phase"].getStr()
  if phase == "countdown":
    return %*{"type": "action", "do": "none"}
  for e in m{"events"}.getElems():
    case e{"type"}.getStr()
    of "finale": c.finaleOn = true
    of "death_fireworks": c.aliveEst = max(1, c.aliveEst - 1)
    else: discard

  let co = c.coach
  let zone = m["zone"]
  let cx = zone["center"][0].getInt()
  let cy = zone["center"][1].getInt()
  let myD2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
  let curR = zone["radius"].getInt()
  let nextR = zone["next_radius"].getInt()
  let tick = m{"tick"}.getInt(0)
  # the podium is the payday: with four left, one death banks a bonus —
  # take zero avoidable risks from here in
  let nearPodium = c.aliveEst <= 4
  let safeR = max(1, nextR - co.ringMargin)

  # nearest opponent — everyone is one
  var enemyD2 = int.high
  var ex, ey = -1
  var enemyCritical = false
  for a in m["visible"]["agents"]:
    let ax = a["pos"][0].getInt()
    let ay = a["pos"][1].getInt()
    let dd = (ax - x) * (ax - x) + (ay - y) * (ay - y)
    if dd < enemyD2:
      enemyD2 = dd
      ex = ax
      ey = ay
      enemyCritical = a["hp_band"].getStr() == "critical"

  # 0. never restart an active channel (heal/forage completes on its own)
  var channeling = false
  for e in you["effects"]:
    if e{"id"}.getStr() == "channeling":
      channeling = true
  if channeling:
    return %*{"type": "action", "do": "none"}
  # 1. the fire is the deadliest opponent: outside the CURRENT radius,
  # nothing else matters
  if myD2 > curR * curR:
    let d = c.dirToward(x, y, cx, cy)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 2. threat response. Disengage by default — a kill pays zero — but a
  # cornered bot with a weapon swings, and an adjacent critical enemy is
  # ended before it heals into a threat again.
  let rng = (case handId
             of "bow": 8
             of "knives": 5
             of "blowgun": 6
             of "spear": 2
             else: 1)
  # the last-two showdown must END: evading into a closed ring scores a
  # double death and no winner. Hunt once the ring is small or we hold any
  # edge — and fists count, the finale has no weapon requirement.
  let finaleHunt = c.finaleOn and co.finaleMode != "evade" and
                   (co.finaleMode == "fight" or curR <= 8 or
                    (weaponRank(handId) >= 1 and hp >= 55))
  # terminal burn: with the ring fully closed everyone is dying at once and
  # placement is decided by who dies LAST — every point of damage dealt now
  # moves us up the ladder, so pacifism stops paying exactly here
  let terminalBurn = curR <= 2
  if ex >= 0:
    let threatened = enemyD2 <= 9
    let mustFlee = (hp < co.fleeAt or weaponRank(handId) == 0 or
                    (nearPodium and not c.finaleOn)) and not terminalBurn
    if threatened and mustFlee and not finaleHunt:
      let d = c.dirAwaySafe(x, y, ex, ey, cx, cy, safeR)
      if d >= 0:
        return %*{"type": "action", "do": "move", "dir": DirNames[d]}
    if weaponRank(handId) >= 1 or finaleHunt or terminalBurn:
      let ad = alignedDir(x, y, ex, ey)
      # finish an adjacent critical, answer an adjacent threat, hunt at the
      # finale, or race the burn — never chase across the arena for zero
      let engage = (enemyD2 <= 2 and (enemyCritical or hp >= co.fleeAt)) or
                   (enemyCritical and enemyD2 <= rng * rng and
                    co.aggression >= 5) or
                   finaleHunt or terminalBurn
      if engage:
        if ad >= 0 and enemyD2 <= rng * rng:
          return %*{"type": "action", "do": "attack", "dir": DirNames[ad]}
        if finaleHunt or terminalBurn:
          let d = c.dirToward(x, y, ex, ey)
          if d >= 0:
            return %*{"type": "action", "do": "move", "dir": DirNames[d]}
    # armed but not engaging: open space toward the safe band
    if threatened:
      let d = c.dirAwaySafe(x, y, ex, ey, cx, cy, safeR)
      if d >= 0:
        return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 3. heal early: hp is placement in a survival game. Safe means no one
  # visible within striking distance, not no one visible at all.
  if hp < co.healAt and (ex < 0 or enemyD2 > 64):
    for idx in 0 ..< you["pack"].len:
      let ps = you["pack"][idx]
      if ps.kind != JNull and ps{"id"}.getStr() in ["first_aid", "rations"]:
        return %*{"type": "action", "do": "use", "slot": idx}
  # 4. ring preparation: stay ringMargin inside the NEXT radius
  if myD2 > safeR * safeR:
    let d = c.dirToward(x, y, cx, cy)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 5. loot: pick up anything on my tile; walk to the best visible item
  # or pod — but never walk INTO someone to do it (contested loot is a
  # fight, and fights pay nothing)
  var onMyTile = false
  for it in m["visible"]["items"]:
    if it["pos"][0].getInt() == x and it["pos"][1].getInt() == y:
      onMyTile = true
  for pod in m["visible"]["pods"]:
    if pod["landed"].getBool() and pod["pos"][0].getInt() == x and
       pod["pos"][1].getInt() == y:
      onMyTile = true
  if onMyTile:
    return %*{"type": "action", "do": "pickup"}
  if ex < 0 or enemyD2 > 36:
    var tx, ty = -1
    var bestScore = -1
    for it in m["visible"]["items"]:
      let id = it["id"].getStr()
      # healing IS placement; a weapon is only insurance for being cornered
      var score = (case id
                   of "first_aid": 24
                   of "rations": 18
                   else: 10 + weaponRank(id))
      let pi = co.lootPriority.find(id)
      if pi >= 0:
        score += 50 - 5 * pi    # coach's shopping list outranks instinct
      if score > bestScore:
        bestScore = score
        tx = it["pos"][0].getInt()
        ty = it["pos"][1].getInt()
    for pod in m["visible"]["pods"]:
      if pod["landed"].getBool():
        let mine = pod["recipient_slot"].getInt() == c.slot
        let score = (if mine: 40 else: 20)
        if score > bestScore:
          bestScore = score
          tx = pod["pos"][0].getInt()
          ty = pod["pos"][1].getInt()
    if tx >= 0:
      let d = c.dirToward(x, y, tx, ty)
      if d >= 0:
        return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 6. forage when standing on a bush (opening "forage" also seeks them)
  for b in m["visible"]["bushes"]:
    if b["pos"][0].getInt() == x and b["pos"][1].getInt() == y and
       b["charges"].getInt() > 0:
      return %*{"type": "action", "do": "interact"}
  if co.opening == "forage" and tick < 2400:
    var bx, by = -1
    var bd = int.high
    for b in m["visible"]["bushes"]:
      if b["charges"].getInt() > 0:
        let dd = (b["pos"][0].getInt() - x) * (b["pos"][0].getInt() - x) +
                 (b["pos"][1].getInt() - y) * (b["pos"][1].getInt() - y)
        if dd < bd:
          bd = dd
          bx = b["pos"][0].getInt()
          by = b["pos"][1].getInt()
    if bx >= 0:
      let d = c.dirToward(x, y, bx, by)
      if d >= 0:
        return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 7. movement doctrine: coached opening early; after that, SPACING —
  # the centre crowd is where the zero-point fights happen, so hold the
  # safe band and keep visible agents at arm's length instead of drifting
  # into the scrum. The ring shepherds everyone together at the end.
  if tick < 1440:
    case co.opening
    of "fortress":
      if myD2 > 4:
        let d = c.dirToward(x, y, cx, cy)
        if d >= 0:
          return %*{"type": "action", "do": "move", "dir": DirNames[d]}
    of "outer":
      # hold the mid-outer band (radius ~17) until the ring starts biting
      if myD2 < 15 * 15:
        let d = c.dirAway(x, y, cx, cy)
        if d >= 0:
          return %*{"type": "action", "do": "move", "dir": DirNames[d]}
      return %*{"type": "action", "do": "none"}
    else:
      discard
  if ex >= 0 and enemyD2 <= 25:
    let d = c.dirAwaySafe(x, y, ex, ey, cx, cy, safeR)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  if myD2 > safeR * safeR or (safeR <= 6 and myD2 > 4):
    let d = c.dirToward(x, y, cx, cy)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  %*{"type": "action", "do": "none"}

when isMainModule:
  var url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    url = getEnv("COGAMES_ENGINE_WS_URL")
  if url.len == 0 and paramCount() >= 1:
    url = paramStr(1)
  if url.len == 0:
    quit "COWORLD_PLAYER_WS_URL / COGAMES_ENGINE_WS_URL not set", 1

  var ctx: Ctx
  ctx.coach = loadCoach()
  let ws = newWebSocket(url)
  ws.send($(%*{"type": "allocate_stats",
               "speed": ctx.coach.stats[0],
               "strength": ctx.coach.stats[1],
               "intelligence": ctx.coach.stats[2],
               "athleticism": ctx.coach.stats[3]}), TextMessage)
  while true:
    let msgOpt = ws.receiveMessage()
    if msgOpt.isNone:
      break
    let raw = msgOpt.get().data
    var m: JsonNode
    try:
      m = parseJson(raw)
    except CatchableError:
      continue
    case m{"type"}.getStr("")
    of "player_config":
      ctx.slot = m["slot"].getInt()
      ctx.numPlayers = m{"num_players"}.getInt(16)
      ctx.aliveEst = ctx.numPlayers
      ctx.arenaSize = m["arena"]["size"].getInt()
      ctx.staticMap = @[]
      for row in m["arena"]["static_map"]:
        ctx.staticMap.add(row.getStr())
    of "observation":
      if ctx.staticMap.len > 0:
        try:
          ctx.maybeTalk(m, ws)
          ws.send($decide(ctx, m), TextMessage)
        except CatchableError:
          break
    of "final":
      break
    else:
      discard
  quit 0
