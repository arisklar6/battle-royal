#!/usr/bin/env python3
"""bake.py — PNG -> Nim const RGBA baker for ZERO SUM (AFTERGLOW).

Implements the reduction chain in docs/ART_UPGRADE_PLAN.md §3.4, the ramps in
§3.5, and the bake format in §4.2.  One generated image in, one reviewable Nim
fragment out.

    decode -> crop -> chroma key -> despill -> solidify -> alpha-weighted
    area minify -> alpha discipline -> quantize (OKLab) -> ink pass -> lint
    -> emit

Correctness notes that are load-bearing, not decoration:

* **Premultiply before resampling.**  Straight-alpha RGBA cannot be averaged
  channel-wise: a transparent pixel still carries an RGB triple, and a naive
  box filter averages that dead colour into every rim pixel, producing a halo
  of whatever the background happened to be.  Every reduction here premultiplies
  (c*a), area-averages, then unpremultiplies (c/a).  This is the single most
  important line of code in the file; `--selftest` asserts it against a naive
  resize that visibly bleeds.
* **Bitwise-zero transparency.**  `dimmed()` in render.nim scales alpha
  proportionally, so residual haze in the "empty" corners survives every fade
  stage as a dim floating rectangle, and `addBacklight`'s hard `<40` / `>=128`
  thresholds silently stop working.  a < --alpha-zero becomes RGBA(0,0,0,0)
  exactly, and the lint asserts no alpha mass in 1..alpha_zero-1.
* **Perceptual snapping.**  Palette snapping runs in OKLab, not RGB.  Naive RGB
  euclidean distance routinely pulls a mid amber onto an Etch blue-grey because
  the two are numerically close and perceptually nothing alike.
* **Determinism.**  Fixed-order median cut, no RNG, no timestamps in the output.
  Baking the same PNG twice is byte-identical (ART_UPGRADE_PLAN risk #11).

Usage:

    uv run --project tools/art tools/art/bake.py art/source/carrier.png \\
        --name CarrierS --size 32x48 --crop 0,0,256,384 \\
        --out game/art_carrier.nim --palette afterglow --colors 16 \\
        --ink stone --contact-sheet /tmp/carrier.png

    uv run --project tools/art tools/art/bake.py --selftest
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

# --------------------------------------------------------------------------
# §3.5 — the ramps, made mechanical.  These are the ONLY legal source for
# generated pixels.  Semantic colours are reserved for lines and glyphs the
# code draws; team hue is stamped by code and never generated.
# --------------------------------------------------------------------------

RAMPS: dict[str, tuple[str, ...]] = {
    "etch": (
        "1C242B", "232D36", "2A3742", "313E4A",
        "36444F", "3E4D59", "465563", "4E5E6B",
    ),
    "phosphor": (
        "2A4A52", "3E6B76", "52909D", "6EB4C2",
        "8ACFDC", "A5E3EE", "C6EDF4", "EAF7FA",
    ),
    "amber": (
        "3A2610", "5C3D18", "8A5B22", "B8792E",
        "E0953C", "FFB454", "FFC97E", "FFD9A0",
    ),
    "ink": ("10161C",),
    # Lines and glyphs only, never fills.  Off by default.
    "semantic": ("FF4FA3", "FF4A36", "E9E4D8"),
    # Code-stamped, never generated.  Off by default; here so a lint can name
    # a violation precisely instead of reporting "unknown colour".
    "team": (
        "FF8FA8", "49C7E8", "E8C558", "9B7BFF",
        "E85D75", "9FB8D8", "E8975D", "D97BE8",
    ),
    # Neutral ramp for monochrome-plus-alpha assets that code tints later
    # (the burst star: 1 image -> 15 sprites via 3 tints x dimmed() stages).
    "mono": (
        "101418", "2A2E33", "44494F", "5F646B",
        "7A8087", "969CA3", "B3B8BE", "D0D4D9",
        "E9EBEE", "FFFFFF",
    ),
}

DEFAULT_RAMPS = ("etch", "phosphor", "amber", "ink")

STONE_INK = (0x10, 0x16, 0x1C)          # render.nim StoneInk, near-black blue
BG_DARK = (40, 48, 57)                  # render.nim BgDark — the lit substrate
CHROMA_KEY = (0x00, 0xFF, 0x00)         # §3.1 — AFTERGLOW forbids green, so
                                        # pure green can never collide with art

# Green hue band for the lint.  Phosphor bottoms out near 189 degrees and amber
# tops out near 40, so [65, 175] has real headroom on both sides.
GREEN_HUE_LO, GREEN_HUE_HI = 65.0, 175.0

TIER_A_MIN_DIM = 20                     # §1 hard rule

PREVIEW_TRANSPARENT = "."
PREVIEW_PARTIAL = ","
PREVIEW_RAMP = ":-=+*#%@"


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.strip().lstrip("#")
    if len(h) != 6:
        raise ValueError(f"bad hex colour {h!r} (want RRGGBB)")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def rgb_to_hex(c) -> str:
    return "%02X%02X%02X" % (int(c[0]), int(c[1]), int(c[2]))


def pack_keys(cols: np.ndarray) -> np.ndarray:
    """(N,3) RGB -> (N,) 0xRRGGBB int64 keys.  Sorting these is lexicographic
    RGB order, which is what makes the median cut's tie-breaks deterministic.
    numpy 2 refuses uint8 * 256, hence the explicit widen."""
    c = np.asarray(cols, dtype=np.int64)
    return c[..., 0] * 65536 + c[..., 1] * 256 + c[..., 2]


def unpack_keys(keys: np.ndarray) -> np.ndarray:
    k = np.asarray(keys, dtype=np.int64)
    return np.stack([(k >> 16) & 255, (k >> 8) & 255, k & 255], axis=-1).astype(np.uint8)


# --------------------------------------------------------------------------
# OKLab.  Björn Ottosson's matrices, vectorized.  Snapping and median-cut both
# happen here so that "nearest colour" means what the eye means.
# --------------------------------------------------------------------------

def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    c = np.asarray(c, dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(np.asarray(c, dtype=np.float64), 0.0, 1.0)
    out = np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)
    return np.clip(out * 255.0, 0.0, 255.0)


def rgb_to_oklab(rgb: np.ndarray) -> np.ndarray:
    """rgb: (..., 3) in 0..255 -> (..., 3) OKLab."""
    lin = srgb_to_linear(rgb)
    r, g, b = lin[..., 0], lin[..., 1], lin[..., 2]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    return np.stack([
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    ], axis=-1)


def oklab_to_rgb(lab: np.ndarray) -> np.ndarray:
    lab = np.asarray(lab, dtype=np.float64)
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    return linear_to_srgb(np.stack([
        +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ], axis=-1))


def rgb_hue(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Plain HSV hue/sat/val on 0..255 RGB.  Used only by the green lint."""
    c = np.asarray(rgb, dtype=np.float64) / 255.0
    mx = c.max(axis=-1)
    mn = c.min(axis=-1)
    d = mx - mn
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        h = np.select(
            [d == 0, mx == r, mx == g],
            [0.0, ((g - b) / np.where(d == 0, 1, d)) % 6.0, (b - r) / np.where(d == 0, 1, d) + 2.0],
            default=(r - g) / np.where(d == 0, 1, d) + 4.0,
        ) * 60.0
    sat = np.where(mx == 0, 0.0, d / np.where(mx == 0, 1, mx))
    return h % 360.0, sat, mx


# --------------------------------------------------------------------------
# Palette resolution
# --------------------------------------------------------------------------

@dataclass
class Palette:
    name: str
    colors: np.ndarray          # (N, 3) uint8
    lab: np.ndarray             # (N, 3) float64
    labels: list[str]           # "amber[5]" style, for lint messages

    @property
    def size(self) -> int:
        return int(self.colors.shape[0])


def build_palette(spec: str, ramp_names: tuple[str, ...] | None = None) -> Palette | None:
    """spec: 'afterglow' | 'afterglow-full' | 'mono' | 'free'/'none' |
    'hex:AABBCC,...' | '@path/to/list.txt'"""
    spec = (spec or "afterglow").strip()
    if spec in ("free", "none", ""):
        return None

    entries: list[tuple[str, str]] = []       # (label, hex)
    if spec.startswith("hex:"):
        for i, h in enumerate(spec[4:].split(",")):
            if h.strip():
                entries.append((f"custom[{i}]", h.strip().lstrip("#").upper()))
        name = "custom"
    elif spec.startswith("@"):
        # '#' is both the comment marker and the customary hex prefix, so a
        # naive split on '#' silently eats every "#AABBCC" line and yields an
        # empty palette.  Only treat '#' as a comment when what follows is not
        # six hex digits.
        text = Path(spec[1:]).read_text(encoding="utf-8")
        i = 0
        for raw in text.splitlines():
            for tok in raw.replace(",", " ").split():
                t = tok.lstrip("#").upper()
                if len(t) >= 6 and all(c in "0123456789ABCDEF" for c in t[:6]):
                    entries.append((f"file[{i}]", t[:6]))
                    i += 1
                else:
                    break               # rest of the line is a comment
        name = f"file:{Path(spec[1:]).name}"
    else:
        if spec == "afterglow":
            names = ramp_names or DEFAULT_RAMPS
        elif spec == "afterglow-full":
            names = ramp_names or (DEFAULT_RAMPS + ("semantic", "team"))
        elif spec in RAMPS:
            names = (spec,)
        else:
            raise SystemExit(f"bake: unknown palette {spec!r}")
        for rn in names:
            if rn not in RAMPS:
                raise SystemExit(f"bake: unknown ramp {rn!r} (have {', '.join(RAMPS)})")
            for i, h in enumerate(RAMPS[rn]):
                entries.append((f"{rn}[{i}]", h))
        name = spec if not ramp_names else f"{spec}({'+'.join(names)})"

    if not entries:
        raise SystemExit("bake: palette resolved to zero colours")

    seen: dict[str, str] = {}
    for label, h in entries:
        seen.setdefault(h, label)
    cols = np.array([hex_to_rgb(h) for h in seen], dtype=np.uint8)
    return Palette(name=name, colors=cols, lab=rgb_to_oklab(cols), labels=list(seen.values()))


def snap_to_palette(rgb: np.ndarray, pal: Palette) -> np.ndarray:
    """rgb: (N,3) 0..255 -> nearest palette entry per row, OKLab distance."""
    if rgb.size == 0:
        return rgb.astype(np.uint8)
    lab = rgb_to_oklab(np.asarray(rgb, dtype=np.float64))
    # (N, P) distance matrix.  Palettes are <=32 entries; this is cheap.
    d = ((lab[:, None, :] - pal.lab[None, :, :]) ** 2).sum(axis=-1)
    return pal.colors[np.argmin(d, axis=1)]


# --------------------------------------------------------------------------
# §3.4 step 2-4 — key, despill, solidify
# --------------------------------------------------------------------------

def chroma_key(rgba: np.ndarray, key: tuple[int, int, int]) -> np.ndarray:
    """Zero alpha on the key colour.  For pure green this is the plan's
    predicate verbatim (g > 190 && r < 110 && b < 110); for any other key it is
    a tolerance ball in OKLab."""
    out = rgba.copy()
    r = out[..., 0].astype(np.int16)
    g = out[..., 1].astype(np.int16)
    b = out[..., 2].astype(np.int16)
    if tuple(key) == CHROMA_KEY:
        hit = (g > 190) & (r < 110) & (b < 110)
    else:
        lab = rgb_to_oklab(out[..., :3].astype(np.float64))
        klab = rgb_to_oklab(np.array(key, dtype=np.float64))
        hit = ((lab - klab) ** 2).sum(axis=-1) < (0.10 ** 2)
    out[..., 3] = np.where(hit, 0, 255).astype(np.uint8)
    return out


def despill(rgba: np.ndarray, amount: int = 12) -> np.ndarray:
    """g = min(g, max(r, b) + amount) on kept pixels.  Green fringing survives
    reduction and reappears as a halo; kill it before averaging."""
    out = rgba.copy()
    keep = out[..., 3] > 0
    r = out[..., 0].astype(np.int16)
    g = out[..., 1].astype(np.int16)
    b = out[..., 2].astype(np.int16)
    capped = np.minimum(g, np.maximum(r, b) + amount)
    out[..., 1] = np.where(keep, np.clip(capped, 0, 255), g).astype(np.uint8)
    return out


def _shift(a: np.ndarray, dy: int, dx: int, fill) -> np.ndarray:
    """out[y, x] = a[y + dy, x + dx], `fill` outside."""
    out = np.full_like(a, fill)
    h, w = a.shape
    if abs(dy) >= h or abs(dx) >= w:
        # A jump-flood step can exceed the SHORTER side of a non-square
        # image; the raw slice arithmetic below would go negative and wrap
        # from the end, pairing mismatched shapes. Everything is fill.
        return out
    yd = slice(max(0, -dy), h - max(0, dy))
    ys = slice(max(0, dy), h - max(0, -dy))
    xd = slice(max(0, -dx), w - max(0, dx))
    xs = slice(max(0, dx), w - max(0, -dx))
    out[yd, xd] = a[ys, xs]
    return out


def solidify(rgba: np.ndarray) -> np.ndarray:
    """Flood the transparent region's RGB from its nearest opaque neighbour
    (jump flood, O(log n) passes).

    Without this, an averaging reduction that hits a block of pure transparency
    has no colour to fall back on and the guard branch emits black — a dark
    fringe in exactly the places the silhouette is thinnest."""
    out = rgba.copy()
    mask = out[..., 3] > 0
    if not mask.any() or mask.all():
        return out
    h, w = mask.shape
    yy, xx = np.meshgrid(np.arange(h, dtype=np.int32),
                         np.arange(w, dtype=np.int32), indexing="ij")
    INF = np.int64(1) << 40
    by = np.where(mask, yy, np.int32(-1))
    bx = np.where(mask, xx, np.int32(-1))

    def dist2(cy: np.ndarray, cx: np.ndarray) -> np.ndarray:
        valid = cy >= 0
        d = (yy.astype(np.int64) - cy.astype(np.int64)) ** 2 \
            + (xx.astype(np.int64) - cx.astype(np.int64)) ** 2
        return np.where(valid, d, INF)

    bd = dist2(by, bx)
    step = 1
    while step < max(h, w):
        step *= 2
    step //= 2
    while step >= 1:
        for dy in (-step, 0, step):
            for dx in (-step, 0, step):
                if dy == 0 and dx == 0:
                    continue
                cy = _shift(by, dy, dx, np.int32(-1))
                cx = _shift(bx, dy, dx, np.int32(-1))
                cd = dist2(cy, cx)
                better = cd < bd
                bd = np.where(better, cd, bd)
                by = np.where(better, cy, by)
                bx = np.where(better, cx, bx)
        step //= 2

    filled = out[..., :3][np.clip(by, 0, h - 1), np.clip(bx, 0, w - 1)]
    hole = ~mask & (by >= 0)
    out[..., :3] = np.where(hole[..., None], filled, out[..., :3])
    return out


# --------------------------------------------------------------------------
# §3.4 step 5 — alpha-weighted area minify.  THE correctness core.
# --------------------------------------------------------------------------

def _halve(px: np.ndarray) -> np.ndarray:
    """One exact 2x2 box halving of straight-alpha float RGBA.

    a' = mean(a);  c' = sum(c*a) / sum(a)  — i.e. premultiply, average,
    unpremultiply.  Where the whole block is transparent, fall through to the
    plain RGB mean so the solidified colour keeps propagating down the chain
    instead of collapsing to black."""
    h, w, _ = px.shape
    assert h % 2 == 0 and w % 2 == 0, "halving needs even dimensions"
    blk = px.reshape(h // 2, 2, w // 2, 2, 4)
    a = blk[..., 3:4]
    pm = (blk[..., :3] * a).mean(axis=(1, 3))       # premultiplied mean
    a2 = a.mean(axis=(1, 3))
    plain = blk[..., :3].mean(axis=(1, 3))
    rgb = np.where(a2 > 1e-9, pm / np.maximum(a2, 1e-9), plain)
    return np.concatenate([rgb, a2], axis=-1)


def _area_resize(px: np.ndarray, tw: int, th: int) -> np.ndarray:
    """General (non power-of-two) reduction: premultiply, PIL BOX (a true area
    filter with fractional edge coverage), unpremultiply."""
    a = px[..., 3:4]
    pm = np.concatenate([px[..., :3] * a, a], axis=-1)
    plain = px[..., :3]

    def rs(chan: np.ndarray) -> np.ndarray:
        img = Image.fromarray(chan.astype(np.float32), mode="F")
        return np.asarray(img.resize((tw, th), Image.BOX), dtype=np.float64)

    pm_r = np.stack([rs(pm[..., i]) for i in range(4)], axis=-1)
    plain_r = np.stack([rs(plain[..., i]) for i in range(3)], axis=-1)
    a2 = pm_r[..., 3:4]
    rgb = np.where(a2 > 1e-9, pm_r[..., :3] / np.maximum(a2, 1e-9), plain_r)
    return np.concatenate([rgb, a2], axis=-1)


def minify(rgba: np.ndarray, tw: int, th: int) -> tuple[np.ndarray, str]:
    """Reduce to (tw, th).  Exact halving chain when the ratio is 2^k in both
    axes (the plan's hard rule on crop rects), general area filter otherwise."""
    h, w = rgba.shape[:2]
    if (w, h) == (tw, th):
        return rgba.astype(np.float64), "1x (no reduction)"
    if tw > w or th > h:
        raise SystemExit(
            f"bake: target {tw}x{th} is larger than source {w}x{h}; this is a "
            f"reducer, not an upscaler (render.nim upscales at addSprite time)")
    px = rgba.astype(np.float64)
    kx, ky = ratio_pow2(w, tw), ratio_pow2(h, th)
    if kx is not None and kx == ky:
        for _ in range(kx):
            px = _halve(px)
        return px, f"{1 << kx}x exact box-halving chain (k={kx})"
    return _area_resize(px, tw, th), f"{w / tw:.4g}x area filter (non-2^k)"


def ratio_pow2(src: int, dst: int) -> int | None:
    """k where src/dst == 2^k, else None."""
    if dst <= 0 or src % dst != 0:
        return None
    q = src // dst
    if q < 1 or (q & (q - 1)) != 0:
        return None
    return q.bit_length() - 1


# --------------------------------------------------------------------------
# §3.4 step 7 — deterministic median cut in OKLab
# --------------------------------------------------------------------------

def median_cut(colors: np.ndarray, counts: np.ndarray, n: int) -> np.ndarray:
    """colors: (U,3) uint8 unique, sorted.  Returns (U,) index into 0..k-1
    cluster ids.  Deterministic: no RNG, fixed traversal, stable sorts."""
    u = colors.shape[0]
    if u == 0:
        return np.zeros((0,), dtype=np.int32)
    lab = rgb_to_oklab(colors.astype(np.float64))
    # OKLab a/b are ~10x smaller in range than L; scale so a chroma split is
    # competitive with a lightness split instead of never winning.
    lab_s = lab * np.array([1.0, 2.0, 2.0])
    boxes: list[np.ndarray] = [np.arange(u, dtype=np.int32)]
    unsplittable: set[int] = set()

    while len(boxes) < n:
        best_i, best_score = -1, -1.0
        for i, bx in enumerate(boxes):
            if i in unsplittable or bx.size < 2:
                continue
            sub = lab_s[bx]
            span = float((sub.max(axis=0) - sub.min(axis=0)).max())
            if span <= 0.0:
                unsplittable.add(i)
                continue
            score = span * float(counts[bx].sum())
            # Strict > keeps the earliest box on ties: deterministic.
            if score > best_score:
                best_score, best_i = score, i
        if best_i < 0:
            break

        bx = boxes[best_i]
        sub = lab_s[bx]
        spans = sub.max(axis=0) - sub.min(axis=0)
        split = None
        for axis in np.argsort(-spans, kind="stable"):
            order = np.argsort(sub[:, axis], kind="stable")
            ordered = bx[order]
            w = counts[ordered].astype(np.int64)
            cum = np.cumsum(w)
            half = cum[-1] / 2.0
            cut = int(np.searchsorted(cum, half, side="left")) + 1
            cut = max(1, min(cut, ordered.size - 1))
            # Do not split a run of identical values across the boundary.
            vals = sub[order, axis]
            while cut < ordered.size and vals[cut] == vals[cut - 1]:
                cut += 1
            if 0 < cut < ordered.size:
                split = (ordered[:cut], ordered[cut:])
                break
        if split is None:
            unsplittable.add(best_i)
            continue
        boxes[best_i] = split[0]
        boxes.append(split[1])

    cluster = np.zeros((u,), dtype=np.int32)
    for i, bx in enumerate(boxes):
        cluster[bx] = i
    return cluster


def quantize(rgba: np.ndarray, n_colors: int, pal: Palette | None,
             mode: str) -> np.ndarray:
    """Quantize opaque RGB to <= n_colors, snapping centroids to `pal`."""
    out = rgba.copy()
    h, w = out.shape[:2]
    flat_rgb = out[..., :3].reshape(-1, 3)
    flat_a = out[..., 3].reshape(-1)
    live = flat_a > 0
    if not live.any():
        return out

    if mode == "direct":
        if pal is None:
            raise SystemExit("bake: --quantize direct needs a fixed palette")
        flat_rgb[live] = snap_to_palette(flat_rgb[live], pal)
        out[..., :3] = flat_rgb.reshape(h, w, 3)
        return out

    keys = pack_keys(flat_rgb[live])
    uk, inv, cnt = np.unique(keys, return_inverse=True, return_counts=True)
    inv = inv.reshape(-1)               # numpy 2 returns the source shape
    uniq = unpack_keys(uk)

    cluster = median_cut(uniq, cnt, max(1, n_colors))
    k = int(cluster.max()) + 1 if cluster.size else 0
    lab = rgb_to_oklab(uniq.astype(np.float64))
    reps = np.zeros((k, 3), dtype=np.uint8)
    for i in range(k):
        m = cluster == i
        wgt = cnt[m].astype(np.float64)
        centroid_lab = (lab[m] * wgt[:, None]).sum(axis=0) / wgt.sum()
        reps[i] = np.clip(np.rint(oklab_to_rgb(centroid_lab)), 0, 255).astype(np.uint8)
    if pal is not None:
        reps = snap_to_palette(reps, pal)

    flat_rgb[live] = reps[cluster[inv]]
    out[..., :3] = flat_rgb.reshape(h, w, 3)
    return out


# --------------------------------------------------------------------------
# §3.4 step 6 / 8 — alpha discipline and the ink pass
# --------------------------------------------------------------------------

def alpha_discipline(rgba: np.ndarray, zero_below: int, binary: bool,
                     cut: int) -> np.ndarray:
    out = rgba.copy()
    a = out[..., 3]
    if binary:
        a = np.where(a >= cut, 255, 0).astype(np.uint8)
    a = np.where(a < zero_below, 0, a).astype(np.uint8)
    out[..., 3] = a
    dead = a == 0
    out[dead] = 0                       # bitwise zero, RGB included
    return out


def ink_pass(rgba: np.ndarray, color: tuple[int, int, int], alpha: int,
             outside: bool) -> np.ndarray:
    """Redraw the 1px StoneInk outline around the alpha mask, exactly as
    bodyPixels does today.  A model-drawn outline does not survive a 16x
    reduction; this one is drawn after it."""
    out = rgba.copy()
    solid = out[..., 3] >= 128
    if not solid.any():
        return out
    neigh = np.zeros_like(solid)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            neigh |= _shift(solid, dy, dx, False)
    if outside:
        # Grow by one: the ink ring sits in what was empty space.
        ring = (~solid) & neigh
    else:
        # Interior boundary: silhouette size is preserved exactly.
        allsolid = np.ones_like(solid)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                allsolid &= _shift(solid, dy, dx, False)
        ring = solid & (~allsolid)
    out[ring, 0], out[ring, 1], out[ring, 2] = color
    out[ring, 3] = np.uint8(alpha)
    return out


# --------------------------------------------------------------------------
# §3.4 step 9 / risk #2, #6 — lint
# --------------------------------------------------------------------------

@dataclass
class LintReport:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def lint(rgba: np.ndarray, pal: Palette | None, n_colors: int,
         zero_below: int, allow_green: bool, target: tuple[int, int]) -> LintReport:
    rep = LintReport()
    a = rgba[..., 3]

    # risk #2 — no alpha mass in 1..zero_below-1, transparent region bitwise 0.
    hist = np.bincount(a.reshape(-1), minlength=256)
    haze = int(hist[1:zero_below].sum())
    if haze:
        rep.errors.append(
            f"alpha haze: {haze} px with alpha in 1..{zero_below - 1} "
            f"(dimmed() would carry it into every fade stage)")
    dead = a == 0
    if dead.any() and rgba[dead][:, :3].any():
        rep.errors.append("transparent region is not bitwise zero (RGB != 0 under alpha 0)")

    live = a > 0
    if not live.any():
        rep.warnings.append("sprite is fully transparent")
        return rep

    cols = rgba[live][:, :3]
    uniq = np.unique(pack_keys(cols))
    if uniq.size > n_colors:
        rep.errors.append(f"{uniq.size} distinct colours > budget {n_colors}")

    # risk #6 — palette membership.
    if pal is not None:
        stray = np.setdiff1d(uniq, pack_keys(pal.colors))
        if stray.size:
            names = ", ".join(
                "#%06X" % int(s) for s in stray[:8])
            rep.errors.append(
                f"{stray.size} colour(s) outside palette {pal.name}: {names}"
                + (" ..." if stray.size > 8 else ""))

    # §3.1 law 3 — nothing green, anywhere.
    if not allow_green:
        urgb = unpack_keys(uniq)
        hue, sat, val = rgb_hue(urgb)
        bad = (hue >= GREEN_HUE_LO) & (hue <= GREEN_HUE_HI) & (sat > 0.12) & (val > 0.08)
        if bad.any():
            names = ", ".join("#" + rgb_to_hex(c) for c in urgb[bad][:8])
            rep.errors.append(f"{int(bad.sum())} green colour(s): {names}")

    # §1 hard rule.
    if min(target) < TIER_A_MIN_DIM:
        rep.warnings.append(
            f"target {target[0]}x{target[1]} has a dimension under {TIER_A_MIN_DIM}px "
            f"— below the Tier A floor; expect to hand-trace, not downsample")
    return rep


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

def ascii_preview_row(row: np.ndarray, max_w: int) -> str:
    """One line of ASCII for one sprite row.  '.' transparent, ',' partial,
    ':-=+*#%@' by luminance."""
    stride = max(1, math.ceil(row.shape[0] / max_w))
    out = []
    for x in range(0, row.shape[0], stride):
        px = row[x]
        a = int(px[3])
        if a == 0:
            out.append(PREVIEW_TRANSPARENT)
        elif a < 128:
            out.append(PREVIEW_PARTIAL)
        else:
            lum = (0.2126 * int(px[0]) + 0.7152 * int(px[1]) + 0.0722 * int(px[2])) / 255.0
            out.append(PREVIEW_RAMP[min(len(PREVIEW_RAMP) - 1,
                                        int(lum * len(PREVIEW_RAMP)))])
    return "".join(out)


def nim_header(name: str, w: int, h: int, meta: dict) -> list[str]:
    return [
        f"## GENERATED by tools/art/bake.py — do not edit by hand.",
        f"## Regenerate: uv run --project tools/art tools/art/bake.py \\",
        f"##   {meta['source_rel']} --name {name} --size {w}x{h}"
        + (f" --crop {meta['crop_str']}" if meta.get("crop_str") else "")
        + f" --palette {meta['palette']} --colors {meta['colors_budget']}",
        f"##",
        f"## source     {meta['source_rel']}  sha256:{meta['source_sha'][:16]}",
        f"## source px  {meta['source_w']}x{meta['source_h']}"
        + (f"  crop {meta['crop_str']}" if meta.get("crop_str") else ""),
        f"## reduction  {meta['reduction']}",
        f"## palette    {meta['palette']}  ({meta['colors_used']} of "
        f"{meta['colors_budget']} colours used)",
        f"## bytes      {w * h * 4} raw"
        + (f", {meta['blob_bytes']} snappy ({meta['blob_ratio']:.2f}:1)"
           if meta.get("blob_bytes") else ""),
        f"## Straight (unpremultiplied) RGBA, row-major, top-left origin — the"
        f" sprite_v1 wire layout.",
        f"## Register with native = true or addSprite upscales it by RS for free.",
        "",
    ]


def emit_array(name: str, rgba: np.ndarray, meta: dict, *, mask: bool,
               ctor: bool, preview_width: int) -> str:
    h, w = rgba.shape[:2]
    lines = nim_header(name, w, h, meta)
    lines.append(f"const {name}W* = {w}")
    lines.append(f"const {name}H* = {h}")
    lines.append("")
    lines.append(f"const {name}Px*: array[{w} * {h} * 4, uint8] = [")
    first = True
    for y in range(h):
        row = rgba[y]
        nums = []
        for x in range(w):
            for c in range(4):
                v = int(row[x][c])
                if first:
                    nums.append(f"{v}'u8")
                    first = False
                else:
                    nums.append(str(v))
        body = ",".join(nums)
        sep = "," if y < h - 1 else ""
        lines.append(f"  {body}{sep}   # {y:>3} |{ascii_preview_row(row, preview_width)}|")
    lines.append("]")

    if mask:
        lines.append("")
        lines.append(f"## 0/255 alpha mask — the silhouette camo glass, the glitch tear and")
        lines.append(f"## the hit flash are all derived from, so they cannot drift off the body.")
        lines.append(f"const {name}Mask*: array[{w} * {h}, uint8] = [")
        for y in range(h):
            vals = ["255" if int(v) >= 128 else "0" for v in rgba[y][:, 3]]
            if y == 0 and vals:
                vals[0] = vals[0] + "'u8"
            sep = "," if y < h - 1 else ""
            lines.append(f"  {','.join(vals)}{sep}   # {y:>3} "
                         f"|{ascii_preview_row(rgba[y], preview_width)}|")
        lines.append("]")

    if ctor:
        lines.append("")
        lines.append(f"let {name}* = BakedSprite(w: {name}W, h: {name}H, px: @{name}Px"
                     + (f", mask: @{name}Mask)" if mask else ")"))
    lines.append("")
    return "\n".join(lines)


def emit_blob(name: str, rgba: np.ndarray, meta: dict, blob_ref: str, *,
              ctor: bool) -> tuple[str, bytes]:
    try:
        import cramjam
    except ImportError:  # pragma: no cover - dependency is declared
        raise SystemExit(
            "bake: --emit blob needs cramjam (declared in tools/art/pyproject.toml); "
            "run via `uv run --project tools/art`")
    raw = rgba.tobytes(order="C")
    packed = bytes(cramjam.snappy.compress_raw(raw))
    assert bytes(cramjam.snappy.decompress_raw(packed)) == raw, "snappy round-trip failed"
    meta["blob_bytes"] = len(packed)
    meta["blob_ratio"] = len(raw) / max(1, len(packed))

    h, w = rgba.shape[:2]
    lines = nim_header(name, w, h, meta)
    lines += [
        f"## Blob, not a literal: {w}x{h}x4 = {w * h * 4} B raw would be ~{w * h * 4 * 4 // 1024}"
        f" KB of escaped Nim source (ART_UPGRADE_PLAN §4.2).",
        f"## supersnappy.uncompress reads this raw-block Snappy stream at module init.",
        "",
        f"const {name}W* = {w}",
        f"const {name}H* = {h}",
        f"const {name}Blob* = staticRead(\"{blob_ref}\")",
    ]
    if ctor:
        lines += [
            "",
            "## `cast[seq[uint8]](string)` happens to work under ORC because",
            "## NimStringV2 and NimSeqV2 share a payload layout — but it is a",
            "## cast, and this file feeds a bit-exact game.  Copy instead.",
            "when not declared(bakedBytes):",
            "  proc bakedBytes(s: string): seq[uint8] =",
            "    result = newSeq[uint8](s.len)",
            "    if s.len > 0:",
            "      copyMem(result[0].addr, s[0].unsafeAddr, s.len)",
            "",
            f"let {name}* = BakedSprite(w: {name}W, h: {name}H,",
            f"                          px: bakedBytes(uncompress({name}Blob)))",
        ]
    lines.append("")
    return "\n".join(lines), packed


def contact_sheet(rgba: np.ndarray, path: Path, scales=(1, 2, 4, 8)) -> None:
    """A scaled-up preview on the real substrate.  The acceptance question is
    'can I tell what it is at 1:1?' (risk #5), so 1x leads and the zooms follow."""
    h, w = rgba.shape[:2]
    gut, pad, swatch = 10, 12, 14
    strip_w = sum(w * s for s in scales) + gut * (len(scales) - 1)
    strip_h = max(h * s for s in scales)

    live = rgba[..., 3] > 0
    cols = rgba[live][:, :3] if live.any() else np.zeros((0, 3), np.uint8)
    used = unpack_keys(np.unique(pack_keys(cols))) if cols.size \
        else np.zeros((0, 3), np.uint8)

    sheet_w = max(strip_w, used.shape[0] * swatch) + pad * 2
    sheet_h = strip_h + pad * 3 + swatch
    sheet = Image.new("RGB", (sheet_w, sheet_h), BG_DARK)

    src = Image.fromarray(rgba, "RGBA")
    x = pad
    for s in scales:
        img = src.resize((w * s, h * s), Image.NEAREST)
        sheet.paste(img, (x, pad + (strip_h - h * s) // 2), img)
        x += w * s + gut
    for i, c in enumerate(used):
        sw = Image.new("RGB", (swatch - 2, swatch - 2), tuple(int(v) for v in c))
        sheet.paste(sw, (pad + i * swatch, pad * 2 + strip_h))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------

@dataclass
class BakeResult:
    rgba: np.ndarray
    nim: str
    meta: dict
    lint: LintReport
    blob: bytes | None = None


def bake(src_path: Path, name: str, target: tuple[int, int], args) -> BakeResult:
    tw, th = target
    raw_bytes = src_path.read_bytes()
    img = Image.open(src_path)
    img = img.convert("RGBA")
    sw, sh = img.size
    rgba = np.asarray(img, dtype=np.uint8).copy()

    crop_str = None
    if args.crop:
        cx, cy, cw, ch = (int(v) for v in args.crop.split(","))
        if cx < 0 or cy < 0 or cx + cw > sw or cy + ch > sh:
            raise SystemExit(f"bake: crop {args.crop} falls outside {sw}x{sh}")
        rgba = rgba[cy:cy + ch, cx:cx + cw]
        crop_str = f"{cx},{cy},{cw},{ch}"

    ch_, cw_ = rgba.shape[:2]
    kx, ky = ratio_pow2(cw_, tw), ratio_pow2(ch_, th)
    exact = kx is not None and kx == ky and kx >= 2
    if not exact and args.strict_ratio and (cw_, ch_) != (tw, th):
        raise SystemExit(
            f"bake: crop {cw_}x{ch_} -> target {tw}x{th} violates the crop-rect rule "
            f"(crop.w/target.w == crop.h/target.h == 2^k, k>=2). "
            f"Got {cw_ / tw:.4g}x by {ch_ / th:.4g}x. "
            f"Fix the rect in art/sheets.json, or pass --no-strict-ratio.")

    if args.chroma_key != "none":
        key = CHROMA_KEY if args.chroma_key == "green" else hex_to_rgb(args.chroma_key)
        rgba = chroma_key(rgba, key)
        if args.despill > 0:
            rgba = despill(rgba, args.despill)
    rgba = solidify(rgba)

    reduced, reduction = minify(rgba, tw, th)
    out = np.clip(np.rint(reduced), 0, 255).astype(np.uint8)

    out = alpha_discipline(out, args.alpha_zero, not args.soft_alpha, args.alpha_cut)

    pal = build_palette(args.palette, tuple(args.ramps.split(",")) if args.ramps else None)
    out = quantize(out, args.colors, pal, args.quantize)

    if args.ink != "none":
        ink_rgb = STONE_INK if args.ink == "stone" else hex_to_rgb(args.ink)
        out = ink_pass(out, ink_rgb, args.ink_alpha, args.ink_outside)
    # The ink pass writes alpha; re-assert the zero rule so it cannot smuggle
    # haze back in through a partially-alpha'd ring.
    out = alpha_discipline(out, args.alpha_zero, False, args.alpha_cut)

    rep = lint(out, pal, args.colors, args.alpha_zero, args.allow_green, (tw, th))

    live = out[..., 3] > 0
    used = int(np.unique(pack_keys(out[live][:, :3])).size) if live.any() else 0

    # Relative when the source is inside the tree (art/source/foo.png), absolute
    # when it is not — a header full of ../../.. is worse than useless, because
    # the "Regenerate:" line is meant to be copy-pasteable.
    try:
        rel = os.path.relpath(src_path, Path.cwd())
        source_rel = rel if not rel.startswith("..") else str(src_path.resolve())
    except ValueError:
        source_rel = str(src_path.resolve())
    meta = {
        "name": name, "w": tw, "h": th,
        "source_rel": source_rel.replace(os.sep, "/"),
        "source_sha": hashlib.sha256(raw_bytes).hexdigest(),
        "source_w": sw, "source_h": sh, "crop_str": crop_str,
        "reduction": reduction,
        "palette": pal.name if pal else "free",
        "colors_budget": args.colors, "colors_used": used,
        "raw_bytes": tw * th * 4,
        "alpha_mode": "soft" if args.soft_alpha else "binary",
    }

    def array_fragment() -> str:
        # The guard belongs to the literal, so it must apply to 'both' too.
        if tw * th * 4 > args.max_array_bytes:
            raise SystemExit(
                f"bake: {tw}x{th}x4 = {tw * th * 4} B exceeds --max-array-bytes "
                f"{args.max_array_bytes}. Escaped Nim literals of this size compile "
                f"miserably — use --emit blob (ART_UPGRADE_PLAN §4.2).")
        return emit_array(name, out, meta, mask=args.emit_mask,
                          ctor=args.emit_object, preview_width=args.preview_width)

    blob = None
    if args.emit in ("blob", "both"):
        blob_path = Path(args.blob_dir) / f"{args.blob_name or name.lower()}.snappy"
        if args.blob_ref:
            ref = args.blob_ref
        else:
            out_dir = Path(args.out).resolve().parent if args.out else Path.cwd()
            ref = os.path.relpath(blob_path.resolve(), out_dir).replace(os.sep, "/")
        # emit_blob fills in meta['blob_bytes'], which the array header prints,
        # so it must run first when emitting both.
        nim, blob = emit_blob(name, out, meta, ref, ctor=args.emit_object)
        if args.emit == "both":
            nim = array_fragment() + "\n" + nim
    else:
        nim = array_fragment()

    return BakeResult(rgba=out, nim=nim, meta=meta, lint=rep, blob=blob)


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

class _Args:
    """Defaults mirroring the CLI, so the self-test drives the real pipeline."""

    def __init__(self, **kw):
        self.crop = None
        self.chroma_key = "green"
        self.despill = 12
        self.strict_ratio = True
        self.alpha_zero = 24
        self.alpha_cut = 128
        self.soft_alpha = False
        self.palette = "afterglow"
        self.ramps = None
        self.colors = 16
        self.quantize = "mediancut"
        self.ink = "none"
        self.ink_alpha = 190
        self.ink_outside = False
        self.allow_green = False
        self.emit = "array"
        self.emit_mask = False
        self.emit_object = False
        self.preview_width = 128
        self.max_array_bytes = 262144
        self.blob_dir = "art/baked"
        self.blob_name = None
        self.blob_ref = None
        self.out = None
        for k, v in kw.items():
            setattr(self, k, v)


def _synthetic_carrier(w: int = 256, h: int = 384) -> Image.Image:
    """A 'nano banana' stand-in: a chamfered hull on a pure-green field, lit
    upper-left, with an amber->phosphor gradient and a green spill rim (which
    the despill step must remove)."""
    a = np.zeros((h, w, 4), dtype=np.uint8)
    a[..., :3] = CHROMA_KEY
    a[..., 3] = 255
    yy, xx = np.mgrid[0:h, 0:w]
    cx, cy = w / 2.0, h / 2.0
    # Superellipse hull: a real silhouette with chamfered shoulders.
    d = (np.abs(xx - cx) / (w * 0.34)) ** 3.0 + (np.abs(yy - cy) / (h * 0.42)) ** 2.2
    body = d <= 1.0
    t = np.clip((yy - h * 0.10) / (h * 0.80), 0.0, 1.0)
    key = np.clip(1.0 - ((xx - cx) / (w * 0.6)) - ((yy - cy) / (h * 1.4)), 0.15, 1.0)
    amber = np.array([255, 180, 84], dtype=np.float64)
    phos = np.array([165, 227, 238], dtype=np.float64)
    grad = (amber[None, None, :] * (1 - t)[..., None] + phos[None, None, :] * t[..., None])
    grad = grad * key[..., None]
    a[..., :3] = np.where(body[..., None], np.clip(grad, 0, 255).astype(np.uint8), a[..., :3])
    # Green spill: a 3px rim of key bleed, exactly what a real key leaves.
    rim = body & ~np.roll(np.roll(body, 3, 0), 3, 1)
    a[..., 1] = np.where(rim, np.minimum(255, a[..., 1].astype(np.int16) + 90), a[..., 1])
    # A dark visor band, so the reduction has a hard edge to lose.
    visor = body & (np.abs(yy - h * 0.32) < h * 0.05)
    a[visor, 0], a[visor, 1], a[visor, 2] = 28, 36, 43
    return Image.fromarray(a, "RGBA")


def _synthetic_bleed(w: int = 256, h: int = 256) -> Image.Image:
    """Opaque amber DISC whose transparent surround carries WHITE rgb under
    alpha 0 — the canonical straight-alpha bleed trap.

    A disc, not a square: a square aligned to the reduction grid has no
    partially-covered block, so a naive resize would score identically and the
    test would prove nothing.  Every block along a circular edge is fractional,
    which is exactly where straight-alpha averaging drags the dead background
    colour into the sprite."""
    a = np.zeros((h, w, 4), dtype=np.uint8)
    a[..., :3] = 255                     # white under full transparency
    a[..., 3] = 0
    yy, xx = np.mgrid[0:h, 0:w]
    disc = ((xx - w / 2.0 + 0.5) ** 2 + (yy - h / 2.0 + 0.5) ** 2) <= (w * 0.35) ** 2
    a[disc, 0], a[disc, 1], a[disc, 2], a[disc, 3] = 255, 180, 84, 255
    return Image.fromarray(a, "RGBA")


def _parse_nim_bytes(nim: str, name: str) -> np.ndarray:
    """Re-read the emitted Nim array so the round trip is actually verified,
    not assumed."""
    start = nim.index(f"const {name}Px*: array[")
    body = nim[nim.index("[", nim.index("= [", start) + 1):]
    body = body[:body.index("\n]")]
    vals: list[int] = []
    for line in body.splitlines():
        line = line.split("#", 1)[0].strip()
        for tok in line.split(","):
            tok = tok.strip().replace("'u8", "").replace("[", "")
            if tok:
                vals.append(int(tok))
    return np.array(vals, dtype=np.uint8)


def selftest() -> int:
    log = []

    def ok(msg):
        log.append(f"  ok   {msg}")

    tmp = Path(tempfile.mkdtemp(prefix="zs-bake-selftest-"))
    print(f"bake.py selftest  (scratch: {tmp})")

    # -- 1. OKLab round trip and perceptual snapping ------------------------
    print("\n[1] OKLab")
    probes = np.array([[0, 0, 0], [255, 255, 255], [255, 180, 84],
                       [165, 227, 238], [54, 68, 79], [16, 22, 28]], dtype=np.float64)
    back = oklab_to_rgb(rgb_to_oklab(probes))
    err = float(np.abs(back - probes).max())
    assert err < 0.6, f"OKLab round trip off by {err}"
    ok(f"srgb -> oklab -> srgb round trip within {err:.4f}/255")

    pal = build_palette("afterglow")
    assert pal is not None and pal.size == 25, f"afterglow palette is {pal.size} entries"
    ok(f"afterglow palette = {pal.size} entries (etch 8 + phosphor 8 + amber 8 + ink 1)")

    # A mid amber must land in the amber ramp.  In raw RGB, (180,120,50) is
    # 74 away from amber B8792E and 106 from etch 4E5E6B — but darker ambers
    # sit close enough to the greys that naive RGB flips on real sprite data,
    # which is why this snaps in OKLab.
    snapped = snap_to_palette(np.array([[180, 120, 50], [120, 160, 175], [30, 38, 46]]), pal)
    hexes = [rgb_to_hex(c) for c in snapped]
    assert hexes[0] in RAMPS["amber"], f"mid amber snapped to {hexes[0]}"
    assert hexes[1] in RAMPS["phosphor"], f"mid phosphor snapped to {hexes[1]}"
    assert hexes[2] in RAMPS["etch"] + RAMPS["ink"], f"dark slate snapped to {hexes[2]}"
    ok(f"perceptual snap: amber->{hexes[0]} phosphor->{hexes[1]} slate->{hexes[2]}")

    # -- 2. Premultiplied reduction (the load-bearing one) ------------------
    print("\n[2] premultiplied resampling (the bleed trap)")
    AMBER = np.array([255.0, 180.0, 84.0])

    # 2a. The arithmetic, isolated.  One opaque amber pixel and three
    # transparent white ones.  Premultiplied: a' = 255/4, c' = amber exactly,
    # because the white contributes weight zero.  Straight-alpha: c' is
    # three-quarters white.  This is the whole bug in four pixels, and it is
    # asserted on _halve directly so no later stage can mask it.
    blk = np.array([[[255., 180., 84., 255.], [255., 255., 255., 0.]],
                    [[255., 255., 255., 0.], [255., 255., 255., 0.]]])
    got = _halve(blk)[0, 0]
    naive = blk.reshape(-1, 4).mean(axis=0)
    assert abs(got[3] - 63.75) < 1e-9, f"alpha mean {got[3]}, want 63.75"
    assert np.abs(got[:3] - AMBER).max() < 1e-9, f"_halve rgb {got[:3]}, want {AMBER}"
    naive_err = float(np.abs(naive[:3] - AMBER).max())
    assert naive_err > 40.0, "fixture does not exercise the bleed"
    ok(f"_halve: rgb {got[:3].tolist()} a {got[3]} — exact; "
       f"straight-alpha mean would be {naive[:3].round(1).tolist()} "
       f"(off by {naive_err:.0f}/255)")

    # 2b. The general (non-2^k) path must agree with the exact chain.
    gen = _area_resize(blk, 1, 1)[0, 0]
    assert np.abs(gen - got).max() < 1e-6, f"area path {gen} != halving path {got}"
    ok("_area_resize agrees with the halving chain to 1e-6 on the same block")

    # 2c. End to end, on a disc whose every edge block is fractional.
    #
    # The naive baseline is written out by hand rather than borrowed from
    # Pillow: as of Pillow 12, Image.resize DOES premultiply RGBA internally,
    # so it is no longer a straight-alpha reference.  (That is also why
    # _area_resize feeds PIL one mode='F' plane at a time — single-channel
    # images carry no alpha, so PIL cannot premultiply data this file has
    # already premultiplied.)
    def naive_reduce(px: np.ndarray, k: int) -> np.ndarray:
        """What every 'just resize the RGBA' implementation does."""
        f = px.astype(np.float64)
        for _ in range(k):
            h, w, _c = f.shape
            f = f.reshape(h // 2, 2, w // 2, 2, 4).mean(axis=(1, 3))
        return f

    bleed_png = tmp / "bleed.png"
    _synthetic_bleed().save(bleed_png)
    res = bake(bleed_png, "Bleed", (32, 32),
               _Args(chroma_key="none", palette="free", colors=8, allow_green=True))
    live = res.rgba[..., 3] > 0
    assert live.any(), "bleed fixture produced no opaque pixels"
    # Per-pixel, not averaged: the bleed lives on the rim, and a mean over the
    # solid interior (which is ~85% of the disc) hides it almost completely.
    dev = np.abs(res.rgba[live][:, :3].astype(np.float64) - AMBER).max(axis=1)
    ours_bad, ours_err = int((dev > 1).sum()), float(dev.max())

    src_px = np.asarray(Image.open(bleed_png).convert("RGBA"), dtype=np.uint8)
    nv = naive_reduce(src_px, 3)
    n_live = nv[..., 3] >= 128
    n_dev = np.abs(nv[n_live][:, :3] - AMBER).max(axis=1)
    n_bad, n_err = int((n_dev > 1).sum()), float(n_dev.max())

    assert ours_bad == 0, f"{ours_bad} opaque px drifted off amber (max {ours_err:.1f})"
    assert n_bad > 20 and n_err > 40, \
        f"naive path only spoiled {n_bad} px by {n_err:.1f} — fixture is not discriminating"
    ok(f"end to end: {int(live.sum())} opaque px, ALL exactly {AMBER.tolist()}; "
       f"the same PNG through a straight-alpha reduction spoils {n_bad} rim px "
       f"by up to {n_err:.0f}/255")
    assert res.rgba[live][:, 2].max() <= 140, "white background bled into the sprite"
    ok("no white background reached the sprite (max blue channel "
       f"{int(res.rgba[live][:, 2].max())}, amber is 84)")

    # -- 3. Full bake, afterglow, 8x reduction ------------------------------
    print("\n[3] full bake: 256x384 -> 32x48, afterglow/16, ink pass")
    src = tmp / "carrier.png"
    _synthetic_carrier().save(src)
    a3 = _Args(ink="stone", emit_mask=True, emit_object=True,
               out=str(tmp / "art_carrier.nim"))
    r3 = bake(src, "CarrierS", (32, 48), a3)

    assert r3.rgba.shape == (48, 32, 4), f"shape {r3.rgba.shape}"
    assert r3.rgba.size == 32 * 48 * 4 == 6144
    ok(f"dimensions 32x48, {r3.rgba.size} bytes, reduction = {r3.meta['reduction']}")

    hist = np.bincount(r3.rgba[..., 3].reshape(-1), minlength=256)
    assert hist[1:24].sum() == 0, f"alpha haze in 1..23: {hist[1:24].sum()} px"
    dead = r3.rgba[..., 3] == 0
    assert dead.any(), "fixture produced no transparency at all"
    assert not r3.rgba[dead][:, :3].any(), "transparent region not bitwise zero"
    ok(f"alpha keying: {int(dead.sum())} px bitwise zero, no mass in 1..23, "
       f"levels present = {sorted(int(v) for v in np.unique(r3.rgba[..., 3]))}")

    live3 = r3.rgba[..., 3] > 0
    uniq = np.unique(pack_keys(r3.rgba[live3][:, :3]))
    pk = set(int(k) for k in pack_keys(pal.colors))
    stray = [k for k in uniq.tolist() if k not in pk]
    assert not stray, f"colours outside the afterglow ramps: {['#%06X' % s for s in stray]}"
    assert uniq.size <= 16, f"{uniq.size} colours > 16"
    ok(f"palette membership: all {uniq.size} colours in the afterglow ramps "
       f"({', '.join('#%06X' % k for k in uniq[:6])}{' ...' if uniq.size > 6 else ''})")

    hue, sat, val = rgb_hue(unpack_keys(uniq))
    green = (hue >= GREEN_HUE_LO) & (hue <= GREEN_HUE_HI) & (sat > 0.12) & (val > 0.08)
    assert not green.any(), "green survived the despill"
    ok(f"no green: hues span {hue.min():.0f}..{hue.max():.0f} deg, "
       f"none in [{GREEN_HUE_LO:.0f}, {GREEN_HUE_HI:.0f}]")

    assert r3.lint.ok, f"lint errors: {r3.lint.errors}"
    ok(f"lint clean ({len(r3.lint.warnings)} warning(s))")

    ink_hits = int(((r3.rgba[..., 0] == STONE_INK[0]) & (r3.rgba[..., 1] == STONE_INK[1])
                    & (r3.rgba[..., 2] == STONE_INK[2]) & (r3.rgba[..., 3] == 190)).sum())
    assert ink_hits > 20, f"ink pass drew only {ink_hits} px"
    ok(f"ink pass: {ink_hits} px of StoneInk @a190 on the silhouette boundary")

    # -- 4. Nim emission round trip ----------------------------------------
    print("\n[4] Nim emission")
    nim_path = Path(a3.out)
    nim_path.write_text(r3.nim, encoding="utf-8")
    text = nim_path.read_text(encoding="utf-8")
    assert "const CarrierSW* = 32" in text and "const CarrierSH* = 48" in text
    assert "const CarrierSPx*: array[32 * 48 * 4, uint8] = [" in text
    ok("declares CarrierSW/CarrierSH and array[32 * 48 * 4, uint8]")

    parsed = _parse_nim_bytes(text, "CarrierS")
    assert parsed.size == 6144, f"parsed {parsed.size} bytes, want 6144"
    assert np.array_equal(parsed, r3.rgba.reshape(-1)), "emitted bytes != baked pixels"
    ok("re-parsed the emitted array: 6144 bytes, byte-identical to the baked buffer")

    body_lines = [l for l in text.splitlines() if l.startswith("  ") and "# " in l]
    assert len(body_lines) >= 48, f"{len(body_lines)} data lines, want >= 48 (one per row)"
    prev_lines = [l.split("# ", 1)[1] for l in body_lines[:48]]
    assert all("|" in p for p in prev_lines), "row preview missing"
    assert any(set(p.split("|")[1]) - {PREVIEW_TRANSPARENT} for p in prev_lines), \
        "preview is entirely transparent"
    ok("one sprite row per line, each with an ASCII preview comment")
    assert "const CarrierSMask*: array[32 * 48, uint8] = [" in text
    assert "let CarrierS* = BakedSprite(w: CarrierSW, h: CarrierSH" in text
    ok("mask array and BakedSprite ctor emitted")
    assert "'u8" in text.split("= [", 1)[1][:64], "first element lacks a 'u8 type anchor"
    ok("first element carries the 'u8 anchor")

    # -- 4b. Does it actually compile? --------------------------------------
    # Text assertions prove the shape; only nim proves the shape is legal.
    # Skipped (not failed) where no compiler is on PATH.
    print("\n[4b] Nim compile")
    import shutil
    import subprocess
    if shutil.which("nim") is None:
        log.append("  SKIP nim not on PATH — emitted fragment not compile-checked")
        print("  (nim not found, skipping)")
    else:
        checksum = int(r3.rgba.astype(np.int64).sum())
        opaque = int((r3.rgba[..., 3] > 0).sum())
        drv = tmp / "check_array.nim"
        drv.write_text(
            f'include "{nim_path.stem}"\n'
            "proc main() =\n"
            "  doAssert CarrierSW == 32 and CarrierSH == 48\n"
            "  doAssert CarrierSPx.len == 32 * 48 * 4\n"
            "  doAssert CarrierSMask.len == 32 * 48\n"
            "  var sum = 0\n  var opaque = 0\n"
            "  for i in 0 ..< CarrierSW * CarrierSH:\n"
            "    if CarrierSPx[i * 4 + 3] > 0'u8: inc opaque\n"
            "    for c in 0 .. 3: sum += int(CarrierSPx[i * 4 + c])\n"
            f"  doAssert sum == {checksum}, $sum\n"
            f"  doAssert opaque == {opaque}, $opaque\n"
            "  echo \"nim ok sum=\", sum, \" opaque=\", opaque\n"
            "main()\n", encoding="utf-8")
        # BakedSprite ctor + mask are in the fragment, so give the driver the
        # type.  (game/art_baked.nim declares it once for all fragments.)
        r3_txt = nim_path.read_text(encoding="utf-8")
        nim_path.write_text(
            "type BakedSprite* = object\n  w*, h*: int\n"
            "  px*: seq[uint8]\n  mask*: seq[uint8]\n\n" + r3_txt, encoding="utf-8")
        p = subprocess.run(
            ["nim", "c", "-r", "--hints:off", "--warnings:off",
             "--nimcache:" + str(tmp / "nimcache"), "-o:" + str(tmp / "check_array"),
             str(drv)],
            capture_output=True, text=True, cwd=tmp)
        assert p.returncode == 0, \
            f"emitted Nim did not compile:\n{p.stdout[-2500:]}\n{p.stderr[-2500:]}"
        assert "nim ok" in p.stdout, p.stdout
        ok(f"nim compiled the emitted array and agreed: {p.stdout.strip().splitlines()[-1]}"
           f" (python checksum {checksum}, opaque {opaque})")
        nim_path.write_text(r3_txt, encoding="utf-8")

    # -- 5. Determinism -----------------------------------------------------
    print("\n[5] determinism (risk #11)")
    r5 = bake(src, "CarrierS", (32, 48), _Args(ink="stone", emit_mask=True,
                                               emit_object=True, out=a3.out))
    assert np.array_equal(r5.rgba, r3.rgba), "second bake differs in pixels"
    assert r5.nim == r3.nim, "second bake differs in emitted Nim"
    ok("two bakes of the same PNG are byte-identical (no RNG, no timestamps)")

    # -- 6. Alpha modes -----------------------------------------------------
    print("\n[6] alpha modes")
    r6b = bake(src, "Ab", (32, 48), _Args())
    lv = sorted(int(v) for v in np.unique(r6b.rgba[..., 3]))
    assert lv == [0, 255], f"binary mode produced alpha levels {lv}"
    ok(f"--alpha-mode binary (default): levels {lv}")
    r6s = bake(src, "As", (32, 48), _Args(soft_alpha=True))
    lvs = np.unique(r6s.rgba[..., 3])
    mid = [int(v) for v in lvs if 0 < int(v) < 255]
    assert mid, "soft mode kept no intermediate alpha"
    assert min(mid) >= 24, f"soft mode leaked alpha {min(mid)} below the zero floor"
    ok(f"--soft-alpha: {len(mid)} intermediate level(s), min {min(mid)} >= 24 floor")

    # -- 7. Crop-rect rule --------------------------------------------------
    print("\n[7] crop-rect rule (§3.3)")
    try:
        bake(src, "Bad", (30, 45), _Args())
        raise AssertionError("non-2^k reduction was accepted under --strict-ratio")
    except SystemExit as e:
        assert "crop-rect rule" in str(e), str(e)
    ok("256x384 -> 30x45 rejected: not an exact chain of box-halvings")
    r7 = bake(src, "Loose", (32, 48), _Args(strict_ratio=False))
    assert r7.rgba.shape == (48, 32, 4)
    ok("--no-strict-ratio falls back to the general area filter")

    # -- 8. Green lint bites ------------------------------------------------
    print("\n[8] green lint (§3.1 law 3)")
    green_png = tmp / "green.png"
    g = np.zeros((256, 256, 4), np.uint8)
    g[..., :3] = CHROMA_KEY
    g[..., 3] = 255
    g[64:192, 64:192] = (46, 108, 50, 255)      # the bush leaf green, Phase 2 kills it
    Image.fromarray(g, "RGBA").save(green_png)
    r8 = bake(green_png, "Leaf", (32, 32), _Args(palette="free", colors=4))
    assert any("green" in e for e in r8.lint.errors), \
        f"green lint did not fire: {r8.lint.errors}"
    ok(f"free-palette green flagged: {r8.lint.errors[0]}")
    r8b = bake(green_png, "Leaf", (32, 32), _Args(palette="afterglow", colors=4))
    assert r8b.lint.ok, f"afterglow snap left a violation: {r8b.lint.errors}"
    ok("the same image snapped to afterglow lints clean (green has nowhere to land)")

    # -- 9. Blob path -------------------------------------------------------
    print("\n[9] blob emission (§4.2)")
    r9 = bake(src, "FloorField", (32, 48),
              _Args(emit="blob", blob_dir=str(tmp / "baked"),
                    out=str(tmp / "game" / "art_baked.nim"), emit_object=True))
    assert r9.blob is not None
    blob_path = tmp / "baked" / "floorfield.snappy"
    blob_path.parent.mkdir(parents=True, exist_ok=True)
    blob_path.write_bytes(r9.blob)
    import cramjam
    assert bytes(cramjam.snappy.decompress_raw(blob_path.read_bytes())) \
        == r9.rgba.tobytes(order="C"), "snappy blob does not round trip"
    assert 'staticRead("' in r9.nim and "floorfield.snappy" in r9.nim
    assert "../baked/floorfield.snappy" in r9.nim, r9.nim
    ok(f"snappy blob {len(r9.blob)} B from {r9.rgba.size} B raw "
       f"({r9.meta['blob_ratio']:.2f}:1), staticRead path relative to the .nim")

    # The interop claim that matters: cramjam's raw-block Snappy must be
    # readable by Nim's supersnappy, or the whole blob path is fiction.
    ss = Path(__file__).resolve().parents[2] / "supersnappy" / "src"
    if shutil.which("nim") is None or not ss.exists():
        log.append("  SKIP supersnappy interop (no nim, or supersnappy/src missing)")
        print("  (skipping supersnappy interop)")
    else:
        nim9 = tmp / "game" / "art_baked.nim"
        nim9.parent.mkdir(parents=True, exist_ok=True)
        nim9.write_text(
            "import supersnappy\n"
            "type BakedSprite* = object\n  w*, h*: int\n  px*: seq[uint8]\n\n"
            + r9.nim, encoding="utf-8")
        chk9 = int(r9.rgba.astype(np.int64).sum())
        d9 = tmp / "game" / "check_blob.nim"
        d9.write_text(
            'include "art_baked"\n'
            "proc main() =\n"
            f"  doAssert FloorField.px.len == {r9.rgba.size}, $FloorField.px.len\n"
            "  var sum = 0\n"
            "  for b in FloorField.px: sum += int(b)\n"
            f"  doAssert sum == {chk9}, $sum\n"
            "  echo \"nim ok inflated=\", FloorField.px.len, \" sum=\", sum\n"
            "main()\n", encoding="utf-8")
        p9 = subprocess.run(
            ["nim", "c", "-r", "--hints:off", "--warnings:off", f"--path:{ss}",
             "--nimcache:" + str(tmp / "nimcache9"), "-o:" + str(tmp / "check_blob"),
             str(d9)], capture_output=True, text=True, cwd=tmp / "game")
        assert p9.returncode == 0, \
            f"blob fragment did not compile:\n{p9.stdout[-2500:]}\n{p9.stderr[-2500:]}"
        assert "nim ok" in p9.stdout, p9.stdout
        ok(f"supersnappy interop: {p9.stdout.strip().splitlines()[-1]} "
           f"— cramjam compress_raw is readable by Nim, checksum matches python")

    # -- 10. Array size guard, --emit both, @file palettes -------------------
    print("\n[10] guards, --emit both, @file palette")
    try:
        bake(src, "Huge", (32, 48), _Args(max_array_bytes=1024))
        raise AssertionError("oversize array was accepted")
    except SystemExit as e:
        assert "--emit blob" in str(e)
    ok("oversize literal refused with a pointer at --emit blob")
    try:
        bake(src, "Huge", (32, 48), _Args(emit="both", max_array_bytes=1024,
                                          blob_dir=str(tmp / "baked"),
                                          out=str(tmp / "both.nim")))
        raise AssertionError("--emit both bypassed the size guard")
    except SystemExit as e:
        assert "--emit blob" in str(e)
    ok("--emit both is covered by the same guard (it still emits a literal)")

    r10 = bake(src, "Both", (32, 48), _Args(emit="both", blob_dir=str(tmp / "baked"),
                                            out=str(tmp / "both.nim")))
    assert "const BothPx*: array[" in r10.nim and 'staticRead("' in r10.nim
    assert "snappy (" in r10.nim, "array header did not pick up the blob stats"
    ok("--emit both emits literal + blob, and the header reports both sizes")

    pal_file = tmp / "ramp.txt"
    pal_file.write_text("# a comment line\n#FFB454\n#A5E3EE   # trailing comment\n"
                        "10161C, 36444F\n", encoding="utf-8")
    pf = build_palette(f"@{pal_file}")
    assert pf is not None and pf.size == 4, \
        f"@file palette parsed {pf.size if pf else 0} entries, want 4"
    got_hex = sorted(rgb_to_hex(c) for c in pf.colors)
    assert got_hex == ["10161C", "36444F", "A5E3EE", "FFB454"], got_hex
    ok(f"@file palette: '#RRGGBB' read as colour, not comment ({', '.join(got_hex)})")

    # -- 11. Contact sheet --------------------------------------------------
    print("\n[11] contact sheet")
    sheet = tmp / "sheet.png"
    contact_sheet(r3.rgba, sheet)
    si = Image.open(sheet)
    assert si.size[0] > 32 * 15 and si.size[1] > 48 * 8, f"sheet {si.size} too small"
    ok(f"wrote {sheet.name} at {si.size[0]}x{si.size[1]} (1x/2x/4x/8x on BgDark "
       f"+ palette swatches)")

    print("\n" + "\n".join(log))
    print(f"\nALL {len(log)} ASSERTIONS PASSED")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def parse_size(s: str) -> tuple[int, int]:
    s = s.lower().replace("×", "x")
    if "x" in s:
        w, h = s.split("x", 1)
        return int(w), int(h)
    return int(s), int(s)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="bake.py",
        description="PNG -> quantized AFTERGLOW RGBA -> Nim const baker "
                    "(docs/ART_UPGRADE_PLAN.md §3.4, §4.2).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  bake.py art/source/carrier.png --name CarrierS --size 32x48 \\
      --crop 0,0,256,384 --out game/art_carrier.nim --ink stone --emit-mask
  bake.py art/source/floor.png --name FloorField --size 1152x1152 \\
      --emit blob --blob-dir art/baked --out game/art_floor.nim
  bake.py --selftest
""")
    p.add_argument("input", nargs="?", help="source PNG (a nano banana generation)")
    p.add_argument("--name", help="Nim symbol stem, e.g. CarrierS -> CarrierSPx")
    p.add_argument("--size", help="target WxH in emitted wire pixels, e.g. 32x48")
    p.add_argument("--out", help="output .nim path ('-' for stdout)")
    p.add_argument("--crop", help="X,Y,W,H rect into the source sheet (see art/sheets.json)")

    g = p.add_argument_group("key / despill")
    g.add_argument("--chroma-key", default="green",
                   help="'green' (#00FF00, the plan default), a hex colour, or 'none'")
    g.add_argument("--despill", type=int, default=12, metavar="N",
                   help="g = min(g, max(r,b) + N) on kept pixels (default 12; 0 disables)")

    g = p.add_argument_group("reduction")
    g.add_argument("--no-strict-ratio", dest="strict_ratio", action="store_false",
                   help="allow non-2^k reductions (default: refuse, §3.3)")
    p.set_defaults(strict_ratio=True)

    g = p.add_argument_group("alpha")
    g.add_argument("--alpha-zero", type=int, default=24, metavar="N",
                   help="alpha < N becomes bitwise RGBA(0,0,0,0) (default 24)")
    g.add_argument("--alpha-cut", type=int, default=128, metavar="N",
                   help="binarization threshold (default 128)")
    g.add_argument("--soft-alpha", action="store_true",
                   help="keep intermediate alpha instead of binarizing")

    g = p.add_argument_group("palette")
    g.add_argument("--palette", default="afterglow",
                   help="afterglow | afterglow-full | etch|phosphor|amber|ink|mono | "
                        "free | hex:AABBCC,... | @file")
    g.add_argument("--ramps", help="comma list restricting an afterglow palette, "
                                   "e.g. 'amber,ink' for a chip body")
    g.add_argument("--colors", type=int, default=16, metavar="N",
                   help="colour budget, hard-linted (default 16, §3.5)")
    g.add_argument("--quantize", choices=("mediancut", "direct"), default="mediancut",
                   help="mediancut: cut to N then snap centroids (default). "
                        "direct: snap every pixel, no cut")
    g.add_argument("--allow-green", action="store_true",
                   help="skip the green-hue lint (you almost certainly should not)")

    g = p.add_argument_group("ink pass")
    g.add_argument("--ink", default="none",
                   help="'stone' (#10161C), a hex colour, or 'none' (default)")
    g.add_argument("--ink-alpha", type=int, default=190, metavar="N")
    g.add_argument("--ink-outside", action="store_true",
                   help="draw the ring outside the silhouette (default: interior "
                        "boundary, which preserves silhouette size)")

    g = p.add_argument_group("emission")
    g.add_argument("--emit", choices=("array", "blob", "both"), default="array")
    g.add_argument("--emit-mask", action="store_true",
                   help="also emit <Name>Mask*: array[W*H, uint8] (0/255)")
    g.add_argument("--emit-object", action="store_true",
                   help="also emit a BakedSprite literal (needs the type in scope)")
    g.add_argument("--preview-width", type=int, default=128, metavar="N",
                   help="max chars of ASCII preview per row (default 128)")
    g.add_argument("--max-array-bytes", type=int, default=262144, metavar="N",
                   help="refuse to emit a literal larger than this (default 256 KiB)")
    g.add_argument("--blob-dir", default="art/baked")
    g.add_argument("--blob-name", help="blob stem (default: lowercased --name)")
    g.add_argument("--blob-ref", help="literal staticRead path (default: computed "
                                      "relative to --out)")

    g = p.add_argument_group("review / CI")
    g.add_argument("--contact-sheet", metavar="PATH",
                   help="also write a 1x/2x/4x/8x PNG preview on BgDark")
    g.add_argument("--report", metavar="PATH", help="write a JSON metadata report")
    g.add_argument("--lint-warn-only", action="store_true",
                   help="report lint failures without a non-zero exit")
    g.add_argument("--quiet", action="store_true")

    p.add_argument("--selftest", action="store_true",
                   help="bake synthetic fixtures and assert round-trip properties")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest()
    missing = [f for f, v in (("input", args.input), ("--name", args.name),
                              ("--size", args.size), ("--out", args.out)) if not v]
    if missing:
        raise SystemExit(f"bake: missing required {', '.join(missing)} "
                         f"(try --help, or --selftest)")

    src = Path(args.input)
    if not src.exists():
        raise SystemExit(f"bake: no such file {src}")
    target = parse_size(args.size)
    res = bake(src, args.name, target, args)

    if args.out == "-":
        sys.stdout.write(res.nim)
    else:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(res.nim, encoding="utf-8")
    if res.blob is not None:
        bp = Path(args.blob_dir) / f"{args.blob_name or args.name.lower()}.snappy"
        bp.parent.mkdir(parents=True, exist_ok=True)
        bp.write_bytes(res.blob)

    if args.contact_sheet:
        contact_sheet(res.rgba, Path(args.contact_sheet))
    if args.report:
        rp = Path(args.report)
        rp.parent.mkdir(parents=True, exist_ok=True)
        rp.write_text(json.dumps(
            {**res.meta,
             "lint_errors": res.lint.errors,
             "lint_warnings": res.lint.warnings}, indent=2), encoding="utf-8")

    if not args.quiet:
        m = res.meta
        print(f"{args.name}: {m['w']}x{m['h']}  {m['reduction']}  "
              f"{m['palette']}  {m['colors_used']}/{m['colors_budget']} colours  "
              f"{m['raw_bytes']} B raw"
              + (f"  {m['blob_bytes']} B snappy ({m['blob_ratio']:.2f}:1)"
                 if m.get("blob_bytes") else "")
              + f"  -> {args.out}", file=sys.stderr)
        for w in res.lint.warnings:
            print(f"  warn  {w}", file=sys.stderr)
        for e in res.lint.errors:
            print(f"  FAIL  {e}", file=sys.stderr)
    if not res.lint.ok and not args.lint_warn_only:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
