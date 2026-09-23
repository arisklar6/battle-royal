# Changelog

## 0.1.19

- Added a `duos` variant (`league_mode: duos`) to the `zero-sum` manifest;
  `competition` (Solo) stays the first/default variant. The separate
  `zero-sum-duos` manifest template is gone.
- `results.json` gains `game_version`; presentation replay header v2 carries
  GameVersion (v1 replays still decode).
- `results_schema` declares the optional `game_version` field. The schema is
  closed (`additionalProperties: false`), so without it certification's
  `results-conform` step rejected every 0.1.19 results document.
  `tests/t_results_schema.nim` now checks `resultsJson` against the committed
  template.
- Added warnings for unknown configuration keys.
- Improved CI reporting so every failing test is reported.
- No rule or player-protocol changes.
