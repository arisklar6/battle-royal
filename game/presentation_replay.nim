## Static replay artifact: the exact sprite_v1 packets produced for the public
## live spectator. Replays are presentation recordings, so the browser can
## render them without a game server or a second implementation of the sim.

import zippy

const
  PresentationReplayMagic* = "BATTLE_ROYAL_FRAMES"
  LegacyPresentationReplayMagic* = "ZERO_SUM_FRAMES"
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
  ## without going through zippy: zippy 0.10.19's INFLATE corrupts some
  ## multi-MB streams. Verified 2026-08-19 by inflating the same stream with
  ## `dfDeflate` (which skips checksum verification) and diffing against
  ## Python's zlib: zippy returns 6,373,670 bytes where zlib returns
  ## 6,373,669, first differing at offset 5,346,342. The ZippyError that
  ## surfaces says "Checksum verification failed", which reads like a checksum
  ## bug and is not — adler32 is correctly catching real corruption.
  ##
  ## Deflate is fine (Python reads what zippy writes), it is level-dependent
  ## (the same payload round-trips at BestSpeed and DefaultCompression), and
  ## it is data-dependent, not a size cliff — a real 28.8 MB league replay
  ## parses correctly. 0.10.19 is the latest release. Nothing in the shipped
  ## game inflates: the server refuses replay mode and the static viewer
  ## bundle plays artifacts in the browser, so only this in-process assertion
  ## and tools/replay_video.nim use that decoder.
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

proc matchesMagic(raw, magic: string): bool =
  raw.len >= magic.len and raw[0 ..< magic.len] == magic

proc decodeFrames*(raw: string): PresentationReplay =
  ## Inverse of encodeFrames, on the uncompressed buffer. Accepts both the
  ## current magic and the legacy one so replays recorded before the game was
  ## renamed (Zero Sum -> Battle Royal) keep parsing.
  var offset: int
  if raw.matchesMagic(PresentationReplayMagic):
    offset = PresentationReplayMagic.len
  elif raw.matchesMagic(LegacyPresentationReplayMagic):
    offset = LegacyPresentationReplayMagic.len
  else:
    raise newException(ValueError, "not a Battle Royal presentation replay")
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
