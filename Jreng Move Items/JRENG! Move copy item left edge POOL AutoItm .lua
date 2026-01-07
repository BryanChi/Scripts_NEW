-- JRENG! (C) MMXV
desc = "Duplicate & move left edge to mouse cursor"

r = reaper
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
  tempo = r.Master_GetTempo()
  window, segment, details = r.BR_GetMouseCursorContext()
  isNew, filename, sec, cmd, mode, res, val = r.get_action_context()
  snap = r.GetToggleCommandStateEx(sec, 1157)

  if string.match(window, "arrange") and segment ~= 'envelope' then
    countSel = r.CountSelectedMediaItems(0)
    mousePos = r.BR_GetMouseCursorContext_Position()

    if snap == 1 then
      mousePos = r.SnapToGrid(0, mousePos)
    end

    pos = {}
    for i = 0, countSel - 1 do
      item = r.GetSelectedMediaItem(0, i)
      o = r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
      p = r.GetMediaItemInfo_Value(item, "D_POSITION")
      if o > 0 then
        pos[i] = o + p
      else
        pos[i] = p
      end
    end

    table.sort(pos)
    minPos, maxPos = minMax(pos)
    dist = (tempo * (mousePos - minPos) * .5) / 120

    r.PreventUIRefresh(countSel + 1)
    r.ApplyNudge(0, 0, 5, 15, dist, 0, 1)
  else
    r.Main_OnCommandEx(42085, 1, 0) -- no pool
    Trk = r.BR_GetMouseCursorContext_Track()
    AllEnv = r.CountTrackEnvelopes(Trk)

    for i = 0, AllEnv - 1, 1 do
      env = r.GetTrackEnvelope(Trk, i)

      EnvHeight = r.GetEnvelopeInfo_Value(env, 'I_TCPH_USED')

      if EnvHeight > 1 then --- if Envelope is visible
        local count = r.CountAutomationItems(env)
        mousePos = r.BR_GetMouseCursorContext_Position()
        if snap == 1 then
          mousePos = r.SnapToGrid(0, mousePos)
        end

        pos = {}
        SelItmPos = {}
        SelItm = {}
        for i = 0, count - 1 do
          local sel = r.GetSetAutomationItemInfo(env, i, 'D_UISEL', 0, false)
          if sel then
            if sel ~= 0 then
              pos[i] = r.GetSetAutomationItemInfo(env, i, 'D_POSITION', 0, false)
              table.insert(SelItmPos, pos[i])
              table.insert(SelItm, i)
            end
          end
        end
        local dist

        table.sort(SelItmPos)
        for i, v in ipairs(SelItmPos) do
          if i == 1 then
            dist = v - mousePos

            r.GetSetAutomationItemInfo(env, SelItm[i], 'D_POSITION', mousePos, true)
          elseif i > 1 then
            r.GetSetAutomationItemInfo(env, SelItm[i], 'D_POSITION', SelItmPos[i] - dist, true)
          end
        end
      end
    end
  end
end

r.Undo_BeginBlock2()
move()
r.Undo_EndBlock(desc, -1)
