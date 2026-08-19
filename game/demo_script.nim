## Step-1 scripted demo policy (shared by headless and the live server):
## slot 3 steps off early (mine), survivors drift to center after ignition.

import battle_royal/[types, sim]

proc driveScript*(s: var Sim) =
  if s.tick == 4:
    discard s.submitTalk(AgentId(0), tcBroadcast, -1,
      "sixteen of us, one crown. anyone want the fortress mouth?")
  if s.tick == 30:
    discard s.submitTalk(AgentId(1), tcBroadcast, -1, "east crates are claimed. cross me and find out")
  if s.tick == 60:
    discard s.submitTalk(AgentId(9), tcDm, 2, "truce until the ring closes?")
  if s.tick == 100:
    discard s.submitTalk(AgentId(2), tcDm, 9, "deal. south crates are mine")
  if s.tick == 10:
    s.submitAction(AgentId(3), Action(kind: akMove, dir: dN))
  if s.phase == phLive:
    for i in 0 .. 15:
      let a = s.agents[i]
      if a.alive and s.tick >= a.moveReadyTick:
        let cx = ArenaSize div 2
        let cy = ArenaSize div 2
        let dir =
          if a.pos.x < cx and a.pos.y < cy: dSE
          elif a.pos.x < cx and a.pos.y > cy: dNE
          elif a.pos.x > cx and a.pos.y < cy: dSW
          elif a.pos.x > cx and a.pos.y > cy: dNW
          elif a.pos.x < cx: dE
          elif a.pos.x > cx: dW
          elif a.pos.y < cy: dS
          else: dN
        s.submitAction(AgentId(i), Action(kind: akMove, dir: dir))
