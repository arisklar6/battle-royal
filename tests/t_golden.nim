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
import battle_royal/[prng, types, arena, sim]

const GoldenSeeds = [1, 7, 42, 99, 1234]
const Checkpoints = [1000, 3000]     # plus the final tick, always

# (seed, checkpoint hashes..., final tick, final hash)
# Regenerated 2026-08-19 for the FFA rules change (DELIBERATE): no team
# layer (per-player sponsor purses resize the hashed budget array, the
# finale event moves to the last-two showdown, team chat is gone) and the
# scripted gift is player-addressed. Same seeds, same scripted episodes.
const GoldenHashes: array[5, (int, uint64, uint64, int, uint64)] = [
  (1, 0xD30458640B36BB0C'u64, 0x1D965A01A0510116'u64, 7632, 0x6B74490D05938DFE'u64),
  (7, 0x7FD6E55B4F8A530F'u64, 0x38A8A113BCB69F4B'u64, 7632, 0xDCB6129E6F276548'u64),
  (42, 0x804A90D7A27E32B8'u64, 0x2DFB31D1D33EF639'u64, 7632, 0x5C854246068EB5BB'u64),
  (99, 0x03102FD142564C78'u64, 0x1F422BDEB80BC978'u64, 7632, 0xC6A5DACE448DF91C'u64),
  (1234, 0x73E5FF5A2650FF8E'u64, 0xF1725E942C33FC25'u64, 7632, 0x0E26468989C26CEF'u64)]

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
    "sponsor": {"live": true, "budget_per_player": 300,
                 "shop_opens_tick": 1680}}, minted))
  var cp: array[2, uint64]
  while s.phase != phEnded:
    if s.tick == s.cfg.sponsor.shopOpensTick + 24:
      discard s.requestGift("golden", 0, "blowgun", Pos(x: 30, y: 24))
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
