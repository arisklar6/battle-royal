# Zero Sum

A battle-royale Coworld: 8 teams of 2 — 16 contestants, one policy container per agent — spawn empty-handed on a pedestal ring around a loot-stocked central Fortress. Countdown, ignition fireworks, then a scramble: the best gear sits in the most dangerous place. A shrinking safe zone and scripted hazards force the fight; sponsors spend softcoin to airdrop supplies to their own team; the last contestant standing wins. Every death is a black firework.

Built in Nim on the [bitworld](https://github.com/Metta-AI/bitworld) engine library (see NOTICE), packaged and certified as a Coworld for the [coworld](https://github.com/Metta-AI/coworld) platform.

- `DESIGN.md` — the complete v1 design: arena, items, combat, stats, zone, sponsor economy, protocols, scoring, artifacts, determinism.
- `docs/PLATFORM_FACTS.md` — file:line evidence base for every engine/platform contract claim.
- `docs/recon/` — Phase A reconnaissance reports.
- `src/zero_sum/` — deterministic sim.
- `game/` — coworld runnable adapter (server, clients, replay).
- `player/` — baseline player.
- `tests/` — determinism, stat validation, scoring, softcoin accounting.

Match: 24 Hz, hard cap 9,120 ticks (6:20). Protocol: `zero_sum.player.v1` (JSON over WS). Spectator/replay: sprite_v1.

Status: Phase C (implementation) in progress.
