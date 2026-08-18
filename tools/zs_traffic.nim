## Wire traffic report — measures what a match actually costs on the wire.
##
## Runs a headless episode through the REAL renderer and accounts every byte
## of every update packet by message kind and sprite id, so "80.3% of match
## traffic is the arena" is a measurement rather than a claim.
##
## Usage: zs_traffic [seed] [ticks] [script]
##   script: demo (default) | drift  (drift matches poster/t_golden)

import std/[algorithm, json, monotimes, os, strformat, strutils, tables, times]
import supersnappy
import bitworld/spriteprotocol
import zero_sum/[types, sim]
import render, demo_script

proc mintFixed(): uint64 = 42'u64

type Bucket = object
  bytes: int
  count: int

type Scene = object
  ## Just enough of a viewer to answer "does a late joiner see the same
  ## board?". Same decode and same painter's algorithm as tools/frame_dump.
  sprites: Table[int, (int, int, seq[uint8])]
  objects: OrderedTable[int, SpritePacketObject]

proc apply(scene: var Scene, packet: seq[uint8]) =
  for m in parseSpritePacket(packet):
    case m.kind
    of spkSprite:
      let raw = supersnappy.uncompress(m.sprite.compressedPixels)
      var px = newSeq[uint8](raw.len)
      for i in 0 ..< raw.len:
        px[i] = uint8(raw[i])
      scene.sprites[m.sprite.id] = (m.sprite.width, m.sprite.height, px)
    of spkObject: scene.objects[m.objectDef.id] = m.objectDef
    of spkDeleteObject: scene.objects.del(m.objectId)
    of spkClearObjects: scene.objects.clear()
    else: discard

proc composite(scene: Scene, maxZ: int): seq[uint8] =
  ## Board layers only, up to maxZ — the bands this phase moved (background,
  ## reclaimed overlay, trace) without the transient effects a late joiner
  ## has never been sent.
  result = newSeq[uint8](WorldPxR * WorldPxR * 4)
  var order: seq[SpritePacketObject] = @[]
  for _, o in scene.objects:
    if o.layer == LayerMap and o.z <= maxZ:
      order.add(o)
  order.sort(proc(a, b: SpritePacketObject): int =
    if a.z != b.z: cmp(a.z, b.z) else: cmp(a.id, b.id))
  for o in order:
    if o.spriteId notin scene.sprites: continue
    let (sw, sh, sp) = scene.sprites[o.spriteId]
    for y in 0 ..< sh:
      let dy = o.y + y
      if dy < 0 or dy >= WorldPxR: continue
      for x in 0 ..< sw:
        let dx = o.x + x
        if dx < 0 or dx >= WorldPxR: continue
        let si = (y * sw + x) * 4
        if si + 3 >= sp.len: continue
        let a = int(sp[si + 3])
        if a == 0: continue
        let di = (dy * WorldPxR + dx) * 4
        if a == 255:
          for c in 0 .. 3: result[di + c] = sp[si + c]
        else:
          for c in 0 .. 2:
            result[di + c] = uint8(
              (int(sp[si + c]) * a + int(result[di + c]) * (255 - a)) div 255)
          result[di + 3] = uint8(max(int(result[di + 3]), a))

when isMainModule:
  let seedArg = if paramCount() >= 1: parseBiggestInt(paramStr(1)) else: 42
  let ticksArg = if paramCount() >= 2: parseInt(paramStr(2)) else: 9120
  let scriptArg = if paramCount() >= 3: paramStr(3) else: "demo"

  ## "fixture" is the exact config tests/t_presentation_replay.nim records —
  ## the 480-tick artifact every byte budget in the plan is quoted against.
  let original =
    if scriptArg == "fixture":
      %*{"seed": seedArg, "max_ticks": 480, "freeze_ticks": 48,
         "zone": {"schedule": [[96, 120, 288, 24, 12, 4],
                                [336, 360, 384, 12, 0, 40]]},
         "sponsor": {"live": false, "budget_per_team": 300,
                     "shop_opens_tick": 48, "scripted_gifts": []}}
    else:
      %*{"seed": seedArg, "max_ticks": ticksArg, "freeze_ticks": 48}
  let cfg = parseSimConfig(original, mintFixed)
  var s = initSim(cfg)
  var r: Renderer
  let initPkt = r.initPacket(s)
  let initBytes = initPkt.len

  if scriptArg == "join":
    ## A viewer that streamed from tick 0 and a viewer that connects now must
    ## see the same board. The whole point of Phase 0 item 5 is that the
    ## reclaimed exterior stopped being baked into the arena sprite, so if
    ## initPacket forgot to carry it, a late joiner would watch a pristine
    ## board while the ring sat closed around everyone else.
    var streamed = Scene()
    var s3 = initSim(cfg)
    var r3: Renderer
    streamed.apply(r3.initPacket(s3))
    var worst = 0
    for probe in [600, 1500, 3000, 5000, 7000]:
      while s3.phase != phEnded and s3.tick < probe:
        s3.driveScript()
        s3.step()
        streamed.apply(r3.updatePacket(s3))
      if s3.tick < probe: break
      var joined = Scene()
      joined.apply(r3.initPacket(s3))
      var line = &"join at t={s3.tick}: "
      for maxZ in [1, 2, 3]:
        # z<=1 is background + reclaimed overlay (what item 5 moved),
        # z<=2 adds the Fortress mouth lights, z<=3 adds the trace overlay
        let a = streamed.composite(maxZ)
        let b = joined.composite(maxZ)
        var diff = 0
        for i in 0 ..< a.len:
          if a[i] != b[i]: inc diff
        if maxZ == 1:
          worst = max(worst, diff)
        line.add(&"z<={maxZ} diff={diff}  ")
      echo line, &"(objects streamed={streamed.objects.len} " &
           &"joined={joined.objects.len})"
    quit(if worst == 0: 0 else: 1)

  if scriptArg == "find":
    ## First tick each of the rescaled sprites is actually placed, so the
    ## before/after comparison can look at a frame that contains them.
    # render.nim keeps its sprite ids private, so name them here: channel
    # halo A/B, camo-reveal mark, settlement rule
    var want = {850: 0, 851: 0, 852: 0, 860: 0}.toTable
    var s4 = initSim(cfg)
    var r4: Renderer
    discard r4.initPacket(s4)
    while s4.phase != phEnded and s4.tick < ticksArg:
      s4.driveScript()
      s4.step()
      for o in spritePacketObjects(r4.updatePacket(s4)):
        if o.spriteId in want and want[o.spriteId] == 0:
          want[o.spriteId] = s4.tick
          echo &"sprite {o.spriteId} first placed at tick {s4.tick}"
    quit(0)

  if scriptArg == "connect":
    ## What a viewer connecting mid-match costs the tick thread. The tick
    ## budget at 24 Hz is 41.7 ms; this used to run the whole rasterizer.
    var s2 = initSim(cfg)
    var r2: Renderer
    let t0 = getMonoTime()
    let first = r2.initPacket(s2)
    let t1 = getMonoTime()
    for _ in 0 ..< 16:
      discard r2.initPacket(s2)
    let t2 = getMonoTime()
    echo &"first_connect_ms=" &
         &"{(t1 - t0).inMicroseconds.float / 1000.0:.2f}"
    echo &"per_later_connect_ms=" &
         &"{(t2 - t1).inMicroseconds.float / 16000.0:.2f}"
    echo &"init_packet_bytes={first.len}"
    quit(0)

  if scriptArg == "audit":
    ## Every sprite the init packet defines, in wire order. A repeated id is
    ## a collision: the client's sprite map is last-define-wins, so the
    ## earlier art is simply gone.
    var seen = initTable[int, string]()
    var order: seq[int] = @[]
    var dupes = 0
    for m in parseSpritePacket(initPkt):
      if m.kind != spkSprite: continue
      let d = &"{m.sprite.label} {m.sprite.width}x{m.sprite.height}"
      if m.sprite.id in seen:
        inc dupes
        echo &"COLLISION id={m.sprite.id}: {seen[m.sprite.id]} overwritten " &
             &"by {d}"
      else:
        order.add(m.sprite.id)
      seen[m.sprite.id] = d
    var ids = order
    ids.sort(cmp)
    var line = ""
    for id in ids:
      line.add(&"{id}:{seen[id].replace(\" \", \":\")} ")
    echo "defined ids (", ids.len, "): ", line
    echo "init_packet_bytes=", initBytes, " collisions=", dupes
    quit(if dupes == 0: 0 else: 1)

  var spriteBytes = initTable[int, Bucket]()
  var spriteLabel = initTable[int, string]()
  var objBytes = 0
  var objCount = 0
  var delBytes = 0
  var delCount = 0
  var otherBytes = 0
  var total = 0
  var frames = 0
  var largest = 0

  while s.phase != phEnded and s.tick < ticksArg:
    if scriptArg == "demo":
      s.driveScript()
    elif s.phase == phLive:
      let c = ArenaSize div 2
      for i in 0 .. 15:
        let a = s.agents[i]
        if a.alive and s.tick >= a.moveReadyTick:
          let dir =
            if a.pos.x < c and a.pos.y < c: dSE
            elif a.pos.x < c and a.pos.y > c: dNE
            elif a.pos.x > c and a.pos.y < c: dSW
            elif a.pos.x > c and a.pos.y > c: dNW
            elif a.pos.x < c: dE
            elif a.pos.x > c: dW
            elif a.pos.y < c: dS
            else: dN
          s.submitAction(AgentId(i), Action(kind: akMove, dir: dir))
    s.step()
    let packet = r.updatePacket(s)
    inc frames
    total += packet.len
    largest = max(largest, packet.len)
    var off = 0
    while off < packet.len:
      let n = spriteMessageBytes(packet, off)
      if n <= 0: break
      case packet[off]
      of SpriteMessageSprite:
        let id = packet.readU16(off + 1)
        var b = spriteBytes.getOrDefault(id)
        b.bytes += n
        b.count += 1
        spriteBytes[id] = b
        block labelCheck:
          let clen = packet.readU32(off + 7)
          let lOff = off + 11 + clen
          if lOff + 2 <= packet.len:
            let llen = packet.readU16(lOff)
            var lab = ""
            for i in 0 ..< llen:
              if lOff + 2 + i < packet.len:
                lab.add(char(packet[lOff + 2 + i]))
            # Two different families writing one id is a collision, whether
            # the ids are static or computed. Labels are stable per family
            # except for the deliberate double buffers (hud/kill/banner) and
            # the per-pod cargo text, which reuse an id by design.
            if id in spriteLabel and spriteLabel[id] != lab and
               not (lab.startsWith("hud") or lab.startsWith("kill") or
                    lab == "banner" or lab == "cargo" or lab == "dmg"):
              echo &"DYNAMIC COLLISION id={id}: {spriteLabel[id]} then {lab}"
            spriteLabel[id] = lab
      of SpriteMessageObject:
        objBytes += n
        inc objCount
      of SpriteMessageDeleteObject:
        delBytes += n
        inc delCount
      else:
        otherBytes += n
      off += n

  var rows: seq[(int, Bucket)] = @[]
  var defBytes = 0
  for id, b in spriteBytes:
    rows.add((id, b))
    defBytes += b.bytes
  rows.sort(proc(a, b: (int, Bucket)): int = cmp(b[1].bytes, a[1].bytes))

  echo &"seed={seedArg} script={scriptArg} ticks={s.tick} frames={frames}"
  echo &"init_packet_bytes={initBytes}"
  echo &"in_match_bytes={total} largest_packet={largest}"
  echo &"  sprite_defs={defBytes} ({defBytes * 100 div max(1, total)}%)  " &
       &"objects={objBytes} ({objCount})  deletes={delBytes} ({delCount})  " &
       &"other={otherBytes}"
  ## subtotal the families this phase moved: the arena (id 1) and the
  ## phosphor overlay (id 3 before, the 1100..1163 cell grid after)
  var arenaB = 0
  var traceB = 0
  for id, b in spriteBytes:
    if id == 1: arenaB += b.bytes
    elif id == 3 or id in 1100 .. 1163: traceB += b.bytes
  echo &"  arena_defs={arenaB} ({arenaB * 100 div max(1, total)}%)  " &
       &"trace_defs={traceB} ({traceB * 100 div max(1, total)}%)"
  echo "top sprite definitions by bytes:"
  for i in 0 ..< min(14, rows.len):
    let (id, b) = rows[i]
    echo &"  id={id:<5} {spriteLabel.getOrDefault(id, \"?\"):<12} " &
         &"bytes={b.bytes:<10} defs={b.count:<6} " &
         &"{b.bytes * 100 div max(1, total)}%"
