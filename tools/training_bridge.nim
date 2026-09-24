## Train one Battle Royal seat against the shipped survival policy.
## The observation and actions use the same game-owned player protocol as /player.

import std/[json, os, strutils]
import battle_royal/[arena, obs, sim, types]
import ../player/baseline

const Directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var
  game: Sim
  contexts: array[16, Ctx]
  config: JsonNode
  decisionId: int
  maxTicks: int
  controlledSeat: int
  actions: seq[JsonNode]

proc seedOf(value: string): uint64 =
  result = 14695981039346656037'u64
  for ch in value:
    result = (result xor uint64(ord(ch))) * 1099511628211'u64
  result = result and 0x7fffffffffffffff'u64

proc makeActions(): seq[JsonNode] =
  result.add(%*{"type": "action", "do": "none"})
  for name in Directions:
    result.add(%*{"type": "action", "do": "move", "dir": name})
  for name in Directions:
    result.add(%*{"type": "action", "do": "attack", "dir": name})
  result.add(%*{"type": "action", "do": "pickup"})
  for slot in [SlotHand, SlotBody, 0, 1, 2, 3]:
    result.add(%*{"type": "action", "do": "drop", "slot": slot})
  for slot in 0 .. 3:
    result.add(%*{"type": "action", "do": "use", "slot": slot})
  result.add(%*{"type": "action", "do": "interact"})

proc legal(action: JsonNode): bool =
  if action["do"].getStr() == "none": return true
  if game.phase != phLive or not game.agents[controlledSeat].alive: return false
  let me = game.agents[controlledSeat]
  case action["do"].getStr()
  of "move":
    if me.moveReadyTick > game.tick: return false
    for i, name in Directions:
      if name == action["dir"].getStr():
        let delta = [Pos(x: 0, y: -1), Pos(x: 1, y: -1),
                     Pos(x: 1, y: 0), Pos(x: 1, y: 1),
                     Pos(x: 0, y: 1), Pos(x: -1, y: 1),
                     Pos(x: -1, y: 0), Pos(x: -1, y: -1)][i]
        return not blocksMovement(game.arena.tile(Pos(
          x: me.pos.x + delta.x, y: me.pos.y + delta.y)))
  of "attack": return me.attackReadyTick <= game.tick
  of "pickup":
    for ground in game.ground:
      if ground.pos == me.pos: return true
  of "drop":
    let slot = action["slot"].getInt()
    if slot == SlotHand: return me.hand != iNone
    if slot == SlotBody: return me.body != iNone
    return slot < me.packSlots and me.pack[slot].item != iNone
  of "use":
    let slot = action["slot"].getInt()
    return slot < me.packSlots and me.pack[slot].item != iNone
  of "interact":
    for bush in game.bushes:
      if bush.pos == me.pos and bush.charges > 0: return true
  else: raise newException(ValueError, "Unknown Battle Royal action")

proc current(): JsonNode =
  let observation = parseJson(observationJson(game, controlledSeat))
  var choices = newJArray()
  for action in actions:
    if legal(action): choices.add(action)
  let view = %*{"config": config, "observation": observation}
  %*{"kind": "decision", "game": "battle-royal", "decision_id": decisionId,
     "seat": 0, "engine_seat": controlledSeat, "turn": game.tick,
     "semantic_view": view, "inbox": observation["chat"],
     "messages": [
       {"role": "system", "content": "Survive Battle Royal. Choose one legal action for this tick."},
       {"role": "user", "content": $view}],
     "speech_messages": [], "action_schema": {"enum": choices},
     "typed_question": newJNull()}

proc itemCode(name: string): int =
  for item in ItemId:
    if $item == name: return ord(item)
  raise newException(ValueError, "Unknown Battle Royal item: " & name)

proc encoding(): JsonNode =
  let observation = parseJson(observationJson(game, controlledSeat))
  let you = observation["you"]
  let zone = observation["zone"]
  var values = newJArray()
  for number in [float(game.tick) / float(maxTicks),
                 float(controlledSeat) / 15.0,
                 float(you["pos"][0].getInt()) / 48.0,
                 float(you["pos"][1].getInt()) / 48.0,
                 float(you["hp"].getInt()) / 100.0,
                 float(you["stats"]["speed"].getInt()) / 10.0,
                 float(you["stats"]["strength"].getInt()) / 10.0,
                 float(you["stats"]["intelligence"].getInt()) / 10.0,
                 float(you["stats"]["athleticism"].getInt()) / 10.0,
                 float(itemCode(you["hand"]["id"].getStr())) / float(ord(high(ItemId))),
                 float(if you["body"].kind == JNull: 0 else:
                   itemCode(you["body"].getStr())) / float(ord(high(ItemId))),
                 float(zone["radius"].getInt()) / 48.0,
                 float(zone["next_radius"].getInt()) / 48.0,
                 float(zone["center"][0].getInt()) / 48.0,
                 float(zone["center"][1].getInt()) / 48.0,
                 float(max(0, zone["shrink_tick"].getInt() - game.tick)) / float(maxTicks),
                 float(you["move_ready_in"].getInt()) / 100.0,
                 float(you["attack_ready_in"].getInt()) / 100.0,
                 float(you["kills"].getInt()) / 15.0,
                 float(observation["chat"].len) / 16.0,
                 float(observation["events"].len) / 16.0]:
    values.add(%number)
  for index in 0 .. 3:
    if index < you["pack"].len and you["pack"][index].kind != JNull:
      values.add(%(float(itemCode(you["pack"][index]["id"].getStr())) /
        float(ord(high(ItemId)))))
      values.add(%(float(you["pack"][index]["n"].getInt()) / 20.0))
    else:
      values.add(%0)
      values.add(%0)
  for slot in 0 .. 15:
    if slot == controlledSeat: continue
    var seen = newJNull()
    for other in observation["visible"]["agents"]:
      if other["slot"].getInt() == slot: seen = other
    if seen.kind == JNull:
      for unused in 0 .. 8: values.add(%0)
    else:
      values.add(%1)
      values.add(%(float(seen["pos"][0].getInt()) / 48.0))
      values.add(%(float(seen["pos"][1].getInt()) / 48.0))
      values.add(%(case seen["hp_band"].getStr()
        of "healthy": 1.0
        of "hurt": 0.5
        else: 0.0))
      values.add(%(if seen["netted"].getBool(): 1 else: 0))
      values.add(%(if seen["poisoned"].getBool(): 1 else: 0))
      values.add(%(float(itemCode(seen["hand"].getStr())) /
        float(ord(high(ItemId)))))
      values.add(%(float(if seen["body"].kind == JNull: 0 else:
        itemCode(seen["body"].getStr())) / float(ord(high(ItemId)))))
      values.add(%(if seen["channeling"].getBool(): 1 else: 0))
  for index in 0 .. 15:
    if index < observation["visible"]["items"].len:
      let item = observation["visible"]["items"][index]
      values.add(%1)
      values.add(%(float(item["pos"][0].getInt()) / 48.0))
      values.add(%(float(item["pos"][1].getInt()) / 48.0))
      values.add(%(float(itemCode(item["id"].getStr())) / float(ord(high(ItemId)))))
      values.add(%(float(item["n"].getInt()) / 20.0))
    else:
      for unused in 0 .. 4: values.add(%0)
  for index in 0 .. 7:
    if index < observation["visible"]["bushes"].len:
      let bush = observation["visible"]["bushes"][index]
      values.add(%1)
      values.add(%(float(bush["pos"][0].getInt()) / 48.0))
      values.add(%(float(bush["pos"][1].getInt()) / 48.0))
      values.add(%(float(bush["charges"].getInt()) / 10.0))
    else:
      for unused in 0 .. 3: values.add(%0)
  for y in -4 .. 4:
    for x in -4 .. 4:
      let tile = game.arena.tile(Pos(
        x: you["pos"][0].getInt() + x,
        y: you["pos"][1].getInt() + y))
      values.add(%(float(ord(tile)) / float(ord(high(TileKind)))))
  var slots = newJArray()
  for action in actions:
    slots.add(if legal(action): action else: newJNull())
  %*{"decision_id": decisionId, "values": values, "actions": slots}

proc terminal(): JsonNode =
  let score = game.episodeScore(game.computePlacements(), AgentId(controlledSeat))
  %*{"kind": "terminal", "scores": {"0": score},
     "utilities": {"0": float(score) / 12.5 - 1.0}}

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == 1
  let seed = seedOf(request["seed"].getStr())
  controlledSeat = int(seed mod 16)
  game = initSim(parseSimConfig(%*{"seed": seed, "max_ticks": maxTicks,
    "freeze_ticks": min(240, maxTicks div 4)}, proc(): uint64 = seed))
  for seat in 0 .. 15:
    config = parseJson(playerConfigJson(game, seat))
    contexts[seat] = trainingContext(config)
    game.applyInputJson(AgentId(seat), trainingAllocation())
  config = parseJson(playerConfigJson(game, controlledSeat))
  while game.phase == phCountdown: game.step()
  decisionId = 0
  current()

proc handle(request: JsonNode): JsonNode =
  case request["kind"].getStr()
  of "reset": return reset(request)
  of "encode": return encoding()
  of "teacher":
    var action = trainingAction(contexts[controlledSeat],
      parseJson(observationJson(game, controlledSeat)))
    if not legal(action): action = actions[0]
    return %*{"response": $action}
  of "step":
    doAssert request["decision_id"].getInt() == decisionId
    let action = parseJson(request["response"].getStr())
    if action notin actions or not legal(action):
      return %*{"kind": "rejected", "reason": "Action is not legal"}
    game.applyInputJson(AgentId(controlledSeat), action)
    for seat in 0 .. 15:
      if seat == controlledSeat: continue
      if game.agents[seat].alive:
        game.applyInputJson(AgentId(seat),
          trainingAction(contexts[seat], parseJson(observationJson(game, seat))))
    game.step()
    inc decisionId
    return %*{"kind": "accepted", "action": action,
      "observation": (if game.phase == phEnded or not game.agents[controlledSeat].alive:
        terminal() else: current())}
  else: raise newException(ValueError, "Unknown bridge command")

when isMainModule:
  let args = commandLineParams()
  if args.len > 1: quit("usage: training_bridge [max_ticks]", 1)
  maxTicks = if args.len == 1: parseInt(args[0]) else: 9120
  actions = makeActions()
  for line in stdin.lines:
    echo $handle(parseJson(line))
