--[[
  test/smoke.lua - offline smoke test for eqgfx feature scripts.

  Runs a feature script (nameplates / indicators) under stubbed mq + ImGui:
  startup, 3 main-loop iterations, several draw-callback frames (menu closed
  and open). Catches Lua-level crashes before they ever reach the client.

  Usage:  luajit test/smoke.lua <feature> <project_root> <tmpdir>
]]

local feature, root, tmp = arg[1], arg[2], arg[3]
local mode = arg[4]            -- nil | 'occlude-native' | 'occlude-tlo'
local OCC = mode and mode:match('^occlude') and true or false

-- deterministic, always-advancing clock so timed gates (scan cadence,
-- discovery cadence) fire during the 3 simulated loop ticks
local t0 = 0
rawset(os, 'clock', function() t0 = t0 + 0.05; return t0 end)
package.path = root .. '/../?.lua;' .. root .. '/../?/init.lua;' .. package.path

-- ===== universal TLO proxy: any member chain, calls return nil =====
local function proxy()
  return setmetatable({}, {
    __index = function(self, k)
      local p = proxy()
      rawset(self, k, p)
      return p
    end,
    -- TLO semantics: Node(args) selects a sub-node (callable);
    -- Node() with no args yields the value (nil in the stub).
    __call = function(_, a)
      if a ~= nil then return proxy() end
      return nil
    end,
  })
end

-- ===== mq stub =====
local draws, binds, events = {}, {}, {}
local loops = 0
local mqstub = {
  configDir = tmp,
  TLO = proxy(),
  imgui = { init = function(_, fn) draws[#draws + 1] = fn end },
  event = function(name)
    assert(not events[name], 'duplicate event name: ' .. name)
    events[name] = true
  end,
  bind = function(cmd, fn) binds[cmd] = fn end,
  doevents = function() end,
  delay = function()
    loops = loops + 1
    if loops >= 3 then error('__SMOKE_DONE__', 0) end
  end,
  cmdf = function() end,
  cmd = function() end,
  ExtractLinks = function() return {} end,
  ParseSpellLink = function() return nil end,
  FormatSpellLink = function() return '' end,
  ExecuteTextLink = function() end,
  StripTextLinks = function(s) return s end,
  LinkTypes = { Spell = 1 },
  FindTextureAnimation = function() return nil end,
  pickle = function() end,
  unpickle = function() error('no file', 0) end,
}
package.preload['mq'] = function() return mqstub end

-- ===== ImGui stub =====
local fills = 0
local dl = setmetatable({}, { __index = function(_, k)
  if k == 'AddRectFilled' then return function() fills = fills + 1 end end
  return function() end
end })
local ImGuiStub = setmetatable({
  GetForegroundDrawList = function() return dl end,
  GetBackgroundDrawList = function() return dl end,
  GetWindowDrawList = function() return dl end,
  Begin = function() return true, true end,
  End = function() end,
  CalcTextSize = function() return 10, 13 end,
  GetFontSize = function() return 13 end,
  GetFont = function() return {} end,
  ColorConvertFloat4ToU32 = function() return 0x7f7f7f7f end,
  GetMousePos = function() return 50, 50 end,
  IsMouseDown = function() return false end,
  Text = function() end, TextDisabled = function() end,
  Separator = function() end, SameLine = function() end,
  SetNextWindowPos = function() end, SetNextWindowSize = function() end,
  SetCursorScreenPos = function() end,
  DrawTextureAnimation = function() end,
  TreePop = function() end,
  Button = function() return false end,
  SmallButton = function() return false end,
  RadioButton = function() return false end,
  TreeNode = function() return false end,
}, {
  -- generic widget: (label, value, ...) -> value, changed=false
  __index = function()
    return function(_, v) return v, false end
  end,
})
package.preload['ImGui'] = function() return ImGuiStub end
rawset(_G, 'ImGui', ImGuiStub)
rawset(_G, 'ImVec2', function(x, y) return { x = x, y = y } end)
rawset(_G, 'ImGuiWindowFlags', setmetatable({}, { __index = function() return 1 end }))
rawset(_G, 'ImGuiMouseButton', setmetatable({}, { __index = function() return 1 end }))

-- ===== occlusion-mode stubs: one NPC spawn + one open InventoryWindow =====
local W2S = { x = 300, y = 300 }   -- projection result, mutated by the test
if OCC then
  local function fn(v) return function() return v end end
  local spawn = setmetatable({
    ID = fn(42), X = fn(10), Y = fn(10), Z = fn(5),
    PctHPs = fn(100), CleanName = fn('Dummy'), Type = fn('NPC'),
    Animation = fn(0),
  }, {
    __index = function() return fn(nil) end,
    __call = function() return true end,
  })
  mqstub.TLO.SpawnCount = function() return fn(1) end
  mqstub.TLO.NearestSpawn = function() return spawn end
  mqstub.TLO.Spawn = function() return spawn end

  local invWindow = setmetatable({
    Open = fn(true), Minimized = fn(false),
    X = fn(100), Y = fn(100), Width = fn(600), Height = fn(800),
    Parent = setmetatable({}, { __index = function() return fn(nil) end }),
  }, { __index = function() return fn(nil) end })
  local nullWindow = setmetatable({}, { __index = function() return fn(nil) end })
  mqstub.TLO.Window = function(name)
    if name == 'InventoryWindow' then return invWindow end
    return nullWindow
  end
end

-- ===== eqgfx core stub (FFI bridge can't load off-platform) =====
package.preload['eqgfx'] = function()
  return {
    init = function() return true end,
    shutdown = function() end,
    clear = function() end,
    get_screen = function() return 1920, 1080 end,
    ui_native = (mode ~= 'occlude-tlo'),
    ui_find_mode = function() return 1 end,
    build = function() return 'smoke-stub' end,
    dll_stale = false,
    set_ui_names = function() end,
    get_ui_rects = function()
      if mode == 'occlude-tlo' then return nil end
      if mode == 'occlude-native' then return { { 100, 100, 700, 900 } } end
      if mode == 'occlude-native-empty' then return {} end
      return { { 100, 100, 400, 300 }, { 500, 50, 800, 200 } }
    end,
    world_to_screen = function() return W2S.x, W2S.y, true end,
    project = function() return 320, 240, true end,
    spell_geom = function() return nil end,
    set_thickness = function() end,
    set_flipx = function() end, set_flipy = function() end,
    add_screen_line = function() end, add_screen_rect = function() end,
    add_circle = function() end, add_arc = function() end, add_line = function() end,
    stats = function() return 0, 0 end,
    argb = function() return 0 end,
    abgr = function() return 0 end,
    get_eye = function() return 0, 0, 0 end,
    world_to_camera = function() return 0, 0, 0 end,
    dump_matrix = function() return {} end,
    TargetType = require('eqgfx.core._types').TargetType,
  }
end

-- ===== run the script =====
local okk, err = pcall(dofile, root .. '/' .. feature .. '/init.lua')
if not okk and not tostring(err):find('__SMOKE_DONE__') then
  io.stderr:write('STARTUP/LOOP FAIL: ' .. tostring(err) .. '\n')
  os.exit(1)
end
assert(#draws > 0, 'no imgui draw callback registered')

-- draw frames: menu closed
for frame = 1, 3 do
  for _, fn in ipairs(draws) do
    local ok2, e2 = pcall(fn)
    if not ok2 then
      io.stderr:write('DRAW FAIL (frame ' .. frame .. '): ' .. tostring(e2) .. '\n')
      os.exit(1)
    end
  end
end

-- draw frames: menu open (smokes every widget path)
local menu = package.loaded['eqgfx.' .. feature .. '.menu']
if menu then
  menu.open = true
  for _, fn in ipairs(draws) do
    local ok2, e2 = pcall(fn)
    if not ok2 then
      io.stderr:write('MENU DRAW FAIL: ' .. tostring(e2) .. '\n')
      os.exit(1)
    end
  end
end

-- exercise binds with no args
for cmd, fn in pairs(binds) do
  local ok2, e2 = pcall(fn)
  if not ok2 then
    io.stderr:write('BIND FAIL ' .. cmd .. ': ' .. tostring(e2) .. '\n')
    os.exit(1)
  end
end

if OCC and feature == 'nameplates' then
  if mode == 'occlude-tlo' or mode == 'occlude-native-empty' then
    -- occlude-tlo: no native scan -> occlusion OFF (never a slow Lua sweep).
    -- occlude-native-empty: native works, zero rects -> no windows open.
    -- Either way plates must draw everywhere and the loop stays fast.
    W2S.x, W2S.y = 300, 300
    fills = 0
    for _ = 1, 3 do for _, fn2 in ipairs(draws) do assert(pcall(fn2)) end end
    assert(fills > 0, mode .. ': plate should draw when occlusion is off')
  else
    -- plate projected INSIDE the open window rect -> must not draw
    W2S.x, W2S.y = 300, 300
    fills = 0
    for _ = 1, 3 do for _, fn2 in ipairs(draws) do assert(pcall(fn2)) end end
    assert(fills == 0, mode .. ': plate drew INSIDE window rect (fills=' .. fills .. ')')

    -- plate projected OUTSIDE the rect -> must draw
    W2S.x, W2S.y = 1500, 300
    fills = 0
    for _ = 1, 3 do for _, fn2 in ipairs(draws) do assert(pcall(fn2)) end end
    assert(fills > 0, mode .. ': plate did NOT draw outside window rect')
  end
  print('OCCLUSION OK: ' .. mode)
end

print('SMOKE OK: ' .. feature .. ' (loops=' .. loops .. ', draws=' .. #draws .. ')')
