-- MIDI editor / arrange hover position line
-- Run once to start, run again to stop.

local r = reaper

local SCRIPT_NAME = "MIDI editor / arrange hover position line"
local EXT_SECTION = "MIDIEditorHoverArrangeLine"
local EXT_KEY_RUNNING = "running"

local LINE_COLOR = 0x00FFFFFF
local LINE_THICKNESS = 2.0
local MAC_RETINA_SCALE = 0.5

local function have_deps()
  return r.ImGui_CreateContext
    and r.JS_Window_FindChildByID
    and r.JS_Window_GetClientRect
    and r.JS_Window_ClientToScreen
    and r.MIDIEditor_GetActive
    and r.GetMousePosition
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
flags = flags | (r.ImGui_WindowFlags_NoScrollbar and r.ImGui_WindowFlags_NoScrollbar() or 0)
flags = flags | (r.ImGui_WindowFlags_NoScrollWithMouse and r.ImGui_WindowFlags_NoScrollWithMouse() or 0)
flags = flags | (r.ImGui_WindowFlags_NoMove and r.ImGui_WindowFlags_NoMove() or 0)
flags = flags | (r.ImGui_WindowFlags_NoSavedSettings and r.ImGui_WindowFlags_NoSavedSettings() or 0)

local os_name = r.GetOS() or ""
local is_macos = os_name:match("OSX") or os_name:match("macOS")
local last_editor = nil
local last_take = nil
local midi_line_bitmap = nil
local midi_line_window = nil
local midi_line_w = 0
local midi_line_h = 0

local function clear_direct_midi_line()
  if midi_line_window and midi_line_bitmap and r.JS_Composite_Unlink then
    pcall(r.JS_Composite_Unlink, midi_line_window, midi_line_bitmap, true)
  end
  midi_line_window = nil
end

local function destroy_direct_midi_line()
  clear_direct_midi_line()
  if midi_line_bitmap and r.JS_LICE_DestroyBitmap then
    pcall(r.JS_LICE_DestroyBitmap, midi_line_bitmap)
  end
  midi_line_bitmap = nil
  midi_line_w = 0
  midi_line_h = 0
end

r.atexit(destroy_direct_midi_line)

local function native_to_imgui(x, y)
  if r.ImGui_PointConvertNative then
    local ok, ix, iy = pcall(r.ImGui_PointConvertNative, ctx, x, y, true)
    if ok and ix and iy then return ix, iy end
  end
  return x, y
end

local function get_screen_rect(window)
  if not window then return nil end

  local ok, l, t, rr, bb = r.JS_Window_GetClientRect(window)
  if not ok then return nil end

  local sx, sy = r.JS_Window_ClientToScreen(window, 0, 0)
  return sx, sy, sx + (rr - l), sy + (bb - t)
end

local function get_arrange_rect_screen()
  local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 1000)
  local nx1, ny1, nx2, ny2 = get_screen_rect(arrange)
  if not nx1 then return nil end

  local ix1, iy1 = native_to_imgui(nx1, ny1)
  local ix2, iy2 = native_to_imgui(nx2, ny2)
  if ix2 < ix1 then ix1, ix2 = ix2, ix1 end
  if iy2 < iy1 then iy1, iy2 = iy2, iy1 end

  return ix1, iy1, ix2, iy2, nx1, ny1, nx2, ny2
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

local function get_midi_editor_view(take)
  local take_chunk, full_chunk = get_take_chunk(take)
  if not take_chunk then return nil end

  local left_ppq_s, hzoom_s = take_chunk:match("\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)")
  if not left_ppq_s then
    left_ppq_s, hzoom_s = (full_chunk or ""):match("\nCFGEDITVIEW (%S+) (%S+) (%S+) (%S+)")
  end

  local left_ppq = tonumber(left_ppq_s or "")
  local hzoom = tonumber(hzoom_s or "")
  if not left_ppq or not hzoom or hzoom <= 0 then return nil end

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
  return left_ppq, hzoom, is_beats
end

local function is_valid_midi_editor(editor)
  if not editor then return false end
  if r.JS_Window_IsWindow then
    return r.JS_Window_IsWindow(editor)
  end
  return true
end

local function is_valid_midi_take(take)
  return take
    and (not r.ValidatePtr2 or r.ValidatePtr2(0, take, "MediaItem_Take*"))
    and r.TakeIsMIDI(take)
end

local function get_current_or_last_midi_context()
  local editor = r.MIDIEditor_GetActive()
  local take = editor and r.MIDIEditor_GetTake(editor)

  if is_valid_midi_editor(editor) and is_valid_midi_take(take) then
    last_editor = editor
    last_take = take
    return editor, take
  end

  if is_valid_midi_editor(last_editor) and is_valid_midi_take(last_take) then
    return last_editor, last_take
  end

  return nil, nil
end

local function get_sws_hover_project_time(expected_window)
  if not (r.BR_GetMouseCursorContext and r.BR_GetMouseCursorContext_Position) then
    return nil
  end

  local window = select(1, r.BR_GetMouseCursorContext())
  if expected_window and window ~= expected_window then return nil end

  local time = r.BR_GetMouseCursorContext_Position()
  if (not time or time < 0) and r.BR_PositionAtMouseCursor then
    time = r.BR_PositionAtMouseCursor(false)
  end
  if not time or time < 0 then return nil end

  return time
end

local function get_hover_project_time()
  local editor, take = get_current_or_last_midi_context()
  if not editor or not take then return nil end

  local sws_time = get_sws_hover_project_time("midi_editor")
  if sws_time then return sws_time end

  local midiview = r.JS_Window_FindChildByID(editor, 1001) or editor
  local mx, my = r.GetMousePosition()
  local vx1, vy1, vx2, vy2 = get_screen_rect(midiview)
  if not vx1 then return nil end
  if mx < vx1 or mx > vx2 then return nil end

  local ex1, ey1, ex2, ey2 = get_screen_rect(editor)
  if ex1 and (my < ey1 or my > ey2) then return nil end

  local left_ppq, hzoom, is_beats = get_midi_editor_view(take)
  if not left_ppq then return nil end

  local scale = is_macos and MAC_RETINA_SCALE or 1.0
  local x_px = (mx - vx1) / scale
  if x_px < 0 then return nil end

  if is_beats then
    local ppq = left_ppq + (x_px / hzoom)
    return r.MIDI_GetProjTimeFromPPQPos(take, ppq)
  end

  local left_time = r.MIDI_GetProjTimeFromPPQPos(take, left_ppq)
  if not left_time then return nil end
  return left_time + (x_px / hzoom)
end

local function get_arrange_hover_project_time(nx1, ny1, nx2, ny2)
  local mx, my = r.GetMousePosition()
  if mx < nx1 or mx > nx2 or my < ny1 or my > ny2 then return nil end

  local sws_time = get_sws_hover_project_time("arrange")
  if sws_time then return sws_time end

  local view_start, view_end = r.GetSet_ArrangeView2(0, false, 0, 0)
  if not view_start or not view_end or view_end <= view_start then return nil end

  return view_start + ((mx - nx1) / (nx2 - nx1)) * (view_end - view_start)
end

local function get_midi_editor_rect_screen()
  local editor, take = get_current_or_last_midi_context()
  if not editor or not take then return nil end

  local midiview = r.JS_Window_FindChildByID(editor, 1001) or editor
  local nx1, ny1, nx2, ny2 = get_screen_rect(midiview)
  if not nx1 then return nil end

  local ix1, iy1 = native_to_imgui(nx1, ny1)
  local ix2, iy2 = native_to_imgui(nx2, ny2)
  if ix2 < ix1 then ix1, ix2 = ix2, ix1 end
  if iy2 < iy1 then iy1, iy2 = iy2, iy1 end

  return ix1, iy1, ix2, iy2, nx1, ny1, nx2, ny2, take, midiview
end

local function get_midi_x_from_project_time(take, time, mx1)
  local left_ppq, hzoom, is_beats = get_midi_editor_view(take)
  if not left_ppq then return nil end

  local scale = is_macos and MAC_RETINA_SCALE or 1.0
  if is_beats then
    local ppq = r.MIDI_GetPPQPosFromProjTime(take, time)
    if not ppq then return nil end
    return mx1 + ((ppq - left_ppq) * hzoom * scale)
  end

  local left_time = r.MIDI_GetProjTimeFromPPQPos(take, left_ppq)
  if not left_time then return nil end
  return mx1 + ((time - left_time) * hzoom * scale)
end

local function draw_midi_to_arrange_line(ax1, ay1, ax2, ay2, dl)
  local hover_time = get_hover_project_time()
  if not hover_time then return end

  local view_start, view_end = r.GetSet_ArrangeView2(0, false, 0, 0)
  if not view_start or not view_end or view_end <= view_start then return end

  local x = ax1 + ((hover_time - view_start) / (view_end - view_start)) * (ax2 - ax1)
  if x < ax1 or x > ax2 then return end

  r.ImGui_DrawList_AddLine(dl, x, ay1, x, ay2, LINE_COLOR, LINE_THICKNESS)
end

local function draw_arrange_to_midi_line(mx1, my1, mx2, my2, anx1, any1, anx2, any2, take, dl)
  local hover_time = get_arrange_hover_project_time(anx1, any1, anx2, any2)
  if not hover_time then return end

  local x = get_midi_x_from_project_time(take, hover_time, mx1)
  if not x or x < mx1 or x > mx2 then return end

  r.ImGui_DrawList_AddLine(dl, x, my1, x, my2, LINE_COLOR, LINE_THICKNESS)
end

local function ensure_direct_midi_bitmap(width, height)
  if not (r.JS_LICE_CreateBitmap and r.JS_LICE_DestroyBitmap and r.JS_LICE_Clear and r.JS_LICE_Line and r.JS_Composite) then
    return nil
  end

  width = math.max(1, math.floor(width + 0.5))
  height = math.max(1, math.floor(height + 0.5))

  if midi_line_bitmap and midi_line_w == width and midi_line_h == height then
    return midi_line_bitmap
  end

  destroy_direct_midi_line()
  midi_line_bitmap = r.JS_LICE_CreateBitmap(true, width, height)
  midi_line_w = width
  midi_line_h = height
  return midi_line_bitmap
end

local function draw_direct_midi_line(midiview, nx1, ny1, nx2, ny2, anx1, any1, anx2, any2, take)
  local hover_time = get_arrange_hover_project_time(anx1, any1, anx2, any2)
  if not hover_time then
    clear_direct_midi_line()
    return
  end

  local x = get_midi_x_from_project_time(take, hover_time, nx1)
  if not x or x < nx1 or x > nx2 then
    clear_direct_midi_line()
    return
  end

  local line_w = math.max(1, math.floor(LINE_THICKNESS + 0.5))
  local height = math.max(1, math.floor(ny2 - ny1 + 0.5))
  local bitmap = ensure_direct_midi_bitmap(line_w, height)
  if not bitmap then return end

  -- Direct compositing is used only as a MIDI-editor fallback, so make the
  -- tiny bitmap solid instead of depending on transparent alpha behavior.
  r.JS_LICE_Clear(bitmap, 0xFFFFFF)

  local dst_x = math.floor((x - nx1) - (line_w / 2) + 0.5)
  r.JS_Composite(midiview, dst_x, 0, line_w, height, bitmap, 0, 0, line_w, height, true)
  midi_line_window = midiview
end

local function get_overlay_rect(ax1, ay1, ax2, ay2, mx1, my1, mx2, my2)
  if r.ImGui_GetMainViewport and r.ImGui_Viewport_GetPos and r.ImGui_Viewport_GetSize then
    local ok_vp, vp = pcall(r.ImGui_GetMainViewport, ctx)
    if ok_vp and vp then
      local ok_pos, vx, vy = pcall(r.ImGui_Viewport_GetPos, vp)
      local ok_size, vw, vh = pcall(r.ImGui_Viewport_GetSize, vp)
      if ok_pos and ok_size and vx and vy and vw and vh then
        return vx, vy, vx + vw, vy + vh
      end
    end
  end

  local ox1, oy1, ox2, oy2 = ax1, ay1, ax2, ay2

  if mx1 then
    ox1 = math.min(ox1, mx1)
    oy1 = math.min(oy1, my1)
    ox2 = math.max(ox2, mx2)
    oy2 = math.max(oy2, my2)
  end

  return ox1, oy1, ox2, oy2
end

local function loop()
  if not is_running() then return end
  if r.ImGui_ValidatePtr and r.ImGui_ValidatePtr(ctx, "ImGui_Context*") == false then
    set_running(false)
    return
  end

  local ax1, ay1, ax2, ay2, anx1, any1, anx2, any2 = get_arrange_rect_screen()
  if not ax1 then
    r.defer(loop)
    return
  end

  local mx1, my1, mx2, my2, mnx1, mny1, mnx2, mny2, take, midiview = get_midi_editor_rect_screen()
  local ox1, oy1, ox2, oy2 = get_overlay_rect(ax1, ay1, ax2, ay2, mx1, my1, mx2, my2)

  r.ImGui_SetNextWindowPos(ctx, ox1, oy1)
  r.ImGui_SetNextWindowSize(ctx, ox2 - ox1, oy2 - oy1)
  local visible = select(1, r.ImGui_Begin(ctx, "##midi_editor_arrange_hover_position_lines", true, flags))
  if visible then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    draw_midi_to_arrange_line(ax1, ay1, ax2, ay2, dl)
    if mx1 then
      draw_arrange_to_midi_line(mx1, my1, mx2, my2, anx1, any1, anx2, any2, take, dl)
    end
  end
  r.ImGui_End(ctx)

  if midiview then
    draw_direct_midi_line(midiview, mnx1, mny1, mnx2, mny2, anx1, any1, anx2, any2, take)
  else
    clear_direct_midi_line()
  end

  if r.ValidatePtr2(0, ctx, "ImGui_Context*") then
    r.defer(loop)
  end
end

r.defer(loop)
