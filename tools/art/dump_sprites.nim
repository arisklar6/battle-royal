## dump_sprites — the ground truth for "what does the art actually look like".
##
## This is deliberately NOT a reimplementation of the drawing code in another
## language. It runs a real headless episode through the real `Renderer`,
## parses the sprite_v1 packets it emits, and decompresses the exact Snappy
## payloads a client would receive. Every PNG it writes is byte-identical to
## the pixels that ship.
##
## It follows `game/poster.nim`'s established pattern (`include render`, fixed
## seed, scripted centre-drift + one sponsor gift) so the two harnesses see the
## same match. `poster.nim` composites one frame; this dumps the catalogue.
##
## Build + run, from the repo root:
##   nim c -r tools/art/dump_sprites.nim out=docs/evidence/sprites
##
## Arguments are `key=value`, any order:
##   out=DIR        output directory        (default docs/evidence/sprites)
##   seed=N         sim seed                (default 42)
##   ticks=N        max ticks to run        (default 480; 0 = init packet only)
##   variants=N     max distinct pixel variants dumped per (id,label)
##                                          (default 2)
##   gift=0|1       fire one sponsor gift so pod/crate/label art appears
##                                          (default 1)
##
## Writes:
##   <out>/png/s0000_<label>_<v>.png   straight-alpha RGBA, exact wire pixels
##   <out>/sprites.json                manifest consumed by tools/art/preview.py
##
## The manifest records the wire cost (compressed bytes) of every sprite, which
## is only knowable here; pixel statistics are left to the Python side.
##
## It also records `coverage`: the renderer's whole addressable sprite-id space
## against what this episode actually emitted. A contact sheet built from one
## match shows what that match happened to draw, and a sprite the run never
## reached looks exactly like a sprite the renderer does not have. Coverage is
## what tells those two apart — see `declaredFamilies` below.

import std/[algorithm, json, os, sequtils, sets, strformat, strutils, tables]
import pixie
import pixie/fileformats/png as pixiepng   # encodePng: straight-alpha RGBA in
import supersnappy

include "../../game/render"

type
  Variant = object
    pixHashHex: string
    w, h: int
    px: seq[uint8]
    compressedBytes: int
    firstTick: int
    lastTick: int
    defineCount: int
    file: string

  SpriteRec = object
    id: int
    label: string
    w, h: int                 # dimensions of the LAST definition seen
    order: int
    variants: seq[Variant]
    distinctVariants: int
    defineCount: int
    firstTick: int
    lastTick: int
    fromInitPacket: bool
    dimsVary: bool            # live text sprites resize as the string changes

proc fnv1a(data: openArray[uint8]): uint64 =
  ## Stable, order-dependent hash used only to tell variants apart.
  result = 0xcbf29ce484222325'u64
  for b in data:
    result = result xor uint64(b)
    result = result * 0x100000001b3'u64

proc sanitize(s: string): string =
  for ch in s:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      result.add(ch)
    elif ch == ' ' or ch == '.':
      result.add('_')
  if result.len == 0:
    result = "unlabelled"

proc argValue(key, fallback: string): string =
  result = fallback
  for i in 1 .. paramCount():
    let p = paramStr(i)
    let eq = p.find('=')
    if eq > 0 and p[0 ..< eq] == key:
      result = p[eq + 1 .. ^1]

proc argInt(key: string, fallback: int): int =
  let raw = argValue(key, $fallback)
  try:
    result = parseInt(raw)
  except ValueError:
    quit(&"dump_sprites: {key}= expects an integer, got '{raw}'", 2)

proc mintFixed(): uint64 =
  ## Boundary-only entropy; fixed so dumps are byte-reproducible.
  42'u64

var
  recs: seq[SpriteRec] = @[]
  recIndex: Table[string, int] = initTable[string, int]()
  maxVariants = 2

proc record(def: SpritePacketSpriteDef, tick: int, fromInit: bool) =
  let px = uncompress(def.compressedPixels)
  let key = $def.id & "/" & def.label
  if key notin recIndex:
    recIndex[key] = recs.len
    recs.add(SpriteRec(id: def.id, label: def.label, w: def.width,
                       h: def.height, order: recs.len, firstTick: tick,
                       lastTick: tick, fromInitPacket: fromInit))
  let i = recIndex[key]
  recs[i].defineCount += 1
  recs[i].lastTick = tick
  if recs[i].w != def.width or recs[i].h != def.height:
    if recs[i].defineCount > 1:
      recs[i].dimsVary = true
    recs[i].w = def.width
    recs[i].h = def.height
  if fromInit:
    recs[i].fromInitPacket = true
  let h = toHex(fnv1a(px), 16)
  for v in recs[i].variants.mitems:
    if v.pixHashHex == h and v.w == def.width and v.h == def.height:
      v.defineCount += 1
      v.lastTick = tick
      return
  recs[i].distinctVariants += 1
  if recs[i].variants.len < maxVariants:
    recs[i].variants.add(Variant(pixHashHex: h, w: def.width, h: def.height,
                                 px: px,
                                 compressedBytes: def.compressedPixels.len,
                                 firstTick: tick, lastTick: tick,
                                 defineCount: 1))

proc ingest(packet: seq[uint8], tick: int, fromInit: bool) =
  for m in parseSpritePacket(packet):
    if m.kind == spkSprite:
      record(m.sprite, tick, fromInit)

# --------------------------------------------------------------- coverage
type Family = tuple[name: string, lo, hi: int]

proc declaredFamilies(): seq[Family] =
  ## Every sprite id `render.nim` can address, written in the renderer's own
  ## constants so this table cannot drift from it.
  ##
  ## This is *addressable* space, not a promise that every id is drawn: the
  ## body block leaves two spare ids per slot (`slot*10 + facing*2 + frame`
  ## uses eight of ten), and `Base + ord(iNone)` is never drawn for the four
  ## item-keyed families. So "emitted < declared" is normal; **"emitted = 0"
  ## is the signal** — that family is either dead code or unreachable in this
  ## episode, and neither is visible on a contact sheet.
  const lastItem = ord(ItemId.high)      # item-keyed ids skip ord(iNone) = 0
  @[(name: "background", lo: SpBackground, hi: SpBackground),
    (name: "burst", lo: SpFwBlack, hi: SpMineFlash),
    (name: "plasma", lo: SpZoneFireA, hi: SpZoneFireB),
    (name: "firestorm", lo: SpFirestormA, hi: SpFirestormB),
    (name: "flood", lo: SpFloodA, hi: SpFloodB),
    (name: "plasma_crit", lo: SpPlasmaCritA, hi: SpPlasmaCritB),
    (name: "camo_glass", lo: SpGlassBody, hi: SpGlassBody),
    (name: "net_mesh", lo: SpNetMesh, hi: SpNetMesh),
    (name: "poison_halo", lo: SpPoisonHaloA, hi: SpPoisonHaloB),
    (name: "void_beam", lo: SpVoidBeam, hi: SpVoidBeam),
    (name: "gold_beam", lo: SpGoldBeam, hi: SpGoldBeam),
    (name: "glitch", lo: SpGlitch, hi: SpGlitch),
    (name: "item_chip", lo: SpItemBase + 1, hi: SpItemBase + lastItem),
    (name: "projectile", lo: SpProjBase + 1, hi: SpProjBase + lastItem),
    (name: "bush", lo: SpBushBase, hi: SpBushBase + 3),
    (name: "hud", lo: SpHudBase, hi: SpHudBase + 3),
    (name: "banner", lo: SpBanner, hi: SpBanner + 1),
    # 400 + slot*10 + facing*2 + frame: 16 slots, stride 10, 8 of them used
    (name: "body", lo: SpBodyBase, hi: SpBodyBase + 15 * 10 + 7),
    (name: "corpse", lo: SpCorpseBase, hi: SpCorpseBase + 15),
    (name: "weapon_glyph", lo: SpWeaponBase + 1, hi: SpWeaponBase + lastItem),
    (name: "mouth_light", lo: SpMouthA, hi: SpMouthB),
    (name: "trail", lo: SpTrailBase + 1, hi: SpTrailBase + lastItem),
    (name: "slot_tag", lo: SpSlotLabelBase, hi: SpSlotLabelBase + 15),
    (name: "hp_band", lo: SpHpBandBase, hi: SpHpBandBase + 2),
    (name: "ring_ghost", lo: SpRingGhost, hi: SpRingGhost),
    (name: "kill_feed", lo: SpKillBase, hi: SpKillBase + 5),
    (name: "channel_halo", lo: SpChannelA, hi: SpChannelB),
    (name: "reveal_mark", lo: SpRevealMark, hi: SpRevealMark),
    (name: "settle_line", lo: SpSettleLine, hi: SpSettleLine),
    (name: "lamp_row", lo: SpLampRow, hi: SpLampRow),
    (name: "reticle", lo: SpReticle, hi: SpReticle),
    (name: "crate_print", lo: SpCratePartBase, hi: SpCratePartBase + 2),
    (name: "ping", lo: SpPingA, hi: SpPingB),
    (name: "hit_flash", lo: SpHitFlash, hi: SpHitFlash),
    (name: "damage_numeral", lo: SpDmgBase, hi: SpDmgBase + 15),
    (name: "pod_crate", lo: SpPodCrateBase + 1, hi: SpPodCrateBase + lastItem),
    (name: "fade_death", lo: SpFadeDeath, hi: SpFadeDeath + FadeStages - 1),
    (name: "fade_ignite", lo: SpFadeIgnite, hi: SpFadeIgnite + FadeStages - 1),
    (name: "fade_mine", lo: SpFadeMine, hi: SpFadeMine + FadeStages - 1),
    (name: "fade_void", lo: SpFadeVoid, hi: SpFadeVoid + FadeStages - 1),
    (name: "pod_label", lo: SpPodLabelBase, hi: SpPodLabelBase + PodPool - 1),
    # Counts derive from render.nim's own constants, never written out as
    # literals. Both families have already gone stale once — the trace grid
    # when it was dirty-tiled, the dither pool when it was resized 16 -> 32 —
    # and a stale range reports phantom `undeclaredEmittedIds` while silently
    # hiding real art from review.
    (name: "trace_cell", lo: SpTraceBase, hi: SpTraceBase + TraceCells - 1),
    (name: "derez", lo: SpDerezWash, hi: SpDerezWireSolid),
    (name: "derez_dither", lo: SpDerezDitherBase,
     hi: SpDerezDitherBase + DerezVariants - 1)]

const
  GiftDelay = 24            # ticks after the shop opens before we request one
  GiftLandingMargin = 120   # ticks for the pod to fly, print and be labelled

when isMainModule:
  let
    outDir = argValue("out", "docs/evidence/sprites")
    seedArg = argInt("seed", 42)
    ticksArg = argInt("ticks", 480)
    wantGift = argInt("gift", 1) != 0
    pngDir = outDir / "png"
  maxVariants = max(1, argInt("variants", 2))

  let original = %*{"seed": seedArg, "max_ticks": max(1, ticksArg),
                    "freeze_ticks": 48}
  var cfg = parseSimConfig(original, mintFixed)
  # `gift=1` promises the pod / crate-print / cargo-label art, but the sponsor
  # shop does not open until tick 1680, so at the default ticks=480 the gift
  # tick is never reached and the flag is a silent no-op — sprite ids 1000+
  # were absent from every default dump. Pull the shop forward far enough for
  # the pod to launch, land and be labelled inside the run, and say so.
  var shopMoved = -1
  if wantGift and ticksArg > 0 and
     cfg.sponsor.shopOpensTick + GiftDelay + GiftLandingMargin > ticksArg:
    shopMoved = max(48, ticksArg div 3)
    cfg.sponsor.shopOpensTick = shopMoved
  var s = initSim(cfg)
  var r: Renderer
  ingest(r.initPacket(s), 0, true)

  var updateBytes = 0
  var frames = 0
  if ticksArg > 0:
    let giftTick = s.cfg.sponsor.shopOpensTick + GiftDelay
    # Same scripted drift as headless.nim / poster.nim: after ignition every
    # survivor walks at the arena centre, which produces fights, deaths, kill
    # feed lines, damage numerals and corpses — i.e. the dynamic sprites that
    # never appear in the init packet.
    while s.phase != phEnded and s.tick < ticksArg:
      if wantGift and s.tick == giftTick:
        discard s.requestGift("dump", 0, -1, "blowgun", Pos(x: 30, y: 24))
      if s.phase == phLive:
        for i in 0 .. 15:
          let a = s.agents[i]
          if a.alive and s.tick >= a.moveReadyTick:
            let cx = ArenaSize div 2
            let cy = ArenaSize div 2
            let dir =
              if a.pos.x < cx and a.pos.y < cy: dSE
              elif a.pos.x < cx and a.pos.y > cy: dNE
              elif a.pos.x > cx and a.pos.y < cy: dSW
              elif a.pos.x > cx and a.pos.y > cy: dNW
              elif a.pos.x < cx: dE
              elif a.pos.x > cx: dW
              elif a.pos.y < cy: dS
              else: dN
            s.submitAction(AgentId(i), Action(kind: akMove, dir: dir))
      s.step()
      let packet = r.updatePacket(s)
      updateBytes += packet.len
      inc frames
      ingest(packet, s.tick, false)

  # ------------------------------------------------------------------ write
  # Wipe first. Filenames encode id AND label (`s0092_proj_darts_0.png`), so
  # any renamed or retired sprite leaves an orphan behind that looks exactly
  # like current output to every downstream tool. That cost a false "green
  # pixels still shipping" alarm on 2026-08-14: id 92 had been reassigned
  # from a collided projectile to a bush, and the stale PNG was the only
  # green left in the dump. Only ever removes the png subdirectory we own.
  removeDir(pngDir)
  createDir(pngDir)
  # id first, then definition order — stable across runs, so two dumps line up
  # cell for cell in the contact sheet.
  recs.sort(proc(a, b: SpriteRec): int =
    if a.id != b.id: cmp(a.id, b.id) else: cmp(a.order, b.order))

  var
    manifest = newJArray()
    totalRaw = 0
    totalCompressed = 0
    pngCount = 0
    idLabels = initOrderedTable[int, seq[string]]()

  for rec in recs.mitems:
    if rec.id notin idLabels:
      idLabels[rec.id] = @[]
    idLabels[rec.id].add(rec.label)
    var vjs = newJArray()
    for vi in 0 ..< rec.variants.len:
      let name = &"s{rec.id:04}_{sanitize(rec.label)}_{vi}.png"
      let vw = rec.variants[vi].w
      let vh = rec.variants[vi].h
      let expected = vw * vh * 4
      if rec.variants[vi].px.len != expected or vw <= 0 or vh <= 0:
        quit(&"dump_sprites: sprite {rec.id} '{rec.label}' decompressed to " &
             &"{rec.variants[vi].px.len} bytes, expected {expected} " &
             &"({vw}x{vh}x4)", 1)
      writeFile(pngDir / name, encodePng(vw, vh, 4,
                                         rec.variants[vi].px[0].addr,
                                         rec.variants[vi].px.len))
      rec.variants[vi].file = "png/" & name
      inc pngCount
      totalRaw += rec.variants[vi].px.len
      totalCompressed += rec.variants[vi].compressedBytes
      vjs.add(%*{
        "file": rec.variants[vi].file,
        "pixHash": rec.variants[vi].pixHashHex,
        "w": vw,
        "h": vh,
        "compressedBytes": rec.variants[vi].compressedBytes,
        "rawBytes": rec.variants[vi].px.len,
        "defineCount": rec.variants[vi].defineCount,
        "firstTick": rec.variants[vi].firstTick,
        "lastTick": rec.variants[vi].lastTick
      })
    var entry = %*{
      "id": rec.id,
      "label": rec.label,
      "w": rec.w,
      "h": rec.h,
      "defineCount": rec.defineCount,
      "distinctVariants": rec.distinctVariants,
      "dumpedVariants": rec.variants.len,
      "firstTick": rec.firstTick,
      "lastTick": rec.lastTick,
      "fromInitPacket": rec.fromInitPacket,
      "dimsVary": rec.dimsVary
    }
    entry["variants"] = vjs
    manifest.add(entry)

  # What the renderer can address vs what this episode actually drew. Without
  # this the sheet's "262 sprite ids" has no denominator, and a family the run
  # never reached is indistinguishable from one the renderer does not have.
  var
    coverage = newJArray()
    declaredIds = 0
    emittedDeclared = 0
    emptyFamilies: seq[string] = @[]
    claimed = initHashSet[int]()
  for f in declaredFamilies():
    var emitted, missing: seq[int] = @[]
    for id in f.lo .. f.hi:
      claimed.incl(id)
      if id in idLabels: emitted.add(id) else: missing.add(id)
    declaredIds += f.hi - f.lo + 1
    emittedDeclared += emitted.len
    if emitted.len == 0:
      emptyFamilies.add(f.name)
    coverage.add(%*{"family": f.name, "lo": f.lo, "hi": f.hi,
                    "declared": f.hi - f.lo + 1, "emitted": emitted.len,
                    "missingIds": missing})
  # An emitted id nobody declares means declaredFamilies() has fallen behind
  # render.nim — the table is only useful while it is complete.
  var undeclared: seq[int] = @[]
  for id in idLabels.keys:
    if id notin claimed:
      undeclared.add(id)

  # An id defined under two different labels is a genuine collision: the
  # client's sprite map is last-define-wins, so one of them is invisible.
  var collisions = newJArray()
  for id, labels in idLabels.pairs:
    if labels.len > 1:
      var c = %*{"id": id, "winner": labels[^1]}
      c["labels"] = %labels
      collisions.add(c)

  var meta = %*{
    "generator": "tools/art/dump_sprites.nim",
    "rs": RS,
    "tileSize": TileSize,
    "tilePxR": TilePxR,
    "worldPx": WorldPx,
    "worldPxR": WorldPxR,
    "arenaSize": ArenaSize,
    "bodyW": BodyWR,
    "bodyH": BodyHR,
    "seed": seedArg,
    "ticksRequested": ticksArg,
    "ticksRun": s.tick,
    "updateFrames": frames,
    "updatePacketBytes": updateBytes,
    "maxVariants": maxVariants,
    "uniqueSpriteIds": idLabels.len,
    "spriteRecords": recs.len,
    "pngCount": pngCount,
    "totalRawBytes": totalRaw,
    "totalCompressedBytes": totalCompressed,
    "giftRequested": wantGift and ticksArg > 0,
    "shopOpensTick": s.cfg.sponsor.shopOpensTick,
    "shopOpensTickMovedForGift": shopMoved >= 0
  }
  meta["collisions"] = collisions
  var cov = %*{"declaredFamilies": coverage.len,
               "presentFamilies": coverage.len - emptyFamilies.len,
               "declaredIds": declaredIds, "emittedIds": emittedDeclared,
               "emptyFamilies": emptyFamilies,
               "undeclaredEmittedIds": undeclared}
  cov["families"] = coverage
  meta["coverage"] = cov
  meta["sprites"] = manifest
  writeFile(outDir / "sprites.json", pretty(meta))

  echo &"dump_sprites: RS={RS} tile={TilePxR} world={WorldPxR}"
  echo &"  ran {frames} update frames to tick {s.tick} (phase={s.phase})"
  echo &"  {idLabels.len} unique sprite ids, {recs.len} (id,label) records, " &
       &"{pngCount} PNGs"
  echo &"  raw {totalRaw} B -> snappy {totalCompressed} B" &
       (if totalCompressed > 0:
          &" ({totalRaw.float / totalCompressed.float:.2f}:1)"
        else: "")
  if collisions.len > 0:
    echo &"  WARNING: {collisions.len} sprite-id collision(s):"
    for c in collisions:
      echo "    id ", c["id"].getInt, " defined as ",
           c["labels"].getElems.mapIt(it.getStr).join(", "),
           "  -> client keeps '", c["winner"].getStr, "'"
  if shopMoved >= 0:
    echo &"  gift=1: sponsor shop moved to tick {shopMoved} (default " &
         &"{parseSimConfig(original, mintFixed).sponsor.shopOpensTick} is " &
         &"unreachable in {ticksArg} ticks), gift at tick {shopMoved + GiftDelay}"
  echo &"  coverage: {coverage.len - emptyFamilies.len}/{coverage.len} " &
       &"declared sprite families present, {emittedDeclared}/{declaredIds} " &
       "addressable ids emitted (spare ids inside a family are normal — " &
       "an empty family is not)"
  if emptyFamilies.len > 0:
    echo &"  WARNING: {emptyFamilies.len} declared famil(ies) emitted nothing " &
         "— absent from every sheet, and absence looks like 'no such art':"
    for f in coverage:
      if f["emitted"].getInt == 0:
        echo &"""    {f["family"].getStr:<22} ids {f["lo"].getInt}..""" &
             &"""{f["hi"].getInt}  ({f["declared"].getInt} ids)"""
  if undeclared.len > 0:
    echo &"  WARNING: {undeclared.len} emitted id(s) outside declaredFamilies()" &
         " — the coverage table has fallen behind render.nim: " &
         undeclared.mapIt($it).join(", ")
  echo &"  wrote {outDir}/sprites.json"
