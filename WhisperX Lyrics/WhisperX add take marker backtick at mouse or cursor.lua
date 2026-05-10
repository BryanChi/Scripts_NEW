-- @description WhisperX: add take marker "`" at mouse or edit cursor
-- @version 1.00
-- @author Bryan
-- @about
--   Inserts a new take marker on the active take of the selected item. Marker name is a single grave accent (`).
--   Source time is taken from the mouse position on the arrange view when SWS extension is available
--   (BR_GetMouseCursorContext + BR_GetMouseCursorContext_Position); otherwise from the project edit cursor.
--   The target time must fall inside the selected item’s timeline span. Undo-friendly.

local r = reaper

local MARKER_NAME = "`"

local function mb(msg)
  r.MB(msg, "WhisperX — marker at mouse/cursor", 0)
end

local function project_time_from_mouse_or_cursor()
  if r.BR_GetMouseCursorContext and r.BR_GetMouseCursorContext_Position then
    local win = ({ r.BR_GetMouseCursorContext() })[1]
    if type(win) == "string" and win:lower() == "arrange" then
      local t = r.BR_GetMouseCursorContext_Position()
      if type(t) == "number" and t == t then
        return t, "mouse"
      end
    end
  end
  return r.GetCursorPosition(), "cursor"
end

--- Map project timeline time (seconds) to take source time for linear playrate (WhisperX markers use src time).
local function project_time_to_take_source_time(take, proj_t)
  local item = r.GetMediaItemTake_Item(take)
  if not item then
    return nil
  end
  local ipos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local ilen = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  if proj_t < ipos - 1e-9 or proj_t > ipos + ilen + 1e-9 then
    return nil
  end
  local rel = proj_t - ipos
  local startoffs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not playrate or playrate == 0 then
    playrate = 1
  end
  return startoffs + rel * playrate
end

local function main()
  if not r.SetTakeMarker then
    mb("This REAPER build does not expose SetTakeMarker.")
    return
  end

  local nsel = r.CountSelectedMediaItems(0)
  if nsel ~= 1 then
    mb("Select exactly one media item.")
    return
  end

  local item = r.GetSelectedMediaItem(0, 0)
  local take = r.GetActiveTake(item)
  if not take then
    mb("No active take on the selected item.")
    return
  end

  local proj_t, src = project_time_from_mouse_or_cursor()
  local src_t = project_time_to_take_source_time(take, proj_t)
  if not src_t then
    mb(
      "Could not map that time to this take’s source.\n\n"
        .. "Move the "
        .. (src == "mouse" and "mouse over the body of the selected item" or "edit cursor inside the selected item")
        .. " on the timeline, then run again."
    )
    return
  end

  r.Undo_BeginBlock()
  r.SetTakeMarker(take, -1, MARKER_NAME, src_t)
  r.UpdateArrange()
  r.Undo_EndBlock("Add take marker `", -1)
end

main()

