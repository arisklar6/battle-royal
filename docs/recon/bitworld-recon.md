I have a complete picture. Here is the report.

---

# BitWorld Recon Report

**Repo:** `/home/claude/source/bitworld` — shallow clone (`.git/shallow`, 1 commit: `e47559c Merge pull request #237 from Metta-AI/replay-client-input-records`), branch `master`, 158 tracked files, ~27.7k lines of Nim.

## ⚠️ The single most important structural fact

**This repo contains NO game simulation code.** It is the shared protocol library + orchestration/tooling layer. Per `README.md:6-8`:

> "Completed Coworld games live in standalone `cogame-*` repositories and depend on this package through Nimble."

Every "game" present in-repo is **only a `coworld_manifest.json`** pointing at a prebuilt Docker image (`public.ecr.aws/s3j4p9s7/treeform/games/...`). There is no tick loop, no movement, no combat, no fog of war, no map generation for any actual game inside this tree. Plan accordingly: a new battle-royale game would live in its own `cogame-*` / `coworld-*` repo and consume this repo as a Nimble dependency.

---

# 1. REPO LAYOUT

## Top-level directories

| Path | Purpose |
|---|---|
| `src/bitworld/` | **The installable library.** Protocol codecs, replay format, Coworld runtime (config/artifact intake), asset loaders, drawing primitives, pathfinding, multi-run harness, LLM adapters. |
| `client/` | **Renderers/clients.** Native Nim clients (`*.nim`) + browser clients (`*.html`, Canvas 2D) + shared art assets (`data/`, `dist/`). Also contains a stray committed macOS arm64 binary `client/client` (Mach-O, 1.25 MB). |
| `games_server/` | **Orchestrator.** A `mummy` HTTP/web-UI server that launches game+bot Docker containers/ECS tasks from manifests. Also `tournament_server.nim`, `multi_server.nim`, the Coworld certifier, ECS/container/artifact backends. Holds `games/<name>/coworld_manifest.json` and `players/<name>/coplayer_manifest.json`. |
| `global_ui/` | A **reference Sprite-v1 server** (300 lines) — a working minimal example of a game server side of the global protocol with a 24 Hz tick loop. Best template for a new game. |
| `tools/` | CLI tools: `quick_run`, `games_cli`, `coworld_certify`/`cogame_certify`, `docker_build`, `multi_run`, `start_all_games`, `infra` (terraform wrapper), `ptswap`, `update_manifest`, plus 3 shell scripts. |
| `docs/` | **The contract-level specs.** `bitscreen_v1.md`, `sprite_v1.md`, `reward_v1.md`, `bitreplay_spec.md`, `container_philosophy.md`, `tools.md`, `quick_run.md`, `demo_grid.md`, `docker_gdb_debugging.md`, `bitworld.md`. |
| `tests/` | 17 `test_*.nim` + 5 `manual_*.nim` (network-hitting LLM adapter smoke tests), plus `tests/data/jumper/` Tiled fixtures. |
| `infra/` | Terraform for AWS (VPC, ECS Fargate, EC2 dashboard, S3 buckets, DNS-firewalled security groups). 1197 lines. |
| `.claude/skills/games-cli/` | One skill file (`SKILL.md`). |

## Where the core simulation lives

**ABSENT.** No simulation exists in-repo. The closest thing to a game loop is:
- `global_ui/global_ui.nim:248-281` — `while true:` loop, `inc tick`, `runFrameLimiter(lastTick)` at `TargetFps = 24.0` (`global_ui/global_ui.nim:7`).

Shared helpers a sim would use:
- `src/bitworld/server.nim` — despite the name, this is the **128×128 indexed framebuffer + sprite blitter** (`initFramebuffer` :108, `putPixel` :116, `blitSprite` :121, `blitText` :171, `packFramebuffer` :221).
- `src/bitworld/sprites.nim` — RGBA sprite primitives (`fillRect` :363, `drawLine` :404, `drawCircleFill` :458, `blitRgbaSprite` :505, HSV tinting :284).
- `src/bitworld/pathfinding.nim` — fixed `MapWidth* = 32 / MapHeight* = 32` (`:4-5`) obstacle grid, `bfsNextStep` :36, `greedyStep` :118, `unstickStep` :130, `pathStep` :142.
- `src/bitworld/tiled.nim` — Tiled `.tmx`/`.tsx`/`.tiled-project` loader (`loadTiledMap` :174, `gidAt` :248).
- `src/bitworld/aseprite.nim` — `.aseprite` file parser incl. tilemap layers/cels.
- `src/bitworld/resources.nim` — a small `.resources` rect/color declarative format (`parseResourceRects` :183).
- `src/bitworld/pixelfonts.nim` — pixel font decode + OCR-style glyph scoring (used by bots to read the screen).

## Renderer/client — tech

Two parallel stacks, both first-class:

**Native Nim** (windy + silky + OpenGL):
- `client/player_client.nim` (812 lines) — Bitscreen v1 client. Draws a Game-Boy-style shell; `ShellWidth* = 293*2`, `ScreenOnlyW = ScreenWidth*3`. `TargetFps = 24.0` (`:55`). Uses `windy`'s `openWebSocket`.
- `client/global_client.nim` (1296 lines) — Sprite v1 client. **Raw OpenGL/GLSL** (`RawRenderer` with `#version 300 es` shaders at `:100-131`, `initRawRenderer` :160), layer textures, pan/zoom, `TargetFps = 60.0` (`:75`). Also serves as a `/player` client when `playerMode` is on. Emscripten/WebGL2 build path exists (`config.nims:22-84`, `-s USE_WEBGL2=1 -s FULL_ES3=1`).
- `client/reward_client.nim` — Reward v1 text viewer.

**Browser (Canvas 2D, not WebGL)** — embedded into every game binary via `staticRead` (`src/bitworld/client.nim:37-42`):
- `client/player_client.html` — `<canvas id="c" width="128" height="128">`, `getContext("2d")`, `image-rendering:pixelated`. Handles *both* raw 8192-byte frames and Sprite v1 (per-layer offscreen canvases at `:89-101`).
- `client/global_client.html` (1184 lines) — Sprite v1 viewer + debug-sprite panel; `ctx=canvas.getContext("2d")` (`:165`).
- `client/admin_client.html` (625 lines) — admin/spectator control panel + QR join code.
- `client/reward_client.html`, `client/stats.html`.
- `client/snappyjs.min.js` (sprite pixel decompression), `client/qrcode.min.js`.

## Where player-protocol handling lives

- **Codec:** `src/bitworld/spriteprotocol.nim` (581 lines) — single source of truth for both Bitscreen v1 and Sprite v1 wire formats. `src/bitworld/bitstreamprotocol.nim` is a 3-line re-export alias.
- **Route table:** `src/bitworld/client.nim:6-42` — canonical HTTP client routes + embedded HTML bodies; `clientRoute()` (`:69`) maps `/clients/*` (v2 Coworld plural) and `/client/*` (v1) aliases onto one canonical route.
- **A concrete server-side implementation:** `global_ui/global_ui.nim:185-211` (`httpHandler` upgrade + `websocketHandler`).

## Games in-repo and where their code lives

8 manifests under `games_server/games/`, **manifest-only** (dir also contains `games_server/games/keep`: *"This directory stores uploaded Coworld manifests."*):

| Game | Version | Image | Player protocol | Source repo (from manifest) |
|---|---|---|---|---|
| `among_them` | 0.1.20 | `.../games/among-them:latest` | **bitscreen_v1** | `github.com/Metta-AI/cogame-among-them` |
| `crewrift` | 0.1.26 | `.../games/crewrift:latest` | sprite_v1 | `github.com/Metta-AI/coworld-crewrift` |
| `asteroid_arena` | 0.1.0 | `.../games/asteroid-arena:latest` | sprite_v1 | `github.com/Metta-AI/coworld-asteroid-arena` |
| `big_adventure` | 0.1.0 | `.../games/big-adventure:latest` | sprite_v1 | — |
| `heartleaf` | 0.1.0 | `.../games/heartleaf:latest` | sprite_v1 | — |
| `infinite_blocks` | 0.1.0 | `.../games/infinite-blocks:latest` | sprite_v1 | — |
| `jumper` | 0.1.0 | `.../games/jumper:latest` | sprite_v1 | — |
| `planet_wars` | 0.1.0 | `.../games/planet-wars:latest` | sprite_v1 | — |

21 bot manifests under `games_server/players/*/coplayer_manifest.json` (also image-only). Note `README.md:20-31` advertises prototypes (`Brushwalk`, `Bubble Eats`, `Fancy Cookout`, `Free Chat`, `Ice Brawl`, `Stag Hunt`, `Tag`, `Warzone`, `Overworld`) that **are ABSENT from this tree** — README is stale.

## How a game plugs into the shared engine (extension points)

A game is **a Docker container that is an HTTP+WebSocket server**. There is no plugin/registration API. The contract, in order:

1. Depend on `bitworld` via Nimble (`bitworld.nimble`), import `bitworld/runtime`, `bitworld/spriteprotocol`, `bitworld/replays`, `bitworld/client`, `bitworld/server`.
2. Call `readRuntimeConfig()` (`src/bitworld/runtime.nim:279`) to absorb env vars + CLI.
3. Serve the endpoints listed in §3.
4. Emit `results.json` via `writeResults()` (`runtime.nim:399`) and a `.bitreplay` via `writeReplay()` (`runtime.nim:408`).
5. Ship a `coworld_manifest.json` declaring `config_schema` / `results_schema` / `protocols` / `variants` / `certification`.
6. Pass `coworld_certify` (`tools/coworld_certify.nim` → `games_server/cogame_validator.nim`).

---

# 2. COWORLD PACKAGING

## What is ABSENT from this repo

- **`compose.yaml` / `docker-compose.*`: ABSENT.**
- **`Dockerfile` (any): ABSENT.** (`find . -iname 'Dockerfile*'` → nothing. `README.md:196-217` and `docs/quick_run.md` reference `among_them/Dockerfile`, `stag_hunt/Dockerfile` — those directories do not exist here.)
- **`AGENTS.md` / `CLAUDE.md`: ABSENT.**
- **`.github/` / any CI: ABSENT.**
- **`cogs_vs_clips` manifest: ABSENT.** The string `cogs_vs_clips` appears in *exactly one file* — `.claude/skills/games-cli/SKILL.md` (lines 3, 26, 28, 32, 33, 44, 68). There is no `games_server/games/cogs_vs_clips/`. The skill documents a manifest that must be uploaded at runtime via `POST /uploads/game` (see below). **I cannot quote its manifest — it does not exist in this repo.**
- Any `*.yml`/`*.yaml`: ABSENT.

## What IS there

### Manifest schema

All 8 game manifests declare:
```json
"$schema": "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/coworld/src/coworld/coworld_manifest_schema.json"
```
The authoritative schema lives in the **metta** repo, not here. This repo re-implements validation in `games_server/cogame_validator.nim:582-618` (`validateCoworldManifest`).

Required top-level shape enforced by `validateCoworldManifest`:
- `game` (object) → requires `name`, `version`, `description`, `owner`, image, `config_schema` (object), `results_schema` (object), `protocols` (object); `run` command optional at game level (`cogame_validator.nim:568-579`).
- `player` (non-empty array) → each requires `id`, `name`, image, `run`, `description` (`:538-552`).
- `variants` (non-empty array) → each requires `id`, `name`, `description`, `game_config` (`:554-566`).
- Optional arrays validated the same way: `grader`, `reporter`, `commissioner`, `diagnoser`, `optimizer` (`:597-600`).
- `certification` (object) → requires `players[]` each with `player_id` (+ optional `initial_params` object), and **either** `variant_id` **or** `game_config` (`:602-618`).

### Verbatim manifest — jumper (smallest complete game manifest, v2 Coworld shape)

`games_server/games/jumper/coworld_manifest.json:1-30`:
```json
{
  "$schema": "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/coworld/src/coworld/coworld_manifest_schema.json",
  "game": {
    "name": "jumper",
    "version": "0.1.0",
    "description": "A cooperative BitWorld platformer where players cross pits, stack on each other, and reach the flag.",
    "owner": "treeform@softmax.com",
    "runnable": {
      "type": "game",
      "image": "public.ecr.aws/s3j4p9s7/treeform/games/jumper:latest",
      "run": ["/bin/jumper"]
    },
    "config_schema": {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "tokens"
      ],
      "properties": {
        "tokens": {
          "description": "One connection token per player slot, indexed by slot.",
          "type": "array",
          "minItems": 0,
          "maxItems": 16,
          "items": {
            "type": "string",
            "minLength": 0
          },
          "default": []
        },
```
…and its non-game sections (`:93-158`):
```json
  "player": [
    {
      "id": "dalli",
      "name": "dalli",
      "type": "player",
      "description": "Coworld player for jumper.",
      "image": "public.ecr.aws/s3j4p9s7/treeform/players/dalli:latest",
      "run": ["/bin/dalli"]
    }
  ],
  "reporter": [
    {
      "id": "default-reporter",
      "name": "Default Reporter",
      "type": "reporter",
      "description": "Default Coworld reporter for generic episode artifacts.",
      "image": "public.ecr.aws/q5f4m8t9/cogames@sha256:396e56a9ba1576aecc5b9868a85fa309ea98fdbbf8d656c94ec021906197ea52"
    }
  ],
  "grader": [
    {
      "id": "bitworld-score-grader",
      "name": "BitWorld Score Grader",
      "type": "grader",
      "description": "Generic BitWorld grader that scores episode interest from score spread and game-specific activity signals.",
      "source_url": "https://github.com/Metta-AI/graders/tree/main/graders/bitworld_score/bitworld_score_grader",
      "image": "ghcr.io/metta-ai/graders-bitworld-score:latest"
    }
  ],
  "variants": [
    {
      "id": "freeplay",
      "name": "Freeplay",
      "game_config": {
        "seed": 727920,
        "maxTicks": 0,
        "maxGames": 0
      },
      "description": "Open-ended Jumper configuration for local player testing."
    },
    {
      "id": "smoke",
      "name": "Smoke",
      "game_config": {
        "seed": 727920,
        "maxTicks": 300,
        "maxGames": 0
      },
      "description": "Short deterministic Jumper configuration used for manifest checks."
    }
  ],
  "certification": {
    "game_config": {
      "seed": 727920,
      "maxTicks": 300,
      "maxGames": 0
    },
    "players": [
      { "player_id": "dalli" },
      { "player_id": "dalli" }
    ]
  }
}
```

`among_them` (the "v1 bitworld" the skill mentions) is the *only* manifest whose `protocols.player` is `bitscreen_v1.md`; it also carries the full 6-section role stack (`commissioner`, `reporter`, `grader`, `diagnoser`, `optimizer`) — `games_server/games/among_them/coworld_manifest.json:328-337, 508-557`:
```json
    "protocols": {
      "player": {
        "type": "uri",
        "value": "https://github.com/Metta-AI/bitworld/blob/master/docs/bitscreen_v1.md"
      },
      "global": {
        "type": "uri",
        "value": "https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md"
      }
    },
```

### Player manifest (v1 `coplayer_manifest.json`) — verbatim

`games_server/players/nottoodumb/coplayer_manifest.json`:
```json
{
  "author": "treeform@softmax.com",
  "name": "nottoodumb",
  "description": "Compact deterministic baseline Among Them visual player.",
  "image_uri": "ghcr.io/treeform/bitworld-nottoodumb:latest",
  "games": [
    "among_them"
  ],
  "run": [
    "/bin/nottoodumb"
  ]
}
```
(Two players use `"binary": "/bin/..."` instead of `"run": [...]` — `talking_villager`, `villager`. `games_server/games_server.nim:675` `manifestRunCommand` handles both.)

### Certify script

`tools/coworld_certify.nim` (182 lines) → `games_server/cogame_validator.nim` (1821 lines). `tools/cogame_certify.nim` is a 1-line `include coworld_certify`.

Usage (`tools/coworld_certify.nim:25-41`, verbatim):
```
Usage:
  coworld_certify [options] <game-or-manifest>

Options:
  --timeout:<seconds>     Docker and endpoint timeout. Default: 60.
  --workspace:<path>      Artifact workspace. Default: bitworld/tmp.
  --docker:<path>         Docker command. Default: docker or env override.
  --skip-images           Skip Docker image inspect checks.
  --no-run                Certify manifest and write config only.
  --help                  Show this help.

Examples:
  coworld_certify among_them --no-run
  coworld_certify crewrift --skip-images
  coworld_certify games_server/games/planet_wars/coworld_manifest.json
```

**Certification criteria ids** (emitted as `[PASS|FAIL|SKIP] <id>`): `manifest.read`, `manifest.kind`, `manifest.schema`(via `coworld.manifest`), `certification.references`, `referenced.files`, `docker.images`, `artifacts.workspace`, `config.schema`, `episode.request`, `docker.port`, `docker.episode`, `results.schema`, `replay.artifact` (`cogame_validator.nim:889-1010, 1531-1700`).

**Certification episode Docker invocation — verbatim** (`cogame_validator.nim:1367-1379`):
```nim
  result.add(spec.cogameImage)
  for token in spec.cogameCommand:
    result.add(token)
  result.add("--host:0.0.0.0")
  result.add("--port:" & $spec.containerPort)
  result.add("--config-path:" & ContainerWorkDir & "/config.json")
  result.add("--results-uri:file://" & ContainerWorkDir & "/results.json")
  result.add("--save-replay-uri:file://" & ContainerWorkDir & "/replay.json")
  result.add("--log-uri:file://" & ContainerWorkDir & "/logs/game-runtime.log")
```
with `ContainerWorkDir = "/coworld"` (`:13`), bind-mounted from the host workspace (`:1360-1362`).

**Player container in certification** (`:1400-1410`):
```nim
  result = @[
    "--name", name,
    "--add-host", "host.docker.internal:host-gateway",
    "-e", EngineWsEnv & "=" & playerWsUrl(
      "host.docker.internal",
      port,
      slot,
      token,
      player
    )
  ]
```

**Endpoints certification requires** (`runCogameEpisode`, `:1419-1520`): `GET /healthz` 200; `GET /player?slot=0&token=<t>` 2xx; `ws:///player?...&token=bad` must be **rejected**; `GET /global` 2xx; `GET /admin` 2xx; `WS /global` yields ≥1 non-empty message; `WS /admin` yields ≥1 non-empty message; game container exits 0; then replay container: `GET /healthz`, `GET /client/replay?uri=file://...`, `WS /replay?uri=file://...` yields a message.

### Build tooling
`tools/docker_build.nim` (794 lines) — wraps `docker buildx` for multi-arch (`DefaultPlatforms = "linux/amd64,linux/arm64"`, `:26`); it *finds* Dockerfiles beside manifests in sibling `cogame-*` repos, it does not contain any.
`tools/publish_packages.mjs` — flips ghcr.io packages public.

---

# 3. PLAYER PROTOCOL

## Transport & endpoints

WebSocket, **binary** messages. Default game port **8080** (`src/bitworld/runtime.nim:7` `RuntimeDefaultPort = 8080`; `src/bitworld/spriteprotocol.nim:15` `DefaultPort* = 8080`; `games_server/games_server.nim:55` `GameContainerPort = 8080`). Orchestrators: games_server **2080**, tournament_server **2081**, multi_server **2082**.

WebSocket paths (`docs/tools.md:8-44`, `cogame_validator.nim:16-20`):

| Path | Protocol |
|---|---|
| `/player` | Bitscreen v1 **or** Sprite v1 (per manifest `protocols.player`) |
| `/global` | Sprite v1 |
| `/replay` | Sprite v1 (accepts `?uri=`) |
| `/reward` | Reward v1 (**text** messages) |
| `/admin` | Sprite v1 + admin control |

HTTP client pages (`src/bitworld/client.nim:6-30`), both singular v1 and plural v2 forms:
```nim
  PlayerClientRoute* = "/client/player"
  GlobalClientRoute* = "/client/global"
  AdminClientRoute* = "/client/admin"
  RewardClientRoute* = "/client/reward"
  ...
  CoworldPlayerClientRoute* = "/clients/player"
  CoworldGlobalClientRoute* = "/clients/global"
  CoworldReplayClientRoute* = "/clients/replay"
  CoworldAdminClientRoute* = "/clients/admin"
  CoworldRewardClientRoute* = "/clients/rewards"
```
Plus `GET /healthz`. Health body: *"v1 games return body `healthy`; v2 games return `{"ok":true}`. Either is fine."* — `games_server/games_server.nim:2499`.

## Join query parameters

`docs/bitscreen_v1.md:12-29` (verbatim):
```text
/player?name=player1&slot=0&token=0xBADA55
```
> `name` is an optional player identity. Servers that support rewards or global display should use this value instead of the network address when naming the player. The value is URL decoded by the server. It must not contain spaces after server normalization.
>
> `slot` is an optional zero-based player slot. A server may use it to assign a stable color, start position, and configured role. If the slot is missing, the server assigns the first valid open slot.
>
> `token` is an optional basic join secret. Servers may check it against their game config before accepting the websocket. A player whose configured name or token does not match should be disconnected.

## Protocol version strings

There is **no version string on the wire.** Versioning is by (a) doc filename referenced in `protocols` (`bitscreen_v1.md` / `sprite_v1.md` / `reward_v1.md`), and (b) the replay header's `Format version = 3`. Message-type bytes are the de-facto discriminators.

## Bitscreen v1 — full message list

**Server → client** (only one message): screen frame, exactly **8192 bytes**.
`docs/bitscreen_v1.md:37-52`:
> | Field | Type | Notes |
> | Pixels | `u8[]` | `128 * 128 / 2` bytes |
>
> The screen is always `128x128` pixels. Each pixel is a 4 bit color index into the Pico-8 palette, so each byte stores two pixels:
>
> | Bits | Pixel |
> | `0 .. 3` | Left pixel |
> | `4 .. 7` | Right pixel |
>
> Pixels are stored left to right, then top to bottom. A complete frame is `8192` bytes.
> The server usually sends frames at `24hz`…

**Client → server:**
```text
| Kind | Name    | Notes                     |
| `0`  | Buttons | Current controller state   |
| `1`  | Chat    | ASCII chat message        |
```
Button packet — 2 bytes: `[0x00, mask]`. Chat packet — `[0x01, ...ascii]`.

Bit masks (`docs/bitscreen_v1.md:101-110`, matching `src/bitworld/spriteprotocol.nim:20-26`):
```
| Bit | Mask | Button |
| `0` | `0x01` | Up |
| `1` | `0x02` | Down |
| `2` | `0x04` | Left |
| `3` | `0x08` | Right |
| `4` | `0x10` | Select |
| `5` | `0x20` | A |
| `6` | `0x40` | B |
| `7` | `0x80` | Reserved |
```

Disambiguation rule (`docs/bitscreen_v1.md:133-141`, verbatim):
> A server-to-client binary message with length `8192` is a screen frame.
> A client-to-server binary message with length `2` and first byte `0` is a button packet.
> A client-to-server binary message with first byte `1` is a chat packet.
> Other binary messages should be ignored. Text websocket messages are not used by this protocol.

## Sprite v1 — full message list

`src/bitworld/spriteprotocol.nim:27-38` (verbatim):
```nim
  SpriteMessageSprite* = 0x01'u8
  SpriteMessageObject* = 0x02'u8
  SpriteMessageDeleteObject* = 0x03'u8
  SpriteMessageClearObjects* = 0x04'u8
  SpriteMessageViewport* = 0x05'u8
  SpriteMessageLayer* = 0x06'u8
  SpriteClientChat* = 0x81'u8
  SpriteClientMouseMove* = 0x82'u8
  SpriteClientMouseButton* = 0x83'u8
  SpriteClientInput* = 0x84'u8
  SpriteClientReady* = 0x85'u8
  SpriteClientDebugSprite* = 0x86'u8
```

Exact wire shapes (`docs/sprite_v1.md`; all multi-byte fields little-endian):

**0x01 Define Sprite** — `u8 type | u16 spriteId | u16 width | u16 height | u32 compressedLen | u8[] snappyPixels | u16 labelLen | u8[] label`. Decompressed payload must be exactly `Width*Height*4`, RGBA unpremultiplied.
**0x02 Define Object** — `u8 type | u16 objectId | i16 x | i16 y | i16 z | u8 layer | u16 spriteId` (12 bytes).
**0x03 Delete Object** — `u8 type | u16 objectId` (3 bytes).
**0x04 Clear Objects** — `u8 type` (1 byte). *"Sprite definitions remain loaded."*
**0x05 Set Viewport** — `u8 type | u8 layer | u16 width | u16 height` (6 bytes).
**0x06 Define Layer** — `u8 type | u8 layer | u8 kind | u8 flags` (4 bytes).

Layer kinds/flags (`docs/sprite_v1.md:126-146`, mirrored `spriteprotocol.nim:39-50`):
```
| `0x00` | Map zoomable layer |     | `0x05` | Center top UI layer |
| `0x01` | Top left UI layer |      | `0x06` | Center right UI layer |
| `0x02` | Top right UI layer |     | `0x07` | Center left UI layer |
| `0x03` | Bottom right UI layer |  | `0x08` | Center bottom UI layer |
| `0x04` | Bottom left UI layer |   | `0x09` | Full screen layer |
Flags: `0x01` Zoomable, `0x02` UI
```

**0x81 Input Text** — `u8 type | u16 len | u8[] ascii`. Control codes: `0x08` Backspace, `0x09` Tab, `0x0a` Enter, `0x1b` Escape.
**0x82 Mouse Position** — `u8 type | i16 x | i16 y | u8 layer`.
**0x83 Mouse Button** — `u8 type | u8 code | u8 down` (`0x01` left, `0x02` right, `0x03` middle).
**0x84 Player Input** — `u8 type | u8 buttons` (2 bytes; bit 7 reserved, must be 0). Encoder: `blobFromSpriteMask` masks with `0x7f` (`spriteprotocol.nim:462-466`).
**0x85 Player Ready** — `u8 type` (1 byte). Docs: *"Servers may use this packet as an optional frame pacing hint. A server should still advance at its normal frame rate when not all players send ready packets before the frame deadline."*
**0x86 Debug Sprites** — `u8 type | u32 packetLen | u8[] spritePacket` (payload is nested server→client Sprite v1 messages). *"Debug sprites are diagnostic data. They should not affect deterministic game state, scoring, or player input."*

Reserved: `0x00`, `0x07..0x7f`, `0x87..0xff`.

Draw ordering rule (`docs/sprite_v1.md:320-324`, verbatim):
> Objects with lower `z` values are drawn first. If two objects have the same `z`, the object with the lower `y` value is drawn first. If two objects have the same `z` and `y`, the object with the lower object id is drawn first.

## Reward v1

Text WebSocket, one message per simulation tick, newline-separated lines of `<name> <player> <value>` (base-10 integer). `reward` is mandatory per player per tick. Stable extra names emitted by Among Them (`docs/reward_v1.md:56-68`): `wins_imposter`, `wins_crewmate`, `games_imposter`, `games_crewmate`, `kills`, `tasks`, `vote_players`, `vote_skip`, `vote_timeout`, `connect_timeout`, `disconnect_timeout`. Binary messages invalid; client→server unused.

## How a baseline player connects and acts

**`players/baseline/baseline.nim`: ABSENT.** There is no bot source of any kind in this repo — every bot is an opaque image reference in a `coplayer_manifest.json`.

**How bots are wired:** a single env var, `COGAMES_ENGINE_WS_URL`, carries the full player WebSocket URL including credentials. Set in 5 places: `src/bitworld/multiruns.nim:37,1000`, `games_server/ecs_backend.nim:23,426`, `games_server/cogame_validator.nim:21,1403`, `games_server/games_server.nim:72,2471`, `games_server/tournament_server.nim:43,1257`, `tools/start_all_games.nim:50,627`.

URL construction — `src/bitworld/multiruns.nim:840-845` (verbatim):
```nim
proc playerWsUrl*(port: int, slot: PlayerSlot): string =
  ## Builds the bot websocket URL for one player slot.
  "ws://" & BotHost & ":" & $port & "/player?name=" &
    encodeUrlComponent(slot.playerName) & "&slot=" & $slot.slotIndex &
    "&token=" & encodeUrlComponent(slot.token)
```
(`BotHost* = "host.docker.internal"`, `multiruns.nim:44`.)

**The nearest in-repo "main loop"** is the native human client. `client/player_client.nim:756-778` (verbatim):
```nim
proc runClientLoop*(
  address = DefaultPlayerAddress,
  clientOptions = ClientOptions()
) =
  var
    client = initClient(address, clientOptions)
    lastTick = getMonoTime()

  while client.windowOpen:
    pollEvents()
    pollNetwork()
    client.refreshDisplayScale()
    if client.window.buttonPressed[KeyEscape]:
      if client.chatActive():
        client.closeChat()
      else:
        client.window.closeRequested = true

    let inputMask = client.captureInputMask()
    client.tickNetwork(inputMask)
    pollNetwork()
    client.drawFramebuffer()
    runFrameLimiter(lastTick)

  client.shutdownClient()
```
With the network side, `client/player_client.nim:664-678` (verbatim):
```nim
proc tickNetwork(client: ClientApp, inputMask: uint8) =
  client.network.desiredMask = inputMask
  if not client.network.connected:
    if client.network.reconnectDelayMilliseconds <= 0:
      return
    let elapsed =
      (getMonoTime() - client.network.lastConnectAttemptAt).inMilliseconds
    if not client.network.connecting and
      elapsed >= client.network.reconnectDelayMilliseconds:
        client.connectNetwork()
    return
  if inputMask == client.network.lastSentMask:
    return
  client.network.ws.send(blobFromMask(inputMask), BinaryMessage)
  client.network.lastSentMask = inputMask
```
and frame intake, `client/player_client.nim:393-399` (verbatim):
```nim
  ws.onMessage = proc(msg: string, kind: WebSocketMessageKind) =
    if client.network.ws != ws:
      return
    if kind == BinaryMessage and msg.len == ProtocolBytes:
      blobToBytes(msg, client.network.latestFrame)
      client.network.hasFrame = true
      inc client.network.frameSerial
```
Note: **input is sent only on change** (edge-triggered), not per tick.

---

# 4. TALK / CHAT

Agent-to-agent talk is **first-class in the protocol and replay format, but every semantic (range, audience, cooldown) is game-side and therefore ABSENT here.**

**Wire support:**
- Bitscreen v1 chat packet, kind `1` — `spriteprotocol.nim:12` `PacketChat* = 1'u8`; builders/parsers at `:175-199` (`isChatPacket`, `blobFromChat`, `blobToChat`). `blobToChat` filters to printable ASCII `0x20..0x7e`.
- Sprite v1 `0x81` — named **`SpriteClientChat`** in code (`spriteprotocol.nim:33`) but **"Input Text"** in `docs/sprite_v1.md:159`. Same byte, two names. Builder `blobFromSpriteChat` (`:473-480`), parser `parseSpriteClientMessages` case at `:509-522`, convenience reader `readSpriteInputText` (`:571-575`).
- `SpriteClientChatMessage` enum variant, `SpriteClientMessage.text` field (`:91, :100`).

**Replay support:** `ReplayChatRecord* = 0x05'u8` (`src/bitworld/replays.nim:84`); `ReplayChat = object time, player, message` (`:52-55`); writer `writeChat` (`:313-325`); parser (`:446-457`) gated on `ReplaySpec.allowChat` — games may forbid chat records outright (`raise ... "Replay chat record is not supported"`, `:448`).

**Client-side chat UX:** `client/player_client.nim` has a full on-screen chat composer — `ChatState` (`:80-83`), `ChatMaxChars = 48` (`:56`), `openChat`/`closeChat`/`submitChat`/`queueChatRune`/`deleteChatChar` (`:157-183`). `submitChat` sends `blobFromChat(...)` as `BinaryMessage`. `client/global_client.html:589-628` has the Sprite v1 equivalent (`startTyping`/`stopTyping`/`sendInputText`).

**Game-side chat config knobs** (in manifests, so implemented in the external game): `messageCooldownTicks` (default `100`) in `among_them` and `crewrift`.

**LLM-driven talkers:** `src/bitworld/ais/{claude,openai,gemini,xai,bedrock}.nim` all export `talkToAI*(messages: var seq[ConversationMessage]): string`. Key env vars forwarded to containers: `AiKeyEnvNames = ["CLAUDE_KEY", "GEMINI_KEY", "OPENAI_KEY", "XAI_KEY"]` (`games_server/games_server.nim:70`, `multiruns.nim:46`, `cogame_validator.nim:22`). Talking bots in the manifests: `italkalot` ("LLM-guided Among Them player that talks and votes"), `talking_villager` ("LLM-guided Heartleaf bot that gathers food, talks to players, invites guests, and honors party commitments"), `coilbot`.

**Broadcast / say / speak keywords:** no dedicated broadcast primitive exists. `blobFromBytes` → `websocket.send(...)` fan-out to all viewers is the only "broadcast" (`global_ui/global_ui.nim:260-278`).

---

# 5. OBSERVATION ENCODING

An agent observes **rendered pixels**, not a structured world state. There is no grid-layer tensor, no entity list, no token stream anywhere in this repo.

## Mode A — Bitscreen v1 (raw pixels)

Per tick the agent receives exactly one binary message of **8192 bytes** = 128×128 4-bit palette indices, two pixels per byte (low nibble = left pixel). Constants, `src/bitworld/spriteprotocol.nim:7-10`:
```nim
  ScreenWidth* = 128
  ScreenHeight* = 128
  TileSize* = 6
  ProtocolBytes* = (ScreenWidth * ScreenHeight) div 2
```
Server-side struct, `src/bitworld/server.nim:16-18`:
```nim
  Framebuffer* = object
    indices*: seq[uint8]
    packed*: seq[uint8]
```
`initFramebuffer` allocates `indices` = 16384 bytes, `packed` = 8192 bytes (`:108-110`). Packing, `:221-226`:
```nim
proc packFramebuffer*(fb: var Framebuffer) =
  for i in 0 ..< fb.packed.len:
    let lo = fb.indices[i * 2] and 0x0F
    let hi = fb.indices[i * 2 + 1] and 0x0F
    fb.packed[i] = lo or (hi shl 4)
```
Palette = Pico-8, 16 entries, loaded from the embedded `client/data/pallete.png` (`spriteprotocol.nim:51, 108-123`). Index `255` = `TransparentColorIndex` (server-side only, `server.nim:21`).

## Mode B — Sprite v1 (retained-mode scene graph, RGBA)

The agent receives *deltas* and maintains three tables. `docs/sprite_v1.md:313-318` (verbatim):
> | State | Key | Value |
> | Layers | `u8 layer id` | Type, flags, viewport width, and viewport height |
> | Sprites | `u16 sprite id` | Width, height, label, and RGBA pixel buffer |
> | Objects | `u16 object id` | X, y, z, layer, and sprite id |

Decoded shapes, `src/bitworld/spriteprotocol.nim:68-88` (verbatim):
```nim
  SpritePacketSpriteDef* = object
    id*, width*, height*: int
    compressedPixels*: seq[uint8]
    label*: string

  SpritePacketObject* = object
    id*, x*, y*, z*, layer*, spriteId*: int

  SpritePacketViewport* = object
    layer*, width*, height*: int

  SpritePacketLayer* = object
    layer*, kind*, flags*: int
```
Sizes: sprite ids and object ids are `u16` (≤65535 each); coordinates are `i16` (`-32768..32767`) *"so objects and pointer positions can be placed outside the visible viewport"*; layer ids are `u8`; sprite pixels are `Width*Height*4` bytes after Snappy decompression, **unbounded** in size (viewports in the reference server are 512×512 map + 128×128 UI, `global_ui/global_ui.nim:9-12`). Sprite `label` is explicitly non-rendering metadata: *"Labels are for tooling, debugging, and human inspection."* — an agent can read semantic names off it.

## Fog of war / visibility

**No fog/vision system exists in this repo.** Grep for `fog`, `vision`, `visibility`, `lineOfSight` → zero hits in `*.nim`.

The architectural handling is: **visibility is baked into what the server renders per socket.** `docs/sprite_v1.md:272-274` describes `/player` as *"player endpoints that render a private observation view"*. Each player socket gets its own rendered stream; the game decides what to draw. There is no client-side culling contract beyond viewport clipping (`docs/sprite_v1.md:326-329`):
> Objects outside their layer viewport are clipped. Pixels with layer coordinates less than `0`, greater than or equal to the layer viewport width, or greater than or equal to the layer viewport height are not drawn.

## Agent-authored annotations

Agents can push overlays back: `0x86` Debug Sprites (client→server), recorded as replay record `0x06`. They must not affect the deterministic hash.

---

# 6. CONFIG INTAKE

## Env vars (the Coworld contract)

`src/bitworld/runtime.nim:8-14` (verbatim):
```nim
  CogameConfigUriEnv* = "COGAME_CONFIG_URI"
  CogameResultsUriEnv* = "COGAME_RESULTS_URI"
  CogameSaveReplayUriEnv* = "COGAME_SAVE_REPLAY_URI"
  CogameLoadReplayUriEnv* = "COGAME_LOAD_REPLAY_URI"
  CogameLogUriEnv* = "COGAME_LOG_URI"
  CogameHostEnv* = "COGAME_HOST"
  CogamePortEnv* = "COGAME_PORT"
```
Defaults: `RuntimeDefaultHost = "0.0.0.0"`, `RuntimeDefaultPort = 8080` (`:6-7`). Player containers get `COGAMES_ENGINE_WS_URL`. AI keys: `CLAUDE_KEY`, `GEMINI_KEY`, `OPENAI_KEY`, `XAI_KEY`.

URI schemes supported for all `*_URI` vars: `file://<path>` and `http(s)://` (`readCogameUri` :97-123 via `curly`; `writeCogameUri` :193-226 does an HTTP **PUT** with a `Content-Type` header). Anything else with `://` raises `unsupported URI from <source>`.

## CLI args

`src/bitworld/runtime.nim:32-54` — the canonical help text (verbatim):
```
Coworld runtime options:
  --host:<host>              Bind host. Env: COGAME_HOST.
  --port:<port>              Bind port. Env: COGAME_PORT.
  --config:{json}            Inline JSON config text.
  --config-path:<path>       Read JSON config from a local path.
  --config-uri:<uri>         Read JSON config from file/http/https URI.
                             Env: COGAME_CONFIG_URI.
  --results:<path>           Write results to a local path.
  --results-uri:<uri>        Write results to file/http/https URI.
                             Env: COGAME_RESULTS_URI.
  --save-replay:<path>       Write replay to a local path.
  --save-replay-uri:<uri>    Write replay to file/http/https URI.
                             Env: COGAME_SAVE_REPLAY_URI.
  --load-replay:<path>       Read replay from a local path.
  --load-replay-uri:<uri>    Read replay from file/http/https URI.
                             Env: COGAME_LOAD_REPLAY_URI.
  --log:<path>               Write log to a local path.
  --log-uri:<uri>            Write log to file/http/https URI.
                             Env: COGAME_LOG_URI.
  --mismatch-quit            Raise on replay hash mismatch.
  --help, -h                 Show this help.
```
`RuntimeConfig` struct (`:19-28`):
```nim
  RuntimeConfig* = object
    host*: string
    port*: int
    config*: string
    resultsUri*: string
    replayUri*: string
    replay*: string
    logUri*: string
    replayMode*: bool
    mismatchQuit*: bool
```
**Precedence:** CLI wins; env is only consulted when the matching flag was not set (`readRuntimeConfig` :375-397). Unknown long options **raise** (`:362`), as do bare arguments (`:371`).

Older doc-level top-level fields still honored by some games (`docs/tools.md:70-79`): `address`, `port`, `saveReplay`, `loadReplay`, `saveReplayPath`, `loadReplayPath`.

## Config schema/fields

Per-game via manifest `config_schema` (JSON Schema draft 2020-12, `additionalProperties: false`). Universal field: **`tokens`** — `"One connection token per player slot, indexed by slot."`, array of strings, `maxItems: 16`, and **`required`** in all 8 manifests. Near-universal: `seed`, `maxTicks`, `maxGames`. Full per-game field inventory:

- `jumper` / `big_adventure` / `heartleaf` / `infinite_blocks`: `tokens, seed, maxTicks, maxGames`
- `asteroid_arena`: `tokens, seed, duration`
- `planet_wars`: `tokens, seed, planetCount, maxTicks, maxGames`
- `among_them`: `tokens, slots, closedRoster, seed, minPlayers, imposterCount, autoImposterCount, tasksPerPlayer, buttonCalls, startWaitTicks, voteTimerTicks, voteResultTicks, killCooldownTicks, roleRevealTicks, taskCompleteTicks, messageCooldownTicks, gameOverTicks, maxTicks, maxGames, killRange, ventRange, reportRange, showTaskArrows, showTaskBubbles, showPlayerLabels, mapPath`
- `crewrift`: same as among_them **plus** `players` (required), `connectTimeoutTicks`, `disconnectTimeoutTicks`

The in-repo JSON-Schema validator is a partial implementation: `validateJsonSchema` handles `type`, `properties`, `required`, `additionalProperties`, `items`/`minItems`/`maxItems`, `minLength`/`maxLength`, `minimum`/`maximum`, `enum`, `allOf` (`cogame_validator.nim:426-536`). No `oneOf`/`anyOf`/`$ref`/`pattern`.

## Seed handling & determinism

**Where seeds are generated (the determinism weak points):**

1. **`src/bitworld/multiruns.nim:801` — wall clock into the seed:**
   ```nim
   node["seed"] = %int(epochTime() * 1000)
   ```
   `buildGameConfigJson` unconditionally overwrites any manifest/variant seed with a millisecond wall-clock value. Multi-runs are therefore **not reproducible** unless you supply the config out-of-band.
2. **`games_server/tournament_server.nim:1123` — global RNG:**
   ```nim
   node["seed"] = %rand(1_000_000_000)
   ```
   seeded by `randomize()` at `tournament_server.nim:2424` (i.e. wall-clock-derived). Also `:1157` (`$rand(1_000_000_000)`), and weighted player selection at `:1350-1351`.
3. **`games_server/games_server.nim` (web UI path)** — takes seed from the form or from `variantDefaults()` (first variant's `game_config`), so the manifest seed is preserved. `configJson` :2236-2285.
4. **`tools/quick_run.nim`** — `--seed:N` (`parseSeed` :152, must be ≥ `-1`), merged last into the inline config (`mergedConfigJson` :1126-1150).
5. **Certification** — uses the manifest's `certification.game_config` / variant verbatim, so it is deterministic by construction (`buildGameConfig` :1035-1045).

**Tokens** are always CSPRNG (`std/sysrand.urandom`, 16 bytes hex): `multiruns.nim:369-377`, `games_server.nim:2199-2206`, `cogame_validator.nim:1004-1008`. Tokens do not enter the sim.

**Where RNG lives:** there is **no simulation RNG in this repo at all**. `std/random` is imported only by `tournament_server.nim`. Games are expected to own their PRNG, keyed on `config.seed`.

**Other nondeterminism to watch:**
- `src/bitworld/replays.nim:249` writes `toUnix(getTime()) * 1000` into the replay header — but the spec explicitly neutralizes it: *"`Start time` is informational. The simulation must use input timestamps relative to the start of the game, not wall clock time."* (`docs/bitreplay_spec.md:53-54`).
- Unordered `Table` iteration over viewers in `global_ui/global_ui.nim:257-258` — affects send order only, not sim state.
- The spec's own rule (`docs/bitreplay_spec.md:93-96`): *"The hash must be calculated from deterministic game state only. It must not include wall clock time, renderer state, socket state, allocation addresses, or other process-local data."*
- `--mismatch-quit` (`runtime.nim:351`) is the opt-in strict mode; by default a hash mismatch does not abort.

## Runtime config injection paths (how a container actually gets its config)

Four distinct wirings exist:

| Launcher | `COGAME_CONFIG_URI` value |
|---|---|
| `cogame_validator` certification | *not used* — passes `--config-path:/coworld/config.json` from a bind mount (`:1373`) |
| `multi_run` | `file:///replays/<name>.config.json` via `-v <runDir>:/replays` (`multiruns.nim:884-887`) |
| `games_server` (local) | `file:///replays/<replay>.config.json` via `-v <replayDir>:/replays` (`games_server.nim:2373-2381`) |
| `games_server` (with `GAMES_SERVER_URL`) | `http://<host>:2080/api/replay/download/<replay>.config.json` (`games_server.nim:2351-2357`) |
| `games_server --ecs` | presigned S3 GET from bucket `bitworld-game-configs` (`container_backend.nim:33`) |

---

# 7. EPISODE OUTPUTS

## Replay format — `.bitreplay`, format version 3

Spec: `docs/bitreplay_spec.md`. Writer/parser: `src/bitworld/replays.nim`.

**File layout:** `Header | Initial config (string) | Record[]`.

**Header** (`docs/bitreplay_spec.md:42-48`, verbatim):
```
| Magic | `u8[8]` | ASCII `BITWORLD` |
| Format version | `u16` | Must be `3` |
| Game name | `string` | Name of the game |
| Game version | `string` | Version of the game |
| Start time | `u64` | Milliseconds since Unix epoch, or `0` |
```
Strings = `u16` byte-length prefix + UTF-8 bytes, not null-terminated. Loader must reject on name/version mismatch (`replays.nim:393-396`).

**Initial config** — a `string` containing UTF-8 JSON. `docs/bitreplay_spec.md:63-67`:
> A writer should store the complete effective config after applying defaults, config files, and command line config values. … Live config arguments must not change replay simulation behavior. A game with no configurable gameplay state should write `{}`.

**Record types** — `src/bitworld/replays.nim:79-86` (verbatim):
```nim
  ReplayTickHashRecord* = 0x01'u8
  ReplayInputRecord* = 0x02'u8
  ReplayJoinRecord* = 0x03'u8
  ReplayLeaveRecord* = 0x04'u8
  ReplayChatRecord* = 0x05'u8
  ReplayDebugSpriteRecord* = 0x06'u8
  ReplayClientInputRecord* = 0x07'u8
```
⚠️ **`0x07` is UNDOCUMENTED** — `docs/bitreplay_spec.md:74-81` stops at `0x06`, and `:234` says *"A record type is unknown"* is a rejection reason. `0x07` is the payload of the HEAD commit ("replay-client-input-records") and carries the **raw Sprite v1 client packet**: `u8 0x07 | u32 time | u8 player | u32 len | u8[] packet` (`replays.nim:341-353`, `ReplayClientInput` struct `:31-34`). **The doc is stale; treat `replays.nim` as authoritative.**

Bodies:
- `0x01` Tick hash: `u32 tick | u64 hash`. Must be strictly increasing; `ReplayHashOrder` (`rhoStop` / `rhoError`) selects whether backward ticks truncate or throw (`:412-419`).
- `0x02` Input: `u32 time(ms) | u8 player | u8 keys`. Note the spec's key bit order **differs from Bitscreen** — `docs/bitreplay_spec.md:124-133` lists `0x10`=A, `0x20`=B, `0x40`=Select, whereas `docs/bitscreen_v1.md:101-110` lists `0x10`=Select, `0x20`=A, `0x40`=B. **Conflicting; verify against the specific game before relying on it.**
- `0x03` Join: two encodings selected by `ReplaySpec.joinKind` — `rjkNameSlotToken` (`string name | i16 slot | string token`) or `rjkAddress` (`string address`). `readJoin` :364-375.
- `0x04` Leave: `u32 time | u8 player`.
- `0x05` Chat: `u32 time | u8 player | string message` (gated on `allowChat`).
- `0x06` Debug sprites: `u32 time | u8 player | u32 len | u8[] packet`.

**`ReplaySpec`** — the per-game dialect selector (`replays.nim:16-24`, verbatim):
```nim
  ReplaySpec* = object
    magic*: string
    formatVersion*: uint16
    gameName*: string
    gameVersion*: string
    joinKind*: ReplayJoinKind
    allowChat*: bool
    allowCompressed*: bool
    hashOrder*: ReplayHashOrder
```
`allowCompressed` lets a hosted artifact be gzip/zlib-wrapped; `replayPayloadBytes` :225-231 sniffs magic bytes and calls `zippy.uncompress`.

**Writer API:** `openReplayWriter` :233, `writeJoin` :264/:282, `writeLeave` :296, `writeInput` :304, `writeChat` :313, `writeDebugSprite` :327, `writeClientInput` :341, `writeHash` :355 (flushes after every tick hash), `closeReplayWriter` :252.
**Reader API:** `parseReplayBytes` :377, `loadReplay` :487.
**Tick↔time helpers:** `tickTime(tick, fps)` :88, `timeTick(time, fps)` :92.

**Playback:** `--load-replay` / `--load-replay-uri` puts the game in `replayMode`; it serves `/replay` (Sprite v1) and `/client/replay`. Certification exercises this (`cogame_validator.nim:1512-1520`). Orchestrator side: `createReplayGame` (`games_server.nim:2694-2765`) launches the **same game image** with `COGAME_LOAD_REPLAY_URI` set and mounts the replay dir read-only.

## Results / scores emission

Written to `COGAME_RESULTS_URI` (or `--results-uri`) with `Content-Type: application/json` (`runtime.nim:399-406`). Validated against manifest `results_schema` (`loadResults` :1526-1532).

**Canonical file names:** the certifier expects literally `results.json` (`createEpisodeArtifacts` :998); the games_server names it `<replay-basename>.scores.json` (`scoresName`, `games_server.nim:1822-1827`) and the config `<replay-basename>.config.json` (`configName` :1829-1834).

**Shape:** a JSON object of **parallel arrays indexed by player slot.** Known keys consumed by `tournament_server.nim:1561-1600` (`parseScores`):
```
names, scores, win, tasks, kills, imposters|imposter, crew,
vote_player|vote_players, vote_skip, vote_timeout,
connect_timeout, disconnect_timeout
```
Row count = max array length across all keys. Games may add arbitrary array columns — `games_server.nim:2190-2197` (`parseScoreTable`) renders any `JArray` key as a column, so extra stats surface in the UI for free.

Minimal contract (`asteroid_arena`'s `results_schema`, verbatim):
```json
    "results_schema": {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "names",
        "scores"
      ],
```
(`jumper` is the degenerate case: `"properties": {}` — no results required at all.)

## Artifact conventions & where outputs land

**Certifier workspace** (`cogame_validator.nim:985-1001`), rooted at `<repo>/tmp/coworld-cert-<unix>-<hex>/`:
```
config.json
results.json
replay.json          # note: .json extension, but it is bitreplay binary
logs/
  game.log
  game-runtime.log
  replay-runtime.log
  replay.log
  player_<slot>.log
```
**games_server:** `games_server/replays/` (env `GAMES_SERVER_REPLAY_DIR`), gitignored. Files: `<game>.bitreplay`, `<game>.scores.json`, `<game>.config.json`. Container mount point `/replays` (`ReplayMountDir`).
**multi_run:** `<replayRoot>/multi_runs/run_<N>/` with `run.json` + `game_<i>.json` metadata (`multiruns.nim:1067-1183`).
**HTTP artifact service** (`games_server/artifact_service.nim`): `PUT /api/replay/upload/<name>?token=<hmac>` and `GET /api/replay/download/<name>`. Token = SHA1 of secret+filename, secret from `GAMES_SERVER_UPLOAD_SECRET` or a `.upload_secret` file (32 random bytes).
**ECS/S3:** `bitworld-game-configs` (presigned GET) and `bitworld-replays` (presigned PUT, prefixes `replays/`, `results/`) — `container_backend.nim:33-34`.

---

# 8. SYSTEMS INVENTORY

| System | Status | Location |
|---|---|---|
| **Tick loop** | Present only as reference impl | `global_ui/global_ui.nim:248-281` (`while true` … `inc tick` … `runFrameLimiter`) |
| **Tick rate** | 24 Hz canonical | `global_ui/global_ui.nim:7` `TargetFps = 24.0`; `client/player_client.nim:55` `TargetFps = 24.0`; `client/reward_client.nim:7` `TargetFps = 24.0`; `client/global_client.nim:75` `TargetFps = 60.0` (viewer only). Doc: *"The server usually sends frames at `24hz`, but the protocol does not require a fixed frame rate."* (`docs/bitscreen_v1.md:52-54`). Frame limiters: `global_ui.nim:217-223`, `player_client.nim:749-754`, `global_client.nim:1108`, `reward_client.nim:166`. |
| **Movement** | ABSENT (only pathfinding *helpers*) | `src/bitworld/pathfinding.nim:36` `bfsNextStep`, `:118` `greedyStep`, `:130` `unstickStep`, `:142` `pathStep` — all return a `uint8` button mask, i.e. bot-side navigation, not server movement. `MapWidth*/MapHeight* = 32` hardcoded (`:4-5`). |
| **Projectiles** | **ABSENT** | zero hits for `projectile`/`bullet` |
| **Damage / HP / death** | **ABSENT** | zero hits for `damage`/`health`/`hp` in sim context (`HealthPath = "/healthz"` is container health only). Only trace: `big_adventure` results key `hearts`; `infinite_blocks` results key `alive`. |
| **Item pickups / inventory** | **ABSENT** | zero hits |
| **Fog of war / vision** | **ABSENT** | zero hits. Architectural answer: per-socket server-side rendering (`docs/sprite_v1.md:272-274`) + viewport clipping (`:326-329`). |
| **Map generation** | **ABSENT** | Map *loading* only: `src/bitworld/tiled.nim` (`loadTiledMap` :174, `loadTiledWorkspace` :254, `gidAt` :248), `src/bitworld/aseprite.nim` (tilemap layers/cels `:197-266`), `src/bitworld/resources.nim` (`parseResourceRects` :183). Manifest `mapPath` defaults: `"data/map.json"` (among_them), `"data/croatoan.resources"` (crewrift). Fixtures: `tests/data/jumper/forest.tmx`, `spritesheet.tsx`. |
| **Tile system** | Constant only | `spriteprotocol.nim:9` `TileSize* = 6`; letter/digit sprite strips are 6×6 (`server.nim:72, :85`). |
| **Sprites / rendering pipeline** | Present | **Indexed 4bpp:** `src/bitworld/server.nim` — `nearestPaletteIndex` :29, `spriteFromImage` :47, `sliceSpriteStrip` :55, `blitSprite` :121 (with 4-way `Facing` rotation), `blitSpriteTinted` :146, `blitText` :171/:182, `packFramebuffer` :221. **RGBA:** `src/bitworld/sprites.nim` — `solidRgbaSprite` :90, `outlineRgbaSprite` :101, `imageRgbaSprite` :117, `fillRect` :363, `strokeRect` :385, `drawLine` :404, `drawCircleFill` :458, `drawCircleRing` :482, `blitRgbaSprite` :505, `hsvTinted` :284. **Fonts:** `src/bitworld/pixelfonts.nim` (`decodePixelFont` :103, `readTiny5Font` :154, `textWidth` :159, `glyphScore` :246-292 — used for reading text off a rendered screen). **Client GPU:** `client/global_client.nim:160` `initRawRenderer` (GL 3.0 ES / GL 3.3 core shaders at :100-131). |
| **Replay recording + playback** | Present | Recording: `src/bitworld/replays.nim:233-362`. Parsing/playback data: `:377-489`. Playback container orchestration: `games_server/games_server.nim:2694-2765` (`createReplayGame`), `src/bitworld/multiruns.nim:903-957` (`replayDockerArgs`). Playback endpoints: `/replay` WS + `/client/replay` HTTP. Tests: `tests/test_replays.nim`. |
| **Networking / server** | **mummy** server-side, **whisky** + **windy** client-side | `bitworld.nimble:16-19` requires `mummy >= 0.4.7`, `curly >= 1.1.1`, `whisky >= 0.1.3`. `global_ui/global_ui.nim:228-233` `newServer(httpHandler, websocketHandler, workerThreads = 4, tcpNoDelay = true)`. `games_server.nim:4390` `newServer(httpHandler, workerThreads = 4)` on port 2080; `tournament_server.nim:2479` `workerThreads = 1` on 2081; `multi_server.nim:1425` `workerThreads = 1` on 2082. `whisky` is used by `cogame_validator.nim` (`newWebSocket` :1315) for certification probes; `curly` by `runtime.nim` for URI I/O; `windy`'s `openWebSocket` by the native clients (`player_client.nim:381`, `global_client.nim`). |
| **RNG** | **ABSENT for simulation** | Only `std/sysrand.urandom` (tokens/ids) and `std/random` in `tournament_server.nim` (matchmaking). See §6. |

---

# 9. ADJACENT MECHANICS ("anything resembling…")

## Freeze phases / countdowns / timers
Present **as config knobs only** (implemented in external game images). From `among_them` / `crewrift` `config_schema`, verbatim descriptions:
- `startWaitTicks` — `"Lobby countdown ticks after enough players join."` (default `120`)
- `roleRevealTicks` — `"Role reveal duration in ticks."` (default `120`)
- `voteTimerTicks` — `"Voting phase duration in ticks."` (among_them default `6000`; crewrift `240`)
- `voteResultTicks` — `"Vote result display duration in ticks."` (default `72`)
- `killCooldownTicks` — `"Kill cooldown duration in ticks."` (default `900`)
- `taskCompleteTicks` — `"Task completion duration in ticks."` (default `72`)
- `messageCooldownTicks` — `"Chat message cooldown in ticks."` (default `100`)
- `gameOverTicks` — `"Game over display duration in ticks."` (default `360`)
- `connectTimeoutTicks` / `disconnectTimeoutTicks` (crewrift only) — `"Initial connection grace duration in ticks."` / `"Reconnect grace duration in ticks."` (default `720` each)
- `maxTicks` — `"Maximum game ticks, where 0 means no limit."`; `maxGames` — `"Maximum games before shutdown."`
- `asteroid_arena`: `duration` — `"Game duration in seconds. Use 0 for no time limit."`

Orchestrator-side timers: `WatchdogIntervalMs = 30_000` (`games_server.nim:50`), `DefaultCpuKillSeconds = 600.0` (`:45`), certifier `DefaultTimeoutSeconds = 60.0` (`cogame_validator.nim:11`), `DefaultTickMillis = 2000` for tournament scheduling (`tournament_server.nim:19`).

## Shrinking zones / hazards
**ABSENT.** No zone, storm, circle, hazard, or area-shrink concept anywhere. This is greenfield for a battle royale.

## Per-agent stats / attributes
Two surfaces:
1. **Live, per-tick**: Reward v1 extra stat lines (§3) — cumulative-per-identity, reset on server restart (`docs/reward_v1.md:70-73`).
2. **End-of-episode**: `results_schema` parallel arrays — `scores`, `win`, `tasks`, `kills`, `imposter`, `crew`, `vote_players`, `vote_skip`, `vote_timeout`, `connect_timeout`, `disconnect_timeout`, `hearts`, `distance_walked`, `alive`, `planets`, `ships`, `day`, `usernames`, `playerNames`.

Also `slots[]` per-player config (name/token/role/color) in `among_them`/`crewrift`, with a 16-color enum.

## Currencies / economy
**ABSENT.** No currency, coin, wallet, shop, or trade code. Only aspirational text — `README.md:56` (`Select` could "trade with another player"), `docs/bitworld.md:28` ("Players need to share loot, coins, health and items").

## Spectator endpoints
- `/global` (WS) + `/client/global` (HTTP) — unauthenticated live viewer. `infra/security.tf:27` documents the game SG as *"INBOUND: port 8080 from internet (spectators)"*; `:137` *"Game containers - websocket for spectators and bots"*; `:145` *"Spectators and human players connect via browser"*.
- `/reward` + `/client/rewards` + `client/stats.html` — live scoreboard.
- `games_server` grid view: `GET /containers/grid?name=A&name=B&...` renders an N-panel viewer wall (`games_server.nim:58` `BulkGridPath`; `tools/start_demo_grid.sh` builds the URL).
- Viewer URL for a running game: `http://127.0.0.1:<port>/clients/global` (skill) or `/client/global` (`games_cli.nim:245`).

## Admin / debug ingress
`/admin` WebSocket + `/client/admin` page (`client/admin_client.html`), certified as a required endpoint. Capabilities:
- **HTTP POST control endpoints** (`admin_client.html:371-408`): `POST /control/restart` and `POST /control/kick?identity=<name>`.
- **Replay transport over the admin socket** — `admin_client.html:428-432` (verbatim):
  ```js
  function sendReplayCommand(command,label){
    sendAdminPacket([0x81,1,0,command.charCodeAt(0)],label);
  }
  ```
  i.e. a Sprite v1 `0x81` Input-Text message carrying a single ASCII char. Bound commands (`:619-620`): `" "` (space) = play/pause, `"r"` = loop.
- **QR join code** — generates `/client/player?address=ws://<host>/player` and renders it as a scannable SVG for phones on the LAN (`:306-348`).
- **Debug sprite overlay panel** in `client/global_client.html` (`.debugSprite` CSS `:105-120`, `debugSprites` element `:171`) — renders agent-authored `0x86` overlays.
- **games_server web UI** (port 2080): `POST /games/create`, `/games/stop`, `/games/bot`, `/games/bot/stop`, `/games/certify`, `/uploads/game`, `/containers/stop`, `/containers/remove`, `/replays/play`, `/logs`, `/scores`, `/manifests` (`games_server.nim:4297-4370`). **No authentication in code** — protected only by network placement (`infra/security.tf:36`: *"INBOUND: port 2080 (web UI) from Observatory reverse proxy (MVP) + SSH from trusted humans"*).

## External human input into a running game
Yes, three ways:
1. **Join as a player** — `/client/player?address=ws://host:8080/player&name=...&slot=N&token=...`, from browser or native client. The admin QR code exists specifically for this.
2. **Chat/text ingress** — Bitscreen packet `1` or Sprite `0x81` while a game is live.
3. **Admin control** — restart / kick / replay transport as above.

Note `closedRoster` (`"Reject players outside the configured token/slot roster."`, default `false`) is the switch that locks a game to its configured tokens. Certification *requires* bad-token rejection: `requireBadPlayerRejected` (`cogame_validator.nim:1332-1340`).

---

# 10. BUILD / RUN

## Nim version pin & deps

`bitworld.nimble` (verbatim):
```nim
version     = "0.1.0"
author      = "Andre von Houck"
description = "Retro 64x64 multiplayer social curriculum AI environment."
license     = "MIT"

srcDir = "src"
paths = @["src"]
installDirs = @["src", "client", "docs", "games_server", "tools"]

switch("path", "src")
switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "pixie"
requires "mummy >= 0.4.7"
requires "curly >= 1.1.1"
requires "whisky >= 0.1.3"
requires "silky >= 0.0.2"
requires "windy >= 0.4.4"
requires "paddy >= 0.1.0"
requires "supersnappy >= 2.1.3"
requires "flatty >= 0.3.4"
requires "taggy >= 0.0.3"
requires "fluffy >= 1.0.0"
requires "zippy >= 0.10.19"
```
**`nimble` tasks: ABSENT** — the `.nimble` defines zero `task` blocks. Exact-commit pins live in `nimby.lock` (28 packages, e.g. `pixie 6.0.0 … 6d47166`, `mummy 0.4.7 … 3bcb1e3`, `whisky 0.1.3 … 494fb10`) — the project uses **nimby**, not `nimble lock`. `client/nimby.lock` is a 21-package subset for client-only builds.

`config.nims` notables: `--outdir:./out`, `--nimcache:./nimcache`, `--threads:on`, `--mm:orc`, `--define:release` unless `-d:debug`, `--define:ssl` (needed for `wss://` and https LLM calls), and sibling-checkout paths `../mummy/src`, `../paddy/src`, `../whisky/src`. Emscripten branch (`:22-84`) targets `wasm32` + WebGL2, uses `-d:useMalloc` with an explicit comment about Nim's allocator corrupting the heap under `ALLOW_MEMORY_GROWTH`.

## Build + run commands

**Orchestrator (games_server):**
```sh
cd /home/claude/source/bitworld
nim r games_server/games_server.nim              # dev, port 2080
# or, as the demo-grid script does:
nim c -o:tmp/demo_grid/games_server games_server/games_server.nim
./tmp/demo_grid/games_server --address:127.0.0.1 --port:2080
```
Other servers: `nim r games_server/tournament_server.nim` (2081), `nim r games_server/multi_server.nim` (2082).

**Reference sprite server (best new-game template):**
```sh
nim r global_ui/global_ui.nim --address:0.0.0.0 --port:8080
```

**Clients (standalone):**
```sh
nim r client/player_client.nim --address:ws://localhost:8080/player [--screen-only] [--reconnect:5] [--joystick:N] [--x:N --y:N] [--title:...]
nim r client/global_client.nim   # flags per GlobalOptions
nim r client/reward_client.nim
# browser:
#   client/player_client.html?address=ws://localhost:8080/player&reconnect=5
#   client/global_client.html?address=ws://localhost:8080/global
```

**A game locally (quick_run)** — path-based; the game must be a sibling `cogame-*` checkout since none ship here:
```sh
nim r tools/quick_run ../cogame-planet-wars --players:1 --bots:skurge:3 --port:2001
nim r tools/quick_run ../cogame-infinite-blocks --players:1 --bots:stacker:3 --port:2002
nim r tools/quick_run ../cogame-big-adventure --players:1 --bots:konrad:1 --port:2003
nim r tools/quick_run ./among_them --players:1 --bots:evidencebot_v2:7 --port:2000 \
  --config:'{"minPlayers":8,"imposterCount":2,"tasksPerPlayer":6,"voteTimerTicks":360}'
nim r tools/quick_run ./among_them --bots:nottoodumb:8 --save-replay:among_them.bitreplay
nim r tools/quick_run ./among_them --connect --address:localhost --port:2000 --players:1 --bots:nottoodumb:7
```
Full flag surface (`tools/quick_run.nim:109-129`): `--connect --address:ADDR --port:N --player --players:N --bots:BOT:N[:ROLE] --global --html --slots --bot-gui --seed:N --bot-name-prefix:NAME --bot-map:PATH --reconnect:N`, plus `--config:JSON`, `--config-file:PATH`, `--save-replay:PATH`. **Unknown options are forwarded verbatim to the game server.** Bot lookup order: `<game>/players/<bot>/<bot>.nim` then `<game>/players/<bot>.nim`. Compilation is `nim c --out:<out> --path:<root>/src <source>` (`:729-747`), and the server is compiled *before* clients/bots so a bad server build launches nothing.

**Certify a Coworld package:**
```sh
nim r tools/coworld_certify.nim among_them --no-run
nim r tools/coworld_certify.nim crewrift --skip-images
nim r tools/coworld_certify.nim games_server/games/planet_wars/coworld_manifest.json
```

**Demo grid (6 games + browser wall):**
```sh
tools/start_demo_grid.sh     # requires docker, nim, lsof; uses tmux if present
tools/stop_demo_grid.sh
# env: BITWORLD_DEMO_GRID_ADDRESS / _PORT / _RUN_DIR / _SESSION
```

**Multi-arch images:** `nim r tools/docker_build.nim --push ../cogame-jumper` (buildx, `linux/amd64,linux/arm64`).
**Infra:** `nim r tools/infra.nim --bootstrap|--init|--plan|--apply|--destroy`.

## Tests

Layout: `tests/test_*.nim` (17 files, plain `doAssert`-style top-level scripts — **no `unittest`, no testament**) and `tests/manual_*.nim` (5 network-hitting LLM adapter checks, deliberately not prefixed `test`).

Coverage: `test_bitstreamprotocol`, `test_spriteprotocol` (401 lines — the deepest), `test_replays`, `test_runtime`, `test_client`, `test_server`, `test_sprites`, `test_pixelfonts`, `test_aseprite`, `test_tiled`, `test_resources`, `test_pathfinding`, `test_multi_run` (594 lines), `test_quick_run`, `test_profile`, `test_scales`.

**How to run:** no runner is committed. Either
```sh
nimble test          # nimble's builtin picks up tests/t*.nim → all test_*.nim, skips manual_*.nim
```
or directly:
```sh
for f in tests/test_*.nim; do nim r --path:src "$f" || break; done
```
`tests/test_quick_run.nim` imports `../tools/quick_run`, so `quick_run.nim` must stay importable (its main is guarded by `when isMainModule`).

## The `games-cli` skill (`.claude/skills/games-cli/SKILL.md`)

A thin doc wrapper over `tools/games_cli.nim` (407 lines) → the games_server HTTP form endpoints.

**Prereqs:** games_server on `http://127.0.0.1:2080` (override `GAMES_SERVER_URL`); Docker on PATH (the CLI shells out for `list`/`logs`/`health`); run from repo root. The skill explicitly says it will **not** start games_server for you.

**Subcommands** (all `nim r tools/games_cli.nim <cmd>`):
- `launch <manifest> [--bot NAME=N]... [--bots N] [--json]` — `POST /games/create` with form fields `manifest=<key>` and `<playerId>Bots=<N>`. `--bot all=N` / `--bots N` expands across every `player[].id`. The bot field name is `botCountField` = alphanumeric+`_`+`-` chars of the id, then `"Bots"` (`games_cli.nim:86-92`, mirroring `games_server.nim:1691-1693`). Reads the created container name out of the 302 `Location: /?notice=created+<name>` header (`:123-130`). JSON output: `{"name":"...","port":38153}`. Skill note: *"The game becomes healthy ~1–5s after this command returns."*
- `list [--json]` — `docker ps --filter label=bitworld.games_server=among_them`, emitting `{"name","port","status","manifest"}`.
- `stop <game-name>` — `POST /games/stop`; server also cleans up the bots.
- `logs <container-name> [--tail N]` — shells to `docker logs`.
- `health <game-name> [--json]` — `GET http://127.0.0.1:<port>/healthz`; exits 1 on failure unless `--json`.
- `manifests [--json]` / `bots <manifest> [--json]` — enumerate `games_server/games/*.json` + `*/coworld_manifest.json`, and `player[].id` respectively.

**Env:** `GAMES_SERVER_URL`, `GAMES_SERVER_REPO_ROOT`, `GAMES_SERVER_UPLOAD_GAMES_DIR`.

**Documented smoke-test flow (verbatim from SKILL.md:65-75):**
```bash
nim r tools/games_cli.nim launch cogs_vs_clips --bots 4 --json
# parse "name" out of the response
sleep 3
nim r tools/games_cli.nim health <name> --json
nim r tools/games_cli.nim logs <name> --tail 20
nim r tools/games_cli.nim stop <name>
```
Viewer URL: `http://127.0.0.1:<port>/clients/global` — *"The plural `/clients/` path works for both v1 and v2 games."*

⚠️ Again: `cogs_vs_clips` is **not in this repo**. To follow the skill you must first `POST /uploads/game` a manifest (which writes `games_server/games/<safe-name>/coworld_manifest.json`, `games_server.nim:1677-1690`) or drop the file there yourself.

---

# Bottom line for a new battle-royale game

- **Do not build it in this tree.** Build a `coworld-battle-royale` repo, `requires "bitworld"`, and land only its `coworld_manifest.json` here (or upload it at runtime).
- **What you inherit for free:** the Sprite v1 codec + both viewers, the framebuffer/sprite/font drawing libs, the bitreplay writer/parser, the `COGAME_*_URI` runtime intake, the certifier, the container/ECS launcher, the reward stream, the admin panel, and the tick/frame-limiter pattern in `global_ui/global_ui.nim`.
- **What you must write from scratch:** the entire simulation — tick loop, movement, projectiles, HP/death, pickups, fog/vision, map gen, **shrinking zone**, the per-player observation renderer, the deterministic seeded PRNG, and the tick-hash function.
- **Three contract landmines:** (1) `replays.nim` record `0x07` is undocumented — trust the code; (2) the key-bit table in `bitreplay_spec.md` contradicts `bitscreen_v1.md` for Select/A/B; (3) `multiruns.nim:801` and `tournament_server.nim:1123` overwrite your manifest seed with wall-clock/`rand()` — if you want reproducible episodes from those launchers, that has to change.