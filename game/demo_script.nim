## Step-1 scripted demo policy (shared by headless and the live server):
## slot 3 steps off early (mine), survivors drift to center after ignition.

import zero_sum/[types, sim]

proc driveScript*(s: var Sim) =
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
