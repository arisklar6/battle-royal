## Zero Sum baseline player (DESIGN §18): legal build, grabs loot, fights
## when strong, flees weak, obeys the zone, claims sponsor drops, forages.
## Certify/demo quality, not competitive strength.

import std/[json, os, strutils]
import whisky

type Ctx = object
  slot: int
  teammate: int
  arenaSize: int
  staticMap: seq[string]

proc blockedAt(c: Ctx, x, y: int): bool =
  if x < 0 or y < 0 or x >= c.arenaSize or y >= c.arenaSize:
    return true
  c.staticMap[y][x] in {'#', 'R', 'F'}

const DirNames = ["dN", "dNE", "dE", "dSE", "dS", "dSW", "dW", "dNW"]
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

proc decide(c: Ctx, m: JsonNode): JsonNode =
  let you = m["you"]
  let pos = you["pos"]
  let x = pos[0].getInt()
  let y = pos[1].getInt()
  let hp = you["hp"].getInt()
  let handId = you["hand"]{"id"}.getStr("none")
  let phase = m["phase"].getStr()
  if phase == "countdown":
    return %*{"type": "action", "do": "none"}

  let zone = m["zone"]
  let zr = zone["radius"].getInt()
  let cx = zone["center"][0].getInt()
  let cy = zone["center"][1].getInt()
  let myD2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
  let nextR = zone["next_radius"].getInt()

  # nearest visible enemy
  var enemyD2 = int.high
  var ex, ey = -1
  var enemyCritical = false
  for a in m["visible"]["agents"]:
    let slot = a["slot"].getInt()
    if slot == c.teammate:
      continue
    let ax = a["pos"][0].getInt()
    let ay = a["pos"][1].getInt()
    let dd = (ax - x) * (ax - x) + (ay - y) * (ay - y)
    if dd < enemyD2:
      enemyD2 = dd
      ex = ax
      ey = ay
      enemyCritical = a["hp_band"].getStr() == "critical"

  # 1. survival: flee visible enemies when weak
  if hp < 35 and ex >= 0:
    let d = c.dirAway(x, y, ex, ey)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 2. heal when safe
  if hp < 60 and ex < 0:
    for idx in 0 ..< you["pack"].len:
      let ps = you["pack"][idx]
      if ps.kind != JNull and ps{"id"}.getStr() in ["first_aid", "rations"]:
        return %*{"type": "action", "do": "use", "slot": idx}
  # 3. zone obedience: stay inside the NEXT radius
  if myD2 > (nextR - 1) * (nextR - 1):
    let d = c.dirToward(x, y, cx, cy)
    if d >= 0:
      return %*{"type": "action", "do": "move", "dir": DirNames[d]}
  # 4. fight when strong (armed, healthy or prey weak)
  if ex >= 0 and (weaponRank(handId) >= 3 and (hp >= 50 or enemyCritical)):
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
    let score = 10 + weaponRank(it["id"].getStr())
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
  # 6. forage when standing on a bush
  for b in m["visible"]["bushes"]:
    if b["pos"][0].getInt() == x and b["pos"][1].getInt() == y and
       b["charges"].getInt() > 0:
      return %*{"type": "action", "do": "interact"}
  # 7. drift toward center
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

  let ws = newWebSocket(url)
  ws.send($(%*{"type": "allocate_stats", "speed": 6, "strength": 6,
               "intelligence": 4, "athleticism": 4}), TextMessage)
  var ctx: Ctx
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
