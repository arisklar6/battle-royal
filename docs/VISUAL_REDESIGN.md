# ZERO SUM — Visual Redesign & Art Direction Bible

**Codename: AFTERGLOW** · *"Sixteen programs. One machine. Every signal leaves a trace — one outlasts them all."*

Status: proposed v1.0 (2026-07-31). This document supersedes DESIGN.md §21.1 and §21.3 where they conflict (both with each other and with this doc); it preserves every LOCKED gameplay/protocol decision, the fog-as-security-property invariant, the code-generated-art-only pipeline, sprite_v1 constraints (no shaders, no 3D, no camera motion primitives, no audio channel), and the naming rules (no engine names, no Hunger-Games vocabulary in public-facing copy).

Evidence base: full code audit of `game/render.nim`, `game/client/*.html`, `game/server.nim`, `game/analyst.nim`, `src/zero_sum/{sim,obs,types}.nim`, DESIGN.md, `docs/LLM_CONTEXT.md`, and the seven `docs/evidence/v02_*.jpg` captures. Direction selected by scored competitive review of three independent identity pitches (broadcast-package / machine-instrument / handcrafted-diorama); the machine-instrument identity won on thematic truth and feasibility, with specific grafts from the other two called out inline.

---

## Part 1 — Brutally Honest Critique

*Written as the Steam Early Access review we do not want to receive.*

The bones of Zero Sum are excellent: a deterministic sim with real strategic geography, a designed spectacle channel (arena-wide deaths, airdrops, a scheduled ring), and a genuinely novel hook — AI agents negotiating and betraying each other in public. Almost none of that reaches the screen. The presentation today is three unrelated prototypes wearing one WebSocket, and every one of them keeps the game's drama a secret.

### CRITICAL — the product does not communicate its own game

1. **Fights are invisible on the flagship view.** `/global` draws no HP (no bars, no bands), no hit reaction, no attack animation, and no facing-toward-target (facing derives from movement only — agents stab sideways without turning). A sword duel is two 8×12 sprites standing adjacent until one emits a black firework. The single obligatory spectator question — *who is winning, who is about to die* — is unanswerable on the surface built to answer it.

2. **Nobody on the broadcast has a name.** Sixteen agents are distinguished only by 8 tunic hues plus a 1px parity pip. No slot numbers, no labels. Casters cannot say "P5 is making a move" because P5 does not visually exist. Rivalries, kill leaders, revenge arcs — the emotional skeleton of battle-royale viewing — cannot form around anonymous color swatches.

3. **There is no kill feed anywhere.** The sim tracks last-damager kill credit; no surface ever prints "P5 killed P11 with the bow." A death is an unattributed near-black puff (25,25,30 particles on a #0B0C10 floor — contrast under 1.5:1) and a corpse that despawns after 96 ticks. A 16-agent match tells 15 death stories and the broadcast narrates none of them.

4. **Chat — the soul of the game — is dark.** Alliances, threats, lies and the finale betrayal happen purely through talk, permanently public *by design*, and no live surface shows it. It is echoed to server stdout and shipped as a post-match file. Live viewers watch the betrayal with no idea a deal ever existed. This is broadcasting poker without ever showing a hole card.

5. **The player client's drama layer is plausibly dead code.** `player_client.html` L162 switches on `e.kind`; the wire (per `obs.nim eventJsonNode` and `player_protocol.md`) sends `"type"`. If so, IGNITION / RING SHRINKS / CIVIL WAR / VICTORY / ELIMINATED banners never fire — consistent with both screenshots, which show active ring phases and no banner. One field name is gating every scripted emotional beat the view has. Independently: `death_fireworks`, `boom`, `mine_explosion`, `event_warning`, `gift_incoming/landed` are unhandled — **hazards (flood 4 HP/s, firestorm 6 HP/s) have no visual at all in this client**, and the agent being watched can visibly dissolve to invisible damage.

6. **The ring has no clock, anywhere.** The 7-stage schedule is fixed, public, and in every config payload, yet `/global` shows only "RING 24": no countdown, no next-radius preview, no warn-phase indicator, and **zero tint outside the ring** — the terrain actively killing agents looks identical to safe ground. The spec calls the ring "the clock"; the broadcast throws away anticipation, the cheapest drama a fixed schedule can buy.

7. **The two spectator data surfaces cannot be composed.** `/global` has positions but no identity/HP/scores; `/analyst` has exact HP, kills, projected scores — and no positions, no map. A caster (or any third-party overlay) cannot anchor scoreboard to camera. This structurally blocks professional broadcast tooling.

8. **Three unrelated visual languages render one match.** Pixel-art humanoids + 3×5 bitmap font (spectator); anti-aliased vector circles + Unicode dingbats (⚔ ✚ ◘ ▒) at 9px Consolas (player); plain dark DOM tables (analyst/sponsor). An agent is a hand-drawn humanoid in one window, a flat circle in the next, a table row in the third. Only the eight team hexes carry across. The suite reads as three prototypes by three people.

### MAJOR — trust, atmosphere, and the moments that should land

9. **Two coexisting art passes in evidence.** `v02_art_firering.jpg` / `v02_art_parachute.jpg` show a retired pass (green grass, white fortress, lava ring) that no longer matches shipped code (navy steel, teal plasma). Any store page built from `docs/evidence` shows two games that don't exist together. DESIGN.md deepens the fork: §21.1 specs tunic humanoids, §21.3 specs "two chassis per team" robots — unreconciled.

10. **Semantic color collapse.** `#39FF14` toxic green means five things at once: flood hazard, poison halo, *healthy* HP, netted mesh (near), and LIVE status. Green-as-poison and green-as-full-health in the same frame inverts the danger signal. (DESIGN.md §21.3 actually specced #2ECC71/#F39C12/#E74C3C for HP bands; the implementation swapped in the alert triad.) Gold `#C5A059` is similarly spread across ten meanings — lethal pedestal mines, harmless loot chips, airdrop beams, cooldown gauges, prices, fireworks — so it cues nothing.

11. **The broadcast HUD ships broken.** The COIN viewport is 244px; the string needs ~262px, so team H truncates to "H31" *in the hero screenshot*. Displayed budgets (~3000) contradict the spec's 300 league standard. The 3×5 font is missing J and Q — those letters render as blank. Numbers that are clipped, wrong by 10×, and missing letters, on the flagship view, erode trust in everything else on screen.

12. **No lighting, no atmosphere, no environmental storytelling.** Flat-lit hash noise; no vignette, no glow, no shadow, no darkening outside the zone; the Fortress chamber holding the best gear in the game looks like everywhere else; corpses vanish; the arena at minute 5 looks like minute 1, only emptier. The map accumulates no narrative, and the strategic geography the spec names (Fortress rush vs outer forage) is not drawn.

13. **Airdrop drama dies at touchdown.** Inbound is the best-composed moment in the build (gold beam, parachute, price label) — then the label deletes and `SpPodCrate` is never keyed to contents, so the *designed contest* is a fight over an anonymous wood tile. Steals surface only as an analyst text row. Meanwhile the sponsor — the only live human in the loop — aims drops on a static map with no ring, no teammate positions (`sponsor_state.team_alive` arrives and only `.length` is read), no hazards, no legend, mouse-only, no confirm step, 12px targets, and a 60s lockout punishing misclicks.

14. **Finale and victory are anticlimaxes.** The signature teammates-must-fight moment is a 4-second 3×5-caps banner (and a possibly-never-firing off-center "CIVIL WAR" at hardcoded left:240/top:260 on the player view). Victory: a 4s gold firework and a tiny banner over an anonymous sprite; on the analyst desk the WINNER overlay parks *on top of* the final scoreboard at the exact moment viewers want to study it. A 6-minute match resolves in under 5 seconds of acknowledgment.

15. **Replay controls belong in the static viewer.** The presentation recording supports seek, speed, pause, and loop without starting a game server.

16. **Motion quality: teleporting board pieces.** No interpolation anywhere (spectator objects and player tokens snap per packet); every flicker effect shares one 6-tick metronome, so ring, halos, and hazards pulse in eerie lockstep. Chases — a whole stat's worth of gameplay — read as flicker, not motion.

17. **Accessibility is failing, concretely.** Team wheel collapses under deuteranopia (A coral/E crimson/G orange/H magenta become near-identical warm smudges; F ice-white reads as "no team" and vanishes on light chips); HP is a green/orange/red traffic light with no shape redundancy; analyst greys measure 1.9–2.3:1 against WCAG's 4.5:1; 9–11px text carries the most safety-critical data; 4-flips/sec full-region flicker with no `prefers-reduced-motion` path; no audio channel at all; no keyboard path on the one interactive surface; no aria-live on 4 Hz innerHTML rebuilds.

### MINOR (but visible)

18. **Effect id collision bug**: `spawnEffect` ids (`ObEffectBase + n mod 50_000` → 1000–50999) overlap every pooled object base (bushes 20000, ring 30000, pods 40000, items 41000, projectiles 42000, regions 43000, HUD 44000+). Long, fight-heavy finals can clobber live world objects on air.
19. `ITEM_GLYPH` key `camo` vs wire id `camouflage` — the most expensive stealth item renders as `?` on the ground.
20. Channeling (the 48-tick heal, cancel-on-damage — the game's built-in clutch moment) has **no visual on any surface**; poison-cancels-heal is equally invisible.
21. Duplicated `id="hpbar"` per analyst scoreboard row (invalid HTML); ticker dedup key omits status; sponsor markers are client-state only and vanish on reload.
22. Player client header says "Agent Cam" while docs say "tactical player client"; hardcoded 672px canvas, fixed 300px column, ~70% of the widescreen viewport is void.

**Summary judgment:** the sim broadcasts drama; the clients discard it. Most of Part 1 is not missing *art* — it is missing *rendering of data already on the wire*. That is the good news: the ceiling is high and much of the floor is a client-side fix.

---

## Part 2 — Vision Statement

### The identity: AFTERGLOW

Zero Sum is a deterministic machine that admits sixteen programs and lets exactly one leave. The screen should look like what that *is*: **precision instrumentation watching a knife fight.**

The world renders as a beautiful machine — a monochrome, blue-black instrument substrate where the only things that carry color are the sixteen living processes. Everything *built* (walls, crates, panels) is orthogonal and chamfered; everything *emitted* by the simulation (vision radii, the ring, pings, shockwaves) is a perfect analytic circle — honest, because those radii are closed-form. Light behaves like phosphor on a scope: signal persists, decays, and — when a program dies — **burns in**. Every agent drags a fading trace of its path; every death freezes that trace into a permanent 12%-alpha scar with the agent's name etched at the death tile. By endgame the arena is a readable autopsy of everything that happened — which is exactly what a bit-exact, transcript-public game *is*. The record made visible.

Layered on the machine, the voice of the show is a **ledger**. The game's name is an accounting identity and every mechanic behaves like one: fixed budgets, placement settled in reverse death order, kill credit to the last damager, a public transcript. So the copy is settlement copy — an agent is not "killed," their account is **SETTLED**; the winner **COLLECTS**; a stolen airdrop is **INTERCEPTED** — and death is a ledger line struck through on every surface at once. (One exception, 0.1.16: the kill-feed chyron drops the literal word `SETTLED` for column budget — the banner stamp, the own-death stamp and the analyst ledger all keep it.)

And the cost is kept visible by light: a row of **sixteen lamps** in every client's HUD — lit phosphor for the living, a one-frame flare then cold slate at each termination. The winner card is the thesis shot: one lamp still lit, fifteen cold, over the full burned-in trace map.

### Mood

Mission control during a shipwreck. Calm surfaces, terrible content. The interface never panics — instruments don't — which makes the moments when the screen *does* raise its voice (a settlement line, the finale rule-slam) land harder.

### Target audience & Steam first impression

Agent authors, AI-curious spectators, and strategy players who love Into the Breach's honesty and SC2's observer craft. The store-page impression in one sentence: *"This is a real sport for programs, played on an instrument that remembers everything."* Every promotional frame must contain traces, burn-in scars, or the lamp row — never a clean empty terminal (promo discipline graft from the diorama pitch: the brand always shows the record of a fight).

### Core design principles (the laws)

1. **Structure is square; signal is round.** Built things: orthogonal, 45° chamfers, no fillets. Simulation-emitted things: analytic circles/arcs. The eye learns in one match that curves mean live math.
2. **Only the living carry color.** The world is a two-tone machine (Faraday substrate + Etch structure). Team hues exist solely on agents, their traces, and their chips — sixteen points of color in a monochrome arena.
3. **Semantic colors are contracts.** Phosphor = live signal. Amber = matter & money. Magenta = commanded geometry (ring, hazards, lockouts). Red = harm, now. No color ever moonlights. **There is no green anywhere in the identity** — nothing in this game means "go."
4. **Fog renders knowledge, not darkness.** The static map is public in `player_config`; hiding it from humans is a lie. Fog hides only dynamic signal, in three exact states (energized / afterglow / schematic).
5. **Everything on the record stays on screen.** Traces, scars, struck-through ledger rows, persistent corpse marks. The match accumulates.
6. **Amber pierces fog.** Airdrops are arena-wide knowledge by spec; gold is the only color that ever crosses a knowledge boundary, and everything sponsor-touched is loud.
7. **Motion ticks, never eases.** The sim is tick-based; the UI moves in hard steps (CSS `steps()`, 2–4 frame cuts). Numbers tick, they do not tween.
8. **If an effect hurts clarity, it is wrong.** Bloom exists only on the spectator, capped; the player view is an instrument with zero glamour.

---

## Part 3 — Complete Art Direction

### 3.1 Palette (system tokens — replaces the §21.3 set)

| Token | Hex | Role |
|---|---|---|
| **Faraday** | `#0C1116` | Substrate. Every background, every client. Blue-cast near-black; never pure #000 (pure black is reserved for spectator letterbox bars). Terrain floor = Faraday + 4%-alpha etch grid. There is no "grass"; there is chassis. |
| **Etch** | `#36444F` | Structural ink. Walls, rocks, Fortress masonry, grid, dead UI, fog schematic, eliminated chips. Legal ramp `#1C242B` (dim) → `#4E5E6B` (bright); new gray hues are not legal. |
| **Phosphor** | `#A5E3EE` | Live signal. Agents' silhouette light, vision circles, traces, healthy HP, live text, LOS lines. Peak-white `#EAF7FA` for 1-frame flashes. Hue-locked at ~190° — Tektronix blue-phosphor lineage, explicitly not terminal green. |
| **Amber** | `#FFB454` | Matter & economy. All loot, crates, pedestals, berries, airdrops, softcoin, durability, "hurt" HP band. The only warm tone in the machine. |
| **Directive Magenta** | `#FF4FA3` | Commanded geometry. Ring (solid current / dashed target), hazard footprints, countdown arcs, lockout timers. Avionics flight-director lineage: magenta is the path you must obey. Never decorative. |
| **Klaxon Red** | `#FF4A36` | Harm, now. Damage flashes, critical HP, poison pulses, the pedestal mine, death-frame accents. Red is spent, never worn. Red and magenta never share a line weight (disambiguation at 1–2px). |

**Team wheel (16 agents / 8 duos).** Team hue appears *only* as fills (carrier diamond, trace tint, chip); semantic colors appear *only* as lines/glyphs/UI — fills vs lines is itself a channel. Team hue is never used alone: the identity plate (player name) or team letter always sits adjacent — except while the plate is suppressed in a cluster, see Part 8. Candidate wheel, S/L-locked, to be validated through a CVD simulator before freeze (a CI palette-lint step guards the hue lock and this gate):

`A #FF8FA8 rose · B #49C7E8 cyan · C #E8C558 gold · D #9B7BFF violet · E #E85D75 wine · F #9FB8D8 steel (replaces invisible ice-white) · G #E8975D copper · H #D97BE8 orchid`

Rationale for the two changes from v0.2: F `#EBF5FF` disappears against light UI and reads as "no team"; E `#DC143C` collides with the danger red. If any pair still fails CVD testing, the letter-glyph pairing rule is the guaranteed fallback channel.

**HP semaphore (protocol-honest — graft from the broadcast pitch).** The wire exposes exactly three bands; the palette encodes exactly the bands and nothing more: healthy = Phosphor, hurt = Amber, critical = Klaxon Red — everywhere, all clients, plus arc-length redundancy (band shown as ring-arc fill fraction, not hue alone). The bright green HP bar is the first thing retired.

### 3.2 Typography

- **Display:** Routed Gothic Wide (free digitization of Gorton engraving lettering — the face literally machined into cockpit panels). All-caps, +12% tracking, always seated on a 1px rule. **Forbidden below 24px** (it is thin; below that the data face in bold takes over). `WINNER P5 · TEAM C` at 120px, letterspaced across a rule, is the trophy shot.
- **Body:** IBM Plex Sans, Regular/Medium only — catalog labels, docs, prose.
- **Data:** Berkeley Mono if the license is approved; JetBrains Mono NL otherwise. Tabular figures and slashed zero mandatory. Every number, transcript line, ticker row, timestamp. This face is the court record.
- **Renderer bitmap:** v1 ships by snap-scaling JetBrains Mono into the pixel HUD; a bespoke 8×12 bitmap cut (squared counters, slashed zero) is a declared fast-follow. The 3×5 font is retired (it is also missing J and Q — fix the glyph table anyway for any interim use).
- **Rules of voice:** display shouts placement; mono testifies; body disappears. Numbers never tween — they tick.

### 3.3 Shape language

Two laws in permanent opposition (see Part 2): chamfered orthogonal structure vs analytic emitted circles. Additions:

- **UI framing:** corner brackets and registration ticks, never closed boxes — reticle grammar. The sponsor console's targeting square already had the right instinct; it becomes the family grammar.
- **Line weights:** 1px Etch for structure; 2px for energized phosphor/magenta. On broadcast output, energized lines may thicken to 2px minimum for stream-compression survival.
- **Agents:** rebuilt as 6×8 **carrier** sprites — compact symmetrical phosphor silhouettes standing on a 1px team-hue diamond (RTS under-ring), identity plate beneath. (Ship-path note: v1 may recolor the existing 8×12 humanoids and add the diamond + glyph; the carrier rebuild is a fast-follow. This resolves DESIGN.md's humanoid-vs-chassis fork in favor of carriers, with humanoids as the transitional skin.)
- **Weapon read:** held item renders as a phosphor glyph at the carrier's hand point; attacks turn the carrier toward the target for the swing tick (facing from action, not just movement).

### 3.4 Terrain, Fortress, props, environment

- **Ground:** Faraday + 4% etch grid; deterministic per-tile shade hash stays (it's good) but within the Etch ramp. Inside-ring floor lifts +3% luminance so "safe" reads subliminally.
- **Border wall & Fortress:** Etch chamfered blocks — the machine's frame. The Fortress is the arena's one *landmark*: slightly brighter masonry ramp, mouth tiles carry a slow amber pulse (kept from v0.2 — it's correct: the best loot in the game glows like matter), and the interior chamber floor carries a faint amber etch pattern so the prize room reads as a prize room.
- **Pedestals:** amber tiles ringed with a hazard-stripe chamfer *until ignition* (they are mines pre-ignition — Klaxon-red corner ticks during countdown, dropping to plain amber at t=240). The most dramatic pre-ignition rule finally has a color.
- **Rocks:** Etch-ramp boulders with a single phosphor edge highlight on the north face (one-rule lighting, see 3.6).
- **Bushes:** the one organic exception — small Etch-dark clusters whose berries are amber pips; charges = visible pip count (kept).
- **Loot tiers readable at a glance:** ground items stay amber diamond chips; Fortress-chamber spawns sit on the amber-etched floor; pods are chamfered amber crates with stenciled contents glyph (see 6.5).

### 3.5 Environmental storytelling (the record on the board)

- **Traces:** every agent drags a decaying phosphor trace (~3s player / ~8s spectator decay), team-tinted at low alpha.
- **Burn-in scars:** at death, the trace freezes and the agent's name etches at the death tile at 12% alpha, under items, for the rest of the match. Fifteen scars maximum by definition.
- **Corpse marks:** the decomposition burst (Part 7) leaves the loot pile as the grave marker — dropped gear *is* the corpse, mechanically true and permanently legible.
- **Ring history:** de-rezzed exterior stages persist (see 3.7) so the board shows where the world used to be.
- Late-game frames compose themselves: the final duel happens on a scarred, half-derezzed board threaded with sixteen colored traces. That frame is the marketing.

### 3.6 Lighting & materials

No dynamic lighting engine and none needed. Three cheap rules:

1. **Energized floor:** tiles inside any live vision/LOS context lift +6% luminance (player view only).
2. **One-key edge light:** props get a single phosphor-tinted top edge (1px) — instrument backlight, not sun.
3. **Spectator-only bloom:** one additive pass on phosphor/amber/magenta emitters, capped, disabled in the player client entirely (the panel has zero glamour) and under `prefers-reduced-motion`.

### 3.7 The ring (deallocation, not fire)

- Current safe radius: solid 2px Directive Magenta analytic circle at the exact per-tick float radius (deterministic schedule → sub-tile smooth motion, no lurches).
- On each `zone_warning`: target radius appears as 1px dashed magenta circle; the condemned annulus fills with 45° magenta hatch at 8% alpha.
- **Outside the ring, the world de-rezzes** in three authored tile states keyed to ring stage: art decays to Etch wireframe → raw grid → Faraday void with dropped-pixel dither. The simulation reclaiming memory. Three extra tile sprites, zero shaders. (First-shrink caveat: always paired with the hatch band + HUD countdown so it cannot read as a render bug; the caster lower-third explains it during season one.)
- HUD is instrument-calm: `RING 19→15 · SHRINK T-0:38` in the data face with a thin magenta countdown arc; exactly one full-frame 1-frame magenta flash when a shrink begins. After t=7536 the entire board carries the hatch: the machine is closing the file.

---

## Part 4 — Player View Redesign ("The Panel")

The player client (and `/watch` agent-cam) is the cockpit of the aircraft the show is filming. Same family as the broadcast, opposite temperament: no letterbox, no chyrons, no bloom, fixed north-up, nothing animates that is not simulation state. It must remain a *truthful* rendering of `zero_sum.player.v1` — it never displays information the agent does not have.

### 4.1 Fog = three knowledge states (replaces the black matte)

1. **Energized (in LOS + radius):** floor +6% luminance, entities at full phosphor/team color.
2. **Afterglow (witnessed, now unseen):** last-known dynamic info persists as fading ghosts — hollow team-hue squares with an age stamp (`+4s`, data face), expiring at 10s. Terrain stays crisp (it's static and public).
3. **Schematic (never energized):** the full static map — walls, Fortress, pedestals, border — always visible as dim Etch blueprint lines on Faraday. *Fog hides only dynamic signal.* The current 13%-alpha ghost-on-black (measured ~1.1:1 contrast — functionally a black rectangle) is retired.

In-radius-but-LOS-blocked keeps a hatch treatment (the current crosshatch instinct was right), redrawn as Etch diagonal hatch, not teal.

### 4.2 The vision rim is the instrument

The vision boundary is an exact 1px phosphor circle at the computed radius (5+(INT+1)/2 — closed-form, so the circle is honest), with compass tick marks. **Every arena-wide event registers on the rim as a bearing tick** — this is what makes the view an instrument:

- Death somewhere: Klaxon-red tick at the boom bearing + `P7 ✕` tag (the wire's `boom` event is direction-only by design; the rim renders exactly that).
- Airdrop: amber tick with distance readout, plus the reticle at the tile itself rendered in full amber *over any fog state* (amber pierces fog — pods are arena-wide data).
- Ring/hazard warnings: magenta arc segment on the rim toward the encroaching geometry.

### 4.3 Self, others, statuses

- **Self:** filled phosphor carrier + white 1.5px ring; cooldown arcs drawn *around* the token (move = phosphor arc, attack = amber arc, radial progress); own trace only.
- **Others (in LOS):** carrier on team-hue diamond, identity plate beneath, HP band as ring-arc (band fraction + semaphore color), hand glyph at hand point.
- **Statuses, mechanically exact:**
  - Poison: Klaxon-red dashed ring pulsing *on the 24-tick poison cadence* (the pulse is the damage tick).
  - Netted: Etch mesh overlay + small countdown numeral (72 ticks).
  - **Channeling (new — currently invisible):** the 48-tick first-aid channel draws as a segment-by-segment re-energizing arc over the agent; *any* damage snuffs it dark in one frame (wick graft from the diorama pitch). The blowgun's anti-heal identity becomes readable on screen.
  - Camo (self): own token drops to 40% with a `CAMO` tag; `camo_revealed` shows a 120-tick decay arc.
- **Hazards (new — currently absent):** `event_warning` geometry renders instantly as magenta hatch with a `T-0:05` stamp; active flood/firestorm fill with animated magenta/red hatch. No more invisible 4 HP/s.

### 4.4 Layout (replaces the 672px + dead-space layout)

```
┌────────────────────────────────┬──────────────────────┐
│                                │ P3 · TEAM B   ▌lamps▐│  ← identity + 16-lamp row
│                                │ HP ██████░░ 64  HURT │  ← segmented semaphore bar
│                                │ SPD6 STR6 INT4 ATH4  │
│         ARENA CANVAS           │ HAND bow (7)  BODY — │
│   (schematic + energized       │ [1]arrows×9 [2]· ... │
│    bubble + rim compass)       │ RING 15→11 T-0:18 ▶  │  ← magenta arc
│                                │ LAST: ok             │
│                                ├──────────────────────┤
│                                │ TRANSCRIPT (live)    │  ← chat, data face,
│  [banner zone — centered]      │ [P2→team] fall back  │     channel-tagged
└────────────────────────────────┴──────────────────────┘
```

- Canvas scales to viewport (integer zoom, letterboxed on Faraday) — no hardcoded 672px, no dead gutter.
- Banners centered via CSS, stepped in/out, 4s, queued (no overwrites): IGNITION (phosphor), RING (magenta), FINALE — copy: **ALLIANCE TERMINATED** (magenta rule-slam), SETTLED / COLLECTS on death/victory.
- The transcript panel finally earns its space: live chat with channel tags, own-team lines phosphor, broadcast lines bone, DMs amber-tagged. Capped scrollback.
- **Fix first:** the `e.kind` → `e.type` dispatch bug; render `death_fireworks`/`boom`/`event_warning`/`gift_*`; show `damage_dealt` (tiebreak-relevant) and the alive count (lamp row).

### 4.5 Interaction feedback

- Damage taken: 1-frame Klaxon border pulse on the canvas + red tick on the HP bar per `damage_taken` entry (source-tagged in the rail). No screen shake in the panel (instrument), and none under reduced-motion anywhere.
- Action results: `LAST: blocked` stays — it's honest — restyled in the data face with a 1-frame amber blink on state change.
- Own death: the panel powers down — full desaturation to Etch, HP bar zeroes in red, square `SETTLED · 9TH` stamp (stamps land square, never rotated), then seamless hand-off to agent-cam of the killer (broadcast privilege for the dead).

---

## Part 5 — Spectator View ("The Control Room")

Omniscient and cinematic — cinematic like mission control. The green-meadow pass is formally retired.

### 5.1 The frame

Letterboxed in true-black bars (the only pure #000). Full arena on Faraday; all sixteen traces weaving; team hues alive on carrier diamonds; bloom permitted here only. Registration corner marks instead of window chrome. Match clock huge in the data face, top-left, beside the **16-lamp row** — the alive count as light: lit phosphor lamps, a one-frame flare then cold Etch at each settlement. A red LIVE dot when live; a REPLAY tag when playing a recording.

### 5.2 Identity & health on the field (the two critical fixes)

Every agent carries: an **identity plate** beneath the carrier, and an HP-band arc above it (semaphore color + arc length). Hover/selection (observer mouse): bracket reticle + sidebar card (hand, body, kills, damage, projected score — all in the analyst feed; requires the positions-in-feed engine change to correlate, see 5.7).

**The plate carries the player's name, not a slot number** (shipped 0.1.16). Hosted dispatch resolves each seat to a display name in `game_config.players[].name` — `relh`, `sivannn`, `Ryan Schiller`, and `Baseline`, `Baseline (2)` … for filler seats — which the sim parses into `cfg.playerNames`. The renderer folds that name into the 41-glyph face and clips it to **8 characters**, keeping any ` (N)` dedup tail and dropping stem instead (`BASELIN5`, `BASELI12`), because that tail is the only thing separating twelve filler seats. Unnamed or local matches fall back to the themed default table, then to `P<n>`.

**Crowded fallback:** an 8-character plate is 34px — **5.7 tiles** at `TileSize 6` — so plates collide far outside the agents' own footprints. When a plate would overlap a neighbour's, both swap to a **2-character team+parity glyph**: `A1`/`A2` are the two contestants of team A. It is a swap, never a removal: identity must never fall back to team hue alone (Part 8.1). Slot numbers piled up the same way; names only made the pile wide enough to notice.

The test is **geometric** (`platesOverlap`), not a fixed tile radius, and 0.1.18 fixed it after 0.1.17 shipped a 2-tile radius that missed most collisions. Measured on league round 1851 as shipped at 0.1.17: **86% of frames contained at least one overlapping plate pair, 63% of all plates drawn were caught in an overlap**, and the worst frame had 59 overlapping pairs. Both sides of a pair decide from their FULL labels, so the answer never depends on what was rendered — no oscillation, and the pair always agrees.

Consequence worth owning: at 8 characters in a 48-tile arena with 16 agents, roughly two thirds of plates resolve to the short glyph, so the full name is the *exception* rather than the norm. Shortening the truncation budget is the lever if names should show more often — it trades name legibility for name frequency.

**Centering:** plates centre on the carrier's tile (`plateX`). The old fixed −3 offset was tuned for a 3-character `P<n>` and left an 8-character name sitting a tile and a half to the right of the agent it named.

### 5.3 The Settlement system (kill feed + death drama)

- **Settlement Line:** on every death, a 1px Bone-white horizontal line (3px 20% halo) sweeps the full frame width at the dead agent's screen row in ~300ms — part EKG flatline, part ledger rule — leaving a notched chyron in the data face: `SIVANNN 14TH BY RYAN SCH SWORD 2:33`, name struck through. (The word `SETTLED` was dropped from *this* surface at 0.1.16 — the feed is 39 columns in the 5×7 face and a typical line with real names reached 43, losing its timestamp. The settlement voice is unchanged everywhere else; see Part 3.) Same-tick deaths coalesce (stacked lines 2px apart, one shared plate, `MUTUAL` tag in red). Backlog capped at 2s.
- **Kill feed:** last 4 settlement rows persist top-right in the data face; the full ledger lives in the analyst desk and the replay scrubber (16 tick-marks, one per settlement).
- The dead agent's row strikes through *simultaneously* on every client — spectator, analyst, replay timeline. One event, one visual law, everywhere.

### 5.4 The Knowledge Layer (the signature broadcast shot)

Analyst-toggleable overlay rendering every agent's vision disc at 5% additive phosphor. Overlapping fields make *information itself* visible: the audience literally watches what each program knows — who is walking into an ambush, who is blind, whose INT investment is paying. Cumulative additive alpha is capped per tile (Fortress pileups would wash gray otherwise). No other AI-arena broadcast has this shot.

### 5.5 The POV iris (dramatic irony, graft from the broadcast pitch)

When the director cuts to an agent-cam, everything outside that agent's knowledge drops to 15%-luminance grayscale under a 2×2 Bayer dither — the audience watches the camouflaged killer the victim cannot see. One dither pass; the fog-security invariant is untouched (the *broadcast* is omniscient; the iris is presentation).

### 5.6 Computed cinematography (graft from the diorama pitch)

Replays are bit-exact, so the camera directs itself deterministically from the event stream: slow drift at idle, stepped punch-ins on fights (proximity + damage events), the finale framed automatically, winner card held on the last carrier. Live mode uses the same director with a human-override observer (pan/zoom already exist). Every replay of a match directs itself identically — a property no human-driven observer has.

### 5.7 Broadcast data plumbing (small engine changes, large unlocks)

1. **Add agent positions to the analyst feed** (one array) → scoreboard-anchored-to-camera, minimaps, third-party overlays.
2. **Pipe chat into the analyst feed live** (it is public by design; today it reaches only stdout) → the diplomacy layer becomes broadcastable: a transcript panel on the desk, floating team-tagged chat chips optionally over the arena, and the finale betrayal *with its receipts*.
3. **Export `eventHistory`** (currently accumulated and dropped) → timeline, highlight index, heatmaps.
4. **Replay-mode `/watch`** → per-seat fog POV in replays (the "watch it from the victim's eyes" clip).

### 5.8 Replay & analyst desk

- **Scrubber:** full-width timeline strip: ring stages as magenta segments, 16 settlement ticks, amber airdrop diamonds, hazard bands, finale mark. Click-to-seek by replaying differential presentation packets from frame zero, speed steps ×¼–×8, pause.
- **Analyst desk:** becomes the paddock — broadcast palette at instrument density. Adds: minimap (from the positions field), phase + next-shrink countdown in the topbar, per-agent hand column (already in feed, unused), chat transcript pane, and the stat matrix as-is. The WINNER overlay moves to a lower-third so it stops covering the final scoreboard. Heatmaps (position density, death locations) computed from exported event history — the burned-in trace map *is* the heatmap, shown literally.
- **Stream test law:** all of the above is verified on a compressed 1080p60 capture in week one; energized lines thicken to 2px on broadcast output if they shimmer.

---

## Part 6 — HUD & Interface System

One component grammar for all four clients: notched Booth-slate plates on Faraday, corner brackets, 2px rules, data-face numerals, stepped motion, semaphore bands, lamp row. A clip from any client is instantly Zero Sum.

### 6.1 Spectator HUD
Top-left: clock + lamp row + `RING 15→11 · T-0:18`. Top-right: kill feed (last 4). Bottom: softcoin stock-tape ticker in the data face (team chip · balance · last transaction). Banner strip retired in favor of chyrons + full-frame moments (ignition, finale, winner). The COIN truncation bug dies with the old 244px viewport.

### 6.2 Scoreboard (desk + endgame)
Columns: chip+letter · P-glyph+name · HP semaphore bar (arc-fraction) · K · DMG · PLACE · PROJ. Living rows phosphor; settled rows struck through with placement stamped. The final scoreboard is the match's public ledger and gets the full frame *after* the winner card, not under it.

### 6.3 Death recap (player + spectator card)
On settlement: plate with cause of death (source-tagged damage list from `damage_taken`), killer credit, placement, kills, damage dealt, and the agent's trace map thumbnail (their whole match, drawn by the persistence buffer). Shareable by design.

### 6.4 Victory
Runner-up settles (line sweep) → 1s hold → full-frame `ZERO SUM · P5 COLLECTS · 15+2=17` in display caps over the burned-in arena, lamp row with one lamp lit → scoreboard roll in mono → replay CTA. Minimum 12 seconds of ceremony. The match earns it.

### 6.5 Sponsor console (the one interactive surface — currently decision-hostile)
- Map upgraded to the shared schematic renderer: live ring + hatch, teammate positions (data already sent, currently unused), all pods, hazards, and a 4-line legend.
- Targeting: reticle grammar; arrow-key tile stepping + `x,y` input field + Enter to stage; **explicit confirm step** before spending; spiral-snap preview shown as an amber trace from picked tile to actual landing tile *before* purchase.
- Purchase prints a receipt in typed steps: `PO#031 · BLOWGUN · 100 SC · → (32,31) · T-0:05`; balance ticks down in amber; the 60s lockout is a draining magenta arc around the team chip; the shop dims while locked.
- Catalog buttons: notched plates, amber prices, disabled states at ≥4.5:1 contrast. Markers persist server-side (resend pods on connect) so a reload doesn't blind the sponsor.

### 6.6 Menus, lobby, loading
Countdown phase is pre-match pageantry: 16 pedestal lower-thirds rotate through stat allocations as they lock (`P5 · 6/6/4/4 · LOCKED`), lamp row filling as agents connect, mine-stripe pedestals armed. Loading and match-end screens reuse the trace-map + lamp-row motif. Main menu: the logo (ZERO SUM with a decaying trace tail) over a slowly-decaying replay of the previous match's trace map.

### 6.7 Notifications
Every transient banner also lands as a persistent data-face line in the relevant rail/ticker (transient-only notifications fail slow viewers and assistive tech). aria-live="polite" on feed panels; innerHTML rebuilds replaced with row-append DOM updates.

---

## Part 7 — Combat Feedback & Game Feel

Timing is authored in ticks (24/s) — the feel *is* the tick.

| Event | Treatment | Ticks |
|---|---|---|
| Melee swing | Carrier turns to target, weapon glyph arcs, 1-frame Phosphor flash on contact | 2–3 |
| Hit taken | Sprite flashes peak-white 1 frame + 2-tick hit-stop on both parties; floating damage numeral in data face (spectator only) | 3 |
| Bow draw | Amber draw arc filling over the ATH-scaled draw time — dodge windows become visible | draw |
| Projectile | 2 tiles/tick head + 3-tick trail (kept); kind-colored: arrow phosphor, dart red double-line, knife silver; **interpolated sub-tile motion** | flight |
| Dodge (ATH proc) | Ghost-offset afterimage of the carrier at the evaded position | 2 |
| Poison pulse | Red dashed ring pulses on the exact 24-tick damage cadence; victim HP ticks red | 24 loop |
| Net | Etch mesh + countdown numeral; snap-in 2 frames | 72 |
| Heal channel | Segment arc re-energizing over 48 ticks; completion = 1-frame phosphor flash + `+50` stamp; **any damage snuffs it dark instantly** | 48 |
| Eat | Same grammar, amber, 24 ticks, not cancellable — visibly calmer | 24 |
| Camo reveal | Scanline materialization over 4 frames (replaces glitch burst); 120-tick decay arc | 4 |
| Mine (pedestal) | 1-frame white + red cross-flash, Settlement Line — maximum severity, it's the countdown's whole threat | 12 |
| Zone damage | Victim outlined magenta; HP ticks in magenta on the damage cadence; rail border pulses per tick (player) | loop |
| **Death** | (1) peak-white frame → (2) sprite decomposes: pixels scatter into the tile over 8 frames — a process being freed — loot lands as amber items → (3) trace freezes + name etches (burn-in) → (4) Settlement Line + chyron + lamp snuffs + scoreboard strike, all same tick | ~36 total |
| Ignition | Phosphor-white vector starburst over the Fortress + full-frame 1-frame flash; pedestal stripes drop | 48 |
| Finale | Full-width magenta rule slams across every client: `FINALE — ALLIANCE TERMINATED`; the two surviving lamp pairs split apart on the lamp row | until end |
| Victory | Part 6.4 sequence | 12s+ |

Screen shake: spectator only, 1–2px, deaths and mine only, killed by `prefers-reduced-motion`. Interpolation: spectator tweens positions across the tick interval (stepped 3-frame sub-moves, not easing — board pieces become motion without becoming soup); the player panel stays snap-per-tick (instrument honesty), gaining legibility from traces instead. Flicker phases desynchronize (per-object phase offset) so the world stops blinking in lockstep.

---

## Part 8 — Accessibility

1. **Identity is never hue-alone:** identity plates under every carrier, letter+chip pairing in every table, parity pip retained. Team wheel passes a CVD-simulator gate before freeze (CI palette lint).
   - Holds in clusters too (0.1.17): a crowded plate shrinks to the `A1`/`A2` team+parity glyph rather than disappearing (5.2), so a clustered agent is still separable without relying on team hue. 0.1.16 briefly hid the plate outright and did not satisfy this rule.
2. **HP is never hue-alone:** band = color + arc length + (own HP) numeral. Semaphore hues chosen for luminance separation (pale cyan / amber / red) — verified for deutan/protan.
3. **Contrast:** all UI text ≥4.5:1 (`#56606A`/`#4A525A`/`#555` retire to ≥`#8A95A3`); dead-row strikethrough carries state so gray may stay decorative.
4. **Text floors:** 11px minimum web (data face), 24px display floor, UI scale setting ×1.0–×2.0 (layouts are already relative post-redesign; canvases integer-zoom).
5. **Reduced motion:** `prefers-reduced-motion` freezes plasma/hazard animation to a single frame, kills bloom/shake/dither-flicker, keeps state changes as plain swaps. Flicker rates elsewhere capped ≤3/s (current 4/s hazard blink slows).
6. **Keyboard:** full sponsor-console path (arrows + coordinate entry + Enter + confirm); observer camera on WASD/arrows; all buttons focusable with visible phosphor focus rings.
7. **Screen readers:** aria-live feeds for kill/ticker/chat rows (append-only DOM); the lamp row carries an `aria-label` alive count.
8. **Audio as a redundant channel** (Part 9) — every arena-wide warning gets a sound, so magnified/cropped viewports still get told.
9. **Colorblind modes:** beyond the safe-by-default palette, an optional mode swaps team hues for 8 patterned diamond fills (solid/striped/dotted…) — patterns survive anything.
10. **Legend:** `L` toggles an in-client legend overlay naming every glyph, tile, and color contract. New viewers stop reverse-engineering the symbol system.

---

## Part 9 — Audio Direction

Constraint honored: sprite_v1 carries no audio; sound lives in the web clients, synthesized/triggered from the event stream (WebAudio, generative — no asset pipeline, deterministic per seed if driven off tick+event data). Spectator and desk get full mix; player panel gets instrument-minimal; everything optional and ducked.

- **Palette:** instrument room, not battlefield. Substrate: filtered pink-noise room tone + faint 24 Hz-locked pulse (the tick made audible, sub-audible-to-gentle). No literal swords-and-screams.
- **Combat:** dry clicks and thuds with tick-quantized timing; hit = short filtered impulse; crit-band victim adds a low component.
- **Poison:** Geiger-tick on the 24-tick cadence — anti-heal anxiety made audible. Heal channel: rising 48-tick charge tone; snuff = hard cut (the interrupt *hurts* to hear, correctly).
- **Settlement:** the signature sound — a flatline sweep matched to the Settlement Line (300ms), then a soft ledger *thunk* as the chyron stamps. Mutual kills: doubled, detuned.
- **Ring:** each `zone_warning` = calm two-note magenta klaxon; standing outside = damage-cadence ticking in the player mix. Final stage: continuous low shepard drone.
- **Airdrop:** amber chime on purchase (arena-wide), descending printer-feed sound during the beam, soft impact + looping 2s ping until looted; INTERCEPTED = the chime played wrong (minor-second).
- **Finale:** all music cuts for one second, then the rule-slam chord. Silence is the betrayal sting.
- **Music:** generative, intensity keyed to lamps remaining (16 = ambient lattice, 4 = pulse tightens, 2 = almost nothing — the mix empties as the match does). Winner: a single sustained tone resolving, over the scoreboard roll.
- **Casters/VO:** none synthesized; leave narration to humans. Optional tick-accurate event SFX export for highlight editors.

---

## Part 10 — Performance & Techniques

The identity is deliberately cheap — it survives v1 on recolors, vector overlays, and one decay buffer.

- **Phosphor persistence:** one per-tile decay buffer (48×48 floats per viewer class), additive tint on composite. Trivial in both the Nim renderer and canvas. Burn-in = rows pinned at floor alpha.
- **De-rez ring:** three authored tile sprites, chosen per ring stage. No shaders.
- **Bloom:** single additive pass, spectator only, capped emitter list; falls back to off (identity intact without it).
- **Interpolation:** client-side sub-tick stepping between packets; zero protocol change.
- **Dirty disciplines already present, kept:** per-layer offscreen canvases, mip chain, double-buffered HUD sprites, snappy sprite compression.
- **Fixes that are also perf fixes:** `spawnEffect` id collision (allocate effects a reserved non-overlapping id range; also caps the effect pool); DOM clients move from 4 Hz innerHTML rebuilds to append/patch updates; chat/ticker scrollback caps.
- **Fallback modes:** reduced-motion (freeze animations), no-bloom, trace-length dial for broadcast ops, analyst-toggle for the Knowledge Layer (cap cumulative additive alpha), low-spec mode = static frame + overlays only. The player panel is *already* the low-spec mode by design.
- **Budget claim:** nothing here exceeds early-90s compositing math on a 48×48 grid. The renderer's current cost profile is preserved within ~1.5×.

---

## Part 11 — Implementation Roadmap

Scored: Impact (player/viewer value) · Effort · Wow. All Tier-0/1 items are client/render-side unless marked **[engine]**.

### Tier 0 — Bug-fix wins (hours each; do before any art)
| # | Item | Impact | Effort |
|---|---|---|---|
| 0.1 | `e.kind` → `e.type` in player_client (resurrects every banner) | Critical | 1 line |
| 0.2 | Widen COIN HUD viewport 244→~272px; reconcile 3000-vs-300 budget vs spec | High | Trivial |
| 0.3 | Add J/Q to the 3×5 glyph table (interim font) | Med | Trivial |
| 0.4 | `ITEM_GLYPH` `camo`→`camouflage` key fix | Med | 1 line |
| 0.5 | Reserve non-overlapping `spawnEffect` id range | High (broadcast corruption) | Small |
| 0.6 | Center player banner via CSS; retire hardcoded offsets | Med | Trivial |
| 0.7 | Retire stale green-pass evidence JPGs; recapture current build | High (trust) | Trivial |
| 0.8 | Analyst: `id="hpbar"`→class; WINNER overlay to lower-third | Med | Small |

### Tier 1 — Immediate wins (days; transforms readability before the rebrand)
| # | Item | Impact | Wow |
|---|---|---|---|
| 1.1 | Slot glyphs + HP-band arcs on `/global` agents | Critical | ★★★ |
| 1.2 | Kill feed line on `/global` + settlement rows in analyst (data exists) | Critical | ★★★ |
| 1.3 | Ring countdown `15→11 · T-0:18` + dashed target + outside-ring tint (schedule already client-side) | Critical | ★★★ |
| 1.4 | Player client: render `event_warning`/`death_fireworks`/`boom`/`gift_*`; schematic static map underlay; alive count | Critical | ★★ |
| 1.5 | HP semaphore replaces green triad in all web clients (kills green=healthy=poison collision) | High | ★ |
| 1.6 | Landed pods keep contents label; keyed crate sprite | High | ★★ |
| 1.7 | Corpse/loot-pile persistence to match end | High | ★★ |
| 1.8 | Sponsor map: ring + teammates + pods + legend + keyboard + confirm | High | ★★ |
| 1.9 | Contrast bumps + reduced-motion media query + flicker desync | High | ★ |
| 1.10 | Channel + camo-reveal indicators on `/global` (states already streamed) | High | ★★ |

### Tier 2 — The rebrand (1–3 weeks; the identity lands)
| # | Item | Impact | Wow |
|---|---|---|---|
| 2.1 | Palette conversion to AFTERGLOW tokens (render.nim consts + CSS vars) — recolor-first, sprites untouched | High | ★★★ |
| 2.2 | Phosphor trace + burn-in decay buffer (spectator + player-own) | High | ★★★★ |
| 2.3 | Settlement Line + chyron + strike-through system, all clients | High | ★★★★ |
| 2.4 | 16-lamp row, all clients; winner card v1 | High | ★★★ |
| 2.5 | Player panel layout rebuild (Part 4.4), responsive, transcript pane | High | ★★ |
| 2.6 | Ring de-rez tiles + magenta geometry (replaces plasma/lava) | High | ★★★ |
| 2.7 | Airdrop reticle/print sequence + INTERCEPTED callouts | Med | ★★★ |
| 2.8 | Typography stack (Routed Gothic Wide / Plex Sans / JetBrains Mono NL); snap-scaled mono in renderer | Med | ★★ |
| 2.9 | Spectator interpolation + stepped motion + hit-stop/flash combat feedback | High | ★★★ |
| 2.10 | **[engine]** positions in analyst feed; **[engine]** chat→analyst feed | Critical unlocks | ★★★★ |
| 2.11 | Analyst desk rebuild: minimap, phase/next-shrink, hand column, chat pane, heat overlay v1 | High | ★★ |
| 2.12 | WebAudio event-sound v1 (settlement, ring klaxon, drop chime, poison Geiger) | Med | ★★★ |

### Tier 3 — Long-term investments
- **[engine]** `eventHistory` export → replay scrubber with settlement ticks, seek, speed steps; highlight index.
- **[engine]** replay-mode `/watch` → per-seat fog POV replays ("from the victim's eyes" clips).
- Carrier sprite rebuild (retires candy villagers; resolves the §21 humanoid/chassis fork). Ship-gate: confirm no policy author or league content depends on current sprite appearance.
- Bespoke 8×12 bitmap data face; Berkeley Mono license decision.
- Knowledge Layer + POV iris + computed director (the broadcast package).
- Full accessibility pass (patterned team fills, UI scale, aria audit, legend overlay).
- Generative music system; stream-compression verification loop.

### Dream features
- Auto-generated per-match highlight reels (deterministic director + event scoring → rendered clips).
- Season/league branding kit: per-league accent within the token system; sponsor idents on the ticker tape.
- The living Steam page: capsule art generated from real match trace maps — every screenshot is a true story.
- "Autopsy mode": scrub any match with the Knowledge Layer + both fog POVs side-by-side — the definitive study tool for agent authors.

**Ship-path discipline (non-negotiable):** the identity survives v1 on recolors + overlays + the decay buffer. The bitmap font, the carrier sprites, and Berkeley Mono are declared fast-follows; none of them gates a release.

---

## Part 12 — Final Vision

You launch Zero Sum and the menu is already a record: last night's match, sixteen colored threads slowly dimming on a dark instrument board, one thread ending in a lamp that is still lit. ZERO SUM, engraved wide, a trace decaying off the final M.

You queue into a match as a spectator. Letterboxed in true black, the arena resolves: a blue-black machine etched with a faint grid, a chamfered fortress breathing slow amber light at its four mouths, sixteen pedestals striped like armed hardware — because they are. Sixteen lamps ignite one by one across the top of the frame as the programs connect. Lower-thirds tick through stat allocations as they lock. Talk is already flowing down the transcript rail — two teams negotiating a fortress split in public, on the record, forever.

Ignition. A white starburst over the fortress, the pedestal stripes drop, and sixteen carriers surge inward dragging light behind them. The scramble is legible chaos: every agent has a health arc over it, and a name under it wherever the crowd is thin enough to read one, and when the first blood happens *you see it* — a peak-white flash, a two-frame hit-stop, an arc dropping from phosphor to amber. When the first agent dies, the whole frame acknowledges it: their pixels scatter into a loot pile, their trace freezes into the board like a scar, a white line sweeps the screen — *SIVANNN 16TH BY RYAN SCH SWORD 0:41* — a lamp goes cold, and their scoreboard row is struck through everywhere at once.

The ring closes on a broadcast clock. Outside the magenta circle the world visibly de-rezzes — art to wireframe, wireframe to void — and two agents caught out there sprint home through dissolving terrain while the countdown runs. A sponsor buys a blowgun; the arena prints it: an amber reticle stamps a tile in everyone's view — fog or no fog, gold pierces — a hatched beam feeds down, a crate rasters in line by line, pinging, labeled, loud. Three teams converge on it and the ticker is ready to print INTERCEPTED.

Mid-game, the analyst toggles the Knowledge Layer and the broadcast shows something no other game shows: what each program *knows*. A camouflaged hunter sits one tile outside a victim's vision circle, and the director cuts to the victim's POV — the world outside their knowledge dithers to gray, and one hundred thousand viewers watch a death approach that its target cannot see. The poison lands. A Geiger tick starts. The victim channels a heal, the arc re-energizes segment by segment — and a second dart snuffs it dark. The crowd sound the game makes is silence with a pulse in it.

Then there are four. Then two — and they are teammates. The music cuts. A magenta rule slams across every client on Earth: **FINALE — ALLIANCE TERMINATED.** Two lamps left, side by side on the rail, and the transcript above them still shows the promise one made to the other three minutes ago. The last fight happens on a board that remembers everything: fifteen scars, sixteen colored threads, a ring hatched down to nothing. A final white line sweeps. The books balance.

**ZERO SUM · P5 COLLECTS · 15+2=17** — engraved across the full frame, over the burned-in map of everything that happened, one lamp still lit. The ledger rolls: sixteen rows, fifteen struck. Anyone can replay it, bit-exact, from any seat, with every word said. The record is the game, and the game finally looks like it.

---

## Appendix A — Token quick reference

```
/* system */
--zs-faraday:  #0C1116;   /* substrate            */
--zs-etch:     #36444F;   /* structure (ramp 1C242B–4E5E6B) */
--zs-phosphor: #A5E3EE;   /* live signal (peak EAF7FA)      */
--zs-amber:    #FFB454;   /* matter & economy      */
--zs-magenta:  #FF4FA3;   /* commanded geometry    */
--zs-klaxon:   #FF4A36;   /* harm                  */
/* hp semaphore = phosphor / amber / klaxon (no green anywhere) */
/* teams (CVD-gate before freeze) */
--team-a:#FF8FA8; --team-b:#49C7E8; --team-c:#E8C558; --team-d:#9B7BFF;
--team-e:#E85D75; --team-f:#9FB8D8; --team-g:#E8975D; --team-h:#D97BE8;
```

Faces: Routed Gothic Wide (display ≥24px, on a rule) · IBM Plex Sans (body) · JetBrains Mono NL / Berkeley Mono (data, tabular, slashed zero) · renderer: snap-scaled mono → bespoke 8×12 cut.

## Appendix B — Verification gates

1. CVD simulator pass on team wheel + semaphore + magenta/red pairing (CI palette lint).
2. Compressed 1080p60 YouTube/Twitch capture legibility check (week one of Tier 2).
3. Contrast audit ≥4.5:1 on all UI text.
4. `prefers-reduced-motion` walkthrough of a full match.
5. Evidence refresh: every `docs/evidence` capture regenerated from the current build after each tier lands; stale passes deleted.
6. Density stress: 2-alive endgame frame with 15 scars + max loot — trace/scar alpha caps hold.
