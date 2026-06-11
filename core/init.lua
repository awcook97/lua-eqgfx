--[[
  core/init.lua - LuaJIT FFI binding for eqgfx.dll (native EQGraphics drawing).

  Pulls the LIVE CRenderInterface* and ClientSpellManager* straight out of
  eqlib.dll's exported symbols and hands those pointers to eqgfx.dll, which
  does the actual native drawing from the render callback and reads spell
  data from the engine.

  Usage:
    local eqgfx = require('eqgfx')
    eqgfx.init()
    -- each pulse:
    eqgfx.clear()
    eqgfx.add_circle(x, y, z, radius, eqgfx.argb(255, 255, 40, 40), 48)
    local g = eqgfx.spell_geom(spellID)   -- targetType/range/aeRange/coneStart/coneEnd
    -- on script exit:
    eqgfx.shutdown()
]]

local ffi = require('ffi')

ffi.cdef[[
  // Exported as plain C symbols from eqlib.dll (shared build, EQLIB_EXPORTS).
  // Each is a uintptr_t holding a live instance address.
  extern uintptr_t pinstRenderInterface;
  extern uintptr_t pinstSpellManager;
  extern uintptr_t pinstCDisplay;

  typedef struct {
    int   targetType;   // eSpellTargetType (-1 if lookup failed)
    float range;
    float aeRange;
    int   coneStart;    // degrees
    int   coneEnd;      // degrees
  } eqgfx_spell_geom;

  int  eqgfx_init(void* pRenderInterface, void* pSpellManager);
  void eqgfx_set_display(void* pCDisplay);
  void eqgfx_shutdown();
  void eqgfx_clear();
  void eqgfx_add_circle(float x, float y, float z, float radius, uint32_t color, int segments);
  void eqgfx_add_arc(float cx, float cy, float cz, float radius,
                     float startRad, float endRad, uint32_t color, int segments);
  void eqgfx_add_line(float x1, float y1, float z1, float x2, float y2, float z2, uint32_t color);
  int  eqgfx_get_spell_geom(int spellID, eqgfx_spell_geom* out);
  void eqgfx_stats(uint32_t* sceneCalls, uint32_t* lastDraws);
  void eqgfx_set_axis_mode(int mode);
  void eqgfx_set_convention(int c);
  void eqgfx_set_eyerel(int e);
  void eqgfx_set_wsign(int s);
  void eqgfx_set_flipx(int f);
  void eqgfx_set_flipy(int f);
  void eqgfx_get_eye(float* x, float* y, float* z);
  void eqgfx_world_to_camera(float x, float y, float z, float* cx, float* cy, float* cz);
  void eqgfx_get_screen(int* w, int* h);
  void eqgfx_set_thickness(int t);
  void eqgfx_dump_matrix(float* out16);
  void eqgfx_add_screen_line(float x1, float y1, float x2, float y2, uint32_t color);
  void eqgfx_add_screen_rect(float x0, float y0, float x1, float y1, uint32_t color);
  void eqgfx_world_to_screen(float x, float y, float z, float* sx, float* sy, int* visible);
  void eqgfx_project(float x, float y, float z, float* sx, float* sy, int* infront);
  void eqgfx_set_ui_names(const char* newlineSeparated);
  int  eqgfx_ui_available();
  int  eqgfx_ui_find_mode();
  void eqgfx_ui_stats(int* names, int* found, int* faults);
  const char* eqgfx_build();
  int  eqgfx_get_ui_rects(float* out, int maxRects);
  int  eqgfx_get_ui_rects2(float* out, int* nameIdx, int maxRects);
]]

-- Optional hard override for the DLL location (Windows-style path). Normally
-- leave nil: we locate eqgfx.dll next to this script so the project is portable.
local DLL_PATH = nil

local function locate_dll()
  if DLL_PATH then return DLL_PATH end
  local src = debug.getinfo(1, 'S').source        -- "@<root>/core/init.lua"
  if src:sub(1, 1) == '@' then
    local dir  = src:sub(2):gsub('[^/\\]+$', '')   -- .../eqgfx/core/
    local root = dir:gsub('[^/\\]+[/\\]$', '')     -- .../eqgfx/
    local sep  = dir:find('\\', 1, true) and '\\' or '/'
    return root .. 'native' .. sep .. 'eqgfx.dll'
  end
  return 'eqgfx'                                   -- fall back to OS search path
end

-- Fingerprinted hot-loading: Windows returns the ALREADY-MAPPED module when
-- the same path is loaded again, so a rebuilt eqgfx.dll would silently keep
-- running old code until the game restarts. Instead the dll is copied to a
-- per-build name (eqgfx_run_<size>_<hash>.dll) and THAT is loaded - a fresh
-- /lua run always gets the newest build, no game restart required.
local function file_fingerprint(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local size = f:seek('end') or 0
  if size > 4096 then f:seek('set', size - 4096) else f:seek('set', 0) end
  local sample = f:read(4096) or ''
  f:close()
  local h = 5381
  for idx = 1, #sample, 7 do
    h = (h * 33 + sample:byte(idx)) % 4294967291
  end
  return string.format('%x_%x', size, h)
end

local function hot_copy_path(base)
  local fp = file_fingerprint(base)
  if not fp then return base end
  local dir = base:gsub('[^/\\]+$', '')
  local cached = dir .. 'eqgfx_run_' .. fp .. '.dll'
  local probe = io.open(cached, 'rb')
  if probe then probe:close() return cached end
  local src = io.open(base, 'rb')
  if not src then return base end
  local dst = io.open(cached, 'wb')
  if not dst then src:close() return base end
  dst:write(src:read('*a'))
  src:close()
  dst:close()
  -- best-effort cleanup of older run copies (loaded ones refuse deletion)
  pcall(function()
    local lfs = require('lfs')
    for name in lfs.dir(dir) do
      if name:match('^eqgfx_run_.*%.dll$') and dir .. name ~= cached then
        pcall(os.remove, dir .. name)
      end
    end
  end)
  return cached
end

local eqlib = ffi.load('eqlib')                    -- already in-process; read its exports
local lib
do
  local base = locate_dll()
  local path = hot_copy_path(base)
  local okk, l = pcall(ffi.load, path)
  if not okk then okk, l = pcall(ffi.load, base) end       -- fall back to base path
  if not okk then okk, l = pcall(ffi.load, 'eqgfx') end    -- then OS search path
  if not okk then error('[eqgfx] could not load eqgfx.dll (tried: ' .. tostring(path) .. ')') end
  lib = l
end

--- The eqgfx core API: engine-backed world drawing, projection and spell
--- geometry for MacroQuest Lua. See docs/CORE_API.md for the full guide.
---@class Eqgfx
---@field ui_native boolean|nil # native window enumeration available (set by init)
---@field dll_stale boolean|nil # the game loaded an older eqgfx.dll than the one on disk
---@field TargetType table<string, integer> # eSpellTargetType values (PBAE, Beam, ...)
local M = {}

-- scalar cdata fields read back as plain Lua numbers
---@type { targetType: integer, range: number, aeRange: number, coneStart: number, coneEnd: number }
local geom = ffi.new('eqgfx_spell_geom')

-- The pinst* symbols hold the ADDRESS OF the instance pointer slot, not the
-- instance. Dereference once to get the real CRenderInterface*/SpellManager*.
local function deref_inst(addr)
  if addr == 0 then return nil end
  local p = ffi.cast('void**', addr)[0]
  if p == nil then return nil end
  return p
end

--- Wire up eqgfx: read the live engine pointers from eqlib's exports, hand
--- them to the DLL, and register the render callback. Must be called IN GAME
--- (character loaded) before anything else; check the result, don't assume.
---
--- ```lua
--- local eqgfx = require('eqgfx')
--- local ok, err = eqgfx.init()
--- if not ok then print('eqgfx: ' .. tostring(err)) return end
--- ```
---@return boolean ok # false when the engine isn't ready (e.g. not in game yet)
---@return string|nil err # human-readable reason when ok is false
function M.init()
  local pr = deref_inst(eqlib.pinstRenderInterface)
  if not pr then return false, 'render interface is null (not in game yet?)' end
  local ps = deref_inst(eqlib.pinstSpellManager)   -- may be nil; spell lookups no-op
  local rc = lib.eqgfx_init(pr, ps)
  if rc ~= 0 then
    local why = ({ [1]='render ptr null', [2]='MQ2Main.dll not loaded',
                   [3]='AddRenderCallbacks export not found' })[rc] or ('code '..rc)
    return false, 'eqgfx_init failed: '..why
  end
  local pd = deref_inst(eqlib.pinstCDisplay)         -- CDisplay -> active camera
  if pd then lib.eqgfx_set_display(pd) end
  -- CXWndManager -> native UI window enumeration (older eqlib builds may not
  -- export it; everything degrades to the Lua-side Window TLO scan).
  -- Native UI enumeration: the DLL resolves FindMQ2Window / CXWnd methods
  -- BY NAME from MQ2Main.dll / eqlib.dll exports. If the
  -- loaded eqgfx.dll predates these exports (game launched before a rebuild),
  -- flag it so scripts tell the user to restart EQ instead of failing quietly.
  M.ui_native = false
  M.dll_stale = not pcall(function() return lib.eqgfx_ui_available end)
  if not M.dll_stale then
    M.ui_native = lib.eqgfx_ui_available() == 1
  end
  return true
end

--- Compile stamp of the dll the game ACTUALLY loaded (vs whatever is on
--- disk) - what /npdebug prints as "loaded eqgfx.dll build".
---
--- ```lua
--- print(eqgfx.build())   --> "Jun 11 2026 02:04:53"
--- ```
---@return string stamp # build date/time, or a stale-dll hint on very old builds
function M.build()
  local okk, v = pcall(function() return ffi.string(lib.eqgfx_build()) end)
  return okk and v or 'pre-2026-06-10 (stale - restart EQ)'
end

--- Which FindMQ2Window ABI variant the native window sweep locked onto
--- (diagnostic; shown by /npdebug).
---@return integer mode # 0 unprobed, 1 char*, 2 string_view, 3/4 same via deref'd export variable, -1 nothing worked
function M.ui_find_mode()
  local okk, v = pcall(function() return lib.eqgfx_ui_find_mode() end)
  return okk and v or -1
end

local _usn, _usf, _usx = ffi.new('int[1]'), ffi.new('int[1]'), ffi.new('int[1]')

--- Health of the last native window sweep. faults > 0 means an export/ABI
--- mismatch inside the scan - occlusion would be silently broken otherwise.
---
--- ```lua
--- local names, found, faults = eqgfx.ui_stats()
--- ```
---@return integer|nil names # candidate window names swept (nil on a stale dll)
---@return integer|nil found # window rects the sweep produced
---@return integer|nil faults # SEH probe faults (broken scan when > 0)
function M.ui_stats()
  local okk = pcall(function() lib.eqgfx_ui_stats(_usn, _usf, _usx) end)
  if not okk then return nil end
  return tonumber(_usn[0]), tonumber(_usf[0]), tonumber(_usx[0])
end

--- Push the candidate window-name list for the native UI scan. lib/uirects
--- owns this; scripts normally never call it directly.
---@param names string[] # window names as shown by /windows (order matters: rect.idx indexes it)
function M.set_ui_names(names)
  pcall(function() lib.eqgfx_set_ui_names(table.concat(names, '\n')) end)
end

--- Unregister the render callback and drop every queued primitive. Call on
--- script exit.
function M.shutdown() lib.eqgfx_shutdown() end

--- Wipe the retained scene (world + screen primitives). Call at the top of
--- each main-loop pass, then re-add what should exist right now - the engine
--- redraws whatever is queued every frame until the next clear().
---
--- ```lua
--- while true do
---   eqgfx.clear()
---   eqgfx.add_circle(me.X(), me.Y(), me.Z(), 30, eqgfx.argb(180, 0, 255, 0))
---   mq.delay(50)
--- end
--- ```
function M.clear()    lib.eqgfx_clear()    end

--- Queue a ground-plane circle, engine-drawn every frame until clear().
--- Coordinates are TLO order - pass Spawn.X()/Y()/Z() directly.
---
--- ```lua
--- eqgfx.add_circle(t.X(), t.Y(), t.Z(), 15, eqgfx.argb(200, 255, 60, 60), 48)
--- ```
---@param x number # world X (TLO order)
---@param y number # world Y
---@param z number # world Z (height the ring is drawn at)
---@param radius number # world units
---@param color integer # packed color from eqgfx.argb()
---@param segments integer|nil # line segments around the circle (default 48)
function M.add_circle(x, y, z, radius, color, segments)
  lib.eqgfx_add_circle(x, y, z, radius, color, segments or 48)
end

--- Queue an arc wedge (two radii + the arc between them), e.g. a cone slice.
--- Angles are RADIANS in the world atan2 frame (x = cos, y = sin); for an
--- arc relative to a spawn's facing see indicators/render.lua facing_rad().
---@param cx number # arc center X (TLO order)
---@param cy number # arc center Y
---@param cz number # arc center Z
---@param radius number # world units
---@param startRad number # start angle in radians
---@param endRad number # end angle in radians
---@param color integer # packed color from eqgfx.argb()
---@param segments integer|nil # subdivisions along the arc (default 24)
function M.add_arc(cx, cy, cz, radius, startRad, endRad, color, segments)
  lib.eqgfx_add_arc(cx, cy, cz, radius, startRad, endRad, color, segments or 24)
end

--- Queue a world-space line segment. Drawn only while both endpoints are in
--- front of the camera.
---
--- ```lua
--- eqgfx.add_line(me.X(), me.Y(), me.Z(), t.X(), t.Y(), t.Z(),
---                eqgfx.argb(255, 255, 215, 50))
--- ```
---@param x1 number # first endpoint X (TLO order)
---@param y1 number # first endpoint Y
---@param z1 number # first endpoint Z
---@param x2 number # second endpoint X
---@param y2 number # second endpoint Y
---@param z2 number # second endpoint Z
---@param color integer # packed color from eqgfx.argb()
function M.add_line(x1, y1, z1, x2, y2, z2, color)
  lib.eqgfx_add_line(x1, y1, z1, x2, y2, z2, color)
end

local _sc, _ld = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')

--- Render-callback diagnostics. If sceneCalls isn't growing, the callback
--- isn't firing (init failed / not in game); lastDraws says how much of your
--- retained scene actually drew.
---
--- ```lua
--- local calls, draws = eqgfx.stats()
--- ```
---@return integer sceneCalls # cumulative render-callback invocations
---@return integer lastDraws # primitives drawn on the previous frame
function M.stats()
  lib.eqgfx_stats(_sc, _ld)
  return tonumber(_sc[0]) --[[@as integer]], tonumber(_ld[0]) --[[@as integer]]
end

--- Calibration leftover: world-coordinate convention. The shipped default is
--- already calibrated - only touch via tools/calibrate.lua.
---@param mode integer # axis permutation 0..6 (6 = the solved EQ render frame)
function M.set_axis_mode(mode) lib.eqgfx_set_axis_mode(mode) end

--- Calibration leftover: matrix multiply convention.
---@param c integer # 0 = row-vector (v*M), 1 = column-vector (M*v)
function M.set_convention(c)   lib.eqgfx_set_convention(c) end

--- Calibration leftover: subtract the camera eye before transforming.
---@param e boolean # true = eye-relative, false = absolute world->clip
function M.set_eyerel(e)       lib.eqgfx_set_eyerel(e and 1 or 0) end

--- Calibration leftover: sign of clip.w for front-facing points.
---@param s integer # +1 or -1
function M.set_wsign(s)        lib.eqgfx_set_wsign(s) end

--- Calibration leftover: mirror the horizontal screen axis.
---@param f boolean
function M.set_flipx(f)        lib.eqgfx_set_flipx(f and 1 or 0) end

--- Calibration leftover: mirror the vertical screen axis.
---@param f boolean
function M.set_flipy(f)        lib.eqgfx_set_flipy(f and 1 or 0) end

local _ex, _ey, _ez = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('float[1]')

--- Camera eye position in world coords (calibration/debug helper).
---@return number x
---@return number y
---@return number z
function M.get_eye()
  lib.eqgfx_get_eye(_ex, _ey, _ez)
  return tonumber(_ex[0]) --[[@as number]], tonumber(_ey[0]) --[[@as number]],
         tonumber(_ez[0]) --[[@as number]]
end

local _cx, _cy, _cz = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('float[1]')

--- The engine's own world->camera transform (calibration/debug helper).
---@param x number # world X (TLO order)
---@param y number # world Y
---@param z number # world Z
---@return number cx # view-space X
---@return number cy # view-space Y
---@return number cz # view-space depth
function M.world_to_camera(x, y, z)
  lib.eqgfx_world_to_camera(x, y, z, _cx, _cy, _cz)
  return tonumber(_cx[0]) --[[@as number]], tonumber(_cy[0]) --[[@as number]],
         tonumber(_cz[0]) --[[@as number]]
end

local _gw, _gh = ffi.new('int[1]'), ffi.new('int[1]')

--- Render resolution in pixels (0,0 when the render interface is gone).
---
--- ```lua
--- local w, h = eqgfx.get_screen()
--- ```
---@return integer w # screen width in pixels
---@return integer h # screen height in pixels
function M.get_screen()
  lib.eqgfx_get_screen(_gw, _gh)
  return tonumber(_gw[0]) --[[@as integer]], tonumber(_gh[0]) --[[@as integer]]
end

--- World-line thickness for the engine primitives.
---@param t integer # line half-width in pixels (0 = hairline)
function M.set_thickness(t) lib.eqgfx_set_thickness(t) end

--- Queue a pure 2D screen-space line (pixels, no projection) - HUD elements,
--- crosshairs. Retained until clear(), same as the world primitives.
---@param x1 number # start X in pixels
---@param y1 number # start Y in pixels
---@param x2 number # end X in pixels
---@param y2 number # end Y in pixels
---@param color integer # packed color from eqgfx.argb()
function M.add_screen_line(x1, y1, x2, y2, color)
  lib.eqgfx_add_screen_line(x1, y1, x2, y2, color)
end

--- Queue a filled 2D screen-space rectangle (pixels, no projection) - HUD
--- fills, simple bars. Retained until clear().
---
--- ```lua
--- eqgfx.add_screen_rect(20, 20, 220, 36, eqgfx.argb(160, 30, 30, 30))
--- ```
---@param x0 number # left edge in pixels
---@param y0 number # top edge in pixels
---@param x1 number # right edge in pixels
---@param y1 number # bottom edge in pixels
---@param color integer # packed color from eqgfx.argb()
function M.add_screen_rect(x0, y0, x1, y1, color)
  lib.eqgfx_add_screen_rect(x0, y0, x1, y1, color)
end

local _m16 = ffi.new('float[16]')

--- Copy of the engine's view-projection matrix (calibration/debug helper).
---@return number[] m # the 16 floats as a flat table, m[1..16]
function M.dump_matrix()
  lib.eqgfx_dump_matrix(_m16)
  local t = {}
  for i = 1, 16 do t[i] = tonumber(_m16[i - 1]) end
  return t
end

local _sx, _sy, _vis = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('int[1]')

--- Project a world point to screen pixels. `visible` is true only when the
--- point is in front of the camera AND inside the viewport - the right test
--- for "should I draw a label/plate here at all".
---
--- ```lua
--- local sx, sy, vis = eqgfx.world_to_screen(s.X(), s.Y(), s.Z() + 4)
--- if vis then drawList:AddText(ImVec2(sx, sy), 0xFFFFFFFF, s.CleanName()) end
--- ```
---@param x number # world X (TLO order; pass Spawn.X() directly)
---@param y number # world Y
---@param z number # world Z
---@return number sx # screen X in pixels
---@return number sy # screen Y in pixels
---@return boolean visible # in front of the camera AND on screen
function M.world_to_screen(x, y, z)
  lib.eqgfx_world_to_screen(x, y, z, _sx, _sy, _vis)
  return tonumber(_sx[0]) --[[@as number]], tonumber(_sy[0]) --[[@as number]],
         _vis[0] ~= 0
end

local _px, _py, _pf = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('int[1]')

--- Project a world point to RAW screen pixels - no viewport clamp - plus the
--- engine's in-front-of-camera bool. Use this (not world_to_screen's
--- `visible`) when off-screen points still matter, e.g. triangulating a ring
--- you stand inside: each wedge needs a reliable per-vertex front test even
--- for vertices outside the screen. See indicators/render.lua fill_and_outline.
---
--- ```lua
--- local sx, sy, infront = eqgfx.project(px, py, pz)
--- if infront then table.insert(poly, ImVec2(sx, sy)) end
--- ```
---@param x number # world X (TLO order)
---@param y number # world Y
---@param z number # world Z
---@return number sx # raw screen X in pixels (may be off-screen)
---@return number sy # raw screen Y in pixels
---@return boolean infront # point is in front of the camera
function M.project(x, y, z)
  lib.eqgfx_project(x, y, z, _px, _py, _pf)
  return tonumber(_px[0]) --[[@as number]], tonumber(_py[0]) --[[@as number]],
         _pf[0] ~= 0
end

local _uiBuf = ffi.new('float[512]')   -- 128 rects max
local _uiIdx = ffi.new('int[128]')

--- Raw snapshot of the native window sweep: one rect per visible, top-level,
--- non-minimized EQ window, in render pixels. `idx` is the 1-based position
--- in the name list pushed via set_ui_names (nil on a stale dll without the
--- v2 export). Most scripts want lib/uirects.get() instead - it filters,
--- clamps and attaches the window names.
---@return { [1]: number, [2]: number, [3]: number, [4]: number, idx: integer|nil }[]|nil rects # {x0,y0,x1,y1,idx} array, or nil when the native path is unavailable
function M.get_ui_rects()
  if not M.ui_native then return nil end
  local okk, n = pcall(function() return lib.eqgfx_get_ui_rects2(_uiBuf, _uiIdx, 128) end)
  if not okk then n = lib.eqgfx_get_ui_rects(_uiBuf, 128) end
  local t = {}
  for i = 0, n - 1 do
    t[i + 1] = { tonumber(_uiBuf[i * 4]),     tonumber(_uiBuf[i * 4 + 1]),
                 tonumber(_uiBuf[i * 4 + 2]), tonumber(_uiBuf[i * 4 + 3]),
                 idx = okk and (tonumber(_uiIdx[i]) + 1) or nil }
  end
  return t
end

--- A spell's area geometry, straight from the client's spell data. The
--- conventional radius is aeRange when > 0, else range; cone angles are
--- degrees relative to the caster's facing.
---
--- ```lua
--- local g = eqgfx.spell_geom(spellID)
--- if g and g.targetType == eqgfx.TargetType.PBAE then
---   local radius = (g.aeRange > 0) and g.aeRange or g.range
--- end
--- ```
---@param spellID integer # spell ID (e.g. from mq.TLO.Me.Casting.ID())
---@return SpellGeom|nil geom # nil when the spell can't be found
function M.spell_geom(spellID)
  if lib.eqgfx_get_spell_geom(spellID, geom) == 0 then return nil end
  return {
    targetType = geom.targetType,
    range      = geom.range,
    aeRange    = geom.aeRange,
    coneStart  = geom.coneStart,
    coneEnd    = geom.coneEnd,
  }
end

--- Pack a color for the engine-primitive calls (add_circle, add_line, ...).
--- NOT for ImGui draw lists - those want ImGui.ColorConvertFloat4ToU32.
---
--- ```lua
--- local red = eqgfx.argb(200, 255, 60, 60)
--- ```
---@param a integer # alpha 0-255
---@param r integer # red 0-255
---@param g integer # green 0-255
---@param b integer # blue 0-255
---@return integer color # packed 32-bit color
function M.argb(a, r, g, b)
  return bit.bor(bit.lshift(a, 24), bit.lshift(r, 16), bit.lshift(g, 8), b)
end

--- Byte-order-swapped variant of argb(). If reds come out blue on some
--- client, swap argb -> abgr in your calls.
---@param a integer # alpha 0-255
---@param b integer # blue 0-255
---@param g integer # green 0-255
---@param r integer # red 0-255
---@return integer color # packed 32-bit color
function M.abgr(a, b, g, r)
  return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r)
end

-- eSpellTargetType values + LuaLS annotations live in core/_types.lua.
M.TargetType = require('eqgfx.core._types').TargetType

return M
