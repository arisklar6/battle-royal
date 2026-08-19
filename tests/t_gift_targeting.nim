## v0.2 audience pivot (DECIDED 2026-07-31), FFA sponsorship: every seat has
## its own purse; sponsors buy one package at a time and drop it on a CHOSEN
## TILE. Covers: tile landing via the pinned spiral, the 60 s per-player
## lockout (tile mode only), atomic rejects, legacy recipient gifts staying
## lockout-free.

import std/json
import battle_royal/[types, items, sim]

proc fixedSeed(): uint64 = 42'u64

let cfgNode = %*{
  "seed": 777, "max_ticks": 7200, "freeze_ticks": 48,
  "zone": {"schedule": [[6000, 6240, 6960, 24, 0, 30]]},
  "sponsor": {"live": true, "budget_per_player": 300, "shop_opens_tick": 96}}

var s = initSim(parseSimConfig(cfgNode, fixedSeed))
while s.tick < 100:
  s.step()

# ---- tile gift lands on/near the requested tile
let want = Pos(x: 10, y: 10)
let o1 = s.requestGift("live:P1", 0, "rations", want)
doAssert o1.accepted, "tile gift rejected: " & o1.reason
let dx = o1.landing.x - want.x
let dy = o1.landing.y - want.y
doAssert dx * dx + dy * dy <= 18, "landing too far from target: " & $o1.landing
doAssert s.sponsorLog[^1].recipientSlot == -1
doAssert s.sponsorLog[^1].target == want

# ---- lockout: same player blocked for GiftLockoutTicks, other players free
let o2 = s.requestGift("live:P1", 0, "rations", Pos(x: 20, y: 20))
doAssert not o2.accepted and o2.reason == "lockout", $o2.reason
let o3 = s.requestGift("live:P2", 1, "rations", Pos(x: 20, y: 20))
doAssert o3.accepted, "other player hit lockout: " & o3.reason

# ---- lockout expires
let resumeTick = s.tick + GiftLockoutTicks
while s.tick < resumeTick:
  s.step()
let o4 = s.requestGift("live:P1", 0, "knives", Pos(x: 30, y: 30))
doAssert o4.accepted, "post-lockout gift rejected: " & o4.reason

# ---- atomic rejects burn no coin, no lockout
let balBefore = s.playerBudget[2]
let o5 = s.requestGift("live:P3", 2, "nonsense", Pos(x: 5, y: 5))
doAssert not o5.accepted and s.playerBudget[2] == balBefore
let o6 = s.requestGift("live:P3", 2, "rations", Pos(x: -3, y: 900))
doAssert not o6.accepted and o6.reason == "malformed"
let o7 = s.requestGift("live:P3", 2, "rations", Pos(x: 5, y: 5))
doAssert o7.accepted, "reject must not arm the lockout: " & o7.reason

# ---- recipient gifts retain their distinct no-lockout behavior
let l1 = s.requestGift("script", 3, "rations")
let l2 = s.requestGift("script", 3, "rations")
doAssert l1.accepted and l2.accepted,
  "legacy recipient gifts must stay lockout-free: " & l1.reason & "/" & l2.reason

# ---- live ingress must carry a tile: the legacy recipient path is closed to
# it, so a live socket cannot use the lockout-free mode to drain the budget
let balE = s.playerBudget[4]
let logLen = s.sponsorLog.len
let n1 = s.requestGift("live:P5", 4, "rations", requireTile = true)
doAssert not n1.accepted and n1.reason == "target_required", $n1.reason
doAssert s.playerBudget[4] == balE, "rejected live request must burn no coin"
doAssert s.sponsorLog.len == logLen + 1, "reject must stay in the audit log"
doAssert s.sponsorLog[^1].status == gsRejected
doAssert s.sponsorLog[^1].reason == "target_required"

# a targetless live request must not arm the lockout either
let n2 = s.requestGift("live:P5", 4, "rations", Pos(x: 12, y: 12),
                       requireTile = true)
doAssert n2.accepted, "target_required reject armed the lockout: " & n2.reason

# ---- requireTile is opt-in: scripted config gifts keep both modes
let n3 = s.requestGift("script", 5, "rations")
doAssert n3.accepted, "scripted recipient gift broke: " & n3.reason

echo "t_gift_targeting ok"
