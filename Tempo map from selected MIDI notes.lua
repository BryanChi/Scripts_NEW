-- @description Tempo map from selected MIDI notes
-- @version 1.1
-- @author BRYAN
-- @about Creates tempo markers at selected note positions, mapping each note to beat 1 of each measure
-- @provides [main] Tempo map from selected MIDI notes.lua

local r = reaper

-- Check if MIDI editor is active
local function check_midi_editor()
    local editor = r.MIDIEditor_GetActive()
    if not editor then
        r.MB("Please open the MIDI editor first.", "MIDI Editor Required", 0)
        return nil, nil
    end
    
    local take = r.MIDIEditor_GetTake(editor)
    if not take or not r.TakeIsMIDI(take) then
        r.MB("No MIDI take found in the active MIDI editor.", "MIDI Take Required", 0)
        return nil, nil
    end
    
    return editor, take
end

-- Get all selected notes from the MIDI take
local function get_selected_notes(take)
    local selected_notes = {}
    local _, note_count, _, _ = r.MIDI_CountEvts(take)
    
    -- Get the MIDI item to get its position
    local item = r.GetMediaItemTake_Item(take)
    if not item then
        r.ShowConsoleMsg("ERROR: Could not get MIDI item from take\n")
        return selected_notes
    end
    
    local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    
    -- Use MIDI_GetProjTimeFromPPQPos but verify it's working
    -- If it returns incorrect values, we'll calculate manually
    for i = 0, note_count - 1 do
        local retval, selected, muted, startppq, endppq, chan, pitch, vel = r.MIDI_GetNote(take, i)
        if retval and selected then
            -- Try using MIDI_GetProjTimeFromPPQPos first
            local proj_time_api = r.MIDI_GetProjTimeFromPPQPos(take, startppq)
            
            -- Also calculate manually as backup
            -- Get PPQ resolution (default 960)
            local ppq_per_beat = 960
            local current_bpm = r.Master_GetTempo()
            local beats = startppq / ppq_per_beat
            local seconds = beats * 60.0 / current_bpm
            local proj_time_manual = item_pos + seconds
            
            -- Use the API result if it seems reasonable, otherwise use manual
            local proj_time = proj_time_api
            
            -- Check if API result is reasonable (should be close to item_pos + some small offset)
            if proj_time_api < item_pos - 1.0 or proj_time_api > item_pos + 100.0 then
                -- API result seems wrong, use manual calculation
                proj_time = proj_time_manual
                r.ShowConsoleMsg(string.format("Note %d: API time suspicious (%.4f), using manual (%.4f)\n", 
                                              i, proj_time_api, proj_time_manual))
            else
                r.ShowConsoleMsg(string.format("Note %d: PPQ=%.2f, API_Time=%.4f, Manual_Time=%.4f, ItemPos=%.4f\n", 
                                              i, startppq, proj_time_api, proj_time_manual, item_pos))
            end
            
            table.insert(selected_notes, {
                index = i,
                startppq = startppq,
                endppq = endppq,
                proj_time = proj_time,
                pitch = pitch,
                vel = vel
            })
        end
    end
    
    -- Sort by project time
    table.sort(selected_notes, function(a, b) return a.proj_time < b.proj_time end)
    
    return selected_notes
end


local function clear_tempo_markers_in_range(start_time, end_time)
    if start_time == nil or end_time == nil then return 0 end
    if end_time < start_time then
        start_time, end_time = end_time, start_time
    end
    local removed = 0
    local count = r.CountTempoTimeSigMarkers(0)
    for i = count - 1, 0, -1 do
        local ret, time = r.GetTempoTimeSigMarker(0, i)
        if ret and time >= start_time and time <= end_time then
            r.DeleteTempoTimeSigMarker(0, i)
            removed = removed + 1
        end
    end
    return removed
end

local function find_marker_near_time(target_time, tolerance)
    tolerance = tolerance or 0.001
    local count = r.CountTempoTimeSigMarkers(0)
    local best_idx = -1
    local best_diff = nil
    for i = 0, count - 1 do
        local ret, time = r.GetTempoTimeSigMarker(0, i)
        if ret then
            local diff = math.abs(time - target_time)
            if diff <= tolerance and (not best_diff or diff < best_diff) then
                best_diff = diff
                best_idx = i
            elseif not best_diff or diff < best_diff then
                -- keep closest even if outside tolerance
                best_diff = diff
                best_idx = i
            end
        end
    end
    return best_idx, best_diff
end

local function get_closest_measure_start(timepos)
    if r.TimeMap2_timeToBeats then
        local qn, measurepos, beatpos, ts_num, ts_den = r.TimeMap2_timeToBeats(0, timepos)
        if measurepos and beatpos and ts_num and ts_den then
            local beats_per_measure = ts_num * (4.0 / ts_den)
            local closest_measure = measurepos
            if beatpos >= (beats_per_measure / 2.0) then
                closest_measure = measurepos + 1
            end
            return closest_measure, beats_per_measure
        end
    end
    return 0, 4
end

local function get_beats_per_measure(timepos)
    -- Use TimeMap_GetTimeSigAtTime which returns: timesig_num, timesig_denom, tempo
    if r.TimeMap_GetTimeSigAtTime then
        local ts_num, ts_den, tempo = r.TimeMap_GetTimeSigAtTime(0, timepos)
        r.ShowConsoleMsg(string.format("  DEBUG TimeMap_GetTimeSigAtTime(%.3f): num=%s, den=%s, tempo=%s\n", 
                                       timepos, tostring(ts_num), tostring(ts_den), tostring(tempo)))
        if ts_num and ts_den and ts_num > 0 and ts_den > 0 then
            local beats = ts_num * (4.0 / ts_den)
            return beats, math.floor(ts_num), math.floor(ts_den)
        end
    end
    
    -- Fallback: scan tempo markers for time signature info
    r.ShowConsoleMsg("  DEBUG: TimeMap_GetTimeSigAtTime not available or returned invalid, using fallback\n")
    local num, den = 4, 4
    local count = r.CountTempoTimeSigMarkers(0)
    for i = 0, count - 1 do
        local ret, time, _measurepos, _beatpos, _tempo, ts_num, ts_den = r.GetTempoTimeSigMarker(0, i)
        if ret and time <= timepos then
            if ts_num and ts_den and ts_num > 0 and ts_den > 0 then
                num, den = ts_num, ts_den
            end
        end
    end
    
    r.ShowConsoleMsg(string.format("  DEBUG fallback time sig: %d/%d\n", num, den))
    return num * (4.0 / den), num, den
end

-- Main function
local function main()
    -- Check if MIDI editor is active
    local editor, take = check_midi_editor()
    if not editor or not take then
        return
    end
    
    r.ShowConsoleMsg("========================================\n")
    r.ShowConsoleMsg("TEMPO MAP FROM SELECTED MIDI NOTES\n")
    r.ShowConsoleMsg("========================================\n\n")
    
    -- Get selected notes
    local selected_notes = get_selected_notes(take)
    
    if #selected_notes == 0 then
        r.MB("No notes are selected in the MIDI editor.\nPlease select some notes first.", "No Notes Selected", 0)
        return
    end
    
    r.ShowConsoleMsg(string.format("Found %d selected note(s)\n", #selected_notes))
    r.ShowConsoleMsg("Selected notes summary:\n")
    for i, note in ipairs(selected_notes) do
        r.ShowConsoleMsg(string.format("  Note %d: time=%.6f, PPQ=%.2f, pitch=%d\n", 
                                      i, note.proj_time, note.startppq, note.pitch))
    end
    r.ShowConsoleMsg("\n")
    
    -- Check existing tempo markers
    local existing_marker_count = r.CountTempoTimeSigMarkers(0)
    r.ShowConsoleMsg(string.format("Existing tempo markers in project: %d\n", existing_marker_count))
    if existing_marker_count > 0 then
        r.ShowConsoleMsg("Existing tempo markers:\n")
        for i = 0, math.min(existing_marker_count - 1, 10) do  -- Show first 10
        local ret, time, _measurepos, _beatpos, tempo, timesig_num, timesig_denom = r.GetTempoTimeSigMarker(0, i)
            if ret then
                -- Ensure values are numbers, use defaults if nil
                time = time or 0
                tempo = tempo or 0
                timesig_num = timesig_num and math.floor(timesig_num) or 4
                timesig_denom = timesig_denom and math.floor(timesig_denom) or 4
                r.ShowConsoleMsg(string.format("  Marker %d: time=%.6f, bpm=%.2f, timesig=%d/%d\n", 
                                              i, time, tempo, timesig_num, timesig_denom))
            end
        end
        if existing_marker_count > 10 then
            r.ShowConsoleMsg(string.format("  ... and %d more markers\n", existing_marker_count - 10))
        end
    end
    r.ShowConsoleMsg("\n")
    
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    
    -- No timebase checks or manipulation
    
    -- Clear existing tempo markers in the range we are about to map
    local first_note_time = selected_notes[1].proj_time
    local last_note_time = selected_notes[#selected_notes].proj_time
    local clear_start = math.max(0, first_note_time - 1.0)
    local clear_end = last_note_time + 1.0
    local removed = clear_tempo_markers_in_range(clear_start, clear_end)
    r.ShowConsoleMsg(string.format("Cleared %d tempo markers in range %.3f to %.3f\n\n", removed, clear_start, clear_end))

    -- Calculate BPM for each segment based on note spacing
    -- Each note will be mapped to beat 1 of each measure (measure 1, 2, 3, etc.)
    -- BPM is calculated so that the time between notes equals exactly one measure (4 beats)
    -- We need to place tempo markers such that each note falls on beat 1
    local markers_added = 0
    local default_bpm = r.Master_GetTempo()
    local beats_per_measure = 4  -- 4/4 time signature (default)
    
    -- For each note, calculate BPM and place marker
    -- The key is: if we want note at time T to be beat 1, and the tempo is BPM,
    -- then we need to place the tempo marker at time T - (60/BPM) seconds
    -- But actually, tempo markers define the tempo from that point, so if we place
    -- a marker at time T with BPM X, then time T becomes the start of a new tempo section.
    -- To make time T be beat 1, we need to ensure the previous tempo section ends
    -- such that T is beat 1.
    
    -- Simpler approach: Place tempo marker at each note position.
    -- Calculate BPM so that the spacing equals 4 beats.
    -- Then use SetTempoTimeSigMarker to align the marker to beat 1.
    
    -- Calculate BPM per measure based on consecutive note spacing
    r.ShowConsoleMsg("=== BPM CALCULATION ===\n")
    r.ShowConsoleMsg(string.format("Default BPM: %.2f\n", default_bpm))
    r.ShowConsoleMsg(string.format("Beats per measure (default): %d\n", beats_per_measure))

    local per_marker_bpm = {}
    if #selected_notes > 1 then
        for i = 1, #selected_notes - 1 do
            local t1 = selected_notes[i].proj_time
            local t2 = selected_notes[i + 1].proj_time
            local time_diff = t2 - t1
            local bpm_beats, ts_num, ts_den = get_beats_per_measure(t1)
            ts_num = ts_num and math.floor(ts_num) or 4
            ts_den = ts_den and math.floor(ts_den) or 4
            r.ShowConsoleMsg(string.format("Interval %d -> %d: t1=%.6f t2=%.6f diff=%.6f\n", i, i + 1, t1, t2, time_diff))
            r.ShowConsoleMsg(string.format("  Time signature at t1: %d/%d (beats/measure=%.2f)\n", ts_num, ts_den, bpm_beats))
            local bpm = default_bpm
            if time_diff > 0.001 then
                bpm = (60.0 * bpm_beats) / time_diff
                if bpm < 20 then
                    r.ShowConsoleMsg(string.format("  BPM too low (%.2f), clamping to 20\n", bpm))
                    bpm = 20
                elseif bpm > 300 then
                    r.ShowConsoleMsg(string.format("  BPM too high (%.2f), clamping to 300\n", bpm))
                    bpm = 300
                end
            else
                r.ShowConsoleMsg("  WARNING: Time difference too small, using default BPM\n")
            end
            per_marker_bpm[i] = bpm
            r.ShowConsoleMsg(string.format("  BPM for measure %d: %.6f\n", i, bpm))
        end
        per_marker_bpm[#selected_notes] = per_marker_bpm[#selected_notes - 1] or default_bpm
    else
        per_marker_bpm[1] = default_bpm
        r.ShowConsoleMsg("Only one note selected, using default BPM\n")
    end

    r.ShowConsoleMsg("\n")
    
    -- Place tempo markers
    r.ShowConsoleMsg("=== PLACING TEMPO MARKERS ===\n")
    
    -- Strategy: Place first marker at or before first note to establish the tempo
    -- Then place markers at each note position so they become beat 1 of their measures
    
    -- Place first marker at the first note's position (tempo-only)
    local first_note = selected_notes[1]
    local first_marker_time = first_note.proj_time

    -- Get current time signature to preserve it (don't change time signature)
    local _beats_pm, current_ts_num, current_ts_denom = get_beats_per_measure(first_marker_time)
    current_ts_num = current_ts_num and math.floor(current_ts_num) or 4
    current_ts_denom = current_ts_denom and math.floor(current_ts_denom) or 4

    r.ShowConsoleMsg(string.format("Placing marker 1:\n"))
    r.ShowConsoleMsg(string.format("  Target time: %.6f\n", first_marker_time))
    local first_bpm = per_marker_bpm[1] or default_bpm
    r.ShowConsoleMsg(string.format("  BPM: %.6f\n", first_bpm))
    r.ShowConsoleMsg(string.format("  Preserving time signature: %d/%d\n", current_ts_num, current_ts_denom))
    r.ShowConsoleMsg(string.format("  Note time: %.6f\n", first_note.proj_time))

    -- Use 0, 0 for time signature to preserve existing
    local success = r.AddTempoTimeSigMarker(0, first_marker_time, first_bpm, 0, 0, 0)
    if success then
        markers_added = markers_added + 1
        r.ShowConsoleMsg(string.format("  SUCCESS: Marker added\n"))
        
        -- Verify the marker was added correctly
        local marker_idx, marker_diff = find_marker_near_time(first_marker_time, 0.01)
        if marker_idx >= 0 then
            if marker_diff and marker_diff > 0.001 then
                r.ShowConsoleMsg(string.format("  WARNING: Marker snapped (diff=%.6f)\n", marker_diff))
            end
            -- Force exact time (no beat snapping) while preserving time signature
            if r.SetTempoTimeSigMarker then
                r.SetTempoTimeSigMarker(0, marker_idx, first_marker_time, -1, -1, first_bpm, 0, 0, 0)
            end
                local ret, actual_time, _measurepos, _beatpos, actual_bpm, timesig_num, timesig_denom = r.GetTempoTimeSigMarker(0, marker_idx)
                if ret then
                    actual_time = actual_time or 0
                    actual_bpm = actual_bpm or 0
                    timesig_num = timesig_num and math.floor(timesig_num) or 4
                    timesig_denom = timesig_denom and math.floor(timesig_denom) or 4
                    r.ShowConsoleMsg(string.format("  VERIFIED: Marker at index %d, time=%.6f, bpm=%.6f, timesig=%d/%d\n", 
                                              marker_idx, actual_time, actual_bpm, timesig_num, timesig_denom))
                    if actual_bpm and first_bpm and math.abs(actual_bpm - first_bpm) > 0.01 then
                        r.ShowConsoleMsg(string.format("  WARNING: BPM mismatch! Expected %.6f, got %.6f\n", 
                                                  first_bpm, actual_bpm))
                    end
                end
            end
    else
        r.ShowConsoleMsg(string.format("  FAILED: Could not add marker\n"))
    end
    r.ShowConsoleMsg("\n")
    
    -- Place markers for subsequent notes
    for i = 2, #selected_notes do
        local note = selected_notes[i]
        local measure_number = i
        local timepos = note.proj_time
        
        r.ShowConsoleMsg(string.format("Placing marker %d:\n", measure_number))
        local bpm = per_marker_bpm[i] or default_bpm
        r.ShowConsoleMsg(string.format("  Target time: %.6f\n", timepos))
        r.ShowConsoleMsg(string.format("  BPM: %.6f\n", bpm))
        r.ShowConsoleMsg(string.format("  Preserving time signature: %d/%d\n", current_ts_num, current_ts_denom))
        r.ShowConsoleMsg(string.format("  Note time: %.6f\n", timepos))
        
        -- Place marker at the note's position (tempo-only)
        local success = r.AddTempoTimeSigMarker(0, timepos, bpm, 0, 0, 0)
        
        if success then
            markers_added = markers_added + 1
            r.ShowConsoleMsg(string.format("  SUCCESS: Marker added\n"))
            
            -- Verify the marker was added correctly
            local marker_idx, marker_diff = find_marker_near_time(timepos, 0.01)
            if marker_idx >= 0 then
                if marker_diff and marker_diff > 0.001 then
                    r.ShowConsoleMsg(string.format("  WARNING: Marker snapped (diff=%.6f)\n", marker_diff))
                end
                if r.SetTempoTimeSigMarker then
                    -- Force exact time (no beat snapping) while preserving time signature
                    r.SetTempoTimeSigMarker(0, marker_idx, timepos, -1, -1, bpm, 0, 0, 0)
                end
                local ret, actual_time, _measurepos, _beatpos, actual_bpm, timesig_num, timesig_denom = r.GetTempoTimeSigMarker(0, marker_idx)
                if ret then
                    actual_time = actual_time or 0
                    actual_bpm = actual_bpm or 0
                    timesig_num = timesig_num and math.floor(timesig_num) or 4
                    timesig_denom = timesig_denom and math.floor(timesig_denom) or 4
                    r.ShowConsoleMsg(string.format("  VERIFIED: Marker at index %d, time=%.6f, bpm=%.6f, timesig=%d/%d\n", 
                                                  marker_idx, actual_time, actual_bpm, timesig_num, timesig_denom))
                    if actual_bpm and bpm and math.abs(actual_bpm - bpm) > 0.01 then
                        r.ShowConsoleMsg(string.format("  WARNING: BPM mismatch! Expected %.6f, got %.6f\n", 
                                                      bpm, actual_bpm))
                    end
                end
            end
        else
            r.ShowConsoleMsg(string.format("  FAILED: Could not add marker\n"))
        end
        r.ShowConsoleMsg("\n")
    end
    
    -- Final verification: list all tempo markers
    r.ShowConsoleMsg("=== FINAL TEMPO MARKER VERIFICATION ===\n")
    local final_marker_count = r.CountTempoTimeSigMarkers(0)
    r.ShowConsoleMsg(string.format("Total tempo markers in project: %d\n", final_marker_count))
    for i = 0, final_marker_count - 1 do
        local ret, time, _measurepos, _beatpos, tempo, timesig_num, timesig_denom = r.GetTempoTimeSigMarker(0, i)
        if ret then
            time = time or 0
            tempo = tempo or 0
            timesig_num = timesig_num and math.floor(timesig_num) or 4
            timesig_denom = timesig_denom and math.floor(timesig_denom) or 4
            r.ShowConsoleMsg(string.format("  Marker %d: time=%.6f, bpm=%.6f, timesig=%d/%d\n", 
                                          i, time, tempo, timesig_num, timesig_denom))
        end
    end
    r.ShowConsoleMsg("\n")
    
    r.PreventUIRefresh(-1)
    r.UpdateTimeline()
    
    if markers_added > 0 then
        local undo_msg = string.format("Tempo map from selected MIDI notes (%d markers)", markers_added)
        local changes = {}
        if timebase_changed then
            table.insert(changes, "Timebase set to Time")
        end
        if midi_timebase_changed then
            table.insert(changes, "MIDI item timebase enabled")
        end
        if #changes > 0 then
            undo_msg = undo_msg .. " - " .. table.concat(changes, ", ")
        end
        r.Undo_EndBlock(undo_msg, 0)
        r.ShowConsoleMsg(string.format("\nSuccessfully created %d tempo marker(s) from selected notes.\n", markers_added))
    else
        r.Undo_EndBlock("Tempo map from selected MIDI notes (no markers added)", -1)
        r.ShowConsoleMsg("No tempo markers were added.\n")
    end
end

-- Run the script
main()
