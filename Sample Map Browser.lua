-- @description Sample Map Browser (Lua + ReaImGui)
-- @version 0.1.0
-- @author bryan
-- @about Scans user folders for audio files, derives simple metadata, and shows an interactive 2D map where each file is a dot. Click a dot to preview the file.
-- @requires ReaImGui

local r = reaper

-- Check for ReaImGui
if not r.APIExists('ImGui_GetVersion') then
  r.ShowMessageBox("ReaImGui is required for this script.", "Missing dependency", 0)
  return
end

-- Check for JS_ReaScriptAPI (optional but recommended for folder browsing)
if not r.APIExists("JS_Dialog_BrowseForFolder") then
  r.ShowMessageBox("JS_ReaScriptAPI extension is recommended for folder browsing.\n\nInstall via: Extensions > ReaPack > Browse Packages > Search 'js_ReaScriptAPI'\n\nYou can still use the script, but folder selection will be limited.", "Extension Recommended", 0)
end

-- --- Script state ------------------------------------------------------------
local SCRIPT_NAME = "Sample Map Browser"
local SCRIPT_DIR = r.GetResourcePath() .. "/Scripts/BRYAN's SCRIPTS"
local CONFIG_DIR = SCRIPT_DIR
local CONFIG_PATH = CONFIG_DIR .. "/SampleMapBrowser.json"
local DATA_PATH = SCRIPT_DIR .. "/SampleMapData.json"  -- Cached sample index
PROJ_EXT_SECTION = "SampleMapBrowser"
PROJ_EXT_KEY_SEQUENCER = "SequencerStateV1"

local AUDIO_EXTS = {
  [".wav"] = true, [".wave"] = true, [".aif"] = true, [".aiff"] = true,
  [".flac"] = true, [".mp3"] = true, [".ogg"] = true, [".m4a"] = true, [".wv"] = true
}

-- Common tag keywords (ordered by priority for tagging)
local TAG_KEYWORDS = {
  {tag = "kick",   keys = {"kick", "kck"}, weight = 100},
  {tag = "snare",  keys = {"snare", "snr"}, weight = 95},
  {tag = "clap",   keys = {"clap"}, weight = 92},
  {tag = "snap",   keys = {"snap", "finger", "finger snap", "finger snaps", "fingersnap", "fingersnaps"}, weight = 91},
  {tag = "rim",    keys = {"rim", "rimshot"}, weight = 90},
  {tag = "hat",    keys = {"hat", "hihat", "oh", "ch", "hh"}, weight = 88},
  {tag = "tom",    keys = {"tom"}, weight = 82},
  {tag = "ride",   keys = {"ride"}, weight = 80},
  {tag = "crash",  keys = {"crash", "cymbal"}, weight = 79},
  {tag = "perc",   keys = {"perc", "percussion", "shaker", "tamb", "cowbell"}, weight = 76},
  {tag = "fx",     keys = {"fx", "sfx", "impact", "whoosh", "sweep", "riser", "uplift", "downlift"}, weight = 74},
  {tag = "bass",   keys = {"bass", "sub"}, weight = 70},
  {tag = "808",    keys = {"808"}, weight = 69},
  {tag = "vocal",  keys = {"vocal", "vox", "voice"}, weight = 65},
  {tag = "drum",   keys = {"drum", "beat", "break"}, weight = 58},
  {tag = "pad",    keys = {"pad"}, weight = 55},
  {tag = "lead",   keys = {"lead"}, weight = 54},
  {tag = "pluck",  keys = {"pluck"}, weight = 53},
  {tag = "keys",   keys = {"keys", "piano"}, weight = 52},
  {tag = "guitar", keys = {"guitar"}, weight = 50},
}

local state = {
  folders = {},
  samples = {},
  scan_queue = {},
  scan_started = 0.0,
  scan_total = 0,
  scanned_paths = {},  -- Set of already-scanned file paths (for resuming)
  selected = nil,
  filter = "",
  active_tags = {},      -- Tag filters toggled by the user
  tag_list = {},         -- Cached sorted list of tags with counts
  tag_counts = {},       -- Map<tag,count>
  scan_logs = {},        -- Rolling buffer of scan/analyzer logs
  map_seed = 1337,
  zoom = 1.0,  -- Zoom level (1.0 = normal)
  pan_x = 0.0,  -- Pan offset X
  pan_y = 0.0,  -- Pan offset Y
  drag_start_x = nil,  -- Drag start position
  drag_start_y = nil,
  drag_start_pan_x = 0.0,
  drag_start_pan_y = 0.0,
  is_dragging = false,  -- Right mouse drag for panning
  is_left_dragging = false,  -- Left mouse drag for selecting samples
  last_dragged_sample_path = nil,  -- Track last sample previewed during drag
  pending_waveform_drop = nil,  -- Sample waiting to be dropped (global drag operation)
  last_mouse_time_pos = nil,  -- Last known mouse time position during drag
  last_mouse_track = nil,     -- Last known mouse track during drag
  seq_drop_target_idx = nil,  -- Sequencer track row hovered during sample drag
  provisional_drop = nil,     -- { item, track, time, sample_path } live arrange preview item during drag
  drag_tooltip_active = false,-- Whether the native floating drag tooltip is showing
  external_disabled = false,  -- Stop trying analyzer after first hard failure
  analyzer_warned = false,
  folder_filter_path = nil,  -- Filter by folder path (nil = no filter)
  settings_open = false,  -- Settings window open/closed state
  played_history = {},  -- Array of played samples (history)
  history_index = 0,  -- Current position in history (0 = most recent, higher = older)
  hovered_tag = nil,  -- Currently hovered tag name
  tag_color_picker_open = false,  -- Whether color picker popup is open
  tag_color_picker_tag = nil,  -- Tag being edited in color picker
  current_preset_name = "Default",  -- Currently active preset name
  -- Dot customization settings
  dot_radius = 2.0,  -- Base dot radius
  dot_outline_size = 4.0,  -- Outline size for selected/playing sample
  dot_outline_thickness = 3.0,  -- Outline thickness
  dot_color = 0x44AA55,     -- Dot color (RRGGBB format, default: green)
  dot_outline_color = 0xFF00FF,   -- Outline color (RRGGBB format, default: magenta)
  dot_hover_color = 0xC84D,       -- Hover highlight color (RRGGBB format, default: yellow)
  dot_detection_multiplier = 16.0,  -- Detection radius multiplier (multiplies dot_radius)
  -- Tag colors (RRGGBB format - full opacity)
  tag_colors = {
    kick = 0x6B46C1,      -- Purple
    snare = 0xFF6B6B,     -- Red
    clap = 0x4ECDC4,      -- Teal
    rim = 0xFFBE0B,       -- Yellow
    hat = 0x8338EC,       -- Purple-blue
    tom = 0x3A86FF,       -- Blue
    ride = 0x06FFA5,      -- Green
    crash = 0xFF006E,     -- Pink
    perc = 0xFFB703,      -- Orange
    fx = 0x9B5DE5,        -- Light purple
    bass = 0x00F5FF,      -- Cyan
    ["808"] = 0xFFD60A,   -- Gold
    vocal = 0xFF9F43,     -- Orange
    loop = 0x0ABDE3,      -- Light blue
    drum = 0xFF3838,      -- Red
    pad = 0xA29BFE,       -- Light purple
    lead = 0xFD79A8,      -- Pink
    pluck = 0x00B894,     -- Green
    keys = 0xE17055,      -- Coral
    guitar = 0x6C5CE7,    -- Purple
  },
  -- Pop effect animation
  pop_start_time = nil,  -- When pop animation started (nil = no pop)
  pop_duration = 0.3,  -- Pop animation duration in seconds
  breathing_start_time = nil,  -- When breathing cycle started (resets on dot click)
  -- Parallel analyzer processing
  analyzer_queue = {},              -- Files waiting for analyzer processing
  analyzer_results = {},            -- Map: path -> analyzer_data (completed results)
  active_processes = {},            -- Table of active analyzer processes: {path, pipe, start_time}
  max_concurrent_analyzers = 2,     -- Number of parallel analyzer processes (reduced to prevent file handle exhaustion)
  last_save_time = 0.0,             -- Timestamp of last cache save
  preview_volume = 1.0,             -- Preview volume (0.0 to 1.0)
  preview_paused = false,           -- Whether preview is paused
  preview_position = 0.0,           -- Playhead position when paused/stopped
  -- Sequencer track slots (linked to project tracks + assigned samples)
  seq_tracks = {},                  -- { id, name, reaper_track_guid, sample_path, sample_name, sample_tag }
  selected_seq_track = nil,         -- 1-based index into seq_tracks
  seq_swap_track_idx = nil,         -- Track slot in sample swap mode (1-based)
  seq_swap_track_id = nil,          -- Stable track slot id in sample swap mode
  seq_swap_backup_path = nil,       -- Original sample path when swap mode started
  seq_swap_backup_name = nil,       -- Original sample name when swap mode started
  block_swap_bar_input = false,     -- Prevent same-frame click bleed from map to bar
  seq_track_next_id = 1,
  seq_panel_width = 240,
  active_view = "sample_map",       -- "sample_map" | "sequencer"
  seq_timeline_drop_track_idx = nil,-- Sequencer timeline row hovered during sample drag
  seq_timeline_drop_time = nil,     -- Sequencer timeline time hovered during sample drag
  seq_follow_arrange = true,        -- Sequencer view follows arrange view when true
  seq_view_start_qn = nil,          -- Manual sequencer view start (QN)
  seq_view_span_qn = nil,           -- Sequencer view span in QN
  seq_grid_qn = 0.25,               -- Musical sequencer cell size in quarter notes
  seq_gen_style = "basic",          -- Template style used by sequencer pattern generation
  seq_regions = {},                 -- { id, name, start_qn, length_bars, pool_id, pattern_id }
  seq_patterns = {},                -- pattern_id -> { notes = { track_slot_id -> step_key -> note } }
  seq_region_next_id = 1,
  seq_pattern_next_id = 1,
  seq_pool_next_id = 1,
  selected_seq_region_id = nil,
  seq_random_edit_region_id = nil, -- Region id whose per-track random controls are shown in sequencer lanes
  seq_random_active_key = nil,     -- Active random knob key while dragging in sequencer overlay
  seq_random_knob_drag = nil,      -- { id, start_value } for custom knob drag math
  seq_pattern_popup_last_style = nil, -- Last popup preset targeted by a dice strength button
  seq_pattern_popup_last_strength = nil,
  selected_seq_note = nil,          -- { region_id, track_id, step_key }
  seq_drag_paint = false,
  seq_drag_mode = nil,              -- "paint" | "erase"
  seq_drag_last_cell = nil,
  seq_expanded_tracks = {},         -- track slot id -> true when parameter lanes are visible
  seq_new_track_query = "",         -- Text input for sequencer add-track popup
  seq_param_drag = nil,             -- { track_id, param, region_id, step_key, col, end_col, ramp, unify, start_value }
  seq_region_drag = nil,            -- Region lane mouse interaction state
  seq_lane_zoom = 1.0,              -- Vertical zoom for sequencer track/param lanes
  seq_note_anims = {},              -- region:track:step -> { kind, start_time, duration, note }
  seq_track_play_anims = {},        -- track slot id -> { start_time, duration }
}

local ctx = nil
local font = nil
local running = true
legacy_seq_project_state = nil
loaded_project = nil
loaded_project_token = nil
local preview_proc = nil  -- preview handle/ID (integer ID for Xen_StartSourcePreview, or boolean for other APIs)
local preview_track = nil  -- dedicated preview track (for PlayTrackPreview2)
local PYTHON_BIN = "/usr/bin/python3"
local EXTERNAL_ANALYZER = SCRIPT_DIR .. "/SampleMapAnalyzer.py"  -- External analysis script path
local preview_source = nil  -- PCM_Source for preview
local preview_source_engine_owned = false  -- True when preview API owns source lifetime
local preview_start_time = 0.0  -- When preview started
local preview_sample_obj = nil  -- Currently previewing sample object
local waveform_data = nil  -- Cached waveform data for current preview
local waveform_width = 800  -- Width of waveform display
local PREVIEW_TRACK_NAME = "__SampleMapPreview"
local cf_preview_obj = nil  -- CF_Preview object (light userdata) for seeking support


-- --- Helper functions ---------------------------------------------------------
local function log(msg)
end

local function add_scan_log(msg)
  local timestamp = os.date("%H:%M:%S")
  local line = string.format("[%s] %s", timestamp, tostring(msg))
  table.insert(state.scan_logs, line)
  if #state.scan_logs > 500 then
    table.remove(state.scan_logs, 1)
  end
end

local function get_scan_logs_text()
  return table.concat(state.scan_logs, "\n")
end


local function shell_escape(str)
  return '"' .. tostring(str):gsub('"', '\\"') .. '"'
end


-- Normalize path separators for macOS (ensure forward slashes)
local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  -- Replace backslashes with forward slashes
  path = path:gsub("\\", "/")
  -- Remove trailing slash
  path = path:gsub("/+$", "")
  return path
end

-- Get filename without path
local function basename(path)
  if not path then return "" end
  local norm = normalize_path(path)
  return norm:match("([^/]+)$") or norm
end

-- Set media take name with logging (preferred) and fallback to item name
local function set_item_name(item, take, sample_path)
  if (not item and not take) or not sample_path then
    log("set_item_name: missing item/take or path")
    return
  end
  local name = basename(sample_path)
  local ok_take = nil
  if take then
    ok_take = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  end
  local ok_item = nil
  if item then
    ok_item = r.GetSetMediaItemInfo_String(item, "P_NAME", name, true)
  end
  log(string.format("Naming to '%s' take_result=%s item_result=%s", name, tostring(ok_take), tostring(ok_item)))
end


-- Build ARGB color from RGB components (0-255)
local function build_color(r, g, b, a)
  a = a or 255
  return 0xFF000000 | (math.floor(r) << 16) | (math.floor(g) << 8) | math.floor(b)
end

-- Extract RGB components from RRGGBBAA format color
local function extract_rgb_rrgbbaa(color)
  if not color then return 0, 0, 0 end
  local r = math.floor((color / 16777216) % 256)   -- Extract red (first byte)
  local g = math.floor((color / 65536) % 256)     -- Extract green
  local b = math.floor((color / 256) % 256)       -- Extract blue
  return r, g, b
end

-- Build RRGGBBAA color from RGB components (0-255) and alpha (0-255, default 255)
local function build_color_rrgbbaa(r, g, b, a)
  a = a or 255
  return (math.floor(r) * 16777216) + (math.floor(g) * 65536) + (math.floor(b) * 256) + math.floor(a)
end

-- Extract RGB from RRGGBB color (24-bit)
local function extract_rgb(color)
  if not color then return 0, 0, 0 end
  local r = math.floor((color / 65536) % 256)
  local g = math.floor((color / 256) % 256)
  local b = math.floor(color % 256)
  return r, g, b
end

-- Build RRGGBB color from RGB components (0-255)
local function build_rgb(r, g, b)
  return (math.floor(r) * 65536) + (math.floor(g) * 256) + math.floor(b)
end



local function pick_number(ret, default)
  default = default or 0.0
  if type(ret) == "number" then
    return ret
  elseif type(ret) == "table" then
    for _, v in ipairs(ret) do
      if type(v) == "number" then
        return v
      end
    end
  end
  return default
end


local function pick_bool(ret, default)
  default = default or false
  if type(ret) == "boolean" then
    return ret
  elseif type(ret) == "table" then
    for _, v in ipairs(ret) do
      if type(v) == "boolean" then
        return v
      end
    end
  end
  return default
end


-- Detect if sample is a loop or oneshot based on filename/path patterns
local function detect_loop_or_oneshot(path, folder)
  local path_lower = path:lower()
  local folder_lower = (folder or ""):lower()
  
  -- Check for oneshot first (explicit keywords)
  if path_lower:find("oneshot") or path_lower:find("one%-shot") or 
     folder_lower:find("oneshot") or folder_lower:find("one%-shot") then
    return "One shot"
  end
  
  -- Check for loop keywords in filename/path
  if path_lower:find("loop") or path_lower:find("looped") or 
     path_lower:find("lpd") or path_lower:find("repeat") or 
     path_lower:find("cycle") or path_lower:find("cycling") then
    return "loop"
  end
  
  -- Check for loop patterns: _loop, -loop, loop_, loop-
  if path_lower:find("[_%-]loop") or path_lower:find("loop[_%-]") then
    return "loop"
  end
  
  -- Check for BPM references (usually indicates loops)
  if path_lower:find("%d+bpm") or path_lower:find("%d+_bpm") or 
     path_lower:find("%d+%-bpm") then
    return "loop"
  end
  
  -- Check for musical keys (usually indicates loops)
  -- Pattern: Am, C#m, Fmaj, etc.
  if path_lower:find("[a-g][#b]?m?aj?") or path_lower:find("key") then
    return "loop"
  end
  
  -- Check for bar/measure references (usually indicates loops)
  if path_lower:find("%d+bar") or path_lower:find("%d+_bar") or 
     path_lower:find("%d+%-bar") then
    return "loop"
  end
  
  -- Check folder structure patterns for loops
  if folder_lower:find("loop") or folder_lower:find("looped") then
    return "loop"
  end
  
  -- Check for specific loop folder patterns
  if folder_lower:find("drum loop") or folder_lower:find("bass loop") or 
     folder_lower:find("melodic loop") or folder_lower:find("full loop") or
     folder_lower:find("construction kit") then
    return "loop"
  end
  
  -- Check for BPM folders (usually contain loops)
  if folder_lower:find("%d+%s+bpm") or folder_lower:find("%d+%-bpm") then
    return "loop"
  end
  
  return nil
end


-- Extract meaningful tags from filename and folder tokens
local function infer_tags_from_path(path, folder)
  local tokens = {}
  local function collect(str)
    if not str or str == "" then return end
    for token in tostring(str):lower():gmatch("%w+") do
      tokens[token] = true
    end
  end
  collect(path or "")
  collect(folder or "")

  local scored = {}
  for _, entry in ipairs(TAG_KEYWORDS) do
    for _, key in ipairs(entry.keys) do
      if tokens[key] then
        local current = scored[entry.tag] or 0
        if entry.weight > current then
          scored[entry.tag] = entry.weight
        end
        break
      end
    end
  end

  local sorted = {}
  for tag, weight in pairs(scored) do
    table.insert(sorted, {tag = tag, weight = weight})
  end
  table.sort(sorted, function(a, b)
    if a.weight == b.weight then
      return a.tag < b.tag
    end
    return a.weight > b.weight
  end)

  local tags = {}
  for _, entry in ipairs(sorted) do
    tags[#tags + 1] = entry.tag
    if #tags >= 6 then break end -- Keep cache lean
  end

  return tags
end


-- Build tag list and counts for UI
local function rebuild_tag_index()
  local counts = {}
  for _, s in ipairs(state.samples) do
    if s.tags and type(s.tags) == "table" then
      for _, tag in ipairs(s.tags) do
        counts[tag] = (counts[tag] or 0) + 1
      end
    end
  end

  state.tag_counts = counts
  state.tag_list = {}
  for tag, count in pairs(counts) do
    table.insert(state.tag_list, {tag = tag, count = count})
  end
  table.sort(state.tag_list, function(a, b)
    if a.count == b.count then
      return a.tag < b.tag
    end
    return a.count > b.count
  end)
end


-- --- JSON helpers (improved) ----------------------------------------------------
local function json_encode_string(s)
  -- Escape special characters in strings
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local function json_encode(val)
  if type(val) == "table" then
    local parts = {}
    local is_array = true
    local max_idx = 0
    for k, v in pairs(val) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
      max_idx = math.max(max_idx, k)
    end
    
    if is_array then
      for i = 1, max_idx do
        table.insert(parts, json_encode(val[i]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(val) do
        table.insert(parts, json_encode_string(tostring(k)) .. ":" .. json_encode(v))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif type(val) == "string" then
    return json_encode_string(val)
  elseif type(val) == "number" then
    return tostring(val)
  elseif type(val) == "boolean" then
    return val and "true" or "false"
  else
    return "null"
  end
end


local function json_decode(str)
  -- Improved JSON decoder that handles strings with commas and special chars
  str = str:match("%s*(.*)")
  if str:sub(1, 1) == "{" then
    local obj = {}
    str = str:sub(2, -2) -- remove {}
    
    -- Parse key-value pairs, handling quoted strings properly
    local pos = 1
    while pos <= #str do
      -- Skip whitespace
      while pos <= #str and str:sub(pos, pos):match("%s") do
        pos = pos + 1
      end
      if pos > #str then break end
      
      -- Find key (quoted string)
      if str:sub(pos, pos) ~= '"' then break end
      local key_start = pos + 1
      local key_end = key_start
      while key_end <= #str do
        if str:sub(key_end, key_end) == '"' and str:sub(key_end - 1, key_end - 1) ~= '\\' then
          break
        end
        key_end = key_end + 1
      end
      local key = str:sub(key_start, key_end - 1):gsub('\\"', '"'):gsub('\\\\', '\\')
      
      -- Skip to colon
      pos = key_end + 1
      while pos <= #str and str:sub(pos, pos) ~= ':' do pos = pos + 1 end
      pos = pos + 1
      
      -- Skip whitespace
      while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
      
      -- Parse value
      if str:sub(pos, pos) == '"' then
        -- String value
        local val_start = pos + 1
        local val_end = val_start
        while val_end <= #str do
          if str:sub(val_end, val_end) == '"' and str:sub(val_end - 1, val_end - 1) ~= '\\' then
            break
          end
          val_end = val_end + 1
        end
        obj[key] = str:sub(val_start, val_end - 1):gsub('\\"', '"'):gsub('\\\\', '\\'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t')
        pos = val_end + 1
      elseif str:sub(pos, pos) == '[' then
        -- Array value - find matching bracket
        local depth = 1
        local arr_start = pos
        pos = pos + 1
        while pos <= #str and depth > 0 do
          if str:sub(pos, pos) == '[' then depth = depth + 1
          elseif str:sub(pos, pos) == ']' then depth = depth - 1 end
          pos = pos + 1
        end
        local arr_str = str:sub(arr_start, pos - 1)
        obj[key] = json_decode(arr_str)
      elseif str:sub(pos, pos) == '{' then
        -- Object value - find matching brace
        local depth = 1
        local obj_start = pos
        pos = pos + 1
        while pos <= #str and depth > 0 do
          if str:sub(pos, pos) == '{' then depth = depth + 1
          elseif str:sub(pos, pos) == '}' then depth = depth - 1 end
          pos = pos + 1
        end
        local obj_str = str:sub(obj_start, pos - 1)
        obj[key] = json_decode(obj_str)
      else
        -- Number or boolean
        local val_end = pos
        while val_end <= #str and str:sub(val_end, val_end) ~= ',' and str:sub(val_end, val_end) ~= '}' do
          val_end = val_end + 1
        end
        local val_str = str:sub(pos, val_end - 1):match("^%s*(.-)%s*$")
        if val_str == "true" then
          obj[key] = true
        elseif val_str == "false" then
          obj[key] = false
        elseif tonumber(val_str) then
          obj[key] = tonumber(val_str)
        end
        pos = val_end
      end
      
      -- Skip comma
      while pos <= #str and (str:sub(pos, pos) == ',' or str:sub(pos, pos):match("%s")) do
        pos = pos + 1
      end
    end
    return obj
  elseif str:sub(1, 1) == "[" then
    local arr = {}
    str = str:sub(2, -2) -- remove []
    
    -- Handle empty array
    if str:match("^%s*$") then
      return arr
    end
    
    -- Parse array items, handling strings with commas, nested objects, and nested arrays
    local pos = 1
    while pos <= #str do
      -- Skip whitespace
      while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
      if pos > #str then break end
      
      if str:sub(pos, pos) == '"' then
        -- String item
        local item_start = pos + 1
        local item_end = item_start
        while item_end <= #str do
          if str:sub(item_end, item_end) == '"' and str:sub(item_end - 1, item_end - 1) ~= '\\' then
            break
          end
          item_end = item_end + 1
        end
        if item_end <= #str then
          local item_str = str:sub(item_start, item_end - 1)
          item_str = item_str:gsub('\\"', '"'):gsub('\\\\', '\\')
          table.insert(arr, item_str)
        end
        pos = item_end + 1
      elseif str:sub(pos, pos) == '{' then
        -- Nested object - find matching brace
        local depth = 1
        local obj_start = pos
        pos = pos + 1
        while pos <= #str and depth > 0 do
          if str:sub(pos, pos) == '{' then depth = depth + 1
          elseif str:sub(pos, pos) == '}' then depth = depth - 1 end
          pos = pos + 1
        end
        local obj_str = str:sub(obj_start, pos - 1)
        table.insert(arr, json_decode(obj_str))
      elseif str:sub(pos, pos) == '[' then
        -- Nested array - find matching bracket
        local depth = 1
        local arr_start = pos
        pos = pos + 1
        while pos <= #str and depth > 0 do
          if str:sub(pos, pos) == '[' then depth = depth + 1
          elseif str:sub(pos, pos) == ']' then depth = depth - 1 end
          pos = pos + 1
        end
        local arr_str = str:sub(arr_start, pos - 1)
        table.insert(arr, json_decode(arr_str))
      elseif tonumber(str:sub(pos, pos)) or str:sub(pos, pos) == '-' then
        -- Number item
        local item_end = pos
        while item_end <= #str and str:sub(item_end, item_end) ~= ',' and str:sub(item_end, item_end) ~= ']' do
          item_end = item_end + 1
        end
        local num_str = str:sub(pos, item_end - 1):match("^%s*(.-)%s*$")
        local num = tonumber(num_str)
        if num then 
          table.insert(arr, num) 
        end
        pos = item_end
      elseif str:sub(pos, pos) == 't' or str:sub(pos, pos) == 'f' then
        -- Boolean or null
        local item_end = pos
        while item_end <= #str and str:sub(item_end, item_end) ~= ',' and str:sub(item_end, item_end) ~= ']' do
          item_end = item_end + 1
        end
        local val_str = str:sub(pos, item_end - 1):match("^%s*(.-)%s*$")
        if val_str == "true" then
          table.insert(arr, true)
        elseif val_str == "false" then
          table.insert(arr, false)
        elseif val_str == "null" then
          table.insert(arr, nil)
        end
        pos = item_end
      else
        -- Skip unknown character (shouldn't happen in valid JSON)
        log("Warning: Unexpected character in array at position " .. pos .. ": " .. str:sub(pos, pos))
        pos = pos + 1
      end
      
      -- Skip comma
      while pos <= #str and (str:sub(pos, pos) == ',' or str:sub(pos, pos):match("%s")) do
        pos = pos + 1
      end
    end
    return arr
  end
  return nil
end


-- --- Preview helpers (track only) ----------------------------------------------
local function ensure_preview_track()
  if preview_track then
    if (r.ValidatePtr2 and r.ValidatePtr2(0, preview_track, "MediaTrack*")) or 
       (r.ValidatePtr and r.ValidatePtr(preview_track, "MediaTrack*")) then
      return preview_track
    end
  end

  -- Try to find existing preview track
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, name = r.GetTrackName(tr, "")
    if name == PREVIEW_TRACK_NAME then
      preview_track = tr
      break
    end
  end

  -- Create if missing
  if not preview_track then
    r.InsertTrackAtIndex(r.CountTracks(0), true)
    preview_track = r.GetTrack(0, r.CountTracks(0) - 1)
    r.GetSetMediaTrackInfo_String(preview_track, "P_NAME", PREVIEW_TRACK_NAME, true)
    -- Hide from TCP/mixer to avoid clutter
    r.SetMediaTrackInfo_Value(preview_track, "B_SHOWINTCP", 0)
    r.SetMediaTrackInfo_Value(preview_track, "B_SHOWINMIXER", 0)
    -- Keep normal routing (main send on)
    r.SetMediaTrackInfo_Value(preview_track, "B_MAINSEND", 1)
  end

  return preview_track
end


-- --- Persistence -------------------------------------------------------------
function get_current_project()
  if r.EnumProjects then
    local proj = r.EnumProjects(-1, "")
    if proj then
      return proj
    end
  end
  return 0
end

function reset_seq_project_state()
  state.seq_tracks = {}
  state.selected_seq_track = nil
  state.seq_swap_track_idx = nil
  state.seq_swap_track_id = nil
  state.seq_swap_backup_path = nil
  state.seq_swap_backup_name = nil
  state.seq_track_next_id = 1
  state.seq_panel_width = 240
  state.seq_timeline_drop_track_idx = nil
  state.seq_timeline_drop_time = nil
  state.seq_follow_arrange = true
  state.seq_view_start_qn = nil
  state.seq_view_span_qn = nil
  state.seq_grid_qn = 0.25
  state.seq_gen_style = "basic"
  state.seq_regions = {}
  state.seq_patterns = {}
  state.seq_region_next_id = 1
  state.seq_pattern_next_id = 1
  state.seq_pool_next_id = 1
  state.selected_seq_region_id = nil
  state.seq_pattern_popup_last_style = nil
  state.seq_pattern_popup_last_strength = nil
  state.selected_seq_note = nil
  state.seq_drag_paint = false
  state.seq_drag_mode = nil
  state.seq_drag_last_cell = nil
  state.seq_expanded_tracks = {}
  state.seq_new_track_query = ""
  state.seq_param_drag = nil
  state.seq_region_drag = nil
  state.seq_lane_zoom = 1.0
  state.seq_note_anims = {}
  state.seq_track_play_anims = {}
end

function apply_seq_project_state(cfg)
  if type(cfg) ~= "table" then
    return
  end
  if cfg.seq_tracks and type(cfg.seq_tracks) == "table" then
    state.seq_tracks = {}
    for _, entry in ipairs(cfg.seq_tracks) do
      if type(entry) == "table" and entry.id then
        table.insert(state.seq_tracks, {
          id = entry.id,
          name = entry.name or "Track",
          reaper_track_guid = entry.reaper_track_guid,
          sample_path = entry.sample_path,
          sample_name = entry.sample_name,
          sample_tag = entry.sample_tag,
        })
        if type(entry.id) == "number" and entry.id >= state.seq_track_next_id then
          state.seq_track_next_id = entry.id + 1
        end
      end
    end
  end
  if cfg.selected_seq_track and type(cfg.selected_seq_track) == "number" then
    state.selected_seq_track = cfg.selected_seq_track
  end
  if cfg.seq_panel_width and type(cfg.seq_panel_width) == "number" then
    state.seq_panel_width = cfg.seq_panel_width
  end
  if type(cfg.seq_follow_arrange) == "boolean" then
    state.seq_follow_arrange = cfg.seq_follow_arrange
  end
  if type(cfg.seq_view_start_qn) == "number" then
    state.seq_view_start_qn = cfg.seq_view_start_qn
  end
  if type(cfg.seq_view_span_qn) == "number" and cfg.seq_view_span_qn > 0 then
    state.seq_view_span_qn = cfg.seq_view_span_qn
  end
  if type(cfg.seq_grid_qn) == "number" and cfg.seq_grid_qn > 0 then
    state.seq_grid_qn = cfg.seq_grid_qn
  end
  if type(cfg.seq_gen_style) == "string" and cfg.seq_gen_style ~= "" then
    state.seq_gen_style = cfg.seq_gen_style
  end
  if type(cfg.seq_lane_zoom) == "number" and cfg.seq_lane_zoom > 0 then
    state.seq_lane_zoom = cfg.seq_lane_zoom
  end
  if cfg.seq_regions and type(cfg.seq_regions) == "table" then
    state.seq_regions = cfg.seq_regions
    for _, region in ipairs(state.seq_regions) do
      if type(region) == "table" and type(region.id) == "number" and region.id >= state.seq_region_next_id then
        state.seq_region_next_id = region.id + 1
      end
    end
  end
  if cfg.seq_patterns and type(cfg.seq_patterns) == "table" then
    state.seq_patterns = cfg.seq_patterns
  end
  if type(cfg.seq_region_next_id) == "number" then
    state.seq_region_next_id = math.max(state.seq_region_next_id, cfg.seq_region_next_id)
  end
  if type(cfg.seq_pattern_next_id) == "number" then
    state.seq_pattern_next_id = cfg.seq_pattern_next_id
  end
  if type(cfg.seq_pool_next_id) == "number" then
    state.seq_pool_next_id = cfg.seq_pool_next_id
  end
  if type(cfg.selected_seq_region_id) == "number" then
    state.selected_seq_region_id = cfg.selected_seq_region_id
  end
  if cfg.seq_expanded_tracks and type(cfg.seq_expanded_tracks) == "table" then
    state.seq_expanded_tracks = cfg.seq_expanded_tracks
  end
end

function build_seq_project_state_payload()
  return {
    version = 1,
    seq_tracks = state.seq_tracks,
    selected_seq_track = state.selected_seq_track,
    seq_panel_width = state.seq_panel_width,
    seq_follow_arrange = state.seq_follow_arrange,
    seq_view_start_qn = state.seq_view_start_qn,
    seq_view_span_qn = state.seq_view_span_qn,
    seq_grid_qn = state.seq_grid_qn,
    seq_gen_style = state.seq_gen_style,
    seq_lane_zoom = state.seq_lane_zoom,
    seq_regions = state.seq_regions,
    seq_patterns = state.seq_patterns,
    seq_region_next_id = state.seq_region_next_id,
    seq_pattern_next_id = state.seq_pattern_next_id,
    seq_pool_next_id = state.seq_pool_next_id,
    selected_seq_region_id = state.selected_seq_region_id,
    seq_expanded_tracks = state.seq_expanded_tracks,
  }
end

function save_seq_project_state(proj)
  if not r.SetProjExtState then
    return
  end
  proj = proj or get_current_project()
  local ok, serialized = pcall(json_encode, build_seq_project_state_payload())
  if ok and type(serialized) == "string" then
    r.SetProjExtState(proj, PROJ_EXT_SECTION, PROJ_EXT_KEY_SEQUENCER, serialized)
  end
end

function load_seq_project_state(proj)
  proj = proj or get_current_project()
  reset_seq_project_state()
  local loaded = false
  if r.GetProjExtState then
    local ok, serialized = r.GetProjExtState(proj, PROJ_EXT_SECTION, PROJ_EXT_KEY_SEQUENCER)
    if ok and ok ~= 0 and serialized and serialized ~= "" then
      local parse_ok, cfg = pcall(json_decode, serialized)
      if parse_ok and type(cfg) == "table" then
        apply_seq_project_state(cfg)
        loaded = true
      end
    end
  end
  if loaded then
    legacy_seq_project_state = nil
  elseif legacy_seq_project_state and type(legacy_seq_project_state) == "table" then
    apply_seq_project_state(legacy_seq_project_state)
    legacy_seq_project_state = nil
    save_seq_project_state(proj)
  end
end

function sync_project_state_if_needed()
  local proj = get_current_project()
  local token = tostring(proj)
  if loaded_project_token ~= token then
    if loaded_project then
      save_seq_project_state(loaded_project)
    end
    load_seq_project_state(proj)
    loaded_project = proj
    loaded_project_token = token
  end
end

local function load_config()
  local file = io.open(CONFIG_PATH, "r")
  if file then
    local content = file:read("*all")
    file:close()
    if content and content ~= "" then
      local success, cfg = pcall(json_decode, content)
      if success and cfg and type(cfg) == "table" then
        -- Ensure folders is an array of strings (normalized)
        if cfg.folders and type(cfg.folders) == "table" then
          state.folders = {}
          for i, folder in ipairs(cfg.folders) do
            if type(folder) == "string" then
              table.insert(state.folders, normalize_path(folder))
            end
          end
        else
          state.folders = {}
        end
        state.map_seed = cfg.map_seed or 1337
        -- Zoom and pan are not saved - always start at defaults
        -- Load dot customization settings
        state.dot_radius = cfg.dot_radius or 2.0
        state.dot_outline_size = cfg.dot_outline_size or 4.0
        state.dot_outline_thickness = cfg.dot_outline_thickness or 3.0
        -- Load colors (RGB format)
        if cfg.dot_color then
          state.dot_color = cfg.dot_color
        elseif cfg.dot_color_r then
          -- Convert old RGB component format to RGB color value
          state.dot_color = build_rgb(cfg.dot_color_r or 68, cfg.dot_color_g or 170, cfg.dot_color_b or 85)
        else
          state.dot_color = 0x44AA55
        end
        if cfg.dot_outline_color then
          state.dot_outline_color = cfg.dot_outline_color
        elseif cfg.dot_outline_color_r then
          state.dot_outline_color = build_rgb(cfg.dot_outline_color_r or 255, cfg.dot_outline_color_g or 0, cfg.dot_outline_color_b or 255)
        else
          state.dot_outline_color = 0xFF00FF
        end
        if cfg.dot_hover_color then
          state.dot_hover_color = cfg.dot_hover_color
        elseif cfg.dot_hover_color_r then
          state.dot_hover_color = build_rgb(cfg.dot_hover_color_r or 200, cfg.dot_hover_color_g or 76, cfg.dot_hover_color_b or 77)
        else
          state.dot_hover_color = 0xC84D
        end
        state.dot_detection_multiplier = cfg.dot_detection_multiplier or 16.0
        -- Load preview volume
        state.preview_volume = cfg.preview_volume or 1.0
        -- Load tag colors
        if cfg.tag_colors and type(cfg.tag_colors) == "table" then
          for tag, color in pairs(cfg.tag_colors) do
            if type(color) == "number" then
              state.tag_colors[tag] = color
            end
          end
        end
        if cfg.active_view == "sample_map" or cfg.active_view == "sequencer" then
          state.active_view = cfg.active_view
        end
        if type(cfg.seq_tracks) == "table"
            or type(cfg.seq_regions) == "table"
            or type(cfg.seq_patterns) == "table" then
          legacy_seq_project_state = {
            seq_tracks = cfg.seq_tracks,
            selected_seq_track = cfg.selected_seq_track,
            seq_panel_width = cfg.seq_panel_width,
            seq_follow_arrange = cfg.seq_follow_arrange,
            seq_view_start_qn = cfg.seq_view_start_qn,
            seq_view_span_qn = cfg.seq_view_span_qn,
            seq_grid_qn = cfg.seq_grid_qn,
            seq_gen_style = cfg.seq_gen_style,
            seq_lane_zoom = cfg.seq_lane_zoom,
            seq_regions = cfg.seq_regions,
            seq_patterns = cfg.seq_patterns,
            seq_region_next_id = cfg.seq_region_next_id,
            seq_pattern_next_id = cfg.seq_pattern_next_id,
            seq_pool_next_id = cfg.seq_pool_next_id,
            selected_seq_region_id = cfg.selected_seq_region_id,
            seq_expanded_tracks = cfg.seq_expanded_tracks,
          }
        end
        log("Loaded config: " .. #state.folders .. " folder(s)")
        if #state.folders > 0 then
          for i, folder in ipairs(state.folders) do
            log("  Folder " .. i .. ": " .. folder)
          end
        end
      else
        log("Config file exists but couldn't parse it: " .. tostring(cfg))
      end
    end
  else
    log("No config file found, starting fresh")
  end
end


local function serialize_table(t, indent)
  indent = indent or ""
  local result = "{\n"
  for k, v in pairs(t) do
    result = result .. indent .. "  "
    if type(k) == "string" then
      result = result .. '["' .. k .. '"]'
    else
      result = result .. '[' .. tostring(k) .. ']'
    end
    result = result .. " = "
    if type(v) == "table" then
      result = result .. serialize_table(v, indent .. "  ")
    elseif type(v) == "string" then
      result = result .. '"' .. v .. '"'
    else
      result = result .. tostring(v)
    end
    result = result .. ",\n"
  end
  result = result .. indent .. "}"
  return result
end

local function save_config()
  local cfg = {
    folders = state.folders,
    map_seed = state.map_seed,
    -- Save dot customization settings
    dot_radius = state.dot_radius,
    dot_outline_size = state.dot_outline_size,
    dot_outline_thickness = state.dot_outline_thickness,
    dot_color = state.dot_color,
    dot_outline_color = state.dot_outline_color,
    dot_hover_color = state.dot_hover_color,
    dot_detection_multiplier = state.dot_detection_multiplier,
    preview_volume = state.preview_volume,
    tag_colors = state.tag_colors,
    active_view = state.active_view,
  }
  local file = io.open(CONFIG_PATH, "w")
  if file then
    local json_str = json_encode(cfg)
    file:write(json_str)
    file:close()
    log("Saved config with " .. #state.folders .. " folder(s)")
  else
    log("Failed to save config file")
  end
  save_seq_project_state(loaded_project or get_current_project())
end


-- Run external Python analyzer to compute metadata (e.g., frequency/RMS)
-- Expected JSON output: { dominant_freq: number, rms_energy: number }
local function run_external_analyzer(path)
  local analyzer_start = r.time_precise()
  
  -- Validate analyzer script exists
  local t0 = r.time_precise()
  local fh = io.open(EXTERNAL_ANALYZER, "r")
  if not fh then
    return nil, "analyzer script missing"
  end
  fh:close()
  local check_time = (r.time_precise() - t0) * 1000

  local t1 = r.time_precise()
  local cmd = table.concat({
    shell_escape(PYTHON_BIN),
    shell_escape(EXTERNAL_ANALYZER),
    shell_escape(path)
  }, " ")

  -- Try to capture both stdout and stderr
  -- On macOS, we can redirect stderr to stdout with 2>&1
  local cmd_with_stderr = cmd .. " 2>&1"
  local pipe = io.popen(cmd_with_stderr, "r")
  if not pipe then
    return nil, "failed to start analyzer"
  end
  local spawn_time = (r.time_precise() - t1) * 1000

  local t2 = r.time_precise()
  local output = pipe:read("*all")
  local ok, why, code = pipe:close()
  local exec_time = (r.time_precise() - t2) * 1000
  
  if not ok then
    return nil, "analyzer process failed"
  end

  if not output or output == "" then
    return nil, "empty analyzer output"
  end

  local t3 = r.time_precise()
  local success, data = pcall(json_decode, output)
  local parse_time = (r.time_precise() - t3) * 1000
  
  local total_analyzer_time = (r.time_precise() - analyzer_start) * 1000
  
  if success and type(data) == "table" then
    -- Remove debug key before returning (don't store it in sample data)
    data._debug = nil
    
    -- Analyzer timing removed - use scan logs instead
    
    return data, nil
  end

  return nil, "invalid analyzer JSON"
end


-- Start an analyzer process for a file (non-blocking)
-- Returns true if process started successfully, false otherwise
local function start_analyzer_process(path)
  -- Check if analyzer script exists
  local fh = io.open(EXTERNAL_ANALYZER, "r")
  if not fh then
    return false
  end
  fh:close()
  
  -- Build command
  local cmd = table.concat({
    shell_escape(PYTHON_BIN),
    shell_escape(EXTERNAL_ANALYZER),
    shell_escape(path)
  }, " ")
  
  local cmd_with_stderr = cmd .. " 2>&1"
  local pipe = io.popen(cmd_with_stderr, "r")
  
  if pipe then
    table.insert(state.active_processes, {
      path = path,
      pipe = pipe,
      start_time = r.time_precise()
    })
    return true
  end
  
  return false
end


-- Check for completed analyzer processes and update analyzer_results
-- Only checks one process per call to avoid blocking (called each frame)
-- Returns true if a process was checked/completed, false if no processes to check
local function check_analyzer_processes()
  if #state.active_processes == 0 then
    return false
  end
  
  -- Check only the first process (oldest) to minimize blocking
  local proc = state.active_processes[1]
  local pipe = proc.pipe
  
  -- Check timeout first (non-blocking check)
  local elapsed = r.time_precise() - proc.start_time
  if elapsed > 30.0 then
    -- Timeout - close pipe and mark as failed
    local close_ok, close_err = pcall(function() return pipe:close() end)
    if not close_ok then
      add_scan_log(string.format("Warning: failed to close timed-out pipe for %s: %s", proc.path:match("([^/]+)$") or proc.path, tostring(close_err)))
    end
    state.analyzer_results[proc.path] = {data = nil, err = "analyzer timeout"}
    add_scan_log(string.format("Analyzer timeout on %s (continuing)", proc.path:match("([^/]+)$") or proc.path))
    table.remove(state.active_processes, 1)
    return true
  end
  
  -- Try to read from pipe (this may block briefly if process is still running)
  -- We only check one per frame to keep GUI responsive
  -- Use non-blocking check: try to read a line, but don't wait if process is still running
  local line = pipe:read("*line")
  
  if line then
    -- Process has output, read remaining
    local output = line
    local rest = pipe:read("*all")
    if rest then
      output = output .. "\n" .. rest
    end

    -- Always close the pipe after reading
    local ok, why, code = pcall(function() return pipe:close() end)
    if not ok then
      -- If close fails, log it but continue
      add_scan_log(string.format("Warning: failed to close pipe for %s: %s", proc.path:match("([^/]+)$") or proc.path, tostring(why)))
    end
    
    add_scan_log(string.format("Process closed: ok=%s, output_len=%d", tostring(ok), #output))

    if output and output ~= "" then
      local success, data = pcall(json_decode, output)
      if success and type(data) == "table" then
        data._debug = nil
        state.analyzer_results[proc.path] = {data = data, err = nil}

        -- Log success
        add_scan_log(string.format("Analyzer completed: %s (freq=%.1f, rms=%.3f)", proc.path:match("([^/]+)$") or proc.path, data.dominant_freq or 0, data.rms_energy or 0))
      else
        state.analyzer_results[proc.path] = {data = nil, err = "invalid analyzer JSON"}
        add_scan_log(string.format("Analyzer error on %s: invalid JSON: %s", proc.path:match("([^/]+)$") or proc.path, tostring(data)))
      end
    else
      state.analyzer_results[proc.path] = {data = nil, err = "analyzer process failed"}
      add_scan_log(string.format("Analyzer error on %s: process failed (ok=%s, why=%s, code=%s)", proc.path:match("([^/]+)$") or proc.path, tostring(ok), tostring(why), tostring(code)))
    end
  
    -- Remove from active processes
    table.remove(state.active_processes, 1)
    return true
  end
  
  -- Process still running, no output yet - pipe remains open (will be checked next frame)
  -- This is OK as long as we limit concurrent processes and handle timeouts
  return false
end


-- Manage the analyzer process pool: start new processes when slots available
local function process_analyzer_queue()
  if state.external_disabled then
    add_scan_log("Analyzer disabled, skipping queue processing")
    return
  end

  -- Check for completed processes (check one at a time to avoid blocking)
  local had_completed = check_analyzer_processes()
  if had_completed then
    add_scan_log("Completed analyzer process")
  end

  -- Start new processes if we have slots available and files in queue
  local started = 0
  while #state.active_processes < state.max_concurrent_analyzers and #state.analyzer_queue > 0 do
    local path = table.remove(state.analyzer_queue, 1)
    if start_analyzer_process(path) then
      started = started + 1
      add_scan_log(string.format("Started analyzer process for: %s", path:match("([^/]+)$") or path))
    else
      -- Failed to start - check if it's a critical error
      local fh = io.open(EXTERNAL_ANALYZER, "r")
      if not fh then
        state.external_disabled = true
        state.analyzer_warned = true
        add_scan_log("Analyzer critical error; disabled further runs: analyzer script missing")
        break
      end
      fh:close()

      -- Non-critical error, just log and continue
      state.analyzer_results[path] = {data = nil, err = "failed to start analyzer"}
      add_scan_log(string.format("Analyzer error on %s: failed to start (continuing)", path:match("([^/]+)$") or path))
    end
  end

  if started > 0 then
    add_scan_log(string.format("Started %d new analyzer processes", started))
  end
end


local function folders_match(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if #a ~= #b then return false end
  for i = 1, #a do
    -- Normalize paths before comparison
    local norm_a = normalize_path(a[i] or "")
    local norm_b = normalize_path(b[i] or "")
    if norm_a ~= norm_b then return false end
  end
  return true
end


-- Layout samples on the 2D map based on their audio characteristics
local function layout_samples()
  if #state.samples == 0 then return end

  -- Use Lua calculation (Python analyzer doesn't support layout calculations)
  -- Coordinates are cached after calculation, so this only runs when needed

  -- Calculate positioning scores for all samples
  local len_scores = {}
  local freq_scores = {}
  local rms_scores = {}
  local size_scores = {}

  -- Lua doesn't have log10, so use log(x) / log(10)
  local log10 = math.log(10)
  for _, s in ipairs(state.samples) do
    table.insert(len_scores, math.log(math.max(s.duration, 0.01)) / log10)
    -- Use dominant frequency (log scale for better distribution)
    -- Clamp frequency to valid range (20Hz to 20kHz)
    local freq = math.max(20.0, math.min(20000.0, s.dominant_freq or 440.0))
    table.insert(freq_scores, math.log(freq) / log10)
    -- Store RMS energy (use log scale for better distribution)
    local rms = math.max(1e-6, s.rms_energy or 0.0)
    table.insert(rms_scores, math.log(rms) / log10)
    -- Store file size (use log scale for better distribution)
    local size = math.max(1, s.file_size or 1)
    table.insert(size_scores, math.log(size) / log10)
  end

  -- Check if frequencies are too similar (all defaulting to 440Hz)
  local freq_min = freq_scores[1]
  local freq_max = freq_scores[1]
  for _, v in ipairs(freq_scores) do
    freq_min = math.min(freq_min, v)
    freq_max = math.max(freq_max, v)
  end
  local freq_range = freq_max - freq_min

  -- Check if RMS is all zeros
  local rms_min = rms_scores[1]
  local rms_max = rms_scores[1]
  for _, v in ipairs(rms_scores) do
    rms_min = math.min(rms_min, v)
    rms_max = math.max(rms_max, v)
  end
  local rms_range = rms_max - rms_min
  local rms_all_zero = rms_range < 1e-6  -- RMS is essentially zero

  -- Decide what to use for Y axis
  local use_rms_for_y = false
  local use_size_for_y = false

  if freq_range < 0.01 then
    -- Frequency range too small
    if rms_all_zero then
      -- RMS is also zero, use file size
      use_size_for_y = true
    else
      use_rms_for_y = true
    end
  end

  math.randomseed(state.map_seed)

  -- Ensure we use the full range: find min/max for both axes
  local len_min, len_max = len_scores[1], len_scores[1]
  local y_min, y_max

  for _, v in ipairs(len_scores) do
    len_min = math.min(len_min, v)
    len_max = math.max(len_max, v)
  end

  -- Use RMS, file size, or frequency for Y axis
  if use_size_for_y then
    y_min, y_max = size_scores[1], size_scores[1]
    for _, v in ipairs(size_scores) do
      y_min = math.min(y_min, v)
      y_max = math.max(y_max, v)
    end
  elseif use_rms_for_y then
    y_min, y_max = rms_scores[1], rms_scores[1]
    for _, v in ipairs(rms_scores) do
      y_min = math.min(y_min, v)
      y_max = math.max(y_max, v)
    end
  else
    y_min, y_max = freq_scores[1], freq_scores[1]
    for _, v in ipairs(freq_scores) do
      y_min = math.min(y_min, v)
      y_max = math.max(y_max, v)
    end
  end

  -- Normalize function that ensures full range usage with padding for better spread
  local function normalize(value, min_val, max_val, padding)
    padding = padding or 0.1  -- 10% padding on each side
    if max_val - min_val < 1e-9 then
      return 0.5  -- All same value, center it
    end
    -- Normalize to 0-1 range
    local normalized = (value - min_val) / (max_val - min_val)
    -- Scale to use more of the available space (with padding)
    -- Maps 0-1 to padding to (1-padding)
    return padding + normalized * (1.0 - 2.0 * padding)
  end

  -- Position each sample
  for i, s in ipairs(state.samples) do
    -- Preserve existing tags before modifying sample (make a copy, not a reference)
    local preserved_tags = nil
    if s.tags and type(s.tags) == "table" then
      preserved_tags = {}
      for _, tag in ipairs(s.tags) do
        table.insert(preserved_tags, tag)
      end
    end

    -- X-axis: duration (left = short, right = long)
    local x = normalize(len_scores[i], len_min, len_max, 0.05)  -- 5% padding
    -- Y-axis: dominant frequency, RMS energy, or file size (top = high, bottom = low)
    -- Use full range (0.0 padding) to spread from top to bottom
    local y_value
    if use_size_for_y then
      y_value = size_scores[i]
    elseif use_rms_for_y then
      y_value = rms_scores[i]
    else
      y_value = freq_scores[i]
    end
    local y_normalized = normalize(y_value, y_min, y_max, 0.0)  -- No padding - use full range
    local y = 1.0 - y_normalized  -- Invert so highest value is at top
    -- Add jitter to avoid clustering
    local jx = (math.random() - 0.5) * 0.04
    local jy = (math.random() - 0.5) * 0.04
    s.x = math.max(0.0, math.min(1.0, x + jx))
    s.y = math.max(0.0, math.min(1.0, y + jy))
    -- Use customizable dot color, with slight variation for mono samples
    local base_color = state.dot_color or 0x44AA55FF  -- RRGGBBAA format
    local base_r, base_g, base_b = extract_rgb_rrgbbaa(base_color)
    local base_alpha = math.floor(base_color % 256)
    if s.channels == 1 then
      -- Mono: use lighter version (add 50% to each component, clamped to 255)
      local mono_r = math.min(255, math.floor(base_r * 1.5))
      local mono_g = math.min(255, math.floor(base_g * 1.5))
      local mono_b = math.min(255, math.floor(base_b * 1.5))
      s.color = build_color_rrgbbaa(mono_r, mono_g, mono_b, base_alpha)
    else
      -- Stereo: use base customizable color directly
      s.color = base_color
    end
    -- Use customizable hover color directly (RRGGBBAA format)
    s.hot_color = state.dot_hover_color or 0xFFC84DFF

    -- Restore preserved tags
    if preserved_tags then
      s.tags = preserved_tags
    end
  end

  -- Layout debug logs removed - happens during scanning
end


local function load_samples()
  log("Attempting to load cached samples from: " .. DATA_PATH)
  local file = io.open(DATA_PATH, "r")
  if not file then
    log("Cache file not found or cannot be opened")
    return false
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    log("Cache file is empty")
    return false
  end
  log("Cache file size: " .. #content .. " bytes")
  local ok, data = pcall(json_decode, content)
  if not ok then
    log("Failed to decode JSON: " .. tostring(data))
    return false
  end
  if type(data) ~= "table" then
    log("Decoded data is not a table: " .. type(data))
    return false
  end
  log("Decoded JSON successfully")
  if data.folders then
    log("Cache has " .. #data.folders .. " folder(s)")
    if not folders_match(state.folders, data.folders) then
      log("Cached samples ignored: folder list changed")
      log("  Current folders: " .. #state.folders)
      log("  Cached folders: " .. #data.folders)
      return false
    end
    log("Folder list matches cache")
  else
    log("Cache has no folders field")
  end
  if data.samples and type(data.samples) == "table" then
    log("Cache has samples table with " .. #data.samples .. " entries")
    local cleaned = {}
    -- Use ipairs to properly iterate over array
    for i, s in ipairs(data.samples) do
      if type(s) == "table" then
        -- Verify sample has required fields
        if s.path and s.name then
          -- Normalize path immediately (critical for analyzer result merging)
          s.path = normalize_path(s.path)
          -- Ensure coordinates exist (set defaults if missing)
          if not s.x then s.x = 0.5 end
          if not s.y then s.y = 0.5 end
          -- Backfill tags for older cache entries
          if not s.tags or type(s.tags) ~= "table" then
            s.tags = infer_tags_from_path(s.path, s.folder or "")
          end
          -- Ensure sample_type is added to tags if it exists
          if s.sample_type and (s.sample_type == "Drum" or s.sample_type == "Swell") then
            local has_tag = false
            for _, tag in ipairs(s.tags) do
              if tag == s.sample_type then
                has_tag = true
                break
              end
            end
            if not has_tag then
              table.insert(s.tags, s.sample_type)
            end
          end
          -- Detect and add Loop or One shot tag if detected
          local sample_type_detected = detect_loop_or_oneshot(s.path, s.folder or "")
          if sample_type_detected then
            local has_tag = false
            for _, tag in ipairs(s.tags) do
              if tag == sample_type_detected then
                has_tag = true
                break
              end
            end
            if not has_tag then
              table.insert(s.tags, sample_type_detected)
            end
          end
          table.insert(cleaned, s)
        else
          log("Warning: sample " .. i .. " missing path or name")
        end
      else
        log("Warning: sample " .. i .. " is not a table: " .. type(s))
      end
    end
    state.samples = cleaned

    -- Re-hydrate runtime-only fields (hot_color, samplerate, file_size) that are not persisted
    local function hydrate_sample_runtime(sample)
      if not sample then return end
      if sample.hot_color == nil then
        sample.hot_color = state.dot_hover_color or 0xFFC84DFF
      end
      if sample.samplerate == nil and sample.sample_rate ~= nil then
        sample.samplerate = sample.sample_rate
      end
      if sample.samplerate == nil then
        sample.samplerate = 44100
      end
      if sample.file_size == nil then
        local dur = sample.duration or 0
        local bps = sample.bps or 0
        sample.file_size = math.max(0, math.floor(bps * dur + 0.5))
      end
    end

    for _, s in ipairs(state.samples) do
      hydrate_sample_runtime(s)
    end
    
    -- Restore scan state if available (for resuming interrupted scans)
    if data.scan_queue and type(data.scan_queue) == "table" and #data.scan_queue > 0 then
      state.scan_queue = data.scan_queue
      state.scan_total = data.scan_total or (#state.samples + #state.scan_queue)
      state.scan_started = data.scan_started or r.time_precise()
      log(string.format("Resuming interrupted scan: %d files remaining", #state.scan_queue))
    end

    -- Restore analyzer state: pending queue, results, and pending flag
    if data.analyzer_queue and type(data.analyzer_queue) == "table" and #data.analyzer_queue > 0 then
      state.analyzer_queue = data.analyzer_queue
    else
      state.analyzer_queue = {}
    end
    if data.analyzer_results and type(data.analyzer_results) == "table" then
      state.analyzer_results = data.analyzer_results
    else
      state.analyzer_results = {}
    end
    -- If analyzers were in flight when saved, re-queue unresolved samples
    if data.analyzer_pending then
      for _, sample in ipairs(state.samples) do
        if not sample.dominant_freq then
          table.insert(state.analyzer_queue, sample.path)
        end
      end
    end
    
    if #state.samples == 0 then
      return false
    end

    -- Check if we need to re-layout samples
    local needs_layout = false

    -- Check if any samples are missing coordinates
    for _, sample in ipairs(state.samples) do
      if not sample.x or not sample.y or
         sample.x < 0 or sample.x > 1 or
         sample.y < 0 or sample.y > 1 then
        needs_layout = true
        break
      end
    end

    -- Re-layout only if coordinates are missing or analyzer results were merged
    if needs_layout then
      layout_samples()
      log("Re-layouting samples (missing/invalid coordinates)")
    else
      log("Using cached coordinates (no layout needed)")
    end

    rebuild_tag_index()
    return true
  else
    log("Cache has no samples field or samples is not a table")
    if data.samples then
      log("  samples type: " .. type(data.samples))
    end
  end
  return false
end


local function save_samples()
  local save_start = r.time_precise()
  
  -- Normalize folder paths before saving
  local t0 = r.time_precise()
  local normalized_folders = {}
  for _, folder in ipairs(state.folders) do
    table.insert(normalized_folders, normalize_path(folder))
  end
  -- Strip runtime-only fields before writing cache
  local function sanitize_sample(sample)
    local out = {}
    for k, v in pairs(sample) do
      if k ~= "samplerate" and k ~= "sample_rate" and k ~= "file_size" and k ~= "hot_color" then
        out[k] = v
      end
    end
    return out
  end

  local sanitized_samples = {}
  for _, s in ipairs(state.samples) do
    sanitized_samples[#sanitized_samples + 1] = sanitize_sample(s)
  end

  local payload = {
    folders = normalized_folders,
    map_seed = state.map_seed,
    samples = sanitized_samples,
    -- Save scan state for resuming
    scan_queue = state.scan_queue,
    scan_total = state.scan_total,
    scan_started = state.scan_started,
    analyzer_queue = state.analyzer_queue,
    analyzer_pending = state.active_processes and #state.active_processes > 0,
    analyzer_results = state.analyzer_results,
  }
  local prep_time = (r.time_precise() - t0) * 1000
  
  -- Pretty-print samples with a newline between each entry for readability
  local function encode_samples_pretty(list)
    local out = {"["}
    for i, s in ipairs(list) do
      out[#out + 1] = json_encode(s)
      if i < #list then
        out[#out + 1] = ",\n"
      end
    end
    out[#out + 1] = "]"
    return table.concat(out)
  end

  local t1 = r.time_precise()
  local samples_str = encode_samples_pretty(payload.samples)
  local json_str = table.concat({
    "{",
    "\"folders\":", json_encode(payload.folders), ",",
    "\"map_seed\":", json_encode(payload.map_seed), ",",
    "\"samples\":", samples_str, ",",
    "\"scan_queue\":", json_encode(payload.scan_queue), ",",
    "\"scan_total\":", json_encode(payload.scan_total), ",",
    "\"scan_started\":", json_encode(payload.scan_started), ",",
    "\"analyzer_queue\":", json_encode(payload.analyzer_queue), ",",
    "\"analyzer_pending\":", json_encode(payload.analyzer_pending), ",",
    "\"analyzer_results\":", json_encode(payload.analyzer_results),
    "}"
  })
  local encode_time = (r.time_precise() - t1) * 1000
  
  local t2 = r.time_precise()
  local file = io.open(DATA_PATH, "w")
  if not file then
    return
  end
  file:write(json_str)
  file:close()
  local write_time = (r.time_precise() - t2) * 1000
  
  local total_save_time = (r.time_precise() - save_start) * 1000
  
  -- Update last save time
  state.last_save_time = r.time_precise()
  
  -- Save timing removed - happens during scanning
end


local function clear_sample_cache()
  os.remove(DATA_PATH)
end

local function filter_samples_by_folders()
  if #state.folders == 0 then
    -- If no folders, clear all samples
    state.samples = {}
    state.active_tags = {}
    state.tag_list = {}
    state.tag_counts = {}
    return
  end

  local filtered_samples = {}
  local removed_count = 0

  for _, sample in ipairs(state.samples) do
    if sample.path then
      local normalized_sample_path = normalize_path(sample.path)
      local keep_sample = false

      -- Check if sample belongs to any of the current folders
      for _, folder in ipairs(state.folders) do
        local normalized_folder = normalize_path(folder)
        if normalized_sample_path:sub(1, #normalized_folder) == normalized_folder then
          keep_sample = true
          break
        end
      end

      if keep_sample then
        table.insert(filtered_samples, sample)
      else
        removed_count = removed_count + 1
      end
    else
      -- Keep samples without path (shouldn't happen but safety check)
      table.insert(filtered_samples, sample)
    end
  end

  state.samples = filtered_samples

  -- Rebuild tag data since samples changed
  state.active_tags = {}
  state.tag_list = {}
  state.tag_counts = {}

  if removed_count > 0 then
    log("Removed " .. removed_count .. " samples from removed folder(s)")
  end
end


-- --- Scanning and analysis ---------------------------------------------------
local function enqueue_scan()
  state.debug_count = 0  -- Reset debug counter for new scan
  state.external_disabled = false
  state.analyzer_warned = false
  
  -- Build set of already-scanned paths for quick lookup (normalize paths to ensure matching)
  local scanned_set = {}
  for _, sample in ipairs(state.samples) do
    if sample.path then
      local normalized_path = normalize_path(sample.path)
      scanned_set[normalized_path] = true
      -- Also store original path mapping in case it's needed
      if normalized_path ~= sample.path then
        scanned_set[sample.path] = true
      end
    end
  end
  
  local paths = {}
  local skipped_count = 0
  
  for _, folder in ipairs(state.folders) do
    -- Normalize folder path
    folder = normalize_path(folder)
    local files_found = 0
    
    local function scan_dir(dir)
      -- Ensure dir path is normalized
      dir = normalize_path(dir)
      
      -- Scan all files in current directory
      local i = 0
      local file = r.EnumerateFiles(dir, i)
      while file do
        local ext = file:match("%.(.+)$")
        if ext then
          ext = "." .. ext:lower()
          if AUDIO_EXTS[ext] then
            -- Use forward slash for macOS
            local full_path = dir .. "/" .. file
            -- Normalize path before checking against scanned_set
            local normalized_full_path = normalize_path(full_path)
            -- Only add if not already scanned
            if not scanned_set[normalized_full_path] and not scanned_set[full_path] then
              table.insert(paths, normalized_full_path)
              files_found = files_found + 1
            else
              skipped_count = skipped_count + 1
            end
          end
        end
        i = i + 1
        file = r.EnumerateFiles(dir, i)
      end
      
      -- Recursively scan all subdirectories
      i = 0
      local subdir = r.EnumerateSubdirectories(dir, i)
      while subdir do
        -- Use forward slash for macOS
        scan_dir(dir .. "/" .. subdir)
        i = i + 1
        subdir = r.EnumerateSubdirectories(dir, i)
      end
    end
    
    -- Try to scan the folder
    local success, err = pcall(scan_dir, folder)
    if not success then
      -- Error scanning folder - silent during scan, errors visible in scan logs
    end
  end
  
  -- If we have existing samples, keep them; otherwise start fresh
  if #state.samples == 0 then
    state.samples = {}
  end
  
  state.scan_queue = paths
  state.scan_total = #paths + skipped_count  -- Total includes already-scanned
  state.scan_started = r.time_precise()
  state.last_save_time = r.time_precise()  -- Initialize save time for time-based saving
  state.active_tags = {}
  state.tag_list = {}
  state.tag_counts = {}
  
  -- Clear analyzer queues for new scan
  state.analyzer_queue = {}
  state.analyzer_results = {}
  state.active_processes = {}
  
  -- Scan start/resume messages removed - use scan logs instead
end


local function analyze_file(path)
  local file_start_time = r.time_precise()
  local timings = {}
  
  -- PCM_Source creation
  local t0 = r.time_precise()
  local src = r.PCM_Source_CreateFromFile(path)
  if not src then
    return nil
  end
  timings.pcm_create = (r.time_precise() - t0) * 1000  -- Convert to ms
  
  -- Get metadata from PCM_Source
  local t1 = r.time_precise()
  local length_ret = {r.GetMediaSourceLength(src)}
  local duration = pick_number(length_ret, 0.0)
  
  local sr_ret = {r.GetMediaSourceSampleRate(src)}
  local sr = pick_number(sr_ret, 44100.0)
  
  local ch_ret = {r.GetMediaSourceNumChannels(src)}
  local ch = math.floor(pick_number(ch_ret, 2))
  timings.pcm_metadata = (r.time_precise() - t1) * 1000

  -- Get file size from PCM_Source if possible (faster than opening file again)
  local t2 = r.time_precise()
  local size = 0
  local size_ret = {r.GetMediaSourceLength(src)}
  local length_in_samples = pick_number(size_ret, 0.0)
  if length_in_samples > 0 and sr > 0 then
    -- Estimate file size: samples * channels * bytes_per_sample
    -- Use average bitrate estimation
    local estimated_bytes = length_in_samples * ch * 2  -- Assume 16-bit (2 bytes)
    -- Try to get actual file size, but fall back to estimate
    local file = io.open(path, "rb")
    if file then
      file:seek("end")
      size = file:seek()
      file:close()
    else
      size = estimated_bytes
    end
  else
    -- Fallback: open file to get size
    local file = io.open(path, "rb")
    if file then
      file:seek("end")
      size = file:seek()
      file:close()
    end
  end
  timings.file_size = (r.time_precise() - t2) * 1000
  
  -- Queue analyzer request instead of blocking (analyzer data will be merged later)
  -- Normalize path before queuing
  local normalized_path = normalize_path(path)
  if not state.external_disabled then
    -- Add to analyzer queue for parallel processing
    table.insert(state.analyzer_queue, normalized_path)
    add_scan_log(string.format("Queued analyzer for: %s", path:match("([^/]+)$") or path))
  else
    add_scan_log(string.format("Analyzer disabled, skipping: %s", path:match("([^/]+)$") or path))
  end
  
  local t4 = r.time_precise()
  r.PCM_Source_Destroy(src)
  timings.pcm_destroy = (r.time_precise() - t4) * 1000
  
  local avg_bps = size / math.max(duration, 0.01)
  -- Normalize path to use forward slashes
  path = normalize_path(path)
  
  -- Get tags from path first
  local t5 = r.time_precise()
  local tags = infer_tags_from_path(path, path:match("(.+)/[^/]+$") or "")
  timings.tags = (r.time_precise() - t5) * 1000
  
  -- File timing logs removed - happens during scanning
  
  -- Note: Analyzer tags (Drum/Swell) will be added later when analyzer data is merged
  
  -- Detect Loop or One shot based on filename/path patterns
  local sample_type_detected = detect_loop_or_oneshot(path, path:match("(.+)/[^/]+$") or "")
  if sample_type_detected then
    -- Check if tag already exists (avoid duplicates)
    local has_tag = false
    for _, tag in ipairs(tags) do
      if tag == sample_type_detected then
        has_tag = true
        break
      end
    end
    if not has_tag then
      table.insert(tags, sample_type_detected)
    end
  end
  
  -- Return sample without analyzer data initially (will be merged later)
  return {
    path = normalized_path,
    name = normalized_path:match("([^/]+)$"),  -- macOS uses forward slashes only
    folder = normalized_path:match("(.+)/[^/]+$") or "",
    duration = duration,
    samplerate = sr,
    channels = ch,
    bps = avg_bps,
    file_size = size,  -- Store file size for Y axis fallback
    dominant_freq = nil,  -- Will be set when analyzer completes
    rms_energy = nil,     -- Will be set when analyzer completes
    sample_type = nil,    -- Will be set when analyzer completes
    snap_offset = nil,    -- Will be set when analyzer completes
    tags = tags
  }
end


local function process_scan_slice(max_ms)
  max_ms = max_ms or 15.0

  -- Manage analyzer process pool (start new processes, check for completed ones)
  process_analyzer_queue()

  -- Merge completed analyzer results into samples
  local merged_count = 0
  add_scan_log(string.format("Merging %d analyzer results", #state.analyzer_results))
  for path, result in pairs(state.analyzer_results) do
    -- Find matching sample by path
    local found_sample = false
    for _, sample in ipairs(state.samples) do
      if sample.path == path then
        -- Merge analyzer data into sample
        if result.data then
          -- Debug: log successful merge
          add_scan_log(string.format("Merged analyzer data for %s: freq=%.1f, rms=%.3f", path:match("([^/]+)$") or path, result.data.dominant_freq or 0, result.data.rms_energy or 0))
          sample.dominant_freq = result.data.dominant_freq
          sample.rms_energy = result.data.rms_energy
          sample.sample_type = result.data.sample_type
          sample.snap_offset = result.data.snap_offset

          -- Add Drum or Swell tag if detected by analyzer
          if result.data.sample_type and (result.data.sample_type == "Drum" or result.data.sample_type == "Swell") then
            local has_tag = false
            for _, tag in ipairs(sample.tags) do
              if tag == result.data.sample_type then
                has_tag = true
                break
              end
            end
            if not has_tag then
              table.insert(sample.tags, result.data.sample_type)
            end
          end
          merged_count = merged_count + 1
        elseif result.err then
          add_scan_log(string.format("Failed to merge analyzer data for %s: %s", path:match("([^/]+)$") or path, result.err))
        end
        found_sample = true
        break
      end
    end

    if not found_sample then
      add_scan_log(string.format("Could not find sample for analyzer result: %s", path))
    end

    -- Remove from results after merging
    state.analyzer_results[path] = nil
  end

  if merged_count > 0 then
    add_scan_log(string.format("Successfully merged %d analyzer results", merged_count))
  end

  -- If analyzer results were merged, re-layout samples since positions may have changed
  if merged_count > 0 then
    layout_samples()
  end
  
  -- DISABLED: Time-based saving during scan (only save at end)
  -- If analyzer results were merged, persist them on a timer so dominant_freq/rms
  -- don't remain nil in the cache (which would later default to 440 Hz on reload)
  -- local current_time = r.time_precise()
  -- local time_since_last_save = current_time - state.last_save_time
  -- if merged_count > 0 and time_since_last_save >= 2.0 then
  --   save_samples()
  --   state.last_save_time = current_time
  --   time_since_last_save = 0
  -- end
  
  -- Check if scan just completed (queue is empty but scan was started)
  -- This handles the case where rescan is clicked but there are no new files
  -- Also check if analyzer queue is empty and no active processes
  local scan_complete = (#state.scan_queue == 0 and state.scan_started > 0 and state.scan_total > 0)
  local analyzer_complete = (#state.analyzer_queue == 0 and #state.active_processes == 0)
  local finished_this_frame = false
  
  if scan_complete and analyzer_complete then
    -- Final save to ensure merged analyzer data is cached
    save_samples()
    state.last_save_time = r.time_precise()
    -- Scan completed (either just finished or was empty from start)
    -- Count samples with tags before rebuilding index
    local samples_with_tags = 0
    for _, s in ipairs(state.samples) do
      if s.tags and type(s.tags) == "table" and #s.tags > 0 then
        samples_with_tags = samples_with_tags + 1
      end
    end
    -- Scan completion log removed - use scan logs instead
    -- Rebuild tag index to ensure tags are preserved
    rebuild_tag_index()
    state.scan_started = 0  -- Reset to indicate scan is complete
    finished_this_frame = true  -- Continue to layout below
  end
  
  if #state.scan_queue == 0 then
    -- No more files to process; if analyzer still running, wait for completion
    if not analyzer_complete then
      return
    end
  end
  
  local deadline = r.time_precise() + (max_ms / 1000.0)
  math.randomseed(state.map_seed)
  
  local processed = 0
  local should_save = false
  local last_log_count = state.scan_total - #state.scan_queue
  local slice_start_time = r.time_precise()
  local total_analyze_time = 0
  local total_other_time = 0
  
  while #state.scan_queue > 0 and r.time_precise() < deadline do
    local path = table.remove(state.scan_queue)
    local file_start = r.time_precise()
    local sample = analyze_file(path)
    local file_time = (r.time_precise() - file_start) * 1000
    
    if sample then
      table.insert(state.samples, sample)
      processed = processed + 1
      should_save = true
      total_analyze_time = total_analyze_time + file_time
    else
      total_other_time = total_other_time + file_time
    end
  end
  
  -- Slice timing and progress logs removed - use scan logs instead
  
  -- DISABLED: Time-based cache saving during scan (only save at end)
  -- Time-based cache saving (every 2 seconds)
  -- current_time = r.time_precise()
  -- time_since_last_save = current_time - state.last_save_time
  -- if should_save and time_since_last_save >= 2.0 then
  --   save_samples()
  --   state.last_save_time = current_time
  -- end
  
  -- DISABLED: Incremental saving during scan (only save at end)
  -- Save progress incrementally (every 50 files or when queue is empty) - reduced frequency for speed
  -- if should_save and (processed >= 50 or #state.scan_queue == 0) then
  --   save_samples()
  --   state.last_save_time = current_time
  -- end
  
  if #state.scan_queue == 0 then
    -- Count samples with tags before layout
    local samples_with_tags_before = 0
    for _, s in ipairs(state.samples) do
      if s.tags and type(s.tags) == "table" and #s.tags > 0 then
        samples_with_tags_before = samples_with_tags_before + 1
      end
    end
    -- Scan complete log removed - use scan logs instead
    -- Layout samples
    layout_samples()
    -- Count samples with tags after layout
    local samples_with_tags_after = 0
    for _, s in ipairs(state.samples) do
      if s.tags and type(s.tags) == "table" and #s.tags > 0 then
        samples_with_tags_after = samples_with_tags_after + 1
      end
    end
    -- Analysis complete log removed - use scan logs instead
    rebuild_tag_index()
    save_samples()
  end
end


-- --- Frequency analysis for spectral waveform ----------------------------------
-- Estimate dominant frequency using autocorrelation with zero-crossing fallback
local function estimate_dominant_frequency(samples, sample_rate)
  if not samples or #samples < 16 then
    return nil  -- Need at least 16 samples for meaningful analysis
  end

  local n = #samples

  -- For large sample sets, downsample to improve performance while maintaining frequency resolution
  local analysis_samples = samples
  local analysis_sr = sample_rate
  if n > 512 then
    -- Downsample to ~512 samples to balance performance and accuracy
    local downsample_factor = math.floor(n / 512)
    analysis_samples = {}
    analysis_sr = sample_rate / downsample_factor

    for i = 1, n, downsample_factor do
      table.insert(analysis_samples, samples[i])
    end
    n = #analysis_samples
  end

  -- Normalize samples (center around zero and normalize amplitude)
  local sum = 0.0
  local max_amp = 0.0
  for i = 1, n do
    sum = sum + analysis_samples[i]
    max_amp = math.max(max_amp, math.abs(analysis_samples[i]))
  end

  if max_amp < 1e-6 then
    return nil  -- Silence
  end

  -- Remove DC offset and normalize
  local mean = sum / n
  local normalized = {}
  for i = 1, n do
    normalized[i] = (analysis_samples[i] - mean) / max_amp
  end

  -- Try autocorrelation first (more accurate for periodic signals)
  -- Focus on musical frequency range: 80Hz to 8000Hz (covers most instruments)
  local max_freq = 8000  -- Look for frequencies up to 8kHz
  local min_freq = 80    -- Minimum frequency to detect (below this, likely noise or rumble)
  local min_lag = math.floor(analysis_sr / max_freq)
  local max_lag = math.floor(analysis_sr / min_freq)

  min_lag = math.max(2, min_lag)
  max_lag = math.min(max_lag, math.floor(n / 2))

  if max_lag >= min_lag then
    -- Calculate autocorrelation at lag 0 for normalization
    local autocorr_0 = 0.0
    for i = 1, n do
      autocorr_0 = autocorr_0 + normalized[i] * normalized[i]
    end
    autocorr_0 = autocorr_0 / n

    if autocorr_0 > 1e-10 then
      -- Autocorrelation - look for the strongest peak in the musical range
      local max_corr = -math.huge
      local best_lag = nil

      for lag = min_lag, max_lag do
        local corr = 0.0
        local count = 0

        for i = 1, n - lag do
          corr = corr + normalized[i] * normalized[i + lag]
          count = count + 1
        end

        if count > 0 then
          -- Normalize autocorrelation
          corr = corr / count
          corr = corr / autocorr_0  -- Normalize by autocorrelation at lag 0

          if corr > max_corr then
            max_corr = corr
            best_lag = lag
          end
        end
      end

      -- Require a minimum correlation threshold to avoid noise
      if best_lag and best_lag > 0 and max_corr > 0.3 then  -- Higher threshold for better accuracy
        local freq = analysis_sr / best_lag
        -- Clamp to audible range (20Hz to 20kHz)
        freq = math.max(20, math.min(20000, freq))
        return freq
      end
    end
  end

  -- Fallback: Zero-crossing rate estimation (simpler but less accurate)
  -- Count zero crossings to estimate frequency
  local zero_crossings = 0
  for i = 2, n do
    if (normalized[i-1] >= 0 and normalized[i] < 0) or (normalized[i-1] < 0 and normalized[i] >= 0) then
      zero_crossings = zero_crossings + 1
    end
  end

  if zero_crossings > 2 then
    -- Each zero crossing represents half a cycle
    local cycles = zero_crossings / 2
    local duration = n / analysis_sr
    local freq = cycles / duration
    -- Clamp to audible range
    freq = math.max(20, math.min(20000, freq))
    return freq
  end

  return nil
end

-- Convert frequency to color (spectral mapping: low=red, mid=yellow/green, high=blue)
local function frequency_to_color(freq)
  if not freq then
    return 0x888888FF  -- Gray for no frequency data
  end
  
  -- Map frequency to hue (0-360 degrees)
  -- 20Hz = red (0°), 2000Hz = yellow (60°), 20000Hz = blue (240°)
  local hue
  if freq < 2000 then
    -- Low to mid: red to yellow (0° to 60°)
    local t = (freq - 20) / (2000 - 20)
    hue = t * 60
  elseif freq < 8000 then
    -- Mid to high-mid: yellow to cyan (60° to 180°)
    local t = (freq - 2000) / (8000 - 2000)
    hue = 60 + t * 120
  else
    -- High: cyan to blue (180° to 240°)
    local t = (freq - 8000) / (20000 - 8000)
    hue = 180 + t * 60
  end
  
  -- Convert HSV to RGB
  local c = 1.0  -- Chroma
  local x = c * (1 - math.abs((hue / 60) % 2 - 1))
  local m = 0.3  -- Lightness adjustment (make it darker for visibility)
  
  local r, g, b = 0, 0, 0
  if hue < 60 then
    r, g, b = c, x, 0
  elseif hue < 120 then
    r, g, b = x, c, 0
  elseif hue < 180 then
    r, g, b = 0, c, x
  elseif hue < 240 then
    r, g, b = 0, x, c
  else
    r, g, b = x, 0, c
  end
  
  -- Convert to 0-255 and apply lightness
  r = math.floor((r + m) * 255)
  g = math.floor((g + m) * 255)
  b = math.floor((b + m) * 255)
  
  -- Clamp values
  r = math.max(0, math.min(255, r))
  g = math.max(0, math.min(255, g))
  b = math.max(0, math.min(255, b))
  
  -- Return as ARGB (0xAARRGGBB format)
  return (0xFF << 24) | (r << 16) | (g << 8) | b
end

-- --- Waveform generation -----------------------------------------------------
local function generate_waveform(sample, width)
  width = width or waveform_width
  if not sample or not sample.path then
    return nil
  end
  
  -- Create a temporary track and item to access audio samples via AudioAccessor
  local temp_track = r.GetTrack(0, 0)  -- Try to use first track
  if not temp_track then
    temp_track = r.InsertTrackAtIndex(0, true)
  end
  
  if not temp_track then
    log("Failed to create/get track for waveform generation")
    return nil
  end
  
  -- Insert media item
  local item = r.AddMediaItemToTrack(temp_track)
  if not item then
    log("Failed to create media item for waveform")
    return nil
  end
  
  -- Set item position
  r.SetMediaItemPosition(item, 0, false)
  local src = r.PCM_Source_CreateFromFile(sample.path)
  if not src then
    r.DeleteTrackMediaItem(temp_track, item)
    log("Failed to create PCM source for waveform")
    return nil
  end
  
  local length_ret = {r.GetMediaSourceLength(src)}
  local duration = pick_number(length_ret, 0.0)
  if duration <= 0 then
    r.PCM_Source_Destroy(src)
    r.DeleteTrackMediaItem(temp_track, item)
    return nil
  end
  
  r.SetMediaItemLength(item, duration, false)
  
  -- Add take
  local take = r.AddTakeToMediaItem(item)
  if not take then
    r.PCM_Source_Destroy(src)
    r.DeleteTrackMediaItem(temp_track, item)
    log("Failed to create take for waveform")
    return nil
  end
  
  r.SetMediaItemTake_Source(take, src)
  r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0.0)
  
  -- Note: After SetMediaItemTake_Source, REAPER owns the src, so don't destroy it manually
  
  -- We create/destroy a fresh accessor per pixel below.
  -- Only check API availability here.
  if not r.APIExists("GetAudioAccessorSamples") then
    log("GetAudioAccessorSamples API not available in this REAPER version")
    -- Note: Don't destroy src here - it's owned by the take/item
    r.DeleteTrackMediaItem(temp_track, item)
    return nil
  end
  
  local sr_ret = {r.GetMediaSourceSampleRate(src)}
  local sr = pick_number(sr_ret, 44100.0)
  
  local ch_ret = {r.GetMediaSourceNumChannels(src)}
  local channels = math.max(1, math.floor(pick_number(ch_ret, 2)))  -- Ensure at least 1 channel
  
  -- Calculate samples to read per pixel
  -- Ensure we read at least 128 samples per pixel for better frequency analysis
  local samples_per_pixel = math.max(128, math.floor((duration * sr) / width))
  
  -- Store waveform data per channel (for stereo: separate left/right)
  local waveform_channels = {}
  local frequency_channels = {}  -- Store frequency data per channel per pixel
  for c = 0, channels - 1 do
    waveform_channels[c] = {}
    frequency_channels[c] = {}
  end
  local max_val_per_channel = {}
  for c = 0, channels - 1 do
    max_val_per_channel[c] = 0.0
  end
  
  -- Read samples for each pixel
  local pixel_idx = 0
  
  while pixel_idx < width do
    
    -- Read samples (REAPER's PCM_Source API)
    -- Note: REAPER doesn't have a direct ReadSamples API in Lua
    -- We'll use a workaround: create a temporary take and read from it
    -- For now, let's use a simpler approach: sample at regular intervals
    
    -- Calculate RMS for this pixel's worth of samples
    -- Since we can't easily read raw samples, we'll use a simplified approach
    -- by sampling at regular time intervals
    local time_per_pixel = duration / width
    local time_at_pixel = pixel_idx * time_per_pixel
    
    -- Use REAPER's ability to get peak info at a specific time
    -- This is a simplified waveform - we'll use duration-based estimation
    -- For a more accurate waveform, we'd need to read actual samples
    
    -- For now, create a placeholder waveform based on file properties
    -- In a full implementation, you'd read actual sample data
    -- Calculate RMS for this pixel using AudioAccessor
    local time_start = (pixel_idx) * (duration / width)
    local time_end = (pixel_idx + 1) * (duration / width)
    local time_center = (time_start + time_end) * 0.5
    
    -- For frequency analysis, we need a longer time window to capture low frequencies
    -- Use a wider window: current pixel plus some surrounding context
    local analysis_window_start = math.max(0, time_start - 0.01)  -- 10ms before
    local analysis_window_end = math.min(duration, time_end + 0.01)  -- 10ms after
    local analysis_window_duration = analysis_window_end - analysis_window_start

    -- Read enough samples for frequency analysis (aim for 256-1024 samples for good analysis)
    local target_samples = math.max(256, math.floor(analysis_window_duration * sr))
    target_samples = math.min(target_samples, 1024)  -- Cap at 1024 to avoid excessive processing
    local max_samples_for_window = math.floor(analysis_window_duration * sr)
    local read_samples = math.min(target_samples, max_samples_for_window)
    read_samples = math.max(64, read_samples)  -- Minimum 64 samples for frequency analysis

    -- For very short windows, try to read more samples by extending the window
    if read_samples < 256 and analysis_window_start > 0.02 then
      -- Extend backward if possible
      analysis_window_start = math.max(0, analysis_window_start - 0.02)
      analysis_window_duration = analysis_window_end - analysis_window_start
      read_samples = math.min(1024, math.floor(analysis_window_duration * sr))
      read_samples = math.max(64, read_samples)
    elseif read_samples < 256 and analysis_window_end < duration - 0.02 then
      -- Extend forward if possible
      analysis_window_end = math.min(duration, analysis_window_end + 0.02)
      analysis_window_duration = analysis_window_end - analysis_window_start
      read_samples = math.min(1024, math.floor(analysis_window_duration * sr))
      read_samples = math.max(64, read_samples)
    end

    local buf_size = read_samples * channels
    local buf = r.new_array(buf_size)

    -- Debug logging for analysis window setup
    if pixel_idx < 3 then
      log(string.format("Pixel %d: analysis_window=%.3fs-%.3fs (%.1fms), target_samples=%d, read_samples=%d",
          pixel_idx + 1, analysis_window_start, analysis_window_end, analysis_window_duration * 1000, target_samples, read_samples))
    end
    
    -- Create a fresh accessor for each pixel to avoid positioning issues
    local pixel_accessor = r.CreateTakeAudioAccessor(take)
    if not pixel_accessor then
      log("Failed to create accessor for pixel " .. (pixel_idx + 1))
      if buf and buf.clear then
        buf.clear(buf)
      end
      for c = 0, channels - 1 do
        waveform_channels[c][pixel_idx + 1] = 0.1
        frequency_channels[c][pixel_idx + 1] = nil
      end
      pixel_idx = pixel_idx + 1
    elseif not r.GetAudioAccessorSamples then
      log("ERROR: GetAudioAccessorSamples not available - waveform generation will fail")
      r.DestroyAudioAccessor(pixel_accessor)
      if buf and buf.clear then
        buf.clear(buf)
      end
      for c = 0, channels - 1 do
        waveform_channels[c][pixel_idx + 1] = 0.1
        frequency_channels[c][pixel_idx + 1] = nil
      end
      pixel_idx = pixel_idx + 1
    else
      -- Read from analysis window to get samples for frequency analysis
      local samples_read = r.GetAudioAccessorSamples(pixel_accessor, sr, channels, analysis_window_start, read_samples, buf)

      -- Clean up the pixel accessor
      r.DestroyAudioAccessor(pixel_accessor)

      -- Debug logging for first few pixels
      if pixel_idx < 3 then
        log(string.format("Pixel %d: samples_read=%s, read_samples=%d, buf_size=%d, channels=%d, sr=%.0f, analysis_start=%.3f, analysis_end=%.3f", 
            pixel_idx + 1, tostring(samples_read), read_samples, buf_size, channels, sr, analysis_window_start, analysis_window_end))
      end
      
      if samples_read and samples_read > 0 and buf then
        -- GetAudioAccessorSamples returns the number of sample frames read (not total samples)
        -- Each frame contains one sample per channel
        local actual_frames = samples_read

        if pixel_idx < 3 then
          log(string.format("Pixel %d: Got %d sample frames (%d total samples across %d channels)",
              pixel_idx + 1, actual_frames, actual_frames * channels, channels))
        end
        
        -- Calculate RMS per channel for this pixel
        local sum_sq_per_channel = {}
        local count_per_channel = {}
        for c = 0, channels - 1 do
          sum_sq_per_channel[c] = 0.0
          count_per_channel[c] = 0
        end
        
        -- Debug: check first few buffer values for first pixel
        if pixel_idx < 1 and channels >= 2 then
          local debug_vals = {}
          -- REAPER arrays are 1-indexed, so we need to add 1 to the index
          for i = 0, math.min(5, buf_size - 1) do
            local buf_idx = i + 1  -- Convert to 1-based index
            local ok, val = pcall(function() return buf[buf_idx] end)
            if ok then
              debug_vals[i] = val
            else
              debug_vals[i] = "ERROR"
            end
          end
          -- Use %s to avoid errors if values are non-numeric
          log(string.format("Pixel %d buffer first 6 values: [0]=%s [1]=%s [2]=%s [3]=%s [4]=%s [5]=%s", 
              pixel_idx + 1, tostring(debug_vals[0] or 0), tostring(debug_vals[1] or 0), tostring(debug_vals[2] or 0), 
              tostring(debug_vals[3] or 0), tostring(debug_vals[4] or 0), tostring(debug_vals[5] or 0)))
        end
        
        -- Extract samples per channel for frequency analysis
        local channel_samples = {}
        for c = 0, channels - 1 do
          channel_samples[c] = {}
        end
        
        for j = 0, actual_frames - 1 do
          for c = 0, channels - 1 do
            -- REAPER arrays are 1-indexed, interleaved: [sample0_ch0, sample0_ch1, sample1_ch0, sample1_ch1, ...]
            -- Calculate 0-based index, then add 1 for 1-based array access
            local idx_0based = j * channels + c
            local buf_idx = idx_0based + 1  -- Convert to 1-based index for REAPER arrays
            if idx_0based >= 0 and idx_0based < buf_size then
              local ok, sample_val = pcall(function() return buf[buf_idx] end)
              if ok and sample_val ~= nil then
                sum_sq_per_channel[c] = sum_sq_per_channel[c] + (sample_val * sample_val)
                count_per_channel[c] = count_per_channel[c] + 1
                table.insert(channel_samples[c], sample_val)
              else
                if pixel_idx < 3 then
                  log(string.format("WARNING: Pixel %d, frame %d, ch %d: failed to read buf[%d] (1-based)", pixel_idx + 1, j, c, buf_idx))
                end
              end
            else
              if pixel_idx < 3 and c == 0 then
                log(string.format("WARNING: Pixel %d, frame %d, ch %d: idx %d out of bounds (buf_size=%d)", 
                    pixel_idx + 1, j, c, idx_0based, buf_size))
              end
            end
          end
        end
        
        -- Calculate RMS and frequency for each channel
        for c = 0, channels - 1 do
          if count_per_channel[c] > 0 then
            local rms = math.sqrt(sum_sq_per_channel[c] / count_per_channel[c])
            waveform_channels[c][pixel_idx + 1] = rms
            max_val_per_channel[c] = math.max(max_val_per_channel[c], rms)
            
            -- Estimate dominant frequency for this pixel/channel
            local freq = estimate_dominant_frequency(channel_samples[c], sr)
            frequency_channels[c][pixel_idx + 1] = freq
            
            -- Debug first few pixels for all channels
            if pixel_idx < 3 then
              local sample_count = channel_samples[c] and #channel_samples[c] or 0
              local first_sample = (channel_samples[c] and channel_samples[c][1]) or 0
              log(string.format("Pixel %d: time=%.3f, ch%d_rms=%.6f, ch%d_freq=%sHz, sample_count=%d, first_sample=%.6f", 
                  pixel_idx + 1, time_center, c, rms, c, freq and string.format("%.1f", freq) or "nil", sample_count, first_sample))
            end
          else
            waveform_channels[c][pixel_idx + 1] = 0.0
            frequency_channels[c][pixel_idx + 1] = nil
            if pixel_idx < 3 then
              log(string.format("WARNING: Pixel %d ch%d got 0 samples (buf_size=%d, read_samples=%d, actual_frames=%d, channels=%d)", 
                  pixel_idx + 1, c, buf_size, read_samples, actual_frames, channels))
            end
          end
        end
      else
        for c = 0, channels - 1 do
          waveform_channels[c][pixel_idx + 1] = 0.0
        end
        if pixel_idx < 3 then
          log(string.format("WARNING: GetAudioAccessorSamples failed for pixel %d: samples_read=%s, buf=%s", 
              pixel_idx + 1, tostring(samples_read), tostring(buf ~= nil)))
        end
      end
      
      if buf and buf.clear then
        buf.clear(buf)
      end
    end
    
    pixel_idx = pixel_idx + 1
  end
  
  -- Cleanup (accessors are destroyed per pixel now)
  -- Note: Don't destroy src - it's owned by the take/item, will be cleaned up when item is deleted
  r.DeleteTrackMediaItem(temp_track, item)
  
  -- Normalize waveforms per channel
  for c = 0, channels - 1 do
    local max_val = max_val_per_channel[c]
    log(string.format("Channel %d max_val before normalization: %.6f", c, max_val))
    if max_val > 0.001 then
      for i = 1, #waveform_channels[c] do
        waveform_channels[c][i] = waveform_channels[c][i] / max_val
      end
      log(string.format("Channel %d waveform normalized successfully", c))
    else
      -- If all values are very small, log warning and use a small value
      log("WARNING: Channel " .. c .. " max_val is very small (" .. string.format("%.6f", max_val) .. "), using placeholder")
      for i = 1, #waveform_channels[c] do
        waveform_channels[c][i] = 0.1
      end
    end
  end
  
  -- Log first few values for debugging (all channels)
  for c = 0, channels - 1 do
    if #waveform_channels[c] > 0 then
      local debug_str = string.format("First 5 waveform values (ch%d): ", c)
      for i = 1, math.min(5, #waveform_channels[c]) do
        debug_str = debug_str .. string.format("%.6f ", waveform_channels[c][i])
      end
      log(debug_str)
      
      -- Count non-zero values
      local non_zero_count = 0
      for i = 1, #waveform_channels[c] do
        if waveform_channels[c][i] and waveform_channels[c][i] > 0.0001 then
          non_zero_count = non_zero_count + 1
        end
      end
      log(string.format("Channel %d: %d total pixels, %d non-zero values", c, #waveform_channels[c], non_zero_count))
    else
      log(string.format("WARNING: Channel %d has no waveform data!", c))
    end
  end
  
  -- Return channel data: for mono, return single array; for stereo+, return table with channel arrays
  local waveform_data = {}
  local frequency_data = {}
  if channels == 1 then
    -- Mono: return single array for backward compatibility
    waveform_data.data = waveform_channels[0]
    frequency_data.data = frequency_channels[0]
    log("Returning mono waveform data")
  else
    -- Multi-channel: return table with channel arrays
    waveform_data.channel_data = {}
    frequency_data.channel_data = {}
    for c = 0, channels - 1 do
      waveform_data.channel_data[c] = waveform_channels[c]
      frequency_data.channel_data[c] = frequency_channels[c]
      log(string.format("Channel %d: %d pixels in channel_data", c, #waveform_channels[c]))
    end
    -- Also provide 'data' for backward compatibility (use first channel)
    waveform_data.data = waveform_channels[0]
    frequency_data.data = frequency_channels[0]
    local ch_data_count = 0
    if waveform_data.channel_data then
      for k, v in pairs(waveform_data.channel_data) do
        ch_data_count = ch_data_count + 1
      end
    end
    log(string.format("Multi-channel waveform: %d channels, channel_data has %d entries", 
        channels, ch_data_count))
  end
  
  local result = {
    data = waveform_data.data,  -- For backward compatibility
    channel_data = waveform_data.channel_data,  -- Per-channel data (nil for mono)
    frequency_data = frequency_data.data,  -- Frequency data for mono (backward compatibility)
    frequency_channel_data = frequency_data.channel_data,  -- Per-channel frequency data (nil for mono)
    duration = duration,
    sample_rate = sr,
    channels = channels
  }
  
  log(string.format("Waveform generation complete: channels=%d, data points=%d, channel_data=%s", 
      channels, result.data and #result.data or 0, result.channel_data and "present" or "nil"))
  
  return result
end


-- --- Preview handling --------------------------------------------------------
local function release_preview_source()
  if not preview_source then
    preview_source_engine_owned = false
    return
  end

  if preview_source_engine_owned then
    preview_source = nil
    preview_source_engine_owned = false
    return
  end

  if r.PCM_Source_Destroy then
    local can_destroy = false

    if r.GetMediaSourceLength then
      local ok = pcall(function() return r.GetMediaSourceLength(preview_source) end)
      if ok then
        can_destroy = true
      end
    end

    if not can_destroy and r.ValidatePtr2 then
      local ok, valid = pcall(function() return r.ValidatePtr2(0, preview_source, "PCM_source*") end)
      if ok and valid then
        can_destroy = true
      end
    end

    if not can_destroy and r.ValidatePtr then
      local ok, valid = pcall(function() return r.ValidatePtr(preview_source, "PCM_source*") end)
      if ok and valid then
        can_destroy = true
      end
    end

    if can_destroy then
      pcall(function() r.PCM_Source_Destroy(preview_source) end)
    end
  end

  preview_source = nil
  preview_source_engine_owned = false
end

local function stop_preview()
  -- Stop CF_Preview instances first (uses objects, not IDs)
  if cf_preview_obj then
    if r.CF_Preview_StopAll then
      r.CF_Preview_StopAll()
    elseif r.CF_Preview_Stop then
      r.CF_Preview_Stop(cf_preview_obj)
    end
    cf_preview_obj = nil
  elseif r.CF_Preview_StopAll then
    -- Stop all CF_Preview instances even if we don't have a handle
    r.CF_Preview_StopAll()
  end

  -- Stop preview using Xen_StopSourcePreview if we have an integer preview ID
  if preview_proc and type(preview_proc) == "number" and r.Xen_StopSourcePreview then
    r.Xen_StopSourcePreview(preview_proc)
    preview_proc = nil
  elseif preview_proc and type(preview_proc) == "number" and r.StopSourcePreview then
    r.StopSourcePreview(preview_proc)
    preview_proc = nil
  elseif preview_source then
    -- Stop track preview style APIs
    if r.StopTrackPreview2 and preview_track then
      r.StopTrackPreview2(preview_source, preview_track)
    elseif r.StopTrackPreview then
      r.StopTrackPreview(preview_source)
    end
    preview_proc = nil
  end

  release_preview_source()

  preview_start_time = 0.0
  preview_proc = nil
end


-- --- History navigation --------------------------------------------------------
local function preview_sample_from_history(sample)
  -- Preview a sample without adding it to history (used for navigation)
  local start_time = 0.0
  
  if not sample or not sample.path then
    return
  end
  
  -- Stop current preview before starting new one
  stop_preview()
  
  preview_sample_obj = sample
  preview_start_time = r.time_precise() - start_time
  state.preview_position = start_time
  state.preview_paused = false
  -- Reset breathing cycle when navigating to a sample
  state.breathing_start_time = r.time_precise()
  
  -- Generate waveform if not already cached
  if not waveform_data or waveform_data.sample_path ~= sample.path then
    log("Generating waveform for: " .. sample.name)
    waveform_data = generate_waveform(sample)
    if waveform_data then
      waveform_data.sample_path = sample.path
      log("Waveform generated successfully: " .. #waveform_data.data .. " points")
    else
      log("WARNING: Waveform generation failed for: " .. sample.name)
      waveform_data = {
        data = {},
        duration = sample.duration or 1.0,
        sample_rate = sample.samplerate or 44100,
        channels = sample.channels or 2,
        sample_path = sample.path,
        frequency_data = {}  -- Empty frequency data (will show gray)
      }
      for i = 1, waveform_width do
        waveform_data.data[i] = 0.1
        waveform_data.frequency_data[i] = nil  -- No frequency data
      end
    end
  end
  
  -- Create PCM_source and start preview (same as preview_sample)
  preview_source = r.PCM_Source_CreateFromFile(sample.path)
  preview_source_engine_owned = false
  if not preview_source then
    log("Failed to create preview source for: " .. tostring(sample.path))
    return
  end

  -- Try CF_Preview API first
  if r.CF_CreatePreview and r.CF_Preview_SetValue and r.CF_Preview_Play then
    cf_preview_obj = r.CF_CreatePreview(preview_source)
    if cf_preview_obj then
      r.CF_Preview_SetValue(cf_preview_obj, "D_VOLUME", state.preview_volume or 1.0)
      if start_time > 0 then
        r.CF_Preview_SetValue(cf_preview_obj, "D_POSITION", start_time)
      end
      local ret = r.CF_Preview_Play(cf_preview_obj)
      if ret then
        preview_proc = true
        preview_start_time = r.time_precise() - start_time
        state.pop_start_time = r.time_precise()  -- Trigger pop effect
      else
        cf_preview_obj = nil
      end
    end
  elseif r.PlayTrackPreview2 then
    local track = ensure_preview_track()
    if track then
      local preview = {
        src = preview_source,
        startpos = start_time,
        volume = state.preview_volume or 1.0,
        pan = 0.0,
        loop = false,
        length = -1.0,
        fadein = 0.0,
        fadeout = 0.0,
        pitch = 0.0,
        mode = 0,
      }
      local ret = r.PlayTrackPreview2(0, preview, track)
      if ret then
        preview_proc = true
        preview_start_time = r.time_precise() - start_time
        state.pop_start_time = r.time_precise()  -- Trigger pop effect
      end
    end
  elseif r.Xen_StartSourcePreview then
    local preview_id = r.Xen_StartSourcePreview(preview_source, state.preview_volume or 1.0, false)
    if preview_id and preview_id ~= 0 then
      preview_proc = preview_id
      preview_source_engine_owned = true
      preview_start_time = r.time_precise()
      state.pop_start_time = r.time_precise()  -- Trigger pop effect
    end
  end

  if not preview_proc and not cf_preview_obj then
    release_preview_source()
  end
end


local function navigate_history(direction)
  -- direction: -1 for back (up arrow), 1 for forward (down arrow)
  -- history_index: 0 = current sample, 1+ = index in played_history array
  
  local new_index = state.history_index + direction
  
  -- Clamp to valid range
  if new_index < 0 then
    return  -- Can't go back further than current
  elseif new_index > #state.played_history then
    return  -- Can't go forward past oldest
  end
  
  -- If going back from current (index 0) to history, need at least one item
  if new_index > 0 and #state.played_history == 0 then
    return
  end
  
  state.history_index = new_index
  
  local sample = nil
  if new_index == 0 then
    -- Back to current sample
    sample = preview_sample_obj
  else
    -- Navigate to history entry
    sample = state.played_history[new_index]  -- Lua arrays are 1-indexed
  end
  
  if sample and sample.path then
    preview_sample_from_history(sample)
  end
end


local function preview_sample(sample, start_time)
  start_time = math.max(0.0, start_time or 0.0)
  
  if not sample or not sample.path then
    return
  end
  
  -- Add current sample to history if it exists and is different from the new one
  if preview_sample_obj and preview_sample_obj.path and preview_sample_obj.path ~= sample.path then
    -- Insert at the beginning of history
    table.insert(state.played_history, 1, preview_sample_obj)
    -- Limit history size to 100 entries
    if #state.played_history > 100 then
      table.remove(state.played_history, #state.played_history)
    end
  end
  
  -- Reset history index when playing a new sample (not navigating history)
  state.history_index = 0
  
  -- Stop current preview before starting new one (as per example script pattern)
  stop_preview()

  preview_sample_obj = sample
  preview_start_time = r.time_precise() - start_time
  state.preview_position = start_time
  state.preview_paused = false
  -- Reset breathing cycle when a new sample is clicked
  state.breathing_start_time = r.time_precise()
  
  -- Generate waveform if not already cached
  if not waveform_data or waveform_data.sample_path ~= sample.path then
    log("Generating waveform for: " .. sample.name)
    waveform_data = generate_waveform(sample)
    if waveform_data then
      waveform_data.sample_path = sample.path
      log("Waveform generated successfully: " .. #waveform_data.data .. " points")
    else
      log("WARNING: Waveform generation failed for: " .. sample.name)
      -- Create a placeholder waveform so something shows
      local channels = sample.channels or 2
      waveform_data = {
        data = {},
        duration = sample.duration or 1.0,
        sample_rate = sample.samplerate or 44100,
        channels = channels,
        sample_path = sample.path,
        frequency_data = {},  -- Empty frequency data (will show gray)
        frequency_channel_data = nil
      }
      -- Fill with placeholder data
      if channels > 1 then
        -- Multi-channel: create channel_data structure
        waveform_data.channel_data = {}
        waveform_data.frequency_channel_data = {}
        for c = 0, channels - 1 do
          waveform_data.channel_data[c] = {}
          waveform_data.frequency_channel_data[c] = {}
          for i = 1, waveform_width do
            waveform_data.channel_data[c][i] = 0.1
            waveform_data.frequency_channel_data[c][i] = nil  -- No frequency data
          end
        end
        -- Also set data for backward compatibility (use first channel)
        waveform_data.data = waveform_data.channel_data[0]
        waveform_data.frequency_data = waveform_data.frequency_channel_data[0]
      else
        -- Mono: just fill data array
        for i = 1, waveform_width do
          waveform_data.data[i] = 0.1
          waveform_data.frequency_data[i] = nil  -- No frequency data
        end
      end
    end
  end
  
  -- Always create a fresh PCM_source for each preview.
  -- If an old one is still around, release it first.
  if preview_source then
    -- Shouldn't happen since stop_preview() clears the source, but be safe.
    log("Warning: preview_source still exists, releasing it")
    release_preview_source()
  end
  
  preview_source = r.PCM_Source_CreateFromFile(sample.path)
  preview_source_engine_owned = false
  if not preview_source then
    log("Failed to create preview source for: " .. tostring(sample.path))
    return
  end

  log("Attempting to preview: " .. sample.path .. (start_time > 0 and (" at " .. string.format("%.2f", start_time) .. "s") or ""))
  log("  API check - CF_CreatePreview: " .. tostring(r.CF_CreatePreview ~= nil))
  log("  API check - CF_Preview_SetValue: " .. tostring(r.CF_Preview_SetValue ~= nil))
  log("  API check - CF_Preview_Play: " .. tostring(r.CF_Preview_Play ~= nil))
  log("  API check - PlayTrackPreview2: " .. tostring(r.PlayTrackPreview2 ~= nil))
  log("  API check - Xen_StartSourcePreview: " .. tostring(r.Xen_StartSourcePreview ~= nil))

  -- Try CF_Preview API first (supports seeking via CF_Preview_SetValue with "D_POSITION")
  if r.CF_CreatePreview and r.CF_Preview_SetValue and r.CF_Preview_Play then
    log("Using CF_Preview API for seeking support")
    -- Create CF_Preview object (correct function name is CF_CreatePreview)
    cf_preview_obj = r.CF_CreatePreview(preview_source)
    if cf_preview_obj then
      r.CF_Preview_SetValue(cf_preview_obj, "D_VOLUME", state.preview_volume or 1.0)
      -- Set start position if needed using CF_Preview_SetValue with "D_POSITION"
      -- D_POSITION is in seconds (as per example script)
      if start_time > 0 then
        local set_ok = r.CF_Preview_SetValue(cf_preview_obj, "D_POSITION", start_time)
        if set_ok then
          log("Set CF_Preview start position to " .. string.format("%.2f", start_time) .. "s")
        else
          log("Warning: Could not set CF_Preview D_POSITION")
        end
      end
      -- Start playback
      local ret = r.CF_Preview_Play(cf_preview_obj)
      if ret then
        preview_proc = true  -- Flag that CF_Preview is active (don't store the object here)
        preview_start_time = r.time_precise() - start_time
        state.pop_start_time = r.time_precise()  -- Trigger pop effect
        log("CF_Preview_Play succeeded")
      else
        log("CF_Preview_Play returned false")
        cf_preview_obj = nil
      end
    else
      log("CF_CreatePreview returned nil")
    end
  -- Fallback to PlayTrackPreview2 (supports seeking via startpos in preview table)
  elseif r.PlayTrackPreview2 then
    log("Using PlayTrackPreview2 for seeking support")
    local track = ensure_preview_track()
    if track then
      local preview = {
        src = preview_source,
        startpos = start_time,
        volume = state.preview_volume or 1.0,
        pan = 0.0,
        loop = false,
        length = -1.0,
        fadein = 0.0,
        fadeout = 0.0,
        pitch = 0.0,
        mode = 0,
      }
      local ret = r.PlayTrackPreview2(0, preview, track)
      if ret then
        preview_proc = true
        preview_start_time = r.time_precise() - start_time
        state.pop_start_time = r.time_precise()  -- Trigger pop effect
        log("PlayTrackPreview2 succeeded with startpos=" .. string.format("%.2f", start_time))
      else
        log("PlayTrackPreview2 returned false")
      end
    else
      log("Failed to get preview track for PlayTrackPreview2")
    end
  -- Fallback to Xen_StartSourcePreview (no seeking support, always starts from beginning)
  elseif r.Xen_StartSourcePreview then
    log("Using Xen_StartSourcePreview fallback (no seek support)")
    -- Xen_StartSourcePreview(PCM_source source, number gain, boolean loop, optional integer outputchanindexIn)
    -- Returns integer preview handle ID
    local preview_id = r.Xen_StartSourcePreview(preview_source, state.preview_volume or 1.0, false)
    if preview_id and preview_id ~= 0 then
      preview_proc = preview_id
      preview_source_engine_owned = true
      preview_start_time = r.time_precise()
      state.pop_start_time = r.time_precise()  -- Trigger pop effect
      if start_time > 0 then
        log("Warning: Seek requested but Xen_StartSourcePreview doesn't support seeking; starting from 0")
      end
      log("Xen_StartSourcePreview succeeded, preview_id=" .. tostring(preview_id))
    else
      log("Xen_StartSourcePreview returned invalid ID: " .. tostring(preview_id))
    end
  else
    log("No preview APIs available; cannot play sample")
  end

  if not preview_proc and not cf_preview_obj then
    release_preview_source()
  end

  log("Preview start: " .. sample.name .. (start_time > 0 and (" at " .. string.format("%.2f", start_time) .. "s") or ""))
end


local function get_preview_position()
  if preview_proc and preview_sample_obj then
    local pos = nil

    if cf_preview_obj and r.CF_Preview_GetValue then
      local ret, cf_pos = r.CF_Preview_GetValue(cf_preview_obj, "D_POSITION")
      if ret and cf_pos then
        pos = cf_pos
      end
    end

    if not pos then
      local elapsed = r.time_precise() - preview_start_time
      local duration = preview_sample_obj.duration or 0.0
      pos = math.min(elapsed, duration)
      if elapsed >= duration then
        stop_preview()
        state.preview_paused = false
        state.preview_position = duration
        return duration
      end
    end

    state.preview_position = pos
    return pos
  end

  if preview_sample_obj then
    return state.preview_position or 0.0
  end

  return nil
end

local function apply_preview_volume(vol)
  vol = math.max(0.0, math.min(1.0, vol))
  state.preview_volume = vol
  save_config()

  if cf_preview_obj and r.CF_Preview_SetValue then
    r.CF_Preview_SetValue(cf_preview_obj, "D_VOLUME", vol)
    return
  end

  if preview_proc and preview_sample_obj then
    local resume_pos = state.preview_position or 0.0
    local sample = preview_sample_obj
    stop_preview()
    preview_sample(sample, resume_pos)
  end
end

local function draw_preview_volume_knob(knob_size)
  local vol = state.preview_volume or 1.0
  local radius = knob_size * 0.5

  r.ImGui_InvisibleButton(ctx, "##preview_vol_knob", knob_size, knob_size)
  local active = r.ImGui_IsItemActive(ctx)
  local hovered = r.ImGui_IsItemHovered(ctx)

  if active then
    local _, dy = r.ImGui_GetMouseDelta(ctx)
    if dy ~= 0.0 then
      local step = 1.0 / 200.0
      vol = vol + (-dy) * step
      apply_preview_volume(vol)
      vol = state.preview_volume or vol
    end
  end

  if r.ImGui_IsItemClicked(ctx, 0) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    apply_preview_volume(1.0)
    vol = state.preview_volume or 1.0
  end

  if hovered or active then
    r.ImGui_SetTooltip(ctx, string.format("Volume: %.0f%% (double-click reset)", vol * 100))
  end

  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetItemRectMin(ctx)
  local cx = x0 + radius
  local cy = y0 + radius
  local ANGLE_MIN = math.pi * 0.75
  local ANGLE_MAX = math.pi * 2.25
  local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * vol
  local accent = active and 0x8EC0FFFF or (hovered and 0x7EB8F0FF or 0x5A9AE6FF)

  r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, radius - 1.0, 0x243448FF, 20)
  r.ImGui_DrawList_AddCircle(dl, cx, cy, radius - 1.0, accent, 20, 1.4)
  local lx = cx + math.cos(angle) * (radius - 4.0)
  local ly = cy + math.sin(angle) * (radius - 4.0)
  r.ImGui_DrawList_AddLine(dl, cx, cy, lx, ly, 0xFFFFFFFF, 2.0)
end


-- Helper function to change color alpha (set alpha value 0.0-1.0)
local function change_color_alpha(color, alpha_value)
  if not color then return color end
  local r, g, b = extract_rgb_rrgbbaa(color)
  local new_alpha = math.max(0, math.min(255, math.floor(alpha_value * 255)))
  return build_color_rrgbbaa(r, g, b, new_alpha)
end

-- Helper function to blend two colors
local function blend_colors(color1, color2, t)
  t = math.max(0.0, math.min(1.0, t))
  local r1, g1, b1 = extract_rgb_rrgbbaa(color1)
  local r2, g2, b2 = extract_rgb_rrgbbaa(color2)
  local r = math.floor(r1 * (1.0 - t) + r2 * t)
  local g = math.floor(g1 * (1.0 - t) + g2 * t)
  local b = math.floor(b1 * (1.0 - t) + b2 * t)
  local a1 = color1 % 256
  local a2 = color2 % 256
  local a = math.floor(a1 * (1.0 - t) + a2 * t)
  return build_color_rrgbbaa(r, g, b, a)
end

-- Helper function to brighten a color while preserving hue
-- brightness_factor: 0.0 = no change, 1.0 = maximum brightness (toward white but preserving hue)
local function brighten_color_preserve_hue(color, brightness_factor)
  brightness_factor = math.max(0.0, math.min(1.0, brightness_factor))
  local r, g, b = extract_rgb_rrgbbaa(color)
  
  -- Find the maximum component to determine the current brightness
  local max_component = math.max(r, g, b)
  if max_component == 0 then
    -- Black color - return a gray based on brightness
    local gray = math.floor(brightness_factor * 255)
    return build_color_rrgbbaa(gray, gray, gray, 255)
  end
  
  -- Calculate how much to scale each component toward 255 while preserving ratios
  -- This preserves hue while increasing brightness
  local scale_factor = 1.0 + brightness_factor * (255.0 / max_component - 1.0)
  
  local new_r = math.min(255, math.floor(r * scale_factor))
  local new_g = math.min(255, math.floor(g * scale_factor))
  local new_b = math.min(255, math.floor(b * scale_factor))
  
  return build_color_rrgbbaa(new_r, new_g, new_b, 255)
end

-- Draw glowing circle effect (adapted from provided pattern)
local function draw_glowing_circle(dl, x, y, glow_in, glow_out, solid_rad, clr, center_clr)
  -- Draw solid center circle if specified
  if solid_rad then
    local center_color = center_clr or clr
    r.ImGui_DrawList_AddCircleFilled(dl, x, y, solid_rad, center_color, 32)
  end
  
  -- Draw concentric circles for glow effect
  -- Use step size based on radius to balance quality and performance
  local step = math.max(0.5, (glow_out - glow_in) / 50.0)  -- Draw ~50 circles for smooth glow
  for i = glow_in, glow_out, step do
    local range = glow_out - glow_in
    if range > 0 then
      -- Calculate normalized position (1.0 at glow_in, 0.0 at glow_out)
      local n = (glow_out - i) / range
      
      -- Opacity decreases as we go outward
      local opacity = n
      
      -- Blend colors if center color is provided
      local circle_color = clr
      if center_clr then
        circle_color = blend_colors(clr, center_clr, n)
      end
      
      -- Apply opacity
      local final_color = change_color_alpha(circle_color, opacity)
      
      -- Draw circle outline (not filled for glow effect)
      r.ImGui_DrawList_AddCircle(dl, x, y, i, final_color, 32, 1.0)
    end
  end
end

-- --- UI helpers --------------------------------------------------------------
local function sample_passes_filters(sample)
  if not sample then return false end

  if state.filter ~= "" then
    local name = string.lower(sample.name or "")
    if not string.find(name, string.lower(state.filter), 1, true) then
      return false
    end
  end

  if state.active_tags and next(state.active_tags) ~= nil then
    local matched = false
    if sample.tags then
      for _, tag in ipairs(sample.tags) do
        if state.active_tags[tag] then
          matched = true
          break
        end
      end
    end
    if not matched then
      return false
    end
  end

  -- Check folder path filter
  if state.folder_filter_path and state.folder_filter_path ~= "" then
    local sample_path = normalize_path(sample.path or "")
    local filter_path = normalize_path(state.folder_filter_path)
    -- Check if sample path starts with filter path
    if not (sample_path:sub(1, #filter_path) == filter_path) then
      return false
    end
  end

  return true
end


-- Custom function to draw a nicer-looking tag button
local function draw_tag_button(ctx, label, active, tag, id_prefix)
  id_prefix = id_prefix or ""  -- Optional ID prefix to make buttons unique
  -- Get text size and frame padding for button sizing
  local text_size = {r.ImGui_CalcTextSize(ctx, label)}
  local frame_padding = {r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())}

  local button_width = text_size[1] + frame_padding[1] * 2
  local button_height = text_size[2] + frame_padding[2] * 2

  -- Get the tag's assigned color
  local tag_color = state.tag_colors[tag] or 0x336699 -- Default blue if not found

  -- Extract RGB components for color variations
  local base_r, base_g, base_b = extract_rgb(tag_color)

  -- Define colors based on active state using the tag's color
  local bg_color, border_color, text_color
  if active then
    -- Active: dim the tag color slightly for better text legibility
    local dim_factor = 0.75  -- Reduce brightness to 75% for active state
    bg_color = build_color_rrgbbaa(
      math.floor(base_r * dim_factor),
      math.floor(base_g * dim_factor),
      math.floor(base_b * dim_factor),
      255
    )
    -- Darken further for border
    border_color = build_color_rrgbbaa(
      math.max(0, math.floor(base_r * dim_factor * 0.7)),
      math.max(0, math.floor(base_g * dim_factor * 0.7)),
      math.max(0, math.floor(base_b * dim_factor * 0.7)),
      255
    )
    text_color = 0xFFFFFFFF   -- Active text: white
  else
    -- Inactive: brighter version of the tag color for better visibility
    local inactive_factor = 0.45  -- 45% brightness instead of 20%
    bg_color = build_color_rrgbbaa(
      math.floor(base_r * inactive_factor),
      math.floor(base_g * inactive_factor),
      math.floor(base_b * inactive_factor),
      255
    )
    border_color = build_color_rrgbbaa(
      math.floor(base_r * inactive_factor * 1.2),  -- Slightly brighter border
      math.floor(base_g * inactive_factor * 1.2),
      math.floor(base_b * inactive_factor * 1.2),
      255
    )
    text_color = 0xFFCCCCCC   -- Inactive text: light gray
  end

  -- Create an invisible button to handle input and layout
  local clicked = r.ImGui_InvisibleButton(ctx, "##" .. id_prefix .. "tag_" .. label, button_width, button_height)

  -- Get the button rect from ImGui
  local rect_min = {r.ImGui_GetItemRectMin(ctx)}
  local rect_max = {r.ImGui_GetItemRectMax(ctx)}

  -- Check if button is hovered
  local is_hovered = r.ImGui_IsItemHovered(ctx)
  
  -- Track hovered tag in state
  if is_hovered then
    state.hovered_tag = tag
  end

  -- Adjust colors for hover state
  if is_hovered and not active then
    -- Lighter version for inactive hover (between inactive and active brightness)
    local hover_factor = 0.6  -- 60% brightness for inactive hover
    bg_color = build_color_rrgbbaa(
      math.floor(base_r * hover_factor),
      math.floor(base_g * hover_factor),
      math.floor(base_b * hover_factor),
      255
    )
    border_color = build_color_rrgbbaa(
      math.floor(base_r * hover_factor * 1.3),  -- Slightly brighter border
      math.floor(base_g * hover_factor * 1.3),
      math.floor(base_b * hover_factor * 1.3),
      255
    )
    text_color = 0xFFE0E0E0    -- Hover text: brighter
  elseif is_hovered and active then
    -- Brighten the dimmed active color slightly for hover
    local hover_active_factor = 0.85  -- 85% brightness for active hover
    bg_color = build_color_rrgbbaa(
      math.floor(base_r * hover_active_factor),
      math.floor(base_g * hover_active_factor),
      math.floor(base_b * hover_active_factor),
      255
    )
    border_color = build_color_rrgbbaa(
      math.floor(base_r * hover_active_factor * 0.8),  -- Darker border for contrast
      math.floor(base_g * hover_active_factor * 0.8),
      math.floor(base_b * hover_active_factor * 0.8),
      255
    )
  end

  -- Get draw list and draw the custom button
  local draw_list = r.ImGui_GetWindowDrawList(ctx)

  -- Draw button background
  r.ImGui_DrawList_AddRectFilled(draw_list, rect_min[1], rect_min[2], rect_max[1], rect_max[2],
                                 bg_color, 4.0) -- 4.0 for rounded corners

  -- Draw border
  r.ImGui_DrawList_AddRect(draw_list, rect_min[1], rect_min[2], rect_max[1], rect_max[2],
                           border_color, 4.0, 0, 1.0)

  -- Draw text centered in the button
  local text_pos_x = rect_min[1] + frame_padding[1]
  local text_pos_y = rect_min[2] + frame_padding[2]

  -- Make active tags appear bold by drawing text with slight offset
  if active then
    -- Draw text multiple times with small offsets to create bold effect
    r.ImGui_DrawList_AddText(draw_list, text_pos_x, text_pos_y, text_color, label)
    r.ImGui_DrawList_AddText(draw_list, text_pos_x + 0.5, text_pos_y, text_color, label)
    r.ImGui_DrawList_AddText(draw_list, text_pos_x, text_pos_y + 0.5, text_color, label)
    r.ImGui_DrawList_AddText(draw_list, text_pos_x + 0.5, text_pos_y + 0.5, text_color, label)
  else
    r.ImGui_DrawList_AddText(draw_list, text_pos_x, text_pos_y, text_color, label)
  end

  return clicked
end

function ui_button_colors(style, hovered, active, selected)
  if style == "danger" then
    if active then return 0x401818FF, 0xAA4444FF, 0xFFFFFFFF, 0x00000000, 1.0 end
    if hovered then return 0x773333FF, 0xDD6666FF, 0xFFFFFFFF, 0xCC444422, 1.5 end
    return 0x5A2828FF, 0xCC5555FF, 0xFFCCCCFF, 0x00000000, 1.0
  elseif style == "ghost_arrow" then
    if active then return 0x00000000, 0x00000000, 0xBFE6FFFF, 0x9ED8FF33, 0.0 end
    if hovered then return 0x00000000, 0x00000000, 0xFFFFFFFF, 0x9ED8FF22, 0.0 end
    return 0x00000000, 0x00000000, 0x9FB7CCFF, 0x00000000, 0.0
  elseif style == "success" then
    if active then return 0x1A4028FF, 0x44AA66FF, 0xFFFFFFFF, 0x00000000, 1.0 end
    if hovered then return 0x337048FF, 0x66CC88FF, 0xFFFFFFFF, 0x44AA6622, 1.5 end
    return 0x285838FF, 0x55BB77FF, 0xD8F0E0FF, 0x00000000, 1.0
  elseif style == "primary" or selected then
    if active then return 0x1E4060FF, 0x5A9AE6FF, 0xFFFFFFFF, 0x00000000, 1.6 end
    if hovered then return 0x356599FF, 0x8EC0FFFF, 0xFFFFFFFF, 0x5A9AE644, 1.6 end
    return 0x2A5080FF, 0x5A9AE6FF, 0xE8F2FFFF, 0x00000000, 1.2
  elseif style == "accent" then
    if active then return 0x306999FF, 0x8EC0FFFF, 0xFFFFFFFF, 0x00000000, 1.6 end
    if hovered then return 0x4A8FD0FF, 0xA8D4FFFF, 0xFFFFFFFF, 0x5A9AE644, 1.6 end
    return 0x3E7CB1FF, 0x7EB8F0FF, 0xF0F8FFFF, 0x00000000, 1.4
  end
  if active then return 0x1A2838FF, 0x6080A0FF, 0xFFFFFFFF, 0x00000000, 1.0 end
  if hovered then return 0x314A66FF, 0x7EB8F0FF, 0xFFFFFFFF, 0x5A9AE633, 1.6 end
  return 0x243448FF, 0x4A6888FF, 0xC8D8EAFF, 0x00000000, 1.0
end

function ui_button_draw_icon(dl, icon, cx, cy, size, color)
  local arm = size * 0.34
  if icon == "plus" then
    r.ImGui_DrawList_AddLine(dl, cx - arm, cy, cx + arm, cy, color, 2.2)
    r.ImGui_DrawList_AddLine(dl, cx, cy - arm, cx, cy + arm, color, 2.2)
  elseif icon == "close" then
    r.ImGui_DrawList_AddLine(dl, cx - arm, cy - arm, cx + arm, cy + arm, color, 2.0)
    r.ImGui_DrawList_AddLine(dl, cx + arm, cy - arm, cx - arm, cy + arm, color, 2.0)
  elseif icon == "check" then
    r.ImGui_DrawList_AddLine(dl, cx - arm * 0.85, cy, cx - arm * 0.15, cy + arm * 0.75, color, 2.2)
    r.ImGui_DrawList_AddLine(dl, cx - arm * 0.15, cy + arm * 0.75, cx + arm * 0.95, cy - arm * 0.65, color, 2.2)
  elseif icon == "chev_left" then
    r.ImGui_DrawList_AddTriangleFilled(dl, cx - arm * 0.35, cy, cx + arm * 0.55, cy - arm * 0.75, cx + arm * 0.55, cy + arm * 0.75, color)
  elseif icon == "chev_right" then
    r.ImGui_DrawList_AddTriangleFilled(dl, cx + arm * 0.35, cy, cx - arm * 0.55, cy - arm * 0.75, cx - arm * 0.55, cy + arm * 0.75, color)
  elseif icon == "play" then
    -- Bootstrap play-fill style
    local h = size * 0.34
    r.ImGui_DrawList_AddTriangleFilled(dl, cx - h * 0.42, cy - h, cx - h * 0.42, cy + h, cx + h * 0.88, cy, color)
  elseif icon == "pause" then
    local h = size * 0.30
    local bar_w = size * 0.11
    local gap = size * 0.07
    r.ImGui_DrawList_AddRectFilled(dl, cx - gap - bar_w, cy - h, cx - gap, cy + h, color, 1.5)
    r.ImGui_DrawList_AddRectFilled(dl, cx + gap, cy - h, cx + gap + bar_w, cy + h, color, 1.5)
  elseif icon == "stop" then
    -- Bootstrap stop-fill style
    local s = size * 0.28
    r.ImGui_DrawList_AddRectFilled(dl, cx - s, cy - s, cx + s, cy + s, color, 2.0)
  elseif icon == "list" then
    local lw = size * 0.30
    local dot = math.max(1.0, size * 0.05)
    for i = -1, 1 do
      local ly = cy + i * (size * 0.22)
      r.ImGui_DrawList_AddCircleFilled(dl, cx - lw - dot * 1.5, ly, dot, color, 8)
      r.ImGui_DrawList_AddLine(dl, cx - lw, ly, cx + lw, ly, color, 1.8)
    end
  elseif type(icon) == "string" and icon:match("^dice[1-6]$") then
    local count = tonumber(icon:match("(%d)$")) or 1
    local half = size * 0.28
    local x0, y0 = cx - half, cy - half
    local x1, y1 = cx + half, cy + half
    r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, color, 3.0, 0, 1.5)

    local p = half * 0.48
    local pip_r = math.max(1.2, size * 0.045)
    local function pip(dx, dy)
      r.ImGui_DrawList_AddCircleFilled(dl, cx + dx, cy + dy, pip_r, color, 10)
    end

    if count == 1 or count == 3 or count == 5 then
      pip(0, 0)
    end
    if count >= 2 then
      pip(-p, -p)
      pip(p, p)
    end
    if count >= 4 then
      pip(p, -p)
      pip(-p, p)
    end
    if count == 6 then
      pip(-p, 0)
      pip(p, 0)
    end
  end
end

function draw_ui_button(id, label, w, h, opts)
  opts = opts or {}
  local style = opts.style or "default"
  local icon = opts.icon
  local display = (not icon and label) and label or ""
  local frame_padding = { r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()) }
  local frame_pad_x = frame_padding[1]
  local frame_pad_y = frame_padding[2]
  if opts.compact then
    frame_pad_x = frame_pad_x * 0.65
    frame_pad_y = frame_pad_y * 0.65
  end

  local text_size = { r.ImGui_CalcTextSize(ctx, (display ~= "" and display) or "Ay") }
  if not w or w == 0 then
    if opts.full_width then
      w = r.ImGui_GetContentRegionAvail(ctx)
    elseif display ~= "" then
      w = text_size[1] + frame_pad_x * 2
    else
      w = h or 28
    end
  end
  if not h or h == 0 then
    if display ~= "" then
      h = text_size[2] + frame_pad_y * 2
    else
      h = 28
    end
  end

  r.ImGui_InvisibleButton(ctx, "##ui_" .. tostring(id), w, h)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local active = r.ImGui_IsItemActive(ctx)
  local clicked = r.ImGui_IsItemClicked(ctx, 0)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetItemRectMin(ctx)
  local x1, y1 = r.ImGui_GetItemRectMax(ctx)
  local cx = (x0 + x1) * 0.5
  local cy = (y0 + y1) * 0.5
  local rounding = opts.compact and 4.0 or 6.0
  local bg, border, text_col, glow, border_w = ui_button_colors(style, hovered, active, opts.selected)
  local is_ghost_arrow = style == "ghost_arrow"

  if glow ~= 0 and hovered then
    if is_ghost_arrow then
      r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, active and math.min(w, h) * 0.38 or math.min(w, h) * 0.32, glow, 20)
    else
      r.ImGui_DrawList_AddRectFilled(dl, x0 - 1, y0 - 1, x1 + 1, y1 + 1, glow, rounding + 1)
    end
  end
  if not is_ghost_arrow then
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, bg, rounding)
    r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, border, rounding, 0, border_w)
  end

  if icon then
    local icon_size = math.min(w, h)
    local icon_y = cy
    local icon_color = hovered and 0xFFFFFFFF or text_col
    if is_ghost_arrow then
      if active then
        icon_size = icon_size * 1.18
        icon_y = cy + 1.0
        icon_color = 0xBFE6FFFF
      elseif hovered then
        icon_size = icon_size * 1.14
        icon_color = 0xFFFFFFFF
      end
    end
    ui_button_draw_icon(dl, icon, cx, icon_y, icon_size, icon_color)
    if icon == "plus" and hovered then
      r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2.0, 0xFFFFFFFF, 12)
    end
  elseif display ~= "" then
    r.ImGui_DrawList_AddText(dl, x0 + (w - text_size[1]) * 0.5, y0 + (h - text_size[2]) * 0.5, text_col, display)
  end

  return clicked
end

-- Function to save tag colors to current preset
local function save_tag_color_to_preset(tag, color)
  -- Load current presets
  local tag_presets = {}
  local function load_tag_presets()
    local preset_file = io.open(CONFIG_DIR .. "/tag_presets.lua", "r")
    if preset_file then
      local content = preset_file:read("*all")
      preset_file:close()
      local success, presets = pcall(load, content)
      if success and type(presets) == "function" then
        tag_presets = presets() or {}
      end
    end
  end
  load_tag_presets()
  
  -- Ensure current preset exists
  if not tag_presets[state.current_preset_name] then
    tag_presets[state.current_preset_name] = {}
  end
  
  -- Update the tag color in the preset
  tag_presets[state.current_preset_name][tag] = color
  
  -- Save presets back to file
  local preset_content = "return " .. serialize_table(tag_presets)
  local preset_file = io.open(CONFIG_DIR .. "/tag_presets.lua", "w")
  if preset_file then
    preset_file:write(preset_content)
    preset_file:close()
  end
end

-- Helper function to categorize tags
local function categorize_tags(tag)
  -- Normalize tag to lowercase for comparison (but preserve original for display)
  local tag_lower = string.lower(tag)
  
  -- Drum category tags (case-insensitive)
  local drum_tags = {
    kick = true, snare = true, clap = true, snap = true, rim = true, hat = true,
    tom = true, ride = true, crash = true, perc = true, fx = true,
    bass = true, ["808"] = true, drum = true
  }
  
  -- Melodic category tags (case-insensitive)
  local melodic_tags = {
    vocal = true, pluck = true, lead = true, pad = true,
    keys = true, guitar = true, swell = true  -- Swell is melodic
  }
  
  -- Loop/oneshot category tags (case-insensitive, handle both "One shot" and "oneshot")
  local loop_tags = {
    loop = true, ["one shot"] = true, oneshot = true
  }
  
  if drum_tags[tag_lower] then
    return "drum"
  elseif melodic_tags[tag_lower] then
    return "melodic"
  elseif loop_tags[tag_lower] then
    return "loop"
  end
  
  return nil
end

-- Helper function to draw a larger category tag
local function draw_category_tag(ctx, label, id_prefix)
  id_prefix = id_prefix or ""
  -- Get text size with larger font (we'll use a scale factor)
  local text_size = {r.ImGui_CalcTextSize(ctx, label)}
  local frame_padding = {r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())}
  
  -- Scale up the category tag (1.2x larger)
  local scale = 1.2
  local button_width = text_size[1] * scale + frame_padding[1] * 2
  local button_height = text_size[2] * scale + frame_padding[2] * 2
  
  -- Create invisible button for layout
  local clicked = r.ImGui_InvisibleButton(ctx, "##" .. id_prefix .. "cat_" .. label, button_width, button_height)
  
  -- Get button rect
  local rect_min = {r.ImGui_GetItemRectMin(ctx)}
  local rect_max = {r.ImGui_GetItemRectMax(ctx)}
  
  -- Category tags use a distinct style (darker, more prominent)
  local bg_color = 0xFF4A4A4A  -- Dark gray background
  local border_color = 0xFF666666  -- Lighter gray border
  local text_color = 0xFFFFFFFF   -- White text
  
  -- Check hover state
  local is_hovered = r.ImGui_IsItemHovered(ctx)
  if is_hovered then
    bg_color = 0xFF5A5A5A  -- Slightly lighter on hover
    border_color = 0xFF777777
  end
  
  -- Get draw list and draw the category tag
  local draw_list = r.ImGui_GetWindowDrawList(ctx)
  
  -- Draw button background
  r.ImGui_DrawList_AddRectFilled(draw_list, rect_min[1], rect_min[2], rect_max[1], rect_max[2],
                                 bg_color, 4.0)
  
  -- Draw border
  r.ImGui_DrawList_AddRect(draw_list, rect_min[1], rect_min[2], rect_max[1], rect_max[2],
                           border_color, 4.0, 0, 1.5)  -- Thicker border for category tags
  
  -- Draw text centered (scaled up)
  local text_pos_x = rect_min[1] + (button_width - text_size[1] * scale) * 0.5
  local text_pos_y = rect_min[2] + (button_height - text_size[2] * scale) * 0.5
  
  -- Draw text normally (no bold effect)
  r.ImGui_DrawList_AddText(draw_list, text_pos_x, text_pos_y, text_color, label)
  
  return clicked
end

local function render_tag_filters()
  if not state.tag_list or #state.tag_list == 0 then
    return
  end

  -- Reset hovered tag at start of frame
  state.hovered_tag = nil

  -- Categorize tags
  local drum_tags = {}
  local melodic_tags = {}
  local loop_tags = {}
  
  for _, entry in ipairs(state.tag_list) do
    local tag = entry.tag
    local category = categorize_tags(tag)
    if category == "drum" then
      table.insert(drum_tags, entry)
    elseif category == "melodic" then
      table.insert(melodic_tags, entry)
    elseif category == "loop" then
      table.insert(loop_tags, entry)
    end
  end

  -- Render Drum category (first line)
  if #drum_tags > 0 then
    -- Draw "Drum" category tag (larger)
    if draw_category_tag(ctx, "Drum", "cat_") then
      -- Toggle all drum tags when category tag is clicked
      local all_active = true
      for _, entry in ipairs(drum_tags) do
        if not state.active_tags[entry.tag] then
          all_active = false
          break
        end
      end
      -- Toggle all drum tags
      for _, entry in ipairs(drum_tags) do
        if all_active then
          state.active_tags[entry.tag] = nil
        else
          state.active_tags[entry.tag] = true
        end
      end
    end
    
    -- Draw colon
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, ":")
    r.ImGui_SameLine(ctx)
    
    -- Draw drum tags
    for idx, entry in ipairs(drum_tags) do
      if idx > 1 then
        r.ImGui_SameLine(ctx)
      end
      local tag = entry.tag
      local active = state.active_tags[tag]
      local label = tag
      
      if draw_tag_button(ctx, label, active, tag) then
        if active then
          state.active_tags[tag] = nil
        else
          state.active_tags[tag] = true
        end
      end
    end
  end

  -- Render Melodic category (second line)
  if #melodic_tags > 0 then
    -- Start new line (don't call SameLine before first item)
    
    -- Draw "Melodic" category tag (larger)
    if draw_category_tag(ctx, "Melodic", "cat_") then
      -- Toggle all melodic tags when category tag is clicked
      local all_active = true
      for _, entry in ipairs(melodic_tags) do
        if not state.active_tags[entry.tag] then
          all_active = false
          break
        end
      end
      -- Toggle all melodic tags
      for _, entry in ipairs(melodic_tags) do
        if all_active then
          state.active_tags[entry.tag] = nil
        else
          state.active_tags[entry.tag] = true
        end
      end
    end
    
    -- Draw colon
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, ":")
    r.ImGui_SameLine(ctx)
    
    -- Draw melodic tags
    for idx, entry in ipairs(melodic_tags) do
      if idx > 1 then
        r.ImGui_SameLine(ctx)
      end
      local tag = entry.tag
      local active = state.active_tags[tag]
      local label = tag
      
      if draw_tag_button(ctx, label, active, tag) then
        if active then
          state.active_tags[tag] = nil
        else
          state.active_tags[tag] = true
        end
      end
    end
  end

  -- Render Loop/Oneshot category (third line)
  if #loop_tags > 0 then
    -- Start new line (don't call SameLine before first item)
    
    -- Draw loop/oneshot tags (no category header, just the tags)
    for idx, entry in ipairs(loop_tags) do
      if idx > 1 then
        r.ImGui_SameLine(ctx)
      end
      local tag = entry.tag
      local active = state.active_tags[tag]
      local label = tag
      
      if draw_tag_button(ctx, label, active, tag) then
        if active then
          state.active_tags[tag] = nil
        else
          state.active_tags[tag] = true
        end
      end
    end
  end

  -- Check for C key press when hovering over a tag
  if state.hovered_tag and r.ImGui_IsKeyPressed and r.ImGui_Key_C then
    local c_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_C(), false)
    if c_pressed then
      state.tag_color_picker_tag = state.hovered_tag
      r.ImGui_OpenPopup(ctx, "tag_color_picker")
    end
  end

  -- Color picker popup
  if r.ImGui_BeginPopup(ctx, "tag_color_picker") then
    if state.tag_color_picker_tag then
      r.ImGui_Text(ctx, "Edit color for: " .. state.tag_color_picker_tag)
      local tag_color = state.tag_colors[state.tag_color_picker_tag] or 0x336699
      local color_changed, new_color = r.ImGui_ColorEdit3(ctx, "Color", tag_color | 0xFF000000, 0)
      if color_changed then
        local rgb_color = new_color & 0xFFFFFF  -- Extract RGB part only
        state.tag_colors[state.tag_color_picker_tag] = rgb_color
        save_tag_color_to_preset(state.tag_color_picker_tag, rgb_color)
        save_config()  -- Also save to main config
      end
      
      r.ImGui_Spacing(ctx)
      if draw_ui_button("tag_picker_done", "Done") then
        r.ImGui_CloseCurrentPopup(ctx)
        state.tag_color_picker_tag = nil
      end
      
      -- Close popup if clicked outside (ImGui handles this automatically, but we can also check for escape)
      if r.ImGui_IsKeyPressed and r.ImGui_Key_Escape then
        local escape_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape(), false)
        if escape_pressed then
          r.ImGui_CloseCurrentPopup(ctx)
          state.tag_color_picker_tag = nil
        end
      end
    else
      -- Tag was cleared, close popup
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_Separator(ctx)
end


local function begin_window()
  r.ImGui_SetNextWindowSize(ctx, 1024, 720, r.ImGui_Cond_FirstUseEver())
  if r.ImGui_SetConfigVar and r.ImGui_ConfigVar_WindowsMoveFromTitleBarOnly then
    r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_WindowsMoveFromTitleBarOnly(), 1)
  end
  -- Disable scrolling and set solid background
  -- Disable keyboard navigation so arrow keys can be used for history navigation
  local flags = r.ImGui_WindowFlags_NoCollapse() | 
                r.ImGui_WindowFlags_NoScrollbar() | 
                r.ImGui_WindowFlags_NoScrollWithMouse() |
                r.ImGui_WindowFlags_NoNav()
  
  -- Set solid black window background color
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(), 0x000000ff)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), 0x000000ff)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x000000ff)
  
  local visible, open = r.ImGui_Begin(ctx, SCRIPT_NAME, true, flags)
  
  return visible, open
end

-- Build peaks for a specific item while preserving user selection
local function rebuild_peaks_for_item(item)
  if not item then return end

  -- Save current selection
  local selected = {}
  local sel_count = r.CountSelectedMediaItems(0)
  for i = 0, sel_count - 1 do
    selected[#selected + 1] = r.GetSelectedMediaItem(0, i)
  end

  -- Select only the target item
  r.SelectAllMediaItems(0, false)
  r.SetMediaItemSelected(item, true)

  -- Rebuild peaks for selected items
  r.Main_OnCommand(40047, 0) -- Peaks: Rebuild peaks for selected items

  -- Restore previous selection
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(selected) do
    if r.ValidatePtr(it, "MediaItem*") then
      r.SetMediaItemSelected(it, true)
    end
  end
end

-- Insert a sample at the current cursor position in the arrange window
local function insert_sample_at_cursor(sample)
  if not sample or not sample.path then
    log("No sample to insert")
    return false
  end

  -- Check if file exists
  if not r.file_exists(sample.path) then
    log("Sample file does not exist: " .. sample.path)
    return false
  end

  -- Prevent UI refresh during operations
  r.PreventUIRefresh(1)

  -- Get cursor position
  local cursor_pos = r.GetCursorPosition()
  log("Cursor position: " .. string.format("%.3f", cursor_pos))

  -- Get selected track (or first track if none selected)
  local num_tracks = r.CountTracks(0)
  log("Total tracks in project: " .. num_tracks)

  local track = r.GetSelectedTrack(0, 0)
  if not track then
    log("No selected track, trying first track...")
    if num_tracks > 0 then
      track = r.GetTrack(0, 0)  -- Get first track (0-indexed)
    end
  end

  if not track then
    log("No track available for inserting sample (project has " .. num_tracks .. " tracks)")
    r.PreventUIRefresh(-1)
    return false
  end

  -- Get track info for debugging
  local _, track_name = r.GetTrackName(track)
  log("Using track: " .. (track_name or "unnamed"))

  -- Create media item
  local item = r.AddMediaItemToTrack(track)
  if not item then
    log("Failed to create media item")
    r.PreventUIRefresh(-1)
    return false
  end

  -- Set item position and length
  r.SetMediaItemPosition(item, cursor_pos, false)
  local duration = sample.duration or 1.0
  r.SetMediaItemLength(item, duration, false)
  log("Set item position to " .. string.format("%.3f", cursor_pos) .. " and length to " .. string.format("%.3f", duration))

  -- Create take and set source
  local take = r.AddTakeToMediaItem(item)
  if take then
    local src = r.PCM_Source_CreateFromFile(sample.path)
    if src then
      local retval = r.SetMediaItemTake_Source(take, src)
      log("SetMediaItemTake_Source result: " .. tostring(retval))

      -- Verify the source was set
      local take_src = r.GetMediaItemTake_Source(take)
      if take_src then
        log("Take source successfully set")
      else
        log("WARNING: Take source not set properly")
      end

      -- Name the item after the filename (with debug)
      set_item_name(item, take, sample.path)

      log("Inserted sample '" .. sample.name .. "' at position " .. string.format("%.3f", cursor_pos))

      -- Build peaks for the newly created item
      rebuild_peaks_for_item(item)

      -- Update arrange view and allow UI refresh
      r.UpdateArrange()
      r.PreventUIRefresh(-1)

      return true
    else
      log("Failed to create PCM source for: " .. sample.path)
      r.PreventUIRefresh(-1)
      return false
    end
  else
    log("Failed to create take for media item")
    r.PreventUIRefresh(-1)
    return false
  end
end

-- Get the drop position from mouse cursor context (using SWS extension)
local function get_drop_position()
  if not r.BR_GetMouseCursorContext then
    log("SWS functions not available; cannot get mouse position")
    return nil, nil
  end

  -- Refresh mouse context; returns window/segment/details strings
  local window, segment, details = r.BR_GetMouseCursorContext()

  -- Only proceed when mouse is over arrange view (window == "arrange")
  if window == "arrange" then
    local time_pos = r.BR_GetMouseCursorContext_Position()
    local track = r.BR_GetMouseCursorContext_Track()
    if time_pos then
      return time_pos, track
    end
  end

  -- No position available (mouse not over arrange)
  return nil, nil
end

-- Insert sample at specific position and track
local function insert_sample_at_position(sample, time_pos, target_track)
  if not sample or not sample.path then
    log("No sample to insert")
    return false
  end

  -- Check if file exists
  if not r.file_exists(sample.path) then
    log("Sample file does not exist: " .. sample.path)
    return false
  end

  -- Prevent UI refresh during operations
  r.PreventUIRefresh(1)

  -- Use target track if provided, otherwise fallback to selected/first track
  local track = target_track
  if not track then
    track = r.GetSelectedTrack(0, 0)
    if not track then
      local num_tracks = r.CountTracks(0)
      if num_tracks > 0 then
        track = r.GetTrack(0, 0)
      end
    end
  end

  if not track then
    log("No track available for inserting sample")
    r.PreventUIRefresh(-1)
    return false
  end

  -- Get track info for debugging
  local _, track_name = r.GetTrackName(track)
  log("Using track: " .. (track_name or "unnamed"))

  -- Create media item
  local item = r.AddMediaItemToTrack(track)
  if not item then
    log("Failed to create media item")
    r.PreventUIRefresh(-1)
    return false
  end

  -- Set item position and length
  r.SetMediaItemPosition(item, time_pos, false)
  local duration = sample.duration or 1.0
  r.SetMediaItemLength(item, duration, false)
  log("Set item position to " .. string.format("%.3f", time_pos) .. " and length to " .. string.format("%.3f", duration))

  -- Create take and set source
  local take = r.AddTakeToMediaItem(item)
  if take then
    local src = r.PCM_Source_CreateFromFile(sample.path)
    if src then
      local retval = r.SetMediaItemTake_Source(take, src)
      log("SetMediaItemTake_Source result: " .. tostring(retval))

      -- Verify the source was set
      local take_src = r.GetMediaItemTake_Source(take)
      if take_src then
        log("Take source successfully set")
      else
        log("WARNING: Take source not set properly")
      end

      -- Name the item after the filename (with debug)
      set_item_name(item, take, sample.path)

      log("Inserted sample '" .. sample.name .. "' at position " .. string.format("%.3f", time_pos))

      -- Build peaks for the newly created item
      rebuild_peaks_for_item(item)

      -- Update arrange view and allow UI refresh
      r.UpdateArrange()
      r.PreventUIRefresh(-1)

      return true
    else
      log("Failed to create PCM source for: " .. sample.path)
      r.PreventUIRefresh(-1)
      return false
    end
  else
    log("Failed to create take for media item")
    r.PreventUIRefresh(-1)
    return false
  end
end

-- Wrap a single committed insert in one undo point (prefer the project-scoped API).
-- NOTE: declared as globals (not locals) to avoid exceeding Lua's 200 local-per-chunk limit.
function arrange_undo_begin()
  if r.Undo_BeginBlock2 then
    r.Undo_BeginBlock2(0)
  elseif r.Undo_BeginBlock then
    r.Undo_BeginBlock()
  end
end

function arrange_undo_end(label)
  label = label or "Insert sample"
  if r.Undo_EndBlock2 then
    r.Undo_EndBlock2(0, label, -1)
  elseif r.Undo_EndBlock then
    r.Undo_EndBlock(label, -1)
  end
end

-- Snap to grid only when REAPER snapping is enabled, mirroring native drag behavior.
function maybe_snap_drop_time(t)
  if not t then
    return t
  end
  if r.GetToggleCommandState and r.SnapToGrid and r.GetToggleCommandState(1157) == 1 then
    local snapped = r.SnapToGrid(0, t)
    if snapped and snapped == snapped then
      return snapped
    end
  end
  return t
end

-- Remove the live "provisional" preview item without touching the undo history.
function remove_provisional_drop()
  local p = state.provisional_drop
  state.provisional_drop = nil
  if not p or not p.item then
    return
  end
  if not r.ValidatePtr(p.item, "MediaItem*") then
    return
  end
  local track = p.track
  if not (track and r.ValidatePtr(track, "MediaTrack*")) then
    track = r.GetMediaItemTrack(p.item)
  end
  if not track then
    return
  end
  r.PreventUIRefresh(1)
  r.DeleteTrackMediaItem(track, p.item)
  r.UpdateArrange()
  r.PreventUIRefresh(-1)
end

-- Create/move a real media item under the cursor while dragging over the arrange,
-- so the user gets REAPER's own drop preview. Created outside any undo block; the
-- final commit (or cancel) is what manages the undo history.
function update_provisional_drop(sample)
  if not sample or not sample.path then
    remove_provisional_drop()
    return
  end

  -- In-window drop targets (sequencer track row / timeline) are not arrange inserts.
  if state.seq_drop_target_idx or state.seq_timeline_drop_track_idx then
    remove_provisional_drop()
    return
  end

  local drop_time, drop_track = get_drop_position()
  if not drop_time or not drop_track then
    -- Cursor is not over an arrange track; hide the preview but keep dragging.
    remove_provisional_drop()
    return
  end

  drop_time = maybe_snap_drop_time(drop_time)
  state.last_mouse_time_pos = drop_time
  state.last_mouse_track = drop_track

  local p = state.provisional_drop
  local valid = p and p.item and r.ValidatePtr(p.item, "MediaItem*") and p.sample_path == sample.path
  if not valid then
    remove_provisional_drop()
    if not r.file_exists(sample.path) then
      return
    end
    r.PreventUIRefresh(1)
    local item = r.AddMediaItemToTrack(drop_track)
    if item then
      local take = r.AddTakeToMediaItem(item)
      local src = take and r.PCM_Source_CreateFromFile(sample.path)
      if src then
        r.SetMediaItemTake_Source(take, src)
        set_item_name(item, take, sample.path)
      end
      r.SetMediaItemLength(item, sample.duration or 1.0, false)
      r.SetMediaItemPosition(item, drop_time, false)
      -- Tint the preview so it reads as provisional, not a committed item.
      if r.ColorToNative then
        r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", r.ColorToNative(120, 170, 255) | 0x1000000)
      end
      r.SetMediaItemInfo_Value(item, "B_UISEL", 0)
      -- Peaks build lazily for the visible preview; the committed item rebuilds them.
      state.provisional_drop = { item = item, track = drop_track, time = drop_time, sample_path = sample.path }
    end
    r.UpdateArrange()
    r.PreventUIRefresh(-1)
    return
  end

  -- Reposition the existing preview (cheap: no source/peak rebuild).
  r.PreventUIRefresh(1)
  if drop_track ~= p.track and r.ValidatePtr(drop_track, "MediaTrack*") then
    r.MoveMediaItemToTrack(p.item, drop_track)
    p.track = drop_track
  end
  r.SetMediaItemPosition(p.item, drop_time, false)
  p.time = drop_time
  r.UpdateArrange()
  r.PreventUIRefresh(-1)
end

-- Hide REAPER's floating drag tooltip window if it is currently shown.
function clear_drag_tooltip()
  if state.drag_tooltip_active and r.TrackCtl_SetToolTip then
    r.TrackCtl_SetToolTip("", 0, 0, true)
  end
  state.drag_tooltip_active = false
end

local function is_alt_down()
  if r.JS_Mouse_GetState then
    local cap = r.JS_Mouse_GetState(0)
    if cap & 16 == 16 then
      return true
    end
  end
  if r.ImGui_GetIO then
    local io = r.ImGui_GetIO(ctx)
    if io and io.KeyAlt then
      return io.KeyAlt
    end
  end
  if r.ImGui_IsKeyDown and r.ImGui_Key_LeftAlt and r.ImGui_Key_RightAlt then
    return r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftAlt()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightAlt())
  end
  return false
end

local function is_cmd_down()
  if not r.ImGui_IsKeyDown then
    return false
  end
  if r.ImGui_Key_LeftSuper and r.ImGui_Key_RightSuper then
    return r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftSuper()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightSuper())
  end
  return false
end

local function is_shift_down()
  if not r.ImGui_IsKeyDown then
    return false
  end
  if r.ImGui_Key_LeftShift and r.ImGui_Key_RightShift then
    return r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftShift()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightShift())
  end
  return false
end

function is_ctrl_down()
  if r.JS_Mouse_GetState then
    local cap = r.JS_Mouse_GetState(0)
    if cap & 4 == 4 then
      return true
    end
  end
  if r.ImGui_GetIO then
    local io = r.ImGui_GetIO(ctx)
    if io and io.KeyCtrl then
      return io.KeyCtrl
    end
  end
  if r.ImGui_IsKeyDown and r.ImGui_Key_LeftCtrl and r.ImGui_Key_RightCtrl then
    return r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftCtrl()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightCtrl())
  end
  return false
end

local function update_pending_drop_tracking()
  if not state.pending_waveform_drop then
    return
  end
  local time_pos, track = get_drop_position()
  if time_pos then
    state.last_mouse_time_pos = time_pos
    state.last_mouse_track = track
  end
end

local function render_playback_controls_compact(column_w)
  local is_playing = preview_proc ~= nil and preview_sample_obj ~= nil
  local current_pos = get_preview_position()
  local btn = 20
  local knob = 24

  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 2, 2)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 1, 1)

  if is_playing then
    if draw_ui_button("playback_pause", nil, btn, btn, { icon = "pause", style = "primary", compact = true }) then
      state.preview_position = current_pos or state.preview_position or 0.0
      stop_preview()
      state.preview_paused = true
    end
  else
    if draw_ui_button("playback_play", nil, btn, btn, { icon = "play", style = "primary", compact = true }) then
      if preview_sample_obj then
        local start_time = state.preview_paused and (state.preview_position or 0.0) or 0.0
        preview_sample(preview_sample_obj, start_time)
        state.preview_paused = false
      end
    end
  end

  r.ImGui_SameLine(ctx)
  if draw_ui_button("playback_stop", nil, btn, btn, { icon = "stop", compact = true }) then
    stop_preview()
    state.preview_paused = false
    state.preview_position = 0.0
  end

  local knob_offset = math.max(0, (column_w - knob) * 0.5)
  if knob_offset > 0 then
    r.ImGui_Dummy(ctx, knob_offset, 0)
    r.ImGui_SameLine(ctx, 0, 0)
  end
  draw_preview_volume_knob(knob)

  if preview_sample_obj then
    local duration = preview_sample_obj.duration or 0.0
    local pos = current_pos or state.preview_position or 0.0
    if pos > duration then pos = duration end
    r.ImGui_Text(ctx, string.format("%.1f/%.1fs", pos, duration))
  end

  r.ImGui_PopStyleVar(ctx, 2)
end

local function render_waveform_overlay_tags(x0, y0, layout_x, layout_y)
  if preview_sample_obj and preview_sample_obj.tags and type(preview_sample_obj.tags) == "table" and #preview_sample_obj.tags > 0 then
    r.ImGui_SetCursorScreenPos(ctx, x0 + 4, y0 + 4)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 3, 2)
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 3, 1)
    for idx, tag in ipairs(preview_sample_obj.tags) do
      if idx > 1 then
        r.ImGui_SameLine(ctx)
      end

      local active = state.active_tags[tag] or false
      if draw_tag_button(ctx, tag, active, tag, "waveform_") then
        local alt_pressed = false
        if r.ImGui_IsKeyDown and r.ImGui_Key_LeftAlt and r.ImGui_Key_RightAlt then
          alt_pressed = r.ImGui_IsKeyDown(ctx, r.ImGui_Key_LeftAlt()) or r.ImGui_IsKeyDown(ctx, r.ImGui_Key_RightAlt())
        end

        if alt_pressed then
          log("Deleting tag '" .. tag .. "' from sample: " .. preview_sample_obj.name)
          local new_tags = {}
          for _, t in ipairs(preview_sample_obj.tags) do
            if t ~= tag then
              table.insert(new_tags, t)
            end
          end
          preview_sample_obj.tags = new_tags
          for _, s in ipairs(state.samples) do
            if s.path == preview_sample_obj.path then
              s.tags = new_tags
              break
            end
          end
          rebuild_tag_index()
          save_samples()
          log("Tag deleted. Remaining tags: " .. table.concat(new_tags, ", "))
        elseif active then
          state.active_tags[tag] = nil
        else
          state.active_tags[tag] = true
        end
      end
    end
    r.ImGui_PopStyleVar(ctx, 2)
  end

  r.ImGui_SetCursorPos(ctx, layout_x, layout_y)
end

local function render_waveform()
  -- Always show waveform area if a sample is selected/previewing
  if not preview_sample_obj then
    -- Show placeholder message when no sample is selected
    r.ImGui_Text(ctx, "(No sample selected)")
    r.ImGui_Separator(ctx)
    return
  end
  
  -- If waveform_data doesn't exist, try to generate it
  if not waveform_data or waveform_data.sample_path ~= preview_sample_obj.path then
    log("Waveform data missing, generating...")
    waveform_data = generate_waveform(preview_sample_obj)
    if waveform_data then
      waveform_data.sample_path = preview_sample_obj.path
    else
      -- Create placeholder if generation fails
      log("Creating placeholder waveform")
      local channels = preview_sample_obj.channels or 2
      waveform_data = {
        data = {},
        duration = preview_sample_obj.duration or 1.0,
        sample_rate = preview_sample_obj.samplerate or 44100,
        channels = channels,
        sample_path = preview_sample_obj.path,
        frequency_data = {},  -- Empty frequency data (will show gray)
        frequency_channel_data = nil
      }
      if channels > 1 then
        -- Multi-channel: create channel_data structure
        waveform_data.channel_data = {}
        waveform_data.frequency_channel_data = {}
        for c = 0, channels - 1 do
          waveform_data.channel_data[c] = {}
          waveform_data.frequency_channel_data[c] = {}
          for i = 1, waveform_width do
            waveform_data.channel_data[c][i] = 0.1
            waveform_data.frequency_channel_data[c][i] = nil  -- No frequency data
          end
        end
        -- Also set data for backward compatibility (use first channel)
        waveform_data.data = waveform_data.channel_data[0]
        waveform_data.frequency_data = waveform_data.frequency_channel_data[0]
      else
        -- Mono: just fill data array
        for i = 1, waveform_width do
          waveform_data.data[i] = 0.1
          waveform_data.frequency_data[i] = nil  -- No frequency data
        end
      end
    end
  end
  
  if not waveform_data then
    return
  end
  
  local height = 80
  local width = r.ImGui_GetContentRegionAvail(ctx)
  
  -- Render path as clickable folder buttons
  
  local full_path = preview_sample_obj.path or ""
  if full_path ~= "" then
    -- Find which scanned folder contains this sample
    local normalized_path = normalize_path(full_path)
    local scanned_root = nil
    
    -- Find the longest matching scanned folder (most specific match)
    for _, scanned_folder in ipairs(state.folders) do
      local norm_scanned = normalize_path(scanned_folder)
      -- Check if the sample path starts with this scanned folder
      if normalized_path:sub(1, #norm_scanned) == norm_scanned then
        if not scanned_root or #norm_scanned > #scanned_root then
          scanned_root = norm_scanned
        end
      end
    end
    
    -- Extract directory path (remove filename)
    local dir_path = normalized_path:match("(.+)/[^/]+$") or ""
    
    -- If we found a scanned root, only show path segments from that root onward
    local path_segments = {}
    if scanned_root and dir_path ~= "" then
      -- Always add the scanned root as the first segment
      local root_name = scanned_root:match("([^/]+)/?$") or scanned_root
      table.insert(path_segments, {name = root_name, path = scanned_root})
      
      -- Remove the scanned root from the path to get relative path
      local relative_path = dir_path
      if dir_path:sub(1, #scanned_root) == scanned_root then
        relative_path = dir_path:sub(#scanned_root + 1)
        -- Remove leading slash if present
        if relative_path:sub(1, 1) == "/" then
          relative_path = relative_path:sub(2)
        end
      end
      
      -- Build path segments for subfolders
      if relative_path ~= "" then
        local current_path = scanned_root
        for segment in relative_path:gmatch("([^/]+)") do
          current_path = current_path .. "/" .. segment
          table.insert(path_segments, {name = segment, path = current_path})
        end
      end
    elseif dir_path ~= "" then
      -- Fallback: show full path if no scanned root found (shouldn't happen normally)
      local is_absolute = dir_path:sub(1, 1) == "/"
      local current_path = is_absolute and "/" or ""
      for segment in dir_path:gmatch("([^/]+)") do
        if is_absolute then
          current_path = current_path .. segment
        else
          current_path = current_path .. (current_path == "" and "" or "/") .. segment
        end
        table.insert(path_segments, {name = segment, path = current_path})
        if is_absolute then
          current_path = current_path .. "/"
        end
      end
    end
    
    -- Render each segment as a button with improved styling
    for i, seg in ipairs(path_segments) do
      if i > 1 then
        r.ImGui_SameLine(ctx)
        -- Use a subtle separator (RRGGBBAA format)
        r.ImGui_TextColored(ctx, 0x666666FF, " / ")
        r.ImGui_SameLine(ctx)
      end
      
      -- Highlight if this path is currently filtered
      local is_filtered = state.folder_filter_path and normalize_path(state.folder_filter_path) == normalize_path(seg.path)
      
      -- Enhanced button styling with transparent fill and solid outline
      local button_bg_color, border_color
      if is_filtered then
        -- Active/filtered state: blue with less transparency (25% opacity = 0x40 alpha)
        button_bg_color = 0x2D5A8F40  -- Blue, 25% opacity
        border_color = 0x3D7ABFFF     -- Solid blue border
      else
        -- Default state: gray with 90% transparency (10% opacity = 0x1A alpha)
        button_bg_color = 0x2A2A2A1A  -- Gray, 10% opacity
        border_color = 0x666666FF     -- Solid gray border
      end
      
      -- Calculate button size
      local text_size = {r.ImGui_CalcTextSize(ctx, seg.name)}
      local frame_padding = 4.0
      local button_width = text_size[1] + frame_padding * 2
      local button_height = text_size[2] + 4.0
      
      -- Create invisible button for input handling
      local clicked = r.ImGui_InvisibleButton(ctx, "##path_btn_" .. seg.name, button_width, button_height)
      local is_hovered = r.ImGui_IsItemHovered(ctx)
      
      -- Adjust border color on hover
      if is_hovered then
        if is_filtered then
          border_color = 0x4D8ACFFF  -- Brighter blue border on hover
        else
          border_color = 0x888888FF  -- Brighter gray border on hover
        end
      end
      
      -- Get button rect
      local rect_min = {r.ImGui_GetItemRectMin(ctx)}
      local rect_max = {r.ImGui_GetItemRectMax(ctx)}
      
      -- Draw custom button background and border
      local dl = r.ImGui_GetWindowDrawList(ctx)
      r.ImGui_DrawList_AddRectFilled(dl, rect_min[1], rect_min[2], rect_max[1], rect_max[2], button_bg_color, 3.0)
      r.ImGui_DrawList_AddRect(dl, rect_min[1], rect_min[2], rect_max[1], rect_max[2], border_color, 3.0, 0, 1.5)
      
      -- Draw text centered in button (white color, bold when filtered)
      local text_pos_x = rect_min[1] + frame_padding
      local text_pos_y = rect_min[2] + (button_height - text_size[2]) * 0.5
      if is_filtered then
        -- Draw text multiple times with small offsets to create bold effect
        r.ImGui_DrawList_AddText(dl, text_pos_x, text_pos_y, 0xFFFFFFFF, seg.name)
        r.ImGui_DrawList_AddText(dl, text_pos_x + 0.5, text_pos_y, 0xFFFFFFFF, seg.name)
        r.ImGui_DrawList_AddText(dl, text_pos_x, text_pos_y + 0.5, 0xFFFFFFFF, seg.name)
        r.ImGui_DrawList_AddText(dl, text_pos_x + 0.5, text_pos_y + 0.5, 0xFFFFFFFF, seg.name)
      else
        r.ImGui_DrawList_AddText(dl, text_pos_x, text_pos_y, 0xFFFFFFFF, seg.name)
      end
      
      -- Handle click
      if clicked then
        -- Toggle filter: if already filtered, clear it; otherwise set it
        if is_filtered then
          state.folder_filter_path = nil
        else
          state.folder_filter_path = seg.path
        end
      end
    end
    
    -- Show filename (not clickable)
    if #path_segments > 0 then
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, " / ")
      r.ImGui_SameLine(ctx)
    end
    r.ImGui_TextColored(ctx, 0xFFCCCCCC, preview_sample_obj.name or "Unknown")
    
    -- Add a clear filter button if filter is active
    if state.folder_filter_path and state.folder_filter_path ~= "" then
      r.ImGui_SameLine(ctx)
      if draw_ui_button("clear_folder_filter", "[Clear Folder Filter]", nil, nil, { compact = true }) then
        state.folder_filter_path = nil
      end
    end
  else
    r.ImGui_Text(ctx, preview_sample_obj.name or "Unknown")
  end
  
  r.ImGui_Separator(ctx)

  local transport_w = 52
  local no_scroll_flags = r.ImGui_WindowFlags_NoScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()
  if r.ImGui_BeginChild(ctx, "waveform_transport", transport_w, height, 0, no_scroll_flags) then
    render_playback_controls_compact(transport_w)
    r.ImGui_EndChild(ctx)
  end
  r.ImGui_SameLine(ctx)

  width = r.ImGui_GetContentRegionAvail(ctx)
  local pos_x, pos_y = r.ImGui_GetCursorScreenPos(ctx)
  local x0, y0 = pos_x, pos_y
  
  -- Create invisible button for click detection
  r.ImGui_InvisibleButton(ctx, "waveform_area", width, height)
  local layout_x, layout_y = r.ImGui_GetCursorPos(ctx)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local clicked = r.ImGui_IsItemClicked(ctx, 0)
  local dl = r.ImGui_GetWindowDrawList(ctx)

  -- Track Alt+drag drops from the sample map (not waveform click-to-insert)
  if state.pending_waveform_drop then
    if hovered then
      r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand())
    end
    update_pending_drop_tracking()
  end
  
  -- Draw waveform background
  local bg_color = 0x1A1A1AFF
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + height, bg_color, 0)
  
  -- Draw waveform
  local waveform = waveform_data.data
  if not waveform or #waveform == 0 then
    -- Show message if no waveform data
    r.ImGui_DrawList_AddText(dl, x0 + width * 0.5 - 50, y0 + height * 0.5, 0xFFFFFFFF, "No waveform data")
    render_waveform_overlay_tags(x0, y0, layout_x, layout_y)
    r.ImGui_Separator(ctx)
    return
  end
  
  if waveform and #waveform > 0 then
    local channels = waveform_data.channels or 1
    local channel_data = waveform_data.channel_data
    local frequency_data = waveform_data.frequency_data
    local frequency_channel_data = waveform_data.frequency_channel_data
    
    -- For mono: draw centered waveform (backward compatible)
    -- For stereo+: draw separate waveforms per channel
    if channels == 1 or not channel_data then
      -- Mono waveform: centered display
      local center_y = y0 + height * 0.5
      local half_height = height * 0.4
      
      -- Draw center line
      r.ImGui_DrawList_AddLine(dl, x0, center_y, x0 + width, center_y, 0x444444FF, 1.0)
      
      -- Draw waveform
      local step = width / #waveform
      local prev_x = x0
      local prev_y_top = center_y
      local prev_y_bot = center_y
      local prev_color = nil
      
      for i = 1, #waveform do
        local x = x0 + (i - 1) * step
        local value = waveform[i] or 0.0
        local y_top = center_y - value * half_height
        local y_bot = center_y + value * half_height
        
        -- Get frequency-based color for this pixel
        local freq = frequency_data and frequency_data[i]
        local color = frequency_to_color(freq)
        
        -- Draw vertical line for this sample
        r.ImGui_DrawList_AddLine(dl, x, y_top, x, y_bot, color, 1.5)
        
        -- Draw connecting line to previous sample (use average color for smooth transition)
        if i > 1 then
          local prev_freq = frequency_data and frequency_data[i - 1]
          local prev_color_val = frequency_to_color(prev_freq)
          -- Blend colors for smooth transition
          local avg_color = color
          if prev_color_val ~= color then
            -- Simple average of RGB components
            local r1 = (color >> 16) & 0xFF
            local g1 = (color >> 8) & 0xFF
            local b1 = color & 0xFF
            local r2 = (prev_color_val >> 16) & 0xFF
            local g2 = (prev_color_val >> 8) & 0xFF
            local b2 = prev_color_val & 0xFF
            local r_avg = math.floor((r1 + r2) / 2)
            local g_avg = math.floor((g1 + g2) / 2)
            local b_avg = math.floor((b1 + b2) / 2)
            avg_color = (0xFF << 24) | (r_avg << 16) | (g_avg << 8) | b_avg
          end
          r.ImGui_DrawList_AddLine(dl, prev_x, prev_y_top, x, y_top, avg_color, 1.0)
          r.ImGui_DrawList_AddLine(dl, prev_x, prev_y_bot, x, y_bot, avg_color, 1.0)
        end
        
        prev_x = x
        prev_y_top = y_top
        prev_y_bot = y_bot
        prev_color = color
      end
    else
      -- Multi-channel waveform: draw separate waveforms per channel
      -- For stereo: left channel on top half, right channel on bottom half
      local channel_height = height / channels
      
      for ch = 0, channels - 1 do
        local ch_data = channel_data[ch]
        local ch_freq_data = frequency_channel_data and frequency_channel_data[ch]
        if ch_data and #ch_data > 0 then
          -- Calculate channel-specific parameters
          local ch_y0 = y0 + ch * channel_height
          local ch_y1 = y0 + (ch + 1) * channel_height
          local ch_center_y = (ch_y0 + ch_y1) * 0.5
          local ch_half_height = channel_height * 0.4
          
          -- Draw center line for this channel
          r.ImGui_DrawList_AddLine(dl, x0, ch_center_y, x0 + width, ch_center_y, 0x444444FF, 1.0)
          
          -- Draw waveform for this channel
          local step = width / #ch_data
          local prev_x = x0
          local prev_y_top = ch_center_y
          local prev_y_bot = ch_center_y
          
          for i = 1, #ch_data do
            local x = x0 + (i - 1) * step
            local value = ch_data[i] or 0.0
            local y_top = ch_center_y - value * ch_half_height
            local y_bot = ch_center_y + value * ch_half_height
            
            -- Get frequency-based color for this pixel/channel
            local freq = ch_freq_data and ch_freq_data[i]
            local color = frequency_to_color(freq)
            
            -- Draw vertical line for this sample
            r.ImGui_DrawList_AddLine(dl, x, y_top, x, y_bot, color, 1.5)
            
            -- Draw connecting line to previous sample (use average color for smooth transition)
            if i > 1 then
              local prev_freq = ch_freq_data and ch_freq_data[i - 1]
              local prev_color_val = frequency_to_color(prev_freq)
              -- Blend colors for smooth transition
              local avg_color = color
              if prev_color_val ~= color then
                -- Simple average of RGB components
                local r1 = (color >> 16) & 0xFF
                local g1 = (color >> 8) & 0xFF
                local b1 = color & 0xFF
                local r2 = (prev_color_val >> 16) & 0xFF
                local g2 = (prev_color_val >> 8) & 0xFF
                local b2 = prev_color_val & 0xFF
                local r_avg = math.floor((r1 + r2) / 2)
                local g_avg = math.floor((g1 + g2) / 2)
                local b_avg = math.floor((b1 + b2) / 2)
                avg_color = (0xFF << 24) | (r_avg << 16) | (g_avg << 8) | b_avg
              end
              r.ImGui_DrawList_AddLine(dl, prev_x, prev_y_top, x, y_top, avg_color, 1.0)
              r.ImGui_DrawList_AddLine(dl, prev_x, prev_y_bot, x, y_bot, avg_color, 1.0)
            end
            
            prev_x = x
            prev_y_top = y_top
            prev_y_bot = y_bot
          end
          
          -- Draw separator line between channels (except after last channel)
          if ch < channels - 1 then
            r.ImGui_DrawList_AddLine(dl, x0, ch_y1, x0 + width, ch_y1, 0x333333FF, 1.0)
          end
        end
      end
    end
    
    -- Draw snap offset marker if available
    if preview_sample_obj then
    end
    if preview_sample_obj and preview_sample_obj.snap_offset then
      local snap_time = preview_sample_obj.snap_offset
      local duration = waveform_data.duration or preview_sample_obj.duration or 1.0
      if duration > 0 and snap_time >= 0 and snap_time <= duration then
        local snap_x = x0 + (snap_time / duration) * width
        snap_x = math.max(x0, math.min(x0 + width, snap_x))
        
        -- Draw snap offset line (bright yellow/green, distinct from playhead)
        local snap_color = 0x00FFFFFF  -- Cyan (RRGGBBAA format)
        local snap_thickness = 2.5
        r.ImGui_DrawList_AddLine(dl, snap_x, y0, snap_x, y0 + height, snap_color, snap_thickness)
        
        -- Draw snap offset indicators at top and bottom (triangles pointing down/up)
        local triangle_size = 6.0
        -- Top triangle (pointing down)
        r.ImGui_DrawList_AddTriangleFilled(dl, 
          snap_x, y0, 
          snap_x - triangle_size, y0 + triangle_size, 
          snap_x + triangle_size, y0 + triangle_size, 
          snap_color)
        -- Bottom triangle (pointing up)
        r.ImGui_DrawList_AddTriangleFilled(dl, 
          snap_x, y0 + height, 
          snap_x - triangle_size, y0 + height - triangle_size, 
          snap_x + triangle_size, y0 + height - triangle_size, 
          snap_color)
      end
    end
    
    -- Draw playhead when playing or paused
    local current_pos = get_preview_position()
    local duration = waveform_data.duration or 1.0
    if (preview_proc ~= nil or state.preview_paused) and current_pos ~= nil and duration > 0 then
      local playhead_x = x0 + (current_pos / duration) * width
      playhead_x = math.max(x0, math.min(x0 + width, playhead_x))
      
      -- Draw playhead line (bright yellow, thicker for visibility)
      local playhead_color = 0xFFFF88FF  -- Yellow (RRGGBBAA format)
      local playhead_thickness = 2.0
      r.ImGui_DrawList_AddLine(dl, playhead_x, y0, playhead_x, y0 + height, playhead_color, playhead_thickness)
      
      -- Draw playhead indicators at top and bottom (filled circles for better visibility)
      local indicator_radius = 5.0
      r.ImGui_DrawList_AddCircleFilled(dl, playhead_x, y0, indicator_radius, playhead_color, 16)
    end
  end
  
  -- Handle click to seek
  if clicked then
    local mx, my = r.ImGui_GetMousePos(ctx)
    local rel_x = mx - x0
    local normalized_pos = math.max(0.0, math.min(1.0, rel_x / width))
    local duration = waveform_data.duration or preview_sample_obj.duration or 0.0
    local seek_time = normalized_pos * duration
    
    log(string.format("Waveform click: mx=%.1f, x0=%.1f, rel_x=%.1f, width=%.1f, normalized=%.3f, duration=%.2f, seek_time=%.2fs", 
        mx, x0, rel_x, width, normalized_pos, duration, seek_time))
    preview_sample(preview_sample_obj, seek_time)
  end

  render_waveform_overlay_tags(x0, y0, layout_x, layout_y)
  r.ImGui_Separator(ctx)
end


-- --- Sequencer track helpers -------------------------------------------------
local function get_track_by_guid(track_guid)
  if not track_guid or track_guid == "" then
    return nil
  end
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == track_guid then
      return tr
    end
  end
  return nil
end

local function get_project_tracks_list()
  local tracks = {}
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    local _, name = r.GetTrackName(tr)
    tracks[#tracks + 1] = {
      track = tr,
      guid = r.GetTrackGUID(tr),
      name = name ~= "" and name or ("Track " .. (i + 1)),
    }
  end
  return tracks
end

local function get_reaper_track_display_name(track_guid)
  if not track_guid then
    return nil
  end
  local tr = get_track_by_guid(track_guid)
  if not tr then
    return "(missing track)"
  end
  local _, name = r.GetTrackName(tr)
  if name and name ~= "" then
    return name
  end
  return "(unnamed track)"
end

local function find_sample_by_path(path)
  if not path then
    return nil
  end
  for _, s in ipairs(state.samples) do
    if s.path == path then
      return s
    end
  end
  return nil
end

function sample_drag_active()
  return state.pending_waveform_drop ~= nil
    or (state.is_left_dragging and state.last_dragged_sample_path ~= nil)
end

function get_active_dragged_sample()
  if state.pending_waveform_drop then
    return state.pending_waveform_drop
  end
  if state.last_dragged_sample_path then
    return find_sample_by_path(state.last_dragged_sample_path)
  end
  return nil
end

local function seq_track_has_guid(guid)
  if not guid then
    return false
  end
  for _, slot in ipairs(state.seq_tracks) do
    if slot.reaper_track_guid == guid then
      return true
    end
  end
  return false
end

local function clamp_selected_seq_track()
  if state.selected_seq_track and state.selected_seq_track > #state.seq_tracks then
    state.selected_seq_track = #state.seq_tracks > 0 and #state.seq_tracks or nil
  end
  if state.selected_seq_track and state.selected_seq_track < 1 then
    state.selected_seq_track = nil
  end
  if state.seq_swap_track_idx and state.seq_swap_track_idx > #state.seq_tracks then
    state.seq_swap_track_idx = nil
  end
end

local function add_seq_track_from_reaper_track(tr)
  if not tr then
    return nil
  end
  local guid = r.GetTrackGUID(tr)
  if seq_track_has_guid(guid) then
    return nil
  end
  local _, name = r.GetTrackName(tr)
  local slot = {
    id = state.seq_track_next_id,
    name = name ~= "" and name or ("Track " .. (#state.seq_tracks + 1)),
    reaper_track_guid = guid,
    sample_path = nil,
    sample_name = nil,
  }
  state.seq_track_next_id = state.seq_track_next_id + 1
  table.insert(state.seq_tracks, slot)
  state.selected_seq_track = #state.seq_tracks
  return slot
end

local function add_empty_seq_track()
  local slot = {
    id = state.seq_track_next_id,
    name = "Track " .. (#state.seq_tracks + 1),
    reaper_track_guid = nil,
    sample_path = nil,
    sample_name = nil,
  }
  state.seq_track_next_id = state.seq_track_next_id + 1
  table.insert(state.seq_tracks, slot)
  state.selected_seq_track = #state.seq_tracks
  return slot
end

local function remove_selected_seq_track()
  if not state.selected_seq_track then
    return
  end
  local removed_idx = state.selected_seq_track
  local removed_slot = state.seq_tracks[removed_idx]
  local removed_id = removed_slot and removed_slot.id
  table.remove(state.seq_tracks, removed_idx)
  if state.seq_swap_track_id and removed_id and state.seq_swap_track_id == removed_id then
    state.seq_swap_track_idx = nil
    state.seq_swap_track_id = nil
    state.seq_swap_backup_path = nil
    state.seq_swap_backup_name = nil
  elseif state.seq_swap_track_idx and state.seq_swap_track_idx > removed_idx then
    state.seq_swap_track_idx = state.seq_swap_track_idx - 1
  end
  if #state.seq_tracks == 0 then
    state.selected_seq_track = nil
  elseif state.selected_seq_track > #state.seq_tracks then
    state.selected_seq_track = #state.seq_tracks
  end
  save_config()
end

local function assign_sample_to_seq_track(slot, sample, persist)
  if not slot or not sample or not sample.path then
    return false
  end
  slot.sample_path = sample.path
  slot.sample_name = sample.name or basename(sample.path)
  if update_seq_track_sample_assignments then
    update_seq_track_sample_assignments(slot, sample.path, slot.sample_name, persist == nil or persist)
  end
  if persist == nil or persist then
    save_config()
  end
  return true
end

local function seq_slot_in_swap_mode(slot)
  if not state.seq_swap_track_id or not slot then
    return false
  end
  return slot.id == state.seq_swap_track_id
end

local function find_seq_track_by_id(track_id)
  if not track_id then
    return nil, nil
  end
  for idx, slot in ipairs(state.seq_tracks) do
    if slot.id == track_id then
      return slot, idx
    end
  end
  return nil, nil
end

local function begin_seq_swap_mode(idx)
  local slot = state.seq_tracks[idx]
  if not slot then
    return
  end
  if state.seq_swap_track_id == slot.id then
    state.seq_swap_track_idx = idx
    return
  end
  if state.seq_swap_track_id and state.seq_swap_track_id ~= slot.id then
    local prev_slot = find_seq_track_by_id(state.seq_swap_track_id)
    if prev_slot then
      if state.seq_swap_backup_path then
        assign_sample_to_seq_track(prev_slot, {
          path = state.seq_swap_backup_path,
          name = state.seq_swap_backup_name or basename(state.seq_swap_backup_path),
        }, true)
      else
        prev_slot.sample_path = nil
        prev_slot.sample_name = nil
        save_config()
      end
    end
    state.seq_swap_track_idx = nil
    state.seq_swap_track_id = nil
    state.seq_swap_backup_path = nil
    state.seq_swap_backup_name = nil
  end
  state.seq_swap_track_idx = idx
  state.seq_swap_track_id = slot.id
  state.selected_seq_track = idx
  state.seq_swap_backup_path = slot.sample_path
  state.seq_swap_backup_name = slot.sample_name
  state.active_view = "sample_map"
  save_config()
end

local function end_seq_swap_mode(confirmed)
  local slot, idx = find_seq_track_by_id(state.seq_swap_track_id)
  if not slot then
    state.seq_swap_track_idx = nil
    state.seq_swap_track_id = nil
    state.seq_swap_backup_path = nil
    state.seq_swap_backup_name = nil
    return
  end
  state.seq_swap_track_idx = idx
  if confirmed then
    if slot.sample_path then
      update_seq_track_sample_assignments(slot, slot.sample_path, slot.sample_name, false)
    end
    save_config()
  else
    if state.seq_swap_backup_path then
      assign_sample_to_seq_track(slot, {
        path = state.seq_swap_backup_path,
        name = state.seq_swap_backup_name or basename(state.seq_swap_backup_path),
      }, true)
    else
      slot.sample_path = nil
      slot.sample_name = nil
      save_config()
    end
    if slot.sample_path then
      local restored = find_sample_by_path(slot.sample_path)
      if restored then
        preview_sample(restored)
      end
    end
  end
  state.seq_swap_track_idx = nil
  state.seq_swap_track_id = nil
  state.seq_swap_backup_path = nil
  state.seq_swap_backup_name = nil
end

local function get_active_swap_slot()
  local slot, idx = find_seq_track_by_id(state.seq_swap_track_id)
  if not slot then
    return nil, nil
  end
  state.seq_swap_track_idx = idx
  return slot, idx
end

local function complete_pending_sample_drop()
  local sample = get_active_dragged_sample()
  local mouse_down = r.ImGui_IsMouseDown(ctx, 0)

  if mouse_down then
    if state.pending_waveform_drop then
      -- Escape during the drag cancels everything (no insert, no undo point).
      if r.ImGui_IsKeyPressed and r.ImGui_Key_Escape
          and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape(), false) then
        remove_provisional_drop()
        clear_drag_tooltip()
        state.pending_waveform_drop = nil
        state.last_mouse_time_pos = nil
        state.last_mouse_track = nil
        state.seq_drop_target_idx = nil
        state.seq_timeline_drop_track_idx = nil
        state.seq_timeline_drop_time = nil
        state.is_left_dragging = false
        state.last_dragged_sample_path = nil
        log("Drag cancelled via Escape")
        return
      end
      update_provisional_drop(sample)
    end
    return
  end

  if not sample and not state.pending_waveform_drop and not state.is_left_dragging then
    return
  end

  if sample then
    log("Mouse released globally, completing drag operation")

    if state.seq_drop_target_idx then
      remove_provisional_drop()
      local slot = state.seq_tracks[state.seq_drop_target_idx]
      if slot and sample.path then
        local in_swap = state.seq_swap_track_id and slot.id == state.seq_swap_track_id
        assign_sample_to_seq_track(slot, sample, not in_swap)
        state.selected_seq_track = state.seq_drop_target_idx
        preview_sample(sample)
        log("Swapped '" .. (sample.name or sample.path) .. "' onto " .. slot.name)
      end
    elseif state.pending_waveform_drop then
      local sample_label = sample.name or basename(sample.path or "") or "sample"
      if state.seq_timeline_drop_track_idx and state.seq_timeline_drop_time then
        remove_provisional_drop()
        local slot = state.seq_tracks[state.seq_timeline_drop_track_idx]
        local target_track = nil
        if slot and slot.reaper_track_guid then
          local n = r.CountTracks(0)
          for i = 0, n - 1 do
            local tr = r.GetTrack(0, i)
            if r.GetTrackGUID(tr) == slot.reaper_track_guid then
              target_track = tr
              break
            end
          end
        end
        arrange_undo_begin()
        local success = insert_sample_at_position(sample, state.seq_timeline_drop_time, target_track)
        arrange_undo_end("Insert sample: " .. sample_label)
        if success then
          state.selected_seq_track = state.seq_timeline_drop_track_idx
          log("Inserted '" .. sample_label .. "' via sequencer timeline")
        else
          log("Failed sequencer timeline insertion")
        end
      else
        -- Arrange drop: commit the provisional preview position as one undo point.
        local commit_time, commit_track
        local p = state.provisional_drop
        if p and p.item and r.ValidatePtr(p.item, "MediaItem*") then
          commit_time = p.time or state.last_mouse_time_pos
          if p.track and r.ValidatePtr(p.track, "MediaTrack*") then
            commit_track = p.track
          end
        end
        if not commit_time then
          local dt, dtr = get_drop_position()
          if dt then
            commit_time = maybe_snap_drop_time(dt)
            commit_track = commit_track or dtr
          end
        end
        if not commit_time and state.last_mouse_time_pos then
          commit_time = state.last_mouse_time_pos
          commit_track = commit_track or state.last_mouse_track
        end

        -- Clear the preview before committing so the undo block captures exactly
        -- one media item creation (project returns to clean state first).
        remove_provisional_drop()

        if commit_time then
          arrange_undo_begin()
          local success = insert_sample_at_position(sample, commit_time, commit_track)
          arrange_undo_end("Insert sample: " .. sample_label)
          if success then
            log(string.format("Committed arrange insert at %.3f", commit_time))
          else
            log("Failed to commit arrange insert")
          end
        else
          log("Drag released away from the arrange; insert cancelled")
        end
      end
    end
  end

  remove_provisional_drop()
  clear_drag_tooltip()
  state.pending_waveform_drop = nil
  state.last_mouse_time_pos = nil
  state.last_mouse_track = nil
  state.seq_drop_target_idx = nil
  state.seq_timeline_drop_track_idx = nil
  state.seq_timeline_drop_time = nil
  state.is_left_dragging = false
  state.last_dragged_sample_path = nil
end

local function clear_seq_track_sample(slot)
  if not slot then
    return
  end
  slot.sample_path = nil
  slot.sample_name = nil
  save_config()
end

local function add_seq_tracks_from_selection()
  local count = r.CountSelectedTracks(0)
  if count == 0 then
    add_empty_seq_track()
    save_config()
    return
  end
  local added = 0
  for i = 0, count - 1 do
    local tr = r.GetSelectedTrack(0, i)
    if add_seq_track_from_reaper_track(tr) then
      added = added + 1
    end
  end
  if added == 0 then
    log("Selected project tracks are already in the sequencer track list")
  else
    save_config()
  end
end

function seq_trim_text(value)
  local text = tostring(value or "")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

function find_sample_for_tag(tag_name)
  local needle = seq_trim_text(tag_name):lower()
  if needle == "" then
    return nil
  end
  for _, sample in ipairs(state.samples) do
    if sample_has_tag(sample, needle) then
      return sample
    end
  end
  return nil
end

function sample_has_tag(sample, tag_name)
  if not sample or not sample.tags or type(sample.tags) ~= "table" then
    return false
  end
  local needle = seq_trim_text(tag_name):lower()
  if needle == "" then
    return false
  end
  for _, sample_tag in ipairs(sample.tags) do
    if tostring(sample_tag):lower() == needle then
      return true
    end
  end
  return false
end

function create_seq_track_with_name(track_name)
  local final_name = seq_trim_text(track_name)
  if final_name == "" then
    final_name = "Track " .. tostring(#state.seq_tracks + 1)
  end

  local insert_idx = r.CountTracks(0)
  r.InsertTrackAtIndex(insert_idx, true)
  local tr = r.GetTrack(0, insert_idx)
  if not tr then
    return nil
  end

  r.GetSetMediaTrackInfo_String(tr, "P_NAME", final_name, true)
  local slot = add_seq_track_from_reaper_track(tr)
  if not slot then
    return nil
  end

  slot.name = final_name
  return slot
end

function create_seq_track_from_popup(track_name, tag_name)
  local slot = create_seq_track_with_name(track_name)
  if not slot then
    return false
  end

  local chosen_tag = seq_trim_text(tag_name)
  if chosen_tag ~= "" then
    slot.sample_tag = chosen_tag
    local sample = find_sample_for_tag(chosen_tag)
    if sample then
      assign_sample_to_seq_track(slot, sample, false)
    else
      log("No sample found for tag '" .. chosen_tag .. "'")
    end
  end

  save_config()
  if r.TrackList_AdjustWindows then
    r.TrackList_AdjustWindows(false)
  end
  r.UpdateArrange()
  return true
end

function seq_add_popup_tag_width(tag_label)
  local text_w = r.ImGui_CalcTextSize(ctx, tag_label)
  local pad_x = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())
  return text_w + pad_x * 2
end

function seq_add_popup_count_rows(query_lower, content_w)
  content_w = math.max(120.0, content_w or 480.0)
  local rows = 0
  local row_w = 0.0
  local gap = 6.0
  for _, entry in ipairs(state.tag_list or {}) do
    local tag = tostring(entry.tag or "")
    if query_lower == "" or tag:lower():find(query_lower, 1, true) then
      local tw = seq_add_popup_tag_width(tag)
      if rows == 0 then
        rows = 1
        row_w = tw
      elseif row_w + gap + tw > content_w then
        rows = rows + 1
        row_w = tw
      else
        row_w = row_w + gap + tw
      end
    end
  end
  return math.max(1, rows)
end

function seq_add_popup_window_height(trimmed_query)
  local popup_w = 520.0
  local content_w = popup_w - 32.0
  local query_lower = seq_trim_text(trimmed_query):lower()
  local rows = seq_add_popup_count_rows(query_lower, content_w)
  local tag_row_h = 28.0
  return math.max(220.0, 118.0 + rows * tag_row_h + 12.0)
end

function open_seq_add_track_popup()
  state.seq_new_track_query = ""
  if (not state.tag_list or #state.tag_list == 0) and #state.samples > 0 then
    rebuild_tag_index()
  end
  if r.ImGui_SetNextWindowSize then
    local cond = r.ImGui_Cond_Appearing and r.ImGui_Cond_Appearing() or 0
    r.ImGui_SetNextWindowSize(ctx, 520, seq_add_popup_window_height(""), cond)
  end
  r.ImGui_OpenPopup(ctx, "seq_add_track_popup")
end

function render_seq_add_track_full_width_button(button_id, button_h)
  if draw_ui_button(tostring(button_id or "seq_add_track_popup_open"), nil, nil, button_h or 28, { icon = "plus", full_width = true, style = "primary" }) then
    open_seq_add_track_popup()
  end
end

function render_seq_add_popup_tag_list(trimmed_query)
  local wrap_w = r.ImGui_GetContentRegionAvail(ctx)
  local query_lower = seq_trim_text(trimmed_query):lower()
  local row_w = 0.0
  local gap = 6.0
  local shown_tags = 0
  local first_tag = true

  for idx, entry in ipairs(state.tag_list or {}) do
    local tag = tostring(entry.tag or "")
    if query_lower == "" or tag:lower():find(query_lower, 1, true) then
      local tw = seq_add_popup_tag_width(tag)
      if not first_tag then
        if row_w + gap + tw > wrap_w then
          row_w = 0.0
        else
          r.ImGui_SameLine(ctx, 0, gap)
          row_w = row_w + gap
        end
      end
      first_tag = false
      shown_tags = shown_tags + 1
      if draw_tag_button(ctx, tag, false, tag, "seq_add_popup_" .. tostring(idx) .. "_") then
        if create_seq_track_from_popup(tag, tag) then
          state.seq_new_track_query = ""
          r.ImGui_CloseCurrentPopup(ctx)
        end
      end
      row_w = row_w + tw
    end
  end

  if shown_tags == 0 then
    r.ImGui_TextColored(ctx, 0xFF888888, "No tags match filter")
  end
  return shown_tags
end

function render_seq_add_track_popup()
  local trimmed_query = seq_trim_text(state.seq_new_track_query)
  if r.ImGui_IsPopupOpen and r.ImGui_IsPopupOpen(ctx, "seq_add_track_popup") and r.ImGui_SetNextWindowSize then
    local cond = r.ImGui_Cond_Always and r.ImGui_Cond_Always() or 0
    r.ImGui_SetNextWindowSize(ctx, 520, seq_add_popup_window_height(trimmed_query), cond)
  end

  if not r.ImGui_BeginPopup(ctx, "seq_add_track_popup") then
    return
  end

  if (not state.tag_list or #state.tag_list == 0) and #state.samples > 0 then
    rebuild_tag_index()
  end

  r.ImGui_Text(ctx, "Track Name / Tag Search")
  local changed, query = r.ImGui_InputText(ctx, "##seq_new_track_query", state.seq_new_track_query or "", 128)
  if changed then
    state.seq_new_track_query = query
    trimmed_query = seq_trim_text(query)
  end

  local create_label = (trimmed_query ~= "") and ('Create "' .. trimmed_query .. '"') or "Create Track"
  if draw_ui_button("seq_create_custom", create_label, nil, nil, { full_width = true, style = "primary" }) then
    if create_seq_track_from_popup(trimmed_query, nil) then
      state.seq_new_track_query = ""
      r.ImGui_CloseCurrentPopup(ctx)
    end
  end

  r.ImGui_Separator(ctx)
  r.ImGui_Text(ctx, "Available Tags")
  r.ImGui_Dummy(ctx, 0, 4)
  render_seq_add_popup_tag_list(trimmed_query)
  r.ImGui_EndPopup(ctx)
end

local function get_selected_seq_track()
  clamp_selected_seq_track()
  if not state.selected_seq_track then
    return nil
  end
  return state.seq_tracks[state.selected_seq_track]
end

local function preview_seq_track_sample(slot)
  if not slot or not slot.sample_path then
    return false
  end
  local sample = find_sample_by_path(slot.sample_path)
  if not sample then
    return false
  end
  preview_sample(sample)
  state.seq_track_play_anims = state.seq_track_play_anims or {}
  state.seq_track_play_anims[tostring(slot.id)] = {
    start_time = r.time_precise(),
    duration = 0.35,
  }
  return true
end

local function select_seq_track(idx, opts)
  opts = opts or {}
  if not idx or idx < 1 or idx > #state.seq_tracks then
    return false
  end
  state.selected_seq_track = idx
  save_config()
  if opts.preview ~= false then
    preview_seq_track_sample(state.seq_tracks[idx])
  end
  return true
end

-- Exposed for the upcoming sequencer UI
function SampleMapBrowser_GetSeqTracks()
  return state.seq_tracks
end

function SampleMapBrowser_GetSelectedSeqTrack()
  return get_selected_seq_track()
end

function SampleMapBrowser_GetSeqTrackSample(slot)
  if not slot or not slot.sample_path then
    return nil
  end
  return find_sample_by_path(slot.sample_path)
end

local function get_sample_dot_color(sample)
  if not sample then
    return build_color_rrgbbaa(96, 96, 96, 255)
  end

  local color = build_color_rrgbbaa(extract_rgb(state.dot_color or 0x44AA55))
  if sample.tags and type(sample.tags) == "table" and #sample.tags > 0 then
    local best_tag = nil
    local best_weight = 0
    for _, tag_name in ipairs(sample.tags) do
      for _, keyword_entry in ipairs(TAG_KEYWORDS) do
        if keyword_entry.tag == tag_name and keyword_entry.weight > best_weight then
          best_weight = keyword_entry.weight
          best_tag = tag_name
        end
      end
    end
    if best_tag and state.tag_colors[best_tag] then
      local tr, tg, tb = extract_rgb(state.tag_colors[best_tag])
      color = build_color_rrgbbaa(tr, tg, tb, 255)
    end
  end

  if sample.channels == 1 then
    local base_r, base_g, base_b = extract_rgb_rrgbbaa(color)
    color = build_color_rrgbbaa(
      math.min(255, math.floor(base_r * 1.5)),
      math.min(255, math.floor(base_g * 1.5)),
      math.min(255, math.floor(base_b * 1.5)),
      255
    )
  end

  return color
end

-- Eased 0..1 pulse used for animated drag/drop feedback.
function drag_pulse()
  return 0.5 + 0.5 * math.sin(r.time_precise() * 6.0)
end

-- Highlight a rectangular drop target while a sample is being dragged onto it.
function draw_drop_target_highlight(dl, x0, y0, x1, y1, radius)
  radius = radius or 4.0
  local pulse = drag_pulse()
  local fill = build_color_rrgbbaa(68, 136, 255, math.floor(40 + 45 * pulse))
  local border = build_color_rrgbbaa(120, 180, 255, math.floor(170 + 85 * pulse))
  local accent = build_color_rrgbbaa(120, 180, 255, 255)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, radius)
  r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, border, radius, 0, 2.0)
  -- Bright accent bar on the left edge so the active target reads at a glance.
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + 3.0, y1, accent, radius)
end

-- Floating feedback that follows the cursor while a sample is being dragged.
function draw_sample_drag_ghost()
  local sample = get_active_dragged_sample()
  if not sample then
    clear_drag_tooltip()
    return
  end

  local name = sample.name or basename(sample.path or "") or "sample"
  if #name > 40 then
    name = name:sub(1, 39) .. "..."
  end

  -- Arrange-drop drag (Alt+drag): use REAPER's native tooltip window so the
  -- label stays visible even when the cursor leaves the script's ImGui window.
  if state.pending_waveform_drop then
    local hint
    if state.seq_drop_target_idx then
      hint = "Release to swap track sample"
    elseif state.seq_timeline_drop_time then
      hint = "Release to insert on this track"
    elseif state.provisional_drop then
      hint = "Drop to insert on the arrange"
    else
      hint = "Drag over the arrange to insert  (Esc to cancel)"
    end
    if r.TrackCtl_SetToolTip and r.GetMousePosition then
      local sx, sy = r.GetMousePosition()
      r.TrackCtl_SetToolTip(name .. "\n" .. hint, math.floor((sx or 0) + 22), math.floor((sy or 0) + 22), true)
      state.drag_tooltip_active = true
    end
    return
  end

  clear_drag_tooltip()

  local mx, my = r.ImGui_GetMousePos(ctx)
  if not mx or mx ~= mx then
    return
  end

  local dl = (r.APIExists and r.APIExists("ImGui_GetForegroundDrawList"))
    and r.ImGui_GetForegroundDrawList(ctx)
    or r.ImGui_GetWindowDrawList(ctx)

  if #name > 30 then
    name = name:sub(1, 29) .. "..."
  end

  local over_target = state.seq_drop_target_idx ~= nil
  local hint = over_target and "Release to swap track sample" or "Drag onto a sequencer track"

  local dot_color = get_sample_dot_color(sample)
  local pulse = drag_pulse()

  local name_w, name_h = r.ImGui_CalcTextSize(ctx, name)
  local hint_w, hint_h = r.ImGui_CalcTextSize(ctx, hint)
  local dot_r = 5.0
  local pad = 8.0
  local gap = 7.0
  local line_gap = 3.0
  local text_block_w = math.max(name_w, hint_w)
  local chip_w = pad + dot_r * 2 + gap + text_block_w + pad
  local chip_h = pad + name_h + line_gap + hint_h + pad

  local x0 = mx + 18.0
  local y0 = my + 12.0
  local x1 = x0 + chip_w
  local y1 = y0 + chip_h

  r.ImGui_DrawList_AddRectFilled(dl, x0 + 2, y0 + 3, x1 + 2, y1 + 3, 0x00000070, 7.0)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x1E2230F5, 7.0)

  local cr, cg, cb = extract_rgb_rrgbbaa(dot_color)
  local border = build_color_rrgbbaa(cr, cg, cb, math.floor(140 + 115 * pulse))
  r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, border, 7.0, 0, 1.5)

  local cx = x0 + pad + dot_r
  local cy = y0 + pad + name_h * 0.5
  r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, dot_r, dot_color, 16)
  r.ImGui_DrawList_AddCircle(dl, cx, cy, dot_r + 1.5, border, 16, 1.0)

  local tx = x0 + pad + dot_r * 2 + gap
  r.ImGui_DrawList_AddText(dl, tx, y0 + pad, 0xFFFFFFFF, name)
  local hint_color = over_target and 0x8FE0A6FF or 0x9FB2CCFF
  r.ImGui_DrawList_AddText(dl, tx, y0 + pad + name_h + line_gap, hint_color, hint)
end

local function find_map_neighbor_sample(current, direction, required_tag)
  if not current or not current.path then
    return nil
  end

  local cx = current.x or 0.5
  local cy = current.y or 0.5
  local best = nil
  local best_dist = math.huge
  local tag_filter = required_tag and seq_trim_text(required_tag) or ""

  for _, s in ipairs(state.samples) do
    if s.path and s.path ~= current.path and s.x and s.y
      and (tag_filter == "" or sample_has_tag(s, tag_filter)) then
      if direction < 0 then
        local dx = cx - s.x
        if dx > 1e-5 then
          local dist = dx * dx + (cy - s.y) * (cy - s.y)
          if dist < best_dist then
            best_dist = dist
            best = s
          end
        end
      else
        local dx = s.x - cx
        if dx > 1e-5 then
          local dist = dx * dx + (cy - s.y) * (cy - s.y)
          if dist < best_dist then
            best_dist = dist
            best = s
          end
        end
      end
    end
  end

  return best
end

local function collect_map_samples_by_distance(origin)
  local ranked = {}
  if not origin or not origin.path then
    return ranked
  end

  local cx = origin.x or 0.5
  local cy = origin.y or 0.5
  for _, s in ipairs(state.samples) do
    if s.path and s.path ~= origin.path and s.x and s.y then
      local dx = s.x - cx
      local dy = s.y - cy
      ranked[#ranked + 1] = { sample = s, dist = math.sqrt(dx * dx + dy * dy) }
    end
  end

  table.sort(ranked, function(a, b)
    if math.abs(a.dist - b.dist) < 1e-9 then
      return (a.sample.path or "") < (b.sample.path or "")
    end
    return a.dist < b.dist
  end)
  return ranked
end

seq_vary_rank_cache = {}

local function clear_seq_vary_rank_cache()
  seq_vary_rank_cache = {}
end

local function get_map_samples_ranked_from_path(base_path)
  if not base_path then
    return {}
  end
  if seq_vary_rank_cache[base_path] then
    return seq_vary_rank_cache[base_path]
  end
  local origin = find_sample_by_path(base_path)
  local ranked = origin and collect_map_samples_by_distance(origin) or {}
  seq_vary_rank_cache[base_path] = ranked
  return ranked
end

local function resolve_seq_note_sample(note, slot)
  -- Track slot sample is the vary origin; keeps sample_vary rankings tied to the current assignment.
  local base_path = (slot and slot.sample_path) or (note and note.sample_path)
  if not base_path then
    return nil, nil
  end

  local vary = note and note.sample_vary or 0.0
  if vary <= 0.000001 then
    return base_path, find_sample_by_path(base_path)
  end

  local origin = find_sample_by_path(base_path)
  if not origin or origin.x == nil or origin.y == nil then
    return base_path, origin
  end

  local ranked = get_map_samples_ranked_from_path(base_path)
  if #ranked == 0 then
    return base_path, origin
  end

  local t = math.max(0.0, math.min(1.0, vary))
  local idx = math.max(1, math.min(#ranked, math.ceil(t * #ranked)))
  local picked = ranked[idx].sample
  return picked.path, picked
end

local function swap_seq_track_sample_neighbor(slot, direction)
  if not slot or not slot.sample_path then
    return false
  end

  local current = find_sample_by_path(slot.sample_path)
  if not current then
    return false
  end

  local neighbor = find_map_neighbor_sample(current, direction, slot.sample_tag)
  if not neighbor then
    if slot.sample_tag and seq_trim_text(slot.sample_tag) ~= "" then
      log("No more samples with tag '" .. slot.sample_tag .. "' " .. (direction < 0 and "to the left" or "to the right") .. " on the map")
    else
      log("No similar sample " .. (direction < 0 and "to the left" or "to the right") .. " on the map")
    end
    return false
  end

  assign_sample_to_seq_track(slot, neighbor, not seq_slot_in_swap_mode(slot))
  preview_seq_track_sample(slot)
  return true
end

local function render_swap_mode_bar()
  if not state.seq_swap_track_id then
    return
  end

  local slot, idx = get_active_swap_slot()
  if not slot then
    state.seq_swap_track_idx = nil
    state.seq_swap_track_id = nil
    state.seq_swap_backup_path = nil
    state.seq_swap_backup_name = nil
    return
  end
  state.seq_swap_track_idx = idx

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), 0x2A2A2AF0)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), 8)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FramePadding(), 10, 8)

  r.ImGui_Text(ctx, "Swap sample:")
  r.ImGui_SameLine(ctx)
  r.ImGui_TextColored(ctx, 0xFF88CCFF, slot.name)
  r.ImGui_SameLine(ctx)

  if state.block_swap_bar_input then
    r.ImGui_BeginDisabled(ctx)
  end

  if draw_ui_button("swap_cancel", nil, 28, 26, { icon = "close", style = "danger" }) then
    end_seq_swap_mode(false)
  end

  r.ImGui_SameLine(ctx)
  if draw_ui_button("swap_confirm", nil, 28, 26, { icon = "check", style = "success" }) then
    end_seq_swap_mode(true)
  end

  if state.block_swap_bar_input then
    r.ImGui_EndDisabled(ctx)
  end

  r.ImGui_PopStyleVar(ctx, 2)
  r.ImGui_PopStyleColor(ctx, 1)
  r.ImGui_Separator(ctx)
end

SEQ_SAMPLE_DOT_SIZE = 22.0
SEQ_TRACK_PLAY_ANIM_DURATION = 0.35

local function prune_seq_track_play_anims(now)
  local anims = state.seq_track_play_anims
  if not anims then
    return
  end
  for key, anim in pairs(anims) do
    local start_t = anim.start_time or 0.0
    local dur = anim.duration or SEQ_TRACK_PLAY_ANIM_DURATION
    if (now - start_t) >= dur then
      anims[key] = nil
    end
  end
end

local function get_seq_track_play_anim(track_id, now)
  local anims = state.seq_track_play_anims
  if not anims or track_id == nil then
    return nil
  end
  local anim = anims[tostring(track_id)]
  if not anim then
    return nil
  end
  local dur = anim.duration or SEQ_TRACK_PLAY_ANIM_DURATION
  local t = dur > 0 and ((now - (anim.start_time or now)) / dur) or 1.0
  if t <= 0.0 then
    t = 0.0
  elseif t >= 1.0 then
    anims[tostring(track_id)] = nil
    return nil
  end
  anim.t = t
  return anim
end

local function draw_seq_track_play_row_fx(dl, x0, y0, x1, y1, play_t, sample)
  if not play_t then
    return
  end
  local pulse = math.sin(play_t * math.pi)
  local accent = sample and get_sample_dot_color(sample) or 0x88CCFFFF
  local ar, ag, ab = extract_rgb_rrgbbaa(accent)
  local bg_alpha = math.floor(24 + pulse * 48 + (1.0 - play_t) * 36)
  local edge_alpha = math.floor(50 + pulse * 130)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, build_color_rrgbbaa(ar, ag, ab, bg_alpha), 4)
  r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, build_color_rrgbbaa(255, 255, 255, edge_alpha), 4, 0, 1.0 + pulse * 1.5)
  local bar_w = 2.0 + pulse * 3.0
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + bar_w, y1, build_color_rrgbbaa(ar, ag, ab, math.floor(110 + pulse * 145)), 2)
end

local function get_seq_track_sample_controls_width(ctrl_size)
  ctrl_size = ctrl_size or 20.0
  local item_spacing = 8.0
  if r.ImGui_GetStyleVar and r.ImGui_StyleVar_ItemSpacing then
    local spacing = { r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing()) }
    if spacing[1] and spacing[1] > 0 then
      item_spacing = spacing[1]
    end
  end
  return ctrl_size * 2 + SEQ_SAMPLE_DOT_SIZE + item_spacing * 2 + 2.0
end

local function draw_sample_dot_control(sample, id_suffix, is_swap_active, play_t)
  local size = SEQ_SAMPLE_DOT_SIZE
  r.ImGui_InvisibleButton(ctx, "seq_dot_" .. id_suffix, size, size)
  local clicked = r.ImGui_IsItemClicked(ctx, 0)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local min_x, min_y = r.ImGui_GetItemRectMin(ctx)
  local max_x, max_y = r.ImGui_GetItemRectMax(ctx)
  local cx = (min_x + max_x) * 0.5
  local cy = (min_y + max_y) * 0.5
  local pulse = play_t and math.sin(play_t * math.pi) or 0.0
  local radius = 6.0 + pulse * 2.5
  local fill = get_sample_dot_color(sample)
  local ring_color = is_swap_active and 0xFFFFFFFF or 0x666666FF
  local ring_radius = radius + (is_swap_active and 2.5 or 1.0)
  local ring_thickness = is_swap_active and 2.0 or 1.0

  if play_t and sample then
    local ripple_r = ring_radius + 4.0 + play_t * 12.0
    local ripple_alpha = math.floor((1.0 - play_t) * 170 + pulse * 35)
    local sr, sg, sb = extract_rgb_rrgbbaa(fill)
    r.ImGui_DrawList_AddCircle(dl, cx, cy, ripple_r, build_color_rrgbbaa(sr, sg, sb, ripple_alpha), 24, 1.5)
    local outer_r = radius + 3.0 + pulse * 4.0
    r.ImGui_DrawList_AddCircle(dl, cx, cy, outer_r, build_color_rrgbbaa(255, 255, 255, math.floor(40 + pulse * 120)), 24, 1.0)
  end

  if sample then
    r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, radius, fill, 24)
  end
  r.ImGui_DrawList_AddCircle(dl, cx, cy, ring_radius, ring_color, 24, ring_thickness)

  return clicked, hovered
end

local function render_seq_track_sample_controls(slot, idx, opts)
  opts = opts or {}
  local id_suffix = opts.id_suffix or tostring(slot.id)
  local ctrl_size = opts.ctrl_size or 20.0
  local show_sample_label = opts.show_sample_label == true
  local sample_label_max_len = opts.sample_label_max_len or 22

  local swap_active = state.seq_swap_track_id and state.seq_swap_track_id == slot.id
  local assigned_sample = slot.sample_path and find_sample_by_path(slot.sample_path) or nil
  local play_anim = get_seq_track_play_anim(slot.id, r.time_precise())
  local play_t = play_anim and play_anim.t or nil
  local sample_label = slot.sample_name or "(no sample)"
  if #sample_label > sample_label_max_len then
    sample_label = sample_label:sub(1, sample_label_max_len - 3) .. "..."
  end

  local row_drop_hovered = false
  local can_nav = assigned_sample ~= nil

  if not can_nav then
    r.ImGui_BeginDisabled(ctx)
  end
  if draw_ui_button("seq_left_" .. id_suffix, nil, ctrl_size, ctrl_size, { icon = "chev_left", compact = true, style = "ghost_arrow" }) then
    swap_seq_track_sample_neighbor(slot, -1)
  end
  if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
    row_drop_hovered = true
  end
  if not can_nav then
    r.ImGui_EndDisabled(ctx)
  end

  r.ImGui_SameLine(ctx)
  local dot_clicked, dot_hovered = draw_sample_dot_control(assigned_sample, id_suffix, swap_active, play_t)
  if dot_clicked and not sample_drag_active() then
    begin_seq_swap_mode(idx)
    if state.active_view ~= "sample_map" then
      state.active_view = "sample_map"
      save_config()
    end
  end
  if sample_drag_active() and dot_hovered then
    row_drop_hovered = true
  end

  r.ImGui_SameLine(ctx)
  if not can_nav then
    r.ImGui_BeginDisabled(ctx)
  end
  if draw_ui_button("seq_right_" .. id_suffix, nil, ctrl_size, ctrl_size, { icon = "chev_right", compact = true, style = "ghost_arrow" }) then
    swap_seq_track_sample_neighbor(slot, 1)
  end
  if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
    row_drop_hovered = true
  end
  if not can_nav then
    r.ImGui_EndDisabled(ctx)
  end

  if show_sample_label then
    r.ImGui_SameLine(ctx)
    r.ImGui_AlignTextToFramePadding(ctx)
    r.ImGui_TextColored(ctx, assigned_sample and 0xFFCCCCCC or 0xFF666666, sample_label)
    if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
      row_drop_hovered = true
    end
  end

  return {
    row_drop_hovered = row_drop_hovered,
    swap_active = swap_active,
  }
end


local function render_seq_tracks_panel()
  r.ImGui_Text(ctx, "Sequencer Tracks")
  r.ImGui_Separator(ctx)

  if draw_ui_button("seq_add_sel", "Add selected", nil, nil, { style = "primary" }) then
    add_seq_tracks_from_selection()
  end

  r.ImGui_SameLine(ctx)
  local remove_disabled = not state.selected_seq_track
  if remove_disabled then
    r.ImGui_BeginDisabled(ctx)
  end
  if draw_ui_button("seq_remove", "Remove", nil, nil, { style = "danger" }) then
    remove_selected_seq_track()
  end
  if remove_disabled then
    r.ImGui_EndDisabled(ctx)
  end

  if state.seq_random_edit_region_id then
    local random_edit_region = nil
    for _, reg in ipairs(state.seq_regions) do
      if reg.id == state.seq_random_edit_region_id then
        random_edit_region = reg
        break
      end
    end
    if random_edit_region then
      r.ImGui_TextColored(ctx, 0xD7E8FFFF, "Region Random: " .. (random_edit_region.name or ("Region " .. tostring(random_edit_region.id))))
      r.ImGui_TextColored(ctx, 0x88A0BFFF, "Adjust knobs inside sequencer lanes.")
    else
      state.seq_random_edit_region_id = nil
    end
  end

  r.ImGui_Separator(ctx)

  prune_seq_track_play_anims(r.time_precise())

  local add_row_h = 28.0
  local add_row_gap = 6.0
  local _, panel_avail_h = r.ImGui_GetContentRegionAvail(ctx)
  local list_height = math.max(40.0, panel_avail_h - add_row_h - add_row_gap)
  local track_count = #state.seq_tracks
  local row_budget = track_count > 0 and (list_height / track_count) or list_height
  local tight = row_budget < 46.0
  local compact = row_budget < 68.0
  local inline_controls = compact
  local ctrl_size = tight and 16.0 or (compact and 18.0 or 20.0)
  local show_linked_name = not compact

  if track_count == 0 then
    r.ImGui_TextColored(ctx, 0xFF888888, "No tracks")
  else
    for idx, slot in ipairs(state.seq_tracks) do
      local selected = state.selected_seq_track == idx
      local swap_active = state.seq_swap_track_id and state.seq_swap_track_id == slot.id
      local linked_name = show_linked_name and get_reaper_track_display_name(slot.reaper_track_guid) or nil
      local assigned_sample = slot.sample_path and find_sample_by_path(slot.sample_path) or nil

      r.ImGui_PushID(ctx, slot.id)

      local row_x, row_y = r.ImGui_GetCursorScreenPos(ctx)
      local row_drop_hovered = false

      if swap_active then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Header(), 0x335588AA)
      end

      local avail_w = r.ImGui_GetContentRegionAvail(ctx)
      local nav_opts = {
        id_suffix = slot.id,
        ctrl_size = ctrl_size,
      }

      if inline_controls then
        local nav_reserve = get_seq_track_sample_controls_width(ctrl_size)
        local name_w = math.max(48.0, avail_w - nav_reserve)
        r.ImGui_Selectable(ctx, slot.name .. "##seq_name_" .. slot.id, selected and not swap_active, 0, name_w, 0)
        if r.ImGui_IsItemClicked(ctx, 0) and not sample_drag_active() then
          select_seq_track(idx)
        end
        if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
          row_drop_hovered = true
        end
        r.ImGui_SameLine(ctx)
        local nav = render_seq_track_sample_controls(slot, idx, nav_opts)
        if nav.row_drop_hovered then
          row_drop_hovered = true
        end
      else
        r.ImGui_Selectable(ctx, slot.name .. "##seq_name_" .. slot.id, selected and not swap_active, 0, avail_w, 0)
        if r.ImGui_IsItemClicked(ctx, 0) and not sample_drag_active() then
          select_seq_track(idx)
        end
        if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
          row_drop_hovered = true
        end

        if linked_name and linked_name ~= slot.name then
          r.ImGui_TextColored(ctx, 0xFF888888, "  " .. linked_name)
          if sample_drag_active() and r.ImGui_IsItemHovered(ctx) then
            row_drop_hovered = true
          end
        end

        local nav = render_seq_track_sample_controls(slot, idx, nav_opts)
        if nav.row_drop_hovered then
          row_drop_hovered = true
        end
      end

      if swap_active then
        r.ImGui_PopStyleColor(ctx, 1)
      end

      local _, row_end_y = r.ImGui_GetCursorScreenPos(ctx)
      if sample_drag_active() then
        local mx, my = r.ImGui_GetMousePos(ctx)
        if mx >= row_x and mx < row_x + avail_w and my >= row_y and my < row_end_y then
          row_drop_hovered = true
        end
      end
      local play_anim = get_seq_track_play_anim(slot.id, r.time_precise())
      if play_anim then
        local row_dl = r.ImGui_GetWindowDrawList(ctx)
        draw_seq_track_play_row_fx(row_dl, row_x, row_y, row_x + avail_w, row_end_y, play_anim.t, assigned_sample)
      end
      if sample_drag_active() and row_drop_hovered then
        state.seq_drop_target_idx = idx
        state.seq_timeline_drop_time = nil
        state.seq_timeline_drop_track_idx = nil
        local row_dl = r.ImGui_GetWindowDrawList(ctx)
        draw_drop_target_highlight(row_dl, row_x, row_y, row_x + avail_w, row_end_y, 4)
      end

      if not tight then
        r.ImGui_Separator(ctx)
      else
        r.ImGui_Dummy(ctx, 0, 2)
      end
      r.ImGui_PopID(ctx)
    end
  end

  r.ImGui_Dummy(ctx, 0, add_row_gap)
  render_seq_add_track_full_width_button("seq_add_track_popup_open", add_row_h)
  render_seq_add_track_popup()

  if sample_drag_active() and state.seq_drop_target_idx then
    r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand())
  end
end

local function get_arrange_view_range()
  if r.GetSet_ArrangeView2 then
    local a, b, c, d = r.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
    local start_time = nil
    local end_time = nil
    if type(a) == "number" and type(b) == "number" then
      start_time, end_time = a, b
    elseif type(c) == "number" and type(d) == "number" then
      start_time, end_time = c, d
    end
    if start_time and end_time and end_time > start_time then
      return start_time, end_time
    end
  end
  local cursor = r.GetCursorPosition()
  return math.max(0.0, cursor - 4.0), cursor + 12.0
end

local function get_project_grid_step_qn()
  local step_qn = 0.25
  if r.GetSetProjectGrid then
    local _, div = r.GetSetProjectGrid(0, false)
    if type(div) == "number" and div > 0.000001 then
      step_qn = math.abs(div)
    end
  end
  return step_qn
end

local function time_to_qn(time_pos)
  if r.TimeMap2_timeToQN then
    return r.TimeMap2_timeToQN(0, time_pos)
  elseif r.TimeMap_timeToQN then
    return r.TimeMap_timeToQN(time_pos)
  end
  return nil
end

local function qn_to_time(qn)
  if r.TimeMap2_QNToTime then
    return r.TimeMap2_QNToTime(0, qn)
  elseif r.TimeMap_QNToTime then
    return r.TimeMap_QNToTime(qn)
  end
  return nil
end

local function get_visible_qn_grid_range(qn_start_raw, qn_end_raw)
  local step_qn = (type(state.seq_grid_qn) == "number" and state.seq_grid_qn > 0) and state.seq_grid_qn or get_project_grid_step_qn()
  qn_start_raw = qn_start_raw or 0.0
  qn_end_raw = qn_end_raw or (qn_start_raw + step_qn * 16.0)
  if qn_end_raw <= qn_start_raw then
    qn_end_raw = qn_start_raw + step_qn * 16.0
  end

  local start_qn = math.floor((qn_start_raw / step_qn) + 1e-9) * step_qn
  local end_qn = math.ceil((qn_end_raw / step_qn) - 1e-9) * step_qn
  if end_qn <= start_qn then
    end_qn = start_qn + step_qn
  end

  local step_count = math.max(1, math.floor(((end_qn - start_qn) / step_qn) + 0.5))
  local max_steps = 768
  if step_count > max_steps then
    local mult = math.ceil(step_count / max_steps)
    step_qn = step_qn * mult
    start_qn = math.floor((qn_start_raw / step_qn) + 1e-9) * step_qn
    end_qn = math.ceil((qn_end_raw / step_qn) - 1e-9) * step_qn
    if end_qn <= start_qn then
      end_qn = start_qn + step_qn
    end
    step_count = math.max(1, math.floor(((end_qn - start_qn) / step_qn) + 0.5))
  end

  return start_qn, end_qn, step_qn, step_count
end

local function get_seq_slot_target_track(slot)
  if not slot then
    return nil
  end
  if slot.reaper_track_guid then
    local tr = get_track_by_guid(slot.reaper_track_guid)
    if tr then
      return tr
    end
  end
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    return tr
  end
  if r.CountTracks(0) > 0 then
    return r.GetTrack(0, 0)
  end
  return nil
end

local function collect_seq_item_cells(start_qn, end_qn, step_qn, step_count)
  local occupied_any = {}
  local occupied_match = {}

  for idx, slot in ipairs(state.seq_tracks) do
    occupied_any[idx] = {}
    occupied_match[idx] = {}

    local tr = get_seq_slot_target_track(slot)
    if tr then
      local item_count = r.CountTrackMediaItems(tr)
      local expected_path = nil
      if slot.sample_path and slot.sample_path ~= "" then
        expected_path = normalize_path(slot.sample_path)
      end

      for item_idx = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(tr, item_idx)
        if item then
          local item_time = r.GetMediaItemInfo_Value(item, "D_POSITION")
          local item_qn = time_to_qn(item_time)
          if item_qn then
            local col = math.floor(((item_qn - start_qn) / step_qn) + 0.5)
            if col >= 0 and col < step_count then
              occupied_any[idx][col] = true
              if not expected_path then
                occupied_match[idx][col] = true
              else
                local take = r.GetActiveTake(item)
                local src = take and r.GetMediaItemTake_Source(take) or nil
                if src and r.GetMediaSourceFileName then
                  local _, src_path = r.GetMediaSourceFileName(src, "")
                  if src_path and normalize_path(src_path) == expected_path then
                    occupied_match[idx][col] = true
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  return occupied_any, occupied_match
end

local function remove_seq_items_in_cell(slot, start_qn, step_qn, col)
  local tr = get_seq_slot_target_track(slot)
  if not tr then
    return 0
  end

  local removed = 0

  for item_idx = r.CountTrackMediaItems(tr) - 1, 0, -1 do
    local item = r.GetTrackMediaItem(tr, item_idx)
    if item then
      local item_time = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_qn = time_to_qn(item_time)
      if item_qn then
        local item_col = math.floor(((item_qn - start_qn) / step_qn) + 0.5)
        if item_col == col then
          if r.DeleteTrackMediaItem(tr, item) then
            removed = removed + 1
          end
        end
      end
    end
  end

  if removed > 0 then
    r.UpdateArrange()
  end
  return removed
end

SEQ_EXT_FLAG = "P_EXT:SampleMapSeq"
SEQ_EXT_REGION = "P_EXT:SampleMapSeqRegion"
SEQ_EXT_PATTERN = "P_EXT:SampleMapSeqPattern"
SEQ_EXT_TRACK = "P_EXT:SampleMapSeqTrack"
SEQ_EXT_STEP = "P_EXT:SampleMapSeqStep"

local function get_item_ext(item, key)
  if not item or not r.GetSetMediaItemInfo_String then
    return nil
  end
  local ok, value = r.GetSetMediaItemInfo_String(item, key, "", false)
  if ok then
    return value
  end
  return nil
end

local function set_item_ext(item, key, value)
  if item and r.GetSetMediaItemInfo_String then
    r.GetSetMediaItemInfo_String(item, key, tostring(value or ""), true)
  end
end

local function begin_seq_undo(label)
  if r.Undo_BeginBlock2 then
    r.Undo_BeginBlock2(0)
  elseif r.Undo_BeginBlock then
    r.Undo_BeginBlock()
  end
  return label or "Sample Map Sequencer edit"
end

local function end_seq_undo(label)
  if r.Undo_EndBlock2 then
    r.Undo_EndBlock2(0, label or "Sample Map Sequencer edit", -1)
  elseif r.Undo_EndBlock then
    r.Undo_EndBlock(label or "Sample Map Sequencer edit", -1)
  end
end

local function alloc_seq_pattern()
  local id = state.seq_pattern_next_id
  state.seq_pattern_next_id = state.seq_pattern_next_id + 1
  state.seq_patterns[tostring(id)] = state.seq_patterns[tostring(id)] or { notes = {} }
  return id
end

local function alloc_seq_pool()
  local id = state.seq_pool_next_id
  state.seq_pool_next_id = state.seq_pool_next_id + 1
  return id
end

local function get_seq_pattern(pattern_id, create)
  if not pattern_id then
    return nil
  end
  local key = tostring(pattern_id)
  if not state.seq_patterns[key] and create then
    state.seq_patterns[key] = { notes = {} }
  end
  local pattern = state.seq_patterns[key]
  if pattern and type(pattern.notes) ~= "table" then
    pattern.notes = {}
  end
  return pattern
end

local function get_seq_region_by_id(region_id)
  if not region_id then
    return nil
  end
  for _, region in ipairs(state.seq_regions) do
    if region.id == region_id then
      return region
    end
  end
  return nil
end

local function get_seq_region_length_qn(region)
  if not region then
    return 16.0
  end
  local bars = math.max(1, math.floor(region.length_bars or 4))
  if r.TimeMap_GetMeasureInfo and r.TimeMap2_timeToBeats then
    local start_time = qn_to_time(region.start_qn or 0.0)
    if start_time then
      local _, measure = r.TimeMap2_timeToBeats(0, start_time)
      if measure then
        local _, qn_start = r.TimeMap_GetMeasureInfo(0, measure)
        local _, qn_end = r.TimeMap_GetMeasureInfo(0, measure + bars)
        if qn_start and qn_end and qn_end > qn_start then
          return qn_end - qn_start
        end
      end
    end
  end
  return bars * 4.0
end

local function snap_seq_length_qn(length_qn, step_qn)
  step_qn = step_qn or state.seq_grid_qn or 0.25
  local steps = math.max(1, math.floor(((length_qn or step_qn) / step_qn) + 0.5))
  return steps * step_qn
end

local function seq_region_pool_color(pool_id, alpha)
  local palette = {
    {0x4A, 0x8B, 0xD6},
    {0x7D, 0xD6, 0x70},
    {0xD6, 0xA4, 0x4A},
    {0xC7, 0x6D, 0xD6},
    {0x4A, 0xD6, 0xC1},
    {0xD6, 0x6D, 0x6D},
  }
  local idx = ((math.floor(pool_id or 1) - 1) % #palette) + 1
  local rgb = palette[idx]
  return build_color_rrgbbaa(rgb[1], rgb[2], rgb[3], alpha or 160)
end

local function seq_region_overlaps(start_qn, length_qn, ignore_region_id)
  local end_qn = start_qn + length_qn
  for _, reg in ipairs(state.seq_regions) do
    if reg.id ~= ignore_region_id then
      local reg_start = reg.start_qn or 0.0
      local reg_end = reg_start + get_seq_region_length_qn(reg)
      if start_qn < reg_end - 0.000001 and end_qn > reg_start + 0.000001 then
        return true
      end
    end
  end
  return false
end

local function find_non_overlapping_region_start(preferred_start_qn, length_qn, ignore_region_id)
  local start_qn = math.max(0.0, preferred_start_qn or 0.0)
  local guard = 0
  while seq_region_overlaps(start_qn, length_qn, ignore_region_id) and guard < 256 do
    local next_start = nil
    local end_qn = start_qn + length_qn
    for _, reg in ipairs(state.seq_regions) do
      if reg.id ~= ignore_region_id then
        local reg_start = reg.start_qn or 0.0
        local reg_end = reg_start + get_seq_region_length_qn(reg)
        if start_qn < reg_end - 0.000001 and end_qn > reg_start + 0.000001 then
          if not next_start or reg_end > next_start then
            next_start = reg_end
          end
        end
      end
    end
    if not next_start or next_start <= start_qn then
      start_qn = start_qn + length_qn
    else
      start_qn = next_start
    end
    guard = guard + 1
  end
  return start_qn
end

local function find_prev_non_overlapping_region_start(preferred_start_qn, length_qn, ignore_region_id)
  local start_qn = math.max(0.0, preferred_start_qn or 0.0)
  local guard = 0
  while seq_region_overlaps(start_qn, length_qn, ignore_region_id) and guard < 256 do
    local prev_start = nil
    local end_qn = start_qn + length_qn
    for _, reg in ipairs(state.seq_regions) do
      if reg.id ~= ignore_region_id then
        local reg_start = reg.start_qn or 0.0
        local reg_end = reg_start + get_seq_region_length_qn(reg)
        if start_qn < reg_end - 0.000001 and end_qn > reg_start + 0.000001 then
          local candidate = reg_start - length_qn
          if candidate >= 0 and (not prev_start or candidate < prev_start) then
            prev_start = candidate
          end
        end
      end
    end
    if prev_start == nil then
      return find_non_overlapping_region_start(preferred_start_qn, length_qn, ignore_region_id)
    end
    start_qn = math.max(0.0, prev_start)
    guard = guard + 1
  end
  return start_qn
end

local function sort_seq_regions()
  table.sort(state.seq_regions, function(a, b) return (a.start_qn or 0) < (b.start_qn or 0) end)
end

local function ensure_default_seq_region()
  if #state.seq_regions > 0 then
    if not get_seq_region_by_id(state.selected_seq_region_id) then
      state.selected_seq_region_id = state.seq_regions[1].id
    end
    return state.seq_regions[1]
  end

  local arrange_start, arrange_end = get_arrange_view_range()
  local start_qn = time_to_qn(arrange_start) or 0.0
  local pattern_id = alloc_seq_pattern()
  local temp_region = { start_qn = start_qn, length_bars = 4 }
  start_qn = find_non_overlapping_region_start(start_qn, get_seq_region_length_qn(temp_region), nil)
  local region = {
    id = state.seq_region_next_id,
    name = "Region 1",
    start_qn = start_qn,
    length_bars = 4,
    pool_id = alloc_seq_pool(),
    pattern_id = pattern_id,
  }
  state.seq_region_next_id = state.seq_region_next_id + 1
  table.insert(state.seq_regions, region)
  state.selected_seq_region_id = region.id
  state.seq_view_start_qn = start_qn
  local span_qn = math.max(get_project_grid_step_qn(), (time_to_qn(arrange_end) or (start_qn + 16.0)) - start_qn)
  state.seq_view_span_qn = span_qn
  save_config()
  return region
end

local function get_selected_seq_region()
  ensure_default_seq_region()
  return get_seq_region_by_id(state.selected_seq_region_id) or state.seq_regions[1]
end

local function get_track_note_table(pattern, track_id, create)
  if not pattern then
    return nil
  end
  pattern.notes = pattern.notes or {}
  local key = tostring(track_id)
  if not pattern.notes[key] and create then
    pattern.notes[key] = {}
  end
  return pattern.notes[key]
end

function seq_new_seed()
  local t = (r.time_precise and r.time_precise()) or os.clock()
  return math.floor(t * 1000000 + math.random(0, 1000000)) % 2147483647
end

function get_seq_track_settings(pattern, track_id, create)
  if not pattern then
    return nil
  end
  pattern.track_settings = pattern.track_settings or {}
  local key = tostring(track_id)
  if not pattern.track_settings[key] and create then
    pattern.track_settings[key] = {
      probability = 1.0,
      humanize_ms = 0.0,
      probability_seed = seq_new_seed(),
      humanize_seed = seq_new_seed(),
    }
  end
  local settings = pattern.track_settings[key]
  if settings then
    if type(settings.probability) ~= "number" then
      settings.probability = 1.0
    end
    if type(settings.humanize_ms) ~= "number" then
      settings.humanize_ms = 0.0
    end
    if type(settings.probability_seed) ~= "number" then
      settings.probability_seed = settings.seed or seq_new_seed()
    end
    if type(settings.humanize_seed) ~= "number" then
      settings.humanize_seed = settings.seed or settings.probability_seed or seq_new_seed()
    end
  end
  return settings
end

SEQ_GEN_STYLE_ORDER = {
  { header = "Genres" },
  { key = "house", label = "House" },
  { key = "techno", label = "Techno" },
  { key = "disco", label = "Disco" },
  { key = "basic", label = "Pop Backbeat" },
  { key = "rock", label = "Rock" },
  { key = "hiphop", label = "Boom Bap" },
  { key = "trap", label = "Trap" },
  { key = "funk", label = "Funk" },
  { key = "dnb", label = "Drum & Bass" },
  { key = "breakbeat", label = "Breakbeat" },
  { key = "reggaeton", label = "Reggaeton" },
  { key = "afrobeat", label = "Afrobeat" },
  { header = "Abstract" },
  { key = "dust_motes", label = "Dust Motes" },
  { key = "glass_steps", label = "Glass Steps" },
  { key = "crooked_neon", label = "Crooked Neon" },
  { key = "soft_alarm", label = "Soft Alarm" },
  { key = "tiny_machines", label = "Tiny Machines" },
  { key = "low_gravity", label = "Low Gravity" },
  { key = "ritual_drift", label = "Ritual Drift" },
  { key = "broken_lantern", label = "Broken Lantern" },
  { key = "afterimage", label = "Afterimage" },
  { key = "rain_on_plastic", label = "Rain On Plastic" },
  { key = "velvet_push", label = "Velvet Push" },
  { key = "static_bloom", label = "Static Bloom" },
}

-- Each preset declares its own palette of sample-type roles. Picking a preset
-- auto-adds any missing track types it needs (see ensure_seq_tracks_for_roles).
SEQ_GEN_TEMPLATES = {
  -- Four-on-the-floor; clap doubles beats 2 & 4; open hats on the offbeats.
  house = {
    kick = {0, 4, 8, 12},
    clap = {4, 12},
    hat = {2, 6, 10, 14},
    bass = {2, 6, 10, 14},
  },
  -- Driving 4/4; offbeat open hats; syncopated perc stabs.
  techno = {
    kick = {0, 4, 8, 12},
    hat = {2, 6, 10, 14},
    clap = {12},
    perc = {3, 11},
  },
  -- Disco: four-on-the-floor with steady 8th hats and offbeat open ride.
  disco = {
    kick = {0, 4, 8, 12},
    snare = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
    ride = {2, 6, 10, 14},
  },
  -- Straight pop backbeat; clap layered on the snare.
  basic = {
    kick = {0, 8},
    snare = {4, 12},
    clap = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
  },
  -- Rock: kick on 1 and the & of 3, backbeat snare, crash on the downbeat.
  rock = {
    kick = {0, 8, 10},
    snare = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
    crash = {0},
  },
  -- Boom bap: kick on 1 and the & of 2, classic backbeat, swung 8th hats.
  hiphop = {
    kick = {0, 6, 10},
    snare = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
  },
  -- Trap: half-time snare on beat 3, syncopated 808/kick, rapid 16th hats.
  trap = {
    kick = {0, 7, 10},
    snare = {8},
    hat = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    ["808"] = {0, 7, 10},
  },
  -- Funk: syncopated kick, backbeat snare, 16th hats, perc ghost on the &-a.
  funk = {
    kick = {0, 3, 10},
    snare = {4, 12},
    hat = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    perc = {7, 14},
  },
  -- Drum & bass two-step: kick on 1 and the & of 3, snare backbeat, sub on kicks.
  dnb = {
    kick = {0, 10},
    snare = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
    bass = {0, 10},
  },
  -- Breakbeat: amen-style kick/snare interplay with a perc tail.
  breakbeat = {
    kick = {0, 10},
    snare = {4, 12},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
    perc = {7, 15},
  },
  -- Reggaeton dembow: kick on 1 & 3, rimshot on the boom-ch-boom-chick.
  reggaeton = {
    kick = {0, 8},
    rim = {3, 6, 11, 14},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
  },
  -- Afrobeat: son-clave (3-2) rimshot, rolling perc, lilting kick.
  afrobeat = {
    kick = {0, 6, 10},
    rim = {0, 3, 6, 10, 12},
    perc = {2, 5, 8, 11, 14},
    hat = {0, 2, 4, 6, 8, 10, 12, 14},
  },
  dust_motes = {
    kick = {0, 10},
    rim = {4, 12},
    perc = {3, 7, 11, 13},
    vocal = {2, 10},
  },
  glass_steps = {
    kick = {0, 6, 11},
    snare = {4, 12},
    hat = {1, 3, 5, 7, 9, 11, 13, 15},
    perc = {6, 10, 14},
    fx = {0},
  },
  crooked_neon = {
    ["808"] = {0, 5, 10, 14},
    clap = {4, 11},
    hat = {0, 2, 5, 7, 8, 10, 13, 15},
    perc = {3, 9, 12},
  },
  soft_alarm = {
    kick = {0, 9},
    snare = {4, 12},
    hat = {2, 6, 10, 14},
    fx = {8, 15},
  },
  tiny_machines = {
    kick = {0, 4, 9, 12},
    rim = {6, 14},
    perc = {2, 5, 10, 13},
    hat = {0, 1, 3, 4, 6, 8, 9, 11, 12, 14},
  },
  low_gravity = {
    kick = {0, 11},
    snare = {6, 13},
    bass = {0, 8},
    ride = {0, 4, 8, 12},
  },
  ritual_drift = {
    kick = {0, 7, 12},
    tom = {5, 13},
    perc = {2, 4, 6, 10, 12, 14},
    vocal = {1, 8, 15},
  },
  broken_lantern = {
    kick = {0, 3, 10},
    snare = {4, 12, 15},
    hat = {1, 4, 6, 9, 11, 14},
    fx = {0},
    perc = {2, 7, 13},
  },
  afterimage = {
    kick = {0, 8, 15},
    clap = {4, 12},
    hat = {2, 3, 6, 7, 10, 11, 14, 15},
    ride = {0, 4, 8, 12},
    fx = {15},
  },
  rain_on_plastic = {
    kick = {0, 6, 12},
    rim = {4, 10},
    hat = {0, 2, 3, 5, 7, 8, 10, 12, 13, 15},
    perc = {1, 6, 11, 14},
    vocal = {3, 11},
  },
  velvet_push = {
    kick = {0, 8, 10},
    snare = {4, 12},
    hat = {2, 6, 9, 10, 14},
    bass = {0, 8},
    clap = {12},
  },
  static_bloom = {
    ["808"] = {0, 4, 10},
    snare = {7, 12},
    hat = {1, 2, 4, 5, 7, 8, 10, 11, 13, 14},
    perc = {3, 6, 9, 15},
    fx = {0, 8},
  },
}

-- Per-preset groove. swing delays odd 16th positions (fraction of a 16th note)
-- to push the pattern off the grid and into a more human pocket.
SEQ_GEN_GROOVE = {
  house      = { swing = 0.0 },
  techno     = { swing = 0.0 },
  disco      = { swing = 0.04 },
  basic      = { swing = 0.04 },
  rock       = { swing = 0.0 },
  hiphop     = { swing = 0.16 },
  trap       = { swing = 0.0 },
  funk       = { swing = 0.10 },
  dnb        = { swing = 0.0 },
  breakbeat  = { swing = 0.08 },
  reggaeton  = { swing = 0.0 },
  afrobeat   = { swing = 0.06 },
}

-- Canonical ordering for deterministic track creation.
SEQ_ROLE_ORDER = { "kick", "808", "bass", "snare", "clap", "rim", "tom", "hat", "ride", "crash", "perc", "fx", "vocal" }

SEQ_ROLE_LABELS = {
  kick = "Kick", ["808"] = "808", bass = "Bass", snare = "Snare", clap = "Clap",
  rim = "Rim", tom = "Tom", hat = "Hat", ride = "Ride", crash = "Crash",
  perc = "Perc", fx = "FX", vocal = "Vocal",
}

-- Candidate library tags to search when auto-assigning a sample to a role track.
-- First entry is the primary tag stamped on the slot (drives role detection).
SEQ_ROLE_TAG_CANDIDATES = {
  kick  = { "kick" },
  ["808"] = { "808", "kick", "bass" },
  bass  = { "bass", "808" },
  snare = { "snare" },
  clap  = { "clap", "snap" },
  rim   = { "rim", "snap", "clap" },
  tom   = { "tom", "perc" },
  hat   = { "hat" },
  ride  = { "ride", "hat" },
  crash = { "crash", "hat" },
  perc  = { "perc", "rim", "tom" },
  fx    = { "fx" },
  vocal = { "vocal" },
}

-- Group roles into rhythmic families that drive the randomizer behavior.
function seq_role_family(role)
  if role == "kick" or role == "808" or role == "bass" then
    return "kick"
  elseif role == "snare" or role == "clap" or role == "rim" then
    return "backbeat"
  elseif role == "hat" or role == "ride" then
    return "hat"
  end
  return "perc"
end

-- Baseline groove offset (in QN) so hits sit in the pocket rather than dead on
-- the grid: per-preset swing on odd 16ths, a small family lay-back, and a tiny
-- stable humanize. pos16 is the step position within the bar at 16th resolution.
function seq_pattern_base_offset(role, pos16, style_key, grid_qn)
  local groove = SEQ_GEN_GROOVE[style_key]
  local swing = (groove and groove.swing) or 0.0
  local sixteenth_qn = 0.25
  local off = 0.0

  -- Swing pushes the "e" and "a" (odd 16th positions) later.
  if (pos16 % 2) == 1 then
    off = off + swing * sixteenth_qn
  end

  -- Family lay-back: backbeat sits furthest behind, hats just a hair late.
  local fam = seq_role_family(role)
  if fam == "backbeat" then
    off = off + 0.015
  elseif fam == "hat" then
    off = off + 0.006
  elseif fam == "perc" then
    off = off + 0.010
  end

  -- Tiny deterministic humanize so repeated steps aren't identical.
  off = off + (seq_pattern_rand(pos16 * 13.7 + 3.0) - 0.5) * 0.008
  return off
end

function seq_gen_style_exists(style_key)
  if type(style_key) ~= "string" then
    return false
  end
  return SEQ_GEN_TEMPLATES[style_key] ~= nil
end

function normalize_seq_gen_style(style_key)
  if seq_gen_style_exists(style_key) then
    return style_key
  end
  return "basic"
end

function get_seq_gen_style_label(style_key)
  style_key = normalize_seq_gen_style(style_key)
  for _, style in ipairs(SEQ_GEN_STYLE_ORDER) do
    if style.key and style.key == style_key then
      return style.label
    end
  end
  return "Basic"
end

function classify_seq_role_text(text)
  local s = tostring(text or ""):lower()
  if s == "" then
    return nil
  end
  if s:find("kick", 1, true) or s:find("kck", 1, true) then
    return "kick"
  end
  if s:find("snare", 1, true) or s:find("snr", 1, true) then
    return "snare"
  end
  if s:find("clap", 1, true) then
    return "clap"
  end
  if s:find("rim", 1, true) or s:find("snap", 1, true) then
    return "rim"
  end
  if s:find("tom", 1, true) then
    return "tom"
  end
  if s:find("ride", 1, true) then
    return "ride"
  end
  if s:find("crash", 1, true) or s:find("cymbal", 1, true) then
    return "crash"
  end
  if s:find("hihat", 1, true) or s:find("hi hat", 1, true) or s:find("hat", 1, true)
      or s:find("hh", 1, true) then
    return "hat"
  end
  if s:find("808", 1, true) then
    return "808"
  end
  if s:find("sub", 1, true) or s:find("bass", 1, true) then
    return "bass"
  end
  if s:find("perc", 1, true) or s:find("percussion", 1, true) or s:find("shaker", 1, true)
      or s:find("tamb", 1, true) or s:find("cowbell", 1, true) then
    return "perc"
  end
  if s:find("riser", 1, true) or s:find("impact", 1, true) or s:find("sweep", 1, true)
      or s:find("whoosh", 1, true) or s:find("sfx", 1, true) or s:find("fx", 1, true) then
    return "fx"
  end
  if s:find("vocal", 1, true) or s:find("vox", 1, true) or s:find("voice", 1, true) then
    return "vocal"
  end
  return nil
end

function infer_seq_track_role(slot)
  if not slot then
    return "other"
  end

  local role = classify_seq_role_text(slot.sample_tag)
  if role then
    return role
  end

  local sample = slot.sample_path and find_sample_by_path(slot.sample_path) or nil
  if sample and type(sample.tags) == "table" then
    for _, tag in ipairs(sample.tags) do
      role = classify_seq_role_text(tag)
      if role then
        return role
      end
    end
  end

  role = classify_seq_role_text(sample and sample.name)
      or classify_seq_role_text(sample and sample.path)
      or classify_seq_role_text(slot.sample_name)
      or classify_seq_role_text(slot.name)

  return role or "other"
end

function seq_random_control_alpha(active_key, control_key)
  if active_key and active_key ~= "" then
    if active_key == control_key then
      return 128
    end
    return 38
  end
  return 170
end

function seq_random_knob_control(id, dl, x, y, size, value, min_v, max_v, alpha)
  size = math.max(18.0, size or 24.0)
  min_v = min_v or 0.0
  max_v = max_v or 1.0
  if max_v <= min_v then
    max_v = min_v + 1.0
  end

  value = math.max(min_v, math.min(max_v, value or min_v))
  r.ImGui_SetCursorScreenPos(ctx, x, y)
  r.ImGui_InvisibleButton(ctx, id, size, size)
  local active = r.ImGui_IsItemActive(ctx)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local changed = false

  if active then
    local _, my = r.ImGui_GetMousePos(ctx)
    my = my or 0.0
    if (not state.seq_random_knob_drag) or state.seq_random_knob_drag.id ~= id then
      state.seq_random_knob_drag = { id = id, start_value = value, start_my = my }
    end
    local sensitivity = (max_v - min_v) / 160.0
    local start_my = state.seq_random_knob_drag.start_my or my
    local drag_y = my - start_my
    local new_value = (state.seq_random_knob_drag.start_value or value) - drag_y * sensitivity
    new_value = math.max(min_v, math.min(max_v, new_value))
    if math.abs(new_value - value) > 1e-9 then
      value = new_value
      changed = true
    end
  elseif state.seq_random_knob_drag and state.seq_random_knob_drag.id == id then
    state.seq_random_knob_drag = nil
  end

  local cx = x + size * 0.5
  local cy = y + size * 0.5
  local radius = size * 0.5 - 1.5
  local bg = build_color_rrgbbaa(33, 40, 54, alpha)
  local ring = build_color_rrgbbaa(120, 145, 176, math.min(255, alpha + 35))
  local tip = build_color_rrgbbaa(255, 221, 132, math.min(255, alpha + 70))
  local hover_ring = build_color_rrgbbaa(255, 255, 255, math.min(255, alpha + 40))

  r.ImGui_DrawList_AddCircleFilled(dl, cx, cy, radius, bg, 24)
  r.ImGui_DrawList_AddCircle(dl, cx, cy, radius, ring, 24, 1.4)
  if hovered or active then
    r.ImGui_DrawList_AddCircle(dl, cx, cy, radius + 1.5, hover_ring, 24, 1.0)
  end

  local t = (value - min_v) / (max_v - min_v)
  local angle = (-math.pi * 0.75) + t * (math.pi * 1.5)
  local tip_r = radius - 4.0
  local tx = cx + math.cos(angle) * tip_r
  local ty = cy + math.sin(angle) * tip_r
  r.ImGui_DrawList_AddLine(dl, cx, cy, tx, ty, tip, 2.2)

  return changed, value, active
end

function seq_random_seed_button(id, dl, x, y, w, h, alpha)
  w = math.max(14.0, w or 16.0)
  h = math.max(12.0, h or 14.0)
  r.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = r.ImGui_InvisibleButton(ctx, id, w, h)
  local hovered = r.ImGui_IsItemHovered(ctx)

  local bg = build_color_rrgbbaa(28, 34, 45, alpha)
  local edge = build_color_rrgbbaa(114, 138, 172, math.min(255, alpha + 35))
  if hovered then
    edge = build_color_rrgbbaa(220, 230, 255, math.min(255, alpha + 35))
  end

  r.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, 3.0)
  r.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, edge, 3.0, 0, 1.0)

  local pip = build_color_rrgbbaa(235, 235, 235, math.min(255, alpha + 60))
  local px0 = x + w * 0.28
  local px1 = x + w * 0.72
  local py0 = y + h * 0.30
  local py1 = y + h * 0.70
  r.ImGui_DrawList_AddCircleFilled(dl, px0, py0, 1.2, pip, 8)
  r.ImGui_DrawList_AddCircleFilled(dl, px1, py0, 1.2, pip, 8)
  r.ImGui_DrawList_AddCircleFilled(dl, (px0 + px1) * 0.5, (py0 + py1) * 0.5, 1.2, pip, 8)
  r.ImGui_DrawList_AddCircleFilled(dl, px0, py1, 1.2, pip, 8)
  r.ImGui_DrawList_AddCircleFilled(dl, px1, py1, 1.2, pip, 8)

  return clicked
end

function seq_get_lane_random_layout(row_pos, timeline_x0)
  local lane_h = row_pos.y1 - row_pos.y0
  local knob_size = math.max(20.0, math.min(30.0, lane_h - 16.0))
  local seed_h = math.max(11.0, math.floor(knob_size * 0.46))
  local seed_w = math.max(13.0, math.floor(knob_size * 0.55))
  local knob_y = row_pos.y0 + 2.0
  local seed_y = knob_y + knob_size + 1.0
  local knob_x0 = timeline_x0 + 8.0
  local knob_gap = knob_size + 12.0
  local prob_x = knob_x0
  local human_x = knob_x0 + knob_gap
  return {
    knob_size = knob_size,
    seed_h = seed_h,
    seed_w = seed_w,
    knob_y = knob_y,
    seed_y = seed_y,
    prob_x = prob_x,
    human_x = human_x,
  }
end

function seq_lane_random_controls_hit(row_pos, mx, my, timeline_x0)
  local ui = seq_get_lane_random_layout(row_pos, timeline_x0)
  local pad = 2.0
  local function in_rect(x0, y0, x1, y1)
    return mx >= x0 and mx <= x1 and my >= y0 and my <= y1
  end
  local prob_seed_x = ui.prob_x + (ui.knob_size - ui.seed_w) * 0.5
  local human_seed_x = ui.human_x + (ui.knob_size - ui.seed_w) * 0.5
  return in_rect(ui.prob_x - pad, ui.knob_y - pad, ui.prob_x + ui.knob_size + pad, ui.knob_y + ui.knob_size + pad)
    or in_rect(ui.human_x - pad, ui.knob_y - pad, ui.human_x + ui.knob_size + pad, ui.knob_y + ui.knob_size + pad)
    or in_rect(prob_seed_x - pad, ui.seed_y - pad, prob_seed_x + ui.seed_w + pad, ui.seed_y + ui.seed_h + pad)
    or in_rect(human_seed_x - pad, ui.seed_y - pad, human_seed_x + ui.seed_w + pad, ui.seed_y + ui.seed_h + pad)
end

function seq_render_lane_random_controls(dl, row_pos, slot_id, random_settings, focus_key, timeline_x0)
  local ui = seq_get_lane_random_layout(row_pos, timeline_x0)
  local knob_size = ui.knob_size
  local seed_h = ui.seed_h
  local seed_w = ui.seed_w
  local knob_y = ui.knob_y
  local seed_y = ui.seed_y
  local prob_x = ui.prob_x
  local human_x = ui.human_x
  local prob_key = "rand_prob_" .. slot_id
  local human_key = "rand_human_" .. slot_id
  local changed = false
  local active_key = nil
  local overlay_text = nil

  local prob_alpha = seq_random_control_alpha(focus_key, prob_key)
  local human_alpha = seq_random_control_alpha(focus_key, human_key)
  local prob_changed, prob_value, prob_active = seq_random_knob_control(
    "##seq_lane_prob_knob_" .. slot_id,
    dl,
    prob_x,
    knob_y,
    knob_size,
    random_settings.probability or 1.0,
    0.0,
    1.0,
    prob_alpha
  )
  if prob_changed then
    random_settings.probability = prob_value
    changed = true
  end
  if prob_active then
    active_key = prob_key
    overlay_text = string.format("Prob %.2f", random_settings.probability or 1.0)
  end
  if seq_random_seed_button("##seq_lane_prob_seed_" .. slot_id, dl, prob_x + (knob_size - seed_w) * 0.5, seed_y, seed_w, seed_h, prob_alpha) then
    random_settings.probability_seed = seq_new_seed()
    changed = true
  end

  local human_changed, human_value, human_active = seq_random_knob_control(
    "##seq_lane_human_knob_" .. slot_id,
    dl,
    human_x,
    knob_y,
    knob_size,
    random_settings.humanize_ms or 0.0,
    0.0,
    50.0,
    human_alpha
  )
  if human_changed then
    random_settings.humanize_ms = human_value
    changed = true
  end
  if human_active then
    active_key = human_key
    overlay_text = string.format("Human %.1f ms", random_settings.humanize_ms or 0.0)
  end
  if seq_random_seed_button("##seq_lane_human_seed_" .. slot_id, dl, human_x + (knob_size - seed_w) * 0.5, seed_y, seed_w, seed_h, human_alpha) then
    random_settings.humanize_seed = seq_new_seed()
    changed = true
  end

  return changed, active_key, overlay_text
end

local function get_seq_note(region, track_id, step_key)
  local pattern = region and get_seq_pattern(region.pattern_id, false)
  local notes = get_track_note_table(pattern, track_id, false)
  return notes and notes[tostring(step_key)] or nil
end

local function set_seq_note(region, track_id, step_key, note)
  local pattern = region and get_seq_pattern(region.pattern_id, true)
  local notes = get_track_note_table(pattern, track_id, true)
  notes[tostring(step_key)] = note
end

local function delete_seq_note(region, track_id, step_key)
  local pattern = region and get_seq_pattern(region.pattern_id, false)
  local notes = get_track_note_table(pattern, track_id, false)
  if notes then
    notes[tostring(step_key)] = nil
  end
end

local function clone_table_deep(src)
  if type(src) ~= "table" then
    return src
  end
  local out = {}
  for k, v in pairs(src) do
    out[k] = clone_table_deep(v)
  end
  return out
end

local function seq_item_is_owned(item, region_id)
  if get_item_ext(item, SEQ_EXT_FLAG) ~= "1" then
    return false
  end
  if region_id and tonumber(get_item_ext(item, SEQ_EXT_REGION) or "") ~= region_id then
    return false
  end
  return true
end

local function remove_seq_rendered_items(region)
  local removed = 0
  local region_id = region and region.id or nil
  local tr_count = r.CountTracks(0)
  for tr_idx = 0, tr_count - 1 do
    local tr = r.GetTrack(0, tr_idx)
    for item_idx = r.CountTrackMediaItems(tr) - 1, 0, -1 do
      local item = r.GetTrackMediaItem(tr, item_idx)
      if item and seq_item_is_owned(item, region_id) then
        if r.DeleteTrackMediaItem(tr, item) then
          removed = removed + 1
        end
      end
    end
  end
  return removed
end

local function seq_stutter_count(note)
  return math.max(1, math.floor((note and note.stutter or 1) + 0.5))
end

local function apply_seq_note_params(item, take, note)
  if item then
    r.SetMediaItemInfo_Value(item, "D_VOL", note.volume or 1.0)
  end
  if take then
    r.SetMediaItemTakeInfo_Value(take, "D_VOL", note.volume or 1.0)
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", note.pan or 0.0)
    r.SetMediaItemTakeInfo_Value(take, "D_PITCH", note.pitch or 0.0)
  end
end

local function insert_seq_note_hit(tr, region, track_id, step_key, note, resolved_path, hit_start_qn, hit_length_qn, humanize_ms, random_seed)
  local start_time = qn_to_time(hit_start_qn)
  local end_time = qn_to_time(hit_start_qn + hit_length_qn)
  if not start_time or not end_time or end_time <= start_time then
    return nil
  end

  if humanize_ms > 0.0 then
    local seed = random_seed + (region.id or 1) * 2654435761 + (tonumber(track_id) or 1) * 1013904223 + (tonumber(step_key) or 1) * 374761393
    local centered = ((math.abs(math.sin(seed) * 10000.0) % 1.0) * 2.0) - 1.0
    start_time = math.max(0.0, start_time + centered * (humanize_ms / 1000.0))
  end

  local item = r.AddMediaItemToTrack(tr)
  if not item then
    return nil
  end
  r.SetMediaItemPosition(item, start_time, false)
  r.SetMediaItemLength(item, end_time - start_time, false)

  local take = r.AddTakeToMediaItem(item)
  if take then
    local src = r.PCM_Source_CreateFromFile(resolved_path)
    if src then
      r.SetMediaItemTake_Source(take, src)
      set_item_name(item, take, resolved_path)
      apply_seq_note_params(item, take, note)
    end
  end

  set_item_ext(item, SEQ_EXT_FLAG, "1")
  set_item_ext(item, SEQ_EXT_REGION, region.id)
  set_item_ext(item, SEQ_EXT_PATTERN, region.pattern_id)
  set_item_ext(item, SEQ_EXT_TRACK, track_id)
  set_item_ext(item, SEQ_EXT_STEP, step_key)
  rebuild_peaks_for_item(item)
  return item
end

local function insert_seq_note_item(region, slot, track_id, step_key, note)
  if not region or not slot or not note then
    return nil
  end

  local resolved_path, resolved_sample = resolve_seq_note_sample(note, slot)
  if not resolved_path then
    return nil
  end
  if not r.file_exists(resolved_path) then
    log("Sequencer sample missing: " .. tostring(resolved_path))
    return nil
  end

  local tr = get_seq_slot_target_track(slot)
  if not tr then
    log("No target track for sequencer note")
    return nil
  end

  local pattern = get_seq_pattern(region.pattern_id, false)
  local track_settings = get_seq_track_settings(pattern, track_id, false) or {}
  local probability = track_settings.probability or 1.0
  local probability_seed = track_settings.probability_seed or track_settings.seed or 0
  local humanize_seed = track_settings.humanize_seed or track_settings.seed or 0
  if probability < 1.0 then
    local seed = probability_seed + (region.id or 1) * 73856093 + (tonumber(track_id) or 1) * 19349663 + (tonumber(step_key) or 1) * 83492791
    local pseudo = math.abs(math.sin(seed) * 10000.0) % 1.0
    if pseudo > probability then
      return nil
    end
  end

  local grid_qn = state.seq_grid_qn or 0.25
  local stutter_count = seq_stutter_count(note)
  local step_idx = tonumber(step_key) or 0
  local cell_start_qn = (region.start_qn or 0.0) + step_idx * grid_qn
  local slice_qn = grid_qn / stutter_count
  local note_len_qn = snap_seq_length_qn(note.length_qn or grid_qn, grid_qn)
  local hit_len_qn = note_len_qn
  if stutter_count > 1 then
    hit_len_qn = math.min(note_len_qn, slice_qn * 0.98)
  end
  local offset_qn = note.offset_qn or 0.0
  local humanize_ms = track_settings.humanize_ms or 0.0

  local first_item = nil
  for i = 0, stutter_count - 1 do
    local hit_start_qn = cell_start_qn + offset_qn + i * slice_qn
    local item = insert_seq_note_hit(
      tr, region, track_id, step_key, note, resolved_path,
      hit_start_qn, hit_len_qn,
      (i == 0) and humanize_ms or 0.0,
      humanize_seed
    )
    if item and not first_item then
      first_item = item
    end
  end
  return first_item
end

local function sync_seq_region(region)
  if not region then
    return
  end
  clear_seq_vary_rank_cache()
  remove_seq_rendered_items(region)

  local pattern = get_seq_pattern(region.pattern_id, false)
  if not pattern or type(pattern.notes) ~= "table" then
    r.UpdateArrange()
    return
  end

  for _, slot in ipairs(state.seq_tracks) do
    local track_notes = get_track_note_table(pattern, slot.id, false)
    if track_notes then
      for step_key, note in pairs(track_notes) do
        if type(note) == "table" and note.enabled ~= false then
          insert_seq_note_item(region, slot, slot.id, step_key, note)
        end
      end
    end
  end
  r.UpdateArrange()
end

function sync_seq_pattern_regions(pattern_id)
  for _, region in ipairs(state.seq_regions) do
    if region.pattern_id == pattern_id then
      sync_seq_region(region)
    end
  end
end

update_seq_track_sample_assignments = function(slot, sample_path, sample_name, persist)
  if not slot or not slot.id or not sample_path then
    return
  end

  clear_seq_vary_rank_cache()

  local touched_patterns = {}
  local track_key = tostring(slot.id)
  for pattern_id, pattern in pairs(state.seq_patterns) do
    if type(pattern) == "table" and type(pattern.notes) == "table" then
      local track_notes = pattern.notes[track_key]
      if type(track_notes) == "table" then
        local touched = false
        for _, note in pairs(track_notes) do
          if type(note) == "table" then
            note.sample_path = sample_path
            note.sample_name = sample_name or basename(sample_path)
            touched = true
          end
        end
        if touched then
          touched_patterns[tonumber(pattern_id) or pattern_id] = true
        end
      end
    end
  end

  for pattern_id, _ in pairs(touched_patterns) do
    sync_seq_pattern_regions(pattern_id)
  end

  if persist then
    save_config()
  end
end

local function sync_selected_seq_region()
  local region = get_selected_seq_region()
  if region then
    sync_seq_pattern_regions(region.pattern_id)
  end
end

local function create_seq_region(length_bars, copy_from, pooled, preferred_start_qn)
  local start_qn = 0.0
  local region_length_bars = length_bars or (copy_from and copy_from.length_bars) or 4
  if preferred_start_qn then
    start_qn = preferred_start_qn
  elseif copy_from then
    start_qn = (copy_from.start_qn or 0.0) + get_seq_region_length_qn(copy_from)
  else
    local arrange_start = select(1, get_arrange_view_range())
    start_qn = time_to_qn(arrange_start) or 0.0
  end
  start_qn = find_non_overlapping_region_start(start_qn, get_seq_region_length_qn({ start_qn = start_qn, length_bars = region_length_bars }), nil)

  local pattern_id
  local pool_id
  if copy_from and pooled then
    pattern_id = copy_from.pattern_id
    pool_id = copy_from.pool_id or alloc_seq_pool()
    copy_from.pool_id = pool_id
  else
    pattern_id = alloc_seq_pattern()
    pool_id = alloc_seq_pool()
    if copy_from then
      local src_pattern = get_seq_pattern(copy_from.pattern_id, false)
      state.seq_patterns[tostring(pattern_id)] = clone_table_deep(src_pattern or { notes = {} })
    end
  end

  local region = {
    id = state.seq_region_next_id,
    name = "Region " .. tostring(state.seq_region_next_id),
    start_qn = start_qn,
    length_bars = region_length_bars,
    pool_id = pool_id,
    pattern_id = pattern_id,
  }
  state.seq_region_next_id = state.seq_region_next_id + 1
  table.insert(state.seq_regions, region)
  table.sort(state.seq_regions, function(a, b) return (a.start_qn or 0) < (b.start_qn or 0) end)
  state.selected_seq_region_id = region.id
  save_config()
  if copy_from and pooled then
    sync_seq_pattern_regions(pattern_id)
  else
    sync_seq_region(region)
  end
  return region
end

local function unpool_selected_seq_region()
  local region = get_selected_seq_region()
  if not region then
    return
  end
  local old_pattern = get_seq_pattern(region.pattern_id, false)
  local new_pattern_id = alloc_seq_pattern()
  state.seq_patterns[tostring(new_pattern_id)] = clone_table_deep(old_pattern or { notes = {} })
  region.pattern_id = new_pattern_id
  region.pool_id = alloc_seq_pool()
  save_config()
  sync_seq_region(region)
end

local function clear_selected_seq_region()
  local region = get_selected_seq_region()
  if not region then
    return
  end
  local pattern = get_seq_pattern(region.pattern_id, true)
  pattern.notes = {}
  state.selected_seq_note = nil
  save_config()
  sync_seq_pattern_regions(region.pattern_id)
end

local function delete_selected_seq_region()
  local region = get_selected_seq_region()
  if not region then
    return
  end
  remove_seq_rendered_items(region)
  local removed_idx = nil
  for i, reg in ipairs(state.seq_regions) do
    if reg.id == region.id then
      removed_idx = i
      break
    end
  end
  if removed_idx then
    table.remove(state.seq_regions, removed_idx)
  end

  local pattern_still_used = false
  for _, reg in ipairs(state.seq_regions) do
    if reg.pattern_id == region.pattern_id then
      pattern_still_used = true
      break
    end
  end
  if not pattern_still_used then
    state.seq_patterns[tostring(region.pattern_id)] = nil
  end

  if #state.seq_regions == 0 then
    state.selected_seq_region_id = nil
    state.selected_seq_note = nil
    ensure_default_seq_region()
  else
    local next_region = state.seq_regions[math.min(removed_idx or 1, #state.seq_regions)] or state.seq_regions[1]
    state.selected_seq_region_id = next_region.id
  end
  r.UpdateArrange()
  save_config()
end

local function move_selected_seq_region(delta_qn)
  local region = get_selected_seq_region()
  if not region then
    return
  end
  local length_qn = get_seq_region_length_qn(region)
  local desired = math.max(0.0, (region.start_qn or 0.0) + delta_qn)
  local new_start
  if delta_qn < 0 then
    new_start = find_prev_non_overlapping_region_start(desired, length_qn, region.id)
  else
    new_start = find_non_overlapping_region_start(desired, length_qn, region.id)
  end
  if math.abs(new_start - (region.start_qn or 0.0)) < 0.000001 then
    return
  end
  remove_seq_rendered_items(region)
  region.start_qn = new_start
  sort_seq_regions()
  state.seq_view_start_qn = new_start
  state.seq_view_span_qn = length_qn
  save_config()
  sync_seq_region(region)
end

SEQ_REGION_EDGE_PX = 6
SEQ_LINK_ICON_SIZE = 14
SEQ_LINK_HIT_PAD = 2

function seq_snap_qn(qn, step_qn)
  step_qn = step_qn or state.seq_grid_qn or 0.25
  return math.floor((qn / step_qn) + 0.5) * step_qn
end

function seq_get_measure_end_qn(measure)
  if not r.TimeMap_GetMeasureInfo then
    return nil
  end
  local _, qn_start, qn_end, ts_num, ts_den = r.TimeMap_GetMeasureInfo(0, measure)
  if not qn_start then
    return nil
  end
  if type(qn_end) == "number" and qn_end > qn_start then
    return qn_end
  end
  local out_num = (type(ts_num) == "number" and ts_num > 0) and ts_num or 4
  local out_den = (type(ts_den) == "number" and ts_den > 0) and ts_den or 4
  return qn_start + out_num * (4.0 / out_den)
end

function seq_get_measure_start_qn(measure)
  if not r.TimeMap_GetMeasureInfo then
    return nil
  end
  local _, qn_start = r.TimeMap_GetMeasureInfo(0, measure)
  if type(qn_start) == "number" then
    return qn_start
  end
  return nil
end

function seq_snap_qn_to_measure_end(qn)
  qn = math.max(0.0, qn or 0.0)
  if not r.TimeMap_GetMeasureInfo or not r.TimeMap2_timeToBeats then
    return seq_snap_qn(qn, state.seq_grid_qn or 0.25)
  end
  local time = qn_to_time(qn)
  if not time then
    return qn
  end
  local _, measure = r.TimeMap2_timeToBeats(0, time)
  if measure == nil then
    return qn
  end

  local measure_idx = math.max(0, math.floor((tonumber(measure) or 0) + 0.5))
  local best = seq_snap_qn(qn, state.seq_grid_qn or 0.25)
  local best_dist = math.abs(qn - best)
  for m = math.max(0, measure_idx - 1), measure_idx + 2 do
    local end_qn = seq_get_measure_end_qn(m)
    if end_qn then
      local dist = math.abs(qn - end_qn)
      if dist < best_dist then
        best_dist = dist
        best = end_qn
      end
    end
  end
  return best
end

function seq_snap_qn_to_bar(qn, step_qn)
  qn = math.max(0.0, qn or 0.0)
  if not r.TimeMap_GetMeasureInfo or not r.TimeMap2_timeToBeats then
    return seq_snap_qn(qn, step_qn or state.seq_grid_qn or 0.25)
  end
  local time = qn_to_time(qn)
  if not time then
    return qn
  end
  local _, measure = r.TimeMap2_timeToBeats(0, time)
  if measure == nil then
    return qn
  end

  local measure_idx = math.max(0, math.floor(tonumber(measure) or 0))
  local start_qn = seq_get_measure_start_qn(measure_idx)
  if start_qn then
    return start_qn
  end
  return seq_snap_qn(qn, step_qn or state.seq_grid_qn or 0.25)
end

function seq_snap_qn_for_region_drag(qn, step_qn)
  if is_shift_down() then
    return seq_snap_qn(qn, step_qn)
  end
  return seq_snap_qn_to_bar(qn, step_qn)
end

function seq_snap_qn_for_region_move(qn, step_qn)
  if is_shift_down() then
    return seq_snap_qn(qn, step_qn)
  end
  return seq_snap_qn_to_bar(qn, step_qn)
end

function seq_x_to_qn(mx, timeline_x0, timeline_w, start_qn, qn_span)
  return start_qn + ((mx - timeline_x0) / math.max(1.0, timeline_w)) * qn_span
end

function seq_region_pool_count(pool_id)
  local count = 0
  for _, reg in ipairs(state.seq_regions) do
    if reg.pool_id == pool_id then
      count = count + 1
    end
  end
  return count
end

function seq_qn_length_to_bars(start_qn, length_qn)
  length_qn = math.max(state.seq_grid_qn or 0.25, length_qn)
  local bars = 1
  while bars < 512 do
    local test = { start_qn = start_qn, length_bars = bars }
    if get_seq_region_length_qn(test) >= length_qn - 0.0001 then
      return bars
    end
    bars = bars + 1
  end
  return bars
end

function seq_select_region(reg)
  if not reg then
    return
  end
  if state.selected_seq_region_id == reg.id then
    return
  end
  state.selected_seq_region_id = reg.id
  save_config()
end

function seq_zoom_to_region(reg)
  if not reg then
    return
  end
  state.seq_follow_arrange = false
  state.seq_view_start_qn = reg.start_qn or 0.0
  state.seq_view_span_qn = get_seq_region_length_qn(reg)
  save_config()
end

function seq_get_playhead_time()
  local play_state = r.GetPlayState and r.GetPlayState() or 0
  if play_state & 1 == 1 and r.GetPlayPosition then
    return r.GetPlayPosition()
  end
  if r.GetCursorPosition then
    return r.GetCursorPosition()
  end
  return nil
end

function seq_set_playhead_qn(qn)
  if type(qn) ~= "number" then
    return
  end
  local time_pos = qn_to_time(qn)
  if type(time_pos) ~= "number" then
    return
  end
  if r.SetEditCurPos then
    r.SetEditCurPos(time_pos, true, true)
  elseif r.SetEditCurPos2 then
    r.SetEditCurPos2(0, time_pos, true, true)
  end
end

function imgui_text_input_active()
  if r.ImGui_GetIO then
    local io = r.ImGui_GetIO(ctx)
    if io and io.WantTextInput then
      return io.WantTextInput
    end
  end
  return false
end

function handle_script_keyboard_shortcuts()
  if imgui_text_input_active() then
    return
  end
  if r.ImGui_IsKeyPressed and r.ImGui_Key_Space then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space(), false) then
      r.Main_OnCommand(40044, 0)
    end
  end
end

function seq_unpool_region(region)
  if not region then
    return
  end
  local old_pattern_id = region.pattern_id
  local old_pattern = get_seq_pattern(old_pattern_id, false)
  local new_pattern_id = alloc_seq_pattern()
  state.seq_patterns[tostring(new_pattern_id)] = clone_table_deep(old_pattern or { notes = {} })
  region.pattern_id = new_pattern_id
  region.pool_id = alloc_seq_pool()
  save_config()
  sync_seq_region(region)
  if old_pattern_id then
    sync_seq_pattern_regions(old_pattern_id)
  end
end

function seq_delete_region_by_id(region_id)
  state.selected_seq_region_id = region_id
  delete_selected_seq_region()
end

function seq_move_region_to(region, desired_start_qn)
  if not region then
    return false
  end
  local length_qn = get_seq_region_length_qn(region)
  desired_start_qn = math.max(0.0, desired_start_qn)
  local delta = desired_start_qn - (region.start_qn or 0.0)
  local new_start
  if delta < 0 then
    new_start = find_prev_non_overlapping_region_start(desired_start_qn, length_qn, region.id)
  else
    new_start = find_non_overlapping_region_start(desired_start_qn, length_qn, region.id)
  end
  if math.abs(new_start - (region.start_qn or 0.0)) < 0.000001 then
    return false
  end
  remove_seq_rendered_items(region)
  region.start_qn = new_start
  sort_seq_regions()
  save_config()
  sync_seq_region(region)
  return true
end

function seq_resize_region_end(region, new_end_qn, step_qn)
  if not region then
    return false
  end
  step_qn = step_qn or state.seq_grid_qn or 0.25
  new_end_qn = seq_snap_qn_for_region_drag(new_end_qn, step_qn)
  local reg_start = region.start_qn or 0.0
  new_end_qn = math.max(new_end_qn, reg_start + step_qn)
  for _, other in ipairs(state.seq_regions) do
    if other.id ~= region.id then
      local other_start = other.start_qn or 0.0
      if other_start > reg_start and other_start < new_end_qn then
        new_end_qn = other_start
      end
    end
  end
  local length_qn = new_end_qn - reg_start
  if length_qn < step_qn then
    return false
  end
  local bars = seq_qn_length_to_bars(reg_start, length_qn)
  if bars == region.length_bars then
    return false
  end
  remove_seq_rendered_items(region)
  region.length_bars = bars
  save_config()
  sync_seq_region(region)
  return true
end

function seq_resize_region_start(region, new_start_qn, step_qn)
  if not region then
    return false
  end
  step_qn = step_qn or state.seq_grid_qn or 0.25
  local reg_end = (region.start_qn or 0.0) + get_seq_region_length_qn(region)
  new_start_qn = seq_snap_qn_for_region_drag(math.max(0.0, new_start_qn), step_qn)
  new_start_qn = math.min(new_start_qn, reg_end - step_qn)
  for _, other in ipairs(state.seq_regions) do
    if other.id ~= region.id then
      local other_end = (other.start_qn or 0.0) + get_seq_region_length_qn(other)
      if other_end > new_start_qn and other_end <= reg_end then
        new_start_qn = math.max(new_start_qn, other_end)
      end
    end
  end
  local length_qn = reg_end - new_start_qn
  if length_qn < step_qn then
    return false
  end
  local bars = seq_qn_length_to_bars(new_start_qn, length_qn)
  if math.abs(new_start_qn - (region.start_qn or 0.0)) < 0.000001 and bars == region.length_bars then
    return false
  end
  remove_seq_rendered_items(region)
  region.start_qn = new_start_qn
  region.length_bars = bars
  sort_seq_regions()
  save_config()
  sync_seq_region(region)
  return true
end

function seq_draw_link_icon(dl, icon_x0, icon_y0, color)
  local cx0 = icon_x0 + 3
  local cy = icon_y0 + SEQ_LINK_ICON_SIZE * 0.5
  local cx1 = icon_x0 + SEQ_LINK_ICON_SIZE - 3
  r.ImGui_DrawList_AddCircleFilled(dl, cx0, cy, 3.0, color, 10)
  r.ImGui_DrawList_AddCircleFilled(dl, cx1, cy, 3.0, color, 10)
  r.ImGui_DrawList_AddLine(dl, cx0 + 2.5, cy, cx1 - 2.5, cy, color, 1.5)
end

function seq_hit_test_region_at(mx, my, y0, region_lane_h, timeline_x0, timeline_w, start_qn, qn_span, qn_to_x_fn)
  if my < y0 or my > y0 + region_lane_h or mx < timeline_x0 or mx > timeline_x0 + timeline_w then
    return nil
  end
  local clicked_qn = seq_x_to_qn(mx, timeline_x0, timeline_w, start_qn, qn_span)
  for i = #state.seq_regions, 1, -1 do
    local reg = state.seq_regions[i]
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if clicked_qn >= reg_start and clicked_qn <= reg_end then
      local rx0 = qn_to_x_fn(reg_start)
      local rx1 = qn_to_x_fn(reg_end)
      if seq_region_is_linked(reg) then
        local icon_x0 = rx0 + 4 - SEQ_LINK_HIT_PAD
        local icon_y0 = y0 + 4 - SEQ_LINK_HIT_PAD
        local icon_x1 = rx0 + 4 + SEQ_LINK_ICON_SIZE + SEQ_LINK_HIT_PAD
        local icon_y1 = y0 + 4 + SEQ_LINK_ICON_SIZE + SEQ_LINK_HIT_PAD
        if mx >= icon_x0 and mx <= icon_x1 and my >= icon_y0 and my <= icon_y1 then
          return { region = reg, part = "link" }
        end
      end
      if mx - rx0 <= SEQ_REGION_EDGE_PX then
        return { region = reg, part = "left_edge" }
      elseif rx1 - mx <= SEQ_REGION_EDGE_PX then
        return { region = reg, part = "right_edge" }
      end
      return { region = reg, part = "body" }
    end
  end
  return nil
end

function seq_get_default_create_region_qn(hover_qn, step_qn)
  step_qn = step_qn or state.seq_grid_qn or 0.25
  hover_qn = seq_snap_qn_for_region_drag(hover_qn or 0.0, step_qn)

  local create_start_qn = hover_qn
  local prev_region_end_qn = nil
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if reg_end <= hover_qn + 0.000001 then
      if not prev_region_end_qn or reg_end > prev_region_end_qn then
        prev_region_end_qn = reg_end
      end
    end
  end

  if prev_region_end_qn then
    local four_bars_qn = get_seq_region_length_qn({ start_qn = prev_region_end_qn, length_bars = 4 })
    local gap_qn = math.max(0.0, hover_qn - prev_region_end_qn)
    if gap_qn <= four_bars_qn + 0.000001 then
      create_start_qn = prev_region_end_qn
    elseif gap_qn <= (four_bars_qn * 2.0) + 0.000001 then
      create_start_qn = prev_region_end_qn + four_bars_qn
    end
  end

  local create_length_qn = get_seq_region_length_qn({ start_qn = create_start_qn, length_bars = 4 })
  create_start_qn = find_non_overlapping_region_start(create_start_qn, create_length_qn, nil)
  return create_start_qn, create_length_qn
end

function seq_region_is_linked(reg)
  if not reg then
    return false
  end
  if seq_region_pool_count(reg.pool_id) > 1 then
    return true
  end
  for _, other in ipairs(state.seq_regions) do
    if other.id ~= reg.id and other.pattern_id == reg.pattern_id then
      return true
    end
  end
  return false
end

function seq_region_at_qn(qn)
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if qn >= reg_start and qn < reg_end then
      return reg
    end
  end
  return nil
end

function seq_build_visible_active_cells(start_qn, end_qn, step_qn, step_count)
  local active_cells = {}
  for _, slot in ipairs(state.seq_tracks) do
    active_cells[slot.id] = {}
  end
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if reg_end >= start_qn and reg_start <= end_qn then
      local pattern = get_seq_pattern(reg.pattern_id, false)
      if pattern then
        for _, slot in ipairs(state.seq_tracks) do
          local notes = get_track_note_table(pattern, slot.id, false)
          if notes then
            for step_key, note in pairs(notes) do
              if type(note) == "table" and note.enabled ~= false then
                local abs_qn = reg_start + (note.qn_offset or 0.0)
                local col = math.floor(((abs_qn - start_qn) / step_qn) + 0.5)
                if col >= 0 and col < step_count then
                  active_cells[slot.id][col] = {
                    key = step_key,
                    note = note,
                    region_id = reg.id,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  return active_cells
end

function seq_dim_color_rrgbbaa(color, dim)
  if not dim then
    return color
  end
  local cr, cg, cb = extract_rgb_rrgbbaa(color or 0xFFFFFFFF)
  local alpha = math.max(20, math.floor((color or 0xFF) % 256 * 0.38))
  return build_color_rrgbbaa(cr, cg, cb, alpha)
end

local function make_default_seq_note(slot, step_key, qn_offset)
  local sample = slot and slot.sample_path and find_sample_by_path(slot.sample_path) or nil
  if not sample then
    return nil
  end
  return {
    enabled = true,
    step = tonumber(step_key) or 0,
    qn_offset = qn_offset or 0.0,
    sample_path = sample.path,
    sample_name = sample.name or basename(sample.path),
    volume = 1.0,
    pan = 0.0,
    pitch = 0.0,
    length_qn = state.seq_grid_qn or 0.25,
    offset_qn = 0.0,
    sample_vary = 0.0,
    stutter = 1,
  }
end

function seq_template_step_to_grid_step(template_step, steps_per_bar)
  local raw = (template_step or 0) * steps_per_bar / 16.0
  local rounded = math.floor(raw + 0.5)
  if math.abs(raw - rounded) > 0.000001 then
    return nil
  end
  return rounded
end

function seq_pattern_rand(seed)
  return math.abs(math.sin(seed or 0) * 10000.0) % 1.0
end

function seq_pattern_clamp(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end

function seq_role_anchor_hit(role, template_step)
  local fam = seq_role_family(role)
  if fam == "kick" then
    return template_step == 0 or template_step == 8
  end
  if fam == "backbeat" then
    return template_step == 4 or template_step == 12
  end
  return false
end

-- Each dice roll produces an independent random intensity (0..strength*10) for
-- every randomization type. So dice 1 yields 0..10, dice 2 yields 0..20, etc.
-- The rolled values are derived from the seed so a stored variation reproduces
-- exactly. Returns displacement %, density %, and stutter %.
function seq_dice_intensities(strength, seed)
  local s = math.max(0, math.min(6, strength or 0))
  if s <= 0 then
    return 0.0, 0.0, 0.0
  end
  local maxv = s * 10.0
  local disp = seq_pattern_rand((seed or 0) + 1234.5) * maxv
  local dens = seq_pattern_rand((seed or 0) + 6789.0) * maxv
  local stut = seq_pattern_rand((seed or 0) + 2468.0) * maxv
  return disp, dens, stut
end

-- Decides how far (in grid steps) a template hit is nudged from its position.
-- disp_pct is the rolled displacement intensity (0..60). Returns a signed step
-- delta, or 0 to stay put.
function seq_random_step_displacement(disp_pct, is_anchor, fam, rnd_gate, rnd_dir)
  if not disp_pct or disp_pct <= 0 then
    return 0
  end
  local p = disp_pct / 100.0
  if is_anchor then
    p = p * 0.55
  end
  if fam == "kick" then
    p = p * 0.8
  end
  if rnd_gate >= p then
    return 0
  end
  local span = rnd_gate / math.max(p, 1e-6)
  local mag = 1
  if disp_pct >= 25 and span > 0.5 then
    mag = 2
  end
  if disp_pct >= 45 and span > 0.8 then
    mag = 3
  end
  local dir = (rnd_dir < 0.5) and -1 or 1
  return dir * mag
end

-- Stutter/roll, intentionally rare even at high dice.
function apply_seq_random_note_shape(note, stut_pct, rnd_b)
  if not note or not stut_pct or stut_pct <= 0 then
    return
  end
  local stut_prob = (stut_pct / 100.0) * 0.10
  if rnd_b < stut_prob then
    note.stutter = math.min(6, 2 + math.floor(seq_pattern_rand(rnd_b * 10000.0 + stut_pct * 13.0) * 3))
  end
end

function seq_has_generatable_track(style_key)
  local template = SEQ_GEN_TEMPLATES[normalize_seq_gen_style(style_key)]
  if not template then
    return false
  end
  for _, slot in ipairs(state.seq_tracks) do
    if slot.sample_path then
      local role = infer_seq_track_role(slot)
      if template[role] then
        return true
      end
    end
  end
  return false
end

function generate_seq_pattern(region, style_key, opts)
  if not region then
    return 0
  end
  opts = opts or {}

  style_key = normalize_seq_gen_style(style_key)
  local template = SEQ_GEN_TEMPLATES[style_key] or SEQ_GEN_TEMPLATES.basic
  local pattern = get_seq_pattern(region.pattern_id, true)
  if not pattern then
    return 0
  end

  local grid_qn = (type(state.seq_grid_qn) == "number" and state.seq_grid_qn > 0) and state.seq_grid_qn or 0.25
  local region_len_qn = get_seq_region_length_qn(region)
  local steps_per_bar = math.max(1, math.floor((4.0 / grid_qn) + 0.5))
  local bar_count = math.max(1, math.floor((region_len_qn / 4.0) + 0.5))
  local max_steps = math.max(1, math.floor((region_len_qn / grid_qn) + 0.5))
  local strength = type(opts.random_strength) == "number" and math.max(0, math.min(6, math.floor(opts.random_strength + 0.5))) or 0
  local random_seed = opts.random_seed or seq_new_seed()

  -- One random intensity per randomization type for this dice roll.
  local disp_pct, dens_pct, stut_pct = seq_dice_intensities(strength, random_seed)
  -- Density randomization: drop some existing hits and/or add new ones.
  local drop_prob = (dens_pct / 100.0) * 0.5
  local add_prob = (dens_pct / 100.0) * 0.4

  pattern.notes = {}
  state.selected_seq_note = nil

  local hit_count = 0
  local skipped_unassigned = false
  for _, slot in ipairs(state.seq_tracks) do
    if slot.sample_path then
      local role = infer_seq_track_role(slot)
      local role_steps = template[role]
      if role_steps then
        local seen = {}
        local fam = seq_role_family(role)
        local template_step_lookup = {}
        for _, template_step in ipairs(role_steps) do
          template_step_lookup[template_step] = true
        end

        local function add_pattern_note(step_idx)
          if step_idx >= 0 and step_idx < max_steps and not seen[step_idx] then
            local note = make_default_seq_note(slot, step_idx, step_idx * grid_qn)
            if note then
              local pos16 = steps_per_bar > 0
                and math.floor(((step_idx % steps_per_bar) * 16.0 / steps_per_bar) + 0.5)
                or step_idx
              note.offset_qn = seq_pattern_base_offset(role, pos16, style_key, grid_qn)
              local rnd_stut = seq_pattern_rand(random_seed + step_idx * 733 + (slot.id or 0) * 41)
              apply_seq_random_note_shape(note, stut_pct, rnd_stut)
              if (step_idx % steps_per_bar) == 0 and note.offset_qn < 0.0 then
                note.offset_qn = 0.0
              end
              set_seq_note(region, slot.id, step_idx, note)
              seen[step_idx] = true
              hit_count = hit_count + 1
              return true
            end
          end
          return false
        end

        for bar = 0, bar_count - 1 do
          local bar_lo = bar * steps_per_bar
          local bar_hi = bar_lo + steps_per_bar - 1

          -- Place template hits, applying density-drop and displacement.
          for _, template_step in ipairs(role_steps) do
            local grid_step = seq_template_step_to_grid_step(template_step, steps_per_bar)
            if grid_step then
              local base_idx = bar_lo + grid_step
              local is_anchor = seq_role_anchor_hit(role, template_step)

              local dropped = false
              if drop_prob > 0 and not is_anchor then
                local rnd_drop = seq_pattern_rand(random_seed + base_idx * 211 + (slot.id or 0) * 13)
                if rnd_drop < drop_prob then
                  dropped = true
                end
              end

              if not dropped then
                local target_idx = base_idx
                if disp_pct > 0 then
                  local rnd_gate = seq_pattern_rand(random_seed + base_idx * 331 + (slot.id or 0) * 7)
                  local rnd_dir = seq_pattern_rand(random_seed + base_idx * 521 + (slot.id or 0) * 29)
                  local delta = seq_random_step_displacement(disp_pct, is_anchor, fam, rnd_gate, rnd_dir)
                  if delta ~= 0 then
                    local dir = (delta > 0) and 1 or -1
                    local mag = math.abs(delta)
                    local candidates = {}
                    candidates[#candidates + 1] = dir * mag
                    candidates[#candidates + 1] = -dir * mag
                    for m = mag - 1, 1, -1 do
                      candidates[#candidates + 1] = dir * m
                      candidates[#candidates + 1] = -dir * m
                    end
                    for _, d in ipairs(candidates) do
                      local cand = base_idx + d
                      if cand >= bar_lo and cand <= bar_hi and cand >= 0 and cand < max_steps and not seen[cand] then
                        target_idx = cand
                        break
                      end
                    end
                  end
                end
                if not add_pattern_note(target_idx) and target_idx ~= base_idx then
                  add_pattern_note(base_idx)
                end
              end
            end
          end

          -- Density-add: sprinkle new hits onto empty 16th steps in this bar.
          if add_prob > 0 then
            for template_step = 0, 15 do
              if not template_step_lookup[template_step] then
                local grid_step = seq_template_step_to_grid_step(template_step, steps_per_bar)
                if grid_step then
                  local idx = bar_lo + grid_step
                  if not seen[idx] then
                    local rnd_add = seq_pattern_rand(random_seed + idx * 617 + (slot.id or 0) * 23 + template_step * 5)
                    if rnd_add < add_prob then
                      add_pattern_note(idx)
                    end
                  end
                end
              end
            end
          end
        end
      end
    else
      skipped_unassigned = true
    end
  end

  save_config()
  sync_seq_pattern_regions(region.pattern_id)
  if skipped_unassigned then
    log("Skipped unassigned sequencer tracks while generating pattern")
  end
  if strength > 0 then
    log(string.format("Randomized %s pattern at dice %d (disp %.0f / dens %.0f / stut %.0f, %d hits)",
      get_seq_gen_style_label(style_key), strength, disp_pct, dens_pct, stut_pct, hit_count))
  else
    log("Generated " .. get_seq_gen_style_label(style_key) .. " pattern (" .. tostring(hit_count) .. " hits)")
  end
  return hit_count
end

function seq_template_roles(style_key)
  local template = SEQ_GEN_TEMPLATES[normalize_seq_gen_style(style_key)] or {}
  local roles = {}
  for _, role in ipairs(SEQ_ROLE_ORDER) do
    if template[role] then
      roles[#roles + 1] = role
    end
  end
  return roles
end

function find_sample_for_role(role)
  local candidates = SEQ_ROLE_TAG_CANDIDATES[role] or { role }
  for _, tag in ipairs(candidates) do
    local sample = find_sample_for_tag(tag)
    if sample then
      return sample, tag
    end
  end
  return nil
end

-- A preset can generate if any of its roles is already on an assigned track,
-- or a matching sample exists in the library to auto-create the track from.
function seq_preset_can_generate(style_key)
  local roles = seq_template_roles(style_key)
  if #roles == 0 then
    return false
  end
  local assigned_roles = {}
  for _, slot in ipairs(state.seq_tracks) do
    if slot.sample_path then
      assigned_roles[infer_seq_track_role(slot)] = true
    end
  end
  for _, role in ipairs(roles) do
    if assigned_roles[role] then
      return true
    end
    if find_sample_for_role(role) then
      return true
    end
  end
  return false
end

-- Ensure a sequencer track exists for each role the preset needs. Missing roles
-- get a new track (named for the role, stamped with the role's primary tag) and,
-- when available, an auto-assigned sample from the library.
function ensure_seq_tracks_for_roles(roles)
  local present = {}
  for _, slot in ipairs(state.seq_tracks) do
    present[infer_seq_track_role(slot)] = true
  end
  local created = 0
  for _, role in ipairs(roles) do
    if not present[role] then
      local label = SEQ_ROLE_LABELS[role] or role
      local slot = create_seq_track_with_name(label)
      if slot then
        local candidates = SEQ_ROLE_TAG_CANDIDATES[role] or { role }
        slot.sample_tag = candidates[1] or role
        local sample = find_sample_for_role(role)
        if sample then
          assign_sample_to_seq_track(slot, sample, false)
        end
        present[role] = true
        created = created + 1
      end
    end
  end
  return created
end

SEQ_PATTERN_POPUP_W = 340.0

function seq_truncate_text_to_width(text, max_w)
  if not text or text == "" then return "" end
  if max_w <= 0 then return "" end
  local tw = select(1, r.ImGui_CalcTextSize(ctx, text))
  if tw <= max_w then return text end
  local ell = "..."
  local len = #text
  while len > 0 do
    len = len - 1
    local candidate = text:sub(1, len) .. ell
    tw = select(1, r.ImGui_CalcTextSize(ctx, candidate))
    if tw <= max_w then return candidate end
  end
  return ell
end

-- Small pill label for inline badges (e.g. variation # tags).
function draw_ui_pill_label(dl, x, cy, text, opts)
  opts = opts or {}
  local pad_x = opts.pad_x or 6.0
  local pad_y = opts.pad_y or 2.0
  local rounding = opts.rounding or 5.0
  local bg = opts.bg or 0x2A5080FF
  local border = opts.border or 0x5A9AE6FF
  local text_col = opts.text_col or 0xE8F2FFFF
  local tw, th = r.ImGui_CalcTextSize(ctx, text)
  local w = tw + pad_x * 2.0
  local h = th + pad_y * 2.0
  local y = cy - h * 0.5
  r.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, rounding)
  r.ImGui_DrawList_AddRect(dl, x, y, x + w, y + h, border, rounding, 0, opts.border_w or 1.0)
  r.ImGui_DrawList_AddText(dl, x + pad_x, y + pad_y, text_col, text)
  return w, h
end

function open_seq_pattern_popup()
  state.seq_pattern_window_open = not state.seq_pattern_window_open
end

-- Position the preset popup flush against the left or right edge of the main
-- window (whichever side has room in the viewport) so it never covers the grid.
function seq_position_pattern_popup()
  local popup_w = SEQ_PATTERN_POPUP_W
  local rect = state.main_window_rect
  if not rect then
    if r.ImGui_SetNextWindowSize then
      r.ImGui_SetNextWindowSize(ctx, popup_w, 640.0)
    end
    if r.ImGui_SetNextWindowSizeConstraints then
      r.ImGui_SetNextWindowSizeConstraints(ctx, popup_w, 200.0, popup_w, 10000.0)
    end
    return
  end

  local vp_x, vp_w = nil, nil
  if r.ImGui_GetMainViewport and r.ImGui_Viewport_GetPos and r.ImGui_Viewport_GetSize then
    local vp = r.ImGui_GetMainViewport(ctx)
    if vp then
      vp_x = select(1, r.ImGui_Viewport_GetPos(vp))
      vp_w = select(1, r.ImGui_Viewport_GetSize(vp))
    end
  end

  local right_x = rect.x + rect.w
  local px
  if vp_x and vp_w and (right_x + popup_w) <= (vp_x + vp_w) then
    px = right_x                       -- attach just outside the right edge
  elseif rect.x - popup_w >= (vp_x or 0) then
    px = rect.x - popup_w              -- otherwise attach outside the left edge
  else
    px = right_x - popup_w             -- last resort: overlay the right edge
  end

  if r.ImGui_SetNextWindowPos then
    r.ImGui_SetNextWindowPos(ctx, px, rect.y)
  end
  if r.ImGui_SetNextWindowSize then
    r.ImGui_SetNextWindowSize(ctx, popup_w, rect.h)
  end
  if r.ImGui_SetNextWindowSizeConstraints then
    r.ImGui_SetNextWindowSizeConstraints(ctx, popup_w, 200.0, popup_w, 10000.0)
  end
end

function seq_pattern_variation_store(style_key)
  state.seq_pattern_variations = state.seq_pattern_variations or {}
  local store = state.seq_pattern_variations[style_key]
  if not store then
    store = { counter = 0, entries = {} }
    state.seq_pattern_variations[style_key] = store
  end
  return store
end

function seq_pattern_variation_count(style_key)
  local store = state.seq_pattern_variations and state.seq_pattern_variations[style_key]
  if not store then return 0 end
  return #store.entries
end

function seq_record_pattern_variation(style_key, strength, seed)
  local store = seq_pattern_variation_store(style_key)
  store.counter = store.counter + 1
  local entry = {
    id = store.counter,
    name = get_seq_gen_style_label(style_key) .. " #" .. tostring(store.counter),
    seed = seed,
    strength = strength,
  }
  store.entries[#store.entries + 1] = entry
  return entry
end

-- Snapshot the affected pattern before the *first* pattern application of a
-- confirmation session, so the X button can revert all the way back to the
-- state that existed before the user started auditioning patterns.
function seq_pattern_confirm_capture(region)
  if not region then return end
  if state.seq_pattern_confirm and state.seq_pattern_confirm.active then
    return
  end
  local key = tostring(region.pattern_id)
  state.seq_pattern_confirm = {
    active = true,
    region_id = region.id,
    pattern_id = region.pattern_id,
    snapshot = clone_table_deep(state.seq_patterns[key]),
  }
end

function seq_pattern_confirm_commit()
  state.seq_pattern_confirm = nil
end

function seq_pattern_confirm_restore()
  local c = state.seq_pattern_confirm
  if not c then return end
  local key = tostring(c.pattern_id)
  local label = begin_seq_undo("Revert pattern changes")
  if c.snapshot == nil then
    state.seq_patterns[key] = nil
  else
    state.seq_patterns[key] = clone_table_deep(c.snapshot)
  end
  state.selected_seq_note = nil
  save_config()
  sync_seq_pattern_regions(c.pattern_id)
  end_seq_undo(label)
  state.seq_pattern_confirm = nil
end

function render_seq_pattern_confirm_bar(dl, x0, y0, x1, y1)
  local cy = (y0 + y1) * 0.5
  r.ImGui_DrawList_AddRectFilled(dl, x0 + 2, y0 + 2, x1 + 2, y1 + 2, 0x00000066, 8.0)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x14233CF8, 8.0)
  r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, 0x5A9AE6FF, 8.0, 0, 1.5)

  local txt = "Keep pattern?"
  local _, th = r.ImGui_CalcTextSize(ctx, txt)
  r.ImGui_DrawList_AddText(dl, x0 + 12.0, cy - th * 0.5, 0xE8F2FFFF, txt)

  local btn = 24.0
  local gap = 6.0
  local bx = x1 - 12.0 - btn * 2.0 - gap
  local by = cy - btn * 0.5
  r.ImGui_SetCursorScreenPos(ctx, bx, by)
  if draw_ui_button("seq_pattern_confirm_apply", nil, btn, btn, { icon = "check", style = "success", compact = true }) then
    seq_pattern_confirm_commit()
  end
  r.ImGui_SetCursorScreenPos(ctx, bx + btn + gap, by)
  if draw_ui_button("seq_pattern_confirm_cancel", nil, btn, btn, { icon = "close", style = "danger", compact = true }) then
    seq_pattern_confirm_restore()
  end
end

function run_seq_pattern_preset(region, style_key, strength)
  state.seq_gen_style = normalize_seq_gen_style(style_key)
  local style = state.seq_gen_style
  if strength then
    state.seq_pattern_popup_last_style = style
    state.seq_pattern_popup_last_strength = strength
  end

  local label = begin_seq_undo(strength and "Randomize sequencer pattern" or "Generate sequencer pattern")
  local created = ensure_seq_tracks_for_roles(seq_template_roles(style))
  if created > 0 then
    log("Added " .. tostring(created) .. " track type(s) for " .. get_seq_gen_style_label(style))
    if r.TrackList_AdjustWindows then
      r.TrackList_AdjustWindows(false)
    end
    r.UpdateArrange()
  end
  if region and seq_has_generatable_track(style) then
    seq_pattern_confirm_capture(region)
    local seed = seq_new_seed()
    generate_seq_pattern(region, style, { random_strength = strength, random_seed = seed })
    if strength then
      seq_record_pattern_variation(style, strength, seed)
    end
  end
  end_seq_undo(label)
  save_config()
end

function seq_apply_pattern_variation(region, style_key, variation)
  if not (region and variation) then return end
  state.seq_gen_style = normalize_seq_gen_style(style_key)
  local style = state.seq_gen_style
  local label = begin_seq_undo("Apply pattern variation")
  local created = ensure_seq_tracks_for_roles(seq_template_roles(style))
  if created > 0 then
    if r.TrackList_AdjustWindows then
      r.TrackList_AdjustWindows(false)
    end
    r.UpdateArrange()
  end
  if seq_has_generatable_track(style) then
    seq_pattern_confirm_capture(region)
    generate_seq_pattern(region, style, { random_strength = variation.strength, random_seed = variation.seed })
  end
  end_seq_undo(label)
  save_config()
end

function render_seq_pattern_preset_row(region, style_def)
  local style_key = style_def.key
  local selected = state.seq_gen_style == style_key
  local can_generate = region and seq_preset_can_generate(style_key)
  local avail_w = r.ImGui_GetContentRegionAvail(ctx)
  local row_w = math.max(1.0, avail_w)
  local row_h = 34.0
  local left_pad = 10.0
  local right_pad = 8.0

  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local x1, y1 = x0 + row_w, y0 + row_h
  local mx, my = r.ImGui_GetMousePos(ctx)
  local hovered = mx >= x0 and mx <= x1 and my >= y0 and my <= y1

  local has_variations = seq_pattern_variation_count(style_key) > 0
  local btn_size = 20.0
  local btn_gap = 3.0

  -- The list button sits at the far right whenever variations exist.
  local list_w = has_variations and (btn_size + 6.0) or 0.0
  local list_x = x0 + row_w - right_pad - btn_size

  -- Dice strip appears on hover, to the left of the list button.
  local dice_size = btn_size
  local dice_total_w = dice_size * 6.0 + btn_gap * 5.0
  local right_edge = x0 + row_w - right_pad - list_w
  if hovered and dice_total_w > (right_edge - x0 - 70.0) then
    dice_size = math.max(13.0, math.floor((right_edge - x0 - 70.0 - btn_gap * 5.0) / 6.0))
    dice_total_w = dice_size * 6.0 + btn_gap * 5.0
  end
  local dice_x = right_edge - dice_total_w

  -- Row click area excludes the dice strip (on hover) and the list button so
  -- those overlapping buttons receive their own clicks.
  local interactive_left = right_edge
  if hovered then
    interactive_left = dice_x
  end
  local row_button_w = math.max(40.0, interactive_left - x0 - 4.0)
  r.ImGui_InvisibleButton(ctx, "##seq_pattern_preset_row_" .. style_key, row_button_w, row_h)
  local clicked = r.ImGui_IsItemClicked(ctx, 0)

  local dl = r.ImGui_GetWindowDrawList(ctx)
  local fill = selected and 0x263E5CFF or 0x182230FF
  local edge = selected and 0x7EB8F0FF or 0x384858FF
  if hovered then
    fill = selected and 0x31577EFF or 0x243448FF
    edge = 0x8EC0FFFF
  end
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, fill, 5.0)
  r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, edge, 5.0, 0, selected and 1.5 or 1.0)

  local label_color = selected and 0xFFFFFFFF or 0xD7E8FFFF
  local label_right = hovered and dice_x or (x0 + row_w - right_pad - list_w)
  local label_max_w = math.max(20.0, label_right - x0 - left_pad - 6.0)
  if not hovered then
    label_max_w = math.min(label_max_w, row_w * 0.42)
  end
  local label_text = seq_truncate_text_to_width(style_def.label, label_max_w)
  r.ImGui_DrawList_AddText(dl, x0 + left_pad, y0 + 9.0, label_color, label_text)

  if not hovered then
    local palette = {}
    for _, role in ipairs(seq_template_roles(style_key)) do
      palette[#palette + 1] = SEQ_ROLE_LABELS[role] or role
    end
    if #palette > 0 then
      local palette_text = table.concat(palette, " \xC2\xB7 ")
      local label_w = select(1, r.ImGui_CalcTextSize(ctx, label_text))
      local palette_right = x0 + row_w - right_pad - list_w
      local palette_max_w = math.max(20.0, palette_right - (x0 + left_pad + label_w) - 12.0)
      palette_text = seq_truncate_text_to_width(palette_text, palette_max_w)
      local palette_w = select(1, r.ImGui_CalcTextSize(ctx, palette_text))
      r.ImGui_DrawList_AddText(
        dl,
        palette_right - palette_w,
        y0 + 9.0,
        can_generate and 0x8AA6C8FF or 0x6A748AFF,
        palette_text
      )
    end
  end

  if clicked and can_generate then
    run_seq_pattern_preset(region, style_key, nil)
  elseif clicked then
    state.seq_gen_style = normalize_seq_gen_style(style_key)
    save_config()
  end

  if hovered then
    local dice_y = y0 + (row_h - dice_size) * 0.5
    for strength = 1, 6 do
      r.ImGui_SetCursorScreenPos(ctx, dice_x + (strength - 1) * (dice_size + btn_gap), dice_y)
      local dice_clicked = draw_ui_button(
        "seq_pattern_dice_" .. style_key .. "_" .. tostring(strength),
        nil,
        dice_size,
        dice_size,
        { icon = "dice" .. tostring(strength), compact = true, style = "default" }
      )
      if dice_clicked and can_generate then
        run_seq_pattern_preset(region, style_key, strength)
      end
    end
  end

  if has_variations then
    r.ImGui_SetCursorScreenPos(ctx, list_x, y0 + (row_h - btn_size) * 0.5)
    local list_clicked = draw_ui_button(
      "seq_pattern_varlist_" .. style_key,
      nil,
      btn_size,
      btn_size,
      { icon = "list", compact = true, style = selected and "primary" or "default" }
    )
    if list_clicked then
      state.seq_pattern_variations_open_key = style_key
      state.seq_pattern_variations_request_open = true
    end
  end

  r.ImGui_SetCursorScreenPos(ctx, x0, y1)
  r.ImGui_Dummy(ctx, 0, 5.0)
end

function render_seq_pattern_popup(region)
  if not state.seq_pattern_window_open then
    return
  end
  seq_position_pattern_popup()

  local win_flags = 0
  local function add_flag(getter)
    if getter then win_flags = win_flags | getter() end
  end
  add_flag(r.ImGui_WindowFlags_NoTitleBar)
  add_flag(r.ImGui_WindowFlags_NoCollapse)
  add_flag(r.ImGui_WindowFlags_NoDocking)
  add_flag(r.ImGui_WindowFlags_NoScrollbar)
  add_flag(r.ImGui_WindowFlags_NoScrollWithMouse)

  local visible, keep_open = r.ImGui_Begin(ctx, "Pattern Presets##seq_pattern_window", true, win_flags)
  if keep_open == false then
    state.seq_pattern_window_open = false
  end
  if visible then
    state.seq_gen_style = normalize_seq_gen_style(state.seq_gen_style)
    local can_generate = region and seq_preset_can_generate(state.seq_gen_style)

    r.ImGui_TextColored(ctx, 0xD7E8FFFF, "Pattern Presets")
    r.ImGui_SameLine(ctx)
    local avail_close = r.ImGui_GetContentRegionAvail(ctx)
    r.ImGui_SetCursorPosX(ctx, r.ImGui_GetCursorPosX(ctx) + math.max(0.0, avail_close - 22.0))
    if draw_ui_button("seq_pattern_window_close", nil, 18.0, 18.0, { icon = "close", compact = true, style = "default" }) then
      state.seq_pattern_window_open = false
    end
    r.ImGui_TextColored(ctx, 0x88A0BFFF, "Each preset has its own sample types; picking one auto-adds missing track types.")
    r.ImGui_TextColored(ctx, 0x88A0BFFF, "Click to generate. Hover for dice: 1 is subtle, 6 is unruly.")
    if not can_generate then
      r.ImGui_TextColored(ctx, 0xFFB870FF, "No matching samples found for this preset's types.")
    end
    r.ImGui_Separator(ctx)

    local list_flags = 0
    if r.ImGui_WindowFlags_NoBackground then
      list_flags = r.ImGui_WindowFlags_NoBackground()
    end
    if r.ImGui_BeginChild(ctx, "seq_pattern_preset_list", 0, 0, 0, list_flags) then
      for _, style in ipairs(SEQ_GEN_STYLE_ORDER) do
        if style.header then
          r.ImGui_Dummy(ctx, 0, 2)
          r.ImGui_TextColored(ctx, 0x9FB7CCFF, style.header)
        elseif style.key then
          render_seq_pattern_preset_row(region, style)
        end
      end
      r.ImGui_EndChild(ctx)
    end

    if state.seq_pattern_variations_request_open then
      state.seq_pattern_variations_request_open = false
      r.ImGui_OpenPopup(ctx, "seq_pattern_variations_popup")
    end
    render_seq_pattern_variations_popup(region)
  end

  r.ImGui_End(ctx)
end

function render_seq_pattern_variation_row(region, style_key, entry)
  local row_w = math.max(1.0, r.ImGui_GetContentRegionAvail(ctx))
  local row_h = 30.0
  r.ImGui_InvisibleButton(ctx, "##seq_var_" .. tostring(entry.id), row_w, row_h)
  local x0, y0 = r.ImGui_GetItemRectMin(ctx)
  local x1, y1 = r.ImGui_GetItemRectMax(ctx)
  row_w = x1 - x0
  local hovered = r.ImGui_IsItemHovered(ctx)
  local clicked = r.ImGui_IsItemClicked(ctx, 0)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local cy = (y0 + y1) * 0.5

  if hovered then
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x31577EAA, 4.0)
    r.ImGui_DrawList_AddRect(dl, x0, y0, x1, y1, 0x5A9AE6FF, 4.0, 0, 1.0)
  end

  local x = x0 + 6.0
  local base_name = get_seq_gen_style_label(style_key)
  local _, name_h = r.ImGui_CalcTextSize(ctx, base_name)
  r.ImGui_DrawList_AddText(dl, x, cy - name_h * 0.5, 0xD7E8FFFF, base_name)
  x = x + select(1, r.ImGui_CalcTextSize(ctx, base_name)) + 8.0

  local num_text = "#" .. tostring(entry.id)
  local pill_w = draw_ui_pill_label(dl, x, cy, num_text, {
    bg = 0x2A5080FF,
    border = 0x7EB8F0FF,
    text_col = 0xF0F8FFFF,
    pad_x = 7.0,
    pad_y = 2.0,
    rounding = 6.0,
  })
  x = x + pill_w + 6.0

  local dice_text = "dice " .. tostring(entry.strength or 1)
  draw_ui_pill_label(dl, x, cy, dice_text, {
    bg = 0x1E2838FF,
    border = 0x4A6888FF,
    text_col = 0x9FB7CCFF,
    pad_x = 6.0,
    pad_y = 2.0,
    rounding = 5.0,
  })

  if clicked then
    seq_apply_pattern_variation(region, style_key, entry)
    r.ImGui_CloseCurrentPopup(ctx)
  end
end

function render_seq_pattern_variations_popup(region)
  local style_key = state.seq_pattern_variations_open_key
  if r.ImGui_SetNextWindowSizeConstraints then
    r.ImGui_SetNextWindowSizeConstraints(ctx, 280.0, 80.0, 280.0, 520.0)
  end
  if not r.ImGui_BeginPopup(ctx, "seq_pattern_variations_popup") then
    return
  end

  local store = style_key and state.seq_pattern_variations and state.seq_pattern_variations[style_key]
  r.ImGui_TextColored(ctx, 0xD7E8FFFF, "Variations")
  if style_key then
    r.ImGui_TextColored(ctx, 0x88A0BFFF, get_seq_gen_style_label(style_key))
  end
  r.ImGui_Separator(ctx)

  if not store or #store.entries == 0 then
    r.ImGui_TextColored(ctx, 0x88A0BFFF, "No variations yet. Roll a dice to add some.")
  else
    for i = #store.entries, 1, -1 do
      render_seq_pattern_variation_row(region, style_key, store.entries[i])
    end
    r.ImGui_Separator(ctx)
    if r.ImGui_SmallButton(ctx, "Clear list##seq_var_clear") then
      store.entries = {}
      r.ImGui_CloseCurrentPopup(ctx)
    end
  end

  r.ImGui_EndPopup(ctx)
end

function seq_anim_clamp01(v)
  if v <= 0.0 then return 0.0 end
  if v >= 1.0 then return 1.0 end
  return v
end

function seq_note_anim_cell_key(region_id, track_id, step_key)
  return tostring(region_id or 0) .. ":" .. tostring(track_id or 0) .. ":" .. tostring(step_key or 0)
end

function seq_snapshot_note_for_anim(note)
  if type(note) ~= "table" then
    return nil
  end
  return {
    enabled = note.enabled ~= false,
    step = note.step,
    qn_offset = note.qn_offset or 0.0,
    sample_path = note.sample_path,
    sample_name = note.sample_name,
    volume = note.volume,
    pan = note.pan,
    pitch = note.pitch,
    length_qn = note.length_qn,
    offset_qn = note.offset_qn,
    sample_vary = note.sample_vary,
    stutter = note.stutter,
  }
end

function register_seq_note_anim(region_id, track_id, step_key, note, kind)
  if not region_id or not track_id or step_key == nil or (kind ~= "add" and kind ~= "delete") then
    return
  end
  state.seq_note_anims = state.seq_note_anims or {}
  local duration = kind == "delete" and 0.24 or 0.20
  state.seq_note_anims[seq_note_anim_cell_key(region_id, track_id, step_key)] = {
    kind = kind,
    region_id = region_id,
    track_id = track_id,
    step_key = tostring(step_key),
    note = seq_snapshot_note_for_anim(note),
    start_time = r.time_precise(),
    duration = duration,
  }
end

function prune_seq_note_anims(now)
  local anims = state.seq_note_anims
  if not anims then
    return
  end
  for key, anim in pairs(anims) do
    local start_t = anim.start_time or 0.0
    local dur = anim.duration or 0.2
    if (now - start_t) >= dur then
      anims[key] = nil
    end
  end
end

function get_seq_note_anim(region_id, track_id, step_key, now)
  local anims = state.seq_note_anims
  if not anims then
    return nil
  end
  local key = seq_note_anim_cell_key(region_id, track_id, step_key)
  local anim = anims[key]
  if not anim then
    return nil
  end
  local dur = anim.duration or 0.2
  local t = dur > 0 and seq_anim_clamp01((now - (anim.start_time or now)) / dur) or 1.0
  if t >= 1.0 then
    anims[key] = nil
    return nil
  end
  anim.t = t
  return anim
end

function scale_rect_about_center(x0, y0, x1, y1, scale_x, scale_y, offset_y)
  local cx = (x0 + x1) * 0.5
  local cy = (y0 + y1) * 0.5 + (offset_y or 0.0)
  local hw = math.max(1.0, (x1 - x0) * 0.5 * (scale_x or 1.0))
  local hh = math.max(1.0, (y1 - y0) * 0.5 * (scale_y or 1.0))
  return cx - hw, cy - hh, cx + hw, cy + hh
end

local function toggle_seq_note(region, slot, step_key, qn_offset, force_mode)
  if not region or not slot then
    return false
  end

  local existing = get_seq_note(region, slot.id, step_key)
  if existing and force_mode ~= "paint" then
    register_seq_note_anim(region.id, slot.id, step_key, existing, "delete")
    delete_seq_note(region, slot.id, step_key)
    if state.selected_seq_note and state.selected_seq_note.region_id == region.id and
       state.selected_seq_note.track_id == slot.id and state.selected_seq_note.step_key == tostring(step_key) then
      state.selected_seq_note = nil
    end
  elseif not existing and force_mode ~= "erase" then
    local note = make_default_seq_note(slot, step_key, qn_offset)
    if not note then
      log("Sequencer slot has no assigned sample")
      return false
    end
    set_seq_note(region, slot.id, step_key, note)
    register_seq_note_anim(region.id, slot.id, step_key, note, "add")
    state.selected_seq_note = { region_id = region.id, track_id = slot.id, step_key = tostring(step_key) }
  else
    return false
  end

  save_config()
  sync_seq_pattern_regions(region.pattern_id)
  return true
end

local function get_selected_seq_note()
  if not state.selected_seq_note then
    return nil, nil
  end
  local region = get_seq_region_by_id(state.selected_seq_note.region_id)
  if not region then
    return nil, nil
  end
  return get_seq_note(region, state.selected_seq_note.track_id, state.selected_seq_note.step_key), region
end

SEQ_PARAM_LANES = {
  { key = "volume", label = "Vol", min = 0.0, max = 2.0, default = 1.0, fmt = "%.2f" },
  { key = "sample_vary", label = "Vary", min = 0.0, max = 1.0, default = 0.0, fmt = "%.2f" },
  { key = "stutter", label = "Stut", min = 1.0, max = 16.0, default = 1.0, fmt = "%.0f" },
  { key = "pan", label = "Pan", min = -1.0, max = 1.0, default = 0.0, fmt = "%.2f" },
  { key = "pitch", label = "Pitch", min = -24.0, max = 24.0, default = 0.0, fmt = "%.1f" },
  { key = "length_qn", label = "Len", min = 0.03125, max = 8.0, default = 0.25, fmt = "%.3f" },
  { key = "offset_qn", label = "Off", min = -1.0, max = 1.0, default = 0.0, fmt = "%.3f" },
}

local function get_seq_row_lane_style(row)
  if row.type == "note" then
    return {
      bg = 0x1B2230FF,
      label_bg = 0x151A24FF,
      timeline_bg = 0x1A2438FF,
      edge = 0x4A5870FF,
      accent = 0x6E8EB8FF,
    }
  end
  if row.type == "param" and row.param then
    local styles = {
      volume = { bg = 0x141922FF, label_bg = 0x10151DFF, timeline_bg = 0x181A14FF, edge = 0x3A4860FF, accent = 0xFFD166FF },
      sample_vary = { bg = 0x131A22FF, label_bg = 0x0F151CFF, timeline_bg = 0x121C14FF, edge = 0x384858FF, accent = 0x8FD98FFF },
      stutter = { bg = 0x18141EFF, label_bg = 0x121018FF, timeline_bg = 0x1C1424FF, edge = 0x403858FF, accent = 0xC9A8FFFF },
      pan = { bg = 0x121922FF, label_bg = 0x0D141CFF, timeline_bg = 0x101C24FF, edge = 0x344560FF, accent = 0x6EC8FFFF },
      pitch = { bg = 0x191820FF, label_bg = 0x131018FF, timeline_bg = 0x201A14FF, edge = 0x3A3850FF, accent = 0xFFB84DFF },
      length_qn = { bg = 0x121A22FF, label_bg = 0x0D141CFF, timeline_bg = 0x101E18FF, edge = 0x344860FF, accent = 0x88DDAAFF },
      offset_qn = { bg = 0x141922FF, label_bg = 0x10151CFF, timeline_bg = 0x141824FF, edge = 0x364058FF, accent = 0xAFC6E8FF },
    }
    return styles[row.param.key] or { bg = 0x141923FF, label_bg = 0x10151CFF, timeline_bg = 0x141923FF, edge = 0x364058FF, accent = 0xAFC6E8FF }
  end
  return { bg = 0x171B23FF, label_bg = 0x12161EFF, timeline_bg = 0x171B23FF, edge = 0x344055FF, accent = 0x888888FF }
end

function seq_lane_color_with_alpha(color, alpha)
  local cr, cg, cb = extract_rgb_rrgbbaa(color or 0xFFFFFFFF)
  return build_color_rrgbbaa(cr, cg, cb, alpha or 255)
end

function seq_lane_param_fill_colors(accent, bipolar, value)
  local ar, ag, ab = extract_rgb_rrgbbaa(accent or 0xFFD166FF)
  local fill = build_color_rrgbbaa(ar, ag, ab, 205)
  local cap = build_color_rrgbbaa(math.min(255, ar + 45), math.min(255, ag + 45), math.min(255, ab + 45), 255)
  local fill_neg = build_color_rrgbbaa(math.max(0, ar - 70), math.max(0, ag - 35), math.min(255, ab + 40), 205)
  if bipolar and value ~= nil and value < 0 then
    return fill_neg, cap
  end
  return fill, cap
end

local function get_param_lane_def(param_key)
  for _, def in ipairs(SEQ_PARAM_LANES) do
    if def.key == param_key then
      return def
    end
  end
  return nil
end

local function seq_param_value_from_y(def, y, y0, y1, step_qn)
  local t = 1.0 - ((y - y0) / math.max(1.0, y1 - y0))
  t = math.max(0.0, math.min(1.0, t))
  local min_v = def.min
  local max_v = def.max
  if def.key == "length_qn" then
    min_v = math.min(step_qn or state.seq_grid_qn or 0.25, def.min)
    max_v = math.max(step_qn or state.seq_grid_qn or 0.25, def.max)
  elseif def.key == "offset_qn" then
    local range = step_qn or state.seq_grid_qn or 0.25
    min_v = -range
    max_v = range
  end
  return min_v + (max_v - min_v) * t
end

local function seq_param_y_from_value(def, value, y0, y1, step_qn)
  local min_v = def.min
  local max_v = def.max
  if def.key == "length_qn" then
    min_v = math.min(step_qn or state.seq_grid_qn or 0.25, def.min)
    max_v = math.max(step_qn or state.seq_grid_qn or 0.25, def.max)
  elseif def.key == "offset_qn" then
    local range = step_qn or state.seq_grid_qn or 0.25
    min_v = -range
    max_v = range
  end
  local t = ((value or def.default) - min_v) / math.max(0.000001, max_v - min_v)
  t = math.max(0.0, math.min(1.0, t))
  return y1 - t * (y1 - y0)
end

local function collect_measure_guides_qn(start_qn, end_qn, max_guides)
  local guides = {}
  if not r.TimeMap_GetMeasureInfo or not r.TimeMap2_timeToBeats then
    return guides
  end

  local start_time = qn_to_time(start_qn)
  if not start_time then
    return guides
  end

  max_guides = max_guides or 1024
  local _, start_measure = r.TimeMap2_timeToBeats(0, start_time)
  if start_measure == nil then
    return guides
  end

  local measure = math.max(0, start_measure)
  local guard = 0
  while guard < max_guides do
    local meas_time, qn_start, qn_end, ts_num, ts_den = r.TimeMap_GetMeasureInfo(0, measure)
    if not meas_time or not qn_start then
      break
    end
    if qn_start > end_qn + 0.000001 then
      break
    end

    local out_num = (type(ts_num) == "number" and ts_num > 0) and ts_num or 4
    local out_den = (type(ts_den) == "number" and ts_den > 0) and ts_den or 4
    local out_qn_end = qn_end
    if type(out_qn_end) ~= "number" or out_qn_end <= qn_start then
      out_qn_end = qn_start + out_num * (4.0 / out_den)
    end

    if out_qn_end >= start_qn - 0.000001 then
      guides[#guides + 1] = {
        measure = measure,
        qn_start = qn_start,
        qn_end = out_qn_end,
        time = meas_time,
        ts_num = out_num,
        ts_den = out_den,
      }
    end

    measure = measure + 1
    guard = guard + 1
  end

  return guides
end

local function find_seq_param_lane_bounds(row_positions, track_id, param_key)
  for _, row_pos in ipairs(row_positions) do
    local row = row_pos.row
    if row.type == "param" and row.slot and row.slot.id == track_id and row.param and row.param.key == param_key then
      return row_pos.y0 + 2, row_pos.y1 - 2, row_pos
    end
  end
  return nil, nil, nil
end

local function format_seq_param_value(def, value)
  if value == nil then
    value = def.default
  end
  return string.format("%s %s", def.label, string.format(def.fmt, value))
end

function draw_seq_stutter_lane_cell(dl, ctx, cx0, cx1, lane_top, lane_bot, count, accent)
  count = math.max(1, math.min(16, math.floor((count or 1) + 0.5)))
  local ar, ag, ab = extract_rgb_rrgbbaa(accent or 0xC9A8FFFF)
  local pad_x = 2.0
  local fill_x0 = cx0 + pad_x
  local fill_x1 = cx1 - pad_x
  if fill_x1 <= fill_x0 then
    fill_x1 = fill_x0 + 1.0
  end

  local lane_h = math.max(4.0, lane_bot - lane_top)
  local gap = 1.0
  local box_h = math.max(2.0, (lane_h - gap * (count - 1)) / count)
  local stack_h = count * box_h + math.max(0, count - 1) * gap
  local stack_y0 = lane_bot - stack_h

  for i = 1, count do
    local by1 = lane_bot - (i - 1) * (box_h + gap)
    local by0 = by1 - box_h
    if by0 < stack_y0 then
      by0 = stack_y0
    end
    local fade = 50 + math.floor((i / count) * 120)
    local edge_fade = math.min(255, fade + 40)
    local fill_col = build_color_rrgbbaa(ar, ag, ab, fade)
    local edge_col = build_color_rrgbbaa(ar, ag, ab, edge_fade)
    r.ImGui_DrawList_AddRectFilled(dl, fill_x0, by0, fill_x1, by1, fill_col, 1.0)
    r.ImGui_DrawList_AddRect(dl, fill_x0, by0, fill_x1, by1, edge_col, 1.0, 0, 1.0)
  end

  local text = tostring(count)
  local text_size = { r.ImGui_CalcTextSize(ctx, text) }
  local text_w = text_size[1] or 0
  local text_h = text_size[2] or 0
  local tx = (fill_x0 + fill_x1) * 0.5 - text_w * 0.5
  local ty = (lane_top + lane_bot) * 0.5 - text_h * 0.5
  r.ImGui_DrawList_AddRectFilled(dl, tx - 2, ty - 1, tx + text_w + 2, ty + text_h + 1, 0x00000099, 2.0)
  r.ImGui_DrawList_AddText(dl, tx + 1, ty + 1, 0x000000AA, text)
  r.ImGui_DrawList_AddText(dl, tx, ty, seq_lane_color_with_alpha(accent, 255), text)
end

local function seq_param_mouse_col(mx, timeline_x0, cell_w, step_count)
  return math.max(0, math.min(step_count - 1, math.floor((mx - timeline_x0) / cell_w)))
end

local function seq_param_value_for_drag(def, value, step_qn)
  if def.key == "length_qn" then
    return snap_seq_length_qn(value, step_qn)
  end
  if def.key == "stutter" then
    return math.max(1, math.floor((value or 1) + 0.5))
  end
  return value
end

local function apply_seq_param_lane_drag(drag, def, lane_y0, lane_y1, mx, my, step_qn, step_count, timeline_x0, cell_w, active_cells)
  drag.end_col = seq_param_mouse_col(mx, timeline_x0, cell_w, step_count)
  local mouse_col = drag.end_col
  local current_value = seq_param_value_for_drag(def, seq_param_value_from_y(def, my, lane_y0, lane_y1, step_qn), step_qn)
  local col_min = math.min(drag.col, drag.end_col)
  local col_max = math.max(drag.col, drag.end_col)
  local changed = false

  if drag.ramp and drag.end_col ~= drag.col then
    local start_val = drag.start_value
    if start_val == nil then
      start_val = def.default
    end
    for col = col_min, col_max do
      local active = active_cells[drag.track_id] and active_cells[drag.track_id][col]
      if active then
        local t = (col - drag.col) / (drag.end_col - drag.col)
        local value = seq_param_value_for_drag(def, start_val + (current_value - start_val) * t, step_qn)
        active.note[def.key] = value
        changed = true
      end
    end
  elseif drag.unify then
    for col = col_min, col_max do
      local active = active_cells[drag.track_id] and active_cells[drag.track_id][col]
      if active then
        active.note[def.key] = current_value
        changed = true
      end
    end
  else
    local active = active_cells[drag.track_id] and active_cells[drag.track_id][mouse_col]
    if active then
      active.note[def.key] = current_value
      changed = true
      state.selected_seq_note = {
        region_id = drag.region_id,
        track_id = drag.track_id,
        step_key = active.key,
      }
    end
  end

  local highlight_col_min = mouse_col
  local highlight_col_max = mouse_col
  if drag.ramp or drag.unify then
    highlight_col_min = col_min
    highlight_col_max = col_max
  end

  return changed, current_value, highlight_col_min, highlight_col_max, mouse_col
end

function render_sequencer_map()
  clear_seq_vary_rank_cache()
  local region = get_selected_seq_region()
  local avail_x, avail_y = r.ImGui_GetContentRegionAvail(ctx)
  local width = math.max(720.0, avail_x)
  local lane_zoom = math.max(0.5, math.min(3.0, state.seq_lane_zoom or 1.0))
  state.seq_lane_zoom = lane_zoom
  local note_lane_h = 48.0 * lane_zoom
  local param_lane_h = 22.0 * lane_zoom
  local region_lane_h = 22.0
  local ruler_lane_h = 30.0
  local header_h = region_lane_h + ruler_lane_h
  local visual_rows = {}
  for _, slot in ipairs(state.seq_tracks) do
    visual_rows[#visual_rows + 1] = { type = "note", slot = slot, h = note_lane_h }
    if state.seq_expanded_tracks[tostring(slot.id)] then
      for _, def in ipairs(SEQ_PARAM_LANES) do
        visual_rows[#visual_rows + 1] = { type = "param", slot = slot, param = def, h = param_lane_h }
      end
    end
  end
  if #visual_rows == 0 then
    visual_rows[#visual_rows + 1] = { type = "empty", h = note_lane_h }
  end
  local rows_h = 0.0
  for _, row in ipairs(visual_rows) do
    rows_h = rows_h + row.h
  end
  local add_track_row_h = 28.0
  local map_h = math.max(header_h + rows_h + add_track_row_h, 210.0)

  local child_flags = 0
  if r.ImGui_ChildFlags_Border then child_flags = r.ImGui_ChildFlags_Border end
  if not r.ImGui_BeginChild(ctx, "sequencer_map_area", 0, math.max(0, avail_y), child_flags) then
    r.ImGui_EndChild(ctx)
    return
  end

  local function grid_button(label, qn, btn_id)
    local active = math.abs((state.seq_grid_qn or 0.25) - qn) < 0.0001
    local display = label:match("^(.-)##") or label
    if draw_ui_button(btn_id or display, display, nil, nil, { style = active and "accent" or "default", selected = active, compact = true }) then
      state.seq_grid_qn = qn
      save_config()
    end
    r.ImGui_SameLine(ctx)
  end

  r.ImGui_TextColored(ctx, 0xD7E8FFFF, "Sequencer")
  r.ImGui_SameLine(ctx)
  grid_button("1/4##grid4", 1.0)
  grid_button("1/8##grid8", 0.5)
  grid_button("1/16##grid16", 0.25)
  grid_button("1/32##grid32", 0.125)
  grid_button("1/8T##grid8t", 1.0 / 3.0)
  grid_button("1/16T##grid16t", 1.0 / 6.0)

  state.seq_gen_style = normalize_seq_gen_style(state.seq_gen_style)
  if draw_ui_button("seq_pattern_popup_open", "Patterns: " .. get_seq_gen_style_label(state.seq_gen_style), nil, nil, { style = "primary", compact = true, selected = state.seq_pattern_window_open }) then
    open_seq_pattern_popup()
  end
  r.ImGui_Separator(ctx)

  if draw_ui_button("seq_sync", "Sync to Arrange") then
    state.seq_follow_arrange = true
    local arrange_start, arrange_end = get_arrange_view_range()
    local arrange_start_qn = time_to_qn(arrange_start) or 0.0
    local arrange_end_qn = time_to_qn(arrange_end) or (arrange_start_qn + (state.seq_grid_qn or 0.25) * 16.0)
    state.seq_view_start_qn = arrange_start_qn
    state.seq_view_span_qn = math.max(state.seq_grid_qn or 0.25, arrange_end_qn - arrange_start_qn)
    save_config()
  end

  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  -- Reserve layout space without creating an active hit-test item that can
  -- steal clicks from overlaid lane controls (hot-swap/nav widgets).
  r.ImGui_Dummy(ctx, width, map_h)
  local left_clicked = r.ImGui_IsMouseClicked(ctx, 0)
  local right_clicked = r.ImGui_IsMouseClicked(ctx, 1)
  local left_down = r.ImGui_IsMouseDown(ctx, 0)
  local right_down = r.ImGui_IsMouseDown(ctx, 1)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local window_hovered = false
  if r.ImGui_IsWindowHovered then
    local hover_flags = 0
    if r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem then
      hover_flags = r.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem()
    end
    window_hovered = r.ImGui_IsWindowHovered(ctx, hover_flags)
  else
    window_hovered = true
  end
  local hovered = window_hovered
    and mx >= x0 and mx <= x0 + width
    and my >= y0 and my <= y0 + map_h

  local view_start, view_end = get_arrange_view_range()
  local arrange_start_qn = time_to_qn(view_start) or 0.0
  local arrange_end_qn = time_to_qn(view_end) or (arrange_start_qn + (state.seq_grid_qn or 0.25) * 16.0)
  local arrange_span_qn = math.max(state.seq_grid_qn or 0.25, arrange_end_qn - arrange_start_qn)
  if state.seq_follow_arrange or not state.seq_view_start_qn then
    state.seq_view_start_qn = arrange_start_qn
    state.seq_view_span_qn = arrange_span_qn
  elseif not state.seq_view_span_qn or state.seq_view_span_qn <= 0 then
    state.seq_view_span_qn = get_seq_region_length_qn(region)
  end

  local start_qn, end_qn, step_qn, step_count = get_visible_qn_grid_range(
    state.seq_view_start_qn,
    state.seq_view_start_qn + (state.seq_view_span_qn or get_seq_region_length_qn(region))
  )
  local qn_span = math.max(step_qn, end_qn - start_qn)
  local label_w = math.min(300.0, math.max(220.0, width * 0.32))
  local timeline_x0 = x0 + label_w
  local timeline_w = math.max(120.0, width - label_w)

  -- Floating "keep pattern?" confirmation bar geometry. Computed up-front so we
  -- can suppress grid interactions underneath it (otherwise clicking the tick
  -- would also toggle a note in the cell below).
  local show_confirm = state.seq_pattern_confirm and state.seq_pattern_confirm.active
  local cb_x0, cb_y0, cb_x1, cb_y1
  if show_confirm then
    local cb_h = 34.0
    local cb_w = 240.0
    local confirm_region = region
    if state.seq_pattern_confirm.region_id then
      confirm_region = get_seq_region_by_id(state.seq_pattern_confirm.region_id) or region
    end
    if confirm_region then
      local reg_start = confirm_region.start_qn or 0.0
      local reg_end = reg_start + get_seq_region_length_qn(confirm_region)
      local rx0 = math.max(timeline_x0, timeline_x0 + ((reg_start - start_qn) / qn_span) * timeline_w)
      local rx1 = math.min(timeline_x0 + timeline_w, timeline_x0 + ((reg_end - start_qn) / qn_span) * timeline_w)
      if rx1 > rx0 + 48.0 then
        cb_w = math.min(cb_w, rx1 - rx0 - 8.0)
        cb_x0 = rx0 + math.max(0.0, (rx1 - rx0 - cb_w) * 0.5)
      else
        cb_x0 = timeline_x0 + math.max(0.0, (timeline_w - cb_w) * 0.5)
      end
    else
      cb_x0 = timeline_x0 + math.max(0.0, (timeline_w - cb_w) * 0.5)
    end
    -- Sit just above the region's note grid (below the ruler), centered on the region span.
    cb_y0 = y0 + header_h - cb_h - 6.0
    cb_x1 = cb_x0 + cb_w
    cb_y1 = cb_y0 + cb_h
    if mx >= cb_x0 and mx <= cb_x1 and my >= cb_y0 and my <= cb_y1 then
      hovered = false
    end
  end

  if hovered then
    local wheel = r.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      if is_shift_down() then
        local zoom = state.seq_lane_zoom or 1.0
        state.seq_lane_zoom = math.max(0.5, math.min(3.0, zoom * math.exp(wheel * 0.15)))
        save_config()
      else
        state.seq_follow_arrange = false
        local base_span = state.seq_view_span_qn or qn_span
        if is_cmd_down() then
          local ratio = math.max(0.0, math.min(1.0, (mx - timeline_x0) / math.max(1.0, timeline_w)))
          local anchor = start_qn + base_span * ratio
          local new_span = math.max(step_qn * 8.0, math.min(step_qn * 4096.0, base_span * math.exp(-wheel * 0.2)))
          state.seq_view_start_qn = math.max(0.0, anchor - new_span * ratio)
          state.seq_view_span_qn = new_span
        else
          state.seq_view_start_qn = math.max(0.0, (state.seq_view_start_qn or start_qn) - wheel * step_qn * 8.0)
          state.seq_view_span_qn = base_span
        end
        start_qn, end_qn, step_qn, step_count = get_visible_qn_grid_range(state.seq_view_start_qn, state.seq_view_start_qn + state.seq_view_span_qn)
        qn_span = math.max(step_qn, end_qn - start_qn)
      end
    end
  end

  local cell_w = timeline_w / step_count
  local measure_guides = collect_measure_guides_qn(start_qn, end_qn, 1024)
  local active_cells = seq_build_visible_active_cells(start_qn, end_qn, step_qn, step_count)
  local selected_region_id = region.id
  local pattern = get_seq_pattern(region.pattern_id, true)
  local random_edit_region = state.seq_random_edit_region_id and get_seq_region_by_id(state.seq_random_edit_region_id) or nil
  local random_edit_pattern = random_edit_region and get_seq_pattern(random_edit_region.pattern_id, true) or nil
  local random_focus_prev = state.seq_random_active_key
  local random_focus_effective = random_focus_prev
  local random_focus_next = nil
  local random_overlay_text = nil
  local random_overlay_y = nil
  if state.seq_random_edit_region_id and not random_edit_region then
    state.seq_random_edit_region_id = nil
    state.seq_random_active_key = nil
  end
  local now_t = r.time_precise()
  prune_seq_note_anims(now_t)
  prune_seq_track_play_anims(now_t)

  local function qn_to_x(qn) return timeline_x0 + ((qn - start_qn) / qn_span) * timeline_w end
  local function label_for_step(step)
    local denom = math.floor((4.0 / step) + 0.5)
    if denom > 0 and math.abs(step - (4.0 / denom)) < 0.0001 then return "1/" .. tostring(denom) end
    return string.format("%.3f QN", step)
  end

  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + map_h, 0x111318FF, 6.0)
  r.ImGui_DrawList_AddRect(dl, x0, y0, x0 + width, y0 + map_h, 0x40516AFF, 6.0, 0, 1.2)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + header_h, 0x202838FF, 0)
  r.ImGui_DrawList_AddRectFilled(dl, timeline_x0, y0, timeline_x0 + timeline_w, y0 + region_lane_h, 0x161C28FF, 0)
  r.ImGui_DrawList_AddLine(dl, timeline_x0, y0 + region_lane_h, timeline_x0 + timeline_w, y0 + region_lane_h, 0x40516AFF, 1.0)
  r.ImGui_DrawList_AddLine(dl, timeline_x0, y0, timeline_x0, y0 + map_h, 0x70829CFF, 1.5)
  r.ImGui_DrawList_AddLine(dl, timeline_x0, y0 + header_h, timeline_x0 + timeline_w, y0 + header_h, 0x607086FF, 2.0)
  r.ImGui_DrawList_AddText(dl, x0 + 8, y0 + region_lane_h + 7, 0xE8E8E8FF, "Track / Sample")

  local measure_y0 = y0 + region_lane_h
  local measure_line_clr = 0x5A7A9840
  local measure_label_clr = 0x90A8C888
  for i, guide in ipairs(measure_guides) do
    local px = qn_to_x(guide.qn_start)
    if px >= timeline_x0 - 1 and px <= timeline_x0 + timeline_w + 1 then
      local next_guide = measure_guides[i + 1]
      local measure_px = next_guide and math.abs(qn_to_x(next_guide.qn_start) - px) or (4.0 / qn_span) * timeline_w
      local show_every = 1
      if measure_px < 12 then
        show_every = 32
      elseif measure_px < 20 then
        show_every = 16
      elseif measure_px < 35 then
        show_every = 8
      elseif measure_px < 60 then
        show_every = 4
      elseif measure_px < 95 then
        show_every = 2
      end
      local measure_num = guide.measure + 1
      if ((measure_num - 1) % show_every) == 0 then
        r.ImGui_DrawList_AddLine(dl, px, measure_y0, px, y0 + map_h, measure_line_clr, 1.0)
        r.ImGui_DrawList_AddText(dl, px + 4, measure_y0 + 7, measure_label_clr, tostring(measure_num))
      end
    end
  end

  -- Region blocks live above the ruler and align to the sequencer timeline.
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if reg_end >= start_qn and reg_start <= end_qn then
      local rx0 = math.max(timeline_x0, qn_to_x(reg_start))
      local rx1 = math.min(timeline_x0 + timeline_w, qn_to_x(reg_end))
      local selected = reg.id == region.id
      local linked = seq_region_is_linked(reg)
      local fill = seq_region_pool_color(reg.pool_id, selected and 220 or 145)
      local edge = selected and 0xFFFFFFFF or seq_region_pool_color(reg.pool_id, 230)
      r.ImGui_DrawList_AddRectFilled(dl, rx0 + 1, y0 + 3, rx1 - 1, y0 + region_lane_h - 3, fill, 4.0)
      r.ImGui_DrawList_AddRect(dl, rx0 + 1, y0 + 3, rx1 - 1, y0 + region_lane_h - 3, edge, 4.0, 0, selected and 1.6 or 1.0)
      local label_x = rx0 + 6
      if linked then
        seq_draw_link_icon(dl, rx0 + 4, y0 + 4, 0xFFFFFFFF)
        label_x = rx0 + 6 + SEQ_LINK_ICON_SIZE
      end
      if rx1 - label_x > 24 then
        local label = reg.name or ("Region " .. reg.id)
        r.ImGui_DrawList_AddText(dl, label_x, y0 + 5, 0xFFFFFFFF, label)
      end
    end
  end

  if state.seq_region_drag and left_down then
    local drag = state.seq_region_drag
    local current_qn_raw = seq_x_to_qn(mx, timeline_x0, timeline_w, start_qn, qn_span)
    local current_qn = seq_snap_qn_for_region_drag(current_qn_raw, step_qn)
    local function begin_region_drag_undo()
      if not drag.undo_started then
        begin_seq_undo(drag.undo_label or "Edit sequencer region")
        drag.undo_started = true
      end
    end
    if drag.mode == "move" then
      local reg = get_seq_region_by_id(drag.region_id)
      if reg then
        local anchor_qn_raw = drag.anchor_qn_raw or drag.anchor_qn or current_qn_raw
        local desired = drag.orig_start_qn + (current_qn_raw - anchor_qn_raw)
        desired = seq_snap_qn_for_region_move(desired, step_qn)
        if seq_move_region_to(reg, desired) then
          begin_region_drag_undo()
          seq_select_region(reg)
          region = reg
        end
      end
    elseif drag.mode == "pool_copy" then
      drag.current_start_qn = seq_snap_qn_for_region_drag(current_qn_raw - (drag.anchor_offset_qn or 0.0), step_qn)
    elseif drag.mode == "resize_left" then
      local reg = get_seq_region_by_id(drag.region_id)
      if reg and seq_resize_region_start(reg, current_qn, step_qn) then
        begin_region_drag_undo()
        seq_select_region(reg)
        region = reg
      end
    elseif drag.mode == "resize_right" then
      local reg = get_seq_region_by_id(drag.region_id)
      if reg and seq_resize_region_end(reg, current_qn, step_qn) then
        begin_region_drag_undo()
        seq_select_region(reg)
        region = reg
      end
    elseif drag.mode == "create" then
      drag.current_qn = current_qn
    end
  end

  if state.seq_region_drag then
    local drag = state.seq_region_drag
    if drag.mode == "pool_copy" and drag.current_start_qn then
      local src = get_seq_region_by_id(drag.source_region_id)
      if src then
        local ghost_start = drag.current_start_qn
        local ghost_end = ghost_start + get_seq_region_length_qn(src)
        local gx0 = math.max(timeline_x0, qn_to_x(ghost_start))
        local gx1 = math.min(timeline_x0 + timeline_w, qn_to_x(ghost_end))
        local ghost_fill = seq_region_pool_color(src.pool_id, 90)
        local ghost_edge = seq_region_pool_color(src.pool_id, 200)
        r.ImGui_DrawList_AddRectFilled(dl, gx0 + 1, y0 + 3, gx1 - 1, y0 + region_lane_h - 3, ghost_fill, 4.0)
        r.ImGui_DrawList_AddRect(dl, gx0 + 1, y0 + 3, gx1 - 1, y0 + region_lane_h - 3, ghost_edge, 4.0, 0, 1.2)
      end
    elseif drag.mode == "create" and drag.start_qn and drag.current_qn then
      local create_start = math.min(drag.start_qn, drag.current_qn)
      local create_end = math.max(drag.start_qn, drag.current_qn)
      if create_end - create_start < step_qn then
        create_end = create_start + (drag.default_length_qn or get_seq_region_length_qn({ start_qn = create_start, length_bars = 4 }))
      end
      local cx0 = math.max(timeline_x0, qn_to_x(create_start))
      local cx1 = math.min(timeline_x0 + timeline_w, qn_to_x(create_end))
      r.ImGui_DrawList_AddRectFilled(dl, cx0 + 1, y0 + 3, cx1 - 1, y0 + region_lane_h - 3, 0x4A8BD688, 3.0)
      r.ImGui_DrawList_AddRect(dl, cx0 + 1, y0 + 3, cx1 - 1, y0 + region_lane_h - 3, 0x4A8BD6FF, 3.0, 0, 1.2)
    end
  end

  if hovered and not state.seq_region_drag and mx >= timeline_x0 and mx <= timeline_x0 + timeline_w and my >= y0 and my <= y0 + region_lane_h then
    local hover_hit = seq_hit_test_region_at(mx, my, y0, region_lane_h, timeline_x0, timeline_w, start_qn, qn_span, qn_to_x)
    if not hover_hit then
      local hover_qn = seq_snap_qn_for_region_drag(seq_x_to_qn(mx, timeline_x0, timeline_w, start_qn, qn_span), step_qn)
      local preview_start_qn, preview_len_qn = seq_get_default_create_region_qn(hover_qn, step_qn)
      local px0 = math.max(timeline_x0, qn_to_x(preview_start_qn))
      local px1 = math.min(timeline_x0 + timeline_w, qn_to_x(preview_start_qn + preview_len_qn))
      r.ImGui_DrawList_AddRectFilled(dl, px0 + 1, y0 + 3, px1 - 1, y0 + region_lane_h - 3, 0x4A8BD655, 3.0)
      r.ImGui_DrawList_AddRect(dl, px0 + 1, y0 + 3, px1 - 1, y0 + region_lane_h - 3, 0x4A8BD6DD, 3.0, 0, 1.0)
    end
  end

  if hovered and left_clicked and mx >= timeline_x0 and mx <= timeline_x0 + timeline_w then
    local clicked_qn_raw = seq_x_to_qn(mx, timeline_x0, timeline_w, start_qn, qn_span)
    local clicked_qn = seq_snap_qn_for_region_drag(clicked_qn_raw, step_qn)
    if my >= y0 and my <= y0 + region_lane_h then
      local hit = seq_hit_test_region_at(mx, my, y0, region_lane_h, timeline_x0, timeline_w, start_qn, qn_span, qn_to_x)
      if hit then
        if hit.part == "link" then
          local label = begin_seq_undo("Unlink sequencer region")
          seq_unpool_region(hit.region)
          end_seq_undo(label)
        elseif hit.part == "body" and is_alt_down() then
          local label = begin_seq_undo("Delete sequencer region")
          seq_delete_region_by_id(hit.region.id)
          end_seq_undo(label)
          region = get_selected_seq_region()
        elseif hit.part == "left_edge" then
          seq_select_region(hit.region)
          region = hit.region
          state.seq_region_drag = {
            mode = "resize_left",
            region_id = hit.region.id,
            undo_label = "Resize sequencer region",
            undo_started = false,
          }
        elseif hit.part == "right_edge" then
          seq_select_region(hit.region)
          region = hit.region
          state.seq_region_drag = {
            mode = "resize_right",
            region_id = hit.region.id,
            undo_label = "Resize sequencer region",
            undo_started = false,
          }
        elseif hit.part == "body" then
          if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
            state.seq_region_drag = nil
            state.selected_seq_region_id = hit.region.id
            seq_zoom_to_region(hit.region)
            region = hit.region
          else
            seq_select_region(hit.region)
            region = hit.region
            if is_ctrl_down() then
              state.seq_region_drag = {
                mode = "pool_copy",
                source_region_id = hit.region.id,
                anchor_offset_qn = clicked_qn - (hit.region.start_qn or 0.0),
                current_start_qn = hit.region.start_qn,
                length_bars = hit.region.length_bars,
                undo_label = "Pool copy sequencer region",
                start_mx = mx,
                start_my = my,
              }
            else
              state.seq_region_drag = {
                mode = "move",
                region_id = hit.region.id,
                anchor_qn = clicked_qn,
                anchor_qn_raw = clicked_qn_raw,
                orig_start_qn = hit.region.start_qn or 0.0,
                undo_label = "Move sequencer region",
                undo_started = false,
              }
            end
          end
        end
      else
        local create_start_qn, create_length_qn = seq_get_default_create_region_qn(clicked_qn, step_qn)
        state.seq_region_drag = {
          mode = "create",
          start_qn = create_start_qn,
          current_qn = create_start_qn,
          default_length_qn = create_length_qn,
          undo_label = "Create sequencer region",
          start_mx = mx,
          start_my = my,
        }
      end
    elseif my > y0 + region_lane_h and my <= y0 + header_h then
      seq_set_playhead_qn(clicked_qn)
    end
  end

  if hovered and right_clicked and mx >= timeline_x0 and mx <= timeline_x0 + timeline_w and my >= y0 and my <= y0 + region_lane_h then
    local right_hit = seq_hit_test_region_at(mx, my, y0, region_lane_h, timeline_x0, timeline_w, start_qn, qn_span, qn_to_x)
    if right_hit and right_hit.region then
      if state.seq_random_edit_region_id == right_hit.region.id then
        state.seq_random_edit_region_id = nil
      else
        seq_select_region(right_hit.region)
        region = right_hit.region
        state.seq_random_edit_region_id = right_hit.region.id
      end
    end
  end

  -- Region ownership cues in the sequencer grid.
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if reg_end >= start_qn and reg_start <= end_qn then
      local rx0 = math.max(timeline_x0, qn_to_x(reg_start))
      local rx1 = math.min(timeline_x0 + timeline_w, qn_to_x(reg_end))
      local selected = reg.id == region.id
      local fill = seq_region_pool_color(reg.pool_id, selected and 42 or 22)
      local edge = seq_region_pool_color(reg.pool_id, selected and 255 or 150)
      r.ImGui_DrawList_AddRectFilled(dl, rx0, y0 + header_h, rx1, y0 + map_h, fill, 0)
      r.ImGui_DrawList_AddLine(dl, rx0, y0, rx0, y0 + map_h, edge, selected and 2.5 or 1.5)
      r.ImGui_DrawList_AddLine(dl, rx1, y0 + header_h, rx1, y0 + map_h, edge, selected and 2.0 or 1.0)
    end
  end

  local row_positions = {}
  local cursor_y = y0 + header_h
  for row_idx, row in ipairs(visual_rows) do
    local row_y0 = cursor_y
    local row_y1 = row_y0 + row.h
    row_positions[row_idx] = { y0 = row_y0, y1 = row_y1, row = row }
    cursor_y = row_y1

    local lane_style = get_seq_row_lane_style(row)
    local track_boundary = row.type == "note" and row_idx > 1

    r.ImGui_DrawList_AddRectFilled(dl, x0, row_y0, x0 + width, row_y1, lane_style.bg, 0)
    r.ImGui_DrawList_AddRectFilled(dl, timeline_x0, row_y0, timeline_x0 + timeline_w, row_y1, lane_style.timeline_bg or lane_style.bg, 0)
    r.ImGui_DrawList_AddRectFilled(dl, x0, row_y0, timeline_x0 - 1, row_y1, lane_style.label_bg or lane_style.bg, 0)
    r.ImGui_DrawList_AddRectFilled(dl, x0, row_y0, x0 + 4, row_y1, lane_style.accent or 0xAFC6E8FF, 0)
    r.ImGui_DrawList_AddLine(dl, x0, row_y0, x0 + width, row_y0, lane_style.edge, 1.0)
    r.ImGui_DrawList_AddLine(dl, timeline_x0, row_y0, timeline_x0 + timeline_w, row_y0, lane_style.edge, 1.0)
    r.ImGui_DrawList_AddLine(dl, x0, row_y1, x0 + width, row_y1, lane_style.edge, 1.5)
    r.ImGui_DrawList_AddLine(dl, timeline_x0, row_y1, timeline_x0 + timeline_w, row_y1, lane_style.edge, 1.5)
    if track_boundary then
      r.ImGui_DrawList_AddLine(dl, x0, row_y0, x0 + width, row_y0, 0x8090A8FF, 2.5)
    end
    if row.type == "note" then
      local next_row = visual_rows[row_idx + 1]
      if next_row and next_row.type == "param" then
        r.ImGui_DrawList_AddLine(dl, x0, row_y1, x0 + width, row_y1, 0x607088FF, 2.0)
      end
    end

    local slot = row.slot
    if row.type == "note" and slot then
      local expanded = state.seq_expanded_tracks[tostring(slot.id)] == true
      local exp_label = expanded and "[-]" or "[+]"
      local play_anim = get_seq_track_play_anim(slot.id, now_t)
      if play_anim then
        local assigned_sample = slot.sample_path and find_sample_by_path(slot.sample_path) or nil
        draw_seq_track_play_row_fx(dl, x0, row_y0, timeline_x0 - 1, row_y1, play_anim.t, assigned_sample)
      end
      local name_alpha = play_anim and math.floor(180 + math.sin(play_anim.t * math.pi) * 75) or 255
      r.ImGui_DrawList_AddText(dl, x0 + 8, row_y0 + 6, 0xFFDFAAFF, exp_label)
      r.ImGui_DrawList_AddText(dl, x0 + 36, row_y0 + 6, build_color_rrgbbaa(255, 255, 255, name_alpha), slot.name or ("Track " .. row_idx))

      for col = 0, step_count - 1 do
        local cx0 = timeline_x0 + col * cell_w
        local cx1 = cx0 + cell_w
        if col % 2 == 1 then
          r.ImGui_DrawList_AddRectFilled(dl, cx0, row_y0, cx1, row_y1, seq_lane_color_with_alpha(lane_style.accent, 16), 0)
        end
        local active = active_cells[slot.id] and active_cells[slot.id][col]
        local cell_reg = active and seq_region_at_qn(start_qn + col * step_qn) or region
        local step_key_for_col = active and active.key or tostring(math.floor((((start_qn + col * step_qn) - (cell_reg.start_qn or 0.0)) / step_qn) + 0.5))
        if active then
          local note = active.note
          local cell_selected = active.region_id == selected_region_id
          local note_fx = get_seq_note_anim(active.region_id, slot.id, active.key or step_key_for_col, now_t)
          local fx_t = note_fx and note_fx.t or 1.0
          local resolved_path, resolved_sample = resolve_seq_note_sample(note, slot)
          local base = get_sample_dot_color(resolved_sample or find_sample_by_path(resolved_path or note.sample_path or slot.sample_path))
          local note_len = snap_seq_length_qn(note.length_qn or step_qn, step_qn)
          local note_off = note.offset_qn or 0.0
          local cell_inner_w = cell_w - 4
          local draw_x0 = cx0 + 2 + (note_off / step_qn) * cell_w
          local draw_w = math.max(6.0, (note_len / step_qn) * cell_inner_w)
          local draw_x1 = draw_x0 + draw_w
          local row_pad = 4.0
          -- Notes always render full height; pitch morphs shape from circle/pill to diamond.
          local block_y0 = row_y0 + row_pad
          local block_y1 = row_y1 - row_pad
          local note_alpha = cell_selected and 235 or 90
          local border_alpha = cell_selected and 205 or 70
          if note_fx and note_fx.kind == "add" then
            local pulse = math.sin(fx_t * math.pi)
            local scale_x = 0.78 + fx_t * 0.22 + pulse * 0.12
            local scale_y = 0.66 + fx_t * 0.34 + pulse * 0.18
            draw_x0, block_y0, draw_x1, block_y1 = scale_rect_about_center(draw_x0, block_y0, draw_x1, block_y1, scale_x, scale_y, 0.0)
            draw_w = draw_x1 - draw_x0
            note_alpha = math.floor((cell_selected and (120 + fx_t * 115) or (45 + fx_t * 45)))
            border_alpha = math.floor((cell_selected and (90 + fx_t * 150) or (35 + fx_t * 50)))
          end
          local block_h = block_y1 - block_y0

          local br, bg, bb = extract_rgb_rrgbbaa(base)
          local body_color = build_color_rrgbbaa(br, bg, bb, note_alpha)
          r.ImGui_DrawList_AddRectFilled(dl, draw_x0, block_y0, draw_x1, block_y1, body_color, 0)
          r.ImGui_DrawList_AddRect(dl, draw_x0, block_y0, draw_x1, block_y1, build_color_rrgbbaa(255, 255, 255, border_alpha), 0, 0, 1.0)

          local stutter_count = seq_stutter_count(note)
          if stutter_count > 1 then
            local slice_qn = step_qn / stutter_count
            local stut_x0 = cx0 + 2 + (note_off / step_qn) * cell_w
            local div_alpha = math.max(70, math.floor(border_alpha * 0.70))
            local pulse_alpha = math.max(90, math.floor(border_alpha * 0.85))
            local div_col = build_color_rrgbbaa(255, 255, 255, div_alpha)
            local pulse_col = build_color_rrgbbaa(255, 255, 255, pulse_alpha)
            for si = 1, stutter_count - 1 do
              local sx = stut_x0 + (si * slice_qn / step_qn) * cell_w
              if sx > draw_x0 + 1 and sx < draw_x1 - 1 then
                r.ImGui_DrawList_AddLine(dl, sx, block_y0 + 1, sx, block_y1 - 1, div_col, 1.0)
              elseif sx > cx0 + 1 and sx < cx1 - 1 then
                -- If note length is short, still show stutter steps in-cell.
                r.ImGui_DrawList_AddLine(dl, sx, block_y1 - 5, sx, block_y1 - 1, div_col, 1.0)
              end
            end
            for si = 0, stutter_count - 1 do
              local sx = stut_x0 + (si * slice_qn / step_qn) * cell_w
              if sx > cx0 + 1 and sx < cx1 - 1 then
                local px0 = sx + 0.5
                local px1 = math.min(px0 + 1.8, cx1 - 1)
                r.ImGui_DrawList_AddRectFilled(dl, px0, block_y0 + 1, px1, block_y0 + 3.5, pulse_col, 0.5)
              end
            end
          end

          local gauges_fit = draw_w >= 14.0

          -- Volume: left vertical gauge filled bottom-up (0..2, default 1 = mid).
          local vol = math.max(0.0, math.min(2.0, note.volume or 1.0))
          local vol_t = vol / 2.0
          local gx0 = draw_x0 + 2
          local gx1 = gx0 + 3
          r.ImGui_DrawList_AddRectFilled(dl, gx0, block_y0 + 2, gx1, block_y1 - 2, 0x00000055, 1.0)
          local vol_top = block_y1 - 2 - vol_t * math.max(1.0, (block_h - 4))
          r.ImGui_DrawList_AddRectFilled(dl, gx0, vol_top, gx1, block_y1 - 2, 0xFFFFFFFF, 1.0)

          if gauges_fit then
            -- Pitch: right vertical gauge with center origin; up = amber, down = blue.
            local pitch = math.max(-24.0, math.min(24.0, note.pitch or 0.0))
            local pitch_t = (pitch + 24.0) / 48.0
            local px1 = draw_x1 - 2
            local px0 = px1 - 3
            local mid_y = (block_y0 + block_y1) * 0.5
            r.ImGui_DrawList_AddRectFilled(dl, px0, block_y0 + 2, px1, block_y1 - 2, 0x00000055, 1.0)
            r.ImGui_DrawList_AddLine(dl, px0, mid_y, px1, mid_y, 0xFFFFFF66, 1.0)
            local pitch_y = (block_y1 - 2) - pitch_t * math.max(1.0, (block_h - 4))
            local pitch_color = pitch >= 0.0 and 0xFFB84DFF or 0x58B7FFFF
            if pitch >= 0 then
              r.ImGui_DrawList_AddRectFilled(dl, px0, pitch_y, px1, mid_y, pitch_color, 1.0)
            else
              r.ImGui_DrawList_AddRectFilled(dl, px0, mid_y, px1, pitch_y, pitch_color, 1.0)
            end
          end

          -- Pan: top horizontal gauge with center tick and a position marker.
          local pan = math.max(-1.0, math.min(1.0, note.pan or 0.0))
          local pan_track_x0 = draw_x0 + 6
          local pan_track_x1 = draw_x1 - (gauges_fit and 6 or 2)
          if pan_track_x1 > pan_track_x0 + 2 then
            local pan_y = block_y0 + 3
            r.ImGui_DrawList_AddLine(dl, pan_track_x0, pan_y, pan_track_x1, pan_y, 0x00000077, 1.0)
            local pan_cx = (pan_track_x0 + pan_track_x1) * 0.5
            r.ImGui_DrawList_AddLine(dl, pan_cx, pan_y - 2, pan_cx, pan_y + 2, 0xFFFFFF66, 1.0)
            local pan_x = pan_track_x0 + ((pan + 1.0) * 0.5) * (pan_track_x1 - pan_track_x0)
            r.ImGui_DrawList_AddRectFilled(dl, pan_x - 1.5, pan_y - 2.5, pan_x + 1.5, pan_y + 2.5, 0xFFFFFFFF, 1.0)
          end
        else
          local note_fx = get_seq_note_anim(region.id, slot.id, step_key_for_col, now_t)
          if note_fx and note_fx.kind == "delete" and note_fx.note then
            local note = note_fx.note
            local resolved_path, resolved_sample = resolve_seq_note_sample(note, slot)
            local base = get_sample_dot_color(resolved_sample or find_sample_by_path(resolved_path or note.sample_path or slot.sample_path))
            local note_len = snap_seq_length_qn(note.length_qn or step_qn, step_qn)
            local note_off = note.offset_qn or 0.0
            local cell_inner_w = cell_w - 4
            local draw_x0 = cx0 + 2 + (note_off / step_qn) * cell_w
            local draw_w = math.max(6.0, (note_len / step_qn) * cell_inner_w)
            local draw_x1 = draw_x0 + draw_w
            local row_pad = 4.0
            local block_y0 = row_y0 + row_pad
            local block_y1 = row_y1 - row_pad
            local t = note_fx.t or 0.0
            local scale_x = 1.0 + t * 0.42
            local scale_y = math.max(0.3, 1.0 - t * 0.60)
            local drift_y = -5.0 * t
            draw_x0, block_y0, draw_x1, block_y1 = scale_rect_about_center(draw_x0, block_y0, draw_x1, block_y1, scale_x, scale_y, drift_y)
            local fade = math.floor(230 * ((1.0 - t) ^ 1.2))
            local edge_fade = math.floor(190 * ((1.0 - t) ^ 1.0))
            local br, bg, bb = extract_rgb_rrgbbaa(base)
            local ghost_fill = build_color_rrgbbaa(br, bg, bb, fade)
            local ghost_edge = build_color_rrgbbaa(255, 255, 255, edge_fade)
            r.ImGui_DrawList_AddRectFilled(dl, draw_x0, block_y0, draw_x1, block_y1, ghost_fill, 0)
            r.ImGui_DrawList_AddRect(dl, draw_x0, block_y0, draw_x1, block_y1, ghost_edge, 0, 0, 1.0)
            local glow_alpha = math.floor(130 * ((1.0 - t) ^ 2.0))
            if glow_alpha > 0 then
              r.ImGui_DrawList_AddRect(dl, draw_x0 - 1.5, block_y0 - 1.5, draw_x1 + 1.5, block_y1 + 1.5, build_color_rrgbbaa(br, bg, bb, glow_alpha), 0, 0, 1.2)
            end
          end
        end
      end
    elseif row.type == "param" and slot and row.param then
      local def = row.param
      local lane_top = row_y0 + 2
      local lane_bot = row_y1 - 2
      local is_stutter_lane = def.key == "stutter"
      local bipolar = def.min < 0
      r.ImGui_DrawList_AddText(dl, x0 + 36, row_y0 + 3, lane_style.accent or 0xAFC6E8FF, def.label)

      -- Baseline / zero reference for the lane.
      local base_y = lane_bot
      if not is_stutter_lane then
        if bipolar then
          base_y = seq_param_y_from_value(def, 0.0, lane_top, lane_bot, step_qn)
          r.ImGui_DrawList_AddLine(dl, timeline_x0, base_y, timeline_x0 + timeline_w, base_y, seq_lane_color_with_alpha(lane_style.accent, 90), 1.0)
        else
          r.ImGui_DrawList_AddLine(dl, timeline_x0, lane_bot, timeline_x0 + timeline_w, lane_bot, seq_lane_color_with_alpha(lane_style.accent, 90), 1.0)
        end
      end

      for col = 0, step_count - 1 do
        local cx0 = timeline_x0 + col * cell_w
        local cx1 = cx0 + cell_w
        if col % 2 == 1 then
          r.ImGui_DrawList_AddRectFilled(dl, cx0, row_y0, cx1, row_y1, seq_lane_color_with_alpha(lane_style.accent, 16), 0)
        end
        local active = active_cells[slot.id] and active_cells[slot.id][col]
        if active then
          local cell_selected = active.region_id == selected_region_id
          local value = active.note[def.key]
          if value == nil then value = def.default end
          if def.key == "length_qn" then
            value = snap_seq_length_qn(value, step_qn)
          elseif def.key == "stutter" then
            value = seq_param_value_for_drag(def, value, step_qn)
          end

          if is_stutter_lane then
            local accent = cell_selected and lane_style.accent or seq_lane_color_with_alpha(lane_style.accent, 100)
            draw_seq_stutter_lane_cell(dl, ctx, cx0, cx1, lane_top, lane_bot, value, accent)
          else
            local py = seq_param_y_from_value(def, value, lane_top, lane_bot, step_qn)
            local fill_x0 = cx0 + 2
            local fill_x1 = cx1 - 2
            if fill_x1 <= fill_x0 then fill_x1 = fill_x0 + 1 end
            local top_y = math.min(py, base_y)
            local bot_y = math.max(py, base_y)
            if math.abs(bot_y - top_y) < 2 then
              top_y = math.min(top_y, bot_y - 2)
            end
            local fill_col, cap_col = seq_lane_param_fill_colors(lane_style.accent, bipolar, value)
            if not cell_selected then
              fill_col = seq_dim_color_rrgbbaa(fill_col, true)
              cap_col = seq_dim_color_rrgbbaa(cap_col, true)
            end
            r.ImGui_DrawList_AddRectFilled(dl, fill_x0, top_y, fill_x1, bot_y, fill_col, 2.0)
            local cap_y = (py <= base_y) and top_y or bot_y
            r.ImGui_DrawList_AddRectFilled(dl, fill_x0, cap_y - 1, fill_x1, cap_y + 1, cap_col, 1.0)
          end
        end
      end
    else
      r.ImGui_DrawList_AddText(dl, x0 + 8, row_y0 + 8, 0x888888FF, "No sequencer tracks configured")
    end
  end

  local slot_id_to_idx = {}
  for track_idx, track_slot in ipairs(state.seq_tracks) do
    slot_id_to_idx[track_slot.id] = track_idx
  end
  local map_ctrl_size = 16.0
  local map_nav_w = get_seq_track_sample_controls_width(map_ctrl_size)
  local label_track_click_x1 = timeline_x0 - map_nav_w - 4

  local add_row_y0 = y0 + header_h + rows_h
  local add_row_y1 = add_row_y0 + add_track_row_h
  local label_col_w = timeline_x0 - x0
  r.ImGui_DrawList_AddRectFilled(dl, x0, add_row_y0, timeline_x0 - 1, add_row_y1, 0x161C28FF, 0)
  r.ImGui_DrawList_AddRectFilled(dl, timeline_x0, add_row_y0, timeline_x0 + timeline_w, add_row_y1, 0x111318FF, 0)
  r.ImGui_DrawList_AddLine(dl, x0, add_row_y0, x0 + width, add_row_y0, 0x607086FF, 1.5)
  r.ImGui_DrawList_AddLine(dl, x0, add_row_y1, x0 + width, add_row_y1, 0x40516AFF, 1.0)

  -- Draw visible region ownership again over row backgrounds so users can see which
  -- cells belong to each selected/copy/pooled region.
  for _, reg in ipairs(state.seq_regions) do
    local reg_start = reg.start_qn or 0.0
    local reg_end = reg_start + get_seq_region_length_qn(reg)
    if reg_end >= start_qn and reg_start <= end_qn then
      local rx0 = math.max(timeline_x0, qn_to_x(reg_start))
      local rx1 = math.min(timeline_x0 + timeline_w, qn_to_x(reg_end))
      local selected = reg.id == region.id
      local fill = seq_region_pool_color(reg.pool_id, selected and 32 or 16)
      local edge = seq_region_pool_color(reg.pool_id, selected and 255 or 170)
      r.ImGui_DrawList_AddRectFilled(dl, rx0, y0 + header_h, rx1, y0 + map_h, fill, 0)
      r.ImGui_DrawList_AddLine(dl, rx0, y0, rx0, y0 + map_h, edge, selected and 2.5 or 1.5)
      r.ImGui_DrawList_AddLine(dl, rx1, y0 + header_h, rx1, y0 + map_h, edge, selected and 2.0 or 1.0)
    end
  end

  for col = 0, step_count do
    local qn = start_qn + col * step_qn
    local px = qn_to_x(qn)
    local clr = (math.abs(qn - math.floor(qn + 0.5)) < 0.0001) and 0x45505EFF or 0x2A303AFF
    r.ImGui_DrawList_AddLine(dl, px, y0 + header_h, px, y0 + map_h, clr, 1.0)
  end

  local hovered_slot, hovered_col, hovered_qn, hovered_row = nil, nil, nil, nil
  local param_drag_active = state.seq_param_drag and left_down and state.seq_param_drag.region_id == region.id
  if hovered and mx >= timeline_x0 and mx <= timeline_x0 + timeline_w and my >= y0 + header_h and my <= y0 + map_h then
    for _, row_pos in ipairs(row_positions) do
      if my >= row_pos.y0 and my <= row_pos.y1 then
        hovered_row = row_pos
        hovered_slot = row_pos.row.slot
        break
      end
    end
    if hovered_slot then
      hovered_col = math.max(0, math.min(step_count - 1, math.floor((mx - timeline_x0) / cell_w)))
      hovered_qn = start_qn + hovered_col * step_qn
      local hover_in_selected = hovered_qn >= region.start_qn and hovered_qn < region.start_qn + get_seq_region_length_qn(region)
      if not param_drag_active and hover_in_selected then
        local hx0 = timeline_x0 + hovered_col * cell_w
        r.ImGui_DrawList_AddRectFilled(dl, hx0, hovered_row.y0, hx0 + cell_w, hovered_row.y1, 0xFFE59933, 0)
        r.ImGui_DrawList_AddRect(dl, hx0, hovered_row.y0, hx0 + cell_w, hovered_row.y1, 0xFFE599FF, 0, 0, 1.5)
      end
    end
  end

  local over_lane_random_controls = false
  if random_edit_region and hovered_row and hovered_row.row and hovered_row.row.type == "note" then
    over_lane_random_controls = seq_lane_random_controls_hit(hovered_row, mx, my, timeline_x0)
  end

  if hovered and left_clicked and mx >= x0 + 8 and mx <= x0 + 30 then
    for _, row_pos in ipairs(row_positions) do
      if row_pos.row.type == "note" and row_pos.row.slot and my >= row_pos.y0 and my <= row_pos.y1 then
        local key = tostring(row_pos.row.slot.id)
        state.seq_expanded_tracks[key] = not state.seq_expanded_tracks[key] or nil
        save_config()
        break
      end
    end
  end

  if hovered and left_clicked and not state.pending_waveform_drop and mx >= x0 + 31 and mx < label_track_click_x1 then
    for _, row_pos in ipairs(row_positions) do
      if row_pos.row.type == "note" and row_pos.row.slot and my >= row_pos.y0 and my <= row_pos.y1 then
        local track_idx = slot_id_to_idx[row_pos.row.slot.id]
        if track_idx then
          select_seq_track(track_idx)
        end
        break
      end
    end
  end

  if hovered_slot and hovered_qn and hovered_row and not state.seq_region_drag and not over_lane_random_controls then
    local step_idx = math.floor(((hovered_qn - region.start_qn) / step_qn) + 0.5)
    local in_region = hovered_qn >= region.start_qn and hovered_qn < region.start_qn + get_seq_region_length_qn(region)
    local step_key = tostring(step_idx)
    local cell_id = tostring(hovered_slot.id) .. ":" .. step_key
    local active = active_cells[hovered_slot.id] and active_cells[hovered_slot.id][hovered_col]

    if hovered_row.row.type == "param" and hovered_row.row.param and in_region and left_clicked and mx >= timeline_x0 then
      local def = hovered_row.row.param
      local start_value = def.default
      if active then
        start_value = active.note[def.key]
        if start_value == nil then
          start_value = def.default
        end
      else
        start_value = seq_param_value_for_drag(def, seq_param_value_from_y(def, my, hovered_row.y0 + 2, hovered_row.y1 - 2, step_qn), step_qn)
      end
      state.seq_param_drag = {
        track_id = hovered_slot.id,
        param = def.key,
        region_id = region.id,
        step_key = active and active.key or step_key,
        col = hovered_col,
        end_col = hovered_col,
        ramp = is_shift_down(),
        unify = is_alt_down() and not is_shift_down(),
        start_value = start_value,
      }
      if active then
        state.selected_seq_note = { region_id = region.id, track_id = hovered_slot.id, step_key = active.key }
      end
    elseif state.pending_waveform_drop then
      local track_idx = hovered_slot and slot_id_to_idx[hovered_slot.id]
      state.seq_timeline_drop_track_idx = track_idx
      state.seq_timeline_drop_time = qn_to_time(hovered_qn)
      state.seq_drop_target_idx = nil
      -- Highlight the cell under the cursor and draw an insertion marker so the
      -- exact drop position on the timeline is obvious.
      local cell_x0 = timeline_x0 + hovered_col * cell_w
      draw_drop_target_highlight(dl, cell_x0, hovered_row.y0, cell_x0 + cell_w, hovered_row.y1, 2)
      local pulse = drag_pulse()
      local line_col = build_color_rrgbbaa(120, 200, 255, math.floor(170 + 85 * pulse))
      r.ImGui_DrawList_AddLine(dl, cell_x0, y0 + header_h, cell_x0, y0 + map_h, line_col, 2.0)
      r.ImGui_DrawList_AddTriangleFilled(dl, cell_x0 - 5, y0 + header_h, cell_x0 + 5, y0 + header_h, cell_x0, y0 + header_h + 7, line_col)
    elseif hovered_row.row.type == "note" and r.ImGui_IsMouseDoubleClicked(ctx, 0) and mx >= timeline_x0 then
      local hover_reg = seq_region_at_qn(hovered_qn)
      if hover_reg then
        state.seq_region_drag = nil
        state.selected_seq_region_id = hover_reg.id
        seq_zoom_to_region(hover_reg)
        region = hover_reg
        selected_region_id = region.id
      end
    elseif hovered_row.row.type == "note" and not in_region and left_clicked and mx >= timeline_x0 then
      local hover_reg = seq_region_at_qn(hovered_qn)
      if hover_reg then
        seq_select_region(hover_reg)
        region = hover_reg
        selected_region_id = region.id
      end
    elseif hovered_row.row.type == "note" and in_region and (left_clicked or right_clicked) and mx >= timeline_x0 then
      local label = begin_seq_undo(left_clicked and "Toggle sequencer note" or "Erase sequencer note")
      toggle_seq_note(region, hovered_slot, step_key, hovered_qn - region.start_qn, right_clicked and "erase" or nil)
      end_seq_undo(label)
      state.seq_drag_paint = true
      state.seq_drag_mode = right_clicked and "erase" or "paint"
      state.seq_drag_last_cell = cell_id
    elseif hovered_row.row.type == "note" and in_region and state.seq_drag_paint and (left_down or right_down) and state.seq_drag_last_cell ~= cell_id then
      local label = begin_seq_undo(state.seq_drag_mode == "erase" and "Erase sequencer notes" or "Paint sequencer notes")
      toggle_seq_note(region, hovered_slot, step_key, hovered_qn - region.start_qn, state.seq_drag_mode)
      end_seq_undo(label)
      state.seq_drag_last_cell = cell_id
    end
  end

  param_drag_active = state.seq_param_drag and left_down and state.seq_param_drag.region_id == region.id
  if param_drag_active then
    local drag = state.seq_param_drag
    local def = get_param_lane_def(drag.param)
    local lane_y0, lane_y1, lane_row = find_seq_param_lane_bounds(row_positions, drag.track_id, drag.param)
    if def and lane_y0 and lane_row then
      if is_shift_down() and not drag.ramp then
        drag.ramp = true
        drag.unify = false
        local anchor = active_cells[drag.track_id] and active_cells[drag.track_id][drag.col]
        if anchor then
          drag.start_value = anchor.note[def.key]
          if drag.start_value == nil then
            drag.start_value = def.default
          end
        end
      elseif is_alt_down() and not drag.ramp and not drag.unify then
        drag.unify = true
      end

      local changed, current_value, highlight_col_min, highlight_col_max, mouse_col = apply_seq_param_lane_drag(
        drag, def, lane_y0, lane_y1, mx, my, step_qn, step_count, timeline_x0, cell_w, active_cells
      )
      if changed then
        save_config()
        sync_seq_pattern_regions(region.pattern_id)
      end

      local hx0 = timeline_x0 + highlight_col_min * cell_w
      local hx1 = timeline_x0 + (highlight_col_max + 1) * cell_w
      r.ImGui_DrawList_AddRectFilled(dl, hx0, lane_row.y0, hx1, lane_row.y1, 0xFFB84D44, 0)
      r.ImGui_DrawList_AddRect(dl, hx0, lane_row.y0, hx1, lane_row.y1, 0xFFB84DFF, 0, 0, 2.0)

      if drag.ramp then
        local lane_top = lane_row.y0 + 2
        local lane_bot = lane_row.y1 - 2
        local start_val = drag.start_value or def.default
        local x0 = timeline_x0 + drag.col * cell_w + cell_w * 0.5
        local x1 = timeline_x0 + drag.end_col * cell_w + cell_w * 0.5
        local y0 = seq_param_y_from_value(def, start_val, lane_top, lane_bot, step_qn)
        local y1 = seq_param_y_from_value(def, current_value, lane_top, lane_bot, step_qn)
        r.ImGui_DrawList_AddLine(dl, x0, y0, x1, y1, 0xFFFFFFFF, 2.0)
        r.ImGui_DrawList_AddCircleFilled(dl, x0, y0, 3.0, 0xFFFFFFFF, 12)
        r.ImGui_DrawList_AddCircleFilled(dl, x1, y1, 3.0, 0xFFFFFFFF, 12)
      end

      local value_text
      if drag.ramp and drag.end_col ~= drag.col then
        value_text = string.format("%s ramp %s -> %s",
          def.label,
          string.format(def.fmt, drag.start_value or def.default),
          string.format(def.fmt, current_value))
      elseif drag.unify then
        value_text = string.format("%s unify %s", def.label, string.format(def.fmt, current_value))
      else
        local hover_active = active_cells[drag.track_id] and active_cells[drag.track_id][mouse_col]
        if hover_active then
          value_text = format_seq_param_value(def, hover_active.note[def.key])
        else
          value_text = format_seq_param_value(def, current_value)
        end
      end
      local text_x = timeline_x0 + mouse_col * cell_w + 4
      local text_y = lane_row.y0 - 16
      local text_size = { r.ImGui_CalcTextSize(ctx, value_text) }
      local text_w = text_size[1] or 0
      local text_h = text_size[2] or 0
      r.ImGui_DrawList_AddRectFilled(dl, text_x - 3, text_y - 2, text_x + text_w + 3, text_y + text_h + 2, 0x000000CC, 3.0)
      r.ImGui_DrawList_AddRect(dl, text_x - 3, text_y - 2, text_x + text_w + 3, text_y + text_h + 2, 0xFFB84DFF, 3.0, 0, 1.0)
      r.ImGui_DrawList_AddText(dl, text_x, text_y, 0xFFFFFFFF, value_text)
    end
  end

  local mouse_released = r.ImGui_IsMouseReleased(ctx, 0) or r.ImGui_IsMouseReleased(ctx, 1)
  if r.ImGui_IsMouseReleased(ctx, 0) and state.seq_region_drag then
    local drag = state.seq_region_drag
    if drag.mode == "pool_copy" then
      local src = get_seq_region_by_id(drag.source_region_id)
      if src and drag.current_start_qn then
        local moved_qn = math.abs(drag.current_start_qn - (src.start_qn or 0.0)) >= step_qn * 0.25
        local moved_px = drag.start_mx and (math.abs(mx - drag.start_mx) > 4 or math.abs(my - drag.start_my) > 4)
        if moved_qn or moved_px then
          local label = begin_seq_undo(drag.undo_label or "Pool copy sequencer region")
          create_seq_region(drag.length_bars or src.length_bars, src, true, drag.current_start_qn)
          region = get_selected_seq_region()
          end_seq_undo(label)
        end
      end
    elseif drag.mode == "create" and drag.start_qn and drag.current_qn then
      local create_start = seq_snap_qn_for_region_drag(math.min(drag.start_qn, drag.current_qn), step_qn)
      local create_end = seq_snap_qn_for_region_drag(math.max(drag.start_qn, drag.current_qn), step_qn)
      local moved_px = drag.start_mx and (math.abs(mx - drag.start_mx) > 4 or math.abs(my - drag.start_my) > 4)
      local label = begin_seq_undo(drag.undo_label or "Create sequencer region")
      if not moved_px then
        create_seq_region(4, nil, false, drag.start_qn)
      elseif create_end - create_start < step_qn * 2 then
        create_seq_region(4, nil, false, create_start)
      else
        local bars = seq_qn_length_to_bars(create_start, create_end - create_start)
        create_seq_region(bars, nil, false, create_start)
      end
      region = get_selected_seq_region()
      end_seq_undo(label)
    elseif drag.undo_label and drag.undo_started then
      end_seq_undo(drag.undo_label)
    end
    state.seq_region_drag = nil
  end
  if mouse_released then
    state.seq_drag_paint = false
    state.seq_drag_mode = nil
    state.seq_drag_last_cell = nil
    state.seq_param_drag = nil
  end

  local playhead_time = seq_get_playhead_time()
  if playhead_time then
    local playhead_qn = time_to_qn(playhead_time)
    if playhead_qn and playhead_qn >= start_qn and playhead_qn <= end_qn then
      local playhead_x = qn_to_x(playhead_qn)
      if playhead_x >= timeline_x0 - 1 and playhead_x <= timeline_x0 + timeline_w + 1 then
        local playing = r.GetPlayState and (r.GetPlayState() & 1) == 1
        local playhead_color = playing and 0xFFFF88EE or 0xFFFF8866
        local playhead_thickness = playing and 2.0 or 1.5
        r.ImGui_DrawList_AddLine(dl, playhead_x, y0, playhead_x, y0 + map_h, playhead_color, playhead_thickness)
        r.ImGui_DrawList_AddCircleFilled(dl, playhead_x, y0 + region_lane_h + 6, 4.0, playhead_color, 12)
        r.ImGui_DrawList_AddCircleFilled(dl, playhead_x, y0 + map_h - 6, 3.0, playhead_color, 10)
      end
    end
  end

  for _, row_pos in ipairs(row_positions) do
    local row = row_pos.row
    if row.type == "note" and row.slot then
      local track_idx = slot_id_to_idx[row.slot.id]
      if track_idx then
        if random_edit_region and random_edit_pattern then
          local random_settings = get_seq_track_settings(random_edit_pattern, row.slot.id, true)
          if random_settings then
            local changed, active_key, overlay_text = seq_render_lane_random_controls(dl, row_pos, row.slot.id, random_settings, random_focus_effective, timeline_x0)
            if active_key then
              random_focus_next = active_key
              random_focus_effective = active_key
              random_overlay_text = overlay_text
              random_overlay_y = row_pos.y0
            end
            if changed then
              save_config()
              sync_seq_pattern_regions(random_edit_region.pattern_id)
            end
          end
        end
        r.ImGui_SetCursorScreenPos(
          ctx,
          timeline_x0 - map_nav_w - 4,
          row_pos.y0 + (row_pos.y1 - row_pos.y0 - map_ctrl_size) * 0.5
        )
        r.ImGui_PushID(ctx, "seq_lane_nav_" .. row.slot.id)
        local nav = render_seq_track_sample_controls(row.slot, track_idx, {
          id_suffix = "seq_map_" .. row.slot.id,
          ctrl_size = map_ctrl_size,
        })
        r.ImGui_PopID(ctx)
        if state.pending_waveform_drop then
          local row_drop_hovered = nav.row_drop_hovered
          if not row_drop_hovered and hovered and mx >= x0 and mx < timeline_x0
              and my >= row_pos.y0 and my <= row_pos.y1 then
            row_drop_hovered = true
          end
          if row_drop_hovered then
            state.seq_drop_target_idx = track_idx
            state.seq_timeline_drop_time = nil
            state.seq_timeline_drop_track_idx = nil
            draw_drop_target_highlight(dl, x0 + 1, row_pos.y0, timeline_x0 - 1, row_pos.y1, 3)
          end
        end
      end
    end
  end

  state.seq_random_active_key = random_focus_next
  if not random_edit_region then
    state.seq_random_active_key = nil
  end
  if random_overlay_text and random_overlay_y then
    local text_w, text_h = r.ImGui_CalcTextSize(ctx, random_overlay_text)
    local text_x = timeline_x0 + 8
    local text_y = random_overlay_y + 2
    r.ImGui_DrawList_AddRectFilled(dl, text_x - 3, text_y - 2, text_x + text_w + 4, text_y + text_h + 2, 0x00000088, 3.0)
    r.ImGui_DrawList_AddText(dl, text_x, text_y, 0xFFE7A6DD, random_overlay_text)
  end

  if show_confirm then
    render_seq_pattern_confirm_bar(dl, cb_x0, cb_y0, cb_x1, cb_y1)
  end

  r.ImGui_SetCursorScreenPos(ctx, x0, add_row_y0)
  if draw_ui_button("seq_add_track_popup_open_sequencer", nil, label_col_w, add_track_row_h, { icon = "plus", style = "primary" }) then
    open_seq_add_track_popup()
  end

  r.ImGui_Dummy(ctx, width, 0)

  render_seq_add_track_popup()
  r.ImGui_EndChild(ctx)

  render_seq_pattern_popup(region)
end


function render_view_tab_switcher()
  local icon_size = 26
  local btn_h = 34
  local pad_x = 12
  local icon_text_gap = 8
  local tab_gap = 8

  local function draw_sample_map_icon(dl, x0, y0, sz, color, accent)
    local pad = sz * 0.15
    local ix0 = x0 + pad
    local iy0 = y0 + pad
    local ix1 = x0 + sz - pad
    local iy1 = y0 + sz - pad
    local w = ix1 - ix0
    local h = iy1 - iy0

    r.ImGui_DrawList_AddRect(dl, ix0, iy0, ix1, iy1, color, 3.0, 0, 1.3)

    local mid_x = ix0 + w * 0.5
    local mid_y = iy0 + h * 0.5
    local cr, cg, cb = extract_rgb_rrgbbaa(color)
    local axis_color = build_color_rrgbbaa(cr, cg, cb, 70)
    r.ImGui_DrawList_AddLine(dl, mid_x, iy0 + 2, mid_x, iy1 - 2, axis_color, 1.0)
    r.ImGui_DrawList_AddLine(dl, ix0 + 2, mid_y, ix1 - 2, mid_y, axis_color, 1.0)

    local dots = {
      {0.20, 0.24, 2.4, accent},
      {0.58, 0.18, 1.8, color},
      {0.34, 0.56, 2.6, accent},
      {0.76, 0.58, 1.7, color},
      {0.16, 0.70, 2.0, color},
      {0.52, 0.80, 2.2, accent},
    }
    for _, dot in ipairs(dots) do
      r.ImGui_DrawList_AddCircleFilled(dl, ix0 + w * dot[1], iy0 + h * dot[2], dot[3], dot[4], 12)
    end
  end

  local function draw_sequencer_icon(dl, x0, y0, sz, color, accent)
    local pad = sz * 0.12
    local ix0 = x0 + pad
    local iy0 = y0 + pad
    local ix1 = x0 + sz - pad
    local iy1 = y0 + sz - pad
    local w = ix1 - ix0
    local h = iy1 - iy0

    local cols = 4
    local rows = 3
    local gap = 1.6
    local cell_w = (w - gap * (cols - 1)) / cols
    local cell_h = (h - gap * (rows - 1)) / rows
    local cr, cg, cb = extract_rgb_rrgbbaa(color)
    local inactive_color = build_color_rrgbbaa(cr, cg, cb, 90)

    local active_steps = {
      {1, 3},
      {2, 1, 4},
      {2, 3},
    }

    for row = 1, rows do
      for col = 1, cols do
        local cx0 = ix0 + (col - 1) * (cell_w + gap)
        local cy0 = iy0 + (row - 1) * (cell_h + gap)
        local cx1 = cx0 + cell_w
        local cy1 = cy0 + cell_h
        local is_active = false
        for _, active_col in ipairs(active_steps[row] or {}) do
          if active_col == col then
            is_active = true
            break
          end
        end
        if is_active then
          r.ImGui_DrawList_AddRectFilled(dl, cx0, cy0, cx1, cy1, accent, 2.0)
        else
          r.ImGui_DrawList_AddRect(dl, cx0, cy0, cx1, cy1, inactive_color, 2.0, 0, 1.0)
        end
      end
    end
  end

  local function draw_view_tab_button(view_id, label, draw_icon_fn, active)
    local text_w, text_h = r.ImGui_CalcTextSize(ctx, label)
    local btn_w = pad_x + icon_size + icon_text_gap + text_w + pad_x

    local clicked = r.ImGui_InvisibleButton(ctx, "##view_tab_" .. view_id, btn_w, btn_h)
    local rect_min = {r.ImGui_GetItemRectMin(ctx)}
    local rect_max = {r.ImGui_GetItemRectMax(ctx)}
    local hovered = r.ImGui_IsItemHovered(ctx)

    if clicked and state.active_view ~= view_id then
      state.active_view = view_id
      save_config()
    end

    local bg_color, border_color, icon_color, accent_color, text_color
    if active then
      bg_color = 0x284868FF
      border_color = 0x5A9AE6FF
      icon_color = 0xE8E8E8FF
      accent_color = 0x66AAFFFF
      text_color = 0xF2F2F2FF
    elseif hovered then
      bg_color = 0x1E2430FF
      border_color = 0x666677FF
      icon_color = 0xCCCCCCFF
      accent_color = 0x5599DDFF
      text_color = 0xD8D8D8FF
    else
      bg_color = 0x12141AFF
      border_color = 0x333344FF
      icon_color = 0x777777FF
      accent_color = 0x4477AAFF
      text_color = 0x888888FF
    end

    local dl = r.ImGui_GetWindowDrawList(ctx)
    r.ImGui_DrawList_AddRectFilled(dl, rect_min[1], rect_min[2], rect_max[1], rect_max[2], bg_color, 8.0)
    r.ImGui_DrawList_AddRect(dl, rect_min[1], rect_min[2], rect_max[1], rect_max[2], border_color, 8.0, 0, active and 1.8 or 1.0)

    if active then
      r.ImGui_DrawList_AddRectFilled(dl, rect_min[1] + 8, rect_max[2] - 3, rect_max[1] - 8, rect_max[2] - 1, accent_color, 2.0)
    end

    local icon_x0 = rect_min[1] + pad_x
    local icon_y0 = rect_min[2] + (btn_h - icon_size) * 0.5
    draw_icon_fn(dl, icon_x0, icon_y0, icon_size, icon_color, accent_color)

    local text_x = icon_x0 + icon_size + icon_text_gap
    local text_y = rect_min[2] + (btn_h - text_h) * 0.5
    if active then
      r.ImGui_DrawList_AddText(dl, text_x + 0.5, text_y, text_color, label)
      r.ImGui_DrawList_AddText(dl, text_x, text_y + 0.5, text_color, label)
    end
    r.ImGui_DrawList_AddText(dl, text_x, text_y, text_color, label)
  end

  draw_view_tab_button("sample_map", "Sample Map", draw_sample_map_icon, state.active_view == "sample_map")
  r.ImGui_SameLine(ctx, 0, tab_gap)
  draw_view_tab_button("sequencer", "Sequencer", draw_sequencer_icon, state.active_view == "sequencer")
  r.ImGui_Separator(ctx)
end

function render_filter_input()
  local function draw_search_icon(dl, x, y, height, color)
    local size = math.min(height - 4, 16)
    local lens_r = size * 0.32
    local cx = x + size * 0.45
    local cy = y + height * 0.5
    r.ImGui_DrawList_AddCircle(dl, cx, cy, lens_r, color, 16, 1.4)
    local hx = cx + lens_r * 0.62
    local hy = cy + lens_r * 0.62
    r.ImGui_DrawList_AddLine(dl, hx, hy, hx + size * 0.30, hy + size * 0.30, color, 1.6)
  end

  local function collect_active_tags_in_display_order()
    local ordered = {}
    if not state.active_tags or next(state.active_tags) == nil then
      return ordered
    end

    for tag, active in pairs(state.active_tags) do
      if active then
        ordered[#ordered + 1] = tag
      end
    end

    table.sort(ordered, function(a, b)
      return string.lower(a) < string.lower(b)
    end)

    return ordered
  end

  local function calc_tag_button_width(label)
    local text_w = r.ImGui_CalcTextSize(ctx, label)
    local frame_padding = {r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())}
    return text_w + (frame_padding[1] or 4) * 2
  end

  local function calc_compact_button_width(label)
    local text_w = r.ImGui_CalcTextSize(ctx, label)
    local frame_padding = {r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding())}
    return text_w + ((frame_padding[1] or 4) * 0.65) * 2
  end

  local avail_x = r.ImGui_GetContentRegionAvail(ctx)
  local filter_width = math.max(220, math.min(640, avail_x))
  local filter_height = 34
  local icon_pad = 28
  local min_input_width = 90
  local spacing = 4
  local active_tags = collect_active_tags_in_display_order()
  local has_active_tags = #active_tags > 0
  local clear_label = "Clear"

  local child_flags = 0
  if r.ImGui_ChildFlags_Border then
    child_flags = r.ImGui_ChildFlags_Border
  end
  local child_window_flags = r.ImGui_WindowFlags_NoScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()

  if r.ImGui_BeginChild(ctx, "sample_filter_field", filter_width, filter_height, child_flags, child_window_flags) then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    local x0, y0 = r.ImGui_GetWindowPos(ctx)
    draw_search_icon(dl, x0 + 8, y0 + 5, filter_height - 10, 0x888888FF)

    local clear_width = has_active_tags and calc_compact_button_width(clear_label) or 0
    local region_width = r.ImGui_GetContentRegionAvail(ctx)
    local max_tag_area = region_width - icon_pad - min_input_width
    if has_active_tags then
      max_tag_area = max_tag_area - clear_width - spacing
    end
    max_tag_area = math.max(0, max_tag_area)

    local visible_tags = {}
    local used_width = 0
    for _, tag in ipairs(active_tags) do
      local tag_width = calc_tag_button_width(tag)
      local extra_spacing = (#visible_tags > 0) and spacing or 0
      if used_width + extra_spacing + tag_width <= max_tag_area then
        visible_tags[#visible_tags + 1] = tag
        used_width = used_width + extra_spacing + tag_width
      else
        break
      end
    end

    local hidden_count = #active_tags - #visible_tags
    if hidden_count > 0 then
      local hidden_label = "+" .. tostring(hidden_count)
      local hidden_width = calc_tag_button_width(hidden_label)
      local extra_spacing = (#visible_tags > 0) and spacing or 0
      while #visible_tags > 0 and used_width + extra_spacing + hidden_width > max_tag_area do
        local removed = table.remove(visible_tags)
        used_width = used_width - calc_tag_button_width(removed)
        if #visible_tags > 0 then
          used_width = used_width - spacing
        end
        hidden_count = hidden_count + 1
        hidden_label = "+" .. tostring(hidden_count)
        hidden_width = calc_tag_button_width(hidden_label)
        extra_spacing = (#visible_tags > 0) and spacing or 0
      end
      if used_width + extra_spacing + hidden_width <= max_tag_area then
        visible_tags[#visible_tags + 1] = hidden_label
      end
    end

    r.ImGui_SetCursorPosX(ctx, icon_pad)
    r.ImGui_SetCursorPosY(ctx, 4)
    local first_item = true
    for _, tag in ipairs(visible_tags) do
      if not first_item then
        r.ImGui_SameLine(ctx, 0, spacing)
      end
      first_item = false
      if tag:sub(1, 1) == "+" then
        draw_tag_button(ctx, tag, false, "__hidden_tags__", "filter_active_")
      else
        if draw_tag_button(ctx, tag, true, tag, "filter_active_") then
          state.active_tags[tag] = nil
        end
      end
    end

    if has_active_tags then
      if not first_item then
        r.ImGui_SameLine(ctx, 0, spacing)
      end
      if draw_ui_button("filter_clear_active_tags", clear_label, nil, nil, { compact = true, style = "danger" }) then
        state.active_tags = {}
      end
      first_item = false
    end

    if not first_item then
      r.ImGui_SameLine(ctx, 0, spacing)
    end
    local input_width = math.max(min_input_width, r.ImGui_GetContentRegionAvail(ctx))
    r.ImGui_SetNextItemWidth(ctx, input_width)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(), 0x00000000)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Border(), 0x00000000)

    local ret, input
    if r.ImGui_InputTextWithHint then
      ret, input = r.ImGui_InputTextWithHint(ctx, "##sample_filter", has_active_tags and "Type to refine..." or "Search samples...", state.filter)
    else
      ret, input = r.ImGui_InputText(ctx, "##sample_filter", state.filter, 256)
    end
    r.ImGui_PopStyleColor(ctx, 4)

    if ret then
      state.filter = input
    end

    r.ImGui_EndChild(ctx)
  end
end

function render_header()
  -- Add settings button in top right
  -- Get available content region width to calculate button position
  local avail_x, avail_y = r.ImGui_GetContentRegionAvail(ctx)
  local button_width = 100
  local spacing = 10
  -- Calculate position: available width - button width - spacing
  -- (cursor starts at 0, so we use available width directly)
  local button_x = avail_x - button_width - spacing
  r.ImGui_SetCursorPosX(ctx, button_x)
  if draw_ui_button("header_settings", "Settings") then
    state.settings_open = not state.settings_open
  end
  
  -- Reset cursor for main content (start of next line)
  r.ImGui_SetCursorPosX(ctx, 0)
  
  if draw_ui_button("header_rescan", "Rescan", nil, nil, { style = "primary" }) then
    enqueue_scan()
    log("Manual rescan triggered")
  end
  
  r.ImGui_SameLine(ctx)
  if draw_ui_button("header_clear", "Clear", nil, nil, { style = "danger" }) then
    state.folders = {}
    filter_samples_by_folders()  -- This will clear samples and tag data
    state.scan_queue = {}
    clear_sample_cache()
    save_config()
    log("Cleared folders and samples")
  end
  
  r.ImGui_SameLine(ctx)
  if draw_ui_button("header_copy_logs", "Copy Scan Logs") then
    local logs_text = get_scan_logs_text()
    if logs_text and logs_text ~= "" then
      r.ImGui_SetClipboardText(ctx, logs_text)
      log("Scan logs copied to clipboard (" .. tostring(#state.scan_logs) .. " entries)")
    else
      log("No scan logs to copy")
    end
  end
  
  r.ImGui_SameLine(ctx)
  if draw_ui_button("header_debug_coords", "Debug Coords") then
    log("=== DEBUG: Sample Coordinates ===")
    log("Total samples: " .. #state.samples)
    if #state.samples > 0 then
      -- Find min/max for both axes
      local x_min, x_max = state.samples[1].x or 0.5, state.samples[1].x or 0.5
      local y_min, y_max = state.samples[1].y or 0.5, state.samples[1].y or 0.5
      local freq_min, freq_max = state.samples[1].dominant_freq or 440.0, state.samples[1].dominant_freq or 440.0
      
      local rms_min, rms_max = state.samples[1].rms_energy or 0.0, state.samples[1].rms_energy or 0.0
      local size_min, size_max = state.samples[1].file_size or 0, state.samples[1].file_size or 0
      for i, s in ipairs(state.samples) do
        local x = s.x or 0.5
        local y = s.y or 0.5
        local freq = s.dominant_freq or 440.0
        local rms = s.rms_energy or 0.0
        local size = s.file_size or 0
        log(string.format("Sample %d: name='%s', freq=%.1f Hz, rms=%.6f, size=%d bytes, x=%.6f, y=%.6f", 
            i, s.name or "unknown", freq, rms, size, x, y))
        x_min = math.min(x_min, x)
        x_max = math.max(x_max, x)
        y_min = math.min(y_min, y)
        y_max = math.max(y_max, y)
        freq_min = math.min(freq_min, freq)
        freq_max = math.max(freq_max, freq)
        rms_min = math.min(rms_min, rms)
        rms_max = math.max(rms_max, rms)
        size_min = math.min(size_min, size)
        size_max = math.max(size_max, size)
      end
      
      log("--- Summary ---")
      log(string.format("X range: %.6f to %.6f (span: %.6f)", x_min, x_max, x_max - x_min))
      log(string.format("Y range: %.6f to %.6f (span: %.6f)", y_min, y_max, y_max - y_min))
      log(string.format("Frequency range: %.1f Hz to %.1f Hz", freq_min, freq_max))
      log(string.format("RMS range: %.6f to %.6f", rms_min, rms_max))
      log(string.format("File size range: %d to %d bytes", size_min, size_max))
    else
      log("No samples to debug")
    end
    log("=== End Debug ===")
  end

  r.ImGui_Separator(ctx)
end


function render_settings()
  if not state.settings_open then
    return
  end
  
  r.ImGui_SetNextWindowSize(ctx, 600, 600, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, "Settings", true, r.ImGui_WindowFlags_None())
  
  if visible then
    r.ImGui_Text(ctx, "Scan Folders")
    r.ImGui_Separator(ctx)
    
    if draw_ui_button("settings_add_folder", "Add Folder", nil, nil, { style = "primary" }) then
      local new_folder = ""
      
      -- Try JS_Dialog_BrowseForFolder first (from JS_ReaScriptAPI extension)
      if r.APIExists("JS_Dialog_BrowseForFolder") then
        -- JS_Dialog_BrowseForFolder returns (retval, selectedFolder)
        -- retval: 1 = OK, 0 = cancelled
        -- selectedFolder: the path string
        local retval, selectedFolder = r.JS_Dialog_BrowseForFolder("Choose folder to scan", "")
        if retval == 1 and selectedFolder and selectedFolder ~= "" then
          new_folder = selectedFolder
          log("JS_Dialog_BrowseForFolder returned: " .. tostring(selectedFolder))
        else
          log("JS_Dialog_BrowseForFolder cancelled or failed. retval=" .. tostring(retval))
        end
      else
        log("JS_Dialog_BrowseForFolder not available - JS_ReaScriptAPI extension may not be installed")
      end
      
      -- Only show fallback dialog if JS dialog didn't work
      if new_folder == "" and not r.APIExists("JS_Dialog_BrowseForFolder") then
        r.ShowMessageBox("JS_ReaScriptAPI extension is required for folder browsing.\n\nPlease install it via ReaPack:\nExtensions > ReaPack > Browse Packages > Search for 'js_ReaScriptAPI'", "Extension Required", 0)
      end
      
      -- Normalize and validate folder path before adding
      if new_folder and new_folder ~= "" then
        new_folder = normalize_path(new_folder)
        
        -- Check if it's a valid path (not just a number or single character)
        if string.len(new_folder) < 2 or new_folder:match("^%d+$") then
          r.ShowMessageBox("Invalid folder path: " .. new_folder .. "\n\nPlease select a valid folder.", "Error", 0)
          log("Rejected invalid folder path: " .. new_folder)
        else
          -- Check if folder already exists in list
          local exists = false
          for _, f in ipairs(state.folders) do
            if f == new_folder then
              exists = true
              break
            end
          end
          if not exists then
            table.insert(state.folders, new_folder)
            save_config()
            log("Added folder: " .. new_folder)
            log("Folder path length: " .. string.len(new_folder))
          else
            log("Folder already in list: " .. new_folder)
          end
        end
      end
    end
    
    r.ImGui_Separator(ctx)
    
    if #state.folders > 0 then
      r.ImGui_Text(ctx, "Folders:")
      -- Use ChildFlags_Border constant if available, otherwise use 0 (no border)
      -- In ReaImGui, child flags may be accessed differently, so we check if it exists
      local child_flags = 0
      if r.ImGui_ChildFlags_Border then
        child_flags = r.ImGui_ChildFlags_Border
      end
      if r.ImGui_BeginChild(ctx, "folder_list", 0, 0, child_flags) then
        for idx, folder in ipairs(state.folders) do
          r.ImGui_BulletText(ctx, folder)
          r.ImGui_SameLine(ctx)
          if draw_ui_button("settings_remove_folder_" .. idx, "Remove", nil, nil, { style = "danger", compact = true }) then
            table.remove(state.folders, idx)
            filter_samples_by_folders()
            save_config()
            break
          end
        end
        r.ImGui_EndChild(ctx)
      end
    else
      r.ImGui_TextColored(ctx, 0xFF888888, "No folders yet. Click Add Folder to add scan folders.")
    end
    
    r.ImGui_Separator(ctx)
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Dot Appearance")
    r.ImGui_Separator(ctx)
    
    -- Dot size
    local ret, dot_radius = r.ImGui_InputDouble(ctx, "Dot Radius", state.dot_radius, 0.1, 1.0, "%.1f")
    if ret then
      state.dot_radius = math.max(0.5, math.min(10.0, dot_radius))
      save_config()
    end
    
    -- Outline size
    local ret2, outline_size = r.ImGui_InputDouble(ctx, "Outline Size", state.dot_outline_size, 0.1, 1.0, "%.1f")
    if ret2 then
      state.dot_outline_size = math.max(0.0, math.min(20.0, outline_size))
      save_config()
    end
    
    -- Outline thickness
    local ret3, outline_thickness = r.ImGui_InputDouble(ctx, "Outline Thickness", state.dot_outline_thickness, 0.1, 1.0, "%.1f")
    if ret3 then
      state.dot_outline_thickness = math.max(0.5, math.min(10.0, outline_thickness))
      save_config()
    end
    
    -- Detection multiplier
    local ret4, detection_mult = r.ImGui_InputDouble(ctx, "Detection Size Multiplier", state.dot_detection_multiplier, 0.5, 2.0, "%.1f")
    if ret4 then
      state.dot_detection_multiplier = math.max(1.0, math.min(50.0, detection_mult))
      save_config()
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Dot Color")
    
    -- Dot color using ColorEdit3 (RGB only)
    local dot_changed, dot_color_result = r.ImGui_ColorEdit3(ctx, "Dot Color", (state.dot_color or 0x44AA55) | 0xFF000000, 0)
    if dot_changed then
      state.dot_color = dot_color_result & 0xFFFFFF  -- Extract RGB part only
      save_config()
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Outline Color")
    
    -- Outline color using ColorEdit3
    local outline_changed, outline_color_result = r.ImGui_ColorEdit3(ctx, "Outline Color", (state.dot_outline_color or 0xFF00FF) | 0xFF000000, 0)
    if outline_changed then
      state.dot_outline_color = outline_color_result & 0xFFFFFF  -- Extract RGB part only
      save_config()
    end
    
    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Hover Color")
    
    -- Hover color using ColorEdit3
    local hover_changed, hover_color_result = r.ImGui_ColorEdit3(ctx, "Hover Color", (state.dot_hover_color or 0xC84D) | 0xFF000000, 0)
    if hover_changed then
      state.dot_hover_color = hover_color_result & 0xFFFFFF  -- Extract RGB part only
      save_config()
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Tag Colors")
    r.ImGui_Separator(ctx)

    -- Load tag presets
    local tag_presets = {}
    local function load_tag_presets()
      local preset_file = io.open(CONFIG_DIR .. "/tag_presets.lua", "r")
      if preset_file then
        local content = preset_file:read("*all")
        preset_file:close()
        local success, presets = pcall(load, content)
        if success and type(presets) == "function" then
          tag_presets = presets() or {}
        end
      end
    end
    load_tag_presets()

    -- Preset selector
    local preset_names = {}
    for name, _ in pairs(tag_presets) do
      table.insert(preset_names, name)
    end
    table.sort(preset_names)

    if #preset_names > 0 then
      r.ImGui_Text(ctx, "Presets:")
      r.ImGui_SameLine(ctx)
      if draw_ui_button("settings_load_preset", "Load Preset") then
        r.ImGui_OpenPopup(ctx, "select_tag_preset")
      end

      if r.ImGui_BeginPopup(ctx, "select_tag_preset") then
        for _, preset_name in ipairs(preset_names) do
          if r.ImGui_Selectable(ctx, preset_name) then
            local preset = tag_presets[preset_name]
            if preset then
              for tag, color in pairs(preset) do
                state.tag_colors[tag] = color
              end
              state.current_preset_name = preset_name  -- Track current preset
              save_config()
            end
          end
        end
        r.ImGui_EndPopup(ctx)
      end
      r.ImGui_SameLine(ctx)
      r.ImGui_Text(ctx, "|")
      r.ImGui_SameLine(ctx)
    end

    if draw_ui_button("settings_save_preset", "Save as Preset") then
      r.ImGui_OpenPopup(ctx, "save_tag_preset")
    end

    if r.ImGui_BeginPopup(ctx, "save_tag_preset") then
      r.ImGui_Text(ctx, "Preset Name:")
      local preset_name = ""
      local changed, new_name = r.ImGui_InputText(ctx, "##preset_name", preset_name, 0)
      if changed then
        preset_name = new_name
      end

      if draw_ui_button("settings_save_preset_confirm", "Save") and preset_name ~= "" then
        tag_presets[preset_name] = {}
        for tag, color in pairs(state.tag_colors) do
          tag_presets[preset_name][tag] = color
        end
        state.current_preset_name = preset_name  -- Track current preset

        -- Save presets back to file
        local preset_content = "return " .. serialize_table(tag_presets)
        local preset_file = io.open(CONFIG_DIR .. "/tag_presets.lua", "w")
        if preset_file then
          preset_file:write(preset_content)
          preset_file:close()
        end

        r.ImGui_CloseCurrentPopup(ctx)
      end
      r.ImGui_EndPopup(ctx)
    end

    r.ImGui_Separator(ctx)

    -- Create a sorted list of tags for consistent ordering
    local sorted_tags = {}
    for tag, _ in pairs(state.tag_colors) do
      table.insert(sorted_tags, tag)
    end
    table.sort(sorted_tags)

    -- Display color pickers for each tag
    for _, tag in ipairs(sorted_tags) do
      local tag_color = state.tag_colors[tag]
      local color_changed, new_color = r.ImGui_ColorEdit3(ctx, tag, tag_color | 0xFF000000, 0)
      if color_changed then
        state.tag_colors[tag] = new_color & 0xFFFFFF  -- Extract RGB part only
        save_config()
      end
    end
  end
  
  r.ImGui_End(ctx)
  
  -- Update settings_open state based on window open state
  if not open then
    state.settings_open = false
  end
end


function draw_map_status_overlay(dl, x0, y0, width, height)
  if #state.scan_queue > 0 then
    return
  end

  local lines = {}
  if #state.samples == 0 then
    lines[#lines + 1] = "Press Rescan to populate the map."
    if #state.folders > 0 then
      lines[#lines + 1] = "Folders configured: " .. #state.folders
    end
  else
    lines[#lines + 1] = string.format("Showing %d samples on map (Zoom: %.1fx)", #state.samples, state.zoom)
    if state.selected then
      lines[#lines + 1] = "Selected: " .. state.selected.name
    end
  end

  if #lines == 0 then
    return
  end

  local line_h = 16.0
  local padding = 8.0
  local text_y = y0 + height - (#lines * line_h) - padding
  for i, line in ipairs(lines) do
    local ty = text_y + (i - 1) * line_h
    r.ImGui_DrawList_AddText(dl, x0 + padding + 1, ty + 1, 0x000000AA, line)
    r.ImGui_DrawList_AddText(dl, x0 + padding, ty, 0xCCCCCCFF, line)
  end
end

function clamp_map_pan(width, height)
  local max_pan = width * 0.5 * state.zoom
  state.pan_x = math.max(-max_pan, math.min(max_pan, state.pan_x))
  local min_pan_y = height * 0.5 * (1 - state.zoom)
  local max_pan_y = height * 0.5 * (state.zoom - 1)
  state.pan_y = math.max(min_pan_y, math.min(max_pan_y, state.pan_y))
end

function handle_map_view_input(hovered, mx, my, width, height, x0, y0)
  local right_clicked = r.ImGui_IsMouseClicked(ctx, 1)  -- Right mouse button
  local right_down = r.ImGui_IsMouseDown(ctx, 1)
  local right_released = r.ImGui_IsMouseReleased(ctx, 1)
  -- Note: left_clicked detection moved to sample selection logic to prevent double detection
  
  -- Handle right-click drag for panning
  if hovered and right_clicked then
    -- Start right drag
    state.is_dragging = true
    state.is_left_dragging = false  -- Cancel left drag if right drag starts
    state.drag_start_x = mx
    state.drag_start_y = my
    state.drag_start_pan_x = state.pan_x
    state.drag_start_pan_y = state.pan_y
  elseif state.is_dragging and right_down then
    -- Continue right drag
    local dx = mx - state.drag_start_x
    local dy = my - state.drag_start_y
    state.pan_x = state.drag_start_pan_x + dx
    state.pan_y = state.drag_start_pan_y + dy

    clamp_map_pan(width, height)
    -- Don't save during drag - only save when drag ends
  elseif right_released then
    -- End right drag
    state.is_dragging = false
    state.drag_start_x = nil
    state.drag_start_y = nil
    -- Pan position not saved
  end
  
  -- Handle left-click drag for selecting samples
  local left_clicked = r.ImGui_IsMouseClicked(ctx, 0)  -- Left mouse button (detected here for drag logic)
  local left_released = r.ImGui_IsMouseReleased(ctx, 0)

  if hovered and left_clicked and not state.is_dragging then
    -- Start left drag (only if not right-dragging)
    state.is_left_dragging = true
    state.last_dragged_sample_path = nil
  elseif left_released then
    -- End left drag; cleanup happens in complete_pending_sample_drop()
  end
  
  -- Handle mouse wheel zoom
  if hovered and not state.is_dragging then
    local wheel = r.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      local zoom_speed = 0.1
      local old_zoom = state.zoom
      -- Clamp zoom to range: minimum 1.0 (normal zoom), maximum 3.0 (zoomed in)
      local new_zoom = math.max(1.0, math.min(3.0, state.zoom + wheel * zoom_speed))
      
      -- Calculate mouse position relative to map area center
      local mouse_rel_x = mx - (x0 + width * 0.5)
      local mouse_rel_y = my - (y0 + height * 0.5)
      
      -- Calculate what normalized map coordinate (0-1) the mouse is over
      -- Current transformation: px = center_x + (base_x - width/2) * zoom
      -- Where base_x = s.x * width (normalized coord * width)
      -- So: px = center_x + (s.x * width - width/2) * zoom
      --     px = center_x + width * (s.x - 0.5) * zoom
      -- Reverse: s.x = ((px - center_x) / (width * zoom)) + 0.5
      
      local center_x = x0 + width * 0.5 + state.pan_x
      local center_y = y0 + height * 0.5 + state.pan_y
      
      -- Find normalized map coordinate under mouse
      local map_norm_x = ((mx - center_x) / (width * old_zoom)) + 0.5
      local map_norm_y = ((my - center_y) / (height * old_zoom)) + 0.5
      
      -- Update zoom
      state.zoom = new_zoom
      
      -- Adjust pan so the same normalized map coordinate stays under the mouse
      -- After zoom: mx = new_center_x + width * (map_norm_x - 0.5) * new_zoom
      -- Solve: new_center_x = mx - width * (map_norm_x - 0.5) * new_zoom
      local new_center_x = mx - width * (map_norm_x - 0.5) * new_zoom
      local new_center_y = my - height * (map_norm_y - 0.5) * new_zoom
      
      -- Convert back to pan offset
      state.pan_x = new_center_x - (x0 + width * 0.5)
      state.pan_y = new_center_y - (y0 + height * 0.5)

      -- Clamp pan position to prevent excessive panning
      local max_pan = width * 0.5 * state.zoom  -- Allow panning up to half screen width at current zoom
      state.pan_x = math.max(-max_pan, math.min(max_pan, state.pan_x))
      
      -- Clamp pan_y to prevent going beyond frequency boundaries (Y axis: 0 = top/20kHz, 1 = bottom/20Hz)
      local min_pan_y = height * 0.5 * (1 - state.zoom)   -- Can't pan up beyond Y=0 (20kHz at top)
      local max_pan_y = height * 0.5 * (state.zoom - 1)   -- Can't pan down beyond Y=1 (20Hz at bottom)
      state.pan_y = math.max(min_pan_y, math.min(max_pan_y, state.pan_y))
      -- Don't save during zoom - config is saved on script exit and after drag ends
    end
  end
end

function round_to_nice_map_freq(freq)
  if freq < 100.0 then
    return math.floor((freq + 5) / 10) * 10
  elseif freq < 500.0 then
    return math.floor((freq + 10) / 20) * 20
  elseif freq < 1000.0 then
    return math.floor((freq + 20) / 40) * 40
  elseif freq < 5000.0 then
    return math.floor((freq + 50) / 100) * 100
  else
    return math.floor((freq + 100) / 200) * 200
  end
end

function draw_map_grid(dl, x0, y0, width, height, padded_x0, padded_y0, padded_width, padded_height, padded_center_x, padded_center_y)
  -- Draw grid lines for frequency (horizontal) and time (vertical)
  if #state.samples > 0 and state.samples[1].x then
    local log10 = math.log(10)
    
    -- Use theoretical frequency range (20Hz-20kHz) for consistent grid
    local freq_min_log = math.log(20.0) / log10
    local freq_max_log = math.log(20000.0) / log10
    
    -- Calculate duration range from samples for X-axis grid
    local len_min_log, len_max_log = nil, nil
    for _, s in ipairs(state.samples) do
      if s.duration then
        local len_log = math.log(math.max(s.duration, 0.01)) / log10
        if not len_min_log then
          len_min_log = len_log
          len_max_log = len_log
        else
          len_min_log = math.min(len_min_log, len_log)
          len_max_log = math.max(len_max_log, len_log)
        end
      end
    end
    
    -- Use reasonable defaults for duration if no samples
    if not len_min_log then
      len_min_log = math.log(0.01) / log10  -- 10ms
      len_max_log = math.log(60.0) / log10   -- 60 seconds
    end
    
    -- Subtle grid color (semi-transparent gray)
    local grid_color = 0x40404040  -- RRGGBBAA: gray with ~25% opacity
    local text_color = 0x80808080  -- RRGGBBAA: lighter gray with ~50% opacity for text
    
    -- Draw evenly spaced horizontal frequency grid lines
    -- Generate evenly spaced normalized Y positions (every 10% = 0.1)
    local num_freq_lines = 10  -- 10 evenly spaced lines
    for i = 0, num_freq_lines do
      local normalized_y = i / num_freq_lines  -- 0.0 to 1.0, evenly spaced
      
      -- Convert normalized Y back to frequency (inverse of layout transform)
      -- normalized_y = 1.0 - y_normalized, so y_normalized = 1.0 - normalized_y
      local y_normalized = 1.0 - normalized_y
      local freq_log = freq_min_log + y_normalized * (freq_max_log - freq_min_log)
      local freq_val = 10 ^ freq_log
      
      -- Convert normalized Y to screen coordinate (using padded area)
      local base_y = normalized_y * padded_height
      local py = padded_center_y + (base_y - padded_height * 0.5) * state.zoom
      
      -- Only draw if line is visible in viewport
      if py >= padded_y0 - 1 and py <= padded_y0 + padded_height + 1 then
        -- Draw line across padded area (from label padding to right edge)
        r.ImGui_DrawList_AddLine(dl, padded_x0, py, x0 + width, py, grid_color, 1.0)
        
        -- Round frequency to nice round number for display
        local rounded_freq = round_to_nice_map_freq(freq_val)
        
        -- Add text label for frequency
        local freq_text
        if rounded_freq >= 1000.0 then
          freq_text = string.format("%.1fkHz", rounded_freq / 1000.0)
        else
          freq_text = string.format("%.0fHz", rounded_freq)
        end
        -- Draw text at left edge, slightly offset from line
        r.ImGui_DrawList_AddText(dl, x0 + 4, py - 7, text_color, freq_text)
      end
    end
    
    -- Draw vertical time/duration grid lines (seconds)
    -- Find reasonable time range from samples
    local duration_min, duration_max = nil, nil
    for _, s in ipairs(state.samples) do
      if s.duration then
        local dur = math.max(0.01, s.duration)
        if not duration_min then
          duration_min = dur
          duration_max = dur
        else
          duration_min = math.min(duration_min, dur)
          duration_max = math.max(duration_max, dur)
        end
      end
    end
    
    if duration_min and duration_max then
      -- Draw evenly spaced vertical time/duration grid lines
      -- Generate evenly spaced normalized X positions (every 10% = 0.1, accounting for 5% padding)
      local padding = 0.05
      local num_time_lines = 10  -- 10 evenly spaced lines
      for i = 0, num_time_lines do
        -- Map i from 0-num_time_lines to normalized_x accounting for padding
        local normalized_x = padding + (i / num_time_lines) * (1.0 - 2.0 * padding)
        
        -- Convert normalized X back to duration (inverse of layout transform)
        local len_log = len_min_log + ((normalized_x - padding) / (1.0 - 2.0 * padding)) * (len_max_log - len_min_log)
        local time_val = 10 ^ len_log
        
        -- Convert normalized X to screen coordinate (using padded area)
        local base_x = normalized_x * padded_width
        local px = padded_center_x + (base_x - padded_width * 0.5) * state.zoom
        
        -- Only draw if line is visible in viewport
        if px >= padded_x0 - 1 and px <= padded_x0 + padded_width + 1 then
          -- Draw line across padded area (from label padding to bottom edge)
          r.ImGui_DrawList_AddLine(dl, px, padded_y0, px, y0 + height, grid_color, 1.0)
          
          -- Add text label for time
          local time_text
          if time_val < 1.0 then
            time_text = string.format("%.1fs", time_val)
          elseif time_val < 10.0 then
            time_text = string.format("%.1fs", time_val)
          else
            time_text = string.format("%.0fs", time_val)
          end
          -- Draw text at top edge, slightly offset from line
          r.ImGui_DrawList_AddText(dl, px + 4, y0 + 4, text_color, time_text)
        end
      end
    end
  end
end

function render_map_samples(dl, hovered, mx, my, padded_x0, padded_y0, padded_width, padded_height, padded_center_x, padded_center_y)
  -- Use customizable dot size
  local dot_radius = state.dot_radius or 2.0
  local clicked_sample = nil
  local hovered_samples = {}  -- Collect all hovered samples to handle overlaps
  local click_handled_this_frame = false  -- Prevent multiple preview triggers per frame
  
  -- Colors are in RGB format, convert to RRGGBBAA for rendering
  local dot_color = build_color_rrgbbaa(extract_rgb(state.dot_color or 0x44AA55))
  local outline_color = build_color_rrgbbaa(extract_rgb(state.dot_outline_color or 0xFF00FF))
  local hover_color = build_color_rrgbbaa(extract_rgb(state.dot_hover_color or 0xC84D))
  
  -- Debug: log sample count
  if #state.samples > 0 and not state.samples[1].x then
    log("WARNING: Samples found but not laid out yet. Count: " .. #state.samples)
  end
  
  for _, s in ipairs(state.samples) do
    if type(s) == "table" and sample_passes_filters(s) then
      -- Apply zoom and pan to coordinates (using padded area for sample drawing)
      -- Samples use normalized coordinates (0-1), map them to padded area to align with grid
      local base_x = (s.x or 0.5) * padded_width
      local base_y = (s.y or 0.5) * padded_height
      local px = padded_center_x + (base_x - padded_width * 0.5) * state.zoom
      local py = padded_center_y + (base_y - padded_height * 0.5) * state.zoom
      
      -- Only draw if visible
      local outline_size = state.dot_outline_size or 4.0
      local is_playing = preview_sample_obj and preview_sample_obj.path == s.path
      -- Account for selected dot being 5x larger plus glow effect
      local current_dot_radius = is_playing and (dot_radius * 5.0) or dot_radius
      local glow_expansion = is_playing and (current_dot_radius * 0.3) or 0.0  -- Max glow expansion
      local max_radius = math.max(current_dot_radius + glow_expansion, current_dot_radius + outline_size)
      -- Check visibility against padded area (samples are drawn in padded area to avoid label overlap)
      if px >= padded_x0 - max_radius and px <= padded_x0 + padded_width + max_radius and
         py >= padded_y0 - max_radius and py <= padded_y0 + padded_height + max_radius then
        -- Use tag-based color instead of global dot color
        local color = dot_color -- fallback color

        -- Find the primary tag for this sample (highest weight tag)
        if s.tags and type(s.tags) == "table" and #s.tags > 0 then
          local best_tag = nil
          local best_weight = 0
          for _, tag_name in ipairs(s.tags) do
            -- Find the weight for this tag from TAG_KEYWORDS
            for _, keyword_entry in ipairs(TAG_KEYWORDS) do
              if keyword_entry.tag == tag_name then
                if keyword_entry.weight > best_weight then
                  best_weight = keyword_entry.weight
                  best_tag = tag_name
                end
                break
              end
            end
          end

          -- Use the tag's color if found (convert RGB to RRGGBBAA)
          if best_tag and state.tag_colors[best_tag] then
            local tag_rgb = state.tag_colors[best_tag]
            local r, g, b = extract_rgb(tag_rgb)
            color = build_color_rrgbbaa(r, g, b, 255)
          end
        end

        -- Apply mono/stereo distinction to the tag color
        if s.channels == 1 then
          -- Mono: use lighter version (add 50% to each component, clamped to 255)
          local base_r, base_g, base_b = extract_rgb_rrgbbaa(color)
          local mono_r = math.min(255, math.floor(base_r * 1.5))
          local mono_g = math.min(255, math.floor(base_g * 1.5))
          local mono_b = math.min(255, math.floor(base_b * 1.5))
          -- Build color in RRGGBBAA format with full opacity
          color = build_color_rrgbbaa(mono_r, mono_g, mono_b, 255)
        end
        
        -- Draw outline for currently playing/chosen sample (bigger and more visible)
        if is_playing then
          -- Selected dot is 5x the normal size
          local selected_dot_radius = dot_radius * 2
          
          -- Continuous breathing glow effect - more prominent
          -- Reset breathing cycle when sample is clicked (breathing_start_time is set in preview_sample)
          if not state.breathing_start_time then
            state.breathing_start_time = r.time_precise()
          end
          local current_time = r.time_precise()
          -- Breathing cycle: 1.5 seconds per cycle (faster breathing)
          local breathing_speed = 1.5  -- seconds per full cycle
          local elapsed = current_time - state.breathing_start_time
          local breathing_phase = (elapsed % breathing_speed) / breathing_speed  -- 0 to 1
          
          -- More prominent breathing: larger amplitude (0.7 to 1.3 instead of 0.9 to 1.1)
          -- This creates a more noticeable pulsing effect
          local breathing_amplitude = 0.7 + 0.6 * (0.5 + 0.5 * math.sin(breathing_phase * 2.0 * math.pi))
          
          -- Add intensity spike when first clicked (decays over 0.4 seconds)
          local spike_duration = 0.4  -- seconds for spike to fade out
          local spike_factor = 0.0
          if elapsed < spike_duration then
            -- Exponential decay: starts at 1.0, fades to 0.0 over spike_duration
            local spike_progress = elapsed / spike_duration
            spike_factor = math.exp(-spike_progress * 4.0)  -- Fast exponential decay
            -- Scale spike intensity (adds up to 0.5x to the amplitude)
            spike_factor = spike_factor * 0.5
          end
          
          -- Combine breathing amplitude with spike
          local total_amplitude = breathing_amplitude + spike_factor
          
          -- Much larger glow radius: 4x the selected dot radius (was 30% expansion)
          local glow_inner = selected_dot_radius * 1.2  -- Start glow just outside the dot
          local glow_outer = selected_dot_radius * 4.0  -- Much larger outer radius
          
          -- Apply breathing + spike to glow size
          local breathing_glow_inner = glow_inner * total_amplitude
          local breathing_glow_outer = glow_outer * total_amplitude
          
          -- Brighten glow color (brighten dot's color while preserving hue)
          -- Use a brighter version of the dot's color for the outer glow
          local base_brightness = 0.3  -- Base brightness increase for normal glow
          local glow_color = brighten_color_preserve_hue(color, base_brightness)
          
          -- Further brighten during spike
          if spike_factor > 0.01 then
            -- Additional brightness during spike
            local spike_brightness = math.min(1.0, spike_factor * 2.0)  -- Scale spike_factor for brightness
            glow_color = brighten_color_preserve_hue(color, base_brightness + spike_brightness * 0.5)  -- Up to 80% total brightness
          end
          
          -- Draw glowing circle effect
          draw_glowing_circle(dl, px, py, breathing_glow_inner, breathing_glow_outer, 
                             selected_dot_radius, glow_color, color)
          
          -- Draw outline for selected dot (on top of glow)
          local outline_thickness = state.dot_outline_thickness or 3.0
          r.ImGui_DrawList_AddCircle(dl, px, py, selected_dot_radius + outline_size, outline_color, 32, outline_thickness)
        else
          -- Draw filled circle (dot) for non-playing samples
          r.ImGui_DrawList_AddCircleFilled(dl, px, py, dot_radius, color, 16)
        end
        
        if hovered then
          local dx = mx - px
          local dy = my - py
          local dist_sq = dx * dx + dy * dy
          -- Use customizable detection multiplier
          local detection_mult = state.dot_detection_multiplier or 16.0
          if dist_sq <= (dot_radius * dot_radius * detection_mult) then
            -- Store hovered sample with distance and dot color for later selection
            table.insert(hovered_samples, {
              sample = s,
              px = px,
              py = py,
              dist_sq = dist_sq,
              dot_color = color  -- Store the dot's tag-based color
            })
          end
        end
      end
    end
  end
  
  -- Handle hovered samples: select closest one to prevent overlapping dot issues
  if #hovered_samples > 0 then
    -- Sort by distance (closest first)
    table.sort(hovered_samples, function(a, b)
      return a.dist_sq < b.dist_sq
    end)
    
    -- Use the closest sample for hover effects and interaction
    local closest = hovered_samples[1]
    local s = closest.sample
    local px = closest.px
    local py = closest.py
    local dot_color_for_glow = closest.dot_color or dot_color  -- Use stored dot color
    
    -- Only add hover glow if this sample is not currently playing (avoid double glow)
    local is_currently_playing = preview_sample_obj and preview_sample_obj.path == s.path
    if not is_currently_playing then
      -- Subtle glow effect for hovered dots
      local hover_glow_inner = dot_radius * 1.1  -- Start glow just outside the dot
      local hover_glow_outer = dot_radius * 2.5   -- Smaller outer radius than selected dot
      
      -- Use the dot's tag color for glow (make it more subtle with lower opacity)
      local dot_r, dot_g, dot_b = extract_rgb_rrgbbaa(dot_color_for_glow)
      local subtle_hover_color = build_color_rrgbbaa(dot_r, dot_g, dot_b, 180)  -- ~70% opacity
      
      -- Draw subtle glowing circle effect for hover using dot's color
      draw_glowing_circle(dl, px, py, hover_glow_inner, hover_glow_outer, 
                         nil, subtle_hover_color, nil)  -- No solid center, just glow
    end
    
    -- Draw hover highlight ring for closest sample (colors already in RRGGBBAA format)
    local hot_color = s.hot_color or hover_color
    r.ImGui_DrawList_AddCircle(dl, px, py, dot_radius + 1.5, hot_color, 16, 1.5)
    
    -- Show tooltip for closest sample
    r.ImGui_BeginTooltip(ctx)
    r.ImGui_Text(ctx, s.name)
    r.ImGui_Text(ctx, string.format("%.2fs | %d Hz | ch:%d", s.duration, s.samplerate, s.channels))
    r.ImGui_Text(ctx, string.format("Dominant freq: %.1f Hz", s.dominant_freq or 440.0))
    r.ImGui_Text(ctx, string.format("RMS energy: %.6f", s.rms_energy or 0.0))
    if s.sample_type then
      r.ImGui_Text(ctx, string.format("Type: %s", s.sample_type))
    end
    if s.snap_offset then
      r.ImGui_Text(ctx, string.format("Snap offset: %.3fs", s.snap_offset))
    end
    if s.tags and #s.tags > 0 then
      r.ImGui_Text(ctx, "Tags: " .. table.concat(s.tags, ", "))
    end
    r.ImGui_EndTooltip(ctx)
    
    -- Handle click or drag selection (only for closest sample)
    if not click_handled_this_frame and r.ImGui_IsMouseClicked(ctx, 0) then
      if is_alt_down() then
        state.pending_waveform_drop = s
        state.is_left_dragging = false
        state.last_dragged_sample_path = nil
        click_handled_this_frame = true
        log("Alt+drag started for sample: " .. (s.name or s.path))
      elseif state.seq_swap_track_id then
        local slot = get_active_swap_slot()
        if slot and assign_sample_to_seq_track(slot, s, false) then
          preview_sample(s)
          log("Swapped to '" .. (s.name or s.path) .. "' on " .. slot.name .. " (swap mode)")
        end
        state.block_swap_bar_input = true
        click_handled_this_frame = true
      else
        clicked_sample = s
        click_handled_this_frame = true
        -- Start drag state so users can drag to preview different samples even if drag starts on a dot
        state.is_left_dragging = true
        state.last_dragged_sample_path = s.path
      end
    elseif state.is_left_dragging and not state.pending_waveform_drop and s.path ~= state.last_dragged_sample_path then
      -- While left-dragging, preview newly hovered samples
      clicked_sample = s
      state.last_dragged_sample_path = s.path
    end
  end

  return clicked_sample
end

function draw_map_scan_progress_overlay(dl, x0, y0, width, height)
  if #state.scan_queue > 0 then
    local done = state.scan_total - #state.scan_queue
    local elapsed = r.time_precise() - state.scan_started
    local progress = state.scan_total > 0 and (done / state.scan_total) or 0.0
    
    -- Draw semi-transparent overlay background at the top of the map
    local overlay_height = 70.0
    local overlay_y = y0
    local overlay_bg_color = 0x000000CC  -- Semi-transparent black (RRGGBBAA format, last two digits are alpha)
    r.ImGui_DrawList_AddRectFilled(dl, x0, overlay_y, x0 + width, overlay_y + overlay_height, overlay_bg_color, 0, 0)
    
    -- Draw progress bar at the top of the map
    local bar_padding = 20.0
    local bar_y = overlay_y + 25.0
    local bar_width = width - (bar_padding * 2)
    local bar_height = 8.0
    
    -- Progress text (centered above bar)
    local text = string.format("Scanning: %.1f%% (%d/%d) - %.1fs", progress * 100.0, done, state.scan_total, elapsed)
    local text_size_x, text_size_y = r.ImGui_CalcTextSize(ctx, text)
    local text_x = x0 + (width - text_size_x) * 0.5
    local text_y = overlay_y + 8.0
    -- Draw text with shadow for better visibility
    r.ImGui_DrawList_AddText(dl, text_x + 1, text_y + 1, 0x000000FF, text)
    r.ImGui_DrawList_AddText(dl, text_x, text_y, 0xFFFFFFFF, text)
    
    -- Background bar (dark gray)
    local bar_bg_color = 0x2A2A2AFF
    r.ImGui_DrawList_AddRectFilled(dl, x0 + bar_padding, bar_y, x0 + bar_padding + bar_width, bar_y + bar_height, bar_bg_color, 4.0, 0)
    
    -- Progress fill (bright green)
    local fill_width = bar_width * math.max(0.0, math.min(1.0, progress))
    if fill_width > 2.0 then
      local fill_color = 0x00FF00FF
      r.ImGui_DrawList_AddRectFilled(dl, x0 + bar_padding + 2, bar_y + 2, x0 + bar_padding + fill_width - 2, bar_y + bar_height - 2, fill_color, 2.0, 0)
    end
    
    -- Border (white)
    local border_color = 0xFFFFFFFF
    r.ImGui_DrawList_AddRect(dl, x0 + bar_padding, bar_y, x0 + bar_padding + bar_width, bar_y + bar_height, border_color, 4.0, 0, 1.5)
    
    -- Estimate time remaining (below bar)
    if done > 0 and elapsed > 0.1 then
      local rate = done / elapsed  -- files per second
      local remaining = #state.scan_queue / rate
      if remaining > 0 then
        local remaining_text = string.format("Estimated time remaining: %.1fs", remaining)
        local remaining_size_x, remaining_size_y = r.ImGui_CalcTextSize(ctx, remaining_text)
        local remaining_x = x0 + (width - remaining_size_x) * 0.5
        local remaining_y = bar_y + bar_height + 8.0
        r.ImGui_DrawList_AddText(dl, remaining_x + 1, remaining_y + 1, 0x000000FF, remaining_text)
        r.ImGui_DrawList_AddText(dl, remaining_x, remaining_y, 0xCCCCCCFF, remaining_text)
      end
    end
  end
end


function render_map()
  local avail_x, avail_y = r.ImGui_GetContentRegionAvail(ctx)
  local width = math.max(0, avail_x)
  local height = math.max(0, avail_y)
  if width <= 0 or height <= 0 then
    return
  end

  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)

  r.ImGui_InvisibleButton(ctx, "map_area", width, height)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)

  handle_map_view_input(hovered, mx, my, width, height, x0, y0)

  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + width, y0 + height, 0x000000FF, 6)

  local label_padding_left = 70
  local label_padding_top = 25
  local padded_x0 = x0 + label_padding_left
  local padded_y0 = y0 + label_padding_top
  local padded_width = width - label_padding_left
  local padded_height = height - label_padding_top
  local padded_center_x = padded_x0 + padded_width * 0.5 + state.pan_x
  local padded_center_y = padded_y0 + padded_height * 0.5 + state.pan_y

  draw_map_grid(dl, x0, y0, width, height, padded_x0, padded_y0, padded_width, padded_height, padded_center_x, padded_center_y)

  local clicked_sample = render_map_samples(dl, hovered, mx, my, padded_x0, padded_y0, padded_width, padded_height, padded_center_x, padded_center_y)
  if clicked_sample then
    preview_sample(clicked_sample)
  end

  if state.pending_waveform_drop then
    r.ImGui_SetMouseCursor(ctx, r.ImGui_MouseCursor_Hand())
    update_pending_drop_tracking()
  end

  draw_map_scan_progress_overlay(dl, x0, y0, width, height)
  draw_map_status_overlay(dl, x0, y0, width, height)
end


-- --- Main loop ---------------------------------------------------------------
function loop()
  if not running then
    return
  end
  
  if not r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
    log("ImGui context invalid; stopping loop")
    running = false
    return
  end
  
  sync_project_state_if_needed()
  process_scan_slice()
  
  local visible, open = begin_window()
  if visible then
    if r.ImGui_GetWindowPos and r.ImGui_GetWindowSize then
      local wx, wy = r.ImGui_GetWindowPos(ctx)
      local ww, wh = r.ImGui_GetWindowSize(ctx)
      state.main_window_rect = { x = wx, y = wy, w = ww, h = wh }
    end
    state.block_swap_bar_input = false
    state.seq_drop_target_idx = nil
    state.seq_timeline_drop_track_idx = nil
    state.seq_timeline_drop_time = nil

    -- Handle keyboard input for history navigation (only when window is visible)
    if r.ImGui_IsKeyPressed and r.ImGui_Key_UpArrow and r.ImGui_Key_DownArrow then
      local up_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow(), false)
      local down_pressed = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow(), false)

      if up_pressed then
        navigate_history(1)   -- Go back in history to older samples (up arrow increases index)
      elseif down_pressed then
        navigate_history(-1)  -- Go forward in history to newer samples (down arrow decreases index)
      end
    end

    handle_script_keyboard_shortcuts()

    render_header()

    local _, avail_y = r.ImGui_GetContentRegionAvail(ctx)

    local child_flags = 0
    if r.ImGui_ChildFlags_Border then
      child_flags = r.ImGui_ChildFlags_Border
    end
    local no_scroll_flags = r.ImGui_WindowFlags_NoScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()

    if r.ImGui_BeginChild(ctx, "main_content", 0, avail_y, child_flags) then
      render_view_tab_switcher()

      if state.active_view == "sample_map" then
        render_filter_input()
        render_tag_filters()
        local panel_width = state.seq_panel_width or 240
        local _, tab_avail_y = r.ImGui_GetContentRegionAvail(ctx)
        if r.ImGui_BeginChild(ctx, "sample_map_seq_tracks", panel_width, math.max(0, tab_avail_y), child_flags, no_scroll_flags) then
          render_seq_tracks_panel()
          r.ImGui_EndChild(ctx)
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_BeginChild(ctx, "sample_map_right_column", 0, math.max(0, tab_avail_y), child_flags) then
          render_waveform()
          render_swap_mode_bar()
          local _, map_avail_y = r.ImGui_GetContentRegionAvail(ctx)
          if r.ImGui_BeginChild(ctx, "sample_map_area", 0, math.max(0, map_avail_y), child_flags, no_scroll_flags) then
            render_map()
            r.ImGui_EndChild(ctx)
          end
          r.ImGui_EndChild(ctx)
        end
      elseif state.active_view == "sequencer" then
        render_sequencer_map()
      end
      r.ImGui_EndChild(ctx)
    end

    draw_sample_drag_ghost()
    complete_pending_sample_drop()
  end
  r.ImGui_End(ctx)
  
  -- Pop the style colors we pushed in begin_window (must match every push)
  r.ImGui_PopStyleColor(ctx, 3)  -- WindowBg, ChildBg, FrameBg
  
  -- Render settings window (separate window)
  render_settings()
  
  if open and running then
    r.defer(loop)
  else
    running = false
    stop_preview()

    -- Cancel any in-flight drag so we never leave a provisional item or tooltip behind.
    remove_provisional_drop()
    clear_drag_tooltip()

    -- Cleanup: Close all open analyzer pipes to prevent file handle leaks
    for i = #state.active_processes, 1, -1 do
      local proc = state.active_processes[i]
      if proc and proc.pipe then
        local close_ok, close_err = pcall(function() return proc.pipe:close() end)
        if not close_ok then
          log("Warning: failed to close pipe during cleanup: " .. tostring(close_err))
        end
      end
    end
    state.active_processes = {}
    
    -- Save samples before closing (to preserve scan progress)
    if #state.samples > 0 or #state.scan_queue > 0 then
      save_samples()
    end
    -- Try to destroy context if function exists
    if ctx and r.ImGui_ValidatePtr(ctx, "ImGui_Context*") then
      if r.APIExists("ImGui_DestroyContext") then
        r.ImGui_DestroyContext(ctx)
      end
    end
    ctx = nil
    save_config()
  end
end


-- --- Main entry point --------------------------------------------------------
function main()
  log("Starting Sample Map Browser...")
  
  load_config()
  sync_project_state_if_needed()

  local cache_loaded = load_samples()

  ctx = r.ImGui_CreateContext(SCRIPT_NAME, r.ImGui_ConfigFlags_DockingEnable())
  font = r.ImGui_CreateFont("sans-serif", 16)
  if font then
    r.ImGui_Attach(ctx, font)
  end
  
  log("ImGui context created; beginning scan")
  if not cache_loaded then
    enqueue_scan()
  else
    state.scan_queue = {}
    state.scan_total = 0
    log("Using cached samples; skip initial scan")
  end
  loop()
end

main()



