## Step-7 tests: softcoin accounting, gift validation matrix, landing spiral,
## pod landing/looting, scripted pipeline, and determinism.

import std/json
import battle_royal/[types, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(gifts: JsonNode = newJArray(), shopOpens = 96): Sim =
  initSim(parseSimConfig(%*{
    "seed": 42, "max_ticks": 2000, "freeze_ticks": 48,
    "sponsor": {"live": false, "budget_per_player": 300,
                 "shop_opens_tick": shopOpens, "scripted_gifts": gifts}},
    fixedSeed))

proc runTo(s: var Sim, tick: int) =
  while s.tick < tick:
    s.step()

block validation_matrix:
  var s = mkSim()
  s.runTo(100)
  # unknown item
  doAssert not s.requestGift("t", 0, "bazooka").accepted
  doAssert s.sponsorLog[^1].reason == "unknown_item"
  # dead sponsored player
  s.agents[1].hpCenti = 0
  s.step()
  doAssert not s.requestGift("t", 1, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "recipient_dead"
  # malformed player index
  doAssert not s.requestGift("t", 77, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "malformed"
  # valid accept deducts full price
  let outc = s.requestGift("t", 0, "sword")
  doAssert outc.accepted and outc.cost == 120 and outc.balance == 180
  doAssert s.playerBudget[0] == 180

block shop_lockout:
  var s = mkSim(shopOpens = 500)
  s.runTo(100)
  doAssert not s.requestGift("t", 0, "rations").accepted
  doAssert s.sponsorLog[^1].reason == "shop_locked"
  s.runTo(500)
  doAssert s.requestGift("t", 0, "rations").accepted

block insufficient_funds_atomic:
  var s = mkSim()
  s.runTo(100)
  doAssert s.requestGift("t", 1, "bow").accepted           # 150
  doAssert s.requestGift("t", 1, "sword").accepted         # 120 -> balance 30
  let before = s.playerBudget[1]
  doAssert not s.requestGift("t", 1, "net").accepted       # 50 > 30
  doAssert s.sponsorLog[^1].reason == "insufficient_funds"
  doAssert s.playerBudget[1] == before                     # zero effect
  # accounting invariant: initial - spent == balance
  var spent = 0
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.player == 1:
      spent += r.cost
  doAssert 300 - spent == s.playerBudget[1]

block pod_lands_and_loots:
  var s = mkSim()
  s.runTo(100)
  let outc = s.requestGift("t", 0, "sword")
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
    {"tick": 90, "player": 0, "item_id": "rations"},
    {"tick": 150, "player": 5, "item_id": "sword"}]
  var s = mkSim(gifts)
  s.runTo(300)
  # t=90 gift rejected (shop opens 96), t=150 accepted
  doAssert s.sponsorLog.len == 2
  doAssert s.sponsorLog[0].status == gsRejected and
           s.sponsorLog[0].reason == "shop_locked"
  doAssert s.sponsorLog[1].status == gsAccepted
  doAssert s.playerBudget[5] == 180
  var sawIncoming, sawLanded: bool
  for e in s.eventHistory:
    if e.kind == evGiftIncoming: sawIncoming = true
    if e.kind == evGiftLanded: sawLanded = true
  doAssert sawIncoming and sawLanded

block determinism_with_gifts:
  let gifts = %*[{"tick": 100, "player": 1, "item_id": "camouflage"}]
  var a = mkSim(gifts)
  var b = mkSim(gifts)
  for _ in 0 ..< 400:
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

echo "t_step7 ok"
