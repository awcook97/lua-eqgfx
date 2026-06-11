--[[
  indicators/init.lua - draw the affected area / target of spells being cast,
  for YOU and for nearby mobs (and optionally friendlies).

  Cast detection lives in the shared eqgfx.casts tracker ("begins to cast"
  chat events + spell links + casting animations); spell geometry comes from
  the native eqgfx.spell_geom(id).

  TARGET RESOLUTION (cross-box via EQBC)
    A mob's target is only readable when YOU have it targeted
    (Target.AggroHolder). Whichever box has the caster targeted resolves the
    victim and broadcasts "eqgfx_cast=<casterID>=<spellID>=<targetID>" over
    EQBC; every box then draws the line / target-centered ring, even ones
    that never targeted the caster.

  Run:  /lua run eqgfx/indicators
  Stop: /lua stop eqgfx/indicators
  Opts: /aemenu        settings window (auto-saved under
                       <config>/eqgfx/, scope switchable in the menu)
        /aering [rect]    toggle activeCast fixed debug ring of radius rect around YOU
        /aerad  rect      set the debug ring radius
        /aez    z      ground offset: how far below reported Z to draw areas
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local ImGui = require('ImGui')
local log   = require('eqgfx.lib.lwlogger')

local settings = require('eqgfx.indicators.settings')
local render   = require('eqgfx.indicators.render')
local menu     = require('eqgfx.indicators.menu')
local casts    = require('eqgfx.casts')
local uirects  = require('eqgfx.lib.uirects')

log.SetAppName('eqgfx')
log.SetModuleName('indicators')
log.SetColors(true)
log.SetIncludeTime('milliseconds')
log.SetLevel(log.INFO)
log.SetIncludeCharacter('Server.Character.Zone')
log.SetOutputFile(mq.configDir .. '/eqgfx.log')
log.SetIncludeSource('trace')

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end
if eqgfx.dll_stale then
  log.Warn('eqgfx.dll on disk is newer than the one loaded in this game session - restart EQ to load it (native UI occlusion disabled until then)')
end

settings.load()
casts.init{ log = log, trackSelf = true, grace = 0.5 }

---@type table<integer, ActiveCast>
local active = {}

--- Is this caster on the players' side? PCs/pets/mercs always; NPCs only
--- when not aggressive. Decides the indicator color category.
---@param spawn spawn # caster spawn TLO
---@return boolean friend
local function classify_friend(spawn)
  local t = spawn.Type()
  if t == 'PC' or t == 'Pet' or t == 'Mercenary' then return true end
  if t == 'NPC' then return not spawn.Aggressive() end
  return true
end

----------------------------------------------------------------------------
-- EQBC: broadcast resolved targets; ingest peers' resolutions.
----------------------------------------------------------------------------
--- Is EQBC loaded and connected? (Target sharing is silently off otherwise.)
---@return boolean|nil ok
local function eqbc_ok()
  return mq.TLO.Plugin('mq2eqbc').IsLoaded() and mq.TLO.EQBC.Connected()
end

--- Broadcast a resolved cast target to the other boxes
--- ("eqgfx_cast=casterID=spellID=targetID" over /bc).
---@param casterID integer
---@param spellID integer|nil # 0 when unknown
---@param targetID integer|nil # the resolved victim
local function announce(casterID, spellID, targetID)
  if not eqbc_ok() then return end
  mq.cmdf('/squelch /bc eqgfx_cast=%d=%d=%d', casterID, spellID or 0, targetID or 0)
end

mq.event('eqgfx_cast_in', "#*#eqgfx_cast=#1#=#2#=#3##*#", function(_, cid, sid, vid)
  cid, sid, vid = tonumber(cid), tonumber(sid), tonumber(vid)
  if not cid or cid <= 0 then return end
  local activeCast = active[cid]
  if not activeCast then
    -- caster may be out of our detection range; build a stub from the broadcast.
    activeCast = { id = cid, spellID = (sid and sid > 0) and sid or nil, name = '?',
          isSelf = false, friend = false, stub = true, castStart = casts.now(),
          expireAt = casts.now() + casts.cast_seconds(sid) + 1 }
    activeCast.geom = activeCast.spellID and eqgfx.spell_geom(activeCast.spellID) or nil
    active[cid] = activeCast
  end
  if vid and vid > 0 then activeCast.targetID = vid end
end)

----------------------------------------------------------------------------
-- Per-frame draw callback. With native UI rects available, world geometry
-- is drawn clipped to the screen regions NOT covered by EQ windows, so the
-- indicators appear underneath the native UI.
----------------------------------------------------------------------------
local canClip   -- PushClipRect capability, probed once

--- Draw every active cast (and the debug ring) once. Called once per
--- visible screen region by draw() so geometry clips around EQ windows.
---@param drawList ImDrawList
local function draw_all(drawList)
  if (settings.data or {}).showDebugRing then render.draw_debug_ring(drawList) end
  for _, activeCast in pairs(active) do
    render.draw_active(drawList, activeCast)
  end
end

--- Per-frame ImGui callback: probe clipping once, then draw the scene
--- clipped to the screen-minus-windows regions (or unclipped when the
--- native scan / clipping is unavailable). Also renders the menu.
local function draw()
  local drawList = ImGui.GetBackgroundDrawList()
  if canClip == nil then
    canClip = pcall(function()
      drawList:PushClipRect(ImVec2(0, 0), ImVec2(1, 1), false)
      drawList:PopClipRect()
    end) and true or false
  end

  local rects, native = uirects.get()
  if canClip and native and #rects > 0 then
    local sw, sh = eqgfx.get_screen()
    if sw and sw > 0 then
      for _, rect in ipairs(uirects.regions(rects, sw, sh)) do
        drawList:PushClipRect(ImVec2(rect[1], rect[2]), ImVec2(rect[3], rect[4]), false)
        draw_all(drawList)
        drawList:PopClipRect()
      end
    else
      draw_all(drawList)
    end
  else
    draw_all(drawList)
  end

  menu.draw()
end

mq.imgui.init('eqgfx_indicators', draw)

----------------------------------------------------------------------------
-- Binds.
----------------------------------------------------------------------------
mq.bind('/aemenu', function() menu.toggle() end)
mq.bind('/aering', function(rect)
  local cfg = settings.data or {}
  if rect and rect ~= '' then cfg.debugRadius = tonumber(rect) or cfg.debugRadius end
  cfg.showDebugRing = not cfg.showDebugRing
  settings.mark_dirty()
  log.Info('debug ring = %s (radius %g)', tostring(cfg.showDebugRing), cfg.debugRadius)
end)
mq.bind('/aerad', function(rect)
  local cfg = settings.data or {}
  cfg.debugRadius = tonumber(rect) or cfg.debugRadius
  settings.mark_dirty()
  log.Info('debug ring radius = %g', cfg.debugRadius)
end)
mq.bind('/aez', function(z)
  local cfg = settings.data or {}
  cfg.groundOffset = tonumber(z) or cfg.groundOffset
  settings.mark_dirty()
  log.Info('ground offset = %g', cfg.groundOffset)
end)

log.Info('spell indicators running. /aemenu = settings, /aering = debug ring.')

----------------------------------------------------------------------------
-- Main loop: tracker -> active sync, target announce, stub expiry, save.
----------------------------------------------------------------------------
while true do
  mq.doevents()
  casts.update()
  local timeNow = casts.now()   -- cast/stub expiry lives in the cast domain

  -- Sync the shared tracker into our active set (geometry + friend/foe).
  local seen = {}
  for id, castInfo in pairs(casts.all()) do
    if not (castInfo.interrupted or (castInfo.isSelf and castInfo.done)) then
      seen[id] = true
      local activeCast = active[id]
      if not activeCast or activeCast.spellID ~= castInfo.spellID or activeCast.castStart ~= castInfo.startedAt then
        local spawn = mq.TLO.Spawn(id) --[[@as spawn]]
        active[id] = {
          id        = id,
          spellID   = castInfo.spellID,
          castStart = castInfo.startedAt,
          geom      = castInfo.spellID and eqgfx.spell_geom(castInfo.spellID) or nil,
          name      = castInfo.casterName,
          isSelf    = castInfo.isSelf,
          friend    = castInfo.isSelf or (spawn() and classify_friend(spawn)) or false,
          targetID  = activeCast and activeCast.targetID or nil,
        }
      end
    end
  end
  for id, activeCast in pairs(active) do
    if not seen[id] then
      if activeCast.stub then
        if timeNow > (activeCast.expireAt or 0) then active[id] = nil end
      else
        active[id] = nil       -- tracker expired / interrupted it
      end
    end
  end

  -- If I have a caster targeted, resolve its victim and broadcast it.
  local tgt = mq.TLO.Target
  local tid = tgt.ID()
  if tid and active[tid] and not active[tid].isSelf then
    local vid = tgt.AggroHolder.ID()
    if vid and vid > 0 and active[tid].targetID ~= vid then
      active[tid].targetID = vid
      announce(tid, active[tid].spellID or 0, vid)
    end
  end

  settings.maybe_save(log)
  mq.delay(50)
end
