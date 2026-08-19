#!/usr/bin/env python3
"""Floor-field assembly (ART_UPGRADE_PLAN Tier B, world.json floor-field notes).

Four independent material draws become one WorldPxR x WorldPxR field:
interior-crop each (the frame edge is where the model puts its vignette),
box-halve to quadrant size, equalize per-quadrant statistics to the global
mean/std (independently quantized quadrants would join as colour steps), then
mosaic. Quantization happens ONCE, downstream in bake.py, on the mosaic.

Usage:
    assemble_floor.py --dir art/raw/world --out /tmp/floor_mosaic.png
                      [--world 1152] [--crop-frac 0.5625]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def box_halve(a: np.ndarray, times: int) -> np.ndarray:
    for _ in range(times):
        h, w = a.shape[:2]
        a = a.reshape(h // 2, 2, w // 2, 2, -1).mean(axis=(1, 3))
    return a


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", default="art/raw/world")
    ap.add_argument("--stem", default="floor-field")
    ap.add_argument("--out", required=True)
    ap.add_argument("--world", type=int, default=1152,
                    help="assembled field edge (WorldPxR)")
    ap.add_argument("--blend", type=int, default=12,
                    help="cross-fade width at quadrant joins, px (0 disables)")
    ap.add_argument("--substrate", default="40,48,57",
                    help="target per-channel mean RGB — the board's BgDark; "
                         "'none' skips substrate matching")
    ap.add_argument("--texture-std", type=float, default=9.0,
                    help="target luminance std after matching (texture depth)")
    args = ap.parse_args()

    quad = args.world // 2
    paths = [Path(args.dir) / f"{args.stem}-{i:02d}.png" for i in (1, 2, 3, 4)]
    quads = []
    for p in paths:
        if not p.exists():
            print(f"missing {p}", file=sys.stderr)
            return 2
        im = np.asarray(Image.open(p).convert("RGB")).astype(np.float64)
        h, w = im.shape[:2]
        # interior window: centred, sized for an exact box-halving chain to quad
        k = 0
        crop = quad
        while crop * 2 <= min(h, w) - 128:   # keep >=64px off each edge
            crop *= 2
            k += 1
        y0 = (h - crop) // 2
        x0 = (w - crop) // 2
        quads.append(box_halve(im[y0:y0 + crop, x0:x0 + crop], k))
        print(f"{p.name}: {w}x{h} -> interior {crop} -> {k} halvings -> {quad}")

    # equalize each quadrant to the global statistics, per channel
    g_mean = np.mean([q.mean(axis=(0, 1)) for q in quads], axis=0)
    g_std = np.mean([q.std(axis=(0, 1)) for q in quads], axis=0)
    eq = []
    for q in quads:
        m = q.mean(axis=(0, 1))
        s = q.std(axis=(0, 1))
        eq.append((q - m) * (g_std / np.maximum(s, 1e-6)) + g_mean)

    field = np.zeros((args.world, args.world, 3), dtype=np.float64)
    field[:quad, :quad] = eq[0]
    field[:quad, quad:] = eq[1]
    field[quad:, :quad] = eq[2]
    field[quad:, quad:] = eq[3]

    if args.substrate != "none":
        # The raw material is far brighter than the Etch ramp the quantizer
        # snaps to (a bright field collapses to ONE ramp colour). Tone-map to
        # the substrate: per-channel mean -> BgDark, contrast -> texture-std,
        # so plateAt's own +-deltas ride on a base that lives near BgDark.
        tgt = np.array([float(v) for v in args.substrate.split(",")])
        m = field.mean(axis=(0, 1))
        sd = field.std(axis=(0, 1))
        scale = args.texture_std / np.maximum(sd, 1e-6)
        field = (field - m) * scale + tgt
    b = args.blend
    if b > 0:
        # cross-fade across the two seams so the joins read as material, not tiles
        for i in range(-b, b):
            t = (i + b) / (2 * b)
            col = quad + i
            field[:, col] = field[:, col - 1] * (1 - t) * 0.5 + field[:, col] * (0.5 + t * 0.5)
            row = quad + i
            field[row, :] = field[row - 1, :] * (1 - t) * 0.5 + field[row, :] * (0.5 + t * 0.5)

    out = np.clip(field, 0, 255).astype(np.uint8)
    Image.fromarray(out).save(args.out)
    print(f"assembled {args.world}x{args.world} -> {args.out} "
          f"(mean {out.mean():.1f}, std {out.std():.1f})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
