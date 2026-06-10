--[[
  casts/init.lua - shared cast detection & tracking for eqgfx features.

  Spawn.Casting is only accurate for YOURSELF, so other spawns' casts are
  detected from the "<name> begins to cast <spell>" chat line (with the spell
  link kept), and progress is computed as time elapsed since the event against
  the spell's CastTime. The caster name is resolved to a spawn ID by preferring
  nearby spawns showing a casting animation.

  Each running script gets its own copy of this state (MQ Lua states are
  isolated), so nameplates and indicators can both use it independently.

  Usage:
    local casts = require('eqgfx.casts')
    casts.init{ log = log, trackSelf = true }
    -- main loop (after mq.doevents()):
    casts.update(os.clock())
    local ci = casts.get(spawnID)        -- CastInfo or nil
    local pct, remain = casts.progress(ci, os.clock())
]]

local mq    = require('mq')
local types = require('eqgfx.casts._types')

local CAST_ANIMS = types.CAST_ANIMS

local M = { CAST_ANIMS = CAST_ANIMS }

local cfg = {
  log             = nil,    -- lwlogger-style module (Info/Warn/Debug)
  trackSelf       = true,   -- include your own casts (via Me.Casting)
  interruptDetect = true,   -- drop NPC casts whose cast animation stops early
  grace           = 1.0,    -- seconds a finished cast lingers (finish pulses)
  interruptLinger = 0.8,    -- seconds an interrupted cast lingers (fade-outs)
}

local active        = {}   -- spawnID -> CastInfo
local pendingByName = {}   -- casterName -> { spellID, spellName, at }
local registered    = false
local selfSpellID   = nil

local function dbg(fmt, ...)
  if cfg.log then cfg.log.Debug(fmt, ...) end
end

local function spell_icon(spellID)
  if not spellID then return nil end
  local ic = mq.TLO.Spell(spellID).SpellIcon()
  if type(ic) == 'number' and ic >= 0 then return ic end
  return nil
end

local function cast_seconds(spellID)
  if not spellID then return 3 end
  local ms = mq.TLO.Spell(spellID).MyCastTime()
  if not ms or ms <= 0 then ms = mq.TLO.Spell(spellID).CastTime() end
  if type(ms) == 'number' and ms > 0 then return ms / 1000 end
  return 3
end
M.cast_seconds = cast_seconds

-- Resolve a caster name to its spawn, preferring one in a cast animation.
local function resolve_caster(name)
  local cnt = mq.TLO.SpawnCount('npc ' .. name)() or 0
  local fallback = nil
  for i = 1, cnt do
    local sp = mq.TLO.NearestSpawn(string.format('%d, npc %s', i, name))
    if sp() and sp.ID() and sp.ID() > 0 then
      if CAST_ANIMS[sp.Animation()] then return sp end
      fallback = fallback or sp
    end
  end
  if fallback then return fallback end
  local sp = mq.TLO.Spawn('npc ' .. name)
  if sp() and sp.ID() and sp.ID() > 0 then return sp end
  sp = mq.TLO.Spawn('pc =' .. name)                 -- other players cast too
  if sp() and sp.ID() and sp.ID() > 0 then return sp end
  return nil
end

-- Chat event: stash a pending cast keyed by caster name + spell link's id.
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
  pendingByName[casterName] = { spellID = spellID, spellName = spellName, at = os.clock() }
  dbg('cast evt: "%s" -> %s (id=%s)', casterName, tostring(spellName), tostring(spellID))
end

-- Interrupt lines name the caster directly - far more reliable than the
-- animation heuristic (which needs the spawn close enough to see the anim).
local function on_interrupt(name)
  if not name or name == '' then return end
  local now = os.clock()
  for _, a in pairs(active) do
    if not a.isSelf and not a.interrupted and a.casterName == name then
      a.interrupted, a.interruptedAt = true, now
      dbg('cast interrupted (event): %s', name)
    end
  end
  pendingByName[name] = nil
end

---@param opts table|nil  overrides for cfg fields (log, trackSelf, ...)
function M.init(opts)
  if opts then for k, v in pairs(opts) do cfg[k] = v end end
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

-- Runtime toggles (settings menus call this).
function M.config(opts)
  for k, v in pairs(opts) do cfg[k] = v end
end

local function update_self(now)
  local myid = mq.TLO.Me.ID()
  if not myid or myid <= 0 then return end
  local sc = mq.TLO.Me.Casting.ID()
  if sc and sc > 0 then
    if selfSpellID ~= sc then
      selfSpellID = sc
      local ci = types.CastInfo(myid, mq.TLO.Me.CleanName() or 'me', sc,
                                mq.TLO.Spell(sc).Name(), cast_seconds(sc), true, now)
      ci.spellIcon = spell_icon(sc)
      active[myid] = ci
    end
  else
    selfSpellID = nil
    local a = active[myid]
    if a and a.isSelf and not a.done then
      a.done = true
      -- ended early -> interrupted; otherwise linger for the finish pulse.
      if now < a.startedAt + a.duration - 0.25 then
        a.interrupted, a.interruptedAt = true, now
      end
    end
  end
end

function M.update(now)
  if cfg.trackSelf then update_self(now) end

  -- Resolve pending casts (name -> spawn id) and create active entries.
  for name, p in pairs(pendingByName) do
    local sp = resolve_caster(name)
    if sp and sp.ID() and sp.ID() > 0 then
      local id = sp.ID()
      local ci = types.CastInfo(id, name, p.spellID, p.spellName,
                                cast_seconds(p.spellID), false, now)
      ci.spellIcon = spell_icon(p.spellID)
      if CAST_ANIMS[sp.Animation()] then ci.sawAnim, ci.lastAnimAt = true, now end
      active[id] = ci
      pendingByName[name] = nil
    elseif now - p.at > 3 then
      pendingByName[name] = nil
    end
  end

  -- Interrupt heuristic + expiry.
  for id, a in pairs(active) do
    if not a.isSelf and not a.interrupted and cfg.interruptDetect then
      local sp = mq.TLO.Spawn(id)
      if sp.ID() == id then
        local anim = sp.Animation()
        if CAST_ANIMS[anim] then
          a.sawAnim, a.lastAnimAt = true, now
        elseif a.sawAnim and a.lastAnimAt
           and now - a.lastAnimAt > 0.3
           and now < a.startedAt + a.duration - 0.2 then
          a.interrupted, a.interruptedAt = true, now
          dbg('cast interrupted: %s (%s)', a.casterName, tostring(a.spellName))
        end
      end
    end

    if a.interrupted then
      if now > (a.interruptedAt or now) + cfg.interruptLinger then active[id] = nil end
    elseif now > a.startedAt + a.duration + cfg.grace then
      active[id] = nil
    end
  end
end

---@return CastInfo|nil
function M.get(spawnID) return active[spawnID] end

---@return table<integer, CastInfo>
function M.all() return active end

-- Progress of a cast: fraction 0..1 (clamped) and seconds remaining (>= 0).
---@param ci CastInfo
---@param now number
---@return number pct, number remain
function M.progress(ci, now)
  local elapsed = now - ci.startedAt
  local pct = (ci.duration > 0) and (elapsed / ci.duration) or 1
  if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
  local remain = ci.duration - elapsed
  if remain < 0 then remain = 0 end
  return pct, remain
end

return M
