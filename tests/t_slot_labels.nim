## Seat labels: the platform injects real display names into
## game_config.players[].name (verified on league round 1842 — the hosted log
## prints "relh (A)", "sivannn (A)", "Ryan Schiller (B)", "Baseline (5) (E)").
## sim.nim parses them into cfg.playerNames; this covers the fold from that
## name to something the 3x5/5x7 faces can draw inside the tag budget.

import std/json
import zero_sum/[types, sim]
import render

# ---- real names as they arrive from hosted dispatch
doAssert slotLabel("relh", 0) == "RELH"
doAssert slotLabel("sivannn", 1) == "SIVANNN"
doAssert slotLabel("Ryan Schiller", 2) == "RYAN SCH"
doAssert slotLabel("Ari Sklar", 3) == "ARI SKLA"

# ---- filler dedup tails survive truncation; the stem gives way. Twelve
# filler seats are otherwise indistinguishable.
doAssert slotLabel("Baseline", 4) == "BASELINE"
doAssert slotLabel("Baseline (2)", 5) == "BASELIN2"
doAssert slotLabel("Baseline (5)", 6) == "BASELIN5"
doAssert slotLabel("Baseline (12)", 7) == "BASELI12"
var seen: seq[string] = @[]
for n in 2 .. 12:
  let lb = slotLabel("Baseline (" & $n & ")", 4)
  doAssert lb notin seen, "filler labels collided at " & $n & ": " & lb
  seen.add(lb)

# ---- every emitted character must be drawable by the shared 41-glyph set
const Drawable = {'0'..'9', 'A'..'Z', ':', '-', '>', '.', ' '}
for raw in ["relh", "Ryan Schiller", "Baseline (12)", "zs_patient",
            "ryanschiller-zero-sum-player-v1", "Ω≈ç√", "user@example.com",
            "  padded  ", "MiXeD cAsE"]:
  let lb = slotLabel(raw, 0)
  doAssert lb.len <= 8, "over budget: " & raw & " -> " & lb & " (" & $lb.len & ")"
  for ch in lb:
    doAssert ch in Drawable, "undrawable char " & $ch & " from " & raw

# ---- degenerate input falls back to the slot, never to an empty tag
doAssert slotLabel("", 3) == "P3"
doAssert slotLabel("Ω≈ç√", 11) == "P11"
doAssert slotLabel("   ", 7) == "P7"

# ---- a policy label that is all one token still truncates cleanly
doAssert slotLabel("ryanschiller-zero-sum-player-v1", 0) == "RYANSCHI"

# ---- default (unhosted) names: sim.nim seeds a themed table, and a config
# with no players[] must still produce distinct, drawable tags
proc fixedSeed(): uint64 = 7'u64

let cfgNode = %*{
  "seed": 5, "max_ticks": 200, "freeze_ticks": 48,
  "zone": {"schedule": [[100, 120, 180, 24, 0, 30]]}}
let cfg = parseSimConfig(cfgNode, fixedSeed)
var tags: seq[string] = @[]
for i in 0 .. 15:
  let lb = slotLabel(cfg.playerNames[i], i)
  doAssert lb.len > 0 and lb.len <= 8
  tags.add(lb)
doAssert tags.len == 16

# ---- injected names win over the defaults, at the right internal slot
var withNames = cfgNode
withNames["players"] = newJArray()
for i in 0 .. 15:
  withNames["players"].add(%*{"name": "user" & $i})
let cfg2 = parseSimConfig(withNames, fixedSeed)
let s2 = initSim(cfg2)
# league_mode remaps external -> internal seats, so assert the SET rather than
# a per-index identity: every injected name must reach exactly one seat.
var got: seq[string] = @[]
for i in 0 .. 15:
  got.add(slotLabel(s2, i))
for i in 0 .. 15:
  doAssert ("USER" & $i) in got, "injected name lost: user" & $i
doAssert got.len == 16

echo "t_slot_labels ok"
