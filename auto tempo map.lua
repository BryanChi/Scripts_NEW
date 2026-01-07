-- Script Name: AI Tempo Mapper
-- Author: Gemini (modified by User)
-- Version: 1.0
-- Website: 
-- Description: Creates a tempo map based on MIDI messages in the selected track using a placeholder AI analysis.
--              The user needs to implement the actual AI logic in the 'placeholder_ai_tempo_analysis' function.

-- @description AI Tempo Map from Selected Track MIDI
-- @version 1.0
-- @author Gemini/User
-- @provides [main] .

-------------------------------------------------------------------------------
-- Helper function to check for required Reaper API functions
-------------------------------------------------------------------------------
function check_functions()
    local required_funcs = {
        "CountSelectedTracks", "GetSelectedTrack", "CountTrackMediaItems", "GetTrackMediaItem",
        "GetActiveTake", "TakeIsMIDI", 
        "MIDI_CountEvts", "MIDI_GetEvt", -- Changed from MIDI_EnumEvents
        "MIDI_GetProjTimeFromPPQPos",
        "AddTempoTimeSigMarker", "Undo_BeginBlock", "Undo_EndBlock", "ShowConsoleMsg", "UpdateTimeline",
        "GetMediaItemInfo_Value" -- Added for getting item position
    }
    local all_found = true
    local missing_message = ""
    for _, func_name in ipairs(required_funcs) do
        if reaper[func_name] == nil then
            missing_message = missing_message .. "Error: Required Reaper API function not found: reaper." .. func_name .. "\n"
            all_found = false
        end
    end
    if not all_found then
      reaper.ShowMessageBox(missing_message .. "Script cannot run due to missing Reaper API functions.\nPlease update Reaper or check API availability.", "Missing API Functions", 0)
    end
    return all_found
end

-------------------------------------------------------------------------------
-- Placeholder AI Analysis Function - TO BE REPLACED WITH LOCAL MODEL INTEGRATION
-------------------------------------------------------------------------------
function placeholder_ai_tempo_analysis(note_on_times_sorted)
  reaper.ShowConsoleMsg("--------------------\n")
  reaper.ShowConsoleMsg("AI Integration: Starting local model tempo analysis...\n")

  if #note_on_times_sorted == 0 then
    reaper.ShowConsoleMsg("AI Integration: No note times received. Returning default 120 BPM at time 0.\n")
    reaper.ShowConsoleMsg("--------------------\n")
    return { {time = 0.0, bpm = 120.0, num = 4, den = 4} }
  end

  -- 1. Define paths for temporary files and your AI script
  -- It's good practice to put temp files in Reaper's resource path or a dedicated script temp folder.
  local resource_path = reaper.GetResourcePath()
  if resource_path == "" then -- Should not happen if Reaper is running
      reaper.ShowConsoleMsg("AI Error: Could not get Reaper resource path!\n")
      return { {time = note_on_times_sorted[1], bpm = 120.0, num = 4, den = 4} } -- fallback
  end
  
  -- Ensure paths use directory separators consistent with the OS
  -- Reaper's Lua on Windows might handle forward slashes okay, but being explicit is safer.
  local sep = package.config:sub(1,1) -- Gets the directory separator ('/' or '\')
  local temp_dir = resource_path .. sep .. "Scripts" .. sep .. "AITempoMapTemp"
  
  -- Create the temporary directory if it doesn't exist
  -- For simplicity, this example assumes reaper.ExecProcess can create dirs, or they exist.
  -- A more robust script would use os.execute to create temp_dir if it doesn't exist.
  -- For now, let's just define file paths. You might need to create 'AITempoMapTemp' manually inside your Reaper/Scripts folder.
  local temp_input_file_path = temp_dir .. sep .. "input_midi_times.txt"
  local temp_output_file_path = temp_dir .. sep .. "output_tempo_map.txt"

  -- !!! --- USER ACTION REQUIRED: Configure your AI model details below --- !!!
  local ai_model_command = "python3"  -- Or "python", or full path to your python interpreter, or your model executable
  -- Example: local ai_model_script_path = resource_path .. sep .. "Scripts" .. sep .. "MyAIModels" .. sep .. "tempo_analyzer.py"
  local ai_model_script_path = "/path/to/your/tempo_analyzer_model.py" -- <<< SET THIS TO THE ACTUAL PATH of your AI script/executable
  -- !!! --- END USER ACTION REQUIRED --- !!!

  -- 2. Write note_on_times_sorted to the temporary input file
  reaper.ShowConsoleMsg("AI Integration: Writing note times to: " .. temp_input_file_path .. "\n")
  local file_in = io.open(temp_input_file_path, "w")
  if not file_in then
    reaper.ShowConsoleMsg("AI Error: Could not open temp input file for writing: " .. temp_input_file_path .. "\n")
    reaper.ShowConsoleMsg("  (Make sure the directory exists or the script has permissions to create it.)\n")
    return { {time = note_on_times_sorted[1], bpm = 120.0, num = 4, den = 4} } -- fallback
  end
  for _, time_val in ipairs(note_on_times_sorted) do
    file_in:write(string.format("%.6f\n", time_val)) -- Each timestamp on a new line
  end
  file_in:close()

  -- 3. Construct the command to execute your local model
  -- Assuming your model takes --input and --output arguments
  -- Quote paths to handle spaces. string.format with %q is good for this.
  local command_to_run = string.format("%s %q --input %q --output %q", 
                                     ai_model_command, 
                                     ai_model_script_path, 
                                     temp_input_file_path, 
                                     temp_output_file_path)
  
  reaper.ShowConsoleMsg("AI Integration: Executing command: " .. command_to_run .. "\n")

  -- 4. Execute the local model using reaper.ExecProcess
  -- This function blocks until the process completes or timeout is reached.
  -- The first return value is the standard output of the command.
  local model_stdout = reaper.ExecProcess(command_to_run, 30000) -- 30-second timeout, adjust as needed
  reaper.ShowConsoleMsg("AI Integration: Local model stdout:\n" .. (model_stdout or "(no stdout)") .. "\n")

  -- 5. Read and parse the tempo map from the temporary output file
  local tempo_map_from_ai = {}
  reaper.ShowConsoleMsg("AI Integration: Reading tempo map from: " .. temp_output_file_path .. "\n")
  local file_out = io.open(temp_output_file_path, "r")
  if not file_out then
    reaper.ShowConsoleMsg("AI Error: Could not open temp output file for reading: " .. temp_output_file_path .. "\n")
    reaper.ShowConsoleMsg("  (Did the AI model successfully create this file? Check model stdout/stderr above.)\n")
    -- Fallback to a simple marker if AI output fails
    table.insert(tempo_map_from_ai, {time = note_on_times_sorted[1], bpm = 115.0, num = 4, den = 4}) 
    reaper.ShowConsoleMsg("--------------------\n")
    return tempo_map_from_ai
  end

  -- Example parsing: assuming "time,bpm,numerator,denominator" CSV format
  -- Modify this parsing logic if your AI model outputs a different format (e.g., JSON)
  for line in file_out:lines() do
    reaper.ShowConsoleMsg("AI Integration: Parsing line from model: " .. line .. "\n")
    -- Example CSV match: time,bpm (num and den are optional)
    local time_str, bpm_str, num_str, den_str = line:match("([^,]+),([^,]+)(?:,([^,]+))?(?:,([^,]+))?")
    
    if time_str and bpm_str then
      local t = tonumber(time_str)
      local b = tonumber(bpm_str)
      local n = tonumber(num_str) or 4 -- Default to 4 if not present
      local d = tonumber(den_str) or 4 -- Default to 4 if not present
      
      if t ~= nil and b ~= nil then
        table.insert(tempo_map_from_ai, {time = t, bpm = b, num = n, den = d})
        reaper.ShowConsoleMsg(string.format("  Successfully parsed AI marker: time=%.4f, bpm=%.2f, ts=%d/%d\n", t, b, n, d))
      else
        reaper.ShowConsoleMsg("AI Warning: Could not parse numbers from line (t or b is nil): " .. line .. "\n")
      end
    else
      reaper.ShowConsoleMsg("AI Warning: Could not parse expected format from line: " .. line .. "\n")
    end
  end
  file_out:close()

  -- 6. Clean up temporary files (optional, but recommended)
  local removed_in = os.remove(temp_input_file_path)
  local removed_out = os.remove(temp_output_file_path)
  if not removed_in then reaper.ShowConsoleMsg("AI Warning: Could not remove temp input file: " .. temp_input_file_path .. "\n") end
  if not removed_out then reaper.ShowConsoleMsg("AI Warning: Could not remove temp output file: " .. temp_output_file_path .. "\n") end

  if #tempo_map_from_ai == 0 then
    reaper.ShowConsoleMsg("AI Warning: No tempo markers were parsed from the AI model output.\n")
    reaper.ShowConsoleMsg("  (Returning a single default marker instead.)\n")
    table.insert(tempo_map_from_ai, {time = note_on_times_sorted[1], bpm = 110.0, num = 4, den = 4})
  end
  
  reaper.ShowConsoleMsg("AI Integration: Tempo analysis complete. Returning " .. #tempo_map_from_ai .. " marker(s).\n")
  reaper.ShowConsoleMsg("--------------------\n")
  return tempo_map_from_ai
end

-------------------------------------------------------------------------------
-- Main Script Logic
-------------------------------------------------------------------------------
function main()
  reaper.ClearConsole()
  reaper.ShowConsoleMsg("Starting AI Tempo Map script...\n")

  local selected_tracks_count = reaper.CountSelectedTracks(0)
  if selected_tracks_count == 0 then
    reaper.ShowMessageBox("Please select a track containing MIDI items.", "AI Tempo Map", 0)
    return
  end
  if selected_tracks_count > 1 then
    reaper.ShowMessageBox("Please select only one track.", "AI Tempo Map", 0)
    return
  end

  reaper.Undo_BeginBlock()

  local track = reaper.GetSelectedTrack(0, 0)
  local note_on_events = {} -- Store {time = project_time, pitch = pitch, velocity = velocity}

  local num_items = reaper.CountTrackMediaItems(track)
  reaper.ShowConsoleMsg("Found " .. num_items .. " media item(s) on the selected track.\n")

  for i = 0, num_items - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    if not item then goto continue_item_loop end

    local take = reaper.GetActiveTake(item)

    if take and reaper.TakeIsMIDI(take) then
      reaper.ShowConsoleMsg(string.format("Processing MIDI take in item %d...\n", i + 1))
      local notes_in_item = 0
      
      local total_events, note_count, cc_count, sysex_count = reaper.MIDI_CountEvts(take)
      reaper.ShowConsoleMsg(string.format("Item %d: MIDI_CountEvts reports: total_events=%s, notes=%s, ccs=%s, sysex=%s\n", 
                                          i + 1, tostring(total_events), tostring(note_count), tostring(cc_count), tostring(sysex_count)))

      if total_events and total_events > 0 then
        for current_event_index = 0, total_events - 1 do
          local retval, selected, muted, ppq_pos, msg_str, api_msg_len = reaper.MIDI_GetEvt(take, current_event_index)
          
          local actual_msg_len = 0
          if msg_str and type(msg_str) == "string" then
            actual_msg_len = string.len(msg_str)
          end

          if retval then
            if current_event_index < 10 then -- Log details for the first 10 events for inspection
              local raw_msg_bytes_str = ""
              if msg_str and actual_msg_len > 0 then
                for k=1, actual_msg_len do raw_msg_bytes_str = raw_msg_bytes_str .. string.format("%02X ", string.byte(msg_str, k)) end
              end
              reaper.ShowConsoleMsg(string.format("  Evt %d: ret=%s, ppq=%.2f, api_len=%s, str_len=%d, raw_msg=[%s], str_msg=\"%s\"\n", 
                                                current_event_index, tostring(retval), ppq_pos or -1, 
                                                tostring(api_msg_len), actual_msg_len, raw_msg_bytes_str, msg_str or "nil"))
            end

            if msg_str and actual_msg_len >= 3 then -- Use actual_msg_len now
              local status = string.byte(msg_str, 1)
              local data1  = string.byte(msg_str, 2)
              local data2  = string.byte(msg_str, 3)

              -- Note On is 0x9n (144-159 decimal). data2 is velocity.
              if (status >= 0x90 and status <= 0x9F) and data2 > 0 then
                local proj_time_qN = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_pos)
                local pitch = data1 -- data1 is the note number
                table.insert(note_on_events, {time = proj_time_qN, pitch = pitch, velocity = data2})
                notes_in_item = notes_in_item + 1
                if notes_in_item < 5 then -- Log first few found notes
                    reaper.ShowConsoleMsg(string.format("    ----> Found Note On: time=%.4f, pitch=%d, vel=%d\n", proj_time_qN, pitch, data2))
                end
              end
            end
          else
            if current_event_index < 10 then -- Log if GetEvt failed for early events
                 reaper.ShowConsoleMsg(string.format("  Evt %d: MIDI_GetEvt failed (retval is false or nil).\n", current_event_index))
            end
          end
        end
      end
      reaper.ShowConsoleMsg(string.format("Found %d note-on events in item %d.\n", notes_in_item, i + 1))
    else
      reaper.ShowConsoleMsg(string.format("Item %d is not MIDI or has no active take. Skipping.\n", i + 1))
    end
    ::continue_item_loop::
  end

  if #note_on_events == 0 then
    reaper.ShowConsoleMsg("No MIDI note-on events found in the selected track's items.\n")
    reaper.Undo_EndBlock("AI Tempo Map (no MIDI notes found)", -1) -- -1 cancels undo block
    reaper.ShowMessageBox("No MIDI note-on events found in the selected track's items.", "AI Tempo Map",0)
    return
  end

  -- Sort events by time
  table.sort(note_on_events, function(a,b) return a.time < b.time end)

  local note_on_times = {}
  for _, event in ipairs(note_on_events) do
    table.insert(note_on_times, event.time)
  end

  reaper.ShowConsoleMsg("Extracted " .. #note_on_times .. " total note-on event times for AI analysis.\n")

  -- Call the placeholder AI function
  local tempo_map_from_ai = placeholder_ai_tempo_analysis(note_on_times)

  if not tempo_map_from_ai or #tempo_map_from_ai == 0 then
    reaper.ShowConsoleMsg("AI placeholder did not return a tempo map or returned an empty map.\n")
    reaper.Undo_EndBlock("AI Tempo Map (AI error or empty map)", -1)
    reaper.ShowMessageBox("AI analysis (placeholder) did not return a usable tempo map.", "AI Tempo Map",0)
    return
  end

  reaper.ShowConsoleMsg("Applying " .. #tempo_map_from_ai .. " tempo marker(s) from AI...\n")
  
  -- Sort AI markers by time before applying, just in case.
  table.sort(tempo_map_from_ai, function(a,b) return a.time < b.time end)

  -- Note: This script adds new tempo markers. It does not automatically remove or modify existing ones.
  -- You might want to manually clear existing tempo markers in the relevant range before running this script,
  -- or extend this script to do so.

  local markers_added = 0
  for i, marker_info in ipairs(tempo_map_from_ai) do
    local timepos = marker_info.time
    local bpm = marker_info.bpm
    local num = marker_info.num or 4 -- Default to 4/4 time signature numerator
    local den = marker_info.den or 4 -- Default to 4/4 time signature denominator
    local linear_tempo_change_val = 0 -- 0 for stepped tempo changes, 1 for gradual
    local unknown_bool_param = false -- Adding a 6th boolean parameter, defaulting to false

    if timepos == nil or bpm == nil then
        reaper.ShowConsoleMsg(string.format("Skipping invalid AI marker %d: missing time or bpm.\n", i))
    else
        -- Lua API for some versions might expect 6 arguments:
        -- reaper.AddTempoTimeSigMarker(timepos, bpm, timesig_num, timesig_denom, linearTempoValue, someOtherBoolean)
        local success = reaper.AddTempoTimeSigMarker(timepos, bpm, num, den, linear_tempo_change_val, unknown_bool_param)
        if success then
            reaper.ShowConsoleMsg(string.format("Added tempo marker: time=%.4f, bpm=%.2f, ts=%d/%d, linear=%d, extra_bool=%s\n", 
                                                timepos, bpm, num, den, linear_tempo_change_val, tostring(unknown_bool_param)))
            markers_added = markers_added + 1
        else
            reaper.ShowConsoleMsg(string.format("Failed to add tempo marker at time=%.4f\n", timepos))
        end
    end
  end

  if markers_added > 0 then
    reaper.UpdateTimeline() -- Refresh the timeline to show new markers
    reaper.ShowConsoleMsg(markers_added .. " tempo marker(s) applied successfully.\n")
    reaper.Undo_EndBlock("AI Tempo Map Applied (" .. markers_added .. " markers)", 0) -- 0 for normal undo
  else
    reaper.ShowConsoleMsg("No tempo markers were actually added.\n")
    reaper.Undo_EndBlock("AI Tempo Map (no markers added)", -1)
  end
  
  reaper.ShowConsoleMsg("AI Tempo Map script finished.\n")
end

-------------------------------------------------------------------------------
-- Script Entry Point
-------------------------------------------------------------------------------
if not check_functions() then
    -- Message already shown by check_functions if there's an issue
    reaper.ShowConsoleMsg("Script aborted due to missing API functions.\n")
else
    -- Using reaper.defer to ensure the script runs in the main thread if launched from a different context
    -- For a simple action script this might not be strictly necessary but is good practice.
    reaper.defer(main) 
end
