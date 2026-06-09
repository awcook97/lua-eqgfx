---@module 'lwlogger.COLORS'
---
--- MQ console color codes + the color scheme lwlogger paints with.
---
--- An MQ color code is the BELL char (`\a`, 0x07) followed by a letter; a leading
--- `-` selects the dark variant. `\ax` restores the previous color. (In Lua the
--- escape `\a` *is* 0x07, so `'\ag'` is literally what MQ scans for.)
---
--- Code  Color        Code   Dark Variant
--- \ab   Black        \a-b   Black (dark)
--- \ag   Green        \a-g   Green (dark)
--- \am   Magenta      \a-m   Magenta (dark)
--- \ao   Orange       \a-o   Orange (dark)
--- \ap   Purple       \a-p   Purple (dark)
--- \ar   Red          \a-r   Red (dark)
--- \at   Cyan         \a-t   Cyan (dark)
--- \au   Blue         \a-u   Blue (dark)
--- \aw   White        \a-w   White (dark)
--- \ay   Yellow       \a-y   Yellow (dark)
--- \ax   Previous color (default if none)

--- Friendly color names accepted anywhere a color is wanted.
---@alias lwlogger.ColorName
---| '"black"'
---| '"green"'
---| '"magenta"'
---| '"orange"'
---| '"purple"'
---| '"red"'
---| '"cyan"'
---| '"blue"'
---| '"white"'
---| '"yellow"'
---| '"reset"'

--- Raw MQ code letters (bright variants) and the reset code.
---@alias lwlogger.ColorCode
---| '"b"' # black
---| '"g"' # green
---| '"m"' # magenta
---| '"o"' # orange
---| '"p"' # purple
---| '"r"' # red
---| '"t"' # cyan
---| '"u"' # blue
---| '"w"' # white
---| '"y"' # yellow
---| '"x"' # previous/reset

--- Dark ('-' prefixed) variants of the raw code letters.
---@alias lwlogger.DarkColorCode
---| '"-b"' # black (dark)
---| '"-g"' # green (dark)
---| '"-m"' # magenta (dark)
---| '"-o"' # orange (dark)
---| '"-p"' # purple (dark)
---| '"-r"' # red (dark)
---| '"-t"' # cyan (dark)
---| '"-u"' # blue (dark)
---| '"-w"' # white (dark)
---| '"-y"' # yellow (dark)

--- Any value `color.wrap` understands: a friendly name, a raw code, or a dark code.
---@alias lwlogger.Color
---| lwlogger.ColorName
---| lwlogger.ColorCode
---| lwlogger.DarkColorCode

--- A piece of a log line that `SCHEME` assigns a color to.
---@alias lwlogger.Role
---| '"app"'       # the application name segment
---| '"module"'    # the module name segment
---| '"time"'      # the timestamp segment
---| '"character"' # the character segment
---| '"source"'    # the caller file:line segment
---| '"var"'       # substituted message variables
---| '"trace"'     # TRACE level label
---| '"debug"'     # DEBUG level label
---| '"info"'      # INFO level label
---| '"warn"'      # WARN level label
---| '"error"'     # ERROR level label
---| '"fatal"'     # FATAL level label

---@class lwlogger.colors
---@field CODES       table<lwlogger.ColorName, lwlogger.ColorCode> # friendly name -> code letter
---@field SCHEME      table<lwlogger.Role, lwlogger.Color>          # role -> the color it's drawn in
---@field VAR_PALETTE lwlogger.Color[]                              # colors cycled for multicolored vars
local color = {}

local ESC   = '\a'          -- 0x07, the byte MQ scans for
local RESET  = ESC .. 'x'   -- \ax — restore previous color

--- Friendly name -> MQ code letter. Pass either form to `color.wrap`.
color.CODES = {
  black = 'b', green = 'g', magenta = 'm', orange = 'o', purple = 'p',
  red   = 'r', cyan  = 't', blue    = 'u', white  = 'w', yellow = 'y',
  reset = 'x',
}

--- Which color each logger role is drawn in. Override via `color.SetColorRules`.
color.SCHEME = {
  app       = 'green',
  module    = 'yellow',
  time      = 'white',
  character = 'cyan',
  source    = '-w',     -- subtle grey for file:line
  var       = 'purple',
  -- one entry per log level:
  trace = '-w', debug = 'u', info = 'g', warn = 'y', error = 'r', fatal = 'm',
}

--- Colors cycled through when MulticoloredVariables is on.
color.VAR_PALETTE = { 'p', 't', 'y', 'o', 'u', 'm', 'g' }

--- Wrap `text` in a color and restore the previous one afterwards.
--- `name` may be a CODES key ('green'), a raw code letter ('g'), or a dark
--- variant ('-g'). A nil/empty name returns the text untouched.
---@param name lwlogger.Color|nil
---@param text string
---@return string
function color.wrap(name, text)
  if not name or name == '' then return text end
  local code = color.CODES[name] or name        -- allow raw 'g' / '-g'
  return ESC .. code .. text .. RESET
end

--- Wrap text in the color assigned to a logger `role` (see SCHEME).
---@param role lwlogger.Role
---@param text string
---@return string
function color.ColoredRole(role, text)
  return color.wrap(color.SCHEME[role] or 'white', text)
end

-- Back-compat / convenience names from the original outline.
---@param name string
---@return string
function color.ColoredModule(name)   return color.ColoredRole('module', name) end
---@param name string
---@return string
function color.ColoredFunction(name) return color.wrap('cyan', name) end

--- Format `fmt` with the given args, coloring each substituted value.
---
--- With `logger.SetColors('Variables')` a call like
---     logger.Info("Casting: %s", spell)
--- renders (in the MQ console) as:
---     [App][Module][Info][12:34:56] Casting: <spell in purple>
--- With 'MulticoloredVariables', each successive value cycles VAR_PALETTE.
---@param multicolor boolean         # cycle VAR_PALETTE instead of one fixed color
---@param baseColor  lwlogger.Color   # color used when not multicolor
---@param fmt        string           # printf-style format string
---@param ...        any              # arguments substituted into `fmt`
---@return string
function color.ColoredVars(multicolor, baseColor, fmt, ...)
  local args = { ... }
  local n = 0
  local out = fmt:gsub('%%[%-%+ #0]*%d*%.?%d*[%a%%]', function(spec)
    if spec == '%%' then return '%' end        -- literal percent
    n = n + 1
    local ok, formatted = pcall(string.format, spec, args[n])
    if not ok then formatted = tostring(args[n]) end
    local c = baseColor
    if multicolor then
      c = color.VAR_PALETTE[(n - 1) % #color.VAR_PALETTE + 1]
    end
    return color.wrap(c, formatted)
  end)
  return out
end

--- Override one or more role colors, e.g. SetColorRules{ app='cyan', warn='o' }.
---@param rules table<lwlogger.Role, lwlogger.Color>
function color.SetColorRules(rules)
  for role, c in pairs(rules or {}) do color.SCHEME[role] = c end
end

--- Strip every MQ color code from a string (for plain-text file output).
---@param s string
---@return string
function color.strip(s)
  return (s:gsub('\a%-?.', ''))
end

return color
