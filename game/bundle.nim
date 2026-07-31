## Replay bundle (DESIGN §14): zip containing the engine replay stream plus
## human/machine artifacts. Written to COGAME_SAVE_REPLAY_URI as opaque bytes.

import std/[json, os, tables, times]
import bitworld/replays
import zippy/ziparchives_v1
import zippy/ziparchives
import zero_sum/[types, sim, version]
import transcript

proc zeroSumReplaySpec*(): ReplaySpec =
  ReplaySpec(
    magic: ZeroSumReplayMagic,
    formatVersion: ZeroSumReplayFormatVersion,
    gameName: ZeroSumGameName,
    gameVersion: ZeroSumVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoError)

proc writeReplayStream*(path: string, effectiveConfig: string, s: Sim) =
  ## Engine replay stream: header w/ COMPLETE EFFECTIVE config (minted seed
  ## included, tokens stripped — DESIGN §14), joins, per-tick client inputs
  ## (JSON action payloads), tick hashes. Tokens are NEVER written (join token
  ## field left empty on purpose).
  var w = openReplayWriter(path, effectiveConfig, zeroSumReplaySpec())
  for slot in 0 .. 15:
    w.writeJoin(tickTime(0, 24), slot, "P" & $slot, slot, "")
  var inputIdx = 0
  for (tick, hash) in s.hashes:
    while inputIdx < s.inputLog.len and s.inputLog[inputIdx].tick <= tick:
      let inp = s.inputLog[inputIdx]
      var bytes = newSeq[uint8](inp.payload.len)
      for i, c in inp.payload:
        bytes[i] = uint8(ord(c))
      w.writeClientInput(tickTime(inp.tick, 24), inp.slot, bytes)
      inc inputIdx
    w.writeHash(uint32(tick), hash)
  closeReplayWriter(w)

proc inputLogJson(s: Sim): string =
  var arr = newJArray()
  for inp in s.inputLog:
    arr.add(%*{"tick": inp.tick, "slot": inp.slot,
               "action": parseJson(inp.payload)})
  $arr

proc sponsorLogJson*(s: Sim): string =
  ## DESIGN §14: every accept AND reject.
  var arr = newJArray()
  for r in s.sponsorLog:
    arr.add(%*{"tick_requested": r.tickRequested,
               "tick_landed": (if r.tickLanded >= 0: %r.tickLanded else: newJNull()),
               "sponsor": r.sponsor,
               "team": (if r.team in 0 .. 7: %TeamNames[r.team] else: newJNull()),
               "recipient_slot": r.recipientSlot, "item": r.itemId,
               "cost": r.cost, "status": $r.status,
               "reason": (if r.reason.len > 0: %r.reason else: newJNull()),
               "balance_after": r.balanceAfter})
  $arr

proc resultsJson*(s: Sim): string =
  ## DESIGN §12.2 — schema-required scores + declared parallel arrays.
  var scores = newJArray()
  var placements = newJArray()
  var kills = newJArray()
  var damage = newJArray()
  var survival = newJArray()
  var gifts = newJArray()
  let places = s.computePlacements()
  var giftCount: array[16, int]
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.recipientSlot in 0 .. 15:
      inc giftCount[r.recipientSlot]
  for i in 0 .. 15:
    let a = s.agents[i]
    scores.add(%scoreFor(places[i], a.kills))
    placements.add(%places[i])
    kills.add(%a.kills)
    damage.add(%(a.damageDealtCenti div 100))
    survival.add(%(if a.alive: s.tick else: a.deathTick))
    gifts.add(%giftCount[i])
  let winnerTeam =
    if s.winnerSlot >= 0: %teamName(AgentId(s.winnerSlot)) else: newJNull()
  $(%*{"scores": scores, "placements": placements, "kills": kills,
       "damage_dealt": damage, "survival_ticks": survival,
       "gifts_received": gifts,
       "winner_slot": s.winnerSlot, "winner_team": winnerTeam,
       "match_ticks": s.tick, "seed": cast[int64](s.cfg.seed)})

proc matchSummaryJson*(s: Sim, seed: uint64): string =
  var deaths = newJArray()
  for a in s.agents:
    if not a.alive:
      deaths.add(%*{"slot": int(a.slot), "tick": a.deathTick})
  $(%*{"game": ZeroSumGameName, "version": ZeroSumVersion,
       "match_ticks": s.tick, "winner_slot": s.winnerSlot,
       "alive": s.aliveCount(), "seed": cast[int64](seed), "deaths": deaths})

proc buildReplayZip*(workDir: string, effectiveConfig: string, s: Sim): string =
  ## Returns the zip BYTES. workDir holds the temporary stream file.
  createDir(workDir)
  let streamPath = workDir / "replay.zsr"
  writeReplayStream(streamPath, effectiveConfig, s)
  let archive = ZipArchive()
  let stamp = fromUnix(0)  # fixed timestamp: byte-stable artifacts
  archive.contents["replay.zsr"] = ArchiveEntry(
    kind: ekFile, contents: readFile(streamPath), lastModified: stamp)
  archive.contents["input_log.json"] = ArchiveEntry(
    kind: ekFile, contents: inputLogJson(s), lastModified: stamp)
  archive.contents["effective_config.json"] = ArchiveEntry(
    kind: ekFile, contents: effectiveConfig, lastModified: stamp)
  archive.contents["match_summary.json"] = ArchiveEntry(
    kind: ekFile, contents: matchSummaryJson(s, s.cfg.seed), lastModified: stamp)
  archive.contents["chat_transcript.txt"] = ArchiveEntry(
    kind: ekFile, contents: buildTranscriptText(s), lastModified: stamp)
  archive.contents["chat_transcript.json"] = ArchiveEntry(
    kind: ekFile, contents: buildTranscriptJson(s), lastModified: stamp)
  archive.contents["sponsor_log.json"] = ArchiveEntry(
    kind: ekFile, contents: sponsorLogJson(s), lastModified: stamp)
  let zipPath = workDir / "replay.zip"
  archive.writeZipArchive(zipPath)
  readFile(zipPath)

type
  LoadedReplay* = object
    effectiveConfig*: JsonNode
    data*: ReplayData

proc loadReplayZip*(zipBytes: string, workDir: string): LoadedReplay =
  ## Unzips replay bytes (from COGAME_LOAD_REPLAY_URI) and parses the stream.
  createDir(workDir)
  let zipPath = workDir / "loaded_replay.zip"
  writeFile(zipPath, zipBytes)
  let reader = openZipArchive(zipPath)
  let stream = reader.extractFile("replay.zsr")
  reader.close()
  result.data = parseReplayBytes(stream, zeroSumReplaySpec())
  result.effectiveConfig = parseJson(result.data.configJson)
