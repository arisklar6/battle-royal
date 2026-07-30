## Zero Sum game server — step-1 scope.
## Live mode: runs the scripted demo episode at 24 Hz, streams sprite_v1 to
## /global viewers, writes the replay bundle on match end, exits 0.
## Replay mode (COGAME_LOAD_REPLAY_URI / --load-replay): re-simulates from the
## recorded effective config + input log, streams to /replay, autoplay + loop.
## Note: /replay?uri= overrides are accepted but the stream source is the
## loaded replay (same file in both certifier flows); full per-uri loading is
## Phase D polish.

import std/[json, locks, monotimes, os, strutils, sysrand, tables, times]
import mummy
import bitworld/[replays, runtime, spriteprotocol]
import zero_sum/[prng, types, arena, sim, obs]
import render, bundle, demo_script, transcript

const
  GlobalClientHtml = staticRead("client/global_client.html")
  SnappyJs = staticRead("client/snappyjs.min.js")
  TargetFps = 24.0

const SponsorClientHtml = staticRead("client/sponsor_client.html")
const PlayerClientHtml = staticRead("client/player_client.html")

type
  ViewerState = object
    initialized: bool

  SponsorReq = object
    ws: WebSocket
    teamIdx: int
    payload: string

  AppState = object
    lock: Lock
    viewers: Table[WebSocket, ViewerState]
    closed: seq[WebSocket]
    sponsors: Table[WebSocket, int]      # ws -> team index
    sponsorQueue: seq[SponsorReq]
    sponsorLive: bool
    sponsorTokens: Table[string, string] # team name -> token (runtime config only)
    playerTokens: seq[string]            # per-slot, runner-injected
    players: Table[WebSocket, int]       # ws -> slot
    playerBySlot: array[16, WebSocket]   # valid only when slotConnected
    slotConnected: array[16, bool]
    playerQueue: seq[(int, string)]      # (slot, payload)
    playerJoined: seq[int]               # slots needing player_config

var appState: AppState

proc mintSeedFromOs(): uint64 =
  ## Entropy at the boundary only (DESIGN §17.1). urandom via std/sysrand.
  var b: array[8, byte]
  discard urandom(b)
  for i in 0 .. 7:
    result = (result shl 8) or uint64(b[i])

proc queryParam(uri, key: string): string =
  let parts = uri.split('?')
  if parts.len < 2:
    return ""
  for pair in parts[1].split('&'):
    let kv = pair.split('=')
    if kv.len == 2 and kv[0] == key:
      return kv[1]

proc httpHandler(request: Request) =
  let path = request.uri.split('?')[0]
  var headers: HttpHeaders
  if request.httpMethod == "GET" and path in ["/global", "/replay"]:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.viewers[websocket] = ViewerState()
    return
  if request.httpMethod == "GET" and path == "/player":
    # slot+token auth (platform contract: bad token MUST fail the upgrade)
    {.gcsafe.}:
      withLock appState.lock:
        let slotStr = queryParam(request.uri, "slot")
        let token = queryParam(request.uri, "token")
        var slot = -1
        try:
          slot = parseInt(slotStr)
        except CatchableError:
          discard
        if slot notin 0 .. 15 or slot >= appState.playerTokens.len or
           token.len == 0 or appState.playerTokens[slot] != token:
          headers["Content-Type"] = "text/plain"
          request.respond(401, headers, "bad slot/token")
          return
        let websocket = request.upgradeToWebSocket()
        # reconnect policy (DESIGN §10): a valid second connection replaces
        # the seat; the old socket is queued for closure
        if appState.slotConnected[slot]:
          appState.closed.add(appState.playerBySlot[slot])
          appState.players.del(appState.playerBySlot[slot])
        appState.playerBySlot[slot] = websocket
        appState.slotConnected[slot] = true
        appState.players[websocket] = slot
        appState.playerJoined.add(slot)
    return
  if request.httpMethod == "GET" and path == "/sponsor":
    # token-gated live ingress (DESIGN §11); refuse at upgrade on any mismatch
    {.gcsafe.}:
      withLock appState.lock:
        let live = appState.sponsorLive
        let teamName = queryParam(request.uri, "team")
        let token = queryParam(request.uri, "token")
        if not live or teamName notin appState.sponsorTokens or
           token.len == 0 or appState.sponsorTokens[teamName] != token:
          headers["Content-Type"] = "text/plain"
          request.respond(403, headers, "sponsor ingress disabled or bad token")
          return
        var teamIdx = -1
        for i, tn in TeamNames:
          if tn == teamName: teamIdx = i
        let websocket = request.upgradeToWebSocket()
        appState.sponsors[websocket] = teamIdx
    return
  case path
  of "/healthz":
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "ok")
  of "/client/global", "/client/replay":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, GlobalClientHtml)
  of "/client/player":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, PlayerClientHtml)
  of "/client/sponsor":
    {.gcsafe.}:
      withLock appState.lock:
        if not appState.sponsorLive:
          headers["Content-Type"] = "text/plain"
          request.respond(403, headers, "sponsor mode is not live")
          return
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, SponsorClientHtml)
  of "/client/snappyjs.min.js":
    headers["Content-Type"] = "application/javascript"
    request.respond(200, headers, SnappyJs)
  else:
    headers["Content-Type"] = "text/plain"
    request.respond(404, headers, "not found")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.sponsors:
          appState.sponsorQueue.add(SponsorReq(
            ws: websocket, teamIdx: appState.sponsors[websocket],
            payload: message.data))
        elif websocket in appState.players:
          appState.playerQueue.add((appState.players[websocket], message.data))
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closed.add(websocket)
        appState.sponsors.del(websocket)
        if websocket in appState.players:
          let slot = appState.players[websocket]
          if appState.slotConnected[slot] and
             appState.playerBySlot[slot] == websocket:
            appState.slotConnected[slot] = false
          appState.players.del(websocket)

type ServerThreadArgs = object
  server: ptr Server
  address: string
  port: int

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previous: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previous
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previous = getMonoTime()

proc broadcast(r: var Renderer, s: Sim, update: seq[uint8]) =
  var viewers: seq[(WebSocket, ViewerState)] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for ws in appState.closed:
        appState.viewers.del(ws)
      appState.closed.setLen(0)
      for ws, st in appState.viewers.pairs:
        viewers.add((ws, st))
  for (ws, st) in viewers:
    let packet = if st.initialized: update else: r.initPacket(s) & update
    try:
      ws.send(blobFromBytes(packet), BinaryMessage)
      {.gcsafe.}:
        withLock appState.lock:
          if ws in appState.viewers:
            appState.viewers[ws] = ViewerState(initialized: true)
    except:
      {.gcsafe.}:
        withLock appState.lock:
          appState.viewers.del(ws)

var
  httpServer: Server
  serverThread: Thread[ServerThreadArgs]

proc startServer(rc: RuntimeConfig) =
  initLock(appState.lock)
  appState.viewers = initTable[WebSocket, ViewerState]()
  httpServer = newServer(httpHandler, websocketHandler,
                         workerThreads = 4, tcpNoDelay = true)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(
    server: addr httpServer, address: rc.host, port: rc.port))
  httpServer.waitUntilReady()
  echo "zero_sum server on ", rc.host, ":", rc.port

proc runLive(rc: RuntimeConfig) =
  let original =
    if rc.config.len > 0: parseJson(rc.config)
    else: %*{"max_ticks": 720, "freeze_ticks": 48, "seed": 42,
             "demo_script": true,
             "zone": {"schedule": [[96, 144, 336, 24, 12, 2],
                                    [432, 480, 624, 12, 0, 30]]},
             "events": [{"kind": "firestorm", "center": [15, 15], "radius": 4,
                          "from_tick": 240, "duration": 240}],
             "sponsor": {"live": false, "budget_per_team": 300,
                          "shop_opens_tick": 96,
                          "scripted_gifts": [
                            {"tick": 90, "team": "A", "recipient_slot": 0,
                             "item_id": "rations"},
                            {"tick": 150, "team": "C", "recipient_slot": 5,
                             "item_id": "sword"},
                            {"tick": 200, "team": "B", "recipient_slot": 2,
                             "item_id": "first_aid"}]}}
  let cfg = parseSimConfig(original, mintSeedFromOs)
  var s = initSim(cfg)
  var r: Renderer
  startServer(rc)
  {.gcsafe.}:
    withLock appState.lock:
      appState.sponsorLive = cfg.sponsor.live
      if original.hasKey("sponsor") and
         original["sponsor"].hasKey("sponsor_tokens"):
        for teamName, tok in original["sponsor"]["sponsor_tokens"].pairs:
          appState.sponsorTokens[teamName] = tok.getStr()
      if original.hasKey("tokens"):
        for tok in original["tokens"]:
          appState.playerTokens.add(tok.getStr())
  let demoMode = original{"demo_script"}.getBool(false)

  var last = getMonoTime()
  var echoedTalks = 0
  var echoedGifts = 0
  while s.phase != phEnded:
    # live sponsor ingress: drain queued requests at the tick boundary
    var reqs: seq[SponsorReq] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        reqs = appState.sponsorQueue
        appState.sponsorQueue.setLen(0)
    for req in reqs:
      var reply = """{"type":"gift_result","accepted":false,"reason":"malformed"}"""
      try:
        let j = parseJson(req.payload)
        if j{"type"}.getStr() == "gift_request":
          let outc = s.requestGift("live:" & TeamNames[req.teamIdx],
            req.teamIdx, j{"recipient_slot"}.getInt(-1), j{"item_id"}.getStr(""))
          let reqId = j{"request_id"}.getStr("")
          reply =
            if outc.accepted:
              """{"type":"gift_result","request_id":""" & escapeJson(reqId) &
              ""","accepted":true,"cost":""" & $outc.cost &
              ""","balance":""" & $outc.balance &
              ""","lands_tick":""" & $outc.landsTick &
              ""","landing":[""" & $outc.landing.x & "," & $outc.landing.y & "]}"
            else:
              """{"type":"gift_result","request_id":""" & escapeJson(reqId) &
              ""","accepted":false,"reason":""" & escapeJson(outc.reason) &
              ""","balance":""" & $outc.balance & "}"
      except CatchableError:
        discard
      try:
        req.ws.send(reply, TextMessage)
      except CatchableError:
        discard
    # player intake: config for fresh joins, then queued inputs (first-wins)
    var joined: seq[int] = @[]
    var pinputs: seq[(int, string)] = @[]
    var conns: array[16, (bool, WebSocket)]
    {.gcsafe.}:
      withLock appState.lock:
        joined = appState.playerJoined
        appState.playerJoined.setLen(0)
        pinputs = appState.playerQueue
        appState.playerQueue.setLen(0)
        for i in 0 .. 15:
          conns[i] = (appState.slotConnected[i], appState.playerBySlot[i])
    for slot in joined:
      if conns[slot][0]:
        try:
          conns[slot][1].send(playerConfigJson(s, slot), TextMessage)
        except CatchableError:
          discard
    for (slot, payload) in pinputs:
      let j =
        try: parseJson(payload)
        except CatchableError: nil
      s.applyInputJson(AgentId(slot), j)
    if demoMode:
      s.driveScript()
    s.step()
    # per-tick observations to connected, living players; final on death
    for i in 0 .. 15:
      if not conns[i][0]:
        continue
      try:
        if s.agents[i].alive:
          conns[i][1].send(observationJson(s, i), TextMessage)
        elif s.agents[i].deathTick == s.tick - 1:
          conns[i][1].send(finalJson(s, i), TextMessage)
      except CatchableError:
        discard
    # sponsor state push every 24 ticks
    if s.tick mod 24 == 0:
      var sponsorConns: seq[(WebSocket, int)] = @[]
      {.gcsafe.}:
        withLock appState.lock:
          for ws, ti in appState.sponsors.pairs:
            sponsorConns.add((ws, ti))
      for (ws, ti) in sponsorConns:
        var aliveArr = ""
        for i in 0 .. 15:
          if s.agents[i].alive and team(AgentId(i)) == ti:
            if aliveArr.len > 0: aliveArr.add(",")
            aliveArr.add($i)
        try:
          ws.send("""{"type":"sponsor_state","tick":""" & $s.tick &
                  ""","budget":""" & $s.teamBudget[ti] &
                  ""","shop_opens_tick":""" & $s.cfg.sponsor.shopOpensTick &
                  ""","team_alive":[""" & aliveArr & "]}", TextMessage)
        except CatchableError:
          discard
    while echoedGifts < s.sponsorLog.len:
      let g = s.sponsorLog[echoedGifts]
      echo "SPONSOR [t=", g.tickRequested, "] ", g.sponsor, " ", $g.status,
           " ", g.itemId, " -> P", g.recipientSlot, " (team ",
           TeamNames[g.team], ") cost=", g.cost,
           (if g.reason.len > 0: " reason=" & g.reason else: ""),
           " balance=", g.balanceAfter
      inc echoedGifts
    while echoedTalks < s.talkLog.len:
      echo "CHAT ", talkLine(s, s.talkLog[echoedTalks])
      inc echoedTalks
    r.broadcast(s, r.updatePacket(s))
    runFrameLimiter(last)

  # match over: final message to every connected player, then a short hold
  var endConns: array[16, (bool, WebSocket)]
  {.gcsafe.}:
    withLock appState.lock:
      for i in 0 .. 15:
        endConns[i] = (appState.slotConnected[i], appState.playerBySlot[i])
  for i in 0 .. 15:
    if endConns[i][0]:
      try:
        endConns[i][1].send(finalJson(s, i), TextMessage)
      except CatchableError:
        discard
  # hold the final frame briefly so a live viewer sees the ending
  for _ in 0 ..< 72:
    r.broadcast(s, @[])
    runFrameLimiter(last)

  let effective = effectiveConfigJson(cfg, original)
  let work = getTempDir() / "zero-sum-bundle"
  let zipBytes = buildReplayZip(work, effective, s)
  let results = resultsJson(s)
  if rc.resultsUri.len > 0:
    writeResults(rc, results)
    echo "results -> ", rc.resultsUri
  createDir("results")
  writeFile("results" / "results.json", results)
  if rc.replayUri.len > 0:
    writeReplay(rc, zipBytes)
    echo "replay bundle -> ", rc.replayUri
  else:
    writeFile("results" / "replay.zip", zipBytes)
    echo "replay bundle -> results/replay.zip"
  # local convenience copies next to results (DESIGN §13/§14)
  createDir("results")
  writeFile("results" / "chat_transcript.txt", buildTranscriptText(s))
  writeFile("results" / "chat_transcript.json", buildTranscriptJson(s))
  writeFile("results" / "sponsor_log.json", sponsorLogJson(s))
  echo "match over: winner=", s.winnerSlot, " ticks=", s.tick
  quit(0)

proc runReplay(rc: RuntimeConfig) =
  let work = getTempDir() / "zero-sum-replay"
  let loaded = loadReplayZip(rc.replay, work)
  echo "replay loaded: game=", loaded.data.gameName,
       " inputs=", loaded.data.clientInputs.len,
       " hashes=", loaded.data.hashes.len
  startServer(rc)

  # inputs grouped by tick once
  var inputsByTick = initTable[int, seq[(int, string)]]()
  for ci in loaded.data.clientInputs:
    var payload = newString(ci.packet.len)
    for i, b in ci.packet:
      payload[i] = char(b)
    inputsByTick.mgetOrPut(timeTick(ci.time, 24), @[]).add((int(ci.player), payload))

  var storedHash = initTable[int, uint64]()
  for h in loaded.data.hashes:
    storedHash[int(h.tick)] = h.hash

  var last = getMonoTime()
  while true:                                   # autoplay + LOOP
    let cfg = parseSimConfig(loaded.effectiveConfig, mintSeedFromOs)
    doAssert not cfg.seedWasMinted, "effective config must carry the seed"
    var s = initSim(cfg)
    var r: Renderer
    r.resetForLoop()
    {.gcsafe.}:
      withLock appState.lock:
        var keys: seq[WebSocket] = @[]
        for ws in appState.viewers.keys:
          keys.add(ws)
        for ws in keys:
          appState.viewers[ws] = ViewerState(initialized: false)
    while s.phase != phEnded:
      if s.tick in inputsByTick:
        for (slot, payload) in inputsByTick[s.tick]:
          let j =
            try: parseJson(payload)
            except CatchableError: nil
          if slot in 0 .. 15:
            s.applyInputJson(AgentId(slot), j)
      s.step()
      let expect = storedHash.getOrDefault(s.tick - 1, 0'u64)
      if expect != 0'u64 and expect != s.hashes[^1][1]:
        echo "HASH MISMATCH at tick ", s.tick - 1
        if rc.mismatchQuit:
          quit(1)
      r.broadcast(s, r.updatePacket(s))
      runFrameLimiter(last)
    for _ in 0 ..< 48:                          # end-of-loop beat
      r.broadcast(s, @[])
      runFrameLimiter(last)

when isMainModule:
  let rc = readRuntimeConfig()
  if rc.replayMode:
    runReplay(rc)
  else:
    runLive(rc)
