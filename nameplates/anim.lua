--[[
  nameplates/anim.lua - small pure animation helpers (no mq/ImGui deps).
]]

local A = {}

function A.clamp01(t)
  if t < 0 then return 0 elseif t > 1 then return 1 end
  return t
end

function A.lerp(a, b, t) return a + (b - a) * t end

-- Exponential approach: move cur toward target at `speed` per second.
function A.approach(cur, target, speed, dt)
  return cur + (target - cur) * math.min(1, dt * speed)
end

function A.smoothstep(t)
  t = A.clamp01(t)
  return t * t * (3 - 2 * t)
end

-- Overshooting ease for the appear "pop" (settles at 1).
function A.ease_out_back(t)
  t = A.clamp01(t)
  local c1, c3 = 1.70158, 2.70158
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

-- 1 -> 0 sawtooth over dur (for flashes / fades); nil-safe.
function A.fade(startedAt, dur, now)
  if not startedAt or dur <= 0 then return 0 end
  return 1 - A.clamp01((now - startedAt) / dur)
end

-- Gentle 0..1 sine pulse.
function A.pulse(now, period)
  return 0.5 + 0.5 * math.sin(now * (2 * math.pi) / (period or 0.4))
end

-- Lerp two {r,g,b,a} float colors into a new table.
function A.lerp_color(c1, c2, t)
  return { A.lerp(c1[1], c2[1], t), A.lerp(c1[2], c2[2], t),
           A.lerp(c1[3], c2[3], t), A.lerp(c1[4], c2[4], t) }
end

return A
