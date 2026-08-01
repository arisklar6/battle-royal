## sprite_v1 renderer — v0.2 art (DESIGN §21.1, DECIDED): 12px humanoid
## figures with facing/walk/death, textured environment, animated hazards,
## parachute drops. All pixel data code-generated; <=15 visible colors per
## sprite (house convention).

import std/tables
import bitworld/spriteprotocol
import zero_sum/[types, arena, sim]

const
  LayerMap* = 0
  WorldPx* = ArenaSize * TileSize

  # sprite ids
  SpBackground = 1
  SpFwBlack = 30
  SpFwGold = 31
  SpMineFlash = 32
  SpZoneFireA = 33          # teal plasma (stages 1-4)
  SpZoneFireB = 34
  SpPodCrate = 35
  SpPodChute = 36
  SpFirestormA = 37
  SpFirestormB = 38
  SpFloodA = 39
  SpFloodB = 40
  SpPlasmaCritA = 41        # crimson plasma (stages 5+)
  SpPlasmaCritB = 42
  SpGlassBody = 43          # camo refractive silhouette
  SpNetMesh = 44
  SpPoisonHaloA = 45
  SpPoisonHaloB = 46
  SpVoidBeam = 47
  SpGoldBeam = 48
  SpGlitch = 49
  SpTrailBase = 750         # 750+ord: arrow/dart/knife trail ghosts
  SpMouthA = 700
  SpMouthB = 701
  SpCargoBase = 710         # rotating cargo-label text sprites (8)
  SpItemBase = 50          # 50 + ord(ItemId): ground chips
  SpProjBase = 80          # 80 + ord(ItemId): projectiles
  SpBushBase = 90          # 90..93: bush with 0..3 berries
  SpHudBase = 200
  SpBanner = 210
  # humanoids: 400 + slot*10 + facing(0..3)*2 + frame(0..1); corpse 560+slot
  SpBodyBase = 400
  SpCorpseBase = 560
  SpWeaponBase = 600       # 600 + ord(ItemId): held-weapon glyphs
  SpSlotLabelBase = 800    # 800 + slot: "P<n>" identity tags
  SpHpBandBase = 830       # 830 + band: hp semaphore bar (0 healthy/1 hurt/2 crit)
  SpRingGhost = 834        # dashed next-radius preview tile
  SpKillBase = 840         # 840..845: kill-feed lines (3 lines x 2 buffers)

  # object ids
  ObBackground = 1
  ObAgentBase = 100        # body
  ObWeaponBase = 200       # held weapon overlay (200+slot)
  ObEffectBase = 1000
  ObBushBase = 20000
  BushPool = 24
  ObZoneRingBase = 30000
  ZoneRingPool = 400
  ObNextRingBase = 31000
  NextRingPool = 200
  ObPodBase = 40000
  PodPool = 64
  ObItemBase = 41000
  ItemPool = 300
  ObProjBase = 42000
  ProjPool = 64
  ObRegionBase = 43000
  RegionPool = 400
  ObHudLine1 = 50001
  ObHudLine2 = 50002
  ObBanner = 50010
  ObHaloBase = 44000        # poison halo per slot
  ObMeshBase = 44100        # net mesh per slot
  ObMouthBase = 44200       # 8 gold mouth tiles
  ObPodBeamBase = 44300
  ObPodLabelBase = 44400
  ObSlotLabelBase = 45000   # + slot: identity tag under each agent
  ObHpBandBase = 45100      # + slot: hp semaphore over each agent
  ObKillLineBase = 50020    # + 0..2: kill-feed lines, newest first

  LayerHudTL = 1
  LayerHudBL = 4
  LayerBanner = 5

  BodyW = 8
  BodyH = 12

  ## Esports palette (DESIGN §21.3): team accents A-H
  ## coral pink / electric cyan / amber gold / royal violet / crimson /
  ## ice white / burnt orange (default) / magenta (default)
  TeamColors: array[8, (uint8, uint8, uint8)] = [
    (255'u8, 127'u8, 140'u8), (69'u8, 220'u8, 255'u8), (255'u8, 191'u8, 0'u8),
    (122'u8, 60'u8, 220'u8), (220'u8, 20'u8, 60'u8), (235'u8, 245'u8, 255'u8),
    (255'u8, 110'u8, 30'u8), (225'u8, 90'u8, 235'u8)]

  # palette tokens
  BgDark = (11'u8, 12'u8, 16'u8)          # #0B0C10
  Masonry = (31'u8, 40'u8, 51'u8)         # #1F2833
  PlasmaTeal = (102'u8, 252'u8, 241'u8)   # #66FCF1
  PlasmaCrit = (255'u8, 0'u8, 85'u8)      # #FF0055
  GoldTone = (197'u8, 160'u8, 89'u8)      # #C5A059
  ToxicFlood = (57'u8, 255'u8, 20'u8)     # #39FF14

  Skin = (232'u8, 190'u8, 150'u8)
  Hair = (60'u8, 42'u8, 30'u8)
  Pants = (48'u8, 44'u8, 56'u8)
  Outline = (18'u8, 16'u8, 14'u8)

type
  Effect = object
    objId: int
    dieTick: int

  Renderer* = object
    nextEffect: int
    effects: seq[Effect]
    deadDrawn: array[16, bool]
    facing: array[16, int]    # 0 S, 1 N, 2 E, 3 W
    lastPos: array[16, Pos]
    lastMoveTick: array[16, int]
    ringDrawn: int
    podsDrawn: int
    itemsDrawn: int
    projsDrawn: int
    regionDrawn: int
    bushesDrawn: int
    weaponDrawn: array[16, bool]
    hudFlip: int
    lastHud1, lastHud2: string
    bannerText: string
    bannerUntil: int
    bannerFlip: int
    haloOn: array[16, bool]
    meshOn: array[16, bool]
    wasCamoHidden: array[16, bool]
    mouthsDrawn: bool
    mouthPhase: int
    podBeamsDrawn: int
    labelFlip: int
    killFeed: seq[string]     # newest first, max 3
    killDirty: bool
    killFlip: int
    killLinesDrawn: int
    nextRingDrawn: int
    lastBgRadius: int         # last safe radius baked into the background

# ---------------------------------------------------------------- helpers

proc put(pixels: var seq[uint8], w, x, y: int, rgb: (uint8, uint8, uint8),
         a: uint8 = 255) =
  if x < 0 or y < 0 or x >= w:
    return
  let i = (y * w + x) * 4
  if i + 3 >= pixels.len:
    return
  pixels[i] = rgb[0]; pixels[i+1] = rgb[1]; pixels[i+2] = rgb[2]; pixels[i+3] = a

proc shade(c: (uint8, uint8, uint8), d: int): (uint8, uint8, uint8) =
  (uint8(max(0, min(255, int(c[0]) + d))),
   uint8(max(0, min(255, int(c[1]) + d))),
   uint8(max(0, min(255, int(c[2]) + d))))

proc tileHash(x, y: int): int = (x * 7 + y * 13 + (x * y) mod 11) mod 16

# ---------------------------------------------------------------- tiles

proc grassAt(px: var seq[uint8], w, ox, oy, tx, ty: int) =
  ## Dark-brutalist steel plate with a recessed grid seam (DESIGN §21.3).
  let h = tileHash(tx, ty)
  let base = shade(BgDark, (h mod 3) * 3)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let seam = x == 0 or y == 0
      px.put(w, ox + x, oy + y, (if seam: Masonry else: base))
  if h mod 5 == 0:                        # faint plate wear
    px.put(w, ox + 2 + (h mod 3), oy + 2 + (h div 3) mod 3, shade(base, 10))

proc bricksAt(px: var seq[uint8], w, ox, oy, tx, ty: int,
              base: (uint8, uint8, uint8)) =
  let mortar = shade(base, -36)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let brickShift = (if (ty * 2 + y div 3) mod 2 == 0: 0 else: 3)
      let onMortar = (y mod 3 == 2) or ((x + brickShift) mod 3 == 2)
      let jitter = (if tileHash(tx * 6 + x, ty * 6 + y) mod 7 == 0: -8 else: 0)
      px.put(w, ox + x, oy + y, (if onMortar: mortar else: shade(base, jitter)))

proc rockAt(px: var seq[uint8], w, ox, oy: int) =
  let base = (118'u8, 88'u8, 58'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let edge = x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1
      px.put(w, ox + x, oy + y, (if edge: shade(base, -30) else: base))
  px.put(w, ox + 1, oy + 1, shade(base, 26))
  px.put(w, ox + 2, oy + 1, shade(base, 26))

proc pedestalAt(px: var seq[uint8], w, ox, oy: int) =
  let gold = (208'u8, 172'u8, 60'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let ring = x in [0, TileSize - 1] or y in [0, TileSize - 1]
      px.put(w, ox + x, oy + y, (if ring: shade(gold, -50) else: gold))
  px.put(w, ox + 2, oy + 2, shade(gold, 30))
  px.put(w, ox + 3, oy + 3, shade(gold, 30))

proc backgroundPixels(a: Arena, safeR: int): seq[uint8] =
  ## safeR: tiles outside this center radius get a dark red "off-air" wash
  ## so the killing field is legible (pass >= ArenaSize for no wash).
  result = newSeq[uint8](WorldPx * WorldPx * 4)
  let c = ArenaSize div 2
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      let ox = tx * TileSize
      let oy = ty * TileSize
      case a.tiles[ty][tx]
      of tkGround, tkBush:      # bushes are objects; plate beneath
        grassAt(result, WorldPx, ox, oy, tx, ty)
      of tkWall:
        bricksAt(result, WorldPx, ox, oy, tx, ty, Masonry)
      of tkFortressWall:
        bricksAt(result, WorldPx, ox, oy, tx, ty, shade(Masonry, 22))
      of tkRock:
        grassAt(result, WorldPx, ox, oy, tx, ty)
        rockAt(result, WorldPx, ox, oy)
      of tkPedestal:
        grassAt(result, WorldPx, ox, oy, tx, ty)
        pedestalAt(result, WorldPx, ox, oy)
      let dx = tx - c
      let dy = ty - c
      if dx * dx + dy * dy > safeR * safeR:
        for y in 0 ..< TileSize:
          for x in 0 ..< TileSize:
            let i = ((oy + y) * WorldPx + ox + x) * 4
            result[i] = uint8(int(result[i]) * 3 div 5 + 26)
            result[i+1] = uint8(int(result[i+1]) * 3 div 5 + 4)
            result[i+2] = uint8(int(result[i+2]) * 3 div 5 + 8)

# ---------------------------------------------------------------- humanoids

proc bodyPixels(team, parity, facing, frame: int): seq[uint8] =
  ## 8x12 figure. facing: 0 S (face), 1 N (back), 2 E, 3 W. frame: walk phase.
  result = newSeq[uint8](BodyW * BodyH * 4)
  let tunic = TeamColors[team]
  let tunicDark = shade(tunic, -40)
  template P(x, y: int, c: (uint8, uint8, uint8)) =
    result.put(BodyW, x, y, c)
  # head rows 0..3 (centered cols 2..5)
  for x in 2 .. 5:
    P(x, 0, Hair)
  for y in 1 .. 3:
    P(1, y, Outline)
    P(6, y, Outline)
    for x in 2 .. 5:
      P(x, y, Skin)
  case facing
  of 0:                        # south: face
    P(3, 2, Outline)
    P(4, 2, Outline)
  of 2:                        # east profile: eye right
    P(5, 2, Outline)
    P(2, 1, Hair)
  of 3:                        # west profile
    P(2, 2, Outline)
    P(5, 1, Hair)
  else:                        # north: hair back
    for x in 2 .. 5:
      P(x, 1, Hair)
  # torso rows 4..8
  for y in 4 .. 8:
    for x in 2 .. 5:
      P(x, y, (if y == 8: tunicDark else: tunic))
  # arms: swing with frame; side facings show one arm
  let armUp = frame == 1
  if facing in [0, 1]:
    P(1, (if armUp: 4 else: 5), Skin)
    P(1, (if armUp: 5 else: 6), Skin)
    P(6, (if armUp: 6 else: 5), Skin)
    P(6, (if armUp: 5 else: 4), Skin)
  elif facing == 2:
    P(6, (if armUp: 4 else: 6), Skin)
    P(6, 5, Skin)
  else:
    P(1, (if armUp: 4 else: 6), Skin)
    P(1, 5, Skin)
  # parity pip on chest
  if parity == 1:
    P(3, 5, (250'u8, 250'u8, 250'u8))
  # legs rows 9..11: stride by frame
  if frame == 0:
    for y in 9 .. 11:
      P(3, y, Pants)
      P(4, y, Pants)
  else:
    P(2, 9, Pants); P(3, 9, Pants); P(4, 9, Pants); P(5, 9, Pants)
    P(2, 10, Pants); P(5, 10, Pants)
    P(1, 11, Pants); P(6, 11, Pants)
  # boots
  P(3, 11, Outline)
  P(4, 11, Outline)

proc corpsePixels(team, parity: int): seq[uint8] =
  ## 12x6 fallen figure + dark pool.
  result = newSeq[uint8](12 * 6 * 4)
  let tunic = shade(TeamColors[team], -20)
  template P(x, y: int, c: (uint8, uint8, uint8)) =
    result.put(12, x, y, c)
  for x in 1 .. 10:
    P(x, 5, (70'u8, 20'u8, 20'u8))                 # pool
  for x in 2 .. 3:
    for y in 2 .. 3:
      P(x, y, Skin)                                 # head left
  P(1, 2, Hair)
  for x in 4 .. 8:
    P(x, 2, tunic)
    P(x, 3, tunic)
  if parity == 1:
    P(5, 2, (250'u8, 250'u8, 250'u8))
  for x in 9 .. 10:
    P(x, 3, Pants)

proc weaponGlyph(id: ItemId): seq[uint8] =
  ## 5x5 held-item glyph.
  result = newSeq[uint8](5 * 5 * 4)
  template P(x, y: int, c: (uint8, uint8, uint8)) =
    result.put(5, x, y, c)
  case id
  of iSword:
    for i in 0 .. 3: P(i + 1, 3 - i, (222'u8, 222'u8, 235'u8))
    P(1, 4, (150'u8, 110'u8, 40'u8))
  of iSpear:
    for i in 0 .. 4: P(i, 4 - i, (180'u8, 140'u8, 90'u8))
    P(4, 0, (200'u8, 200'u8, 210'u8))
  of iBow:
    for y in 0 .. 4: P(1, y, (200'u8, 160'u8, 60'u8))
    P(2, 0, (200'u8, 160'u8, 60'u8)); P(2, 4, (200'u8, 160'u8, 60'u8))
    for y in 1 .. 3: P(3, y, (235'u8, 235'u8, 235'u8))
  of iKnives:
    P(2, 2, (190'u8, 190'u8, 205'u8)); P(3, 1, (190'u8, 190'u8, 205'u8))
    P(1, 3, (150'u8, 110'u8, 40'u8))
  of iBlowgun:
    for x in 0 .. 4: P(x, 2, (120'u8, 160'u8, 110'u8))
  of iNet:
    for x in [0, 2, 4]:
      for y in [0, 2, 4]: P(x, y, (150'u8, 150'u8, 110'u8))
  else:
    discard

# ---------------------------------------------------------------- misc art

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
        result.put(size, x, y, (r, g, b), uint8(255 - min(220, d2 * 220 div (c * c))))

proc plasmaPixels(phase: int, crit: bool): seq[uint8] =
  ## Swirling plasma wall: teal (stages 1-4) or crimson (endgame).
  result = newSeq[uint8](TileSize * TileSize * 4)
  let hotC = (if crit: PlasmaCrit else: PlasmaTeal)
  let coldC = shade(hotC, -110)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let swirl = (x * 2 + y + phase * 2) mod 5
      if swirl == 0:
        result.put(TileSize, x, y, (255'u8, 255'u8, 255'u8), 210)
      elif swirl < 3:
        result.put(TileSize, x, y, hotC, 190)
      else:
        result.put(TileSize, x, y, coldC, 150)

proc floodPixels(phase: int): seq[uint8] =
  ## Toxic hyper-reflective fluid (#39FF14).
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let crest = (x + y * 2 + phase * 3) mod 6 == 0
      result.put(TileSize, x, y,
        (if crest: (200'u8, 255'u8, 180'u8) else: ToxicFlood),
        (if crest: 220'u8 else: 150'u8))

proc stormPixels(phase: int): seq[uint8] =
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if (x + y + phase) mod 2 == 0:
        result.put(TileSize, x, y, (255'u8, 90'u8, 30'u8), 120)

proc podCratePixels(): seq[uint8] =
  result = newSeq[uint8](TileSize * TileSize * 4)
  let wood = (150'u8, 105'u8, 55'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let edge = x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1
      result.put(TileSize, x, y, (if edge: shade(wood, -40) else: wood))
  for x in 0 ..< TileSize:
    result.put(TileSize, x, TileSize div 2, (220'u8, 40'u8, 40'u8))

proc podChutePixels(): seq[uint8] =
  ## 10x12: canopy + lines + crate.
  result = newSeq[uint8](10 * 12 * 4)
  template P(x, y: int, c: (uint8, uint8, uint8), a: uint8 = 255) =
    result.put(10, x, y, c, a)
  for x in 1 .. 8:
    P(x, 1, (235'u8, 235'u8, 235'u8))
  for x in 0 .. 9:
    P(x, 2, (215'u8, 215'u8, 220'u8))
  for x in [0, 3, 6, 9]:
    P(x, 3, (150'u8, 150'u8, 155'u8), 200)
  P(2, 4, (120'u8, 120'u8, 125'u8), 180); P(7, 4, (120'u8, 120'u8, 125'u8), 180)
  P(3, 5, (120'u8, 120'u8, 125'u8), 180); P(6, 5, (120'u8, 120'u8, 125'u8), 180)
  let wood = (150'u8, 105'u8, 55'u8)
  for y in 6 .. 10:
    for x in 3 .. 6:
      P(x, y, (if y == 6 or y == 10 or x == 3 or x == 6: shade(wood, -40) else: wood))
  P(4, 8, (220'u8, 40'u8, 40'u8)); P(5, 8, (220'u8, 40'u8, 40'u8))

proc bushPixels(berries: int): seq[uint8] =
  result = newSeq[uint8](TileSize * TileSize * 4)
  let leaf = (46'u8, 108'u8, 50'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let dx = x * 2 + 1 - TileSize
      let dy = y * 2 + 1 - TileSize
      if dx * dx + dy * dy <= (TileSize - 1) * (TileSize - 1):
        result.put(TileSize, x, y,
          (if (x + y) mod 3 == 0: shade(leaf, 16) else: leaf))
  const spots = [(1, 2), (4, 1), (3, 4)]
  for i in 0 ..< min(berries, 3):
    result.put(TileSize, spots[i][0], spots[i][1], (215'u8, 45'u8, 60'u8))

proc glassBodyPixels(): seq[uint8] =
  ## Camo: refractive glass silhouette — faint outline, near-transparent fill.
  result = newSeq[uint8](BodyW * BodyH * 4)
  for y in 0 ..< BodyH:
    for x in 1 .. 6:
      let isHead = y >= 1 and y <= 3 and x >= 2 and x <= 5
      let isBody = y >= 4 and y <= 11 and x >= 2 and x <= 5
      if isHead or isBody:
        let edge = x == 2 or x == 5 or y == 1 or y == 11
        result.put(BodyW, x, y, (200'u8, 235'u8, 255'u8),
                   (if edge: 90'u8 else: 34'u8))

proc netMeshPixels(): seq[uint8] =
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if (x + y) mod 2 == 0 and (x == 0 or y == 0 or x == TileSize - 1 or
                                  y == TileSize - 1 or x == y):
        result.put(TileSize, x, y, (57'u8, 255'u8, 160'u8), 200)

proc poisonHaloPixels(phase: int): seq[uint8] =
  result = newSeq[uint8](10 * 10 * 4)
  for y in 0 ..< 10:
    for x in 0 ..< 10:
      let dx = x * 2 + 1 - 10
      let dy = y * 2 + 1 - 10
      let d2 = dx * dx + dy * dy
      if d2 > 36 and d2 <= 81 and (x + y + phase) mod 2 == 0:
        result.put(10, x, y, ToxicFlood, 120)

proc voidBeamPixels(): seq[uint8] =
  ## Vertical dark energy beam (death marker).
  result = newSeq[uint8](6 * 48 * 4)
  for y in 0 ..< 48:
    for x in 0 ..< 6:
      let a = uint8(200 - (y * 3))
      if x in [0, 5]:
        result.put(6, x, y, (110'u8, 30'u8, 140'u8), a div 2)
      else:
        result.put(6, x, y, (8'u8, 4'u8, 12'u8), a)

proc goldBeamPixels(): seq[uint8] =
  ## Holographic gold drop cylinder.
  result = newSeq[uint8](8 * 54 * 4)
  for y in 0 ..< 54:
    for x in 0 ..< 8:
      if x in [0, 7]:
        result.put(8, x, y, GoldTone, 170)
      elif (y + x) mod 6 == 0:
        result.put(8, x, y, shade(GoldTone, 40), 90)

proc glitchPixels(): seq[uint8] =
  ## Camo-reveal digital artifact burst.
  result = newSeq[uint8](BodyW * BodyH * 4)
  for y in 0 ..< BodyH:
    for x in 0 ..< BodyW:
      let n = tileHash(x * 3 + 1, y * 5 + 2)
      if n mod 3 == 0:
        result.put(BodyW, x, y,
          (if n mod 2 == 0: (255'u8, 0'u8, 200'u8) else: (255'u8, 255'u8, 255'u8)),
          220)

proc mouthLightPixels(phase: int): seq[uint8] =
  ## Volumetric golden light pooling in the Fortress mouths.
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if (x + y + phase) mod 3 != 0:
        result.put(TileSize, x, y, shade(GoldTone, 30), 90)

proc trailPixels(id: ItemId): seq[uint8] =
  ## Fading combat vector trail: white kinetic / green vapor / silver blur.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let c =
    case id
    of iArrows: (255'u8, 255'u8, 255'u8)
    of iDarts: ToxicFlood
    else: (200'u8, 200'u8, 215'u8)
  for x in 0 ..< TileSize:
    result.put(TileSize, x, TileSize div 2, c, 110)
    if id == iDarts:
      result.put(TileSize, x, TileSize div 2 + 1, c, 60)

proc itemColor(id: ItemId): (uint8, uint8, uint8) =
  case id
  of iSword: (220, 220, 235)
  of iSpear: (180, 140, 90)
  of iBow: (200, 160, 60)
  of iKnives: (170, 170, 190)
  of iBlowgun: (120, 160, 110)
  of iNet: (140, 140, 100)
  of iFirstAid: (240, 80, 80)
  of iRations: (200, 170, 110)
  of iBackpack: (150, 110, 60)
  of iCamo: (90, 120, 70)
  of iArrows: (210, 190, 120)
  of iDarts: (140, 200, 140)
  of iNone: (255, 0, 255)

proc itemPixels(id: ItemId): seq[uint8] =
  ## ground chip: outlined diamond in item color.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let c = itemColor(id)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let d = abs(x * 2 + 1 - TileSize) + abs(y * 2 + 1 - TileSize)
      if d <= TileSize - 1:
        result.put(TileSize, x, y,
          (if d >= TileSize - 2: shade(c, -60) else: c))
  result.put(TileSize, 2, 2, (255'u8, 255'u8, 255'u8))

proc projPixels(id: ItemId): seq[uint8] =
  result = newSeq[uint8](4 * 4 * 4)
  let c = itemColor(id)
  for y in 1 .. 2:
    for x in 0 .. 3:
      result.put(4, x, y, c)

proc hpBandPixels(band: int): seq[uint8] =
  ## 10x3 semaphore bar over each agent: color AND fill length encode the
  ## wire's hp_band (healthy/hurt/critical) — no green anywhere.
  result = newSeq[uint8](10 * 3 * 4)
  for y in 0 ..< 3:
    for x in 0 ..< 10:
      result.put(10, x, y, (10'u8, 13'u8, 17'u8), 210)
  let (fill, c) =
    case band
    of 0: (10, (165'u8, 227'u8, 238'u8))   # healthy: phosphor
    of 1: (6, (255'u8, 180'u8, 84'u8))     # hurt: amber
    else: (3, (255'u8, 74'u8, 54'u8))      # critical: klaxon
  for y in 0 ..< 3:
    for x in 0 ..< fill:
      result.put(10, x, y, c)

proc ringGhostPixels(): seq[uint8] =
  ## Faint bone outline tile; every-other tile placement dashes the circle.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let bone = (233'u8, 228'u8, 216'u8)
  for i in 0 ..< TileSize:
    result.put(TileSize, i, 0, bone, 130)
    result.put(TileSize, i, TileSize - 1, bone, 130)
    result.put(TileSize, 0, i, bone, 130)
    result.put(TileSize, TileSize - 1, i, bone, 130)

# --- 3x5 pixel font ---
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
  'I': 0b111_010_010_010_111, 'J': 0b001_001_001_101_010,
  'K': 0b101_110_100_110_101,
  'L': 0b100_100_100_100_111, 'M': 0b101_111_111_101_101,
  'N': 0b101_111_111_111_101, 'O': 0b010_101_101_101_010,
  'P': 0b110_101_110_100_100, 'Q': 0b111_101_101_111_001,
  'R': 0b110_101_110_110_101,
  'S': 0b011_100_010_001_110, 'T': 0b111_010_010_010_010,
  'U': 0b101_101_101_101_111, 'V': 0b101_101_101_101_010,
  'W': 0b101_101_111_111_101, 'X': 0b101_101_010_101_101,
  'Y': 0b101_101_010_010_010, 'Z': 0b111_001_010_100_111,
  ':': 0b000_010_000_010_000, '-': 0b000_000_111_000_000,
  '>': 0b100_010_001_010_100, '.': 0b000_000_000_000_010,
  ' ': 0}.toTable

proc textPixels(text: string, r, g, b: uint8): (int, int, seq[uint8]) =
  let w = 2 + text.len * 4
  let h = 7
  var px = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      px.put(w, x, y, (12'u8, 14'u8, 10'u8), 220)
  for i, ch in text:
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    let bits = Glyphs.getOrDefault(up, 0)
    for gy in 0 ..< 5:
      for gx in 0 ..< 3:
        if ((bits shr ((4 - gy) * 3 + (2 - gx))) and 1) == 1:
          px.put(w, 1 + i * 4 + gx, 1 + gy, (r, g, b))
  (w, h, px)

# ---------------------------------------------------------------- packets

proc mmss(secs: int): string =
  $(secs div 60) & ":" & (if secs mod 60 < 10: "0" else: "") & $(secs mod 60)

proc effectiveSafeRadius(s: Sim): int =
  ## Exterior wash applies only once the zone deals damage.
  if s.zoneDamagePerS() > 0: s.zoneRadius() else: ArenaSize

proc spriteDefs(s: Sim): seq[uint8] =
  result.addSprite(SpBackground, WorldPx, WorldPx,
                   backgroundPixels(s.arena, s.effectiveSafeRadius()), "arena")
  for slot in 0 .. 15:
    for facing in 0 .. 3:
      for frame in 0 .. 1:
        result.addSprite(SpBodyBase + slot * 10 + facing * 2 + frame,
          BodyW, BodyH, bodyPixels(slot div 2, slot mod 2, facing, frame),
          "body" & $slot)
    result.addSprite(SpCorpseBase + slot, 12, 6,
      corpsePixels(slot div 2, slot mod 2), "corpse" & $slot)
  for id in [iSword, iSpear, iBow, iKnives, iBlowgun, iNet]:
    result.addSprite(SpWeaponBase + ord(id), 5, 5, weaponGlyph(id), "held_" & $id)
  result.addSprite(SpFwBlack, 18, 18, burstPixels(18, 25, 25, 30), "fw_black")
  result.addSprite(SpFwGold, 18, 18, burstPixels(18, 250, 210, 80), "fw_gold")
  result.addSprite(SpMineFlash, 12, 12, burstPixels(12, 255, 120, 40), "mine")
  result.addSprite(SpZoneFireA, TileSize, TileSize, plasmaPixels(0, false), "plasmaA")
  result.addSprite(SpZoneFireB, TileSize, TileSize, plasmaPixels(1, false), "plasmaB")
  result.addSprite(SpPlasmaCritA, TileSize, TileSize, plasmaPixels(0, true), "plasmaCritA")
  result.addSprite(SpPlasmaCritB, TileSize, TileSize, plasmaPixels(1, true), "plasmaCritB")
  result.addSprite(SpGlassBody, BodyW, BodyH, glassBodyPixels(), "camo_glass")
  result.addSprite(SpNetMesh, TileSize, TileSize, netMeshPixels(), "net_mesh")
  result.addSprite(SpPoisonHaloA, 10, 10, poisonHaloPixels(0), "haloA")
  result.addSprite(SpPoisonHaloB, 10, 10, poisonHaloPixels(1), "haloB")
  result.addSprite(SpVoidBeam, 6, 48, voidBeamPixels(), "void_beam")
  result.addSprite(SpGoldBeam, 8, 54, goldBeamPixels(), "gold_beam")
  result.addSprite(SpGlitch, BodyW, BodyH, glitchPixels(), "glitch")
  result.addSprite(SpMouthA, TileSize, TileSize, mouthLightPixels(0), "mouthA")
  result.addSprite(SpMouthB, TileSize, TileSize, mouthLightPixels(1), "mouthB")
  for id in [iArrows, iDarts, iKnives]:
    result.addSprite(SpTrailBase + ord(id), TileSize, TileSize, trailPixels(id), "trail_" & $id)
  result.addSprite(SpFirestormA, TileSize, TileSize, stormPixels(0), "stormA")
  result.addSprite(SpFirestormB, TileSize, TileSize, stormPixels(1), "stormB")
  result.addSprite(SpFloodA, TileSize, TileSize, floodPixels(0), "floodA")
  result.addSprite(SpFloodB, TileSize, TileSize, floodPixels(1), "floodB")
  result.addSprite(SpPodCrate, TileSize, TileSize, podCratePixels(), "pod")
  result.addSprite(SpPodChute, 10, 12, podChutePixels(), "chute")
  for n in 0 .. 3:
    result.addSprite(SpBushBase + n, TileSize, TileSize, bushPixels(n), "bush" & $n)
  for id in ItemId:
    if id != iNone:
      result.addSprite(SpItemBase + ord(id), TileSize, TileSize,
                       itemPixels(id), "item_" & $id)
  for id in [iArrows, iDarts, iKnives, iNet]:
    result.addSprite(SpProjBase + ord(id), 4, 4, projPixels(id), "proj_" & $id)
  for slot in 0 .. 15:
    let (w, h, px) = textPixels("P" & $slot, 205, 214, 220)
    result.addSprite(SpSlotLabelBase + slot, w, h, px, "tag" & $slot)
  for band in 0 .. 2:
    result.addSprite(SpHpBandBase + band, 10, 3, hpBandPixels(band), "hp" & $band)
  result.addSprite(SpRingGhost, TileSize, TileSize, ringGhostPixels(), "ring_ghost")

proc bodySprite(r: Renderer, s: Sim, slot: int): int =
  let moving = s.tick - r.lastMoveTick[slot] < 12
  let frame = (if moving: (s.tick div 6) mod 2 else: 0)
  SpBodyBase + slot * 10 + r.facing[slot] * 2 + frame

proc camoHidden(s: Sim, slot: int): bool =
  s.agents[slot].body == iCamo and s.tick >= s.agents[slot].camoRevealedUntil

proc drawAgent(r: Renderer, packet: var seq[uint8], s: Sim, slot: int) =
  let p = s.agents[slot].pos
  # camo agents render as refractive glass on the spectator view (§21.3)
  let sprite = (if s.camoHidden(slot): SpGlassBody else: r.bodySprite(s, slot))
  packet.addObject(ObAgentBase + slot, p.x * TileSize - 1,
                   p.y * TileSize - (BodyH - TileSize), 10, LayerMap, sprite)
  let hand = s.agents[slot].hand
  if hand != iNone and not s.camoHidden(slot) and
     def(hand).kind in {ikMelee, ikRanged, ikThrown}:
    let dx = (if r.facing[slot] == 2: TileSize - 1
              elif r.facing[slot] == 3: -4 else: TileSize - 2)
    packet.addObject(ObWeaponBase + slot, p.x * TileSize - 1 + dx,
                     p.y * TileSize - 3, 11, LayerMap, SpWeaponBase + ord(hand))
  # identity tag + hp semaphore (Tier 1): fights must be readable on air
  packet.addObject(ObSlotLabelBase + slot, p.x * TileSize - 3,
                   p.y * TileSize + TileSize + 1, 12, LayerMap,
                   SpSlotLabelBase + slot)
  let band = (if s.agents[slot].hpCenti > 6600: 0
              elif s.agents[slot].hpCenti >= 3300: 1 else: 2)
  packet.addObject(ObHpBandBase + slot, p.x * TileSize - 2,
                   p.y * TileSize - (BodyH - TileSize) - 4, 12, LayerMap,
                   SpHpBandBase + band)

proc spawnEffect(r: var Renderer, packet: var seq[uint8], s: Sim,
                 spriteId, cx, cy, size, ttl: int) =
  # ids must stay below ObBushBase (20000) — effects rotating past that
  # range would clobber pooled world objects mid-broadcast
  let objId = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
  inc r.nextEffect
  packet.addObject(objId, cx - size div 2, cy - size div 2, 20, LayerMap, spriteId)
  r.effects.add(Effect(objId: objId, dieTick: s.tick + ttl))

proc updatePacket*(r: var Renderer, s: Sim): seq[uint8] =
  # facing/anim bookkeeping
  for slot in 0 .. 15:
    let a = s.agents[slot]
    if a.alive:
      if not (a.pos == r.lastPos[slot]):
        let dx = a.pos.x - r.lastPos[slot].x
        let dy = a.pos.y - r.lastPos[slot].y
        r.facing[slot] =
          (if abs(dx) >= abs(dy): (if dx > 0: 2 else: 3)
           else: (if dy > 0: 0 else: 1))
        r.lastMoveTick[slot] = s.tick
        r.lastPos[slot] = a.pos
      r.drawAgent(result, s, slot)
      r.weaponDrawn[slot] = s.agents[slot].hand != iNone and not s.camoHidden(slot)
      # camo reveal glitch: hidden last frame, visible now (§21.3)
      let hiddenNow = s.camoHidden(slot)
      if r.wasCamoHidden[slot] and not hiddenNow:
        r.spawnEffect(result, s, SpGlitch,
          a.pos.x * TileSize + 3, a.pos.y * TileSize - 2, 8, 6)
      r.wasCamoHidden[slot] = hiddenNow
      # poison halo pulse
      let poisoned = a.poisonUntil > s.tick
      if poisoned:
        result.addObject(ObHaloBase + slot, a.pos.x * TileSize - 2,
          a.pos.y * TileSize - 2, 9, LayerMap,
          (if (s.tick div 6) mod 2 == 0: SpPoisonHaloA else: SpPoisonHaloB))
        r.haloOn[slot] = true
      elif r.haloOn[slot]:
        result.addDeleteObject(ObHaloBase + slot)
        r.haloOn[slot] = false
      # net energy mesh at the base
      let netted = a.nettedUntil > s.tick
      if netted:
        result.addObject(ObMeshBase + slot, a.pos.x * TileSize,
          a.pos.y * TileSize, 12, LayerMap, SpNetMesh)
        r.meshOn[slot] = true
      elif r.meshOn[slot]:
        result.addDeleteObject(ObMeshBase + slot)
        r.meshOn[slot] = false
    elif not r.deadDrawn[slot]:
      result.addDeleteObject(ObAgentBase + slot)
      result.addDeleteObject(ObSlotLabelBase + slot)
      result.addDeleteObject(ObHpBandBase + slot)
      if r.weaponDrawn[slot]:
        result.addDeleteObject(ObWeaponBase + slot)
      if r.haloOn[slot]:
        result.addDeleteObject(ObHaloBase + slot)
        r.haloOn[slot] = false
      if r.meshOn[slot]:
        result.addDeleteObject(ObMeshBase + slot)
        r.meshOn[slot] = false
      # corpse + vertical void beam (§21.3 death broadcast)
      r.spawnEffect(result, s, SpCorpseBase + slot,
        a.pos.x * TileSize + TileSize div 2, a.pos.y * TileSize + TileSize div 2,
        12, 96)
      r.spawnEffect(result, s, SpVoidBeam,
        a.pos.x * TileSize + TileSize div 2, a.pos.y * TileSize - 20, 6, 36)
      r.deadDrawn[slot] = true
    elif r.weaponDrawn[slot]:
      result.addDeleteObject(ObWeaponBase + slot)
      r.weaponDrawn[slot] = false
  # bushes (objects: berries shrink as charges deplete)
  var bushIdx = 0
  for b in s.bushes:
    if bushIdx >= BushPool: break
    result.addObject(ObBushBase + bushIdx, b.pos.x * TileSize,
                     b.pos.y * TileSize, 6, LayerMap,
                     SpBushBase + max(0, min(3, b.charges)))
    inc bushIdx
  for stale in bushIdx ..< r.bushesDrawn:
    result.addDeleteObject(ObBushBase + stale)
  r.bushesDrawn = bushIdx
  # ground items
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
  # projectiles + kinetic vector trails (§21.3)
  var projIdx = 0
  for p in s.projectiles:
    if projIdx >= ProjPool: break
    result.addObject(ObProjBase + projIdx, p.pos.x * TileSize + 1,
                     p.pos.y * TileSize + 1, 18, LayerMap, SpProjBase + ord(p.kind))
    if p.kind in [iArrows, iDarts, iKnives]:
      r.spawnEffect(result, s, SpTrailBase + ord(p.kind),
        p.pos.x * TileSize + TileSize div 2, p.pos.y * TileSize + TileSize div 2,
        TileSize, 3)
    inc projIdx
  for stale in projIdx ..< r.projsDrawn:
    result.addDeleteObject(ObProjBase + stale)
  r.projsDrawn = projIdx
  # hazard regions (animated)
  var regIdx = 0
  let phase = (s.tick div 6) mod 2
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
            result.addObject(ObRegionBase + regIdx, tx * TileSize, ty * TileSize,
              14, LayerMap, (if phase == 0: SpFirestormA else: SpFirestormB))
            inc regIdx
    of ecFlood:
      for ty in max(1, ev.rect[1]) .. min(ArenaSize - 2, ev.rect[3]):
        for tx in max(1, ev.rect[0]) .. min(ArenaSize - 2, ev.rect[2]):
          if regIdx >= RegionPool: break
          result.addObject(ObRegionBase + regIdx, tx * TileSize, ty * TileSize,
            14, LayerMap, (if phase == 0: SpFloodA else: SpFloodB))
          inc regIdx
  for stale in regIdx ..< r.regionDrawn:
    result.addDeleteObject(ObRegionBase + stale)
  r.regionDrawn = regIdx
  # sponsor pods: gold drop beam + cargo typography while inbound (§21.3),
  # parachute descending, crate once landed
  var podIdx = 0
  var beamIdx = 0
  for pod in s.pods:
    if podIdx >= PodPool: break
    if pod.landed:
      result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                       pod.landing.y * TileSize, 12, LayerMap, SpPodCrate)
    else:
      let total = max(1, pod.landsTick - pod.spawnTick)
      let left = max(0, pod.landsTick - s.tick)
      let height = 4 + (left * 30) div total
      result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize - 2,
                       pod.landing.y * TileSize - height, 19, LayerMap, SpPodChute)
      if beamIdx < 8:
        # beam + label objects persist; refresh sprite on new beam or 1x/s
        if beamIdx >= r.podBeamsDrawn or s.tick mod 24 == 0:
          result.addObject(ObPodBeamBase + beamIdx, pod.landing.x * TileSize - 1,
                           pod.landing.y * TileSize - 54, 13, LayerMap, SpGoldBeam)
          # floating cargo typography above the beam
          let (_, gift) = giftLookup(pod.itemId)
          let spId = SpCargoBase + (r.labelFlip mod 8)
          inc r.labelFlip
          var label = "AIRDROP: "
          for ch in pod.itemId:
            label.add(if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
          label.add(" " & $gift.price & " SC")
          let (w, h, px) = textPixels(label, GoldTone[0], GoldTone[1], GoldTone[2])
          result.addSprite(spId, w, h, px, "cargo")
          result.addObject(ObPodLabelBase + beamIdx,
                           pod.landing.x * TileSize - w div 2 + 3,
                           pod.landing.y * TileSize - 62, 21, LayerMap, spId)
        inc beamIdx
    inc podIdx
  for stale in podIdx ..< r.podsDrawn:
    result.addDeleteObject(ObPodBase + stale)
  r.podsDrawn = podIdx
  for stale in beamIdx ..< r.podBeamsDrawn:
    result.addDeleteObject(ObPodBeamBase + stale)
    result.addDeleteObject(ObPodLabelBase + stale)
  r.podBeamsDrawn = beamIdx
  # events -> bursts
  for e in s.events:
    let cx = e.pos.x * TileSize + TileSize div 2
    let cy = e.pos.y * TileSize + TileSize div 2
    case e.kind
    of evMineExplosion: r.spawnEffect(result, s, SpMineFlash, cx, cy, 12, 12)
    of evDeathFireworks:
      r.spawnEffect(result, s, SpFwBlack, cx, cy, 18, 36)
      if e.slot >= 0:
        # kill feed (Tier 1): credit = last damager, same rule as scoring
        let k = s.agents[e.slot].lastDamager
        let line = (if k >= 0 and k != e.slot: "P" & $k & " > P" & $e.slot
                    else: "P" & $e.slot & " DOWN")
        r.killFeed.insert(line, 0)
        if r.killFeed.len > 3:
          r.killFeed.setLen(3)
        r.killDirty = true
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
  # zone plasma ring (flicker); crimson crit arc once damage hits stage 5 (§21.3)
  var ringIdx = 0
  let zr = s.zoneRadius()
  if zr < ArenaSize and s.phase != phCountdown:
    let crit = s.zoneDamagePerS() >= 8
    let c = ArenaSize div 2
    for ty in 0 ..< ArenaSize:
      for tx in 0 ..< ArenaSize:
        if ringIdx >= ZoneRingPool: break
        let dx = tx - c
        let dy = ty - c
        let d2 = dx * dx + dy * dy
        if d2 > zr * zr and d2 <= (zr + 1) * (zr + 1):
          let flip = (phase + tx + ty) mod 2 == 0
          let sp =
            (if crit: (if flip: SpPlasmaCritA else: SpPlasmaCritB)
             else: (if flip: SpZoneFireA else: SpZoneFireB))
          result.addObject(ObZoneRingBase + ringIdx, tx * TileSize, ty * TileSize,
            15, LayerMap, sp)
          inc ringIdx
  for stale in ringIdx ..< r.ringDrawn:
    result.addDeleteObject(ObZoneRingBase + stale)
  r.ringDrawn = ringIdx
  # dashed next-radius preview once a stage's warn window opens (Tier 1)
  var ghostIdx = 0
  for st in s.cfg.zone:
    if s.tick < st.doneT:
      if s.tick >= st.warnT and st.rEnd < zr:
        let c = ArenaSize div 2
        for ty in 0 ..< ArenaSize:
          for tx in 0 ..< ArenaSize:
            if ghostIdx >= NextRingPool: break
            if (tx + ty) mod 2 == 0:
              let dx = tx - c
              let dy = ty - c
              let d2 = dx * dx + dy * dy
              if d2 > st.rEnd * st.rEnd and d2 <= (st.rEnd + 1) * (st.rEnd + 1):
                result.addObject(ObNextRingBase + ghostIdx, tx * TileSize,
                  ty * TileSize, 15, LayerMap, SpRingGhost)
                inc ghostIdx
      break
  for stale in ghostIdx ..< r.nextRingDrawn:
    result.addDeleteObject(ObNextRingBase + stale)
  r.nextRingDrawn = ghostIdx
  # exterior wash tracks the shrinking ring: re-bake the background whenever
  # the integer safe radius changes (a handful of uploads per match)
  let bgR = s.effectiveSafeRadius()
  if bgR != r.lastBgRadius:
    r.lastBgRadius = bgR
    result.addSprite(SpBackground, WorldPx, WorldPx,
                     backgroundPixels(s.arena, bgR), "arena")
    result.addObject(ObBackground, 0, 0, 0, LayerMap, SpBackground)
  # Fortress mouth gold light (§21.3): warm pulse in each wall gap
  let mouthNow = (s.tick div 12) mod 2
  if not r.mouthsDrawn or mouthNow != r.mouthPhase:
    const MouthPos = [(23, 20), (24, 20), (23, 28), (24, 28),
                      (20, 23), (20, 24), (28, 23), (28, 24)]
    for i, (mx, my) in MouthPos:
      result.addObject(ObMouthBase + i, mx * TileSize, my * TileSize, 2,
        LayerMap, (if (mouthNow + i) mod 2 == 0: SpMouthA else: SpMouthB))
    r.mouthsDrawn = true
    r.mouthPhase = mouthNow
  # HUD
  var deadCount = 0
  for a in s.agents:
    if not a.alive: inc deadCount
  let zrHud = s.zoneRadius()
  let secs = s.tick div 24
  # ring clock (Tier 1): the schedule is public — broadcast the countdown
  var ringTxt = "RING " & $zrHud
  for st in s.cfg.zone:
    if s.tick < st.doneT:
      if st.rEnd < zrHud:
        if s.tick >= st.shrinkT:
          ringTxt.add(">" & $st.rEnd & " NOW")
        else:
          ringTxt.add(">" & $st.rEnd & " IN " & mmss((st.shrinkT - s.tick) div 24))
      break
  let hud1 = "ALIVE " & $(16 - deadCount) & "  " & ringTxt & "  T " & mmss(secs)
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
  # kill feed under the status line (Tier 1)
  if r.killDirty:
    r.killDirty = false
    for i in 0 ..< r.killFeed.len:
      let spId = SpKillBase + i * 2 + (r.killFlip mod 2)
      let (w, h, px) = textPixels(r.killFeed[i], 233, 228, 216)
      result.addSprite(spId, w, h, px, "kill" & $i)
      result.addObject(ObKillLineBase + i, 2, 13 + i * 7, 0, LayerHudTL, spId)
    inc r.killFlip
    for stale in r.killFeed.len ..< r.killLinesDrawn:
      result.addDeleteObject(ObKillLineBase + stale)
    r.killLinesDrawn = r.killFeed.len
  # banners
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

proc initPacket*(r: Renderer, s: Sim): seq[uint8] =
  ## Complete current scene for a fresh viewer (or replay-loop restart).
  result.addClearObjects()
  result.addLayer(LayerMap, 0x00, 0x01)
  result.addViewport(LayerMap, WorldPx, WorldPx)
  result.addLayer(LayerHudTL, 0x01, 0x02)
  result.addViewport(LayerHudTL, 208, 36)
  result.addLayer(LayerHudBL, 0x04, 0x02)
  result.addViewport(LayerHudBL, 280, 12)
  result.addLayer(LayerBanner, 0x05, 0x02)
  result.addViewport(LayerBanner, 120, 16)
  result.add(spriteDefs(s))
  result.addObject(ObBackground, 0, 0, 0, LayerMap, SpBackground)
  const MouthPos = [(23, 20), (24, 20), (23, 28), (24, 28),
                    (20, 23), (20, 24), (28, 23), (28, 24)]
  for i, (mx, my) in MouthPos:
    result.addObject(ObMouthBase + i, mx * TileSize, my * TileSize, 2,
      LayerMap, (if i mod 2 == 0: SpMouthA else: SpMouthB))
  for slot in 0 .. 15:
    if s.agents[slot].alive:
      r.drawAgent(result, s, slot)

proc resetForLoop*(r: var Renderer) =
  r.effects = @[]
  for i in 0 .. 15:
    r.deadDrawn[i] = false
    r.weaponDrawn[i] = false
    r.facing[i] = 0
    r.lastPos[i] = Pos(x: -1, y: -1)
    r.lastMoveTick[i] = -100
    r.haloOn[i] = false
    r.meshOn[i] = false
    r.wasCamoHidden[i] = false
  r.mouthsDrawn = false
  r.podBeamsDrawn = 0
  r.ringDrawn = 0
  r.nextRingDrawn = 0
  r.killFeed = @[]
  r.killDirty = false
  r.killLinesDrawn = 0
  r.lastBgRadius = 0
  r.podsDrawn = 0
  r.itemsDrawn = 0
  r.projsDrawn = 0
  r.regionDrawn = 0
  r.bushesDrawn = 0
  r.lastHud1 = ""
  r.lastHud2 = ""
  r.bannerText = ""
