## sprite_v1 renderer — step-1 placeholder art (flagged for aesthetic review):
## solid-color tiles baked into one background sprite, 6x6 team-colored agent
## chips, ray-burst fireworks. Spectacle grows in later steps.

import std/tables
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
  SpZoneFire = 33
  SpPod = 34
  SpPodMark = 35
  SpFirestorm = 36
  SpFlood = 37
  SpItemBase = 50           # 50 + ord(ItemId), 6x6 ground item chips
  SpProjBase = 80           # 80 + ord(ItemId) for arrow/dart/knife/net
  SpHudBase = 200           # rotating text sprites (200..205)
  SpBanner = 210            # rotating banner text (210..211)

  ObBackground = 1
  ObAgentBase = 100         # 100 + slot
  ObEffectBase = 1000
  ObZoneRingBase = 30000    # pool for zone-front tiles
  ZoneRingPool = 400
  ObPodBase = 40000         # pod markers/crates by pod index
  PodPool = 64
  ObItemBase = 41000        # ground-item chips
  ItemPool = 300
  ObProjBase = 42000        # projectiles in flight
  ProjPool = 64
  ObRegionBase = 43000      # firestorm/flood tint tiles
  RegionPool = 400
  ObHudLine1 = 50001        # UI layer objects
  ObHudLine2 = 50002
  ObBanner = 50010

  LayerHudTL = 1            # anchored top-left UI layer
  LayerHudBL = 4            # anchored bottom-left
  LayerBanner = 5           # anchored center-top

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
    ringDrawn: int            # zone-front objects currently defined
    podsDrawn: int
    itemsDrawn: int
    projsDrawn: int
    regionDrawn: int
    hudFlip: int              # rotating sprite ids for redefined text
    lastHud1, lastHud2: string
    bannerText: string
    bannerUntil: int
    bannerFlip: int

proc put(pixels: var seq[uint8], w, x, y: int, r, g, b: uint8, a: uint8 = 255) =
  let i = (y * w + x) * 4
  pixels[i] = r; pixels[i+1] = g; pixels[i+2] = b; pixels[i+3] = a

proc solid(w, h: int, r, g, b: uint8): seq[uint8] =
  result = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result.put(w, x, y, r, g, b)

# --- tiny 3x5 pixel font (placeholder art; digits, caps, few symbols) ---
const Glyphs = {
  '0': 0b111_101_101_101_111, '1': 0b010_110_010_010_111,
  '2': 0b111_001_111_100_111, '3': 0b111_001_111_001_111,
  '4': 0b101_101_111_001_001, '5': 0b111_100_111_001_111,
  '6': 0b111_100_111_101_111, '7': 0b111_001_010_010_010,
  '8': 0b111_101_111_101_111, '9': 0b111_101_111_001_111,
  'A': 0b010_101_111_101_101, 'B': 0b110_101_110_101_110,
  'C': 0b011_100_100_100_011, 'D': 0b110_101_101_101_110,
  'E': 0b111_100_110_100_111, 'F': 0b111_100_110_100_100,
  'G': 0b011_100_101_101_011, 'H': 0b101_101_111_101_101,
  'I': 0b111_010_010_010_111, 'K': 0b101_110_100_110_101,
  'L': 0b100_100_100_100_111, 'M': 0b101_111_111_101_101,
  'N': 0b101_111_111_111_101, 'O': 0b010_101_101_101_010,
  'P': 0b110_101_110_100_100, 'R': 0b110_101_110_110_101,
  'S': 0b011_100_010_001_110, 'T': 0b111_010_010_010_010,
  'U': 0b101_101_101_101_111, 'V': 0b101_101_101_101_010,
  'W': 0b101_101_111_111_101, 'X': 0b101_101_010_101_101,
  'Y': 0b101_101_010_010_010, 'Z': 0b111_001_010_100_111,
  ':': 0b000_010_000_010_000, '-': 0b000_000_111_000_000,
  '>': 0b100_010_001_010_100, '.': 0b000_000_000_000_010,
  ' ': 0}.toTable

proc textPixels(text: string, r, g, b: uint8): (int, int, seq[uint8]) =
  ## 3x5 glyphs + 1px spacing, 1px padding, on a dark backing strip.
  let w = 2 + text.len * 4
  let h = 7
  var px = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      px.put(w, x, y, 12, 14, 10, 220)
  for i, ch in text:
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    let bits = Glyphs.getOrDefault(up, 0)
    for gy in 0 ..< 5:
      for gx in 0 ..< 3:
        if ((bits shr ((4 - gy) * 3 + (2 - gx))) and 1) == 1:
          px.put(w, 1 + i * 4 + gx, 1 + gy, r, g, b)
  (w, h, px)

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

proc itemColor(id: ItemId): (uint8, uint8, uint8) =
  case id
  of iSword: (220'u8, 220'u8, 235'u8)
  of iSpear: (180'u8, 140'u8, 90'u8)
  of iBow: (200'u8, 160'u8, 60'u8)
  of iKnives: (170'u8, 170'u8, 190'u8)
  of iBlowgun: (120'u8, 160'u8, 110'u8)
  of iNet: (140'u8, 140'u8, 100'u8)
  of iFirstAid: (240'u8, 80'u8, 80'u8)
  of iRations: (200'u8, 170'u8, 110'u8)
  of iBackpack: (150'u8, 110'u8, 60'u8)
  of iCamo: (90'u8, 120'u8, 70'u8)
  of iArrows: (210'u8, 190'u8, 120'u8)
  of iDarts: (140'u8, 200'u8, 140'u8)
  of iNone: (255'u8, 0'u8, 255'u8)

proc itemPixels(id: ItemId): seq[uint8] =
  ## 6x6 chip: item color diamond on transparent, white pip center.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let (r, g, b) = itemColor(id)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let d = abs(x * 2 + 1 - TileSize) + abs(y * 2 + 1 - TileSize)
      if d <= TileSize - 1:
        result.put(TileSize, x, y, r, g, b)
  result.put(TileSize, 2, 2, 255, 255, 255)

proc projPixels(id: ItemId): seq[uint8] =
  ## 4x4 flying projectile dot.
  result = newSeq[uint8](4 * 4 * 4)
  let (r, g, b) = itemColor(id)
  for y in 1 .. 2:
    for x in 0 .. 3:
      result.put(4, x, y, r, g, b)

proc spriteDefs(s: Sim): seq[uint8] =
  result.addSprite(SpBackground, WorldPx, WorldPx, backgroundPixels(s.arena), "arena")
  for slot in 0 .. 15:
    result.addSprite(SpAgentBase + slot, TileSize, TileSize, agentPixels(slot),
                     "agent" & $slot)
  result.addSprite(SpFwBlack, 18, 18, burstPixels(18, 25, 25, 30), "fw_black")
  result.addSprite(SpFwGold, 18, 18, burstPixels(18, 250, 210, 80), "fw_gold")
  result.addSprite(SpMineFlash, 12, 12, burstPixels(12, 255, 120, 40), "mine")
  # zone front: semi-transparent fire tile
  var fire = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let hot = (x + y) mod 2 == 0
      fire.put(TileSize, x, y,
               (if hot: 255'u8 else: 210'u8), (if hot: 110'u8 else: 60'u8), 20, 170)
  result.addSprite(SpZoneFire, TileSize, TileSize, fire, "zone_fire")
  # sponsor pod: white crate w/ red stripe; incoming marker: red target box
  var pod = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if y == TileSize div 2 or y == TileSize div 2 - 1:
        pod.put(TileSize, x, y, 220, 40, 40)
      else:
        pod.put(TileSize, x, y, 235, 235, 235)
  result.addSprite(SpPod, TileSize, TileSize, pod, "pod")
  var mark = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1:
        mark.put(TileSize, x, y, 255, 60, 60, 200)
  result.addSprite(SpPodMark, TileSize, TileSize, mark, "pod_mark")
  # hazard region tints
  var storm = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if (x + y) mod 2 == 0:
        storm.put(TileSize, x, y, 255, 90, 30, 120)
  result.addSprite(SpFirestorm, TileSize, TileSize, storm, "firestorm")
  var flood = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      flood.put(TileSize, x, y, 50, 90, 200, uint8(if y mod 3 == 0: 160 else: 110))
  result.addSprite(SpFlood, TileSize, TileSize, flood, "flood")
  # ground item + projectile chips
  for id in ItemId:
    if id != iNone:
      result.addSprite(SpItemBase + ord(id), TileSize, TileSize,
                       itemPixels(id), "item_" & $id)
  for id in [iArrows, iDarts, iKnives, iNet]:
    result.addSprite(SpProjBase + ord(id), 4, 4, projPixels(id), "proj_" & $id)

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
  # HUD lines (redefine text sprite only when the string changes)
  var deadCount = 0
  for a in s.agents:
    if not a.alive: inc deadCount
  let zrHud = s.zoneRadius()
  let secs = s.tick div 24
  let hud1 = "ALIVE " & $(16 - deadCount) & "  RING " & $zrHud &
             "  T " & $(secs div 60) & ":" & (if secs mod 60 < 10: "0" else: "") &
             $(secs mod 60)
  var hud2 = "COIN"
  for t in 0 .. 7:
    hud2.add(" " & TeamNames[t] & $s.teamBudget[t])
  if hud1 != r.lastHud1:
    r.lastHud1 = hud1
    let spId = SpHudBase + (r.hudFlip mod 2)
    inc r.hudFlip
    let (w, h, px) = textPixels(hud1, 255, 235, 150)
    result.addSprite(spId, w, h, px, "hud1")
    result.addObject(ObHudLine1, 2, 2, 0, LayerHudTL, spId)
  if hud2 != r.lastHud2:
    r.lastHud2 = hud2
    let spId = SpHudBase + 2 + (r.hudFlip mod 2)
    inc r.hudFlip
    let (w, h, px) = textPixels(hud2, 180, 220, 255)
    result.addSprite(spId, w, h, px, "hud2")
    result.addObject(ObHudLine2, 2, 2, 0, LayerHudBL, spId)
  # banner on big beats
  for e in s.events:
    let txt =
      case e.kind
      of evIgnition: "IGNITION"
      of evFinale: "FINALE"
      of evMatchEnd:
        (if e.slot >= 0: "WINNER " & $TeamNames[team(AgentId(e.slot))] &
                         " P" & $e.slot
         else: "MATCH OVER")
      else: ""
    if txt.len > 0:
      r.bannerText = txt
      r.bannerUntil = s.tick + 96
      let spId = SpBanner + (r.bannerFlip mod 2)
      inc r.bannerFlip
      let (w, h, px) = textPixels(txt, 255, 210, 80)
      result.addSprite(spId, w, h, px, "banner")
      result.addObject(ObBanner, 4, 4, 0, LayerBanner, spId)
  if r.bannerText.len > 0 and s.tick >= r.bannerUntil:
    r.bannerText = ""
    result.addDeleteObject(ObBanner)
  # ground items (skip tiles under landed pods; the crate reads better)
  var itemIdx = 0
  for g in s.ground:
    if itemIdx >= ItemPool: break
    var underPod = false
    for pod in s.pods:
      if pod.landed and pod.landing == g.pos:
        underPod = true
    if underPod: continue
    result.addObject(ObItemBase + itemIdx, g.pos.x * TileSize,
                     g.pos.y * TileSize, 8, LayerMap, SpItemBase + ord(g.item))
    inc itemIdx
  for stale in itemIdx ..< r.itemsDrawn:
    result.addDeleteObject(ObItemBase + stale)
  r.itemsDrawn = itemIdx
  # projectiles in flight
  var projIdx = 0
  for p in s.projectiles:
    if projIdx >= ProjPool: break
    result.addObject(ObProjBase + projIdx, p.pos.x * TileSize + 1,
                     p.pos.y * TileSize + 1, 18, LayerMap, SpProjBase + ord(p.kind))
    inc projIdx
  for stale in projIdx ..< r.projsDrawn:
    result.addDeleteObject(ObProjBase + stale)
  r.projsDrawn = projIdx
  # active hazard regions
  var regIdx = 0
  for ev in s.cfg.events:
    if s.tick < ev.fromTick or s.tick >= ev.fromTick + ev.duration:
      continue
    case ev.kind
    of ecFirestorm:
      for ty in max(1, ev.center.y - ev.radius) .. min(ArenaSize - 2, ev.center.y + ev.radius):
        for tx in max(1, ev.center.x - ev.radius) .. min(ArenaSize - 2, ev.center.x + ev.radius):
          if regIdx >= RegionPool: break
          let dx = tx - ev.center.x
          let dy = ty - ev.center.y
          if dx * dx + dy * dy <= ev.radius * ev.radius:
            result.addObject(ObRegionBase + regIdx, tx * TileSize,
                             ty * TileSize, 14, LayerMap, SpFirestorm)
            inc regIdx
    of ecFlood:
      for ty in max(1, ev.rect[1]) .. min(ArenaSize - 2, ev.rect[3]):
        for tx in max(1, ev.rect[0]) .. min(ArenaSize - 2, ev.rect[2]):
          if regIdx >= RegionPool: break
          result.addObject(ObRegionBase + regIdx, tx * TileSize,
                           ty * TileSize, 14, LayerMap, SpFlood)
          inc regIdx
  for stale in regIdx ..< r.regionDrawn:
    result.addDeleteObject(ObRegionBase + stale)
  r.regionDrawn = regIdx
  # sponsor pods: incoming marker blinks on the landing tile; landed = crate
  var podIdx = 0
  for pod in s.pods:
    if podIdx >= PodPool: break
    if pod.landed:
      result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                       pod.landing.y * TileSize, 12, LayerMap, SpPod)
    elif (s.tick div 6) mod 2 == 0:
      result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                       pod.landing.y * TileSize, 12, LayerMap, SpPodMark)
    else:
      result.addDeleteObject(ObPodBase + podIdx)
    inc podIdx
  for stale in podIdx ..< r.podsDrawn:
    result.addDeleteObject(ObPodBase + stale)
  r.podsDrawn = podIdx
  # zone front ring: tiles just outside the current radius
  var ringIdx = 0
  let zr = s.zoneRadius()
  if zr < ArenaSize and s.phase != phCountdown:
    let c = ArenaSize div 2
    for ty in 0 ..< ArenaSize:
      for tx in 0 ..< ArenaSize:
        if ringIdx >= ZoneRingPool: break
        let dx = tx - c
        let dy = ty - c
        let d2 = dx * dx + dy * dy
        if d2 > zr * zr and d2 <= (zr + 1) * (zr + 1):
          result.addObject(ObZoneRingBase + ringIdx,
            tx * TileSize, ty * TileSize, 15, LayerMap, SpZoneFire)
          inc ringIdx
  for stale in ringIdx ..< r.ringDrawn:
    result.addDeleteObject(ObZoneRingBase + stale)
  r.ringDrawn = ringIdx

proc initPacket*(r: Renderer, s: Sim): seq[uint8] =
  ## Complete current scene for a fresh viewer (or a replay-loop restart:
  ## clear-objects wipes stale client state; sprites stay loaded).
  result.addClearObjects()
  result.addLayer(LayerMap, 0x00, 0x01)
  result.addViewport(LayerMap, WorldPx, WorldPx)
  result.addLayer(LayerHudTL, 0x01, 0x02)
  result.addViewport(LayerHudTL, 160, 12)
  result.addLayer(LayerHudBL, 0x04, 0x02)
  result.addViewport(LayerHudBL, 200, 12)
  result.addLayer(LayerBanner, 0x05, 0x02)
  result.addViewport(LayerBanner, 120, 16)
  result.add(spriteDefs(s))
  result.addObject(ObBackground, 0, 0, 0, LayerMap, SpBackground)
  for slot in 0 .. 15:
    if s.agents[slot].alive:
      result.agentObject(s, slot)

proc resetForLoop*(r: var Renderer) =
  r.effects = @[]
  for i in 0 .. 15:
    r.deadDrawn[i] = false
  r.ringDrawn = 0
  r.podsDrawn = 0
  r.itemsDrawn = 0
  r.projsDrawn = 0
  r.regionDrawn = 0
  r.lastHud1 = ""
  r.lastHud2 = ""
  r.bannerText = ""
