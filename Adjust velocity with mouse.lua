local r = reaper
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.9.3'
local im = ImGui
BarClr                       = 0x3c473d77
FocusedMidiEditor            = r.MIDIEditor_GetActive()
take                         = r.MIDIEditor_GetTake(FocusedMidiEditor)
ItemTakeGUID                 = r.BR_GetMediaItemTakeGUID(take)
MediaItemGUID                = r.BR_GetMediaItemGUID(item)
closestgrid_pos              = r.BR_GetClosestGridDivision(0.1)
MouseInitPosX, MouseInitPosY = r.GetMousePosition()
r                            = r
size_w                       = 20
size_h                       = 200
GUI_Win_Sz_W                 = 3840
GUI_Win_Sz_H                 = 2160
_, TakeGUID_Saved            = r.GetProjExtState(0, 'Quantize', 'Item Take GUID' .. ItemTakeGUID)
FrameCountLast               = 0
PreviouslyFocusedWindow      = r.JS_Window_GetFocus()
Take                         = {}
VelAdj                       = 0
AdjScale                     = 0.5
OrigVel                      = {}
Disp                         = {}
SelItm                       = {}
start_time                   = r.time_precise()
key_state, KEY               = r.JS_VKeys_GetState(start_time - 2), nil
INTERCEPTED_KEYS              = {}  -- Track all intercepted keys

-- Safety: Release any previously intercepted keys (in case script was interrupted)
-- Note: This is a best-effort cleanup - we can't know which keys were intercepted
-- but the Release() function will handle cleanup when script exits

for i = 1, 255 do
    if key_state:byte(i) ~= 0 then
        KEY = i
        -- Use pcall to handle any errors during interception
        local success = pcall(function() r.JS_VKeys_Intercept(KEY, 1) end)
        if success then
            INTERCEPTED_KEYS[KEY] = true  -- Track this key
        else
            KEY = nil  -- If interception failed, don't proceed
        end
        break  -- Only intercept the first pressed key
    end
end

if not KEY then return end

function Key_held()
    if not KEY then return false end
    key_state = r.JS_VKeys_GetState(start_time - 2)
    return key_state:byte(KEY) == 1
end

function Release()
    -- Release ALL intercepted keys, not just KEY
    -- Use multiple attempts to ensure release succeeds
    if INTERCEPTED_KEYS then
        for k, _ in pairs(INTERCEPTED_KEYS) do
            -- Try releasing multiple times to ensure it works
            for attempt = 1, 3 do
                pcall(function() r.JS_VKeys_Intercept(k, -1) end)
            end
        end
        INTERCEPTED_KEYS = {}
    end
    if KEY then
        -- Try releasing multiple times to ensure it works
        for attempt = 1, 3 do
            pcall(function() r.JS_VKeys_Intercept(KEY, -1) end)
        end
        KEY = nil  -- Prevent multiple releases
    end
    if PreviouslyFocusedWindow then
        pcall(function() r.JS_Window_SetFocus(PreviouslyFocusedWindow) end)
    end
end

function SetMinMax(Input, Min, Max)
    if Input >= Max then
        Input = Max
    elseif Input <= Min then
        Input = Min
    else
        Input = Input
    end
    return Input
end

function msg(value)
    r.ShowConsoleMsg(tostring(value))
end

first_Sel_Note                                   = r.MIDI_EnumSelNotes(take, 0)
retval, NoteCount, CC_EventCount, TextEventCount = r.MIDI_CountEvts(take)

First_Sel_CC = r.MIDI_EnumSelEvts(take, 0)


HowManySelItm = r.CountSelectedMediaItems(0)

for i = 0, HowManySelItm, 1 do
    local itm = r.GetSelectedMediaItem(0, i)
    if itm then SelItm[i + 1] = r.GetActiveTake(itm) end
end

if HowManySelItm == 0 then
    SelItm[1] = r.MIDIEditor_GetTake(FocusedMidiEditor)
end






r.MIDI_GetNote(take, 0)

local VKLow, VKHi = 8, 0xFE

ctx = im.CreateContext('My script')

-- Create Impact font at size 24
Font_Impact_24 = im.CreateFont('impact', 24)
im.Attach(ctx, Font_Impact_24)
Font_Note_Vel = im.CreateFont('sans-serif', 13)
im.Attach(ctx, Font_Note_Vel)

init_X = 200
init_Y = 200


_, MouseInitPosY = im.PointConvertNative(ctx, nil, MouseInitPosY, true)



--[[ for TrackRpts = 0, 50, 1 do
    Take[TrackRpts] = r.MIDIEditor_EnumTakes(FocusedMidiEditor, TrackRpts, true)
    if Take[TrackRpts] ~= nil then
        for RptTimes = first_Sel_Note - 1, NoteCount - 1, 1 do
            retval, selected, muted, _, endppqpos, chan, pitch, vel = r.MIDI_GetNote(
                Take[TrackRpts], RptTimes)
            OrigVel[RptTimes] = vel
        end
    end
end ]]

Disp.InitMsX, Disp.InitMsY = r.GetMousePosition()


-- Velocity of every note visible in the MIDI editor, drawn over the notes
local MidiView      = r.JS_Window_FindChildByID(FocusedMidiEditor, 1001)
local View          = { NextRead = 0 }
local NoteCache     = {}
local RULER_H       = 64
local VEL_BAR_W     = 5
local VEL_BAR_H     = 40
local CLR_BAR_BG    = 0x00000066
local CLR_BAR_SEL   = 0x58d68dee
local CLR_BAR       = 0xc8c8c8aa
local CLR_TEXT      = 0xffffffff
local CLR_TEXT_BACK = 0x000000cc

-- Zoom and scroll live in the take's chunk, which is slow to fetch, so it's only read a few times per second
local function Read_View()
    local now = r.time_precise()
    if now < View.NextRead then return end
    View.NextRead = now + 0.2

    local ok, L, T, R, B = r.JS_Window_GetClientRect(MidiView)
    View.X, View.Y = im.PointConvertNative(ctx, L, T, true)
    View.W, View.H = R - L, math.abs(B - T)

    local item = r.GetMediaItemTake_Item(take)
    local _, chunk = r.GetItemStateChunk(item, '', false)
    local start = 1
    for i = 1, r.GetMediaItemTakeInfo_Value(take, 'IP_TAKENUMBER') do
        start = chunk:find('\nTAKE[ \r\n]', start + 1) or start
    end
    local stop = chunk:find('\nTAKE[ \r\n]', start + 1) or #chunk
    chunk = chunk:sub(start, stop)

    local left, zoom, top, px_per_pitch = chunk:match('\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)')
    local timebase = 0
    local field = 0
    for word in (chunk:match('\nCFGEDIT ([^\n]+)') or ''):gmatch('%S+') do
        field = field + 1
        if field == 19 then timebase = tonumber(word) end
    end
    View.OK = left ~= nil and r.MIDIEditor_GetMode(FocusedMidiEditor) == 0
    if not View.OK then return end

    -- Timebases 0 and 4 are beats (zoom = pixels per tick), the others are time (zoom = pixels per second)
    View.IsBeats    = timebase == 0 or timebase == 4
    View.Left       = tonumber(left)
    if not View.IsBeats then View.Left = r.MIDI_GetProjTimeFromPPQPos(take, View.Left) end
    View.Zoom       = tonumber(zoom)
    View.TopPitch   = 127 - tonumber(top)
    View.PxPerPitch = tonumber(px_per_pitch)
    View.NotesH     = View.H
    for height in chunk:gmatch('\nVELLANE %S+ (%S+)') do
        View.NotesH = View.NotesH - tonumber(height)
    end
end

local function Get_Notes(Tk)
    local _, hash = r.MIDI_GetHash(Tk, true, '')
    local Cache = NoteCache[Tk]
    if Cache and Cache.Hash == hash and Cache.IsBeats == View.IsBeats then return Cache end

    Cache = { Hash = hash, IsBeats = View.IsBeats }
    local _, Count = r.MIDI_CountEvts(Tk)
    -- Everything goes through project time so that notes of other takes in the editor line up with the active take
    local function Pos(ppq)
        local time = r.MIDI_GetProjTimeFromPPQPos(Tk, ppq)
        return View.IsBeats and r.MIDI_GetPPQPosFromProjTime(take, time) or time
    end
    for i = 0, Count - 1 do
        local _, sel, _, start, stop, _, pitch, vel = r.MIDI_GetNote(Tk, i)
        Cache[i + 1] = { Sel = sel, Start = Pos(start), Stop = Pos(stop), Pitch = pitch, Vel = vel }
    end
    NoteCache[Tk] = Cache
    return Cache
end

local function Draw_Note_Vels(DL)
    if not View.OK then return end
    local TopY, BotY = View.Y + RULER_H, View.Y + View.NotesH
    local PxPerPitch = View.PxPerPitch
    im.DrawList_PushClipRect(DL, View.X, TopY, View.X + View.W, BotY)
    im.PushFont(ctx, Font_Note_Vel)

    local TextH = im.GetTextLineHeight(ctx)
    local i = 0
    local Tk = r.MIDIEditor_EnumTakes(FocusedMidiEditor, i, false)
    while Tk do
        for _, N in ipairs(Get_Notes(Tk)) do
            local NoteL = (N.Start - View.Left) * View.Zoom
            local NoteR = (N.Stop - View.Left) * View.Zoom
            local RowT  = TopY + (View.TopPitch - N.Pitch) * PxPerPitch
            local RowB  = RowT + PxPerPitch

            if NoteR >= 0 and NoteL <= View.W and RowB >= TopY and RowT <= BotY then
                local X  = View.X + math.max(NoteL, 0)
                local X2 = X + VEL_BAR_W
                im.DrawList_AddRectFilled(DL, X, RowB - VEL_BAR_H, X2, RowB, CLR_BAR_BG)
                im.DrawList_AddRectFilled(DL, X, RowB - N.Vel / 127 * VEL_BAR_H, X2, RowB, N.Sel and CLR_BAR_SEL or CLR_BAR)

                local TextY = RowT + (PxPerPitch - TextH) / 2
                im.DrawList_AddText(DL, X2 + 4, TextY + 1, CLR_TEXT_BACK, N.Vel)
                im.DrawList_AddText(DL, X2 + 3, TextY, CLR_TEXT, N.Vel)
            end
        end
        i = i + 1
        Tk = r.MIDIEditor_EnumTakes(FocusedMidiEditor, i, false)
    end

    im.PopFont(ctx)
    im.DrawList_PopClipRect(DL)
end


function loop()
    -- Wrap entire loop in error handling to ensure Release() is always called
    local success, err = pcall(function()
        --[[     state = r.JS_VKeys_GetDown( 0.1 )

        keyState = r.JS_VKeys_GetState(0.5):sub(VKLow, VKHi)
        ]]
        -- Safety check: if KEY is nil, release and exit
        if not KEY then 
            Release()
            return
        end
        
        if not Key_held() then 
            Release()
            return  -- Stop the loop when key is released
        end

        if not InitMsY then InitMsX, InitMsY = r.GetMousePosition() end

        isVKeyDown = im.IsKeyDown(ctx, im.Key_V)
        isVKeyREL = im.IsKeyReleased(ctx, im.Key_V)


        MouseX, MouseY = r.GetMousePosition()

        Display_Adjusted_Vel =  Display_Adjusted_Vel or 0 

        MouseDeltaY = InitMsY - MouseY
        VelAdj = MouseDeltaY
        Disp.VelAdj = Disp.InitMsY - MouseY


        local window_flags = im.WindowFlags_NoDecoration + im.WindowFlags_AlwaysAutoResize +
            im.WindowFlags_NoBackground

        im.SetNextWindowBgAlpha(ctx, 0.01)
        Read_View()
        -- The window has to reach every visible note, not only the area around the mouse
        local WinL = math.min(Disp.InitMsX - GUI_Win_Sz_W / 2, View.X)
        local WinT = math.min(MouseInitPosY - GUI_Win_Sz_H / 2, View.Y)
        local WinR = math.max(Disp.InitMsX + GUI_Win_Sz_W / 2, View.X + View.W)
        local WinB = math.max(MouseInitPosY + GUI_Win_Sz_H / 2, View.Y + View.H)
        im.SetNextWindowPos(ctx, WinL, WinT, nil)
        im.SetNextWindowSize(ctx, WinR - WinL, WinB - WinT)
        function SetMinMax(value, min, max)
            if value < min then
                return min
            elseif value > max then
                return max
            else
                return value
            end
        end

        visible, open = im.Begin(ctx, 'My Win', true, window_flags)
        if visible then
            im.PushFont(ctx, Font_Impact_24)

            drawlist     = im.GetForegroundDrawList(ctx)
            PosX, PosY   = im.GetItemRectMin(ctx)

            SelNoteCount = 0
            local function SetVel ()

                
                for i, v in ipairs(SelItm) do
                    for RptTimes = first_Sel_Note - 1, NoteCount - 1, 1 do
                        retval, selected, muted, _, endppqpos, chan, pitch, vel = r.MIDI_GetNote( SelItm[i], RptTimes)



                        if selected and (VelAdj >= 1 or VelAdj <= 1) then
                            SelNoteCount = SelNoteCount + 1
                            local Out_vel = vel - math.floor(VelAdj * AdjScale + 0.5)
                            local Out_vel = SetMinMax(Out_vel, 1, 127)
                            r.MIDI_SetNote(SelItm[i], RptTimes, nil, nil, nil, nil, nil, nil, Out_vel or vel, true)
                            ResetInitMs = true
                        end
                    end
                end

            end

            --[[ local function Draw_Slider_GUI()
                -- Fixed slider size (no dynamic resizing)
                local sliderLength = 300
                local sliderWidth = 30
                local rulerWidth = 20
                
                -- Calculate slider position (centered on initial mouse position)
                local sliderStartX = MouseInitPosX - sliderWidth / 2
                local sliderStartY = MouseInitPosY - sliderLength / 2
                
                -- Draw slider background (more transparent)
                im.DrawList_AddRectFilled(drawlist, sliderStartX, sliderStartY, 
                    sliderStartX + sliderWidth, sliderStartY + sliderLength, 0x33333310)
                
                -- Draw slider border
                im.DrawList_AddRect(drawlist, sliderStartX, sliderStartY, 
                    sliderStartX + sliderWidth, sliderStartY + sliderLength, 0xffffff66, 0, 0, 2)
                
                -- Draw center line (0 position)
                local centerY = sliderStartY + sliderLength / 2
                im.DrawList_AddLine(drawlist, sliderStartX - 5, centerY, sliderStartX + sliderWidth + 5, centerY, 0xff000066, 3)
                
                -- Draw ruler increments (tick marks only, no numbers)
                for i = 0, 127, 16 do
                    local posY = sliderStartY + sliderLength - (i / 127) * sliderLength
                    local tickWidth = (i % 32 == 0) and 8 or 4
                    
                    -- Draw tick marks
                    im.DrawList_AddLine(drawlist, sliderStartX - rulerWidth, posY, sliderStartX - rulerWidth + tickWidth, posY, 0xffffff66, 1)
                end
                
                -- Draw current velocity indicator
                local currentVel = Display_Adjusted_Vel or 0
                local velPosY = sliderStartY + sliderLength - ((currentVel + 127) / 254) * sliderLength
                velPosY = math.max(sliderStartY, math.min(sliderStartY + sliderLength, velPosY))
                
                -- Draw velocity indicator line
                im.DrawList_AddLine(drawlist, sliderStartX - 5, velPosY, sliderStartX + sliderWidth + 5, velPosY, 0x00ff0066, 2)
            end ]]

            local function Display_Vel ()
                
                if (VelAdj >= 1 or VelAdj <= 1) then 
                    Display_Adjusted_Vel = SetMinMax(Display_Adjusted_Vel -   math.floor(VelAdj * AdjScale + 0.5), -127, 127)
                end
                local PosX, PosY = im.GetMousePos(ctx)
                im.SetCursorScreenPos(ctx, PosX + 10, PosY- 20)
                local plus  = Display_Adjusted_Vel > 0 and '+' or ''
                im.Text(ctx , plus .. Display_Adjusted_Vel)
            end

            local function Change_CC()
                for i, v in ipairs(SelItm) do
                    for I = 0, CC_EventCount , 1 do

                        local retval, selected,  muted,  ppqpos,  chanmsg,  chan,  msg2,  msg3 = r.MIDI_GetCC(SelItm[i], I)

                        if selected and (VelAdj >= 1 or VelAdj <= 1) then

                            Sel_CC_Count = (Sel_CC_Count or 0) + 1
                            local Out_vel = msg3 - math.floor(VelAdj * AdjScale + 0.5)
                            local Out_vel = SetMinMax(Out_vel, 1, 127)
                            r.MIDI_SetCC( take, I, nil, nil, nil, nil, nil, msg2, Out_vel, true )

                            ResetInitMs = true
                        end
                    end
                end
            end

            SetVel ()
            Display_Vel ()
            Change_CC()
            --Draw_Slider_GUI()
            --[[ for RptTimes = first_Sel_Note - 1, NoteCount - 1, 1 do
                        retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = r.MIDI_GetNote(
                            Take[TrackRpts], RptTimes)
                        if selected and (VelAdj >= 1 or VelAdj <= 1) then
                            if SelNoteCount == 1 then -- if there's only one selected note
                                local X, Y = r.ImGui_GetCursorScreenPos(ctx)
                                local Y = Y + size_h - 7
                                r.ImGui_DrawList_AddLine(drawlist, MouseInitPosX_No_Move, Y, MouseInitPosX_No_Move,
                                    Y - (vel / 127 * size_h), 0x3c473dff, 40)
                                r.ImGui_DrawList_AddText(drawlist, MouseInitPosX_No_Move - 4, MouseInitPosY + 5, 0xffffffff,
                                    Out_vel or vel)
                            else
                            end
                        end
                    end ]]



            if ResetInitMs then
                InitMsX, InitMsY = r.GetMousePosition()
                ResetInitMs = false
            end



            r.MIDI_Sort(take)

            Draw_Note_Vels(drawlist)

            im.PopFont(ctx)
            im.End(ctx)
        end


        --[[ if open and isVKeyREL ~= true then
            r.defer(loop)
        else --on script close
            FrameCount = im.GetFrameCount(ctx)

            if FrameCount > FrameCountLast then
                im.SetNextWindowSize(ctx, 10, 100)

                visible, open = im.Begin(ctx, 'My Win', true, window_flags)


                im.End(ctx)

                r.JS_Window_SetFocus(PreviouslyFocusedWindow)
                size_w = size_w - 1

                FrameCountLast = FrameCount
            end


            --im.DestroyContext(ctx)
        end ]]
        -- Only continue loop if key is still held
        if KEY and Key_held() then
            r.defer(loop)
        else
            Release()  -- Ensure cleanup if loop stops
        end
    end)  -- End of pcall
    
    -- If error occurred, release keys and stop
    if not success then
        Release()
        if err then
            r.ShowConsoleMsg("Error in loop: " .. tostring(err) .. "\n")
        end
        return
    end
end

-- Wrap initial defer in error handling too
local function safe_loop()
    local success, err = pcall(loop)
    if not success then
        Release()
        if err then
            r.ShowConsoleMsg("Error in safe_loop: " .. tostring(err) .. "\n")
        end
    end
end

r.defer(safe_loop)
r.atexit(Release)
