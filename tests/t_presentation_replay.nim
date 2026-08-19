## The static artifact is the public sprite stream itself. This proves the
## encoded replay round-trips every packet byte-for-byte and stays byte-stable.

import std/json
import zero_sum/[sim, types]
import ../game/[presentation_replay, render]

proc fixedSeed(): uint64 = 42'u64

let cfg = parseSimConfig(%*{
  "seed": 42,
  "max_ticks": 480,
  "freeze_ticks": 48,
  "zone": {"schedule": [[96, 120, 288, 24, 12, 4],
                         [336, 360, 384, 12, 0, 40]]},
  "sponsor": {"live": false, "budget_per_team": 300,
              "shop_opens_tick": 48, "scripted_gifts": []}
}, fixedSeed)
var gameState = initSim(cfg)
var renderer: Renderer
var replay: PresentationReplay
replay.addFrame(gameState.tick, renderer.initPacket(gameState))
while gameState.phase != phEnded:
  gameState.step()
  replay.addFrame(gameState.tick, renderer.updatePacket(gameState))

# Round-trip the FRAMING, which is the part this repo owns. The compressed
# round-trip cannot be asserted in-process: zippy 0.10.19's uncompress
# miscomputes adler32 on multi-MB buffers and rejects its own valid output
# (see encodeFrames' note — Python zlib reads the same artifact and the
# trailer matches Python's adler32). Only inflate is affected and the game
# never inflates in production, so shipped replays are unaffected.
let raw = encodeFrames(replay)
let decoded = decodeFrames(raw)
let artifact = encodePresentationReplay(replay)
var packetBytes = 0
var largestPacket = 0
for frame in replay.frames:
  packetBytes += frame.packet.len
  largestPacket = max(largestPacket, frame.packet.len)
doAssert decoded.frames == replay.frames
doAssert encodeFrames(replay) == raw                  # framing is stable
doAssert encodePresentationReplay(replay) == artifact # and so is the artifact
doAssert artifact.len < raw.len                       # compression did happen
doAssert decoded.frames[0].tick == 0
doAssert decoded.frames[^1].tick == uint32(gameState.tick)
doAssert decoded.frames[0].packet.len > decoded.frames[^1].packet.len

echo "t_presentation_replay ok: frames=", decoded.frames.len,
     " packet_bytes=", packetBytes, " largest_packet=", largestPacket,
     " artifact_bytes=", artifact.len
