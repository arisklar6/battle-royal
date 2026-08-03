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
  SpChannelA = 850         # phosphor channel halo (heal/eat window)
  SpChannelB = 851
  SpRevealMark = 852       # red "camo blown" mark
  SpTraceLayer = 3         # full-arena phosphor persistence overlay
  SpSettleLine = 860       # full-width settlement rule (death sweep)
  SpLampRow = 861          # 16-lamp alive row
  SpReticle = 870          # amber drop-targeting reticle
  SpCratePartBase = 871    # 871..873: crate rastering in (print sequence)
  SpPingA = 874            # landed-crate contested ping
  SpPingB = 875
  SpHitFlash = 876         # 1-frame peak-white hit silhouette
  SpDmgBase = 880          # 880..895: rotating damage numerals
  SpPodCrateBase = 900     # 900 + ord(ItemId): contents-keyed crates
  SpPodLabelBase = 1000    # 1000 + pod index: persistent cargo labels

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
  ObChannelBase = 44500     # channel halo per slot
  ObRevealBase = 44600      # camo-reveal mark per slot
  ObPodPingBase = 44700     # contested-crate ping per pod index
  ObSlotLabelBase = 45000   # + slot: identity tag under each agent
  ObHpBandBase = 45100      # + slot: hp semaphore over each agent
  ObCorpseBase = 46000      # + slot: persistent corpse (lives to match end)
  ObKillLineBase = 50020    # + 0..2: kill-feed lines, newest first
  ObTraceLayer = 3          # phosphor persistence overlay (z above bg)
  ObLampRow = 50030         # alive lamps in the TL HUD

  LayerHudTL = 1
  LayerHudBL = 4
  LayerBanner = 5

  BodyW = 8
  BodyH = 12

  ## AFTERGLOW team wheel (VISUAL_REDESIGN §3.1): S/L-locked fills, only
  ## polychrome in the arena. F ice-white and E crimson retired (invisible /
  ## danger-red collision). Always paired with the slot glyph, never hue-alone.
  ## rose / cyan / gold / violet / wine / steel / copper / orchid
  TeamColors: array[8, (uint8, uint8, uint8)] = [
    (255'u8, 143'u8, 168'u8), (73'u8, 199'u8, 232'u8), (232'u8, 197'u8, 88'u8),
    (155'u8, 123'u8, 255'u8), (232'u8, 93'u8, 117'u8), (159'u8, 184'u8, 216'u8),
    (232'u8, 151'u8, 93'u8), (217'u8, 123'u8, 232'u8)]

  ## AFTERGLOW palette tokens (docs/VISUAL_REDESIGN.md §3.1).
  ## Semantic contracts: phosphor = live signal, amber = matter & economy,
  ## magenta = commanded geometry, klaxon = harm now. No green anywhere.
  BgDark = (12'u8, 17'u8, 22'u8)          # Faraday #0C1116 substrate
  EtchDim = (28'u8, 36'u8, 43'u8)         # Etch ramp low #1C242B
  Masonry = (54'u8, 68'u8, 79'u8)         # Etch #36444F structural ink
  Phosphor = (165'u8, 227'u8, 238'u8)     # #A5E3EE
  PhosphorPeak = (234'u8, 247'u8, 250'u8) # #EAF7FA
  RingMagenta = (255'u8, 79'u8, 163'u8)   # Directive Magenta #FF4FA3
  Klaxon = (255'u8, 74'u8, 54'u8)         # Klaxon Red #FF4A36
  GoldTone = (255'u8, 180'u8, 84'u8)      # Amber #FFB454
  Bone = (233'u8, 228'u8, 216'u8)         # settlement ink #E9E4D8


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
    channelOn: array[16, bool]
    revealOn: array[16, bool]
    podLabelText: seq[string] # per pod index, for sprite-rebuild detection
    trace: seq[uint32]        # packed RGBA per world px: live afterglow
    scars: seq[uint32]        # packed RGBA per world px: burn-in, permanent
    traceActive: bool
    traceDrawn: bool
    lastLampMask: int
    lastHp: array[16, int]    # centi-HP watermark for hit flashes
    dmgFlip: int

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

proc alphaAt(px: seq[uint8], w, x, y: int): int =
  if x < 0 or y < 0 or x >= w:
    return 0
  let i = (y * w + x) * 4 + 3
  if i >= px.len: 0 else: int(px[i])

proc addBacklight(px: var seq[uint8], w, h: int, c: (uint8, uint8, uint8),
                  a: uint8, dx = 0, dy = 0) =
  ## Writes a one-pixel halo into empty space around what is already
  ## drawn — CTF gets this from pixie.shadow() behind the weapon
  ## (spread 1.0, blur 0.6, warm amber); at 6px tiles a crisp single-pixel
  ## rim reads better than a blur and costs one pass. dx/dy offset turns
  ## the same helper into a contact shadow.
  let src = px
  for y in 0 ..< h:
    for x in 0 ..< w:
      if alphaAt(src, w, x, y) >= 40:
        continue                      # only fill empty space
      var touching = false
      for ny in -1 .. 1:
        for nx in -1 .. 1:
          if (nx != 0 or ny != 0) and
             alphaAt(src, w, x + nx - dx, y + ny - dy) >= 128:
            touching = true
      if touching:
        px.put(w, x, y, c, a)

# ---------------------------------------------------------------- tiles

# --- floor material: value noise + panel joints (from ctf build_floor) ---
# The plate used to be one flat tone plus a grid line, which read as graph
# paper. CTF bakes its floor as a material: broad mottling, fine grain,
# aggregate flecks, pinholes, and embossed panel joints spaced far wider
# than a tile. Same recipe here, generated per-pixel instead of sampled
# from a texture so no asset ships.
const
  PanelPeriodPx = 8 * TileSize        # joints every 8 tiles, not every tile
  FloorLo = -7                        # luminance envelope around Faraday
  FloorHi = 9

proc pixHash(x, y: int): int =
  ## Deterministic prime-mix hash in uint64 (wraps, never overflows).
  var h = uint64(x and 0xFFFF) * 73856093'u64 xor
          uint64(y and 0xFFFF) * 19349663'u64
  h = h xor (h shr 13)
  h = h * 0x85EBCA6B'u64
  h = h xor (h shr 16)
  int(h and 0xFF'u64)

proc noiseAt(x, y, cell: int): int =
  ## Value noise: bilinear blend of per-cell hashes, returns -128..127.
  let gx = x div cell
  let gy = y div cell
  let fx = x mod cell
  let fy = y mod cell
  let a = pixHash(gx, gy)
  let b = pixHash(gx + 1, gy)
  let c = pixHash(gx, gy + 1)
  let d = pixHash(gx + 1, gy + 1)
  let top = a * (cell - fx) + b * fx
  let bot = c * (cell - fx) + d * fx
  ((top * (cell - fy) + bot * fy) div (cell * cell)) - 128

proc plateAt(px: var seq[uint8], w, ox, oy, tx, ty: int) =
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let wx = ox + x
      let wy = oy + y
      # two octaves of mottling plus per-pixel grain
      var d = (noiseAt(wx, wy, 16) * 5) div 128 +
              (noiseAt(wx, wy, 4) * 3) div 128 +
              (pixHash(wx, wy) mod 3) - 1
      let g = pixHash(wx * 3 + 1, wy * 3 + 7)
      if g mod 211 == 0: d += 14        # aggregate fleck
      elif g mod 397 == 0: d -= 9       # pinhole
      # embossed panel joint: recessed line with a lit lip up-left of it
      let jx = wx mod PanelPeriodPx
      let jy = wy mod PanelPeriodPx
      if jx == 0 or jy == 0: d -= 10
      elif jx == 1 or jy == 1: d += 6
      elif x == 0 or y == 0: d -= 3     # faint per-tile etch grid
      px.put(w, wx, wy, shade(BgDark, max(FloorLo, min(FloorHi, d))))

# --- structural material: shading derived from the collision mask ---
# Ported technique (coworld-ctf map_art.nim rooftopColorAt): instead of a
# flat tile pattern, every structural pixel measures its distance to the
# nearest open pixel along 4 rays and shades by that distance — ground
# ink line, lit/shadowed parapet rim, then roof face. The art therefore
# matches the colliders exactly and reads as built volume rather than
# texture. Light comes from up-left throughout the renderer.
const
  StoneInk = (16'u8, 22'u8, 28'u8)     # contact line — never pure black
  WallBevelPx = 2                      # rim width; tiles are only 6px
  RoofSeamPeriod = 8

proc isStructure(a: Arena, tx, ty: int): bool =
  ## Off-map counts as solid so the border wall keeps a face, not a rim.
  if tx < 0 or ty < 0 or tx >= ArenaSize or ty >= ArenaSize:
    return true
  a.tiles[ty][tx] in {tkWall, tkFortressWall}

proc structureAtPx(a: Arena, wx, wy: int): bool =
  isStructure(a, wx div TileSize, wy div TileSize)

proc openDistDir(a: Arena, wx, wy, dx, dy, maxD: int): int =
  ## Steps to the nearest non-structural pixel in one direction.
  for d in 1 .. maxD:
    if not structureAtPx(a, wx + dx * d, wy + dy * d):
      return d
  maxD + 1

proc parapetColorAt(a: Arena, wx, wy: int,
                    base: (uint8, uint8, uint8)): (uint8, uint8, uint8) =
  const MaxD = WallBevelPx + 2
  let up = openDistDir(a, wx, wy, 0, -1, MaxD)
  let dn = openDistDir(a, wx, wy, 0, 1, MaxD)
  let lf = openDistDir(a, wx, wy, -1, 0, MaxD)
  let rt = openDistDir(a, wx, wy, 1, 0, MaxD)
  let edge = min(min(up, dn), min(lf, rt))
  if edge <= 1:
    StoneInk
  elif edge <= WallBevelPx:
    # rim: lit where the opening lies up-left, shadowed down-right
    if min(up, lf) <= min(dn, rt): shade(base, 40) else: shade(base, -26)
  elif (wx + wy) mod RoofSeamPeriod == 0:
    shade(base, -12)                   # roof seam
  else:
    base

proc wallAt(px: var seq[uint8], w, ox, oy: int, a: Arena,
            base: (uint8, uint8, uint8)) =
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      px.put(w, ox + x, oy + y, parapetColorAt(a, ox + x, oy + y, base))

proc rockAt(px: var seq[uint8], w, ox, oy: int) =
  ## Boulder under the same up-left key light as the walls.
  let base = (86'u8, 78'u8, 70'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let lit = x + y <= 2
      let dark = (TileSize - 1 - x) + (TileSize - 1 - y) <= 2
      let rim = x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1
      var c = base
      if lit: c = shade(base, 34)
      elif dark: c = shade(base, -30)
      elif rim: c = shade(base, -16)
      px.put(w, ox + x, oy + y, c)
  px.put(w, ox + TileSize - 1, oy + TileSize - 1, StoneInk)

proc pedestalAt(px: var seq[uint8], w, ox, oy: int) =
  let gold = (235'u8, 166'u8, 76'u8)      # amber family (matter)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let ring = x in [0, TileSize - 1] or y in [0, TileSize - 1]
      px.put(w, ox + x, oy + y, (if ring: shade(gold, -50) else: gold))
  px.put(w, ox + 2, oy + 2, shade(gold, 30))
  px.put(w, ox + 3, oy + 3, shade(gold, 30))

proc backgroundPixels(a: Arena, safeR: int, derez: int): seq[uint8] =
  ## safeR: tiles outside this center radius are reclaimed territory.
  ## derez escalates with the ring stage (VISUAL_REDESIGN §3.7 — the
  ## machine deallocating the world): 0 = red "off-air" wash,
  ## 1 = art decays to Etch wireframe, 2 = raw substrate + dropped-pixel
  ## dither. Pass safeR >= ArenaSize for an untouched board.
  result = newSeq[uint8](WorldPx * WorldPx * 4)
  let c = ArenaSize div 2
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      let ox = tx * TileSize
      let oy = ty * TileSize
      case a.tiles[ty][tx]
      of tkGround, tkBush:      # bushes are objects; plate beneath
        plateAt(result, WorldPx, ox, oy, tx, ty)
      of tkWall:
        wallAt(result, WorldPx, ox, oy, a, Masonry)
      of tkFortressWall:
        wallAt(result, WorldPx, ox, oy, a, shade(Masonry, 22))
      of tkRock:
        plateAt(result, WorldPx, ox, oy, tx, ty)
        rockAt(result, WorldPx, ox, oy)
      of tkPedestal:
        plateAt(result, WorldPx, ox, oy, tx, ty)
        pedestalAt(result, WorldPx, ox, oy)
      let dx = tx - c
      let dy = ty - c
      if dx * dx + dy * dy > safeR * safeR:
        if derez == 0:
          for y in 0 ..< TileSize:
            for x in 0 ..< TileSize:
              let i = ((oy + y) * WorldPx + ox + x) * 4
              result[i] = uint8(int(result[i]) * 3 div 5 + 26)
              result[i+1] = uint8(int(result[i+1]) * 3 div 5 + 4)
              result[i+2] = uint8(int(result[i+2]) * 3 div 5 + 8)
        else:
          let structural = a.tiles[ty][tx] in
            {tkWall, tkFortressWall, tkRock, tkPedestal}
          for y in 0 ..< TileSize:
            for x in 0 ..< TileSize:
              var col = BgDark
              if derez == 1:
                if x == 0 or y == 0:
                  col = EtchDim
                if structural and (x == 0 or y == 0 or x == TileSize - 1 or
                                   y == TileSize - 1):
                  col = Masonry
              else:
                if tileHash(tx * 3 + x, ty * 3 + y) mod 13 == 0:
                  col = EtchDim
              let i = ((oy + y) * WorldPx + ox + x) * 4
              result[i] = col[0]
              result[i+1] = col[1]
              result[i+2] = col[2]
              result[i+3] = 255

# ---------------------------------------------------------------- humanoids

proc bodyPixels(team, parity, facing, frame: int): seq[uint8] =
  ## AFTERGLOW carrier (VISUAL_REDESIGN §3.3): compact phosphor
  ## silhouette riding a team-hue diamond — the only polychrome in the
  ## arena. Drawn inside the legacy 8x12 frame so every offset in the
  ## pipeline stays valid. facing nudges the sensor pixels; frame is a
  ## 1px hover bob (the diamond is the ground mark and never lifts).
  result = newSeq[uint8](BodyW * BodyH * 4)
  let tunic = TeamColors[team]
  let lift = (if frame == 1: -1 else: 0)
  template P(x, y: int, c: (uint8, uint8, uint8), a: uint8 = 255) =
    result.put(BodyW, x, y + lift, c, a)
  # chassis rows 3..7, cols 1..6
  for x in 2 .. 5:
    P(x, 3, PhosphorPeak)
  for y in 4 .. 6:
    P(1, y, Phosphor)
    P(6, y, Phosphor)
    for x in 2 .. 5:
      P(x, y, Phosphor)
  for x in 2 .. 5:
    P(x, 7, shade(Phosphor, -70))
  # sensor pair, nudged toward the facing
  let sx = (if facing == 2: 1 elif facing == 3: -1 else: 0)
  if facing == 1:              # north: dorsal line, no sensors
    for x in 2 .. 5:
      P(x, 4, shade(Phosphor, -50))
  else:
    P(3 + sx, 5, BgDark)
    P(4 + sx, 5, BgDark)
  if parity == 1:
    P(2, 4, PhosphorPeak)      # teammate pip
  # contact shadow before the diamond: grounds the chassis so it does not
  # look pasted onto the floor (CTF bakes this into its soldier masters)
  result.addBacklight(BodyW, BodyH, StoneInk, 90, dx = 1, dy = 1)
  # team diamond rows 9..11 (ground mark, unaffected by the bob)
  result.put(BodyW, 3, 9, tunic)
  result.put(BodyW, 4, 9, tunic)
  for x in 2 .. 5:
    result.put(BodyW, x, 10, tunic)
  result.put(BodyW, 3, 11, tunic)
  result.put(BodyW, 4, 11, tunic)

proc corpsePixels(team, parity: int): seq[uint8] =
  ## 12x6 decommissioned carrier: shadow pool, toppled cold chassis,
  ## team-tinted diamond gone dark.
  result = newSeq[uint8](12 * 6 * 4)
  let tunic = shade(TeamColors[team], -50)
  template P(x, y: int, c: (uint8, uint8, uint8)) =
    result.put(12, x, y, c)
  for x in 1 .. 10:
    P(x, 5, (24'u8, 30'u8, 36'u8))                 # shadow pool
  for x in 3 .. 8:
    P(x, 2, EtchDim)
    P(x, 3, EtchDim)
  P(2, 2, EtchDim)
  P(9, 3, EtchDim)
  P(5, 1, tunic)                                    # cold diamond tip
  P(6, 1, tunic)
  if parity == 1:
    P(3, 2, (200'u8, 205'u8, 210'u8))

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
  ## Ray star with hash-dithered scatter (ctf technique): clean rays read
  ## as a diagram, dithered ones read as thrown particles. Density falls
  ## with radius, so the core stays solid and the tips break up.
  result = newSeq[uint8](size * size * 4)
  let c = size div 2
  for y in 0 ..< size:
    for x in 0 ..< size:
      let dx = x - c
      let dy = y - c
      let d2 = dx * dx + dy * dy
      if d2 > c * c:
        continue
      let onRay = dx == 0 or dy == 0 or dx == dy or dx == -dy
      let fade = 255 - min(220, d2 * 220 div (c * c))
      if onRay:
        result.put(size, x, y, (r, g, b), uint8(fade))
      elif pixHash(x * 5 + 3, y * 7 + 11) mod 100 < (fade div 6):
        # sparse embers between the rays, thinning outward
        result.put(size, x, y, (r, g, b), uint8(fade * 3 div 5))

proc plasmaPixels(phase: int, crit: bool): seq[uint8] =
  ## Swirling plasma wall: teal (stages 1-4) or crimson (endgame).
  result = newSeq[uint8](TileSize * TileSize * 4)
  let hotC = (if crit: Klaxon else: RingMagenta)
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
  ## Commanded-flood fluid. Hash dither breaks the crest lattice so the
  ## surface reads as moving liquid instead of a repeating hatch.
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let n = pixHash(x * 3 + phase * 29, y * 5 + phase * 17) mod 5
      let crest = (x + y * 2 + phase * 3 + n) mod 6 == 0
      result.put(TileSize, x, y,
        (if crest: (255'u8, 160'u8, 205'u8) else: RingMagenta),
        (if crest: 220'u8 else: uint8(132 + n * 6)))

proc stormPixels(phase: int): seq[uint8] =
  ## Firestorm: dithered density rather than a checkerboard, so overlapping
  ## tiles merge into one field instead of showing their tile seams.
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let n = pixHash(x * 7 + phase * 13, y * 11 + phase * 23) mod 100
      if n < 55:
        result.put(TileSize, x, y, (255'u8, 90'u8, 30'u8),
                   uint8(90 + (n mod 5) * 12))

proc podCratePixels(band: (uint8, uint8, uint8)): seq[uint8] =
  ## Crate keyed to contents: the strap carries the item color so a
  ## contested drop stays identified after touchdown.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let wood = (150'u8, 105'u8, 55'u8)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let edge = x == 0 or y == 0 or x == TileSize - 1 or y == TileSize - 1
      result.put(TileSize, x, y, (if edge: shade(wood, -40) else: wood))
  for x in 0 ..< TileSize:
    result.put(TileSize, x, TileSize div 2, band)
  result.put(TileSize, 1, 1, band)
  result.addBacklight(TileSize, TileSize, GoldTone, 80)

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
      let d2 = dx * dx + dy * dy
      let r2 = (TileSize - 1) * (TileSize - 1)
      # dithered rim: foliage frays instead of ending on a hard circle
      let n = pixHash(x * 13 + 5, y * 17 + 3) mod 100
      if d2 <= r2 - r2 div 3 or (d2 <= r2 and n < 62):
        result.put(TileSize, x, y,
          (if n mod 3 == 0: shade(leaf, 16) else: leaf))
  const spots = [(1, 2), (4, 1), (3, 4)]
  for i in 0 ..< min(berries, 3):
    result.put(TileSize, spots[i][0], spots[i][1], (215'u8, 45'u8, 60'u8))

proc glassBodyPixels(): seq[uint8] =
  ## Camo: refractive carrier silhouette — faint outline, near-clear fill.
  result = newSeq[uint8](BodyW * BodyH * 4)
  for y in 3 .. 7:
    for x in 1 .. 6:
      if (y >= 4 and y <= 6) or (x >= 2 and x <= 5):
        let edge = x == 1 or x == 6 or y == 3 or y == 7
        result.put(BodyW, x, y, (200'u8, 235'u8, 255'u8),
                   (if edge: 90'u8 else: 34'u8))

proc netMeshPixels(): seq[uint8] =
  ## Etch-bright restraint mesh — structure pinning a signal down.
  result = newSeq[uint8](TileSize * TileSize * 4)
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      if (x + y) mod 2 == 0 and (x == 0 or y == 0 or x == TileSize - 1 or
                                  y == TileSize - 1 or x == y):
        result.put(TileSize, x, y, (150'u8, 170'u8, 185'u8), 210)

proc poisonHaloPixels(phase: int): seq[uint8] =
  result = newSeq[uint8](10 * 10 * 4)
  for y in 0 ..< 10:
    for x in 0 ..< 10:
      let dx = x * 2 + 1 - 10
      let dy = y * 2 + 1 - 10
      let d2 = dx * dx + dy * dy
      # poison is airborne, not a signal ring: dither it into mist
      if d2 > 36 and d2 <= 81 and
         pixHash(x * 9 + phase * 31, y * 7 + phase * 19) mod 100 < 55:
        result.put(10, x, y, Klaxon, 130)

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
          (if n mod 2 == 0: Klaxon else: PhosphorPeak), 220)

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
    of iDarts: Klaxon
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
  # amber backlight: matter glows, so loot separates from the plate
  result.addBacklight(TileSize, TileSize, GoldTone, 70)

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

proc channelHaloPixels(phase: int): seq[uint8] =
  ## Phosphor ring: the 48-tick heal/eat channel made visible. Sparser
  ## dash rhythm than the poison halo so the two never read alike.
  result = newSeq[uint8](10 * 10 * 4)
  for y in 0 ..< 10:
    for x in 0 ..< 10:
      let dx = x * 2 + 1 - 10
      let dy = y * 2 + 1 - 10
      let d2 = dx * dx + dy * dy
      if d2 > 36 and d2 <= 81 and (x + 2 * y + phase) mod 3 == 0:
        result.put(10, x, y, (165'u8, 227'u8, 238'u8), 150)

proc revealMarkPixels(): seq[uint8] =
  ## Red exclamation over a camo agent whose 120-tick reveal window runs.
  result = newSeq[uint8](5 * 5 * 4)
  let c = (255'u8, 74'u8, 54'u8)
  result.put(5, 2, 0, c)
  result.put(5, 2, 1, c)
  result.put(5, 2, 2, c)
  result.put(5, 2, 4, c)

proc upperLabel(s: string): string =
  ## 3x5-font-safe: uppercase, underscores become spaces.
  for ch in s:
    if ch == '_': result.add(' ')
    elif ch >= 'a' and ch <= 'z': result.add(chr(ord(ch) - 32))
    else: result.add(ch)

proc reticlePixels(): seq[uint8] =
  ## Amber drop-targeting reticle: corner brackets + center mark — the
  ## sponsor console's grammar stamped into the arena itself.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let m = TileSize - 1
  for i in 0 .. 1:
    result.put(TileSize, i, 0, GoldTone)
    result.put(TileSize, 0, i, GoldTone)
    result.put(TileSize, m - i, 0, GoldTone)
    result.put(TileSize, m, i, GoldTone)
    result.put(TileSize, i, m, GoldTone)
    result.put(TileSize, 0, m - i, GoldTone)
    result.put(TileSize, m - i, m, GoldTone)
    result.put(TileSize, m, m - i, GoldTone)
  result.put(TileSize, TileSize div 2, TileSize div 2, GoldTone, 230)

proc cratePartPixels(rows: int): seq[uint8] =
  ## Crate rastering in top-to-bottom under the beam — a print, not a
  ## landing. The print head is an amber line at the current row.
  result = newSeq[uint8](TileSize * TileSize * 4)
  let wood = (150'u8, 105'u8, 55'u8)
  for y in 0 ..< min(rows, TileSize):
    for x in 0 ..< TileSize:
      let edge = x == 0 or y == 0 or x == TileSize - 1
      result.put(TileSize, x, y, (if edge: shade(wood, -40) else: wood))
  if rows < TileSize:
    for x in 0 ..< TileSize:
      result.put(TileSize, x, min(rows, TileSize - 1), GoldTone, 230)

proc pingPixels(big: bool): seq[uint8] =
  ## Expanding contested-crate ping (two-phase pulse).
  result = newSeq[uint8](12 * 12 * 4)
  let rr = (if big: 10 else: 6)
  for y in 0 ..< 12:
    for x in 0 ..< 12:
      let dx = x * 2 + 1 - 12
      let dy = y * 2 + 1 - 12
      let d2 = dx * dx + dy * dy
      if d2 > (rr - 2) * (rr - 2) and d2 <= rr * rr:
        result.put(12, x, y, GoldTone, (if big: 90'u8 else: 150'u8))

proc hitFlashPixels(): seq[uint8] =
  ## 1-frame peak-white carrier silhouette on any damage taken.
  result = newSeq[uint8](BodyW * BodyH * 4)
  for y in 3 .. 7:
    for x in 1 .. 6:
      result.put(BodyW, x, y, PhosphorPeak, 170)

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

# --- 5x7 display font (banners/HUD/kill feed; 3x5 stays for in-world tags) ---
const Glyphs7 = {
  '0': 0b01110_10001_10011_10101_11001_10001_01110,
  '1': 0b00100_01100_00100_00100_00100_00100_01110,
  '2': 0b01110_10001_00001_00010_00100_01000_11111,
  '3': 0b11111_00010_00100_00010_00001_10001_01110,
  '4': 0b00010_00110_01010_10010_11111_00010_00010,
  '5': 0b11111_10000_11110_00001_00001_10001_01110,
  '6': 0b00110_01000_10000_11110_10001_10001_01110,
  '7': 0b11111_00001_00010_00100_01000_01000_01000,
  '8': 0b01110_10001_10001_01110_10001_10001_01110,
  '9': 0b01110_10001_10001_01111_00001_00010_01100,
  'A': 0b01110_10001_10001_11111_10001_10001_10001,
  'B': 0b11110_10001_10001_11110_10001_10001_11110,
  'C': 0b01110_10001_10000_10000_10000_10001_01110,
  'D': 0b11100_10010_10001_10001_10001_10010_11100,
  'E': 0b11111_10000_10000_11110_10000_10000_11111,
  'F': 0b11111_10000_10000_11110_10000_10000_10000,
  'G': 0b01110_10001_10000_10111_10001_10001_01111,
  'H': 0b10001_10001_10001_11111_10001_10001_10001,
  'I': 0b01110_00100_00100_00100_00100_00100_01110,
  'J': 0b00111_00010_00010_00010_00010_10010_01100,
  'K': 0b10001_10010_10100_11000_10100_10010_10001,
  'L': 0b10000_10000_10000_10000_10000_10000_11111,
  'M': 0b10001_11011_10101_10101_10001_10001_10001,
  'N': 0b10001_10001_11001_10101_10011_10001_10001,
  'O': 0b01110_10001_10001_10001_10001_10001_01110,
  'P': 0b11110_10001_10001_11110_10000_10000_10000,
  'Q': 0b01110_10001_10001_10001_10101_10010_01101,
  'R': 0b11110_10001_10001_11110_10100_10010_10001,
  'S': 0b01111_10000_10000_01110_00001_00001_11110,
  'T': 0b11111_00100_00100_00100_00100_00100_00100,
  'U': 0b10001_10001_10001_10001_10001_10001_01110,
  'V': 0b10001_10001_10001_10001_10001_01010_00100,
  'W': 0b10001_10001_10001_10101_10101_10101_01010,
  'X': 0b10001_10001_01010_00100_01010_10001_10001,
  'Y': 0b10001_10001_10001_01010_00100_00100_00100,
  'Z': 0b11111_00001_00010_00100_01000_10000_11111,
  ':': 0b00000_00100_00000_00000_00100_00000_00000,
  '-': 0b00000_00000_00000_01110_00000_00000_00000,
  '>': 0b01000_00100_00010_00001_00010_00100_01000,
  '.': 0b00000_00000_00000_00000_00000_00000_00100,
  ' ': 0}.toTable

proc textPixels7(text: string, r, g, b: uint8): (int, int, seq[uint8]) =
  ## Display-face line: 5x7 glyphs, 6px advance, on the standard plate.
  let w = 2 + text.len * 6
  let h = 9
  var px = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      px.put(w, x, y, BgDark, 220)
  for i, ch in text:
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    let bits = Glyphs7.getOrDefault(up, 0)
    for gy in 0 ..< 7:
      for gx in 0 ..< 5:
        if ((bits shr ((6 - gy) * 5 + (4 - gx))) and 1) == 1:
          px.put(w, 1 + i * 6 + gx, 1 + gy, (r, g, b))
  (w, h, px)

proc textPixels(text: string, r, g, b: uint8): (int, int, seq[uint8]) =
  let w = 2 + text.len * 4
  let h = 7
  var px = newSeq[uint8](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      px.put(w, x, y, BgDark, 220)
  for i, ch in text:
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    let bits = Glyphs.getOrDefault(up, 0)
    for gy in 0 ..< 5:
      for gx in 0 ..< 3:
        if ((bits shr ((4 - gy) * 3 + (2 - gx))) and 1) == 1:
          px.put(w, 1 + i * 4 + gx, 1 + gy, (r, g, b))
  (w, h, px)

# ------------------------------------------------- phosphor persistence
# (VISUAL_REDESIGN §3.5): every agent drags a decaying team-tinted trace;
# a death freezes into a permanent burn-in scar with the slot glyph etched
# at the death tile. One decay buffer, one overlay sprite at 2 Hz.

proc settleLinePixels(): seq[uint8] =
  ## Full-arena-width settlement rule, swept at a dead agent's row.
  result = newSeq[uint8](WorldPx * 3 * 4)
  for x in 0 ..< WorldPx:
    result.put(WorldPx, x, 0, Bone, 70)
    result.put(WorldPx, x, 1, Bone, 230)
    result.put(WorldPx, x, 2, Bone, 70)

proc lampRowPixels(mask: int): seq[uint8] =
  ## 16 lamps, one per slot: lit phosphor = alive, cold etch = settled.
  result = newSeq[uint8](81 * 6 * 4)
  for i in 0 ..< 16:
    let ox = 1 + i * 5
    let lit = ((mask shr i) and 1) == 1
    for y in 1 .. 4:
      for x in 0 ..< 4:
        if lit:
          result.put(81, ox + x, y, (if y == 1: PhosphorPeak else: Phosphor))
        else:
          result.put(81, ox + x, y,
            (if y == 1 or y == 4 or x == 0 or x == 3: Masonry else: EtchDim))

proc ordSuffix(n: int): string =
  if n mod 100 in 11 .. 13: "TH"
  elif n mod 10 == 1: "ST"
  elif n mod 10 == 2: "ND"
  elif n mod 10 == 3: "RD"
  else: "TH"

proc ensureTrace(r: var Renderer) =
  if r.trace.len == 0:
    r.trace = newSeq[uint32](WorldPx * WorldPx)
    r.scars = newSeq[uint32](WorldPx * WorldPx)

proc stampTrace(r: var Renderer, tileX, tileY: int,
                c: (uint8, uint8, uint8), a: uint8) =
  let ox = tileX * TileSize + 1
  let oy = tileY * TileSize + 1
  for y in 0 ..< TileSize - 2:
    for x in 0 ..< TileSize - 2:
      let i = (oy + y) * WorldPx + ox + x
      if i >= 0 and i < r.trace.len:
        if uint32(a) > (r.trace[i] and 0xFF):
          r.trace[i] = (uint32(c[0]) shl 24) or (uint32(c[1]) shl 16) or
                       (uint32(c[2]) shl 8) or uint32(a)
  r.traceActive = true

proc etchScar(r: var Renderer, slot: int, pos: Pos) =
  ## Burn-in: team-tinted floor scar plus the slot glyph, for the rest
  ## of the match. Rendered under live entities (overlay sits at z=3).
  let tc = TeamColors[slot div 2]
  let ox = pos.x * TileSize
  let oy = pos.y * TileSize
  for y in 0 ..< TileSize:
    for x in 0 ..< TileSize:
      let i = (oy + y) * WorldPx + ox + x
      if i >= 0 and i < r.scars.len and (r.scars[i] and 0xFF) < 45:
        r.scars[i] = (uint32(tc[0]) shl 24) or (uint32(tc[1]) shl 16) or
                     (uint32(tc[2]) shl 8) or 45'u32
  let label = "P" & $slot
  var gx = ox + TileSize + 1
  for ch in label:
    let bits = Glyphs.getOrDefault(ch, 0)
    for yy in 0 ..< 5:
      for xx in 0 ..< 3:
        if ((bits shr ((4 - yy) * 3 + (2 - xx))) and 1) == 1:
          let i = (oy + yy) * WorldPx + gx + xx
          if i >= 0 and i < r.scars.len:
            r.scars[i] = (uint32(Bone[0]) shl 24) or
                         (uint32(Bone[1]) shl 16) or
                         (uint32(Bone[2]) shl 8) or 85'u32
    gx += 4
  r.traceActive = true

proc traceSpritePixels(r: Renderer, s: Sim): seq[uint8] =
  result = newSeq[uint8](WorldPx * WorldPx * 4)
  for i in 0 ..< r.trace.len:
    let t = r.trace[i]
    let sc = r.scars[i]
    let v = (if (sc and 0xFF) > (t and 0xFF): sc else: t)
    if (v and 0xFF) > 0:
      let o = i * 4
      result[o] = uint8((v shr 24) and 0xFF)
      result[o+1] = uint8((v shr 16) and 0xFF)
      result[o+2] = uint8((v shr 8) and 0xFF)
      result[o+3] = uint8(v and 0xFF)
  # Knowledge Layer (VISUAL_REDESIGN §5.4): every living program's vision
  # disc at low additive phosphor — information itself made visible.
  # Cumulative alpha capped so Fortress pileups don't wash the board;
  # traces and scars (alpha > cap) always win.
  if s.phase != phEnded:
    for slot in 0 .. 15:
      let a = s.agents[slot]
      if not a.alive:
        continue
      let vr = (5 + (a.stats.intelligence + 1) div 2) * TileSize
      let cx = a.pos.x * TileSize + TileSize div 2
      let cy = a.pos.y * TileSize + TileSize div 2
      for y in max(0, cy - vr) .. min(WorldPx - 1, cy + vr):
        for x in max(0, cx - vr) .. min(WorldPx - 1, cx + vr):
          let dx = x - cx
          let dy = y - cy
          if dx * dx + dy * dy <= vr * vr:
            let o = (y * WorldPx + x) * 4
            let cur = int(result[o+3])
            if cur < 36:
              let na = min(36, cur + 9)
              result[o] = uint8((int(result[o]) * cur +
                int(Phosphor[0]) * (na - cur)) div max(1, na))
              result[o+1] = uint8((int(result[o+1]) * cur +
                int(Phosphor[1]) * (na - cur)) div max(1, na))
              result[o+2] = uint8((int(result[o+2]) * cur +
                int(Phosphor[2]) * (na - cur)) div max(1, na))
              result[o+3] = uint8(na)

# ---------------------------------------------------------------- packets

proc mmss(secs: int): string =
  $(secs div 60) & ":" & (if secs mod 60 < 10: "0" else: "") & $(secs mod 60)

proc effectiveSafeRadius(s: Sim): int =
  ## Exterior wash applies only once the zone deals damage.
  if s.zoneDamagePerS() > 0: s.zoneRadius() else: ArenaSize

proc derezLevel(s: Sim): int =
  ## De-rez escalates with ring severity (§3.7).
  let d = s.zoneDamagePerS()
  if d <= 2: 0
  elif d <= 8: 1
  else: 2

proc spriteDefs(s: Sim): seq[uint8] =
  result.addSprite(SpBackground, WorldPx, WorldPx,
                   backgroundPixels(s.arena, s.effectiveSafeRadius(),
                                    s.derezLevel()), "arena")
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
  # death burst in bone: the old (25,25,30)-on-Faraday burst measured
  # under 1.5:1 contrast — the game's pivotal event was invisible
  result.addSprite(SpFwBlack, 18, 18, burstPixels(18, 233, 228, 216), "fw_black")
  result.addSprite(SpFwGold, 18, 18, burstPixels(18, 255, 210, 110), "fw_gold")
  result.addSprite(SpMineFlash, 12, 12, burstPixels(12, 255, 74, 54), "mine")
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
  for id in ItemId:
    if id != iNone:
      result.addSprite(SpPodCrateBase + ord(id), TileSize, TileSize,
                       podCratePixels(itemColor(id)), "pod_" & $id)
  result.addSprite(SpPodChute, 10, 12, podChutePixels(), "chute")
  result.addSprite(SpChannelA, 10, 10, channelHaloPixels(0), "chanA")
  result.addSprite(SpChannelB, 10, 10, channelHaloPixels(1), "chanB")
  result.addSprite(SpRevealMark, 5, 5, revealMarkPixels(), "revealed")
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
  result.addSprite(SpSettleLine, WorldPx, 3, settleLinePixels(), "settle")
  result.addSprite(SpReticle, TileSize, TileSize, reticlePixels(), "reticle")
  for ph in 0 .. 2:
    result.addSprite(SpCratePartBase + ph, TileSize, TileSize,
                     cratePartPixels(2 + ph * 2), "crate_p" & $ph)
  result.addSprite(SpPingA, 12, 12, pingPixels(false), "pingA")
  result.addSprite(SpPingB, 12, 12, pingPixels(true), "pingB")
  result.addSprite(SpHitFlash, BodyW, BodyH, hitFlashPixels(), "hit")

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
  r.ensureTrace()
  # facing/anim bookkeeping
  for slot in 0 .. 15:
    let a = s.agents[slot]
    if a.alive:
      r.stampTrace(a.pos.x, a.pos.y, TeamColors[slot div 2], 130)
      # hit response (Tier 2): 1-frame peak-white flash + damage numeral
      if r.lastHp[slot] > a.hpCenti:
        r.spawnEffect(result, s, SpHitFlash,
          a.pos.x * TileSize + 3, a.pos.y * TileSize, 8, 2)
        let dmg = (r.lastHp[slot] - a.hpCenti + 50) div 100
        # numerals for combat/hazard hits only — steady zone burn would
        # carpet the endgame in floating digits (HP bars carry that)
        if dmg >= 1 and s.insideZone(a.pos):
          let spId = SpDmgBase + (r.dmgFlip mod 16)
          inc r.dmgFlip
          let (w, h, px) = textPixels("-" & $dmg, Klaxon[0], Klaxon[1],
                                      Klaxon[2])
          result.addSprite(spId, w, h, px, "dmg")
          let dObj = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
          inc r.nextEffect
          result.addObject(dObj, a.pos.x * TileSize - 4,
                           a.pos.y * TileSize - (BodyH - TileSize) - 13, 23,
                           LayerMap, spId)
          r.effects.add(Effect(objId: dObj, dieTick: s.tick + 16))
      r.lastHp[slot] = a.hpCenti
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
          (if ((s.tick div 6) + slot) mod 2 == 0: SpPoisonHaloA
           else: SpPoisonHaloB))
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
      # channel halo (Tier 1): the interruptible heal/eat window on air
      if a.channeling.kind != chNone:
        result.addObject(ObChannelBase + slot, a.pos.x * TileSize - 2,
          a.pos.y * TileSize - 2, 9, LayerMap,
          (if ((s.tick div 6) + slot) mod 2 == 0: SpChannelA
           else: SpChannelB))
        r.channelOn[slot] = true
      elif r.channelOn[slot]:
        result.addDeleteObject(ObChannelBase + slot)
        r.channelOn[slot] = false
      # camo blown: red mark while the 120-tick reveal window runs
      if a.body == iCamo and s.tick < a.camoRevealedUntil:
        result.addObject(ObRevealBase + slot, a.pos.x * TileSize + 1,
          a.pos.y * TileSize - (BodyH - TileSize) - 10, 13, LayerMap,
          SpRevealMark)
        r.revealOn[slot] = true
      elif r.revealOn[slot]:
        result.addDeleteObject(ObRevealBase + slot)
        r.revealOn[slot] = false
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
      if r.channelOn[slot]:
        result.addDeleteObject(ObChannelBase + slot)
        r.channelOn[slot] = false
      if r.revealOn[slot]:
        result.addDeleteObject(ObRevealBase + slot)
        r.revealOn[slot] = false
      # burn-in: freeze this agent's mark into the board forever
      r.etchScar(slot, a.pos)
      # persistent corpse (Tier 1: board accumulates story) + void beam
      result.addObject(ObCorpseBase + slot,
        a.pos.x * TileSize + TileSize div 2 - 6,
        a.pos.y * TileSize + TileSize div 2 - 6, 5, LayerMap,
        SpCorpseBase + slot)
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
              14, LayerMap,
              (if (phase + tx + ty) mod 2 == 0: SpFirestormA
               else: SpFirestormB))
            inc regIdx
    of ecFlood:
      for ty in max(1, ev.rect[1]) .. min(ArenaSize - 2, ev.rect[3]):
        for tx in max(1, ev.rect[0]) .. min(ArenaSize - 2, ev.rect[2]):
          if regIdx >= RegionPool: break
          result.addObject(ObRegionBase + regIdx, tx * TileSize, ty * TileSize,
            14, LayerMap,
            (if (phase + tx + ty) mod 2 == 0: SpFloodA else: SpFloodB))
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
    let (_, gift) = giftLookup(pod.itemId)
    if pod.landed:
      # crate keyed to primary contents — the contest stays identified —
      # plus a slow amber ping until looted (a fight magnet by design)
      let keyItem = (if gift.contents.len > 0: gift.contents[0][0] else: iNone)
      result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                       pod.landing.y * TileSize, 12, LayerMap,
                       SpPodCrateBase + ord(keyItem))
      result.addObject(ObPodPingBase + podIdx, pod.landing.x * TileSize - 3,
                       pod.landing.y * TileSize - 3, 11, LayerMap,
                       (if (s.tick div 12) mod 2 == 0: SpPingA else: SpPingB))
    else:
      # print sequence (§ sponsor_drop): reticle stamps the landing tile;
      # in the final 12 ticks the crate rasters in under the beam — the
      # machine prints deliveries, it does not parachute them
      result.addDeleteObject(ObPodPingBase + podIdx)
      let leftT = max(0, pod.landsTick - s.tick)
      if leftT <= 12:
        result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                         pod.landing.y * TileSize, 12, LayerMap,
                         SpCratePartBase + min(2, (12 - leftT) div 4))
      else:
        result.addObject(ObPodBase + podIdx, pod.landing.x * TileSize,
                         pod.landing.y * TileSize, 12, LayerMap, SpReticle)
      if beamIdx < 8:
        # beam objects persist; refresh on new beam or 1x/s
        if beamIdx >= r.podBeamsDrawn or s.tick mod 24 == 0:
          result.addObject(ObPodBeamBase + beamIdx, pod.landing.x * TileSize - 1,
                           pod.landing.y * TileSize - 54, 13, LayerMap, SpGoldBeam)
        inc beamIdx
    # cargo label rides the pod for its whole life (Tier 1): full manifest
    # while inbound, item name above the crate once landed
    let labelTxt = (if pod.landed: upperLabel(pod.itemId)
                    else: "AIRDROP: " & upperLabel(pod.itemId) & " " &
                          $gift.price & " SC")
    if r.podLabelText.len <= podIdx:
      r.podLabelText.setLen(podIdx + 1)
    if r.podLabelText[podIdx] != labelTxt:
      r.podLabelText[podIdx] = labelTxt
      let (w, h, px) = textPixels(labelTxt, GoldTone[0], GoldTone[1], GoldTone[2])
      result.addSprite(SpPodLabelBase + podIdx, w, h, px, "cargo")
    result.addObject(ObPodLabelBase + podIdx,
                     pod.landing.x * TileSize - (2 + labelTxt.len * 4) div 2 + 3,
                     pod.landing.y * TileSize - (if pod.landed: 10 else: 62),
                     21, LayerMap, SpPodLabelBase + podIdx)
    inc podIdx
  for stale in podIdx ..< r.podsDrawn:
    result.addDeleteObject(ObPodBase + stale)
    result.addDeleteObject(ObPodLabelBase + stale)
    result.addDeleteObject(ObPodPingBase + stale)
    if stale < r.podLabelText.len:
      r.podLabelText[stale] = ""
  r.podsDrawn = podIdx
  for stale in beamIdx ..< r.podBeamsDrawn:
    result.addDeleteObject(ObPodBeamBase + stale)
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
        let place = s.computePlacements()[e.slot]
        let line = (if k >= 0 and k != e.slot: "P" & $k & " > P" & $e.slot
                    else: "P" & $e.slot & " DOWN") &
                   " - " & $place & ordSuffix(place)
        r.killFeed.insert(line, 0)
        if r.killFeed.len > 3:
          r.killFeed.setLen(3)
        r.killDirty = true
        # settlement line (VISUAL_REDESIGN §5.3): a ledger rule strikes
        # the full frame at the dead agent's row
        let lineObj = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
        inc r.nextEffect
        result.addObject(lineObj, 0, e.pos.y * TileSize + 2, 22, LayerMap,
                         SpSettleLine)
        r.effects.add(Effect(objId: lineObj, dieTick: s.tick + 10))
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
  # phosphor persistence: decay + re-upload the overlay at 2 Hz
  if r.traceActive and s.tick mod 12 == 0:
    for i in 0 ..< r.trace.len:
      let a = r.trace[i] and 0xFF
      if a > 0:
        let na = (a * 4) div 5
        r.trace[i] = (r.trace[i] and 0xFFFFFF00'u32) or
                     (if na < 6: 0'u32 else: na)
    result.addSprite(SpTraceLayer, WorldPx, WorldPx, r.traceSpritePixels(s),
                     "trace")
    result.addObject(ObTraceLayer, 0, 0, 3, LayerMap, SpTraceLayer)
    r.traceDrawn = true
  # 16-lamp alive row: subtraction made visible as light
  var lampMask = 0
  for slot in 0 .. 15:
    if s.agents[slot].alive:
      lampMask = lampMask or (1 shl slot)
  if lampMask != r.lastLampMask:
    r.lastLampMask = lampMask
    result.addSprite(SpLampRow, 81, 6, lampRowPixels(lampMask), "lamps")
    result.addObject(ObLampRow, 2, 44, 0, LayerHudTL, SpLampRow)
  # exterior treatment tracks the shrinking ring: re-bake the background
  # whenever the integer safe radius OR the de-rez stage changes
  let bgR = s.effectiveSafeRadius()
  let bgKey = bgR * 4 + s.derezLevel()
  if bgKey != r.lastBgRadius:
    r.lastBgRadius = bgKey
    result.addSprite(SpBackground, WorldPx, WorldPx,
                     backgroundPixels(s.arena, bgR, s.derezLevel()), "arena")
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
    let (w, h, px) = textPixels7(hud1, PhosphorPeak[0], PhosphorPeak[1],
                                 PhosphorPeak[2])
    result.addSprite(spId, w, h, px, "hud1")
    result.addObject(ObHudLine1, 2, 2, 0, LayerHudTL, spId)
  if hud2 != r.lastHud2:
    r.lastHud2 = hud2
    let spId = SpHudBase + 2 + (r.hudFlip mod 2)
    inc r.hudFlip
    let (w, h, px) = textPixels7(hud2, GoldTone[0], GoldTone[1], GoldTone[2])
    result.addSprite(spId, w, h, px, "hud2")
    result.addObject(ObHudLine2, 2, 2, 0, LayerHudBL, spId)
  # kill feed under the status line (Tier 1)
  if r.killDirty:
    r.killDirty = false
    for i in 0 ..< r.killFeed.len:
      let spId = SpKillBase + i * 2 + (r.killFlip mod 2)
      let (w, h, px) = textPixels7(r.killFeed[i], 233, 228, 216)
      result.addSprite(spId, w, h, px, "kill" & $i)
      result.addObject(ObKillLineBase + i, 2, 13 + i * 9, 0, LayerHudTL, spId)
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
      let (w, h, px) = textPixels7(txt, GoldTone[0], GoldTone[1], GoldTone[2])
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
  result.addViewport(LayerHudTL, 240, 52)
  result.addLayer(LayerHudBL, 0x04, 0x02)
  result.addViewport(LayerHudBL, 320, 14)
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
    elif s.agents[slot].deathTick >= 0:
      # late joiners still see the fallen where they fell
      result.addObject(ObCorpseBase + slot,
        s.agents[slot].pos.x * TileSize + TileSize div 2 - 6,
        s.agents[slot].pos.y * TileSize + TileSize div 2 - 6, 5, LayerMap,
        SpCorpseBase + slot)

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
    r.channelOn[i] = false
    r.revealOn[i] = false
  r.mouthsDrawn = false
  r.podBeamsDrawn = 0
  r.ringDrawn = 0
  r.nextRingDrawn = 0
  r.killFeed = @[]
  r.killDirty = false
  r.killLinesDrawn = 0
  r.lastBgRadius = 0
  r.podLabelText = @[]
  r.trace = @[]
  r.scars = @[]
  r.traceActive = false
  r.traceDrawn = false
  r.lastLampMask = 0
  for i in 0 .. 15:
    r.lastHp[i] = 0
  r.dmgFlip = 0
  r.podsDrawn = 0
  r.itemsDrawn = 0
  r.projsDrawn = 0
  r.regionDrawn = 0
  r.bushesDrawn = 0
  r.lastHud1 = ""
  r.lastHud2 = ""
  r.bannerText = ""
