--[[
  nameplates/init.lua - custom nameplates: animated HP bar + name + cast bar.

  Projection: native eqgfx world->screen.
  Drawing:    MQ ImGui foreground draw list - smooth, no flicker.

  Positions are read LIVE every frame in the draw callback (frame-accurate, so
  plates stick to spawns as you/they move). A slow loop only decides which
  spawns get plates (range/NPC filter) and prunes ones that leave.

  Cast bars: your own casts via Me.Casting; other spawns via the shared
  eqgfx.casts tracker ("begins to cast" chat events + Spell.CastTime), since
  Spawn.Casting is only accurate for yourself.

  Run:  /lua run eqgfx/nameplates
  Stop: /lua stop eqgfx/nameplates
  Opts: /npmenu       in-game customization window (auto-saved settings)
        /npradius N   range filter
        /nppcs        toggle PC plates
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local ImGui = require('ImGui')
local log   = require('eqgfx.lib.lwlogger')

local types    = require('eqgfx.nameplates._types')
local anim     = require('eqgfx.nameplates.anim')
local settings = require('eqgfx.nameplates.settings')
local render   = require('eqgfx.nameplates.render')
local menu     = require('eqgfx.nameplates.menu')
local casts    = require('eqgfx.casts')

log.SetAppName('eqgfx')
log.SetModuleName('nameplates')
log.SetColors(true)
log.SetIncludeCharacter('Server.Character.Zone')
log.SetIncludeTime('milliseconds')
log.SetLevel(log.INFO)
log.SetOutputFile(mq.configDir .. '/eqgfx.log')

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end

settings.load()
casts.init{ log = log, trackSelf = true,
            interruptDetect = settings.data.castbar.interruptDetect }

---@type table<integer, Plate>
local plates = {}

----------------------------------------------------------------------------
-- Per-frame draw callback: live position reads + all animation state.
----------------------------------------------------------------------------
local lastFrame = os.clock()

local function update_live(p, sp, S, now, dt)
  local hp = (sp.PctHPs() or 0) / 100

  if S.anim.damageFlash and hp < p.lastHp - S.anim.flashThreshold then
    p.flashAt = now
  end
  p.lastHp = hp

  if S.anim.hpSmoothing then
    p.dispHp = anim.approach(p.dispHp, hp, S.anim.hpSpeed, dt)
  else
    p.dispHp = hp
  end

  p.name  = sp.CleanName() or p.name
  p.alpha = S.anim.fadeIn
            and anim.clamp01((now - p.bornAt) / math.max(S.anim.fadeInDur, 0.01))
            or 1
  p.scale = S.anim.appearPop
            and anim.ease_out_back((now - p.bornAt) / math.max(S.anim.popDur, 0.01))
            or 1
end

local function draw()
  local now = os.clock()
  local dt  = now - lastFrame; lastFrame = now
  local S   = settings.data
  local dl  = ImGui.GetForegroundDrawList()
  render.probe_caps(dl)

  if S.enabled then
    for id, p in pairs(plates) do
      if not p.lostAt then
        -- LIVE read every frame -> plates track movement exactly.
        local sp = mq.TLO.Spawn(id)
        if sp.ID() == id and sp.X() then
          update_live(p, sp, S, now, dt)
          local sx, sy, vis = eqgfx.world_to_screen(sp.X(), sp.Y(), sp.Z() + S.bar.zOffset)
          if vis then
            p.sx, p.sy = sx, sy
            render.plate(dl, S, p, S.castbar.show and casts.get(id) or nil, now)
          end
        else
          p.lostAt, p.lossAlpha = now, p.alpha       -- spawn despawned
        end
      else
        -- fade out at last known screen position
        local f = S.anim.fadeOut and anim.fade(p.lostAt, S.anim.fadeOutDur, now) or 0
        if f <= 0 then
          plates[id] = nil
        elseif p.sx then
          p.alpha = (p.lossAlpha or 1) * f
          render.plate(dl, S, p, nil, now)
        end
      end
    end
  end

  menu.draw(render.caps)
end

mq.imgui.init('eqgfx_nameplates', draw)

----------------------------------------------------------------------------
-- Binds.
----------------------------------------------------------------------------
mq.bind('/npmenu', function() menu.toggle() end)
mq.bind('/npradius', function(n)
  settings.data.radius = tonumber(n) or settings.data.radius
  settings.mark_dirty()
  log.Info('radius=%d', settings.data.radius)
end)
mq.bind('/nppcs', function()
  settings.data.show.pcs = not settings.data.show.pcs
  settings.mark_dirty()
  log.Info('show PCs=%s', tostring(settings.data.show.pcs))
end)

log.Info('nameplates running. /npmenu = customization, /npradius N, /nppcs')

----------------------------------------------------------------------------
-- Main loop: cast tracking + slow plate discovery + debounced settings save.
----------------------------------------------------------------------------
local lastDiscover = 0

-- Only real creatures get plates. The plain radius spawn search also returns
-- auras, campfires, banners, totems, corpses, traps... - all filtered here.
local function allowed(S, sp, id, myID)
  if id == myID then return S.show.self end
  local t = sp.Type()
  if t == 'NPC' then return S.show.npcs end
  if t == 'PC'  then return S.show.pcs end
  if t == 'Pet' or t == 'Mercenary' then return S.show.pets end
  return false
end

local function discover(now)
  local S = settings.data
  local myID = mq.TLO.Me.ID()
  local spec = 'radius ' .. S.radius
  local present = {}
  local cnt = mq.TLO.SpawnCount(spec)() or 0
  for i = 1, cnt do
    local sp = mq.TLO.NearestSpawn(string.format('%d, %s', i, spec))
    if sp() and sp.X() then
      local id = sp.ID()
      if allowed(S, sp, id, myID) then
        present[id] = true
        local p = plates[id]
        if p then
          if p.lostAt then p.lostAt, p.lossAlpha, p.bornAt = nil, nil, now - 1 end
        else
          plates[id] = types.Plate.new(id, sp.CleanName() or '?',
                                       (sp.PctHPs() or 0) / 100, now)
        end
      end
    end
  end
  for id, p in pairs(plates) do
    if not present[id] and not p.lostAt then
      p.lostAt, p.lossAlpha = now, p.alpha           -- left range -> fade
    end
  end
end

while true do
  mq.doevents()
  local now = os.clock()
  local S = settings.data

  casts.config{ interruptDetect = S.castbar.interruptDetect }
  casts.update(now)

  if S.enabled then
    if now - lastDiscover >= 0.15 then
      discover(now)
      lastDiscover = now
    end
  elseif next(plates) then
    plates = {}
  end

  settings.maybe_save(now, log)
  mq.delay(50)
end
