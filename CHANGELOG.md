# Changelog

All notable changes to eqgfx are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-06-11

### Added

- **Nameplates** (`/lua run eqgfx/nameplates`): animated HP bars with five
  fill textures, names with anonymization modes and per-letter animations,
  buff icon rows with filters/overrides/tooltips, cast bars with spell icons
  and interrupt detection, mana/endurance bars, target styling, and a full
  in-game menu (`/npmenu`) with character/server/global save scopes.
- **AE cast highlight**: plates light up when an in-flight AE will affect
  them — orange for harmful, light blue for helpful — for your casts, other
  players', and NPCs'. Overlapping AEs deepen the color (configurable
  stacking curve, sources, colors, and animation).
- **Native UI occlusion**: plates clip around (or hide behind) open EQ
  windows instead of drawing over them; `/npui` manages and visualizes the
  detected windows.
- **Indicators** (`/lua run eqgfx/indicators`): the area of spells being
  cast drawn on the ground — caster rings, target rings, cones, beams and
  cast lines, colored by friend/enemy, with EQBC target sharing across
  boxes and its own menu (`/aemenu`).
- Documentation: [getting started](docs/GETTING_STARTED.md),
  [commands](docs/COMMANDS.md), [developing](docs/DEVELOPING.md).
