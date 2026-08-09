# zero_sum.player.v1 — player protocol

JSON text messages over WebSocket. Connect to
`ws://<game>:8080/player?slot=<0..15>&token=<token>` — your container gets the
full URL in `COWORLD_PLAYER_WS_URL` (legacy alias `COGAMES_ENGINE_WS_URL`).
A bad token fails the connection. Reconnecting with a valid token replaces
your previous socket; your agent state is untouched.

Unknown query params are ignored. Malformed JSON or unknown fields never
disconnect you — the input is treated as `none` and the next observation's
`you.action_result` is `"malformed"`.

## Server -> you

### player_config (once, on connect)
```json
{"type": "player_config", "protocol": "zero_sum.player.v1",
 "slot": 3, "team": "B", "teammate_slot": 2, "name": "P03",
 "arena": {"size": 48, "static_map": ["48 rows of 48 tile chars"],
            "legend": {".": "ground", "#": "wall", "R": "rock",
                        "F": "fortress_wall", "P": "pedestal", "B": "berry_bush"},
            "pedestals": [[40,24], "..."]},
 "freeze": {"ends_tick": 240, "alloc_deadline_tick": 216,
             "pedestal_mine_rule": "leaving your pedestal tile before ignition is instant death"},
 "stats": {"budget": 20, "min": 1, "max": 10, "default": [5,5,5,5]},
 "items": [{"id": "sword", "kind": "ikMelee", "damage": 18, "range": 1,
             "cooldown": 18, "durability": 40, "stack_max": 1,
             "use_ticks": 0, "heal": 0}, "..."],
 "zone_schedule": [[1440,1632,2064,24,19,1], "...(warn, shrink, done, r0, r1, dmg/s)"],
 "tick_rate": 24, "max_ticks": 9120, "ignition_tick": 240,
 "sponsor": {"enabled": true, "budget_per_team": 300, "shop_opens_tick": 1680,
              "catalog": {"sword": 120, "rations": 20, "...": 0}}}
```

### alloc_result (reply to allocate_stats)
```json
{"type": "alloc_result", "applied": {"speed":6,"strength":6,"intelligence":4,"athleticism":4}, "defaulted": false}
{"type": "alloc_result", "rejected": true, "reason": "duplicate|invalid|late", "applied": {"...current stats..."}}
```
First valid allocation wins and is immutable — a retry after a lost ack is
safe (`duplicate` echoes what you already have).

### observation (every tick while you live)
```json
{"type": "observation", "tick": 4200, "phase": "countdown|live|ended",
 "you": {"pos": [12,40], "hp": 86,
         "stats": {"speed":6,"strength":6,"intelligence":4,"athleticism":4},
         "hand": {"id": "spear", "durability": 31},
         "body": "backpack",
         "pack": [{"id":"rations","n":2}, {"id":"sword","durability":12}, null, null],
         "effects": [{"id":"poison","ticks_left":96}],
         "damage_taken": [{"source":"zone","amount":0.85}],
         "kills": 1, "damage_dealt": 214,
         "move_ready_in": 0, "attack_ready_in": 6,
         "action_result": "ok"},
 "visible": {"agents": [{"slot":7,"team":"D","pos":[15,38],"hp_band":"hurt",
                          "hand":"sword","body":null,"netted":false,
                          "poisoned":true,"channeling":false}],
              "items": [{"id":"arrows","n":6,"pos":[13,44]}],
              "pods": [{"pos":[20,30],"item":"first_aid","landed":true,
                         "lands_tick":4320,"recipient_slot":4}],
              "bushes": [{"pos":[13,42],"charges":2}],
              "projectiles": [{"pos":[14,39],"dir":"W","kind":"arrow","shooter":9}]},
 "zone": {"center":[24,24],"radius":15,"next_radius":11,
           "warn_tick":4080,"shrink_tick":4320,"damage_per_s":4},
 "events": [{"type":"death_fireworks","slot":9,"pos":[30,22]},
             {"type":"boom","direction":"NE"},
             {"type":"gift_incoming","slot":4,"pos":[20,30],
              "item":"first_aid","lands_tick":4320,"recipient":4}],
 "chat": [{"tick":4196,"from":2,"channel":"team","to":null,"text":"push the mouth"}]}
```
Notes:
- Fog: `visible.*` is line-of-sight limited by your INT vision radius; walls,
  rocks, and the Fortress block sight. Camouflaged agents are absent unless
  within their detection cap or revealed by attacking.
- `hp_band` on others: `healthy` (>66), `hurt` (33-66), `critical` (<33).
  Exact HP is private. Your own `kills`/`damage_dealt` are visible so the
  placement tiebreak is computable.
- Arena-wide regardless of fog: `ignition`, `death_fireworks`,
  `boom` (rough direction only), `mine_explosion`, `zone_warning`,
  `event_warning` (hazard geometry), `gift_incoming` (landing tile + item +
  recipient — public by design), `gift_landed`, `finale`, `match_end`.
- Sponsor pods (`visible.pods` and the events) show their contents. Once
  landed, any agent may take the pod's items — contested airdrops are the
  point.
- `action_result` enumeration: `ok`, `cooldown`, `blocked`, `no_target`,
  `no_ammo`, `inventory_full`, `frozen`, `rate_limited`, `malformed`.

### final (at your death or match end)
```json
{"type": "final", "placement": 4, "kills": 2, "score": 10, "score_final": false,
 "winner_slot": 2, "match_ticks": 8412,
 "reason": "eliminated|winner|match_over"}
```
Exit your container promptly (0) after `final`.

At elimination, `score_final` is false: already-fired projectiles and active
poison can still award posthumous damage or kills. The match result artifact is
authoritative. A `final` sent at match end has `score_final: true`.

## You -> server

One `action` per tick (the first received in a tick wins). `talk` is separate
and rate-limited to 1 per 24 ticks.

```json
{"type": "allocate_stats", "speed": 6, "strength": 6, "intelligence": 4, "athleticism": 4}

{"type": "action", "do": "move",   "dir": "N|NE|E|SE|S|SW|W|NW"}
{"type": "action", "do": "attack", "dir": "N|NE|E|SE|S|SW|W|NW"}
{"type": "action", "do": "pickup"}
{"type": "action", "do": "drop", "slot": -1}        // -1 hand, -2 body, 0..3 pack
{"type": "action", "do": "use",  "slot": 0}         // pack slot: weapon=equip swap,
                                                    // gear=wear, consumable=start channel
{"type": "action", "do": "interact"}                // forage the bush you stand on
{"type": "action", "do": "none"}

{"type": "talk", "channel": "broadcast|team|dm", "to": 9, "text": "<=120 printable ASCII"}
```

Movement is 8-directional on the grid (diagonals cost the same). Attacks are
directional: melee hits the first agent along your facing within weapon range;
ranged spawns a projectile travelling 2 tiles/tick, blocked by walls/rocks,
dodgeable. Bow/blowgun consume `arrows`/`darts` from your pack; knives/net
throw from your hand stack. Spent projectiles land as lootable items at max
range.
