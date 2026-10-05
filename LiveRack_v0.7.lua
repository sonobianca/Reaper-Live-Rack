-- LiveRack_v0.7.lua
-- Live Rack: a rack-based FX panel for REAPER, built with ReaImGui.
--
-- Every track whose name starts with PREFIX is a "rack". On detection the
-- script hides it from the TCP and the mixer and adds two small meter JSFX
-- to its chain: one at the very top (input meter) and one at the very end
-- (output RMS, used by Level match). The JSFX file is written automatically
-- to <REAPER resource path>/Effects/LiveRack/ on first run.
--
-- Requires: ReaImGui (install via ReaPack, "ReaTeam Extensions" repo).
--
-- Note for editing: every top-level name below lives in a private environment
-- (the line right under this note) instead of being a Lua "local". A script
-- may only have 200 locals; this keeps room to grow. It behaves the same.

local _ENV = setmetatable({}, { __index = _G })

PREFIX          = 'RACK:'   -- track name prefix (case-insensitive); not editable at run time
GLOW_M          = 6         -- room left around the racks for the selection glow
NAME_FONT_SIZE  = 16        -- rack name font (bold)
TITLE_FONT_SIZE = 24        -- "Live Rack" title font (bold)

LEVEL_MIN, LEVEL_MAX = -60.0, 12.0   -- dB range of the level box

EXT_SECTION     = 'LiveRack'          -- where settings are saved (REAPER ExtState)
METER_NAME      = 'LiveRack Meter'
LEGACY_NAME     = 'RackPanel'                 -- meter JSFX of earlier versions, removed automatically
METER_PATH      = 'LiveRack/LiveRack_Meter'
GMEM            = 'LiveRackMeters'
STRIDE          = 16        -- gmem slots per rack (8 input stage, 8 output stage)
EXT_BYPASS      = 'P_EXT:LiveRack_bypass'
OLD_EXT_BYPASS  = 'P_EXT:RackPanel_bypass'   -- read once, then moved to EXT_BYPASS
STATS_FILE      = '/tmp/LiveRack_stats.txt'

-- Buttons that open a native REAPER window (FX windows, routing) use this
-- color scheme: { normal, hovered, active }.
NATIVE_DARK     = { 0x1F7A7AFF, 0x2A9696FF, 0x34B0B0FF }
NATIVE_LIGHT    = { 0x7FCFCFFF, 0x6BC0C0FF, 0x58B0B0FF }

if not reaper.ImGui_CreateContext then
  reaper.MB('ReaImGui is not installed.\nInstall it from ReaPack (ReaTeam Extensions), then restart REAPER.',
            'Live Rack', 0)
  return
end

-- shorthand: ig.Button(...) == reaper.ImGui_Button(...)
ig = setmetatable({}, { __index = function(t, k)
  local f = reaper['ImGui_' .. k]
  rawset(t, k, f)
  return f
end })

cfg_flags = 0
if reaper.ImGui_ConfigFlags_DockingEnable then cfg_flags = reaper.ImGui_ConfigFlags_DockingEnable() end
ctx = reaper.ImGui_CreateContext('Live Rack', cfg_flags)

math.randomseed(math.floor(reaper.time_precise() * 1000))

---------------------------------------------------------------- editable settings

-- Everything here shows up in Options > Settings... (group, label, range).
-- kind: 'f' = decimal slider, 'i' = integer slider, 'mod' = modifier key.
SCHEMA = {
  { group = 'Colors', key = 'color_l_min', label = 'Lightness, min', kind = 'f', min = 0.05, max = 0.95, def = 0.38, fmt = '%.2f',
    tip = 'Darkest automatic rack color (0 = black). Keep it away from 0.' },
  { group = 'Colors', key = 'color_l_max', label = 'Lightness, max', kind = 'f', min = 0.05, max = 0.95, def = 0.68, fmt = '%.2f',
    tip = 'Lightest automatic rack color (1 = white). Keep it away from 1.' },
  { group = 'Colors', key = 'color_s_min', label = 'Saturation, min', kind = 'f', min = 0.0, max = 1.0, def = 0.55, fmt = '%.2f',
    tip = 'Least saturated automatic color.' },
  { group = 'Colors', key = 'color_s_max', label = 'Saturation, max', kind = 'f', min = 0.0, max = 1.0, def = 0.90, fmt = '%.2f',
    tip = 'Most saturated automatic color.' },
  { group = 'Colors', key = 'hue_step', label = 'Hue jump between racks', kind = 'f', min = 30, max = 180, def = 137.5, fmt = '%.1f deg',
    tip = 'How far the hue moves from one rack to the next (137.5 = golden angle).' },

  { group = 'Meters', key = 'meter_min', label = 'Meter floor (dB)', kind = 'f', min = -90, max = -20, def = -60, fmt = '%.0f',
    tip = 'Bottom of the meters.' },
  { group = 'Meters', key = 'meter_max', label = 'Meter top (dB)', kind = 'f', min = -6, max = 12, def = 6, fmt = '%.0f',
    tip = 'Top of the meters.' },
  { group = 'Meters', key = 'meter_fall', label = 'Fall speed (dB/s)', kind = 'f', min = 5, max = 120, def = 40, fmt = '%.0f',
    tip = 'How fast the meters fall back.' },
  { group = 'Meters', key = 'clip_db', label = 'Clip level (dB)', kind = 'f', min = -6, max = 0, def = -0.1, fmt = '%.1f',
    tip = 'Peaks at or above this level light the clip marker.' },

  { group = 'Level match', key = 'match_secs', label = 'Measuring time (s)', kind = 'f', min = 1, max = 10, def = 3, fmt = '%.1f',
    tip = 'How long Level match listens.' },
  { group = 'Level match', key = 'match_gate', label = 'Signal gate (dB)', kind = 'f', min = -80, max = -20, def = -50, fmt = '%.0f',
    tip = 'Quieter input than this is ignored while measuring.' },

  { group = 'Behavior', key = 'copy_mod', label = 'Copy modifier key', kind = 'mod', def = 'ctrl',
    tip = 'Hold while dropping an FX to copy it (Ctrl is Cmd on macOS).' },
  { group = 'Behavior', key = 'move_mod', label = 'Move modifier key', kind = 'mod', def = 'alt',
    tip = 'Hold while dropping an FX on another rack to move it.' },
  { group = 'Behavior', key = 'long_list', label = 'Split FX lists above', kind = 'i', min = 10, max = 100, def = 30, fmt = '%d items',
    tip = 'FX lists longer than this are split by first letter.' },
  { group = 'Behavior', key = 'scan_every', label = 'Rack scan interval (s)', kind = 'f', min = 0.2, max = 2, def = 0.5, fmt = '%.1f',
    tip = 'How often the panel looks for new racks.' },
  { group = 'Behavior', key = 'stats_every', label = 'Status bar refresh (s)', kind = 'f', min = 0.25, max = 5, def = 1.0, fmt = '%.2f',
    tip = 'How often CPU, memory and latency are refreshed.' },

  { group = 'Appearance', key = 'rounding', label = 'Corner rounding', kind = 'i', min = 0, max = 14, def = 6, fmt = '%d px',
    tip = 'Corner radius of buttons, boxes and sections.' },

  { group = 'Layout', key = 'center_w', label = 'Middle area width', kind = 'i', min = 140, max = 320, def = 180, fmt = '%d px',
    tip = 'Width of the part of a rack between the meters.' },
  { group = 'Layout', key = 'meter_w', label = 'Meter width', kind = 'i', min = 14, max = 32, def = 20, fmt = '%d px',
    tip = 'Width of each meter; also the size of the round R and ... buttons.' },
  { group = 'Layout', key = 'pad', label = 'Rack padding', kind = 'i', min = 2, max = 20, def = 8, fmt = '%d px',
    tip = 'Space between the rack border and what is inside.' },
  { group = 'Layout', key = 'gap', label = 'Meter gap', kind = 'i', min = 0, max = 16, def = 6, fmt = '%d px',
    tip = 'Space between a meter and the middle area.' },
  { group = 'Layout', key = 'si', label = 'Section padding', kind = 'i', min = 0, max = 12, def = 4, fmt = '%d px',
    tip = 'Space inside the three boxes of a rack.' },
  { group = 'Layout', key = 'sg', label = 'Section gap', kind = 'i', min = 0, max = 16, def = 6, fmt = '%d px',
    tip = 'Space between the three boxes of a rack.' },
  { group = 'Layout', key = 'rack_space', label = 'Space between racks', kind = 'i', min = 0, max = 24, def = 8, fmt = '%d px',
    tip = 'Also the space under the top bar and above the status bar.' },
  { group = 'Layout', key = 'clip_h', label = 'Clip marker height', kind = 'i', min = 2, max = 12, def = 6, fmt = '%d px',
    tip = 'Height of the clip markers above the meters.' },
}

CFG = {}

function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function load_cfg()
  for _, e in ipairs(SCHEMA) do
    local raw = reaper.GetExtState(EXT_SECTION, 'cfg_' .. e.key)
    if e.kind == 'mod' then
      CFG[e.key] = (raw == 'shift' or raw == 'ctrl' or raw == 'alt') and raw or e.def
    else
      local v = tonumber(raw)
      if v then v = clamp(v, e.min, e.max) else v = e.def end
      if e.kind == 'i' then v = math.floor(v + 0.5) end
      CFG[e.key] = v
    end
  end
end

function save_cfg_value(e)
  reaper.SetExtState(EXT_SECTION, 'cfg_' .. e.key, tostring(CFG[e.key]), true)
end

function reset_cfg()
  for _, e in ipairs(SCHEMA) do
    CFG[e.key] = e.def
    reaper.DeleteExtState(EXT_SECTION, 'cfg_' .. e.key, true)
  end
end

-- copies the editable settings into the names the rest of the script uses
function apply_settings()
  COLOR_L_MIN, COLOR_L_MAX = CFG.color_l_min, CFG.color_l_max
  COLOR_S_MIN, COLOR_S_MAX = CFG.color_s_min, CFG.color_s_max
  HUE_STEP    = CFG.hue_step
  METER_MIN, METER_MAX = CFG.meter_min, CFG.meter_max
  METER_FALL  = CFG.meter_fall
  CLIP_DB     = CFG.clip_db
  MATCH_SECS, MATCH_GATE = CFG.match_secs, CFG.match_gate
  COPY_MOD, MOVE_MOD = CFG.copy_mod, CFG.move_mod
  LONG_LIST   = math.floor(CFG.long_list)
  SCAN_EVERY  = CFG.scan_every
  STATS_EVERY = CFG.stats_every
  ROUNDING    = CFG.rounding
  CENTER_W, METER_W = CFG.center_w, CFG.meter_w
  PAD, GAP, SI, SG  = CFG.pad, CFG.gap, CFG.si, CFG.sg
  RACK_SPACE, CLIP_H = CFG.rack_space, CFG.clip_h
  RACK_W     = CENTER_W + 2 * METER_W + 2 * GAP + 2 * PAD
  MIN_W, MIN_H = RACK_W + 50, 260
end

---------------------------------------------------------------- settings saved under the old name

-- Before the app was called Live Rack its settings lived in the "RackPanel" section
-- (and one layout setting was called "strip_space"). Copy them over once.
function migrate_ext_state()
  if reaper.GetExtState(EXT_SECTION, 'migrated') == '1' then return end
  local keys = { 'colormode', 'hiddentypes', 'daylight', 'defcolor', 'disconnect', 'mode', 'nometers', 'dock' }
  for _, e in ipairs(SCHEMA) do keys[#keys + 1] = 'cfg_' .. e.key end
  keys[#keys + 1] = 'cfg_strip_space'
  for _, k in ipairs(keys) do
    local v = reaper.GetExtState('RackPanel', k)
    if v ~= '' then
      local nk = (k == 'cfg_strip_space') and 'cfg_rack_space' or k
      if reaper.GetExtState(EXT_SECTION, nk) == '' then reaper.SetExtState(EXT_SECTION, nk, v, true) end
      reaper.DeleteExtState('RackPanel', k, true)
    end
  end
  reaper.SetExtState(EXT_SECTION, 'migrated', '1', true)
end
migrate_ext_state()

---------------------------------------------------------------- panel settings (remembered)

function load_settings()
  local mode = reaper.GetExtState(EXT_SECTION, 'colormode')
  local hidden = {}
  for n in reaper.GetExtState(EXT_SECTION, 'hiddentypes'):gmatch('[^,]+') do hidden[n] = true end
  return {
    daylight    = reaper.GetExtState(EXT_SECTION, 'daylight') == '1',
    color_mode  = (mode == 'default') and 'default' or 'auto',
    default_rgb = tonumber(reaper.GetExtState(EXT_SECTION, 'defcolor')) or 0x3D85C6,
    disconnect  = reaper.GetExtState(EXT_SECTION, 'disconnect') == '1',
    hidden      = hidden,           -- FX types left out of the menus
    mode        = (reaper.GetExtState(EXT_SECTION, 'mode') == 'show') and 'show' or 'edit',
    no_meters   = reaper.GetExtState(EXT_SECTION, 'nometers') == '1',   -- troubleshooting switch
    show_settings = false,
  }
end

S = load_settings()

function save_setting(key, value)
  reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
end

function hidden_list()
  local t = {}
  for n in pairs(S.hidden) do t[#t + 1] = n end
  table.sort(t)
  return t
end

function save_hidden()
  save_setting('hiddentypes', table.concat(hidden_list(), ','))
end

---------------------------------------------------------------- fonts

function reaimgui_version()
  if not reaper.ImGui_GetVersion then return 0 end
  local _, _, v = reaper.ImGui_GetVersion()
  local maj, min = tostring(v):match('^(%d+)%.(%d+)')
  return (tonumber(maj) or 0) * 1000 + (tonumber(min) or 0)
end

-- 0.10+: CreateFont(family, flags) + PushFont(ctx, font, size)
-- 0.9  : CreateFont(family, size, flags) + PushFont(ctx, font)
new_font_api = reaimgui_version() >= 10

function make_bold_font(size)
  local bold = reaper.ImGui_FontFlags_Bold and reaper.ImGui_FontFlags_Bold() or 0
  local ok, f = pcall(function()
    if new_font_api then
      return reaper.ImGui_CreateFont('sans-serif', bold)
    end
    return reaper.ImGui_CreateFont('sans-serif', size, bold)
  end)
  if ok and f then
    pcall(reaper.ImGui_Attach, ctx, f)
    return f
  end
  return nil
end

name_font  = make_bold_font(NAME_FONT_SIZE)
title_font = new_font_api and name_font or make_bold_font(TITLE_FONT_SIZE)

function push_bold(font, size)
  if not font then return false end
  local ok
  if new_font_api then
    ok = pcall(reaper.ImGui_PushFont, ctx, font, size)
  else
    ok = pcall(reaper.ImGui_PushFont, ctx, font)
  end
  return ok
end

---------------------------------------------------------------- JSFX

JSFX_SRC = [==[
desc:LiveRack Meter
// Part of LiveRack_v0.7.lua - do not remove. Audio passes through untouched.
// Stage 0 = chain input, stage 1 = chain output (before the track fader).
// Publishes peak and RMS data to the panel through gmem.
options:gmem=LiveRackMeters

slider1:0<0,255,1>-Slot (managed by Live Rack)
slider2:0<0,1,1>-Stage (0 input, 1 output)

in_pin:Left
in_pin:Right
out_pin:Left
out_pin:Right

@init
bpl = 0;
bpr = 0;
ssl = 0;
ssr = 0;
cnt = 0;
base = 0;

@slider
base = floor(slider1) * 16 + floor(slider2) * 8;

@block
gmem[base + 0] = max(gmem[base + 0], bpl);
gmem[base + 1] = max(gmem[base + 1], bpr);
gmem[base + 2] += 1;
gmem[base + 3] += ssl;
gmem[base + 4] += ssr;
gmem[base + 5] += cnt;
bpl = 0;
bpr = 0;
ssl = 0;
ssr = 0;
cnt = 0;

@sample
a = abs(spl0);
a > bpl ? bpl = a;
b = abs(spl1);
b > bpr ? bpr = b;
ssl += spl0 * spl0;
ssr += spl1 * spl1;
cnt += 1;
]==]

function install_jsfx()
  local dir  = reaper.GetResourcePath() .. '/Effects/LiveRack'
  local path = dir .. '/LiveRack_Meter'
  local f = io.open(path, 'r')
  if f then
    local cur = f:read('*a')
    f:close()
    if cur == JSFX_SRC then return true end
  end
  reaper.RecursiveCreateDirectory(dir, 0)
  f = io.open(path, 'w')
  if not f then return false end
  f:write(JSFX_SRC)
  f:close()
  return true
end

---------------------------------------------------------------- state

racks         = {}
last_scan     = -math.huge
meters        = {}      -- [guid] = meter state
matches       = {}      -- [guid] = level match measurement
status        = {}      -- [guid] = { text, untl }
edit_state    = {}      -- text boxes
name_state    = {}      -- [guid] = { editing, text, fresh, was_active }
pending_ops   = {}      -- FX reorders / copies / moves requested by drag and drop
pending_racks = {}      -- rack reorders requested by drag and drop
meter_error   = nil
fx_db         = nil     -- installed FX, built on first use
fx_view       = nil     -- fx_db without the hidden FX types
fx_view_key   = nil
confirm       = nil     -- pending confirmation dialog { text, yes, label }
confirm_open  = false
picker        = { open = false, kind = nil, tr = nil, rgb = 0x808080 }
last_time     = reaper.time_precise()

win_w, win_h   = 840, 480   -- last good window size
prev_w, prev_h = nil, nil
was_visible    = true
force_size     = false
dock_request   = nil
cur_dock       = nil
saved_dock     = tonumber(reaper.GetExtState(EXT_SECTION, 'dock')) or 0
dock_applied   = false

ZONES = {
  { -60, -12, 0x40C060FF },
  { -12,  -3, 0xE0C040FF },
  {  -3,   6, 0xE04040FF },
}

TYPE_ORDER = { 'VST3', 'VST3i', 'VST', 'VSTi', 'CLAP', 'CLAPi', 'AU', 'AUi', 'JS', 'LV2', 'LV2i', 'DX', 'DXi' }

---------------------------------------------------------------- helpers

WHITE, BLACK = 0xFFFFFFFF, 0x000000FF

function amp_to_db(a)
  if a <= 0.0000001 then return -150.0 end
  return 20.0 * math.log(a, 10)
end

function meter_frac(db)
  return clamp((db - METER_MIN) / (METER_MAX - METER_MIN), 0, 1)
end

function valid(tr)
  return reaper.ValidatePtr2(0, tr, 'MediaTrack*')
end

function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  return name
end

function is_rack_name(name)
  return name:sub(1, #PREFIX):upper() == PREFIX:upper()
end

function raw_name(tr)
  local n = track_name(tr)
  if is_rack_name(n) then n = n:sub(#PREFIX + 1) end
  return (n:match('^%s*(.-)%s*$'))
end

-- colors are 0xRRGGBBAA everywhere in the panel
function mix(a, b, t)
  local function ch(c, s) return (c >> s) & 255 end
  local r = math.floor(ch(a, 24) + (ch(b, 24) - ch(a, 24)) * t + 0.5)
  local g = math.floor(ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t + 0.5)
  local bl = math.floor(ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t + 0.5)
  return (r << 24) | (g << 16) | (bl << 8) | 0xFF
end

function darken(rgba, f)
  return mix(rgba, BLACK, 1 - f)
end

function lum(rgba)
  return (0.2126 * ((rgba >> 24) & 255) + 0.7152 * ((rgba >> 16) & 255)
        + 0.0722 * ((rgba >> 8) & 255)) / 255
end

-- readable text on top of `bg`, keeping a hint of `tint`
function contrast_text(bg, tint)
  if lum(bg) < 0.5 then return mix(tint, WHITE, 0.85) end
  return mix(tint, BLACK, 0.85)
end

function track_rgb(tr)
  local c = reaper.GetTrackColor(tr)
  if c == 0 then return nil end
  return reaper.ColorFromNative(c & 0xFFFFFF)
end

function track_color(tr)
  local r, g, b = track_rgb(tr)
  if not r then return 0xB0B0B0FF end
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

function set_track_rgb(tr, r, g, b)
  reaper.SetMediaTrackInfo_Value(tr, 'I_CUSTOMCOLOR',
    reaper.ColorToNative(math.floor(r), math.floor(g), math.floor(b)) | 0x1000000)
end

function clean_fx_name(name)
  name = name:gsub('^[%w_%-]+:%s*', '')
  name = name:gsub('%s*%b()$', '')
  return name
end

function fit_text(s, w)
  if ig.CalcTextSize(ctx, s) <= w then return s end
  while #s > 1 and ig.CalcTextSize(ctx, s .. '...') > w do
    s = s:sub(1, (utf8.offset(s, -1) or #s) - 1)
  end
  return s .. '...'
end

function with_undo(label, fn)
  reaper.Undo_BeginBlock2(0)
  fn()
  reaper.Undo_EndBlock2(0, label, -1)
end

function has_mod(name)
  local mods = ig.GetKeyMods(ctx)
  local flag
  if name == 'shift' then flag = ig.Mod_Shift()
  elseif name == 'alt' then flag = ig.Mod_Alt()
  else flag = ig.Mod_Ctrl() end
  return (mods & flag) ~= 0
end

function mouse_in(x1, y1, x2, y2)
  local mx, my = ig.GetMousePos(ctx)
  return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

-- what is being dragged right now (a rack's guid / "guid|fxindex"); the "prev" values
-- are last frame's, so every rack can react to a drag that started in another one
drag_now_rack, drag_now_fx, drag_prev_rack, drag_prev_fx = nil, nil, nil, nil

-- the drag preview of an FX: a button-shaped bar that follows the cursor
function draw_fx_ghost(name, hint, w, h)
  local x, y = ig.GetCursorScreenPos(ctx)
  local gdl = ig.GetWindowDrawList(ctx)
  ig.DrawList_AddRectFilled(gdl, x, y, x + w, y + h, (T.native[1] & 0xFFFFFF00) | 0xE6, ROUNDING)
  ig.DrawList_AddRect(gdl, x, y, x + w, y + h, T.glow, ROUNDING, 0, 2)
  local label = fit_text(name .. hint, w - 12)
  local tw = ig.CalcTextSize(ctx, label)
  ig.DrawList_AddText(gdl, x + (w - tw) / 2, y + (h - ig.GetTextLineHeight(ctx)) / 2, T.gauge_text, label)
  ig.Dummy(ctx, w, h)
end

function rack_by_guid(g)
  for _, tr in ipairs(racks) do
    if valid(tr) and reaper.GetTrackGUID(tr) == g then return tr end
  end
  return nil
end

function rack_index(tr)
  for i, t in ipairs(racks) do
    if t == tr then return i end
  end
  return nil
end

function request_confirm(text, yes, label)
  confirm = { text = text, yes = yes, label = label or 'Yes' }
  confirm_open = true
end

---------------------------------------------------------------- modes and selection

-- Show mode locks everything that changes the structure of the racks:
-- creating, renaming, reordering, recoloring, routing, loading/removing FX.
-- Level, mute, bypass, FX on/off, A/B and opening FX windows stay usable.
function is_locked()
  return S.mode == 'show'
end

function lock_begin(on)
  if on and ig.BeginDisabled then ig.BeginDisabled(ctx, true) end
end

function lock_end(on)
  if on and ig.EndDisabled then ig.EndDisabled(ctx) end
end

function set_mode(mode)
  S.mode = mode
  save_setting('mode', mode)
end

-- a rack's selection is REAPER's own track selection
function rack_selected(tr)
  return reaper.IsTrackSelected(tr)
end

-- click = only this rack; Cmd/Ctrl-click = add to / remove from the selection
function select_rack(tr, additive)
  if additive then
    reaper.SetTrackSelected(tr, not reaper.IsTrackSelected(tr))
  else
    reaper.SetOnlyTrackSelected(tr)
  end
end

function deselect_racks()
  for _, t in ipairs(racks) do
    if valid(t) then reaper.SetTrackSelected(t, false) end
  end
end

-- racks an action from the Rack Option Menu applies to: all selected racks when
-- the rack it was opened on is selected, otherwise just that rack
function targets_for(tr)
  if reaper.IsTrackSelected(tr) then
    local out = {}
    for _, t in ipairs(racks) do
      if valid(t) and reaper.IsTrackSelected(t) then out[#out + 1] = t end
    end
    if #out > 0 then return out end
  end
  return { tr }
end

-- runs fn(rack) on every target; with several racks it asks first
function rack_action(tr, what, fn, label)
  local trs = targets_for(tr)
  local function go()
    for _, t in ipairs(trs) do
      if valid(t) then fn(t) end
    end
  end
  if #trs > 1 then
    request_confirm(('%s\nfor the %d selected racks?'):format(what, #trs), go, label or 'Apply')
  else
    go()
  end
end

---------------------------------------------------------------- theme

-- Dark is REAPER-like ImGui as before. Daylight is a light scheme that still
-- follows each rack's own color (pale tint as background, solid color for the name).
LIGHT_COLORS = {
  { 'WindowBg', 0xF2F2F2FF },     { 'Text', 0x141414FF },
  { 'TextDisabled', 0x6A6A6AFF }, { 'Button', 0xD9D9D9FF },
  { 'ButtonHovered', 0xC9C9C9FF }, { 'ButtonActive', 0xB5B5B5FF },
  { 'FrameBg', 0xFFFFFFFF },      { 'FrameBgHovered', 0xF0F0F0FF },
  { 'FrameBgActive', 0xE6E6E6FF }, { 'PopupBg', 0xFAFAFAFF },
  { 'Border', 0x9A9A9AFF },       { 'Header', 0xD0D8E8FF },
  { 'HeaderHovered', 0xBCC8E0FF }, { 'HeaderActive', 0xA8B8D8FF },
  { 'CheckMark', 0x141414FF },    { 'ScrollbarBg', 0xE0E0E0FF },
  { 'ScrollbarGrab', 0xB0B0B0FF }, { 'TextSelectedBg', 0x4296FA55 },
}

function theme()
  if S.daylight then
    return {
      native = NATIVE_LIGHT, byp = 0xFFB347FF, mute = 0xFF7B7BFF, dim = 0x606060FF,
      meter_bg = 0xC8C8C8FF, hold = 0x000000FF, clip_off = 0xC9A9A9FF,
      bar_border = 0x707070FF, title = 0x1B3A5BFF, gauge_text = 0x141414FF,
      chk_bg = 0xFFFFFFFF, chk_ring = 0x333333FF, chk_dot = 0x1E6FD9FF,
      glow = 0x1E6FD9FF, cue_edit = 0x2E9E4FFF, cue_show = 0xD23C3CFF,
    }
  end
  return {
    native = NATIVE_DARK, byp = 0xD08020FF, mute = 0xC03030FF, dim = 0xA0A0A0FF,
    meter_bg = 0x181818FF, hold = 0xFFFFFFFF, clip_off = 0x3A2020FF,
    bar_border = 0x707070FF, title = 0xFFD27AFF, gauge_text = 0xFFFFFFFF,
    chk_bg = 0x1A1A1AFF, chk_ring = 0xCCCCCCFF, chk_dot = 0x6FB4FFFF,
    glow = 0xFFFFFFFF, cue_edit = 0x2E9E4FFF, cue_show = 0xD23C3CFF,
  }
end

T = theme()

function rack_colors(col, bypassed)
  local c = {}
  if not S.daylight then
    if bypassed then
      c.bg, c.border, c.sec_bg, c.sec_bd = 0x2A2A2AFF, 0x666666FF, 0x1E1E1EFF, 0x505050FF
    else
      c.bg, c.border = darken(col, 0.25), col
      c.sec_bg, c.sec_bd = darken(col, 0.36), darken(col, 0.75)
    end
    c.name_bg = bypassed and 0x303030FF or darken(col, 0.5)
    c.line = 0xFFFFFF30
  else
    if bypassed then
      c.bg, c.border, c.sec_bg, c.sec_bd = 0xD6D6D6FF, 0x8A8A8AFF, 0xE8E8E8FF, 0xA0A0A0FF
    else
      c.bg, c.border = mix(col, WHITE, 0.80), mix(col, BLACK, 0.25)
      c.sec_bg, c.sec_bd = mix(col, WHITE, 0.90), mix(col, BLACK, 0.12)
    end
    c.name_bg = bypassed and 0xBEBEBEFF or col
    c.line = 0x00000040
  end
  c.name_txt = contrast_text(c.name_bg, col)
  return c
end

function push_native()
  ig.PushStyleColor(ctx, ig.Col_Button(),        T.native[1])
  ig.PushStyleColor(ctx, ig.Col_ButtonHovered(), T.native[2])
  ig.PushStyleColor(ctx, ig.Col_ButtonActive(),  T.native[3])
end

function pop_native()
  ig.PopStyleColor(ctx, 3)
end

---------------------------------------------------------------- colors

function rgb_to_hsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l = (mx + mn) / 2
  if mx == mn then return 0, 0, l end
  local d = mx - mn
  local s = (l > 0.5) and d / (2 - mx - mn) or d / (mx + mn)
  local h
  if mx == r then h = (g - b) / d + ((g < b) and 6 or 0)
  elseif mx == g then h = (b - r) / d + 2
  else h = (r - g) / d + 4 end
  return h * 60, s, l
end

function hsl_to_rgb(h, s, l)
  h = (h % 360) / 360
  local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end
  local q = (l < 0.5) and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return math.floor(hue2rgb(p, q, h + 1 / 3) * 255 + 0.5),
         math.floor(hue2rgb(p, q, h) * 255 + 0.5),
         math.floor(hue2rgb(p, q, h - 1 / 3) * 255 + 0.5)
end

function hue_dist(a, b)
  local d = math.abs(a - b) % 360
  return (d > 180) and 360 - d or d
end

function track_hue(tr)
  local r, g, b = track_rgb(tr)
  if not r then return nil end
  return (rgb_to_hsl(r, g, b))
end

-- a hue that contrasts with the given neighbour hues (either may be nil)
function contrast_hue(a, b)
  if not a and not b then return math.random() * 360 end
  if not a or not b then
    return ((a or b) + HUE_STEP + (math.random() - 0.5) * 30) % 360
  end
  local scores, best = {}, -1
  for h = 0, 355, 5 do
    local sc = math.min(hue_dist(h, a), hue_dist(h, b))
    scores[#scores + 1] = { h, sc }
    if sc > best then best = sc end
  end
  local cands = {}
  for _, e in ipairs(scores) do
    if e[2] >= best - 6 then cands[#cands + 1] = e[1] end
  end
  return cands[math.random(#cands)]
end

-- random saturation / lightness inside the allowed range
function rgb_for_hue(h)
  local s = COLOR_S_MIN + math.random() * (COLOR_S_MAX - COLOR_S_MIN)
  local l = COLOR_L_MIN + math.random() * (COLOR_L_MAX - COLOR_L_MIN)
  return hsl_to_rgb(h, s, l)
end

function default_rgb_parts()
  local c = S.default_rgb
  return (c >> 16) & 255, (c >> 8) & 255, c & 255
end

-- color for a rack that is created or copied between prev_tr and next_tr
function color_for_new(prev_tr, next_tr)
  if S.color_mode == 'default' then return default_rgb_parts() end
  local a = prev_tr and track_hue(prev_tr)
  local b = next_tr and track_hue(next_tr)
  return rgb_for_hue(contrast_hue(a, b))
end

function recolor_every_rack()
  with_undo('Rack: recolor every rack', function()
    local hue = math.random() * 360
    for i, tr in ipairs(racks) do
      if valid(tr) then
        if i > 1 then hue = (hue + HUE_STEP + (math.random() - 0.5) * 30) % 360 end
        set_track_rgb(tr, rgb_for_hue(hue))
      end
    end
  end)
end

function recolor_rack_auto(tr)
  local i = rack_index(tr)
  local a = i and racks[i - 1] and track_hue(racks[i - 1])
  local b = i and racks[i + 1] and track_hue(racks[i + 1])
  with_undo('Rack: recolor', function()
    set_track_rgb(tr, rgb_for_hue(contrast_hue(a, b)))
  end)
end

function open_picker(kind, tr)
  picker.kind = kind
  picker.trs = (kind == 'rack') and targets_for(tr) or nil     -- every selected rack, or just this one
  if kind == 'rack' then
    local r, g, b = track_rgb(tr)
    picker.rgb = r and ((r << 16) | (g << 8) | b) or S.default_rgb
  else
    picker.rgb = S.default_rgb
  end
  picker.open = true
end

---------------------------------------------------------------- chain

-- Splits the FX chain into: the input meter, the output meter, the real
-- FX (the only thing shown to the user) and leftovers to clean up.
function chain_info(tr)
  local info = { list = {}, legacy = {}, extras = {} }
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, fx, '')
    if name:find(LEGACY_NAME, 1, true) then
      info.legacy[#info.legacy + 1] = fx
    elseif name:find(METER_NAME, 1, true) then
      local stage = math.floor(reaper.TrackFX_GetParam(tr, fx, 1) + 0.5)
      if stage == 0 then
        if info.in_fx then info.extras[#info.extras + 1] = fx else info.in_fx = fx end
      else
        if info.out_fx then info.extras[#info.extras + 1] = fx else info.out_fx = fx end
      end
    else
      info.list[#info.list + 1] = { fx = fx, name = name, enabled = reaper.TrackFX_GetEnabled(tr, fx) }
    end
  end
  return info
end

function fx_index_by_guid(tr, guid)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetFXGUID(tr, i) == guid then return i end
  end
  return nil
end

-- Moves an FX so that it ends up at index `dst`. The result is verified and
-- corrected once, so it does not matter how REAPER counts the destination.
function move_fx(tr, src, dst)
  if src == dst then return end
  local g = reaper.TrackFX_GetFXGUID(tr, src)
  reaper.TrackFX_CopyToTrack(tr, src, tr, dst, true)
  local f = fx_index_by_guid(tr, g)
  if f and f ~= dst then
    reaper.TrackFX_CopyToTrack(tr, f, tr, dst + (dst - f), true)
  end
end

function get_saved_bypass(tr)
  local ok, s = reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, '', false)
  if ok and s ~= '' then return s end
  -- state saved by an earlier version: move it to the new key
  local ok2, old = reaper.GetSetMediaTrackInfo_String(tr, OLD_EXT_BYPASS, '', false)
  if ok2 and old ~= '' then
    reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, old, true)
    reaper.GetSetMediaTrackInfo_String(tr, OLD_EXT_BYPASS, '', true)
    return old
  end
  return nil
end

function is_bypassed(tr, list)
  if not get_saved_bypass(tr) then return false end
  for _, it in ipairs(list) do
    if it.enabled then
      -- an FX was re-enabled by hand: forget the stale bypass state
      reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, '', true)
      return false
    end
  end
  return true
end

-- bypass = disable every FX (the meters keep running)
function set_bypass(tr, on)
  local list = chain_info(tr).list
  if on then
    local t = {}
    for i, it in ipairs(list) do t[i] = it.enabled and '1' or '0' end
    reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, (#t > 0) and table.concat(t, ',') or 'x', true)
    for _, it in ipairs(list) do reaper.TrackFX_SetEnabled(tr, it.fx, false) end
  else
    local s = get_saved_bypass(tr)
    local states = {}
    if s then for v in s:gmatch('[01]') do states[#states + 1] = v end end
    for i, it in ipairs(list) do
      local st = states[i]
      reaper.TrackFX_SetEnabled(tr, it.fx, st == nil or st == '1')
    end
    reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, '', true)
  end
end

function unbypass_if_needed(tr)
  if get_saved_bypass(tr) then set_bypass(tr, false) end
end

function remove_all_fx(tr)
  with_undo('Rack: remove every FX', function()
    local list = chain_info(tr).list
    for i = #list, 1, -1 do reaper.TrackFX_Delete(tr, list[i].fx) end
    reaper.GetSetMediaTrackInfo_String(tr, EXT_BYPASS, '', true)
  end)
end

function remove_bypassed_fx(tr)
  with_undo('Rack: remove bypassed FX', function()
    unbypass_if_needed(tr)
    local list = chain_info(tr).list
    for i = #list, 1, -1 do
      if not list[i].enabled then reaper.TrackFX_Delete(tr, list[i].fx) end
    end
  end)
end

function ab_invert(tr)
  with_undo('Rack: A/B FX', function()
    unbypass_if_needed(tr)
    for _, it in ipairs(chain_info(tr).list) do
      reaper.TrackFX_SetEnabled(tr, it.fx, not it.enabled)
    end
  end)
end

function revert_to_track(tr)
  with_undo('Rack: revert to regular track', function()
    unbypass_if_needed(tr)
    for fx = reaper.TrackFX_GetCount(tr) - 1, 0, -1 do
      local _, name = reaper.TrackFX_GetFXName(tr, fx, '')
      if name:find(METER_NAME, 1, true) or name:find(LEGACY_NAME, 1, true) then
        reaper.TrackFX_Delete(tr, fx)
      end
    end
    reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', raw_name(tr), true)
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 1)
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end)
  last_scan = -math.huge
end

function delete_rack(tr)
  with_undo('Rack: delete rack', function()
    reaper.DeleteTrack(tr)
  end)
  last_scan = -math.huge
end

-- adds an FX at the end of the rack's FX (always before the output meter)
function add_fx_to_rack(tr, ident)
  with_undo('Rack: add FX', function()
    local idx = reaper.TrackFX_AddByName(tr, ident, false, -1)
    if idx >= 0 then
      local info = chain_info(tr)
      if info.out_fx and idx > info.out_fx then move_fx(tr, idx, info.out_fx) end
    end
  end)
end

-- inserts an FX at `pos`; the FX from there on move down
function insert_fx_at(tr, ident, pos)
  with_undo('Rack: insert FX', function()
    local idx = reaper.TrackFX_AddByName(tr, ident, false, -1)
    if idx >= 0 then move_fx(tr, idx, pos) end
  end)
end

-- swaps the FX identified by `old_guid` for a new one (keeps the enabled state)
function replace_fx(tr, old_guid, ident)
  with_undo('Rack: replace FX', function()
    local pos = fx_index_by_guid(tr, old_guid)
    if not pos then return end
    local was_enabled = reaper.TrackFX_GetEnabled(tr, pos)
    local idx = reaper.TrackFX_AddByName(tr, ident, false, -1)
    if idx < 0 then return end
    local new_guid = reaper.TrackFX_GetFXGUID(tr, idx)
    move_fx(tr, idx, pos)
    local old = fx_index_by_guid(tr, old_guid)
    if old then reaper.TrackFX_Delete(tr, old) end
    local ni = fx_index_by_guid(tr, new_guid)
    if ni then reaper.TrackFX_SetEnabled(tr, ni, was_enabled) end
  end)
end

function delete_fx(tr, guid)
  with_undo('Rack: delete FX', function()
    local pos = fx_index_by_guid(tr, guid)
    if pos then reaper.TrackFX_Delete(tr, pos) end
  end)
end

---------------------------------------------------------------- tracks

function save_selection()
  local prev = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    prev[#prev + 1] = reaper.GetSelectedTrack(0, i)
  end
  return prev
end

function restore_selection(prev)
  reaper.Main_OnCommand(40297, 0)          -- unselect all tracks
  for _, t in ipairs(prev) do
    if valid(t) then reaper.SetTrackSelected(t, true) end
  end
end

-- Runs an action with only `tr` selected, then restores the selection.
function run_with_only_selected(tr, cmd)
  local prev = save_selection()
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(tr, true)
  reaper.Main_OnCommand(cmd, 0)
  restore_selection(prev)
end

function open_routing(tr)
  run_with_only_selected(tr, 40293)        -- view routing for selected tracks
end

-- removes every input and output of a track
function disconnect_track(tr)
  for cat = 1, -1, -1 do                   -- 1 = hardware outs, 0 = sends, -1 = receives
    for i = reaper.GetTrackNumSends(tr, cat) - 1, 0, -1 do
      reaper.RemoveTrackSend(tr, cat, i)
    end
  end
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', -1)
  reaper.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
end

-- duplicates a track with everything (FX, parameters, routing, level...)
function duplicate_track(tr)
  local prev = save_selection()
  reaper.Main_OnCommand(40297, 0)
  reaper.SetTrackSelected(tr, true)
  reaper.Main_OnCommand(40062, 0)          -- Track: Duplicate tracks
  local new = reaper.GetSelectedTrack(0, 0)
  restore_selection(prev)
  return new
end

-- naming, color and (optionally) disconnection shared by copies and templates
function finish_copy(new, src, suffix)
  reaper.GetSetMediaTrackInfo_String(new, 'P_NAME', PREFIX .. ' ' .. raw_name(src) .. ' ' .. suffix, true)
  if S.disconnect then disconnect_track(new) end
  local i = rack_index(src)
  local r, g, b = color_for_new(src, i and racks[i + 1] or nil)
  set_track_rgb(new, r, g, b)
end

function duplicate_rack(tr)
  with_undo('Rack: duplicate', function()
    local new = duplicate_track(tr)
    if new then finish_copy(new, tr, 'copy') end
  end)
  last_scan = -math.huge
end

-- same rack, same FX, but every FX re-added with its default parameters
function template_rack(tr)
  with_undo('Rack: new rack from template', function()
    local new = duplicate_track(tr)
    if not new then return end
    finish_copy(new, tr, 'template')
    reaper.GetSetMediaTrackInfo_String(new, EXT_BYPASS, '', true)

    local list = chain_info(new).list
    local names = {}
    for i, it in ipairs(list) do
      local ok, ident = reaper.TrackFX_GetNamedConfigParm(new, it.fx, 'fx_ident')
      names[i] = { name = it.name, ident = ok and ident or nil }
    end
    for i = #list, 1, -1 do reaper.TrackFX_Delete(new, list[i].fx) end
    for _, n in ipairs(names) do
      local idx = reaper.TrackFX_AddByName(new, n.name, false, -1)
      if idx < 0 and n.ident then reaper.TrackFX_AddByName(new, n.ident, false, -1) end
    end
  end)
  last_scan = -math.huge
end

-- a new empty rack after the last rack: no FX, no routing, default name
function create_rack()
  with_undo('Rack: new rack', function()
    local last = racks[#racks]
    local idx = last and math.floor(reaper.GetMediaTrackInfo_Value(last, 'IP_TRACKNUMBER'))
                or reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(idx, true)
    local tr = reaper.GetTrack(0, idx)
    if not tr then return end

    local n = #racks + 1
    local function used(name)
      for _, t in ipairs(racks) do if raw_name(t) == name then return true end end
      return false
    end
    while used('Rack ' .. n) do n = n + 1 end
    reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', PREFIX .. ' Rack ' .. n, true)
    disconnect_track(tr)
    local r, g, b = color_for_new(last, nil)
    set_track_rgb(tr, r, g, b)
  end)
  last_scan = -math.huge
end

-- moves a rack in the project track order (the panel follows track order)
function reorder_rack(src, dst)
  if src == dst then return end
  local sn = reaper.GetMediaTrackInfo_Value(src, 'IP_TRACKNUMBER')
  local dn = reaper.GetMediaTrackInfo_Value(dst, 'IP_TRACKNUMBER')
  if sn < 1 or dn < 1 then return end
  local before = (sn < dn) and dn or (dn - 1)   -- 0-based index to insert before
  with_undo('Rack: reorder racks', function()
    local prev = save_selection()
    reaper.Main_OnCommand(40297, 0)
    reaper.SetTrackSelected(src, true)
    reaper.ReorderSelectedTracks(before, 0)
    restore_selection(prev)
  end)
  last_scan = -math.huge
end

---------------------------------------------------------------- routing

function in_text(tr)
  local parts = {}
  if reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1 then
    local rin = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'))
    if rin >= 0 then
      if rin & 4096 ~= 0 then
        parts[#parts + 1] = 'MIDI'
      else
        local idx, pre = rin & 1023, ''
        if idx >= 512 then idx = idx - 512; pre = 'Rt ' end
        if rin & 2048 ~= 0 then
          parts[#parts + 1] = pre .. (idx + 1) .. '+'
        elseif rin & 1024 ~= 0 then
          parts[#parts + 1] = ('%s%d/%d'):format(pre, idx + 1, idx + 2)
        else
          parts[#parts + 1] = pre .. (idx + 1)
        end
      end
    end
  end
  local nrcv = reaper.GetTrackNumSends(tr, -1)
  if nrcv > 0 then parts[#parts + 1] = 'rcv x' .. nrcv end
  if #parts == 0 then return '-' end
  return table.concat(parts, ', ')
end

function out_text(tr)
  local parts = {}
  for i = 0, reaper.GetTrackNumSends(tr, 1) - 1 do
    local d = math.floor(reaper.GetTrackSendInfo_Value(tr, 1, i, 'I_DSTCHAN'))
    local idx = d & 1023
    if d & 1024 ~= 0 then
      parts[#parts + 1] = tostring(idx + 1)
    else
      parts[#parts + 1] = ('%d/%d'):format(idx + 1, idx + 2)
    end
  end
  local ns = reaper.GetTrackNumSends(tr, 0)
  if ns > 0 then parts[#parts + 1] = 'snd x' .. ns end
  if #parts == 0 then return '-' end
  return table.concat(parts, ', ')
end

function set_input(tr, val)
  if val < 0 then
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 0)
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', -1)
  else
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', val)
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECMODE', 2)   -- monitor only, never record
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON', 1)
    reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
  end
end

function set_hw_out(tr, dst)
  for i = reaper.GetTrackNumSends(tr, 1) - 1, 0, -1 do
    reaper.RemoveTrackSend(tr, 1, i)
  end
  if dst then
    local idx = reaper.CreateTrackSend(tr, nil)
    reaper.SetTrackSendInfo_Value(tr, 1, idx, 'I_DSTCHAN', dst)
  end
end

---------------------------------------------------------------- add FX menu

-- Built from REAPER's own FX list (and, when it can be read, the folders
-- from the FX browser). Built once, on first use. The FX type (VST3, AU,
-- JS...) is part of every menu entry, so versions of the same FX can be told apart.
function read_ini(path)
  local secs = {}
  local f = io.open(path, 'r')
  if not f then return secs end
  local cur = nil
  for line in f:lines() do
    local s = line:match('^%[(.-)%]%s*$')
    if s then
      cur = {}
      secs[s] = cur
    elseif cur then
      local k, v = line:match('^([^=]+)=(.*)$')
      if k then cur[k] = (v:gsub('\r$', '')) end
    end
  end
  f:close()
  return secs
end

function type_rank(name)
  for i, n in ipairs(TYPE_ORDER) do
    if n == name then return i end
  end
  return 100
end

function sort_items(items)
  table.sort(items, function(a, b)
    local la, lb = a.label:lower(), b.label:lower()
    if la ~= lb then return la < lb end
    return type_rank(a.type) < type_rank(b.type)
  end)
end

function sorted_groups(map, by_type)
  local out = {}
  for name, items in pairs(map) do
    sort_items(items)
    out[#out + 1] = { name = name, items = items }
  end
  table.sort(out, function(a, b)
    if by_type then
      local ra, rb = type_rank(a.name), type_rank(b.name)
      if ra ~= rb then return ra < rb end
    end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

function build_fx_db()
  local by_type, by_dev = {}, {}
  local idx_name, idx_ident, idx_label = {}, {}, {}
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    i = i + 1
    local ftype, rest = name:match('^([%w_]+):%s*(.*)$')
    if not ftype then ftype, rest = 'Other', name end
    local dev = rest:match('%(([^()]+)%)%s*$') or 'Other'
    local it = { name = name, ident = ident, label = rest, type = ftype }
    by_type[ftype] = by_type[ftype] or {}
    table.insert(by_type[ftype], it)
    by_dev[dev] = by_dev[dev] or {}
    table.insert(by_dev[dev], it)
    idx_name[name:lower()] = it
    if ident then idx_ident[ident:lower()] = it end
    idx_label[rest:lower()] = it
  end

  -- folders of the FX browser (best effort: the file is only read, never written)
  local folders = {}
  local secs = read_ini(reaper.GetResourcePath() .. '/reaper-fxfolders.ini')
  local fs = secs['Folders']
  if fs then
    local n = 0
    while fs['Folder' .. n] do
      local fname = fs['Folder' .. n]
      local sec = secs['Folder' .. n] or secs[fname]
      if sec then
        local items = {}
        local k = 0
        while sec['Item' .. k] do
          local v = sec['Item' .. k]:lower()
          local it = idx_name[v] or idx_ident[v] or idx_label[v]
          if it then items[#items + 1] = it end
          k = k + 1
        end
        if #items > 0 then
          sort_items(items)
          folders[#folders + 1] = { name = fname, items = items }
        end
      end
      n = n + 1
    end
  end

  return {
    folders = folders,
    devs    = sorted_groups(by_dev, false),
    types   = sorted_groups(by_type, true),
  }
end

-- the FX tree without the FX types switched off in Options > FX types
function get_view()
  if not fx_db then fx_db = build_fx_db() end
  local key = table.concat(hidden_list(), ',')
  if fx_view and fx_view_key == key then return fx_view end

  local function visible(items)
    local out = {}
    for _, it in ipairs(items) do
      if not S.hidden[it.type] then out[#out + 1] = it end
    end
    return out
  end
  local v = { folders = {}, devs = {}, types = {} }
  for _, g in ipairs(fx_db.folders) do
    local items = visible(g.items)
    if #items > 0 then v.folders[#v.folders + 1] = { name = g.name, items = items } end
  end
  for _, g in ipairs(fx_db.devs) do
    local items = visible(g.items)
    if #items > 0 then v.devs[#v.devs + 1] = { name = g.name, items = items } end
  end
  for _, g in ipairs(fx_db.types) do
    if not S.hidden[g.name] then v.types[#v.types + 1] = g end
  end
  fx_view, fx_view_key = v, key
  return v
end

function draw_fx_items(items, on_pick)
  if #items <= LONG_LIST then
    for _, it in ipairs(items) do
      if ig.MenuItem(ctx, it.name .. '##' .. it.ident) then on_pick(it) end
    end
    return
  end
  local groups, order = {}, {}
  for _, it in ipairs(items) do
    local ch = it.label:sub(1, 1):upper()
    if not ch:match('%a') then ch = '#' end
    if not groups[ch] then groups[ch] = {}; order[#order + 1] = ch end
    table.insert(groups[ch], it)
  end
  table.sort(order)
  for _, ch in ipairs(order) do
    if ig.BeginMenu(ctx, ch) then
      for _, it in ipairs(groups[ch]) do
        if ig.MenuItem(ctx, it.name .. '##' .. it.ident) then on_pick(it) end
      end
      ig.EndMenu(ctx)
    end
  end
end

-- the FX tree; `on_pick(item)` is called with the chosen FX
function draw_add_menu(on_pick)
  local view = get_view()

  for _, fld in ipairs(view.folders) do
    if ig.BeginMenu(ctx, fld.name .. '##fld') then
      draw_fx_items(fld.items, on_pick)
      ig.EndMenu(ctx)
    end
  end
  if #view.folders > 0 then ig.Separator(ctx) end

  if ig.BeginMenu(ctx, 'Developers') then
    for _, g in ipairs(view.devs) do
      if ig.BeginMenu(ctx, g.name .. '##dev') then
        draw_fx_items(g.items, on_pick)
        ig.EndMenu(ctx)
      end
    end
    ig.EndMenu(ctx)
  end
  if ig.BeginMenu(ctx, 'All FX') then
    for _, g in ipairs(view.types) do
      if ig.BeginMenu(ctx, g.name .. '##typ') then
        draw_fx_items(g.items, on_pick)
        ig.EndMenu(ctx)
      end
    end
    ig.EndMenu(ctx)
  end
end

---------------------------------------------------------------- scan / setup

function add_meter(tr, stage, slot)
  local idx = reaper.TrackFX_AddByName(tr, 'JS:' .. METER_PATH, false, -1)
  if idx < 0 then idx = reaper.TrackFX_AddByName(tr, 'JS: ' .. METER_NAME, false, -1) end
  if idx < 0 then return nil end
  reaper.TrackFX_SetParam(tr, idx, 0, slot)
  reaper.TrackFX_SetParam(tr, idx, 1, stage)
  return idx
end

function ensure_setup(tr, slot)
  slot = math.min(slot, 255)

  -- racks are never routed to the master
  if reaper.GetMediaTrackInfo_Value(tr, 'B_MAINSEND') ~= 0 then
    reaper.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
  end

  local changed = false
  if reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP') ~= 0 then
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0); changed = true
  end
  if reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER') ~= 0 then
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0); changed = true
  end

  local info = chain_info(tr)

  -- troubleshooting switch: no meters, so no meter JSFX in the audio path either
  if S.no_meters then
    local gone = {}
    for _, fx in ipairs(info.legacy) do gone[#gone + 1] = fx end
    for _, fx in ipairs(info.extras) do gone[#gone + 1] = fx end
    if info.in_fx then gone[#gone + 1] = info.in_fx end
    if info.out_fx then gone[#gone + 1] = info.out_fx end
    table.sort(gone, function(a, b) return a > b end)
    for _, fx in ipairs(gone) do reaper.TrackFX_Delete(tr, fx) end
    if changed then
      reaper.TrackList_AdjustWindows(false)
      reaper.UpdateArrange()
    end
    return
  end

  -- v0.2 meters and duplicates go away
  local kill = {}
  for _, fx in ipairs(info.legacy) do kill[#kill + 1] = fx end
  for _, fx in ipairs(info.extras) do kill[#kill + 1] = fx end
  if #kill > 0 then
    table.sort(kill, function(a, b) return a > b end)
    for _, fx in ipairs(kill) do reaper.TrackFX_Delete(tr, fx) end
    info = chain_info(tr)
  end

  -- input meter: always the first FX
  if not info.in_fx then
    local idx = add_meter(tr, 0, slot)
    if idx then move_fx(tr, idx, 0)
    else meter_error = 'Could not add the meter JSFX. Restart REAPER or refresh the FX list.' end
    info = chain_info(tr)
  elseif info.in_fx ~= 0 then
    move_fx(tr, info.in_fx, 0)
    info = chain_info(tr)
  end

  -- output meter: always the last FX
  if not info.out_fx then
    local idx = add_meter(tr, 1, slot)
    if idx then move_fx(tr, idx, reaper.TrackFX_GetCount(tr) - 1)
    else meter_error = 'Could not add the meter JSFX. Restart REAPER or refresh the FX list.' end
    info = chain_info(tr)
  elseif info.out_fx ~= reaper.TrackFX_GetCount(tr) - 1 then
    move_fx(tr, info.out_fx, reaper.TrackFX_GetCount(tr) - 1)
    info = chain_info(tr)
  end

  for _, fx in ipairs({ info.in_fx or -1, info.out_fx or -1 }) do
    if fx >= 0 then
      local cur = reaper.TrackFX_GetParam(tr, fx, 0)
      if math.floor(cur + 0.5) ~= slot then reaper.TrackFX_SetParam(tr, fx, 0, slot) end
    end
  end

  if changed then
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
  end
end

function scan()
  local found = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if is_rack_name(track_name(tr)) then found[#found + 1] = tr end
  end
  racks = found
  meter_error = nil
  for i, tr in ipairs(racks) do ensure_setup(tr, i - 1) end
end

---------------------------------------------------------------- system stats (status bar)

-- REAPER has no script function for its Performance Meter, so CPU and memory
-- come from the operating system (macOS and Linux). Latency is reported by REAPER.
-- On macOS the numbers are fetched in the background and read back from a
-- small file, so the panel never waits for them.
STATS = {
  kind = nil, pid = nil, ncpu = 1, memtotal = nil,
  cpu = nil, ram_pct = nil, ram_mb = nil,
  seq = -1, launch_n = 0, launch_t = -math.huge, sample_t = {},
  prev_cpu = nil, prev_t = nil,
  latency = nil, latency_tip = nil, lat_t = -math.huge,
}

function init_stats()
  local osn = reaper.GetOS() or ''
  if osn:find('OSX') or osn:find('mac') then
    local ok, out = pcall(reaper.ExecProcess,
      '/bin/sh -c "echo $PPID; sysctl -n hw.memsize; sysctl -n hw.ncpu"', 3000)
    if ok and out then
      local nums = {}
      for n in out:gmatch('%d+') do nums[#nums + 1] = tonumber(n) end
      if #nums >= 4 then
        STATS.kind, STATS.pid, STATS.memtotal, STATS.ncpu = 'mac', nums[2], nums[3], math.max(1, nums[4])
      end
    end
  elseif osn:find('Linux') then
    local f = io.open('/proc/meminfo', 'r')
    if f then
      local kb = f:read('*a'):match('MemTotal:%s+(%d+)')
      f:close()
      STATS.memtotal = kb and tonumber(kb) * 1024 or nil
    end
    local n = 0
    f = io.open('/proc/cpuinfo', 'r')
    if f then
      for line in f:lines() do if line:match('^processor') then n = n + 1 end end
      f:close()
    end
    STATS.ncpu = math.max(1, n)
    STATS.kind = 'linux'
  end
end

function update_stats(cpu_secs, rss_kb, t)
  if STATS.prev_t and t - STATS.prev_t > 0.2 then
    local pct = (cpu_secs - STATS.prev_cpu) / (t - STATS.prev_t) / STATS.ncpu * 100
    STATS.cpu = clamp(pct, 0, 100)
  end
  STATS.prev_cpu, STATS.prev_t = cpu_secs, t
  STATS.ram_mb = rss_kb / 1024
  if STATS.memtotal then
    STATS.ram_pct = clamp(rss_kb * 1024 / STATS.memtotal * 100, 0, 100)
  end
end

function poll_latency(now)
  if now - STATS.lat_t < STATS_EVERY then return end
  STATS.lat_t = now
  local ok, inl, outl = pcall(reaper.GetInputOutputLatency)
  local ok2, _, sr = pcall(reaper.GetAudioDeviceInfo, 'SRATE', '')
  local ok3, _, bs = pcall(reaper.GetAudioDeviceInfo, 'BSIZE', '')
  sr = ok2 and tonumber(sr) or nil
  bs = ok3 and tonumber(bs) or nil
  if ok and inl and outl and sr and sr > 0 then
    STATS.lat_in  = math.floor(inl / sr * 1000 + 0.5)
    STATS.lat_out = math.floor(outl / sr * 1000 + 0.5)
    STATS.latency_tip = ('Input / output latency reported by REAPER%s'):format(
      (bs and sr) and ('\n%d samples at %d Hz'):format(bs, sr) or '')
  else
    STATS.lat_in, STATS.lat_out, STATS.latency_tip = nil, nil, nil
  end
end

function poll_stats(now)
  poll_latency(now)
  if STATS.kind == 'mac' then
    local f = io.open(STATS_FILE, 'r')
    if f then
      local line = f:read('*l')
      f:close()
      local seq, t, rss = (line or ''):match('^(%d+)%s+(%S+)%s+(%d+)')
      seq = tonumber(seq)
      if seq and seq ~= STATS.seq then
        STATS.seq = seq
        local secs = 0
        for p in t:gmatch('[^:]+') do secs = secs * 60 + (tonumber(p) or 0) end
        update_stats(secs, tonumber(rss), STATS.sample_t[seq] or now)
        STATS.sample_t[seq] = nil
      end
    end
    if now - STATS.launch_t >= STATS_EVERY then
      STATS.launch_t = now
      STATS.launch_n = STATS.launch_n + 1
      STATS.sample_t[STATS.launch_n] = now
      STATS.sample_t[STATS.launch_n - 20] = nil
      reaper.ExecProcess(('/bin/sh -c "echo %d $(ps -o time=,rss= -p %d) > %s.tmp; mv %s.tmp %s"')
        :format(STATS.launch_n, STATS.pid, STATS_FILE, STATS_FILE, STATS_FILE), -1)
    end
  elseif STATS.kind == 'linux' then
    if now - STATS.launch_t >= STATS_EVERY then
      STATS.launch_t = now
      local f = io.open('/proc/self/stat', 'r')
      local g = io.open('/proc/self/statm', 'r')
      if f and g then
        local s = f:read('*l') or ''
        local rest = s:match('%) (.*)$') or ''
        local tk = {}
        for w in rest:gmatch('%S+') do tk[#tk + 1] = w end
        local secs = ((tonumber(tk[12]) or 0) + (tonumber(tk[13]) or 0)) / 100
        local pages = tonumber((g:read('*l') or ''):match('^%d+%s+(%d+)')) or 0
        update_stats(secs, pages * 4, now)
      end
      if f then f:close() end
      if g then g:close() end
    end
  end
end

---------------------------------------------------------------- text boxes

-- Returns the new text only when the user commits (Enter or click away).
function text_edit(key, current, width)
  local st = edit_state[key]
  if not st then st = { text = current, active = false }; edit_state[key] = st end

  -- one blank frame makes ImGui drop the active text box (used after a reset)
  if st.skip then
    st.skip = false
    st.active = false
    ig.Dummy(ctx, width, ig.GetFrameHeight(ctx))
    return nil
  end

  local shown = st.active and st.text or current
  ig.SetNextItemWidth(ctx, width)
  local rv, new = ig.InputText(ctx, '##' .. key, shown, ig.InputTextFlags_AutoSelectAll())
  if rv then st.text = new end
  local active = ig.IsItemActive(ctx)
  if active and not st.active then st.text = shown end
  local committed = nil
  if ig.IsItemDeactivatedAfterEdit(ctx) then committed = new end
  st.active = active
  return committed
end

function parse_db(s)
  s = s:lower():gsub(',', '.')
  if s:find('inf') then return -math.huge end
  return tonumber(s:match('[-+]?%d*%.?%d+'))
end

function apply_level(tr, text)
  local v = parse_db(text)
  if not v then return end
  if v <= LEVEL_MIN then
    reaper.SetMediaTrackInfo_Value(tr, 'D_VOL', 0.0)
  else
    reaper.SetMediaTrackInfo_Value(tr, 'D_VOL', 10.0 ^ (clamp(v, LEVEL_MIN, LEVEL_MAX) / 20.0))
  end
end

function rename_rack(tr, text)
  text = text:match('^%s*(.-)%s*$')
  if text == raw_name(tr) then return end
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', (text == '') and PREFIX or (PREFIX .. ' ' .. text), true)
end

---------------------------------------------------------------- meters

function new_meter_state()
  return {
    lv_in    = { -150, -150 }, lv_out   = { -150, -150 },
    hold_in  = { -150, -150 }, hold_out = { -150, -150 },
    clip_in  = { false, false }, clip_out = { false, false },
    cnt = -1, stale = 0,
  }
end

-- one click on any meter resets every peak hold line and clip marker
function reset_markers()
  for _, m in pairs(meters) do
    m.hold_in  = { -150, -150 }; m.hold_out = { -150, -150 }
    m.clip_in  = { false, false }; m.clip_out = { false, false }
  end
end

function mark(hold, clip, i, db)
  if db > hold[i] then hold[i] = db end
  if db >= CLIP_DB then clip[i] = true end
end

-- reads (and clears) one stage of one rack from gmem
function read_stage(base)
  local pl  = reaper.gmem_read(base)
  local pr  = reaper.gmem_read(base + 1)
  local cnt = reaper.gmem_read(base + 2)
  local sl  = reaper.gmem_read(base + 3)
  local sr  = reaper.gmem_read(base + 4)
  local n   = reaper.gmem_read(base + 5)
  reaper.gmem_write(base, 0)
  reaper.gmem_write(base + 1, 0)
  reaper.gmem_write(base + 3, 0)
  reaper.gmem_write(base + 4, 0)
  reaper.gmem_write(base + 5, 0)
  return pl, pr, cnt, sl, sr, n
end

function draw_bar(dl, x, y1, y2, w, level, hold, clipped)
  ig.DrawList_AddRectFilled(dl, x, y1, x + w, y2, T.meter_bg, 2)
  for _, z in ipairs(ZONES) do
    if level > z[1] then
      local top = math.min(level, z[2])
      local ya = y2 - meter_frac(top) * (y2 - y1)
      local yb = y2 - meter_frac(z[1]) * (y2 - y1)
      ig.DrawList_AddRectFilled(dl, x, ya, x + w, yb, z[3])
    end
  end
  if hold > METER_MIN then
    local yh = y2 - meter_frac(hold) * (y2 - y1)
    ig.DrawList_AddLine(dl, x, yh, x + w, yh, clipped and 0xFF4040FF or T.hold, 2)
  end
end

function draw_meter(dl, x, y1, y2, lv, hold, clip, id)
  local bw  = (METER_W - 2) / 2
  local by1 = y1 + CLIP_H + 2
  ig.DrawList_AddRectFilled(dl, x, y1, x + bw, y1 + CLIP_H,
                            clip[1] and 0xFF2020FF or T.clip_off, 2)
  ig.DrawList_AddRectFilled(dl, x + bw + 2, y1, x + METER_W, y1 + CLIP_H,
                            clip[2] and 0xFF2020FF or T.clip_off, 2)
  draw_bar(dl, x, by1, y2, bw, lv[1], hold[1], clip[1])
  draw_bar(dl, x + bw + 2, by1, y2, bw, lv[2], hold[2], clip[2])

  ig.SetCursorScreenPos(ctx, x, y1)
  if ig.InvisibleButton(ctx, id, METER_W, y2 - y1) then reset_markers() end
  if ig.IsItemHovered(ctx) then
    ig.SetTooltip(ctx, 'Click to reset peak hold and clip markers (all racks)')
  end
end

---------------------------------------------------------------- racks

function set_status(guid, text, secs)
  status[guid] = { text = text, untl = reaper.time_precise() + secs }
end

function metrics()
  local fh = ig.GetFrameHeight(ctx)
  local spx, spy = ig.GetStyleVar(ctx, ig.StyleVar_ItemSpacing())
  local fpx, fpy = ig.GetStyleVar(ctx, ig.StyleVar_FramePadding())
  local tlh = ig.GetTextLineHeight(ctx)
  return {
    fh = fh, spx = spx, spy = spy, fpx = fpx, fpy = fpy, tlh = tlh,
    sm = math.floor(fh * 0.85),                       -- small buttons
    btn_h = math.floor(fh * 1.35),                    -- bypass / mute
    name_h = name_font and (NAME_FONT_SIZE + 8) or (fh + 4),
    rowp = fh + spy,
  }
end

-- the three sections of a rack: header, FX, controls
function section_heights(n_fx, M)
  local rows = math.max(n_fx, 1)
  local hdr = SI + M.name_h + M.spy + M.fh + SI
  local fxs = SI + rows * M.rowp + M.sm + SI
  local ctl = SI + M.fh + M.spy + M.btn_h + SI
  return hdr, fxs, ctl
end

function natural_height(n_fx, M)
  local hdr, fxs, ctl = section_heights(n_fx, M)
  return PAD + hdr + SG + fxs + SG + ctl + PAD
end

-- a round "radio" checkbox: ring with a dot inside when on
function circle_check(dl, id, x, y, d, checked)
  ig.SetCursorScreenPos(ctx, x, y)
  local clicked = ig.InvisibleButton(ctx, id, d, d)
  local hovered = ig.IsItemHovered(ctx)
  local cx, cy, r = x + d / 2, y + d / 2, d / 2 - 2
  ig.DrawList_AddCircleFilled(dl, cx, cy, r, T.chk_bg, 0)
  ig.DrawList_AddCircle(dl, cx, cy, r, hovered and 0x6FB4FFFF or T.chk_ring, 0, 2)
  if checked then ig.DrawList_AddCircleFilled(dl, cx, cy, r - 4, T.chk_dot, 0) end
  return clicked
end

-- a drop target that appends to the FX of a rack
function drop_zone(id, x, y, w, h, tr, append_idx)
  ig.SetCursorScreenPos(ctx, x, y)
  ig.InvisibleButton(ctx, id, w, h)
  if drag_prev_fx and mouse_in(x, y, x + w, y + h) then
    ig.DrawList_AddRect(ig.GetWindowDrawList(ctx), x, y, x + w, y + h, T.glow, ROUNDING, 0, 2)
  end
  if ig.BeginDragDropTarget(ctx) then
    local ok, payload = ig.AcceptDragDropPayload(ctx, 'RACKFX')
    if ok then
      pending_ops[#pending_ops + 1] = { payload = payload, dst_tr = tr, dst = append_idx }
    end
    ig.EndDragDropTarget(ctx)
  end
end

function draw_rack(info, x0, y0, H, M, dt, now)
  local tr = info.tr
  local guid = reaper.GetTrackGUID(tr)
  local list = info.list
  local bypassed = info.bypassed
  local col = track_color(tr)
  local slot = math.min(info.slot, 255)
  local locked = is_locked()
  local selected = rack_selected(tr)
  local metering = not S.no_meters

  ------------------------------------------------ meter data
  local m = meters[guid]
  if not m then m = new_meter_state(); meters[guid] = m end

  local pl, pr = 0, 0
  local sl_i, sr_i, n_i = 0, 0, 0
  local sl_o, sr_o, n_o = 0, 0, 0
  if metering and info.in_fx then
    local cnt
    pl, pr, cnt, sl_i, sr_i, n_i = read_stage(slot * STRIDE)
    if cnt ~= m.cnt then m.cnt = cnt; m.stale = 0 else m.stale = m.stale + 1 end
    if m.stale > 8 then pl, pr = 0, 0 end
  end
  if metering and info.out_fx then
    local _, _, _, a, b, n = read_stage(slot * STRIDE + 8)
    sl_o, sr_o, n_o = a, b, n
  end

  if metering then
    local ol = reaper.Track_GetPeakInfo(tr, 0)
    local o_r = reaper.Track_GetPeakInfo(tr, 1)
    local fall = METER_FALL * dt
    local din_l, din_r = amp_to_db(pl), amp_to_db(pr)
    local dout_l, dout_r = amp_to_db(ol), amp_to_db(o_r)
    m.lv_in[1]  = math.max(din_l,  m.lv_in[1]  - fall)
    m.lv_in[2]  = math.max(din_r,  m.lv_in[2]  - fall)
    m.lv_out[1] = math.max(dout_l, m.lv_out[1] - fall)
    m.lv_out[2] = math.max(dout_r, m.lv_out[2] - fall)
    mark(m.hold_in,  m.clip_in,  1, din_l);  mark(m.hold_in,  m.clip_in,  2, din_r)
    mark(m.hold_out, m.clip_out, 1, dout_l); mark(m.hold_out, m.clip_out, 2, dout_r)
  end

  ------------------------------------------------ level match (RMS)
  if not metering then matches[guid] = nil end
  local mt = matches[guid]
  if mt then
    if mt.first then
      mt.first = false      -- the first read holds stale accumulated data
    elseif n_i > 0 and n_o > 0 then
      local in_pow = (sl_i + sr_i) / (2 * n_i)
      if in_pow > 10.0 ^ (MATCH_GATE / 10.0) then
        mt.sin  = mt.sin  + (sl_i + sr_i);  mt.nin  = mt.nin  + 2 * n_i
        mt.sout = mt.sout + (sl_o + sr_o);  mt.nout = mt.nout + 2 * n_o
        mt.frames = mt.frames + 1
      end
    end
    if now - mt.t0 >= MATCH_SECS then
      matches[guid] = nil
      if not (info.in_fx and info.out_fx) then
        set_status(guid, 'Match: meters missing', 4)
      elseif mt.frames < 20 then
        set_status(guid, 'Match: not enough signal', 4)
      elseif mt.sout <= 0 then
        set_status(guid, 'Match: output silent', 4)
      else
        -- the end-of-chain meter sits before the fader, so the fader
        -- value that makes output = input is simply the (negated) chain gain
        local chain_db = 10.0 * math.log((mt.sout / mt.nout) / (mt.sin / mt.nin), 10)
        local new_db = clamp(-chain_db, LEVEL_MIN, LEVEL_MAX)
        reaper.SetMediaTrackInfo_Value(tr, 'D_VOL', 10.0 ^ (new_db / 20.0))
        set_status(guid, ('Matched: %.1f dB'):format(new_db), 4)
      end
    end
  end

  ------------------------------------------------ geometry
  local fh, spx, spy, sm = M.fh, M.spx, M.spy, M.sm
  local hdr_h, fxs_h, ctl_h = section_heights(#list, M)

  local cx  = x0 + PAD + METER_W + GAP         -- middle area
  local wx  = cx + SI                          -- widgets inside a section
  local WW  = CENTER_W - 2 * SI                -- widget width

  local hdr_top = y0 + PAD
  local hdr_bot = hdr_top + hdr_h
  local ctl_bot = y0 + H - PAD
  local ctl_top = ctl_bot - ctl_h
  local fxs_top = hdr_bot + SG
  local fxs_bot = ctl_top - SG

  local name_y = hdr_top + SI
  local io_y   = name_y + M.name_h + spy
  local lvl_y  = ctl_top + SI
  local btn_y  = lvl_y + fh + spy
  local add_y  = fxs_bot - SI - sm

  ------------------------------------------------ frame, sections
  local dl = ig.GetWindowDrawList(ctx)
  local c = rack_colors(col, bypassed)
  if selected then
    -- selection glow: rings that fade out away from the rack
    local base = T.glow & 0xFFFFFF00
    for i = 1, GLOW_M do
      local a = math.floor(170 * (1 - (i - 1) / GLOW_M) ^ 2)
      ig.DrawList_AddRect(dl, x0 - i, y0 - i, x0 + RACK_W + i, y0 + H + i,
                          base | a, ROUNDING + 2 + i, 0, 1)
    end
  end
  ig.DrawList_AddRectFilled(dl, x0, y0, x0 + RACK_W, y0 + H, c.bg, ROUNDING + 2)
  ig.DrawList_AddRect(dl, x0, y0, x0 + RACK_W, y0 + H,
                      selected and mix(c.border, T.glow, 0.6) or c.border, ROUNDING + 2, 0, selected and 3 or 2)

  local function section(y1, y2)
    ig.DrawList_AddRectFilled(dl, cx, y1, cx + CENTER_W, y2, c.sec_bg, ROUNDING)
    ig.DrawList_AddRect(dl, cx, y1, cx + CENTER_W, y2, c.sec_bd, ROUNDING, 0, 1)
  end
  section(hdr_top, hdr_bot)
  section(fxs_top, fxs_bot)
  section(ctl_top, ctl_bot)

  -- the drag preview of this rack: its outline, sections and name, as a see-through shape
  local function rack_ghost()
    local gx, gy = ig.GetCursorScreenPos(ctx)
    local gdl = ig.GetWindowDrawList(ctx)
    local dx, dy = gx - x0, gy - y0
    local function fade(rgba, a) return (rgba & 0xFFFFFF00) | a end
    ig.DrawList_AddRectFilled(gdl, gx, gy, gx + RACK_W, gy + H, fade(c.bg, 0xC8), ROUNDING + 2)
    ig.DrawList_AddRect(gdl, gx, gy, gx + RACK_W, gy + H, c.border, ROUNDING + 2, 0, 3)
    for _, sec in ipairs({ { hdr_top, hdr_bot }, { fxs_top, fxs_bot }, { ctl_top, ctl_bot } }) do
      ig.DrawList_AddRectFilled(gdl, cx + dx, sec[1] + dy, cx + dx + CENTER_W, sec[2] + dy, fade(c.sec_bg, 0xB0), ROUNDING)
      ig.DrawList_AddRect(gdl, cx + dx, sec[1] + dy, cx + dx + CENTER_W, sec[2] + dy, fade(c.sec_bd, 0xFF), ROUNDING, 0, 1)
    end
    ig.DrawList_AddRectFilled(gdl, wx + dx, name_y + dy, wx + dx + WW, name_y + dy + M.name_h, c.name_bg, ROUNDING)
    local nm = fit_text(raw_name(tr) ~= '' and raw_name(tr) or '(unnamed)', WW - 8)
    ig.DrawList_AddText(gdl, wx + dx + (WW - ig.CalcTextSize(ctx, nm)) / 2,
                        name_y + dy + (M.name_h - ig.GetTextLineHeight(ctx)) / 2, c.name_txt, nm)
    ig.Dummy(ctx, RACK_W, H)
  end

  ig.PushID(ctx, guid)

  ------------------------------------------------ routing + Rack Option Menu (round, above the meters)
  local by = name_y + (M.name_h - METER_W) / 2

  lock_begin(locked)
  ig.SetCursorScreenPos(ctx, x0 + PAD, by)
  push_native()
  ig.PushStyleVar(ctx, ig.StyleVar_FrameRounding(), METER_W / 2)
  if ig.Button(ctx, 'R##route', METER_W, METER_W) then open_routing(tr) end
  ig.PopStyleVar(ctx)
  pop_native()
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'Routing window') end

  ig.SetCursorScreenPos(ctx, x0 + RACK_W - PAD - METER_W, by)
  ig.PushStyleVar(ctx, ig.StyleVar_FrameRounding(), METER_W / 2)
  if ig.Button(ctx, '...##opt', METER_W, METER_W) then ig.OpenPopup(ctx, 'rack_opt') end
  ig.PopStyleVar(ctx)
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'Rack Option Menu') end
  lock_end(locked)

  if ig.BeginPopup(ctx, 'rack_opt') then
    local n_sel = #targets_for(tr)
    if n_sel > 1 then
      ig.TextDisabled(ctx, ('Applies to the %d selected racks'):format(n_sel))
      ig.Separator(ctx)
    end
    if ig.MenuItem(ctx, 'Level match', nil, false, metering) then
      rack_action(tr, 'Level match', function(t)
        matches[reaper.GetTrackGUID(t)] = { t0 = reaper.time_precise(), first = true, sin = 0, nin = 0, sout = 0, nout = 0, frames = 0 }
      end)
    end
    ig.Separator(ctx)
    if ig.MenuItem(ctx, 'Duplicate rack') then rack_action(tr, 'Duplicate rack', duplicate_rack) end
    if ig.MenuItem(ctx, 'Use as template (default parameters)') then
      rack_action(tr, 'Use as template', template_rack)
    end
    ig.Separator(ctx)
    if ig.MenuItem(ctx, 'Recolor automatically') then rack_action(tr, 'Recolor automatically', recolor_rack_auto) end
    if ig.MenuItem(ctx, 'Choose color...') then open_picker('rack', tr) end
    ig.Separator(ctx)
    if ig.MenuItem(ctx, 'Remove every FX') then rack_action(tr, 'Remove every FX', remove_all_fx) end
    if ig.MenuItem(ctx, 'Remove bypassed FX') then
      rack_action(tr, 'Remove bypassed FX', remove_bypassed_fx)
    end
    ig.Separator(ctx)
    if ig.MenuItem(ctx, 'Revert to regular track') then rack_action(tr, 'Revert to regular track', revert_to_track) end
    if ig.MenuItem(ctx, 'Delete rack...') then
      local trs = targets_for(tr)
      if #trs > 1 then
        request_confirm(('Delete the %d selected racks and all of their FX?\n(Ctrl+Z brings them back.)')
                        :format(#trs), function()
          for _, t in ipairs(trs) do if valid(t) then delete_rack(t) end end
        end, 'Delete')
      else
        request_confirm(('Delete the rack "%s" and all of its FX?\n(Ctrl+Z brings it back.)')
                        :format(raw_name(tr)), function() delete_rack(tr) end, 'Delete')
      end
    end
    ig.EndPopup(ctx)
  end

  ------------------------------------------------ name (bold, centered)
  local ns = name_state[guid]
  if not ns then ns = { editing = false }; name_state[guid] = ns end
  local pushed = push_bold(name_font, NAME_FONT_SIZE)
  ig.SetCursorScreenPos(ctx, wx, name_y)
  if locked then ns.editing = false end

  if ns.editing then
    if ns.fresh then ig.SetKeyboardFocusHere(ctx); ns.fresh = false end
    ig.PushStyleColor(ctx, ig.Col_Text(), c.name_txt)
    ig.PushStyleColor(ctx, ig.Col_FrameBg(), c.name_bg)
    ig.SetNextItemWidth(ctx, WW)
    local rv, new = ig.InputText(ctx, '##nm', ns.text, ig.InputTextFlags_AutoSelectAll())
    ig.PopStyleColor(ctx, 2)
    if rv then ns.text = new end
    local active = ig.IsItemActive(ctx)
    if active then ns.was_active = true end
    if ig.IsItemDeactivatedAfterEdit(ctx) then rename_rack(tr, new) end
    if ns.was_active and not active then ns.editing = false; ns.was_active = false end
  else
    ig.DrawList_AddRectFilled(dl, wx, name_y, wx + WW, name_y + M.name_h, c.name_bg, ROUNDING)
    ig.InvisibleButton(ctx, 'name', WW, M.name_h)
    -- click selects the rack (REAPER's track selection); Cmd/Ctrl-click adds or removes it
    if ig.IsItemClicked(ctx, 0) then select_rack(tr, has_mod('ctrl')) end
    local txt = fit_text(raw_name(tr) ~= '' and raw_name(tr) or '(unnamed)', WW - 8)
    local tw = ig.CalcTextSize(ctx, txt)
    local lh = ig.GetTextLineHeight(ctx)
    ig.DrawList_AddText(dl, wx + (WW - tw) / 2, name_y + (M.name_h - lh) / 2, c.name_txt, txt)

    if not locked then
      if ig.IsItemHovered(ctx) then
        if ig.IsMouseDoubleClicked(ctx, 0) then
          ns.editing, ns.text, ns.fresh, ns.was_active = true, raw_name(tr), true, false
        end
      end
      -- drag the name to reorder racks: the whole rack follows the cursor as a ghost
      if ig.BeginDragDropSource(ctx) then
        ig.SetDragDropPayload(ctx, 'RACKMOVE', guid)
        drag_now_rack = guid
        rack_ghost()
        ig.EndDragDropSource(ctx)
      end
    end
  end
  if pushed then ig.PopFont(ctx) end

  ------------------------------------------------ In / Out
  local iow = (WW - spx) / 2
  lock_begin(locked)
  ig.SetCursorScreenPos(ctx, wx, io_y)
  if ig.Button(ctx, 'In: ' .. in_text(tr) .. '##in', iow, fh) then ig.OpenPopup(ctx, 'in_pop') end
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'Input: ' .. in_text(tr)) end

  ig.SetCursorScreenPos(ctx, wx + iow + spx, io_y)
  if ig.Button(ctx, 'Out: ' .. out_text(tr) .. '##out', iow, fh) then ig.OpenPopup(ctx, 'out_pop') end
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'Output: ' .. out_text(tr)) end
  lock_end(locked)

  if ig.BeginPopup(ctx, 'in_pop') then
    local cur   = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'))
    local armed = reaper.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 1
    if ig.MenuItem(ctx, 'None (receives only)', nil, (not armed) or cur < 0) then set_input(tr, -1) end
    local n = reaper.GetNumAudioInputs()
    if ig.BeginMenu(ctx, 'Mono input') then
      for i = 0, n - 1 do
        local nm = reaper.GetInputChannelName(i) or ''
        if ig.MenuItem(ctx, ('%d  %s'):format(i + 1, nm), nil, armed and cur == i) then set_input(tr, i) end
      end
      ig.EndMenu(ctx)
    end
    if ig.BeginMenu(ctx, 'Stereo input') then
      for i = 0, n - 2 do
        local nm = reaper.GetInputChannelName(i) or ''
        if ig.MenuItem(ctx, ('%d/%d  %s'):format(i + 1, i + 2, nm), nil, armed and cur == (i | 1024)) then
          set_input(tr, i | 1024)
        end
      end
      ig.EndMenu(ctx)
    end
    local midi_all = 4096 | (63 << 5)
    if ig.MenuItem(ctx, 'MIDI (all devices, all channels)', nil, armed and cur == midi_all) then
      set_input(tr, midi_all)
    end
    ig.EndPopup(ctx)
  end

  if ig.BeginPopup(ctx, 'out_pop') then
    local nh = reaper.GetTrackNumSends(tr, 1)
    local d0 = (nh == 1) and math.floor(reaper.GetTrackSendInfo_Value(tr, 1, 0, 'I_DSTCHAN')) or nil
    if ig.MenuItem(ctx, 'No hardware output', nil, nh == 0) then set_hw_out(tr, nil) end
    local n = reaper.GetNumAudioOutputs()
    if ig.BeginMenu(ctx, 'Hardware out: stereo pair') then
      for i = 0, n - 2 do
        local nm = reaper.GetOutputChannelName(i) or ''
        if ig.MenuItem(ctx, ('%d/%d  %s'):format(i + 1, i + 2, nm), nil, d0 == i) then set_hw_out(tr, i) end
      end
      ig.EndMenu(ctx)
    end
    if ig.BeginMenu(ctx, 'Hardware out: mono') then
      for i = 0, n - 1 do
        local nm = reaper.GetOutputChannelName(i) or ''
        if ig.MenuItem(ctx, ('%d  %s'):format(i + 1, nm), nil, d0 == (i | 1024)) then set_hw_out(tr, i | 1024) end
      end
      ig.EndMenu(ctx)
    end
    ig.EndPopup(ctx)
  end

  ------------------------------------------------ FX section
  local fxs_y = fxs_top + SI
  local append_idx = info.out_fx or reaper.TrackFX_GetCount(tr)

  for k, it in ipairs(list) do
    local fx = it.fx
    local y = fxs_y + (k - 1) * M.rowp
    local fx_guid = reaper.TrackFX_GetFXGUID(tr, fx)

    if circle_check(dl, '##en' .. fx, wx, y, fh, it.enabled) then
      reaper.TrackFX_SetEnabled(tr, fx, not it.enabled)
    end

    ig.SetCursorScreenPos(ctx, wx + fh + spx, y)
    push_native()
    if not it.enabled then ig.PushStyleColor(ctx, ig.Col_Text(), T.dim) end
    if ig.Button(ctx, clean_fx_name(it.name) .. '##fx' .. fx, WW - fh - spx, fh) then
      if reaper.TrackFX_GetFloatingWindow(tr, fx) then
        reaper.TrackFX_Show(tr, fx, 2)
      else
        reaper.TrackFX_Show(tr, fx, 3)
      end
    end
    if not it.enabled then ig.PopStyleColor(ctx) end
    pop_native()

    -- drag: reorder, copy or move (also to another rack); edit mode only
    local fx_key = guid .. '|' .. fx
    if not locked and ig.BeginDragDropSource(ctx) then
      ig.SetDragDropPayload(ctx, 'RACKFX', fx_key)
      drag_now_fx = fx_key
      local hint = ''
      if has_mod(COPY_MOD) then hint = '  (copy)' elseif has_mod(MOVE_MOD) then hint = '  (move)' end
      draw_fx_ghost(clean_fx_name(it.name), hint, WW - fh - spx, fh)
      ig.EndDragDropSource(ctx)
    end
    if drag_prev_fx == fx_key then
      -- the FX being dragged stays behind, faded
      ig.DrawList_AddRectFilled(dl, wx, y, wx + WW, y + fh, S.daylight and 0xFFFFFF99 or 0x00000099, ROUNDING)
    elseif drag_prev_fx and not locked and mouse_in(wx, y, wx + WW, y + fh) then
      -- the slot the dragged FX would take
      ig.DrawList_AddRect(dl, wx - 1, y - 1, wx + WW + 1, y + fh + 1, T.glow, ROUNDING, 0, 2)
    end
    if not locked and ig.BeginDragDropTarget(ctx) then
      local ok, payload = ig.AcceptDragDropPayload(ctx, 'RACKFX')
      if ok then
        pending_ops[#pending_ops + 1] = { payload = payload, dst_tr = tr, dst = fx }
      end
      ig.EndDragDropTarget(ctx)
    end

    -- right-click: insert, replace, delete (edit mode only)
    if not locked and ig.BeginPopupContextItem(ctx, 'fx_ctx' .. fx) then
      if ig.BeginMenu(ctx, 'Insert FX') then
        draw_add_menu(function(item) insert_fx_at(tr, item.ident, fx) end)
        ig.EndMenu(ctx)
      end
      if ig.BeginMenu(ctx, 'Replace FX') then
        draw_add_menu(function(item)
          request_confirm(('Replace "%s" with "%s"?'):format(clean_fx_name(it.name), item.name),
            function() replace_fx(tr, fx_guid, item.ident) end, 'Replace')
        end)
        ig.EndMenu(ctx)
      end
      if ig.MenuItem(ctx, 'Delete FX...') then
        request_confirm(('Delete "%s" from this rack?'):format(clean_fx_name(it.name)),
          function() delete_fx(tr, fx_guid) end, 'Delete')
      end
      ig.EndPopup(ctx)
    end
  end

  -- empty space of the section: "(no FX)" and the append drop zone
  local zone_y = fxs_y + #list * M.rowp
  if #list == 0 then
    ig.SetCursorScreenPos(ctx, wx, zone_y + M.fpy)
    ig.TextDisabled(ctx, '(no FX)')
  end
  if not locked and add_y - zone_y > 4 then
    drop_zone('dz', wx, zone_y, WW, add_y - zone_y, tr, append_idx)
  end

  ------------------------------------------------ + / status / A/B (part of the FX section)
  lock_begin(locked)
  ig.SetCursorScreenPos(ctx, wx, add_y)
  ig.PushStyleVar(ctx, ig.StyleVar_FrameRounding(), sm / 2)
  if ig.Button(ctx, '+##add', sm, sm) then ig.OpenPopup(ctx, 'add_pop') end
  ig.PopStyleVar(ctx)
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'Add an FX') end
  lock_end(locked)

  -- A/B: a rounded rectangle sized to its text
  local ab_w = ig.CalcTextSize(ctx, 'A/B') + 2 * M.fpx + 4
  ig.SetCursorScreenPos(ctx, wx + WW - ab_w, add_y)
  if ig.Button(ctx, 'A/B##ab', ab_w, sm) then ab_invert(tr) end
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'A/B: invert the enabled state of every FX') end

  local mid_x, mid_w = wx + sm + spx, WW - sm - ab_w - 2 * spx
  local stx = nil
  if matches[guid] then
    stx = ('Matching... %ds'):format(math.max(0, math.ceil(MATCH_SECS - (now - matches[guid].t0))))
  elseif status[guid] and now < status[guid].untl then
    stx = status[guid].text
  end
  if stx and mid_w > 10 then
    local t = fit_text(stx, mid_w)
    local tw = ig.CalcTextSize(ctx, t)
    ig.SetCursorScreenPos(ctx, mid_x + (mid_w - tw) / 2, add_y + (sm - M.tlh) / 2)
    ig.TextDisabled(ctx, t)
  end
  if not locked and mid_w > 10 then drop_zone('dz2', mid_x, add_y, mid_w, sm, tr, append_idx) end

  ig.SetNextWindowPos(ctx, wx, add_y + sm, ig.Cond_Appearing())
  if ig.BeginPopup(ctx, 'add_pop') then
    draw_add_menu(function(item) add_fx_to_rack(tr, item.ident) end)
    ig.EndPopup(ctx)
  end

  ------------------------------------------------ controls section
  local vol = reaper.GetMediaTrackInfo_Value(tr, 'D_VOL')
  local txt = (vol > 0.000001) and ('%.1f'):format(amp_to_db(vol)) or '-inf'
  ig.SetCursorScreenPos(ctx, wx, lvl_y)
  local lv = text_edit(guid .. ':lvl', txt, WW - 30 - spx)
  -- Shift + double-click resets the level to 0 dB
  if ig.IsItemHovered(ctx) and ig.IsMouseDoubleClicked(ctx, 0) and has_mod('shift') then
    reaper.SetMediaTrackInfo_Value(tr, 'D_VOL', 1.0)
    local st = edit_state[guid .. ':lvl']
    if st then st.skip = true; st.active = false end
    lv = nil
  end
  if lv then apply_level(tr, lv) end
  ig.SetCursorScreenPos(ctx, wx + WW - 30, lvl_y + M.fpy)
  ig.Text(ctx, 'dB')

  local hw = (WW - spx) / 2
  ig.SetCursorScreenPos(ctx, wx, btn_y)
  if bypassed then ig.PushStyleColor(ctx, ig.Col_Button(), T.byp) end
  if ig.Button(ctx, 'BYPASS##byp', hw, M.btn_h) then set_bypass(tr, not bypassed) end
  if bypassed then ig.PopStyleColor(ctx) end

  ig.SetCursorScreenPos(ctx, wx + hw + spx, btn_y)
  local muted = reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1
  if muted then ig.PushStyleColor(ctx, ig.Col_Button(), T.mute) end
  if ig.Button(ctx, 'MUTE##mute', hw, M.btn_h) then
    reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', muted and 0 or 1)
  end
  if muted then ig.PopStyleColor(ctx) end

  ------------------------------------------------ meters: from under the name to the bottom of the buttons
  -- a rack is being dragged: fade the original, outline the one under the cursor and drop on it
  if drag_prev_rack then
    if drag_prev_rack == guid then
      ig.DrawList_AddRectFilled(dl, x0, y0, x0 + RACK_W, y0 + H, S.daylight and 0xFFFFFF99 or 0x00000099, ROUNDING + 2)
    elseif not locked and mouse_in(x0, y0, x0 + RACK_W, y0 + H) then
      ig.DrawList_AddRect(dl, x0 - 2, y0 - 2, x0 + RACK_W + 2, y0 + H + 2, T.glow, ROUNDING + 4, 0, 3)
      if ig.IsMouseReleased(ctx, 0) then
        pending_racks[#pending_racks + 1] = { src = drag_prev_rack, dst = tr }
      end
    end
  end

  if metering then
    local my1, my2 = io_y, btn_y + M.btn_h
    draw_meter(dl, x0 + PAD, my1, my2, m.lv_in, m.hold_in, m.clip_in, 'min')
    draw_meter(dl, x0 + RACK_W - PAD - METER_W, my1, my2, m.lv_out, m.hold_out, m.clip_out, 'mout')
  end

  ig.PopID(ctx)
end

---------------------------------------------------------------- window

-- carries out the drag and drop requests collected while drawing
function apply_pending()
  if #pending_ops > 0 then
    local ops = pending_ops
    pending_ops = {}
    with_undo('Rack: move/copy FX', function()
      for _, op in ipairs(ops) do
        local g, s = op.payload:match('^(.-)|(%d+)$')
        local src_tr = g and rack_by_guid(g)
        local src = tonumber(s)
        if src_tr and src and valid(op.dst_tr) then
          if src_tr == op.dst_tr then
            if has_mod(COPY_MOD) then
              reaper.TrackFX_CopyToTrack(src_tr, src, op.dst_tr, op.dst, false)
            else
              move_fx(src_tr, src, op.dst)
            end
          elseif has_mod(MOVE_MOD) then
            reaper.TrackFX_CopyToTrack(src_tr, src, op.dst_tr, op.dst, true)
          else
            reaper.TrackFX_CopyToTrack(src_tr, src, op.dst_tr, op.dst, false)
          end
        end
      end
    end)
  end

  if #pending_racks > 0 then
    local rr = pending_racks
    pending_racks = {}
    for _, r in ipairs(rr) do
      local src = rack_by_guid(r.src)
      if src and valid(r.dst) then reorder_rack(src, r.dst) end
    end
  end
end

-- the color picker and the confirmation dialog
function draw_dialogs()
  if picker.open then
    ig.OpenPopup(ctx, 'Color##picker')
    picker.open = false
  end
  if ig.BeginPopup(ctx, 'Color##picker') then
    if picker.kind == 'default' then
      ig.Text(ctx, 'Default rack color')
    elseif picker.trs and #picker.trs > 1 then
      ig.Text(ctx, ('Color for the %d selected racks'):format(#picker.trs))
    else
      ig.Text(ctx, 'Rack color')
    end
    local rv, new = ig.ColorPicker3(ctx, '##cp', picker.rgb)
    if rv then
      picker.rgb = new
      local r, g, b = (new >> 16) & 255, (new >> 8) & 255, new & 255
      if picker.kind == 'rack' then
        for _, t in ipairs(picker.trs or {}) do
          if valid(t) then set_track_rgb(t, r, g, b) end
        end
      else
        S.default_rgb = new
        save_setting('defcolor', new)
      end
    end
    if ig.Button(ctx, 'Close', 80, 0) then ig.CloseCurrentPopup(ctx) end
    ig.EndPopup(ctx)
  end

  if confirm then
    if confirm_open then
      ig.OpenPopup(ctx, 'Please confirm')
      confirm_open = false
    end
    local wx, wy = ig.GetWindowPos(ctx)
    local ww, wh = ig.GetWindowSize(ctx)
    ig.SetNextWindowPos(ctx, wx + ww / 2, wy + wh / 2, ig.Cond_Appearing(), 0.5, 0.5)
    local shown = ig.BeginPopupModal(ctx, 'Please confirm', nil, ig.WindowFlags_AlwaysAutoResize())
    if shown then
      ig.Text(ctx, confirm.text)
      ig.Separator(ctx)
      local yes = ig.Button(ctx, confirm.label, 110, 0)
      ig.SameLine(ctx)
      local no = ig.Button(ctx, 'Cancel', 110, 0)
      if yes then
        local f = confirm.yes
        confirm = nil
        ig.CloseCurrentPopup(ctx)
        f()
      elseif no then
        confirm = nil
        ig.CloseCurrentPopup(ctx)
      end
      ig.EndPopup(ctx)
    elseif not confirm_open then
      confirm = nil      -- closed some other way (Escape): treat as Cancel
    end
  end
end

-- a horizontal gauge with a label on it; frac = nil means "not available"
function draw_gauge(dl, id, x, y, w, h, frac, label, tip)
  ig.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.meter_bg, ROUNDING)
  if frac and frac > 0 then
    local col = (frac < 0.6) and 0x40C060FF or ((frac < 0.85) and 0xE0C040FF or 0xE04040FF)
    ig.DrawList_AddRectFilled(dl, x, y, x + math.max(2, w * frac), y + h, col, ROUNDING)
  end
  ig.DrawList_AddRect(dl, x, y, x + w, y + h, T.bar_border, ROUNDING, 0, 1)
  local tw = ig.CalcTextSize(ctx, label)
  local lh = ig.GetTextLineHeight(ctx)
  ig.DrawList_AddText(dl, x + (w - tw) / 2, y + (h - lh) / 2, T.gauge_text, label)
  ig.SetCursorScreenPos(ctx, x, y)
  ig.InvisibleButton(ctx, id, w, h)
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, tip) end
end

-- status bar: same size, border and color as the top bar
function draw_status_bar(dl, x, y, w, h, M, nracks, nfx)
  ig.DrawList_AddRect(dl, x, y, x + w, y + h, T.bar_border, ROUNDING, 0, 1)
  local gw = 140
  local gy = y + (h - M.fh) / 2
  local gx = x + 8

  local cpu_label = STATS.cpu and ('CPU %d%%'):format(math.floor(STATS.cpu + 0.5)) or 'CPU n/a'
  draw_gauge(dl, 'g_cpu', gx, gy, gw, M.fh, STATS.cpu and STATS.cpu / 100 or nil, cpu_label,
    STATS.cpu and 'REAPER process CPU, as a share of all cores'
              or 'Not available on this system')
  gx = gx + gw + 10

  local ram_label = STATS.ram_pct and ('RAM %d%%'):format(math.floor(STATS.ram_pct + 0.5)) or 'RAM n/a'
  local ram_tip = 'Not available on this system'
  if STATS.ram_mb then
    ram_tip = ('REAPER memory: %d MB'):format(math.floor(STATS.ram_mb + 0.5))
    if STATS.memtotal then ram_tip = ram_tip .. ('\nof %.1f GB installed'):format(STATS.memtotal / 1073741824) end
  end
  draw_gauge(dl, 'g_ram', gx, gy, gw, M.fh, STATS.ram_pct and STATS.ram_pct / 100 or nil, ram_label, ram_tip)
  gx = gx + gw + 14

  -- latency: "Latency: in [33] ms  -  out [11] ms", the numbers in gauge-style boxes
  local ty = y + (h - M.tlh) / 2
  local function label(s)
    ig.SetCursorScreenPos(ctx, gx, ty)
    ig.Text(ctx, s)
    gx = gx + ig.CalcTextSize(ctx, s) + 6
  end
  if STATS.lat_in and STATS.lat_out then
    local bw = ig.CalcTextSize(ctx, '0000') + 16
    label('Latency: in')
    draw_gauge(dl, 'g_lat_in', gx, gy, bw, M.fh, nil, ('%i'):format(STATS.lat_in), STATS.latency_tip)
    gx = gx + bw + 6
    label('ms  -  out')
    draw_gauge(dl, 'g_lat_out', gx, gy, bw, M.fh, nil, ('%i'):format(STATS.lat_out), STATS.latency_tip)
    gx = gx + bw + 6
    label('ms')
  else
    label('Latency: n/a')
  end

  -- rack and FX counts, bottom right
  local counts = ('%d rack(s)  |  %d FX'):format(nracks or 0, nfx or 0)
  local cw = ig.CalcTextSize(ctx, counts)
  local cx = x + w - cw - 10
  if cx > gx + 12 then
    ig.SetCursorScreenPos(ctx, cx, ty)
    ig.TextDisabled(ctx, counts)
  end
end

-- the scrolling part: every rack, tiled
function draw_rack_area(infos, M, dt, now, avail)
  local x_left, y_top = ig.GetCursorScreenPos(ctx)
  local limit = x_left + avail                       -- the scrollbar starts here
  local wx, y = x_left + GLOW_M, y_top + GLOW_M      -- room around the racks for the selection glow
  local rects = {}
  local grid_x, last_row_y, last_row_h, grid_cols_n = wx, y, 0, 1

  if #infos == 0 then
    ig.SetCursorScreenPos(ctx, wx, y)
    ig.Text(ctx, ('No tracks named "%s ..." found. Double-click here or use + to create a rack.'):format(PREFIX))
  else
    -- each row is as tall as its tallest rack
    local cols = math.max(1, math.floor((avail - 2 * GLOW_M + RACK_SPACE) / (RACK_W + RACK_SPACE)))
    local i = 1
    while i <= #infos do
      local row_h = 0
      for c = 0, cols - 1 do
        local inf = infos[i + c]
        if inf then row_h = math.max(row_h, inf.nat) end
      end
      -- the grid is centered as a whole: every row starts at the same left edge,
      -- so a shorter last row stays aligned with the row above it
      local grid_cols = math.min(cols, #infos)
      local grid_w = grid_cols * RACK_W + (grid_cols - 1) * RACK_SPACE
      local row_x = math.max(wx, x_left + math.floor((avail - grid_w) / 2))
      grid_x, last_row_y, last_row_h, grid_cols_n = row_x, y, row_h, cols
      for c = 0, cols - 1 do
        local inf = infos[i + c]
        if inf then
          local x = row_x + c * (RACK_W + RACK_SPACE)
          draw_rack(inf, x, y, row_h, M, dt, now)
          rects[#rects + 1] = { x, y, x + RACK_W, y + row_h }
        end
      end
      y = y + row_h + RACK_SPACE
      i = i + cols
    end
    y = y - RACK_SPACE
  end

  -- empty space: a click deselects the racks, a double-click offers a new rack
  if ig.IsWindowHovered(ctx) then
    local mx, my = ig.GetMousePos(ctx)
    local over_rack = false
    for _, r in ipairs(rects) do
      if mx >= r[1] and mx <= r[3] and my >= r[2] and my <= r[4] then over_rack = true; break end
    end
    if not over_rack and mx < limit then
      if ig.IsMouseClicked(ctx, 0) then deselect_racks() end
      if ig.IsMouseDoubleClicked(ctx, 0) and not is_locked() then
        request_confirm('Create a new rack?', create_rack, 'Create')
      end
    end
  end

  -- a rack dropped in the empty space around or below the racks goes to the last position
  if drag_prev_rack and not is_locked() and #infos > 0 then
    local last = infos[#infos].tr
    local src = rack_by_guid(drag_prev_rack)
    local area_x, area_y = ig.GetWindowPos(ctx)
    local _, area_h = ig.GetWindowSize(ctx)
    local mx, my = ig.GetMousePos(ctx)
    local in_area = mx >= area_x and mx < limit and my >= area_y and my <= area_y + area_h
    local over_rack = false
    for _, r in ipairs(rects) do
      if mx >= r[1] and mx <= r[3] and my >= r[2] and my <= r[4] then over_rack = true; break end
    end
    if src and src ~= last and in_area and not over_rack then
      -- show the free cell the rack would land in
      local used = (#infos - 1) % grid_cols_n + 1
      local sx, sy
      if used < grid_cols_n then
        sx, sy = grid_x + used * (RACK_W + RACK_SPACE), last_row_y
      else
        sx, sy = grid_x, last_row_y + last_row_h + RACK_SPACE
      end
      local gdl = ig.GetWindowDrawList(ctx)
      ig.DrawList_AddRectFilled(gdl, sx, sy, sx + RACK_W, sy + last_row_h, (T.glow & 0xFFFFFF00) | 0x28, ROUNDING + 2)
      ig.DrawList_AddRect(gdl, sx, sy, sx + RACK_W, sy + last_row_h, (T.glow & 0xFFFFFF00) | 0xC0, ROUNDING + 2, 0, 3)
      if ig.IsMouseReleased(ctx, 0) then
        pending_racks[#pending_racks + 1] = { src = drag_prev_rack, dst = last }
      end
    end
  end

  -- extend the scrollable area to the bottom of the last row
  ig.SetCursorScreenPos(ctx, wx, y)
  ig.Dummy(ctx, 1, GLOW_M + 2)
end

-- BeginChild takes a number (child flags) in recent ReaImGui and a boolean
-- (border) in older ones; try the number first and remember what works.
child_old_api = false
function begin_child(id, w, h)
  if not child_old_api then
    local ok, vis = pcall(ig.BeginChild, ctx, id, w, h, 0, 0)
    if ok then return vis end
    child_old_api = true
  end
  return ig.BeginChild(ctx, id, w, h, false, 0)
end

function draw(dt, now)
  drag_prev_rack, drag_prev_fx = drag_now_rack, drag_now_fx
  drag_now_rack, drag_now_fx = nil, nil

  local M  = metrics()
  local dl = ig.GetWindowDrawList(ctx)
  local padx, pady = ig.GetStyleVar(ctx, ig.StyleVar_WindowPadding())
  local sbw = ig.GetStyleVar(ctx, ig.StyleVar_ScrollbarSize())
  local ww, wh = ig.GetWindowSize(ctx)
  local win_x, win_y = ig.GetWindowPos(ctx)
  local wx, wy = ig.GetCursorScreenPos(ctx)
  local bar_w = ww - 2 * padx

  -- gather racks
  local infos, nfx = {}, 0
  for i, tr in ipairs(racks) do
    if valid(tr) then
      local info = chain_info(tr)
      info.tr = tr
      info.slot = i - 1
      info.bypassed = is_bypassed(tr, info.list)
      info.nat = natural_height(#info.list, M)
      nfx = nfx + #info.list
      infos[#infos + 1] = info
    end
  end

  ------------------------------------------------ top bar (stays put): Live Rack, centered | + Options
  local tb_h = math.max(M.fh + 8, title_font and (TITLE_FONT_SIZE + 12) or 0)
  ig.DrawList_AddRect(dl, wx, wy, wx + bar_w, wy + tb_h, T.bar_border, ROUNDING, 0, 1)

  local ow = 70
  local opt_x = wx + bar_w - ow - 4
  local plus_x = opt_x - M.fh - M.spx

  -- title, centered
  local tpushed = push_bold(title_font, TITLE_FONT_SIZE)
  local ttw = ig.CalcTextSize(ctx, 'Live Rack')
  local tlh = ig.GetTextLineHeight(ctx)
  local title_x = wx + (bar_w - ttw) / 2
  ig.DrawList_AddText(dl, title_x, wy + (tb_h - tlh) / 2, T.title, 'Live Rack')
  if tpushed then ig.PopFont(ctx) end

  -- mode switch, like a cue light: green = Edit, red = Show
  local editing = S.mode == 'edit'
  local cue = editing and T.cue_edit or T.cue_show
  local cue_label = editing and 'EDIT' or 'SHOW'
  local cue_w = ig.CalcTextSize(ctx, 'SHOW') + 36
  local cue_x, cue_y = wx + 6, wy + (tb_h - M.fh) / 2
  local halo = cue & 0xFFFFFF00
  for i = 1, 4 do
    local a = math.floor(130 * (1 - (i - 1) / 4) ^ 2)
    ig.DrawList_AddRect(dl, cue_x - i, cue_y - i, cue_x + cue_w + i, cue_y + M.fh + i,
                        halo | a, ROUNDING + i, 0, 1)
  end
  ig.DrawList_AddRectFilled(dl, cue_x, cue_y, cue_x + cue_w, cue_y + M.fh, cue, ROUNDING)
  ig.DrawList_AddCircleFilled(dl, cue_x + 12, cue_y + M.fh / 2, 4, mix(cue, WHITE, 0.8), 0)
  local cue_tw = ig.CalcTextSize(ctx, cue_label)
  ig.DrawList_AddText(dl, cue_x + 22 + (cue_w - 22 - cue_tw) / 2, cue_y + (M.fh - M.tlh) / 2, WHITE, cue_label)
  ig.SetCursorScreenPos(ctx, cue_x, cue_y)
  if ig.InvisibleButton(ctx, 'mode_switch', cue_w, M.fh) then
    set_mode(editing and 'show' or 'edit')
  end
  if ig.IsItemHovered(ctx) then
    ig.SetTooltip(ctx, editing
      and 'Edit mode: everything can be changed.\nClick to switch to Show mode.'
      or  'Show mode: racks and FX are locked.\nLevel, mute, bypass and FX on/off still work.\nClick to switch to Edit mode.')
  end

  -- a JSFX problem, if any, shows next to it
  if meter_error then
    local ex = cue_x + cue_w + 12
    ig.SetCursorScreenPos(ctx, ex, wy + (tb_h - M.tlh) / 2)
    ig.TextColored(ctx, 0xFF6060FF, fit_text(meter_error, math.max(40, title_x - ex - 8)))
  end

  -- + : new rack (edit mode only)
  lock_begin(is_locked())
  ig.SetCursorScreenPos(ctx, plus_x, wy + (tb_h - M.fh) / 2)
  ig.PushStyleVar(ctx, ig.StyleVar_FrameRounding(), M.fh / 2)
  if ig.Button(ctx, '+##newrack', M.fh, M.fh) then create_rack() end
  ig.PopStyleVar(ctx)
  if ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, 'New empty rack') end
  lock_end(is_locked())

  -- general options menu
  ig.SetCursorScreenPos(ctx, opt_x, wy + (tb_h - M.fh) / 2)
  if ig.Button(ctx, 'Options##opts', ow, M.fh) then ig.OpenPopup(ctx, 'opts_pop') end
  if ig.BeginPopup(ctx, 'opts_pop') then
    if ig.MenuItem(ctx, 'Recolor every rack', nil, false, not is_locked()) then recolor_every_rack() end
    if ig.MenuItem(ctx, 'Choose default color...') then open_picker('default') end
    if ig.MenuItem(ctx, 'New racks use automatic color', nil, S.color_mode == 'auto') then
      S.color_mode = 'auto'; save_setting('colormode', 'auto')
    end
    if ig.MenuItem(ctx, 'New racks use default color', nil, S.color_mode == 'default') then
      S.color_mode = 'default'; save_setting('colormode', 'default')
    end
    if ig.MenuItem(ctx, 'Daylight mode', nil, S.daylight) then
      S.daylight = not S.daylight
      save_setting('daylight', S.daylight and '1' or '0')
    end
    ig.Separator(ctx)
    if ig.MenuItem(ctx, 'Disconnect inputs/outputs on copy and template', nil, S.disconnect) then
      S.disconnect = not S.disconnect
      save_setting('disconnect', S.disconnect and '1' or '0')
    end
    ig.Separator(ctx)
    -- FX types that actually exist, with how many FX each has
    if ig.BeginMenu(ctx, 'FX types') then
      if not fx_db then fx_db = build_fx_db() end
      for _, g in ipairs(fx_db.types) do
        if ig.MenuItem(ctx, ('%s (%d)'):format(g.name, #g.items), nil, not S.hidden[g.name]) then
          if S.hidden[g.name] then S.hidden[g.name] = nil else S.hidden[g.name] = true end
          save_hidden()
        end
      end
      ig.Separator(ctx)
      if ig.MenuItem(ctx, 'All') then
        S.hidden = {}
        save_hidden()
      end
      if ig.MenuItem(ctx, 'None') then
        S.hidden = {}
        for _, g in ipairs(fx_db.types) do S.hidden[g.name] = true end
        save_hidden()
      end
      ig.EndMenu(ctx)
    end
    if ig.BeginMenu(ctx, 'Dock') then
      if ig.MenuItem(ctx, 'Floating') then dock_request = 0 end
      ig.Separator(ctx)
      for n = 1, 16 do
        if ig.MenuItem(ctx, 'Docker ' .. n) then dock_request = -n end
      end
      ig.EndMenu(ctx)
    end
    ig.Separator(ctx)
    -- troubleshooting: no meters, no Level match, and no meter JSFX in the racks
    if ig.MenuItem(ctx, 'Disable metering and Level match', nil, S.no_meters) then
      S.no_meters = not S.no_meters
      save_setting('nometers', S.no_meters and '1' or '0')
      last_scan = -math.huge          -- add or remove the meter JSFX right away
    end
    if ig.MenuItem(ctx, 'Settings...') then S.show_settings = true end
    ig.EndPopup(ctx)
  end

  ------------------------------------------------ racks (the only part that scrolls)
  local top = wy + tb_h + RACK_SPACE
  local sb_y = win_y + wh - pady - tb_h               -- status bar top
  local child_h = math.max(40, sb_y - RACK_SPACE - top)

  ig.SetCursorScreenPos(ctx, wx, top)
  if begin_child('racks', bar_w, child_h) then
    draw_rack_area(infos, M, dt, now, bar_w - sbw)
    ig.EndChild(ctx)
  end

  ------------------------------------------------ status bar (stays put)
  draw_status_bar(dl, wx, sb_y, bar_w, tb_h, M, #infos, nfx)

  apply_pending()
  draw_dialogs()
end

-- the settings window: edits SCHEMA values, saved as they change
function draw_settings()
  if not S.show_settings then return end
  ig.SetNextWindowSize(ctx, 440, 560, ig.Cond_FirstUseEver())
  local vis, open = ig.Begin(ctx, 'Live Rack Settings', true)
  if vis then
    local group, group_open = nil, false
    for _, e in ipairs(SCHEMA) do
      if e.group ~= group then
        group = e.group
        group_open = ig.CollapsingHeader(ctx, group, nil, (group == 'Colors') and ig.TreeNodeFlags_DefaultOpen() or 0)
      end
      if group_open then
        ig.SetNextItemWidth(ctx, 210)
        local label = e.label .. '##cfg_' .. e.key
        if e.kind == 'mod' then
          if ig.BeginCombo(ctx, label, CFG[e.key]) then
            for _, name in ipairs({ 'ctrl', 'shift', 'alt' }) do
              if ig.Selectable(ctx, name, CFG[e.key] == name) then
                CFG[e.key] = name
                save_cfg_value(e)
              end
            end
            ig.EndCombo(ctx)
          end
        else
          local rv, v
          if e.kind == 'i' then
            rv, v = ig.SliderInt(ctx, label, CFG[e.key], e.min, e.max, e.fmt)
          else
            rv, v = ig.SliderDouble(ctx, label, CFG[e.key], e.min, e.max, e.fmt)
          end
          if rv then CFG[e.key] = v end
          if ig.IsItemDeactivatedAfterEdit(ctx) then save_cfg_value(e) end
        end
        if e.tip and ig.IsItemHovered(ctx) then ig.SetTooltip(ctx, e.tip) end
      end
    end
    ig.Separator(ctx)
    ig.TextDisabled(ctx, 'Ctrl+click a slider to type a value.')
    if ig.Button(ctx, 'Reset to defaults', 150, 0) then
      request_confirm('Reset every setting in this window to its default?', reset_cfg, 'Reset')
    end
    ig.End(ctx)
  end
  if not open then S.show_settings = false end
end

---------------------------------------------------------------- main loop

-- global look: rounded corners everywhere; Daylight also swaps the colors
function push_theme()
  T = theme()
  ig.PushStyleVar(ctx, ig.StyleVar_FrameRounding(), ROUNDING)
  ig.PushStyleVar(ctx, ig.StyleVar_PopupRounding(), ROUNDING)
  local nc = 0
  if S.daylight then
    for _, e in ipairs(LIGHT_COLORS) do
      ig.PushStyleColor(ctx, ig['Col_' .. e[1]](), e[2])
      nc = nc + 1
    end
  end
  return nc
end

function pop_theme(nc)
  if nc > 0 then ig.PopStyleColor(ctx, nc) end
  ig.PopStyleVar(ctx, 2)
end

function loop()
  local now = reaper.time_precise()
  local dt = now - last_time
  last_time = now

  apply_settings()
  poll_stats(now)

  if now - last_scan > SCAN_EVERY then
    scan()
    last_scan = now
  end

  if ig.SetNextWindowSizeConstraints then
    ig.SetNextWindowSizeConstraints(ctx, MIN_W, MIN_H, 16384, 16384)
  end
  if force_size or not was_visible then
    ig.SetNextWindowSize(ctx, win_w, win_h, ig.Cond_Always())
    force_size = false
  else
    ig.SetNextWindowSize(ctx, win_w, win_h, ig.Cond_FirstUseEver())
  end
  if ig.SetNextWindowDockID then
    if dock_request ~= nil then
      ig.SetNextWindowDockID(ctx, dock_request, ig.Cond_Always())
      dock_request = nil
    elseif not dock_applied and saved_dock ~= 0 then
      ig.SetNextWindowDockID(ctx, saved_dock, ig.Cond_Once())
      dock_applied = true
    end
  end

  local nc = push_theme()
  local flags = ig.WindowFlags_NoScrollbar() | ig.WindowFlags_NoScrollWithMouse()
  local visible, open = ig.Begin(ctx, 'Live Rack', true, flags)
  if visible then
    -- remember size (and detect the "minimized" shrink)
    local docked = ig.IsWindowDocked(ctx)
    if not docked then
      local w, h = ig.GetWindowSize(ctx)
      local shrunk = prev_w and (w <= MIN_W + 1 and h <= MIN_H + 1)
                     and (prev_w > MIN_W + 40 or prev_h > MIN_H + 40)
      if shrunk then
        force_size = true
      else
        win_w, win_h = w, h
      end
      prev_w, prev_h = w, h
    end

    -- remember dock state
    local did = ig.GetWindowDockID(ctx)
    if did ~= cur_dock then
      cur_dock = did
      reaper.SetExtState(EXT_SECTION, 'dock', tostring(did or 0), true)
    end

    draw(dt, now)
    ig.End(ctx)
  end
  draw_settings()
  pop_theme(nc)
  was_visible = visible

  if open then reaper.defer(loop) end
end

---------------------------------------------------------------- start

load_cfg()
apply_settings()
init_stats()

if not install_jsfx() then
  reaper.MB('Could not write the meter JSFX into the Effects folder.', 'Live Rack', 0)
end
-- the meter JSFX files of earlier versions are no longer used (their instances are replaced automatically)
do
  local old_dir = reaper.GetResourcePath() .. '/Effects/RackPanel'
  os.remove(old_dir .. '/RackPanel_Meter')
  os.remove(old_dir .. '/RackPanel_InputMeter')
  os.remove(old_dir)                 -- only succeeds when the folder is empty
end
reaper.gmem_attach(GMEM)
reaper.defer(loop)
