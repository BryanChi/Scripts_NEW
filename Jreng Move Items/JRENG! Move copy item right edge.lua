-- JRENG! (C) MMXV
desc = "Duplicate & move right edge to mouse cursor"
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
  tempo = reaper.Master_GetTempo()
  window, segment, details = reaper.BR_GetMouseCursorContext()
  isNew, filename, sec, cmd, mode, res, val = reaper.get_action_context()
  snap = reaper.GetToggleCommandStateEx(sec, 1157)

  if string.match(window, "arrange") and segment ~= 'envelope' then
    countSel = reaper.CountSelectedMediaItems(0)

    mousePos = reaper.BR_GetMouseCursorContext_Position()

    if snap == 1 then
      mousePos = reaper.SnapToGrid(0, mousePos)
    end

    edge = {}
    for i = 0, countSel - 1 do
      item = reaper.GetSelectedMediaItem(0, i)
      pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      edge[i] = pos + len
    end

    table.sort(edge)
    minEdge, maxEdge = minMax(edge)
    dist = (tempo * (mousePos - maxEdge) * .5) / 120

    reaper.PreventUIRefresh(countSel + 1)
    reaper.ApplyNudge(0, 0, 5, 15, dist, 0, 1)
  else
    r.Main_OnCommandEx(42083, 1, 0) --  pool
    --env = r.BR_GetMouseCursorContext_Envelope()
    Trk = r.BR_GetMouseCursorContext_Track()
    AllEnv = r.CountTrackEnvelopes(Trk)

    for i = 0, AllEnv - 1, 1 do
      env = r.GetTrackEnvelope(Trk, i)

      EnvHeight = r.GetEnvelopeInfo_Value(env, 'I_TCPH_USED')

      if EnvHeight > 1 then  --- if Envelope is visible
        local count = r.CountAutomationItems(env)
        mousePos = r.BR_GetMouseCursorContext_Position()
        if snap == 1 then
          mousePos = r.SnapToGrid(0, mousePos)
        end

        pos = {}
        SelItmPos = {}
        SelItm = {}
        SelItmL = {}
        for i = 0, count - 1 do
          local sel = r.GetSetAutomationItemInfo(env, i, 'D_UISEL', 0, false)
          if sel then
            if sel ~= 0 then
              pos[i] = r.GetSetAutomationItemInfo(env, i, 'D_POSITION', 0, false)
              table.insert(SelItmL, r.GetSetAutomationItemInfo(env, i, 'D_LENGTH', 0, false))
              table.insert(SelItmPos, pos[i])
              table.insert(SelItm, i)
            end
          end
        end


        local dist

        table.sort(SelItmPos)
        for i, v in ipairs(SelItmPos) do
          if i == 1 then
            End = SelItmPos[#SelItmPos] + SelItmL[#SelItmL]

            dist = End - mousePos





            --dist = v - mousePos

            r.GetSetAutomationItemInfo(env, SelItm[i], 'D_POSITION', SelItmPos[i] - dist, true)
          elseif i > 1 then
            r.GetSetAutomationItemInfo(env, SelItm[i], 'D_POSITION', SelItmPos[i] - dist, true)
          end
        end
      end
    end


    --r.PreventUIRefresh(count + 1)
  end
end

reaper.Undo_BeginBlock2()
move()
reaper.Undo_EndBlock(desc, -1)
