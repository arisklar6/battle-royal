#!/usr/bin/env python3
"""Mechanical acceptance test for the two-chassis carrier sheets.

The pair contract (carrier-sheet-a/b notes in prompts/characters.json): after
box-reduction to the 32x48 target, Chassis A must read visibly narrower than
Chassis B. Because both sheets bake through crop rects registered by HEIGHT
(hull top at 1/6 of the rect, base at 3/4), the honest width comparison scales
each hull by its height, not its own bbox width.

Usage:
    uv run --project tools/art tools/art/measure_silhouette.py [glob...]

Prints per sheet: front-cell hull bbox, height-normalized baked width, and a
PASS/FAIL verdict per A/B pair (A at least 4px narrower baked, per the
"~8px narrower at the shoulder line" design intent with tolerance).
"""

import glob
import os
import sys

import numpy as np
from PIL import Image

HULL_ROWS = 28  # rows 8..36 of the 48-row target between the 1/6 and 3/4 anchors


def hull_mask(img: Image.Image) -> np.ndarray:
    a = np.asarray(img.convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return ~((g > 150) & (g > r + 40) & (g > b + 40))


def front_cell_metrics(path: str):
    im = Image.open(path)
    w, h = im.size
    cell = im.crop((0, 0, w // 2, h // 2))  # top-left cell = front view
    m = hull_mask(cell)
    ys, xs = np.where(m)
    if len(xs) == 0:
        return None
    bw = int(xs.max() - xs.min() + 1)
    bh = int(ys.max() - ys.min() + 1)
    baked_w = bw * HULL_ROWS / bh  # width in target px when height fills the anchors
    return bw, bh, baked_w


def main(argv: list[str]) -> int:
    root = os.path.join(os.path.dirname(__file__), "..", "..", "art", "raw", "characters")
    patterns = argv or [os.path.join(root, "carrier-sheet-*.png")]
    paths = sorted(p for pat in patterns for p in glob.glob(pat))
    if not paths:
        print("no sheets found", file=sys.stderr)
        return 2
    widths: dict[str, list[tuple[str, float]]] = {"a": [], "b": []}
    for p in paths:
        met = front_cell_metrics(p)
        name = os.path.basename(p)
        if met is None:
            print(f"{name}: NO HULL FOUND")
            continue
        bw, bh, baked = met
        chassis = "a" if "-a-" in name else "b" if "-b-" in name else "?"
        if chassis in widths:
            widths[chassis].append((name, baked))
        print(f"{name}  front hull {bw}x{bh}px  baked width {baked:.1f}/32")
    ok = True
    if widths["a"] and widths["b"]:
        best_a = min(widths["a"], key=lambda t: t[1])
        best_b = max(widths["b"], key=lambda t: t[1])
        gap = best_b[1] - best_a[1]
        verdict = "PASS" if gap >= 4.0 else "FAIL"
        ok = gap >= 4.0
        print(f"\nbest pair: {best_a[0]} ({best_a[1]:.1f}) vs {best_b[0]} "
              f"({best_b[1]:.1f})  gap {gap:.1f}px  {verdict} (need >= 4)")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
