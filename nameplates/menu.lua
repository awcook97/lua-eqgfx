--[[
  nameplates/menu.lua - the in-game customization window (/npmenu).

  Every widget writes straight into settings.data and marks it dirty; the main
  loop debounce-saves to mq.configDir/eqgfx_nameplates.lua.
]]

local ImGui    = require('ImGui')
local types    = require('eqgfx.nameplates._types')
local settings = require('eqgfx.nameplates.settings')

local M = { open = false }

function M.toggle() M.open = not M.open end

local filterInput, ovInput = '', ''

local function mark() settings.mark_dirty() end

local function check(label, t, k)
  local v, pressed = ImGui.Checkbox(label, t[k])
  if pressed then t[k] = v; mark() end
end

local function slideri(label, t, k, lo, hi)
  local v, changed = ImGui.SliderInt(label, t[k], lo, hi)
  if changed then t[k] = v; mark() end
end

local function sliderf(label, t, k, lo, hi, fmt)
  local v, changed = ImGui.SliderFloat(label, t[k], lo, hi, fmt or '%.1f')
  if changed then t[k] = v; mark() end
end

-- Keep colors as plain number tables (pickle-safe) regardless of what the
-- binding hands back (table vs ImVec4).
local function to_color(c)
  if type(c) == 'table' then return { c[1], c[2], c[3], c[4] } end
  return { c.x, c.y, c.z, c.w }
end

local function color(label, t, k)
  local c, changed = ImGui.ColorEdit4(label, t[k])
  if changed then t[k] = to_color(c); mark() end
end

local function combo(label, t, k, items)
  local v, changed = ImGui.Combo(label, t[k], items, #items)
  if changed then t[k] = v; mark() end
end

local function list_editor(tag, list)
  for idx = #list, 1, -1 do
    if ImGui.SmallButton('x##' .. tag .. idx) then
      table.remove(list, idx); mark()
    else
      ImGui.SameLine()
      ImGui.Text(list[idx])
    end
  end
end

---@param caps table  render capability flags (sizedText)
function M.draw(caps)
  if not M.open then return end
  local S = settings.data
  local open, show = ImGui.Begin('EQGFX Nameplates', M.open)
  M.open = open
  if show then
    ImGui.Text('Save for:')
    ImGui.SameLine()
    if ImGui.RadioButton('This character', settings.scope == 'char') then settings.set_scope('char') end
    ImGui.SameLine()
    if ImGui.RadioButton('This server', settings.scope == 'server') then settings.set_scope('server') end
    ImGui.SameLine()
    if ImGui.RadioButton('All characters', settings.scope == 'global') then settings.set_scope('global') end
    ImGui.Separator()
    check('Enabled', S, 'enabled')
    slideri('Radius', S, 'radius', 20, 500)
    check('Hide plates behind EQ windows', S, 'hideUnderUI')
    if S.hideUnderUI then
      ImGui.TextDisabled('(missing a window? /windows for names, /npui add <Name>)')
    end
    ImGui.Separator()
    check('Show NPCs', S.show, 'npcs')
    check('Show PCs',  S.show, 'pcs')
    check('Show pets & mercs', S.show, 'pets')
    check('Show yourself', S.show, 'self')

    if ImGui.CollapsingHeader('Bar') then
      combo('Texture', S.bar, 'texture', types.BarTextureLabels)
      slideri('Width',  S.bar, 'width',  20, 300)
      slideri('Height', S.bar, 'height', 2, 40)
      sliderf('Rounding', S.bar, 'rounding', 0.0, 12.0)
      sliderf('Height above head', S.bar, 'zOffset', 0.0, 20.0)
      sliderf('Border thickness', S.bar, 'borderThickness', 0.0, 4.0)
      sliderf('Opacity', S.bar, 'opacity', 0.1, 1.0, '%.2f')
    end

    if ImGui.CollapsingHeader('Names') then
      check('Show names', S.name, 'show')
      combo('Position', S.name, 'position', types.NamePositionLabels)
      slideri('Offset X', S.name, 'offsetX', -100, 100)
      slideri('Offset Y', S.name, 'offsetY', -50, 50)
      if caps.sizedText ~= false then
        sliderf('Text size', S.name, 'size', 8.0, 32.0, '%.0f px')
      else
        ImGui.TextDisabled('(text sizing unavailable in this MQ build)')
      end
      color('Name color', S.colors, 'name')
      combo('PC anonymity', S.name, 'anonMode', types.AnonModeLabels)
      check('Background', S.name, 'background')
      if S.name.background then
        slideri('  Padding', S.name, 'bgPadding', 0, 8)
        color('  Background color', S.colors, 'nameBg')
      end
      check('Text shadow', S.name, 'shadow')
      if S.name.shadow then color('  Shadow color', S.colors, 'nameShadow') end
      combo('Name animation', S.name, 'anim', types.NameAnimLabels)
      if S.name.anim ~= types.NameAnim.NONE then
        sliderf('  Animation speed', S.name, 'animSpeed', 0.1, 4.0, '%.1f x')
        if S.name.anim >= types.NameAnim.RAINBOW_WAVE then
          sliderf('  Amplitude', S.name, 'animAmount', 0.5, 8.0, '%.1f px')
        end
      end
    end

    if ImGui.CollapsingHeader('HP bar') then
      check('HP color gradient', S.hp, 'gradient')
      if S.hp.gradient then
        color('Full HP',  S.colors, 'barHigh')
        color('Half HP',  S.colors, 'barMid')
        color('Low HP',   S.colors, 'barLow')
      else
        color('Bar color', S.colors, 'barFixed')
      end
      check('Show HP %', S.hp, 'showPct')
      if S.hp.showPct then
        combo('HP % position', S.hp, 'textPos', types.HpTextPosLabels)
        sliderf('HP % size', S.hp, 'textSize', 7.0, 24.0, '%.0f px')
        color('HP % text', S.colors, 'hpText')
      end
    end

    if ImGui.CollapsingHeader('Mana / Endurance') then
      combo('Mana bar', S.resources, 'manaScope', types.ResScopeLabels)
      combo('Endurance bar', S.resources, 'enduScope', types.ResScopeLabels)
      slideri('Bar height##res', S.resources, 'height', 2, 12)
      color('Mana color', S.colors, 'manaFill')
      color('Endurance color', S.colors, 'enduFill')
      color('Resource background', S.colors, 'resourceBack')
      ImGui.TextDisabled('(others\' mana/endurance only when the client knows it)')
    end

    if ImGui.CollapsingHeader('Cast bar') then
      check('Show cast bars', S.castbar, 'show')
      check('Only on my target', S.castbar, 'onlyTarget')
      slideri('Cast bar height', S.castbar, 'height', 2, 30)
      sliderf('Cast bar width', S.castbar, 'widthScale', 0.3, 2.0, '%.2f x')
      slideri('Gap below plate', S.castbar, 'gap', 0, 20)
      check('Spell icon', S.castbar, 'showIcon')
      if S.castbar.showIcon then slideri('  Icon size', S.castbar, 'iconSize', 10, 40) end
      check('Show spell name', S.castbar, 'showSpellName')
      check('Show time remaining', S.castbar, 'showTime')
      if S.castbar.showTime then check('  Show total time too', S.castbar, 'showTotal') end
      sliderf('Cast text size', S.castbar, 'textSize', 8.0, 24.0, '%.0f px')
      check('Detect interrupts', S.castbar, 'interruptDetect')
      color('Cast fill',       S.colors, 'castFill')
      color('Cast background', S.colors, 'castBack')
      color('Cast text',       S.colors, 'castText')
      color('Interrupt color', S.colors, 'castInterrupt')
    end

    if ImGui.CollapsingHeader('Buffs') then
      check('Show buffs', S.buffs, 'enabled')
      ImGui.TextDisabled('(cached buffs: a spawn must have been targeted once)')
      check('Only on my target##buffs', S.buffs, 'onlyTarget')
      check('Hover tooltip', S.buffs, 'tooltip')
      check('Right-click inspect', S.buffs, 'rightClickInspect')
      check('Flash new buffs', S.buffs, 'appearFlash')
      check('Pulse detrimental borders', S.buffs, 'detPulse')
      check('Combine beneficial + detrimental', S.buffs, 'combine')
      slideri('Icon size##buffs', S.buffs, 'iconSize', 8, 40)
      slideri('Icon spacing', S.buffs, 'spacing', 0, 8)
      slideri('Wrap after N icons', S.buffs, 'maxPerRow', 1, 30)
      slideri('Max icons total', S.buffs, 'maxIcons', 1, 60)
      ImGui.Text('Beneficial')
      combo('Position##ben',  S.buffs.beneficial, 'position',  types.BuffPositionLabels)
      combo('Stacking##ben',  S.buffs.beneficial, 'direction', types.BuffDirectionLabels)
      if not S.buffs.combine then
        ImGui.Text('Detrimental')
        combo('Position##det', S.buffs.detrimental, 'position',  types.BuffPositionLabels)
        combo('Stacking##det', S.buffs.detrimental, 'direction', types.BuffDirectionLabels)
      end

      ImGui.Separator()
      ImGui.Text('Filters')
      check('Only my casts', S.buffs, 'mineOnly')
      combo('Filter mode', S.buffs, 'filterMode', types.BuffFilterLabels)
      filterInput = select(1, ImGui.InputText('Spell name##filter', filterInput))
      if ImGui.Button('+ Whitelist') and filterInput ~= '' then
        table.insert(S.buffs.whitelist, filterInput); filterInput = ''; mark()
      end
      ImGui.SameLine()
      if ImGui.Button('+ Blacklist') and filterInput ~= '' then
        table.insert(S.buffs.blacklist, filterInput); filterInput = ''; mark()
      end
      if #S.buffs.whitelist > 0 and ImGui.TreeNode('Whitelist (' .. #S.buffs.whitelist .. ')') then
        list_editor('wl', S.buffs.whitelist)
        ImGui.TreePop()
      end
      if #S.buffs.blacklist > 0 and ImGui.TreeNode('Blacklist (' .. #S.buffs.blacklist .. ')') then
        list_editor('bl', S.buffs.blacklist)
        ImGui.TreePop()
      end

      ImGui.Separator()
      ImGui.Text('My casts vs others')
      check('Colored borders', S.buffs, 'borders')
      if S.buffs.borders then
        combo('Border colors', S.buffs, 'borderMode', types.BuffBorderLabels)
        if S.buffs.borderMode == types.BuffBorderMode.BY_CASTER then
          color('My border', S.buffs, 'mineBorder')
          color('Others border', S.buffs, 'otherBorder')
        end
      end
      sliderf('Dim others', S.buffs, 'dimOthers', 0.0, 0.8, '%.2f')

      ImGui.Separator()
      ImGui.Text('Per-buff overrides')
      ovInput = select(1, ImGui.InputText('Spell name##ov', ovInput))
      if ImGui.Button('+ Add override') and ovInput ~= '' then
        S.buffs.overrides[ovInput:lower()] = { scale = 1.0, priority = 0, hide = false }
        ovInput = ''
        mark()
      end
      local keys = {}
      for k in pairs(S.buffs.overrides) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local ov = S.buffs.overrides[k]
        if ImGui.TreeNode(k) then
          local v, ch = ImGui.SliderFloat('Size##' .. k, ov.scale or 1, 0.5, 3.0, '%.2f x')
          if ch then ov.scale = v; mark() end
          local pv, pch = ImGui.SliderInt('Priority##' .. k, ov.priority or 0, -10, 10)
          if pch then ov.priority = pv; mark() end
          local hv, hch = ImGui.Checkbox('Hide##' .. k, ov.hide or false)
          if hch then ov.hide = hv; mark() end
          if ImGui.Button('Remove##' .. k) then S.buffs.overrides[k] = nil; mark() end
          ImGui.TreePop()
        end
      end
    end

    if ImGui.CollapsingHeader('Target') then
      check('Distinguish my target', S.target, 'distinguish')
      if S.target.distinguish then
        sliderf('Target scale', S.target, 'scale', 1.0, 2.5, '%.2f x')
        check('Custom border', S.target, 'border')
        if S.target.border then
          color('Target border color', S.target, 'borderColor')
          sliderf('Target border thickness', S.target, 'borderThickness', 0.5, 6.0)
        end
        check('Glow on target', S.target, 'glow')
      end
    end

    if ImGui.CollapsingHeader('Animations') then
      ImGui.Text('Passive (always running)')
      check('Sheen sweep', S.anim, 'sheen')
      if S.anim.sheen then sliderf('  Sweep every', S.anim, 'sheenPeriod', 0.5, 10.0, '%.1f s') end
      check('Scroll stripes (Stripes texture)', S.anim, 'stripeScroll')
      if S.anim.stripeScroll then sliderf('  Scroll speed', S.anim, 'stripeSpeed', 5.0, 120.0, '%.0f px/s') end
      check('Low-HP heartbeat', S.anim, 'lowHpPulse')
      if S.anim.lowHpPulse then
        sliderf('  Below HP', S.anim, 'lowHpThreshold', 0.05, 0.9, '%.2f')
        sliderf('  Beat rate', S.anim, 'lowHpSpeed', 0.3, 5.0, '%.1f Hz')
        color('  Heartbeat color', S.colors, 'lowHp')
      end
      check('Breathe (alpha pulse)', S.anim, 'breathe')
      if S.anim.breathe then
        sliderf('  Breathe amount', S.anim, 'breatheAmount', 0.05, 0.6, '%.2f')
        sliderf('  Breathe rate', S.anim, 'breatheSpeed', 0.1, 2.0, '%.1f Hz')
      end
      check('Border glow', S.anim, 'borderGlow')
      if S.anim.borderGlow then
        sliderf('  Glow rate', S.anim, 'glowSpeed', 0.1, 4.0, '%.1f Hz')
        color('  Glow color', S.colors, 'glow')
      end
      check('Idle bob', S.anim, 'bob')
      if S.anim.bob then
        sliderf('  Bob amount', S.anim, 'bobAmount', 0.5, 8.0, '%.1f px')
        sliderf('  Bob rate', S.anim, 'bobSpeed', 0.1, 2.0, '%.1f Hz')
      end
      ImGui.Separator()
      ImGui.Text('Event-driven')
      check('Smooth HP changes', S.anim, 'hpSmoothing')
      if S.anim.hpSmoothing then sliderf('  HP speed', S.anim, 'hpSpeed', 1.0, 30.0) end
      check('Fade in on appear', S.anim, 'fadeIn')
      if S.anim.fadeIn then sliderf('  Fade in time', S.anim, 'fadeInDur', 0.05, 2.0, '%.2f s') end
      check('Fade out on leave', S.anim, 'fadeOut')
      if S.anim.fadeOut then sliderf('  Fade out time', S.anim, 'fadeOutDur', 0.05, 2.0, '%.2f s') end
      check('Damage flash', S.anim, 'damageFlash')
      if S.anim.damageFlash then
        sliderf('  Flash threshold', S.anim, 'flashThreshold', 0.01, 0.5, '%.2f')
        sliderf('  Flash time', S.anim, 'flashDur', 0.05, 1.0, '%.2f s')
        color('  Flash color', S.colors, 'flash')
      end
      check('Appear pop', S.anim, 'appearPop')
      if S.anim.appearPop then sliderf('  Pop time', S.anim, 'popDur', 0.05, 1.0, '%.2f s') end
      check('Cast finish pulse', S.anim, 'castPulse')
    end

    if ImGui.CollapsingHeader('Plate colors') then
      color('Background', S.colors, 'barBack')
      color('Border',     S.colors, 'border')
    end
  end
  ImGui.End()
end

return M
