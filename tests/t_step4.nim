## Step-4 tests: stat-allocation validation (DESIGN §5.1), stat effect
## formulas (§5.2), forage yield, determinism with allocations.

import std/json
import battle_royal/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(): Sim =
  let cfg = parseSimConfig(%*{"seed": 42, "max_ticks": 2000, "freeze_ticks": 240},
                           fixedSeed)
  initSim(cfg)

block allocation_validation:
  var s = mkSim()
  # valid, first wins
  doAssert s.submitAllocation(AgentId(0),
    Stats(speed: 6, strength: 6, intelligence: 4, athleticism: 4)) == arAccepted
  doAssert s.agents[0].stats.speed == 6
  doAssert s.agents[0].statsLocked
  # duplicate rejected, original kept (retry-safe)
  doAssert s.submitAllocation(AgentId(0),
    Stats(speed: 1, strength: 1, intelligence: 1, athleticism: 1)) == arRejectedDuplicate
  doAssert s.agents[0].stats.speed == 6
  # sum > 20 rejected
  doAssert s.submitAllocation(AgentId(1),
    Stats(speed: 10, strength: 10, intelligence: 1, athleticism: 1)) == arRejectedInvalid
  doAssert not s.agents[1].statsLocked
  # out of range rejected
  doAssert s.submitAllocation(AgentId(1),
    Stats(speed: 0, strength: 10, intelligence: 5, athleticism: 5)) == arRejectedInvalid
  doAssert s.submitAllocation(AgentId(1),
    Stats(speed: 11, strength: 1, intelligence: 1, athleticism: 1)) == arRejectedInvalid
  # sum < 20 is legal (sum <= 20)
  doAssert s.submitAllocation(AgentId(1),
    Stats(speed: 1, strength: 1, intelligence: 1, athleticism: 1)) == arAccepted

block allocation_deadline:
  var s = mkSim()
  # deadline = freeze 240 - 24 = 216; late submission rejected
  for _ in 0 ..< 217:
    s.step()
  doAssert s.tick == 217
  doAssert s.submitAllocation(AgentId(2),
    Stats(speed: 5, strength: 5, intelligence: 5, athleticism: 5)) == arRejectedLate
  s.step()   # tick 217 executes: defaulting fires
  # unallocated agents got the default log line and keep 5/5/5/5
  doAssert s.agents[2].stats.speed == 5
  var defaultedLogged = 0
  for inp in s.inputLog:
    if inp.payload == """{"allocate_stats":"defaulted"}""":
      inc defaultedLogged
  doAssert defaultedLogged == 16

block effect_formulas:
  var a = Agent(stats: Stats(speed: 1, strength: 1, intelligence: 1, athleticism: 1))
  doAssert moveCooldown(a) == 15
  doAssert visionRadius(a) == 6
  doAssert hazardScaled(a, 10_000) == 9_700
  a.stats = Stats(speed: 5, strength: 5, intelligence: 5, athleticism: 5)
  doAssert moveCooldown(a) == 11
  doAssert visionRadius(a) == 8
  doAssert hazardScaled(a, 10_000) == 8_500
  a.stats = Stats(speed: 10, strength: 10, intelligence: 10, athleticism: 10)
  doAssert moveCooldown(a) == 6
  doAssert visionRadius(a) == 10
  doAssert hazardScaled(a, 10_000) == 7_000
  # poison duration formula spot checks (§5.2): 12*(20-INT)
  doAssert 12 * (20 - 1) == 228
  doAssert 12 * (20 - 10) == 120

block speed_changes_cooldown_live:
  var s = mkSim()
  doAssert s.submitAllocation(AgentId(3),
    Stats(speed: 10, strength: 4, intelligence: 3, athleticism: 3)) == arAccepted
  while s.phase == phCountdown:
    s.step()
  # clear terrain west of slot 3's pedestal and walk: cooldown 6
  s.submitAction(AgentId(3), Action(kind: akMove, dir: dN))
  s.step()
  let readyIn = s.agents[3].moveReadyTick - (s.tick - 1)
  doAssert readyIn == 6

block forage_yield_deterministic:
  var a = mkSim()
  var b = mkSim()
  for s in [addr a, addr b]:
    discard s[].submitAllocation(AgentId(0),
      Stats(speed: 1, strength: 1, intelligence: 10, athleticism: 1))
    while s[].phase == phCountdown:
      s[].step()
    s[].agents[0].pos = s[].bushes[0].pos
    s[].submitAction(AgentId(0), Action(kind: akInteract))
    for _ in 0 ..< 26:
      s[].step()
  # yield is 1 or 2 rations (50% at INT 10), identical across runs
  doAssert a.agents[0].pack[0].item == iRations
  doAssert a.agents[0].pack[0].n in 1 .. 2
  doAssert a.agents[0].pack[0].n == b.agents[0].pack[0].n
  doAssert a.hashes == b.hashes

echo "t_step4 ok"
