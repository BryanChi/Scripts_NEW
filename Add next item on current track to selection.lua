-- @description Add next item on current track to selection
-- @version 1.0
-- @author AI Assistant
-- @about
--   Adds the next item on the current track to the selection.
--   If an item is already selected on that track, the script adds the next
--   item to the right. If no item is selected on that track, it selects the
--   closest item to the play cursor without choosing an item under the cursor.
--   When transport is stopped, the edit cursor is used as the reference.

local r = reaper

local function get_current_track()
  local selected_track_count = r.CountSelectedTracks(0)
  if selected_track_count > 0 then
    return r.GetSelectedTrack(0, 0)
  end

  local selected_item_count = r.CountSelectedMediaItems(0)
  if selected_item_count > 0 then
    local item = r.GetSelectedMediaItem(0, 0)
    if item then
      return r.GetMediaItemTrack(item)
    end
  end

  return r.GetLastTouchedTrack()
end

local function get_reference_position()
  if r.GetPlayState() ~= 0 then
    return r.GetPlayPosition2Ex(0)
  end
  return r.GetCursorPosition()
end

local function get_item_bounds(item)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

local function get_sorted_track_items(track)
  local items = {}
  local item_count = r.CountTrackMediaItems(track)

  for i = 0, item_count - 1 do
    items[#items + 1] = r.GetTrackMediaItem(track, i)
  end

  table.sort(items, function(a, b)
    local a_pos, a_end = get_item_bounds(a)
    local b_pos, b_end = get_item_bounds(b)

    if a_pos == b_pos then
      return a_end < b_end
    end

    return a_pos < b_pos
  end)

  return items
end

local function get_selected_items_on_track(track)
  local selected = {}
  local selected_item_count = r.CountSelectedMediaItems(0)

  for i = 0, selected_item_count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    if item and r.GetMediaItemTrack(item) == track then
      selected[item] = true
    end
  end

  return selected
end

local function find_next_unselected_item(items, selected_lookup)
  local rightmost_selected_index = nil

  for i = 1, #items do
    if selected_lookup[items[i]] then
      rightmost_selected_index = i
    end
  end

  if not rightmost_selected_index then
    return nil
  end

  for i = rightmost_selected_index + 1, #items do
    if not selected_lookup[items[i]] then
      return items[i]
    end
  end

  return nil
end

local function find_closest_item_not_under_position(items, position)
  local best_item = nil
  local best_distance = math.huge
  local best_is_after = false

  for i = 1, #items do
    local item = items[i]
    local item_start, item_end = get_item_bounds(item)

    if position < item_start or position >= item_end then
      local distance
      local is_after

      if position < item_start then
        distance = item_start - position
        is_after = true
      else
        distance = position - item_end
        is_after = false
      end

      if distance < best_distance
        or (distance == best_distance and is_after and not best_is_after) then
        best_item = item
        best_distance = distance
        best_is_after = is_after
      end
    end
  end

  return best_item
end

local function main()
  local track = get_current_track()
  if not track then return end

  local items = get_sorted_track_items(track)
  if #items == 0 then return end

  local selected_lookup = get_selected_items_on_track(track)
  local target_item = find_next_unselected_item(items, selected_lookup)

  if not target_item then
    local reference_position = get_reference_position()
    target_item = find_closest_item_not_under_position(items, reference_position)
  end

  if not target_item then return end

  r.Undo_BeginBlock()
  r.SetMediaItemSelected(target_item, true)
  r.UpdateArrange()
  r.Undo_EndBlock("Add next item on current track to selection", -1)
end

main()
