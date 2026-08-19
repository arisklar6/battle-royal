## Static arena construction (DESIGN §2). Border, Fortress, pedestals are fixed;
## rock clusters are seeded (PRNG consumption order: rocks first — DESIGN §15.1).

import prng, types

type
  Arena* = object
    tiles*: array[ArenaSize, array[ArenaSize, TileKind]]

const
  FortressLo* = 20
  FortressHi* = 28
  ChamberLo* = 22
  ChamberHi* = 26
  ## Mouths (DESIGN §2.1): N/S at columns 23-24, E/W at rows 23-24.
  MouthLo* = 23
  MouthHi* = 24

proc inBounds*(p: Pos): bool =
  p.x >= 0 and p.x < ArenaSize and p.y >= 0 and p.y < ArenaSize

proc tile*(a: Arena, p: Pos): TileKind =
  if not inBounds(p): tkWall else: a.tiles[p.y][p.x]

proc blocksMovement*(k: TileKind): bool =
  k in {tkWall, tkRock, tkFortressWall}

proc blocksSight*(k: TileKind): bool =
  k in {tkWall, tkRock, tkFortressWall}

proc isFortressWallTile(x, y: int): bool =
  ## Fortress ring wall minus the four 2-tile mouths; interior stays ground.
  let onRing = (x == FortressLo or x == FortressHi or y == FortressLo or y == FortressHi) and
               x >= FortressLo and x <= FortressHi and y >= FortressLo and y <= FortressHi
  if not onRing:
    return false
  # mouth openings
  if (y == FortressLo or y == FortressHi) and x >= MouthLo and x <= MouthHi:
    return false
  if (x == FortressLo or x == FortressHi) and y >= MouthLo and y <= MouthHi:
    return false
  true

proc buildArena*(rng: var Prng): Arena =
  for y in 0 ..< ArenaSize:
    for x in 0 ..< ArenaSize:
      result.tiles[y][x] =
        if x == 0 or y == 0 or x == ArenaSize - 1 or y == ArenaSize - 1: tkWall
        elif isFortressWallTile(x, y): tkFortressWall
        else: tkGround
  for p in Pedestals:
    result.tiles[p.y][p.x] = tkPedestal

  # Rock clusters (DESIGN §2.3): 10 clusters, 2x2 or 3x2, rings 8-15 and 17-21
  # from center, min spacing 4 from Fortress, pedestals, and each other.
  const C = ArenaSize div 2
  var placed: seq[Pos] = @[]
  var attempts = 0
  while placed.len < 10 and attempts < 500:
    inc attempts
    let x = 2 + rng.rand(ArenaSize - 6)
    let y = 2 + rng.rand(ArenaSize - 6)
    let dx = x - C
    let dy = y - C
    let d2 = dx * dx + dy * dy
    let inRingA = d2 >= 64 and d2 <= 225      # 8..15
    let inRingB = d2 >= 289 and d2 <= 441     # 17..21
    if not (inRingA or inRingB):
      continue
    let w = 2 + rng.rand(2)                    # 2 or 3 wide
    let h = 2
    var ok = true
    for yy in y - 4 .. y + h + 3:
      for xx in x - 4 .. x + w + 3:
        let q = Pos(x: xx, y: yy)
        if not inBounds(q):
          continue
        if result.tiles[q.y][q.x] in {tkFortressWall, tkPedestal}:
          ok = false
    for prev in placed:
      if abs(prev.x - x) < w + 4 and abs(prev.y - y) < h + 4:
        ok = false
    if not ok:
      continue
    for yy in y ..< y + h:
      for xx in x ..< x + w:
        if inBounds(Pos(x: xx, y: yy)) and result.tiles[yy][xx] == tkGround:
          result.tiles[yy][xx] = tkRock
    placed.add(Pos(x: x, y: y))

proc staticMapRows*(a: Arena): seq[string] =
  for y in 0 ..< ArenaSize:
    var row = newStringOfCap(ArenaSize)
    for x in 0 ..< ArenaSize:
      row.add($a.tiles[y][x])
    result.add(row)
