-- @description WhisperX: word overlay on video (Video Processor from take markers)
-- @version 1.17
-- @author Bryan
-- @about
--   Builds a Video Processor effect on the active take of the selected item. Reads
--   take markers on the active take (plain names or legacy wx|…) and shows each
--   word from that marker's source time until the next word marker (last word until
--   source end or +2s fallback).
--   Position and size are Video Processor parameters (knobs) on the effect.
--   First run adds a new Video processor at the end of the take FX chain (won't hijack an
--   existing VP). Run again on the same item to refresh words; the script finds its
--   marker in the code and replaces it in place. If word markers are on another take of the
--   same item, the script switches the active take to that take.
--   Code is written in REAPER's Video Processor chunk form (tab + | per line) so the FX shows the preset.
--   Japanese/Chinese takes (mostly Hiragana/Katakana/CJK): words are joined with no spaces in the overlay.
--   For presets and line grouping, use "WhisperX word overlay bridge (ReaImGui).lua".

local r = reaper

local function mb(msg)
  r.MB(msg, "WhisperX word overlay", 0)
end

local _, script_fn = r.get_action_context()
local script_dir = (script_fn or ""):gsub("\\", "/"):match("^(.*)/[^/]+$") or ""
local core_path = script_dir .. "/WhisperX word overlay core.lua"
local chunk, cerr = loadfile(core_path)
if not chunk then
  mb("Could not load core library:\n" .. core_path .. "\n" .. tostring(cerr))
  return
end
local W = chunk()
if type(W) ~= "table" or not W.build_eel_body then
  mb("Core library returned invalid module: " .. core_path)
  return
end

r.Undo_BeginBlock()

local nsel = r.CountSelectedMediaItems(0)
if nsel ~= 1 then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb("Select exactly one media item (your video or clip with take markers for each word).")
  return
end

local item = r.GetSelectedMediaItem(0, 0)
local take, words, take_was_switched = W.find_take_and_wx_words(item)
if not take then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb("No take on the selected item.")
  return
end

if #words == 0 then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  local diag = ""
  if r.GetNumTakeMarkers then
    local nm = r.GetNumTakeMarkers(take)
    diag = "\n\nOn the take we checked: " .. tostring(nm) .. " take marker(s) total."
    if nm > 0 then
      local name, _, sp = W.get_take_marker_srcpos_name(take, 0)
      diag = diag
        .. "\nFirst marker name (debug): "
        .. tostring(name)
        .. "\nFirst marker srcpos (debug): "
        .. tostring(sp)
    end
  end
  mb(
    "No take markers with a valid source time were found on this item.\n"
      .. "Add word markers (e.g. WhisperX dictation), and REAPER must return each marker's src position."
      .. diag
  )
  return
end

if take_was_switched and r.SetActiveTake then
  r.SetActiveTake(take)
end

local src_end = W.source_length_for_take(take)

local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
if not startoffs or not playrate or playrate == 0 then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb("Could not read take start offset / playrate.")
  return
end

local body, err = W.build_eel_body(words, src_end, startoffs, playrate, W.default_display_opts())
if not body then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb(err or "Build failed.")
  return
end

local chunk_ok, ichunk = r.GetItemStateChunk(item, "", false)
if not chunk_ok or type(ichunk) ~= "string" then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb("GetItemStateChunk failed.")
  return
end

local need_new_vp = not ichunk:find(W.SENTINEL, 1, true)
local new_vp_fx_guid = nil
if need_new_vp then
  if not r.TakeFX_AddByName then
    r.Undo_EndBlock("WhisperX word overlay", -1)
    mb("TakeFX_AddByName not available in this REAPER version.")
    return
  end
  local idx = r.TakeFX_AddByName(take, "Video processor", -1)
  if not idx or idx < 0 then
    r.Undo_EndBlock("WhisperX word overlay", -1)
    mb("Could not add Video processor to the take. Install REAPER video features or add it manually once.")
    return
  end
  if r.TakeFX_GetFXGUID then
    new_vp_fx_guid = r.TakeFX_GetFXGUID(take, idx)
  end
end

local ok_upsert, uerr = W.upsert_video_processor_code(item, take, W.eel_plain_to_reaper_vp_chunk(body), new_vp_fx_guid)
if not ok_upsert then
  r.Undo_EndBlock("WhisperX word overlay", -1)
  mb("Could not write Video Processor code:\n" .. tostring(uerr))
  return
end

r.UpdateArrange()
r.Undo_EndBlock("WhisperX word overlay (Video Processor)", -1)

local switched_line = take_was_switched and "Switched active take to the one that has word markers.\n\n" or ""
mb(
  string.format(
    switched_line
      .. "Video Processor updated on this take.\n\nWords: %d\nStart offset: %.4f s  Playrate: %.4f\n\nAdjust position and size with the effect's first three parameters.\n\nTip: use the ReaImGui bridge for line presets.",
    #words,
    startoffs,
    playrate
  )
)
