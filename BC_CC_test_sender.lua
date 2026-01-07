-- BC_CC_test_sender.lua
-- Test script to send CC 1-127 with values 0-127 every second
-- Author: Bryan
-- Version: 1.0

local script_name = "BC_CC_test_sender"
local running = false
local start_time = 0
local duration = 1.0 -- 1 second duration for full sweep

-- Initialize GUI
function init_gfx()
    gfx.init(script_name, 300, 150, 0, 100, 100)
    gfx.setfont(1, "Arial", 16)
    gfx.setfont(2, "Arial", 12)
end

-- Send MIDI CC message
function send_cc(cc_num, value, channel)
    channel = channel or 1 -- Default to channel 1
    -- Mode 1 sends to first MIDI output device
    reaper.StuffMIDIMessage(1, 0xB0 | (channel - 1), cc_num, value)
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
    
    if running then
        gfx.set(0, 1, 0, 1) -- Green
        local elapsed = reaper.time_precise() - start_time
        local progress = math.min(elapsed / duration, 1.0)
        local current_value = math.floor(progress * 127)
        gfx.drawstr(string.format("Running - All CCs 1-127 sweeping 0 to %d", current_value))
    else
        gfx.set(1, 1, 0, 1) -- Yellow
        gfx.drawstr("Stopped - Click Start to begin")
    end
    
    -- Current status
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 20, 70
    if running then
        local elapsed = reaper.time_precise() - start_time
        local progress = math.min(elapsed / duration, 1.0)
        gfx.drawstr(string.format("Progress: %.1f%% (%.2fs/%.2fs)", progress * 100, elapsed, duration))
    else
        gfx.drawstr("Ready to sweep all CCs 1-127 from 0 to 127")
    end
    
    -- Buttons
    gfx.x, gfx.y = 20, 100
    if not running then
        gfx.set(0, 0.5, 1, 1) -- Blue
        gfx.rect(gfx.x, gfx.y, 80, 30)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = gfx.x + 25, gfx.y + 8
        gfx.drawstr("Start")
    else
        gfx.set(1, 0, 0, 1) -- Red
        gfx.rect(gfx.x, gfx.y, 80, 30)
        gfx.set(1, 1, 1, 1)
        gfx.x, gfx.y = gfx.x + 25, gfx.y + 8
        gfx.drawstr("Stop")
    end
    
    -- Reset button
    gfx.x, gfx.y = 110, 100
    gfx.set(0.5, 0.5, 0.5, 1) -- Gray
    gfx.rect(gfx.x, gfx.y, 80, 30)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = gfx.x + 25, gfx.y + 8
    gfx.drawstr("Reset")
    
    -- Close button
    gfx.x, gfx.y = 200, 100
    gfx.set(0.5, 0.5, 0.5, 1) -- Gray
    gfx.rect(gfx.x, gfx.y, 80, 30)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = gfx.x + 25, gfx.y + 8
    gfx.drawstr("Close")
end

-- Handle mouse clicks
function handle_mouse()
    local mouse_x, mouse_y = gfx.mouse_x, gfx.mouse_y
    
    if gfx.mouse_cap & 1 == 1 then -- Left mouse button
        -- Start/Stop button
        if mouse_x >= 20 and mouse_x <= 100 and mouse_y >= 100 and mouse_y <= 130 then
            running = not running
            if running then
                start_time = reaper.time_precise()
            end
        end
        
        -- Reset button
        if mouse_x >= 110 and mouse_x <= 190 and mouse_y >= 100 and mouse_y <= 130 then
            running = false
        end
        
        -- Close button
        if mouse_x >= 200 and mouse_x <= 280 and mouse_y >= 100 and mouse_y <= 130 then
            gfx.quit()
            return false
        end
    end
    
    return true
end

-- Main loop
function main()
    if running then
        local current_time = reaper.time_precise()
        local elapsed = current_time - start_time
        
        if elapsed <= duration then
            -- Calculate current value based on elapsed time
            local progress = elapsed / duration
            local current_value = math.floor(progress * 127)
            
            -- Send all CCs 1-127 with the current value
            for cc = 1, 127 do
                send_cc(cc, current_value, 1)
            end
        else
            -- Sweep complete
            running = false
            reaper.ShowMessageBox("All CCs 1-127 sweep completed!", "Test Complete", 0)
        end
    end
    
    draw_gui()
    
    if not handle_mouse() then
        return
    end
    
    gfx.update()
    
    if gfx.getchar() >= 0 then
        reaper.defer(main)
    else
        gfx.quit()
    end
end

-- Start the script
init_gfx()
main()
