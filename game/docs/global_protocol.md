# Battle Royal — global/spectator protocol

The spectator surfaces speak the engine's binary sprite protocol
(`sprite_v1`): the server pushes sprite/object/layer definition messages over
WebSocket and the bundled browser client renders them. You normally never
parse this yourself — open the client pages.

## Endpoints

- `GET /client/global` — live spectator page (pan/zoom the arena).
- `WS /global` — the sprite_v1 stream behind it.
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

## Static replay artifact

The replay written to `COGAME_SAVE_REPLAY_URI` is a zlib-compressed sequence
of timestamped `sprite_v1` packets. It records the exact public presentation
stream generated for the live global viewer. The game-owned static bundle
fetches those bytes through its `?replay=` parameter and provides autoplay,
pause, speed, seek, and looping without starting the game image.

Human-readable transcripts, sponsor logs, event history, and fairness reports
remain separate match artifacts. The replay intentionally contains no auth
tokens or private player observations.
