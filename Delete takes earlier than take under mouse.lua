-- @description Delete takes earlier than take under mouse
-- @version 1.02
-- @author Bryan
-- @about
--   Deletes every recording before the take/item under the mouse.
--   Classic take lanes: removes lower-index takes on the same item.
--   Fixed item lanes: removes overlapping items on lower lane numbers
--   on the same track, then any earlier takes on the item under the mouse.
--   Requires the SWS/S&M extension.

local r = reaper

local CMD_DELETE_CURRENT_TAKE = 40129 -- Take: Delete active take from items

local function require_sws()
  return r.BR_GetMouseCursorContext ~= nil or r.GetItemFromPoint ~= nil
end

local function get_take_guid(take)
  if not take then
    return nil
  end
  local ok, guid = r.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  if ok and guid and guid ~= "" then
    return guid
  end
  return nil
end

local function get_item_and_take_under_mouse()
  if r.BR_GetMouseCursorContext then
    r.BR_GetMouseCursorContext()
  end

  if r.GetItemFromPoint and r.GetMousePosition then
    local x, y = r.GetMousePosition()
    local item, take = r.GetItemFromPoint(x, y, true)
    if item and r.ValidatePtr(item, "MediaItem*") then
      if take and r.ValidatePtr(take, "MediaItem_Take*") then
        return item, take
      end
      take = r.GetActiveTake(item)
      if take then
        return item, take
      end
    end
  end

  if r.BR_TakeAtMouseCursor then
    local take = r.BR_TakeAtMouseCursor()
    if take and r.ValidatePtr(take, "MediaItem_Take*") then
      local item = r.GetMediaItemTake_Item(take)
      if item then
        return item, take
      end
    end
  end

  if not r.BR_GetMouseCursorContext then
    return nil, nil
  end

  local window, _segment, details = r.BR_GetMouseCursorContext()
  if window ~= "arrange" or details ~= "item" then
    return nil, nil
  end

  local item = r.BR_GetMouseCursorContext_Item()
  if not item or not r.ValidatePtr(item, "MediaItem*") then
    return nil, nil
  end

  local take = r.BR_GetMouseCursorContext_Take()
  if take and r.ValidatePtr(take, "MediaItem_Take*") then
    return item, take
  end

  take = r.GetActiveTake(item)
  if take then
    return item, take
  end

  return nil, nil
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

local function find_take_by_guid(item, guid)
  if not guid then
    return -1, nil
  end
  local n = r.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    local take = r.GetMediaItemTake(item, i)
    if take and get_take_guid(take) == guid then
      return i, take
    end
  end
  return -1, nil
end

local function delete_take_at_index(item, idx)
  if not item or idx < 0 then
    return false
  end

  local before = r.GetMediaItemNumTakes(item)
  if before <= 1 then
    return false
  end

  r.SetMediaItemSelected(item, true)

  if type(r.NF_DeleteTakeFromItem) == "function" then
    if r.NF_DeleteTakeFromItem(item, idx) and r.GetMediaItemNumTakes(item) == before - 1 then
      return true
    end
  end

  local take = r.GetMediaItemTake(item, idx)
  if not take then
    return false
  end

  if r.APIExists and r.APIExists("DeleteTake") then
    r.DeleteTake(take)
    if r.GetMediaItemNumTakes(item) == before - 1 then
      return true
    end
  end

  take = r.GetMediaItemTake(item, idx)
  if take then
    r.SetActiveTake(take)
    r.Main_OnCommand(CMD_DELETE_CURRENT_TAKE, 0)
    if r.GetMediaItemNumTakes(item) == before - 1 then
      return true
    end
  end

  return false
end

local function items_overlap(a, b)
  local a_pos = r.GetMediaItemInfo_Value(a, "D_POSITION")
  local a_end = a_pos + r.GetMediaItemInfo_Value(a, "D_LENGTH")
  local b_pos = r.GetMediaItemInfo_Value(b, "D_POSITION")
  local b_end = b_pos + r.GetMediaItemInfo_Value(b, "D_LENGTH")
  return a_pos < a_end and b_pos < b_end and a_pos < b_end - 1e-9 and b_pos < a_end - 1e-9
end

local function is_fixed_lane_item(item)
  local lane_plays = r.GetMediaItemInfo_Value(item, "C_LANEPLAYS")
  return lane_plays ~= nil and lane_plays >= 0
end

local function item_lane_index(item)
  local lane = r.GetMediaItemInfo_Value(item, "I_FIXEDLANE")
  if lane and lane >= 0 then
    return math.floor(lane + 0.5)
  end
  return nil
end

local function delete_earlier_lane_items(item)
  if not is_fixed_lane_item(item) then
    return 0
  end

  local mouse_lane = item_lane_index(item)
  if not mouse_lane or mouse_lane <= 0 then
    return 0
  end

  local track = r.GetMediaItemTrack(item)
  if not track then
    return 0
  end

  local to_delete = {}
  local n = r.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = r.GetTrackMediaItem(track, i)
    if it ~= item then
      local lane = item_lane_index(it)
      if lane and lane < mouse_lane and items_overlap(item, it) then
        to_delete[#to_delete + 1] = it
      end
    end
  end

  table.sort(to_delete, function(a, b)
    return item_lane_index(a) > item_lane_index(b)
  end)

  local deleted = 0
  for _, it in ipairs(to_delete) do
    if r.ValidatePtr(it, "MediaItem*") then
      r.DeleteTrackMediaItem(track, it)
      deleted = deleted + 1
    end
  end

  return deleted
end

local function delete_earlier_takes_in_item(item, keep_take)
  local keep_idx = find_take_index(item, keep_take)
  if keep_idx < 0 then
    local keep_guid = get_take_guid(keep_take)
    keep_idx, keep_take = find_take_by_guid(item, keep_guid)
  end
  if keep_idx <= 0 then
    return 0, true
  end

  local keep_guid = get_take_guid(keep_take)
  local deleted = 0

  for idx = keep_idx - 1, 0, -1 do
    if not delete_take_at_index(item, idx) then
      return deleted, false
    end
    deleted = deleted + 1
  end

  if keep_guid then
    local _, kept_take = find_take_by_guid(item, keep_guid)
    if kept_take then
      r.SetMediaItemSelected(item, true)
      r.SetActiveTake(kept_take)
    end
  end

  return deleted, true
end

local function main()
  if not require_sws() then
    return
  end

  local item, take = get_item_and_take_under_mouse()
  if not item or not take then
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local deleted_lanes = delete_earlier_lane_items(item)
  local deleted_takes, ok = delete_earlier_takes_in_item(item, take)
  local deleted = deleted_lanes + deleted_takes

  r.PreventUIRefresh(-1)

  if ok and deleted > 0 then
    r.UpdateArrange()
  end
  r.Undo_EndBlock("Delete takes earlier than take under mouse", -1)
end

main()
