-- @description Quantize note under mouse 50% to closest grid
-- @version 1.0
-- @author AI Assistant
-- @about
--   Quantizes the MIDI note under the mouse cursor by 50% towards the closest grid line.
--   Uses detection logic from "TCP Midi item mouse actions - change note position under mouse.lua".

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
	-- Choose spanning note whose start is closest to mouse_ppq; 
	-- break ties by pitch proximity to target_pitch; final tie by latest start
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

local function get_item_under_mouse()
	local mx, my = reaper.GetMousePosition()
	local item = reaper.GetItemFromPoint(mx, my, true)
	return item, mx, my
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

local function quantize_note_50_percent(take, note_idx, startppq, endppq)
    local start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
    local closest_grid = reaper.SnapToGrid(0, start_time)
    
    local diff = closest_grid - start_time
    -- 50% quantize
    local new_start_time = start_time + (diff * 0.5)
    
    local new_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, new_start_time)
    local len_ppq = endppq - startppq
    local new_end_ppq = new_start_ppq + len_ppq
    
    reaper.MIDI_DisableSort(take)
    -- idx, selected, muted, startppq, endppq, chan, pitch, vel, noSort
    reaper.MIDI_SetNote(take, note_idx, nil, nil, new_start_ppq, new_end_ppq, nil, nil, nil, true)
    reaper.MIDI_Sort(take)
    return true
end

local function main()
	if not require_sws() then return end
	local track, mouse_time = get_mouse_context()
	if not track or not mouse_time then return end

	-- Check for context from SWS (Inline Editor / MIDI Editor)
	local mtake, note_row = get_mouse_midi_context()
	
	local item, take
	if mtake and reaper.TakeIsMIDI(mtake) then
		take = mtake
		item = reaper.GetMediaItemTake_Item(take)
	else
		item, take = find_midi_item_take_at_time(track, mouse_time)
	end
    
	if not take then return end

	-- Determine target pitch (if not provided by SWS context, try to estimate from item position)
	local target_pitch = note_row
	if not target_pitch then
		local item_under_mouse = select(1, get_item_under_mouse())
		if item_under_mouse and item and item_under_mouse == item then
			target_pitch = estimate_pitch_from_mouse_on_item(item_under_mouse, take)
		end
	end

	local mouse_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, mouse_time)
	local note_idx, startppq, endppq = select_note_time_then_pitch(take, mouse_ppq, target_pitch)
	
	if not note_idx then return end

	reaper.Undo_BeginBlock()
	reaper.PreventUIRefresh(1)
	local ok = quantize_note_50_percent(take, note_idx, startppq, endppq)
	reaper.PreventUIRefresh(-1)
	
	reaper.Undo_EndBlock(ok and "Quantize note under mouse 50%" or "Quantize note failed", -1)
	if ok then reaper.UpdateArrange() end
end

main()

