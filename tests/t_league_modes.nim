## Platform league boundary: Solo is identity seating with individual scores;
## Duos maps team_n's i/i+8 seats onto adjacent internal teams and emits a
## duplicated team total so the platform's per-policy mean is the sum.

import std/json
import zero_sum/[types, sim, obs]
import ../game/bundle

proc fixedSeed(): uint64 = 42'u64

block seat_bijection:
  for external in 0 .. 15:
    let internal = internalSlot(lmDuos, AgentId(external))
    doAssert externalSlot(lmDuos, internal) == AgentId(external)
  for teamIdx in 0 .. 7:
    doAssert internalSlot(lmDuos, AgentId(teamIdx)) == AgentId(2 * teamIdx)
    doAssert internalSlot(lmDuos, AgentId(teamIdx + 8)) ==
      AgentId(2 * teamIdx + 1)

block config_and_external_names:
  var players = newJArray()
  for i in 0 .. 15:
    players.add(%*{"name": "External " & $i})
  let cfg = parseSimConfig(%*{
    "league_mode": "duos", "seed": 42, "max_ticks": 200,
    "freeze_ticks": 48, "players": players}, fixedSeed)
  doAssert cfg.leagueMode == lmDuos
  doAssert cfg.playerNames[0] == "External 0"
  doAssert cfg.playerNames[1] == "External 8"

block duos_team_total_results:
  var s = initSim(parseSimConfig(%*{
    "league_mode": "duos", "seed": 42, "max_ticks": 200,
    "freeze_ticks": 48}, fixedSeed))
  for i in 0 .. 15:
    s.agents[i].alive = false
    s.agents[i].deathTick = 100 - i
  s.agents[0].alive = true
  s.agents[0].kills = 1
  s.agents[1].kills = 2
  s.winnerSlot = 1
  let results = parseJson(resultsJson(s))
  let teamATotal = scoreFor(1, 1) + scoreFor(2, 2)
  doAssert results["scores"][0].getInt() == teamATotal
  doAssert results["scores"][8].getInt() == teamATotal
  doAssert results["winner_slot"].getInt() == 8
  doAssert parseJson(finalJson(s, 0))["score"].getInt() == teamATotal

block solo_results_stay_individual:
  var s = initSim(parseSimConfig(%*{
    "league_mode": "solo", "seed": 42, "max_ticks": 200,
    "freeze_ticks": 48}, fixedSeed))
  for i in 0 .. 15:
    s.agents[i].alive = false
    s.agents[i].deathTick = 100 - i
  s.agents[0].alive = true
  s.agents[0].kills = 1
  s.agents[1].kills = 2
  let results = parseJson(resultsJson(s))
  doAssert results["scores"][0].getInt() == scoreFor(1, 1)
  doAssert results["scores"][1].getInt() == scoreFor(2, 2)

echo "t_league_modes ok"
