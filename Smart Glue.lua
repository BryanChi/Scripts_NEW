r = reaper
window, segment, detail = reaper.BR_GetMouseCursorContext()

window, segment, detail = reaper.BR_GetMouseCursorContext()

if window == 'arrange' and segment == 'envelope' then
    --[[  local env = r.GetSelectedTrackEnvelope(0)

    r.GetSetAutomationItemInfo( env, integer autoitem_idx, string desc, number value, boolean is_set) ]]

    r.Main_OnCommandEx(42089, 1, 0)
else
    r.Main_OnCommandEx(40362, 1, 0)
end
