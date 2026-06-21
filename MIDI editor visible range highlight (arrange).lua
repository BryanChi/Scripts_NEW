-- MIDI editor visible range highlight (arrange view)
-- Run once to start, run again to stop.

local r = reaper

local SCRIPT_NAME = "MIDI editor visible range highlight (arrange)"
local EXT_SECTION = "MIDIEditorArrangeHighlight"
local EXT_KEY_RUNNING = "running"

local RANGE_FILL = 0x6600AAFF
local RANGE_BORDER = 0xFF00AAFF
local THICKNESS = 2.0
local MAC_RETINA_SCALE = 0.5

local function have_deps()
  return r.ImGui_CreateContext
    and r.JS_Window_FindChildByID
    and r.JS_Window_GetClientRect
    and r.JS_Window_ClientToScreen
    and r.MIDIEditor_GetActive
end

if not have_deps() then
  r.MB("This script requires ReaImGui and js_ReaScriptAPI.", SCRIPT_NAME, 0)
  return
end

local function is_running()
  return r.GetExtState(EXT_SECTION, EXT_KEY_RUNNING) == "1"
end

local function set_running(on)
  r.SetExtState(EXT_SECTION, EXT_KEY_RUNNING, on and "1" or "0", false)
end

if is_running() then
  set_running(false)
  r.ShowConsoleMsg(SCRIPT_NAME .. ": stopped.\n")
  return
end

set_running(true)
r.ShowConsoleMsg(SCRIPT_NAME .. ": started. Run again to stop.\n")

local ctx = r.ImGui_CreateContext(SCRIPT_NAME)
local flags = 0
flags = flags | (r.ImGui_WindowFlags_NoDecoration and r.ImGui_WindowFlags_NoDecoration() or 0)
flags = flags | (r.ImGui_WindowFlags_NoInputs and r.ImGui_WindowFlags_NoInputs() or 0)
flags = flags | (r.ImGui_WindowFlags_NoNav and r.ImGui_WindowFlags_NoNav() or 0)
flags = flags | (r.ImGui_WindowFlags_NoBackground and r.ImGui_WindowFlags_NoBackground() or 0)
flags = flags | (r.ImGui_WindowFlags_NoBringToFrontOnFocus and r.ImGui_WindowFlags_NoBringToFrontOnFocus() or 0)

local os_name = r.GetOS() or ""
local is_macos = os_name:match("OSX") or os_name:match("macOS")
local screen_left, screen_top, screen_right, screen_bottom =
  r.JS_Window_MonitorFromRect(0, 0, 0, 0, true)
if is_macos then
  screen_bottom, screen_top = screen_top, screen_bottom
end
local screen_height = screen_bottom - screen_top

local function native_to_imgui(x, y)
  if r.ImGui_PointConvertNative then
    local ok, ix, iy = pcall(r.ImGui_PointConvertNative, ctx, x, y, true)
    if ok and ix and iy then return ix, iy end
  end
  return x, y
end

local function get_arrange_rect_screen()
  local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000)
  if not arrange then return nil end
  local ok, l, t, rr, bb = r.JS_Window_GetClientRect(arrange)
  if not ok then return nil end
  local sx, sy = r.JS_Window_ClientToScreen(arrange, 0, 0)
  local nx1, ny1 = sx, sy
  local nx2, ny2 = sx + (rr - l), sy + (bb - t)
  local ix1, iy1 = native_to_imgui(nx1, ny1)
  local ix2, iy2 = native_to_imgui(nx2, ny2)
  if ix2 < ix1 then ix1, ix2 = ix2, ix1 end
  if iy2 < iy1 then iy1, iy2 = iy2, iy1 end
  return ix1, iy1, ix2, iy2, nx1, ny1, nx2, ny2
end

local function get_arrange_top_native()
  local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000)
  if not arrange then return nil end

  if r.BR_Win32_GetPrivateProfileString then
    local top = tonumber(select(2, r.BR_Win32_GetPrivateProfileString("REAPER", "toppane", "", r.get_ini_file())))
    if top then
      top = top + 5
      if is_macos and r.JS_Window_GetRect then
        local ok, _l, rv_top = r.JS_Window_GetRect(arrange)
        if ok then top = screen_top + (screen_height - rv_top) end
      end
      return top
    end
  end

  local _sx, sy = r.JS_Window_ClientToScreen(arrange, 0, 0)
  return sy
end

local function get_midiview_width(editor)
  local midiview = r.JS_Window_FindChildByID(editor, 1001) or editor
  local ok, l, _t, rr, _b = r.JS_Window_GetClientRect(midiview)
  if not ok then return nil end
  return math.max(1, rr - l)
end

local function get_take_chunk(take)
  local item = r.GetMediaItemTake_Item(take)
  if not item then return nil end
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok or not chunk then return nil end

  local take_num = math.floor(r.GetMediaItemTakeInfo_Value(take, "IP_TAKENUMBER") or 0)
  local start_pos = 1
  for _ = 1, take_num do
    start_pos = chunk:find("\nTAKE[^\n]-\nNAME", start_pos + 1)
    if not start_pos then return nil end
  end
  local end_pos = chunk:find("\nTAKE[^\n]-\nNAME", start_pos + 1)
  return chunk:sub(start_pos, end_pos or -1), chunk
end

local function get_visible_time_range(take, viewport_px)
  local item = r.GetMediaItemTake_Item(take)
  if not item then return nil end

  local take_chunk, full_chunk = get_take_chunk(take)
  if not take_chunk then return nil end

  local left_tick_s, hzoom_s = take_chunk:match("\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)")
  if not left_tick_s then
    left_tick_s, hzoom_s = (full_chunk or ""):match("\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)")
  end
  local left_tick = tonumber(left_tick_s)
  local hzoom = tonumber(hzoom_s)
  if not left_tick or not hzoom or hzoom <= 0 then return nil end

  local _active_channel, tb_s = take_chunk:match(
    "\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+)"
  )
  if not tb_s then
    _active_channel, tb_s = (full_chunk or ""):match(
      "\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+)"
    )
  end
  local tb = tonumber(tb_s or "")
  local is_beats = (tb == 0) or (tb == 4) or (tb == nil)

  local os_name = r.GetOS() or ""
  local is_macos = os_name:match("OSX") or os_name:match("macOS")
  local scale = is_macos and MAC_RETINA_SCALE or 1.0
  local span_px = (viewport_px or 0) / scale
  if span_px <= 0 then return nil end

  local left_time = r.MIDI_GetProjTimeFromPPQPos(take, left_tick)
  if not left_time then return nil end

  local right_time
  if is_beats then
    local right_tick = left_tick + (span_px / hzoom)
    right_time = r.MIDI_GetProjTimeFromPPQPos(take, right_tick)
  else
    right_time = left_time + (span_px / hzoom)
  end
  if not right_time or right_time <= left_time then return nil end
  return left_time, right_time
end

local function draw_active_take_highlight(ax1, ay1, ax2, ay2, nx1, dl)
  local editor = r.MIDIEditor_GetActive()
  if not editor then return end
  local take = r.MIDIEditor_GetTake(editor)
  if not take or not r.TakeIsMIDI(take) then return end

  local item = r.GetMediaItemTake_Item(take)
  if not item then return end

  local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  if item_len <= 0 then return end
  local item_end = item_pos + item_len

  local viewport_px = get_midiview_width(editor) or 1
  local left_t, right_t = get_visible_time_range(take, viewport_px)
  if not left_t then
    -- Fallback so overlay is still visible even if CFGEDITVIEW parsing fails.
    left_t, right_t = item_pos, item_end
  end

  local t1 = math.max(left_t, item_pos)
  local t2 = math.min(right_t, item_end)
  if t2 <= t1 then return end

  local view_start, view_end = r.GetSet_ArrangeView2(0, false, 0, 0)
  if not view_start or not view_end or view_end <= view_start then return end

  local x1 = ax1 + ((t1 - view_start) / (view_end - view_start)) * (ax2 - ax1)
  local x2 = ax1 + ((t2 - view_start) / (view_end - view_start)) * (ax2 - ax1)
  if x2 < x1 then x1, x2 = x2, x1 end

  local track = r.GetMediaItemTake_Track(take)
  if not track then return end

  local track_y = r.GetMediaTrackInfo_Value(track, "I_TCPY")
  local track_h = r.GetMediaTrackInfo_Value(track, "I_WNDH")
  local item_y = r.GetMediaItemInfo_Value(item, "I_LASTY")
  local item_h = r.GetMediaItemInfo_Value(item, "I_LASTH")
  local item_free_y = r.GetMediaItemInfo_Value(item, "F_FREEMODE_Y")
  if not item_y or not item_h or item_h <= 0 then return end

  -- Match item pan knob: Top_Arrang + track_y + item_y, then convert to ImGui coords.
  local top_arrang = get_arrange_top_native()
  if not top_arrang then return end
  local item_pos_from_track_top = item_free_y and (item_free_y * track_h) or item_y
  local y1_native = top_arrang + track_y + item_pos_from_track_top
  local _ix, y1 = native_to_imgui(nx1, y1_native)
  local _ix2, y2 = native_to_imgui(nx1, y1_native + item_h)

  r.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, RANGE_FILL)
  r.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, RANGE_BORDER, 0.0, 0, THICKNESS)
end

local function loop()
  if not is_running() then return end
  if r.ImGui_ValidatePtr and r.ImGui_ValidatePtr(ctx, "ImGui_Context*") == false then
    set_running(false)
    return
  end

  local ax1, ay1, ax2, ay2, nx1 = get_arrange_rect_screen()
  if not ax1 then
    r.defer(loop)
    return
  end

  r.ImGui_SetNextWindowPos(ctx, ax1, ay1)
  r.ImGui_SetNextWindowSize(ctx, ax2 - ax1, ay2 - ay1)
  local visible = select(1, r.ImGui_Begin(ctx, "##midi_editor_arrange_highlight", true, flags))
  if visible then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    draw_active_take_highlight(ax1, ay1, ax2, ay2, nx1, dl)
  end
  r.ImGui_End(ctx)

  if r.ValidatePtr2(0, ctx, "ImGui_Context*") then
    r.defer(loop)
  end
end

r.defer(loop)
