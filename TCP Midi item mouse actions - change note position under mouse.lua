-- TCP MIDI note position adjuster by mousewheel
-- Moves the MIDI note that spans the mouse time by ±1 grid step while hovering TCP/arrange
-- Requirements: SWS extension (BR_* API)

local function require_sws()
	if reaper and reaper.BR_PositionAtMouseCursor and reaper.BR_TrackAtMouseCursor then
		return true
	end
	reaper.MB("This script requires the SWS/S&M extension.\nPlease install SWS and try again.", "Missing dependency", 0)
	return false
end

local function get_mouse_context()
	-- Returns track under mouse and project time at mouse (no snapping)
	local track = nil
	if reaper.BR_TrackAtMouseCursor then
		track = select(1, reaper.BR_TrackAtMouseCursor())
	end
	local pos = nil
	if reaper.BR_PositionAtMouseCursor then
		pos = reaper.BR_PositionAtMouseCursor(false)
	end
	return track, pos
end

local function get_wheel_direction()
	-- Determine wheel direction via action context; positive = up/forward, negative = down/back
	local _, _, _, _, _, _, val = reaper.get_action_context()
	if type(val) == "number" and val ~= 0 then
		return (val > 0) and 1 or -1
	end
	-- Fallback if context provides no value
	return 1
end

local function find_midi_item_take_at_time(track, proj_time)
	if not track then return nil, nil, nil end
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
	return nil, nil, nil
end

local function find_note_spanning_ppq(take, mouse_ppq)
	-- Return index and start/end ppq of the note that spans mouse_ppq.
	-- If multiple, choose the one with the latest start (max start <= mouse_ppq).
	local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
	local best_idx = nil
	local best_start = nil
	local best_end = nil
	for i = 0, note_count - 1 do
		local ok, _, _, startppq, endppq, _, _, _ = reaper.MIDI_GetNote(take, i)
		if ok then
			if startppq <= mouse_ppq and mouse_ppq < endppq then
				if (not best_start) or (startppq > best_start) then
					best_idx = i
					best_start = startppq
					best_end = endppq
				end
			end
		end
	end
	return best_idx, best_start, best_end
end

local function find_note_spanning_ppq_with_pitch(take, mouse_ppq, target_pitch)
	-- Try to find a spanning note matching target_pitch first; if not found, fallback to any note spanning
	local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
	local best_idx = nil
	local best_start = nil
	local best_end = nil

	-- First pass: exact pitch match
	if target_pitch ~= nil then
		for i = 0, note_count - 1 do
			local ok, _, _, startppq, endppq, _, pitch, _ = reaper.MIDI_GetNote(take, i)
			if ok and pitch == target_pitch then
				if startppq <= mouse_ppq and mouse_ppq < endppq then
					if (not best_start) or (startppq > best_start) then
						best_idx = i
						best_start = startppq
						best_end = endppq
					end
				end
			end
		end
		if best_idx ~= nil then
			return best_idx, best_start, best_end
		end
	end

	-- Second pass: nearest pitch among spanning notes
	if target_pitch ~= nil then
		local nearest_idx, nearest_start, nearest_end, nearest_diff = nil, nil, nil, nil
		for i = 0, note_count - 1 do
			local ok, _, _, startppq, endppq, _, pitch, _ = reaper.MIDI_GetNote(take, i)
			if ok and startppq <= mouse_ppq and mouse_ppq < endppq then
				local diff = math.abs(pitch - target_pitch)
				if (nearest_diff == nil) or (diff < nearest_diff) or (diff == nearest_diff and startppq > (nearest_start or -math.huge)) then
					nearest_idx, nearest_start, nearest_end, nearest_diff = i, startppq, endppq, diff
				end
			end
		end
		if nearest_idx ~= nil then
			return nearest_idx, nearest_start, nearest_end
		end
	end

	-- Fallback: any spanning note
	return find_note_spanning_ppq(take, mouse_ppq)
end

local function collect_spanning_notes(take, mouse_ppq)
	local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
	local notes = {}
	for i = 0, note_count - 1 do
		local ok, _, _, startppq, endppq, _, pitch, _ = reaper.MIDI_GetNote(take, i)
		if ok and startppq <= mouse_ppq and mouse_ppq < endppq then
			notes[#notes+1] = { idx = i, startppq = startppq, endppq = endppq, pitch = pitch }
		end
	end
	return notes
end

local function select_note_time_then_pitch(take, mouse_ppq, target_pitch)
	-- Emulates the strategy from the referenced script: choose spanning note whose start is
	-- closest to mouse_ppq; break ties by pitch proximity to target_pitch; final tie by latest start
	local spanning = collect_spanning_notes(take, mouse_ppq)
	if #spanning == 0 then return nil end

	-- Find minimum absolute distance to start
	local min_abs = nil
	for _, n in ipairs(spanning) do
		local d = math.abs(mouse_ppq - n.startppq)
		if not min_abs or d < min_abs then
			min_abs = d
		end
	end

	-- Collect candidates with minimal distance
	local candidates = {}
	for _, n in ipairs(spanning) do
		local d = math.abs(mouse_ppq - n.startppq)
		if d == min_abs then
			candidates[#candidates+1] = n
		end
	end

	-- If we have a target pitch, pick the candidate nearest to it
	local chosen = nil
	if target_pitch ~= nil and #candidates > 1 then
		local best_diff = nil
		for _, n in ipairs(candidates) do
			local diff = math.abs(n.pitch - target_pitch)
			if not best_diff or diff < best_diff or (diff == best_diff and n.startppq > (chosen and chosen.startppq or -math.huge)) then
				best_diff = diff
				chosen = n
			end
		end
	else
		-- Otherwise choose the one with the latest start among candidates
		for _, n in ipairs(candidates) do
			if (not chosen) or (n.startppq > chosen.startppq) then
				chosen = n
			end
		end
	end

	if DEBUG then
		dbg(string.format("Selection: %d spanning, min_abs=%.1f, target_pitch=%s", #spanning, min_abs or -1, tostring(target_pitch)))
		if chosen then
			dbg(string.format("Chosen idx=%d pitch=%d start=%d end=%d", chosen.idx, chosen.pitch, chosen.startppq, chosen.endppq))
		end
	end

	return chosen and chosen.idx, chosen and chosen.startppq, chosen and chosen.endppq
end

local function get_mouse_midi_context()
	-- Returns take and pitch row under mouse if hovering inline ME/ME; nils otherwise
	if not (reaper.BR_GetMouseCursorContext and reaper.BR_GetMouseCursorContext_MIDI) then return nil, nil end
	local _w, _s, _d = reaper.BR_GetMouseCursorContext()
	local mtake, _item, note_row, _cc_lane, _cc_val, _text = reaper.BR_GetMouseCursorContext_MIDI()
	if mtake and type(note_row) == "number" then
		return mtake, note_row
	end
	return nil, nil
end

local function get_item_pos_len_from_take(take)
	if not take then return nil, nil end
	local item = reaper.GetMediaItemTake_Item(take)
	if not item then return nil, nil end
	local it_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
	local it_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
	return it_pos, it_len
end

local function get_item_under_mouse()
	local mx, my = reaper.GetMousePosition()
	local item = reaper.GetItemFromPoint(mx, my, true)
	return item, mx, my
end

local function is_take_inline_editor(take)
	if not take then return false end
	if reaper.BR_IsMidiOpenInInlineEditor then
		return reaper.BR_IsMidiOpenInInlineEditor(take) or false
	end
	return false
end

local function compute_min_max_pitch(take)
	local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
	local min_p, max_p = nil, nil
	for i = 0, note_count - 1 do
		local ok, _, _, _s, _e, _sel, pitch, _vel = reaper.MIDI_GetNote(take, i)
		if ok then
			if not min_p or pitch < min_p then min_p = pitch end
			if not max_p or pitch > max_p then max_p = pitch end
		end
	end
	return min_p, max_p
end

local function js_get_arrange_client_xy(screen_x, screen_y)
	if not (reaper.JS_Window_FindChildByID and reaper.JS_Window_ScreenToClient and reaper.GetMainHwnd) then
		return nil, nil
	end
	local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
	if arrange then
		local cx, cy = reaper.JS_Window_ScreenToClient(arrange, screen_x, screen_y)
		return cx, cy
	end
	return nil, nil
end

local function js_get_arrange_origin_screen()
    if not (reaper.JS_Window_FindChildByID and reaper.JS_Window_ClientToScreen and reaper.GetMainHwnd) then
        return nil, nil
    end
    local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
    if arrange then
        local ox, oy = reaper.JS_Window_ClientToScreen(arrange, 0, 0)
        return ox, oy
    end
    return nil, nil
end

local function estimate_pitch_from_mouse_on_item(item, take)
	-- Map mouse Y inside item rect to pitch between min and max note in take
	-- Requires JS API to convert screen to arrange-client coordinates.
	if not item or not take then return nil end
	if not (reaper.JS_Window_FindChildByID and reaper.JS_Window_ScreenToClient and reaper.GetMainHwnd) then return nil end

	local item_y = reaper.GetMediaItemInfo_Value(item, "I_LASTY")
	local item_h = reaper.GetMediaItemInfo_Value(item, "I_LASTH")
	if not item_y or not item_h or item_h <= 0 then return nil end

	local _item_under_mouse, mx, my_screen = get_item_under_mouse()
	local _cx, my_client = js_get_arrange_client_xy(mx, my_screen)
	if not my_client then return nil end

    -- I_LASTY is already in arrange client coordinates; use directly
    local rel = (my_client - item_y) / item_h
    if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end

    -- Prefer mapping within the actual note pitch range present in the take
    local min_p, max_p = compute_min_max_pitch(take)
    if min_p and max_p then
		if min_p == max_p then return min_p end
        -- Y grows downward; top -> max_p, bottom -> min_p
        local pitchf = max_p - rel * (max_p - min_p)
		local pitch = math.floor(pitchf + 0.5)
		if pitch < 0 then pitch = 0 elseif pitch > 127 then pitch = 127 end
		return pitch
    end

    -- Fallback: map full item height to MIDI pitch 127..0 (top to bottom)
    local pitchf = 127 - (rel * 127)
	local pitch = math.floor(pitchf + 0.5)
	if pitch < 0 then pitch = 0 elseif pitch > 127 then pitch = 127 end
	return pitch
end

local function move_note_by_one_pixel(take, note_idx, startppq, endppq, dir, item_pos, item_len)
	-- Move the note horizontally by exactly one screen pixel at current zoom
	local hzoom = reaper.GetHZoomLevel()
	if not hzoom or hzoom <= 0 then return false end
	local seconds_per_pixel = 1.0 / hzoom
	local start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
	local new_start_time = start_time + (dir * seconds_per_pixel)
	local new_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, new_start_time)
	local delta_ppq = new_start_ppq - startppq
	local new_end_ppq = endppq + delta_ppq

	-- Clamp to item boundaries in project time
	local item_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos)
	local item_end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos + item_len)

	local note_len_ppq = endppq - startppq
	if new_start_ppq < item_start_ppq then
		new_start_ppq = item_start_ppq
		new_end_ppq = new_start_ppq + note_len_ppq
	elseif new_end_ppq > item_end_ppq then
		new_end_ppq = item_end_ppq
		new_start_ppq = new_end_ppq - note_len_ppq
	end

	-- Apply edit
	reaper.MIDI_DisableSort(take)
	local ok = reaper.MIDI_SetNote(take, note_idx, nil, nil, new_start_ppq, new_end_ppq, nil, nil, nil, true)
	reaper.MIDI_Sort(take)
	return ok
end

local function move_selected_notes_by_one_pixel(take, dir, item_pos, item_len)
	-- Move all selected notes by exactly one screen pixel at current zoom
	local hzoom = reaper.GetHZoomLevel()
	if not hzoom or hzoom <= 0 then return false end
	local seconds_delta = (1.0 / hzoom) * dir

	local item_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos)
	local item_end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, item_pos + item_len)

	local _, note_count, _, _ = reaper.MIDI_CountEvts(take)
	local moved = 0
	reaper.MIDI_DisableSort(take)
	for i = 0, note_count - 1 do
		local ok, selected, _, startppq, endppq, _, _, _ = reaper.MIDI_GetNote(take, i)
		if ok and selected then
			local start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
			local new_start_time = start_time + seconds_delta
			local new_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, new_start_time)
			local note_len_ppq = endppq - startppq
			local new_end_ppq = new_start_ppq + note_len_ppq

			if new_start_ppq < item_start_ppq then
				new_start_ppq = item_start_ppq
				new_end_ppq = new_start_ppq + note_len_ppq
			elseif new_end_ppq > item_end_ppq then
				new_end_ppq = item_end_ppq
				new_start_ppq = new_end_ppq - note_len_ppq
			end

			if reaper.MIDI_SetNote(take, i, nil, nil, new_start_ppq, new_end_ppq, nil, nil, nil, true) then
				moved = moved + 1
			end
		end
	end
	reaper.MIDI_Sort(take)
	return moved > 0
end

local function main()
	if not require_sws() then return end
	local track, mouse_time = get_mouse_context()
	if not track or not mouse_time then return end

	-- Prefer the exact take and pitch under the mouse if SWS provides it (inline/ME)
	local mtake, note_row = get_mouse_midi_context()
	local window, segment, details = nil, nil, nil
	if reaper.BR_GetMouseCursorContext then
		window, segment, details = reaper.BR_GetMouseCursorContext()
	end


	local item, take, item_pos, item_len
	if mtake and reaper.TakeIsMIDI(mtake) then
		take = mtake
		item_pos, item_len = get_item_pos_len_from_take(take)
		if not item_pos then return end
	else
		item, take, item_pos, item_len = find_midi_item_take_at_time(track, mouse_time)
		if not take then return end
	end

	local is_inline = is_take_inline_editor(take)


	local dir = get_wheel_direction()

	-- If inline editor for this take and there are selected notes, ignore mouse position and move selected notes
	if is_inline then
		local has_sel = false
		local _, ncnt = reaper.MIDI_CountEvts(take)
		local sel_count = 0
		for i = 0, ncnt - 1 do
			local _ok, sel = reaper.MIDI_GetNote(take, i)
			if _ok and sel then sel_count = sel_count + 1 has_sel = true end
		end
		if has_sel then
			reaper.Undo_BeginBlock()
			reaper.PreventUIRefresh(1)
			local ok = move_selected_notes_by_one_pixel(take, dir, item_pos, item_len)
			reaper.PreventUIRefresh(-1)
			reaper.Undo_EndBlock(ok and "Nudge selected MIDI notes by one pixel" or "Nudge selected MIDI notes by one pixel (failed)", -1)
			if ok then reaper.UpdateArrange() end
			return
		end
	end

	-- Otherwise compute mouse-based target and nudge a single note
	local mouse_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, mouse_time)
	local target_pitch = note_row
	if not target_pitch then
		local item_for_take = reaper.GetMediaItemTake_Item(take)
		local item_under_mouse = select(1, get_item_under_mouse())
		if item_under_mouse and item_for_take and item_under_mouse == item_for_take then
			target_pitch = estimate_pitch_from_mouse_on_item(item_under_mouse, take)
		end
	end
	local note_idx, startppq, endppq = select_note_time_then_pitch(take, mouse_ppq, target_pitch)
	if not note_idx then return end


	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	local ok = move_note_by_one_pixel(take, note_idx, startppq, endppq, dir, item_pos, item_len)
	reaper.PreventUIRefresh(-1)
	reaper.Undo_EndBlock(ok and "Nudge MIDI note by one pixel" or "Nudge MIDI note by one pixel (failed)", -1)
	if ok then reaper.UpdateArrange() end

end

main()


