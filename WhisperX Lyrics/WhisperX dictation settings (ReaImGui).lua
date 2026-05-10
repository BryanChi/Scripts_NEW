-- @description WhisperX dictation — settings (ReaImGui)
-- @version 1.02
-- @author Bryan
-- @about
--   Edits global extstate BRYAN_WHISPERX used by "WhisperX dictation (selected item to JSON).lua".
--   Requires the ReaImGui extension. Save, then run the dictation action.
--   Model presets show Hugging Face hub cache status (Systran/faster-whisper-*) and on-disk size when present.

local r = reaper

local SECTION = "BRYAN_WHISPERX"
local WINDOW_TITLE = "WhisperX dictation — settings"

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
  r.MB("ReaImGui is required for this script.\nInstall ReaImGui from ReaPack, then reload.", WINDOW_TITLE, 0)
  return
end

local function es_get(key, default)
  local v = r.GetExtState(SECTION, key)
  if type(v) ~= "string" or v == "" then
    return default
  end
  return v
end

local function es_bool(key, default_true)
  local s = r.GetExtState(SECTION, key)
  if s == nil or s == "" then
    return default_true
  end
  local sl = s:lower()
  if s == "0" or sl == "false" or sl == "off" or sl == "no" then
    return false
  end
  return true
end

local MODEL_ITEMS_STR =
  "tiny\0tiny.en\0base\0base.en\0small\0small.en\0medium\0medium.en\0large-v1\0large-v2\0large-v3\0"

local MARKER_ITEMS_STR = "start\0mid\0end\0"

local INTERP_ITEMS_STR = "linear\0nearest\0quadratic\0"

local DEVICE_ITEMS_STR = "cpu\0cuda\0mps\0"

local COMPUTE_ITEMS_STR = "int8\0float16\0float32\0"

local function split_null(s)
  local t = {}
  for part in string.gmatch(s, "[^\0]+") do
    t[#t + 1] = part
  end
  return t
end

local function index_in_list(list_str, value)
  value = string.lower(tostring(value or ""))
  local i = 0
  for part in string.gmatch(list_str, "[^\0]+") do
    if string.lower(part) == value then
      return i
    end
    i = i + 1
  end
  return 0
end

local function join_path(a, b)
  if not a or a == "" then
    return b
  end
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  return a .. "/" .. b
end

local function getenv_safe(k)
  if os.getenv then
    return os.getenv(k)
  end
  return nil
end

local function path_exists(p)
  if not p or p == "" then
    return false
  end
  if r.APIExists and r.APIExists("file_exists") then
    return r.file_exists(p)
  end
  local f = io.open(p, "r")
  if f then
    f:close()
    return true
  end
  return false
end

--- Hugging Face hub directory (contains models--org--repo folders).
local function huggingface_hub_dir()
  local hub = getenv_safe("HUGGINGFACE_HUB_CACHE")
  if hub and hub ~= "" then
    return hub:gsub("\\", "/"):gsub("/+$", "")
  end
  local hf = getenv_safe("HF_HOME")
  local base
  if hf and hf ~= "" then
    base = hf:gsub("\\", "/"):gsub("/+$", "")
  else
    local home = getenv_safe("HOME") or getenv_safe("USERPROFILE") or ""
    if home == "" then
      return nil
    end
    local xdg = getenv_safe("XDG_CACHE_HOME")
    local on_win = (r.GetOS() or ""):match("Win") ~= nil
    if xdg and xdg ~= "" and not on_win then
      base = join_path(xdg:gsub("\\", "/"):gsub("/+$", ""), "huggingface")
    else
      base = join_path(home:gsub("\\", "/"):gsub("/+$", ""), ".cache/huggingface")
    end
  end
  return join_path(base, "hub")
end

local function faster_whisper_hub_folder_name(model_id)
  model_id = tostring(model_id or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if model_id == "" then
    return nil
  end
  return "models--Systran--faster-whisper-" .. model_id
end

local function format_bytes(n)
  if not n or n < 0 then
    return "—"
  end
  if n < 1024 then
    return tostring(n) .. " B"
  end
  if n < 1048576 then
    return string.format("%.1f KB", n / 1024)
  end
  if n < 1073741824 then
    return string.format("%.1f MB", n / 1048576)
  end
  return string.format("%.2f GB", n / 1073741824)
end

local os_str = r.GetOS() or ""
local is_win = os_str:match("Win") ~= nil

--- Recursive size using REAPER APIs (fallback if du/PowerShell unavailable).
local function dir_total_bytes_lua(root)
  local total = 0
  local function scan(dir)
    local i = 0
    local file = r.EnumerateFiles(dir, i)
    while file do
      local full = join_path(dir, file)
      local fh = io.open(full, "rb")
      if fh then
        local sz = fh:seek("end")
        fh:close()
        if type(sz) == "number" then
          total = total + sz
        end
      end
      i = i + 1
      file = r.EnumerateFiles(dir, i)
    end
    i = 0
    local sub = r.EnumerateSubdirectories(dir, i)
    while sub do
      scan(join_path(dir, sub))
      i = i + 1
      sub = r.EnumerateSubdirectories(dir, i)
    end
  end
  pcall(scan, root)
  return total
end

local function dir_total_bytes_fast(path)
  path = path:gsub("\\", "/")
  if is_win then
    -- PowerShell -LiteralPath uses single quotes; escape ' as ''. Avoid ''' in Lua strings (lexer break).
    local p_ps = path:gsub("'", "''")
    local cmd =
      [=[powershell -NoProfile -Command "(Get-ChildItem -LiteralPath ']=]
      .. p_ps
      .. [=[' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum"]=]
    local h = io.popen(cmd)
    if not h then
      return dir_total_bytes_lua(path)
    end
    local out = h:read("*a") or ""
    h:close()
    local n = tonumber((out:gsub("%s+", "")))
    if n and n > 0 then
      return math.floor(n)
    end
    return dir_total_bytes_lua(path)
  end
  local esc = path:gsub("'", "'\\''")
  local h = io.popen("du -sk '" .. esc .. "' 2>/dev/null")
  if not h then
    return dir_total_bytes_lua(path)
  end
  local line = h:read("*l") or ""
  h:close()
  local kb = tonumber(line:match("^(%d+)"))
  if kb then
    return kb * 1024
  end
  return dir_total_bytes_lua(path)
end

local models = split_null(MODEL_ITEMS_STR)
local model_saved = es_get("MODEL", "large-v2")

local state = {
  model_idx = index_in_list(MODEL_ITEMS_STR, model_saved),
  model_text = model_saved,
  language = es_get("LANGUAGE", ""),
  interp_idx = index_in_list(INTERP_ITEMS_STR, es_get("INTERPOLATE_METHOD", "linear")),
  marker_idx = index_in_list(MARKER_ITEMS_STR, es_get("MARKER_AT", "start")),
  timeout_ms = es_get("TIMEOUT_MS", "0"),
  max_markers = es_get("MAX_WORD_MARKERS", "1500"),
  use_background = es_bool("USE_BACKGROUND", true),
  write_notes = es_bool("WRITE_ITEM_NOTES", true),
  write_markers = es_bool("WRITE_TAKE_MARKERS", true),
  device_idx = index_in_list(DEVICE_ITEMS_STR, es_get("DEVICE", "cpu")),
  compute_idx = index_in_list(COMPUTE_ITEMS_STR, es_get("COMPUTE_TYPE", "int8")),
  status = "",
  status_err = false,
  should_close = false,
  --- [model_id] = bytes on disk, or nil if repo folder not in hub
  cache_bytes = {},
  hub_dir_display = "",
  model_combo_str = MODEL_ITEMS_STR,
  custom_cache_note = "",
}

local function build_model_combo_str()
  local parts = {}
  for _, m in ipairs(models) do
    local sz = state.cache_bytes[m]
    local tag = "   · not cached"
    if type(sz) == "number" then
      if sz > 0 then
        tag = "   · on disk " .. format_bytes(sz)
      else
        tag = "   · cached (0 B)"
      end
    end
    parts[#parts + 1] = m .. tag
  end
  return table.concat(parts, "\0") .. "\0"
end

local function refresh_hf_cache_status()
  state.cache_bytes = {}
  state.custom_cache_note = ""
  local hub = huggingface_hub_dir()
  if not hub then
    state.hub_dir_display = "HF hub: (set HOME / USERPROFILE, or HF_HOME)"
    state.model_combo_str = build_model_combo_str()
    return
  end
  state.hub_dir_display = "HF hub: " .. hub
  if not path_exists(hub) then
    state.hub_dir_display = state.hub_dir_display .. " (folder not found yet — downloads go here on first run)"
    state.model_combo_str = build_model_combo_str()
    return
  end
  for _, m in ipairs(models) do
    local folder = faster_whisper_hub_folder_name(m)
    if folder then
      local full = join_path(hub, folder)
      if path_exists(full) then
        state.cache_bytes[m] = dir_total_bytes_fast(full)
      end
    end
  end
  state.model_combo_str = build_model_combo_str()

  local custom = (state.model_text or ""):match("^%s*(.-)%s*$") or ""
  local listed = false
  for _, m in ipairs(models) do
    if m == custom then
      listed = true
      break
    end
  end
  if custom ~= "" and not listed then
    local folder = faster_whisper_hub_folder_name(custom)
    if folder then
      local full = join_path(hub, folder)
      if path_exists(full) then
        local b = dir_total_bytes_fast(full)
        state.custom_cache_note = "Custom id cache: on disk " .. format_bytes(b) .. "  (" .. folder .. ")"
      else
        state.custom_cache_note = "Custom id: not cached  (expected " .. folder .. ")"
      end
    end
  end
end

--- Only probes the custom model id (fast while typing; avoids re-scanning every preset).
local function update_custom_cache_line_only()
  state.custom_cache_note = ""
  local hub = huggingface_hub_dir()
  if not hub or not path_exists(hub) then
    return
  end
  local custom = (state.model_text or ""):match("^%s*(.-)%s*$") or ""
  local listed = false
  for _, m in ipairs(models) do
    if m == custom then
      listed = true
      break
    end
  end
  if custom == "" or listed then
    return
  end
  local folder = faster_whisper_hub_folder_name(custom)
  if not folder then
    return
  end
  local full = join_path(hub, folder)
  if path_exists(full) then
    local b = dir_total_bytes_fast(full)
    state.custom_cache_note = "Custom id cache: on disk " .. format_bytes(b) .. "  (" .. folder .. ")"
  else
    state.custom_cache_note = "Custom id: not cached  (expected " .. folder .. ")"
  end
end

local function save_settings()
  local model = (state.model_text or ""):match("^%s*(.-)%s*$") or ""
  if model == "" then
    state.status = "Model name is empty."
    state.status_err = true
    return
  end
  local to = tonumber(state.timeout_ms)
  if not to or to < 0 then
    state.status = "TIMEOUT_MS must be a number ≥ 0 (0 = no limit on blocking path)."
    state.status_err = true
    return
  end
  local mm = tonumber(state.max_markers)
  if not mm or mm < 1 then
    state.status = "MAX_WORD_MARKERS must be a positive integer."
    state.status_err = true
    return
  end

  local marker_labels = split_null(MARKER_ITEMS_STR)
  local interp_labels = split_null(INTERP_ITEMS_STR)
  local device_labels = split_null(DEVICE_ITEMS_STR)
  local compute_labels = split_null(COMPUTE_ITEMS_STR)

  local marker_at = marker_labels[state.marker_idx + 1] or "start"
  local interp = interp_labels[state.interp_idx + 1] or "linear"
  local device = device_labels[state.device_idx + 1] or "cpu"
  local compute = compute_labels[state.compute_idx + 1] or "int8"

  r.SetExtState(SECTION, "MODEL", model, true)
  r.SetExtState(SECTION, "LANGUAGE", state.language, true)
  r.SetExtState(SECTION, "INTERPOLATE_METHOD", interp, true)
  r.SetExtState(SECTION, "MARKER_AT", marker_at, true)
  r.SetExtState(SECTION, "TIMEOUT_MS", tostring(math.floor(to)), true)
  r.SetExtState(SECTION, "MAX_WORD_MARKERS", tostring(math.floor(mm)), true)
  r.SetExtState(SECTION, "USE_BACKGROUND", state.use_background and "1" or "0", true)
  r.SetExtState(SECTION, "WRITE_ITEM_NOTES", state.write_notes and "1" or "0", true)
  r.SetExtState(SECTION, "WRITE_TAKE_MARKERS", state.write_markers and "1" or "0", true)
  r.SetExtState(SECTION, "DEVICE", device, true)
  r.SetExtState(SECTION, "COMPUTE_TYPE", compute, true)

  state.status = "Saved to global extstate " .. SECTION .. "."
  state.status_err = false
end

refresh_hf_cache_status()

local ctx = ImGui.CreateContext(WINDOW_TITLE)

local function loop()
  local flags = ImGui.WindowFlags_NoCollapse
  ImGui.SetNextWindowSize(ctx, 640, 540, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true, flags)
  if visible then
    ImGui.TextWrapped(
      ctx,
      "These values are read by the action “WhisperX dictation (selected item to JSON)”. Save, then run that action."
    )
    ImGui.Separator(ctx)

    ImGui.TextWrapped(ctx, state.hub_dir_display)
    ImGui.TextColored(
      ctx,
      0x888888FF,
      "Tags assume Systran/faster-whisper-* in the Hugging Face hub cache (WhisperX default). Refresh after downloads."
    )
    if ImGui.SmallButton(ctx, "Refresh cache status") then
      refresh_hf_cache_status()
    end

    local rv
    rv, state.model_idx = ImGui.Combo(ctx, "Model preset", state.model_idx, state.model_combo_str)
    if rv then
      local pick = models[state.model_idx + 1]
      if pick then
        state.model_text = pick
      end
      refresh_hf_cache_status()
    end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Help##model") then
      state.status =
        "Pick a Whisper / faster-whisper checkpoint. large-v* is slow on CPU; first run may download multi-GB from Hugging Face."
      state.status_err = false
    end
    if state.model_idx < 0 then
      state.model_idx = 0
    end
    if state.model_idx >= #models then
      state.model_idx = #models - 1
    end
    ImGui.Text(ctx, "Model id saved to extstate (edit for custom ids e.g. large-v3-turbo):")
    rv, state.model_text = ImGui.InputText(ctx, "##model_text", state.model_text or "")
    if rv then
      state.model_idx = index_in_list(MODEL_ITEMS_STR, state.model_text)
      update_custom_cache_line_only()
    end
    if state.custom_cache_note ~= "" then
      ImGui.TextColored(ctx, 0xA0A0A0FF, state.custom_cache_note)
    end

    ImGui.Spacing(ctx)
    rv, state.language = ImGui.InputTextWithHint(
      ctx,
      "Language (optional)",
      "empty = auto-detect (ISO code e.g. en, ja)",
      state.language or ""
    )

    rv, state.interp_idx = ImGui.Combo(ctx, "Align interpolation", state.interp_idx, INTERP_ITEMS_STR)
    rv, state.marker_idx = ImGui.Combo(ctx, "Take marker time", state.marker_idx, MARKER_ITEMS_STR)

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "Inference")
    rv, state.device_idx = ImGui.Combo(ctx, "Device", state.device_idx, DEVICE_ITEMS_STR)
    rv, state.compute_idx = ImGui.Combo(ctx, "Compute type", state.compute_idx, COMPUTE_ITEMS_STR)
    ImGui.TextWrapped(
      ctx,
      "cuda needs an NVIDIA GPU + CUDA build; mps is Apple Silicon. int8 is fastest on CPU; float32 is most compatible."
    )

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "REAPER integration")
    rv, state.timeout_ms = ImGui.InputText(ctx, "TIMEOUT_MS (blocking path)", state.timeout_ms or "0")
    if is_win and ImGui.BeginDisabled then
      ImGui.BeginDisabled(ctx, true)
    end
    rv, state.use_background = ImGui.Checkbox(ctx, "Background job + progress (macOS/Linux)", state.use_background)
    if is_win and ImGui.EndDisabled then
      ImGui.EndDisabled(ctx)
    end
    if is_win then
      ImGui.TextColored(ctx, 0x888888FF, "Windows always uses the blocking subprocess path.")
    end
    rv, state.write_notes = ImGui.Checkbox(ctx, "Write plain transcript to item notes", state.write_notes)
    rv, state.write_markers = ImGui.Checkbox(ctx, "Write take markers from word TSV (clears all markers on take)", state.write_markers)
    rv, state.max_markers = ImGui.InputText(ctx, "MAX_WORD_MARKERS cap", state.max_markers or "1500")

    ImGui.Separator(ctx)
    if state.status ~= "" then
      if state.status_err then
        ImGui.TextColored(ctx, 0x7D7DFFFF, state.status)
      else
        ImGui.TextColored(ctx, 0x8FD18CFF, state.status)
      end
    end
    if ImGui.Button(ctx, "Save", 120, 0) then
      save_settings()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Close", 100, 0) then
      state.should_close = true
    end

    ImGui.End(ctx)
  end

  if open and not state.should_close then
    r.defer(loop)
  end
  -- Do not call DestroyContext: ReaImGui/imgui.lua builds differ; omitting avoids close errors. Context ends with script.
end

r.defer(loop)
