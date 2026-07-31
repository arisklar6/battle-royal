# Zero Sum — global/spectator protocol

The spectator surfaces speak the engine's binary sprite protocol
(`sprite_v1`): the server pushes sprite/object/layer definition messages over
WebSocket and the bundled browser client renders them. You normally never
parse this yourself — open the client pages.

## Endpoints

- `GET /client/global` — live spectator page (pan/zoom the arena).
- `WS /global` — the sprite_v1 stream behind it.
- `GET /client/replay` + `WS /replay` — replay mode (server started with
  `COGAME_LOAD_REPLAY_URI`); plays automatically and loops.
- `GET /client/admin` + `WS /admin` — read-only ops view of the same stream.
- `GET /healthz` — liveness.

All client pages honor an optional `?address=` query parameter (proxied
hosting) and otherwise derive their WebSocket URL from the page origin.

## What a spectator sees

One zoomable world layer (288x288 px, 6 px per tile) plus anchored HUD
layers:

- top-left: `ALIVE n  RING r  T m:ss`
- bottom-left: per-team softcoin ticker (`COIN A300 B180 ...`)
- center-top banners: `IGNITION`, `FINALE`, `WINNER <team> P<slot>`

On the map: team-colored agent chips (two per team, pip marks the second
slot), loot chips color-coded by item, projectile tracers, the advancing
orange fire ring at the safe-zone boundary, hazard region tints (firestorm
orange, flood blue), sponsor pods (blinking red target while inbound, white
crate with red stripe once landed), and fireworks: gold bursts for ignition
and the winner, black bursts + shock ring for every death, orange flash for
pedestal mines.

## Replay artifact

The replay blob written to `COGAME_SAVE_REPLAY_URI` is a zip:

| file | contents |
|---|---|
| `replay.zsr` | engine replay stream: complete effective config (seed included, all auth tokens stripped), joins, every applied input as client-input records, per-tick state hashes |
| `input_log.json` | human-readable applied-input log (actions, talk, sponsor gifts) |
| `effective_config.json` | the complete effective config (convenience copy) |
| `chat_transcript.txt` / `.json` | full talk transcript with system events |
| `sponsor_log.json` | every gift request, accepted AND rejected, with costs and balances |
| `match_summary.json` | results mirror + death log |

The match is deterministic given that config + input log; replay mode
re-simulates and verifies the recorded per-tick hashes.
