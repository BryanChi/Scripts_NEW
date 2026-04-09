-- @description Split note under mouse at nearest grid
-- @version 1.0
-- @author AI Assistant
-- @about
--   In MIDI editor, split the note under the mouse cursor at the grid
--   line nearest to the mouse position.

local function require_sws()
  if reaper.BR_GetMouseCursorContext and reaper.BR_GetMouseCursorContext_MIDI and reaper.BR_GetMouseCursorContext_Position then
    return true
  end
  reaper.MB("This script requires the SWS/S&M extension.", "Missing dependency", 0)
  return false
end

local function is_valid_midi_take(take)
  if not take then return false end
  if not reaper.ValidatePtr2(0, take, "MediaItem_Take*") then return false end
  return reaper.TakeIsMIDI(take)
end

local function get_context()
  local editor = reaper.MIDIEditor_GetActive()
  if not editor then return nil end

  local take = reaper.MIDIEditor_GetTake(editor)
  if not is_valid_midi_take(take) then return nil end

  local _, _, _ = reaper.BR_GetMouseCursorContext()
  local mouse_take, _, note_row = reaper.BR_GetMouseCursorContext_MIDI()
  if is_valid_midi_take(mouse_take) and mouse_take ~= take then
    -- Mouse is over a different take/editor than the active one.
    take = mouse_take
  end

  local mouse_time = reaper.BR_GetMouseCursorContext_Position()
  if (not mouse_time) and reaper.BR_PositionAtMouseCursor then
    mouse_time = reaper.BR_PositionAtMouseCursor(false)
  end
  if not mouse_time then return nil end

  return take, mouse_time, note_row
end

local function nearest_grid_ppq(take, mouse_ppq)
  local grid_qn = reaper.MIDI_GetGrid(take)
  if not grid_qn or grid_qn <= 0 then return nil end

  local mouse_qn = reaper.MIDI_GetProjQNFromPPQPos(take, mouse_ppq)
  local split_qn = math.floor((mouse_qn / grid_qn) + 0.5) * grid_qn
  return reaper.MIDI_GetPPQPosFromProjQN(take, split_qn)
end

local function find_note_under_mouse(take, mouse_ppq, note_row)
  local _, note_count = reaper.MIDI_CountEvts(take)

  local best_match_idx = nil
  local best_match_start = nil
  local best_match_end = nil
  local best_any_idx = nil
  local best_any_start = nil
  local best_any_end = nil
  local use_pitch = type(note_row) == "number" and note_row >= 0 and note_row <= 127

  for i = 0, note_count - 1 do
    local ok, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok and startppq <= mouse_ppq and mouse_ppq < endppq then
      if (not best_any_start) or (startppq > best_any_start) then
        best_any_idx = i
        best_any_start = startppq
        best_any_end = endppq
      end
      if use_pitch and pitch == note_row then
        if (not best_match_start) or (startppq > best_match_start) then
          best_match_idx = i
          best_match_start = startppq
          best_match_end = endppq
        end
      end
    end
  end

  if best_match_idx ~= nil then
    return best_match_idx, best_match_start, best_match_end
  end

  if best_any_idx ~= nil then
    return best_any_idx, best_any_start, best_any_end
  end

  return nil
end

local function split_note(take, idx, split_ppq)
  local ok, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, idx)
  if not ok then return false end
  if split_ppq <= startppq or split_ppq >= endppq then return false end

  reaper.MIDI_DisableSort(take)

  -- Shorten first half.
  reaper.MIDI_SetNote(take, idx, sel, muted, startppq, split_ppq, chan, pitch, vel, true)
  -- Insert second half with same properties.
  reaper.MIDI_InsertNote(take, sel, muted, split_ppq, endppq, chan, pitch, vel, true)

  reaper.MIDI_Sort(take)
  return true
end

local function main()
  if not require_sws() then return end

  local take, mouse_time, note_row = get_context()
  if not is_valid_midi_take(take) then return end

  local mouse_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, mouse_time)
  local split_ppq = nearest_grid_ppq(take, mouse_ppq)
  if not split_ppq then return end

  local idx = nil
  local startppq = nil
  local endppq = nil
  idx, startppq, endppq = find_note_under_mouse(take, mouse_ppq, note_row)
  if not idx then return end

  if split_ppq <= startppq or split_ppq >= endppq then
    return
  end

  reaper.Undo_BeginBlock()
  local ok = split_note(take, idx, split_ppq)
  reaper.Undo_EndBlock(ok and "Split note under mouse at nearest grid" or "Split note under mouse failed", -1)

  if ok then
    reaper.UpdateArrange()
  end
end

main()
