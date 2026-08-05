## Zero Sum game server: runs matches at 24 Hz, streams sprite_v1 to live
## viewers, records the same presentation packets for the static replay
## viewer, writes match artifacts, and exits.

import std/[json, locks, monotimes, os, strutils, sysrand, tables, times, uri]
when defined(posix):
  import std/posix
import mummy
import bitworld/[runtime, spriteprotocol]
import zero_sum/[types, arena, sim, obs]
import render, bundle, demo_script, transcript, analyst, presentation_replay

const
  GlobalClientHtml = staticRead("client/global_client.html")
  SnappyJs = staticRead("client/snappyjs.min.js")
  ReplayViewerJs = staticRead("client/replay_viewer.js")
  TargetFps = 24.0

const SponsorClientHtml = staticRead("client/sponsor_client.html")
const PlayerClientHtml = staticRead("client/player_client.html")
const AnalystClientHtml = staticRead("client/analyst_client.html")
const CockpitClientHtml = staticRead("client/cockpit.html")
const CoachPolicyPath = "coach_policy.json"

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
    sponsorJoined: seq[WebSocket]
    sponsorLive: bool
    sponsorTokens: Table[string, string] # team name -> token (runtime config only)
    playerTokens: seq[string]            # per-slot, runner-injected
    players: Table[WebSocket, int]       # ws -> slot
    playerBySlot: array[16, WebSocket]   # valid only when slotConnected
    slotConnected: array[16, bool]
    playerQueue: seq[(int, string)]      # (slot, payload)
    playerJoined: seq[int]               # slots needing player_config
    analysts: Table[WebSocket, bool]     # /analyst JSON telemetry feed
    watchers: Table[WebSocket, int]      # /watch read-only agent views (ws->slot)
    watcherJoined: seq[WebSocket]        # need player_config on next tick

var appState: AppState

# graceful shutdown (review §1.9): hosted evictions send SIGTERM; without a
# handler every artifact of a 9000-tick match is lost
var stopRequested = false

proc onStopSignal() {.noconv.} =
  stopRequested = true

when defined(posix):
  proc onTermSignal(sig: cint) {.noconv.} =
    stopRequested = true

proc installStopHandlers() =
  setControlCHook(onStopSignal)
  when defined(posix):
    signal(SIGTERM, onTermSignal)

const MaxViewers = 64
const MaxQueuedInputsPerSlot = 4

proc mintSeedFromOs(): uint64 =
  ## Entropy at the boundary only (DESIGN §17.1). urandom via std/sysrand.
  ## Masked to 63 bits so the seed always fits a JSON int64 cleanly (63 bits
  ## of entropy is ample; artifacts stay non-negative and human-friendly).
  var b: array[8, byte]
  discard urandom(b)
  for i in 0 .. 7:
    result = (result shl 8) or uint64(b[i])
  result = result and 0x7FFF_FFFF_FFFF_FFFF'u64

proc queryParam(uri, key: string): string =
  ## maxsplit=1: values may legally contain '=' (base64 token padding);
  ## naive split('=') silently failed auth for any such token.
  let parts = uri.split('?')
  if parts.len < 2:
    return ""
  for pair in parts[1].split('&'):
    let kv = pair.split('=', maxsplit = 1)
    if kv.len == 2 and kv[0] == key:
      return decodeUrl(kv[1])

# ops-endpoint gate (review §1.4): /coach is a local-play surface. Default
# CLOSED: enabled only with ZERO_SUM_LOCAL=1
# (the launcher sets it) or a matching ?token= against ZERO_SUM_OPS_TOKEN.
# Env is read per-call: handler threads must stay GC-safe.
proc opsAllowed(uri: string): bool =
  if getEnv("ZERO_SUM_LOCAL") == "1":
    return true
  let tok = getEnv("ZERO_SUM_OPS_TOKEN")
  tok.len > 0 and queryParam(uri, "token") == tok

proc redactUri(u: string): string =
  ## Presigned upload URIs are write credentials — never log them whole.
  try:
    let p = parseUri(u)
    p.scheme & "://" & p.hostname & "/..."
  except CatchableError:
    "<uri>"

proc isWsHandshake(request: Request): bool =
  ## Plain HTTP GETs on WS routes must get 2xx, not a 500 from a failed
  ## upgrade (platform validator does exactly that probe).
  var hasUpgrade = false
  for (k, v) in request.headers:
    if k.toLowerAscii() == "upgrade" and v.toLowerAscii() == "websocket":
      hasUpgrade = true
  hasUpgrade

proc httpHandler(request: Request) =
  let path = request.uri.split('?')[0]
  var headers: HttpHeaders
  if request.httpMethod == "GET" and
     path in ["/global", "/admin", "/analyst"] and
     not request.isWsHandshake():
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "zero_sum " & path & " websocket endpoint")
    return
  if path == "/coach":
    if not opsAllowed(request.uri):
      headers["Content-Type"] = "text/plain"
      request.respond(403, headers, "ops endpoint disabled")
      return
    # Coach-mode plan exchange (local play): the cockpit saves the human
    # coach's pre-match plan; the relauncher hands it to the two coached
    # bots. Content is whitelist-rebuilt — nothing client-sent is stored
    # verbatim except the capped notes string.
    if request.httpMethod == "GET":
      headers["Content-Type"] = "application/json"
      if fileExists(CoachPolicyPath):
        request.respond(200, headers, readFile(CoachPolicyPath))
      else:
        request.respond(404, headers, "{}")
      return
    if request.httpMethod == "POST":
      headers["Content-Type"] = "application/json"
      var ok = false
      try:
        let j = parseJson(request.body)
        let teamName = j{"team"}.getStr("")
        var teamIdx = -1
        for i, tn in TeamNames:
          if tn == teamName: teamIdx = i
        if teamIdx >= 0:
          var clean = %*{"team": teamName, "slots": newJObject(),
                          "policy": newJObject(), "notes": ""}
          for slot in [teamIdx * 2, teamIdx * 2 + 1]:
            let ss = j{"slots"}{$slot}
            var stats = %*{"speed": 6, "strength": 6,
                            "intelligence": 4, "athleticism": 4}
            if ss != nil and ss.kind == JObject:
              var total = 0
              for k in ["speed", "strength", "intelligence", "athleticism"]:
                let v = clamp(ss{k}.getInt(5), 1, 10)
                stats[k] = %v
                total += v
              if total > 20:
                stats = %*{"speed": 5, "strength": 5,
                            "intelligence": 5, "athleticism": 5}
            clean["slots"][$slot] = stats
          let p = j{"policy"}
          var pol = newJObject()
          pol["opening"] = %(if p{"opening"}.getStr("center") in
              ["center", "fortress", "outer", "forage"]:
            p{"opening"}.getStr("center") else: "center")
          pol["aggression"] = %clamp(p{"aggression"}.getInt(5), 0, 10)
          pol["heal_at"] = %clamp(p{"heal_at"}.getInt(60), 0, 100)
          pol["flee_at"] = %clamp(p{"flee_at"}.getInt(35), 0, 100)
          pol["ring_margin"] = %clamp(p{"ring_margin"}.getInt(1), 0, 4)
          pol["finale"] = %(if p{"finale"}.getStr("fight") in
              ["fight", "evade"]: p{"finale"}.getStr("fight") else: "fight")
          var loot = newJArray()
          if p{"loot_priority"} != nil and p{"loot_priority"}.kind == JArray:
            for it in p["loot_priority"]:
              if loot.len < 12 and it.getStr() in [
                  "sword", "spear", "bow", "knives", "blowgun", "net",
                  "first_aid", "rations", "backpack", "camouflage",
                  "arrows", "darts"]:
                loot.add(%it.getStr())
          pol["loot_priority"] = loot
          clean["policy"] = pol
          var notes = j{"notes"}.getStr("")
          if notes.len > 4000:
            notes.setLen(4000)
          clean["notes"] = %notes
          # the coach's raw prompt: stored verbatim (capped) so the cockpit
          # can re-show and re-interpret it next session
          var prompt = j{"prompt"}.getStr("")
          if prompt.len > 4000:
            prompt.setLen(4000)
          clean["prompt"] = %prompt
          writeFile(CoachPolicyPath, $clean)
          ok = true
      except CatchableError:
        ok = false
      request.respond(if ok: 200 else: 400, headers,
                      """{"ok":""" & $ok & "}")
      return
  if request.httpMethod == "GET" and path in ["/global", "/admin"]:
    var full = false
    {.gcsafe.}:
      withLock appState.lock:
        full = appState.viewers.len >= MaxViewers
    if full:
      headers["Content-Type"] = "text/plain"
      request.respond(503, headers, "viewer capacity reached")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.viewers[websocket] = ViewerState()
    return
  if request.httpMethod == "GET" and path == "/analyst":
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.analysts[websocket] = true
    return
  if request.httpMethod == "GET" and path == "/watch":
    # v0.2: read-only per-agent fog view. No token, no inputs — watching a
    # seat never touches the agent's own /player connection. Leaks nothing
    # the /global viewer doesn't already show.
    var slot = -1
    try:
      slot = parseInt(queryParam(request.uri, "slot"))
    except CatchableError:
      discard
    if slot notin 0 .. 15:
      headers["Content-Type"] = "text/plain"
      request.respond(400, headers, "bad slot")
      return
    if not request.isWsHandshake():
      headers["Content-Type"] = "text/plain"
      request.respond(200, headers, "zero_sum watch websocket endpoint")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.watchers[websocket] = slot
        appState.watcherJoined.add(websocket)
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
        if not request.isWsHandshake():
          headers["Content-Type"] = "text/plain"
          request.respond(200, headers, "zero_sum player websocket endpoint")
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
        var teamIdx = -1
        for i, tn in TeamNames:
          if tn == teamName: teamIdx = i
        if not live or teamIdx < 0 or teamName notin appState.sponsorTokens or
           token.len == 0 or appState.sponsorTokens[teamName] != token:
          headers["Content-Type"] = "text/plain"
          request.respond(403, headers, "sponsor ingress disabled or bad token")
          return
        let websocket = request.upgradeToWebSocket()
        appState.sponsors[websocket] = teamIdx
        appState.sponsorJoined.add(websocket)
    return
  case path
  of "/healthz":
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "ok")
  of "/client/global", "/client/admin":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, GlobalClientHtml)
  of "/client/player":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, PlayerClientHtml)
  of "/client/analyst":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, AnalystClientHtml)
  of "/client/cockpit":
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, CockpitClientHtml)
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
  of "/client/replay_viewer.js":
    headers["Content-Type"] = "application/javascript"
    request.respond(200, headers, ReplayViewerJs)
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
          if appState.sponsorQueue.len < 256:
            appState.sponsorQueue.add(SponsorReq(
              ws: websocket, teamIdx: appState.sponsors[websocket],
              payload: message.data))
        elif websocket in appState.players:
          # ingress cap (review §1.6): a flooding bot cannot grow the queue
          # unboundedly between ticks; first inputs win, excess is dropped
          let slot = appState.players[websocket]
          var queued = 0
          for (qs, _) in appState.playerQueue:
            if qs == slot:
              inc queued
          if queued < MaxQueuedInputsPerSlot:
            appState.playerQueue.add((slot, message.data))
  of ErrorEvent, CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closed.add(websocket)
        appState.sponsors.del(websocket)
        appState.analysts.del(websocket)
        appState.watchers.del(websocket)
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
  var toClose: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      # drain replaced/errored sockets from EVERY table and actually close
      # them (review §1.7: they used to stay open until process exit)
      toClose = appState.closed
      appState.closed.setLen(0)
      for ws in toClose:
        appState.viewers.del(ws)
        appState.players.del(ws)
        appState.analysts.del(ws)
        appState.watchers.del(ws)
        appState.sponsors.del(ws)
      for ws, st in appState.viewers.pairs:
        viewers.add((ws, st))
  for ws in toClose:
    try:
      ws.close()
    except CatchableError:
      discard
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

proc broadcastAnalyst(s: Sim, t: AnalystTracker) =
  var conns: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for ws in appState.analysts.keys:
        conns.add(ws)
  if conns.len == 0:
    return
  let payload = analystJson(s, t)
  for ws in conns:
    try:
      ws.send(payload, TextMessage)
    except CatchableError:
      {.gcsafe.}:
        withLock appState.lock:
          appState.analysts.del(ws)

var
  httpServer: Server
  serverThread: Thread[ServerThreadArgs]

proc initAppState() =
  ## Split from startServer so auth material can be populated BEFORE the
  ## HTTP server starts listening — /healthz used to go green with an
  ## empty playerTokens, and a fast bot connecting in that window was
  ## rejected with a valid token.
  initLock(appState.lock)
  appState.viewers = initTable[WebSocket, ViewerState]()
  appState.analysts = initTable[WebSocket, bool]()
  appState.watchers = initTable[WebSocket, int]()

proc startServer(rc: RuntimeConfig) =
  # tightened ingress limits (review §1.6): the biggest legal client
  # payload is a chat message (~200 bytes); 4 KB is already generous
  httpServer = newServer(httpHandler, websocketHandler,
                         workerThreads = 4, tcpNoDelay = true,
                         maxMessageLen = 4 * 1024,
                         maxBodyLen = 64 * 1024)
  createThread(serverThread, serverThreadProc, ServerThreadArgs(
    server: addr httpServer, address: rc.host, port: rc.port))
  httpServer.waitUntilReady()
  echo "zero_sum server on ", rc.host, ":", rc.port

proc serviceWatchers(s: Sim) =
  ## Read-only /watch mirrors: per-slot observation stream, no inputs.
  ## Shared by the live and replay loops (replay POV, VISUAL_REDESIGN §5.7).
  var watchConns: seq[(WebSocket, int)] = @[]
  var watchFresh: seq[WebSocket] = @[]
  {.gcsafe.}:
    withLock appState.lock:
      for ws, slot in appState.watchers.pairs:
        watchConns.add((ws, slot))
      watchFresh = appState.watcherJoined
      appState.watcherJoined.setLen(0)
  for ws in watchFresh:
    for (w, slot) in watchConns:
      if w == ws:
        try:
          ws.send(playerConfigJson(s, slot), TextMessage)
        except CatchableError:
          discard
        break
  var watchObs: array[16, string]
  for (ws, slot) in watchConns:
    try:
      if s.agents[slot].alive:
        if watchObs[slot].len == 0:
          watchObs[slot] = observationJson(s, slot)
        ws.send(watchObs[slot], TextMessage)
      elif s.agents[slot].deathTick == s.tick - 1:
        ws.send(finalJson(s, slot), TextMessage)
    except CatchableError:
      {.gcsafe.}:
        withLock appState.lock:
          appState.watchers.del(ws)

proc writeMatchArtifacts(rc: RuntimeConfig, s: Sim,
                         replay: PresentationReplay) =
  ## One artifact path for every exit: normal end, stop signal, and the
  ## tick-loop crash guard all land here (review §1.9/§1.10).
  let replayBytes = encodePresentationReplay(replay)
  let results = resultsJson(s)
  if rc.resultsUri.len > 0:
    writeResults(rc, results)
    echo "results -> ", redactUri(rc.resultsUri)
  createDir("results")
  writeFile("results" / "results.json", results)
  if rc.replayUri.len > 0:
    writeReplay(rc, replayBytes)
    echo "static replay -> ", redactUri(rc.replayUri)
  else:
    writeFile("results" / "replay.replay", replayBytes)
    echo "static replay -> results/replay.replay"
  # local convenience copies next to results (DESIGN §13/§14)
  writeFile("results" / "chat_transcript.txt", buildTranscriptText(s))
  writeFile("results" / "chat_transcript.json", buildTranscriptJson(s))
  writeFile("results" / "sponsor_log.json", sponsorLogJson(s))
  # full event stream for timeline/highlight tooling (§5.7)
  writeFile("results" / "events.json", eventHistoryJson(s))
  # per-slot input fairness metrics (review §1.2)
  writeFile("results" / "fairness.json", fairnessJson(s))

proc runLive(rc: RuntimeConfig) =
  let original =
    try:
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
    except JsonParsingError as e:
      echo "CONFIG ERROR: config is not valid JSON: ", e.msg
      quit(1)
  let cfg =
    try:
      parseSimConfig(original, mintSeedFromOs)
    except ValueError as e:
      echo "CONFIG ERROR: ", e.msg
      quit(1)
  var s = initSim(cfg)
  var r: Renderer
  var replay: PresentationReplay
  replay.addFrame(s.tick, r.initPacket(s))
  var tracker: AnalystTracker
  installStopHandlers()
  # auth material lands before the listener comes up (startup-race fix)
  initAppState()
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
  startServer(rc)
  let demoMode = original{"demo_script"}.getBool(false)

  # Player-connect grace (Paint Arena idiom, hosted k8s pods cold-start
  # slowly): when the config carries a full token set, hold the match until
  # every seat has connected or the grace deadline passes. Pure wall-clock
  # boundary BEFORE tick 0 — the sim itself stays deterministic.
  let connectGraceSeconds = original{"player_connect_timeout_seconds"}.getInt(180)
  var expectSeats = false
  {.gcsafe.}:
    withLock appState.lock:
      expectSeats = appState.playerTokens.len == 16
  if expectSeats and connectGraceSeconds > 0:
    let graceDeadline = getMonoTime() + initDuration(seconds = connectGraceSeconds)
    var waitLast = getMonoTime()
    while getMonoTime() < graceDeadline:
      var connected = 0
      {.gcsafe.}:
        withLock appState.lock:
          for i in 0 .. 15:
            if appState.slotConnected[i]:
              inc connected
      if connected == 16:
        break
      # keep spectators fed during the hold: the /global probe (hosted smoke)
      # expects a frame within ~10 s regardless of match start
      r.broadcast(s, @[])
      runFrameLimiter(waitLast)
    var connected = 0
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 .. 15:
          if appState.slotConnected[i]:
            inc connected
    echo "match starting with ", connected, "/16 seats connected"

  var last = getMonoTime()
  var echoedTalks = 0
  var echoedGifts = 0
  while s.phase != phEnded:
    if stopRequested:
      # SIGTERM/SIGINT: end the match early but exit through the normal
      # artifact path — a 9000-tick match survives an eviction
      echo "stop signal received - closing the match at tick ", s.tick
      break
    # live sponsor ingress: welcomes first, then queued requests
    var reqs: seq[SponsorReq] = @[]
    var freshSponsors: seq[(WebSocket, int)] = @[]
    {.gcsafe.}:
      withLock appState.lock:
        for ws in appState.sponsorJoined:
          if ws in appState.sponsors:
            freshSponsors.add((ws, appState.sponsors[ws]))
        appState.sponsorJoined.setLen(0)
        reqs = appState.sponsorQueue
        appState.sponsorQueue.setLen(0)
    for (ws, ti) in freshSponsors:
      var catalog = "{"
      for (key, g) in GiftCatalog:
        if catalog.len > 1: catalog.add(",")
        catalog.add("\"" & key & "\":" & $g.price)
      catalog.add("}")
      var rows = "["
      for row in staticMapRows(s.arena):
        if rows.len > 1: rows.add(",")
        rows.add(escapeJson(row))
      rows.add("]")
      try:
        ws.send("""{"type":"sponsor_welcome","team":"""" & TeamNames[ti] &
                """","budget":""" & $s.teamBudget[ti] &
                ""","catalog":""" & catalog &
                ""","shop_opens_tick":""" & $s.cfg.sponsor.shopOpensTick &
                ""","lockout_ticks":""" & $GiftLockoutTicks &
                ""","arena_size":""" & $ArenaSize &
                ""","static_map":""" & rows &
                ""","tick":""" & $s.tick & "}", TextMessage)
      except CatchableError:
        discard
    for req in reqs:
      var reply = """{"type":"gift_result","accepted":false,"reason":"malformed"}"""
      try:
        let j = parseJson(req.payload)
        if j{"type"}.getStr() == "gift_request":
          # v0.2 audience pivot: sponsors target a TILE. recipient_slot kept
          # for wire back-compat; target wins when both are present.
          var tgt = Pos(x: -1, y: -1)
          if j.hasKey("target") and j["target"].kind == JArray and
             j["target"].len == 2:
            tgt = Pos(x: j["target"][0].getInt(-1), y: j["target"][1].getInt(-1))
          let outc = s.requestGift("live:" & TeamNames[req.teamIdx],
            req.teamIdx, j{"recipient_slot"}.getInt(-1), j{"item_id"}.getStr(""),
            tgt)
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
      if j == nil:
        s.noteMalformedInput(AgentId(slot))
        continue
      # alloc_result reply (DESIGN §5.1/§10.2): handled here so the outcome
      # can be echoed back on the socket
      if j.kind == JObject and j{"type"}.getStr("") == "allocate_stats" and
         j.hasKey("speed"):
        let res = s.submitAllocation(AgentId(slot), Stats(
          speed: j{"speed"}.getInt(), strength: j{"strength"}.getInt(),
          intelligence: j{"intelligence"}.getInt(),
          athleticism: j{"athleticism"}.getInt()))
        let st = s.agents[slot].stats
        let applied = """{"speed":""" & $st.speed & ""","strength":""" &
          $st.strength & ""","intelligence":""" & $st.intelligence &
          ""","athleticism":""" & $st.athleticism & "}"
        let reply =
          case res
          of arAccepted:
            """{"type":"alloc_result","applied":""" & applied &
            ""","defaulted":false}"""
          of arRejectedDuplicate:
            """{"type":"alloc_result","rejected":true,"reason":"duplicate","applied":""" &
            applied & "}"
          of arRejectedInvalid:
            """{"type":"alloc_result","rejected":true,"reason":"invalid","applied":""" &
            applied & "}"
          of arRejectedLate:
            """{"type":"alloc_result","rejected":true,"reason":"late","applied":""" &
            applied & "}"
        if conns[slot][0]:
          try:
            conns[slot][1].send(reply, TextMessage)
          except CatchableError:
            discard
        continue
      s.applyInputJson(AgentId(slot), j)
    if demoMode:
      s.driveScript()
    try:
      s.step()
    except CatchableError as e:
      # crash guard (review §1.10): losing a match is survivable, losing
      # its artifacts is not
      echo "SIM FATAL tick=", s.tick, ": ", e.name, ": ", e.msg
      writeMatchArtifacts(rc, s, replay)
      quit(1)
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
    serviceWatchers(s)
    # sponsor state push every 24 ticks
    if s.tick mod 24 == 0:
      var sponsorConns: seq[(WebSocket, int)] = @[]
      {.gcsafe.}:
        withLock appState.lock:
          for ws, ti in appState.sponsors.pairs:
            sponsorConns.add((ws, ti))
      # drop-targeting context shared by every sponsor: ring geometry and
      # the public pod list (pods are arena-wide knowledge by spec)
      var nextR = s.zoneRadius()
      var shrinkT = 0
      for st in s.cfg.zone:
        if s.tick < st.doneT:
          nextR = st.rEnd
          shrinkT = st.shrinkT
          break
      var podsArr = ""
      for pod in s.pods:
        if podsArr.len > 0: podsArr.add(",")
        podsArr.add("""{"pos":[""" & $pod.landing.x & "," & $pod.landing.y &
                    """],"item":"""" & pod.itemId & """","landed":""" &
                    $pod.landed & "}")
      for (ws, ti) in sponsorConns:
        var aliveArr = ""
        var mates = ""
        for i in 0 .. 15:
          if s.agents[i].alive and team(AgentId(i)) == ti:
            if aliveArr.len > 0: aliveArr.add(",")
            aliveArr.add($i)
            # own-team positions only; /global is public anyway, so this
            # leaks nothing the sponsor could not already watch
            let band = (if s.agents[i].hpCenti > 6600: "healthy"
              elif s.agents[i].hpCenti >= 3300: "hurt"
              else: "critical")
            if mates.len > 0: mates.add(",")
            mates.add("""{"slot":""" & $i & ""","pos":[""" &
                      $s.agents[i].pos.x & "," & $s.agents[i].pos.y &
                      """],"hp_band":"""" & band & """"}""")
        try:
          ws.send("""{"type":"sponsor_state","tick":""" & $s.tick &
                  ""","budget":""" & $s.teamBudget[ti] &
                  ""","shop_opens_tick":""" & $s.cfg.sponsor.shopOpensTick &
                  ""","lockout_remaining":""" & $s.giftLockoutRemaining(ti) &
                  ""","team_alive":[""" & aliveArr &
                  """],"teammates":[""" & mates &
                  """],"zone":{"radius":""" & $s.zoneRadius() &
                  ""","next_radius":""" & $nextR &
                  ""","shrink_tick":""" & $shrinkT &
                  """},"pods":[""" & podsArr & "]}", TextMessage)
        except CatchableError:
          discard
    while echoedGifts < s.sponsorLog.len:
      let g = s.sponsorLog[echoedGifts]
      echo "SPONSOR [t=", g.tickRequested, "] ", g.sponsor, " ", $g.status,
           " ", g.itemId, " -> P", g.recipientSlot, " (team ",
           (if g.team in 0 .. 7: TeamNames[g.team] else: "?"), ") cost=", g.cost,
           (if g.reason.len > 0: " reason=" & g.reason else: ""),
           " balance=", g.balanceAfter
      inc echoedGifts
    while echoedTalks < s.talkLog.len:
      # DMs are public POST-match by design; streaming them to the live
      # log mid-match is a real-time intel channel (review §2.3) — gate it
      if s.talkLog[echoedTalks].channel != tcDm or
         getEnv("ZERO_SUM_DEBUG_CHAT") == "1":
        echo "CHAT ", talkLine(s, s.talkLog[echoedTalks])
      inc echoedTalks
    tracker.track(s)
    if s.tick mod 6 == 0 or s.phase == phEnded:
      broadcastAnalyst(s, tracker)
    try:
      let packet = r.updatePacket(s)
      replay.addFrame(s.tick, packet)
      r.broadcast(s, packet)
    except CatchableError as e:
      echo "RENDER FATAL tick=", s.tick, ": ", e.name, ": ", e.msg
      writeMatchArtifacts(rc, s, replay)
      quit(1)
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

  writeMatchArtifacts(rc, s, replay)
  echo "match over: winner=", s.winnerSlot, " ticks=", s.tick
  quit(0)

when isMainModule:
  let rc = readRuntimeConfig()
  if rc.replayMode:
    # A stray COGAME_LOAD_REPLAY_URI should not surface as an AssertionDefect
    # and a stack trace; say what changed and exit non-zero cleanly.
    stderr.writeLine "zero_sum: replay mode is no longer served by the game " &
      "image. Replays are played by the static viewer bundle declared at " &
      "game.replay_viewer.bundle; point the viewer at the artifact instead."
    quit(1)
  runLive(rc)
