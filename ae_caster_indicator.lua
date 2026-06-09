--[[
  ae_caster_indicator.lua - draw the affected area / target of spells being cast,
  for YOU and for nearby mobs (and optionally friendlies).

  Projection: native eqgfx world->screen (eqgfx.project: raw pixels + a reliable
              in-front-of-camera bool per vertex).
  Drawing:    MQ ImGui foreground draw list - real translucent filled polygons,
              anti-aliased outlines, plus caster->target lines for single-target
              spells.

  HOW MOB CASTS ARE DETECTED
    - mq.event captures the "<name> begins to cast ..." line WITH the clickable
      spell link kept (keepLinks); mq.ParseSpellLink -> spell id.
    - the caster NAME is resolved to a spawn ID by scanning nearby spawns of that
      name showing a casting animation (27/43/44/134/135; reliable <= ~400u).
    - spell geometry comes from the existing native eqgfx.spell_geom(id).

  TARGET RESOLUTION (cross-box via EQBC)
    A mob's target is only readable when YOU have it targeted (Target.AggroHolder).
    Whichever box has the caster targeted resolves the victim and broadcasts
    "eqgfx_cast=<casterID>=<spellID>=<targetID>" over EQBC; every box then draws
    the line / target-centered ring, even ones that never targeted the caster.

  SETTINGS
    /aemenu        toggle the in-game settings window (colors, friend/foe,
                   per-category toggles, radius, ground offset). Auto-saved to
                   mq.configDir/eqgfx_indicator.lua via mq.pickle.
    /aering [r]    toggle a fixed debug ring of radius r around YOU.
    /aerad  r      set the debug ring radius.
    /aez    z      ground offset: how far below reported Z to draw areas.

  Run:  /lua run eqgfx/ae_caster_indicator
  Stop: /lua stop eqgfx/ae_caster_indicator
]]

local mq    = require('mq')
local eqgfx = require('eqgfx')
local ImGui = require('ImGui')
local log   = require('eqgfx.lib.lwlogger')

log.SetAppName('eqgfx')
log.SetModuleName('ae_caster')
log.SetColors(true)
log.SetIncludeTime("milliseconds")
log.SetLevel(log.INFO)
log.SetIncludeCharacter("Server.Character.Zone")
log.SetOutputFile(mq.configDir .. "/eqgfx.log")
log.SetIncludeSource("trace")

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end

local TT       = eqgfx.TargetType
local SEGMENTS = 48
local CAST_ANIMS = { [27]=true, [43]=true, [44]=true, [134]=true, [135]=true }

local CASTER_CENTERED = {
  [TT.PBAE]=true, [TT.AEPC_v1]=true, [TT.Group_v1]=true, [TT.AEPC_v2]=true,
  [TT.Group_v2]=true, [TT.CasterAreaPC]=true, [TT.CasterAreaNPC]=true,
}
local TARGET_CENTERED = {
  [TT.TargetArea]=true, [TT.AreaDetrimental]=true, [TT.TargetAEDrain]=true,
  [TT.TargetAEUndead]=true, [TT.TargetAESummoned]=true, [TT.FreeTarget]=true,
}

----------------------------------------------------------------------------
-- Settings (plain tables only, so mq.pickle round-trips cleanly). Colors are
-- {r,g,b,a} floats 0..1 - directly usable by ImGui.ColorEdit4 and
-- ImGui.ColorConvertFloat4ToU32.
----------------------------------------------------------------------------
local CFG_PATH = mq.configDir .. '/eqgfx_indicator.lua'

local DEFAULTS = {
  showEnemies   = true,
  showFriendly  = false,
  showSelf      = true,
  showAoE       = true,   -- caster-centered circles (PBAE etc.)
  showCones     = true,
  showBeams     = true,
  showTargetAoE = true,   -- target-centered circles
  showLines     = true,   -- single-target caster->target lines
  showDebugRing = false,
  genericMarker = true,   -- show a marker when the spell can't be identified
  radius        = 250,
  groundOffset  = 5.0,
  debugRadius   = 40,
  colors = {
    enemyFill  = { 1.00, 0.51, 0.51, 0.27 },
    enemyLine  = { 1.00, 0.24, 0.24, 0.86 },
    friendFill = { 0.51, 0.71, 1.00, 0.27 },
    friendLine = { 0.30, 0.60, 1.00, 0.86 },
    selfFill   = { 0.51, 1.00, 0.51, 0.27 },
    selfLine   = { 0.24, 1.00, 0.24, 0.86 },
    line       = { 1.00, 0.85, 0.20, 0.90 },  -- single-target line
    debugFill  = { 0.00, 1.00, 1.00, 0.20 },
    debugLine  = { 0.00, 1.00, 1.00, 0.86 },
  },
}

local settings

-- Fill any keys missing from a loaded config with defaults (so new fields appear
-- on upgrade). Recurses one level for the colors sub-table.
local function merge_defaults(dst, def)
  dst = (type(dst) == 'table') and dst or {}
  for k, v in pairs(def) do
    if type(v) == 'table' then
      dst[k] = merge_defaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

local function load_settings()
  local okk, data = pcall(mq.unpickle, CFG_PATH)
  settings = merge_defaults((okk and type(data) == 'table') and data or {}, DEFAULTS)
end

local saveDirty, lastSave = false, 0
local function mark_dirty() saveDirty = true end
local function save_settings()
  local okk, e = pcall(mq.pickle, CFG_PATH, settings)
  if not okk then log.Warn('save failed: %s', tostring(e)) end
end

load_settings()

----------------------------------------------------------------------------
-- Color helpers. ImGui draw list wants a packed ImU32; settings hold float4.
----------------------------------------------------------------------------
local function u32(c) return ImGui.ColorConvertFloat4ToU32({ c[1], c[2], c[3], c[4] }) end

local function cols_for(cat)
  local C = settings.colors
  if     cat == 'self'   then return u32(C.selfFill),   u32(C.selfLine)
  elseif cat == 'friend' then return u32(C.friendFill), u32(C.friendLine)
  else                        return u32(C.enemyFill),  u32(C.enemyLine) end
end

-- EQ heading (deg, 0=N) -> world atan2 angle. heading increases clockwise; +90.
local function facing_rad(h) return math.rad(90 + (h or 0)) end

----------------------------------------------------------------------------
-- ImGui drawing helpers (projection via eqgfx.project: raw px + infront bool).
----------------------------------------------------------------------------

-- Fan-fill a perimeter of WORLD points around a WORLD center, then outline it.
-- Each filled wedge (center, p_i, p_{i+1}) is drawn only when all three vertices
-- are in front of the camera, so a ring you stand inside degrades gracefully.
local function fill_and_outline(dl, cx, cy, cz, pts, closed, fillCol, lineCol)
  local csx, csy, cIn = eqgfx.project(cx, cy, cz)
  local n = #pts
  local sx, sy, infront = {}, {}, {}
  for i = 1, n do
    local p = pts[i]
    sx[i], sy[i], infront[i] = eqgfx.project(p.x, p.y, p.z)
  end

  if cIn then
    local last = closed and n or (n - 1)
    for i = 1, last do
      local j = (i % n) + 1
      if infront[i] and infront[j] then
        dl:AddTriangleFilled(ImVec2(csx, csy), ImVec2(sx[i], sy[i]),
                             ImVec2(sx[j], sy[j]), fillCol)
      end
    end
  end

  local run = {}
  local function flush()
    if #run >= 2 then dl:AddPolyline(run, lineCol, 0, 2.0) end
    run = {}
  end
  for i = 1, n do
    if infront[i] then run[#run + 1] = ImVec2(sx[i], sy[i]) else flush() end
  end
  if closed and infront[1] and infront[n] and #run >= 1 then
    run[#run + 1] = ImVec2(sx[1], sy[1])
  end
  flush()
end

-- N world points on a circle (clockwise) at ground z.
local function circle_pts(cx, cy, cz, radius, n)
  local pts = {}
  for i = 0, n - 1 do
    local a = -2 * math.pi * (i / n)
    pts[i + 1] = { x = cx + radius * math.cos(a), y = cy + radius * math.sin(a), z = cz }
  end
  return pts
end

-- Arc wedge perimeter from a0..a1 (center supplied by fill_and_outline).
local function arc_pts(cx, cy, cz, radius, a0, a1, n)
  if a1 < a0 then a0, a1 = a1, a0 end
  local pts = {}
  for i = 0, n do
    local t = i / n
    local a = a1 + (a0 - a1) * t
    pts[#pts + 1] = { x = cx + radius * math.cos(a), y = cy + radius * math.sin(a), z = cz }
  end
  return pts
end

-- Filled quad (beam) from four world corners in order.
local function fill_quad(dl, a, b, c, d, fillCol, lineCol)
  local function P(w) return eqgfx.project(w.x, w.y, w.z) end
  local ax, ay, ai = P(a); local bx, by, bi = P(b)
  local cx, cy, ci = P(c); local dx, dy, di = P(d)
  if ai and bi and ci then dl:AddTriangleFilled(ImVec2(ax,ay), ImVec2(bx,by), ImVec2(cx,cy), fillCol) end
  if ai and ci and di then dl:AddTriangleFilled(ImVec2(ax,ay), ImVec2(cx,cy), ImVec2(dx,dy), fillCol) end
  local sc = { {ax,ay,ai}, {bx,by,bi}, {cx,cy,ci}, {dx,dy,di} }
  for i = 1, 4 do
    local p, q = sc[i], sc[(i % 4) + 1]
    if p[3] and q[3] then dl:AddLine(ImVec2(p[1],p[2]), ImVec2(q[1],q[2]), lineCol, 2.0) end
  end
end

----------------------------------------------------------------------------
-- Active-cast tracking.
--   active[spawnID] = { id, spellID, geom, name, isSelf, friend,
--                       targetID, expireAt }
--   pendingByName[name] = { spellID, spellName, at }  (awaiting spawn resolution)
----------------------------------------------------------------------------
local active        = {}
local pendingByName = {}

local function classify_friend(sp)
  local t = sp.Type()
  if t == 'PC' or t == 'Pet' or t == 'Mercenary' then return true end
  if t == 'NPC' then return not sp.Aggressive() end
  return true
end

-- Resolve a caster name to its spawn, preferring one currently in a cast anim.
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
  return nil
end

local function cast_seconds(spellID)
  if not spellID then return 3 end
  local ms = mq.TLO.Spell(spellID).MyCastTime()
  if not ms or ms <= 0 then ms = mq.TLO.Spell(spellID).CastTime() end
  if type(ms) == 'number' and ms > 0 then return ms / 1000 end
  return 3
end

----------------------------------------------------------------------------
-- Cast event: stash a pending cast keyed by caster name + the spell link's id.
----------------------------------------------------------------------------
local function on_cast(line, casterName)
  if not casterName or casterName == '' then return end
  if casterName == (mq.TLO.Me.CleanName() or '') then return end  -- self handled via Me.Casting

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
  log.Info('CAST evt: "%s" -> %s (id=%s)', casterName, tostring(spellName), tostring(spellID))
end

-- "<name> begins to cast a spell." and "<name> begins to cast <spell>." both
-- match the first; the named/link form carries the spell link in the raw line.
mq.event('eqgfx_cast1', "#1# begins to cast #2#.#*#",  function(l, n) on_cast(l, n) end, { keepLinks = true })
mq.event('eqgfx_cast2', "#1# begins casting #2#.#*#",  function(l, n) on_cast(l, n) end, { keepLinks = true })

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
    -- caster may be out of our animation range; build a stub from the broadcast.
    a = { id = cid, spellID = (sid and sid > 0) and sid or nil, name = '?',
          isSelf = false, friend = false, expireAt = os.clock() + cast_seconds(sid) + 1 }
    a.geom = a.spellID and eqgfx.spell_geom(a.spellID) or nil
    active[cid] = a
  end
  if vid and vid > 0 then a.targetID = vid end
end)

----------------------------------------------------------------------------
-- Per-cast drawing.
----------------------------------------------------------------------------
local function spawn_ground(sp)
  return sp.X(), sp.Y(), sp.Z() - settings.groundOffset
end

local function draw_active(dl, a)
  local sp = mq.TLO.Spawn(a.id)
  if not (sp() and sp.X()) then return end

  local cat = a.isSelf and 'self' or (a.friend and 'friend' or 'enemy')
  if cat == 'enemy'  and not settings.showEnemies  then return end
  if cat == 'friend' and not settings.showFriendly then return end
  if cat == 'self'   and not settings.showSelf     then return end
  local fillCol, lineCol = cols_for(cat)

  local cx, cy, cz = spawn_ground(sp)
  local g = a.geom

  if not g then
    if settings.genericMarker and settings.showAoE then
      fill_and_outline(dl, cx, cy, cz, circle_pts(cx, cy, cz, 8, SEGMENTS), true, fillCol, lineCol)
    end
    return
  end

  local tt = g.targetType
  local radius = (g.aeRange and g.aeRange > 0) and g.aeRange or g.range
  if radius <= 0 then radius = 1 end

  if tt == TT.DirectionalCone then
    if not settings.showCones then return end
    local facing = facing_rad(sp.Heading.Degrees())
    if math.abs(g.coneEnd - g.coneStart) < 0.5 then
      fill_and_outline(dl, cx, cy, cz, circle_pts(cx, cy, cz, radius, SEGMENTS), true, fillCol, lineCol)
    else
      local a0, a1 = facing + math.rad(g.coneStart), facing + math.rad(g.coneEnd)
      fill_and_outline(dl, cx, cy, cz, arc_pts(cx, cy, cz, radius, a0, a1, SEGMENTS), false, fillCol, lineCol)
    end

  elseif tt == TT.Beam then
    if not settings.showBeams then return end
    local f   = facing_rad(sp.Heading.Degrees())
    local len = (g.range and g.range > 0) and g.range or radius
    local hw  = (g.aeRange and g.aeRange > 0) and g.aeRange or 5
    local fx, fy = math.cos(f), math.sin(f)
    local px, py = -fy, fx
    local function corner(d, w) return { x = cx + fx*d + px*w, y = cy + fy*d + py*w, z = cz } end
    fill_quad(dl, corner(0, hw), corner(len, hw), corner(len, -hw), corner(0, -hw), fillCol, lineCol)

  elseif CASTER_CENTERED[tt] then
    if not settings.showAoE then return end
    fill_and_outline(dl, cx, cy, cz, circle_pts(cx, cy, cz, radius, SEGMENTS), true, fillCol, lineCol)

  elseif TARGET_CENTERED[tt] then
    if not settings.showTargetAoE then return end
    local tsp = a.targetID and mq.TLO.Spawn(a.targetID) or (a.isSelf and mq.TLO.Target or nil)
    if tsp and tsp() and tsp.X() then
      local tx, ty, tz = spawn_ground(tsp)
      fill_and_outline(dl, tx, ty, tz, circle_pts(tx, ty, tz, radius, SEGMENTS), true, fillCol, lineCol)
    end

  else
    -- single target / direct: line from caster to target.
    if not settings.showLines then return end
    local tsp = a.targetID and mq.TLO.Spawn(a.targetID) or (a.isSelf and mq.TLO.Target or nil)
    if tsp and tsp() and tsp.X() then
      local tx, ty, tz = spawn_ground(tsp)
      local ax, ay, ai = eqgfx.project(cx, cy, cz)
      local bx, by, bi = eqgfx.project(tx, ty, tz)
      if ai and bi then dl:AddLine(ImVec2(ax, ay), ImVec2(bx, by), u32(settings.colors.line), 3.0) end
    end
  end
end

----------------------------------------------------------------------------
-- Settings window.
----------------------------------------------------------------------------
local menuOpen = false

local function w_check(label, key)
  local v, pressed = ImGui.Checkbox(label, settings[key])
  if pressed then settings[key] = v; mark_dirty() end
end
-- Keep colors as plain number tables (pickle-safe) regardless of what the
-- binding hands back (table vs ImVec4).
local function to_color(c)
  if type(c) == 'table' then return { c[1], c[2], c[3], c[4] } end
  return { c.x, c.y, c.z, c.w }
end
local function w_color(label, key)
  local c, changed = ImGui.ColorEdit4(label, settings.colors[key])
  if changed then settings.colors[key] = to_color(c); mark_dirty() end
end
local function w_slideri(label, key, lo, hi)
  local v, changed = ImGui.SliderInt(label, settings[key], lo, hi)
  if changed then settings[key] = v; mark_dirty() end
end
local function w_sliderf(label, key, lo, hi)
  local v, changed = ImGui.SliderFloat(label, settings[key], lo, hi, '%.1f')
  if changed then settings[key] = v; mark_dirty() end
end

local function draw_settings()
  if not menuOpen then return end
  local open, show = ImGui.Begin('EQGFX Spell Indicators', menuOpen)
  menuOpen = open
  if show then
    ImGui.Text('Mob casts detected within ~%d units (anim limit ~400).', settings.radius)
    w_slideri('Detection radius', 'radius', 20, 400)
    w_sliderf('Ground offset', 'groundOffset', 0.0, 15.0)
    ImGui.Separator()
    w_check('Show enemies',  'showEnemies')
    w_check('Show friendly', 'showFriendly')
    w_check('Show self',     'showSelf')
    ImGui.Separator()
    w_check('AoE (caster-centered)', 'showAoE')
    w_check('Cones',                 'showCones')
    w_check('Beams',                 'showBeams')
    w_check('Target-centered AoE',   'showTargetAoE')
    w_check('Single-target lines',   'showLines')
    w_check('Generic marker (unknown spell)', 'genericMarker')
    w_check('Debug ring',            'showDebugRing')
    ImGui.Separator()
    if ImGui.CollapsingHeader('Colors') then
      w_color('Enemy fill',     'enemyFill')
      w_color('Enemy outline',  'enemyLine')
      w_color('Friendly fill',  'friendFill')
      w_color('Friendly outline','friendLine')
      w_color('Self fill',      'selfFill')
      w_color('Self outline',   'selfLine')
      w_color('Single-target line', 'line')
      w_color('Debug fill',     'debugFill')
      w_color('Debug outline',  'debugLine')
    end
  end
  ImGui.End()
end

----------------------------------------------------------------------------
-- Per-frame draw callback.
----------------------------------------------------------------------------
local function draw()
  local dl = ImGui.GetForegroundDrawList()

  if settings.showDebugRing then
    local me = mq.TLO.Me
    local x, y, z = me.X(), me.Y(), me.Z()
    if x then
      fill_and_outline(dl, x, y, z, circle_pts(x, y, z, settings.debugRadius, SEGMENTS),
                       true, u32(settings.colors.debugFill), u32(settings.colors.debugLine))
    end
  end

  for _, a in pairs(active) do
    draw_active(dl, a)
  end

  draw_settings()
end

mq.imgui.init('ae_caster_indicator', draw)

----------------------------------------------------------------------------
-- Binds.
----------------------------------------------------------------------------
mq.bind('/aemenu', function() menuOpen = not menuOpen end)
mq.bind('/aering', function(r)
  if r and r ~= '' then settings.debugRadius = tonumber(r) or settings.debugRadius end
  settings.showDebugRing = not settings.showDebugRing
  mark_dirty()
  log.Info('debug ring = %s (radius %g)', tostring(settings.showDebugRing), settings.debugRadius)
end)
mq.bind('/aerad', function(r)
  settings.debugRadius = tonumber(r) or settings.debugRadius
  mark_dirty()
  log.Info('debug ring radius = %g', settings.debugRadius)
end)
mq.bind('/aez', function(z)
  settings.groundOffset = tonumber(z) or settings.groundOffset
  mark_dirty()
  log.Info('ground offset = %g', settings.groundOffset)
end)

log.Info('spell indicators running. /aemenu = settings, /aering = debug ring.')

----------------------------------------------------------------------------
-- Tracking loop: events, self-cast, resolve pendings, target announce, expire.
----------------------------------------------------------------------------
while true do
  mq.doevents()
  local now = os.clock()

  -- Self cast (always reliable for your own character).
  local myid = mq.TLO.Me.ID()
  local sc   = mq.TLO.Me.Casting.ID()
  if myid and sc and sc > 0 then
    local a = active[myid] or { id = myid }
    a.id, a.spellID, a.geom = myid, sc, eqgfx.spell_geom(sc)
    a.isSelf, a.friend, a.expireAt = true, true, nil
    active[myid] = a
  elseif myid and active[myid] and active[myid].isSelf then
    active[myid] = nil
  end

  -- Resolve pending casts (name -> spawn id) and build active entries.
  for name, p in pairs(pendingByName) do
    local sp = resolve_caster(name)
    if sp and sp.ID() and sp.ID() > 0 then
      local id = sp.ID()
      active[id] = {
        id       = id,
        spellID  = p.spellID,
        geom     = p.spellID and eqgfx.spell_geom(p.spellID) or nil,
        name     = name,
        isSelf   = false,
        friend   = classify_friend(sp),
        targetID = nil,
        expireAt = now + cast_seconds(p.spellID) + 0.5,
      }
      pendingByName[name] = nil
    elseif now - p.at > 3 then
      pendingByName[name] = nil
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

  -- Expire finished casts.
  for id, a in pairs(active) do
    if not a.isSelf and a.expireAt and now > a.expireAt then active[id] = nil end
  end

  -- Debounced settings save.
  if saveDirty and now - lastSave > 1.0 then
    save_settings(); saveDirty = false; lastSave = now
  end

  mq.delay(50)
end
