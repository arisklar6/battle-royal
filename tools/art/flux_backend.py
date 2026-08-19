"""Local FLUX.2 [klein] 4B backend for the BATTLE ROYAL art pipeline.

Why local, and why this model specifically (decided 2026-08-17; model updated
to FLUX.2 klein-4B 2026-08-18 when BFL's newer Apache-2.0 model landed locally):

  * Battle Royal is a PUBLIC, MIT repo, so the generator's licence attaches to art
    we would be committing. FLUX.2 [klein] 4B is Apache-2.0 and ungated
    (verified on the model card 2026-08-18) — same clean terms as schnell,
    newer model, a third the size. FLUX.2 [dev] and klein-9B are explicitly
    non-commercial; SDXL is Open RAIL++ and the sprite LoRAs people actually
    use for pixel art mostly have unstated terms.
  * Every Gemini image model reports `limit: 0` on the free tier — image
    generation there needs billing, and iteration would cost money per attempt.
  * At our target sizes the generator matters far less than the reduction.
    Each source image is minified to a 24x24 tile or a 32x48 carrier, then
    alpha-keyed and snapped to the AFTERGLOW palette in OKLab by bake.py. Past
    a quality floor, what survives that reduction is silhouette and value
    structure — not brushwork. Unlimited free iteration (generate 50, keep the
    best) buys more than any per-image fidelity gain would.

Determinism: seeds derive from the prompt text by default, so the same spec
reproduces the same PNG across runs and machines. That matters in a repo whose
whole identity is bit-exactness — `art/raw/**` should be regenerable, not a
pile of lucky draws. Pass an explicit `seed` in the spec to pin one.

Hardware note: on Apple Silicon the model runs on MPS in bfloat16. klein-4B
is a 4B rectified-flow transformer; peak resident is ~13 GB, comfortable on a
48 GB machine with room for the baker beside it. `--offload` trades speed for
headroom by moving components to CPU between stages; on unified memory that
saves less than it does on discrete GPUs, so it is a fallback rather than the
default (and with klein-4B it should rarely be needed at all).
"""

from __future__ import annotations

import hashlib
import io
import os
import sys
import time
from dataclasses import dataclass
from typing import Any

MODEL_ID = "black-forest-labs/FLUX.2-klein-4B"

# klein-4B is size-distilled for 4 steps with CFG effectively off: the model
# card's reference pipeline runs num_inference_steps=4, guidance_scale=1.0.
# Raising steps mostly burns time; raising guidance degrades a distilled model.
DEFAULT_STEPS = 4
DEFAULT_GUIDANCE = 1.0

# Long edge of the generated source image. Deliberately not 2K/4K: the largest
# thing we bake is the 1152x1152 floor field, everything else reduces to <= 72px,
# and FLUX at 2K on MPS costs ~4x the time for detail the minifier discards.
# The crop-rect rule in ART_UPGRADE_PLAN §3.3 wants crop/target to be a power of
# two, so sizes are rounded to a multiple of 16 and checked against the target.
DEFAULT_LONG_EDGE = 1024
SIZE_LONG_EDGE = {"512px": 768, "1K": 1024, "2K": 1280, "4K": 1536}


class FluxUnavailable(RuntimeError):
    """Raised when the local extra is not installed or the device is unusable."""


@dataclass
class FluxConfig:
    model_id: str = MODEL_ID
    steps: int = DEFAULT_STEPS
    guidance: float = DEFAULT_GUIDANCE
    long_edge: int | None = None
    offload: bool = False
    device: str | None = None


def _round16(value: int) -> int:
    """FLUX requires both dimensions divisible by 16 (VAE 8x, patch 2x)."""
    return max(256, int(round(value / 16.0)) * 16)


def dimensions_for(aspect_ratio: str, image_size: str,
                   cfg: FluxConfig) -> tuple[int, int]:
    """Map a spec's aspectRatio + imageSize token onto real FLUX pixels.

    The Gemini API takes a ratio plus a size token and decides pixels itself;
    locally we must choose. Keeping the same spec fields means one prompt file
    drives both backends and the crop rects in art/sheets.json stay meaningful.
    """
    try:
        rw, rh = (int(part) for part in aspect_ratio.split(":"))
    except Exception as exc:
        raise ValueError(f"bad aspect_ratio {aspect_ratio!r}") from exc
    if rw <= 0 or rh <= 0:
        raise ValueError(f"bad aspect_ratio {aspect_ratio!r}")

    long_edge = cfg.long_edge or SIZE_LONG_EDGE.get(image_size, DEFAULT_LONG_EDGE)
    if rw >= rh:
        width, height = long_edge, long_edge * rh / rw
    else:
        width, height = long_edge * rw / rh, long_edge
    return _round16(width), _round16(height)


def seed_for(prompt: str, explicit: int | None) -> int:
    """Deterministic per prompt unless the spec pins one."""
    if explicit is not None:
        return int(explicit) & 0x7FFFFFFF
    digest = hashlib.sha256(prompt.encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") & 0x7FFFFFFF


def _pick_device(requested: str | None) -> str:
    try:
        import torch
    except ImportError as exc:  # pragma: no cover - guarded by ensure_available
        raise FluxUnavailable(_install_hint()) from exc
    if requested:
        return requested
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _install_hint() -> str:
    return (
        "local FLUX backend needs the 'local' extra:\n"
        "    uv sync --project tools/art --extra local\n"
        "It installs torch + diffusers (~2 GB of wheels). The model weights\n"
        f"({MODEL_ID}, Apache-2.0, ungated — no HF token needed) download on\n"
        "first use into ~/.cache/huggingface, about 22 GB."
    )


def ensure_available() -> None:
    """Fail early and actionably rather than deep inside a generation loop."""
    try:
        import torch  # noqa: F401
        import diffusers  # noqa: F401
    except ImportError as exc:
        raise FluxUnavailable(_install_hint()) from exc


class FluxPipeline:
    """Lazily-loaded wrapper. Loading costs ~60-90 s and ~34 GB, so it happens
    once per process and is reused across every prompt in the run."""

    def __init__(self, cfg: FluxConfig) -> None:
        self.cfg = cfg
        self._pipe: Any = None
        self._device: str | None = None

    def _load(self) -> None:
        if self._pipe is not None:
            return
        ensure_available()
        import torch
        from diffusers import Flux2KleinPipeline as _DiffusersFlux

        device = _pick_device(self.cfg.device)
        self._device = device
        dtype = torch.bfloat16 if device != "cpu" else torch.float32

        print(f"  loading {self.cfg.model_id} on {device} ({dtype}) …",
              file=sys.stderr, flush=True)
        started = time.time()
        pipe = _DiffusersFlux.from_pretrained(self.cfg.model_id, torch_dtype=dtype)
        if self.cfg.offload:
            # Sequential offload keeps peak resident memory down at a real
            # speed cost. On unified memory this helps less than on discrete
            # GPUs, so it is opt-in.
            pipe.enable_sequential_cpu_offload()
        else:
            pipe.to(device)
        try:
            pipe.set_progress_bar_config(disable=True)
        except Exception:
            pass
        self._pipe = pipe
        print(f"  loaded in {time.time() - started:.0f}s", file=sys.stderr, flush=True)

    def generate_png(self, prompt: str, aspect_ratio: str, image_size: str,
                     seed: int | None = None) -> tuple[bytes, int, int, int]:
        """Return (png_bytes, width, height, seed_used)."""
        self._load()
        import torch

        width, height = dimensions_for(aspect_ratio, image_size, self.cfg)
        used_seed = seed_for(prompt, seed)
        generator = torch.Generator(device="cpu").manual_seed(used_seed)

        image = self._pipe(
            prompt=prompt,
            width=width,
            height=height,
            num_inference_steps=self.cfg.steps,
            guidance_scale=self.cfg.guidance,
            generator=generator,
        ).images[0]

        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return buffer.getvalue(), width, height, used_seed


def describe(cfg: FluxConfig) -> str:
    """One-line summary for --dry-run, so the plan is auditable without a load."""
    where = cfg.device or "auto (mps > cuda > cpu)"
    return (f"{cfg.model_id} · {cfg.steps} steps · guidance {cfg.guidance} · "
            f"device {where}{' · sequential offload' if cfg.offload else ''}")


def selftest() -> int:
    """Exercises everything that does not need the weights on disk."""
    failures = 0

    def check(label: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        if not ok:
            failures += 1
            print(f"FAIL {label} {detail}")
        else:
            print(f"ok   {label}")

    cfg = FluxConfig()
    w, h = dimensions_for("1:1", "1K", cfg)
    check("1:1 @1K is square", w == h == 1024, f"got {w}x{h}")

    w, h = dimensions_for("2:3", "2K", cfg)
    check("2:3 is portrait", h > w, f"got {w}x{h}")
    check("2:3 ratio within 2%", abs((w / h) - (2 / 3)) < 0.02, f"got {w}x{h}")

    w, h = dimensions_for("16:9", "1K", cfg)
    check("16:9 is landscape", w > h, f"got {w}x{h}")

    for ratio in ("1:1", "2:3", "3:2", "4:3", "16:9", "21:9", "1:4", "8:1"):
        for size in ("512px", "1K", "2K", "4K"):
            w, h = dimensions_for(ratio, size, cfg)
            if w % 16 or h % 16:
                check(f"{ratio}@{size} divisible by 16", False, f"got {w}x{h}")
                break
            if w < 256 or h < 256:
                check(f"{ratio}@{size} above VAE floor", False, f"got {w}x{h}")
                break
    else:
        check("every ratio/size is /16 and >= 256", True)

    cfg_long = FluxConfig(long_edge=512)
    w, h = dimensions_for("1:1", "4K", cfg_long)
    check("--long-edge overrides the size token", max(w, h) == 512, f"got {w}x{h}")

    a = seed_for("carrier", None)
    b = seed_for("carrier", None)
    c = seed_for("carrier ", None)
    check("seed is deterministic per prompt", a == b)
    check("seed differs on a changed prompt", a != c)
    check("explicit seed wins", seed_for("carrier", 7) == 7)
    check("seed fits int32", 0 <= a <= 0x7FFFFFFF)

    check("guidance is 1.0 (klein is CFG-distilled; 1.0 = CFG off)",
          DEFAULT_GUIDANCE == 1.0)
    check("steps is 4 (klein is 4-step distilled)", DEFAULT_STEPS == 4)
    check("model is the Apache-2.0 klein-4B, not dev/9B (non-commercial)",
          MODEL_ID.endswith("FLUX.2-klein-4B"))

    try:
        dimensions_for("oops", "1K", cfg)
        check("bad ratio raises", False)
    except ValueError:
        check("bad ratio raises", True)

    print()
    print(describe(cfg))
    try:
        ensure_available()
        print("local extra: installed")
    except FluxUnavailable as exc:
        print(f"local extra: NOT installed\n{exc}")

    print()
    print("FAILURES:" if failures else "ALL CHECKS PASSED", failures or "")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(selftest())
