-- Item Pan Knob Overlay
-- Displays a transparent knob over every selected media item in the Arrange view.
-- Dragging the knob changes the item's pan value (-1.0 = left, 1.0 = right).
-- Requires:  
--   • ReaImGui (v0.8+) – https://github.com/ReaTeam/ReaScripts/wiki/ReaImGui-API  
--   • JS_ReaScriptAPI – https://github.com/ReaTeam/JS_ReaScriptAPI
local r = reaper
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'

im = require 'imgui' '0.9.3'
local ctx = im.CreateContext('Item Pan Knob Overlay', im.ConfigFlags_DockingEnable)
-- Modifier masks with safe fallbacks
local MOD_CTRL  = im.Mod_Ctrl  or 0
local MOD_ALT   = im.Mod_Alt   or 0
local MOD_SHIFT = im.Mod_Shift or 0
local MOD_CMD   = im.Mod_Super or 0 -- macOS Command key
-- Persistent multi-drag state across frames
local multi = {
  active = false,
  leader_item = nil,
  leader_take = nil,
  leader_start_pan = 0.0,
  direction = 1, -- 1 = same, -1 = opposite
  baselines = nil
}

UserOS = r.GetOS()
if UserOS == "OSX32" or UserOS == "OSX64" or UserOS == "macOS-arm64" then
  MOD_CMD = im.Mod_Super or 0
  Using_MacOS = true
end
--------------------------------------------------------------------
-- Safety checks ----------------------------------------------------
--------------------------------------------------------------------
if not im.CreateContext then
  r.ShowMessageBox("ReaImGui extension is required.", "Error", 0)
  return
end
if not r.JS_Window_FindChildByID then
  r.ShowMessageBox("JS_ReaScriptAPI extension is required.", "Error", 0)
  return
end

--------------------------------------------------------------------
-- ImGui setup ------------------------------------------------------
--------------------------------------------------------------------
local FONT_SIZE = 14
local knob_radius = 12  -- visual radius in pixels (knob diameter = 24px)

-- Load default font slightly larger so the knob looks crisp
function msg(str)
  r.ShowConsoleMsg(str)
end

--------------------------------------------------------------------
-- Helper: draw a rotary knob (derived from Add_WetDryKnob) ---------
--------------------------------------------------------------------
local function Add_PanKnob(ctx, id, value, radius)
  -- value is expected in range ‑1.0 .. 1.0
  radius = radius or knob_radius
  local line_height = im.GetTextLineHeight(ctx)
  local suppress_multi = false
  
  -- We only need an invisible button to capture mouse interaction (make it wider to accommodate text)
  im.InvisibleButton(ctx, id, radius * 2 + 40, radius * 2 + line_height - 10)

  ------------------------------------------------------------------
  -- Mouse handling -------------------------------------------------
  ------------------------------------------------------------------
  local is_active = im.IsItemActive(ctx)
  local mouse_delta_y = select(2, im.GetMouseDelta(ctx))
  
  -- Check for double-click (center the knob)
  if im.IsItemClicked(ctx, im.MouseButton_Left) and im.IsMouseDoubleClicked(ctx, im.MouseButton_Left) then
    local mods = im.GetKeyMods(ctx)
    local has_ctrl = ((mods & MOD_CTRL) ~= 0) or ((mods & MOD_CMD) ~= 0)
    
    if has_ctrl then
      -- Ctrl + double-click: center all selected items
      local sel_count = r.CountSelectedMediaItems(0)
      for i = 0, sel_count - 1 do
        local item = r.GetSelectedMediaItem(0, i)
        if item then
          local take = r.GetActiveTake(item)
          if take then
            r.SetMediaItemTakeInfo_Value(take, 'D_PAN', 0.0)
          end
        end
      end
      r.UpdateArrange()
      -- Also center the current knob value and suppress multi-drag for this frame
      value = 0.0
      suppress_multi = true
    else
      -- Regular double-click: center just this knob
      value = 0.0  -- Center position (0.0 = center pan)
    end
  end
  
  -- Handle mouse dragging
  if is_active and mouse_delta_y ~= 0.0 then
    local step = 2 / 200.0  -- full range (-1..1) divided into 200 steps
    local mods = im.GetKeyMods(ctx)
    if (mods & MOD_SHIFT) ~= 0 then step = step / 5 end
    value = value + (-mouse_delta_y) * step
    value = math.max(-1.0, math.min(1.0, value))
  end

  ------------------------------------------------------------------
  -- Drawing --------------------------------------------------------
  ------------------------------------------------------------------
  local tlx, tly = im.GetItemRectMin(ctx)
  local center_x, center_y = tlx + radius, tly + radius
  local draw_list = im.GetWindowDrawList(ctx)

  -- Background circle (fully transparent)
  im.DrawList_AddCircleFilled(draw_list, center_x, center_y, radius, 0x000000ff)


  -- Foreground circle outline
  im.DrawList_AddCircle(draw_list, center_x, center_y, radius, 0xFFFFFFFF, 0, 1.0)

  -- Pointer
  local t = (value + 1.0) / 2.0 -- map ‑1..1 → 0..1
  local ANGLE_MIN = math.pi * 0.75
  local ANGLE_MAX = math.pi * 2.25
  local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * t
  local angle_cos, angle_sin = math.cos(angle), math.sin(angle)
  local pointer_length = radius * 0.6
  im.DrawList_AddLine(draw_list, center_x, center_y, center_x + angle_cos * pointer_length, center_y + angle_sin * pointer_length, 0xFFFFFFFF, 2.0)
  -- Center dot
  im.DrawList_AddCircleFilled(draw_list, center_x, center_y, math.max(1, radius * 0.2), 0xFF202020)
  
  -- Draw numeric value indicator
  local pan_value = math.floor(value * 100) -- Convert to percentage (-100 to +100)
  local value_text
  if pan_value == 0 then
    value_text = "C" -- Center
  elseif pan_value > 0 then
    value_text = string.format("%d", pan_value) -- Positive (right)
  else
    value_text = string.format("%d", pan_value) -- Negative (left)
  end
  
  -- Calculate text position (to the right of the knob)
  local text_width, text_height = im.CalcTextSize(ctx, value_text)
  local text_x = center_x + radius + 5 -- 5 pixels to the right of knob edge
  local text_y = center_y - text_height * 0.5 -- Vertically centered with knob
  
  -- Draw text with shadow for better visibility
  im.DrawList_AddText(draw_list, text_x + 1, text_y + 1, 0xFF000000, value_text) -- Shadow
  im.DrawList_AddText(draw_list, text_x, text_y, 0xFFFFFFFF, value_text) -- Main text
  
  return value, is_active, suppress_multi
end

--------------------------------------------------------------------
-- Main loop --------------------------------------------------------
--------------------------------------------------------------------
local arrange_hwnd = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000) -- Arrange view
local function getTrackPosAndHeight(track)
  if track then
    local height = r.GetMediaTrackInfo_Value(track, "I_WNDH") -- current TCP window height in pixels including envelopes
    local posy = r.GetMediaTrackInfo_Value(track, "I_TCPY")   -- current TCP window Y-position in pixels relative to top of arrange view
    return posy, height
  end
end
local screen_left, screen_top, screen_right, screen_bottom = reaper.JS_Window_MonitorFromRect(0, 0, 0, 0, true)
if Using_MacOS then
  screen_bottom, screen_top = screen_top, screen_bottom
end
local screen_width = screen_right - screen_left
local screen_height = screen_bottom - screen_top

local function loop()
  if not r.ValidatePtr(arrange_hwnd, 'HWND') then  return end
  -- Get the top of the arrange window from INI (used for TCP calculations)
  Top_Arrang = tonumber(select(2, r.BR_Win32_GetPrivateProfileString("REAPER", "toppane", "", r.get_ini_file()))) + 5
  
  -- Fetch arrange view geometry and time range (rv_top is the screen Y coordinate of arrange window top)
  local rv_left, rv_top, rv_right, rv_bottom = select(2, r.JS_Window_GetRect(arrange_hwnd))
  --[[ if rv_bottom < rv_top then rv_top, rv_bottom = rv_bottom, rv_top end ]]
  if Using_MacOS then
    rv_top = screen_top + (screen_height - rv_top) 
    Top_Arrang = rv_top 
  end
  local arrange_start, arrange_end = r.GetSet_ArrangeView2(0, false, 0, 0)
  -- GetHZoomLevel returns pixels per second directly
  local px_per_sec = r.GetHZoomLevel()

  -- Begin ImGui frame ------------------------------------------------------
  im.SetNextWindowBgAlpha(ctx, 0.0) -- ensure windows are transparent
  local win_flags = im.WindowFlags_NoDecoration  | im.WindowFlags_NoNav | im.WindowFlags_NoScrollWithMouse | im.WindowFlags_NoBackground

  -- Multi-drag state for this frame
  local multi_drag_delta = nil
  local multi_drag_leader = nil
  local multi_drag_direction = 1 -- 1 = same (Ctrl), -1 = opposite (Alt)

  ------------------------------------------------------------------
  -- Iterate over selected items -----------------------------------
  ------------------------------------------------------------------
  local sel_count = r.CountSelectedMediaItems(0)
  for i = 0, sel_count - 1 do
  
    local item = r.GetSelectedMediaItem(0, i)
    if item then
      local item_pos   = r.GetMediaItemInfo_Value(item, 'D_POSITION')
      local item_len   = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local take       = r.GetActiveTake(item)
      local take_pan   = 0
      if take then take_pan = r.GetMediaItemTakeInfo_Value(take, 'D_PAN') end
      local track      = r.GetMediaItem_Track(item)
      -- Use same method as FXD_Vertical FX list
      local track_y    = r.GetMediaTrackInfo_Value(track, 'I_TCPY')-- current TCP window Y-position in pixels relative to top of arrange view
      local track_h    = r.GetMediaTrackInfo_Value(track, 'I_WNDH')-- current TCP window height in pixels including envelopes
      -- Item coordinates
      local item_x     = r.GetMediaItemInfo_Value(item, 'I_LASTX')
      local item_w     = r.GetMediaItemInfo_Value(item, 'I_LASTW')
      local item_Free_Y = r.GetMediaItemInfo_Value(item, 'F_FREEMODE_Y')
      local item_Free_Y = item_Free_Y and item_Free_Y * track_h 
      local item_y     = r.GetMediaItemInfo_Value(item, 'I_LASTY')
      local item_h     = r.GetMediaItemInfo_Value(item, 'I_LASTH')
      -- Only draw knob if item is (even partially) within arrange view
      if item_pos < arrange_end and (item_pos + item_len) > arrange_start then
        -- Centre of item in pixels (horizontal) - manual time to pixel conversion
        local item_center_time = item_pos + item_len * 0.5
        local time_offset = item_center_time - arrange_start
        local item_pixel_x = rv_left + (time_offset * px_per_sec)
        
      -- Item coordinates (I_LASTY and I_LASTH are already in screen coordinates)
      local ar = knob_radius
      local track_top_y = Top_Arrang + track_y
      -- Center vertically based on item's screen position and height
      local item_pos_from_trk_top = (item_Free_Y or item_y) + (item_h * 0.5)
      local min_center_y = track_top_y + ar
      local max_center_y = track_top_y + track_h - ar
      local center_y =  track_top_y +item_pos_from_trk_top
     --[[  if center_y < min_center_y then center_y = min_center_y end
      if center_y > max_center_y then center_y = max_center_y end ]]

        -- Window centered on knob (wider to accommodate text)
        -- Clamp horizontally to stay within arrange view
        local knob_center_x = item_pixel_x
        local min_center_x = rv_left + ar * 1.5
        local max_center_x = rv_right - ar * 1.5 - 40 -- Extra space for text
        if knob_center_x < min_center_x then knob_center_x = min_center_x end
        if knob_center_x > max_center_x then knob_center_x = max_center_x end
        local win_x = knob_center_x - ar * 1.5
        local win_y = center_y --[[ - ar * 1.5 ]]

        -- Skip if off-screen vertically (use absolute center)
        
          
        -- Create a window large enough for the knob and text
        im.SetNextWindowBgAlpha(ctx, 0.0) -- ensure this window is transparent
        im.SetNextWindowPos(ctx, win_x, win_y)
        im.SetNextWindowSize(ctx, ar*3 + 40, ar*3) -- Wider to accommodate text
        im.Begin(ctx, '##pan_win' .. tostring(item), nil, win_flags)
        -- Center the knob inside the larger window
        im.SetCursorPos(ctx, ar * 0.5, ar * 0.5)
        local new_pan, is_active, suppress_multi = Add_PanKnob(ctx, '##pan' .. tostring(item), take_pan, ar)
        im.End(ctx)
        if new_pan ~= take_pan then
          if take then r.SetMediaItemTakeInfo_Value(take, 'D_PAN', new_pan) end
          r.UpdateArrange()
        end

        -- Start multi-drag if this knob is being dragged with Ctrl/Alt (or Cmd)
        if not multi.active and is_active and not suppress_multi then
          local mods = im.GetKeyMods(ctx)
          local has_ctrl = ((mods & MOD_CTRL) ~= 0) or ((mods & MOD_CMD) ~= 0)
          local has_alt  = ((mods & MOD_ALT)  ~= 0)
          if has_ctrl or has_alt then
            multi.active = true
            multi.leader_item = item
            multi.leader_take = take
            multi.leader_start_pan = take_pan -- value before this frame's change
            multi.direction = has_alt and -1 or 1
            -- Capture baselines for all selected items
            multi.baselines = {}
            local sc = r.CountSelectedMediaItems(0)
            for ii = 0, sc - 1 do
              local it0 = r.GetSelectedMediaItem(0, ii)
              if it0 then
                local tk0 = r.GetActiveTake(it0)
                local pan0 = 0.0
                if tk0 then pan0 = r.GetMediaItemTakeInfo_Value(tk0, 'D_PAN') end
                multi.baselines[it0] = pan0
              end
            end
          end
        end

      end
    end
  end

  -- Apply multi-drag continuously while dragging
  if multi.active then
    -- End condition: mouse released or leader invalid
    if not im.IsMouseDown(ctx, im.MouseButton_Left) or not multi.leader_item then
      multi.active = false
      multi.leader_item = nil
      multi.leader_take = nil
      multi.baselines = nil
    else
      -- Compute leader delta from starting pan
      local leader_pan_now = 0.0
      if multi.leader_take and r.ValidatePtr(multi.leader_take, 'MediaItem_Take*') then
        leader_pan_now = r.GetMediaItemTakeInfo_Value(multi.leader_take, 'D_PAN')
      else
        -- If take lost, try to reacquire
        local it = multi.leader_item
        if it and r.ValidatePtr(it, 'MediaItem*') then
          local tk = r.GetActiveTake(it)
          multi.leader_take = tk
          if tk then leader_pan_now = r.GetMediaItemTakeInfo_Value(tk, 'D_PAN') end
        end
      end
      local delta = leader_pan_now - multi.leader_start_pan

      -- Verify modifiers are still held (Ctrl/Cmd or Alt)
      local mods_now = im.GetKeyMods(ctx)
      local has_ctrl_now = ((mods_now & MOD_CTRL) ~= 0) or ((mods_now & MOD_CMD) ~= 0)
      local has_alt_now  = ((mods_now & MOD_ALT)  ~= 0)
      if not (has_ctrl_now or has_alt_now) then
        -- Stop multi if modifiers released
        multi.active = false
        multi.leader_item = nil
        multi.leader_take = nil
        multi.baselines = nil
      else
        local any_changed = false
        local sc2 = r.CountSelectedMediaItems(0)
        for i2 = 0, sc2 - 1 do
          local it2 = r.GetSelectedMediaItem(0, i2)
          if it2 and it2 ~= multi.leader_item then
            local tk2 = r.GetActiveTake(it2)
            if tk2 then
              local base = (multi.baselines and multi.baselines[it2]) or r.GetMediaItemTakeInfo_Value(tk2, 'D_PAN')
              local newp = base + (multi.direction * delta)
              if newp > 1.0 then newp = 1.0 elseif newp < -1.0 then newp = -1.0 end
              local cur = r.GetMediaItemTakeInfo_Value(tk2, 'D_PAN')
              if newp ~= cur then
                r.SetMediaItemTakeInfo_Value(tk2, 'D_PAN', newp)
                any_changed = true
              end
            end
          end
        end
        if any_changed then r.UpdateArrange() end
      end
    end
  end


  r.defer(loop)
end

--------------------------------------------------------------------
-- Start script -----------------------------------------------------
--------------------------------------------------------------------
r.defer(loop)
