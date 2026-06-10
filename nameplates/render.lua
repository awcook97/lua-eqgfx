--[[
  nameplates/render.lua - draws one nameplate: HP bar + name + cast bar.

  Everything is sized/colored from settings and multiplied by the plate's
  animation state. Two kinds of animation:
    event-driven : fade in/out, appear pop, damage flash, cast pulses
    passive      : sheen sweep, scrolling stripes, low-HP heartbeat, breathe,
                   border glow, idle bob - always running, desynced per plate

  Bar fills (HP + cast) go through fill_styled(), a procedural texture engine:
  Flat / Gradient / Glass / Stripes / Segmented.

  The MQ ImGui binding isn't documented, so probe_caps() pcall-checks the
  fancier draw-list calls once on the first frame:
    sizedText  - dl:AddText(font, size, ...)        else default-size text
    multiColor - dl:AddRectFilledMultiColor(...)    else flat shading
    clipRect   - dl:PushClipRect/PopClipRect        else axis-aligned fallbacks
]]

local ImGui = require('ImGui')
local anim  = require('eqgfx.nameplates.anim')
local types = require('eqgfx.nameplates._types')
local casts = require('eqgfx.casts')

local NP = types.NamePosition
local BT = types.BarTexture

local R = {}

R.caps = { sizedText = nil, multiColor = nil, clipRect = nil }

function R.probe_caps(dl)
  if R.caps.sizedText ~= nil then return end
  R.caps.sizedText = pcall(function()
    dl:AddText(ImGui.GetFont(), 13, ImVec2(-4096, -4096), 0x01FFFFFF, 'x')
  end) and true or false
  R.caps.multiColor = pcall(function()
    dl:AddRectFilledMultiColor(ImVec2(-4096, -4096), ImVec2(-4095, -4095),
                               0x01000000, 0x01000000, 0x01000000, 0x01000000)
  end) and true or false
  R.caps.clipRect = pcall(function()
    dl:PushClipRect(ImVec2(0, 0), ImVec2(1, 1), true)
    dl:PopClipRect()
  end) and true or false
end

local function u32(c, alphaMult)
  return ImGui.ColorConvertFloat4ToU32({ c[1], c[2], c[3], c[4] * (alphaMult or 1) })
end

-- f > 1 lightens toward white, f < 1 darkens toward black.
local function shade(c, f)
  if f >= 1 then
    local t = f - 1
    return { c[1] + (1 - c[1]) * t, c[2] + (1 - c[2]) * t, c[3] + (1 - c[3]) * t, c[4] }
  end
  return { c[1] * f, c[2] * f, c[3] * f, c[4] }
end

local function text(dl, x, y, c, alphaMult, str, size)
  if R.caps.sizedText and size then
    dl:AddText(ImGui.GetFont(), size, ImVec2(x, y), u32(c, alphaMult), str)
  else
    dl:AddText(ImVec2(x, y), u32(c, alphaMult), str)
  end
end

local function text_width(str, size)
  local w = ImGui.CalcTextSize(str)
  if R.caps.sizedText and size then
    local base = ImGui.GetFontSize()
    if base and base > 0 then w = w * (size / base) end
  end
  return w
end

local function text_height(size)
  if R.caps.sizedText and size then return size end
  return ImGui.GetFontSize() or 13
end

local function hp_color(S, p)
  if not S.hp.gradient then return S.colors.barFixed end
  local C = S.colors
  if p <= 0.5 then return anim.lerp_color(C.barLow, C.barMid, p * 2) end
  return anim.lerp_color(C.barMid, C.barHigh, (p - 0.5) * 2)
end

----------------------------------------------------------------------------
-- Procedural bar textures.
----------------------------------------------------------------------------

-- Diagonal (or vertical, without clipRect) stripe overlay across a region.
local function stripes_overlay(dl, S, x0, y0, x1, y1, a, now)
  local sw, gap = 6, 6
  local period = sw + gap
  local h = y1 - y0
  local speed = S.anim.stripeScroll and S.anim.stripeSpeed or 0
  local off = (now * speed) % period
  local col = u32({ 1, 1, 1, 0.13 }, a)
  if R.caps.clipRect then
    dl:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    local x = x0 - h - period + off
    while x < x1 do
      dl:AddQuadFilled(ImVec2(x, y1), ImVec2(x + h, y0),
                       ImVec2(x + h + sw, y0), ImVec2(x + sw, y1), col)
      x = x + period
    end
    dl:PopClipRect()
  else
    local x = x0 - period + off
    while x < x1 do
      local bx0, bx1 = math.max(x, x0), math.min(x + sw, x1)
      if bx1 > bx0 then dl:AddRectFilled(ImVec2(bx0, y0), ImVec2(bx1, y1), col) end
      x = x + period
    end
  end
end

-- Styled fill for the lit part of a bar (HP fill / cast progress).
local function fill_styled(dl, S, x0, y0, x1, y1, c, a, now)
  if x1 - x0 < 0.5 then return end
  local style = S.bar.texture
  local rnd = S.bar.rounding

  dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(c, a), rnd)

  if (style == BT.GRADIENT or style == BT.GLASS) and R.caps.multiColor then
    -- inset slightly so the square gradient doesn't poke out of round corners
    local ix0, ix1 = x0 + rnd * 0.5, x1 - rnd * 0.5
    if ix1 > ix0 then
      if style == BT.GRADIENT then
        local top = u32(shade(c, 1.35), a)
        local bot = u32(shade(c, 0.60), a)
        dl:AddRectFilledMultiColor(ImVec2(ix0, y0), ImVec2(ix1, y1), top, top, bot, bot)
      else -- GLASS: bright top highlight fading out by mid-bar
        local hi  = u32({ 1, 1, 1, 0.38 }, a)
        local lo  = u32({ 1, 1, 1, 0.02 }, a)
        local mid = y0 + (y1 - y0) * 0.45
        dl:AddRectFilledMultiColor(ImVec2(ix0, y0), ImVec2(ix1, mid), hi, hi, lo, lo)
        dl:AddRectFilledMultiColor(ImVec2(ix0, mid), ImVec2(ix1, y1),
                                   u32({ 0, 0, 0, 0.00 }, a), u32({ 0, 0, 0, 0.00 }, a),
                                   u32({ 0, 0, 0, 0.22 }, a), u32({ 0, 0, 0, 0.22 }, a))
      end
    end
  elseif style == BT.GLASS then       -- no multiColor: flat highlight band
    local mid = y0 + (y1 - y0) * 0.45
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, mid), u32({ 1, 1, 1, 0.18 }, a), rnd)
  elseif style == BT.STRIPES then
    stripes_overlay(dl, S, x0, y0, x1, y1, a, now)
  end
end

-- Segment tick marks across the FULL bar width (10% steps).
local function segment_ticks(dl, S, x0, y0, x1, y1, a)
  if S.bar.texture ~= BT.SEGMENTS then return end
  local w = x1 - x0
  local col = u32({ 0, 0, 0, 0.45 }, a)
  for i = 1, 9 do
    local x = x0 + w * i / 10
    dl:AddLine(ImVec2(x, y0 + 1), ImVec2(x, y1 - 1), col, 1.0)
  end
end

-- Periodic light band sweeping left -> right across the bar.
local function sheen_sweep(dl, S, x0, y0, x1, y1, a, now, phase)
  local period = math.max(S.anim.sheenPeriod, 0.5)
  local t = ((now + phase) % period) / period
  if t > 0.35 then return end                -- sweep lasts 35% of the cycle
  local k = t / 0.35
  local w, h = x1 - x0, y1 - y0
  local bandW = math.max(8, w * 0.18)
  local bx = x0 - bandW - h + (w + 2 * (bandW + h)) * k
  local col = u32({ 1, 1, 1, 0.28 }, a)
  if R.caps.clipRect then
    dl:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    dl:AddQuadFilled(ImVec2(bx, y1), ImVec2(bx + h, y0),
                     ImVec2(bx + h + bandW, y0), ImVec2(bx + bandW, y1), col)
    dl:PopClipRect()
  else
    local cx0, cx1 = math.max(bx, x0), math.min(bx + bandW, x1)
    if cx1 > cx0 then dl:AddRectFilled(ImVec2(cx0, y0), ImVec2(cx1, y1), col) end
  end
end

local function hz_pulse(now, hz, phase)     -- 0..1 sine at hz cycles/second
  return 0.5 + 0.5 * math.sin((now + (phase or 0)) * hz * 2 * math.pi)
end

----------------------------------------------------------------------------
-- Cast bar under the plate stack.
----------------------------------------------------------------------------
---@param ci CastInfo
local function cast_bar(dl, S, ci, cx, topY, w, a, now, phase)
  local CB, C = S.castbar, S.colors
  local h  = CB.height
  local x0, x1 = cx - w * 0.5, cx + w * 0.5
  local y0, y1 = topY, topY + h
  local pct, remain = casts.progress(ci, now)

  if ci.interrupted then
    local f = anim.fade(ci.interruptedAt, 0.8, now)
    if f <= 0 then return end
    a = a * f
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.castBack, a), S.bar.rounding)
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.castInterrupt, a * 0.8), S.bar.rounding)
    if CB.showSpellName then
      text(dl, x0 + 1, y1 + 1, C.castInterrupt, a, 'Interrupted', S.name.size * 0.85)
    end
    return
  end

  dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.castBack, a), S.bar.rounding)
  fill_styled(dl, S, x0, y0, x0 + w * pct, y1, C.castFill, a, now)
  dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.border, a), S.bar.rounding)
  if S.anim.sheen then sheen_sweep(dl, S, x0, y0, x1, y1, a, now, phase + 0.7) end

  -- finish pulse: expanding, fading outline once the bar fills.
  if pct >= 1 and S.anim.castPulse then
    local f = anim.fade(ci.startedAt + ci.duration, 0.6, now)
    if f > 0 then
      local grow = (1 - f) * 6
      dl:AddRect(ImVec2(x0 - grow, y0 - grow), ImVec2(x1 + grow, y1 + grow),
                 u32(C.castFill, a * f), S.bar.rounding + grow)
    end
  end

  local ty = y1 + 1
  local ts = S.name.size * 0.85
  if CB.showSpellName and ci.spellName then
    text(dl, x0 + 1, ty, C.castText, a, ci.spellName, ts)
  end
  if CB.showTime and pct < 1 then
    local str = string.format('%.1fs', remain)
    text(dl, x1 - text_width(str, ts) - 1, ty, C.castText, a, str, ts)
  end
end

----------------------------------------------------------------------------
-- One plate, centered on p.sx/p.sy.
----------------------------------------------------------------------------
---@param p Plate
---@param ci CastInfo|nil
function R.plate(dl, S, p, ci, now)
  local C = S.colors
  local phase = (p.id % 89) * 0.41           -- desync passive anims per plate

  local a = p.alpha * S.bar.opacity
  if S.anim.breathe then
    a = a * (1 - S.anim.breatheAmount * hz_pulse(now, S.anim.breatheSpeed, phase))
  end
  if a <= 0.01 then return end

  local w = S.bar.width  * p.scale
  local h = S.bar.height * p.scale
  local cx = p.sx
  local cy = p.sy
  if S.anim.bob then
    cy = cy + math.sin((now + phase) * S.anim.bobSpeed * 2 * math.pi) * S.anim.bobAmount
  end
  local x0, y0 = cx - w * 0.5, cy - h * 0.5
  local x1, y1 = cx + w * 0.5, cy + h * 0.5
  local rnd = S.bar.rounding
  local bt  = S.bar.borderThickness

  -- pulsing outer glow rings
  if S.anim.borderGlow then
    local g = hz_pulse(now, S.anim.glowSpeed, phase)
    for i = 1, 2 do
      local e = bt + i * 2
      dl:AddRect(ImVec2(x0 - e, y0 - e), ImVec2(x1 + e, y1 + e),
                 u32(C.glow, a * g / i), rnd + e)
    end
  end

  -- border halo + background
  if bt > 0 then
    dl:AddRectFilled(ImVec2(x0 - bt, y0 - bt), ImVec2(x1 + bt, y1 + bt), u32(C.border, a), rnd)
  end
  dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.barBack, a), rnd)

  -- HP fill (low-HP heartbeat shifts the color toward lowHp and pulses it)
  local fillC = hp_color(S, p.dispHp)
  local lowPulse = 0
  if S.anim.lowHpPulse and p.dispHp <= S.anim.lowHpThreshold then
    lowPulse = hz_pulse(now, S.anim.lowHpSpeed, phase)
    fillC = anim.lerp_color(fillC, C.lowHp, 0.35 + 0.45 * lowPulse)
  end
  fill_styled(dl, S, x0, y0, x0 + w * p.dispHp, y1, fillC, a, now)
  segment_ticks(dl, S, x0, y0, x1, y1, a)

  -- damage flash overlay
  if S.anim.damageFlash then
    local f = anim.fade(p.flashAt, S.anim.flashDur, now)
    if f > 0 then
      dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.flash, a * f), rnd)
    end
  end

  -- sheen sweeps the whole bar (background included), then the border on top
  if S.anim.sheen then sheen_sweep(dl, S, x0, y0, x1, y1, a, now, phase) end
  dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), u32(C.border, a), rnd)
  if lowPulse > 0 then
    dl:AddRect(ImVec2(x0 - 1, y0 - 1), ImVec2(x1 + 1, y1 + 1), u32(C.lowHp, a * lowPulse), rnd)
  end

  -- HP % text inside the bar (right-aligned)
  if S.hp.showPct then
    local str = string.format('%d%%', math.floor(p.dispHp * 100 + 0.5))
    local ts  = math.min(S.name.size, h + 4)
    text(dl, x1 - text_width(str, ts) - 2, cy - text_height(ts) * 0.5, C.hpText, a, str, ts)
  end

  -- name, per position setting
  local belowY = y1 + bt + 1
  local pos = S.name.show and S.name.position or NP.HIDDEN
  if pos == NP.ABOVE then
    local th = text_height(S.name.size)
    text(dl, cx - text_width(p.name, S.name.size) * 0.5, y0 - bt - th - 1, C.name, a, p.name, S.name.size)
  elseif pos == NP.BELOW then
    text(dl, cx - text_width(p.name, S.name.size) * 0.5, belowY, C.name, a, p.name, S.name.size)
    belowY = belowY + text_height(S.name.size) + 1
  elseif pos == NP.INSIDE then
    local ts = math.min(S.name.size, h + 4)
    text(dl, cx - text_width(p.name, ts) * 0.5, cy - text_height(ts) * 0.5, C.name, a, p.name, ts)
  end

  -- cast bar under the whole stack
  if ci and S.castbar.show then
    cast_bar(dl, S, ci, cx, belowY + S.castbar.gap, w, a, now, phase)
  end
end

return R
