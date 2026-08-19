#!/usr/bin/env python3
"""
generate.py — "nano banana" (Gemini image model) generation harness for BATTLE ROYAL art.

Implements the generation half of docs/ART_UPGRADE_PLAN.md §3. It turns a prompt
spec file into raw PNG generations on disk. It does NOT key, reduce, quantize or
bake — that is tools/bake_art.nim's job (§3.4, §4). Raw generations are kept as
provenance (plan §4.1: "art/source/*.png — raw nano banana generations —
provenance, repo-only"), so this directory is COMMITTED, not gitignored.

WIRE SHAPE — verified 2026-08-13 against Google's official developer docs, not
guessed. Sources relied on:

  * https://ai.google.dev/gemini-api/docs/image-generation
      The "Nano Banana" family and its model ids:
        gemini-3-pro-image         (Nano Banana Pro)     <- our default
        gemini-3.1-flash-image     (Nano Banana 2)
        gemini-3.1-flash-lite-image
        gemini-2.5-flash-image     (legacy Nano Banana)
      Also documents the newer Interactions API (beta). We deliberately do NOT
      use it: the same page recommends generateContent for stable production
      use, and generateContent is the shape we can pin.

  * https://ai.google.dev/gemini-api/docs/generate-content/image-generation
      The generateContent REST call and its response:
        POST https://generativelanguage.googleapis.com/v1beta/models/<MODEL>:generateContent
        header: x-goog-api-key: $GEMINI_API_KEY
        body:   {"contents":[{"parts":[{"text": "..."}]}],
                 "generationConfig":{"responseModalities":["TEXT","IMAGE"],
                                     "imageConfig":{"aspectRatio":"1:1","imageSize":"2K"}}}
        reply:  candidates[0].content.parts[*].inlineData.{mimeType,data(base64)}
                candidates[0].finishReason
                promptFeedback.blockReason (+ safetyRatings) when blocked
      generationConfig.imageConfig accepts aspectRatio in
        1:1 2:3 3:2 3:4 4:3 4:5 5:4 9:16 16:9 21:9 1:4 4:1 1:8 8:1
      and imageSize in 512px / 1K / 2K / 4K.

  * https://ai.google.dev/api/generate-content
      Endpoint path + auth (x-goog-api-key header, or ?key= query param).

The model id is never hard-coded in one place: --model overrides it, a spec's
`defaults.model` overrides that per group, and a per-entry `model` overrides
that. DEFAULT_MODEL below is only the last resort.

USAGE
    uv run --project tools/art tools/art/generate.py --list
    uv run --project tools/art tools/art/generate.py carrier --dry-run
    uv run --project tools/art tools/art/generate.py carrier terrain
    uv run --project tools/art tools/art/generate.py carrier --only carrier-sheet --force

--dry-run needs no API key at all and prints the exact JSON body per prompt.

CACHING — the API is paid and sits OUTSIDE the Claude Max subscription, so a
re-run must never re-bill an unchanged prompt. The cache is the committed output
itself: art/raw/<group>/_manifest.json records the sha256 of the exact request
body that produced each PNG. Same body + file still on disk = skip, zero calls.
Edit a prompt (or pass --force) and only that entry regenerates.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import io
import json
import os
import random
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants pinned to the docs quoted in the module header.
# ---------------------------------------------------------------------------

API_BASE = "https://generativelanguage.googleapis.com"
API_VERSION = "v1beta"

# Nano Banana Pro. Highest fidelity + the best cross-variant consistency, which
# is exactly what the sheet strategy in plan §3.3 leans on (4 carrier facings /
# 12 stencils / 6 weapon glyphs must agree with each other).
DEFAULT_MODEL = "gemini-3-pro-image"

KNOWN_MODELS = (
    "gemini-3-pro-image",          # Nano Banana Pro
    "gemini-3.1-flash-image",      # Nano Banana 2
    "gemini-3.1-flash-lite-image",  # Nano Banana 2 Lite
    "gemini-2.5-flash-image",      # legacy Nano Banana
)

# The local backend is the default as of 2026-08-17: every Gemini image model
# answers `limit: 0` on the free tier, so the hosted path needs a billing
# account, while FLUX.1-schnell is Apache-2.0 and runs here for nothing.
# Imported lazily-ish — flux_backend itself does not import torch at module
# scope, so `--dry-run` and `--backend gemini` stay free of the heavy deps.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from flux_backend import (  # noqa: E402
    MODEL_ID as FLUX_MODEL_ID,
    FluxConfig,
    FluxPipeline,
    FluxUnavailable,
    describe as describe_flux,
    dimensions_for as flux_dimensions_for,
    seed_for as flux_seed_for,
)

ASPECT_RATIOS = (
    "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4",
    "9:16", "16:9", "21:9", "1:4", "4:1", "1:8", "8:1",
)

# imageSize token -> long-edge pixels (used to pick a token from a WxH request
# and to estimate emitted dimensions; the real dimensions are measured after
# download and recorded in the manifest).
IMAGE_SIZES: dict[str, int] = {"512px": 512, "1K": 1024, "2K": 2048, "4K": 4096}

DEFAULT_ASPECT_RATIO = "1:1"
DEFAULT_IMAGE_SIZE = "2K"

# Terminal (non-retryable) candidate finishReasons that mean "the model refused".
BLOCKED_FINISH_REASONS = {
    "SAFETY", "PROHIBITED_CONTENT", "IMAGE_SAFETY", "BLOCKLIST",
    "RECITATION", "SPII", "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION",
}

RETRYABLE_STATUS = {408, 429, 500, 502, 503, 504}

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_BLOCKED = 3
EXIT_API = 4
EXIT_NO_KEY = 5


# ---------------------------------------------------------------------------
# Repo layout
# ---------------------------------------------------------------------------

def repo_root() -> Path:
    """Walk up from this file to the repo root (marked by battle_royal.nimble)."""
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / "battle_royal.nimble").exists() or (candidate / ".git").exists():
            return candidate
    return here.parent.parent.parent


ROOT = repo_root()


def rel_to_root(path: Path) -> str:
    """Repo-relative display path, falling back to absolute when outside the repo."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)



PROMPTS_DIR = ROOT / "tools" / "art" / "prompts"
RAW_DIR = ROOT / "art" / "raw"
ENV_FILE = ROOT / ".env"


# ---------------------------------------------------------------------------
# .env parsing (no external dotenv dependency)
# ---------------------------------------------------------------------------

def parse_env_file(path: Path) -> dict[str, str]:
    """Minimal .env parser: KEY=VALUE, `export ` prefix, # comments, quotes."""
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        # Strip one layer of matching quotes; leave inner content untouched.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        else:
            # Unquoted values may carry a trailing inline comment.
            hash_at = value.find(" #")
            if hash_at >= 0:
                value = value[:hash_at].rstrip()
        out[key] = value
    return out


def resolve_api_key(env_file: Path) -> tuple[str | None, str]:
    """Return (key, source). Process env wins; .env fills the gap."""
    from_env = os.environ.get("GEMINI_API_KEY", "").strip()
    if from_env:
        return from_env, "environment (GEMINI_API_KEY)"
    parsed = parse_env_file(env_file)
    from_file = parsed.get("GEMINI_API_KEY", "").strip()
    if from_file:
        return from_file, f"{env_file}"
    # Accept the common alternate spelling rather than failing confusingly.
    for alt in ("GOOGLE_API_KEY", "GOOGLE_GENAI_API_KEY"):
        alt_val = os.environ.get(alt, "").strip() or parsed.get(alt, "").strip()
        if alt_val:
            return alt_val, f"{alt} (fallback)"
    return None, "not found"


def missing_key_message(env_file: Path) -> str:
    return (
        "\nGEMINI_API_KEY is not set — cannot generate.\n"
        "\n"
        "  1. Get a key:  https://aistudio.google.com/apikey\n"
        f"  2. Put it in {env_file} (already covered by .gitignore):\n"
        "\n"
        f"       printf 'GEMINI_API_KEY=YOUR_KEY_HERE\\n' >> {env_file}\n"
        "\n"
        "     ...or export it for one shell:  export GEMINI_API_KEY=YOUR_KEY_HERE\n"
        "  3. Re-run the same command.\n"
        "\n"
        "This repo is PUBLIC. Never commit a real key; .env and .env.* are gitignored\n"
        "(.env.example is the committed template).\n"
        "\n"
        "--dry-run works with no key at all: it prints the exact request bodies and\n"
        "the billable call count without contacting Google.\n"
    )


# ---------------------------------------------------------------------------
# Prompt specs
# ---------------------------------------------------------------------------

@dataclass
class PromptSpec:
    name: str
    prompt: str
    model: str
    aspect_ratio: str
    image_size: str
    variants: int
    requested_px: tuple[int, int] | None
    size_raw: Any
    seed: int | None = None
    temperature: float | None = None
    notes: str = ""
    # Free-form, ignored by this tool, carried into the manifest for the baker
    # (e.g. crop rects the human hand-verifies later — plan §3.3).
    extra: dict[str, Any] = field(default_factory=dict)


SIZE_WH_RE = re.compile(r"^\s*(\d{2,5})\s*[xX*×]\s*(\d{2,5})\s*$")


def _nearest_aspect_ratio(width: int, height: int) -> str:
    """Pick the supported aspectRatio closest to width:height in log space."""
    target = width / height
    best = DEFAULT_ASPECT_RATIO
    best_err = float("inf")
    for ratio in ASPECT_RATIOS:
        rw, rh = (int(part) for part in ratio.split(":"))
        err = abs((rw / rh) / target - 1.0)
        if err < best_err - 1e-12:
            best_err = err
            best = ratio
    return best


def _smallest_image_size(long_edge: int) -> str:
    for token in ("512px", "1K", "2K", "4K"):
        if IMAGE_SIZES[token] >= long_edge:
            return token
    return "4K"


def normalize_size(size: Any, where: str) -> tuple[str, str, tuple[int, int] | None]:
    """
    Accepts, in order of explicitness:
      {"aspect_ratio": "3:4", "image_size": "2K"}   -> passed straight through
      "1536x1152"                                   -> nearest ratio + smallest token that covers it
      "2K" / "1K" / "512px" / "4K"                  -> that token, square
      "16:9"                                        -> that ratio, default token
      null / missing                                -> 1:1 @ 2K
    Returns (aspect_ratio, image_size, requested_px_or_None).
    """
    if size is None:
        return DEFAULT_ASPECT_RATIO, DEFAULT_IMAGE_SIZE, None

    if isinstance(size, dict):
        aspect = str(size.get("aspect_ratio", size.get("aspectRatio", DEFAULT_ASPECT_RATIO)))
        token = str(size.get("image_size", size.get("imageSize", DEFAULT_IMAGE_SIZE)))
        if aspect not in ASPECT_RATIOS:
            raise SpecError(f"{where}: aspect_ratio {aspect!r} is not supported. "
                            f"Supported: {', '.join(ASPECT_RATIOS)}")
        if token not in IMAGE_SIZES:
            raise SpecError(f"{where}: image_size {token!r} is not supported. "
                            f"Supported: {', '.join(IMAGE_SIZES)}")
        px = size.get("px")
        requested = (int(px[0]), int(px[1])) if isinstance(px, (list, tuple)) and len(px) == 2 else None
        return aspect, token, requested

    if isinstance(size, (list, tuple)) and len(size) == 2:
        width, height = int(size[0]), int(size[1])
        return _nearest_aspect_ratio(width, height), _smallest_image_size(max(width, height)), (width, height)

    if isinstance(size, int):
        return DEFAULT_ASPECT_RATIO, _smallest_image_size(size), (size, size)

    if isinstance(size, str):
        text = size.strip()
        match = SIZE_WH_RE.match(text)
        if match:
            width, height = int(match.group(1)), int(match.group(2))
            return _nearest_aspect_ratio(width, height), _smallest_image_size(max(width, height)), (width, height)
        if text in IMAGE_SIZES:
            return DEFAULT_ASPECT_RATIO, text, None
        if text in ASPECT_RATIOS:
            return text, DEFAULT_IMAGE_SIZE, None
        raise SpecError(
            f"{where}: cannot read size {size!r}. Use \"1536x1152\", an imageSize token "
            f"({', '.join(IMAGE_SIZES)}), an aspectRatio ({', '.join(ASPECT_RATIOS)}), "
            f"or {{\"aspect_ratio\": \"3:4\", \"image_size\": \"2K\"}}."
        )

    raise SpecError(f"{where}: cannot read size {size!r} (type {type(size).__name__}).")


def estimate_px(aspect_ratio: str, image_size: str) -> tuple[int, int]:
    """
    ESTIMATE of the emitted pixel dimensions: the long edge equals the imageSize
    token and the short edge follows the ratio. Google does not publish an exact
    per-ratio table we could pin, so this is advisory only — the harness measures
    the real dimensions after download and records those in the manifest. Build
    art/sheets.json crop rects against `actual_px`, never against this number.
    """
    rw, rh = (int(part) for part in aspect_ratio.split(":"))
    long_edge = IMAGE_SIZES[image_size]
    if rw >= rh:
        return long_edge, max(1, round(long_edge * rh / rw))
    return max(1, round(long_edge * rw / rh)), long_edge


class SpecError(Exception):
    pass


def load_group(group: str, prompts_dir: Path, model_override: str | None) -> list[PromptSpec]:
    """
    Load tools/art/prompts/<group>.json.

    Two accepted shapes:
      A bare list:      [ {name, prompt, size, variants}, ... ]
      Or an object:     { "defaults": {...}, "prompts": [ ... ] }

    `defaults` may carry: model, size, variants, prompt_prefix, prompt_suffix,
    seed, temperature. prompt_prefix/prompt_suffix exist so the AFTERGLOW
    constraint block (plan §3.2) is stated once per group and lands verbatim in
    every request body — the palette laws must not drift between entries.
    """
    path = prompts_dir / f"{group}.json"
    if not path.exists():
        available = sorted(p.stem for p in prompts_dir.glob("*.json")) if prompts_dir.exists() else []
        raise SpecError(
            f"no prompt spec at {path}\n"
            + (f"available groups: {', '.join(available)}" if available else
               f"no specs exist yet in {prompts_dir}")
        )

    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SpecError(f"{path}: invalid JSON — {exc}") from exc

    if isinstance(doc, list):
        defaults: dict[str, Any] = {}
        entries = doc
    elif isinstance(doc, dict):
        defaults = doc.get("defaults", {}) or {}
        entries = doc.get("prompts", doc.get("entries", []))
        if not isinstance(entries, list):
            raise SpecError(f"{path}: \"prompts\" must be a list.")
    else:
        raise SpecError(f"{path}: top level must be a list or an object.")

    if not entries:
        raise SpecError(f"{path}: contains no prompt entries.")

    prefix = str(defaults.get("prompt_prefix", "") or "")
    suffix = str(defaults.get("prompt_suffix", "") or "")
    default_model = str(defaults.get("model", DEFAULT_MODEL))
    default_size = defaults.get("size")
    default_variants = int(defaults.get("variants", 1))

    specs: list[PromptSpec] = []
    seen: set[str] = set()
    for index, entry in enumerate(entries):
        where = f"{path} [{index}]"
        if not isinstance(entry, dict):
            raise SpecError(f"{where}: each entry must be an object.")
        name = str(entry.get("name", "")).strip()
        if not name:
            raise SpecError(f"{where}: missing \"name\".")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            raise SpecError(f"{where}: name {name!r} must be a safe filename "
                            "([A-Za-z0-9._-], no slashes).")
        if name in seen:
            raise SpecError(f"{where}: duplicate name {name!r}.")
        seen.add(name)

        body = str(entry.get("prompt", "")).strip()
        if not body:
            raise SpecError(f"{where} ({name}): missing \"prompt\".")

        parts = [chunk for chunk in (prefix.strip(), body, suffix.strip()) if chunk]
        prompt = "\n\n".join(parts)

        aspect, token, requested = normalize_size(
            entry.get("size", default_size), f"{where} ({name})"
        )

        variants = int(entry.get("variants", default_variants))
        if variants < 1:
            raise SpecError(f"{where} ({name}): variants must be >= 1.")

        seed = entry.get("seed", defaults.get("seed"))
        temperature = entry.get("temperature", defaults.get("temperature"))

        specs.append(PromptSpec(
            name=name,
            prompt=prompt,
            model=model_override or str(entry.get("model", default_model)),
            aspect_ratio=aspect,
            image_size=token,
            variants=variants,
            requested_px=requested,
            size_raw=entry.get("size", default_size),
            seed=int(seed) if seed is not None else None,
            temperature=float(temperature) if temperature is not None else None,
            notes=str(entry.get("notes", "") or ""),
            extra={k: v for k, v in entry.items()
                   if k not in {"name", "prompt", "size", "variants", "model",
                                "seed", "temperature", "notes"}},
        ))
    return specs


# ---------------------------------------------------------------------------
# Request construction + hashing
# ---------------------------------------------------------------------------

def build_request_body(spec: PromptSpec) -> dict[str, Any]:
    generation_config: dict[str, Any] = {
        "responseModalities": ["TEXT", "IMAGE"],
        "imageConfig": {
            "aspectRatio": spec.aspect_ratio,
            "imageSize": spec.image_size,
        },
    }
    if spec.seed is not None:
        generation_config["seed"] = spec.seed
    if spec.temperature is not None:
        generation_config["temperature"] = spec.temperature
    return {
        "contents": [{"role": "user", "parts": [{"text": spec.prompt}]}],
        "generationConfig": generation_config,
    }


def endpoint_for(model: str) -> str:
    return f"{API_BASE}/{API_VERSION}/models/{model}:generateContent"


def request_sha256(model: str, body: dict[str, Any]) -> str:
    """
    Cache key. Covers the model id, the endpoint version and every byte of the
    request body, so changing a single word of a prompt invalidates exactly that
    entry and nothing else.
    """
    canonical = json.dumps(
        {"endpoint": endpoint_for(model), "body": body},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def output_paths(group_dir: Path, spec: PromptSpec) -> list[Path]:
    if spec.variants == 1:
        return [group_dir / f"{spec.name}.png"]
    return [group_dir / f"{spec.name}-{i + 1:02d}.png" for i in range(spec.variants)]


# ---------------------------------------------------------------------------
# Manifest (also the cache index)
# ---------------------------------------------------------------------------

def manifest_path(group_dir: Path) -> Path:
    return group_dir / "_manifest.json"


def load_manifest(group_dir: Path) -> dict[str, Any]:
    path = manifest_path(group_dir)
    if not path.exists():
        return {"group": group_dir.name, "generator": "tools/art/generate.py", "entries": {}}
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # A corrupt manifest must not silently re-bill; say so loudly.
        print(f"warning: {path} is not valid JSON — treating every entry as a cache miss.",
              file=sys.stderr)
        return {"group": group_dir.name, "generator": "tools/art/generate.py", "entries": {}}
    doc.setdefault("entries", {})
    return doc


def save_manifest(group_dir: Path, manifest: dict[str, Any]) -> None:
    manifest["group"] = group_dir.name
    manifest["generator"] = "tools/art/generate.py"
    path = manifest_path(group_dir)
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def is_cached(manifest: dict[str, Any], out_path: Path, req_sha: str) -> bool:
    entry = manifest.get("entries", {}).get(out_path.name)
    if not isinstance(entry, dict):
        return False
    if entry.get("request_sha256") != req_sha:
        return False
    return out_path.exists() and out_path.stat().st_size > 0


# ---------------------------------------------------------------------------
# API errors
# ---------------------------------------------------------------------------

class SafetyBlocked(Exception):
    def __init__(self, reason: str, detail: str):
        super().__init__(f"blocked: {reason}")
        self.reason = reason
        self.detail = detail


class NoImageReturned(Exception):
    def __init__(self, finish_reason: str, text: str):
        super().__init__(f"no image in response (finishReason={finish_reason})")
        self.finish_reason = finish_reason
        self.text = text


class ApiError(Exception):
    def __init__(self, status: int, message: str, body: str):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.body = body


def _describe_safety_ratings(ratings: Any) -> str:
    if not isinstance(ratings, list):
        return ""
    lines = []
    for rating in ratings:
        if not isinstance(rating, dict):
            continue
        probability = rating.get("probability", "?")
        if probability in ("NEGLIGIBLE", "LOW", None):
            continue
        lines.append(f"      {rating.get('category', '?')}: {probability}"
                     + (" (blocked)" if rating.get("blocked") else ""))
    return "\n".join(lines)


def extract_image(response: dict[str, Any]) -> tuple[str, bytes, str, str]:
    """
    Pull the first inlineData image out of a generateContent response.
    Returns (mime_type, raw_bytes, finish_reason, accompanying_text).
    Raises SafetyBlocked / NoImageReturned with actionable detail.
    """
    feedback = response.get("promptFeedback") or {}
    block_reason = feedback.get("blockReason")
    if block_reason:
        detail = _describe_safety_ratings(feedback.get("safetyRatings"))
        raise SafetyBlocked(
            str(block_reason),
            "    the PROMPT was rejected before generation\n"
            + (detail + "\n" if detail else "")
            + f"    message: {feedback.get('blockReasonMessage', '(none)')}",
        )

    candidates = response.get("candidates") or []
    if not candidates:
        raise NoImageReturned("NO_CANDIDATES", json.dumps(response)[:800])

    candidate = candidates[0]
    finish_reason = str(candidate.get("finishReason", "") or "")
    parts = ((candidate.get("content") or {}).get("parts")) or []

    texts: list[str] = []
    for part in parts:
        if not isinstance(part, dict):
            continue
        inline = part.get("inlineData") or part.get("inline_data")
        if isinstance(inline, dict) and inline.get("data"):
            mime = str(inline.get("mimeType") or inline.get("mime_type") or "image/png")
            try:
                raw = base64.b64decode(inline["data"], validate=False)
            except (binascii.Error, ValueError) as exc:
                raise NoImageReturned(finish_reason or "BAD_BASE64",
                                      f"inlineData was not decodable base64: {exc}") from exc
            return mime, raw, finish_reason or "STOP", "\n".join(texts).strip()
        if isinstance(part.get("text"), str):
            texts.append(part["text"])

    if finish_reason in BLOCKED_FINISH_REASONS:
        detail = _describe_safety_ratings(candidate.get("safetyRatings"))
        raise SafetyBlocked(
            finish_reason,
            "    the IMAGE was rejected after generation\n"
            + (detail + "\n" if detail else "")
            + ("    model said: " + "\n".join(texts).strip()[:400] + "\n" if texts else ""),
        )

    raise NoImageReturned(finish_reason or "UNKNOWN", "\n".join(texts).strip()[:800])


def _retry_delay_from_error(payload: dict[str, Any]) -> float | None:
    details = ((payload.get("error") or {}).get("details")) or []
    for detail in details:
        if not isinstance(detail, dict):
            continue
        if "RetryInfo" in str(detail.get("@type", "")):
            raw = str(detail.get("retryDelay", ""))
            match = re.match(r"^([0-9.]+)s$", raw)
            if match:
                return float(match.group(1))
    return None


def call_api(
    session: Any,
    model: str,
    body: dict[str, Any],
    api_key: str,
    *,
    timeout: float,
    max_retries: int,
    label: str,
    rng: random.Random,
) -> dict[str, Any]:
    """POST to generateContent with backoff on rate limits and 5xx."""
    url = endpoint_for(model)
    headers = {"x-goog-api-key": api_key, "Content-Type": "application/json"}
    attempt = 0
    while True:
        attempt += 1
        try:
            response = session.post(url, headers=headers, json=body, timeout=timeout)
        except Exception as exc:  # requests.RequestException and friends
            if attempt > max_retries:
                raise ApiError(0, f"network error after {max_retries} retries: {exc}", "") from exc
            delay = min(60.0, 2.0 ** attempt) + rng.uniform(0, 1.0)
            print(f"    [{label}] network error ({exc}); retry {attempt}/{max_retries} in {delay:.1f}s",
                  file=sys.stderr)
            time.sleep(delay)
            continue

        if response.status_code == 200:
            try:
                return response.json()
            except ValueError as exc:
                raise ApiError(200, f"200 OK but body was not JSON: {exc}",
                               response.text[:800]) from exc

        text = response.text or ""
        try:
            payload = response.json()
        except ValueError:
            payload = {}
        message = ((payload.get("error") or {}).get("message")) or text[:400] or "(no message)"

        if response.status_code in (401, 403):
            raise ApiError(response.status_code,
                           f"authentication rejected — check GEMINI_API_KEY. {message}", text[:800])
        if response.status_code == 404:
            raise ApiError(404,
                           f"model {model!r} not found at {url}. "
                           f"Known image models: {', '.join(KNOWN_MODELS)}. {message}", text[:800])
        if response.status_code not in RETRYABLE_STATUS or attempt > max_retries:
            raise ApiError(response.status_code, message, text[:800])

        header_delay = response.headers.get("Retry-After")
        delay = None
        if header_delay:
            try:
                delay = float(header_delay)
            except ValueError:
                delay = None
        if delay is None:
            delay = _retry_delay_from_error(payload)
        if delay is None:
            delay = min(60.0, 2.0 ** attempt)
        delay += rng.uniform(0, 1.0)
        kind = "rate limited" if response.status_code == 429 else f"HTTP {response.status_code}"
        print(f"    [{label}] {kind}; retry {attempt}/{max_retries} in {delay:.1f}s — {message[:160]}",
              file=sys.stderr)
        time.sleep(delay)


# ---------------------------------------------------------------------------
# Writing output
# ---------------------------------------------------------------------------

def write_png(raw: bytes, mime: str, out_path: Path, label: str) -> tuple[int, int, str]:
    """
    Persist the generation as a real PNG and return its true (width, height, format).
    PNG bytes are written verbatim (byte-exact provenance); anything else is
    converted, loudly — JPEG ringing around the #00FF00 key would survive the
    chroma key in plan §3.4 step 2 and reappear as a green halo after minification.
    """
    from PIL import Image  # imported here so --dry-run needs no Pillow at all

    image = Image.open(io.BytesIO(raw))
    image.load()
    width, height = image.size
    fmt = (image.format or "").upper()

    out_path.parent.mkdir(parents=True, exist_ok=True)
    if fmt == "PNG":
        out_path.write_bytes(raw)
    else:
        print(f"    [{label}] WARNING: model returned {mime} ({fmt}), not PNG. "
              "Converting, but lossy artefacts around the chroma key are already baked in — "
              "inspect the edges before trusting the key.", file=sys.stderr)
        image.convert("RGBA").save(out_path, format="PNG")
    return width, height, fmt


# ---------------------------------------------------------------------------
# Dry run + reporting
# ---------------------------------------------------------------------------

def print_dry_run(spec: PromptSpec, body: dict[str, Any], req_sha: str,
                  outs: list[Path], cached: list[bool]) -> None:
    est_w, est_h = estimate_px(spec.aspect_ratio, spec.image_size)
    print(f"── {spec.name} " + "─" * max(0, 66 - len(spec.name)))
    print(f"   POST {endpoint_for(spec.model)}")
    print("   headers: x-goog-api-key: <GEMINI_API_KEY>, Content-Type: application/json")
    print(f"   request sha256: {req_sha}")
    size_note = f"size spec {spec.size_raw!r}" if spec.size_raw is not None else "size spec (default)"
    print(f"   {size_note} -> aspectRatio {spec.aspect_ratio}, imageSize {spec.image_size}"
          f"  (expect ~{est_w}x{est_h} px; actual measured after download)")
    if spec.requested_px:
        rw, rh = spec.requested_px
        if (rw, rh) != (est_w, est_h):
            print(f"   note: spec asked for {rw}x{rh}; the API cannot be asked for exact pixels, "
                  f"so expect ~{est_w}x{est_h} and cut crop rects against the measured size.")
    for path, hit in zip(outs, cached):
        print(f"   -> {rel_to_root(path)}  [{'CACHED, would skip' if hit else 'WOULD CALL'}]")
    if spec.notes:
        print(f"   notes: {spec.notes}")
    print("   body:")
    for line in json.dumps(body, indent=2, ensure_ascii=False).splitlines():
        print(f"     {line}")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="generate.py",
        description="Generate BATTLE ROYAL sprite source art with Google's nano banana "
                    "(Gemini image) models. See docs/ART_UPGRADE_PLAN.md §3.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  uv run --project tools/art tools/art/generate.py --list\n"
            "  uv run --project tools/art tools/art/generate.py carrier --dry-run\n"
            "  uv run --project tools/art tools/art/generate.py carrier terrain\n"
            "  uv run --project tools/art tools/art/generate.py economy --only chip-body --force\n"
        ),
    )
    parser.add_argument("groups", nargs="*",
                        help="prompt group(s): tools/art/prompts/<group>.json")
    parser.add_argument("--list", action="store_true",
                        help="list available prompt groups and exit")
    parser.add_argument("--model", default=None,
                        help=f"override the model id for every entry (default per spec, "
                             f"else {DEFAULT_MODEL}). Known: {', '.join(KNOWN_MODELS)}")
    parser.add_argument("--only", action="append", default=[], metavar="NAME",
                        help="only this entry name (repeatable)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the exact request bodies and the billable call count; "
                             "makes no network call and needs no API key")
    parser.add_argument("--force", action="store_true",
                        help="ignore the cache and regenerate (this re-bills)")
    parser.add_argument("--out-dir", default=str(RAW_DIR),
                        help=f"output root (default {RAW_DIR})")
    parser.add_argument("--prompts-dir", default=str(PROMPTS_DIR),
                        help=f"prompt spec directory (default {PROMPTS_DIR})")
    parser.add_argument("--env-file", default=str(ENV_FILE),
                        help=f"dotenv file to read GEMINI_API_KEY from (default {ENV_FILE})")
    parser.add_argument("--timeout", type=float, default=300.0,
                        help="per-request timeout in seconds (default 300)")
    parser.add_argument("--max-retries", type=int, default=5,
                        help="retries on 429/5xx/network errors (default 5)")
    parser.add_argument("--sleep", type=float, default=0.0,
                        help="seconds to wait between successful calls (default 0)")
    parser.add_argument("--keep-going", action="store_true",
                        help="continue past a safety block or API error instead of stopping")

    local = parser.add_argument_group(
        "local backend (default)",
        "FLUX.1-schnell on this machine. Apache-2.0 weights, no API key, no "
        "per-image cost. See tools/art/flux_backend.py for why this is the "
        "default and why it is schnell specifically.")
    local.add_argument("--backend", choices=("local", "gemini"), default="local",
                       help="local = FLUX.1-schnell here; gemini = the hosted "
                            "nano banana path (needs GEMINI_API_KEY *and* a "
                            "billing account — the free tier reports limit: 0 "
                            "for every image model). Default: local")
    local.add_argument("--flux-model", default=None,
                       help=f"override the local model id (default {FLUX_MODEL_ID})")
    local.add_argument("--steps", type=int, default=None,
                       help="local sampling steps (default 4; schnell is "
                            "timestep-distilled and does not improve past that)")
    local.add_argument("--long-edge", type=int, default=None,
                       help="local source resolution long edge, overriding the "
                            "spec's imageSize token (default 1024)")
    local.add_argument("--offload", action="store_true",
                       help="local: sequential CPU offload — lower peak memory, "
                            "slower. Only needed under ~32 GB")
    local.add_argument("--device", default=None,
                       help="local: force a torch device (mps/cuda/cpu)")
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    prompts_dir = Path(args.prompts_dir).expanduser().resolve()
    out_root = Path(args.out_dir).expanduser().resolve()

    if args.list or not args.groups:
        groups = sorted(p.stem for p in prompts_dir.glob("*.json")) if prompts_dir.exists() else []
        if groups:
            print(f"prompt groups in {prompts_dir}:")
            for group in groups:
                try:
                    count = len(load_group(group, prompts_dir, None))
                    print(f"  {group}  ({count} entries)")
                except SpecError as exc:
                    print(f"  {group}  (INVALID: {exc})")
        else:
            print(f"no prompt specs found in {prompts_dir}")
            print("Author one as <group>.json — see tools/art/prompts/README.md.")
        if not args.groups and not args.list:
            print("\nnothing to do: name at least one group.", file=sys.stderr)
            return EXIT_USAGE
        return EXIT_OK

    if args.model and args.model not in KNOWN_MODELS:
        print(f"note: --model {args.model!r} is not in the known list "
              f"({', '.join(KNOWN_MODELS)}); sending it anyway.", file=sys.stderr)

    # Load and validate every group up front — a typo in group 3 should not be
    # discovered after group 1 has already been billed.
    plan: list[tuple[str, list[PromptSpec]]] = []
    for group in args.groups:
        try:
            specs = load_group(group, prompts_dir, args.model)
        except SpecError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return EXIT_USAGE
        if args.only:
            wanted = set(args.only)
            specs = [s for s in specs if s.name in wanted]
            missing = wanted - {s.name for s in specs}
            if missing:
                print(f"error: --only named unknown entries in {group}: "
                      f"{', '.join(sorted(missing))}", file=sys.stderr)
                return EXIT_USAGE
        plan.append((group, specs))

    use_local = args.backend == "local"
    flux_cfg = FluxConfig(
        model_id=args.flux_model or FLUX_MODEL_ID,
        steps=args.steps if args.steps is not None else FluxConfig.steps,
        long_edge=args.long_edge,
        offload=args.offload,
        device=args.device,
    )
    flux = FluxPipeline(flux_cfg) if use_local else None

    api_key, key_source = resolve_api_key(Path(args.env_file).expanduser())
    if not use_local and not args.dry_run and not api_key:
        print(missing_key_message(Path(args.env_file).expanduser()), file=sys.stderr)
        return EXIT_NO_KEY

    session = None
    if not args.dry_run and not use_local:
        try:
            import requests
        except ImportError:
            print("error: `requests` is not installed. Run this via uv:\n"
                  "  uv run --project tools/art tools/art/generate.py ...", file=sys.stderr)
            return EXIT_USAGE
        session = requests.Session()

    rng = random.Random(0xC0FFEE)  # jitter only; never touches the art
    total_calls = 0
    total_cached = 0
    total_written = 0
    total_bytes = 0
    failures: list[str] = []
    blocked: list[str] = []

    mode = "DRY RUN — nothing generated" if args.dry_run else "LIVE"
    print(f"BATTLE ROYAL art generation harness — {mode}")
    print(f"repo:    {ROOT}")
    print(f"output:  {out_root}")
    if use_local:
        print(f"backend: local — {describe_flux(flux_cfg)}")
        print("cost:    none (Apache-2.0 weights, generated on this machine)")
    else:
        print("backend: gemini (hosted)")
        print(f"api key: {key_source}" + ("" if api_key else "  (fine for --dry-run)"))
    print()

    for group, specs in plan:
        group_dir = out_root / group
        manifest = load_manifest(group_dir)
        print(f"═══ group {group}  ({len(specs)} entries -> {rel_to_root(group_dir)})")
        print()

        for spec in specs:
            body = build_request_body(spec)
            if use_local:
                # The cache key must name the backend and everything that
                # changes the pixels, or switching backends (or steps, or
                # resolution) would silently serve art made by the other one.
                req_sha = request_sha256(
                    f"local:{flux_cfg.model_id}:{flux_cfg.steps}:"
                    f"{flux_cfg.guidance}:{flux_cfg.long_edge}",
                    body)
            else:
                req_sha = request_sha256(spec.model, body)
            outs = output_paths(group_dir, spec)
            cached = [(not args.force) and is_cached(manifest, path, req_sha) for path in outs]

            if args.dry_run:
                print_dry_run(spec, body, req_sha, outs, cached)
                total_cached += sum(1 for hit in cached if hit)
                total_calls += sum(1 for hit in cached if not hit)
                continue

            for index, (out_path, hit) in enumerate(zip(outs, cached)):
                label = out_path.name
                if hit:
                    total_cached += 1
                    print(f"  ✓ {label}  cached (prompt unchanged) — not billed")
                    continue

                seed_used = None
                if use_local:
                    print(f"  → {label}  generating locally "
                          f"({flux_cfg.model_id.rsplit('/', 1)[-1]}, "
                          f"{spec.aspect_ratio} @ {spec.image_size})"
                          + (f"  variant {index + 1}/{spec.variants}"
                             if spec.variants > 1 else ""))
                    try:
                        # Perturb the deterministic per-prompt seed by the
                        # variant index: Gemini gets variety from server
                        # nondeterminism, but a seeded local model would
                        # otherwise emit N identical PNGs.
                        base_seed = flux_seed_for(spec.prompt, spec.seed)
                        raw, _gw, _gh, seed_used = flux.generate_png(
                            spec.prompt, spec.aspect_ratio, spec.image_size,
                            seed=(base_seed + index) & 0x7FFFFFFF)
                        total_calls += 1
                        mime, finish_reason, text = "image/png", "LOCAL", ""
                    except (FluxUnavailable, RuntimeError, ValueError) as exc:
                        failures.append(f"{group}/{label}")
                        print(f"  ✗ {label}  local generation failed: {exc}",
                              file=sys.stderr)
                        if args.keep_going:
                            continue
                        return EXIT_API
                else:
                  print(f"  → {label}  calling {spec.model} "
                        f"({spec.aspect_ratio} @ {spec.image_size})"
                        + (f"  variant {index + 1}/{spec.variants}" if spec.variants > 1 else ""))
                  try:
                    response = call_api(
                        session, spec.model, body, api_key,
                        timeout=args.timeout, max_retries=args.max_retries,
                        label=label, rng=rng,
                    )
                    total_calls += 1
                    mime, raw, finish_reason, text = extract_image(response)
                  except SafetyBlocked as exc:
                    total_calls += 1
                    blocked.append(f"{group}/{label}")
                    print(f"  ✗ {label}  SAFETY BLOCK — {exc.reason}", file=sys.stderr)
                    print(exc.detail, file=sys.stderr)
                    print("    Not cached and not retried: the same prompt will be blocked again.\n"
                          "    Rewrite the prompt (weapons, gore and violence wording are the usual\n"
                          "    triggers for this catalogue — say 'icon of a fencing foil', not\n"
                          "    'sword for killing') and re-run this one entry with --only.",
                          file=sys.stderr)
                    if args.keep_going:
                        continue
                    return EXIT_BLOCKED
                  except NoImageReturned as exc:
                    total_calls += 1
                    failures.append(f"{group}/{label}")
                    print(f"  ✗ {label}  no image returned (finishReason={exc.finish_reason})",
                          file=sys.stderr)
                    if exc.text:
                        print(f"    model text: {exc.text[:400]}", file=sys.stderr)
                    if args.keep_going:
                        continue
                    return EXIT_API
                  except ApiError as exc:
                    failures.append(f"{group}/{label}")
                    print(f"  ✗ {label}  {exc}", file=sys.stderr)
                    if exc.body:
                        print(f"    body: {exc.body[:600]}", file=sys.stderr)
                    if args.keep_going:
                        continue
                    return EXIT_API

                width, height, fmt = write_png(raw, mime, out_path, label)
                digest = hashlib.sha256(out_path.read_bytes()).hexdigest()
                nbytes = out_path.stat().st_size
                total_written += 1
                total_bytes += nbytes

                est_w, est_h = estimate_px(spec.aspect_ratio, spec.image_size)
                flag = "" if (width, height) == (est_w, est_h) else \
                    f"  (expected ~{est_w}x{est_h} — cut crop rects against the ACTUAL size)"
                print(f"    wrote {width}x{height} px, {nbytes:,} B, {fmt}{flag}")
                if spec.requested_px and (width, height) != spec.requested_px:
                    print(f"    note: spec requested {spec.requested_px[0]}x{spec.requested_px[1]}; "
                          f"got {width}x{height}. art/sheets.json crop rects must use {width}x{height}.")

                manifest["entries"][out_path.name] = {
                    "file": out_path.name,
                    "entry": spec.name,
                    "variant": index + 1,
                    "variants": spec.variants,
                    "model": (f"local:{flux_cfg.model_id}" if use_local
                              else spec.model),
                    "endpoint": ("local" if use_local
                                 else endpoint_for(spec.model)),
                    "seed_used": seed_used,
                    "steps": flux_cfg.steps if use_local else None,
                    "guidance": flux_cfg.guidance if use_local else None,
                    "request_sha256": req_sha,
                    "aspect_ratio": spec.aspect_ratio,
                    "image_size": spec.image_size,
                    "requested_px": list(spec.requested_px) if spec.requested_px else None,
                    "actual_px": [width, height],
                    "source_format": fmt,
                    "mime_type": mime,
                    "bytes": nbytes,
                    "sha256": digest,
                    "finish_reason": finish_reason,
                    "model_text": text[:2000],
                    "notes": spec.notes,
                    "prompt": spec.prompt,
                    "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
                save_manifest(group_dir, manifest)
                if args.sleep > 0:
                    time.sleep(args.sleep)

        if not args.dry_run:
            save_manifest(group_dir, manifest)
        print()

    print("─" * 72)
    if args.dry_run:
        print(f"DRY RUN: {total_calls} billable image generation(s) would be requested; "
              f"{total_cached} cached entr(y/ies) would be skipped.")
        if not api_key:
            print("No API key present — that is fine for --dry-run. "
                  "Add GEMINI_API_KEY to .env before running for real.")
    else:
        print(f"{total_calls} API call(s), {total_written} image(s) written "
              f"({total_bytes:,} B), {total_cached} cached and not billed.")
        if blocked:
            print(f"safety-blocked: {', '.join(blocked)}")
        if failures:
            print(f"failed: {', '.join(failures)}")

    if blocked:
        return EXIT_BLOCKED
    if failures:
        return EXIT_API
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
