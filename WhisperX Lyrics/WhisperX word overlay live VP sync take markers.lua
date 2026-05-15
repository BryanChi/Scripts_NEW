-- @description WhisperX: toggle live VP sync when take markers change
-- @version 1.02
-- @author Bryan
-- @about
--   Run once to start, run again to stop. While active, if exactly one item is selected and its active take has
--   WhisperX word markers, the script watches marker times/names and rewrites the take’s Video Processor overlay
--   whenever they change. Preset / karaoke / layout sliders / subtitle text come from the same extstate as the
--   ReaImGui bridge (BRYAN_WX_OVERLAY_UI). Save settings or use “Live” in the bridge so EDITOR_TEXT is current.
--   Per-word styles use the media item’s P_EXT blob (written by the bridge), not global extstate, when an item is selected.
--   Add the Video Processor once from the bridge (“Apply”) if the item has no overlay yet. Uses SetItemStateChunk
--   with undo disabled for each tweak to avoid flooding the undo stack.

local r = reaper

local SECTION = "BRYAN_WX_OVERLAY_UI"
local ACT_KEY = "MARKER_VP_SYNC_ACTIVE"

local _, script_fn = r.get_action_context()
local script_dir = (script_fn or ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ""
local core_path = script_dir .. "/WhisperX word overlay core.lua"
local chunk, cerr = loadfile(core_path)
if not chunk then
  r.MB("Could not load:\n" .. core_path .. "\n" .. tostring(cerr), "WhisperX live marker sync", 0)
  return
end
local W = chunk()
if type(W) ~= "table" or not W.build_eel_body then
  r.MB("Invalid core: " .. core_path, "WhisperX live marker sync", 0)
  return
end

if r.GetExtState(SECTION, ACT_KEY) == "1" then
  r.SetExtState(SECTION, ACT_KEY, "0", true)
  r.MB("Take-marker → Video Processor live sync stopped.\nRun this action again to start.", "WhisperX live marker sync", 0)
  return
end

r.SetExtState(SECTION, ACT_KEY, "1", true)
r.MB(
  "Live sync started.\n\n"
    .. "• Select one item with word take markers.\n"
    .. "• Preset/subtitle come from bridge extstate (use Save settings or Live VP in the bridge).\n"
    .. "• If there is no overlay VP yet, use the bridge “Apply to selected item” once first.\n\n"
    .. "Run this action again to stop.",
  "WhisperX live marker sync",
  0
)

local last_sig = ""

local function tick()
  if r.GetExtState(SECTION, ACT_KEY) ~= "1" then
    return
  end

  if r.CountSelectedMediaItems(0) ~= 1 then
    r.defer(tick)
    return
  end

  local item = r.GetSelectedMediaItem(0, 0)
  local take, words = W.find_take_and_wx_words(item)
  if not take or #words == 0 then
    r.defer(tick)
    return
  end

  local sig = W.overlay_marker_signature(words)
  if sig == last_sig then
    r.defer(tick)
    return
  end
  last_sig = sig

  local opts = W.overlay_display_opts_from_extstate(SECTION, item, #words)
  if (opts.editor_text or "") == "" then
    opts.editor_text = W.default_editor_text_from_words(words)
  end

  local src_end = W.source_length_for_take(take)
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not startoffs or not playrate or playrate == 0 then
    r.defer(tick)
    return
  end

  local body, err = W.build_eel_body(words, src_end, startoffs, playrate, opts)
  if body then
    local ok = W.upsert_video_processor_code(item, take, W.eel_plain_to_reaper_vp_chunk(body), nil, false)
    if ok then
      r.UpdateArrange()
    end
  end

  r.defer(tick)
end

r.defer(tick)
