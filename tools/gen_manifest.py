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
        "league_mode": {
            "enum": ["solo", "duos"],
            "description": "Policy seating and result attribution. solo maps one "
                           "external seat to one contestant. duos remaps platform "
                           "team_n seats i/i+8 onto adjacent teammates and reports "
                           "their shared team-total score to both seats.",
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
                "budget_per_team": {"type": "integer", "minimum": 0, "maximum": 10000},
                "shop_opens_tick": {"type": "integer", "minimum": 0},
                "scripted_gifts": {
                    "type": "array",
                    "items": {
                        "type": "object", "additionalProperties": False,
                        "required": ["tick", "team", "recipient_slot", "item_id"],
                        "properties": {
                            "tick": {"type": "integer", "minimum": 0},
                            "team": {"enum": list("ABCDEFGH")},
                            "recipient_slot": {"type": "integer", "minimum": 0, "maximum": 15},
                            "item_id": {"type": "string", "minLength": 1},
                        },
                    },
                },
                "sponsor_tokens": {
                    "type": "object",
                    "additionalProperties": {"type": "string"},
                    "description": "team letter -> sponsor auth token. Runtime-"
                                   "supplied for live local play only; never "
                                   "authored in manifests.",
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
                 "winner_team", "match_ticks", "seed"],
    "properties": {
        "scores": {"type": "array", "minItems": 16, "maxItems": 16,
                    "items": {"type": "number"}},
        "placements": INT16,
        "kills": INT16,
        "damage_dealt": INT16,
        "survival_ticks": INT16,
        "gifts_received": INT16,
        "winner_slot": {"type": "integer", "minimum": -1, "maximum": 15},
        "winner_team": {"type": ["string", "null"]},
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

# League fairness (DESIGN 9.4/D3): IDENTICAL scripted schedule per team,
# staggered 24 ticks so pods never contend on the same tick.
LEAGUE_GIFTS = []
for t, team in enumerate("ABCDEFGH"):
    LEAGUE_GIFTS.append({"tick": 2016 + 24 * t, "team": team,
                         "recipient_slot": 2 * t, "item_id": "rations"})
    LEAGUE_GIFTS.append({"tick": 4608 + 24 * t, "team": team,
                         "recipient_slot": 2 * t + 1, "item_id": "first_aid"})

COMPETITION = {
    "league_mode": "solo", "max_ticks": 9120, "freeze_ticks": 240,
    "stat_budget": 20,
    "zone": {"schedule": FULL_ZONE},
    "events": [{"kind": "flood", "rect": [10, 22, 14, 26],
                "from_tick": 4400, "duration": 720}],
    "sponsor": {"live": False, "budget_per_team": 300,
                "shop_opens_tick": 1680, "scripted_gifts": LEAGUE_GIFTS},
    "players": DEFAULT_NAMES,
}

CASUAL = {
    "league_mode": "solo", "max_ticks": 9120, "freeze_ticks": 240,
    "stat_budget": 20,
    "zone": {"schedule": FULL_ZONE},
    "events": [],
    "sponsor": {"live": True, "budget_per_team": 300,
                "shop_opens_tick": 1680, "scripted_gifts": []},
    "players": DEFAULT_NAMES,
}

FIXTURE = {
    "league_mode": "solo", "seed": 42, "max_ticks": 480,
    "freeze_ticks": 48, "stat_budget": 20,
    "zone": {"schedule": [[96, 120, 288, 24, 12, 4], [336, 360, 384, 12, 0, 40]]},
    "events": [],
    "sponsor": {"live": False, "budget_per_team": 300, "shop_opens_tick": 96,
                "scripted_gifts": [
                    {"tick": 120, "team": "A", "recipient_slot": 0, "item_id": "rations"},
                    {"tick": 200, "team": "C", "recipient_slot": 5, "item_id": "sword"},
                ]},
    "players": DEFAULT_NAMES,
}

DUOS_COMPETITION = deepcopy(COMPETITION)
DUOS_COMPETITION["league_mode"] = "duos"
DUOS_FIXTURE = deepcopy(FIXTURE)
DUOS_FIXTURE["league_mode"] = "duos"

MANIFEST = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    "tags": ["battle-royale", "multi-agent", "real-time", "social", "sponsor-economy"],
    "game": {
        "name": "zero-sum",
        "replay_viewer": {"bundle": "build/static-replay-viewer"},
        "description": "Battle royale for 16 agents in 8 teams of 2: a "
                       "loot-stocked central Fortress, a shrinking ring of "
                       "fire, open talk channels, sponsor softcoin airdrops "
                       "anyone can steal, and a finale that turns the last "
                       "team against itself. Every death is a black firework.",
        "owner": "arisklar6@gmail.com",
        "runnable": {
            "type": "game",
            "image": "{{ZERO_SUM_IMAGE}}",
            "run": ["/app/zero_sum_server"],
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
        "id": "zero-sum-baseline",
        "name": "Zero Sum Baseline",
        "type": "player",
        "image": "{{ZERO_SUM_IMAGE}}",
        "run": ["/app/zero_sum_baseline"],
        "description": "Bundled reference policy: allocates 6/6/4/4, loots "
                       "nearby crates, fights when armed and healthy, flees "
                       "weak, heals when safe, obeys the ring, claims its "
                       "team's sponsor drops, forages.",
    }],
    "variants": [
        {
            "id": "competition",
            "name": "Competition",
            "game_config": COMPETITION,
            "description": "League standard: full 9120-tick match, fast "
                           "5-minute ring, one scripted flood, equal per-team "
                           "softcoin budgets delivered as an identical "
                           "scripted gift schedule (no live sponsorship in "
                           "hosted play).",
        },
        {
            "id": "casual-live",
            "name": "Casual (live sponsors)",
            "game_config": CASUAL,
            "description": "Local play with the live sponsor console enabled: "
                           "supply per-team sponsor tokens via runtime config "
                           "(sponsor.sponsor_tokens) and open /client/sponsor. "
                           "Not intended for hosted runs.",
        },
    ],
    "certification": {
        "game_config": FIXTURE,
        "players": [{"player_id": "zero-sum-baseline"} for _ in range(16)],
    },
}

DUOS_MANIFEST = deepcopy(MANIFEST)
DUOS_MANIFEST["game"]["name"] = "zero-sum-duos"
DUOS_MANIFEST["game"]["description"] = (
    "Self-paired Zero Sum for 8 policies controlling adjacent teams of 2. "
    "The game remaps the platform team_n seat pattern onto the canonical "
    "arena layout and attributes each policy its two contestants' team-total "
    "score."
)
DUOS_MANIFEST["variants"] = [{
    "id": "competition-duos",
    "name": "Competition Duos",
    "game_config": DUOS_COMPETITION,
    "description": "League standard for 8 self-paired entrants. Use platform "
                   "team_n seating with team_count 8; external seats i and "
                   "i+8 become adjacent teammates inside the game.",
}]
DUOS_MANIFEST["certification"]["game_config"] = DUOS_FIXTURE

for filename, manifest in [
    ("coworld_manifest_template.json", MANIFEST),
    ("coworld_manifest_duos_template.json", DUOS_MANIFEST),
]:
    out = ROOT / filename
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
