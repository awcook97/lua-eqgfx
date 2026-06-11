--[[
  nameplates/anim.lua - small pure animation helpers (no mq/ImGui deps).
]]

local A = {}

--- Clamp a number into [0, 1].
---@param t number
---@return number clamped
function A.clamp01(t)
  if t < 0 then return 0 elseif t > 1 then return 1 end
  return t
end

--- Linear interpolation between a and b.
---@param a number # value at t = 0
---@param b number # value at t = 1
---@param t number # blend factor (not clamped)
---@return number
function A.lerp(a, b, t) return a + (b - a) * t end

--- Exponential approach: move cur toward target at `speed` per second.
--- Frame-rate independent enough for UI; great for smoothed HP bars.
---
--- ```lua
--- plate.dispHp = anim.approach(plate.dispHp, hp, cfg.anim.hpSpeed, dt)
--- ```
---@param cur number # current value
---@param target number # value to move toward
---@param speed number # approach rate per second (higher = snappier)
---@param dt number # seconds since the last update
---@return number next # the moved value
function A.approach(cur, target, speed, dt)
  return cur + (target - cur) * math.min(1, dt * speed)
end

--- Hermite ease-in-out of a 0..1 input (clamped).
---@param t number
---@return number eased
function A.smoothstep(t)
  t = A.clamp01(t)
  return t * t * (3 - 2 * t)
end

--- Overshooting ease for the appear "pop": rises past 1 then settles at 1.
---@param t number # progress 0..1 (clamped)
---@return number scale # ~0..1.1..1
function A.ease_out_back(t)
  t = A.clamp01(t)
  local c1, c3 = 1.70158, 2.70158
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

--- 1 -> 0 sawtooth over dur (flashes / fade-outs); nil-safe.
---
--- ```lua
--- local f = anim.fade(plate.flashAt, cfg.anim.flashDur, timeNow)
--- if f > 0 then draw_flash(alpha * f) end
--- ```
---@param startedAt number|nil # when the event began (nil = no event -> 0)
---@param dur number # fade duration in the caller's timebase
---@param timeNow number # current time, same timebase as startedAt
---@return number f # 1 at start -> 0 at startedAt+dur (0 when expired/nil)
function A.fade(startedAt, dur, timeNow)
  if not startedAt or dur <= 0 then return 0 end
  return 1 - A.clamp01((timeNow - startedAt) / dur)
end

--- Gentle 0..1 sine pulse.
---@param timeNow number
---@param period number|nil # seconds per cycle (default 0.4)
---@return number pulse # 0..1
function A.pulse(timeNow, period)
  return 0.5 + 0.5 * math.sin(timeNow * (2 * math.pi) / (period or 0.4))
end

--- Lerp two {r,g,b,a} float colors into a NEW table (inputs untouched).
---
--- ```lua
--- fillC = anim.lerp_color(fillC, colors.lowHp, 0.5)
--- ```
---@param c1 number[] # {r,g,b,a} floats 0..1, at t = 0
---@param c2 number[] # {r,g,b,a} floats 0..1, at t = 1
---@param t number # blend factor
---@return number[] color # new {r,g,b,a}
function A.lerp_color(c1, c2, t)
  return { A.lerp(c1[1], c2[1], t), A.lerp(c1[2], c2[2], t),
           A.lerp(c1[3], c2[3], t), A.lerp(c1[4], c2[4], t) }
end

return A
