--[[
  core/init.lua - LuaJIT FFI binding for eqgfx.dll (native EQGraphics drawing).

  Pulls the LIVE CRenderInterface* and ClientSpellManager* straight out of
  eqlib.dll's exported symbols, so nothing here bakes in a game address and it
  keeps working across monthly EQ patches. Hands those pointers to eqgfx.dll,
  which does the actual native DrawLine3D from the render callback and reads
  spell data from the struct.

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
  const char* eqgfx_build();
  int  eqgfx_get_ui_rects(float* out, int maxRects);
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

---@class Eqgfx
---@field ui_native boolean|nil  native window enumeration available
---@field dll_stale boolean|nil  loaded DLL predates the one on disk
---@field TargetType table<string, integer>
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
  -- BY NAME from MQ2Main.dll / eqlib.dll exports - no struct offsets. If the
  -- loaded eqgfx.dll predates these exports (game launched before a rebuild),
  -- flag it so scripts tell the user to restart EQ instead of failing quietly.
  M.ui_native = false
  M.dll_stale = not pcall(function() return lib.eqgfx_ui_available end)
  if not M.dll_stale then
    M.ui_native = lib.eqgfx_ui_available() == 1
  end
  return true
end

-- Compile stamp of the LOADED dll (vs whatever is on disk).
function M.build()
  local okk, v = pcall(function() return ffi.string(lib.eqgfx_build()) end)
  return okk and v or 'pre-2026-06-10 (stale - restart EQ)'
end

-- FindMQ2Window ABI variant in use (0 none/unprobed, 1 char*, 2 string_view).
function M.ui_find_mode()
  local okk, v = pcall(function() return lib.eqgfx_ui_find_mode() end)
  return okk and v or -1
end

-- Candidate window names for the native UI scan (newline-joined internally).
function M.set_ui_names(names)
  pcall(function() lib.eqgfx_set_ui_names(table.concat(names, '\n')) end)
end

function M.shutdown() lib.eqgfx_shutdown() end
function M.clear()    lib.eqgfx_clear()    end

function M.add_circle(x, y, z, radius, color, segments)
  lib.eqgfx_add_circle(x, y, z, radius, color, segments or 48)
end
function M.add_arc(cx, cy, cz, radius, startRad, endRad, color, segments)
  lib.eqgfx_add_arc(cx, cy, cz, radius, startRad, endRad, color, segments or 24)
end
function M.add_line(x1, y1, z1, x2, y2, z2, color)
  lib.eqgfx_add_line(x1, y1, z1, x2, y2, z2, color)
end

-- Diagnostics. sceneCalls grows only if MQ is actually invoking our render
-- callback; lastDraws is how many lines it drew on the previous frame.
local _sc, _ld = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
function M.stats()
  lib.eqgfx_stats(_sc, _ld)
  return tonumber(_sc[0]), tonumber(_ld[0])
end

-- World coordinate convention (0..5). Calibrated in-game; see tools/calibrate.lua.
function M.set_axis_mode(mode) lib.eqgfx_set_axis_mode(mode) end
function M.set_convention(c)   lib.eqgfx_set_convention(c) end   -- 0=row-vector, 1=column-vector
function M.set_eyerel(e)       lib.eqgfx_set_eyerel(e and 1 or 0) end
function M.set_wsign(s)        lib.eqgfx_set_wsign(s) end        -- sign of clip.w for front points
function M.set_flipx(f)        lib.eqgfx_set_flipx(f and 1 or 0) end  -- mirror horizontal axis
function M.set_flipy(f)        lib.eqgfx_set_flipy(f and 1 or 0) end  -- mirror vertical axis

local _ex, _ey, _ez = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('float[1]')
function M.get_eye()
  lib.eqgfx_get_eye(_ex, _ey, _ez)
  return tonumber(_ex[0]), tonumber(_ey[0]), tonumber(_ez[0])
end

local _cx, _cy, _cz = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('float[1]')
function M.world_to_camera(x, y, z)
  lib.eqgfx_world_to_camera(x, y, z, _cx, _cy, _cz)
  return tonumber(_cx[0]), tonumber(_cy[0]), tonumber(_cz[0])
end

local _gw, _gh = ffi.new('int[1]'), ffi.new('int[1]')
function M.get_screen()
  lib.eqgfx_get_screen(_gw, _gh)
  return tonumber(_gw[0]), tonumber(_gh[0])
end

-- Line half-width in pixels.
function M.set_thickness(t) lib.eqgfx_set_thickness(t) end

-- Pure 2D screen-space line (pixels), no projection.
function M.add_screen_line(x1, y1, x2, y2, color)
  lib.eqgfx_add_screen_line(x1, y1, x2, y2, color)
end

-- Filled 2D screen-space rectangle (pixels), no projection.
function M.add_screen_rect(x0, y0, x1, y1, color)
  lib.eqgfx_add_screen_rect(x0, y0, x1, y1, color)
end

-- Returns the 16 floats of CRender::matrixViewProj as a flat Lua table (m[1..16]).
local _m16 = ffi.new('float[16]')
function M.dump_matrix()
  lib.eqgfx_dump_matrix(_m16)
  local t = {}
  for i = 1, 16 do t[i] = tonumber(_m16[i - 1]) end
  return t
end

-- Project a world point to screen pixels. Returns sx, sy, visible(bool).
local _sx, _sy, _vis = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('int[1]')
function M.world_to_screen(x, y, z)
  lib.eqgfx_world_to_screen(x, y, z, _sx, _sy, _vis)
  return tonumber(_sx[0]), tonumber(_sy[0]), _vis[0] ~= 0
end

-- Project a world point to RAW screen pixels (no on-screen clamp) and return
-- the engine's in-front-of-camera bool. Use this (not world_to_screen's
-- `visible`) when you need a reliable per-vertex front test for off-screen
-- points - e.g. triangulating a ring you stand inside. Returns sx, sy, infront.
local _px, _py, _pf = ffi.new('float[1]'), ffi.new('float[1]'), ffi.new('int[1]')
function M.project(x, y, z)
  lib.eqgfx_project(x, y, z, _px, _py, _pf)
  return tonumber(_px[0]), tonumber(_py[0]), _pf[0] ~= 0
end

-- Visible, top-level, non-minimized native EQ window rects, straight from
-- CXWndManager. Returns an array of {x0, y0, x1, y1}, or nil when the native
-- path is unavailable.
local _uiBuf = ffi.new('float[512]')   -- 128 rects max
function M.get_ui_rects()
  if not M.ui_native then return nil end
  local n = lib.eqgfx_get_ui_rects(_uiBuf, 128)
  local t = {}
  for i = 0, n - 1 do
    t[i + 1] = { tonumber(_uiBuf[i * 4]),     tonumber(_uiBuf[i * 4 + 1]),
                 tonumber(_uiBuf[i * 4 + 2]), tonumber(_uiBuf[i * 4 + 3]) }
  end
  return t
end

-- Returns a plain Lua table {targetType, range, aeRange, coneStart, coneEnd}
-- or nil if the spell wasn't found.
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

-- Color helpers. Engine RGB byte order is unverified; if colors look wrong
-- in-game, switch argb -> abgr and we'll lock it down.
function M.argb(a, r, g, b)
  return bit.bor(bit.lshift(a, 24), bit.lshift(r, 16), bit.lshift(g, 8), b)
end
function M.abgr(a, b, g, r)
  return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r)
end

-- eSpellTargetType values + LuaLS annotations live in core/_types.lua.
M.TargetType = require('eqgfx.core._types').TargetType

return M
