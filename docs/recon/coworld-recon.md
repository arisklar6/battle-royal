I have full coverage. Here is the report.

---

# COWORLD REPO RECON — `/home/claude/source/coworld`

Repo state: single commit `7c3d8f0 fix: allocate coworld versions above all uploads (#24)`, clean tree. `CLAUDE.md` is a symlink → `AGENTS.md`.

---

## 1. README.md — "Developing Coworlds" + Documentation Map

**File:** `/home/claude/source/coworld/README.md`

### "Developing Coworlds" (lines 40–58), verbatim:

> ## Developing Coworlds
>
> Coworld builders create the worlds that player developers target. They define the game, the player experience, example
> or baseline players, local test episodes, local browser-play surfaces, and supporting outputs that help humans and agents
> understand what happened.
>
> Start with [Authoring A Coworld](src/coworld/docs/AUTHORING.md) — the end-to-end guide from design through local
> testing, certification, upload, and hosted verification. It leans on the
> [starter templates](src/coworld/templates/README.md) and the
> [Paint Arena example](src/coworld/examples/paintarena/README.md) as its worked references. Use
> [Rebuilding Coworlds After The Role Repo Move](src/coworld/docs/REBUILDING_COWORLDS.md) when updating an existing
> Coworld or fixing a supporting role.
>
> For uploaded games, `game.docs.readme` should be the durable game-owned guide: rules, strategy, how to use or modify a
> game-specific policy, and game-specific FAQs. Shared protocol docs belong in `game.protocols`; Softmax participation,
> policy upload, league submission, standings, logs, and replay instructions belong in the platform `play_*.md` guide.
>
> The canonical rebuild flow is to copy the relevant template, Paint Arena role, or `coworld-tools` implementation into
> the owning `coworld-<slug>` repo, then build and publish that game-local source.

Docs linked from that section (absolute paths):
- `/home/claude/source/coworld/src/coworld/docs/AUTHORING.md`
- `/home/claude/source/coworld/src/coworld/templates/README.md`
- `/home/claude/source/coworld/src/coworld/examples/paintarena/README.md`
- `/home/claude/source/coworld/src/coworld/docs/REBUILDING_COWORLDS.md`

### Documentation Map (README.md:95–122)

Preamble verbatim (README.md:97–98):
> The Coworld docs are being reorganized. These links are the current source-of-truth entry points while that work is in
> progress:

Table rows → target files (all under `/home/claude/source/coworld/`):

| Need | Doc path |
| --- | --- |
| Understand what a complete Coworld is | `src/coworld/docs/README.md` |
| Build and test a new Coworld end to end | `src/coworld/docs/AUTHORING.md` |
| Build or operate from recipes | `COOKBOOK.md` |
| Understand manifest fields | `src/coworld/docs/COWORLD_MANIFEST.md` |
| Understand roles and artifact flow | `src/coworld/docs/README.md#roles` |
| Implement a game runnable | `src/coworld/docs/roles/GAME.md` |
| Add a browser-only replay viewer | `src/coworld/docs/STATIC_REPLAY_VIEWERS.md` |
| Implement or submit a player | `src/coworld/docs/roles/PLAYER.md` + `COOKBOOK.md` |
| Call Bedrock / an LLM from a player | `src/coworld/docs/BEDROCK.md` |
| Implement supporting roles | `src/coworld/docs/roles/{REPORTER,COMMISSIONER,GRADER,DIAGNOSER,OPTIMIZER}.md` |
| Start from installable templates | `coworld/templates` in the installed package |
| Rebuild with the current role source layout | `src/coworld/docs/REBUILDING_COWORLDS.md` |
| Understand artifact contracts | `src/coworld/docs/artifacts/README.md` |
| Consume episode artifacts as a unit | `src/coworld/docs/artifacts/EPISODE_BUNDLE.md` |
| Understand the episode lifecycle | `src/coworld/docs/LIFECYCLE.md` |
| Debug local or hosted execution | `src/coworld/runner/RUNNER_README.md`, `src/coworld/runner/KUBERNETES_RUNNER_README.md` |
| Start from the canonical example | `src/coworld/examples/paintarena/README.md` |
| Look up exact CLI or API reference | `uv run coworld --help`, `uv run coworld <command> --help`, Observatory OpenAPI |

Also load-bearing for your sponsor-gift design, README.md:91–93 verbatim:
> Coworld does not currently provide a supported hosted game-only lobby where users connect their own remote players. Use
> `coworld play` for local browser play, or submit policies to leagues for fully hosted tournament episodes where the
> platform runs the game and every player container.

---

## 2. COOKBOOK.md recipes

**File:** `/home/claude/source/coworld/COOKBOOK.md` (1181 lines)

### Stated global prerequisites (COOKBOOK.md:121–138, "Set Up Auth"), verbatim:

> ## Set Up Auth
>
> ### CLI
>
> Install Coworld in a project that will run player or Coworld commands:
>
> ```bash
> uv add "coworld[auth]"
> ```
>
> Log in before using commands that talk to Softmax:
>
> ```bash
> uv run softmax login
> uv run softmax status
> ```
>
> Pass `--server` only when targeting a non-default Observatory API environment.

### "Certify And Upload A Coworld" — VERBATIM, full recipe (COOKBOOK.md:1032–1119)

> ## Certify And Upload A Coworld
>
> ### CLI
>
> Coworld authors should build, certify, and upload the Coworld package. For Paint Arena:
>
> ```bash
> uv run coworld build --project packages/coworld/src/coworld/examples/paintarena --version 0.1.0
> uv run coworld certify packages/coworld/src/coworld/examples/paintarena/dist/coworld_manifest.json
> uv run coworld upload-coworld packages/coworld/src/coworld/examples/paintarena/dist/coworld_manifest.json
> ```
>
> `certify` runs the Executable transcript locally. It validates GitHub `source_url` refs by checking that they resolve
> and carry a Dockerfile, validates the manifest's certification fixture before launching containers, runs one smoke
> episode, validates results, verifies the replay artifact is present and loadable, confirms declared players launched,
> and checks implemented supporting-role probes. Mutable `source_url` refs and bare repository URLs pass with a warning
> because certification checks the ref or default branch as it exists at run time. Replay-load verification starts the
> game image in replay mode with `COGAME_LOAD_REPLAY_URI` and verifies `GET /client/replay`. It waits for a frame from the
> `/replay` WebSocket. Manifest reporter references are statically validated (spec 0061); commissioners are probed over
> `/healthz` and `/round`. After a successful explicit `certify`, the exact manifest, certifier code, transcript, and
> local image IDs are cached. `upload-coworld` reuses that proof when nothing changed; otherwise it certifies before
> creating or pushing any Docker archive. After upload, the platform auto-queues a hosted certification run for the new
> version; the upload output prints the hosted certification state, `coworld status <cow_id>` shows the verdict and
> per-step transcript, and `--wait-certification` polls the hosted run to completion (exit 2 on an author-controlled
> failure, 3 on platform failure/timeout). A failed hosted certification never blocks or hides the upload.
>
> `certify` also writes `certification_report.html` into the printed artifact workspace and opens it in the browser by
> default. The report is a local transcript view with each step's pass/fail status, failure reason, artifact paths, and
> expandable details about what the step checks. Use `--no-open-report` for CI or other non-interactive runs.
>
> After certification, open the printed replay command and watch the replay once before upload. The automated probe proves
> the replay route is alive; the visual check proves the game-specific viewer shows the expected state, controls, and
> looping behavior.
>
> To publish a small update from an already uploaded Coworld, use the hosted manifest as the base. Only new local image
> refs are uploaded; unchanged `img_...` entries stay as-is:
>
> ```bash
> uv run coworld upload-coworld --from-coworld cow_... \
>   --version 0.1.1 \
>   --image commissioner.default=paintarena-commissioner:latest
>
> uv run coworld upload-coworld --from-coworld paintarena \
>   --version 0.1.2 \
>   --patch '{"game":{"owner":"games@softmax.com"}}'
> ```
>
> Use `--image role.id=IMAGE` or `--image role[index]=IMAGE` when a role has more than one runnable. `--patch` accepts a
> JSON merge-patch object inline, or a path to a JSON file.
>
> Inspect uploaded Coworlds and images:
>
> ```bash
> uv run coworld list
> uv run coworld show cow_...
> uv run coworld images
> ```
>
> ### Non-CLI Docker/API
>
> Use Docker-backed build/certification helpers locally and the upload client for the hosted API:
>
> ```python
> from pathlib import Path
>
> from coworld.bundle import build_coworld_manifest
> from coworld.certifier import certify_coworld
> from coworld.upload import upload_coworld
> from softmax.auth import get_api_server
>
>
> manifest_path = build_coworld_manifest(
>     Path("packages/coworld/src/coworld/examples/paintarena/compose.yaml"),
>     Path("packages/coworld/src/coworld/examples/paintarena/coworld_manifest_template.json"),
>     "0.1.0",
>     Path("tmp/paintarena/coworld_manifest.json"),
> )
>
> certification = certify_coworld(manifest_path, timeout_seconds=60)
> print(certification.artifacts.replay_path)
>
> upload = upload_coworld(manifest_path, server=get_api_server(), timeout_seconds=60)
> print(upload.id)
> ```
>
> The lower-level API sequence for Coworld upload is the same container-image upload flow used by policies, repeated for
> every runnable image in the manifest. Replace each manifest `image` with the returned container image ID, then
> `POST /v2/coworlds/upload` with `{"manifest": ...}`.

### "Build And Run Paint Arena Locally" — VERBATIM, full recipe (COOKBOOK.md:217–367)

> ## Build And Run Paint Arena Locally
>
> ### CLI
>
> From the repository root, hydrate the in-package Paint Arena manifest and build its images:
>
> ```bash
> uv run coworld build --project packages/coworld/src/coworld/examples/paintarena --version 0.1.0
> ```
>
> Run a browser-play session with the bundled Paint Arena player:
>
> ```bash
> uv run coworld play packages/coworld/src/coworld/examples/paintarena/dist/coworld_manifest.json
> ```
>
> Run one headless local episode with the same default fixture:
>
> ```bash
> uv run coworld run-episode packages/coworld/src/coworld/examples/paintarena/dist/coworld_manifest.json
> ```
>
> Use `play` when you want browser links for a live local episode. Use `run-episode` when you want a headless smoke test
> that waits for completion and writes results, replay, and logs. For a local manifest like the one above, `run-episode`
> writes those artifacts under `tmp/paintarena/results/` by default. For repeated local runs, add `--episodes N`; the
> artifacts are written under `tmp/paintarena/results/episode-0001/`, `episode-0002/`, and so on.
>
> To show the resulting local replay, use `coworld replay` with the local replay file:
>
> ```bash
> uv run coworld replay tmp/paintarena/coworld_manifest.json tmp/paintarena/results/replay
> ```
>
> `run-episode --verify-replay` verifies the game image can serve replay mode, but it does not leave a viewer running. Use
> `coworld replay` when you want an actual local replay URL.
>
> ### Non-CLI Docker-Backed Python
>
> The public Python helpers run the same Docker containers:
>
> ```python
> from pathlib import Path
>
> from coworld.bundle import build_coworld_manifest
> from coworld.certifier import build_manifest_episode_job_spec, load_coworld_package
> from coworld.play import play_coworld, replay_coworld
> from coworld.runner.runner import EpisodeArtifacts, run_coworld_episode
>
>
> manifest_path = build_coworld_manifest(
>     Path("packages/coworld/src/coworld/examples/paintarena/compose.yaml"),
>     Path("packages/coworld/src/coworld/examples/paintarena/coworld_manifest_template.json"),
>     "0.1.0",
>     Path("tmp/paintarena/coworld_manifest.json"),
> )
>
> play_coworld(
>     manifest_path,
>     workspace=Path("tmp/paintarena/play"),
>     on_ready=lambda session: print(session.links.global_),
> )
>
> package = load_coworld_package(manifest_path)
> artifacts = EpisodeArtifacts.create(Path("tmp/paintarena/results"))
> run_coworld_episode(
>     build_manifest_episode_job_spec(package),
>     artifacts,
>     timeout_seconds=3600,
> )
>
> replay_coworld(
>     manifest_path,
>     artifacts.replay_path,
>     on_ready=lambda session: print(session.link),
> )
> ```
>
> ### Raw Docker Shape
>
> Use raw Docker when you need to debug the runtime contract directly. The game container receives config/results/replay
> URIs; each player container receives a slot-specific WebSocket URL.
>
> ```bash
> docker network inspect coworld-local >/dev/null 2>&1 || docker network create coworld-local
> mkdir -p tmp/paintarena/docker/logs
>
> cat > tmp/paintarena/docker/config.json <<'JSON'
> {
>   "width": 12,
>   "height": 8,
>   "max_ticks": 100,
>   "tick_rate": 5,
>   "player_connect_timeout_seconds": 180,
>   "players": [{"name": "Sweep Painter 1"}, {"name": "Sweep Painter 2"}],
>   "tokens": ["token-0", "token-1"]
> }
> JSON
>
> docker run --rm --name paintarena-game \
>   --network coworld-local --network-alias coworld-game \
>   -p 127.0.0.1:18080:8080 \
>   -e COGAME_HOST=0.0.0.0 \
>   -e COGAME_PORT=8080 \
>   -e COGAME_CONFIG_URI=file:///coworld/config.json \
>   -e COGAME_RESULTS_URI=file:///coworld/results.json \
>   -e COGAME_SAVE_REPLAY_URI=file:///coworld/replay \
>   -e COGAME_PLAYER_FAILURE_URI=file:///coworld/player_failure.json \
>   -v "$PWD/tmp/paintarena/docker:/coworld:rw" \
>   coworld-paintarena:latest \
>   python -m coworld.examples.paintarena.game.server
> ```
>
> For browser-controlled play, skip the player containers and open the player client links below. For a headless policy
> test, start one player container per slot in separate terminals:
>
> ```bash
> docker run --rm --network coworld-local \
>   -e COWORLD_PLAYER_WS_URL='ws://coworld-game:8080/player?slot=0&token=token-0' \
>   -e COGAMES_ENGINE_WS_URL='ws://coworld-game:8080/player?slot=0&token=token-0' \
>   coworld-paintarena:latest \
>   python -m coworld.examples.paintarena.player.player
>
> docker run --rm --network coworld-local \
>   -e COWORLD_PLAYER_WS_URL='ws://coworld-game:8080/player?slot=1&token=token-1' \
>   -e COGAMES_ENGINE_WS_URL='ws://coworld-game:8080/player?slot=1&token=token-1' \
>   coworld-paintarena:latest \
>   python -m coworld.examples.paintarena.player.player
> ```
>
> Browser clients are served by the game container:
>
> ```text
> http://127.0.0.1:18080/client/global
> http://127.0.0.1:18080/client/player?slot=0&token=token-0
> http://127.0.0.1:18080/client/player?slot=1&token=token-1
> ```
>
> Serve the replay with the same game image in replay mode:
>
> ```bash
> docker run --rm --name paintarena-replay \
>   -p 127.0.0.1:18081:8080 \
>   -e COGAME_HOST=0.0.0.0 \
>   -e COGAME_PORT=8080 \
>   -e COGAME_LOAD_REPLAY_URI=file:///coworld-replay/replay \
>   -v "$PWD/tmp/paintarena/docker:/coworld-replay:ro" \
>   coworld-paintarena:latest \
>   python -m coworld.examples.paintarena.game.server
> ```
>
> Then open `http://127.0.0.1:18081/client/replay`. The replay WebSocket is `/replay`.

Note: the "For browser-controlled play, skip the player containers and open the player client links below" line is the documented human-plays-a-slot path.

### All other COOKBOOK recipe titles (`##` level, with line numbers)

| Line | Title |
| --- | --- |
| 29 | FAQ (subsections at 31, 46, 67, 83, 97, 115) |
| 121 | Set Up Auth |
| 166 | Find A League And Coworld |
| 217 | Build And Run Paint Arena Locally |
| 369 | Test A Player Image Locally |
| 436 | Run An Exact Episode Request |
| 471 | Use Secrets Or Bedrock Locally |
| 552 | Act As A Player |
| 581 | Upload And Submit A Player |
| 711 | Check Submission Status |
| 750 | Watch Results And Find Episodes |
| 798 | Request Experience Runs |
| 875 | Retrieve Logs, Results, And Replays |
| 1032 | Certify And Upload A Coworld |
| 1121 | Read Tournament Data From Python |
| 1141 | Raw HTTP Escape Hatch |
| 1157 | Troubleshooting |

---

## 3. COWORLD_MANIFEST.md + the real field contract

**Doc:** `/home/claude/source/coworld/src/coworld/docs/COWORLD_MANIFEST.md`
**Machine contract:** `/home/claude/source/coworld/src/coworld/coworld_manifest_schema.json` (834 lines, generated)
**Pydantic source of truth:** `/home/claude/source/coworld/src/coworld/types.py` (564 lines)

The doc explicitly refuses to restate fields (COWORLD_MANIFEST.md:18–19, verbatim):
> This document intentionally does **not** duplicate the schema field by field. It records how to use the manifest, which
> semantics live outside normal JSON Schema, and where to look when authoring or changing manifests.

And COWORLD_MANIFEST.md:34–35, verbatim:
> When a field contract changes, update the Pydantic model in [`types.py`](../types.py), regenerate the schema, and keep
> this document focused on the surrounding semantics. Do not hand-edit `coworld_manifest_schema.json`.

### Complete top-level field list (from generated schema; `additionalProperties: false`)

**REQUIRED:** `game`, `player`, `variants`, `certification`
**OPTIONAL:** `$schema`, `tags`, `reporter`, `commissioner`, `grader`, `diagnoser`, `optimizer`, `players_per_user`, `episode_timeout_minutes`

Per-field, from `types.py:387–472`:
- `$schema` (`schema_`, alias `$schema`) — `types.py:397` — "Optional JSON Schema URI for IDE tooling."
- `tags` — `types.py:398–403` — `list[str]`, `min_length=3` on the list, each item `min_length=1`. Description verbatim: `"Tags describing the Coworld for discovery and classification. When present, at least three are required."` Default omitted from schema. **Certification hard-requires it** (see §11).
- `game` — required, `CoworldGameManifest`
- `player` — required, `list[CoworldManifestRoleSpec]`, `min_length=1`
- `reporter` — optional, default `[]`, union of `CoworldReporterPlatformReference | CoworldReporterWasmReference`
- `commissioner`, `grader` — optional, default `[]`
- `diagnoser`, `optimizer` — optional, default `[]`, carry `x-coworld-future-required: true` and `$comment` = `"Optional in the current schema; intended to become required as this role stabilizes."` (`types.py:20`)
- `variants` — required, `min_length=1`
- `certification` — required, `CoworldCertificationFixture`
- `players_per_user` — optional `int`, `ge=1` — `types.py:451–458`
- `episode_timeout_minutes` — optional `int`, `ge=1`, `le=100` (`MAX_EPISODE_TIMEOUT_MINUTES=100`, default `DEFAULT_EPISODE_TIMEOUT_MINUTES=20`) — `types.py:459–468`

### `game` object (`CoworldGameManifest`, `types.py:308–354`)

**REQUIRED:** `name`, `version`, `description`, `owner`, `config_schema`, `results_schema`, `runnable`, `protocols`, `docs`
**OPTIONAL:** `promo`, `replay_viewer`

- `version` — verbatim description: `"Coworld package version. Pydantic validation requires a valid PEP 440 version."` **The template must NOT set it** — `AUTHORING.md:144`: "The template must **not** set `game.version` — the build stamps it."
- `runnable` — a single object (not array), `type` must be `"game"` (`types.py:352–353`)
- `config_schema` verbatim (`types.py:318–324`): `"JSON Schema for runtime game configs. It must require a string-array `tokens` field for runner-injected player auth with minItems/maxItems validity bounds; variants and certification configs omit tokens because the runner injects them."`
- `results_schema` verbatim: `"JSON Schema for the game-written results artifact. Cross-game consumers require `scores`."`
- `replay_viewer.bundle` — package-relative dir with `index.html`, rewritten to `sha256:<64 hex>` on upload (`types.py:282–305`)
- `promo.video_url` — HTTP(S) URL; surfaces a "Video Promo" tab.

### Runnable shapes

`CoworldRunnableSpec` (`types.py:105–131`) — **required:** `type`, `image`; **optional:** `run` (`[]`), `env` (`{}`), `source_url`, `resources`.
`CoworldManifestRoleSpec` (`types.py:134–152`) extends it — **additionally required:** `id`, `name`, `description`; **optional:** `repository_url`.
`resources` → `requests{cpu, memory, ephemeral-storage}` + `limits{cpu}` (`types.py:49–102`).

`env` public-by-default warning, COWORLD_MANIFEST.md:126–127 verbatim:
> Manifest runnable `env` is public by default: uploaded manifests are visible to users, and downloaded Coworld packages
> include the env values. Do not put raw API keys, signing keys, or cloud credentials directly in manifest env.

Secret referencing (COWORLD_MANIFEST.md:132–140) verbatim:
```bash
uv run coworld secret put cue_n_woo worker_signing_key ./tournament_signing_key.secret
```
```json
"env": {
  "WORKER_SIGNING_KEY_URI": "secret://coworld/cue_n_woo/worker_signing_key"
}
```
COWORLD_MANIFEST.md:145–146 verbatim: "Hosted play and Antfarm dispatch do not resolve Coworld secrets; use the k8s hosted episode backend for Coworlds whose game env contains `secret://` values." Cap: 1 MiB.

### `game.docs` — how docs are declared

`CoworldDocs` (`types.py:255–267`): **required** `readme`; **optional** `pages` (default `[]`).
A doc is `CoworldTextDoc` (`{"type":"text","value":"…"}`) or `CoworldUriDoc` (`{"type":"uri","value":"https://…"}`), discriminated on `type` (`types.py:206–220`). URI values must match `^https?://`.
`CoworldDocPage` (`types.py:237–252`): **required** `id`, `title`, `content`.

COWORLD_MANIFEST.md:168–182 verbatim:
> The manifest stores document references, not local file uploads. A document is either inline text or a public HTTP(S)
> URI. Referenced URI docs should be fetchable by users and tools after the Coworld is uploaded.
>
> `game.docs.readme` is required and points to the Coworld's `README.md`. […]
>
> `game.docs.pages` is optional supplemental documentation. Coworlds may include pages for strategy notes, protocol
> supplements, reference material, or legacy rule/play guides, but the manifest contract no longer requires a `rules.md`
> or `play_*.md` page.

`game.protocols` (`CoworldProtocolDocs`, `types.py:223–234`): **required** `player`, `global` (alias for `global_`); **optional** `engine_runtime` ∈ `mettagrid | cogweb | bitworld | nimgrid`.

### Certification fixture

`CoworldCertificationFixture` (`types.py:375–384`): **required** `game_config` (token-free) and `players` (`min_length=1`, ordered).
`CoworldCertificationPlayer` (`types.py:366–372`): **required** `player_id` only — "ID of a bundled player runnable to use for this certification slot."

COWORLD_MANIFEST.md:102–108 verbatim:
> Coworld-authored configs do **not** include `tokens`:
>
> - `variants[].game_config` is token-free.
> - `certification.game_config` is token-free.
>
> The runner injects fresh tokens when it creates the concrete per-episode config. Authoring tools validate
> author-provided configs by adding placeholder tokens first, not by expecting token values to appear in the manifest.

### Variants

`CoworldVariant` (`types.py:357–363`): **all four required** — `id`, `name`, `game_config`, `description`. `game_config` verbatim: `"Token-free game config that validates against game.config_schema."`

### Authoring workflow (COWORLD_MANIFEST.md:69–86), verbatim ordered list:
> 1. Fill in `game` metadata, docs, protocols, config schema, results schema, and game runnable. […]
> 2. Add bundled players used for examples, certification, and local play.
> 3. Add reporter references when the Coworld ships bespoke reporting (reporter v2, spec 0061). […]
> 4. Add grader runnables when the Coworld has custom graders or a default grader is useful.
> 5. Add commissioner, diagnoser, and optimizer runnables when the Coworld has custom implementations, or when a default image is appropriate for the role.
> 6. Define at least one variant.
> 7. Define the certification fixture that `coworld certify` and default local episode runs execute.
> 8. Validate locally before upload.

Name ownership (COWORLD_MANIFEST.md:91–92): "The first authenticated user upload for a Coworld `game.name` establishes that user as the name owner. Future uploads for the same name must come from that original uploader or a Softmax team member."

**Full example manifest quoted verbatim inside COWORLD_MANIFEST.md: ABSENT.** The doc points at `examples/paintarena/coworld_manifest_template.json` as "the canonical worked example" (COWORLD_MANIFEST.md:15–16). That file is quoted verbatim in §7 below.

---

## 4. GAME.md — the game runnable contract

**File:** `/home/claude/source/coworld/src/coworld/docs/roles/GAME.md` — **Status:** live

### Core contract, GAME.md:29–45 VERBATIM:

> The game runnable is a long-running container that listens on `COGAME_HOST:COGAME_PORT`, defaulting to `0.0.0.0:8080`.
> It must:
>
> - Read its concrete game config from `COGAME_CONFIG_URI` at startup.
> - Serve `GET /healthz` with 200 once it is ready.
> - Serve player HTML clients at `GET /client/player?slot=...&token=...`.
> - Serve player WebSocket connections at `/player?slot=...&token=...`.
> - Serve a live global viewer at `GET /client/global` and `/global`.
> - Support replay mode with `COGAME_LOAD_REPLAY_URI`, `GET /client/replay`, and `/replay`. Local certification still
>   probes this path; when `game.replay_viewer.bundle` is absent, hosted viewers also use it as the version-matched
>   container fallback.
> - Make `GET /client/replay` start playback automatically and loop from the recorded end back to tick 0 by default.
> - Write a JSON results artifact to `COGAME_RESULTS_URI` when the episode completes.
> - Write replay bytes to `COGAME_SAVE_REPLAY_URI`.
> - When its own rules make a player failure terminal, write a typed `GamePlayerFailure` to
>   `COGAME_PLAYER_FAILURE_URI` instead of results. The runner validates this signal and produces the platform-owned
>   [`error_info.json`](../artifacts/ERROR_INFO.md); the game does not write that final artifact.

### Env vars (canonical constants, `/home/claude/source/coworld/src/coworld/runner/runner.py:31–48`)

```
CONTAINER_WORKDIR = "/coworld"
CONFIG_ENV_VAR = "COGAME_CONFIG_URI"
RESULTS_ENV_VAR = "COGAME_RESULTS_URI"
REPLAY_SAVE_ENV_VAR = "COGAME_SAVE_REPLAY_URI"
REPLAY_LOAD_ENV_VAR = "COGAME_LOAD_REPLAY_URI"
PLAYER_FAILURE_ENV_VAR = "COGAME_PLAYER_FAILURE_URI"
GAME_HOST_ENV_VAR = "COGAME_HOST"
GAME_PORT_ENV_VAR = "COGAME_PORT"
GAME_HOST = "0.0.0.0"
GAME_PORT = 8080
LOCAL_DOCKER_NETWORK = "coworld-local"
LOCAL_GAME_NETWORK_ALIAS_PREFIX = "coworld-game-"
LOCAL_EPISODE_CONTAINER_PREFIX = "coworld-cert"
LOCAL_EXTRA_PORTS_ENV_VAR = "COWORLD_LOCAL_EXTRA_PORTS"
LOCAL_PORT_ENV_PREFIX = "COWORLD_LOCAL_PORT_"
LOCAL_PORTS_JSON_ENV_VAR = "COWORLD_LOCAL_PORTS_JSON"
LOCAL_PORT_HOST = "127.0.0.1"
```

Hosted game env, `/home/claude/source/coworld/src/coworld/runner/KUBERNETES_RUNNER_README.md:155–162` VERBATIM:
```bash
COGAME_HOST=0.0.0.0
COGAME_PORT=8080
COGAME_CONFIG_URI=file:///coworld/config.json
COGAME_RESULTS_URI=file:///coworld/results.json
COGAME_SAVE_REPLAY_URI=file:///coworld/replay
COGAME_PLAYER_FAILURE_URI=file:///coworld/player_failure.json
```
Optional game-side: `COGAME_LOG_URI` (optional; `docs/artifacts/GAME_LOGS.md:13`: "`COGAME_LOG_URI` is optional. If it is unset, the game must skip log posting and may still write stdout/stderr normally.")

### Ports

- Container port **8080** is the only Coworld HTTP/WS port. Local runner publishes `127.0.0.1:<random>:8080`.
- **Extra local ports** — GAME.md:77–90 VERBATIM (this is the closest thing to a custom ingress, and it is local-only):
> Local Docker runners always publish the Coworld HTTP/WebSocket port as `127.0.0.1:<random>:8080`. A game that also
> needs host-visible TCP services can request additional local mappings through public `manifest.game.runnable.env`:
>
> ```json
> "env": {
>   "COWORLD_LOCAL_EXTRA_PORTS": "3724:3724,8085:8085"
> }
> ```
>
> Entries are `container_port[:host_port]`. Omit `host_port` or set it to `0` to allocate a free local host port. The
> local runner rejects invalid ports and duplicate host or container ports. When mappings are resolved, the game container
> receives `COWORLD_LOCAL_PORT_<container_port>=127.0.0.1:<host_port>` for each mapping and
> `COWORLD_LOCAL_PORTS_JSON` with the same resolved data. This is local-runner-only; hosted/Kubernetes runners do not
> publish arbitrary extra host ports today.

### Terminal player failure, GAME.md:61–73 VERBATIM

```json
{
  "message": "Player slot 3 failed before completing its session",
  "failed_policy_index": 3
}
```
> Both fields are required, unknown fields are rejected, `message` is 1–2000 characters, and `failed_policy_index` is a
> non-negative player slot.
>
> Publish the declaration atomically (for a file URI, write a temporary file and rename it), then shut down gracefully.
> Do not also finalize normal results or replay output for that failure. If every required success artifact is already
> complete, the runner treats the episode as successful and ignores a stale or racing declaration.

### Player slots, GAME.md:94–96 VERBATIM
> `game.config_schema` must require a string-array `tokens` field. Tokens are runner-injected player auth values, not a
> player-count declaration, so `minItems` and `maxItems` are validity bounds for possible rosters, not the scheduler's
> chosen count. The runner injects the concrete tokens after the episode roster is known.

### Exit behavior
The game is expected to exit after writing artifacts; runner waits via `_wait_for_game_exit` (`play.py:253`, `runner.py`). Local: `--timeout-seconds` default 3600 for `play`/`run-episode`/`scrimmage`, 60 for `certify`. Hosted: GAME.md:135 — "Hosted episode Jobs have a 20 minute active deadline"; `episode_timeout_minutes` (1..100) overrides per manifest.

### Hosted resources, GAME.md:131–135 VERBATIM
> The current hosted baseline is 1 CPU / 512Mi for the game container, 250m CPU / 256Mi for the runner worker, 250m CPU / 256Mi for each
> player container, and 2 CPU / 2Gi for replay containers […] These are scheduling requests, not CPU or memory limits.

### Bedrock in the GAME container, GAME.md:139–143 VERBATIM
> In hosted runs your game image can call AWS Bedrock by default — Softmax provides Bedrock credentials and region to the
> game container at runtime […] The game container sees `USE_BEDROCK=true`, `AWS_REGION`, and `AWS_DEFAULT_REGION` set for you […]

### Logging, GAME.md:153 VERBATIM
> Game stdout and stderr may be exposed to anyone with episode access through the [game logs](../artifacts/GAME_LOGS.md) artifact and episode bundles. Treat those streams as public diagnostic output.

---

## 5. PLAYER.md — the player contract

**File:** `/home/claude/source/coworld/src/coworld/docs/roles/PLAYER.md` — **Status:** live

### Core contract, PLAYER.md:24–43 VERBATIM:

> The player runnable is a short-lived container started by the episode runner once per player slot. It must:
>
> - Read `COWORLD_PLAYER_WS_URL` from the environment. The URL is a fully-formed websocket address pointing at the
>   game runnable's `/player` route with the slot's `slot` and `token` query params already encoded.
> - Connect to that websocket and speak the game-defined player protocol (see `game.protocols.player` in the
>   manifest). The protocol is game-owned; player authors build against the linked spec.
> - Act only for the slot identified by its `COWORLD_PLAYER_WS_URL`. The runner gives each player container its own
>   slot/token pair; a player must not attempt to control other slots.
> - Exit cleanly when the episode ends.
>
> A player may also, optionally, upload a single artifact at episode end:
>
> - Read `COWORLD_PLAYER_ARTIFACT_UPLOAD_URL` from the environment. When present, it is a destination the player may upload
>   one file to (a presigned `PUT` URL hosted, a `file://` path locally). When absent, the player simply skips uploading.
> - Upload at most one `.zip` (max 200 MB). The player may bundle whatever debug data it wants inside (parquet, sqlite,
>   csv, json, trace files); the platform stores and serves the bytes as-is.
> - Upload before the container is torn down. […] an upload that does not finish before teardown is lost. The platform
>   does not block teardown waiting for an upload, and a missing artifact never fails an otherwise successful
>   episode.

### Player env vars
- `COWORLD_PLAYER_WS_URL` (canonical) and `COGAMES_ENGINE_WS_URL` (legacy compat; both set identically — `play.py:238–240`, `runner.py`, `LIFECYCLE.md:177`)
- `COWORLD_PLAYER_ARTIFACT_UPLOAD_URL` (optional)
- policy-scoped secret env from `upload-policy --secret-env`; `USE_BEDROCK`, `BEDROCK_MODEL`, `AWS_ENDPOINT_URL_BEDROCK_RUNTIME`
- Local URL shape: `runner.py:578` → `f"ws://{host}:{GAME_PORT}/player?{_player_query(slot, token)}"`

### Bedrock rule, PLAYER.md:54–59 VERBATIM
> The one rule: in a hosted episode, send every Bedrock call to the
> `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` endpoint (the per-pod sidecar that signs with the runner identity) using
> `InvokeModel`, not `Converse`.

Reserved sidecar env keys (a policy env may **never** override) — `/home/claude/source/coworld/src/coworld/runner/bedrock_sidecar_wiring.py:21–33`: `AWS_ENDPOINT_URL_BEDROCK_RUNTIME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_BEARER_TOKEN_BEDROCK`, `AWS_BEARER_TOKEN_BEDROCK_FILE`.

### Bundled vs submitted, PLAYER.md:115–122 VERBATIM
> - **Bundled players** — referenced from a Coworld's `manifest.player[]` and uploaded via `coworld upload-coworld`.
>   After the upload completes, the backend's image publisher mirrors these images to ECR Public, so anyone can pull
>   them as part of `coworld download <coworld-id>`. Treat their contents as fully public; do not include secrets in
>   the image.
> - **Submitted policies** — uploaded via `coworld upload-policy` for league submission. These images stay private to
>   Observatory runtime and are never mirrored to ECR Public.

---

## 6. `src/coworld/docs/artifacts/` — the whole dir

Dir: `/home/claude/source/coworld/src/coworld/docs/artifacts/` — 16 files: `README.md`, `EPISODE_BUNDLE.md`, `RESULTS.md`, `REPLAY.md`, `GAME_LOGS.md`, `PLAYER_LOGS.md`, `PLAYER_ARTIFACT.md`, `DEBUG_ARCHIVE.md`, `ERROR_INFO.md`, `REPORT.md`, `RENDER.md`, `EVENT_LOG.md`, `TRACE.md`, `GRADE.md`, `DIAGNOSIS.md`, `ROUND_DECISIONS.md`, `OPTIMIZER_OUTPUTS.md`.

### Episode artifact table (`artifacts/README.md:8–17`) VERBATIM

| Artifact | Producer | Where it appears |
| --- | --- | --- |
| Results | Game | Local `results.json`, hosted `RESULTS_URI`, episode bundle `results` token |
| Replay | Game | Local `replay`, hosted `REPLAY_URI`, episode bundle `replay` token |
| Game logs | Game container / runner | Local `logs/game.*.log`, hosted `DEBUG_URI`, episode bundle `game_logs` token |
| Player logs | Player containers / runner | Local `logs/policy_agent_{slot}.log`, hosted `POLICY_LOG_URLS`, episode bundle `player_logs` token |
| Player artifact | Player containers | Local `policy_artifact_{slot}.zip`, hosted `PLAYER_ARTIFACT_UPLOAD_URLS`, episode bundle `player_artifact` token |
| Debug archive | Hosted runner | Hosted `DEBUG_URI` aggregate log zip |
| Error info | Hosted runner | Hosted `ERROR_INFO_URI`, episode bundle `error_info` token |
| Episode bundle | Bundling layer | On-demand zip assembled for post-episode consumers |

### What a game MUST emit
1. **`results.json`** — `RESULTS.md:31–37` VERBATIM:
> - Format: JSON object.
> - Validation: must satisfy `manifest.game.results_schema`.
> - Required cross-game field: `scores`, one number per player slot.
> - Local filename: `results.json`.
> - Hosted artifact: `RESULTS_URI`, uploaded as `application/json`.
> - Episode bundle entry: `results.json`.

2. **`replay`** — `REPLAY.md:56–64` VERBATIM:
> - Format: game-owned byte payload.
> - Local filename: `replay`.
> - Hosted artifact: `REPLAY_URI`, stored as raw `replay.replay`.
> - Episode bundle entry: `replay`.
> - Static viewer mode: immutable bundle `index.html`, with the replay URL in the `replay` query parameter.
> - Fallback replay server mode: same game image, with `COGAME_LOAD_REPLAY_URI` pointing at the replay bytes.
> - Replay viewer default: autoplay and loop from the recorded end back to tick 0.

### What a game MAY emit
- `player_failure.json` at `COGAME_PLAYER_FAILURE_URI` (typed `GamePlayerFailure`, §4)
- stdout/stderr → `logs/game.stdout.log`, `logs/game.stderr.log`; optional `COGAME_LOG_URI` posting

### ⚠️ CUSTOM GAME ARTIFACTS (e.g. a chat transcript): **ABSENT**
There is **no game-side custom-artifact slot**. The game's only outputs are `results` (JSON, schema-constrained, `additionalProperties` governed by *your* `results_schema`), `replay` (arbitrary game-owned bytes), logs, and the player-failure signal. The **only** free-form per-episode file in the platform is the **player artifact** — one `.zip` per player slot, written by the *player container*:

`PLAYER_ARTIFACT.md:26–36` VERBATIM:
> - Exactly one object per player slot.
> - Maximum size: 200 MB.
> - Format: a `.zip`. The player may bundle whatever it wants inside (parquet, sqlite, csv, json, trace files). The
>   platform stores and serves the bytes as-is and does not unzip them. The `.zip` extension is a storage convention,
>   not an enforced format.
> - Local filename: `policy_artifact_{slot}.zip` in the workspace root.
> - Hosted key: `jobs/{job_id}/policy_artifact_{slot}.zip`.
> - Content type: `application/zip`.
> - Purpose: profiling and debugging only.

Practical consequence for a chat transcript: put it **inside the replay bytes** (game-owned format, no schema) or **inside `results_schema`** as a declared field, or have players zip it. There is no third door.

### Naming rules / where things go
Local workspace layout (`runner/RUNNER_README.md:31–46`) VERBATIM:
> - `config.json` — concrete game config used for the episode (with runner-injected tokens)
> - `results.json` — game-written results, validated against `game.results_schema`
> - `replay` — game-written replay artifact (exact bytes written by the game container)
> - `player_failure.json` — optional typed terminal failure written by the game to its explicit URI
> - `logs/game.stdout.log`, `logs/game.stderr.log` — game container stdout/stderr
> - `logs/policy_agent_{slot}.log` — combined stdout+stderr for each player container
> - `policy_artifact_{slot}.zip` — optional artifact each player uploads (max 200 MB).

### Episode bundle
`EPISODE_BUNDLE.md:15` VERBATIM: "A bundle is a zip containing some subset of the following entries plus a `manifest.json` describing what's present"

Tokens → files (EPISODE_BUNDLE.md:17–24): `results`→`results.json`; `replay`→`replay` (uncompressed); `error_info`→`error_info.json`; `game_logs`→`logs/game.log`; `player_logs`→`logs/policy_agent_{slot}.log`; `player_artifact`→`artifacts/policy_artifact_{slot}.zip`.

Bundle `manifest.json` VERBATIM (EPISODE_BUNDLE.md:33–50):
```json
{
  "ereq_id": "ereq_...",
  "status": "success",
  "include": ["results", "replay", "game_logs", "player_logs"],
  "files": {
    "results": "results.json",
    "replay": "replay",
    "game_logs": {
      "combined": "logs/game.log"
    },
    "player_logs": {
      "0": "logs/policy_agent_0.log",
      "1": "logs/policy_agent_1.log"
    }
  }
}
```
API: `GET /v2/episode-requests/{ereq_id}/bundle?include=results,replay,player_logs`. Delivered to grader/diagnoser as `COGAME_EPISODE_BUNDLE_URI`. **`coworld bundle` CLI: planned, not implemented** (EPISODE_BUNDLE.md:66 — "A dedicated `coworld bundle` CLI command is still planned").

Access control (EPISODE_BUNDLE.md:100–106): `results`/`replay`/`error_info`/`game_logs` = anyone with episode access; `player_logs` and `player_artifact` = policy-scoped to owner (Softmax-internal gets all).

Supporting-role output URIs: `COGAME_GRADE_URI` (GRADE.md), `COGAME_DIAGNOSIS_URI` + `COGAME_TARGET_POLICY_URI` (DIAGNOSIS.md — "reserved and highly tentative"), `COGAME_OPTIMIZER_OUTPUT_URI` (OPTIMIZER_OUTPUTS.md). Reporter v2 emits typed output parts via `POST /v2/reporters/outputs`, no zip, no bundle (REPORT.md, TRACE.md, RENDER.md, EVENT_LOG.md).

---

## 7. `src/coworld/examples/paintarena/` — full tree + verbatim manifest

### File tree (25 files, all under `/home/claude/source/coworld/src/coworld/examples/paintarena/`)

```
Dockerfile
README.md
__init__.py
compose.yaml
coworld_manifest_template.json
diagnoser/__init__.py
diagnoser/paint_arena_diagnoser.py
game/__init__.py
game/client/admin.html
game/client/global.html
game/client/player.html
game/client/replay.html
game/docs/global_protocol_spec.md
game/docs/player_protocol_spec.md
game/server.py
grader/__init__.py
grader/paint_arena_grader.py
optimizer/README.md
optimizer/__init__.py
optimizer/paint_arena_optimizer.py
player/__init__.py
player/player.py
shared/__init__.py
shared/log_shipper.py
shared/supporting_role_io.py
```
Note: no `dist/` in-tree — `coworld build` writes `dist/coworld_manifest.json`.

### `coworld_manifest_template.json` — VERBATIM, complete

```json
{
  "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
  "tags": ["strategy", "real-time", "multiplayer"],
  "game": {
    "name": "paintarena",
    "description": "Continuous tick-based territory painting game used to certify the Coworld contract.",
    "owner": "coworld@softmax.com",
    "runnable": {
      "type": "game",
      "image": "{{PAINTARENA_IMAGE}}",
      "run": ["python", "-m", "coworld.examples.paintarena.game.server"],
      "source_url": "https://github.com/Metta-AI/coworld/tree/68257d7b450fb8013ed496538221cd2bd423e140/src/coworld/examples/paintarena/game"
    },
    "config_schema": {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": ["tokens", "players", "width", "height", "max_ticks", "tick_rate"],
      "properties": {
        "tokens": {
          "type": "array",
          "minItems": 2,
          "maxItems": 2,
          "items": {
            "type": "string",
            "minLength": 1
          }
        },
        "players": {
          "type": "array",
          "minItems": 2,
          "maxItems": 2,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name"],
            "properties": {
              "name": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        },
        "width": {
          "type": "integer",
          "minimum": 4,
          "maximum": 40
        },
        "height": {
          "type": "integer",
          "minimum": 4,
          "maximum": 40
        },
        "max_ticks": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000
        },
        "tick_rate": {
          "type": "number",
          "exclusiveMinimum": 0,
          "maximum": 60
        },
        "player_connect_timeout_seconds": {
          "type": "number",
          "minimum": 0,
          "default": 180
        }
      }
    },
    "results_schema": {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": ["scores", "painted_tiles", "ticks"],
      "properties": {
        "scores": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {
            "type": "number"
          }
        },
        "painted_tiles": {
          "type": "array",
          "minItems": 1,
          "maxItems": 4,
          "items": {
            "type": "integer",
            "minimum": 0
          }
        },
        "ticks": {
          "type": "integer",
          "minimum": 0
        }
      }
    },
    "protocols": {
      "player": {
        "type": "uri",
        "value": "https://github.com/Metta-AI/coworld/blob/main/src/coworld/examples/paintarena/game/docs/player_protocol_spec.md"
      },
      "global": {
        "type": "uri",
        "value": "https://github.com/Metta-AI/coworld/blob/main/src/coworld/examples/paintarena/game/docs/global_protocol_spec.md"
      }
    },
    "docs": {
      "readme": {
        "type": "uri",
        "value": "https://github.com/Metta-AI/coworld/blob/main/src/coworld/examples/paintarena/README.md"
      },
      "pages": [
        {
          "id": "rules.md",
          "title": "rules.md",
          "content": {
            "type": "text",
            "value": "# Paint Arena Rules\n\nTwo players move around a grid and paint the tile they stand on. Painting overwrites the previous owner. Final scores are the number of tiles painted with each player's color."
          }
        },
        {
          "id": "play_paintarena.md",
          "title": "play_paintarena.md",
          "content": {
            "type": "uri",
            "value": "https://github.com/Metta-AI/coworld/blob/main/src/coworld/examples/paintarena/README.md"
          }
        },
        {
          "id": "optimizer",
          "title": "optimizer.md",
          "content": {
            "type": "uri",
            "value": "https://github.com/Metta-AI/coworld/blob/main/src/coworld/examples/paintarena/optimizer/README.md"
          }
        }
      ]
    }
  },
  "player": [
    {
      "id": "sweep-painter",
      "name": "Sweep Painter",
      "type": "player",
      "image": "{{PAINTARENA_IMAGE}}",
      "run": ["python", "-m", "coworld.examples.paintarena.player.player"],
      "source_url": "https://github.com/Metta-AI/coworld/tree/68257d7b450fb8013ed496538221cd2bd423e140/src/coworld/examples/paintarena/player",
      "description": "Deterministic player that sweeps across the arena repainting tiles."
    }
  ],
  "commissioner": [
    {
      "id": "default-commissioner",
      "name": "Default Commissioner",
      "type": "commissioner",
      "description": "Game-agnostic round-robin commissioner with mean-score rankings.",
      "source_url": "https://github.com/Metta-AI/coworld-tools/tree/e6b7863c2619d260bb29f14364baf09c578c9f30/commissioners/commissioners/ruleset_strategy_commissioner",
      "image": "{{COMMISSIONER_IMAGE}}"
    }
  ],
  "grader": [
    {
      "id": "paint-arena-grader",
      "type": "grader",
      "name": "Paint Arena Grader",
      "description": "Scores a PaintArena episode as the absolute painted-tile margin divided by board area.",
      "source_url": "https://github.com/Metta-AI/coworld/tree/68257d7b450fb8013ed496538221cd2bd423e140/src/coworld/examples/paintarena/grader",
      "image": "{{PAINTARENA_IMAGE}}",
      "run": ["python", "-m", "coworld.examples.paintarena.grader.paint_arena_grader"]
    }
  ],
  "diagnoser": [
    {
      "id": "paint-arena-diagnoser",
      "type": "diagnoser",
      "name": "Paint Arena Diagnoser",
      "description": "Reads a PaintArena episode bundle plus target policy reference and emits a deterministic Markdown diagnosis zip.",
      "source_url": "https://github.com/Metta-AI/coworld/tree/68257d7b450fb8013ed496538221cd2bd423e140/src/coworld/examples/paintarena/diagnoser",
      "image": "{{PAINTARENA_IMAGE}}",
      "run": ["python", "-m", "coworld.examples.paintarena.diagnoser.paint_arena_diagnoser"]
    }
  ],
  "optimizer": [
    {
      "id": "paint-arena-reference-optimizer",
      "type": "optimizer",
      "name": "Paint Arena Reference Optimizer",
      "description": "Reference optimizer: reads a Coworld manifest plus optional report, grader, and diagnoser artifact URI lists, then writes a deterministic PaintArena policy-improvement plan.",
      "source_url": "https://github.com/Metta-AI/coworld/tree/68257d7b450fb8013ed496538221cd2bd423e140/src/coworld/examples/paintarena/optimizer",
      "image": "{{PAINTARENA_IMAGE}}",
      "run": ["python", "-m", "coworld.examples.paintarena.optimizer.paint_arena_optimizer"]
    }
  ],
  "variants": [
    {
      "id": "default",
      "name": "Default",
      "game_config": {
        "width": 12,
        "height": 8,
        "max_ticks": 100,
        "tick_rate": 5,
        "player_connect_timeout_seconds": 180,
        "players": [
          {
            "name": "Sweep Painter 1"
          },
          {
            "name": "Sweep Painter 2"
          }
        ]
      },
      "description": "Short two-player territory painting smoke-test configuration."
    }
  ],
  "certification": {
    "game_config": {
      "width": 12,
      "height": 8,
      "max_ticks": 100,
      "tick_rate": 5,
      "player_connect_timeout_seconds": 180,
      "players": [
        {
          "name": "Sweep Painter 1"
        },
        {
          "name": "Sweep Painter 2"
        }
      ]
    },
    "players": [
      {
        "player_id": "sweep-painter"
      },
      {
        "player_id": "sweep-painter"
      }
    ]
  }
}
```

Note: **no `game.version`** (build stamps it), **no `reporter`** section, **no `tokens`** in variant/certification configs.

### `compose.yaml` — VERBATIM
```yaml
services:
  paintarena:
    image: coworld-paintarena:latest
    platform: linux/amd64
    build:
      context: .
  commissioner:
    image: ghcr.io/metta-ai/commissioners-default:latest
    platform: linux/amd64
```
Placeholder derivation (`/home/claude/source/coworld/src/coworld/bundle.py:127–132`): service name → `{{<UPPERCASE, dashes→underscores>_IMAGE}}`. So `paintarena` → `{{PAINTARENA_IMAGE}}`, `commissioner` → `{{COMMISSIONER_IMAGE}}`. Service with a `build:` context is built; the other is pulled.

### `Dockerfile` — VERBATIM
```dockerfile
FROM docker.io/library/python:3.12-slim

RUN pip install --no-cache-dir fastapi==0.115.5 uvicorn[standard]==0.34.2 websockets==15.0.1 requests==2.32.3 pyarrow==16.1.0

ENV PYTHONPATH=/app
WORKDIR /app

# Mirror the source-tree layout so absolute imports
# (`coworld.examples.paintarena.*`) resolve identically here and in tests.
# The `coworld` and `coworld.examples` packages contribute nothing else to
# the runtime image, so empty stub __init__.py files suffice.
RUN mkdir -p /app/coworld/examples && \
    touch /app/coworld/__init__.py /app/coworld/examples/__init__.py

COPY __init__.py /app/coworld/examples/paintarena/__init__.py
COPY shared /app/coworld/examples/paintarena/shared
COPY game /app/coworld/examples/paintarena/game
COPY player /app/coworld/examples/paintarena/player
COPY grader /app/coworld/examples/paintarena/grader
COPY diagnoser /app/coworld/examples/paintarena/diagnoser
COPY optimizer /app/coworld/examples/paintarena/optimizer

CMD ["python", "-m", "coworld.examples.paintarena.game.server"]
```
**One image, six roles** — each manifest runnable picks its entrypoint with its own `run` argv.

### How docs are packaged
Three mechanisms coexist:
1. `game.docs.readme` → **URI** pointing at the GitHub-hosted `README.md` (not an upload).
2. `game.docs.pages[0]` (`rules.md`) → **inline text** with escaped `\n` — the pattern for embedding a doc directly in the manifest.
3. `game.docs.pages[1..2]` → URIs. `game.protocols.player`/`global` → URIs to `game/docs/*_protocol_spec.md`.

### How the certification fixture is wired
`certification.players` = `[{"player_id":"sweep-painter"}, {"player_id":"sweep-painter"}]` — the same bundled player id in both slots, resolved by id against `manifest.player[].id`. `certification.game_config` is a token-free copy of the `default` variant config. The certifier injects placeholder tokens, validates against `config_schema`, then launches 1 game + 2 player containers. Note this satisfies AUTHORING.md:157 ("a `certification` fixture that seats **every** declared player") because only one player is declared.

### Variants
Exactly one: `id: "default"`. Per COMMISSIONER.md:714–717, hosted default v2 rounds select **the manifest's first variant**.

---

## 8. CLI SURFACE

**Code:** `/home/claude/source/coworld/src/coworld/cli.py` (1339 lines, `app = typer.Typer(...)` at :53), `/home/claude/source/coworld/src/coworld/tournament_cli.py` (1358 lines, `register_tournament_commands(app)`), `/home/claude/source/coworld/src/coworld/__main__.py`. Entrypoint declared in `pyproject.toml` as `coworld.cli:app`.

Sub-apps mounted: `hosted-game` (cli.py:56), `league` (:85), `secret` (:88), `player` (:245, from softmax-cli), `xp-request` (tournament_cli.py:62), `reporters` (:128).

### Top-level commands (cli.py)

| Command | file:line | Args / flags |
| --- | --- | --- |
| `certify` | cli.py:275 | `MANIFEST_URI` · `--server` · `--timeout-seconds` (≥1, **default 60.0**) · `--open-report/--no-open-report` (default on) |
| `build` | cli.py:352 | `--version` (**required**) · `--project` (default `.`) · `--compose` (default `compose.yaml`) · `--template` (default `coworld_manifest_template.json`) · `--output` (default `dist/coworld_manifest.json`) |
| `play` | cli.py:385 | `MANIFEST_URI` · `[episode_request.json \| PLAYER_IMAGE...]` · `--run` (repeat) · `--output-dir/-o` · `--server` · `--variant` · `--timeout-seconds` (default 3600) · `--player-exit-timeout-seconds` (default 30) · `--use-bedrock` · `--aws-profile` · `--aws-region` · `--secret-env KEY=VALUE` (repeat) · `--open-browser/--no-open-browser` |
| `list` | cli.py:489 | `--server --limit --offset --json` |
| `next-version` | cli.py:504 | `COWORLD_NAME` · `--server` |
| `show` | cli.py:521 | `COWORLD_ID` · `--server --json` |
| `status` | cli.py:538 | `COWORLD_ID` · `--server` · `--wait-hosted-smoke/--no-wait-hosted-smoke` · `--hosted-smoke-timeout-seconds` · `--json` |
| `images` | cli.py:573 | `[IMAGE_ID]` · `--server --limit --offset --json` |
| `upload-coworld` | cli.py:596 | `[MANIFEST_PATH]` · `--from-coworld` · `--version` · `--patch` · `--image TARGET=IMAGE` (repeat) · `--server` · `--timeout-seconds` (60) · `--wait-hosted-smoke/--no-…` (default **on**) · `--hosted-smoke-timeout-seconds` (1800) · `--wait-certification/--no-…` (default **off**) · `--certification-timeout-seconds` (1800) |
| `patch-commissioner` | cli.py:668 | `COWORLD_NAME` `IMAGE` · `--runnable-id --version --server` |
| **`download`** | cli.py:691 | `COWORLD_REF` · `--output-dir/-o` (default `./coworld`) · `--server` · `--refresh` |
| `upload-policy` | cli.py:714 | `IMAGE` · `--name/-n` (req) · `--run` · `--secret-env` · `--tag` · `--use-bedrock` · `--bedrock-model` · `--server` |
| `submit` | cli.py:779 | `POLICY[:vN]` · `--league/-l` (req) · `--server` · `--open-browser/--no-open-browser` · `--auto-champion` (default `always`) · `--preference KEY=VALUE` |
| `run-episode` | cli.py:821 | `MANIFEST_URI` · `[request.json \| IMAGE...]` · `--run` · `--output-dir/-o` · `--episodes/-n` (≥1, default 1) · `--server` · `--variant` · `--timeout-seconds` (3600) · `--verify-replay/--no-verify-replay` · `--use-bedrock --aws-profile --aws-region --secret-env` |
| `scrimmage` | cli.py:959 | `MANIFEST_URI` `TARGET_PLAYER_IMAGE` · `--run --output-dir/-o --server --variant --timeout-seconds --verify-replay/--no-… --use-bedrock --aws-profile --aws-region --secret-env` |
| `replay` | cli.py:1046 | `MANIFEST_URI` `REPLAY_PATH` · `--server` · `--timeout-seconds` (60) · `--open-browser/--no-open-browser` |
| `optimize` | cli.py:1073 | `[COWORLD]` · `--port` · `--open-browser/--no-…` · `--refresh` · `--optimizer-repo` · `--optimizer-ref` · `--optimizer-dir` · `--server` |

Sub-apps:
- `league create <coworld_name> [--template|-t] [--set K=V] [--server] [--json]` (cli.py:91) · `league list` (:131) · `league update <coworld_name> --set K=V` (:156)
- `secret put <coworld_name> <secret_name> <secret_path>` (cli.py:182) · `secret list <coworld_name>` (:203) · `secret delete <coworld_name> <secret_name>` (:225)
- `hosted-game create <coworld_id> [--variant] [--spectators/--no-spectators] [--json]` (cli.py:1138) · `hosted-game join <session_id>` (:1165)
- `player list | use <player-id> | unset` (mounted from softmax-cli, cli.py:245)

### tournament_cli.py commands

`xp-request create <body.json|->` (:64) · `xp-request list [--mine --limit --offset]` (:82) · `xp-request get <id>` (:98) · `xp-request episodes <id>` (:111)
`reporters list [-q/--query] [--type] [--mode] [--author] [--limit] [--offset]` (:130) · `reporters search <text>` (:158) · `reporters show <rptr_...>` (:172)
`leagues [id]` (:185) · `divisions [id] [--league/-l]` (:207) · `results <league_id>` (:234) · `rounds [id] [--league/-l --division/-d --status --limit --offset]` (:264) · `memberships [--league/-l --division/-d --policy/-p --player --mine --active-only --champions-only --limit]` (:298) · `retire-membership <id> [--reason]` (:333) · `submissions [--league/-l --policy/-p --player --mine --limit]` (:350) · `events [--league/-l --division/-d --round/-r --event-type --audience --policy/-p --player --limit]` (:377) · `episodes [ereq_id] [--division/-d --round/-r --policy/-p --mine --with-replay --limit --offset]` (:410) · `episode-stats <ereq_id>` (:463) · `episode-results <ereq_id> [--output/-o]` (:476) · `episode-logs <ereq_id> [--list --game --agent N --mine --artifact --download-dir --output/-o]` (:491) · `replays [--division/-d --round/-r --policy/-p --mine --download-dir/-o --limit --offset]` (:619) · `replay-open <ereq_id> [--hosted --timeout-seconds --open-browser/--no-… --with-artifacts --artifacts-dir --mine]` (:669)

### ⭐ DOWNLOADING A PUBLISHED COWORLD — YES, `coworld download`

`cli.py:691–711`, arg help VERBATIM:
> `coworld_ref`: "Coworld ID to download, or Coworld name to download its canonical version."
> `--output-dir/-o`: "Directory for downloaded files." default `Path("./coworld")`
> `--refresh`: "Re-fetch the Coworld and re-pull images even when it is already cached."

COOKBOOK.md:182–188 VERBATIM:
```bash
uv run coworld download cow_... --output-dir ./coworld
uv run python -m json.tool ./coworld/cow_.../coworld_manifest.json
```
> Downloaded packages live under `./coworld/<coworld-id>/` and include `coworld_manifest.json`, `coworld_images.json`, and
> an `AGENTS.md` for local policy work. The downloaded manifest rewrites uploaded image references to local Docker tags
> after pulling the public images.

Implementation: `/home/claude/source/coworld/src/coworld/upload.py:1476–1526` (`download_coworld_cmd`) — writes `<out>/<cow_id>/coworld_manifest.json`, `coworld_images.json`, `AGENTS.md` (canned text from `upload.py:50`, `DOWNLOAD_AGENTS_MD`). Python API: `coworld.upload.download_coworld(coworld_id, server=...)` returns the manifest payload only.

**For your bitworld reference:** `uv run coworld download bitworld -o ./coworld` (name resolves to the canonical version) — requires `uv run softmax login`. Note only **bundled** player images are ECR-Public-mirrored and pullable; **submitted policy** images are never downloadable (PLAYER.md:115–122). Also note: `bitworld` appears in this repo **only** as an `engine_runtime` enum value (`types.py:18`; `COWORLD_MANIFEST.md:188`) — there is no bitworld package vendored here.

Also relevant: many commands accept a **Coworld ID directly in place of a manifest path** — `certify`, `play`, `run-episode`, `scrimmage`, `replay` all take "Path, URI, or Coworld ID for coworld_manifest.json" and auto-download to `./coworld/<coworld-id>/` (`cli.py:1024` `_materialized_manifest_path`, `LIFECYCLE.md:127–128`).

---

## 9. LIVE HUMAN INPUT — every path into a RUNNING episode

This is the decisive section for a sponsor-gift design. Here is every mechanism, concretely.

### 9.1 LOCAL: `coworld play` → browser player client (the primary human path)

`coworld play` (`cli.py:385`) calls `play_coworld` (`/home/claude/source/coworld/src/coworld/play.py:112`). It starts the game container **publishing 8080 on a random `127.0.0.1` port** (`play.py:191–192`), then builds three link families (`play.py:385–399`) VERBATIM:

```python
def build_play_links(
    players: list[PlayerLaunchSpec],
    tokens: list[str],
    *,
    game_port: int,
) -> PlayLinks:
    player_links = [
        f"http://127.0.0.1:{game_port}/client/player?{_player_query(slot, tokens[slot])}"
        for slot, _player in enumerate(players)
    ]
    return PlayLinks(
        players=player_links,
        global_=f"http://127.0.0.1:{game_port}/client/global",
        admin=f"http://127.0.0.1:{game_port}/client/admin",
    )
```

`PlayLinks` dataclass (`play.py:61–66`): `players: list[str]`, `global_: str`, `admin: str`.
Printed by `_print_play_session` (`cli.py:1208–1222`) as `Player clients:` / `Global client:` / `Admin client:` / `Extra local ports:`.

**Critical semantics:** `coworld play` **still launches one player container per slot** (`play.py:218–250`) — it does *not* leave a seat open. A human takes over a seat by opening `/client/player?slot=N&token=…` and racing/co-driving the same slot's websocket; the game server decides. In Paint Arena's server, a second connection to the same slot **replaces** `state.players[slot]` (`game/server.py:228`), so the browser effectively hijacks the seat. To leave seats genuinely free, COOKBOOK.md:329 says: *"For browser-controlled play, skip the player containers and open the player client links below"* — i.e. use the raw-Docker path, not `coworld play`.

### 9.2 LOCAL: the `/admin` websocket (out-of-band control of a live episode) ⭐

**This is the most direct existing "external input mutates a running episode" mechanism, and it is game-owned, not platform-mandated.**

- Link built unconditionally by the platform: `play.py:398` → `/client/admin`.
- Printed by the CLI: `cli.py:1216` → `typer.echo(f"Admin client: {session.links.admin}")`.
- **NOT in the GAME.md required-routes list** (§4 above) — GAME.md never mentions `/admin`. `LIFECYCLE.md:131` VERBATIM: "Print browser URLs for player slots, the global viewer, and local admin/debug surfaces when available."
- Paint Arena implements it (`/home/claude/source/coworld/src/coworld/examples/paintarena/game/server.py:157–159, 197–208`) VERBATIM:

```python
@app.get("/client/admin")
def admin_client() -> HTMLResponse:
    return HTMLResponse((CLIENT_DIR / "admin.html").read_text())
...
@app.websocket("/admin")
async def admin(websocket: WebSocket) -> None:
    await websocket.accept()
    await websocket.send_json(_snapshot())
    async for command in websocket.iter_json():
        if command["command"] == "pause":
            state.paused = True
        elif command["command"] == "resume":
            state.paused = False
        elif command["command"] == "tick_rate":
            state.tick_rate = float(command["tick_rate"])
        await websocket.send_json(_snapshot())
```

Documented in `game/docs/global_protocol_spec.md:31–38` VERBATIM:
> For local development, browsers may request `GET /client/admin` and open `/admin` as a websocket. The admin websocket
> accepts:
>
> ```json
> { "command": "pause" }
> { "command": "resume" }
> { "command": "tick_rate", "tick_rate": 15 }
> ```

**No auth on `/admin`.** No token check, unlike `/player` (`server.py:221–225` validates `slot` + `token`). Paint Arena README:33 calls it "an admin link for pause, resume, and tick-rate controls". Explicitly framed as "For local development".

**For a sponsor-gift, `/admin` is the obvious template**: it is an arbitrary game-defined websocket route that mutates live episode state, the platform already prints a link to it in `coworld play`, and nothing in the contract restricts its command vocabulary. Caveat: it is local-only in practice (see 9.5) and unauthenticated in the reference implementation — add your own token if you copy it.

### 9.3 LOCAL: `/global` websocket accepts inbound messages

`server.py:172–194`: the global viewer runs a `_send_global_snapshots` task **and** a `_drain_global_messages` task. The drain currently discards (`async for _ in websocket.iter_json(): pass`), but the socket is bidirectional and unauthenticated. A game could use `/global` for spectator input. GAME.md only specifies `/global` as "a live global viewer"; AUTHORING.md:122 calls it "the spectator contract: the read-only stream". So: **mechanism exists, contract says read-only.**

### 9.4 LOCAL: `COWORLD_LOCAL_EXTRA_PORTS` — arbitrary extra TCP ingress

`GAME.md:75–90`, `RUNNER_README.md:9–15`, `runner.py:44–47, 828–931`. Declare in `manifest.game.runnable.env`:
```json
"env": { "COWORLD_LOCAL_EXTRA_PORTS": "3724:3724,8085:8085" }
```
Game receives `COWORLD_LOCAL_PORT_<container_port>=127.0.0.1:<host_port>` and `COWORLD_LOCAL_PORTS_JSON`. **`coworld play` prints them** (`cli.py:1217–1221`: "Extra local ports:"). This is the sanctioned way to expose a *second* server (e.g. a sponsor-gift HTTP API) alongside the game. **Local Docker runner only** — `COWORLD_MANIFEST.md:212`: "Hosted/Kubernetes runners do not support arbitrary extra host ports yet."

### 9.5 HOSTED: `coworld hosted-game` (exists in code, disclaimed in docs) ⚠️

Code path is real and complete:
- `cli.py:1138–1162` `hosted-game create <coworld_id> [--variant] [--spectators/--no-spectators]` → prints `Hosted game:`, `Player slots:`, `Player command:`, `Player URL:`, `Spectator URL:`.
- `cli.py:1165–1178` `hosted-game join <session_id>` → prints `Slot:`, `Player:`, `URL:`.
- Client: `/home/claude/source/coworld/src/coworld/upload.py:656–683` → `POST /v2/coworlds/play/session` with `{coworld_id, variant_id, allow_spectators}`; `POST /v2/coworlds/play/session/{session_id}/join`.
- Response models `upload.py:184–204`: `HostedGameCreateResponse{session_id, join_url, lobby_url, player_count, global_url}`; `HostedGameJoinResponse{player_url, slot, player{slot,label,user_id,player_id,player_name,joined_at}}`.
- Proxy URL shapes visible in tests (`/home/claude/source/coworld/tests/test_coworld_upload_cli.py:1573,1609`):
  `https://api.example.com/v2/coworlds/play/session/ps_00000000/proxy/client/global`
  `https://api.example.com/v2/coworlds/play/session/ps_00000000/proxy/client/player`

**How the browser reaches the game through that proxy — the `address` query param.** `KUBERNETES_RUNNER_README.md:147–149` VERBATIM:
> The `address` query parameter is only for browser client pages served through an HTTP proxy, such as hosted play. The
> Kubernetes runner does not use `address` for policy containers: `COWORLD_PLAYER_WS_URL` is the direct game websocket URL
> and already includes the required `slot` and `token` query params.

Paint Arena's player client implements it (`game/client/player.html:175–187`) VERBATIM:
```js
const pageUrl = new URL(window.location.href)

function websocketAddress(path) {
  const address = pageUrl.searchParams.get('address')
  const target = new URL(address || window.location.href, window.location.href)
  if (target.protocol === 'http:') target.protocol = 'ws:'
  if (target.protocol === 'https:') target.protocol = 'wss:'
  if (!address) target.pathname = target.pathname.replace(/\/client\/player$/, path)
  target.hash = ''
  return target
}

const websocketUrl = websocketAddress('/player')
```
**If you want a hosted browser surface, your client HTML must honor `?address=`.** Paint Arena's `admin.html` does **not** (`admin.html:40–47` derives the WS URL from `window.location` only) — so `/client/admin` would break behind the hosted proxy as written.

**But the docs disclaim hosted play three times:**
- `AGENTS.md` ("Manifest And Role Contracts") VERBATIM: "Do not describe `coworld hosted-game` as a supported player workflow unless product/runtime support is restored. Current hosted execution means tournament jobs where the platform runs the game and every player container."
- `README.md:91–93` (quoted in §1).
- `LIFECYCLE.md:46–47` VERBATIM: "Coworld does not currently provide a supported hosted game-only lobby where users connect their own remote players. Hosted execution means tournament jobs in which the platform runs the game container and every player container."
- Also `COWORLD_MANIFEST.md:145`: "Hosted play and Antfarm dispatch do not resolve Coworld secrets."
- `COOKBOOK.md:1153` VERBATIM: "Avoid relying on internal routes such as Coworld browser proxy paths, job runner internals, SQL/admin routes, legacy tournament routes, social feed routes, or one-off maintenance endpoints."

**Verdict:** `hosted-game` is a live-but-unsupported code path. Do not build a product on it; do prototype against it knowing it may be off in your environment.

### 9.6 HOSTED (league/tournament): live human input is **ABSENT**

`LIFECYCLE.md:159–160` VERBATIM: "This is the only supported hosted game execution path: the game and all player containers run inside platform-managed Kubernetes jobs. For browser play while developing a Coworld or player, use local `coworld play`."

`KUBERNETES_RUNNER_README.md:53–64`: the game listens on 8080 inside the Job; the worker creates a **ClusterIP** Service so *player pods* can reach it. ClusterIP = cluster-internal only. No Ingress, no NodePort, no LoadBalancer anywhere in `/home/claude/source/coworld/src/coworld/runner/kubernetes_runner.py`. Grep for `ingress` across the repo returns **zero** hits. The only sidecar is `bedrock-sidecar` (`bedrock_sidecar_wiring.py:6`), an **egress** signing proxy for Bedrock — not ingress.

So in a league round: **no human can send input to a running episode.** Everything must come from the game container's own logic, its config, or its player containers.

### 9.7 Ways state can be *pre-injected* into a hosted episode (the realistic sponsor-gift levers)

Since live ingress is closed hosted-side, these are the seams:
1. **`variants[].game_config` / `certification.game_config`** — static per-variant config the game reads at startup from `COGAME_CONFIG_URI`.
2. **`EpisodeRequest.game_config_overrides`** — the commissioner can pass per-episode config deltas (`/home/claude/source/coworld/src/coworld/commissioner/protocol.py:82`). Also on `PersistentPlayerRuntimeRequest` (`:93`). **This is the only per-episode, scheduler-driven input channel in hosted runs.**
3. **`PersistentPlayerRuntimeRequest.config_overlay_secret`** (`protocol.py:94`) — a private, named config overlay for persistent leagues.
4. **`secret://coworld/<name>/<secret>` env** resolved into the game container at hosted dispatch (`COWORLD_MANIFEST.md:142–146`) — your game could use a signing key to authenticate an *outbound* call it makes to a service you run. The game container has normal outbound network (it calls Bedrock). **A game that polls your own external endpoint is the only unblocked "live external input" path in hosted runs**, and nothing in the docs forbids it — but nothing sanctions it either; `source_url` provenance is checked, network egress policy is not documented here.
5. **Player-side**: a player container can carry `--secret-env` values and call out; players are the only in-flight actors besides the game.

### 9.8 Everything the keyword sweep found (exhaustive)

- `sidecar` → **only** Bedrock egress signing: `runner/bedrock_sidecar_wiring.py`, `runner/kubernetes_runner.py:452`, `docs/BEDROCK.md:6,20`, `AGENTS.md`.
- `ingress` → **zero hits** anywhere in the repo.
- `spectator` → `cli.py:1143,1150,1159–1162` (`--spectators/--no-spectators`, `Spectator URL`), `upload.py:661,669` (`allow_spectators`), `AUTHORING.md:42,122` (spectator = read-only `/global` contract). Nothing else.
- `admin` → `play.py:66,398`; `cli.py:1216`; `paintarena/game/server.py:157,197`; `paintarena/game/client/admin.html`; `global_protocol_spec.md:31`; `LIFECYCLE.md:131`; `paintarena/README.md:33`; `COMMISSIONER.md:429,434` (an abort *reason* string, unrelated); `COOKBOOK.md:1153` (don't use admin routes).
- `debug_link` / `debug-link` → **ABSENT**. Closest: `LIFECYCLE.md:131` "local admin/debug surfaces"; `DEBUG_URI`/debug archive (post-episode logs, not live).
- `endpoint` → Bedrock (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME`) and generic API-endpoint prose only.
- `human` → only "human-readable"/"human-facing" descriptions + `TranscriptStepKind = Literal["auto", "human"]` (`types.py:524`, certifier examiner kind) + AUTHORING prose.
- `interactive` → optimizer workbench (`docs/README.md:179`, `templates/roles/optimizer/README.md:3`); `coworld play` "optimized for interactive debugging" (`LIFECYCLE.md:125`).

---

## 10. ECONOMY PRIMITIVES — **ABSENT**

Full-repo search (excluding `templates/optimizers/**` boilerplate) for `softcoin`, `coin`, `wallet`, `currency`, `credit(s)`, `sponsor`, `payment`, `budget`, `shop`, `purchase`, `pay`, `marketplace` produced **no platform economy primitive**. There is no wallet, no currency, no ledger, no balance, no transfer, no shop, no sponsorship object, no gift primitive in the manifest schema, the runner, the CLI, or the artifact contracts.

Every hit is unrelated:
- `docs/BEDROCK.md:156` — an HTTP response header `x-coworld-spend-usd` for **LLM spend metering** (read-only observability for a player: "A budget-aware…"). This is the only money-adjacent runtime signal in the repo, and it measures Bedrock cost, not game economy.
- `docs/roles/REPORTER.md:55,163,177` — reporter runs are "metered, budgeted, and recorded in the run's trace"; `llm` tool "metered against your run's budget, billed to the run's requester"; "Budget exhaustion is a typed error". Platform compute budget for reporters, not a player-facing economy.
- `docs/artifacts/REPORT.md:48` — "output budget (256 MiB default)". Storage.
- `docs/roles/COMMISSIONER.md:820` — "`defaults.stage` sets the per-round **episode** budget". Episode-count scheduling.
- `SCHEMA_PRD.md:130`, `docs/coworlds-expert-agent/knowledge/*` — the verb "pay off"/"pay attention". Prose.

**Conclusion:** any softcoin / sponsor-gift economy is entirely yours to build inside your game container's own state, config, and results/replay. The platform offers zero primitives, zero persistence between episodes (except commissioner `state`, ≤10 MB opaque blob — `ROUND_DECISIONS.md:20`), and zero identity beyond `game_config.players[].name` and league `player_id`.

---

## 11. CERTIFICATION — what `certify` actually checks

**Files:** `/home/claude/source/coworld/CERTIFIER_PRD.md` (22.7 KB), `/home/claude/source/coworld/src/coworld/certifier.py` (935 lines), `/home/claude/source/coworld/src/coworld/transcripts/coworld-executable.transcript.md`, `/home/claude/source/coworld/src/coworld/certification_report.py`, `/home/claude/source/coworld/src/coworld/report.py`.

`certifier.py:73` — `EXECUTABLE_TRANSCRIPT_PATH = Path(__file__).parent / "transcripts" / "coworld-executable.transcript.md"`. The markdown transcript is the source of truth for *meaning*; the code is the *implementation* (transcript header, line 5–7). `certifier.py` asserts executed step ids == declared step ids (`_assert_transcript_complete`, `:741`).

### The 10 steps — transcript table VERBATIM (`coworld-executable.transcript.md:13–22`)

| id | kind | checks | pass | how |
| --- | --- | --- | --- | --- |
| matriculate | auto | manifest conforms to the Coworld schema | schema validates | Parse the manifest and validate it against the generated coworld_manifest_schema.json; refuse to grade if it does not conform. |
| source-resolves | auto | every declared GitHub source_url resolves and carries a Dockerfile | all GitHub sources resolve; mutable refs are reported as warnings | For each GitHub runnable source_url, fetch its contents at the declared ref or repository default branch and confirm it (or an ancestor directory) contains a Dockerfile. Full commit SHAs are preferred for stable provenance, but short SHAs, branches, tags, and bare repository URLs pass with warning text because they are checked at certification run time. |
| images-reachable | auto | every declared image is pullable or inspectable | all images reachable | Run docker image inspect locally and fall back to docker manifest inspect for remote images. |
| fixture-conforms | auto | the certification fixture validates against game.config_schema after runner token injection | fixture schema validates | Inject synthetic runner tokens into certification.game_config and validate the concrete fixture against the manifest's game.config_schema before launching containers. |
| smoke-episode | auto | the game and certification players run one episode | episode completes | Launch the game plus the certification players from the manifest fixture and run a single episode to completion. |
| results-conform | auto | episode results validate against results_schema | schema validates | Load the episode results artifact and validate it against the manifest's results_schema. |
| replay-present | auto | a replay artifact was produced | replay file exists | Confirm the smoke episode wrote a replay artifact to the workspace. |
| replay-loadable | auto | the replay artifact can be loaded by the game replay server | replay server emits a frame | Start the game image in replay mode with COGAME_LOAD_REPLAY_URI, verify GET /client/replay, and wait for a frame from the /replay WebSocket. |
| players-run | auto | every declared player actually started on the smoke episode (not just declared) | each declared player runs, not just resolves | Confirm the smoke episode left launch logs for the game and for every declared player via at least one certification slot. |
| supporting-roles | auto | declared supporting roles satisfy the currently implemented Executable checks | reporter references validate and commissioners pass; unavailable harnesses are recorded as inert | Statically validate declared reporter references (platform references are recorded; wasm references must name a non-empty component inside the package and declare purpose, world, and typed outputs — full semantic validation happens at platform submission); probe declared commissioners over /healthz and /round with schedule_rounds_request; record graders and diagnosers as declared but harness unavailable; skip optimizers for Executable. |

Transcript preamble line 9 VERBATIM: "Every step is `auto` — a robot grants Executable alone (`CERTIFIER_PRD.md` §5)."

### Number of runs
**Exactly ONE smoke episode.** Transcript `smoke-episode`: "run a single episode to completion". No repeat run, no A/B, no cross-run comparison anywhere in `certifier.py`.

### Timeouts
- `certify_coworld(..., timeout_seconds: float = 60.0)` — `certifier.py:400`.
- CLI `--timeout-seconds` min 1.0, **default 60.0** — `cli.py:279`.
- Same value is reused for the replay-loadable probe (`certifier.py:412`) and supporting-role probes (`:416, 526`).
- Commissioner websocket probe: `ping_timeout_seconds: float = 30.0` (`certifier.py:694`).
- Hosted certification (auto-queued post-upload): `--certification-timeout-seconds` default 1800.0 (`cli.py:648–651`); `--hosted-smoke-timeout-seconds` default 1800.0.
- Hosted episode ceiling: `episode_timeout_minutes` 1..100, default 20 (`types.py:459–472`).

### Extra checks not in the transcript table
- **Tags are mandatory for certification.** `certifier.py:461–465` calls `load_coworld_package(manifest_path, require_certification_tags=True)`; `certifier.py:151–152` raises `ValueError("Coworld certification requires at least three manifest tags")` when `tags is None`. Step feedback string: `"Manifest schema and certification tags validated."`
- **Invalid-token rejection.** `LIFECYCLE.md:105` VERBATIM: "Check the first player browser route and verify that an invalid player token is rejected." (Local runner sequence step 9.)
- Certifier reserves synthetic IDs for the probe: `_CERTIFICATION_LEAGUE_ID`, `_CERTIFICATION_DIVISION_ID`, `_CERTIFICATION_POLICY_IDS` (`certifier.py:76–78`).
- On success, `cache_certified_manifest(manifest_path)` (`cli.py:307`) — `upload-coworld` reuses that proof.
- `certification_report.html` written into the artifact workspace and opened by default (`cli.py:330–349`).
- `/home/claude/source/coworld/src/coworld/report.py` — "the safe-render-profile checker `coworld certify` enforces on commissioner round reports" (`AGENTS.md`, Source Layout).

### DETERMINISM: **NOT CHECKED BY `certify`** ⚠️

There is no repeat-episode comparison, no seed-fixing, no state hashing anywhere in `certifier.py` or the transcript. Determinism is a **documented authoring invariant with no automated gate**:

`AUTHORING.md:52–58` VERBATIM:
> **The determinism invariant.** The initial state must be a pure function of the seed, and the state evolution a pure
> function of state plus actions. No wall-clock reads, no ambient randomness — route all randomness through a PRNG seeded
> from the config. This single invariant is what makes everything downstream work: reproducible tests, meaningful
> certification, replay/episode parity, and seeded hosted runs. Keep the seed **optional** in your config schema: absent
> means the game mints a fresh random seed (board variety across episodes), present means exactly reproducible. Never
> coerce an absent seed into a string like `"undefined"` or a constant default — both collapse every episode onto one
> board, and that class of bug ships silently because everything still "works".

`AUTHORING.md:180–183` (Rung 1, your own tests): "same seed twice produces identical initial state, and an identical trajectory under a scripted policy; no seed produces differing states across runs; a reset or new episode mints a fresh seed."

Note Paint Arena's `config_schema` has **no `seed` field at all** — so `run-episode -n N` seed incrementing (`cli.py:933–936`, only fires when `"seed" in spec.game_config` and it's an `int`) is a no-op for Paint Arena.

Calibration warnings, `AUTHORING.md:220–223` VERBATIM:
> - **A low or zero certification score is normal.** The fixture is a protocol smoke check, not the mission — it proves
>   the machinery runs, not that anyone played well.
> - **Certification is necessary, not sufficient.** It waits for one frame from the replay server; only you can confirm
>   the replay _viewer_ shows the right game. Open the printed replay URL and watch it before uploading.

### CERTIFIER_PRD.md degrees (§5, VERBATIM excerpt)
> - **Matriculated** — statically a Coworld (schema conforms). Admission, not a degree.
> - **Executable** — the parts actually run end-to-end and emit output. **Fully automated**; machine-checkable integrity. This is the robot's to grant alone.
> - **Optimizable** — the **viability floor**: the loop closes *once*. A human examiner, using **only** the Coworld's shipped parts (cold, self-bootstrapping), drives the optimizer to **one verified improvement** and attests the loop closed. […]

§9 "What exists today" VERBATIM: "Grader and diagnoser run harnesses do not exist yet" and "Optimizable has no automated implementation today, by design."

Typed episode failure taxonomy (CERTIFIER_PRD.md §9) VERBATIM: `player_error`, `game_unhealthy`, `game_contract_violation`, `results_missing`, `results_malformed`, `replay_missing`, `replay_unloadable`, `episode_timeout`, `crash`.

CERTIFIER_PRD headings: §1 North Star, §2 Certifier:grader::integrator:differentiator, §3 The certificate, §4 Lifecycle, §5 Category and degrees, §6 Transcript and degree files (6.1–6.4), §7 Self-bootstrapping, §8 Trust model, §9 What exists today, §10 Open questions.

---

## 12. LEAGUE + AGENTS.md

### 12.1 How leagues run episodes

**Contract doc:** `/home/claude/source/coworld/src/coworld/docs/roles/COMMISSIONER.md` (978+ lines) — **Status:** "live for container leagues".
**Protocol code:** `/home/claude/source/coworld/src/coworld/commissioner/protocol.py`.

Round lifecycle, `COMMISSIONER.md:150–168` VERBATIM:
> 1. For each persisted container round, platform starts the commissioner container.
> 2. Platform polls `/healthz` until ready, connects to `WEBSOCKET /round`, and sends `round_start` (round context:
>    divisions, memberships, recent results, variants, optional pre-completed recorded episode results, and optional
>    state blob from the previous round).
> 3. For an ordinary round, the commissioner sends `schedule_episodes` listing the episodes it wants to run. For a
>    recorded round, it scores `round_start.completed_episodes` directly and must not schedule executable episodes.
> 4. Platform responds with `episodes_accepted` or `episodes_rejected`, dispatches valid episodes.
> 5. As episodes complete, platform sends `episode_result` or `episode_failed`.
> 6. Platform calls the commissioner's episode-completed hook for the result or failure; the commissioner may schedule
>    more episodes, including retries or replacements after failures, or declare the round done.
> 7. Commissioner sends `round_complete` (per-division rankings, policy membership events, optional state blob) and exits.
> 8. Platform records results, applies policy membership events, stores commissioner state for the next round.
> 9. Container is terminated.

### Which variant runs — `COMMISSIONER.md:712–724` VERBATIM
> ## Variant resolution
>
> The v2 tournament surface is Coworld-native. A `Game` points at a Coworld name, and runtime scheduling resolves the
> latest uploaded Coworld manifest for that name:
>
> 1. The Coworld manifest declares all available variants up front.
> 2. The platform selects the manifest's first variant for default v2 rounds.
> 3. The selected variant is materialized as an idempotent env-config row keyed by the resolved Coworld payload hash.
> 4. Rounds store scheduling config only; pools point at the env-config row.
> 5. Episode dispatch stores the resolved `coworld_id` and variant `game_config` directly on the request.
> 6. The number of agents is validated from the Coworld manifest game configs.

**Per-episode config the commissioner controls:** `EpisodeRequest` (`protocol.py:76–82`) — `request_id`, `variant_id`, `policy_version_ids`, `seed: int | None`, `tags: dict[str,str]`, `game_config_overrides: dict[str,Any]`.

**Persistent leagues** (`COMMISSIONER.md:109–148`) — long-lived player runtimes, one per `(league, player_id)`, reconciled by the platform. VERBATIM: "A persistent league has one `Game`, and that `Game` is bound to one canonical, dedicated Coworld registration with exactly one declared competition variant. […] the commissioner cannot choose another Coworld, variant, or game image in `persistent_players`." And: "Persistent runtimes do not represent episodes. Authoritative game windows are materialized later as completed recorded episodes; they do not create execution requests, enter episode admission, or launch another player pod."

### **Live human input in hosted/league runs: ABSENT.** See §9.6. Confirmed by `LIFECYCLE.md:46–47`, `LIFECYCLE.md:159–160`, `README.md:91–93`, and by ClusterIP-only networking in `kubernetes_runner.py`.

### League CLI surface
- Seeding (team-only, `cli.py:84`, help VERBATIM: *"Create and inspect Coworld league seeds (team only)."*): `coworld league create <coworld_name> [--template/-t] [--set K=V] [--server] [--json]`, `coworld league list`, `coworld league update <coworld_name> --set K=V`. Template default `commissioner_driven`; help VERBATIM: *"Temporary seed template. Defaults to commissioner_driven; legacy values are default | social_deduction | cogs_vs_clips | four_score."*
- Inspection (tournament_cli.py): `leagues`, `divisions`, `results`, `rounds`, `memberships`, `retire-membership`, `submissions`, `events`, `episodes`, `episode-stats`, `episode-results`, `episode-logs`, `replays`, `replay-open`.
- Participation: `upload-policy`, `submit --league`, `xp-request create|list|get|episodes`.
- Commissioner selection: `commissioner_config.commissioner_runnable_id` must match one `manifest.commissioner[].id` (`COWORLD_MANIFEST.md:53–55`). Patch path: `coworld patch-commissioner <coworld_name> <image> [--runnable-id]`.

### 12.2 AGENTS.md at repo root

`/home/claude/source/coworld/AGENTS.md` (8451 bytes; `CLAUDE.md` symlinks to it) is **the AGENTS.md of the `coworld` package itself**, not a spec for what a packaged coworld's AGENTS.md must contain. Its own sections: the Bedrock warning banner, "Coworlds Expert Agent", "Before Editing", "CLI", "Validation", "Source Layout", "Documentation Map", "Manifest And Role Contracts", "Package Data Gotchas".

**Is a packaged coworld required to ship an AGENTS.md? NO.** There is no manifest field for it and no certification step. The only statements in the repo:

`SCHEMA_PRD.md:446–452` VERBATIM:
> ### 8.3 Accumulated wisdom — AGENTS.md + skills (recommended, not required)
>
> Lessons that make a generic coding agent **competent on this game** rather than flailing — ideally
> agent-consumable and **accumulating across iterations**, canonical home `AGENTS.md` + skills. This is **required of
> Softmax's own internal projects but is *not* imposed on coworld devs**: a strong recommendation, not a viability
> requirement. (cogsguard demonstrates structured `CogsguardLearning` records — `mettagrid.sdk.cogsguard.learnings`
> — alongside prose AGENTS.md; the structured form is an optional dev choice.)

`COOKBOOK.md:117` VERBATIM: "Start from the downloaded Coworld package and the game's `AGENTS.md`/README."
`COOKBOOK.md:187`: downloaded packages "include `coworld_manifest.json`, `coworld_images.json`, and an `AGENTS.md` for local policy work" — that AGENTS.md is **platform-generated boilerplate**, hardcoded at `/home/claude/source/coworld/src/coworld/upload.py:50` as `DOWNLOAD_AGENTS_MD`, written by `download_coworld_cmd` (`upload.py:1488–1489, 1521–1522`). It is **not** author-supplied and is overwritten on every download.

**Practical takeaway:** if you want agent-facing guidance to ship with your coworld, it must go in `game.docs.readme` (required) or `game.docs.pages[]` (optional) — those are the only author-controlled doc surfaces the platform carries. A repo-level `AGENTS.md` in your `coworld-<slug>` repo is a strong convention (SCHEMA_PRD §8.3) with zero platform enforcement, and it will **not** survive `coworld download` (which writes its own).

---

## Cross-cutting notes for packaging a new game

- Source layout you'll mirror: **one Dockerfile, one compose service, one image, N runnables** differentiated by `run` argv (Paint Arena). Templates at `/home/claude/source/coworld/src/coworld/templates/roles/{game,player,commissioner,grader,diagnoser,optimizer}/`.
- Build placeholder rule (`bundle.py:127–132`): compose service `my-game` → `{{MY_GAME_IMAGE}}`.
- `platform: linux/amd64` is mandatory in compose — `AUTHORING.md:138–139`: "hosted runners are amd64; images built for other architectures fail or crawl under emulation."
- `coworld build` also pins `source_url` refs to the current commit from the local git remote (`bundle.py:151–229`) — **build from committed, pushed state**.
- Manifest schema regeneration (COWORLD_MANIFEST.md:257–260) VERBATIM:
```bash
uv run --project packages/coworld python packages/coworld/scripts/generate_coworld_schemas.py
uv run --project packages/coworld pytest packages/coworld/tests/test_types.py
```
- Every command in the docs is written as if run from a monorepo root with the package at `packages/coworld/` — this standalone checkout has that content at `/home/claude/source/coworld/` (i.e. `src/coworld/...`, not `packages/coworld/src/coworld/...`). Adjust paths accordingly.