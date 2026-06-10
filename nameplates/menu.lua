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
      if caps.sizedText ~= false then
        sliderf('Text size', S.name, 'size', 8.0, 32.0, '%.0f px')
      else
        ImGui.TextDisabled('(text sizing unavailable in this MQ build)')
      end
      color('Name color', S.colors, 'name')
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
      color('HP % text', S.colors, 'hpText')
    end

    if ImGui.CollapsingHeader('Cast bar') then
      check('Show cast bars', S.castbar, 'show')
      slideri('Cast bar height', S.castbar, 'height', 2, 30)
      slideri('Gap below plate', S.castbar, 'gap', 0, 20)
      check('Show spell name', S.castbar, 'showSpellName')
      check('Show time remaining', S.castbar, 'showTime')
      check('Detect interrupts', S.castbar, 'interruptDetect')
      color('Cast fill',       S.colors, 'castFill')
      color('Cast background', S.colors, 'castBack')
      color('Cast text',       S.colors, 'castText')
      color('Interrupt color', S.colors, 'castInterrupt')
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
