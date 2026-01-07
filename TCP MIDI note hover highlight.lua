-- TCP MIDI note hover highlight (ImGui overlay)
-- Draws a rectangle over the MIDI note under the mouse in arrange/TCP
-- Requirements: SWS/S&M (BR_*), js_ReaScriptAPI, ReaImGui

local function have_exts()
	return reaper and reaper.BR_PositionAtMouseCursor and reaper.BR_TrackAtMouseCursor
		and reaper.JS_Window_FindChildByID and reaper.JS_Window_GetClientRect and reaper.JS_Window_ClientToScreen
		and reaper.ImGui_CreateContext
end

if not have_exts() then
	reaper.MB("This script requires SWS, js_ReaScriptAPI, and ReaImGui.", "Missing dependency", 0)
	return
end

-- Mouse + context helpers
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

local function estimate_pitch_from_mouse_on_item(item, take, arrange_y_client)
	local item_y = reaper.GetMediaItemInfo_Value(item, "I_LASTY")
	local item_h = reaper.GetMediaItemInfo_Value(item, "I_LASTH")
	if not item_y or not item_h or item_h <= 0 then return nil end

	local mx, my = reaper.GetMousePosition()
	local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
	local _cx, my_client = reaper.JS_Window_ScreenToClient(arrange, mx, my)

	local rel = (my_client - item_y) / item_h
	if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end

	local min_p, max_p = compute_min_max_pitch(take)
	if min_p and max_p then
		if min_p == max_p then return min_p end
		local pitchf = max_p - rel * (max_p - min_p)
		return math.floor(pitchf + 0.5)
	end
	return nil
end

local function select_note_time_then_pitch(take, mouse_ppq, target_pitch)
	local spanning = collect_spanning_notes(take, mouse_ppq)
	if #spanning == 0 then return nil end

	local min_abs = nil
	for _, n in ipairs(spanning) do
		local d = math.abs(mouse_ppq - n.startppq)
		if not min_abs or d < min_abs then min_abs = d end
	end
	local candidates = {}
	for _, n in ipairs(spanning) do
		if math.abs(mouse_ppq - n.startppq) == min_abs then candidates[#candidates+1] = n end
	end
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
		for _, n in ipairs(candidates) do
			if (not chosen) or (n.startppq > chosen.startppq) then chosen = n end
		end
	end
	return chosen
end

-- ImGui setup
local ctx = reaper.ImGui_CreateContext('TCP Note Hover Highlight')
-- Build flags defensively: some flags may not exist in older ReaImGui builds
local flags = 0
flags = flags | (reaper.ImGui_WindowFlags_NoDecoration and reaper.ImGui_WindowFlags_NoDecoration() or 0)
flags = flags | (reaper.ImGui_WindowFlags_NoInputs and reaper.ImGui_WindowFlags_NoInputs() or 0)
flags = flags | (reaper.ImGui_WindowFlags_NoNav and reaper.ImGui_WindowFlags_NoNav() or 0)
flags = flags | (reaper.ImGui_WindowFlags_NoBackground and reaper.ImGui_WindowFlags_NoBackground() or 0)
flags = flags | (reaper.ImGui_WindowFlags_NoBringToFrontOnFocus and reaper.ImGui_WindowFlags_NoBringToFrontOnFocus() or 0)

local function get_arrange_rect_screen()
	local arrange = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
	if not arrange then return nil end
	local ok, l, t, r, b = reaper.JS_Window_GetClientRect(arrange)
	if not ok then return nil end
	local sx, sy = reaper.JS_Window_ClientToScreen(arrange, 0, 0)
	return sx, sy, sx + (r - l), sy + (b - t)
end

local color = 0xFF00FFFF -- ARGB: opaque cyan
local thickness = 2.0

local function loop()
	if reaper.ImGui_ValidatePtr(ctx, 'ImGui_Context*') == false then return end

	local ax1, ay1, ax2, ay2 = get_arrange_rect_screen()
	if not ax1 then
		reaper.defer(loop)
		return
	end

	local w = ax2 - ax1
	local h = ay2 - ay1
	local viewport = reaper.ImGui_GetMainViewport(ctx)
	reaper.ImGui_SetNextWindowPos(ctx, ax1, ay1)
	reaper.ImGui_SetNextWindowSize(ctx, w, h)
	local visible, _ = reaper.ImGui_Begin(ctx, 'overlay', true, flags)
	if visible then
		local track, mouse_time = get_mouse_context()
		if track and mouse_time then
			local item, take, item_pos, item_len = find_midi_item_take_at_time(track, mouse_time)
			if take then
				local mouse_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, mouse_time)
				local target_pitch = estimate_pitch_from_mouse_on_item(item, take)
				local chosen = select_note_time_then_pitch(take, mouse_ppq, target_pitch)
				if chosen then
					local note_start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, chosen.startppq)
					local note_end_time = reaper.MIDI_GetProjTimeFromPPQPos(take, chosen.endppq)
					local view_start, view_end = reaper.GetSet_ArrangeView2(0, false, 0, 0)
					if view_start and view_end and view_end > view_start then
						local px_per_sec = (ax2 - ax1) / (view_end - view_start)
						local x1 = ax1 + (note_start_time - view_start) * px_per_sec
						local x2 = ax1 + (note_end_time - view_start) * px_per_sec
						-- Vertical mapping within item by pitch range
						local item_y = reaper.GetMediaItemInfo_Value(item, 'I_LASTY')
						local item_h = reaper.GetMediaItemInfo_Value(item, 'I_LASTH')
						local min_p, max_p = compute_min_max_pitch(take)
						local y1, y2
						if min_p and max_p and max_p >= min_p and item_h > 0 then
							local rows = (max_p - min_p + 1)
							local row_h = math.max(3, item_h / rows)
							local rel_top = (max_p - chosen.pitch) / (max_p - min_p + 1e-9)
							y1 = ay1 + item_y + rel_top * item_h
							y2 = y1 + row_h
						else
							y1 = ay1 + item_y
							y2 = y1 + item_h
						end
						local dl = reaper.ImGui_GetWindowDrawList(ctx)
						reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, color, 0.0, 0, thickness)
					end
				end
			end
		end
	end
	reaper.ImGui_End(ctx)

	if reaper.ValidatePtr2(0, ctx, 'ImGui_Context*') then
		reaper.defer(loop)
	end
end

reaper.defer(loop)


