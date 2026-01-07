-- @description Grid Selector (Hold)
-- @author AI Assistant
-- @version 2.1
-- @about
--   Displays a grid of buttons to change the project grid size.
--   Hold the assigned shortcut to keep the window open.
--   Hover over buttons to switch grid immediately.
--   Window centers on the current grid setting.
--   Requires: ReaImGui, JS_ReaScriptAPI

if not reaper.APIExists('ImGui_GetVersion') then
  reaper.ShowConsoleMsg('ReaImGui is required for this script.\n')
  return
end

if not reaper.APIExists('JS_VKeys_GetState') then
  reaper.ShowConsoleMsg('JS_ReaScriptAPI is required for this script.\n')
  return
end

local ctx = reaper.ImGui_CreateContext('Grid Selector')

-- Configuration
local BTN_W, BTN_H = 60, 30
local SPACING_X, SPACING_Y = 6, 6
local WINDOW_PAD_X, WINDOW_PAD_Y = 12, 12
local GAP_BEFORE_NONSTD = 15

-- Colors (RGBA)
local COL_BG = 0x202020FF
local COL_BTN_BASE = 0x353535FF
local COL_BTN_HOVER = 0x4A4A4AFF
local COL_BTN_ACTIVE = 0x4CAF50FF
local COL_BTN_ACTIVE_HOVER = 0x66BB6AFF
local COL_TEXT = 0xE0E0E0FF
local COL_HEADER = 0xAAAAAAFF

-- Grid Definitions
local standard_grids = {
  { name="1/1",   val=4 },      -- Whole
  { name="1/2",   val=8 },      -- Half
  { name="1/4",   val=16 },     -- Quarter
  { name="1/8",   val=32 },     -- Eighth
  { name="1/16",  val=64 },     -- 16th
  { name="1/32",  val=128 },    
  { name="1/64",  val=256 },     
  { name="1/128", val=512 },    
}

-- Non-Standard Columns Definition
-- k: label suffix/key, m: multiplier of val
local non_std_cols = {
  { k=5,  m=1.25 },
  { k=7,  m=1.75 },
  { k=9,  m=2.25 },
  { k=11, m=2.75 },
  { k=13, m=3.25 },
}

-- Helper to get base denominator from val
function GetBaseDenom(val)
  return val / 4
end

-- Detect Trigger Key
local trigger_key = nil
local start_time = reaper.time_precise()
local anim_start_time = start_time

function get_trigger_key()
  -- Use timestamp-based state check like other working scripts
  local state = reaper.JS_VKeys_GetState(start_time - 2)
  for i = 1, 255 do
    -- Filter out mouse buttons (1=L, 2=R, 4=M, 5=X1, 6=X2)
    if i > 6 then 
       -- Check if key is pressed (== 1 pattern used by working scripts)
       if state:byte(i) == 1 then
          return i 
       end
    end
  end
  return nil
end

trigger_key = get_trigger_key()

function GetCurrentGrid()
  local _, division, swingmode, swingamt = reaper.GetSetProjectGrid(0, false)
  if division == 0 then return 0 end
  return 4.0 / division
end

function SetGrid(val)
  -- grid = 4 / val
  local grid_val = 4.0 / val
  reaper.GetSetProjectGrid(0, true, grid_val)
end

function IsCloseEnough(a, b)
  return math.abs(a - b) < 0.001
end

function DrawStylishButton(label, val, is_active)
  -- Animation: Pulse for active button
  local btn_color = COL_BTN_BASE
  local hvr_color = COL_BTN_HOVER
  
  if is_active then
    -- Simple pulse calculation logic for color
    -- We won't do full continuous redraw unless mouse moves, but defer loop handles it.
    local time = reaper.time_precise()
    -- Gentle pulse for active state
    -- local pulse = (math.sin(time * 6) + 1) * 0.5 
    
    btn_color = COL_BTN_ACTIVE
    hvr_color = COL_BTN_ACTIVE_HOVER
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), btn_color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), hvr_color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), hvr_color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_TEXT)
  
  -- Rounding
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
  
  if reaper.ImGui_Button(ctx, label, BTN_W, BTN_H) or reaper.ImGui_IsItemHovered(ctx) then
    if not IsCloseEnough(GetCurrentGrid(), val) then
      SetGrid(val)
    end
  end
  
  reaper.ImGui_PopStyleVar(ctx) -- FrameRounding
  reaper.ImGui_PopStyleColor(ctx, 4)
end

local initial_pos_set = false

function loop()
  -- Check trigger key
  if trigger_key then
    -- Use timestamp-based state check like other working scripts
    local state = reaper.JS_VKeys_GetState(start_time - 2)
    -- Check if key is still held (== 1 pattern)
    if state:byte(trigger_key) ~= 1 then
      return -- Key released
    end
  else
    -- Fallback if no key detected: Close on left click after delay
    if reaper.time_precise() - start_time > 0.3 and reaper.JS_Mouse_GetState(1) == 1 then
       return 
    end
    -- Optional: If we wanted "Hold" behavior but couldn't detect key, 
    -- we might need to just exit immediately or rely on the fallback.
    -- But the user issue is specifically "won't terminate".
    -- If trigger_key is set but it's not terminating, maybe the key code is wrong 
    -- or the state isn't updating properly?
    -- But JS_VKeys_GetState(0) usually works fine. 
    
    -- However, REAPER might re-run the script if key is held? 
    -- No, that's only if the action is set to re-trigger.
    -- If the script is running in a defer loop, REAPER considers it "running".
  end
  
  local current_grid = GetCurrentGrid()
  
  -- Window Styles
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), WINDOW_PAD_X, WINDOW_PAD_Y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), SPACING_X, SPACING_Y)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COL_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x555555FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)
  
  local window_flags = reaper.ImGui_WindowFlags_NoTitleBar() | 
                       reaper.ImGui_WindowFlags_NoResize() | 
                       reaper.ImGui_WindowFlags_NoScrollbar() |
                       reaper.ImGui_WindowFlags_AlwaysAutoResize() |
                       reaper.ImGui_WindowFlags_NoSavedSettings()
                       
  if not initial_pos_set then
    -- Default to Quarter Note (Row 3, val=16)
    local target_row = 3 
    local target_col = 2 -- Standard
    
    -- Find target row/col
    local found = false
    for r, base in ipairs(standard_grids) do
      -- Dotted (Col 1)
      local val_d = base.val / 1.5
      if IsCloseEnough(current_grid, val_d) then target_row = r; target_col = 1; found = true; break end
      
      -- Standard (Col 2)
      if IsCloseEnough(current_grid, base.val) then target_row = r; target_col = 2; found = true; break end
      
      -- Triplet (Col 3)
      local val_t = base.val * 1.5
      if IsCloseEnough(current_grid, val_t) then target_row = r; target_col = 3; found = true; break end
      
      -- Non-Standard Cols (Col 4+)
      for ns_i, ns in ipairs(non_std_cols) do
         local val_ns = base.val * ns.m
         if IsCloseEnough(current_grid, val_ns) then
            target_row = r
            target_col = 3 + ns_i 
            found = true
            break
         end
      end
      if found then break end
    end
    
    -- Calculate Target X/Y relative to Window Content Top-Left
    -- Cols: Dotted(1), Standard(2), Triplet(3) |Gap| NS1(4) | NS2(5) ...
    local target_x = 0
    if target_col <= 3 then
       target_x = (target_col - 1) * (BTN_W + SPACING_X)
    else
       -- Non-Standard: 3 cols + Gap + (target_col - 4) cols
       local ns_index = target_col - 3
       target_x = 3 * (BTN_W + SPACING_X) + GAP_BEFORE_NONSTD + (ns_index - 1) * (BTN_W + SPACING_X)
    end
    
    -- Header offset
    local header_height = reaper.ImGui_GetTextLineHeight(ctx) + SPACING_Y
    local target_y = (target_row - 1) * (BTN_H + SPACING_Y) + header_height
    
    -- Mouse Position
    local mx, my = reaper.GetMousePosition()
    
    -- Convert from native screen coordinates to ImGui coordinates
    if reaper.ImGui_PointConvertNative then
      mx, my = reaper.ImGui_PointConvertNative(ctx, mx, my, true)
    end
    
    -- Calculate Window Top-Left
    -- Window X = MouseX - (WindowPadding + TargetX + BtnW/2)
    local win_x = mx - (WINDOW_PAD_X + target_x + (BTN_W / 2))
    local win_y = my - (WINDOW_PAD_Y + target_y + (BTN_H / 2))
    
    reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y)
    initial_pos_set = true
  end

  -- Intro Animation (Opacity Fade In)
  local elapsed = reaper.time_precise() - anim_start_time
  local alpha = math.min(elapsed / 0.15, 1.0) -- 150ms fade in
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), alpha)

  local visible, open = reaper.ImGui_Begin(ctx, 'GridSelector', true, window_flags)
  
  if visible then
  
    -- Headers Helper
    local function CenterText(text, width)
        local tw = reaper.ImGui_CalcTextSize(ctx, text)
        local off = (width - tw) * 0.5
        if off > 0 then reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + off) end
        reaper.ImGui_Text(ctx, text)
    end
    
    -- Headers Row
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_HEADER)
    
    reaper.ImGui_BeginGroup(ctx)
      -- Dotted
      reaper.ImGui_BeginGroup(ctx)
      CenterText("Dotted", BTN_W)
      reaper.ImGui_EndGroup(ctx)
      reaper.ImGui_SameLine(ctx)
      
      -- Straight
      reaper.ImGui_BeginGroup(ctx)
      CenterText("Straight", BTN_W)
      reaper.ImGui_EndGroup(ctx)
      reaper.ImGui_SameLine(ctx)
      
      -- Triplet
      reaper.ImGui_BeginGroup(ctx)
      CenterText("Triplet", BTN_W)
      reaper.ImGui_EndGroup(ctx)
      reaper.ImGui_SameLine(ctx)
      
      -- Gap
      reaper.ImGui_Dummy(ctx, GAP_BEFORE_NONSTD, 1)
      reaper.ImGui_SameLine(ctx)
      
      -- Odd / Non-Standard
      reaper.ImGui_BeginGroup(ctx)
      -- Center "Odd" over the group of non-std buttons
      local non_std_width = BTN_W * #non_std_cols + SPACING_X * (#non_std_cols - 1)
      CenterText("Odd", non_std_width)
      reaper.ImGui_EndGroup(ctx)
    reaper.ImGui_EndGroup(ctx)
    
    reaper.ImGui_PopStyleColor(ctx) -- Header Text
    
    reaper.ImGui_Separator(ctx)
    -- Add a little spacing after separator
    reaper.ImGui_Dummy(ctx, 1, 2) 

    -- Grid Buttons
    for i, base in ipairs(standard_grids) do
      local denom = GetBaseDenom(base.val)
      
      -- Dotted (Col 1)
      reaper.ImGui_PushID(ctx, "dot"..i)
      local val_d = base.val / 1.5
      DrawStylishButton(base.name .. " D", val_d, IsCloseEnough(current_grid, val_d))
      reaper.ImGui_PopID(ctx)
      
      reaper.ImGui_SameLine(ctx)
      
      -- Standard (Col 2)
      reaper.ImGui_PushID(ctx, "std"..i)
      DrawStylishButton(base.name, base.val, IsCloseEnough(current_grid, base.val))
      reaper.ImGui_PopID(ctx)
      
      reaper.ImGui_SameLine(ctx)
      
      -- Triplet (Col 3)
      reaper.ImGui_PushID(ctx, "trip"..i)
      local val_t = base.val * 1.5
      DrawStylishButton(base.name .. " T", val_t, IsCloseEnough(current_grid, val_t))
      reaper.ImGui_PopID(ctx)
      
      -- Gap
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_Dummy(ctx, GAP_BEFORE_NONSTD, 1)
      reaper.ImGui_SameLine(ctx)
      
      -- Non-Standard Cols
      for ns_i, ns in ipairs(non_std_cols) do
         reaper.ImGui_PushID(ctx, "ns"..ns.k..i)
         local val_ns = base.val * ns.m
         local denom_ns = denom * ns.m
         local label_ns = string.format("1/%g", denom_ns)
         if denom_ns < 1 then label_ns = "1/" .. denom_ns end
         
         DrawStylishButton(label_ns, val_ns, IsCloseEnough(current_grid, val_ns))
         reaper.ImGui_PopID(ctx)
         
         if ns_i < #non_std_cols then
            reaper.ImGui_SameLine(ctx)
         end
      end
    end
    
    reaper.ImGui_End(ctx)
  end
  
  reaper.ImGui_PopStyleVar(ctx, 4) -- Alpha, WinPad, ItemSpacing, BorderSize
  reaper.ImGui_PopStyleColor(ctx, 2) -- WinBg, Border

  if open then
    reaper.defer(loop)
  end
end

loop()
