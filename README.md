# eqgfx — native EverQuest world drawing from MacroQuest Lua

Draw in the EverQuest 3D world from **Lua scripts** — AE spell indicators, health
bars, nameplates, overlays — by talking to the game's own renderer. Built for
running MacroQuest on **Linux/Wine**, where you can't rebuild the MQ2Lua plugin
and can't ship a normal C Lua module.

It ships two example scripts:

- **`healthbars`** — animated, flicker-free HP bars floating over nearby spawns.
- **`ae_caster_indicator`** — while you cast, draws the spell's affected area
  (PBAE / targeted-AE ring, directional cone, or beam) on the ground.

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
   engine's `CRenderInterface::DrawLine2D`. Health bars instead draw via MQ's
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

| File | What it is |
|------|------------|
| `eqgfx.cpp` | The native bridge. extern "C" ABI: projection, line/circle/arc/rect drawing, spell lookup. **Compile this → `eqgfx.dll`.** |
| `build_eqgfx.sh` | Builds `eqgfx.dll` with the msvc-wine toolchain. |
| `eqgfx.dll` | Prebuilt bridge (x64 PE). Loaded by `init.lua` via FFI. |
| `init.lua` | The Lua module (`require('eqgfx')`). Loads the DLL, exposes the API, reads eqlib's exported pointers. |
| `healthbars.lua` | Example: animated HP bars (ImGui + projection). |
| `ae_caster_indicator.lua` | Example: AE/cone/beam area while casting. |
| `eqgfx_calibrate.lua` | Dev tool: crosshair-on-target + matrix/camera dumps used to solve the projection. |
| `eqgfx_debug.lua` | Dev tool: render-callback counters + fixed test geometry. |

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
./build_eqgfx.sh
```
`eqgfx.dll` is written next to the script. It's self-contained (imports only
`KERNEL32.dll`) — no game offsets, no second LuaJIT.

## Install

Drop the whole folder in your MQ `lua/` directory as `lua/eqgfx/`:
```
<MacroQuest>/lua/eqgfx/{eqgfx.dll, init.lua, healthbars.lua, ...}
```
`init.lua` finds `eqgfx.dll` next to itself automatically.

## Use

```
/lua run eqgfx/healthbars
/lua run eqgfx/ae_caster_indicator
```

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
For health-bar-style ImGui drawing, use `g.world_to_screen` for the position and
draw with MQ's ImGui (`ImGui.GetForegroundDrawList()`), as `healthbars.lua` does.

(There are also `set_flipx/flipy`, `dump_matrix`, `world_to_camera`, `get_eye`,
etc. — leftover calibration/debug helpers used while reverse-engineering the
projection. Safe to ignore.)

---

## Caveats

- **Layout, not addresses, is hard-coded.** vtable indices (`DrawLine2D`,
  `ProjectWorldCoordinatesToScreen`, `GetSpellByID`) and struct offsets
  (`EQ_Spell` fields, `CDisplay::pCamera`) come from MQ's eqlib headers. Monthly
  patches that only move addresses are fine; a patch that *reorders* an interface
  or changes a struct means bumping those constants in `eqgfx.cpp`.
- **DX11 client only.** The legacy DX9 3D path (`DrawLine3D`) doesn't composite
  on this client; we use the 2D overlay path + CPU projection instead.
- Cone/beam facing uses EQ heading and may need a sign tweak per client.

---

## Contributing

1. Edit `eqgfx.cpp` and/or the Lua, rebuild with `./build_eqgfx.sh`.
2. The `eqgfx_calibrate.lua` / `eqgfx_debug.lua` tools are there for diagnosing
   projection/rendering if you change the engine-facing code.
3. Keep the "no baked offsets" rule: read live pointers from `eqlib.dll` exports;
   only encode stable *layout* (and comment the header each index/offset came
   from). PRs welcome — new primitives, text rendering, more spell shapes,
   nameplate styling.
