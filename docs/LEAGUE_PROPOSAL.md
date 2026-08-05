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
- **No self-pairing.** A player may hold several policy versions, so pairing
  must never place the same player on both seats of a team. Otherwise that
  player gets Duos-grade coordination inside a Solo league — a strictly
  dominant position, since the two halves can agree a finale outcome that a
  stranger pairing never would.
- Higher variance, since some of your result depends on a partner you did not
  choose. **Please schedule more episodes per round here than in Duos** so
  ratings converge; partner luck should average out within a round rather than
  across many rounds.

### Both leagues

- Cadence: continuous rounds, as Paintbot runs today.
- **Fillers are the launch requirement.** Set
  `filler_policy_version_ids: ["092ffb35-671e-4497-aadf-a7baa4244897"]` — our
  baseline, already on the platform as `coworld-smoke/cow_36202b83-…` v1 from
  the 0.1.8 upload. Paintbot demonstrates the pattern: it runs continuously
  with one filler policy and `insufficient_players: "do_not_run"`, because
  fillers satisfy the seat count. Zero Sum needs 16 seats, so without this a
  single real entrant can never start a round.
- Disqualification: platform default (3 consecutive failures) is fine.

### Concrete seed, modeled on the live Paintbot league

Shared:

```json
{
  "filler_policy_version_ids": ["092ffb35-671e-4497-aadf-a7baa4244897"],
  "settings": {
    "ladder": {
      "enabled": true,
      "ranking": { "algorithm": "elo", "k_factor": 16,
                   "initial_rating": 1500, "round_scoring_rule": "mean" },
      "divisions": [{ "name": "Competition",
                      "disqualify_after_consecutive_failures": 3 }],
      "fulfillment": { "retry_times": 2, "allowed_failures": 0.05 }
    }
  }
}
```

### Seating: please use the container commissioner, not `team_n`

**The platform ladder's `team_n` strategy cannot seat this game correctly.**
Zero Sum defines a team as a *contiguous* seat pair
(`src/zero_sum/types.nim:128` — `proc team*(slot: AgentId): int = slot div 2`),
but `team_n` deals seat groups *interleaved*, by `slot mod team_count`. At
`team_count: 8` over 16 seats, entrant *i* receives slots `{i, i+8}`, which
under `slot div 2` land in teams `i/2` and `i/2 + 4` — every entrant split
across two teams and every team split between two entrants. That is neither
mode; it silently corrupts both. Please do not seed either league with
`strategy: team_n`.

The reusable **container commissioner** (`commissioner_key: "container"`, as
Proxywar and Traverse Wow already use) expresses both modes exactly:

- **Duos** — `{"seating": "team_blocks", "team_count": 8, "policies_per_team": 1}`
  → slot→entrant `[0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7]`, i.e. entrant *i* on slots
  (2i, 2i+1). Exactly one entrant per team.
- **Solo** — `{"seating": "team_interleaved", "team_count": 8, "policies_per_team": 2}`
  → slot→entrant `[0,1,2,…,15]`, so Zero Sum team *i* is entrants `{2i, 2i+1}`.
  Two different entrants per team.

No `allied_teams`: unlike Paintbot, all 8 Zero Sum teams are mutually hostile.

### Remaining gaps we could not close from outside

1. **Solo's two fairness rules are not expressible in any scheduler we could
   find**: partner re-randomized per episode, and never the same player on both
   seats of a team. With static seating, entrant 0 is always paired with
   entrant 1. If the commissioner cannot randomize per episode, Solo still
   works but partner assignment is fixed within a round — please tell us which,
   because it changes how many episodes a round needs.
2. The platform ladder's scheduler source is closed (`app_backend`, private
   `Metta-AI/metta`), so the `team_n` behaviour above is inferred from observed
   episodes rather than read from code. Worth a sanity check by someone who can
   see it.
- Player interface: JSON WebSocket protocol `zero_sum.player.v1`
  (documented in the repo: DESIGN.md §10-§11, docs/LLM_CONTEXT.md is a
  model-ready context pack for LLM agents).
- Spectating: `/client/global` broadcast view, `/client/analyst` telemetry
  dashboard (projected scoreboard, softcoin ticker, stat matrix).

## Contact

arisklar6@gmail.com — happy to adjust config, cadence, or scoring to fit
Observatory conventions, and to run any validation episodes requested.
