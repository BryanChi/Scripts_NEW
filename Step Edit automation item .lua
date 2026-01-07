r = reaper
window, segment, detail = reaper.BR_GetMouseCursorContext()


if window == 'arrange' and segment == 'envelope' then
    --[[  local env = r.GetSelectedTrackEnvelope(0)

    r.GetSetAutomationItemInfo( env, integer autoitem_idx, string desc, number value, boolean is_set) ]]
    env, takeEnv = r.BR_GetMouseCursorContext_Envelope()
    MousePos = r.BR_GetMouseCursorContext_Position()
    Track = r.BR_GetMouseCursorContext_Track()


    if env and not takeEnv then
        Ct = r.CountAutomationItems(env)



        repeat
            Frame = (Frame or 0) + 1
            i = i or 0

            Pos = r.GetSetAutomationItemInfo(env, i, 'D_POSITION', 0, false)
            Len = r.GetSetAutomationItemInfo(env, i, 'D_LENGTH', 0, false)

            if MousePos > Pos and MousePos < Pos + Len then Itm = i end
            i = i + 1
        until (Itm or Frame > 100)

        if Itm then
            local i = Itm
            Len = r.GetSetAutomationItemInfo(env, i, 'D_BASELINE', 0, false)
            TrackPosY = r.GetMediaTrackInfo_Value(Track, 'I_TCPY')
            EnvHeight = r.GetEnvelopeInfo_Value(env, 'I_TCPH_USED')
        end
    end
end

function loop()
    MsX, MsY = r.GetMousePosition()
    Val = TrackPosY
    r.ShowConsoleMsg(Val .. '\n')
end

reaper.defer(loop)
