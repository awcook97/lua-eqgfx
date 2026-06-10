--[[
  eqgfx/init.lua - entry shim.

  The FFI binding lives in core/init.lua; this keeps `require('eqgfx')`
  working for every feature script and external user.
]]

return require('eqgfx.core')
