# Commands

All slash commands registered by the two feature scripts. Everything visual
is also (and more comfortably) reachable through the in-game menus
(`/npmenu`, `/aemenu`); the commands exist for quick toggles and debugging.

---

## Nameplates (`/lua run eqgfx/nameplates`)

| Command | What it does |
|---------|--------------|
| `/npmenu` | Toggle the settings window. Every widget applies live and auto-saves. |
| `/npradius N` | Set the plate range filter (world units). Same as the Radius slider. |
| `/nppcs` | Quick-toggle plates for other players. |
| `/npdebug` | Print a health report to the MQ console / log (see below). |
| `/npui` | List the EQ windows the native occlusion scan currently sees, with their rects. |
| `/npui show` | Toggle an on-screen overlay outlining every detected occluder rect with its window name. |
| `/npui add <Name>` | Track an extra window name for occlusion (find names with `/windows`). Persisted in settings. |

### Reading `/npdebug`

```
caps: sizedText=true multiColor=true clipRect=true iconDraw=true ...
```
Which optional ImGui binding features this MQ build supports. `false` values
mean the feature degrades (default-size text, flat shading, hidden plates
instead of clipped ones, colored squares instead of spell icons).

```
flags: hideUnderUI=true dll_stale=false ui_native=true findMode=1 ... liveRects=14
```
Occlusion pipeline state. `dll_stale=true` means the game loaded an older
`eqgfx.dll` than the one on disk — restart EQ once. `liveRects` is how many
window rects are currently occluding plates.

```
ui sweep: 688 candidate names -> 42 rects, 0 probe faults
ui rects: raw=42 kept=41 screen=1920x1023 (GetScreenRect = render pixels, identity)
```
The native window scan. `probe faults > 0` indicates an export/ABI mismatch
inside the scan (occlusion would be broken — report it). `raw` vs `kept`
shows how many scanned rects survived clamping/filtering.

```
AE area in flight: det circle marks npc plates
```
One line per active AE cast the highlight system is tracking, or
`AE highlight: idle`.

---

## Indicators (`/lua run eqgfx/indicators`)

| Command | What it does |
|---------|--------------|
| `/aemenu` | Toggle the settings window. |
| `/aering [r]` | Toggle a fixed debug ring of radius `r` around you (calibration aid). |
| `/aerad r` | Change the debug ring radius. |
| `/aez z` | Ground offset: how far below a spawn's reported Z to draw areas (fixes floating/buried rings on uneven ground). |

---

## Menu map

Quick orientation for the two settings windows:

**`/npmenu`** — save scope; master toggles (enabled, radius, occlusion
style, spawn types); then collapsible sections: Bar, Names, HP bar,
Mana/Endurance, Cast bar, Buffs, Target, **AE cast highlight** (sources,
colors, tint/border/glow/pulse, stacking curve), Animations, Plate colors.

**`/aemenu`** — save scope; per-category colors (self / friendly / enemy);
shape toggles (AoE rings, target rings, cones, beams, target lines); debug
ring; ground offset.
