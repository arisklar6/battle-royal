## Deterministic match PRNG (xoshiro256**) — the ONLY randomness source in the sim.
## Seeded from config.seed; consumption order is part of the spec (DESIGN §15).
## No std/random, no wall clock anywhere in the sim.

type
  Prng* = object
    s: array[4, uint64]

proc splitmix64(x: var uint64): uint64 =
  x = x + 0x9E3779B97F4A7C15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc initPrng*(seed: uint64): Prng =
  var x = seed
  for i in 0 .. 3:
    result.s[i] = splitmix64(x)

proc rotl(x: uint64, k: int): uint64 {.inline.} =
  (x shl k) or (x shr (64 - k))

proc next*(rng: var Prng): uint64 =
  result = rotl(rng.s[1] * 5, 7) * 9
  let t = rng.s[1] shl 17
  rng.s[2] = rng.s[2] xor rng.s[0]
  rng.s[3] = rng.s[3] xor rng.s[1]
  rng.s[1] = rng.s[1] xor rng.s[2]
  rng.s[0] = rng.s[0] xor rng.s[3]
  rng.s[2] = rng.s[2] xor t
  rng.s[3] = rotl(rng.s[3], 45)

proc rand*(rng: var Prng, bound: int): int =
  ## Uniform-ish integer in [0, bound). bound > 0, always tiny (< 2^16) in this
  ## game, so modulo bias is < 2^-48 — irrelevant. Modulo IS the spec: exactly
  ## one next() per call, replay-stable.
  assert bound > 0
  int(rng.next() mod bound.uint64)

proc chance*(rng: var Prng, percent: int): bool =
  ## True with `percent` in 100 probability. Consumes exactly one draw.
  rng.rand(100) < percent

proc state*(rng: Prng): array[4, uint64] = rng.s
