## v0.2 audience pivot (DECIDED 2026-07-31): sponsors buy one package at a
## time and drop it on a CHOSEN TILE. Covers: tile landing via the pinned
## spiral, the 60 s per-team lockout (tile mode only), atomic rejects, legacy
## recipient gifts staying lockout-free.

import std/json
import zero_sum/[types, items, sim]

proc fixedSeed(): uint64 = 42'u64

let cfgNode = %*{
  "seed": 777, "max_ticks": 7200, "freeze_ticks": 48,
  "zone": {"schedule": [[6000, 6240, 6960, 24, 0, 30]]},
  "sponsor": {"live": true, "budget_per_team": 300, "shop_opens_tick": 96}}

var s = initSim(parseSimConfig(cfgNode, fixedSeed))
while s.tick < 100:
  s.step()

# ---- tile gift lands on/near the requested tile
let want = Pos(x: 10, y: 10)
let o1 = s.requestGift("live:A", 0, -1, "rations", want)
doAssert o1.accepted, "tile gift rejected: " & o1.reason
let dx = o1.landing.x - want.x
let dy = o1.landing.y - want.y
doAssert dx * dx + dy * dy <= 18, "landing too far from target: " & $o1.landing
doAssert s.sponsorLog[^1].recipientSlot == -1
doAssert s.sponsorLog[^1].target == want

# ---- lockout: same team blocked for GiftLockoutTicks, other teams free
let o2 = s.requestGift("live:A", 0, -1, "rations", Pos(x: 20, y: 20))
doAssert not o2.accepted and o2.reason == "lockout", $o2.reason
let o3 = s.requestGift("live:B", 1, -1, "rations", Pos(x: 20, y: 20))
doAssert o3.accepted, "other team hit lockout: " & o3.reason

# ---- lockout expires
let resumeTick = s.tick + GiftLockoutTicks
while s.tick < resumeTick:
  s.step()
let o4 = s.requestGift("live:A", 0, -1, "knives", Pos(x: 30, y: 30))
doAssert o4.accepted, "post-lockout gift rejected: " & o4.reason

# ---- atomic rejects burn no coin, no lockout
let balBefore = s.teamBudget[2]
let o5 = s.requestGift("live:C", 2, -1, "nonsense", Pos(x: 5, y: 5))
doAssert not o5.accepted and s.teamBudget[2] == balBefore
let o6 = s.requestGift("live:C", 2, -1, "rations", Pos(x: -3, y: 900))
doAssert not o6.accepted and o6.reason == "malformed"
let o7 = s.requestGift("live:C", 2, -1, "rations", Pos(x: 5, y: 5))
doAssert o7.accepted, "reject must not arm the lockout: " & o7.reason

# ---- recipient gifts retain their distinct no-lockout behavior
let l1 = s.requestGift("script", 3, 6, "rations")
let l2 = s.requestGift("script", 3, 6, "rations")
doAssert l1.accepted and l2.accepted,
  "legacy recipient gifts must stay lockout-free: " & l1.reason & "/" & l2.reason

echo "t_gift_targeting ok"
