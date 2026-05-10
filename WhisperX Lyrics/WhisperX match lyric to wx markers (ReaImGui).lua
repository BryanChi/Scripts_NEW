-- @description WhisperX: match pasted lyric to take markers (ReaImGui)
-- @version 1.02
-- @author Bryan
-- @about
--   Select one media item whose active (or first) take has take markers (word timing from dictation, etc.).
--   Paste the official lyric (tokens separated by spaces; optional “UTF-8 characters” mode for unspaced CJK).
--   Runs Needleman–Wunsch alignment between marker names and lyric tokens, then clears all markers on that take
--   and rewrites plain marker names (no prefix; times preserved).
--   Use dry-run first to see stats.
--   Requires ReaImGui and “WhisperX word overlay core.lua” in the same folder.

local r = reaper

local WINDOW_TITLE = "WhisperX — lyric ↔ take markers"
local SECTION = "BRYAN_WX_LYRIC_MATCH"

local _, script_fn = r.get_action_context()
local script_dir = (script_fn or ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ""
local core_path = script_dir .. "/WhisperX word overlay core.lua"
local chunk, cerr = loadfile(core_path)
if not chunk then
  r.MB("Could not load:\n" .. core_path .. "\n" .. tostring(cerr), WINDOW_TITLE, 0)
  return
end
local W = chunk()
if type(W) ~= "table" or not W.find_take_and_wx_words then
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

local function im_input_text_flag(name)
  local ok, v = pcall(function()
    return ImGui[name]
  end)
  if ok and type(v) == "number" then
    return v
  end
  return nil
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

local function es_set(key, val)
  r.SetExtState(SECTION, key, tostring(val), true)
end

--- Whitespace tokens (Latin-style lyric).
local function tokens_whitespace(s)
  s = tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local t = {}
  for w in s:gmatch("%S+") do
    t[#t + 1] = w
  end
  return t
end

--- One token per Unicode scalar (for pasted CJK with no spaces).
local function tokens_utf8_chars(s)
  s = tostring(s or "")
  local t = {}
  if not utf8 or not utf8.codes then
    return t
  end
  for _, cp in utf8.codes(s) do
    if not (cp == 9 or cp == 10 or cp == 13 or cp == 32) then
      t[#t + 1] = utf8.char(cp)
    end
  end
  return t
end

local function norm_key(s)
  s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s:find("[\128-\255]") then
    return s
  end
  return s:lower()
end

local function sub_cost(a, b)
  if a == b then
    return 0
  end
  if norm_key(a) == norm_key(b) then
    return 0
  end
  return 2
end

local GAP = 1

--- Needleman–Wunsch global alignment. Returns array new_asr[i] = lyric text to use for ASR slot i, or asr[i] if unmatched.
local function align_asr_to_lyric(asr, lyric)
  local n, m = #asr, #lyric
  if n == 0 then
    return nil, "No marker words on the take."
  end
  if m == 0 then
    return nil, "Paste lyric tokens first (whitespace- or character-split)."
  end
  local huge = 1e15
  local dp = {}
  local pr = {}
  for i = 0, n do
    dp[i] = {}
    pr[i] = {}
    for j = 0, m do
      dp[i][j] = huge
    end
  end
  dp[0][0] = 0
  for i = 1, n do
    dp[i][0] = dp[i - 1][0] + GAP
    pr[i][0] = 2
  end
  for j = 1, m do
    dp[0][j] = dp[0][j - 1] + GAP
    pr[0][j] = 3
  end
  for i = 1, n do
    for j = 1, m do
      local c_diag = dp[i - 1][j - 1] + sub_cost(asr[i], lyric[j])
      local c_up = dp[i - 1][j] + GAP
      local c_left = dp[i][j - 1] + GAP
      -- Prefer diagonal on ties, then up, then left.
      local c, p = c_diag, 1
      if c_up < c then
        c, p = c_up, 2
      end
      if c_left < c then
        c, p = c_left, 3
      end
      dp[i][j] = c
      pr[i][j] = p
    end
  end

  local new_txt = {}
  for ii = 1, n do
    new_txt[ii] = asr[ii]
  end
  local i, j = n, m
  local exact_same, kept_asr, lyric_unused = 0, 0, 0
  while i > 0 or j > 0 do
    local p = pr[i] and pr[i][j] or 0
    if i > 0 and j > 0 and p == 1 then
      new_txt[i] = lyric[j]
      if norm_key(asr[i]) == norm_key(lyric[j]) then
        exact_same = exact_same + 1
      end
      i, j = i - 1, j - 1
    elseif i > 0 and p == 2 then
      new_txt[i] = asr[i]
      kept_asr = kept_asr + 1
      i = i - 1
    elseif j > 0 and p == 3 then
      lyric_unused = lyric_unused + 1
      j = j - 1
    elseif i > 0 then
      new_txt[i] = asr[i]
      kept_asr = kept_asr + 1
      i = i - 1
    elseif j > 0 then
      lyric_unused = lyric_unused + 1
      j = j - 1
    else
      break
    end
  end

  local changed = 0
  for k = 1, n do
    if new_txt[k] ~= asr[k] then
      changed = changed + 1
    end
  end

  local stats = {
    exact_same = exact_same,
    kept_asr = kept_asr,
    lyric_tokens_unused = lyric_unused,
    changed = changed,
    cost = dp[n][m],
  }
  return new_txt, nil, stats
end

local function wipe_all_take_markers(take)
  if not take or not r.GetNumTakeMarkers or not r.DeleteTakeMarker then
    return
  end
  local n = r.GetNumTakeMarkers(take)
  for idx = n - 1, 0, -1 do
    r.DeleteTakeMarker(take, idx)
  end
end

local function sanitize_marker_word(w)
  w = tostring(w or ""):gsub("[\r\n]", " ")
  w = w:gsub("|", "\239\189\156")
  if #w > 180 then
    w = w:sub(1, 180) .. "…"
  end
  return w
end

local function apply_new_words_to_take(take, words, new_w)
  if not take or not r.SetTakeMarker or #words ~= #new_w then
    return false, "Internal: length mismatch."
  end
  r.Undo_BeginBlock()
  wipe_all_take_markers(take)
  for k = 1, #words do
    local pos = words[k].t
    if type(pos) == "number" then
      r.SetTakeMarker(take, -1, sanitize_marker_word(new_w[k]), pos)
    end
  end
  r.Undo_EndBlock("WhisperX: lyric align to take markers", -1)
  r.UpdateArrange()
  return true, nil
end

local state = {
  lyric_text = es_get("LYRIC_TEXT", ""),
  char_split = es_bool("CHAR_SPLIT", false),
  dry_run = es_bool("DRY_RUN", false),
  status = "",
  status_err = false,
  should_close = false,
}

local function save_prefs()
  es_set("CHAR_SPLIT", state.char_split and "1" or "0")
  es_set("DRY_RUN", state.dry_run and "1" or "0")
  r.SetExtState(SECTION, "LYRIC_TEXT", state.lyric_text or "", true)
end

local function run_align()
  state.status_err = false
  state.status = ""
  if r.CountSelectedMediaItems(0) ~= 1 then
    state.status_err = true
    state.status = "Select exactly one media item with take markers on a take."
    return
  end
  local item = r.GetSelectedMediaItem(0, 0)
  local take, words = W.find_take_and_wx_words(item)
  if not take or #words == 0 then
    state.status_err = true
    state.status = "No take markers with valid times on this item’s takes."
    return
  end

  local lyric_toks
  if state.char_split then
    lyric_toks = tokens_utf8_chars(state.lyric_text)
    if #lyric_toks == 0 then
      state.status_err = true
      state.status = "UTF-8 character mode: no non-space characters in the paste (or utf8 library missing)."
      return
    end
  else
    lyric_toks = tokens_whitespace(state.lyric_text)
  end

  local asr = {}
  for i = 1, #words do
    asr[i] = words[i].w
  end

  local new_w, err, stats = align_asr_to_lyric(asr, lyric_toks)
  if not new_w then
    state.status_err = true
    state.status = err or "Alignment failed."
    return
  end

  local msg = string.format(
    "ASR words: %d  Lyric tokens: %d  DP cost: %.0f\n"
      .. "Diagonal exact (case-fold ASCII / raw UTF-8): %d\n"
      .. "Markers left as ASR (gap in lyric): %d\n"
      .. "Lyric tokens skipped (gap in ASR): %d\n"
      .. "Markers whose text changed: %d",
    #asr,
    #lyric_toks,
    stats.cost,
    stats.exact_same,
    stats.kept_asr,
    stats.lyric_tokens_unused,
    stats.changed
  )

  if state.dry_run then
    state.status = "Dry run — no changes written.\n" .. msg
    return
  end

  local ok, werr = apply_new_words_to_take(take, words, new_w)
  if not ok then
    state.status_err = true
    state.status = werr or "Could not write markers."
    return
  end
  state.status = "Updated take markers.\n" .. msg
  save_prefs()
end

local ctx = ImGui.CreateContext(WINDOW_TITLE)

local function loop()
  local flags = ImGui.WindowFlags_NoCollapse
  ImGui.SetNextWindowSize(ctx, 520, 420, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true, flags)
  if visible then
    ImGui.TextWrapped(
      ctx,
      "Select one item with take markers (all marker names are used as ASR tokens). Paste the correct lyric, then align. "
        .. "Latin: separate words with spaces (line breaks OK). "
        .. "Japanese/Chinese without spaces between syllables: enable “UTF-8 characters” so each character is one lyric token."
    )
    ImGui.Separator(ctx)

    local ml_flags = 0
    local tab_in = im_input_text_flag("InputTextFlags_AllowTabInput")
    if tab_in then
      ml_flags = ml_flags | tab_in
    end
    local ww = im_input_text_flag("InputTextFlags_WordWrap")
    if ww then
      ml_flags = ml_flags | ww
    end
    local line_h = 18
    if ImGui.GetTextLineHeight then
      line_h = ImGui.GetTextLineHeight(ctx)
    end
    ImGui.Text(ctx, "Reference lyric (paste):")
    local rv
    rv, state.lyric_text = ImGui.InputTextMultiline(
      ctx,
      "##lyric_paste",
      state.lyric_text or "",
      -1,
      line_h * 12,
      ml_flags
    )

    rv, state.char_split = ImGui.Checkbox(ctx, "Split lyric into UTF-8 characters (unspaced CJK)", state.char_split)
    rv, state.dry_run = ImGui.Checkbox(ctx, "Dry run (show stats only, do not change markers)", state.dry_run)

    ImGui.Separator(ctx)
    if ImGui.Button(ctx, "Align lyric to take markers", 220, 0) then
      run_align()
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save pasted lyric to extstate", 200, 0) then
      save_prefs()
      state.status_err = false
      state.status = "Saved preferences + lyric text."
    end

    ImGui.Separator(ctx)
    if state.status ~= "" then
      if state.status_err then
        ImGui.TextColored(ctx, 0x7D7DFFFF, state.status)
      else
        ImGui.TextWrapped(ctx, state.status)
      end
    end

    ImGui.Separator(ctx)
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
