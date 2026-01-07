
-- helper: return same color with specified alpha (0..1)
local function ColorWithAlpha(color, alpha)
  local r, g, b, a = im.ColorConvertU32ToDouble4(color)
  local na = math.max(0, math.min(1, alpha or 1))
  return im.ColorConvertDouble4ToU32(r, g, b, na)
end

-- Safe fallbacks in case helpers were removed
if not LightenColorU32 then
  function LightenColorU32(color, amount)
    local r,g,b,a = im.ColorConvertU32ToDouble4(color)
    amount = math.max(0, math.min(1, amount or 0))
    r = r + (1 - r) * amount
    g = g + (1 - g) * amount
    b = b + (1 - b) * amount
    return im.ColorConvertDouble4ToU32(r,g,b,a)
  end
end
if not DarkenColorU32 then
  function DarkenColorU32(color, amount)
    local r,g,b,a = im.ColorConvertU32ToDouble4(color)
    amount = math.max(0, math.min(1, amount or 0))
    local f = 1 - amount
    r = r * f; g = g * f; b = b * f
    return im.ColorConvertDouble4ToU32(r,g,b,a)
  end
end
if not deriveHover then
  function deriveHover(base)
    -- Enhanced hover effect: more noticeable lightening for better visual feedback
    return LightenColorU32(base, 0.20)
  end
end
if not deriveActive then
  function deriveActive(base)
    return DarkenColorU32(base, 0.10)
  end
end

-- Color utilities and per-project persistent container colors -----------------
local function HSVtoU32(h, s, v, a)
  local r, g, b = im.ColorConvertHSVtoRGB(h % 1, math.max(0, math.min(1, s or 1)), math.max(0, math.min(1, v or 1)))
  return im.ColorConvertDouble4ToU32(r, g, b, math.max(0, math.min(1, a or 1)))
end

ContainerColorCache = ContainerColorCache or {}
local function GetContainerColor(Track, containerIndex, fxGUID)
  if not fxGUID then return 0xffffffff end
  if ContainerColorCache[fxGUID] then return ContainerColorCache[fxGUID] end
  -- Try load from project-ext state
  local key = 'P_EXT: VFXL_ContainerColor_' .. tostring(fxGUID)
  local ok, stored = r.GetSetMediaTrackInfo_String(Track, key, '', false)
  if ok and stored ~= '' then
    local asNum = tonumber(stored)
    if asNum then ContainerColorCache[fxGUID] = asNum; return asNum end
  end
  -- Assign new hue index (per-track monotonic)
  local idxKey = 'P_EXT: VFXL_NextContainerColorIndex'
  local _, idxStr = r.GetSetMediaTrackInfo_String(Track, idxKey, '', false)
  local idx = tonumber(idxStr) or 0
  idx = idx + 1
  -- Seed hues for first few: orange, red, purple, teal
  local seeds = { 0.08, 0.00, 0.78, 0.50 }
  local hue
  if idx <= #seeds then
    hue = seeds[idx]
  else
    local lastHueKey = 'P_EXT: VFXL_LastHue'
    local _, lastHueStr = r.GetSetMediaTrackInfo_String(Track, lastHueKey, '', false)
    local lastHue = tonumber(lastHueStr) or seeds[#seeds]
    -- Golden-angle step provides maximal separation around the circle
    local golden = 0.618033988749895
    hue = (lastHue + golden) % 1
    -- Ensure noticeable difference if we wrap near a previously used hue
    local diff = math.abs(hue - lastHue)
    if diff < 0.08 or diff > 0.92 then
      hue = (hue + 0.33) % 1
    end
    r.GetSetMediaTrackInfo_String(Track, lastHueKey, tostring(hue), true)
  end
  local col = HSVtoU32(hue, 0.65, 0.95, 1.0)
  r.GetSetMediaTrackInfo_String(Track, key, tostring(col), true)
  r.GetSetMediaTrackInfo_String(Track, idxKey, tostring(idx), true)
  ContainerColorCache[fxGUID] = col
  return col
end

-- DrawListSplitter helper intentionally local-only per use to avoid cross-window misuse.

-- Track container right-click to detect click vs drag
-- Only toggle if: right-click down and release within short time AND no significant mouse movement
ContainerRightClickStart = ContainerRightClickStart or {}
local CONTAINER_CLICK_TIME_THRESHOLD = 0.2 -- seconds
local CONTAINER_CLICK_MOVE_THRESHOLD = 5 -- pixels

-- Track maximum distance moved during drag (updated each frame while mouse is down)
ContainerRightClickMaxMove = ContainerRightClickMaxMove or {}

function FXBtns(Track, BtnSz, container, TrackTB, ctx, inheritedAlpha, OPEN)
  FX_Ct = r.TrackFX_GetCount(Track)
  local t = TrackTB
  local AutoSize
  if BtnSz == 'Auto Size' then
    local A = {}
    for fx = 0, FX_Ct - 1, 1 do
      local rv, Name = r.TrackFX_GetFXName(Track, fx)
      local w, h = im.CalcTextSize(ctx, Name)
      table.insert(A, w)
    end
    if A[1] then
      AutoSize = math.max(table.unpack(A)) - WetDryKnobSz * 2.5
    end
  end

  BtnSz = BtnSz or FXPane_W - WetDryKnobSz * 2.5
  -- Ensure inherited alpha defaults to fully opaque
  inheritedAlpha = inheritedAlpha or 1
  if BtnSz == 'Auto Size' then BtnSz = AutoSize end

  if container then 
    FX_Ct = tonumber( select(2, r.TrackFX_GetNamedConfigParm(Track, container, 'container_count')))
  end
  
  -- Helpers for parallel grouping at this scope
  local function BuildLevelList()
    local list = {}
    if container then
      local cnt = tonumber(select(2, r.TrackFX_GetNamedConfigParm(Track, container, 'container_count'))) or 0
      for i = 0, cnt - 1 do
        local id = tonumber(select(2, r.TrackFX_GetNamedConfigParm(Track, container, 'container_item.' .. i)))
        if id then list[#list + 1] = id end
      end
    else
      local cnt = r.TrackFX_GetCount(Track)
      for i = 0, cnt - 1 do list[#list + 1] = i end
    end
    return list
  end

  local function GetParallelGroupPeers(currentFx)
    local list = BuildLevelList()
    local idx
    for i = 1, #list do
      if list[i] == currentFx then idx = i break end
    end
    if not idx then return {} end
    local start_i = idx
    while start_i > 1 do
      local _, pv = r.TrackFX_GetNamedConfigParm(Track, list[start_i], 'parallel')
      if tonumber(pv or '0') and tonumber(pv or '0') > 0 then
        start_i = start_i - 1
      else
        break
      end
    end
    local end_i = idx
    while end_i + 1 <= #list do
      local _, nv = r.TrackFX_GetNamedConfigParm(Track, list[end_i + 1], 'parallel')
      if tonumber(nv or '0') and tonumber(nv or '0') > 0 then
        end_i = end_i + 1
      else
        break
      end
    end
    local peers = {}
    for i = start_i, end_i do peers[#peers + 1] = list[i] end
    return peers
  end

  local prevFxAtLevel = nil
  -- Defer container children rendering until end of parallel group
  local deferredChildren = {}
  -- Track open AB Level Matching block from Source to Control on this track
  local ABOpenRect = nil
  -- Repeat for every fx
  for fx = 0, (FX_Ct or 0) - 1, 1 do
    if container then 
      fx =  tonumber(select(2, r.TrackFX_GetNamedConfigParm(Track, container, 'container_item.'..fx)))
    end
    if not fx then return end 
    
    -- Determine parallel-with-previous state (1=parallel audio, 2=parallel+merge MIDI)
    local _, parStr = r.TrackFX_GetNamedConfigParm(Track, fx, 'parallel')
    local parVal = tonumber(parStr or '0') or 0
    if parVal > 0 and prevFxAtLevel then
      -- Always place parallel FX on the same line; children will render after the row
      im.SameLine(ctx, 0, 6)
    end
    
    local rv, Name = r.TrackFX_GetNamedConfigParm( Track,  fx, 'fx_name')
    local _, FullName = r.TrackFX_GetFXName(Track, fx)
    local FX_Is_Open
    Trk[t][fx] = Trk[t][fx] or {}
    local F = Trk[t][fx]



    if r.TrackFX_GetOpen(Track, fx) then
      --im.PushStyleColor(ctx, im.Col_Button(), getClr(im.Col_ButtonActive()))
      FX_Is_Open = true
    end

    if im.IsMouseDown(ctx, 0) then
      Dur = im.GetMouseDownDuration(ctx, 0)
      DragX, DragY = im.GetMouseDragDelta(ctx, DragX, DragY)
      if not MouseDragDir then
        if DragY > 5 or DragY < -5 then
          MouseDragDir = 'Vert'
        elseif DragX > 5 or DragX < -5 then
          MouseDragDir = 'Horiz'
        
        end
      end
    else
      MouseDragDir = nil
      -- Clear pending drop target if drag ended without a drop
      if DraggingFX_Index ~= nil then
        PendingDropTarget = nil
      end
      DraggingFX_Index = nil
    end

    local ShownName = ChangeFX_Name(Name)
    local fxID = r.TrackFX_GetFXGUID(Track, fx)
    if fxID then FX[fxID] = FX[fxID] or {} end
    -- Deleting animation flag for this FX
    local DeletingAnim = fxID and FXDeleteAnim and FXDeleteAnim[fxID]
    local IsDeleting = DeletingAnim and (DeletingAnim.progress or 0) < 1
    -- Creation animation flag for this FX
    local CreatingAnim = fxID and FXCreateAnim and FXCreateAnim[fxID]
    -- Detect if this FX is a Reaper FX Container
    local _, __cnt = r.TrackFX_GetNamedConfigParm(Track, fx, 'container_count')
    local isContainer = (__cnt and __cnt ~= '') and true or false
    -- Default: when multiple containers are in parallel, start them collapsed
    if isContainer and fxID and ContainerCollapsed[fxID] == nil then
      local peers = GetParallelGroupPeers(fx)
      if peers and #peers > 1 then
        local containerPeers = 0
        for _, p in ipairs(peers) do
          local _, c = r.TrackFX_GetNamedConfigParm(Track, p, 'container_count')
          if c and c ~= '' then containerPeers = containerPeers + 1 end
        end
        if containerPeers >= 2 then
          ContainerCollapsed[fxID] = true
          ContainerAnim[fxID] = ContainerAnim[fxID] or 1
        end
      end
    end

    local offset = 0
    -- Draw folder icon (open/closed) at the left when this FX is a container
    if (not IsDeleting) and isContainer and (Img.FolderOpen or Img.Folder)  then
      local iconSz = HideBtnSz
      local folderImg = (ContainerCollapsed[fxID] and Img.Folder) or (Img.FolderOpen or Img.Folder)
      local containerColor = GetContainerColor(Track, fx, fxID)
      -- Make the folder icon clickable so users can toggle collapse by clicking it
      if im.ImageButton(ctx, '##Folder' .. tostring(fxID), folderImg, iconSz, iconSz, nil, nil, nil, nil, nil, containerColor) then
        local newState = not ContainerCollapsed[fxID]
        ContainerCollapsed[fxID] = newState
        ContainerAnim[fxID] = ContainerAnim[fxID] or 0
        if not newState then
          local peers = GetParallelGroupPeers(fx)
          for _, p in ipairs(peers) do
            if p ~= fx then
              local _, pCnt = r.TrackFX_GetNamedConfigParm(Track, p, 'container_count')
              if pCnt and pCnt ~= '' then
                local pGUID = r.TrackFX_GetFXGUID(Track, p)
                if pGUID then
                  ContainerCollapsed[pGUID] = true
                  ContainerAnim[pGUID] = ContainerAnim[pGUID] or 0
                end
              end
            end
          end
        end
      end
      -- Track container right-click movement (must be outside hover check so it works during drag)
      if im.IsMouseDown(ctx, 1) then
        if not ContainerRightClickStart[fxID] then
          -- Check if mouse is within folder icon bounds to start tracking
          local iconL, iconT = im.GetItemRectMin(ctx)
          local iconR, iconB = im.GetItemRectMax(ctx)
          local mx, my = im.GetMousePos(ctx)
          if mx >= iconL and mx <= iconR and my >= iconT and my <= iconB then
            local now = r.time_precise()
            ContainerRightClickStart[fxID] = { x = mx, y = my, time = now }
            ContainerRightClickMaxMove[fxID] = 0 -- Track max distance moved
          end
        elseif ContainerRightClickStart[fxID] then
          -- Update max distance moved while mouse is down (even if not hovering)
          local mx, my = im.GetMousePos(ctx)
          local dx = math.abs(mx - ContainerRightClickStart[fxID].x)
          local dy = math.abs(my - ContainerRightClickStart[fxID].y)
          local maxDist = math.max(dx, dy)
          local currentMax = ContainerRightClickMaxMove[fxID] or 0
          if maxDist > currentMax then
            ContainerRightClickMaxMove[fxID] = maxDist
          end
        end
      end
      
      if im.IsItemHovered(ctx) then
        SetHelpHint('LMB = Toggle Container Expand/Collapse', 'RMB = Toggle Container Expand/Collapse', 'Drag FX here to add to container')
      end
      -- Also support right-click specifically on the folder icon
      -- Only toggle if: quick click (within time threshold) AND no significant movement AND marquee selection not active
      -- Check for mouse release (not IsItemClicked, which might fire at wrong time)
      if ContainerRightClickStart[fxID] and im.IsMouseReleased(ctx, 1) then
        -- NEVER toggle if marquee selection is active
        local shouldToggle = false
        -- Check if Alt is held - if so, don't toggle collapse/uncollapse
        local Mods = im.GetKeyMods(ctx)
        if Mods == Alt then
          -- Alt + right click: don't toggle collapse/uncollapse
          shouldToggle = false
        elseif MarqueeSelection and MarqueeSelection.isActive then
          -- Marquee selection is currently active, don't toggle
          shouldToggle = false
        else
          -- Use the maximum distance moved during the drag (tracked while mouse was down)
          local maxMove = ContainerRightClickMaxMove[fxID] or 0
          local releaseTime = r.time_precise()
          local timeElapsed = releaseTime - ContainerRightClickStart[fxID].time
          
          -- Only toggle if: quick release AND no significant movement
          if timeElapsed < CONTAINER_CLICK_TIME_THRESHOLD and 
             maxMove < CONTAINER_CLICK_MOVE_THRESHOLD then
            shouldToggle = true
          end
        end
        if shouldToggle then
          local newState = not ContainerCollapsed[fxID]
          ContainerCollapsed[fxID] = newState
          ContainerAnim[fxID] = ContainerAnim[fxID] or 0
          if not newState then
            local peers = GetParallelGroupPeers(fx)
            for _, p in ipairs(peers) do
              if p ~= fx then
                local _, pCnt = r.TrackFX_GetNamedConfigParm(Track, p, 'container_count')
                if pCnt and pCnt ~= '' then
                  local pGUID = r.TrackFX_GetFXGUID(Track, p)
                  if pGUID then
                    ContainerCollapsed[pGUID] = true
                    ContainerAnim[pGUID] = ContainerAnim[pGUID] or 0
                  end
                end
              end
            end
          end
        end
        -- Clear tracking after handling release
        ContainerRightClickStart[fxID] = nil
        ContainerRightClickMaxMove[fxID] = nil
      end
      -- Drag-over highlight and drop-into-container (append to end)
      do
        local iconL, iconT = im.GetItemRectMin(ctx)
        local iconR, iconB = im.GetItemRectMax(ctx)
        -- Draw subtle highlight when pointer is over the icon while dragging
        if im.IsItemHovered(ctx) and MouseDragDir == 'Vert' and DraggingFX_Index ~= nil then
          local DL = FDL or im.GetForegroundDrawList(ctx)
          im.DrawList_AddRect(DL, iconL - 2, iconT - 2, iconR + 2, iconB + 2, containerColor, 2, nil, 2)
        end

        -- Accept drop on the folder icon to insert at end of container
        if im.BeginDragDropTarget(ctx) then
          local dropped, draggedFXPayload = im.AcceptDragDropPayload(ctx, 'DragFX')
          local _, payloadType, draggedFXIdx, is_preview, is_delivery = im.GetDragDropPayload(ctx)
          local draggedFXIdxNum = tonumber(draggedFXIdx)

          -- Show a subtle highlight during preview
          do
            local DL = FDL or im.GetForegroundDrawList(ctx)
            im.DrawList_AddRect(DL, iconL - 2, iconT - 2, iconR + 2, iconB + 2, containerColor, 2, nil, 2)
          end

          -- Auto-uncollapse after 0.8s hover while an FX is being dragged over this icon
          do
            FX[fxID] = FX[fxID] or {}
            if is_preview and MouseDragDir == 'Vert' and DraggingFX_Index ~= nil then
              local now = r.time_precise()
              FX[fxID].FolderHoverStart = FX[fxID].FolderHoverStart or now
              if ContainerCollapsed[fxID] and (now - (FX[fxID].FolderHoverStart or now)) > 0.8 then
                ContainerCollapsed[fxID] = false
                ContainerAnim[fxID] = ContainerAnim[fxID] or 0
              end
            else
              FX[fxID].FolderHoverStart = nil
            end
          end

          if dropped and draggedFXIdxNum then
            -- Compute destination inside the container: append to end
            local _, cntStr = r.TrackFX_GetNamedConfigParm(Track, fx, 'container_count')
            local curCnt = tonumber(cntStr) or 0
            local into = Calc_Container_FX_Index and Calc_Container_FX_Index(Track, fx, curCnt + 1)
            if into then
              if Mods == 0 then
                r.TrackFX_CopyToTrack(DraggingTrack_Data, draggedFXIdxNum, Track, into, true)
              elseif Mods == Super then
                r.TrackFX_CopyToTrack(DraggingTrack_Data, draggedFXIdxNum, Track, into, false)
              elseif Mods == Ctrl then -- Pool FX (copy and link)
                r.TrackFX_CopyToTrack(DraggingTrack_Data, draggedFXIdxNum, Track, into, false)
                local ID = r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFXIdxNum)
                NeedLinkFXsID = ID
                FX = FX or {}
                FX[ID] = FX[ID] or {}
              end
            end
          end
          im.EndDragDropTarget(ctx)
        end
        -- Persist folder icon rect so we can connect a guide line later when drawing children
        do
          local _fl, _ft = im.GetItemRectMin(ctx)
          local _fr, _fb = im.GetItemRectMax(ctx)
          FX[fxID] = FX[fxID] or {}
          FX[fxID].FolderRect = { L = _fl, T = _ft, R = _fr, B = _fb }
        end
      end
      SL(nil, 1)
      offset = offset + iconSz + 1
    end

    if (not IsDeleting) and FX[fxID] and FX[fxID].Link then
      -- Validate that the linked FX still exists
      local linkedFxID = FX[fxID].Link
      local out = FindFXFromFxGUID(linkedFxID)
      if not out.trk[1] then
        -- Linked FX no longer exists, remove the link
        r.GetSetMediaTrackInfo_String(Track, 'P_EXT: FX' .. fxID .. 'Link to ', '', true)
        FX[fxID].Link = nil
      else
        -- Linked FX exists, display the link icon
        local LN = im.GetTextLineHeight(ctx)
        local linkTint = (Clr and Clr.LinkCable) or 0xffffffff
        if im.ImageButton(ctx, '##Link' .. fxID, Img.Link, LN, LN, nil, nil, nil, nil, nil, linkTint) then
          if out.trk[1] then 
            r.GetSetMediaTrackInfo_String(out.trk[1], 'P_EXT: FX' .. FX[fxID].Link .. 'Link to ', '', true)
            FX[FX[fxID].Link].Link = nil
          end
          r.GetSetMediaTrackInfo_String(Track, 'P_EXT: FX' .. fxID .. 'Link to ', '', true)
          FX[fxID].Link = nil
        end
        if im.IsItemHovered(ctx) then
          SetHelpHint('LMB = Unlink FX')
        end
        -- capture link icon rect for hover glow and cross-highlighting
        do
          local L, T = im.GetItemRectMin(ctx)
          local R, B = im.GetItemRectMax(ctx)
          FX[fxID].LinkRect = { L = L, T = T, R = R, B = B }
          local base = (Clr and Clr.LinkCable) or 0xffffffff
          local glowClr = deriveHover(base)
          -- highlight when icon itself hovered
          if im.IsItemHovered(ctx) then
            im.DrawList_AddRect(FDL, L - 2, T - 2, R + 2, B + 2, glowClr, 2, nil, 3)
            local linkedId = FX[fxID].Link
            if linkedId and FX[linkedId] and FX[linkedId].LinkRect then
              local rr = FX[linkedId].LinkRect
              im.DrawList_AddRect(FDL, rr.L - 2, rr.T - 2, rr.R + 2, rr.B + 2, glowClr, 2, nil, 3)
            end
          end
          -- highlight when the FX row is hovered (tracked elsewhere)
          if HoveredLinkedFXID == fxID then
            im.DrawList_AddRect(FDL, L - 2, T - 2, R + 2, B + 2, glowClr, 2, nil, 3)
            local linkedId = FX[fxID].Link
            if linkedId and FX[linkedId] and FX[linkedId].LinkRect then
              local rr = FX[linkedId].LinkRect
              im.DrawList_AddRect(FDL, rr.L - 2, rr.T - 2, rr.R + 2, rr.B + 2, glowClr, 2, nil, 3)
            end
          end
        end
        offset = offset + LN
        -- (Removed redundant extra folder icon draw inside link block)
        SL(nil, 0)
        if HoveredLinkedFXID then
          if FX[HoveredLinkedFXID].Link == fxID then
            local x, y = im.GetCursorScreenPos(ctx)
            local x = x - LN / 2
            local y2
            if LinkCablePosY > y then
              y = y + LN * 1.3
              y2 = LinkCablePosY - LN * 1.5
            else
              y2 = LinkCablePosY
            end
            im.DrawList_AddLine(FDL, LinkCablePosX, y2, LinkCablePosX, y, (Clr and Clr.LinkCable) or 0xffffffff, Patch_Thick)
            -- also glow both link icons when hovering a linked FX
            do
              local base = (Clr and Clr.LinkCable) or 0xffffffff
              local glowClr = deriveHover(base)
              local rrSelf = FX[fxID] and FX[fxID].LinkRect
              if rrSelf then
                im.DrawList_AddRect(FDL, rrSelf.L - 2, rrSelf.T - 2, rrSelf.R + 2, rrSelf.B + 2, glowClr, 2, nil, 3)
              end
              local rrOther = FX[HoveredLinkedFXID] and FX[HoveredLinkedFXID].LinkRect
              if rrOther then
                im.DrawList_AddRect(FDL, rrOther.L - 2, rrOther.T - 2, rrOther.R + 2, rrOther.B + 2, glowClr, 2, nil, 3)
              end
            end
          end
        end
      end
    end
    -- Retrieve offline state early
    local FX_Is_Offline = r.TrackFX_GetOffline(Track, fx)

    local function Push_clr_and_styles()
      local pushCount = 0

      rv, fxType = r.TrackFX_GetNamedConfigParm(Track, fx, 'fx_type')
      local hoverColor
      local baseColor
      if fxType == 'VST3i' or fxType =='VSTi' or fxType == 'AUi' then 
        baseColor = Clr.VSTi
        im.PushStyleColor(ctx, im.Col_Button, baseColor)
        im.PushStyleColor(ctx, im.Col_ButtonActive,  deriveActive(baseColor))
        pushCount = pushCount + 2
        hoverColor = deriveHover(baseColor)
      else 
        baseColor = Clr.Buttons
        im.PushStyleColor(ctx, im.Col_Button, baseColor)
        im.PushStyleColor(ctx, im.Col_ButtonActive,  deriveActive(baseColor))
        pushCount = pushCount + 2
        hoverColor = deriveHover(baseColor)
      end
      
      -- Get track GUID and check if FX is selected via marquee selection
      local trackGUID = r.GetTrackGUID(Track)
      local isSelected = IsFXSelected(trackGUID, fx)
      
      -- Apply dark-red scheme for offline FX (push styles first)
      if FX_Is_Offline then
        local offlineBase = 0x551111ff
        -- Don't change color for selected offline FX (will use stripes instead)
        im.PushStyleColor(ctx, im.Col_Button, offlineBase)
        -- Disable hover highlighting during marquee selection even for offline FX
        if MarqueeSelection and MarqueeSelection.isActive then
          im.PushStyleColor(ctx, im.Col_ButtonHovered, offlineBase)
        else
          im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x771111ff)
        end
        im.PushStyleColor(ctx, im.Col_ButtonActive,  0x991111ff)
        im.PushStyleColor(ctx, im.Col_Text,          0xdd4444ff)
        pushCount = pushCount + 4
      else
        -- For non-offline FX, don't change color for selected (will use stripes instead)
        -- Disable hover highlighting when marquee selection is active
        if MarqueeSelection and MarqueeSelection.isActive then
          -- Use button color instead of hover color to disable highlighting
          im.PushStyleColor(ctx, im.Col_ButtonHovered, baseColor)
        else
          im.PushStyleColor(ctx, im.Col_ButtonHovered, hoverColor)
        end
        pushCount = pushCount + 1
      end

      im.PushStyleColor(ctx, im.Col_Border, 0x00000000)
      pushCount = pushCount + 1
      
      return pushCount
    end
    local styleColorPushCount = Push_clr_and_styles()

    -- Now push font (after style) so popping order remains: font first, then styles
    -- Use Andale Mono font matching the current font size
    local lineHeight = im.GetTextLineHeight(ctx)
    local andaleMonoFont = Font_Andale_Mono_13 -- Default fallback
    -- Match font size based on line height (approximate: line height ≈ font size * 1.2-1.3)
    if lineHeight <= 8 then andaleMonoFont = Font_Andale_Mono_6
    elseif lineHeight <= 9 then andaleMonoFont = Font_Andale_Mono_7
    elseif lineHeight <= 10 then andaleMonoFont = Font_Andale_Mono_8
    elseif lineHeight <= 11 then andaleMonoFont = Font_Andale_Mono_9
    elseif lineHeight <= 12 then andaleMonoFont = Font_Andale_Mono_10
    elseif lineHeight <= 13 then andaleMonoFont = Font_Andale_Mono_11
    elseif lineHeight <= 14 then andaleMonoFont = Font_Andale_Mono_12
    elseif lineHeight <= 15 then andaleMonoFont = Font_Andale_Mono_13
    elseif lineHeight <= 16 then andaleMonoFont = Font_Andale_Mono_14
    elseif lineHeight <= 17 then andaleMonoFont = Font_Andale_Mono_15
    else andaleMonoFont = Font_Andale_Mono_16
    end
    im.PushFont(ctx, andaleMonoFont)

    local retval,  renamed = r.TrackFX_GetNamedConfigParm(Track, fx, 'renamed_name')
    if renamed~='' then ShownName = renamed .. ' ('.. ShownName..')' end 
    if CheckIf_FX_Special(Track,fx) then  
      ShownName = ''
    end

    -- Optionally shorten label: remove bracketed segments for display
    if OPEN and OPEN.ShortenFXNames and ShownName and ShownName ~= '' then
      local s = ShownName
      s = s:gsub('%b()', ''):gsub('%b[]', ''):gsub('%b{}', '')
      s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
      ShownName = s
    end

    -- Visual improvements: rounded corners and better border
    im.PushStyleVar(ctx, im.StyleVar_FrameBorderSize, 1)
    im.PushStyleVar(ctx, im.StyleVar_FrameRounding, 3) -- Subtle rounded corners
      local autoBtnW = 0
      local hasAuto = FX_HasAutomation(Track, fx)
      if (not IsDeleting) and hasAuto and Img.Graph then
        local txtH = im.GetTextLineHeight(ctx)
        local pad = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
        local padY = (type(pad) == 'table' and (pad.y or 6)) or (type(pad) == 'number' and pad) or 6
        local iconSz = math.max(12, math.floor(txtH + padY * 2 + 0.5))
        autoBtnW = iconSz
        -- derive tint by current envelope state
        local _, anyVisible, anyBypassed = FX_AnyEnvelopeStates(Track, fx)
        local tint
        if anyBypassed then
          tint = 0x020402ff  -- keep user's dark gray tone
        elseif anyVisible then
          tint = 0xffffffff  -- white when lanes shown
        else
          tint = 0x999999ff  -- gray when hidden
        end

        if im.ImageButton(ctx, '##Auto'..t..fx, Img.Graph, iconSz, iconSz, nil, nil, nil, nil, nil, tint) then
          if Mods == Alt then
            -- Alt+click: Delete all FX envelopes using actions
            r.Undo_BeginBlock()
            r.PreventUIRefresh(1)
            
            local paramCnt = r.TrackFX_GetNumParams(Track, fx)
            for p = 0, paramCnt - 1 do
              local env = r.GetFXEnvelope(Track, fx, p, false)
              if env then
                r.SetCursorContext(2, env)
                r.Main_OnCommand(40065, 0) -- Delete selected envelope
              end
            end
            
            r.PreventUIRefresh(-1)
            r.Undo_EndBlock('Delete FX envelopes', -1)
            r.TrackList_AdjustWindows(false)
          elseif Mods == Shift then
            FX_ToggleAllEnvelopesActive(Track, fx)
          else
            FX_ToggleAllEnvelopesVisible(Track, fx)
          end
        end
        if im.IsItemHovered(ctx) then
          SetHelpHint('LMB = Toggle Envelope Visibility', 'Shift+LMB = Toggle Envelope Active/Bypass', 'Alt+LMB = Delete All Envelopes')
        end
        -- Store envelope icon rect so container lines can end before it
        if fxID then
          local envL, envT = im.GetItemRectMin(ctx)
          local envR, envB = im.GetItemRectMax(ctx)
          FX[fxID] = FX[fxID] or {}
          FX[fxID].EnvelopeRect = { L = envL, T = envT, R = envR, B = envB }
        end
        im.SameLine(ctx, 0, 0)
      end

      -- Before drawing the button, capture rect for block selection highlight
      local blockRectStartX, blockRectStartY = im.GetCursorScreenPos(ctx)
      -- Determine per-item width (handle parallel groups)
      local btnWidthForThis = BtnSz - offset - autoBtnW
      local peers = GetParallelGroupPeers(fx)
      local groupCols = #peers
      if groupCols > 1 then
        local spacing = 6
        -- Use full available width for the row (top-level: FXPane_W; inside containers: BtnSz)
        local rowW = container and BtnSz or FXPane_W
        local cellSlotW = (rowW - (groupCols - 1) * spacing) / groupCols
        -- For parallel rows, Wet/Dry knob is hidden, so do not subtract its width
        btnWidthForThis = math.max(50, cellSlotW - offset - autoBtnW)
      end

      -- Handle renaming mode: show input field with consistent width and styling
      local styleVarsPopped = false
      if Changing_FX_Name == tostring(Track)..'  '.. fx then
        -- Check if FX is selected for text color
        local trackGUID = r.GetTrackGUID(Track)
        local isSelected = IsFXSelected(trackGUID, fx)
        -- Use button background color for input field background
        local btnBgColor = getClr(im.Col_Button)
        im.PushStyleColor(ctx, im.Col_FrameBg, btnBgColor)
        im.PushStyleColor(ctx, im.Col_FrameBgHovered, getClr(im.Col_ButtonHovered))
        im.PushStyleColor(ctx, im.Col_FrameBgActive, getClr(im.Col_ButtonActive))
        -- Use white text color
        im.PushStyleColor(ctx, im.Col_Text, 0xffffffff)
        -- Set cursor color to bright white/cyan for better visibility
        im.PushStyleColor(ctx, r.ImGui_Col_InputTextCursor(), 0x00ffffff)
        -- Set placeholder/hint text color to white with transparency
        im.PushStyleColor(ctx, im.Col_TextDisabled, 0xffffff88)
        im.SetNextItemWidth(ctx, btnWidthForThis)
        local retval, renamed = r.TrackFX_GetNamedConfigParm(Track, fx, 'renamed_name')
        -- Create placeholder text from displayed name, removing renamed part in parentheses
        local placeholderName = ShownName
        -- Remove the renamed part in parentheses if it exists (format: "renamed (original)")
        if placeholderName and placeholderName:match('%s+%(') then
          placeholderName = placeholderName:match('^(.+)%s+%(') or placeholderName
        end
        -- Remove any remaining parentheses content and clean up
        if placeholderName then
          placeholderName = placeholderName:gsub('%b()', ''):gsub('%b[]', ''):gsub('%b{}', '')
          placeholderName = placeholderName:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        end
        im.SetKeyboardFocusHere(ctx)
        rv, Txt = im.InputTextWithHint(ctx, '##RenameFX' .. tostring(Track) .. '_' .. fx, placeholderName or Name, Txt or renamed or Name, im.InputTextFlags_EnterReturnsTrue)
        im.PopStyleColor(ctx, 6) -- Pop input field colors (Text + Cursor + TextDisabled + 3 FrameBg colors)
        -- Finish renaming when Enter is pressed or item is deactivated
        if rv or im.IsItemDeactivated(ctx) then
          r.TrackFX_SetNamedConfigParm(Track, fx, 'renamed_name', Txt)
          Txt = nil
          Changing_FX_Name = nil
        end
        -- Pop FrameBorderSize and FrameRounding style vars
        im.PopStyleVar(ctx, 2) -- FrameBorderSize and FrameRounding
        styleVarsPopped = true
      else
      -- Store the button click state
      -- If this is currently being dragged vertically, or if it's selected and another selected FX is being dragged, draw it half-transparent
      local isDraggedFX = (MouseDragDir == 'Vert' and DraggingTrack == t and DraggingFX_Index == fx)
      local isSelectedAndMultiDragging = false
      if not isDraggedFX and MouseDragDir == 'Vert' and DraggingFX_Index ~= nil and DraggingTrack == t then
        local trackGUID = r.GetTrackGUID(Track)
        local isSelected = IsFXSelected(trackGUID, fx)
        if isSelected then
          local sel = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
          if sel and #sel > 1 then
            isSelectedAndMultiDragging = true
          end
        end
      end
      if isDraggedFX or isSelectedAndMultiDragging then im.PushStyleVar(ctx, im.StyleVar_Alpha, 0.5) end
      -- If selected, make text bold and italic
      local pushedSelFont
      do
        local trackGUID = r.GetTrackGUID(Track)
        if IsFXSelected(trackGUID, fx) then
          -- Use bold+italic font matching the current font size
          -- Get current font size by checking text line height and matching to closest available size
          local lineHeight = im.GetTextLineHeight(ctx)
          local boldItalicFont = Font_Andale_Mono_13_BI -- Default fallback
          -- Match font size based on line height (approximate: line height ≈ font size * 1.2-1.3)
          if lineHeight <= 8 then boldItalicFont = Font_Andale_Mono_6_BI
          elseif lineHeight <= 9 then boldItalicFont = Font_Andale_Mono_7_BI
          elseif lineHeight <= 10 then boldItalicFont = Font_Andale_Mono_8_BI
          elseif lineHeight <= 11 then boldItalicFont = Font_Andale_Mono_9_BI
          elseif lineHeight <= 12 then boldItalicFont = Font_Andale_Mono_10_BI
          elseif lineHeight <= 13 then boldItalicFont = Font_Andale_Mono_11_BI
          elseif lineHeight <= 14 then boldItalicFont = Font_Andale_Mono_12_BI
          elseif lineHeight <= 15 then boldItalicFont = Font_Andale_Mono_13_BI
          elseif lineHeight <= 16 then boldItalicFont = Font_Andale_Mono_14_BI
          elseif lineHeight <= 17 then boldItalicFont = Font_Andale_Mono_15_BI
          else boldItalicFont = Font_Andale_Mono_16_BI
          end
          im.PushFont(ctx, boldItalicFont)
          pushedSelFont = true
        end
      end
      -- AB Level Matching special-case rendering
      local lowerName = (FullName or Name or ''):lower()
      local isABSource = (lowerName:find('ab level matching') and lowerName:find('source')) and true or false
      local isABControl = (lowerName:find('ab level matching') and lowerName:find('control')) and true or false
      if isABSource then
        local display = 'Loudness Matching'
        local abWidth = btnWidthForThis + (WetDryKnobSz or 0)*2 + 2
        -- Orange text for source label
        local padX, padY = 6, 6
        local h = im.GetTextLineHeight(ctx) + padY * 2
        local halfH = math.max(10, math.floor(h * 0.5))
        -- If delete animation active, shrink height and advance
        local anim = FXDeleteAnim and FXDeleteAnim[fxID]
        local drawHalfH = halfH
        if anim and anim.progress and anim.progress < 1 then
          drawHalfH = math.max(0, math.floor(halfH * (1 - anim.progress)))
        end

        im.PushStyleColor(ctx, im.Col_Text, 0xE0690FFF)
        im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
        
--[[         im.PushStyleVar(ctx, im.StyleVar_FrameHeight, 0.1)
 ]]        rv = im.Button(ctx, display .. '##' .. fx, abWidth, drawHalfH)
        im.PopStyleColor(ctx, 2)

        -- Trigger delete on Alt+release inside this row
        if Mods == Alt and im.IsItemHovered(ctx) and im.IsMouseReleased(ctx, 0) then
          if not (anim and anim.progress and anim.progress < 1) then
            FXDeleteAnim = FXDeleteAnim or {}
            FXDeleteAnim[fxID] = { progress = 0, track = Track, index = fx, delay = 1 }
            anim = FXDeleteAnim[fxID]
          end
        end

        -- Advance animation and queue deletion
        if anim and anim.progress and anim.progress < 1 then
          -- one-frame delay to avoid same-frame flash
          if anim.delay then
            anim.delay = nil
          else
            -- blinking overlay over the AB Source row while shrinking
            local Ls, Ts = im.GetItemRectMin(ctx)
            local Rs, Bs = im.GetItemRectMax(ctx)
            local tnow = (r.time_precise and r.time_precise()) or 0
            local pulse = (math.sin(tnow * 6.0) + 1) * 0.5
            local red   = 0.5 + 0.5 * pulse
            local alpha = math.max(0, math.min(1, (anim.progress or 0)))
            local fill  = im.ColorConvertDouble4ToU32(red, 0.0, 0.0, alpha)
            local dl    = im.GetWindowDrawList(ctx)
            im.DrawList_AddRectFilled(dl, Ls, Ts, Rs, Bs, fill)
            anim.progress = math.min(1, (anim.progress or 0) + (DELETE_ANIM_STEP or 0.22))
          end
          if anim.progress >= 1 and anim.track then
            PendingDeleteGUIDs = PendingDeleteGUIDs or {}
            PendingDeleteGUIDs[#PendingDeleteGUIDs+1] = { guid = fxID, track = anim.track, index = anim.index }
          end
        end

        -- Record AB block start rect and text opening; top line will be drawn when Control renders
        do
          local Ls, Ts = im.GetItemRectMin(ctx)
          local Rs, Bs = im.GetItemRectMax(ctx)
          local padX, padY = 6, 6
          local pad = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
          if pad ~= nil then
            if type(pad) == 'number' then padX = pad; padY = pad
            else padX = pad.x or padX; padY = pad.y or padY end
          end
          local textW = im.CalcTextSize(ctx, display) or 0
          local openStart = Ls + padX
          local openEnd = openStart + textW
          ABOpenRect = { L = Ls, T = Ts, R = Ls + abWidth, openStart = openStart, openEnd = openEnd, midY = (Ts + Bs) * 0.5 }
        end
      elseif isABControl then
        -- Draw a half-height control row: behaves like a button for opening FX,
        -- plus an inner value button that toggles Auto Gain (RMS) bypass.
        local txtH = im.GetTextLineHeight(ctx)
        local padX, padY = 6, 6
        do
          local pad = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
          if pad ~= nil then
            if type(pad) == 'number' then padX = pad; padY = pad
            else padX = pad.x or padX; padY = pad.y or padY end
          end
        end
        local h = txtH + padY * 2
        local halfH = math.max(10, math.floor(h * 0.5))
        local Lc, Tc = im.GetCursorScreenPos(ctx)
        local abWidth = btnWidthForThis + (WetDryKnobSz or 0)*2 + 2
        -- If delete animation active, shrink and bypass sub-controls
        do
          local anim = FXDeleteAnim and FXDeleteAnim[fxID]
          if anim and anim.progress and anim.progress < 1 then
            local drawHalfH = math.max(0, math.floor(halfH * (1 - anim.progress)))
            im.SetCursorScreenPos(ctx, Lc, Tc)
            im.PushStyleColor(ctx, im.Col_Text, 0xE0690FFF)
            im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
            im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000000)
            im.PushStyleColor(ctx, im.Col_ButtonActive, 0xE0690F22)
            im.Button(ctx, '##ABCtrlBtn'..tostring(fx), abWidth, drawHalfH)
            im.PopStyleColor(ctx, 4)
            -- advance and queue
            do
              local Ls, Ts = im.GetItemRectMin(ctx)
              local Rs, Bs = im.GetItemRectMax(ctx)
              local tnow = (r.time_precise and r.time_precise()) or 0
              local pulse = (math.sin(tnow * 6.0) + 1) * 0.5
              local red   = 0.5 + 0.5 * pulse
              local alpha = math.max(0, math.min(1, (anim.progress or 0)))
              local fill  = im.ColorConvertDouble4ToU32(red, 0.0, 0.0, alpha)
              local dl    = im.GetWindowDrawList(ctx)
              im.DrawList_AddRectFilled(dl, Ls, Ts, Rs, Bs, fill)
            end
            anim.progress = math.min(1, (anim.progress or 0) + (DELETE_ANIM_STEP or 0.22))
            if anim.progress >= 1 and anim.track then
              PendingDeleteGUIDs = PendingDeleteGUIDs or {}
              PendingDeleteGUIDs[#PendingDeleteGUIDs+1] = { guid = fxID, track = anim.track, index = anim.index }
            end
            -- Skip the rest of AB Control rendering while deleting
            goto afterABControl
          end
        end
        -- We'll render the value button first, then place the main invisible button on top
        local hoveredMain = false
        local clickedMain = false
        -- Base background kept disabled per your change
        --im.DrawList_AddRectFilled(WDL, Lc, Tc, Lc + abWidth, Tc + halfH, getClr(im.Col_Button))
        -- Fetch 'post gain dB' parameter value and build value button rect
        local function findParamIdxByName(trackRef, fxIdx, want)
          local np = r.TrackFX_GetNumParams(trackRef, fxIdx) or 0
          local wlow = want:lower()
          for p = 0, np - 1 do
            local rvn, pname = r.TrackFX_GetParamName(trackRef, fxIdx, p)
            pname = (pname or ''):lower()
            if pname:find(wlow, 1, true) then return p end
          end
          return -1
        end
        local pidx = findParamIdxByName(Track, fx, 'post gain')
        -- Auto gain RMS parameter fixed to index 17 (0-based) when present
        local autoIdx = 17
        do
          local np = r.TrackFX_GetNumParams(Track, fx) or 0
          if not autoIdx or autoIdx < 0 or autoIdx >= np then autoIdx = -1 end
        end
        local valTxt = ''
        if pidx and pidx >= 0 then
          local _, fmt = r.TrackFX_GetFormattedParamValue(Track, fx, pidx)
          valTxt = fmt or ''
        end
        local tw = (valTxt ~= '' and (im.CalcTextSize(ctx, valTxt) or 0)) or 0
        local btnW = tw + padX * 2
        local btnH = math.max(halfH - 4, txtH + padY)
        local cx = Lc + (abWidth - btnW) * 0.5
        local cy = Tc + (halfH - btnH) * 0.5
        local vx1, vy1, vx2, vy2 = cx, cy, cx + btnW, cy + btnH
        -- Draw main control button (styled same as Source) first
        im.SetCursorScreenPos(ctx, Lc, Tc)
        im.PushStyleColor(ctx, im.Col_Text, 0xE0690FFF)
        im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
        im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000000)
        im.PushStyleColor(ctx, im.Col_ButtonActive, 0xE0690F22)
        local ctrlClicked = im.Button(ctx, '##ABCtrlBtn'..tostring(fx), abWidth, halfH)
        im.PopStyleColor(ctx, 4)
        hoveredMain = im.IsItemHovered(ctx)
        -- Now draw the value button on top and handle its clicks
        local hoveredVal = im.IsMouseHoveringRect(ctx, vx1, vy1, vx2, vy2)
        -- Click-capture to prevent click-through: capture on press, act on release
        F.ABValCapture = F.ABValCapture or false
        -- Drag-capture for manual Post Gain (param 18)
        F.ABValDrag = F.ABValDrag or { active = false }
        -- compute post gain index (prefer 18, fallback to found index)
        local postGainIdx = 18
        do
          local np = r.TrackFX_GetNumParams(Track, fx) or 0
          if postGainIdx < 0 or postGainIdx >= np then postGainIdx = (pidx and pidx >= 0 and pidx) or -1 end
        end
        if hoveredVal and im.IsMouseClicked(ctx, 0) then
          F.ABValCapture = true
          local _, startY = im.GetMousePos(ctx)
          local startVal = (postGainIdx and postGainIdx >= 0) and (r.TrackFX_GetParamNormalized(Track, fx, postGainIdx) or 0) or 0
          F.ABValDrag = { active = true, startY = startY, startVal = startVal, isDrag = false, postIdx = postGainIdx }
        end
        if F.ABValDrag and F.ABValDrag.active and im.IsMouseDown(ctx, 0) then
          -- Suppress main hover/click while dragging value
          hoveredMain = false; ctrlClicked = false; clickedMain = false; PreventFXReorder = true
          local _, my = im.GetMousePos(ctx)
          local dy = (F.ABValDrag.startY or my) - my
          if math.abs(dy) > 2 then F.ABValDrag.isDrag = true end
          if F.ABValDrag.isDrag and F.ABValDrag.postIdx and F.ABValDrag.postIdx >= 0 then
            local scale = (im.GetKeyMods(ctx) == im.Mod_Shift) and 0.001 or 0.005
            local newVal = (F.ABValDrag.startVal or 0) + dy * scale
            if newVal < 0 then newVal = 0 elseif newVal > 1 then newVal = 1 end
            r.TrackFX_SetParamNormalized(Track, fx, F.ABValDrag.postIdx, newVal)
          end
        end
        -- While capturing (click or drag), suppress main hover/click
        if F.ABValCapture or (F.ABValDrag and F.ABValDrag.active) then hoveredMain = false; ctrlClicked = false; clickedMain = false end
        -- If not capturing, main click stands
        if not F.ABValCapture and not (F.ABValDrag and F.ABValDrag.active) then clickedMain = ctrlClicked end
        local autoBypassed = false
        if autoIdx and autoIdx >= 0 then
          local aVal = r.TrackFX_GetParamNormalized(Track, fx, autoIdx) or 0
          autoBypassed = (aVal < 0.5)
        end
      local bg = --[[ autoBypassed and getClr(im.Col_ButtonHovered) or ]] getClr(im.Col_Button)
        if hoveredVal then bg = getClr(im.Col_ButtonActive) end
        --im.DrawList_AddRectFilled(WDL, vx1, vy1, vx2, vy2, bg)
        do
          local isZero = (valTxt == '0.0' or valTxt == '0.00' or valTxt == '0 dB' or valTxt == '0.0 dB' or valTxt == '0.00 dB' or valTxt == '+0.0 dB' or valTxt == '+0.00 dB')
          local txtCol = autoBypassed and 0xFF7711FF or (isZero and 0x999999ff or 0xE0690FFF)
          local tx = Lc + (abWidth - tw) * 0.5
          local ty = Tc + (halfH - txtH) * 0.5
          im.DrawList_AddText(WDL, tx, ty, txtCol, valTxt)
          -- If Auto Gain RMS (param 17) is exactly 0, highlight the text's four corners
          if autoIdx and autoIdx >= 0 then
            local aVal = r.TrackFX_GetParamNormalized(Track, fx, autoIdx) or 0
            if aVal <= 0.001 then
              local textL = tx
              local textT = ty
              local textR = tx + tw
              local textB = ty + txtH
              -- Use same color as orange accent, semi-opaque
              local cornerClr = 0xE0690FFF
              -- Arguments: clr, ?, ?, L, T, R, B, h, w, Hscale, Vscale, mode, drawlist
              -- We pass explicit rect and draw list; keep scales at 1
              local p = 6
              HighlightSelectedItem(nil, cornerClr, 0, textL-p, textT, textR+p, textB-2, txtH, tw, 4,4, 'Manual', WDL)
            end
          end
        end
        -- Toggle on mouse release if we started capture inside value rect
        if F.ABValCapture and im.IsMouseReleased(ctx, 0) then
          if hoveredVal and autoIdx and autoIdx >= 0 and not (F.ABValDrag and F.ABValDrag.isDrag) then
            local aVal = r.TrackFX_GetParamNormalized(Track, fx, autoIdx) or 0
            local newVal = (aVal < 0.4) and 0.5 or 0
            r.TrackFX_SetParamNormalized(Track, fx, autoIdx, newVal)
          end
          -- consume click; do not let main button fire this frame
          clickedMain = false
          F.ABValCapture = false
          if F.ABValDrag then F.ABValDrag.active = false; F.ABValDrag.isDrag = false end
          PreventFXReorder = nil
        end
        -- If Alt is held and we released inside main ctrl area, treat as delete trigger
        if Mods == Alt and (hoveredMain or im.IsItemHovered(ctx)) and im.IsMouseReleased(ctx, 0) then
          FXDeleteAnim = FXDeleteAnim or {}
          FXDeleteAnim[fxID] = FXDeleteAnim[fxID] or { progress = 0, track = Track, index = fx }
        end
        -- If either main or value area hovered, apply hover overlay across the row
        if hoveredMain or hoveredVal then
          --im.DrawList_AddRectFilled(WDL, Lc, Tc, Lc + abWidth, Tc + halfH, getClr(im.Col_ButtonHovered))
        end
        -- If a Source was previously seen, draw the enclosing rectangle now
        if ABOpenRect then
          local _, Btm = im.GetItemRectMax(ctx)
          local Lr, Tr, Rr = ABOpenRect.L, ABOpenRect.T, ABOpenRect.R
          -- Use centered y positions: top at source text mid, bottom at control mid
          local topY = ABOpenRect.midY or Tr
          local bottomY = Tc + halfH * 0.5
          local col = 0xE0690FFF
          local thick = 1.0
          -- Left, Right verticals
          im.DrawList_AddLine(WDL, Lr, topY, Lr, bottomY, col, thick)
          im.DrawList_AddLine(WDL, Rr, topY, Rr, bottomY, col, thick)
          -- Bottom with centered opening near mid X (use text width as reference)
          local midX = (Lr + Rr) * 0.5
          local gapPad = 2
          local textW = math.max(0, (ABOpenRect.openEnd or midX) - (ABOpenRect.openStart or midX))
          local halfGap = textW * 0.5 + gapPad
          if (midX - halfGap) > Lr then im.DrawList_AddLine(WDL, Lr, bottomY, midX - halfGap, bottomY, col, thick) end
          if (midX + halfGap) < Rr then im.DrawList_AddLine(WDL, midX + halfGap, bottomY, Rr, bottomY, col, thick) end
          -- Top with centered opening (same behavior as bottom)
          if (midX - halfGap) > Lr then im.DrawList_AddLine(WDL, Lr, topY, midX - halfGap, topY, col, thick) end
          if (midX + halfGap) < Rr then im.DrawList_AddLine(WDL, midX + halfGap, topY, Rr, topY, col, thick) end
          ABOpenRect = nil
        end
        -- For main control area click, open FX like a normal button
        if clickedMain then rv = true else rv = false end
        ::afterABControl::
      else
        -- Apply delete shrink animation by reducing frame height when active for this FX GUID
        do
          local guid = r.TrackFX_GetFXGUID(Track, fx)
          local anim = guid and FXDeleteAnim and FXDeleteAnim[guid]
          if anim and anim.progress and anim.progress < 1 then
            local txtH = im.GetTextLineHeight(ctx)
            local pad = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
            local padX = (type(pad) == 'table' and (pad.x or 6)) or (type(pad) == 'number' and pad) or 6
            local padY = (type(pad) == 'table' and (pad.y or 6)) or (type(pad) == 'number' and pad) or 6
            local fullH = txtH + padY * 2
            local h = math.max(0, math.floor(fullH * (1 - anim.progress)))
            im.PushStyleVar(ctx, im.StyleVar_FramePadding, padX, padY)
            im.PushStyleVar(ctx, im.StyleVar_FrameBorderSize, 1)
            im.PushStyleVar(ctx, im.StyleVar_FrameRounding, 3) -- Consistent rounded corners
            rv = im.Button(ctx, ShownName .. '##' .. fx, btnWidthForThis, h)
            im.PopStyleVar(ctx, 3)
            -- advance animation
            do
              local Ls, Ts = im.GetItemRectMin(ctx)
              local Rs, Bs = im.GetItemRectMax(ctx)
              local tnow = (r.time_precise and r.time_precise()) or 0
              local pulse = (math.sin(tnow * 6.0) + 1) * 0.5
              local red   = 0.5 + 0.5 * pulse
              local alpha = math.max(0, math.min(1, (anim.progress or 0)))
              local fill  = im.ColorConvertDouble4ToU32(red, 0.0, 0.0, alpha)
              local dl    = im.GetWindowDrawList(ctx)
              im.DrawList_AddRectFilled(dl, Ls, Ts, Rs, Bs, fill)
            end
            anim.progress = math.min(1, (anim.progress or 0) + (DELETE_ANIM_STEP or 0.22))
            if anim.progress >= 1 and anim.track then
              -- queue deletion at end of frame
              PendingDeleteGUIDs = PendingDeleteGUIDs or {}
              PendingDeleteGUIDs[#PendingDeleteGUIDs+1] = { guid = guid, track = anim.track, index = anim.index }
            end
          else
            -- Regular button with visual improvements
            rv = im.Button(ctx, ShownName .. '##' .. fx, btnWidthForThis)
          end
        end
      end
      -- Capture button rect for selected FX stripes before popping font
      local btnRectForStripes = nil
      local btnRectForHover = nil
      local btnRectForCreateAnim = nil
      do
        local L, T = im.GetItemRectMin(ctx)
        local R, B = im.GetItemRectMax(ctx)
        local trackGUID = r.GetTrackGUID(Track)
        if IsFXSelected(trackGUID, fx) then
          btnRectForStripes = { L = L, T = T, R = R, B = B }
        end
        -- Capture button rect for hover glow effect
        if im.IsItemHovered(ctx) and not (MarqueeSelection and MarqueeSelection.isActive) then
          btnRectForHover = { L = L, T = T, R = R, B = B }
        end
        -- Capture button rect for creation animation
        if CreatingAnim and (CreatingAnim.progress or 0) < 1 then
          btnRectForCreateAnim = { L = L, T = T, R = R, B = B }
        end
      end
      if pushedSelFont then im.PopFont(ctx) end
      local blockRectEndX, blockRectEndY = im.GetCursorScreenPos(ctx)
      if isDraggedFX or isSelectedAndMultiDragging then im.PopStyleVar(ctx) end
      
      -- Draw subtle hover glow effect
      if btnRectForHover then
        local dl = im.GetWindowDrawList(ctx)
        -- Subtle outer glow for better visual feedback
        im.DrawList_AddRect(dl, btnRectForHover.L - 1, btnRectForHover.T - 1, btnRectForHover.R + 1, btnRectForHover.B + 1, 0xffffff20, 3, 0, 1.0)
      end
      
      -- Apply creation animation (flash/fade-in)
      if btnRectForCreateAnim and CreatingAnim and (CreatingAnim.progress or 0) < 1 then
        local dl = im.GetWindowDrawList(ctx)
        
        -- Animation: Flash white/bright and fade out
        local animAlpha = 0.6 * (1 - (CreatingAnim.progress or 0))
        local col = im.ColorConvertDouble4ToU32(1, 1, 1, animAlpha)
        
        im.DrawList_AddRectFilled(dl, btnRectForCreateAnim.L, btnRectForCreateAnim.T, btnRectForCreateAnim.R, btnRectForCreateAnim.B, col, im.GetStyleVar(ctx, im.StyleVar_FrameRounding))
        
        CreatingAnim.progress = (CreatingAnim.progress or 0) + (FX_CREATE_ANIM_STEP or 0.05)
        if CreatingAnim.progress >= 1 then
          FXCreateAnim[fxID] = nil
        end
      end
      
      -- Draw diagonal stripes for selected FXs (thicker than drag stripes)
      if btnRectForStripes then
        local dl = im.GetWindowDrawList(ctx)
        -- Use thicker stripes than drag (drag uses stripeWidth=2, gap=2; we use stripeWidth=4, gap=2)
        DrawDiagonalStripes(dl, btnRectForStripes.L, btnRectForStripes.T, btnRectForStripes.R, btnRectForStripes.B, 0xffffff30, 4, 2, 1)
        -- Add subtle border highlight for selected items
        im.DrawList_AddRect(dl, btnRectForStripes.L, btnRectForStripes.T, btnRectForStripes.R, btnRectForStripes.B, 0xffffff50, 0, 0, 1.5)
      end
      
      -- Track container right-click movement (must be outside hover check so it works during drag)
      if isContainer and im.IsMouseDown(ctx, 1) then
        if not ContainerRightClickStart[fxID] then
          -- Check if mouse is within button bounds to start tracking
          local btnL, btnT = im.GetItemRectMin(ctx)
          local btnR, btnB = im.GetItemRectMax(ctx)
          local mx, my = im.GetMousePos(ctx)
          if mx >= btnL and mx <= btnR and my >= btnT and my <= btnB then
            local now = r.time_precise()
            ContainerRightClickStart[fxID] = { x = mx, y = my, time = now }
            ContainerRightClickMaxMove[fxID] = 0 -- Track max distance moved
          end
        elseif ContainerRightClickStart[fxID] then
          -- Update max distance moved while mouse is down (even if not hovering)
          local mx, my = im.GetMousePos(ctx)
          local dx = math.abs(mx - ContainerRightClickStart[fxID].x)
          local dy = math.abs(my - ContainerRightClickStart[fxID].y)
          local maxDist = math.max(dx, dy)
          local currentMax = ContainerRightClickMaxMove[fxID] or 0
          if maxDist > currentMax then
            ContainerRightClickMaxMove[fxID] = maxDist
          end
        end
      end
      
      -- Check for expand track shortcut key press when hovering over the FX button
      if im.IsItemHovered(ctx) then
        local expandShortcut = Shortcuts and Shortcuts.ExpandTrack
        local keyToCheck = expandShortcut and expandShortcut.key or im.Key_E
        local modsToCheck = expandShortcut and expandShortcut.mods or 0
        
        if im.IsKeyPressed(ctx, keyToCheck) and im.GetKeyMods(ctx) == modsToCheck then
          ExpandTrackHeight(Track)
        end
        if Mods == Alt then 
          HighlightItem(0x00000044, WDL, 0x991111ff)
        end
        -- Show hint text for main FX button
        if isContainer then
          SetHelpHint('LMB = Open FX Window', 'RMB = Toggle Container Expand/Collapse', 'Alt+RMB = Rename FX', 'Drag Vertically = Reorder FX', 'Drag Horizontally = Adjust Wet/Dry', 'Alt+LMB = Delete FX')
        else
          SetHelpHint('LMB = Open FX Window', 'Alt+RMB = Rename FX', 'Drag Vertically = Reorder FX', 'Drag Horizontally = Adjust Wet/Dry', 'Alt+LMB = Delete FX')
        end
      end
      -- Toggle container collapse/expand with right-click (ignore key modifiers, except Alt)
      -- Only toggle if: quick click (within time threshold) AND no significant movement AND marquee selection not active
      -- Otherwise, let marquee selection handle it
      -- Check for mouse release (not IsItemClicked, which might fire at wrong time)
      if isContainer and ContainerRightClickStart[fxID] and im.IsMouseReleased(ctx, 1) and (not OPEN or not OPEN.ShowFullSizeHiddenParents) then
        -- NEVER toggle if marquee selection is active
        local shouldToggle = false
        -- Check if Alt is held - if so, don't toggle collapse/uncollapse
        local Mods = im.GetKeyMods(ctx)
        if Mods == Alt then
          -- Alt + right click: don't toggle collapse/uncollapse
          shouldToggle = false
        elseif MarqueeSelection and MarqueeSelection.isActive then
          -- Marquee selection is currently active, don't toggle
          shouldToggle = false
        else
          -- Use the maximum distance moved during the drag (tracked while mouse was down)
          local maxMove = ContainerRightClickMaxMove[fxID] or 0
          local releaseTime = r.time_precise()
          local timeElapsed = releaseTime - ContainerRightClickStart[fxID].time
          
          -- Only toggle if: quick release AND no significant movement
          if timeElapsed < CONTAINER_CLICK_TIME_THRESHOLD and 
             maxMove < CONTAINER_CLICK_MOVE_THRESHOLD then
            shouldToggle = true
          end
        end
        if shouldToggle then
          local newState = not ContainerCollapsed[fxID]
          ContainerCollapsed[fxID] = newState
          -- initialise animation progress if nil
          ContainerAnim[fxID] = ContainerAnim[fxID] or 0
          -- Only one container can be UNcollapsed within a parallel group:
          -- if this one was expanded (uncollapsed), collapse all other containers in the group
          if not newState then
            local peers = GetParallelGroupPeers(fx)
            for _, p in ipairs(peers) do
              if p ~= fx then
                local _, pCnt = r.TrackFX_GetNamedConfigParm(Track, p, 'container_count')
                if pCnt and pCnt ~= '' then
                  local pGUID = r.TrackFX_GetFXGUID(Track, p)
                  if pGUID then
                    ContainerCollapsed[pGUID] = true
                    ContainerAnim[pGUID] = ContainerAnim[pGUID] or 0
                  end
                end
              end
            end
          end
        end
        -- Clear tracking after handling release
        ContainerRightClickStart[fxID] = nil
        ContainerRightClickMaxMove[fxID] = nil
      end

      -- Prevent opening FX chain for AB Control surrogate (rv is false); keep drag logic intact
      FX_Btn_Mouse_Interaction(rv, Track, fx, FX_Is_Open, FX_Is_Offline, ctx)

      -- After interaction, accumulate contiguous selection blocks (by GUID-based selection)
      do
        local trackGUID = r.GetTrackGUID(Track)
        local selected = IsFXSelected(trackGUID, fx)
        BlockSel = BlockSel or {}
        BlockSel[trackGUID] = BlockSel[trackGUID] or { open=nil, ranges={} }
        local B = BlockSel[trackGUID]
        if selected and not B.open then
          -- start new block at this item rect (use per-item actual button left)
          local curL, curT = im.GetItemRectMin(ctx)
          local R, Btm = im.GetItemRectMax(ctx)
          local L = curL or blockRectStartX
          local T = curT or blockRectStartY
          B.open = { L=L, T=T, R=R, B=Btm }
        elseif selected and B.open then
          -- extend current block downward to include this item; update min-left and max-right
          local curL = select(1, im.GetItemRectMin(ctx))
          local R, Btm = im.GetItemRectMax(ctx)
          B.open.B = Btm
          B.open.R = math.max(B.open.R or R, R)
          if curL then B.open.L = math.min(B.open.L or curL, curL) end
        elseif (not selected) and B.open then
          -- close the block when selection breaks
          table.insert(B.ranges, B.open)
          B.open = nil
        end
      end

      -- Note: FrameBorderSize and FrameRounding are popped at the end of the function
    end

    if CheckIf_FX_Special(Track,fx) then  
      local rv, Name = r.TrackFX_GetFXName(Track, fx)
      local rv, val = r.TrackFX_GetFormattedParamValue(Track,  fx, SPECIAL_FX.Prm[Name])
      ShownName = ''
      ShownName = SPECIAL_FX.ShownName[Name]
      local x , y = im.GetItemRectMin(ctx)
      local txtClr = getClr(im.Col_Text)
      local pushedSpecialFont = false
      do
        local trackGUID = r.GetTrackGUID(Track)
        if IsFXSelected(trackGUID, fx) then
          -- Use bold+italic font matching the current font size
          local lineHeight = im.GetTextLineHeight(ctx)
          local boldItalicFont = Font_Andale_Mono_13_BI -- Default fallback
          -- Match font size based on line height (approximate: line height ≈ font size * 1.2-1.3)
          if lineHeight <= 8 then boldItalicFont = Font_Andale_Mono_6_BI
          elseif lineHeight <= 9 then boldItalicFont = Font_Andale_Mono_7_BI
          elseif lineHeight <= 10 then boldItalicFont = Font_Andale_Mono_8_BI
          elseif lineHeight <= 11 then boldItalicFont = Font_Andale_Mono_9_BI
          elseif lineHeight <= 12 then boldItalicFont = Font_Andale_Mono_10_BI
          elseif lineHeight <= 13 then boldItalicFont = Font_Andale_Mono_11_BI
          elseif lineHeight <= 14 then boldItalicFont = Font_Andale_Mono_12_BI
          elseif lineHeight <= 15 then boldItalicFont = Font_Andale_Mono_13_BI
          elseif lineHeight <= 16 then boldItalicFont = Font_Andale_Mono_14_BI
          elseif lineHeight <= 17 then boldItalicFont = Font_Andale_Mono_15_BI
          else boldItalicFont = Font_Andale_Mono_16_BI
          end
          im.PushFont(ctx, boldItalicFont)
          pushedSpecialFont = true
        end
      end
      local isDraggedFX = (MouseDragDir == 'Vert' and DraggingTrack == t and DraggingFX_Index == fx)
      local isSelectedAndMultiDraggingSpecial = false
      if not isDraggedFX and MouseDragDir == 'Vert' and DraggingFX_Index ~= nil and DraggingTrack == t then
        local trackGUID = r.GetTrackGUID(Track)
        local isSelected = IsFXSelected(trackGUID, fx)
        if isSelected then
          local sel = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
          if sel and #sel > 1 then
            isSelectedAndMultiDraggingSpecial = true
          end
        end
      end
      if isDraggedFX or isSelectedAndMultiDraggingSpecial then txtClr = ColorWithAlpha(txtClr, 0.5) end
      im.DrawList_AddText(WDL, x,y, txtClr, SPECIAL_FX.ShownName[Name]..val )
      if pushedSpecialFont then im.PopFont(ctx) end
    end

    -- Pop regular Andale Mono font (pushed at the beginning)
    im.PopFont(ctx)

    -- Pop FrameBorderSize and FrameRounding style vars (pushed at the beginning)
    -- Only pop if not already popped in renaming path
    if not styleVarsPopped then
      im.PopStyleVar(ctx, 2)
    end

    -- Pop style colors using the tracked count
    im.PopStyleColor(ctx, styleColorPushCount)

   

    --Show link cable if hovered ---
    if FX[fxID] and FX[fxID].Link then
      -- Validate that the linked FX still exists
      local linkedFxID = FX[fxID].Link
      local out = FindFXFromFxGUID(linkedFxID)
      if not out.trk[1] then
        -- Linked FX no longer exists, remove the link
        r.GetSetMediaTrackInfo_String(Track, 'P_EXT: FX' .. fxID .. 'Link to ', '', true)
        FX[fxID].Link = nil
      else
        if im.IsItemHovered(ctx) then
          local x, y        = im.GetCursorScreenPos(ctx)
          LinkCablePosX     = x + HideBtnSz / 2
          LinkCablePosY     = y
          HoveredLinkedFXID = fxID
        else
          if HoveredLinkedFXID == fxID then
            LinkCablePosX, LinkCablePosY, HoveredLinkedFXID = nil
          end
        end
      end
    end
    --- alt + RMB to change FX name 
    if im.IsItemClicked(ctx, 1 ) then 
      if Mods == Alt then 
        Changing_FX_Name = tostring(Track)..'  '.. fx 
      end
    end
    


    FxBtn.H = FxBtn.H or select(2, im.GetItemRectSize(ctx))


    FX.Enable[fx] = r.TrackFX_GetEnabled(Track, fx)

    if FX.Enable[fx] == false then -- add a shade to show it's bypassed
      local L, T = im.GetItemRectMin(ctx)
      im.DrawList_AddRectFilled(WDL, L, T, L + BtnSz, T + FxBtn.H, 0x000000aa)
      --HighlightSelectedItem(0x00000088, nil, 0, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, 'GetItemRect', WDL)
    end



    if MouseDragDir == 'Vert' then
      if im.BeginDragDropSource(ctx, im.DragDropFlags_AcceptNoDrawDefaultRect) then
        -- If value drag is active, do not start FX drag payload (keeps stripes off only for value drags)
        if PreventFXReorder then im.EndDragDropSource(ctx); goto skipDragSource end
        DraggingTrack = t
        DraggingTrack_Data = Track
        DraggingFX_Index = fx

        -- Snapshot original indices of currently selected FXs (GUID-based) at drag start
        -- Also create snapshot if Command is held to enable copying all selected FXs
        local Mods = im.GetKeyMods(ctx)
        local trackGUID = r.GetTrackGUID(DraggingTrack_Data)
        local sel = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
        local hasSelection = sel and #sel > 0
        local cmdHeld = (Mods & Super) ~= 0
        local draggedGUID = r.TrackFX_GetFXGUID(DraggingTrack_Data, fx)
        
        
        -- Always create snapshot if there are selected FXs OR if Command is held
        if hasSelection or cmdHeld then
          MultiMoveSnapshot = MultiMoveSnapshot or {}
          MultiMoveSnapshot[trackGUID] = {}
          -- Include all selected FXs
          if sel and #sel > 0 then
            for _, guid in ipairs(sel) do
              local idx = -1
              local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
              for j = 0, cnt - 1 do
                if r.TrackFX_GetFXGUID(DraggingTrack_Data, j) == guid then idx = j break end
              end
              if idx >= 0 then MultiMoveSnapshot[trackGUID][guid] = idx end
            end
          end
          -- If Command is held, ensure dragged FX is included (even if not in selection)
          if cmdHeld and draggedGUID then
            if not MultiMoveSnapshot[trackGUID][draggedGUID] then
              MultiMoveSnapshot[trackGUID][draggedGUID] = fx
            end
          end

          -- If the dragged FX is part of a marquee selection, treat the first (lowest index) FX
          -- in that selection as the primary drag source so relative order stays intact when dropping.
          local primaryGUID = draggedGUID
          if hasSelection and draggedGUID then
            local draggedIsSelected = false
            for _, g in ipairs(sel) do
              if g == draggedGUID then
                draggedIsSelected = true
                break
              end
            end
            if draggedIsSelected then
              local lowestGUID, lowestIdx = nil, math.huge
              for guid, idx in pairs(MultiMoveSnapshot[trackGUID]) do
                if idx < lowestIdx then
                  lowestIdx = idx
                  lowestGUID = guid
                end
              end
              if lowestGUID then primaryGUID = lowestGUID end
            end
          end

          MultiMoveSourceGUID = primaryGUID
        end

        im.SetDragDropPayload(ctx, 'DragFX', fx)
        -- Check if cmd is held for copy icon display (re-check during drag)
        local currentMods = im.GetKeyMods(ctx)
        local cmdHeldNow = (currentMods & Super) ~= 0
        -- Draw copy icon at mouse position in foreground when cmd is held
        if cmdHeldNow and Img and Img.Copy then
          local mx, my = im.GetMousePos(ctx)
          local iconSz = 16
          local iconX = mx + 10  -- offset to the right of cursor
          local iconY = my - iconSz * 0.5  -- center vertically on cursor
          local FDL = im.GetForegroundDrawList(ctx)
          im.DrawList_AddImage(FDL, Img.Copy, iconX, iconY, iconX + iconSz, iconY + iconSz, nil, nil, nil, nil, 0xffffffff)
          -- Small "+" marker at top-right of the copy icon
          local plusX = iconX + iconSz +2
          local plusY = iconY - 4
          im.DrawList_AddText(FDL, plusX, plusY, 0xffffffff, '+')
        end
        if Show_FX_Drag_Preview then
          im.BeginTooltip(ctx)
          -- Check if multiple FXs are selected and show all of them
          local trackGUID = r.GetTrackGUID(DraggingTrack_Data)
          local sel = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
          if sel and #sel > 1 then
            -- Show all selected FXs in tooltip (vertically stacked)
            local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
            local firstButtonRect = nil
            for i = 0, cnt - 1 do
              local g = r.TrackFX_GetFXGUID(DraggingTrack_Data, i)
              for _, sg in ipairs(sel) do
                if sg == g then
                  local _, fxName = r.TrackFX_GetFXName(DraggingTrack_Data, i)
                  local shownFxName = ChangeFX_Name(fxName)
                  -- Apply renamed name if exists
                  local retval, renamed = r.TrackFX_GetNamedConfigParm(DraggingTrack_Data, i, 'renamed_name')
                  if renamed ~= '' then shownFxName = renamed .. ' ('.. shownFxName..')' end
                  -- Apply shortening if option is enabled
                  if OPEN and OPEN.ShortenFXNames and shownFxName and shownFxName ~= '' then
                    local s = shownFxName
                    s = s:gsub('%b()', ''):gsub('%b[]', ''):gsub('%b{}', '')
                    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
                    shownFxName = s
                  end
                  im.Button(ctx, shownFxName .. '##tooltip' .. i, BtnSz)
                  -- Capture first button geometry for arrows
                  if not firstButtonRect then
                    local TT_L, TT_T = im.GetItemRectMin(ctx)
                    local TT_R, TT_B = im.GetItemRectMax(ctx)
                    firstButtonRect = { L = TT_L, T = TT_T, R = TT_R, B = TT_B }
                    DragTooltipLeftX = TT_L
                    DragTooltipMidY  = (TT_T + TT_B) * 0.5
                    DragTooltipTopY  = TT_T
                    DragTooltipTopMidX = (TT_L + TT_R) * 0.5
                  end
                  break
                end
              end
            end
          else
            -- Single FX: show just this one
            im.Button(ctx, ShownName .. '##' .. t, BtnSz)
            -- Capture tooltip button geometry for arrows
            local TT_L, TT_T = im.GetItemRectMin(ctx)
            local TT_R, TT_B = im.GetItemRectMax(ctx)
            DragTooltipLeftX = TT_L
            DragTooltipMidY  = (TT_T + TT_B) * 0.5
            DragTooltipTopY  = TT_T
            DragTooltipTopMidX = (TT_L + TT_R) * 0.5
          end
          im.EndTooltip(ctx)
        end
        im.EndDragDropSource(ctx)
      end
    end
    ::skipDragSource::

    if im.BeginDragDropTarget(ctx) then
      dropped, draggedFX = im.AcceptDragDropPayload(ctx, 'DragFX') --
      
      local rv, payloadType, draggedFXPayload, is_preview, is_delivery = im.GetDragDropPayload(ctx)
      local draggedFX = tonumber(draggedFX) or tonumber(draggedFXPayload)
      
      
      -- Track hovered target when preview is active
      if is_preview and DraggingFX_Index ~= nil and draggedFX ~= nil then
        PendingDropTarget = PendingDropTarget or {}
        PendingDropTarget.track = Track
        PendingDropTarget.fx = fx
        PendingDropTarget.draggedFX = draggedFX
      end
      
      -- Check if mouse was just released while over this target (fallback detection)
      local mouseJustReleased = im.IsMouseReleased(ctx, 0) and DraggingFX_Index ~= nil and draggedFX ~= nil
      
      -- Use is_delivery or mouse release to detect actual drop (more reliable than dropped flag)
      -- Also check if we have a pending drop target that matches this one
      local hasPendingDrop = PendingDropTarget and PendingDropTarget.track == Track and PendingDropTarget.fx == fx
      local actualDrop = dropped or (is_delivery and draggedFX ~= nil) or (mouseJustReleased and hasPendingDrop)
      
      
      -- Clear pending drop after processing
      if actualDrop then
        PendingDropTarget = nil
      end
      
      if t == DraggingTrack then    -- if drag to same track
        if fx <= draggedFX - 1 then -- if destination is one slot above dragged FX
          local L, T = im.GetItemRectMin(ctx); w, h = im.GetItemRectSize(ctx)
          -- im.DrawList_AddLine(WDL, L, T, L + FXPane_W, T, 0xffffffff) -- removed per request
        else
          local L, T = im.GetItemRectMin(ctx); local R, B = im.GetItemRectMax(ctx);
          local w, h = im.GetItemRectSize(ctx)
          -- im.DrawList_AddLine(WDL, L, B, L + FXPane_W, B, 0xffffffff) -- removed per request
        end
      else
        local L, T = im.GetItemRectMin(ctx); w, h = im.GetItemRectSize(ctx)
        -- im.DrawList_AddLine(WDL, L, T, L + FXPane_W, T, 0xffffffff) -- removed per request
      end

      -- When hovering a target, draw an L-shaped arrow to indicate insertion.
      -- Parallel case: from tooltip's left edge to the horizontal gap between previous and hovered FX.
      -- Non-parallel case: from the tooltip button's top-center, go up to the gap line, then left to the right end of the gap.
      do
        local _, tgtParStrPrev = r.TrackFX_GetNamedConfigParm(Track, fx, 'parallel')
        local tgtParValPrev = tonumber(tgtParStrPrev or '0') or 0
        if tgtParValPrev > 0 then
          local Lh, Th = im.GetItemRectMin(ctx); local Wh, Hh = im.GetItemRectSize(ctx)
          -- Destination x is the gap between previous and hovered FX buttons
          local gapX = Lh - 3  -- half of the 6px spacing
          -- If hovered FX is a container, point to the left of the folder icon as well
          if isContainer then
            local iconPad = ((HideBtnSz or 0) + 1)
            gapX = gapX - iconPad
          end
          -- Start at tooltip button's left edge (or mouse if tooltip hidden)
          local tipX = DragTooltipLeftX; local tipY = DragTooltipMidY
          if not tipX or not tipY then
            tipX, tipY = im.GetMousePos(ctx)
          end
          local endX = gapX; local endY = Th + Hh * 0.5
          local DL = im.GetForegroundDrawList(ctx)
          local col = 0xffffffff
          -- Thin diagonal stripe band at vertical gap (parallel insert)
          do
            local bandW = 2
            local stripeL = endX - bandW * 0.5
            local stripeR = endX + bandW * 0.5
            local stripeT = Th + 1
            local stripeB = Th + Hh - 1
            DrawDiagonalStripes(DL, stripeL, stripeT, stripeR, stripeB, 0xffffff60, 2, 2, 1)
          end
          -- L-shape: horizontal segment to the left (toward gap), then vertical to the gap's Y
          local joinX, joinY = endX, tipY
          im.DrawList_AddLine(DL, tipX, tipY, joinX, joinY, col)
          im.DrawList_AddLine(DL, joinX, joinY, endX, endY, col)
          -- arrow head pointing vertically toward the final end point
          local headLen = 10; local headWidth = 6
          local dirY = (endY >= joinY) and 1 or -1
          local baseX = endX; local baseY = endY - dirY * headLen
          local leftX = baseX - headWidth; local leftY = baseY
          local rightX = baseX + headWidth; local rightY = baseY
          im.DrawList_AddLine(DL, endX, endY, leftX, leftY, col)
          im.DrawList_AddLine(DL, endX, endY, rightX, rightY, col)
        else
          -- Non-parallel target: draw from tooltip top-center up to the selected gap line, then left to right end of gap.
          local Lh, Th = im.GetItemRectMin(ctx); local Wh, Hh = im.GetItemRectSize(ctx)
          -- Determine which gap line (above or below hovered) we're addressing
          local gapY
          if t == DraggingTrack then
            if fx <= draggedFX - 1 then
              gapY = Th                -- insert above hovered FX
            else
              gapY = Th + Hh           -- insert below hovered FX
            end
          else
            gapY = Th                  -- different track: insert above hovered FX
          end
          local endY = gapY
          local endX = Lh + FXPane_W - 6 -- "to the right" end of the gap (near row's right edge)
          local DL = im.GetForegroundDrawList(ctx)
          local col = 0xffffffff
          -- Thin diagonal stripe band at horizontal gap (non-parallel insert)
          do
            local bandH = 2
            local stripeT = endY - bandH * 0.5
            local stripeB = stripeT + bandH
            local stripeL = Lh
            local stripeR = Lh + FXPane_W
            DrawDiagonalStripes(DL, stripeL, stripeT, stripeR, stripeB, 0xffffff60, 2, 2, 1)
          end
          -- Start at tooltip top-center (or mouse if tooltip hidden)
          local tipX = DragTooltipTopMidX; local tipTop = DragTooltipTopY
          if not tipX or not tipTop then
            tipX, tipTop = im.GetMousePos(ctx)
          end
          -- If tooltip start is left of the gap end, draw only an upward arrow; otherwise draw up-and-left arrow.
          if tipX < endX then
            -- Vertical-only up arrow
            im.DrawList_AddLine(DL, tipX, tipTop, tipX, endY, col)
            local headLen = 10; local headWidth = 6
            local baseY = endY + headLen
            im.DrawList_AddLine(DL, tipX, endY, tipX - headWidth, baseY, col)
            im.DrawList_AddLine(DL, tipX, endY, tipX + headWidth, baseY, col)
          else
            -- L-shape: vertical segment up to gap line, then horizontal left to the right end of the gap
            local joinX, joinY = tipX, endY
            im.DrawList_AddLine(DL, tipX, tipTop, joinX, joinY, col)
            im.DrawList_AddLine(DL, joinX, joinY, endX, endY, col)
            -- Arrow head pointing left toward the final end point
            local headLen = 10; local headWidth = 6
            local baseX = endX + headLen; local baseY = endY
            local topX = baseX; local topY = baseY - headWidth
            local botX = baseX; local botY = baseY + headWidth
            im.DrawList_AddLine(DL, endX, endY, baseX, topY, col)
            im.DrawList_AddLine(DL, endX, endY, baseX, botY, col)
          end
        end
      end

      -- Use is_delivery to detect actual drop (works even when AcceptDragDropPayload returns false)
      if actualDrop then
        -- Build batch moves using original indices snapshot (FX Devices-like)
        local Mods = im.GetKeyMods(ctx)  -- Get modifiers at drop time
        local srcTrackGUID = DraggingTrack_Data and r.GetTrackGUID(DraggingTrack_Data)
        local selGuids = srcTrackGUID and MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[srcTrackGUID]
        local snap = srcTrackGUID and MultiMoveSnapshot and MultiMoveSnapshot[srcTrackGUID]
        local cmdHeld = (Mods & Super) ~= 0
        local didBatch = false
        
        
        -- Check if dragged FX is in the selection
        local draggedInSelection = false
        if selGuids and MultiMoveSourceGUID then
          for _, g in ipairs(selGuids) do
            if g == MultiMoveSourceGUID then
              draggedInSelection = true
              break
            end
          end
        end
        
        -- Use snapshot if available (created when multiple FXs selected or Command held)
        -- Also handle Command+Drag case even if snapshot doesn't exist or dragged FX not in snapshot
        local draggedOrig = nil
        if snap and MultiMoveSourceGUID then
          draggedOrig = snap[MultiMoveSourceGUID]
        end
        -- If dragged FX not in snapshot but we have source track, look it up
        if draggedOrig == nil and DraggingTrack_Data and MultiMoveSourceGUID then
          local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
          for j = 0, cnt - 1 do
            if r.TrackFX_GetFXGUID(DraggingTrack_Data, j) == MultiMoveSourceGUID then
              draggedOrig = j
              break
            end
          end
        end
        
        -- If we have a valid dragged FX index, proceed with batch logic
        if draggedOrig ~= nil then
          MovFX = { ToPos = {}, FromPos = {}, Lbl = {}, Copy = {}, FromTrack = {}, ToTrack = {}, GUID = {} }
          local pairsList = {}
          -- If Command is held and there are multiple selected FXs, copy all selected FXs
          if cmdHeld and selGuids and #selGuids > 1 then
            -- Command+Drag: copy all selected FXs (use snapshot if available, otherwise look up current indices)
            for _, g in ipairs(selGuids) do
              local origIdx = snap and snap[g] or nil
              -- If not in snapshot, look up current index from source track
              if origIdx == nil then
                local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
                for j = 0, cnt - 1 do
                  if r.TrackFX_GetFXGUID(DraggingTrack_Data, j) == g then
                    origIdx = j
                    break
                  end
                end
              end
              if origIdx ~= nil then
                pairsList[#pairsList+1] = { guid=g, orig=origIdx }
              end
            end
          elseif cmdHeld and snap then
            -- Command+Drag but no selection or single selection: copy all FXs in snapshot
            for guid, origIdx in pairs(snap) do
              pairsList[#pairsList+1] = { guid=guid, orig=origIdx }
            end
          elseif selGuids and #selGuids > 1 and snap then
            -- Normal multi-move: use selected FXs from snapshot
            for _, g in ipairs(selGuids) do
              local oi = snap[g]
              if oi ~= nil then 
                pairsList[#pairsList+1] = { guid=g, orig=oi }
              end
            end
          end
          
          
          -- Only proceed if we have FXs to process
          if #pairsList > 0 then
            table.sort(pairsList, function(a,b)
              if cmdHeld then
                return a.orig < b.orig -- keep relative order when copying
              elseif fx > draggedOrig then -- moving downwards
                return a.orig > b.orig
              else -- upwards or equal
                return a.orig < b.orig
              end
            end)
            -- Build ascending order for rank mapping (contiguous block mapping)
            local asc = {}
            for i=1,#pairsList do asc[i] = pairsList[i] end
            table.sort(asc, function(a,b) return a.orig < b.orig end)
            local rankOf = {}
            for i,it in ipairs(asc) do rankOf[it.guid] = i-1 end -- 0-based rank
            local draggedRank = rankOf[MultiMoveSourceGUID] or 0
            local sameTrack = (DraggingTrack_Data == Track)
            DraggedMultiMove = MultiMoveSourceGUID

            -- Step 1: Compact selected to a contiguous block around the lowest original index
            -- Skip compaction when copying (Command held) - copy directly from original positions
            if not cmdHeld then
              local lowest = asc[1] and asc[1].orig or nil
              if lowest then
                -- Move each selected by original order to eliminate gaps
                for i=1,#asc do
                  local want = lowest + (i-1)
                  if asc[i].orig ~= want then
                    table.insert(MovFX.FromPos, asc[i].orig)
                    table.insert(MovFX.ToPos, want)
                    table.insert(MovFX.FromTrack, DraggingTrack_Data)
                    table.insert(MovFX.ToTrack, DraggingTrack_Data)
                    table.insert(MovFX.GUID, asc[i].guid)
                    asc[i].orig = want
                  end
                end
                -- Update draggedOrig after compaction
                draggedOrig = lowest + draggedRank
              end
            end

            -- Step 2: Copy/Move the block to destination keeping relative order
            do
              local blockStart = asc[1] and asc[1].orig or 0
              local blockLen = #asc
              local insertionStart
              if sameTrack and not cmdHeld then
                -- Moving on same track: adjust insertion point to account for block
                if fx >= blockStart then
                  insertionStart = fx - (blockLen - 1)
                else
                  insertionStart = fx
                end
              else
                -- Copying or different track: insert at drop position
                insertionStart = fx
              end
              if insertionStart < 0 then insertionStart = 0 end
              for _, it in ipairs(pairsList) do
                local rank = rankOf[it.guid] or 0
                local fromIndex
                if cmdHeld then
                  -- When copying, use original index (no compaction)
                  fromIndex = it.orig
                else
                  -- When moving, use contiguous index after compaction
                  fromIndex = blockStart + rank
                end
                local target = insertionStart + rank
                table.insert(MovFX.FromPos, fromIndex)
                table.insert(MovFX.ToPos, target)
                table.insert(MovFX.FromTrack, DraggingTrack_Data)
                table.insert(MovFX.ToTrack, Track)
                table.insert(MovFX.GUID, it.guid)
              end
            end
            didBatch = #pairsList > 0
          end  -- Close if #pairsList > 0
        end  -- Close if draggedOrig ~= nil
        -- Decide desired parallel state based on the drop target
        local _, tgtParStr = r.TrackFX_GetNamedConfigParm(Track, fx, 'parallel')
        local tgtParVal = tonumber(tgtParStr or '0') or 0
        if tgtParVal > 0 then
          -- Dropping onto a non-first parallel FX: make inserted FX parallel to previous
          SetParallelForNextDrop = true
          SetParallelToValue = tgtParVal
          SetParallelClearForNextDrop = nil
        else
          -- Dropping onto a non-parallel target: ensure inserted FX is not parallel
          SetParallelClearForNextDrop = true
          SetParallelForNextDrop = nil
          SetParallelToValue = nil
        end

        if not didBatch then
          if Mods == 0 then
            MoveFX(draggedFX, fx, true, nil, DraggingTrack_Data, Track)
          elseif Mods == Super then
            MoveFX(draggedFX, fx, false, nil, DraggingTrack_Data, Track)
          elseif Mods == Ctrl then --Pool FX
            MoveFX(draggedFX, fx, false, nil, DraggingTrack_Data, Track)
            local ID = r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFX)
            NeedLinkFXsID = ID
            FX[ID] = FX[ID] or {}
          end
        else
          -- Batch prepared. If copying (Cmd/Super or Ctrl), set flags similar to MoveFX behavior
          if Mods == Super or Mods == Ctrl then
            NeedCopyFX = true
            DropPos = fx
            if Mods == Ctrl then
              -- For multi-selection Ctrl+drag, store all original GUIDs for linking
              if selGuids and #selGuids > 1 then
                NeedLinkFXsGUIDs = {}
                for _, guid in ipairs(selGuids) do
                  NeedLinkFXsGUIDs[guid] = true
                  FX[guid] = FX[guid] or {}
                end
              else
                -- Single FX: use the old method
                local ID = r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFX)
                NeedLinkFXsID = ID
                FX[ID] = FX[ID] or {}
              end
            end
          end
        end
      end
      im.EndDragDropTarget(ctx)
    end

    F.Wet_PNum = F.Wet_PNum or r.TrackFX_GetParamFromIdent(Track, fx, ':wet')

    if im.IsItemActive(ctx) and MouseDragDir == 'Horiz' then
      --F.Wet = F.Wet + im.GetMouseDelta(ctx) * 0.01
      if CheckIf_FX_Special(Track,fx) then 
        local rv, Name = r.TrackFX_GetFXName(Track, fx)
        F.Special = SPECIAL_FX.Prm[Name]
      end

      local Prm 
      if  F.Special then Prm = F.Special else Prm = F.Wet_PNum end 


      local Val = r.TrackFX_GetParamNormalized(Track, fx, Prm)
      local Scale = 0.01
      if im.GetKeyMods(ctx) == im.Mod_Shift then Scale = 0.002 end
      local Delta = im.GetMouseDelta(ctx) * Scale

      r.TrackFX_SetParamNormalized(Track, fx, Prm, Val + Delta)
      if not   F.Special then 
        F.Wet = Val 
        im.BeginTooltip(ctx)
        im.Text(ctx, ('%.f'):format(Val * 100) .. '%')
        im.EndTooltip(ctx)
      end 
    elseif MouseDragDir == 'Vert' then
      -- Show drag effect on the actively dragged FX or all selected FXs if multi-dragging
      local showDragEffect = false
      if im.IsItemActive(ctx) then
        -- This FX is being actively dragged
        showDragEffect = true
      elseif DraggingFX_Index ~= nil and DraggingTrack == t then
        -- A drag is happening on this track
        local trackGUID = r.GetTrackGUID(Track)
        local isSelected = IsFXSelected(trackGUID, fx)
        if isSelected then
          -- Check if there are multiple selected FXs being dragged
          local sel = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
          if sel and #sel > 1 then
            -- Multi-drag: show effect on all selected FXs
            showDragEffect = true
          end
        end
      end
      
      if showDragEffect then
        -- Replace corner-line highlight with diagonal stripes over the button rect
        local L, T = im.GetItemRectMin(ctx)
        local R, B = im.GetItemRectMax(ctx)
        local dl = im.GetWindowDrawList(ctx)
        -- Make stripes half transparent as well (0x80 alpha)
        DrawDiagonalStripes(dl, L, T, R, B, 0xffffff30, 2, 2, 1)
      end
    end

   
    local R, B = im.GetItemRectMax(ctx)
    -- Record the main FX button rectangle for layout decisions (e.g., multi-select menu positioning)
    do
      if fxID then
        local Lb, Tb = im.GetItemRectMin(ctx)
        local Rb, Bb = R, B
        FX[fxID].BtnRect = { L = Lb, T = Tb, R = Rb, B = Bb }
      end
    end

    -- Draw a circular area on the FX button so the upcoming Wet/Dry knob appears "embedded"
    local Lbtn, Tbtn = im.GetItemRectMin(ctx)

    local _, LineH = im.GetItemRectSize(ctx)
    local knobCenterX = R + LineH/2
    local knobCenterY = Tbtn + LineH/2

    -- Hide Wet/Dry knob for FXs that are in a parallel group
    local peersForKnob = GetParallelGroupPeers(fx)
    local showKnob = not (peersForKnob and #peersForKnob > 1)
    do
      local lowerName = (FullName or Name or ''):lower()
      local isABSource = (lowerName:find('ab level matching') and lowerName:find('source')) and true or false
      local isABControl = (lowerName:find('ab level matching') and lowerName:find('control')) and true or false
      if isABSource or isABControl then showKnob = false end
    end
    if IsDeleting then showKnob = false end
    if showKnob then
      local knobBg = FX_Is_Offline and 0x771111ff or getClr(im.Col_Button)
      im.DrawList_AddRectFilled(WDL, R, Tbtn, R + WetDryKnobSz, Tbtn + LineH, knobBg)
      --[[ im.DrawList_AddCircleFilled(WDL, knobCenterX, knobCenterY, WetDryKnobSz, getClr(im.Col_Button)) ]]
      --im.DrawList_AddCircleFilled(WDL, knobCenterX, knobCenterY, knobRadius, getClr(im.Col_Button))
     -- im.DrawList_AddCircle(WDL, knobCenterX, knobCenterY, knobRadius, 0xffffffff, 12, 1)

      -- Place the Wet/Dry knob immediately after the button with no spacing
      im.SameLine(ctx, 0, 0)
      im.AlignTextToFramePadding(ctx)
      F.ActiveAny, F.Active, F.Wet = Add_WetDryKnob(ctx, 'WD' .. fx, '',
        F.Wet or r.TrackFX_GetParamNormalized(Track, fx, F.Wet_PNum), 0, 1, fx, Track, FX_Is_Offline)
      -- If this knob is active (dragging), mark global dragging so any selected FX hides the menu
      if F.Active then WetDryKnobDragging = true end
      -- Add hint text for wet/dry knob (check if knob is hovered via its item)
      if im.IsItemHovered(ctx) then
        SetHelpHint('LMB Drag = Adjust Wet/Dry Mix', 'Shift+Drag = Fine Adjustment', 'Ctrl+LMB = Show Wet/Dry Envelope')
      end

      -- (Popup moved outside showKnob block to ensure visibility even when knob hidden)
    end

    -- Floating menu window: draw after knob block so it appears regardless of knob visibility
    do
      local trackGUID = r.GetTrackGUID(Track)
      local selGuids = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
      if selGuids and #selGuids >= 1 then
        -- Check if this is the first selected FX across ALL tracks
        local firstTrackGUID, firstFXGUID = GetFirstSelectedFXAcrossTracks()
        local thisGuid = r.TrackFX_GetFXGUID(Track, fx)
        local isFirstAcrossTracks = (firstTrackGUID == trackGUID and firstFXGUID == thisGuid)
        
        -- Only show menu for the first selected FX across all tracks, and only once per frame
        -- Hide menu when dragging FXs
        local isDragging = (MouseDragDir == 'Vert' and DraggingFX_Index ~= nil)
        if isFirstAcrossTracks and not SuppressMultiSelMenuThisFrame and not MultiSelMenuVisibleThisFrame and not isDragging then
          local spansMultipleTracks = SelectionSpansMultipleTracks()
          local Lbtn, Tbtn = im.GetItemRectMin(ctx)
          local Rbtn, Bbtn = im.GetItemRectMax(ctx)
          local cnt = r.TrackFX_GetCount(Track)
          
          -- Determine if selection contains parallel FX and compute rightmost rect among selected
          local idxs, selIndexSet = {}, {}
          for i = 0, cnt - 1 do
            local g = r.TrackFX_GetFXGUID(Track, i)
            for _, sg in ipairs(selGuids) do if sg == g then idxs[#idxs+1] = i; selIndexSet[i] = true; break end end
          end
          table.sort(idxs)
          local hasParallelInSelection = false
          for _, idx in ipairs(idxs) do
            local peers = GetParallelGroupPeers(idx)
            if peers and #peers > 1 then
              local c = 0
              for _, pi in ipairs(peers) do if selIndexSet[pi] then c = c + 1 end end
              if c >= 2 then hasParallelInSelection = true break end
            end
          end

          local rightmostR, topMostT = nil, nil
          do
            -- Collect rects from all selected FX across all tracks
            for trackGUIDForMenu, fxGUIDsForMenu in pairs(MarqueeSelection.selectedFXs) do
              if fxGUIDsForMenu then
                for _, sg in ipairs(fxGUIDsForMenu) do
                  local rect = FX[sg] and FX[sg].BtnRect
                  if rect then
                    rightmostR = (rightmostR and math.max(rightmostR, rect.R)) or rect.R
                    topMostT = (topMostT and math.min(topMostT, rect.T)) or rect.T
                  end
                end
              end
            end
          end

          local menuX = (hasParallelInSelection and rightmostR) and (rightmostR + 6) or (Rbtn + 6)
          local menuY = (hasParallelInSelection and topMostT) and topMostT or Tbtn
          local winName = 'MultiSelMenu##Global'
          im.SetNextWindowPos(ctx, menuX, menuY)
          im.SetNextWindowBgAlpha(ctx, 0.95)
          local flags = im.WindowFlags_NoTitleBar | im.WindowFlags_NoResize | im.WindowFlags_NoMove | im.WindowFlags_AlwaysAutoResize | im.WindowFlags_NoSavedSettings | im.WindowFlags_NoScrollbar
          local visible, open = im.Begin(ctx, winName, true, flags)
          if visible then
            MultiSelMenuVisibleThisFrame = true
            
            if im.IsWindowHovered(ctx) then im.PushStyleVar(ctx, im.StyleVar_Alpha, 1.0) else im.PushStyleVar(ctx, im.StyleVar_Alpha, 0.9) end
            
            -- If selection spans multiple tracks, only show bypass option
            if spansMultipleTracks then
              if im.Selectable(ctx, 'Bypass') then BypassSelectedFXs() end
            else
              -- Single track selection: show all options
              local function Parallel()
                -- Only show Put in Parallel if all selected are contiguous and at least 2 selected
                local contiguous = true
                local idxs = {}
                for i = 0, cnt - 1 do
                  local g = r.TrackFX_GetFXGUID(Track, i)
                  for _, sg in ipairs(selGuids) do if sg == g then idxs[#idxs+1] = i break end end
                end
                table.sort(idxs)
                for i = 2, #idxs do if idxs[i] ~= idxs[i-1] + 1 then contiguous = false break end end
                if (#idxs >= 2) and contiguous and im.Selectable(ctx, 'Put in Parallel') then
                  r.PreventUIRefresh(1)  -- Prevent intermediate UI updates to ensure single undo step
                  r.Undo_BeginBlock()
                  local idxs = {}
                  for i = 0, cnt - 1 do
                    local g = r.TrackFX_GetFXGUID(Track, i)
                    for _, sg in ipairs(selGuids) do if sg == g then idxs[#idxs+1] = i break end end
                  end
                  table.sort(idxs)
                  for i = 2, #idxs do r.TrackFX_SetNamedConfigParm(Track, idxs[i], 'parallel', '1') end
                  r.Undo_EndBlock('Put selected FXs in Parallel', -1)
                  r.PreventUIRefresh(-1)  -- Re-enable UI updates
                  ClearSelection()
                end
              end
              if im.Selectable(ctx, 'Put in Container##'..tostring(trackGUID)) then
                PutSelectedFXsInContainer()
                ClearSelection()
              end
              -- Only show Loudness Match if selection is contiguous (or single)
              if not hasParallelInSelection then Parallel() end
              do
                local contiguousLM = true
                local lmIdxs = {}
                for i = 0, cnt - 1 do
                  local g = r.TrackFX_GetFXGUID(Track, i)
                  for _, sg in ipairs(selGuids) do if sg == g then lmIdxs[#lmIdxs+1] = i break end end
                end
                table.sort(lmIdxs)
                if #lmIdxs >= 2 then
                  for i = 2, #lmIdxs do if lmIdxs[i] ~= lmIdxs[i-1] + 1 then contiguousLM = false break end end
                end
                if contiguousLM and im.Selectable(ctx, 'Loudness Match') then
                  LoudnessMatchSelectedFXs()
                  ClearSelection()
                end
              end
              if im.Selectable(ctx, 'Bypass') then BypassSelectedFXs() end
            end
            
            im.PopStyleVar(ctx)
            -- Record menu rectangle to prevent selection clear when clicking menu
            do
              local L, T = im.GetWindowPos(ctx)
              local W, H = im.GetWindowSize(ctx)
              MultiSelMenuRect = { L = L, T = T, R = L + W, B = T + H }
            end
            im.End(ctx)
          end
        end
      end
    end

    -------------------------------------------------------
    --  If container : render enclosed FXs with rectangle  --
    -------------------------------------------------------
    if isContainer then
      -- update animation progress
      local prog = ContainerAnim[fxID] or (ContainerCollapsed[fxID] and 1 or 0)
      local step = 0.15  -- speed per frame
      if ContainerCollapsed[fxID] then
        prog = math.min(1, prog + step)
      else
        prog = math.max(0, prog - step)
      end
      ContainerAnim[fxID] = prog

      local indent = 8  -- left/right margin for contained FXs
      im.Indent(ctx, indent)
      local rectL, rectT = im.GetCursorScreenPos(ctx)
      -- Local container fade. Parent fade is applied by the style alpha pushed around this recursive call.
      local alpha = 1 - prog  -- 1 when expanded, 0 when fully collapsed
      if alpha > 0.01 then
        -- Defer children rendering to after the entire parallel row is drawn
        deferredChildren[#deferredChildren + 1] = { fx = fx, indent = indent, alpha = alpha }
      end
      local rectEndX, rectEndY = im.GetCursorScreenPos(ctx)
      im.Unindent(ctx, indent)
     end

    -- If current FX is the last in its parallel group, render any deferred container children underneath
    do
      local peersForFlush = GetParallelGroupPeers(fx)
      if peersForFlush and #peersForFlush > 0 and peersForFlush[#peersForFlush] == fx then
        if #deferredChildren > 0 then
          for i = 1, #deferredChildren do
            local d = deferredChildren[i]
            if d.alpha > 0.01 then
              im.PushStyleVar(ctx, im.StyleVar_Alpha, d.alpha)
              im.Indent(ctx, d.indent)
              -- Capture start of children region for boundary drawing
              local startL, startT = im.GetCursorScreenPos(ctx)
              -- Draw children first; guide lines will be drawn after on the same draw list (on top)
              local draw_list = im.GetWindowDrawList(ctx)
              -- Draw inner FX list with reduced width (leave margin both sides)
              -- Parent fade is applied via this PushStyleVar; children will multiply their own local fade.

              FXBtns(Track, BtnSz - d.indent, d.fx, t, ctx, inheritedAlpha, OPEN)
              -- Capture end of children region and draw boundary visualization
              do
                local endX, endY = im.GetCursorScreenPos(ctx)
                local innerW = (BtnSz - d.indent) + (WetDryKnobSz or 0)
                local pad = 2
                local thick = 3
                local Lb = startL -pad*3
                local Tb = startT - pad
                local Rb = startL + innerW + pad
                local Bb = endY - pad*3
                local peers = GetParallelGroupPeers(d.fx)
                local dGUID = r.TrackFX_GetFXGUID(Track, d.fx)
                local isParallel = peers and #peers > 1
                local isUncollapsed = dGUID and (ContainerCollapsed[dGUID] == false)
                -- Check if container has any children before drawing enclosing lines
                local okCnt, cntStr = r.TrackFX_GetNamedConfigParm(Track, d.fx, 'container_count')
                local childCount = tonumber(cntStr) or 0
                -- Only draw enclosing lines if container has FX inside
                if childCount > 0 then
                  -- Use persistent container color for this container's guides
                  local containerColor = dGUID and GetContainerColor(Track, d.fx, dGUID) or ((Clr and Clr.Attention) or 0xffffffff)
                  local outline = containerColor
                  local fill = 0xffffff06
                  -- Draw guide lines after children on the same window draw list
                  local dl = draw_list
                  --[[ im.DrawList_AddRectFilled(dl, Lb, Tb, Rb, Bb, fill, 3, nil) ]]
                  im.DrawList_AddLine(dl, Lb, Tb, Lb, Bb, outline, thick)

                  --[[ im.DrawList_AddRect(dl, Lb, Tb, Rb, Bb, outline, 3, nil, 1.0) ]]
                  -- Connect a guide line from the bottom of the folder icon to the left boundary
                  do
                    local fr = dGUID and FX[dGUID] and FX[dGUID].FolderRect
                    if fr and isUncollapsed then
                      local y = fr.B + pad
                      local xStart = fr.L + (fr.R - fr.L) * 0.5
                      im.DrawList_AddLine(dl, xStart, y, Lb , y, outline, thick)
                    end
                  end

                  -- Draw short horizontal lines to each direct child FX. For parallel rows, connect between siblings.
                  do
                    local prevRect = nil
                    for i = 0, childCount - 1 do
                      local childIdx = tonumber(select(2, r.TrackFX_GetNamedConfigParm(Track, d.fx, 'container_item.' .. i)))
                      if childIdx then
                        local g = r.TrackFX_GetFXGUID(Track, childIdx)
                        local rect = g and FX[g] and FX[g].BtnRect
                        local isChildContainer = select(2, r.TrackFX_GetNamedConfigParm(Track, childIdx, 'container_count'))
                        local childFolder = g and FX[g] and FX[g].FolderRect
                        local childEnvelope = g and FX[g] and FX[g].EnvelopeRect
                        local _, parStr = r.TrackFX_GetNamedConfigParm(Track, childIdx, 'parallel')
                        local parVal = tonumber(parStr or '0') or 0
                        -- Choose target X: for containers, aim to folder icon's left edge; 
                        -- if envelope icon exists, end before it; otherwise to button left
                        local targetX
                        if isChildContainer and isChildContainer ~= '' and childFolder then
                          targetX = childFolder.L
                        elseif childEnvelope then
                          targetX = childEnvelope.L
                        else
                          targetX = rect and rect.L
                        end
                        if rect and targetX then
                          local yMid = (rect.T + rect.B) * 0.5
                          local startX
                          if parVal > 0 and prevRect then
                            -- Second (or later) in a parallel group: start from the right edge of previous sibling
                            startX = prevRect.R
                          else
                            -- First in row or non-parallel: start from the container's left guide
                            startX = Lb
                          end
                          im.DrawList_AddLine(dl, startX, yMid, targetX, yMid, outline, thick)
                        end
                        prevRect = rect or prevRect
                      end
                    end
                  end
                end
                -- No splitter: lines are drawn after children and appear above
              end
              im.Unindent(ctx, d.indent)
              im.PopStyleVar(ctx)
            end
          end
          deferredChildren = {}
        end
      end
    end

    -- track previous FX at this scope for layout decisions
    prevFxAtLevel = fx
  end

  -- Draw contiguous selection blocks for this track
  do
    local trackGUID = r.GetTrackGUID(Track)
    local B = BlockSel and BlockSel[trackGUID]
    if B then
      if B.open then table.insert(B.ranges, B.open) B.open = nil end
      local dl = im.GetWindowDrawList(ctx)
      for _, rct in ipairs(B.ranges) do
        -- Slight padding
        local pad = 1
        -- im.DrawList_AddRect(dl, rct.L - pad, rct.T - pad, rct.R + pad, rct.B + pad, 0x75FB66FF, 0, nil, 3)
      end
      -- clear for next frame
      BlockSel[trackGUID] = { open=nil, ranges={} }
    end
  end
  

  -- Process any FX queued for deletion after their shrink animation completes
  if PendingDeleteGUIDs and #PendingDeleteGUIDs > 0 then
    local toDelete = PendingDeleteGUIDs
    PendingDeleteGUIDs = {}
    for i = 1, #toDelete do
      local it = toDelete[i]
      if it and it.guid and it.track then
        -- Prefer direct index when provided (container child indices are stable within frame)
        if it.index ~= nil then DeleteFX(it.index, it.track)
        else
          local found = FindFXFromFxGUID(it.guid)
          if found and found.fx and found.trk then
            for j = 1, #found.fx do
              if found.trk[j] == it.track then
                DeleteFX(found.fx[j], it.track)
                break
              end
            end
          end
        end
        if FXDeleteAnim then FXDeleteAnim[it.guid] = nil end
      end
    end
  end
end

function Empty_FX_Space_Btn(ctx, T)
  --if FX_Ct == 0 then -- if there's no fx on track
  im.PushStyleColor(ctx, im.Col_Button, getClr(im.Col_ChildBg))
  im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_FrameBgHovered))
  im.PushStyleColor(ctx, im.Col_ButtonActive, getClr(im.Col_FrameBgActive))


  if im.Button(ctx, ' ##empty'..tostring(Track), FXPane_W, T.H) then
    if Mods == 0 then
      im.OpenPopup(ctx, 'Btwn FX Windows' ..tostring(Track))

    end -- Add FX Window            end
  end
  if im.IsItemHovered(ctx) then
    SetHelpHint('LMB = Add FX', 'Drag FX here to insert at end')
  end

  -- Show dotted outline when Add FX popup (end-of-chain) is open
  local popupName = 'Btwn FX Windows' .. tostring(Track)
  if im.IsPopupOpen(ctx, popupName) then
    local L_rect, T_rect = im.GetItemRectMin(ctx)
    local R_rect, B_rect = im.GetItemRectMax(ctx)
    local H = im.GetTextLineHeight(ctx)
    DrawDottedRect(FDL or im.GetForegroundDrawList(ctx), L_rect, T_rect, R_rect, T_rect+H, 0xffffffff, 4, 2)
    EndFXSlot_Rect = {L=L_rect, T=T_rect, R=R_rect, B=T_rect+H}
  else
    EndFXSlot_Rect = nil
  end


  if im.IsWindowHovered(ctx,im.HoveredFlags_AnyWindow) then 

    --r.BR_Win32_SetFocus()
    r.DockWindowRefresh()
 
  end
  im.PopStyleColor(ctx, 3)
  if im.BeginPopup(ctx, 'Btwn FX Windows'..tostring(Track)) then 
    -- Always use the actual track FX count for end-of-chain insertion
    -- FX_Ct may have been modified by recursive calls for nested FX in containers
    local trackFXCount = r.TrackFX_GetCount(Track)
    if FilterBox(ctx,Track ,  trackFXCount, LyrID, SpaceIsBeforeRackMixer, FxGUID_Container, SpcIsInPre, SpcInPost,SpcIDinPost) then
      im.CloseCurrentPopup(ctx)
    end
    im.EndPopup(ctx)

  end


  if im.BeginDragDropTarget(ctx) then
    dropped, draggedFX = im.AcceptDragDropPayload(ctx, 'DragFX') --

    local rv, payloadType, draggedFX, is_preview, is_delivery = im.GetDragDropPayload(ctx)
    local draggedFX = tonumber(draggedFX)
    local L, T = im.GetItemRectMin(ctx); w, h = im.GetItemRectSize(ctx)
    -- im.DrawList_AddLine(WDL, L, T, L + FXPane_W, T, 0xffffffff) -- removed per request
    -- Thin diagonal stripe band at horizontal gap (end-of-chain insert)
    do
      local DL = im.GetForegroundDrawList(ctx)
      local bandH = 4
      local stripeT = T
      local stripeB = stripeT + bandH
      local stripeL = L
      local stripeR = L + FXPane_W
      DrawDiagonalStripes(DL, stripeL, stripeT, stripeR, stripeB, 0xffffff60, 2, 2, 1)
    end

    if dropped then
      -- End-of-chain space is not parallel by definition; clear any parallel state for the insert
      SetParallelClearForNextDrop = true
      SetParallelForNextDrop = nil
      SetParallelToValue = nil

      local appendPos = r.TrackFX_GetCount(Track)
      local fx = appendPos

      local Mods = im.GetKeyMods(ctx)
      local srcTrackGUID = DraggingTrack_Data and r.GetTrackGUID(DraggingTrack_Data)
      local selGuids = srcTrackGUID and MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[srcTrackGUID]
      local snap = srcTrackGUID and MultiMoveSnapshot and MultiMoveSnapshot[srcTrackGUID]
      local cmdHeld = (Mods & Super) ~= 0
      local didBatch = false

      -- Treat empty-area drop the same as dropping after the last FX slot
      if snap and MultiMoveSourceGUID then
        -- If dragging within a marquee selection, treat the lowest-index FX in the selection
        -- as the primary drag source so block ordering stays stable even when dropping at end.
        local sourceGUID = MultiMoveSourceGUID
        do
          local draggedGUID = DraggingTrack_Data and r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFX)
          
          if draggedGUID and selGuids then
            local draggedIsSelected = false
            for _, g in ipairs(selGuids) do
              if g == draggedGUID then draggedIsSelected = true break end
            end
            if draggedIsSelected then
              local lowestGUID, lowestIdx = nil, math.huge
              for guid, idx in pairs(snap) do
                if idx < lowestIdx then
                  lowestIdx = idx
                  lowestGUID = guid
                end
              end
              if lowestGUID then
                sourceGUID = lowestGUID
                MultiMoveSourceGUID = lowestGUID -- keep global in sync
              end
            end
          end
        end

        local draggedOrig = snap[sourceGUID]
        if draggedOrig == nil and DraggingTrack_Data then
          local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
          for j = 0, cnt - 1 do
            if r.TrackFX_GetFXGUID(DraggingTrack_Data, j) == sourceGUID then
              draggedOrig = j
              break
            end
          end
        end

        if draggedOrig ~= nil then
          MovFX = { ToPos = {}, FromPos = {}, Lbl = {}, Copy = {}, FromTrack = {}, ToTrack = {}, GUID = {} }
          local pairsList = {}
          if cmdHeld and selGuids and #selGuids > 1 then
            for _, g in ipairs(selGuids) do
              local origIdx = snap[g]
              if origIdx == nil then
                local cnt = r.TrackFX_GetCount(DraggingTrack_Data)
                for j = 0, cnt - 1 do
                  if r.TrackFX_GetFXGUID(DraggingTrack_Data, j) == g then
                    origIdx = j
                    break
                  end
                end
              end
              if origIdx ~= nil then
                pairsList[#pairsList+1] = { guid=g, orig=origIdx }
              end
            end
          elseif cmdHeld then
            for guid, origIdx in pairs(snap) do
              pairsList[#pairsList+1] = { guid=guid, orig=origIdx }
            end
          elseif selGuids and #selGuids > 1 then
            for _, g in ipairs(selGuids) do
              local oi = snap[g]
              if oi ~= nil then pairsList[#pairsList+1] = { guid=g, orig=oi } end
            end
          end

          if #pairsList > 0 then
            table.sort(pairsList, function(a,b)
              if cmdHeld then
                return a.orig < b.orig -- keep relative order when copying
              elseif appendPos > draggedOrig then
                return a.orig > b.orig
              else
                return a.orig < b.orig
              end
            end)
            
            local asc = {}
            for i=1,#pairsList do asc[i] = pairsList[i] end
            table.sort(asc, function(a,b) return a.orig < b.orig end)
            local rankOf = {}
            for i,it in ipairs(asc) do rankOf[it.guid] = i-1 end
            local draggedRank = rankOf[sourceGUID] or 0
            local sameTrack = (DraggingTrack_Data == Track)
            DraggedMultiMove = sourceGUID

            do
              local blockStart = asc[1] and asc[1].orig or 0
              local blockLen = #asc
              local insertionStart
              -- End-of-chain: place block ending at appendPos-1 (move) or starting at appendPos (copy/other track)
              if sameTrack and not cmdHeld then
                insertionStart = math.max(appendPos - blockLen, 0)
              else
                insertionStart = appendPos
              end
              if insertionStart < 0 then insertionStart = 0 end
              
              for _, it in ipairs(pairsList) do
                local rank = rankOf[it.guid] or 0
                local fromIndex = it.orig
                local target = insertionStart + rank
                table.insert(MovFX.FromPos, fromIndex)
                table.insert(MovFX.ToPos, target)
                table.insert(MovFX.FromTrack, DraggingTrack_Data)
                table.insert(MovFX.ToTrack, Track)
                table.insert(MovFX.GUID, it.guid)
              end
            end
            didBatch = #pairsList > 0
          end
        end
      end

      if not didBatch then
        if Mods == 0 then 
          MoveFX(draggedFX, appendPos, true, nil, DraggingTrack_Data, Track)
        elseif Mods == Super then
          MoveFX(draggedFX, appendPos, false, nil, DraggingTrack_Data, Track)
        elseif Mods == Ctrl then --Pool FX
          MoveFX(draggedFX, appendPos, false, nil, DraggingTrack_Data, Track)
          local ID = r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFX)
          NeedLinkFXsID = ID
          FX = FX or {}
          FX[ID] = FX[ID] or {}
        end
      else
        if Mods == Super or Mods == Ctrl then
          NeedCopyFX = true
          DropPos = appendPos
          if Mods == Ctrl then
            -- Check if this is a multi-selection drag
            local trackGUID = r.GetTrackGUID(DraggingTrack_Data)
            local selGuids = MarqueeSelection and MarqueeSelection.selectedFXs and MarqueeSelection.selectedFXs[trackGUID]
            if selGuids and #selGuids > 1 then
              -- Multi-selection Ctrl+drag: store all original GUIDs for linking
              NeedLinkFXsGUIDs = {}
              for _, guid in ipairs(selGuids) do
                NeedLinkFXsGUIDs[guid] = true
                FX = FX or {}
                FX[guid] = FX[guid] or {}
              end
            else
              -- Single FX: use the old method
              local ID = r.TrackFX_GetFXGUID(DraggingTrack_Data, draggedFX)
              NeedLinkFXsID = ID
              FX = FX or {}
              FX[ID] = FX[ID] or {}
            end
          end
        end
      end
    end
    im.EndDragDropTarget(ctx)
  end
end