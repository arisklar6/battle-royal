## Probes a running replay server the way the certifier does: one non-empty
## frame from WS /replay. Run manually against a --load-replay server.

import whisky

when isMainModule:
  let ws = newWebSocket("ws://127.0.0.1:8080/replay")
  let msg = ws.receiveMessage()
  if msg.isSome:
    let m = msg.get()
    doAssert m.data.len > 0
    echo "replay frame ok: ", m.data.len, " bytes, kind=", m.kind
  else:
    quit "no frame received", 1
  ws.close()
