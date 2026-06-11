--[[
  nameplates/_types.lua - types, classes and enums for the nameplate feature.
]]

local T = {}

---@enum NamePosition
T.NamePosition = { ABOVE = 1, BELOW = 2, INSIDE = 3, HIDDEN = 4 }
T.NamePositionLabels = { 'Above bar', 'Below bar', 'Inside bar', 'Hidden' }

---@enum UiOccludeMode  what happens to plates behind open EQ windows
T.UiOccludeMode = { CLIP = 1, HIDE = 2 }
T.UiOccludeModeLabels = { 'Clip (plates pass under windows)', 'Hide whole plate' }

---@enum BarTexture  procedural fill styles for HP + cast bars
T.BarTexture = { FLAT = 1, GRADIENT = 2, GLASS = 3, STRIPES = 4, SEGMENTS = 5 }
T.BarTextureLabels = { 'Flat', 'Gradient', 'Glass', 'Stripes', 'Segmented' }

---@enum BuffPosition  which side of the plate a buff row anchors to
T.BuffPosition = { TOP = 1, BOTTOM = 2, LEFT = 3, RIGHT = 4, HIDDEN = 5 }
T.BuffPositionLabels = { 'Top', 'Bottom', 'Left', 'Right', 'Hidden' }

---@enum BuffDirection  how icons stack within a row
T.BuffDirection = { HORIZONTAL = 1, VERTICAL = 2 }
T.BuffDirectionLabels = { 'Horizontal', 'Vertical' }

---@class BuffEntry
---@field id integer        spell ID
---@field icon integer      SpellIcon cell in the A_SpellIcons atlas
---@field ben boolean       beneficial?
---@field name string       spell name (lowercased matching for lists/overrides)
---@field mine boolean      cast by me?
---@field caster string|nil who cast it (tooltip)
---@field dur number|nil    duration seconds (tooltip)
---@field addedAt number|nil tick stamp when first seen (appear flash)
---@field scale number|nil  per-buff size multiplier (from overrides)
---@field prio number|nil   sort priority (higher = first, survives the cap)
---@field _i integer|nil    stable-sort tiebreaker

---@enum BuffFilterMode  which buffs make it onto the plate
T.BuffFilterMode = { ALL = 1, WHITELIST = 2, BLACKLIST = 3 }
T.BuffFilterLabels = { 'Show all', 'Whitelist only', 'Hide blacklisted' }

---@enum BuffBorderMode  what buff icon border colors signify
T.BuffBorderMode = { BY_TYPE = 1, BY_CASTER = 2 }
T.BuffBorderLabels = { 'By buff type (ben/det)', 'By caster (mine/others)' }

---@enum AnonMode  how PC names are anonymized
T.AnonMode = { OFF = 1, CLASS = 2, CLASS_SHORT = 3, SCRAMBLE = 4,
               ASTERISKS = 5, ASTERISKS8 = 6, FIRST_LAST = 7 }
T.AnonModeLabels = { 'Real names', 'Class (Magician)', 'Class short (MAG)',
                     'Scrambled (SDMFLKI)', 'Asterisks (******)',
                     'Asterisks x8 (********)', 'First+last (C****e)' }

---@enum NameAnim  passive name text animation (4+ animate per character)
T.NameAnim = { NONE = 1, BREATHE = 2, RAINBOW = 3, RAINBOW_WAVE = 4,
               WAVE = 5, BOUNCE = 6, JITTER = 7, PULSE = 8, TYPEWRITER = 9 }
T.NameAnimLabels = { 'None', 'Breathe (alpha)', 'Rainbow (whole name)',
                     'Rainbow wave (per letter)', 'Wave (per letter)',
                     'Bounce (per letter)', 'Jitter (per letter)',
                     'Pulse size (per letter)', 'Typewriter' }

---@enum HpTextPos
T.HpTextPos = { IN_LEFT = 1, IN_CENTER = 2, IN_RIGHT = 3, ABOVE = 4, BELOW = 5 }
T.HpTextPosLabels = { 'Inside left', 'Inside center', 'Inside right',
                      'Above bar', 'Below bar' }

---@enum ResScope  who gets mana/endurance bars
T.ResScope = { OFF = 1, SELF = 2, GROUP = 3, PCS = 4, ALL = 5 }
T.ResScopeLabels = { 'Off', 'Self only', 'Self + group', 'All PCs', 'Everything' }

----------------------------------------------------------------------------
-- Configuration classes. nameplates/settings.lua's DEFAULTS literal is
-- checked against these (---@type NameplatesConfig), so the class and the
-- defaults can't drift apart silently.
----------------------------------------------------------------------------

---@class NpShowCfg          which spawn types get plates
---@field npcs boolean
---@field pcs boolean
---@field pets boolean # pets & mercenaries
---@field self boolean # your own plate

---@class NpBarCfg           the HP bar body
---@field width number # pixels
---@field height number # pixels
---@field rounding number # corner radius
---@field zOffset number # world units above the spawn's head
---@field opacity number # 0..1 master alpha
---@field borderThickness number # pixels
---@field texture BarTexture # fill style (Flat/Gradient/Glass/Stripes/Segmented)

---@class NpHpCfg            HP color & percentage text
---@field gradient boolean # low->mid->high color ramp by HP%; off = fixed color
---@field showPct boolean
---@field textPos HpTextPos
---@field textSize number # pixels

---@class NpResourcesCfg     thin mana/endurance bars under the HP bar
---@field manaScope ResScope
---@field enduScope ResScope
---@field height number # pixels

---@class NpNameCfg          the name text
---@field show boolean
---@field position NamePosition
---@field size number # font pixel size (needs sized-text support)
---@field offsetX number # pixels
---@field offsetY number # pixels
---@field anonMode AnonMode # PC name anonymization
---@field background boolean
---@field bgPadding number # pixels
---@field shadow boolean # 1px drop shadow
---@field anim NameAnim # passive text animation
---@field animSpeed number # animation speed multiplier
---@field animAmount number # px amplitude for per-letter wave/bounce/jitter

---@class NpCastbarCfg       the cast bar under the plate
---@field show boolean
---@field height number # pixels
---@field gap number # pixels between plate stack and cast bar
---@field widthScale number # relative to bar width
---@field showIcon boolean # spell icon left of the bar
---@field iconSize number # pixels
---@field showSpellName boolean
---@field showTime boolean
---@field showTotal boolean # "1.2s / 3.0s" instead of "1.2s"
---@field textSize number # pixels
---@field onlyTarget boolean # cast bars only on your current target
---@field interruptDetect boolean

---@class NpBuffRowCfg       one buff icon row's anchoring
---@field position BuffPosition
---@field direction BuffDirection

---@class NpBuffOverride     per-buff tweak, keyed by lowercase spell name
---@field scale number|nil # 0.5..3.0 size multiplier
---@field priority number|nil # -10..10, higher sorts first and survives the cap
---@field hide boolean|nil

---@class NpBuffsCfg         buff icon rows
---@field enabled boolean
---@field onlyTarget boolean
---@field iconSize number # pixels
---@field spacing number # pixels between icons
---@field maxIcons number # total cap (highest priority survive)
---@field maxPerRow number # wrap to a new row/column after this many
---@field borders boolean
---@field combine boolean # one combined group at the beneficial position
---@field beneficial NpBuffRowCfg
---@field detrimental NpBuffRowCfg
---@field filterMode BuffFilterMode
---@field whitelist string[] # spell names
---@field blacklist string[]
---@field mineOnly boolean # only buffs/debuffs I cast
---@field borderMode BuffBorderMode
---@field mineBorder RGBA
---@field otherBorder RGBA
---@field dimOthers number # 0..0.8 dark overlay on icons not cast by me
---@field overrides table<string, NpBuffOverride>
---@field tooltip boolean # hover an icon: name / caster / duration
---@field rightClickInspect boolean # hold right-click: spell display window
---@field appearFlash boolean # new buffs flash an expanding outline
---@field detPulse boolean # detrimental icon borders pulse continuously

---@class NpTargetCfg        styling for your current target's plate
---@field distinguish boolean
---@field scale number # plate scale multiplier
---@field border boolean # override border color/thickness
---@field borderColor RGBA
---@field borderThickness number
---@field glow boolean # force border glow on the target

---@class NpAehlCfg          AE cast highlight
---@field enabled boolean
---@field fromMe boolean # my own casts
---@field fromPCs boolean # other players (and their pets/mercs)
---@field fromNPCs boolean # NPC casts (mark PC plates)
---@field tintBar boolean
---@field strength number # HP fill lerp toward the AE color
---@field tintBorder boolean
---@field glow boolean # pulsing rings around marked plates
---@field pulse boolean
---@field pulseSpeed number # Hz
---@field pulseAmount number # modulation depth
---@field fadeSpeed number # highlight fade in/out speed (per second)
---@field stackBase number # highlight alpha at one AE
---@field stackStep number # added per extra overlapping AE
---@field stackMax number # AE count cap

---@class NpAnimCfg          all animation toggles & tunings
---@field hpSmoothing boolean
---@field hpSpeed number
---@field fadeIn boolean
---@field fadeInDur number # seconds
---@field fadeOut boolean
---@field fadeOutDur number # seconds
---@field damageFlash boolean
---@field flashThreshold number # HP fraction drop that triggers a flash
---@field flashDur number # seconds
---@field appearPop boolean
---@field popDur number # seconds
---@field castPulse boolean # pulse when a cast completes
---@field sheen boolean # light sweep
---@field sheenPeriod number # seconds/cycle
---@field stripeScroll boolean
---@field stripeSpeed number # px/s (Stripes texture)
---@field lowHpPulse boolean
---@field lowHpThreshold number # HP fraction
---@field lowHpSpeed number # Hz
---@field breathe boolean # alpha pulse
---@field breatheAmount number
---@field breatheSpeed number # Hz
---@field borderGlow boolean
---@field glowSpeed number # Hz
---@field bob boolean # idle vertical bob
---@field bobAmount number # pixels
---@field bobSpeed number # Hz

---@class NpColors           every plate color
---@field barHigh RGBA
---@field barMid RGBA
---@field barLow RGBA
---@field barFixed RGBA
---@field barBack RGBA
---@field border RGBA
---@field name RGBA
---@field hpText RGBA
---@field flash RGBA
---@field lowHp RGBA
---@field glow RGBA
---@field nameBg RGBA
---@field nameShadow RGBA
---@field manaFill RGBA
---@field enduFill RGBA
---@field resourceBack RGBA
---@field castFill RGBA
---@field castBack RGBA
---@field castText RGBA
---@field castInterrupt RGBA
---@field aeDet RGBA # my detrimental AE will hit this spawn
---@field aeBen RGBA # my beneficial AE will help this spawn

---@class NameplatesConfig   the whole settings tree (defaults in settings.lua)
---@field enabled boolean
---@field radius number # plate range filter, world units
---@field hideUnderUI boolean # occlude plates behind open EQ windows
---@field uiOccludeMode UiOccludeMode
---@field extraWindows string[] # extra occlusion window names (/npui add)
---@field show NpShowCfg
---@field bar NpBarCfg
---@field hp NpHpCfg
---@field resources NpResourcesCfg
---@field name NpNameCfg
---@field castbar NpCastbarCfg
---@field buffs NpBuffsCfg
---@field target NpTargetCfg
---@field aehl NpAehlCfg
---@field anim NpAnimCfg
---@field colors NpColors

---@class PlateGeom          per-side layout cursors while drawing one plate
---@field x0 number # bar rect left
---@field y0 number # bar rect top
---@field x1 number # bar rect right
---@field y1 number # bar rect bottom
---@field cy number # bar vertical center
---@field top number # stack cursor, grows upward
---@field bottom number # grows downward
---@field left number # grows leftward
---@field right number # grows rightward

---@class Plate
---@field id integer
---@field name string
---@field dispHp number       smoothed HP fraction 0..1 (what the bar shows)
---@field lastHp number       last raw HP fraction (damage-flash detection)
---@field alpha number        current fade alpha 0..1
---@field scale number        current appear-pop scale
---@field bornAt number       frame-timebase stamp when the plate appeared
---@field lostAt number|nil   set when the spawn despawns / leaves range
---@field lossAlpha number|nil alpha at the moment the plate was lost
---@field flashAt number|nil  damage flash start (frame timebase)
---@field sx number|nil       last projected screen x (fade-out anchor)
---@field sy number|nil       last projected screen y
---@field dist number|nil     squared 3D distance to me (draw-order sort)
---@field isPC boolean|nil    spawn type PC?
---@field isSelf boolean|nil  this is my own plate
---@field inGroup boolean|nil spawn is in my group
---@field kind string|nil     spawn category: 'npc'|'pc'|'pet'|'merc'|'other'
---@field aeKind string|nil   'det'|'ben' while AE casts mark this plate (lingers through the fade)
---@field aeAmt number|nil    smoothed AE highlight amount 0..1 (stack alpha curve)
---@field ext number[]|nil    drawn extents last frame, relative to sx/sy: {left, top, right, bottom}
---@field cls string|nil      class name (PC anonymization)
---@field clsShort string|nil class short name
---@field mana number|nil     0..1 when the mana bar applies
---@field endu number|nil     0..1 when the endurance bar applies
---@field buffsB BuffEntry[]|nil  cached beneficial buffs
---@field buffsD BuffEntry[]|nil  cached detrimental buffs
---@field _scr string|nil     cached scrambled name
---@field _scrFor string|nil  name the scramble cache was built for

local Plate = {}
T.Plate = Plate

---@param id integer
---@param name string
---@param hp number  0..1
---@param now number
---@return Plate
function Plate.new(id, name, hp, now)
  return {
    id     = id,
    name   = name,
    dispHp = hp,
    lastHp = hp,
    alpha  = 0,
    scale  = 1,
    bornAt = now,
  }
end

return T
