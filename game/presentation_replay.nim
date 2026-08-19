## Static replay artifact: the exact sprite_v1 packets produced for the public
## live spectator. Replays are presentation recordings, so the browser can
## render them without a game server or a second implementation of the sim.

import zippy

const
  PresentationReplayMagic* = "ZERO_SUM_FRAMES"
  PresentationReplayVersion* = 1'u16
  PresentationReplayTickRate* = 24'u16

type
  PresentationFrame* = object
    tick*: uint32
    packet*: seq[uint8]

  PresentationReplay* = object
    frames*: seq[PresentationFrame]

proc addU16(data: var string, value: uint16) =
  data.add(char(value and 0xff))
  data.add(char(value shr 8))

proc addU32(data: var string, value: uint32) =
  for shift in [0, 8, 16, 24]:
    data.add(char((value shr shift) and 0xff))

proc readU16(data: string, offset: var int): uint16 =
  if offset + 2 > data.len:
    raise newException(ValueError, "truncated presentation replay")
  result = uint16(uint8(data[offset])) or
    (uint16(uint8(data[offset + 1])) shl 8)
  offset += 2

proc readU32(data: string, offset: var int): uint32 =
  if offset + 4 > data.len:
    raise newException(ValueError, "truncated presentation replay")
  result = uint32(uint8(data[offset])) or
    (uint32(uint8(data[offset + 1])) shl 8) or
    (uint32(uint8(data[offset + 2])) shl 16) or
    (uint32(uint8(data[offset + 3])) shl 24)
  offset += 4

proc addFrame*(replay: var PresentationReplay, tick: int,
               packet: seq[uint8]) =
  doAssert tick >= 0
  doAssert replay.frames.len == 0 or
    uint32(tick) >= replay.frames[^1].tick
  replay.frames.add(PresentationFrame(tick: uint32(tick), packet: packet))

proc encodeFrames*(replay: PresentationReplay): string =
  ## The framing layer on its own, before compression. Split out from
  ## encodePresentationReplay so the round-trip we actually own can be tested
  ## without going through zippy: zippy 0.10.19's `uncompress` miscomputes
  ## adler32 on multi-MB buffers and rejects its OWN valid output (verified
  ## 2026-08-19 — Python zlib reads the same artifact, and the trailer
  ## checksum matches Python's adler32 of the result). Only inflate is
  ## affected, and the game never inflates in production, so shipped replays
  ## are correct; it is the in-process round-trip assertion that cannot use
  ## it. 0.10.19 is the latest release, so there is no fix to pull.
  doAssert replay.frames.len > 0
  var raw = PresentationReplayMagic
  raw.addU16(PresentationReplayVersion)
  raw.addU16(PresentationReplayTickRate)
  raw.addU32(uint32(replay.frames.len))
  for frame in replay.frames:
    raw.addU32(frame.tick)
    raw.addU32(uint32(frame.packet.len))
    for value in frame.packet:
      raw.add(char(value))
  raw

proc encodePresentationReplay*(replay: PresentationReplay): string =
  compress(encodeFrames(replay), BestCompression, dfZlib)

proc decodeFrames*(raw: string): PresentationReplay =
  ## Inverse of encodeFrames, on the uncompressed buffer.
  if raw.len < PresentationReplayMagic.len or
     raw[0 ..< PresentationReplayMagic.len] != PresentationReplayMagic:
    raise newException(ValueError, "not a Zero Sum presentation replay")
  var offset = PresentationReplayMagic.len
  if raw.readU16(offset) != PresentationReplayVersion:
    raise newException(ValueError, "unsupported presentation replay version")
  if raw.readU16(offset) != PresentationReplayTickRate:
    raise newException(ValueError, "unsupported presentation replay tick rate")
  let frameCount = raw.readU32(offset)
  if frameCount == 0 or frameCount > 100_000:
    raise newException(ValueError, "invalid presentation replay frame count")
  for _ in 0 ..< int(frameCount):
    let tick = raw.readU32(offset)
    if result.frames.len > 0 and tick < result.frames[^1].tick:
      raise newException(ValueError, "out-of-order presentation replay frame")
    let packetLength = raw.readU32(offset)
    if packetLength > uint32(raw.len - offset):
      raise newException(ValueError, "truncated presentation replay packet")
    var packet = newSeq[uint8](int(packetLength))
    for i in 0 ..< packet.len:
      packet[i] = uint8(raw[offset + i])
    offset += packet.len
    result.frames.add(PresentationFrame(tick: tick, packet: packet))
  if offset != raw.len:
    raise newException(ValueError, "trailing presentation replay bytes")

proc parsePresentationReplay*(artifact: string): PresentationReplay =
  decodeFrames(uncompress(artifact, dfZlib))
