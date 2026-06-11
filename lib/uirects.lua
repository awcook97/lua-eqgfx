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
-- the DLL once (and re-pushed when extras change). The pushed ORDER is kept:
-- each scanned rect carries its 1-based index into this list (rect.idx).
local baseNames = require('eqgfx.lib.ui_windows')
local extraNames = {}
local pushedNames = {}
local pushed = false

local function push_names()
  local all, seen = {}, {}
  local function add(n)
    if n and n ~= '' and not seen[n] then
      seen[n] = true
      all[#all + 1] = n
    end
  end
  for _, n in ipairs(baseNames) do add(n) end
  for _, n in ipairs(extraNames) do add(n) end
  eqgfx.set_ui_names(all)
  pushedNames = all
  pushed = true
end

function M.add_names(list)
  for _, n in ipairs(list or {}) do extraNames[#extraNames + 1] = n end
  pushed = false
end

-- Diagnostics snapshot of the last get() (printed by /npdebug).
---@class UiRectsDebug
---@field raw integer    rects from the DLL sweep
---@field kept integer   rects after clamping/filtering
---@field sw number|nil  render resolution
---@field sh number|nil
---@field firstRaw number[]|nil   first raw rect from the sweep, untouched
---@field firstKept table|nil     first kept rect (clamped, with .name)
M.debug = { raw = 0, kept = 0 }

-- Fetch every call - no clocks, no caching. The native path is one FFI call.
--
-- COORDINATE SPACE: CXWnd::GetScreenRect returns RENDER PIXELS directly -
-- verified in-game (rect 1745,90..1825,200 inside a 1920x1023 screen). Two
-- earlier "calibration" attempts both corrupted good data by scaling against
-- EQMainWnd, which is NOT the fullscreen canvas on this client - it's the
-- small EQ-button window (52x94 at the bottom-left). So: identity transform,
-- clamp to the screen (a half-off-screen window still occludes its visible
-- part), drop only empty leftovers and near-fullscreen HUD layers.
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
  if #raw > 0 then M.proven = true end

  local sw, sh = eqgfx.get_screen()
  local haveScreen = (sw and sw > 0 and sh and sh > 0) and true or false

  local out = {}
  for _, rect in ipairs(raw) do
    local x0, y0, x1, y1 = rect[1], rect[2], rect[3], rect[4]
    if haveScreen then
      if x0 < 0 then x0 = 0 end
      if y0 < 0 then y0 = 0 end
      if x1 > sw then x1 = sw end
      if y1 > sh then y1 = sh end
    end
    -- near-fullscreen layers never occlude (canvas/HUD-style windows)
    local full = haveScreen and (x1 - x0) * (y1 - y0) >= sw * sh * 0.9
    if x1 > x0 and y1 > y0 and not full then
      out[#out + 1] = { x0, y0, x1, y1, name = rect.idx and pushedNames[rect.idx] or nil }
    end
  end

  M.debug.raw, M.debug.kept = #raw, #out
  M.debug.sw, M.debug.sh = sw, sh
  M.debug.firstRaw = raw[1]
  M.debug.firstKept = out[1]

  M.rects = out
  return out, true
end

-- Subtract window rects from one seed rect -> the visible sub-rectangles
-- (capped). Used per plate by nameplates to clip drawing around EQ windows.
function M.subtract(seed, rects, cap)
  cap = cap or 24
  local regs = { { seed[1], seed[2], seed[3], seed[4] } }
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

-- Screen minus windows -> list of visible rectangles (capped).
function M.regions(rects, sw, sh, cap)
  return M.subtract({ 0, 0, sw, sh }, rects, cap)
end

return M
