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
    if Overlay_Bitmap then
        pcall(function()
            r.JS_LICE_DestroyBitmap(Overlay_Bitmap) -- The extension will automatically un-composite the bitmap
            r.JS_Window_InvalidateRect(MidiView, 0, 0, Overlay_W, Overlay_H, false)
        end)
        Overlay_Bitmap = nil
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

first_Sel_Note                                   = math.max(r.MIDI_EnumSelNotes(take, -1), 0)
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


-- Velocity of the selected notes, drawn as a lane on top of the notes area
-- (same look as the piano roll overlay in js_Mouse editing - Arch and Tilt.lua)
MidiView                 = r.JS_Window_FindChildByID(FocusedMidiEditor, 1001)
local View               = { NextRead = 0 }
local NoteCache          = {}
local OrigVels           = {}
local LastDrawn
local RULER_H            = 64
local Overlay_Color_Grid       = 0xFF505050
local Overlay_Color_Bar        = 0xFFB4B4B4 -- Unchanged velocity
local Overlay_Color_BarUp      = 0xFF3CDC64 -- Raised velocity
local Overlay_Color_BarDown    = 0xFFFF6A4D -- Lowered velocity
local Overlay_Color_Original   = 0xFFFFFFFF -- Marker at original velocity

-- Zoom and scroll live in the take's chunk, which is slow to fetch, so it's only read a few times per second
local function Read_View()
    local now = r.time_precise()
    if now < View.NextRead then return end
    View.NextRead = now + 0.2

    local ok, L, T, R, B = r.JS_Window_GetClientRect(MidiView)
    View.W, View.H = R - L, math.abs(B - T)

    local item = r.GetMediaItemTake_Item(take)
    local _, chunk = r.GetItemStateChunk(item, '', false)
    local start = 1
    for i = 1, r.GetMediaItemTakeInfo_Value(take, 'IP_TAKENUMBER') do
        start = chunk:find('\nTAKE[ \r\n]', start + 1) or start
    end
    local stop = chunk:find('\nTAKE[ \r\n]', start + 1) or #chunk
    chunk = chunk:sub(start, stop)

    local left, zoom = chunk:match('\nCFGEDITVIEW (%S+) (%S+)')
    local timebase = 0
    local field = 0
    for word in (chunk:match('\nCFGEDIT ([^\n]+)') or ''):gmatch('%S+') do
        field = field + 1
        if field == 19 then timebase = tonumber(word) end
    end
    View.OK = left ~= nil and r.MIDIEditor_GetMode(FocusedMidiEditor) == 0
    if not View.OK then return end

    -- Timebases 0 and 4 are beats (zoom = pixels per tick), the others are time (zoom = pixels per second)
    View.IsBeats = timebase == 0 or timebase == 4
    View.Left    = tonumber(left)
    if not View.IsBeats then View.Left = r.MIDI_GetProjTimeFromPPQPos(take, View.Left) end
    View.Zoom    = tonumber(zoom)
    View.NotesH  = View.H
    for height in chunk:gmatch('\nVELLANE %S+ (%S+)') do
        View.NotesH = View.NotesH - tonumber(height)
    end
end

local function Get_Notes(Tk)
    local _, hash = r.MIDI_GetHash(Tk, true, '')
    local Cache = NoteCache[Tk]
    if Cache and Cache.Hash == hash and Cache.IsBeats == View.IsBeats then return Cache end

    Cache = { Hash = hash, IsBeats = View.IsBeats }
    OrigVels[Tk] = OrigVels[Tk] or {}
    local Orig = OrigVels[Tk]
    local _, Count = r.MIDI_CountEvts(Tk)
    for i = 0, Count - 1 do
        local _, sel, _, start, _, _, _, vel = r.MIDI_GetNote(Tk, i)
        if sel then
            -- Goes through project time so that notes of other takes in the editor line up with the active take
            local time = r.MIDI_GetProjTimeFromPPQPos(Tk, start)
            Orig[i] = Orig[i] or vel
            Cache[#Cache + 1] = { Pos = View.IsBeats and r.MIDI_GetPPQPosFromProjTime(take, time) or time, Vel = vel, Orig = Orig[i] }
        end
    end
    NoteCache[Tk] = Cache
    return Cache
end

local function Prepare_Bitmap()
    if Overlay_Bitmap and Overlay_W == View.W and Overlay_H == View.H then return true end
    if Overlay_Bitmap then r.JS_LICE_DestroyBitmap(Overlay_Bitmap) end
    Overlay_W, Overlay_H = View.W, View.H
    Overlay_Bitmap = r.JS_LICE_CreateBitmap(true, View.W, View.H)
    if not Overlay_Bitmap then return false end
    return r.JS_Composite(MidiView, 0, 0, View.W, View.H, Overlay_Bitmap, 0, 0, View.W, View.H) == 1
end

local function Draw_Velocity_Overlay()
    if not View.OK or not Prepare_Bitmap() then return end

    local Lists, Key = {}, { View.Left, View.Zoom, View.W, View.NotesH }
    local i = 0
    local Tk = r.MIDIEditor_EnumTakes(FocusedMidiEditor, i, false)
    while Tk do
        local Notes = Get_Notes(Tk)
        Lists[#Lists + 1] = Notes
        Key[#Key + 1] = Notes.Hash
        i = i + 1
        Tk = r.MIDIEditor_EnumTakes(FocusedMidiEditor, i, false)
    end
    Key = table.concat(Key, ' ')
    if Key == LastDrawn then return end
    LastDrawn = Key

    local bitmap, width = Overlay_Bitmap, View.W
    local top, bottom = RULER_H, View.NotesH - 1
    local function VelToY(vel)
        return math.floor(bottom - (vel - 1) / 126 * (bottom - top) + 0.5)
    end

    r.JS_LICE_Clear(bitmap, 0)
    local HasNotes = false
    for _, Notes in ipairs(Lists) do HasNotes = HasNotes or Notes[1] ~= nil end
    if HasNotes then
        r.JS_LICE_Line(bitmap, 0, top, width - 1, top, Overlay_Color_Grid, 1, 'COPY', false)
        r.JS_LICE_Line(bitmap, 0, VelToY(64), width - 1, VelToY(64), Overlay_Color_Grid, 1, 'COPY', false)
        r.JS_LICE_Line(bitmap, 0, bottom, width - 1, bottom, Overlay_Color_Grid, 1, 'COPY', false)
    end

    for _, Notes in ipairs(Lists) do
        for _, N in ipairs(Notes) do
            local x = math.floor((N.Pos - View.Left) * View.Zoom + 0.5)
            if -2 <= x and x <= width + 1 then
                local newY = VelToY(N.Vel)
                local color = (N.Vel > N.Orig and Overlay_Color_BarUp) or (N.Vel < N.Orig and Overlay_Color_BarDown) or Overlay_Color_Bar
                r.JS_LICE_FillRect(bitmap, x - 1, newY, 3, bottom - newY, color, 1, 'COPY')
                r.JS_LICE_FillRect(bitmap, x - 3, newY - 1, 7, 3, color, 1, 'COPY')
                if N.Vel ~= N.Orig then
                    local origY = VelToY(N.Orig)
                    r.JS_LICE_Line(bitmap, x - 4, origY, x + 4, origY, Overlay_Color_Original, 1, 'COPY', false)
                end
            end
        end
    end

    r.JS_Window_InvalidateRect(MidiView, 0, 0, width, View.H, false)
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
        im.SetNextWindowPos(ctx, Disp.InitMsX - GUI_Win_Sz_W / 2, MouseInitPosY - GUI_Win_Sz_H / 2, nil)
        im.SetNextWindowSize(ctx, GUI_Win_Sz_W, GUI_Win_Sz_H)
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
                    for RptTimes = first_Sel_Note, NoteCount - 1, 1 do
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

            Read_View()
            Draw_Velocity_Overlay()

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
