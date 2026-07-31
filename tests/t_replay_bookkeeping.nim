## Regression (owner directive, Phase D gate): a log-driven re-simulation of a
## gifted episode must regenerate results.json, chat_transcript, and
## sponsor_log identical to the live run — modulo rejected-request rows,
## which are live-only audit records (documented asymmetry).

import std/[json, strutils]
import zero_sum/[prng, types, arena, sim]
import ../game/bundle
import ../game/transcript

proc fixedSeed(): uint64 = 42'u64

let cfgNode = %*{
  "seed": 4242, "max_ticks": 900, "freeze_ticks": 48,
  "zone": {"schedule": [[96, 144, 432, 24, 12, 2], [528, 576, 816, 12, 0, 30]]},
  "sponsor": {"live": false, "budget_per_team": 300, "shop_opens_tick": 96,
               "scripted_gifts": [
                 {"tick": 90, "team": "A", "recipient_slot": 0, "item_id": "rations"},
                 {"tick": 150, "team": "C", "recipient_slot": 5, "item_id": "sword"},
                 {"tick": 200, "team": "B", "recipient_slot": 2, "item_id": "first_aid"}]}}

# ---- live run (scripted gifts from config; t=90 rejects: shop_locked)
let cfg = parseSimConfig(cfgNode, fixedSeed)
var live = initSim(cfg)
while live.phase != phEnded:
  live.step()

# ---- log-driven re-simulation (the replay path)
var rep = initReplaySim(parseSimConfig(cfgNode, fixedSeed))
var idx = 0
while rep.phase != phEnded:
  while idx < live.inputLog.len and live.inputLog[idx].tick == rep.tick:
    let j = parseJson(live.inputLog[idx].payload)
    let slot = live.inputLog[idx].slot
    if slot in 0 .. 15:
      rep.applyInputJson(AgentId(slot), j)
    inc idx
  rep.step()

# ---- hashes must match exactly
doAssert live.hashes == rep.hashes, "hash streams diverged"

# ---- results.json identical (gifts_received included)
let liveResults = parseJson(resultsJson(live))
let repResults = parseJson(resultsJson(rep))
doAssert liveResults == repResults,
  "results diverged:\nlive: " & $liveResults & "\nrep:  " & $repResults
doAssert liveResults["gifts_received"].elems[5].getInt() == 1
doAssert liveResults["gifts_received"].elems[2].getInt() == 1

# ---- sponsor_log: accepted rows identical; rejected rows live-only
proc acceptedRows(s: Sim): seq[GiftRecord] =
  for r in s.sponsorLog:
    if r.status == gsAccepted:
      result.add(r)
let la = acceptedRows(live)
let ra = acceptedRows(rep)
doAssert la.len == 2, "live accepted rows: " & $la.len
doAssert ra.len == la.len,
  "replay lost accepted sponsor rows: live=" & $la.len & " replay=" & $ra.len
for i in 0 ..< la.len:
  doAssert la[i].tickRequested == ra[i].tickRequested
  doAssert la[i].tickLanded == ra[i].tickLanded
  doAssert la[i].itemId == ra[i].itemId
  doAssert la[i].cost == ra[i].cost
  doAssert la[i].balanceAfter == ra[i].balanceAfter

# ---- transcript: SPONSOR DROP lines present in both
let liveT = buildTranscriptText(live)
let repT = buildTranscriptText(rep)
doAssert "SPONSOR DROP INBOUND" in liveT
doAssert "SPONSOR DROP LANDED" in liveT
doAssert "SPONSOR DROP INBOUND" in repT, "replay transcript lost INBOUND lines"
doAssert "SPONSOR DROP LANDED" in repT, "replay transcript lost LANDED lines"

echo "t_replay_bookkeeping ok"
