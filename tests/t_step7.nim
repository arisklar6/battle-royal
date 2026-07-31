## Step-7 tests: softcoin accounting, gift validation matrix, landing spiral,
## pod landing/looting, scripted pipeline, replay single-application guard,
## determinism.

import std/json
import zero_sum/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(gifts: JsonNode = newJArray(), shopOpens = 96): Sim =
  initSim(parseSimConfig(%*{
    "seed": 42, "max_ticks": 2000, "freeze_ticks": 48,
    "sponsor": {"live": false, "budget_per_team": 300,
                 "shop_opens_tick": shopOpens, "scripted_gifts": gifts}},
    fixedSeed))

proc runTo(s: var Sim, tick: int) =
  while s.tick < tick:
    s.step()

block validation_matrix:
  var s = mkSim()
  s.runTo(100)
  # unknown item
  doAssert not s.requestGift("t", 0, 0, "bazooka").accepted
  doAssert s.sponsorLog[^1].reason == "unknown_item"
  # not own team (slot 5 is team C=2, sponsor claims team 0)
  doAssert not s.requestGift("t", 0, 5, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "not_own_team"
  # dead recipient
  s.agents[1].hpCenti = 0
  s.step()
  doAssert not s.requestGift("t", 0, 1, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "recipient_dead"
  # malformed team/slot
  doAssert not s.requestGift("t", 9, 0, "rations").accepted
  doAssert not s.requestGift("t", 0, 77, "rations").accepted
  # valid accept deducts full price
  let outc = s.requestGift("t", 0, 0, "sword")
  doAssert outc.accepted and outc.cost == 120 and outc.balance == 180
  doAssert s.teamBudget[0] == 180

block shop_lockout:
  var s = mkSim(shopOpens = 500)
  s.runTo(100)
  doAssert not s.requestGift("t", 0, 0, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "shop_locked"
  s.runTo(500)
  doAssert s.requestGift("t", 0, 0, "rations").accepted

block insufficient_funds_atomic:
  var s = mkSim()
  s.runTo(100)
  doAssert s.requestGift("t", 1, 2, "bow").accepted        # 150
  doAssert s.requestGift("t", 1, 2, "sword").accepted      # 120 -> balance 30
  let before = s.teamBudget[1]
  doAssert not s.requestGift("t", 1, 2, "net").accepted    # 50 > 30
  doAssert s.sponsorLog[^1].reason == "insufficient_funds"
  doAssert s.teamBudget[1] == before                       # zero effect
  # accounting invariant: initial - spent == balance
  var spent = 0
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.team == 1:
      spent += r.cost
  doAssert 300 - spent == s.teamBudget[1]

block pod_lands_and_loots:
  var s = mkSim()
  s.runTo(100)
  let outc = s.requestGift("t", 0, 0, "sword")
  doAssert outc.accepted
  doAssert outc.landsTick == 100 + 120
  # landing tile within Chebyshev 3 of recipient (free space permitting)
  let d = max(abs(outc.landing.x - s.agents[0].pos.x),
              abs(outc.landing.y - s.agents[0].pos.y))
  doAssert d <= 3
  s.runTo(221)
  # pod landed: sword on the ground at the landing tile
  var found = false
  for g in s.ground:
    if g.pos == outc.landing and g.item == iSword:
      found = true
  doAssert found
  # gift record got its landing tick
  var landedRec = false
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.tickLanded == 220:
      landedRec = true
  doAssert landedRec
  # anyone may loot (DECIDED free-for-all): walk enemy slot 9 onto it
  s.agents[9].pos = outc.landing
  s.submitAction(AgentId(9), Action(kind: akPickup))
  s.step()
  doAssert s.agents[9].hand == iSword

block scripted_pipeline_and_events:
  let gifts = %*[
    {"tick": 90, "team": "A", "recipient_slot": 0, "item_id": "rations"},
    {"tick": 150, "team": "C", "recipient_slot": 5, "item_id": "sword"}]
  var s = mkSim(gifts)
  s.runTo(300)
  # t=90 gift rejected (shop opens 96), t=150 accepted
  doAssert s.sponsorLog.len == 2
  doAssert s.sponsorLog[0].status == gsRejected and
           s.sponsorLog[0].reason == "shop_locked"
  doAssert s.sponsorLog[1].status == gsAccepted
  doAssert s.teamBudget[2] == 180
  var sawIncoming, sawLanded: bool
  for e in s.eventHistory:
    if e.kind == evGiftIncoming: sawIncoming = true
    if e.kind == evGiftLanded: sawLanded = true
  doAssert sawIncoming and sawLanded

block replay_single_application:
  # replay guard: suppressScriptedGifts on -> config gifts skipped; the log
  # entry re-applies via applyInputJson -> exactly one acceptance
  let gifts = %*[{"tick": 150, "team": "C", "recipient_slot": 5,
                  "item_id": "sword"}]
  var live = mkSim(gifts)
  live.runTo(400)
  doAssert live.teamBudget[2] == 180
  var rep = mkSim(gifts)
  rep.suppressScriptedGifts = true
  rep.allowLoggedGifts = true
  # re-apply from the live input log
  var gi = 0
  while rep.tick < 400:
    for inp in live.inputLog:
      if inp.tick == rep.tick:
        let j = parseJson(inp.payload)
        if j.hasKey("gift"):
          rep.applyInputJson(AgentId(0), j)
    rep.step()
  doAssert rep.teamBudget[2] == 180                        # once, not twice
  doAssert rep.hashes == live.hashes

block determinism_with_gifts:
  let gifts = %*[{"tick": 100, "team": "A", "recipient_slot": 1,
                  "item_id": "camouflage"}]
  var a = mkSim(gifts)
  var b = mkSim(gifts)
  for _ in 0 ..< 400:
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

echo "t_step7 ok"
