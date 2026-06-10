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
        /aering [r]    toggle a fixed debug ring of radius r around YOU
        /aerad  r      set the debug ring radius
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

settings.load()
casts.init{ log = log, trackSelf = true, grace = 0.5 }

---@type table<integer, ActiveCast>
local active = {}

local function classify_friend(sp)
  local t = sp.Type()
  if t == 'PC' or t == 'Pet' or t == 'Mercenary' then return true end
  if t == 'NPC' then return not sp.Aggressive() end
  return true
end

----------------------------------------------------------------------------
-- EQBC: broadcast resolved targets; ingest peers' resolutions.
----------------------------------------------------------------------------
local function eqbc_ok()
  return mq.TLO.Plugin('mq2eqbc').IsLoaded() and mq.TLO.EQBC.Connected()
end

local function announce(casterID, spellID, targetID)
  if not eqbc_ok() then return end
  mq.cmdf('/squelch /bc eqgfx_cast=%d=%d=%d', casterID, spellID or 0, targetID or 0)
end

mq.event('eqgfx_cast_in', "#*#eqgfx_cast=#1#=#2#=#3##*#", function(_, cid, sid, vid)
  cid, sid, vid = tonumber(cid), tonumber(sid), tonumber(vid)
  if not cid or cid <= 0 then return end
  local a = active[cid]
  if not a then
    -- caster may be out of our detection range; build a stub from the broadcast.
    a = { id = cid, spellID = (sid and sid > 0) and sid or nil, name = '?',
          isSelf = false, friend = false, stub = true,
          expireAt = os.clock() + casts.cast_seconds(sid) + 1 }
    a.geom = a.spellID and eqgfx.spell_geom(a.spellID) or nil
    active[cid] = a
  end
  if vid and vid > 0 then a.targetID = vid end
end)

----------------------------------------------------------------------------
-- Per-frame draw callback.
----------------------------------------------------------------------------
local function draw()
  -- background list: world geometry stays under ImGui windows
  local dl = ImGui.GetBackgroundDrawList()

  if settings.data.showDebugRing then render.draw_debug_ring(dl) end

  for _, a in pairs(active) do
    render.draw_active(dl, a)
  end

  menu.draw()
end

mq.imgui.init('eqgfx_indicators', draw)

----------------------------------------------------------------------------
-- Binds.
----------------------------------------------------------------------------
mq.bind('/aemenu', function() menu.toggle() end)
mq.bind('/aering', function(r)
  local S = settings.data
  if r and r ~= '' then S.debugRadius = tonumber(r) or S.debugRadius end
  S.showDebugRing = not S.showDebugRing
  settings.mark_dirty()
  log.Info('debug ring = %s (radius %g)', tostring(S.showDebugRing), S.debugRadius)
end)
mq.bind('/aerad', function(r)
  local S = settings.data
  S.debugRadius = tonumber(r) or S.debugRadius
  settings.mark_dirty()
  log.Info('debug ring radius = %g', S.debugRadius)
end)
mq.bind('/aez', function(z)
  local S = settings.data
  S.groundOffset = tonumber(z) or S.groundOffset
  settings.mark_dirty()
  log.Info('ground offset = %g', S.groundOffset)
end)

log.Info('spell indicators running. /aemenu = settings, /aering = debug ring.')

----------------------------------------------------------------------------
-- Main loop: tracker -> active sync, target announce, stub expiry, save.
----------------------------------------------------------------------------
while true do
  mq.doevents()
  local now = os.clock()
  casts.update(now)

  -- Sync the shared tracker into our active set (geometry + friend/foe).
  local seen = {}
  for id, ci in pairs(casts.all()) do
    if not (ci.interrupted or (ci.isSelf and ci.done)) then
      seen[id] = true
      local a = active[id]
      if not a or a.spellID ~= ci.spellID or a.castStart ~= ci.startedAt then
        local sp = mq.TLO.Spawn(id)
        active[id] = {
          id        = id,
          spellID   = ci.spellID,
          castStart = ci.startedAt,
          geom      = ci.spellID and eqgfx.spell_geom(ci.spellID) or nil,
          name      = ci.casterName,
          isSelf    = ci.isSelf,
          friend    = ci.isSelf or (sp() and classify_friend(sp)) or false,
          targetID  = a and a.targetID or nil,
        }
      end
    end
  end
  for id, a in pairs(active) do
    if not seen[id] then
      if a.stub then
        if now > (a.expireAt or 0) then active[id] = nil end
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

  settings.maybe_save(now, log)
  mq.delay(50)
end
