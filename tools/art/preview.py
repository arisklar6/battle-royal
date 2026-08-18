#!/usr/bin/env python3
"""preview.py — contact sheets for every sprite the renderer actually emits.

The honest way to see whether the art got better is to look at the bytes that
ship, not at a Python re-implementation of the drawing code.  So this script
does not draw anything itself: it assembles the output of
`tools/art/dump_sprites.nim`, which runs a real headless episode through the
real `Renderer` (the same `include render` pattern `game/poster.nim` uses) and
writes every wire sprite out as a straight-alpha PNG.

Three views, because they answer three different questions:

  contact_sheet.png   every sprite, integer-zoomed to a uniform cell, labelled
                      with id / label / dimensions / colour count / wire bytes.
                      "What is in the build, and did anything change?"
  contact_1to1.png    the same sprites at exactly 1:1, flowed onto the real
                      substrate.  ART_UPGRADE_PLAN risk #5's acceptance test is
                      literally "can I tell what it is at 1:1, unzoomed?" — a
                      zoomed sheet cannot answer that and will flatter bad art.
  contact_4x.png      the same flow at a *uniform* 4x (--zoom).  The cell sheet
                      zooms each sprite to fill its box, so a 5px sprite and a
                      48px one end up the same size on the page; a uniform zoom
                      keeps relative scale honest while still showing pixels.
  contact_diff.png    two dumps overlaid: cells bordered amber (changed),
                      phosphor (added), klaxon (removed).  Before/after at a
                      glance, cell for cell, because the dump's ordering is
                      stable.

Every sheet carries the dump's coverage line: how many of the sprite ids the
renderer can address this episode actually emitted, and which declared families
drew nothing at all.  A contact sheet is a picture of one match, and a sprite
the match never reached is absent in exactly the same way as a sprite that does
not exist — the header is what keeps the sheet from quietly claiming to be the
whole catalogue.

Cells sit on the real board substrate `BgDark (40,48,57)` — checkered, so
transparency is visible — because AFTERGLOW art is lit for that ground and
judging it on white or black is judging a different picture
(ART_UPGRADE_PLAN §3.2's substrate warning).

Usage
-----
    # dump + assemble in one step
    uv run --project tools/art tools/art/preview.py --build

    # assemble an existing dump somewhere else
    uv run --project tools/art tools/art/preview.py \\
        --dump docs/evidence/sprites --out docs/evidence

    # before/after
    uv run --project tools/art tools/art/preview.py \\
        --dump /tmp/after --diff-against /tmp/before

    uv run --project tools/art tools/art/preview.py --selftest
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# --- AFTERGLOW colours used by the sheet chrome itself ---------------------
BG_DARK = (40, 48, 57)              # render.nim BgDark — the real substrate
BG_DARK_ALT = (48, 56, 65)          # checker partner, +8 like shade()
PAPER = (18, 23, 28)                # gutter, a touch under Faraday
ETCH = (0x36, 0x44, 0x4F)
ETCH_DIM = (0x2A, 0x37, 0x42)
PHOSPHOR = (0xA5, 0xE3, 0xEE)
AMBER = (0xFF, 0xB4, 0x54)
MAGENTA = (0xFF, 0x4F, 0xA3)
KLAXON = (0xFF, 0x4A, 0x36)
BONE = (0xE9, 0xE4, 0xD8)

EXIT_OK, EXIT_FAIL, EXIT_USAGE = 0, 1, 2

FONT_CANDIDATES = [
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "DejaVuSansMono.ttf",
]


def load_font(size: int):
    for cand in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(cand, size)
        except (OSError, ValueError):
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:      # Pillow < 10.1
        return ImageFont.load_default()


# ---------------------------------------------------------------------------
# dump loading + per-sprite statistics
# ---------------------------------------------------------------------------

@dataclass(eq=False)   # holds an ndarray; identity comparison is what we want
class Sprite:
    id: int
    label: str
    w: int
    h: int
    variant: int
    path: Path
    pix_hash: str
    compressed: int
    raw: int
    define_count: int
    distinct_variants: int
    from_init: bool
    dims_vary: bool
    # filled by stats()
    px: np.ndarray | None = None
    colours: int = 0
    alpha_haze: int = 0
    dirty_transparent: int = 0
    opaque_px: int = 0
    block_scale: int = 1
    flags: list[str] = field(default_factory=list)

    @property
    def key(self) -> tuple[int, str, int]:
        return (self.id, self.label, self.variant)


def block_scale(px: np.ndarray, max_scale: int = 8) -> int:
    """Largest k such that the image is exactly k*k blocks of one colour.

    k > 1 means the sprite was authored at 1/k scale and nearest-neighbour
    upscaled by `addSprite` — i.e. it carries no more information than its
    small original.  ART_UPGRADE_PLAN §1 lists eight such board sprites as a
    Phase 1 fix; this measures the claim instead of trusting it.
    """
    h, w = px.shape[:2]
    best = 1
    for k in range(2, max_scale + 1):
        if w % k or h % k:
            continue
        blocks = px.reshape(h // k, k, w // k, k, 4)
        if np.all(blocks == blocks[:, :1, :, :1]):
            best = k
    return best


def load_dump(dump: Path) -> tuple[dict, list[Sprite]]:
    manifest = dump / "sprites.json"
    if not manifest.is_file():
        raise SystemExit(
            f"preview: no sprites.json in {dump}\n"
            f"         run: nim c -r tools/art/dump_sprites.nim out={dump}\n"
            f"         (or pass --build)")
    meta = json.loads(manifest.read_text())
    out: list[Sprite] = []
    for s in meta.get("sprites", []):
        for i, v in enumerate(s.get("variants", [])):
            out.append(Sprite(
                id=s["id"], label=s["label"],
                w=v.get("w", s["w"]), h=v.get("h", s["h"]), variant=i,
                path=dump / v["file"], pix_hash=v["pixHash"],
                compressed=v["compressedBytes"], raw=v["rawBytes"],
                define_count=s["defineCount"],
                distinct_variants=s["distinctVariants"],
                from_init=s.get("fromInitPacket", False),
                dims_vary=s.get("dimsVary", False)))
    return meta, out


def stats(sprites: list[Sprite], meta: dict, alpha_min: int = 24) -> None:
    colliding = {c["id"] for c in meta.get("collisions", [])}
    rs = int(meta.get("rs", 1))
    for s in sprites:
        img = Image.open(s.path)
        if img.mode != "RGBA":
            img = img.convert("RGBA")
        px = np.asarray(img, dtype=np.uint8)
        s.px = px
        a = px[..., 3]
        s.opaque_px = int((a >= alpha_min).sum())
        s.alpha_haze = int(np.bincount(a.reshape(-1),
                                       minlength=256)[1:alpha_min].sum())
        dead = a == 0
        s.dirty_transparent = (int((px[dead][:, :3] != 0).any(axis=1).sum())
                               if dead.any() else 0)
        live = px[a >= alpha_min][:, :3].astype(np.int64)
        s.colours = int(np.unique(live[:, 0] * 65536 + live[:, 1] * 256
                                  + live[:, 2]).size) if live.size else 0
        s.block_scale = block_scale(px)
        s.flags = []
        if s.block_scale >= rs > 1:
            s.flags.append(f"1x*{s.block_scale}")
        elif s.block_scale > 1:
            s.flags.append(f"blk{s.block_scale}")
        if s.id in colliding:
            s.flags.append("COLLIDE")
        if s.alpha_haze:
            s.flags.append(f"haze{s.alpha_haze}")
        if s.dirty_transparent:
            s.flags.append("dirty")
        if s.distinct_variants > 1:
            s.flags.append(f"v{s.variant + 1}/{s.distinct_variants}")


# ---------------------------------------------------------------------------
# drawing helpers
# ---------------------------------------------------------------------------

def checker(w: int, h: int, size: int = 8) -> Image.Image:
    """The board substrate, checkered so alpha reads without lying about the
    ground colour the art is lit for."""
    yy, xx = np.mgrid[0:h, 0:w]
    mask = (((xx // size) + (yy // size)) % 2).astype(bool)
    out = np.empty((h, w, 3), dtype=np.uint8)
    out[...] = BG_DARK
    out[mask] = BG_DARK_ALT
    return Image.fromarray(out, "RGB")


def fit(px: np.ndarray, box_w: int, box_h: int) -> tuple[Image.Image, str]:
    """Integer-zoom up, area-average down.  Never a fractional upscale: this is
    pixel art and a smoothed enlargement is a different picture."""
    h, w = px.shape[:2]
    img = Image.fromarray(px, "RGBA")
    if w <= box_w and h <= box_h:
        z = max(1, min(box_w // max(1, w), box_h // max(1, h)))
        if z > 1:
            img = img.resize((w * z, h * z), Image.NEAREST)
        return img, (f"x{z}" if z > 1 else "1:1")
    scale = min(box_w / w, box_h / h)
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    return img.resize((nw, nh), Image.BOX), f"/{w / nw:.1f}"


def paste_centred(sheet: Image.Image, cell: Image.Image, x: int, y: int,
                  box_w: int, box_h: int) -> None:
    sheet.paste(cell, (x + (box_w - cell.width) // 2,
                       y + (box_h - cell.height) // 2), cell)


def fmt_bytes(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f}K"
    return f"{n / 1048576:.2f}M"


def clip(text: str, font, width: int) -> str:
    """Hard-truncate to `width` px. Cell labels that overrun bleed into the
    neighbouring cell and make the sheet unreadable exactly where it is
    densest."""
    if font.getlength(text) <= width:
        return text
    while text and font.getlength(text + "…") > width:
        text = text[:-1]
    return text + "…" if text else ""


def draw_cell_label(d: ImageDraw.ImageDraw, x: int, y: int, w: int,
                    font, lines: list[tuple[str, tuple[int, int, int]]],
                    line_h: int = 11) -> None:
    for i, (text, colour) in enumerate(lines):
        d.text((x, y + i * line_h), clip(text, font, w), font=font,
               fill=colour)


# ---------------------------------------------------------------------------
# the sheets
# ---------------------------------------------------------------------------

def header_lines(meta: dict, sprites: list[Sprite], title: str) -> list[str]:
    tot_c = sum(s.compressed for s in sprites)
    tot_r = sum(s.raw for s in sprites)
    ones = [s for s in sprites if s.block_scale >= int(meta.get("rs", 1)) > 1]
    haze = [s for s in sprites if s.alpha_haze]
    lines = [
        f"ZERO SUM — {title}",
        f"RS={meta.get('rs')}  tile={meta.get('tilePxR')}px  "
        f"arena={meta.get('worldPxR')}px  body={meta.get('bodyW')}x"
        f"{meta.get('bodyH')}  seed={meta.get('seed')}  "
        f"ticks={meta.get('ticksRun')}",
        f"{meta.get('uniqueSpriteIds')} sprite ids / "
        f"{len(sprites)} images   raw {tot_r/1024:.0f} KiB -> "
        f"snappy {tot_c/1024:.0f} KiB ({tot_r/max(1,tot_c):.2f}:1)   "
        f"update traffic {meta.get('updatePacketBytes', 0)/1048576:.2f} MiB "
        f"over {meta.get('updateFrames')} frames",
        f"no detail finer than RS (block-uniform x{meta.get('rs')}): "
        f"{len(ones)} images   with alpha haze in 1..23: {len(haze)}",
    ]
    cov = meta.get("coverage")
    if cov:
        # No parenthetical here: the header clips at the page width, and the
        # line that matters is the amber one below it.
        lines.append(
            f"coverage: {cov.get('presentFamilies')}/"
            f"{cov.get('declaredFamilies')} declared sprite families present "
            f"in this episode, {cov.get('emittedIds')}/"
            f"{cov.get('declaredIds')} addressable ids emitted")
        empty = cov.get("emptyFamilies", [])
        if empty:
            lines.append(f"NOT ON THIS SHEET — {len(empty)} declared famil"
                         f"{'ies' if len(empty) != 1 else 'y'} emitted "
                         f"nothing: " + ", ".join(empty))
        stray = cov.get("undeclaredEmittedIds", [])
        if stray:
            lines.append("NOT ON THIS SHEET — ids emitted that the coverage "
                         "table does not declare (it has fallen behind "
                         "render.nim): " + ", ".join(str(i) for i in stray))
    for c in meta.get("collisions", []):
        lines.append(f"SPRITE ID COLLISION  id {c['id']}: "
                     + " / ".join(c["labels"])
                     + f"  -> client keeps '{c['winner']}'")
    return lines


def draw_header(sheet: Image.Image, lines: list[str], width: int,
                fonts) -> int:
    f_big, f_small = fonts
    d = ImageDraw.Draw(sheet)
    y = 10
    d.text((12, y), clip(lines[0], f_big, width - 24), font=f_big, fill=BONE)
    y += 20
    for ln in lines[1:]:
        colour = (KLAXON if ln.startswith("SPRITE ID COLLISION")
                  else AMBER if ln.startswith(("reject criterion",
                                               "NOT ON THIS SHEET"))
                  else PHOSPHOR)
        d.text((12, y), clip(ln, f_small, width - 24), font=f_small,
               fill=colour)
        y += 14
    y += 4
    d.line([(12, y), (width - 12, y)], fill=ETCH, width=1)
    return y + 10


def contact_sheet(meta: dict, sprites: list[Sprite], out: Path, *,
                  box: int = 88, cols: int = 0, pad: int = 6,
                  label_h: int = 48, title: str = "sprite contact sheet"
                  ) -> Image.Image:
    fonts = (load_font(15), load_font(10))
    f_small = fonts[1]
    n = len(sprites)
    cell_w = box + pad * 2
    cell_h = box + pad * 2 + label_h
    if cols <= 0:
        cols = max(1, int(np.ceil(np.sqrt(n * cell_h / cell_w))))
    rows = int(np.ceil(n / cols))
    width = cols * cell_w + 24
    head = header_lines(meta, sprites, title)
    head_h = 34 + 14 * (len(head) - 1) + 16
    sheet = Image.new("RGB", (width, head_h + rows * cell_h + 16), PAPER)
    top = draw_header(sheet, head, width, fonts)
    d = ImageDraw.Draw(sheet)

    for i, s in enumerate(sprites):
        cx = 12 + (i % cols) * cell_w
        cy = top + (i // cols) * cell_h
        sheet.paste(checker(box, box), (cx + pad, cy + pad))
        img, zoom = fit(s.px, box, box)
        paste_centred(sheet, img, cx + pad, cy + pad, box, box)
        border = ETCH_DIM
        if "COLLIDE" in s.flags:
            border = KLAXON
        elif any(f.startswith("1x*") for f in s.flags):
            border = AMBER
        d.rectangle([cx + pad - 1, cy + pad - 1,
                     cx + pad + box, cy + pad + box], outline=border)
        flag_colour = KLAXON if "COLLIDE" in s.flags else AMBER
        draw_cell_label(d, cx + pad, cy + pad + box + 3, box, f_small, [
            (f"{s.id} {s.label}", BONE),
            (f"{s.w}x{s.h} {zoom}", ETCH),
            (f"{s.colours}c {fmt_bytes(s.compressed)}", ETCH),
            (" ".join(s.flags), flag_colour),
        ])
    sheet.save(out)
    return sheet


def one_to_one_sheet(meta: dict, sprites: list[Sprite], out: Path, *,
                     width: int = 1100, max_native: int = 160,
                     gutter: int = 10, zoom: int = 1) -> Image.Image:
    """Every sprite at a uniform integer zoom on the real substrate.

    `zoom=1` is the acceptance view for ART_UPGRADE_PLAN risk #5. `zoom=4` is
    the same page with the pixels visible — uniform, so a 5px sprite still
    looks five pixels wide next to a 48px one. (The cell sheet zooms each
    sprite to fill its box, which is the right choice there and the wrong one
    for judging relative size.)"""
    zoom = max(1, int(zoom))
    fonts = (load_font(15), load_font(11))
    f_small = fonts[1]
    shown: list[Sprite] = []
    omitted: list[Sprite] = []
    for s in sprites:
        (shown if s.w <= max_native and s.h <= max_native
         else omitted).append(s)
    head = header_lines(
        meta, sprites,
        "sprites at 1:1 (acceptance view)" if zoom == 1
        else f"sprites at {zoom}:1, uniform zoom")
    head.append(
        (f"reject criterion: can you tell what it is at 1:1? " if zoom == 1
         else f"uniform x{zoom} — relative size is true, so judge shape here "
              f"and legibility on the 1:1 sheet.  ")
        + f"{len(omitted)} sprite(s) over {max_native}px omitted: "
        + ", ".join(sorted({f"{s.id} {s.label}" for s in omitted})))
    head_h = 34 + 14 * (len(head) - 1) + 16

    # flow layout
    rows: list[list[Sprite]] = [[]]
    row_w = 0
    for s in shown:
        w = max(s.w * zoom, 26) + gutter
        if row_w + w > width - 24 and rows[-1]:
            rows.append([])
            row_w = 0
        rows[-1].append(s)
        row_w += w
    row_hs = [max((s.h * zoom for s in r), default=0) + 14 + gutter
              for r in rows]
    sheet = Image.new("RGB", (width, head_h + sum(row_hs) + 16), PAPER)
    top = draw_header(sheet, head, width, fonts)
    d = ImageDraw.Draw(sheet)
    y = top
    for r, rh in zip(rows, row_hs):
        x = 12
        for s in r:
            img = Image.fromarray(s.px, "RGBA")
            if zoom > 1:
                img = img.resize((s.w * zoom, s.h * zoom), Image.NEAREST)
            sheet.paste(checker(img.width, img.height), (x, y))
            sheet.paste(img, (x, y), img)
            d.text((x, y + img.height + 1), str(s.id), font=f_small, fill=ETCH)
            x += max(img.width, 26) + gutter
        y += rh
    sheet.save(out)
    return sheet


def diff_sheet(meta_new: dict, new: list[Sprite],
               meta_old: dict, old: list[Sprite], out: Path, *,
               box: int = 88, cols: int = 0, pad: int = 6,
               label_h: int = 48) -> tuple[Image.Image, dict]:
    by_old = {s.key: s for s in old}
    by_new = {s.key: s for s in new}
    keys = sorted(set(by_old) | set(by_new))
    tally = {"changed": 0, "added": 0, "removed": 0, "same": 0,
             "resized": 0}
    fonts = (load_font(15), load_font(10))
    f_small = fonts[1]
    cell_w, cell_h = box + pad * 2, box + pad * 2 + label_h
    if cols <= 0:
        cols = max(1, int(np.ceil(np.sqrt(len(keys) * cell_h / cell_w))))
    rows = int(np.ceil(len(keys) / cols))
    width = cols * cell_w + 24
    head = [
        "ZERO SUM — sprite diff",
        f"new: RS={meta_new.get('rs')} {meta_new.get('uniqueSpriteIds')} ids, "
        f"{len(new)} images   |   old: RS={meta_old.get('rs')} "
        f"{meta_old.get('uniqueSpriteIds')} ids, {len(old)} images",
        "phosphor = added   amber = changed   klaxon = removed   "
        "magenta = resized   etch = identical",
        "",
    ]
    head_h = 34 + 14 * (len(head) - 1) + 16
    sheet = Image.new("RGB", (width, head_h + rows * cell_h + 16), PAPER)

    for i, k in enumerate(keys):
        a, b = by_old.get(k), by_new.get(k)
        if b is None:
            state, border, show = "removed", KLAXON, a
        elif a is None:
            state, border, show = "added", PHOSPHOR, b
        elif (a.w, a.h) != (b.w, b.h):
            state, border, show = "resized", MAGENTA, b
        elif a.pix_hash != b.pix_hash:
            state, border, show = "changed", AMBER, b
        else:
            state, border, show = "same", ETCH_DIM, b
        tally[state] += 1
        cx = 12 + (i % cols) * cell_w
        cy = head_h + (i // cols) * cell_h
        sheet.paste(checker(box, box), (cx + pad, cy + pad))
        img, zoom = fit(show.px, box, box)
        paste_centred(sheet, img, cx + pad, cy + pad, box, box)
        d = ImageDraw.Draw(sheet)
        d.rectangle([cx + pad - 1, cy + pad - 1,
                     cx + pad + box, cy + pad + box],
                    outline=border, width=2 if state != "same" else 1)
        draw_cell_label(d, cx + pad, cy + pad + box + 3, box, f_small, [
            (f"{show.id} {show.label}", BONE),
            (f"{show.w}x{show.h} {zoom}", ETCH),
            ("" if state == "same" else state, border),
        ])

    head[3] = ("  ".join(f"{k}={v}" for k, v in tally.items()))
    draw_header(sheet, head, width, fonts)
    sheet.save(out)
    return sheet, tally


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

def repo_root(start: Path) -> Path:
    for p in [start, *start.parents]:
        if (p / "zero_sum.nimble").is_file():
            return p
    return start


def run_dump(root: Path, dump: Path, seed: int, ticks: int,
             variants: int) -> None:
    import tempfile
    src = root / "tools" / "art" / "dump_sprites.nim"
    if not src.is_file():
        raise SystemExit(f"preview: missing {src}")
    if shutil.which("nim") is None:
        raise SystemExit("preview: --build needs `nim` on PATH")
    with tempfile.TemporaryDirectory() as td:
        # Compile out of tree so no stray binary lands next to the sources.
        cmd = ["nim", "c", "-r", "--hints:off",
               f"-o:{Path(td) / 'dump_sprites'}", str(src),
               f"out={dump}", f"seed={seed}", f"ticks={ticks}",
               f"variants={variants}"]
        print("+ " + " ".join(cmd))
        r = subprocess.run(cmd, cwd=root)
    if r.returncode != 0:
        raise SystemExit(
            "preview: dump_sprites failed to build or run.\n"
            "         If this is a missing-dependency error, the nimby sync "
            "has not finished:\n"
            "         run `nimby sync nimby.lock` and try again.")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="preview.py",
        description="Contact sheets of every sprite render.nim puts on the wire")
    p.add_argument("--dump", default="docs/evidence/sprites",
                   help="dump directory written by dump_sprites.nim "
                        "(default docs/evidence/sprites)")
    p.add_argument("--out", default=None,
                   help="output directory for the sheets (default: --dump)")
    p.add_argument("--build", action="store_true",
                   help="run tools/art/dump_sprites.nim first")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--ticks", type=int, default=480)
    p.add_argument("--variants", type=int, default=2)
    p.add_argument("--box", type=int, default=88, help="cell size in px")
    p.add_argument("--cols", type=int, default=0, help="0 = auto")
    p.add_argument("--width", type=int, default=1100,
                   help="width of the 1:1 sheet")
    p.add_argument("--max-native", type=int, default=160,
                   help="sprites larger than this are omitted from the 1:1 "
                        "sheet (default 160)")
    p.add_argument("--zoom", type=int, default=4,
                   help="uniform zoom for the second flow sheet "
                        "(contact_<zoom>x.png; 1 = skip it, default 4)")
    p.add_argument("--filter", default="",
                   help="only sprites whose label contains this substring")
    p.add_argument("--ids", default="",
                   help="comma-separated sprite ids (ranges like 400-410 ok)")
    p.add_argument("--diff-against", default=None, metavar="DIR",
                   help="second dump directory; also writes contact_diff.png")
    p.add_argument("--no-1to1", action="store_true")
    p.add_argument("--stats-json", default=None,
                   help="write per-sprite statistics as JSON")
    p.add_argument("--selftest", action="store_true")
    return p


def parse_ids(spec: str) -> set[int] | None:
    if not spec:
        return None
    out: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


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

    print("preview selftest")

    # block_scale detects nearest-neighbour upscaling, which is the whole
    # point of the "still authored at 1x" flag.
    base = np.random.default_rng(7).integers(0, 255, (6, 6, 4), dtype=np.uint8)
    check("block_scale(1x art) == 1", block_scale(base) == 1)
    up2 = np.repeat(np.repeat(base, 2, axis=0), 2, axis=1)
    check("block_scale(2x upscale) == 2", block_scale(up2) == 2,
          str(block_scale(up2)))
    up4 = np.repeat(np.repeat(base, 4, axis=0), 4, axis=1)
    check("block_scale(4x upscale) == 4", block_scale(up4) == 4,
          str(block_scale(up4)))

    # fit(): integer zoom up, never fractional; area-average down.
    small = np.zeros((5, 5, 4), dtype=np.uint8)
    img, tag = fit(small, 88, 88)
    check("fit upscales by an integer", img.size == (85, 85) and tag == "x17",
          f"{img.size} {tag}")
    big = np.zeros((576, 576, 4), dtype=np.uint8)
    img, tag = fit(big, 88, 88)
    check("fit downscales oversize art into the box",
          img.size == (88, 88) and tag.startswith("/"), f"{img.size} {tag}")

    with tempfile.TemporaryDirectory() as td:
        dump = Path(td) / "dump"
        (dump / "png").mkdir(parents=True)
        sprites_meta = []
        rng = np.random.default_rng(3)
        for i, (sid, label, w, h) in enumerate(
                [(1, "arena", 32, 32), (90, "bush0", 12, 12),
                 (91, "bush1", 12, 12), (91, "proj_arrows", 8, 8)]):
            px = rng.integers(0, 255, (h, w, 4), dtype=np.uint8)
            name = f"png/s{sid:04}_{label}_0.png"
            Image.fromarray(px, "RGBA").save(dump / name)
            sprites_meta.append({
                "id": sid, "label": label, "w": w, "h": h,
                "defineCount": 1, "distinctVariants": 1, "dumpedVariants": 1,
                "firstTick": 0, "lastTick": 0, "fromInitPacket": True,
                "dimsVary": False,
                "variants": [{"file": name, "pixHash": f"{i:016X}",
                              "w": w, "h": h,
                              "compressedBytes": 100, "rawBytes": w * h * 4,
                              "defineCount": 1, "firstTick": 0,
                              "lastTick": 0}]})
        meta = {"rs": 2, "tilePxR": 12, "worldPxR": 576, "bodyW": 16,
                "bodyH": 24, "seed": 42, "ticksRun": 480, "updateFrames": 480,
                "updatePacketBytes": 1000, "uniqueSpriteIds": 3,
                "collisions": [{"id": 91, "labels": ["bush1", "proj_arrows"],
                                "winner": "proj_arrows"}],
                "sprites": sprites_meta}
        (dump / "sprites.json").write_text(json.dumps(meta))

        m, sprites = load_dump(dump)
        check("load_dump finds every variant", len(sprites) == 4,
              str(len(sprites)))
        stats(sprites, m)
        collide = [s for s in sprites if "COLLIDE" in s.flags]
        check("collisions propagate to sprite flags", len(collide) == 2,
              str([s.label for s in collide]))

        out = Path(td) / "sheet.png"
        sheet = contact_sheet(m, sprites, out, box=48)
        check("contact sheet renders", out.is_file() and sheet.width > 100,
              f"{sheet.size}")
        out1 = Path(td) / "one.png"
        s1 = one_to_one_sheet(m, sprites, out1, width=400, max_native=64)
        check("1:1 sheet renders", out1.is_file())

        # the zoomed sheet must be a *uniform nearest* upscale: same colours,
        # more rows. A smoothed or per-sprite zoom would fail one or the other.
        out4 = Path(td) / "four.png"
        s4 = one_to_one_sheet(m, sprites, out4, width=800, max_native=64,
                              zoom=4)
        check("zoom sheet is taller than the 1:1 sheet",
              s4.height > s1.height, f"{s4.height} vs {s1.height}")
        src = {tuple(c) for c in sprites[1].px[..., :3].reshape(-1, 3)}
        got = {tuple(c) for c in
               np.asarray(Image.fromarray(sprites[1].px, "RGBA")
                          .resize((sprites[1].w * 4, sprites[1].h * 4),
                                  Image.NEAREST))[..., :3].reshape(-1, 3)}
        check("zoom introduces no new colours", src == got,
              f"{len(src)} -> {len(got)}")

        # coverage, when the dump carries it, must reach the sheet header:
        # a sheet that silently omits a whole family is the failure mode.
        m_cov = dict(m)
        m_cov["coverage"] = {"declaredFamilies": 45, "presentFamilies": 44,
                             "declaredIds": 359, "emittedIds": 262,
                             "emptyFamilies": ["damage_numeral"],
                             "undeclaredEmittedIds": []}
        hl = header_lines(m_cov, sprites, "t")
        check("coverage reaches the header",
              any("NOT ON THIS SHEET" in ln and "damage_numeral" in ln
                  for ln in hl), str(hl[-3:]))

        # diff against a mutated copy of the same dump
        m2, sprites2 = load_dump(dump)
        stats(sprites2, m2)
        sprites2[0].pix_hash = "DEADBEEFDEADBEEF"     # changed
        sprites2.pop()                                 # removed
        outd = Path(td) / "diff.png"
        _, tally = diff_sheet(m2, sprites2, m, sprites, outd, box=48)
        check("diff classifies changed/removed/same",
              tally["changed"] == 1 and tally["removed"] == 1
              and tally["same"] == 2, str(tally))

    print(f"\n{'PASS' if failures == 0 else 'FAIL'}: {failures} failure(s)")
    return EXIT_OK if failures == 0 else EXIT_FAIL


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest()

    root = repo_root(Path.cwd())
    dump = Path(args.dump)
    if not dump.is_absolute():
        dump = root / dump
    if args.build:
        run_dump(root, dump, args.seed, args.ticks, args.variants)

    meta, sprites = load_dump(dump)
    ids = parse_ids(args.ids)
    if ids is not None:
        sprites = [s for s in sprites if s.id in ids]
    if args.filter:
        sprites = [s for s in sprites if args.filter in s.label]
    if not sprites:
        print("preview: no sprites matched", file=sys.stderr)
        return EXIT_USAGE
    stats(sprites, meta)

    out = Path(args.out) if args.out else dump
    if not out.is_absolute():
        out = root / out
    out.mkdir(parents=True, exist_ok=True)

    p = out / "contact_sheet.png"
    sheet = contact_sheet(meta, sprites, p, box=args.box, cols=args.cols)
    print(f"wrote {p}  {sheet.width}x{sheet.height}  ({len(sprites)} sprites)")

    if not args.no_1to1:
        p1 = out / "contact_1to1.png"
        s1 = one_to_one_sheet(meta, sprites, p1, width=args.width,
                              max_native=args.max_native)
        print(f"wrote {p1}  {s1.width}x{s1.height}")
        if args.zoom > 1:
            pz = out / f"contact_{args.zoom}x.png"
            # a wider page, or a 4x flow of ~260 sprites turns into a column
            sz = one_to_one_sheet(meta, sprites, pz, width=args.width * 2,
                                  max_native=args.max_native, zoom=args.zoom)
            print(f"wrote {pz}  {sz.width}x{sz.height}")

    if args.diff_against:
        other = Path(args.diff_against)
        if not other.is_absolute():
            other = root / other
        meta_old, old = load_dump(other)
        stats(old, meta_old)
        pd = out / "contact_diff.png"
        sd, tally = diff_sheet(meta, sprites, meta_old, old, pd,
                               box=args.box, cols=args.cols)
        print(f"wrote {pd}  {sd.width}x{sd.height}  "
              + "  ".join(f"{k}={v}" for k, v in tally.items()))

    if args.stats_json:
        rows = [{
            "id": s.id, "label": s.label, "variant": s.variant,
            "w": s.w, "h": s.h, "colours": s.colours,
            "compressedBytes": s.compressed, "rawBytes": s.raw,
            "blockScale": s.block_scale, "alphaHaze": s.alpha_haze,
            "dirtyTransparent": s.dirty_transparent,
            "opaquePx": s.opaque_px, "flags": s.flags,
        } for s in sprites]
        Path(args.stats_json).write_text(json.dumps(
            {"meta": {k: v for k, v in meta.items() if k != "sprites"},
             "sprites": rows}, indent=2))
        print(f"wrote {args.stats_json}")

    ones = [s for s in sprites if s.block_scale >= int(meta.get("rs", 1)) > 1]
    haze = [s for s in sprites if s.alpha_haze]
    print(f"\n{len(sprites)} images, "
          f"{meta.get('uniqueSpriteIds')} sprite ids")
    if meta.get("collisions"):
        for c in meta["collisions"]:
            print(f"  COLLISION id {c['id']}: " + " / ".join(c["labels"])
                  + f" -> client keeps '{c['winner']}'")
    cov = meta.get("coverage")
    if cov:
        print(f"  coverage: {cov.get('presentFamilies')}/"
              f"{cov.get('declaredFamilies')} declared sprite families "
              f"present, {cov.get('emittedIds')}/{cov.get('declaredIds')} "
              f"addressable ids emitted")
        for fam in cov.get("families", []):
            if fam["emitted"] == 0:
                print(f"    NOT ON THIS SHEET  {fam['family']:<22} "
                      f"ids {fam['lo']}..{fam['hi']} ({fam['declared']} ids)")
    if ones:
        print(f"  block-uniform at x{meta.get('rs')} — carries no detail "
              f"finer than RS, so it gains nothing from the supersample "
              f"({len(ones)} images):")
        for s in sorted(ones, key=lambda s: s.id):
            print(f"    {s.id:>4} {s.label:<18} {s.w}x{s.h}")
    if haze:
        print(f"  alpha haze in 1..23 (risk #2): {len(haze)} sprite(s), "
              f"{sum(s.alpha_haze for s in haze)} px")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
