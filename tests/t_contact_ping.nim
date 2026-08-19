## Contact calls are drawn, not printed (VISUAL_REDESIGN 5.7 amendment): a
## talk message leading with "contact" becomes a klaxon sighting ring on the
## reported tile plus a "!" chip riding the reporter — never a text chip.
## Packs meeting used to stack "CONTACT: P0 AT .." chips into text walls
## (league round 1854's midgame was unreadable for exactly this).

import std/json
import bitworld/spriteprotocol
import battle_royal/[types, sim]
import ../game/render

# ---- parser: the shapes real bots emit
doAssert contactCall("contact: P3 at (31,20)") == (true, 31, 20)
doAssert contactCall("CONTACT: P10 AT 22 29") == (true, 22, 29)
doAssert contactCall("contact at 7 9") == (true, 7, 9)
doAssert contactCall("  Contact nearby, regroup") == (true, -1, -1)
doAssert contactCall("contact") == (true, -1, -1)
# the P-slot number must not be eaten as a coordinate
doAssert contactCall("contact: P7 at (1,2)") == (true, 1, 2)
# only ONE integer after "at" is not a coordinate pair
doAssert contactCall("contact at 31") == (true, -1, -1)
# signed coordinates are off-board by definition — never mirror "-5" to 5
doAssert contactCall("contact at (-5,-3)") == (true, -1, -1)
doAssert contactCall("contact at -5 3") == (true, -1, -1)
# fractional tails truncate instead of leaking into the next coordinate
doAssert contactCall("contact at 3.5 7.9") == (true, 3, 7)
doAssert contactCall("contact at 10.25, 12") == (true, 10, 12)
# conversation is not a report
doAssert contactCall("no contact yet") == (false, -1, -1)
doAssert contactCall("contacting hq") == (false, -1, -1)
doAssert contactCall("drop at (10,12) - im close") == (false, -1, -1)
doAssert contactCall("") == (false, -1, -1)
# "at" inside a word does not anchor coordinates
doAssert contactCall("contact: combat 3 4") == (true, -1, -1)

# ---- the defs packet bakes the ring stages and the mark
proc fixedSeed(): uint64 = 7'u64
let cfg = parseSimConfig(%*{
  "seed": 5, "max_ticks": 200, "freeze_ticks": 48,
  "zone": {"schedule": [[100, 120, 180, 24, 0, 30]]}}, fixedSeed)
var s = initSim(cfg)
var r: Renderer
var defLabels: seq[string] = @[]
for m in parseSpritePacket(r.initPacket(s)):
  if m.kind == spkSprite:
    defLabels.add(m.sprite.label)
for want in ["contact0", "contact1", "contact2", "contact3", "contact_mark"]:
  doAssert want in defLabels, "missing sprite def: " & want

# ---- a coordinate contact call pings the tile and marks the reporter
doAssert s.submitTalk(AgentId(0), tcTeam, -1, "contact: P3 at (10,12)") ==
  tkAccepted
doAssert s.submitTalk(AgentId(2), tcTeam, -1, "hello there") == tkAccepted
s.step()
var pingObj = -1
var markObj = -1
var sawTalk2 = false
var sawTalk0Sprite = false
for m in parseSpritePacket(r.updatePacket(s)):
  case m.kind
  of spkObject:
    if m.objectDef.spriteId == SpContactPing:
      pingObj = m.objectDef.id
      # tile (10,12) centre, 24px canvas, LayerMap scales by RS
      doAssert m.objectDef.x == (10 * TileSize + 3 - 12) * RS
      doAssert m.objectDef.y == (12 * TileSize + 3 - 12) * RS
    elif m.objectDef.spriteId == SpContactMark:
      markObj = m.objectDef.id
  of spkSprite:
    if m.sprite.label == "talk0": sawTalk0Sprite = true
    elif m.sprite.label == "talk2": sawTalk2 = true
  else: discard
doAssert pingObj >= 0, "sighting ring never placed"
doAssert markObj >= 0, "reporter mark never placed"
doAssert not sawTalk0Sprite, "contact call still printed as a text chip"
doAssert sawTalk2, "ordinary chat must still print"

# ---- ring dies at ContactPingTtl, mark at TalkChipTtl; both by delete
var pingDead = false
var markDead = false
var stagePointed = false
for _ in 0 ..< 70:
  s.step()
  for m in parseSpritePacket(r.updatePacket(s)):
    case m.kind
    of spkObject:
      # the ring ages by re-pointing the same object at later stages
      if m.objectDef.id == pingObj and
         m.objectDef.spriteId > SpContactPing and
         m.objectDef.spriteId < SpContactPing + 4:
        stagePointed = true
    of spkDeleteObject:
      if m.objectId == pingObj: pingDead = true
      if m.objectId == markObj: markDead = true
    else: discard
doAssert stagePointed, "ring never bloomed through its stages"
doAssert pingDead, "sighting ring never expired"
doAssert markDead, "reporter mark never expired"

# ---- a coordinate-less call marks the reporter without a ping
doAssert s.submitTalk(AgentId(4), tcTeam, -1, "contact nearby, regroup") ==
  tkAccepted
s.step()
var newPing = false
var mark4 = false
for m in parseSpritePacket(r.updatePacket(s)):
  if m.kind == spkObject:
    if m.objectDef.spriteId == SpContactPing: newPing = true
    if m.objectDef.spriteId == SpContactMark: mark4 = true
doAssert mark4, "coordinate-less contact call lost its reporter mark"
doAssert not newPing, "coordinate-less contact call must not ping a tile"

echo "t_contact_ping ok"
