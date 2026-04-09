-- @description Render item in place (replace active take with rendered audio)
-- @version 1.9
-- @author Bryan
-- @about
--   For each selected media item, runs REAPER's built-in "Item: render items to new take"
--   and replaces ONLY the original active take's source with the rendered result.
--   Other takes are preserved.

local r = reaper

local CMD_RENDER_ITEMS_NEW_TAKE = 40601 -- Item: render items to new take
local CMD_DELETE_CURRENT_TAKE = 40129 -- Take: Delete current take from items
local DEBUG = true
local debug_lines = {}

local function dbg(msg)
  if not DEBUG then return end
  debug_lines[#debug_lines + 1] = tostring(msg)
end

local function item_id(item)
  if not item then return "nil-item" end
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION") or -1
  return string.format("item@%.3f", pos)
end

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

local function copy_take_source_to_take(source_take, destination_take)
  if not source_take or not destination_take then
    return false, "missing source or destination take"
  end

  local source = r.GetMediaItemTake_Source(source_take)
  if not source then
    return false, "source take has no source"
  end

  local _, source_path = r.GetMediaSourceFileName(source, "")
  if not source_path or source_path == "" then
    return false, "could not read source file path"
  end

  local new_src = r.PCM_Source_CreateFromFile(source_path)
  if not new_src then
    return false, "could not create source from rendered file"
  end

  r.SetMediaItemTake_Source(destination_take, new_src)
  return true, nil
end

local function delete_take_by_guid(item, target_guid)
  local idx = find_take_index_by_guid(item, target_guid)
  if idx < 0 then
    dbg("delete_take_by_guid: guid not found " .. tostring(target_guid))
    return false, "take not found"
  end

  local take = r.GetMediaItemTake(item, idx)
  if not take then
    dbg("delete_take_by_guid: take pointer invalid at idx " .. tostring(idx))
    return false, "take pointer invalid"
  end

  local before = r.GetMediaItemNumTakes(item)
  dbg("delete_take_by_guid: before=" .. tostring(before) .. " idx=" .. tostring(idx))
  if r.APIExists and r.APIExists("DeleteTake") then
    r.DeleteTake(take)
    if r.GetMediaItemNumTakes(item) == before - 1 then
      dbg("delete_take_by_guid: success via DeleteTake")
      return true, nil
    end
  end

  if type(r.NF_DeleteTakeFromItem) == "function" then
    local idx_now = find_take_index_by_guid(item, target_guid)
    if idx_now >= 0 then
      r.NF_DeleteTakeFromItem(item, idx_now)
      if r.GetMediaItemNumTakes(item) == before - 1 then
        dbg("delete_take_by_guid: success via NF_DeleteTakeFromItem")
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
        dbg("delete_take_by_guid: success via action 40129")
        return true, nil
      end
    end
  end

  return false, "failed to delete rendered temp take"
end

local function replace_by_swapping_to_rendered_take(item, original_active_guid, rendered_guid)
  dbg("replace_by_swapping_to_rendered_take: fallback start")
  local rendered_idx = find_take_index_by_guid(item, rendered_guid)
  if rendered_idx < 0 then
    dbg("replace_by_swapping_to_rendered_take: rendered take not found")
    return false, "rendered take not found for swap fallback"
  end

  local rendered_take = r.GetMediaItemTake(item, rendered_idx)
  if not rendered_take then
    return false, "rendered take pointer invalid for swap fallback"
  end

  local ok_del_orig, err_del_orig = delete_take_by_guid(item, original_active_guid)
  if not ok_del_orig then
    dbg("replace_by_swapping_to_rendered_take: delete original failed: " .. tostring(err_del_orig))
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
  r.SetActiveTake(rendered_take)
  dbg("replace_by_swapping_to_rendered_take: success")
  return true, nil
end

local function replace_with_rendered_take_only(item)
  dbg("---- processing " .. item_id(item) .. " ----")
  local n_before = r.GetMediaItemNumTakes(item)
  dbg("takes before render: " .. tostring(n_before))
  if n_before < 1 then
    return false, "item has no takes"
  end
  local original_active_take = r.GetActiveTake(item)
  if not original_active_take then
    return false, "item has no active take"
  end
  local original_active_guid = get_take_guid(original_active_take)
  if not original_active_guid then
    dbg("failure: could not read original active take GUID")
    return false, "could not read original active take GUID"
  end
  local original_active_idx = find_active_take_index(item)
  dbg("original active idx: " .. tostring(original_active_idx))
  dbg("original active GUID: " .. original_active_guid)

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
  dbg("takes after render action: " .. tostring(n_after))
  if n_after <= n_before then
    dbg("render did not add take; trying separate rendered item path")
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
      dbg("no secondary selected item found for rendered-item path")
      return false, "render did not produce a replaceable take/item"
    end

    dbg("rendered-item path using " .. item_id(rendered_item))
    local target_idx = find_take_index_by_guid(item, original_active_guid)
    if target_idx < 0 and original_active_idx >= 0 then
      local fallback_take = r.GetMediaItemTake(item, original_active_idx)
      if fallback_take and get_take_guid(fallback_take) ~= nil then
        target_idx = original_active_idx
        dbg("copy-path: using fallback original active idx " .. tostring(target_idx))
      end
    end
    if target_idx < 0 then
      dbg("failure: original active take not found after copy path")
      return false, "original active take not found after copy path"
    end
    local target_take = r.GetMediaItemTake(item, target_idx)
    local rendered_take = r.GetActiveTake(rendered_item)
    if not rendered_take then
      dbg("failure: rendered item has no active take")
      return false, "rendered item has no active take"
    end
    local ok_src, err_src = copy_take_source_to_take(rendered_take, target_take)
    if not ok_src then
      dbg("failure copy-path source apply: " .. tostring(err_src))
      return false, err_src or "could not apply rendered source to active take"
    end

    local rendered_len = r.GetMediaItemInfo_Value(rendered_item, "D_LENGTH")
    if rendered_len and rendered_len > 0 then
      r.SetMediaItemInfo_Value(item, "D_LENGTH", rendered_len)
    end

    local rendered_track = r.GetMediaItem_Track(rendered_item)
    if rendered_track then
      r.DeleteTrackMediaItem(rendered_track, rendered_item)
      dbg("copy-path: deleted temporary rendered item")
    end

    r.SetActiveTake(target_take)
    dbg("copy-path: replaced source on original active take")
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
    dbg("could not identify rendered GUID")
    return false, "could not identify rendered take"
  end
  dbg("rendered GUID: " .. rendered_guid)

  local target_idx = find_take_index_by_guid(item, original_active_guid)
  if target_idx < 0 and original_active_idx >= 0 then
    local fallback_take = r.GetMediaItemTake(item, original_active_idx)
    local fallback_guid = get_take_guid(fallback_take)
    if fallback_take and fallback_guid and fallback_guid ~= rendered_guid then
      target_idx = original_active_idx
      dbg("new-take path: using fallback original active idx " .. tostring(target_idx))
    end
  end
  if target_idx < 0 then
    dbg("failure: original active take not found after render")
    return false, "original active take not found after render"
  end
  local target_take = r.GetMediaItemTake(item, target_idx)

  local rendered_idx = find_take_index_by_guid(item, rendered_guid)
  if rendered_idx < 0 then
    dbg("failure: rendered take missing before replace")
    return false, "rendered take missing before replace"
  end
  local rendered_take = r.GetMediaItemTake(item, rendered_idx)
  local ok_src, err_src = copy_take_source_to_take(rendered_take, target_take)
  if not ok_src then
    dbg("failure new-take source apply: " .. tostring(err_src))
    -- Some rendered take source types don't expose a file path.
    -- Fallback: keep rendered take, remove original active take.
    if tostring(err_src) == "could not read source file path" then
      local ok_swap, err_swap = replace_by_swapping_to_rendered_take(item, original_active_guid, rendered_guid)
      if ok_swap then
        dbg("new-take path: swap fallback succeeded")
        return true, nil
      end
      dbg("new-take path: swap fallback failed: " .. tostring(err_swap))
      return false, err_swap or "swap fallback failed"
    end
    return false, err_src or "could not apply rendered source to original active take"
  end

  local ok_del, err_del = delete_take_by_guid(item, rendered_guid)
  if not ok_del then
    dbg("failure deleting temp rendered take: " .. tostring(err_del))
    return false, err_del or "could not remove temporary rendered take"
  end
  r.SetActiveTake(target_take)
  dbg("new-take path: source replaced and temp rendered take removed")

  return true, nil
end

local function main()
  debug_lines = {}
  local items = collect_selected_items()
  dbg("selected items: " .. tostring(#items))
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
        dbg("item failed: " .. tostring(err))
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
  r.Undo_EndBlock("Render item in place (replace take)", -1)

  if #failed > 0 then
    dbg("run finished with failures: " .. tostring(#failed))
    r.MB(
      "Some items could not be replaced:\n" .. table.concat(failed, "\n"),
      "Render in place",
      0
    )
  else
    dbg("run finished successfully")
  end

  if DEBUG then
    r.ClearConsole()
    r.ShowConsoleMsg("[Render item in place replace take] Debug log\n")
    r.ShowConsoleMsg(table.concat(debug_lines, "\n") .. "\n")
  end
end

main()
