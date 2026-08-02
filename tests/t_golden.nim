## Golden determinism corpus (review §2.2): scripted full episodes for a
## fixed seed set, asserted against committed tick hashes. Catches every
## unintended rules change, and — run on both Ubuntu and Windows in CI —
## proves cross-platform bit-exactness, the assumption the whole replay
## and certification story rests on.
##
## Regenerate after a DELIBERATE rules change:
##   nim c -r -d:goldenGen tests/t_golden.nim
## then paste the printed table over GoldenHashes below and explain the
## rules change in the same commit.

import std/[json, strutils]
import zero_sum/[prng, types, arena, sim]

const GoldenSeeds = [1, 7, 42, 99, 1234]
const Checkpoints = [1000, 3000]     # plus the final tick, always

# (seed, checkpoint hashes..., final tick, final hash)
# Generated 2026-08-01 under the ring-closure fix (r=0 has no safe tile);
# every scripted episode now resolves at full closure (t=7632).
const GoldenHashes: array[5, (int, uint64, uint64, int, uint64)] = [
  (1, 0xAC1A1E241656FC4C'u64, 0xF33FCEBA904737D6'u64, 7632, 0xF8DCBD4BE7E09A3E'u64),
  (7, 0x2B40D73CA16E0BEF'u64, 0x403631A80F54AC6B'u64, 7632, 0x5871FEB58F92DE88'u64),
  (42, 0x422F8D6318B35178'u64, 0x561580FCCD6EF079'u64, 7632, 0xD927F2C878CA5D5B'u64),
  (99, 0x43C9907314E688D8'u64, 0x6210CDC991808C98'u64, 7632, 0xF56D930F098DCEDC'u64),
  (1234, 0xA285EEBAF474CC4E'u64, 0x168276F0056DEA65'u64, 7632, 0xA1BC8B3D533EA8CF'u64)]

const DirDx = [0, 1, 1, 1, 0, -1, -1, -1]
const DirDy = [-1, -1, 0, 1, 1, 1, 0, -1]

proc blockedAt(s: Sim, x, y: int): bool =
  x < 0 or y < 0 or x >= ArenaSize or y >= ArenaSize or
  s.arena.tiles[y][x] in {tkWall, tkRock, tkFortressWall}

proc dirToward(s: Sim, fx, fy, tx, ty: int): int =
  result = -1
  var bestD = int.high
  for d in 0 .. 7:
    let nx = fx + DirDx[d]
    let ny = fy + DirDy[d]
    if s.blockedAt(nx, ny):
      continue
    let dd = (nx - tx) * (nx - tx) + (ny - ty) * (ny - ty)
    if dd < bestD:
      bestD = dd
      result = d

proc runEpisode(seed: int): (uint64, uint64, int, uint64) =
  ## Deterministic scripted episode: everyone drifts to center on their
  ## move cooldown (fights, loot walks, ring burn), one sponsor gift
  ## exercises the pod pipeline.
  var minted = proc(): uint64 = 0'u64
  var s = initSim(parseSimConfig(%*{
    "seed": seed, "max_ticks": 9120, "freeze_ticks": 48,
    "sponsor": {"live": true, "budget_per_team": 300,
                 "shop_opens_tick": 1680}}, minted))
  var cp: array[2, uint64]
  while s.phase != phEnded:
    if s.tick == s.cfg.sponsor.shopOpensTick + 24:
      discard s.requestGift("golden", 0, -1, "blowgun", Pos(x: 30, y: 24))
    if s.phase == phLive:
      let c = ArenaSize div 2
      for i in 0 .. 15:
        let a = s.agents[i]
        if a.alive and s.tick >= a.moveReadyTick and
           (a.pos.x != c or a.pos.y != c):
          let d = s.dirToward(a.pos.x, a.pos.y, c, c)
          if d >= 0:
            s.submitAction(AgentId(i), Action(kind: akMove, dir: Dir8(d)))
    s.step()
    for i, t in Checkpoints:
      if s.tick == t:
        cp[i] = s.hashes[^1][1]
  (cp[0], cp[1], s.hashes[^1][0], s.hashes[^1][1])

when defined(goldenGen):
  echo "const GoldenHashes: array[5, (int, uint64, uint64, int, uint64)] = ["
  for i, seed in GoldenSeeds:
    let (a, b, ft, fh) = runEpisode(seed)
    echo "  (", seed, ", 0x", toHex(a), "'u64, 0x", toHex(b), "'u64, ",
         ft, ", 0x", toHex(fh), "'u64)",
         (if i < GoldenSeeds.len - 1: "," else: "]")
else:
  for (seed, g1, g2, gft, gfh) in GoldenHashes:
    let (a, b, ft, fh) = runEpisode(seed)
    doAssert a == g1 and b == g2 and ft == gft and fh == gfh,
      "GOLDEN MISMATCH seed=" & $seed &
      " got cp1=0x" & toHex(a) & " cp2=0x" & toHex(b) &
      " final(t=" & $ft & ")=0x" & toHex(fh) &
      " — a rules change happened; if deliberate, regenerate with -d:goldenGen"
    echo "golden ok seed=", seed, " final t=", ft
  echo "t_golden ok"
