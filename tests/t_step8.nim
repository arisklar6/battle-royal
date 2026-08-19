## Step-8 tests: placement ordering + tiebreaks, scoring table, FFA finale
## event, results shape via sim-side scoring procs.

import std/json
import battle_royal/[prng, types, arena, sim]

proc fixedSeed(): uint64 = 42'u64

proc mkSim(): Sim =
  initSim(parseSimConfig(%*{"seed": 42, "max_ticks": 9120, "freeze_ticks": 48},
                         fixedSeed))

block scoring_table:
  # FFA scoring: survival credit (one point per opponent outlasted) plus
  # the podium bonus 10/5/2 — and NOTHING for kills.
  let s = mkSim()
  doAssert PodiumBonus == [10, 5, 2]
  doAssert s.scoreFor(1) == 15 + 10   # 16 players: outlasted 15, gold bonus
  doAssert s.scoreFor(2) == 14 + 5
  doAssert s.scoreFor(3) == 13 + 2
  doAssert s.scoreFor(4) == 12        # off the podium: survival only
  doAssert s.scoreFor(16) == 0
  var s4 = initSim(parseSimConfig(%*{
    "seed": 42, "max_ticks": 9120, "freeze_ticks": 48, "num_players": 4},
    fixedSeed))
  doAssert s4.scoreFor(1) == 3 + 10   # scales with the head count
  doAssert s4.scoreFor(4) == 0

block placement_ordering:
  var s = mkSim()
  # kill agents at staggered ticks: slot 3 first, then 7, then 11
  s.agents[3].deathTick = 100; s.agents[3].alive = false
  s.agents[7].deathTick = 200; s.agents[7].alive = false
  s.agents[11].deathTick = 300; s.agents[11].alive = false
  # everyone else "dies" at tick 400 with varying damage; slot 0 stays alive
  for i in 0 .. 15:
    if i notin [0, 3, 7, 11]:
      s.agents[i].deathTick = 400
      s.agents[i].alive = false
      s.agents[i].damageDealtCenti = i * 100    # higher slot -> more damage
  let p = s.computePlacements()
  doAssert p[0] == 1                  # winner
  doAssert p[3] == 16                 # first death = last place
  doAssert p[7] == 15
  doAssert p[11] == 14
  # among the tick-400 cohort: damage desc, so slot 15 places best (2nd)
  doAssert p[15] == 2
  doAssert p[1] == 13                 # lowest damage in cohort -> worst of them
  # same-tick same-damage falls to slot asc
  var s2 = mkSim()
  for i in 0 .. 15:
    s2.agents[i].alive = false
    s2.agents[i].deathTick = 50
    s2.agents[i].damageDealtCenti = 0
  let p2 = s2.computePlacements()
  doAssert p2[0] == 1 and p2[15] == 16

block finale_event:
  # FFA finale: the last-two showdown, emitted once when 2 remain.
  var s = mkSim()
  while s.phase == phCountdown:
    s.step()
  for i in 2 .. 15:
    s.agents[i].hpCenti = 0
  s.step()
  var sawFinale = false
  for e in s.events:
    if e.kind == evFinale:
      sawFinale = true
  doAssert sawFinale
  doAssert s.phase == phLive          # match continues to a single winner
  # only emitted once
  s.step()
  for e in s.events:
    doAssert e.kind != evFinale
  s.agents[1].hpCenti = 0
  s.step()
  doAssert s.phase == phEnded
  doAssert s.winnerSlot == 0

block gifts_received_and_scores_align:
  var s = initSim(parseSimConfig(%*{
    "seed": 42, "max_ticks": 2000, "freeze_ticks": 48,
    "sponsor": {"live": false, "budget_per_player": 300, "shop_opens_tick": 60,
                 "scripted_gifts": [
                   {"tick": 70, "player": 0, "item_id": "rations"},
                   {"tick": 100, "player": 0, "item_id": "net"}]}},
    fixedSeed))
  while s.tick < 150:
    s.step()
  var accepted = 0
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.recipientSlot == 0:
      inc accepted
  doAssert accepted == 2
  doAssert s.playerBudget[0] == 300 - 20 - 50

echo "t_step8 ok"
