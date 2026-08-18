## Frame dump — the art iteration loop.
##
## Runs a headless episode through the REAL renderer, decodes the sprite_v1
## packets it emits, composites them exactly as the browser viewer would, and
## writes one PNG. No Docker, no websocket, no browser: the fastest way to
## eyeball what the art actually looks like on the board.
##
## This is deliberately a *consumer* of the packet stream rather than a second
## renderer — whatever you change in game/render.nim shows up here, and if the
## packet is malformed this tool sees the same thing the viewer would.
##
## Usage: frame_dump [seed] [ticks] [outPath] [scale]
##   seed    PRNG seed                       (default 42)
##   ticks   stop after this many sim ticks  (default 400; capped by match end)
##   out     PNG path                        (default docs/evidence/frame.png)
##   scale   nearest-neighbour upscale       (default 2)
##
## Board art lives on LayerMap in RS space (WorldPxR x WorldPxR). HUD layers
## are UI-space overlays and are dumped separately with --hud.

import std/[algorithm, json, os, strformat, strutils, tables]
import pixie, supersnappy
import bitworld/spriteprotocol
import zero_sum/[types, sim]
import render, demo_script

type
  DecodedSprite = object
    w, h: int
    px: seq[uint8]

  Scene = object
    sprites: Table[int, DecodedSprite]
    objects: OrderedTable[int, SpritePacketObject]
    viewports: Table[int, (int, int)]

proc mintFixed(): uint64 = 42'u64

proc apply(scene: var Scene, packet: seq[uint8]) =
  ## Fold one sprite_v1 packet into the running scene, the way a viewer does.
  for m in parseSpritePacket(packet):
    case m.kind
    of spkSprite:
      let raw = supersnappy.uncompress(m.sprite.compressedPixels)
      var px = newSeq[uint8](raw.len)
      for i in 0 ..< raw.len:
        px[i] = uint8(raw[i])
      scene.sprites[m.sprite.id] =
        DecodedSprite(w: m.sprite.width, h: m.sprite.height, px: px)
    of spkObject:
      scene.objects[m.objectDef.id] = m.objectDef
    of spkDeleteObject:
      scene.objects.del(m.objectId)
    of spkClearObjects:
      scene.objects.clear()
    of spkViewport:
      scene.viewports[m.viewport.layer] = (m.viewport.width, m.viewport.height)
    of spkLayer:
      discard

proc composite(scene: Scene, layer, w, h: int): seq[uint8] =
  ## Painter's algorithm: ascending z, ties broken by object id so the result
  ## is stable run to run. Unpremultiplied source-over, matching sprite_v1.
  result = newSeq[uint8](w * h * 4)
  var order: seq[SpritePacketObject] = @[]
  for _, o in scene.objects:
    if o.layer == layer:
      order.add(o)
  order.sort(proc(a, b: SpritePacketObject): int =
    if a.z != b.z: cmp(a.z, b.z) else: cmp(a.id, b.id))

  for o in order:
    if o.spriteId notin scene.sprites:
      continue
    let sp = scene.sprites[o.spriteId]
    for y in 0 ..< sp.h:
      let dy = o.y + y
      if dy < 0 or dy >= h:
        continue
      for x in 0 ..< sp.w:
        let dx = o.x + x
        if dx < 0 or dx >= w:
          continue
        let si = (y * sp.w + x) * 4
        if si + 3 >= sp.px.len:
          continue
        let a = int(sp.px[si + 3])
        if a == 0:
          continue
        let di = (dy * w + dx) * 4
        if a == 255:
          for c in 0 .. 3:
            result[di + c] = sp.px[si + c]
        else:
          for c in 0 .. 2:
            result[di + c] = uint8(
              (int(sp.px[si + c]) * a + int(result[di + c]) * (255 - a)) div 255)
          result[di + 3] = uint8(max(int(result[di + 3]), a))

proc writePng(px: seq[uint8], w, h, scale: int, path: string) =
  let ow = w * scale
  let oh = h * scale
  var img = newImage(ow, oh)
  for y in 0 ..< oh:
    for x in 0 ..< ow:
      let si = ((y div scale) * w + (x div scale)) * 4
      img[x, y] = rgba(px[si], px[si + 1], px[si + 2], 255'u8)
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  img.writeFile(path)

when isMainModule:
  let seedArg = if paramCount() >= 1: parseBiggestInt(paramStr(1)) else: 42
  let ticksArg = if paramCount() >= 2: parseInt(paramStr(2)) else: 400
  let outArg =
    if paramCount() >= 3: paramStr(3) else: "docs/evidence/frame.png"
  let scaleArg = if paramCount() >= 4: parseInt(paramStr(4)) else: 2

  # max_ticks is validated to 100..20000 by parseSimConfig; ask for the full
  # match and stop early ourselves so any tick count is dumpable.
  let original = %*{"seed": seedArg, "max_ticks": 20000, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, mintFixed)
  var s = initSim(cfg)
  var r: Renderer
  var scene = Scene()
  scene.apply(r.initPacket(s))

  while s.phase != phEnded and s.tick < ticksArg:
    s.driveScript()
    s.step()
    scene.apply(r.updatePacket(s))

  let (mw, mh) =
    if LayerMap in scene.viewports: scene.viewports[LayerMap]
    else: (WorldPxR, WorldPxR)
  let px = scene.composite(LayerMap, mw, mh)
  writePng(px, mw, mh, scaleArg, outArg)

  var objCount = 0
  for _, o in scene.objects:
    if o.layer == LayerMap: inc objCount
  echo &"tick={s.tick} phase={s.phase} alive={s.aliveCount()}"
  echo &"sprites={scene.sprites.len} map_objects={objCount} viewport={mw}x{mh}"
  echo &"frame: {outArg} {mw * scaleArg}x{mh * scaleArg}"
