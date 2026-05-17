-- @description WhisperX: word overlay bridge — presets & lines (ReaImGui → Video Processor)
-- @version 1.90
-- @author Bryan
-- @about
--   GUI for the WhisperX Video Processor overlay: subtitle text is taken from take markers only (no free typing).
--   Words: horizontal drag scales size; triple-stack uses ReaImGui drag–drop onto the previous word or “new phrase” (applied on drop). Ctrl+Shift+click makes a word the first of its phrase.
--   Triple-stack: cut zones between words create phrase/row breaks; marquee selection; Shift+click range. Layout auto-saves to the item (P_EXT) + bridge extstate when you change the word grid or other overlay parameters (no manual “save layout” required).
--   Triple-stack layout parameters can be stored in named presets (save/load/delete).
--   Motion tab: “Show words by” chooses phrase write-on, phrase visible from start, or single-word timing.
--   Phrase/row structure is stored in extstate and synced for the VP core parser.
--   Per-line size & randomize: jitter is stable until you move that row’s Randomize slider; row gap (% of fontPx). Apply/Save writes jitter to extstate for marker-sync.
--   "Re-read markers → VP" refreshes take marker times from the item and rewrites the Video Processor
--   (no undo per push). “Live VP” (on by default) rewrites VP when controls are idle; uncheck if chunk writes glitch.
--   Separate action “WhisperX word overlay live VP sync take markers.lua” watches markers.
--   “Save subtitle text to item” stores the editor in the media item’s extended state (P_EXT) so reopening the bridge restores it when it still matches markers.
--   Per-word styling and the word color palette are stored on that same item (separate P_EXT keys), so they do not carry over when you select a different item.
--   Triple-stack: optional max characters per visual row (UTF-8 length) plus ± range varied per phrase (stable seed until you move those sliders); row indent sliders use their own seed.
--   Requires ReaImGui and "WhisperX word overlay core.lua".

local r = reaper

do
  local t = (r.time_precise and r.time_precise()) or 0
  math.randomseed((math.floor(t * 65536 + (os.clock() or 0) * 1e6)) % 2147483647)
end

local WINDOW_TITLE = "WhisperX — word overlay bridge"
local SECTION = "BRYAN_WX_OVERLAY_UI"
--- Item-extended-state keys (survives project save; travels with the item).
local ITEM_EXT = {
  EDITOR = "P_EXT:BRYAN_WX_OVERLAY_EDITOR",
  WORD_STYLES = "P_EXT:BRYAN_WX_OVERLAY_WORD_STYLES",
  WORD_PALETTE = "P_EXT:BRYAN_WX_OVERLAY_WORD_PALETTE",
  ROW_SPACING = "P_EXT:BRYAN_WX_OVERLAY_ROW_SPACING",
}

--- Overview hint for triple-stack timing mode (matches `SHOW_WORDS_MODE` / state.ml_timing_mode).
local WX_TIMING_HINT = {
  [0] = "Whole phrase write-on",
  [1] = "Whole phrase visible from phrase start",
  [2] = "Single word only",
}

local ANIM_SCOPE_STR = "Every word\0First word of phrase\0First word of each row\0"
local ANIM_TYPE_STR =
  "None\0Fade\0Zoom In\0Zoom Out\0Slide Left\0Slide Right\0Slide Up\0Slide Down\0Whip Left\0Whip Right\0"
  .. "Pop\0Punch\0Squash (dir °)\0Stretch (dir °)\0Drop Bounce\0Rise Bounce\0Drift Left\0Drift Right\0Shake\0Jitter\0"
  .. "Wave\0Orbit\0Spiral\0Stamp\0Echo Trail\0Clone Burst\0Blur\0Custom\0Wipe Reveal\0"
--- Built-in type ids 0..28 (Blur=26, Custom=27, Wipe Reveal=28).
local ANIM_TYPE_MAX = 28
local ANIM_MAX_DUPES = 8
--- Word-animation type ids (one table keeps main-chunk local count under Lua 5.1’s 200 limit).
local ANIM_KIND = {
  SLIDE_LEFT = 4,
  SLIDE_RIGHT = 5,
  SLIDE_UP = 6,
  SLIDE_DOWN = 7,
  WHIP_LEFT = 8,
  WHIP_RIGHT = 9,
  PUNCH = 11,
  SQUASH = 12,
  STRETCH = 13,
  DROP_BOUNCE = 14,
  RISE_BOUNCE = 15,
  DRIFT_LEFT = 16,
  DRIFT_RIGHT = 17,
  SHAKE = 18,
  JITTER = 19,
  WAVE = 20,
  ORBIT = 21,
  SPIRAL = 22,
  ECHO_TRAIL = 24,
  CLONE_BURST = 25,
  BLUR = 26,
  CUSTOM = 27,
  WIPE_REVEAL = 28,
}
local ANIM_CURVE_STR = "Linear\0In Quad\0Out Quad\0InOut Quad\0In Exp\0Out Exp\0InOut Exp\0In Log\0Out Log\0Back Overshoot\0Elastic Bounce\0"
local ANIM_CURVE_MAX = 10
local ANIM_CURVE_BACK, ANIM_CURVE_ELASTIC = 9, 10
local ANIM_GRAPH_CURVE_SQUARE = 4
local ANIM_GRAPH_CURVE_IN_LOG = 5
local ANIM_GRAPH_CURVE_IN_EXP = 6
local ANIM_GRAPH_CURVE_STR = "Linear\0In Quad\0Out Quad\0InOut Quad\0Square\0In Log\0In Exp\0"
local ANIM_GRAPH_CURVE_MAX = 6
--- Path graph preview (must match core `ANIM_GRAPH_LOG_K` / `ANIM_GRAPH_EXP_A` for VP).
local ANIM_GRAPH_LOG_K = 99
local ANIM_GRAPH_EXP_A = 13.815511 -- ln(1e6); normalized (e^(a*u)-1)/(e^a-1)
local ANIM_AUTO_LANES = {
  { key = "motion", label = "motion", min = 0, max = 3, integer = false },
  { key = "wiggle", label = "wiggle", min = 0, max = 3, integer = false },
  { key = "scale", label = "scale", min = -1, max = 2, integer = false },
  { key = "fade", label = "fade", min = 0, max = 1, integer = false },
  { key = "blur", label = "blur", min = 0, max = 3, integer = false },
  { key = "bounce", label = "bounce", min = 0, max = 2, integer = false },
  { key = "ghost", label = "ghost", min = 0, max = 2, integer = false },
  { key = "dupes", label = "dupes", min = 1, max = ANIM_MAX_DUPES, integer = true },
  { key = "twist", label = "twist", min = -720, max = 720, integer = false },
  { key = "dir", label = "dir", min = -180, max = 180, integer = false },
}

local _, script_fn = r.get_action_context()
local script_dir = (script_fn or ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ""
local core_path = script_dir .. "/WhisperX word overlay core.lua"
local chunk, cerr = loadfile(core_path)
if not chunk then
  r.MB("Could not load:\n" .. core_path .. "\n" .. tostring(cerr), WINDOW_TITLE, 0)
  return
end
local W = chunk()
if type(W) ~= "table" or not W.build_eel_body then
  r.MB("Invalid core module: " .. core_path, WINDOW_TITLE, 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ok_imgui, ImGui = pcall(function()
  return require("imgui")("0.9.3")
end)
if not ok_imgui then
  ok_imgui, ImGui = pcall(function()
    return require("imgui")("0.9.2")
  end)
end
if not ok_imgui then
  r.MB("ReaImGui is required.\nInstall from ReaPack, then reload REAPER.", WINDOW_TITLE, 0)
  return
end

local wx_bridge_icon_images = {
  settings = nil,
  expand = nil,
  _attached_ctx = nil,
}

--- Icon PNGs live next to this script (`…/WhisperX Lyrics/icons`) or under `…/WhisperX Lyrics/icons`
--- when the bridge `.lua` sits directly under the scripts bundle folder.
local WX_ICON_DIR_CANDIDATES = {}
do
  local seen = {}
  local function add(dir)
    dir = tostring(dir or ""):gsub("\\", "/"):gsub("/+$", "")
    if dir == "" or seen[dir] then
      return
    end
    seen[dir] = true
    WX_ICON_DIR_CANDIDATES[#WX_ICON_DIR_CANDIDATES + 1] = dir
  end
  local base = (script_dir or ""):gsub("\\", "/"):gsub("/+$", "")
  add(base .. "/icons")
  add(base .. "/WhisperX Lyrics/icons")
  local up = base:match("^(.+)/[^/]+$")
  if up then
    add(up .. "/icons")
    add(up .. "/WhisperX Lyrics/icons")
  end
end

local function wx_bridge_icon_file_readable(path)
  path = tostring(path or "")
  if path == "" then
    return false
  end
  if r.APIExists and r.APIExists("file_exists") and r.file_exists(path) then
    return true
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function wx_bridge_icons_try_load(ctx)
  if not (ctx and ImGui.CreateImage and ImGui.Attach) then
    return
  end
  if wx_bridge_icon_images._attached_ctx == ctx then
    return
  end
  local function try_load_image(abs_path)
    if not wx_bridge_icon_file_readable(abs_path) then
      return nil
    end
    local ok, img = pcall(ImGui.CreateImage, abs_path)
    if not ok or not img then
      return nil
    end
    local ok2 = pcall(ImGui.Attach, ctx, img)
    if not ok2 then
      return nil
    end
    return img
  end
  local function load_first(field, names)
    if wx_bridge_icon_images[field] then
      return
    end
    for ni = 1, #names do
      local fname = names[ni]
      for di = 1, #WX_ICON_DIR_CANDIDATES do
        local abs_path = WX_ICON_DIR_CANDIDATES[di] .. "/" .. fname
        local img = try_load_image(abs_path)
        if img then
          wx_bridge_icon_images[field] = img
          return
        end
      end
    end
  end
  load_first("settings", { "settings.png" })
  load_first("expand", { "expand.png" })
  wx_bridge_icon_images._attached_ctx = ctx
end

--- ImageButton with optional tint; signature varies by ReaImGui build.
local function wx_bridge_image_button(ctx, id_str, img, sz, tint_abgr)
  if not (ctx and img and ImGui.ImageButton) then
    return false
  end
  tint_abgr = tonumber(tint_abgr) or 0xFFFFFFFF
  local ok, clicked = pcall(function()
    return ImGui.ImageButton(ctx, id_str, img, sz, sz, nil, nil, nil, nil, nil, tint_abgr)
  end)
  if ok then
    return clicked and true or false
  end
  ok, clicked = pcall(function()
    return ImGui.ImageButton(ctx, id_str, img, sz, sz)
  end)
  return ok and clicked and true or false
end

local function es_get(key, default)
  local v = r.GetExtState(SECTION, key)
  if type(v) ~= "string" or v == "" then
    return default
  end
  return v
end

local function es_bool(key, default)
  local s = r.GetExtState(SECTION, key)
  if s == nil or s == "" then
    return default
  end
  local sl = s:lower()
  if s == "0" or sl == "false" or sl == "off" or sl == "no" then
    return false
  end
  return true
end

--- Identity for “reload editor from item” only: item GUID + word count + each marker word text.
--- Marker *times* are intentionally omitted so retiming markers does not wipe the subtitle field.
local function overlay_source_key(item, words)
  local g = ""
  if item and r.GetSetMediaItemInfo_String then
    local ok, gg = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if ok and type(gg) == "string" and gg ~= "" then
      g = gg
    end
  end
  if not words or #words == 0 then
    return g .. "\0290"
  end
  local sep = "\029"
  local parts = { g, sep, tostring(#words), sep }
  for i = 1, #words do
    parts[#parts + 1] = words[i].w
    parts[#parts + 1] = sep
  end
  return table.concat(parts)
end

local function item_guid_str(item)
  if not item or not r.GetSetMediaItemInfo_String then
    return ""
  end
  local ok, gg = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok and type(gg) == "string" and gg ~= "" then
    return gg
  end
  return ""
end

local function read_editor_text_from_item(item)
  if not item or not r.GetSetMediaItemInfo_String then
    return nil
  end
  local ok, s = r.GetSetMediaItemInfo_String(item, ITEM_EXT.EDITOR, "", false)
  if ok and type(s) == "string" and s ~= "" then
    return s
  end
  return nil
end

local function write_editor_text_to_item(item, text)
  if not item or not r.GetSetMediaItemInfo_String then
    return false
  end
  return r.GetSetMediaItemInfo_String(item, ITEM_EXT.EDITOR, text or "", true)
end

local function migrate_ml_timing_mode_from_extstate()
  local sw = es_get("SHOW_WORDS_MODE", "")
  if sw ~= "" then
    local t = math.floor(tonumber(sw) or 1)
    return math.max(0, math.min(2, t))
  end
  local pi = tonumber(es_get("PRESET_IDX", "3")) or 3
  if pi == 4 then
    pi = 3
  end
  pi = math.max(0, math.min(3, math.floor(pi)))
  local k = es_bool("KARAOKE", true)
  if pi == 0 then
    return 2
  end
  if k then
    return 0
  end
  return 1
end

VIDEO_RATIO_GUIDES = {
  { id = "169", label = "16:9", key = "VIDEO_GUIDE_169", ratio = 16 / 9, color = 0x00E5FF },
  { id = "916", label = "9:16", key = "VIDEO_GUIDE_916", ratio = 9 / 16, color = 0xFF66CC },
  { id = "11", label = "1:1", key = "VIDEO_GUIDE_11", ratio = 1, color = 0xFFD447 },
  { id = "45", label = "4:5", key = "VIDEO_GUIDE_45", ratio = 4 / 5, color = 0x66FF66 },
  { id = "43", label = "4:3", key = "VIDEO_GUIDE_43", ratio = 4 / 3, color = 0xAA88FF },
  { id = "235", label = "2.35:1", key = "VIDEO_GUIDE_235", ratio = 2.35, color = 0xFF8844 },
}

local state = {
  ml_timing_mode = migrate_ml_timing_mode_from_extstate(),
  karaoke = false,
  words_per_line = tonumber(es_get("WORDS_PER_LINE", "8")) or 8,
  max_chars = tonumber(es_get("MAX_CHARS", "0")) or 0,
  break_sentence = es_bool("BREAK_SENTENCE", false),
  font_name = es_get("FONT_NAME", ""),
  editor_text = "",
  overlay_source_key = "",
  status = "",
  status_err = false,
  preview_parse_err = "",
  should_close = false,
  wx_settings_open = false,
  preview_words = 0,
  preview_lines = 0,
  preview_segs = 0,
  parse_hint = nil,
  --- Avoid reloading the subtitle field when take markers briefly read as empty (e.g. after refocus).
  tracked_item_guid = "",
  prev_words_count = 0,
  ml_max_rows = 4,
  ml_s = { 0.58, 2, 0.58, 1, 1, 1 },
  ml_r = { 0, 0, 0, 0, 0, 0 },
  ml_line_gap = 0.1,
  ml_jitter = { 0, 0, 0, 0, 0, 0 },
  ml_row_chars = 0,
  ml_row_chars_rand = 0,
  ml_row_v_align = 0,
  ml_chars_seed = 0,
  ml_indent_step = 0,
  ml_indent_rand = 0,
  ml_indent_seed = 0,
  anim_scope = math.max(0, math.min(2, math.floor(tonumber(es_get("ANIM_SCOPE", "0")) or 0))),
  anim_in_on = es_bool("ANIM_IN_ON", false),
  anim_in_type = math.max(0, math.min(128, math.floor(tonumber(es_get("ANIM_IN_TYPE", "1")) or 1))),
  anim_in_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(es_get("ANIM_IN_CURVE", "0")) or 0))),
  anim_in_dur = math.max(0, math.min(2.0, tonumber(es_get("ANIM_IN_DUR", "0.12")) or 0.12)),
  anim_in_amp = math.max(0, math.min(3.0, tonumber(es_get("ANIM_IN_AMP", "1")) or 1)),
  anim_out_on = es_bool("ANIM_OUT_ON", false),
  anim_out_type = math.max(0, math.min(128, math.floor(tonumber(es_get("ANIM_OUT_TYPE", "1")) or 1))),
  anim_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(es_get("ANIM_OUT_CURVE", "0")) or 0))),
  anim_out_dur = math.max(0, math.min(2.0, tonumber(es_get("ANIM_OUT_DUR", "0.12")) or 0.12)),
  anim_out_amp = math.max(0, math.min(3.0, tonumber(es_get("ANIM_OUT_AMP", "1")) or 1)),
  anim_phrase_out_on = es_bool("ANIM_PHRASE_OUT_ON", false),
  anim_phrase_out_type = math.max(0, math.min(128, math.floor(tonumber(es_get("ANIM_PHRASE_OUT_TYPE", es_get("ANIM_OUT_TYPE", "1"))) or 1))),
  anim_phrase_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(es_get("ANIM_PHRASE_OUT_CURVE", es_get("ANIM_OUT_CURVE", "0"))) or 0))),
  anim_phrase_out_dur = math.max(0, math.min(2.0, tonumber(es_get("ANIM_PHRASE_OUT_DUR", es_get("ANIM_OUT_DUR", "0.12"))) or 0.12)),
  anim_phrase_out_amp = math.max(0, math.min(3.0, tonumber(es_get("ANIM_PHRASE_OUT_AMP", es_get("ANIM_OUT_AMP", "1"))) or 1)),
  anim_in_bounce = math.max(0, math.min(2.0, tonumber(es_get("ANIM_IN_BOUNCE", es_get("ANIM_BOUNCE", "0.7"))) or 0.7)),
  anim_in_motion = math.max(0, math.min(3.0, tonumber(es_get("ANIM_IN_MOTION", es_get("ANIM_MOTION", "1"))) or 1)),
  anim_in_wiggle = math.max(0, math.min(3.0, tonumber(es_get("ANIM_IN_WIGGLE", es_get("ANIM_WIGGLE", "1"))) or 1)),
  anim_in_scale = math.max(-1.0, math.min(2.0, tonumber(es_get("ANIM_IN_SCALE", "0")) or 0)),
  anim_in_fade = math.max(0, math.min(1.0, tonumber(es_get("ANIM_IN_FADE", "0")) or 0)),
  anim_in_blur = math.max(0, math.min(3.0, tonumber(es_get("ANIM_IN_BLUR", "0")) or 0)),
  anim_in_ghost = math.max(0, math.min(2.0, tonumber(es_get("ANIM_IN_GHOST", es_get("ANIM_GHOST", "1"))) or 1)),
  anim_in_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(es_get("ANIM_IN_DUPES", "3")) or 3))),
  anim_in_dir = math.max(-180, math.min(180, tonumber(es_get("ANIM_IN_DIR", "90")) or 90)),
  anim_in_twist = math.max(-720, math.min(720, tonumber(es_get("ANIM_IN_TWIST", "0")) or 0)),
  anim_out_bounce = math.max(0, math.min(2.0, tonumber(es_get("ANIM_OUT_BOUNCE", es_get("ANIM_BOUNCE", "0.7"))) or 0.7)),
  anim_out_motion = math.max(0, math.min(3.0, tonumber(es_get("ANIM_OUT_MOTION", es_get("ANIM_MOTION", "1"))) or 1)),
  anim_out_wiggle = math.max(0, math.min(3.0, tonumber(es_get("ANIM_OUT_WIGGLE", es_get("ANIM_WIGGLE", "1"))) or 1)),
  anim_out_scale = math.max(-1.0, math.min(2.0, tonumber(es_get("ANIM_OUT_SCALE", "0")) or 0)),
  anim_out_fade = math.max(0, math.min(1.0, tonumber(es_get("ANIM_OUT_FADE", "0")) or 0)),
  anim_out_blur = math.max(0, math.min(3.0, tonumber(es_get("ANIM_OUT_BLUR", "0")) or 0)),
  anim_out_ghost = math.max(0, math.min(2.0, tonumber(es_get("ANIM_OUT_GHOST", es_get("ANIM_GHOST", "1"))) or 1)),
  anim_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(es_get("ANIM_OUT_DUPES", "3")) or 3))),
  anim_out_dir = math.max(-180, math.min(180, tonumber(es_get("ANIM_OUT_DIR", "90")) or 90)),
  anim_out_twist = math.max(-720, math.min(720, tonumber(es_get("ANIM_OUT_TWIST", "0")) or 0)),
  anim_phrase_out_bounce = math.max(0, math.min(2.0, tonumber(es_get("ANIM_PHRASE_OUT_BOUNCE", es_get("ANIM_OUT_BOUNCE", es_get("ANIM_BOUNCE", "0.7")))) or 0.7)),
  anim_phrase_out_motion = math.max(0, math.min(3.0, tonumber(es_get("ANIM_PHRASE_OUT_MOTION", es_get("ANIM_OUT_MOTION", es_get("ANIM_MOTION", "1")))) or 1)),
  anim_phrase_out_wiggle = math.max(0, math.min(3.0, tonumber(es_get("ANIM_PHRASE_OUT_WIGGLE", es_get("ANIM_OUT_WIGGLE", es_get("ANIM_WIGGLE", "1")))) or 1)),
  anim_phrase_out_scale = math.max(-1.0, math.min(2.0, tonumber(es_get("ANIM_PHRASE_OUT_SCALE", es_get("ANIM_OUT_SCALE", "0"))) or 0)),
  anim_phrase_out_fade = math.max(0, math.min(1.0, tonumber(es_get("ANIM_PHRASE_OUT_FADE", es_get("ANIM_OUT_FADE", "0"))) or 0)),
  anim_phrase_out_blur = math.max(0, math.min(3.0, tonumber(es_get("ANIM_PHRASE_OUT_BLUR", es_get("ANIM_OUT_BLUR", "0"))) or 0)),
  anim_phrase_out_ghost = math.max(0, math.min(2.0, tonumber(es_get("ANIM_PHRASE_OUT_GHOST", es_get("ANIM_OUT_GHOST", es_get("ANIM_GHOST", "1")))) or 1)),
  anim_phrase_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(es_get("ANIM_PHRASE_OUT_DUPES", es_get("ANIM_OUT_DUPES", "3"))) or 3))),
  anim_phrase_out_dir = math.max(-180, math.min(180, tonumber(es_get("ANIM_PHRASE_OUT_DIR", es_get("ANIM_OUT_DIR", "90"))) or 90)),
  anim_phrase_out_twist = math.max(-720, math.min(720, tonumber(es_get("ANIM_PHRASE_OUT_TWIST", es_get("ANIM_OUT_TWIST", "0"))) or 0)),
  anim_wipe_mask_offset = math.max(-300, math.min(300, tonumber(es_get("ANIM_WIPE_MASK_OFFSET", "0")) or 0)),
  anim_in_use_graph = es_bool("ANIM_IN_USE_GRAPH", false),
  anim_out_use_graph = es_bool("ANIM_OUT_USE_GRAPH", false),
  anim_phrase_out_use_graph = es_bool("ANIM_PHRASE_OUT_USE_GRAPH", false),
  anim_in_graph_word_span = es_bool("ANIM_IN_GRAPH_WORD_SPAN", false),
  anim_out_graph_word_span = es_bool("ANIM_OUT_GRAPH_WORD_SPAN", false),
  anim_phrase_out_graph_word_span = es_bool("ANIM_PHRASE_OUT_GRAPH_WORD_SPAN", false),
  anim_in_graph_blob = es_get("ANIM_IN_GRAPH", "0,0,0|0.65,0,1;0"),
  anim_out_graph_blob = es_get("ANIM_OUT_GRAPH", "0,0,0|0.65,0,1;0"),
  anim_phrase_out_graph_blob = es_get("ANIM_PHRASE_OUT_GRAPH", "0,0,0|0.65,0,1;0"),
  anim_in_graph_auto_blob = es_get("ANIM_IN_GRAPH_AUTO", ""),
  anim_out_graph_auto_blob = es_get("ANIM_OUT_GRAPH_AUTO", ""),
  anim_phrase_out_graph_auto_blob = es_get("ANIM_PHRASE_OUT_GRAPH_AUTO", ""),
  anim_graph_editor_open = false,
  anim_graph_editor_side_key = "in",
  anim_graph_editor_points = nil,
  anim_graph_editor_curves = nil,
  anim_graph_editor_blends = nil,
  anim_graph_editor_selected = 1,
  anim_graph_editor_drag_point = nil,
  anim_graph_editor_drag_t = nil,
  anim_graph_editor_popup_seg = nil,
  anim_graph_editor_auto_drag_lane = "",
  anim_graph_editor_auto_drag_point = nil,
  --- Graph segment drag: 1=In Log / Linear / In Exp (smooth vertical drag + Tab), 2=Quad family, 3=Square; X cycles families.
  anim_graph_seg_family_mode = 1,
  anim_graph_seg_mode1_bias0 = nil,
  --- Triple-stack: phrase_after[i] / row_after[i] for i = 1 .. n-1 (after word i). Word scales [1..n] for VP.
  ml_phrase_after = {},
  ml_row_after = {},
  ml_word_scales = {},
  ml_row_indents = {},
  ml_row_spacings = {},
  word_styles = {},
  word_color_palette = {},
  word_sel = {},
  word_anchor = nil,
  marquee_active = false,
  marquee_btn = 0,
  marquee_x0 = 0,
  marquee_y0 = 0,
  marquee_x1 = 0,
  marquee_y1 = 0,
  marquee_additive = false,
  --- Word grid triple-stack phrase row: gutter click seek + pulse (not persisted).
  wx_phrase_click_pulse_until = nil,
  wx_phrase_click_pulse_pi = nil,
  --- Word grid drag: nil until moved ~4px, then "scale" (horizontal) or "phrase" (vertical, triple only).
  word_drag_lock = nil,
  word_drag_acc_x = 0,
  word_drag_acc_y = 0,
  word_scale_tip_active = false,
  word_scale_tip_until = 0,
  --- Pixel height of words grid section (persisted in extstate).
  word_grid_h = tonumber(es_get("WORD_GRID_H", "240")) or 240,
  --- Show words panel in a separate floating window.
  word_grid_floating = es_bool("WORD_GRID_FLOAT", false),
  img_post_wave = es_bool("IMG_POST_WAVE", false),
  img_post_wave_amp = math.max(0, math.min(240, tonumber(es_get("IMG_POST_WAVE_AMP", "24")) or 24)),
  img_post_wave_len = math.max(8, math.min(2000, tonumber(es_get("IMG_POST_WAVE_LEN", "90")) or 90)),
  img_post_wave_speed = math.max(-20, math.min(20, tonumber(es_get("IMG_POST_WAVE_SPEED", "6")) or 6)),
  video_guides = {},
  current_play_word = nil,
  current_play_src = nil,
  _last_follow_word = nil,
  --- Pixel height of subtitle multiline field (persisted in extstate).
  editor_body_h = tonumber(es_get("EDITOR_BODY_H", "140")) or 140,
  _wig_rects = {},
  --- Fingerprint of last successful `auto_persist_layout` flush (subtitle + sliders + VP-affecting state).
  overlay_autosave_sig_saved = nil,
  overlay_autosave_force = false,
  ml_word_n = 0,
  ml_preset_names = {},
  ml_preset_idx = 0,
  ml_preset_name = es_get("ML_PRESET_LAST", ""),
  ml_preset_save_name = "",
  anim_preset_names = {},
  anim_preset_idx = 0,
  anim_preset_name = es_get("ANIM_PRESET_LAST", ""),
  anim_preset_save_name = "",
  anim_custom_type_names = {},
  anim_custom_type_save_name = "",
  word_style_preset_names = {},
  word_style_preset_name = es_get("WORD_STYLE_PRESET_LAST", ""),
  word_style_preset_save_name = "",
  font_items = {},
  font_preview_fonts = {},
  font_combo_filter = "",
  font_favorites = {},
  font_list_ready = false,
  font_scan_attempted = false,
  live_gui_vp = es_bool("LIVE_GUI_VP", true),
  wx_slider_style = tonumber(es_get("WX_SLIDER_STYLE", "1")) or 1,
  wx_slider_demo_value = tonumber(es_get("WX_SLIDER_DEMO_VALUE", "42")) or 42,
  wx_slider_demo_step_value = 2,
  _last_vp_body = nil,
}

local function wx_sync_karaoke_derived()
  state.karaoke = state.ml_timing_mode ~= 1
end

wx_sync_karaoke_derived()

state.words_per_line = math.max(1, math.min(64, math.floor(state.words_per_line)))
state.max_chars = math.max(0, math.min(500, math.floor(state.max_chars)))
state.word_grid_h = math.max(120, math.min(700, tonumber(state.word_grid_h) or 240))
state.wx_slider_demo_value = math.max(0, math.min(100, math.floor(tonumber(state.wx_slider_demo_value) or 42)))
state.wx_slider_demo_step_value = math.max(0, math.min(5, math.floor(tonumber(state.wx_slider_demo_step_value) or 2)))
for _, guide in ipairs(VIDEO_RATIO_GUIDES) do
  state.video_guides[guide.id] = es_bool(guide.key, false)
end
state.wx_slider_colors = {}
state.wx_slider_highlight_colors = {}
for i = 1, 10 do
  local c = tonumber(es_get("WX_SLIDER_C" .. tostring(i), ""))
  if c then state.wx_slider_colors[i] = c end
  local hc = tonumber(es_get("WX_SLIDER_HC" .. tostring(i), ""))
  if hc then state.wx_slider_highlight_colors[i] = hc end
end

do
  local ML_DEF = { 0.58, 2, 0.58, 1, 1, 1 }
  state.ml_max_rows = math.max(1, math.min(6, math.floor(tonumber(es_get("ML_MAX_ROWS", "4")) or 4)))
  for i = 1, 6 do
    local d = ML_DEF[i] or 1
    local sv = tonumber(es_get("ML_S" .. tostring(i), tostring(d))) or d
    state.ml_s[i] = math.max(0.12, math.min(3, sv))
    local rv = tonumber(es_get("ML_R" .. tostring(i), "0")) or 0
    state.ml_r[i] = math.max(0, math.min(1, rv))
  end
  state.ml_line_gap = math.max(-0.95, math.min(0.5, tonumber(es_get("ML_LINE_GAP", "0.1")) or 0.1))
  local j_any = false
  for i = 1, 6 do
    local js = es_get("ML_J" .. tostring(i), "")
    if js ~= "" then
      state.ml_jitter[i] = tonumber(js) or 0
      j_any = true
    end
  end
  if not j_any then
    for i = 1, 6 do
      state.ml_jitter[i] = math.random() * 2 - 1
    end
  end
  state.ml_row_chars = math.max(0, math.min(200, math.floor(tonumber(es_get("ML_ROW_CHARS", "0")) or 0)))
  state.ml_row_chars_rand = math.max(0, math.min(200, math.floor(tonumber(es_get("ML_ROW_CHARS_RAND", "0")) or 0)))
  state.ml_row_v_align = math.max(0, math.min(2, math.floor(tonumber(es_get("ML_ROW_VALIGN", "0")) or 0)))
  local seed_s = es_get("ML_CHARS_SEED", "")
  if seed_s == "" then
    state.ml_chars_seed = math.random() * 1e9
  else
    state.ml_chars_seed = tonumber(seed_s) or math.random() * 1e9
  end
  state.ml_indent_step = math.max(0, math.min(0.5, tonumber(es_get("ML_INDENT_STEP", "0")) or 0))
  state.ml_indent_rand = math.max(0, math.min(0.25, tonumber(es_get("ML_INDENT_RAND", "0")) or 0))
  local iseed = es_get("ML_INDENT_SEED", "")
  if iseed == "" then
    state.ml_indent_seed = math.random() * 1e9
  else
    state.ml_indent_seed = tonumber(iseed) or math.random() * 1e9
  end
end

local function bump_ml_chars_seed()
  state.ml_chars_seed = math.random() * 1e9
  r.SetExtState(SECTION, "ML_CHARS_SEED", string.format("%.17g", state.ml_chars_seed), true)
end

local function bump_ml_indent_seed()
  state.ml_indent_seed = math.random() * 1e9
  r.SetExtState(SECTION, "ML_INDENT_SEED", string.format("%.17g", state.ml_indent_seed), true)
end

local function persist_ml_jitter()
  for i = 1, 6 do
    local v = state.ml_jitter[i] or 0
    r.SetExtState(SECTION, "ML_J" .. tostring(i), string.format("%.17g", v), true)
  end
end

local ML_PRESET_SEP = "\031"

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

local function wx_visible_label(label)
  local s = tostring(label or "")
  local last
  local pos = 1
  while true do
    local p = s:find("##", pos, true)
    if not p then
      break
    end
    last = p
    pos = p + 2
  end
  return last and s:sub(1, last - 1) or s
end

--- Word grid labels: keep marker text unchanged; only calculate enough button width for UTF-8 text.
--- (Helpers in do/end so they do not add 3 extra top-level locals — Lua 5.1 chunk limit is 200.)
local wx_word_grid_button_label_and_width
do
  local function utf8_len_safe(s)
    if type(s) ~= "string" or s == "" then
      return 0
    end
    if utf8 and utf8.len then
      local ok, n = pcall(utf8.len, s)
      if ok and type(n) == "number" then
        return n
      end
    end
    return #s
  end

  wx_word_grid_button_label_and_width = function(ctx, raw, sc, byte_cap, max_show_cp)
    sc = tonumber(sc) or 1
    raw = tostring(raw or "")
    byte_cap = math.floor(tonumber(byte_cap) or 24)
    max_show_cp = math.max(1, math.floor(tonumber(max_show_cp) or 7))
    local wtxt = raw
    local bw = math.max(28, math.floor(utf8_len_safe(raw) * 8 * sc + 18))
    if ImGui and ImGui.CalcTextSize then
      local ok, tw = pcall(ImGui.CalcTextSize, ctx, wtxt)
      if ok and tonumber(tw) then
        local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
        bw = math.max(bw, math.floor(tw + fs * 1.35 * sc + 10))
      end
    end
    return wtxt, bw
  end
end

state.font_name = trim(state.font_name or "")

local function split_sep(s, sep)
  local out = {}
  if type(s) ~= "string" or s == "" then
    return out
  end
  local i = 1
  while i <= #s + 1 do
    local j = s:find(sep, i, true)
    if not j then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  return out
end

function anim_graph_default_blob()
  return "0,0,0|0.65,0,1;0"
end

function anim_graph_decode_blob(blob)
  blob = trim(blob or "")
  if blob == "" then
    blob = anim_graph_default_blob()
  end
  local points, curves = {}, {}
  local pblob, cblob = blob, ""
  local semi = blob:find(";", 1, true)
  if semi then
    pblob = blob:sub(1, semi - 1)
    cblob = blob:sub(semi + 1)
  end
  for tok in tostring(pblob):gmatch("[^|]+") do
    local xs, ys, ts = tok:match("^%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*,%s*([%-%d%.eE]+)%s*$")
    local x, y, t = tonumber(xs), tonumber(ys), tonumber(ts)
    if x and y and t then
      points[#points + 1] = {
        x = math.max(-1, math.min(1, x)),
        y = math.max(-1, math.min(1, y)),
        t = math.max(0, math.min(1, t)),
      }
    end
  end
  if #points < 2 then
    return anim_graph_decode_blob(anim_graph_default_blob())
  end
  table.sort(points, function(a, b)
    return (a.t or 0) < (b.t or 0)
  end)
  points[1].t = 0
  points[#points].t = 1
  local cpart = trim(tostring(cblob))
  local bpart
  local til = cpart:find("~", 1, true)
  if til then
    bpart = trim(cpart:sub(til + 1))
    cpart = trim(cpart:sub(1, til - 1))
  end
  for tok in cpart:gmatch("[^,]+") do
    curves[#curves + 1] = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(tok) or 0)))
  end
  for i = 1, #points - 1 do
    if curves[i] == nil then
      curves[i] = 0
    end
  end
  local blends = {}
  if bpart and bpart ~= "" then
    local bi = 1
    for tok in bpart:gmatch("[^,]+") do
      local tt = trim(tok)
      if tt ~= "d" and tt ~= "D" and tt ~= "" then
        local bv = tonumber(tt)
        if bv then
          blends[bi] = math.max(-1, math.min(1, bv))
        end
      end
      bi = bi + 1
    end
  end
  for i = 1, #points - 1 do
    local cid = curves[i]
    local bb = blends[i]
    --- Old blobs: IN_LOG stored +blend as 0→1 “ease amount” toward log; signed dial uses negatives.
    if cid == ANIM_GRAPH_CURVE_IN_LOG and type(bb) == "number" and bb > 0 and bb <= 1 then
      blends[i] = -bb
    end
  end
  return points, curves, blends
end

function anim_graph_encode_blob(points, curves, blends)
  if type(points) ~= "table" or #points < 2 then
    return anim_graph_default_blob()
  end
  local pt = {}
  for i = 1, #points do
    local p = points[i] or {}
    local x = math.max(-1, math.min(1, tonumber(p.x) or 0))
    local y = math.max(-1, math.min(1, tonumber(p.y) or 0))
    local t = math.max(0, math.min(1, tonumber(p.t) or 0))
    pt[#pt + 1] = string.format("%.17g,%.17g,%.17g", x, y, t)
  end
  local cv = {}
  for i = 1, #points - 1 do
    cv[#cv + 1] = tostring(math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curves and curves[i]) or 0))))
  end
  local out = table.concat(pt, "|") .. ";" .. table.concat(cv, ",")
  local need_tilde = false
  if blends then
    for i = 1, #points - 1 do
      if type(blends[i]) == "number" then
        need_tilde = true
        break
      end
    end
  end
  if need_tilde then
    local bp = {}
    for i = 1, #points - 1 do
      local bv = blends and blends[i]
      if type(bv) == "number" then
        bp[#bp + 1] = string.format("%.5g", bv)
      else
        bp[#bp + 1] = "d"
      end
    end
    out = out .. "~" .. table.concat(bp, ",")
  end
  return out
end

function anim_graph_side_blob_key(side_key)
  if side_key == "phrase_out" then
    return "anim_phrase_out_graph_blob"
  end
  return "anim_" .. side_key .. "_graph_blob"
end

function anim_graph_auto_blob_key(side_key)
  if side_key == "phrase_out" then
    return "anim_phrase_out_graph_auto_blob"
  end
  return "anim_" .. side_key .. "_graph_auto_blob"
end

function anim_side_param_value(side_key, lane_key)
  if side_key == "phrase_out" then
    return tonumber(state["anim_phrase_out_" .. lane_key]) or 0
  end
  return tonumber(state["anim_" .. side_key .. "_" .. lane_key]) or 0
end

function anim_graph_auto_lane_spec(lane_key)
  for i = 1, #ANIM_AUTO_LANES do
    if ANIM_AUTO_LANES[i].key == lane_key then
      return ANIM_AUTO_LANES[i]
    end
  end
  return nil
end

function anim_graph_auto_decode_blob(blob, side_key)
  local lanes = {}
  local raw = split_sep(blob or "", ML_PRESET_SEP)
  for i = 1, #raw do
    local rec = raw[i]
    local p = split_sep(rec, "~")
    local key = trim(p[1] or "")
    if key ~= "" then
      local lane = { enabled = tostring(p[2] or "") == "1", points = {}, curves = {} }
      for tok in tostring(p[3] or ""):gmatch("[^|]+") do
        local vs, ts = tok:match("^%s*([%-%d%.eE]+)%s*@%s*([%-%d%.eE]+)%s*$")
        local v, t = tonumber(vs), tonumber(ts)
        if v and t then
          lane.points[#lane.points + 1] = { v = v, t = math.max(0, math.min(1, t)) }
        end
      end
      for tok in tostring(p[4] or ""):gmatch("[^,]+") do
        lane.curves[#lane.curves + 1] = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(tok) or 0)))
      end
      lane.curve_blends = {}
      if p[5] and trim(tostring(p[5])) ~= "" then
        local bi = 1
        for tok in tostring(p[5]):gmatch("[^,]+") do
          local tt = trim(tok)
          if tt ~= "d" and tt ~= "D" and tt ~= "" then
            local bv = tonumber(tt)
            if bv then
              lane.curve_blends[bi] = math.max(-1, math.min(1, bv))
            end
          end
          bi = bi + 1
        end
      end
      lanes[key] = lane
    end
  end
  for i = 1, #ANIM_AUTO_LANES do
    local spec = ANIM_AUTO_LANES[i]
    local lane = lanes[spec.key]
    local base = anim_side_param_value(side_key, spec.key)
    base = math.max(spec.min, math.min(spec.max, base))
    if spec.integer then
      base = math.floor(base + 0.5)
    end
    if type(lane) ~= "table" or type(lane.points) ~= "table" or #lane.points < 2 then
      lane = { enabled = false, points = { { v = base, t = 0 }, { v = base, t = 1 } }, curves = { 0 }, curve_blends = {} }
      lanes[spec.key] = lane
    end
    table.sort(lane.points, function(a, b)
      return (a.t or 0) < (b.t or 0)
    end)
    lane.points[1].t = 0
    lane.points[#lane.points].t = 1
    for pidx = 1, #lane.points do
      local p = lane.points[pidx]
      p.v = math.max(spec.min, math.min(spec.max, tonumber(p.v) or base))
      if spec.integer then
        p.v = math.floor(p.v + 0.5)
      end
    end
    for cidx = 1, #lane.points - 1 do
      if lane.curves[cidx] == nil then
        lane.curves[cidx] = 0
      end
      lane.curves[cidx] = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(lane.curves[cidx]) or 0)))
    end
  end
  return lanes
end

function anim_graph_auto_encode_blob(lanes)
  local recs = {}
  for i = 1, #ANIM_AUTO_LANES do
    local spec = ANIM_AUTO_LANES[i]
    local lane = lanes and lanes[spec.key]
    if type(lane) == "table" and type(lane.points) == "table" and #lane.points >= 2 then
      local pts = {}
      for pidx = 1, #lane.points do
        local p = lane.points[pidx]
        local v = math.max(spec.min, math.min(spec.max, tonumber(p.v) or 0))
        if spec.integer then
          v = math.floor(v + 0.5)
        end
        local t = math.max(0, math.min(1, tonumber(p.t) or 0))
        pts[#pts + 1] = string.format("%.17g@%.17g", v, t)
      end
      local curves = {}
      for cidx = 1, #lane.points - 1 do
        curves[#curves + 1] = tostring(math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(lane.curves and lane.curves[cidx]) or 0))))
      end
      local need_bl = false
      if lane.curve_blends then
        for cidx = 1, #lane.points - 1 do
          if type(lane.curve_blends[cidx]) == "number" then
            need_bl = true
            break
          end
        end
      end
      local parts = {
        spec.key,
        lane.enabled and "1" or "0",
        table.concat(pts, "|"),
        table.concat(curves, ","),
      }
      if need_bl then
        local bp = {}
        for cidx = 1, #lane.points - 1 do
          local bv = lane.curve_blends and lane.curve_blends[cidx]
          if type(bv) == "number" then
            bp[#bp + 1] = string.format("%.5g", bv)
          else
            bp[#bp + 1] = "d"
          end
        end
        parts[#parts + 1] = table.concat(bp, ",")
      end
      recs[#recs + 1] = table.concat(parts, "~")
    end
  end
  return table.concat(recs, ML_PRESET_SEP)
end

function anim_graph_auto_lane_enabled(side_key, lane_key)
  local lanes = anim_graph_auto_decode_blob(state[anim_graph_auto_blob_key(side_key)] or "", side_key)
  local lane = lanes[lane_key]
  return lane and lane.enabled and true or false
end

do
  local p, c, gb = anim_graph_decode_blob(state.anim_in_graph_blob)
  state.anim_in_graph_blob = anim_graph_encode_blob(p, c, gb)
  p, c, gb = anim_graph_decode_blob(state.anim_out_graph_blob)
  state.anim_out_graph_blob = anim_graph_encode_blob(p, c, gb)
  p, c, gb = anim_graph_decode_blob(state.anim_phrase_out_graph_blob)
  state.anim_phrase_out_graph_blob = anim_graph_encode_blob(p, c, gb)
  local lanes = anim_graph_auto_decode_blob(state.anim_in_graph_auto_blob or "", "in")
  state.anim_in_graph_auto_blob = anim_graph_auto_encode_blob(lanes)
  lanes = anim_graph_auto_decode_blob(state.anim_out_graph_auto_blob or "", "out")
  state.anim_out_graph_auto_blob = anim_graph_auto_encode_blob(lanes)
  lanes = anim_graph_auto_decode_blob(state.anim_phrase_out_graph_auto_blob or "", "phrase_out")
  state.anim_phrase_out_graph_auto_blob = anim_graph_auto_encode_blob(lanes)
end

function anim_custom_type_key(name)
  local safe = (trim(name):gsub("[^%w%-_]", "_"))
  if safe == "" then
    safe = "_"
  end
  return "ANIM_CUSTOM_TYPE_DATA_" .. safe
end

function anim_custom_type_names_load()
  local names, seen = {}, {}
  for _, nm in ipairs(split_sep(es_get("ANIM_CUSTOM_TYPE_NAMES", ""), ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" and not seen[nm] then
      names[#names + 1] = nm
      seen[nm] = true
    end
  end
  table.sort(names)
  return names
end

function anim_custom_type_names_save()
  r.SetExtState(SECTION, "ANIM_CUSTOM_TYPE_NAMES", table.concat(state.anim_custom_type_names, ML_PRESET_SEP), true)
end

function anim_custom_type_find_idx(name)
  for i = 1, #state.anim_custom_type_names do
    if state.anim_custom_type_names[i] == name then
      return i
    end
  end
  return nil
end

function anim_type_ui_max()
  return ANIM_TYPE_MAX + #(state.anim_custom_type_names or {})
end

function anim_type_to_core(typ)
  typ = math.floor(tonumber(typ) or 0)
  if typ > ANIM_TYPE_MAX then
    return ANIM_KIND.CUSTOM
  end
  return math.max(0, math.min(ANIM_TYPE_MAX, typ))
end

function anim_custom_type_name_for_id(typ)
  typ = math.floor(tonumber(typ) or 0)
  if typ <= ANIM_TYPE_MAX then
    return nil
  end
  return state.anim_custom_type_names[typ - ANIM_TYPE_MAX]
end

function anim_type_combo_str()
  if not state.anim_custom_type_names or #state.anim_custom_type_names == 0 then
    return ANIM_TYPE_STR
  end
  return ANIM_TYPE_STR .. table.concat(state.anim_custom_type_names, "\0") .. "\0"
end

function anim_custom_type_pack(side_key)
  return table.concat({
    tostring(math.floor(state["anim_" .. side_key .. "_curve"] or 0)),
    string.format("%.17g", state["anim_" .. side_key .. "_bounce"] or 0.7),
    string.format("%.17g", state["anim_" .. side_key .. "_motion"] or 1),
    string.format("%.17g", state["anim_" .. side_key .. "_wiggle"] or 1),
    string.format("%.17g", state["anim_" .. side_key .. "_scale"] or 0),
    string.format("%.17g", state["anim_" .. side_key .. "_fade"] or 0),
    string.format("%.17g", state["anim_" .. side_key .. "_blur"] or 0),
    string.format("%.17g", state["anim_" .. side_key .. "_ghost"] or 1),
    tostring(math.floor(state["anim_" .. side_key .. "_dupes"] or 3)),
    string.format("%.17g", state["anim_" .. side_key .. "_dir"] or 90),
    state["anim_" .. side_key .. "_use_graph"] and "1" or "0",
    state[anim_graph_side_blob_key(side_key)] or anim_graph_default_blob(),
    state[anim_graph_auto_blob_key(side_key)] or "",
  }, ML_PRESET_SEP)
end

function anim_custom_type_apply_blob(side_key, blob)
  local t = split_sep(blob, ML_PRESET_SEP)
  if #t < 7 then
    return false
  end
  state["anim_" .. side_key .. "_curve"] = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(t[1]) or 0)))
  state["anim_" .. side_key .. "_bounce"] = math.max(0, math.min(2.0, tonumber(t[2]) or 0.7))
  state["anim_" .. side_key .. "_motion"] = math.max(0, math.min(3.0, tonumber(t[3]) or 1))
  state["anim_" .. side_key .. "_wiggle"] = math.max(0, math.min(3.0, tonumber(t[4]) or 1))
  if #t >= 10 then
    state["anim_" .. side_key .. "_scale"] = math.max(-1.0, math.min(2.0, tonumber(t[5]) or 0))
    state["anim_" .. side_key .. "_fade"] = math.max(0, math.min(1.0, tonumber(t[6]) or 0))
    state["anim_" .. side_key .. "_blur"] = math.max(0, math.min(3.0, tonumber(t[7]) or 0))
    state["anim_" .. side_key .. "_ghost"] = math.max(0, math.min(2.0, tonumber(t[8]) or 1))
    state["anim_" .. side_key .. "_dupes"] = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[9]) or 3)))
    state["anim_" .. side_key .. "_dir"] = math.max(-180, math.min(180, tonumber(t[10]) or 90))
  elseif #t >= 9 then
    state["anim_" .. side_key .. "_scale"] = math.max(-1.0, math.min(2.0, tonumber(t[5]) or 0))
    state["anim_" .. side_key .. "_fade"] = math.max(0, math.min(1.0, tonumber(t[6]) or 0))
    state["anim_" .. side_key .. "_blur"] = 0
    state["anim_" .. side_key .. "_ghost"] = math.max(0, math.min(2.0, tonumber(t[7]) or 1))
    state["anim_" .. side_key .. "_dupes"] = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[8]) or 3)))
    state["anim_" .. side_key .. "_dir"] = math.max(-180, math.min(180, tonumber(t[9]) or 90))
  else
    state["anim_" .. side_key .. "_scale"] = 0
    state["anim_" .. side_key .. "_fade"] = 0
    state["anim_" .. side_key .. "_blur"] = 0
    state["anim_" .. side_key .. "_ghost"] = math.max(0, math.min(2.0, tonumber(t[5]) or 1))
    state["anim_" .. side_key .. "_dupes"] = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[6]) or 3)))
    state["anim_" .. side_key .. "_dir"] = math.max(-180, math.min(180, tonumber(t[7]) or 90))
  end
  if t[11] ~= nil and (t[11] == "0" or t[11] == "1") then
    state["anim_" .. side_key .. "_use_graph"] = tostring(t[11]) == "1"
    state[anim_graph_side_blob_key(side_key)] = (t[12] ~= nil and trim(t[12]) ~= "") and t[12] or anim_graph_default_blob()
    state[anim_graph_auto_blob_key(side_key)] = t[13] or ""
  elseif t[11] ~= nil then
    state["anim_" .. side_key .. "_use_graph"] = false
    state[anim_graph_side_blob_key(side_key)] = trim(t[11]) ~= "" and t[11] or anim_graph_default_blob()
    state[anim_graph_auto_blob_key(side_key)] = t[12] or ""
  end
  return true
end

function anim_custom_type_apply_named(side_key, name)
  name = trim(name or "")
  if name == "" then
    return false
  end
  return anim_custom_type_apply_blob(side_key, es_get(anim_custom_type_key(name), ""))
end

function anim_custom_type_save_named(side_key, name)
  name = trim(name or "")
  if name == "" then
    return false, "Custom type name is empty."
  end
  r.SetExtState(SECTION, anim_custom_type_key(name), anim_custom_type_pack(side_key), true)
  if not anim_custom_type_find_idx(name) then
    state.anim_custom_type_names[#state.anim_custom_type_names + 1] = name
    table.sort(state.anim_custom_type_names)
    anim_custom_type_names_save()
  end
  return true
end

function anim_custom_type_delete_named(name)
  name = trim(name or "")
  local idx = anim_custom_type_find_idx(name)
  if idx then
    table.remove(state.anim_custom_type_names, idx)
    anim_custom_type_names_save()
  end
  if name ~= "" then
    r.SetExtState(SECTION, anim_custom_type_key(name), "", true)
  end
  state.anim_in_type = math.min(state.anim_in_type or 0, anim_type_ui_max())
  state.anim_out_type = math.min(state.anim_out_type or 0, anim_type_ui_max())
end

state.anim_custom_type_names = anim_custom_type_names_load()
do
  local mig = W.migrate_anim_type_id
  if type(mig) == "function" then
    state.anim_in_type = mig(state.anim_in_type, SECTION)
    state.anim_out_type = mig(state.anim_out_type, SECTION)
    state.anim_phrase_out_type = mig(state.anim_phrase_out_type, SECTION)
  end
end
state.anim_in_type = math.max(0, math.min(anim_type_ui_max(), math.floor(tonumber(state.anim_in_type) or 0)))
state.anim_out_type = math.max(0, math.min(anim_type_ui_max(), math.floor(tonumber(state.anim_out_type) or 0)))
state.anim_phrase_out_type = math.max(0, math.min(anim_type_ui_max(), math.floor(tonumber(state.anim_phrase_out_type) or 0)))

do
  state.font_combo_filter = es_get("FONT_COMBO_FILTER", "") or ""
  for _, nm in ipairs(split_sep(es_get("FONT_FAVORITES", ""), ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" then
      state.font_favorites[nm] = true
    end
  end
end

local function ml_preset_key(name)
  local safe = (trim(name):gsub("[^%w%-_]", "_"))
  if safe == "" then
    safe = "_"
  end
  return "ML_PRESET_DATA_" .. safe
end

local function ml_preset_find_idx(name)
  for i = 1, #state.ml_preset_names do
    if state.ml_preset_names[i] == name then
      return i
    end
  end
  return nil
end

local function ml_preset_find_default_name()
  for i = 1, #state.ml_preset_names do
    local nm = state.ml_preset_names[i]
    if type(nm) == "string" and nm:lower() == "default" then
      return nm, i
    end
  end
  return nil, nil
end

local function ml_preset_names_load()
  local raw = es_get("ML_PRESET_NAMES", "")
  local names = {}
  local seen = {}
  for _, nm in ipairs(split_sep(raw, ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" and not seen[nm] then
      names[#names + 1] = nm
      seen[nm] = true
    end
  end
  table.sort(names)
  return names
end

local function ml_preset_names_save()
  r.SetExtState(SECTION, "ML_PRESET_NAMES", table.concat(state.ml_preset_names, ML_PRESET_SEP), true)
end

local function ml_preset_pack_current()
  local vals = {
    tostring(state.ml_max_rows or 4),
    string.format("%.17g", state.ml_line_gap or 0.1),
    tostring(state.ml_row_chars or 0),
    tostring(state.ml_row_chars_rand or 0),
    string.format("%.17g", state.ml_chars_seed or 0),
    string.format("%.17g", state.ml_indent_step or 0),
    string.format("%.17g", state.ml_indent_rand or 0),
    string.format("%.17g", state.ml_indent_seed or 0),
  }
  for i = 1, 6 do
    vals[#vals + 1] = string.format("%.17g", state.ml_s[i] or 1)
  end
  for i = 1, 6 do
    vals[#vals + 1] = string.format("%.17g", state.ml_r[i] or 0)
  end
  for i = 1, 6 do
    vals[#vals + 1] = string.format("%.17g", state.ml_jitter[i] or 0)
  end
  vals[#vals + 1] = tostring(math.floor(state.ml_row_v_align or 0))
  return table.concat(vals, ML_PRESET_SEP)
end

local function ml_preset_apply_blob(blob)
  local t = split_sep(blob, ML_PRESET_SEP)
  if #t < 26 then
    return false, "Preset data is incomplete."
  end
  local p = 1
  state.ml_max_rows = math.max(1, math.min(6, math.floor(tonumber(t[p]) or 4)))
  p = p + 1
  state.ml_line_gap = math.max(-0.95, math.min(0.5, tonumber(t[p]) or 0.1))
  p = p + 1
  state.ml_row_chars = math.max(0, math.min(200, math.floor(tonumber(t[p]) or 0)))
  p = p + 1
  state.ml_row_chars_rand = math.max(0, math.min(200, math.floor(tonumber(t[p]) or 0)))
  p = p + 1
  state.ml_chars_seed = tonumber(t[p]) or math.random() * 1e9
  p = p + 1
  state.ml_indent_step = math.max(0, math.min(0.5, tonumber(t[p]) or 0))
  p = p + 1
  state.ml_indent_rand = math.max(0, math.min(0.25, tonumber(t[p]) or 0))
  p = p + 1
  state.ml_indent_seed = tonumber(t[p]) or math.random() * 1e9
  p = p + 1
  for i = 1, 6 do
    state.ml_s[i] = math.max(0.12, math.min(3, tonumber(t[p]) or 1))
    p = p + 1
  end
  for i = 1, 6 do
    state.ml_r[i] = math.max(0, math.min(1, tonumber(t[p]) or 0))
    p = p + 1
  end
  for i = 1, 6 do
    state.ml_jitter[i] = tonumber(t[p]) or 0
    p = p + 1
  end
  if t[p] ~= nil then
    state.ml_row_v_align = math.max(0, math.min(2, math.floor(tonumber(t[p]) or 0)))
  end
  persist_ml_jitter()
  return true
end

local function ml_preset_combo_str()
  if #state.ml_preset_names == 0 then
    return "\0"
  end
  return table.concat(state.ml_preset_names, "\0") .. "\0"
end

local function persist_anim_settings_extstate()
  wx_sync_karaoke_derived()
  r.SetExtState(SECTION, "ANIM_SCOPE", tostring(math.floor(state.anim_scope or 0)), true)
  r.SetExtState(SECTION, "ANIM_IN_ON", state.anim_in_on and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_IN_TYPE", tostring(math.floor(state.anim_in_type or 0)), true)
  r.SetExtState(SECTION, "ANIM_IN_CURVE", tostring(math.floor(state.anim_in_curve or 0)), true)
  r.SetExtState(SECTION, "ANIM_IN_DUR", string.format("%.17g", state.anim_in_dur or 0), true)
  r.SetExtState(SECTION, "ANIM_IN_AMP", string.format("%.17g", state.anim_in_amp or 1), true)
  r.SetExtState(SECTION, "ANIM_IN_BOUNCE", string.format("%.17g", state.anim_in_bounce or 0.7), true)
  r.SetExtState(SECTION, "ANIM_IN_MOTION", string.format("%.17g", state.anim_in_motion or 1), true)
  r.SetExtState(SECTION, "ANIM_IN_WIGGLE", string.format("%.17g", state.anim_in_wiggle or 1), true)
  r.SetExtState(SECTION, "ANIM_IN_SCALE", string.format("%.17g", state.anim_in_scale or 0), true)
  r.SetExtState(SECTION, "ANIM_IN_FADE", string.format("%.17g", state.anim_in_fade or 0), true)
  r.SetExtState(SECTION, "ANIM_IN_BLUR", string.format("%.17g", state.anim_in_blur or 0), true)
  r.SetExtState(SECTION, "ANIM_IN_GHOST", string.format("%.17g", state.anim_in_ghost or 1), true)
  r.SetExtState(SECTION, "ANIM_IN_DUPES", tostring(math.floor(state.anim_in_dupes or 3)), true)
  r.SetExtState(SECTION, "ANIM_IN_DIR", string.format("%.17g", state.anim_in_dir or 90), true)
  r.SetExtState(SECTION, "ANIM_IN_TWIST", string.format("%.17g", state.anim_in_twist or 0), true)
  r.SetExtState(SECTION, "ANIM_IN_USE_GRAPH", state.anim_in_use_graph and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_OUT_ON", state.anim_out_on and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_OUT_TYPE", tostring(math.floor(state.anim_out_type or 0)), true)
  r.SetExtState(SECTION, "ANIM_OUT_CURVE", tostring(math.floor(state.anim_out_curve or 0)), true)
  r.SetExtState(SECTION, "ANIM_OUT_DUR", string.format("%.17g", state.anim_out_dur or 0), true)
  r.SetExtState(SECTION, "ANIM_OUT_AMP", string.format("%.17g", state.anim_out_amp or 1), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_ON", state.anim_phrase_out_on and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_TYPE", tostring(math.floor(state.anim_phrase_out_type or state.anim_out_type or 0)), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_CURVE", tostring(math.floor(state.anim_phrase_out_curve or state.anim_out_curve or 0)), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_DUR", string.format("%.17g", state.anim_phrase_out_dur or state.anim_out_dur or 0), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_AMP", string.format("%.17g", state.anim_phrase_out_amp or state.anim_out_amp or 1), true)
  r.SetExtState(SECTION, "ANIM_OUT_BOUNCE", string.format("%.17g", state.anim_out_bounce or 0.7), true)
  r.SetExtState(SECTION, "ANIM_OUT_MOTION", string.format("%.17g", state.anim_out_motion or 1), true)
  r.SetExtState(SECTION, "ANIM_OUT_WIGGLE", string.format("%.17g", state.anim_out_wiggle or 1), true)
  r.SetExtState(SECTION, "ANIM_OUT_SCALE", string.format("%.17g", state.anim_out_scale or 0), true)
  r.SetExtState(SECTION, "ANIM_OUT_FADE", string.format("%.17g", state.anim_out_fade or 0), true)
  r.SetExtState(SECTION, "ANIM_OUT_BLUR", string.format("%.17g", state.anim_out_blur or 0), true)
  r.SetExtState(SECTION, "ANIM_OUT_GHOST", string.format("%.17g", state.anim_out_ghost or 1), true)
  r.SetExtState(SECTION, "ANIM_OUT_DUPES", tostring(math.floor(state.anim_out_dupes or 3)), true)
  r.SetExtState(SECTION, "ANIM_OUT_DIR", string.format("%.17g", state.anim_out_dir or 90), true)
  r.SetExtState(SECTION, "ANIM_OUT_TWIST", string.format("%.17g", state.anim_out_twist or 0), true)
  r.SetExtState(SECTION, "ANIM_OUT_USE_GRAPH", state.anim_out_use_graph and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_BOUNCE", string.format("%.17g", state.anim_phrase_out_bounce or state.anim_out_bounce or 0.7), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_MOTION", string.format("%.17g", state.anim_phrase_out_motion or state.anim_out_motion or 1), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_WIGGLE", string.format("%.17g", state.anim_phrase_out_wiggle or state.anim_out_wiggle or 1), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_SCALE", string.format("%.17g", state.anim_phrase_out_scale or state.anim_out_scale or 0), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_FADE", string.format("%.17g", state.anim_phrase_out_fade or state.anim_out_fade or 0), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_BLUR", string.format("%.17g", state.anim_phrase_out_blur or state.anim_out_blur or 0), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_GHOST", string.format("%.17g", state.anim_phrase_out_ghost or state.anim_out_ghost or 1), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_DUPES", tostring(math.floor(state.anim_phrase_out_dupes or state.anim_out_dupes or 3)), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_DIR", string.format("%.17g", state.anim_phrase_out_dir or state.anim_out_dir or 90), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_TWIST", string.format("%.17g", state.anim_phrase_out_twist or state.anim_out_twist or 0), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_USE_GRAPH", state.anim_phrase_out_use_graph and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_IN_GRAPH_WORD_SPAN", state.anim_in_graph_word_span and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_OUT_GRAPH_WORD_SPAN", state.anim_out_graph_word_span and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_GRAPH_WORD_SPAN", state.anim_phrase_out_graph_word_span and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_IN_GRAPH", state.anim_in_graph_blob or anim_graph_default_blob(), true)
  r.SetExtState(SECTION, "ANIM_OUT_GRAPH", state.anim_out_graph_blob or anim_graph_default_blob(), true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_GRAPH", state.anim_phrase_out_graph_blob or anim_graph_default_blob(), true)
  r.SetExtState(SECTION, "ANIM_IN_GRAPH_AUTO", state.anim_in_graph_auto_blob or "", true)
  r.SetExtState(SECTION, "ANIM_OUT_GRAPH_AUTO", state.anim_out_graph_auto_blob or "", true)
  r.SetExtState(SECTION, "ANIM_PHRASE_OUT_GRAPH_AUTO", state.anim_phrase_out_graph_auto_blob or "", true)
  r.SetExtState(SECTION, "KARAOKE", state.karaoke and "1" or "0", true)
  r.SetExtState(SECTION, "SHOW_WORDS_MODE", tostring(math.max(0, math.min(2, math.floor(state.ml_timing_mode or 1)))), true)
  r.SetExtState(SECTION, "ANIM_TYPE_REV", "3", true)
end

local function ml_preset_blob(name)
  local nm = trim(name or "")
  if nm == "" then
    return ""
  end
  return es_get(ml_preset_key(nm), "")
end

local function ml_preset_is_dirty()
  local nm = trim(state.ml_preset_name or "")
  if nm == "" then
    return true
  end
  local blob = ml_preset_blob(nm)
  if blob == "" then
    return true
  end
  return blob ~= ml_preset_pack_current()
end

local function ml_preset_apply_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  local blob = ml_preset_blob(nm)
  if blob == "" then
    return false, "Preset not found: " .. nm
  end
  local okp, perr = ml_preset_apply_blob(blob)
  if not okp then
    return false, perr or "Could not load preset."
  end
  local idx = ml_preset_find_idx(nm)
  state.ml_preset_name = nm
  state.ml_preset_idx = math.max(0, (idx or 1) - 1)
  r.SetExtState(SECTION, "ML_PRESET_LAST", nm, true)
  return true
end

local function ml_preset_save_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  r.SetExtState(SECTION, ml_preset_key(nm), ml_preset_pack_current(), true)
  local idx = ml_preset_find_idx(nm)
  if not idx then
    state.ml_preset_names[#state.ml_preset_names + 1] = nm
    table.sort(state.ml_preset_names)
    ml_preset_names_save()
    idx = ml_preset_find_idx(nm)
  end
  state.ml_preset_name = nm
  state.ml_preset_idx = math.max(0, (idx or 1) - 1)
  r.SetExtState(SECTION, "ML_PRESET_LAST", nm, true)
  return true
end

local function ml_preset_delete_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  local idx = ml_preset_find_idx(nm)
  if idx then
    table.remove(state.ml_preset_names, idx)
    ml_preset_names_save()
  end
  r.SetExtState(SECTION, ml_preset_key(nm), "", true)
  if #state.ml_preset_names > 0 then
    local pick = math.max(1, math.min(idx or 1, #state.ml_preset_names))
    state.ml_preset_name = state.ml_preset_names[pick]
    state.ml_preset_idx = pick - 1
  else
    state.ml_preset_name = ""
    state.ml_preset_idx = 0
  end
  r.SetExtState(SECTION, "ML_PRESET_LAST", state.ml_preset_name or "", true)
  return true
end

local function anim_preset_key(name)
  local safe = (trim(name):gsub("[^%w%-_]", "_"))
  if safe == "" then
    safe = "_"
  end
  return "ANIM_PRESET_DATA_" .. safe
end

local function anim_preset_find_idx(name)
  for i = 1, #state.anim_preset_names do
    if state.anim_preset_names[i] == name then
      return i
    end
  end
  return nil
end

local function anim_preset_find_default_name()
  for i = 1, #state.anim_preset_names do
    local nm = state.anim_preset_names[i]
    if type(nm) == "string" and nm:lower() == "default" then
      return nm, i
    end
  end
  return nil, nil
end

local function anim_preset_names_load()
  local raw = es_get("ANIM_PRESET_NAMES", "")
  local names = {}
  local seen = {}
  for _, nm in ipairs(split_sep(raw, ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" and not seen[nm] then
      names[#names + 1] = nm
      seen[nm] = true
    end
  end
  table.sort(names)
  return names
end

local function anim_preset_names_save()
  r.SetExtState(SECTION, "ANIM_PRESET_NAMES", table.concat(state.anim_preset_names, ML_PRESET_SEP), true)
end

local function anim_preset_pack_current()
  local vals = {
    tostring(math.floor(state.anim_scope or 0)),
    state.anim_in_on and "1" or "0",
    tostring(math.floor(state.anim_in_type or 0)),
    tostring(math.floor(state.anim_in_curve or 0)),
    string.format("%.17g", state.anim_in_dur or 0),
    string.format("%.17g", state.anim_in_amp or 1),
    string.format("%.17g", state.anim_in_bounce or 0.7),
    string.format("%.17g", state.anim_in_motion or 1),
    string.format("%.17g", state.anim_in_wiggle or 1),
    string.format("%.17g", state.anim_in_scale or 0),
    string.format("%.17g", state.anim_in_fade or 0),
    string.format("%.17g", state.anim_in_blur or 0),
    string.format("%.17g", state.anim_in_ghost or 1),
    tostring(math.floor(state.anim_in_dupes or 3)),
    string.format("%.17g", state.anim_in_dir or 90),
    state.anim_out_on and "1" or "0",
    tostring(math.floor(state.anim_out_type or 0)),
    tostring(math.floor(state.anim_out_curve or 0)),
    string.format("%.17g", state.anim_out_dur or 0),
    string.format("%.17g", state.anim_out_amp or 1),
    string.format("%.17g", state.anim_out_bounce or 0.7),
    string.format("%.17g", state.anim_out_motion or 1),
    string.format("%.17g", state.anim_out_wiggle or 1),
    string.format("%.17g", state.anim_out_scale or 0),
    string.format("%.17g", state.anim_out_fade or 0),
    string.format("%.17g", state.anim_out_blur or 0),
    string.format("%.17g", state.anim_out_ghost or 1),
    tostring(math.floor(state.anim_out_dupes or 3)),
    string.format("%.17g", state.anim_out_dir or 90),
    state.anim_phrase_out_on and "1" or "0",
    tostring(math.floor(state.anim_phrase_out_type or state.anim_out_type or 0)),
    tostring(math.floor(state.anim_phrase_out_curve or state.anim_out_curve or 0)),
    string.format("%.17g", state.anim_phrase_out_dur or state.anim_out_dur or 0),
    string.format("%.17g", state.anim_phrase_out_amp or state.anim_out_amp or 1),
    string.format("%.17g", state.anim_phrase_out_bounce or state.anim_out_bounce or 0.7),
    string.format("%.17g", state.anim_phrase_out_motion or state.anim_out_motion or 1),
    string.format("%.17g", state.anim_phrase_out_wiggle or state.anim_out_wiggle or 1),
    string.format("%.17g", state.anim_phrase_out_scale or state.anim_out_scale or 0),
    string.format("%.17g", state.anim_phrase_out_fade or state.anim_out_fade or 0),
    string.format("%.17g", state.anim_phrase_out_blur or state.anim_out_blur or 0),
    string.format("%.17g", state.anim_phrase_out_ghost or state.anim_out_ghost or 1),
    tostring(math.floor(state.anim_phrase_out_dupes or state.anim_out_dupes or 3)),
    string.format("%.17g", state.anim_phrase_out_dir or state.anim_out_dir or 90),
    string.format("%.17g", state.anim_in_twist or 0),
    string.format("%.17g", state.anim_out_twist or 0),
    string.format("%.17g", state.anim_phrase_out_twist or state.anim_out_twist or 0),
    state.anim_in_use_graph and "1" or "0",
    state.anim_out_use_graph and "1" or "0",
    state.anim_phrase_out_use_graph and "1" or "0",
    state.anim_in_graph_word_span and "1" or "0",
    state.anim_out_graph_word_span and "1" or "0",
    state.anim_phrase_out_graph_word_span and "1" or "0",
    state.anim_in_graph_blob or anim_graph_default_blob(),
    state.anim_out_graph_blob or anim_graph_default_blob(),
    state.anim_phrase_out_graph_blob or state.anim_out_graph_blob or anim_graph_default_blob(),
    state.anim_in_graph_auto_blob or "",
    state.anim_out_graph_auto_blob or "",
    state.anim_phrase_out_graph_auto_blob or "",
    state.karaoke and "1" or "0",
    "3",
  }
  return table.concat(vals, ML_PRESET_SEP)
end

local function anim_preset_apply_blob(blob)
  local t = split_sep(blob, ML_PRESET_SEP)
  if #t < 9 then
    return false, "Animation preset data is incomplete."
  end
  local types_are_v3 = (tonumber(t[#t] or "") == 3)
  local function migr_preset_type(raw)
    raw = math.floor(tonumber(raw) or 0)
    if types_are_v3 then
      return raw
    end
    if type(W.migrate_anim_type_compact_to_v3) == "function" then
      return W.migrate_anim_type_compact_to_v3(raw)
    end
    return raw
  end
  local p = 1
  state.anim_scope = math.max(0, math.min(2, math.floor(tonumber(t[p]) or 0)))
  p = p + 1
  state.anim_in_on = tostring(t[p] or "") == "1"
  p = p + 1
  state.anim_in_type = math.max(0, math.min(anim_type_ui_max(), migr_preset_type(t[p])))
  p = p + 1
  state.anim_in_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(t[p]) or 0)))
  p = p + 1
  state.anim_in_dur = math.max(0, math.min(2.0, tonumber(t[p]) or 0.12))
  p = p + 1
  if #t >= 11 then
    state.anim_in_amp = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
  else
    state.anim_in_amp = 1
  end
  local is_blur_custom_look_preset = #t >= 29
  local is_full_custom_look_preset = #t >= 27
  local is_custom_look_preset = #t >= 23
  local is_split_look_preset = #t >= 21
  local is_shared_look_preset = (not is_split_look_preset) and #t >= 15
  if is_split_look_preset then
    state.anim_in_bounce = math.max(0, math.min(2.0, tonumber(t[p]) or 0.7))
    p = p + 1
    state.anim_in_motion = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    state.anim_in_wiggle = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    if is_full_custom_look_preset then
      state.anim_in_scale = math.max(-1.0, math.min(2.0, tonumber(t[p]) or 0))
      p = p + 1
      state.anim_in_fade = math.max(0, math.min(1.0, tonumber(t[p]) or 0))
      p = p + 1
      if is_blur_custom_look_preset then
        state.anim_in_blur = math.max(0, math.min(3.0, tonumber(t[p]) or 0))
        p = p + 1
      else
        state.anim_in_blur = 0
      end
    else
      state.anim_in_scale, state.anim_in_fade, state.anim_in_blur = 0, 0, 0
    end
    state.anim_in_ghost = math.max(0, math.min(2.0, tonumber(t[p]) or 1))
    p = p + 1
    state.anim_in_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[p]) or 3)))
    p = p + 1
    if is_custom_look_preset then
      state.anim_in_dir = math.max(-180, math.min(180, tonumber(t[p]) or 90))
      p = p + 1
    else
      state.anim_in_dir = 90
    end
  elseif is_shared_look_preset then
    local b = math.max(0, math.min(2.0, tonumber(t[p]) or 0.7))
    p = p + 1
    local m = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    local w = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    local g = math.max(0, math.min(2.0, tonumber(t[p]) or 1))
    p = p + 1
    state.anim_in_bounce, state.anim_out_bounce = b, b
    state.anim_in_motion, state.anim_out_motion = m, m
    state.anim_in_wiggle, state.anim_out_wiggle = w, w
    state.anim_in_scale, state.anim_out_scale = 0, 0
    state.anim_in_fade, state.anim_out_fade = 0, 0
    state.anim_in_blur, state.anim_out_blur = 0, 0
    state.anim_in_ghost, state.anim_out_ghost = g, g
    state.anim_in_dupes, state.anim_out_dupes = 3, 3
    state.anim_in_dir, state.anim_out_dir = 90, 90
    state.anim_in_twist, state.anim_out_twist = 0, 0
  else
    state.anim_in_bounce, state.anim_out_bounce = 0.7, 0.7
    state.anim_in_motion, state.anim_out_motion = 1, 1
    state.anim_in_wiggle, state.anim_out_wiggle = 1, 1
    state.anim_in_scale, state.anim_out_scale = 0, 0
    state.anim_in_fade, state.anim_out_fade = 0, 0
    state.anim_in_blur, state.anim_out_blur = 0, 0
    state.anim_in_ghost, state.anim_out_ghost = 1, 1
    state.anim_in_dupes, state.anim_out_dupes = 3, 3
    state.anim_in_dir, state.anim_out_dir = 90, 90
    state.anim_in_twist, state.anim_out_twist = 0, 0
  end
  state.anim_out_on = tostring(t[p] or "") == "1"
  p = p + 1
  state.anim_out_type = math.max(0, math.min(anim_type_ui_max(), migr_preset_type(t[p])))
  p = p + 1
  state.anim_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(t[p]) or 0)))
  p = p + 1
  state.anim_out_dur = math.max(0, math.min(2.0, tonumber(t[p]) or 0.12))
  p = p + 1
  if #t >= 11 then
    state.anim_out_amp = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
  else
    state.anim_out_amp = 1
  end
  if is_split_look_preset then
    state.anim_out_bounce = math.max(0, math.min(2.0, tonumber(t[p]) or 0.7))
    p = p + 1
    state.anim_out_motion = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    state.anim_out_wiggle = math.max(0, math.min(3.0, tonumber(t[p]) or 1))
    p = p + 1
    if is_full_custom_look_preset then
      state.anim_out_scale = math.max(-1.0, math.min(2.0, tonumber(t[p]) or 0))
      p = p + 1
      state.anim_out_fade = math.max(0, math.min(1.0, tonumber(t[p]) or 0))
      p = p + 1
      if is_blur_custom_look_preset then
        state.anim_out_blur = math.max(0, math.min(3.0, tonumber(t[p]) or 0))
        p = p + 1
      else
        state.anim_out_blur = 0
      end
    else
      state.anim_out_scale, state.anim_out_fade, state.anim_out_blur = 0, 0, 0
    end
    state.anim_out_ghost = math.max(0, math.min(2.0, tonumber(t[p]) or 1))
    p = p + 1
    state.anim_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[p]) or 3)))
    p = p + 1
    if is_custom_look_preset then
      state.anim_out_dir = math.max(-180, math.min(180, tonumber(t[p]) or 90))
      p = p + 1
    else
      state.anim_out_dir = 90
    end
  end
  if t[p] ~= nil then
    state.anim_phrase_out_on = tostring(t[p] or "") == "1"
    p = p + 1
  else
    state.anim_phrase_out_on = false
  end
  if t[p] ~= nil then
    state.anim_phrase_out_type = math.max(0, math.min(anim_type_ui_max(), migr_preset_type(t[p])))
    p = p + 1
  else
    state.anim_phrase_out_type = state.anim_out_type
  end
  if t[p] ~= nil then
    state.anim_phrase_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, math.floor(tonumber(t[p]) or (state.anim_out_curve or 0))))
    p = p + 1
    state.anim_phrase_out_dur = math.max(0, math.min(2.0, tonumber(t[p]) or (state.anim_out_dur or 0.12)))
    p = p + 1
    state.anim_phrase_out_amp = math.max(0, math.min(3.0, tonumber(t[p]) or (state.anim_out_amp or 1)))
    p = p + 1
    state.anim_phrase_out_bounce = math.max(0, math.min(2.0, tonumber(t[p]) or (state.anim_out_bounce or 0.7)))
    p = p + 1
    state.anim_phrase_out_motion = math.max(0, math.min(3.0, tonumber(t[p]) or (state.anim_out_motion or 1)))
    p = p + 1
    state.anim_phrase_out_wiggle = math.max(0, math.min(3.0, tonumber(t[p]) or (state.anim_out_wiggle or 1)))
    p = p + 1
    state.anim_phrase_out_scale = math.max(-1.0, math.min(2.0, tonumber(t[p]) or (state.anim_out_scale or 0)))
    p = p + 1
    state.anim_phrase_out_fade = math.max(0, math.min(1.0, tonumber(t[p]) or (state.anim_out_fade or 0)))
    p = p + 1
    state.anim_phrase_out_blur = math.max(0, math.min(3.0, tonumber(t[p]) or (state.anim_out_blur or 0)))
    p = p + 1
    state.anim_phrase_out_ghost = math.max(0, math.min(2.0, tonumber(t[p]) or (state.anim_out_ghost or 1)))
    p = p + 1
    state.anim_phrase_out_dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(t[p]) or (state.anim_out_dupes or 3))))
    p = p + 1
    state.anim_phrase_out_dir = math.max(-180, math.min(180, tonumber(t[p]) or (state.anim_out_dir or 90)))
    p = p + 1
    if #t >= 46 then
      state.anim_in_twist = math.max(-720, math.min(720, tonumber(t[p]) or 0))
      p = p + 1
      state.anim_out_twist = math.max(-720, math.min(720, tonumber(t[p]) or 0))
      p = p + 1
      state.anim_phrase_out_twist = math.max(-720, math.min(720, tonumber(t[p]) or 0))
      p = p + 1
    elseif t[p] ~= nil then
      --- Older single trailing phrase twist only (in/out twist omitted).
      state.anim_in_twist = 0
      state.anim_out_twist = 0
      state.anim_phrase_out_twist = math.max(-720, math.min(720, tonumber(t[p]) or 0))
      p = p + 1
    else
      state.anim_in_twist = 0
      state.anim_out_twist = 0
      state.anim_phrase_out_twist = 0
    end
  else
    state.anim_phrase_out_curve = state.anim_out_curve
    state.anim_phrase_out_dur = state.anim_out_dur
    state.anim_phrase_out_amp = state.anim_out_amp
    state.anim_phrase_out_bounce = state.anim_out_bounce
    state.anim_phrase_out_motion = state.anim_out_motion
    state.anim_phrase_out_wiggle = state.anim_out_wiggle
    state.anim_phrase_out_scale = state.anim_out_scale
    state.anim_phrase_out_fade = state.anim_out_fade
    state.anim_phrase_out_blur = state.anim_out_blur
    state.anim_phrase_out_ghost = state.anim_out_ghost
    state.anim_phrase_out_dupes = state.anim_out_dupes
    state.anim_phrase_out_dir = state.anim_out_dir
    state.anim_phrase_out_twist = state.anim_out_twist
  end
  if t[p] ~= nil and (t[p] == "0" or t[p] == "1") and t[p + 1] ~= nil and (t[p + 1] == "0" or t[p + 1] == "1") and t[p + 2] ~= nil and (t[p + 2] == "0" or t[p + 2] == "1") then
    state.anim_in_use_graph = tostring(t[p]) == "1"
    p = p + 1
    state.anim_out_use_graph = tostring(t[p]) == "1"
    p = p + 1
    state.anim_phrase_out_use_graph = tostring(t[p]) == "1"
    p = p + 1
  else
    state.anim_in_use_graph = false
    state.anim_out_use_graph = false
    state.anim_phrase_out_use_graph = false
  end
  state.anim_in_graph_blob = (t[p] ~= nil and trim(t[p]) ~= "") and t[p] or anim_graph_default_blob()
  if t[p] ~= nil then p = p + 1 end
  state.anim_out_graph_blob = (t[p] ~= nil and trim(t[p]) ~= "") and t[p] or anim_graph_default_blob()
  if t[p] ~= nil then p = p + 1 end
  state.anim_phrase_out_graph_blob = (t[p] ~= nil and trim(t[p]) ~= "") and t[p] or state.anim_out_graph_blob or anim_graph_default_blob()
  if t[p] ~= nil then p = p + 1 end
  state.anim_in_graph_auto_blob = t[p] or state.anim_in_graph_auto_blob or ""
  if t[p] ~= nil then p = p + 1 end
  state.anim_out_graph_auto_blob = t[p] or state.anim_out_graph_auto_blob or ""
  if t[p] ~= nil then p = p + 1 end
  state.anim_phrase_out_graph_auto_blob = t[p] or state.anim_phrase_out_graph_auto_blob or state.anim_out_graph_auto_blob or ""
  if t[p] ~= nil then
    p = p + 1
  end
  local gp, gc, gb = anim_graph_decode_blob(state.anim_in_graph_blob)
  state.anim_in_graph_blob = anim_graph_encode_blob(gp, gc, gb)
  gp, gc, gb = anim_graph_decode_blob(state.anim_out_graph_blob)
  state.anim_out_graph_blob = anim_graph_encode_blob(gp, gc, gb)
  gp, gc, gb = anim_graph_decode_blob(state.anim_phrase_out_graph_blob)
  state.anim_phrase_out_graph_blob = anim_graph_encode_blob(gp, gc, gb)
  local al = anim_graph_auto_decode_blob(state.anim_in_graph_auto_blob or "", "in")
  state.anim_in_graph_auto_blob = anim_graph_auto_encode_blob(al)
  al = anim_graph_auto_decode_blob(state.anim_out_graph_auto_blob or "", "out")
  state.anim_out_graph_auto_blob = anim_graph_auto_encode_blob(al)
  al = anim_graph_auto_decode_blob(state.anim_phrase_out_graph_auto_blob or "", "phrase_out")
  state.anim_phrase_out_graph_auto_blob = anim_graph_auto_encode_blob(al)
  if t[p] ~= nil and (t[p] == "0" or t[p] == "1") and t[p + 1] and (t[p + 1] == "0" or t[p + 1] == "1") and t[p + 2] and (t[p + 2] == "0" or t[p + 2] == "1") then
    state.anim_in_graph_word_span = tostring(t[p]) == "1"
    p = p + 1
    state.anim_out_graph_word_span = tostring(t[p]) == "1"
    p = p + 1
    state.anim_phrase_out_graph_word_span = tostring(t[p]) == "1"
    p = p + 1
  else
    state.anim_in_graph_word_span = false
    state.anim_out_graph_word_span = false
    state.anim_phrase_out_graph_word_span = false
  end
  if t[p] ~= nil and (tostring(t[p]) == "0" or tostring(t[p]) == "1") then
    p = p + 1
  end
  persist_anim_settings_extstate()
  return true
end

local function anim_preset_blob(name)
  local nm = trim(name or "")
  if nm == "" then
    return ""
  end
  return es_get(anim_preset_key(nm), "")
end

local function anim_preset_is_dirty()
  local nm = trim(state.anim_preset_name or "")
  if nm == "" then
    return true
  end
  local blob = anim_preset_blob(nm)
  if blob == "" then
    return true
  end
  return blob ~= anim_preset_pack_current()
end

local function anim_preset_apply_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  local blob = anim_preset_blob(nm)
  if blob == "" then
    return false, "Preset not found: " .. nm
  end
  local okp, perr = anim_preset_apply_blob(blob)
  if not okp then
    return false, perr or "Could not load animation preset."
  end
  local idx = anim_preset_find_idx(nm)
  state.anim_preset_name = nm
  state.anim_preset_idx = math.max(0, (idx or 1) - 1)
  r.SetExtState(SECTION, "ANIM_PRESET_LAST", nm, true)
  return true
end

local function anim_preset_save_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  r.SetExtState(SECTION, anim_preset_key(nm), anim_preset_pack_current(), true)
  local idx = anim_preset_find_idx(nm)
  if not idx then
    state.anim_preset_names[#state.anim_preset_names + 1] = nm
    table.sort(state.anim_preset_names)
    anim_preset_names_save()
    idx = anim_preset_find_idx(nm)
  end
  state.anim_preset_name = nm
  state.anim_preset_idx = math.max(0, (idx or 1) - 1)
  r.SetExtState(SECTION, "ANIM_PRESET_LAST", nm, true)
  return true
end

local function anim_preset_delete_named(nm)
  nm = trim(nm or "")
  if nm == "" then
    return false, "Preset name is empty."
  end
  local idx = anim_preset_find_idx(nm)
  if idx then
    table.remove(state.anim_preset_names, idx)
    anim_preset_names_save()
  end
  r.SetExtState(SECTION, anim_preset_key(nm), "", true)
  if #state.anim_preset_names > 0 then
    local pick = math.max(1, math.min(idx or 1, #state.anim_preset_names))
    state.anim_preset_name = state.anim_preset_names[pick]
    state.anim_preset_idx = pick - 1
  else
    state.anim_preset_name = ""
    state.anim_preset_idx = 0
  end
  r.SetExtState(SECTION, "ANIM_PRESET_LAST", state.anim_preset_name or "", true)
  return true
end

local function load_system_font_items()
  local names = {}
  local seen = {}
  local osname = ((r.GetOS and r.GetOS()) or ""):lower()
  if osname:find("mac", 1, true) or osname:find("osx", 1, true) or osname:find("darwin", 1, true) then
    local p = io.popen("system_profiler SPFontsDataType 2>/dev/null")
    if p then
      local out = p:read("*a") or ""
      p:close()
      local cur_name = nil
      for ln in out:gmatch("[^\r\n]+") do
        local nm = ln:match("^%s*Full Name:%s*(.-)%s*$")
        if nm and nm ~= "" then
          cur_name = trim(nm)
        end
        if cur_name and not seen[cur_name] then
          names[#names + 1] = { name = cur_name }
          seen[cur_name] = true
          cur_name = nil
        end
      end
    end
  end

  if #names == 0 and ImGui.CreateFont then
    local fallback = {
      "Arial",
      "Helvetica",
      "Times New Roman",
      "Courier New",
      "Verdana",
      "Tahoma",
      "Trebuchet MS",
      "Georgia",
      "Impact",
      "Comic Sans MS",
      "Hiragino Sans",
      "HiraginoSans-W3",
      "Hiragino Kaku Gothic ProN",
      "Avenir",
      "Menlo",
      "Monaco",
    }
    for i = 1, #fallback do
      local nm = fallback[i]
      if not seen[nm] then
        names[#names + 1] = { name = nm }
        seen[nm] = true
      end
    end
  end

  table.sort(names, function(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  return names
end

local function load_font_items_from_cache()
  local raw = es_get("FONT_LIST_CACHE", "")
  local out = {}
  local seen = {}
  for _, nm in ipairs(split_sep(raw, ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" and not seen[nm] then
      out[#out + 1] = { name = nm }
      seen[nm] = true
    end
  end
  table.sort(out, function(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  return out
end

local function save_font_items_cache(items)
  local names = {}
  for i = 1, #items do
    local nm = trim(items[i].name or "")
    if nm ~= "" then
      names[#names + 1] = nm
    end
  end
  r.SetExtState(SECTION, "FONT_LIST_CACHE", table.concat(names, ML_PRESET_SEP), true)
end

local function ensure_font_items(force_scan)
  if state.font_list_ready and (not force_scan) then
    return
  end
  if not force_scan then
    state.font_items = load_font_items_from_cache()
    state.font_list_ready = true
    return
  end
  local scanned = load_system_font_items()
  if #scanned > 0 then
    state.font_items = scanned
    save_font_items_cache(scanned)
  elseif not state.font_list_ready then
    state.font_items = {}
  end
  state.font_scan_attempted = true
  state.font_list_ready = true
end

local function font_preview_get(ctx, font_name)
  if not font_name or font_name == "" then
    return nil
  end
  local f = state.font_preview_fonts[font_name]
  if f ~= nil then
    return f or nil
  end
  -- ReaImGui exposes CreateFont/AttachFont on reaper as ImGui_CreateFont / ImGui_AttachFont.
  -- The imgui.lua wrapper may omit AttachFont or error on absent fields; never index ImGui.* directly.
  local function try_create(name, sz)
    if r.ImGui_CreateFont then
      local ok, h = pcall(r.ImGui_CreateFont, name, sz)
      if ok and h then
        return h
      end
    end
    local ok, h = pcall(function()
      return ImGui.CreateFont(name, sz)
    end)
    if ok and h then
      return h
    end
    return nil
  end
  local function try_attach(c, font_handle)
    if r.ImGui_AttachFont then
      local ok = pcall(r.ImGui_AttachFont, c, font_handle)
      if ok then
        return true
      end
    end
    local ok = pcall(function()
      ImGui.AttachFont(c, font_handle)
    end)
    return ok
  end
  local created = try_create(font_name, 15)
  if not created then
    state.font_preview_fonts[font_name] = false
    return nil
  end
  if not try_attach(ctx, created) then
    state.font_preview_fonts[font_name] = false
    return nil
  end
  state.font_preview_fonts[font_name] = created
  return created
end

local function font_favorites_persist()
  local names = {}
  for nm in pairs(state.font_favorites) do
    if type(nm) == "string" and trim(nm) ~= "" then
      names[#names + 1] = trim(nm)
    end
  end
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  r.SetExtState(SECTION, "FONT_FAVORITES", table.concat(names, ML_PRESET_SEP), true)
end

local function font_toggle_favorite(nm)
  nm = trim(nm or "")
  if nm == "" then
    return
  end
  if state.font_favorites[nm] then
    state.font_favorites[nm] = nil
  else
    state.font_favorites[nm] = true
  end
  font_favorites_persist()
end

--- Favorites first (A–Z), then others (A–Z); only names matching filter (substring, case-insensitive).
local function font_items_filtered()
  local filt = trim(state.font_combo_filter or ""):lower()
  local favs = {}
  local rest = {}
  for i = 1, #state.font_items do
    local it = state.font_items[i]
    local nm = it.name or ""
    if filt == "" or nm:lower():find(filt, 1, true) then
      if state.font_favorites[nm] then
        favs[#favs + 1] = it
      else
        rest[#rest + 1] = it
      end
    end
  end
  table.sort(favs, function(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  table.sort(rest, function(a, b)
    return (a.name or ""):lower() < (b.name or ""):lower()
  end)
  local out = {}
  for j = 1, #favs do
    out[#out + 1] = favs[j]
  end
  for j = 1, #rest do
    out[#out + 1] = rest[j]
  end
  return out
end

-- Forward declare (Lua 5.1 local scoping): refresh_preview, wx_custom_*, wx_bridge_transport_strip (assigned after wx_custom_small_button).
local refresh_preview
local wx_custom_slider_int
local wx_custom_combo
local wx_custom_button
local wx_custom_small_button
local wx_bridge_transport_strip

local function font_selector_ui(ctx, item)
  ensure_font_items(false)
  if #state.font_items == 0 and not state.font_scan_attempted then
    ensure_font_items(true)
  end

  local filtered = font_items_filtered()
  local font_items = { "<Default system fallback>" }
  local selected_idx = 0
  local current_seen = (state.font_name or "") == ""
  for i = 1, #filtered do
    local nm = filtered[i].name
    font_items[#font_items + 1] = nm
    if state.font_name == nm then
      selected_idx = #font_items - 1
      current_seen = true
    end
  end
  if not current_seen and trim(state.font_name or "") ~= "" then
    font_items[#font_items + 1] = state.font_name
    selected_idx = #font_items - 1
  end

  local font_items_str = table.concat(font_items, "\0") .. "\0"
  local function font_combo_popup_header_wrap(ctx2, inner_w, pw, fs, style_idx)
    local rv_fil = false
    local new_fil = state.font_combo_filter
    if ImGui.PushItemWidth then
      ImGui.PushItemWidth(ctx2, inner_w)
    end
    if ImGui.InputTextWithHint then
      rv_fil, new_fil = ImGui.InputTextWithHint(
        ctx2,
        "##font_filter",
        "Filter fonts…",
        state.font_combo_filter or ""
      )
    elseif ImGui.InputText then
      rv_fil, new_fil = ImGui.InputText(ctx2, "Filter##font_filter", state.font_combo_filter or "", 256)
    end
    if ImGui.PopItemWidth then
      ImGui.PopItemWidth(ctx2)
    end
    if rv_fil then
      state.font_combo_filter = new_fil or ""
      r.SetExtState(SECTION, "FONT_COMBO_FILTER", state.font_combo_filter, true)
    end

    if wx_custom_small_button(ctx2, "Rescan fonts##font_rescan", style_idx) then
      ensure_font_items(true)
    end
    if trim(state.font_name or "") ~= "" then
      ImGui.SameLine(ctx2, 0, 8)
      local is_fav = state.font_favorites[state.font_name] and true or false
      if wx_custom_small_button(ctx2, (is_fav and "★" or "☆") .. "##font_fav_current", style_idx) then
        font_toggle_favorite(state.font_name)
      end
    end

    if #font_items == 1 and #state.font_items == 0 then
      ImGui.TextColored(ctx2, 0x888888FF, "No system fonts found.")
    elseif #font_items == 1 then
      ImGui.TextColored(ctx2, 0x888888FF, "No fonts match filter.")
    end

    if ImGui.Separator then
      ImGui.Separator(ctx2)
    end
  end

  local rv_font, next_idx = wx_custom_combo(
    ctx,
    "##font_wx",
    "Font",
    selected_idx,
    font_items_str,
    240,
    state.wx_slider_style,
    font_combo_popup_header_wrap
  )
  if rv_font then
    local nm = font_items[(next_idx or 0) + 1] or ""
    if (next_idx or 0) == 0 then
      nm = ""
    end
    state.font_name = nm
    r.SetExtState(SECTION, "FONT_NAME", state.font_name, true)
    refresh_preview(item)
    overlay_request_autosave()
  end
end

state.ml_preset_names = ml_preset_names_load()
if #state.ml_preset_names > 0 then
  local def_name, def_idx = ml_preset_find_default_name()
  if def_name and def_idx then
    local blob = es_get(ml_preset_key(def_name), "")
    if blob ~= "" then
      ml_preset_apply_blob(blob)
    end
    state.ml_preset_name = def_name
    state.ml_preset_idx = def_idx - 1
  else
    local idx = ml_preset_find_idx(state.ml_preset_name)
    if idx then
      state.ml_preset_idx = idx - 1
    else
      state.ml_preset_idx = 0
      state.ml_preset_name = state.ml_preset_names[1]
    end
  end
end

state.anim_preset_names = anim_preset_names_load()
if #state.anim_preset_names > 0 then
  local def_name, def_idx = anim_preset_find_default_name()
  if def_name and def_idx then
    local blob = es_get(anim_preset_key(def_name), "")
    if blob ~= "" then
      anim_preset_apply_blob(blob)
    end
    state.anim_preset_name = def_name
    state.anim_preset_idx = def_idx - 1
  else
    local idx = anim_preset_find_idx(state.anim_preset_name)
    if idx then
      state.anim_preset_idx = idx - 1
    else
      state.anim_preset_idx = 0
      state.anim_preset_name = state.anim_preset_names[1]
    end
  end
end

local word_style_is_empty
local word_style_defaults

local function display_opts_from_state(words_for_scale)
  local karaoke = state.ml_timing_mode ~= 1
  local video_guides = nil
  for _, guide in ipairs(VIDEO_RATIO_GUIDES) do
    if state.video_guides and state.video_guides[guide.id] then
      video_guides = video_guides or {}
      video_guides[#video_guides + 1] = {
        label = guide.label,
        ratio = guide.ratio,
        color = guide.color,
      }
    end
  end
  local ls, lr, jit = {}, {}, {}
  for i = 1, 6 do
    ls[i] = state.ml_s[i]
    lr[i] = state.ml_r[i]
    jit[i] = state.ml_jitter[i]
  end
  local wscale = nil
  if type(words_for_scale) == "table" and #words_for_scale > 0 then
    wscale = {}
    for i = 1, #words_for_scale do
      wscale[i] = state.ml_word_scales[i] or 1
    end
  end
  local row_indent = nil
  if type(words_for_scale) == "table" and #words_for_scale > 0 then
    row_indent = {}
    for i = 1, #words_for_scale do
      row_indent[i] = state.ml_row_indents[i] or 0
    end
  end
  local row_gap = nil
  if type(words_for_scale) == "table" and #words_for_scale > 0 then
    for i = 1, #words_for_scale do
      if state.ml_row_spacings and state.ml_row_spacings[i] ~= nil then
        row_gap = row_gap or {}
        row_gap[i] = state.ml_row_spacings[i]
      end
    end
  end
  local wstyles = nil
  --- Snapshot for triple CJK minimal parse (`parse_editor_phrases_for_multiline` uses markers + flags only).
  local ml_pa_tabs, ml_ra_tabs = nil, nil
  if type(words_for_scale) == "table" and #words_for_scale > 0 then
    local nw = #words_for_scale
    ml_pa_tabs, ml_ra_tabs = {}, {}
    for i = 1, nw - 1 do
      ml_pa_tabs[i] = state.ml_phrase_after[i] and true or false
      ml_ra_tabs[i] = state.ml_row_after[i] and true or false
    end
  end
  if type(words_for_scale) == "table" and #words_for_scale > 0 then
    for i = 1, #words_for_scale do
      local st = state.word_styles and state.word_styles[i]
      if not word_style_is_empty(st) then
        word_style_defaults(st)
        wstyles = wstyles or {}
        wstyles[i] = {
          flags = math.max(0, math.floor(tonumber(st.flags) or 0)),
          text_color = st.text_color,
          highlight_color = st.highlight_color,
          pseudo_bold_copies = st.pseudo_bold_copies,
          pseudo_bold_offset = st.pseudo_bold_offset,
          pseudo_slant = st.pseudo_slant,
          shadow_dx = st.shadow_dx,
          shadow_dy = st.shadow_dy,
          shadow_alpha = st.shadow_alpha,
          underline_thick = st.underline_thick,
          underline_offset = st.underline_offset,
          outline_thickness = st.outline_thickness,
          outline_gap = st.outline_gap,
          outline_color = st.outline_color,
          anim_preset_name = trim(st.anim_preset_name or ""),
        }
      end
    end
  end
  return {
    preset = W.PRESET_LINE_TRIPLE,
    words_per_line = state.words_per_line,
    max_chars = state.max_chars,
    break_after_sentence = state.break_sentence,
    editor_text = state.editor_text,
    karaoke = karaoke,
    ml_timing_mode = state.ml_timing_mode,
    layout_max_rows = state.ml_max_rows,
    layout_line_scales = ls,
    layout_line_rand = lr,
    layout_line_gap = state.ml_line_gap,
    layout_rand_jitter = jit,
    layout_ml_row_chars = state.ml_row_chars,
    layout_ml_row_chars_rand = state.ml_row_chars_rand,
    layout_row_v_align = state.ml_row_v_align,
    layout_ml_chars_seed = state.ml_chars_seed,
    layout_indent_step = state.ml_indent_step,
    layout_indent_rand = state.ml_indent_rand,
    layout_indent_seed = state.ml_indent_seed,
    layout_word_scale = wscale,
    layout_row_indent = row_indent,
    layout_row_gap = row_gap,
    ml_phrase_after = ml_pa_tabs,
    ml_row_after = ml_ra_tabs,
    video_guides = video_guides,
    word_styles = wstyles,
    anim_scope = state.anim_scope,
    anim_in_on = state.anim_in_on,
    anim_in_type = anim_type_to_core(state.anim_in_type),
    anim_in_curve = state.anim_in_curve,
    anim_in_dur = state.anim_in_dur,
    anim_in_amp = state.anim_in_amp,
    anim_in_bounce = state.anim_in_bounce,
    anim_in_motion = state.anim_in_motion,
    anim_in_wiggle = state.anim_in_wiggle,
    anim_in_scale = state.anim_in_scale,
    anim_in_fade = state.anim_in_fade,
    anim_in_blur = state.anim_in_blur,
    anim_in_ghost = state.anim_in_ghost,
    anim_in_dupes = state.anim_in_dupes,
    anim_in_dir = state.anim_in_dir,
    anim_in_twist = state.anim_in_twist,
    anim_in_use_graph = state.anim_in_use_graph and true or false,
    anim_in_graph_word_span = state.anim_in_graph_word_span and true or false,
    anim_in_graph = state.anim_in_graph_blob or anim_graph_default_blob(),
    anim_in_auto_blob = state.anim_in_graph_auto_blob or "",
    anim_out_on = state.anim_out_on,
    anim_out_type = anim_type_to_core(state.anim_out_type),
    anim_out_curve = state.anim_out_curve,
    anim_out_dur = state.anim_out_dur,
    anim_out_amp = state.anim_out_amp,
    anim_out_bounce = state.anim_out_bounce,
    anim_out_motion = state.anim_out_motion,
    anim_out_wiggle = state.anim_out_wiggle,
    anim_out_scale = state.anim_out_scale,
    anim_out_fade = state.anim_out_fade,
    anim_out_blur = state.anim_out_blur,
    anim_out_ghost = state.anim_out_ghost,
    anim_out_dupes = state.anim_out_dupes,
    anim_out_dir = state.anim_out_dir,
    anim_out_twist = state.anim_out_twist,
    anim_out_use_graph = state.anim_out_use_graph and true or false,
    anim_out_graph_word_span = state.anim_out_graph_word_span and true or false,
    anim_out_graph = state.anim_out_graph_blob or anim_graph_default_blob(),
    anim_out_auto_blob = state.anim_out_graph_auto_blob or "",
    anim_phrase_out_on = state.anim_phrase_out_on,
    anim_phrase_out_type = anim_type_to_core(state.anim_phrase_out_type),
    anim_phrase_out_curve = state.anim_phrase_out_curve,
    anim_phrase_out_dur = state.anim_phrase_out_dur,
    anim_phrase_out_amp = state.anim_phrase_out_amp,
    anim_phrase_out_bounce = state.anim_phrase_out_bounce,
    anim_phrase_out_motion = state.anim_phrase_out_motion,
    anim_phrase_out_wiggle = state.anim_phrase_out_wiggle,
    anim_phrase_out_scale = state.anim_phrase_out_scale,
    anim_phrase_out_fade = state.anim_phrase_out_fade,
    anim_phrase_out_blur = state.anim_phrase_out_blur,
    anim_phrase_out_ghost = state.anim_phrase_out_ghost,
    anim_phrase_out_dupes = state.anim_phrase_out_dupes,
    anim_phrase_out_dir = state.anim_phrase_out_dir,
    anim_phrase_out_twist = state.anim_phrase_out_twist,
    anim_wipe_mask_offset = state.anim_wipe_mask_offset,
    anim_phrase_out_use_graph = state.anim_phrase_out_use_graph and true or false,
    anim_phrase_out_graph_word_span = state.anim_phrase_out_graph_word_span and true or false,
    anim_phrase_out_graph = state.anim_phrase_out_graph_blob or state.anim_out_graph_blob or anim_graph_default_blob(),
    anim_phrase_out_auto_blob = state.anim_phrase_out_graph_auto_blob or state.anim_out_graph_auto_blob or "",
    font_name = trim(state.font_name or ""),
    img_post_wave = state.img_post_wave and true or false,
    img_post_wave_amp = state.img_post_wave_amp,
    img_post_wave_len = state.img_post_wave_len,
    img_post_wave_speed = state.img_post_wave_speed,
  }
end

--- True if `editor_text` parses against current marker words (triple-stack phrases).
local function editor_text_parse_ok(words, editor_text)
  if not words or #words == 0 or type(editor_text) ~= "string" then
    return false
  end
  local opts = display_opts_from_state(words)
  return W.parse_editor_phrases_for_multiline(words, editor_text, opts) and true
end


local IS_MAC = false
do
  local os = (r.GetOS and r.GetOS()) or ""
  local osl = os:lower()
  IS_MAC = osl:find("mac", 1, true) ~= nil or os:find("OSX", 1, true) ~= nil
end

--- Bitmasks for GetKeyMods; 0 if this ReaImGui build does not expose them as numbers.
local Mod_Ctrl, Mod_Alt, Mod_Shift, Mod_Super = 0, 0, 0, 0
do
  local function mod_bit(name)
    local ok, v = pcall(function()
      return ImGui[name]
    end)
    if ok and type(v) == "number" then
      return v
    end
    return 0
  end
  Mod_Ctrl = mod_bit("Mod_Ctrl")
  Mod_Alt = mod_bit("Mod_Alt")
  Mod_Shift = mod_bit("Mod_Shift")
  Mod_Super = mod_bit("Mod_Super")
end

local function overlay_mods_now(ctx)
  if ImGui.GetKeyMods then
    local ok, m = pcall(ImGui.GetKeyMods, ctx)
    if ok and type(m) == "number" then
      return m
    end
  end
  return 0
end

--- Prefer IsKeyDown (Dear ImGui demo style); fall back to GetKeyMods bitmasks.
local function overlay_mod_ctrl(ctx)
  if ImGui.IsKeyDown and ImGui.Mod_Ctrl then
    local ok, d = pcall(ImGui.IsKeyDown, ctx, ImGui.Mod_Ctrl)
    if ok and d then
      return true
    end
  end
  if IS_MAC and ImGui.IsKeyDown and ImGui.Mod_Super then
    local ok, d = pcall(ImGui.IsKeyDown, ctx, ImGui.Mod_Super)
    if ok and d then
      return true
    end
  end
  local mods = overlay_mods_now(ctx)
  if Mod_Ctrl ~= 0 and (mods & Mod_Ctrl) ~= 0 then
    return true
  end
  if IS_MAC and Mod_Super ~= 0 and (mods & Mod_Super) ~= 0 then
    return true
  end
  return false
end

local function overlay_mod_alt(ctx)
  if ImGui.IsKeyDown and ImGui.Mod_Alt then
    local ok, d = pcall(ImGui.IsKeyDown, ctx, ImGui.Mod_Alt)
    if ok and d then
      return true
    end
  end
  local mods = overlay_mods_now(ctx)
  return Mod_Alt ~= 0 and (mods & Mod_Alt) ~= 0
end

local function overlay_mod_shift(ctx)
  if ImGui.IsKeyDown and ImGui.Mod_Shift then
    local ok, d = pcall(ImGui.IsKeyDown, ctx, ImGui.Mod_Shift)
    if ok and d then
      return true
    end
  end
  local mods = overlay_mods_now(ctx)
  return Mod_Shift ~= 0 and (mods & Mod_Shift) ~= 0
end

local function overlay_mod_ctrl_shift(ctx)
  return overlay_mod_ctrl(ctx) and overlay_mod_shift(ctx)
end

local MOUSE_LEFT = (ImGui.MouseButton_Left ~= nil) and ImGui.MouseButton_Left or 0
local MOUSE_RIGHT = (ImGui.MouseButton_Right ~= nil) and ImGui.MouseButton_Right or 1

--- Set after `write_vp_for_item` is defined (captures upvalue for `word_grid_ui`).
local auto_persist_layout

--- ReaImGui drag-drop payload id for word-index (1..n) in the marker grid.
local WX_WORD = "WX_WORD"

local WSTYLE_BOLD = 1
local WSTYLE_ITALIC = 2
local WSTYLE_SHADOW = 4
local WSTYLE_HIGHLIGHT = 8
local WSTYLE_OUTLINE = 16
local WSTYLE_UNDERLINE = 32
local WSTYLE_PSEUDO_BOLD = 64
local WSTYLE_PSEUDO_SLANT = 128

local WORD_DEFAULT_COLORS = {
  { "White", 0xFFFFFF },
  { "Yellow", 0xFFE66D },
  { "Cyan", 0x6DEBFF },
  { "Magenta", 0xFF6DFF },
  { "Red", 0xFF5F5F },
  { "Green", 0x69F06D },
  { "Blue", 0x6D9CFF },
  { "Orange", 0xFFB347 },
}

local WORD_DEFAULT_HIGHLIGHTS = {
  { "Gold", 0xFFD34D },
  { "Blue", 0x2878FF },
  { "Purple", 0x9C5CFF },
  { "Red", 0xFF4050 },
  { "Green", 0x34D060 },
}

local function ml_parse_bits(s, n)
  local t = {}
  for i = 1, math.max(0, n - 1) do
    t[i] = string.sub(s or "", i, i) == "1"
  end
  return t
end

local function ml_bits_pack(t, n)
  local p = {}
  for i = 1, n - 1 do
    p[i] = (t[i] and "1") or "0"
  end
  return table.concat(p)
end

local function ml_parse_scales(s, n)
  local t = {}
  for i = 1, n do
    t[i] = 1
  end
  if type(s) ~= "string" or s == "" then
    return t
  end
  local i = 1
  for tok in string.gmatch(s, "[^,]+") do
    if i > n then
      break
    end
    t[i] = math.max(0.15, math.min(4, tonumber(tok) or 1))
    i = i + 1
  end
  return t
end

local function ml_parse_indents(s, n)
  local t = {}
  for i = 1, n do
    t[i] = 0
  end
  if type(s) ~= "string" or s == "" then
    return t
  end
  local i = 1
  for tok in string.gmatch(s, "[^,]+") do
    if i > n then
      break
    end
    t[i] = math.max(-0.5, math.min(0.5, tonumber(tok) or 0))
    i = i + 1
  end
  return t
end

local function ml_scales_pack(t, n)
  local p = {}
  for i = 1, n do
    p[i] = string.format("%.17g", t[i] or 1)
  end
  return table.concat(p, ",")
end

local function ml_indents_pack(t, n)
  local p = {}
  for i = 1, n do
    p[i] = string.format("%.17g", t[i] or 0)
  end
  return table.concat(p, ",")
end

local function ml_parse_row_spacings(s, n)
  local t = {}
  if type(s) ~= "string" or s == "" then
    return t
  end
  for _, tok in ipairs(split_sep(s, ML_PRESET_SEP)) do
    local k, v = tostring(tok):match("^(%d+):([%-%d%.eE]+)$")
    k, v = tonumber(k), tonumber(v)
    if k and v and k >= 1 and k <= n then
      t[k] = math.max(-0.95, math.min(1.5, v))
    end
  end
  return t
end

local function ml_row_spacings_pack(t, n)
  local p = {}
  if type(t) ~= "table" then
    return ""
  end
  for i = 1, n do
    local v = t[i]
    if v ~= nil then
      p[#p + 1] = tostring(i) .. ":" .. string.format("%.17g", math.max(-0.95, math.min(1.5, tonumber(v) or 0.1)))
    end
  end
  return table.concat(p, ML_PRESET_SEP)
end

word_style_is_empty = function(st)
  if type(st) ~= "table" then
    return true
  end
  local apn = trim(st.anim_preset_name or "")
  return (tonumber(st.flags) or 0) == 0 and st.text_color == nil and st.highlight_color == nil and apn == ""
end

word_style_defaults = function(st)
  st = st or {}
  st.flags = math.max(0, math.floor(tonumber(st.flags) or 0))
  st.pseudo_bold_copies = math.max(1, math.min(8, math.floor(tonumber(st.pseudo_bold_copies) or 2)))
  st.pseudo_bold_offset = math.max(0.25, math.min(6, tonumber(st.pseudo_bold_offset) or 1))
  st.pseudo_slant = math.max(-12, math.min(12, tonumber(st.pseudo_slant) or 2))
  st.shadow_dx = math.max(-20, math.min(20, tonumber(st.shadow_dx) or 2))
  st.shadow_dy = math.max(-20, math.min(20, tonumber(st.shadow_dy) or 2))
  st.shadow_alpha = math.max(0, math.min(1, tonumber(st.shadow_alpha) or 0.55))
  st.underline_thick = math.max(1, math.min(12, tonumber(st.underline_thick) or 1))
  st.underline_offset = math.max(-8, math.min(16, tonumber(st.underline_offset) or 1))
  st.outline_thickness = math.max(1, math.min(12, math.floor(tonumber(st.outline_thickness) or 2)))
  st.outline_gap = math.max(0, math.min(24, math.floor(tonumber(st.outline_gap) or 0)))
  do
    local oc = tonumber(st.outline_color)
    st.outline_color = oc and math.max(0, math.min(0xFFFFFF, math.floor(oc))) or 0
  end
  st.anim_preset_name = trim(st.anim_preset_name or "")
  return st
end

local function word_palette_load_for_item(item)
  local pal = {}
  local seen = {}
  for i = 1, #WORD_DEFAULT_COLORS do
    local c = WORD_DEFAULT_COLORS[i][2]
    pal[#pal + 1] = c
    seen[c] = true
  end
  for i = 1, #WORD_DEFAULT_HIGHLIGHTS do
    local c = WORD_DEFAULT_HIGHLIGHTS[i][2]
    if not seen[c] then
      pal[#pal + 1] = c
      seen[c] = true
    end
  end
  if item and r.GetSetMediaItemInfo_String then
    local ok, s = r.GetSetMediaItemInfo_String(item, ITEM_EXT.WORD_PALETTE, "", false)
    if ok and type(s) == "string" and s ~= "" then
      for _, tok in ipairs(split_sep(s, ML_PRESET_SEP)) do
        local c = tonumber(tok)
        if c then
          c = math.max(0, math.min(0xFFFFFF, math.floor(c)))
          if not seen[c] then
            pal[#pal + 1] = c
            seen[c] = true
          end
        end
      end
    end
  else
    for _, tok in ipairs(split_sep(es_get("WORD_COLOR_PALETTE", ""), ML_PRESET_SEP)) do
      local c = tonumber(tok)
      if c then
        c = math.max(0, math.min(0xFFFFFF, math.floor(c)))
        if not seen[c] then
          pal[#pal + 1] = c
          seen[c] = true
        end
      end
    end
  end
  state.word_color_palette = pal
end

local function word_palette_persist(item)
  local vals = {}
  local seen = {}
  for i = 1, #(state.word_color_palette or {}) do
    local c = tonumber(state.word_color_palette[i])
    if c then
      c = math.max(0, math.min(0xFFFFFF, math.floor(c)))
      if not seen[c] then
        vals[#vals + 1] = tostring(c)
        seen[c] = true
      end
    end
  end
  local s = table.concat(vals, ML_PRESET_SEP)
  if item and r.GetSetMediaItemInfo_String then
    r.GetSetMediaItemInfo_String(item, ITEM_EXT.WORD_PALETTE, s, true)
  else
    r.SetExtState(SECTION, "WORD_COLOR_PALETTE", s, true)
  end
end

local function word_palette_add(c, item)
  c = tonumber(c)
  if not c then
    return
  end
  c = math.max(0, math.min(0xFFFFFF, math.floor(c)))
  state.word_color_palette = state.word_color_palette or {}
  for i = 1, #state.word_color_palette do
    if state.word_color_palette[i] == c then
      return
    end
  end
  state.word_color_palette[#state.word_color_palette + 1] = c
  word_palette_persist(item)
end

word_palette_load_for_item(nil)

local function word_styles_parse(blob, n)
  local out = {}
  n = math.max(0, math.floor(tonumber(n) or 0))
  if type(blob) ~= "string" or blob == "" then
    return out
  end
  for rec in blob:gmatch("[^;]+") do
    local parts = split_sep(rec, ":")
    local wi = tonumber(parts[1])
    local flags = parts[2]
    local textc = parts[3]
    local highc = parts[4]
    wi = tonumber(wi)
    if wi and wi >= 1 and wi <= n then
      local st = {
        flags = math.max(0, math.floor(tonumber(flags) or 0)),
      }
      local tc = tonumber(textc)
      if tc then
        st.text_color = math.max(0, math.min(0xFFFFFF, math.floor(tc)))
      end
      local hc = tonumber(highc)
      if hc then
        st.highlight_color = math.max(0, math.min(0xFFFFFF, math.floor(hc)))
      end
      st.pseudo_bold_copies = tonumber(parts[5])
      st.pseudo_bold_offset = tonumber(parts[6])
      st.pseudo_slant = tonumber(parts[7])
      st.shadow_dx = tonumber(parts[8])
      st.shadow_dy = tonumber(parts[9])
      st.shadow_alpha = tonumber(parts[10])
      st.underline_thick = tonumber(parts[11])
      st.underline_offset = tonumber(parts[12])
      st.anim_preset_name = trim(parts[13] or "")
      st.outline_thickness = tonumber(parts[14])
      st.outline_gap = tonumber(parts[15])
      local oc = tonumber(parts[16])
      if oc then
        st.outline_color = math.max(0, math.min(0xFFFFFF, math.floor(oc)))
      end
      word_style_defaults(st)
      if not word_style_is_empty(st) then
        out[wi] = st
      end
    end
  end
  return out
end

local function word_styles_pack(styles, n)
  local recs = {}
  n = math.max(0, math.floor(tonumber(n) or 0))
  for wi = 1, n do
    local st = styles and styles[wi]
    if not word_style_is_empty(st) then
      word_style_defaults(st)
      recs[#recs + 1] = table.concat({
        tostring(wi),
        tostring(math.max(0, math.floor(tonumber(st.flags) or 0))),
        st.text_color and tostring(math.floor(st.text_color)) or "",
        st.highlight_color and tostring(math.floor(st.highlight_color)) or "",
        tostring(st.pseudo_bold_copies),
        string.format("%.17g", st.pseudo_bold_offset),
        string.format("%.17g", st.pseudo_slant),
        string.format("%.17g", st.shadow_dx),
        string.format("%.17g", st.shadow_dy),
        string.format("%.17g", st.shadow_alpha),
        string.format("%.17g", st.underline_thick),
        string.format("%.17g", st.underline_offset),
        trim(st.anim_preset_name or ""):gsub("[:;]", "_"),
        tostring(math.floor(st.outline_thickness or 2)),
        tostring(math.floor(st.outline_gap or 0)),
        tostring(math.floor(st.outline_color or 0)),
      }, ":")
    end
  end
  return table.concat(recs, ";")
end

local function persist_word_styles(n, item)
  n = math.max(0, math.floor(tonumber(n) or state.ml_word_n or 0))
  local blob = word_styles_pack(state.word_styles, n)
  if item and r.GetSetMediaItemInfo_String then
    r.GetSetMediaItemInfo_String(item, ITEM_EXT.WORD_STYLES, blob, true)
  else
    r.SetExtState(SECTION, "WORD_STYLE_BLOB", blob, true)
  end
end

local function word_style_get(wi)
  state.word_styles = state.word_styles or {}
  local st = state.word_styles[wi]
  if type(st) ~= "table" then
    st = { flags = 0 }
    state.word_styles[wi] = st
  end
  return word_style_defaults(st)
end

local function word_style_toggle_flag(wi, flag)
  local st = word_style_get(wi)
  if (st.flags & flag) ~= 0 then
    st.flags = st.flags & (~flag)
  else
    st.flags = st.flags | flag
  end
  if word_style_is_empty(st) then
    state.word_styles[wi] = nil
  end
end

local function word_style_preset_key(name)
  local safe = (trim(name or ""):gsub("[^%w%-_]", "_"))
  if safe == "" then
    safe = "_"
  end
  return "WORD_STYLE_PRESET_DATA_" .. safe
end

local function word_style_preset_names_load()
  local names = {}
  local seen = {}
  for _, nm in ipairs(split_sep(es_get("WORD_STYLE_PRESET_NAMES", ""), ML_PRESET_SEP)) do
    nm = trim(nm)
    if nm ~= "" and not seen[nm] then
      names[#names + 1] = nm
      seen[nm] = true
    end
  end
  table.sort(names)
  return names
end

local function word_style_preset_names_save()
  r.SetExtState(SECTION, "WORD_STYLE_PRESET_NAMES", table.concat(state.word_style_preset_names, ML_PRESET_SEP), true)
end

local function word_style_preset_find_idx(name)
  for i = 1, #state.word_style_preset_names do
    if state.word_style_preset_names[i] == name then
      return i
    end
  end
  return nil
end

local function word_style_copy(st)
  if word_style_is_empty(st) then
    return nil
  end
  word_style_defaults(st)
  return {
    flags = st.flags,
    text_color = st.text_color,
    highlight_color = st.highlight_color,
    pseudo_bold_copies = st.pseudo_bold_copies,
    pseudo_bold_offset = st.pseudo_bold_offset,
    pseudo_slant = st.pseudo_slant,
    shadow_dx = st.shadow_dx,
    shadow_dy = st.shadow_dy,
    shadow_alpha = st.shadow_alpha,
    underline_thick = st.underline_thick,
    underline_offset = st.underline_offset,
    outline_thickness = st.outline_thickness,
    outline_gap = st.outline_gap,
    outline_color = st.outline_color,
    anim_preset_name = trim(st.anim_preset_name or ""),
  }
end

local function word_style_preset_blob_from_style(st)
  local cp = word_style_copy(st)
  if not cp then
    return ""
  end
  return word_styles_pack({ [1] = cp }, 1)
end

local function word_style_preset_apply_blob(wi, blob)
  local parsed = word_styles_parse(blob or "", 1)
  local st = parsed and parsed[1]
  if word_style_is_empty(st) then
    return false, "Style preset is empty."
  end
  state.word_styles[wi] = word_style_copy(st)
  return true
end

local function word_style_preset_save_named(name, st)
  name = trim(name or "")
  if name == "" then
    return false, "Preset name is empty."
  end
  local blob = word_style_preset_blob_from_style(st)
  if blob == "" then
    return false, "Current word style is empty."
  end
  r.SetExtState(SECTION, word_style_preset_key(name), blob, true)
  if not word_style_preset_find_idx(name) then
    state.word_style_preset_names[#state.word_style_preset_names + 1] = name
    table.sort(state.word_style_preset_names)
    word_style_preset_names_save()
  end
  state.word_style_preset_name = name
  state.word_style_preset_save_name = name
  r.SetExtState(SECTION, "WORD_STYLE_PRESET_LAST", name, true)
  return true
end

local function word_style_preset_delete_named(name)
  name = trim(name or "")
  if name == "" then
    return false, "Preset name is empty."
  end
  local idx = word_style_preset_find_idx(name)
  if idx then
    table.remove(state.word_style_preset_names, idx)
    word_style_preset_names_save()
  end
  r.SetExtState(SECTION, word_style_preset_key(name), "", true)
  if state.word_style_preset_name == name then
    state.word_style_preset_name = state.word_style_preset_names[1] or ""
    r.SetExtState(SECTION, "WORD_STYLE_PRESET_LAST", state.word_style_preset_name, true)
  end
  return true
end

state.word_style_preset_names = word_style_preset_names_load()

local function ml_load_for_word_count(n, item)
  if n < 1 then
    state.ml_phrase_after = {}
    state.ml_row_after = {}
    state.ml_word_scales = {}
    state.ml_row_indents = {}
    state.ml_row_spacings = {}
    state.word_styles = {}
    return
  end
  local blob = ""
  if item and r.GetSetMediaItemInfo_String then
    local ok, s = r.GetSetMediaItemInfo_String(item, ITEM_EXT.WORD_STYLES, "", false)
    if ok and type(s) == "string" then
      blob = s
    end
  end
  state.word_styles = word_styles_parse(blob, n)
  local row_spacing_blob = ""
  if item and r.GetSetMediaItemInfo_String then
    local ok, s = r.GetSetMediaItemInfo_String(item, ITEM_EXT.ROW_SPACING, "", false)
    if ok and type(s) == "string" then
      row_spacing_blob = s
    end
  end
  state.ml_row_spacings = ml_parse_row_spacings(row_spacing_blob, n)
  if n < 2 then
    state.ml_phrase_after = {}
    state.ml_row_after = {}
    local sc = es_get("ML_WORDSCALE", "")
    local ind = es_get("ML_ROW_INDENT", "")
    state.ml_word_scales = ml_parse_scales(sc, n)
    state.ml_row_indents = ml_parse_indents(ind, n)
    return
  end
  local pa = es_get("ML_PHRASE_AFTER", "")
  local ra = es_get("ML_ROW_AFTER", "")
  local sc = es_get("ML_WORDSCALE", "")
  local ind = es_get("ML_ROW_INDENT", "")
  if #pa == n - 1 then
    state.ml_phrase_after = ml_parse_bits(pa, n)
  else
    state.ml_phrase_after = {}
    for i = 1, n - 1 do
      state.ml_phrase_after[i] = false
    end
  end
  if #ra == n - 1 then
    state.ml_row_after = ml_parse_bits(ra, n)
  else
    state.ml_row_after = {}
    for i = 1, n - 1 do
      state.ml_row_after[i] = false
    end
  end
  state.ml_word_scales = ml_parse_scales(sc, n)
  state.ml_row_indents = ml_parse_indents(ind, n)
end

--- Keep current triple layout as much as possible when marker count changes on the same item.
local function ml_preserve_layout_for_new_count(n)
  n = math.max(0, math.floor(tonumber(n) or 0))
  local old_n = math.max(0, math.floor(tonumber(state.ml_word_n) or 0))
  local old_pa, old_ra, old_sc, old_ind, old_gap = state.ml_phrase_after, state.ml_row_after, state.ml_word_scales, state.ml_row_indents, state.ml_row_spacings
  local old_styles = state.word_styles
  state.ml_phrase_after, state.ml_row_after, state.ml_word_scales, state.ml_row_indents, state.ml_row_spacings = {}, {}, {}, {}, {}
  state.word_styles = {}
  for i = 1, math.max(0, n - 1) do
    state.ml_phrase_after[i] = false
    state.ml_row_after[i] = false
  end
  for i = 1, n do
    state.ml_word_scales[i] = 1
    state.ml_row_indents[i] = 0
  end
  if old_n > 0 then
    local m_br = math.min(math.max(0, old_n - 1), math.max(0, n - 1))
    for i = 1, m_br do
      state.ml_phrase_after[i] = old_pa[i] and true or false
      state.ml_row_after[i] = old_ra[i] and true or false
    end
    local m_sc = math.min(old_n, n)
    for i = 1, m_sc do
      state.ml_word_scales[i] = tonumber(old_sc[i]) or 1
      state.ml_row_indents[i] = tonumber(old_ind[i]) or 0
      if type(old_gap) == "table" and old_gap[i] ~= nil then
        state.ml_row_spacings[i] = tonumber(old_gap[i]) or nil
      end
      if type(old_styles) == "table" and old_styles[i] then
        state.word_styles[i] = old_styles[i]
      end
    end
  end
  state.ml_word_n = n
end

local function ml_sync_editor_text(words)
  if not words or #words == 0 then
    state.editor_text = ""
    return
  end
  state.editor_text = W.editor_text_from_ml_after_flags(words, state.ml_phrase_after, state.ml_row_after)
end

refresh_preview = function(item)
  state.preview_words = 0
  state.preview_lines = 0
  state.preview_segs = 0
  state.preview_parse_err = ""
  state.parse_hint = nil
  if not item then
    return
  end
  if r.ValidatePtr and not r.ValidatePtr(item, "MediaItem*") then
    return
  end
  local take, words = W.find_take_and_wx_words(item)
  if not take or #words == 0 then
    return
  end
  state.preview_words = #words
  state.ml_word_n = #words
  ml_sync_editor_text(words)
  local opts = display_opts_from_state(words)
  local src_end = W.source_length_for_take(take)

  if type(state.editor_text) == "string" and state.editor_text ~= "" then
    local ph, gerr, ghint = W.parse_editor_phrases_for_multiline(words, state.editor_text, opts)
    --- Do not clear `ml_phrase_after` / `ml_row_after` on parse failure: that threw away phrase splits
    --- (e.g. embedded newlines in marker text, rare "|" in a word) and made triple UI feel "stuck".
    state.parse_hint = ghint
    if ph then
      state.preview_lines = #ph
    else
      state.preview_lines = 0
      state.preview_parse_err = gerr or "Invalid editor text."
    end
  else
    local lines = W.split_words_into_lines(words, opts.words_per_line, opts.max_chars, opts.break_after_sentence)
    state.preview_lines = #lines
  end

  opts.editor_text = state.editor_text or ""

  local segs, serr, shint = W.build_display_segments(words, src_end, opts)
  if shint then
    state.parse_hint = shint
  end
  if not segs then
    state.preview_segs = 0
    state.preview_parse_err = serr or state.preview_parse_err
    return
  end
  state.preview_segs = #segs
end

local function ml_phrase_range_end(k, n)
  for j = k, n - 1 do
    if state.ml_phrase_after[j] then
      return j
    end
  end
  return n
end

local function ml_ctrl_phrase(k, n)
  if k < 1 or k >= n then
    return
  end
  local e = ml_phrase_range_end(k, n)
  for j = k + 1, e - 1 do
    state.ml_phrase_after[j] = false
    state.ml_row_after[j] = false
  end
  state.ml_phrase_after[k] = true
  state.ml_row_after[k] = true
end

local function ml_alt_row(k, n)
  if k < 1 or k >= n then
    return
  end
  local e = ml_phrase_range_end(k, n)
  for j = k + 1, e - 1 do
    state.ml_row_after[j] = false
  end
  state.ml_row_after[k] = true
end

local function ml_phrase_ranges(n)
  local r = {}
  local s = 1
  while s <= n do
    local e = n
    for j = s, n - 1 do
      if state.ml_phrase_after[j] then
        e = j
        break
      end
    end
    r[#r + 1] = { s, e }
    s = e + 1
  end
  return r
end

local function ml_row_ranges_in(s, e)
  local r = {}
  local a = s
  while a <= e do
    local b = e
    for j = a, e - 1 do
      if state.ml_row_after[j] then
        b = j
        break
      end
    end
    r[#r + 1] = { a, b }
    a = b + 1
  end
  return r
end

--- `kind`: "indent" | "rowsp" | "styles" | "all" — only affects word indices ps..pe (one phrase).
local function ml_phrase_reset_layout(kind, ps, pe, n, item, words, ctx)
  local rows = ml_row_ranges_in(ps, pe)
  if kind == "indent" or kind == "all" then
    for ri = 1, #rows do
      state.ml_row_indents[rows[ri][1]] = 0
    end
  end
  if kind == "rowsp" or kind == "all" then
    for ri = 1, #rows - 1 do
      state.ml_row_spacings[rows[ri + 1][1]] = nil
    end
  end
  if kind == "styles" or kind == "all" then
    for wi = ps, pe do
      state.word_styles[wi] = nil
    end
    persist_word_styles(n, item)
  end
  ml_sync_editor_text(words)
  refresh_preview(item)
  if auto_persist_layout then
    auto_persist_layout(item, words, ctx)
  end
end

local function ml_phrase_start_index(wi)
  local s = wi
  while s > 1 and not state.ml_phrase_after[s - 1] do
    s = s - 1
  end
  return s
end

--- Drop dragged word `src` onto previous word `src-1`: merge into same phrase/row (clear breaks between).
local function ml_drop_merge_into_prev_word(src, n)
  if src < 2 or src > n then
    return false
  end
  local dst = src - 1
  for j = dst, src - 1 do
    if j <= n - 1 then
      state.ml_phrase_after[j] = false
      state.ml_row_after[j] = false
    end
  end
  return true
end

--- Drop dragged word `src` onto next word `src+1`: move `src` into the next row/phrase.
local function ml_drop_merge_into_next_word(src, n)
  if src < 1 or src >= n then
    return false
  end
  if state.ml_phrase_after[src] then
    state.ml_phrase_after[src] = false
    state.ml_row_after[src] = false
    if src > 1 then
      state.ml_phrase_after[src - 1] = true
      state.ml_row_after[src - 1] = true
    end
    return true
  end
  if state.ml_row_after[src] then
    state.ml_row_after[src] = false
    if src > 1 then
      state.ml_row_after[src - 1] = true
    end
    return true
  end
  return false
end

--- Start a new phrase at word index `src` (phrase + row break before `src`).
local function ml_drop_new_phrase_at(src, n)
  if src < 1 or src > n or src <= 1 then
    return false
  end
  state.ml_phrase_after[src - 1] = true
  state.ml_row_after[src - 1] = true
  return true
end

local function ml_word_in_last_phrase(wi, n)
  local phrases = ml_phrase_ranges(n)
  if #phrases == 0 then
    return false
  end
  local last = phrases[#phrases]
  return wi >= last[1] and wi <= last[2]
end

--- Make `wi` the first word of its phrase (split before `wi`, merge prefix with previous phrase).
local function ml_make_word_phrase_start(wi, n)
  if wi < 1 or wi > n then
    return false
  end
  local s = ml_phrase_start_index(wi)
  if wi == s then
    return false
  end
  for j = s, wi - 2 do
    if j <= n - 1 then
      state.ml_phrase_after[j] = false
      state.ml_row_after[j] = false
    end
  end
  if wi > 1 then
    state.ml_phrase_after[wi - 1] = true
    state.ml_row_after[wi - 1] = true
  end
  return true
end

--- Scale embedded alpha channel (0xRRGGBBAA layout used throughout this script).
function wx_im_col_alpha_mul(c, mul)
  c = tonumber(c) or 0xFFFFFFFF
  mul = math.max(0, math.min(1, tonumber(mul) or 1))
  local a = math.floor((c & 0xFF) * mul + 0.5)
  if a > 255 then
    a = 255
  end
  return (c & ~0xFF) | a
end

function wx_im_col_alpha_set(c, a_byte)
  c = tonumber(c) or 0xFFFFFFFF
  local a = math.floor(math.max(0, math.min(255, tonumber(a_byte) or 255)))
  return (c & ~0xFF) | a
end

function word_grid_reset_drag_state()
  state.word_drag_lock = nil
  state.word_drag_acc_x = 0
  state.word_drag_acc_y = 0
end

--- Horizontal drag adjusts word scale (triple: horizontal only; other presets: dominant axis).
function word_grid_drag_on_word(ctx, item, words, n, wi, triple_preset)
  if not (ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging and ImGui.IsMouseDragging(ctx, 0, 0)) then
    return
  end
  local dx, dy = 0, 0
  if ImGui.GetMouseDelta then
    dx, dy = ImGui.GetMouseDelta(ctx)
  end
  if not state.word_drag_lock then
    state.word_drag_acc_x = state.word_drag_acc_x + math.abs(dx or 0)
    state.word_drag_acc_y = state.word_drag_acc_y + math.abs(dy or 0)
    if triple_preset then
      if state.word_drag_acc_x >= 4 then
        state.word_drag_lock = "scale"
      end
    else
      if state.word_drag_acc_x >= 4 and state.word_drag_acc_x > state.word_drag_acc_y then
        state.word_drag_lock = "scale"
      elseif state.word_drag_acc_y >= 4 and state.word_drag_acc_y >= state.word_drag_acc_x then
        state.word_drag_lock = "scale"
      end
    end
  end
  if state.word_drag_lock ~= "scale" then
    return
  end
  local d = dx or 0
  if not triple_preset then
    if math.abs(dy or 0) > math.abs(d) then
      d = -(dy or 0)
    end
  end
  if math.abs(d) > 0.15 then
    local adj = {}
    if state.word_sel[wi] then
      for j = 1, n do
        if state.word_sel[j] then
          adj[#adj + 1] = j
        end
      end
    else
      adj[1] = wi
    end
    for _, j in ipairs(adj) do
      local t = state.ml_word_scales[j] or 1
      t = math.max(0.15, math.min(4, t + d * 0.012))
      state.ml_word_scales[j] = t
    end
    state.word_scale_tip_active = true
    state.word_scale_tip_until = (r.time_precise and r.time_precise() or 0) + 0.35
    if ImGui.SetTooltip then
      local pct = math.floor((state.ml_word_scales[wi] or 1) * 100 + 0.5)
      ImGui.SetTooltip(ctx, "Font size: " .. tostring(pct) .. "%")
    end
    ml_sync_editor_text(words)
    refresh_preview(item)
    if auto_persist_layout then
      auto_persist_layout(item, words, ctx)
    end
  end
end

function word_grid_show_size_labels(ctx, n)
  local now = (r.time_precise and r.time_precise()) or 0
  if not state.word_scale_tip_active and now > (state.word_scale_tip_until or 0) then
    return
  end
  if now > (state.word_scale_tip_until or 0) then
    state.word_scale_tip_active = false
    return
  end
  if not (ImGui.GetWindowDrawList and ImGui.DrawList_AddText) then
    return
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  if not dl then
    return
  end
  for wi = 1, n do
    local show = state.word_sel and state.word_sel[wi]
    if not show and state.word_anchor == wi then
      show = true
    end
    local R = state._wig_rects and state._wig_rects[wi]
    if show and R then
      local pct = math.floor((state.ml_word_scales[wi] or 1) * 100 + 0.5)
      local lbl = wx_active_style_fill_rgba()
      ImGui.DrawList_AddText(dl, R[1], R[4] + 2, lbl, tostring(pct) .. "%")
    end
  end
end

local function word_grid_take_for_item(item)
  if not item then
    return nil
  end
  if r.GetActiveTake then
    local tk = r.GetActiveTake(item)
    if tk then
      return tk
    end
  end
  if r.CountTakes and r.GetMediaItemTake then
    local ntk = r.CountTakes(item)
    if type(ntk) == "number" and ntk >= 1 then
      return r.GetMediaItemTake(item, 0)
    end
  end
  return nil
end

--- Map absolute project timeline time to WhisperX word index (1-based).
--- Returns wi, src_t where src_t is source time seconds (or nil, nil).
local function word_grid_word_index_from_proj_time(item, words, proj_t)
  if not (item and words and #words > 0 and type(proj_t) == "number") then
    return nil, nil
  end
  local take = word_grid_take_for_item(item)
  if not take then
    return nil, nil
  end
  local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ilen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  if type(ipos) ~= "number" or type(ilen) ~= "number" then
    return nil, nil
  end
  if proj_t < ipos or proj_t > ipos + ilen then
    return nil, nil
  end
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
  if playrate == 0 then
    playrate = 1
  end
  local src_t = startoffs + (proj_t - ipos) * playrate
  for i = 1, #words do
    local t0 = tonumber(words[i].t) or 0
    local t1 = (i < #words) and (tonumber(words[i + 1].t) or (t0 + 0.05)) or (t0 + 2.0)
    if src_t >= t0 and src_t < t1 then
      return i, src_t
    end
  end
  return nil, src_t
end

function word_grid_word_at_edit_cursor(item, words)
  if not r.GetCursorPosition then
    return nil
  end
  local proj_t = r.GetCursorPosition()
  local wi = word_grid_word_index_from_proj_time(item, words, proj_t)
  return wi
end

function word_grid_current_play_word(item, words)
  state.current_play_word = nil
  state.current_play_src = nil
  if not item or not words or #words == 0 then
    state._last_follow_word = nil
    return nil
  end
  if not (r.GetPlayState and r.GetPlayPosition) then
    return nil
  end
  local ps = r.GetPlayState()
  -- Follow playback position only while transport is moving (play or record).
  if (ps & 5) == 0 then
    return nil
  end
  local proj_t = r.GetPlayPosition()
  if type(proj_t) ~= "number" then
    return nil
  end
  local wi, src_t = word_grid_word_index_from_proj_time(item, words, proj_t)
  if not wi then
    local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
    if type(ipos) == "number" and type(ilen) == "number" and (proj_t < ipos or proj_t > ipos + ilen) then
      state._last_follow_word = nil
    end
    return nil
  end
  state.current_play_src = src_t
  state.current_play_word = wi
  return wi
end

local function word_grid_seek_word(item, words, wi)
  if not (item and words and words[wi] and r.SetEditCurPos) then
    return false
  end
  local take = word_grid_take_for_item(item)
  if not take then
    return false
  end
  local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ilen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1
  local src_t = tonumber(words[wi].t)
  if type(ipos) ~= "number" or type(ilen) ~= "number" or not src_t then
    return false
  end
  if playrate == 0 then
    playrate = 1
  end
  local proj_t = ipos + (src_t - startoffs) / playrate
  proj_t = math.max(ipos, math.min(ipos + ilen, proj_t))
  r.SetEditCurPos(proj_t, true, false)
  return true
end

function word_grid_cut_zone(ctx, item, words, n, wi, bh)
  if wi < 1 or wi >= n then
    return
  end
  ImGui.SameLine(ctx, 0, 0)
  ImGui.PushID(ctx, wi + 930000)
  local zone_w = 10
  local zone_h = math.max(18, tonumber(bh) or 20)
  if ImGui.InvisibleButton(ctx, "##cut", zone_w, zone_h) then
    if overlay_mod_alt(ctx) then
      ml_alt_row(wi, n)
    else
      ml_ctrl_phrase(wi, n)
    end
    ml_sync_editor_text(words)
    refresh_preview(item)
    if auto_persist_layout then
      auto_persist_layout(item, words, ctx)
    end
  end
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  if hovered then
    if ImGui.SetMouseCursor and ImGui.MouseCursor_Hand then
      ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
    end
    if ImGui.SetTooltip then
      ImGui.SetTooltip(ctx, "Cut here: phrase break\nAlt+click: row break")
    end
    if ImGui.GetWindowDrawList and ImGui.DrawList_AddLine then
      local dl = ImGui.GetWindowDrawList(ctx)
      local x0, y0 = ImGui.GetItemRectMin(ctx)
      local x1, y1 = ImGui.GetItemRectMax(ctx)
      local x = (x0 + x1) * 0.5
      -- High-contrast separator: blend fill RGB toward white, full alpha, thicker stroke.
      local c = wx_active_style_fill_rgba()
      local t = 0.65
      local rr = (c >> 24) & 0xFF
      local gg = (c >> 16) & 0xFF
      local bb = (c >> 8) & 0xFF
      rr = math.min(255, math.floor(rr + (255 - rr) * t + 0.5))
      gg = math.min(255, math.floor(gg + (255 - gg) * t + 0.5))
      bb = math.min(255, math.floor(bb + (255 - bb) * t + 0.5))
      local sep = (rr << 24) | (gg << 16) | (bb << 8) | 0xFF
      ImGui.DrawList_AddLine(dl, x, y0, x, y1, sep, 3)
    end
  end
  ImGui.PopID(ctx)
  ImGui.SameLine(ctx, 0, 0)
end

--- True while phrase-row gutter seek/hover must stay inactive (widgets inside the phrase own the interaction).
local function word_grid_phrase_row_widgets_busy(ctx)
  if state.word_drag_lock then
    return true
  end
  if state._wx_ind_drag_w then
    return true
  end
  if state._wx_rowsp_drag_w then
    return true
  end
  if ImGui.IsAnyItemActive and ImGui.IsAnyItemActive(ctx) then
    return true
  end
  return false
end

--- Triple-stack: after `BeginGroup … EndGroup` for one phrase — extend hit/visual strip across the inner row width,
--- paint hover / gutter-press shading, pulse on gutter seek clicks.
function word_grid_phrase_row_interaction(ctx, item, words, pi, ps, mx, my, avail_inner_hint)
  if not (ctx and ImGui.GetItemRectMin and ImGui.GetItemRectMax) then
    return
  end
  local gx0, gy0 = ImGui.GetItemRectMin(ctx)
  local gx1, gy1 = ImGui.GetItemRectMax(ctx)
  if not gx0 or not gy0 or not gx1 or not gy1 then
    return
  end
  local pad_r = math.max(8, (gx1 - gx0) * 0.04 + 12)
  local hinted = tonumber(avail_inner_hint) or (gx1 - gx0 + pad_r)
  hinted = math.max(hinted, gx1 - gx0 + pad_r)
  local nx1 = gx0 + hinted

  local hovered = mx >= gx0 and mx <= nx1 and my >= gy0 and my <= gy1
  local any_item = ImGui.IsAnyItemHovered and ImGui.IsAnyItemHovered(ctx)
  local busy = word_grid_phrase_row_widgets_busy(ctx)
  --- “Gutter” = pointer in phrase band with no item hit and no active tweak/drag inside the phrase row.
  local gutter = hovered and not any_item and not busy and not state.marquee_active

  local now = (r.time_precise and r.time_precise()) or 0
  if state.wx_phrase_click_pulse_until and now >= state.wx_phrase_click_pulse_until then
    state.wx_phrase_click_pulse_until = nil
    state.wx_phrase_click_pulse_pi = nil
  end
  local pulsing = state.wx_phrase_click_pulse_pi == pi
    and state.wx_phrase_click_pulse_until
    and now < state.wx_phrase_click_pulse_until

  local dl = ImGui.GetWindowDrawList(ctx)
  --- Hover chrome + hand cursor only on true gutter — not over words, grips, cut zones, or while tweaking/dragging them.
  if dl and gutter and ImGui.DrawList_AddRectFilled then
    local fill_hi = wx_active_style_fill_rgba()
    local hcol = wx_im_col_alpha_mul(fill_hi, 0.088)
    if ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
      hcol = interp_color(hcol, fill_hi, 0.42)
      hcol = wx_im_col_alpha_mul(hcol, 1.08)
    end
    local rr = math.max(4, math.min(10, (gy1 - gy0) * 0.22))
    ImGui.DrawList_AddRectFilled(dl, gx0, gy0 - 2, nx1, gy1 + 2, hcol, rr)
    if ImGui.DrawList_AddRect then
      local ac = wx_active_style_accent_rgba()
      ImGui.DrawList_AddRect(
        dl,
        gx0 - 1,
        gy0 - 3,
        nx1 + 1,
        gy1 + 3,
        wx_im_col_alpha_mul(ac, 0.52),
        rr,
        0,
        ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) and 2 or 1
      )
    end
    if ImGui.SetMouseCursor and ImGui.MouseCursor_Hand then
      ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
    end
  end

  if pulsing and dl and ImGui.DrawList_AddRect then
    local pulse_t = math.max(0, (state.wx_phrase_click_pulse_until - now) / 0.18)
    local ac = wx_active_style_accent_rgba()
    local a = wx_im_col_alpha_mul(ac, math.min(0.95, 0.42 + pulse_t * 0.55))
    local rr = math.max(5, math.min(12, (gy1 - gy0) * 0.28))
    local thick = 2 + pulse_t * 2
    ImGui.DrawList_AddRect(dl, gx0 - 2, gy0 - 4, nx1 + 2, gy1 + 4, a, rr, 0, thick)
  end

  if gutter and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
    word_grid_seek_word(item, words, ps)
    state.wx_phrase_click_pulse_pi = pi
    state.wx_phrase_click_pulse_until = now + 0.18
  end
end

--- East–west grip: horizontal shaft with triangular chevrons (← and →), not four separate diags.
function wx_draw_ew_arrow_in_rect(dl, x0, y0, x1, y1, col, thick)
  if not (dl and ImGui.DrawList_AddLine and x0 and y0 and x1 and y1) then
    return
  end
  thick = thick or 1.5
  local cy = (y0 + y1) * 0.5
  local w = x1 - x0
  local h = y1 - y0
  local halfh = math.max(2, math.min(h * 0.34, w * 0.22))
  local pad = math.max(1, math.min(w, h) * 0.1)
  local xl = x0 + pad
  local xr = x1 - pad
  if xr - xl < halfh * 2.5 then
    return
  end
  local tip = math.max(2, math.min(halfh * 1.1, (xr - xl) * 0.26))
  local xl_back = xl + tip
  local xr_back = xr - tip
  if xl_back >= xr_back - 0.5 then
    local mid = (xl + xr) * 0.5
    xl_back = mid - 1
    xr_back = mid + 1
  end
  ImGui.DrawList_AddLine(dl, xl, cy, xl_back, cy - halfh, col, thick)
  ImGui.DrawList_AddLine(dl, xl, cy, xl_back, cy + halfh, col, thick)
  ImGui.DrawList_AddLine(dl, xr, cy, xr_back, cy - halfh, col, thick)
  ImGui.DrawList_AddLine(dl, xr, cy, xr_back, cy + halfh, col, thick)
  ImGui.DrawList_AddLine(dl, xl_back, cy, xr_back, cy, col, thick)
end

--- Small integer under a grip. `emphasize`: hover, drag, or ImGui active — uses a light readout (theme accent is often too dark).
local GRIP_LABEL_FS_FRAC = 0.62
local GRIP_LABEL_CLR_IDLE = 0x888888FF
local GRIP_LABEL_CLR_HOT = 0xEAEAEAFF

--- Optional `label_lift_px`: pull value text closer to the grip (indent uses a few px).
function wx_draw_grip_int_below(dl, ctx, x0, x1, y1, val, _, emphasize, label_lift_px)
  if not (dl and ImGui.DrawList_AddText) then
    return
  end
  label_lift_px = math.max(0, tonumber(label_lift_px) or 0)
  local txt = tostring(val)
  local fs_base = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local fs_small = math.max(8, math.floor(fs_base * GRIP_LABEL_FS_FRAC + 0.5))
  local tw, th = #txt * (fs_small * 0.48), fs_small
  if ImGui.CalcTextSize then
    local ok, tw2, th2 = pcall(ImGui.CalcTextSize, ctx, txt)
    if ok and tonumber(tw2) and fs_base > 0 then
      local sc = fs_small / fs_base
      tw = (tonumber(tw2) or tw) * sc
      th = (tonumber(th2) or fs_base) * sc
    end
  end
  local cx = (x0 + x1) * 0.5
  local tx = cx - tw * 0.5
  local ty = y1 + 1 - label_lift_px
  local c = emphasize and GRIP_LABEL_CLR_HOT or GRIP_LABEL_CLR_IDLE
  if ImGui.DrawList_AddTextEx and ImGui.GetFont then
    local ok = pcall(ImGui.DrawList_AddTextEx, dl, ImGui.GetFont(ctx), fs_small, tx, ty, c, txt)
    if not ok then
      ImGui.DrawList_AddText(dl, tx, ty, c, txt)
    end
  else
    ImGui.DrawList_AddText(dl, tx, ty, c, txt)
  end
end

function word_grid_row_indent_handle(ctx, item, words, row_start_w, bh, row_sc, row_any_selected)
  if row_start_w < 1 then
    return
  end
  ImGui.PushID(ctx, row_start_w + 940000)

  local bh_px = math.max(18, tonumber(bh) or 20)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local v = tonumber(state.ml_row_indents[row_start_w]) or 0
  local indent_i = math.floor(v * 100 + 0.5)
  indent_i = math.max(-50, math.min(50, indent_i))

  local rw = math.max(14, math.floor(fs * 0.82))
  local rh = math.max(16, math.min(24, math.floor(bh_px * 0.72 + 0.5)))
  local label_h = math.max(7, math.floor(fs * GRIP_LABEL_FS_FRAC + 2.5))
  local col_h = rh + label_h + 2
  local pad_top = math.max(0, (bh_px - col_h) * 0.5)

  if ImGui.BeginGroup and ImGui.EndGroup then
    ImGui.BeginGroup(ctx)
  end
  if pad_top > 0.5 and ImGui.Dummy then
    ImGui.Dummy(ctx, 1, pad_top)
  end

  ImGui.InvisibleButton(ctx, "##rowind", rw, rh)
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local x1, y1 = ImGui.GetItemRectMax(ctx)

  if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
    state._wx_ind_drag_w = row_start_w
    state._wx_ind_drag_acc = 0
    state._wx_rowsp_drag_w = nil
  end

  local dragging_here = state._wx_ind_drag_w == row_start_w
  local mouse_held = ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT)
  if dragging_here and not mouse_held then
    state._wx_ind_drag_w = nil
    state._wx_ind_drag_acc = nil
    dragging_here = false
  end

  local changed = false
  if dragging_here and ImGui.GetMouseDelta then
    local dx = select(1, ImGui.GetMouseDelta(ctx))
    state._wx_ind_drag_acc = (state._wx_ind_drag_acc or 0) + (dx or 0)
    local thr = 3.0
    while state._wx_ind_drag_acc >= thr do
      if indent_i < 50 then
        indent_i = indent_i + 1
        changed = true
      end
      state._wx_ind_drag_acc = state._wx_ind_drag_acc - thr
    end
    while state._wx_ind_drag_acc <= -thr do
      if indent_i > -50 then
        indent_i = indent_i - 1
        changed = true
      end
      state._wx_ind_drag_acc = state._wx_ind_drag_acc + thr
    end
  end

  if changed then
    state.ml_row_indents[row_start_w] = math.max(-0.5, math.min(0.5, indent_i / 100))
    ml_sync_editor_text(words)
    refresh_preview(item)
    if auto_persist_layout then
      auto_persist_layout(item, words, ctx)
    end
  end

  do
    local dl = ImGui.GetWindowDrawList and ImGui.GetWindowDrawList(ctx)
    if dl and x0 and y0 and x1 and y1 then
      local ac = wx_active_style_accent_rgba()
      wx_draw_ew_arrow_in_rect(dl, x0, y0, x1, y1, ac, 1.5)
      local di = math.floor(((state.ml_row_indents[row_start_w]) or 0) * 100 + 0.5)
      local item_active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)
      local hot = dragging_here or item_active or (ImGui.IsItemHovered and ImGui.IsItemHovered(ctx))
      wx_draw_grip_int_below(dl, ctx, x0, x1, y1, di, ac, hot, 5)
    end
  end

  if ImGui.EndGroup and ImGui.BeginGroup then
    ImGui.EndGroup(ctx)
  end

  local ghover = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  if (ghover or dragging_here) and ImGui.SetMouseCursor and ImGui.MouseCursor_ResizeEW then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW)
  end
  if dragging_here and ImGui.SetTooltip then
    local di = math.floor(((state.ml_row_indents[row_start_w]) or 0) * 100 + 0.5)
    ImGui.SetTooltip(ctx, ("Indent: %d\n(−50…50, hundredths of project width)"):format(di))
  elseif ghover and ImGui.SetTooltip then
    local di = math.floor(((state.ml_row_indents[row_start_w]) or 0) * 100 + 0.5)
    ImGui.SetTooltip(ctx, ("Row indent: %d\nDrag left/right; negative = further left."):format(di))
  end

  ImGui.PopID(ctx)
  ImGui.SameLine(ctx, 0, 4)
end

--- North–south grip: vertical shaft with narrow ∧ / ∨ chevrons (matches EW style).
function wx_draw_ns_arrow_in_rect(dl, x0, y0, x1, y1, col, thick)
  if not (dl and ImGui.DrawList_AddLine and x0 and y0 and x1 and y1) then
    return
  end
  thick = math.max(1, (thick or 1.35) * 0.92)
  local cx = (x0 + x1) * 0.5
  local w = x1 - x0
  local h = y1 - y0
  local halfw = math.max(1.6, math.min(w * 0.20, h * 0.10))
  local pad = math.max(0.8, math.min(w, h) * 0.07)
  local y_top = y0 + pad
  local y_bot = y1 - pad
  if y_bot - y_top < halfw * 2.6 then
    return
  end
  local tip = math.max(1.8, math.min(halfw * 1.0, (y_bot - y_top) * 0.26))
  local yt_back = y_top + tip
  local yb_back = y_bot - tip
  if yt_back >= yb_back - 0.5 then
    local mid = (y_top + y_bot) * 0.5
    yt_back = mid - 1
    yb_back = mid + 1
  end
  ImGui.DrawList_AddLine(dl, cx, y_top, cx - halfw, yt_back, col, thick)
  ImGui.DrawList_AddLine(dl, cx, y_top, cx + halfw, yt_back, col, thick)
  ImGui.DrawList_AddLine(dl, cx, y_bot, cx - halfw, yb_back, col, thick)
  ImGui.DrawList_AddLine(dl, cx, y_bot, cx + halfw, yb_back, col, thick)
  ImGui.DrawList_AddLine(dl, cx, yt_back, cx, yb_back, col, thick)
end

function word_grid_row_spacing_handle(ctx, item, words, lower_row_start_w, base_gap, slot_h)
  if lower_row_start_w < 1 then
    return
  end
  ImGui.PushID(ctx, lower_row_start_w + 960000)

  local v0 = state.ml_row_spacings[lower_row_start_w]
  if v0 == nil then
    v0 = tonumber(base_gap) or tonumber(state.ml_line_gap) or 0.1
  end
  v0 = math.max(-0.95, math.min(1.5, tonumber(v0) or 0.1))
  local gap_i = math.floor(v0 * 100 + 0.5)
  gap_i = math.max(-95, math.min(150, gap_i))

  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local row_h = tonumber(slot_h) or (fs + 8)
  local rw = math.max(14, math.floor(fs * 0.82))
  local rh = math.max(16, math.min(24, math.floor(row_h * 0.72 + 0.5)))
  local label_h = math.max(8, math.floor(fs * GRIP_LABEL_FS_FRAC + 4.5))
  local col_h = rh + label_h + 3
  local pad_top = math.max(0, (row_h - col_h) * 0.5)

  if ImGui.BeginGroup and ImGui.EndGroup then
    ImGui.BeginGroup(ctx)
  end
  if pad_top > 0.5 and ImGui.Dummy then
    ImGui.Dummy(ctx, 1, pad_top)
  end

  ImGui.InvisibleButton(ctx, "##rowsp", rw, rh)
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local x1, y1 = ImGui.GetItemRectMax(ctx)

  if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
    state._wx_rowsp_drag_w = lower_row_start_w
    state._wx_rs_drag_acc = 0
    state._wx_ind_drag_w = nil
  end

  local dragging_here = state._wx_rowsp_drag_w == lower_row_start_w
  local mouse_held = ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT)

  if dragging_here and not mouse_held then
    state._wx_rowsp_drag_w = nil
    state._wx_rs_drag_acc = nil
    dragging_here = false
  end

  local changed = false
  if dragging_here and ImGui.GetMouseDelta then
    local _, dy = ImGui.GetMouseDelta(ctx)
    state._wx_rs_drag_acc = (state._wx_rs_drag_acc or 0) + (dy or 0)
    local thr = 3.0
    while state._wx_rs_drag_acc >= thr do
      if gap_i < 150 then
        gap_i = gap_i + 1
        changed = true
      end
      state._wx_rs_drag_acc = state._wx_rs_drag_acc - thr
    end
    while state._wx_rs_drag_acc <= -thr do
      if gap_i > -95 then
        gap_i = gap_i - 1
        changed = true
      end
      state._wx_rs_drag_acc = state._wx_rs_drag_acc + thr
    end
  end

  if changed then
    state.ml_row_spacings[lower_row_start_w] = math.max(-0.95, math.min(1.5, gap_i / 100))
    ml_sync_editor_text(words)
    refresh_preview(item)
    if auto_persist_layout then
      auto_persist_layout(item, words, ctx)
    end
  end

  if ImGui.EndGroup and ImGui.BeginGroup then
    ImGui.EndGroup(ctx)
  end

  local ghover = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)

  do
    local dl = ImGui.GetWindowDrawList and ImGui.GetWindowDrawList(ctx)
    if dl and x0 and y0 and x1 and y1 then
      local ac = wx_active_style_accent_rgba()
      wx_draw_ns_arrow_in_rect(dl, x0, y0, x1, y1, ac, 1.5)
      local gv = math.floor(((state.ml_row_spacings[lower_row_start_w]) or v0) * 100 + 0.5)
      gv = math.max(-95, math.min(150, gv))
      local item_active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)
      wx_draw_grip_int_below(dl, ctx, x0, x1, y1, gv, ac, dragging_here or ghover or item_active)
    end
  end

  if ghover and ImGui.SetMouseCursor and ImGui.MouseCursor_ResizeNS then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS)
  end
  if dragging_here and ImGui.SetMouseCursor and ImGui.MouseCursor_ResizeNS then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS)
  end
  if dragging_here and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx, ("Row spacing: %d/100 × font height"):format(gap_i))
  elseif ghover and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx, ("Row spacing before next row: −95…150 (hundredths × font height)\nDrag up/down on the grip."))
  end

  ImGui.PopID(ctx)
end

function separator_text(ctx, label)
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, label)
  else
    ImGui.Spacing(ctx)
    ImGui.Text(ctx, label)
    ImGui.Separator(ctx)
  end
end

function word_style_menu_item(ctx, label, selected)
  if ImGui.Checkbox then
    local rv = ImGui.Checkbox(ctx, label, selected and true or false)
    if type(rv) == "boolean" then
      return rv
    end
  end
  local flags = ImGui.SelectableFlags_DontClosePopups or 0
  local ok, rv = pcall(ImGui.Selectable, ctx, (selected and "✓ " or "  ") .. label, false, flags)
  if ok then
    return rv
  end
  return ImGui.Selectable(ctx, (selected and "✓ " or "  ") .. label, false)
end

function word_style_apply_change(item, words, ctx)
  local n = (words and #words) or state.ml_word_n or 0
  persist_word_styles(n, item)
  refresh_preview(item)
  if auto_persist_layout then
    auto_persist_layout(item, words, ctx)
  end
end

function word_color_edit(ctx, label, color, default_rgb)
  color = tonumber(color) or default_rgb or 0xFFFFFF
  local rv, out = false, color
  if ImGui.ColorEdit3 then
    local flags = 0
    if ImGui.ColorEditFlags_NoAlpha then
      flags = flags | ImGui.ColorEditFlags_NoAlpha
    end
    rv, out = ImGui.ColorEdit3(ctx, label, (color & 0xFFFFFF) | 0xFF000000, flags)
    if rv then
      out = out & 0xFFFFFF
    end
  else
    rv, out = ImGui.InputInt(ctx, label .. " RGB", color)
    if rv then
      out = math.max(0, math.min(0xFFFFFF, math.floor(tonumber(out) or color)))
    end
  end
  return rv, out
end

function word_color_button(ctx, label, rgb)
  if not ImGui.ColorButton then
    return wx_custom_small_button and wx_custom_small_button(ctx, label, state.wx_slider_style)
  end
  local flags = 0
  if ImGui.ColorEditFlags_NoAlpha then
    flags = flags | ImGui.ColorEditFlags_NoAlpha
  end
  if ImGui.ColorEditFlags_NoTooltip then
    flags = flags | ImGui.ColorEditFlags_NoTooltip
  end
  return ImGui.ColorButton(ctx, label, rgb & 0xFFFFFF, flags, 18, 18)
end

function word_color_drop_target(ctx)
  if not (ImGui.BeginDragDropTarget and ImGui.BeginDragDropTarget(ctx)) then
    return nil
  end
  local dropped, col
  if ImGui.AcceptDragDropPayloadRGB then
    dropped, col = ImGui.AcceptDragDropPayloadRGB(ctx)
    if dropped and col then
      ImGui.EndDragDropTarget(ctx)
      return col & 0xFFFFFF
    end
  end
  if ImGui.AcceptDragDropPayloadRGBA then
    dropped, col = ImGui.AcceptDragDropPayloadRGBA(ctx)
    if dropped and col then
      ImGui.EndDragDropTarget(ctx)
      return (col >> 8) & 0xFFFFFF
    end
  end
  ImGui.EndDragDropTarget(ctx)
  return nil
end

function word_color_palette_ui(ctx, prefix, apply_fn, palette_item)
  local palette = state.word_color_palette or {}
  local per_row = 8
  for i = 1, #palette do
    if i > 1 and ((i - 1) % per_row) ~= 0 then
      ImGui.SameLine(ctx, 0, 4)
    end
    ImGui.PushID(ctx, prefix .. tostring(i))
    if word_color_button(ctx, "##pal", palette[i]) then
      apply_fn(palette[i])
    end
    local dropped = word_color_drop_target(ctx)
    if dropped then
      palette[i] = dropped
      word_palette_persist(palette_item)
    end
    ImGui.PopID(ctx)
  end
  if #palette > 0 and (#palette % per_row) ~= 0 then
    ImGui.SameLine(ctx, 0, 4)
  end
  ImGui.PushID(ctx, prefix .. "_new")
  word_color_button(ctx, "##pal_new", 0x202020)
  local dropped = word_color_drop_target(ctx)
  if dropped then
    word_palette_add(dropped, palette_item)
  end
  ImGui.PopID(ctx)
end

function word_style_popup_ui(ctx, item, words, wi)
  if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) and overlay_mod_ctrl(ctx) and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_RIGHT) then
    local sel = state.word_sel or {}
    local sel_count = 0
    for _ in pairs(sel) do
      sel_count = sel_count + 1
    end
    if sel_count <= 1 or not sel[wi] then
      state.word_sel = { [wi] = true }
    end
    state.word_anchor = wi
    if ImGui.OpenPopup then
      ImGui.OpenPopup(ctx, "##word_style_popup")
    end
  end
  if not (ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##word_style_popup")) then
    return
  end
  local nwords = #(words or {})
  local function word_style_popup_targets()
    local sel = state.word_sel or {}
    local list = {}
    for j = 1, nwords do
      if sel[j] then
        list[#list + 1] = j
      end
    end
    table.sort(list)
    if #list <= 1 then
      return { wi }
    end
    return list
  end
  local targets = word_style_popup_targets()
  local function word_style_propagate_primary_to_others()
    if #targets <= 1 then
      return
    end
    local raw = state.word_styles and state.word_styles[wi]
    local cp = raw and word_style_copy(raw) or nil
    for ti = 1, #targets do
      local t = targets[ti]
      if t ~= wi then
        state.word_styles[t] = cp and word_style_copy(cp) or nil
      end
    end
  end
  local function word_style_set_flag_on_targets(flag, on)
    for ti = 1, #targets do
      local t = targets[ti]
      local s = word_style_get(t)
      if on then
        s.flags = s.flags | flag
      else
        s.flags = s.flags & (~flag)
      end
      if word_style_is_empty(s) then
        state.word_styles[t] = nil
      end
    end
  end
  local st = word_style_get(wi)
  if #targets > 1 then
    ImGui.Text(ctx, string.format("Word style (%d words)", #targets))
  else
    ImGui.Text(ctx, "Word style: " .. tostring(words[wi] and words[wi].w or wi))
  end
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end
  local changed = false

  local preset_preview = trim(state.word_style_preset_name or "")
  if preset_preview == "" then
    preset_preview = "<style preset>"
  end
  if #state.word_style_preset_names == 0 then
    ImGui.TextColored(ctx, 0x888888FF, "No style presets yet.")
  else
    local preset_idx = 0
    for i = 1, #state.word_style_preset_names do
      if state.word_style_preset_name == state.word_style_preset_names[i] then
        preset_idx = i - 1
        break
      end
    end
    local rv_wp, wp_idx = wx_custom_combo(ctx, "##word_style_preset_wx", "Preset", preset_idx, table.concat(state.word_style_preset_names, "\0") .. "\0", 240, state.wx_slider_style)
    if rv_wp then
      local nm = state.word_style_preset_names[(wp_idx or 0) + 1]
      if nm then
        local blob = es_get(word_style_preset_key(nm), "")
        local okp, perr = word_style_preset_apply_blob(targets[1], blob)
        if okp then
          for ti = 2, #targets do
            word_style_preset_apply_blob(targets[ti], blob)
          end
          state.word_style_preset_name = nm
          state.word_style_preset_save_name = nm
          r.SetExtState(SECTION, "WORD_STYLE_PRESET_LAST", nm, true)
          st = word_style_get(wi)
          changed = true
        else
          state.status = perr or "Could not load style preset."
          state.status_err = true
        end
      end
    end
  end
  local rv_spn, spn = ImGui.InputText(ctx, "Save as##word_style_preset_name", state.word_style_preset_save_name or "")
  if rv_spn then
    state.word_style_preset_save_name = spn or ""
  end
  if wx_custom_small_button(ctx, "Save style preset", state.wx_slider_style) then
    local okp, perr = word_style_preset_save_named(state.word_style_preset_save_name or "", st)
    if okp then
      state.status = "Saved word style preset: " .. trim(state.word_style_preset_save_name or "")
      state.status_err = false
    else
      state.status = perr or "Could not save style preset."
      state.status_err = true
    end
  end
  if #state.word_style_preset_names > 0 and trim(state.word_style_preset_name or "") ~= "" then
    ImGui.SameLine(ctx)
    if wx_custom_small_button(ctx, "Delete style preset", state.wx_slider_style) then
      word_style_preset_delete_named(state.word_style_preset_name)
    end
  end
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end
  ImGui.Text(ctx, "Animation preset override")
  if #state.anim_preset_names == 0 then
    ImGui.TextColored(ctx, 0x888888FF, "No animation presets yet.")
  else
    local ap_idx = 0
    local current_ap = trim(st.anim_preset_name or "")
    for i = 1, #state.anim_preset_names do
      if current_ap == state.anim_preset_names[i] then
        ap_idx = i - 1
        break
      end
    end
    local rv_ap, ap_new_idx = wx_custom_combo(
      ctx,
      "##word_anim_preset_override",
      "Anim preset",
      ap_idx,
      table.concat(state.anim_preset_names, "\0") .. "\0",
      240,
      state.wx_slider_style
    )
    if rv_ap then
      local nm = state.anim_preset_names[(ap_new_idx or 0) + 1]
      if nm then
        st.anim_preset_name = nm
        changed = true
      end
    end
  end
  if wx_custom_small_button(ctx, "Clear animation override", state.wx_slider_style) then
    if trim(st.anim_preset_name or "") ~= "" then
      st.anim_preset_name = ""
      changed = true
    end
  end
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end

  local function toggle_line(lbl, flag)
    if word_style_menu_item(ctx, lbl, (st.flags & flag) ~= 0) then
      local on = ((st.flags & flag) == 0)
      word_style_set_flag_on_targets(flag, on)
      st = word_style_get(wi)
      changed = true
    end
  end

  toggle_line("Bold face (font)", WSTYLE_BOLD)
  toggle_line("Italic face (font)", WSTYLE_ITALIC)

  toggle_line("Pseudo bold (duplicate draws)", WSTYLE_PSEUDO_BOLD)
  if (st.flags & WSTYLE_PSEUDO_BOLD) ~= 0 then
    local rvpb, pb = wx_custom_slider_int(ctx, "##word_pseudo_bold_copies", "Pseudo bold copies", st.pseudo_bold_copies or 2, 1, 8, "%d", 260, state.wx_slider_style, nil, nil, nil, true)
    if rvpb then
      st.pseudo_bold_copies = math.max(1, math.min(8, pb or 2))
      changed = true
    end
    local rvpo, po = ImGui.DragDouble(ctx, "Pseudo bold offset px", st.pseudo_bold_offset or 1, 0.05, 0.25, 6, "%.2f")
    if rvpo then
      st.pseudo_bold_offset = math.max(0.25, math.min(6, tonumber(po) or 1))
      changed = true
    end
  end

  toggle_line("Pseudo slant (offset draw)", WSTYLE_PSEUDO_SLANT)
  if (st.flags & WSTYLE_PSEUDO_SLANT) ~= 0 then
    local rvs, sl = ImGui.DragDouble(ctx, "Pseudo slant angle", st.pseudo_slant or 2, 0.1, -12, 12, "%.1f")
    if rvs then
      st.pseudo_slant = math.max(-12, math.min(12, tonumber(sl) or 2))
      changed = true
    end
  end

  toggle_line("Drop shadow", WSTYLE_SHADOW)
  if (st.flags & WSTYLE_SHADOW) ~= 0 then
    local rvdx, dx = ImGui.DragDouble(ctx, "Shadow X px", st.shadow_dx or 2, 0.1, -20, 20, "%.1f")
    if rvdx then
      st.shadow_dx = math.max(-20, math.min(20, tonumber(dx) or 2))
      changed = true
    end
    local rvdy, dy = ImGui.DragDouble(ctx, "Shadow Y px", st.shadow_dy or 2, 0.1, -20, 20, "%.1f")
    if rvdy then
      st.shadow_dy = math.max(-20, math.min(20, tonumber(dy) or 2))
      changed = true
    end
    local sha = math.floor((tonumber(st.shadow_alpha) or 0.55) * 100 + 0.5)
    local rvsa, sha2 = wx_custom_slider_int(ctx, "##word_shadow_alpha", "Shadow alpha", sha, 0, 100, "%d%%", 260, state.wx_slider_style)
    if rvsa then
      st.shadow_alpha = math.max(0, math.min(1, (sha2 or sha) / 100))
      changed = true
    end
  end

  toggle_line("Outline", WSTYLE_OUTLINE)
  if (st.flags & WSTYLE_OUTLINE) ~= 0 then
    local rvot, ot = wx_custom_slider_int(ctx, "##word_outline_thick", "Outline thickness px", math.floor(tonumber(st.outline_thickness) or 2), 1, 12, "%d", 260, state.wx_slider_style, nil, nil, nil, true)
    if rvot then
      st.outline_thickness = math.max(1, math.min(12, tonumber(ot) or 2))
      changed = true
    end
    local rvog, ogp = wx_custom_slider_int(ctx, "##word_outline_gap", "Outline gap from text px", math.floor(tonumber(st.outline_gap) or 0), 0, 24, "%d", 260, state.wx_slider_style, nil, nil, nil, true)
    if rvog then
      st.outline_gap = math.max(0, math.min(24, tonumber(ogp) or 0))
      changed = true
    end
    if ImGui.Separator then
      ImGui.Separator(ctx)
    end
    ImGui.Text(ctx, "Outline color")
    local rv_oc, oc = word_color_edit(ctx, "Outline##word_outline_color", st.outline_color or 0, 0)
    if rv_oc then
      st = word_style_get(wi)
      st.outline_color = oc
      st.flags = st.flags | WSTYLE_OUTLINE
      changed = true
    end
    word_color_palette_ui(ctx, "outline", function(c)
      local s = word_style_get(wi)
      s.outline_color = c
      s.flags = s.flags | WSTYLE_OUTLINE
      changed = true
    end, item)
  end

  toggle_line("Underline", WSTYLE_UNDERLINE)
  if (st.flags & WSTYLE_UNDERLINE) ~= 0 then
    local rvut, ut = wx_custom_slider_int(ctx, "##word_underline_thick", "Underline thickness px", math.floor(tonumber(st.underline_thick) or 1), 1, 12, "%d", 260, state.wx_slider_style, nil, nil, nil, true)
    if rvut then
      st.underline_thick = math.max(1, math.min(12, tonumber(ut) or 1))
      changed = true
    end
    local rvuo, uo = ImGui.DragDouble(ctx, "Underline offset px", st.underline_offset or 1, 0.1, -8, 16, "%.1f")
    if rvuo then
      st.underline_offset = math.max(-8, math.min(16, tonumber(uo) or 1))
      changed = true
    end
  end

  toggle_line("Highlight", WSTYLE_HIGHLIGHT)
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end
  ImGui.Text(ctx, "Text color")
  local rv_tc, tc = word_color_edit(ctx, "Text##word_text_color", st.text_color or 0xFFFFFF, 0xFFFFFF)
  if rv_tc then
    st = word_style_get(wi)
    st.text_color = tc
    changed = true
  end
  word_color_palette_ui(ctx, "txt", function(c)
    word_style_get(wi).text_color = c
    changed = true
  end, item)
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end
  ImGui.Text(ctx, "Highlight color")
  local rv_hc, hc = word_color_edit(ctx, "Highlight##word_highlight_color", st.highlight_color or 0xFFD34D, 0xFFD34D)
  if rv_hc then
    st = word_style_get(wi)
    st.highlight_color = hc
    st.flags = st.flags | WSTYLE_HIGHLIGHT
    changed = true
  end
  word_color_palette_ui(ctx, "hilite", function(c)
    local s = word_style_get(wi)
    s.highlight_color = c
    s.flags = s.flags | WSTYLE_HIGHLIGHT
    changed = true
  end, item)
  if ImGui.Separator then
    ImGui.Separator(ctx)
  end
  if wx_custom_button(ctx, "Clear word style", 130, 0, state.wx_slider_style) then
    for ti = 1, #targets do
      state.word_styles[targets[ti]] = nil
    end
    changed = true
  end
  if changed then
    word_style_propagate_primary_to_others()
    word_style_apply_change(item, words, ctx)
  end
  ImGui.EndPopup(ctx)
end

function auto_phrase_from_lyrics(item, words, lyrics_text, char_split, ctx)
  local n = #words
  if n == 0 then return end
  
  lyrics_text = lyrics_text or ""
  local lyric_tokens = {}
  local is_end_of_line = {}
  
  for line in lyrics_text:gmatch("([^\r\n]+)") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      local line_toks = {}
      if char_split and utf8 and utf8.codes then
        local ok_utf = pcall(function()
          for _, cp in utf8.codes(line) do
            if not (cp == 9 or cp == 10 or cp == 13 or cp == 32) then
              table.insert(line_toks, utf8.char(cp))
            end
          end
        end)
        if not ok_utf then
          line_toks = {}
          for w in line:gmatch("%S+") do
            table.insert(line_toks, w)
          end
        end
      else
        for w in line:gmatch("%S+") do
          table.insert(line_toks, w)
        end
      end
      
      for i, tok in ipairs(line_toks) do
        table.insert(lyric_tokens, tok)
        is_end_of_line[#lyric_tokens] = (i == #line_toks)
      end
    end
  end
  
  local m = #lyric_tokens
  if m == 0 then return end
  
  local asr = {}
  for i = 1, n do
    asr[i] = words[i].w
  end
  
  local dp = {}
  local pr = {}
  for i = 0, n do
    dp[i] = {}
    pr[i] = {}
    for j = 0, m do
      dp[i][j] = 1e15
    end
  end
  dp[0][0] = 0
  for i = 1, n do
    dp[i][0] = dp[i - 1][0] + 1
    pr[i][0] = 2
  end
  for j = 1, m do
    dp[0][j] = dp[0][j - 1] + 1
    pr[0][j] = 3
  end
  
  local function norm_key(s)
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s:find("[\128-\255]") then return s end
    return s:lower()
  end
  local function sub_cost(a, b)
    if a == b then return 0 end
    if norm_key(a) == norm_key(b) then return 0 end
    return 2
  end

  for i = 1, n do
    for j = 1, m do
      local c_diag = dp[i - 1][j - 1] + sub_cost(asr[i], lyric_tokens[j])
      local c_up = dp[i - 1][j] + 1
      local c_left = dp[i][j - 1] + 1
      local c, p = c_diag, 1
      if c_up < c then c, p = c_up, 2 end
      if c_left < c then c, p = c_left, 3 end
      dp[i][j] = c
      pr[i][j] = p
    end
  end
  
  local match_asr_to_lyric = {}
  local i, j = n, m
  while i > 0 or j > 0 do
    local p = pr[i] and pr[i][j] or 0
    if i > 0 and j > 0 and p == 1 then
      match_asr_to_lyric[i] = j
      i, j = i - 1, j - 1
    elseif i > 0 and p == 2 then
      i = i - 1
    elseif j > 0 and p == 3 then
      j = j - 1
    elseif i > 0 then
      i = i - 1
    elseif j > 0 then
      j = j - 1
    else
      break
    end
  end
  
  state.ml_phrase_after = {}
  state.ml_row_after = {}
  
  for i = 1, n - 1 do
    local lj = match_asr_to_lyric[i]
    if lj and is_end_of_line[lj] then
      state.ml_phrase_after[i] = true
    end
  end
  
  if auto_persist_layout then
    auto_persist_layout(item, words, ctx)
  end
end

function word_grid_ui(ctx, item, words)
  if not words or #words == 0 then
    return
  end
  local n = #words
  state._wig_rects = {}
  wx_bridge_icons_try_load(ctx)
  local fs_row = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local expand_ic_sz = math.max(22, math.floor(fs_row * 1.65 + 0.5))
  if ImGui.AlignTextToFramePadding then
    ImGui.AlignTextToFramePadding(ctx)
  end
  if ImGui.BeginGroup then
    ImGui.BeginGroup(ctx)
  end
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, "Words (take markers)")
  else
    ImGui.Text(ctx, "Words (take markers)")
  end
  ImGui.SameLine(ctx, 0, 8)
  local float_hit = false
  if wx_bridge_icon_images.expand then
    local etint = state.word_grid_floating and 0xFFFFFFFF or 0x55FFFFFF
    float_hit = wx_bridge_image_button(ctx, "##wx_float_words", wx_bridge_icon_images.expand, expand_ic_sz, etint)
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, "Float words panel — words in a separate window.")
    elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Float words panel — words in a separate window.")
    end
  else
    local rv_f, v_f = ImGui.Checkbox(ctx, "Float##wx_float_words_fallback", state.word_grid_floating)
    if rv_f then
      state.word_grid_floating = v_f and true or false
      r.SetExtState(SECTION, "WORD_GRID_FLOAT", state.word_grid_floating and "1" or "0", true)
    end
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, "Float words panel")
    elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Float words panel")
    end
  end
  if float_hit then
    state.word_grid_floating = not state.word_grid_floating
    r.SetExtState(SECTION, "WORD_GRID_FLOAT", state.word_grid_floating and "1" or "0", true)
  end
  if ImGui.EndGroup then
    ImGui.EndGroup(ctx)
  end
  if not ImGui.SeparatorText then
    ImGui.Separator(ctx)
  end

  if ImGui.AlignTextToFramePadding then
    ImGui.AlignTextToFramePadding(ctx)
  end
  if ImGui.BeginGroup then
    ImGui.BeginGroup(ctx)
  end
  wx_bridge_transport_strip(ctx, state.wx_slider_style)
  ImGui.SameLine(ctx, 0, 14)
  local cursor_word = word_grid_word_at_edit_cursor(item, words)
  local active_play_word = word_grid_current_play_word(item, words)
  local transport_moving = false
  if r.GetPlayState then
    transport_moving = ((r.GetPlayState() & 5) ~= 0)
  end
  local follow_scroll_wi = (transport_moving and active_play_word) or cursor_word
  if cursor_word then
    ImGui.TextColored(ctx, 0xFF9933FF, "Edit: " .. tostring(words[cursor_word].w or cursor_word))
  else
    ImGui.TextColored(ctx, 0x888888FF, "Edit: -")
  end
  if active_play_word then
    ImGui.SameLine(ctx, 0, 12)
    ImGui.TextColored(ctx, 0x66DDFFFF, "Play: " .. tostring(words[active_play_word].w or active_play_word))
  end
  ImGui.SameLine(ctx)
  if wx_custom_button(ctx, "Auto-phrase from lyrics...", 180, 0, state.wx_slider_style) then
    state.show_auto_phrase_popup = true
    state.auto_phrase_text = ""
    state.auto_phrase_char_split = false
    if ImGui.OpenPopup then
      ImGui.OpenPopup(ctx, "Auto-phrase from lyrics")
    end
  end

  if ImGui.EndGroup then
    ImGui.EndGroup(ctx)
  end
  
  if ImGui.BeginPopupModal and ImGui.BeginPopupModal(ctx, "Auto-phrase from lyrics", nil, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.TextWrapped(ctx, "Paste lyrics with line breaks. The script will match words and add phrase breaks at the end of each line.")
    local line_h = 18
    if ImGui.GetTextLineHeight then line_h = ImGui.GetTextLineHeight(ctx) end
    local rv
    rv, state.auto_phrase_text = ImGui.InputTextMultiline(ctx, "##ap_lyrics", state.auto_phrase_text or "", 400, line_h * 10)
    rv, state.auto_phrase_char_split = ImGui.Checkbox(ctx, "Split lyric into UTF-8 characters (unspaced CJK)", state.auto_phrase_char_split)
    
    if wx_custom_button(ctx, "Send (Apply)", 120, 0, state.wx_slider_style) then
      auto_phrase_from_lyrics(item, words, state.auto_phrase_text, state.auto_phrase_char_split, ctx)
      ImGui.CloseCurrentPopup(ctx)
      state.show_auto_phrase_popup = false
    end
    ImGui.SameLine(ctx)
    if wx_custom_button(ctx, "Cancel", 80, 0, state.wx_slider_style) then
      ImGui.CloseCurrentPopup(ctx)
      state.show_auto_phrase_popup = false
    end
    ImGui.EndPopup(ctx)
  end

  local child_h = 240
  child_h = math.max(120, math.min(700, tonumber(state.word_grid_h) or child_h))
  local hscroll = 0
  if ImGui.WindowFlags_HorizontalScrollbar then
    hscroll = ImGui.WindowFlags_HorizontalScrollbar
  end
  local child_flags = 0
  if ImGui.ChildFlags_Border then
    child_flags = ImGui.ChildFlags_Border
  end
  if ImGui.ChildFlags_ResizeY then
    child_flags = child_flags | ImGui.ChildFlags_ResizeY
  end
  local wordgrid_visible = ImGui.BeginChild(ctx, "##wordgrid", 0, child_h, child_flags, hscroll)
  if wordgrid_visible == nil then
    wordgrid_visible = true
  end
  if wordgrid_visible then
  local sel_fill = wx_active_style_fill_rgba()
  local accent_abgr = wx_active_style_accent_rgba()
  local function word_grid_word_btn_fill_and_outline(wi)
    local fill_mark = nil
    local outline
    if state.word_sel[wi] then
      fill_mark = sel_fill
      outline = wx_im_col_alpha_mul(accent_abgr, 0.95)
    elseif transport_moving and active_play_word == wi then
      outline = 0x22AAFFFF
    elseif cursor_word == wi then
      outline = 0xFF9933FF
    elseif not word_style_is_empty(state.word_styles and state.word_styles[wi]) then
      outline = 0x665522FF
    else
      outline = wx_im_col_alpha_mul(accent_abgr, 0.78)
    end
    return fill_mark, outline
  end
  --- Native ImGui.Button path: faint fill unless selected; Col_Border outlines the frame.
  local function word_grid_push_native_word_btn_styles(wi)
    local fill_mark, outline = word_grid_word_btn_fill_and_outline(wi)
    local pc, pv = 0, 0
    if ImGui.PushStyleVar and ImGui.StyleVar_FrameBorderSize then
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
      pv = pv + 1
    end
    if ImGui.PushStyleColor and ImGui.Col_Border then
      ImGui.PushStyleColor(ctx, ImGui.Col_Border, outline)
      pc = pc + 1
    end
    if state.word_sel[wi] and ImGui.Col_Button then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, sel_fill)
      pc = pc + 1
      if ImGui.Col_ButtonHovered then
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, wx_im_col_alpha_mul(sel_fill, 0.92))
        pc = pc + 1
      end
      if ImGui.Col_ButtonActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, wx_im_col_alpha_mul(sel_fill, 0.84))
        pc = pc + 1
      end
    elseif ImGui.Col_Button then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, wx_im_col_alpha_mul(0xFFFFFFFF, 0.05))
      pc = pc + 1
      if ImGui.Col_ButtonHovered then
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, wx_im_col_alpha_mul(accent_abgr, 0.14))
        pc = pc + 1
      end
      if ImGui.Col_ButtonActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, wx_im_col_alpha_mul(accent_abgr, 0.26))
        pc = pc + 1
      end
    end
    return fill_mark, outline, pc, pv
  end
  local mx, my = ImGui.GetMousePos(ctx)
  local function word_sel_pair_count()
    if not state.word_sel then
      return 0
    end
    local c = 0
    for _ in pairs(state.word_sel) do
      c = c + 1
    end
    return c
  end
  if ImGui.IsMouseReleased and ImGui.IsMouseReleased(ctx, MOUSE_LEFT) then
    word_grid_reset_drag_state()
  end
  local function apply_marquee_selection(finish_drag)
    if finish_drag then
      state.marquee_active = false
    end
    local x0 = math.min(state.marquee_x0, state.marquee_x1)
    local x1 = math.max(state.marquee_x0, state.marquee_x1)
    local y0 = math.min(state.marquee_y0, state.marquee_y1)
    local y1 = math.max(state.marquee_y0, state.marquee_y1)
    if x1 - x0 > 3 or y1 - y0 > 3 then
      state.word_sel = state.word_sel or {}
      for i = 1, n do
        local R = state._wig_rects[i]
        if R and not (R[3] < x0 or R[1] > x1 or R[4] < y0 or R[2] > y1) then
          state.word_sel[i] = true
        end
      end
    end
  end
  if not state.marquee_active and (not overlay_mod_ctrl(ctx)) and ImGui.IsWindowHovered and ImGui.IsWindowHovered(ctx) and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_RIGHT) then
    local dx0, dy0 = 0, 0
    if ImGui.GetMouseDragDelta then
      dx0, dy0 = ImGui.GetMouseDragDelta(ctx, MOUSE_RIGHT)
    end
    state.marquee_active = true
    state.marquee_btn = MOUSE_RIGHT
    state.marquee_additive = overlay_mod_shift(ctx) and true or false
    if not state.marquee_additive then
      state.word_sel = {}
    end
    state.marquee_x0, state.marquee_y0 = (mx - (dx0 or 0)), (my - (dy0 or 0))
    state.marquee_x1, state.marquee_y1 = mx, my
  end
  local mbtn = tonumber(state.marquee_btn) or 0
  if state.marquee_active and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, mbtn) then
    state.marquee_x1, state.marquee_y1 = mx, my
  end
  if ImGui.IsMouseReleased and ImGui.IsMouseReleased(ctx, mbtn) and state.marquee_active then
    state.marquee_finish_after_draw = true
  end
  if state.marquee_active and state.marquee_btn == MOUSE_RIGHT and ImGui.IsMouseDown and not ImGui.IsMouseDown(ctx, MOUSE_RIGHT) then
    state.marquee_finish_after_draw = true
  end
  local phrases = ml_phrase_ranges(n)
    for pi = 1, #phrases do
      local ps, pe = phrases[pi][1], phrases[pi][2]
      ImGui.BeginGroup(ctx)
      local phrase_strip_avail_x = 0
      do
        if ImGui.GetContentRegionAvail then
          local aa, bb = ImGui.GetContentRegionAvail(ctx)
          phrase_strip_avail_x = tonumber(aa) or 0
          if phrase_strip_avail_x <= 1 and type(aa) == "table" then
            phrase_strip_avail_x = tonumber(aa[1]) or 0
          end
        end
      end
      local rows = ml_row_ranges_in(ps, pe)
      for ri = 1, #rows do
        local ra, rb = rows[ri][1], rows[ri][2]
        ImGui.BeginGroup(ctx)
        if ImGui.Dummy then
          ImGui.Dummy(ctx, 0, 0)
        end
        local row_line_h = 20
        local row_sc = state.ml_word_scales[ra] or 1
        for wi = ra, rb do
          local sc = state.ml_word_scales[wi] or 1
          local bh_w = math.max(20, math.floor(18 * sc + 6))
          if bh_w > row_line_h then
            row_line_h = bh_w
            row_sc = sc
          end
        end
        local row_has_sel = false
        for ww = ra, rb do
          if state.word_sel[ww] then
            row_has_sel = true
            break
          end
        end
        word_grid_row_indent_handle(ctx, item, words, ra, row_line_h, row_sc, row_has_sel)
        for wi = ra, rb do
            if wi > ra then
              ImGui.SameLine(ctx, 0, 4)
            end
            ImGui.PushID(ctx, wi + 910000)
            local sc = state.ml_word_scales[wi] or 1
            local wtxt, bw = wx_word_grid_button_label_and_width(ctx, words[wi].w, sc, 24, 7)
            local bh = math.max(20, math.floor(18 * sc + 6))
            local pushed_var = false
            local wv_word_border = 0
            if ImGui.PushStyleVar and ImGui.StyleVar_FramePadding then
              ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4 * sc, 3 * sc)
              pushed_var = true
            end
            local wb_fill, wb_outline, wc_extra, wv_b = word_grid_push_native_word_btn_styles(wi)
            local pushed_color = wc_extra
            wv_word_border = wv_b
            local word_clicked = false
            if ImGui.Button then
              word_clicked = ImGui.Button(ctx, wtxt .. "##w", bw, bh) and true or false
            else
              word_clicked = wx_custom_button(ctx, wtxt .. "##w", bw, bh, state.wx_slider_style, false, wb_fill, wb_outline)
            end
            if word_clicked then
              word_grid_seek_word(item, words, wi)
              if overlay_mod_ctrl_shift(ctx) then
                if ml_make_word_phrase_start(wi, n) then
                  ml_sync_editor_text(words)
                  refresh_preview(item)
                  if auto_persist_layout then
                    auto_persist_layout(item, words, ctx)
                  end
                end
              elseif overlay_mod_ctrl(ctx) then
                ml_ctrl_phrase(wi, n)
                ml_sync_editor_text(words)
                refresh_preview(item)
                if auto_persist_layout then
                  auto_persist_layout(item, words, ctx)
                end
              elseif overlay_mod_alt(ctx) then
                ml_alt_row(wi, n)
                ml_sync_editor_text(words)
                refresh_preview(item)
                if auto_persist_layout then
                  auto_persist_layout(item, words, ctx)
                end
              elseif overlay_mod_shift(ctx) and state.word_anchor then
                local a, b = state.word_anchor, wi
                if a > b then
                  a, b = b, a
                end
                state.word_sel = {}
                for j = a, b do
                  state.word_sel[j] = true
                end
              elseif state.word_sel and state.word_sel[wi] and word_sel_pair_count() > 1 then
                state.word_anchor = wi
              else
                state.word_sel = { [wi] = true }
                state.word_anchor = wi
              end
            end
            do
              local rmin_a, rmin_b = ImGui.GetItemRectMin(ctx)
              local rmax_a, rmax_b = ImGui.GetItemRectMax(ctx)
              if rmin_a and rmin_b and rmax_a and rmax_b then
                state._wig_rects[wi] = { rmin_a, rmin_b, rmax_a, rmax_b }
              end
            end
            if follow_scroll_wi == wi and state._last_follow_word ~= wi then
              if ImGui.SetScrollHereY then
                ImGui.SetScrollHereY(ctx, 0.5)
              end
              if ImGui.SetScrollHereX then
                ImGui.SetScrollHereX(ctx, 0.5)
              end
              state._last_follow_word = wi
            end
            word_style_popup_ui(ctx, item, words, wi)
            word_grid_drag_on_word(ctx, item, words, n, wi, true)
            local can_drag_drop = true
            if ImGui.IsMouseDown then
              can_drag_drop = ImGui.IsMouseDown(ctx, MOUSE_LEFT)
            end
            if can_drag_drop and ImGui.BeginDragDropSource and ImGui.BeginDragDropSource(ctx) then
              ImGui.SetDragDropPayload(ctx, WX_WORD, tostring(wi))
              ImGui.Text(ctx, "→ previous/next word or new phrase")
              ImGui.EndDragDropSource(ctx)
            end
            if ImGui.BeginDragDropTarget and ImGui.BeginDragDropTarget(ctx) then
              local dropped, payload = ImGui.AcceptDragDropPayload(ctx, WX_WORD)
              if dropped and payload then
                local src = tonumber(payload)
                local changed = false
                if src and src == wi + 1 then
                  changed = ml_drop_merge_into_prev_word(src, n)
                elseif src and src == wi - 1 then
                  changed = ml_drop_merge_into_next_word(src, n)
                end
                if changed then
                  ml_sync_editor_text(words)
                  refresh_preview(item)
                  if auto_persist_layout then
                    auto_persist_layout(item, words, ctx)
                  end
                end
              end
              ImGui.EndDragDropTarget(ctx)
            end
            if pushed_color > 0 and ImGui.PopStyleColor then
              ImGui.PopStyleColor(ctx, pushed_color)
            end
            if wv_word_border > 0 and ImGui.PopStyleVar then
              for _ = 1, wv_word_border do
                ImGui.PopStyleVar(ctx)
              end
            end
            if pushed_var and ImGui.PopStyleVar and ImGui.StyleVar_FramePadding then
              ImGui.PopStyleVar(ctx)
            end
            if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
              if ImGui.SetTooltip then
                ImGui.SetTooltip(ctx, (words[wi].w or "") .. "\nCtrl/Cmd+right-click: word style · Drag: reposition · H-drag: size · Ctrl/Cmd+Shift: phrase start")
              end
            end
            if wi < rb then
              word_grid_cut_zone(ctx, item, words, n, wi, bh)
            end
            if wi == pe then
              ImGui.SameLine(ctx, 0, 4)
              local popup_id = "##wx_phrase_rst_" .. tostring(pi)
              if wx_custom_button(ctx, "↻##wx_pr" .. tostring(pi), bh, bh, state.wx_slider_style) then
                if ImGui.OpenPopup then
                  ImGui.OpenPopup(ctx, popup_id)
                end
              end
              if ImGui.SetItemTooltip then
                ImGui.SetItemTooltip(ctx, "This phrase: reset indents, row gaps, and/or word styles")
              elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
                ImGui.SetTooltip(ctx, "This phrase: reset indents, row gaps, and/or word styles")
              end
              if ImGui.BeginPopup and ImGui.BeginPopup(ctx, popup_id) then
                if wx_custom_button(ctx, "Reset row indents", 280, 0, state.wx_slider_style) then
                  ml_phrase_reset_layout("indent", ps, pe, n, item, words, ctx)
                  if ImGui.CloseCurrentPopup then
                    ImGui.CloseCurrentPopup(ctx)
                  end
                end
                if wx_custom_button(ctx, "Reset row spacing", 280, 0, state.wx_slider_style) then
                  ml_phrase_reset_layout("rowsp", ps, pe, n, item, words, ctx)
                  if ImGui.CloseCurrentPopup then
                    ImGui.CloseCurrentPopup(ctx)
                  end
                end
                if wx_custom_button(ctx, "Clear word styles", 280, 0, state.wx_slider_style) then
                  ml_phrase_reset_layout("styles", ps, pe, n, item, words, ctx)
                  if ImGui.CloseCurrentPopup then
                    ImGui.CloseCurrentPopup(ctx)
                  end
                end
                if wx_custom_button(ctx, "Reset all (indents + gaps + styles)", 280, 0, state.wx_slider_style) then
                  ml_phrase_reset_layout("all", ps, pe, n, item, words, ctx)
                  if ImGui.CloseCurrentPopup then
                    ImGui.CloseCurrentPopup(ctx)
                  end
                end
                ImGui.EndPopup(ctx)
              end
            end
            ImGui.PopID(ctx)
          end
        if ri < #rows then
          ImGui.SameLine(ctx, 0, 4)
          local next_row_start = rows[ri + 1] and rows[ri + 1][1]
          word_grid_row_spacing_handle(ctx, item, words, next_row_start or rb + 1, state.ml_line_gap, row_line_h)
        end
        ImGui.EndGroup(ctx)
      end
      ImGui.EndGroup(ctx)
      word_grid_phrase_row_interaction(ctx, item, words, pi, ps, mx, my, phrase_strip_avail_x)
      if pi < #phrases then
        ImGui.Separator(ctx)
      end
    end
    ImGui.Spacing(ctx)
    ImGui.TextColored(ctx, 0x666666FF, "+ New phrase — drop a word from the last phrase here")
    ImGui.InvisibleButton(ctx, "##wxnewphrase_drop", -1, 26)
    if ImGui.BeginDragDropTarget and ImGui.BeginDragDropTarget(ctx) then
      local dropped, payload = ImGui.AcceptDragDropPayload(ctx, WX_WORD)
      if dropped and payload then
        local src = tonumber(payload)
        if src and ml_word_in_last_phrase(src, n) and ml_drop_new_phrase_at(src, n) then
          ml_sync_editor_text(words)
          refresh_preview(item)
          if auto_persist_layout then
            auto_persist_layout(item, words, ctx)
          end
        end
      end
      ImGui.EndDragDropTarget(ctx)
    end
  if ImGui.IsWindowHovered and ImGui.IsWindowHovered(ctx) and ImGui.IsMouseClicked then
    if ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
      if not (ImGui.IsAnyItemHovered and ImGui.IsAnyItemHovered(ctx)) then
        state.marquee_active = true
        state.marquee_btn = MOUSE_LEFT
        state.marquee_additive = overlay_mod_shift(ctx) and true or false
        if not state.marquee_additive then
          state.word_sel = {}
        end
        state.marquee_x0, state.marquee_y0 = mx, my
        state.marquee_x1, state.marquee_y1 = mx, my
      end
    end
  end
  if state.marquee_active then
    apply_marquee_selection(state.marquee_finish_after_draw == true)
    state.marquee_finish_after_draw = false
  end
  word_grid_show_size_labels(ctx, n)
  if state.marquee_active and ImGui.GetWindowDrawList and ImGui.DrawList_AddRectFilled then
    local dl = ImGui.GetWindowDrawList(ctx)
    if dl then
      local x0 = math.min(state.marquee_x0, state.marquee_x1)
      local y0 = math.min(state.marquee_y0, state.marquee_y1)
      local x1 = math.max(state.marquee_x0, state.marquee_x1)
      local y1 = math.max(state.marquee_y0, state.marquee_y1)
      ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, wx_im_col_alpha_mul(sel_fill, 0.34))
      if ImGui.DrawList_AddRect then
        ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, wx_im_col_alpha_mul(sel_fill, 0.92))
      end
    end
  end
  ImGui.EndChild(ctx)
  local split_w = 240
  if ImGui.GetContentRegionAvail then
    local a = ImGui.GetContentRegionAvail(ctx)
    if type(a) == "number" then
      split_w = math.max(80, a)
    elseif type(a) == "table" then
      split_w = math.max(80, tonumber(a[1]) or split_w)
    end
  end
  ImGui.InvisibleButton(ctx, "##word_grid_split", split_w, 8)
  if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) and ImGui.SetMouseCursor and ImGui.MouseCursor_ResizeNS then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeNS)
  end
  if ImGui.IsItemActive and ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging and ImGui.IsMouseDragging(ctx, 0, 0) then
    local dy = 0
    if ImGui.GetMouseDelta then
      _, dy = ImGui.GetMouseDelta(ctx)
    end
    state.word_grid_h = math.max(120, math.min(700, (state.word_grid_h or child_h) + dy))
  end
  if ImGui.IsMouseReleased and ImGui.IsMouseReleased(ctx, 0) then
    r.SetExtState(SECTION, "WORD_GRID_H", tostring(math.floor((state.word_grid_h or child_h) + 0.5)), true)
  end
  end
end

--- Color ABGR for ImGui.TextColored (green / magenta / gray).
function draw_parse_hint(ctx, hint)
  if type(hint) ~= "table" then
    return
  end
  local lab = ""
  if type(hint.mode) == "string" and hint.mode:sub(1, 4) == "ml_" and hint.line_num then
    lab = "Phrase " .. tostring(hint.line_num) .. ": "
  elseif hint.line_num then
    lab = "Editor line " .. tostring(hint.line_num) .. ": "
  end
  local has_good = type(hint.good_prefix) == "string" and hint.good_prefix ~= ""
  local has_bad = type(hint.bad_suffix) == "string" and hint.bad_suffix ~= ""
  if not has_good and not has_bad and (not hint.marker_concat or hint.marker_concat == "") then
    if type(hint.note) == "string" and hint.note ~= "" then
      ImGui.TextColored(ctx, 0xAAAAAAFF, hint.note)
    end
    return
  end
  if lab ~= "" then
    ImGui.Text(ctx, lab)
    ImGui.SameLine(ctx)
  end
  if has_good then
    ImGui.TextColored(ctx, 0x8FD18CFF, hint.good_prefix)
    ImGui.SameLine(ctx)
  end
  if has_bad then
    if not has_good then
      ImGui.Text(ctx, "Mismatch: ")
      ImGui.SameLine(ctx)
    end
    ImGui.TextColored(ctx, 0x6666FFFF, hint.bad_suffix)
  end
  if type(hint.marker_concat) == "string" and hint.marker_concat ~= "" then
    ImGui.TextWrapped(ctx, "Marker concat at mismatch: " .. hint.marker_concat)
  end
  if type(hint.note) == "string" and hint.note ~= "" then
    ImGui.TextColored(ctx, 0xAAAAAAFF, hint.note)
  end
end

function save_settings()
  wx_sync_karaoke_derived()
  r.SetExtState(SECTION, "PRESET_IDX", "3", true)
  r.SetExtState(SECTION, "SHOW_WORDS_MODE", tostring(math.max(0, math.min(2, math.floor(state.ml_timing_mode or 1)))), true)
  r.SetExtState(SECTION, "KARAOKE", state.karaoke and "1" or "0", true)
  r.SetExtState(SECTION, "WORDS_PER_LINE", tostring(state.words_per_line), true)
  r.SetExtState(SECTION, "MAX_CHARS", tostring(state.max_chars), true)
  r.SetExtState(SECTION, "BREAK_SENTENCE", state.break_sentence and "1" or "0", true)
  r.SetExtState(SECTION, "FONT_NAME", trim(state.font_name or ""), true)
  persist_anim_settings_extstate()
  r.SetExtState(SECTION, "ML_MAX_ROWS", tostring(state.ml_max_rows), true)
  for i = 1, 6 do
    r.SetExtState(SECTION, "ML_S" .. tostring(i), tostring(state.ml_s[i]), true)
    r.SetExtState(SECTION, "ML_R" .. tostring(i), tostring(state.ml_r[i]), true)
  end
  r.SetExtState(SECTION, "ML_LINE_GAP", string.format("%.17g", state.ml_line_gap), true)
  r.SetExtState(SECTION, "ML_ROW_CHARS", tostring(state.ml_row_chars), true)
  r.SetExtState(SECTION, "ML_ROW_CHARS_RAND", tostring(state.ml_row_chars_rand), true)
  r.SetExtState(SECTION, "ML_ROW_VALIGN", tostring(math.floor(state.ml_row_v_align or 0)), true)
  r.SetExtState(SECTION, "ML_CHARS_SEED", string.format("%.17g", state.ml_chars_seed), true)
  r.SetExtState(SECTION, "ML_INDENT_STEP", string.format("%.17g", state.ml_indent_step), true)
  r.SetExtState(SECTION, "ML_INDENT_RAND", string.format("%.17g", state.ml_indent_rand), true)
  r.SetExtState(SECTION, "ML_INDENT_SEED", string.format("%.17g", state.ml_indent_seed), true)
  persist_ml_jitter()
  r.SetExtState(SECTION, "LIVE_GUI_VP", state.live_gui_vp and "1" or "0", true)
  r.SetExtState(SECTION, "WORD_GRID_H", tostring(math.floor((state.word_grid_h or 240) + 0.5)), true)
  r.SetExtState(SECTION, "WORD_GRID_FLOAT", state.word_grid_floating and "1" or "0", true)
  r.SetExtState(SECTION, "ANIM_WIPE_MASK_OFFSET", string.format("%.17g", state.anim_wipe_mask_offset or 0), true)
  r.SetExtState(SECTION, "IMG_POST_WAVE", state.img_post_wave and "1" or "0", true)
  r.SetExtState(SECTION, "IMG_POST_WAVE_AMP", string.format("%.17g", state.img_post_wave_amp or 24), true)
  r.SetExtState(SECTION, "IMG_POST_WAVE_LEN", string.format("%.17g", state.img_post_wave_len or 90), true)
  r.SetExtState(SECTION, "IMG_POST_WAVE_SPEED", string.format("%.17g", state.img_post_wave_speed or 6), true)
  for _, guide in ipairs(VIDEO_RATIO_GUIDES) do
    r.SetExtState(SECTION, guide.key, (state.video_guides and state.video_guides[guide.id]) and "1" or "0", true)
  end
  local sel_save_item = (r.CountSelectedMediaItems(0) == 1) and r.GetSelectedMediaItem(0, 0) or nil
  word_palette_persist(sel_save_item)
  r.SetExtState(SECTION, "EDITOR_BODY_H", tostring(math.floor((state.editor_body_h or 140) + 0.5)), true)
  r.SetExtState(SECTION, "WX_SLIDER_STYLE", tostring(math.floor(tonumber(state.wx_slider_style) or 1)), true)
  r.SetExtState(SECTION, "EDITOR_TEXT", state.editor_text or "", true)
  r.SetExtState(SECTION, "ML_PRESET_LAST", state.ml_preset_name or "", true)
  r.SetExtState(SECTION, "ANIM_PRESET_LAST", state.anim_preset_name or "", true)
  local n = math.max(0, math.floor(state.ml_word_n or 0))
  if n > 1 then
    r.SetExtState(SECTION, "ML_PHRASE_AFTER", ml_bits_pack(state.ml_phrase_after, n), true)
    r.SetExtState(SECTION, "ML_ROW_AFTER", ml_bits_pack(state.ml_row_after, n), true)
  else
    r.SetExtState(SECTION, "ML_PHRASE_AFTER", "", true)
    r.SetExtState(SECTION, "ML_ROW_AFTER", "", true)
  end
  if n > 0 then
    r.SetExtState(SECTION, "ML_WORDSCALE", ml_scales_pack(state.ml_word_scales, n), true)
    r.SetExtState(SECTION, "ML_ROW_INDENT", ml_indents_pack(state.ml_row_indents, n), true)
  end
  persist_word_styles(n, sel_save_item)
  state.status = "Settings saved to extstate " .. SECTION .. "."
  state.status_err = false
end

function write_vp_for_item(item, live_opts)
  live_opts = live_opts or {}
  local no_undo = live_opts.no_undo == true
  local skip_refresh = live_opts.skip_refresh == true
  local skip_if_same = live_opts.skip_if_same == true

  if r.ValidatePtr and not r.ValidatePtr(item, "MediaItem*") then
    return false, "Invalid media item."
  end

  local take, words, take_was_switched = W.find_take_and_wx_words(item)
  if not take then
    return false, "No take on the selected item."
  end
  if r.ValidatePtr and not r.ValidatePtr(take, "MediaTake*") then
    return false, "Invalid take."
  end
  if #words == 0 then
    return false, "No take markers with valid times on this item."
  end

  if not no_undo then
    r.Undo_BeginBlock()
  end
  if take_was_switched and r.SetActiveTake then
    r.SetActiveTake(take)
  end

  local src_end = W.source_length_for_take(take)
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not startoffs or not playrate or playrate == 0 then
    if not no_undo then
      r.Undo_EndBlock(WINDOW_TITLE, -1)
    end
    return false, "Could not read take start offset / playrate."
  end

  local opts = display_opts_from_state(words)
  local body, err = W.build_eel_body(words, src_end, startoffs, playrate, opts)
  if not body then
    if not no_undo then
      r.Undo_EndBlock(WINDOW_TITLE, -1)
    end
    return false, err or "Build failed."
  end

  if skip_if_same and state._last_vp_body == body then
    return true, nil
  end

  local chunk_ok, ichunk = r.GetItemStateChunk(item, "", false)
  if not chunk_ok or type(ichunk) ~= "string" then
    if not no_undo then
      r.Undo_EndBlock(WINDOW_TITLE, -1)
    end
    return false, "GetItemStateChunk failed."
  end

  local need_new_vp = not ichunk:find(W.SENTINEL, 1, true)
  local new_vp_fx_guid = nil
  if need_new_vp then
    if not r.TakeFX_AddByName then
      if not no_undo then
        r.Undo_EndBlock(WINDOW_TITLE, -1)
      end
      return false, "TakeFX_AddByName not available."
    end
    local idx = r.TakeFX_AddByName(take, "Video processor", -1)
    if not idx or idx < 0 then
      if not no_undo then
        r.Undo_EndBlock(WINDOW_TITLE, -1)
      end
      return false, "Could not add Video processor to the take."
    end
    if r.TakeFX_GetFXGUID then
      new_vp_fx_guid = r.TakeFX_GetFXGUID(take, idx)
    end
  end

  local ok, uerr = W.upsert_video_processor_code(
    item,
    take,
    W.eel_plain_to_reaper_vp_chunk(body),
    new_vp_fx_guid,
    not no_undo
  )
  if not ok then
    if not no_undo then
      r.Undo_EndBlock(WINDOW_TITLE, -1)
    end
    return false, tostring(uerr or "SetItemStateChunk failed.")
  end

  state._last_vp_body = body
  if no_undo and r.time_precise then
    state._live_vp_last_chunk_write_t = r.time_precise()
  end
  r.SetExtState(SECTION, "EDITOR_TEXT", state.editor_text or "", true)
  persist_ml_jitter()
  r.SetExtState(SECTION, "ML_INDENT_STEP", string.format("%.17g", state.ml_indent_step), true)
  r.SetExtState(SECTION, "ML_INDENT_RAND", string.format("%.17g", state.ml_indent_rand), true)
  r.SetExtState(SECTION, "ML_INDENT_SEED", string.format("%.17g", state.ml_indent_seed), true)

  r.UpdateArrange()
  if not no_undo then
    r.Undo_EndBlock("WhisperX word overlay (bridge)", -1)
  end
  if not skip_refresh then
    refresh_preview(item)
  end
  return true, nil
end

--- Queue a subtitle + item/extstate autosave flush on the next end-of-frame pass (handles font, guides, global sliders, …).
local function overlay_request_autosave()
  state.overlay_autosave_force = true
end

--- Fingerprint written to disk by `auto_persist_layout`; used to coalesce autosaves (word grid + globals + VP settings).
local function overlay_autosave_state_sig(words)
  words = words or {}
  local n = #words
  local z = "\255"
  local p = {}

  local function ap(s)
    p[#p + 1] = s or ""
  end

  local function fq(x)
    return string.format("%.17g", tonumber(x) or 0)
  end

  ap(z .. "TW")
  ap(z .. tostring(math.max(0, math.min(2, math.floor(state.ml_timing_mode or 1)))))
  ap(z .. "FONT")
  ap(z)
  ap(state.font_name or "")
  ap(z .. "KAR")
  ap(z)
  ap(tostring(math.max(0, math.min(2, math.floor(state.ml_timing_mode or 1)))))
  ap(z .. "VG")
  for _, guide in ipairs(VIDEO_RATIO_GUIDES) do
    ap(z)
    ap(state.video_guides[guide.id] and "1" or "0")
  end
  ap(z .. "IMGW")
  ap(z)
  ap(state.img_post_wave and "1" or "0")
  ap(z .. fq(state.img_post_wave_amp or 24))
  ap(z .. fq(state.img_post_wave_len or 90))
  ap(z .. fq(state.img_post_wave_speed or 6))

  ap(z .. "LM")
  ap(z .. tostring(math.floor(state.ml_max_rows or 0)))
  ap(z .. fq(state.ml_line_gap or 0))
  ap(z .. tostring(math.floor(state.ml_row_chars or 0)))
  ap(z .. tostring(math.floor(state.ml_row_chars_rand or 0)))
  ap(z .. tostring(math.floor(state.ml_row_v_align or 0)))
  ap(z .. fq(state.ml_chars_seed or 0))
  ap(z .. fq(state.ml_indent_step or 0))
  ap(z .. fq(state.ml_indent_rand or 0))
  ap(z .. fq(state.ml_indent_seed or 0))
  for li = 1, 6 do
    ap(z .. fq(state.ml_s[li] or 1))
    ap(z .. fq(state.ml_r[li] or 0))
    ap(z .. fq(state.ml_jitter[li] or 0))
  end

  ap(z .. "AW")
  ap(z .. fq(state.anim_wipe_mask_offset or 0))

  local function blob_len_field(key, blob)
    blob = blob or ""
    ap(z .. key)
    ap(z .. tostring(#blob))
    ap(z)
    ap(blob)
  end

  ap(z .. "LGV")
  ap(z .. (state.live_gui_vp and "1" or "0"))

  local function scalar_anim_blob()
    ap(z .. "ANIM")
    ap(z .. tostring(math.floor(state.anim_scope or 0)))
    ap(z .. (state.anim_in_on and "1" or "0"))
    ap(z .. tostring(math.floor(state.anim_in_type or 0)))
    ap(z .. tostring(math.floor(state.anim_in_curve or 0)))
    ap(z .. fq(state.anim_in_dur or 0.12))
    ap(z .. fq(state.anim_in_amp or 1))
    ap(z .. fq(state.anim_in_bounce or 0.7))
    ap(z .. fq(state.anim_in_motion or 1))
    ap(z .. fq(state.anim_in_wiggle or 1))
    ap(z .. fq(state.anim_in_scale or 0))
    ap(z .. fq(state.anim_in_fade or 0))
    ap(z .. fq(state.anim_in_blur or 0))
    ap(z .. fq(state.anim_in_ghost or 1))
    ap(z .. tostring(math.floor(state.anim_in_dupes or 3)))
    ap(z .. fq(state.anim_in_dir or 90))
    ap(z .. fq(state.anim_in_twist or 0))
    ap(z .. (state.anim_in_use_graph and "1" or "0"))

    ap(z .. (state.anim_out_on and "1" or "0"))
    ap(z .. tostring(math.floor(state.anim_out_type or 0)))
    ap(z .. tostring(math.floor(state.anim_out_curve or 0)))
    ap(z .. fq(state.anim_out_dur or 0.12))
    ap(z .. fq(state.anim_out_amp or 1))
    ap(z .. fq(state.anim_out_bounce or 0.7))
    ap(z .. fq(state.anim_out_motion or 1))
    ap(z .. fq(state.anim_out_wiggle or 1))
    ap(z .. fq(state.anim_out_scale or 0))
    ap(z .. fq(state.anim_out_fade or 0))
    ap(z .. fq(state.anim_out_blur or 0))
    ap(z .. fq(state.anim_out_ghost or 1))
    ap(z .. tostring(math.floor(state.anim_out_dupes or 3)))
    ap(z .. fq(state.anim_out_dir or 90))
    ap(z .. fq(state.anim_out_twist or 0))
    ap(z .. (state.anim_out_use_graph and "1" or "0"))

    ap(z .. (state.anim_phrase_out_on and "1" or "0"))
    ap(z .. tostring(math.floor(state.anim_phrase_out_type or state.anim_out_type or 0)))
    ap(z .. tostring(math.floor(state.anim_phrase_out_curve or state.anim_out_curve or 0)))
    ap(z .. fq(state.anim_phrase_out_dur or state.anim_out_dur or 0.12))
    ap(z .. fq(state.anim_phrase_out_amp or state.anim_out_amp or 1))
    ap(z .. fq(state.anim_phrase_out_bounce or state.anim_out_bounce or 0.7))
    ap(z .. fq(state.anim_phrase_out_motion or state.anim_out_motion or 1))
    ap(z .. fq(state.anim_phrase_out_wiggle or state.anim_out_wiggle or 1))
    ap(z .. fq(state.anim_phrase_out_scale or state.anim_out_scale or 0))
    ap(z .. fq(state.anim_phrase_out_fade or state.anim_out_fade or 0))
    ap(z .. fq(state.anim_phrase_out_blur or state.anim_out_blur or 0))
    ap(z .. fq(state.anim_phrase_out_ghost or state.anim_out_ghost or 1))
    ap(z .. tostring(math.floor(state.anim_phrase_out_dupes or state.anim_out_dupes or 3)))
    ap(z .. fq(state.anim_phrase_out_dir or state.anim_out_dir or 90))
    ap(z .. fq(state.anim_phrase_out_twist or state.anim_out_twist or 0))
    ap(z .. (state.anim_phrase_out_use_graph and "1" or "0"))
    ap(z .. (state.anim_in_graph_word_span and "1" or "0"))
    ap(z .. (state.anim_out_graph_word_span and "1" or "0"))
    ap(z .. (state.anim_phrase_out_graph_word_span and "1" or "0"))

    blob_len_field("AIG", state.anim_in_graph_blob)
    blob_len_field("AOG", state.anim_out_graph_blob)
    blob_len_field("APG", state.anim_phrase_out_graph_blob)
    blob_len_field("AIGA", state.anim_in_graph_auto_blob or "")
    blob_len_field("AOGA", state.anim_out_graph_auto_blob or "")
    blob_len_field("APGA", state.anim_phrase_out_graph_auto_blob or "")
  end

  scalar_anim_blob()

  ap(z .. "WN")
  ap(z .. tostring(n))
  ap(z .. "ET")
  ap(z .. tostring(#(state.editor_text or "")))
  ap(z .. (state.editor_text or ""))

  ap(z .. "MLB")
  for i = 1, math.max(0, n - 1) do
    local pa = state.ml_phrase_after[i] and "1" or "0"
    local ra = state.ml_row_after[i] and "1" or "0"
    ap(z .. pa .. ra)
  end

  ap(z .. "MLS")
  for i = 1, n do
    ap(z .. fq(state.ml_word_scales[i] or 1))
  end
  ap(z .. "IND")
  for i = 1, n do
    ap(z .. fq(state.ml_row_indents[i] or 0))
  end
  ap(z .. "RNG")
  for i = 1, n do
    local sp = state.ml_row_spacings[i]
    if sp == nil then
      ap(z .. "x")
    else
      ap(z .. fq(sp))
    end
  end
  ap(z .. "WS")
  for i = 1, n do
    local st = state.word_styles and state.word_styles[i]
    ap(z)
    if word_style_is_empty(st) then
      ap("-")
    else
      word_style_defaults(st)
      ap(
        tostring(math.floor(st.flags or 0))
          .. "^"
          .. tostring(math.floor(st.text_color or -1))
          .. "^"
          .. tostring(math.floor(st.highlight_color or -1))
          .. "^"
          .. fq(st.shadow_dx or 0)
          .. "^"
          .. fq(st.shadow_dy or 0)
          .. "^"
          .. fq(st.shadow_alpha or 0)
          .. "^"
          .. tostring(math.floor(st.pseudo_bold_copies or 2))
          .. "^"
          .. fq(st.pseudo_bold_offset or 1)
          .. "^"
          .. fq(st.pseudo_slant or 2)
          .. "^"
          .. tostring(math.floor(st.underline_thick or 1))
          .. "^"
          .. fq(st.underline_offset or 1)
          .. "^"
          .. tostring(math.floor(st.outline_thickness or 2))
          .. "^"
          .. tostring(math.floor(st.outline_gap or 0))
          .. "^"
          .. tostring(math.floor(st.outline_color or 0))
          .. "^"
          .. trim(st.anim_preset_name or "")
      )
    end
  end

  return table.concat(p)
end

--- Live VP: avoid SetItemStateChunk races with native take-marker / item UI (can hard-crash REAPER).
--- Skip while an ImGui control is active, while keyboard focus is outside this ReaImGui context (user in the arrange),
--- and briefly after each successful live chunk write (coalesce frames).
local LIVE_VP_MIN_WRITE_INTERVAL = 0.09

function anim_graph_live_vp_interacting()
  if state.anim_graph_editor_drag_point then
    return true
  end
  if state.anim_graph_editor_drag_t then
    return true
  end
  if state.anim_graph_editor_seg_drag_seg then
    return true
  end
  if (state.anim_graph_editor_lane_seg_lane or "") ~= "" then
    return true
  end
  if (state.anim_graph_editor_auto_drag_lane or "") ~= "" then
    return true
  end
  return false
end

function anim_graph_update_live_vp_coalesce()
  if anim_graph_live_vp_interacting() then
    state.anim_graph_live_vp_was_interacting = true
    return
  end
  if state.anim_graph_live_vp_was_interacting then
    state.anim_graph_live_vp_was_interacting = false
    if state.live_gui_vp then
      state.anim_graph_vp_defer_flush = true
    end
  end
end

function live_vp_safe_for_chunk_write(ctx)
  if not ctx then
    return true
  end
  if anim_graph_live_vp_interacting() then
    return false
  end
  if ImGui.IsAnyItemActive and ImGui.IsAnyItemActive(ctx) then
    return false
  end
  if ImGui.IsWindowFocused and ImGui.FocusedFlags_AnyWindow then
    if not ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow) then
      return false
    end
  end
  if not state.anim_graph_vp_defer_flush and r.time_precise then
    local now = r.time_precise()
    local last = state._live_vp_last_chunk_write_t
    if type(last) == "number" and (now - last) < LIVE_VP_MIN_WRITE_INTERVAL then
      return false
    end
  end
  return true
end

auto_persist_layout = function(item, words, ctx)
  if not item or not words or #words == 0 then
    return
  end
  ml_sync_editor_text(words)
  local et = state.editor_text or ""
  if not editor_text_parse_ok(words, et) then
    return
  end
  write_editor_text_to_item(item, et)
  local nw = #words
  state.ml_word_n = nw
  r.SetExtState(SECTION, "EDITOR_TEXT", et, true)
  if nw > 1 then
    r.SetExtState(SECTION, "ML_PHRASE_AFTER", ml_bits_pack(state.ml_phrase_after, nw), true)
    r.SetExtState(SECTION, "ML_ROW_AFTER", ml_bits_pack(state.ml_row_after, nw), true)
  else
    r.SetExtState(SECTION, "ML_PHRASE_AFTER", "", true)
    r.SetExtState(SECTION, "ML_ROW_AFTER", "", true)
  end
  if nw > 0 then
    r.SetExtState(SECTION, "ML_WORDSCALE", ml_scales_pack(state.ml_word_scales, nw), true)
    r.SetExtState(SECTION, "ML_ROW_INDENT", ml_indents_pack(state.ml_row_indents, nw), true)
    if r.GetSetMediaItemInfo_String then
      r.GetSetMediaItemInfo_String(item, ITEM_EXT.ROW_SPACING, ml_row_spacings_pack(state.ml_row_spacings, nw), true)
    end
  end
  persist_word_styles(nw, item)
  if r.MarkProjectDirty then
    r.MarkProjectDirty(0)
  end
  refresh_preview(item)
  if state.live_gui_vp and state.preview_parse_err == "" and state.preview_segs > 0 and live_vp_safe_for_chunk_write(ctx) then
    local ok_vp = write_vp_for_item(item, { no_undo = true, skip_refresh = true, skip_if_same = true })
    if ok_vp and state.anim_graph_vp_defer_flush then
      state.anim_graph_vp_defer_flush = false
    end
  end
  state.overlay_autosave_sig_saved = overlay_autosave_state_sig(words)
end

function apply_to_selection()
  local nsel = r.CountSelectedMediaItems(0)
  if nsel ~= 1 then
    state.status = "Select exactly one media item with take markers."
    state.status_err = true
    return
  end
  local item = r.GetSelectedMediaItem(0, 0)
  local ok, err = write_vp_for_item(item)
  if not ok then
    state.status = err or "Failed."
    state.status_err = true
    return
  end
  state.status = string.format(
    "Video Processor updated. Words: %d  Subtitle line(s): %d  VP segments: %d",
    state.preview_words,
    state.preview_lines,
    state.preview_segs
  )
  state.status_err = false
end

--- Re-read take marker times from the item; keep subtitle field when it still parses; then rewrite VP.
function refresh_markers_and_apply(item)
  if not item then
    state.status = "Select exactly one media item."
    state.status_err = true
    return
  end
  local take, words = W.find_take_and_wx_words(item)
  if not take or #words == 0 then
    state.status = "No take markers with valid times on this item."
    state.status_err = true
    return
  end
  ml_load_for_word_count(#words, item)
  ml_sync_editor_text(words)
  local opts_chk = display_opts_from_state(words)
  local parsed_ok = W.parse_editor_phrases_for_multiline(words, state.editor_text or "", opts_chk)
  if not parsed_ok then
    for i = 1, math.max(0, #words - 1) do
      state.ml_phrase_after[i] = false
      state.ml_row_after[i] = false
    end
    ml_sync_editor_text(words)
  end
  state.overlay_source_key = overlay_source_key(item, words)
  state._last_vp_body = nil
  local ok, err = write_vp_for_item(item)
  if not ok then
    state.status = err or "Failed."
    state.status_err = true
    return
  end
  state.status = string.format(
    "Markers re-read → Video Processor updated. Words: %d  Subtitle line(s): %d  VP segments: %d",
    state.preview_words,
    state.preview_lines,
    state.preview_segs
  )
  state.status_err = false
end

--- Narrow width for per-row size / randomize sliders (fits label + two sliders on one line).
function ml_row_slider_w(ctx)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  return math.max(72, math.floor(fs * 7.8))
end

--- Main tri-stack parameter sliders: cap width so panels stay dense.
function ml_stack_param_item_w(ctx)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local avail = (ImGui.GetContentRegionAvail and ImGui.GetContentRegionAvail(ctx)) or 400
  return math.max(fs * 12, math.min(fs * 18, avail * 0.58))
end

--- Content region width (X) for layout; ReaImGui may return one or two values.
local function ml_content_region_avail_x(ctx)
  if not ImGui.GetContentRegionAvail then
    return 400
  end
  local a, b = ImGui.GetContentRegionAvail(ctx)
  local w = tonumber(a)
  if w and w > 1 then
    return math.max(80, w)
  end
  if type(a) == "table" then
    w = tonumber(a[1])
    if w and w > 1 then
      return math.max(80, w)
    end
  end
  return 400
end

--- Packs several controls per horizontal row when the window is wide enough (tri-stack Layout section).
local ml_flow_layout = { col = 0, cols = 1, item_w = 400, gap = 8 }

function ml_layout_flow_start(ctx, min_item_w)
  min_item_w = tonumber(min_item_w) or 168
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  min_item_w = math.max(min_item_w, math.floor(fs * 11))
  local avail = ml_content_region_avail_x(ctx)
  local gap = ml_flow_layout.gap
  local cols = math.min(4, math.max(1, math.floor((avail + gap) / (min_item_w + gap))))
  ml_flow_layout.cols = cols
  ml_flow_layout.item_w = math.max(1, math.floor(((avail - (cols - 1) * gap) / cols) + 0.5))
  ml_flow_layout.col = 0
end

function ml_layout_flow_next_cell(ctx)
  if ml_flow_layout.col > 0 and ImGui.SameLine then
    ImGui.SameLine(ctx, 0, ml_flow_layout.gap)
  end
  ml_flow_layout.col = ml_flow_layout.col + 1
  if ml_flow_layout.col >= ml_flow_layout.cols then
    ml_flow_layout.col = 0
  end
  return ml_flow_layout.item_w
end

function anim_combo_w(ctx, chars, min_w)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local w = fs * (tonumber(chars) or 14)
  local mw = tonumber(min_w) or 120
  return math.max(mw, math.floor(w + 0.5))
end

local WX_SLIDER_STYLES = {
  { name = "Aqua glow", bg = 0x15242CFF, fill = 0x36D6FFFF, knob = 0xE8FBFFFF, accent = 0x1090C0FF },
  { name = "Magenta pill", bg = 0x261428FF, fill = 0xF55AE6FF, knob = 0xFFE6FCFF, accent = 0x8C3A9AFF },
  { name = "Vintage VU", bg = 0x302819FF, fill = 0xFFB23DFF, knob = 0xFFF0C2FF, accent = 0x72521EFF },
  { name = "Minimal line", bg = 0x383838FF, fill = 0xDCDCDCFF, knob = 0xFFFFFFFF, accent = 0x777777FF },
  { name = "Neon rail", bg = 0x12182EFF, fill = 0x62FF8AFF, knob = 0xEFFFF2FF, accent = 0x55A7FFFF },
  { name = "Tape deck", bg = 0x24201CFF, fill = 0xC6A889FF, knob = 0xF2E1CFFF, accent = 0x6F6258FF },
  { name = "Sunset split", bg = 0x241A23FF, fill = 0xFF6C3DFF, knob = 0xFFF1C7FF, accent = 0xF6C34EFF },
  { name = "Glass blue", bg = 0x182130FF, fill = 0x7AAEFFFF, knob = 0xF2F7FFFF, accent = 0x4D6F9AFF },
  { name = "Mono chunk", bg = 0x101010FF, fill = 0xB8B8B8FF, knob = 0xEEEEEEFF, accent = 0x575757FF },
  { name = "Gold capsule", bg = 0x2B2412FF, fill = 0xFFD45CFF, knob = 0xFFF7D6FF, accent = 0xA57920FF },
}

state.wx_slider_style = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(state.wx_slider_style) or 1)))

--- RGBA from Appearance highlight swatch. Used for word-grid selection, marquee, indents, and active slider fills.
function wx_active_style_fill_rgba()
  local i = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(state.wx_slider_style) or 1)))
  return (state.wx_slider_highlight_colors and state.wx_slider_highlight_colors[i])
    or (state.wx_slider_colors and state.wx_slider_colors[i])
    or (WX_SLIDER_STYLES[i] and WX_SLIDER_STYLES[i].fill)
    or 0xFFFFFFFF
end

function clamp_num(v, lo, hi)
  v = tonumber(v) or 0
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

function wx_text_size(ctx, text)
  if ImGui.CalcTextSize then
    local ok, tw, th = pcall(ImGui.CalcTextSize, ctx, tostring(text or ""))
    if ok and tonumber(tw) then
      return tw, tonumber(th) or ((ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13)
    end
  end
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  return #tostring(text or "") * fs * 0.58, fs
end

function interp_color(c1, c2, t)
  local r1, g1, b1, a1 = (c1 >> 24) & 0xFF, (c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF, c1 & 0xFF
  local r2, g2, b2, a2 = (c2 >> 24) & 0xFF, (c2 >> 16) & 0xFF, (c2 >> 8) & 0xFF, c2 & 0xFF
  local r = math.floor(r1 + (r2 - r1) * t)
  local g = math.floor(g1 + (g2 - g1) * t)
  local b = math.floor(b1 + (b2 - b1) * t)
  local a = math.floor(a1 + (a2 - a1) * t)
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- When a style’s base ColorEdit is set (WX_SLIDER_C*), derive bg / knob / accent so sliders, buttons, and combos match that swatch.
function wx_effective_style_colors(style_idx)
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  local st = WX_SLIDER_STYLES[style_idx] or WX_SLIDER_STYLES[1]
  if state.wx_slider_colors and state.wx_slider_colors[style_idx] ~= nil then
    local c = state.wx_slider_colors[style_idx]
    local fill = c
    local ebg = interp_color(c, 0x000000FF, 0.68)
    ebg = (ebg & ~0xFF) | 0xFF
    local accent = interp_color(c, 0xFFFFFFFF, 0.38)
    accent = (accent & ~0xFF) | 0xFF
    local knob = interp_color(c, 0xFFFFFFFF, 0.52)
    knob = (knob & ~0xFF) | 0xFF
    return ebg, fill, knob, accent
  end
  return st.bg, st.fill, st.knob, st.accent
end

--- Accent from active UI style (derived accent when base swatch overrides palette).
function wx_active_style_accent_rgba()
  local i = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(state.wx_slider_style) or 1)))
  local _, _, _, accent = wx_effective_style_colors(i)
  return accent
end

function wx_effective_highlight_color(style_idx, fallback_fill)
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  return (state.wx_slider_highlight_colors and state.wx_slider_highlight_colors[style_idx])
    or fallback_fill
    or (WX_SLIDER_STYLES[style_idx] and WX_SLIDER_STYLES[style_idx].fill)
    or 0xFFFFFFFF
end

wx_custom_button = function(ctx, label, w, h, style_idx, small, mark_col, outline_col)
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  local st = WX_SLIDER_STYLES[style_idx] or WX_SLIDER_STYLES[1]
  local ebg, fill, knob, accent = wx_effective_style_colors(style_idx)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local shown_label = wx_visible_label(label)
  if shown_label == "" then
    shown_label = " "
  end
  local tw, th = wx_text_size(ctx, shown_label)
  local bw = tonumber(w) or 0
  local bh = tonumber(h) or 0
  if bw <= 0 then
    bw = math.max(small and fs * 3.2 or fs * 5.2, tw + fs * (small and 1.1 or 1.7))
  end
  if bh <= 0 then
    bh = math.max(small and math.floor(fs * 1.45 + 0.5) or math.floor(fs * 1.85 + 0.5), th + fs * (small and 0.38 or 0.62))
  end

  if not (ImGui.InvisibleButton and ImGui.GetWindowDrawList and ImGui.DrawList_AddRectFilled) then
    return ImGui.Button and ImGui.Button(ctx, label, bw, bh)
  end

  local x, y = 0, 0
  if ImGui.GetCursorScreenPos then
    x, y = ImGui.GetCursorScreenPos(ctx)
  end
  local clicked = ImGui.InvisibleButton(ctx, label, bw, bh) and true or false
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)
  if not clicked and ImGui.IsItemClicked then
    clicked = ImGui.IsItemClicked(ctx, 0) and true or false
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  local can_rect = ImGui.DrawList_AddRect ~= nil
  local can_line = ImGui.DrawList_AddLine ~= nil
  local can_circle = ImGui.DrawList_AddCircleFilled ~= nil
  local rrad = (style_idx == 4 or style_idx == 9) and 2 or math.max(3, math.floor(bh * 0.28))
  local bg = active and fill or (hovered and accent or ebg)
  local text_col = active and 0x101010FF or (hovered and 0xFFFFFFFF or knob)
  if outline_col and not mark_col then
    local bgq = wx_im_col_alpha_mul(ebg, 0.06)
    if active then
      bgq = wx_im_col_alpha_mul(accent, 0.22)
    elseif hovered then
      bgq = wx_im_col_alpha_mul(accent, 0.12)
    end
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bgq, rrad)
    if can_rect then
      ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, outline_col, rrad, 0, (active or hovered) and 2 or 1)
    end
    if ImGui.DrawList_AddText then
      ImGui.DrawList_AddText(dl, x + (bw - tw) * 0.5, y + (bh - th) * 0.5 - 1, text_col, shown_label)
    end
    return clicked
  end
  if mark_col then
    bg = active and fill or (hovered and interp_color(mark_col, accent, 0.35) or mark_col)
    text_col = 0xFFFFFFFF
  end

  if style_idx == 1 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, rrad)
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 2, x + bw - 2, y + bh * 0.5, 0xFFFFFF18, math.max(1, rrad - 1))
    if can_line then ImGui.DrawList_AddLine(dl, x + 4, y + bh - 4, x + bw - 4, y + bh - 4, fill, active and 2 or 1) end
  elseif style_idx == 2 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, bh * 0.5)
    ImGui.DrawList_AddRectFilled(dl, x + 3, y + bh * 0.45, x + bw - 3, y + bh * 0.62, 0x00000033, bh * 0.12)
  elseif style_idx == 3 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, 0x1A140CFF, 0)
    if can_rect then ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, active and fill or accent, 0, 0, active and 2 or 1) end
    if can_line then
      for tx = x + 5, x + bw - 4, 9 do
        ImGui.DrawList_AddLine(dl, tx, y + bh - 4, tx, y + bh - 2, active and fill or accent, 1)
      end
    end
    text_col = active and fill or knob
  elseif style_idx == 4 then
    if can_line then
      ImGui.DrawList_AddLine(dl, x, y + bh * 0.5, x + bw, y + bh * 0.5, bg, active and 4 or 2)
      ImGui.DrawList_AddLine(dl, x, y + bh - 2, x + bw, y + bh - 2, fill, active and 2 or 1)
    else
      ImGui.DrawList_AddRectFilled(dl, x, y + bh * 0.42, x + bw, y + bh * 0.58, bg, 1)
    end
  elseif style_idx == 5 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, rrad)
    if can_rect then ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, fill, rrad, 0, active and 2 or 1) end
    if can_line then ImGui.DrawList_AddLine(dl, x + 4, y + 3, x + bw - 4, y + 3, accent, 1) end
  elseif style_idx == 6 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, 3)
    if can_rect then
      ImGui.DrawList_AddRect(dl, x + 1, y + 1, x + bw - 1, y + bh - 1, accent, 3, 0, 1)
      ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, 0x000000AA, 3, 0, active and 2 or 1)
    end
    text_col = active and 0xFFFFFFFF or knob
  elseif style_idx == 7 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, rrad)
    if ImGui.DrawList_AddRectFilledMultiColor then
      ImGui.DrawList_AddRectFilledMultiColor(dl, x + 2, y + 2, x + bw - 2, y + bh - 2, accent, fill, fill, accent)
    end
    if can_rect then ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, 0xFFFFFF44, rrad, 0, 1) end
  elseif style_idx == 8 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, 0x0B1220DD, rrad)
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 2, x + bw - 2, y + bh - 2, bg, math.max(2, rrad - 2))
    if can_rect then ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, 0xBBD7FFFF, rrad, 0, active and 2 or 1) end
  elseif style_idx == 9 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, 1)
    if can_rect then ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, fill, 1, 0, active and 2 or 1) end
    if can_line then
      local chunks = math.max(3, math.floor(bw / math.max(8, fs * 0.75)))
      local gap = 2
      local cw = (bw - gap * (chunks + 1)) / chunks
      for i = 1, chunks do
        local cx0 = x + gap + (i - 1) * (cw + gap)
        ImGui.DrawList_AddLine(dl, cx0, y + bh - 3, cx0 + cw, y + bh - 3, hovered and fill or accent, 1)
      end
    end
  elseif style_idx == 10 then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, bh * 0.5)
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 3, x + bw - 2, y + bh - 3, 0x00000033, bh * 0.35)
    if can_circle then
      ImGui.DrawList_AddCircleFilled(dl, x + bh * 0.5, y + bh * 0.5, bh * 0.24, active and 0xFFFFFFFF or fill)
      ImGui.DrawList_AddCircleFilled(dl, x + bw - bh * 0.5, y + bh * 0.5, bh * 0.24, active and 0xFFFFFFFF or fill)
    end
    text_col = active and 0xFFFFFFFF or fill
  else
    ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg, rrad)
  end

  if outline_col and mark_col and can_rect then
    ImGui.DrawList_AddRect(dl, x, y, x + bw, y + bh, outline_col, rrad, 0, (hovered or active) and 2 or 1)
  end

  if ImGui.DrawList_AddText then
    ImGui.DrawList_AddText(dl, x + (bw - tw) * 0.5, y + (bh - th) * 0.5 - 1, text_col, shown_label)
  end
  return clicked
end

wx_custom_small_button = function(ctx, label, style_idx)
  return wx_custom_button(ctx, label, 0, 0, style_idx, true)
end

--- True while REAPER plays or records — matches word-marker follow heuristic.
local function wx_reaper_transport_moving()
  if not r.GetPlayState then
    return false
  end
  local ps = r.GetPlayState()
  return (ps & 5) ~= 0
end

--- Small vector transport glyphs (triangle play, filled square stop/pause motif, wedge skip cues).
local function wx_transport_triangle_r(dl, ax, ay, bx, by, cx, cy, col)
  if ImGui.DrawList_AddTriangleFilled then
    ImGui.DrawList_AddTriangleFilled(dl, ax, ay, bx, by, cx, cy, col)
    return true
  end
  local th = 2
  if ImGui.DrawList_AddLine then
    ImGui.DrawList_AddLine(dl, ax, ay, bx, by, col, th)
    ImGui.DrawList_AddLine(dl, bx, by, cx, cy, col, th)
    ImGui.DrawList_AddLine(dl, cx, cy, ax, ay, col, th)
    return true
  end
  return false
end

local function wx_transport_draw_glyph_play(dl, x, y, w, h, col)
  local pad = math.max(3.6, math.min(w, h) * 0.15)
  local apex_x = x + w - pad
  local base_x = x + pad + math.min(w, h) * 0.06
  local mid_y = y + h * 0.5
  local hh = math.min(w, h) * 0.34
  return wx_transport_triangle_r(dl, apex_x, mid_y, base_x, mid_y - hh, base_x, mid_y + hh, col)
end

--- Stop / pause square (filled).
local function wx_transport_draw_glyph_stop(dl, x, y, w, h, col)
  local sz = math.min(w, h) * 0.44
  local x0 = x + (w - sz) * 0.5
  local y0 = y + (h - sz) * 0.5
  local rr = math.max(2, sz * 0.12)
  if ImGui.DrawList_AddRectFilled then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + sz, y0 + sz, col, rr)
    return true
  end
  return false
end

local function wx_transport_draw_glyph_next(dl, x, y, w, h, col)
  --- Two right-pointing wedges + slim bar (“skip toward end” motif).
  local mid_y = y + h * 0.5
  local apex_off = math.min(w, h) * 0.33
  local half_h = apex_off * 0.92
  local gap = apex_off * 0.52
  local cx_left = x + w * 0.5 - gap * 0.35 - apex_off * 1.08
  for k = 0, 1 do
    local base_x = cx_left + k * gap
    local apex_x = base_x + apex_off
    if not wx_transport_triangle_r(dl, apex_x, mid_y, base_x, mid_y - half_h, base_x, mid_y + half_h, col) then
      return false
    end
  end
  local bar_x = x + w - math.max(2.8, math.min(w, h) * 0.08)
  if ImGui.DrawList_AddLine then
    ImGui.DrawList_AddLine(dl, bar_x, mid_y - half_h * 1.06, bar_x, mid_y + half_h * 1.06, col, math.max(1.5, apex_off * 0.11))
    return true
  end
  return true
end

local function wx_transport_draw_glyph_previous(dl, x, y, w, h, col)
  --- Mirror of Next.
  local mid_y = y + h * 0.5
  local apex_off = math.min(w, h) * 0.33
  local half_h = apex_off * 0.92
  local gap = apex_off * 0.52
  local cx_right = x + w * 0.5 + gap * 0.35 + apex_off * 1.08
  for k = 0, 1 do
    local base_x = cx_right - k * gap
    local apex_x = base_x - apex_off
    if not wx_transport_triangle_r(dl, apex_x, mid_y, base_x, mid_y - half_h, base_x, mid_y + half_h, col) then
      return false
    end
  end
  local bar_x = x + math.max(2.8, math.min(w, h) * 0.08)
  if ImGui.DrawList_AddLine then
    ImGui.DrawList_AddLine(dl, bar_x, mid_y - half_h * 1.06, bar_x, mid_y + half_h * 1.06, col, math.max(1.5, apex_off * 0.11))
    return true
  end
  return true
end

--- Icon-only toolbar button; `playback_lit` tints chrome (used for Play while transport runs).
local function wx_transport_icon_button(ctx, label, bw, bh, slider_style_idx, draw_glyph, playback_lit)
  if not (ImGui.InvisibleButton and ImGui.GetWindowDrawList and ImGui.DrawList_AddRectFilled) then
    return wx_custom_small_button(ctx, label, slider_style_idx)
  end
  slider_style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(slider_style_idx) or 1)))
  local ebg, fill, knob, accent = wx_effective_style_colors(slider_style_idx)
  bw = tonumber(bw) or 28
  bh = tonumber(bh) or 28

  local x, y = 0, 0
  if ImGui.GetCursorScreenPos then
    x, y = ImGui.GetCursorScreenPos(ctx)
  end

  local clicked = ImGui.InvisibleButton(ctx, label, bw, bh) and true or false
  if not clicked and ImGui.IsItemClicked then
    clicked = ImGui.IsItemClicked(ctx, 0) and true or false
  end
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)

  local dl = ImGui.GetWindowDrawList(ctx)
  local can_rect = ImGui.DrawList_AddRect ~= nil
  local rrad = math.max(3, math.floor(bh * 0.29))
  local base_bg = active and fill or (hovered and accent or ebg)

  local bg_main = playback_lit and interp_color(base_bg, accent, hovered and 0.58 or 0.42) or base_bg

  ImGui.DrawList_AddRectFilled(dl, x, y, x + bw, y + bh, bg_main, rrad)

  if playback_lit then
    ImGui.DrawList_AddRectFilled(dl, x + 2, y + 2, x + bw - 2, y + bh - 2, wx_im_col_alpha_mul(accent, 0.38), math.max(1, rrad - 2))
  end

  if can_rect then
    ImGui.DrawList_AddRect(
      dl,
      x,
      y,
      x + bw,
      y + bh,
      playback_lit and accent or wx_im_col_alpha_mul(accent, hovered and 0.85 or 0.45),
      rrad,
      0,
      (playback_lit or hovered or active) and 2 or 1
    )
  end

  local icon_col
  if playback_lit then
    icon_col = 0xFFFFF8FF
  elseif active then
    icon_col = 0x101010FF
  elseif hovered then
    icon_col = 0xFFFFFFFF
  else
    icon_col = knob
  end

  if draw_glyph then
    draw_glyph(dl, x, y, bw, bh, icon_col)
  end

  return clicked
end

wx_bridge_transport_strip = function(ctx, slider_style_idx)
  if not r.Main_OnCommand then
    return
  end
  slider_style_idx = tonumber(slider_style_idx) or 1
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local side = math.max(28, math.floor(fs * 2.08 + 0.5))

  local moving = wx_reaper_transport_moving()

  local function tl(tip)
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, tip)
    elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, tip)
    end
  end

  if ImGui.BeginGroup then
    ImGui.BeginGroup(ctx)
  end

  if wx_transport_icon_button(ctx, "##wx_tr_play", side, side, slider_style_idx, wx_transport_draw_glyph_play, moving) then
    r.Main_OnCommand(40073, 0) -- Transport: Play/pause
  end
  tl(moving and "Pause (transport running)" or "Play")

  if ImGui.SameLine then
    ImGui.SameLine(ctx, 0, 6)
  end

  if wx_transport_icon_button(ctx, "##wx_tr_stop_square", side, side, slider_style_idx, wx_transport_draw_glyph_stop, false) then
    r.Main_OnCommand(40667, 0) -- Transport: Stop
  end
  tl("Stop")

  if ImGui.SameLine then
    ImGui.SameLine(ctx, 0, 6)
  end

  if wx_transport_icon_button(ctx, "##wx_tr_next", side, side, slider_style_idx, wx_transport_draw_glyph_next, false) then
    r.Main_OnCommand(40173, 0) -- Markers: Next marker/project end
  end
  tl("Next marker / project end")

  if ImGui.SameLine then
    ImGui.SameLine(ctx, 0, 6)
  end

  if wx_transport_icon_button(ctx, "##wx_tr_prev", side, side, slider_style_idx, wx_transport_draw_glyph_previous, false) then
    r.Main_OnCommand(40172, 0) -- Markers: Previous marker/project start
  end
  tl("Previous marker / project start")

  if ImGui.EndGroup then
    ImGui.EndGroup(ctx)
  end
end

local _wx_slider_drag_part = {}

--- Pixels above rail_y (slider centerline) to topmost drawn rail/knob art (for readout vertical clearance).
function wx_slider_extent_above_rail(si, rail_h, fs, h_main, main_active, stepped_rail)
  if stepped_rail then
    local body = rail_h * 0.55
    local knob = math.max(main_active and fs * 0.52 or fs * 0.45, h_main * 0.38)
    return math.max(body, knob)
  end
  local body = rail_h * 0.48
  if si == 3 then body = rail_h * 0.38
  elseif si == 4 then body = fs * 0.35
  elseif si == 5 then body = rail_h * 0.28
  elseif si == 6 then body = rail_h * 0.55
  elseif si == 7 then body = rail_h
  elseif si == 8 then body = rail_h * 0.62
  elseif si == 9 then body = rail_h * 0.55
  elseif si == 10 then body = math.max(rail_h * 0.58, rail_h * 0.46)
  end
  local knob = 0
  if si == 7 then
    knob = (main_active and fs * 0.59 or fs * 0.51)
  elseif si == 10 then
    knob = (main_active and fs * 0.72 or fs * 0.62)
  elseif si == 6 or si == 9 then
    knob = h_main * 0.42
  elseif si ~= 4 then
    knob = main_active and fs * 0.52 or fs * 0.45
  end
  return math.max(body, knob)
end

--- Discrete "mono chunk" rail: one segment per integer step (min_v..max_v), using the active style palette.
--- Returns block width (for knob sizing).
function wx_slider_draw_stepped_rail(dl, ctx, style_idx, rail_x0, rail_y, rail_x1, rail_h, min_v, max_v, value,
    fs, h_main, rrad, st, bg, fill, accent, main_active, main_hovered, can_rect, can_circle)
  local n = math.max(1, max_v - min_v + 1)
  local gap = math.max(1, math.min(3, math.floor(fs * 0.11 + 0.5)))
  local span_px = (rail_x1 - rail_x0) - gap * (n - 1)
  local block_w = math.max(2, span_px / n)
  local vy0 = rail_y - rail_h * 0.55
  local vy1 = rail_y + rail_h * 0.55
  local chunk_rnd
  if style_idx == 4 or style_idx == 9 then
    chunk_rnd = 1
  elseif style_idx == 10 then
    chunk_rnd = math.min(rail_h * 0.38, block_w * 0.45)
  else
    chunk_rnd = math.min(rrad, math.max(2, math.floor(block_w * 0.32)))
  end

  if style_idx == 8 and can_rect then
    ImGui.DrawList_AddRectFilled(dl, rail_x0 - 1, vy0 - 2, rail_x1 + 1, vy1 + 2, 0x0B1220DD, rrad)
    if ImGui.DrawList_AddRect then
      ImGui.DrawList_AddRect(dl, rail_x0 - 1, vy0 - 2, rail_x1 + 1, vy1 + 2, 0xBBD7FFFF, rrad, 0, 1)
    end
  end

  local inset_l, inset_r = 0, 0
  if style_idx == 8 then
    inset_l, inset_r = 3, 3
  end
  local rx0, rx1 = rail_x0 + inset_l, rail_x1 - inset_r
  span_px = (rx1 - rx0) - gap * (n - 1)
  block_w = math.max(2, span_px / n)

  for k = 1, n do
    local vx = min_v + k - 1
    local col
    if style_idx == 7 then
      local tk = (max_v > min_v) and ((vx - min_v) / (max_v - min_v)) or 0
      col = (vx <= value) and interp_color(accent, fill, tk) or bg
    else
      col = (vx <= value) and fill or bg
    end
    local bx0 = rx0 + (k - 1) * (block_w + gap)
    local bx1 = bx0 + block_w
    if bx1 > rx1 + 0.5 then
      bx1 = rx1
    end
    ImGui.DrawList_AddRectFilled(dl, bx0, vy0, bx1, vy1, col, chunk_rnd)
    if style_idx == 2 then
      ImGui.DrawList_AddRectFilled(dl, bx0, rail_y - rail_h * 0.15, bx1, rail_y + rail_h * 0.12, 0x00000033, chunk_rnd)
    elseif style_idx == 5 then
      ImGui.DrawList_AddLine(dl, bx0, vy0, bx1, vy0, accent, main_active and 2 or 1)
      ImGui.DrawList_AddLine(dl, bx0, vy1, bx1, vy1, accent, 1)
    elseif style_idx == 6 and can_rect then
      ImGui.DrawList_AddRect(dl, bx0, vy0, bx1, vy1, accent, chunk_rnd, 0, 1)
    end
    if (style_idx == 4 or style_idx == 9) and can_rect then
      ImGui.DrawList_AddRect(dl, bx0, vy0, bx1, vy1, main_hovered and accent or fill, chunk_rnd, 0, (style_idx == 9) and 2 or 1)
    end
  end

  if style_idx == 1 then
    ImGui.DrawList_AddLine(dl, rx0 + 2, rail_y - rail_h * 0.14, rx1 - 2, rail_y - rail_h * 0.14, 0xFFFFFF22, 1)
  elseif style_idx == 3 then
    for k = 1, n do
      local bx0 = rx0 + (k - 1) * (block_w + gap)
      ImGui.DrawList_AddLine(dl, bx0 + block_w * 0.5, vy1, bx0 + block_w * 0.5, vy1 + rail_h * 0.42,
        (min_v + k - 1 <= value) and fill or accent, (k == 1 or k == n) and 2 or 1)
    end
  elseif style_idx == 10 then
    ImGui.DrawList_AddLine(dl, rx0 + 4, rail_y - rail_h * 0.42, rx1 - 4, rail_y - rail_h * 0.42, 0xFFFFFFFF, 1)
    for k = 1, n - 1 do
      local bx1 = rx0 + (k - 1) * (block_w + gap) + block_w
      local tx = bx1 + gap * 0.5
      ImGui.DrawList_AddLine(dl, tx, rail_y - rail_h * 0.14, tx, rail_y + rail_h * 0.14,
        (min_v + k <= value) and 0x7A4B00FF or accent, 1)
    end
  end

  if style_idx == 2 and can_circle then
    for k = 1, n do
      local bx0 = rx0 + (k - 1) * (block_w + gap)
      local cx = bx0 + block_w * 0.5
      ImGui.DrawList_AddCircleFilled(dl, cx, rail_y, 2, (min_v + k - 1 <= value) and 0xFFFFFFAA or 0x00000066)
    end
  end

  return block_w
end

--- Rotary knob for integer degrees: label above, value readout below, drag vertically to adjust (Shift = finer steps).
--- Double-click resets to `reset_deg` (default 0; pass 90 for direction defaults).
function wx_degree_knob_int(ctx, id, label, value, min_v, max_v, fmt, width, style_idx, reset_deg)
  value = math.floor(clamp_num(value, min_v, max_v) + 0.5)
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  local ebg, fill, knob_outline, accent = wx_effective_style_colors(style_idx)
  local shown_label = wx_visible_label(label)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local avail = ml_content_region_avail_x(ctx)
  local requested_w = tonumber(width)
  local w = requested_w and math.min(requested_w, avail) or math.min(fs * 7, avail)
  w = math.max(1, w)
  local fmt_use = fmt or "%d°"
  local value_text = string.format(fmt_use, value)
  local knob_r = math.floor(math.max(13, math.min(w * 0.39, fs * 1.42)) + 0.5)
  local tw_l, th_l = wx_text_size(ctx, (shown_label ~= "") and shown_label or " ")
  local tw_v, th_v = wx_text_size(ctx, value_text)
  local pad_y = math.max(2, math.floor(fs * 0.12))
  local gap_label = math.max(4, math.floor(fs * 0.28))
  local gap_readout = math.max(3, math.floor(fs * 0.24))
  local h = pad_y + th_l + gap_label + knob_r * 2 + gap_readout + th_v + pad_y + 2
  local x, y = 0, 0
  if ImGui.GetCursorScreenPos then
    x, y = ImGui.GetCursorScreenPos(ctx)
  end

  if not (ImGui.InvisibleButton and ImGui.GetWindowDrawList and ImGui.DrawList_AddLine and ImGui.DrawList_AddCircle) then
    if ImGui.PushItemWidth then
      ImGui.PushItemWidth(ctx, w)
    end
    local rv, out = ImGui.SliderInt(ctx, label .. id, value, min_v, max_v, fmt_use)
    if ImGui.PopItemWidth then
      ImGui.PopItemWidth(ctx)
    end
    return rv, out
  end

  ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)
  local changed = false

  if hovered and ImGui.IsMouseDoubleClicked and ImGui.IsMouseDoubleClicked(ctx, 0) then
    local rst = math.floor(clamp_num(tonumber(reset_deg) or 0, min_v, max_v) + 0.5)
    if rst ~= value then
      value = rst
      changed = true
      value_text = string.format(fmt_use, value)
    end
  end

  if active and ImGui.GetMouseDelta then
    local _, dy = ImGui.GetMouseDelta(ctx)
    if dy ~= 0 then
      local span = max_v - min_v
      local step = (math.abs(span) >= 1) and (span / 200) or 1
      if overlay_mod_shift(ctx) then
        step = step / 5
      end
      local nv = math.floor(value + (-dy) * step + 0.5)
      nv = math.floor(clamp_num(nv, min_v, max_v) + 0.5)
      if nv ~= value then
        value = nv
        changed = true
        value_text = string.format(fmt_use, value)
      end
    end
  end

  local dl = ImGui.GetWindowDrawList(ctx)
  local cx = x + w * 0.5
  local label_y = y + pad_y
  local knob_cy = label_y + th_l + gap_label + knob_r
  local readout_y = knob_cy + knob_r + gap_readout - 1
  local t = 0
  if max_v ~= min_v then
    t = clamp_num((value - min_v) / (max_v - min_v), 0, 1)
  end
  local ANGLE_MIN, ANGLE_MAX = math.pi * 0.75, math.pi * 2.25
  local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * t
  local cs, sn = math.cos(angle), math.sin(angle)
  local ptr_len = knob_r * 0.62
  local ring_col = hovered and accent or (active and fill or knob_outline)

  local label_tx = cx - tw_l * 0.5
  ImGui.DrawList_AddText(dl, label_tx, label_y - 1, hovered and GRIP_LABEL_CLR_HOT or 0xC8C8C8FF, (shown_label ~= "") and shown_label or " ")
  local body_col = hovered and interp_color(ebg, fill, 0.22) or ebg
  if ImGui.DrawList_AddCircleFilled then
    ImGui.DrawList_AddCircleFilled(dl, cx, knob_cy, knob_r + 1, interp_color(body_col, 0x000000FF, 0.15))
    ImGui.DrawList_AddCircleFilled(dl, cx, knob_cy, knob_r * 0.94, body_col)
  end
  ImGui.DrawList_AddCircle(dl, cx, knob_cy, knob_r, ring_col, 0, active and 2.2 or 1.25)
  ImGui.DrawList_AddLine(dl, cx, knob_cy, cx + cs * ptr_len, knob_cy + sn * ptr_len, accent, active and 2.75 or 2.25)
  if ImGui.DrawList_AddCircleFilled then
    ImGui.DrawList_AddCircleFilled(dl, cx, knob_cy, math.max(2, knob_r * 0.17), interp_color(ring_col, 0x101010FF, 0.45))
  end

  local readout_hot = active or hovered
  local rv_col = readout_hot and GRIP_LABEL_CLR_HOT or 0xDCDCDCFF
  ImGui.DrawList_AddText(dl, cx - tw_v * 0.5, readout_y - 1, rv_col, value_text)

  if hovered and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx,
      (shown_label ~= "" and (shown_label .. ": ") or "") .. value_text .. "\nDrag vertically • Shift: fine • Double-click: reset")
  end
  return changed, value
end

wx_custom_slider_int = function(ctx, id, label, value, min_v, max_v, fmt, width, style_idx, rand_value, rand_max, rand_fmt, stepped)
  -- stepped: when true, rail draws one filled chunk per integer step (max 36 slots); for low-range params.
  value = math.floor(clamp_num(value, min_v, max_v) + 0.5)
  local has_rand = rand_max and rand_max > 0
  if has_rand then
    rand_value = math.floor(clamp_num(rand_value, 0, rand_max) + 0.5)
  end
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  local st = WX_SLIDER_STYLES[style_idx] or WX_SLIDER_STYLES[1]
  local ebg, fill, knob, accent = wx_effective_style_colors(style_idx)
  local hfill = wx_effective_highlight_color(style_idx, fill)
  local shown_label = wx_visible_label(label)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local avail = ml_content_region_avail_x(ctx)
  local requested_w = tonumber(width)
  local w = requested_w and math.min(requested_w, avail) or math.min(fs * 18, avail)
  w = math.max(1, w)
  local value_text = string.format(fmt or "%d", value)
  local readout_gap = math.max(4, math.floor(fs * 0.28))
  -- Label left / readout right on one row; vertical centering uses readout box in draw (tw_l, th_l).
  local tw_l, th_l = wx_text_size(ctx, (shown_label ~= "") and shown_label or " ")
  local readout_pad = math.max(3, math.floor(fs * 0.24 + 0.5))
  local span_slots = math.max(1, max_v - min_v + 1)
  local stepped_rail = stepped == true and span_slots <= 36
  local h_main = math.max(34, math.floor(fs * 2.55 + 0.5))
  local h_rand = has_rand and math.floor(fs * 1.6) or 0
  local h = h_main + h_rand
  local x, y = 0, 0
  if ImGui.GetCursorScreenPos then
    x, y = ImGui.GetCursorScreenPos(ctx)
  end

  if not (ImGui.InvisibleButton and ImGui.GetWindowDrawList and ImGui.DrawList_AddRectFilled and ImGui.DrawList_AddLine and ImGui.GetMousePos) then
    if ImGui.PushItemWidth then ImGui.PushItemWidth(ctx, w) end
    local rv, out = ImGui.SliderInt(ctx, label .. id, value, min_v, max_v, fmt or "%d")
    local rv_r, out_r = false, rand_value
    if has_rand then
      rv_r, out_r = ImGui.SliderInt(ctx, "±##" .. id .. "_r", rand_value, 0, rand_max, rand_fmt or "%d")
    end
    if ImGui.PopItemWidth then ImGui.PopItemWidth(ctx) end
    return rv, out, rv_r, out_r
  end

  ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)
  local changed = false
  local changed_rand = false

  local mx, my
  if ImGui.GetMousePos then
    mx, my = ImGui.GetMousePos(ctx)
  else
    mx, my = 0, 0
  end

  if ImGui.IsItemActivated and ImGui.IsItemActivated(ctx) then
    if has_rand and my > y + h_main - fs * 0.2 then
      _wx_slider_drag_part[id] = "rand"
    else
      _wx_slider_drag_part[id] = "main"
    end
  elseif not active then
    _wx_slider_drag_part[id] = nil
  end

  local drag_part = _wx_slider_drag_part[id] or "main"
  local main_hovered = hovered and (not has_rand or my <= y + h_main - fs * 0.2)
  local rand_hovered = hovered and has_rand and my > y + h_main - fs * 0.2
  local main_active = active and drag_part == "main"
  local rand_active = active and drag_part == "rand"
  local main_hover_paint = main_hovered and not main_active
  local rand_hover_paint = rand_hovered and not rand_active

  if active and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, 0) then
    local left_pad = fs * 0.7
    local right_pad = fs * 0.7
    local rw = math.max(1, w - left_pad - right_pad)
    
    if drag_part == "main" then
      local t = clamp_num((mx - (x + left_pad)) / rw, 0, 1)
      local next_v = math.floor(min_v + (max_v - min_v) * t + 0.5)
      next_v = math.floor(clamp_num(next_v, min_v, max_v) + 0.5)
      if next_v ~= value then
        value = next_v
        changed = true
      end
    elseif has_rand then
      local cx = x + w * 0.5
      local t = clamp_num(math.abs(mx - cx) / (rw * 0.5), 0, 1)
      local next_r = math.floor(t * rand_max + 0.5)
      next_r = math.floor(clamp_num(next_r, 0, rand_max) + 0.5)
      if next_r ~= rand_value then
        rand_value = next_r
        changed_rand = true
      end
    end
  end

  local dl = ImGui.GetWindowDrawList(ctx)
  local t = 0
  if max_v ~= min_v then
    t = clamp_num((value - min_v) / (max_v - min_v), 0, 1)
  end
  local rail_x0, rail_x1 = x + fs * 0.7, x + w - fs * 0.7
  local rail_y = y + h_main * 0.68
  local fill_x = rail_x0 + (rail_x1 - rail_x0) * t
  local rrad = (style_idx == 4 or style_idx == 9) and 2 or math.floor(h_main * 0.28)
  local rail_h = (style_idx == 4) and 3 or math.max(6, math.floor(h_main * 0.34))
  if style_idx == 6 then
    rail_h = math.max(10, math.floor(h_main * 0.38))
  elseif style_idx == 8 then
    rail_h = math.max(14, math.floor(h_main * 0.46))
  elseif style_idx == 10 then
    rail_h = math.max(16, math.floor(h_main * 0.5))
  end
  local bg = ebg
  if main_hover_paint then
    bg = accent
  end

  local can_circle = ImGui.DrawList_AddCircleFilled ~= nil
  local can_rect = ImGui.DrawList_AddRect ~= nil
  local stepped_block_w
  if stepped_rail then
    stepped_block_w = wx_slider_draw_stepped_rail(dl, ctx, style_idx, rail_x0, rail_y, rail_x1, rail_h,
      min_v, max_v, value, fs, h_main, rrad, st, bg, hfill, accent, main_active, main_hover_paint, can_rect, can_circle)
  elseif style_idx == 1 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.45, rail_x1, rail_y + rail_h * 0.45, bg, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.45, fill_x, rail_y + rail_h * 0.45, hfill, rrad)
    ImGui.DrawList_AddLine(dl, rail_x0 + 4, rail_y - rail_h * 0.16, rail_x1 - 4, rail_y - rail_h * 0.16, 0xFFFFFF22, 1)
    ImGui.DrawList_AddLine(dl, rail_x0 + 4, rail_y + rail_h * 0.17, fill_x - 4, rail_y + rail_h * 0.17, accent, 1)
  elseif style_idx == 2 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.5, rail_x1, rail_y + rail_h * 0.5, bg, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.18, rail_x1, rail_y + rail_h * 0.18, 0x00000033, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.5, fill_x, rail_y + rail_h * 0.5, hfill, rrad)
    if can_circle then
      for i = 1, 4 do
        local dx = rail_x0 + 4 + (rail_x1 - rail_x0 - 8) * (i / 5)
        ImGui.DrawList_AddCircleFilled(dl, dx, rail_y, 2, dx <= fill_x and 0xFFFFFFAA or 0x00000066)
      end
    end
  elseif style_idx == 3 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.38, rail_x1, rail_y + rail_h * 0.38, bg, 3)
    local ticks = 16
    for i = 0, ticks do
      local tx = rail_x0 + (rail_x1 - rail_x0) * (i / ticks)
      local major = (i % 4) == 0
      local col = tx <= fill_x and hfill or accent
      ImGui.DrawList_AddLine(dl, tx, rail_y + rail_h * 0.48, tx, rail_y + rail_h * (major and 0.9 or 0.72), col, major and 2 or 1)
    end
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.38, fill_x, rail_y + rail_h * 0.38, hfill, 3)
  elseif style_idx == 4 then
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y, rail_x1, rail_y, bg, 2)
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y, fill_x, rail_y, hfill, main_active and 4 or 3)
    ImGui.DrawList_AddLine(dl, fill_x, rail_y - fs * 0.35, fill_x, rail_y + fs * 0.35, knob, 2)
  elseif style_idx == 5 then
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y - rail_h * 0.28, rail_x1, rail_y - rail_h * 0.28, bg, 3)
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y + rail_h * 0.28, rail_x1, rail_y + rail_h * 0.28, accent, 2)
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y - rail_h * 0.28, fill_x, rail_y - rail_h * 0.28, hfill, main_active and 5 or 4)
    ImGui.DrawList_AddLine(dl, rail_x0, rail_y + rail_h * 0.28, fill_x, rail_y + rail_h * 0.28, hfill, main_active and 3 or 2)
  elseif style_idx == 6 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.55, rail_x1, rail_y + rail_h * 0.55, bg, 3)
    if can_rect then
      ImGui.DrawList_AddRect(dl, rail_x0, rail_y - rail_h * 0.55, rail_x1, rail_y + rail_h * 0.55, accent, 3, 0, 1)
    end
    local lanes = 7
    local lane_gap = 3
    local lane_w = (rail_x1 - rail_x0 - lane_gap * (lanes - 1)) / lanes
    for i = 1, lanes do
      local lx0 = rail_x0 + (i - 1) * (lane_w + lane_gap)
      local lx1 = lx0 + lane_w
      local lit = (lx0 + lx1) * 0.5 <= fill_x
      ImGui.DrawList_AddRectFilled(dl, lx0, rail_y - rail_h * 0.28, lx1, rail_y + rail_h * 0.28, lit and hfill or 0x00000055, 2)
    end
  elseif style_idx == 7 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.58, rail_x1, rail_y + rail_h * 0.58, bg, rrad)
    if ImGui.PushClipRect and ImGui.DrawList_AddRectFilledMultiColor then
      ImGui.PushClipRect(ctx, rail_x0, rail_y - rail_h, fill_x, rail_y + rail_h, true)
      ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.58, rail_x1, rail_y + rail_h * 0.58, accent, rrad)
      ImGui.DrawList_AddRectFilledMultiColor(dl, rail_x0 + rrad, rail_y - rail_h * 0.58, rail_x1 - rrad, rail_y + rail_h * 0.58, accent, hfill, hfill, accent)
      ImGui.DrawList_AddRectFilled(dl, rail_x1 - rrad, rail_y - rail_h * 0.58, rail_x1, rail_y + rail_h * 0.58, hfill, rrad)
      ImGui.PopClipRect(ctx)
    else
      ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.58, fill_x, rail_y + rail_h * 0.58, hfill, rrad)
    end
  elseif style_idx == 9 then
    local steps = 12
    local gap = 2
    local block_w = (rail_x1 - rail_x0 - gap * (steps - 1)) / steps
    for i = 1, steps do
      local bx0 = rail_x0 + (i - 1) * (block_w + gap)
      local bx1 = bx0 + block_w
      local col = ((i - 0.5) / steps <= t) and hfill or bg
      ImGui.DrawList_AddRectFilled(dl, bx0, rail_y - rail_h * 0.55, bx1, rail_y + rail_h * 0.55, col, 1)
    end
  elseif style_idx == 8 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.62, rail_x1, rail_y + rail_h * 0.62, 0x0B1220DD, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, rail_y - rail_h * 0.42, rail_x1 - 2, rail_y + rail_h * 0.42, bg, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, rail_y - rail_h * 0.42, fill_x, rail_y + rail_h * 0.42, hfill, rrad)
    if can_rect then
      ImGui.DrawList_AddRect(dl, rail_x0, rail_y - rail_h * 0.62, rail_x1, rail_y + rail_h * 0.62, 0xBBD7FFFF, rrad, 0, 1)
    end
  elseif style_idx == 10 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.58, rail_x1, rail_y + rail_h * 0.58, bg, rail_h * 0.5)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, rail_y - rail_h * 0.38, rail_x1 - 2, rail_y + rail_h * 0.38, 0x00000044, rail_h * 0.38)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, rail_y - rail_h * 0.38, fill_x, rail_y + rail_h * 0.38, hfill, rail_h * 0.38)
    local ticks = 10
    for i = 0, ticks do
      local tx = rail_x0 + (rail_x1 - rail_x0) * (i / ticks)
      local col = tx <= fill_x and hfill or accent
      ImGui.DrawList_AddLine(dl, tx, rail_y - rail_h * 0.16, tx, rail_y + rail_h * 0.16, col, 1)
    end
    ImGui.DrawList_AddLine(dl, rail_x0 + 8, rail_y - rail_h * 0.46, rail_x1 - 8, rail_y - rail_h * 0.46, 0xFFFFFFFF, 1)
  else
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.5, rail_x1, rail_y + rail_h * 0.5, bg, rrad)
    ImGui.DrawList_AddRectFilled(dl, rail_x0, rail_y - rail_h * 0.5, fill_x, rail_y + rail_h * 0.5, hfill, rrad)
  end

  local knob_w = (style_idx == 9) and fs * 0.62 or fs * 0.82
  if stepped_rail then
    knob_w = math.min(fs * 0.82, math.max(fs * 0.42, (stepped_block_w or fs * 0.62) * 0.92))
    ImGui.DrawList_AddRectFilled(dl, fill_x - knob_w * 0.5, rail_y - h_main * 0.42, fill_x + knob_w * 0.5,
      rail_y + h_main * 0.42, knob, 3)
    if can_rect then
      ImGui.DrawList_AddRect(dl, fill_x - knob_w * 0.5, rail_y - h_main * 0.42, fill_x + knob_w * 0.5,
        rail_y + h_main * 0.42, main_active and hfill or accent, 3, 0, 1)
    end
  elseif style_idx == 7 and can_rect then
    local mid_col = interp_color(accent, hfill, t)
    local kw = main_active and fs * 1.18 or fs * 1.02
    ImGui.DrawList_AddRectFilled(dl, fill_x - kw * 0.5, rail_y - kw * 0.5, fill_x + kw * 0.5, rail_y + kw * 0.5, knob, 4)
    ImGui.DrawList_AddRect(dl, fill_x - kw * 0.5, rail_y - kw * 0.5, fill_x + kw * 0.5, rail_y + kw * 0.5, mid_col, 4, 0, 1)
  elseif style_idx == 10 and can_circle then
    ImGui.DrawList_AddCircleFilled(dl, fill_x, rail_y, main_active and fs * 0.72 or fs * 0.62, 0x00000055)
    ImGui.DrawList_AddCircleFilled(dl, fill_x, rail_y, main_active and fs * 0.58 or fs * 0.5, knob)
    ImGui.DrawList_AddCircleFilled(dl, fill_x, rail_y, fs * 0.24, hfill)
  elseif ImGui.DrawList_AddCircleFilled and style_idx ~= 6 and style_idx ~= 9 and not stepped_rail then
    ImGui.DrawList_AddCircleFilled(dl, fill_x, rail_y, main_active and fs * 0.52 or fs * 0.45, knob)
    if style_idx == 1 or style_idx == 5 or style_idx == 8 then
      ImGui.DrawList_AddCircleFilled(dl, fill_x, rail_y, fs * 0.23, hfill)
    end
  else
    ImGui.DrawList_AddRectFilled(dl, fill_x - knob_w * 0.5, rail_y - h_main * 0.42, fill_x + knob_w * 0.5, rail_y + h_main * 0.42, knob, 3)
  end

  if ImGui.DrawList_AddText then
    local pad_top = 1
    value_text = string.format(fmt or "%d", value)
    local tw, th = wx_text_size(ctx, value_text)
    local box_w = math.max(fs * 3.2, tw + readout_pad * 2 + fs * 0.35)
    local box_h = math.max(fs * 1.25, th + readout_pad * 2)
    local bx1 = x + w
    local bx0 = bx1 - box_w
    local extent_up = wx_slider_extent_above_rail(style_idx, rail_h, fs, h_main, main_active, stepped_rail)
    local cap_by1 = (rail_y - extent_up) - readout_gap
    local row_h = math.max(th_l, box_h)
    local row_top = y + pad_top
    local by1 = math.min(row_top + row_h, cap_by1)
    local by0 = by1 - box_h
    if by0 < row_top then
      by0 = row_top
      by1 = math.min(by0 + box_h, cap_by1)
    end
    if by1 <= by0 then
      by1 = by0 + math.max(math.floor(th + 0.5) + 2, 6)
    end
    local box_draw_h = by1 - by0
    local mid_y = by0 + box_draw_h * 0.5
    local label_ty = mid_y - th_l * 0.5 - 1
    ImGui.DrawList_AddText(dl, x, label_ty, main_hover_paint and 0xFFFFFFFF or 0xCFCFCFFF, shown_label)
    
    local text_col = main_active and fill or (main_hover_paint and 0xFFFFFFFF or 0xBBBBBBFF)

    if style_idx == 3 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, 0x1A140CFF, 0)
      if can_rect then ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, ebg, 0, 0, 1) end
      text_col = main_active and fill or accent
    elseif style_idx == 4 or style_idx == 9 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, bg, 0)
      if can_rect then ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, main_hover_paint and accent or fill, 0, 0, (style_idx == 9) and 2 or 1) end
      if style_idx == 9 then text_col = main_active and 0xFFFFFFFF or fill end
    elseif style_idx == 6 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, 0x0A0807FF, 2)
      if can_rect then 
        ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, 0xFFFFFF11, 2, 0, 1)
        ImGui.DrawList_AddLine(dl, bx0 + 1, by0 + 1, bx1 - 1, by0 + 1, 0x000000AA, 1)
      end
      text_col = main_active and fill or knob
    elseif style_idx == 7 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, 0x05050588, 3)
      local mid_col = interp_color(accent, hfill, t)
      if can_rect then
        ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, 0xFFFFFF1A, 3, 0, 1)
        if main_active or main_hover_paint then
          ImGui.DrawList_AddRect(dl, bx0 - 1, by0 - 1, bx1 + 1, by1 + 1, mid_col, 4, 0, 1)
        end
      end
      text_col = main_active and mid_col or (main_hover_paint and 0xFFFFFFFF or 0xBBBBBBFF)
    elseif style_idx == 8 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, bg, box_draw_h * 0.5)
      local fill_back = wx_im_col_alpha_mul(hfill, main_active and 0.38 or 0.22)
      ImGui.DrawList_AddRectFilled(dl, bx0 + 3, by0 + 3, bx1 - 3, by1 - 3, fill_back, math.max(2, (box_draw_h - 6) * 0.5))
    elseif style_idx == 10 then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, bg, box_draw_h * 0.5)
      if can_rect then
        ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, main_hover_paint and fill or accent, box_draw_h * 0.5, 0, 1)
      end
      if style_idx == 10 then text_col = main_active and 0xFFFFFFFF or fill end
    else
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, 0x05050588, 3)
      if can_rect then
        ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, 0xFFFFFF1A, 3, 0, 1)
        if main_active or main_hover_paint then
          ImGui.DrawList_AddRect(dl, bx0 - 1, by0 - 1, bx1 + 1, by1 + 1, main_active and fill or accent, 4, 0, 1)
        end
      end
    end

    -- Theme fill/accent can be very dark; keep numeric readout legible while dragging/hovering.
    if main_active or main_hover_paint then
      text_col = GRIP_LABEL_CLR_HOT
    end

    ImGui.DrawList_AddText(dl, bx0 + readout_pad + (box_w - readout_pad * 2 - tw) * 0.5,
      by0 + readout_pad + (box_draw_h - readout_pad * 2 - th) * 0.5 - 1, text_col, value_text)
  end

  if has_rand then
    local cx = x + w * 0.5
    local ry = y + h_main + h_rand * 0.5
    local r_t = 0
    if rand_max > 0 then
      r_t = clamp_num(rand_value / rand_max, 0, 1)
    end
    local r_span = ((rail_x1 - rail_x0) * 0.5) * r_t
    
    local r_bg = 0x00000033
    local r_fill = hfill
    if rand_hover_paint then r_bg = 0x00000055 end
    
    ImGui.DrawList_AddRectFilled(dl, rail_x0, ry - 2, rail_x1, ry + 2, r_bg, 2)
    ImGui.DrawList_AddRectFilled(dl, cx - r_span, ry - 2, cx + r_span, ry + 2, r_fill, 2)
    
    local dice_size = fs * 0.85
    local dx0 = cx - dice_size * 0.5
    local dy0 = ry - dice_size * 0.5
    local dice_hovered = mx >= dx0 and mx <= dx0 + dice_size and my >= dy0 and my <= dy0 + dice_size
    if dice_hovered and ImGui.IsMouseDoubleClicked and ImGui.IsMouseDoubleClicked(ctx, 0) and rand_value ~= 0 then
      rand_value = 0
      changed_rand = true
    end
    local dice_col = rand_active and fill or (rand_hover_paint and accent or ebg)
    ImGui.DrawList_AddRectFilled(dl, dx0, dy0, dx0 + dice_size, dy0 + dice_size, dice_col, 2)
    local dot_col = rand_active and 0x000000FF or 0xFFFFFFFF
    if ImGui.DrawList_AddCircleFilled then
      ImGui.DrawList_AddCircleFilled(dl, dx0 + dice_size * 0.25, dy0 + dice_size * 0.25, 1.5, dot_col)
      ImGui.DrawList_AddCircleFilled(dl, cx, ry, 1.5, dot_col)
      ImGui.DrawList_AddCircleFilled(dl, dx0 + dice_size * 0.75, dy0 + dice_size * 0.75, 1.5, dot_col)
    end

    if rand_hover_paint then
      if ImGui.SetMouseCursor and ImGui.MouseCursor_ResizeEW then
        ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW)
      end
      if ImGui.SetTooltip then
        ImGui.SetTooltip(ctx, string.format("± %s", string.format(rand_fmt or "%d", rand_value)))
      end
    end
  end

  if main_hover_paint and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx, shown_label .. ": " .. value_text)
  end
  return changed, value, changed_rand, rand_value
end

wx_custom_combo = function(ctx, id, label, current_idx, items_str, width, style_idx, popup_header_fn)
  current_idx = math.floor(tonumber(current_idx) or 0)
  style_idx = math.max(1, math.min(#WX_SLIDER_STYLES, math.floor(tonumber(style_idx) or state.wx_slider_style or 1)))
  local ebg, fill, knob, accent = wx_effective_style_colors(style_idx)
  local shown_label = wx_visible_label(label)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local avail = ml_content_region_avail_x(ctx)
  local requested_w = tonumber(width)
  local w = requested_w and math.min(requested_w, avail) or math.min(fs * 18, avail)
  w = math.max(1, w)
  local h = math.max(26, math.floor(fs * 1.72 + 0.5))
  local x, y = 0, 0
  if ImGui.GetCursorScreenPos then x, y = ImGui.GetCursorScreenPos(ctx) end

  local items = split_sep(items_str, "\0")
  if #items > 0 and items[#items] == "" then table.remove(items) end

  if not (ImGui.InvisibleButton and ImGui.GetWindowDrawList and ImGui.DrawList_AddRectFilled) then
    if ImGui.PushItemWidth then ImGui.PushItemWidth(ctx, w) end
    local rv, out = ImGui.Combo(ctx, label .. id, current_idx, items_str)
    if ImGui.PopItemWidth then ImGui.PopItemWidth(ctx) end
    return rv, out
  end

  ImGui.InvisibleButton(ctx, id, w, h)
  local rx0, ry0, rx1, ry1 = x, y, x + w, y + h
  if ImGui.GetItemRectMin then
    local ix0, iy0 = ImGui.GetItemRectMin(ctx)
    if ix0 then
      rx0, ry0 = ix0, iy0
    end
  end
  if ImGui.GetItemRectMax then
    local ix1, iy1 = ImGui.GetItemRectMax(ctx)
    if ix1 then
      rx1, ry1 = ix1, iy1
    end
  end
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive and ImGui.IsItemActive(ctx)

  if hovered and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, 0) then
    ImGui.OpenPopup(ctx, id .. "_popup")
  end

  local cur_raw = items[current_idx + 1] or ""
  local cur_text = trim(tostring(cur_raw or ""))
  if cur_text == "" then
    cur_text = "—"
  end
  local line_text = shown_label ~= "" and (shown_label .. ": " .. cur_text) or cur_text

  local dl = ImGui.GetWindowDrawList(ctx)
  local rail_x0, rail_x1 = x + fs * 0.45, x + w - fs * 0.45
  local pad_y = fs * 0.18
  local top = y + pad_y
  local bot = y + h - pad_y
  local mid_y = (top + bot) * 0.5
  local body_h = bot - top
  local rrad_c = (style_idx == 4 or style_idx == 9) and 2 or math.max(3, math.floor(body_h * 0.28))
  local rail_h = body_h * 0.5

  local bg = hovered and accent or ebg
  local can_rect = ImGui.DrawList_AddRect ~= nil

  if style_idx == 1 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, rrad_c)
    ImGui.DrawList_AddLine(dl, rail_x0 + 4, top + body_h * 0.28, rail_x1 - 4, top + body_h * 0.28, 0xFFFFFF22, 1)
    ImGui.DrawList_AddLine(dl, rail_x0 + 4, bot - body_h * 0.22, rail_x1 - 4, bot - body_h * 0.22, accent, 1)
  elseif style_idx == 2 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, rrad_c)
    ImGui.DrawList_AddRectFilled(dl, rail_x0, mid_y - body_h * 0.12, rail_x1, mid_y + body_h * 0.12, 0x00000033, rrad_c)
  elseif style_idx == 3 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, 3)
  elseif style_idx == 4 then
    ImGui.DrawList_AddLine(dl, rail_x0, mid_y, rail_x1, mid_y, bg, 2)
  elseif style_idx == 5 then
    ImGui.DrawList_AddLine(dl, rail_x0, mid_y - rail_h * 0.28, rail_x1, mid_y - rail_h * 0.28, bg, 3)
    ImGui.DrawList_AddLine(dl, rail_x0, mid_y + rail_h * 0.28, rail_x1, mid_y + rail_h * 0.28, accent, 2)
  elseif style_idx == 6 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, 3)
    if can_rect then
      ImGui.DrawList_AddRect(dl, rail_x0, top, rail_x1, bot, accent, 3, 0, 1)
    end
  elseif style_idx == 7 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, rrad_c)
  elseif style_idx == 8 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, 0x0B1220DD, rrad_c)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, top + 2, rail_x1 - 2, bot - 2, bg, math.max(2, rrad_c - 2))
    if can_rect then
      ImGui.DrawList_AddRect(dl, rail_x0, top, rail_x1, bot, 0xBBD7FFFF, rrad_c, 0, 1)
    end
  elseif style_idx == 9 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, 1)
  elseif style_idx == 10 then
    ImGui.DrawList_AddRectFilled(dl, rail_x0, top, rail_x1, bot, bg, body_h * 0.45)
    ImGui.DrawList_AddRectFilled(dl, rail_x0 + 2, top + 3, rail_x1 - 2, bot - 3, 0x00000044, body_h * 0.35)
  end

  local text_col = active and fill or (hovered and 0xFFFFFFFF or 0xDCDCDCFF)
  if style_idx == 3 then
    text_col = active and fill or accent
  elseif style_idx == 6 then
    text_col = active and fill or knob
  elseif style_idx == 10 then
    text_col = active and 0xFFFFFFFF or fill
  end

  local tw, th = wx_text_size(ctx, line_text)
  local tri_reserve = fs * 1.35
  local tx0 = rail_x0 + fs * 0.55
  local tx1 = rail_x1 - tri_reserve
  local ty = mid_y - th * 0.5 - 1
  local clip_ok = ImGui.PushClipRect and ImGui.PopClipRect
  if clip_ok then
    ImGui.PushClipRect(ctx, tx0, top, tx1, bot, true)
  end
  if ImGui.DrawList_AddText then
    ImGui.DrawList_AddText(dl, tx0, ty, text_col, line_text)
  end
  if clip_ok then
    ImGui.PopClipRect(ctx)
  end

  local tri_x = rail_x1 - fs * 0.65
  local ts = fs * 0.28
  if ImGui.DrawList_AddTriangleFilled then
    ImGui.DrawList_AddTriangleFilled(dl, tri_x - ts, mid_y - ts * 0.35, tri_x + ts, mid_y - ts * 0.35, tri_x, mid_y + ts * 0.65, text_col)
  end

  local changed = false
  local popup_id = id .. "_popup"
  local popup_flags = 0
  if ImGui.WindowFlags_NoMove then
    popup_flags = popup_flags | ImGui.WindowFlags_NoMove
  end
  if ImGui.WindowFlags_AlwaysAutoResize then
    popup_flags = popup_flags | ImGui.WindowFlags_AlwaysAutoResize
  end
  if ImGui.WindowFlags_NoTitleBar then
    popup_flags = popup_flags | ImGui.WindowFlags_NoTitleBar
  end

  local cond_anchor = ImGui.Cond_Always or ImGui.Cond_Appearing or 0
  local pw = w
  local px, py = rx0, ry1 + 2
  local anchor_combo = true
  if ImGui.IsPopupOpen then
    local ok_po, open_po = pcall(ImGui.IsPopupOpen, ctx, popup_id)
    if ok_po then
      anchor_combo = open_po
    end
  end
  if anchor_combo and ImGui.SetNextWindowPos and ImGui.SetNextWindowSize then
    local gap = 2
    local row_h_est = math.floor(fs * 1.38 + 10)
    local header_extra = 0
    if popup_header_fn then
      header_extra = row_h_est * 4 + 28
    end
    local est_h = math.min(math.max(#items, 1), 24) * row_h_est + 14 + header_extra
    local margin = 8
    local place_below = true
    local wx, wy, ws_w, ws_h = nil, nil, nil, nil
    if ImGui.GetMainViewport and ImGui.Viewport_GetWorkPos and ImGui.Viewport_GetWorkSize then
      local vp = ImGui.GetMainViewport(ctx)
      if vp then
        wx, wy = ImGui.Viewport_GetWorkPos(vp)
        ws_w, ws_h = ImGui.Viewport_GetWorkSize(vp)
      end
    end
    if wx ~= nil and wy ~= nil and ws_w ~= nil and ws_h ~= nil then
      local v_top = wy + margin
      local v_bot = wy + ws_h - margin
      local space_below = v_bot - ry1 - gap
      local space_above = ry0 - v_top - gap
      if est_h > space_below and space_above > space_below then
        place_below = false
      end
      if place_below then
        px, py = rx0, ry1 + gap
      else
        py = ry0 - gap - est_h
        if py < v_top then
          py = v_top
        end
        px = rx0
      end
      pw = math.min(w, math.max(fs * 10, ws_w - margin * 2 - math.max(0, px - wx)))
    else
      px, py = rx0, ry1 + gap
    end
    ImGui.SetNextWindowPos(ctx, px, py, cond_anchor)
    ImGui.SetNextWindowSize(ctx, pw, 0, cond_anchor)
  end

  local begin_pop = false
  if ImGui.BeginPopup then
    if popup_flags ~= 0 then
      begin_pop = ImGui.BeginPopup(ctx, popup_id, popup_flags)
    else
      begin_pop = ImGui.BeginPopup(ctx, popup_id)
    end
  end

  local n_style_pop = 0
  if begin_pop then
    if ImGui.PushStyleColor then
      if ImGui.Col_PopupBg then
        ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, wx_im_col_alpha_set(ebg, 252))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_Border then
        ImGui.PushStyleColor(ctx, ImGui.Col_Border, wx_im_col_alpha_mul(accent, 0.65))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_Text then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_Header then
        ImGui.PushStyleColor(ctx, ImGui.Col_Header, wx_im_col_alpha_mul(accent, 0.88))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_HeaderHovered then
        ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, wx_im_col_alpha_mul(accent, 0.68))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_HeaderActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, wx_im_col_alpha_mul(fill, 0.95))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_NavHighlight then
        ImGui.PushStyleColor(ctx, ImGui.Col_NavHighlight, wx_im_col_alpha_mul(fill, 0.78))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_Separator then
        ImGui.PushStyleColor(ctx, ImGui.Col_Separator, wx_im_col_alpha_mul(accent, 0.42))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_FrameBgHovered then
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, wx_im_col_alpha_mul(accent, 0.22))
        n_style_pop = n_style_pop + 1
      end
      if ImGui.Col_FrameBgActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, wx_im_col_alpha_mul(accent, 0.38))
        n_style_pop = n_style_pop + 1
      end
    end

    local inner_w = math.max(pw - fs * 0.75, fs * 6)
    if ImGui.GetContentRegionAvail then
      local aw1, aw2 = ImGui.GetContentRegionAvail(ctx)
      local cr_w = tonumber(aw1)
      if cr_w and cr_w > fs then
        inner_w = cr_w
      end
    end
    local row_h = math.floor(fs * 1.28 + 6)
    local sel_flags = ImGui.SelectableFlags_None or 0

    if popup_header_fn then
      popup_header_fn(ctx, inner_w, pw, fs, style_idx)
    end

    for i, item_str in ipairs(items) do
      ImGui.PushID(ctx, tostring(id) .. "_wxcb_" .. tostring(i))
      local disp = trim(tostring(item_str or ""))
      if disp == "" then
        disp = "(empty)"
      end
      local clicked = false
      if ImGui.Selectable then
        local ok_sc, r1 = pcall(ImGui.Selectable, ctx, disp, current_idx == (i - 1), sel_flags, inner_w, row_h)
        if ok_sc then
          clicked = r1 and true or false
        else
          clicked = ImGui.Selectable(ctx, disp, current_idx == (i - 1))
        end
      end
      if clicked then
        current_idx = i - 1
        changed = true
      end
      ImGui.PopID(ctx)
    end

    while n_style_pop > 0 and ImGui.PopStyleColor do
      ImGui.PopStyleColor(ctx)
      n_style_pop = n_style_pop - 1
    end
    ImGui.EndPopup(ctx)
  end

  if hovered and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx, line_text)
  end

  return changed, current_idx
end

function wx_slider_style_gallery_ui(ctx)
  separator_text(ctx, "Sliders, combos & buttons")
  ImGui.TextColored(ctx, 0x888888FF,
    "Preview each look below. First swatch is base/style color; second swatch is highlight fill for slider value, +/- random range, and word-grid highlights. Use this saves the style globally.")
  local cols = 2
  local table_open = ImGui.BeginTable and ImGui.BeginTable(ctx, "##wx_slider_style_gallery", cols)
  if table_open then
    if ImGui.TableSetupColumn then
      ImGui.TableSetupColumn(ctx, "Left")
      ImGui.TableSetupColumn(ctx, "Right")
    end
  end
  for i = 1, #WX_SLIDER_STYLES do
    if table_open then
      if (i % cols) == 1 then
        ImGui.TableNextRow(ctx)
      end
      ImGui.TableNextColumn(ctx)
    end
    ImGui.PushID(ctx, 900000 + i)
    local selected = (state.wx_slider_style == i)
    local title = string.format("Style %d: %s%s", i, WX_SLIDER_STYLES[i].name, selected and "  [selected]" or "")
    if selected then
      ImGui.TextColored(ctx, 0x8FD18CFF, title)
    else
      ImGui.Text(ctx, title)
    end
    local rv, demo = wx_custom_slider_int(ctx, "##demo_slider", "Demo", state.wx_slider_demo_value or 42, 0, 100, "%d%%", 240, i)
    if rv then
      state.wx_slider_demo_value = demo
      r.SetExtState(SECTION, "WX_SLIDER_DEMO_VALUE", tostring(demo), true)
    end
    local rv_st, st_demo = wx_custom_slider_int(ctx, "##demo_step" .. i, "Low-range (stepped)", state.wx_slider_demo_step_value or 2, 0, 5, "%d", 220, i, nil, nil, nil, true)
    if rv_st then
      state.wx_slider_demo_step_value = st_demo
    end
    
    local demo_btn_clicked = wx_custom_button(ctx, "Button demo##btn_demo", 120, 0, i)
    if demo_btn_clicked then
      state.wx_slider_demo_button_style = i
    end
    ImGui.SameLine(ctx, 0, 8)
    local cust_c = (state.wx_slider_colors and state.wx_slider_colors[i]) or WX_SLIDER_STYLES[i].fill
    if ImGui.ColorEdit4 then
      local flags = 32 | 128 | 1048576 -- NoInputs, NoLabel, AlphaPreview
      local rv_c, new_c = ImGui.ColorEdit4(ctx, "##clr" .. i, cust_c, flags)
      if rv_c then
        if not state.wx_slider_colors then state.wx_slider_colors = {} end
        state.wx_slider_colors[i] = new_c
        r.SetExtState(SECTION, "WX_SLIDER_C" .. tostring(i), tostring(new_c), true)
      end
      if ImGui.SetItemTooltip then
        ImGui.SetItemTooltip(ctx, "Base/style color")
      end
      ImGui.SameLine(ctx, 0, 4)
      local hi_c = (state.wx_slider_highlight_colors and state.wx_slider_highlight_colors[i])
        or (state.wx_slider_colors and state.wx_slider_colors[i])
        or WX_SLIDER_STYLES[i].fill
      local rv_hc, new_hc = ImGui.ColorEdit4(ctx, "##hclr" .. i, hi_c, flags)
      if rv_hc then
        if not state.wx_slider_highlight_colors then state.wx_slider_highlight_colors = {} end
        state.wx_slider_highlight_colors[i] = new_hc
        r.SetExtState(SECTION, "WX_SLIDER_HC" .. tostring(i), tostring(new_hc), true)
      end
      if ImGui.SetItemTooltip then
        ImGui.SetItemTooltip(ctx, "Highlight color: slider value fill and +/- random range")
      end
    end

    ImGui.SameLine(ctx, 0, 8)
    local choose_clicked
    choose_clicked = wx_custom_small_button(ctx, selected and "Selected" or "Use this", i)
    if choose_clicked then
      state.wx_slider_style = i
      r.SetExtState(SECTION, "WX_SLIDER_STYLE", tostring(i), true)
      state.status = "UI style " .. tostring(i) .. " — " .. WX_SLIDER_STYLES[i].name .. " (all sliders, combos & buttons)"
      state.status_err = false
    end

    local combo_items = "First Choice\0Second Option\0Third Item\0\0"
    if not state.wx_slider_demo_combo then state.wx_slider_demo_combo = {} end
    local rv_cb, cbo = wx_custom_combo(ctx, "##demo_combo" .. i, "##preset", state.wx_slider_demo_combo[i] or 0, combo_items, 240, i)
    if rv_cb then state.wx_slider_demo_combo[i] = cbo end
    ImGui.PopID(ctx)
    if not table_open then
      ImGui.Spacing(ctx)
    end
  end
  if table_open then
    ImGui.EndTable(ctx)
  end
end

function wx_draw_hint_row_with_gear(ctx, hint)
  hint = tostring(hint or "")
  wx_bridge_icons_try_load(ctx)
  local fs_top = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local gear_sz = math.max(26, math.floor(fs_top * 2 + 0.5))
  if ImGui.BeginTable and ImGui.TableSetupColumn then
    local tbl_flags = 0
    if ImGui.TableFlags_SizingStretchProp then
      tbl_flags = tbl_flags | ImGui.TableFlags_SizingStretchProp
    end
    if ImGui.TableFlags_NoPadOuterX then
      tbl_flags = tbl_flags | ImGui.TableFlags_NoPadOuterX
    end
    if ImGui.BeginTable(ctx, "##wx_hint_gear_row", 2, tbl_flags) then
      local c_stretch = ImGui.TableColumnFlags_WidthStretch or 0
      local c_fix = ImGui.TableColumnFlags_WidthFixed or 0
      ImGui.TableSetupColumn(ctx, "hint", c_stretch)
      ImGui.TableSetupColumn(ctx, "gear", c_fix, gear_sz + 6)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      if hint ~= "" then
        ImGui.TextWrapped(ctx, hint)
      end
      ImGui.TableNextColumn(ctx)
      if ImGui.AlignTextToFramePadding then
        ImGui.AlignTextToFramePadding(ctx)
      end
      local gear_clicked = false
      if wx_bridge_icon_images.settings then
        gear_clicked = wx_bridge_image_button(ctx, "##wx_open_settings_img", wx_bridge_icon_images.settings, gear_sz, 0xFFFFFFFF)
      elseif wx_custom_button(ctx, "⚙##wx_open_settings", gear_sz, gear_sz, state.wx_slider_style) then
        gear_clicked = true
      end
      if gear_clicked then
        state.wx_settings_open = true
      end
      if ImGui.SetItemTooltip then
        ImGui.SetItemTooltip(ctx, "Appearance settings — sliders & combos")
      elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Appearance settings — sliders & combos")
      end
      ImGui.EndTable(ctx)
    end
  else
    if hint ~= "" then
      ImGui.TextWrapped(ctx, hint)
    end
    local gear_clicked_fb = false
    if wx_bridge_icon_images.settings then
      gear_clicked_fb = wx_bridge_image_button(ctx, "##wx_open_settings_img_fb", wx_bridge_icon_images.settings, gear_sz, 0xFFFFFFFF)
    elseif wx_custom_button(ctx, "Appearance…##wx_open_settings_fb", 0, 0, state.wx_slider_style) then
      gear_clicked_fb = true
    end
    if gear_clicked_fb then
      state.wx_settings_open = true
    end
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, "Appearance settings — sliders & combos")
    elseif ImGui.SetTooltip and ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Appearance settings — sliders & combos")
    end
  end
end

function wx_draw_settings_modal(ctx)
  local pid = "Appearance###wx_settings_modal"
  if state.wx_settings_open then
    state.wx_settings_open = false
    if ImGui.OpenPopup then
      ImGui.OpenPopup(ctx, pid)
    end
  end

  local cond = (ImGui.Cond_Appearing or ImGui.Cond_FirstUseEver or 0)
  if ImGui.SetNextWindowSize then
    ImGui.SetNextWindowSize(ctx, 740, 640, cond)
  end
  local wflags = 0
  if ImGui.WindowFlags_AlwaysVerticalScrollbar then
    wflags = wflags | ImGui.WindowFlags_AlwaysVerticalScrollbar
  end

  local opened = false
  if ImGui.BeginPopupModal then
    opened = ImGui.BeginPopupModal(ctx, pid, nil, wflags)
    if not opened and wflags ~= 0 then
      opened = ImGui.BeginPopupModal(ctx, pid, nil, 0)
    end
  end
  if not opened and ImGui.BeginPopup then
    if wflags ~= 0 then
      opened = ImGui.BeginPopup(ctx, pid, wflags)
    else
      opened = ImGui.BeginPopup(ctx, pid)
    end
  end

  if opened then
    wx_slider_style_gallery_ui(ctx)
    ImGui.Spacing(ctx)
    if wx_custom_button(ctx, "Close##wx_settings_close", 140, 0, state.wx_slider_style) then
      if ImGui.CloseCurrentPopup then
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

function anim_type_uses_motion(typ)
  typ = math.floor(tonumber(typ) or 0)
  return (typ > ANIM_TYPE_MAX or typ == ANIM_KIND.CUSTOM)
    or typ == ANIM_KIND.SLIDE_LEFT
    or typ == ANIM_KIND.SLIDE_RIGHT
    or typ == ANIM_KIND.SLIDE_UP
    or typ == ANIM_KIND.SLIDE_DOWN
    or typ == ANIM_KIND.WHIP_LEFT
    or typ == ANIM_KIND.WHIP_RIGHT
    or typ == ANIM_KIND.SQUASH
    or typ == ANIM_KIND.STRETCH
    or typ == ANIM_KIND.DROP_BOUNCE
    or typ == ANIM_KIND.RISE_BOUNCE
    or typ == ANIM_KIND.DRIFT_LEFT
    or typ == ANIM_KIND.DRIFT_RIGHT
    or typ == ANIM_KIND.SHAKE
    or typ == ANIM_KIND.JITTER
    or typ == ANIM_KIND.WAVE
    or typ == ANIM_KIND.ORBIT
    or typ == ANIM_KIND.SPIRAL
    or typ == ANIM_KIND.ECHO_TRAIL
    or typ == ANIM_KIND.CLONE_BURST
end

function anim_type_uses_wiggle(typ)
  typ = math.floor(tonumber(typ) or 0)
  return (typ > ANIM_TYPE_MAX or typ == ANIM_KIND.CUSTOM)
    or typ == ANIM_KIND.PUNCH
    or typ == ANIM_KIND.DROP_BOUNCE
    or typ == ANIM_KIND.RISE_BOUNCE
    or typ == ANIM_KIND.DRIFT_LEFT
    or typ == ANIM_KIND.DRIFT_RIGHT
    or typ == ANIM_KIND.SHAKE
    or typ == ANIM_KIND.JITTER
    or typ == ANIM_KIND.WAVE
    or typ == ANIM_KIND.ORBIT
    or typ == ANIM_KIND.SPIRAL
    or typ == ANIM_KIND.ECHO_TRAIL
    or typ == ANIM_KIND.CLONE_BURST
end

function anim_type_uses_duplicates(typ)
  typ = math.floor(tonumber(typ) or 0)
  if typ == ANIM_KIND.WIPE_REVEAL then
    return false
  end
  return typ == ANIM_KIND.ECHO_TRAIL or typ == ANIM_KIND.CLONE_BURST or typ > ANIM_TYPE_MAX or typ == ANIM_KIND.CUSTOM
end

function anim_type_uses_blur(typ)
  typ = math.floor(tonumber(typ) or 0)
  return typ > ANIM_TYPE_MAX or typ == ANIM_KIND.CUSTOM or typ == ANIM_KIND.BLUR
end

function anim_uses_bounce(typ, curve)
  typ = math.floor(tonumber(typ) or 0)
  curve = math.floor(tonumber(curve) or 0)
  if typ <= 0 then
    return false
  end
  return typ > ANIM_TYPE_MAX
    or typ == ANIM_KIND.CUSTOM
    or typ == ANIM_KIND.DROP_BOUNCE
    or typ == ANIM_KIND.RISE_BOUNCE
    or curve == ANIM_CURVE_BACK
    or curve == ANIM_CURVE_ELASTIC
end

function anim_pct_slider(ctx, key, label, val, max_pct, width_chars)
  local pct = math.floor((tonumber(val) or 1) * 100 + 0.5)
  local rv, pct2 = wx_custom_slider_int(ctx, key, label, pct, 0, max_pct or 300, "%d%%", anim_combo_w(ctx, width_chars or 11, 104), state.wx_slider_style)
  if rv then
    return true, math.max(0, math.min((max_pct or 300) / 100, (pct2 or pct) / 100))
  end
  return false, val
end

function anim_signed_pct_slider(ctx, key, label, val, min_pct, max_pct, width_chars)
  local pct = math.floor((tonumber(val) or 0) * 100 + 0.5)
  local rv, pct2 = wx_custom_slider_int(ctx, key, label, pct, min_pct or -100, max_pct or 200, "%d%%", anim_combo_w(ctx, width_chars or 11, 104), state.wx_slider_style)
  if rv then
    return true, math.max((min_pct or -100) / 100, math.min((max_pct or 200) / 100, (pct2 or pct) / 100))
  end
  return false, val
end

function anim_graph_find_side_label(side_key)
  if side_key == "in" then return "Entry" end
  if side_key == "out" then return "Exit" end
  if side_key == "phrase_out" then return "Phrase exit" end
  return "Animation"
end

function anim_graph_open_editor(side_key)
  side_key = side_key or "in"
  local key = anim_graph_side_blob_key(side_key)
  local pts, curves, blends = anim_graph_decode_blob(state[key] or anim_graph_default_blob())
  state.anim_graph_editor_side_key = side_key
  state.anim_graph_editor_points = pts
  state.anim_graph_editor_curves = curves
  state.anim_graph_editor_blends = blends
  state.anim_graph_seg_mode1_bias0 = nil
  state.anim_graph_editor_selected = math.max(1, math.min(#pts, state.anim_graph_editor_selected or 1))
  state.anim_graph_editor_drag_point = nil
  state.anim_graph_editor_drag_t = nil
  state.anim_graph_editor_popup_seg = nil
  state.anim_graph_editor_seg_drag_seg = nil
  state.anim_graph_editor_lane_seg_lane = ""
  state.anim_graph_editor_lane_seg_idx = nil
  state.anim_graph_editor_preview_u = 0
  state.anim_graph_editor_preview_clock = r.time_precise and r.time_precise() or 0
  state.anim_graph_editor_open = true
end

function anim_graph_apply_editor_to_state()
  local side_key = state.anim_graph_editor_side_key or "in"
  local key = anim_graph_side_blob_key(side_key)
  local pts = state.anim_graph_editor_points
  local curves = state.anim_graph_editor_curves
  if type(pts) ~= "table" or #pts < 2 then
    return false
  end
  local blob = anim_graph_encode_blob(pts, curves, state.anim_graph_editor_blends)
  if blob ~= (state[key] or "") then
    state[key] = blob
    return true
  end
  return false
end

function anim_graph_curve_name(idx)
  local names = { "Linear", "In Quad", "Out Quad", "InOut Quad", "Square", "In Log", "In Exp" }
  return names[math.max(1, math.min(#names, math.floor(tonumber(idx) or 0) + 1))]
end

function anim_graph_curve_apply(curve_id, u)
  curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  u = math.max(0, math.min(1, tonumber(u) or 0))
  if curve_id == 1 then
    return u * u
  end
  if curve_id == 2 then
    return 1 - (1 - u) * (1 - u)
  end
  if curve_id == 3 then
    if u < 0.5 then
      return 2 * u * u
    end
    local k = (2 - 2 * u)
    return 1 - (k * k) * 0.5
  end
  if curve_id == ANIM_GRAPH_CURVE_SQUARE then
    return (u < 1) and 0 or 1
  end
  if curve_id == ANIM_GRAPH_CURVE_IN_LOG then
    return math.log(1 + ANIM_GRAPH_LOG_K * u) / math.log(ANIM_GRAPH_LOG_K + 1)
  end
  if curve_id == ANIM_GRAPH_CURVE_IN_EXP then
    if u <= 0 then
      return 0
    end
    if u >= 1 then
      return 1
    end
    local den = math.exp(ANIM_GRAPH_EXP_A) - 1
    return (math.exp(ANIM_GRAPH_EXP_A * u) - 1) / den
  end
  return u
end

function anim_graph_curve_mode1_blend(u, b)
  u = math.max(0, math.min(1, tonumber(u) or 0))
  b = math.max(-1, math.min(1, tonumber(b) or 0))
  local yl = anim_graph_curve_apply(ANIM_GRAPH_CURVE_IN_LOG, u)
  local ym = u
  local yr = anim_graph_curve_apply(ANIM_GRAPH_CURVE_IN_EXP, u)
  local sn = (b <= 0) and math.min(1, -b) or 0
  local sp = (b >= 0) and math.min(1, b) or 0
  local function smooth01(s)
    s = math.max(0, math.min(1, s))
    return s * s * (3 - 2 * s)
  end
  local w_log = smooth01(sn)
  local w_exp = smooth01(sp)
  local w_lin = 1 - w_log - w_exp
  if w_lin < 0 then
    w_lin = 0
  end
  return w_log * yl + w_lin * ym + w_exp * yr
end

function anim_graph_curve_ease_at(curve_id, u, blend_bias)
  curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  u = math.max(0, math.min(1, tonumber(u) or 0))
  -- Linear / In Log / In Exp share one signed dial (In Log ↔ linear ↔ In Exp). Other types: linear ↔ chosen ease with [0,1] |b|.
  if anim_graph_curve_is_mode1_family(curve_id) and type(blend_bias) == "number" then
    return anim_graph_curve_mode1_blend(u, math.max(-1, math.min(1, blend_bias)))
  end
  if type(blend_bias) ~= "number" then
    return anim_graph_curve_apply(curve_id, u)
  end
  local b = tonumber(blend_bias) or 0
  local sm = math.max(0, math.min(1, math.abs(b)))
  local ylin = u
  local yc = anim_graph_curve_apply(curve_id, u)
  return ylin + (yc - ylin) * sm
end

--- Path sample at timeline u in [0,1]; matches easing used in Video Processor custom graph (see core `append_anim_graph_path_eel`).
function anim_graph_eval_path_xy(pts, curves, blends, u)
  u = math.max(0, math.min(1, tonumber(u) or 0))
  if type(pts) ~= "table" or #pts < 2 then
    return 0, 0
  end
  if u <= (pts[1].t or 0) then
    return pts[1].x or 0, pts[1].y or 0
  end
  local last = pts[#pts]
  if u >= (last.t or 1) then
    return last.x or 0, last.y or 0
  end
  for i = 1, #pts - 1 do
    local p0, p1 = pts[i], pts[i + 1]
    local t0 = math.max(0, math.min(1, tonumber(p0.t) or 0))
    local t1 = math.max(0, math.min(1, tonumber(p1.t) or 1))
    local dt = math.max(1e-9, t1 - t0)
    local last_seg = i == (#pts - 1)
    local in_seg = last_seg and (u >= t0 and u <= t1) or (u >= t0 and u < t1)
    if in_seg then
      local gu = math.max(0, math.min(1, (u - t0) / dt))
      local curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curves and curves[i]) or 0)))
      local bb = blends and blends[i]
      local eased = anim_graph_curve_ease_at(curve_id, gu, type(bb) == "number" and bb or nil)
      local x0, y0 = tonumber(p0.x) or 0, tonumber(p0.y) or 0
      local x1, y1 = tonumber(p1.x) or 0, tonumber(p1.y) or 0
      return x0 + (x1 - x0) * eased, y0 + (y1 - y0) * eased
    end
  end
  return tonumber(last.x) or 0, tonumber(last.y) or 0
end

--- Concentric circles at current path preview point (Midi CurveEditor–style glow).
function anim_graph_draw_path_preview_glow(dl, cx, cy)
  if not dl then
    return
  end
  local hot = wx_active_style_accent_rgba() or 0xff9660ff
  local dim = interp_color(hot, 0x00000008, 0.55)
  if not ImGui.DrawList_AddCircle then
    if ImGui.DrawList_AddCircleFilled then
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, 5, interp_color(hot, dim, 0.65))
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, 2.4, hot)
    end
    return
  end
  for i = 10, 1, -1 do
    local t = i / 10
    ImGui.DrawList_AddCircle(dl, cx, cy, i, interp_color(hot, dim, (1 - t) * 0.92))
  end
  if ImGui.DrawList_AddCircleFilled then
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, 2.4, hot)
  end
end

function anim_graph_curve_is_mode1_family(curve_id)
  local cid = math.floor(tonumber(curve_id) or 0)
  return cid == 0 or cid == ANIM_GRAPH_CURVE_IN_LOG or cid == ANIM_GRAPH_CURVE_IN_EXP
end

--- Initial blend for vertical segment drag: mode1 trio (linear / in log / in exp) uses signed [-1,1]; other curve types stay [0,1].
function anim_graph_seg_drag_start_blend(blends, curves, si)
  local cid = math.floor(tonumber(curves and curves[si]) or 0)
  local b = blends and blends[si]
  if anim_graph_curve_is_mode1_family(cid) then
    if type(b) == "number" then
      return math.max(-1, math.min(1, b))
    end
    if cid == ANIM_GRAPH_CURVE_IN_LOG then
      return -1
    end
    if cid == ANIM_GRAPH_CURVE_IN_EXP then
      return 1
    end
    return 0
  end
  if type(b) == "number" then
    return math.max(0, math.min(1, math.abs(b)))
  end
  return 1
end

function anim_graph_blends_on_point_insert(blends, k, old_pt_count)
  blends = blends or {}
  local nb = {}
  for i = 1, k - 2 do
    nb[i] = blends[i]
  end
  local spl = blends[k - 1]
  nb[k - 1] = spl
  nb[k] = spl
  for m = k + 1, old_pt_count do
    nb[m] = blends[m - 1]
  end
  return nb
end

function anim_graph_blends_on_point_remove(blends, k, old_pt_count)
  blends = blends or {}
  local n = old_pt_count
  local nb = {}
  for i = 1, k - 2 do
    nb[i] = blends[i]
  end
  nb[k - 1] = nil
  for i = k, n - 2 do
    nb[i] = blends[i + 1]
  end
  return nb
end

function anim_draw_curve_segment(dl, ax, ay, bx, by, curve_id, col, thick, blend_bias)
  if not (dl and ImGui.DrawList_AddLine) then
    return
  end
  local curve = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  if curve == ANIM_GRAPH_CURVE_SQUARE then
    ImGui.DrawList_AddLine(dl, ax, ay, bx, ay, col, thick or 1)
    ImGui.DrawList_AddLine(dl, bx, ay, bx, by, col, thick or 1)
    return
  end
  local prev_x, prev_y = ax, ay
  local steps = 22
  for s = 1, steps do
    local u = s / steps
    local e = anim_graph_curve_ease_at(curve, u, blend_bias)
    local x = ax + (bx - ax) * u
    local y = ay + (by - ay) * e
    ImGui.DrawList_AddLine(dl, prev_x, prev_y, x, y, col, thick or 1)
    prev_x, prev_y = x, y
  end
end

--- Binary search: eased value e(u) vs linear chord (path editor). Monotone 0→1 for all graph curve kinds we use.
function anim_graph_inverse_ease_u(curve_id, target_e, blend_bias)
  curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  local v = math.max(0, math.min(1, tonumber(target_e) or 0))
  local function e_at(uu)
    return anim_graph_curve_ease_at(curve_id, uu, blend_bias)
  end
  if v <= 1e-9 then
    return 0
  end
  if v >= 1 - 1e-9 then
    return 1
  end
  local lo, hi = 0, 1
  for _ = 1, 20 do
    local mid = (lo + hi) * 0.5
    if e_at(mid) < v then
      lo = mid
    else
      hi = mid
    end
  end
  return (lo + hi) * 0.5
end

local function anim_graph_draw_arrowhead(dl, cx, cy, dx, dy, col, ah, hw, thick)
  if not (dl and ImGui.DrawList_AddLine) then
    return
  end
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-9 then
    return
  end
  dx, dy = dx / len, dy / len
  ah = tonumber(ah) or 4
  hw = tonumber(hw) or 2.2
  thick = tonumber(thick) or 1.1
  local ex, ey = cx + dx * ah, cy + dy * ah
  local px, py = -dy, dx
  ImGui.DrawList_AddLine(dl, cx, cy, ex, ey, col, thick)
  ImGui.DrawList_AddLine(dl, ex, ey, ex - dx * ah + px * hw, ey - dy * ah + py * hw, col, thick)
  ImGui.DrawList_AddLine(dl, ex, ey, ex - dx * ah - px * hw, ey - dy * ah - py * hw, col, thick)
end

--- Path editor only: many flow arrows along the eased curve; spacing in equal eased-value steps (in-log → sparse early, dense late).
function anim_draw_path_segment_flow_arrows(dl, ax, ay, bx, by, curve_id, col, blend_bias)
  if not (dl and ImGui.DrawList_AddLine) then
    return
  end
  curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  local legx, legy = bx - ax, by - ay
  local chord = math.sqrt(legx * legx + legy * legy)
  if chord < 2 then
    return
  end
  local num = math.max(26, math.min(78, math.floor(chord / 4.2 + 18.5)))
  local ah, hw, thick = 3.6, 2.1, 1.05
  local du = 1 / 128

  if curve_id == ANIM_GRAPH_CURVE_SQUARE then
    local L1 = math.abs(legx)
    local L2 = math.abs(legy)
    local L = L1 + L2
    if L < 1e-6 then
      return
    end
    local sx = legx >= 0 and 1 or -1
    local sy = legy >= 0 and 1 or -1
    for k = 1, num do
      local d = (k / (num + 1)) * L
      local qx, qy, tx, ty
      if L1 <= 1e-9 then
        qx, qy = ax, ay + sy * d
        tx, ty = 0, sy
      elseif L2 <= 1e-9 then
        qx, qy = ax + sx * d, ay
        tx, ty = sx, 0
      elseif d <= L1 then
        qx, qy = ax + sx * d, ay
        tx, ty = sx, 0
      else
        qx, qy = bx, ay + sy * (d - L1)
        tx, ty = 0, sy
      end
      anim_graph_draw_arrowhead(dl, qx, qy, tx, ty, col, ah * 1.1, hw, thick)
    end
    return
  end

  local function smooth_pt(uu)
    uu = math.max(0, math.min(1, uu))
    local e = anim_graph_curve_ease_at(curve_id, uu, blend_bias)
    return ax + legx * uu, ay + legy * e
  end

  for k = 1, num do
    local v = k / (num + 1)
    local uu = anim_graph_inverse_ease_u(curve_id, v, blend_bias)
    local u0 = math.max(0, math.min(1, uu - du))
    local u1 = math.max(0, math.min(1, uu + du))
    local xa, ya = smooth_pt(u0)
    local xc, yc = smooth_pt(u1)
    local tdx, tdy = xc - xa, yc - ya
    local cx, cy = smooth_pt(uu)
    if uu <= du * 2 then
      local xf, yf = smooth_pt(math.min(1, uu + du * 3))
      tdx, tdy = xf - cx, yf - cy
    elseif uu >= 1 - du * 2 then
      local xb, yb = smooth_pt(math.max(0, uu - du * 3))
      tdx, tdy = cx - xb, cy - yb
    end
    anim_graph_draw_arrowhead(dl, cx, cy, tdx, tdy, col, ah, hw, thick)
  end
end

function point_to_segment_dist(px, py, ax, ay, bx, by)
  local vx, vy = bx - ax, by - ay
  local wx, wy = px - ax, py - ay
  local vv = vx * vx + vy * vy
  if vv <= 1e-12 then
    local dx, dy = px - ax, py - ay
    return math.sqrt(dx * dx + dy * dy)
  end
  local t = (wx * vx + wy * vy) / vv
  t = math.max(0, math.min(1, t))
  local nx = ax + vx * t
  local ny = ay + vy * t
  local dx, dy = px - nx, py - ny
  return math.sqrt(dx * dx + dy * dy)
end

--- Distance from (px,py) to the same polyline `anim_draw_curve_segment` draws (not the chord AB).
function anim_graph_point_to_curve_seg_dist(px, py, ax, ay, bx, by, curve_id, blend_bias)
  curve_id = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(curve_id) or 0)))
  if math.abs(bx - ax) < 1e-6 and math.abs(by - ay) < 1e-6 then
    local dx, dy = px - ax, py - ay
    return math.sqrt(dx * dx + dy * dy)
  end
  if curve_id == ANIM_GRAPH_CURVE_SQUARE then
    local d1 = point_to_segment_dist(px, py, ax, ay, bx, ay)
    local d2 = point_to_segment_dist(px, py, bx, ay, bx, by)
    return math.min(d1, d2)
  end
  local min_d = math.huge
  local steps = 24
  local prev_x, prev_y = ax, ay
  for s = 1, steps do
    local u = s / steps
    local e = anim_graph_curve_ease_at(curve_id, u, blend_bias)
    local x = ax + (bx - ax) * u
    local y = ay + (by - ay) * e
    local dseg = point_to_segment_dist(px, py, prev_x, prev_y, x, y)
    if dseg < min_d then
      min_d = dseg
    end
    prev_x, prev_y = x, y
  end
  return min_d
end

--- Segment hit distance; ignore hits near endpoints so nodes keep priority (CurveEditor-style).
function anim_graph_curve_seg_pick_dist(mx, my, ax, ay, bx, by, curve_id, node_r, blend_bias)
  node_r = tonumber(node_r) or 10
  local d_end = math.min(
    math.sqrt((mx - ax) * (mx - ax) + (my - ay) * (my - ay)),
    math.sqrt((mx - bx) * (mx - bx) + (my - by) * (my - by))
  )
  if d_end < node_r * 0.75 then
    return math.huge
  end
  return anim_graph_point_to_curve_seg_dist(mx, my, ax, ay, bx, by, curve_id, blend_bias)
end

function anim_graph_curve_hotkey_step(ctx)
  if not (ctx and ImGui.IsKeyPressed) then
    return 0
  end
  local function pressed(name)
    local key = ImGui[name]
    if not key then
      return false
    end
    local k = type(key) == "function" and key() or key
    local ok, v = pcall(ImGui.IsKeyPressed, ctx, k, false)
    return ok and v
  end
  if pressed("Key_Tab") then
    return 1
  end
  if pressed("Key_X") then
    return -1
  end
  return 0
end

--- Segment curve families for path editor: drag + Tab stay inside family; X cycles which family (1→2→3→1).
local function anim_graph_seg_family_snap(cc, mode)
  cc = math.max(0, math.min(ANIM_GRAPH_CURVE_MAX, math.floor(tonumber(cc) or 0)))
  mode = math.max(1, math.min(3, math.floor(tonumber(mode) or 1)))
  if mode == 1 then
    if cc == ANIM_GRAPH_CURVE_IN_LOG or cc == 0 or cc == ANIM_GRAPH_CURVE_IN_EXP then
      return cc
    end
    return ANIM_GRAPH_CURVE_IN_LOG
  end
  if mode == 2 then
    if cc >= 1 and cc <= 3 then
      return cc
    end
    return 1
  end
  return ANIM_GRAPH_CURVE_SQUARE
end

function anim_graph_seg_family_cycle_x(ctx)
  if not (ctx and ImGui.IsKeyPressed) then
    return false
  end
  local key = ImGui.Key_X
  if type(key) == "function" then
    key = key()
  end
  if not key then
    return false
  end
  local ok, v = pcall(ImGui.IsKeyPressed, ctx, key, false)
  return ok and v and true or false
end

local function wx_imgui_member(name)
  local ok, v = pcall(function()
    return ImGui[name]
  end)
  return ok and v or nil
end

local function wx_imgui_key(name)
  local key = wx_imgui_member(name)
  if type(key) == "function" then
    key = key()
  end
  return key
end

local function wx_wants_text_input(ctx)
  local get_io = wx_imgui_member("GetIO")
  if get_io then
    local ok, io = pcall(get_io, ctx)
    if ok and io ~= nil then
      local ok_want, want = pcall(function()
        return io.WantTextInput
      end)
      if ok_want and want ~= nil then
        return want == true
      end
    end
  end
  local get_want_text_input = wx_imgui_member("GetIO_WantTextInput")
  if get_want_text_input then
    local ok, v = pcall(get_want_text_input, ctx)
    if ok then
      return v == true
    end
  end
  return false
end

local function wx_bridge_transport_spacebar(ctx)
  local is_key_pressed = wx_imgui_member("IsKeyPressed")
  if not (ctx and is_key_pressed and r.Main_OnCommand) then
    return
  end
  if wx_wants_text_input(ctx) then
    return
  end
  local space = wx_imgui_key("Key_Space")
  if not space then
    return
  end
  local ok, pressed = pcall(is_key_pressed, ctx, space, false)
  if ok and pressed then
    r.Main_OnCommand(40073, 0) -- Transport: Play/pause (match toolbar ▶ strip)
  end
end

local function anim_graph_seg_family_advance_tab(curves, blends, si, direction)
  direction = (tonumber(direction) or 1) >= 0 and 1 or -1
  local mode = math.max(1, math.min(3, math.floor(tonumber(state.anim_graph_seg_family_mode) or 1)))
  local fam
  if mode == 1 then
    fam = { ANIM_GRAPH_CURVE_IN_LOG, 0, ANIM_GRAPH_CURVE_IN_EXP }
    if blends then
      blends[si] = nil
    end
  elseif mode == 2 then
    fam = { 1, 2, 3 }
  else
    fam = { ANIM_GRAPH_CURVE_SQUARE }
  end
  local cc = anim_graph_seg_family_snap(curves[si] or 0, mode)
  local idx = 1
  for i = 1, #fam do
    if fam[i] == cc then
      idx = i
      break
    end
  end
  idx = idx + direction
  if idx < 1 then
    idx = #fam
  elseif idx > #fam then
    idx = 1
  end
  curves[si] = fam[idx]
end

--- Mouse rdy: positive = downward. Updates curves[si] within current family; returns whether curves[si] changed.
function anim_graph_seg_apply_drag_delta_to_family(curves, si, rdy)
  if not (curves and si and type(rdy) == "number" and math.abs(rdy) > 2.5) then
    return false
  end
  local mode = math.max(1, math.min(3, math.floor(tonumber(state.anim_graph_seg_family_mode) or 1)))
  if mode == 1 then
    return false
  end
  local cc = anim_graph_seg_family_snap(curves[si] or 0, mode)
  local newc = cc
  if mode == 2 then
    local fam = { 1, 2, 3 }
    local idx = 1
    for i = 1, 3 do
      if fam[i] == cc then
        idx = i
        break
      end
    end
    if rdy > 0 then
      idx = idx - 1
      if idx < 1 then
        idx = 3
      end
    else
      idx = idx + 1
      if idx > 3 then
        idx = 1
      end
    end
    newc = fam[idx]
  else
    newc = ANIM_GRAPH_CURVE_SQUARE
  end
  if newc ~= (curves[si] or 0) then
    curves[si] = newc
    return true
  end
  return false
end

--- When GetMouseDragDelta is missing: ~14px steps within the active family only (not full 0..MAX).
function anim_graph_seg_apply_continuous_dy_to_family(curves, si, dy, c0)
  if not (curves and si) then
    return false
  end
  dy = tonumber(dy) or 0
  local mode = math.max(1, math.min(3, math.floor(tonumber(state.anim_graph_seg_family_mode) or 1)))
  if mode == 1 then
    return false
  end
  local st = dy >= 0 and math.floor(dy / 14 + 0.5) or -math.floor(-dy / 14 + 0.5)
  local newc
  if mode == 2 then
    local fam = { 1, 2, 3 }
    local cc0 = anim_graph_seg_family_snap(c0, mode)
    local idx = 1
    for i = 1, #fam do
      if fam[i] == cc0 then
        idx = i
        break
      end
    end
    local ni = idx - st
    while ni < 1 do
      ni = ni + #fam
    end
    while ni > #fam do
      ni = ni - #fam
    end
    newc = fam[ni]
  else
    newc = ANIM_GRAPH_CURVE_SQUARE
  end
  if newc ~= (curves[si] or 0) then
    curves[si] = newc
    return true
  end
  return false
end

function anim_graph_seg_process_family_hotkeys(ctx, curves, si, blends)
  if not (ctx and curves and si) then
    return false
  end
  local ch = false
  if anim_graph_seg_family_cycle_x(ctx) then
    state.anim_graph_seg_family_mode = (math.floor(tonumber(state.anim_graph_seg_family_mode) or 1) % 3) + 1
    local m = state.anim_graph_seg_family_mode
    if blends then
      blends[si] = nil
    end
    curves[si] = anim_graph_seg_family_snap(curves[si] or 0, m)
    ch = true
  end
  if anim_graph_curve_hotkey_step(ctx) == 1 then
    anim_graph_seg_family_advance_tab(curves, blends, si, 1)
    ch = true
  end
  return ch
end

function anim_graph_auto_lanes_ui(ctx, side_key)
  local key = anim_graph_auto_blob_key(side_key)
  local lanes = anim_graph_auto_decode_blob(state[key] or "", side_key)
  local changed = false
  local graph_w = 520
  local label_w = 140
  local lane_h = 38
  local function to_px(t, x0, x1)
    return x0 + math.max(0, math.min(1, t)) * math.max(1, x1 - x0)
  end
  for i = 1, #ANIM_AUTO_LANES do
    local spec = ANIM_AUTO_LANES[i]
    local lane = lanes[spec.key]
    if wx_custom_button(ctx, ((lane.enabled and "● " or "○ ") .. spec.label .. "##lane_toggle_" .. side_key .. "_" .. spec.key), label_w - 8, 0, state.wx_slider_style) then
      lane.enabled = not lane.enabled
      changed = true
    end
    ImGui.SameLine(ctx, 0, 8)
    ImGui.InvisibleButton(ctx, "##lane_canvas_" .. side_key .. "_" .. spec.key, graph_w - label_w, lane_h)
    local x0, y0 = ImGui.GetItemRectMin(ctx)
    local x1, y1 = ImGui.GetItemRectMax(ctx)
    local dl = ImGui.GetWindowDrawList and ImGui.GetWindowDrawList(ctx)
    local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
    local mx, my = 0, 0
    if ImGui.GetMousePos then
      mx, my = ImGui.GetMousePos(ctx)
    end
    local lmx, lmy = mx, my
    if dl and ImGui.DrawList_AddRectFilled then
      ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, lane.enabled and 0x1A1F1AFF or 0x141414FF, 3)
      if ImGui.DrawList_AddRect then
        ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, lane.enabled and 0x395C39FF or 0x303030FF, 3)
      end
    end
    local min_v, max_v = spec.min, spec.max
    local vr = math.max(1e-9, max_v - min_v)
    local function v_to_py(v)
      local u = (math.max(min_v, math.min(max_v, v)) - min_v) / vr
      return y1 - u * (y1 - y0)
    end
    local function py_to_v(py)
      local u = (y1 - py) / math.max(1, (y1 - y0))
      local v = min_v + math.max(0, math.min(1, u)) * vr
      if spec.integer then v = math.floor(v + 0.5) end
      return math.max(min_v, math.min(max_v, v))
    end
    local nearest_idx, nearest_d = nil, 9999
    for pidx = 1, #lane.points do
      local px = to_px(lane.points[pidx].t or 0, x0, x1)
      local py = v_to_py(lane.points[pidx].v or min_v)
      local d = math.sqrt((lmx - px) * (lmx - px) + (lmy - py) * (lmy - py))
      if d < nearest_d then
        nearest_d = d
        nearest_idx = pidx
      end
    end
    local function lane_insert_point_at_mouse()
      local nt = math.max(0, math.min(1, (lmx - x0) / math.max(1, x1 - x0)))
      local nv = py_to_v(lmy)
      local insert_idx = #lane.points + 1
      for pidx = 2, #lane.points do
        if nt < (lane.points[pidx].t or 0) then
          insert_idx = pidx
          break
        end
      end
      local old_ln = #lane.points
      table.insert(lane.points, insert_idx, { t = nt, v = nv })
      table.insert(lane.curves, math.max(1, insert_idx - 1), 0)
      lane.curve_blends = anim_graph_blends_on_point_insert(lane.curve_blends or {}, insert_idx, old_ln)
      changed = true
    end
    local function lane_segment_at_mouse()
      if #lane.points < 2 then
        return nil
      end
      local nt = math.max(0, math.min(1, (lmx - x0) / math.max(1, x1 - x0)))
      local best_i, best_d = nil, math.huge
      for pidx = 1, #lane.points - 1 do
        local t0 = lane.points[pidx].t or 0
        local t1 = lane.points[pidx + 1].t or 1
        if nt >= math.min(t0, t1) and nt <= math.max(t0, t1) then
          return pidx
        end
        local mid = (t0 + t1) * 0.5
        local d = math.abs(nt - mid)
        if d < best_d then
          best_d = d
          best_i = pidx
        end
      end
      return best_i
    end
    if hovered and lane.enabled and ImGui.IsMouseDoubleClicked and ImGui.IsMouseDoubleClicked(ctx, MOUSE_LEFT) then
      if not (nearest_idx and nearest_d <= 8) then
        lane_insert_point_at_mouse()
      end
    elseif hovered and lane.enabled and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
      local seg_hit = lane_segment_at_mouse()
      if seg_hit and (not nearest_idx or nearest_d > 8) then
        lane.curve_blends = lane.curve_blends or {}
        state.anim_graph_editor_lane_seg_lane = spec.key
        state.anim_graph_editor_lane_seg_idx = seg_hit
        state.anim_graph_editor_lane_seg_my0 = lmy
        state.anim_graph_seg_mode1_bias0 = anim_graph_seg_drag_start_blend(lane.curve_blends, lane.curves, seg_hit)
        if ImGui.ResetMouseDragDelta then
          pcall(ImGui.ResetMouseDragDelta, ctx)
        end
        changed = true
      elseif nearest_idx and nearest_d <= 8 then
        if overlay_mod_alt(ctx) and #lane.points > 2 and nearest_idx > 1 and nearest_idx < #lane.points then
          local old_pn = #lane.points
          table.remove(lane.points, nearest_idx)
          table.remove(lane.curves, math.max(1, nearest_idx - 1))
          lane.curve_blends = anim_graph_blends_on_point_remove(lane.curve_blends or {}, nearest_idx, old_pn)
          changed = true
        else
          state.anim_graph_editor_auto_drag_lane = spec.key
          state.anim_graph_editor_auto_drag_point = nearest_idx
        end
      end
    end
    if not (ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT)) then
      state.anim_graph_editor_auto_drag_lane = ""
      state.anim_graph_editor_auto_drag_point = nil
      state.anim_graph_editor_lane_seg_lane = ""
      state.anim_graph_editor_lane_seg_idx = nil
      state.anim_graph_editor_lane_seg_my0 = nil
      state.anim_graph_editor_lane_seg_c0 = nil
      state.anim_graph_seg_mode1_bias0 = nil
    end
    if lane.enabled and state.anim_graph_editor_auto_drag_lane == spec.key and state.anim_graph_editor_auto_drag_point and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
      local pidx = state.anim_graph_editor_auto_drag_point
      if lane.points[pidx] then
        if pidx ~= 1 and pidx ~= #lane.points then
          local mt = (lane.points[pidx - 1].t or 0) + 0.01
          local xt = (lane.points[pidx + 1].t or 1) - 0.01
          lane.points[pidx].t = math.max(mt, math.min(xt, (lmx - x0) / math.max(1, x1 - x0)))
        end
        lane.points[pidx].v = py_to_v(lmy)
        changed = true
      end
    end
    if lane.enabled and state.anim_graph_editor_lane_seg_lane == spec.key and state.anim_graph_editor_lane_seg_idx and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
      local si = state.anim_graph_editor_lane_seg_idx
      lane.curves = lane.curves or {}
      if si >= 1 and si <= #lane.points - 1 then
        lane.curve_blends = lane.curve_blends or {}
        local ddy = 0
        if ImGui.GetMouseDragDelta then
          local ok, _, got_dy = pcall(ImGui.GetMouseDragDelta, ctx, MOUSE_LEFT)
          if ok and type(got_dy) == "number" then
            ddy = got_dy
          end
        else
          ddy = lmy - (state.anim_graph_editor_lane_seg_my0 or lmy)
          state.anim_graph_editor_lane_seg_my0 = lmy
        end
        if math.abs(ddy) > 0 then
          local cid = math.floor(tonumber(lane.curves[si]) or 0)
          local b0 = anim_graph_seg_drag_start_blend(lane.curve_blends, lane.curves, si)
          local use_m1 = anim_graph_curve_is_mode1_family(cid)
          local b = use_m1 and math.max(-1, math.min(1, b0 - ddy * 0.02)) or math.max(0, math.min(1, b0 - ddy * 0.02))
          local ob = lane.curve_blends[si]
          if ob ~= b and not (type(ob) == "number" and math.abs(ob - b) < 1e-6) then
            lane.curve_blends[si] = b
            changed = true
          end
          if ImGui.ResetMouseDragDelta then
            pcall(ImGui.ResetMouseDragDelta, ctx)
          end
        end
      end
    end
    if hovered and lane.enabled and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_RIGHT) then
      local seg_idx, seg_dist = nil, 9999
      for pidx = 1, #lane.points - 1 do
        local ax = to_px(lane.points[pidx].t, x0, x1)
        local ay = v_to_py(lane.points[pidx].v)
        local bx = to_px(lane.points[pidx + 1].t, x0, x1)
        local by = v_to_py(lane.points[pidx + 1].v)
        local d = anim_graph_curve_seg_pick_dist(lmx, lmy, ax, ay, bx, by, lane.curves[pidx] or 0, 8, lane.curve_blends and lane.curve_blends[pidx])
        if d < seg_dist then
          seg_dist = d
          seg_idx = pidx
        end
      end
      if seg_idx and seg_dist <= 14 and ImGui.OpenPopup then
        state.anim_graph_editor_popup_seg = seg_idx
        state.anim_graph_editor_auto_drag_lane = spec.key
        ImGui.OpenPopup(ctx, "##lane_curve_popup_" .. side_key .. "_" .. spec.key)
      end
    end
    if ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##lane_curve_popup_" .. side_key .. "_" .. spec.key) then
      local seg = state.anim_graph_editor_popup_seg or 1
      ImGui.Text(ctx, spec.label .. " segment curve")
      for ci = 0, ANIM_GRAPH_CURVE_MAX do
        if ImGui.Selectable(ctx, anim_graph_curve_name(ci), (lane.curves[seg] or 0) == ci) then
          lane.curves[seg] = ci
          lane.curve_blends = lane.curve_blends or {}
          if ci == 0 then
            lane.curve_blends[seg] = 0
          elseif ci == ANIM_GRAPH_CURVE_IN_LOG then
            lane.curve_blends[seg] = -1
          elseif ci == ANIM_GRAPH_CURVE_IN_EXP then
            lane.curve_blends[seg] = 1
          else
            lane.curve_blends[seg] = nil
          end
          changed = true
        end
      end
      ImGui.EndPopup(ctx)
    end
    if dl then
      for pidx = 1, #lane.points - 1 do
        local ax = to_px(lane.points[pidx].t, x0, x1)
        local ay = v_to_py(lane.points[pidx].v)
        local bx = to_px(lane.points[pidx + 1].t, x0, x1)
        local by = v_to_py(lane.points[pidx + 1].v)
        local lb = lane.curve_blends and lane.curve_blends[pidx]
        anim_draw_curve_segment(dl, ax, ay, bx, by, lane.curves and lane.curves[pidx] or 0, lane.enabled and 0x83C9A4FF or 0x606060FF, 2, lb)
      end
      for pidx = 1, #lane.points do
        local px = to_px(lane.points[pidx].t, x0, x1)
        local py = v_to_py(lane.points[pidx].v)
        if ImGui.DrawList_AddCircleFilled then
          ImGui.DrawList_AddCircleFilled(dl, px, py, 4.4, lane.enabled and 0xF0F0F0FF or 0x8A8A8AFF)
        end
      end
    end
  end
  if changed then
    state[key] = anim_graph_auto_encode_blob(lanes)
  end
  return changed
end

function anim_graph_editor_ui(ctx)
  local pid = "Graph editor###anim_graph_editor_popup"
  if state.anim_graph_editor_open and ImGui.OpenPopup then
    ImGui.OpenPopup(ctx, pid)
    state.anim_graph_editor_open = false
  end
  local opened = false
  if ImGui.BeginPopupModal then
    opened = ImGui.BeginPopupModal(ctx, pid, nil, 0)
  end
  if not opened and ImGui.BeginPopup then
    opened = ImGui.BeginPopup(ctx, pid)
  end
  if not opened then
    return false
  end
  local changed = false
  local pts = state.anim_graph_editor_points or {}
  local curves = state.anim_graph_editor_curves or {}
  if #pts < 2 then
    local bb
    pts, curves, bb = anim_graph_decode_blob(anim_graph_default_blob())
    state.anim_graph_editor_points = pts
    state.anim_graph_editor_curves = curves
    state.anim_graph_editor_blends = bb
  end
  if type(state.anim_graph_editor_blends) ~= "table" then
    state.anim_graph_editor_blends = {}
  end
  local blends = state.anim_graph_editor_blends
  state.anim_graph_editor_selected = math.max(1, math.min(#pts, state.anim_graph_editor_selected or 1))

  local side_label = anim_graph_find_side_label(state.anim_graph_editor_side_key)
  ImGui.Text(ctx, side_label .. " custom path")
  local ws_key_modal = (state.anim_graph_editor_side_key == "out" and "anim_out_graph_word_span")
    or (state.anim_graph_editor_side_key == "phrase_out" and "anim_phrase_out_graph_word_span")
    or "anim_in_graph_word_span"
  do
    local chk_lbl = "Along word (t = start→end of each marker word)"
    local rv_ws, ws_v = ImGui.Checkbox(ctx, chk_lbl, state[ws_key_modal] and true or false)
    if rv_ws then
      state[ws_key_modal] = ws_v and true or false
      persist_anim_settings_extstate()
    end
  end
  ImGui.TextColored(
    ctx,
    0x9A9A9AFF,
    "Timeline t (below) maps to playback along the curve. With \"along word\", t follows (time−wordStart)/(nextWord−wordStart). Double-click canvas to add points; Alt+click deletes interior. Drag segments to scrub curve easing. Glow previews the XY output at animated t."
  )
  ImGui.Spacing(ctx)

  local graph_w = 520
  local graph_h = 240
  ImGui.InvisibleButton(ctx, "##anim_graph_canvas", graph_w, graph_h)
  local gx0, gy0 = ImGui.GetItemRectMin(ctx)
  local gx1, gy1 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList and ImGui.GetWindowDrawList(ctx)
  local hovered = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local mx, my = 0, 0
  if ImGui.GetMousePos then
    mx, my = ImGui.GetMousePos(ctx)
  end
  local pad = 10
  local ix0, iy0 = gx0 + pad, gy0 + pad
  local ix1, iy1 = gx1 - pad, gy1 - pad
  local iw, ih = math.max(1, ix1 - ix0), math.max(1, iy1 - iy0)
  local gmx, gmy = mx, my
  local function sx_to_px(v)
    return ix0 + ((math.max(-1, math.min(1, v)) + 1) * 0.5) * iw
  end
  local function sy_to_py(v)
    return iy0 + (1 - ((math.max(-1, math.min(1, v)) + 1) * 0.5)) * ih
  end
  local function px_to_sx(v)
    return math.max(-1, math.min(1, ((v - ix0) / iw) * 2 - 1))
  end
  local function py_to_sy(v)
    return math.max(-1, math.min(1, (1 - ((v - iy0) / ih)) * 2 - 1))
  end
  do
    local now = r.time_precise and r.time_precise() or 0
    state.anim_graph_editor_preview_clock = state.anim_graph_editor_preview_clock or now
    local du = math.max(0, math.min(0.1, now - state.anim_graph_editor_preview_clock))
    state.anim_graph_editor_preview_clock = now
    local pu = tonumber(state.anim_graph_editor_preview_u) or 0
    state.anim_graph_editor_preview_u = (pu + du * 0.22) % 1
  end
  if dl and ImGui.DrawList_AddRectFilled then
    ImGui.DrawList_AddRectFilled(dl, gx0, gy0, gx1, gy1, 0x151515FF, 4)
    if ImGui.DrawList_AddRect then
      ImGui.DrawList_AddRect(dl, gx0, gy0, gx1, gy1, 0x303030FF, 4)
    end
    for i = -1, 1 do
      local tx = sx_to_px(i)
      local ty = sy_to_py(i)
      if ImGui.DrawList_AddLine then
        ImGui.DrawList_AddLine(dl, tx, iy0, tx, iy1, i == 0 and 0x4D4D4DFF or 0x2D2D2DFF, i == 0 and 1.6 or 1)
        ImGui.DrawList_AddLine(dl, ix0, ty, ix1, ty, i == 0 and 0x4D4D4DFF or 0x2D2D2DFF, i == 0 and 1.6 or 1)
      end
    end
  end

  local nearest_idx, nearest_d = nil, 1e9
  for i = 1, #pts do
    local px, py = sx_to_px(pts[i].x or 0), sy_to_py(pts[i].y or 0)
    local d = math.sqrt((gmx - px) * (gmx - px) + (gmy - py) * (gmy - py))
    if d < nearest_d then
      nearest_d = d
      nearest_idx = i
    end
  end
  if hovered and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) then
    local seg_pick_idx, seg_pick_d = nil, 1e9
    for si = 1, #pts - 1 do
      local ax, ay = sx_to_px(pts[si].x), sy_to_py(pts[si].y)
      local bx, by = sx_to_px(pts[si + 1].x), sy_to_py(pts[si + 1].y)
      local d = anim_graph_curve_seg_pick_dist(gmx, gmy, ax, ay, bx, by, curves[si] or 0, 10, blends[si])
      if d < seg_pick_d then
        seg_pick_d = d
        seg_pick_idx = si
      end
    end
    if seg_pick_idx and seg_pick_d <= 24 and (not nearest_idx or nearest_d > 8) then
      state.anim_graph_editor_selected = seg_pick_idx
      state.anim_graph_editor_seg_drag_seg = seg_pick_idx
      state.anim_graph_editor_seg_drag_my0 = gmy
      state.anim_graph_seg_mode1_bias0 = anim_graph_seg_drag_start_blend(blends, curves, seg_pick_idx)
      if ImGui.ResetMouseDragDelta then
        pcall(ImGui.ResetMouseDragDelta, ctx)
      end
      changed = true
    elseif nearest_idx and nearest_d <= 10 then
      if overlay_mod_alt(ctx) and #pts > 2 and nearest_idx > 1 and nearest_idx < #pts then
        local old_pn = #pts
        table.remove(pts, nearest_idx)
        table.remove(curves, math.max(1, nearest_idx - 1))
        state.anim_graph_editor_blends = anim_graph_blends_on_point_remove(blends, nearest_idx, old_pn)
        blends = state.anim_graph_editor_blends
        state.anim_graph_editor_selected = math.max(1, math.min(#pts, nearest_idx - 1))
        changed = true
      else
        state.anim_graph_editor_selected = nearest_idx
        state.anim_graph_editor_drag_point = nearest_idx
      end
    elseif ImGui.IsMouseDoubleClicked and ImGui.IsMouseDoubleClicked(ctx, MOUSE_LEFT) then
      local nx = px_to_sx(gmx)
      local ny = py_to_sy(gmy)
      local nt = math.max(0, math.min(1, (nx + 1) * 0.5))
      local insert_idx = #pts + 1
      for i = 2, #pts do
        if nt < (pts[i].t or 0) then
          insert_idx = i
          break
        end
      end
      local old_pn = #pts
      table.insert(pts, insert_idx, { x = nx, y = ny, t = nt })
      table.insert(curves, math.max(1, insert_idx - 1), 0)
      state.anim_graph_editor_blends = anim_graph_blends_on_point_insert(blends, insert_idx, old_pn)
      blends = state.anim_graph_editor_blends
      for i = 1, #pts - 1 do
        if curves[i] == nil then curves[i] = 0 end
      end
      state.anim_graph_editor_selected = insert_idx
      state.anim_graph_editor_drag_point = insert_idx
      changed = true
    end
  end
  if not (ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT)) then
    state.anim_graph_editor_drag_point = nil
    state.anim_graph_editor_seg_drag_seg = nil
    state.anim_graph_editor_seg_drag_my0 = nil
    state.anim_graph_seg_mode1_bias0 = nil
  end
  local drag_i = state.anim_graph_editor_drag_point
  if drag_i and not state.anim_graph_editor_seg_drag_seg and pts[drag_i] and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
    pts[drag_i].x = px_to_sx(gmx)
    pts[drag_i].y = py_to_sy(gmy)
    changed = true
  end
  local sdrag = state.anim_graph_editor_seg_drag_seg
  if sdrag and type(sdrag) == "number" and sdrag >= 1 and sdrag <= #pts - 1 and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
    local ddy = 0
    if ImGui.GetMouseDragDelta then
      local ok, _, got_dy = pcall(ImGui.GetMouseDragDelta, ctx, MOUSE_LEFT)
      if ok and type(got_dy) == "number" then
        ddy = got_dy
      end
    else
      ddy = gmy - (state.anim_graph_editor_seg_drag_my0 or gmy)
      state.anim_graph_editor_seg_drag_my0 = gmy
    end
    if math.abs(ddy) > 0 then
      local cid = math.floor(tonumber(curves[sdrag]) or 0)
      local b0 = anim_graph_seg_drag_start_blend(blends, curves, sdrag)
      local use_m1 = anim_graph_curve_is_mode1_family(cid)
      local b = use_m1 and math.max(-1, math.min(1, b0 - ddy * 0.02)) or math.max(0, math.min(1, b0 - ddy * 0.02))
      local ob = blends[sdrag]
      if ob ~= b and not (type(ob) == "number" and math.abs(ob - b) < 1e-6) then
        blends[sdrag] = b
        changed = true
      end
      if ImGui.ResetMouseDragDelta then
        pcall(ImGui.ResetMouseDragDelta, ctx)
      end
    end
  end

  if hovered and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_RIGHT) then
    local seg_idx, seg_dist = nil, 9999
    for i = 1, #pts - 1 do
      local ax, ay = sx_to_px(pts[i].x), sy_to_py(pts[i].y)
      local bx, by = sx_to_px(pts[i + 1].x), sy_to_py(pts[i + 1].y)
      local d = anim_graph_curve_seg_pick_dist(gmx, gmy, ax, ay, bx, by, curves[i] or 0, 10, blends[i])
      if d < seg_dist then
        seg_dist = d
        seg_idx = i
      end
    end
    if seg_idx and seg_dist <= 14 then
      state.anim_graph_editor_popup_seg = seg_idx
      if ImGui.OpenPopup then
        ImGui.OpenPopup(ctx, "##anim_graph_seg_curve_popup")
      end
    end
  end
  if ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##anim_graph_seg_curve_popup") then
    local seg = state.anim_graph_editor_popup_seg or 1
    ImGui.Text(ctx, string.format("Segment %d -> %d", seg - 1, seg))
    for ci = 0, ANIM_GRAPH_CURVE_MAX do
      local selected = (curves[seg] or 0) == ci
      if ImGui.Selectable(ctx, anim_graph_curve_name(ci), selected) then
        curves[seg] = ci
        if ci == 0 then
          blends[seg] = 0
        elseif ci == ANIM_GRAPH_CURVE_IN_LOG then
          blends[seg] = -1
        elseif ci == ANIM_GRAPH_CURVE_IN_EXP then
          blends[seg] = 1
        else
          blends[seg] = nil
        end
        changed = true
      end
    end
    ImGui.EndPopup(ctx)
  end

  if dl then
    for i = 1, #pts - 1 do
      local ax, ay = sx_to_px(pts[i].x), sy_to_py(pts[i].y)
      local bx, by = sx_to_px(pts[i + 1].x), sy_to_py(pts[i + 1].y)
      local cc = (curves[i] or 0) == ANIM_GRAPH_CURVE_SQUARE and 0x7DA2FFFF or 0x65D6A0FF
      local bb = blends[i]
      anim_draw_curve_segment(dl, ax, ay, bx, by, curves[i] or 0, cc, 2, bb)
      anim_draw_path_segment_flow_arrows(
        dl,
        ax,
        ay,
        bx,
        by,
        curves[i] or 0,
        (curves[i] or 0) == ANIM_GRAPH_CURVE_SQUARE and 0xB0C8F0FF or 0xB8F0D8FF,
        bb
      )
    end
    do
      local u_prev = tonumber(state.anim_graph_editor_preview_u) or 0
      local xv, yv = anim_graph_eval_path_xy(pts, curves, blends, u_prev)
      anim_graph_draw_path_preview_glow(dl, sx_to_px(xv), sy_to_py(yv))
      if ImGui.DrawList_AddText then
        ImGui.DrawList_AddText(
          dl,
          ix0 + 6,
          iy0 + 4,
          0xb0b0b0FF,
          string.format("preview t %.2f → x %.2f  y %.2f", u_prev, xv, yv)
        )
      end
    end
    for i = 1, #pts do
      local px, py = sx_to_px(pts[i].x), sy_to_py(pts[i].y)
      local col = i == (state.anim_graph_editor_selected or 1) and 0xFFE082FF or 0xE0E0E0FF
      if ImGui.DrawList_AddCircleFilled then
        ImGui.DrawList_AddCircleFilled(dl, px, py, 5.2, col)
      end
      if ImGui.DrawList_AddText then
        ImGui.DrawList_AddText(dl, px + 6, py - 6, 0xD0D0D0FF, string.format("%d  t=%.2f", i - 1, pts[i].t or 0))
      end
    end
  end

  ImGui.Spacing(ctx)
  local tl_w, tl_h = graph_w, 58
  ImGui.InvisibleButton(ctx, "##anim_graph_timeline", tl_w, tl_h)
  local tx0, ty0 = ImGui.GetItemRectMin(ctx)
  local tx1, ty1 = ImGui.GetItemRectMax(ctx)
  local thover = ImGui.IsItemHovered and ImGui.IsItemHovered(ctx)
  local tdl = ImGui.GetWindowDrawList and ImGui.GetWindowDrawList(ctx)
  local tl_pad = 18
  local lx0, lx1 = tx0 + tl_pad, tx1 - tl_pad
  local ly = ty0 + (ty1 - ty0) * 0.52
  local lrange = math.max(1, lx1 - lx0)
  local tmx, tmy = mx, my
  local function t_to_px(v)
    return lx0 + math.max(0, math.min(1, v)) * lrange
  end
  local function px_to_t(v)
    return math.max(0, math.min(1, (v - lx0) / lrange))
  end
  if tdl and ImGui.DrawList_AddLine then
    ImGui.DrawList_AddRectFilled(tdl, tx0, ty0, tx1, ty1, 0x111111FF, 4)
    if ImGui.DrawList_AddRect then
      ImGui.DrawList_AddRect(tdl, tx0, ty0, tx1, ty1, 0x303030FF, 4)
    end
    ImGui.DrawList_AddLine(tdl, lx0, ly, lx1, ly, 0x8A8A8AFF, 2)
    local prv = tonumber(state.anim_graph_editor_preview_u) or 0
    local pux = t_to_px(prv)
    ImGui.DrawList_AddLine(tdl, pux, ty0 + 5, pux, ty1 - 5, 0xff8844cc, 2)
  end
  local nearest_t_idx, nearest_t_d = nil, 1e9
  for i = 1, #pts do
    local px = t_to_px(pts[i].t or 0)
    local d = math.abs(tmx - px) + math.abs(tmy - ly)
    if d < nearest_t_d then
      nearest_t_d = d
      nearest_t_idx = i
    end
  end
  if thover and ImGui.IsMouseClicked and ImGui.IsMouseClicked(ctx, MOUSE_LEFT) and nearest_t_idx and nearest_t_d < 14 then
    if overlay_mod_alt(ctx) and #pts > 2 and nearest_t_idx > 1 and nearest_t_idx < #pts then
      local old_pn = #pts
      table.remove(pts, nearest_t_idx)
      table.remove(curves, math.max(1, nearest_t_idx - 1))
      state.anim_graph_editor_blends = anim_graph_blends_on_point_remove(blends, nearest_t_idx, old_pn)
      blends = state.anim_graph_editor_blends
      state.anim_graph_editor_selected = math.max(1, math.min(#pts, nearest_t_idx - 1))
      changed = true
    else
      state.anim_graph_editor_selected = nearest_t_idx
      state.anim_graph_editor_drag_t = nearest_t_idx
    end
  end
  if not (ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT)) then
    state.anim_graph_editor_drag_t = nil
  end
  local drag_ti = state.anim_graph_editor_drag_t
  if drag_ti and pts[drag_ti] and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_LEFT) then
    if drag_ti ~= 1 and drag_ti ~= #pts then
      local min_t = (pts[drag_ti - 1].t or 0) + 0.01
      local max_t = (pts[drag_ti + 1].t or 1) - 0.01
      pts[drag_ti].t = math.max(min_t, math.min(max_t, px_to_t(tmx)))
      changed = true
    end
  end
  if tdl then
    for i = 1, #pts do
      local px = t_to_px(pts[i].t or 0)
      local col = i == (state.anim_graph_editor_selected or 1) and 0xFFE082FF or 0xD9D9D9FF
      if ImGui.DrawList_AddCircleFilled then
        ImGui.DrawList_AddCircleFilled(tdl, px, ly, 5.5, col)
      end
      if ImGui.DrawList_AddText then
        ImGui.DrawList_AddText(tdl, px - 8, ly + 10, 0xC8C8C8FF, string.format("%.2f", pts[i].t or 0))
      end
    end
  end

  ImGui.Spacing(ctx)
  ImGui.TextColored(ctx, 0x9A9A9AFF, "Custom look automation lanes (click lane title to enable/disable)")
  if anim_graph_auto_lanes_ui(ctx, state.anim_graph_editor_side_key or "in") then
    changed = true
  end
  ImGui.Spacing(ctx)
  local sel = state.anim_graph_editor_selected or 1
  if pts[sel] then
    ImGui.Text(ctx, string.format("Point %d  x %.2f  y %.2f  t %.2f", sel - 1, pts[sel].x or 0, pts[sel].y or 0, pts[sel].t or 0))
  end
  if #pts > 2 then
    if wx_custom_button(ctx, "Delete selected point", 180, 0, state.wx_slider_style) then
      local si = state.anim_graph_editor_selected or 1
      if si > 1 and si < #pts then
        local old_pn = #pts
        table.remove(pts, si)
        table.remove(curves, math.max(1, si - 1))
        state.anim_graph_editor_blends = anim_graph_blends_on_point_remove(blends, si, old_pn)
        blends = state.anim_graph_editor_blends
        for i = 1, #pts - 1 do
          if curves[i] == nil then curves[i] = 0 end
        end
        state.anim_graph_editor_selected = math.max(1, math.min(#pts, si - 1))
        changed = true
      end
    end
    ImGui.SameLine(ctx, 0, 8)
  end
  if wx_custom_button(ctx, "Reset path", 120, 0, state.wx_slider_style) then
    local rp, rc, rb = anim_graph_decode_blob(anim_graph_default_blob())
    state.anim_graph_editor_points = rp
    state.anim_graph_editor_curves = rc
    state.anim_graph_editor_blends = rb
    pts, curves = rp, rc
    blends = rb
    state.anim_graph_editor_selected = 1
    changed = true
  end
  ImGui.SameLine(ctx, 0, 8)
  if wx_custom_button(ctx, "Close", 100, 0, state.wx_slider_style) then
    if ImGui.CloseCurrentPopup then
      ImGui.CloseCurrentPopup(ctx)
    end
  end
  local applied = false
  if changed then
    applied = anim_graph_apply_editor_to_state()
  end
  ImGui.EndPopup(ctx)
  return applied
end

function anim_look_row_ui(ctx, side_label, side_key, enabled, typ, curve)
  local typ_i = math.floor(tonumber(typ) or 0)
  local custom_like = (typ_i > ANIM_TYPE_MAX) or (typ_i == ANIM_KIND.CUSTOM)
  local uses_motion = anim_type_uses_motion(typ)
  local uses_wiggle = anim_type_uses_wiggle(typ)
  local uses_bounce = anim_uses_bounce(typ, curve)
  local uses_dupes = anim_type_uses_duplicates(typ)
  local uses_blur = anim_type_uses_blur(typ)
  local uses_dir = custom_like or typ_i == ANIM_KIND.WIPE_REVEAL or typ_i == ANIM_KIND.SQUASH or typ_i == ANIM_KIND.STRETCH
  local auto_lanes = uses_dir and anim_graph_auto_decode_blob(state[anim_graph_auto_blob_key(side_key)] or "", side_key) or nil
  local function lane_on(k)
    local lane = auto_lanes and auto_lanes[k]
    return lane and lane.enabled and true or false
  end
  local twist_key = (side_key == "phrase_out") and "anim_phrase_out_twist" or ("anim_" .. side_key .. "_twist")
  if
    not (uses_motion or uses_wiggle or uses_bounce or uses_dupes or uses_dir or uses_blur or typ_i == 0)
  then
    return false, false
  end
  local changed = false
  ImGui.TableNextRow(ctx)
  ImGui.TableNextColumn(ctx)
  ImGui.Text(ctx, side_label .. " look")
  ImGui.TableNextColumn(ctx)
  if ImGui.BeginDisabled then
    ImGui.BeginDisabled(ctx, not enabled)
  end
  local first = true
  local function same()
    if first then
      first = false
    else
      ImGui.SameLine(ctx, 0, 8)
    end
  end
  if uses_motion then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("motion")) end
    local rv, v = anim_pct_slider(ctx, "##" .. side_key .. "_motion", "motion", state["anim_" .. side_key .. "_motion"], 300, 12)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv then
      state["anim_" .. side_key .. "_motion"] = v
      changed = true
    end
  end
  if uses_wiggle then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("wiggle")) end
    local rv, v = anim_pct_slider(ctx, "##" .. side_key .. "_wiggle", "wiggle", state["anim_" .. side_key .. "_wiggle"], 300, 12)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv then
      state["anim_" .. side_key .. "_wiggle"] = v
      changed = true
    end
  end
  if custom_like then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("scale")) end
    local rv_s, vs = anim_signed_pct_slider(ctx, "##" .. side_key .. "_scale", "scale", state["anim_" .. side_key .. "_scale"], -100, 200, 12)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv_s then
      state["anim_" .. side_key .. "_scale"] = vs
      changed = true
    end
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("fade")) end
    local rv_f, vf = anim_pct_slider(ctx, "##" .. side_key .. "_fade", "fade", state["anim_" .. side_key .. "_fade"], 100, 10)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv_f then
      state["anim_" .. side_key .. "_fade"] = vf
      changed = true
    end
  end
  if uses_blur then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("blur")) end
    local rv_b, vb = anim_pct_slider(ctx, "##" .. side_key .. "_blur", "blur", state["anim_" .. side_key .. "_blur"], 300, 10)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv_b then
      state["anim_" .. side_key .. "_blur"] = vb
      changed = true
    end
  end
  if uses_bounce then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("bounce")) end
    local rv, v = anim_pct_slider(ctx, "##" .. side_key .. "_bounce", "bounce", state["anim_" .. side_key .. "_bounce"], 200, 12)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv then
      state["anim_" .. side_key .. "_bounce"] = v
      changed = true
    end
  end
  if uses_dupes then
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("dupes")) end
    local dupes = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(tonumber(state["anim_" .. side_key .. "_dupes"]) or 3)))
    local rv_d, dupes2 = wx_custom_slider_int(ctx, "##" .. side_key .. "_dupes", "dupes", dupes, 1, ANIM_MAX_DUPES, "%d", anim_combo_w(ctx, 10, 92), state.wx_slider_style, nil, nil, nil, true)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv_d then
      state["anim_" .. side_key .. "_dupes"] = math.max(1, math.min(ANIM_MAX_DUPES, math.floor(dupes2 or dupes)))
      changed = true
    end
    same()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("ghost")) end
    local rv, v = anim_pct_slider(ctx, "##" .. side_key .. "_ghost", "ghost", state["anim_" .. side_key .. "_ghost"], 200, 11)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv then
      state["anim_" .. side_key .. "_ghost"] = v
      changed = true
    end
  end

  ImGui.TableNextRow(ctx)
  ImGui.TableNextColumn(ctx)
  ImGui.TableNextColumn(ctx)
  if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not enabled) end
  local second = true
  local function same2()
    if second then
      second = false
    else
      ImGui.SameLine(ctx, 0, 8)
    end
  end
  same2()
  if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, lane_on("twist")) end
  local tw = math.floor((tonumber(state[twist_key]) or 0) + 0.5)
  local rv_tw, tw2 =
    wx_degree_knob_int(ctx, "##" .. side_key .. "_twist", "twist", tw, -720, 720, "%d deg", anim_combo_w(ctx, 10, 96), state.wx_slider_style, 0)
  if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
  if rv_tw then
    state[twist_key] = math.max(-720, math.min(720, tonumber(tw2) or tw))
    changed = true
  end
  if uses_dir then
    local use_graph_key = (side_key == "phrase_out") and "anim_phrase_out_use_graph" or ("anim_" .. side_key .. "_use_graph")
    same2()
    local rv_ug, ug = ImGui.Checkbox(ctx, "use graph editor##" .. side_key, state[use_graph_key] and true or false)
    if rv_ug then
      state[use_graph_key] = ug and true or false
      changed = true
    end
    same2()
    if ImGui.BeginDisabled then
      ImGui.BeginDisabled(ctx, (state[use_graph_key] and true or false) or lane_on("dir"))
    end
    local dir = math.floor((tonumber(state["anim_" .. side_key .. "_dir"]) or 90) + 0.5)
    local rv_dir, dir2 =
      wx_degree_knob_int(ctx, "##" .. side_key .. "_dir", "dir", dir, -180, 180, "%d deg", anim_combo_w(ctx, 10, 96), state.wx_slider_style, 90)
    if rv_dir then
      state["anim_" .. side_key .. "_dir"] = math.max(-180, math.min(180, tonumber(dir2) or dir))
      changed = true
    end
    if ImGui.EndDisabled then
      ImGui.EndDisabled(ctx)
    end
    same2()
    if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not (state[use_graph_key] and true or false)) end
    local ws_row_key = side_key == "phrase_out" and "anim_phrase_out_graph_word_span" or ("anim_" .. side_key .. "_graph_word_span")
    local rv_wsp, wsp = ImGui.Checkbox(ctx, "t along word##" .. ws_row_key, state[ws_row_key] and true or false)
    if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
    if rv_wsp then
      state[ws_row_key] = wsp and true or false
      changed = true
    end
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, "When enabled, timeline t advances 0→1 across each marker word interval (requires Custom + graph).")
    end
    same2()
    local current_custom_name = anim_custom_type_name_for_id(state["anim_" .. side_key .. "_type"])
    if wx_custom_small_button(ctx, "Save type##" .. side_key, state.wx_slider_style) then
      state.anim_custom_type_save_name = current_custom_name or ""
      if ImGui.OpenPopup then
        ImGui.OpenPopup(ctx, "##save_custom_type_" .. side_key)
      end
    end
    if ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##save_custom_type_" .. side_key) then
      ImGui.Text(ctx, "Save custom animation type as")
      local rv_nm, nm = ImGui.InputText(ctx, "Name##custom_type_name_" .. side_key, state.anim_custom_type_save_name or "")
      if rv_nm then
        state.anim_custom_type_save_name = nm or ""
      end
      if wx_custom_button(ctx, "Save##custom_type_save_" .. side_key, 90, 0, state.wx_slider_style) then
        local ok, err = anim_custom_type_save_named(side_key, state.anim_custom_type_save_name or "")
        if ok then
          local saved = trim(state.anim_custom_type_save_name or "")
          local idx = anim_custom_type_find_idx(saved)
          if idx then
            state["anim_" .. side_key .. "_type"] = ANIM_TYPE_MAX + idx
          end
          state.status = "Saved custom animation type: " .. saved
          state.status_err = false
          changed = true
          if ImGui.CloseCurrentPopup then
            ImGui.CloseCurrentPopup(ctx)
          end
        else
          state.status = err or "Could not save custom animation type."
          state.status_err = true
        end
      end
      if current_custom_name then
        ImGui.SameLine(ctx)
        if wx_custom_button(ctx, "Delete##custom_type_delete_" .. side_key, 90, 0, state.wx_slider_style) then
          anim_custom_type_delete_named(current_custom_name)
          state["anim_" .. side_key .. "_type"] = ANIM_KIND.CUSTOM
          state.status = "Deleted custom animation type: " .. current_custom_name
          state.status_err = false
          changed = true
          if ImGui.CloseCurrentPopup then
            ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
      ImGui.SameLine(ctx)
      if wx_custom_button(ctx, "Cancel##custom_type_cancel_" .. side_key, 90, 0, state.wx_slider_style) then
        if ImGui.CloseCurrentPopup then
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.EndPopup(ctx)
    end
  end
  if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end  -- closes twist-row BeginDisabled
  if ImGui.EndDisabled then
    ImGui.EndDisabled(ctx)
  end
  return true, changed
end

do
  local ctx = ImGui.CreateContext(WINDOW_TITLE)

  --- One row index `li` (1..6): size + randomize on one line; moving Randomize respawns that row’s jitter only.
  --- Optional `slot_w`: total width for the slider when laid out in adaptive multi-column flow.
  local function ui_ml_row_controls(ctx, item, li, slot_w)
    ImGui.PushID(ctx, li * 137 + 8000)
    if ImGui.AlignTextToFramePadding then
      ImGui.AlignTextToFramePadding(ctx)
    end
    local row_label = string.format("Row %d", li)
    local label_w = wx_text_size(ctx, row_label)
    local label_gap = 5
    ImGui.Text(ctx, row_label)
    ImGui.SameLine(ctx, 0, label_gap)
    local changed = false
    local default_total = ml_row_slider_w(ctx) * 2.1
    local slot_total = tonumber(slot_w)
    local slider_w = slot_total and math.max(1, math.floor(slot_total - label_w - label_gap + 0.5)) or default_total
    local sw = slider_w / 2.1
    local _iw_pushed = false
    if ImGui.PushItemWidth then
      ImGui.PushItemWidth(ctx, sw)
      _iw_pushed = true
    end
    local pct = math.floor((state.ml_s[li] or 1) * 100 + 0.5)
    local rp = math.floor((state.ml_r[li] or 0) * 100 + 0.5)
    local rv2, pct2, rv3, rp2 = wx_custom_slider_int(ctx, "##mlsz" .. li, "Size", pct, 12, 300, "%d%%", slider_w, state.wx_slider_style, rp, 100, "± %d%%")
    if rv2 then
      state.ml_s[li] = math.max(0.12, math.min(3, pct2 / 100))
      changed = true
    end
    if rv3 then
      state.ml_r[li] = math.max(0, math.min(1, rp2 / 100))
      state.ml_jitter[li] = math.random() * 2 - 1
      persist_ml_jitter()
      changed = true
    end
    if ImGui.SetItemTooltip then
      ImGui.SetItemTooltip(ctx, "Size for this row as % of Video Processor fontPx. ± is random span.")
    end
    if _iw_pushed and ImGui.PopItemWidth then
      ImGui.PopItemWidth(ctx)
    end
    ImGui.PopID(ctx)
    if changed then
      refresh_preview(item)
      overlay_request_autosave()
    end
  end

  local function loop()
  local flags = ImGui.WindowFlags_NoCollapse
  ImGui.SetNextWindowSize(ctx, 700, 720, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true, flags)
  if visible then
    local rv
    wx_bridge_transport_spacebar(ctx)
    local item = nil
    if r.CountSelectedMediaItems(0) == 1 then
      item = r.GetSelectedMediaItem(0, 0)
    end

    local take, words = nil, {}
    if item then
      take, words = W.find_take_and_wx_words(item)
    end

    anim_graph_update_live_vp_coalesce()

    wx_draw_hint_row_with_gear(ctx, "")
    ImGui.Separator(ctx)
    local guid = item_guid_str(item)
    local key = overlay_source_key(item, words)
    if
      item
      and guid ~= ""
      and guid == state.tracked_item_guid
      and state.overlay_source_key ~= ""
      and (not words or #words == 0)
      and state.prev_words_count > 0
    then
      key = state.overlay_source_key
    end
    if key ~= state.overlay_source_key then
      state.overlay_source_key = key
      state.overlay_autosave_sig_saved = nil
      if words and #words > 0 then
        local same_item = (guid ~= "" and guid == state.tracked_item_guid)
        if same_item and (state.ml_word_n or 0) > 0 then
          ml_preserve_layout_for_new_count(#words)
        else
          ml_load_for_word_count(#words, item)
        end
        ml_sync_editor_text(words)
        state.tracked_item_guid = guid
      else
        state.editor_text = ""
        state.tracked_item_guid = guid
      end
      word_palette_load_for_item(item)
    end



    local has_marker_words = item and words and #words > 0
    if has_marker_words then
      local hint = WX_TIMING_HINT[state.ml_timing_mode or 1] or ""
      if hint ~= "" then
        ImGui.TextColored(ctx, 0xC8D0E8FF, hint)
      end
    end

    ImGui.Spacing(ctx)

    local tabs_active = ImGui.BeginTabBar and ImGui.BeginTabBar(ctx, "##wx_bridge_main_tabs", ImGui.TabBarFlags_None or 0)
    local function wx_tab_enter(name, folded_title)
      if tabs_active then
        return ImGui.BeginTabItem(ctx, name)
      end
      separator_text(ctx, folded_title)
      ImGui.Spacing(ctx)
      return true
    end
    local function wx_tab_leave(is_open)
      if tabs_active and is_open then
        ImGui.EndTabItem(ctx)
      end
    end

    do
      local t_ov = wx_tab_enter("Overview", "Overview — word grid & sync tools")
      if t_ov then

        ImGui.Spacing(ctx)
        if has_marker_words and not state.word_grid_floating then
          word_grid_ui(ctx, item, words)
        end

        ImGui.Spacing(ctx)
        separator_text(ctx, "Sync & apply tools")
        if wx_custom_button(ctx, "Save layout to item", 200, 0, state.wx_slider_style) then
          if not item or not words or #words == 0 then
            state.status = "Select one item with marker words to save."
            state.status_err = true
          elseif not editor_text_parse_ok(words, state.editor_text or "") then
            state.status = "Internal layout error — try Reset triple layout."
            state.status_err = true
          else
            r.Undo_BeginBlock()
            local ok = write_editor_text_to_item(item, state.editor_text or "")
            if ok then
              r.SetExtState(SECTION, "EDITOR_TEXT", state.editor_text or "", true)
              save_settings()
              if r.MarkProjectDirty then
                r.MarkProjectDirty(0)
              end
              ml_sync_editor_text(words)
              state.overlay_autosave_sig_saved = overlay_autosave_state_sig(words)
              state.status =
                "Layout saved on item (P_EXT) + bridge extstate — edits to words and settings also autosave here when subtitle parses."
              state.status_err = false
            else
              state.status = "Could not write extended state on this item (REAPER too old?)."
              state.status_err = true
            end
            r.Undo_EndBlock("WhisperX: save layout to item", -1)
          end
        end
        ImGui.SameLine(ctx)
        if wx_custom_button(ctx, "Reset triple phrase/row", 200, 0, state.wx_slider_style) then
          if item and words and #words > 0 then
            for i = 1, math.max(0, #words - 1) do
              state.ml_phrase_after[i] = false
              state.ml_row_after[i] = false
            end
            for i = 1, #words do
              state.ml_word_scales[i] = 1
              state.ml_row_spacings[i] = nil
            end
            ml_sync_editor_text(words)
            refresh_preview(item)
            if auto_persist_layout then
              auto_persist_layout(item, words, ctx)
            end
          end
        end
        ImGui.SameLine(ctx)
        if wx_custom_button(ctx, "Clear word styles", 160, 0, state.wx_slider_style) then
          if item and words and #words > 0 then
            state.word_styles = {}
            persist_word_styles(#words, item)
            refresh_preview(item)
            if auto_persist_layout then
              auto_persist_layout(item, words, ctx)
            end
          end
        end
        ImGui.SameLine(ctx)
        if wx_custom_button(ctx, "Re-read markers → VP", 200, 0, state.wx_slider_style) then
          refresh_markers_and_apply(item)
        end
        if state.preview_parse_err ~= "" then
          ImGui.Spacing(ctx)
          separator_text(ctx, "Subtitle / layout issue")
          ImGui.TextColored(ctx, 0x7D7DFFFF, state.preview_parse_err)
          if state.parse_hint then
            ImGui.Spacing(ctx)
            draw_parse_hint(ctx, state.parse_hint)
          end
        end

        wx_tab_leave(t_ov)
      end
    end

    do
      local t_ty = wx_tab_enter("Typography & frame", "Typography — font, guides & image FX")
      if t_ty then
        font_selector_ui(ctx, item)

        ImGui.Spacing(ctx)
        separator_text(ctx, "Video ratio guides")
        local changed_guides = false
        local guide_flags = 0
        if ImGui.TableFlags_SizingStretchProp then
          guide_flags = guide_flags | ImGui.TableFlags_SizingStretchProp
        end
        if ImGui.BeginTable and ImGui.BeginTable(ctx, "##video_ratio_guides", 3, guide_flags) then
          for i, guide in ipairs(VIDEO_RATIO_GUIDES) do
            if (i - 1) % 3 == 0 then
              ImGui.TableNextRow(ctx)
            end
            ImGui.TableNextColumn(ctx)
            local rv_g, on_g = ImGui.Checkbox(ctx, guide.label .. "##video_guide_" .. guide.id, state.video_guides[guide.id] and true or false)
            if rv_g then
              state.video_guides[guide.id] = on_g and true or false
              r.SetExtState(SECTION, guide.key, state.video_guides[guide.id] and "1" or "0", true)
              changed_guides = true
            end
          end
          ImGui.EndTable(ctx)
        else
          for i, guide in ipairs(VIDEO_RATIO_GUIDES) do
            if i > 1 then
              ImGui.SameLine(ctx, 0, 10)
            end
            local rv_g, on_g = ImGui.Checkbox(ctx, guide.label .. "##video_guide_fallback_" .. guide.id, state.video_guides[guide.id] and true or false)
            if rv_g then
              state.video_guides[guide.id] = on_g and true or false
              r.SetExtState(SECTION, guide.key, state.video_guides[guide.id] and "1" or "0", true)
              changed_guides = true
            end
          end
        end
        if changed_guides then
          state._last_vp_body = nil
          refresh_preview(item)
          overlay_request_autosave()
        end

        ImGui.Spacing(ctx)
        separator_text(ctx, "Image post FX")
        local changed_post = false
        local rv_post, post_on = ImGui.Checkbox(ctx, "Wave-warp keyed text image", state.img_post_wave and true or false)
        if rv_post then
          state.img_post_wave = post_on and true or false
          r.SetExtState(SECTION, "IMG_POST_WAVE", state.img_post_wave and "1" or "0", true)
          changed_post = true
        end
        if state.img_post_wave then
          local rv_amp, amp2 = ImGui.DragDouble(ctx, "Wave amp px##img_post_wave_amp", state.img_post_wave_amp or 24, 0.5, 0, 240, "%.1f")
          if rv_amp then
            state.img_post_wave_amp = math.max(0, math.min(240, amp2 or 24))
            r.SetExtState(SECTION, "IMG_POST_WAVE_AMP", string.format("%.17g", state.img_post_wave_amp), true)
            changed_post = true
          end
          local rv_len, len2 = ImGui.DragDouble(ctx, "Wave length px##img_post_wave_len", state.img_post_wave_len or 90, 1, 8, 2000, "%.1f")
          if rv_len then
            state.img_post_wave_len = math.max(8, math.min(2000, len2 or 90))
            r.SetExtState(SECTION, "IMG_POST_WAVE_LEN", string.format("%.17g", state.img_post_wave_len), true)
            changed_post = true
          end
          local rv_speed, speed2 = ImGui.DragDouble(ctx, "Wave speed##img_post_wave_speed", state.img_post_wave_speed or 6, 0.05, -20, 20, "%.2f")
          if rv_speed then
            state.img_post_wave_speed = math.max(-20, math.min(20, speed2 or 6))
            r.SetExtState(SECTION, "IMG_POST_WAVE_SPEED", string.format("%.17g", state.img_post_wave_speed), true)
            changed_post = true
          end
        end
        if changed_post then
          state._last_vp_body = nil
          refresh_preview(item)
          overlay_request_autosave()
        end

        wx_tab_leave(t_ty)
      end
    end

    do
      local t_mo = wx_tab_enter("Motion", "Motion — word timing & animation")
      if t_mo then
        if tabs_active then
          ImGui.Spacing(ctx)
        else
          separator_text(ctx, "Motion / animation")
        end

        local changed_anim = false
        ImGui.Text(ctx, "Show words by:")
        ImGui.Spacing(ctx)
        local function pick_timing(mode)
          mode = math.max(0, math.min(2, math.floor(mode or 1)))
          if state.ml_timing_mode ~= mode then
            state.ml_timing_mode = mode
            wx_sync_karaoke_derived()
            changed_anim = true
          end
        end
        if ImGui.RadioButton(ctx, "Whole phrase write-on##wx_tw0", state.ml_timing_mode == 0) then
          pick_timing(0)
        end
        if ImGui.RadioButton(ctx, "Whole phrase visible from phrase start##wx_tw1", state.ml_timing_mode == 1) then
          pick_timing(1)
        end
        if ImGui.RadioButton(ctx, "Single word only##wx_tw2", state.ml_timing_mode == 2) then
          pick_timing(2)
        end

        ImGui.Spacing(ctx)
        local anim_dirty = anim_preset_is_dirty()
        local anim_preset_idx = 0
        for i = 1, #state.anim_preset_names do
          if state.anim_preset_name == state.anim_preset_names[i] then
            anim_preset_idx = i - 1
            break
          end
        end
        -- Preset bar: combo + save + delete on one line
        if #state.anim_preset_names ~= 0 then
          local rv_ap, ap_idx = wx_custom_combo(ctx, "##anim_preset_wx", "Animation preset", anim_preset_idx, table.concat(state.anim_preset_names, "\0") .. "\0", anim_combo_w(ctx, 16, 150), state.wx_slider_style)
          if rv_ap then
            local nm = state.anim_preset_names[(ap_idx or 0) + 1]
            local okp, perr = anim_preset_apply_named(nm)
            if okp then
              changed_anim = true
              state.status = "Loaded animation preset: " .. nm
              state.status_err = false
            else
              state.status = perr or "Could not load animation preset."
              state.status_err = true
            end
          end
          ImGui.SameLine(ctx, 0, 8)
        end
        local save_anim_lbl = anim_dirty and "Save *##anim_preset_savebtn" or "Save##anim_preset_savebtn"
        if wx_custom_button(ctx, save_anim_lbl, 70, 0, state.wx_slider_style) then
          state.anim_preset_save_name = trim(state.anim_preset_name or "")
          if ImGui.OpenPopup then
            ImGui.OpenPopup(ctx, "##anim_save_preset_popup")
          end
        end
        if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx, anim_dirty and "Save animation preset (unsaved changes)" or "Save animation preset")
        end
        if #state.anim_preset_names > 0 and trim(state.anim_preset_name or "") ~= "" then
          ImGui.SameLine(ctx, 0, 6)
          if wx_custom_small_button(ctx, "Delete##anim_preset_delbtn", state.wx_slider_style) then
            local del_name = state.anim_preset_name
            local okd, derr = anim_preset_delete_named(del_name)
            if okd then
              state.status = "Deleted animation preset: " .. del_name
              state.status_err = false
            else
              state.status = derr or "Could not delete animation preset."
              state.status_err = true
            end
          end
          if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, "Delete preset: " .. (state.anim_preset_name or ""))
          end
        end
        if ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##anim_save_preset_popup") then
          ImGui.Text(ctx, "Save animation preset as")
          local rv_anm, anm = ImGui.InputText(ctx, "Name##anim_preset_name", state.anim_preset_save_name or "")
          if rv_anm then
            state.anim_preset_save_name = anm or ""
          end
          if wx_custom_button(ctx, "Save##anim_preset_save", 90, 0, state.wx_slider_style) then
            local okp, perr = anim_preset_save_named(state.anim_preset_save_name or "")
            if okp then
              state.status = "Saved animation preset: " .. trim(state.anim_preset_save_name or "")
              state.status_err = false
              if ImGui.CloseCurrentPopup then
                ImGui.CloseCurrentPopup(ctx)
              end
            else
              state.status = perr or "Could not save animation preset."
              state.status_err = true
            end
          end
          ImGui.SameLine(ctx)
          if wx_custom_button(ctx, "Cancel##anim_preset_cancel", 90, 0, state.wx_slider_style) then
            if ImGui.CloseCurrentPopup then
              ImGui.CloseCurrentPopup(ctx)
            end
          end
          ImGui.EndPopup(ctx)
        end
        local anim_tbl_flags = 0
        if ImGui.TableFlags_SizingStretchProp then
          anim_tbl_flags = anim_tbl_flags | ImGui.TableFlags_SizingStretchProp
        end
        if ImGui.TableFlags_BordersInnerV then
          anim_tbl_flags = anim_tbl_flags | ImGui.TableFlags_BordersInnerV
        end
        if ImGui.TableFlags_RowBg then
          anim_tbl_flags = anim_tbl_flags | ImGui.TableFlags_RowBg
        end
        if ImGui.BeginTable and ImGui.BeginTable(ctx, "##animtbl", 2, anim_tbl_flags) then
          if ImGui.TableSetupColumn then
            local cfix = ImGui.TableColumnFlags_WidthFixed or 0
            local cstr = ImGui.TableColumnFlags_WidthStretch or 0
            ImGui.TableSetupColumn(ctx, "Parameter", cfix, anim_combo_w(ctx, 13, 120))
            ImGui.TableSetupColumn(ctx, "Value", cstr)
          end

          -- Apply to
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.Text(ctx, "Apply to")
          ImGui.TableNextColumn(ctx)
          rv, state.anim_scope = wx_custom_combo(ctx, "##anim_scope", "", state.anim_scope or 0, ANIM_SCOPE_STR, anim_combo_w(ctx, 19, 190), state.wx_slider_style)
          if rv then
            state.anim_scope = math.max(0, math.min(2, state.anim_scope or 0))
            changed_anim = true
          end

          -- Always visible: graphs are per Entry / Exit / Phrase exit (formerly only inside direction-based rows).
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.Text(ctx, "Keyframe curves")
          if ImGui.SetItemTooltip then
            ImGui.SetItemTooltip(ctx, "XY keyframes vs timeline t (Custom + use graph editor). Glow preview while editor is open.")
          end
          ImGui.TableNextColumn(ctx)
          if wx_custom_small_button(ctx, "Entry##anim_curve_editor_in", state.wx_slider_style) then
            anim_graph_open_editor("in")
          end
          if ImGui.SetItemTooltip then
            ImGui.SetItemTooltip(ctx, "Open curve editor for entry animation")
          end
          ImGui.SameLine(ctx, 0, 6)
          if wx_custom_small_button(ctx, "Exit##anim_curve_editor_out", state.wx_slider_style) then
            anim_graph_open_editor("out")
          end
          if ImGui.SetItemTooltip then
            ImGui.SetItemTooltip(ctx, "Open curve editor for exit animation")
          end
          ImGui.SameLine(ctx, 0, 6)
          if wx_custom_small_button(ctx, "Phrase##anim_curve_editor_phrase", state.wx_slider_style) then
            anim_graph_open_editor("phrase_out")
          end
          if ImGui.SetItemTooltip then
            ImGui.SetItemTooltip(ctx, "Open curve editor for phrase exit animation")
          end

          -- Entry row 1: On + Type
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.Text(ctx, "Entry")
          ImGui.TableNextColumn(ctx)
          rv, state.anim_in_on = ImGui.Checkbox(ctx, "On##entry_on", state.anim_in_on)
          if rv then changed_anim = true end
          ImGui.SameLine(ctx, 0, 10)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_in_on) end
          rv, state.anim_in_type = wx_custom_combo(ctx, "##entry_type", "", state.anim_in_type or 0, anim_type_combo_str(), anim_combo_w(ctx, 12, 118), state.wx_slider_style)
          if rv then
            state.anim_in_type = math.max(0, math.min(anim_type_ui_max(), state.anim_in_type or 0))
            if state.anim_in_type == ANIM_KIND.BLUR and (tonumber(state.anim_in_blur) or 0) < 0.05 then
              state.anim_in_blur = 1
            end
            local custom_name = anim_custom_type_name_for_id(state.anim_in_type)
            if custom_name then
              anim_custom_type_apply_named("in", custom_name)
            end
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end

          -- Entry row 2: Curve + dur + amp
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.TableNextColumn(ctx)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_in_on) end
          rv, state.anim_in_curve = wx_custom_combo(ctx, "##entry_curve", "", state.anim_in_curve or 0, ANIM_CURVE_STR, anim_combo_w(ctx, 11, 108), state.wx_slider_style)
          if rv then
            state.anim_in_curve = math.max(0, math.min(ANIM_CURVE_MAX, state.anim_in_curve or 0))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local in_ms = math.floor((tonumber(state.anim_in_dur) or 0.12) * 1000 + 0.5)
          local rv_in_d, in_ms2 = wx_custom_slider_int(ctx, "##entry_dur", "dur", in_ms, 10, 2000, "%d ms", anim_combo_w(ctx, 12, 120), state.wx_slider_style)
          if rv_in_d then
            state.anim_in_dur = math.max(0.01, math.min(2.0, (in_ms2 or in_ms) / 1000))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local in_amp_pct = math.floor((tonumber(state.anim_in_amp) or 1) * 100 + 0.5)
          local rv_in_a, in_amp_pct2 = wx_custom_slider_int(ctx, "##entry_amp", "amp", in_amp_pct, 0, 300, "%d%%", anim_combo_w(ctx, 10, 96), state.wx_slider_style)
          if rv_in_a then
            state.anim_in_amp = math.max(0, math.min(3.0, (in_amp_pct2 or in_amp_pct) / 100))
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
          local _, rv_entry_look = anim_look_row_ui(ctx, "Entry", "in", state.anim_in_on, state.anim_in_type, state.anim_in_curve)
          if rv_entry_look then changed_anim = true end

          -- Exit row 1: On + Type
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.Text(ctx, "Exit")
          ImGui.TableNextColumn(ctx)
          rv, state.anim_out_on = ImGui.Checkbox(ctx, "On##exit_on", state.anim_out_on)
          if rv then changed_anim = true end
          ImGui.SameLine(ctx, 0, 10)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_out_on) end
          rv, state.anim_out_type = wx_custom_combo(ctx, "##exit_type", "", state.anim_out_type or 0, anim_type_combo_str(), anim_combo_w(ctx, 12, 118), state.wx_slider_style)
          if rv then
            state.anim_out_type = math.max(0, math.min(anim_type_ui_max(), state.anim_out_type or 0))
            if state.anim_out_type == ANIM_KIND.BLUR and (tonumber(state.anim_out_blur) or 0) < 0.05 then
              state.anim_out_blur = 1
            end
            local custom_name = anim_custom_type_name_for_id(state.anim_out_type)
            if custom_name then
              anim_custom_type_apply_named("out", custom_name)
            end
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end

          -- Exit row 2: Curve + dur + amp
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.TableNextColumn(ctx)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_out_on) end
          rv, state.anim_out_curve = wx_custom_combo(ctx, "##exit_curve", "", state.anim_out_curve or 0, ANIM_CURVE_STR, anim_combo_w(ctx, 11, 108), state.wx_slider_style)
          if rv then
            state.anim_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, state.anim_out_curve or 0))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local out_ms = math.floor((tonumber(state.anim_out_dur) or 0.12) * 1000 + 0.5)
          local rv_out_d, out_ms2 = wx_custom_slider_int(ctx, "##exit_dur", "dur", out_ms, 10, 2000, "%d ms", anim_combo_w(ctx, 12, 120), state.wx_slider_style)
          if rv_out_d then
            state.anim_out_dur = math.max(0.01, math.min(2.0, (out_ms2 or out_ms) / 1000))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local out_amp_pct = math.floor((tonumber(state.anim_out_amp) or 1) * 100 + 0.5)
          local rv_out_a, out_amp_pct2 = wx_custom_slider_int(ctx, "##exit_amp", "amp", out_amp_pct, 0, 300, "%d%%", anim_combo_w(ctx, 10, 96), state.wx_slider_style)
          if rv_out_a then
            state.anim_out_amp = math.max(0, math.min(3.0, (out_amp_pct2 or out_amp_pct) / 100))
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
          local _, rv_exit_look = anim_look_row_ui(ctx, "Exit", "out", state.anim_out_on, state.anim_out_type, state.anim_out_curve)
          if rv_exit_look then changed_anim = true end

          -- Phrase exit row 1: On + Type
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.Text(ctx, "Phrase exit")
          ImGui.TableNextColumn(ctx)
          rv, state.anim_phrase_out_on = ImGui.Checkbox(ctx, "On##phrase_exit_on", state.anim_phrase_out_on)
          if rv then changed_anim = true end
          if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, "Animate the whole phrase as it exits at phrase end")
          end
          ImGui.SameLine(ctx, 0, 10)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_phrase_out_on) end
          rv, state.anim_phrase_out_type = wx_custom_combo(ctx, "##phrase_exit_type", "", state.anim_phrase_out_type or state.anim_out_type or 0, anim_type_combo_str(), anim_combo_w(ctx, 12, 118), state.wx_slider_style)
          if rv then
            state.anim_phrase_out_type = math.max(0, math.min(anim_type_ui_max(), state.anim_phrase_out_type or 0))
            if state.anim_phrase_out_type == ANIM_KIND.BLUR and (tonumber(state.anim_phrase_out_blur) or 0) < 0.05 then
              state.anim_phrase_out_blur = 1
            end
            local custom_name = anim_custom_type_name_for_id(state.anim_phrase_out_type)
            if custom_name then
              anim_custom_type_apply_named("phrase_out", custom_name)
            end
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end

          -- Phrase exit row 2: Curve + dur + amp
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.TableNextColumn(ctx)
          if ImGui.BeginDisabled then ImGui.BeginDisabled(ctx, not state.anim_phrase_out_on) end
          rv, state.anim_phrase_out_curve = wx_custom_combo(ctx, "##phrase_exit_curve", "", state.anim_phrase_out_curve or 0, ANIM_CURVE_STR, anim_combo_w(ctx, 11, 108), state.wx_slider_style)
          if rv then
            state.anim_phrase_out_curve = math.max(0, math.min(ANIM_CURVE_MAX, state.anim_phrase_out_curve or 0))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local phrase_out_ms = math.floor((tonumber(state.anim_phrase_out_dur) or 0.12) * 1000 + 0.5)
          local rv_phrase_out_d, phrase_out_ms2 = wx_custom_slider_int(ctx, "##phrase_exit_dur", "dur", phrase_out_ms, 10, 2000, "%d ms", anim_combo_w(ctx, 12, 120), state.wx_slider_style)
          if rv_phrase_out_d then
            state.anim_phrase_out_dur = math.max(0.01, math.min(2.0, (phrase_out_ms2 or phrase_out_ms) / 1000))
            changed_anim = true
          end
          ImGui.SameLine(ctx, 0, 8)
          local phrase_out_amp_pct = math.floor((tonumber(state.anim_phrase_out_amp) or 1) * 100 + 0.5)
          local rv_phrase_out_a, phrase_out_amp_pct2 = wx_custom_slider_int(ctx, "##phrase_exit_amp", "amp", phrase_out_amp_pct, 0, 300, "%d%%", anim_combo_w(ctx, 10, 96), state.wx_slider_style)
          if rv_phrase_out_a then
            state.anim_phrase_out_amp = math.max(0, math.min(3.0, (phrase_out_amp_pct2 or phrase_out_amp_pct) / 100))
            changed_anim = true
          end
          if ImGui.EndDisabled then ImGui.EndDisabled(ctx) end
          local _, rv_phrase_exit_look = anim_look_row_ui(ctx, "Phrase exit", "phrase_out", state.anim_phrase_out_on, state.anim_phrase_out_type, state.anim_phrase_out_curve)
          if rv_phrase_exit_look then changed_anim = true end

          ImGui.EndTable(ctx)
        end
        if changed_anim then
          persist_anim_settings_extstate()
          refresh_preview(item)
          overlay_request_autosave()
        end

        --[[ Subtitle draft sliders — hidden; word grid + markers drive layout for triple-stack; re-enable if non-triple presets need tuning in UI.
        ImGui.Spacing(ctx)
        separator_text(ctx, "Subtitle drafting (from markers)")
        rv, state.words_per_line = wx_custom_slider_int(ctx, "##words_per_line_draft", "Words per line (for Draft)", state.words_per_line, 1, 32, "%d", 320, state.wx_slider_style)
        if rv then
          refresh_preview(item)
        end
        rv, state.max_chars = wx_custom_slider_int(ctx, "##max_chars_draft", "Max chars per line — Draft (0 = off)", state.max_chars, 0, 120, "%d", 320, state.wx_slider_style)
        if rv then
          refresh_preview(item)
        end
        rv, state.break_sentence = ImGui.Checkbox(
          ctx,
          "Draft: new line after . ! ? …",
          state.break_sentence
        )
        if rv then
          refresh_preview(item)
        end
        --]]

        wx_tab_leave(t_mo)
      end
    end

    do
      local t_ph = wx_tab_enter("Phrase layout", "Phrase layout — triple-stack")
      if t_ph then
          ImGui.Spacing(ctx)
          separator_text(ctx, "Triple-stack — layout")
          local changed_layout = false
          local ml_dirty = ml_preset_is_dirty()
          local ml_preview = trim(state.ml_preset_name or "")
          if ml_preview == "" then
            ml_preview = "<none>"
          end
          if ml_dirty then
            ml_preview = ml_preview .. " *"
          end
          local ml_preset_idx = 0
          for i = 1, #state.ml_preset_names do
            if state.ml_preset_name == state.ml_preset_names[i] then
              ml_preset_idx = i - 1
              break
            end
          end
          if #state.ml_preset_names ~= 0 then
            local rv_mp, mp_idx = wx_custom_combo(ctx, "##layout_preset_wx", "Layout preset", ml_preset_idx, table.concat(state.ml_preset_names, "\0") .. "\0", 260, state.wx_slider_style)
            if rv_mp then
              local nm = state.ml_preset_names[(mp_idx or 0) + 1]
              local okp, perr = ml_preset_apply_named(nm)
              if okp then
                changed_layout = true
                state.status = "Loaded triple-stack preset: " .. nm
                state.status_err = false
              else
                state.status = perr or "Could not load preset."
                state.status_err = true
              end
            end
          end
          local save_ml_lbl = ml_dirty and "Save layout preset *" or "Save layout preset"
          if wx_custom_button(ctx, save_ml_lbl, 160, 0, state.wx_slider_style) then
            state.ml_preset_save_name = trim(state.ml_preset_name or "")
            if ImGui.OpenPopup then
              ImGui.OpenPopup(ctx, "##ml_save_preset_popup")
            end
          end
          if #state.ml_preset_names > 0 and trim(state.ml_preset_name or "") ~= "" then
            ImGui.SameLine(ctx)
            if wx_custom_small_button(ctx, "Delete layout preset", state.wx_slider_style) then
              local del_name = state.ml_preset_name
              local okd, derr = ml_preset_delete_named(del_name)
              if okd then
                state.status = "Deleted triple-stack preset: " .. del_name
                state.status_err = false
              else
                state.status = derr or "Could not delete preset."
                state.status_err = true
              end
            end
          end
          if ImGui.BeginPopup and ImGui.BeginPopup(ctx, "##ml_save_preset_popup") then
            ImGui.Text(ctx, "Save layout preset as")
            local rv_mln, mln = ImGui.InputText(ctx, "Name##ml_preset_name", state.ml_preset_save_name or "")
            if rv_mln then
              state.ml_preset_save_name = mln or ""
            end
            if wx_custom_button(ctx, "Save##ml_preset_save", 90, 0, state.wx_slider_style) then
              local okp, perr = ml_preset_save_named(state.ml_preset_save_name or "")
              if okp then
                state.status = "Saved triple-stack preset: " .. trim(state.ml_preset_save_name or "")
                state.status_err = false
                if ImGui.CloseCurrentPopup then
                  ImGui.CloseCurrentPopup(ctx)
                end
              else
                state.status = perr or "Could not save preset."
                state.status_err = true
              end
            end
            ImGui.SameLine(ctx)
            if wx_custom_button(ctx, "Cancel##ml_preset_cancel", 90, 0, state.wx_slider_style) then
              if ImGui.CloseCurrentPopup then
                ImGui.CloseCurrentPopup(ctx)
              end
            end
            ImGui.EndPopup(ctx)
          end

          ImGui.Spacing(ctx)
          local tree_flags = (ImGui.TreeNodeFlags_DefaultOpen and ImGui.TreeNodeFlags_DefaultOpen) or 0
          local open_flow
          if tree_flags ~= 0 then
            open_flow = ImGui.TreeNode(ctx, "Flow & wrapping###ml_flow", tree_flags)
          else
            open_flow = ImGui.TreeNode(ctx, "Flow & wrapping###ml_flow")
          end
          if open_flow then
            -- Fit 2–4 controls per row depending on window width (each needs ~190px+ for labels + readout).
            ml_layout_flow_start(ctx, 196)
            local iw
            iw = ml_layout_flow_next_cell(ctx)
            local rv_mr, mr2 = wx_custom_slider_int(ctx, "##mlmr_wx", "Max rows/phrase", state.ml_max_rows, 1, 6, "%d", iw, state.wx_slider_style, nil, nil, nil, true)
            if rv_mr then
              state.ml_max_rows = math.max(1, math.min(6, mr2))
              changed_layout = true
            end
            local gap_pct = math.floor((state.ml_line_gap or 0.1) * 100 + 0.5)
            iw = ml_layout_flow_next_cell(ctx)
            local rv_g, gp2 = wx_custom_slider_int(ctx, "##mlgap", "Line gap (% fontPx)", gap_pct, -95, 50, "%d", iw, state.wx_slider_style)
            if rv_g then
              state.ml_line_gap = math.max(-0.95, math.min(0.5, gp2 / 100))
              changed_layout = true
            end
            local valign_items = "Top\0Middle\0Bottom\0"
            iw = ml_layout_flow_next_cell(ctx)
            local rv_va, va2 = wx_custom_combo(ctx, "##mlva", "Row V-align", state.ml_row_v_align or 0, valign_items, iw, state.wx_slider_style)
            if rv_va then
              state.ml_row_v_align = math.max(0, math.min(2, va2 or 0))
              changed_layout = true
            end
            iw = ml_layout_flow_next_cell(ctx)
            local rv, ch1, rv2, ch2 = wx_custom_slider_int(ctx, "##mlch", "Max chars/row (0=off)", state.ml_row_chars, 0, 200, "%d", iw, state.wx_slider_style, state.ml_row_chars_rand, 80, "± %d")
            if rv then
              state.ml_row_chars = math.max(0, math.min(200, ch1))
              bump_ml_chars_seed()
              changed_layout = true
            end
            if rv2 then
              state.ml_row_chars_rand = math.max(0, math.min(200, ch2))
              bump_ml_chars_seed()
              changed_layout = true
            end
            ImGui.TreePop(ctx)
          end

          local open_indent = ImGui.TreeNode(ctx, "Indent/stagger###ml_indent")
          if open_indent then
            ml_layout_flow_start(ctx, 220)
            local iw = ml_layout_flow_next_cell(ctx)
            local step_pct = math.floor((state.ml_indent_step or 0) * 100 + 0.5)
            local ir_pct = math.floor((state.ml_indent_rand or 0) * 100 + 0.5)
            ir_pct = math.max(0, math.min(25, ir_pct))
            local rv_is, sp2, rv_ir, ir2 = wx_custom_slider_int(ctx, "##mlinds", "Indent step (%×row idx)", step_pct, 0, 50, "%d%%", iw, state.wx_slider_style, ir_pct, 25, "± %d%%")
            if rv_is then
              state.ml_indent_step = math.max(0, math.min(0.5, sp2 / 100))
              bump_ml_indent_seed()
              changed_layout = true
            end
            if rv_ir then
              state.ml_indent_rand = math.max(0, math.min(0.25, ir2 / 100))
              bump_ml_indent_seed()
              changed_layout = true
            end
            ImGui.TreePop(ctx)
          end

          local open_rows = ImGui.TreeNode(ctx, "Per-row size/random###ml_rows")
          if open_rows then
            ml_layout_flow_start(ctx, math.max(260, math.floor(ml_row_slider_w(ctx) * 2.05)))
            for li = 1, 6 do
              local iw = ml_layout_flow_next_cell(ctx)
              ui_ml_row_controls(ctx, item, li, iw)
            end
            ImGui.TreePop(ctx)
          end

          if changed_layout then
            refresh_preview(item)
            overlay_request_autosave()
          end



        wx_tab_leave(t_ph)
      end
    end



    if tabs_active then
      ImGui.EndTabBar(ctx)
    end

    if state.word_grid_floating then
      ImGui.SetNextWindowSize(ctx, 980, 420, ImGui.Cond_FirstUseEver)
      local fvis, fopen = ImGui.Begin(ctx, WINDOW_TITLE .. " — Words", true)
      if fvis then
        if item and words and #words > 0 then
          word_grid_ui(ctx, item, words)
        end
      end
      ImGui.End(ctx)
      if not fopen and state.word_grid_floating then
        state.word_grid_floating = false
        r.SetExtState(SECTION, "WORD_GRID_FLOAT", "0", true)
      end
    end

    ImGui.Separator(ctx)
    refresh_preview(item)
    local autosave_force = state.overlay_autosave_force
    state.overlay_autosave_force = false
    if item and words and #words > 0 then
      ml_sync_editor_text(words)
      local et_ok = editor_text_parse_ok(words, state.editor_text or "")
      if et_ok and auto_persist_layout then
        local sig = overlay_autosave_state_sig(words)
        if autosave_force or sig ~= (state.overlay_autosave_sig_saved or "") then
          auto_persist_layout(item, words, ctx)
        end
      elseif autosave_force then
        state.overlay_autosave_force = true
      end
    elseif autosave_force then
      state.overlay_autosave_force = true
    end

    state.prev_words_count = (words and #words) or 0
    if item and words and #words > 0 then
      ImGui.Text(
        ctx,
        string.format(
          "Marker words: %d   Phrase(s)/line(s): %d   VP segment(s): %d",
          state.preview_words,
          state.preview_lines,
          state.preview_segs
        )
      )
    end

    rv, state.live_gui_vp = ImGui.Checkbox(
      ctx,
      "Live VP (writes VP chunk when idle; no undo per tweak)",
      state.live_gui_vp
    )
    if rv then
      state._last_vp_body = nil
      r.SetExtState(SECTION, "LIVE_GUI_VP", state.live_gui_vp and "1" or "0", true)
      overlay_request_autosave()
    end
    if state.live_gui_vp and item and words and #words > 0 and state.preview_parse_err == "" and state.preview_segs > 0 and live_vp_safe_for_chunk_write(ctx) then
      local ok_live = write_vp_for_item(item, { no_undo = true, skip_refresh = true, skip_if_same = true })
      if ok_live and state.anim_graph_vp_defer_flush then
        state.anim_graph_vp_defer_flush = false
      end
    end

    ImGui.Separator(ctx)
    if state.status ~= "" then
      if state.status_err then
        ImGui.TextColored(ctx, 0x7D7DFFFF, state.status)
      else
        ImGui.TextColored(ctx, 0x8FD18CFF, state.status)
      end
    end

    if wx_custom_button(ctx, "Apply to selected item", 200, 0, state.wx_slider_style) then
      apply_to_selection()
    end
    ImGui.SameLine(ctx)
    if wx_custom_button(ctx, "Save settings", 120, 0, state.wx_slider_style) then
      save_settings()
      overlay_request_autosave()
    end
    ImGui.SameLine(ctx)
    if wx_custom_button(ctx, "Close", 80, 0, state.wx_slider_style) then
      state.should_close = true
    end

    if anim_graph_editor_ui(ctx) then
      persist_anim_settings_extstate()
      refresh_preview(item)
      overlay_request_autosave()
    end
    wx_draw_settings_modal(ctx)
    ImGui.End(ctx)
  end

  if open and not state.should_close then
    r.defer(loop)
  end
  end

  r.defer(loop)
end
