## Step-10 tests: observation builder (fog, camo, bands, arena-wide events),
## wire-shape input parsing, minted-seed round trip (league integrity).

import std/[json, strutils]
import battle_royal/[prng, types, arena, sim, obs]

proc fixedSeed(): uint64 = 12345'u64

proc mkSim(): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 2000, "freeze_ticks": 48},
                         fixedSeed))

proc clearRect(s: var Sim, x0, x1, y0, y1: int) =
  for y in y0 .. y1:
    for x in x0 .. x1:
      if s.arena.tiles[y][x] in {tkRock, tkBush}:
        s.arena.tiles[y][x] = tkGround

block vision_and_fog:
  var s = mkSim()
  while s.phase == phCountdown: s.step()
  s.clearRect(4, 20, 4, 8)
  s.agents[0].pos = Pos(x: 5, y: 5)
  s.agents[1].pos = Pos(x: 8, y: 5)      # distance 3: inside vision 8
  s.agents[2].pos = Pos(x: 19, y: 5)     # distance 14: outside vision
  let o = parseJson(observationJson(s, 0))
  var seen: seq[int] = @[]
  for a in o["visible"]["agents"]:
    seen.add(a["slot"].getInt())
  doAssert 1 in seen
  doAssert 2 notin seen
  # hp_band privacy: no exact hp field on others
  for a in o["visible"]["agents"]:
    doAssert not a.hasKey("hp")
    doAssert a["hp_band"].getStr() in ["healthy", "hurt", "critical"]

block camo_detection:
  var s = mkSim()
  while s.phase == phCountdown: s.step()
  s.clearRect(4, 20, 14, 18)
  s.agents[3].pos = Pos(x: 5, y: 15)
  s.agents[3].stats.intelligence = 10       # vision 10
  s.agents[4].pos = Pos(x: 11, y: 15)       # distance 6
  s.agents[4].body = iCamo
  # stationary camo: cap 4 -> hidden at 6
  doAssert not s.canSee(3, 4)
  # attacking reveals
  s.agents[4].camoRevealedUntil = s.tick + 120
  doAssert s.canSee(3, 4)
  s.agents[4].camoRevealedUntil = 0
  # without camo: visible
  s.agents[4].body = iNone
  doAssert s.canSee(3, 4)
  # LOS blocked by walls: put a wall segment between two close agents
  s.agents[5].pos = Pos(x: 5, y: 17)
  s.agents[6].pos = Pos(x: 9, y: 17)
  s.arena.tiles[17][7] = tkRock
  doAssert not s.canSee(5, 6)

block arena_wide_events:
  var s = mkSim()
  while s.phase == phCountdown: s.step()
  # kill someone far from a fogged observer: death event must still appear
  s.agents[15].hpCenti = 0
  s.step()
  let o = parseJson(observationJson(s, 0))
  var sawDeath = false
  for e in o["events"]:
    if e["type"].getStr() == "death_fireworks":
      sawDeath = true
  doAssert sawDeath

block wire_shapes:
  var s = mkSim()
  # flat wire allocate
  s.applyInputJson(AgentId(0), parseJson(
    """{"type":"allocate_stats","speed":7,"strength":5,"intelligence":4,"athleticism":4}"""))
  doAssert s.agents[0].statsLocked and s.agents[0].stats.speed == 7
  # flat wire talk (FFA: broadcast and dm are the only channels; both
  # carry at any distance)
  s.applyInputJson(AgentId(1), parseJson(
    """{"type":"talk","channel":"broadcast","text":"wire format"}"""))
  doAssert s.talkLog.len == 1 and s.talkLog[0].channel == tcBroadcast
  s.applyInputJson(AgentId(1), parseJson(
    """{"type":"talk","channel":"team","text":"gone"}"""))
  doAssert s.talkLog.len == 1, "removed team channel must not parse"
  # wire action: applied for real (cleared ground, must move)
  while s.phase == phCountdown: s.step()
  s.clearRect(9, 11, 29, 31)
  s.agents[2].pos = Pos(x: 10, y: 30)
  s.agents[2].moveReadyTick = 0
  s.applyInputJson(AgentId(2), parseJson(
    """{"type":"action","do":"move","dir":"N"}"""))
  s.step()
  doAssert s.agents[2].pos == Pos(x: 10, y: 29)

block player_config_shape:
  var s = mkSim()
  let c = parseJson(playerConfigJson(s, 3))
  doAssert c["protocol"].getStr() == "battle_royal.player.v1"
  doAssert c["slot"].getInt() == 3
  doAssert c["mode"].getStr() == "ffa"
  doAssert c["num_players"].getInt() == 16
  doAssert c["arena"]["static_map"].len == ArenaSize
  doAssert c["arena"]["legend"].hasKey("P")
  doAssert c["stats"]["budget"].getInt() == 20
  doAssert c["sponsor"]["catalog"]["sword"].getInt() == 120

block full_64bit_seed_round_trip:
  ## Regression: a top-bit-set seed must survive JSON emission + re-parse
  ## (the competition-crash bug: %int64(uint64) raised RangeDefect).
  let original = %*{"max_ticks": 200, "freeze_ticks": 48}
  let big = 0xDEADBEEFCAFEBABE'u64
  let cfg = parseSimConfig(original, proc(): uint64 = big)
  doAssert cfg.seed == big
  let eff = parseJson(effectiveConfigJson(cfg, original))
  let cfg2 = parseSimConfig(eff, proc(): uint64 = 1'u64)
  doAssert cfg2.seed == big                        # wrapped round trip
  var a = initSim(cfg)
  var b = initSim(cfg2)
  for _ in 0 ..< 100:
    a.step()
    b.step()
  doAssert a.hashes == b.hashes

block minted_seed_round_trip:
  ## League-integrity test (owner directive): seedless run -> effective config
  ## carries the minted seed -> re-run from it -> identical hash streams.
  let original = %*{"max_ticks": 400, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, fixedSeed)   # "minted" = 12345
  doAssert cfg.seedWasMinted
  var live = initSim(cfg)
  for _ in 0 ..< 300:
    live.step()
  let effective = parseJson(effectiveConfigJson(cfg, original))
  doAssert effective["seed"].getBiggestInt() == 12345
  let cfg2 = parseSimConfig(effective, proc(): uint64 = 999'u64)
  doAssert not cfg2.seedWasMinted                  # seed came from the config
  var rerun = initSim(cfg2)
  for _ in 0 ..< 300:
    rerun.step()
  doAssert live.hashes == rerun.hashes

echo "t_step10 ok"
