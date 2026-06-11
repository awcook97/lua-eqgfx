--[[
  nameplates/render.lua - draws one nameplate: HP bar + name + buffs + cast bar.

  Drawn inside the fullscreen pass-through overlay window that init.lua opens
  each frame (kept at the BACK of the ImGui window stack, so plates sit under
  every other ImGui window). That window context is also what lets us draw
  real spell icons via mq.FindTextureAnimation + ImGui.DrawTextureAnimation.
  NOTE: EQ's own windows are drawn by the game before MQ's ImGui overlay, so
  plates can never truly render beneath native EQ UI - instead init.lua
  clip-rects plate drawing around the native window rects (uirects), which
  looks identical. To support that, R.plate records the actual drawn extents
  into plate.ext each frame (geom envelope + text/cast-bar widths).

  Animation kinds:
    event-driven : fade in/out, appear pop, damage flash, cast pulses
    passive      : sheen sweep, scrolling stripes, low-HP heartbeat, breathe,
                   border glow, idle bob - always running, desynced per plate

  Bar fills (HP + cast) go through fill_styled(), alpha procedural texture engine:
  Flat / Gradient / Glass / Stripes / Segmented.

  The MQ ImGui binding isn't documented, so probe_caps() pcall-checks the
  fancier calls once on the first frame:
    sizedText  - drawList:AddText(font, size, ...)        else default-size text
    multiColor - drawList:AddRectFilledMultiColor(...)    else flat shading
    clipRect   - drawList:PushClipRect/PopClipRect        else axis-aligned fallbacks
    iconDraw   - DrawTextureAnimation spell icons   else colored squares
]]

local mq    = require('mq')
local ImGui = require('ImGui')
local anim  = require('eqgfx.nameplates.anim')
local types = require('eqgfx.nameplates._types')
local casts = require('eqgfx.casts')

local NP = types.NamePosition
local BT = types.BarTexture
local BP = types.BuffPosition
local BD = types.BuffDirection

local R = {}

---@class RenderCaps probed once on the first frame; nil = unknown yet
---@field sizedText boolean|nil
---@field multiColor boolean|nil
---@field clipRect boolean|nil
---@field iconDraw boolean|nil
---@field atlasFound boolean|nil
---@field iconVariant integer|nil

---@type RenderCaps
R.caps = { sizedText = nil, multiColor = nil, clipRect = nil, iconDraw = nil }

--- Probe the optional ImGui binding features once (first frame) - sized
--- text, multi-color rects, clip rects. Every later draw checks R.caps and
--- degrades per-feature instead of crashing on an older MQ build.
---
--- ```lua
--- local drawList = ImGui.GetWindowDrawList()
--- render.probe_caps(drawList)
--- if render.caps.clipRect then drawList:PushClipRect(...) end
--- ```
---@param drawList ImDrawList # any ImGui draw list
function R.probe_caps(drawList)
  if R.caps.sizedText ~= nil then return end
  R.caps.sizedText = pcall(function()
    drawList:AddText(ImGui.GetFont(), 13, ImVec2(-4096, -4096), 0x01FFFFFF, 'x')
  end) and true or false
  R.caps.multiColor = pcall(function()
    drawList:AddRectFilledMultiColor(ImVec2(-4096, -4096), ImVec2(-4095, -4095),
                               0x01000000, 0x01000000, 0x01000000, 0x01000000)
  end) and true or false
  R.caps.clipRect = pcall(function()
    drawList:PushClipRect(ImVec2(0, 0), ImVec2(1, 1), true)
    drawList:PopClipRect()
  end) and true or false
  -- iconDraw probed lazily on the first real icon (needs a live animation)
end

--- Settings color ({r,g,b,a} floats) -> ImGui packed u32, with an optional
--- extra alpha multiplier (the per-plate fade).
---@param c number[] # {r,g,b,a} floats 0..1
---@param alphaMult number|nil # multiplied into alpha (default 1)
---@return integer u32
local function u32(c, alphaMult)
  return ImGui.ColorConvertFloat4ToU32({ c[1], c[2], c[3], c[4] * (alphaMult or 1) })
end

--- Shade a color: f > 1 lightens toward white, f < 1 darkens toward black.
---@param c number[] # {r,g,b,a}
---@param f number # shade factor
---@return number[] shaded # new {r,g,b,a}
local function shade(c, f)
  if f >= 1 then
    local t = f - 1
    return { c[1] + (1 - c[1]) * t, c[2] + (1 - c[2]) * t, c[3] + (1 - c[3]) * t, c[4] }
  end
  return { c[1] * f, c[2] * f, c[3] * f, c[4] }
end

--- Draw text at an optional pixel size (falls back to the default font size
--- when the binding can't size text - check R.caps.sizedText).
---@param drawList ImDrawList
---@param x number # screen X
---@param y number # screen Y
---@param c number[] # {r,g,b,a} color
---@param alphaMult number|nil # extra alpha multiplier
---@param str string
---@param size number|nil # font pixel size (needs caps.sizedText)
local function text(drawList, x, y, c, alphaMult, str, size)
  if R.caps.sizedText and size then
    drawList:AddText(ImGui.GetFont(), size, ImVec2(x, y), u32(c, alphaMult), str)
  else
    drawList:AddText(ImVec2(x, y), u32(c, alphaMult), str)
  end
end

--- Width of a string as text() will draw it (scaled when sized text works).
---@param str string
---@param size number|nil # font pixel size
---@return number px
local function text_width(str, size)
  local w = ImGui.CalcTextSize(str)
  if R.caps.sizedText and size then
    local base = ImGui.GetFontSize()
    if base and base > 0 then w = w * (size / base) end
  end
  return w
end

--- Height of a line as text() will draw it.
---@param size number|nil # font pixel size
---@return number px
local function text_height(size)
  if R.caps.sizedText and size then return size end
  return ImGui.GetFontSize() or 13
end

--- HP fill color for a fraction: the low->mid->high gradient, or the fixed
--- bar color when the gradient is off.
---@param cfg NameplatesConfig # nameplates settings
---@param plate number # HP fraction 0..1
---@return number[] color # {r,g,b,a}
local function hp_color(cfg, plate)
  if not cfg.hp.gradient then return cfg.colors.barFixed end
  local colors = cfg.colors
  if plate <= 0.5 then return anim.lerp_color(colors.barLow, colors.barMid, plate * 2) end
  return anim.lerp_color(colors.barMid, colors.barHigh, (plate - 0.5) * 2)
end

----------------------------------------------------------------------------
-- Spell icons (A_SpellIcons atlas + Spell.SpellIcon cell).
----------------------------------------------------------------------------
local iconAtlas   -- nil = not tried, false = unavailable

--- The spell-icon texture atlas, found once and cached (false = unavailable).
--- The handle's methods vary by MQ build, so callers probe them via pcall.
---@return any|nil atlas # CTextureAnimation handle, nil when missing
local function icon_atlas()
  if iconAtlas == nil then
    for _, name in ipairs({ 'A_SpellIcons', 'A_SpellGems' }) do
      local okk, alpha = pcall(mq.FindTextureAnimation, name)
      if okk and alpha then iconAtlas = alpha break end
    end
    iconAtlas = iconAtlas or false
  end
  return iconAtlas or nil
end

-- The exact binding signatures for cursor placement / texture drawing vary
-- between MQ builds, so try the known variants once and remember the winner.
local ICON_VARIANTS = {
  function(atlas, x, y, size)
    ImGui.SetCursorScreenPos(ImVec2(x, y))
    ImGui.DrawTextureAnimation(atlas, size, size)
  end,
  function(atlas, x, y, size)
    ImGui.SetCursorScreenPos(x, y)
    ImGui.DrawTextureAnimation(atlas, size, size)
  end,
  function(atlas, x, y, size)
    ImGui.SetCursorScreenPos(ImVec2(x, y))
    ImGui.DrawTextureAnimation(atlas, ImVec2(size, size))
  end,
  function(atlas, x, y, size)
    ImGui.SetCursorScreenPos(x, y)
    ImGui.DrawTextureAnimation(atlas, ImVec2(size, size))
  end,
}
local iconVariant   -- nil = unprobed, 0 = none work, else index

--- Select an atlas cell. The binding method is SetTextureCell (mq source:
--- lua_EQBindings.cpp binds CTextureAnimation::SetCurCell as
--- "SetTextureCell"); older builds may have exposed SetCurrentCell, so both
--- are tried.
---@param atlas any # CTextureAnimation handle (methods probed via pcall)
---@param cell integer # SpellIcon cell index
---@return boolean ok
local function set_cell(atlas, cell)
  if pcall(function() atlas:SetTextureCell(cell) end) then return true end
  return pcall(function() atlas:SetCurrentCell(cell) end)
end

--- Draw one spell icon at absolute screen coords (A_SpellIcons atlas cell).
--- Falls back to a colored square if no texture-animation variant works in
--- this MQ build (R.caps.iconDraw records the outcome).
---@param drawList ImDrawList
---@param x number # left edge, pixels
---@param y number # top edge, pixels
---@param size number # icon size in pixels (floored)
---@param iconCell integer|nil # Spell.SpellIcon cell, nil = fallback square
---@param fallbackC number[] # {r,g,b,a} for the fallback square
---@param alpha number # 0..1 plate alpha
local function draw_spell_icon(drawList, x, y, size, iconCell, fallbackC, alpha)
  local atlas = icon_atlas()
  R.caps.atlasFound = atlas and true or false
  size = math.floor(size)
  if atlas and iconCell and iconVariant ~= 0 then
    if not set_cell(atlas, iconCell) then
      iconVariant = 0
    elseif iconVariant then
      if pcall(ICON_VARIANTS[iconVariant], atlas, x, y, size) then return end
      iconVariant = 0
    else
      for v = 1, #ICON_VARIANTS do
        if pcall(ICON_VARIANTS[v], atlas, x, y, size) then
          iconVariant = v
          R.caps.iconDraw = true
          R.caps.iconVariant = v
          return
        end
      end
      iconVariant = 0
    end
    if iconVariant == 0 then R.caps.iconDraw = false end
    R.caps.iconVariant = iconVariant
  end
  drawList:AddRectFilled(ImVec2(x, y), ImVec2(x + size, y + size), u32(fallbackC, alpha * 0.85))
end

----------------------------------------------------------------------------
-- Procedural bar textures.
----------------------------------------------------------------------------
--- Diagonal stripe overlay for the Stripes bar texture (scrolls when
--- anim.stripeScroll is on). Clips properly when caps.clipRect works.
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (anim.stripeScroll/stripeSpeed)
---@param x0 number # fill rect, pixels
---@param y0 number
---@param x1 number
---@param y1 number
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase
local function stripes_overlay(drawList, cfg, x0, y0, x1, y1, alpha, timeNow)
  local sw, gap = 6, 6
  local period = sw + gap
  local h = y1 - y0
  local speed = cfg.anim.stripeScroll and cfg.anim.stripeSpeed or 0
  local off = (timeNow * speed) % period
  local col = u32({ 1, 1, 1, 0.13 }, alpha)
  if R.caps.clipRect then
    drawList:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    local x = x0 - h - period + off
    while x < x1 do
      drawList:AddQuadFilled(ImVec2(x, y1), ImVec2(x + h, y0),
                       ImVec2(x + h + sw, y0), ImVec2(x + sw, y1), col)
      x = x + period
    end
    drawList:PopClipRect()
  else
    local x = x0 - period + off
    while x < x1 do
      local bx0, bx1 = math.max(x, x0), math.min(x + sw, x1)
      if bx1 > bx0 then drawList:AddRectFilled(ImVec2(bx0, y0), ImVec2(bx1, y1), col) end
      x = x + period
    end
  end
end

--- Fill a bar span with the configured texture style (Flat / Gradient /
--- Glass / Stripes; Segmented draws its ticks separately). The procedural
--- "texture" engine for HP and cast bars.
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (bar.texture, bar.rounding, anim.*)
---@param x0 number # fill rect, pixels
---@param y0 number
---@param x1 number # right edge of the FILLED span (not the whole bar)
---@param y1 number
---@param c number[] # base fill color {r,g,b,a}
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase (stripe scroll)
local function fill_styled(drawList, cfg, x0, y0, x1, y1, c, alpha, timeNow)
  if x1 - x0 < 0.5 then return end
  local style = cfg.bar.texture
  local rnd = cfg.bar.rounding

  drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(c, alpha), rnd)

  if (style == BT.GRADIENT or style == BT.GLASS) and R.caps.multiColor then
    local ix0, ix1 = x0 + rnd * 0.5, x1 - rnd * 0.5
    if ix1 > ix0 then
      if style == BT.GRADIENT then
        local top = u32(shade(c, 1.35), alpha)
        local bot = u32(shade(c, 0.60), alpha)
        drawList:AddRectFilledMultiColor(ImVec2(ix0, y0), ImVec2(ix1, y1), top, top, bot, bot)
      else
        local hi  = u32({ 1, 1, 1, 0.38 }, alpha)
        local lo  = u32({ 1, 1, 1, 0.02 }, alpha)
        local mid = y0 + (y1 - y0) * 0.45
        drawList:AddRectFilledMultiColor(ImVec2(ix0, y0), ImVec2(ix1, mid), hi, hi, lo, lo)
        drawList:AddRectFilledMultiColor(ImVec2(ix0, mid), ImVec2(ix1, y1),
                                   u32({ 0, 0, 0, 0.00 }, alpha), u32({ 0, 0, 0, 0.00 }, alpha),
                                   u32({ 0, 0, 0, 0.22 }, alpha), u32({ 0, 0, 0, 0.22 }, alpha))
      end
    end
  elseif style == BT.GLASS then
    local mid = y0 + (y1 - y0) * 0.45
    drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, mid), u32({ 1, 1, 1, 0.18 }, alpha), rnd)
  elseif style == BT.STRIPES then
    stripes_overlay(drawList, cfg, x0, y0, x1, y1, alpha, timeNow)
  end
end

--- Tick marks every 10% for the Segmented bar texture (no-op otherwise).
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (bar.texture)
---@param x0 number # FULL bar rect, pixels (not just the filled span)
---@param y0 number
---@param x1 number
---@param y1 number
---@param alpha number # 0..1 plate alpha
local function segment_ticks(drawList, cfg, x0, y0, x1, y1, alpha)
  if cfg.bar.texture ~= BT.SEGMENTS then return end
  local w = x1 - x0
  local col = u32({ 0, 0, 0, 0.45 }, alpha)
  for i = 1, 9 do
    local x = x0 + w * i / 10
    drawList:AddLine(ImVec2(x, y0 + 1), ImVec2(x, y1 - 1), col, 1.0)
  end
end

--- Light band sweeping across a bar every anim.sheenPeriod seconds.
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (anim.sheenPeriod)
---@param x0 number # bar rect, pixels
---@param y0 number
---@param x1 number
---@param y1 number
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase
---@param phase number # per-plate phase offset (desyncs the sweeps)
local function sheen_sweep(drawList, cfg, x0, y0, x1, y1, alpha, timeNow, phase)
  local period = math.max(cfg.anim.sheenPeriod, 0.5)
  local t = ((timeNow + phase) % period) / period
  if t > 0.35 then return end
  local k = t / 0.35
  local w, h = x1 - x0, y1 - y0
  local bandW = math.max(8, w * 0.18)
  local bx = x0 - bandW - h + (w + 2 * (bandW + h)) * k
  local col = u32({ 1, 1, 1, 0.28 }, alpha)
  if R.caps.clipRect then
    drawList:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    drawList:AddQuadFilled(ImVec2(bx, y1), ImVec2(bx + h, y0),
                     ImVec2(bx + h + bandW, y0), ImVec2(bx + bandW, y1), col)
    drawList:PopClipRect()
  else
    local cx0, cx1 = math.max(bx, x0), math.min(bx + bandW, x1)
    if cx1 > cx0 then drawList:AddRectFilled(ImVec2(cx0, y0), ImVec2(cx1, y1), col) end
  end
end

--- 0..1 sine pulse at a frequency in Hz, with an optional phase offset
--- (per-plate phases keep a crowd desynced; omit it for synced pulses).
---@param timeNow number # frame timebase
---@param hz number # cycles per second
---@param phase number|nil # timebase offset (default 0)
---@return number pulse # 0..1
local function hz_pulse(timeNow, hz, phase)
  return 0.5 + 0.5 * math.sin((timeNow + (phase or 0)) * hz * 2 * math.pi)
end

--- Mouse position, tolerant of binding differences (two numbers vs ImVec2).
---@return number|nil x # nil when unavailable
---@return number|nil y
local function mouse_pos()
  local okk, alpha, b = pcall(ImGui.GetMousePos)
  if not okk then return end
  if type(alpha) == 'number' then return alpha, b end
  if alpha ~= nil then
    local ok2, x, y = pcall(function() return alpha.x, alpha.y end)
    if ok2 then return x, y end
  end
end

--- Is the right mouse button held? (pcall-guarded for older bindings.)
---@return boolean
local function right_mouse_down()
  local okk, v = pcall(ImGui.IsMouseDown, 1)
  return okk and v or false
end

--- HSV -> {r,g,b,a} color (rainbow name animations).
---@param h number # hue 0..1 (wraps)
---@param s number # saturation 0..1
---@param v number # value 0..1
---@param a4 number|nil # alpha (default 1)
---@return number[] color
local function hsv_color(h, s, v, a4)
  local i = math.floor(h * 6) % 6
  local f = h * 6 - math.floor(h * 6)
  local p2, q, t2 = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r1, g1, b1
  if     i == 0 then r1, g1, b1 = v, t2, p2
  elseif i == 1 then r1, g1, b1 = q, v, p2
  elseif i == 2 then r1, g1, b1 = p2, v, t2
  elseif i == 3 then r1, g1, b1 = p2, q, v
  elseif i == 4 then r1, g1, b1 = t2, p2, v
  else               r1, g1, b1 = v, p2, q end
  return { r1, g1, b1, a4 or 1 }
end

--- Deterministic per-name scramble (same name -> same gibberish every frame,
--- so anonymized names don't flicker).
---@param name string
---@return string gibberish # same length, A-Z
local function scramble(name)
  local seed = 5381
  for c = 1, #name do seed = (seed * 33 + name:byte(c)) % 2147483647 end
  local out = {}
  for c = 1, #name do
    seed = (seed * 1103515245 + 12345) % 2147483647
    out[c] = string.char(65 + seed % 26)
  end
  return table.concat(out)
end

local AM = types.AnonMode
local NA = types.NameAnim

--- Draw a name with its configured animation. Modes up to RAINBOW draw the
--- whole string at once; the rest draw letter by letter, each with its own
--- phase (wave, bounce, jitter, pulse, typewriter, rainbow-wave).
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (name.anim/animSpeed/animAmount/shadow)
---@param colors NpColors # cfg.colors
---@param label string # the (possibly anonymized) name to draw
---@param tx number # left edge, pixels
---@param ty number # top edge, pixels
---@param ts number # text size
---@param baseC number[] # base text color {r,g,b,a}
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase
---@param phase number # per-plate phase offset
local function draw_name_text(drawList, cfg, colors, label, tx, ty, ts, baseC, alpha, timeNow, phase)
  local mode = cfg.name.anim
  if mode <= NA.RAINBOW then
    if cfg.name.shadow then text(drawList, tx + 1, ty + 1, colors.nameShadow, alpha, label, ts) end
    text(drawList, tx, ty, baseC, alpha, label, ts)
    return
  end

  local spd = cfg.name.animSpeed
  local amp = cfg.name.animAmount
  timeNow = timeNow + phase   -- de-sync name anims between plates, same as sheen/breathe
  local n = #label
  local x = tx
  local reveal = nil
  if mode == NA.TYPEWRITER then
    reveal = ((timeNow * spd * 3) % (n + 6))   -- pause of ~6 "chars" between loops
  end
  for castInfo = 1, n do
    if reveal and castInfo > reveal then break end
    local ch = label:sub(castInfo, castInfo)
    local dx, dy, cc, cs = 0, 0, baseC, ts
    if mode == NA.WAVE then
      dy = math.sin((timeNow * spd * 2 + castInfo * 0.35) * 2 * math.pi * 0.5) * amp
    elseif mode == NA.BOUNCE then
      dy = -math.abs(math.sin((timeNow * spd + castInfo * 0.22) * 2 * math.pi * 0.5)) * amp
    elseif mode == NA.RAINBOW_WAVE then
      cc = hsv_color(((timeNow * spd * 0.15) + castInfo / math.max(n, 1)) % 1, 0.8, 1, baseC[4])
    elseif mode == NA.JITTER then
      dx = math.sin(timeNow * spd * 23 + castInfo * 13.7) * amp * 0.4
      dy = math.sin(timeNow * spd * 31 + castInfo * 7.3) * amp * 0.4
    elseif mode == NA.PULSE and R.caps.sizedText then
      cs = ts * (1 + 0.22 * math.sin((timeNow * spd * 2 + castInfo * 0.3) * math.pi))
    end
    if cfg.name.shadow then text(drawList, x + dx + 1, ty + dy + 1, colors.nameShadow, alpha, ch, cs) end
    text(drawList, x + dx, ty + dy, cc, alpha, ch, cs)
    x = x + text_width(ch, ts)   -- advance at base size for stable spacing
  end
end

--- Anonymized display name for PCs (NPCs always keep their real name).
---@param cfg NameplatesConfig # nameplates settings (name.anonMode)
---@param plate Plate
---@return string label
local function display_name(cfg, plate)
  local n = plate.name or '?'
  if not plate.isPC then return n end
  local mode = cfg.name.anonMode
  if mode == AM.OFF then return n end
  if mode == AM.CLASS then return plate.cls or n end
  if mode == AM.CLASS_SHORT then return plate.clsShort or n end
  if mode == AM.SCRAMBLE then
    if plate._scrFor ~= n then plate._scrFor, plate._scr = n, scramble(n) end
    return plate._scr
  end
  if mode == AM.ASTERISKS then return string.rep('*', #n) end
  if mode == AM.ASTERISKS8 then return '********' end
  -- FIRST_LAST
  if #n <= 2 then return n end
  return n:sub(1, 1) .. string.rep('*', #n - 2) .. n:sub(-1)
end

--- Open the in-game Spell Display window by "clicking" a generated link
--- (the buff right-click-inspect feature).
---@param spellID integer
local function inspect_spell(spellID)
  pcall(function()
    local spell = mq.TLO.Spell(spellID) --[[@as spell]]   -- narrow the TLO union
    local link = mq.FormatSpellLink(spell)
    local links = mq.ExtractLinks(link)
    if links and links[1] then mq.ExecuteTextLink(links[1]) end
  end)
end
local lastInspectAt = 0

----------------------------------------------------------------------------
-- Buff icon rows. geom carries per-side cursors so multiple rows on the
-- same side stack instead of overlapping.
----------------------------------------------------------------------------
local BEN_BORDER   = { 0.10, 0.90, 0.10, 0.90 }
local DET_BORDER   = { 1.00, 0.15, 0.15, 0.90 }
local BEN_FALLBACK = { 0.20, 0.70, 0.20, 1.0 }
local DET_FALLBACK = { 0.80, 0.20, 0.20, 1.0 }
local DIM          = { 0, 0, 0, 1 }

local BFM = types.BuffBorderMode

--- Lay out n icons in grid space: primary axis runs along +x (horiz) or +y,
--- wrapping after `per` items along the other axis. Per-icon sizes vary with
--- their override scale.
---@param list BuffEntry[] # entries (only .scale is read here)
---@param n integer # how many to lay out
---@param size number # base icon size in pixels
---@param gap number # spacing between icons
---@param per integer # wrap after this many along the primary axis
---@param horiz boolean # true = rows, false = columns
---@return { x: number, y: number, sz: number }[] pos # grid-space cell per icon
---@return number W # bounding width
---@return number H # bounding height
local function layout_grid(list, n, size, gap, per, horiz)
  local pos = {}
  local wrapOff, idx = 0, 1
  while idx <= n do
    local last = math.min(idx + per - 1, n)
    local run, thick = 0, 0
    for i = idx, last do
      local sz = size * (list[i].scale or 1)
      if horiz then pos[i] = { x = run, y = wrapOff, sz = sz }
      else          pos[i] = { x = wrapOff, y = run, sz = sz } end
      run = run + sz + gap
      thick = math.max(thick, sz)
    end
    wrapOff = wrapOff + thick + gap
    idx = last + 1
  end
  local W, H = 0, 0
  for i = 1, n do
    W = math.max(W, pos[i].x + pos[i].sz)
    H = math.max(H, pos[i].y + pos[i].sz)
  end
  return pos, W, H
end

--- Border color for one buff icon (by type or by caster, per settings).
---@param buffCfg NpBuffsCfg # cfg.buffs
---@param entry BuffEntry
---@return RGBA color
local function buff_border_color(buffCfg, entry)
  if buffCfg.borderMode == BFM.BY_CASTER then
    return entry.mine and buffCfg.mineBorder or buffCfg.otherBorder
  end
  return entry.ben and BEN_BORDER or DET_BORDER
end

--- Draw one buff icon row anchored to a plate side, advancing the geometry
--- cursor for that side so stacked rows don't overlap. Also handles hover
--- tooltips (foreground list) and right-click inspect.
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings
---@param list BuffEntry[]|nil # entries to draw (pre-sorted, pre-filtered)
---@param rowCfg NpBuffRowCfg # which side + stacking direction
---@param geom PlateGeom # per-side geometry cursors from R.plate (mutated)
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase
local function draw_buff_row(drawList, cfg, list, rowCfg, geom, alpha, timeNow)
  if not list or #list == 0 or rowCfg.position == BP.HIDDEN then return end
  local buffCfg = cfg.buffs
  local size, gap = buffCfg.iconSize, buffCfg.spacing
  local n = math.min(#list, buffCfg.maxIcons)
  local horiz = rowCfg.direction == BD.HORIZONTAL
  local per = math.max(1, buffCfg.maxPerRow)

  local pos, W, H = layout_grid(list, n, size, gap, per, horiz)

  -- map grid space -> screen per anchor side (grid wrap axis grows AWAY
  -- from the plate; TOP flips vertically so row 1 hugs the plate)
  local p2 = rowCfg.position
  local ox, oy, flipY
  local cx = (geom.x0 + geom.x1) * 0.5
  if p2 == BP.TOP then
    ox, oy, flipY = cx - W * 0.5, geom.top - 2, true
    geom.top = geom.top - H - 2
  elseif p2 == BP.BOTTOM then
    ox, oy = cx - W * 0.5, geom.bottom + 2
    geom.bottom = geom.bottom + H + 2
  elseif p2 == BP.LEFT then
    ox, oy = geom.left - 3 - W, geom.y0
    geom.left = geom.left - W - 3
  else -- RIGHT
    ox, oy = geom.right + 3, geom.y0
    geom.right = geom.right + W + 3
  end

  local mx, my
  if buffCfg.tooltip or buffCfg.rightClickInspect then mx, my = mouse_pos() end

  for i = 1, n do
    local entry = list[i]
    local cell = pos[i]
    local ix = ox + cell.x
    local iy = flipY and (oy - cell.y - cell.sz) or (oy + cell.y)
    draw_spell_icon(drawList, ix, iy, cell.sz, entry.icon, entry.ben and BEN_FALLBACK or DET_FALLBACK, alpha)
    if buffCfg.dimOthers > 0 and not entry.mine then
      drawList:AddRectFilled(ImVec2(ix, iy), ImVec2(ix + cell.sz, iy + cell.sz), u32(DIM, alpha * buffCfg.dimOthers))
    end
    if buffCfg.borders then
      local bc = buff_border_color(buffCfg, entry)
      local ba = alpha
      if buffCfg.detPulse and not entry.ben then
        ba = alpha * (0.45 + 0.55 * hz_pulse(timeNow or 0, 1.5, entry.id % 7))
      end
      drawList:AddRect(ImVec2(ix - 0.5, iy - 0.5), ImVec2(ix + cell.sz + 0.5, iy + cell.sz + 0.5),
                 u32(bc, ba), 0)
    end
    if buffCfg.appearFlash and entry.addedAt and timeNow and timeNow - entry.addedAt < 0.6 then
      local f = 1 - (timeNow - entry.addedAt) / 0.6
      local grow = (1 - f) * 5
      drawList:AddRect(ImVec2(ix - grow, iy - grow), ImVec2(ix + cell.sz + grow, iy + cell.sz + grow),
                 u32({ 1, 1, 1, 0.9 }, alpha * f), 2)
    end

    -- hover: tooltip on the FOREGROUND list (above everything) + inspect
    if mx and mx >= ix and mx < ix + cell.sz and my >= iy and my < iy + cell.sz then
      if buffCfg.tooltip then
        local fg = ImGui.GetForegroundDrawList()
        local lines = { entry.name ~= '' and entry.name or ('Spell ' .. entry.id) }
        if entry.caster then lines[#lines + 1] = 'Caster: ' .. entry.caster end
        if entry.dur and entry.dur > 0 then
          lines[#lines + 1] = string.format('Duration: %d:%02d', math.floor(entry.dur / 60), entry.dur % 60)
        end
        if buffCfg.rightClickInspect then lines[#lines + 1] = '(hold right-click to inspect)' end
        local tw = 0
        for _, l in ipairs(lines) do tw = math.max(tw, text_width(l)) end
        local th = #lines * (text_height() + 2)
        local tx, ty = mx + 14, my + 12
        fg:AddRectFilled(ImVec2(tx - 4, ty - 3), ImVec2(tx + tw + 4, ty + th + 3),
                         u32({ 0.05, 0.05, 0.05, 0.92 }), 3)
        fg:AddRect(ImVec2(tx - 4, ty - 3), ImVec2(tx + tw + 4, ty + th + 3),
                   u32(buff_border_color(buffCfg, entry), 1), 3)
        for li, l in ipairs(lines) do
          local col = (li == 1) and { 1, 1, 1, 1 } or { 0.75, 0.75, 0.75, 1 }
          fg:AddText(ImVec2(tx, ty + (li - 1) * (text_height() + 2)), u32(col), l)
        end
      end
      if buffCfg.rightClickInspect and right_mouse_down() then
        if timeNow - lastInspectAt > 1.5 then
          lastInspectAt = timeNow
          inspect_spell(entry.id)
        end
      end
    end
  end
end

--- Draw a plate's buff rows (beneficial/detrimental, combined or separate).
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings
---@param plate Plate # reads plate.buffsB / plate.buffsD
---@param geom PlateGeom # per-side geometry cursors (mutated)
---@param alpha number # 0..1 plate alpha
---@param isTarget boolean|nil # the onlyTarget filter
---@param timeNow number # frame timebase
local function draw_buffs(drawList, cfg, plate, geom, alpha, isTarget, timeNow)
  local buffCfg = cfg.buffs
  if not buffCfg.enabled then return end
  if buffCfg.onlyTarget and not isTarget then return end
  local ben, det = plate.buffsB, plate.buffsD
  if buffCfg.combine then
    local all = {}
    for _, entry in ipairs(ben or {}) do all[#all + 1] = entry end
    for _, entry in ipairs(det or {}) do all[#all + 1] = entry end
    draw_buff_row(drawList, cfg, all, buffCfg.beneficial, geom, alpha, timeNow)
  else
    draw_buff_row(drawList, cfg, ben, buffCfg.beneficial, geom, alpha, timeNow)
    draw_buff_row(drawList, cfg, det, buffCfg.detrimental, geom, alpha, timeNow)
  end
end

----------------------------------------------------------------------------
-- Cast bar under the plate stack.
----------------------------------------------------------------------------
--- Draw the cast bar under the plate stack: spell icon, styled fill on the
--- tracker's REAL clock (visuals stay on the frame timebase), name/time
--- text, the interrupted state, and the finish pulse. Extends the geometry
--- cursors so plate.ext covers it.
---@param drawList ImDrawList
---@param cfg NameplatesConfig # nameplates settings (castbar.*)
---@param castInfo CastInfo # from eqgfx.casts
---@param cx number # plate center X, pixels
---@param geom PlateGeom # per-side geometry cursors (bottom/left/right mutated)
---@param w number # plate bar width (cast bar scales from it)
---@param alpha number # 0..1 plate alpha
---@param timeNow number # frame timebase (sheen/pulse visuals)
---@param phase number # per-plate phase offset
local function cast_bar(drawList, cfg, castInfo, cx, geom, w, alpha, timeNow, phase)
  local castCfg, colors = cfg.castbar, cfg.colors
  local h  = castCfg.height
  local cw = w * castCfg.widthScale
  local x0, x1 = cx - cw * 0.5, cx + cw * 0.5
  local y0 = geom.bottom + castCfg.gap
  local y1 = y0 + h
  geom.left   = math.min(geom.left, x0 - (castCfg.showIcon and castCfg.iconSize + 3 or 0))
  geom.right  = math.max(geom.right, x1)
  geom.bottom = math.max(geom.bottom, y1 + ((castCfg.showSpellName or castCfg.showTime)
                                            and 1 + text_height(castCfg.textSize) or 0))
  -- cast math runs on the tracker's real clock (spell durations are wall
  -- seconds); visuals (sheen) stay on the frame timebase
  local castNow = casts.now()
  local pct, remain = casts.progress(castInfo, castNow)

  -- spell icon, vertically centered on the bar, left of it
  if castCfg.showIcon and not castInfo.interrupted then
    local isz = castCfg.iconSize
    draw_spell_icon(drawList, x0 - isz - 3, (y0 + y1 - isz) * 0.5, isz,
                    castInfo.spellIcon, colors.castFill, alpha)
  end

  if castInfo.interrupted then
    local f = anim.fade(castInfo.interruptedAt, 0.8, castNow)
    if f <= 0 then return end
    alpha = alpha * f
    drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.castBack, alpha), cfg.bar.rounding)
    drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.castInterrupt, alpha * 0.8), cfg.bar.rounding)
    if castCfg.showSpellName then
      text(drawList, x0 + 1, y1 + 1, colors.castInterrupt, alpha, 'Interrupted', castCfg.textSize)
    end
    return
  end

  drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.castBack, alpha), cfg.bar.rounding)
  fill_styled(drawList, cfg, x0, y0, x0 + cw * pct, y1, colors.castFill, alpha, timeNow)
  drawList:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.border, alpha), cfg.bar.rounding)
  if cfg.anim.sheen then sheen_sweep(drawList, cfg, x0, y0, x1, y1, alpha, timeNow, phase + 0.7) end

  if pct >= 1 and cfg.anim.castPulse then
    local f = anim.fade(castInfo.startedAt + castInfo.duration, 0.6, castNow)
    if f > 0 then
      local grow = (1 - f) * 6
      drawList:AddRect(ImVec2(x0 - grow, y0 - grow), ImVec2(x1 + grow, y1 + grow),
                 u32(colors.castFill, alpha * f), cfg.bar.rounding + grow)
    end
  end

  local ty = y1 + 1
  local ts = castCfg.textSize
  if castCfg.showSpellName and castInfo.spellName then
    text(drawList, x0 + 1, ty, colors.castText, alpha, castInfo.spellName, ts)
    geom.right = math.max(geom.right, x0 + 1 + text_width(castInfo.spellName, ts))
  end
  if castCfg.showTime and pct < 1 then
    local str
    if castCfg.showTotal then str = string.format('%.1fs / %.1fs', remain, castInfo.duration)
    else str = string.format('%.1fs', remain) end
    text(drawList, x1 - text_width(str, ts) - 1, ty, colors.castText, alpha, str, ts)
  end
end

----------------------------------------------------------------------------
-- One plate, centered on p.sx/p.sy.
----------------------------------------------------------------------------

--- Draw one complete nameplate at its projected position: glow rings,
--- border, HP bar (with AE-highlight tint), resource bars, HP % text, name,
--- buff rows, cast bar. Records the actual drawn footprint into plate.ext
--- (relative to sx/sy) for next frame's native-UI occlusion test.
---
--- ```lua
--- -- inside the overlay window's draw pass:
--- render.plate(drawList, cfg, plate, casts.get(plate.id), timeNow, plate.id == tgtID)
--- ```
---@param drawList ImDrawList # the overlay window's draw list
---@param cfg NameplatesConfig # nameplates settings
---@param plate Plate # must have sx/sy set by the caller
---@param castInfo CastInfo|nil # active cast to show a cast bar for
---@param timeNow number # frame timebase (drives all passive animation)
---@param isTarget boolean|nil # apply the target styling
function R.plate(drawList, cfg, plate, castInfo, timeNow, isTarget)
  local colors = cfg.colors
  local targetCfg = cfg.target
  local onTarget = isTarget and targetCfg.distinguish
  local phase = (plate.id % 89) * 0.41

  local alpha = plate.alpha * cfg.bar.opacity
  if cfg.anim.breathe then
    alpha = alpha * (1 - cfg.anim.breatheAmount * hz_pulse(timeNow, cfg.anim.breatheSpeed, phase))
  end
  if alpha <= 0.01 then return end

  local scale = plate.scale * (onTarget and targetCfg.scale or 1)
  local w = cfg.bar.width  * scale
  local h = cfg.bar.height * scale
  local cx = plate.sx or 0   -- guaranteed by callers; defaulted for the analyzer
  local cy = plate.sy or 0
  local baseY = cy           -- plate.ext is recorded relative to (cx, baseY)
  if cfg.anim.bob then
    cy = cy + math.sin((timeNow + phase) * cfg.anim.bobSpeed * 2 * math.pi) * cfg.anim.bobAmount
  end
  local x0, y0 = cx - w * 0.5, cy - h * 0.5
  local x1, y1 = cx + w * 0.5, cy + h * 0.5
  local rnd = cfg.bar.rounding
  local borderC = (onTarget and targetCfg.border) and targetCfg.borderColor or colors.border
  local bt      = (onTarget and targetCfg.border) and targetCfg.borderThickness or cfg.bar.borderThickness

  -- AE cast highlight: while my in-flight AE will affect this spawn, tint
  -- toward the det/ben color. The amount is smoothed by init.lua; the pulse
  -- is UNphased so every marked plate beats in sync and reads as one group.
  local aehl = cfg.aehl
  local aeC, aeAmt = nil, 0
  if aehl.enabled and plate.aeKind and (plate.aeAmt or 0) > 0.01 then
    aeC = (plate.aeKind == 'det') and colors.aeDet or colors.aeBen
    aeAmt = plate.aeAmt or 0
    if aehl.pulse then
      aeAmt = aeAmt * (1 - aehl.pulseAmount + aehl.pulseAmount * hz_pulse(timeNow, aehl.pulseSpeed))
    end
    if aehl.tintBorder then borderC = anim.lerp_color(borderC, aeC, aeAmt) end
  end

  -- pulsing outer glow rings (forced on for the target if configured)
  if cfg.anim.borderGlow or (onTarget and targetCfg.glow) then
    local glowC = onTarget and targetCfg.borderColor or colors.glow
    local cell = hz_pulse(timeNow, cfg.anim.glowSpeed, phase)
    for i = 1, 2 do
      local entry = bt + i * 2
      drawList:AddRect(ImVec2(x0 - entry, y0 - entry), ImVec2(x1 + entry, y1 + entry),
                 u32(glowC, alpha * cell / i), rnd + entry)
    end
  end

  -- AE highlight glow rings (independent of the passive border glow)
  if aeC and aehl.glow then
    for i = 1, 2 do
      local entry = bt + i * 2
      drawList:AddRect(ImVec2(x0 - entry, y0 - entry), ImVec2(x1 + entry, y1 + entry),
                 u32(aeC, alpha * aeAmt / i), rnd + entry)
    end
  end

  if bt > 0 then
    drawList:AddRectFilled(ImVec2(x0 - bt, y0 - bt), ImVec2(x1 + bt, y1 + bt), u32(borderC, alpha), rnd)
  end
  drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.barBack, alpha), rnd)

  local fillC = hp_color(cfg, plate.dispHp)
  local lowPulse = 0
  if cfg.anim.lowHpPulse and plate.dispHp <= cfg.anim.lowHpThreshold then
    lowPulse = hz_pulse(timeNow, cfg.anim.lowHpSpeed, phase)
    fillC = anim.lerp_color(fillC, colors.lowHp, 0.35 + 0.45 * lowPulse)
  end
  if aeC and aehl.tintBar then
    fillC = anim.lerp_color(fillC, aeC, aeAmt * aehl.strength)
  end
  fill_styled(drawList, cfg, x0, y0, x0 + w * plate.dispHp, y1, fillC, alpha, timeNow)
  segment_ticks(drawList, cfg, x0, y0, x1, y1, alpha)

  if cfg.anim.damageFlash then
    local f = anim.fade(plate.flashAt, cfg.anim.flashDur, timeNow)
    if f > 0 then
      drawList:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), u32(colors.flash, alpha * f), rnd)
    end
  end

  if cfg.anim.sheen then sheen_sweep(drawList, cfg, x0, y0, x1, y1, alpha, timeNow, phase) end
  drawList:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), u32(borderC, alpha), rnd)
  if lowPulse > 0 then
    drawList:AddRect(ImVec2(x0 - 1, y0 - 1), ImVec2(x1 + 1, y1 + 1), u32(colors.lowHp, alpha * lowPulse), rnd)
  end

  -- per-side geometry cursors for stacking (resources/name/buffs/cast bar)
  ---@type PlateGeom
  local geom = {
    x0 = x0, x1 = x1, y0 = y0, y1 = y1, cy = cy,
    top    = y0 - bt,        -- grows upward
    bottom = y1 + bt + 1,    -- grows downward
    left   = x0 - bt,        -- grows leftward
    right  = x1 + bt,        -- grows rightward
  }

  -- thin mana / endurance bars directly under the HP bar
  local RH = cfg.resources.height
  local function res_bar(pct, resC)
    local ry = geom.bottom
    drawList:AddRectFilled(ImVec2(x0, ry), ImVec2(x1, ry + RH), u32(colors.resourceBack, alpha), rnd * 0.5)
    drawList:AddRectFilled(ImVec2(x0, ry), ImVec2(x0 + w * anim.clamp01(pct), ry + RH),
                     u32(resC, alpha), rnd * 0.5)
    drawList:AddRect(ImVec2(x0, ry), ImVec2(x1, ry + RH), u32(borderC, alpha * 0.8), rnd * 0.5)
    geom.bottom = ry + RH + 1
  end
  if plate.mana then res_bar(plate.mana, colors.manaFill) end
  if plate.endu then res_bar(plate.endu, colors.enduFill) end

  -- HP % text, positionable
  if cfg.hp.showPct then
    local str = string.format('%d%%', math.floor(plate.dispHp * 100 + 0.5))
    local ts  = cfg.hp.textSize
    local HT  = types.HpTextPos
    local hpPos = cfg.hp.textPos
    local tw = text_width(str, ts)
    local tx, ty
    if hpPos == HT.IN_LEFT then
      tx, ty = x0 + 2, cy - text_height(ts) * 0.5
    elseif hpPos == HT.IN_CENTER then
      tx, ty = cx - tw * 0.5, cy - text_height(ts) * 0.5
    elseif hpPos == HT.IN_RIGHT then
      tx, ty = x1 - tw - 2, cy - text_height(ts) * 0.5
    elseif hpPos == HT.ABOVE then
      ty = geom.top - text_height(ts) - 1
      tx = cx - tw * 0.5
      geom.top = ty
    else -- BELOW
      tx, ty = cx - tw * 0.5, geom.bottom
      geom.bottom = geom.bottom + text_height(ts) + 1
    end
    if hpPos == HT.ABOVE or hpPos == HT.BELOW then
      geom.left  = math.min(geom.left, tx)
      geom.right = math.max(geom.right, tx + tw)
    end
    text(drawList, tx, ty, colors.hpText, alpha, str, ts)
  end

  -- name: anonymization, offsets, background, shadow, passive animation
  local pos = cfg.name.show and cfg.name.position or NP.HIDDEN
  if pos ~= NP.HIDDEN then
    local label = display_name(cfg, plate)
    local nameC = colors.name
    local nameA = alpha
    if cfg.name.anim == NA.BREATHE then
      nameA = alpha * (1 - 0.35 * hz_pulse(timeNow, cfg.name.animSpeed * 0.5, phase))
    elseif cfg.name.anim == NA.RAINBOW then
      nameC = hsv_color(((timeNow * cfg.name.animSpeed * 0.15) + phase) % 1, 0.75, 1, colors.name[4])
    end
    local ts = (pos == NP.INSIDE) and math.min(cfg.name.size, h + 4) or cfg.name.size
    local tw2, th2 = text_width(label, ts), text_height(ts)
    local tx = cx - tw2 * 0.5 + cfg.name.offsetX
    local ty
    if pos == NP.ABOVE then
      ty = geom.top - th2 - 1 + cfg.name.offsetY
      geom.top = math.min(geom.top, ty)
    elseif pos == NP.BELOW then
      ty = geom.bottom + cfg.name.offsetY
      geom.bottom = math.max(geom.bottom, ty + th2 + 1)
    else -- INSIDE
      ty = cy - th2 * 0.5 + cfg.name.offsetY
    end
    if cfg.name.background then
      local pad = cfg.name.bgPadding
      drawList:AddRectFilled(ImVec2(tx - pad, ty - pad), ImVec2(tx + tw2 + pad, ty + th2 + pad),
                       u32(colors.nameBg, nameA), 2)
    end
    local bgPad = cfg.name.background and cfg.name.bgPadding or 0
    geom.left  = math.min(geom.left, tx - bgPad)
    geom.right = math.max(geom.right, tx + tw2 + bgPad)
    draw_name_text(drawList, cfg, colors, label, tx, ty, ts, nameC, nameA, timeNow, phase)
  end

  draw_buffs(drawList, cfg, plate, geom, alpha, isTarget, timeNow)

  if castInfo and cfg.castbar.show then
    cast_bar(drawList, cfg, castInfo, cx, geom, w, alpha, timeNow, phase)
  end

  -- actual drawn footprint, relative to the projected anchor - init.lua uses
  -- it next frame to occlude/clip the plate against native EQ window rects
  plate.ext = { geom.left - cx, geom.top - baseY, geom.right - cx, geom.bottom - baseY }
end

return R
