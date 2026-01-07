-- Insert sustain pedal toggle (CC64 off then on) at mouse position within MIDI item
-- Requirements: SWS/S&M extension (BR_* API)

local function require_sws()
	if reaper and reaper.BR_PositionAtMouseCursor and reaper.BR_TrackAtMouseCursor then
		return true
	end
	reaper.MB("This script requires the SWS/S&M extension.\nPlease install SWS and try again.", "Missing dependency", 0)
	return false
end

local function get_mouse_context()
	local track = select(1, reaper.BR_TrackAtMouseCursor())
	local pos = reaper.BR_PositionAtMouseCursor(false)
	return track, pos
end

local function find_midi_item_take_at_time(track, proj_time)
	if not track then return nil, nil, nil, nil end
	local item_count = reaper.CountTrackMediaItems(track)
	for i = 0, item_count - 1 do
		local item = reaper.GetTrackMediaItem(track, i)
		local it_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
		local it_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
		if proj_time >= it_pos and proj_time < (it_pos + it_len) then
			local take = reaper.GetActiveTake(item)
			if take and reaper.TakeIsMIDI(take) then
				return item, take, it_pos, it_len
			end
		end
	end
	return nil, nil, nil, nil
end

local function insert_cc64_toggle_at_time(take, proj_time)
	local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, proj_time)
	local chan = 0 -- default channel 1
	local lane = 64 -- CC64 sustain pedal
	local off_val = 0
	local on_val = 127
	local ppq_epsilon = 30 -- small gap in ticks (approx 1/32 note at 960 PPQ)

	reaper.MIDI_DisableSort(take)
	-- Insert off then on so the immediate state becomes on, with a clear off event for toggling
	local status = 0xB0 -- CC status base
	local ok1 = reaper.MIDI_InsertCC(take, false, false, ppq, status, chan, lane, off_val)
	local ok2 = reaper.MIDI_InsertCC(take, false, false, ppq + ppq_epsilon, status, chan, lane, on_val)
	reaper.MIDI_Sort(take)
	return ok1 and ok2
end

local function main()
	if not require_sws() then return end
	local track, mouse_time = get_mouse_context()
	if not track or not mouse_time then return end

	-- Try SWS mouse MIDI context first (inline/ME)
	local mtake, _item, _note_row, _cc_lane, _cc_val, _text
	if reaper.BR_GetMouseCursorContext and reaper.BR_GetMouseCursorContext_MIDI then
		reaper.BR_GetMouseCursorContext()
		mtake, _item, _note_row, _cc_lane, _cc_val, _text = reaper.BR_GetMouseCursorContext_MIDI()
	end

	local item, take
	if mtake and reaper.TakeIsMIDI(mtake) then
		take = mtake
	else
		item, take = find_midi_item_take_at_time(track, mouse_time)
	end
	if not take then return end

	reaper.Undo_BeginBlock()
	local ok = insert_cc64_toggle_at_time(take, mouse_time)
	if ok then
		reaper.Undo_EndBlock("Insert CC64 toggle at mouse position", -1)
		reaper.UpdateArrange()
	else
		reaper.Undo_EndBlock("Insert CC64 toggle at mouse position (failed)", -1)
	end
end

main()


