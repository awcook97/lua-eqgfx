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
  cannot be layered above ImGui from Lua.

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
-- Native EQ UI occlusion. ImGui always composites ABOVE the game's own
-- windows, so the next best thing is hiding plates that would overlap an
-- open EQ window (rects via the Window TLO, rescanned every 0.3s).
----------------------------------------------------------------------------
local EQ_WINDOWS = {
  'OptionsWindow', 'InventoryWindow', 'BankWnd', 'BigBankWnd', 'GuildBankWnd',
  'MerchantWnd', 'TradeWnd', 'GiveWnd', 'LootWnd', 'SpellBookWnd',
  'ItemDisplayWindow', 'BuffWindow', 'ShortDurationBuffWindow', 'TargetWindow',
  'PlayerWindow', 'GroupWindow', 'PetInfoWindow', 'CastingWindow',
  'ActionsWindow', 'HotButtonWnd', 'HotButtonWnd2', 'HotButtonWnd3',
  'HotButtonWnd4', 'SelectorWnd', 'ChatWindow', 'RaidWindow', 'MapViewWnd',
  'SkillsWindow', 'AAWindow', 'FellowshipWnd', 'TaskWnd', 'TradeskillWnd',
  'BazaarWnd', 'BazaarSearchWnd', 'InspectWnd', 'HelpWnd', 'FriendsWnd',
  'GuildManagementWnd', 'QuantityWnd', 'LargeDialogWindow',
  'ConfirmationDialogBox', 'BookWindow', 'QuestJournalNPCWnd', 'RespawnWnd',
  'CompassWindow', 'Main Chat', 'MQ2 Chat Window', 'MQChatWnd',
  'ExtendedTargetWnd',
}

local uiRects, lastUiScan = {}, 0

local function probe_window(out, name, names)
  pcall(function()
    local w = mq.TLO.Window(name)
    if w.Open() then
      local x, y = w.X() or 0, w.Y() or 0
      local ww, wh = w.Width() or 0, w.Height() or 0
      if ww > 0 and wh > 0 then
        out[#out + 1] = { x, y, x + ww, y + wh }
        if names then names[#names + 1] = name end
      end
    end
  end)
end

local function scan_ui_rects(now, names)
  lastUiScan = now
  local out = {}
  for _, name in ipairs(EQ_WINDOWS) do probe_window(out, name, names) end
  for _, name in ipairs(settings.data.extraWindows or {}) do probe_window(out, name, names) end
  uiRects = out
end

local function under_ui(S, sx, sy)
  if not S.hideUnderUI then return false end
  local hw = S.bar.width * 0.5 + 10
  local x0, y0 = sx - hw, sy - 26
  local x1, y1 = sx + hw, sy + S.castbar.height + 28
  for _, r in ipairs(uiRects) do
    if x0 < r[3] and x1 > r[1] and y0 < r[4] and y1 > r[2] then return true end
  end
  return false
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

local lastFrame = os.clock()
local drawErrLogged = false

local RS = types.ResScope

local function want_res(scope, p)
  if scope == RS.OFF then return false end
  if scope == RS.SELF then return p.isSelf end
  if scope == RS.GROUP then return p.isSelf or p.inGroup end
  if scope == RS.PCS then return p.isPC end
  return true   -- ALL
end

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

  -- mana / endurance (self: authoritative; others: spawn members where valid)
  p.mana, p.endu = nil, nil
  if want_res(S.resources.manaScope, p) then
    local v
    if p.isSelf then v = mq.TLO.Me.PctMana()
    else local okk, sv = pcall(function() return sp.PctMana() end); v = okk and sv or nil end
    if type(v) == 'number' and (p.isSelf or v > 0) then p.mana = v / 100 end
  end
  if want_res(S.resources.enduScope, p) then
    local v
    if p.isSelf then v = mq.TLO.Me.PctEndurance()
    else local okk, sv = pcall(function() return sp.PctEndurance() end); v = okk and sv or nil end
    if type(v) == 'number' and (p.isSelf or v > 0) then p.endu = v / 100 end
  end
end

local function draw_plates(dl, S, now, dt)
  local tgtID = mq.TLO.Target.ID() or 0
  for id, p in pairs(plates) do
    local isTarget = (id == tgtID)
    if not p.lostAt then
      -- LIVE read every frame -> plates track movement exactly.
      local sp = mq.TLO.Spawn(id)
      if sp.ID() == id and sp.X() then
        update_live(p, sp, S, now, dt)
        local sx, sy, vis = eqgfx.world_to_screen(sp.X(), sp.Y(), sp.Z() + S.bar.zOffset)
        if vis then
          p.sx, p.sy = sx, sy
          if not under_ui(S, sx, sy) then
            local ci = nil
            if S.castbar.show and (not S.castbar.onlyTarget or isTarget) then
              ci = casts.get(id)
            end
            render.plate(dl, S, p, ci, now, isTarget)
          end
        end
      else
        p.lostAt, p.lossAlpha = now, p.alpha       -- spawn despawned
      end
    else
      -- fade out at last known screen position
      local f = S.anim.fadeOut and anim.fade(p.lostAt, S.anim.fadeOutDur, now) or 0
      if f <= 0 then
        plates[id] = nil
      elseif p.sx and not under_ui(S, p.sx, p.sy) then
        p.alpha = (p.lossAlpha or 1) * f
        render.plate(dl, S, p, nil, now, isTarget)
      end
    end
  end
end

local function draw()
  local now = os.clock()
  local dt  = now - lastFrame; lastFrame = now
  local S   = settings.data

  if S.enabled then
    -- Fullscreen pass-through window at the BACK of the ImGui window stack:
    -- plates stay under every other ImGui window, and the window context is
    -- what allows DrawTextureAnimation spell icons.
    local sw, sh = eqgfx.get_screen()
    if not sw or sw <= 0 then sw, sh = 4096, 2160 end
    ImGui.SetNextWindowPos(0, 0)
    ImGui.SetNextWindowSize(sw, sh)
    local _, show = ImGui.Begin('##eqgfx_nameplates_overlay', true, OVERLAY_FLAGS)
    if show then
      local okk, err = pcall(function()
        local dl = ImGui.GetWindowDrawList()
        render.probe_caps(dl)
        draw_plates(dl, S, now, dt)
      end)
      if not okk and not drawErrLogged then
        drawErrLogged = true
        log.Error('draw error (plates disabled this frame): %s', tostring(err))
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
  settings.data.radius = tonumber(n) or settings.data.radius
  settings.mark_dirty()
  log.Info('radius=%d', settings.data.radius)
end)
mq.bind('/nppcs', function()
  settings.data.show.pcs = not settings.data.show.pcs
  settings.mark_dirty()
  log.Info('show PCs=%s', tostring(settings.data.show.pcs))
end)

mq.bind('/npdebug', function()
  local c = render.caps
  log.Info('caps: sizedText=%s multiColor=%s clipRect=%s iconDraw=%s atlasFound=%s iconVariant=%s',
           tostring(c.sizedText), tostring(c.multiColor), tostring(c.clipRect),
           tostring(c.iconDraw), tostring(c.atlasFound), tostring(c.iconVariant))
  local tid = mq.TLO.Target.ID()
  if tid and tid > 0 then
    local sp = mq.TLO.Spawn(tid)
    local bc  = select(2, pcall(function() return sp.BuffCount() end))
    local cbc = select(2, pcall(function() return sp.CachedBuffCount() end))
    local p = plates[tid]
    log.Info('target %s: BuffCount=%s CachedBuffCount=%s plate=%s scanned B=%d D=%d',
             tostring(sp.CleanName()), tostring(bc), tostring(cbc), tostring(p ~= nil),
             p and p.buffsB and #p.buffsB or -1, p and p.buffsD and #p.buffsD or -1)
  else
    log.Info('no target - target something buffed and rerun /npdebug')
  end
  local names = {}
  scan_ui_rects(os.clock(), names)
  log.Info('open EQ windows detected for occlusion: %s',
           #names > 0 and table.concat(names, ', ') or '(none)')
end)

mq.bind('/npui', function(...)
  local args = { ... }
  if args[1] == 'add' and args[2] then
    local name = table.concat(args, ' ', 2)
    table.insert(settings.data.extraWindows, name)
    settings.mark_dirty()
    log.Info('occlusion window added: "%s"', name)
  else
    local names = {}
    scan_ui_rects(os.clock(), names)
    log.Info('open EQ windows detected: %s', #names > 0 and table.concat(names, ', ') or '(none)')
    log.Info('missing one? find its name with /windows, then:  /npui add <Name>')
  end
end)

log.Info('nameplates running. /npmenu, /npradius N, /nppcs, /npdebug, /npui')

----------------------------------------------------------------------------
-- Main loop: cast tracking + slow plate discovery + debounced settings save.
----------------------------------------------------------------------------
local lastDiscover = 0

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
local function apply_buff_rules(BB, e)
  local key = (e.name or ''):lower()
  local ov = BB.overrides[key]
  if ov and ov.hide then return false end
  if BB.mineOnly and not e.mine then return false end
  if BB.filterMode == types.BuffFilterMode.WHITELIST and not list_has(BB.whitelist, key) then
    return false
  end
  if BB.filterMode == types.BuffFilterMode.BLACKLIST and list_has(BB.blacklist, key) then
    return false
  end
  e.scale = (ov and ov.scale) or 1
  e.prio  = (ov and ov.priority) or 0
  return true
end

-- Higher priority first (they also survive the maxIcons cap), stable order.
local function sort_buffs(lst)
  for n, e in ipairs(lst) do e._i = n end
  table.sort(lst, function(x, y)
    if x.prio ~= y.prio then return x.prio > y.prio end
    return x._i < y._i
  end)
end

local function refresh_buffs(p, sp, now, isSelf)
  p.buffsAt = now
  local BB = settings.data.buffs
  local myName = mq.TLO.Me.CleanName() or ''
  local seen = {}   -- id -> addedAt from the previous scan (appear flash)
  for _, lst in ipairs({ p.buffsB, p.buffsD }) do
    for _, e in ipairs(lst or {}) do seen[e.id] = e.addedAt end
  end
  local B, D = {}, {}
  local function add(b)
    if not b then return false end
    local id = getn(function() return b.SpellID() end)
            or getn(function() return b.Spell.ID() end)
    if not id or id <= 0 then return false end
    local icon = getn(function() return b.SpellIcon() end)
              or getn(function() return b.Spell.SpellIcon() end) or 0
    local ben = getbool(function() return b.Beneficial() end)
    if ben == nil then ben = getbool(function() return b.Spell.Beneficial() end) end
    local name = getstr(function() return b.Name() end)
              or getstr(function() return b.Spell.Name() end) or ''
    local caster = getstr(function() return b.Caster() end)
                or getstr(function() return b.CasterName() end)
    local dur = getn(function() return b.Duration() end)
             or getn(function() return b.Duration.TotalSeconds() end)
    if dur and dur > 30000 then dur = math.floor(dur / 1000) end  -- ms -> s
    local e = { id = id, icon = icon, ben = ben and true or false,
                name = name, mine = (caster == myName),
                caster = caster, dur = dur, addedAt = seen[id] or now }
    if apply_buff_rules(BB, e) then
      if e.ben then B[#B + 1] = e else D[#D + 1] = e end
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
      local count = sp.BuffCount() or 0
      for idx = 1, math.min(count, 40) do add(sp.Buff(idx)) end
    end)
    if #B + #D == 0 then
      local ok2 = pcall(function()
        local n = sp.CachedBuffCount() or -1
        for idx = 1, math.min(n, 40) do add(sp.CachedBuff('*' .. idx)) end
      end)
      if not ok1 and not ok2 and not buffScanWarned then
        buffScanWarned = true
        log.Warn('buff scan failed: neither Spawn.Buff nor Spawn.CachedBuff works here')
      end
    end
  end
  p.buffsB, p.buffsD = B, D
end


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
    local sp = mq.TLO.NearestSpawn(string.format('%d, %s', i, spec))
    if sp() and sp.X() then
      local id = sp.ID()
      if allowed(S, sp, id, myID) then
        present[id] = true
        local p = plates[id]
        if p then
          if p.lostAt then p.lostAt, p.lossAlpha, p.bornAt = nil, nil, now - 1 end
        else
          p = types.Plate.new(id, sp.CleanName() or '?',
                              (sp.PctHPs() or 0) / 100, now)
          plates[id] = p
        end
        p.isSelf  = (id == myID)
        p.inGroup = groupIDs[id] or false
        if p.isPC == nil then
          p.isPC = (sp.Type() == 'PC')
          if p.isPC then
            p.cls      = getstr(function() return sp.Class.Name() end)
                      or getstr(function() return sp.Class() end)
            p.clsShort = getstr(function() return sp.Class.ShortName() end)
          end
        end
        if S.buffs.enabled and now - (p.buffsAt or 0) > 0.5 then
          refresh_buffs(p, sp, now, id == myID)
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

  if S.hideUnderUI and now - lastUiScan > 0.3 then scan_ui_rects(now) end

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
