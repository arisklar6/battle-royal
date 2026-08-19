## Results and human-readable match artifacts.

import std/json
import battle_royal/[types, sim]

proc sponsorLogJson*(s: Sim): string =
  ## DESIGN §14: every accept AND reject.
  var arr = newJArray()
  for r in s.sponsorLog:
    arr.add(%*{"tick_requested": r.tickRequested,
               "tick_landed": (if r.tickLanded >= 0: %r.tickLanded else: newJNull()),
               "sponsor": r.sponsor,
               "player": (if r.player in 0 .. 15: %r.player else: newJNull()),
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
  for i in 0 ..< s.cfg.numPlayers:
    let a = s.agents[i]
    scores.add(%s.episodeScore(places, i))
    placements.add(%places[i])
    kills.add(%a.kills)
    damage.add(%(a.damageDealtCenti div 100))
    survival.add(%(if a.alive: s.tick else: a.deathTick))
    gifts.add(%giftCount[i])
  let winnerSlot = s.winnerSlot
  $(%*{"scores": scores, "placements": placements, "kills": kills,
       "damage_dealt": damage, "survival_ticks": survival,
       "gifts_received": gifts,
       "winner_slot": winnerSlot,
       "match_ticks": s.tick, "seed": cast[int64](s.cfg.seed)})
