# League proposal: Battle Royal Solo

Request to the Softmax team to seed the published Coworld **battle-royal** as one
platform-owned Solo league.

Seed creation is currently staff-only. The endpoint
`POST /api/observatory/v2/coworld-league-seeds` requires a Softmax team principal.
`--elevated` selects elevated privileges already present on a credential; it
does not turn a Coworld-owner user credential into a team credential.

## Published Coworld

| Field | Value |
|---|---|
| Coworld ID | `cow_36202b83-04d1-4307-84d4-06832f069adb` |
| Name / version | `battle-royal:0.1.8` (canonical) |
| Owner | arisklar6@gmail.com |
| Source | https://github.com/arisklar6/battle-royal |
| Certification | 10/10, hosted smoke 5/5 |
| Seats | 16 contestants, paired internally as 8 adjacent teams |
| Score | Per-seat placement points plus kills |

The `competition` variant is the first manifest variant and is suitable for
hosted play: a fresh recorded seed per episode, the full ring schedule, and an
identical scripted sponsor schedule for every in-game team.

## Why this request contains one league

Coworld league seeds are unique by Coworld name. One `battle-royal` seed therefore
creates one reconciled league; it cannot create separate Solo and Duos leagues.

The published `battle-royal:0.1.8` contract is already correct for Solo: each
platform policy controls one seat and receives that seat's score. Duos needs a
separate `battle-royal-duos` Coworld profile because platform `team_n` with
`team_count: 8` gives an entrant seats `i` and `i+8`, while the current game
teams are adjacent slots, and the platform averages multi-seat policy rewards.
That profile is tracked in issue #2 and PR #3. Seed it separately only after
its Coworld is published and certified.

## Requested Solo configuration

### 1. Create the platform-owned seed

```http
POST /api/observatory/v2/coworld-league-seeds
Content-Type: application/json

{
  "coworld_name": "battle-royal",
  "template": "commissioner_driven",
  "enabled": true,
  "overrides": {
    "commissioner_key": "platform"
  }
}
```

The manifest intentionally has no commissioner runnable. New Coworld leagues
use the typed platform ladder and shared Temporal worker; the container
commissioner path is deprecated and closed to new use.

Seed reconciliation returns or creates the league ID, but a new platform seed
schedules nothing until its division and ladder document are declared.

### 2. Declare one Competition division

```http
PUT /api/observatory/v2/leagues/{league_id}/divisions
Content-Type: application/json

{
  "divisions": [
    {
      "name": "Competition",
      "level": 1,
      "type": "competition",
      "hidden": false
    }
  ]
}
```

Use the returned `division_id` in the ladder document below.

### 3. Configure the hosted baseline as the filler

```http
POST /api/observatory/v2/leagues/{league_id}/filler-policies
Content-Type: application/json

{
  "policy_version_ids": [
    "092ffb35-671e-4497-aadf-a7baa4244897"
  ]
}
```

`insufficient_players: "filler_policy"` then tops a small live roster up to
16 seats. Filler seats do not receive ladder credit.

### 4. Write and enable the typed ladder

The settings endpoint replaces the complete settings document. Read it first
and preserve any existing siblings. For a new league, use:

```http
POST /api/observatory/v2/leagues/{league_id}/settings
Content-Type: application/json

{
  "ladder": {
    "enabled": true,
    "players_per_user": 1,
    "scheduler": {
      "strategy": "team_n",
      "insufficient_players": "filler_policy",
      "team_count": 16,
      "num_episodes": 32,
      "matchmaking": "elo_softmax",
      "matchmaking_temperature": 100
    },
    "fulfillment": {
      "retry_times": 2,
      "allowed_failures": 0.05
    },
    "ranking": {
      "algorithm": "elo",
      "initial_rating": 1500,
      "k_factor": 16,
      "round_scoring_rule": "mean"
    },
    "divisions": [
      {
        "division_id": "{competition_division_id}",
        "name": "Competition",
        "disqualify_after_consecutive_failures": 3
      }
    ]
  }
}
```

Why `team_n` with 16 teams: over a 16-seat variant, `seat_index % 16`
assigns exactly one seat to each selected policy. The scheduler redraws the
ordered assignment per episode, so adjacent in-game teammates vary rather
than remaining a fixed pair. `players_per_user: 1` prevents a real user from
holding two active players in the league; the ladder already contributes only
one champion policy version per player.

With at least 16 live entrants, `elo_softmax` schedules 32 independent draws
per round, weighted toward nearby ratings. Below 16, the configured baseline
fills the missing seats so the league can launch immediately.

### 5. Prove one real cycle

1. Ensure rounds are unpaused with `POST
   /api/observatory/v2/leagues/{league_id}/rounds-paused` and
   `{"paused": false}`.
2. Trigger one cycle with `POST
   /api/observatory/v2/leagues/{league_id}/trigger-round`.
3. Verify a `platform` round with a frozen 16-seat episode plan, completed
   hosted EpisodeRequests, an Elo settlement, and a published Competition
   leaderboard.

Membership or a pending round is not hosted proof; the handoff is complete
only after an actual episode and settled round read back successfully.

## Owner and staff boundary

The present boundary is intentional and still requires a staff bootstrap:

- **Staff-only:** create/enable a seed, declare platform topology once the
  ladder is enabled, and author matchmaking/ranking in `settings.ladder`.
- **League owner after reconciliation:** manage filler policies, pause or
  unpause rounds, trigger a round, read settings, and disable an existing
  ladder without changing its other fields.
- **Not an owner capability:** create a seed for an owned Coworld or use
  `--elevated` to acquire team identity.

After the staff bootstrap, normal league operation does not require a human
commissioner. The platform ladder plans, dispatches, settles, ranks, and
continues rounds through its shared workflow.

## Duos follow-up

After PR #3 lands, publish and certify the generated `battle-royal-duos` manifest
under its separate name, then create a second platform seed with the same
four-step process. Its scheduler uses `team_n`, `team_count: 8`; the game maps
external seats `i` and `i+8` to adjacent teammates and reports the same
combined team score to both seats, so the platform mean equals the team sum.

## Contact

arisklar6@gmail.com
