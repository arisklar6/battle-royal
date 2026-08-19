## Replay video export — HD match videos from real league artifacts.
##
## Consumes a presentation replay (the exact sprite_v1 packet stream the live
## spectator saw, downloaded from the platform or written to results/), folds
## every packet through the same scene model the browser viewer uses, and
## writes one PNG per recorded frame plus an ffmpeg invocation to make an MP4.
## Like frame_dump, this is a CONSUMER of the packet stream, not a second
## renderer: what shipped on the wire is what lands in the video.
##
## Usage: replay_video REPLAY.replay OUTDIR [scale] [everyN] [fromTick] [toTick]
##   scale     nearest-neighbour upscale of the 1152px board (default 1)
##   everyN    render every Nth recorded frame (default 1; 2 halves the work)
##   from/to   tick range filter (defaults: whole match)
##
## Then:  ffmpeg -framerate 24 -i OUTDIR/f_%05d.png \
##          -c:v libx264 -pix_fmt yuv420p -crf 18 match.mp4
## (the tool prints the exact command, adjusted for everyN)

import std/[algorithm, os, strformat, strutils, tables]
import pixie, supersnappy
import bitworld/spriteprotocol
import presentation_replay

type
  DecodedSprite = object
    w, h: int
    px: seq[uint8]
  Scene = object
    sprites: Table[int, DecodedSprite]
    objects: OrderedTable[int, SpritePacketObject]
    viewports: Table[int, (int, int)]

proc apply(scene: var Scene, packet: seq[uint8]) =
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
  ## Painter's algorithm, ascending z then object id — the viewer's rules.
  result = newSeq[uint8](w * h * 4)
  var order: seq[(int, int)]
  for id, o in scene.objects:
    if int(o.layer) == layer:
      order.add((int(o.z), id))
  order.sort()
  for (_, id) in order:
    let o = scene.objects[id]
    if int(o.spriteId) notin scene.sprites:
      continue
    let sp = scene.sprites[int(o.spriteId)]
    let ox = int(o.x)
    let oy = int(o.y)
    for y in 0 ..< sp.h:
      let ty = oy + y
      if ty < 0 or ty >= h: continue
      for x in 0 ..< sp.w:
        let tx = ox + x
        if tx < 0 or tx >= w: continue
        let si = (y * sp.w + x) * 4
        let al = int(sp.px[si + 3])
        if al == 0: continue
        let di = (ty * w + tx) * 4
        for ch in 0 .. 2:
          result[di + ch] = uint8((int(sp.px[si + ch]) * al +
                                   int(result[di + ch]) * (255 - al)) div 255)
        result[di + 3] = 255

proc writePng(px: seq[uint8], w, h, scale: int, path: string) =
  var img = newImage(w * scale, h * scale)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      let c = rgba(px[i], px[i + 1], px[i + 2], 255)
      for sy in 0 ..< scale:
        for sx in 0 ..< scale:
          img[x * scale + sx, y * scale + sy] = c
  img.writeFile(path)

when isMainModule:
  if paramCount() < 2:
    quit("usage: replay_video REPLAY OUTDIR [scale] [everyN] [fromTick] [toTick]")
  let replayPath = paramStr(1)
  let outDir = paramStr(2)
  let scale = (if paramCount() >= 3: parseInt(paramStr(3)) else: 1)
  let everyN = (if paramCount() >= 4: max(1, parseInt(paramStr(4))) else: 1)
  let fromTick = (if paramCount() >= 5: parseInt(paramStr(5)) else: 0)
  let toTick = (if paramCount() >= 6: parseInt(paramStr(6)) else: int.high)
  createDir(outDir)

  let replay = parsePresentationReplay(readFile(replayPath))
  echo &"replay: {replay.frames.len} recorded frames, " &
       &"ticks {replay.frames[0].tick}..{replay.frames[^1].tick}"

  var scene: Scene
  var written = 0
  var boardW = 1152
  var boardH = 1152
  for i, frame in replay.frames:
    scene.apply(frame.packet)
    if scene.viewports.hasKey(0):
      (boardW, boardH) = scene.viewports[0]
    if int(frame.tick) < fromTick or int(frame.tick) > toTick:
      continue
    if i mod everyN != 0:
      continue
    writePng(scene.composite(0, boardW, boardH), boardW, boardH, scale,
             outDir / &"f_{written:05}.png")
    inc written
    if written mod 200 == 0:
      echo &"  {written} frames written (tick {frame.tick})"

  echo &"{written} frames -> {outDir}"
  let fps = max(1, 24 div everyN)
  echo "encode with:"
  echo &"  ffmpeg -y -framerate {fps} -i {outDir}/f_%05d.png " &
       "-c:v libx264 -pix_fmt yuv420p -crf 18 match.mp4"
