## sprite_v1 renderer — step-1 placeholder art (flagged for aesthetic review):
## solid-color tiles baked into one background sprite, 6x6 team-colored agent
## chips, ray-burst fireworks. Spectacle grows in later steps.

import bitworld/spriteprotocol
import zero_sum/[types, arena, sim]

const
  LayerMap* = 0
  WorldPx* = ArenaSize * TileSize

  SpBackground = 1
  SpAgentBase = 10          # 10..25, one per slot (team color + parity dot)
  SpFwBlack = 30
  SpFwGold = 31
  SpMineFlash = 32

  ObBackground = 1
  ObAgentBase = 100         # 100 + slot
  ObEffectBase = 1000

  TeamColors: array[8, (uint8, uint8, uint8)] = [
    (220'u8, 60'u8, 60'u8), (70'u8, 110'u8, 230'u8), (70'u8, 190'u8, 90'u8),
    (230'u8, 200'u8, 60'u8), (160'u8, 80'u8, 220'u8), (70'u8, 200'u8, 210'u8),
    (240'u8, 140'u8, 50'u8), (240'u8, 110'u8, 180'u8)]

type
  Effect = object
    objId: int
    dieTick: int

  Renderer* = object
    nextEffect: int
    effects: seq[Effect]
    deadDrawn: array[16, bool]

proc put(pixels: var seq[uint8], w, x, y: int, r, g, b: uint8, a: uint8 = 255) =
  let i = (y * w + x) * 4
  pixels[i] = r; pixels[i+1] = g; pixels[i+2] = b; pixels[i+3] = a

proc solid(w, h: int, r, g, b: uint8): seq[uint8] =
  result = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.put(w, x, y, r, g, b)

proc tileColor(k: TileKind): (uint8, uint8, uint8) =
  case k
  of tkGround: (34'u8, 40'u8, 30'u8)
  of tkWall: (92'u8, 92'u8, 100'u8)
  of tkRock: (122'u8, 88'u8, 56'u8)
  of tkFortressWall: (156'u8, 156'u8, 166'u8)
  of tkPedestal: (212'u8, 175'u8, 55'u8)
  of tkBush: (52'u8, 118'u8, 56'u8)

proc backgroundPixels(a: Arena): seq[uint8] =
  result = newSeq[uint8](WorldPx * WorldPx * 4)
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      let (r, g, b) = tileColor(a.tiles[ty][tx])
      for py in 0 ..< TileSize:
        for px in 0 ..< TileSize:
          # 1px grid shading on ground for readability
          let dim = (px == 0 or py == 0) and a.tiles[ty][tx] == tkGround
          let rr = if dim: uint8(max(0, int(r) - 6)) else: r
          result.put(WorldPx, tx * TileSize + px, ty * TileSize + py, rr, g, b)

proc agentPixels(slot: int): seq[uint8] =
  let (r, g, b) = TeamColors[slot div 2]
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1:
        result.put(TileSize, x, y, 10, 10, 10)
      else:
        result.put(TileSize, x, y, r, g, b)
  if slot mod 2 == 1:
    result.put(TileSize, 1, 1, 255, 255, 255)

proc burstPixels(size: int, r, g, b: uint8): seq[uint8] =
  result = newSeq[uint8](size * size * 4)
  let c = size div 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let dx = x - c
      let dy = y - c
      let d2 = dx * dx + dy * dy
      let onRay = dx == 0 or dy == 0 or dx == dy or dx == -dy
      if onRay and d2 <= c * c:
        let a = uint8(255 - min(220, d2 * 220 div (c * c)))
        result.put(size, x, y, r, g, b, a)

proc spriteDefs(s: Sim): seq[uint8] =
  result.addSprite(SpBackground, WorldPx, WorldPx, backgroundPixels(s.arena), "arena")
  for slot in 0 .. 15:
    result.addSprite(SpAgentBase + slot, TileSize, TileSize, agentPixels(slot),
                     "agent" & $slot)
  result.addSprite(SpFwBlack, 18, 18, burstPixels(18, 25, 25, 30), "fw_black")
  result.addSprite(SpFwGold, 18, 18, burstPixels(18, 250, 210, 80), "fw_gold")
  result.addSprite(SpMineFlash, 12, 12, burstPixels(12, 255, 120, 40), "mine")

proc agentObject(packet: var seq[uint8], s: Sim, slot: int) =
  packet.addObject(ObAgentBase + slot,
    s.agents[slot].pos.x * TileSize, s.agents[slot].pos.y * TileSize,
    10, LayerMap, SpAgentBase + slot)

proc spawnEffect(r: var Renderer, packet: var seq[uint8], s: Sim,
                 spriteId, cx, cy, size, ttl: int) =
  let objId = ObEffectBase + (r.nextEffect mod 50_000)
  inc r.nextEffect
  packet.addObject(objId, cx - size div 2, cy - size div 2, 20, LayerMap, spriteId)
  r.effects.add(Effect(objId: objId, dieTick: s.tick + ttl))

proc updatePacket*(r: var Renderer, s: Sim): seq[uint8] =
  ## Per-tick delta: agent positions, death cleanup, event effects, expiries.
  for slot in 0 .. 15:
    if s.agents[slot].alive:
      result.agentObject(s, slot)
    elif not r.deadDrawn[slot]:
      result.addDeleteObject(ObAgentBase + slot)
      r.deadDrawn[slot] = true
  for e in s.events:
    let cx = e.pos.x * TileSize + TileSize div 2
    let cy = e.pos.y * TileSize + TileSize div 2
    case e.kind
    of evMineExplosion: r.spawnEffect(result, s, SpMineFlash, cx, cy, 12, 12)
    of evDeathFireworks: r.spawnEffect(result, s, SpFwBlack, cx, cy, 18, 36)
    of evIgnition: r.spawnEffect(result, s, SpFwGold, cx, cy, 18, 48)
    of evMatchEnd:
      if e.slot >= 0:
        let p = s.agents[e.slot].pos
        r.spawnEffect(result, s, SpFwGold,
          p.x * TileSize + TileSize div 2, p.y * TileSize + TileSize div 2, 18, 96)
    else: discard
  var kept: seq[Effect] = @[]
  for ef in r.effects:
    if s.tick >= ef.dieTick:
      result.addDeleteObject(ef.objId)
    else:
      kept.add(ef)
  r.effects = kept

proc initPacket*(r: Renderer, s: Sim): seq[uint8] =
  ## Complete current scene for a fresh viewer.
  result.addLayer(LayerMap, 0x00, 0x01)
  result.addViewport(LayerMap, WorldPx, WorldPx)
  result.add(spriteDefs(s))
  result.addObject(ObBackground, 0, 0, 0, LayerMap, SpBackground)
  for slot in 0 .. 15:
    if s.agents[slot].alive:
      result.agentObject(s, slot)

proc resetForLoop*(r: var Renderer) =
  r.effects = @[]
  for i in 0 .. 15:
    r.deadDrawn[i] = false
