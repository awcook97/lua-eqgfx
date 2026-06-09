--[[
  healthbars.lua - floating, animated HP bars over nearby spawns.

  Projection: native eqgfx world->screen.
  Drawing:    MQ ImGui foreground draw list - smooth, no flicker.

  Positions are read LIVE every frame in the draw callback (frame-accurate, so
  bars stick to spawns as you/they move). A slow loop only decides which spawns
  to show (range/NPC filter) and prunes ones that leave.

  Run:  /lua run eqgfx/healthbars
  Stop: /lua stop eqgfx/healthbars
  Opts: /hbradius N   range filter (default 200)
        /hbnpc        toggle NPC-only (default on)
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local ImGui = require('ImGui')

local ok, err = eqgfx.init()
if not ok then printf('[hb] init failed: %s', err) return end

local BAR_W, BAR_H = 80, 9
local HEAD_Z       = 4
local ROUND        = 2.0

local radius, npcOnly = 200, true
mq.bind('/hbradius', function(n) radius = tonumber(n) or radius; printf('[hb] radius=%d', radius) end)
mq.bind('/hbnpc',    function()  npcOnly = not npcOnly; printf('[hb] npc-only=%s', tostring(npcOnly)) end)

local function col(r, g, b, a)
  a = a or 255
  return bit.bor(bit.band(r,255), bit.lshift(bit.band(g,255),8),
                 bit.lshift(bit.band(b,255),16), bit.lshift(bit.band(a,255),24))
end
local function hp_col(p, a)
  p = math.max(0, math.min(1, p))
  local r, g
  if p < 0.5 then r, g = 255, math.floor(510 * p)
  else            r, g = math.floor(510 * (1 - p)), 255 end
  return col(r, g, 40, a)
end

-- id -> { disp, name, lost=time|nil, sx, sy }  (lost set when it leaves the set)
local bars = {}

local function draw_bar(dl, sx, sy, pct, name, alpha)
  local x0, y0 = sx - BAR_W * 0.5, sy - BAR_H * 0.5
  local x1, y1 = sx + BAR_W * 0.5, sy + BAR_H * 0.5
  dl:AddRectFilled(ImVec2(x0 - 1, y0 - 1), ImVec2(x1 + 1, y1 + 1), col(0, 0, 0, alpha), ROUND)
  dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), col(28, 28, 28, alpha), ROUND)
  dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x0 + BAR_W * pct, y1), hp_col(pct, alpha), ROUND)
  dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), col(0, 0, 0, alpha), ROUND)
  if name then dl:AddText(ImVec2(x0, y0 - 14), col(255, 255, 255, alpha), name) end
end

local lastFrame = os.clock()
local function draw()
  local now = os.clock()
  local dt  = now - lastFrame; lastFrame = now
  local dl  = ImGui.GetForegroundDrawList()

  for id, b in pairs(bars) do
    if not b.lost then
      -- LIVE read every frame -> bars track movement exactly.
      local sp = mq.TLO.Spawn(id)
      if sp.ID() == id and sp.X() then
        local pct = (sp.PctHPs() or 0) / 100
        b.disp = b.disp + (pct - b.disp) * math.min(1, dt * 10)
        b.name = sp.CleanName() or b.name
        local sx, sy, vis = eqgfx.world_to_screen(sp.X(), sp.Y(), sp.Z() + HEAD_Z)
        if vis then
          b.sx, b.sy = sx, sy
          draw_bar(dl, sx, sy, b.disp, b.name, 255)
        end
      else
        b.lost = now      -- spawn despawned
      end
    else
      -- fade out at last known screen position
      local age = now - b.lost
      if age > 0.5 then bars[id] = nil
      elseif b.sx then
        draw_bar(dl, b.sx, b.sy, b.disp, b.name, math.floor(255 * (1 - age / 0.5)))
      end
    end
  end
end

mq.imgui.init('healthbars', draw)
print('[hb] health bars running (ImGui, live tracking). /hbradius N  /hbnpc')

-- Slow discovery loop: decide the visible set; mark departed spawns lost.
local function spec() return (npcOnly and 'npc ' or '') .. 'radius ' .. radius end
while true do
  local present = {}
  local s   = spec()
  local cnt = mq.TLO.SpawnCount(s)() or 0
  for i = 1, cnt do
    local sp = mq.TLO.NearestSpawn(string.format('%d, %s', i, s))
    if sp() and sp.X() then
      local id = sp.ID()
      present[id] = true
      local b = bars[id]
      if b then b.lost = nil
      else bars[id] = { disp = (sp.PctHPs() or 0) / 100, name = sp.CleanName() } end
    end
  end
  for id, b in pairs(bars) do
    if not present[id] and not b.lost then b.lost = os.clock() end  -- left range -> fade
  end
  mq.delay(150)
end
