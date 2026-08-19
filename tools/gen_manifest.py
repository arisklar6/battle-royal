#!/usr/bin/env python3
"""Regenerates coworld_manifest_template.json, inlining the player docs.
Run from anywhere:  python tools/gen_manifest.py
"""
import json
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def doc(rel: str) -> dict:
    return {"type": "text", "value": (ROOT / rel).read_text(encoding="utf-8")}


# Certification step `source-resolves` fetches this through the GitHub contents
# API and wants a Dockerfile in the directory or an ancestor. Every runnable in
# the manifest needs it — the game AND each bundled player — and a manifest that
# omits it fails that step outright. It was added by hand in 84b3377/91558ff
# after this generator had already been written, so regenerating used to drop it
# again silently; assert_source_urls() below is what makes that impossible now.
SOURCE_URL = "https://github.com/arisklar6/battle-royal"


INT16 = {"type": "array", "minItems": 16, "maxItems": 16, "items": {"type": "integer"}}

CONFIG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens"],
    "properties": {
        "tokens": {
            "type": "array", "minItems": 16, "maxItems": 16,
            "items": {"type": "string", "minLength": 1},
        },
        "num_players": {
            "type": "integer", "minimum": 2, "maximum": 16,
            "description": "Seats in the free-for-all (default 16). Seat i is "
                           "slot i; every other agent is an opponent.",
        },
        "seed": {
            "type": "integer",
            "description": "Optional. Absent: the game mints a fresh random seed "
                           "(recorded in results and the replay's effective config).",
        },
        "max_ticks": {"type": "integer", "minimum": 100, "maximum": 20000},
        "player_connect_timeout_seconds": {
            "type": "integer", "minimum": 0, "maximum": 600,
            "description": "Wall-clock grace before the countdown starts: the "
                           "game waits until all 16 seats connect or this many "
                           "seconds pass (default 180). Pre-tick-0 boundary; "
                           "the simulation itself stays deterministic.",
        },
        "freeze_ticks": {"type": "integer", "minimum": 48, "maximum": 480},
        "stat_budget": {"type": "integer", "minimum": 4, "maximum": 40},
        "zone": {
            "type": "object", "additionalProperties": False,
            "properties": {
                "schedule": {
                    "type": "array",
                    "items": {"type": "array", "minItems": 6, "maxItems": 6,
                               "items": {"type": "integer"}},
                    "description": "Rows: [warn_tick, shrink_tick, done_tick, "
                                   "r_start, r_end, damage_per_s]",
                }
            },
        },
        "events": {
            "type": "array",
            "items": {
                "type": "object", "additionalProperties": False,
                "required": ["kind", "from_tick", "duration"],
                "properties": {
                    "kind": {"enum": ["flood", "firestorm"]},
                    "rect": {"type": "array", "minItems": 4, "maxItems": 4,
                              "items": {"type": "integer"}},
                    "center": {"type": "array", "minItems": 2, "maxItems": 2,
                                "items": {"type": "integer"}},
                    "radius": {"type": "integer", "minimum": 1, "maximum": 24},
                    "from_tick": {"type": "integer", "minimum": 0},
                    "duration": {"type": "integer", "minimum": 24},
                },
            },
        },
        "sponsor": {
            "type": "object", "additionalProperties": False,
            "properties": {
                "live": {
                    "type": "boolean",
                    "description": "Live sponsor websocket ingress. Local play "
                                   "only; league/certification configs keep this false.",
                },
                "budget_per_player": {"type": "integer", "minimum": 0, "maximum": 10000},
                "shop_opens_tick": {"type": "integer", "minimum": 0},
                "scripted_gifts": {
                    "type": "array",
                    "items": {
                        "type": "object", "additionalProperties": False,
                        "required": ["tick", "player", "item_id"],
                        "properties": {
                            "tick": {"type": "integer", "minimum": 0},
                            "player": {"type": "integer", "minimum": 0, "maximum": 15},
                            "target": {"type": "array", "minItems": 2, "maxItems": 2,
                                        "items": {"type": "integer"}},
                            "item_id": {"type": "string", "minLength": 1},
                        },
                    },
                },
                "sponsor_tokens": {
                    "type": "object",
                    "additionalProperties": {"type": "string"},
                    "description": "player slot (\"0\"..\"15\") -> sponsor auth "
                                   "token. Runtime-supplied for live local play "
                                   "only; never authored in manifests.",
                },
            },
        },
        "players": {
            "type": "array", "minItems": 16, "maxItems": 16,
            "items": {"type": "object", "additionalProperties": False,
                       "required": ["name"],
                       "properties": {"name": {"type": "string", "minLength": 1}}},
        },
    },
}

RESULTS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["scores", "placements", "kills", "damage_dealt",
                 "survival_ticks", "gifts_received", "winner_slot",
                 "match_ticks", "seed"],
    "properties": {
        "scores": {"type": "array", "minItems": 16, "maxItems": 16,
                    "items": {"type": "number"}},
        "placements": INT16,
        "kills": INT16,
        "damage_dealt": INT16,
        "survival_ticks": INT16,
        "gifts_received": INT16,
        "winner_slot": {"type": "integer", "minimum": -1, "maximum": 15},
        "match_ticks": {"type": "integer", "minimum": 0},
        "seed": {"type": "integer"},
    },
}

DEFAULT_NAMES = [{"name": f"P{i:02d}"} for i in range(16)]

FULL_ZONE = [
    [1440, 1632, 2064, 24, 19, 1], [2352, 2544, 2976, 19, 15, 2],
    [3264, 3456, 3888, 15, 11, 4], [4176, 4368, 4800, 11, 8, 6],
    [5088, 5280, 5712, 8, 5, 8], [6000, 6192, 6624, 5, 3, 16],
    [6912, 7104, 7536, 3, 0, 24],
]

# League fairness (DESIGN 9.4/D3): IDENTICAL scripted schedule per player,
# staggered 24 ticks so pods never contend on the same tick.
LEAGUE_GIFTS = []
for t in range(16):
    LEAGUE_GIFTS.append({"tick": 2016 + 24 * t, "player": t,
                         "item_id": "rations"})
    LEAGUE_GIFTS.append({"tick": 4608 + 24 * t, "player": t,
                         "item_id": "first_aid"})

COMPETITION = {
    "max_ticks": 9120, "freeze_ticks": 240,
    "stat_budget": 20,
    "zone": {"schedule": FULL_ZONE},
    "events": [{"kind": "flood", "rect": [10, 22, 14, 26],
                "from_tick": 4400, "duration": 720}],
    "sponsor": {"live": False, "budget_per_player": 150,
                "shop_opens_tick": 1680, "scripted_gifts": LEAGUE_GIFTS},
    "players": DEFAULT_NAMES,
}

CASUAL = {
    "max_ticks": 9120, "freeze_ticks": 240,
    "stat_budget": 20,
    "zone": {"schedule": FULL_ZONE},
    "events": [],
    "sponsor": {"live": True, "budget_per_player": 150,
                "shop_opens_tick": 1680, "scripted_gifts": []},
    "players": DEFAULT_NAMES,
}

FIXTURE = {
    "seed": 42, "max_ticks": 480,
    "freeze_ticks": 48, "stat_budget": 20,
    "zone": {"schedule": [[96, 120, 288, 24, 12, 4], [336, 360, 384, 12, 0, 40]]},
    "events": [],
    "sponsor": {"live": False, "budget_per_player": 150, "shop_opens_tick": 96,
                "scripted_gifts": [
                    {"tick": 120, "player": 0, "item_id": "rations"},
                    {"tick": 200, "player": 5, "item_id": "sword"},
                ]},
    "players": DEFAULT_NAMES,
}

MANIFEST = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    "tags": ["battle-royale", "multi-agent", "real-time", "social", "sponsor-economy"],
    "game": {
        "name": "battle-royal",
        "replay_viewer": {"bundle": "build/static-replay-viewer"},
        "description": "Free-for-all battle royale for up to 16 agents: a "
                       "loot-stocked central Fortress, a shrinking ring of "
                       "fire, arena-wide diplomacy (broadcast and dm carry at "
                       "any distance), per-player sponsor airdrops anyone can "
                       "steal, and scoring that only pays survival — with "
                       "podium bonuses for the top three. Every death is a "
                       "black firework.",
        "owner": "arisklar6@gmail.com",
        "runnable": {
            "type": "game",
            "source_url": SOURCE_URL,
            "image": "{{BATTLE_ROYAL_IMAGE}}",
            "run": ["/app/battle_royal_server"],
        },
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "protocols": {
            "player": doc("game/docs/player_protocol.md"),
            "global": doc("game/docs/global_protocol.md"),
            "engine_runtime": "bitworld",
        },
        "docs": {"readme": doc("game/docs/README.md")},
    },
    "player": [{
        "id": "battle-royal-baseline",
        "name": "Battle Royal Baseline",
        "type": "player",
        "source_url": SOURCE_URL,
        "image": "{{BATTLE_ROYAL_IMAGE}}",
        "run": ["/app/battle_royal_baseline"],
        "description": "Bundled reference policy: allocates 6/6/4/4, loots "
                       "nearby crates, fights when armed and healthy, flees "
                       "weak, heals when safe, obeys the ring, claims its "
                       "sponsor drops, forages.",
    }],
    "variants": [
        {
            "id": "competition",
            "name": "Competition",
            "game_config": COMPETITION,
            "description": "League standard: full 9120-tick match, fast "
                           "5-minute ring, one scripted flood, equal "
                           "per-player softcoin budgets delivered as an "
                           "identical scripted gift schedule (no live "
                           "sponsorship in hosted play).",
        },
        {
            "id": "casual-live",
            "name": "Casual (live sponsors)",
            "game_config": CASUAL,
            "description": "Local play with the live sponsor console enabled: "
                           "supply per-player sponsor tokens via runtime "
                           "config (sponsor.sponsor_tokens) and open "
                           "/client/sponsor. Not intended for hosted runs.",
        },
    ],
    "certification": {
        "game_config": FIXTURE,
        "players": [{"player_id": "battle-royal-baseline"} for _ in range(16)],
    },
}

def assert_source_urls(name: str, manifest: dict) -> None:
    """Fail loudly rather than write a template that cannot certify.

    Checks every runnable the certifier resolves sources for, so a new role
    added later (grader, diagnoser, optimizer) is covered without editing this.
    """
    missing = []
    if not manifest["game"]["runnable"].get("source_url"):
        missing.append("game.runnable")
    for role in ("player", "commissioner", "grader", "diagnoser", "optimizer"):
        for i, entry in enumerate(manifest.get(role, [])):
            if not entry.get("source_url"):
                missing.append(f"{role}[{i}] ({entry.get('id', '?')})")
    if missing:
        raise SystemExit(
            f"{name}: source_url missing on {', '.join(missing)} — the "
            f"certifier's source-resolves step would fail. Set SOURCE_URL on "
            f"every runnable before regenerating."
        )


for filename, manifest in [
    ("coworld_manifest_template.json", MANIFEST),
]:
    assert_source_urls(filename, manifest)
    out = ROOT / filename
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
