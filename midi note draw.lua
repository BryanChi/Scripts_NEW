--[[
MIDI Note Draw.lua
Version: 0.2
Description:
  REAPER MIDI-editor script to rapidly create repeated notes on one pitch.
  Now rendered via ReaImGui with an invisible, full-screen overlay.

  Drag behaviour (unchanged):
    • Horizontal → phrase length (snapped to grid)
    • Vertical   → number of notes (density)

  Dependencies: SWS/S&M + ReaImGui.
--]]

local r = reaper
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
im = require 'imgui' '0.9.3'

if not (im) then
  r.MB("ReaImGui extension required", "Error", 0)
  return
end
--[[ if not r.BR_GetMouseCursorContext_MIDI then
  r.MB("SWS extension required (BR_* functions)", "Error", 0)
  return
end ]]



function msg(str)
  r.ShowConsoleMsg(str)
end

------------------------------------------------
-- PPQ snap helper (fallback if MIDI_SnapPPQPos missing)
------------------------------------------------
local function snapPPQ(take, ppq)
  -- Prefer native snap if available
  if r.MIDI_SnapPPQPos then
    return r.MIDI_SnapPPQPos(take, ppq)
  end
  -- Fallback: approximate using take grid (seconds)
  local grid_sec = r.MIDI_GetGrid(take)
  if not grid_sec or grid_sec <= 0 then return ppq end
  local proj_time = r.MIDI_GetProjTimeFromPPQPos(take, ppq)
  local snapped_time = math.floor((proj_time / grid_sec) + 0.5) * grid_sec
  return r.MIDI_GetPPQPosFromProjTime(take, snapped_time)
end

------------------------------------------------
local function getMouseMIDIInfo(ctx   )
    if not ctx then msg('no ctx') return end
    local ImGuiWin = r.JS_Window_GetFocus()
    local editor = r.MIDIEditor_GetActive()
    r.BR_Win32_SetFocus(editor)

    -- Ensure mouse context is refreshed for SWS
    local Win, section, _, _ = r.BR_GetMouseCursorContext()

    -- Get note row & refresh mouse context (SWS)
    local ok, _, _, noteRow, _, _ = r.BR_GetMouseCursorContext_MIDI()

    local take   = editor and r.MIDIEditor_GetTake(editor)

    -- Mouse project-time position then convert to snapped PPQ
    local projTime = r.BR_GetMouseCursorContext_Position()
    local ppq = r.MIDI_GetPPQPosFromProjTime(take, projTime)
    ppq = snapPPQ(take, ppq)
    r.BR_Win32_SetFocus(ImGuiWin)

    -- ImGui mouse coordinatesx
    local mx, my = im.GetMousePos(ctx)
    return take, ppq, noteRow, mx, my
end



------------------------------------------------
-- ImGui setup (invisible full-screen overlay)
------------------------------------------------
local ctx = im.CreateContext('MIDI Note Draw Overlay')
MouseStart = MouseStart or {im.GetMousePos(ctx)}

------------------------------------------------
-- Initial capture when modifier triggered
------------------------------------------------
take, STARTPPQ, _, startX, startY = getMouseMIDIInfo(ctx)

local flags = im.WindowFlags_NoDecoration | im.WindowFlags_NoBackground |
              im.WindowFlags_NoScrollbar  | im.WindowFlags_NoScrollWithMouse |
              im.WindowFlags_NoMove       | im.WindowFlags_NoSavedSettings

-- Colour helpers
local function u32(hex, a)
  local r = ((hex>>16)&0xFF)/255
  local g = ((hex>>8)&0xFF)/255
  local b = (hex&0xFF)/255
  return im.ColorConvertDouble4ToU32(r,g,b,a or 1)
end
local lineClr = u32(0xffffff, 1)
local fillClr = u32(0x66ccff, 0.15)

------------------------------------------------
-- State vars
------------------------------------------------
local lastMouseDown = im.IsMouseDown(ctx, 0) -- left button state
local lastStatus    = ""

------------------------------------------------
-- Main loop
------------------------------------------------
local function loop()

  
  -- Query mouse each frame
  local takeNow, curPPQ, _, mx, my = getMouseMIDIInfo(ctx)
  if not NOTE_ROW then  
    _, _, NOTE_ROW, _, _, _ = r.BR_GetMouseCursorContext_MIDI()
end

  take = takeNow
  if  not curPPQ then          -- <-- keep!
    r.defer(loop)
    return
  end
  
  -- ΔPPQ relative to the drag start (already snapped in curPPQ)
  local totalPPQ = math.abs(curPPQ - STARTPPQ)
  local dir      = (curPPQ >= STARTPPQ) and 1 or -1

  -- Calculate subdivisions
  totalPPQ       = math.abs(totalPPQ)
  local deltaY   = my - startY
  local numNotes = math.max(1, math.min(64, math.floor(math.abs(deltaY)/20)+1))
  local noteLen  = totalPPQ / (numNotes>0 and numNotes or 1)

  -- Status text in REAPER’s title area
  local MSG = string.format("MIDI-Draw ▶ len %.0fppq | notes %d | each %.0fppq", totalPPQ, numNotes, noteLen)
  if MSG ~= lastStatus then r.GetSetProjectInfo_String(0, "RENDER_FILE", MSG, true); lastStatus = MSG end
  -- Invisible full-screen overlay window
  local vp = im.GetMainViewport(ctx)
  local vpX, vpY = im.Viewport_GetPos(vp)
  local vpW, vpH = im.Viewport_GetSize(vp)
  im.SetNextWindowPos(ctx, vpX, vpY, im.Cond_Always)
  im.SetNextWindowSize(ctx, vpW, vpH, im.Cond_Always)

  local visible, open = im.Begin(ctx, "##MIDI_Draw_Overlay", true, flags)
  if visible then

    if MouseStart[1] and MouseStart[1] < 0 then 
      MouseStart = {im.GetMousePos(ctx)}
    end
    local dl = im.GetWindowDrawList(ctx)
    -- Rectangle coordinates
    local x2, y2 = im.GetMousePos(ctx)
    im.DrawList_AddRect(dl, MouseStart[1], MouseStart[2], x2, y2, lineClr, 0, 0, 2)
    im.DrawList_AddRectFilled(dl, MouseStart[1], MouseStart[2], x2, y2, fillClr)
  end
  im.End(ctx)


  -- Mouse-release → create notes
  local mouseDown = im.IsMouseDown(ctx, 0)
  if lastMouseDown and not mouseDown then
    r.Undo_BeginBlock()
    local chan, vel, sel = 0, 96, true
    for i = 0, numNotes-1 do
        local ns = STARTPPQ + dir * noteLen * i
        local ne = ns + dir * noteLen
              if ne < ns then ns, ne = ne, ns end
      r.MIDI_InsertNote(take, sel, false, ns, ne, chan, NOTE_ROW, vel, false)
    end
    r.MIDI_Sort(take)
    r.Undo_EndBlock("MIDI Note Draw", -1)

    return
  end
  lastMouseDown = mouseDown
  r.defer(loop)
end

loop()
