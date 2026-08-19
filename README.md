# Battle Royal

A battle-royale Coworld: 8 teams of 2 — 16 contestants, one policy container per agent — spawn empty-handed on a pedestal ring around a loot-stocked central Fortress. Countdown, ignition fireworks, then a scramble: the best gear sits in the most dangerous place. A shrinking safe zone and scripted hazards force the fight; sponsors spend softcoin to airdrop supplies to their own team; the last contestant standing wins. Every death is a black firework.

Built in Nim on the [bitworld](https://github.com/Metta-AI/bitworld) engine library (see NOTICE), packaged and certified as a Coworld for the [coworld](https://github.com/Metta-AI/coworld) platform.

- `DESIGN.md` — the complete v1 design: arena, items, combat, stats, zone, sponsor economy, protocols, scoring, artifacts, determinism.
- `docs/PLATFORM_FACTS.md` — file:line evidence base for every engine/platform contract claim.
- `docs/recon/` — Phase A reconnaissance reports.
- `src/battle_royal/` — deterministic sim.
- `game/` — Coworld runnable adapter and shared live/static presentation.
- `player/` — baseline player.
- `tests/` — determinism, stat validation, scoring, softcoin accounting.

Match: 24 Hz, hard cap 9,120 ticks (6:20). Protocol: `battle_royal.player.v1` (JSON over WS). Live and static replay presentation: sprite_v1.

> [!CAUTION]
> **Do not upload until the platform-side rename is confirmed.** The manifest
> templates now carry `game.name` `battle-royal` / `battle-royal-duos`, but the
> published Coworld is still registered under `zero-sum`.
>
> **`game.name` is the upload-time ownership key: the first authenticated upload
> of a name claims that name** (`docs/PLATFORM_FACTS.md`, "the first
> authenticated upload of a `game.name` claims name ownership"). Running
> `coworld build` + `upload-coworld` against these templates today would not
> rename anything — it would mint a **brand-new Coworld with zero version
> history**, stranding the `0.1.9 → 0.1.18` chain and its league behind the old
> name. The Progress / counterfactual-evals comparison needs a name that has
> already played, so a fresh name silently produces no comparison at all.
>
> An in-place rename of the Coworld rows and the league has been requested from
> the platform team and is **not yet confirmed**. Until it is:
>
> - **Hold all uploads.**
> - If something must ship urgently, build with `game.name` temporarily reverted
>   to `zero-sum` / `zero-sum-duos` — ship under the old name and rename later.
> - Delete this block once the platform confirms the rename.
>
> Also wire-visible at the next canonical upload: the protocol id is now
> `battle_royal.player.v1` (was `zero_sum.player.v1`) and the replay magic is
> `BATTLE_ROYAL_FRAMES` (legacy `ZERO_SUM_FRAMES` still parses). Third-party
> policies pinning the old protocol string will break — say so in the upload
> announcement.

## League profiles

`python tools/gen_manifest.py` generates two publishable templates from the
same game image:

- `coworld_manifest_template.json` (`battle-royal`) is the Solo profile. Each
  external seat owns one contestant and receives that contestant's score.
- `coworld_manifest_duos_template.json` (`battle-royal-duos`) is the self-paired
  Duos profile. Use platform `team_n` seating with `team_count: 8`; external
  seats `i` and `i+8` are remapped onto the adjacent internal team
  `(2i, 2i+1)`, and both seats receive that team's combined score. The
  platform's per-policy mean therefore equals the requested team total.

The two names are separate because a Coworld league seed is unique by Coworld
name. Build the Duos package with explicit paths so it does not overwrite the
Solo artifact:

```bash
uv run coworld build --project . --version <version> \
  --template coworld_manifest_duos_template.json \
  --output dist/duos/coworld_manifest.json
```

Status: Phase C (implementation) in progress.
