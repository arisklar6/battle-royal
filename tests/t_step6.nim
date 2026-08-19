## Step-6 tests: talk validation/rate-limit/sanitize, channel delivery,
## dead silence, input-JSON round trip, determinism with talk.

import std/json
import battle_royal/[types, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 2000, "freeze_ticks": 48},
                         fixedSeed))

block talk_validation:
  var s = mkSim()
  doAssert s.submitTalk(AgentId(0), tcBroadcast, -1, "hello") == tkAccepted
  # rate limit: second message within 24 ticks
  doAssert s.submitTalk(AgentId(0), tcBroadcast, -1, "again") == tkRateLimited
  for _ in 0 ..< 24: s.step()
  doAssert s.submitTalk(AgentId(0), tcBroadcast, -1, "again") == tkAccepted
  # dm to self / out of range rejected
  doAssert s.submitTalk(AgentId(1), tcDm, 1, "hi me") == tkRejected
  doAssert s.submitTalk(AgentId(1), tcDm, 99, "hi") == tkRejected
  # sanitize: control chars stripped, 120-char cap
  var long = ""
  for i in 0 ..< 200: long.add("x")
  doAssert s.submitTalk(AgentId(2), tcBroadcast, -1, long) == tkAccepted
  doAssert s.talkLog[^1].text.len == 120
  doAssert s.submitTalk(AgentId(3), tcBroadcast, -1, "a\x01b\x7fc") == tkAccepted
  doAssert s.talkLog[^1].text == "abc"
  # empty-after-sanitize rejected
  doAssert s.submitTalk(AgentId(4), tcBroadcast, -1, "\x01\x02") == tkRejected

block delivery_sets:
  var s = mkSim()
  doAssert s.submitTalk(AgentId(4), tcTeam, -1, "team ho") == tkAccepted # team C = slots 4,5
  doAssert s.submitTalk(AgentId(6), tcDm, 9, "psst") == tkAccepted
  doAssert s.submitTalk(AgentId(8), tcBroadcast, -1, "everyone") == tkAccepted
  s.step() # delivery happens next tick
  s.step()
  # inbox contents at the delivery tick were consumed; use a fresh exchange
  var s2 = mkSim()
  discard s2.submitTalk(AgentId(4), tcTeam, -1, "team ho")
  discard s2.submitTalk(AgentId(6), tcDm, 9, "psst")
  discard s2.submitTalk(AgentId(8), tcBroadcast, -1, "everyone")
  s2.step() # tick 0 executes; delivery happens inside the NEXT step
  s2.step() # tick 1: inboxes now hold tick-0 messages
  doAssert s2.inbox[5].len == 2 # teammate: team msg + broadcast
  doAssert s2.inbox[4].len == 2 # sender echo + broadcast
  doAssert s2.inbox[9].len == 2 # dm + broadcast
  doAssert s2.inbox[6].len == 2 # dm sender echo + broadcast
  doAssert s2.inbox[0].len == 1 # broadcast only
  var texts0: seq[string] = @[]
  for m in s2.inbox[0]: texts0.add(m.text)
  doAssert texts0 == @["everyone"]

block dead_silence:
  var s = mkSim()
  s.agents[7].hpCenti = 0
  s.step()
  doAssert not s.agents[7].alive
  doAssert s.submitTalk(AgentId(7), tcBroadcast, -1, "ghost") == tkRejected
  discard s.submitTalk(AgentId(0), tcBroadcast, -1, "who hears me")
  s.step()
  doAssert s.inbox[7].len == 0

block input_json_roundtrip:
  var s = mkSim()
  s.applyInputJson(AgentId(0), parseJson(
    """{"type":"talk","channel":"dm","to":3,"text":"via json"}"""))
  doAssert s.talkLog.len == 1 and s.talkLog[0].to == 3
  s.applyInputJson(AgentId(1), parseJson(
    """{"type":"allocate_stats","speed":7,"strength":5,"intelligence":4,"athleticism":4}"""))
  doAssert s.agents[1].statsLocked and s.agents[1].stats.speed == 7
  s.applyInputJson(AgentId(2), parseJson(
    """{"type":"action","do":"move","dir":"SW"}"""))
  # move pends: step during countdown moves off pedestal -> mine (proves applied)
  s.step()
  doAssert not s.agents[2].alive
  # malformed payloads are inert
  s.applyInputJson(AgentId(3), parseJson(
    """{"type":"action","do":"fly"}"""))
  s.applyInputJson(AgentId(3), parseJson(""""just a string""""))
  s.applyInputJson(AgentId(3), nil)

block determinism_with_talk:
  var a = mkSim()
  var b = mkSim()
  for t in 0 ..< 200:
    for s in [addr a, addr b]:
      if t == 5:
        discard s[].submitTalk(AgentId(0), tcBroadcast, -1, "same words")
    a.step()
    b.step()
  doAssert a.hashes == b.hashes
  # talk DIFFERENCE shows in the hash (rate-limit state + log length)
  var c = mkSim()
  var d = mkSim()
  discard c.submitTalk(AgentId(0), tcBroadcast, -1, "only c talks")
  c.step()
  d.step()
  doAssert c.hashes != d.hashes

echo "t_step6 ok"
