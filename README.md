# eqgfx — native EverQuest world drawing from MacroQuest Lua

Draw in the EverQuest 3D world from **Lua scripts** — AE spell indicators, health
bars, nameplates, overlays — by talking to the game's own renderer. Built for
running MacroQuest on **Linux/Wine**, where you can't rebuild the MQ2Lua plugin
and can't ship a normal C Lua module.

It ships two feature scripts:

- **`nameplates`** — animated, flicker-free nameplates over nearby spawns: HP
  bar, name text, a cast bar showing the spell + time remaining, and a full
  in-game customization menu (`/npmenu` — colors, sizes, name position,
  animations). Plates clip around (or hide behind) the native EQ windows
  instead of drawing over them, and in-flight AE casts (yours, other
  players', NPCs') highlight the plates they will affect — orange for spawns
  they will harm, light blue for ones they will help, deeper color the more
  AEs overlap (colors/animation/stacking configurable).
- **`indicators`** — while you or nearby mobs cast, draws the spell's affected
  area (PBAE / targeted-AE ring, directional cone, or beam) on the ground.

![demo placeholder](#)

---

## How it works

Three problems, three solutions:

1. **Get a screen position for a world point.** The DLL calls the engine's own
   `CCamera::ProjectWorldCoordinatesToScreen` (reached via `CDisplay->pCamera`).
   That's the authoritative world→screen transform — no hand-rolled matrices.
   (EQ stores positions as `Y, X, Z`, so we swap X/Y before projecting.)

2. **Actually draw on screen.** We register through MacroQuest's own
   `AddRenderCallbacks` and draw from its `GraphicsSceneRender` callback using the
   engine's `CRenderInterface::DrawLine2D`. Nameplates instead draw via MQ's
   **ImGui** foreground draw list (double-buffered → smooth, animatable).

3. **Talk to the engine from Lua without crashing.** MQ2Lua statically links
   LuaJIT, so a normal C Lua module would load a *second* LuaJIT and corrupt
   coroutines. Instead `eqgfx.dll` exposes a plain `extern "C"` ABI and Lua calls
   it over **LuaJIT FFI** (same trick as calling `winhttp.dll`). It also reads the
   live, per-patch engine pointers out of `eqlib.dll`'s exported symbols
   (`pinstRenderInterface`, `pinstSpellManager`, `pinstCDisplay`) — so **no game
   offsets are baked into the DLL** and it survives monthly EQ patches without a
   rebuild. The only hard-coded engine knowledge is vtable/struct *layout*
   (method order, field offsets), which is stable across patches.

---

## Files

| Path | What it is |
|------|------------|
| `native/` | The native bridge: `eqgfx.cpp` (extern "C" ABI: projection, line/circle/arc/rect drawing, spell lookup), `build_eqgfx.sh` (msvc-wine build), and the prebuilt `eqgfx.dll` (x64 PE). |
| `init.lua` | Entry shim — keeps `require('eqgfx')` working; the real module lives in `core/`. |
| `core/` | The Lua FFI module: loads the DLL, exposes the API, reads eqlib's exported pointers. |
| `casts/` | Shared cast detection/tracking ("begins to cast" events + spell links + casting animations) used by both features. |
| `nameplates/` | Nameplate feature: HP bar + name + cast bar, settings menu (`/npmenu`). Run: `/lua run eqgfx/nameplates`. |
| `indicators/` | AE/cone/beam area indicators, settings menu (`/aemenu`). Run: `/lua run eqgfx/indicators`. |
| `tools/` | Dev tools: `calibrate.lua` (crosshair-on-target + matrix/camera dumps used to solve the projection), `debug.lua` (render-callback counters + fixed test geometry). |
| `lib/` | Shared libs (logger, EQBC helpers). |

Each feature folder keeps its types, classes and enums in a `_types.lua`.

---

## Requirements

- **MacroQuest** running against EverQuest (this targets the **DirectX 11**
  client). Standard (non-static) MQ build, so `eqlib.dll` exports its symbols.
- To **build the DLL**: the [msvc-wine](https://github.com/mstorsjo/msvc-wine)
  toolchain (MSVC under Wine). To just **use** it, the prebuilt `eqgfx.dll` is
  enough.

---

## Build

```bash
# default toolchain path is $HOME/opt/msvc; override with MSVC_ROOT=...
./native/build_eqgfx.sh
```
`native/eqgfx.dll` is written next to the build script. It's self-contained (imports only
`KERNEL32.dll`) — no game offsets, no second LuaJIT.

## Install

Drop the whole folder in your MQ `lua/` directory as `lua/eqgfx/`:
```
<MacroQuest>/lua/eqgfx/{init.lua, core/, native/, nameplates/, ...}
```
The module finds `native/eqgfx.dll` relative to itself automatically.

## Use

```
/lua run eqgfx/nameplates           # /npmenu for the customization window
/lua run eqgfx/indicators           # /aemenu for the settings window
```

Settings persist under `<config>/eqgfx/` as `<Server>_<Name>_settings.lua`
(per character, the default), `<Server>_settings.lua`, or
`global_settings.lua` — switch the save scope from each feature's menu.

---

## Lua API (`require('eqgfx')`)

```lua
local g = require('eqgfx')
g.init()                                  -- wire up render callback + camera

-- per frame / pulse:
g.clear()
local sx, sy, vis = g.world_to_screen(x, y, z)      -- world -> screen pixels

-- world-space primitives (projected + drawn by the engine each frame):
g.add_circle(x, y, z, radius, color, segments)
g.add_arc(cx, cy, cz, radius, startRad, endRad, color, segments)
g.add_line(x1,y1,z1, x2,y2,z2, color)

-- screen-space primitives (pixels, no projection):
g.add_screen_line(x1,y1, x2,y2, color)
g.add_screen_rect(x0,y0, x1,y1, color)

-- spell geometry (targetType / range / aeRange / coneStart / coneEnd):
local geom = g.spell_geom(spellID)

g.set_thickness(px)                       -- world-line half-width
g.argb(a,r,g,b)                           -- color for eqgfx primitives
g.shutdown()
```
For nameplate-style ImGui drawing, use `g.world_to_screen` for the position and
draw with MQ's ImGui (`ImGui.GetForegroundDrawList()`), as `nameplates/` does.

(There are also `set_flipx/flipy`, `dump_matrix`, `world_to_camera`, `get_eye`,
etc. — leftover calibration/debug helpers used while reverse-engineering the
projection. Safe to ignore.)

---

## Caveats

- **Layout, not addresses, is hard-coded.** vtable indices (`DrawLine2D`,
  `ProjectWorldCoordinatesToScreen`, `GetSpellByID`) and struct offsets
  (`EQ_Spell` fields, `CDisplay::pCamera`) come from MQ's eqlib headers. Monthly
  patches that only move addresses are fine; a patch that *reorders* an interface
  or changes a struct means bumping those constants in `native/eqgfx.cpp`.
- **DX11 client only.** The legacy DX9 3D path (`DrawLine3D`) doesn't composite
  on this client; we use the 2D overlay path + CPU projection instead.
- Cone/beam facing uses EQ heading and may need a sign tweak per client.

---

## Contributing

1. Edit `native/eqgfx.cpp` and/or the Lua, rebuild with `./native/build_eqgfx.sh`.
2. The `tools/calibrate.lua` / `tools/debug.lua` tools are there for diagnosing
   projection/rendering if you change the engine-facing code.
3. Keep the "no baked offsets" rule: read live pointers from `eqlib.dll` exports;
   only encode stable *layout* (and comment the header each index/offset came
   from). PRs welcome — new primitives, text rendering, more spell shapes,
   nameplate styling.
