## Core sim types. All HP in centi-HP integers (DESIGN Â§5.2); no floats in the sim.

import items
export items

type
  TileKind* = enum
    tkGround = "."
    tkWall = "#"       # arena border
    tkRock = "R"
    tkFortressWall = "F"
    tkPedestal = "P"
    tkBush = "B"

  Phase* = enum
    phCountdown = "countdown"
    phLive = "live"
    phEnded = "ended"

  Dir8* = enum
    dN, dNE, dE, dSE, dS, dSW, dW, dNW

  Pos* = object
    x*, y*: int

  Stats* = object
    speed*, strength*, intelligence*, athleticism*: int

  AgentId* = range[0 .. 15]

  PackSlot* = object
    item*: ItemId              # iNone = empty
    n*: int                    # stack count
    durability*: int           # weapons only

  ChannelKind* = enum
    chNone, chConsume, chForage

  Channeling* = object
    kind*: ChannelKind
    item*: ItemId
    packIdx*: int
    doneTick*: int

  Agent* = object
    slot*: AgentId
    alive*: bool
    pos*: Pos
    hpCenti*: int              # 0..10_000 (100.00 HP)
    stats*: Stats
    statsLocked*: bool         # first valid allocation accepted
    moveReadyTick*: int
    attackReadyTick*: int
    deathTick*: int            # -1 while alive
    damageDealtCenti*: int
    kills*: int
    # inventory (DESIGN Â§3.1)
    hand*: ItemId              # iNone = bare hands
    handN*: int                # thrown-weapon stack held in hand
    handDur*: int
    body*: ItemId              # iNone | iBackpack | iCamo
    pack*: array[4, PackSlot]  # slots 2..3 usable only with backpack
    # effects
    poisonUntil*: int          # tick; 0 = not poisoned
    poisonAppliedTick*: int    # pulse phase anchor
    poisonFrom*: int           # shooter slot for kill credit
    nettedUntil*: int
    camoRevealedUntil*: int
    channeling*: Channeling
    lastDamager*: int          # -1 = environment
    damageTakenCenti*: int     # this tick, for observations

  GroundItem* = object
    pos*: Pos
    item*: ItemId
    n*: int
    durability*: int

  Bush* = object
    pos*: Pos
    charges*: int

  Projectile* = object
    pos*: Pos                  # current tile
    dir*: Dir8
    kind*: ItemId              # iArrows | iDarts | iKnives | iNet
    shooter*: int
    remaining*: int            # tiles of range left

  EventKind* = enum
    evIgnition, evDeathFireworks, evBoom, evMineExplosion,
    evZoneWarning, evEventWarning, evGiftIncoming, evGiftLanded,
    evFinale, evMatchEnd

  Event* = object
    tick*: int
    kind*: EventKind
    slot*: int                 # -1 when not agent-scoped
    pos*: Pos
    data*: string

  PendingMove* = object
    slot*: AgentId
    target*: Pos
    active*: bool

const
  ArenaSize* = 48
  MaxHpCenti* = 10_000
  TeamNames* = ["A", "B", "C", "D", "E", "F", "G", "H"]

  SlotHand* = -1
  SlotBody* = -2

  ## Pinned pedestal ring (DESIGN Â§2.2) â€” literal constants, no runtime trig.
  Pedestals*: array[16, Pos] = [
    Pos(x: 40, y: 24), Pos(x: 39, y: 30), Pos(x: 35, y: 35), Pos(x: 30, y: 39),
    Pos(x: 24, y: 40), Pos(x: 18, y: 39), Pos(x: 13, y: 35), Pos(x: 9, y: 30),
    Pos(x: 8, y: 24), Pos(x: 9, y: 18), Pos(x: 13, y: 13), Pos(x: 18, y: 9),
    Pos(x: 24, y: 8), Pos(x: 30, y: 9), Pos(x: 35, y: 13), Pos(x: 39, y: 18)]

proc team*(slot: AgentId): int = slot div 2
proc teamName*(slot: AgentId): string = TeamNames[team(slot)]
proc teammate*(slot: AgentId): AgentId = AgentId(slot xor 1)

proc `+`*(p: Pos, d: Dir8): Pos =
  const dx = [0, 1, 1, 1, 0, -1, -1, -1]
  const dy = [-1, -1, 0, 1, 1, 1, 0, -1]
  Pos(x: p.x + dx[ord(d)], y: p.y + dy[ord(d)])

proc `==`*(a, b: Pos): bool = a.x == b.x and a.y == b.y

proc packSlots*(a: Agent): int =
  if a.body == iBackpack: 4 else: 2


