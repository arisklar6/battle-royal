# ZERO SUM — Art Upgrade Plan (baked generative art)

**Status:** proposed v1.0 (2026-08-13). Decision document, not a survey.
**Direction:** AFTERGLOW (`docs/VISUAL_REDESIGN.md` is the art bible and wins every conflict).
**Method (decided, not up for re-litigation):** author representational art with Google's
"nano banana" (Gemini image model), quantize it to the AFTERGLOW ramps, and bake it into the
binary as compile-time blobs. **No runtime asset loading, no asset directory in the shipped
image.**

This document decides five things: which sprites get generated art, what resolution the board
runs at, how images become pixels, how pixels become Nim, and in what order it lands.

---

## 0. Ground truth (measured, not quoted)

| Constant | Value | Where |
|---|---|---|
| `TileSize` | **6** | `bitworld/src/bitworld/spriteprotocol.nim:9` — engine-owned, do not touch |
| `ArenaSize` | 48 | `src/zero_sum/types.nim:118` |
| `RS` (today) | 2 | `game/render.nim:21` |
| `TilePxR` / `WorldPxR` (today) | 12 / 576 | derived |
| Wire format | raw **unpremultiplied** 8-bit RGBA, Snappy-compressed, `u16` dims | `docs/PLATFORM_FACTS.md` |
| Colour limit | **none in the protocol** — the "≤15 colours" note in `render.nim:3` is a house convention | `PLATFORM_FACTS.md:18` |
| Substrate | `BgDark = (40,48,57)`, **deliberately not** Faraday `#0C1116` | `render.nim:161` + its 2026-08-03 rationale |
| Client sprite cap | `MaxSpriteDimension = 2048` | `global_client.html:290` |
| Replay reader caps | 64 MiB compressed / 192 MiB inflated | `replay_viewer.js:9-10` |

Three facts drive every decision below:

1. **`addSprite` upscales unless told not to.** `render.nim:243` passes pixels through only when
   `native`, or `isUiSprite(id)`, or `width == WorldPxR`; otherwise it nearest-neighbour doubles.
   **Every baked asset must be registered with `native = true`** or it ships at 2× with 0 extra
   information.
2. **There is no per-object alpha, tint, scale or rotation.** Define-Object carries
   `{id, x, y, z, layer, spriteId}` and nothing else. Fading means swapping to a pre-dimmed
   sprite (`dimmed()`, `FadeStages = 4`). Rotating means authoring N sprites.
3. **80.3% of all in-match wire traffic is the arena background being re-baked 27 times** because
   the ring shrank — not because the texture changed. Any art budget is imaginary until that is
   fixed.

---

## 1. The RS decision

### Decision: **RS = 4.** Tile = 24×24 px. Arena = 1152×1152. Carrier = 32×48.

This is the load-bearing decision in the document, because it decides whether generative art is
worth doing at all.

**At RS=2, generative art loses.** A 12×12 tile is 144 pixels. Every downsample from a 1024px
generation to 12×12 destroys more information than a competent hand-tuned 144-pixel sprite
carries. The existing `plateAt` / `parapetColorAt` / `itemPixels` code is *good* — collider-derived
bevels, three-octave non-tiling noise, a deliberate specular dot — and a mushy 12×12 reduction of
a painting would be a visible regression. Shipping generative art at RS=2 is the single most
likely way to make this project end up worse than today.

**At RS=4 it wins.** 24×24 is a real pixel-art canvas; 32×48 is a real character sprite. That is
where material, volume, chamfer and stencil legibility start to survive reduction.

**Hard rule that follows: no asset with a target dimension under 20 px enters Tier A.**

### Cost, measured

| RS | Tile | Arena | initPacket | 480-tick artifact | Full-match artifact (extrapolated) |
|---|---|---|---|---|---|
| 2 | 12 | 576 | 578,935 B | 2.91 MB | 5.26 MiB |
| 3 | 18 | 864 | 1,200,909 B | 5.81 MB | ~10.5 MiB |
| **4** | **24** | **1152** | **2,048,952 B** | **9.52 MB** | **~17.2 MiB** |

Growth is sub-quadratic (3.54× init for 4× the pixels) because most sprites are 1x art whose runs
lengthen under upscale; Snappy's ratio improves 2.98 → 3.31.

**RS=3 is rejected**, despite being cheaper: odd RS silently truncates every `RS div 2` and
`* RS div 2` expression in the renderer (e.g. `bushPixels` berry spots, `render.nim:766`), and 18 px
is an awkward authoring canvas for 1.5× the linear detail. RS=4 buys 2× linear detail, keeps
`WallBevelPx = 2*RS` and every `div 2` exact, and lands on the industry-standard 24 px tile.

### RS=4 is *gated*, not free

At RS=4 the arena re-bake takes ~72 ms against a 41.7 ms tick, and `initPacket` takes ~60 ms on
the tick thread on every viewer connect. **Phase 0 must land first** (§5). After Phase 0 the arena
is rasterized once per match and `initPacket` is cached, so both spikes disappear — and the
full-match artifact drops well below the pre-Phase-0 extrapolation because the 27 whole-arena
re-sends are gone.

**Gate:** after Phase 0 + the RS flip, measure a full 9120-tick artifact. **If it exceeds 24 MiB**
(the reader cap is 64 MiB; 24 MiB keeps ~2.6× headroom), stop and dirty-tile the trace layer
harder before generating any art. If it still exceeds, fall back to RS=2 and re-scope Tier A to
"carrier + corpse + crates only".

### Code changes RS=4 implies

These are all bugs today — they are art authored against a hardcoded canvas rather than in RS
units. All must land in Phase 1, before generation.

| Site | Problem | Fix |
|---|---|---|
| `bodyPixels` (`render.nim:504`) | buffer is `BodyWR × BodyHR` but every literal (rows 5..17, `x in 8±hw`, visor rows 9..11, diamond rows 18..23) assumes 16×24 | rewrite in RS units — or moot it entirely, since Phase 3 replaces the body with a baked blit |
| `hullHalfWidth` (`:773`) | same 16×24 profile table; shared by `glassBodyPixels`, `glitchPixels`, `hitFlashPixels` | **delete it**; derive all three from the baked body's alpha mask (§4) |
| `CorpseW/H = 24/12` (`:571`) | absolute wire px, not RS-derived; placement offset *is* RS-scaled → decenters by `(CorpseW − TilePxR)/2` at any RS≠2 | `CorpseW = 2*TilePxR`, `CorpseH = TilePxR` |
| `global_client.html:1109` | motion tween gated on `abs(Δ) <= 14`; one tile is `TilePxR` wire px, so at RS=4 (24) **interpolation silently dies** and every agent teleports again | `<= TilePxR + 2`, exported from the server or mirrored as a const |
| `bushPixels` (`:766`) | `spots[i][0] * RS div 2` truncates at odd RS | moot at RS=4; fix anyway |
| `isUiSprite` (`:238`) | `840..861` captures `SpChannelA/B` (850/851), `SpRevealMark` (852) and `SpSettleLine` (860), which are placed on `LayerMap` (`:1525`, `:1535`, `:1731`) → they skip the ×RS upscale. **The "full-frame" settlement rule already covers only the left half of the arena.** At RS=4 the error becomes 4× | make it layer-aware, or move those four ids out of the range |
| 1x-authored board sprites | `plasmaPixels`, `floodPixels`, `stormPixels`, `ringGhostPixels`, `reticlePixels`, `weaponGlyph`, `projPixels`, `traceSpritePixels` all ship as 2×2 (soon 4×4) blocks | re-author natively at `TilePxR` with `native = true` |

The scaling layer itself (`addSprite`/`addObject`/`upscaled`) and **every board placement offset**
are already RS-generic — offsets are authored in 1x tile space and multiplied once in `addObject`.
Nothing there changes.

---

## 2. The sprite tiers

### Tier definitions (the line between A and B)

- **Tier A — generate.** The sprite that ships *is* the generated image, possibly stamped or
  recoloured per variant in code. One image → one (or N recoloured) sprites.
- **Tier B — hybrid.** The generated image is a *material* the renderer samples or transforms
  per-tile / per-pixel / per-frame. There is no 1:1 relationship between an image and a sprite.
- **Tier C — procedural forever.** Analytic geometry, alpha ramps, live text, measurement.

### TIER A — generate

All dimensions are **emitted wire pixels at RS=4**. "Variants" = **number of images to ask the
model for**, not number of sprites emitted.

| Asset | Target px | Images | Emitted sprites | What code still does |
|---|---|---|---|---|
| **Carrier hull** (team-neutral phosphor) | **32 × 48** | **4** (facing S/N/E/W) | 128 (`SpBodyBase 400..557`) | stamps the team-hue diamond, the parity pip, the 2 px bob lift for `frame=1`, and `addBacklight` contact shadow |
| **Corpse wreck** | **48 × 24** | **1** | 16 (`560..575`) | stamps the darkened spilled diamond + parity pixel |
| **Rock cluster 2×2** | **48 × 48** | **3** | composited into `SpBackground` | stamps at seeded cluster origins |
| **Rock cluster 3×2** | **72 × 48** | **3** | composited into `SpBackground` | ditto |
| **Orphan rock tile** | **24 × 24** | **1** | composited | covers clipped/leftover `tkRock` tiles |
| **Pedestal** | **24 × 24** | **2** (armed hazard-stripe / disarmed amber) | composited | picks by `tick < 240`; costs 1 extra background define at t=240 |
| **Bush clump** | **24 × 24** | **1** | 4 (`SpBushBase 90..93`) | stamps 0–3 amber pips — **charges are gameplay state and must stay countable**, so pips are never generated |
| **Item chip body** | **24 × 24** | **1** | — | one amber machined chip, shared by all 12 |
| **Contents stencils** | **24 × 24** | **12** | 12 chips (`51..62`) + 12 crates (`901..912`) | composites stencil over chip *and* over crate — one glyph vocabulary, learned once |
| **Pod crate body** | **24 × 24** | **1** | 12 + 6 print frames | `cratePartPixels` becomes a **row-slice of the baked crate**, which fixes the touchdown pop for free |
| **Weapon glyphs** | **20 × 20** | **6** | 6 (`601..606`) | placed at the hand point ⚠ *marginal — see below* |
| **Burst star** (monochrome, alpha) | **72 × 72** | **1** | 15 (3 tints × 5 stages) | tints to Bone / Amber / Klaxon, scales the mine to 48×48, derives all fade stages via `dimmed()` |
| **Total** | | **36 images** | ~200 sprites | |

**Thirty-six generated images produce roughly two hundred emitted sprites.** That ratio is the
whole economic argument. Do **not** ask the model for 128 carriers or 12 crates: per-image drift
would break the "identity is never hue-alone, but hue is the *only* difference between teammates"
contract, and it would bake 196 KB of const where 12 KB does.

**Honest caveats:**

- **Weapon glyphs at 20×20 sit exactly on the floor of the hard rule.** They are in Tier A because
  they are the worst art in the build today (authored 5×5, block-upscaled, and the blowgun is
  literally green — a direct violation of "no green anywhere") and because sword/spear/bow/knives/
  blowgun/net are six recognizable silhouettes, the model's best case. But **expect the deliverable
  to be hand-traced from the generation, not downsampled from it.** A 20×20 icon with 1–2 px strokes
  is downsample-hostile. Budget a cleanup pass and accept a redraw.
- **Bush pips and crate/chip stencils are composited, never generated into the base.** Both encode
  state (charge count, contents). Generated art that bakes state in is unreadable and unmaintainable.
- **The carrier's bob frame is code, not a second generation.** The 2 px lift guarantees the two
  frames are pixel-identical apart from the lift; two independently generated frames would jitter.

### TIER B — hybrid (AI generates a material, code composites)

| Asset | Generated at | Images | Why it can't be Tier A |
|---|---|---|---|
| **`backgroundPixels` (the compositor itself)** | — | 0 | It is a runtime function of three inputs: the **PRNG-seeded rock layout** (measured 30–44 rock tiles at different coordinates across seeds), the shrinking safe radius, and the de-rez level. It stays a compositor forever. Baking 26 whole-arena variants would cost ~34 MB *and still* couldn't absorb per-seed rocks. |
| **Floor field** | **1152 × 1152** | **1** | The floor is deliberately **non-tiling** — `plateAt` samples noise at *absolute world coordinates*, so no two tiles match. Baking the full arena field is the only way to keep that property with generated material. `plateAt` keeps its per-tile shade hash, panel joints at `PanelPeriodPx`, the +3% inside-ring luminance lift (§3.4, missing today) and the amber-etched Fortress chamber floor (§3.4, missing today) as deltas over the sampled base. |
| **Wall / Fortress roof face** | **384 × 384** seamless | **1** | ⚠ **The most dangerous asset in the plan.** Wall shading is derived from the **collision mask**, not from a texture: `parapetColorAt` raycasts 4 directions to the nearest open pixel and classifies edge → `StoneInk` contact line / lit-or-shadowed bevel / roof seam / face. That is what makes the art match the colliders exactly and read as built volume. **Only the `else: base` branch may be replaced by the sampled material.** A flat AI wall tile pasted per-tile decouples art from colliders and restores the graph-paper look the current code exists to kill. The Fortress stays the same material at `shade(+22)` — a brighter ramp, not a different material (§3.4). |
| **Camo glass / glitch / hit flash** | — | 0 | Derived at bake time from the **baked carrier's alpha mask** (threshold, 1 px dilate for the flash, scanline tear for the glitch). Generating them independently guarantees misregistration — the peak-white hit flash would visibly miss the body it is flashing. This is why `hullHalfWidth` gets deleted rather than rewritten. |
| **Death decomposition** (§7, 8 frames) | — | 0 | Per-pixel dissolution **of the baked body**. Frame 0 must be the body exactly; an image model cannot preserve that continuity. |

### TIER C — procedural forever

| Family | Why |
|---|---|
| **All text**: `textPixels` / `textPixels7`, hud1, hud2, kill feed, banners, slot tags (`800..815`), damage numerals (`880..895`), pod cargo labels (`1000+`) | Runtime strings composed from live data. There is no image to bake. The real upgrade is a **better bitmap font cut** (§3.2 wants JetBrains Mono snap-scaled, then a bespoke 8×12) — a font-rasterizer job. **Nano banana cannot spell**; it produces near-letters that drift per glyph. |
| **`Glyphs` / `Glyphs7` tables** | Same. Rasterize a real font into the existing `0b…` const shape so `textPixels*` needs no change beyond cell metrics. Note: an 8×12 cut at advance 9 makes hud2 398 px wide against a 320 px viewport — widen the viewports in the same change. |
| **`traceSpritePixels` / `stampTrace` / `etchScar`** | The AFTERGLOW thesis made of live match data — agent paths, death tiles, vision radii. Different every match, by definition. |
| **The ring**: `plasmaPixels`, `ringGhostPixels`, the condemned hatch | §3.7 **deletes** the per-tile plasma wall in favour of a 2 px Directive Magenta **analytic circle at the exact float radius**. You cannot raster a circle that must land on a sub-tile float radius. `ringGhostPixels` is a 1 px outline whose only defect is that it is Bone instead of magenta — a two-line fix. |
| **Hazard fields**: `floodPixels`, `stormPixels` | Two-frame **dithered fields** stamped edge-to-edge across up to 400 tiles in a two-parity checkerboard (`(phase+tx+ty) mod 2`). The hash dither exists specifically so overlapping tiles merge into one field instead of showing seams. A generated raster must be seamless against itself in **both parities and both axes** — the model cannot guarantee that, and would reintroduce exactly the lattice this code was written to destroy. |
| **Analytic circles**: `poisonHaloPixels`, `channelHaloPixels`, `pingPixels`, `mouthLightPixels`, `reticlePixels` | AFTERGLOW law 1: *"everything emitted by the simulation is a perfect analytic circle — honest, because those radii are closed-form."* A rastered ring is lumpy and non-concentric and reads as a decorative sticker instead of an instrument readout. The channel halo's target form is a **progress arc keyed to completion fraction** — a data readout, not a picture. |
| **`hpBandPixels`** | Fill *length* and hue both encode the band; the length is protocol-exact measurement. Any painterly treatment destroys it. |
| **`lampRowPixels`** | Composites 16 cells from a 65536-state alive mask. |
| **`settleLinePixels`** | Three rows of Bone at alpha 70/230/70. Its defect is arithmetic (wrong width constant + a UI-range id), not art. |
| **`trailPixels`, `projPixels`** | Both need 4–8 **rotations** (today's trail is always horizontal regardless of heading — `render.nim:1605`). Rotation is one line of math versus eight mutually-consistent hand-prompted images. |
| **`dimmed()` / all 16 fade sprites** | Arithmetic — an alpha multiply. Generating fade frames yields four inconsistent images at 4× the cost. ⚠ `FadeStages` cannot be raised without re-spacing `920/924/928/932`; they are packed exactly `FadeStages` apart and will silently overlap. |
| **`netMeshPixels`** | 24×24 mesh that must overlay the carrier without hiding it — thin high-transparency cords are the first quality a raster reduction loses. §4.3's ask (Etch recolour, countdown numeral, 2-frame snap-in) is entirely code. |
| **`itemColor`** | Not art — a 13-entry lookup table, and **the most consequential item in the whole catalogue**. It is why 12 chips currently look like 12 tints of one shape. Collapsing it to a single amber ramp is the *prerequisite* for Tier A: once hue cannot carry identity, the stencil must. |
| **`voidBeamPixels`, `podChutePixels`** | Both retired by the bible ("the machine prints deliveries, it does not parachute them"). `SpPodChute` is already dead art — defined in every init packet, never placed. **Delete, don't regenerate.** |

---

## 3. The generation strategy

### 3.1 The key colour is pure green

Chroma-key on **`#00FF00`**. This is not arbitrary: AFTERGLOW forbids green anywhere in the
identity (§3.1 law 3), so pure green cannot collide with legitimate art. Anything green in a
generation is either background or a bug — and the baker treats both identically.

### 3.2 Prompt skeleton

Every prompt carries these constraints verbatim:

```
Orthographic front view, straight on, no perspective, no camera tilt.
Single key light from the upper left. No cast shadow (the shadow is drawn separately).
Background: flat pure #00FF00, edge to edge. There must be no other green anywhere.
No text, no letters, no numbers, no logos, no watermark, no signature.
Designed to stay legible when reduced to a {W}x{H} pixel icon: bold silhouette,
large shapes, no fine detail, no thin lines under 1/12 of the sprite width.
The subject will be composited onto a dark slate ground, RGB(40,48,57) — light it for that.

Palette, strictly:
  structure / stone / chassis  -> desaturated blue-grey, #1C242B to #4E5E6B only
  living signal / emission     -> pale cyan phosphor #A5E3EE, highlights to #EAF7FA
  matter, loot, money, energy  -> warm amber #FFB454
  contact shadow / ink line    -> near-black blue #10161C
Nothing warm except the amber. Nothing green. Nothing saturated red unless asked.
```

**Substrate warning, do not skip it:** the shipped board is `BgDark = (40,48,57)`, **not** Faraday
`#0C1116`. The renderer deliberately lifted the substrate on 2026-08-03 because near-black put
every material detail below the perceptual floor. Art lit for `#0C1116` will look flat and
low-contrast on the actual board.

### 3.3 Sheets vs singles

- **Sheet** where cross-variant consistency is the point: the 4 carrier facings (one 1024×1024,
  2×2 grid), the 12 contents stencils (one 1024×1024, 4×3 grid), the 6 weapon glyphs (3×2).
  Asking for all views in one image is what keeps the design coherent across facings.
- **Single** where variants should *differ*: each rock cluster, the pedestal states, the burst.

**Segmentation is manifest-declared and hand-verified — never auto-detected.** The model does not
place subjects on a grid reliably enough to crop automatically, and a mis-crop is silent. Each
sheet gets an entry in `art/sheets.json` listing an explicit crop rect per cell, checked once by
eye against the source PNG.

**The one hard rule on crop rects:**

> `crop.w / target.w == crop.h / target.h == 2^k`, `k ≥ 2`.

That makes every reduction an exact chain of box-halvings. Concretely: 24×24 targets crop 384×384
(16×); 32×48 crops 256×384 (8×); 48×24 crops 384×192 (8×); 72×48 crops 576×384 (8×); 72×72 crops
576×576 (8×); 20×20 crops 320×320 (16×).

### 3.4 The reduction chain (order matters)

1. **Decode** with pixie `readImage` + `subImage`. ⚠ Pixie stores **premultiplied** `ColorRGBX`.
   Convert to straight RGBA immediately. (Lossless here: the source PNG is fully opaque.)
2. **Key.** `a = 0` where `g > 190 && r < 110 && b < 110`. Else `a = 255`.
3. **Despill.** For kept pixels, `g = min(g, max(r, b) + 12)`. Green fringing survives reduction
   and reappears as a halo; kill it before averaging.
4. **Solidify.** Flood the transparent region's RGB from the nearest opaque neighbour. Without
   this, step 5 averages key-colour (or black) into every rim pixel.
5. **Box-minify, alpha-weighted, repeated `k` times.** Per output pixel over its 2×2 source block:
   `a' = mean(a)`, `c' = Σ(c·a) / Σ(a)` (guard `Σa == 0`). **Area, never nearest** —
   nearest-neighbour reduction of a 16× generation is aliased noise. Do this in the baker on
   straight RGBA; do **not** route it through pixie's premultiplied `resize`.
6. **Alpha discipline.** `a < 24 → RGBA(0,0,0,0)` exactly. Then assert the transparent region is
   *bitwise* zero.
   *Why this is not cosmetic:* `dimmed()` scales alpha **proportionally**, so any residual haze in
   the "empty" corners survives every fade stage as a dim floating rectangle over the board — the
   one failure mode `dimmed` cannot rescue. And `addBacklight` uses hard thresholds (`< 40` empty,
   `>= 128` solid), so a soft AA band silently disables the halo. Keep the AA rim ≤ 1 px.
7. **Quantize** to **≤ 16 colours**: median-cut with a fixed traversal order (deterministic — never
   k-means with random init), then **snap each cluster centroid to the nearest entry in the
   declared ramps**, then remap every pixel to its snapped centroid.
8. **Ink pass, in code.** Redraw the 1 px `StoneInk` outline at alpha 190 around the alpha mask,
   exactly as `bodyPixels` does today. Do not trust a model-drawn outline to survive a 16×
   reduction.
9. **Lint** (hard failure, see §6): no colour outside the ramp union; no pixel whose hue falls in
   the green band; alpha histogram has no mass in 1..23.

### 3.5 The ramps (Appendix A, made mechanical)

```
Etch      1C242B 232D36 2A3742 313E4A 36444F 3E4D59 465563 4E5E6B
Phosphor  2A4A52 3E6B76 52909D 6EB4C2 8ACFDC A5E3EE C6EDF4 EAF7FA
Amber     3A2610 5C3D18 8A5B22 B8792E E0953C FFB454 FFC97E FFD9A0
Ink       10161C
Substrate 283039  (BgDark 40,48,57)   — reference only, art is never this colour
Semantic  FF4FA3 (magenta)  FF4A36 (klaxon)  E9E4D8 (bone)  — lines/glyphs only, never fills
Team      FF8FA8 49C7E8 E8C558 9B7BFF E85D75 9FB8D8 E8975D D97BE8 — code-stamped, never generated
```

The Etch / Phosphor / Amber ramps are the **only** legal source for generated pixels. Semantic
colours are reserved for lines and glyphs the code draws (§3.1: *fills vs lines is itself an
information channel*). **Team hue is never generated** — it is stamped by code onto the diamond,
the trace tint and the chip, and nowhere else.

Sixteen colours per sprite is now a load-bearing budget, not a house convention: Snappy achieves
only **2.98:1** on the current flat art, and photographic gradients will drop it to ~2.0–2.2:1.
Quantization is the single highest-leverage post-process on model output. Measured: 5-bit
quantizing the existing background halved its payload (503 KB → 273 KB).

---

## 4. The bake format

### 4.1 Layout

```
art/
  sheets.json          # manifest: source png, crop rects, targets, ramp, symbol name
  source/*.png         # raw nano banana generations — provenance, repo-only
  baked/*.snappy       # binary RGBA blobs, checked in
tools/
  bake_art.nim         # the generator (pixie for decode only; own reduction + quantizer)
game/
  art_baked.nim        # GENERATED — small, reviewable, declarations only
```

### 4.2 `game/art_baked.nim`

Blobs are embedded with **`staticRead`, not escaped literals.** A 1152×1152 floor field is 5.3 MB
raw; as an escaped Nim string that is ~6 MB of source and a miserable compile. `staticRead` is
already the established pattern in this repo (`game/server.nim:14-20` embeds all three clients).

```nim
## GENERATED FILE — do not edit. Regenerate: nim c -r tools/bake_art.nim
## Baked for RS=4 (TilePxR=24). Changing RS requires a re-bake.
import supersnappy

const BakeRS* = 4
const BakeTilePx* = 24

type BakedSprite* = object
  w*, h*: int
  px*: seq[uint8]        # straight, unpremultiplied RGBA
  mask*: seq[uint8]      # precomputed 0/255 alpha mask

proc rgbAt*(b: BakedSprite, x, y: int): (uint8, uint8, uint8) {.inline.} = ...

let CarrierPose*   : array[4, BakedSprite] = load4("carrier")
let CorpseWreck*   : BakedSprite           = load1("corpse")
let FloorField*    : BakedSprite           = load1("floor")     # 1152x1152
let WallFace*      : BakedSprite           = load1("wallface")  # 384x384 seamless
let RockCluster22* : array[3, BakedSprite]
let RockCluster32* : array[3, BakedSprite]
let RockOrphan*    : BakedSprite
let Pedestal*      : array[2, BakedSprite]
let BushClump*     : BakedSprite
let ChipBody*      : BakedSprite
let CrateBody*     : BakedSprite
let Stencil*       : array[13, BakedSprite]   # indexed by ord(ItemId)
let WeaponIcon*    : array[13, BakedSprite]
let BurstStar*     : BakedSprite              # monochrome + alpha, tinted in code
```

`art_baked.nim` stays **dependency-free** (indexes by `int`, never imports `zero_sum/items`), so it
can never create an import cycle with `render.nim`. Decompression happens once at module init
(~7 MB, a few ms).

### 4.3 How `render.nim` consumes it — signatures unchanged

This is the constraint that keeps the diff reviewable. Every proc keeps its exact signature; only
the body changes, and at every call site nothing changes at all.

```nim
proc plateAt(px: var seq[uint8], w, ox, oy, tx, ty: int) =
  for y in 0 ..< TilePxR:
    for x in 0 ..< TilePxR:
      let wx = ox + x
      let wy = oy + y
      let base = FloorField.rgbAt(wx, wy)        # was: BgDark
      var d = <panel joints, per-tile etch grid, fleck/pinhole — unchanged>
      if inSafeRing: d += 3                      # §3.4, new
      px.put(w, wx, wy, shade(base, clamp(d, FloorLo, FloorHi)))
```

```nim
proc parapetColorAt(a: Arena, wx, wy: int, base): (uint8, uint8, uint8) =
  <4-ray openDistDir edge classification — UNCHANGED>
  if edge <= 1: StoneInk
  elif edge <= WallBevelPx:
    if min(up, lf) <= min(dn, rt): shade(WallFace.rgbAt(wx, wy), 40)
    else:                          shade(WallFace.rgbAt(wx, wy), -26)
  elif (wx + wy) mod RoofSeamPeriod == 0: shade(WallFace.rgbAt(wx, wy), -12)
  else: WallFace.rgbAt(wx, wy)                   # was: base
```

```nim
proc bodyPixels(team, parity, facing, frame: int): seq[uint8] =
  result = newSeq[uint8](BodyWR * BodyHR * 4)
  result.blit(BodyWR, CarrierPose[facing], dy = (if frame == 1: -(RS div 2) else: 0))
  result.stampDiamond(BodyWR, TeamColors[team])   # team hue: fills only
  if parity == 1: result.stampPip(BodyWR)
  result.addBacklight(BodyWR, BodyHR, StoneInk, 95, dx = RS, dy = RS)
```

Same for `rockAt`, `pedestalAt`, `bushPixels`, `itemPixels`, `podCratePixels`, `corpsePixels`,
`weaponGlyph`, `burstPixels`. `cratePartPixels(n)` becomes a row-slice of `CrateBody`.
`glassBodyPixels` / `glitchPixels` / `hitFlashPixels` are generated by the *baker* from
`CarrierPose[0].mask` and shipped as baked sprites too — which is strictly better than today,
because after the art swap they follow the new outline by construction.

### 4.4 Re-runnability and Docker

- `nim c -r tools/bake_art.nim` rewrites `art/baked/*.snappy` + `game/art_baked.nim`.
  Deterministic by construction (fixed-order median cut, no RNG, no timestamps).
- CI: re-run the baker and `git diff --exit-code art/baked game/art_baked.nim`.
- Dockerfile: add `COPY art/baked ./art/baked` to the **build stage only**. The runtime stage
  copies only `/out/zero_sum_server`, so **no asset directory ships in the image** — the constraint
  holds exactly. `art/source/` never enters Docker at all (add it to `.dockerignore`).
- **Doc debt:** `DESIGN.md §21.1` and the `render.nim:1-4` header both say "all art stays
  code-generated pixel data (no external asset pipeline)". Baking honours the *intent* (nothing
  loads at runtime, nothing ships beside the binary) but contradicts the letter. **Amend both in
  the same commit that lands `art_baked.nim`** — do not leave the codebase asserting something
  false about itself.

---

## 5. Ordering

Each phase is independently verifiable **by looking at one rendered frame**. Nothing generative
happens until Phase 3.

### Phase 0 — Wire and geometry hygiene. No art. *(prerequisite for everything)*

*Verify:* the frame looks identical, three currently-half-size sprites become full size, and
in-match traffic drops ~80%.

1. Fix `isUiSprite` → the settlement rule becomes full-width (it is the flagship death beat and it
   is currently half-drawn), the channel halo and reveal mark become full size.
2. **Fix the sprite-id collision.** `SpBushBase = 90..93` and `SpProjBase + ord(iArrows|iDarts)` =
   **91, 92**. Both are defined in the same `spriteDefs` packet, bushes first; the client's
   `Map.set` means last-define wins, so **two of the three possible bush charge states currently
   render as an 8×8 projectile blob.** Move `SpProjBase` to 960.
3. Delete dead art: `SpPodChute` (defined every init packet, never placed), `SpPodCrate = 35`,
   `SpCargoBase = 710`.
4. Give hud1/hud2 separate flip counters (`r.hudFlip` is shared; when both change on one tick the
   parity fails to advance and hud1 redefines the sprite its own object is bound to).
5. **Arena: define once.** Replace the 27 whole-arena re-bakes with three de-rez tile sprites and
   pooled per-tile overlay objects — which is what §3.7 literally specifies ("Three extra tile
   sprites, zero shaders"). This is 80.3% of all in-match traffic and both CPU spikes.
6. **Cache `initPacket`.** It is deterministic per arena and currently re-runs the whole rasterizer
   plus 254 Snappy compressions on the tick thread for *every* viewer connect (16.8 ms at RS=2).
7. Dirty-tile the trace layer (split into an 8×8 grid, re-define only changed cells).
8. **Fix `game/poster.nim`.** It composites a `WorldPxR²` background against a `WorldPx²` overlay
   using `WorldPx` as the stride for both — the output is the top 144 arena rows smeared across a
   288-wide frame. It has been wrong since RS was raised to 2. **This is the review harness; it
   must work before any art lands or it will give confidently wrong feedback.**
9. Add `tools/spritesheet.nim`: dump every defined sprite to one contact-sheet PNG at 1× and 4×.
10. Add the missing test. `tests/t_presentation_replay.nim` is the *only* test that imports
    `render.nim` and it asserts nothing about pixels, sprite count, dimensions or bytes. Add: a
    hash of the init-packet sprite blob, and `assert artifact_bytes < N`.

### Phase 1 — RS = 4

*Verify:* the same frame at 2× linear resolution, motion interpolation still working.
All of §1's table. Then measure a full 9120-tick artifact against the 24 MiB gate.

### Phase 2 — Palette conversion. Still no generated art. *(highest impact-per-effort in the plan)*

*Verify:* no green anywhere on screen; all loot amber; the ring magenta.

This **must** precede generation, because baked art freezes whatever palette it was generated in.

- `itemColor` → one amber ramp. It is read by `itemPixels`, `projPixels` and `podCratePixels`, so
  one edit fixes chips, projectiles and crate bands together. Kills three greens (blowgun
  `(120,160,110)`, camouflage `(90,120,70)`, darts `(140,200,140)`) and the first-aid red that
  collides with Klaxon.
- Crate wood `(150,105,55)` → chamfered amber. Firestorm `(255,90,30)` → a real token.
  `ringGhostPixels` Bone → Directive Magenta. Blowgun weapon glyph green → phosphor.
- Bushes: leaf `(46,108,50)` → Etch-dark, berries `(215,45,60)` → amber pips. **This is the most
  clear-cut art-bible violation in the codebase** (§3.1: *"There is no green anywhere in the
  identity — nothing in this game means go"*).
- Fix `ITEM_GLYPH`'s dead sibling `WEAPON_GLYPH.camo` → `camouflage` in `player_client.html:117`.

### Phase 3 — Tier A pilot: the carrier + corpse *(5 images)*

*Verify:* one frame with sixteen agents. Do all eight team hues still separate? Do all four
facings read at 1:1 without zooming?

The carrier is the pilot deliberately: it is self-contained, alpha-keyed, the object the eye
tracks all match, and 62% of the entire agent sprite count collapses into 4 images. It proves the
whole pipeline end-to-end (key → reduce → quantize → ink → bake → blit → recolour) on the asset
where failure is most obvious and least expensive to revert.

### Phase 4 — Tier B: terrain *(6 images: floor, wall face, 7 rock pieces, 2 pedestals, 1 bush)*

*Verify:* the poster. Largest surface area in the game, and the hardest not to break — hence
*after* the pipeline is proven. Land the floor first, alone, and look at it before touching walls.

### Phase 5 — Tier A: economy *(20 images: chip, crate, 12 stencils, 6 weapon glyphs)*

*Verify:* a frame with ground loot + a landed pod. Can you name the item without a label?

This is where the Phase-2 palette conversion pays off: with hue no longer available as an identity
channel, the stencil has to carry it — and the same glyph vocabulary appears on chips and crates,
so it is learned once. Also fixes the anonymous-crate problem (critique #13).

### Phase 6 — Tier A: bursts + the death sequence *(1 image)*

*Verify:* a death. The burst is the largest transient canvas and fires on the pivotal beats.
Pair with the §7 death sequence (peak-white frame → 8-frame decomposition → trace freeze + glyph
etch → settlement line), which is all code derived from the baked body.

### Deferred (explicitly out of scope for v1)

- **Bitmap font cut** (§3.2). High value, entirely independent of this plan, and a font-rasterizer
  job — not image generation. Do it as its own project.
- **HUD chrome plates.** Genuine Tier A work (240×52 notched Booth-slate backplates, corner
  brackets, lamp bezel), but §6.1 restructures the whole HUD. Generating chrome for a layout that
  is about to change is waste. Blocked on: lifting the `BgDark`@220 plate out of `textPixels*`
  into separate static sprites first — hud1 redefines once per second and would otherwise
  re-transmit the texture at 1 Hz.

---

## 6. Risks and guards

| # | Risk | Guard |
|---|---|---|
| 1 | **Snappy ratio collapse.** Measured 2.98:1 today on flat art; photographic gradients drop it to ~2.0–2.2:1. With 5 pre-dimmed copies of every ramped effect, that compounds. | Hard quantization to ≤16 ramp colours (§3.4 step 7) + CI byte-budget assertions: init packet ≤ 3.0 MB, 480-tick fixture ≤ 4.0 MB, full match ≤ 24 MiB. |
| 2 | **Soft alpha haze.** Model output leaves a grey halo; `dimmed()` scales it into every fade stage as a floating rectangle, and `addBacklight`'s hard `<40`/`>=128` thresholds silently stop working. | §3.4 step 6: `a < 24 → bitwise zero`; baker asserts the alpha histogram has no mass in 1..23 and that the transparent region is exactly `(0,0,0,0)`. |
| 3 | **Silhouette drift.** Camo glass, glitch and hit flash trace `hullHalfWidth`; if the generated hull differs by a pixel the peak-white flash visibly misses the body. | Delete `hullHalfWidth`. Generate all three **from the baked body's alpha mask in the baker**. Test: the flash mask equals the body mask dilated by 1. |
| 4 | **Art decoupled from colliders.** A flat AI wall tile pasted per-tile kills the built-volume read and restores the graph-paper look. | `parapetColorAt` keeps its 4-ray edge classification; the material feeds **only** the `else: base` branch. Verify by toggling one arena tile and confirming the bevel follows. |
| 5 | **Mud at play size.** 24×24 is still small; a reduced painting turns to porridge. | Review every asset in `poster` and `spritesheet` at **1:1, unzoomed**, before acceptance. Reject criterion: *can I tell what it is at 1:1?* Hard rule: nothing under 20 px target enters Tier A. |
| 6 | **Palette violations baked in permanently.** | CI palette lint over `art/baked/*`: fail on any colour outside the ramp union; fail on any pixel in the green hue band. This is Appendix B gate 1 made mechanical. |
| 7 | **RS=4 blows the tick budget or the artifact cap.** | Phase 0 lands first (removes both spikes); Phase 1 measures a full match against a stated 24 MiB gate with a stated fallback (tile the trace harder, then RS=2 + re-scoped Tier A). |
| 8 | **Losing the semantic channel.** Detailed art that puts team hue or semantic colour into fills destroys "fills vs lines is a channel" and "only the living carry colour". | Generated art is **team-neutral and semantic-neutral**: Etch / Phosphor / Amber ramps only. Team hue and every semantic colour are stamped by code. |
| 9 | **Implied 3D lighting fights the one-key rule.** | Prompt mandates orthographic + single upper-left key + no cast shadow; reject any generation with a disagreeing shadow direction. The contact shadow stays `addBacklight`'s job. |
| 10 | **The model cannot spell.** | No generated asset may contain lettering. Stencils are abstract marks, hand-checked. All text stays Tier C. |
| 11 | **Non-determinism creeping into a bit-exact game.** | Baked art is `const` — it cannot reach the sim. But the *baker* must be deterministic: fixed-order median cut, no RNG, no timestamps; CI re-runs it and diffs. |
| 12 | **Regenerating art becomes impossible.** The floor field is baked at a specific RS. | `art_baked.nim` carries `BakeRS`/`BakeTilePx` consts; `render.nim` static-asserts `BakeRS == RS` so an RS change fails the build instead of shipping a scaled-wrong floor. |
| 13 | **No test can see a visual regression.** One test imports `render.nim` and it asserts nothing about pixels. | Phase 0 item 10 ships before any art. |

---

## 7. Summary of decisions

- **RS = 4** (24 px tile, 1152 px arena, 32×48 carrier), gated on Phase 0 and a measured 24 MiB
  full-match artifact. This is the decision that makes generative art worth doing; at RS=2 it
  would make the game look *worse*.
- **36 generated images → ~200 emitted sprites.** Never generate a variant that code can stamp.
- **Tier A** = carrier, corpse, rocks, pedestals, bush, chip + 12 stencils, crate, weapon glyphs,
  burst. **Tier B** = floor field, wall face, and the three body-derived overlays. **Tier C** =
  everything analytic, measured, tiled, or made of live text.
- **Green `#00FF00` is the chroma key**, because AFTERGLOW forbids green — so it can never collide.
- **Bake via `staticRead` of Snappy blobs**, not escaped literals. Proc signatures unchanged;
  call sites untouched.
- **Palette conversion (Phase 2) ships before any generation**, because baked art freezes its
  palette.
- **Fix the wire before spending it.** 80.3% of match traffic is a background being re-sent because
  the ring shrank.

---

## Local iteration loop

Verified on macOS arm64, Nim 2.2.10, 2026-08-13. Every command runs from the repo
root. No Docker, no websocket, no browser on the fast path.

### 0. One-time: sync pinned deps

```bash
nimble install -y nimby          # if nimby is not already on PATH
nimby sync nimby.lock            # checks out bitworld + 27 deps at their pins
```

`nim.cfg` is generated by nimby and carries the `--path:` for every dep. The
dep checkouts are gitignored at the repo root, so a fresh clone needs this once.

### 1. Baseline build (the Dockerfile's command, natively)

```bash
nim c -d:release --hints:off --warnings:off -o:/tmp/zs-out/zero_sum_server game/server.nim
nim c -d:release --hints:off --warnings:off -o:/tmp/zs-out/zero_sum_baseline player/baseline.nim
```

Cold ~30 s, warm ~1.3 s (Nim caches in `~/.cache/nim/`). Never `-o:` into the
repo — `bin/` and `dist/` are gitignored but `/tmp/zs-out` keeps the tree clean.

### 2. The fast loop — `tools/frame_dump.nim` **(use this one)**

The whole point of an art change is seeing it. `frame_dump` runs a headless
episode through the **real** renderer, decodes the `sprite_v1` packets it emits
with `parseSpritePacket`, composites them exactly as the browser viewer does
(painter's algorithm, ascending `z`, ties by object id, unpremultiplied
source-over), and writes one PNG.

It is deliberately a *consumer of the packet stream*, not a second renderer:
whatever you change in `game/render.nim` shows up here, and a malformed packet
looks broken here in the same way it would look broken in the viewer.

```bash
nim c -d:release --hints:off --warnings:off --path:game \
  -o:/tmp/zs-out/frame_dump tools/frame_dump.nim

# frame_dump [seed] [ticks] [outPath] [scale]
/tmp/zs-out/frame_dump 42 400  /tmp/zs-out/frame_t400.png  2
```

**Note the `--path:game`** — `render.nim` and `demo_script.nim` live in `game/`,
which is not on the default path.

Measured: **0.36 s** wall from launch to PNG at tick 400. That is the loop —
edit `render.nim`, rebuild, dump, look.

Useful tick marks along the match arc (seed 42, match ends t=7632):

| ticks | phase | what it shows |
|---|---|---|
| `20` | countdown (15 alive) | **best frame for terrain + carrier art**: untouched board, all carriers on their pedestals, plus P3 mid-mine-explosion (the demo script steps it off at t=10) |
| `400` | live (15 alive) | full board in motion: Fortress, rocks, bushes, crates, chips, HP bands, slot labels |
| `1200` | live (15 alive) | ring biting into the corners, first reclaimed territory |
| `3000` | live (15 alive) | ring well closed, reclaimed wash + derez on the outside |
| `7000` | live (5 alive) | late game: heavy derez, corpses, few survivors |

Output is the map layer at whatever viewport the packet announces, upscaled by
`scale`. The tool reads the viewport from the stream rather than assuming it, so
it keeps working through the RS change: `576×576` today at RS=2, `1152×1152`
after Phase 1 at RS=4 (`WorldPx 288 × RS`). Drop `scale` to 1 once RS=4 lands —
1152 px is already a comfortable review size.

HUD layers are UI-space overlays and are not composited; board art is what this
tool is for.

### 3. Baseline test suite

```bash
# sim tests — the CI `tests` job
for t in tests/t_*.nim; do echo "=== $t"; nim c -r --hints:off "$t"; done

# JS tests — the CI `cockpit` job
node tests/t_cockpit_prompt.js
node tests/t_replay_viewer.js

# compile-check every top-level program — the CI `check` job
for f in game/server.nim game/headless.nim game/analyst.nim \
         game/render.nim game/poster.nim player/baseline.nim; do
  echo "=== $f"; nim check --hints:off "$f"
done

# determinism — the CI `determinism` job
nim c --hints:off -o:/tmp/zs-out/headless game/headless.nim
for seed in 7 42 1234; do
  /tmp/zs-out/headless "$seed" 2000 && mv results/hashes.txt "run1_$seed.txt"
  /tmp/zs-out/headless "$seed" 2000 && mv results/hashes.txt "run2_$seed.txt"
  diff "run1_$seed.txt" "run2_$seed.txt" && echo "seed $seed deterministic"
done
```

Art changes cannot move sim hashes — `render.nim` never touches the sim. If
`t_golden` moves after an art commit, something reached the simulation and the
commit is wrong.

### 4. Full-fidelity check (browser, still no Docker)

For HUD layers, animation, and the actual viewer code path:

```bash
ZERO_SUM_LOCAL=1 /tmp/zs-out/zero_sum_server --port 8080
# then open http://localhost:8080/global
```

The server is frame-limited to `TargetFps = 24`, so a full 7632-tick match is
**~5 minutes of wall clock**. Fine as a pre-commit check, far too slow to
iterate on. It writes `results/replay.replay` on exit; that artifact plays in
the static bundle built by `tools/build_replay_viewer.sh`:

```bash
tools/build_replay_viewer.sh "$PWD/dist/build/static-replay-viewer"
```

### 5. `game/poster.nim` is broken — do not iterate on it

`poster.nim` composes `backgroundPixels()` (which returns a **`WorldPxR ×
WorldPxR`** buffer, 576×576 at RS=2) into a **`WorldPx × WorldPx`** buffer
(288×288):

```nim
let bg = backgroundPixels(s.arena, s.effectiveSafeRadius(), s.derezLevel())
var composed = newSeq[uint8](WorldPx * WorldPx * 4)     # <-- 288², bg is 576²
for i in 0 ..< WorldPx * WorldPx:
```

Each output row consumes half a source row, and only the top quarter of the
board is ever read, so the poster renders a garbled top-left slice with no
Fortress and no border. It also only draws background + trace overlay — no
carriers, items, or hazards — so it could not review sprite art even if the
dimensions were right.

It still `nim check`s clean and CI never renders it, which is why the drift went
unnoticed. **Phase 0 should either fix it (`WorldPxR` throughout, and compose
`traceSpritePixels`' 1x output upscaled) or delete it.** Going to RS=4 widens
the mismatch from 2× to 4×; leaving it is a trap for whoever opens it next.

### Summary — the three commands that matter

```bash
nimby sync nimby.lock
nim c -d:release --hints:off --warnings:off --path:game -o:/tmp/zs-out/frame_dump tools/frame_dump.nim
/tmp/zs-out/frame_dump 42 400 /tmp/zs-out/frame.png 2
```
