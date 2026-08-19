# Battle Royal — Phase A Recon Report

Date: 2026-07-30. Repos inspected fresh (shallow clones in this session's workspace):

| Repo | HEAD | Date |
|---|---|---|
| `Metta-AI/bitworld` | `e47559c90d92ff25c748ecdb41cd5695c10c65b2` | 2026-07-24 |
| `Metta-AI/coworld` | `7c3d8f05c29f3b38c39673dee4498c6138719791` | 2026-07-20 |
| `Metta-AI/coworld-cogs-vs-clips` | `f6e545029979913217ecda5ea405aa99f3d99a55` | 2026-07-30 |
| `Metta-AI/coworld-ctf` | `beae1614ea28c3d7761bae614ae974477db35b2d` | 2026-07-30 |

Full raw recon reports (with file:line evidence for every claim below): `recon/bitworld-recon.md`, `recon/coworld-recon.md` — attached.

---

## 0. THE STRUCTURAL DISCOVERY (changes the mission's premise)

**The bitworld repo contains no game.** Verbatim from its README: *"Completed Coworld games live in standalone `cogame-*` repositories and depend on this package through Nimble."* It is a shared **Nim library + orchestration layer**: sprite/bitscreen protocol codecs, the `.bitreplay` replay format, the `COGAME_*` runtime intake, embedded browser clients, drawing/font/pathfinding libs, a games_server orchestrator, and a certifier. The 8 "games" in-repo are manifest JSONs pointing at prebuilt Docker images. There is **no tick loop, no movement, no combat, no items, no fog, no zone, no HP anywhere** in that repo to port.

Second discovery: **`coworld-cogs-vs-clips` (the "v2 Coworld" your laptop had cloned) is not a bitworld game at all.** It is Python on **mettagrid** (Metta's C++ gridworld pip package). Two engine families coexist on the platform (`game.protocols.engine_runtime` enum in the platform schema: `mettagrid | cogweb | bitworld | nimgrid`):

- **bitworld family (Nim):** among_them (bitscreen_v1 = raw 128×128 pixel observations), crewrift/jumper/etc (sprite_v1 = retained-mode sprite scene graph). Game repos: `cogame-among-them`, `coworld-crewrift`, … (separate repos).
- **mettagrid family (Python):** cogs_vs_clips — JSON websocket protocol `coworld.player.v1` (token observations), tick loop owned by the engine.

**The platform contract itself is engine-agnostic** and both families satisfy it. So "use bitworld as the backbone" translates in practice to: *build a new standalone game repo in the bitworld family, consuming the bitworld library for infrastructure, writing the entire battle-royale simulation fresh.* Decision 1 below asks you to confirm that translation (or pick an alternative).

---

## 1. Repo layout (what lives where)

**bitworld** (`~27.7k LOC Nim, 158 files`):
- `src/bitworld/` — the installable library: `spriteprotocol.nim` (both wire codecs), `replays.nim` (bitreplay v3 writer/parser incl. deterministic tick-hash records), `runtime.nim` (COGAME env/CLI intake, results/replay writers), `client.nim` (embedded browser clients + canonical routes), `server.nim` (128×128 indexed framebuffer + sprite blitter), `sprites.nim` (RGBA drawing), `pixelfonts.nim`, `pathfinding.nim` (BFS/greedy step helpers that return button masks — bot-side nav), `tiled.nim`/`aseprite.nim` (map/art loaders), LLM adapters (`ais/{claude,openai,gemini,xai,bedrock}.nim`).
- `client/` — native Nim clients + **self-contained Canvas-2D browser clients** (`player_client.html`, `global_client.html` 1184 lines with pan/zoom + debug panel, `admin_client.html` with pause/kick/QR-join, `snappyjs.min.js`).
- `global_ui/` — a 300-line reference Sprite-v1 game server with a 24 Hz tick loop (`TargetFps = 24.0`). **The best in-repo template for a new game server.**
- `games_server/` — orchestrator (port 2080), tournament/multi servers, `cogame_validator.nim` (bitworld's own certifier, 1821 lines).
- `docs/` — `bitscreen_v1.md`, `sprite_v1.md`, `reward_v1.md`, `bitreplay_spec.md` (contract specs).
- **ABSENT:** any Dockerfile, any compose file, any CI, any game simulation, `players/baseline/baseline.nim` (no bot source exists in-repo — all bots are opaque image refs).

**coworld** (Python, the platform): `src/coworld/` — manifest schema (pydantic `types.py` is source of truth), certifier, local Docker runner + Kubernetes runner, CLI (`coworld` command, full surface verified live in this session), docs (`AUTHORING.md`, `COOKBOOK.md`, `COWORLD_MANIFEST.md`, `roles/GAME.md`, `roles/PLAYER.md`, `artifacts/*` 16 files), `examples/paintarena/` (the canonical packaged example), `templates/roles/*`.

---

## 2. How a game gets packaged as a Coworld (the pattern to copy)

From paintarena + cogs_vs_clips (both verified verbatim in the raw reports):

```
coworld-battle-royal/
  compose.yaml                     # services: battle-royal (build: .), … → {{BATTLE_ROYAL_IMAGE}} placeholder
  Dockerfile.game                  # build stage → slim runtime; CMD runs the game server
  Dockerfile.player                # baseline player image
  coworld_manifest_template.json   # NO game.version (build stamps it); {{…_IMAGE}} placeholders
  game/…  player/…  docs/…  tests/…
```

Build/certify/upload (COOKBOOK "Certify And Upload A Coworld", verbatim commands):

```bash
uv run coworld build --project <dir> --version 0.1.0     # hydrates dist/coworld_manifest.json, builds images from compose.yaml
uv run coworld certify <dir>/dist/coworld_manifest.json  # local Executable transcript, one smoke episode
uv run coworld upload-coworld <dir>/dist/coworld_manifest.json
```

Manifest contract (from generated schema + `types.py`):
- **Top-level required:** `game`, `player` (≥1), `variants` (≥1), `certification`. Optional: `tags` (≥3 items — **hard-required by certify**), `reporter/commissioner/grader/diagnoser/optimizer`, `players_per_user`, `episode_timeout_minutes` (1–100, default 20 — **hosted episodes have a 20-minute deadline unless raised; sizes our match length**).
- **`game` required:** `name`, `version` (build-stamped), `description`, `owner`, `config_schema`, `results_schema`, `runnable`, `protocols` (`player` + `global` docs — text or URI), `docs` (`readme` required; inline text allowed, so **no GitHub repo is required for v1**).
- `config_schema` **must require a string-array `tokens` field** (runner-injected per-slot auth); `variants[].game_config` and `certification.game_config` are token-free.
- `results_schema` must include `scores` (one number per slot) — this is where placement+kill league scores go.
- `certification` = token-free `game_config` + `players[]` (each `{"player_id": <bundled player id>}`) — cogs_vs_clips certifies 8 slots of the same reference player at `max_steps: 3`; we'll do 16 slots, few ticks, scripted gifts.
- compose `platform: linux/amd64` is mandatory (hosted runners are amd64).
- Manifest `env` is public — no secrets ever (matches your constraint); `secret://coworld/...` references exist for hosted if ever needed.

**Certification = 10 automated steps** (verbatim ids): `matriculate, source-resolves, images-reachable, fixture-conforms, smoke-episode, results-conform, replay-present, replay-loadable, players-run, supporting-roles`. One smoke episode, default 60 s timeout. Replay-loadable = game image restarted with `COGAME_LOAD_REPLAY_URI`, `GET /client/replay` must serve, `/replay` WS must emit a frame. **Determinism is NOT machine-checked** — it's a documented authoring invariant (AUTHORING.md verbatim: *"The initial state must be a pure function of the seed, and the state evolution a pure function of state plus actions. No wall-clock reads, no ambient randomness…"*). We'll enforce it ourselves with repeat-run hash tests.

**Game runnable contract** (roles/GAME.md, condensed): long-running container on `COGAME_HOST:COGAME_PORT` (0.0.0.0:8080); read config from `COGAME_CONFIG_URI`; serve `GET /healthz`, `GET /client/player?slot&token`, WS `/player?slot&token` (bad token must be rejected), `GET /client/global` + WS `/global`, replay mode (`COGAME_LOAD_REPLAY_URI` + `/client/replay` + `/replay`, autoplay & loop); write `results.json` → `COGAME_RESULTS_URI`, replay bytes → `COGAME_SAVE_REPLAY_URI`; optional typed `player_failure.json`; exit after writing artifacts. The bitworld library's `runtime.nim` implements exactly this env contract already.

**⚠️ One contract gap vs the mission:** the platform has **no custom game-artifact slot**. A game emits exactly: `results.json` (schema-constrained), `replay` (arbitrary game-owned bytes), stdout/stderr logs, optional player-failure. A standalone `chat_transcript` file next to results is not a thing the platform carries. Compliant adaptation (proposed, Phase B): our replay artifact is a **zip container** (game-owned format is explicitly allowed: *"Format: game-owned byte payload"*) holding the deterministic input-log replay + `chat_transcript.txt` + `sponsor_log.json`; the transcript is also echoed to stdout (→ the public `game_logs` artifact) and summarized fields land in `results.json`. Locally we additionally write plain files next to results for your reading convenience.

**Player contract** (roles/PLAYER.md): short-lived container per slot; reads `COWORLD_PLAYER_WS_URL` (full ws URL incl. slot+token; legacy alias `COGAMES_ENGINE_WS_URL` also set), speaks the **game-owned** player protocol, exits at episode end; may upload one debug zip via `COWORLD_PLAYER_ARTIFACT_UPLOAD_URL`.

---

## 3. Player protocol landscape → Battle Royal protocol plan

- **bitscreen_v1** (among_them): server→client = one 8192-byte frame/tick (128×128, 4-bit Pico-8 palette). client→server = 2-byte button mask packet (`Up/Down/Left/Right/Select/A/B`) or ASCII chat packet. Observation = literally pixels.
- **sprite_v1** (crewrift, jumper…): binary retained-mode scene graph — server sends Define Sprite (snappy-compressed RGBA) / Define Object (id,x,y,z,layer,sprite) / Delete / Clear / Viewport / Layer; client sends Input Text (`0x81`, doubles as chat), Mouse, button mask (`0x84`), Ready, Debug Sprites. Per-socket rendering = **fog/visibility is achieved by the server simply not drawing what you can't see** — there is no other fog mechanism, and that's the idiom we'll keep for spectator/replay surfaces.
- **coworld.player.v1** (cogs_vs_clips): JSON over WS — `player_config` handshake (action names, obs shape, feature dictionary), per-tick `observation`, client `action` (by index or name, invalid/missing → noop), `final`. Slot+token auth, reconnect allowed, human-takeover semantics.

**The platform mandates none of these** — *"The protocol is game-owned; player authors build against the linked spec."* The mission's requirements (stat-allocation handshake, structured fog/camo observations, zone state, death/audible events, sponsor-drop visibility, move/attack/pickup/drop/use/talk actions, talk channels, versioned name) fit a **JSON protocol in the coworld.player.v1 idiom**, which is also by far the friendliest surface for policy authors. Plan: **`battle_royal.player.v1`** — JSON over WS on `/player`, message list fully specified in Phase B; `/global` + `/replay` speak **sprite_v1** so the spectacle renderer is the bitworld one (vendored `global_client.html`). Humans get `/client/player` (custom HTML: renders JSON obs, sends actions/talk; honors the `?address=` proxy param).

## 4. Observation encoding

No structured observation encoder exists in bitworld (observations are rendered pixels/sprites). For Battle Royal: server-side fog computation, per-agent structured JSON (visible tiles/entities within vision radius modified by intelligence/camo/terrain, zone state + next-shrink telegraph, arena-wide events: death fireworks with team/count, audible booms with bearing, sponsor drop markers, team/talk inbox, own inventory/HP/stats/cooldowns). Exact schema in Phase B (DESIGN.md).

## 5. Config intake

`runtime.nim` (bitworld) implements the full contract with CLI-over-env precedence: `--config-uri/--config-path/--config` / `COGAME_CONFIG_URI`, `--results-uri` / `COGAME_RESULTS_URI`, `--save-replay-uri` / `COGAME_SAVE_REPLAY_URI`, `--load-replay-uri` (replay mode), `--log-uri`, `--host/--port`, `--mismatch-quit` (strict replay-hash mode). URI schemes: `file://` and `http(s)://`. Hosted values are `file:///coworld/*.json` per the Kubernetes runner README. Our `config_schema` fields (Phase B): `tokens` (required, 16), `players` (16 names), `seed`, `max_ticks`, `tick_rate`, zone schedule overrides, `sponsor` block (per-team softcoin budget, catalog/price overrides, `scripted_gifts[]`, `live_gifts_enabled`).

**Determinism landmines found (evidence preserved):** bitworld's `multiruns.nim:801` overwrites config seed with wall-clock ms and `tournament_server.nim:1123` with `rand()` — those are *bitworld-orchestrator* launchers we don't use; the platform runner and certifier pass the manifest config verbatim, and league commissioners may set per-episode `seed` via `EpisodeRequest`. Our sim: single PRNG seeded from config, no wall-clock in state, tick-hash records in the replay, `--mismatch-quit` in tests.

---

## 6. Live external input + softcoin (the sponsor architecture facts)

**Softcoin/economy at platform level: ABSENT — definitively.** Exhaustive sweep of the coworld repo (softcoin/coin/wallet/currency/credit/sponsor/payment/budget/shop/purchase) found zero economy primitives. All money-adjacent hits are compute metering (Bedrock spend header, reporter run budgets). → Per your locked default: **softcoin = fixed per-team budget per match, set in variant config**, accounted entirely inside the game.

**Every ingress path into a running episode, ranked by fit:**

1. **Game-owned extra WS route on the game container (LOCAL) — the winner.** Precedent: the `/admin` websocket. It's game-defined, mutates live episode state (paintarena: pause/resume/tick_rate), `coworld play` prints its link unconditionally, and nothing in the contract restricts a game's route vocabulary. Paintarena's is unauthenticated; ours gets a token. Plan: dedicated **`/sponsor` WS + `/client/sponsor` console page** (kept separate from `/admin` so ops control ≠ gameplay input; a token gates it; every accepted gift becomes a logged input event in the deterministic input log — identical pipeline to scripted gifts).
2. **`COWORLD_LOCAL_EXTRA_PORTS`** — manifest-declared extra host ports, sanctioned, local-runner-only. Viable for a separate sponsor API server; overkill vs. option 1 since we own the game server anyway.
3. **`/global` is technically bidirectional** but the docs define it as the read-only spectator contract — not appropriate.
4. **HOSTED / LEAGUE: live ingress is ABSENT. Hard fact.** Verbatim: *"This is the only supported hosted game execution path: the game and all player containers run inside platform-managed Kubernetes jobs."* Networking is ClusterIP-only (no Ingress/NodePort/LB in the k8s runner; `ingress` = zero hits repo-wide). `coworld hosted-game` (a session-proxy path) exists in code but the platform docs disclaim it three times ("Do not describe `coworld hosted-game` as a supported player workflow"). The only hosted per-episode input levers are pre-injected: variant `game_config`, commissioner `game_config_overrides` on `EpisodeRequest`, and secrets. A game calling out to an external service of ours from inside a league episode is technically unblocked but unsanctioned — and bad for fairness; not proposed.

**Consequence (needs your call, Decision 3):** live human sponsorship works in **local episodes** (`coworld play` / exhibition matches) via `/sponsor`; **league episodes cannot receive live gifts on today's platform**, so the competition variant either ships **equal scripted budgets** (seeded gift schedule, same softcoin per team — spectacle + fairness + exercises the pipeline) or **no sponsorship**, or later a **custom commissioner** injects gift scripts per-episode via `game_config_overrides`. Certification never depends on a live human either way (scripted gifts in the fixture, per your spec).

---

## 7. Toolchain check (this cloud workspace)

| Thing | Status |
|---|---|
| Docker | ✅ Engine 29.4.3 present; daemon not auto-started but **starts clean** (`dockerd` launched and verified in this session; buildkit OK). Will keep alive / restart per session. |
| uv | ✅ 0.8.17; `uv run coworld --help` works from the coworld clone — full CLI surface confirmed live (certify, build, play, run-episode, scrimmage, replay, upload-coworld, download, league, …). |
| Nim | ❌ not installed; apt only has 1.6.14 (too old — bitworld needs ≥2.2.4). Plan: install Nim 2.2.6 via `nimby` (the exact toolchain cogs_vs_clips's Dockerfile uses) at Phase C start; deps pinned by bitworld's `nimby.lock`. In-Docker builds use the same pattern, so dev and image builds match. |
| Arch | linux/amd64 (matches mandatory compose platform). |
| Auth | `coworld upload-coworld` / `download` require `uv run softmax login` (interactive). **Not needed until Phase E** — flagged now so it's not a surprise: at Phase E you'll either run the login here interactively or supply a token. Nothing else needs auth; certify is fully local. |
| Windows friction | none — we're on Linux in this session. |

## 8. Port-directly vs. new (honest sizing)

**Reused from the bitworld library (infrastructure, ~zero cost):** sprite_v1 + bitscreen codecs; browser clients (global/admin/replay, vendored + reskinned); `.bitreplay` v3 writer/parser incl. tick-hash + chat records + the new raw client-input record (`0x07` — carries arbitrary per-player payloads, i.e. our JSON actions and sponsor events fit natively); `COGAME_*` runtime intake incl. replay mode; framebuffer/RGBA drawing + pixel fonts (sprite sheet generation); pathfinding helpers (baseline bot nav); mummy websocket server pattern + 24 Hz tick-loop template (`global_ui`).

**New (all of it is the game — nothing exists to port):** arena/map gen; pedestals + freeze + mines + fireworks start; loot tables + inventory + 6 weapons + 4 gear + forage; combat (unarmed/melee/ranged/DoT/net), HP, permadeath + death-fireworks broadcast; stat allocation protocol + effects; zone shrink + scripted hazards; talk channels + transcript; sponsor pipeline (softcoin accounting, `/sponsor` ingress, airdrop delivery, gift log); placement+kill scoring + FFA finale; `battle_royal.player.v1` protocol + structured observations + fog; per-agent obs renderer for humans; baseline player (written fresh — `players/baseline/baseline.nim` does not exist upstream); sprite art (placeholders first). Estimate: ~3–5k LOC Nim sim+protocol, ~1k client/player HTML, plus manifest/compose/Dockerfiles/docs (~400 lines) and tests. cogs_vs_clips's equivalent adapter+player+manifest layer is ~1k LOC — consistent.

## 9. Contradiction / evidence log (nothing filed silently)

1. Mission: "bitworld already cloned at source/repo" — false on the laptop (prior session) and N/A here; fresh clones made.
2. Mission: bitworld = "a good working Coworld" — it's the library/orchestrator; games live in separate repos (README quote above).
3. The laptop's `coworld-cogs-vs-clips` clone is mettagrid/Python, not bitworld — the "v2 Coworld" exemplar is from the *other* engine family.
4. bitworld `docs/bitreplay_spec.md` is stale vs code: record `0x07` (client-input) exists in `replays.nim` but not in the spec; spec's key-bit table contradicts `bitscreen_v1.md` on Select/A/B bits. Code treated as authoritative.
5. bitworld README advertises prototype games (Warzone, Ice Brawl, …) absent from the tree.
6. Platform docs: no custom game artifact slot → mission's standalone `chat_transcript` artifact adapted (see §2 ⚠️).
7. `coworld hosted-game` exists in code but is explicitly disclaimed as unsupported — not built upon.
8. bitworld launchers (`multiruns`, `tournament_server`) clobber config seeds with wall-clock/rand — irrelevant to platform runs, documented so we never use those launchers for reproducible episodes.

## 10. Decisions needed (popup) + proposed next step

- **D1 — Backbone confirmation:** (1) **Nim + bitworld library** in a new `battle-royal` repo, custom `battle_royal.player.v1` JSON protocol, sprite_v1 spectacle — recommended; (2) Python paintarena-style (fastest iteration, no bitworld code reuse, renderer re-implemented or vendored); (3) Python + mettagrid (engine fights every BR mechanic: no projectiles, PvP attack unproven, pinned C++ core) — not recommended.
- **D2 — Live-gift ingress (local):** (1) dedicated authenticated `/sponsor` WS + `/client/sponsor` console — recommended; (2) extend `/admin`; (3) extra-port sidecar server.
- **D3 — League-variant sponsorship** (hosted live input impossible today): (1) equal scripted budgets — recommended; (2) none in league; (3) custom commissioner injecting per-episode gift scripts later (v2 backlog).
- **D4 — Proceed to Phase B** (DESIGN.md) on your go.

Softcoin source is resolved by fact (no platform primitive → per-team budget in variant config, per your locked default). Proposed next step: on D1–D4 answers, write DESIGN.md with concrete numbers and stat-mapping proposals, STOP for your review.
