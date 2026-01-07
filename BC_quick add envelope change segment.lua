-- BC_quick add envelope change segment
-- Requirements: SWS/S&M (for BR_* mouse context helpers) and ReaImGui (v0.9+)
-- Behavior:
--  - When invoked via shortcut and mouse is over an envelope lane, begins an invisible ImGui loop
--  - Creates an automation item at mouse position; horizontal mouse moves set content length
--  - Vertical mouse moves set target envelope value
--  - Inserts 4 points inside the automation item: start/end and two inner points near them
--  - Mouse wheel adjusts the inner points' offsets (gradualness)

local function require_dependencies()
    if not (reaper and reaper.ImGui_CreateContext and reaper.BR_GetMouseCursorContext) then
        reaper.MB("This script requires both SWS/S&M and ReaImGui extensions.", "Missing dependency", 0)
        return false
    end
    return true
end

local function get_mouse_envelope()
    -- Prefer native API if available to avoid interference from overlay window
    if reaper.GetEnvelopeFromPoint then
        local x, y = reaper.GetMousePosition()
        local env = reaper.GetEnvelopeFromPoint(x, y)
        if env then return env end
    end
    -- Fallback to SWS context query
    reaper.BR_GetMouseCursorContext()
    local env = reaper.BR_GetMouseCursorContext_Envelope()
    return env
end

local function get_mouse_time()
    return reaper.BR_PositionAtMouseCursor(false)
end

-- value mapping helpers
local function get_env_scaling_mode(env)
    local _, mode = reaper.GetEnvelopeScalingMode(env)
    return mode or 0
end

local function get_env_value_at_time(env, time)
    local ok, value, dVdS, ddVdS, dddVdS = reaper.Envelope_Evaluate(env, time, 0, 0)
    return value or 0.0
end

local function to_internal_env_value(env, display_value)
    local mode = select(2, reaper.GetEnvelopeScalingMode(env)) or 0
    return reaper.ScaleToEnvelopeMode(mode, display_value)
end

local function insert_or_reuse_ai(env, start_time, init_len)
    local pool_id = -1 -- new pooled source
    local ai_idx = reaper.InsertAutomationItem(env, pool_id, start_time, math.max(0.02, init_len))
    return ai_idx
end

local function set_ai_length(env, ai_idx, length)
    reaper.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH", math.max(0.01, length), true)
end

local function set_ai_start(env, ai_idx, start_time)
    reaper.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION", start_time, true)
end

local function set_ai_content_stretch(env, ai_idx, start_offs, playrate)
    if start_offs then reaper.GetSetAutomationItemInfo(env, ai_idx, "D_STARTOFFS", math.max(0.0, start_offs), true) end
    if playrate then reaper.GetSetAutomationItemInfo(env, ai_idx, "D_PLAYRATE", math.max(0.01, playrate), true) end
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function compute_huge_source_len_seconds(start_time)
	-- 100 measures in seconds at the current time signature around start_time
	-- Use TimeMap2_* variants with explicit project argument for compatibility
	local proj = 0 -- current project
	local ok_ts = reaper.TimeMap2_timeToBeats and true or false
	if not ok_ts then
		return 60.0 -- conservative fallback: 60 seconds
	end
	local _qn_at_time, _qn_meas_start, _t_meas_start, ts_num, ts_den = reaper.TimeMap2_timeToBeats(proj, start_time)
	if not (ts_num and ts_den and ts_num > 0 and ts_den > 0) then
		return 60.0
	end
	local qn_per_measure = ts_num * (4.0 / ts_den)
	local start_qn = reaper.TimeMap2_timeToQN and reaper.TimeMap2_timeToQN(proj, start_time) or reaper.TimeMap_timeToQN(start_time)
	if not start_qn then return 60.0 end
	local end_qn = start_qn + (qn_per_measure * 100.0)
	local end_time = reaper.TimeMap2_QNToTime and reaper.TimeMap2_QNToTime(proj, end_qn) or reaper.TimeMap_QNToTime(end_qn)
	if not end_time then return 60.0 end
	return math.max(0.5, end_time - start_time)
end

local function insert_four_points_in_ai(env, ai_idx, length, base_val, target_val, inner_ratio)
    -- inner points defined as percentage of AI length for consistent behavior
    local tiny = math.max(0.001, math.min(0.02, length * 0.05))
    local ratio = clamp(inner_ratio or 0.1, 0.01, 0.49)
    local inner = ratio * length
    -- use automation item's project-time position for point times
    local ai_pos = reaper.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION", 0, false) or 0.0
    local ai_end = ai_pos + length

    local t1, t2, t3, t4
    if length <= tiny * 4 then
        t1 = ai_pos+ 1
        t2 = math.min(ai_end, ai_pos + tiny)
        t3 = math.max(ai_pos, ai_end - tiny)
        t4 = ai_end -1
    else
        t1 = ai_pos -- exactly at AI beginning (project time)
        t2 = math.min(ai_end, ai_pos + math.max(tiny, inner))
        t3 = math.max(ai_pos, ai_end - math.max(tiny, inner))
        t4 = ai_end -- exactly at AI end (project time)
        if t3 <= t2 then
            local mid = length * 0.5
            t2 = math.max(ai_pos, ai_pos + mid - tiny)
            t3 = math.min(ai_end, ai_pos + mid + tiny)
        end
    end

    reaper.DeleteEnvelopePointRangeEx(env, ai_idx, ai_pos - 0.1, ai_end + 0.1)
    reaper.InsertEnvelopePointEx(env, ai_idx, t1, base_val, 0, 0, false, true)
    reaper.InsertEnvelopePointEx(env, ai_idx, t2, target_val, 0, 0, false, true)
    reaper.InsertEnvelopePointEx(env, ai_idx, t3, target_val, 0, 0, false, true)
    reaper.InsertEnvelopePointEx(env, ai_idx, t4, base_val, 0, 0, false, true)
    reaper.Envelope_SortPointsEx(env, ai_idx)
end

local function main()
    if not require_dependencies() then return end

    local ctx = reaper.ImGui_CreateContext('BC_quick_env_change_seg', reaper.ImGui_ConfigFlags_NoSavedSettings())
    local visible = true
    local font = reaper.ImGui_CreateFont('sans-serif', 10)
    reaper.ImGui_Attach(ctx, font)

	local started = false
    local env = nil
    local start_time = nil
    local start_mouse_x, start_mouse_y = nil, nil
    local ai_idx = nil
    local init_len = 1000
    local base_value = nil
    local target_value = nil
    local inner_ratio = 0.1 -- percentage of item length (0.01..0.49)
    local activation_vkey = nil

    local function get_activation_vkey()
        if not reaper.JS_VKeys_GetState then return nil end
        local buf = reaper.JS_VKeys_GetState(0)
        if not buf then return nil end
        -- find first non-modifier key currently down
        for code = 1, 255 do
            local byte = buf:byte(code + 1)
            if byte and byte ~= 0 then
                if code ~= 16 and code ~= 17 and code ~= 18 then -- ignore Shift, Ctrl, Alt
                    return code
                end
            end
        end
        return nil
    end

    local function is_vkey_down(code)
        if not (code and reaper.JS_VKeys_GetState) then return true end
        local buf = reaper.JS_VKeys_GetState(0)
        if not buf then return true end
        local byte = buf:byte(code + 1)
        return byte and byte ~= 0
    end

    local function loop()
        if not visible then return end
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 0)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
        reaper.ImGui_SetNextWindowBgAlpha(ctx, 0.0)
        local dw, dh = 4000, 4000
        if reaper.ImGui_GetDisplaySize then
            dw, dh = reaper.ImGui_GetDisplaySize(ctx)
        end
        if reaper.ImGui_SetNextWindowPos then reaper.ImGui_SetNextWindowPos(ctx, 0, 0) end
        if reaper.ImGui_SetNextWindowSize then reaper.ImGui_SetNextWindowSize(ctx, dw, dh) end
        reaper.ImGui_Begin(ctx, 'BC_quick_env_change_seg_invisible', true,
            reaper.ImGui_WindowFlags_NoTitleBar()|
            reaper.ImGui_WindowFlags_NoResize()|
            reaper.ImGui_WindowFlags_NoMove()|
            reaper.ImGui_WindowFlags_NoScrollbar()|
            reaper.ImGui_WindowFlags_NoBackground())

        local mx, my = reaper.GetMousePosition()
        reaper.BR_GetMouseCursorContext()
        local mouse_time = get_mouse_time()

        if not started then
            env = get_mouse_envelope()
            if not env then
                -- Wait until mouse is over an envelope lane
                reaper.ImGui_End(ctx)
                reaper.ImGui_PopStyleVar(ctx, 2)
                reaper.defer(loop)
                return
            end
			start_time = mouse_time
            start_mouse_x, start_mouse_y = mx, my
            base_value = get_env_value_at_time(env, start_time)
            target_value = base_value

            reaper.Undo_BeginBlock()
            ai_idx = insert_or_reuse_ai(env, start_time, init_len)
            -- Configure AI so it does not loop; keep playrate=1 and define content by inserted points
            reaper.GetSetAutomationItemInfo(env, ai_idx, "D_PLAYRATE", 1.0, true)
            reaper.GetSetAutomationItemInfo(env, ai_idx, "D_STARTOFFS", 0.0, true)
            reaper.GetSetAutomationItemInfo(env, ai_idx, "D_LOOPSRC", 0.0, true)
            -- initial points use internal envelope units
            local base_internal = to_internal_env_value(env, base_value)
            local target_internal = to_internal_env_value(env, target_value)
            insert_four_points_in_ai(env, ai_idx, init_len, base_internal, target_internal, inner_ratio)
            started = true
            activation_vkey = get_activation_vkey()
        else
            -- Update length from horizontal delta (pixels -> seconds via Arrange view pixels/second if available)
            local delta_px_x = mx - start_mouse_x
            local delta_px_y = my - start_mouse_y

            -- Freeze horizontal length changes while left mouse button is held
            local left_down = false

            left_down = reaper.ImGui_IsMouseDown(ctx, 0)

            local length = reaper.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH", 0, false) or 0.02
            if not left_down then
                -- Map horizontal pixels to seconds using zoom level to avoid context interference
                local px_per_sec = reaper.GetHZoomLevel and reaper.GetHZoomLevel() or 100.0
                if px_per_sec < 1e-6 then px_per_sec = 100.0 end
                length = math.max(0.02, math.abs((mx - start_mouse_x) / px_per_sec))
                set_ai_length(env, ai_idx, length)

            end
            -- keep content matching container length with playrate 1.0
            reaper.GetSetAutomationItemInfo(env, ai_idx, "D_PLAYRATE", 1.0, true)

            -- Update points and values
			-- Map vertical pixels to value delta with reasonable ranges by envelope type
			local _, env_name = reaper.GetEnvelopeName(env, "")
			local lower, upper = 0.0, 1.0
			local lname = (env_name or ""):lower()
			if lname:find("pan") or lname:find("width") then
				lower, upper = -1.0, 1.0
			elseif lname:find("volume") then
				lower, upper = 0.0, 4.0
			end
            local range = upper - lower
            local delta_value = delta_px_y * (range / 150.0) -- reverse sign so up = increase
			target_value = clamp(base_value + delta_value, lower, upper)

            -- Update points to match current container length (convert to internal envelope value)
            local base_internal = to_internal_env_value(env, base_value)
            local target_internal = to_internal_env_value(env, target_value)
            insert_four_points_in_ai(env, ai_idx, length, base_internal, target_internal, inner_ratio)
            reaper.Envelope_SortPointsEx(env, ai_idx)

            -- Mouse wheel adjusts inner_offset
            local wheel = reaper.ImGui_GetMouseWheel(ctx)
            if wheel ~= 0 then
                inner_ratio = clamp(inner_ratio + wheel * 0.02, 0.01, 0.49)
                local base_internal = to_internal_env_value(env, base_value)
                local target_internal = to_internal_env_value(env, target_value)
                insert_four_points_in_ai(env, ai_idx, length, base_internal, target_internal, inner_ratio)
                reaper.Envelope_SortPointsEx(env, ai_idx)
            end
        end

        reaper.ImGui_End(ctx)
        reaper.ImGui_PopStyleVar(ctx, 2)

        -- Finalize when: activation key released, ESC pressed, or right mouse button down
        local key_up = (activation_vkey ~= nil and not is_vkey_down(activation_vkey))
        local esc_down = false
        if reaper.ImGui_IsKeyPressed and reaper.ImGui_Key_Escape then
            esc_down = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) or esc_down
        end
        if reaper.JS_VKeys_GetState then
            local buf = reaper.JS_VKeys_GetState(0)
            if buf then esc_down = ((buf:byte(27 + 1) or 0) ~= 0) or esc_down end -- VK_ESCAPE = 27
        end
        local ms = reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(0) or 0
        local right_down = (ms & 2) ~= 0
        if key_up or esc_down or right_down then
            reaper.Undo_EndBlock("BC_quick add envelope change segment", -1)
            reaper.UpdateArrange()
            visible = false
            if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
            return
        end

            reaper.UpdateArrange()

        reaper.defer(loop)
    end

    loop()
end

main()


