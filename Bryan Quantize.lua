--@todo Fix Note Overlap
AlreadyAdjustedGridX2=false
AlreadyAdjustedGrid_Div2=false
tooltip=false
Wheel_V=0
FocusedMidiEditor =  reaper.MIDIEditor_GetActive()
take = reaper.MIDIEditor_GetTake( FocusedMidiEditor )
ItemTakeGUID = reaper.BR_GetMediaItemTakeGUID( take )
MediaItemGUID  = reaper.BR_GetMediaItemGUID( item )
closestgrid_pos = reaper.BR_GetClosestGridDivision( 0.1 )
MouseInitPosX, MouseInitPosY = reaper.GetMousePosition()
r=reaper
MouseInitPosX_No_Move = MouseInitPosX
startppqpos_Before= {}
StartPosQtzdPPQ={}
StartPos_ProjTime={}
StartPosBeforeQ_ExtState={}
size_w=200
size_h=20
_, TakeGUID_Saved =reaper.GetProjExtState(0,'Quantize', 'Item Take GUID'..ItemTakeGUID)
FrameCountLast=0
PreviouslyFocusedWindow=  reaper.JS_Window_GetFocus()
Take={}

first_Sel_Note =  reaper.MIDI_EnumSelNotes( take, 0 )
retval, NoteCount, CC_EventCount, TextEventCount = reaper.MIDI_CountEvts( take )


reaper.MIDI_GetNote(take, 0)

local VKLow, VKHi = 8, 0xFE

 ctx = reaper.ImGui_CreateContext('My script')

--[[ Font_Andale_Mono = reaper.ImGui_CreateFont('andale mono', 13)
reaper.ImGui_AttachFont(ctx, Font_Andale_Mono) ]]
init_X=200

init_Y=200

_, MouseInitPosY = reaper.ImGui_PointConvertNative( ctx, nil, MouseInitPosY, true)


Midi_Grid_Div, swing, noteLen = reaper.MIDI_GetGrid( take )




retval, division_Original, swingmode, swingamt = reaper.GetSetProjectGrid( 0, false )
reaper.SetProjectGrid( 0, Midi_Grid_Div/4 )

for TrackRpts=0, 50, 1 do 
    Take[TrackRpts] = reaper.MIDIEditor_EnumTakes( FocusedMidiEditor, TrackRpts, true )
    if Take[TrackRpts] ~= nil then
        for RptTimes= first_Sel_Note-1, NoteCount-1, 1 do
            retval, selected, muted, startppqpos_Before[RptTimes], endppqpos, chan, pitch, vel = reaper.MIDI_GetNote( Take[TrackRpts], RptTimes )
        -- r.ShowConsoleMsg('sel:'..tostring(selected)..'\n StartPos:'..startppqpos..'\n')
            noteLength = endppqpos- startppqpos_Before[RptTimes]
            if TakeGUID_Saved == ItemTakeGUID then 
                _, StartPosBeforeQ_ExtState[RptTimes] = reaper.GetProjExtState(0, 'Quantize','Item'..ItemTakeGUID..'Note'..RptTimes..'Pos (Before Q)')
                _, StartPosAfterQ_ExtState = reaper.GetProjExtState(0,'Quantize', 'Item'..ItemTakeGUID..'Note'..RptTimes..'Pos (After Q)' )
                StartPosAfterQ_ExtState = tonumber(StartPosAfterQ_ExtState)
                if StartPosAfterQ_ExtState == startppqpos_Before[RptTimes] then
                    startppqpos_Before[RptTimes] = tonumber (StartPosBeforeQ_ExtState[RptTimes])
                    _, MouseDeltaX_ExtState = reaper.GetProjExtState(0, 'Quantize', 'Item'..ItemTakeGUID..'Note'..RptTimes..'Quantize Stength - ')
                    MouseDeltaX_ExtState = tonumber(MouseDeltaX_ExtState)
                    --reaper.ShowConsoleMsg(MouseDeltaX_ExtState)
                end

            end
        end
    end
end


function loop()  
    --[[     state = reaper.JS_VKeys_GetDown( 0.1 ) 

    keyState = reaper.JS_VKeys_GetState(0.5):sub(VKLow, VKHi)
    ]]

    isQKeyDown = reaper.ImGui_IsKeyDown( ctx, 81)
    isWKeyDown = reaper.ImGui_IsKeyDown( ctx, 87)
    isQKeyREL = reaper.ImGui_IsKeyReleased( ctx, 81)
    MouseX, MouseY = reaper.GetMousePosition()
    MouseDeltaX = MouseInitPosX- MouseX
    --TestDeltaX = MouseDeltaX_ExtState-(MouseInitPosX- MouseX)


    

  local window_flags =  r.ImGui_WindowFlags_NoDecoration()       |
                        r.ImGui_WindowFlags_AlwaysAutoResize()

    reaper.ImGui_SetNextWindowBgAlpha(ctx, 0.01)
    reaper.ImGui_SetNextWindowPos( ctx, MouseInitPosX_No_Move, MouseInitPosY, nil)
    reaper.ImGui_SetNextWindowSize( ctx, size_w, size_h)

    visible, open = reaper.ImGui_Begin(ctx, 'My Win', true,window_flags)
    if visible then

        reaper.ImGui_PushFont(ctx, Font_Andale_Mono)

        if  MouseDeltaX <  -200 then 
            MouseDeltaX = -200 
            MouseInitPosX= MouseX-200
        end
        if  MouseDeltaX > 0 then 
            MouseDeltaX = 0
            MouseInitPosX= MouseX
            
        end
        vertical, horizontal = reaper.ImGui_GetMouseWheel( ctx )
        Wheel_V = vertical+Wheel_V
        if Wheel_V > 5 then Wheel_V = 5 end
        if Wheel_V < -5 then Wheel_V = -5 end

        if Wheel_V > 3 and AlreadyAdjustedGridX2==false  then 
            reaper.SetProjectGrid( 0, (Midi_Grid_Div/4)/2 )
            reaper.SetMIDIEditorGrid( 0, (Midi_Grid_Div/4)/2 )
            AlreadyAdjustedGridX2=true
        elseif Wheel_V <3 and AlreadyAdjustedGridX2==true then 
            reaper.SetProjectGrid( 0, (Midi_Grid_Div/4) )
            reaper.SetMIDIEditorGrid( 0, (Midi_Grid_Div/4))
            AlreadyAdjustedGridX2=false

        elseif Wheel_V < -3 and AlreadyAdjustedGrid_Div2==false then 
            reaper.SetProjectGrid( 0, (Midi_Grid_Div/4)*2 )
            reaper.SetMIDIEditorGrid( 0, (Midi_Grid_Div/4)*2)
            r.ImGui_SetTooltip(ctx, 'Grid: x2')
            AlreadyAdjustedGrid_Div2=true

        elseif Wheel_V > -3 and AlreadyAdjustedGrid_Div2==true then 
            reaper.SetProjectGrid( 0, (Midi_Grid_Div/4) )
            reaper.SetMIDIEditorGrid( 0, (Midi_Grid_Div/4))

            AlreadyAdjustedGrid_Div2=false
        end
        if AlreadyAdjustedGridX2==true then 
            r.ImGui_SetTooltip(ctx, 'Grid: /2')

        elseif AlreadyAdjustedGrid_Div2 == true then 
            r.ImGui_SetTooltip(ctx, 'Grid: x2')

        elseif AlreadyAdjustedGridX2==false and AlreadyAdjustedGrid_Div2 == false and tooltip==true then 
            
            r.ImGui_SetTooltip(ctx, nil)

        end






        

        drawlist  = reaper.ImGui_GetForegroundDrawList( ctx)
        PosX, PosY = r.ImGui_GetItemRectMin(ctx)
        reaper.ImGui_DrawList_AddLine( drawlist, MouseInitPosX_No_Move, MouseInitPosY+5, MouseInitPosX_No_Move-MouseDeltaX, MouseInitPosY+5, 0x3c473dff, 40)
        reaper.ImGui_DrawList_AddText( drawlist, MouseInitPosX_No_Move, MouseInitPosY+2, 0xffffffff, -MouseDeltaX/2)
        --reaper.ImGui_Text(ctx, 'X Delta:'.. MouseDeltaX..'Y Delta:'.. MouseDeltaY)
        
        for TrackRpts=0, 50, 1 do 
            Take[TrackRpts] = reaper.MIDIEditor_EnumTakes( FocusedMidiEditor, TrackRpts, true )
            if Take[TrackRpts] ~= nil then
                for RptTimes= first_Sel_Note-1, NoteCount-1, 1 do
                    retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote( Take[TrackRpts], RptTimes )

                    

                    if selected then 
                        NoteLength = endppqpos-startppqpos
                        StartPos_ProjTime = reaper.MIDI_GetProjTimeFromPPQPos( Take[TrackRpts], startppqpos_Before[RptTimes] )

                        ClosestGrid = reaper.BR_GetClosestGridDivision( StartPos_ProjTime )
                        Diff_GridtoNote= -(StartPos_ProjTime-ClosestGrid)
                        StartPosQtzd = StartPos_ProjTime+ (Diff_GridtoNote*(MouseDeltaX/-200))
                        StartPosQtzdPPQ[RptTimes] = reaper.MIDI_GetPPQPosFromProjTime( Take[TrackRpts], StartPosQtzd )
                        reaper.MIDI_SetNote( Take[TrackRpts], RptTimes, nil, nil, StartPosQtzdPPQ[RptTimes] , StartPosQtzdPPQ[RptTimes]+NoteLength, nil, nil, nil, true )
                    end

                end
            end
        end






        reaper.MIDI_Sort( take )
             
        curpos= reaper.GetCursorPosition()
        ClosestGrid = reaper.BR_GetClosestGridDivision( curpos )
        r.ImGui_PopFont(ctx)
        reaper.ImGui_End(ctx)
    end

    

    if open  and isQKeyREL ~=true then
        reaper.defer(loop)
    else    --on script close
        reaper.SetMIDIEditorGrid( 0, (Midi_Grid_Div/4))

        FrameCount =  reaper.ImGui_GetFrameCount( ctx)
        
        if FrameCount  > FrameCountLast then

            reaper.ImGui_SetNextWindowSize( ctx, 10, 100)

        visible, open = reaper.ImGui_Begin(ctx, 'My Win', true,window_flags)


        reaper.ImGui_End(ctx)

        reaper.JS_Window_SetFocus( PreviouslyFocusedWindow )
        size_w=size_w-1
  
        FrameCountLast= FrameCount

        end
       

        if FrameCount > 2000 then 


            reaper.ImGui_DestroyContext(ctx)
            retval = reaper.GetSetProjectGrid( 0, true, division_Original, swingmode, swingamt )
            reaper.SetProjExtState(0,'Quantize', 'Item Take GUID'..ItemTakeGUID , ItemTakeGUID)
            for RptTimes= first_Sel_Note-1, NoteCount-1, 1 do
                retval, selected, muted, startppqpos, endppqpos, chan, pitch, vel = reaper.MIDI_GetNote( take, RptTimes )
                if selected then 
                    reaper.SetProjExtState(0,'Quantize', 'Item'..ItemTakeGUID..'Note'..RptTimes..'Pos (Before Q)' , startppqpos_Before[RptTimes])
                    reaper.SetProjExtState(0,'Quantize', 'Item'..ItemTakeGUID..'Note'..RptTimes..'Pos (After Q)' , startppqpos)
                    reaper.SetProjExtState(0, 'Quantize', 'Item'..ItemTakeGUID..'Note'..RptTimes..'Quantize Stength - ', MouseDeltaX)


                end
            end
        end


    end

    



    

end


reaper.defer(loop)
