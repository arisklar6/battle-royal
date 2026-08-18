# Prompt specs — `tools/art/prompts/<group>.json`

One file per generation group. `generate.py <group>` reads
`tools/art/prompts/<group>.json` and writes PNGs to `art/raw/<group>/`.

Two accepted top-level shapes.

**Bare list** — everything stated per entry:

```json
[
  { "name": "carrier-sheet", "prompt": "…", "size": "2048x2048", "variants": 1 }
]
```

**Object with defaults** — preferred, because the AFTERGLOW constraint block
(`docs/ART_UPGRADE_PLAN.md` §3.2) has to land **verbatim** in every request body
and must not drift between entries:

```json
{
  "defaults": {
    "model": "gemini-3-pro-image",
    "size": "2048x2048",
    "variants": 1,
    "prompt_prefix": "Orthographic front view, straight on, no perspective…",
    "prompt_suffix": "Palette, strictly: …"
  },
  "prompts": [
    { "name": "carrier-sheet", "prompt": "A 2x2 grid of four views of one …" }
  ]
}
```

`prompt_prefix` and `prompt_suffix` are joined to the entry's `prompt` with blank
lines, in that order, before hashing — so editing the prefix invalidates the
cache for every entry in the group, which is correct.

## Entry fields

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Output filename stem. `[A-Za-z0-9._-]` only, unique in the group. |
| `prompt` | yes | The subject text. Prefix/suffix are added around it. |
| `size` | no | See below. Default `1:1` @ `2K`. |
| `variants` | no | How many images to ask for. Default 1. |
| `model` | no | Per-entry model override. `--model` beats it. |
| `seed` | no | Passed through as `generationConfig.seed`. |
| `temperature` | no | Passed through as `generationConfig.temperature`. |
| `notes` | no | Carried into `_manifest.json`. Not sent to the API. |

Any other key is ignored by `generate.py` and copied nowhere — put crop rects in
`art/sheets.json`, not here (plan §3.3: segmentation is hand-verified).

## `size`

The API takes an **aspect ratio plus a size token**, not exact pixels. The
loader accepts whichever form is clearest and converts:

| You write | Becomes |
|---|---|
| `"2048x2048"` | nearest supported ratio (`1:1`) + smallest token covering the long edge (`2K`) |
| `"1536x1152"` | `4:3` + `2K` |
| `"2K"` | `1:1` @ `2K` |
| `"16:9"` | `16:9` @ `2K` |
| `{"aspect_ratio": "3:4", "image_size": "2K"}` | exactly that |

Supported `aspectRatio`: `1:1 2:3 3:2 3:4 4:3 4:5 5:4 9:16 16:9 21:9 1:4 4:1 1:8 8:1`
Supported `imageSize`: `512px 1K 2K 4K`

**The emitted size is measured, not assumed.** `generate.py` opens the returned
PNG, records `actual_px` in `art/raw/<group>/_manifest.json`, and prints a
warning if it differs from the estimate. Cut `art/sheets.json` crop rects against
`actual_px` — the plan's hard rule (`crop.w / target.w == crop.h / target.h ==
2^k, k >= 2`) is only checkable once the true dimensions are known.

## Variants

`variants: 1` writes `<name>.png`. `variants: 3` writes `<name>-01.png`,
`<name>-02.png`, `<name>-03.png` — the same request body sent three times, so
they are three different draws of one prompt. Cache keys are per output file, so
`--only <name> --force` regenerates all of that entry's variants and nothing else.

Per plan §2: variants are for assets that should **differ** (rock clusters,
pedestal states). Never use variants where code can stamp the difference — team
hue, parity pip, bob frame and fade stages are all code.

## Caching

`art/raw/<group>/_manifest.json` records the sha256 of the exact request body
that produced each PNG. Re-running with an unchanged prompt makes **zero API
calls**. The manifest is committed alongside the PNGs, so a fresh clone inherits
the cache. `--force` re-bills; use it deliberately.
