## Certification boundary: results.json must validate against the manifest's
## game.results_schema. The certifier's `results-conform` step and the hosted
## runner both reject a results document with an undeclared key
## (`additionalProperties: false`), so a field added to resultsJson without a
## matching gen_manifest.py RESULTS_SCHEMA entry fails certification. 0.1.19's
## `game_version` stamp got past every other test this way; this test is the
## guard. It checks the committed template, so run `python tools/gen_manifest.py`
## after editing RESULTS_SCHEMA.

import std/[json, os]
import zero_sum/[types, sim]
import ../game/bundle

proc fixedSeed(): uint64 = 42'u64

let manifest = parseFile(currentSourcePath().parentDir.parentDir /
                         "coworld_manifest_template.json")
let schema = manifest["game"]["results_schema"]

proc kindMatches(node: JsonNode, typ: string): bool =
  case typ
  of "array": node.kind == JArray
  of "object": node.kind == JObject
  of "string": node.kind == JString
  of "null": node.kind == JNull
  of "integer": node.kind == JInt
  of "number": node.kind in {JInt, JFloat}
  of "boolean": node.kind == JBool
  else: false

proc typeOk(node, spec: JsonNode): bool =
  if not spec.hasKey("type"): return true
  let t = spec["type"]
  if t.kind == JString: return kindMatches(node, t.getStr())
  for alt in t:
    if kindMatches(node, alt.getStr()): return true
  false

const supportedKeywords = ["type", "items", "minItems", "maxItems", "minimum",
                             "maximum", "minLength"]

proc assertValue(value, spec: JsonNode, where: string) =
  ## Checks one value against one property schema. Any keyword this mini
  ## validator does not implement fails loudly instead of passing silently.
  for kw, _ in spec:
    doAssert kw in supportedKeywords,
      where & ": validator does not support '" & kw & "' -- extend this test"
  doAssert typeOk(value, spec), where & ": wrong JSON type"
  if value.kind in {JInt, JFloat}:
    if spec.hasKey("minimum"):
      doAssert value.getFloat() >= spec["minimum"].getFloat(),
        where & ": below minimum"
    if spec.hasKey("maximum"):
      doAssert value.getFloat() <= spec["maximum"].getFloat(),
        where & ": above maximum"
  if value.kind == JString and spec.hasKey("minLength"):
    doAssert value.getStr().len >= spec["minLength"].getInt(),
      where & ": shorter than minLength"
  if value.kind == JArray:
    if spec.hasKey("minItems"):
      doAssert value.len >= spec["minItems"].getInt(), where & ": too few items"
    if spec.hasKey("maxItems"):
      doAssert value.len <= spec["maxItems"].getInt(), where & ": too many items"
    if spec.hasKey("items"):
      for i, item in value.getElems():
        assertValue(item, spec["items"], where & "[" & $i & "]")

proc assertConforms(results: JsonNode, label: string) =
  let props = schema["properties"]
  for key in schema["required"]:
    doAssert results.hasKey(key.getStr()),
      label & ": required key missing: " & key.getStr()
  for key, value in results:
    doAssert props.hasKey(key),
      label & ": key '" & key & "' is not declared in results_schema " &
      "(additionalProperties is false) -- add it to RESULTS_SCHEMA in " &
      "tools/gen_manifest.py and regenerate the template"
    assertValue(value, props[key], label & ": " & key)

doAssert schema["additionalProperties"].getBool() == false,
  "results_schema is expected to be closed; revisit this test if that changes"

for mode in ["solo", "duos"]:
  # Finished match with a winner: winner_slot/winner_team populated.
  var s = initSim(parseSimConfig(%*{
    "league_mode": mode, "seed": 42, "max_ticks": 200,
    "freeze_ticks": 48}, fixedSeed))
  for i in 0 .. 15:
    s.agents[i].alive = false
    s.agents[i].deathTick = 100 - i
  s.agents[0].alive = true
  s.agents[0].kills = 1
  s.winnerSlot = 0
  assertConforms(parseJson(resultsJson(s)), mode & "/winner")

  # No winner (simultaneous final death): winner_slot -1, winner_team null.
  var t = initSim(parseSimConfig(%*{
    "league_mode": mode, "seed": 7, "max_ticks": 200,
    "freeze_ticks": 48}, fixedSeed))
  for i in 0 .. 15:
    t.agents[i].alive = false
    t.agents[i].deathTick = 100
  t.winnerSlot = -1
  assertConforms(parseJson(resultsJson(t)), mode & "/no-winner")

echo "t_results_schema ok"
