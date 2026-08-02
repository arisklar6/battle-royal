## Chat transcript artifact (DESIGN §13): human-readable text + machine JSON,
## built from the sim's talk log merged with system events.

import std/[json, strutils]
import zero_sum/[types, sim]

proc name(s: Sim, slot: int): string =
  if slot >= 0 and slot < s.cfg.playerNames.len:
    s.cfg.playerNames[slot]
  else:
    "P?" & $slot

proc tag(s: Sim, slot: int): string =
  s.name(slot) & " (" & teamName(AgentId(slot)) & ")"

proc pad5(t: int): string =
  result = $t
  while result.len < 5:
    result = "0" & result

proc talkLine*(s: Sim, m: TalkMsg): string =
  let ch =
    case m.channel
    of tcBroadcast: "[broadcast]"
    of tcTeam: "[team]"
    of tcDm: "[dm->" & s.name(m.to) & "]"
  "[t=" & pad5(m.tick) & "] " & ch & " " & s.tag(m.slot) & ": " & m.text

proc systemLine(s: Sim, e: Event, remainAfter: int): string =
  let t = "[t=" & pad5(e.tick) & "] * "
  case e.kind
  of evIgnition: t & "IGNITION *"
  of evMineExplosion: t & s.tag(e.slot) & " STEPPED OFF EARLY - MINE *"
  of evDeathFireworks: t & s.tag(e.slot) & " DOWN - " & $remainAfter & " remain *"
  of evZoneWarning: t & "ZONE WARNING: " & e.data & " *"
  of evEventWarning: t & "HAZARD WARNING: " & e.data & " *"
  of evGiftIncoming: t & "SPONSOR DROP INBOUND: " & e.data & " *"
  of evGiftLanded: t & "SPONSOR DROP LANDED at (" & $e.pos.x & "," & $e.pos.y & ") *"
  of evFinale: t & "FINALE - one team left, no allies now *"
  of evMatchEnd:
    if e.slot >= 0: t & s.tag(e.slot) & " WINS *"
    else: t & "MATCH OVER *"
  else: ""

proc buildTranscriptText*(s: Sim): string =
  ## Merge talks + system events by tick (talks first within a tick).
  var lines: seq[string] = @[]
  var ti = 0
  var deaths = 0
  var ei = 0
  template flushEventsUpTo(upTo: int) =
    while ei < s.eventHistory.len and s.eventHistory[ei].tick <= upTo:
      let e = s.eventHistory[ei]
      if e.kind == evDeathFireworks:
        inc deaths
      let line = s.systemLine(e, 16 - deaths)
      if line.len > 0 and e.kind != evBoom:
        lines.add(line)
      inc ei
  for m in s.talkLog:
    flushEventsUpTo(m.tick - 1)
    lines.add(s.talkLine(m))
    inc ti
  flushEventsUpTo(int.high)
  result = lines.join("\n") & "\n"

proc fairnessJson*(s: Sim): string =
  ## Per-slot applied-input counts vs lifetime (review §1.2 minimum):
  ## a lagging or dead-link bot silently no-ops, and its misses used to
  ## be indistinguishable from deliberate "none". Derived from the
  ## recorded input log — zero tick-loop cost.
  var counts: array[16, int]
  for ai in s.inputLog:
    if ai.slot in 0 .. 15:
      inc counts[ai.slot]
  var arr = newJArray()
  for i in 0 .. 15:
    let aliveTicks = (if s.agents[i].deathTick >= 0: s.agents[i].deathTick
                      else: s.tick)
    arr.add(%*{"slot": i, "inputs_applied": counts[i],
                "ticks_alive": aliveTicks})
  $(%*{"note": "low inputs_applied vs ticks_alive flags lagging/idle seats",
       "slots": arr})

proc eventHistoryJson*(s: Sim): string =
  ## Full arena event stream (VISUAL_REDESIGN §5.7): the raw feed for
  ## timeline/scrubber/highlight tooling. Data payloads are re-parsed so
  ## consumers get structured fields, not embedded strings.
  var arr = newJArray()
  for e in s.eventHistory:
    var j = %*{"tick": e.tick, "type": $e.kind, "slot": e.slot,
               "pos": [e.pos.x, e.pos.y]}
    if e.data.len > 0:
      j["data"] = (try: parseJson(e.data) except CatchableError: %e.data)
    arr.add(j)
  $arr

proc buildTranscriptJson*(s: Sim): string =
  var arr = newJArray()
  var ei = 0
  template flushEventsUpTo(upTo: int) =
    while ei < s.eventHistory.len and s.eventHistory[ei].tick <= upTo:
      let e = s.eventHistory[ei]
      if e.kind notin {evBoom}:
        arr.add(%*{"tick": e.tick, "slot": nil,
                   "kind": $e.kind,
                   "at": [e.pos.x, e.pos.y],
                   "data": e.data, "subject": e.slot})
      inc ei
  for m in s.talkLog:
    flushEventsUpTo(m.tick - 1)
    arr.add(%*{"tick": m.tick, "slot": m.slot,
               "team": teamName(AgentId(m.slot)),
               "channel": $m.channel,
               "to": (if m.channel == tcDm: %m.to else: newJNull()),
               "text": m.text})
  flushEventsUpTo(int.high)
  $arr
