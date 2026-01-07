-- BC_Send_snapshot_midi_out_msgs.lua
-- Script to learn MIDI CC/note mappings for snapshots and send them when snapshots change
-- Author: Bryan
-- Version: 1.0

local script_name = "BC_Send_snapshot_midi_out_msgs"
local config_file = reaper.GetResourcePath() .. "/Scripts/BRYAN's SCRIPTS/" .. script_name .. "_config.txt"

-- Global variables
local learned_mappings = {}
local learn_mode = false
local current_learning_snapshot = 1
local midi_input_device = nil
local gfx = gfx or {}
local last_midi_time = 0
local learn_debounce_time = 0.5 -- 500ms debounce

-- Initialize GUI
function init_gfx()
    gfx.init(script_name, 400, 300, 0, 100, 100)
    gfx.setfont(1, "Arial", 16)
    gfx.setfont(2, "Arial", 12)
end

-- Load configuration from file
function load_config()
    local file = io.open(config_file, "r")
    if file then
        for line in file:lines() do
            local snapshot, msg_type, channel, value = line:match("(%d+):(%w+):(%d+):(%d+)")
            if snapshot and msg_type and channel and value then
                learned_mappings[tonumber(snapshot)] = {
                    type = msg_type,
                    channel = tonumber(channel),
                    value = tonumber(value)
                }
            end
        end
        file:close()
    end
end

-- Save configuration to file
function save_config()
    local file = io.open(config_file, "w")
    if file then
        for snapshot, mapping in pairs(learned_mappings) do
            file:write(string.format("%d:%s:%d:%d\n", snapshot, mapping.type, mapping.channel, mapping.value))
        end
        file:close()
    end
end

-- Get MIDI input device
function get_midi_input_device()
    local num_inputs = reaper.GetNumMIDIInputs()
    for i = 0, num_inputs - 1 do
        local retval, name = reaper.GetMIDIInputName(i, "")
        if name and name ~= "" then
            return i
        end
    end
    return 0 -- Default to first device
end

-- Start MIDI learn mode
function start_learn_mode()
    learn_mode = true
    current_learning_snapshot = 1
    midi_input_device = get_midi_input_device()
    
    -- Initialize MIDI
    reaper.midi_init(-1, -1)
    
    return true
end

-- Stop MIDI learn mode
function stop_learn_mode()
    learn_mode = false
    -- MIDI devices are managed by REAPER automatically
end

-- Process MIDI input during learn mode
function process_midi_learn()
    if not learn_mode then return end
    
    local current_time = reaper.time_precise()
    
    -- Check all MIDI input devices
    local num_inputs = reaper.GetNumMIDIInputs()
    for i = 0, num_inputs - 1 do
        local retval, msg = reaper.MIDI_GetRecentInputEvent(i)
        if retval then
            -- Debounce: only process if enough time has passed since last MIDI event
            if current_time - last_midi_time < learn_debounce_time then
                return
            end
            last_midi_time = current_time
            
            local msg_num = tonumber(msg) or 0
            local msg_type = msg_num & 0xF0
            local channel = (msg_num & 0x0F) + 1
            local data1 = (msg_num >> 8) & 0x7F
            local data2 = (msg_num >> 16) & 0x7F
            
            if msg_type == 0xB0 then -- CC
                learned_mappings[current_learning_snapshot] = {
                    type = "CC",
                    channel = channel,
                    value = data1
                }
                reaper.ShowMessageBox(string.format("Snapshot %d learned: CC%d on channel %d", 
                    current_learning_snapshot, data1, channel), "MIDI Learned", 0)
                current_learning_snapshot = current_learning_snapshot + 1
            elseif msg_type == 0x90 and data2 > 0 then -- Note On
                learned_mappings[current_learning_snapshot] = {
                    type = "Note",
                    channel = channel,
                    value = data1
                }
                reaper.ShowMessageBox(string.format("Snapshot %d learned: Note %d on channel %d", 
                    current_learning_snapshot, data1, channel), "MIDI Learned", 0)
                current_learning_snapshot = current_learning_snapshot + 1
            end
            
            if current_learning_snapshot > 8 then
                stop_learn_mode()
                save_config()
                reaper.ShowMessageBox("All 8 snapshots learned! Configuration saved.", "Learn Complete", 0)
            end
            break -- Exit loop after processing one MIDI event
        end
    end
end

-- Send MIDI message
function send_midi_message(mapping)
    if not mapping then return end
    
    local msg = 0
    if mapping.type == "CC" then
        msg = 0xB0 | (mapping.channel - 1) | (mapping.value << 8) | (127 << 16)
    elseif mapping.type == "Note" then
        msg = 0x90 | (mapping.channel - 1) | (mapping.value << 8) | (127 << 16)
    end
    
    if msg > 0 then
        reaper.StuffMIDIMessage(0, msg, 0)
    end
end

-- Check snapshot and send MIDI
function check_snapshot_and_send()
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then return end
    
    local track_guid = reaper.GetTrackGUID(track)
    if not track_guid then return end
    
    -- Check each snapshot
    for snapshot = 1, 8 do
        local snapshot_name = string.format("Snapshot_%d", snapshot)
        local retval, snapshot_data = reaper.GetSetTrackState(track, "SNAPSHOT_" .. snapshot, false, "")
        
        if retval and snapshot_data and snapshot_data ~= "" then
            -- Snapshot exists, send corresponding MIDI message
            local mapping = learned_mappings[snapshot]
            if mapping then
                send_midi_message(mapping)
            end
        end
    end
end

-- Draw GUI
function draw_gui()
    gfx.clear = 0x1E1E1E
    
    -- Title
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1)
    gfx.x, gfx.y = 20, 20
    gfx.drawstr(script_name)
    
    -- Status
    gfx.setfont(2)
    gfx.x, gfx.y = 20, 50
    
    if learn_mode then
        gfx.set(1, 1, 0, 1) -- Yellow
        gfx.drawstr(string.format("Learning Snapshot %d - Press MIDI controller", current_learning_snapshot))
    else
        gfx.set(0, 1, 0, 1) -- Green
        gfx.drawstr("Ready - Monitoring snapshots")
    end
    
    -- Learned mappings display
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 20, 80
    gfx.drawstr("Learned Mappings:")
    
    gfx.y = gfx.y + 20
    for i = 1, 8 do
        gfx.x = 20  -- Reset X position for each line
        local mapping = learned_mappings[i]
        if mapping then
            gfx.drawstr(string.format("Snapshot %d: %s %d (Ch %d)", 
                i, mapping.type, mapping.value, mapping.channel))
        else
            gfx.set(0.5, 0.5, 0.5, 1) -- Gray
            gfx.drawstr(string.format("Snapshot %d: Not learned", i))
            gfx.set(1, 1, 1, 1) -- Reset to white
        end
        gfx.y = gfx.y + 15
    end
    
    -- Buttons
    gfx.x, gfx.y = 20, 250
    if not learn_mode then
        gfx.set(0, 0.5, 1, 1) -- Blue
        gfx.rect(gfx.x, gfx.y, 100, 30)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = gfx.x + 35, gfx.y + 8
        gfx.drawstr("Learn")
    else
        gfx.set(1, 0, 0, 1) -- Red
        gfx.rect(gfx.x, gfx.y, 100, 30)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = gfx.x + 25, gfx.y + 8
        gfx.drawstr("Cancel")
    end
    
    -- Close button
    gfx.x, gfx.y = 140, 250
    gfx.set(0.5, 0.5, 0.5, 1) -- Gray
    gfx.rect(gfx.x, gfx.y, 100, 30)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = gfx.x + 35, gfx.y + 8
    gfx.drawstr("Close")
end

-- Handle mouse clicks
function handle_mouse()
    local mouse_x, mouse_y = gfx.mouse_x, gfx.mouse_y
    
    if gfx.mouse_cap & 1 == 1 then -- Left mouse button
        -- Learn/Cancel button
        if mouse_x >= 20 and mouse_x <= 120 and mouse_y >= 250 and mouse_y <= 280 then
            if not learn_mode then
                start_learn_mode()
            else
                stop_learn_mode()
            end
        end
        
        -- Close button
        if mouse_x >= 140 and mouse_x <= 240 and mouse_y >= 250 and mouse_y <= 280 then
            stop_learn_mode()
            gfx.quit()
            return false
        end
    end
    
    return true
end

-- Main loop
function main()
    if learn_mode then
        process_midi_learn()
    else
        check_snapshot_and_send()
    end
    
    draw_gui()
    
    if not handle_mouse() then
        return
    end
    
    gfx.update()
    
    if gfx.getchar() >= 0 then
        reaper.defer(main)
    else
        stop_learn_mode()
        gfx.quit()
    end
end

-- Initialize and start
function init()
    load_config()
    init_gfx()
    
    -- Check if we have learned mappings
    local has_mappings = false
    for i = 1, 8 do
        if learned_mappings[i] then
            has_mappings = true
            break
        end
    end
    
    if not has_mappings then
        reaper.ShowMessageBox("No MIDI mappings found. Click 'Learn' to start learning MIDI CC/Note assignments for snapshots.", "First Run", 0)
    end
    
    main()
end

-- Start the script
init()
