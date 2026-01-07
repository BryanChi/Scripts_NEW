-- JRENG! (C) MMXV
desc = "Move all selected item(s) left edge to mouse cursor"
function print(str)
  reaper.ShowConsoleMsg(str .. "\n")
end

function minMax(t)
  local max = -math.huge
  local min = math.huge

  for k, v in pairs(t) do
    if type(v) == 'number' then
      max = math.max(max, v)
      min = math.min(min, v)
    end
  end
  return min, max
end

function move()
  tempo = reaper.Master_GetTempo()
  window, segment, details = reaper.BR_GetMouseCursorContext()
  isNew, filename, sec, cmd, mode, res, val = reaper.get_action_context()
  snap = reaper.GetToggleCommandStateEx(sec, 1157)

  if string.match(window, "arrange") then
    countSel = reaper.CountSelectedMediaItems(0)
    mousePos = reaper.BR_GetMouseCursorContext_Position()

    if snap == 1 then
      mousePos = reaper.SnapToGrid(0, mousePos)
    end

    pos = {}
    for i = 0, countSel - 1 do
      item = reaper.GetSelectedMediaItem(0, i)
      o = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
      p = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if o > 0 then
        pos[i] = o + p
      else
        pos[i] = p
      end
    end

    table.sort(pos)
    minPos, maxPos = minMax(pos)
    mouseAt = tempo * (mousePos * 2) / 120

    reaper.PreventUIRefresh(countSel + 1)
    reaper.ApplyNudge(0, 1, 0, 15, mouseAt, 0, 0)
  end
end

reaper.Undo_BeginBlock2()
move()
reaper.Undo_EndBlock(desc, -1)
