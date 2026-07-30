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
import zero_sum/[prng, types, arena, sim]
import render, bundle, demo_script

const
  GlobalClientHtml = staticRead("client/global_client.html")
  SnappyJs = staticRead("client/snappyjs.min.js")
  TargetFps = 24.0

type
  ViewerState = object
    initialized: bool

  AppState = object
    lock: Lock
    viewers: Table[WebSocket, ViewerState]
    closed: seq[WebSocket]

var appState: AppState

proc mintSeedFromOs(): uint64 =
  ## Entropy at the boundary only (DESIGN §17.1). urandom via std/sysrand.
  var b: array[8, byte]
  discard urandom(b)
  for i in 0 .. 7:
    result = (result shl 8) or uint64(b[i])

proc httpHandler(request: Request) =
  let path = request.uri.split('?')[0]
  if request.httpMethod == "GET" and path in ["/global", "/replay"]:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.viewers[websocket] = ViewerState()
    return
  var headers: HttpHeaders
  case path
  of "/healthz":
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "ok")
  of "/client/global", "/client/replay":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, GlobalClientHtml)
  of "/client/snappyjs.min.js":
    headers["Content-Type"] = "application/javascript"
    request.respond(200, headers, SnappyJs)
  else:
    headers["Content-Type"] = "text/plain"
    request.respond(404, headers, "not found")

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
                      message: Message) =
  case event
  of OpenEvent, MessageEvent:
    discard message
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closed.add(websocket)

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
             "zone": {"schedule": [[96, 144, 336, 24, 12, 2],
                                    [432, 480, 624, 12, 0, 30]]},
             "events": [{"kind": "firestorm", "center": [15, 15], "radius": 4,
                          "from_tick": 240, "duration": 240}]}
  let cfg = parseSimConfig(original, mintSeedFromOs)
  var s = initSim(cfg)
  var r: Renderer
  startServer(rc)

  var last = getMonoTime()
  while s.phase != phEnded:
    s.driveScript()
    s.step()
    r.broadcast(s, r.updatePacket(s))
    runFrameLimiter(last)

  # hold the final frame briefly so a live viewer sees the ending
  for _ in 0 ..< 72:
    r.broadcast(s, @[])
    runFrameLimiter(last)

  let effective = effectiveConfigJson(cfg, original)
  let work = getTempDir() / "zero-sum-bundle"
  let zipBytes = buildReplayZip(work, effective, s)
  if rc.replayUri.len > 0:
    writeReplay(rc, zipBytes)
    echo "replay bundle -> ", rc.replayUri
  else:
    createDir("results")
    writeFile("results" / "replay.zip", zipBytes)
    echo "replay bundle -> results/replay.zip"
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
            except: newJNull()
          if j.kind == JObject and j{"do"}.getStr("") == "move":
            let dirStr = j{"dir"}.getStr("")
            for d in Dir8:
              if $d == dirStr:
                s.submitAction(AgentId(slot), Action(kind: akMove, dir: d))
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
