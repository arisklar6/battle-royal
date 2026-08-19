## Seat labels: the platform injects real display names into
## game_config.players[].name (verified on league round 1842 — the hosted log
## prints "relh (A)", "sivannn (A)", "Ryan Schiller (B)", "Baseline (5) (E)").
## sim.nim parses them into cfg.playerNames; this covers the fold from that
## name to something the 3x5/5x7 faces can draw inside the tag budget.

import std/json
import battle_royal/[types, sim]
import ../game/render

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
            "ryanschiller-battle-royal-player-v1", "Ω≈ç√", "user@example.com",
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
doAssert slotLabel("ryanschiller-battle-royal-player-v1", 0) == "RYANSCHI"

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

# ---- crowded fallback: the seat number (FFA — no team letters). Must be
# unique per seat, drawable, and narrow (VISUAL_REDESIGN Part 8.1).
var shorts: seq[string] = @[]
for i in 0 .. 15:
  let sl = shortLabel(i)
  doAssert sl.len <= 3, "short plate must stay narrow: " & $i & " -> " & sl
  doAssert sl notin shorts, "short plates collided at slot " & $i & ": " & sl
  for ch in sl:
    doAssert ch in Drawable, "undrawable short-plate char " & $ch
  shorts.add(sl)
doAssert shortLabel(0) == "P1" and shortLabel(15) == "P16"
doAssert shortLabel(-1) == "??" and shortLabel(16) == "??"

# ---- plates centre on the tile rather than sitting at a fixed offset: the
# old -3 was tuned for "P<n>" and left an 8-char name a tile and a half right
# tile 0 spans 0..6 with centre 3; a 2-char plate is 10px, so it starts at -2
doAssert plateX(0, "A1") == -2
doAssert plateX(10, "RYAN SCH") == 10 * 6 + 3 - (2 + 8 * 4) div 2
for lbl in ["A1", "RELH", "RYAN SCH", "BASELI12"]:
  let centre = plateX(10, lbl) + (2 + lbl.len * 4) div 2
  doAssert centre == 10 * 6 + 3, "plate off-centre for " & lbl

# ---- plate collision is geometric, not a fixed tile radius. Regression from
# league round 1851: slot 2 ("B1") and slot 6 ("BASELIN2") sat 3 tiles apart,
# outside the old 2-tile radius, and their plates still overlapped.
doAssert plateWidth("A1") == 10
doAssert plateWidth("BASELIN2") == 34          # 5.7 tiles at TileSize 6

# the exact 1851 case: two full plates 3 tiles apart DO collide
doAssert platesOverlap(27, "RYAN SCH", 30, "BASELIN2"),
  "the round-1851 overlap must be detected"
# and the old radius would have missed it
doAssert abs(30 - 27) > 2

# far enough apart in x, no collision
doAssert not platesOverlap(10, "BASELIN2", 20, "BASELIN2")
# a full plate spans ~6 tiles, so 6 tiles of separation is the boundary
doAssert platesOverlap(10, "BASELIN2", 15, "BASELIN2")
doAssert not platesOverlap(10, "BASELIN2", 16, "BASELIN2")
# short plates are narrow enough to sit two tiles apart cleanly
doAssert not platesOverlap(10, "A1", 12, "B1")
doAssert platesOverlap(10, "A1", 11, "B1")
# symmetric: both sides of a pair must agree
for (x1, l1, x2, l2) in [(27, "RYAN SCH", 30, "BASELIN2"),
                         (10, "A1", 11, "B1"),
                         (10, "BASELIN2", 16, "BASELIN2")]:
  doAssert platesOverlap(x1, l1, x2, l2) == platesOverlap(x2, l2, x1, l1),
    "overlap must be symmetric for " & l1 & "/" & l2

echo "t_slot_labels ok"
