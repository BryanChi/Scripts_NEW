-- Global variables for source track popup
OpenedSrcTrkWin = nil
OpenedSrcSendWin = nil
OpenedSrcTrkWin_X = nil
OpenedSrcTrkWin_Y = nil
OpenSrc_MousePrevDown = false
OpenSrc_MouseDownStartedInside = false
LastSrcPopupFrame = -1

-- Global variables for destination track popup click tracking
SendNameClickTime = nil  -- Frame/time when send name was clicked
SendNameClickTrack = nil  -- Track where send name was clicked
SendNameClickIndex = nil  -- Send index where send name was clicked
SendNameClickHadVolumeDrag = false  -- Whether volume drag happened after send name click
SendNameClickHadSendNameDrag = false  -- Whether send name button drag happened after send name click
SendNameClickMousePos = nil  -- Initial mouse position when send name was clicked

-- Global variables for source track popup click tracking (receives)
RecvNameClickTime = nil
RecvNameClickTrack = nil
RecvNameClickIndex = nil
RecvNameClickHadVolumeDrag = false
RecvNameClickMousePos = nil
RecvNameClickSrcTrack = nil
RecvNameClickRectMax = nil
RecvNameClickRectMinY = nil
RecvBtnDragTime = 0  -- Frame counter for receive drag detection
function OpenSrcTrkWin(ctx, SrcTrk, t)
  local x = OpenedSrcTrkWin_X or im.GetItemRectMax(ctx)
  local y = OpenedSrcTrkWin_Y or select(2, im.GetItemRectMin(ctx))
  x = x + 2
  y = y - 2
  local FXCt = r.TrackFX_GetCount(SrcTrk)

  local rectH = 100 + 10 * FXCt
  local LineAtLeft = 30
  local Top = y - rectH * 0.1
  local Btm = y + rectH * 0.9
  local LineThick = 8
  local WinPad = 12
  im.SetNextWindowPos(ctx, x + 2, Top)
  im.PushStyleVar(ctx, im.StyleVar_WindowPadding, LineThick + WinPad, LineThick + WinPad)

  local resize = 0
  local notitle = im.WindowFlags_NoTitleBar

   im.SetNextWindowSizeConstraints(ctx, 300, -1, 300, -1)
   im.Begin(ctx, 'SrcTrackWin' .. (OpenedSrcSendWin or ''), true,  notitle |im.WindowFlags_NoResize | im.WindowFlags_NoBackground | im.WindowFlags_AlwaysAutoResize)
  InTrackPopup = true
  local L = x + LineAtLeft
  local Y_Mid = y + 8
  local WDL = im.GetWindowDrawList(ctx)
  local _, __availH = im.GetContentRegionAvail(ctx)

  im.DrawList_AddLine(WDL, x, Y_Mid, L, Y_Mid, outlineClr, LineThick)
  im.Indent(ctx, LineAtLeft + 2)
  -- Wrap existing controls in a child panel (use available height to prevent feedback growth)
  if im.BeginChild(ctx, 'SrcTrackControls' .. (OpenedSrcSendWin or ''), 200, nil, im.ChildFlags_AutoResizeY, im.WindowFlags_NoScrollbar | im.WindowFlags_NoScrollWithMouse | im.WindowFlags_NoTitleBar ) then

    local _, SrcTrkName = r.GetTrackName(SrcTrk)

    MyText(SrcTrkName, Font_Andale_Mono_15_B, 0xffffffff, WrapPosX, ctx)
    im.Spacing(ctx)
    im.Spacing(ctx)
    im.Spacing(ctx)
    local Vol = r.GetMediaTrackInfo_Value(SrcTrk, 'D_VOL')
    local ShownVol = roundUp(VAL2DB(r.GetMediaTrackInfo_Value(SrcTrk, 'D_VOL')), 0.1)
    -- consistent widths and row layout
    local sliderW = 190
    local valueW  = 60
    local rowH    = im.GetTextLineHeight(ctx) + 6
    -- VOL label
    im.AlignTextToFramePadding(ctx)

    -- volume slider
    im.SetNextItemWidth(ctx, sliderW)
    local rv, VolAdj = im.DragDouble(ctx, '##SrcTrackVol', 0, 0.1, min, max, '', im.SliderFlags_NoInput)
    if im.IsItemClicked(ctx) then AdjDestTrkVol = SrcTrk end
    if AdjDestTrkVol then
      out = DragVol(ctx, Vol, 'Horiz', 0.7)
      r.SetMediaTrackInfo_Value(SrcTrk, 'D_VOL', out)
      if not im.IsMouseDown(ctx, 0) then AdjDestTrkVol = nil end
      if LBtnDC then r.SetMediaTrackInfo_Value(SrcTrk, 'D_VOL', 1) end
    end
    -- center value text over the control; remove colored backdrops
    local VolL, VolT = im.GetItemRectMin(ctx)
    local VolW, VolH = im.GetItemRectSize(ctx)
    -- value rectangle fill (left -> current)
    local FaderV = Convert_Val2Fader(Vol)
    local vFillCol = (Clr and Clr.ValueRect) or 0x77777777
    im.DrawList_AddRectFilled(WDL, VolL, VolT+2, VolL + VolW * FaderV, VolT + VolH-2, vFillCol)
    local VolText = (Vol <= 0.0001) and '-inf' or (('%.1f dB'):format(ShownVol))
    local tw, th = im.CalcTextSize(ctx, VolText)
    local cx = VolL + (VolW - tw) / 2
    local cy = VolT + (VolH - th) / 2
    im.DrawList_AddText(WDL, cx, cy, getClr(im.Col_Text), VolText)

    local Pan = r.GetMediaTrackInfo_Value(SrcTrk, 'D_PAN')
    -- PAN label
    im.AlignTextToFramePadding(ctx)

    -- pan slider
    im.SetNextItemWidth(ctx, sliderW)
    local rv, TrackPan = im.DragDouble(ctx, '##SrcTrackPan', 0, 0.01, 0, 1, '', im.SliderFlags_NoInput)
    if im.IsItemClicked(ctx) then AdjustDestTrkPan = SrcTrk end
    if AdjustDestTrkPan then
      local out = DragVol(ctx, Pan, 'Horiz', 0.01, 'Pan')
      r.SetMediaTrackInfo_Value(SrcTrk, 'D_PAN', out)
      if not im.IsMouseDown(ctx, 0) then AdjustDestTrkPan = nil end
      if LBtnDC then r.SetMediaTrackInfo_Value(SrcTrk, 'D_PAN', 0) end
    end
    local PanL, PanT = im.GetItemRectMin(ctx)
    local PanW, PanH = im.GetItemRectSize(ctx)
    local PanSZ = 5
    local centerX = PanL + PanW/2
    local valueX  = centerX + (Pan or 0) * (PanW/2 - 1)
    -- center line
    im.DrawList_AddLine(WDL, centerX, PanT+2, centerX, PanT + PanH-2, Change_Clr_A(getClr(im.Col_TextDisabled), 0.6), 1)
    -- value rectangle fill (center -> current)
    local x1 = valueX > centerX and valueX or centerX
    local x2 = valueX < centerX and valueX or centerX
    local pFillCol = (Clr and Clr.ValueRect) or 0x77777777
    im.DrawList_AddRectFilled(WDL, x2, PanT+2, x1, PanT + PanH-2, pFillCol)
    local ShownPan
    if Pan < 0.01 and Pan > -0.01 then
      ShownPan = 'C'
    elseif Pan >= 0.01 then
      ShownPan = ('%.0f'):format(Pan * 100) .. '% R'
    else
      ShownPan = ('%.0f'):format(Pan * -100) .. '% L'
    end
    -- center the pan text over the control
    local ptw, pth = im.CalcTextSize(ctx, ShownPan)
    local pcx = PanL + (PanW - ptw) / 2
    local pcy = PanT + (PanH - pth) / 2
    im.DrawList_AddText(WDL, pcx, pcy, getClr(im.Col_Text), ShownPan)
    local SliderSz = im.GetItemRectSize(ctx)

    AddSpacing(10)
    FXBtns(SrcTrk, nil, nil,t, ctx, nil, OPEN)
    SL()
    im.Text(ctx, '  ')

    -- Add FX button at bottom of FX chain (width = FX btn + wet/dry knob)
    do
      im.Spacing(ctx)
      -- Compute combined width similar to FX row: BtnSz + WetDryKnobSz ≈ FXPane_W - WetDryKnobSz * 1.5
      local availW = ({im.GetContentRegionAvail(ctx)})[1]
      local combinedW = math.max(40, (availW or 0) - (WetDryKnobSz or 0) * 1.5) 
      local addH = math.max(16, (im.GetTextLineHeight(ctx) or 12) + 4)
      -- Transparent button with subtle hover tint
      im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, 0xffffff11)
      im.PushStyleColor(ctx, im.Col_ButtonActive, 0xffffff22)
      local clicked = im.Button(ctx, '+##SrcAddFX' .. tostring(SrcTrk), combinedW , addH)
      -- Dotted outline around the button; brighten slightly on hover
      do
        local L_rect, T_rect = im.GetItemRectMin(ctx)
        local R_rect, B_rect = im.GetItemRectMax(ctx)
        local dl = FDL or im.GetForegroundDrawList(ctx)
        local col = im.IsItemHovered(ctx) and 0xaaaaaaff or 0x444444ff
        local thick = 2
        DrawDottedRect(dl, L_rect , T_rect, R_rect, B_rect, col, 4, thick)
      end
      im.PopStyleColor(ctx, 3)
      if clicked then
        im.OpenPopup(ctx, 'Btwn FX Windows' .. tostring(SrcTrk))
      end
      local popupName = 'Btwn FX Windows' .. tostring(SrcTrk)
      if im.BeginPopup(ctx, popupName) then
        local insertPos = r.TrackFX_GetCount(SrcTrk) or 0
        if FilterBox(ctx, SrcTrk, insertPos, LyrID, SpaceIsBeforeRackMixer, FxGUID_Container, SpcIsInPre, SpcIsInPost, SpcIDinPost) then
          im.CloseCurrentPopup(ctx)
        end
        im.EndPopup(ctx)
      end
    end
    
    im.EndChild(ctx)
  end

  local W, H = im.GetWindowSize(ctx)
  local x, y = im.GetWindowPos(ctx)

  local R = x + W - LineThick - WinPad
  local y = y + 5
  local H = H - 10
  im.DrawList_AddRect(WDL, L, y, R, y + H, outlineClr, 3, nil, LineThick / 2)
  local BDL = im.GetBackgroundDrawList(ctx)
  im.DrawList_AddRectFilled(BDL, L, y, R, y + H, 0x000000ff, 0, nil)

  -- Add separate child panel for sends and receives on the right side using existing functions
  local sendsChildW = 200

  if im.BeginChild(ctx, 'SrcSendsPanel' .. (OpenedSrcSendWin or ''), sendsChildW, nil, im.ChildFlags_AutoResizeY, im.WindowFlags_NoScrollbar + im.WindowFlags_NoScrollWithMouse) then
    im.Dummy(ctx, 0, 5) -- top margin

    
    -- Use existing Send_Btn function for sends
    local numSends = r.GetTrackNumSends(SrcTrk, 0)
    if numSends > 0 then
      -- Temporarily set Track variable for Send_Btn function
      local originalTrack = Track
      local originalTrkID = TrkID
      local originalNumSends = NumSends
      local originalSend_W = Send_W
      local originalWDL = WDL
      Track = SrcTrk
      TrkID = r.GetTrackGUID(SrcTrk)
      -- Provide globals expected by Send_Btn
      NumSends = numSends
      Send_W = sendsChildW
      WDL = im.GetWindowDrawList(ctx)
      -- Compute button width similar to Sends_List
      local btnParamW = sendsChildW - (SendValSize or 40) - 20
      if btnParamW < 40 then btnParamW = sendsChildW - 20 end
      -- Use existing send button function
      local savedOpenIdx = OpenedDestSendWin
      local savedOpenTrk = OpenedDestTrkWin
      OpenedDestSendWin = nil
      OpenedDestTrkWin = nil
      Send_Btn(ctx, SrcTrk, t, btnParamW)
      OpenedDestSendWin = savedOpenIdx
      OpenedDestTrkWin = savedOpenTrk
      
      -- Restore original variables
      Track = originalTrack
      TrkID = originalTrkID
      NumSends = originalNumSends
      Send_W = originalSend_W
      WDL = originalWDL
    end
    
    -- Use existing ReceiveBtn function for receives
    local numRecvs = r.GetTrackNumSends(SrcTrk, -1)
    if numRecvs > 0 then
      
      -- Temporarily set Track variable for ReceiveBtn function
      local originalTrack = Track
      local originalTrkID = TrkID
      local originalSend_W = Send_W
      local originalWDL = WDL
      Track = SrcTrk
      TrkID = r.GetTrackGUID(SrcTrk)
      -- Provide globals expected by ReceiveBtn (uses Send_W and WDL)
      Send_W = sendsChildW
      WDL = im.GetWindowDrawList(ctx)
      
      -- Use existing receive button function
      for i = 0, numRecvs - 1 do
        ReceiveBtn(ctx, SrcTrk, t, i, sendsChildW - 40)
      end
      
      -- Restore original variables
      Track = originalTrack
      TrkID = originalTrkID
      Send_W = originalSend_W
      WDL = originalWDL
    end
    
    im.EndChild(ctx)
  end

  local x, y = im.GetWindowPos(ctx)
  local w, h = im.GetWindowSize(ctx)

  do
    local hovered = im.IsMouseHoveringRect(ctx, L, y, L + w, y + h, im.HoveredFlags_RectOnly)
    -- Manual click detection using JS mouse state (works outside ImGui)
    local curDown = (r.JS_Mouse_GetState(1) == 1)
    OpenSrc_MousePrevDown = OpenSrc_MousePrevDown or false
    OpenSrc_MouseDownStartedInside = OpenSrc_MouseDownStartedInside or false
    -- On press edge
    if curDown and not OpenSrc_MousePrevDown then
      if hovered then
        OpenSrc_MouseDownStartedInside = true
      else
        -- New click started outside: close immediately
        if not rv then OpenedSrcSendWin, OpenedSrcTrkWin, OpenedSrcTrkWin_X, OpenedSrcTrkWin_Y = nil, nil, nil, nil end
      end
    end
    -- On release edge, clear drag-origin flag
    if (not curDown) and OpenSrc_MousePrevDown then
      OpenSrc_MouseDownStartedInside = false
    end
    OpenSrc_MousePrevDown = curDown
    -- Also allow Esc to close
    if im.IsKeyPressed(ctx, im.Key_Escape) and not rv then
      OpenedSrcSendWin, OpenedSrcTrkWin, OpenedSrcTrkWin_X, OpenedSrcTrkWin_Y = nil, nil, nil, nil
    end
  end 
  im.PopStyleVar(ctx)
  
  InTrackPopup = false
  im.End(ctx)
  return rv 
end

function OpenDestTrackPopup(ctx, DestTrk, t)
  local x = im.GetItemRectMax(ctx)
  local y = select(2, im.GetItemRectMin(ctx))
  x = x + 2
  y = y - 2
  local FXCt = r.TrackFX_GetCount(DestTrk)

  local rectH = 100 + 10 * FXCt
  local LineAtLeft = 30
  local Top = y - rectH * 0.1
  local Btm = y + rectH * 0.9
  local LineThick = 8
  local WinPad = 12
  im.SetNextWindowPos(ctx, x + 2, Top)
  --im.SetNextWindowSize(ctx, FXPane_W + LineAtLeft + LineThick, rectH + LineThick)
  im.PushStyleVar(ctx, im.StyleVar_WindowPadding, LineThick + WinPad, LineThick + WinPad)

  -- Avoid per-frame growth: do NOT use AlwaysAutoResize
  local resize = 0
  local notitle = im.WindowFlags_NoTitleBar

  im.SetNextWindowSizeConstraints(ctx, 300, 300, 300,300)
  im.Begin(ctx, 'SendDestTrackWin' .. (OpenedDestSendWin or ''), true,  notitle |im.WindowFlags_NoResize | im.WindowFlags_NoBackground)
  InTrackPopup = true
  --if im.BeginPopup(ctx, 'SendDestTrackWin' .. i, im.WindowFlags_NoBackground()) then
  local L = x + LineAtLeft
  local Y_Mid = y + 8
  local WDL = im.GetWindowDrawList(ctx)
  -- Capture available height for side-by-side children to keep layout stable
  local _, __availH = im.GetContentRegionAvail(ctx)

  im.DrawList_AddLine(WDL, x, Y_Mid, L, Y_Mid, outlineClr, LineThick)
  im.Indent(ctx, LineAtLeft + 2)
  -- Wrap existing controls in a child panel (use available height to prevent feedback growth)
  if im.BeginChild(ctx, 'TrackControls' .. (OpenedDestSendWin or ''), 200, nil, im.ChildFlags_AutoResizeY, im.WindowFlags_NoScrollbar | im.WindowFlags_NoScrollWithMouse | im.WindowFlags_NoTitleBar ) then


    local _, DestTrkName = r.GetTrackName(DestTrk)

    MyText(DestTrkName, Font_Andale_Mono_15_B, 0xffffffff, WrapPosX, ctx)
    im.Spacing(ctx)
    im.Spacing(ctx)
    im.Spacing(ctx)
    local Vol = r.GetMediaTrackInfo_Value(DestTrk, 'D_VOL')
    local ShownVol = roundUp(VAL2DB(r.GetMediaTrackInfo_Value(DestTrk, 'D_VOL')), 0.1)
    -- consistent widths and row layout
    local sliderW = 190
    local valueW  = 60
    local rowH    = im.GetTextLineHeight(ctx) + 6
    -- VOL label
    im.AlignTextToFramePadding(ctx)

    -- volume slider
    im.SetNextItemWidth(ctx, sliderW)
    local rv, VolAdj = im.DragDouble(ctx, '##TrackVol', 0, 0.1, min, max, '', im.SliderFlags_NoInput)
    if im.IsItemClicked(ctx) then AdjDestTrkVol = DestTrk end
    if AdjDestTrkVol then
      out = DragVol(ctx, Vol, 'Horiz', 0.7)
      r.SetMediaTrackInfo_Value(DestTrk, 'D_VOL', out)
      if not im.IsMouseDown(ctx, 0) then AdjDestTrkVol = nil end
      if LBtnDC then r.SetMediaTrackInfo_Value(DestTrk, 'D_VOL', 1) end
    end
    -- center value text over the control; remove colored backdrops
    local VolL, VolT = im.GetItemRectMin(ctx)
    local VolW, VolH = im.GetItemRectSize(ctx)
    -- value rectangle fill (left -> current)
    local FaderV = Convert_Val2Fader(Vol)
    local vFillCol = (Clr and Clr.ValueRect) or 0x77777777
    im.DrawList_AddRectFilled(WDL, VolL, VolT+2, VolL + VolW * FaderV, VolT + VolH-2, vFillCol)
    local VolText = (Vol <= 0.0001) and '-inf' or (('%.1f dB'):format(ShownVol))
    local tw, th = im.CalcTextSize(ctx, VolText)
    local cx = VolL + (VolW - tw) / 2
    local cy = VolT + (VolH - th) / 2
    im.DrawList_AddText(WDL, cx, cy, getClr(im.Col_Text), VolText)

    local Pan = r.GetMediaTrackInfo_Value(DestTrk, 'D_PAN')
    -- PAN label
    im.AlignTextToFramePadding(ctx)

    -- pan slider
    im.SetNextItemWidth(ctx, sliderW)
    local rv, TrackPan = im.DragDouble(ctx, '##TrackPan', 0, 0.01, 0, 1, '', im.SliderFlags_NoInput)
    if im.IsItemClicked(ctx) then AdjustDestTrkPan = DestTrk end
    if AdjustDestTrkPan then
      local out = DragVol(ctx, Pan, 'Horiz', 0.01, 'Pan')
      r.SetMediaTrackInfo_Value(DestTrk, 'D_PAN', out)
      if not im.IsMouseDown(ctx, 0) then AdjustDestTrkPan = nil end
      if LBtnDC then r.SetMediaTrackInfo_Value(DestTrk, 'D_PAN', 0) end
    end
    local PanL, PanT = im.GetItemRectMin(ctx)
    local PanW, PanH = im.GetItemRectSize(ctx)
    local PanSZ = 5
    local centerX = PanL + PanW/2
    local valueX  = centerX + (Pan or 0) * (PanW/2 - 1)
    -- center line
    im.DrawList_AddLine(WDL, centerX, PanT+2, centerX, PanT + PanH-2, Change_Clr_A(getClr(im.Col_TextDisabled), 0.6), 1)
    -- value rectangle fill (center -> current)
    local x1 = valueX > centerX and valueX or centerX
    local x2 = valueX < centerX and valueX or centerX
    local pFillCol = (Clr and Clr.ValueRect) or 0x77777777
    im.DrawList_AddRectFilled(WDL, x2, PanT+2, x1, PanT + PanH-2, pFillCol)
    local ShownPan
    if Pan < 0.01 and Pan > -0.01 then
      ShownPan = 'C'
    elseif Pan >= 0.01 then
      ShownPan = ('%.0f'):format(Pan * 100) .. '% R'
    else
      ShownPan = ('%.0f'):format(Pan * -100) .. '% L'
    end
    -- center the pan text over the control
    local ptw, pth = im.CalcTextSize(ctx, ShownPan)
    local pcx = PanL + (PanW - ptw) / 2
    local pcy = PanT + (PanH - pth) / 2
    im.DrawList_AddText(WDL, pcx, pcy, getClr(im.Col_Text), ShownPan)
    --[[ SL(VolW, 30)
    im.Text(ctx, '              ') ]]
    local SliderSz = im.GetItemRectSize(ctx)


    -- for adding frame on the right side


    AddSpacing(10)
    FXBtns(DestTrk, nil, nil,t, ctx, nil, OPEN)
    SL()
    im.Text(ctx, '  ')

    -- Add FX button at bottom of FX chain (width = FX btn + wet/dry knob)
    do
      im.Spacing(ctx)
      -- Compute combined width similar to FX row: BtnSz + WetDryKnobSz ≈ FXPane_W - WetDryKnobSz * 1.5
      local availW = ({im.GetContentRegionAvail(ctx)})[1]
      local combinedW = math.max(40, (availW or 0) - (WetDryKnobSz or 0) * 1.5) 
      local addH = math.max(16, (im.GetTextLineHeight(ctx) or 12) + 4)
      -- Transparent button with subtle hover tint
      im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, 0xffffff11)
      im.PushStyleColor(ctx, im.Col_ButtonActive, 0xffffff22)
      local clicked = im.Button(ctx, '+##DestAddFX' .. tostring(DestTrk), combinedW , addH)
      -- Dotted outline around the button; brighten slightly on hover
      do
        local L_rect, T_rect = im.GetItemRectMin(ctx)
        local R_rect, B_rect = im.GetItemRectMax(ctx)
        local dl = FDL or im.GetForegroundDrawList(ctx)
        local col = im.IsItemHovered(ctx) and 0xaaaaaaff or 0x444444ff
        local thick = 2
        DrawDottedRect(dl, L_rect , T_rect, R_rect, B_rect, col, 4, thick)
      end
      im.PopStyleColor(ctx, 3)
      if clicked then
        im.OpenPopup(ctx, 'Btwn FX Windows' .. tostring(DestTrk))
      end
      local popupName = 'Btwn FX Windows' .. tostring(DestTrk)
      if im.BeginPopup(ctx, popupName) then
        local insertPos = r.TrackFX_GetCount(DestTrk) or 0
        if FilterBox(ctx, DestTrk, insertPos, LyrID, SpaceIsBeforeRackMixer, FxGUID_Container, SpcIsInPre, SpcIsInPost, SpcIDinPost) then
          im.CloseCurrentPopup(ctx)
        end
        im.EndPopup(ctx)
      end
    end
    
    im.EndChild(ctx)
  end

  local W, H = im.GetWindowSize(ctx)
  local x, y = im.GetWindowPos(ctx)

  local R = x + W - LineThick - WinPad
  local y = y + 5
  local H = H - 10
  im.DrawList_AddRect(WDL, L, y, R, y + H, outlineClr, 3, nil, LineThick / 2)
  local BDL = im.GetBackgroundDrawList(ctx)
  im.DrawList_AddRectFilled(BDL, L, y, R, y + H, 0x000000ff, 0, nil)


  local x, y = im.GetWindowPos(ctx)
  local w, h = im.GetWindowSize(ctx)





  do
    local hovered = im.IsMouseHoveringRect(ctx, L, y, L + w, y + h, im.HoveredFlags_RectOnly)
    -- Manual click detection using JS mouse state (works outside ImGui)
    local curDown = (r.JS_Mouse_GetState(1) == 1)
    OpenDest_MousePrevDown = OpenDest_MousePrevDown or false
    OpenDest_MouseDownStartedInside = OpenDest_MouseDownStartedInside or false
    -- On press edge
    if curDown and not OpenDest_MousePrevDown then
      if hovered then
        OpenDest_MouseDownStartedInside = true
      else
        -- New click started outside: close immediately
        if not rv then OpenedDestSendWin, OpenedDestTrkWin = nil, nil end
      end
    end
    -- On release edge, clear drag-origin flag
    if (not curDown) and OpenDest_MousePrevDown then
      OpenDest_MouseDownStartedInside = false
    end
    OpenDest_MousePrevDown = curDown
    -- Also allow Esc to close
    if im.IsKeyPressed(ctx, im.Key_Escape) and not rv then
      OpenedDestSendWin, OpenedDestTrkWin = nil, nil
    end
  end 
  -- If a switch has been requested (e.g., from clicking a receive), close this popup and open the target next frame
  if OpenDest_SwitchTo_Track and r.ValidatePtr2(0, OpenDest_SwitchTo_Track, 'MediaTrack*') then
    OpenedDestTrkWin = OpenDest_SwitchTo_Track
    OpenedDestSendWin = OpenDest_SwitchTo_Index
    OpenDest_SwitchTo_Track = nil
    OpenDest_SwitchTo_Index = nil
    -- end this popup now; caller frame will reopen on the new track
  end
  im.PopStyleVar(ctx)
  
  --im.EndPopup(ctx)
  InTrackPopup = false
  im.End(ctx)
  return rv 
end
local function PanFader(ctx,Track, Trk_Height, ACTIVE_PAN_V ,t,DisableFader, LockToCenter)
  local retval, pan1, pan2, panmode = r.GetTrackUIPan(Track)
  local IsInv, Active
  for i, v in pairs(PanningTracks) do 
    if PanningTracks_INV[i] == t then 
      IsInv = true 
    end
    if v ==t then 
      Active = true 
    end
  end
   
  local L_or_R
  if pan1 < -0.01 then  L_or_R = 'L' elseif pan1>-0.01 and pan1<0.01 then L_or_R= '' else    L_or_R= 'R' end 
  --[[ im.Text(ctx, math.abs(pan1*100) ..' '.. L_or_R)
  SL()
  im.Text(ctx,Trk_Height) ]]
  --local SendNameClick = im.Button(ctx, 'asdsa' .. '##' , -1 , SendsLineHeight)
  im.SetNextItemWidth(ctx, -15)
  im.PushStyleVar(ctx, im.StyleVar_FramePadding, -50, Trk_Height/2.2 )
  local ShownPan = math.abs( math.ceil( pan1*100))
  if ShownPan == 0 then ShownPan = 'Center' end
  --im.PushFont(ctx, Impact_24)
  if IsInv then 
    im.PushStyleColor(ctx, im.Col_SliderGrab, Clr.Fader_Inv) 
    im.PushStyleColor(ctx, im.Col_FrameBg, Clr.Fader_Inv_Bg)
  elseif Active then 
    im.PushStyleColor(ctx, im.Col_SliderGrab, getClr(im.Col_SliderGrabActive)) 
    im.PushStyleColor(ctx, im.Col_FrameBg, getClr(im.Col_FrameBgActive))
  end
  local L, T = im.GetCursorScreenPos(ctx)
  im.PushStyleColor(ctx, im.Col_SliderGrab, 0x00000000)
  im.PushStyleColor(ctx, im.Col_SliderGrabActive, 0x00000000)
  im.PushStyleColor(ctx, im.Col_FrameBg, 0xffffff00)
  im.PushStyleColor(ctx, im.Col_FrameBgHovered, 0xffffff00)
  im.PushStyleColor(ctx, im.Col_FrameBgActive, 0x00000000)

  -- When a preset is active, keep slider value locked to current pan (pan1)
  -- This prevents the slider from visually following the mouse
  -- We still capture drag to update ACTIVE_PAN_V (for magnitude), but display shows preset value
  -- When LockToCenter is true (Alt+double-click drag), force slider to center (0)
  local sliderValue = pan1
  if LockToCenter then
    -- Force slider to center (0) to prevent visual movement during Alt+double-click drag
    sliderValue = 0
  elseif Pan_Preset_Active then
    -- Force slider to always show current pan value (set by preset), not mouse position
    sliderValue = pan1
  end
  
  local rv, pan_ctrl = im.SliderDouble(ctx,'##', sliderValue, -1, 1, '', im.SliderFlags_NoInput)
  
  -- Check if this slider item was clicked and double-clicked (must check immediately after slider creation)
  local sliderClicked = im.IsItemClicked(ctx)
  local sliderDoubleClicked = LBtnDC and sliderClicked
  local currentMods = im.GetKeyMods(ctx)
  local has_alt_on_slider = (currentMods == Alt) or ((currentMods & Alt) ~= 0)
  
  -- When preset is active and slider is dragged, use pan_ctrl for ACTIVE_PAN_V but keep display as pan1
  if Pan_Preset_Active and rv then
    -- Slider was dragged - pan_ctrl will be used to update ACTIVE_PAN_V
    -- But we need to ensure the slider visually shows pan1 (preset value) not pan_ctrl
    -- This is handled by passing pan1 as the slider value above
  end
  
  -- Return click information along with pan value
  -- Return format: pan_value, was_clicked, was_double_clicked, had_alt
  PanFader_ClickInfo = PanFader_ClickInfo or {}
  PanFader_ClickInfo[t] = {
    clicked = sliderClicked,
    doubleClicked = sliderDoubleClicked,
    hadAlt = has_alt_on_slider
  }
  im.PopStyleColor(ctx, 5)
  local text = tostring(ShownPan) .. ' ' .. L_or_R
  local txtSz = Trk_Height/2.2
  im.PushFont(ctx, Impact_24)
  local textWidth, textHeight = im.CalcTextSize(ctx, text)
  im.PopFont(ctx)
  
  --local L,T = im.GetItemRectMin(ctx)
  local SldrW, SldrH = im.GetItemRectSize(ctx)  -- width of the slider control itself

  local H = Trk_Height

  local centerX = L + (SldrW - textWidth) / 2
  local centerY = T + (H) / 2  -  textHeight/2
  -- Draw value indication from center to current value using slider width rather than window width
  local CenterX = L + SldrW / 2
  -- When preset is active, use pan1 (preset value) for visual display, not pan_ctrl (mouse position)
  local displayValue = Pan_Preset_Active and pan1 or pan_ctrl
  local ValueX = L + ((displayValue + 1) / 2) * SldrW
  -- Colour changes and glow depending on hover / active state
  local is_hovered = im.IsItemHovered(ctx)
  local is_active  = im.IsItemActive(ctx)
  local FillClr    = Clr.PanSliderFill or Clr.PanValue
  -- accumulate vertical drag (Alt + drag)
  if is_active and Mods == Alt then
    local _, dy = im.GetMouseDelta(ctx)
    if dy ~= 0 then
      VERT_PAN_ACCUM = (VERT_PAN_ACCUM or 0) + math.abs(dy)
    end
  end

  if PanningTracks_INV[t] == t then
    FillClr = Change_Clr_A(Clr.PanSliderFill or Clr.PanValue_INV, 0.2)
  end

  if is_active or PanningTracks[t] == t then
    FillClr = Change_Clr_A(Clr.PanSliderFill or Clr.PanValue, 0.2)  -- brighter when dragging
  elseif is_hovered then
    FillClr = Change_Clr_A(Clr.PanSliderFill or Clr.PanValue, 0.2)  -- slightly brighter on hover
  end
  local X1 = ValueX > CenterX and ValueX or CenterX
  local X2 = ValueX < CenterX and ValueX or CenterX

  -- draw fill from centre to value
  -- Disable value rectangle when LockToCenter is true (Alt+double-click drag state)
  if not LockToCenter then
    im.DrawList_AddRectFilled(WDL, X1, T, X2, T + SldrH, FillClr)
  end

  
  -- glow effect while actively dragging, similar to send volume bar
  -- Disable glow when LockToCenter is true (Alt+double-click drag state)
  if not LockToCenter and (is_active and im.IsMouseDown(ctx, 0) or PanningTracks[t] == t) then
    local X = ValueX > CenterX and X1 or  X2
    DrawGlowRect(WDL, X, T+2, X, T + SldrH-2, FillClr, 6, 8)
  end
  
  -- draw text after the value rectangle
  im.DrawList_AddTextEx(WDL, Impact_24, 24, centerX, centerY, Clr.PanTextOverlay, text)

  if IsInv or Active then im.PopStyleColor(ctx, 2) end 
  --im.PopFont(ctx)
  im.PopStyleVar(ctx)

  local L,T = im.GetItemRectMin(ctx)
  local W,H = im.GetItemRectSize(ctx)
  
  
 
  
  if rv and not DisableFader then 
    PanningTracks[t] = t 
    
    -- If a preset is active, still update ACTIVE_PAN_V from drag (for magnitude control)
    -- but the preset controls the actual pan values, not the slider position
    if Pan_Preset_Active then
      -- Return pan_ctrl to update ACTIVE_PAN_V (controls preset magnitude)
      -- The preset will set the actual pan values, so slider position doesn't matter
      return pan_ctrl
    end

    r.Undo_BeginBlock()
    --r.SetTrackUIPan( Track, pan_ctrl, false, true, 0) 
    return pan_ctrl 

  end

  

 
  if im.IsMouseHoveringRect(ctx, L, T, L+W, T+H )   then 
    if  ACTIVE_PAN_V and Mods == Alt and im.IsMouseDown(ctx, 0)  then
      --r.SetTrackUIPan( Track, ACTIVE_PAN_V, false, true, 0) 
      -- include continuous range between first selected and this track
      local minIndex, maxIndex = t, t
      for idx in pairs(PanningTracks) do
        if idx < minIndex then minIndex = idx end
        if idx > maxIndex then maxIndex = idx end
      end
      if t < minIndex then minIndex = t end
      if t > maxIndex then maxIndex = t end
      for i = minIndex, maxIndex do
        PanningTracks[i] = i
      end 
      if im.IsKeyPressed(ctx, im.Key_1) then
        Pan_Preset_Active = toggle(Pan_Preset_Active,1)
      elseif im.IsKeyPressed(ctx, im.Key_2) then
        Pan_Preset_Active = toggle(Pan_Preset_Active,2)
      elseif im.IsKeyPressed(ctx, im.Key_3) then
        Pan_Preset_Active = toggle(Pan_Preset_Active,3)
      end
      if im.IsKeyPressed(ctx, im.Key_Z) then 
        PanningTracks_INV[t] = t 
      end
    end
    
    
  end


end
function Set_Out_Channel_To_A_New_Stereo_Channel(track, fx_id, pairIndex)
  -- Route the container's output to a new stereo pair beyond 1/2.
  -- pairIndex: 1 = ch 1/2, 2 = ch 3/4, 3 = ch 5/6, ... (defaults to 2)
  -- TrackFX_SetPinMappings(track, fx_id, isOutput, pinIndex, low32Bitmask, hi32Bitmask)
  pairIndex = math.max(2, tonumber(pairIndex) or 2)

  -- Ensure the track has enough channels for the requested pair
  local neededCh = pairIndex * 2
  local curCh = math.floor(tonumber(r.GetMediaTrackInfo_Value(track, 'I_NCHAN')) or 2)
  if curCh < neededCh then
    r.SetMediaTrackInfo_Value(track, 'I_NCHAN', neededCh)
  end

  -- Build bitmasks for the target pair
  local leftBit  = 2 ^ (((pairIndex - 1) * 2)    ) -- e.g. pairIndex=2 -> ch3 -> 2^2 = 4
  local rightBit = 2 ^ (((pairIndex - 1) * 2) + 1) -- e.g. pairIndex=2 -> ch4 -> 2^3 = 8

  -- Set output pin mappings (overwrite existing)
  r.TrackFX_SetPinMappings(track, fx_id, 1, 0, leftBit, 0)   -- Left out -> target L
  r.TrackFX_SetPinMappings(track, fx_id, 1, 1, rightBit, 0)  -- Right out -> target R
end

-- Helpers to pick stereo pairs for Send FX containers
local function FirstSetBitIndex(n)
  n = tonumber(n) or 0
  if n <= 0 then return nil end
  local p, b = 1, 0
  while p < n do
    p = p * 2
    b = b + 1
  end
  if p ~= n then return nil end -- only handle single-bit masks
  return b
end

local function GetContainerStereoPairIndex(track, fx_id)
  local leftMask, _ = r.TrackFX_GetPinMappings(track, fx_id, 1, 0) -- output L (low32)
  if type(leftMask) ~= 'number' then leftMask = leftMask or 0 end
  local bitIdx = FirstSetBitIndex(leftMask)
  if bitIdx == nil then return nil end
  return math.floor(bitIdx / 2) + 1 -- 0/1 -> pair 1, 2/3 -> pair 2, ...
end

local function FindNextSendFXStereoPair(track)
  local used = {}
  local fxCount = r.TrackFX_GetCount(track)
  for fx = 0, fxCount - 1 do
    local _, renamed = r.TrackFX_GetNamedConfigParm(track, fx, 'renamed_name')
    if renamed and renamed:find('^Send FX for ') then
      local p = GetContainerStereoPairIndex(track, fx)
      if p then used[p] = true end
    end
  end
  local p = 2 -- start at 3/4
  while used[p] do p = p + 1 end
  return p
end

function Check_If_FX_Exist_In_Container(track, container_id, fx_name)
  -- Return nil if container_id is invalid
  if not container_id or container_id < 0 then
    return nil
  end
  
  -- Get the number of FX in the container
  local _, fx_count = r.TrackFX_GetCount(track)
  
  -- Get the number of FX inside the container
  local _, container_count = r.TrackFX_GetNamedConfigParm(track, container_id, 'container_count')
  container_count = tonumber(container_count) or 0
  
  -- Check each FX in the container
  for i = 0, container_count - 1 do
    local _, fx_id = r.TrackFX_GetNamedConfigParm(track, container_id, 'container_item.'..i)
    if fx_id then
      local _, actual_name = r.TrackFX_GetNamedConfigParm(track, fx_id, 'fx_name')
      if actual_name == fx_name then
        return fx_id  -- Return the FX ID if found
      end
    end
  end
  
  return nil  -- Return nil if FX not found in container
end

function Drag_With_Bar_Indicator(ctx, label, val, track, fx_id, param_idx, bar_clr, format)
  -- Displays an ImGui DragDouble and overlays a bar representing the current value.
  -- Returns (changed, new_val)
  format = format or "%.3f"
  local changed
  im.PushItemWidth(ctx, 60)
  changed, val = im.DragDouble(ctx, label, val, 0.001, 0, 1, format)
  im.PopItemWidth(ctx)

  -- Draw filled bar over the drag control representing current value
  local x1, y1 = im.GetItemRectMin(ctx)
  local x2, y2 = im.GetItemRectMax(ctx)
  local dl = im.GetWindowDrawList(ctx)
  local w = x2 - x1
  local fill_w = w * math.max(0, math.min(1, val))
  local fill_clr = bar_clr or Clr.GenericHighlightFill
  im.DrawList_AddRectFilled(dl, x1, y1, x1 + fill_w, y2, fill_clr)

  -- If value changed, push to FX parameter
  if changed and track and fx_id and param_idx then
    r.TrackFX_SetParamNormalized(track, fx_id, param_idx, val)
  end

  return changed, val
end
local function ExpandTrack(ctx, Track)
  if im.IsItemHovered(ctx)  then
    local expandShortcut = Shortcuts and Shortcuts.ExpandTrack
    local keyToCheck = expandShortcut and expandShortcut.key or im.Key_E
    local modsToCheck = expandShortcut and expandShortcut.mods or 0
    
    if im.IsKeyPressed(ctx, keyToCheck) and im.GetKeyMods(ctx) == modsToCheck then
      ExpandTrackHeight(Track)
    end
  end
end
-- Track Alt+double-click state per track to prevent pan interaction
AltDoubleClickDragActive = AltDoubleClickDragActive or {}

function Do_Pan_Faders_If_In_MIX_MODE (ctx, Track, t)
  if not (MIX_MODE or MIX_MODE_Temp) then  return end 
  
  local currentMods = im.GetKeyMods(ctx)
  local has_alt = (currentMods == Alt) or ((currentMods & Alt) ~= 0)
  local trackKey = tostring(t) -- Use track index as key
  
  -- Check if we're in Alt+double-click drag state
  local isAltDoubleClickDrag = AltDoubleClickDragActive[trackKey] and has_alt and im.IsMouseDown(ctx, 0)
  
  -- Initialize DisableFader state before calling PanFader
  -- Check if we're in Alt+double-click drag state - disable fader to prevent pan interaction
  if isAltDoubleClickDrag then
    -- Keep disabled during Alt+drag after double-click
    DisableFader = true
  elseif LBtnDC then
    -- Any double-click: disable fader for this frame initially
    DisableFader = true
  end
  
  -- Call PanFader with LockToCenter flag to keep slider visually at center during Alt+double-click drag
  local rv =  PanFader(ctx,Track,Trk[t].H ,ACTIVE_PAN_V, t, DisableFader, isAltDoubleClickDrag)
  
  -- Check if the pan fader slider was clicked and double-clicked (using info from PanFader)
  PanFader_ClickInfo = PanFader_ClickInfo or {}
  local clickInfo = PanFader_ClickInfo[t]
  if clickInfo and clickInfo.doubleClicked then
    if clickInfo.hadAlt or has_alt then
      -- Alt+double-click: center the track volume (set to 1.0 = 0dB/unity gain)
      r.SetMediaTrackInfo_Value(Track, 'D_VOL', 1.0)
      -- Also center the pan to keep fader visually centered
      r.SetTrackUIPan( Track, 0, false, true, 0) 
      ACTIVE_PAN_V = 0
      -- Mark this track as having Alt+double-click drag active
      -- This will keep DisableFader true in subsequent frames while Alt is held
      AltDoubleClickDragActive[trackKey] = true
      -- Ensure fader is disabled to prevent pan interaction during Alt+drag
      DisableFader = true
    else
      -- Regular double-click: center the pan
      r.SetTrackUIPan( Track, 0, false, true, 0) 
      ACTIVE_PAN_V = 0
      DisableFader = true
      -- Clear Alt+double-click state for regular double-click
      AltDoubleClickDragActive[trackKey] = nil
    end
    -- Clear click info after processing
    PanFader_ClickInfo[t] = nil
  end
  
  -- Clean up Alt+double-click state when mouse is released
  if not im.IsMouseDown(ctx, 0) then
    DisableFader = nil
    AltDoubleClickDragActive[trackKey] = nil
  elseif not has_alt and AltDoubleClickDragActive[trackKey] then
    -- Alt was released, clear the state
    AltDoubleClickDragActive[trackKey] = nil
    DisableFader = nil
  end
  
  if rv  then 
    ACTIVE_PAN_V = rv 
  end
  
  if not im.IsMouseDown(ctx, 0) then ACTIVE_PAN_V = 0 end 

end


-- Helpers: find send envelopes (volume/pan) and utilities
-- (logs removed)

local function EnvelopeHasAnyData(env)

  if not env then return false end
  local ai = r.CountAutomationItems and r.CountAutomationItems(env) or 0
  if ai and ai > 0 then return true end
  local pt = r.CountEnvelopePoints and r.CountEnvelopePoints(env) or 0
  return (pt or 0) > 0
end

local function FindSendEnvelopesForSendIndex(track, sendIndex)
  if not (track and sendIndex ~= nil) then return nil, nil end
  
  -- Try SWS extension function first (more direct)
  if r.BR_GetMediaTrackSendInfo_Envelope then
    local envVol = r.BR_GetMediaTrackSendInfo_Envelope(track, 0, sendIndex, 0) -- 0 for volume
    local envPan = r.BR_GetMediaTrackSendInfo_Envelope(track, 0, sendIndex, 1) -- 1 for pan
    if envVol or envPan then
      return envVol, envPan
    end
  end
  
  -- Fallback: search through all envelopes
  -- Get the destination track for this send index
  local destTrkObj = r.GetTrackSendInfo_Value(track, 0, sendIndex, 'P_DESTTRACK')
  if not destTrkObj then return nil, nil end
  local destGUID = r.GetTrackGUID(destTrkObj)
  if not destGUID then return nil, nil end
  
  local envVol, envPan
  local envCnt = r.CountTrackEnvelopes(track) or 0
  for e = 0, envCnt - 1 do
    local env = r.GetTrackEnvelope(track, e)
    if env then
      local ok, name = r.GetEnvelopeName(env)
      if ok and name then
        local n = name:lower()
        if n:find('send') then
          -- Get the destination track for this envelope
          local envDestTrkObj = r.GetEnvelopeInfo_Value(env, 'P_DESTTRACK')
          if envDestTrkObj then
            local envDestGUID = r.GetTrackGUID(envDestTrkObj)
            -- Match if the envelope's destination GUID matches this send's destination GUID
            if envDestGUID == destGUID then
              if (n:find('volume') or n:find('vol')) and not envVol then
                envVol = env
              elseif n:find('pan') and not envPan then
                envPan = env
              end
            end
          end
        end
      end
    end
    if envVol and envPan then break end
  end
  --
  return envVol, envPan
end

local function RevealEnvelopeInTCP(env)
  if not env then return end
  r.GetSetEnvelopeInfo_String(env, 'VISIBLE', '1', true)
  r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', '1', true)
  r.GetSetEnvelopeInfo_String(env, 'ACTIVE', '1', true)
end

-- Helpers: read/toggle envelope states
local function GetEnvelopeStates(env)
  if not env then return false, false, true end
  -- Validate envelope by trying to get its name
  local ok, _ = r.GetEnvelopeName(env)
  if not ok then return false, false, true end
  local _, vis = r.GetSetEnvelopeInfo_String(env, 'VISIBLE', '', false)
  local _, shw = r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', '', false)
  local _, act = r.GetSetEnvelopeInfo_String(env, 'ACTIVE', '', false)
  return vis == '1', shw == '1', act ~= '0'
end

local function ToggleEnvelopeVisible(env)
  if not env then return end
  local _, vis = r.GetSetEnvelopeInfo_String(env, 'VISIBLE', '', false)
  local new = (vis == '1') and '0' or '1'
  r.GetSetEnvelopeInfo_String(env, 'VISIBLE', new, true)
  r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', new, true)
end

local function ToggleEnvelopeActive(env)
  if not env then return end
  local _, act = r.GetSetEnvelopeInfo_String(env, 'ACTIVE', '', false)
  local new = (act == '1') and '0' or '1'
  r.GetSetEnvelopeInfo_String(env, 'ACTIVE', new, true)
end

-- Deletion animation state for Sends
SendDeleteAnim = SendDeleteAnim or {}
PendingSendRemovals = PendingSendRemovals or {}
-- Use global DELETE_ANIM_STEP if available (from FX list), else default fast step
SEND_DELETE_ANIM_STEP = SEND_DELETE_ANIM_STEP or (DELETE_ANIM_STEP or 0.08)

-- Creation animation state for Sends
SendCreateAnim = SendCreateAnim or {}
SEND_CREATE_ANIM_STEP = 0.05

local function MakeSendKey(track, destGUID, index)
  local guid = r.GetTrackGUID(track)
  return tostring(guid) .. '|' .. tostring(destGUID or ('invalid_send_' .. tostring(index))) .. '|' .. tostring(index)
end

-- Add receive delete state
ReceiveDeleteAnim = ReceiveDeleteAnim or {}
PendingRecvRemovals = PendingRecvRemovals or {}
-- Add receive create state
ReceiveCreateAnim = ReceiveCreateAnim or {}
local function MakeRecvKey(track, srcGUID, index)
  local guid = r.GetTrackGUID(track)
  return tostring(guid) .. '|recv|' .. tostring(srcGUID or ('invalid_recv_' .. tostring(index))) .. '|' .. tostring(index)
end

-- Pan knob drawing function for sends/receives
DraggingSendPan = DraggingSendPan or {}
local function DrawSendPanKnob(ctx, Track, sendIdx, sendType, rowHeight, id, alphaMultiplier)
  -- sendType: 0 for sends, -1 for receives
  -- alphaMultiplier: optional (0-1) to fade knob during delete animation
  alphaMultiplier = alphaMultiplier or 1.0
  
  -- Get current pan value - use BR_GetSetTrackSendInfo for both sends and receives
  local pan = 0.0
  local vol = 1.0
  if r.BR_GetSetTrackSendInfo then
    pan = r.BR_GetSetTrackSendInfo(Track, sendType, sendIdx, 'D_PAN', false, 0.0) or 0.0
    vol = r.BR_GetSetTrackSendInfo(Track, sendType, sendIdx, 'D_VOL', false, 1.0) or 1.0
  else
    -- Fallback: try GetTrackSendUIVolPan for sends only
    if sendType == 0 then
      local retval, v, p = r.GetTrackSendUIVolPan(Track, sendIdx)
      if retval then
        vol = v or 1.0
        pan = p or 0.0
      else
        return
      end
    else
      return -- Can't get receive pan without BR extension
    end
  end
  
  -- Pan knob size - fill row height with minimal padding
  local effectiveHeight = rowHeight or 14
  local knobRadius = (effectiveHeight * 0.5) - 0.5
  if knobRadius < 4 then knobRadius = 4 end -- minimum usable size
  local knobSize = knobRadius * 2
  
  -- Use FramePadding to match VolumeBar height - set padding before invisible button
  local textLineH = im.GetTextLineHeight(ctx)
  local framePadY = math.max(0, (effectiveHeight - textLineH) / 2)
  im.PushStyleVar(ctx, im.StyleVar_FramePadding, 0, framePadY)
  im.InvisibleButton(ctx, id, knobSize, effectiveHeight)
  im.PopStyleVar(ctx)
  
  local is_active = im.IsItemActive(ctx)
  local is_hovered = im.IsItemHovered(ctx)
  local mouse_delta_y = select(2, im.GetMouseDelta(ctx))
  
  -- Tooltip with value
  if is_hovered or is_active then
    local panText
    if math.abs(pan) < 0.01 then
      panText = "Center"
    elseif pan < 0 then
      panText = string.format("%.0f%% L", math.abs(pan) * 100)
    else
      panText = string.format("%.0f%% R", math.abs(pan) * 100)
    end
    im.SetTooltip(ctx, panText)
  end
  
  -- Handle double-click to center
  if im.IsItemClicked(ctx, im.MouseButton_Left) and im.IsMouseDoubleClicked(ctx, im.MouseButton_Left) then
    pan = 0.0
    if r.BR_GetSetTrackSendInfo then
      r.BR_GetSetTrackSendInfo(Track, sendType, sendIdx, 'D_PAN', true, pan)
    elseif sendType == 0 then
      r.SetTrackSendUIVolPan(Track, sendIdx, vol, pan)
    end
    r.Undo_BeginBlock()
    r.Undo_EndBlock('Center send pan', -1)
  end
  
  -- Handle mouse dragging
  if is_active and mouse_delta_y ~= 0.0 then
    local step = 2 / 200.0  -- full range (-1..1) divided into 200 steps
    local mods = im.GetKeyMods(ctx)
    -- Use Shift constant if available, otherwise check mod flags
    if Shift and (mods == Shift or (mods & Shift) ~= 0) then
      step = step / 5
    elseif (mods & (im.Mod_Shift or 0)) ~= 0 then
      step = step / 5
    end
    pan = pan + (-mouse_delta_y) * step
    pan = math.max(-1.0, math.min(1.0, pan))
    if r.BR_GetSetTrackSendInfo then
      r.BR_GetSetTrackSendInfo(Track, sendType, sendIdx, 'D_PAN', true, pan)
    elseif sendType == 0 then
      r.SetTrackSendUIVolPan(Track, sendIdx, vol, pan)
    end
    if not DraggingSendPan[id] then
      DraggingSendPan[id] = true
      r.Undo_BeginBlock()
    end
  end
  
  -- End undo block when mouse released
  if DraggingSendPan[id] and im.IsMouseReleased(ctx, 0) then
    r.Undo_EndBlock('Adjust send pan', -1)
    DraggingSendPan[id] = nil
  end
  
  -- Drawing
  local tlx, tly = im.GetItemRectMin(ctx)
  local trx, bry = im.GetItemRectMax(ctx)
  -- Use visual radius that's larger than interaction radius for better visibility
  local visualRadius = knobRadius + 1.0  -- Make visual elements 1px larger
  local center_x = tlx + visualRadius
  local center_y = tly + effectiveHeight / 2
  local draw_list = im.GetWindowDrawList(ctx)
  
  -- Determine Theme Color - derive from user's chosen send/receive colors
  local baseAccentColor
  local bgColor
  if sendType == 0 then
    -- Send: use Clr.Send
    baseAccentColor = Clr.Send or 0x289F81FF
    bgColor = Clr.Send or 0x289F81FF
  else
    -- Receive: use Clr.ReceiveSend
    baseAccentColor = Clr.ReceiveSend or 0x569CD6FF
    bgColor = Clr.ReceiveSend or 0x569CD6FF
  end
  
  -- Draw background rectangle to match the send/receive row background color
  im.DrawList_AddRectFilled(draw_list, tlx, tly, trx, bry, bgColor)
  
  -- Draw black solid circle as base for the pan knob
  local blackColor = im.ColorConvertDouble4ToU32(0, 0, 0, 1.0 * alphaMultiplier)
  im.DrawList_AddCircleFilled(draw_list, center_x, center_y, visualRadius, blackColor)
  
  -- Arc calculation
  local ANGLE_MIN = math.pi * 0.75
  local ANGLE_MAX = math.pi * 2.25
  local ANGLE_CENTER = math.pi * 1.5
  
  local t = (pan + 1.0) / 2.0 -- 0..1
  local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * t
  
  -- Draw value arc - make it prominent by increasing opacity and brightness
  local r, g, b, a = im.ColorConvertU32ToDouble4(baseAccentColor)
  local col_arc
  
  if is_hovered or is_active then
    -- When active/hovered: brighten significantly and use full opacity
    col_arc = LightenColorU32 and LightenColorU32(baseAccentColor, 0.4) or baseAccentColor
    local hr, hg, hb, ha = im.ColorConvertU32ToDouble4(col_arc)
    col_arc = im.ColorConvertDouble4ToU32(hr, hg, hb, 1.0 * alphaMultiplier)
  else
    -- Normal state: brighten slightly and use high opacity (0.85) for prominence
    col_arc = LightenColorU32 and LightenColorU32(baseAccentColor, 0.25) or baseAccentColor
    local nr, ng, nb, na = im.ColorConvertU32ToDouble4(col_arc)
    col_arc = im.ColorConvertDouble4ToU32(nr, ng, nb, 0.85 * alphaMultiplier)
  end
  
  -- Draw arc path using visual radius
  im.DrawList_PathClear(draw_list)
  -- If pan is near center, just draw a dot or small line at top
  if math.abs(pan) > 0.01 then
      local start_a, end_a
      if pan < 0 then
          start_a = angle
          end_a = ANGLE_CENTER
      else
          start_a = ANGLE_CENTER
          end_a = angle
      end
      im.DrawList_PathArcTo(draw_list, center_x, center_y, visualRadius - 1.5, start_a, end_a, 10)
      -- Increased stroke width for more prominence (3.0 instead of 2.5)
      im.DrawList_PathStroke(draw_list, col_arc, 0, 3.0)
  else
      -- Draw Center Mark (small dot at top)
      local cx = center_x + math.cos(ANGLE_CENTER) * (visualRadius - 1.5)
      local cy = center_y + math.sin(ANGLE_CENTER) * (visualRadius - 1.5)
      im.DrawList_AddCircleFilled(draw_list, cx, cy, 1.5, col_arc)
  end

  -- Foreground circle outline - more prominent, always visible
  local outlineR, outlineG, outlineB, outlineA = im.ColorConvertU32ToDouble4(baseAccentColor)
  local outlineOpacity = (is_hovered or is_active) and 0.5 or 0.35  -- More visible: 35% normal, 50% hovered/active
  local outlineColor = im.ColorConvertDouble4ToU32(outlineR, outlineG, outlineB, outlineOpacity * alphaMultiplier)
  im.DrawList_AddCircle(draw_list, center_x, center_y, visualRadius, outlineColor, 0, 1.5)  -- Slightly thicker line (1.5 instead of 1.0)
  
  -- Pointer (Line from center to edge) using visual radius
  local pointer_radius_inner = visualRadius * 0.2
  local pointer_radius_outer = visualRadius * 0.8
  local p_x1 = center_x + math.cos(angle) * pointer_radius_inner
  local p_y1 = center_y + math.sin(angle) * pointer_radius_inner
  local p_x2 = center_x + math.cos(angle) * pointer_radius_outer
  local p_y2 = center_y + math.sin(angle) * pointer_radius_outer
  
  -- Draw pointer line - use red-tinted color that blends with deletion animation, apply alpha multiplier
  -- Use a light red-tinted color (0.95, 0.7, 0.7) instead of white for better blending
  local pointerR, pointerG, pointerB = 0.95, 0.7, 0.7
  local pointerA = 0.8 * alphaMultiplier
  local pointerColor = im.ColorConvertDouble4ToU32(pointerR, pointerG, pointerB, pointerA)
  im.DrawList_AddLine(draw_list, p_x1, p_y1, p_x2, p_y2, pointerColor, 1.5)

  return pan
end

-- Reusable overlay+advance helper
function AdvanceDeleteAnimAndOverlay(ctx, anim, rowMinX, rowMinY, rowMaxX, rowCurH, baseRowH)
  local p = anim.progress or 0
  -- No overlay drawings - content fades to transparent via alpha style var
  
  anim.progress = math.min(1, (anim.progress or 0) + (SEND_DELETE_ANIM_STEP or 0.08))
  im.SetCursorScreenPos(ctx, rowMinX, rowMinY + rowCurH)
  return anim.progress >= 1
end

function Send_Btn(ctx, Track, t, BtnSize)
  if t < -1 then return end 
  --- send buttons color
  do
    local base = Clr.Send
    local hvr  = Clr.SendHvr or (LightenColorU32 and LightenColorU32(base, 0.15)) or base
    im.PushStyleColor(ctx, im.Col_Button, base)
    im.PushStyleColor(ctx, im.Col_ButtonHovered, hvr)
  end


  for i = 0, NumSends-1, 1 do
    local BtnSizeOffset = 0
    local rv, SendName  = r.GetTrackSendName(Track, i)
    local DestTrkObj = r.GetTrackSendInfo_Value(Track, 0, i, 'P_DESTTRACK')
    local Dest_Valid = DestTrkObj and r.ValidatePtr2(0, DestTrkObj, 'MediaTrack*')
    local DestTrkGUID = Dest_Valid and r.GetTrackGUID(DestTrkObj) or ('invalid_send_' .. i)
    local Vol           = r.GetTrackSendInfo_Value(Track, 0, i, 'D_VOL')
    Trk[t].send = Trk[t].send or {}
    Trk[t].send[DestTrkGUID] = Trk[t].send[DestTrkGUID]  or {}
    local Snd = Trk[t].send[DestTrkGUID] 
    local srcGUID = r.GetTrackGUID(Track)
    local sendKey = MakeSendKey(Track, DestTrkGUID, i)
    local rowDeleteAnim = SendDeleteAnim[sendKey]
    local rowCreateAnim = SendCreateAnim[sendKey] -- NEW
    local pushedRowAlpha
    if rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1 then
      local rowAlpha = math.max(0, 1 - (rowDeleteAnim.progress or 0))
      im.PushStyleVar(ctx, im.StyleVar_Alpha, rowAlpha)
      pushedRowAlpha = true
    end

    -- NEW: suppress hover globally if any send is animating
    local AnySendAnimActive = false
    do
      if SendDeleteAnim then
        for _, anim in pairs(SendDeleteAnim) do
          if anim and (anim.progress or 0) < 1 then AnySendAnimActive = true break end
        end
      end
    end

    local SendValW_Ofs =0
    if SendName == '' then 
      if pushedRowAlpha then im.PopStyleVar(ctx) end
      im.PopStyleColor(ctx, 2) 
      return 
    end 
    im.AlignTextToFramePadding(ctx)
    local BP = {}
    local HoverEyes
    --Get Send Bypass State
    local Bypass = r.GetTrackSendInfo_Value(Track, 0, i, 'B_MUTE')
    local RemoveSend
    local DestTrk = DestTrkObj
    local Dest_Hidden
    -- forward declare to allow calls anywhere below
    local Gather_Info_For_Patch_Line
    local function Automation_Indicator()
      --
      -- Draw automation indicator (graph icon) before send volume, sized to row height
      local envVol, envPan = FindSendEnvelopesForSendIndex(Track, i)
      local volHasData = (envVol and EnvelopeHasAnyData(envVol)) or false
      local panHasData = (envPan and EnvelopeHasAnyData(envPan)) or false
      --
      local hasAuto = volHasData or panHasData
      if hasAuto then
        local baseH = (SendsLineHeight or lineH or 14)
        local iconSz = math.max(12, math.floor(baseH + 0.5))
        -- During delete animation, replace with a dummy of shrunken height to not block vertical collapse
        if rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1 then
          local h = (rowCurH or nameBtnH or baseH or iconSz)
          im.Dummy(ctx, iconSz, h)
          SendValW_Ofs = (SendValW_Ofs or 0) + iconSz
        else
          -- Determine tint based on state
          -- Only check volume envelope state (not pan)
          local anyBypassed = false
          local anyVisible = false
          
          if envVol then
            local ok, _ = r.GetEnvelopeName(envVol)
            if ok then
              local visibleVol, showVol, activeVol = GetEnvelopeStates(envVol)
              if visibleVol and showVol then anyVisible = true end
              if not activeVol then anyBypassed = true end
            end
          end
          
          local tint
          if anyBypassed then
            tint = 0x020402ff -- dark gray when bypassed
          elseif anyVisible then
            tint = 0xffffffff -- white when shown
          else
            tint = 0x999999ff -- gray when hidden
          end
          if not AnySendAnimActive and im.ImageButton(ctx, '##SendAuto'..tostring(TrkID)..'_'..i, Img.Graph, iconSz, iconSz, nil, nil, nil, nil, nil, tint) then
            if Mods == Alt then
              -- Alt+click: Delete envelopes using actions
              r.Undo_BeginBlock()
              r.PreventUIRefresh(1)
              
              if envVol then
                r.SetCursorContext(2, envVol)
                r.Main_OnCommand(40065, 0) -- Delete selected envelope
              end
              if envPan then
                r.SetCursorContext(2, envPan)
                r.Main_OnCommand(40065, 0) -- Delete selected envelope
              end
              
              r.PreventUIRefresh(-1)
              r.Undo_EndBlock('Delete send envelopes', -1)
            elseif Mods == Shift then
              ToggleEnvelopeActive(envVol)
            else
              ToggleEnvelopeVisible(envVol)
              ToggleEnvelopeVisible(envPan)
            end
            r.TrackList_AdjustWindows(false)
          end
          if im.IsItemHovered(ctx) then
            SetHelpHint('LMB = Toggle Envelope Visibility', 'Shift+LMB = Toggle Envelope Active/Bypass', 'Alt+LMB = Delete Envelopes')
          end
          SL()
          SendValW_Ofs = (SendValW_Ofs or 0) + iconSz
        end
      end
    end
    Automation_Indicator()
    -- Draw Patch 
    local function Draw_Patch_Lines_RECVS(L)
      if not PatchX or not PatchY then return end
      local L = L
      if not L then
        local itemX, itemY = im.GetItemRectMin(ctx)
        L = itemX
      end
      if not L then return end  -- Safety check
      if HoverRecv_Dest == Track  then
        

        RecvTrk = r.GetTrack(0, t)
        local Chan = r.GetTrackSendInfo_Value(Track, 0, i, 'I_DSTCHAN')


        if HoverRecv_Dest_Chan == Chan and HoverRecv_Src == DestTrk --[[ and HoverRecv_Index == i ]] then
          local rv, Name = r.GetTrackName(RecvTrk)
          local EndX, EndY = im.GetCursorScreenPos(ctx)


          --HighlightSelectedItem(0xffffff22, nil, 0, L, EndY, L + 150, EndY + SendsLineHeight, SendsLineHeight, FXPane_W, 1, 1, getitmrect, FDL, Patch_Thick / 2)
          local H = SendsLineHeight/2

          DrawGlowRect(WDL, L, PatchY, PatchX + Send_W - 15, PatchY + SendsLineHeight, Clr.ReceiveSend, 12)

          local L = L - 5
          local T , B = PatchY + H  , EndY + H
          -- im.DrawList_AddLine(FDL, L, T, L, B, 0xffffffff, Patch_Thick/2)
          DrawBentPatchLine(FDL, L, T, B, 10, (Clr and Clr.PatchLine) or 0xffffffff, false)


        end
      end
      if HoverSend == i .. TrkID then
        if Gather_Info_For_Patch_Line then Gather_Info_For_Patch_Line() end
      end
    end

    -- show indication if sending FROM channel that's not 1-2 (at leftmost position, before hide icon and send name)
    local SrcChan = r.GetTrackSendInfo_Value(Track, 0, i, 'I_SRCCHAN')
    if SrcChan > 0 then 
      local CurX, CurY = im.GetCursorScreenPos(ctx)
      local str = ' '..math.ceil(SrcChan+1)..'-'..math.ceil(SrcChan+2)..' '
      local w ,h = im.CalcTextSize(ctx, str)
      local padding = 2
      local totalWidth = w + padding
      -- Use invisible button to reserve space and advance cursor
      im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000000)
      im.PushStyleColor(ctx, im.Col_ButtonActive, 0x00000000)
      im.Button(ctx, '##SrcChanBadge'..i, totalWidth, h)
      im.PopStyleColor(ctx, 3)
      -- Draw badge on top of the invisible button
      local BadgeX = CurX 
      local BadgeY = CurY + 1
      -- Use darker colors if send is disabled
      local badgeBg = (Bypass == 1) and (DarkenColorU32 and DarkenColorU32(Clr.ChanBadgeBg, 0.5) or Clr.ChanBadgeBg) or Clr.ChanBadgeBg
      local badgeText = (Bypass == 1) and (DarkenColorU32 and DarkenColorU32(Clr.ChanBadgeText, 0.5) or Clr.ChanBadgeText) or Clr.ChanBadgeText
      im.DrawList_AddRectFilled(WDL, BadgeX, BadgeY, BadgeX + w, BadgeY + h, badgeBg)
      im.DrawList_AddText(WDL, BadgeX, BadgeY, badgeText, str)
      im.DrawList_AddRect(WDL, BadgeX, BadgeY, BadgeX + w, BadgeY + h, badgeText)
      BtnSizeOffset = BtnSizeOffset - totalWidth
      SL()
    end

    -- if Send Destination Track is hidden (skip while animating deletion and while hover is blocked)
    if Dest_Valid and not AnySendAnimActive and not HoverBlocked and Mods ~= Alt and not (rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1) and r.GetMediaTrackInfo_Value(DestTrk, 'B_SHOWINTCP') == 0 then
      Dest_Hidden = true
      local hideBtnTint = (Bypass == 1) and 0x020402ff or Clr.Attention
      if im.ImageButton(ctx, '##HideBtn_send_hidden_'..(i or 0)..'_'..(TrkID or ''), Img.Hide, HideBtnSz, HideBtnSz, nil, nil, nil, nil, nil, hideBtnTint) then
        r.SetMediaTrackInfo_Value(DestTrk, 'B_SHOWINTCP', 1)
        RefreshUI_HideTrack()
      end
      if im.IsItemHovered(ctx) then
        SetHelpHint('LMB = Show Hidden Track')
      end
      SL()
      BtnSizeOffset = -HideBtnSz
    end

    -- if hovering send, show Hide Track icon (skip while animating deletion and while hover is blocked)
    if Dest_Valid and HoverSend == i .. TrkID and not Dest_Hidden and not AnySendAnimActive and not HoverBlocked and Mods ~= Alt and not (rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1) then
      local hideBtnTint = (Bypass == 1) and 0x020402ff or Clr.Attention
      if im.ImageButton(ctx, '##HideBtn_send_hover_'..(i or 0)..'_'..(TrkID or ''), Img.Show, HideBtnSz, HideBtnSz, nil, nil, nil, nil, nil, hideBtnTint) then
        r.SetMediaTrackInfo_Value(DestTrk, 'B_SHOWINTCP', 0)
        RefreshUI_HideTrack()
      end
      if im.IsItemHovered(ctx) then
        HoverEyes = true
        SetHelpHint('LMB = Hide Track')
      end
      SL()
    end
    -- if hovering send, show solo icon (skip while animating deletion and while hover is blocked)
    if HoverSend == i .. TrkID and not AnySendAnimActive and not HoverBlocked and Mods ~= Alt and not (rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1) then
      im.PushFont(ctx, Font_Andale_Mono_10_B)
      if Bypass == 1 then
        im.PushStyleColor(ctx, im.Col_Text, 0x020402ff)
        im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
        im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000000)
        im.PushStyleColor(ctx, im.Col_ButtonActive, 0x00000000)
      end
      if im.Button(ctx, 'S', 14, 14) then -- Solo Button
        if Mods == 0 then
          if Dest_Valid then ToggleSolo(DestTrk) end
          --ToggleSolo(Track)
        elseif Mods == Ctrl then
          local unmute
          if NumSends > 1 then
            -- mute all sends except the one clicked
            Trk[TrkID].alreadyMutedSend = Trk[TrkID].alreadyMutedSend or {}
            for S = 0, NumSends - 1, 1 do
              if i ~= S then
                Trk[TrkID].alreadyMutedSend[S] = Trk[TrkID].alreadyMutedSend[S] or
                    r.GetTrackSendInfo_Value(Track, 0, S, 'B_MUTE')
              end
            end

            for S = 0, NumSends - 1, 1 do
              if i ~= S then
                if r.GetTrackSendInfo_Value(Track, 0, S, 'B_MUTE') == 1 and Trk[TrkID].alreadyMutedSend[S] == 0 then --- if send is muted
                  r.SetTrackSendInfo_Value(Track, 0, S, 'B_MUTE', 0)                                                 --unmute
                  unmute = true
                else                                                                                                 --if send is not muted
                  r.SetTrackSendInfo_Value(Track, 0, S, 'B_MUTE', 1)                                                 --mute
                end
              end
            end

            if unmute then Trk[TrkID].alreadyMutedSend = {} end
          end
        end
      end

      if im.IsItemHovered(ctx) then
        HoverEyes = true
        SetHelpHint('LMB = Toggle Send Track Solo', 'Ctrl+LMB = Solo This Send Only')
      end
      if Bypass == 1 then
        im.PopStyleColor(ctx, 4)
      end
      im.PopFont(ctx)
      SL()
      BtnSizeOffset = BtnSizeOffset -20
    end
    im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 0.1, 0.5)
    retval, volume, pan = r.GetTrackSendUIVolPan(Track, i)
    lineH = im.GetTextLineHeight(ctx)
    im.PushStyleColor(ctx, im.Col_ButtonActive, Clr.Send)

    -- compute the row rect from cursor and known widths
    local rowMinX, rowMinY = im.GetCursorScreenPos(ctx)
    local rowMaxX = rowMinX + (Send_W or 0)
    local baseRowH = (SendsLineHeight or lineH or 14)
    -- determine current animation-scaled heights (shrink to 0 as progress→1)
    local animProg = rowDeleteAnim and (rowDeleteAnim.progress or 0) or nil
    local nameBtnBaseH = (lineH + 3)
    local volBtnBaseH  = (SendsLineHeight or lineH or 14)
    local nameBtnH = nameBtnBaseH
    local volBtnH  = volBtnBaseH
    if animProg and animProg < 1 then
      local effective_p = math.max(0, (animProg - 0.25) / 0.75)
      local scale = 1 - (effective_p * effective_p * effective_p)
      nameBtnH = math.max(0.0001, nameBtnBaseH * scale)
      volBtnH  = math.max(0.0001, volBtnBaseH  * scale)
    end
    local rowCurH = math.max(nameBtnH, volBtnH)
    local rowMaxY = rowMinY + rowCurH
    -- draw the send name button with current height
    local SendNameClick = im.Button(ctx, SendName .. '##'..i , BtnSize + BtnSizeOffset, nameBtnH)

    -- Apply creation animation (flash/fade-in)
    if rowCreateAnim and (rowCreateAnim.progress or 0) < 1 then
        local L = rowMinX
        local T = rowMinY
        local R = rowMinX + (Send_W or 0)
        local B = rowMinY + rowCurH
        local dl = im.GetWindowDrawList(ctx)
        
        -- Animation: Flash white/bright and fade out
        local animAlpha = 0.6 * (1 - (rowCreateAnim.progress or 0))
        local col = im.ColorConvertDouble4ToU32(1, 1, 1, animAlpha)
        
        im.DrawList_AddRectFilled(dl, L, T, R, B, col, im.GetStyleVar(ctx, im.StyleVar_FrameRounding))
        
        rowCreateAnim.progress = (rowCreateAnim.progress or 0) + SEND_CREATE_ANIM_STEP
        if rowCreateAnim.progress >= 1 then
          SendCreateAnim[sendKey] = nil
        end
    end

    if im.IsItemHovered(ctx) then
      SetHelpHint('LMB = Open Destination Track', 'Alt+LMB = Remove Send', 'Ctrl+LMB = Show Send Volume Envelope')
    end
    -- Handle Ctrl+click on send name button
    if SendNameClick then
      local currentMods = im.GetKeyMods(ctx)
      if currentMods == Ctrl or (currentMods & Ctrl) ~= 0 then
        -- Ctrl+Left-click: show volume envelope for this send
        -- Select the source track first (required for envelope operations)
        r.SetOnlyTrackSelected(Track)
        
        -- Try SWS extension first if available (most direct method)
        local envVol = nil
        if r.BR_GetMediaTrackSendInfo_Envelope then
          envVol = r.BR_GetMediaTrackSendInfo_Envelope(Track, 0, i, 0) -- 0 for volume envelope
        end
        
        -- If SWS method didn't work, try finding existing envelope
        if not envVol then
          envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
        end
        
        -- If envelope doesn't exist, use action to create/show it
        if not envVol then
          -- Use action 41725 to show send volume envelopes for selected track
          -- This will create the envelopes if they don't exist
          r.Main_OnCommand(41725, 0) -- Show/hide track send volume envelope
          
          -- Try to find it again after the action
          if r.BR_GetMediaTrackSendInfo_Envelope then
            envVol = r.BR_GetMediaTrackSendInfo_Envelope(Track, 0, i, 0)
          end
          if not envVol then
            envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
          end
        end
        
        -- Show the envelope if found
        if envVol and envVol ~= 0 then
          -- Verify it's a valid envelope object
          local ok, name = r.GetEnvelopeName(envVol)
          if ok then
            RevealEnvelopeInTCP(envVol)
            r.TrackList_AdjustWindows(false)
          end
        end
      elseif currentMods == 0 then
        -- Track send name click for popup (only if no modifiers)
        local frame = (im.GetFrameCount and im.GetFrameCount(ctx)) or nil
        SendNameClickTime = frame or r.time_precise()
        SendNameClickTrack = Track
        SendNameClickIndex = i
        SendNameClickHadVolumeDrag = false
        SendNameClickHadSendNameDrag = false
        local mx, my = im.GetMousePos(ctx)
        SendNameClickMousePos = {x = mx, y = my}
      end
    end
    -- If marquee selection is active for sends, register this send row when intersecting
    do
      if MarqueeSelection and MarqueeSelection.isActive and MarqueeSelection.mode == 'sends' then
        -- Only check marquee selection for visible items to prevent selecting hidden sends
        -- when tracks are collapsed/zoomed and coordinates overlap
        if im.IsItemVisible(ctx) then
          -- use the full row rect for hit-testing
          local minX, minY, maxX, maxY = rowMinX, rowMinY, rowMaxX, rowMaxY
          if IsRectIntersectingMarquee(minX, minY, maxX, maxY) then
            local trGUID = r.GetTrackGUID(Track)
            MarqueeSelection.selectedSends[trGUID] = MarqueeSelection.selectedSends[trGUID] or {}
            local exists = false
            for _, ent in ipairs(MarqueeSelection.selectedSends[trGUID]) do
              if ent.type == 0 and ent.idx == i then exists = true break end
            end
            if not exists then table.insert(MarqueeSelection.selectedSends[trGUID], { type = 0, idx = i }) end
          elseif not MarqueeSelection.additive then
            local trGUID = r.GetTrackGUID(Track)
            local arr = MarqueeSelection.selectedSends[trGUID]
            if arr then
              for k = #arr, 1, -1 do
                local ent = arr[k]
                if ent.type == 0 and ent.idx == i then table.remove(arr, k) end
              end
            end
          end
        elseif not MarqueeSelection.additive then
          -- If item is not visible and not in additive mode, remove from selection
          local trGUID = r.GetTrackGUID(Track)
          local arr = MarqueeSelection.selectedSends[trGUID]
          if arr then
            for k = #arr, 1, -1 do
              local ent = arr[k]
              if ent.type == 0 and ent.idx == i then table.remove(arr, k) end
            end
          end
        end
      end
    end

    -- If this row is selected, mark interacting flag so selection isn't cleared on click elsewhere
    do
      if MarqueeSelection and MarqueeSelection.selectedSends then
        local trGUID = r.GetTrackGUID(Track)
        local arr = MarqueeSelection.selectedSends[trGUID]
        if arr then
          for _, ent in ipairs(arr) do
            if ent.type == 0 and ent.idx == i then
              if im.IsItemHovered(ctx) or im.IsItemActive(ctx) then
                InteractingWithSelectedSends = true
              end
              break
            end
          end
        end
      end
    end
    ExpandTrack(ctx, Track)
    im.PopStyleColor(ctx)
    im.PopStyleVar(ctx)  
    if im.IsItemActive(ctx) then 
      -- Check if this is the send that was clicked and detect drag
      if SendNameClickTrack == Track and SendNameClickIndex == i then
        local mx, my = im.GetMousePos(ctx)
        if SendNameClickMousePos then
          local dx = math.abs(mx - SendNameClickMousePos.x)
          local dy = math.abs(my - SendNameClickMousePos.y)
          -- Only consider it a drag if there's actual mouse movement (not just SendBtnDragTime > 0, which happens even on quick clicks)
          -- OR if SendBtnDragTime exceeds a threshold (e.g., > 5 frames) indicating a held drag
          if dx > 1 or dy > 1 or (SendBtnDragTime or 0) > 5 then
            -- This is a volume drag (dragging on send name area adjusts volume)
            SendNameClickHadVolumeDrag = true
          end
        else
          -- No initial position - this shouldn't happen if click was recorded
          -- Only consider it a drag if SendBtnDragTime exceeds threshold (indicating held drag)
          if (SendBtnDragTime or 0) > 5 then
            SendNameClickHadVolumeDrag = true
          end
        end
        
      end
      SendBtnDragTime = (SendBtnDragTime or 0) +1
      -- Begin undo block on first drag frame
      if SendBtnDragTime == 1 then
        r.Undo_BeginBlock()
      end
      local out = SendVal_Calc_MouseDrag(ctx)
      -- compute delta in dB from this row's current value
      local curLin = r.GetTrackSendInfo_Value(Track, 0, i, 'D_VOL')
      local refDB  = VAL2DB(curLin)
      local outDB  = VAL2DB(out)
      local deltaDB = outDB - refDB
      -- apply to the reference row (absolute as dragged)
      r.BR_GetSetTrackSendInfo(Track, 0, i, 'D_VOL', true, out)
      if Gather_Info_For_Patch_Line then Gather_Info_For_Patch_Line(true) end
      -- only do cross-track slot sync if no marquee sends selection
      if not (MarqueeSelection and MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
        AdjustSelectedSendVolumes(Track, 0, i, out)
      end
      -- propagate relative to all marquee-selected sends (type 0), regardless of slot index
      if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
        local activeGUID = r.GetTrackGUID(Track)
        for guid, entries in pairs(MarqueeSelection.selectedSends) do
          local tr = GetTrackByGUIDCached(guid)
          if tr and type(entries) == 'table' then
            for _, ent in ipairs(entries) do
              if ent.type == 0 and ent.idx ~= nil and ent.idx < r.GetTrackNumSends(tr, 0) then
                if not (guid == activeGUID and ent.idx == i) then
                local cur = r.GetTrackSendInfo_Value(tr, 0, ent.idx, 'D_VOL')
                local newDB = VAL2DB(cur) + deltaDB
                local newLin = SetMinMax(DB2VAL(newDB), 0, 4)
                r.BR_GetSetTrackSendInfo(tr, 0, ent.idx, 'D_VOL', true, newLin)
                end
              end
            end
          end
        end
      end
    end
    -- End undo block only when mouse is released after drag was initiated
    -- Store drag state before resetting (for popup logic)
    if SendBtnDragTime and SendBtnDragTime > 0 and im.IsMouseReleased(ctx, 0) then
      -- Mark that volume drag happened if this matches the clicked send
      -- Only consider it a drag if SendBtnDragTime exceeds threshold (quick clicks will have SendBtnDragTime = 1-2)
      if SendNameClickTrack == Track and SendNameClickIndex == i then
        -- Only mark as drag if SendBtnDragTime exceeds threshold (indicating actual drag, not quick click)
        if SendBtnDragTime > 5 then
          SendNameClickHadVolumeDrag = true
        end
      end
      r.Undo_EndBlock('Adjust send volume', -1)
      -- Don't reset SendBtnDragTime yet - let popup check use it first
      -- SendBtnDragTime = 0  
    end
    if Mods == Alt and im.IsItemHovered(ctx) then
      -- Use current row rect (not cached PatchX/Y) to avoid offset after dynamic shrink/reflow
      local L = rowMinX
      local T = rowMinY
      local R = rowMinX + (Send_W or (rowMaxX - rowMinX))
      local B = rowMinY + (rowCurH or (SendsLineHeight or lineH or 14)) + 2
      -- Draw X indicator at cursor position when Alt is pressed
      DrawXIndicator(ctx, 12, Clr.Danger)
      -- Keep the highlight for better visibility
      im.DrawList_AddRect(WDL, L, T, R, B, 0x771111ff, 2)
      im.DrawList_AddRectFilled(WDL, L, T, R, B, 0x00000044)
    end
    

    -- Capture position before VolumeBar for patch line (left edge of volume drag area)
    local volDragX, volDragY = im.GetCursorScreenPos(ctx)
   -- im.InvisibleButton(ctx, '##VolDrag_' .. i .. '_' .. TrkID, BtnSize, volBtnH)
    VolumeBar(ctx,BtnSize,i, 0, volBtnH)
    -- If the send name was clicked and the user is dragging within the volume area, treat it as a drag (prevent popup)
    if im.IsMouseDown(ctx, 0) and SendNameClickTrack == Track and SendNameClickIndex == i then
      local mx, my = im.GetMousePos(ctx)
      if SendNameClickMousePos then
        local dx = math.abs(mx - SendNameClickMousePos.x)
        local dy = math.abs(my - SendNameClickMousePos.y)
        if dx > 3 or dy > 3 then
          SendNameClickHadVolumeDrag = true
        end
      else
        SendNameClickHadVolumeDrag = true
      end
    end
    -- Check if right-click happened on volume drag area and start marquee selection
    if MarqueeSelection and im.IsItemClicked(ctx, 1) and not MarqueeSelection.isActive then
      local mx, my = im.GetMousePos(ctx)
      MarqueeSelection.initialMouseX = mx
      MarqueeSelection.initialMouseY = my
      MarqueeSelection.startingOnVolDrag = true
      MarqueeSelection.hasDragged = true
      StartMarqueeSelection(ctx)
    end
    -- Draw selection highlight for sends if selected via marquee
    do
      local selected = false
      if MarqueeSelection and MarqueeSelection.selectedSends then
        local trGUID = r.GetTrackGUID(Track)
        local arr = MarqueeSelection.selectedSends[trGUID]
        if arr then
          for _, ent in ipairs(arr) do
            if ent.type == 0 and ent.idx == i then selected = true break end
          end
        end
      end
      if selected then
        local dl = im.GetWindowDrawList(ctx)
        im.DrawList_AddRectFilled(dl, rowMinX, rowMinY, rowMaxX, rowMaxY, Change_Clr_A(Clr.Send or 0x289F8144, 0.25))
        im.DrawList_AddRect(dl, rowMinX, rowMinY, rowMaxX, rowMaxY, Change_Clr_A(Clr.Send or 0x289F8144, 0.8))
      end
    end




    im.SameLine(ctx, nil, 1)


    if not AnySendAnimActive and not HoverBlocked and (im.IsItemHovered(ctx) or HoverEyes) and not im.IsItemActive(ctx) then
      HoverSend = i .. TrkID
      SENDS_HOVER_THIS_FRAME = true
      -- expose hover context so keyboard shortcuts can act on the hovered send/receive
      HoverSend_Index = i
      HoverSend_Src = Track
      HoverSend_Dest = DestTrk
      -- Gather patch line info for sends - use left edge of volume drag area
      PatchX, PatchY = volDragX, rowMinY + (SendsLineHeight or lineH or 14) / 2
      HoverSend_Dest_Chan = r.GetTrackSendInfo_Value(Track, 0, i, 'I_DSTCHAN')
      HoverSend_Src_Chan = r.GetTrackSendInfo_Value(Track, 0, i, 'I_SRCCHAN')
    else
      if HoverSend == i .. TrkID then
        HoverSend = nil
        HoverSend_Dest = nil
        HoverSend_Src = nil
        HoverSend_Index = nil
        HoverSend_Dest_Chan = nil
        HoverSend_Src_Chan = nil
      end
    end



    
    if Bypass == 1 then
      BP.L, BP.T = im.GetItemRectMin(ctx)
      BP.R, BP.B = im.GetItemRectMax(ctx)
    end

    if im.IsItemClicked(ctx) then
      if Mods == Shift then
        if Bypass == 0 then
          r.SetTrackSendInfo_Value(Track, 0, i, 'B_MUTE', 1)
        else
          r.SetTrackSendInfo_Value(Track, 0, i, 'B_MUTE', 0)
        end
        -- propagate bypass toggle to marquee-selected sends (type 0)
        if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
          local target = r.GetTrackSendInfo_Value(Track, 0, i, 'B_MUTE')
          for guid, entries in pairs(MarqueeSelection.selectedSends) do
            local tr = GetTrackByGUIDCached(guid)
            if tr and type(entries) == 'table' then
              for _, ent in ipairs(entries) do
                if ent.type == 0 and ent.idx ~= nil and ent.idx < r.GetTrackNumSends(tr, 0) then
                  r.SetTrackSendInfo_Value(tr, 0, ent.idx, 'B_MUTE', target)
                end
              end
            end
          end
        end
      elseif Mods == Alt then
        RemoveSend = true
      end
    end

    -- Right-click on send: select destination/source track and scroll to it in TCP
    -- Alt+Right-click: show volume envelope for the send
    if im.IsItemClicked(ctx, 1) and not MarqueeSelection.isActive and not MarqueeSelection.hasDragged then -- Right mouse button, not during marquee and not a drag
       if Mods == Alt then
         -- Alt+Right-click: show volume envelope for this send
         -- Select the source track first (required for envelope operations)
         r.SetOnlyTrackSelected(Track)
         
         -- First try to find existing envelope
         local envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
         
         if not envVol then
           -- Envelope doesn't exist yet, need to create/show it
           -- Use action 41725 to show send volume envelopes for selected track
           -- This will create the envelopes if they don't exist
           r.Main_OnCommand(41725, 0) -- Show/hide track send volume envelope
           
           -- Now try to find it again
           envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
         end
         
         if envVol and envVol ~= 0 then
           -- Verify it's a valid envelope object
           local ok, name = r.GetEnvelopeName(envVol)
           if ok then
             RevealEnvelopeInTCP(envVol)
             r.TrackList_AdjustWindows(false)
           end
         end
      else
        -- Normal right-click: select destination/source track and scroll to it in TCP
        local targetTrack = nil
        local trackName = ""
        
        -- Determine which track to select based on send direction
        if DestTrkObj and Dest_Valid then
          -- This is a send, select the destination track
          targetTrack = DestTrkObj
          local _, destName = r.GetTrackName(DestTrkObj)
          trackName = destName or "Unknown Track"
        else
          -- This might be a receive, select the source track
          targetTrack = Track
          local _, srcName = r.GetTrackName(Track)
          trackName = srcName or "Unknown Track"
        end
        
        if targetTrack then
          -- Clear current selection and select the target track
          r.SetOnlyTrackSelected(targetTrack)
          
          -- Scroll to the track in TCP with extra pixels for better visibility
          r.CF_SetTcpScroll(targetTrack, -50)
        end
      end
    end

    local ShownVol
    if volume < 0.0001 then
      ShownVol = '-inf'
    else
      ShownVol = ('%.1f'):format(VAL2DB(volume))
    end

    --im.Image(ctx, Img.Send, 10, 10)
    local function Check_If_theres_Send_FX_container()
      local id =  r.TrackFX_GetByName(Track, 'Send FX for '..SendName..'##'..DestTrkGUID, false ) 
      if id and id ~=-1 then 

        Snd.Container = id 
      else
        Snd.Container = nil
      end 
    end

    -- show indication if not sending TO channel 1 and 2 
    
    Check_If_theres_Send_FX_container()
    local CurX, CurY = im.GetCursorScreenPos(ctx)
    
    -- Calculate pan knob offset to prevent overlap with volume readout
    local panKnobOffset = 0
    if ShowSendPanKnobs then
      -- Use animated height for pan knob calculations
      local animEffectiveH = baseRowH
      if animProg and animProg < 1 then
        local effective_p = math.max(0, (animProg - 0.25) / 0.75)
        local scale = 1 - (effective_p * effective_p * effective_p)
        animEffectiveH = math.max(0.0001, baseRowH * scale)
      end
      local effectiveHeight = animEffectiveH + 2
      local knobRadius = (effectiveHeight * 0.5) - 0.5
      if knobRadius < 4 then knobRadius = 4 end
      local knobSize = knobRadius * 2
      panKnobOffset = knobSize + 2  -- Same offset as volume readout
    end

    local Chan = r.GetTrackSendInfo_Value(Track, 0, i, 'I_DSTCHAN')
    if Chan > 0 then 

      --MyText(' '..math.ceil(Chan+1)..'-'..math.ceil(Chan+2)..'  ')
      local str = ' '..math.ceil(Chan+1)..'-'..math.ceil(Chan+2)..' '
      local w ,h = im.CalcTextSize(ctx, str)
      local CurX = CurX - panKnobOffset  -- Offset by pan knob width
      local CurY=CurY+1
      -- Use animated height for badge
      local badgeH = h
      if animProg and animProg < 1 then
        local effective_p = math.max(0, (animProg - 0.25) / 0.75)
        local scale = 1 - (effective_p * effective_p * effective_p)
        badgeH = math.max(0.0001, h * scale)
      end
      im.DrawList_AddRectFilled(WDL, CurX  , CurY, CurX + w , CurY + badgeH, Clr.ChanBadgeBg)
      im.DrawList_AddText(WDL,  CurX  , CurY ,Clr.ChanBadgeText,str )
      im.DrawList_AddRect(WDL, CurX  , CurY, CurX + w , CurY + badgeH, Clr.ChanBadgeText)
      BtnSizeOffset = BtnSizeOffset - w
      SL()
    elseif --[[ (not im.IsItemHovered(ctx) or AnySendAnimActive or HoverBlocked) and ]] --[[ not Snd.HvrOnFXSend and ]] not Snd.Container  then 
      -- vertically squash send icon according to delete animation progress
      local scaleY = 1
      if rowDeleteAnim and (rowDeleteAnim.progress or 0) < 1 then
        local effective_p = math.max(0, ((rowDeleteAnim.progress or 0) - 0.25) / 0.75)
        scaleY = math.max(0.0001, 1 - (effective_p * effective_p * effective_p))
      end
      -- Convert send icon to ImageButton with hover effects and tooltip
      local iconSize = 13 * scaleY
      local iconX = CurX - panKnobOffset
      local iconY = CurY
      im.SetCursorScreenPos(ctx, iconX, iconY)
      -- Use base tint (slightly transparent for normal state)
      local baseTint = 0xCCFFFFFF  -- Slightly transparent white for normal state
      local sendIconClicked = im.ImageButton(ctx, '##SendIcon_'..tostring(t)..'_'..i, Img.Send, 13, iconSize, nil, nil, nil, nil, nil, baseTint)
      -- Check if hovered and apply bold effect (brighter tint) and show tooltip
      if im.IsItemHovered(ctx) then
        -- Make icon bold by overlaying with brighter tint (full opacity)
        local hoverTint = 0xFFFFFFFF  -- Full opacity white for bold effect
        local L, T = im.GetItemRectMin(ctx)
        local R, B = im.GetItemRectMax(ctx)
        im.DrawList_AddImage(WDL, Img.Send, L, T, R, B, nil, nil, nil, nil, hoverTint)
        -- Show tooltip
        im.SetItemTooltip(ctx, 'Add send FX')
      end
      -- Handle click - trigger same function as send FX button
      if sendIconClicked then
        im.OpenPopup(ctx, 'Add FX Window for Send FX' ..tostring(Track)..i)
        
      end
      SL()
    end

    local fxBtnHovered = false
    if --[[ Snd.HvrOnFXSend or ]] Snd.Container then 
      -- Move cursor left by 20px to prevent FX button from obstructing volume readout/pan knob
      local curX, curY = im.GetCursorPos(ctx)
      if curX then
        im.SetCursorPosX(ctx, curX - 20)
      end
      im.PushFont(ctx, Impact_10)
      -- shrink FX button height along with the row during delete animation (add 3px to match volume drag height)
      local fxBtnH = (volBtnH or (SendsLineHeight or 13)) + 3
      -- center text and compute a safe width to avoid right-side cropping
      -- vertically nudge slightly upward for better optical centering
      im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 0 , 0.5)
      im.PushStyleVar(ctx, im.StyleVar_FramePadding, 2, 0)
      local fxLabel = 'FX'
      local fxTw, _ = im.CalcTextSize(ctx, fxLabel)
      local fxBtnW = math.max((SendFXBtnSize or 12), fxTw + 8)
      local rv = im.Button(ctx, fxLabel .. '##'..t..'  i '..i, fxBtnW, fxBtnH)
      im.PopStyleVar(ctx)
      im.PopStyleVar(ctx)
      im.PopFont(ctx)
      if rv then 
        im.OpenPopup(ctx, 'Add FX Window for Send FX' ..tostring(Track)..i)
      end
      SL()
      fxBtnHovered = im.IsItemHovered(ctx)
      SendValW_Ofs = fxBtnW
    end

    local function SendFX()
      
      if im.BeginPopup(ctx, 'Add FX Window for Send FX' ..tostring(Track)..i) then 
        
        Snd.HvrOnFXSend = true 
        local function Add_Container_If_Not_Exist()
          
          -- Look for containers that match the name by checking renamed_name
          local targetName = 'Send FX for '..SendName..'##'..DestTrkGUID
          
          -- First, check if Snd.Container is already set and valid
          if Snd.Container ~= nil then
            local fxCount = r.TrackFX_GetCount(Track)
            -- Verify the container index is still valid
            if Snd.Container >= 0 and Snd.Container < fxCount then
              local _, fxName = r.TrackFX_GetFXName(Track, Snd.Container)
              if fxName == 'Container' then
                local _, renamed = r.TrackFX_GetNamedConfigParm(Track, Snd.Container, 'renamed_name')
                if renamed == targetName then
                  -- Container is already set and valid, no need to search or create
                  return
                end
              end
            end
            -- Container was set but is invalid, reset it
            Snd.Container = nil
          end
          
          -- Use r.TrackFX_GetByName which is more reliable than manual search
          local foundContainer = r.TrackFX_GetByName(Track, targetName, false)
          if foundContainer and foundContainer >= 0 then
            -- Found existing container with matching name
            Snd.Container = foundContainer
          else
            -- No matching container exists, create a new one
            -- Try creating at position 1 first
            local newContainerIdx = AddFX_HideWindow(Track, 'Container', 1)
            if not newContainerIdx then 
              newContainerIdx = r.TrackFX_GetCount(Track)-1
            end 
            
            -- Verify this is a new container (doesn't already have a renamed_name)
            -- If it does, it means an existing container was converted, so try creating at the end
            local _, existingRenamed = r.TrackFX_GetNamedConfigParm(Track, newContainerIdx, 'renamed_name')
            if existingRenamed and existingRenamed ~= '' then
              -- This container was converted, not created new - try creating at the end instead
              newContainerIdx = AddFX_HideWindow(Track, 'Container', -1)
              if not newContainerIdx then
                newContainerIdx = r.TrackFX_GetCount(Track)-1
              end
              
              -- Check again if this one is new
              local _, existingRenamed2 = r.TrackFX_GetNamedConfigParm(Track, newContainerIdx, 'renamed_name')
              if existingRenamed2 and existingRenamed2 ~= '' then
                -- Still converted, can't create new container - abort
                return
              end
            end
            
            -- Set the renamed_name on the new container
            r.TrackFX_SetNamedConfigParm(Track, newContainerIdx, 'renamed_name', targetName)
            
            -- Verify the container can be found by name (this ensures it's properly set)
            local verifyFound = r.TrackFX_GetByName(Track, targetName, false)
            if verifyFound and verifyFound >= 0 then
              -- Successfully created and verified, use the verified index
              Snd.Container = verifyFound
              local chan = tonumber( r.GetMediaTrackInfo_Value( Track, 'I_NCHAN'))
              if chan <= 2 then 
                r.SetMediaTrackInfo_Value(Track,  'I_NCHAN', 4)
              end 
              local pairIndex = FindNextSendFXStereoPair(Track)
              Set_Out_Channel_To_A_New_Stereo_Channel(Track, Snd.Container, pairIndex)
              r.SetTrackSendInfo_Value(Track, 0, i, 'I_SRCCHAN', (pairIndex - 1) * 2)
            else
              -- Failed to verify container after creation, abort (will retry next frame)
              return
            end
          end
        end



        local function PreDelay()
  im.Text(ctx, 'Pre-delay : ')
  SL()

  -- Helper converters between JSFX normalized value (0..1) and displayed ms (-100..100)
  local function NormToMs(v)
    v = tonumber(v) or 0.5
    return (v * 200) - 100 -- 0 -> -100ms, 0.5 -> 0ms, 1 -> +100ms
  end
  local function MsToNorm(ms)
    ms = tonumber(ms) or 0
    local v = (ms + 100) / 200
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return v
  end

  local clr
  if not Snd.HasPreDelay then
    clr = getClr(im.Col_TextDisabled)
  end

  -- Find / cache the JSFX inside the container
  local id = Check_If_FX_Exist_In_Container(Track, Snd.Container, 'JS: Dual Time adjustment +/- Delay')
  if not id then
    -- No JSFX yet; show disabled controls, allow double-click to create
    Snd.predelay_id = nil
    Snd.PreDelay_Init = nil
  else
    Snd.predelay_id = id

    -- One-time init of state from current FX parameters
    if not Snd.PreDelay_Init then
      -- Left / right delays (params 0 and 1)
      local pL = r.TrackFX_GetParamNormalized(Track, id, 0)
      local pR = r.TrackFX_GetParamNormalized(Track, id, 1)
      Snd.PreDelay_L = NormToMs(pL)
      Snd.PreDelay_R = NormToMs(pR)

      -- Locate "Mode" parameter so link state follows the JSFX
      if Snd.PreDelay_ModeParamIndex == nil then
        local numParams = r.TrackFX_GetNumParams(Track, id)
        for p = 0, (numParams or 0) - 1 do
          local _, pname = r.TrackFX_GetParamName(Track, id, p)
          if pname == 'Mode' then
            Snd.PreDelay_ModeParamIndex = p
            break
          end
        end
      end

      if Snd.PreDelay_ModeParamIndex ~= nil then
        local m = r.TrackFX_GetParamNormalized(Track, id, Snd.PreDelay_ModeParamIndex)
        -- JSFX 'Mode' parameter: treat 0.0 as linked, 1.0 as unlinked
        Snd.PreDelay_Linked = (m or 0) < 0.5
      else
        -- Fallback: start linked
        Snd.PreDelay_Linked = true
      end

      Snd.PreDelay_Init = true
    end
  end

  -- Current UI values in ms
  Snd.PreDelay_L = Snd.PreDelay_L or 0
  Snd.PreDelay_R = Snd.PreDelay_R or 0

  -- Draw left delay drag
  local dragFormat = '%.1f'
  if clr then im.PushStyleColor(ctx, im.Col_Text, clr) end
  im.PushItemWidth(ctx, 60)
  local changedL, newL = im.DragDouble(ctx,
    '##PreDelay_L_' .. (t or '') .. '_' .. (i or 0),
    Snd.PreDelay_L, 0.13, -100, 100, dragFormat)
  im.PopItemWidth(ctx)
  if clr then im.PopStyleColor(ctx) end
  
  -- Double-click left drag to reset to 0
  if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
    Snd.PreDelay_L = 0
    if Snd.PreDelay_Linked then
      Snd.PreDelay_R = 0
    end
    changedL = true
    newL = 0
  end

  -- Link icon between L/R
  SL()
  local linkSize = im.GetTextLineHeight(ctx)
  local linked = Snd.PreDelay_Linked and true or false
  local linkTint = linked and 0xffffffff or 0x777777ff
  if Img and Img.Link then
    if im.ImageButton(ctx, '##PreDelay_Link_' .. (t or '') .. '_' .. (i or 0),
      Img.Link, linkSize, linkSize, nil, nil, nil, nil, nil, linkTint) then
      linked = not linked
      Snd.PreDelay_Linked = linked
      -- Push link state into JSFX "Mode" parameter if we found it
      if id and Snd.PreDelay_ModeParamIndex ~= nil then
        -- 0.0 = linked, 1.0 = unlinked
        r.TrackFX_SetParamNormalized(Track, id, Snd.PreDelay_ModeParamIndex, linked and 0 or 1)
      end
    end
    if im.IsItemHovered(ctx) then
      if linked then
        SetHelpHint('LMB = Unlink L/R pre-delay')
      else
        SetHelpHint('LMB = Link L/R pre-delay')
      end
    end
  end

  -- Right delay drag
  SL()
  if clr then im.PushStyleColor(ctx, im.Col_Text, clr) end
  im.PushItemWidth(ctx, 60)
  local changedR, newR = im.DragDouble(ctx,
    '##PreDelay_R_' .. (t or '') .. '_' .. (i or 0),
    Snd.PreDelay_R, 0.13, -100, 100, dragFormat)
  im.PopItemWidth(ctx)
  if clr then im.PopStyleColor(ctx) end
  
  -- Double-click right drag to reset to 0
  if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
    Snd.PreDelay_R = 0
    if Snd.PreDelay_Linked then
      Snd.PreDelay_L = 0
    end
    changedR = true
    newR = 0
  end

  -- Show unit label
  SL()
  im.Text(ctx, 'ms')

  -- If JSFX doesn't exist yet, allow double-click to create it
  if not id then
    if im.IsItemClicked(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
      Snd.predelay_id = AddFX_HideWindow(Track, 'JS: Dual Time adjustment +/- Delay',
        Calc_Container_FX_Index(Track, Snd.Container, 1))
      Snd.PreDelay_Init = nil
    end
    return
  end

  -- Update internal state from drags
  local anyChanged = false
  if changedL then
    anyChanged = true
    Snd.PreDelay_L = newL
    if Snd.PreDelay_Linked then
      Snd.PreDelay_R = newL
    end
  end
  if changedR then
    anyChanged = true
    Snd.PreDelay_R = newR
    if Snd.PreDelay_Linked then
      Snd.PreDelay_L = newR
    end
  end

  -- Apply to all matching JSFX instances in the container when changed
  if anyChanged then
    local normL = MsToNorm(Snd.PreDelay_L)
    local normR = MsToNorm(Snd.PreDelay_R)

    local _, HowManyFXinContainer = r.TrackFX_GetNamedConfigParm(Track, Snd.Container, 'container_count')
    local HowManyFXinContainer = tonumber(HowManyFXinContainer)

    for ci = 0, (HowManyFXinContainer or 0) - 1 do
      local _, fxid = r.TrackFX_GetNamedConfigParm(Track, Snd.Container, 'container_item.' .. ci)
      local fxid = tonumber(fxid)
      local _, nm = r.TrackFX_GetNamedConfigParm(Track, fxid, 'fx_name')

      if nm == 'JS: Dual Time adjustment +/- Delay' then
        r.TrackFX_SetParamNormalized(Track, fxid, 0, normL)
        r.TrackFX_SetParamNormalized(Track, fxid, 1, normR)
        -- Also keep JSFX "Mode" in sync with link state if we found it
        if Snd.PreDelay_ModeParamIndex ~= nil then
          -- Keep JSFX 'Mode' in sync: 0.0 = linked, 1.0 = unlinked
          r.TrackFX_SetParamNormalized(Track, fxid, Snd.PreDelay_ModeParamIndex,
            Snd.PreDelay_Linked and 0 or 1)
        end
      end
    end

    local PreDelayIdx = Calc_Container_FX_Index(Track, Snd.Container)
    local pairIndex = GetContainerStereoPairIndex(Track, Snd.Container) or 2
    r.SetTrackSendInfo_Value(Track, 0, i, 'I_SRCCHAN', (pairIndex - 1) * 2) -- align send to container's pair
    Snd.HasPreDelay = true
  end
end
local function AddFX()
          im.Text(ctx, 'Add FX :     ')
          SL()
          local InsertPos = Calc_Container_FX_Index(Track, Snd.Container)

          local rv , fx =  FilterBox(ctx,Track ,  InsertPos, LyrID, SpaceIsBeforeRackMixer, FxGUID_Container, SpcIsInPre, SpcInPost,SpcIDinPost, false) 
        end



        Add_Container_If_Not_Exist()
        PreDelay()
        AddFX()
        FXBtns(Track, nil, Snd.Container, t, ctx, nil, OPEN)
        im.EndPopup(ctx)

      end
    end
    

    local function Volume_Btn ()
      
      -- Calculate volume button width - reduce if pan knobs are enabled
      local volBtnWidth = SendValSize - SendValW_Ofs
      if ShowSendPanKnobs then
        -- Calculate knob size the same way DrawSendPanKnob does, using animated height
        local animEffectiveH = baseRowH
        if animProg and animProg < 1 then
          local effective_p = math.max(0, (animProg - 0.25) / 0.75)
          local scale = 1 - (effective_p * effective_p * effective_p)
          animEffectiveH = math.max(0.0001, baseRowH * scale)
        end
        local effectiveHeight = animEffectiveH + 2
        local knobRadius = (effectiveHeight * 0.5) - 0.5
        if knobRadius < 4 then knobRadius = 4 end
        local knobSize = knobRadius * 2
        volBtnWidth = volBtnWidth - knobSize - 3  -- Subtract knob size plus extra spacing to prevent overlap
      end
      
      -- Draw the send button at current height (add 3px to match volume drag height)
      local volReadoutH = (volBtnH or (SendsLineHeight or 13)) + 3
      local SendBtnClick = im.Button(ctx, ShownVol .. '##Send', volBtnWidth, volReadoutH)
      
      -- Extended hover check for volume readout to avoid FX button flicker at the right edge
      -- Use the item rect with a small horizontal padding on the right
      local volReadoutHovered do
        local L, T = im.GetItemRectMin(ctx)
        local R, B = im.GetItemRectMax(ctx)
        local mx, my = im.GetMousePos(ctx)
        local pad = 3 -- extra pixels to the right to smooth edge-hover behavior
        if mx and my and L and T and R and B then
          volReadoutHovered = (mx >= L and mx <= R + pad and my >= T and my <= B)
        else
          volReadoutHovered = im.IsItemHovered(ctx)
        end
      end

      im.PopStyleVar(ctx)


      if volReadoutHovered then 
        Snd.HvrOnFXSend= true 
        SetHelpHint('LMB Drag = Adjust Send Volume', 'Shift+Drag = Fine Adjustment', 'Alt+LMB = Remove Send', 'Ctrl+LMB = Show Send Volume Envelope')
      end
      

      if im.IsItemClicked(ctx) and not im.IsPopupOpen(ctx,  'Add FX Window for Send FX' ..tostring(Track)..i) then
        local currentMods = im.GetKeyMods(ctx)
        if currentMods == Ctrl or (currentMods & Ctrl) ~= 0 then
          -- Ctrl+Left-click: show volume envelope for this send
          -- Select the source track first (required for envelope operations)
          r.SetOnlyTrackSelected(Track)
          
          -- Try SWS extension first if available (most direct method)
          local envVol = nil
          if r.BR_GetMediaTrackSendInfo_Envelope then
            envVol = r.BR_GetMediaTrackSendInfo_Envelope(Track, 0, i, 0) -- 0 for volume envelope
          end
          
          -- If SWS method didn't work, try finding existing envelope
          if not envVol then
            envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
          end
          
          -- If envelope doesn't exist, use action to create/show it
          if not envVol then
            -- Use action 41725 to show send volume envelopes for selected track
            -- This will create the envelopes if they don't exist
            r.Main_OnCommand(41725, 0) -- Show/hide track send volume envelope
            
            -- Try to find it again after the action
            if r.BR_GetMediaTrackSendInfo_Envelope then
              envVol = r.BR_GetMediaTrackSendInfo_Envelope(Track, 0, i, 0)
            end
            if not envVol then
              envVol, _ = FindSendEnvelopesForSendIndex(Track, i)
            end
          end
          
          -- Show the envelope if found
          if envVol and envVol ~= 0 then
            -- Verify it's a valid envelope object
            local ok, name = r.GetEnvelopeName(envVol)
            if ok then
              RevealEnvelopeInTCP(envVol)
              r.TrackList_AdjustWindows(false)
            end
          end
        else
          draggingSend = 'Track' .. t .. 'Send' .. i
          if Mods == Alt then
            RemoveSend = true
          end
        end
      end

      if draggingSend == 'Track' .. t .. 'Send' .. i and im.IsMouseDown(ctx, 0) then
        if SendNameClickTrack == Track and SendNameClickIndex == i then
          local mx, my = im.GetMousePos(ctx)
          if not SendNameClickMousePos or math.abs(mx - SendNameClickMousePos.x) > 3 or math.abs(my - SendNameClickMousePos.y) > 3 then
            SendNameClickHadVolumeDrag = true
          end
        end
        -- Begin undo block on first drag frame
        if not (SendDragUndoStarted or {})['Track' .. t .. 'Send' .. i] then
          SendDragUndoStarted = SendDragUndoStarted or {}
          SendDragUndoStarted['Track' .. t .. 'Send' .. i] = true
          r.Undo_BeginBlock()
        end
        if Mods == 0 or Mods == Shift then
          --[[ local DtX, DtY = im.GetMouseDelta(ctx)
          local scale = 0.8
          if Mods == Shift then scale = 0.15 end
          local adj = VAL2DB(volume) - DtY * scale
          local out = SetMinMax(DB2VAL(adj), 0, 4) ]]

          -- ★ glow while dragging the send level ★
          if draggingSend == ('Track'..t..'Send'..i) and im.IsMouseDown(ctx,0) and not (Mods == Alt) then
            local L,T = im.GetItemRectMin(ctx)
            local R,B = im.GetItemRectMax(ctx)
            DrawGlowRect( im.GetWindowDrawList(ctx), L,T,R,B, Change_Clr_A(Clr.Send,0.5), 6, 8 )
          end
          local out = SendVal_Calc_MouseDrag(ctx)
          -- compute delta relative to this row
          local curLin = r.GetTrackSendInfo_Value(Track, 0, i, 'D_VOL')
          local refDB  = VAL2DB(curLin)
          local outDB  = VAL2DB(out)
          local deltaDB = outDB - refDB
          -- set reference absolute
          r.BR_GetSetTrackSendInfo(Track, 0, i, 'D_VOL', true, out)
          -- only do cross-track slot sync if no marquee sends selection
          if not (MarqueeSelection and MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
            AdjustSelectedSendVolumes(Track, 0, i, out)
          end
          -- propagate relative to all marquee-selected sends (type 0)
          if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
            local activeGUID = r.GetTrackGUID(Track)
            for guid, entries in pairs(MarqueeSelection.selectedSends) do
              local tr = GetTrackByGUIDCached(guid)
              if tr and type(entries) == 'table' then
                for _, ent in ipairs(entries) do
                  if ent.type == 0 and ent.idx ~= nil and ent.idx < r.GetTrackNumSends(tr, 0) then
                    if not (guid == activeGUID and ent.idx == i) then
                      local cur = r.GetTrackSendInfo_Value(tr, 0, ent.idx, 'D_VOL')
                      local newDB = VAL2DB(cur) + deltaDB
                      local newLin = SetMinMax(DB2VAL(newDB), 0, 4)
                      r.BR_GetSetTrackSendInfo(tr, 0, ent.idx, 'D_VOL', true, newLin)
                    end
                  end
                end
              end
            end
          end
        end
      end

      if LBtnDC and im.IsItemHovered(ctx) then
        r.Undo_BeginBlock()
        r.SetTrackSendUIVol(Track, i, 1, 0)
        r.BR_GetSetTrackSendInfo(Track, 0, i, 'D_VOL', true, 1)
        r.Undo_EndBlock('Reset send volume', -1)
      end


      -- End undo block only when mouse is released after drag was initiated
      if SendDragUndoStarted and SendDragUndoStarted['Track' .. t .. 'Send' .. i] and im.IsMouseReleased(ctx, 0) then
        r.Undo_EndBlock('Adjust send volume', -1)
        SendDragUndoStarted['Track' .. t .. 'Send' .. i] = nil
      end
      if not im.IsMouseDown(ctx, 0) then
        draggingSend = nil
      end
      
      return volReadoutHovered
    end


    SendFX()

    im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 1, 0.5)
    

    local volReadoutHovered = Volume_Btn()
    
    -- Clear FX button hover state only if neither FX button nor volume readout is hovered
    if Snd.HvrOnFXSend and not fxBtnHovered and not volReadoutHovered then
      Snd.HvrOnFXSend = nil
    end
    
    -- Add pan knob if enabled in settings
    if ShowSendPanKnobs then
      im.SameLine(ctx, nil, 0)
      -- Use animated height for pan knob
      local panKnobH = baseRowH
      local panKnobAlpha = 1.0
      if animProg and animProg < 1 then
        local effective_p = math.max(0, (animProg - 0.25) / 0.75)
        local scale = 1 - (effective_p * effective_p * effective_p)
        panKnobH = math.max(0.0001, baseRowH * scale)
        -- Calculate alpha based on delete animation progress
        panKnobAlpha = math.max(0, 1 - animProg)
      end
      DrawSendPanKnob(ctx, Track, i, 0, panKnobH+2, 'SendPan_' .. TrkID .. '_' .. i, panKnobAlpha)
    end

    -- Check if volume drag happened for this send (mark it so popup won't open)
    -- This check happens after Volume_Btn() so draggingSend is already set
    if draggingSend == 'Track' .. t .. 'Send' .. i and SendNameClickTrack == Track and SendNameClickIndex == i then
      -- Check if there was actual mouse movement (not just a click)
      local mx, my = im.GetMousePos(ctx)
      if SendNameClickMousePos then
        local dx = math.abs(mx - SendNameClickMousePos.x)
        local dy = math.abs(my - SendNameClickMousePos.y)
        if dx > 3 or dy > 3 then  -- Consider it a drag if moved more than 3 pixels
          SendNameClickHadVolumeDrag = true
        end
      else
        -- If draggingSend is set, assume it's a drag
        SendNameClickHadVolumeDrag = true
      end
    end
    
    -- Check for drag every frame while mouse is down (not just when IsItemActive)
    -- Also check if volume button is being dragged
    if im.IsMouseDown(ctx, 0) and SendNameClickTrack == Track and SendNameClickIndex == i then
      local mx, my = im.GetMousePos(ctx)
      local dx = SendNameClickMousePos and math.abs(mx - SendNameClickMousePos.x) or 0
      local dy = SendNameClickMousePos and math.abs(my - SendNameClickMousePos.y) or 0
      -- Check if volume button is being dragged
      if draggingSend == 'Track' .. t .. 'Send' .. i then
        SendNameClickHadVolumeDrag = true
      end
      -- Check mouse movement (any movement > 1 pixel indicates drag)
      if SendNameClickMousePos then
        -- Lower threshold to 1 pixel to catch any movement
        if dx > 1 or dy > 1 then
          SendNameClickHadVolumeDrag = true
        end
      end
    end
    
    -- Open popup only on mouse release if it was a quick click without drag
    if im.IsMouseReleased(ctx, 0) and SendNameClickTrack == Track and SendNameClickIndex == i then
      local frame = (im.GetFrameCount and im.GetFrameCount(ctx)) or nil
      local currentTime = frame or r.time_precise()
      local timeDiff = (frame and (currentTime - SendNameClickTime)) or (currentTime - SendNameClickTime)
      -- Final check: if mouse moved at all from initial click position, it's a drag
      local mx, my = im.GetMousePos(ctx)
      if SendNameClickMousePos then
        local dx = math.abs(mx - SendNameClickMousePos.x)
        local dy = math.abs(my - SendNameClickMousePos.y)
        if dx > 1 or dy > 1 then
          SendNameClickHadVolumeDrag = true
        end
      end
      -- Also check SendBtnDragTime - but only consider it a drag if it exceeds threshold
      -- (SendBtnDragTime > 0 happens even on quick clicks, so we need a threshold)
      -- But only if this matches the clicked send
      if SendNameClickTrack == Track and SendNameClickIndex == i then
        if (SendBtnDragTime or 0) > 5 then
          SendNameClickHadVolumeDrag = true
        end
      end
      -- Check if volume button drag was started (even if mouse was released)
      if SendDragUndoStarted and SendDragUndoStarted['Track' .. t .. 'Send' .. i] then
        SendNameClickHadVolumeDrag = true
      end
      -- Only open popup if: no volume drag happened, no send name drag happened, and mouse was released quickly (within 15 frames or 0.3 seconds)
      local quickClick = (frame and timeDiff <= 15) or (not frame and timeDiff <= 0.3)
      if not SendNameClickHadVolumeDrag and not SendNameClickHadSendNameDrag and quickClick and Mods == 0 then
        OpenedDestTrkWin = Track
        OpenedDestSendWin = i
      end
      -- Reset tracking variables
      SendNameClickTime = nil
      SendNameClickTrack = nil
      SendNameClickIndex = nil
      SendNameClickHadVolumeDrag = false
      SendNameClickHadSendNameDrag = false
      SendNameClickMousePos = nil
      -- Reset SendBtnDragTime after popup check
      if SendBtnDragTime and SendBtnDragTime > 0 then
        SendBtnDragTime = 0
      end
    end

    if RemoveSend then
      HoverSend_Src = nil

      -- trigger animated delete across marquee-selected sends (type 0)
      local didGroup = false
      if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
        local toDelete = {}
        for guid, entries in pairs(MarqueeSelection.selectedSends) do
          local tr = GetTrackByGUIDCached(guid)
          if tr and type(entries) == 'table' then
            for _, ent in ipairs(entries) do
              if ent.type == 0 then
                toDelete[guid] = toDelete[guid] or {}
                table.insert(toDelete[guid], ent.idx)
              end
            end
          end
        end
        for guid, idxs in pairs(toDelete) do
          table.sort(idxs, function(a,b) return a>b end)
          local tr = GetTrackByGUIDCached(guid)
          for _, idxv in ipairs(idxs) do
              if tr and idxv < r.GetTrackNumSends(tr, 0) then
              local dest = r.GetTrackSendInfo_Value(tr, 0, idxv, 'P_DESTTRACK')
              local dGUID = (dest and r.ValidatePtr2(0, dest, 'MediaTrack*')) and r.GetTrackGUID(dest) or ('invalid_send_' .. idxv)
              local k = MakeSendKey(tr, dGUID, idxv)
              if not SendDeleteAnim[k] then SendDeleteAnim[k] = { progress = 0, track = tr, index = idxv, destGUID = dGUID, delay = 1 } end
            end
          end
        end
        didGroup = next(toDelete) ~= nil
      end
      if not didGroup then
        -- animate only this send
        if not rowDeleteAnim then
          SendDeleteAnim[sendKey] = { progress = 0, track = Track, index = i, destGUID = DestTrkGUID, container = Snd.Container, delay = 1 }
          rowDeleteAnim = SendDeleteAnim[sendKey]
          -- Clear any create animation state
          SendCreateAnim[sendKey] = nil

          -- Find corresponding receive on destination track and animate it
          if DestTrk and r.ValidatePtr2(0, DestTrk, 'MediaTrack*') then
            -- Count how many sends from Track to DestTrk exist before this send index
            -- This determines which receive index corresponds to this send
            local sendCountBeforeThis = 0
            for si = 0, i - 1 do
              local dest = r.GetTrackSendInfo_Value(Track, 0, si, 'P_DESTTRACK')
              if dest == DestTrk then
                sendCountBeforeThis = sendCountBeforeThis + 1
              end
            end
            
            -- Find the receive at the corresponding position
            local receiveIndex = -1
            local receivesFromThisTrack = 0
            local numRecvs = r.GetTrackNumSends(DestTrk, -1)
            for ri = 0, numRecvs - 1 do
              local src = r.GetTrackSendInfo_Value(DestTrk, -1, ri, 'P_SRCTRACK')
              if src == Track then
                if receivesFromThisTrack == sendCountBeforeThis then
                  receiveIndex = ri
                  break
                end
                receivesFromThisTrack = receivesFromThisTrack + 1
              end
            end
            
            if receiveIndex >= 0 then
              local srcGUID = r.GetTrackGUID(Track)
              local rKey = MakeRecvKey(DestTrk, srcGUID, receiveIndex)
              if not ReceiveDeleteAnim[rKey] then
                ReceiveDeleteAnim[rKey] = { progress = 0, track = DestTrk, index = receiveIndex, srcGUID = rKey, delay = 1 }
                -- Clear any create animation state
                ReceiveCreateAnim[rKey] = nil
              end
            end
          end
        end
      end
      -- start hover-block immediately on delete trigger so hide btn won't appear until move ≥20px
      do
        local mx, my = im.GetMousePos(ctx)
        HoverBlockAfterDelete = { active = true, startX = mx, startY = my }
      end
      RemoveSend = nil
    end

    -- draw content-fade and red fill overlay for active delete animation and advance it; queue actual deletion at completion
    -- Note: alpha style var is kept active so content fades to transparent
    do
      local anim = SendDeleteAnim[sendKey]
      if anim and (anim.progress or 0) < 1 then
        if anim.delay then
          anim.delay = nil
          SendDeleteAnim[sendKey] = anim
        else
          local done = AdvanceDeleteAnimAndOverlay(ctx, anim, rowMinX, rowMinY, rowMaxX, rowCurH, baseRowH)
          if done and not anim.queued then
             anim.queued = true
             local tg = r.GetTrackGUID(Track)
             PendingSendRemovals[tg] = PendingSendRemovals[tg] or {}
             table.insert(PendingSendRemovals[tg], { idx = i, container = Snd and Snd.Container, key = sendKey, destGUID = anim.destGUID })
          end
        end
      end
    end

    -- Pop alpha style var at end of iteration (after overlay is drawn) so content fades to transparent
    if pushedRowAlpha then im.PopStyleVar(ctx) end

    if Bypass == 1 then
      im.DrawList_AddRectFilled(WDL, BP.L, BP.T, BP.L + Send_W, BP.B, 0x000000aa)
    end

    if Dest_Valid and OpenedDestSendWin == i and OpenedDestTrkWin == Track then
      if OpenDestTrackPopup(ctx,DestTrk, t) then 
        OpenedDestSendWin = i 
        OpenedDestTrkWin = Track
      end
      
    end
    
  end
  im.PopStyleColor(ctx, 2) --- pop send buttons color
end

function ReceiveBtn(ctx, Track, t, i, BtnSize)
  local rv, RecvName = r.GetTrackReceiveName(Track, i)
  local Bypass = r.GetTrackSendInfo_Value(Track, -1, i, 'B_MUTE')
  local BP = {}
  local RemoveRecv
  local SrcTrack = r.GetTrackSendInfo_Value(Track, -1, i, 'P_SRCTRACK')
  local HoverEyes
  local BtnSizeOffset = 0
  local Src_Hidden
  -- Global animation/hover-block gating
  local AnyAnimActive = false
  do
    if SendDeleteAnim then
      for _, a in pairs(SendDeleteAnim) do if a and (a.progress or 0) < 1 then AnyAnimActive = true break end end
    end
    if not AnyAnimActive and ReceiveDeleteAnim then
      for _, a in pairs(ReceiveDeleteAnim) do if a and (a.progress or 0) < 1 then AnyAnimActive = true break end end
    end
  end
  local HoverBlocked = false
  do
    local hb = HoverBlockAfterDelete
    if hb and hb.active then
      local mx, my = im.GetMousePos(ctx)
      if mx and my and hb.startX and hb.startY then
        local dx = math.abs(mx - hb.startX)
        local dy = math.abs(my - hb.startY)
        if dx >= 20 or dy >= 20 then HoverBlockAfterDelete.active = false else HoverBlocked = true end
      end
    end
  end
  -- cache row start for full-width overlay later
  local rRowMinX_cached, rRowMinY_cached
    Gather_Info_For_Patch_Line = function( UseRectMin )
    if UseRectMin then
      PatchX, PatchY = im.GetItemRectMin(ctx)
    else
      PatchX, PatchY = im.GetCursorScreenPos(ctx)
    end
    HoverRecv_Dest = r.GetTrackSendInfo_Value(Track, -1, i, 'P_SRCTRACK')
    HoverRecv_Src = Track
    HoverRecv_Dest_Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_DSTCHAN')
    HoverRecv_Src_Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_SRCCHAN')
  end
  --- to show patch
  if HoverRecv == i .. TrkID then
    Gather_Info_For_Patch_Line()
  end
  local function Draw_Patch_Lines_SENDS()
    if not PatchX or not PatchY then return end
    if HoverSend_Src == SrcTrack and SrcTrack and Track == HoverSend_Dest then
      -- Find the send on SrcTrack that sends to Track (this receive track)
      local numSends = r.GetTrackNumSends(SrcTrack, 0)
      for sendIdx = 0, numSends - 1 do
        local destTrk = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'P_DESTTRACK')
        if destTrk == Track then
          local Chan = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'I_DSTCHAN')
          local SrcChan = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'I_SRCCHAN')

          if HoverSend_Dest_Chan == Chan and HoverSend_Src_Chan == SrcChan then 
            RecvTrk = r.GetTrack(0, t)
            local rv, Name = r.GetTrackName(RecvTrk)
            local EndX, EndY = im.GetCursorScreenPos(ctx)
            local L = PatchX
            local H = SendsLineHeight/2
            
            -- Draw glow rect at source (send) position - PatchX is left edge of volume drag area
            local glowLeft = PatchX - (Send_W or 150) + (SendValSize or 40)  -- Approximate send row start
            DrawGlowRect(WDL, glowLeft, PatchY - H, PatchX + (SendValSize or 40), PatchY + H, Clr.Send, 12)

            local L = L - 5
            local T , B = PatchY + H  , EndY + H
            -- Use repeating arrow chevrons to indicate direction instead of plain line
            -- Draw a vertical dotted arrow line (chevron style) from source (T) to destination (B)
            DrawBentPatchLine(FDL, L, T, B, 10, (Clr and Clr.PatchLine) or 0xffffffff, true)        -- colour
            break -- Found matching send, no need to continue
          end
        end
      end
    end
  end
  
  -- Draw patch line for receives when hovering (shows connection to source track)
  local function Draw_Patch_Lines_RECVS_Hover()
    if not PatchX or not PatchY then return end
    if HoverRecv == i .. TrkID and HoverRecv_Src == Track and HoverRecv_Dest == SrcTrack and SrcTrack then
      -- Find the send on SrcTrack that sends to Track (this receive track)
      local numSends = r.GetTrackNumSends(SrcTrack, 0)
      for sendIdx = 0, numSends - 1 do
        local destTrk = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'P_DESTTRACK')
        if destTrk == Track then
          local Chan = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'I_DSTCHAN')
          local SrcChan = r.GetTrackSendInfo_Value(SrcTrack, 0, sendIdx, 'I_SRCCHAN')

          if HoverRecv_Dest_Chan == Chan and HoverRecv_Src_Chan == SrcChan then
            -- Calculate end position at source track's send row
            local srcTrackGUID = r.GetTrackGUID(SrcTrack)
            local srcSendsRect = (Trk and Trk[srcTrackGUID] and Trk[srcTrackGUID].SendsChildRect)
            local EndX, EndY
            if srcSendsRect then
              -- Calculate send row Y position: child top + (send index * row height) + half row height
              local rowH = (SendsLineHeight or 14)
              local sendRowY = srcSendsRect.T + (sendIdx * rowH) + (rowH / 2)
              -- X position: left edge of volume drag area (similar to how we set PatchX for sends)
              EndX = srcSendsRect.L + (Send_W or 150) - (SendValSize or 40)  -- Approximate volume drag left edge
              EndY = sendRowY
            else
              -- Fallback to cursor position if source track's sends rect not available
              EndX, EndY = im.GetCursorScreenPos(ctx)
            end
            
            local L = PatchX
            local H = SendsLineHeight/2
            
            -- Use cached row position or fallback to PatchX
            local glowLeft = (rRowMinX_cached and rRowMinX_cached) or PatchX
            DrawGlowRect(WDL, glowLeft, PatchY, PatchX + Send_W - 15, PatchY + SendsLineHeight, Clr.ReceiveSend, 12)
            
            local L = L - 5
            local T, B = PatchY + H, EndY
            -- Draw patch line from receive to source track
            DrawBentPatchLine(FDL, L, T, B, 10, (Clr and Clr.PatchLine) or 0xffffffff, false)
            break -- Found matching send, no need to continue
          end
        end
      end
    end
  end
  Draw_Patch_Lines_RECVS_Hover()

  Draw_Patch_Lines_SENDS()
  -- show indication if receives are not on channel 1 and 2 
  local Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_DSTCHAN')
  if Chan > 0 then 
    im.Button(ctx,' '..math.ceil(Chan+1)..'-'..math.ceil(Chan+2)..' ')
    local w, h = HighlightItem(0x00000000,WDL, Clr.Attention)
    BtnSizeOffset = BtnSizeOffset - w
    SL()
  end
  -- if Source Track is hidden (suppress during animation and hover-block)
  if SrcTrack and  r.ValidatePtr2(0, SrcTrack, 'MediaTrack*') then 
    if r.GetMediaTrackInfo_Value(SrcTrack, 'B_SHOWINTCP') == 0 and not AnyAnimActive and not HoverBlocked and Mods ~= Alt then
      Src_Hidden = true
      local btnH = math.min(HideBtnSz, SendsLineHeight)
      if im.ImageButton(ctx, '##HideBtn_recv_hidden_'..(i or 0)..'_'..(TrkID or ''), Img.Hide, HideBtnSz, btnH, nil, nil, nil, nil, nil, Clr.Attention) then
        r.SetMediaTrackInfo_Value(SrcTrack, 'B_SHOWINTCP', 1)
        RefreshUI_HideTrack()
      end
      if im.IsItemHovered(ctx) then
        SetHelpHint('LMB = Show Hidden Track')
      end
      SL()
      BtnSizeOffset = -HideBtnSz
    end
  end
  volume = r.GetTrackSendInfo_Value(Track, -1, i, 'D_VOL')

  local function if_hover()
    -- if hovering Receive, show Hide Track icon
    if HoverRecv == i .. TrkID and not Src_Hidden and not DraggingRecvVol and not AnyAnimActive and not HoverBlocked and Mods ~= Alt then

      if im.ImageButton(ctx, '##HideBtn_recv_hover_'..(i or 0)..'_'..(TrkID or ''), Img.Show, HideBtnSz, HideBtnSz, nil, nil, nil, nil, nil, Clr.Attention) then
        r.SetMediaTrackInfo_Value(SrcTrack, 'B_SHOWINTCP', 0)
        RefreshUI_HideTrack()
      end
      if im.IsItemHovered(ctx) then
        HoverEyes = true
        SetHelpHint('LMB = Hide Track')
      end
      SL()
      BtnSizeOffset =BtnSizeOffset -HideBtnSz
    end
  end


  if_hover()

  -- Declare pushedRecvAlpha outside the if block so it's accessible at the end
  local pushedRecvAlpha
  
  if RecvName ~= '' then
    im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 0.1, 0.5)
    do
      local base = Clr.ReceiveSend
      local hvr  = Clr.ReceiveSendHvr or (LightenColorU32 and LightenColorU32(base, 0.15)) or base
      im.PushStyleColor(ctx, im.Col_Button, base)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, hvr)
    end
  -- compute the full receive row rect from cursor and known widths
  local rRowMinX, rRowMinY = im.GetCursorScreenPos(ctx)
  local rRowMaxX = rRowMinX + (Send_W or 0)
  local rRowMaxY = rRowMinY + (SendsLineHeight or 14)
  -- compute current animated height for this receive row
  local rBaseH = (SendsLineHeight or 14)
  local rKey do
    local srcGUID = (SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*')) and r.GetTrackGUID(SrcTrack) or ('invalid_recv_' .. i)
    rKey = MakeRecvKey(Track, srcGUID, i)
  end
  local rAnim = ReceiveDeleteAnim and ReceiveDeleteAnim[rKey]
  local rCreateAnim = ReceiveCreateAnim and ReceiveCreateAnim[rKey]
  local rCurH = rBaseH
  if rAnim and (rAnim.progress or 0) < 1 then
    local p = rAnim.progress or 0
    local effective_p = math.max(0, (p - 0.25) / 0.75)
    local scale = 1 - (effective_p * effective_p * effective_p)
    rCurH = math.max(0.0001, rBaseH * scale)
    -- Push alpha style var to fade content to transparent
    local recvAlpha = math.max(0, 1 - p)
    im.PushStyleVar(ctx, im.StyleVar_Alpha, recvAlpha)
    pushedRecvAlpha = true
  end
  -- cache row start so we can draw full-width overlay even after more items
  rRowMinX_cached, rRowMinY_cached = rRowMinX, rRowMinY
  -- draw name button with current height
  local RecvNameClick = im.Button(ctx, RecvName .. '##'..i, BtnSize + BtnSizeOffset, rCurH)
  
  -- Apply creation animation (flash/fade-in)
  if rCreateAnim and (rCreateAnim.progress or 0) < 1 then
    local L = rRowMinX
    local T = rRowMinY
    local R = rRowMinX + (Send_W or 0)
    local B = rRowMinY + rCurH
    local dl = im.GetWindowDrawList(ctx)
    
    -- Animation: Flash white/bright and fade out
    local animAlpha = 0.6 * (1 - (rCreateAnim.progress or 0))
    local col = im.ColorConvertDouble4ToU32(1, 1, 1, animAlpha)
    
    im.DrawList_AddRectFilled(dl, L, T, R, B, col, im.GetStyleVar(ctx, im.StyleVar_FrameRounding))
    
    rCreateAnim.progress = (rCreateAnim.progress or 0) + SEND_CREATE_ANIM_STEP
    if rCreateAnim.progress >= 1 then
      ReceiveCreateAnim[rKey] = nil
    end
  end
  if im.IsItemHovered(ctx) then
    SetHelpHint('LMB = Open Source Track', 'Alt+LMB = Remove Receive')
  end
  -- Clicking receive name prepares to open source track popup (only on quick click release)
  if RecvNameClick then
    if Mods == 0 and SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*') then
      local frame = (im.GetFrameCount and im.GetFrameCount(ctx)) or nil
      RecvNameClickTime = frame or r.time_precise()
      RecvNameClickTrack = Track
      RecvNameClickIndex = i
      RecvNameClickHadVolumeDrag = false
      local mx, my = im.GetMousePos(ctx)
      RecvNameClickMousePos = { x = mx, y = my }
      RecvNameClickSrcTrack = SrcTrack
      local rectMaxX, rectMaxY = im.GetItemRectMax(ctx)
      RecvNameClickRectMax = { x = rectMaxX, y = rectMaxY }
      RecvNameClickRectMinY = select(2, im.GetItemRectMin(ctx))
    end
  end
  -- Marquee sends selection registration for receive rows (type -1)
  do
    if MarqueeSelection and MarqueeSelection.isActive and MarqueeSelection.mode == 'sends' then
      -- Only check marquee selection for visible items to prevent selecting hidden receives
      -- when tracks are collapsed/zoomed and coordinates overlap
      if im.IsItemVisible(ctx) then
        local minX, minY, maxX, maxY = rRowMinX, rRowMinY, rRowMaxX, rRowMaxY
        if IsRectIntersectingMarquee(minX, minY, maxX, maxY) then
          local trGUID = r.GetTrackGUID(Track)
          MarqueeSelection.selectedSends[trGUID] = MarqueeSelection.selectedSends[trGUID] or {}
          local exists = false
          for _, ent in ipairs(MarqueeSelection.selectedSends[trGUID]) do
            if ent.type == -1 and ent.idx == i then exists = true break end
          end
          if not exists then table.insert(MarqueeSelection.selectedSends[trGUID], { type = -1, idx = i }) end
        elseif not MarqueeSelection.additive then
          local trGUID = r.GetTrackGUID(Track)
          local arr = MarqueeSelection.selectedSends[trGUID]
          if arr then
            for k = #arr, 1, -1 do
              local ent = arr[k]
              if ent.type == -1 and ent.idx == i then table.remove(arr, k) end
            end
          end
        end
      elseif not MarqueeSelection.additive then
        -- If item is not visible and not in additive mode, remove from selection
        local trGUID = r.GetTrackGUID(Track)
        local arr = MarqueeSelection.selectedSends[trGUID]
        if arr then
          for k = #arr, 1, -1 do
            local ent = arr[k]
            if ent.type == -1 and ent.idx == i then table.remove(arr, k) end
          end
        end
      end
    end
  end
  if Mods == Alt and im.IsItemHovered(ctx) then
      -- Use current receive row rect to prevent offset
      local L = rRowMinX
      local T = rRowMinY
      local R = rRowMinX + (Send_W or (rRowMaxX - rRowMinX))
      -- rCurH may not be defined here if not animating yet; compute base height
      local baseH = (SendsLineHeight or 14)
      local B = rRowMinY + (rCurH or baseH) + 2
      -- Draw X indicator and highlight
      DrawXIndicator(ctx, 12, Clr.Danger)
      im.DrawList_AddRect(WDL, L, T, R, B, 0x771111ff, 2)
      im.DrawList_AddRectFilled(WDL, L, T, R, B, 0x00000044)

    end

    ExpandTrack(ctx, Track)

    im.PopStyleColor(ctx, 2)
    im.PopStyleVar(ctx)
  end

  -- If this receive row is selected, mark interacting flag so selection isn't cleared on click elsewhere
  do
    if MarqueeSelection and MarqueeSelection.selectedSends then
      local trGUID = r.GetTrackGUID(Track)
      local arr = MarqueeSelection.selectedSends[trGUID]
      if arr then
        for _, ent in ipairs(arr) do
          if ent.type == -1 and ent.idx == i then
            if im.IsItemHovered(ctx) or im.IsItemActive(ctx) then
              InteractingWithSelectedSends = true
            end
            break
          end
        end
      end
    end
  end

  if im.IsItemActive(ctx) then 
    -- Check if this is the receive that was clicked and detect drag
    if RecvNameClickTrack == Track and RecvNameClickIndex == i then
      local mx, my = im.GetMousePos(ctx)
      if RecvNameClickMousePos then
        local dx = math.abs(mx - RecvNameClickMousePos.x)
        local dy = math.abs(my - RecvNameClickMousePos.y)
        -- Only consider it a drag if there's actual mouse movement (not just RecvBtnDragTime > 0, which happens even on quick clicks)
        -- OR if RecvBtnDragTime exceeds a threshold (e.g., > 5 frames) indicating a held drag
        if dx > 1 or dy > 1 or (RecvBtnDragTime or 0) > 5 then
          -- This is a volume drag (dragging on receive name area adjusts volume)
          RecvNameClickHadVolumeDrag = true
        end
      else
        -- No initial position - this shouldn't happen if click was recorded
        -- Only consider it a drag if RecvBtnDragTime exceeds threshold (indicating held drag)
        if (RecvBtnDragTime or 0) > 5 then
          RecvNameClickHadVolumeDrag = true
        end
      end
    end
    RecvBtnDragTime = (RecvBtnDragTime or 0) + 1
    -- Begin undo block on first drag frame
    if DraggingRecvVol ~= i then
      if DraggingRecvVol == nil then
        r.Undo_BeginBlock()
      end
      DraggingRecvVol = i
    end
    --SendBtnDragTime = (SendBtnDragTime or 0) +1
    local out = SendVal_Calc_MouseDrag(ctx)
    -- compute relative delta
    local curLin = r.GetTrackSendInfo_Value(Track, -1, i, 'D_VOL')
    local refDB  = VAL2DB(curLin)
    local outDB  = VAL2DB(out)
    local deltaDB = outDB - refDB
    -- set this reference absolute
    r.BR_GetSetTrackSendInfo(Track, -1, i, 'D_VOL', true, out)
    Gather_Info_For_Patch_Line(true)
    if not (MarqueeSelection and MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
      AdjustSelectedSendVolumes(Track, -1, i, out)
    end
    -- propagate relative to marquee-selected receives
    if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
      local activeGUID = r.GetTrackGUID(Track)
      for guid, entries in pairs(MarqueeSelection.selectedSends) do
        local tr = GetTrackByGUIDCached(guid)
        if tr and type(entries) == 'table' then
          for _, ent in ipairs(entries) do
            if ent.type == -1 and ent.idx ~= nil and ent.idx < r.GetTrackNumSends(tr, -1) then
              if not (guid == activeGUID and ent.idx == i) then
                local cur = r.GetTrackSendInfo_Value(tr, -1, ent.idx, 'D_VOL')
                local newDB = VAL2DB(cur) + deltaDB
                local newLin = SetMinMax(DB2VAL(newDB), 0, 4)
                r.BR_GetSetTrackSendInfo(tr, -1, ent.idx, 'D_VOL', true, newLin)
              end
            end
          end
        end
      end
    end
  end
  -- End undo block only when mouse is released after drag was initiated
  if DraggingRecvVol == i and im.IsMouseReleased(ctx, 0) then
    r.Undo_EndBlock('Adjust receive volume', -1)
    DraggingRecvVol = nil
  end

  -- Capture position before VolumeBar for patch line (left edge of volume drag area)
  local recvVolDragX, recvVolDragY = im.GetCursorScreenPos(ctx)
  --im.InvisibleButton(ctx, '##RecvVolDrag_' .. i .. '_' .. TrkID, BtnSize, rCurH or (SendsLineHeight or 14))
  VolumeBar(ctx,BtnSize,i,-1, rCurH)
  -- If the receive name was clicked and the user is dragging within the volume area, treat it as a drag (prevent popup)
  if im.IsMouseDown(ctx, 0) and RecvNameClickTrack == Track and RecvNameClickIndex == i then
    local mx, my = im.GetMousePos(ctx)
    if RecvNameClickMousePos then
      local dx = math.abs(mx - RecvNameClickMousePos.x)
      local dy = math.abs(my - RecvNameClickMousePos.y)
      -- Lower threshold to 1 pixel to match sends
      if dx > 1 or dy > 1 then
        RecvNameClickHadVolumeDrag = true
      end
    else
      -- Only mark as drag if RecvBtnDragTime exceeds threshold
      if (RecvBtnDragTime or 0) > 5 then
        RecvNameClickHadVolumeDrag = true
      end
    end
  end
  -- Check if right-click happened on volume drag area and start marquee selection
  if MarqueeSelection and im.IsItemClicked(ctx, 1) and not MarqueeSelection.isActive then
    local mx, my = im.GetMousePos(ctx)
    MarqueeSelection.initialMouseX = mx
    MarqueeSelection.initialMouseY = my
    MarqueeSelection.startingOnVolDrag = true
    MarqueeSelection.hasDragged = true
    StartMarqueeSelection(ctx)
  end
  -- Draw selection highlight for receives if selected via marquee
  do
    local selected = false
    if MarqueeSelection and MarqueeSelection.selectedSends then
      local trGUID = r.GetTrackGUID(Track)
      local arr = MarqueeSelection.selectedSends[trGUID]
      if arr then
        for _, ent in ipairs(arr) do
          if ent.type == -1 and ent.idx == i then selected = true break end
        end
      end
    end
    if selected then
      local dl = im.GetWindowDrawList(ctx)
      local rRowMinX, rRowMinY = im.GetItemRectMin(ctx)
      local rRowMaxX, rRowMaxY = im.GetItemRectMax(ctx)
      im.DrawList_AddRectFilled(dl, rRowMinX, rRowMinY, rRowMaxX, rRowMaxY, Change_Clr_A(Clr.ReceiveSend or 0x2C2F9044, 0.25))
      im.DrawList_AddRect(dl, rRowMinX, rRowMinY, rRowMaxX, rRowMaxY, Change_Clr_A(Clr.ReceiveSend or 0x2C2F9044, 0.8))
    end
  end

  im.SameLine(ctx, nil, 1)

  if (im.IsItemHovered(ctx) or HoverEyes) and not AnyAnimActive and not HoverBlocked then
    HoverRecv = i .. TrkID
    SENDS_HOVER_THIS_FRAME = true
    HoverRecv_Index = i
    HoverRecv_Dest_Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_DSTCHAN')
    HoverRecv_Src_Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_SRCCHAN')
    HoverRecv_Src = Track  -- The receive track
    HoverRecv_Dest = SrcTrack  -- The source track (where the send originates)
    -- Gather patch line info for receives - use left edge of volume drag area
    -- Use cached row position or calculate from volume drag Y position
    local recvRowY = (rRowMinY_cached and rRowMinY_cached) or (recvVolDragY - (SendsLineHeight or 14) / 2)
    PatchX, PatchY = recvVolDragX, recvRowY + (SendsLineHeight or 14) / 2
  
  else
    if HoverRecv == i .. TrkID then
      HoverRecv = nil
      HoverRecv_Dest = nil
    end
  end


  im.SetNextItemWidth(ctx, SendValSize)
  -- Check for drag every frame while mouse is down (not just when IsItemActive)
  if im.IsMouseDown(ctx, 0) and RecvNameClickTrack == Track and RecvNameClickIndex == i then
    local mx, my = im.GetMousePos(ctx)
    local dx = RecvNameClickMousePos and math.abs(mx - RecvNameClickMousePos.x) or 0
    local dy = RecvNameClickMousePos and math.abs(my - RecvNameClickMousePos.y) or 0
    -- Check if volume button is being dragged
    if DraggingRecvVol == i then
      RecvNameClickHadVolumeDrag = true
    end
    -- Check mouse movement (any movement > 1 pixel indicates drag)
    if RecvNameClickMousePos then
      -- Lower threshold to 1 pixel to match sends
      if dx > 1 or dy > 1 then
        RecvNameClickHadVolumeDrag = true
      end
    end
  end
  
  -- Open source track popup only when click was quick and without volume drag
  if im.IsMouseReleased(ctx, 0) and RecvNameClickTrack == Track and RecvNameClickIndex == i then
    local frame = (im.GetFrameCount and im.GetFrameCount(ctx)) or nil
    local currentTime = frame or r.time_precise()
    local timeDiff = (frame and (currentTime - RecvNameClickTime)) or (currentTime - RecvNameClickTime)
    -- Final check: if mouse moved at all from initial click position, it's a drag
    local mx, my = im.GetMousePos(ctx)
    if RecvNameClickMousePos then
      local dx = math.abs(mx - RecvNameClickMousePos.x)
      local dy = math.abs(my - RecvNameClickMousePos.y)
      if dx > 1 or dy > 1 then
        RecvNameClickHadVolumeDrag = true
      end
    end
    -- Also check RecvBtnDragTime - but only consider it a drag if it exceeds threshold
    -- (RecvBtnDragTime > 0 happens even on quick clicks, so we need a threshold)
    if (RecvBtnDragTime or 0) > 5 then
      RecvNameClickHadVolumeDrag = true
    end
    -- Also check DraggingRecvVol - if set and RecvBtnDragTime exceeds threshold, volume was adjusted
    if DraggingRecvVol == i and (RecvBtnDragTime or 0) > 5 then
      RecvNameClickHadVolumeDrag = true
    end
    local quickClick = (frame and timeDiff <= 15) or (not frame and timeDiff <= 0.3)
    if quickClick and not RecvNameClickHadVolumeDrag and RecvNameClickSrcTrack and r.ValidatePtr2(0, RecvNameClickSrcTrack, 'MediaTrack*') then
      OpenedSrcTrkWin = RecvNameClickSrcTrack
      OpenedSrcSendWin = i
      if RecvNameClickRectMax then
        OpenedSrcTrkWin_X = RecvNameClickRectMax.x
        OpenedSrcTrkWin_Y = RecvNameClickRectMinY or RecvNameClickRectMax.y
      else
        OpenedSrcTrkWin_X = nil
        OpenedSrcTrkWin_Y = RecvNameClickRectMinY
      end
    end
    RecvNameClickTime = nil
    RecvNameClickTrack = nil
    RecvNameClickIndex = nil
    RecvNameClickHadVolumeDrag = false
    RecvNameClickMousePos = nil
    RecvNameClickSrcTrack = nil
    RecvNameClickRectMax = nil
    RecvNameClickRectMinY = nil
    -- Reset RecvBtnDragTime after popup check
    if RecvBtnDragTime and RecvBtnDragTime > 0 then
      RecvBtnDragTime = 0
    end
  end

  if Bypass == 1 then
    BP.L, BP.T = im.GetItemRectMin(ctx)
    BP.R, BP.B = im.GetItemRectMax(ctx)
  end
  if im.IsItemClicked(ctx) then
    if Mods == Shift then
      if Bypass == 0 then
        r.SetTrackSendInfo_Value(Track, -1, i, 'B_MUTE', 1)
      else
        r.SetTrackSendInfo_Value(Track, -1, i, 'B_MUTE', 0)
      end
      -- propagate bypass toggle to marquee-selected receives (type -1)
      if MarqueeSelection and (MarqueeSelection.selectedSends and next(MarqueeSelection.selectedSends)) then
        local target = r.GetTrackSendInfo_Value(Track, -1, i, 'B_MUTE')
        for guid, entries in pairs(MarqueeSelection.selectedSends) do
          local tr = GetTrackByGUIDCached(guid)
          if tr and type(entries) == 'table' then
            for _, ent in ipairs(entries) do
              if ent.type == -1 and ent.idx ~= nil and ent.idx < r.GetTrackNumSends(tr, -1) then
                r.SetTrackSendInfo_Value(tr, -1, ent.idx, 'B_MUTE', target)
              end
            end
          end
        end
      end
    elseif Mods == Alt then
      RemoveRecv = true
    end
  end

  -- Right-click on receive: select source track and scroll to it in TCP
  if im.IsItemClicked(ctx, 1) and not MarqueeSelection.isActive and not MarqueeSelection.hasDragged then -- Right mouse button, not during marquee and not a drag
    local targetTrack = nil
    local trackName = ""
    
    -- For receives, select the source track
    if SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*') then
      targetTrack = SrcTrack
      local _, srcName = r.GetTrackName(SrcTrack)
      trackName = srcName or "Unknown Track"
    end
    
    if targetTrack then
      -- Clear current selection and select the target track
      r.SetOnlyTrackSelected(targetTrack)
      
      -- Scroll to the track in TCP with extra pixels for better visibility
      r.CF_SetTcpScroll(targetTrack, -50)
    end
  end

    if rcvTrk ~= 0.0 then
    local volume = r.GetTrackSendInfo_Value(Track, -1, i, 'D_VOL')

    local ShownVol
    if volume < 0.0001 then
      ShownVol = '-inf'
    else
      ShownVol = ('%.1f'):format(VAL2DB(volume))
    end

    local CurX, CurY = im.GetCursorScreenPos(ctx)
    
    im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 1, 1)
    -- compute and apply current row height if animating
    local rMinX, rMinY = rRowMinX or im.GetItemRectMin(ctx)
    local rBaseH = (SendsLineHeight or 14)
    
    local rKey
    do
      local srcGUID = (SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*')) and r.GetTrackGUID(SrcTrack) or ('invalid_recv_' .. i)
      rKey = MakeRecvKey(Track, srcGUID, i)
    end
    local rAnim = ReceiveDeleteAnim and ReceiveDeleteAnim[rKey]
    local rCurH = rBaseH
    if rAnim and (rAnim.progress or 0) < 1 then
      local p = rAnim.progress or 0
      local effective_p = math.max(0, (p - 0.25) / 0.75)
      local scale = 1 - (effective_p * effective_p * effective_p)
      rCurH = math.max(0.0001, rBaseH * scale)
    end
    
    -- Calculate pan knob offset to prevent overlap with volume readout (using animated height)
    local recvPanKnobOffset = 0
    if ShowSendPanKnobs then
      local effectiveHeight = rCurH + 2
      local knobRadius = (effectiveHeight * 0.5) - 0.5
      if knobRadius < 4 then knobRadius = 4 end
      local knobSize = knobRadius * 2
      recvPanKnobOffset = knobSize + 2  -- Same offset as volume readout
    end
    
    -- Calculate receive volume button width - reduce if pan knobs are enabled
    local recvVolBtnWidth = SendValSize
    if ShowSendPanKnobs then
      -- Calculate knob size the same way DrawSendPanKnob does, using animated height
      local effectiveHeight = rCurH + 2
      local knobRadius = (effectiveHeight * 0.5) - 0.5
      if knobRadius < 4 then knobRadius = 4 end
      local knobSize = knobRadius * 2
      recvVolBtnWidth = recvVolBtnWidth - knobSize - 4  -- Subtract knob size plus extra spacing to prevent overlap
    end
    
    -- Add 3px to match volume drag height
    local recvVolReadoutH = rCurH 
    im.Button(ctx, ShownVol .. '##Recv', recvVolBtnWidth, recvVolReadoutH)
    if im.IsItemHovered(ctx) then
      SetHelpHint('LMB Drag = Adjust Receive Volume', 'Shift+Drag = Fine Adjustment', 'Alt+LMB = Remove Receive')
    end
    im.PopStyleVar(ctx)
    
    -- Add pan knob at the rightmost position if enabled in settings
    if ShowSendPanKnobs then
      im.SameLine(ctx, nil, 2)
      -- Use animated height for pan knob and calculate alpha for delete animation
      local panKnobAlpha = 1.0
      if rAnim and (rAnim.progress or 0) < 1 then
        panKnobAlpha = math.max(0, 1 - (rAnim.progress or 0))
      end
      DrawSendPanKnob(ctx, Track, i, -1, rCurH+2, 'RecvPan_' .. TrkID .. '_' .. i, panKnobAlpha)
    end


    local Chan = r.GetTrackSendInfo_Value(Track, -1, i, 'I_SRCCHAN')
    if not DraggingVol then 
      if Chan > 0  then 
        local str = ' '..math.ceil(Chan+1)..'-'..math.ceil(Chan+2)..' '
        local w ,h = im.CalcTextSize(ctx, str)
        local CurX = CurX - recvPanKnobOffset  -- Offset by pan knob width
        local CurY=CurY+1
        -- compress badge vertically to current animated row height
        local badgeH = h
        if rAnim and (rAnim.progress or 0) < 1 then
          local p = rAnim.progress or 0
          local effective_p = math.max(0, (p - 0.25) / 0.75)
          local scale = 1 - (effective_p * effective_p * effective_p)
          badgeH = math.max(0.0001, h * scale)
        else
          badgeH = math.min(h, rCurH)  -- Use smaller of text height or row height
        end
        im.DrawList_AddRectFilled(WDL, CurX  , CurY, CurX + w , CurY + badgeH, Clr.ChanBadgeBg)
        im.DrawList_AddText(WDL,  CurX  , CurY ,Clr.ChanBadgeText,str )
        im.DrawList_AddRect(WDL, CurX  , CurY, CurX + w , CurY + badgeH, Clr.ChanBadgeText)

        --local w, h = HighlightItem(0x00000000,WDL, 0xffffffff)
        BtnSizeOffset = BtnSizeOffset - w

      else
        -- vertically squash receive icon to match current row height (add 3px to match volume drag height)
        local scaleY = math.max(0.0001, rCurH / rBaseH)
        local iconH = rBaseH + 3
        im.DrawList_AddImage(WDL, Img.Recv, CurX - recvPanKnobOffset, CurY, CurX - recvPanKnobOffset + iconH, CurY + iconH * scaleY)
      end
    end


    if im.IsItemClicked(ctx) then
      draggingRecv = 'Track' .. t .. 'Recv' .. i
      if Mods == Alt then
        RemoveRecv = true
      end
    end


    if draggingRecv == 'Track' .. t .. 'Recv' .. i and im.IsMouseDown(ctx, 0) then
      if RecvNameClickTrack == Track and RecvNameClickIndex == i then
        local mx, my = im.GetMousePos(ctx)
        if not RecvNameClickMousePos or math.abs(mx - RecvNameClickMousePos.x) > 3 or math.abs(my - RecvNameClickMousePos.y) > 3 then
          RecvNameClickHadVolumeDrag = true
        end
      end
      -- Begin undo block on first drag frame
      if not (RecvDragUndoStarted or {})['Track' .. t .. 'Recv' .. i] then
        RecvDragUndoStarted = RecvDragUndoStarted or {}
        RecvDragUndoStarted['Track' .. t .. 'Recv' .. i] = true
        r.Undo_BeginBlock()
      end
      if Mods == 0 or Mods == Shift then
        out = DragVol(ctx, volume, nil, 0.4)
        r.BR_GetSetTrackSendInfo(Track, -1, i, 'D_VOL', true, out)
        --ShowSendVolumePopup(ctx,Track , i)
      end
    end
    -- End undo block only when mouse is released after drag was initiated
    if RecvDragUndoStarted and RecvDragUndoStarted['Track' .. t .. 'Recv' .. i] and im.IsMouseReleased(ctx, 0) then
      r.Undo_EndBlock('Adjust receive volume', -1)
      RecvDragUndoStarted['Track' .. t .. 'Recv' .. i] = nil
    end
    if not im.IsMouseDown(ctx, 0) then
      draggingRecv = nil
    end
    if LBtnDC and im.IsItemHovered(ctx) then
      r.Undo_BeginBlock()
      r.SetTrackSendUIVol(Track, i, 1, 0)
      r.BR_GetSetTrackSendInfo(Track, -1, i, 'D_VOL', true, 1)
      r.Undo_EndBlock('Reset receive volume', -1)
    end

    if not im.IsMouseDown(ctx, 0) then
      draggingRecv = nil
    end
    if RemoveRecv then
      -- start receive delete animation instead of immediate removal (with one-frame delay)
      if not ReceiveDeleteAnim[rKey] then
        ReceiveDeleteAnim[rKey] = { progress = 0, track = Track, index = i, srcGUID = rKey, delay = 1 }
        -- Clear any create animation state
        ReceiveCreateAnim[rKey] = nil
        
        -- Find corresponding send on source track and animate it
        if SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*') then
          -- Count how many receives on Track from SrcTrack exist before this receive index
          -- This determines which send index corresponds to this receive
          local recvCountBeforeThis = 0
          for ri = 0, i - 1 do
            local src = r.GetTrackSendInfo_Value(Track, -1, ri, 'P_SRCTRACK')
            if src == SrcTrack then
              recvCountBeforeThis = recvCountBeforeThis + 1
            end
          end
          
          -- Find the send at the corresponding position
          local sendIndex = -1
          local sendsToThisTrack = 0
          local numSends = r.GetTrackNumSends(SrcTrack, 0)
          for si = 0, numSends - 1 do
            local dest = r.GetTrackSendInfo_Value(SrcTrack, 0, si, 'P_DESTTRACK')
            if dest == Track then
              if sendsToThisTrack == recvCountBeforeThis then
                sendIndex = si
                break
              end
              sendsToThisTrack = sendsToThisTrack + 1
            end
          end
          
          if sendIndex >= 0 then
            local destGUID = r.GetTrackGUID(Track)
            local sKey = MakeSendKey(SrcTrack, destGUID, sendIndex)
            if not SendDeleteAnim[sKey] then
              SendDeleteAnim[sKey] = { progress = 0, track = SrcTrack, index = sendIndex, destGUID = destGUID, delay = 1 }
              -- Clear any create animation state
              SendCreateAnim[sKey] = nil
            end
          end
        end
      end
    end
  end


  if Bypass == 1 then
    im.DrawList_AddRectFilled(WDL, BP.L, BP.T, BP.L + Send_W, BP.B, 0x000000aa)
  end
  
  -- Open source track popup for this receive when not inside an existing popup
  if not InTrackPopup and SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*') then
    if OpenedSrcTrkWin == SrcTrack then
      local frame = (im.GetFrameCount and im.GetFrameCount(ctx)) or nil
      if frame == nil or LastSrcPopupFrame ~= frame then
        OpenSrcTrkWin(ctx, SrcTrack, t)
        if frame ~= nil then LastSrcPopupFrame = frame end
      end
    end
  end
  -- draw receive overlay if animating, advance and queue deletion
  do
    local srcGUID = (SrcTrack and r.ValidatePtr2(0, SrcTrack, 'MediaTrack*')) and r.GetTrackGUID(SrcTrack) or ('invalid_recv_' .. i)
    local key = MakeRecvKey(Track, srcGUID, i)
    local anim = ReceiveDeleteAnim and ReceiveDeleteAnim[key]
    if anim and (anim.progress or 0) < 1 then
      -- derive full row rect from stored row start, not the last item only
      local x = rRowMinX_cached or rRowMinX
      local y = rRowMinY_cached or rRowMinY
      local baseH = (SendsLineHeight or 14)
      local effective_p = math.max(0, ((anim.progress or 0) - 0.25) / 0.75)
      local scale = 1 - (effective_p * effective_p * effective_p)
      local curH = math.max(0.0001, baseH * scale)
      if x and y then
        if anim.delay then
          anim.delay = nil
          ReceiveDeleteAnim[key] = anim
        else
          local done = AdvanceDeleteAnimAndOverlay(ctx, anim, x, y, x + (Send_W or 0), curH, baseH)
          ReceiveDeleteAnim[key] = anim
          if done and not anim.queued then
            anim.queued = true
            local tg = r.GetTrackGUID(Track)
            PendingRecvRemovals[tg] = PendingRecvRemovals[tg] or {}
            table.insert(PendingRecvRemovals[tg], { idx = i, key = key })
          end
        end
      end
    end
  end
  
  -- Pop alpha style var at end (after overlay is drawn) so content fades to transparent
  if pushedRecvAlpha then im.PopStyleVar(ctx) end
end

function AddPreview(ctx, Name, x, y, IsSrc, BtnSize)
  if not x then x, y = im.GetItemRectMin(ctx) end
  local offset = 0 
  if  DestChan and IsSrc then 
    im.DrawList_AddText(FDL, x + BtnSize * 0.09, y, 0xffff88, (DestChan + 1 )..'-'..(DestChan + 2))
    offset = im.CalcTextSize(ctx,(DestChan + 1 )..'-'..(DestChan + 2)..' ')
  end
  if  SrcChan and not IsSrc then 
    im.DrawList_AddText(FDL, x + BtnSize * 0.09, y, 0xffff88, (SrcChan + 1 )..'-'..(SrcChan + 2))
    offset = im.CalcTextSize(ctx,(SrcChan + 1 )..'-'..(SrcChan + 2)..' ')
  end
  im.DrawList_AddRect(FDL, x, y, x + BtnSize, y + SendsLineHeight, Clr.SendsPreview)
  im.DrawList_AddRect(FDL, x + BtnSize, y, x + Send_W - 18, y + SendsLineHeight, Clr.SendsPreview)
  im.DrawList_AddText(FDL, x + BtnSize * 0.09 + offset, y, Clr.SendsPreview, Name)
  im.DrawList_AddText(FDL, x + Send_W - 36, y, Clr.SendsPreview, '0.0')
end
local function Draw_Drop_Preview(ctx)
  if Payload_Type ~= 'DragSend' then return end
  local X, Y = im.GetWindowPos(ctx)
  local W , H = im.GetWindowSize(ctx)
  if im.IsMouseHoveringRect(ctx, X, Y , X + W , Y+H) then 
    local rv, DestName = r.GetTrackName(Track)
    local SrcTrk = r.GetTrack(0, Payload)
    AddPreview(ctx, DestName, SendSrcPreview_X, SendSrcPreview_Y, false, BtnSize)

    if SrcTrk ~= Track then 
      local rv, Name = r.GetTrackName(SrcTrk)

      -- cache src/dest indices for chevron orientation
      local srcIdx = SrcTrk and math.floor(tonumber(r.GetMediaTrackInfo_Value(SrcTrk, 'IP_TRACKNUMBER')) or 0) or -1
      local destIdx = Track and math.floor(tonumber(r.GetMediaTrackInfo_Value(Track, 'IP_TRACKNUMBER')) or 0) or -1
      Send_Drag_Prev = {Track = Track ; Name = Name ; srcIdx = srcIdx ; destIdx = destIdx }
      
      -- compact channel selection for send drag
      if Mods == 0 or Mods == Alt then
        local keyMap = {
          [im.Key_1] = 0,
          [im.Key_2] = 2,  [im.Key_3] = 4,  [im.Key_4] = 6,
          [im.Key_5] = 8,  [im.Key_6] = 10, [im.Key_7] = 12,
          [im.Key_8] = 14, [im.Key_9] = 16
        }
        for key, val in pairs(keyMap) do
          if im.IsKeyPressed(ctx, key) then
            if Mods == 0 then DestChan = val else SrcChan = val end
            break
          end
        end
      end




      if im.IsMouseReleased(ctx,0 ) then 
        r.Undo_BeginBlock()
        -- Determine which receives already existed from this source track
        local preExisting = {}
        local recvCountBefore = r.GetTrackNumSends(Track, -1)
        for recvIdx = 0, recvCountBefore-1 do
          if r.GetTrackSendInfo_Value(Track, -1, recvIdx, 'P_SRCTRACK') == SrcTrk then
            preExisting[recvIdx] = true
          end
        end

        -- Create the new send (returns source-side send index)
        local src_send_idx = r.CreateTrackSend(SrcTrk, Track)

        -- Trigger creation animation
        if src_send_idx then
           local destGUID = r.GetTrackGUID(Track)
           local key = MakeSendKey(SrcTrk, destGUID, src_send_idx)
           -- Clear any existing delete animation state for this key
           SendDeleteAnim[key] = nil
           SendCreateAnim[key] = { progress = 0 }
        end

        -- After creation, locate the *new* receive index on the destination track
        local dest_idx = nil
        local recvCountAfter = r.GetTrackNumSends(Track, -1)
        for recvIdx = 0, recvCountAfter-1 do
          if r.GetTrackSendInfo_Value(Track, -1, recvIdx, 'P_SRCTRACK') == SrcTrk and not preExisting[recvIdx] then
            dest_idx = recvIdx
            break
          end
        end
        -- Fallback in case the loop above did not find it (should not happen)
        if not dest_idx then dest_idx = recvCountAfter-1 end

        -- Trigger receive creation animation
        if dest_idx and src_send_idx then
          local srcGUID = r.GetTrackGUID(SrcTrk)
          local rKey = MakeRecvKey(Track, srcGUID, dest_idx)
          -- Clear any existing delete animation state for this receive
          ReceiveDeleteAnim[rKey] = nil
          ReceiveCreateAnim[rKey] = { progress = 0 }
        end

        -- Apply channel adjustments
        if DestChan then -- change destination channel pair
          r.SetTrackSendInfo_Value(Track, -1, dest_idx, 'I_DSTCHAN', DestChan)
          DestChan = nil
        end
        if SrcChan then -- change source channel pair
          r.SetTrackSendInfo_Value(SrcTrk, 0, src_send_idx, 'I_SRCCHAN', SrcChan)
          SrcChan = nil
        end
        r.Undo_EndBlock('Create send', -1)
      end
    end
  end
end
function Empty_Send_Btn(ctx, Track, t, T)

  if im.Button(ctx, ' ##emptySend', Send_W, T.H) then
    Dur = im.GetMouseDownDuration(ctx, 0)
    if Dur or 1 < 0.15 then
      im.OpenPopup(ctx, 'SendWindow')
    end
  end
  if im.IsItemHovered(ctx) then
    SetHelpHint('LMB = Add Send')
  end
  local popupSend = 'SendWindow'
  if im.IsPopupOpen(ctx, popupSend) then
    local LH = im.GetTextLineHeight(ctx)
    local l_s, t_s = im.GetItemRectMin(ctx)
    local r_s, b_s = im.GetItemRectMax(ctx)
    DrawDottedRect(FDL or im.GetForegroundDrawList(ctx), l_s, t_s, r_s-10, t_s + LH, 0xffffffff)
    EndSendSlot_Rect = {L=l_s, T=t_s, R=r_s-10, B=t_s + LH}
  else
    EndSendSlot_Rect = nil
  end
  im.PopStyleColor(ctx)
  -- im.SetNextWindowSize(ctx, 120, 180)
  if im.BeginPopup(ctx, 'SendWindow') then
    local rv, ThisTrkName = r.GetTrackName(Track)
    
    if Trk[TrkID].SendFav then
      if im.ImageButton(ctx, ThisTrkName .. '##ThisTrack' .. t, Img.Star, 10, 10) then
        ToggleTrackSendFav(Track, TrkID)
      end
    else
      if im.ImageButton(ctx, '##' .. t, Img.StarHollow, 10, 10, nil, nil, nil, nil) then
        ToggleTrackSendFav(Track, TrkID) -- currently selected track
      end
    end
    
    im.SameLine(ctx)
    im.AlignTextToFramePadding(ctx)

    im.Text(ctx, ThisTrkName)

    TrkName = TrkName or {}
    AddSpacing(3)
    im.Separator(ctx)
    AddSpacing(3)

    im.Text(ctx, 'Find Tracks:')
    _, AddSend_FILTER = im.InputText(ctx, '##input', AddSend_FILTER, im.InputTextFlags_AutoSelectAll)
    SendWin_W = im.GetWindowSize(ctx)


    if im.IsWindowAppearing(ctx) then
      for t = 0, TrackCount - 1, 1 do
        local Track    = r.GetTrack(0, t)
        if Track then
          local rv, Name = r.GetTrackName(Track)
          TrkName[t]     = Name
        end
      end
      im.SetKeyboardFocusHere(ctx, -1)
    end
    im.PushStyleVar(ctx, im.StyleVar_ButtonTextAlign, 0, 0)

    ------Starred Tracks --------
    for t = 0, TrackCount - 1, 1 do
      local SrcTrk = Track
      local Track = r.GetTrack(0, t)
      if Track then
        local ID = r.GetTrackGUID(Track)
        if r.GetTrackGUID(SrcTrk) ~= ID then
          if Trk[ID] and Trk[ID].SendFav then
            if im.ImageButton(ctx, '##' .. t, Img.Star, 10, 10) then
              ToggleTrackSendFav(Track, ID)
            end
            im.SameLine(ctx)
            if im.Button(ctx, TrkName[t] .. '##', SendWin_W - 30) then
              r.Undo_BeginBlock()
              local newSendIdx = r.CreateTrackSend(SrcTrk, Track)
              if newSendIdx then
                local destGUID = r.GetTrackGUID(Track)
                local key = MakeSendKey(SrcTrk, destGUID, newSendIdx)
                -- Clear any existing delete animation state for this key
                SendDeleteAnim[key] = nil
                SendCreateAnim[key] = { progress = 0 }
                
                -- Find corresponding receive and trigger its create animation
                local numRecvs = r.GetTrackNumSends(Track, -1)
                for ri = numRecvs - 1, 0, -1 do
                  local src = r.GetTrackSendInfo_Value(Track, -1, ri, 'P_SRCTRACK')
                  if src == SrcTrk then
                    local srcGUID = r.GetTrackGUID(SrcTrk)
                    local rKey = MakeRecvKey(Track, srcGUID, ri)
                    ReceiveDeleteAnim[rKey] = nil
                    ReceiveCreateAnim[rKey] = { progress = 0 }
                    break
                  end
                end
              end
              r.Undo_EndBlock('Create send', -1)
              im.CloseCurrentPopup(ctx)
            end
          end
        end
      end
    end


    if AddSend_FILTER ~= '' and AddSend_FILTER then
      for t = 0, TrackCount - 1, 1 do
        local SrcTrk = Track
        local Track = r.GetTrack(0, t)
        local ID = r.GetTrackGUID(Track)
        if r.GetTrackGUID(SrcTrk) ~= ID then
          if string.lower(TrkName[t]):find(string.lower(AddSend_FILTER)) and not Trk[ID].SendFav then
            if im.ImageButton(ctx, '##' .. t, Img.StarHollow, 10, 10, nil, nil, nil, nil) then
              ToggleTrackSendFav(Track, ID)
            end
            im.SameLine(ctx)
            if im.Button(ctx, TrkName[t] .. '##', SendWin_W - 30) then
              r.Undo_BeginBlock()
              local newSendIdx = r.CreateTrackSend(SrcTrk, Track)
              if newSendIdx then
                local destGUID = r.GetTrackGUID(Track)
                local key = MakeSendKey(SrcTrk, destGUID, newSendIdx)
                -- Clear any existing delete animation state for this key
                SendDeleteAnim[key] = nil
                SendCreateAnim[key] = { progress = 0 }
                
                -- Find corresponding receive and trigger its create animation
                local numRecvs = r.GetTrackNumSends(Track, -1)
                for ri = numRecvs - 1, 0, -1 do
                  local src = r.GetTrackSendInfo_Value(Track, -1, ri, 'P_SRCTRACK')
                  if src == SrcTrk then
                    local srcGUID = r.GetTrackGUID(SrcTrk)
                    local rKey = MakeRecvKey(Track, srcGUID, ri)
                    ReceiveDeleteAnim[rKey] = nil
                    ReceiveCreateAnim[rKey] = { progress = 0 }
                    break
                  end
                end
              end
              r.Undo_EndBlock('Create send', -1)
            end
          end
      end
      end
      --[[ elseif AddSend_FILTER == '' then
      for t = 0, TrackCount - 1, 1 do
        local Track = r.GetTrack(0, t)
        local ID = r.GetTrackGUID(Track)
        if Trk[ID].SendFav then
          if im.ImageButton(ctx, '##' .. t, Img.Star, 10, 10) then
            Trk[ID].SendFav = false
          end
        else
          if im.ImageButton(ctx, '##' .. t, Img.StarHollow, 10, 10, nil, nil, nil, nil) then
            Trk[ID].SendFav = true
          end
        end
        im.SameLine(ctx)
        im.Button(ctx, TrkName[t] .. '##', SendWin_W - 30)
      end ]]
    end
    im.PopStyleVar(ctx)
    im.EndPopup(ctx)
  end
  if im.BeginDragDropSource(ctx, im.DragDropFlags_AcceptNoDrawDefaultRect + im.DragDropFlags_SourceNoPreviewTooltip) then
    DraggingTrack = t
    DraggingTrack_Data = Track
    im.SetDragDropPayload(ctx, 'DragSend', t)

    im.EndDragDropSource(ctx)
    local cur = r.JS_Mouse_LoadCursor(7)
    r.JS_Mouse_SetCursor(cur)
    SendSrcPreview_X, SendSrcPreview_Y = im.GetItemRectMin(ctx)
  end

end


function Sends_List(ctx, t, HeightOfs, T)
  if not OPEN.ShowSends then return end 
  --------------------------------------------
  ------Make child frame for sends -----------
  --------------------------------------------
  Separator_Reszie_Handle()

  local WDL = im.GetWindowDrawList(ctx)
  



  if not im.BeginChild(ctx, 'Sends' .. t, Send_W, Trk[t].H-HeightOfs, nil, im.WindowFlags_NoScrollbar + im.WindowFlags_NoScrollWithMouse) then return end 
  do
    local childPosX, childPosY = im.GetWindowPos(ctx)
    local childW, childH = im.GetWindowSize(ctx)
    if Trk and TrkID then
      Trk[TrkID] = Trk[TrkID] or {}
      Trk[TrkID].SendsChildRect = { L = childPosX, T = childPosY, R = childPosX + childW, B = childPosY + childH }
    end
  end
  -- Draw progressive hide cue when overshooting at min width: red fill + central X with pop effect
  do
    local tr = r.GetTrack(0, t)
    local gid = tr and r.GetTrackGUID(tr)
    local activeFrac = nil
    if gid and PerTrackHideOvershoot and PerTrackHideOvershoot[gid] and (Send_W or 0) <= (MIN_SEND_W or 70) then
      local overshoot = math.min(PerTrackHideOvershoot[gid] or 0, (HIDE_DRAG_PX or 10))
      activeFrac = ((HIDE_DRAG_PX or 10) > 0) and (overshoot / (HIDE_DRAG_PX or 10)) or 0
    elseif gid and PerTrackHideFade and PerTrackHideFade[gid] then
      -- fade-out after release when not hidden
      local cur = PerTrackHideFade[gid]
      cur = math.max(0, cur - 0.08)
      if cur <= 0 then PerTrackHideFade[gid] = nil else PerTrackHideFade[gid] = cur end
      activeFrac = cur
    end
    if gid and activeFrac and activeFrac > 0 then
      local winX, winY = im.GetWindowPos(ctx)
      local winW, winH = im.GetWindowSize(ctx)
      local dl = im.GetWindowDrawList(ctx)
      -- Gradual red overlay fill (alpha scales with frac) - darker red
      local fillAlpha = math.max(0.05, math.min(0.8, 0.8 * activeFrac))
      local fillCol = im.ColorConvertDouble4ToU32(0.8, 0.0, 0.0, fillAlpha)
      im.DrawList_AddRectFilled(dl, winX, winY, winX + winW, winY + winH, fillCol)
      -- Central X that scales in; add pop effect once threshold is reached
      PerTrackHidePopAnim = PerTrackHidePopAnim or {}
      local pop = 0
      if activeFrac >= 1.0 then
        -- progress from 0 -> 1 over subsequent frames for pop decay
        local pv = PerTrackHidePopAnim[gid] or 0
        pv = math.min(1, pv + 0.2)
        PerTrackHidePopAnim[gid] = pv
        pop = (1 - pv) * 0.2 -- start +20% size, decay to 0
      else
        PerTrackHidePopAnim[gid] = 0
      end
      local cx = winX + winW * 0.5
      local cy = winY + winH * 0.5
      local baseSz = math.max(14, math.min(60, winW * 0.5))
      local sz = baseSz * math.max(0.2, activeFrac) * (1 + pop)
      local thick = 2 + 3 * math.max(0, activeFrac - 0.5) + (pop > 0 and 2 or 0)
      local xCol = im.ColorConvertDouble4ToU32(1.0, 0.2 + 0.8*activeFrac, 0.2 + 0.8*activeFrac, activeFrac >= 1.0 and 1.0 or math.max(0.3, 0.7*activeFrac))
      im.DrawList_AddLine(dl, cx - sz*0.5, cy - sz*0.5, cx + sz*0.5, cy + sz*0.5, xCol, thick)
      im.DrawList_AddLine(dl, cx + sz*0.5, cy - sz*0.5, cx - sz*0.5, cy + sz*0.5, xCol, thick)
    end
  end
  -- top margin inside Sends child
  im.Dummy(ctx, 0, 1)
  im.PushFont(ctx,Arial_11) -- Font for Sends and Receives 
  Do_Pan_Faders_If_In_MIX_MODE (ctx, Track, t)
  
  -- Skip rendering sends and receives when in pan mode (MIX_MODE)
  if not (MIX_MODE or MIX_MODE_Temp) then
    ------ Repeat for Sends------
    NumSends = r.GetTrackNumSends(Track, 0)
    -- Global per-frame flag to detect if any send/recv was hovered in this child
    SENDS_HOVER_THIS_FRAME = false
    
    BtnSize = Send_W - SendValSize - 20
    Send_Drag_Prev = Send_Drag_Prev or {}
    
    
    
    if Send_Drag_Prev.Track == Track then 
      local X, Y = im.GetCursorScreenPos(ctx)
      local rv = im.Button(ctx, '' .. '##', BtnSize , SendsLineHeight)
      AddPreview(ctx,   Send_Drag_Prev.Name, nil,nil, true , BtnSize)
      -- draw the same shape as hover: left, vertical chevrons (static), right
      -- pick chevron orientation based on cached src/dest indices captured at hover start
      local srcIdx = (Send_Drag_Prev and Send_Drag_Prev.srcIdx) or -1
      local destIdx = (Send_Drag_Prev and Send_Drag_Prev.destIdx) or -1
      local dirUpWanted = (destIdx < srcIdx)
      local dirUpFromCoords = (SendSrcPreview_Y > Y)
      -- flip invert to correct chevron orientation
      local invert = (dirUpFromCoords == dirUpWanted)
      DrawBentPatchLineStatic(FDL, SendSrcPreview_X, SendSrcPreview_Y, Y, 10, (Clr and Clr.PatchLine) or 0xffffffff, invert)
      Send_Drag_Prev = {}
    end
    
    
    
    Send_Btn(ctx, Track, t, BtnSize)
    
    NumRecv = r.GetTrackNumSends(Track, -1)
    -- Receive buttons color
    do
      local base = Clr.ReceiveSend
      local hvr  = Clr.ReceiveSendHvr or (LightenColorU32 and LightenColorU32(base, 0.15)) or base
      im.PushStyleColor(ctx, im.Col_Button, base)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, hvr)
    end
    
    for i = 0, NumRecv - 1, 1 do
      ReceiveBtn(ctx, Track, t, i, BtnSize)
    end
    
    im.PopStyleColor(ctx, 2) --pop Receive buttons color
    
    -------Empty Area below sends ------
    im.PushStyleColor(ctx, im.Col_Button, getClr(im.Col_ChildBg))
    im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_FrameBgHovered))
    im.PushStyleColor(ctx, im.Col_DragDropTarget, 0xffffffff)
    
    Empty_Send_Btn(ctx, Track, t, T)
    
    im.PopStyleColor(ctx, 2)
  end
  
  
  
  
  Draw_Drop_Preview(ctx)
  
  
  im.PopFont(ctx)
  im.EndChild(ctx)

  -- Process any pending animated send removals for this track after drawing
  do
    local tg = r.GetTrackGUID(Track)
    local pend = PendingSendRemovals and PendingSendRemovals[tg]
    if pend and #pend > 0 then
      local list = {}
      for _, e in ipairs(pend) do
        if e and type(e.idx) == 'number' then list[#list+1] = { idx = e.idx, container = e.container, key = e.key } end
      end
      table.sort(list, function(a,b) return (a.idx or 0) > (b.idx or 0) end)
      r.Undo_BeginBlock()
      for _, e in ipairs(list) do
        if e.container then
          -- best-effort: ignore if container index shifted; caller provided last known index
          if e.container >= 0 then pcall(r.TrackFX_Delete, Track, e.container) end
        end
        -- Verify the send at this index still matches the destination before deleting
        -- This prevents deleting the wrong send when indices shift after previous deletions
        if e.idx and e.idx < r.GetTrackNumSends(Track, 0) then
          local dest = r.GetTrackSendInfo_Value(Track, 0, e.idx, 'P_DESTTRACK')
          local currentDestGUID = (dest and r.ValidatePtr2(0, dest, 'MediaTrack*')) and r.GetTrackGUID(dest) or nil
          -- Only delete if the destination still matches (or if destGUID wasn't stored)
          if not e.destGUID or currentDestGUID == e.destGUID then
            r.RemoveTrackSend(Track, 0, e.idx)
          end
        end
        if e.key then SendDeleteAnim[e.key] = nil end
      end
      r.Undo_EndBlock('Delete send(s)', -1)
      -- start hover block until mouse moves at least 20px
      do
        local mx, my = im.GetMousePos(ctx)
        HoverBlockAfterDelete = { active = true, startX = mx, startY = my }
      end
      PendingSendRemovals[tg] = nil
    end
    -- process receive removals
    local pendR = PendingRecvRemovals and PendingRecvRemovals[tg]
    if pendR and #pendR > 0 then
      local list = {}
      for _, e in ipairs(pendR) do
        if e and type(e.idx) == 'number' then list[#list+1] = { idx = e.idx, key = e.key } end
      end
      table.sort(list, function(a,b) return (a.idx or 0) > (b.idx or 0) end)
      r.Undo_BeginBlock()
      for _, e in ipairs(list) do
        local cnt = r.GetTrackNumSends(Track, -1)
        if e.idx and cnt and e.idx < cnt then
          r.RemoveTrackSend(Track, -1, e.idx)
        end
        if e.key then ReceiveDeleteAnim[e.key] = nil end
      end
      r.Undo_EndBlock('Delete receive(s)', -1)
      -- use same hover block behavior after receive deletions
      do
        local mx, my = im.GetMousePos(ctx)
        HoverBlockAfterDelete = { active = true, startX = mx, startY = my }
      end
      PendingRecvRemovals[tg] = nil
    end
  end

  -- If nothing was hovered in this sends list during this frame, clear lingering hover state for this track
  if not SENDS_HOVER_THIS_FRAME then
    if HoverSend and TrkID and string.find(HoverSend, TrkID, 1, true) then
      HoverSend = nil
      HoverSend_Dest = nil
      HoverSend_Src = nil
      HoverSend_Dest_Chan = nil
      HoverSend_Src_Chan = nil
    end
    if HoverRecv and TrkID and string.find(HoverRecv, TrkID, 1, true) then
      HoverRecv = nil
      HoverRecv_Dest = nil
      HoverRecv_Src = nil
      HoverRecv_Dest_Chan = nil
      HoverRecv_Src_Chan = nil
    end
  end

  

  local winDL      = im.GetWindowDrawList(ctx)
  local winPosX, _ = im.GetWindowPos(ctx)
  local winPosX = winPosX + 8
  local winW       = ({im.GetWindowSize(ctx)})[1]
  -- draw line at the current cursor Y (bottom of the just-drawn track row)
  local _, sepY    = im.GetCursorScreenPos(ctx)
  local sepY =sepY-1
  im.DrawList_AddLine(winDL, winPosX, sepY, winPosX + winW, sepY, (Clr and Clr.TrackBoundaryLine) or im.GetColor(ctx, im.Col_Button), 3)

  -- pop # 3 childbg + hover + active


end