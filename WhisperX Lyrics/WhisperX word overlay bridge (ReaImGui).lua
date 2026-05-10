-- @description WhisperX: word overlay bridge — presets & lines (ReaImGui → Video Processor)
-- @version 1.27
-- @author Bryan
-- @about
--   GUI for the WhisperX Video Processor overlay: subtitle text is taken from take markers only (no free typing).
--   Words: horizontal drag scales size; triple-stack uses ReaImGui drag–drop onto the previous word or “new phrase” (applied on drop). Ctrl+Shift+click makes a word the first of its phrase.
--   Triple-stack: cut zones between words create phrase/row breaks; marquee selection; Shift+click range. Layout auto-saves to item (P_EXT) + extstate.
--   Triple-stack layout parameters can be stored in named presets (save/load/delete).
--   Other line presets still follow the draft sliders below (words per line / max chars / sentence breaks).
--   Phrase/row structure is stored in extstate and synced for the VP core parser.
--   Per-line size & randomize: jitter is stable until you move that row’s Randomize slider; row gap (% of fontPx). Apply/Save writes jitter to extstate for marker-sync.
--   "Re-read markers → VP" refreshes take marker times from the item and rewrites the Video Processor
--   (keeps your subtitle text if it still parses). Checkbox “Live: update Video Processor…” pushes VP on each tweak
--   (no undo per push). Separate action “WhisperX word overlay live VP sync take markers.lua” watches markers.
--   “Save subtitle text to item” stores the editor in the media item’s extended state (P_EXT) so reopening the bridge restores it when it still matches markers.
--   Triple-stack: optional max characters per visual row (UTF-8 length) plus ± range varied per phrase (stable seed until you move those sliders); row indent sliders use their own seed.
--   Requires ReaImGui and "WhisperX word overlay core.lua".

local r = reaper

do
  local t = (r.time_precise and r.time_precise()) or 0
  math.randomseed((math.floor(t * 65536 + (os.clock() or 0) * 1e6)) % 2147483647)
end

local WINDOW_TITLE = "WhisperX — word overlay bridge"
local SECTION = "BRYAN_WX_OVERLAY_UI"
--- Item-extended-state key (survives project save; travels with the item).
local ITEM_EXT_EDITOR = "P_EXT:BRYAN_WX_OVERLAY_EDITOR"

local PRESET_STR =
  "Word — one word at a time\0"
    .. "Line — full line until next line\0"
    .. "Line — build up within line\0"
    .. "Line — triple stack (multi-row phrases)\0"

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

local function preset_id_from_index(idx)
  return W.overlay_preset_from_combo_index(idx)
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
  local ok, s = r.GetSetMediaItemInfo_String(item, ITEM_EXT_EDITOR, "", false)
  if ok and type(s) == "string" and s ~= "" then
    return s
  end
  return nil
end

local function write_editor_text_to_item(item, text)
  if not item or not r.GetSetMediaItemInfo_String then
    return false
  end
  return r.GetSetMediaItemInfo_String(item, ITEM_EXT_EDITOR, text or "", true)
end

local state = {
  preset_idx = tonumber(es_get("PRESET_IDX", "0")) or 0,
  karaoke = es_bool("KARAOKE", true),
  words_per_line = tonumber(es_get("WORDS_PER_LINE", "8")) or 8,
  max_chars = tonumber(es_get("MAX_CHARS", "0")) or 0,
  break_sentence = es_bool("BREAK_SENTENCE", false),
  editor_text = "",
  overlay_source_key = "",
  status = "",
  status_err = false,
  preview_parse_err = "",
  should_close = false,
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
  --- Triple-stack: phrase_after[i] / row_after[i] for i = 1 .. n-1 (after word i). Word scales [1..n] for VP.
  ml_phrase_after = {},
  ml_row_after = {},
  ml_word_scales = {},
  ml_row_indents = {},
  word_sel = {},
  word_anchor = nil,
  marquee_active = false,
  marquee_btn = 0,
  marquee_x0 = 0,
  marquee_y0 = 0,
  marquee_x1 = 0,
  marquee_y1 = 0,
  marquee_additive = false,
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
  --- Pixel height of subtitle multiline field (persisted in extstate).
  editor_body_h = tonumber(es_get("EDITOR_BODY_H", "140")) or 140,
  _wig_rects = {},
  ml_word_n = 0,
  ml_preset_names = {},
  ml_preset_idx = 0,
  ml_preset_name = es_get("ML_PRESET_LAST", ""),
  live_gui_vp = es_bool("LIVE_GUI_VP", false),
  _last_vp_body = nil,
}

if state.preset_idx == 4 then
  state.preset_idx = 3
end
if state.preset_idx < 0 or state.preset_idx > 3 then
  state.preset_idx = 0
end
state.words_per_line = math.max(1, math.min(64, math.floor(state.words_per_line)))
state.max_chars = math.max(0, math.min(500, math.floor(state.max_chars)))
state.word_grid_h = math.max(120, math.min(700, tonumber(state.word_grid_h) or 240))

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

local function display_opts_from_state(words_for_scale)
  local karaoke = state.karaoke and true or false
  if state.preset_idx == 0 then
    karaoke = false
  end
  local ls, lr, jit = {}, {}, {}
  for i = 1, 6 do
    ls[i] = state.ml_s[i]
    lr[i] = state.ml_r[i]
    jit[i] = state.ml_jitter[i]
  end
  local wscale = nil
  if state.preset_idx == 3 and type(words_for_scale) == "table" and #words_for_scale > 0 then
    wscale = {}
    for i = 1, #words_for_scale do
      wscale[i] = state.ml_word_scales[i] or 1
    end
  end
  local row_indent = nil
  if state.preset_idx == 3 and type(words_for_scale) == "table" and #words_for_scale > 0 then
    row_indent = {}
    for i = 1, #words_for_scale do
      row_indent[i] = state.ml_row_indents[i] or 0
    end
  end
  return {
    preset = preset_id_from_index(state.preset_idx),
    words_per_line = state.words_per_line,
    max_chars = state.max_chars,
    break_after_sentence = state.break_sentence,
    editor_text = state.editor_text,
    karaoke = karaoke,
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
  }
end

--- True if `editor_text` parses against current `words` for the active preset.
local function editor_text_parse_ok(words, editor_text)
  if not words or #words == 0 or type(editor_text) ~= "string" then
    return false
  end
  local opts = display_opts_from_state(words)
  local preset = opts.preset
  if preset == W.PRESET_LINE_TRIPLE or preset == W.PRESET_LINE_STAIRS then
    return W.parse_editor_phrases_for_multiline(words, editor_text, opts) and true
  end
  return W.parse_editor_line_groups(words, editor_text) and true
end

local function slider_opts_only()
  return {
    words_per_line = state.words_per_line,
    max_chars = state.max_chars,
    break_after_sentence = state.break_sentence,
  }
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

local function ml_load_for_word_count(n)
  if n < 1 then
    state.ml_phrase_after = {}
    state.ml_row_after = {}
    state.ml_word_scales = {}
    state.ml_row_indents = {}
    return
  end
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
  local old_pa, old_ra, old_sc, old_ind = state.ml_phrase_after, state.ml_row_after, state.ml_word_scales, state.ml_row_indents
  state.ml_phrase_after, state.ml_row_after, state.ml_word_scales, state.ml_row_indents = {}, {}, {}, {}
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
    end
  end
  state.ml_word_n = n
end

local function ml_sync_editor_text(words)
  if not words or #words == 0 then
    state.editor_text = ""
    return
  end
  if state.preset_idx == 3 then
    state.editor_text = W.editor_text_from_ml_after_flags(words, state.ml_phrase_after, state.ml_row_after)
  else
    state.editor_text = W.draft_editor_text_from_sliders(words, slider_opts_only())
  end
end

local function refresh_preview(item)
  state.preview_words = 0
  state.preview_lines = 0
  state.preview_segs = 0
  state.preview_parse_err = ""
  state.parse_hint = nil
  if not item then
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
    local preset = opts.preset
    if preset == W.PRESET_LINE_TRIPLE or preset == W.PRESET_LINE_STAIRS then
      local ph, gerr, ghint = W.parse_editor_phrases_for_multiline(words, state.editor_text, opts)
      state.parse_hint = ghint
      if ph then
        state.preview_lines = #ph
      else
        state.preview_lines = 0
        state.preview_parse_err = gerr or "Invalid editor text."
      end
    else
      local groups, gerr, ghint = W.parse_editor_line_groups(words, state.editor_text)
      state.parse_hint = ghint
      if groups then
        state.preview_lines = #groups
      else
        state.preview_lines = 0
        state.preview_parse_err = gerr or "Invalid editor text."
      end
    end
  else
    local lines = W.split_words_into_lines(words, opts.words_per_line, opts.max_chars, opts.break_after_sentence)
    state.preview_lines = #lines
  end

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

local function word_grid_reset_drag_state()
  state.word_drag_lock = nil
  state.word_drag_acc_x = 0
  state.word_drag_acc_y = 0
end

--- Horizontal drag adjusts word scale (triple: horizontal only; other presets: dominant axis).
local function word_grid_drag_on_word(ctx, item, words, n, wi, triple_preset)
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
      auto_persist_layout(item, words)
    end
  end
end

local function word_grid_show_size_labels(ctx, n)
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
      ImGui.DrawList_AddText(dl, R[1], R[4] + 2, 0xFFFFFFFF, tostring(pct) .. "%")
    end
  end
end

local function word_grid_cut_zone(ctx, item, words, n, wi, bh)
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
      auto_persist_layout(item, words)
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
      ImGui.DrawList_AddLine(dl, x, y0, x, y1, 0x66CCFFFF, 2)
    end
  end
  ImGui.PopID(ctx)
  ImGui.SameLine(ctx, 0, 0)
end

local function word_grid_row_indent_handle(ctx, item, words, row_start_w, bh, row_sc)
  if row_start_w < 1 then
    return
  end
  row_sc = tonumber(row_sc) or 1
  ImGui.PushID(ctx, row_start_w + 940000)
  local sz = math.max(18, tonumber(bh) or 20)
  local v = tonumber(state.ml_row_indents[row_start_w]) or 0
  local pushed_pad = false
  if ImGui.PushStyleVar and ImGui.StyleVar_FramePadding then
    local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
    -- Match this row’s word button height: Button uses explicit bh ≈ font + 2*py (frame).
    local py = (sz - fs) * 0.5
    if py < 0.5 then
      py = 0.5
    end
    local px = math.max(2, 4 * row_sc)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, px, py)
    pushed_pad = true
  end
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, sz)
  end
  local rv, v2 = ImGui.DragDouble(ctx, "##rowindent", v, 0.005, -0.5, 0.5, "%.2f")
  if rv then
    state.ml_row_indents[row_start_w] = math.max(-0.5, math.min(0.5, tonumber(v2) or 0))
    ml_sync_editor_text(words)
    refresh_preview(item)
    if auto_persist_layout then
      auto_persist_layout(item, words)
    end
  end
  if pushed_pad and ImGui.PopStyleVar then
    ImGui.PopStyleVar(ctx)
  end
  if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) and ImGui.SetTooltip then
    ImGui.SetTooltip(ctx, ("Row indent: %.2f project width\nDrag left/right; negative = further left."):format(state.ml_row_indents[row_start_w] or 0))
  end
  ImGui.PopID(ctx)
  ImGui.SameLine(ctx, 0, 4)
end

local function separator_text(ctx, label)
  if ImGui.SeparatorText then
    ImGui.SeparatorText(ctx, label)
  else
    ImGui.Spacing(ctx)
    ImGui.Text(ctx, label)
    ImGui.Separator(ctx)
  end
end

local function word_grid_ui(ctx, item, words)
  if not words or #words == 0 then
    return
  end
  local n = #words
  state._wig_rects = {}
  separator_text(ctx, "Words (take markers)")
  ImGui.TextWrapped(
    ctx,
    "Text always matches markers. Triple-stack: hover/click the thin zones between words to cut phrases; Alt+click a cut zone cuts a row. Ctrl+Shift+click makes a word first in phrase. "
      .. "Drag words onto the previous/next word or the “new phrase” strip to move phrase boundaries (drop applies on release). "
      .. "Drag horizontally on a word to scale size. Right-drag to box-select multiple words. Layout auto-saves."
  )
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
  local mx, my = ImGui.GetMousePos(ctx)
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
  if not state.marquee_active and ImGui.IsWindowHovered and ImGui.IsWindowHovered(ctx) and ImGui.IsMouseDown and ImGui.IsMouseDown(ctx, MOUSE_RIGHT) then
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
  if state.preset_idx == 3 then
    local phrases = ml_phrase_ranges(n)
    for pi = 1, #phrases do
      local ps, pe = phrases[pi][1], phrases[pi][2]
      ImGui.BeginGroup(ctx)
      if ImGui.TextColored then
        ImGui.TextColored(ctx, 0x888888FF, ("Phrase %d"):format(pi))
      else
        ImGui.Text(ctx, ("Phrase %d"):format(pi))
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
        word_grid_row_indent_handle(ctx, item, words, ra, row_line_h, row_sc)
        for wi = ra, rb do
            if wi > ra then
              ImGui.SameLine(ctx, 0, 4)
            end
            ImGui.PushID(ctx, wi + 910000)
            local sc = state.ml_word_scales[wi] or 1
            local wtxt = tostring(words[wi].w or "")
            if #wtxt > 24 then
              wtxt = wtxt:sub(1, 21) .. "..."
            end
            local bw = math.max(28, math.floor(#(words[wi].w or "") * 7 * sc + 16))
            local bh = math.max(20, math.floor(18 * sc + 6))
            local pushed_var = false
            if ImGui.PushStyleVar and ImGui.StyleVar_FramePadding then
              ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4 * sc, 3 * sc)
              pushed_var = true
            end
            local pushed_color = false
            if state.word_sel[wi] and ImGui.PushStyleColor and ImGui.Col_Button then
              ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x5555AAFF)
              pushed_color = true
            end
            if ImGui.Button(ctx, wtxt .. "##w", bw, bh) then
              if state.preset_idx == 3 and overlay_mod_ctrl_shift(ctx) then
                if ml_make_word_phrase_start(wi, n) then
                  ml_sync_editor_text(words)
                  refresh_preview(item)
                  if auto_persist_layout then
                    auto_persist_layout(item, words)
                  end
                end
              elseif state.preset_idx == 3 and overlay_mod_ctrl(ctx) then
                ml_ctrl_phrase(wi, n)
                ml_sync_editor_text(words)
                refresh_preview(item)
                if auto_persist_layout then
                  auto_persist_layout(item, words)
                end
              elseif state.preset_idx == 3 and overlay_mod_alt(ctx) then
                ml_alt_row(wi, n)
                ml_sync_editor_text(words)
                refresh_preview(item)
                if auto_persist_layout then
                  auto_persist_layout(item, words)
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
                    auto_persist_layout(item, words)
                  end
                end
              end
              ImGui.EndDragDropTarget(ctx)
            end
            if pushed_color and ImGui.PopStyleColor then
              ImGui.PopStyleColor(ctx)
            end
            if pushed_var and ImGui.PopStyleVar and ImGui.StyleVar_FramePadding then
              ImGui.PopStyleVar(ctx)
            end
            if ImGui.IsItemHovered and ImGui.IsItemHovered(ctx) then
              if ImGui.SetTooltip then
                ImGui.SetTooltip(ctx, (words[wi].w or "") .. "\nDrag: reposition · H-drag: size · Ctrl/Cmd+Shift: phrase start")
              end
            end
            if wi < rb then
              word_grid_cut_zone(ctx, item, words, n, wi, bh)
            end
            ImGui.PopID(ctx)
          end
        ImGui.EndGroup(ctx)
        if ri < #rows then
          ImGui.Dummy(ctx, 0, 1)
        end
      end
      ImGui.EndGroup(ctx)
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
            auto_persist_layout(item, words)
          end
        end
      end
      ImGui.EndDragDropTarget(ctx)
    end
  else
      ImGui.BeginGroup(ctx)
      for wi = 1, n do
        if wi > 1 then
          ImGui.SameLine(ctx, 0, 4)
        end
        ImGui.PushID(ctx, wi + 920000)
        local sc = state.ml_word_scales[wi] or 1
        local wtxt = tostring(words[wi].w or "")
        if #wtxt > 20 then
          wtxt = wtxt:sub(1, 17) .. "..."
        end
        local bw = math.max(28, math.floor(#(words[wi].w or "") * 7 * sc + 12))
        local bh = math.max(20, math.floor(18 * sc + 4))
        if ImGui.Button(ctx, wtxt .. "##w2", bw, bh) then
          if overlay_mod_shift(ctx) and state.word_anchor then
            local a, b = state.word_anchor, wi
            if a > b then
              a, b = b, a
            end
            state.word_sel = {}
            for j = a, b do
              state.word_sel[j] = true
            end
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
        word_grid_drag_on_word(ctx, item, words, n, wi, false)
        ImGui.PopID(ctx)
      end
      ImGui.EndGroup(ctx)
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
      ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x4488FF44)
      if ImGui.DrawList_AddRect then
        ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, 0x88AAFFFF)
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
local function draw_parse_hint(ctx, hint)
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

local function save_settings()
  r.SetExtState(SECTION, "PRESET_IDX", tostring(state.preset_idx), true)
  r.SetExtState(SECTION, "KARAOKE", state.karaoke and "1" or "0", true)
  r.SetExtState(SECTION, "WORDS_PER_LINE", tostring(state.words_per_line), true)
  r.SetExtState(SECTION, "MAX_CHARS", tostring(state.max_chars), true)
  r.SetExtState(SECTION, "BREAK_SENTENCE", state.break_sentence and "1" or "0", true)
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
  r.SetExtState(SECTION, "EDITOR_BODY_H", tostring(math.floor((state.editor_body_h or 140) + 0.5)), true)
  r.SetExtState(SECTION, "EDITOR_TEXT", state.editor_text or "", true)
  r.SetExtState(SECTION, "ML_PRESET_LAST", state.ml_preset_name or "", true)
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
  state.status = "Settings saved to extstate " .. SECTION .. "."
  state.status_err = false
end

local function write_vp_for_item(item, live_opts)
  live_opts = live_opts or {}
  local no_undo = live_opts.no_undo == true
  local skip_refresh = live_opts.skip_refresh == true
  local skip_if_same = live_opts.skip_if_same == true

  local take, words, take_was_switched = W.find_take_and_wx_words(item)
  if not take then
    return false, "No take on the selected item."
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
  r.SetExtState(SECTION, "EDITOR_TEXT", state.editor_text or "", true)
  local pr = opts.preset
  if pr == W.PRESET_LINE_TRIPLE or pr == W.PRESET_LINE_STAIRS then
    persist_ml_jitter()
    r.SetExtState(SECTION, "ML_INDENT_STEP", string.format("%.17g", state.ml_indent_step), true)
    r.SetExtState(SECTION, "ML_INDENT_RAND", string.format("%.17g", state.ml_indent_rand), true)
    r.SetExtState(SECTION, "ML_INDENT_SEED", string.format("%.17g", state.ml_indent_seed), true)
  end

  r.UpdateArrange()
  if not no_undo then
    r.Undo_EndBlock("WhisperX word overlay (bridge)", -1)
  end
  if not skip_refresh then
    refresh_preview(item)
  end
  return true, nil
end

auto_persist_layout = function(item, words)
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
  end
  if r.MarkProjectDirty then
    r.MarkProjectDirty(0)
  end
  refresh_preview(item)
  if state.live_gui_vp and state.preview_parse_err == "" and state.preview_segs > 0 then
    write_vp_for_item(item, { no_undo = true, skip_refresh = true, skip_if_same = true })
  end
end

local function apply_to_selection()
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
local function refresh_markers_and_apply(item)
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
  ml_load_for_word_count(#words)
  ml_sync_editor_text(words)
  local opts_chk = display_opts_from_state(words)
  local preset_chk = opts_chk.preset
  local parsed_ok
  if preset_chk == W.PRESET_LINE_TRIPLE or preset_chk == W.PRESET_LINE_STAIRS then
    parsed_ok = W.parse_editor_phrases_for_multiline(words, state.editor_text or "", opts_chk)
  else
    parsed_ok = W.parse_editor_line_groups(words, state.editor_text or "")
  end
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
local function ml_row_slider_w(ctx)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  return math.max(72, math.floor(fs * 7.8))
end

--- Main tri-stack parameter sliders: cap width so panels stay dense.
local function ml_stack_param_item_w(ctx)
  local fs = (ImGui.GetFontSize and ImGui.GetFontSize(ctx)) or 13
  local avail = (ImGui.GetContentRegionAvail and ImGui.GetContentRegionAvail(ctx)) or 400
  return math.max(fs * 12, math.min(fs * 18, avail * 0.58))
end

--- One row index `li` (1..6): size + randomize on one line; moving Randomize respawns that row’s jitter only.
local function ui_ml_row_controls(ctx, item, li)
  ImGui.PushID(ctx, li * 137 + 8000)
  if ImGui.AlignTextToFramePadding then
    ImGui.AlignTextToFramePadding(ctx)
  end
  ImGui.Text(ctx, string.format("Row %d", li))
  ImGui.SameLine(ctx, 0, 5)
  local changed = false
  local sw = ml_row_slider_w(ctx)
  if ImGui.PushItemWidth then
    ImGui.PushItemWidth(ctx, sw)
  end
  local pct = math.floor((state.ml_s[li] or 1) * 100 + 0.5)
  local rv2, pct2 = ImGui.SliderInt(ctx, "Size %##mlsz", pct, 12, 300)
  if rv2 then
    state.ml_s[li] = math.max(0.12, math.min(3, pct2 / 100))
    changed = true
  end
  if ImGui.PopItemWidth then
    ImGui.PopItemWidth(ctx)
  end
  if ImGui.SetItemTooltip then
    ImGui.SetItemTooltip(ctx, "Size for this row as % of Video Processor fontPx.")
  end
  ImGui.SameLine(ctx, 0, 4)
  if ImGui.PushItemWidth then
    ImGui.PushItemWidth(ctx, sw)
  end
  local rp = math.floor((state.ml_r[li] or 0) * 100 + 0.5)
  local rv3, rp2 = ImGui.SliderInt(ctx, "±##mlr", rp, 0, 100)
  if rv3 then
    state.ml_r[li] = math.max(0, math.min(1, rp2 / 100))
    state.ml_jitter[li] = math.random() * 2 - 1
    persist_ml_jitter()
    changed = true
  end
  if ImGui.PopItemWidth then
    ImGui.PopItemWidth(ctx)
  end
  if ImGui.SetItemTooltip then
    ImGui.SetItemTooltip(ctx, "Randomize ± span for this row’s size (stable until you move this).")
  end
  ImGui.PopID(ctx)
  if changed then
    refresh_preview(item)
  end
end

local ctx = ImGui.CreateContext(WINDOW_TITLE)

local function loop()
  local flags = ImGui.WindowFlags_NoCollapse
  ImGui.SetNextWindowSize(ctx, 620, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true, flags)
  if visible then
    local item = nil
    if r.CountSelectedMediaItems(0) == 1 then
      item = r.GetSelectedMediaItem(0, 0)
    end

    local take, words = nil, {}
    if item then
      take, words = W.find_take_and_wx_words(item)
    end

    do
      local hint =
        "Displayed text always matches take markers (left-to-right timing). Grave accents in marker names are ignored when matching."
      if state.preset_idx == 3 then
        hint = hint
          .. " Triple-stack: phrase and row breaks are chosen in the word grid (Ctrl / Alt + click), not typed."
      else
        hint = hint
          .. " Line presets use the draft sliders below for how markers are grouped into lines."
      end
      if words and #words > 0 and W.words_use_cjk_compact_join(words) then
        hint = hint .. " CJK: words concatenate without spaces inside a row."
      else
        hint = hint .. " Latin: spaces are inserted between words inside a row."
      end
      ImGui.TextWrapped(ctx, hint)
    end
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
      if words and #words > 0 then
        local same_item = (guid ~= "" and guid == state.tracked_item_guid)
        if state.preset_idx == 3 and same_item and (state.ml_word_n or 0) > 0 then
          ml_preserve_layout_for_new_count(#words)
        else
          ml_load_for_word_count(#words)
        end
        if state.preset_idx == 3 then
          ml_sync_editor_text(words)
        else
          local saved = read_editor_text_from_item(item)
          if saved and editor_text_parse_ok(words, saved) then
            state.editor_text = saved
          else
            ml_sync_editor_text(words)
          end
        end
        state.tracked_item_guid = guid
      else
        state.editor_text = ""
        state.tracked_item_guid = guid
      end
    end

    if item and words and #words > 0 then
      local rv_float, v_float = ImGui.Checkbox(ctx, "Float words panel", state.word_grid_floating)
      if rv_float then
        state.word_grid_floating = v_float and true or false
        r.SetExtState(SECTION, "WORD_GRID_FLOAT", state.word_grid_floating and "1" or "0", true)
      end
      if not state.word_grid_floating then
        word_grid_ui(ctx, item, words)
      end
    end

    if state.word_grid_floating then
      ImGui.SetNextWindowSize(ctx, 980, 420, ImGui.Cond_FirstUseEver)
      local fvis, fopen = ImGui.Begin(ctx, WINDOW_TITLE .. " — Words", true)
      if fvis then
        if item and words and #words > 0 then
          word_grid_ui(ctx, item, words)
        else
          ImGui.TextColored(ctx, 0x888888FF, "Select one item with take markers to view words.")
        end
      end
      ImGui.End(ctx)
      if not fopen and state.word_grid_floating then
        state.word_grid_floating = false
        r.SetExtState(SECTION, "WORD_GRID_FLOAT", "0", true)
      end
    end

    if ImGui.Button(ctx, "Save layout to item", 200, 0) then
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
          state.status = "Layout saved on item (P_EXT) + bridge extstate (phrases/rows/scales)."
          state.status_err = false
        else
          state.status = "Could not write extended state on this item (REAPER too old?)."
          state.status_err = true
        end
        r.Undo_EndBlock("WhisperX: save layout to item", -1)
      end
    end
    ImGui.TextColored(
      ctx,
      0x888888FF,
      "Word drags (phrase/size) auto-save subtitle + triple bits to the item (P_EXT) and ML_* to bridge extstate. This button also saves all other bridge settings (sliders, karaoke, etc.)."
    )

    if ImGui.Button(ctx, "Reset triple phrase/row", 200, 0) then
      if item and words and #words > 0 and state.preset_idx == 3 then
        for i = 1, math.max(0, #words - 1) do
          state.ml_phrase_after[i] = false
          state.ml_row_after[i] = false
        end
        for i = 1, #words do
          state.ml_word_scales[i] = 1
        end
        ml_sync_editor_text(words)
        refresh_preview(item)
        if auto_persist_layout then
          auto_persist_layout(item, words)
        end
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Re-read markers → VP", 200, 0) then
      refresh_markers_and_apply(item)
    end
    if state.preset_idx ~= 3 then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Draft line breaks from sliders", 220, 0) then
        if words and #words > 0 then
          ml_sync_editor_text(words)
          refresh_preview(item)
        end
      end
    end

    if state.preview_parse_err ~= "" then
      ImGui.TextColored(ctx, 0x7D7DFFFF, state.preview_parse_err)
      if state.parse_hint then
        ImGui.Spacing(ctx)
        draw_parse_hint(ctx, state.parse_hint)
      end
    end

    ImGui.Separator(ctx)
    local rv
    rv, state.preset_idx = ImGui.Combo(ctx, "Preset", state.preset_idx, PRESET_STR)
    if rv then
      if words and #words > 0 then
        ml_load_for_word_count(#words)
        ml_sync_editor_text(words)
      end
      refresh_preview(item)
    end
    if state.preset_idx == 0 then
      ImGui.TextColored(ctx, 0x888888FF, "Each token appears alone for its marker’s duration (newlines act like spaces here).")
    elseif state.preset_idx == 1 then
      ImGui.TextColored(
        ctx,
        0x888888FF,
        "Each non-empty text line stays on screen from its first word’s time until the next line’s first word."
      )
    elseif state.preset_idx == 2 then
      ImGui.TextColored(
        ctx,
        0x888888FF,
        "Within each text line, caption grows token-by-token until the line’s end time."
      )
    elseif state.preset_idx == 3 then
      ImGui.TextColored(
        ctx,
        0x888888FF,
        "Stacked rows per phrase (Enter = phrase, | = row). Base size = VP fontPx; use the section below for gaps, row indent, and per-row size/randomize."
      )
    end

    if ImGui.BeginDisabled and state.preset_idx == 0 then
      ImGui.BeginDisabled(ctx, true)
    end
    rv, state.karaoke = ImGui.Checkbox(ctx, "Karaoke-style (dim → bright by row / within line)", state.karaoke)
    if ImGui.EndDisabled and state.preset_idx == 0 then
      ImGui.EndDisabled(ctx)
    end
    if rv then
      refresh_preview(item)
    end
    if state.preset_idx ~= 0 then
      ImGui.TextColored(
        ctx,
        0x666666FF,
        "When off: Line Full shows whole lines; Line Grow holds one static line. When on: Full grows like karaoke; Grow keeps grow. Triple-stack + karaoke: each row grows word-by-word at marker times; lower rows stay dim until the row above has finished, then brighten."
      )
    end

    ImGui.Spacing(ctx)
    separator_text(ctx, "Subtitle drafting (from markers)")
    rv, state.words_per_line = ImGui.SliderInt(ctx, "Words per line (for Draft)", state.words_per_line, 1, 32)
    if rv then
      refresh_preview(item)
    end
    rv, state.max_chars = ImGui.SliderInt(ctx, "Max chars per line — Draft (0 = off)", state.max_chars, 0, 120)
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

    if state.preset_idx == 3 then
      ImGui.Spacing(ctx)
      separator_text(ctx, "Triple-stack — layout")
      local changed_layout = false
      ImGui.TextColored(ctx, 0x888888FF, "Layout presets")
      local combo_items = ml_preset_combo_str()
      local rv_pcombo, new_idx = ImGui.Combo(ctx, "Preset", state.ml_preset_idx or 0, combo_items)
      if rv_pcombo and #state.ml_preset_names > 0 then
        state.ml_preset_idx = math.max(0, math.min(#state.ml_preset_names - 1, new_idx))
        state.ml_preset_name = state.ml_preset_names[state.ml_preset_idx + 1] or ""
        r.SetExtState(SECTION, "ML_PRESET_LAST", state.ml_preset_name or "", true)
      end
      ImGui.SameLine(ctx)
      local rv_pname, pname = ImGui.InputText(ctx, "Preset name", state.ml_preset_name or "")
      if rv_pname then
        state.ml_preset_name = trim(pname or "")
      end
      if ImGui.Button(ctx, "Save preset", 110, 0) then
        local nm = trim(state.ml_preset_name or "")
        if nm == "" then
          state.status = "Preset name is empty."
          state.status_err = true
        else
          local key = ml_preset_key(nm)
          r.SetExtState(SECTION, key, ml_preset_pack_current(), true)
          local idx = ml_preset_find_idx(nm)
          if not idx then
            state.ml_preset_names[#state.ml_preset_names + 1] = nm
            table.sort(state.ml_preset_names)
            ml_preset_names_save()
            idx = ml_preset_find_idx(nm)
          end
          state.ml_preset_idx = math.max(0, (idx or 1) - 1)
          state.ml_preset_name = nm
          r.SetExtState(SECTION, "ML_PRESET_LAST", nm, true)
          state.status = "Saved triple-stack preset: " .. nm
          state.status_err = false
        end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Load preset", 110, 0) then
        local nm = trim(state.ml_preset_name or "")
        local blob = (nm ~= "") and es_get(ml_preset_key(nm), "") or ""
        if blob == "" then
          state.status = "Preset not found: " .. (nm == "" and "<empty>" or nm)
          state.status_err = true
        else
          local okp, perr = ml_preset_apply_blob(blob)
          if okp then
            refresh_preview(item)
            state.status = "Loaded triple-stack preset: " .. nm
            state.status_err = false
            r.SetExtState(SECTION, "ML_PRESET_LAST", nm, true)
          else
            state.status = perr or "Could not load preset."
            state.status_err = true
          end
        end
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Delete preset", 120, 0) then
        local nm = trim(state.ml_preset_name or "")
        if nm == "" then
          state.status = "Preset name is empty."
          state.status_err = true
        else
          local idx = ml_preset_find_idx(nm)
          if idx then
            table.remove(state.ml_preset_names, idx)
            ml_preset_names_save()
          end
          r.SetExtState(SECTION, ml_preset_key(nm), "", true)
          if #state.ml_preset_names > 0 then
            state.ml_preset_idx = 0
            state.ml_preset_name = state.ml_preset_names[1]
          else
            state.ml_preset_idx = 0
            state.ml_preset_name = ""
          end
          r.SetExtState(SECTION, "ML_PRESET_LAST", state.ml_preset_name or "", true)
          state.status = "Deleted triple-stack preset: " .. nm
          state.status_err = false
        end
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
        local _mw_pushed = false
        if ImGui.PushItemWidth then
          ImGui.PushItemWidth(ctx, ml_stack_param_item_w(ctx))
          _mw_pushed = true
        end
        rv, state.ml_max_rows = ImGui.SliderInt(ctx, "Max rows/phrase##mlmr", state.ml_max_rows, 1, 6)
        if rv then
          state.ml_max_rows = math.max(1, math.min(6, state.ml_max_rows))
          changed_layout = true
        end
        local gap_pct = math.floor((state.ml_line_gap or 0.1) * 100 + 0.5)
        local rv_g, gp2 = ImGui.SliderInt(ctx, "Line gap (% fontPx)##mlgap", gap_pct, -95, 50)
        if rv_g then
          state.ml_line_gap = math.max(-0.95, math.min(0.5, gp2 / 100))
          changed_layout = true
        end
        local valign_items = "Top\0Middle\0Bottom\0"
        local rv_va, va2 = ImGui.Combo(ctx, "Row V-align##mlva", state.ml_row_v_align or 0, valign_items)
        if rv_va then
          state.ml_row_v_align = math.max(0, math.min(2, va2 or 0))
          changed_layout = true
        end
        rv, state.ml_row_chars = ImGui.SliderInt(ctx, "Max chars/row (0=off)##mlch", state.ml_row_chars, 0, 200)
        if rv then
          state.ml_row_chars = math.max(0, math.min(200, state.ml_row_chars))
          bump_ml_chars_seed()
          changed_layout = true
        end
        if ImGui.BeginDisabled and state.ml_row_chars <= 0 then
          ImGui.BeginDisabled(ctx, true)
        end
        rv, state.ml_row_chars_rand = ImGui.SliderInt(ctx, "± rand row chars##mlchr", state.ml_row_chars_rand, 0, 80)
        if rv then
          state.ml_row_chars_rand = math.max(0, math.min(200, state.ml_row_chars_rand))
          bump_ml_chars_seed()
          changed_layout = true
        end
        if ImGui.EndDisabled and state.ml_row_chars <= 0 then
          ImGui.EndDisabled(ctx)
        end
        if _mw_pushed and ImGui.PopItemWidth then
          ImGui.PopItemWidth(ctx)
        end
        ImGui.TreePop(ctx)
      end

      local open_indent = ImGui.TreeNode(ctx, "Indent/stagger###ml_indent")
      if open_indent then
        local _ind_pushed = false
        if ImGui.PushItemWidth then
          ImGui.PushItemWidth(ctx, ml_stack_param_item_w(ctx))
          _ind_pushed = true
        end
        local step_pct = math.floor((state.ml_indent_step or 0) * 100 + 0.5)
        local rv_is, sp2 =
          ImGui.SliderInt(ctx, "Indent step (%×row idx)##mlinds", step_pct, 0, 50)
        if rv_is then
          state.ml_indent_step = math.max(0, math.min(0.5, sp2 / 100))
          bump_ml_indent_seed()
          changed_layout = true
        end
        local ir_pct = math.floor((state.ml_indent_rand or 0) * 100 + 0.5)
        ir_pct = math.max(0, math.min(25, ir_pct))
        local rv_ir, ir2 = ImGui.SliderInt(ctx, "± rand indent (phrase)##mlinr", ir_pct, 0, 25)
        if rv_ir then
          state.ml_indent_rand = math.max(0, math.min(0.25, ir2 / 100))
          bump_ml_indent_seed()
          changed_layout = true
        end
        if _ind_pushed and ImGui.PopItemWidth then
          ImGui.PopItemWidth(ctx)
        end
        ImGui.TreePop(ctx)
      end

      local open_rows = ImGui.TreeNode(ctx, "Per-row size/random###ml_rows")
      if open_rows then
        for li = 1, 6 do
          ui_ml_row_controls(ctx, item, li)
        end
        ImGui.TreePop(ctx)
      end

      if changed_layout then
        refresh_preview(item)
      end

      ImGui.Spacing(ctx)
      ImGui.TextColored(
        ctx,
        0x666666FF,
        "Tip: Save a few presets (compact, staggered, large) and switch quickly while previewing."
      )
    end

    ImGui.Separator(ctx)
    refresh_preview(item)
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
    else
      ImGui.TextColored(ctx, 0x888888FF, "Select one item with take markers to edit and preview.")
    end

    rv, state.live_gui_vp = ImGui.Checkbox(
      ctx,
      "Live: update Video Processor while tweaking (no undo per tweak; subtitle saved to extstate for marker-sync script)",
      state.live_gui_vp
    )
    if rv then
      state._last_vp_body = nil
      r.SetExtState(SECTION, "LIVE_GUI_VP", state.live_gui_vp and "1" or "0", true)
    end
    if state.live_gui_vp and item and words and #words > 0 and state.preview_parse_err == "" and state.preview_segs > 0 then
      write_vp_for_item(item, { no_undo = true, skip_refresh = true, skip_if_same = true })
    end

    ImGui.Separator(ctx)
    if state.status ~= "" then
      if state.status_err then
        ImGui.TextColored(ctx, 0x7D7DFFFF, state.status)
      else
        ImGui.TextColored(ctx, 0x8FD18CFF, state.status)
      end
    end

    if ImGui.Button(ctx, "Apply to selected item", 200, 0) then
      apply_to_selection()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save settings", 120, 0) then
      save_settings()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Close", 80, 0) then
      state.should_close = true
    end

    ImGui.End(ctx)
  end

  if open and not state.should_close then
    r.defer(loop)
  end
end

r.defer(loop)
