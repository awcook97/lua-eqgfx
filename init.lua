--[[
  eqgfx.lua - LuaJIT FFI binding for eqgfx.dll (native EQGraphics drawing).

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
]]

-- Optional hard override for the DLL location (Windows-style path). Normally
-- leave nil: we locate eqgfx.dll next to this script so the project is portable.
local DLL_PATH = nil

local function locate_dll()
  if DLL_PATH then return DLL_PATH end
  local src = debug.getinfo(1, 'S').source        -- "@<dir>/init.lua"
  if src:sub(1, 1) == '@' then
    return (src:sub(2):gsub('[^/\\]+$', '')) .. 'eqgfx.dll'
  end
  return 'eqgfx'                                   -- fall back to OS search path
end

local eqlib = ffi.load('eqlib')                    -- already in-process; read its exports
local lib
do
  local path = locate_dll()
  local okk, l = pcall(ffi.load, path)
  if not okk then okk, l = pcall(ffi.load, 'eqgfx') end   -- fall back to PATH/name
  if not okk then error('[eqgfx] could not load eqgfx.dll (tried: ' .. tostring(path) .. ')') end
  lib = l
end

local M = {}
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
  return true
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

-- World coordinate convention (0..5). Calibrated in-game; see eqgfx_calibrate.lua.
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

-- eSpellTargetType values (src/eqlib/include/eqlib/game/Spells.h)
M.TargetType = {
  AEPC_v1         = 2,   Group_v1        = 3,   PBAE            = 4,
  Single          = 5,   Self            = 6,   TargetArea      = 8,
  TargetAEDrain   = 20,  TargetAEUndead  = 24,  TargetAESummoned= 25,
  CasterAreaPC    = 36,  CasterAreaNPC   = 37,  AEPC_v2         = 40,
  Group_v2        = 41,  DirectionalCone = 42,  Beam            = 44,
  FreeTarget      = 45,  AreaDetrimental = 50,
}

return M
