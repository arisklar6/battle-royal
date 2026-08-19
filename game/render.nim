## sprite_v1 renderer — v0.3 art: baked generative carriers (two chassis,
## ART_UPGRADE_PLAN Phase 3) over a code-generated board. Baked art lives
## in game/art_baked.nim as const data — nothing loads at runtime, nothing
## ships beside the binary — and code still stamps everything that carries
## state: pupils, pips, team diamonds, HP, text. <=16 colors per sprite.

import std/tables
import bitworld/spriteprotocol
import zero_sum/[types, arena, sim]
import art_baked

const
  LayerMap* = 0
  WorldPx* = ArenaSize * TileSize
  ## Supersampling (coworld-ctf global.nim RenderScale): the map layer
  ## announces an RS-times viewport and every board coordinate scales into
  ## it. Art authored natively at RS gains real detail; art still authored
  ## at 1x is nearest-neighbour upscaled so proportions hold. Costs ~3x
  ## stream — free over localhost, and the only way to have any room for
  ## detail on a 6px tile.
  ##
  ## RS=4 (ART_UPGRADE_PLAN §1): 24 px tile, 1152 px arena, 32x48 carrier.
  ## 12x12 was below the floor where material, chamfer and stencil survive
  ## a reduction, so generated art at RS=2 would have looked *worse* than
  ## the hand-tuned code it replaced. RS must stay EVEN — half of it is the
  ## authoring canvas the humanoids are drawn on (see `ArtScale`) — and it
  ## is a rendering constant only: nothing here reaches the sim, and
  ## tests/t_golden.nim is the standing proof.
  RS* = 4
  WorldPxR* = WorldPx * RS
  TilePxR* = TileSize * RS

  # sprite ids
  SpBackground = 1
  SpFwBlack = 30
  SpFwGold = 31
  SpMineFlash = 32
  SpZoneFireA = 33          # teal plasma (stages 1-4)
  SpZoneFireB = 34
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
  SpItemBase = 50          # 50 + ord(ItemId): ground chips (51..62)
  SpBushBase = 90          # 90..93: bush with 0..3 berries
  SpHudBase = 200
  SpBanner = 210
  # humanoids: 400 + slot*10 + facing(0..3)*2 + frame(0..1); corpse 560+slot
  SpBodyBase = 400
  SpCorpseBase = 560
  SpWeaponBase = 600       # 600 + ord(ItemId): held-item marks (east hand)
  SpWeaponWBase = 620      # 620 + ord(ItemId): mirrored west hand; +12 max
                           # keeps both families clear of SpMouthA at 700
                           # (the computed-base spacing rule, see 960 below)
  SpSlotLabelBase = 800    # 800 + slot: "P<n>" identity tags
  SpHpBandBase = 830       # 830 + band: hp semaphore bar (0 healthy/1 hurt/2 crit)
  SpRingGhost = 834        # dashed next-radius preview tile
  SpKillBase = 840         # 840..847: kill-feed lines (KillRows x 2 buffers)
  KillRows = 4             # VISUAL_REDESIGN 6.1: last 4 settlement rows
  KillCols = 39            # LayerHudTL is 240px and the feed draws at
                           # x=2 in the 5x7 face (6px advance), so a row
                           # past this runs off the viewport unseen
  SpChannelA = 850         # phosphor channel halo (heal/eat window)
  SpChannelB = 851
  SpRevealMark = 852       # red "camo blown" mark
  SpSettleLine = 860       # full-width settlement rule (death sweep)
  SpLampRow = 861          # 16-lamp alive row
  SpReticle = 870          # amber drop-targeting reticle
  SpCratePartBase = 871    # 871..873: crate rastering in (print sequence)
  SpPingA = 874            # landed-crate contested ping
  SpPingB = 875
  SpHitFlash = 876         # 1-frame peak-white hit silhouette
  SpDmgBase = 880          # 880..895: rotating damage numerals
  # baked fade ramps, 4 stages each (920..935) — the protocol carries no
  # per-object alpha, so dimming means swapping to a pre-dimmed sprite
  FadeStages = 4
  SpFadeDeath = 920        # 920..923
  SpFadeIgnite = 924       # 924..927
  SpFadeMine = 928         # 928..931
  SpFadeVoid = 932         # 932..935
  SpPodCrateBase = 900     # 900 + ord(ItemId): contents-keyed crates
  ## 960 + ord(ItemId) -> 964..972. This lived at 80 until 2026-08-13, where
  ## `80 + ord(iArrows|iDarts)` = 91, 92 landed inside SpBushBase's 90..93.
  ## Both families are defined in the same spriteDefs packet with the bushes
  ## first, and the client's sprite map is last-define-wins, so two of the
  ## four bush charge states rendered as the 4x4 projectile blob (8x8 on the
  ## wire, after the RS upscale) instead of foliage. Confirmed off
  ## the wire, not just by reading. Keep every computed base far enough apart
  ## that base + ord(ItemId) (max +12) cannot reach the next family.
  SpProjBase = 960         # 960 + ord(ItemId): projectiles
  SpPodLabelBase = 1000    # 1000 + pod index (< PodPool): cargo labels
  ## The phosphor persistence overlay was one whole-arena sprite (id 3)
  ## redefined every 48 ticks — the single most expensive thing on the wire
  ## over a full match. It is split into an 8x8 grid of cells and only the
  ## cells whose pixels actually changed are re-defined.
  TraceGrid = 8
  TraceCells = TraceGrid * TraceGrid
  TraceCell1x = WorldPx div TraceGrid    # 36 at ArenaSize 48, exact
  TraceCellPx = TraceCell1x * RS         # the cell sprite, authored at RS
  SpTraceBase = 1100       # 1100 + cell -> 1100..1163
  ## Reclaimed-territory overlay tiles (VISUAL_REDESIGN §3.7). The exterior
  ## treatment used to be baked into the arena sprite, which meant re-sending
  ## the whole board every time the ring stepped in.
  SpDerezWash = 1200       # stage 0: red "off-air" wash over live art
  SpDerezWire = 1201       # stage 1: art decays to an Etch wireframe
  SpDerezWireSolid = 1202  # stage 1, structural tile (masonry border)
  SpDerezDitherBase = 1210 # stage 2: raw substrate + dropped-pixel dither
  ## Talk chips (VISUAL_REDESIGN 5.7): chat is public by design, and the
  ## broadcast finally shows it. Double-buffered per speaker like every
  ## other dynamic text sprite.
  SpTalkBase = 1400        # 1400 + slot*2 + flip -> 1400..1431
  ## Death decomposition (VISUAL_REDESIGN Part 7): 8 frames per chassis,
  ## derived from the baked body at defs time — frame 0 IS the body.
  SpDecompBase = 1450      # + parity*8 + frame -> 1450..1465
  DecompFrames = 8
  SpDeathFlashBase = 1470  # + parity: opaque peak-white body silhouette
  SpSlotShortBase = 1500   # 1500 + slot: 2-char team+parity plate (A1, A2,
                           # B1 ...) shown instead of the name when agents
                           # cluster — keeps identity off hue alone (Part 8)

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
  ## One pooled overlay object per reclaimed tile, id keyed to the tile so a
  ## tile's state can be re-pointed or dropped without a rescan. Object ids
  ## are u16 on the wire: 32000 + 48*48 tops out at 34303.
  ObDerezBase = 32000
  ObTraceCellBase = 35000   # 35000 + cell: dirty-tiled trace overlay
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
  ObTalkBase = 45200        # + slot: talk chip above the speaker
  ObCorpseBase = 46000      # + slot: persistent corpse (lives to match end)
  ObKillLineBase = 50020    # + 0..2: kill-feed lines, newest first
  ObLampRow = 50030         # alive lamps in the TL HUD

  LayerHudTL = 1
  LayerHudBL = 4
  LayerBanner = 5

  ## Painter bands (client sorts z, then y, then id — so entities inside a
  ## band already resolve their own overlap by map position). Environment
  ## effects must sit BELOW entities: a carrier standing in the flood or
  ## crossing the ring was being hidden behind the terrain effect drawn on
  ## its own tile. Transient combat FX stay above everything.
  DerezZ = 1                 # reclaimed-territory overlay, just off the board
  TraceZ = 3                 # phosphor persistence, under every entity
  HazardZ = 7                # flood / firestorm fields
  RingZ = 9                  # zone boundary + next-radius ghost
  AgentZ = 10                # carriers and their chrome sit above both

  BodyW = 8
  BodyH = 12
  BodyWR = BodyW * RS      # carrier is authored natively at render scale
  BodyHR = BodyH * RS

  ## The carrier, its corpse and the three body-sized overlays were drawn
  ## with literal coordinates on a 16x24 grid — the buffer's size at RS=2
  ## and nowhere else. At RS=4 the buffer is 32x48 and every one of those
  ## figures would have been painted into its top-left quarter. `ArtScale`
  ## restates that grid as what it always was: an authoring canvas, scaled
  ## into the render buffer. It is exactly 1 at RS=2, so the pixels emitted
  ## there do not move.
  ## TODO(Phase 3): the whole family is replaced by a blit of the baked
  ## carrier (ART_UPGRADE_PLAN §4.3) and this authoring grid goes with it.
  ArtScale = RS div 2

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
  ## Substrate lifted out of near-black (2026-08-03). The old Faraday
  ## #0C1116 board sat at luma 9-25 of 255, so every material detail
  ## painted on it — noise, panel joints, bevels — fell below the
  ## perceptual floor. coworld-ctf holds its floor at luma 72-112, and
  ## that headroom is why its surfaces read at all. Same hues, raised
  ## into a lit range; entity phosphor and the team wheel still sit well
  ## above them.
  BgDark = (40'u8, 48'u8, 57'u8)          # lit slate substrate
  EtchDim = (58'u8, 68'u8, 79'u8)         # ramp low
  Masonry = (104'u8, 119'u8, 132'u8)      # structural ink
  Phosphor = (165'u8, 227'u8, 238'u8)     # #A5E3EE
  PhosphorPeak = (234'u8, 247'u8, 250'u8) # #EAF7FA
  RingMagenta = (255'u8, 79'u8, 163'u8)   # Directive Magenta #FF4FA3
  Klaxon = (255'u8, 74'u8, 54'u8)         # Klaxon Red #FF4A36
  GoldTone = (255'u8, 180'u8, 84'u8)      # Amber #FFB454
  Bone = (233'u8, 228'u8, 216'u8)         # settlement ink #E9E4D8

  ## Amber value ramp (ART_UPGRADE_PLAN §5 Phase 2). §3.1 law 3 makes amber
  ## the *only* colour for matter and money, so loot can no longer be told
  ## apart by hue — every chip, projectile and crate band is amber now.
  ## Value is what is left, so the ramp is spaced by luma rather than by
  ## taste: ~96 / 132 / 168 / 204 / 236, four steps of ~36. That stays
  ## separable after quantization and under every CVD (a value ramp is the
  ## one channel colour blindness does not touch). Hue is held near 34° so
  ## the stops read as one material lit differently, not five paints.
  ## Item *identity* properly returns in Phase 5 as a stencil; until then
  ## value separates classes and `itemPixels` separates them by shape.
  AmberDeep = (138'u8, 88'u8, 30'u8)
  AmberDim = (176'u8, 116'u8, 44'u8)
  AmberMid = (212'u8, 146'u8, 62'u8)
  AmberHot = (255'u8, 208'u8, 138'u8)


type
  Effect = object
    objId: int
    dieTick: int
    # staged fade (ctf technique 6): sprite_v1 has no per-object alpha, so
    # an effect that should dim bakes its stages as separate sprites and
    # swaps between them as it ages. stageBase < 0 = no fade.
    stageBase: int
    stages: int
    bornTick: int
    ttl: int
    stageShown: int
    x, y: int

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
    ## One flip counter per HUD line. They shared `hudFlip` until 2026-08-13,
    ## and a shared counter breaks the parity it exists to keep: when both
    ## lines change on the same tick, hud1 takes parity p and hud2 advances
    ## the counter again, so hud1's *next* change lands back on parity p —
    ## redefining the sprite ObHudLine1 is still bound to instead of writing
    ## the idle buffer and then pointing at it. Double buffering only works
    ## if each buffer advances on its own writes.
    hud1Flip, hud2Flip: int
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
    killFeed: seq[string]     # newest first, max KillRows
    killDirty: bool
    killFlip: int
    killLinesDrawn: int
    talkSeen: int             # talkLog high-water mark
    talkOn: array[16, bool]
    talkUntil: array[16, int]
    talkFlip: array[16, int]
    talkW: array[16, int]     # chip width in 1x space, for the edge clamp
    lastCause: array[16, string]  # cause watermark for settlement chyrons
    labels: array[16, string]     # slotLabel per seat; see ensureLabels
    labelsReady: bool
    nextRingDrawn: int
    lastBgRadius: int         # last (safe radius, de-rez stage) key applied
    derezTile: seq[int]       # per tile: overlay sprite id placed, 0 = none
    channelOn: array[16, bool]
    revealOn: array[16, bool]
    podLabelText: seq[string] # per pod index, for sprite-rebuild detection
    trace: seq[uint32]        # packed RGBA per world px: live afterglow
    scars: seq[uint32]        # packed RGBA per world px: burn-in, permanent
    traceActive: bool
    traceCellHash: array[TraceCells, uint64]
    traceCellDrawn: array[TraceCells, bool]
    lastLampMask: int
    lastHp: array[16, int]    # centi-HP watermark for hit flashes
    bgLive: bool              # pedestal plates already swapped to disarmed
    dmgFlip: int
    ## Cached sprite-definition blob. `spriteDefs` is a pure function of the
    ## arena, but it ran in full — the whole rasterizer plus ~270 Snappy
    ## compressions, a measured 13.5 ms at RS=2 — on the tick thread for
    ## every viewer that connected, mid-match, against a 41.7 ms frame.
    ## Keyed by the arena so a new match with a new map rebuilds it itself.
    defsBlob: seq[uint8]
    defsKey: uint64
    defsValid: bool

# ---------------------------------------------------------------- helpers

proc upscaled(px: openArray[uint8], w, h: int): seq[uint8] =
  ## Nearest-neighbour ×RS for sprites still authored at 1x.
  result = newSeq[uint8](w * RS * h * RS * 4)
  for y in 0 ..< h * RS:
    for x in 0 ..< w * RS:
      let si = ((y div RS) * w + (x div RS)) * 4
      let di = (y * w * RS + x) * 4
      for c in 0 .. 3:
        result[di + c] = px[si + c]

## The sprites placed on a UI layer, named rather than described by a window
## of magic numbers, because this set decides who skips the map viewport's
## xRS upscale. The old test was `id in 200..215 or id in 840..861`, and
## 840..861 swept up three sprites that are placed on LayerMap: SpChannelA/B
## (850/851), SpRevealMark (852) and SpSettleLine (860). They shipped at 1x
## into an RS viewport, so the "full-frame" settlement rule — the flagship
## death beat — drew across exactly half the arena. Every entry below is
## paired with the addObject site that puts it on a UI layer; if a sprite is
## not placed on a UI layer it does not belong here, whatever its id.
const UiSpriteIds = {
  uint16(SpHudBase) .. uint16(SpHudBase + 3),      # hud1/hud2 -> LayerHudTL/BL
  uint16(SpBanner) .. uint16(SpBanner + 1),        # banner    -> LayerBanner
  uint16(SpKillBase) .. uint16(SpKillBase + KillRows * 2 - 1),  # kill feed -> LayerHudTL
  uint16(SpLampRow)                                # lamp row  -> LayerHudTL
}

static:
  ## Baked art is reduced for one specific RS; a mismatch would ship a
  ## scaled-wrong carrier instead of failing the build (ART_UPGRADE_PLAN
  ## risk 12).
  doAssert BakeRS == RS and BakeTilePx == TileSize * RS

proc isUiSprite(id: int): bool =
  ## The only sprites that live on UI layers; everything else is board art
  ## and therefore scales with the map viewport.
  id >= 0 and id <= int(uint16.high) and uint16(id) in UiSpriteIds

proc addSprite(packet: var seq[uint8], spriteId, width, height: int,
               pixels: openArray[uint8], label = "", native = false) =
  ## Board sprites authored at 1x are upscaled into the RS viewport; UI
  ## sprites keep their own 1:1 space. `native` marks art already
  ## rasterized at RS (CTF passes the same flag through addBoardSprite).
  if RS == 1 or native or isUiSprite(spriteId) or width == WorldPxR:
    spriteprotocol.addSprite(packet, spriteId, width, height, pixels, label)
  else:
    spriteprotocol.addSprite(packet, spriteId, width * RS, height * RS,
                             upscaled(pixels, width, height), label)

proc addObject(packet: var seq[uint8],
               objectId, x, y, z, layer, spriteId: int) =
  ## Map placements scale into the supersampled viewport in one place, so
  ## no call site has to know about RS.
  when not defined(release):
    # The whole point of UiSpriteIds is that it agrees with where sprites
    # are actually placed. Check it here, where both halves are in hand.
    # Debug/test builds only: a hosted match must never die of a Defect.
    assert isUiSprite(spriteId) == (layer != LayerMap),
      "sprite " & $spriteId & " placed on layer " & $layer &
      " disagrees with UiSpriteIds — it will be scaled wrong"
  if layer == LayerMap:
    spriteprotocol.addObject(packet, objectId, x * RS, y * RS, z, layer,
                             spriteId)
  else:
    spriteprotocol.addObject(packet, objectId, x, y, z, layer, spriteId)

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

proc lumaOf(c: (uint8, uint8, uint8)): int =
  (int(c[0]) * 30 + int(c[1]) * 59 + int(c[2]) * 11) div 100

proc concreteGrade(c: (uint8, uint8, uint8), lift: int): (uint8, uint8, uint8) =
  ## PAINTBOT pass: coworld-ctf's broadcast reads because its arena is warm
  ## daylight concrete, not a cold instrument slate. The baked material keeps
  ## every bit of its detail — the luma channel — and only the tone moves:
  ## regraded onto a warm concrete ramp (r above luma, b below), lifted into
  ## ctf's floor range. Live board only; the de-rez overlays deliberately
  ## stay on the cold BgDark/Etch ramp, so reclaimed territory now reads as
  ## the machine shutting the warm world off.
  let l = min(255, lumaOf(c) * 9 div 8 + lift)
  (uint8(min(255, l + l div 14 + 4)), uint8(l), uint8(max(0, l * 8 div 9 - 4)))

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
  PanelPeriodPx = 8 * TilePxR         # joints every 8 tiles, not every tile
  FloorLo = -52                       # luminance envelope; the low end is
                                      # sized for the crack ink, which digs
                                      # far deeper than the material noise
  FloorHi = 20

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
  ## Rasterized in render space: at RS=2 the octaves resolve twice as
  ## finely and a third, sub-world octave appears that 1x had no room for.
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let wx = ox + x
      let wy = oy + y
      var d = (noiseAt(wx, wy, 16 * RS) * 5) div 128 +
              (noiseAt(wx, wy, 4 * RS) * 3) div 128 +
              (noiseAt(wx, wy, 2 * RS) * 2) div 128 +
              (pixHash(wx, wy) mod 3) - 1
      let g = pixHash(wx * 3 + 1, wy * 3 + 7)
      if g mod 211 == 0: d += 14        # aggregate fleck
      elif g mod 397 == 0: d -= 9       # pinhole
      # embossed panel joint: recessed line with a lit lip up-left of it
      let jx = wx mod PanelPeriodPx
      let jy = wy mod PanelPeriodPx
      if jx < RS or jy < RS: d -= 10
      elif jx < RS * 2 or jy < RS * 2: d += 6
      # (the per-tile etch grid is gone: ctf's floor has no tile-rate lines,
      # and it is exactly what made the board read as graph paper)
      # organic cracks (ctf arena_floor): a ridged octave pair — the zero
      # band of value noise traces closed meandering contours, exactly the
      # look of settled concrete. Gated by a coarse mask so slabs of clean
      # floor survive; deterministic in world coords like everything else.
      let crackV = noiseAt(wx, wy, 48 * RS) * 2 + noiseAt(wx, wy, 8 * RS)
      let crackHere = noiseAt(wx + 4093, wy + 2251, 64 * RS) > 12
      if crackHere and abs(crackV) < 6:
        d -= (if abs(crackV) < 3: 42 else: 12)
      # Tier B (ART_UPGRADE_PLAN §4.3): the base is the baked floor field —
      # generated stone sampled at absolute world coordinates, so the floor
      # stays non-tiling — and every delta above rides on it unchanged.
      # PAINTBOT pass: regraded warm; the deltas ride on top unchanged.
      let base = concreteGrade(
        FloorField.rgbAt(wx mod FloorFieldW, wy mod FloorFieldH), 26)
      px.put(w, wx, wy, shade(base, max(FloorLo, min(FloorHi, d))))

# --- structural material: shading derived from the collision mask ---
# Ported technique (coworld-ctf map_art.nim rooftopColorAt): instead of a
# flat tile pattern, every structural pixel measures its distance to the
# nearest open pixel along 4 rays and shades by that distance — ground
# ink line, lit/shadowed parapet rim, then roof face. The art therefore
# matches the colliders exactly and reads as built volume rather than
# texture. Light comes from up-left throughout the renderer.
const
  StoneInk = (16'u8, 22'u8, 28'u8)     # contact line — never pure black
  WallBevelPx = 2 * RS                 # rim width, in render pixels
  RoofSeamPeriod = 8 * RS

proc isStructure(a: Arena, tx, ty: int): bool =
  ## Off-map counts as solid so the border wall keeps a face, not a rim.
  if tx < 0 or ty < 0 or tx >= ArenaSize or ty >= ArenaSize:
    return true
  a.tiles[ty][tx] in {tkWall, tkFortressWall}

proc structureAtPx(a: Arena, wx, wy: int): bool =
  isStructure(a, wx div TilePxR, wy div TilePxR)

proc openDistDir(a: Arena, wx, wy, dx, dy, maxD: int): int =
  ## Steps to the nearest non-structural pixel in one direction.
  for d in 1 .. maxD:
    if not structureAtPx(a, wx + dx * d, wy + dy * d):
      return d
  maxD + 1

proc parapetColorAt(a: Arena, wx, wy: int, lift: int): (uint8, uint8, uint8) =
  ## Tier B: the material is baked generated stone, but ONLY the base colour
  ## comes from it — the 4-ray collider classification below is what makes
  ## walls read as built volume, and it stays verbatim (ART_UPGRADE_PLAN
  ## risk 4). The Fortress is the same material lifted, not a second image.
  const MaxD = WallBevelPx + 2
  let up = openDistDir(a, wx, wy, 0, -1, MaxD)
  let dn = openDistDir(a, wx, wy, 0, 1, MaxD)
  let lf = openDistDir(a, wx, wy, -1, 0, MaxD)
  let rt = openDistDir(a, wx, wy, 1, 0, MaxD)
  let edge = min(min(up, dn), min(lf, rt))
  ## PAINTBOT pass: same warm grade as the floor, no lift of its own — the
  ## rooftop reads as the same daylight material one storey up (ctf's
  ## rooftops are its floor concrete, shaded by the collider), and the
  ## Fortress keeps its `lift` on top.
  let base = shade(concreteGrade(
    WallFace.rgbAt(wx mod WallFaceW, wy mod WallFaceH), 0), lift)
  if edge <= 1:
    StoneInk
  elif edge <= WallBevelPx:
    # rim: lit where the opening lies up-left, shadowed down-right
    if min(up, lf) <= min(dn, rt): shade(base, 40) else: shade(base, -26)
  elif (wx + wy) mod RoofSeamPeriod == 0:
    shade(base, -12)                   # roof seam
  else:
    base

proc wallAt(px: var seq[uint8], w, ox, oy: int, a: Arena, lift: int) =
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      px.put(w, ox + x, oy + y, parapetColorAt(a, ox + x, oy + y, lift))

proc compositeBaked(px: var seq[uint8], w, ox, oy: int,
                    art: openArray[uint8], aw, ah: int, graded = false) =
  ## Alpha-over a baked sprite into a larger RGBA buffer. `graded` runs the
  ## source through the PAINTBOT concrete grade — for baked terrain (rock
  ## clusters) that must sit on the regraded floor without re-baking the
  ## assets; props that carry semantic colour (crates, chips, pedestals,
  ## bushes) stay verbatim.
  for y in 0 ..< ah:
    for x in 0 ..< aw:
      let si = (y * aw + x) * 4
      let al = int(art[si + 3])
      if al == 0:
        continue
      var src = (art[si], art[si + 1], art[si + 2])
      if graded:
        src = concreteGrade(src, 4)
      let di = ((oy + y) * w + ox + x) * 4
      if al == 255:
        px[di] = src[0]; px[di+1] = src[1]; px[di+2] = src[2]
        px[di+3] = 255
      else:
        px[di] = uint8((int(src[0]) * al + int(px[di]) * (255 - al)) div 255)
        px[di + 1] = uint8((int(src[1]) * al +
                            int(px[di + 1]) * (255 - al)) div 255)
        px[di + 2] = uint8((int(src[2]) * al +
                            int(px[di + 2]) * (255 - al)) div 255)
        px[di + 3] = 255

proc rockAt(px: var seq[uint8], w, ox, oy: int) =
  ## Boulder under the same up-left key light as the walls.
  ## Etch ramp as of Phase 2. The old (86,78,70) was a warm brown — stone
  ## wearing amber's colour, which §3.1 law 3 forbids ("no colour ever
  ## moonlights"): on a board where amber is the contract for loot, thirty
  ## brown boulders read as thirty things worth walking to. Cooled onto the
  ## Etch ramp and sat below Masonry so rock still separates from wall.
  let base = (84'u8, 96'u8, 108'u8)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let lit = x + y <= 2 * RS
      let dark = (TilePxR - 1 - x) + (TilePxR - 1 - y) <= 2 * RS
      let rim = x < RS or y < RS or x >= TilePxR - RS or y >= TilePxR - RS
      var c = base
      if lit: c = shade(base, 34)
      elif dark: c = shade(base, -30)
      elif rim: c = shade(base, -16)
      px.put(w, ox + x, oy + y, c)
  ## §3.6 one-key edge light: a single phosphor-tinted top edge, instrument
  ## backlight rather than sun. One authoring pixel, so it stays a hairline.
  for x in ArtScale ..< (TilePxR - ArtScale):
    for k in 0 ..< max(1, ArtScale):
      px.put(w, ox + x, oy + k, shade(Phosphor, -74), 150)
  px.put(w, ox + TilePxR - 1, oy + TilePxR - 1, StoneInk)

proc pedestalAt(px: var seq[uint8], w, ox, oy: int, armed: bool) =
  ## Baked pedestal plate (Tier A): hazard-striped amber while the mines
  ## are live during the countdown, plain disarmed plate after ignition.
  if armed:
    px.compositeBaked(w, ox, oy, PedestalArmedPx, PedestalArmedW, PedestalArmedH)
  else:
    px.compositeBaked(w, ox, oy, PedestalOffPx, PedestalOffW, PedestalOffH)

## --- reclaimed territory: overlay tiles, not a re-baked board ---------
##
## The exterior treatment used to be painted into the arena sprite, so every
## time the ring stepped in — 27 times a match — the whole board was
## re-rasterized and re-sent, purely because a radius changed. The treatment
## is per-tile and depends on nothing but (de-rez stage, structural?, tile),
## so it belongs in a handful of tile sprites with one pooled object per
## reclaimed tile (VISUAL_REDESIGN §3.7: "three extra tile sprites, zero
## shaders"). `backgroundPixels` composites those same tiles with the wire's
## own source-over math, so the baked path (poster) and the streamed path
## cannot drift apart.
const
  ## Stage 2's dither is a function of the tile's own coordinates. Its true
  ## period is lcm(16, 11) = 176 tiles — on a 48-tile board it never repeats,
  ## and that is the point (§3.7 wants reclaimed ground to look like dropped
  ## memory, not like wallpaper). It therefore cannot be one sprite.
  ##
  ## The first pooling attempt sampled the variant at `(tx mod 4, ty mod 4)`,
  ## which kept the generator and the density but made the *assignment*
  ## periodic — so the finale, where the whole board is stage 2, became an
  ## exact 12x12 lattice of identical stamps. That is worse than the tiling
  ## the pooling was meant to avoid.
  ##
  ## The lattice came from the periodic assignment, not from the finite
  ## pattern set. So: keep a finite pool, but pick from it with `pixHash`,
  ## which is a prime-mix hash with no period over 48 tiles. Repeats still
  ## occur — 32 patterns over ~2000 tiles — but they land scattered instead
  ## of on a grid, which is what stops the eye resolving a weave.
  DerezVarX = 8
  DerezVarY = 4
  DerezVariants = DerezVarX * DerezVarY
  ## Stage 0 was an in-place `src*3/5 + {26,4,8}` over the baked board. As a
  ## source-over wash that is exactly RGBA(65,10,20,102):
  ## (src*(255-102) + 65*102) div 255 == src*3 div 5 + 26, because 153/255 is
  ## exactly 3/5 and 65*102/255, 10*102/255, 20*102/255 are exactly 26, 4, 8.
  ## The overlay reproduces the old bake byte for byte, not approximately.
  DerezWashColor = (65'u8, 10'u8, 20'u8)
  DerezWashAlpha = 102'u8

proc reclaimVariant(tx, ty: int): int =
  ## Non-periodic over the board: pixHash is a prime-mix hash, so adjacent
  ## tiles disagree and no offset reproduces itself. Deterministic, so the
  ## baked (poster) and streamed paths still pick the same variant.
  pixHash(tx * 3 + 11, ty * 3 + 5) mod DerezVariants

proc derezSpriteId(derez, tx, ty: int, structural: bool): int =
  case derez
  of 0: SpDerezWash
  of 1: (if structural: SpDerezWireSolid else: SpDerezWire)
  else: SpDerezDitherBase + reclaimVariant(tx, ty)

proc derezTilePixels(spriteId: int): seq[uint8] =
  ## The overlay for one reclaimed tile, authored natively at RS.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  if spriteId == SpDerezWash:
    for y in 0 ..< TilePxR:
      for x in 0 ..< TilePxR:
        result.put(TilePxR, x, y, DerezWashColor, DerezWashAlpha)
    return
  let wire = spriteId == SpDerezWire or spriteId == SpDerezWireSolid
  let structural = spriteId == SpDerezWireSolid
  # sample the dither at this variant's representative tile
  let v = spriteId - SpDerezDitherBase
  let vx = v mod DerezVarX
  let vy = v div DerezVarX
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      var col = BgDark
      if wire:
        if x < RS or y < RS:
          col = EtchDim
        if structural and (x < RS or y < RS or x >= TilePxR - RS or
                           y >= TilePxR - RS):
          col = Masonry
      else:
        if tileHash(vx * 3 + x, vy * 3 + y) mod 13 == 0:
          col = EtchDim
      result.put(TilePxR, x, y, col)

iterator derezSpriteIds(): int =
  yield SpDerezWash
  yield SpDerezWire
  yield SpDerezWireSolid
  for v in 0 ..< DerezVariants:
    yield SpDerezDitherBase + v

proc isStructuralTile(a: Arena, tx, ty: int): bool =
  a.tiles[ty][tx] in {tkWall, tkFortressWall, tkRock, tkPedestal}

proc isReclaimed(safeR, tx, ty: int): bool =
  let c = ArenaSize div 2
  let dx = tx - c
  let dy = ty - c
  dx * dx + dy * dy > safeR * safeR

proc backgroundPixels(a: Arena, safeR: int, derez: int,
                      armed = false): seq[uint8] =
  ## safeR: tiles outside this center radius are reclaimed territory.
  ## derez escalates with the ring stage (VISUAL_REDESIGN §3.7 — the
  ## machine deallocating the world): 0 = red "off-air" wash,
  ## 1 = art decays to Etch wireframe, 2 = raw substrate + dropped-pixel
  ## dither. Pass safeR >= ArenaSize for an untouched board.
  ## Rasterized natively at RS — this is the one sprite where the extra
  ## resolution buys genuine detail (finer bevels, a third noise octave)
  ## rather than doubled pixels.
  result = newSeq[uint8](WorldPxR * WorldPxR * 4)
  var overlay = initTable[int, seq[uint8]]()   # built at most once per stage
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      let ox = tx * TilePxR
      let oy = ty * TilePxR
      case a.tiles[ty][tx]
      of tkGround, tkBush:      # bushes are objects; plate beneath
        plateAt(result, WorldPxR, ox, oy, tx, ty)
      of tkWall:
        wallAt(result, WorldPxR, ox, oy, a, 0)
      of tkFortressWall:
        wallAt(result, WorldPxR, ox, oy, a, 22)
      of tkRock:
        plateAt(result, WorldPxR, ox, oy, tx, ty)
      of tkPedestal:
        plateAt(result, WorldPxR, ox, oy, tx, ty)
        pedestalAt(result, WorldPxR, ox, oy, armed)
      if isReclaimed(safeR, tx, ty):
        # Composite the very tile the wire places, with the viewer's own
        # unpremultiplied source-over. Opaque stages replace, the stage-0
        # wash blends — and lands on the same bytes the in-place bake did.
        let spId = derezSpriteId(derez, tx, ty, a.isStructuralTile(tx, ty))
        if spId notin overlay:
          overlay[spId] = derezTilePixels(spId)
        let ov = overlay[spId]
        for y in 0 ..< TilePxR:
          for x in 0 ..< TilePxR:
            let si = (y * TilePxR + x) * 4
            let al = int(ov[si + 3])
            if al == 0:
              continue
            let i = ((oy + y) * WorldPxR + ox + x) * 4
            for ch in 0 .. 2:
              result[i + ch] = uint8((int(ov[si + ch]) * al +
                                      int(result[i + ch]) * (255 - al)) div 255)
            result[i + 3] = 255

# ---------------------------------------------------------------- humanoids

  # --- rock art (Tier A): greedy cluster match over the PRNG rock layout —
  # 3x2 blocks first, then 2x2, then per-tile orphans; the generated
  # clusters read as one formation instead of a grid of copies. Variant
  # choice is pixHash of the origin: deterministic per arena.
  var claimed: array[ArenaSize * ArenaSize, bool]
  template isRock(tx, ty: int): bool =
    tx >= 0 and ty >= 0 and tx < ArenaSize and ty < ArenaSize and
      a.tiles[ty][tx] == tkRock and not claimed[ty * ArenaSize + tx]
  template claim(tx, ty, bw, bh: int) =
    for cy in ty ..< ty + bh:
      for cx in tx ..< tx + bw:
        claimed[cy * ArenaSize + cx] = true
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      block fit32:
        for cy in ty ..< ty + 2:
          for cx in tx ..< tx + 3:
            if not isRock(cx, cy): break fit32
        claim(tx, ty, 3, 2)
        case pixHash(tx * 7 + 1, ty * 11 + 3) mod 3
        of 0: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster32APx, RockCluster32AW, RockCluster32AH, graded = true)
        of 1: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster32BPx, RockCluster32BW, RockCluster32BH, graded = true)
        else: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster32CPx, RockCluster32CW, RockCluster32CH, graded = true)
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      block fit22:
        for cy in ty ..< ty + 2:
          for cx in tx ..< tx + 2:
            if not isRock(cx, cy): break fit22
        claim(tx, ty, 2, 2)
        case pixHash(tx * 5 + 2, ty * 13 + 1) mod 3
        of 0: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster22APx, RockCluster22AW, RockCluster22AH, graded = true)
        of 1: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster22BPx, RockCluster22BW, RockCluster22BH, graded = true)
        else: result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                RockCluster22CPx, RockCluster22CW, RockCluster22CH, graded = true)
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      if isRock(tx, ty):
        claimed[ty * ArenaSize + tx] = true
        result.compositeBaked(WorldPxR, tx * TilePxR, ty * TilePxR,
                              RockOrphanPx, RockOrphanW, RockOrphanH, graded = true)

## --- procedural cog chassis (PAINTBOT pass 2) --------------------------
##
## The baked carriers read as upholstered slabs at broadcast zoom; ctf's
## cogs read instantly because the silhouette is a MACHINE — dark rubber
## wheels, a boxy hull, a head wearing a lit face. Same canvas, same
## two-chassis contract (every duo fields one slender A and one broad B),
## but the art is drawn here in greyscale: luma is what bodyPixels' team
## tint consumes, so the hull takes the team paint while the near-black
## wheels and visor stay rubber and glass. Code still stamps state after
## the tint: phosphor eyes keyed to facing, the parity pip, the bob.
##
## Authoring grid: 8x12 at ArtScale px per cell, the grid every stamp in
## bodyPixels already speaks (template PD).

proc cogRect(px: var seq[uint8], mask: var seq[uint8],
             x0, y0, x1, y1, l: int) =
  ## Fill an authoring-grid rect with grey luma l (opaque).
  for ay in y0 .. y1:
    for ax in x0 .. x1:
      for oy in 0 ..< ArtScale:
        for ox in 0 ..< ArtScale:
          let x = ax * ArtScale + ox
          let y = ay * ArtScale + oy
          if x >= 0 and y >= 0 and x < BodyWR and y < BodyHR:
            px.put(BodyWR, x, y, (uint8(l), uint8(l), uint8(l)))
            mask[y * BodyWR + x] = 255

proc buildCog(parity, facing: int): (seq[uint8], seq[uint8]) =
  ## One chassis, one facing: (RGBA px, coverage mask), both BodyWR x BodyHR.
  var px = newSeq[uint8](BodyWR * BodyHR * 4)
  var mask = newSeq[uint8](BodyWR * BodyHR)
  let broad = parity == 1
  let side = facing >= 2                # E/W: profile view
  if not side:
    # --- front/back view (S shows the face; N the service panel) ---
    # big head, full canvas width — the paintbot proportion — with a dark
    # visor band the eyes will light
    cogRect(px, mask, 0, 0, 7, 0, 225)
    cogRect(px, mask, 0, 1, 7, 3, 200)
    cogRect(px, mask, 1, 2, 6, 2, 35)             # visor band
    if facing == 1:
      cogRect(px, mask, 1, 2, 6, 2, 150)          # N: panel, no glass
      cogRect(px, mask, 3, 1, 4, 3, 165)          # back seam
    # torso: left-lit box; broad chassis adds shoulder pods
    let tx0 = (if broad: 0 else: 1)
    let tx1 = (if broad: 7 else: 6)
    cogRect(px, mask, tx0, 4, tx1, 8, 190)
    cogRect(px, mask, tx0, 4, tx0, 8, 218)        # key-light column
    cogRect(px, mask, tx1, 4, tx1, 8, 152)        # shade column
    cogRect(px, mask, tx0, 8, tx1, 8, 160)        # skirt row
    cogRect(px, mask, tx0, 4, tx1, 4, 142)        # collar seam under the head
    if broad:
      cogRect(px, mask, 0, 4, 0, 5, 120)          # shoulder pods
      cogRect(px, mask, 7, 4, 7, 5, 120)
    if facing == 0:
      cogRect(px, mask, 3, 5, 4, 6, 232)          # chest lamp panel
    # drivetrain: rubber stays rubber (near-black survives the tint)
    cogRect(px, mask, 0, 9, 2, 11, 30)
    cogRect(px, mask, 5, 9, 7, 11, 30)
    cogRect(px, mask, 1, 10, 1, 10, 95)           # hubs
    cogRect(px, mask, 6, 10, 6, 10, 95)
    cogRect(px, mask, 3, 10, 4, 11, 45)           # center caster
  else:
    # --- profile view: hull leans forward over one big drive wheel ---
    let m = facing == 3                 # W mirrors E
    template X(a: int): int = (if m: 7 - a else: a)
    template R(x0, y0, x1, y1, l: int) =
      cogRect(px, mask, min(X(x0), X(x1)), y0, max(X(x0), X(x1)), y1, l)
    R(2, 0, 7, 0, 225)                            # head cap
    R(2, 1, 7, 2, 200)                            # head
    R(5, 1, 6, 2, 35)                             # visor at the bow
    R(1, 3, 6, 8, 190)                            # hull, nose-heavy
    R(1, 3, 1, 8, 218)                            # key light (stern)
    R(6, 3, 6, 8, 152)                            # bow shade
    R(1, 3, 6, 3, 142)                            # deck seam
    if broad:
      R(0, 4, 0, 6, 120)                          # pannier pod
    R(1, 8, 6, 11, 28)                            # drive wheel
    R(3, 9, 4, 10, 100)                           # hub
    R(6, 10, 7, 11, 40)                           # front caster
  (px, mask)

let CogArt = block:
  var arts: array[2, array[4, (seq[uint8], seq[uint8])]]
  for parity in 0 .. 1:
    for facing in 0 .. 3:
      arts[parity][facing] = buildCog(parity, facing)
  arts

proc chassisPx(parity, facing: int):
    tuple[px: ptr UncheckedArray[uint8], mask: ptr UncheckedArray[uint8]] =
  (cast[ptr UncheckedArray[uint8]](unsafeAddr CogArt[parity][facing][0][0]),
   cast[ptr UncheckedArray[uint8]](unsafeAddr CogArt[parity][facing][1][0]))

proc bodyPixels(team, parity, facing, frame: int): seq[uint8] =
  ## Baked AFTERGLOW carrier. Placement offsets stay in 1x tile space and
  ## are scaled by addObject; the buffer is BodyWR x BodyHR, exactly the
  ## baked sprite's size, so the blit is a straight copy with the bob lift.
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  let tunic = TeamColors[team]
  let lift = (if frame == 1: -ArtScale else: 0)   # 1 authoring px of hover
  let (art, _) = chassisPx(parity, facing)
  # blit with the lift; source rows land lift px higher.
  # PAINTBOT tint: ctf's soldiers are one rig recoloured per team, and that
  # full-hull colour is why a rig reads at forty tiles where a neutral hull
  # plus a ground diamond does not. Same move here — the baked shading
  # (luma) keeps the volume, the team hue supplies the paint; dark sensor
  # pixels stay dark, so the code-stamped pupil keeps its contrast.
  for y in 0 ..< BodyHR:
    let sy = y - lift
    if sy < 0 or sy >= BodyHR:
      continue
    for x in 0 ..< BodyWR:
      let si = (sy * BodyWR + x) * 4
      if art[si + 3] == 0:
        continue
      let l = (int(art[si]) * 30 + int(art[si + 1]) * 59 +
               int(art[si + 2]) * 11) div 100
      let di = (y * BodyWR + x) * 4
      let tun = [int(tunic[0]), int(tunic[1]), int(tunic[2])]
      for ch in 0 .. 2:
        result[di + ch] = uint8((int(art[si + ch]) * 2 +
                                 tun[ch] * l * 3 div 255) div 5)
      result[di + 3] = art[si + 3]
  template PD(x, y: int, c: (uint8, uint8, uint8), a: uint8 = 255) =
    for oy in 0 ..< ArtScale:
      for ox in 0 ..< ArtScale:
        result.put(BodyWR, x * ArtScale + ox, y * ArtScale + oy, c, a)
  # the cog face: phosphor eyes in the visor slot, keyed to facing — state,
  # so code stamps it after the tint (the eyes never take team paint). The
  # front view gets ctf's two-eyed grin; profiles get the one eye at the
  # bow; the back shows none. Positions are the visor cells buildCog laid.
  let bob = lift div ArtScale
  case facing
  of 0:
    for ex in [1, 2, 5, 6]:                     # big paintbot eyes, two
      PD(ex, 1 + bob, PhosphorPeak)             # cells tall so they carry
      PD(ex, 2 + bob, PhosphorPeak)             # past the visor band
    PD(3, 3 + bob, Phosphor, 170)               # the grin
    PD(4, 3 + bob, Phosphor, 170)
  of 2:
    PD(5, 1 + bob, PhosphorPeak)
    PD(6, 1 + bob, PhosphorPeak)
    PD(5, 2 + bob, Phosphor, 190)
    PD(6, 2 + bob, Phosphor, 190)
  of 3:
    PD(1, 1 + bob, PhosphorPeak)
    PD(2, 1 + bob, PhosphorPeak)
    PD(1, 2 + bob, Phosphor, 190)
    PD(2, 2 + bob, Phosphor, 190)
  else:
    discard
  if parity == 1:                      # teammate pip on the shoulder
    PD(5, 7 + lift div ArtScale, PhosphorPeak)
    PD(6, 7 + lift div ArtScale, PhosphorPeak)
  # contact shadow before the diamond goes down
  result.addBacklight(BodyWR, BodyHR, StoneInk, 95, dx = RS, dy = RS)
  # ...then ctf's warm amber backlight (pixie.shadow behind every rig): a
  # 1px rim in whatever empty space the shadow left, so the silhouette pops
  # off the daylight floor instead of dissolving into it
  result.addBacklight(BodyWR, BodyHR, GoldTone, 66)
  # --- ground diamond: the team mark, unaffected by the hover bob ---
  for dy in 0 .. 5:
    let wdt = (if dy <= 2: dy + 1 else: 6 - dy)
    for dx in -wdt .. wdt:
      let c = (if dy <= 2: tunic else: shade(tunic, -34))
      PD(8 + dx, 18 + dy, c)
  for dx in -2 .. 2:                   # bright core so it reads when tiny
    PD(8 + dx, 20, shade(tunic, 30))

const
  ## Two tiles wide, one tall. These were the absolute wire values 24 and
  ## 12 — correct only at RS=2 — while the placement offset in `drawAgent`
  ## is RS-scaled, so at any other RS the wreck slid off its own death tile
  ## by (CorpseW - TilePxR) div 2. Stated in tiles it cannot drift again.
  CorpseW = 2 * TilePxR
  CorpseH = TilePxR

proc corpsePixels(team, parity: int): seq[uint8] =
  ## Decommissioned carrier: the baked chassis-neutral wreck (its width
  ## sits between the two standing silhouettes), grounded in a code-drawn
  ## shadow pool, with the darkened team diamond spilled clear of the hull
  ## and the parity pixel — state stays code-stamped.
  result = newSeq[uint8](CorpseW * CorpseH * 4)
  let tunic = shade(TeamColors[team], -60)
  template P(x, y: int, c: (uint8, uint8, uint8), a: uint8 = 255) =
    for oy in 0 ..< ArtScale:
      for ox in 0 ..< ArtScale:
        result.put(CorpseW, x * ArtScale + ox, y * ArtScale + oy, c, a)
  # shadow pool: a squashed ellipse the wreck sits in
  for y in 8 .. 11:
    let hw = (if y == 8 or y == 11: 8 else: 10)
    for x in (12 - hw) ..< (12 + hw):
      P(x, y, StoneInk, (if y >= 10: 150'u8 else: 110'u8))
  # baked hull blit (CorpseW x CorpseH is exactly the baked size), with the
  # living hull's team tint at half strength — dead paint, still theirs
  for k in 0 ..< CorpseW * CorpseH:
    if CorpseWreckPx[k * 4 + 3] > 0:
      let di = k * 4
      let l = (int(CorpseWreckPx[di]) * 30 + int(CorpseWreckPx[di + 1]) * 59 +
               int(CorpseWreckPx[di + 2]) * 11) div 100
      let tun = [int(TeamColors[team][0]), int(TeamColors[team][1]),
                 int(TeamColors[team][2])]
      for ch in 0 .. 2:
        result[di + ch] = uint8((int(CorpseWreckPx[di + ch]) * 7 +
                                 tun[ch] * l * 3 div 255) div 10)
      result[di + 3] = CorpseWreckPx[di + 3]
  if parity == 1:
    P(14, 4, (170'u8, 180'u8, 190'u8))
  # team diamond gone dark, spilled clear of the hull
  for dy in 0 .. 3:
    let wdt = (if dy <= 1: dy + 1 else: 4 - dy)
    for dx in -wdt .. wdt:
      P(19 + dx, 6 + dy, tunic)

const HeldPx = 7 * RS    # 28: the 24px stencil centered with an outline apron

proc itemColor(id: ItemId): (uint8, uint8, uint8) =
  ## One amber ramp. Killed here on 2026-08-14: blowgun (120,160,110),
  ## camouflage (90,120,70) and darts (140,200,140) — the last greens in
  ## the renderer, against §3.1 law 3 — plus first-aid's (240,80,80),
  ## which sat close enough to Klaxon Red to claim "harm" while meaning
  ## "heal". Value now separates within a shape class; the shape class
  ## does the coarse separation. See `itemShape`.
  case id
  of iSword: AmberHot        # the plainest, brightest weapon
  of iSpear: AmberMid
  of iBow: GoldTone
  of iKnives: AmberDim
  of iBlowgun: AmberDeep
  of iArrows: GoldTone
  of iDarts: AmberDim
  of iFirstAid: AmberHot
  of iRations: AmberMid
  of iNet: AmberMid
  of iBackpack: AmberDim
  of iCamo: AmberDeep
  of iNone: (255'u8, 0'u8, 255'u8)   # debug sentinel; never placed in play

proc glyphLine(px: var seq[uint8], w, x0, y0, x1, y1, t: int,
               c: (uint8, uint8, uint8)) =
  ## One thick stroke in render pixels — the primitive the held-item glyphs
  ## are drawn from now that they have a canvas big enough for strokes.
  let steps = max(max(abs(x1 - x0), abs(y1 - y0)), 1)
  for i in 0 .. steps:
    let x = x0 + (x1 - x0) * i div steps
    let y = y0 + (y1 - y0) * i div steps
    for oy in 0 ..< t:
      for ox in 0 ..< t:
        px.put(w, x + ox, y + oy, c)

type StencilRef = tuple[px: ptr UncheckedArray[uint8],
                        mask: ptr UncheckedArray[uint8], w, h: int]

proc stencilFor(id: ItemId): StencilRef =
  ## One glyph vocabulary (world.json decision): the same mark identifies
  ## an item on the ground chip, on the crate, and in a hand.
  template st(px4, m, w, h): untyped =
    (cast[ptr UncheckedArray[uint8]](unsafeAddr px4[0]),
     cast[ptr UncheckedArray[uint8]](unsafeAddr m[0]), w, h)
  case id
  of iSword: st(StencilSwordPx, StencilSwordMask, StencilSwordW, StencilSwordH)
  of iSpear: st(StencilSpearPx, StencilSpearMask, StencilSpearW, StencilSpearH)
  of iBow: st(StencilBowPx, StencilBowMask, StencilBowW, StencilBowH)
  of iKnives: st(StencilKnivesPx, StencilKnivesMask, StencilKnivesW, StencilKnivesH)
  of iBlowgun: st(StencilBlowgunPx, StencilBlowgunMask, StencilBlowgunW, StencilBlowgunH)
  of iNet: st(StencilNetPx, StencilNetMask, StencilNetW, StencilNetH)
  of iFirstAid: st(StencilFirstAidPx, StencilFirstAidMask, StencilFirstAidW, StencilFirstAidH)
  of iRations: st(StencilRationsPx, StencilRationsMask, StencilRationsW, StencilRationsH)
  of iBackpack: st(StencilBackpackPx, StencilBackpackMask, StencilBackpackW, StencilBackpackH)
  of iCamo: st(StencilCamoPx, StencilCamoMask, StencilCamoW, StencilCamoH)
  of iArrows: st(StencilArrowsPx, StencilArrowsMask, StencilArrowsW, StencilArrowsH)
  of iDarts: st(StencilDartsPx, StencilDartsMask, StencilDartsW, StencilDartsH)
  of iNone: st(StencilSwordPx, StencilSwordMask, StencilSwordW, StencilSwordH)   # never drawn; a valid ref keeps this total

proc wrect(px: var seq[uint8], x0, y0, x1, y1: int,
           c: (uint8, uint8, uint8), a: uint8 = 255) =
  for y in y0 .. y1:
    for x in x0 .. x1:
      px.put(HeldPx, x, y, c, a)

proc heldWeaponPixels(id: ItemId, mirror = false): seq[uint8] =
  ## Held-item art (PAINTBOT pass 3): ctf's rigs carry OBJECTS — a gun you
  ## can name at a glance, not a shrunken icon (the 24px stencil reductions
  ## read as blobs in a hand; they stay the chip/crate vocabulary). Each
  ## item is drawn as a chunky object in three materials: Bone steel for
  ## blades, the amber ramp for wood and matter, gunmetal for tubes — over
  ## an ink outline so it separates from any hull and the daylight floor.
  ## Authored pointing east; the west hand gets the horizontal mirror.
  ## Coordinates are raw render px on the 28px canvas (HeldPx tracks RS,
  ## so the guard below keeps a silent RS change from shearing the art).
  static: doAssert HeldPx == 28
  result = newSeq[uint8](HeldPx * HeldPx * 4)
  const Steel = Bone                      # blade-bright, reads on any hull
  const Metal = (74'u8, 78'u8, 86'u8)
  template L(ax0, ay0, ax1, ay1, t: int, c: (uint8, uint8, uint8)) =
    glyphLine(result, HeldPx, ax0, ay0, ax1, ay1, t, c)
  case id
  of iSword:
    L(4, 24, 8, 20, 3, AmberDeep)                 # grip
    L(8, 20, 24, 4, 3, Steel)                     # blade
    L(6, 15, 13, 22, 3, GoldTone)                 # crossguard
  of iSpear:
    L(2, 15, 21, 15, 2, AmberMid)                 # shaft
    L(21, 11, 26, 15, 2, Steel)                   # head
    L(21, 19, 26, 15, 2, Steel)
    L(20, 15, 26, 15, 2, Steel)
  of iBow:
    L(22, 7, 22, 21, 2, AmberMid)                 # belly
    L(15, 3, 22, 8, 2, AmberMid)                  # limbs
    L(15, 25, 22, 20, 2, AmberMid)
    L(15, 4, 15, 24, 1, Steel)                    # string
  of iKnives:
    L(4, 23, 8, 19, 2, AmberDeep)                 # grips under blades
    L(12, 26, 16, 22, 2, AmberDeep)
    L(6, 21, 15, 12, 2, Steel)
    L(14, 24, 23, 15, 2, Steel)
  of iBlowgun:
    L(3, 14, 24, 14, 3, Metal)                    # tube
    result.wrect(2, 12, 5, 17, Steel)             # mouthpiece
    result.wrect(13, 12, 15, 17, GoldTone)        # grip band
  of iNet:
    for i in 0 .. 2:
      L(7 + i * 6, 7, 7 + i * 6, 21, 1, AmberMid)
      L(7, 7 + i * 6, 21, 7 + i * 6, 1, AmberMid)
    for cx in [6, 20]:                            # corner weights
      for cy in [6, 20]:
        result.wrect(cx, cy, cx + 2, cy + 2, AmberDeep)
  of iFirstAid:
    result.wrect(6, 9, 22, 23, Steel)             # kit box
    result.wrect(12, 11, 16, 21, GoldTone)        # amber cross (red = harm)
    result.wrect(8, 14, 20, 18, GoldTone)
  of iRations:
    result.wrect(6, 12, 22, 24, AmberMid)         # tin
    result.wrect(6, 12, 22, 14, AmberHot)         # lid glint
    result.wrect(12, 8, 16, 12, Metal)            # cap
  of iBackpack:
    result.wrect(7, 10, 21, 25, AmberDeep)        # body
    result.wrect(7, 10, 21, 15, AmberMid)         # flap
    result.wrect(13, 14, 15, 18, GoldTone)        # buckle
  of iCamo:
    result.wrect(6, 10, 22, 24, (150'u8, 170'u8, 185'u8), 200)
    L(6, 12, 22, 22, 1, Steel)                    # fold line
  of iArrows:
    for yy in [9, 15, 21]:
      L(4, yy, 20, yy, 1, AmberMid)
      L(20, yy, 25, yy, 2, Steel)                 # heads
      result.wrect(4, yy - 1, 6, yy + 1, GoldTone)
  of iDarts:
    for yy in [12, 19]:
      L(6, yy, 18, yy, 1, AmberDim)
      L(18, yy, 24, yy, 2, Steel)
  of iNone:
    discard                                       # never drawn
  if mirror:
    for y in 0 ..< HeldPx:
      for x in 0 ..< HeldPx div 2:
        let a = (y * HeldPx + x) * 4
        let b = (y * HeldPx + (HeldPx - 1 - x)) * 4
        for ch in 0 .. 3:
          swap(result[a + ch], result[b + ch])
  result.addBacklight(HeldPx, HeldPx, StoneInk, 235)

proc dimmed(px: seq[uint8], mul: int): seq[uint8] =
  ## Alpha-scaled copy for a baked fade stage.
  result = px
  var i = 3
  while i < result.len:
    result[i] = uint8(int(result[i]) * mul div 255)
    i += 4

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

proc tintedBurstStar(tint: (uint8, uint8, uint8)): seq[uint8] =
  ## The baked burst star is a SHAPE — the generation is near-black ink on
  ## key, so its alpha mask carries the rays and its pixel values carry
  ## nothing. The tint paints the mask at full strength with a radial
  ## falloff (core solid, tips breaking up), and a peak-white core dot so
  ## the beat reads as a flash, not a sticker.
  result = newSeq[uint8](BurstStarW * BurstStarH * 4)
  let c = BurstStarW div 2
  for y in 0 ..< BurstStarH:
    for x in 0 ..< BurstStarW:
      let k = y * BurstStarW + x
      let a = int(BurstStarPx[k * 4 + 3])
      if a == 0:
        continue
      let dx = x - c
      let dy = y - c
      let d2 = dx * dx + dy * dy
      let fall = 255 - min(200, d2 * 200 div (c * c))
      let core = d2 * 9 < c * c
      let col = (if core: PhosphorPeak else: tint)
      result.put(BurstStarW, x, y, col, uint8(a * fall div 255))

proc resample3to2(px: seq[uint8], w, h: int): seq[uint8] =
  ## Exact 2/3 box resample (72 -> 48 for the mine burst): duplicate to
  ## 2x, then 3x3 box — all integer, deterministic.
  let ow = w * 2 div 3
  let oh = h * 2 div 3
  result = newSeq[uint8](ow * oh * 4)
  for oy in 0 ..< oh:
    for ox in 0 ..< ow:
      var acc: array[4, int]
      for sy in 0 ..< 3:
        for sx in 0 ..< 3:
          # position in the virtual 2x-duplicated grid, mapped back
          let gx = (ox * 3 + sx) div 2
          let gy = (oy * 3 + sy) div 2
          let si = (min(gy, h - 1) * w + min(gx, w - 1)) * 4
          for ch in 0 .. 3:
            acc[ch] += int(px[si + ch])
      for ch in 0 .. 3:
        result[(oy * ow + ox) * 4 + ch] = uint8(acc[ch] div 9)

proc decompFrame(parity, frame: int): seq[uint8] =
  ## One frame of the death decomposition: pixels of the baked body
  ## scatter into the tile — a process being freed. Frame 0 is the body
  ## exactly; each later frame frees another hash class of pixels, which
  ## drift down and outward as fading embers.
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  let (art, _) = chassisPx(parity, 0)
  for y in 0 ..< BodyHR:
    for x in 0 ..< BodyWR:
      let si = (y * BodyWR + x) * 4
      if art[si + 3] == 0:
        continue
      let cls = pixHash(x * 3 + 1, y * 5 + 2) mod DecompFrames
      if cls >= frame:
        # still part of the body
        let di = si
        result[di] = art[si]; result[di+1] = art[si+1]
        result[di+2] = art[si+2]; result[di+3] = art[si+3]
      else:
        # freed: drifting ember, fading with age
        let t = frame - cls
        let dx = (pixHash(x * 7 + 3, y * 11 + 5) mod 3) - 1
        let nx = x + dx * t
        let ny = y + t
        if nx >= 0 and nx < BodyWR and ny < BodyHR:
          let al = max(0, 210 - t * 60)
          if al > 0:
            result.put(BodyWR, nx, ny, PhosphorPeak, uint8(al))

proc plasmaPixels(phase: int, crit: bool): seq[uint8] =
  ## Swirling plasma wall: teal (stages 1-4) or crimson (endgame).
  ## Native at RS: the band widths are stated in render pixels, so the
  ## diagonal is a clean edge instead of the ×RS staircase the 6x6 version
  ## became. The period is a whole tile in the (2x + y) metric — one tile
  ## right adds 2*TilePxR, one tile down adds TilePxR, both ≡ 0 — so the
  ## ring is one continuous hatch with no seam where the tiles butt. At 1x
  ## the bands were 5 px on a 6 px tile and every joint showed.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let hotC = (if crit: Klaxon else: RingMagenta)
  let coldC = shade(hotC, -110)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let swirl = (x * 2 + y + phase * 2 * RS) mod TilePxR
      if swirl < RS:
        result.put(TilePxR, x, y, (255'u8, 255'u8, 255'u8), 210)
      elif swirl < 3 * RS:
        result.put(TilePxR, x, y, hotC, 190)
      else:
        result.put(TilePxR, x, y, coldC, 150)

proc floodPixels(phase: int): seq[uint8] =
  ## Commanded-flood fluid. Hash dither breaks the crest lattice so the
  ## surface reads as moving liquid instead of a repeating hatch. Native at
  ## RS: crest spacing and thickness are render pixels, and the dither is
  ## sampled per render pixel, so the field gains grain instead of ×RS
  ## blocks. Reduces to the old field exactly at RS=1.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let n = pixHash(x * 3 + phase * 29, y * 5 + phase * 17) mod 5
      let crest = (x + y * 2 + (phase * 3 + n) * RS) mod (6 * RS) < RS
      result.put(TilePxR, x, y,
        (if crest: (255'u8, 160'u8, 205'u8) else: RingMagenta),
        (if crest: 220'u8 else: uint8(132 + n * 6)))

proc stormPixels(phase: int): seq[uint8] =
  ## Firestorm: dithered density rather than a checkerboard, so overlapping
  ## tiles merge into one field instead of showing their tile seams. Native
  ## at RS — the dither is the art here, so sampling it per render pixel is
  ## the whole point; at 1x it was ×RS blocks of embers.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let n = pixHash(x * 7 + phase * 13, y * 11 + phase * 23) mod 100
      if n < 55:
        ## Klaxon, not a bespoke orange. Firestorm is harm happening now,
        ## which is exactly Klaxon's contract (§3.1); (255,90,30) was a
        ## tenth colour that meant the same thing as one we already had.
        result.put(TilePxR, x, y, Klaxon, uint8(90 + (n mod 5) * 12))

proc podCratePixels(id: ItemId): seq[uint8] =
  ## Baked chamfered amber crate, identified by its contents stencil —
  ## the same mark the ground chip wears, so a contested drop stays
  ## identified after touchdown without a label.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  result.compositeBaked(TilePxR, 0, 0, CrateBodyPx, CrateBodyW, CrateBodyH)
  let stn = stencilFor(id)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      if x < stn.w and y < stn.h and stn.mask[y * stn.w + x] > 0:
        result.put(TilePxR, x, y, StoneInk)
  # grounded like every ctf prop: contact shadow first, warm rim after
  result.addBacklight(TilePxR, TilePxR, StoneInk, 110, dx = RS, dy = RS)
  result.addBacklight(TilePxR, TilePxR, GoldTone, 80)

proc bushPixels(berries: int): seq[uint8] =
  ## Baked crystal clump (Tier A); the berries stay code — charges are
  ## gameplay state and must stay countable (ART_UPGRADE_PLAN §2).
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  result.compositeBaked(TilePxR, 0, 0, BushClumpPx, BushClumpW, BushClumpH)
  result.addBacklight(TilePxR, TilePxR, StoneInk, 100, dx = RS, dy = RS)
  const spots = [(2, 4), (7, 2), (5, 8)]
  for i in 0 ..< min(berries, 3):
    let bx = spots[i][0] * ArtScale
    let by = spots[i][1] * ArtScale
    for oy in 0 ..< RS:
      for ox in 0 ..< RS:
        result.put(TilePxR, bx + ox, by + oy, GoldTone)
    result.put(TilePxR, bx, by, AmberHot)

proc unionBodyMask(): array[BodyWR * BodyHR, uint8] =
  ## Union of both chassis' front alpha masks. The camo glass, glitch tear
  ## and hit flash are shared sprites worn by every agent, so they cover
  ## the union — derived from the baked art itself (ART_UPGRADE_PLAN §4.3,
  ## risk 3): the flash cannot miss the body it is flashing.
  for k in 0 ..< BodyWR * BodyHR:
    if CogArt[0][0][1][k] > 0 or CogArt[1][0][1][k] > 0:
      result[k] = 255

let BodyMask = unionBodyMask()

proc maskRowSpan(y: int): (int, int) =
  ## Leftmost/rightmost masked column of a row, (-1, -1) when empty.
  var lo = -1
  var hi = -1
  for x in 0 ..< BodyWR:
    if BodyMask[y * BodyWR + x] > 0:
      if lo < 0: lo = x
      hi = x
  (lo, hi)

proc glassBodyPixels(): seq[uint8] =
  ## Camo: refractive carrier silhouette — faint rim, near-clear fill,
  ## traced from the baked bodies' union mask.
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  var top = BodyHR
  var bot = -1
  for y in 0 ..< BodyHR:
    if maskRowSpan(y)[0] >= 0:
      if y < top: top = y
      bot = y
  for y in 0 ..< BodyHR:
    let (lo, hi) = maskRowSpan(y)
    if lo < 0:
      continue
    for x in lo .. hi:
      let edge = x < lo + ArtScale or x > hi - ArtScale or
                 y < top + ArtScale or y > bot - ArtScale
      result.put(BodyWR, x, y, (200'u8, 235'u8, 255'u8),
                 (if edge: 96'u8 else: 30'u8))

proc netMeshPixels(): seq[uint8] =
  ## Restraint mesh, native: a woven grid with knots at the crossings, so
  ## it reads as rope over the carrier rather than a diagonal hatch.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let cord = (150'u8, 170'u8, 185'u8)
  let step = TilePxR div 3
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let onV = x mod step < RS div 2 + 1
      let onH = y mod step < RS div 2 + 1
      if onV or onH:
        let knot = onV and onH
        result.put(TilePxR, x, y,
                   (if knot: shade(cord, 34) else: cord),
                   (if knot: 235'u8 else: 190'u8))

proc poisonHaloPixels(phase: int): seq[uint8] =
  ## Airborne toxin, native: a dithered mist annulus that drifts with the
  ## pulse phase instead of a hard dashed ring.
  const Sz = 10 * RS
  result = newSeq[uint8](Sz * Sz * 4)
  let outer = 9 * RS
  let inner = 6 * RS
  for y in 0 ..< Sz:
    for x in 0 ..< Sz:
      let dx = x * 2 + 1 - Sz
      let dy = y * 2 + 1 - Sz
      let d2 = dx * dx + dy * dy
      if d2 > inner * inner and d2 <= outer * outer and
         pixHash(x * 9 + phase * 31, y * 7 + phase * 19) mod 100 < 55:
        # thin out toward the rim so the cloud has an edge, not a cut
        let far = d2 > (outer - RS * 2) * (outer - RS * 2)
        result.put(Sz, x, y, Klaxon, (if far: 84'u8 else: 140'u8))

proc voidBeamPixels(): seq[uint8] =
  ## Vertical dark energy beam (death marker), native: a bright core with
  ## violet flanks that both taper as the column rises.
  const W = 6 * RS
  const H = 48 * RS
  result = newSeq[uint8](W * H * 4)
  for y in 0 ..< H:
    let a = 200 - (y * 300) div H
    if a <= 0:
      continue
    for x in 0 ..< W:
      let fromEdge = min(x, W - 1 - x)
      if fromEdge < RS:
        result.put(W, x, y, (110'u8, 30'u8, 140'u8), uint8(a div 2))
      else:
        result.put(W, x, y, (8'u8, 4'u8, 12'u8), uint8(a))

proc goldBeamPixels(): seq[uint8] =
  ## Delivery beam, native: twin bright rails with downward-scrolling
  ## hatch between them — a printer feed, not a spotlight.
  const W = 8 * RS
  const H = 54 * RS
  result = newSeq[uint8](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let fromEdge = min(x, W - 1 - x)
      if fromEdge < RS:
        result.put(W, x, y, GoldTone, 180)
      elif fromEdge < RS * 2:
        result.put(W, x, y, shade(GoldTone, 20), 70)
      elif (y + x) mod (6 * RS) < RS:
        result.put(W, x, y, shade(GoldTone, 40), 95)

proc glitchPixels(): seq[uint8] =
  ## Camo-reveal artifact: horizontal tear bands across the hull, which
  ## reads as a decode failure rather than confetti. Scanlines come from
  ## the baked bodies' union mask, shifted sideways per row.
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  for y in 0 ..< BodyHR:
    let (lo, hi) = maskRowSpan(y)
    if lo < 0:
      continue
    let band = pixHash(y * 13, 7) mod 100
    if band < 45:
      continue                       # untorn scanline
    let shift = (pixHash(y * 7, 3) mod (RS * 3)) - RS
    for x in (lo + shift) .. (hi + shift):
      let n = pixHash(x * 3 + 1, y * 5 + 2)
      result.put(BodyWR, x, y,
        (if n mod 3 == 0: Klaxon else: PhosphorPeak),
        (if n mod 2 == 0: 235'u8 else: 160'u8))

proc mouthLightPixels(phase: int): seq[uint8] =
  ## Light pooling in a Fortress mouth, native: brightest at the tile
  ## centre and falling off to the edges, so the four gates glow rather
  ## than flicker as flat patches.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let mid = TilePxR div 2
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let d = abs(x - mid) + abs(y - mid)
      if (x + y + phase) mod 3 == 0:
        continue                       # dither keeps it volumetric
      let a = max(0, 120 - d * 70 div TilePxR)
      result.put(TilePxR, x, y, shade(GoldTone, 30), uint8(a))

proc trailPixels(id: ItemId): seq[uint8] =
  ## Fading combat vector trail, native: a tapered streak, brightest at
  ## the head, rather than a flat one-pixel line.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let c =
    case id
    of iArrows: (255'u8, 255'u8, 255'u8)
    of iDarts: Klaxon
    else: (200'u8, 200'u8, 215'u8)
  let mid = TilePxR div 2
  for x in 0 ..< TilePxR:
    let a = 60 + x * 90 div TilePxR    # brightens toward the head
    for o in 0 ..< RS:
      result.put(TilePxR, x, mid + o - RS div 2, c, uint8(a))
    if x > TilePxR div 3:              # feathered edges near the head
      result.put(TilePxR, x, mid - RS, c, uint8(a div 3))
      result.put(TilePxR, x, mid + RS, c, uint8(a div 3))
  if id == iDarts:                     # poison vapor drags a second line
    for x in 0 ..< TilePxR:
      result.put(TilePxR, x, mid + RS + RS div 2, c, 70)

type
  ItemShape = enum
    ## Chip silhouette. With hue spent (everything is amber now) and value
    ## carrying only four steps, shape is the widest identity channel left
    ## on a 24px chip. Four classes, four outlines — a coarse read that
    ## survives at 1:1, which the Phase 5 stencil then refines to the item.
    shGem      ## weapons — the bevelled diamond, kept from the old chip
    shBolt     ## ammunition — narrow, pointed, reads as a stack of shafts
    shCase     ## consumables — chamfered square, a supply box
    shPack     ## gear/utility — wide flattened hex, a carried bundle

proc itemShape(id: ItemId): ItemShape =
  case id
  of iSword, iSpear, iBow, iKnives, iBlowgun: shGem
  of iArrows, iDarts: shBolt
  of iFirstAid, iRations: shCase
  of iNet, iBackpack, iCamo: shPack
  of iNone: shGem

proc inItemShape(shape: ItemShape, ex, ey, rr: int): bool =
  ## Membership test in the doubled edge space `itemPixels` works in
  ## (ex, ey odd, |.| < TilePxR), with `rr` the diamond's radius budget.
  ## Each class is sized to carry roughly the gem's visual weight so no
  ## item silently becomes the big one on the board.
  let ax = abs(ex)
  let ay = abs(ey)
  case shape
  of shGem:
    ax + ay <= rr
  of shBolt:
    ## narrow and pointed: a stack of shafts stood on end. The half-width
    ## closes toward the top so the tip is a point, not a flat cap.
    ay <= rr * 9 div 10 and
      ax * 20 <= rr * 7 * (rr + ey + rr div 3) div (rr + rr div 3)
  of shCase:
    ## chamfered square — the corner cut is what keeps it from reading as
    ## "untextured tile" at 1:1.
    max(ax, ay) <= rr * 62 div 100 and ax + ay <= rr * 96 div 100
  of shPack:
    ## wide flattened hex, squat enough to never be confused with the gem.
    ay <= rr * 46 div 100 and ax <= rr * 78 div 100 and
      ax * 6 + ay * 10 <= rr * 78 div 100 * 6 + rr * 20 div 100

proc itemPixels(id: ItemId): seq[uint8] =
  ## Ground chip: the baked amber diamond plus the contents stencil in
  ## ink. Hue no longer carries identity (Phase 2 spent it on the amber
  ## contract); the mark does — and it is the same mark everywhere.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  result.compositeBaked(TilePxR, 0, 0, ChipBodyPx, ChipBodyW, ChipBodyH)
  let stn = stencilFor(id)
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      if x < stn.w and y < stn.h and stn.mask[y * stn.w + x] > 0 and
         result[(y * TilePxR + x) * 4 + 3] > 0:
        result.put(TilePxR, x, y, StoneInk)
  # amber on warm concrete needs the ink edge the cold slate gave for free
  result.addBacklight(TilePxR, TilePxR, StoneInk, 120, dx = ArtScale,
                      dy = ArtScale)

const ProjPx = 4 * RS

proc projPixels(id: ItemId): seq[uint8] =
  ## In flight: a bolt, not a bar. Authored natively at RS so the head can
  ## be a point and the tail can taper — at 1x this was a 4x2 rectangle of
  ## flat colour blown up to 16x8, the crudest thing on the board.
  ## The travel direction is still always east (see `trailPixels`);
  ## rotation is deferred with it.
  result = newSeq[uint8](ProjPx * ProjPx * 4)
  let c = itemColor(id)
  let mid = ProjPx div 2
  let t = max(1, ArtScale)
  for x in 0 ..< ProjPx:
    # thickness grows toward the head, so the shape reads as a vector
    let half = max(t, (t * 2 * (x + 1) + ProjPx - 1) div ProjPx)
    for y in (mid - half) ..< (mid + half):
      let head = x >= ProjPx - t
      result.put(ProjPx, x, y, (if head: PhosphorPeak else: c),
                 (if x < t: 150'u8 else: 255'u8))

proc hpBandPixels(band: int): seq[uint8] =
  ## Three pips over each agent (ctf's under-name health pips): count AND
  ## colour encode the wire's hp_band (healthy/hurt/critical) — no green
  ## anywhere. Pips read as discrete state on the daylight floor where the
  ## old solid bar read as a smear; spent pips keep an ink socket so the
  ## gauge's full extent stays visible.
  result = newSeq[uint8](10 * 3 * 4)
  let (lit, c) =
    case band
    of 0: (3, (165'u8, 227'u8, 238'u8))    # healthy: phosphor
    of 1: (2, (255'u8, 180'u8, 84'u8))     # hurt: amber
    else: (1, (255'u8, 74'u8, 54'u8))      # critical: klaxon
  for p in 0 ..< 3:
    let ox = p * 4
    for y in 0 ..< 2:
      for x in 0 ..< 2:
        if p < lit:
          result.put(10, ox + x, y, (if y == 0: shade(c, 40) else: c))
        else:
          result.put(10, ox + x, y, (10'u8, 13'u8, 17'u8), 190)

proc ringGhostPixels(): seq[uint8] =
  ## Faint bone outline tile; every-other tile placement dashes the circle.
  ## Native at RS: the outline is one *authoring* pixel thick (ArtScale
  ## render px) rather than a whole ×RS block, so the preview stays a hair
  ## line as the board grows instead of thickening with it.
  ## Directive Magenta as of Phase 2. §3.7 makes the *target* radius a
  ## dashed magenta circle, and §3.1 reserves magenta for commanded
  ## geometry — a bone preview said "record", which is Bone's contract
  ## (the settlement rule), not the ring's.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let t = max(1, ArtScale)
  for i in 0 ..< TilePxR:
    for k in 0 ..< t:
      result.put(TilePxR, i, k, RingMagenta, 130)
      result.put(TilePxR, i, TilePxR - 1 - k, RingMagenta, 130)
      result.put(TilePxR, k, i, RingMagenta, 130)
      result.put(TilePxR, TilePxR - 1 - k, i, RingMagenta, 130)

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

const LabelMax = 8         # in-world tags sit over a 24px tile; past 8 chars
                           # at the 3x5 face's 4px advance they collide with
                           # the next agent's tag

proc glyphSafe(ch: char): char =
  ## Fold one character into the 41-glyph set both faces share
  ## (0-9 A-Z : - > . space). Anything else draws as a blank advance, so it
  ## becomes a space here and gets collapsed away instead of eating width.
  if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32)
  elif (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9'): ch
  elif ch in {':', '-', '>', '.'}: ch
  else: ' '

proc slotLabel*(name: string, slot: int): string =
  ## On-screen identity for one seat, from the display name the platform
  ## injects into game_config.players[].name (sim.nim parses it into
  ## cfg.playerNames; obs/transcript/analyst already use it).
  ##
  ## Hosted rounds resolve these to real usernames and disambiguate repeats of
  ## one policy with " (2)", " (3)" ... — twelve filler seats arrive as
  ## Baseline, Baseline (2), ... Baseline (12), where that tail is the ONLY
  ## thing telling them apart. So the tail survives truncation and the stem
  ## gives way: BASELIN5, BASELI12.
  var cleaned: string
  for ch in name:
    let g = glyphSafe(ch)
    if g == ' ':
      if cleaned.len > 0 and cleaned[^1] != ' ': cleaned.add(' ')
    else:
      cleaned.add(g)
  while cleaned.len > 0 and cleaned[^1] == ' ': cleaned.setLen(cleaned.len - 1)
  if cleaned.len == 0:
    return "P" & $slot
  var stem = cleaned
  var tail = ""
  var i = cleaned.len
  while i > 0 and cleaned[i - 1] >= '0' and cleaned[i - 1] <= '9': dec i
  if i > 0 and i < cleaned.len and cleaned[i - 1] == ' ':
    tail = cleaned[i .. ^1]
    stem = cleaned[0 ..< i - 1]
  if tail.len >= LabelMax:
    return tail[0 ..< LabelMax]
  let room = LabelMax - tail.len
  if stem.len > room: stem = stem[0 ..< room]
  stem & tail

proc slotLabel*(s: Sim, slot: int): string =
  if slot >= 0 and slot < s.cfg.playerNames.len:
    slotLabel(s.cfg.playerNames[slot], slot)
  else:
    "P" & $slot

proc shortLabel*(slot: int): string =
  ## Crowded fallback: team letter + which of the duo, so A1/A2 are the two
  ## contestants of team A. Two characters is ~a third of a tile, narrow
  ## enough that a cluster cannot stack into a wall, and it keeps identity
  ## off team hue alone for CVD viewers (VISUAL_REDESIGN Part 8.1).
  if slot < 0 or slot > 15: return "??"
  TeamNames[slot div 2] & $(slot mod 2 + 1)

proc plateX*(tileX: int, label: string): int =
  ## Centre a text plate on the agent's tile. textPixels is 2px of plate plus
  ## 4px per glyph, and the tile is TileSize wide in 1x space; the old fixed
  ## -3 offset was tuned for 3-character "P<n>" and left an 8-character name
  ## sitting a full tile-and-a-half to the right of its carrier.
  tileX * TileSize + TileSize div 2 - (2 + label.len * 4) div 2

proc plateWidth*(label: string): int =
  ## textPixels lays out 2px of plate plus 4px per glyph.
  2 + label.len * 4

proc platesOverlap*(tileX1: int, label1: string,
                    tileX2: int, label2: string): bool =
  ## Do two identity plates on the same row band share any column?
  let a = plateX(tileX1, label1)
  let b = plateX(tileX2, label2)
  a < b + plateWidth(label2) and b < a + plateWidth(label1)

proc clipCols(line: string, cols: int): string =
  if line.len <= cols: line else: line[0 ..< cols]

proc ensureLabels(r: var Renderer, s: Sim) =
  ## Seat labels are fixed for the whole match, so build them once. They are
  ## cached on the Renderer because etchScar has no Sim in scope.
  if r.labelsReady: return
  for i in 0 .. 15: r.labels[i] = slotLabel(s, i)
  r.labelsReady = true

const
  TalkChipTtl = 60     # 2.5 s at 24 Hz
  TalkChipMax = 24     # chars of message after the speaker tag

proc talkSafe(text: string): string =
  ## 3x5-font-safe chip text: uppercase, unsupported glyphs become spaces,
  ## space runs collapse, hard cap so a monologue can't span the arena.
  var prevSpace = true
  for ch in text:
    if result.len >= TalkChipMax:
      break
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    if (up >= '0' and up <= '9') or (up >= 'A' and up <= 'Z') or
       up in {':', '-', '>', '.'}:
      result.add(up)
      prevSpace = false
    elif not prevSpace:
      result.add(' ')
      prevSpace = true
  while result.len > 0 and result[^1] == ' ':
    result.setLen(result.len - 1)

proc reticlePixels(): seq[uint8] =
  ## Amber drop-targeting reticle: corner brackets + center mark — the
  ## sponsor console's grammar stamped into the arena itself. Native at RS:
  ## the brackets keep their proportions (a third of the tile long, one
  ## authoring pixel thick) rather than growing into ×RS bars.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let m = TilePxR - 1
  let t = max(1, ArtScale)          # stroke weight
  let arm = TilePxR div 3           # bracket length
  for i in 0 ..< arm:
    for k in 0 ..< t:
      result.put(TilePxR, i, k, GoldTone)
      result.put(TilePxR, k, i, GoldTone)
      result.put(TilePxR, m - i, k, GoldTone)
      result.put(TilePxR, m - k, i, GoldTone)
      result.put(TilePxR, i, m - k, GoldTone)
      result.put(TilePxR, k, m - i, GoldTone)
      result.put(TilePxR, m - i, m - k, GoldTone)
      result.put(TilePxR, m - k, m - i, GoldTone)
  for oy in 0 ..< t:                # center mark
    for ox in 0 ..< t:
      result.put(TilePxR, TilePxR div 2 + ox, TilePxR div 2 + oy,
                 GoldTone, 230)

proc cratePartPixels(rows: int): seq[uint8] =
  ## Crate rastering in top-to-bottom under the beam — a row-slice of the
  ## baked crate body with an amber print-head line, which is what fixes
  ## the touchdown pop: the finished print IS the crate.
  result = newSeq[uint8](TilePxR * TilePxR * 4)
  let done = min(rows * RS, TilePxR)
  for y in 0 ..< done:
    for x in 0 ..< TilePxR:
      let si = (y * CrateBodyW + x) * 4
      if CrateBodyPx[si + 3] > 0:
        result[(y * TilePxR + x) * 4] = CrateBodyPx[si]
        result[(y * TilePxR + x) * 4 + 1] = CrateBodyPx[si + 1]
        result[(y * TilePxR + x) * 4 + 2] = CrateBodyPx[si + 2]
        result[(y * TilePxR + x) * 4 + 3] = 255
  if done < TilePxR:
    for x in 0 ..< TilePxR:
      result.put(TilePxR, x, done, AmberHot)

proc pingPixels(big: bool): seq[uint8] =
  ## Expanding contested-crate ping. Authored natively so the ring is a
  ## smooth circle with an antialiased rim instead of a jagged annulus.
  const Sz = 12 * RS
  result = newSeq[uint8](Sz * Sz * 4)
  let rr = (if big: 10 * RS else: 6 * RS)
  let inner = rr - 2 * RS
  for y in 0 ..< Sz:
    for x in 0 ..< Sz:
      let dx = x * 2 + 1 - Sz
      let dy = y * 2 + 1 - Sz
      let d2 = dx * dx + dy * dy
      if d2 > inner * inner and d2 <= rr * rr:
        # feather the outermost band so the curve reads round
        let outer = d2 > (rr - RS) * (rr - RS)
        let a = (if big: 90 else: 150) div (if outer: 2 else: 1)
        result.put(Sz, x, y, GoldTone, uint8(a))

proc hitFlashPixels(): seq[uint8] =
  ## 1-frame peak-white carrier silhouette on any damage taken — the
  ## union mask dilated by one authoring pixel, so the rim reads and the
  ## flash covers either chassis by construction.
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  for y in 0 ..< BodyHR:
    let (lo, hi) = maskRowSpan(y)
    if lo < 0:
      continue
    for x in max(0, lo - ArtScale) .. min(BodyWR - 1, hi + ArtScale):
      result.put(BodyWR, x, y, PhosphorPeak, 185)

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

proc tagPixels(text: string): (int, int, seq[uint8]) =
  ## PAINTBOT identity tag: bone-bright glyphs in a full ink outline and no
  ## plate — ctf's name labels float over the board and stay readable on any
  ## material without boxing off half the arena. Same layout economy as
  ## textPixels (2px margin + 4px advance), so plateX/plateWidth and the
  ## tagCrowded geometry stay honest without change.
  let w = 2 + text.len * 4
  let h = 7
  var px = newSeq[uint8](w * h * 4)
  for i, ch in text:
    let up = (if ch >= 'a' and ch <= 'z': chr(ord(ch) - 32) else: ch)
    let bits = Glyphs.getOrDefault(up, 0)
    for gy in 0 ..< 5:
      for gx in 0 ..< 3:
        if ((bits shr ((4 - gy) * 3 + (2 - gx))) and 1) == 1:
          px.put(w, 1 + i * 4 + gx, 1 + gy, (244'u8, 242'u8, 234'u8))
  # translucent ink chip behind the glyphs — the board reads through it. A
  # true 1px outline is not available at this face's 4px advance (dilation
  # fills every gap and rebuilds the solid plate), so the chip carries the
  # contrast and its transparency is what makes the tag float, ctf-style.
  let ink = (26'u8, 22'u8, 16'u8)
  for y in 0 ..< h:
    for x in 0 ..< w:
      if alphaAt(px, w, x, y) < 128:
        px.put(w, x, y, ink, 165)
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

proc lampRowPixels(mask, n: int): seq[uint8] =
  ## One lamp per seated player: lit phosphor = alive, cold etch = settled.
  ## The row shrinks with num_players; the sprite keeps its HUD footprint.
  result = newSeq[uint8](81 * 6 * 4)
  for i in 0 ..< n:
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

## The persistence buffers are the board at render scale. They used to be
## WorldPx square and were nearest-neighbour blown up on the way out, which
## cost the Knowledge Layer the one thing it is: the vision disc is an
## analytic circle (VISUAL_REDESIGN law 1) and a x4 upscale gives it a
## staircase rim. Stamps and scars are tile-granular either way.
proc ensureTrace(r: var Renderer) =
  if r.trace.len == 0:
    r.trace = newSeq[uint32](WorldPxR * WorldPxR)
    r.scars = newSeq[uint32](WorldPxR * WorldPxR)

proc stampTrace(r: var Renderer, tileX, tileY: int,
                c: (uint8, uint8, uint8), a: uint8) =
  let ox = tileX * TilePxR + RS
  let oy = tileY * TilePxR + RS
  for y in 0 ..< TilePxR - 2 * RS:
    for x in 0 ..< TilePxR - 2 * RS:
      let i = (oy + y) * WorldPxR + ox + x
      if i >= 0 and i < r.trace.len:
        if uint32(a) > (r.trace[i] and 0xFF):
          r.trace[i] = (uint32(c[0]) shl 24) or (uint32(c[1]) shl 16) or
                       (uint32(c[2]) shl 8) or uint32(a)
  r.traceActive = true

proc etchScar(r: var Renderer, slot: int, pos: Pos) =
  ## Burn-in: team-tinted floor scar plus the slot glyph, for the rest
  ## of the match. Rendered under live entities (overlay sits at z=3).
  let tc = TeamColors[slot div 2]
  let ox = pos.x * TilePxR
  let oy = pos.y * TilePxR
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let i = (oy + y) * WorldPxR + ox + x
      if i >= 0 and i < r.scars.len and (r.scars[i] and 0xFF) < 45:
        r.scars[i] = (uint32(tc[0]) shl 24) or (uint32(tc[1]) shl 16) or
                     (uint32(tc[2]) shl 8) or 45'u32
  ## The slot glyph keeps its physical size: one font pixel is RS render
  ## pixels, so the etch reads the same next to a 24 px tile as it did next
  ## to a 6 px one. A crisper cut is the Phase-2 font job, not this.
  let label = r.labels[slot]
  var gx = ox + TilePxR + RS
  for ch in label:
    let bits = Glyphs.getOrDefault(ch, 0)
    for yy in 0 ..< 5:
      for xx in 0 ..< 3:
        if ((bits shr ((4 - yy) * 3 + (2 - xx))) and 1) == 1:
          for sy in 0 ..< RS:
            for sx in 0 ..< RS:
              let i = (oy + yy * RS + sy) * WorldPxR + gx + xx * RS + sx
              if i >= 0 and i < r.scars.len:
                r.scars[i] = (uint32(Bone[0]) shl 24) or
                             (uint32(Bone[1]) shl 16) or
                             (uint32(Bone[2]) shl 8) or 85'u32
    gx += 4 * RS
  r.traceActive = true

proc traceSpritePixels(r: Renderer, s: Sim): seq[uint8] =
  result = newSeq[uint8](WorldPxR * WorldPxR * 4)
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
      let vr = (5 + (a.stats.intelligence + 1) div 2) * TilePxR
      let cx = a.pos.x * TilePxR + TilePxR div 2
      let cy = a.pos.y * TilePxR + TilePxR div 2
      for y in max(0, cy - vr) .. min(WorldPxR - 1, cy + vr):
        for x in max(0, cx - vr) .. min(WorldPxR - 1, cx + vr):
          let dx = x - cx
          let dy = y - cy
          if dx * dx + dy * dy <= vr * vr:
            let o = (y * WorldPxR + x) * 4
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

proc traceCell(px: seq[uint8], cell: int): (seq[uint8], uint64, bool) =
  ## One cell of the overlay, its content hash, and whether anything at all
  ## is visible in it. FNV-1a over the exact bytes that would ship, so "did
  ## this change" is answered by the pixels rather than by guessing which
  ## stamps landed where.
  ##
  ## Row copy, then one hash step per pixel rather than per byte. At RS=4
  ## this walks 5.3 MB every 48 ticks on the match thread; the hash only
  ## has to answer "did this cell change", and folding four bytes at a time
  ## answers that just as well a quarter as often.
  var buf = newSeq[uint8](TraceCellPx * TraceCellPx * 4)
  var h = 0xCBF29CE484222325'u64
  var lit = false
  let ox = (cell mod TraceGrid) * TraceCellPx
  let oy = (cell div TraceGrid) * TraceCellPx
  for y in 0 ..< TraceCellPx:
    let src = ((oy + y) * WorldPxR + ox) * 4
    let dst = y * TraceCellPx * 4
    copyMem(addr buf[dst], unsafeAddr px[src], TraceCellPx * 4)
    var i = dst
    let stop = dst + TraceCellPx * 4
    while i < stop:
      let v = (uint32(buf[i]) shl 24) or (uint32(buf[i + 1]) shl 16) or
              (uint32(buf[i + 2]) shl 8) or uint32(buf[i + 3])
      h = (h xor uint64(v)) * 0x100000001B3'u64
      if (v and 0xFF'u32) != 0:
        lit = true
      i += 4
  (buf, h, lit)

proc emitTraceCells(r: var Renderer, packet: var seq[uint8],
                    px: seq[uint8]) =
  ## Re-define only the cells whose pixels moved. Cells that empty out drop
  ## their object instead of shipping a transparent rectangle forever.
  for cell in 0 ..< TraceCells:
    let (buf, h, lit) = traceCell(px, cell)
    if lit:
      if r.traceCellDrawn[cell] and r.traceCellHash[cell] == h:
        continue
      packet.addSprite(SpTraceBase + cell, TraceCellPx, TraceCellPx, buf,
                       "trace" & $cell, native = true)
      if not r.traceCellDrawn[cell]:
        packet.addObject(ObTraceCellBase + cell,
                         (cell mod TraceGrid) * TraceCell1x,
                         (cell div TraceGrid) * TraceCell1x, TraceZ,
                         LayerMap, SpTraceBase + cell)
        r.traceCellDrawn[cell] = true
      r.traceCellHash[cell] = h
    elif r.traceCellDrawn[cell]:
      packet.addDeleteObject(ObTraceCellBase + cell)
      r.traceCellDrawn[cell] = false
      r.traceCellHash[cell] = 0

proc emitTraceCellsFull(packet: var seq[uint8], px: seq[uint8]) =
  ## Everything a fresh viewer needs to see the afterglow that is already on
  ## the board. Before this, a viewer joining at tick 5000 got no trace at
  ## all until the next 48-tick refresh; with dirty cells it would have got
  ## only the cells that happened to change after it connected.
  for cell in 0 ..< TraceCells:
    let (buf, _, lit) = traceCell(px, cell)
    if not lit:
      continue
    packet.addSprite(SpTraceBase + cell, TraceCellPx, TraceCellPx, buf,
                     "trace" & $cell, native = true)
    packet.addObject(ObTraceCellBase + cell,
                     (cell mod TraceGrid) * TraceCell1x,
                     (cell div TraceGrid) * TraceCell1x, TraceZ,
                     LayerMap, SpTraceBase + cell)

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

proc derezObjectAt(packet: var seq[uint8], tx, ty, spriteId: int) =
  ## One overlay tile, id keyed to the tile so it can be re-pointed or
  ## dropped later without a rescan. Placed in 1x board space like every
  ## other map object; addObject scales it into the RS viewport.
  packet.addObject(ObDerezBase + ty * ArenaSize + tx, tx * TileSize,
                   ty * TileSize, DerezZ, LayerMap, spriteId)

proc emitDerezFull(packet: var seq[uint8], a: Arena, safeR, derez: int) =
  ## Complete reclaimed-territory state, for a viewer that just connected.
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      if isReclaimed(safeR, tx, ty):
        packet.derezObjectAt(tx, ty,
          derezSpriteId(derez, tx, ty, a.isStructuralTile(tx, ty)))

proc syncDerez(r: var Renderer, packet: var seq[uint8], a: Arena,
               safeR, derez: int) =
  ## Emit only what changed. A ring step reclaims a ring of tiles (a few
  ## hundred object messages); a de-rez stage change re-points the tiles
  ## already placed. Either way it is bytes per tile, not a whole board.
  if r.derezTile.len == 0:
    r.derezTile = newSeq[int](ArenaSize * ArenaSize)
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      let want =
        if isReclaimed(safeR, tx, ty):
          derezSpriteId(derez, tx, ty, a.isStructuralTile(tx, ty))
        else: 0
      let idx = ty * ArenaSize + tx
      if want == r.derezTile[idx]:
        continue
      if want == 0:
        packet.addDeleteObject(ObDerezBase + idx)
      else:
        packet.derezObjectAt(tx, ty, want)
      r.derezTile[idx] = want

proc spriteDefs(s: Sim): seq[uint8] =
  ## Every sprite here is a pure function of the arena, so this whole blob
  ## is cacheable (see initPacket). The background is deliberately baked
  ## *pristine* — reclaimed territory arrives as overlay objects, which is
  ## what stops the board being re-sent 27 times a match.
  result.addSprite(SpBackground, WorldPxR, WorldPxR,
                   backgroundPixels(s.arena, ArenaSize, 0,
                                    armed = s.phase == phCountdown), "arena")
  for id in derezSpriteIds():
    result.addSprite(id, TilePxR, TilePxR, derezTilePixels(id), "derez",
                     native = true)
  for slot in 0 ..< s.cfg.numPlayers:
    for facing in 0 .. 3:
      for frame in 0 .. 1:
        result.addSprite(SpBodyBase + slot * 10 + facing * 2 + frame,
          BodyWR, BodyHR, bodyPixels(slot div 2, slot mod 2, facing, frame),
          "body" & $slot, native = true)
    result.addSprite(SpCorpseBase + slot, CorpseW, CorpseH,
      corpsePixels(slot div 2, slot mod 2), "corpse" & $slot, native = true)
  for id in ItemId:
    if id != iNone:      # every carriable shows in the hand, medkits included
      result.addSprite(SpWeaponBase + ord(id), HeldPx, HeldPx,
                       heldWeaponPixels(id), "held_" & $id, native = true)
      result.addSprite(SpWeaponWBase + ord(id), HeldPx, HeldPx,
                       heldWeaponPixels(id, mirror = true),
                       "held_w_" & $id, native = true)
  # death burst in bone: the old (25,25,30)-on-Faraday burst measured
  # under 1.5:1 contrast — the game's pivotal event was invisible
  ## Tier A bursts: one baked star, three tints, native at RS (a 72-wire
  ## native sprite has the same 18-unit board footprint the upscaled 18x18
  ## had, so every placement stays put). Mine scales to 48 per the plan.
  result.addSprite(SpFwBlack, BurstStarW, BurstStarH,
                   tintedBurstStar(Bone), "fw_bone", native = true)
  result.addSprite(SpFwGold, BurstStarW, BurstStarH,
                   tintedBurstStar(GoldTone), "fw_amber", native = true)
  result.addSprite(SpMineFlash, BurstStarW * 2 div 3, BurstStarH * 2 div 3,
                   resample3to2(tintedBurstStar(Klaxon), BurstStarW, BurstStarH),
                   "mine", native = true)
  for parity in 0 .. 1:
    for f in 0 ..< DecompFrames:
      result.addSprite(SpDecompBase + parity * DecompFrames + f,
                       BodyWR, BodyHR, decompFrame(parity, f),
                       "decomp" & $parity & "_" & $f, native = true)
    # opaque peak-white death frame, cut to THIS chassis: the flash is a
    # solid silhouette, not a tinted body (the shared 185-alpha hit flash
    # let the hull read through and the beat read as a white agent)
    var flash = newSeq[uint8](BodyWR * BodyHR * 4)
    let (_, mask) = chassisPx(parity, 0)
    for k in 0 ..< BodyWR * BodyHR:
      if mask[k] > 0:
        flash[k * 4] = PhosphorPeak[0]
        flash[k * 4 + 1] = PhosphorPeak[1]
        flash[k * 4 + 2] = PhosphorPeak[2]
        flash[k * 4 + 3] = 255
    result.addSprite(SpDeathFlashBase + parity, BodyWR, BodyHR, flash,
                     "death_flash" & $parity, native = true)
  result.addSprite(SpZoneFireA, TilePxR, TilePxR, plasmaPixels(0, false),
                   "plasmaA", native = true)
  result.addSprite(SpZoneFireB, TilePxR, TilePxR, plasmaPixels(1, false),
                   "plasmaB", native = true)
  result.addSprite(SpPlasmaCritA, TilePxR, TilePxR, plasmaPixels(0, true),
                   "plasmaCritA", native = true)
  result.addSprite(SpPlasmaCritB, TilePxR, TilePxR, plasmaPixels(1, true),
                   "plasmaCritB", native = true)
  result.addSprite(SpGlassBody, BodyWR, BodyHR, glassBodyPixels(),
                   "camo_glass", native = true)
  result.addSprite(SpNetMesh, TilePxR, TilePxR, netMeshPixels(), "net_mesh",
                   native = true)
  result.addSprite(SpPoisonHaloA, 10 * RS, 10 * RS, poisonHaloPixels(0),
                   "haloA", native = true)
  result.addSprite(SpPoisonHaloB, 10 * RS, 10 * RS, poisonHaloPixels(1),
                   "haloB", native = true)
  result.addSprite(SpVoidBeam, 6 * RS, 48 * RS, voidBeamPixels(),
                   "void_beam", native = true)
  # baked fade ramps: stage 0 is full strength, later stages pre-dimmed
  for k in 0 ..< FadeStages:
    let m = (FadeStages - k) * 255 div FadeStages
    result.addSprite(SpFadeDeath + k, BurstStarW, BurstStarH,
                     dimmed(tintedBurstStar(Bone), m), "fade_death",
                     native = true)
    result.addSprite(SpFadeIgnite + k, BurstStarW, BurstStarH,
                     dimmed(tintedBurstStar(GoldTone), m), "fade_ignite",
                     native = true)
    result.addSprite(SpFadeMine + k, BurstStarW * 2 div 3, BurstStarH * 2 div 3,
                     dimmed(resample3to2(tintedBurstStar(Klaxon),
                                         BurstStarW, BurstStarH), m),
                     "fade_mine", native = true)
    result.addSprite(SpFadeVoid + k, 6 * RS, 48 * RS,
                     dimmed(voidBeamPixels(), m), "fade_void", native = true)
  result.addSprite(SpGoldBeam, 8 * RS, 54 * RS, goldBeamPixels(),
                   "gold_beam", native = true)
  result.addSprite(SpGlitch, BodyWR, BodyHR, glitchPixels(), "glitch",
                   native = true)
  result.addSprite(SpMouthA, TilePxR, TilePxR, mouthLightPixels(0), "mouthA",
                   native = true)
  result.addSprite(SpMouthB, TilePxR, TilePxR, mouthLightPixels(1), "mouthB",
                   native = true)
  for id in [iArrows, iDarts, iKnives]:
    result.addSprite(SpTrailBase + ord(id), TilePxR, TilePxR, trailPixels(id),
                     "trail_" & $id, native = true)
  result.addSprite(SpFirestormA, TilePxR, TilePxR, stormPixels(0), "stormA",
                   native = true)
  result.addSprite(SpFirestormB, TilePxR, TilePxR, stormPixels(1), "stormB",
                   native = true)
  result.addSprite(SpFloodA, TilePxR, TilePxR, floodPixels(0), "floodA",
                   native = true)
  result.addSprite(SpFloodB, TilePxR, TilePxR, floodPixels(1), "floodB",
                   native = true)
  for id in ItemId:
    if id != iNone:
      result.addSprite(SpPodCrateBase + ord(id), TilePxR, TilePxR,
                       podCratePixels(id), "pod_" & $id,
                       native = true)
  result.addSprite(SpChannelA, 10, 10, channelHaloPixels(0), "chanA")
  result.addSprite(SpChannelB, 10, 10, channelHaloPixels(1), "chanB")
  result.addSprite(SpRevealMark, 5, 5, revealMarkPixels(), "revealed")
  for n in 0 .. 3:
    result.addSprite(SpBushBase + n, TilePxR, TilePxR, bushPixels(n),
                     "bush" & $n, native = true)
  for id in ItemId:
    if id != iNone:
      result.addSprite(SpItemBase + ord(id), TilePxR, TilePxR,
                       itemPixels(id), "item_" & $id, native = true)
  for id in [iArrows, iDarts, iKnives, iNet]:
    result.addSprite(SpProjBase + ord(id), ProjPx, ProjPx, projPixels(id),
                       "proj_" & $id, native = true)
  for slot in 0 ..< s.cfg.numPlayers:
    let (w, h, px) = tagPixels(slotLabel(s, slot))
    result.addSprite(SpSlotLabelBase + slot, w, h, px, "tag" & $slot)
    let (sw, sh, spx) = tagPixels(shortLabel(slot))
    result.addSprite(SpSlotShortBase + slot, sw, sh, spx, "tagshort" & $slot)
  for band in 0 .. 2:
    result.addSprite(SpHpBandBase + band, 10, 3, hpBandPixels(band), "hp" & $band)
  result.addSprite(SpRingGhost, TilePxR, TilePxR, ringGhostPixels(),
                   "ring_ghost", native = true)
  result.addSprite(SpSettleLine, WorldPx, 3, settleLinePixels(), "settle")
  result.addSprite(SpReticle, TilePxR, TilePxR, reticlePixels(), "reticle",
                   native = true)
  for ph in 0 .. 2:
    result.addSprite(SpCratePartBase + ph, TilePxR, TilePxR,
                     cratePartPixels(2 + ph * 2), "crate_p" & $ph,
                     native = true)
  result.addSprite(SpPingA, 12 * RS, 12 * RS, pingPixels(false), "pingA",
                   native = true)
  result.addSprite(SpPingB, 12 * RS, 12 * RS, pingPixels(true), "pingB",
                   native = true)
  result.addSprite(SpHitFlash, BodyWR, BodyHR, hitFlashPixels(), "hit",
                   native = true)

proc bodySprite(r: Renderer, s: Sim, slot: int): int =
  let moving = s.tick - r.lastMoveTick[slot] < 12
  let frame = (if moving: (s.tick div 6) mod 2 else: 0)
  SpBodyBase + slot * 10 + r.facing[slot] * 2 + frame

proc camoHidden(s: Sim, slot: int): bool =
  s.agents[slot].body == iCamo and s.tick >= s.agents[slot].camoRevealedUntil

const TagRowSpan = 1     # plates are 7px tall on rows TileSize apart, so only
                         # adjacent rows can share columns

proc tagCrowded(s: Sim, slot: int): bool =
  ## True when this agent's name plate would collide with a neighbour's, in
  ## which case both fall back to the 2-char A1/A2 plate.
  ##
  ## Tests real plate geometry rather than a fixed tile radius, because the
  ## radius has to track the label: an 8-character plate is 34px = 5.7 tiles
  ## at TileSize 6, so the old 2-tile test left agents 3 tiles apart both
  ## believing they were uncrowded while their plates overlapped by 16 render
  ## pixels. Seen in league round 1851, where slot 2's "B1" and slot 6's
  ## "BASELIN2" ran together into one unreadable token.
  ##
  ## Both sides decide from their FULL labels, so the answer never depends on
  ## what was rendered — no oscillation, and the pair agrees.
  let p = s.agents[slot].pos
  let mine = slotLabel(s, slot)
  for i in 0 .. 15:
    if i == slot or not s.agents[i].alive: continue
    let q = s.agents[i].pos
    if abs(q.y - p.y) > TagRowSpan: continue
    if platesOverlap(p.x, mine, q.x, slotLabel(s, i)):
      return true
  false

proc drawAgent(r: Renderer, packet: var seq[uint8], s: Sim, slot: int) =
  let p = s.agents[slot].pos
  # camo agents render as refractive glass on the spectator view (§21.3)
  let sprite = (if s.camoHidden(slot): SpGlassBody else: r.bodySprite(s, slot))
  packet.addObject(ObAgentBase + slot, p.x * TileSize - 1,
                   p.y * TileSize - (BodyH - TileSize), 10, LayerMap, sprite)
  # Whatever the hand holds is broadcast-visible — weapon, medkit, net: a
  # viewer reads "armed with what / about to heal" from the mark alone.
  # East/south lead with the upright mark, the west hand mirrors it, and
  # facing north it rides behind the hull (z below the body) so it peeks
  # over the shoulder instead of covering the head.
  let hand = s.agents[slot].hand
  if hand != iNone and not s.camoHidden(slot):
    let f = r.facing[slot]
    let wSprite = (if f == 3: SpWeaponWBase else: SpWeaponBase) + ord(hand)
    let wx = p.x * TileSize - 1 +
             (case f
              of 2: TileSize - 2
              of 3: -(HeldPx div RS) + 2
              else: 1)
    let wy = p.y * TileSize + (if f == 1: -8 else: -3)
    packet.addObject(ObWeaponBase + slot, wx, wy,
                     (if f == 1: 9 else: 11), LayerMap, wSprite)
  # identity tag + hp semaphore (Tier 1): fights must be readable on air
  # A cluster gets the 2-char plate, not no plate: identity must never fall
  # back to team hue alone (VISUAL_REDESIGN Part 8.1).
  let crowded = s.tagCrowded(slot)
  let plate = (if crowded: shortLabel(slot) else: slotLabel(s, slot))
  packet.addObject(ObSlotLabelBase + slot, plateX(p.x, plate),
                   p.y * TileSize + TileSize + 1, 12, LayerMap,
                   (if crowded: SpSlotShortBase else: SpSlotLabelBase) + slot)
  let band = (if s.agents[slot].hpCenti > 6600: 0
              elif s.agents[slot].hpCenti >= 3300: 1 else: 2)
  packet.addObject(ObHpBandBase + slot, p.x * TileSize - 2,
                   p.y * TileSize - (BodyH - TileSize) - 4, 12, LayerMap,
                   SpHpBandBase + band)

proc spawnEffect(r: var Renderer, packet: var seq[uint8], s: Sim,
                 spriteId, cx, cy, size, ttl: int,
                 stageBase = -1, stages = 0) =
  # ids must stay below ObBushBase (20000) — effects rotating past that
  # range would clobber pooled world objects mid-broadcast
  let objId = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
  inc r.nextEffect
  let px = cx - size div 2
  let py = cy - size div 2
  packet.addObject(objId, px, py, 20, LayerMap, spriteId)
  r.effects.add(Effect(objId: objId, dieTick: s.tick + ttl,
                       stageBase: stageBase, stages: stages,
                       bornTick: s.tick, ttl: ttl, stageShown: 0,
                       x: px, y: py))

proc updatePacket*(r: var Renderer, s: Sim): seq[uint8] =
  r.ensureLabels(s)
  # Pedestal disarm (VISUAL_REDESIGN §3.4): the mines die at ignition, so
  # the board's plates swap from hazard-striped to plain — one extra
  # background define per match, exactly as ART_UPGRADE_PLAN budgeted.
  if not r.bgLive and s.phase != phCountdown:
    result.addSprite(SpBackground, WorldPxR, WorldPxR,
                     backgroundPixels(s.arena, ArenaSize, 0, armed = false),
                     "arena")
    r.bgLive = true
  r.ensureTrace()
  # facing/anim bookkeeping
  for slot in 0 ..< s.cfg.numPlayers:
    let a = s.agents[slot]
    if a.alive:
      r.stampTrace(a.pos.x, a.pos.y, TeamColors[slot div 2], 130)
      # hit response (Tier 2): 1-frame peak-white flash + damage numeral
      if r.lastHp[slot] > a.hpCenti:
        r.spawnEffect(result, s, SpHitFlash,
          a.pos.x * TileSize + 3, a.pos.y * TileSize, 8, 2)
        # cause watermark for the settlement chyron: damageSources is
        # cleared before the death event becomes visible next tick, so
        # the cause is recorded the tick the damage actually lands
        if a.damageSources.len > 0:
          let label = a.damageSources[^1][0]
          r.lastCause[slot] =
            (if label.len > 0 and label[0] == 'P' and a.lastDamager >= 0:
               (if s.agents[a.lastDamager].hand == iNone: "FISTS"
                else: upperLabel($s.agents[a.lastDamager].hand))
             elif label == "environment": ""
             else: upperLabel(label))
        # attack facing (VISUAL_REDESIGN 5.2): the attacker turns toward
        # the victim the tick the hit lands, so duels stop reading as two
        # agents stabbing sideways
        if a.lastDamager >= 0 and a.lastDamager != slot and
           s.agents[a.lastDamager].alive:
          let ddx = a.pos.x - s.agents[a.lastDamager].pos.x
          let ddy = a.pos.y - s.agents[a.lastDamager].pos.y
          if ddx != 0 or ddy != 0:
            r.facing[a.lastDamager] =
              (if abs(ddx) >= abs(ddy): (if ddx > 0: 2 else: 3)
               else: (if ddy > 0: 0 else: 1))
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
      # the held mark must leave the wire the tick the hand empties (a
      # thrown net used to linger at the old offset until death)
      let wantWeapon = s.agents[slot].hand != iNone and not s.camoHidden(slot)
      if r.weaponDrawn[slot] and not wantWeapon:
        result.addDeleteObject(ObWeaponBase + slot)
      r.weaponDrawn[slot] = wantWeapon
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
        a.pos.x * TileSize + TileSize div 2, a.pos.y * TileSize - 20, 6, 36,
        SpFadeVoid, FadeStages)
      r.deadDrawn[slot] = true
    elif r.weaponDrawn[slot]:
      result.addDeleteObject(ObWeaponBase + slot)
      r.weaponDrawn[slot] = false
  # talk chips (VISUAL_REDESIGN 5.7): the diplomacy layer, on air. Talk is
  # permanently public by design; the broadcast shows it live. One chip per
  # speaker, newest message wins, TalkChipTtl and gone. Late joiners can
  # miss an active chip's sprite for its remaining life -- same convention
  # as the kill feed's dynamic text.
  for idx in r.talkSeen ..< s.talkLog.len:
    let msg = s.talkLog[idx]
    if msg.slot < 0 or msg.slot > 15 or not s.agents[msg.slot].alive:
      continue
    let body = talkSafe(msg.text)
    if body.len == 0:
      continue
    let tag =
      case msg.channel
      of tcBroadcast: slotLabel(s, msg.slot) & ":"
      of tcTeam: slotLabel(s, msg.slot) & "+"
      of tcDm: slotLabel(s, msg.slot) & ">" & slotLabel(s, msg.to)
    let chipColor =
      case msg.channel
      of tcBroadcast: Bone
      of tcTeam: Phosphor
      of tcDm: GoldTone
    inc r.talkFlip[msg.slot]
    let spId = SpTalkBase + msg.slot * 2 + (r.talkFlip[msg.slot] mod 2)
    let (w, h, px) = textPixels(tag & " " & body,
                                chipColor[0], chipColor[1], chipColor[2])
    result.addSprite(spId, w, h, px, "talk" & $msg.slot)
    r.talkW[msg.slot] = w
    r.talkOn[msg.slot] = true
    r.talkUntil[msg.slot] = s.tick + TalkChipTtl
  r.talkSeen = s.talkLog.len
  for slot in 0 .. 15:
    if not r.talkOn[slot]:
      continue
    if s.tick >= r.talkUntil[slot] or not s.agents[slot].alive:
      result.addDeleteObject(ObTalkBase + slot)
      r.talkOn[slot] = false
    else:
      # re-pin to the speaker every tick so the chip follows them; clamp
      # into the arena so edge speakers don't push their text off-world
      let p = s.agents[slot].pos
      let cx = max(0, min(WorldPx - r.talkW[slot], p.x * TileSize - 4))
      result.addObject(ObTalkBase + slot, cx,
                       p.y * TileSize - (BodyH - TileSize) - 13, 14, LayerMap,
                       SpTalkBase + slot * 2 + (r.talkFlip[slot] mod 2))
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
              HazardZ, LayerMap,
              (if (phase + tx + ty) mod 2 == 0: SpFirestormA
               else: SpFirestormB))
            inc regIdx
    of ecFlood:
      for ty in max(1, ev.rect[1]) .. min(ArenaSize - 2, ev.rect[3]):
        for tx in max(1, ev.rect[0]) .. min(ArenaSize - 2, ev.rect[2]):
          if regIdx >= RegionPool: break
          result.addObject(ObRegionBase + regIdx, tx * TileSize, ty * TileSize,
            HazardZ, LayerMap,
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
    of evMineExplosion:
      r.spawnEffect(result, s, SpMineFlash, cx, cy, 12, 12,
                    SpFadeMine, FadeStages)
    of evDeathFireworks:
      r.spawnEffect(result, s, SpFwBlack, cx, cy, 18, 36,
                    SpFadeDeath, FadeStages)
      if e.slot >= 0:
        # death sequence (VISUAL_REDESIGN Part 7): peak-white frame, then
        # the body decomposes over 8 frames — pixels scatter into the
        # tile, a process being freed. Placement matches drawAgent's body
        # offset exactly so frame 0 lands on the body it replaces.
        let bx = e.pos.x * TileSize - 1
        let by = e.pos.y * TileSize - (BodyH - TileSize)
        let flashObj = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
        inc r.nextEffect
        result.addObject(flashObj, bx, by, 21, LayerMap,
                         SpDeathFlashBase + (e.slot mod 2))
        r.effects.add(Effect(objId: flashObj, dieTick: s.tick + 2))
        let decompObj = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
        inc r.nextEffect
        let base = SpDecompBase + (e.slot mod 2) * DecompFrames
        result.addObject(decompObj, bx, by, 20, LayerMap, base)
        r.effects.add(Effect(objId: decompObj, dieTick: s.tick + 24,
                             stageBase: base, stages: DecompFrames,
                             bornTick: s.tick, ttl: 24, stageShown: 0,
                             x: bx, y: by))
      if e.slot >= 0:
        # settlement chyron (VISUAL_REDESIGN 5.3): credit = last damager,
        # same rule as scoring; cause from the hit-time watermark
        let k = s.agents[e.slot].lastDamager
        let place = s.computePlacements()[e.slot]
        # "SETTLED" cost 8 of the feed's 39 columns; with real names the
        # typical line overflowed and lost its timestamp. Place + killer +
        # weapon + time all fit without it.
        var line = slotLabel(s, e.slot) & " " & $place & ordSuffix(place)
        if k >= 0 and k != e.slot:
          line.add " BY " & slotLabel(s, k)
        if r.lastCause[e.slot].len > 0:
          line.add " " & r.lastCause[e.slot]
        line.add " " & mmss(max(0, s.agents[e.slot].deathTick) div 24)
        if k >= 0 and k != e.slot and
           s.agents[k].deathTick == s.agents[e.slot].deathTick:
          line.add " MUTUAL"
        r.killFeed.insert(clipCols(line, KillCols), 0)
        if r.killFeed.len > KillRows:
          r.killFeed.setLen(KillRows)
        r.killDirty = true
        # settlement line (VISUAL_REDESIGN §5.3): a ledger rule strikes
        # the full frame at the dead agent's row
        let lineObj = ObEffectBase + (r.nextEffect mod (ObBushBase - ObEffectBase))
        inc r.nextEffect
        result.addObject(lineObj, 0, e.pos.y * TileSize + 2, 22, LayerMap,
                         SpSettleLine)
        r.effects.add(Effect(objId: lineObj, dieTick: s.tick + 10))
    of evIgnition:
      r.spawnEffect(result, s, SpFwGold, cx, cy, 18, 48,
                    SpFadeIgnite, FadeStages)
    of evMatchEnd:
      if e.slot >= 0:
        let p = s.agents[e.slot].pos
        r.spawnEffect(result, s, SpFwGold,
          p.x * TileSize + TileSize div 2, p.y * TileSize + TileSize div 2, 18, 96,
          SpFadeIgnite, FadeStages)
    else: discard
  var kept: seq[Effect] = @[]
  for ef in r.effects:
    if s.tick >= ef.dieTick:
      result.addDeleteObject(ef.objId)
    else:
      var e = ef
      if e.stages > 1 and e.ttl > 0:
        # advance the baked fade: re-point the same object at a dimmer
        # sprite, so effects ebb away instead of vanishing on one frame
        let want = min(e.stages - 1,
                       ((s.tick - e.bornTick) * e.stages) div e.ttl)
        if want != e.stageShown:
          e.stageShown = want
          result.addObject(e.objId, e.x, e.y, 20, LayerMap,
                           e.stageBase + want)
      kept.add(e)
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
            RingZ, LayerMap, sp)
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
                  ty * TileSize, RingZ, LayerMap, SpRingGhost)
                inc ghostIdx
      break
  for stale in ghostIdx ..< r.nextRingDrawn:
    result.addDeleteObject(ObNextRingBase + stale)
  r.nextRingDrawn = ghostIdx
  # Phosphor persistence is the only full-world dynamic sprite. Refresh it at
  # 0.5 Hz so the live stream and static presentation recording stay compact;
  # object motion and combat effects continue at the full 24 Hz tick rate.
  if r.traceActive and s.tick mod 48 == 0:
    for i in 0 ..< r.trace.len:
      let a = r.trace[i] and 0xFF
      if a > 0:
        let na = (a * 2) div 5
        r.trace[i] = (r.trace[i] and 0xFFFFFF00'u32) or
                     (if na < 6: 0'u32 else: na)
    r.emitTraceCells(result, r.traceSpritePixels(s))
  # per-seat alive lamp row: subtraction made visible as light
  var lampMask = 0
  for slot in 0 ..< s.cfg.numPlayers:
    if s.agents[slot].alive:
      lampMask = lampMask or (1 shl slot)
  if lampMask != r.lastLampMask:
    r.lastLampMask = lampMask
    result.addSprite(SpLampRow, 81, 6,
                     lampRowPixels(lampMask, s.cfg.numPlayers), "lamps")
    result.addObject(ObLampRow, 2, 50, 0, LayerHudTL, SpLampRow)
  # exterior treatment tracks the shrinking ring. The board itself never
  # changes, so it is defined once per match: only the per-tile overlay
  # moves, and only the tiles that actually changed are sent.
  let bgR = s.effectiveSafeRadius()
  let derez = s.derezLevel()
  let bgKey = bgR * 4 + derez
  if bgKey != r.lastBgRadius:
    r.lastBgRadius = bgKey
    r.syncDerez(result, s.arena, bgR, derez)
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
  let hud1 = "ALIVE " & $s.aliveCount() & "  " & ringTxt & "  T " & mmss(secs)
  var hud2 = "COIN"
  for t in 0 ..< s.cfg.numPlayers div 2:
    hud2.add(" " & TeamNames[t] & $s.teamBudget[t])
  if hud1 != r.lastHud1:
    r.lastHud1 = hud1
    let spId = SpHudBase + (r.hud1Flip mod 2)
    inc r.hud1Flip
    let (w, h, px) = textPixels7(hud1, PhosphorPeak[0], PhosphorPeak[1],
                                 PhosphorPeak[2])
    result.addSprite(spId, w, h, px, "hud1")
    result.addObject(ObHudLine1, 2, 2, 0, LayerHudTL, spId)
  if hud2 != r.lastHud2:
    r.lastHud2 = hud2
    let spId = SpHudBase + 2 + (r.hud2Flip mod 2)
    inc r.hud2Flip
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
                         " " & slotLabel(s, e.slot)
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

proc arenaKey(a: Arena): uint64 =
  ## FNV-1a over the tile grid — and it costs microseconds against the tens of
  ## milliseconds it guards. NOT the whole cache key on its own: spriteDefs
  ## also bakes the seat nameplates, so initPacket folds labelsKey in too.
  result = 0xCBF29CE484222325'u64
  for ty in 0 ..< ArenaSize:
    for tx in 0 ..< ArenaSize:
      result = (result xor uint64(ord(a.tiles[ty][tx]))) * 0x100000001B3'u64

proc labelsKey(s: Sim): uint64 =
  ## The nameplate sprites are baked into the atlas, so the seat labels are
  ## part of what it depends on. Without this a cached atlas would carry one
  ## match's names into the next.
  result = 0xCBF29CE484222325'u64
  result = (result xor uint64(s.cfg.numPlayers)) * 0x100000001B3'u64
  for i in 0 ..< s.cfg.numPlayers:
    for ch in slotLabel(s, i):
      result = (result xor uint64(ord(ch))) * 0x100000001B3'u64

proc initPacket*(r: var Renderer, s: Sim): seq[uint8] =
  ## Complete current scene for a fresh viewer (or replay-loop restart).
  r.ensureLabels(s)
  result.addClearObjects()
  result.addLayer(LayerMap, 0x00, 0x01)
  result.addViewport(LayerMap, WorldPxR, WorldPxR)
  result.addLayer(LayerHudTL, 0x01, 0x02)
  result.addViewport(LayerHudTL, 240, 60)
  result.addLayer(LayerHudBL, 0x04, 0x02)
  result.addViewport(LayerHudBL, 320, 14)
  result.addLayer(LayerBanner, 0x05, 0x02)
  result.addViewport(LayerBanner, 120, 16)
  var key = arenaKey(s.arena) xor labelsKey(s)
  if s.phase == phCountdown:
    key = key xor 1'u64        # armed pedestals bake a different board
  if not r.defsValid or r.defsKey != key:
    r.defsBlob = spriteDefs(s)
    r.defsKey = key
    r.defsValid = true
  result.add(r.defsBlob)
  r.bgLive = s.phase != phCountdown
  result.addObject(ObBackground, 0, 0, 0, LayerMap, SpBackground)
  # the board is pristine in the sprite; reclaimed ground is objects, and a
  # viewer joining at tick 5000 needs the ones already standing
  emitDerezFull(result, s.arena, s.effectiveSafeRadius(), s.derezLevel())
  if r.traceActive:
    emitTraceCellsFull(result, r.traceSpritePixels(s))
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
  r.talkSeen = 0
  for i in 0 .. 15:
    r.talkOn[i] = false
    r.talkFlip[i] = 0
    r.talkUntil[i] = 0
    r.lastCause[i] = ""
  r.labelsReady = false

  r.lastBgRadius = 0
  r.bgLive = false
  for i in 0 ..< r.derezTile.len:
    r.derezTile[i] = 0
  r.podLabelText = @[]
  r.trace = @[]
  r.scars = @[]
  r.traceActive = false
  for i in 0 ..< TraceCells:
    r.traceCellHash[i] = 0
    r.traceCellDrawn[i] = false
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