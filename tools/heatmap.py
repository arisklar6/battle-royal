#!/usr/bin/env python3
"""Post-match spatial heatmap from results/events.json (VISUAL_REDESIGN Part 5).

Reads the eventHistoryJson export (array of {tick, type, slot, pos:[x,y], data?})
and renders a 48x48 arena grid upscaled x12 (576x576 px):

  - background        Faraday  #0C1116, faint #1C242B grid every tile
  - death_fireworks   Klaxon   #FF4A36 heat blobs (per-tile intensity,
                      radius-1 falloff, alpha saturates with count)
  - mine_explosion    same blobs at half weight
  - gift_landed       Amber    #FFB454 diamonds
  - zone_warning      Magenta  #FF4FA3 concentric ring outlines at r_end

Stdlib only: writes a hand-rolled PNG (zlib+struct) plus a binary PPM (P6)
fallback next to it.

Usage:  python tools/heatmap.py <events.json> [out.png]
"""

import json
import os
import struct
import sys
import zlib
from collections import Counter

ARENA = 48
SCALE = 12
SIZE = ARENA * SCALE  # 576

FARADAY = (0x0C, 0x11, 0x16)
GRIDCOL = (0x1C, 0x24, 0x2B)
KLAXON = (0xFF, 0x4A, 0x36)
AMBER = (0xFF, 0xB4, 0x54)
MAGENTA = (0xFF, 0x4F, 0xA3)


# ---------------------------------------------------------------- canvas ----

def blend(buf, x, y, rgb, a):
    """Alpha-blend rgb onto pixel (x, y) of the SIZE x SIZE RGB buffer."""
    if a <= 0.0 or not (0 <= x < SIZE and 0 <= y < SIZE):
        return
    if a > 1.0:
        a = 1.0
    i = (y * SIZE + x) * 3
    buf[i] = int(buf[i] + (rgb[0] - buf[i]) * a + 0.5)
    buf[i + 1] = int(buf[i + 1] + (rgb[1] - buf[i + 1]) * a + 0.5)
    buf[i + 2] = int(buf[i + 2] + (rgb[2] - buf[i + 2]) * a + 0.5)


def make_canvas():
    buf = bytearray(bytes(FARADAY) * (SIZE * SIZE))
    # faint 1px grid line at every tile boundary
    for t in range(0, SIZE, SCALE):
        for p in range(SIZE):
            blend(buf, p, t, GRIDCOL, 1.0)
            blend(buf, t, p, GRIDCOL, 1.0)
    return buf


# --------------------------------------------------------------- drawing ----

def fill_tile(buf, tx, ty, rgb, a):
    for py in range(ty * SCALE, ty * SCALE + SCALE):
        for px in range(tx * SCALE, tx * SCALE + SCALE):
            blend(buf, px, py, rgb, a)


def draw_heat(buf, heat):
    """heat: {(tx,ty): intensity}. Spread radius-1 falloff, alpha by count."""
    spread = {}
    for (tx, ty), w in heat.items():
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = tx + dx, ty + dy
                if 0 <= nx < ARENA and 0 <= ny < ARENA:
                    f = 1.0 if dx == 0 and dy == 0 else 0.35
                    spread[(nx, ny)] = spread.get((nx, ny), 0.0) + w * f
    for (tx, ty), w in spread.items():
        fill_tile(buf, tx, ty, KLAXON, 1.0 - 0.62 ** w)  # saturating alpha


def draw_diamond(buf, tx, ty):
    cx, cy = tx * SCALE + SCALE // 2, ty * SCALE + SCALE // 2
    r = 5
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            d = abs(dx) + abs(dy)
            if d <= r:
                a = 1.0 if d < r else 0.6  # softened diamond edge
                blend(buf, cx + dx, cy + dy, AMBER, a)


def draw_ring(buf, tx, ty, r_tiles):
    """Anti-aliased circle outline, radius in tiles, centered on tile center."""
    cx, cy = tx * SCALE + SCALE // 2, ty * SCALE + SCALE // 2
    rp = r_tiles * SCALE
    if rp <= 0:
        return
    lo, hi = int(rp) - 2, int(rp) + 3
    for py in range(max(0, cy - hi), min(SIZE, cy + hi + 1)):
        for px in range(max(0, cx - hi), min(SIZE, cx + hi + 1)):
            dx, dy = px - cx, py - cy
            d2 = dx * dx + dy * dy
            if (lo * lo) <= d2 <= (hi * hi):
                dist = d2 ** 0.5
                a = 1.4 - abs(dist - rp)  # ~1.5px anti-aliased stroke
                blend(buf, px, py, MAGENTA, min(0.85, a * 0.85))


# --------------------------------------------------------------- writers ----

def write_png(path, w, h, rgb):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3])
                   for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def write_ppm(path, w, h, rgb):
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(bytes(rgb))


# ------------------------------------------------------------------ main ----

def in_arena(pos):
    return (isinstance(pos, list) and len(pos) == 2
            and 0 <= pos[0] < ARENA and 0 <= pos[1] < ARENA)


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: python tools/heatmap.py <events.json> [out.png]")
    src = argv[1]
    out_png = argv[2] if len(argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(src)), "heatmap.png")
    out_ppm = os.path.splitext(out_png)[0] + ".ppm"

    with open(src, "r", encoding="utf-8") as f:
        events = json.load(f)

    counts = Counter(e.get("type", "?") for e in events)

    heat = {}
    gifts, rings = [], []
    for e in events:
        t, pos = e.get("type"), e.get("pos")
        if t == "death_fireworks" and in_arena(pos):
            heat[tuple(pos)] = heat.get(tuple(pos), 0.0) + 1.0
        elif t == "mine_explosion" and in_arena(pos):
            heat[tuple(pos)] = heat.get(tuple(pos), 0.0) + 0.5
        elif t == "gift_landed" and in_arena(pos):
            gifts.append(tuple(pos))
        elif t == "zone_warning" and in_arena(pos):
            data = e.get("data")
            if isinstance(data, dict) and isinstance(data.get("r_end"), (int, float)):
                rings.append((tuple(pos), data["r_end"]))

    buf = make_canvas()
    draw_heat(buf, heat)
    for (pos, r_end) in rings:
        draw_ring(buf, pos[0], pos[1], r_end)
    for (tx, ty) in gifts:
        draw_diamond(buf, tx, ty)

    write_ppm(out_ppm, SIZE, SIZE, buf)
    png_err = None
    try:
        write_png(out_png, SIZE, SIZE, buf)
    except Exception as exc:  # PPM already on disk as the fallback
        png_err = exc

    print("event counts:")
    for name in sorted(counts):
        print("  %-18s %d" % (name, counts[name]))
    print("rendered: %d heat tile(s), %d gift diamond(s), %d zone ring(s)"
          % (len(heat), len(gifts), len(rings)))
    print("wrote %s (%dx%d)" % (out_ppm, SIZE, SIZE))
    if png_err is None:
        print("wrote %s (%dx%d)" % (out_png, SIZE, SIZE))
    else:
        print("png write failed (%s); ppm is authoritative" % png_err)


if __name__ == "__main__":
    main(sys.argv)
