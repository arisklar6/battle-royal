# Changelog

## 0.1.19

- Added a `duos` variant (`league_mode: duos`) to the `zero-sum` manifest;
  `competition` (Solo) stays the first/default variant. The separate
  `zero-sum-duos` manifest template is gone.
- `results.json` gains `game_version`; presentation replay header v2 carries
  GameVersion (v1 replays still decode).
- Added warnings for unknown configuration keys.
- Improved CI reporting so every failing test is reported.
- No rule or player-protocol changes.
