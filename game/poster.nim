## Poster — "every screenshot a true story" marketing tool.
## Runs a full headless episode through the real renderer and writes the
## final burned-in trace map (scars + afterglow over the end-state arena)
## as a PNG poster.
## Usage: poster [seed] [maxTicks]  (defaults 42, 9120)

import std/[json, os, strformat, strutils]
import pixie

include render

proc mintFixed(): uint64 =
  ## Boundary-only entropy; fixed so poster runs are reproducible.
  42'u64

when isMainModule:
  let seedArg = if paramCount() >= 1: parseBiggestInt(paramStr(1)) else: 42
  let ticksArg = if paramCount() >= 2: parseInt(paramStr(2)) else: 9120

  let original = %*{"seed": seedArg, "max_ticks": ticksArg, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, mintFixed)
  var s = initSim(cfg)
  var r: Renderer
  discard r.initPacket(s)

  let giftTick = s.cfg.sponsor.shopOpensTick + 24
  # Script: post-ignition, every survivor drifts toward the arena center on
  # its move cooldown (same drift script as headless.nim). Mid-game, one
  # sponsor gift lands so the poster carries the drop story too.
  while s.phase != phEnded:
    if s.tick == giftTick:
      discard s.requestGift("poster", 0, -1, "blowgun", Pos(x: 30, y: 24))
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
    discard r.updatePacket(s)

  # Compose: end-state background with the trace/scar overlay alpha-blended.
  let bg = backgroundPixels(s.arena, s.effectiveSafeRadius(), s.derezLevel())
  let overlay = r.traceSpritePixels(s)
  var composed = newSeq[uint8](WorldPx * WorldPx * 4)
  for i in 0 ..< WorldPx * WorldPx:
    let o = i * 4
    let a = int(overlay[o + 3])
    composed[o] = uint8((int(bg[o]) * (255 - a) + int(overlay[o]) * a) div 255)
    composed[o + 1] =
      uint8((int(bg[o + 1]) * (255 - a) + int(overlay[o + 1]) * a) div 255)
    composed[o + 2] =
      uint8((int(bg[o + 2]) * (255 - a) + int(overlay[o + 2]) * a) div 255)
    composed[o + 3] = 255

  # Upscale x4 nearest-neighbor and write the PNG.
  const Scale = 4
  const OutPx = WorldPx * Scale
  var img = newImage(OutPx, OutPx)
  for y in 0 ..< OutPx:
    for x in 0 ..< OutPx:
      let si = ((y div Scale) * WorldPx + (x div Scale)) * 4
      img[x, y] = rgba(composed[si], composed[si + 1], composed[si + 2], 255)

  createDir("docs/evidence")
  let outPath = "docs" / "evidence" / ("poster_" & $seedArg & ".png")
  img.writeFile(outPath)
  echo &"episode done: ticks={s.tick} phase={s.phase} alive={s.aliveCount()} winner={s.winnerSlot}"
  echo &"poster: {outPath} {OutPx}x{OutPx}"
