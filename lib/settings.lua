--[[
  lib/settings.lua - scoped, persisted settings shared by eqgfx features.

  Files live under  <config>/eqgfx/ :
      global_settings.lua                 all servers, all characters
      <Server>_settings.lua               every character on one server
      <Server>_<Name>_settings.lua        one character

  Each file is a plain `return { <section> = {...}, ... }` table; features
  store their settings under their own section key (nameplates, indicators),
  so all features share the same three files.

  Scope ("save for: character / server / global") is implicit in WHERE the
  section is found: load checks character -> server -> global and saving
  writes back to that level. Picking a broader scope in a menu removes the
  section from the more specific files so the broader one takes effect.

  Reading uses loadfile (quiet when the file doesn't exist yet); writing uses
  our own stable serializer (sorted keys), since mq.pickle wants paths
  relative to the config dir and can't read-modify-write shared files.

  Usage:
    local Store = require('eqgfx.lib.settings')
    local settings = Store.new{ section = 'nameplates', defaults = DEFAULTS }
    settings.load()
    settings.data.foo = 42; settings.mark_dirty()
    settings.maybe_save(os.clock(), log)   -- debounced; call every loop tick
    settings.set_scope('server')           -- 'char' | 'server' | 'global'
]]

local mq = require('mq')

local M = {}

M.SCOPES = { 'char', 'server', 'global' }
M.SCOPE_LABELS = {
  char   = 'This character',
  server = 'This server',
  global = 'All characters',
}

local DIR = mq.configDir .. '/eqgfx'

local function sanitize(s)
  return tostring(s or 'unknown'):gsub('[^%w_%-]', '')
end

local function safe_tlo(fn)
  local okk, v = pcall(fn)
  if okk and v and v ~= '' and v ~= 'NULL' then return v end
  return nil
end

local function path_for(scope)
  if scope == 'global' then return DIR .. '/global_settings.lua' end
  local server = sanitize(safe_tlo(function() return mq.TLO.EverQuest.Server() end))
  if scope == 'server' then return DIR .. '/' .. server .. '_settings.lua' end
  local name = sanitize(safe_tlo(function() return mq.TLO.Me.CleanName() end))
  return DIR .. '/' .. server .. '_' .. name .. '_settings.lua'
end
M.path_for = path_for

local function ensure_dir()
  pcall(function() require('lfs').mkdir(DIR) end)
  -- belt and braces if lfs is unavailable: cmd-style mkdir (no-op if exists)
  if not io.open(DIR .. '/.exists', 'a') then
    pcall(os.execute, 'mkdir "' .. DIR:gsub('/', '\\') .. '"')
  else
    os.remove(DIR .. '/.exists')
  end
end

-- Read a settings file -> table, or nil (quietly) if missing/invalid.
local function read_file(path)
  local chunk = loadfile(path)
  if not chunk then return nil end
  local okk, t = pcall(chunk)
  if okk and type(t) == 'table' then return t end
  return nil
end
M.read_file = read_file

----------------------------------------------------------------------------
-- Stable serializer (plain tables: string/number/boolean, nested tables).
----------------------------------------------------------------------------
local function val_str(v)
  local tv = type(v)
  if tv == 'string' then return string.format('%q', v) end
  if tv == 'number' then
    if v == math.floor(v) and math.abs(v) < 2 ^ 31 then return string.format('%d', v) end
    return string.format('%.10g', v)
  end
  return tostring(v)   -- boolean
end

local function key_str(k)
  if type(k) == 'number' then return '[' .. string.format('%d', k) .. ']' end
  if k:match('^[%a_][%w_]*$') then return k end
  return '[' .. string.format('%q', k) .. ']'
end

local function serialize(t, ind, out)
  out[#out + 1] = '{\n'
  local pad = string.rep('  ', ind + 1)
  local nums, strs = {}, {}
  for k in pairs(t) do
    if type(k) == 'number' then nums[#nums + 1] = k
    elseif type(k) == 'string' then strs[#strs + 1] = k end
  end
  table.sort(nums); table.sort(strs)
  local function emit(k)
    local v = t[k]
    out[#out + 1] = pad .. key_str(k) .. ' = '
    if type(v) == 'table' then serialize(v, ind + 1, out)
    else out[#out + 1] = val_str(v) end
    out[#out + 1] = ',\n'
  end
  for _, k in ipairs(nums) do emit(k) end
  for _, k in ipairs(strs) do emit(k) end
  out[#out + 1] = string.rep('  ', ind) .. '}'
end

local function write_file(path, tbl)
  ensure_dir()
  local out = { '-- eqgfx settings (auto-generated; edit while scripts are stopped)\nreturn ' }
  serialize(tbl, 0, out)
  out[#out + 1] = '\n'
  local f, e = io.open(path, 'w')
  if not f then return false, e end
  f:write(table.concat(out))
  f:close()
  return true
end

-- Remove one section from a file; delete the file if it ends up empty.
local function remove_section(path, section)
  local whole = read_file(path)
  if not whole or whole[section] == nil then return end
  whole[section] = nil
  if next(whole) == nil then os.remove(path)
  else write_file(path, whole) end
end

-- Fill any keys missing from a loaded config with defaults (so new fields
-- appear on upgrade). Recurses into nested tables.
local function merge_defaults(dst, def)
  dst = (type(dst) == 'table') and dst or {}
  for k, v in pairs(def) do
    if type(v) == 'table' then
      dst[k] = merge_defaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end
M.merge_defaults = merge_defaults

----------------------------------------------------------------------------
-- Store instances (closure-based: callers use dot-call).
----------------------------------------------------------------------------

---@param opts { section: string, defaults: table, legacy: string|nil }
function M.new(opts)
  local self = {
    section  = assert(opts.section, 'settings store needs a section name'),
    defaults = assert(opts.defaults, 'settings store needs defaults'),
    legacy   = opts.legacy,     -- optional old single-file config to import
    data     = nil,
    scope    = 'char',
  }
  local dirty, lastSave = false, 0

  function self.load()
    local found, level
    for _, sc in ipairs(M.SCOPES) do
      local t = read_file(path_for(sc))
      if t and type(t[self.section]) == 'table' then
        found, level = t[self.section], sc
        break
      end
    end
    if not found and self.legacy then
      found = read_file(self.legacy)        -- one-time import of the old file
    end
    self.data  = merge_defaults(found or {}, self.defaults)
    self.scope = level or 'char'
    return self.data
  end

  function self.save(log)
    local target = path_for(self.scope)
    local whole = read_file(target) or {}
    whole[self.section] = self.data
    local okk, e = write_file(target, whole)
    if not okk and log then log.Warn('settings save failed (%s): %s', target, tostring(e)) end
    return okk
  end

  function self.mark_dirty() dirty = true end

  -- Debounced save; call every loop tick.
  function self.maybe_save(now, log)
    if dirty and now - lastSave > 1.0 then
      self.save(log)
      dirty, lastSave = false, now
    end
  end

  -- Change save scope. Removes this section from files more specific than
  -- the new scope (so the new file actually takes effect) and saves now.
  function self.set_scope(scope, log)
    if scope == self.scope then return end
    self.scope = scope
    for _, sc in ipairs(M.SCOPES) do
      if sc == scope then break end
      remove_section(path_for(sc), self.section)
    end
    self.save(log)
    dirty = false
    if log then log.Info('settings scope -> %s (%s)', scope, path_for(scope)) end
  end

  return self
end

return M
