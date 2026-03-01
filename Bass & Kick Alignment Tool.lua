--[[
  Bass & Kick Alignment Tool
  - First run: scans track names for "Kick", asks user to confirm kick tracks.
  - Saves confirmed kick tracks per project using ProjExtState (track GUID list).
  - Runtime: draws a transparent, non-interactive waveform overlay in MIDI editor.

  Requirements:
    - ReaImGui
    - SWS (for BR_* mouse context helpers)
    - js_ReaScriptAPI (for MIDI editor window rect)
--]]

local r = reaper

local EXT_SECTION = "BassKickAlignmentTool"
local EXT_KEY_GUIDS = "KickTrackGUIDs"
local SCRIPT_NAME = "Bass & Kick Alignment Tool"
local DEBUG = true
local DEBUG_VERBOSE = false
local DEBUG_WAVE_COORDS = true
local DEBUG_SHOW_OVERLAY_TINT = true
local OS_NAME = (r.GetOS and r.GetOS() or "")
local DEFAULT_HZOOM_SCALE = (OS_NAME:match("OSX") and 0.5 or 1.0)
local FORCE_BEATS_TIMEBASE = false

local dbg_last = {}
local function dbg(msg, key, min_interval)
  if not (DEBUG and DEBUG_VERBOSE) then return end
  local now = r.time_precise()
  local k = key or msg
  local wait = min_interval or 0.0
  local last = dbg_last[k] or -math.huge
  if (now - last) < wait then return end
  dbg_last[k] = now
  r.ShowConsoleMsg(string.format("[BKA %.3f] %s\n", now, tostring(msg)))
end

local function wave_dbg(msg, key, min_interval)
  if not (DEBUG and DEBUG_WAVE_COORDS) then return end
  local now = r.time_precise()
  local k = "wave_" .. (key or msg)
  local wait = min_interval or 0.0
  local last = dbg_last[k] or -math.huge
  if (now - last) < wait then return end
  dbg_last[k] = now
  r.ShowConsoleMsg(string.format("[BKA-WAVE %.3f] %s\n", now, tostring(msg)))
end

if DEBUG then
  r.ClearConsole()
  r.ShowConsoleMsg("[BKA] script loaded\n")
end

local function has_deps()
  return r.ImGui_CreateContext
     and r.BR_GetMouseCursorContext
     and r.BR_GetMouseCursorContext_Position
     and r.JS_Window_GetRect
end

if not has_deps() then
  r.MB("Missing dependency.\nNeed ReaImGui + SWS + js_ReaScriptAPI.", SCRIPT_NAME, 0)
  return
end

local function split(str, sep)
  local out = {}
  if not str or str == "" then return out end
  for token in string.gmatch(str, "([^" .. sep .. "]+)") do
    out[#out + 1] = token
  end
  return out
end

local function flags_or(...)
  local out = 0
  for i = 1, select("#", ...) do
    local fn = select(i, ...)
    if fn then out = out | fn() end
  end
  return out
end

local function get_track_name(track)
  local _, name = r.GetTrackName(track, "")
  return name or ""
end

local function collect_tracks()
  local tracks = {}
  local count = r.CountTracks(0)
  for i = 0, count - 1 do
    local tr = r.GetTrack(0, i)
    tracks[#tracks + 1] = tr
  end
  return tracks
end

local function find_track_by_guid(guid)
  local tracks = collect_tracks()
  for i = 1, #tracks do
    if r.GetTrackGUID(tracks[i]) == guid then
      return tracks[i]
    end
  end
  return nil
end

local function scan_kick_candidates()
  local out = {}
  local tracks = collect_tracks()
  for i = 1, #tracks do
    local name = get_track_name(tracks[i])
    if string.find(string.lower(name), "kick", 1, true) then
      out[#out + 1] = tracks[i]
    end
  end
  return out
end

local function load_saved_guid_list()
  local ok, data = r.GetProjExtState(0, EXT_SECTION, EXT_KEY_GUIDS)
  if ok ~= 1 or not data or data == "" then return {} end
  return split(data, ";")
end

local function save_guid_list(guid_list)
  local packed = table.concat(guid_list, ";")
  r.SetProjExtState(0, EXT_SECTION, EXT_KEY_GUIDS, packed)
end

local ctx = r.ImGui_CreateContext(SCRIPT_NAME)
if not ctx then
  r.MB("Failed to create ImGui context.", SCRIPT_NAME, 0)
  return
end

local function ensure_ctx_alive()
  if not ctx then
    ctx = r.ImGui_CreateContext(SCRIPT_NAME)
    if not ctx then
      dbg("Failed to create ImGui context", "ctx_create_fail", 1.0)
      return false
    end
    dbg("Context created (ctx was nil)", "ctx_create", 1.0)
    return true
  end

  local ok = pcall(r.ImGui_GetFrameCount, ctx)
  if ok then return true end

  dbg("ImGui ctx ping failed; recreating context", "ctx_recreate", 1.0)
  local new_ctx = r.ImGui_CreateContext(SCRIPT_NAME)
  if not new_ctx then
    dbg("ImGui ctx recreation failed", "ctx_recreate_fail", 1.0)
    return false
  end
  ctx = new_ctx
  state.wave_cache.points = nil
  return true
end
local state = {
  setup_done = false,
  kick_selected = {},   -- guid -> bool
  kick_tracks = {},     -- resolved MediaTrack list
  all_tracks = collect_tracks(),
  wave_cache = {
    t = 0.0,
    left_t = nil,
    right_t = nil,
    points = nil
  },
  accessors = {},       -- guid -> accessor
  map_points = {},      -- rolling mouse/time calibration samples
  map_a = nil,          -- project_time = a*x + b
  map_b = nil,
  warned_no_signal = false,
  last_editor = nil,
  last_rect = nil,
  last_t1 = nil,
  last_t2 = nil,
  cfg_left_tick = nil,
  cfg_hzoom = nil,
  cfg_timebase = "beats",
  cal_scale = DEFAULT_HZOOM_SCALE,
  cal_prev = nil,
  cal_offset_x = 0.0
}

local function is_finite(v)
  return type(v) == "number" and v == v and v > -1e30 and v < 1e30
end

local function native_to_imgui(nx, ny)
  if r.ImGui_PointConvertNative and ensure_ctx_alive() then
    local ok, ix, iy = pcall(r.ImGui_PointConvertNative, ctx, nx, ny, true)
    if ok and is_finite(ix) and is_finite(iy) then
      return ix, iy
    end
    dbg("ImGui_PointConvertNative failed, using native coords fallback", "pt_convert_fail", 1.0)
  end
  return nx, ny
end

local function resolve_selected_tracks()
  local tracks = {}
  for guid, is_on in pairs(state.kick_selected) do
    if is_on then
      local tr = find_track_by_guid(guid)
      if tr then tracks[#tracks + 1] = tr end
    end
  end
  state.kick_tracks = tracks
end

local function prime_setup_selection()
  local saved = load_saved_guid_list()
  dbg("prime_setup_selection(): saved count = " .. tostring(#saved), "prime_saved")
  if #saved > 0 then
    for i = 1, #saved do
      state.kick_selected[saved[i]] = true
    end
    resolve_selected_tracks()
    dbg("resolved saved kick tracks = " .. tostring(#state.kick_tracks), "prime_saved_resolved")
    if #state.kick_tracks > 0 then
      state.setup_done = true
      dbg("setup_done=true from saved selection", "prime_saved_ok")
      return
    end
  end

  local cands = scan_kick_candidates()
  dbg("kick name candidates found = " .. tostring(#cands), "prime_cands")
  for i = 1, #cands do
    state.kick_selected[r.GetTrackGUID(cands[i])] = true
  end
end

prime_setup_selection()

local function get_midi_editor_rect()
  local editor = r.MIDIEditor_GetActive() or state.last_editor
  if not editor then
    dbg("No active MIDI editor", "no_midi_editor", 1.0)
    return nil
  end

  -- Follow the MIDI "midiview" child (1001), which is the piano roll viewport.
  local midiview = r.JS_Window_FindChildByID(editor, 1001) or editor
  local ok, cl, ct, cr, cb = r.JS_Window_GetClientRect(midiview)
  if not ok then
    dbg("JS_Window_GetClientRect() failed for MIDI midiview", "midi_rect_fail", 1.0)
    return nil
  end
  local nx1, ny1 = r.JS_Window_ClientToScreen(midiview, 0, 0)
  local nx2, ny2 = nx1 + (cr - cl), ny1 + (cb - ct)
  -- Exclude ruler/header so waveform is in note area only.
  local ruler_h = 62
  ny1 = ny1 + math.min(ruler_h, math.max(0, ny2 - ny1 - 20))

  -- Also capture full midiview native rect for time->x mapping width.
  local full_nx1, full_ny1 = r.JS_Window_ClientToScreen(midiview, 0, 0)
  local full_nx2, full_ny2 = full_nx1 + (cr - cl), full_ny1 + (cb - ct)

  if nx2 < nx1 then nx1, nx2 = nx2, nx1 end
  if ny2 < ny1 then ny1, ny2 = ny2, ny1 end
  local nw = math.max(1, nx2 - nx1)
  local nh = math.max(1, ny2 - ny1)

  -- Convert to ImGui coordinates.
  local gx1, gy1 = native_to_imgui(nx1, ny1)
  local gx2, gy2 = native_to_imgui(nx2, ny2)
  if gx2 < gx1 then gx1, gx2 = gx2, gx1 end
  if gy2 < gy1 then gy1, gy2 = gy2, gy1 end
  local gw = math.max(1, gx2 - gx1)
  local gh = math.max(1, gy2 - gy1)

  dbg(string.format("rect native=(%.1f,%.1f)-(%.1f,%.1f) imgui=(%.1f,%.1f)-(%.1f,%.1f)",
      nx1, ny1, nx2, ny2, gx1, gy1, gx2, gy2), "rect_coords", 1.0)

  local out = {
    editor = editor,
    midiview = midiview,
    -- Note-area native/screen coordinates.
    nx1 = nx1, ny1 = ny1, nx2 = nx2, ny2 = ny2, nw = nw, nh = nh,
    -- Full midiview native/screen coordinates for precise horizontal timeline width.
    full_nx1 = full_nx1, full_nx2 = full_nx2,
    full_nw = math.max(1, full_nx2 - full_nx1),
    -- Note-area ImGui coordinates (for SetNextWindowPos and drawing).
    x1 = gx1, y1 = gy1, x2 = gx2, y2 = gy2, w = gw, h = gh
  }
  state.last_editor = editor
  state.last_rect = out
  return out
end

local function get_take_chunk_for_active_take(take)
  local item = r.GetMediaItemTake_Item(take)
  if not item then return nil end
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then
    return nil
  end
  return chunk
end

local function get_cfg_edit_view(take)
  local chunk = get_take_chunk_for_active_take(take)
  if not chunk then return nil end
  local left_tick_s, hzoom_s = chunk:match("\nCFGEDITVIEW%s+([%-%d%.]+)%s+([%-%d%.]+)")
  local left_tick = tonumber(left_tick_s)
  local hzoom = tonumber(hzoom_s)
  if not left_tick or not hzoom or hzoom <= 0 then return nil end
  -- Parse timebase from known CFGEDIT layout (same approach used in js MIDI scripts).
  local _, tb_s = chunk:match(
    "\nCFGEDIT %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (%S+)"
  )
  local tb = tonumber(tb_s or "")
  local timebase = ((tb == 0) or (tb == 4)) and "beats" or "time"
  if FORCE_BEATS_TIMEBASE then
    timebase = "beats"
  end
  return left_tick, hzoom, timebase
end

local function reset_calibration()
  state.cal_scale = DEFAULT_HZOOM_SCALE
  state.cal_prev = nil
  state.cal_offset_x = 0.0
end

local function collect_calibration_sample(rect, take, left_tick, left_time, hzoom, timebase)
  local mx, my = r.GetMousePosition()
  if mx < rect.nx1 or mx > rect.nx2 or my < rect.ny1 or my > rect.ny2 then
    state.cal_prev = nil
    return nil
  end
  r.BR_GetMouseCursorContext()
  local proj_time = r.BR_GetMouseCursorContext_Position()
  if not proj_time or not is_finite(proj_time) or proj_time < 0 then return nil end
  local u
  if timebase == "beats" then
    local ppq = r.MIDI_GetPPQPosFromProjTime(take, proj_time)
    if not is_finite(ppq) then return nil end
    u = (ppq - left_tick)
  else
    u = (proj_time - left_time)
  end
  if not is_finite(u) then return nil end
  return { x = mx, u = u }
end

local function calibrate_every_frame(sample, hzoom)
  if not sample then return nil, nil end
  local prev = state.cal_prev

  if prev and is_finite(prev.u) and is_finite(prev.x) then
    local du = sample.u - prev.u
    local dx = sample.x - prev.x
    if math.abs(du) > 1e-9 and math.abs(dx) > 0.0 then
      local inst_scale = (dx / du) / hzoom
      if is_finite(inst_scale) and inst_scale >= 0.2 and inst_scale <= 4.0 then
        -- Per-frame calibration: apply immediately.
        state.cal_scale = inst_scale
      end
    end
  end

  state.cal_prev = sample
  return state.cal_scale, sample
end

local function get_editor_timeline(take, rect)
  local left_tick, hzoom, timebase = get_cfg_edit_view(take)
  if not left_tick then
    dbg("CFGEDITVIEW unavailable for active take", "cfgeditview_missing", 1.0)
    return nil
  end

  local left_time = r.MIDI_GetProjTimeFromPPQPos(take, left_tick)
  if not is_finite(left_time) then return nil end

  if state.cfg_timebase and state.cfg_timebase ~= timebase then
    -- Only reset when mapping mode actually changes.
    reset_calibration()
  end
  state.cfg_left_tick = left_tick
  state.cfg_hzoom = hzoom
  state.cfg_timebase = timebase

  local sample = collect_calibration_sample(rect, take, left_tick, left_time, hzoom, timebase)
  local scale, cal_sample = calibrate_every_frame(sample, hzoom)
  if not state.cal_scale then
    state.cal_scale = DEFAULT_HZOOM_SCALE
  end

  local scale_now = state.cal_scale or DEFAULT_HZOOM_SCALE
  -- Deterministic base anchor, then per-frame calibrated offset.
  local anchor_native = rect.full_nx1
  if cal_sample then
    local predicted_x = rect.full_nx1 + cal_sample.u * hzoom * scale_now
    local off = cal_sample.x - predicted_x
    -- Keep calibration offset bounded to viewport width to prevent runaway.
    local max_off = math.max(100, rect.full_nw)
    if off > max_off then off = max_off elseif off < -max_off then off = -max_off end
    state.cal_offset_x = off
  end
  anchor_native = anchor_native + (state.cal_offset_x or 0.0)
  local scale = scale_now

  local imgui_per_native_x = rect.w / math.max(1, rect.nw)
  local function native_to_overlay_x(nx)
    return rect.x1 + (nx - rect.nx1) * imgui_per_native_x
  end
  local function overlay_x_to_native(x)
    return rect.nx1 + (x - rect.x1) / imgui_per_native_x
  end

  local function time_to_native_x(proj_time)
    if timebase == "beats" then
      local ppq = r.MIDI_GetPPQPosFromProjTime(take, proj_time)
      return anchor_native + (ppq - left_tick) * hzoom * scale
    end
    return anchor_native + (proj_time - left_time) * hzoom * scale
  end

  local function native_x_to_time(nx)
    if timebase == "beats" then
      local ppq = left_tick + ((nx - anchor_native) / (hzoom * scale))
      return r.MIDI_GetProjTimeFromPPQPos(take, ppq)
    end
    return left_time + ((nx - anchor_native) / (hzoom * scale))
  end

  local left_t = native_x_to_time(rect.nx1)
  local right_t = native_x_to_time(rect.nx2)
  if right_t < left_t then left_t, right_t = right_t, left_t end
  if not (is_finite(left_t) and is_finite(right_t) and right_t > left_t) then return nil end

  local function time_to_x(proj_time)
    return native_to_overlay_x(time_to_native_x(proj_time))
  end

  wave_dbg(string.format("timeline mode=%s hzoom=%.3f scale=%.4f left_tick=%.1f left_time=%.3f anchor=%.1f off=%.1f has_sample=%s",
      timebase, hzoom, scale, left_tick, left_time, anchor_native, state.cal_offset_x or 0.0, cal_sample and "y" or "n"), "timeline_cfg", 0.12)
  return {
    left_t = left_t,
    right_t = right_t,
    time_to_x = time_to_x,
    x_to_time = function(x) return native_x_to_time(overlay_x_to_native(x)) end
  }
end

local function get_accessor_for_track(track)
  local guid = r.GetTrackGUID(track)
  local cached = state.accessors[guid]
  if cached then return cached end
  local acc = r.CreateTrackAudioAccessor(track)
  if not acc then return nil end
  state.accessors[guid] = acc
  return acc
end

local function get_accessor_bounds(acc)
  local t1, t2 = nil, nil
  if r.GetAudioAccessorStartTime then
    local ok, v = pcall(r.GetAudioAccessorStartTime, acc)
    if ok and is_finite(v) then t1 = v end
  end
  if r.GetAudioAccessorEndTime then
    local ok, v = pcall(r.GetAudioAccessorEndTime, acc)
    if ok and is_finite(v) then t2 = v end
  end
  return t1, t2
end

local function destroy_accessors()
  for _, acc in pairs(state.accessors) do
    if acc then r.DestroyAudioAccessor(acc) end
  end
  state.accessors = {}
end

local function build_wave_points(left_t, right_t, width_px)
  local duration = right_t - left_t
  if duration <= 0 then
    dbg("build_wave_points(): non-positive duration", "wave_bad_dur", 1.0)
    return nil
  end
  if #state.kick_tracks == 0 then
    dbg("build_wave_points(): no kick tracks selected", "wave_no_tracks", 1.0)
    return nil
  end

  -- Use a denser lookup table so waveform follows grid-scale changes tightly.
  local points = math.max(512, math.min(32768, math.floor(width_px)))
  local sample_rate = math.floor(math.max(1000, math.min(192000, points / duration)) + 0.5)
  local channels = 2
  local total = {}
  for i = 1, points do total[i] = 0.0 end

  for i = 1, #state.kick_tracks do
    local tr = state.kick_tracks[i]
    local acc = get_accessor_for_track(tr)
    if acc then
      local astart, aend = get_accessor_bounds(acc)
      local seg_l = left_t
      local seg_r = right_t
      if astart then seg_l = math.max(seg_l, astart) end
      if aend then seg_r = math.min(seg_r, aend) end

      if seg_r > seg_l then
        local i1 = math.max(1, math.floor(((seg_l - left_t) / duration) * (points - 1)) + 1)
        local i2 = math.min(points, math.ceil(((seg_r - left_t) / duration) * (points - 1)) + 1)
        local npts = math.max(1, i2 - i1 + 1)

        local arr = r.new_array(npts * channels)
        local ok = r.GetAudioAccessorSamples(acc, sample_rate, channels, seg_l, npts, arr)
        if ok == 1 then
          local t = arr.table()
          local idx = 1
          for s = 0, npts - 1 do
            local l = math.abs(t[idx] or 0.0); idx = idx + 1
            local rr = math.abs(t[idx] or 0.0); idx = idx + 1
            local out_idx = i1 + s
            if out_idx >= 1 and out_idx <= points then
              total[out_idx] = total[out_idx] + (l + rr) * 0.5
            end
          end
        else
          dbg("GetAudioAccessorSamples() failed on selected track", "audio_accessor_fail", 1.0)
        end
      end
    end
  end

  local peak = 0.0
  for i = 1, points do
    if total[i] > peak then peak = total[i] end
  end
  if peak < 1e-7 then
    dbg("build_wave_points(): peak too low (silence in view)", "wave_silence", 1.0)
    return nil
  end

  dbg(string.format("build_wave_points(): points=%d sr=%d peak=%.5f", points, sample_rate, peak), "wave_ok", 1.0)
  for i = 1, points do
    total[i] = total[i] / peak
  end
  return total
end

local function get_wave_points_cached(left_t, right_t, width_px)
  local c = state.wave_cache
  -- Always refresh every frame to match current MIDI zoom/scroll exactly.
  c.points = build_wave_points(left_t, right_t, width_px)
  c.left_t = left_t
  c.right_t = right_t
  c.t = r.time_precise()
  return c.points
end

local function sample_wave_at_time(wave, left_t, right_t, t)
  if not wave then return 0.0 end
  local n = #wave
  if n <= 0 or right_t <= left_t then return 0.0 end
  local u = (t - left_t) / (right_t - left_t)
  if u <= 0 then return wave[1] or 0.0 end
  if u >= 1 then return wave[n] or 0.0 end
  local p = 1 + u * (n - 1)
  local i1 = math.floor(p)
  local i2 = i1 + 1
  if i2 > n then i2 = n end
  local a = p - i1
  local v1 = wave[i1] or 0.0
  local v2 = wave[i2] or v1
  return v1 + (v2 - v1) * a
end

local setup_flags = flags_or(
  r.ImGui_WindowFlags_AlwaysAutoResize
)

local overlay_flags = flags_or(
  r.ImGui_WindowFlags_NoDecoration,
  r.ImGui_WindowFlags_NoBackground,
  r.ImGui_WindowFlags_NoInputs,
  r.ImGui_WindowFlags_NoNav,
  r.ImGui_WindowFlags_NoSavedSettings,
  r.ImGui_WindowFlags_NoFocusOnAppearing,
  r.ImGui_WindowFlags_TopMost
)

local function draw_setup_window()
  if not ensure_ctx_alive() then return false end
  r.ImGui_SetNextWindowSize(ctx, 430, 420, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, SCRIPT_NAME .. " - Kick Track Setup", true, setup_flags)
  if visible then
    r.ImGui_Text(ctx, "Confirm kick tracks. Selection is saved per project.")
    r.ImGui_Separator(ctx)

    local tracks = collect_tracks()
    for i = 1, #tracks do
      local tr = tracks[i]
      local guid = r.GetTrackGUID(tr)
      local label = string.format("%02d. %s##%s", i, get_track_name(tr), guid)
      local cur = state.kick_selected[guid] == true
      local changed, val = r.ImGui_Checkbox(ctx, label, cur)
      if changed then state.kick_selected[guid] = val end
    end

    r.ImGui_Separator(ctx)
    if r.ImGui_Button(ctx, "Auto-Select Tracks Containing 'Kick'") then
      local cands = scan_kick_candidates()
      for i = 1, #tracks do
        state.kick_selected[r.GetTrackGUID(tracks[i])] = false
      end
      for i = 1, #cands do
        state.kick_selected[r.GetTrackGUID(cands[i])] = true
      end
    end

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Clear") then
      for i = 1, #tracks do
        state.kick_selected[r.GetTrackGUID(tracks[i])] = false
      end
    end

    local selected_guids = {}
    for guid, on in pairs(state.kick_selected) do
      if on then selected_guids[#selected_guids + 1] = guid end
    end

    r.ImGui_Spacing(ctx)
    r.ImGui_Text(ctx, "Selected kick tracks: " .. tostring(#selected_guids))

    local can_confirm = #selected_guids > 0
    if not can_confirm then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, "Confirm and Start Overlay", 220, 0) then
      save_guid_list(selected_guids)
      resolve_selected_tracks()
      state.setup_done = true
      state.wave_cache.points = nil
      dbg("Confirmed kick tracks, overlay starting. count=" .. tostring(#state.kick_tracks), "setup_confirm")
    end
    if not can_confirm then r.ImGui_EndDisabled(ctx) end
  end
  r.ImGui_End(ctx)

  if not open then
    dbg("Setup window closed by user; script will stop defer loop.", "setup_closed")
    r.defer(function() end)
    return false
  end
  return true
end

local function draw_wave_overlay()
  if not ensure_ctx_alive() then return end
  local rect = get_midi_editor_rect()

  if not rect then return end
  local take = r.MIDIEditor_GetTake(rect.editor or r.MIDIEditor_GetActive())
  if not take or not r.TakeIsMIDI(take) then return end
  local timeline = get_editor_timeline(take, rect)
  if not timeline then return end

  r.ImGui_SetNextWindowPos(ctx, rect.x1, rect.y1, r.ImGui_Cond_Always())
  r.ImGui_SetNextWindowSize(ctx, rect.w, rect.h, r.ImGui_Cond_Always())
  r.ImGui_SetNextWindowBgAlpha(ctx, DEBUG_SHOW_OVERLAY_TINT and 0.08 or 0.0)

  local visible = select(1, r.ImGui_Begin(ctx, "##kick_overlay", true, overlay_flags))
  if visible then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    local base_y = rect.y1 + rect.h * 0.5

    if DEBUG then
      -- Debug marker: bright box at overlay top-left.
      r.ImGui_DrawList_AddRectFilled(dl, rect.x1 + 8, rect.y1 + 8, rect.x1 + 24, rect.y1 + 24, 0xFF00FFFF)
    end

    -- Always draw a faint center line so the overlay is visibly present.
    r.ImGui_DrawList_AddLine(dl, rect.x1, base_y, rect.x2, base_y, 0x33FFFFFF, 1.0)

    local left_t, right_t = timeline.left_t, timeline.right_t
    if left_t and right_t then
      local x_l = timeline.time_to_x(left_t)
      local x_r = timeline.time_to_x(right_t)
      wave_dbg(string.format("range t=[%.3f, %.3f] x=[%.1f, %.1f] w=%.1f", left_t, right_t, x_l, x_r, rect.w), "range", 0.4)

      -- Draw beat lines from project tempo map, positioned in MIDI editor coords.
      if r.TimeMap2_timeToBeats and r.TimeMap2_beatsToTime then
        local _, _, _, fb_l = r.TimeMap2_timeToBeats(0, left_t)
        local _, _, _, fb_r = r.TimeMap2_timeToBeats(0, right_t)
        if fb_l and fb_r then
          local beat_start = math.floor(fb_l)
          local beat_end = math.ceil(fb_r)
          for beat = beat_start, beat_end do
            local bt = r.TimeMap2_beatsToTime(0, beat)
            local x = timeline.time_to_x(bt)
            if x >= rect.x1 - 1 and x <= rect.x2 + 1 then
              local major = (beat % 4) == 0
              local clr = major and 0x22FFFFFF or 0x11FFFFFF
              local thick = major and 1.2 or 1.0
              r.ImGui_DrawList_AddLine(dl, x, rect.y1, x, rect.y2, clr, thick)
            end
          end
        end
      end

      -- Build a high-resolution time lookup table, then sample it from x->time.
      -- This makes waveform movement/zoom adhere to the exact grid transform.
      local px_count = math.max(1, math.floor(rect.w))
      local lookup_points = math.max(4096, math.floor(px_count * 8))
      local wave = get_wave_points_cached(left_t, right_t, lookup_points)
      if wave then
        wave_dbg("waveform visible", "visible", 0.8)
        state.warned_no_signal = false
        local amp_h = rect.h * 0.42
        local color_main = 0x66AAFFFF
        local color_outline = 0x88CCFFFF

        local prev_x_u, prev_y_u = nil, nil
        local prev_x_l, prev_y_l = nil, nil
        for i = 0, px_count do
          local x = rect.x1 + i
          local t = timeline.x_to_time(x)
          local norm = sample_wave_at_time(wave, left_t, right_t, t)
          local y_up = base_y - norm * amp_h
          local y_dn = base_y + norm * amp_h

          if prev_x_u then
            r.ImGui_DrawList_AddLine(dl, prev_x_u, prev_y_u, x, y_up, color_outline, 1.4)
            r.ImGui_DrawList_AddLine(dl, prev_x_l, prev_y_l, x, y_dn, color_outline, 1.4)
          end
          -- Light vertical fill to emphasize transients.
          r.ImGui_DrawList_AddLine(dl, x, y_up, x, y_dn, color_main, 1.0)

          prev_x_u, prev_y_u = x, y_up
          prev_x_l, prev_y_l = x, y_dn
        end
      else
        wave_dbg("no waveform available for current view", "missing", 0.8)
        -- Keep non-interactive overlay, but explain why waveform is absent.
        r.ImGui_DrawList_AddText(dl, rect.x1 + 12, rect.y1 + 10, 0x99FFFFFF,
          "No kick waveform in current view (move mouse over piano roll to calibrate time)")
      end
    end
  end
  r.ImGui_End(ctx)
end

local function cleanup()
  destroy_accessors()
  pcall(function()
    r.ImGui_DestroyContext(ctx)
  end)
end

local safe_loop
local function loop()
  dbg("loop heartbeat", "loop_heartbeat", 1.0)
  if not ensure_ctx_alive() then
    dbg("No valid ImGui context; stopping loop", "ctx_dead_stop", 1.0)
    return
  end

  if not state.setup_done then
    dbg("loop branch: setup window", "loop_setup", 1.0)
    if not draw_setup_window() then
      dbg("draw_setup_window returned false -> loop stops", "loop_setup_stop")
      return
    end
  else
    dbg("loop branch: overlay", "loop_overlay", 1.0)
    resolve_selected_tracks()
    if #state.kick_tracks == 0 then
      dbg("No resolved kick tracks -> returning to setup", "loop_no_tracks")
      state.setup_done = false
    else
      draw_wave_overlay()
    end
  end

  dbg("loop deferred", "loop_deferred", 1.0)
  r.defer(safe_loop)
end

safe_loop = function()
  local ok, err = pcall(loop)
  if not ok then
    r.ShowConsoleMsg("[BKA ERROR] " .. tostring(err) .. "\n")
    r.ShowMessageBox("Bass & Kick Alignment Tool crashed:\n\n" .. tostring(err), SCRIPT_NAME, 0)
  end
end

r.atexit(cleanup)
safe_loop()

