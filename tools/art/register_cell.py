#!/usr/bin/env python3
"""Registration compositor: sheet cell -> anchor-true bake source.

The generated 2x2 sheets place hulls larger than the plan's in-cell
reservation, so a raw cell crop cannot satisfy both the strict 2^k ratio rule
and the registration contract (hull top at 1/6 of the rect, base near 3/4,
horizontally centred). This tool cuts one cell, finds the hull against the
chroma key, and pastes it onto a fresh pure-#00FF00 canvas of exactly
targetW*16 x targetH*16 with the hull top pinned to the 1/6 anchor and the
silhouette centred. bake.py then crops the whole canvas (a clean 16x chain).

Mirroring: --mirror flips the cell horizontally before registration — the
carrier is bilaterally symmetrical, so one good quarter-turn cell yields both
E and W facings with guaranteed consistency.

Usage:
  register_cell.py SHEET.png --cell top-left --target 32x48 --out reg.png
                   [--mirror] [--scale-to-anchors]
"""

import argparse
import sys

import numpy as np
from PIL import Image

CELLS = {"top-left": (0, 0), "top-right": (1, 0),
         "bottom-left": (0, 1), "bottom-right": (1, 1)}
KEY = (0, 255, 0)


def hull_bbox(img: Image.Image):
    a = np.asarray(img.convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    keep = ~((g > 150) & (g > r + 40) & (g > b + 40))
    ys, xs = np.where(keep)
    if len(xs) == 0:
        raise SystemExit("no hull found against the chroma key")
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sheet")
    ap.add_argument("--cell", choices=sorted(CELLS) + ["whole"], default="whole",
                    help="sheet cell, or 'whole' for a single-subject image")
    ap.add_argument("--target", required=True, help="WxH, e.g. 32x48")
    ap.add_argument("--out", required=True)
    ap.add_argument("--mirror", action="store_true",
                    help="flip horizontally before registration")
    ap.add_argument("--factor", type=int, default=16,
                    help="canvas = target * factor (power of two, default 16)")
    ap.add_argument("--scale-to-anchors", action="store_true",
                    help="resize the hull so its height exactly spans the "
                         "1/6..3/4 anchor band (one clean resample; default "
                         "keeps native size when it fits)")
    args = ap.parse_args()

    tw, th = (int(v) for v in args.target.split("x"))
    cw_, chh = tw * args.factor, th * args.factor
    band_top = chh // 6
    band_bot = chh * 3 // 4
    band_h = band_bot - band_top

    im = Image.open(args.sheet).convert("RGB")
    W, H = im.size
    if args.cell == "whole":
        cell = im
    else:
        cx, cy = CELLS[args.cell]
        cell = im.crop((cx * W // 2, cy * H // 2,
                        (cx + 1) * W // 2, (cy + 1) * H // 2))
    if args.mirror:
        cell = cell.transpose(Image.FLIP_LEFT_RIGHT)

    x0, y0, x1, y1 = hull_bbox(cell)
    hull = cell.crop((x0, y0, x1, y1))
    hw, hh = hull.size

    if hh > band_h or args.scale_to_anchors:
        s = band_h / hh
        hull = hull.resize((max(1, round(hw * s)), band_h), Image.LANCZOS)
        hw, hh = hull.size
    if hw > cw_:
        raise SystemExit(f"hull {hw}px wider than canvas {cw_}px — wrong target?")

    canvas = Image.new("RGB", (cw_, chh), KEY)
    py_ = band_top if th > tw else (chh - hh) // 2   # wide sprites centre vertically
    canvas.paste(hull, ((cw_ - hw) // 2, py_))
    canvas.save(args.out)
    print(f"registered {args.cell}{' mirrored' if args.mirror else ''}: "
          f"hull {hw}x{hh} on {cw_}x{chh}, top anchor {band_top} "
          f"-> baked height {hh * th / chh:.1f}/{th} rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
