## Ring-closure invariant (spec §3: "After t=7536 there is NO safe tile").
## Regression tests for the degenerate r=0 boundary: without the r <= 0
## guard in insideZone, tile (24,24) satisfies 0 <= 0 and camping the
## fortress chamber center is a provably dominant endgame — the match
## never resolves.

import std/json
import battle_royal/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 9120,
                            "freeze_ticks": 48}, fixedSeed))

block no_safe_tile_at_full_closure:
  var s = mkSim()
  s.tick = 7600                       # past the default schedule's last doneT
  doAssert s.zoneRadius() == 0
  doAssert s.zoneDamagePerS() == 24
  var safe = 0
  for y in 0 ..< ArenaSize:
    for x in 0 ..< ArenaSize:
      if s.insideZone(Pos(x: x, y: y)):
        inc safe
  doAssert safe == 0, "expected zero safe tiles at r=0, got " & $safe

block boundary_still_correct_above_zero:
  var s = mkSim()
  s.tick = 7000                       # last stage, shrinking toward 0
  let r = s.zoneRadius()
  doAssert r > 0
  doAssert s.insideZone(Pos(x: ArenaSize div 2, y: ArenaSize div 2))
  doAssert not s.insideZone(Pos(x: 1, y: 1))

const DirDx = [0, 1, 1, 1, 0, -1, -1, -1]
const DirDy = [-1, -1, 0, 1, 1, 1, 0, -1]

proc blockedAt(s: Sim, x, y: int): bool =
  x < 0 or y < 0 or x >= ArenaSize or y >= ArenaSize or
  s.arena.tiles[y][x] in {tkWall, tkRock, tkFortressWall}

proc dirToward(s: Sim, fx, fy, tx, ty: int): int =
  ## Greedy unblocked step (baseline-bot style) — routes around rocks.
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

block center_campers_die_at_full_closure:
  ## End-to-end: agents 0 and 8 (teams A and E — pedestals on the E/W
  ## axis, straight path through the fortress mouths) both walk to the
  ## exact center and hold. Everyone else stands and burns. Pre-fix the
  ## tile-(24,24) holder survives full closure and wins by camping;
  ## post-fix the ring resolves everyone.
  var s = mkSim()
  let c = ArenaSize div 2
  var centerHpEarly = -1
  var centerHpLate = -1
  while s.phase != phEnded:
    if s.phase == phLive:
      for i in [0, 8]:
        let a = s.agents[i]
        if a.alive and s.tick >= a.moveReadyTick and
           (a.pos.x != c or a.pos.y != c):
          let d = s.dirToward(a.pos.x, a.pos.y, c, c)
          if d >= 0:
            s.submitAction(AgentId(i), Action(kind: akMove, dir: Dir8(d)))
    s.step()
    # sample the hp of whoever holds the exact center tile mid-closure:
    # pre-fix it is constant (the exploit), post-fix it drains at 24/s
    if s.tick == 7560 or s.tick == 7620:
      for i in [0, 8]:
        if s.agents[i].alive and s.agents[i].pos.x == c and
           s.agents[i].pos.y == c:
          if s.tick == 7560:
            centerHpEarly = s.agents[i].hpCenti
          else:
            centerHpLate = s.agents[i].hpCenti
  doAssert s.tick < 9120,
    "match hit the hard cap - closure did not resolve it (t=" & $s.tick & ")"
  doAssert centerHpEarly > 0 and centerHpLate > 0,
    "no camper held the center through closure - path assumption broken"
  doAssert centerHpLate < centerHpEarly,
    "center-tile hp did not drain during full closure - exploit is back"
  echo "ring closure ok: ended t=", s.tick, " center hp ",
       centerHpEarly, " -> ", centerHpLate

echo "t_ring_closure ok"
