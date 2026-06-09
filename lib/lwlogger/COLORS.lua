---@module 'lwlogger.COLORS'

-- Code	Color	Code	Dark Variant
-- \ab	Black	    \a-b	Black (dark)
-- \ag	Green	    \a-g	Green (dark)
-- \am	Magenta	    \a-m	Magenta (dark)
-- \ao	Orange	    \a-o	Orange (dark)
-- \ap	Purple	    \a-p	Purple (dark)
-- \ar	Red	        \a-r	Red (dark)
-- \at	Cyan	    \a-t	Cyan (dark)
-- \au	Blue	    \a-u	Blue (dark)
-- \aw	White	    \a-w	White (dark)
-- \ay	Yellow	    \a-y	Yellow (dark)
-- \ax	Previous color		(Default if none)

---@class lw-color
---@field COLORS table # Create all of the proper types for this class
local color = {}

--- if logger.ColoredVars == true, then when the user does something like:
---
---       logger.Info("Casting: %s", something)
---       
--- the output string will look something like:
--- 
---       [\agMy App\ax][\ayMy Module\ax][\atInfo\ax][\aw12:34:56\ax] Casting: \apSome Spell\ax
--- 
--- This gets interpreted in the MQ console with colors
---@vararg string # The string as well as each of the variables
---@return string # Colored string
function color.ColoredVars(...) 
    local output = ""
    return output
end

function color.ColoredModule(...) end

function color.ColoredFunction(...) end

function color.SetColorRules(...) end