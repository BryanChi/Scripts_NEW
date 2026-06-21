-- @description Delete take under mouse
-- @version 1.02
-- @author Bryan
-- @about
--   Deletes the media-item take under the mouse cursor in the arrange view.
--   Requires the SWS/S&M extension (BR_GetMouseCursorContext / BR_TakeAtMouseCursor).
--   If the item has only one take, the whole item is removed.

local r = reaper

local CMD_DELETE_CURRENT_TAKE = 40129 -- Take: Delete active take from items

local function require_sws()
  return r.BR_GetMouseCursorContext ~= nil or r.GetItemFromPoint ~= nil
end

local function get_take_under_mouse()
  if r.BR_GetMouseCursorContext then
    r.BR_GetMouseCursorContext()
  end

  if r.GetItemFromPoint and r.GetMousePosition then
    local x, y = r.GetMousePosition()
    local item, take = r.GetItemFromPoint(x, y, true)
    if take and r.ValidatePtr(take, "MediaItem_Take*") then
      return take
    end
    if item and r.ValidatePtr(item, "MediaItem*") then
      take = r.GetActiveTake(item)
      if take then
        return take
      end
    end
  end

  if r.BR_TakeAtMouseCursor then
    local take = r.BR_TakeAtMouseCursor()
    if take and r.ValidatePtr(take, "MediaItem_Take*") then
      return take
    end
  end

  if not r.BR_GetMouseCursorContext then
    return nil
  end

  local window, _segment, details = r.BR_GetMouseCursorContext()
  if window ~= "arrange" or details ~= "item" then
    return nil
  end

  local item = r.BR_GetMouseCursorContext_Item()
  if not item or not r.ValidatePtr(item, "MediaItem*") then
    return nil
  end

  local take = r.BR_GetMouseCursorContext_Take()
  if take and r.ValidatePtr(take, "MediaItem_Take*") then
    return take
  end

  return r.GetActiveTake(item)
end

local function find_take_index(item, take)
  local n = r.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    if r.GetMediaItemTake(item, i) == take then
      return i
    end
  end
  return -1
end

local function take_deletion_succeeded(item, take, before_count)
  if not item or not r.ValidatePtr(item, "MediaItem*") then
    return true
  end
  if r.GetMediaItemNumTakes(item) < before_count then
    return true
  end
  if take and not r.ValidatePtr(take, "MediaItem_Take*") then
    return true
  end
  if take and find_take_index(item, take) < 0 then
    return true
  end
  return false
end

local function delete_take(item, take)
  if not item or not take then
    return false
  end

  local track = r.GetMediaItemTake_Track(take) or r.GetMediaItemTrack(item)
  local num_takes = r.GetMediaItemNumTakes(item)

  if num_takes <= 1 then
    if track then
      r.DeleteTrackMediaItem(track, item)
      return not r.ValidatePtr(item, "MediaItem*")
    end
    return false
  end

  local before = num_takes
  local idx = find_take_index(item, take)
  r.SetMediaItemSelected(item, true)

  if type(r.NF_DeleteTakeFromItem) == "function" and idx >= 0 then
    r.NF_DeleteTakeFromItem(item, idx)
    if take_deletion_succeeded(item, take, before) then
      return true
    end
  end

  if r.APIExists and r.APIExists("DeleteTake") then
    r.DeleteTake(take)
    if take_deletion_succeeded(item, take, before) then
      return true
    end
  end

  if idx >= 0 then
    local take_now = r.GetMediaItemTake(item, idx)
    if take_now then
      r.SetActiveTake(take_now)
      r.Main_OnCommand(CMD_DELETE_CURRENT_TAKE, 0)
      if take_deletion_succeeded(item, take, before) then
        return true
      end
    end
  end

  return take_deletion_succeeded(item, take, before)
end

local function main()
  if not require_sws() then
    return
  end

  local take = get_take_under_mouse()
  if not take then
    return
  end

  local item = r.GetMediaItemTake_Item(take)
  if not item then
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local ok = delete_take(item, take)
  r.PreventUIRefresh(-1)
  if ok then
    r.UpdateArrange()
  end
  r.Undo_EndBlock("Delete take under mouse", -1)
end

main()
