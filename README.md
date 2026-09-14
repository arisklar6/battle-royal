# Zero Sum

A battle-royale Coworld: 8 teams of 2 — 16 contestants, one policy container per agent — spawn empty-handed on a pedestal ring around a loot-stocked central Fortress. Countdown, ignition fireworks, then a scramble: the best gear sits in the most dangerous place. A shrinking safe zone and scripted hazards force the fight; sponsors spend softcoin to airdrop supplies to their own team; the last contestant standing wins. Every death is a black firework.

Built in Nim on the [bitworld](https://github.com/Metta-AI/bitworld) engine library (see NOTICE), packaged and certified as a Coworld for the [coworld](https://github.com/Metta-AI/coworld) platform.

- `DESIGN.md` — the complete v1 design: arena, items, combat, stats, zone, sponsor economy, protocols, scoring, artifacts, determinism.
- `docs/PLATFORM_FACTS.md` — file:line evidence base for every engine/platform contract claim.
- `docs/recon/` — Phase A reconnaissance reports.
- `src/zero_sum/` — deterministic sim.
- `game/` — Coworld runnable adapter and shared live/static presentation.
- `player/` — baseline player.
- `tests/` — determinism, stat validation, scoring, softcoin accounting.

Match: 24 Hz, hard cap 9,120 ticks (6:20). Protocol: `zero_sum.player.v1` (JSON over WS). Live and static replay presentation: sprite_v1.

> **CAUTION:** This repository contains both the shipping Zero Sum branch and a
> held rewrite on `master`.

`release/zero-sum-0.1.x` is the shipping branch for Zero Sum. `master` is the
held Battle Royal/FFA rewrite and is not the release line for Zero Sum.

## League profiles

`python tools/gen_manifest.py` generates one publishable `zero-sum` manifest
with Solo `competition` first and a self-paired Duos variant second:

- The `competition` variant is Solo: each
  external seat owns one contestant and receives that contestant's score.
- The `duos` variant is self-paired: use platform `team_n` seating with
  `team_count: 8`; external
  seats `i` and `i+8` are remapped onto the adjacent internal team
  `(2i, 2i+1)`, and both seats receive that team's combined score. The
  platform's per-policy mean therefore equals the requested team total.

Status: Phase C (implementation) in progress.
