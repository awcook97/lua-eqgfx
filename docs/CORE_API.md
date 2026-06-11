# Core API — building your own scripts on eqgfx

`require('eqgfx')` gives any MacroQuest Lua script engine-backed world
drawing: project world coordinates to screen pixels, draw primitives the
engine renders every frame, and read spell geometry. The nameplates and
indicators features are built entirely on this API — your script can do
anything they do.

The smallest useful script — a ring under your target:

```lua
local mq    = require('mq')
local eqgfx = require('eqgfx')

local ok, err = eqgfx.init()
if not ok then print('eqgfx: ' .. tostring(err)) return end

while true do
  eqgfx.clear()                                   -- rebuild the scene each pass
  local t = mq.TLO.Target
  if t.ID() and t.ID() > 0 and t.X() then
    eqgfx.add_circle(t.X(), t.Y(), t.Z(), 15,     -- TLO coords, as-is
                     eqgfx.argb(200, 255, 60, 60), 48)
  end
  mq.delay(50)
end
```

Run it, target something, and there's a red ring on the ground under it.

---

## Lifecycle

```lua
local eqgfx = require('eqgfx')
local ok, err = eqgfx.init()   -- false + reason when not in game yet
...
eqgfx.shutdown()               -- on script exit (unregisters the render hook)
```

- `init()` must run **in game** (character loaded) — it reads the live engine
  pointers from MacroQuest and registers a render callback. Check the return
  value; retry later rather than crashing.
- Each running Lua script gets its own independent copy of the module
  (MQ Lua states are isolated), so your script coexists with nameplates and
  indicators without coordination.
- After `init()`, two flags are worth checking:
  - `eqgfx.dll_stale` — the game session loaded an older `eqgfx.dll` than the
    one on disk (restart EQ once to pick up the new build).
  - `eqgfx.ui_native` — the native EQ window scan is available (needed for
    the occlusion helpers below).

---

## Two ways to draw — pick per job

| | Engine primitives (`add_*`) | ImGui overlay (`project` + ImGui) |
|---|---|---|
| Layering | **under** the native EQ UI automatically | on **top** of everything (clip to go under — see below) |
| Shapes | lines, circles, arcs, screen rects | anything ImGui can do: filled polys, text, textures/icons |
| Pacing | engine frame rate, rebuilt from your main loop | every ImGui frame — smooth, animatable |
| Colors | `eqgfx.argb(a,r,g,b)` | ImGui packed u32 (`ImGui.ColorConvertFloat4ToU32{r,g,b,a}`) |
| Used by | `tools/debug.lua`, `tools/calibrate.lua` | `nameplates/`, `indicators/` |

### Engine primitives

Your main loop owns a little retained scene: `clear()` it, `add_*` what should
exist right now, and the engine redraws it every frame until you change it.

```lua
eqgfx.clear()
eqgfx.add_circle(x, y, z, radius, color, segments)        -- ground ring (segments default 48)
eqgfx.add_arc(cx, cy, cz, radius, a0, a1, color, segments) -- a0/a1 in RADIANS
eqgfx.add_line(x1,y1,z1, x2,y2,z2, color)                  -- world-space segment
eqgfx.add_screen_line(x1,y1, x2,y2, color)                 -- raw pixels, no projection
eqgfx.add_screen_rect(x0,y0, x1,y1, color)                 -- filled pixel rect
eqgfx.set_thickness(px)                                    -- line half-width in pixels
```

Colors are `eqgfx.argb(a, r, g, b)` with 0–255 components (`eqgfx.abgr` exists
in case a client swaps the byte order — if your reds come out blue, that's
why). A segment only draws while both endpoints are in front of the camera.

### ImGui overlay

Project positions yourself and draw with MQ's ImGui from an
`mq.imgui.init` callback — this is the nameplates approach, and the only way
to get filled shapes, text and spell icons:

```lua
local mq    = require('mq')
local eqgfx = require('eqgfx')
local ImGui = require('ImGui')

assert(eqgfx.init())

mq.imgui.init('target_label', function()
  local t = mq.TLO.Target
  if not (t.ID() and t.ID() > 0 and t.X()) then return end
  local sx, sy, vis = eqgfx.world_to_screen(t.X(), t.Y(), t.Z() + 4)
  if not vis then return end
  local fg = ImGui.GetForegroundDrawList()
  fg:AddText(ImVec2(sx, sy), ImGui.ColorConvertFloat4ToU32({1, 1, 0, 1}),
             t.CleanName() or '?')
end)

while true do mq.doevents() mq.delay(100) end
```

The callback runs every frame; reading positions inside it is what makes
drawings stick to moving spawns (the features all do this).

---

## Projection

```lua
local sx, sy, visible = eqgfx.world_to_screen(x, y, z)
local sx, sy, infront = eqgfx.project(x, y, z)
local w, h            = eqgfx.get_screen()
```

- **Pass TLO coordinates directly** (`spawn.X(), spawn.Y(), spawn.Z()`) — the
  engine's axis conventions are handled internally.
- `world_to_screen`: `visible` is true only when the point is in front of the
  camera **and** inside the viewport. Use it for "should I draw this at all"
  decisions (labels, plates).
- `project`: raw pixels with no viewport clamp; `infront` is a reliable
  per-vertex front-of-camera test even for off-screen points. Use it when
  triangulating shapes you might be standing inside (see
  `indicators/render.lua` `fill_and_outline` for the pattern).

---

## Spell geometry

```lua
local g = eqgfx.spell_geom(spellID)
-- nil, or { targetType, range, aeRange, coneStart, coneEnd }  (cone angles in degrees)

local TT   = eqgfx.TargetType                       -- PBAE, TargetArea, DirectionalCone, Beam, ...
local core = require('eqgfx.core._types')
core.CasterCentered[g.targetType]                   -- area sits on the caster
core.TargetCentered[g.targetType]                   -- area sits on the caster's target
```

The conventional radius is `aeRange` when it's > 0, else `range`. For worked
examples of every shape — rings, cones, beams, and who they affect — read
`indicators/render.lua` (drawing) and `nameplates/ae.lua` (hit-testing).

---

## Going under the EQ windows (ImGui route)

ImGui draws over the native UI. To make world drawings respect open windows,
clip them to the screen regions the windows don't cover — `lib/uirects.lua`
provides the rects:

```lua
local uirects = require('eqgfx.lib.uirects')

-- inside your imgui callback:
local rects, native = uirects.get()          -- one cheap FFI call; {x0,y0,x1,y1,name=...}
local drawList = ImGui.GetBackgroundDrawList()
if native and #rects > 0 then
  local sw, sh = eqgfx.get_screen()
  for _, r in ipairs(uirects.regions(rects, sw, sh)) do
    drawList:PushClipRect(ImVec2(r[1], r[2]), ImVec2(r[3], r[4]), false)
    draw_everything(drawList)                -- your drawing, once per region
    drawList:PopClipRect()
  end
else
  draw_everything(drawList)
end
```

`uirects.subtract(bbox, rects)` does the same subtraction against a single
rectangle — nameplates uses it to clip one plate at a time. Engine primitives
never need any of this; they're under the UI already.

---

## Cast tracking (shared lib)

Detecting what *other* spawns cast is messy (`Spawn.Casting` only works for
yourself); `eqgfx.casts` wraps it:

```lua
local casts = require('eqgfx.casts')
casts.init{ trackSelf = true }       -- registers chat events; do this once

-- main loop:
mq.doevents()                        -- required: cast detection rides on events
casts.update()
for spawnID, info in pairs(casts.all()) do
  local pct, remain = casts.progress(info, casts.now())
  -- info.spellID / spellName / casterName / duration / interrupted ...
end
```

## Persistent settings (shared lib)

The same scoped store the features use (character / server / global files
under `<config>/eqgfx/`) works for your script:

```lua
local Store = require('eqgfx.lib.settings')
local settings = Store.new{ section = 'myscript', defaults = { radius = 50 } }
settings.load()
settings.data.radius = 75
settings.mark_dirty()
settings.maybe_save()               -- call every loop pass; writes only on change
```

---

## Diagnostics & gotchas

- `eqgfx.stats()` → `sceneCalls, lastDraws`: if `sceneCalls` isn't growing,
  the render callback isn't firing (init failed or not in game); `lastDraws`
  is how many primitives drew last frame.
- `eqgfx.build()` → compile stamp of the DLL the game actually loaded.
- Keep per-pass work light: never sweep the Window TLO in a loop (measured at
  hundreds of milliseconds), prefer one spawn search over many, and pcall any
  TLO member that might not exist on a given MQ build.
- `set_axis_mode`, `set_convention`, `dump_matrix`, `world_to_camera`,
  `get_eye` and friends are calibration leftovers from reverse-engineering
  the projection — you don't need them; `tools/calibrate.lua` shows their use
  if a future client ever changes conventions.
