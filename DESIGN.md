# Zero Sum — Design Document (v1)

Status: Phase B draft for review. Numbers are proposals unless marked LOCKED (locked upstream by mission).
Engine: Nim game on the bitworld library (pinned commit recorded at scaffold time; `e47559c90d92ff25c748ecdb41cd5695c10c65b2` at design time).
Platform: coworld manifest/certify contract. Tick rate 24 Hz (bitworld-family norm).
Naming (locked, 4 forms): display "Zero Sum", slug `zero-sum`, code `zero_sum`, constants/magic `ZERO_SUM` (uppercase of code form). No "bitworld" and no Hunger-Games-distinctive vocabulary in anything public-facing.

Engine/platform facts were verified against bitworld `e47559c` and coworld `7c3d8f0` source — file:line evidence in docs/PLATFORM_FACTS.md. This draft was adversarially reviewed (6 lenses, 39 agents); all confirmed defects are fixed in this text. The 8 open design parameters were decided by the owner via popups (§19 decision record) and are integrated throughout.

---

## 1. Match timeline & tick model

All times in ticks at 24 Hz. `t=0` is episode start.

| Event | Tick | Wall (sim) |
|---|---|---|
| Episode start, agents on pedestals, freeze begins | 0 | 0:00 |
| Stat-allocation deadline (`freeze_ticks − 24`) | 216 | 0:09 |
| Fireworks ignition — match begins, mines disarm | 240 | 0:10 |
| Zone stage 1 warning | 1,440 | 1:00 |
| Sponsor shop opens (lockout ends) — DECIDED: 60 s | 1,680 | 1:10 |
| Zone fully closed (radius 0) | 7,536 | 5:14 |
| Hard tick cap (safety) | 9,120 | 6:20 |

- Match ends the tick exactly one contestant is alive, or at the hard cap.
- After full closure (t=7,536) every living agent takes stage-7 damage (24 HP/s, ATH-scaled §5.2). Unaided death takes 120–144 ticks depending on ATH; the theoretical worst case (max ration stockpile + max sponsor rations, §3.2 note) stretches ≈ 980 ticks past closure — still inside the 1,584-tick margin to the cap. The cap is a safety net, not the expected end.
- If ≥2 agents are alive at the cap: all are killed at t=9,120 and ranked by the placement tiebreak (§12.1). No draws are possible.
- Wall clock: 9,120 ticks at the 24 Hz limiter = **6:20 hard max** (headless runs may step faster; the frame limiter is server-loop policy, not protocol). Hosted budget: `episode_timeout_minutes` omitted → platform default 20 min — ample.

### 1.1 Freeze phase (t=0..239)
- Agents stand on their pedestals. Allowed: `talk` (pre-match diplomacy is a feature), `allocate_stats`. Ignored: `attack`, `pickup`, `drop`, `use`, `interact`.
- `move` is legal but stepping off the pedestal detonates a hidden mine: instant death (HP→0), `mine_explosion` + death-fireworks events. Mines disarm at ignition. `player_config` states this rule explicitly — a policy can know the cost before moving.
- Stat allocation (§5.1) deadline is derived: `freeze_ticks − 24` (t=216 at full schedule; scales with the fixture's compressed freeze automatically). Missing/invalid → default build applied and logged.
- Observations are delivered every tick during freeze (`phase: "countdown"`).

### 1.2 Per-tick resolution order (deterministic; this order is part of the spec)
1. Ingest queued client inputs (actions, talk) and accepted sponsor gifts for this tick; append player inputs to the fairness log. Canonicalization: exactly one action entry per slot per tick — the first action message received in the window wins, later ones are dropped before logging; illegal/ignored actions are logged as received and the ignore rule is deterministic sim logic.
2. Phase transitions (ignition, zone stage changes + radius update per §7.1 formula, scripted events, shop open).
3. Movement — complete algorithm:
   a. Collect intended target tiles of all movers (off-cooldown, legal terrain).
   b. **Swaps forbidden**: any two agents targeting each other's tiles both stay.
   c. **Contested tiles**: process contested target tiles in row-major order; per tile, the winner is drawn uniformly from the contenders via the match PRNG (deterministic per seed + inputs, unpredictable without the seed); losers stay.
   d. **Blocked propagation to fixpoint**: an agent whose target is occupied by a non-mover (or by a loser/stayer from b–c) also stays; iterate until stable. Pure rotation cycles (≥3 agents, each moving into a tile simultaneously vacated) all move; 2-cycles were already forbidden in (b).
4. Melee attacks (positions post-move; mutual simultaneous hits both land).
5. Projectile spawn, advance (2 tiles/tick), collision.
6. Net effects, poison/DoT pulses, zone damage (once per 24 ticks), event damage.
7. Item use completions (first-aid channel, eating, equip swaps), pickups, drops.
8. Deaths resolve (every agent at HP ≤ 0 dies this tick), inventory drops to ground, death events fire.
9. Win check (§8), observations built, frame pushed, tick-hash recorded.

---

## 2. Arena map

Square grid, **48×48 tiles**, solid 1-tile border wall. Center C=(24,24). Coordinates are integers, (0,0) top-left. Movement is 8-directional, diagonals cost the same cooldown. Zone/vision distance is Euclidean on tile centers (integer comparisons on dx²+dy²).

Renderer mapping (verified): sprite_v1 canonical screen is **128×128 px**, tile sprites are **6×6 px**, and the map layer is zoomable/pannable with i16 world coordinates — the world may exceed the screen. The 48×48 arena renders as a 288×288-px world layer; the vendored global client pans/zooms (default view fits the arena), HUD lives on anchored UI layers. Visible tile window at 1:1 zoom is ~21×21 — fine for the per-player client; spectators zoom out.

### 2.1 Fortress (center structure, LOCKED concept)
- 9×9 footprint, tiles (20..28, 20..28). Stone walls; four 2-tile-wide mouths: N/S mouths at columns 23–24, E/W mouths at rows 23–24 (pinned; the 2-in-9 opening is necessarily off-center by half a tile — same offset all four sides, rotationally symmetric).
- Inner chamber 5×5 (22..26, 22..26): **Tier-1 loot** (6 spawn points).
- Mouth corridors (2×2 each, just inside each mouth): **Tier-2 loot** (1 spawn point per mouth, 4 total).
- Walls block movement, LOS, and projectiles.

### 2.2 Pedestal ring
- 16 pedestals, adjacent ones 22.5° apart (≈6 tiles). Positions are **pinned literal constants** (no runtime trig): slot k at:
  `(40,24) (39,30) (35,35) (30,39) (24,40) (18,39) (13,35) (9,30) (8,24) (9,18) (13,13) (18,9) (24,8) (30,9) (35,13) (39,18)` for k = 0..15.
- Slot k spawns on pedestal k. Teams: slots (0,1)=team A, (2,3)=B, … (14,15)=H — teammates are adjacent on the ring, so partners start near each other. Team assignment is fixed, not seed-dependent.
- `league_mode` is the external platform boundary, not a second set of game
  rules. `solo` maps external seat k directly to internal slot k and reports
  individual scores. `duos` maps the platform `team_n` pair `(i, i+8)` to
  internal adjacent slots `(2i, 2i+1)` and reports the combined team score to
  both external seats. All simulation, protocol, replay, team chat, sponsor,
  and rendering logic continues to use the canonical internal slots above.

### 2.3 Loot tiers & placement (seeded from the match seed)
| Tier | Where | Contents pool (draw without replacement) |
|---|---|---|
| 1 | Fortress chamber (6 spawns) | 2× sword, 1× bow + 12 arrows, 1× blowgun + 8 darts, 1× first-aid kit, 1× camouflage |
| 2 | Fortress mouths (4 spawns) | 1× spear, 1× net, 1× throwing knives (×6), 1× first-aid kit (assignment to mouths seeded) |
| 3 | 20 crates, ring radius 9–14, seeded positions (min spacing 3 tiles) | per-crate roll: 25% rations ×2, 15% throwing knives ×4, 15% arrows ×6, 10% darts ×4, 10% net, 10% backpack, 10% spear, 5% first-aid kit |
| Forage | 12 berry bushes, ring radius 18–22, seeded | each bush: 1–3 charges (seeded); `interact` 24 ticks → 1 ration |

- Terrain/cover: 10 rock clusters (2×2 or 3×2, seeded shapes/positions) distributed in rings 8–15 and 17–21, min spacing 4 from Fortress, pedestals, and each other. Rocks block movement, LOS, and projectiles.
- Design intent (LOCKED): best gear deep in the Fortress = the opening scramble is the most dangerous moment; outer ring is safer and sparser; forage sustains stallers until the zone punishes them.

---

## 3. Items & inventory

### 3.1 Inventory model
- **Hand** (1): the wielded weapon. Bare hands if empty.
- **Body** (1): worn gear — `camouflage` OR `backpack` (mutually exclusive by slot; equipping one drops the other to the ground; if dropping a backpack overflows the pack, the excess items in slots 3–4 drop to the ground too).
- **Pack**: 2 slots base, **4 with backpack**. Consumables stack per slot: rations ×5, arrows ×12, darts ×8, knives ×8, first-aid ×2, net ×2.
- `pickup` (instant, item on own tile). Routing: weapon → hand if bare-handed, else first free pack slot, else rejected (`action_result: "inventory_full"`); gear → body if empty, else pack, else rejected; consumables → merge into matching stack, else free slot, else rejected.
- Equip/swap: `use {slot}` on a pack **weapon** swaps it with the hand item (hand item goes to that pack slot); instant, but sets `attack_ready_in ≥ 6`. `use {slot}` on gear in pack equips it to body (see body rule above).
- `drop {slot}` (instant, to own tile; `slot` = "hand"/"body"/pack index). **On death every item drops to the death tile** — looting the fallen is core BR economy.

### 3.2 v1 item roster (LOCKED roster; numbers proposed)
Weapon damage marked ×M scales with strength (§5.2). Projectiles do not scale.

| Item | Type | Damage | Range | Cooldown | Ammo/uses | Notes / counterplay |
|---|---|---|---|---|---|---|
| Bare hands | melee | 5 ×M | 1 (8-dir) | 12 | ∞ | Always available (LOCKED). Weakest tier. |
| Sword | melee | 18 ×M | 1 | 18 | 40 swings | Highest sustained melee DPS (24/s at M=1.0). Durability 0 → breaks. |
| Spear | melee | 12 ×M | 2 (straight line, 8-dir) | 20 | 40 thrusts | Reach — beats sword on approach; loses point-blank tie DPS (14.4/s at M=1.0). |
| Throwing knives | ranged consumable | 8 | 5 (projectile) | 10 | stack (≤8) | Fast harass (19.2/s ammo-bound; full stack = 64 dmg). |
| Bow + arrows | ranged | 14 | 8 (projectile) | draw 18 (ATH-modified §5.2) | arrows consumable | 2 tiles/tick projectile, dodgeable (§5.2), blocked by walls/rocks. ~18.7/s at base draw. |
| Blowgun + darts | ranged DoT | 4 impact + poison | 6 (projectile) | 24 | darts consumable | Poison §4.1. Also denies first-aid for its duration (pulse period 24 < channel 48) — intended anti-heal value, priced accordingly. |
| Net | utility consumable | 0 | 3 (thrown) | 30 | 1 per net | Target immobilized 72 ticks (can still attack/use/talk, cannot move). Setup tool; hard-counters flight. Netted state is publicly visible. |
| First-aid kit | consumable | — | self | channel 48 | 1 | Heals 50 HP. Channel cancelled by ANY damage taken (kit kept; consumed only on completion). |
| Rations | consumable | — | self | eat 24 | 1 | Heals 15 HP on completion. Eating is **not** damage-cancelled (explicit rule; late-zone damage still out-paces it — §7.1). |
| Backpack | gear (body) | — | — | — | passive | Pack 2→4 slots. |
| Camouflage | gear (body) | — | — | — | passive | While worn: enemies detect you only within **4 tiles when you have not moved in the last 24 ticks, 7 tiles otherwise** (overrides their vision radius for you). Attacking reveals you arena-standard for **120 ticks**. |

- HP: every agent **100 max**, tracked internally in **centi-HP** (integer 1/100 HP — §5.2 rounding rule). No armor in v1. No hunger clock in v1.
- Ration-stall math (why the zone still wins): sustained eating = 15 HP/24t; stage-7 damage 24 HP/s ATH-scaled ≥ 16.8 — always net-negative; a full backpack of rations (20) plus every sponsor coin spent on rations only delays death ≈ 980 ticks past closure, inside the 1,584-tick cap margin (§1).
- Item system is data-driven (single item table + effect enums) so v2 additions (crafting, traps, more weapons) are cheap (LOCKED requirement).

---

## 4. Combat details

- Melee `attack {dir}` hits the first agent on the target tile(s); spear checks tile 1 then tile 2 in the direction (first agent hit).
- Projectiles are simulated entities: spawn adjacent tile in direction, advance 2 tiles/tick, stop at first agent/wall/rock. 8 directions only. Projectile entities carry shooter slot (publicly visible).
- Friendly fire: **always on**, including teammates (enables betrayal and the FFA finale with zero special-casing).
- Kill credit: last agent whose damage reduced the victim's HP (poison credits the dart shooter). Zone, mines, scripted events, and cap-kills credit nobody.
- Simultaneous lethal damage: both die same tick (mutual kills count for both).

### 4.1 Poison (pinned)
- Application at tick T: pulses of 2 HP at T+24k (k = 1, 2, …) until expiry. Duration: `12 × (20 − INT)` ticks of the victim (INT 1 → 228, INT 5 → 180, INT 10 → 120; base intent ≈ 240 scaled down by INT).
- Non-stacking: one timer per victim; reapplication (any shooter) resets duration AND pulse phase to the new application tick; the most recent shooter holds kill credit.

---

## 5. Stats (LOCKED frame: 4 stats, each 1–10 int, sum ≤ 20, policy-allocated at episode start; server validates; invalid → legal default + log)

### 5.1 Allocation
- `allocate_stats {speed, strength, intelligence, athleticism}` — during freeze, deadline `freeze_ticks − 24`.
- Valid: all integers in [1,10], sum ≤ 20. **First valid allocation wins and is immutable**; later `allocate_stats` messages are rejected with `alloc_result {rejected: true, reason: "duplicate", applied: <the accepted stats>}` and never alter the build (a retry after a lost ack must be safe). Invalid-or-missing by deadline → **default build 5/5/5/5** applied, `alloc_result {applied, defaulted: true, reason}`, logged.
- Baseline player allocates 6/6/4/4 (§18).

### 5.2 Effects — all integer/fixed-point (DECIDED: INT = vision + poison-resist + forage; ATH = dodge + hazard-resist + draw speed)
All damage/healing is computed in centi-HP with integer arithmetic; the pinned formulas ARE the spec (no float anywhere in the sim).

| Stat | Effect | Pinned integer formula | 1 | 5 | 10 |
|---|---|---|---|---|---|
| Speed | move cooldown (ticks/tile) | `16 − SPD` | 15 (1.6 t/s) | 11 (2.2 t/s) | 6 (4.0 t/s) |
| Strength | melee damage | `dmg_c × (5 + STR) div 10` | 0.6× | 1.0× | 1.5× |
| Intelligence | vision radius (tiles) | `5 + (INT + 1) div 2` | 6 | 8 | 10 |
| | poison duration suffered | `12 × (20 − INT)` ticks | 228 | 180 | 120 |
| | forage double-yield chance | `5·INT` in 100 (PRNG) | 5% | 25% | 50% |
| Athleticism | projectile dodge chance | `2·ATH` in 100 (PRNG) | 2% | 10% | 20% |
| | zone/event damage taken | `dmg_c × (100 − 3·ATH) div 100` | −3% | −15% | −30% |
| | bow draw time | `18 − ATH div 2` ticks | 18 | 16 | 13 |

- Sub-1-HP amounts accumulate exactly in the centi-HP ledger (e.g., stage-1 zone at ATH 10: 70 c-HP per application) — no rounding loss, no immunity threshold.
- Dodge and forage rolls consume the match PRNG in a fixed order (§15). A dodged projectile passes through and continues.
- Strength does NOT grant carry capacity (backpack owns that); keeps each stat single-purpose.

---

## 6. Vision, fog, observations

- Per-agent vision: radius per INT (§5.2), LOS raycast blocked by walls/rocks/Fortress. Tiles outside LOS: unknown entities; static terrain is common knowledge (arena layout, Fortress, pedestal ring, bush positions are in `player_config`; bush REMAINING charges are visible only in LOS).
- Camouflage per §3.2 modifies the *observer's* effective detection radius for the wearer (pure observation-layer effect; sim state is unaffected).
- Always visible arena-wide regardless of fog (LOCKED spectacle): death fireworks (slot + tile), the **boom** event (rough direction only), zone state, incoming/landed sponsor drop markers (landing tile + item public — counterplay), ignition fireworks, scripted-event warnings, finale event.
- Observation content: §10.3.

---

## 7. Hazards

### 7.1 Shrinking safe zone (LOCKED concept; DECIDED: fast ~5-min close)
Circular safe zone centered at C (fixed center v1). Outside = damage per second (applied every 24 ticks), ATH-scaled (§5.2). Per-stage rhythm: warn → +192 ticks shrink start → 432-tick shrink → 288-tick rest (912-tick stage cycle; every boundary a multiple of 24).

| Stage | Warn t | Shrink t | Done t | Radius → | Damage outside (HP/s) |
|---|---|---|---|---|---|
| 1 | 1,440 | 1,632 | 2,064 | 24→19 | 1 |
| 2 | 2,352 | 2,544 | 2,976 | 19→15 | 2 |
| 3 | 3,264 | 3,456 | 3,888 | 15→11 | 4 |
| 4 | 4,176 | 4,368 | 4,800 | 11→8 | 6 |
| 5 | 5,088 | 5,280 | 5,712 | 8→5 | 8 |
| 6 | 6,000 | 6,192 | 6,624 | 5→3 | 16 |
| 7 | 6,912 | 7,104 | 7,536 | 3→0 | 24 |

- **Radius formula (pinned)**: during a stage's shrink window, `r(t) = r_start − floor((t − shrink_t) · (r_start − r_end) / (done_t − shrink_t))`, evaluated at §1.2 step 2. At `shrink_t` r = r_start; at `done_t` r = r_end exactly (radius 0 lands precisely at t=7,536). **Inside** = `dx² + dy² ≤ r²` on tile centers.
- Stage 6–7 damage (16/24 HP/s) intentionally exceeds max sustained ration healing (15 HP/24t) at every ATH — the endgame cannot be out-eaten (§3.2).
- Rendered as an advancing fire/gas front (§16). Zone circle + next-stage target in every observation and on the spectator view.
- Schedule lives in config (§17.1) — fixture compresses it; variants can retune without code.

### 7.2 Scripted regional events (LOCKED concept)
Config-driven list; v1 types:
- `flood {rect, from_tick, duration}`: tiles impassable; agents caught on them take 4 HP/s (ATH-scaled) and may move out (movement allowed off flooded tiles, not onto them).
- `firestorm {center, radius, from_tick, duration}`: 6 HP/s (ATH-scaled) DoT inside region.
Both emit a warning event 120 ticks prior with the region geometry (arena-wide). Competition variant ships 1 flood (§17.4).

---

## 8. Death, finale, win (LOCKED)

- Permadeath. Death → black-fireworks visual + boom, arena-wide, in renderer + observations + static presentation replay. Inventory drops on death tile. Dead agents: no actions, no talk; they receive a terminal `final` message (§10.5); their policy container should then exit 0.
- **FFA finale**: the tick only one team has living members AND ≥2 of them are alive, a `finale` event fires arena-wide (distinct fireworks + banner). Nothing mechanical changes (friendly fire was always on) — the event is dramatic framing telling teammates the alliance is over.
- Win: last agent alive = winner (placement 1). Match ends immediately; `final` sent to all; artifacts written; process exits 0 per runnable contract.

---

## 9. Sponsor system (softcoin)

LOCKED frame: no platform economy exists — softcoin is a per-team budget fully accounted inside the game. Own-team gifts only in v1. Every gift is recorded in the sponsor log and public presentation replay. Certification never depends on a live human. No real-money integration, ever.

### 9.1 Accounting
- Budget: `sponsor.budget_per_team` softcoin per team per match (DECIDED: **300**). v1: one sponsor token per team.
- A request is atomically validated → accepted (full cost deducted at accept tick) or rejected (zero effect). Never partially applied (LOCKED). Rejection reasons: `insufficient_funds`, `shop_locked`, `recipient_dead`, `not_own_team`, `unknown_item`, `sponsor_disabled`, `malformed`.
- All accepts AND rejects logged to `sponsor_log.json` (§14) and echoed to stdout.

### 9.2 Catalog & prices (catalog/prices approved with DESIGN; DECIDED: fixed prices, no escalation)
| Item | Price | | Item | Price |
|---|---|---|---|---|
| Rations | 20 | | Backpack | 70 |
| Throwing knives ×4 | 30 | | Camouflage | 80 |
| Arrows ×6 | 30 | | Spear | 90 |
| Darts ×4 | 35 | | Blowgun + 4 darts | 100 |
| Net | 50 | | Sword | 120 |
| First-aid kit | 60 | | Bow + 6 arrows | 150 |

- Prices fixed for the whole match (DECIDED). No per-item caps — the budget is the cap (300 = 2 swords + change, not an army).
- Shop opens at t=1,680 (DECIDED: 60 s after ignition) — empty-handed spawns mean a tick-one weapon drop would bypass the Fortress scramble (LOCKED concern).

### 9.3 Gift path (both ingress modes → identical pipeline, LOCKED)
1. Request arrives: live (`/sponsor` WS, §11) or scripted (`sponsor.scripted_gifts` config list, §17.1) — same struct: `{recipient_slot, item_id}` + sponsor identity (token owner or `"script"`).
2. Validated per §9.1 at the current tick T. Accept → deduct and append to the sponsor log; the public result appears in the presentation replay (§14).
3. **Landing tile (pinned algorithm)**: fixed at T from the recipient's position P: enumerate Chebyshev rings r = 0, 1, 2, 3 around P; within each ring start at (P.x, P.y − r) and walk the full ring clockwise; the first **free** tile wins. Free = not wall/rock/Fortress wall, not occupied by an agent, landed pod, or a landing tile already reserved by an in-flight pod (reservations are made in gift-acceptance log order). If no free tile within r ≤ 3: fall back to the tile minimizing dx²+dy² from P among free tiles, tie-broken by the same ring enumeration order. Announced arena-wide immediately (`gift_incoming` with landing tile, **item id**, recipient, ETA).
4. Pod lands at **T+120** (5 s): parachute/pod sprite descends on the spectator view; `gift_landed` event.
5. Landed pod is a ground container with **public contents**: any agent (any team) may `pickup` it (DECIDED: free-for-all interception — drops are contested objectives). Persists until looted or match end.

### 9.4 Variant wiring (LOCKED by D3)
- **Certification fixture**: `sponsor.live: false`, ≥2 scripted gifts. No live path exercised by certify.
- **Competition variant**: `sponsor.live: false`, equal budgets, seeded scripted gift schedule (league fairness; hosted episodes can't receive live input).
- **Casual-live variant**: `sponsor.live: true` — **local `coworld play` only** (explicit scope: hosted variants have no sanctioned secret channel for per-team sponsor tokens; a `coworld.game_config_overlay.v1` secret overlay is the v2 route if hosted live-sponsorship is ever wanted). Sponsor tokens enter via runtime config, never the manifest.
- With `live: false` the `/sponsor` WS and `/client/sponsor` return 403.

### 9.6 v0.2 audience pivot (DECIDED 2026-07-31)
- Agents are AI-only: **no human controls any agent mid-game**. The ONLY mid-game human interaction is sponsorship. Human seats are gone from casual play — bots fill all 16 seats (supersedes §21.2's "keyboard play remains available in casual-live" note).
- Sponsors **adopt a team** (A–H) and spend that team's budget (300, §9.1 unchanged).
- Purchases are **tile-targeted**: the sponsor picks any tile; landing = nearest free tile by the pinned spiral (same spiral as §9.3 step 3, origin = the chosen tile instead of the recipient's position).
- **One purchase at a time per team**: 60 s lockout (`GiftLockoutTicks = 1440`; new reject reason `lockout`).
- The lockout applies ONLY to tile-mode purchases. Recipient-mode scripted gifts remain under their original rules (including `recipient_dead` and `not_own_team`) with no lockout.
- Wire deltas (§11): `gift_request` gains `target: [x,y]`; `sponsor_welcome` now carries `static_map` + `lockout_ticks`; `sponsor_state` carries `lockout_remaining`.
- Artifact deltas (§14): `GiftRecord` and `sponsor_log.json` gain `target`; `recipient_slot` is `-1` for tile gifts.
- New **read-only WS `/watch?slot=N`**: `player_config` + that slot's observation stream + `final`. No token, no inputs — leaks nothing `/global` does not already show. `/client/player` is now the read-only **Agent Cam** built on it.

---

## 10. Player protocol — `zero_sum.player.v1`

JSON over WS `/player?slot=K&token=...` (game-owned protocol; the Paint Arena player-protocol idiom). The endpoint accepts and ignores unknown query params; a `name` param, when present, is used for display. Server → client messages carry `type`. Malformed JSON, unknown `type`, or unknown action verbs are treated as `none` with `action_result: "malformed"` — never a disconnect (logged server-side).
Reconnects: a second connection with a valid token for an occupied slot **replaces the seat** (Paint Arena idiom; `coworld play` humans race their slot's container by design). The old socket closes; the new one receives `player_config`, the `alloc_result` if allocation already happened, and the current observation. Agent state is untouched — reconnection is pure transport.

### 10.1 `player_config` (on connect)
```json
{
  "type": "player_config", "protocol": "zero_sum.player.v1",
  "slot": 3, "team": "B", "teammate_slot": 2, "name": "P03",
  "arena": {"size": 48, "static_map": "<48 rows of 48 tile codes>",
             "legend": {".": "ground", "#": "wall", "R": "rock", "F": "fortress_wall", "P": "pedestal", "B": "berry_bush"},
             "pedestals": [[40,24], "...16 entries..."], "fortress_mouths": [[23,20],[24,20], "..."]},
  "freeze": {"ends_tick": 240, "alloc_deadline_tick": 216, "pedestal_mine_rule": "leaving your pedestal tile before ignition is instant death"},
  "stats": {"budget": 20, "min": 1, "max": 10, "default": [5,5,5,5]},
  "items": [{"id": "sword", "kind": "melee", "damage": 18, "range": 1, "cooldown": 18, "durability": 40}, "...full catalog incl. effects..."],
  "zone_schedule": [[1440,1632,2064,24,19,1], "...(warn, shrink, done, r_start, r_end, dmg_per_s)..."],
  "tick_rate": 24, "max_ticks": 9120, "ignition_tick": 240,
  "sponsor": {"enabled": true, "budget_per_team": 300, "shop_opens_tick": 1680, "catalog": {"sword": 120, "...": 0}}
}
```
### 10.2 `allocate_stats` / `alloc_result` — see §5.1 (first-valid-wins, duplicate-rejected semantics).

### 10.3 `observation` (server, every tick while alive, including countdown)
```json
{
  "type": "observation", "tick": 4200, "phase": "live",
  "you": {"pos": [12,40], "hp": 86, "stats": {"speed":6,"strength":6,"intelligence":4,"athleticism":4},
          "hand": {"id": "spear", "durability": 31}, "body": "backpack",
          "pack": [{"id":"rations","n":2}, {"id":"sword","durability":12}, null, null],
          "effects": [{"id":"poison","ticks_left":96}],
          "damage_taken": [{"source":"zone","amount":0.17}],
          "kills": 1, "damage_dealt": 214,
          "move_ready_in": 0, "attack_ready_in": 6, "action_result": "ok"},
  "visible": {"agents": [{"slot":7,"team":"D","pos":[15,38],"hp_band":"hurt","hand":"sword","body":null,
                            "netted":false,"poisoned":true,"channeling":false}],
               "items": [{"id":"arrows","n":6,"pos":[13,44]}, {"id":"sword","durability":8,"pos":[14,44]}],
               "pods": [{"pos":[20,30],"item":"first_aid","landed":true}],
               "bushes": [{"pos":[13,42],"charges":2}],
               "projectiles": [{"pos":[14,39],"dir":"W","kind":"arrow","shooter":9}]},
  "zone": {"center":[24,24], "radius": 15, "next_radius": 11, "warn_tick": 4080, "shrink_tick": 4320, "damage_per_s": 4},
  "events": [{"type":"death_fireworks","slot":9,"pos":[30,22]}, {"type":"boom","direction":"NE"},
              {"type":"gift_incoming","landing":[20,30],"item":"first_aid","lands_tick":4320,"recipient_slot":4}],
  "chat": [{"tick":4196,"from":2,"channel":"team","text":"push the mouth"}]
}
```
- The example above is one self-consistent tick (stage 3 active, shop open, no finale). The full event-type enumeration (these do NOT co-occur): `ignition`, `death_fireworks`, `boom`, `mine_explosion`, `zone_warning`, `event_warning` (flood/firestorm geometry), `gift_incoming`, `gift_landed`, `finale`, `match_end`.
- Effect id enumeration (self): `poison {ticks_left}`, `netted {ticks_left}`, `channeling {item, done_tick}`, `camo_revealed {ticks_left}`. Publicly visible on others: `netted`, `poisoned`, `channeling` booleans + worn `body` gear. Camouflage state is never flagged — a camouflaged agent is simply absent beyond §3.2 detection radii.
- `hp_band` for others: `healthy` (>66), `hurt` (33–66), `critical` (<33) — exact HP is private. `damage_taken` amounts are in HP (centi-HP rendered as decimals). Own `kills`/`damage_dealt` are visible so the §12.1 tiebreak is player-computable.
- `action_result` enumeration: `ok`, `cooldown`, `blocked`, `inventory_full`, `no_target`, `out_of_range`, `no_ammo`, `frozen`, `dead_target`, `malformed`, `rate_limited`.

### 10.4 `action` + `talk` (client)
```json
{"type": "action", "do": "move", "dir": "NE"}
{"type": "action", "do": "attack", "dir": "N"}
{"type": "action", "do": "pickup"} | {"do": "drop", "slot": "hand|body|0..3"} | {"do": "use", "slot": "0..3"} | {"do": "interact"} | {"do": "none"}
{"type": "talk", "channel": "broadcast" | "team" | "dm", "to": 9, "text": "≤120 chars"}
```
- One `action` per tick (first received wins, §1.2); `talk` is separate, rate-limited 1 per 24 ticks per agent (`rate_limited` result beyond), text ≤120 chars, **printable ASCII only (0x20–0x7E)** — the engine replay chat path filters to printable ASCII; the server strips other bytes and logs it.
- The engine replay chat record carries only (time, player, message) — no channel field — so the replay copy embeds the channel as a text prefix (`[team] …`, `[dm→9] …`); `chat_transcript.json` is the structured source of truth.
- Delivery next tick in recipients' `chat` (broadcast: all alive; team: teammates; dm: target only; sender receives its own message echoed). Dead agents send/receive nothing.

### 10.5 `final` (server, at death or match end)
```json
{"type": "final", "placement": 4, "kills": 2, "score": 10, "winner_slot": 2, "match_ticks": 8412, "reason": "eliminated"}
```

---

## 11. Sponsor protocol — `zero_sum.sponsor.v1` (LOCKED ingress: authenticated WS + browser console on the game container; token-gated, separate from ops/admin control)

- WS `/sponsor?team=B&token=...` — token must match `sponsor.sponsor_tokens[team]` from runtime config (secrets never in manifest). Bad token → connection rejected at upgrade. `sponsor.live: false` → 403.
- `GET /client/sponsor?team=B&token=...` — browser console: embeds the global spectator view + shop panel + budget + gift log. WS URL per the client-page contract below. The sponsor console URL is documented alongside the printed links.
- **Client-page WS contract (player, global, admin, sponsor)**: honor an optional `?address=` query param when present (the contract for pages served through an HTTP proxy, e.g. hosted play — verified KUBERNETES_RUNNER_README.md:147–149), else derive the WS URL from `window.location` with a pathname rewrite — the Paint Arena `websocketAddress()` fallback pattern (verified player.html:175–187). The static replay viewer instead receives an opaque replay URL in `?replay=` and makes no WebSocket connection.
- Messages:
```json
S→C {"type":"sponsor_welcome","team":"B","budget":300,"catalog":{"sword":120},"shop_opens_tick":1680,"tick":312}
S→C {"type":"sponsor_state","tick":2400,"budget":180,"team_alive":[2,3]}   // every 24 ticks
C→S {"type":"gift_request","request_id":"r1","recipient_slot":3,"item_id":"sword"}
S→C {"type":"gift_result","request_id":"r1","accepted":true,"cost":120,"balance":60,"lands_tick":2520,"landing":[20,30]}
S→C {"type":"gift_result","request_id":"r2","accepted":false,"reason":"insufficient_funds","balance":60}
```
- Sponsors see the omniscient public spectator frame but have **no channel to agents** in v1, so fog-piercing information cannot be relayed; this must be revisited before sponsor→agent messages (v2 backlog) are added.

---

## 12. Scoring & results (LOCKED frame: placement points + small kill bonus; sponsor spending never scores)

### 12.1 Placement points (16 slots — DECIDED: standard table, +1/kill)
| Place | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Points | 15 | 12 | 10 | 8 | 7 | 6 | 5 | 4 | 3 | 3 | 2 | 2 | 1 | 1 | 0 | 0 |

- Kill bonus: **+1 per kill** (DECIDED). `score[slot] = placement_points + kills`.
- Placement = reverse death order. Same-tick deaths tiebreak: higher total damage_dealt → better placement; then lower slot index. Winner = place 1. Deterministic, no draws. (Own damage_dealt is observable — §10.3.)

### 12.2 `results.json`
```json
{
  "scores": [10, 2, 19, "…16 numbers…"],
  "placements": [4, 12, 1, "…"], "kills": [2, 0, 4, "…"],
  "damage_dealt": [312, 45, 601, "…"], "survival_ticks": [8412, 3120, 8412, "…"],
  "gifts_received": [1, 0, 2, "…"],
  "winner_slot": 2, "winner_team": "B", "match_ticks": 8412, "seed": 133742
}
```
(Worked check: slot 0 = place 4 → 8 + 2 kills = 10; slot 1 = place 12 → 2 + 0 = 2; slot 2 = place 1 → 15 + 4 = 19. §10.5's example is the same match: winner_slot 2.)
- `scores` = the schema-required per-slot number array (16 numbers). Extra parallel arrays are allowed **when declared in our `results_schema`** (verified: Paint Arena ships `painted_tiles` alongside `scores`) — every field above is declared, `additionalProperties: false`.
- `seed` echoes the seed actually used (minted when absent from config — §17.1).

---

## 13. Chat transcript (LOCKED hard requirement: every message with tick, sender, channel/recipient)

- Names: when config `players[].name` is present (hosted runs inject display names — verified), the transcript uses them; otherwise `P<slot>`.
- `chat_transcript.txt` (human): `[t=01234] [team] P03 (B): push the mouth` / `[t=02350] [dm→P09] P02 (A): truce until zone 3?` / system lines: `[t=00240] * IGNITION *`, `[t=05500] * P07 (D) DOWN — 9 remain *`, `[t=02520] * SPONSOR DROP for P03 (B): sword, landed (20,30) *`.
- `chat_transcript.json` (machine): `[{"tick":1234,"slot":3,"team":"B","channel":"team","to":null,"text":"..."}]` + system events with `"slot":null,"kind":"death|gift|ignition|finale|zone"`.
- Echoed live to stdout with `CHAT ` prefix → lands in the public game-logs artifact (platform adaptation, LOCKED). Local runs also write both files next to results for convenience.
- **stdout hygiene (verified: game stdout/stderr are public)**: chat/sponsor/death lines are public by design; the seed, loot layout, and any hidden state are NEVER printed to live logs — the seed surfaces only in post-episode results and the platform's episode config.

## 14. Static presentation replay (LOCKED adaptation: platform carries results.json + one replay blob + logs)

The opaque bytes written to `COGAME_SAVE_REPLAY_URI` are a deterministic,
zlib-compressed sequence of timestamped `sprite_v1` packets. These are the
same public presentation packets generated for `/global`; no mechanics or
private player observations are duplicated into browser code.

The manifest declares `game.replay_viewer.bundle`. Observatory opens the
game-owned static `index.html` with the replay URL in `?replay=`. The viewer
fetches and validates the bytes, feeds packets into the shared global renderer,
and provides autoplay, pause, speed, seek, and loop controls without starting
the game image. Corrupt, incompatible, or missing artifacts fail visibly.

Human-readable chat transcripts, sponsor logs, event history, and fairness
reports remain separate local match artifacts. Auth tokens and hidden state
never enter the public presentation recording.

## 15. Determinism (LOCKED invariant; certify does NOT machine-check it — we enforce it ourselves)

1. Initial state = pure function of the seed (loot, bushes, rocks, crate rolls — single PRNG, fixed consumption order: rocks → crates positions → crate contents → bushes → tier-1 → tier-2 assignments).
2. Evolution = pure function of (state, applied inputs). All in-match randomness (movement contests, dodge, forage) draws from the same match PRNG in §1.2 step order. No wall clock, no ambient randomness, no hash-map iteration in sim, no floats (all centi-HP integer arithmetic, §5.2).
3. The applied-input log supports fairness reporting. Replay presentation is recorded directly from the public renderer and does not reconstruct the simulation from this log.
4. Live-play nondeterminism (network timing changes which inputs arrive by the tick boundary) exists ONLY upstream of the log — documented intentional boundary. Verified engine norm: fixed 24 Hz frame limiter, no wait-for-actions, no per-player action deadline.
5. Tick-hash record every tick; **repeat-run determinism test**: same seed + same scripted inputs twice → identical hash streams. Unit-tested in CI along with stat validation, scoring, softcoin accounting, and byte-exact presentation replay round trips. Platform rung-1 contract (verified, AUTHORING.md): same seed twice → identical initial state AND trajectory under a scripted policy; NO seed → differing states across runs; a new episode mints a fresh seed.
6. Never launch reproducible episodes via upstream multiruns/tournament_server (verified: they clobber config seeds with wall-clock values).

## 16. Renderer & spectacle (LOCKED: reuse sprite_v1 + vendored global client; spectacle is a design goal)

- `/global` speaks sprite_v1 to the shared global client. Static replay records and replays the same packets in-browser. `/client/player` = custom HTML client (JSON obs → canvas, action buttons/keys, talk box) — WS URL per the §11 client-page contract (`?address=` when present, else same-origin fallback). `/client/admin` + WS `/admin` = ops console; sponsor ingress stays separate (D2).
- Spectator composition (verified constraints): 128×128-px canonical screen; arena on the zoomable map layer (288×288 world px, 6-px tiles, i16 coords); HUD on anchored UI layers: alive count, zone stage + countdown, per-team color chips, softcoin balances, kill feed line. 16-color palette per sprite is the house convention — and ALL 16 indices are drawable: transparency is the engine's out-of-band sentinel 255, no palette slot is sacrificed (crosscheck-corrected; README's "15 visible" is unenforced convention). No text-drawing message exists — HUD text via upstream `pixelfonts.nim` (verified present).
- **No audio exists in sprite_v1** (verified absence). All "audible" cues are observation events for agents + visual effects for spectators: the boom is a screen-edge ring + black firework, not a sound.
- Set pieces: ignition fireworks (t=240, white/gold burst over Fortress); death = **black firework** burst at death tile + boom ring; zone front = animated fire/gas wall on the boundary ring; drop pods = parachute sprite descending 5 s + landing flash; flood/firestorm = tinted region + warning flash; finale = double gold burst + "FINALE" banner; win = crown fireworks on the survivor.
- Placeholder art in Phase C is explicitly fine (LOCKED) — flagged for aesthetic popups later.

## 17. Config, fixture, variants

### 17.1 Game config (schema sketch — `COGAME_CONFIG_URI` JSON; platform requires string-array `tokens`)
Verified platform rules baked in: `tokens` is runner-injected (authored configs MUST omit it; schema requires it, `minItems: 16, maxItems: 16` → seat count inferred). **`seed` is OPTIONAL** — absent means the game mints a fresh random seed at episode start and records it in `results.json`; the hosted platform separately archives the per-episode config. Never default it to a constant. Fog = hidden information, so per-episode random seeds are a security property. Optional `players` array (16 items, each requiring string `name`) lets hosted runs inject display names (they flow into transcript + HUD).
```json
{
  "tokens": ["<injected by runner — never authored>"],
  "seed": 133742,
  "players": [{"name": "P00"}, "… 16 optional display names …"],
  "teams": 8, "team_size": 2,
  "max_ticks": 9120, "freeze_ticks": 240,
  "zone": {"schedule": [[1440,1632,2064,24,19,1], "…"]},
  "events": [{"kind":"flood","rect":[10,22,14,26],"from_tick":4400,"duration":720}],
  "sponsor": {"live": false, "budget_per_team": 300, "shop_opens_tick": 1680,
               "scripted_gifts": [{"tick":2000,"team":"A","recipient_slot":0,"item_id":"rations"}],
               "sponsor_tokens": {}},
  "stat_budget": 20
}
```

### 17.2 Manifest & runnable-contract musts (verified against certifier/validator source)
- Manifest: `game` + ≥1 `player` + ≥1 variant + `certification`; **≥3 tags** (hard-required by certify); config_schema requires `tokens` (16/16); results_schema declares 16-slot `scores` + our extra arrays; docs `readme` + `protocols.player` + `protocols.global` as inline `{type:"text", value}` objects (verified allowed, types.py:220); `protocols.engine_runtime: "bitworld"` (platform enum value, not our naming); template must NOT set `game.version` (build stamps it); no `source_url` in v1 (absent → source-resolves skips); `episode_timeout_minutes` omitted → platform default 20 min.
- Compose: service `zero-sum` → placeholder `{{ZERO_SUM_IMAGE}}` (uppercase, dash→underscore — verified rule), `platform: linux/amd64` on every service. Paint Arena precedent: ONE shared Dockerfile/image for game + player, roles differentiated by manifest `run` argv — we follow it (game binary + baseline-player binary in one image).
- Certify smoke probes (exact, verified — coworld PLATFORM certifier, the one that gates upload): `/healthz` 200 → `GET /client/player?slot=0&token=<t0>` 2xx → WS `/player?slot=0&token=bad` MUST be rejected (close/handshake-fail/401/403) → `GET /client/global` OK → ≥1 frame on WS `/global` within min(timeout,10) s → game exits → results/replay checked after exit → player containers exit. When `game.replay_viewer.bundle` is declared, certification does not launch the legacy replay container; the bundle's browser proof is the replay gate.
- Player-failure channel (typed, platform): `COGAME_PLAYER_FAILURE_URI` → `{message: 1–2000 chars, failed_policy_index ≥ 0}`, atomic write (temp+rename). **Eliminations are normal gameplay and NEVER use it** — only unrecoverable protocol failures (e.g., a slot that never completes the WS handshake before ignition + grace).
- Fixture wall-clock budget: 600 ticks = 25 s sim + container start/stop fits the 60 s certifier timeout; the fixture schedule is pure config and shrinks further if tight.

### 17.3 Certification fixture (LOCKED shape: few ticks, 16 slots, deterministic seed, ≥2 scripted gifts)
- `seed: 42` (fixture pins the seed; the competition variant OMITS `seed` so hosted episodes mint fresh ones), `max_ticks: 600`, `freeze_ticks: 48` (ignition t=48, alloc deadline t=24), `shop_opens_tick: 96` (scripted gifts pass the SAME lockout validation as live ones — the t=120 gift must be legal), compressed zone: **radius 0 at t=400** (scaled stage table in config).
- Scripted gifts: t=120 rations ×2 → slot 0; t=200 sword → slot 2 (exercises accounting + drop pipeline inside certification, LOCKED).
- Expected resolution (recomputed): post-closure stage-7 damage 24 HP/s ATH-scaled (baseline ATH 4 → 21.1 HP/application) kills undamaged agents in ~5 applications ≈ 120 ticks → deaths ≈ t=520–560; slot 0's gifted rations (+30 HP) outlast the field → deterministic staggered ending inside 600 ticks, exercising heals, gifts, deaths, and placement. If a future tuning reintroduces survivors at the cap, the t=600 cap-kill + §12.1 tiebreak is an acceptable fixture resolution (documented, not accidental).
- 16 slots, every declared player seated (single baseline player id in all 16 certification slots).

### 17.4 Variants
Ordering is load-bearing (verified: the platform selects `variants[0]` for default hosted rounds) — `competition` MUST stay first.
1. `competition` — full schedule (§1/§7), equal budgets 300, seeded scripted-gift schedule (4 gifts across teams at fair ticks), 1 flood event, `live: false` (D3 LOCKED), no `seed` field.
2. `casual-live` — same match, `live: true`, sponsor tokens via runtime config, scripted gifts empty, **local play only** (§9.4).

## 18. Baseline player (LOCKED contract: legal build, grabs loot, fights strong/flees weak, obeys zone, claims own drops)

- Connects to the WS URL in **`COWORLD_PLAYER_WS_URL`**, falling back to `COGAMES_ENGINE_WS_URL` (verified: the certifier sets both to `ws://<game-alias>:8080/player?slot=N&token=T` — the game is NOT at localhost from inside the player container); absence of both is a fatal config error.
- Allocates 6/6/4/4. Waits out freeze on pedestal (never steps early).
- At ignition: paths to nearest Tier-3 crate (not the Fortress — risk-averse), arms best weapon found (sword > spear > bow > knives > blowgun > net).
- Fight/flee: engage if `(my_hp × my_dps) > 1.3 × (their_hp × est_dps)` on a visible enemy; else avoid/kite; flee below 35 HP; first-aid/eat when no enemy visible and HP < 60.
- Zone: paths inside the next radius when `zone_warning` fires. Claims pods addressed to self/teammate within 8 tiles. Forages when idle. Talk: none (silent baseline).
- On `final` (or WS close): exits 0 promptly, target **< 10 s** — the platform allows 30 s but bitworld's local validator only 10 s (crosscheck); fast exit passes both.
- Purpose: certify + demo quality, not competitive strength.

## 19. Decision record (owner, 2026-07-30 popups)
1. INT mapping (§5.2): **vision + poison-resist + forage.**
2. ATH mapping (§5.2): **dodge 2%/pt + hazard resist 3%/pt + draw speed.**
3. Scoring (§12.1): **standard table, +1/kill.**
4. Zone pace (§7.1): **fast ~5-min close** (close t=7,536; cap t=9,120).
5. Sponsor lockout (§9.2): **60 s** (shop t=1,680).
6. Budget (§9.1): **300 per team.**
7. Price escalation (§9.2): **none — fixed prices.**
8. Drop interception (§9.3): **free-for-all once landed** (contents public).

## 20. v2 backlog (LOCKED list + additions)
Remaining weapons (axe, sling, machete…), crafting, traps, trading, cross-team gifts/bribery, sponsor→agent messages, 12×2 roster, custom commissioner injecting per-episode gift scripts via `game_config_overrides`, hosted casual-live via `coworld.game_config_overlay.v1` secret overlay, zone re-centering, terrain variety (water/mud), consumable buffs, armor.

## 21. v0.2 — DECIDED additions (owner, 2026-07-31 popups)

### 21.1 Art revamp (DECIDED: 12px humanoids + full texture pass)
- Agents render as ~8x12-px humanoid figures (head/torso/legs, team-colored
  tunic, slot-parity pip), 4-way facing derived from last movement, 2-frame
  walk cycle, held weapon drawn as an overlay at the hand, distinct death
  pose in the tick before the black fireworks. Tall sprites overlap the tile
  behind (z-ordered by y — the engine draws lower-y first within a layer).
- Environment: stone-brick Fortress + border walls, grass ground with
  deterministic per-tile shade variation, bushes with visible berry dots
  (dots = remaining charges, capped 3), wooden crate chips for ground loot,
  2-frame flickering fire ring, water-styled flood tiles, pods descend under
  a parachute sprite while inbound.
- All art stays code-generated pixel data (no external asset pipeline);
  palette discipline: <=15 visible colors per sprite (house convention).

### 21.3 Esports visual system (owner spec, 2026-07-31)
Standard palette tokens: BG #0B0C10, masonry #1F2833, telemetry base #45A29E,
ring plasma #66FCF1 (stages 1-4) / #FF0055 (stages 5+ and lethal), gold
#C5A059 (pedestals/Fortress light/airdrops), toxic flood #39FF14, HP states
#2ECC71/#F39C12/#E74C3C. Team accents: A coral pink, B electric cyan,
C amber gold, D royal violet, E crimson (spec's "mint crimson" resolved),
F ice white, G burnt orange, H magenta (G/H defaulted — spec silent).
Spectator: dark-steel plate floor w/ recessed grid, granite Fortress with
golden mouth light, teal->crimson plasma ring w/ lightning micro-strikes on
burning agents, two chassis per team (Alpha heavy / Beta sleek), weapon
trails (white kinetic / green vapor / silver blur), poison halo pulse,
translucent camo w/ reveal glitch, netted energy mesh, death void beam +
black burst, airdrop gold beam + floating cargo typography. Player client:
ruthless tactical view — black fog matte, LOS shadow crosshatch, cyan self
token (cooldown gauge, stacked status tags), band-colored enemy tokens w/
weapon icons, symbol+count ground items, bush charge integers. Analyst
dashboard (new /client/analyst + JSON telemetry feed): live projected-score
scoreboard, softcoin ticker w/ interception callouts, post-deadline stat
matrix, FINALE takeover overlay. sprite_v1 constraint: all effects are
pixel-art equivalents (alpha supported; no 3D/shaders/camera motion).

### 21.2 Prompt-policy seats + pre-game lobby (DECIDED: game-side LLM)
- The human role becomes COACH: before the match each human (a) writes a
  free-text policy prompt and (b) allocates the 20 stat points. Both are
  IMMUTABLE once the countdown starts (allocation already first-valid-wins;
  the lobby closes with it). No mid-game control of prompt seats.
- Pre-game lobby: the connect-grace window becomes a lobby phase. The player
  page shows a stat allocator (live sum<=20 validation) + prompt textarea +
  READY. New protocol messages: `lobby_state` (S->C: seats, ready flags,
  countdown-arming), `lobby_ready` (C->S: {stats, policy_prompt}). Countdown
  begins when all expected seats are ready or the grace deadline passes.
- Runtime (DECIDED): the GAME container hosts the LLM agents. Hosted runs use
  the platform-granted Bedrock sidecar (InvokeModel); local runs use the
  operator's Anthropic key from the environment. Planner cadence ~48 ticks:
  compact observation digest + the seat's prompt -> a small plan (goal,
  aggression, target, optional talk line); a deterministic micro-executor
  (parameterized baseline heuristics) turns the current plan into per-tick
  actions submitted through the NORMAL player-input path — so every action
  lands in the input log and replays exactly (players remain outside the
  determinism boundary; LLM nondeterminism never touches the sim).
- Prompts are pre-game configuration: recorded verbatim in the effective
  config (replay header + artifacts) for provenance. Hosted episodes supply
  prompts via variant config / game_config_overrides (no live ingress — D3
  unchanged); the local lobby writes them the same way before tick 0.
- New variant `prompt-arena` (appended AFTER competition — variants[0] must
  not change): all 16 seats prompt-driven; unclaimed seats get a default
  prompt + 5/5/5/5. Competition/casual-live variants are untouched; keyboard
  play remains available in casual-live only.
