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

  Buffs: read from MQ's cached buffs (Spawn.CachedBuff - populated once
  you've targeted a spawn), shown as icon rows whose side/stacking direction
  is configurable per category (beneficial / detrimental).

  Plates render inside a fullscreen pass-through ImGui window pinned to the
  back of the window stack, so they stay UNDER other ImGui windows (consoles,
  menus). EQ's own UI windows are drawn by the game before MQ's overlay and
  cannot be layered above ImGui from Lua - so plates that overlap a native
  window are CLIPPED around its rect (default) or hidden whole, using each
  plate's measured footprint from the previous frame (plate.ext).

  AE cast highlight: every in-flight area cast (mine, other players', NPCs')
  marks the plates it will affect - detrimental marks the caster's enemies
  in cfg.colors.aeDet, beneficial marks its allies in aeBen - and overlapping
  areas deepen the highlight (stack alpha curve). nameplates/ae.lua owns the
  area math; the per-plate counting lives in draw_plates.

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
local ae       = require('eqgfx.nameplates.ae')
local casts    = require('eqgfx.casts')
local uirects  = require('eqgfx.lib.uirects')

log.SetAppName('eqgfx')
log.SetModuleName('nameplates')
log.SetColors(true)
log.SetIncludeCharacter('Server.Character.Zone')
log.SetIncludeTime('milliseconds')
log.SetLevel(log.INFO)
log.SetOutputFile(mq.configDir .. '/eqgfx.log')

local ok, err = eqgfx.init()
if not ok then log.Error('init failed: %s', err) return end
if eqgfx.dll_stale then
  log.Warn('eqgfx.dll on disk is newer than the one loaded in this game session - restart EQ to load it (native UI occlusion disabled until then)')
end

settings.load()
local bootCfg = settings.data or {}
uirects.add_names(bootCfg.extraWindows)
casts.init{ log = log, trackSelf = true,
            interruptDetect = bootCfg.castbar.interruptDetect }

---@type table<integer, Plate>
local plates = {}

----------------------------------------------------------------------------
-- Native EQ UI occlusion - NATIVE ONLY. The compiled scan (named exports,
-- full window list per call) is the single source of occluder rects. There
-- is NO Lua-side window sweep: a TLO fallback was measured stalling the
-- script loop for hundreds of ms per pass, which starved mq.doevents() and
-- lagged cast detection by seconds. If the loaded eqgfx.dll can't do the
-- native scan, occlusion is OFF and we say so loudly - the loop stays fast.
----------------------------------------------------------------------------
local uiRects = {}
local showUiRects = false      -- /npui show: visualize detected occluders
local nativeWarned = false

local function scan_ui_rects(names)
  local nrects, native = uirects.get()
  if native then
    uiRects = nrects
    if names then
      for idx, rect in ipairs(nrects) do
        names[idx] = string.format('%s %d,%d %dx%d', rect.name or 'rect',
                                   rect[1], rect[2],
                                   rect[3] - rect[1], rect[4] - rect[2])
      end
      if #nrects == 0 then names[1] = '(native: no visible windows)' end
    end
    return
  end

  uiRects = {}
  if names then names[1] = '(native scan unavailable - occlusion OFF)' end
  if not nativeWarned then
    nativeWarned = true
    log.Error('native UI scan unavailable (old eqgfx.dll loaded?) - occlusion DISABLED. Restart EQ to load the current DLL.')
  end
end

-- Per-plate native-UI occlusion. The plate's bbox is its measured footprint
-- from the previous frame (plate.ext, recorded by render.plate) at the
-- current position - over-estimating is harmless (the clip regions come from
-- the window rects, not the bbox), under-estimating leaks pixels, hence PAD.
-- Returns hide(boolean)[, hits, bbox]: hits/bbox set when the plate should
-- be drawn CLIPPED around the overlapping window rects.
local PAD = 12   -- slack for glow rings, bob, buff appear-flash growth

local function occlusion(cfg, plate, hasCast)
  if not cfg.hideUnderUI or #uiRects == 0 then return false end
  local bx0, by0, bx1, by1
  local ext = plate.ext
  if ext then
    bx0, by0 = plate.sx + ext[1] - PAD, plate.sy + ext[2] - PAD
    bx1, by1 = plate.sx + ext[3] + PAD, plate.sy + ext[4] + PAD
  else
    local hw = cfg.bar.width * 0.5 + 120     -- not drawn yet: generous guess
    bx0, by0, bx1, by1 = plate.sx - hw, plate.sy - 90, plate.sx + hw, plate.sy + 110
  end
  if hasCast then   -- cast bar may appear before ext catches up (1 frame)
    by1 = by1 + cfg.castbar.gap + cfg.castbar.height + cfg.castbar.textSize + 2
  end
  local hits
  for _, rect in ipairs(uiRects) do
    if bx0 < rect[3] and bx1 > rect[1] and by0 < rect[4] and by1 > rect[2] then
      hits = hits or {}
      hits[#hits + 1] = rect
    end
  end
  if not hits then return false end
  if cfg.uiOccludeMode == types.UiOccludeMode.HIDE or not render.caps.clipRect then
    return true   -- hide the whole plate (or clipping is unavailable here)
  end
  return false, hits, { bx0, by0, bx1, by1 }
end

----------------------------------------------------------------------------
-- Per-frame draw callback: live position reads + all animation state.
----------------------------------------------------------------------------
local OVERLAY_FLAGS = bit.bor(
  ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoResize, ImGuiWindowFlags.NoMove,
  ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse,
  ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoBackground,
  ImGuiWindowFlags.NoSavedSettings, ImGuiWindowFlags.NoInputs,
  ImGuiWindowFlags.NoFocusOnAppearing, ImGuiWindowFlags.NoBringToFrontOnFocus,
  ImGuiWindowFlags.NoNav)

local drawErrLogged = false

-- No clock reads here: the game paces draw frames (~35fps) and a frame
-- counter drives all animation math. The main loop has NO gating - every
-- pass does everything. Only the cast tracker touches real time.
local FRAME_DT = 1 / 35
local animNow  = 0           -- advances once per drawn frame

local RS = types.ResScope

local function want_res(scope, plate)
  if scope == RS.OFF then return false end
  if scope == RS.SELF then return plate.isSelf end
  if scope == RS.GROUP then return plate.isSelf or plate.inGroup end
  if scope == RS.PCS then return plate.isPC end
  return true   -- ALL
end

local function update_live(plate, spawn, cfg, timeNow, dt)
  local hp = (spawn.PctHPs() or 0) / 100

  if cfg.anim.damageFlash and hp < plate.lastHp - cfg.anim.flashThreshold then
    plate.flashAt = timeNow
  end
  plate.lastHp = hp

  if cfg.anim.hpSmoothing then
    plate.dispHp = anim.approach(plate.dispHp, hp, cfg.anim.hpSpeed, dt)
  else
    plate.dispHp = hp
  end

  plate.name  = spawn.CleanName() or plate.name
  plate.alpha = cfg.anim.fadeIn
            and anim.clamp01((timeNow - plate.bornAt) / math.max(cfg.anim.fadeInDur, 0.01))
            or 1
  plate.scale = cfg.anim.appearPop
            and anim.ease_out_back((timeNow - plate.bornAt) / math.max(cfg.anim.popDur, 0.01))
            or 1

  -- mana / endurance (self: authoritative; others: spawn members where valid)
  plate.mana, plate.endu = nil, nil
  if want_res(cfg.resources.manaScope, plate) then
    local v
    if plate.isSelf then v = mq.TLO.Me.PctMana()
    else local okk, sv = pcall(function() return spawn.PctMana() end); v = okk and sv or nil end
    if type(v) == 'number' and (plate.isSelf or v > 0) then plate.mana = v / 100 end
  end
  if want_res(cfg.resources.enduScope, plate) then
    local v
    if plate.isSelf then v = mq.TLO.Me.PctEndurance()
    else local okk, sv = pcall(function() return spawn.PctEndurance() end); v = okk and sv or nil end
    if type(v) == 'number' and (plate.isSelf or v > 0) then plate.endu = v / 100 end
  end
end

-- Plates are gathered first, then drawn far -> near (painter's algorithm)
-- so closer mobs' plates overlap farther ones; your target always draws last.
local function draw_plates(drawList, cfg, timeNow, dt)
  if cfg.hideUnderUI and uirects.native then
    -- native rects every frame; an empty result only counts once native has
    -- proven itself (never clobber the TLO sweep's rects otherwise)
    local rect = uirects.get()
    if #rect > 0 or uirects.proven then uiRects = rect end
  end
  local tgtID = mq.TLO.Target.ID() or 0
  local me = mq.TLO.Me
  local mex, mey, mez = me.X() or 0, me.Y() or 0, me.Z() or 0
  local aeStates = cfg.aehl.enabled and ae.states(cfg, mex, mey, mez) or nil
  local jobs = {}

  for id, plate in pairs(plates) do
    local isTarget = (id == tgtID)
    if not plate.lostAt then
      -- LIVE read every frame -> plates track movement exactly.
      local spawn = mq.TLO.Spawn(id)
      if spawn.ID() == id and spawn.X() then
        update_live(plate, spawn, cfg, timeNow, dt)
        local x, y, z = spawn.X(), spawn.Y(), spawn.Z()
        local dx, dy, dz = x - mex, y - mey, z - mez
        plate.dist = dx * dx + dy * dy + dz * dz
        local sx, sy, vis = eqgfx.world_to_screen(x, y, z + cfg.bar.zOffset)
        if vis then
          plate.sx, plate.sy = sx, sy
          -- AE highlight: count how many in-flight areas cover this plate
          -- (det outranks ben) and map the count onto the stack alpha curve.
          -- aeKind lingers so the fade-out keeps its color after marks drop.
          local detN, benN = 0, 0
          if aeStates then
            for si = 1, #aeStates do
              local k = ae.affects(aeStates[si], plate, x, y, z)
              if k == 'det' then detN = detN + 1
              elseif k == 'ben' then benN = benN + 1 end
            end
          end
          local kind = detN > 0 and 'det' or (benN > 0 and 'ben' or nil)
          local target = 0
          if kind then
            local hl = cfg.aehl
            local n = math.min(detN > 0 and detN or benN, hl.stackMax)
            target = math.min(hl.stackBase + hl.stackStep * (n - 1), 1)
            plate.aeKind = kind
          end
          plate.aeAmt = anim.approach(plate.aeAmt or 0, target, cfg.aehl.fadeSpeed, dt)
          if not kind and plate.aeAmt < 0.01 then plate.aeKind = nil end
          local castInfo = nil
          if cfg.castbar.show and (not cfg.castbar.onlyTarget or isTarget) then
            castInfo = casts.get(id)
          end
          local hide, hits, bbox = occlusion(cfg, plate, castInfo ~= nil)
          if not hide then
            jobs[#jobs + 1] = { plate = plate, castInfo = castInfo, isTarget = isTarget,
                                hits = hits, bbox = bbox }
          end
        end
      else
        plate.lostAt, plate.lossAlpha = timeNow, plate.alpha       -- spawn despawned
      end
    else
      -- fade out at last known screen position
      local f = cfg.anim.fadeOut and anim.fade(plate.lostAt, cfg.anim.fadeOutDur, timeNow) or 0
      if f <= 0 then
        plates[id] = nil
      elseif plate.sx then
        plate.aeAmt = anim.approach(plate.aeAmt or 0, 0, cfg.aehl.fadeSpeed, dt)
        local hide, hits, bbox = occlusion(cfg, plate, false)
        if not hide then
          plate.alpha = (plate.lossAlpha or 1) * f
          jobs[#jobs + 1] = { plate = plate, castInfo = nil, isTarget = isTarget,
                              hits = hits, bbox = bbox }
        end
      end
    end
  end

  -- layering: my own plate on top of everything (target included), then
  -- the target, then everyone else by distance
  local function rank(job)
    if job.plate.isSelf then return 3 end
    if job.isTarget then return 2 end
    return 0
  end
  table.sort(jobs, function(a2, b2)
    local ra, rb = rank(a2), rank(b2)
    if ra ~= rb then return ra < rb end                -- higher rank drawn later
    return (a2.plate.dist or 0) > (b2.plate.dist or 0)         -- farthest first
  end)
  for _, job in ipairs(jobs) do
    if job.hits then
      -- punch the overlapping window rects out of the plate's bbox and draw
      -- once per leftover piece, clip-rect'd to it - the plate visually
      -- passes UNDER the native EQ UI (same trick as indicators/)
      for _, sub in ipairs(uirects.subtract(job.bbox, job.hits, 16)) do
        drawList:PushClipRect(ImVec2(sub[1], sub[2]), ImVec2(sub[3], sub[4]), false)
        render.plate(drawList, cfg, job.plate, job.castInfo, timeNow, job.isTarget)
        drawList:PopClipRect()
      end
    else
      render.plate(drawList, cfg, job.plate, job.castInfo, timeNow, job.isTarget)
    end
  end
end

local function draw()
  animNow = animNow + FRAME_DT
  local timeNow, dt = animNow, FRAME_DT
  local cfg = settings.data or {}

  if cfg.enabled then
    -- Fullscreen pass-through window at the BACK of the ImGui window stack:
    -- plates stay under every other ImGui window, and the window context is
    -- what allows DrawTextureAnimation spell icons.
    local sw, sh = eqgfx.get_screen()
    if not sw or sw <= 0 then sw, sh = 4096, 2160 end
    ImGui.SetNextWindowPos(0, 0)
    ImGui.SetNextWindowSize(sw, sh)
    local _, show = ImGui.Begin('##eqgfx_nameplates_overlay', true, OVERLAY_FLAGS)
    if show then
      local okk, drawErr = pcall(function()
        local drawList = ImGui.GetWindowDrawList()
        render.probe_caps(drawList)
        draw_plates(drawList, cfg, timeNow, dt)
        if showUiRects then
          local fg = ImGui.GetForegroundDrawList()
          for n, rect in ipairs(uiRects) do
            fg:AddRect(ImVec2(rect[1], rect[2]), ImVec2(rect[3], rect[4]), 0xffff00ff, 0, 0, 2.0)
            fg:AddText(ImVec2(rect[1] + 3, rect[2] + 3), 0xffff00ff,
                       '#' .. n .. (rect.name and (' ' .. rect.name) or ''))
          end
        end
      end)
      if not okk and not drawErrLogged then
        drawErrLogged = true
        log.Error('draw error (plates disabled this frame): %s', tostring(drawErr))
      end
    end
    ImGui.End()
  end

  menu.draw(render.caps)
end

mq.imgui.init('eqgfx_nameplates', draw)

----------------------------------------------------------------------------
-- Binds.
----------------------------------------------------------------------------
mq.bind('/npmenu', function() menu.toggle() end)
mq.bind('/npradius', function(n)
  local cfg = settings.data or {}
  cfg.radius = tonumber(n) or cfg.radius
  settings.mark_dirty()
  log.Info('radius=%d', cfg.radius)
end)
mq.bind('/nppcs', function()
  local cfg = settings.data or {}
  cfg.show.pcs = not cfg.show.pcs
  settings.mark_dirty()
  log.Info('show PCs=%s', tostring(cfg.show.pcs))
end)

mq.bind('/npdebug', function()
  local c = render.caps
  log.Info('caps: sizedText=%s multiColor=%s clipRect=%s iconDraw=%s atlasFound=%s iconVariant=%s',
           tostring(c.sizedText), tostring(c.multiColor), tostring(c.clipRect),
           tostring(c.iconDraw), tostring(c.atlasFound), tostring(c.iconVariant))
  local tid = mq.TLO.Target.ID()
  if tid and tid > 0 then
    local spawn = mq.TLO.Spawn(tid)
    local bc  = select(2, pcall(function() return spawn.BuffCount() end))
    local cbc = select(2, pcall(function() return spawn.CachedBuffCount() end))
    local plate = plates[tid]
    log.Info('target %s: BuffCount=%s CachedBuffCount=%s plate=%s scanned benefits=%d detriments=%d',
             tostring(spawn.CleanName()), tostring(bc), tostring(cbc), tostring(plate ~= nil),
             plate and plate.buffsB and #plate.buffsB or -1, plate and plate.buffsD and #plate.buffsD or -1)
  else
    log.Info('no target - target something buffed and rerun /npdebug')
  end
  log.Info('loaded eqgfx.dll build: %s', eqgfx.build and eqgfx.build() or '?')
  log.Info('flags: hideUnderUI=%s dll_stale=%s ui_native=%s findMode=%s uirects.native=%s liveRects=%d',
           tostring((settings.data or {}).hideUnderUI), tostring(eqgfx.dll_stale),
           tostring(eqgfx.ui_native), tostring(eqgfx.ui_find_mode and eqgfx.ui_find_mode() or '?'),
           tostring(uirects.native), #uiRects)
  local names = {}
  scan_ui_rects(names)
  log.Info('occlusion source: %s | %s',
           uirects.native and 'NATIVE (named exports)' or 'TLO window scan',
           #names > 0 and table.concat(names, ', ') or '(none)')
  local sn, sf, sx = eqgfx.ui_stats()
  if sn then
    log.Info('ui sweep: %d candidate names -> %d rects, %d probe faults%s', sn, sf, sx,
             sx > 0 and '  <- export/ABI mismatch, occlusion is broken!' or '')
  else
    log.Info('ui sweep stats unavailable (old eqgfx.dll loaded - restart EQ)')
  end
  local D = uirects.debug
  log.Info('ui map: raw=%d kept=%d anchor(EQMainWnd)=%s screen=%sx%s o=(%.0f,%.0f) k=(%.3f,%.3f)',
           D.raw, D.kept, tostring(D.anchored), tostring(D.sw), tostring(D.sh),
           D.ox, D.oy, D.kx, D.ky)
  if D.firstRaw then
    log.Info('ui map: first raw rect = %.0f,%.0f .. %.0f,%.0f (scan units, pre-map)',
             D.firstRaw[1], D.firstRaw[2], D.firstRaw[3], D.firstRaw[4])
  end
  log.Info('use /npui show to draw detected occluder rects on screen')
  local sts = ae.states(settings.data or {}, mq.TLO.Me.X() or 0, mq.TLO.Me.Y() or 0, mq.TLO.Me.Z() or 0)
  if #sts > 0 then
    for _, st in ipairs(sts) do
      log.Info('AE area in flight: %s %s marks %s plates%s', st.kind, tostring(st.shape),
               st.marks, st.groupOnly and ' (my group only)' or '')
    end
  else
    log.Info('AE highlight: idle (no area casts in flight)')
  end
end)

mq.bind('/npui', function(...)
  local args = { ... }
  if args[1] == 'show' then
    showUiRects = not showUiRects
    log.Info('occluder rect overlay = %s (%d rects)', tostring(showUiRects), #uiRects)
    return
  end
  if args[1] == 'add' and args[2] then
    local name = table.concat(args, ' ', 2)
    table.insert((settings.data or {}).extraWindows, name)
    uirects.add_names({ name })   -- pushed into the native scan's name list
    settings.mark_dirty()
    log.Info('occlusion window added: "%s"', name)
  else
    local names = {}
    scan_ui_rects(names)
    log.Info('open EQ windows detected: %s', #names > 0 and table.concat(names, ', ') or '(none)')
    log.Info('missing one? find its name with /windows, then:  /npui add <Name>')
  end
end)

log.Info('nameplates running. /npmenu, /npradius N, /nppcs, /npdebug, /npui')

----------------------------------------------------------------------------
-- Main loop: cast tracking + slow plate discovery + debounced settings save.
----------------------------------------------------------------------------

-- Buff scan. Self uses Me.Buff directly (always available); other spawns
-- use MQ's cached buffs - Spawn.Buff(index) with a CachedBuff('*i') fallback.
-- Cached data only exists for spawns you've targeted at least once. Member
-- names differ between buff/cachedbuff types, so every getter is chained
-- (SpellID -> Spell.ID etc.) and pcall-guarded.
local buffScanWarned = false

local function getn(f)
  local okk, v = pcall(f)
  if okk and type(v) == 'number' then return v end
end

local function getbool(f)
  local okk, v = pcall(f)
  if okk then return v and true or false end
  return nil
end

local function getstr(f)
  local okk, v = pcall(f)
  if okk and type(v) == 'string' and v ~= '' then return v end
end

local function list_has(list, key)
  for _, v in ipairs(list or {}) do
    if tostring(v):lower() == key then return true end
  end
  return false
end

-- Scan-time filtering + override resolution. Returns false to drop the buff.
local function apply_buff_rules(buffCfg, entry)
  local key = (entry.name or ''):lower()
  local ov = buffCfg.overrides[key]
  if ov and ov.hide then return false end
  if buffCfg.mineOnly and not entry.mine then return false end
  if buffCfg.filterMode == types.BuffFilterMode.WHITELIST and not list_has(buffCfg.whitelist, key) then
    return false
  end
  if buffCfg.filterMode == types.BuffFilterMode.BLACKLIST and list_has(buffCfg.blacklist, key) then
    return false
  end
  entry.scale = (ov and ov.scale) or 1
  entry.prio  = (ov and ov.priority) or 0
  return true
end

-- Higher priority first (they also survive the maxIcons cap), stable order.
local function sort_buffs(lst)
  for n, entry in ipairs(lst) do entry._i = n end
  table.sort(lst, function(x, y)
    if x.prio ~= y.prio then return x.prio > y.prio end
    return x._i < y._i
  end)
end

local function refresh_buffs(plate, spawn, isSelf)
  local buffCfg = (settings.data or {}).buffs
  local myName = mq.TLO.Me.CleanName() or ''
  local seen = {}   -- id -> addedAt from the previous scan (appear flash)
  for _, lst in ipairs({ plate.buffsB, plate.buffsD }) do
    for _, entry in ipairs(lst or {}) do seen[entry.id] = entry.addedAt end
  end
  local benefits, detriments = {}, {}
  local function add(buff)
    if not buff then return false end
    local id = getn(function() return buff.SpellID() end)
            or getn(function() return buff.Spell.ID() end)
    if not id or id <= 0 then return false end
    local icon = getn(function() return buff.SpellIcon() end)
              or getn(function() return buff.Spell.SpellIcon() end) or 0
    local ben = getbool(function() return buff.Beneficial() end)
    if ben == nil then ben = getbool(function() return buff.Spell.Beneficial() end) end
    local name = getstr(function() return buff.Name() end)
              or getstr(function() return buff.Spell.Name() end) or ''
    local caster = getstr(function() return buff.Caster() end)
                or getstr(function() return buff.CasterName() end)
    local dur = getn(function() return buff.Duration() end)
             or getn(function() return buff.Duration.TotalSeconds() end)
    if dur and dur > 30000 then dur = math.floor(dur / 1000) end  -- ms -> s
    local entry = { id = id, icon = icon, ben = ben and true or false,
                name = name, mine = (caster == myName),
                caster = caster, dur = dur, addedAt = seen[id] or animNow }
    if apply_buff_rules(buffCfg, entry) then
      if entry.ben then benefits[#benefits + 1] = entry else detriments[#detriments + 1] = entry end
    end
    return true   -- counts as a slot hit even when filtered out
  end

  if isSelf then
    pcall(function()
      local me = mq.TLO.Me
      local total = me.CountBuffs() or 0
      local found, slot = 0, 1
      while found < total and slot <= 97 do
        if add(me.Buff(slot)) then found = found + 1 end
        slot = slot + 1
      end
    end)
  else
    local ok1 = pcall(function()
      local count = spawn.BuffCount() or 0
      for idx = 1, math.min(count, 40) do add(spawn.Buff(idx)) end
    end)
    if #benefits + #detriments == 0 then
      local ok2 = pcall(function()
        local n = spawn.CachedBuffCount() or -1
        for idx = 1, math.min(n, 40) do add(spawn.CachedBuff('*' .. idx)) end
      end)
      if not ok1 and not ok2 and not buffScanWarned then
        buffScanWarned = true
        log.Warn('buff scan failed: neither Spawn.Buff nor Spawn.CachedBuff works here')
      end
    end
  end
  sort_buffs(benefits)
  sort_buffs(detriments)
  plate.buffsB, plate.buffsD = benefits, detriments
end


-- Only real creatures get plates. The plain radius spawn search also returns
-- auras, campfires, banners, totems, corpses, traps... - all filtered here.
-- Also returns the spawn category (the AE highlight's eligibility key).
local function allowed(cfg, spawn, id, myID)
  if id == myID then return cfg.show.self, 'pc' end
  local t = spawn.Type()
  if t == 'NPC' then return cfg.show.npcs, 'npc' end
  if t == 'PC'  then return cfg.show.pcs, 'pc' end
  if t == 'Pet'       then return cfg.show.pets, 'pet' end
  if t == 'Mercenary' then return cfg.show.pets, 'merc' end
  return false, 'other'
end

local function discover()
  local cfg = settings.data or {}
  local myID = mq.TLO.Me.ID()
  local spec = 'radius ' .. cfg.radius
  local present = {}

  local groupIDs = {}
  pcall(function()
    local n = mq.TLO.Group.Members() or 0
    for gi = 1, n do
      local gid = mq.TLO.Group.Member(gi).ID()
      if gid and gid > 0 then groupIDs[gid] = true end
    end
  end)

  local cnt = mq.TLO.SpawnCount(spec)() or 0
  for i = 1, cnt do
    local spawn = mq.TLO.NearestSpawn(string.format('%d, %s', i, spec))
    if spawn() and spawn.X() then
      local id = spawn.ID()
      local allow, kind = allowed(cfg, spawn, id, myID)
      if allow then
        present[id] = true
        local plate = plates[id]
        if plate then
          if plate.lostAt then plate.lostAt, plate.lossAlpha, plate.bornAt = nil, nil, animNow - 1 end
        else
          plate = types.Plate.new(id, spawn.CleanName() or '?',
                              (spawn.PctHPs() or 0) / 100, animNow)
          plates[id] = plate
        end
        plate.kind    = kind
        plate.isSelf  = (id == myID)
        plate.inGroup = groupIDs[id] or false
        if plate.isPC == nil then
          plate.isPC = (spawn.Type() == 'PC')
          if plate.isPC then
            plate.cls      = getstr(function() return spawn.Class.Name() end)
                      or getstr(function() return spawn.Class() end)
            plate.clsShort = getstr(function() return spawn.Class.ShortName() end)
          end
        end
        if cfg.buffs.enabled then
          refresh_buffs(plate, spawn, id == myID)
        end
      end
    end
  end
  for id, plate in pairs(plates) do
    if not present[id] and not plate.lostAt then
      plate.lostAt, plate.lossAlpha = animNow, plate.alpha           -- left range -> fade
    end
  end
end

while true do
  mq.doevents()
  local cfg = settings.data or {}

  casts.config{ interruptDetect = cfg.castbar.interruptDetect }
  casts.update()

  if cfg.hideUnderUI then scan_ui_rects() end

  if cfg.enabled then
    discover()
  elseif next(plates) then
    plates = {}
  end

  settings.maybe_save(log)
  mq.delay(50)
end
