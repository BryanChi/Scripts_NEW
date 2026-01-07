-- Test script to check REAPER resource path
if not reaper then
  print("This script must be run in REAPER")
  return
end

local resource_path = reaper.GetResourcePath()
print("REAPER Resource Path: " .. resource_path)

local script_path = resource_path .. '/Scripts/BRYAN\'s SCRIPTS/'
local file_path = script_path .. 'style_presets.json'
print("Generated file path: " .. file_path)

local file = io.open(file_path, 'r')
if file then
  print("File opened successfully")
  local content = file:read('*all')
  file:close()
  print("File size: " .. #content .. " bytes")
else
  print("Failed to open file")
end
