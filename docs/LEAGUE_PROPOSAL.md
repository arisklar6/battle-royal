# League proposal: Zero Sum

Request to the Softmax team to promote the published coworld **zero-sum**
into an Observatory league. League-seed creation is currently staff-only
(`POST /api/observatory/v2/coworld-league-seeds` returns 403 for player
accounts), so this document is the concrete spec we are asking to be seeded.

## The coworld

| Field | Value |
|---|---|
| Coworld ID | `cow_b9a252c4-cdbb-4c8c-b2ef-2ee70458d684` |
| Name / version | `zero-sum:0.1.2` (canonical) |
| Owner | arisklar6@gmail.com |
| Source | https://github.com/arisklar6/zero-sum (MIT, bitworld engine, NOTICE included) |
| Certification | 10/10 steps, hosted smoke 5/5 |
| Determinism | Full: sim is a pure function of (seed, input log); replays are hash-verified re-simulations (11k-input live match replayed bit-exact) |

## What a league match is

16 agents (8 teams of 2) in a battle-royale on a 48x48 arena: shrinking
7-stage zone (~5-minute close), fortress loot scramble, sponsor airdrops,
public chat diplomacy, and a forced finale — when one team remains, the
teammates fight. Exactly one winner every match, no draws, hard cap t=9120.

- **Scoring** (league-ready, zero-sum by construction):
  `score = placement points + kills`, placement points
  15/12/10/8/7/6/5/4/3/3/2/2/1/1/0/0 by reverse death order, +1 per kill.
- **Sponsor fairness**: in league config every team receives an identical
  scripted sponsor schedule (budget 300); sponsor spending never affects score.
- **Anti-collusion pressure**: friendly fire always on, no pact mechanic,
  finale guarantees alliances end; the complete chat transcript is a public
  artifact of every match.

## Suggested league seed

- Variant: `competition` (manifest variants[0] — the hosted default:
  16 seats, scripted sponsors, fast zone).
- Seats: 16 per episode; team assignment by slot pairs (0,1)=A ... (14,15)=H.
- Suggested cadence: rolling episodes as entrants queue, seed minted per
  episode and recorded in the effective config (replay-exact).
- Ranking: per-episode score as above; ladder = mean score, ties by wins.
- Player interface: JSON WebSocket protocol `zero_sum.player.v1`
  (documented in the repo: DESIGN.md §10-§11, docs/LLM_CONTEXT.md is a
  model-ready context pack for LLM agents).
- Spectating: `/client/global` broadcast view, `/client/analyst` telemetry
  dashboard (projected scoreboard, softcoin ticker, stat matrix).

## Contact

arisklar6@gmail.com — happy to adjust config, cadence, or scoring to fit
Observatory conventions, and to run any validation episodes requested.
