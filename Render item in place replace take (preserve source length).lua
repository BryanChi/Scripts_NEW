-- @description Render item in place (replace active take, preserve source length)
-- @version 1.13
-- @author Bryan
-- @about
--   For each selected media item, runs REAPER's built-in "Item: render items to new take"
--   and replaces ONLY the original active take's source with the rendered result.
--   Other takes are preserved.
--   This variant preserves the original active take's source-based item length.

local r = reaper

local CMD_RENDER_ITEMS_NEW_TAKE = 40601 -- Item: render items to new take
local CMD_DELETE_CURRENT_TAKE = 40129 -- Take: Delete current take from items
local HISTORY_SECTION = "BRYAN_RENDER_ITEM_HISTORY"
local HISTORY_LIMIT = 30

local function collect_selected_items()
  local items = {}
  local n = r.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    items[#items + 1] = r.GetSelectedMediaItem(0, i)
  end
  return items
end

local function get_take_guid(take)
  if not take then return nil end
  local ok, guid = r.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  if ok and guid and guid ~= "" then
    return guid
  end
  return nil
end

local function get_item_guid(item)
  if not item then return nil end
  local ok, guid = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok and guid and guid ~= "" then
    return guid
  end
  return nil
end

local function encode_blob(s)
  if not s then return "" end
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function split_string(s, sep)
  local out = {}
  if not s or s == "" then return out end
  local start = 1
  while true do
    local i, j = s:find(sep, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = j + 1
  end
  return out
end

local function load_item_history(item_guid)
  local _, blob = r.GetProjExtState(0, HISTORY_SECTION, item_guid)
  if not blob or blob == "" then return {} end
  local rows = split_string(blob, "\n")
  local entries = {}
  for _, row in ipairs(rows) do
    if row ~= "" then
      local parts = split_string(row, "\t")
      if #parts >= 4 then
        entries[#entries + 1] = {
          ts = parts[1],
          label = parts[2],
          summary = parts[3],
          chunk = parts[4],
        }
      end
    end
  end
  return entries
end

local function save_item_history(item_guid, entries)
  if #entries == 0 then
    r.SetProjExtState(0, HISTORY_SECTION, item_guid, "")
    return
  end
  local rows = {}
  local first = math.max(1, #entries - HISTORY_LIMIT + 1)
  for i = first, #entries do
    local e = entries[i]
    rows[#rows + 1] = table.concat({
      e.ts or "",
      e.label or "",
      e.summary or "",
      e.chunk or "",
    }, "\t")
  end
  r.SetProjExtState(0, HISTORY_SECTION, item_guid, table.concat(rows, "\n"))
end

local function save_item_snapshot(item, summary)
  local item_guid = get_item_guid(item)
  if not item_guid then return end
  local ok_chunk, chunk = r.GetItemStateChunk(item, "", false)
  if not ok_chunk or not chunk or chunk == "" then return end

  local entries = load_item_history(item_guid)
  local encoded = encode_blob(chunk)
  local prev = entries[#entries]
  if prev and prev.chunk == encoded then
    return
  end

  entries[#entries + 1] = {
    ts = tostring(os.time()),
    label = os.date("%Y-%m-%d %H:%M:%S"),
    summary = summary or "Before render",
    chunk = encoded,
  }
  save_item_history(item_guid, entries)
end

local function find_take_index_by_guid(item, wanted_guid)
  if not wanted_guid then return -1 end
  local n = r.GetMediaItemNumTakes(item)
  for idx = 0, n - 1 do
    local take = r.GetMediaItemTake(item, idx)
    if get_take_guid(take) == wanted_guid then
      return idx
    end
  end
  return -1
end

local function find_active_take_index(item)
  local active = r.GetActiveTake(item)
  if not active then return -1 end
  local n = r.GetMediaItemNumTakes(item)
  for idx = 0, n - 1 do
    if r.GetMediaItemTake(item, idx) == active then
      return idx
    end
  end
  return -1
end

local function get_take_source_backed_item_length(take)
  if not take then return nil end
  local src = r.GetMediaItemTake_Source(take)
  if not src then return nil end

  local src_len = r.GetMediaSourceLength(src)
  if not src_len or src_len <= 0 then return nil end

  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not playrate or playrate == 0 then playrate = 1.0 end
  playrate = math.abs(playrate)
  if playrate == 0 then return nil end

  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  local remaining = src_len - startoffs
  if remaining <= 0 then
    return 0
  end

  return remaining / playrate
end

local function shorten_fx_name(raw_name)
  local name = tostring(raw_name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("^%s*(VST3i?|VSTi?|AUi?|AU|CLAPi?|CLAP|JSFX?|DXi?)%s*:%s*", "", 1)
  name = name:gsub("^%s*[^:]+:%s*", "", 1)
  name = name:gsub("%s*%b()$", "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

local function has_nonunity_stretch_markers(take)
  local marker_count = r.GetTakeNumStretchMarkers(take) or 0
  if marker_count <= 0 then
    return false, 0
  end

  local prev_pos, prev_src = nil, nil
  for idx = 0, marker_count - 1 do
    local ok, pos, srcpos = r.GetTakeStretchMarker(take, idx)
    if ok then
      if prev_pos ~= nil and prev_src ~= nil then
        local dpos = pos - prev_pos
        if math.abs(dpos) > 1e-9 then
          local segment_rate = (srcpos - prev_src) / dpos
          if math.abs(segment_rate - 1.0) > 0.001 then
            return true, marker_count
          end
        end
      end
      prev_pos, prev_src = pos, srcpos
    end
  end

  for idx = 0, marker_count - 1 do
    local slope = r.GetTakeStretchMarkerSlope(take, idx)
    if slope and math.abs(slope) > 0.001 then
      return true, marker_count
    end
  end

  return false, marker_count
end

local function shorten_envelope_name(raw_name)
  local name = tostring(raw_name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("^Take%s+", "")
  name = name:gsub("^Pre%-FX%s+", "")
  name = name:gsub("^Post%-FX%s+", "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

local function build_envelope_summary(take)
  local envelope_count = r.CountTakeEnvelopes(take) or 0
  if envelope_count <= 0 then
    return nil
  end

  local names = {}
  local seen = {}
  local max_names = 3
  for env_idx = 0, envelope_count - 1 do
    local env = r.GetTakeEnvelope(take, env_idx)
    if env then
      local ok, env_name = r.GetEnvelopeName(env, "")
      if ok and env_name and env_name ~= "" then
        local short = shorten_envelope_name(env_name)
        if short ~= "" and not seen[short] then
          seen[short] = true
          names[#names + 1] = short
          if #names >= max_names then
            break
          end
        end
      end
    end
  end

  if #names == 0 then
    return tostring(envelope_count) .. " envelope"
  end

  local summary = "Envelope " .. table.concat(names, ", ")
  if envelope_count > #names then
    summary = summary .. ", +" .. tostring(envelope_count - #names) .. " more"
  end
  return summary
end

local function build_render_adjustment_summary(take)
  if not take then return "Rendered" end
  local parts = {}

  local pitch = r.GetMediaItemTakeInfo_Value(take, "D_PITCH") or 0
  if math.abs(pitch) > 0.001 then
    parts[#parts + 1] = string.format("Pitch %.2fst", pitch)
  end

  local has_nonunity_stretch, stretch_count = has_nonunity_stretch_markers(take)
  if has_nonunity_stretch and stretch_count > 0 then
    parts[#parts + 1] = "Stretch markers " .. tostring(stretch_count)
  end

  local envelope_summary = build_envelope_summary(take)
  if envelope_summary then
    parts[#parts + 1] = envelope_summary
  end

  local fx_count = r.TakeFX_GetCount(take) or 0
  if fx_count > 0 then
    local names = {}
    local max_names = 3
    local show_n = math.min(fx_count, max_names)
    for fx_idx = 0, show_n - 1 do
      local ok, fx_name = r.TakeFX_GetFXName(take, fx_idx, "")
      if ok and fx_name and fx_name ~= "" then
        local short = shorten_fx_name(fx_name)
        if short ~= "" then
          names[#names + 1] = short
        end
      end
    end
    if fx_count > max_names then
      names[#names + 1] = "+" .. tostring(fx_count - max_names) .. " more"
    end
    if #names > 0 then
      parts[#parts + 1] = "FX " .. table.concat(names, ", ")
    else
      parts[#parts + 1] = "FX " .. tostring(fx_count)
    end
  end

  if #parts == 0 then
    return "Rendered"
  end
  return "Rendered: " .. table.concat(parts, " | ")
end

local function add_render_summary_marker(take, summary)
  if not take or not summary or summary == "" then return end
  if type(r.SetTakeMarker) ~= "function" then return end
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
  r.SetTakeMarker(take, -1, summary, startoffs, -1)
end

local function copy_take_source_to_take(source_take, destination_take)
  if not source_take or not destination_take then
    return false, "missing source or destination take"
  end

  local function clear_take_fx(take)
    local fx_count = r.TakeFX_GetCount(take)
    if fx_count and fx_count > 0 then
      for fx = fx_count - 1, 0, -1 do
        r.TakeFX_Delete(take, fx)
      end
    end
  end

  local function clear_take_stretch_markers(take)
    local marker_count = r.GetTakeNumStretchMarkers(take)
    if marker_count and marker_count > 0 then
      r.DeleteTakeStretchMarkers(take, 0, marker_count)
    end
  end

  local function clear_take_envelopes(take)
    local env_count = r.CountTakeEnvelopes(take)
    if not env_count or env_count <= 0 then
      return
    end
    for env_idx = env_count - 1, 0, -1 do
      local env = r.GetTakeEnvelope(take, env_idx)
      if env then
        local ai_count = r.CountAutomationItems(env) or 0
        for ai_idx = ai_count - 1, 0, -1 do
          r.DeleteAutomationItem(env, ai_idx)
        end
        r.DeleteEnvelopePointRange(env, -1e15, 1e15)
        r.Envelope_SortPoints(env)
      end
    end
  end

  local function sync_take_timing(dst_take, src_take)
    local src_startoffs = r.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS")
    local src_playrate = r.GetMediaItemTakeInfo_Value(src_take, "D_PLAYRATE")
    local src_pitch = r.GetMediaItemTakeInfo_Value(src_take, "D_PITCH")
    local src_preserve_pitch = r.GetMediaItemTakeInfo_Value(src_take, "B_PPITCH")

    if src_startoffs ~= nil then
      r.SetMediaItemTakeInfo_Value(dst_take, "D_STARTOFFS", src_startoffs)
    end
    if src_playrate ~= nil then
      r.SetMediaItemTakeInfo_Value(dst_take, "D_PLAYRATE", src_playrate)
    end
    if src_pitch ~= nil then
      r.SetMediaItemTakeInfo_Value(dst_take, "D_PITCH", src_pitch)
    end
    if src_preserve_pitch ~= nil then
      r.SetMediaItemTakeInfo_Value(dst_take, "B_PPITCH", src_preserve_pitch)
    end
  end

  local source = r.GetMediaItemTake_Source(source_take)
  if not source then
    return false, "source take has no source"
  end

  -- Preferred path: assign source object directly (works even for non-file-backed sources
  -- and preserves destination take index/position in the take stack).
  local set_ok = r.SetMediaItemTake_Source(destination_take, source)
  if set_ok ~= false then
    local dst_src = r.GetMediaItemTake_Source(destination_take)
    if dst_src then
      sync_take_timing(destination_take, source_take)
      clear_take_fx(destination_take)
      clear_take_stretch_markers(destination_take)
      clear_take_envelopes(destination_take)
      return true, nil
    end
  end

  -- Fallback path: recreate source from file path.
  local _, source_path = r.GetMediaSourceFileName(source, "")
  if not source_path or source_path == "" then
    return false, "could not read source file path"
  end

  local new_src = r.PCM_Source_CreateFromFile(source_path)
  if not new_src then
    return false, "could not create source from rendered file"
  end

  r.SetMediaItemTake_Source(destination_take, new_src)
  sync_take_timing(destination_take, source_take)
  clear_take_fx(destination_take)
  clear_take_stretch_markers(destination_take)
  clear_take_envelopes(destination_take)
  return true, nil
end

local function delete_take_by_guid(item, target_guid)
  local idx = find_take_index_by_guid(item, target_guid)
  if idx < 0 then
    return false, "take not found"
  end

  local take = r.GetMediaItemTake(item, idx)
  if not take then
    return false, "take pointer invalid"
  end

  local before = r.GetMediaItemNumTakes(item)
  if r.APIExists and r.APIExists("DeleteTake") then
    r.DeleteTake(take)
    if r.GetMediaItemNumTakes(item) == before - 1 then
      return true, nil
    end
  end

  if type(r.NF_DeleteTakeFromItem) == "function" then
    local idx_now = find_take_index_by_guid(item, target_guid)
    if idx_now >= 0 then
      r.NF_DeleteTakeFromItem(item, idx_now)
      if r.GetMediaItemNumTakes(item) == before - 1 then
        return true, nil
      end
    end
  end

  local idx_now = find_take_index_by_guid(item, target_guid)
  if idx_now >= 0 then
    local take_now = r.GetMediaItemTake(item, idx_now)
    if take_now then
      r.SetActiveTake(take_now)
      r.Main_OnCommand(CMD_DELETE_CURRENT_TAKE, 0)
      if r.GetMediaItemNumTakes(item) == before - 1 then
        return true, nil
      end
    end
  end

  return false, "failed to delete rendered temp take"
end

local function replace_by_swapping_to_rendered_take(item, original_active_guid, rendered_guid)
  local rendered_idx = find_take_index_by_guid(item, rendered_guid)
  if rendered_idx < 0 then
    return false, "rendered take not found for swap fallback"
  end

  local rendered_take = r.GetMediaItemTake(item, rendered_idx)
  if not rendered_take then
    return false, "rendered take pointer invalid for swap fallback"
  end

  local ok_del_orig, err_del_orig = delete_take_by_guid(item, original_active_guid)
  if not ok_del_orig then
    return false, err_del_orig or "failed deleting original take in swap fallback"
  end

  -- Re-find rendered take after deletion since indices may have changed.
  rendered_idx = find_take_index_by_guid(item, rendered_guid)
  if rendered_idx < 0 then
    return false, "rendered take missing after deleting original"
  end
  rendered_take = r.GetMediaItemTake(item, rendered_idx)
  if not rendered_take then
    return false, "rendered take pointer invalid after deleting original"
  end
  local fx_count = r.TakeFX_GetCount(rendered_take)
  if fx_count and fx_count > 0 then
    for fx = fx_count - 1, 0, -1 do
      r.TakeFX_Delete(rendered_take, fx)
    end
  end
  local marker_count = r.GetTakeNumStretchMarkers(rendered_take) or 0
  if marker_count > 0 then
    r.DeleteTakeStretchMarkers(rendered_take, 0, marker_count)
  end
  local env_count = r.CountTakeEnvelopes(rendered_take) or 0
  for env_idx = env_count - 1, 0, -1 do
    local env = r.GetTakeEnvelope(rendered_take, env_idx)
    if env then
      local ai_count = r.CountAutomationItems(env) or 0
      for ai_idx = ai_count - 1, 0, -1 do
        r.DeleteAutomationItem(env, ai_idx)
      end
      r.DeleteEnvelopePointRange(env, -1e15, 1e15)
      r.Envelope_SortPoints(env)
    end
  end
  r.SetActiveTake(rendered_take)
  return true, nil
end

local function replace_with_rendered_take_only(item)
  local n_before = r.GetMediaItemNumTakes(item)
  if n_before < 1 then
    return false, "item has no takes"
  end
  local original_active_take = r.GetActiveTake(item)
  if not original_active_take then
    return false, "item has no active take"
  end
  local original_active_guid = get_take_guid(original_active_take)
  if not original_active_guid then
    return false, "could not read original active take GUID"
  end
  local original_active_idx = find_active_take_index(item)
  local original_item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local source_backed_len = get_take_source_backed_item_length(original_active_take)
  local render_summary = build_render_adjustment_summary(original_active_take)
  save_item_snapshot(item, render_summary)

  local function restore_original_length()
    if original_item_len and original_item_len >= 0 then
      r.SetMediaItemInfo_Value(item, "D_LENGTH", original_item_len)
    end
  end

  if source_backed_len and original_item_len and source_backed_len > original_item_len then
    r.SetMediaItemInfo_Value(item, "D_LENGTH", source_backed_len)
  end

  local existing_guids = {}
  for idx = 0, n_before - 1 do
    local guid = get_take_guid(r.GetMediaItemTake(item, idx))
    if guid then
      existing_guids[guid] = true
    end
  end

  r.SelectAllMediaItems(0, false)
  r.SetMediaItemSelected(item, true)

  r.Main_OnCommand(CMD_RENDER_ITEMS_NEW_TAKE, 0)

  local n_after = r.GetMediaItemNumTakes(item)
  if n_after <= n_before then
    -- Some setups create a separate rendered item instead of a new take in-place.
    -- In that case, copy rendered item source to the original item's active take.
    local sel_count = r.CountSelectedMediaItems(0)
    local rendered_item = nil
    for i = 0, sel_count - 1 do
      local it = r.GetSelectedMediaItem(0, i)
      if it and it ~= item then
        rendered_item = it
        break
      end
    end
    if not rendered_item then
      restore_original_length()
      return false, "render did not produce a replaceable take/item"
    end

    local target_idx = find_take_index_by_guid(item, original_active_guid)
    if target_idx < 0 and original_active_idx >= 0 then
      local fallback_take = r.GetMediaItemTake(item, original_active_idx)
      if fallback_take and get_take_guid(fallback_take) ~= nil then
        target_idx = original_active_idx
      end
    end
    if target_idx < 0 then
      restore_original_length()
      return false, "original active take not found after copy path"
    end
    local target_take = r.GetMediaItemTake(item, target_idx)
    local rendered_take = r.GetActiveTake(rendered_item)
    if not rendered_take then
      restore_original_length()
      return false, "rendered item has no active take"
    end
    local ok_src, err_src = copy_take_source_to_take(rendered_take, target_take)
    if not ok_src then
      restore_original_length()
      return false, err_src or "could not apply rendered source to active take"
    end

    local rendered_track = r.GetMediaItem_Track(rendered_item)
    if rendered_track then
      r.DeleteTrackMediaItem(rendered_track, rendered_item)
    end

    restore_original_length()
    r.SetActiveTake(target_take)
    add_render_summary_marker(target_take, render_summary)
    return true, nil
  end

  -- Rendered take position can vary by REAPER settings. Find the newly-created take by GUID.
  local rendered_guid = nil
  for idx = 0, n_after - 1 do
    local guid = get_take_guid(r.GetMediaItemTake(item, idx))
    if guid and not existing_guids[guid] then
      rendered_guid = guid
      break
    end
  end

  if not rendered_guid then
    rendered_guid = get_take_guid(r.GetActiveTake(item))
  end
  if not rendered_guid then
    restore_original_length()
    return false, "could not identify rendered take"
  end

  local target_idx = find_take_index_by_guid(item, original_active_guid)
  if target_idx < 0 and original_active_idx >= 0 then
    local fallback_take = r.GetMediaItemTake(item, original_active_idx)
    local fallback_guid = get_take_guid(fallback_take)
    if fallback_take and fallback_guid and fallback_guid ~= rendered_guid then
      target_idx = original_active_idx
    end
  end
  if target_idx < 0 then
    restore_original_length()
    return false, "original active take not found after render"
  end
  local target_take = r.GetMediaItemTake(item, target_idx)

  local rendered_idx = find_take_index_by_guid(item, rendered_guid)
  if rendered_idx < 0 then
    restore_original_length()
    return false, "rendered take missing before replace"
  end
  local rendered_take = r.GetMediaItemTake(item, rendered_idx)
  local ok_src, err_src = copy_take_source_to_take(rendered_take, target_take)
  if not ok_src then
    -- Last-resort fallback: keep rendered take, remove original active take.
    local ok_swap, err_swap = replace_by_swapping_to_rendered_take(item, original_active_guid, rendered_guid)
    if ok_swap then
      restore_original_length()
      add_render_summary_marker(r.GetActiveTake(item), render_summary)
      return true, nil
    end
    restore_original_length()
    return false, err_src or err_swap or "could not apply rendered source to original active take"
  end

  local ok_del, err_del = delete_take_by_guid(item, rendered_guid)
  if not ok_del then
    restore_original_length()
    return false, err_del or "could not remove temporary rendered take"
  end

  restore_original_length()
  r.SetActiveTake(target_take)
  add_render_summary_marker(target_take, render_summary)
  return true, nil
end

local function main()
  local items = collect_selected_items()
  if #items == 0 then
    r.MB("Select one or more media items first.", "Render in place", 0)
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local failed = {}
  for _, item in ipairs(items) do
    if r.ValidatePtr2(0, item, "MediaItem*") then
      local ok, err = replace_with_rendered_take_only(item)
      if not ok then
        failed[#failed + 1] = err or "unknown error"
      end
    end
  end

  r.SelectAllMediaItems(0, false)
  for _, item in ipairs(items) do
    if r.ValidatePtr2(0, item, "MediaItem*") then
      r.SetMediaItemSelected(item, true)
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Render item in place (replace take, preserve source length)", -1)

  if #failed > 0 then
    r.MB(
      "Some items could not be replaced:\n" .. table.concat(failed, "\n"),
      "Render in place",
      0
    )
  end
end

main()
