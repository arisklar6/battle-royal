## Zero Sum baseline player (DESIGN §18): legal build, grabs loot, fights
## when strong, flees weak, obeys the zone, claims sponsor drops, forages.
## Certify/demo quality, not competitive strength.
##
## COACH MODE (local play): when COACH_POLICY_FILE + COACH_SLOT are set, the
## bot reads the human coach's pre-match plan — stat allocation and strategy
## knobs — and executes it. The human never drives the seat mid-match; the
## coached bot is still a policy program (v0.2 AI-only invariant holds).

import std/[json, os, strutils]
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
    teammate: int
    arenaSize: int
    staticMap: seq[string]
    coach: Coach
    finaleOn: bool

proc defaultCoach(): Coach =
  Coach(active: false, stats: [6, 6, 4, 4], opening: "center",
        aggression: 5, healAt: 60, fleeAt: 35, ringMargin: 1,
        lootPriority: @[], finaleMode: "fight")

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
      result.stats = [clamp(ss{"speed"}.getInt(6), 1, 10),
                      clamp(ss{"strength"}.getInt(6), 1, 10),
                      clamp(ss{"intelligence"}.getInt(4), 1, 10),
                      clamp(ss{"athleticism"}.getInt(4), 1, 10)]
    let p = j{"policy"}
    if p != nil and p.kind == JObject:
      result.opening = p{"opening"}.getStr("center")
      result.aggression = clamp(p{"aggression"}.getInt(5), 0, 10)
      result.healAt = clamp(p{"heal_at"}.getInt(60), 0, 100)
      result.fleeAt = clamp(p{"flee_at"}.getInt(35), 0, 100)
      result.ringMargin = clamp(p{"ring_margin"}.getInt(1), 0, 4)
      result.finaleMode = p{"finale"}.getStr("fight")
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

proc decide(c: var Ctx, m: JsonNode): JsonNode =
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
    if e{"type"}.getStr() == "finale":
      c.finaleOn = true

  let co = c.coach
  let zone = m["zone"]
  let cx = zone["center"][0].getInt()
  let cy = zone["center"][1].getInt()
  let myD2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
  let nextR = zone["next_radius"].getInt()
  let tick = m{"tick"}.getInt(0)

  # nearest "enemy" — at the finale the partner is one too
  var enemyD2 = int.high
  var ex, ey = -1
  var enemyCritical = false
  for a in m["visible"]["agents"]:
    let slot = a["slot"].getInt()
    if slot == c.teammate and not c.finaleOn:
      continue
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
  # 1. survival: flee visible enemies when weak (finale "evade" flees always)
  let fleeAt = (if c.finaleOn and co.finaleMode == "evade": 101 else: co.fleeAt)
  if hp < fleeAt and ex >= 0:
    let d = c.dirAway(x, y, ex, ey)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 2. heal when safe
  if hp < co.healAt and ex < 0:
    for idx in 0 ..< you["pack"].len:
      let ps = you["pack"][idx]
      if ps.kind != JNull and ps{"id"}.getStr() in ["first_aid", "rations"]:
        return %*{"type": "action", "do": "use", "slot": idx}
  # 3. zone obedience: stay ringMargin inside the NEXT radius
  if myD2 > (nextR - co.ringMargin) * (nextR - co.ringMargin):
    let d = c.dirToward(x, y, cx, cy)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 4. fight — appetite set by aggression (0-2 only finishes crippled prey)
  let minRank = (if co.aggression >= 7: 1 else: 3)
  let hpGate = clamp(70 - co.aggression * 4, 20, 70)
  let wantFight = (if co.aggression <= 2: enemyCritical
                   else: hp >= hpGate or enemyCritical)
  if ex >= 0 and weaponRank(handId) >= minRank and wantFight and
     not (c.finaleOn and co.finaleMode == "evade"):
    let ad = alignedDir(x, y, ex, ey)
    let rng = (case handId
               of "bow": 8
               of "knives": 5
               of "blowgun": 6
               of "spear": 2
               else: 1)
    if ad >= 0 and enemyD2 <= rng * rng:
      return %*{"type": "action", "do": "attack", "dir": DirNames[ad]}
    let d = c.dirToward(x, y, ex, ey)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 5. loot: pick up anything on my tile; walk to best visible item/pod
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
  var tx, ty = -1
  var bestScore = -1
  for it in m["visible"]["items"]:
    let id = it["id"].getStr()
    var score = 10 + weaponRank(id)
    let pi = co.lootPriority.find(id)
    if pi >= 0:
      score += 50 - 5 * pi      # coach's shopping list outranks instinct
    if score > bestScore:
      bestScore = score
      tx = it["pos"][0].getInt()
      ty = it["pos"][1].getInt()
  for pod in m["visible"]["pods"]:
    if pod["landed"].getBool():
      let mine = pod["recipient_slot"].getInt() in [c.slot, c.teammate]
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
  # 7. movement doctrine: coached opening early, then centre drift
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
  let d = c.dirToward(x, y, cx, cy)
  if d >= 0 and myD2 > 9:
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
      ctx.teammate = m["teammate_slot"].getInt()
      ctx.arenaSize = m["arena"]["size"].getInt()
      ctx.staticMap = @[]
      for row in m["arena"]["static_map"]:
        ctx.staticMap.add(row.getStr())
    of "observation":
      if ctx.staticMap.len > 0:
        try:
          ws.send($decide(ctx, m), TextMessage)
        except CatchableError:
          break
    of "final":
      break
    else:
      discard
  quit 0
