## Poster — "every screenshot a true story" marketing tool, and the review
## harness for board art.
## Runs a full headless episode through the real renderer and writes the
## final burned-in trace map (scars + afterglow over the end-state arena)
## as a PNG poster.
## Usage: poster [seed] [maxTicks] [scale]  (defaults 42, 9120, auto)
##
## Everything here is expressed in RS units so it survives an RS change:
## the two source buffers live in *different* pixel spaces and the wire is
## the arbiter of how they meet (see the compose step below).

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
      discard s.requestGift("poster", 0, "blowgun", Pos(x: 30, y: 24))
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
  #
  # Both buffers are RS-native (WorldPxR^2), so the source index equals the
  # dest index. This has been wrong twice and in opposite directions, so the
  # sizes are asserted rather than assumed:
  #   - Before 2026-08-13 the compose used WorldPx as the stride for both,
  #     smearing the top WorldPx div RS background rows across the frame.
  #   - Then `traceSpritePixels` moved to RS-native, and the `div RS` sample
  #     added to fix the first bug became the second one — the overlay was
  #     read at quarter scale and tiled. `nim check` passes either way, so
  #     only a runtime assert catches it; poster is the art-review harness
  #     and a harness that lies is worse than no harness.
  let bg = backgroundPixels(s.arena, s.effectiveSafeRadius(), s.derezLevel())
  let overlay = r.traceSpritePixels(s)
  doAssert bg.len == WorldPxR * WorldPxR * 4, "background is not RS-native"
  doAssert overlay.len == WorldPxR * WorldPxR * 4, "trace overlay is not RS-native"
  var composed = newSeq[uint8](WorldPxR * WorldPxR * 4)
  for y in 0 ..< WorldPxR:
    for x in 0 ..< WorldPxR:
      let d = (y * WorldPxR + x) * 4                       # both are RS-space
      let a = int(overlay[d + 3])
      for c in 0 .. 2:
        composed[d + c] = uint8((int(bg[d + c]) * (255 - a) +
                                 int(overlay[d + c]) * a) div 255)
      composed[d + 3] = 255

  # Nearest-neighbour zoom, then write the PNG. The default holds the poster
  # near PosterTargetPx however RS moves (RS=2 -> x2, RS=4 -> x1), which also
  # keeps it the same size as `frame_dump 42 400 out.png 2` for side-by-side
  # review. Pass an explicit scale to review art at 1:1.
  const PosterTargetPx = 1152
  let scale =
    if paramCount() >= 3: max(1, parseInt(paramStr(3)))
    else: max(1, PosterTargetPx div WorldPxR)
  let outPx = WorldPxR * scale
  var img = newImage(outPx, outPx)
  for y in 0 ..< outPx:
    for x in 0 ..< outPx:
      let si = ((y div scale) * WorldPxR + (x div scale)) * 4
      img[x, y] = rgba(composed[si], composed[si + 1], composed[si + 2], 255)

  createDir("docs/evidence")
  let outPath = "docs" / "evidence" / ("poster_" & $seedArg & ".png")
  img.writeFile(outPath)
  echo &"episode done: ticks={s.tick} phase={s.phase} alive={s.aliveCount()} winner={s.winnerSlot}"
  echo &"poster: {outPath} {outPx}x{outPx} (board {WorldPxR}px at RS={RS}, x{scale})"
