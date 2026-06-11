--[[
  lib/uirects.lua - native EQ UI window rects, shared by eqgfx features.

  Primary source: eqgfx.get_ui_rects() (compiled walk of CXWndManager -
  visible, top-level, non-minimized windows only). Fullscreen-sized layers
  are filtered out here. When the native path is unavailable, get() reports
  native=false and callers fall back to their own Window-TLO scans.

  regions() subtracts the window rects from the screen, returning the list
  of still-visible screen rectangles - used to clip world drawings (AE
  indicators) so they appear UNDER the native UI.
]]

local eqgfx = require('eqgfx')

---@class UiRects
---@field rects number[][]   filtered {x0,y0,x1,y1} per visible window
---@field native boolean|nil nil until first fetch
---@field proven boolean     native has produced rects at least once
local M = { rects = {}, native = nil, proven = false }

-- Candidate names: the client window dump plus any user extras. Pushed to
-- the DLL once (and re-pushed when extras change).
local baseNames = require('eqgfx.lib.ui_windows')
local extraNames = {}
local pushed = false

local function push_names()
  local all = {}
  for _, n in ipairs(baseNames) do all[#all + 1] = n end
  for _, n in ipairs(extraNames) do all[#all + 1] = n end
  eqgfx.set_ui_names(all)
  pushed = true
end

function M.add_names(list)
  for _, n in ipairs(list or {}) do extraNames[#extraNames + 1] = n end
  pushed = false
end

-- CXWnd::GetScreenRect reports EQ UI-CANVAS coordinates; our plate math is
-- in render pixels. With UI scaling active the two diverge, so calibrate
-- once from EQMainWnd (full UI canvas) vs the render resolution.
local scaleX, scaleY = 1, 1
local calibrated = false

local function calibrate()
  calibrated = true
  pcall(function()
    local mq = require('mq')
    local main = mq.TLO.Window('EQMainWnd')
    local mw, mh = main.Width(), main.Height()
    local sw, sh = eqgfx.get_screen()
    if mw and mw > 0 and mh and mh > 0 and sw and sw > 0 and sh and sh > 0 then
      if math.abs(sw - mw) > 2 or math.abs(sh - mh) > 2 then
        scaleX, scaleY = sw / mw, sh / mh
      end
    end
  end)
end

-- Fetch every call - no clocks, no caching. The native path is one FFI call.
---@return table rects, boolean native
function M.get()
  if not pushed and eqgfx.ui_native then push_names() end
  local raw = eqgfx.get_ui_rects()
  if not raw then
    M.native = false
    M.rects = {}
    return M.rects, false
  end
  M.native = true
  if #raw > 0 then
    M.proven = true
    if not calibrated then calibrate() end
    if scaleX ~= 1 or scaleY ~= 1 then
      for _, rect in ipairs(raw) do
        rect[1], rect[2] = rect[1] * scaleX, rect[2] * scaleY
        rect[3], rect[4] = rect[3] * scaleX, rect[4] * scaleY
      end
    end
  end
  local sw, sh = eqgfx.get_screen()
  local area = (sw and sw > 0 and sh and sh > 0) and sw * sh or nil
  local out = {}
  for _, rect in ipairs(raw) do
    local width, height = rect[3] - rect[1], rect[4] - rect[2]
    local sane = width > 0 and height > 0
      and (not sw or (rect[1] > -200 and rect[2] > -200 and rect[3] < sw + 200 and rect[4] < sh + 200))
    if sane and (not area or width * height < area * 0.6) then
      out[#out + 1] = rect
    end
  end
  M.rects = out
  return out, true
end

-- Screen minus windows -> list of visible rectangles (capped).
function M.regions(rects, sw, sh, cap)
  cap = cap or 24
  local regs = { { 0, 0, sw, sh } }
  for _, winRect in ipairs(rects) do
    local nxt = {}
    for _, rect in ipairs(regs) do
      if winRect[1] >= rect[3] or winRect[3] <= rect[1] or winRect[2] >= rect[4] or winRect[4] <= rect[2] then
        nxt[#nxt + 1] = rect
      else
        local iy0, iy1 = math.max(rect[2], winRect[2]), math.min(rect[4], winRect[4])
        if rect[2] < iy0 then nxt[#nxt + 1] = { rect[1], rect[2], rect[3], iy0 } end
        if iy1 < rect[4] then nxt[#nxt + 1] = { rect[1], iy1, rect[3], rect[4] } end
        local ix0, ix1 = math.max(rect[1], winRect[1]), math.min(rect[3], winRect[3])
        if rect[1] < ix0 then nxt[#nxt + 1] = { rect[1], iy0, ix0, iy1 } end
        if ix1 < rect[3] then nxt[#nxt + 1] = { ix1, iy0, rect[3], iy1 } end
      end
    end
    regs = nxt
    if #regs > cap then return regs end
  end
  return regs
end

return M
