# Developing eqgfx

How the pieces fit, how to build the native DLL, and the engine facts that
were expensive to learn. Read this before touching `core/`, `native/` or the
occlusion path.

---

## Layout

```
init.lua            entry shim: require('eqgfx') -> core/
core/               LuaJIT FFI binding for eqgfx.dll + TargetType enums
native/             eqgfx.cpp (the DLL), build_eqgfx.sh (msvc-wine build)
casts/              shared cast tracker ("begins to cast" events + Me.Casting)
nameplates/         plates: init (loop/occlusion), render, anim, ae, menu, settings, _types
indicators/         ground AE drawing: init (loop/EQBC), render, menu, settings, _types
lib/                settings store, uirects (occluder rects), ui_windows (name list),
                    lwlogger, EQBC helpers
tools/              calibrate.lua, debug.lua - projection/render diagnostics
test/               smoke.lua
```

Each feature keeps its enums/classes in a `_types.lua`. The codebase is
LuaLS-clean (`.luarc.json` targets LuaJIT + the mq-definitions library);
keep `lua-language-server --check .` at zero problems.

---

## The three core problems

1. **World → screen.** The DLL calls the engine's own
   `CCamera::ProjectWorldCoordinatesToScreen` via `CDisplay->pCamera`. EQ
   stores positions as `(Y, X, Z)` — every world-space entry point swaps the
   first two components before projecting. `eqgfx.world_to_screen` clamps to
   the viewport and returns `visible`; `eqgfx.project` returns raw pixels
   plus a reliable in-front-of-camera bool (use it when triangulating rings
   you may be standing inside).

2. **Drawing.** World geometry (indicators) goes through MQ's
   `AddRenderCallbacks` → `GraphicsSceneRender` and the engine's 2D overlay
   (`DrawLine2D`); the legacy DX9 `DrawLine3D` path fires but never
   composites on the DX11 client — don't try to revive it. Nameplates draw
   through MQ's ImGui instead (double-buffered, animatable), inside a
   fullscreen pass-through window pinned to the back of the ImGui stack.

3. **Lua ↔ native without a second LuaJIT.** MQ2Lua statically links LuaJIT,
   so a normal C Lua module would load a second runtime and corrupt
   coroutines. `eqgfx.dll` exposes a plain `extern "C"` ABI consumed over
   LuaJIT FFI.

---

## Resolving the engine at runtime

Everything engine-facing is resolved at runtime from symbols exported by
`eqlib.dll` / `MQ2Main.dll` (`pinstRenderInterface`, `pinstSpellManager`,
`pinstCDisplay`, `FindMQ2Window`, ...). Keep it that way: resolve by name,
have a fallback, and make resolution failures visible (`/npdebug`).

### Export gotchas (learned the hard way)

- **eqlib's flat `CXWnd__*` exports are `uintptr_t` variables**, not
  functions — data slots holding the resolved function's address (same
  convention as `pinst*`). `GetProcAddress` happily returns them and calling
  one executes data bytes. The mangled `?...@eqlib@@` exports are the real
  compiled member functions. Resolve mangled first; deref the flat name as a
  fallback. The sweep counts SEH probe faults and surfaces them through
  `eqgfx_ui_stats` / `/npdebug` so an ABI mismatch can never be silent.
- **`CXWnd::GetScreenRect` returns render pixels** on this client — verified
  in-game. Do not "calibrate" them: `EQMainWnd` is *not* the fullscreen
  canvas (it's the small EQ-button window), and two separate attempts to
  scale rects against it corrupted perfectly good data. `lib/uirects.lua`
  applies the identity transform, clamps to the screen, and drops only empty
  leftovers and near-fullscreen layers.
- **`FindMQ2Window`'s parameter ABI varies** across MQ builds (`const char*`
  vs `std::string_view`). The sweep probes the variants once at runtime
  (including through a deref'd variable) and locks in whichever works.

---

## Building the DLL

Only needed when `native/eqgfx.cpp` changes. With
[msvc-wine](https://github.com/mstorsjo/msvc-wine) installed:

```bash
# default toolchain path is $HOME/opt/msvc; override with MSVC_ROOT=...
./native/build_eqgfx.sh
```

The output is self-contained (imports only `KERNEL32.dll`). **No game
restart needed to test**: `core/init.lua` copies the DLL to a fingerprinted
name (`eqgfx_run_<size>_<hash>.dll`) and loads that, so every `/lua run`
binds the newest build even while an older copy is still mapped. The only
time a restart matters is when the *running session's* DLL predates a new
export — scripts detect that (`eqgfx.dll_stale`) and say so.

`native/MQ2Main.def` / `native/eqlib.def` are export dumps from a local MQ
install kept as a **developer reference** for which symbols exist (they are
gitignored, not shipped). The DLL never links against them — everything is
`GetProcAddress` at runtime.

---

## Threading and timing rules

- The DLL's UI window sweep runs on the **render thread** (inside the
  `GraphicsSceneRender` callback) where engine calls are legal; Lua only
  snapshots the cached result (`eqgfx_get_ui_rects2`) under a small mutex.
  Per-window calls are SEH-isolated so engine-side faults degrade to "no
  rect", never a client crash.
- **Never put a Window-TLO sweep in script loops.** A full TLO window scan
  was measured stalling the Lua loop for hundreds of milliseconds, starving
  `mq.doevents()` and lagging cast detection by seconds. The native scan is
  the single source of occluder rects; if it's unavailable, occlusion turns
  off loudly.
- Nameplate animation runs on a **frame counter** (`FRAME_DT = 1/35`), not
  the wall clock — the game paces draw frames. Only the cast tracker touches
  real time (`os.clock()`), because spell durations are wall seconds.
- The main loops are flat: every pass does everything, no time-gating, with
  `mq.delay(50)` pacing. The per-frame draw callback does the position reads
  so plates track movement exactly.

---

## Nameplates internals

- **Render caps probing** (`render.probe_caps`): the MQ ImGui binding's
  fancier calls (sized text, multi-color rects, clip rects, texture
  animations) vary by build, so each is pcall-probed once and the renderer
  degrades per-feature. Check `R.caps` before using any of them.
- **Occlusion** (`init.lua`): each plate records its real drawn footprint
  into `plate.ext` (geometry cursors + text/cast-bar extents). Next frame,
  that bbox is tested against the occluder rects; overlapping plates are
  either skipped (HIDE) or drawn once per visible sub-rectangle with
  `PushClipRect` (CLIP) — `uirects.subtract` punches the windows out of the
  bbox. Over-estimating the bbox is harmless; under-estimating leaks pixels
  for one frame.
- **Draw order**: plates are gathered, then painted far → near; your target
  ranks above everything except your own plate.
- **AE highlight** (`ae.lua`): every active cast becomes an `AeState`
  (circle/cone/beam + who it `marks`); `draw_plates` counts how many areas
  cover each plate and maps the count onto the stack alpha curve
  (`aehl.stackBase/Step/Max`), smoothed by `anim.approach`. Detrimental
  marks the caster's enemies, beneficial its allies; group-target spells
  resolve only for my own group; target-centered casts from others need the
  caster targeted (`Target.AggroHolder`). Spell geometry and the
  beneficial flag are cached per caster+spell.

## Indicators internals

- Shapes follow `eqgfx.spell_geom` (target type, range, aeRange, cone
  angles); the caster-centered/target-centered sets live in
  `core/_types.lua` and are shared with the nameplates highlight so both
  always agree.
- Cross-box target resolution rides EQBC: whoever has the caster targeted
  broadcasts `eqgfx_cast=<casterID>=<spellID>=<targetID>`, and every box
  draws the target ring (stub entries handle casters outside local
  detection range).
- World drawing is clipped to `uirects.regions(rects, sw, sh)` — the screen
  minus the open windows — so areas render under the native UI.

---

## Settings

`lib/settings.lua` is a tiny scoped store: one file per scope
(char/server/global) shared by all features, each feature under its own
section key. `merge_defaults` fills in new fields on upgrade, so adding a
setting is just: add the default in `<feature>/settings.lua`, read it where
needed, add a widget in `<feature>/menu.lua` (the helpers mark the store
dirty; the main loop saves when dirty).

## Conventions

- `_types.lua` per feature for enums/classes; LuaLS annotations everywhere;
  zero `lua-language-server --check` problems.
- TLO reads that can fail are pcall-wrapped (see the `getn/getstr/getbool`
  helpers); members differ across MQ builds more than you'd hope.
- New symbols are resolved by name at runtime, with a fallback and a way to
  see the failure (`/npdebug`).
