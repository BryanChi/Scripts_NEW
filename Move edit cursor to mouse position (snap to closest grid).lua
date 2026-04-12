-- @description Move edit cursor to mouse position (snap to closest grid)
-- @version 1.0
-- @author AI Assistant
-- @about
--   Moves the edit cursor to the mouse position and snaps to
--   the nearest project grid line.

local function require_sws()
  if reaper.BR_PositionAtMouseCursor then
    return true
  end
  reaper.MB("This script requires the SWS/S&M extension.", "Missing dependency", 0)
  return false
end

local function main()
  if not require_sws() then return end

  local mouse_time = reaper.BR_PositionAtMouseCursor(false)
  if not mouse_time or mouse_time < 0 then return end

  local snapped_time = reaper.SnapToGrid(0, mouse_time)
  reaper.SetEditCurPos(snapped_time, true, false)
end

main()
