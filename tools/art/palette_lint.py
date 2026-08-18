#!/usr/bin/env python3
"""palette_lint.py — the AFTERGLOW CI gate (VISUAL_REDESIGN.md Appendix B item 1).

Two jobs, both mechanical, both reporting numbers instead of opinions:

1. **Token conformance.**  Given PNGs, a sprite-dump directory, or a `.nim`
   source/baked file, assert every colour is in the AFTERGLOW token set — or
   within a *stated* CIEDE2000 tolerance of it — and report every violation
   with its pixel coordinates (or file:line, for `.nim`).  Also enforces
   §3.1 law 3 (nothing green, anywhere) and the alpha discipline of
   ART_UPGRADE_PLAN §3.4 step 6 / risk #2.

2. **The CVD gate.**  Simulates deuteranopia / protanopia / tritanopia over the
   team wheel, the HP semaphore and the magenta/klaxon pairing, and reports the
   *minimum pairwise perceptual distance* in each case.  Appendix B item 1 asks
   for a "CVD simulator pass"; this is what makes that measurable rather than
   asserted.

The palette tables are imported from `bake.py`, deliberately: the gate and the
baker must never drift apart.  Colour maths here is CIEDE2000 in CIELAB (D65);
`--metric oklab` reuses bake.py's OKLab transform for cross-checking against the
baker's own snapping metric.

CVD simulation is Viénot, Brettel & Mollon (1999): sRGB -> linear -> LMS
(Smith-Pokorny), project onto the dichromat plane, back to sRGB.  That paper
validates the single-plane reduction for protanopia and deuteranopia only and
explicitly warns against applying it to tritanopia (the two tritan half-planes
are not coplanar).  So tritanopia is *reported* — you asked for the number —
but is ADVISORY and excluded from the pass/fail gate unless you opt in with
`--cvd-gate protanopia,deuteranopia,tritanopia`.  Reporting a number the method
does not support as a hard gate would be worse than not reporting it.

Usage
-----
    # gate the baked art (exact token membership)
    uv run --project tools/art tools/art/palette_lint.py art/baked game/art_baked.nim

    # audit what render.nim actually puts on the wire today
    uv run --project tools/art tools/art/palette_lint.py \\
        docs/evidence/sprites --profile shipped

    # scan Nim source for off-token colour literals (the Phase 2 worklist)
    uv run --project tools/art tools/art/palette_lint.py game/render.nim \\
        --profile shipped

    # just the CVD numbers
    uv run --project tools/art tools/art/palette_lint.py --cvd-only

Exit codes: 0 clean, 1 violations (over --budget), 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image

try:
    from bake import (  # one palette table in the repo, not two
        RAMPS,
        GREEN_HUE_LO,
        GREEN_HUE_HI,
        hex_to_rgb,
        rgb_to_hex,
        pack_keys,
        unpack_keys,
        rgb_hue,
        rgb_to_oklab,
    )
except ImportError as exc:  # pragma: no cover - only if bake.py is moved
    sys.exit(f"palette_lint: cannot import tools/art/bake.py ({exc}); "
             "run me from the repo with `uv run --project tools/art`")

# Families bake.py does not carry because generated art may never use them.
# BgDark is render.nim:161 (the deliberately lifted substrate); Faraday is the
# bible's Appendix A substrate token.
EXTRA_RAMPS: dict[str, tuple[str, ...]] = {
    "substrate": ("283039",),   # render.nim BgDark = (40,48,57)
    "faraday": ("0C1116",),     # VISUAL_REDESIGN Appendix A
}
ALL_RAMPS: dict[str, tuple[str, ...]] = {**RAMPS, **EXTRA_RAMPS}

# The team wheel, in bible order (A..H).
TEAM_WHEEL = [
    ("A rose", "FF8FA8"), ("B cyan", "49C7E8"), ("C gold", "E8C558"),
    ("D violet", "9B7BFF"), ("E wine", "E85D75"), ("F steel", "9FB8D8"),
    ("G copper", "E8975D"), ("H orchid", "D97BE8"),
]
SEMAPHORE = [("healthy phosphor", "A5E3EE"), ("hurt amber", "FFB454"),
             ("critical klaxon", "FF4A36")]
DIRECTIVE_PAIR = [("directive magenta", "FF4FA3"), ("klaxon red", "FF4A36")]

PROFILES = {
    # What the baker must emit.  Exact membership: a snapped pixel IS a token.
    "generated": dict(families=("etch", "phosphor", "amber", "ink", "mono"),
                      tolerance=0.0, mode="stops"),
    # Audit profile for art the renderer computes with shade()/dimmed(), which
    # slides along a ramp rather than landing on its stops.
    "shipped": dict(families=("etch", "phosphor", "amber", "ink", "mono",
                              "semantic", "team", "substrate", "faraday"),
                    tolerance=6.0, mode="ramp"),
}

EXIT_OK, EXIT_FAIL, EXIT_USAGE = 0, 1, 2

# ---------------------------------------------------------------------------
# colour science
# ---------------------------------------------------------------------------

_D65 = np.array([0.95047, 1.00000, 1.08883])
_RGB2XYZ = np.array([
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
])


def _srgb_to_linear(c: np.ndarray) -> np.ndarray:
    c = np.asarray(c, dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(np.asarray(c, dtype=np.float64), 0.0, 1.0)
    out = np.where(c <= 0.0031308, c * 12.92,
                   1.055 * np.power(c, 1.0 / 2.4) - 0.055)
    return np.clip(out * 255.0, 0.0, 255.0)


def rgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    """(...,3) sRGB 0..255 -> (...,3) CIELAB, D65."""
    lin = _srgb_to_linear(rgb)
    xyz = lin @ _RGB2XYZ.T / _D65
    eps, kappa = 216.0 / 24389.0, 24389.0 / 27.0
    f = np.where(xyz > eps, np.cbrt(xyz), (kappa * xyz + 16.0) / 116.0)
    return np.stack([116.0 * f[..., 1] - 16.0,
                     500.0 * (f[..., 0] - f[..., 1]),
                     200.0 * (f[..., 1] - f[..., 2])], axis=-1)


def ciede2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    """CIEDE2000 between broadcastable (...,3) CIELAB arrays."""
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cbar = (C1 + C2) / 2.0
    Cbar7 = Cbar ** 7
    G = 0.5 * (1.0 - np.sqrt(Cbar7 / (Cbar7 + 25.0 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360.0
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360.0
    dLp = L2 - L1
    dCp = C2p - C1p
    zero = (C1p * C2p) == 0
    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, dhp)
    dhp = np.where(dhp < -180, dhp + 360, dhp)
    dhp = np.where(zero, 0.0, dhp)
    dHp = 2.0 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2.0)
    Lbp = (L1 + L2) / 2.0
    Cbp = (C1p + C2p) / 2.0
    hsum, hdiff = h1p + h2p, np.abs(h1p - h2p)
    hbp = np.where(zero, hsum,
                   np.where(hdiff <= 180, hsum / 2.0,
                            np.where(hsum < 360, (hsum + 360) / 2.0,
                                     (hsum - 360) / 2.0)))
    T = (1.0
         - 0.17 * np.cos(np.radians(hbp - 30.0))
         + 0.24 * np.cos(np.radians(2.0 * hbp))
         + 0.32 * np.cos(np.radians(3.0 * hbp + 6.0))
         - 0.20 * np.cos(np.radians(4.0 * hbp - 63.0)))
    dTheta = 30.0 * np.exp(-(((hbp - 275.0) / 25.0) ** 2))
    Cbp7 = Cbp ** 7
    Rc = 2.0 * np.sqrt(Cbp7 / (Cbp7 + 25.0 ** 7))
    Sl = 1.0 + (0.015 * (Lbp - 50.0) ** 2) / np.sqrt(20.0 + (Lbp - 50.0) ** 2)
    Sc = 1.0 + 0.045 * Cbp
    Sh = 1.0 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2.0 * dTheta)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                   + Rt * (dCp / Sc) * (dHp / Sh))


def oklab_de(rgb1: np.ndarray, rgb2: np.ndarray) -> np.ndarray:
    """Euclidean OKLab distance, scaled x100 so it reads on a CIEDE2000-ish
    scale.  Provided for cross-checking bake.py's snapping metric."""
    d = rgb_to_oklab(rgb1) - rgb_to_oklab(rgb2)
    return np.sqrt((d ** 2).sum(axis=-1)) * 100.0


# --- CVD (Viénot, Brettel & Mollon 1999) -----------------------------------

_RGB2LMS = np.array([
    [17.8824000, 43.5161000, 4.11935000],
    [3.45565000, 27.1554000, 3.86714000],
    [0.02996560, 0.18430900, 1.46709000],
])
_LMS2RGB = np.linalg.inv(_RGB2LMS)
_CVD_LMS = {
    "protanopia": np.array([[0.0, 2.02344, -2.52581],
                            [0.0, 1.0, 0.0],
                            [0.0, 0.0, 1.0]]),
    "deuteranopia": np.array([[1.0, 0.0, 0.0],
                              [0.494207, 0.0, 1.24827],
                              [0.0, 0.0, 1.0]]),
    "tritanopia": np.array([[1.0, 0.0, 0.0],
                            [0.0, 1.0, 0.0],
                            [-0.395913, 0.801109, 0.0]]),
}


def simulate_cvd(rgb: np.ndarray, kind: str) -> np.ndarray:
    """(...,3) sRGB 0..255 -> simulated (...,3) sRGB 0..255."""
    if kind == "normal":
        return np.asarray(rgb, dtype=np.float64)
    lin = _srgb_to_linear(rgb)
    lms = lin @ _RGB2LMS.T
    sim = lms @ _CVD_LMS[kind].T
    return _linear_to_srgb(sim @ _LMS2RGB.T)


# ---------------------------------------------------------------------------
# legal-colour set
# ---------------------------------------------------------------------------

@dataclass
class LegalSet:
    rgb: np.ndarray            # (N,3) float
    lab: np.ndarray            # (N,3)
    labels: list[str]
    families: tuple[str, ...]
    mode: str
    steps: int

    def describe(self) -> str:
        return (f"{len(self.labels)} legal points "
                f"({self.mode}, families {'+'.join(self.families)}"
                + (f", segments sampled at 1/{self.steps}"
                   if self.mode == "ramp" else "") + ")")


def build_legal_set(families: tuple[str, ...], mode: str,
                    steps: int = 16) -> LegalSet:
    pts: list[tuple[float, float, float]] = []
    labels: list[str] = []
    for fam in families:
        if fam not in ALL_RAMPS:
            raise SystemExit(f"palette_lint: unknown token family {fam!r} "
                             f"(have {', '.join(ALL_RAMPS)})")
        stops = [hex_to_rgb(h) for h in ALL_RAMPS[fam]]
        for i, c in enumerate(stops):
            pts.append(tuple(float(v) for v in c))
            labels.append(f"{fam}[{i}] #{ALL_RAMPS[fam][i]}")
        if mode == "ramp":
            # The bible writes "legal ramp #1C242B -> #4E5E6B": the ramp is a
            # continuum, and shade()/dimmed() slide along it.  Sample each
            # segment so an interpolated tone is legal without widening the
            # tolerance for genuinely stray hues.
            for i in range(len(stops) - 1):
                a = np.array(stops[i], dtype=np.float64)
                b = np.array(stops[i + 1], dtype=np.float64)
                for k in range(1, steps):
                    t = k / steps
                    pts.append(tuple(a + (b - a) * t))
                    labels.append(f"{fam}[{i}->{i+1}] t={t:.2f}")
    rgb = np.array(pts, dtype=np.float64)
    return LegalSet(rgb=rgb, lab=rgb_to_lab(rgb), labels=labels,
                    families=families, mode=mode, steps=steps)


# ---------------------------------------------------------------------------
# findings
# ---------------------------------------------------------------------------

@dataclass
class ColourFinding:
    hexcode: str
    count: int
    distance: float
    nearest: str
    coords: list[tuple[int, int]] = field(default_factory=list)
    hue: float = 0.0
    sat: float = 0.0
    val: float = 0.0


@dataclass
class TargetReport:
    name: str
    kind: str                    # "image" | "nim"
    detail: str = ""
    pixels: int = 0
    considered: int = 0
    off_token_px: int = 0
    off_token: list[ColourFinding] = field(default_factory=list)
    green_px: int = 0
    green: list[ColourFinding] = field(default_factory=list)
    alpha_haze_px: int = 0
    dirty_transparent_px: int = 0
    distinct_colours: int = 0
    notes: list[str] = field(default_factory=list)

    @property
    def violations(self) -> int:
        return (self.off_token_px + self.green_px + self.alpha_haze_px
                + self.dirty_transparent_px)

    @property
    def ok(self) -> bool:
        return self.violations == 0


# ---------------------------------------------------------------------------
# image linting
# ---------------------------------------------------------------------------

def _distances(colours: np.ndarray, legal: LegalSet, metric: str
               ) -> tuple[np.ndarray, np.ndarray]:
    """(N,3) uint8 colours -> (min distance, index of nearest legal point)."""
    if metric == "oklab":
        d = oklab_de(colours[:, None, :].astype(np.float64),
                     legal.rgb[None, :, :])
    else:
        lab = rgb_to_lab(colours.astype(np.float64))
        d = ciede2000(lab[:, None, :], legal.lab[None, :, :])
    return d.min(axis=1), d.argmin(axis=1)


def lint_image(path: Path, legal: LegalSet, args, label: str = "") -> TargetReport:
    img = Image.open(path)
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    px = np.asarray(img, dtype=np.uint8)
    h, w = px.shape[:2]
    rep = TargetReport(name=str(path), kind="image",
                       detail=f"{label + ' ' if label else ''}{w}x{h}")
    rep.pixels = h * w
    alpha = px[..., 3]

    # ART_UPGRADE_PLAN §3.4 step 6 / risk #2 -- alpha discipline.
    hist = np.bincount(alpha.reshape(-1), minlength=256)
    rep.alpha_haze_px = int(hist[1:args.alpha_min].sum())
    dead = alpha == 0
    if dead.any():
        rep.dirty_transparent_px = int((px[dead][:, :3] != 0).any(axis=1).sum())

    live = alpha >= args.alpha_min
    rep.considered = int(live.sum())
    if rep.considered == 0:
        rep.notes.append("no pixels at or above the alpha floor")
        return rep

    cols = px[live][:, :3]
    keys = pack_keys(cols)
    uniq_keys, counts = np.unique(keys, return_counts=True)
    uniq = unpack_keys(uniq_keys).astype(np.uint8)
    rep.distinct_colours = int(uniq_keys.size)

    dmin, nearest = _distances(uniq, legal, args.metric)
    bad = dmin > args.tolerance + 1e-9

    hue, sat, val = rgb_hue(uniq)
    green = ((hue >= args.green_lo) & (hue <= args.green_hi)
             & (sat > args.green_sat) & (val > args.green_val))

    full_keys = pack_keys(px[..., :3])

    def coords_for(key: int) -> list[tuple[int, int]]:
        if args.max_coords <= 0:
            return []
        ys, xs = np.nonzero((full_keys == key) & live)
        return [(int(x), int(y)) for x, y in zip(xs[:args.max_coords],
                                                 ys[:args.max_coords])]

    rep.off_token_px = int(counts[bad].sum())
    order = np.argsort(-counts * bad)
    for i in order[:args.max_report]:
        if not bad[i]:
            break
        rep.off_token.append(ColourFinding(
            hexcode="#" + rgb_to_hex(uniq[i]), count=int(counts[i]),
            distance=float(dmin[i]), nearest=legal.labels[int(nearest[i])],
            coords=coords_for(int(uniq_keys[i]))))

    rep.green_px = int(counts[green].sum())
    order = np.argsort(-counts * green)
    for i in order[:args.max_report]:
        if not green[i]:
            break
        rep.green.append(ColourFinding(
            hexcode="#" + rgb_to_hex(uniq[i]), count=int(counts[i]),
            distance=float(dmin[i]), nearest=legal.labels[int(nearest[i])],
            coords=coords_for(int(uniq_keys[i])),
            hue=float(hue[i]), sat=float(sat[i]), val=float(val[i])))
    return rep


# ---------------------------------------------------------------------------
# .nim linting (source or baked)
# ---------------------------------------------------------------------------

_NUM = r"(\d{1,3})\s*(?:'u8|'i8|\.uint8|u8)?"
_TUPLE_RE = re.compile(r"\(\s*" + _NUM + r"\s*,\s*" + _NUM + r"\s*,\s*" + _NUM
                       + r"\s*\)")
_RGBA_RE = re.compile(r"\brgba?\(\s*" + _NUM + r"\s*,\s*" + _NUM + r"\s*,\s*"
                      + _NUM + r"\s*(?:,\s*\d{1,3}\s*)?\)")
_HEX_RE = re.compile(r"#([0-9A-Fa-f]{6})\b")


def lint_nim(path: Path, legal: LegalSet, args) -> TargetReport:
    text = path.read_text(encoding="utf-8", errors="replace")
    rep = TargetReport(name=str(path), kind="nim")
    hits: list[tuple[int, str, tuple[int, int, int]]] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        seen: set[tuple[int, int, int]] = set()
        for rx in (_TUPLE_RE, _RGBA_RE):
            for m in rx.finditer(line):
                vals = tuple(int(g) for g in m.groups())
                if any(v > 255 for v in vals):
                    continue
                if vals in seen:
                    continue
                seen.add(vals)
                hits.append((lineno, line.strip(), vals))
        for m in _HEX_RE.finditer(line):
            vals = hex_to_rgb(m.group(1))
            if vals in seen:
                continue
            seen.add(vals)
            hits.append((lineno, line.strip(), vals))
    rep.detail = f"{len(hits)} colour literal(s) scanned"
    rep.notes.append("heuristic literal scan: 3-number tuples, rgb(a) calls "
                     "and #RRGGBB; 4-argument colour calls are not matched")
    if not hits:
        return rep
    cols = np.array([h[2] for h in hits], dtype=np.uint8)
    rep.pixels = rep.considered = len(hits)
    keys = pack_keys(cols)
    uniq_keys, counts = np.unique(keys, return_counts=True)
    uniq = unpack_keys(uniq_keys).astype(np.uint8)
    rep.distinct_colours = int(uniq_keys.size)
    dmin, nearest = _distances(uniq, legal, args.metric)
    bad = dmin > args.tolerance + 1e-9
    hue, sat, val = rgb_hue(uniq)
    green = ((hue >= args.green_lo) & (hue <= args.green_hi)
             & (sat > args.green_sat) & (val > args.green_val))

    lines_for: dict[int, list[int]] = {}
    for lineno, _src, vals in hits:
        lines_for.setdefault(int(pack_keys(np.array(vals))), []).append(lineno)

    rep.off_token_px = int(counts[bad].sum())
    order = np.argsort(-counts * bad)
    for i in order[:args.max_report]:
        if not bad[i]:
            break
        key = int(uniq_keys[i])
        rep.off_token.append(ColourFinding(
            hexcode="#" + rgb_to_hex(uniq[i]), count=int(counts[i]),
            distance=float(dmin[i]), nearest=legal.labels[int(nearest[i])],
            coords=[(ln, 0) for ln in lines_for.get(key, [])[:args.max_coords]]))
    rep.green_px = int(counts[green].sum())
    order = np.argsort(-counts * green)
    for i in order[:args.max_report]:
        if not green[i]:
            break
        key = int(uniq_keys[i])
        rep.green.append(ColourFinding(
            hexcode="#" + rgb_to_hex(uniq[i]), count=int(counts[i]),
            distance=float(dmin[i]), nearest=legal.labels[int(nearest[i])],
            coords=[(ln, 0) for ln in lines_for.get(key, [])[:args.max_coords]],
            hue=float(hue[i]), sat=float(sat[i]), val=float(val[i])))
    return rep


# ---------------------------------------------------------------------------
# CVD report
# ---------------------------------------------------------------------------

CVD_KINDS = ("normal", "protanopia", "deuteranopia", "tritanopia")
CVD_GATE_DEFAULT = ("protanopia", "deuteranopia")


def cvd_report(sets: dict[str, list[tuple[str, str]]], cvd_min: float,
               gated: tuple[str, ...]) -> dict:
    out: dict = {"threshold": cvd_min, "method": "Vienot-Brettel-Mollon 1999",
                 "metric": "CIEDE2000", "gated": list(gated), "sets": {}}
    for set_name, entries in sets.items():
        names = [e[0] for e in entries]
        rgb = np.array([hex_to_rgb(e[1]) for e in entries], dtype=np.float64)
        per: dict = {}
        for kind in CVD_KINDS:
            sim = simulate_cvd(rgb, kind)
            lab = rgb_to_lab(sim)
            d = ciede2000(lab[:, None, :], lab[None, :, :])
            iu = np.triu_indices(len(entries), k=1)
            vals = d[iu]
            order = np.argsort(vals)
            pairs = [{
                "a": names[iu[0][j]], "b": names[iu[1][j]],
                "aHex": "#" + rgb_to_hex(np.rint(sim[iu[0][j]])),
                "bHex": "#" + rgb_to_hex(np.rint(sim[iu[1][j]])),
                "deltaE": round(float(vals[j]), 2),
            } for j in order[:3]]
            per[kind] = {
                "minDeltaE": round(float(vals.min()), 2),
                "medianDeltaE": round(float(np.median(vals)), 2),
                "pass": bool(vals.min() >= cvd_min),
                "gated": kind in gated,
                "worstPairs": pairs,
            }
        out["sets"][set_name] = {"colours": len(entries), "byVision": per}
    return out


def print_cvd(rep: dict) -> bool:
    ok = True
    gated = set(rep["gated"])
    print(f"\nCVD gate — {rep['method']}, {rep['metric']}, "
          f"threshold min pairwise dE00 >= {rep['threshold']:.1f}")
    print(f"  gated: {', '.join(rep['gated'])}   "
          f"advisory: {', '.join(k for k in CVD_KINDS if k not in gated)}")
    print("  (Vienot 1999 validates the single-plane reduction for protan and "
          "deutan only; its\n   tritan numbers are reported but must not be a "
          "hard gate — see --cvd-gate)")
    for set_name, s in rep["sets"].items():
        print(f"\n  {set_name} ({s['colours']} colours)")
        for kind, v in s["byVision"].items():
            if kind not in gated:
                flag = "pass" if v["pass"] else "warn"
                flag += " (advisory)"
            else:
                flag = "PASS" if v["pass"] else "FAIL"
                if not v["pass"]:
                    ok = False
            worst = v["worstPairs"][0]
            print(f"    {kind:<13} min dE00 {v['minDeltaE']:>6.2f}  "
                  f"median {v['medianDeltaE']:>6.2f}  {flag:<16} "
                  f"worst: {worst['a']} vs {worst['b']} "
                  f"({worst['aHex']} vs {worst['bHex']})")
        for p in s["byVision"]["deuteranopia"]["worstPairs"][1:]:
            print(f"      next-worst (deuteranopia): {p['a']} vs {p['b']} "
                  f"dE00 {p['deltaE']:.2f}")
    return ok


# ---------------------------------------------------------------------------
# target discovery
# ---------------------------------------------------------------------------

def collect_targets(paths: list[str]) -> list[tuple[Path, str]]:
    """-> [(path, label)] where label comes from sprites.json when present."""
    out: list[tuple[Path, str]] = []
    for raw in paths:
        p = Path(raw)
        if not p.exists():
            raise SystemExit(f"palette_lint: no such path: {p}")
        if p.is_file():
            out.append((p, ""))
            continue
        manifest = p / "sprites.json"
        if manifest.is_file():
            # A dump directory also holds the assembled contact sheets, which
            # are chrome, not art. Lint exactly what the manifest declares.
            data = json.loads(manifest.read_text())
            for s in data.get("sprites", []):
                for v in s.get("variants", []):
                    out.append((p / v["file"],
                                f"id={s['id']} '{s['label']}'"))
            continue
        for f in sorted(p.rglob("*.png")):
            out.append((f, ""))
        for f in sorted(p.rglob("*.nim")):
            out.append((f, ""))
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="palette_lint.py",
        description="AFTERGLOW palette + CVD gate (VISUAL_REDESIGN Appendix B item 1)",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("targets", nargs="*",
                   help="PNG files, .nim files, or directories (a directory "
                        "with sprites.json is a tools/art/dump_sprites dump)")
    p.add_argument("--profile", choices=sorted(PROFILES), default="generated",
                   help="generated = what the baker must emit (exact tokens); "
                        "shipped = audit of art the renderer computes "
                        "(default: generated)")
    p.add_argument("--families", default=None,
                   help="comma-separated token families to allow, overriding "
                        "the profile (" + ",".join(ALL_RAMPS) + ")")
    p.add_argument("--tolerance", type=float, default=None,
                   help="max perceptual distance to a legal colour "
                        "(profile default)")
    p.add_argument("--mode", choices=("stops", "ramp"), default=None,
                   help="stops = only the 8 declared ramp entries; ramp = the "
                        "ramp read as a continuum (profile default)")
    p.add_argument("--metric", choices=("ciede2000", "oklab"),
                   default="ciede2000",
                   help="perceptual metric (default ciede2000; oklab reuses "
                        "bake.py's transform, scaled x100)")
    p.add_argument("--ramp-steps", type=int, default=16,
                   help="subdivisions per ramp segment in ramp mode (default 16)")
    p.add_argument("--alpha-min", type=int, default=24,
                   help="pixels below this alpha are ignored, and any mass in "
                        "1..alpha_min-1 is reported as haze (default 24, "
                        "ART_UPGRADE_PLAN §3.4 step 6)")
    p.add_argument("--green-lo", type=float, default=GREEN_HUE_LO)
    p.add_argument("--green-hi", type=float, default=GREEN_HUE_HI)
    p.add_argument("--green-sat", type=float, default=0.12)
    p.add_argument("--green-val", type=float, default=0.08)
    p.add_argument("--max-report", type=int, default=8,
                   help="distinct offending colours listed per target (default 8)")
    p.add_argument("--max-coords", type=int, default=4,
                   help="coordinates listed per offending colour (default 4)")
    p.add_argument("--budget", type=int, default=0,
                   help="violating pixels tolerated before exit 1 (default 0)")
    p.add_argument("--top", type=int, default=15,
                   help="worst targets listed in the summary (default 15)")
    p.add_argument("--cvd-min", type=float, default=10.0,
                   help="minimum pairwise dE00 the team wheel must hold under "
                        "each CVD simulation (default 10.0)")
    p.add_argument("--cvd-gate", default=",".join(CVD_GATE_DEFAULT),
                   help="which simulations count toward pass/fail "
                        "(default protanopia,deuteranopia — Vienot 1999 does "
                        "not support tritanopia; it is always reported)")
    p.add_argument("--cvd-only", action="store_true",
                   help="run only the CVD report")
    p.add_argument("--no-cvd", action="store_true")
    p.add_argument("--selftest", action="store_true",
                   help="run the built-in tests and exit")
    p.add_argument("--json", metavar="PATH", help="write the full report as JSON")
    p.add_argument("--quiet", action="store_true",
                   help="only print failing targets and the summary")
    return p


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

class _Args:
    """Stand-in for argparse.Namespace in the selftest."""
    def __init__(self, **kw):
        self.tolerance = 0.0
        self.mode = "stops"
        self.metric = "ciede2000"
        self.alpha_min = 24
        self.green_lo, self.green_hi = GREEN_HUE_LO, GREEN_HUE_HI
        self.green_sat, self.green_val = 0.12, 0.08
        self.max_report, self.max_coords = 8, 4
        self.__dict__.update(kw)


def selftest() -> int:
    import tempfile
    failures = 0

    def check(name: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if cond:
            print(f"  ok   {name}")
        else:
            failures += 1
            print(f"  FAIL {name}" + (f" — {detail}" if detail else ""))

    print("palette_lint selftest")

    # 1. CIEDE2000 against Sharma, Wu & Dalal (2005) table 1.
    sharma = [
        ((50.0000, 2.6772, -79.7751), (50.0000, 0.0000, -82.7485), 2.0425),
        ((50.0000, 3.1571, -77.2803), (50.0000, 0.0000, -82.7485), 2.8615),
        ((50.0000, 2.8361, -74.0200), (50.0000, 0.0000, -82.7485), 3.4412),
        ((50.0000, -1.3802, -84.2814), (50.0000, 0.0000, -82.7485), 1.0000),
        ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
        ((22.7233, 20.0904, -46.6940), (23.0331, 14.9730, -42.5619), 2.0373),
        ((2.0776, 0.0795, -1.1350), (0.9033, -0.0636, -0.5514), 0.9082),
        ((50.0000, 2.5000, 0.0000), (50.0000, 0.0000, -2.5000), 4.3065),
    ]
    worst = 0.0
    for a, b, exp in sharma:
        got = float(ciede2000(np.array(a), np.array(b)))
        worst = max(worst, abs(got - exp))
    check("CIEDE2000 matches Sharma 2005 reference pairs",
          worst < 5e-3, f"max error {worst:.5f}")

    # 2. CIELAB anchors.
    check("Lab(white) == (100,0,0)",
          np.allclose(rgb_to_lab(np.array([255.0, 255.0, 255.0])),
                      [100.0, 0.0, 0.0], atol=1e-3))
    check("Lab(black) == (0,0,0)",
          np.allclose(rgb_to_lab(np.array([0.0, 0.0, 0.0])),
                      [0.0, 0.0, 0.0], atol=1e-6))

    # 3. CVD simulation invariants.
    grays = np.array([[0.0, 0, 0], [128.0, 128, 128], [255.0, 255, 255]])
    check("simulate_cvd('normal') is the identity",
          np.allclose(simulate_cvd(grays, "normal"), grays))
    for kind in ("protanopia", "deuteranopia", "tritanopia"):
        out = simulate_cvd(grays, kind)
        check(f"{kind} preserves the neutral axis",
              np.allclose(out, grays, atol=1.5),
              f"got {out.tolist()}")
    red = np.array([[255.0, 0, 0]])
    green = np.array([[0.0, 255, 0]])
    for kind in ("protanopia", "deuteranopia"):
        r = simulate_cvd(red, kind)[0]
        g = simulate_cvd(green, kind)[0]
        # Both should collapse to a yellow: R ~= G, B far below either.
        check(f"{kind} turns red and green into the same hue family",
              abs(float(r[0]) - float(r[1])) < 6
              and abs(float(g[0]) - float(g[1])) < 6
              and float(r[2]) < 0.5 * float(r[0])
              and float(g[2]) < 0.5 * float(g[0]),
              f"red->{rgb_to_hex(np.rint(r))} green->{rgb_to_hex(np.rint(g))}")

    # 4. Ramp mode accepts an interpolated tone that stops mode rejects.
    a = np.array(hex_to_rgb(RAMPS["etch"][3]), dtype=np.float64)
    b = np.array(hex_to_rgb(RAMPS["etch"][4]), dtype=np.float64)
    mid = np.rint((a + b) / 2).astype(np.uint8)[None, :]
    stops = build_legal_set(("etch",), "stops")
    ramp = build_legal_set(("etch",), "ramp", 16)
    d_stop = float(_distances(mid, stops, "ciede2000")[0][0])
    d_ramp = float(_distances(mid, ramp, "ciede2000")[0][0])
    check("ramp mode is strictly tighter than stops for an interpolated tone",
          d_ramp < d_stop, f"stops {d_stop:.3f} vs ramp {d_ramp:.3f}")
    check("an exact ramp stop is distance 0",
          float(_distances(np.array([hex_to_rgb(RAMPS["amber"][5])],
                                    dtype=np.uint8), stops
                           if False else build_legal_set(("amber",), "stops"),
                           "ciede2000")[0][0]) < 1e-9)

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        legal = build_legal_set(("etch", "phosphor", "amber", "ink"), "stops")

        # 5. A pure-token image lints clean.
        img = np.zeros((4, 4, 4), dtype=np.uint8)
        img[..., :3] = hex_to_rgb(RAMPS["amber"][5])
        img[..., 3] = 255
        Image.fromarray(img, "RGBA").save(tmp / "clean.png")
        rep = lint_image(tmp / "clean.png", legal, _Args())
        check("token-exact image is clean",
              rep.ok and rep.distinct_colours == 1,
              f"{rep.off_token_px} off-token, {rep.green_px} green")

        # 6. Green fires, with coordinates.
        img = np.zeros((4, 4, 4), dtype=np.uint8)
        img[..., :3] = hex_to_rgb(RAMPS["etch"][2])
        img[..., 3] = 255
        img[2, 1, :3] = (0, 255, 0)      # the chroma key leaking through
        img[3, 0, :3] = (46, 108, 50)    # render.nim's bush leaf
        Image.fromarray(img, "RGBA").save(tmp / "green.png")
        rep = lint_image(tmp / "green.png", legal, _Args())
        hexes = {f.hexcode for f in rep.green}
        coords = {c for f in rep.green for c in f.coords}
        check("green band fires on #00FF00 and on the bush leaf",
              rep.green_px == 2 and "#00FF00" in hexes and "#2E6C32" in hexes,
              f"{rep.green_px} px {hexes}")
        check("green violations carry (x,y) coordinates",
              (1, 2) in coords and (0, 3) in coords, f"{coords}")

        # 7. Alpha haze and dirty transparency fire.
        img = np.zeros((4, 4, 4), dtype=np.uint8)
        img[..., :3] = hex_to_rgb(RAMPS["amber"][5])
        img[..., 3] = 255
        img[0, 0, 3] = 12                       # haze
        img[1, 1] = (9, 9, 9, 0)                # transparent but not zeroed
        Image.fromarray(img, "RGBA").save(tmp / "alpha.png")
        rep = lint_image(tmp / "alpha.png", legal, _Args())
        check("alpha haze in 1..23 is reported", rep.alpha_haze_px == 1,
              f"{rep.alpha_haze_px}")
        check("non-zero RGB under alpha 0 is reported",
              rep.dirty_transparent_px == 1, f"{rep.dirty_transparent_px}")

        # 8. Off-token colour is reported with distance and nearest token.
        img = np.zeros((2, 2, 4), dtype=np.uint8)
        img[..., :3] = (200, 40, 190)
        img[..., 3] = 255
        Image.fromarray(img, "RGBA").save(tmp / "stray.png")
        rep = lint_image(tmp / "stray.png", legal, _Args())
        check("stray colour reported with a nearest-token name",
              rep.off_token_px == 4 and rep.off_token
              and rep.off_token[0].distance > 10
              and rep.off_token[0].nearest, f"{rep.off_token}")

        # 9. .nim literal scan finds tuples, hexes and line numbers.
        nim = tmp / "sample.nim"
        nim.write_text(
            "const Phosphor = (165'u8, 227'u8, 238'u8)   # #A5E3EE\n"
            "let leaf = (46'u8, 108'u8, 50'u8)\n"
            "of iBlowgun: (120, 160, 110)\n"
            "let notAColour = (2, 4)\n")
        rep = lint_nim(nim, legal, _Args())
        greens = {f.hexcode: [c[0] for c in f.coords] for f in rep.green}
        check("nim scan flags both greens", len(greens) == 2, f"{greens}")
        check("nim scan reports the right line numbers",
              greens.get("#2E6C32") == [2] and greens.get("#78A06E") == [3],
              f"{greens}")
        check("nim scan accepts the phosphor token",
              all(f.hexcode != "#A5E3EE" for f in rep.off_token),
              f"{[f.hexcode for f in rep.off_token]}")

    # 10. The CVD report is shaped and gated correctly.
    rep = cvd_report({"team": TEAM_WHEEL}, 10.0, CVD_GATE_DEFAULT)
    per = rep["sets"]["team"]["byVision"]
    check("CVD report covers all four vision types",
          set(per) == set(CVD_KINDS))
    check("tritanopia is reported but not gated",
          per["tritanopia"]["gated"] is False
          and per["deuteranopia"]["gated"] is True)
    check("normal vision separates the wheel better than deuteranopia",
          per["normal"]["minDeltaE"] > per["deuteranopia"]["minDeltaE"])

    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: "
          f"{failures} failure(s)")
    return EXIT_OK if failures == 0 else EXIT_FAIL


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest()
    prof = PROFILES[args.profile]
    families = tuple(f.strip() for f in args.families.split(",")) \
        if args.families else prof["families"]
    tolerance = prof["tolerance"] if args.tolerance is None else args.tolerance
    mode = prof["mode"] if args.mode is None else args.mode
    args.tolerance, args.mode = tolerance, mode

    report: dict = {"profile": args.profile, "metric": args.metric,
                    "mode": mode, "tolerance": tolerance,
                    "families": list(families)}

    if not args.cvd_only and not args.targets:
        print("palette_lint: no targets given (use --cvd-only for just the "
              "CVD gate, or pass PNGs / a dump dir / a .nim file)",
              file=sys.stderr)
        return EXIT_USAGE

    ok = True
    targets_json: list[dict] = []
    if not args.cvd_only:
        legal = build_legal_set(families, mode, args.ramp_steps)
        print("palette_lint — AFTERGLOW gate "
              "(VISUAL_REDESIGN.md Appendix B item 1)")
        print(f"  profile={args.profile}  metric={args.metric}  "
              f"tolerance={tolerance:.2f}  alpha-min={args.alpha_min}")
        print(f"  {legal.describe()}")
        print(f"  green band: hue {args.green_lo:.0f}..{args.green_hi:.0f} deg, "
              f"sat > {args.green_sat}, val > {args.green_val}")

        found = collect_targets(args.targets)
        if not found:
            print("palette_lint: targets matched no PNG or .nim files",
                  file=sys.stderr)
            return EXIT_USAGE
        print(f"  {len(found)} file(s)\n")

        reps: list[TargetReport] = []
        for path, label in found:
            if path.suffix.lower() == ".nim":
                rep = lint_nim(path, legal, args)
            elif path.suffix.lower() == ".png":
                rep = lint_image(path, legal, args, label)
            else:
                continue
            reps.append(rep)
            if rep.ok and args.quiet:
                continue
            status = "ok  " if rep.ok else "FAIL"
            print(f"{status} {rep.name}  [{rep.detail}]  "
                  f"{rep.distinct_colours} colours")
            if rep.off_token:
                pct = (100.0 * rep.off_token_px / max(1, rep.considered))
                unit = "literal" if rep.kind == "nim" else "px"
                print(f"     off-token: {rep.off_token_px} {unit} "
                      f"({pct:.1f}%) beyond dE {tolerance:.2f}")
                for f in rep.off_token:
                    where = ("lines " + ",".join(str(c[0]) for c in f.coords)
                             if rep.kind == "nim"
                             else " ".join(f"({x},{y})" for x, y in f.coords))
                    print(f"       {f.hexcode}  x{f.count:<6} "
                          f"dE={f.distance:6.2f}  nearest {f.nearest:<24} "
                          f"{where}")
            if rep.green:
                print(f"     GREEN (§3.1 law 3 — nothing in this game means "
                      f"go): {rep.green_px}")
                for f in rep.green:
                    where = ("lines " + ",".join(str(c[0]) for c in f.coords)
                             if rep.kind == "nim"
                             else " ".join(f"({x},{y})" for x, y in f.coords))
                    print(f"       {f.hexcode}  x{f.count:<6} "
                          f"hue={f.hue:6.1f} sat={f.sat:.2f} val={f.val:.2f}  "
                          f"{where}")
            if rep.alpha_haze_px:
                print(f"     alpha haze: {rep.alpha_haze_px} px with alpha in "
                      f"1..{args.alpha_min - 1} (dimmed() carries it into "
                      f"every fade stage)")
            if rep.dirty_transparent_px:
                print(f"     transparent region not bitwise zero: "
                      f"{rep.dirty_transparent_px} px")
            for n in rep.notes:
                print(f"     note: {n}")

        total = sum(r.violations for r in reps)
        failing = [r for r in reps if not r.ok]
        print(f"\nsummary: {len(reps) - len(failing)}/{len(reps)} clean, "
              f"{total} violating unit(s), budget {args.budget}")
        if failing:
            print("  worst targets:")
            for r in sorted(failing, key=lambda r: -r.violations)[:args.top]:
                print(f"    {r.violations:>8}  {r.name}  "
                      f"[{r.detail}]{'  GREEN' if r.green_px else ''}")
        ok = total <= args.budget
        targets_json = [{
            "name": r.name, "kind": r.kind, "detail": r.detail,
            "pixels": r.pixels, "considered": r.considered,
            "distinctColours": r.distinct_colours,
            "offTokenPx": r.off_token_px, "greenPx": r.green_px,
            "alphaHazePx": r.alpha_haze_px,
            "dirtyTransparentPx": r.dirty_transparent_px,
            "offToken": [f.__dict__ for f in r.off_token],
            "green": [f.__dict__ for f in r.green],
            "notes": r.notes,
        } for r in reps]
        report["targets"] = targets_json
        report["totalViolations"] = total
        report["budget"] = args.budget

    if not args.no_cvd:
        gated = tuple(k.strip() for k in args.cvd_gate.split(",") if k.strip())
        for k in gated:
            if k not in CVD_KINDS:
                print(f"palette_lint: unknown CVD kind {k!r} "
                      f"(have {', '.join(CVD_KINDS)})", file=sys.stderr)
                return EXIT_USAGE
        cvd = cvd_report({
            "team wheel (8 duos)": TEAM_WHEEL,
            "HP semaphore": SEMAPHORE,
            "directive/klaxon pairing": DIRECTIVE_PAIR,
        }, args.cvd_min, gated)
        report["cvd"] = cvd
        if not print_cvd(cvd):
            ok = False

    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2))
        print(f"\nwrote {args.json}")

    print("\nRESULT:", "PASS" if ok else "FAIL")
    return EXIT_OK if ok else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
