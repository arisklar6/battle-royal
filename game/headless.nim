## Headless short-episode runner — the per-step no-regression check.
## Scripted inputs only; prints an event digest and writes hash/event artifacts.
## Usage: headless [seed] [maxTicks]  (defaults 42, 600)

import std/[json, os, strformat, strutils]
import battle_royal/[prng, types, arena, sim]

proc mintFromOs(): uint64 =
  ## Boundary-only entropy (never inside the sim). Step-1 harness uses a fixed
  ## fallback so runs are reproducible unless a seed argument says otherwise.
  42'u64

when isMainModule:
  let seedArg = if paramCount() >= 1: parseBiggestInt(paramStr(1)) else: 42
  let ticksArg = if paramCount() >= 2: parseInt(paramStr(2)) else: 600

  let original = %*{"seed": seedArg, "max_ticks": ticksArg, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, mintFromOs)
  var s = initSim(cfg)

  var eventLines: seq[string] = @[]
  # Script: slot 3 steps off its pedestal at t=10 (mine demo). After ignition,
  # every survivor drifts toward the arena center on its move cooldown.
  while s.phase != phEnded:
    if s.tick == 10:
      s.submitAction(AgentId(3), Action(kind: akMove, dir: dN))
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
    for e in s.events:
      eventLines.add(&"[t={e.tick:05}] {e.kind} slot={e.slot} pos=({e.pos.x},{e.pos.y})")

  createDir("results")
  writeFile("results/effective_config.json", effectiveConfigJson(cfg, original))
  var hashLines: seq[string] = @[]
  for (t, h) in s.hashes:
    hashLines.add($t & " " & toHex(h))
  writeFile("results/hashes.txt", hashLines.join("\n") & "\n")
  writeFile("results/events.txt", eventLines.join("\n") & "\n")

  echo &"episode done: ticks={s.tick} phase={s.phase} alive={s.aliveCount()} winner={s.winnerSlot}"
  echo &"events={eventLines.len} first: {eventLines[0]}"
  echo &"final hash: {toHex(s.hashes[^1][1])}"
  for line in eventLines:
    if "MineExplosion" in line or "Ignition" in line or "MatchEnd" in line:
      echo line
