## Results and human-readable match artifacts.

import std/json
import zero_sum/[types, sim]

proc sponsorLogJson*(s: Sim): string =
  ## DESIGN §14: every accept AND reject.
  var arr = newJArray()
  for r in s.sponsorLog:
    arr.add(%*{"tick_requested": r.tickRequested,
               "tick_landed": (if r.tickLanded >= 0: %r.tickLanded else: newJNull()),
               "sponsor": r.sponsor,
               "team": (if r.team in 0 .. 7: %TeamNames[r.team] else: newJNull()),
               "recipient_slot": r.recipientSlot,
               "target": (if r.target.x >= 0: %[r.target.x, r.target.y]
                          else: newJNull()),
               "item": r.itemId,
               "cost": r.cost, "status": $r.status,
               "reason": (if r.reason.len > 0: %r.reason else: newJNull()),
               "balance_after": r.balanceAfter})
  $arr

proc resultsJson*(s: Sim): string =
  ## DESIGN §12.2 — schema-required scores + declared parallel arrays.
  var scores = newJArray()
  var placements = newJArray()
  var kills = newJArray()
  var damage = newJArray()
  var survival = newJArray()
  var gifts = newJArray()
  let places = s.computePlacements()
  var giftCount: array[16, int]
  for r in s.sponsorLog:
    if r.status == gsAccepted and r.recipientSlot in 0 .. 15:
      inc giftCount[r.recipientSlot]
  for external in 0 .. 15:
    let i = internalSlot(s.cfg.leagueMode, AgentId(external))
    let a = s.agents[i]
    scores.add(%s.episodeScore(places, i))
    placements.add(%places[i])
    kills.add(%a.kills)
    damage.add(%(a.damageDealtCenti div 100))
    survival.add(%(if a.alive: s.tick else: a.deathTick))
    gifts.add(%giftCount[i])
  let winnerTeam =
    if s.winnerSlot >= 0: %teamName(AgentId(s.winnerSlot)) else: newJNull()
  let winnerSlot =
    if s.winnerSlot >= 0:
      int(externalSlot(s.cfg.leagueMode, AgentId(s.winnerSlot)))
    else:
      -1
  $(%*{"scores": scores, "placements": placements, "kills": kills,
       "damage_dealt": damage, "survival_ticks": survival,
       "gifts_received": gifts,
       "winner_slot": winnerSlot, "winner_team": winnerTeam,
       "match_ticks": s.tick, "seed": cast[int64](s.cfg.seed)})
