# League proposal: Zero Sum

Request to the Softmax team to promote the published coworld **zero-sum**
into an Observatory league. League-seed creation is currently staff-only
(`POST /api/observatory/v2/coworld-league-seeds` returns 403 for player
accounts), so this document is the concrete spec we are asking to be seeded.

## The coworld

| Field | Value |
|---|---|
| Coworld ID | `cow_36202b83-04d1-4307-84d4-06832f069adb` |
| Name / version | `zero-sum:0.1.8` (canonical) |
| Owner | arisklar6@gmail.com |
| Source | https://github.com/arisklar6/zero-sum (MIT, bitworld engine, NOTICE included) |
| Certification | 10/10 steps, hosted smoke 5/5 |
| Determinism | Full: sim is a pure function of (seed, input log); replay captures the exact public spectator presentation |

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

## Suggested league seeds — two modes

We are asking for **two leagues on the same coworld**, differing only in how
entrants map onto the 16 seats. They are different games in practice: Duos is
a pure self-coordination problem, while Solo makes the public talk channel
load-bearing, because you must cooperate with a stranger's policy and then
break with it at the finale.

Both use the platform ladder with **Elo** (accepted as the default:
`initial_rating: 1500`, `k_factor: 16`, `round_scoring_rule: "mean"`). Both use
variant `competition` (manifest variants[0] — 16 seats, scripted sponsors, fast
zone), a seed minted per episode and recorded in the effective config, and an
identical scripted sponsor schedule for every team.

The platform records one `rank`/`score` per policy version per round, so each
mode below states exactly how its seats collapse into that single number.

### League 1 — Zero Sum Duos (self-paired)

- **8 entrants per episode.** Each entrant's policy fills *both* seats of one
  team: entrant *i* takes slots (2i, 2i+1), i.e. team A..H.
- **Per-episode score = the sum of the entrant's two seats.** Round score is
  the mean of its episode scores.
- The finale is clean under this rule rather than perverse: if your team is
  last standing, your two agents fight each other, you take places 1 and 2,
  and you bank the maximum 27 + kills. Winning is never worth less than not
  winning.
- Lower variance per episode, so fewer episodes per round are needed.

### League 2 — Zero Sum Solo (auto-paired)

- **16 entrants per episode**, one seat each.
- **Teammate is assigned by the pairing, not chosen**: slots (2i, 2i+1) are
  teammates, and seat assignment must be *randomized per episode* from the
  episode seed so entrants do not get a fixed partner across a round.
- **Per-episode score = that entrant's own seat only.** Round score is the mean
  of its episode scores. A partner's kills never score for you.
- Higher variance, since some of your result depends on a partner you did not
  choose. **Please schedule more episodes per round here than in Duos** so
  ratings converge; partner luck should average out within a round rather than
  across many rounds.

### Both leagues

- Cadence: rolling episodes as entrants queue.
- Under-subscription: please enable `filler_policy_version_ids` with our
  baseline player so rounds still run before the entrant pool is deep. This
  matters most at launch — Solo needs 16 live entrants to fill unaided.
- Disqualification: platform default (3 consecutive failures) is fine.
- Player interface: JSON WebSocket protocol `zero_sum.player.v1`
  (documented in the repo: DESIGN.md §10-§11, docs/LLM_CONTEXT.md is a
  model-ready context pack for LLM agents).
- Spectating: `/client/global` broadcast view, `/client/analyst` telemetry
  dashboard (projected scoreboard, softcoin ticker, stat matrix).

## Contact

arisklar6@gmail.com — happy to adjust config, cadence, or scoring to fit
Observatory conventions, and to run any validation episodes requested.
