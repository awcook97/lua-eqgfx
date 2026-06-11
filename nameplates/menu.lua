--[[
  nameplates/menu.lua - the in-game customization window (/npmenu).

  Every widget writes straight into settings.data and marks it dirty; the main
  loop debounce-saves to mq.configDir/eqgfx_nameplates.lua.
]]

local ImGui = require("ImGui")
local types = require("eqgfx.nameplates._types")
local settings = require("eqgfx.nameplates.settings")

local M = { open = false }

--- Show/hide the settings window (the /npmenu bind).
function M.toggle()
	M.open = not M.open
end

local filterInput, ovInput = "", ""

local function mark()
	settings.mark_dirty()
end

--- Checkbox bound to t[k]; marks the settings dirty on change.
---@param label string
---@param t table # settings subtable
---@param k string # key within t
local function check(label, t, k)
	local v, pressed = ImGui.Checkbox(label, t[k])
	if pressed then
		t[k] = v
		mark()
	end
end

--- Integer slider bound to t[k]; marks dirty on change.
---@param label string
---@param t table # settings subtable
---@param k string # key within t
---@param lo integer # slider minimum
---@param hi integer # slider maximum
local function slideri(label, t, k, lo, hi)
	local v, changed = ImGui.SliderInt(label, t[k], lo, hi)
	if changed then
		t[k] = v
		mark()
	end
end

--- Float slider bound to t[k]; marks dirty on change.
---@param label string
---@param t table # settings subtable
---@param k string # key within t
---@param lo number # slider minimum
---@param hi number # slider maximum
---@param fmt string|nil # printf display format (default "%.1f")
local function sliderf(label, t, k, lo, hi, fmt)
	local v, changed = ImGui.SliderFloat(label, t[k], lo, hi, fmt or "%.1f")
	if changed then
		t[k] = v
		mark()
	end
end

--- Keep colors as plain number tables (pickle-safe) regardless of what the
--- binding hands back (table vs ImVec4).
---@param colorVal table|any # ImGui ColorEdit4 result
---@return number[] color # plain {r,g,b,a}
local function to_color(colorVal)
	if type(colorVal) == "table" then
		return { colorVal[1], colorVal[2], colorVal[3], colorVal[4] }
	end
	return { colorVal.x, colorVal.y, colorVal.z, colorVal.w }
end

--- Color picker bound to t[k] ({r,g,b,a} floats); marks dirty on change.
---@param label string
---@param t table # settings subtable (usually cfg.colors)
---@param k string # key within t
local function color(label, t, k)
	local colorVal, changed = ImGui.ColorEdit4(label, t[k])
	if changed then
		t[k] = to_color(colorVal)
		mark()
	end
end

--- Combo box bound to t[k] (1-based index into items); marks dirty on change.
---@param label string
---@param t table # settings subtable
---@param k string # key within t
---@param items string[] # the labels (e.g. types.BarTextureLabels)
local function combo(label, t, k, items)
	local v, changed = ImGui.Combo(label, t[k], items, #items)
	if changed then
		t[k] = v
		mark()
	end
end

--- Inline remove-button list editor (whitelist/blacklist entries).
---@param tag string # unique widget id prefix
---@param list string[] # edited in place
local function list_editor(tag, list)
	for idx = #list, 1, -1 do
		if ImGui.SmallButton("x##" .. tag .. idx) then
			table.remove(list, idx)
			mark()
		else
			ImGui.SameLine()
			ImGui.Text(list[idx])
		end
	end
end

--- Render the settings window (call every frame from the ImGui callback;
--- no-op while closed). Widgets write straight into settings.data and the
--- main loop debounce-saves.
---@param caps RenderCaps # render capability flags (degraded-feature notes)
function M.draw(caps)
	if not M.open then
		return
	end
	local cfg = settings.data or {}
	local open, show = ImGui.Begin("EQGFX Nameplates", M.open)
	M.open = open
	if show then
		ImGui.Text("Save for:")
		ImGui.SameLine()
		if ImGui.RadioButton("This character", settings.scope == "char") then
			settings.set_scope("char")
		end
		ImGui.SameLine()
		if ImGui.RadioButton("This server", settings.scope == "server") then
			settings.set_scope("server")
		end
		ImGui.SameLine()
		if ImGui.RadioButton("All characters", settings.scope == "global") then
			settings.set_scope("global")
		end
		ImGui.Separator()
		check("Enabled", cfg, "enabled")
		slideri("Radius", cfg, "radius", 20, 500)
		check("Occlude plates behind EQ windows", cfg, "hideUnderUI")
		if cfg.hideUnderUI then
			combo("Behind-window style", cfg, "uiOccludeMode", types.UiOccludeModeLabels)
			if caps.clipRect == false then
				ImGui.TextDisabled("(clipping unavailable in this MQ build - hiding instead)")
			end
			ImGui.TextDisabled("(missing a window? /windows for names, /npui add <Name>)")
		end
		ImGui.Separator()
		check("Show NPCs", cfg.show, "npcs")
		check("Show PCs", cfg.show, "pcs")
		check("Show pets & mercs", cfg.show, "pets")
		check("Show yourself", cfg.show, "self")

		if ImGui.CollapsingHeader("Bar") then
			combo("Texture", cfg.bar, "texture", types.BarTextureLabels)
			slideri("Width", cfg.bar, "width", 20, 300)
			slideri("Height", cfg.bar, "height", 2, 40)
			sliderf("Rounding", cfg.bar, "rounding", 0.0, 12.0)
			sliderf("Height above head", cfg.bar, "zOffset", 0.0, 20.0)
			sliderf("Border thickness", cfg.bar, "borderThickness", 0.0, 4.0)
			sliderf("Opacity", cfg.bar, "opacity", 0.1, 1.0, "%.2f")
		end

		if ImGui.CollapsingHeader("Names") then
			check("Show names", cfg.name, "show")
			combo("Position", cfg.name, "position", types.NamePositionLabels)
			slideri("Offset X", cfg.name, "offsetX", -100, 100)
			slideri("Offset Y", cfg.name, "offsetY", -50, 50)
			if caps.sizedText ~= false then
				sliderf("Text size", cfg.name, "size", 8.0, 32.0, "%.0f px")
			else
				ImGui.TextDisabled("(text sizing unavailable in this MQ build)")
			end
			color("Name color", cfg.colors, "name")
			combo("PC anonymity", cfg.name, "anonMode", types.AnonModeLabels)
			check("Background", cfg.name, "background")
			if cfg.name.background then
				slideri("  Padding", cfg.name, "bgPadding", 0, 8)
				color("  Background color", cfg.colors, "nameBg")
			end
			check("Text shadow", cfg.name, "shadow")
			if cfg.name.shadow then
				color("  Shadow color", cfg.colors, "nameShadow")
			end
			combo("Name animation", cfg.name, "anim", types.NameAnimLabels)
			if cfg.name.anim ~= types.NameAnim.NONE then
				sliderf("  Animation speed", cfg.name, "animSpeed", 0.1, 4.0, "%.1f x")
				if cfg.name.anim >= types.NameAnim.RAINBOW_WAVE then
					sliderf("  Amplitude", cfg.name, "animAmount", 0.5, 8.0, "%.1f px")
				end
			end
		end

		if ImGui.CollapsingHeader("HP bar") then
			check("HP color gradient", cfg.hp, "gradient")
			if cfg.hp.gradient then
				color("Full HP", cfg.colors, "barHigh")
				color("Half HP", cfg.colors, "barMid")
				color("Low HP", cfg.colors, "barLow")
			else
				color("Bar color", cfg.colors, "barFixed")
			end
			check("Show HP %", cfg.hp, "showPct")
			if cfg.hp.showPct then
				combo("HP % position", cfg.hp, "textPos", types.HpTextPosLabels)
				sliderf("HP % size", cfg.hp, "textSize", 7.0, 24.0, "%.0f px")
				color("HP % text", cfg.colors, "hpText")
			end
		end

		if ImGui.CollapsingHeader("Mana / Endurance") then
			combo("Mana bar", cfg.resources, "manaScope", types.ResScopeLabels)
			combo("Endurance bar", cfg.resources, "enduScope", types.ResScopeLabels)
			slideri("Bar height##res", cfg.resources, "height", 2, 12)
			color("Mana color", cfg.colors, "manaFill")
			color("Endurance color", cfg.colors, "enduFill")
			color("Resource background", cfg.colors, "resourceBack")
			ImGui.TextDisabled("(others' mana/endurance only when the client knows it)")
		end

		if ImGui.CollapsingHeader("Cast bar") then
			check("Show cast bars", cfg.castbar, "show")
			check("Only on my target", cfg.castbar, "onlyTarget")
			slideri("Cast bar height", cfg.castbar, "height", 2, 30)
			sliderf("Cast bar width", cfg.castbar, "widthScale", 0.3, 2.0, "%.2f x")
			slideri("Gap below plate", cfg.castbar, "gap", 0, 20)
			check("Spell icon", cfg.castbar, "showIcon")
			if cfg.castbar.showIcon then
				slideri("  Icon size", cfg.castbar, "iconSize", 10, 40)
			end
			check("Show spell name", cfg.castbar, "showSpellName")
			check("Show time remaining", cfg.castbar, "showTime")
			if cfg.castbar.showTime then
				check("  Show total time too", cfg.castbar, "showTotal")
			end
			sliderf("Cast text size", cfg.castbar, "textSize", 8.0, 24.0, "%.0f px")
			check("Detect interrupts", cfg.castbar, "interruptDetect")
			color("Cast fill", cfg.colors, "castFill")
			color("Cast background", cfg.colors, "castBack")
			color("Cast text", cfg.colors, "castText")
			color("Interrupt color", cfg.colors, "castInterrupt")
		end

		if ImGui.CollapsingHeader("Buffs") then
			check("Show buffs", cfg.buffs, "enabled")
			ImGui.TextDisabled("(cached buffs: a spawn must have been targeted once)")
			check("Only on my target##buffs", cfg.buffs, "onlyTarget")
			check("Hover tooltip", cfg.buffs, "tooltip")
			check("Right-click inspect", cfg.buffs, "rightClickInspect")
			check("Flash new buffs", cfg.buffs, "appearFlash")
			check("Pulse detrimental borders", cfg.buffs, "detPulse")
			check("Combine beneficial + detrimental", cfg.buffs, "combine")
			slideri("Icon size##buffs", cfg.buffs, "iconSize", 8, 40)
			slideri("Icon spacing", cfg.buffs, "spacing", 0, 8)
			slideri("Wrap after N icons", cfg.buffs, "maxPerRow", 1, 30)
			slideri("Max icons total", cfg.buffs, "maxIcons", 1, 60)
			ImGui.Text("Beneficial")
			combo("Position##ben", cfg.buffs.beneficial, "position", types.BuffPositionLabels)
			combo("Stacking##ben", cfg.buffs.beneficial, "direction", types.BuffDirectionLabels)
			if not cfg.buffs.combine then
				ImGui.Text("Detrimental")
				combo("Position##det", cfg.buffs.detrimental, "position", types.BuffPositionLabels)
				combo("Stacking##det", cfg.buffs.detrimental, "direction", types.BuffDirectionLabels)
			end

			ImGui.Separator()
			ImGui.Text("Filters")
			check("Only my casts", cfg.buffs, "mineOnly")
			combo("Filter mode", cfg.buffs, "filterMode", types.BuffFilterLabels)
			filterInput = select(1, ImGui.InputText("Spell name##filter", filterInput))
			if ImGui.Button("+ Whitelist") and filterInput ~= "" then
				table.insert(cfg.buffs.whitelist, filterInput)
				filterInput = ""
				mark()
			end
			ImGui.SameLine()
			if ImGui.Button("+ Blacklist") and filterInput ~= "" then
				table.insert(cfg.buffs.blacklist, filterInput)
				filterInput = ""
				mark()
			end
			if #cfg.buffs.whitelist > 0 and ImGui.TreeNode("Whitelist (" .. #cfg.buffs.whitelist .. ")") then
				list_editor("wl", cfg.buffs.whitelist)
				ImGui.TreePop()
			end
			if #cfg.buffs.blacklist > 0 and ImGui.TreeNode("Blacklist (" .. #cfg.buffs.blacklist .. ")") then
				list_editor("bl", cfg.buffs.blacklist)
				ImGui.TreePop()
			end

			ImGui.Separator()
			ImGui.Text("My casts vs others")
			check("Colored borders", cfg.buffs, "borders")
			if cfg.buffs.borders then
				combo("Border colors", cfg.buffs, "borderMode", types.BuffBorderLabels)
				if cfg.buffs.borderMode == types.BuffBorderMode.BY_CASTER then
					color("My border", cfg.buffs, "mineBorder")
					color("Others border", cfg.buffs, "otherBorder")
				end
			end
			sliderf("Dim others", cfg.buffs, "dimOthers", 0.0, 0.8, "%.2f")

			ImGui.Separator()
			ImGui.Text("Per-buff overrides")
			ovInput = select(1, ImGui.InputText("Spell name##override", ovInput))
			if ImGui.Button("+ Add override") and ovInput ~= "" then
				cfg.buffs.overrides[ovInput:lower()] = { scale = 1.0, priority = 0, hide = false }
				ovInput = ""
				mark()
			end
			local keys = {}
			for k in pairs(cfg.buffs.overrides) do
				keys[#keys + 1] = k
			end
			table.sort(keys)
			for _, k in ipairs(keys) do
				local override = cfg.buffs.overrides[k]
				if ImGui.TreeNode(k) then
					local v, ch = ImGui.SliderFloat("Size##" .. k, override.scale or 1, 0.5, 3.0, "%.2f x")
					if ch then
						override.scale = v
						mark()
					end
					local pv, pch = ImGui.SliderInt("Priority##" .. k, override.priority or 0, -10, 10)
					if pch then
						override.priority = pv
						mark()
					end
					local hv, hch = ImGui.Checkbox("Hide##" .. k, override.hide or false)
					if hch then
						override.hide = hv
						mark()
					end
					if ImGui.Button("Remove##" .. k) then
						cfg.buffs.overrides[k] = nil
						mark()
					end
					ImGui.TreePop()
				end
			end
		end

		if ImGui.CollapsingHeader("Target") then
			check("Distinguish my target", cfg.target, "distinguish")
			if cfg.target.distinguish then
				sliderf("Target scale", cfg.target, "scale", 1.0, 2.5, "%.2f x")
				check("Custom border", cfg.target, "border")
				if cfg.target.border then
					color("Target border color", cfg.target, "borderColor")
					sliderf("Target border thickness", cfg.target, "borderThickness", 0.5, 6.0)
				end
				check("Glow on target", cfg.target, "glow")
			end
		end

		if ImGui.CollapsingHeader("AE cast highlight") then
			check("Highlight plates AE casts will affect", cfg.aehl, "enabled")
			if cfg.aehl.enabled then
				ImGui.Text("Watch casts from")
				check("My casts", cfg.aehl, "fromMe")
				check("Other players (and pets/mercs)", cfg.aehl, "fromPCs")
				check("NPCs (their AEs mark PC plates)", cfg.aehl, "fromNPCs")
				ImGui.Separator()
				color("Will harm (detrimental)", cfg.colors, "aeDet")
				color("Will help (beneficial)", cfg.colors, "aeBen")
				check("Tint HP bar", cfg.aehl, "tintBar")
				if cfg.aehl.tintBar then
					sliderf("  Tint strength", cfg.aehl, "strength", 0.1, 1.0, "%.2f")
				end
				check("Tint border", cfg.aehl, "tintBorder")
				check("Glow rings", cfg.aehl, "glow")
				check("Pulse", cfg.aehl, "pulse")
				if cfg.aehl.pulse then
					sliderf("  Pulse rate", cfg.aehl, "pulseSpeed", 0.2, 4.0, "%.1f Hz")
					sliderf("  Pulse depth", cfg.aehl, "pulseAmount", 0.05, 0.9, "%.2f")
				end
				sliderf("Fade in/out speed", cfg.aehl, "fadeSpeed", 1.0, 30.0, "%.1f")
				ImGui.Separator()
				ImGui.Text("Stacking (overlapping AEs deepen the color)")
				sliderf("One AE", cfg.aehl, "stackBase", 0.1, 1.0, "%.2f")
				sliderf("Each extra AE", cfg.aehl, "stackStep", 0.0, 0.3, "%.2f")
				slideri("Count cap", cfg.aehl, "stackMax", 1, 10)
				ImGui.TextDisabled("(detrimental AEs mark the caster's enemies; beneficial")
				ImGui.TextDisabled(" mark its allies - NPC AEs never mark other NPCs)")
			end
		end

		if ImGui.CollapsingHeader("Animations") then
			ImGui.Text("Passive (always running)")
			check("Sheen sweep", cfg.anim, "sheen")
			if cfg.anim.sheen then
				sliderf("  Sweep every", cfg.anim, "sheenPeriod", 0.5, 10.0, "%.1f s")
			end
			check("Scroll stripes (Stripes texture)", cfg.anim, "stripeScroll")
			if cfg.anim.stripeScroll then
				sliderf("  Scroll speed", cfg.anim, "stripeSpeed", 5.0, 120.0, "%.0f px/s")
			end
			check("Low-HP heartbeat", cfg.anim, "lowHpPulse")
			if cfg.anim.lowHpPulse then
				sliderf("  Below HP", cfg.anim, "lowHpThreshold", 0.05, 0.9, "%.2f")
				sliderf("  Beat rate", cfg.anim, "lowHpSpeed", 0.3, 5.0, "%.1f Hz")
				color("  Heartbeat color", cfg.colors, "lowHp")
			end
			check("Breathe (alpha pulse)", cfg.anim, "breathe")
			if cfg.anim.breathe then
				sliderf("  Breathe amount", cfg.anim, "breatheAmount", 0.05, 0.6, "%.2f")
				sliderf("  Breathe rate", cfg.anim, "breatheSpeed", 0.1, 2.0, "%.1f Hz")
			end
			check("Border glow", cfg.anim, "borderGlow")
			if cfg.anim.borderGlow then
				sliderf("  Glow rate", cfg.anim, "glowSpeed", 0.1, 4.0, "%.1f Hz")
				color("  Glow color", cfg.colors, "glow")
			end
			check("Idle bob", cfg.anim, "bob")
			if cfg.anim.bob then
				sliderf("  Bob amount", cfg.anim, "bobAmount", 0.5, 8.0, "%.1f px")
				sliderf("  Bob rate", cfg.anim, "bobSpeed", 0.1, 2.0, "%.1f Hz")
			end
			ImGui.Separator()
			ImGui.Text("Event-driven")
			check("Smooth HP changes", cfg.anim, "hpSmoothing")
			if cfg.anim.hpSmoothing then
				sliderf("  HP speed", cfg.anim, "hpSpeed", 1.0, 30.0)
			end
			check("Fade in on appear", cfg.anim, "fadeIn")
			if cfg.anim.fadeIn then
				sliderf("  Fade in time", cfg.anim, "fadeInDur", 0.05, 2.0, "%.2f s")
			end
			check("Fade out on leave", cfg.anim, "fadeOut")
			if cfg.anim.fadeOut then
				sliderf("  Fade out time", cfg.anim, "fadeOutDur", 0.05, 2.0, "%.2f s")
			end
			check("Damage flash", cfg.anim, "damageFlash")
			if cfg.anim.damageFlash then
				sliderf("  Flash threshold", cfg.anim, "flashThreshold", 0.01, 0.5, "%.2f")
				sliderf("  Flash time", cfg.anim, "flashDur", 0.05, 1.0, "%.2f s")
				color("  Flash color", cfg.colors, "flash")
			end
			check("Appear pop", cfg.anim, "appearPop")
			if cfg.anim.appearPop then
				sliderf("  Pop time", cfg.anim, "popDur", 0.05, 1.0, "%.2f s")
			end
			check("Cast finish pulse", cfg.anim, "castPulse")
		end

		if ImGui.CollapsingHeader("Plate colors") then
			color("Background", cfg.colors, "barBack")
			color("Border", cfg.colors, "border")
		end
	end
	ImGui.End()
end

return M
