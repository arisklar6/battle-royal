## Data-driven item system (DESIGN §3). One table + effect enums so v2 items
## (crafting, traps, more weapons) are config additions, not engine work.

type
  ItemId* = enum
    iNone = "none"
    iSword = "sword"
    iSpear = "spear"
    iBow = "bow"
    iKnives = "knives"          # throwing knives: weapon + ammo in one stack
    iBlowgun = "blowgun"
    iNet = "net"
    iFirstAid = "first_aid"
    iRations = "rations"
    iBackpack = "backpack"
    iCamo = "camouflage"
    iArrows = "arrows"
    iDarts = "darts"

  ItemKind* = enum
    ikMelee, ikRanged, ikThrown, ikGear, ikConsumable, ikAmmo

  ItemDef* = object
    kind*: ItemKind
    damage*: int                # base HP (whole), melee scaled by strength
    rng*: int                   # range in tiles
    cooldown*: int              # ticks between uses (bow: base draw time)
    durability*: int            # uses until break (0 = not applicable)
    stackMax*: int              # per pack slot
    useTicks*: int              # channel/eat duration (consumables)
    heal*: int                  # HP restored on completed use
    price*: int                 # softcoin (sponsor catalog)

const
  ItemTable*: array[ItemId, ItemDef] = [
    iNone:     ItemDef(kind: ikMelee, damage: 5, rng: 1, cooldown: 12,
                       stackMax: 1),                               # bare hands
    iSword:    ItemDef(kind: ikMelee, damage: 18, rng: 1, cooldown: 18,
                       durability: 40, stackMax: 1, price: 120),
    iSpear:    ItemDef(kind: ikMelee, damage: 12, rng: 2, cooldown: 20,
                       durability: 40, stackMax: 1, price: 90),
    iBow:      ItemDef(kind: ikRanged, damage: 14, rng: 8, cooldown: 18,
                       stackMax: 1, price: 150),
    iKnives:   ItemDef(kind: ikThrown, damage: 8, rng: 5, cooldown: 10,
                       stackMax: 8, price: 30),
    iBlowgun:  ItemDef(kind: ikRanged, damage: 4, rng: 6, cooldown: 24,
                       stackMax: 1, price: 100),
    iNet:      ItemDef(kind: ikThrown, damage: 0, rng: 3, cooldown: 30,
                       stackMax: 2, price: 50),
    iFirstAid: ItemDef(kind: ikConsumable, stackMax: 2, useTicks: 48,
                       heal: 50, price: 60),
    iRations:  ItemDef(kind: ikConsumable, stackMax: 5, useTicks: 24,
                       heal: 15, price: 20),
    iBackpack: ItemDef(kind: ikGear, stackMax: 1, price: 70),
    iCamo:     ItemDef(kind: ikGear, stackMax: 1, price: 80),
    iArrows:   ItemDef(kind: ikAmmo, stackMax: 12, price: 30),
    iDarts:    ItemDef(kind: ikAmmo, stackMax: 8, price: 35)]

  PoisonPulseCenti* = 200       # 2 HP per pulse
  PoisonPulsePeriod* = 24
  NetTicks* = 72
  CamoRevealTicks* = 120

type
  GiftDef* = object
    price*: int
    contents*: seq[(ItemId, int)]

const GiftCatalog*: seq[(string, GiftDef)] = @[
  ## DESIGN §9.2 (DECIDED: fixed prices, no caps beyond the budget).
  ("rations", GiftDef(price: 20, contents: @[(iRations, 2)])),
  ("knives", GiftDef(price: 30, contents: @[(iKnives, 4)])),
  ("arrows", GiftDef(price: 30, contents: @[(iArrows, 6)])),
  ("darts", GiftDef(price: 35, contents: @[(iDarts, 4)])),
  ("net", GiftDef(price: 50, contents: @[(iNet, 1)])),
  ("first_aid", GiftDef(price: 60, contents: @[(iFirstAid, 1)])),
  ("backpack", GiftDef(price: 70, contents: @[(iBackpack, 1)])),
  ("camouflage", GiftDef(price: 80, contents: @[(iCamo, 1)])),
  ("spear", GiftDef(price: 90, contents: @[(iSpear, 1)])),
  ("blowgun", GiftDef(price: 100, contents: @[(iBlowgun, 1), (iDarts, 4)])),
  ("sword", GiftDef(price: 120, contents: @[(iSword, 1)])),
  ("bow", GiftDef(price: 150, contents: @[(iBow, 1), (iArrows, 6)]))]

proc giftLookup*(id: string): (bool, GiftDef) =
  for (key, g) in GiftCatalog:
    if key == id:
      return (true, g)
  (false, GiftDef())

proc def*(id: ItemId): ItemDef = ItemTable[id]
proc isWeapon*(id: ItemId): bool =
  ItemTable[id].kind in {ikMelee, ikRanged, ikThrown} and id != iNone
proc ammoFor*(id: ItemId): ItemId =
  case id
  of iBow: iArrows
  of iBlowgun: iDarts
  else: iNone
