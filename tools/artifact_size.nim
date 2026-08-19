## Full-match artifact measurement — the Phase 1 gate (ART_UPGRADE_PLAN §1).
##
## Runs a complete league-standard match (variant "solo", max_ticks 9120, the
## real 7-step zone schedule and the scripted flood) through the REAL renderer,
## records every packet into a PresentationReplay, and reports the encoded
## artifact size. That artifact is what the static replay viewer downloads, so
## its size — not the sum of the packets — is the number the 24 MiB gate is
## stated against.
##
## Usage: artifact_size [seed]

import std/[json, monotimes, strformat, strutils, times, os]
import battle_royal/[types, sim]
import presentation_replay, render, demo_script

proc mintFixed(): uint64 = 42'u64

when isMainModule:
  let seedArg = if paramCount() >= 1: parseBiggestInt(paramStr(1)) else: 42

  ## coworld_manifest_template.json .variants[0].game_config — "League
  ## standard: full 9120-tick match, fast 5-minute ring, one scripted flood".
  let original = %*{
    "seed": seedArg,
    "league_mode": "solo",
    "max_ticks": 9120,
    "freeze_ticks": 240,
    "stat_budget": 20,
    "zone": {"schedule": [[1440, 1632, 2064, 24, 19, 1],
                          [2352, 2544, 2976, 19, 15, 2],
                          [3264, 3456, 3888, 15, 11, 4],
                          [4176, 4368, 4800, 11, 8, 6],
                          [5088, 5280, 5712, 8, 5, 8],
                          [6000, 6192, 6624, 5, 3, 16],
                          [6912, 7104, 7536, 3, 0, 24]]},
    "events": [{"kind": "flood", "rect": [10, 22, 14, 26],
                "from_tick": 4400, "duration": 720}],
    "sponsor": {"live": false, "budget_per_team": 300,
                "shop_opens_tick": 1680, "scripted_gifts": []}
  }
  let cfg = parseSimConfig(original, mintFixed)
  var s = initSim(cfg)
  var r: Renderer
  var replay: PresentationReplay
  var packetBytes = 0
  var largest = 0
  let initStart = getMonoTime()
  let initPkt = r.initPacket(s)
  let initMs = (getMonoTime() - initStart).inMicroseconds.float / 1000.0
  ## Every viewer that connects mid-match pays this on the match thread.
  ## The first one rasterizes; Phase 0's cache serves the rest.
  let warmStart = getMonoTime()
  discard r.initPacket(s)
  let warmMs = (getMonoTime() - warmStart).inMicroseconds.float / 1000.0
  replay.addFrame(s.tick, initPkt)
  packetBytes += initPkt.len

  ## The other half of the RS gate: rendering happens on the match thread
  ## against a 41.7 ms frame, so a cap that fits the wire but not the tick
  ## is not a pass.
  var worstMs = 0.0
  var worstTick = 0
  var totalMs = 0.0
  while s.phase != phEnded:
    s.driveScript()
    s.step()
    let t0 = getMonoTime()
    let pkt = r.updatePacket(s)
    let ms = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    totalMs += ms
    if ms > worstMs:
      worstMs = ms
      worstTick = s.tick
    replay.addFrame(s.tick, pkt)
    packetBytes += pkt.len
    largest = max(largest, pkt.len)

  let artifact = encodePresentationReplay(replay)
  echo &"seed={seedArg} RS={RS} viewport={WorldPxR}x{WorldPxR} " &
       &"final_tick={s.tick} frames={replay.frames.len}"
  echo &"init_packet_bytes={initPkt.len}"
  echo &"in_match_packet_bytes={packetBytes - initPkt.len} " &
       &"largest_update_packet={largest}"
  echo &"artifact_bytes={artifact.len} " &
       &"artifact_mib={float(artifact.len) / 1048576.0:.3f}"
  echo &"initPacket_cold_ms={initMs:.2f} initPacket_cached_ms={warmMs:.2f} " &
       &"updatePacket_mean_ms={totalMs / float(replay.frames.len - 1):.3f} " &
       &"updatePacket_worst_ms={worstMs:.2f}@t{worstTick} (budget 41.7)"
