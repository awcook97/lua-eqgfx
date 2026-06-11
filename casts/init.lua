--[[
  casts/init.lua - shared cast detection & tracking for eqgfx features.

  Spawn.Casting is only accurate for YOURSELF, so other spawns' casts are
  detected from the "<name> begins to cast <spell>" chat line (with the spell
  link kept), and progress is computed as time elapsed since the event against
  the spell's CastTime. The caster name is resolved to cast spawn ID by preferring
  nearby spawns showing cast casting animation.

  Each running script gets its own copy of this state (MQ Lua states are
  isolated), so nameplates and indicators can both use it independently.

  Usage:
    local casts = require('eqgfx.casts')
    casts.init{ log = log, trackSelf = true }
    -- main loop (after mq.doevents()):
    casts.update(os.clock())
    local castInfo = casts.get(spawnID)        -- CastInfo or nil
    local pct, remain = casts.progress(castInfo, os.clock())
]]

local mq    = require('mq')
local types = require('eqgfx.casts._types')

local CAST_ANIMS = types.CAST_ANIMS

local M = { CAST_ANIMS = CAST_ANIMS }

--- Tracker configuration. All fields are optional in init()/config() calls;
--- the defaults below fill the gaps.
---@class CastTrackerCfg
---@field log table|nil # lwlogger-style module (Info/Warn/Debug); nil = silent
---@field trackSelf boolean|nil # include your own casts (via Me.Casting)
---@field interruptDetect boolean|nil # drop NPC casts whose cast animation stops early
---@field grace number|nil # seconds a finished cast lingers (finish pulses)
---@field interruptLinger number|nil # seconds an interrupted cast lingers (fade-outs)
local trackerCfg = {
  log             = nil,
  trackSelf       = true,
  interruptDetect = true,
  grace           = 1.0,
  interruptLinger = 0.8,
}

local active        = {}   -- spawnID -> CastInfo
local pendingByName = {}   -- casterName -> { spellID, spellName, at }
local registered    = false
local selfSpellID   = nil

local function dbg(fmt, ...)
  if trackerCfg.log then trackerCfg.log.Debug(fmt, ...) end
end

--- SpellIcon atlas cell for a spell, or nil when unknown.
---@param spellID integer|nil
---@return integer|nil icon # cell index in the A_SpellIcons atlas
local function spell_icon(spellID)
  if not spellID then return nil end
  local ic = mq.TLO.Spell(spellID).SpellIcon()
  if type(ic) == 'number' and ic >= 0 then return ic end
  return nil
end

--- Cast time of a spell in wall-clock seconds (3s fallback when unknown).
---
--- ```lua
--- local dur = casts.cast_seconds(spellID)
--- ```
---@param spellID integer|nil
---@return number seconds # MyCastTime, else CastTime, else 3
local function cast_seconds(spellID)
  if not spellID then return 3 end
  local ms = mq.TLO.Spell(spellID).MyCastTime()
  if not ms or ms <= 0 then ms = mq.TLO.Spell(spellID).CastTime() end
  if type(ms) == 'number' and ms > 0 then return ms / 1000 end
  return 3
end
M.cast_seconds = cast_seconds

--- Resolve a caster name to its spawn, preferring one in a cast animation
--- (several spawns can share a name).
---@param name string # clean caster name from the chat line
---@return spawn|nil spawn # the spawn TLO, or nil when nothing matches
local function resolve_caster(name)
  local cnt = mq.TLO.SpawnCount('npc ' .. name)() or 0
  local fallback = nil
  for i = 1, cnt do
    local spawn = mq.TLO.NearestSpawn(string.format('%d, npc %s', i, name)) --[[@as spawn]]
    if spawn() and spawn.ID() and spawn.ID() > 0 then
      if CAST_ANIMS[spawn.Animation()] then return spawn end
      fallback = fallback or spawn
    end
  end
  if fallback then return fallback end
  local spawn = mq.TLO.Spawn('npc ' .. name) --[[@as spawn]]
  if spawn() and spawn.ID() and spawn.ID() > 0 then return spawn end
  spawn = mq.TLO.Spawn('pc =' .. name) --[[@as spawn]] -- other players cast too
  if spawn() and spawn.ID() and spawn.ID() > 0 then return spawn end
  return nil
end

--- Build + register an active cast for a resolved spawn.
---@param spawn spawn # spawn TLO of the caster
---@param casterName string
---@param spellID integer|nil
---@param spellName string|nil
---@param timeNow number # tracker clock (os.clock)
local function activate(spawn, casterName, spellID, spellName, timeNow)
  local id = spawn.ID()
  local castInfo = types.CastInfo(id, casterName, spellID, spellName,
                                  cast_seconds(spellID), false, timeNow)
  castInfo.spellIcon = spell_icon(spellID)
  if CAST_ANIMS[spawn.Animation()] then castInfo.sawAnim, castInfo.lastAnimAt = true, timeNow end
  active[id] = castInfo
end

-- Chat event: resolve the caster IMMEDIATELY (handlers run inside
-- mq.doevents, so the cast bar exists the instant the line arrives - no
-- waiting on the next tracker update). Unresolvable names go to pending
-- and get retried from update().
local function on_cast(line, casterName)
  if not casterName or casterName == '' then return end
  if casterName == (mq.TLO.Me.CleanName() or '') then return end  -- self via Me.Casting

  local spellID, spellName
  local okk, links = pcall(mq.ExtractLinks, line)
  if okk and links then
    for _, lnk in ipairs(links) do
      if lnk.type == mq.LinkTypes.Spell then
        local ok2, s = pcall(mq.ParseSpellLink, lnk.link)
        if ok2 and s then spellID, spellName = s.spellID, s.spellName end
        break
      end
    end
  end

  local spawn = resolve_caster(casterName)
  if spawn and spawn.ID() and spawn.ID() > 0 then
    activate(spawn, casterName, spellID, spellName, os.clock())
    dbg('cast evt (instant): "%s" -> %s', casterName, tostring(spellName))
  else
    pendingByName[casterName] = { spellID = spellID, spellName = spellName, at = os.clock() }
    dbg('cast evt (pending): "%s" -> %s', casterName, tostring(spellName))
  end
end

-- Interrupt lines name the caster directly - far more reliable than the
-- animation heuristic (which needs the spawn close enough to see the anim).
local function on_interrupt(name)
  if not name or name == '' then return end
  local timeNow = os.clock()
  for _, cast in pairs(active) do
    if not cast.isSelf and not cast.interrupted and cast.casterName == name then
      cast.interrupted, cast.interruptedAt = true, timeNow
      dbg('cast interrupted (event): %s', name)
    end
  end
  pendingByName[name] = nil
end

--- Set up the tracker: registers the "begins to cast" / interrupt chat
--- events (once) and applies config overrides. Cast detection rides on those
--- events, so your main loop MUST call mq.doevents().
---
--- ```lua
--- local casts = require('eqgfx.casts')
--- casts.init{ trackSelf = true }
--- while true do
---   mq.doevents()
---   casts.update()
---   mq.delay(50)
--- end
--- ```
---@param opts CastTrackerCfg|nil # overrides: log, trackSelf, interruptDetect, grace, interruptLinger
function M.init(opts)
  if opts then for k, v in pairs(opts) do trackerCfg[k] = v end end
  if registered then return end
  registered = true
  -- "begins to cast a spell." and "begins casting <spell>." - the named/link
  -- form carries the spell link in the raw line (keepLinks).
  mq.event('eqgfx_casts1', "#1# begins to cast #2#.#*#", function(l, n) on_cast(l, n) end, { keepLinks = true })
  mq.event('eqgfx_casts2', "#1# begins casting #2#.#*#", function(l, n) on_cast(l, n) end, { keepLinks = true })
  mq.event('eqgfx_casts_i1', "#1#'s casting is interrupted#*#",     function(_, n) on_interrupt(n) end)
  mq.event('eqgfx_casts_i2', "#1#'s spell is interrupted#*#",        function(_, n) on_interrupt(n) end)
  -- actual live format: "Soandso's Adamant Stance spell is interrupted."
  mq.event('eqgfx_casts_i3', "#1#'s #2# spell is interrupted#*#",    function(_, n) on_interrupt(n) end)
  mq.event('eqgfx_casts_i4', "#1#'s #2# casting is interrupted#*#",  function(_, n) on_interrupt(n) end)
end

--- Change tracker config at runtime (settings menus call this every pass).
---
--- ```lua
--- casts.config{ interruptDetect = cfg.castbar.interruptDetect }
--- ```
---@param opts table # any CastTrackerCfg fields to override
function M.config(opts)
  for k, v in pairs(opts) do trackerCfg[k] = v end
end

local function update_self(timeNow)
  local myid = mq.TLO.Me.ID()
  if not myid or myid <= 0 then return end
  local sc = mq.TLO.Me.Casting.ID()
  if sc and sc > 0 then
    if selfSpellID ~= sc then
      selfSpellID = sc
      local castInfo = types.CastInfo(myid, mq.TLO.Me.CleanName() or 'me', sc,
                                mq.TLO.Spell(sc).Name(), cast_seconds(sc), true, timeNow)
      castInfo.spellIcon = spell_icon(sc)
      active[myid] = castInfo
    end
  else
    selfSpellID = nil
    local cast = active[myid]
    if cast and cast.isSelf and not cast.done then
      cast.done = true
      -- ended early -> interrupted; otherwise linger for the finish pulse.
      if timeNow < cast.startedAt + cast.duration - 0.25 then
        cast.interrupted, cast.interruptedAt = true, timeNow
      end
    end
  end
end

--- The tracker's clock. Spell durations are wall-clock seconds, so cast math
--- (progress/expiry) must use THIS time base, not a frame counter.
---
--- ```lua
--- local pct, remain = casts.progress(info, casts.now())
--- ```
---@return number now # os.clock() seconds
function M.now()
  return os.clock()
end

--- Advance the tracker: pick up my own casts (Me.Casting), retry unresolved
--- caster names, run interrupt detection, expire finished casts. Call once
--- per main-loop pass, after mq.doevents().
function M.update()
  local timeNow = os.clock()
  if trackerCfg.trackSelf then update_self(timeNow) end

  -- Retry casts whose caster couldn't be resolved at event time.
  for name, pending in pairs(pendingByName) do
    local spawn = resolve_caster(name)
    if spawn and spawn.ID() and spawn.ID() > 0 then
      activate(spawn, name, pending.spellID, pending.spellName, timeNow)
      pendingByName[name] = nil
    elseif timeNow - pending.at > 3 then
      pendingByName[name] = nil
    end
  end

  -- Interrupt heuristic + expiry.
  for id, cast in pairs(active) do
    if not cast.isSelf and not cast.interrupted and trackerCfg.interruptDetect then
      local spawn = mq.TLO.Spawn(id)
      if spawn.ID() == id then
        local anim = spawn.Animation()
        if CAST_ANIMS[anim] then
          cast.sawAnim, cast.lastAnimAt = true, timeNow
        elseif cast.sawAnim and cast.lastAnimAt
           and timeNow - cast.lastAnimAt > 0.3
           and timeNow < cast.startedAt + cast.duration - 0.2 then
          cast.interrupted, cast.interruptedAt = true, timeNow
          dbg('cast interrupted: %s (%s)', cast.casterName, tostring(cast.spellName))
        end
      end
    end

    if cast.interrupted then
      if timeNow > (cast.interruptedAt or timeNow) + trackerCfg.interruptLinger then active[id] = nil end
    elseif timeNow > cast.startedAt + cast.duration + trackerCfg.grace then
      active[id] = nil
    end
  end
end

--- The active cast for one spawn, if any.
---
--- ```lua
--- local info = casts.get(mq.TLO.Target.ID() or 0)
--- if info and not info.interrupted then ... end
--- ```
---@param spawnID integer # caster spawn ID
---@return CastInfo|nil castInfo # nil when that spawn isn't casting
function M.get(spawnID) return active[spawnID] end

--- Every cast currently in flight, keyed by caster spawn ID. Includes
--- recently finished/interrupted entries while they linger for fade-outs.
---@return table<integer, CastInfo> active
function M.all() return active end

--- Progress of a cast on the tracker clock.
---
--- ```lua
--- local pct, remain = casts.progress(info, casts.now())
--- bar_fill(pct); label(string.format('%.1fs', remain))
--- ```
---@param castInfo CastInfo
---@param timeNow number # casts.now() - NOT a frame counter
---@return number pct # fraction 0..1, clamped
---@return number remain # seconds remaining, >= 0
function M.progress(castInfo, timeNow)
  local elapsed = timeNow - castInfo.startedAt
  local pct = (castInfo.duration > 0) and (elapsed / castInfo.duration) or 1
  if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
  local remain = castInfo.duration - elapsed
  if remain < 0 then remain = 0 end
  return pct, remain
end

return M
