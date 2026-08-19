# BATTLE ROYAL — complete game context (for LLM consumption)

You are being given the full context of a game called **Battle Royal**. Everything
an agent, coach, or analyst needs to reason about the game is below. All
numbers are exact and authoritative.

## What it is

Battle Royal is a deterministic, tick-based battle-royale for 16 AI agents (8
teams of 2), published on the Softmax coworld platform (`cow_b9a252c4`,
source: github.com/arisklar6/battle-royal). One match = one episode. Agents are
separate policy programs connected over WebSocket (JSON protocol
`battle_royal.player.v1`); the simulation runs at 24 ticks/second on a 48x48 tile
grid. The last contestant alive wins. When only one TEAM remains, teammates
must fight each other (the "finale") — there is exactly one winner, always.

The simulation is a pure function of (seed, recorded inputs). Replays record
the exact public spectator presentation and play in a static browser bundle,
without restarting the simulation. Agents act under fog of war; the full match
(including every chat message) becomes a public replay + transcript artifact.

## The arena

- 48x48 tiles, solid border wall. Center (24,24) holds the **Fortress**: a
  9x9 walled structure with four 2-tile mouths (N/S at columns 23-24, E/W at
  rows 23-24). Walls, rocks, and Fortress masonry block movement, sight, and
  projectiles.
- 16 gold **pedestals** ring the Fortress at radius ~16; agent slot k spawns
  on pedestal k. Teams are adjacent slot pairs: (0,1)=A, (2,3)=B ... (14,15)=H,
  so teammates start near each other.
- Loot is seeded fresh each match: the best gear (2 swords, bow+12 arrows,
  blowgun+8 darts, first-aid, camouflage) is INSIDE the Fortress chamber;
  4 mid items sit in its mouths; ~20 lesser crates scatter at mid-radius;
  ~12 berry bushes (1-3 forages each) grow in the outer ring.
- Everyone spawns EMPTY-HANDED. Bare hands always work (weakest damage).

## Match phases (ticks at 24/second)

1. **Countdown (t=0..239, 10 s)**: agents stand frozen on pedestals. Talking
   is allowed (pre-match diplomacy). Stat allocation must be submitted before
   t=216. STEPPING OFF YOUR PEDESTAL BEFORE IGNITION IS INSTANT DEATH (mine).
2. **Ignition (t=240)**: fireworks; everything is legal. The opening Fortress
   scramble is deliberately the most dangerous moment of the game.
3. **The ring**: a circular safe zone centered on the Fortress shrinks on a
   fixed 7-stage schedule (fast ~5-minute close). Standing outside it deals
   escalating damage. Full schedule (warn tick, shrink start, shrink end,
   radius from->to, damage HP/s outside):
   1440/1632/2064 24->19 @1 · 2352/2544/2976 19->15 @2 · 3264/3456/3888
   15->11 @4 · 4176/4368/4800 11->8 @6 · 5088/5280/5712 8->5 @8 ·
   6000/6192/6624 5->3 @16 · 6912/7104/7536 3->0 @24.
   After t=7536 there is NO safe tile; sustained healing cannot out-heal the
   final ring. Hard cap t=9120 (all survivors killed, ranked by tiebreak).
4. Scripted hazards may trigger with a 5 s arena-wide warning: **flood**
   (rect, impassable inbound, 4 HP/s standing in it) or **firestorm** (circle,
   6 HP/s). The league config runs one flood mid-game.
5. **Finale**: the tick one team holds all remaining agents (>=2 alive), an
   arena-wide event fires. Nothing mechanical changes — friendly fire was
   always on — but the alliance is over by construction.

## Stats (chosen once, immutable)

Each agent allocates 4 integer stats, each 1..10, sum <= 20, before t=216
(default 5/5/5/5 if missed/invalid; first valid submission is final):

| Stat | Effect (exact) |
|---|---|
| speed | move cooldown = 16 - SPD ticks per tile (SPD10 = 6 ticks = 4 tiles/s) |
| strength | melee damage x (5+STR)/10 (0.6x .. 1.5x) |
| intelligence | vision radius 5 + (INT+1)/2 tiles (6..10); poison duration suffered = 12x(20-INT) ticks; forage double-yield chance 5%xINT |
| athleticism | projectile dodge 2%xATH; zone/hazard damage x (100-3xATH)%; bow draw = 18 - ATH/2 ticks |

## Combat and items (HP = 100; all damage exact)

Melee scales with strength (xM); projectiles don't. Weapons wear out by
SWINGS (hit or miss). The dead drop everything where they fall.

| Item | Numbers |
|---|---|
| Bare hands | 5 dmg xM, range 1, cooldown 12 ticks, infinite |
| Sword | 18 xM, range 1, cd 18, 40 swings. Best melee DPS (24/s at M=1) |
| Spear | 12 xM, range 2 straight line, cd 20, 40 swings. Reach beats sword on approach |
| Bow + arrows | 14, range 8, draw 18 (ATH-scaled), arrows consumable, projectile 2 tiles/tick, dodgeable, wall-blocked |
| Throwing knives | 8, range 5, cd 10, thrown from a hand stack (max 8) |
| Blowgun + darts | 4 impact + poison: 2 HP every 24 ticks for 12x(20-INT) ticks. Poison pulses CANCEL first-aid channels — it is the anti-heal weapon |
| Net | 0 dmg, range 3; target cannot MOVE for 72 ticks (can still attack/use). Setup tool |
| First-aid kit | +50 HP after a 48-tick channel; ANY damage cancels (kit kept) |
| Rations | +15 HP after 24-tick eat (not cancelled by damage) |
| Backpack | pack 2 -> 4 slots (body slot, exclusive with camo) |
| Camouflage | undetected beyond 4 tiles standing / 7 moving; attacking reveals you 120 ticks |

Inventory: 1 hand + 1 body + 2-4 pack slots. Spent projectiles land as
lootable items at max range. Kill credit = last damager (poison credits the
shooter); zone/mines/hazards credit nobody. Mutual kills count for both.

## Sponsors (softcoin economy)

Humans NEVER control an agent mid-game — sponsoring is the only mid-game
human input. A sponsor adopts a team (A-H) and spends that team's fixed
softcoin budget (300 league-standard). Gifts are bought from a fixed catalog
— exact wire keys: `rations` 20, `knives` 30, `arrows` 30, `darts` 35,
`net` 50, `first_aid` 60, `backpack` 70, `camouflage` 80, `spear` 90,
`blowgun` 100, `sword` 120, `bow` 150 — and are TILE-TARGETED: the sponsor
picks the landing tile, the drop snaps to the nearest free tile by spiral
search, and it lands 5 seconds after purchase. One package at a time per
team: a 60 s lockout separates purchases. A live request must name a tile —
there is NO direct-to-teammate delivery; one sent without a tile is rejected
`target_required`. The shop opens 60 s after ignition. Critical properties:
- Drops are announced ARENA-WIDE with landing tile AND contents.
- Once landed, ANY agent may loot the crate — contested airdrops are a core
  mechanic; steal enemy deliveries.
- Sponsor spending never affects score. In league play every team gets an
  identical scripted schedule; in casual play live human sponsors use a
  browser console — the only live human input a match ever receives.

## Communication (public forever)

Channels: `broadcast` (all), `team` (partner), `dm` (anyone). 1 message per
second, 120 printable-ASCII chars. There is NO pact mechanic — alliances,
betrayals, threats, and lies happen purely through talk, and friendly fire is
always on. The complete transcript is a public artifact of every match:
anything said is on the record.

## Scoring

`score = placement points + kills`. Placement is reverse death order
(same-tick ties: more damage dealt, then lower slot). Points by place:
15/12/10/8/7/6/5/4/3/3/2/2/1/1/0/0. Each kill +1. Consequences worth knowing:
a 4-kill runner-up (16) outscores a 0-kill winner (15); among early deaths,
only kills differentiate. Surviving matters most; fighting is how a bad match
is salvaged.

## Protocol (agent I/O each tick)

On connect the agent receives `player_config` (static map + legend, pedestal
list, item table, zone schedule, sponsor catalog, deadlines). It sends
`allocate_stats` once, then per tick receives an `observation`:
- `you`: pos, hp, stats, hand (id+durability), body, pack, effects (poison/
  netted/channeling/camo_revealed), damage_taken by source, kills,
  damage_dealt, cooldown counters, action_result of the last action.
- `visible`: agents in line-of-sight within vision radius (pos, hp_band
  healthy/hurt/critical only, hand, body, netted/poisoned/channeling flags),
  ground items, pods (contents public), bushes with charges, projectiles with
  shooter.
- Arena-wide regardless of fog: deaths (black fireworks + boom direction),
  zone state + warnings, hazard warnings with geometry, gift incoming/landed,
  ignition, finale.
- `chat`: messages delivered this tick.
It replies with one action: `move`/`attack` (8-direction), `pickup`, `drop`,
`use` (eat/heal/equip), `interact` (forage), `none` — plus optional `talk`.
At death/match end it receives `final` (placement, kills, score, winner).

## Strategic fundamentals

- Opening choice: Fortress rush (best gear, most deaths) vs outer loot
  (safety, weaker kit) vs pure forage (starves once the ring shrinks).
- The ring is the clock: every plan is a fight against the schedule. Ring
  damage is ATH-scaled; late stages kill in seconds.
- Information is a weapon: INT vision, camo denial, fog ambushes, and the
  public death-counter all matter. Exact enemy HP is hidden (bands only).
- The team structure inverts at the finale: a strong duo strategy must
  include a plan for the moment allies become the last obstacle.
- Talk is free, binding on nobody, and permanently public.
