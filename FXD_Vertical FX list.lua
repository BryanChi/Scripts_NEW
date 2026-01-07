
-- @name FXD - Vertical FX List
-- @author Bryan Chi
-- @version 1.0
-- @about Vertical FX List - A comprehensive vertical FX chain interface for REAPER, visit www.coolreaperscripts.com for details
-- @provides
--   [main] FXD_Vertical FX list.lua
--   [nomain] style_presets_FACTORY.lua
--   [nomain] fx_favorites.txt
--   [nomain] Vertical FX List Resources/**


local r = reaper
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
im = require 'imgui' '0.9.3'
OS = r.GetOS()
local FunctionFolder = r.GetResourcePath() ..
    '/Scripts/ReaTeam Scripts/Tracks Properties/bryanchi_FXD - Vertical FX List/Functions/'

dofile(FunctionFolder .. 'General functions.lua')
--[[ arrange_hwnd  = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 0x3E8) -- client position

_, Top_Arrang = reaper.JS_Window_ClientToScreen(arrange_hwnd, 0, 0)         -- convert to screen position (where clients x,y is actually on the screen)
 ]]

WetDryKnobSz         = 7
SpaceBtwnFXs         = 1
ShowFXNum            = true
Show_FX_Drag_Preview = true
MovFX                = { ToPos = {}, FromPos = {}, Lbl = {}, Copy = {}, FromTrack = {}, ToTrack = {}, GUID = {} }
NeedLinkFXsGUIDs     = nil -- Table mapping original GUIDs to link when copying multiple FXs with Ctrl+drag
FX                   = { Enable = {} }
FxBtn                = {}
SendValSize          = 40
SendFXBtnSize        = 16
SendsLineHeight      = 13
HelpHint             = {}
HideBtnSz            = 12
Patch_Thick          = 4
Folder_Btn_Compact   = 5

-- Marquee selection system
MarqueeSelection     = {
  isActive = false,
  startX = 0,
  startY = 0,
  endX = 0,
  endY = 0,
  selectedFXs = {}, -- {trackGUID = {fxGUIDs = {}}}
  selectedSends = {}, -- {trackGUID = { { type = 0| -1, idx = number } }}
  lastSelectedTrack = nil,
  lastSelectedFX = nil,
  additive = false,
  mode = 'fx', -- 'fx' or 'sends'
  -- Drag detection
  dragThreshold = 5, -- pixels of movement to consider it a drag
  hasDragged = false,
  initialMouseX = 0,
  initialMouseY = 0,
  startingOnVolDrag = false -- Set to true if right drag starts on volume drag area
}
MultiSelectionButtons = {
  visible = false,
  bypass = false,
  container = false,
  loudnessMatch = false
}
-- Helper: does any track have 2 or more selected FX?
function HasMultiSelection()
  if not MarqueeSelection or not MarqueeSelection.selectedFXs then return false end
  if MarqueeSelection.mode == 'fx' then
    for _, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
      if fxGUIDs and #fxGUIDs >= 2 then return true end
    end
  else
    for _, entries in pairs(MarqueeSelection.selectedSends or {}) do
      if entries and #entries >= 2 then return true end
    end
  end
  return false
end

-- Helper: check if selection spans multiple tracks
function SelectionSpansMultipleTracks()
  if not MarqueeSelection or not MarqueeSelection.selectedFXs then return false end
  local trackCount = 0
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    if fxGUIDs and #fxGUIDs > 0 then
      trackCount = trackCount + 1
      if trackCount >= 2 then return true end
    end
  end
  return false
end

-- Helper: Show a clickable link that opens a URL in the default browser
local function ShowLink(ctx, url, linkText)
  linkText = linkText or url
  
  -- Check if CF_ShellExecute is available (requires SWS extension)
  if not r.CF_ShellExecute then
    im.Text(ctx, linkText)
    return
  end

  -- Display the link in a colored text (using CheckMark color for link appearance)
  local color = im.GetStyleColor(ctx, im.Col_CheckMark)
  im.TextColored(ctx, color, linkText)
  
  -- If clicked, open the URL
  if im.IsItemClicked(ctx) then
    r.CF_ShellExecute(url)
  elseif im.IsItemHovered(ctx) then
    -- Show hand cursor on hover for better UX
    im.SetMouseCursor(ctx, im.MouseCursor_Hand)
  end
end

-- Helper: find the first selected FX across all tracks (for menu positioning)
function GetFirstSelectedFXAcrossTracks()
  if not MarqueeSelection or not MarqueeSelection.selectedFXs then return nil, nil end
  local firstTrackGUID, firstFXGUID = nil, nil
  local firstTrackIndex = math.huge
  local firstFXIndex = math.huge
  
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    if fxGUIDs and #fxGUIDs > 0 then
      local track = GetTrackByGUIDCached(trackGUID)
      if track then
        -- Get track index (master is -1, others are 0-based)
        local trackIndex = -1
        local masterGUID = r.GetTrackGUID(r.GetMasterTrack(0))
        if trackGUID ~= masterGUID then
          local trackCount = r.CountTracks(0) or 0
          for i = 0, trackCount - 1 do
            local tr = r.GetTrack(0, i)
            if tr and r.GetTrackGUID(tr) == trackGUID then
              trackIndex = i
              break
            end
          end
        end
        -- Find first FX index on this track
        local cnt = r.TrackFX_GetCount(track)
        for i = 0, cnt - 1 do
          local g = r.TrackFX_GetFXGUID(track, i)
          for _, sg in ipairs(fxGUIDs) do
            if sg == g then
              -- Compare: lower track index first, then lower FX index
              if trackIndex < firstTrackIndex or (trackIndex == firstTrackIndex and i < firstFXIndex) then
                firstTrackIndex = trackIndex
                firstFXIndex = i
                firstTrackGUID = trackGUID
                firstFXGUID = sg
              end
              break
            end
          end
        end
      end
    end
  end
  
  return firstTrackGUID, firstFXGUID
end
-- Track the primary dragged FX for group moves so we can apply parallel flags to it only
DraggedMultiMove = nil
-- Flag to prevent clearing selection when interacting with selected FXs
InteractingWithSelectedFX = false
-- Flag to prevent clearing selection when interacting with selected Sends/Receives
InteractingWithSelectedSends = false

local function IsValidTrackPtr(track)
  if not track then return false end
  if r.ValidatePtr2 then
    return r.ValidatePtr2(0, track, 'MediaTrack*')
  end
  return true
end

TrackByGUIDCache = TrackByGUIDCache or {}

local function CacheTrackPointer(track)
  if not IsValidTrackPtr(track) then return nil end
  local guid = r.GetTrackGUID(track)
  if guid then
    TrackByGUIDCache[guid] = track
  end
  return track
end

function GetTrackByGUIDCached(trackGUID)
  if not trackGUID then return nil end
  TrackByGUIDCache = TrackByGUIDCache or {}

  local track = TrackByGUIDCache[trackGUID]
  if IsValidTrackPtr(track) then
    local guid = r.GetTrackGUID(track)
    if guid == trackGUID then
      return track
    end
    TrackByGUIDCache[trackGUID] = nil
  end

  if r.BR_GetMediaTrackByGUID then
    track = CacheTrackPointer(r.BR_GetMediaTrackByGUID(0, trackGUID))
    if track then return track end
  end

  local master = r.GetMasterTrack(0)
  if IsValidTrackPtr(master) and r.GetTrackGUID(master) == trackGUID then
    return CacheTrackPointer(master)
  end

  local trackCount = r.CountTracks(0) or 0
  for i = 0, trackCount - 1 do
    local tr = r.GetTrack(0, i)
    if IsValidTrackPtr(tr) and r.GetTrackGUID(tr) == trackGUID then
      return CacheTrackPointer(tr)
    end
  end

  return nil
end

-- Animation phase for moving chevron (patch) lines
PatchLineShift = 0        -- pixels offset along the line; will be advanced every frame
PatchLineSpeed = 1        -- how many pixels per frame the chevrons move

Clr={SendHvr = 0x289F8177 ; Send = 0x289F8144 ; VSTi=0x43BB8899 ; VSTi_Hvr =0x43BB88cc; VSTi_Act = 0x43BB88ff;
  Fader_Inv = 0x80FFA4ff ; Fader_Inv_Bg = 0x399954ff;
  FrameBG = 0x252525ff;
  FrameBGHvr = 0x333333ff;
  FrameBGAct = 0x393939ff;
  PanValue = 0x43BB8855;
  PanValue_INV = 0xB0BB4355;

  -- Slightly transparent FX button colours
  Buttons     = 0x333333ff;  -- default
  ButtonsHvr  = 0x555555ff;  -- hover
  ButtonsAct  = 0x777777ff;  -- active

  ReceiveSend= 0x2C2F9044 ; ReceiveSendHvr = 0x2C2F9077;

  SliderGrb = 0x377F60ff; SliderGrbAct = 0x449D77ff;

  -- Element-specific colours editable in Style Editor
  SelectionOutline   = 0x289F81ff; -- based on Send but full alpha
  PaneSeparator      = 0xffffffff; -- center separator line
  PaneSeparatorGuide = 0xffffffff; -- dotted guide during drag
  TrackBoundaryLine  = 0x777777ff; -- row boundary line

  -- Additional customizable colors
  GenericHighlightFill    = 0xffffff33;
  GenericHighlightOutline = 0xffffff88;
  PatchLine               = 0xffffffdd;
  SendsPreview            = 0xffffff88;
  SnapshotOverlay         = 0xffffff88;
  Danger                  = 0xFF0000FF;   -- e.g., red X indicator
  Attention               = 0xffff00ff;   -- e.g., yellow eye icons
  ChanBadgeBg             = 0x27463Eff;
  ChanBadgeText           = 0xffffffff;
  PanTextOverlay          = 0xffffff44;
  ValueRect               = 0x77777777;
  LinkCable               = 0xffffffff;
  -- Hidden parents colors
  HiddenParentOutline     = 0x333333ff; -- dim gray
  HiddenParentHover       = 0x2ECC7177; -- green
  -- Menu button hover color
  MenuHover               = 0x555555ff; -- menu item hover (defaults to same as ButtonsHvr)
  -- Menu bar button base color (hover/active derived from this)
  MenuBarButton           = 0x00000000; -- transparent by default, user can customize
}

-- Global outline color used by highlight helpers
OutlineClr = Clr.SelectionOutline

-- Allow saving/loading of element-specific colors with presets
local ElementColorKeys = {
  'Buttons','ButtonsHvr','ButtonsAct',
  'VSTi','VSTi_Hvr','VSTi_Act',
  'Send','SendHvr','ReceiveSend','ReceiveSendHvr',
  'SelectionOutline','PaneSeparator','PaneSeparatorGuide','TrackBoundaryLine',
  'GenericHighlightFill','GenericHighlightOutline','PatchLine','SendsPreview',
  'SnapshotOverlay',
  'Danger','Attention','ChanBadgeBg','ChanBadgeText','PanTextOverlay',
  'ValueRect','LinkCable', 'PatchLine',
  'MenuHover','MenuBarButton',
  'HiddenParentOutline','HiddenParentHover'
}

local function GetCustomClrPreset()
  local t = {}
  for _,k in ipairs(ElementColorKeys) do t[k] = Clr[k] end
  return t
end

local function ApplyCustomClrPreset(t)
  if not t then return end
  for k,v in pairs(t) do if Clr[k] ~= nil and type(v)=='number' then Clr[k] = v end end
  OutlineClr = Clr.SelectionOutline or OutlineClr
end

CustomColorsDefault = {
  FX_Adder_VST = 0x6FB74BFF,
  FX_Adder_VST3 = 0xC3DC5CFF,
  FX_Adder_JS = 0x9348A9FF,
  FX_Adder_AU = 0x526D97FF,
  FX_Adder_CLAP = 0xB62424FF,
  FX_Adder_VST3i = 0xC3DC5CFF,
  FX_Adder_VSTi = 0x6FB74BFF,
  FX_Adder_AUi = 0x526D97FF,
  FX_Adder_CLAPi = 0xB62424FF

}
PanningTracks = {}
PanningTracks_INV={}



OPEN={}
ContainerCollapsed = {}
ContainerAnim = {}
-- Delete animation state per FX GUID
FXDeleteAnim = FXDeleteAnim or {}
PendingDeleteGUIDs = PendingDeleteGUIDs or {}
-- Track delayed snapshot panel closures (to prevent accidental FX deletion)
DelaySnapshotPanelClose = DelaySnapshotPanelClose or {}
-- Animation for snapshot panel closing
SnapshotPanelCloseAnim = SnapshotPanelCloseAnim or {}
-- Default delete animation step (thousandths = 750 => 0.750 per frame)
DELETE_ANIM_STEP = DELETE_ANIM_STEP or 0.750

--.persist OPEN in project extstate
local OPEN_SECTION = 'FXD_Vertical_FX_List'
local OPEN_KEY     = 'OPEN'

local function_folder = r.GetResourcePath() ..
'/Vertical FX List/Vertical FX List Resources/Functions/'
dofile(function_folder..'FX Buttons.lua')
dofile(function_folder..'Sends.lua')



local function SaveOpenState()
  local parts = {}
  for k, v in pairs(OPEN) do
    -- Persist only project-scoped values; skip globals like ShowHiddenParents and Settings
    if k ~= 'ShowHiddenParents' and k ~= 'Settings' then
      if k == 'Snapshots' and type(v) == 'number' then
        -- Handle Snapshots as numeric value (0=hidden, 1=show with snapshots, 2=show all)
        parts[#parts+1] = k .. '=' .. tostring(v)
      elseif v and type(v)=='boolean' then
        parts[#parts+1] = k .. '=' .. (v and '1' or '0')
      end
    end
  end
  local str = table.concat(parts, ';')
  r.SetProjExtState(0, OPEN_SECTION, OPEN_KEY, str)
end

local function LoadOpenState()
  local ok, str = r.GetProjExtState(0, OPEN_SECTION, OPEN_KEY)
  if ok == 1 and str ~= '' then
    for pair in string.gmatch(str, '([^;]+)') do
      local k, val = pair:match('([^=]+)=(%d+)')
      if k and val then
        if k == 'Snapshots' then
          -- Handle Snapshots as numeric value (0=hidden, 1=show with snapshots, 2=show all)
          OPEN[k] = tonumber(val) or 0
        else
          OPEN[k] = (val=='1')
        end
      end
    end
  end
end

LoadOpenState()

-- Global extstate helpers for user preferences (persist across all projects)
local GLOBAL_SECTION = 'FXD_Vertical_FX_List_Global'
local function SaveGlobalBool(key, value)
  r.SetExtState(GLOBAL_SECTION, key, value and '1' or '0', true)
end
local function LoadGlobalBool(key, default)
  local v = r.GetExtState(GLOBAL_SECTION, key)
  if v == '' then return default end
  return v == '1'
end
-- Global numeric helpers
local function SaveGlobalNumber(key, value)
  r.SetExtState(GLOBAL_SECTION, key, tostring(math.floor(tonumber(value) or 0)), true)
end
local function LoadGlobalNumber(key, default)
  local v = r.GetExtState(GLOBAL_SECTION, key)
  if v == '' then return default end
  return tonumber(v) or default
end

-- ============================================================================
-- License verification with License Key
-- API: POST /api/license/verify with body {"licenseKey": "<key>", "deviceId": "<device_id>"}
-- Server should check if license key has more than 3 active devices
-- ============================================================================
local LICENSE_SECTION = 'FXD_Vertical_FX_List_License'
-- Set to your deployed website domain (Vercel/Netlify/etc)
local LICENSE_VERIFY_URL = 'https://coolreaperscripts.com/api/license/verify'
local LICENSE_CHECK_INTERVAL = 24 * 60 * 60 -- seconds

LicenseState = LicenseState or {
  status = nil,          -- active | trial | expired | inactive
  expiresAt = nil,       -- ms since epoch
  reason = nil,
  licenseKey = nil,
  deviceId = nil,        -- Unique device identifier
  lastCheck = 0,
  checking = false
}

-- Generate or retrieve a unique device ID for this machine
local function GetOrCreateDeviceId()
  local deviceId = r.GetExtState(LICENSE_SECTION, 'deviceId')
  if deviceId and deviceId ~= '' then
    return deviceId
  end
  
  -- Generate a new device ID based on system info
  local deviceInfo = {}
  
  -- Try to get system-specific identifiers
  if OS:match('Win') then
    -- On Windows, try to get computer name
    local computerName = r.ExecProcess('echo %COMPUTERNAME%', 2000)
    if computerName and computerName ~= '' then
      deviceInfo[#deviceInfo + 1] = computerName:match('^%s*(.-)%s*$')
    end
  elseif OS:match('OSX') or OS:match('Darwin') or OS:match('Mac') then
    -- On macOS, try to get hostname
    local hostname = r.ExecProcess('/bin/hostname', 2000)
    if hostname and hostname ~= '' then
      deviceInfo[#deviceInfo + 1] = hostname:match('^%s*(.-)%s*$')
    end
  else
    -- Linux
    local hostname = r.ExecProcess('hostname', 2000)
    if hostname and hostname ~= '' then
      deviceInfo[#deviceInfo + 1] = hostname:match('^%s*(.-)%s*$')
    end
  end
  
  -- Add REAPER resource path as additional identifier
  local resourcePath = r.GetResourcePath()
  if resourcePath then
    deviceInfo[#deviceInfo + 1] = resourcePath
  end
  
  -- Create a hash-like identifier from the device info
  local combined = table.concat(deviceInfo, '|')
  local hash = 0
  for i = 1, #combined do
    hash = ((hash * 31) + string.byte(combined, i)) % 2147483647
  end
  
  -- Generate a more readable device ID
  local chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  math.randomseed(hash)
  local deviceId = ''
  for i = 1, 16 do
    local rand = math.random(1, #chars)
    deviceId = deviceId .. chars:sub(rand, rand)
  end
  
  -- Save it
  r.SetExtState(LICENSE_SECTION, 'deviceId', deviceId, true)
  return deviceId
end

local function LoadLicenseState()
  local status = r.GetExtState(LICENSE_SECTION, 'status')
  if status ~= '' then LicenseState.status = status end
  local exp = tonumber(r.GetExtState(LICENSE_SECTION, 'expiresAt'))
  if exp then LicenseState.expiresAt = exp end
  local reason = r.GetExtState(LICENSE_SECTION, 'reason')
  if reason ~= '' then LicenseState.reason = reason end
  local key = r.GetExtState(LICENSE_SECTION, 'licenseKey')
  if key ~= '' then LicenseState.licenseKey = key end
  local deviceId = r.GetExtState(LICENSE_SECTION, 'deviceId')
  if deviceId ~= '' then LicenseState.deviceId = deviceId end
  local last = tonumber(r.GetExtState(LICENSE_SECTION, 'lastCheck'))
  if last then LicenseState.lastCheck = last end
  
  -- Ensure device ID exists
  if not LicenseState.deviceId or LicenseState.deviceId == '' then
    LicenseState.deviceId = GetOrCreateDeviceId()
  end
end

local function SaveLicenseState()
  r.SetExtState(LICENSE_SECTION, 'status', LicenseState.status or '', true)
  r.SetExtState(LICENSE_SECTION, 'expiresAt', tostring(LicenseState.expiresAt or ''), true)
  r.SetExtState(LICENSE_SECTION, 'reason', LicenseState.reason or '', true)
  r.SetExtState(LICENSE_SECTION, 'licenseKey', LicenseState.licenseKey or '', true)
  r.SetExtState(LICENSE_SECTION, 'deviceId', LicenseState.deviceId or '', true)
  r.SetExtState(LICENSE_SECTION, 'lastCheck', tostring(LicenseState.lastCheck or 0), true)
end

local function SetLicenseResult(status, expiresAt, reason, licenseKey)
  LicenseState.status = status
  LicenseState.expiresAt = expiresAt
  LicenseState.reason = reason
  LicenseState.licenseKey = licenseKey
  LicenseState.lastCheck = os.time()
  SaveLicenseState()
end

local function FormatExpiry(expiresAt)
  if not expiresAt then return 'No expiry' end
  -- API returns milliseconds; convert if value looks like ms
  local value = expiresAt
  if value > 1e11 then
    value = math.floor(value / 1000)
  end
  return os.date('%Y-%m-%d %H:%M:%S', value)
end

local function BuildLicenseCurl(payload)
  if OS:match('Win') then
    return string.format(
      'curl -L -s -X POST -H "Content-Type: application/json" -d "%s" "%s"',
      payload:gsub('"', '\\"'),
      LICENSE_VERIFY_URL
    )
  else
    -- On macOS/Linux, use full path and proper escaping
    return string.format(
      "/usr/bin/curl -L -s -X POST -H 'Content-Type: application/json' -d %q %q",
      payload,
      LICENSE_VERIFY_URL
    )
  end
end

local function VerifyLicense(licenseKey)
  if LicenseState.checking then return false, 'Already checking' end
  
  -- Require license key
  local key = licenseKey or LicenseState.licenseKey
  if not key or key == '' then
    return false, 'License key required'
  end
  
  -- Ensure device ID exists
  if not LicenseState.deviceId or LicenseState.deviceId == '' then
    LicenseState.deviceId = GetOrCreateDeviceId()
  end
  
  LicenseState.licenseKey = key
  SaveLicenseState()

  -- Check if URL is configured
  if LICENSE_VERIFY_URL:match('your%-api%-domain') or LICENSE_VERIFY_URL:match('example%.com') then
    SetLicenseResult('inactive', nil, 'API URL not configured. Please set LICENSE_VERIFY_URL in the script.', nil)
    return false, 'API URL not configured'
  end

  -- Test if curl is available
  local curl_test = r.ExecProcess('curl --version', 2000)
  if not curl_test or curl_test == '' then
    SetLicenseResult('inactive', nil, 'curl not found. Please install curl or use a system with curl available.', nil)
    return false, 'curl not available'
  end

  -- Escape JSON values properly
  local function escapeJson(str)
    if not str then return '' end
    return tostring(str):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
  end

  local payload = string.format('{"licenseKey":"%s","deviceId":"%s"}', 
    escapeJson(key), 
    escapeJson(LicenseState.deviceId))
  local cmd = BuildLicenseCurl(payload)

  LicenseState.checking = true
  
  -- Use io.popen with proper output capture
  local response = nil
  
  local handle = io.popen(cmd, 'r')
  if handle then
    -- Read all output line by line to ensure we get everything
    local lines = {}
    for line in handle:lines() do
      table.insert(lines, line)
    end
    response = table.concat(lines, '\n')
    handle:close()
  else
    response = r.ExecProcess(cmd, 10000)
  end
  
  LicenseState.checking = false

  -- Check if response looks like an error code (single digit or negative number)
  if response and type(response) == 'string' then
    local trimmed = response:match('^%s*(.-)%s*$')  -- Trim whitespace
    if trimmed:match('^-?%d+$') and tonumber(trimmed) and (tonumber(trimmed) < 10 or tonumber(trimmed) < 0) then
      SetLicenseResult('inactive', nil, 'curl returned error code: ' .. trimmed .. '. Check console for command details.', nil)
      return false, 'curl error code: ' .. trimmed
    end
    response = trimmed  -- Use trimmed version
  end

  if not response or response == '' or (type(response) == 'string' and response:match('^%s*$')) then
    SetLicenseResult('inactive', nil, 'No response from server. Check your internet connection and API URL.', nil)
    return false, 'No response from server'
  end

  -- Parse JSON response (simple pattern matching)
  -- Try multiple formats for compatibility
  local ok = response:match('"ok"%s*:%s*true') ~= nil or 
             response:match('"ok"%s*:%s*True') ~= nil or
             response:match('"success"%s*:%s*true') ~= nil or
             response:match('"success"%s*:%s*True') ~= nil
  
  local status = response:match('"status"%s*:%s*"([^"]+)"')
  
  -- Handle expiresAt - can be a number or null
  local expiresAt = nil
  local expiresAtStr = response:match('"expiresAt"%s*:%s*([^,}]+)')
  if expiresAtStr then
    expiresAtStr = expiresAtStr:match('^%s*(.-)%s*$')  -- trim whitespace
    if expiresAtStr ~= 'null' and expiresAtStr ~= 'nil' then
      expiresAt = tonumber(expiresAtStr)
    end
  end
  
  local reason = response:match('"reason"%s*:%s*"([^"]+)"') or 
                 response:match('"message"%s*:%s*"([^"]+)"') or
                 response:match('"error"%s*:%s*"([^"]+)"')
  local returnedKey = response:match('"licenseKey"%s*:%s*"([^"]+)"')
  
  if not ok then
    -- Show full response in error for debugging
    local errorMsg = reason or 'Verification failed'
    if not reason or reason == '' then
      -- If no reason provided, show first 200 chars of response for debugging
      local responsePreview = response:sub(1, 200)
      errorMsg = 'Verification failed. Server response: ' .. responsePreview
    end
    SetLicenseResult('inactive', expiresAt, errorMsg, returnedKey or key)
    return false, errorMsg
  end

  -- Ensure status is set
  if not status or status == '' then
    status = 'active'  -- Default to active if ok is true but status is missing
  end
  
  SetLicenseResult(status, expiresAt, reason, returnedKey or key)
  return true, status
end

local _0x1a2b = {}
_0x1a2b._0x3c4d = false
_0x1a2b._0x5e6f = nil
_0x1a2b._0x7a8b = false
_0x1a2b._0x9c0d = 0
_0x1a2b._0x2a3b = false  -- Track if modal was open in previous frame

local _0x2e3f = function() return string.char(76, 105, 99, 101, 110, 115, 101) end
local _0x4a5b = function() return string.char(86, 101, 114, 105, 102, 105, 99, 97, 116, 105, 111, 110) end
local _0x6c7d = function() return string.char(82, 101, 113, 117, 105, 114, 101, 100) end
local _0x8e9f = function() return string.char(75, 101, 121) end
local _0x1a2c = function() return string.char(83, 116, 97, 116, 117, 115) end
local _0x3d4e = function() return string.char(69, 120, 112, 105, 114, 101, 115) end
local _0x5f6g = function() return string.char(68, 101, 118, 105, 99, 101) end
local _0x7h8i = function() return string.char(73, 68) end
local _0x9j0k = function() return string.char(78, 111, 116, 32, 115, 101, 116) end
local _0x1l2m = function() return string.char(78, 111, 116, 32, 103, 101, 110, 101, 114, 97, 116, 101, 100) end
local _0x3n4o = function() return string.char(86, 101, 114, 105, 102, 121) end
local _0x5p6q = function() return string.char(86, 101, 114, 105, 102, 121, 105, 110, 103, 46, 46, 46) end
local _0x7r8s = function() return string.char(82, 101, 109, 111, 118, 101) end
local _0x9t0u = function() return string.char(69, 110, 116, 101, 114) end
local _0x1v2w = function() return string.char(97, 99, 116, 105, 118, 97, 116, 101) end
local _0x3x4y = function() return string.char(65, 99, 116, 105, 118, 97, 116, 101) end
local _0x5z6a = function() return string.char(83, 117, 99, 99, 101, 115, 115) end
local _0x7b8c = function() return string.char(84, 114, 105, 97, 108) end
local _0x9d0e = function() return string.char(100, 97, 121, 115) end
local _0x1f2g = function() return string.char(114, 101, 109, 97, 105, 110, 105, 110, 103) end

local function _0x7a8b()
  if not LicenseState then return false end
  local _0x9c0d = LicenseState.status
  if not _0x9c0d then return false end
  return (_0x9c0d == 'active') or (_0x9c0d == 'trial')
end

local function _0x1e2f()
  local _0x3a4b = LicenseState
  if not _0x3a4b then return false end
  local _0x5c6d = _0x3a4b.status
  if _0x5c6d == 'active' then return true end
  if _0x5c6d == 'trial' then return true end
  return false
end

function IsLicenseValid()
  local _0x7f8a = _0x7a8b()
  local _0x9b0c = _0x1e2f()
  if not LicenseState or not LicenseState.status then return false end
  local result = (LicenseState.status == 'active' or LicenseState.status == 'trial')
  if result ~= _0x7f8a or result ~= _0x9b0c then return false end
  return result
end

local function LicenseStatusText()
  if not LicenseState.status then 
    return 'Unknown' 
  end
  local status = LicenseState.status
  if status == 'active' then return 'Active license' end
  if status == 'trial' then
    if LicenseState.expiresAt then
      return string.format('Trial until %s', FormatExpiry(LicenseState.expiresAt))
    end
    return 'Trial active'
  end
  if status == 'expired' then return 'Trial expired' end
  if status == 'inactive' then return LicenseState.reason or 'No license' end
  return status
end

local function MaybeAutoVerifyLicense()
  if LicenseState.checking then return end
  if not LicenseState.licenseKey or LicenseState.licenseKey == '' then return end
  if (os.time() - (LicenseState.lastCheck or 0)) < LICENSE_CHECK_INTERVAL then return end
  VerifyLicense(LicenseState.licenseKey)
end

LoadLicenseState()

-- Check license on startup if license key exists
if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
  if os.time() - LicenseState.lastCheck > 3600 then
    VerifyLicense(LicenseState.licenseKey)
  end
end

-- ============================================================================
-- OAuth Configuration - Load from environment variables or config file
-- ============================================================================
local OAUTH_CONFIG_FILE = r.GetResourcePath() .. '/Scripts/BRYAN\'s SCRIPTS/oauth_config.lua'

-- Load OAuth credentials from environment variables or config file
local function LoadOAuthConfig()
  local clientId = nil
  local clientSecret = nil
  
  -- First, try to load from environment variables (most secure)
  if OS:match('Win') then
    -- Windows: use set command
    local envId = r.ExecProcess('echo %GOOGLE_OAUTH_CLIENT_ID%', 2000)
    local envSecret = r.ExecProcess('echo %GOOGLE_OAUTH_CLIENT_SECRET%', 2000)
    if envId and envId ~= '' and envId ~= '%GOOGLE_OAUTH_CLIENT_ID%' then
      clientId = envId:match('^%s*(.-)%s*$')
    end
    if envSecret and envSecret ~= '' and envSecret ~= '%GOOGLE_OAUTH_CLIENT_SECRET%' then
      clientSecret = envSecret:match('^%s*(.-)%s*$')
    end
  else
    -- macOS/Linux: use environment variables
    local envId = r.ExecProcess('echo "$GOOGLE_OAUTH_CLIENT_ID"', 2000)
    local envSecret = r.ExecProcess('echo "$GOOGLE_OAUTH_CLIENT_SECRET"', 2000)
    if envId and envId ~= '' and envId ~= '\n' then
      clientId = envId:match('^%s*(.-)%s*$')
    end
    if envSecret and envSecret ~= '' and envSecret ~= '\n' then
      clientSecret = envSecret:match('^%s*(.-)%s*$')
    end
  end
  
  -- If not found in environment, try loading from config file
  if (not clientId or not clientSecret) then
    local configFile = io.open(OAUTH_CONFIG_FILE, 'r')
    if configFile then
      local configContent = configFile:read('*all')
      configFile:close()
      
      -- Simple Lua table parsing for config file
      -- Expected format: return { client_id = "...", client_secret = "..." }
      local success, config = pcall(load(configContent))
      if success and config then
        local result = config()
        if result and type(result) == 'table' then
          clientId = clientId or result.client_id
          clientSecret = clientSecret or result.client_secret
        end
      end
    end
  end
  
  return clientId, clientSecret
end

-- OAuth configuration (loaded on demand)
local OAuthConfig = {
  clientId = nil,
  clientSecret = nil,
  loaded = false
}

-- Get OAuth client ID (loads config if not already loaded)
local function GetOAuthClientId()
  if not OAuthConfig.loaded then
    OAuthConfig.clientId, OAuthConfig.clientSecret = LoadOAuthConfig()
    OAuthConfig.loaded = true
  end
  return OAuthConfig.clientId
end

-- Get OAuth client secret (loads config if not already loaded)
local function GetOAuthClientSecret()
  if not OAuthConfig.loaded then
    OAuthConfig.clientId, OAuthConfig.clientSecret = LoadOAuthConfig()
    OAuthConfig.loaded = true
  end
  return OAuthConfig.clientSecret
end


if OPEN.ShortenFXNames == nil then OPEN.ShortenFXNames = true end

-- Show full size hidden parents is GLOBAL; load from global extstate
OPEN.ShowHiddenParents = LoadGlobalBool('ShowHiddenParents', OPEN.ShowHiddenParents or false)

-- Show pan knobs for sends/receives (global persistent)
ShowSendPanKnobs = LoadGlobalBool('ShowSendPanKnobs', false)

-- Show favorite FXs under search bar (global persistent)
ShowFavoritesUnderSearchBar = LoadGlobalBool('ShowFavoritesUnderSearchBar', false)

-- Monitor FX columns (global persistent, 1-6)
MonitorFX_Columns = LoadGlobalNumber('MonitorFX_Columns', 1)
if MonitorFX_Columns < 1 then MonitorFX_Columns = 1 end
if MonitorFX_Columns > 6 then MonitorFX_Columns = 6 end

-- Hidden parent button height (global persistent)
Folder_Btn_Compact = LoadGlobalNumber('HiddenParentBtnH', Folder_Btn_Compact or 5)
-- Load global delete animation speed (stored as thousandths)
do
  local stepInt = LoadGlobalNumber('FXDeleteAnimStep', 750)
  if not stepInt or stepInt <= 0 then stepInt = 750 end
  DELETE_ANIM_STEP = (stepInt or 750) / 1000
end

-- Load global send delete animation speed (stored as thousandths)
do
  local stepInt = LoadGlobalNumber('SendDeleteAnimStep', 80)
  if not stepInt or stepInt <= 0 then stepInt = 80 end
  SEND_DELETE_ANIM_STEP = (stepInt or 80) / 1000
end


-- Per-track FX pane widths (persisted per project)
local WIDTHS_SECTION = 'FXD_Vertical_FX_List_PerTrackWidths'
local WIDTHS_KEY     = 'widths'
PerTrackFXPane_W        = {}
PerTrackSendsHidden     = {}
PerTrackDragAccum       = {}
PerTrackSnappedToGlobal = {}
PerTrackSnapBreakAccum  = {}
PerTrackSnapBreakDir    = {}
PerTrackHideFade        = {}

local SNAP_THRESHOLD = 15  -- px distance to break apart or snap back to global
local MIN_SEND_W     = 70  -- px minimum visible width before hide threshold begins
local HIDE_DRAG_PX   = 10  -- additional right-drag beyond min width to trigger hide on release
PerTrackHideOvershoot = {}

-- Accumulate screen-space bounds for hidden children when drawing full-size hidden parents
HiddenParentBounds = HiddenParentBounds or {}
HiddenParentBtnRect = HiddenParentBtnRect or {}
HiddenParentHoveredGUID = nil
HiddenParentBtnBoldNext = HiddenParentBtnBoldNext or {}
-- Outlines to draw at end of frame so they appear on top
HiddenOutlinesToDraw = HiddenOutlinesToDraw or {}

-- Tween state for smoothing Sends hide/show per track (animate FX pane width)
PerTrackSendsTween = {}
local function EaseOutCubic(x)
  if not x then return 0 end
  local inv = 1 - x
  return 1 - inv * inv * inv
end
local TWEEN_STEP = 0.18 -- progress per frame

local function SavePerTrackWidths()
  local parts = {}
  for guid, w in pairs(PerTrackFXPane_W) do
    if type(guid) == 'string' and type(w) == 'number' then
      parts[#parts+1] = guid .. '=' .. tostring(math.floor(w))
    end
  end
  r.SetProjExtState(0, WIDTHS_SECTION, WIDTHS_KEY, table.concat(parts, ';'))
end

local function LoadPerTrackWidths()
  local ok, str = r.GetProjExtState(0, WIDTHS_SECTION, WIDTHS_KEY)
  if ok == 1 and str ~= '' then
    for pair in string.gmatch(str, '([^;]+)') do
      local g, w = pair:match('([^=]+)=([%d%.]+)')
      if g and w then PerTrackFXPane_W[g] = tonumber(w) end
    end
  end
end

LoadPerTrackWidths()
PerTrackWidth_DragActive = false
-- Track separator drag state to stabilize highlights while dragging
SeparatorDragGUID = nil
SeparatorDragIsIndependent = nil
PendingGlobalDragDX = 0
-- Accumulator for snapping break-away (single drag at a time)
SnapBreakAccum = 0
SnapBreakActiveGUID = nil
SnapDragBaselineDX = nil
-- Track whether current drag is a Shift (independent) drag
ShiftBoundaryDragGUID = nil
-- Per-track Sends hidden persistence
local SENDS_SECTION = 'FXD_Vertical_FX_List_PerTrackSends'
local SENDS_KEY     = 'hidden'
local function SavePerTrackSendsHidden()
  local parts = {}
  for guid, hidden in pairs(PerTrackSendsHidden) do
    if hidden then parts[#parts+1] = guid .. '=1' end
  end
  r.SetProjExtState(0, SENDS_SECTION, SENDS_KEY, table.concat(parts,';'))
end
local function LoadPerTrackSendsHidden()
  local ok, str = r.GetProjExtState(0, SENDS_SECTION, SENDS_KEY)
  if ok == 1 and str ~= '' then
    for pair in string.gmatch(str, '([^;]+)') do
      local g, v = pair:match('([^=]+)=(%d)')
      if g then PerTrackSendsHidden[g] = (v == '1') end
    end
  end
end
LoadPerTrackSendsHidden()
PerTrackWidth_DragActive = false

SPECIAL_FX = { 'JS: volume adjustment' }
SPECIAL_FX.Prm = {}
SPECIAL_FX.Prm['JS: volume adjustment'] = 0
SPECIAL_FX.ShownName={}
SPECIAL_FX.ShownName['JS: volume adjustment'] = 'Gain = '




function DrawDottedArrowLine(draw_list, x1, y1, x2, y2, spacing, arrowSize, color, invertDir)
--[[   local Hi, Low = y1 > y2 and y1 or y2, y1 > y2 and y2 or y1
  local y1, y2 = Hi, Low ]]
  local S = arrowSize
  local Dir_UP = y1 > y2
  if invertDir then Dir_UP = not Dir_UP end

  local y1 = Dir_UP and y1 - S/2 or y1 
  local y2 = Dir_UP and y2 + S/2 or y2 - S/2

  local dx = x2 - x1
  local dy = y2 - y1
  local distance = math.sqrt(dx*dx + dy*dy)

  -- ensure spacing positive
  spacing = math.max(1, spacing)

  -- shift all chevrons along the line to create animation
  local phase = (PatchLineShift or 0) % spacing

  -- If the arrow orientation (Dir_UP) disagrees with the coordinate order, run the animation in reverse
  local pathUp = (y1 > y2)
  local reverseMotion = (pathUp ~= Dir_UP)

  -- start drawing from negative offset so first visible chevron can slide in
  for dist = -phase, distance, spacing do
    if dist >= 0 then
      local t = dist / distance
      if reverseMotion then t = 1 - t end
      local x = x1 + t * dx
      local y = y1 + t * dy
      --Calculate arrow points (example, needs proper calculation)
      local arrowX1 = x
      local arrowY1 = y
      local arrowX2 = x + arrowSize 
      local arrowY2 = Dir_UP and  y - arrowSize or y + arrowSize
      local arrowX3 = x - arrowSize 
      local arrowY3 = Dir_UP and y - arrowSize or y + arrowSize
      local pt = { }
      if Dir_UP then 
        if i == 0 then 
          pt[1] = {x - S/4 ,  y }
          
          pt[2] = {x  ,       y +S/4 }

          pt[3] = {x + S/4 ,  y }
          pt[4] = {x + S/4  , y + S/2 }
          pt[5] = {x - S/4 ,  y + S/2 }
        else 
          pt[1] = {x - S/4 ,  y }
          pt[2] = {x  ,       y + S/4 }
          pt[3] = {x + S/4 ,  y }
          pt[4] = {x + S/4 ,  y + S/2 }
          pt[5]= {x   ,       y + S/4  + S/2 }
          pt[6] = {x - S/4 ,  y + S/2 }
        end
      else 
        if i == 0 then 
          pt[1] = {x - S/4 ,  y }

          pt[2] = {x + S/4 ,  y }
          pt[3] = {x + S/4 ,  y + S/2 }
          pt[4] = {x   ,       y + S/4 }
          pt[5] = {x - S/4 , y + S/2 }
        else 
          pt[1] = {x - S/4 ,  y }
          pt[2] = {x  ,       y - S/4 }
          pt[3] = {x + S/4 ,  y }
          pt[4] = {x + S/4 ,  y + S/2 }
          pt[5]= {x   ,       y + S/4 }
          pt[6] = {x - S/4 ,  y + S/2 }
        end
      end


      for i, v in ipairs(pt) do
        im.DrawList_PathLineTo(draw_list, v[1], v[2])
      end 
      if Dir_UP then 
        im.DrawList_PathFillConcave(draw_list,  color)
      else 
        im.DrawList_PathFillConvex(draw_list,  color)
      end
      im.DrawList_PathClear(draw_list)

      --Draw arrow
      --im.DrawList_AddTriangleFilled(draw_list, arrowX1, arrowY1, arrowX2, arrowY2, arrowX3, arrowY3, color) --[1]
    end
  end
end

-- Draw a chevron patch that first goes left by `offset`, then vertically (with animated chevrons),
-- then right back by `offset` into the destination row.
-- x is the original column of the items, y1 is the source row centre, y2 is destination row centre.
function DrawBentPatchLine(draw_list, x, y1, y2, offset, color, invertDir)
  offset = offset or 10
  color  = color  or (Clr and Clr.PatchLine) or 0xffffffff
  invertDir = invertDir or false

  local xLeft = x - offset

  -- horizontal from source to left
  im.DrawList_AddLine(draw_list, x, y1, xLeft, y1, color, Patch_Thick)

  -- vertical animated chevrons
  DrawDottedArrowLine(draw_list, xLeft, y1, xLeft, y2, Patch_Thick*2, Patch_Thick*3, color, invertDir)

  -- horizontal into destination
  im.DrawList_AddLine(draw_list, xLeft, y2, x, y2, color, Patch_Thick)
end

-- Same as DrawBentPatchLine but with non-animated chevrons (phase=0)
function DrawBentPatchLineStatic(draw_list, x, y1, y2, offset, color, invertDir)
  local saved = PatchLineShift
  PatchLineShift = 0
  DrawBentPatchLine(draw_list, x, y1, y2, offset, color, invertDir)
  PatchLineShift = saved
end

-- Draw a vertical chevron line (non-animated) for previews
function DrawChevronLineStatic(draw_list, x, y1, y2, color, invertDir)
  color = color or (Clr and Clr.PatchLine) or 0xffffffff
  local Dir_UP = (y2 < y1)
  local step = Patch_Thick*3
  local S = Patch_Thick*2
  local y = y1
  while (Dir_UP and y > y2) or ((not Dir_UP) and y < y2) do
    local pt = {}
    if Dir_UP then
      pt[1] = {x - S/4 ,  y }
      pt[2] = {x + S/4 ,  y }
      pt[3] = {x + S/4 ,  y + S/2 }
      pt[4] = {x   ,       y + S/4 }
      pt[5] = {x - S/4 ,  y + S/2 }
      y = y - step
    else
      pt[1] = {x - S/4 ,  y }
      pt[2] = {x  ,       y - S/4 }
      pt[3] = {x + S/4 ,  y }
      pt[4] = {x + S/4 ,  y + S/2 }
      pt[5]= {x   ,       y + S/4 }
      pt[6] = {x - S/4 ,  y + S/2 }
      y = y + step
    end
    for i, v in ipairs(pt) do im.DrawList_PathLineTo(draw_list, v[1], v[2]) end
    if Dir_UP then im.DrawList_PathFillConcave(draw_list, color) else im.DrawList_PathFillConvex(draw_list, color) end
    im.DrawList_PathClear(draw_list)
  end
end

-- Normalize hyphens and spaces to treat them as equivalent for search
local function NormalizeHyphensAndSpaces(text)
  if not text then return '' end
  -- Replace hyphens with spaces, then normalize multiple spaces
  local result = text:gsub('-', ' '):gsub('%s+', ' ')
  return result:match('^%s*(.-)%s*$') -- trim
end

function ThirdPartyDeps()
  local ultraschall_path = reaper.GetResourcePath() .. "/UserPlugins/ultraschall_api.lua"
  if ultraschall_path then dofile(ultraschall_path)end
  local version = tonumber (string.sub( reaper.GetAppVersion() ,  0, 4))


  local fx_browser_path
  local n,arch = reaper.GetAppVersion():match("(.+)/(.+)")
  local fx_browser_v6_path
  
  if n:match("^7%.") then
      fx_browser = reaper.GetResourcePath() .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_ParserV7.lua"
      fx_browser_reapack = 'sexan fx browser parser v7' 
  else
      fx_browser= reaper.GetResourcePath() .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_Parser.lua"  
      fx_browser_v6_path = reaper.GetResourcePath() .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_Parser.lua"
     fx_browser_reapack = 'sexan fx browser parser v6'

  end
  --local fx_browser_v6_path = reaper.GetResourcePath() .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_Parser.lua"
  --local fx_browser_v7_path = reaper.GetResourcePath() .. "/Scripts/Sexan_Scripts/FX/Sexan_FX_Browser_ParserV7.lua"
  
  local reapack_process
  local repos = {
    {name = "Sexan_Scripts", url = 'https://github.com/GoranKovac/ReaScripts/raw/master/index.xml'},
  }
  
  for i = 1, #repos do
    local retinfo, url, enabled, autoInstall = reaper.ReaPack_GetRepositoryInfo( repos[i].name )
    if not retinfo then
      retval, error = reaper.ReaPack_AddSetRepository( repos[i].name, repos[i].url, true, 0 )
      reapack_process = true
    end
  end
 
  -- ADD NEEDED REPOSITORIES
  if reapack_process then
    reaper.ShowMessageBox("Added Third-Party ReaPack Repositories", "ADDING REPACK REPOSITORIES", 0)
    reaper.ReaPack_ProcessQueue(true)
    reapack_process = nil
  end
  
  if not reapack_process then
    -- FX BROWSER
    if reaper.file_exists(fx_browser) then
        dofile(fx_browser)
        -- Check if Filter_actions was loaded, if not provide a fallback
        if not Filter_actions then
            -- Fallback Filter_actions function if external script doesn't provide it
            Filter_actions = function(filter_text)
                if not FX_LIST or #FX_LIST == 0 then return {} end
                if not filter_text or filter_text == '' then return FX_LIST end
                
                local filtered = {}
                local filter_lower = filter_text:lower()
                local filter_normalized = NormalizeHyphensAndSpaces(filter_lower)
                for _, fx_name in ipairs(FX_LIST) do
                    local fx_normalized = NormalizeHyphensAndSpaces(fx_name:lower())
                    if fx_normalized:find(filter_normalized, 1, true) then
                        table.insert(filtered, fx_name)
                    end
                end
                return filtered
            end
        end
    else
       reaper.ShowMessageBox("Sexan FX BROWSER is needed.\nPlease Install it in next window", "MISSING DEPENDENCIES", 0)
       reaper.ReaPack_BrowsePackages(fx_browser_reapack)
       return 'error Sexan FX BROWSER'
    end
  end
end


if ThirdPartyDeps() then return end


-- FX Category system - reads REAPER's native FX categories from reaper-fxtags.ini
FX_CATEGORIES = FX_CATEGORIES or {} -- {fx_name = {categories = {"EQ", "Dynamics"}, primary = "EQ"}}
FX_CATEGORIES_LOOKUP = FX_CATEGORIES_LOOKUP or {} -- {category_name = {fx_names...}}
FX_LIST_TO_CATEGORIES = FX_LIST_TO_CATEGORIES or {} -- Direct lookup: {fx_list_name = {categories, primary}}
FX_CATEGORY_SET = FX_CATEGORY_SET or {} -- Set of all category names for fast lookup
FX_Favorites = FX_Favorites or {} -- {fx_name = true/false} - tracks favorite FX plugins
FX_Favorites_Order = FX_Favorites_Order or {} -- Ordered array of favorite FX names for display order

-- Favorites file path
local function GetFavoritesFilePath()
    return r.GetResourcePath() .. '/Scripts/BRYAN\'s SCRIPTS/fx_favorites.txt'
end

-- Load favorites from file
local function LoadFXFavorites()
    FX_Favorites = {}
    FX_Favorites_Order = {}
    local file_path = GetFavoritesFilePath()
    local file = io.open(file_path, 'r')
    if file then
        for line in file:lines() do
            line = line:match("^%s*(.-)%s*$") -- Trim whitespace
            if line and line ~= '' then
                FX_Favorites[line] = true
                table.insert(FX_Favorites_Order, line) -- Preserve order from file
            end
        end
        file:close()
    end
end

-- Save favorites to file (preserving order)
local function SaveFXFavorites()
    -- Ensure FX_Favorites_Order exists
    if not FX_Favorites_Order then
        FX_Favorites_Order = {}
    end
    
    local file_path = GetFavoritesFilePath()
    local file = io.open(file_path, 'w')
    if file then
        -- Save in order from FX_Favorites_Order array
        for _, fx_name in ipairs(FX_Favorites_Order) do
            if FX_Favorites[fx_name] then
                file:write(fx_name .. '\n')
            end
        end
        -- Also save any favorites that might not be in the order array (backwards compatibility)
        for fx_name, is_favorite in pairs(FX_Favorites) do
            if is_favorite then
                -- Check if already saved
                local found = false
                for _, ordered_name in ipairs(FX_Favorites_Order) do
                    if ordered_name == fx_name then
                        found = true
                        break
                    end
                end
                if not found then
                    file:write(fx_name .. '\n')
                    table.insert(FX_Favorites_Order, fx_name) -- Add to order
                end
            end
        end
        file:close()
    end
end

-- Normalize FX name for matching (remove prefix, extension, lowercase)
local function NormalizeFXName(fx_name)
  if not fx_name then return '' end
  -- Remove prefix (VST3:, VST:, etc.)
  local base = fx_name:match('^[^:]+:(.+)$') or fx_name
  -- Remove extensions
  base = base:gsub('%.vst3$', ''):gsub('%.vst$', ''):gsub('%.dll$', ''):gsub('%.jsfx$', ''):gsub('%.au$', '')
  -- Get just the filename part (last component)
  base = base:match('([^/\\]+)$') or base
  return base:lower()
end

local function LoadFXCategories()
  local resource_path = r.GetResourcePath()
  local fxtags_path = resource_path .. "/reaper-fxtags.ini"
  
  -- Clear existing data (but preserve FX_LIST_TO_CATEGORIES if it was loaded from cache)
  FX_CATEGORIES = {}
  FX_CATEGORIES_LOOKUP = {}
  -- Don't clear FX_LIST_TO_CATEGORIES here - it might have been loaded from cache
  -- FX_LIST_TO_CATEGORIES will be rebuilt in BuildFXListCategoryLookup() if needed
  FX_CATEGORY_SET = {}
  
  local file = io.open(fxtags_path, 'r')
  if not file then
    return -- File doesn't exist or can't be read
  end
  
  local in_category_section = false
  for line in file:lines() do
    line = line:match('^%s*(.-)%s*$') -- trim whitespace
    
    -- Check if we're entering the [category] section
    if line == '[category]' then
      in_category_section = true
    elseif line:match('^%[') then
      -- Entered a different section
      in_category_section = false
    elseif in_category_section and line ~= '' and not line:match('^%s*;') then
      -- Parse category line: PluginName.vst3=Category1|Category2
      local fx_name, categories_str = line:match('^([^=]+)=(.+)$')
      if fx_name and categories_str then
        fx_name = fx_name:match('^%s*(.-)%s*$') -- trim
        categories_str = categories_str:match('^%s*(.-)%s*$') -- trim
        
        -- Normalize the FX name for matching
        local normalized_name = NormalizeFXName(fx_name)
        
        -- Split categories by pipe
        local categories = {}
        for cat in categories_str:gmatch('([^|]+)') do
          cat = cat:match('^%s*(.-)%s*$') -- trim each category
          if cat ~= '' then
            table.insert(categories, cat)
            -- Build reverse lookup
            FX_CATEGORIES_LOOKUP[cat] = FX_CATEGORIES_LOOKUP[cat] or {}
            table.insert(FX_CATEGORIES_LOOKUP[cat], fx_name)
            -- Build category set for fast lookup
            FX_CATEGORY_SET[cat:lower()] = true
          end
        end
        
        if #categories > 0 then
          FX_CATEGORIES[fx_name] = {
            categories = categories,
            primary = categories[1], -- First category is considered primary
            normalized = normalized_name -- Cache normalized name
          }
        end
      end
    end
  end
  
  file:close()
end

-- Get path for category cache file
local function GetCategoryCachePath()
  local resource_path = r.GetResourcePath()
  return resource_path .. "/Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/fx_category_cache.lua"
end

-- Save category cache to file
local function SaveCategoryCache()
  if not FX_LIST_TO_CATEGORIES or not next(FX_LIST_TO_CATEGORIES) then 
    return -- Nothing to save
  end
  
  local cache_path = GetCategoryCachePath()
  
  -- Ensure directory exists
  local dir_path = cache_path:match('^(.+)/[^/]+$')
  if dir_path then
    r.RecursiveCreateDirectory(dir_path, 0)
  end
  
  local file = io.open(cache_path, 'w')
  if not file then 
    return -- Failed to open file for writing
  end
  
  file:write('-- FX Category Cache\n')
  file:write('-- Auto-generated file - do not edit manually\n')
  file:write('-- Format: {fx_name = {categories = {...}, primary = "..."}}\n\n')
  file:write('return {\n')
  
  local count = 0
  local first = true
  for fx_name, cat_data in pairs(FX_LIST_TO_CATEGORIES) do
    if not first then file:write(',\n') end
    first = false
    count = count + 1
    
    -- Escape quotes and newlines in FX name
    local escaped_name = fx_name:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    file:write(('  ["%s"] = {'):format(escaped_name))
    file:write('\n    categories = {')
    
    local first_cat = true
    for _, cat in ipairs(cat_data.categories or {}) do
      if not first_cat then file:write(', ') end
      first_cat = false
      local escaped_cat = cat:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
      file:write(('"%s"'):format(escaped_cat))
    end
    
    file:write('},\n')
    local escaped_primary = (cat_data.primary or ''):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    file:write(('    primary = "%s"'):format(escaped_primary))
    file:write('\n  }')
  end
  
  file:write('\n}\n')
  file:close()
end

-- Load category cache from file
local function LoadCategoryCache()
  local cache_path = GetCategoryCachePath()
  
  -- Check if file exists
  local file_check = io.open(cache_path, 'r')
  if not file_check then
    -- File doesn't exist, that's okay - cache will be built on rescan
    return false
  end
  file_check:close()
  
  local chunk, err = loadfile(cache_path)
  if not chunk then
    -- Failed to load chunk
    return false
  end
  
  local success, cache_data = pcall(chunk)
  if not success then
    -- Error executing chunk
    return false
  end
  
  if type(cache_data) == 'table' and next(cache_data) then
    FX_LIST_TO_CATEGORIES = cache_data
    return true
  end
  
  return false
end

-- Get path for plugin counts file
local function GetPluginCountsPath()
  -- Try to get script directory first (for ReaPack compatibility)
  local script_path = debug.getinfo(1, "S").source
  if script_path and script_path:sub(1, 1) == "@" then
    script_path = script_path:sub(2) -- Remove the @ prefix
  end
  
  if script_path then
    local script_dir
    if script_path:match("^[/\\]") or script_path:match("^[A-Za-z]:[/\\]") then
      -- Absolute path
      script_dir = script_path:match("^(.+)[/\\][^/\\]+$")
    else
      -- Relative path
      script_path = r.GetResourcePath() .. "/" .. script_path
      script_dir = script_path:match("^(.+)[/\\][^/\\]+$")
    end
    
    if script_dir then
      -- Ensure trailing slash
      if not script_dir:match("[/\\]$") then
        script_dir = script_dir .. "/"
      end
      return script_dir .. "Vertical FX List Resources/plugin_select_counts.txt"
    end
  end
  
  -- Fallback to old path
  return r.GetResourcePath() .. "/Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/plugin_select_counts.txt"
end

-- Load plugin counts from file
local function LoadPluginCounts()
  SelectionCounts = SelectionCounts or {}
  local counts_path = GetPluginCountsPath()
  
  local file = io.open(counts_path, 'r')
  if not file then
    -- File doesn't exist, that's okay - start with empty counts
    return
  end
  
  for line in file:lines() do
    -- Format: PluginName\tCount
    local name, count = line:match("^(.+)\t(%d+)$")
    if name and count then
      SelectionCounts[name] = tonumber(count)
    end
  end
  
  file:close()
end

-- Save plugin counts to file
function SavePluginCounts()
  if not SelectionCounts or not next(SelectionCounts) then
    return -- Nothing to save
  end
  
  local counts_path = GetPluginCountsPath()
  
  -- Ensure directory exists
  local dir_path = counts_path:match('^(.+)/[^/]+$')
  if dir_path then
    r.RecursiveCreateDirectory(dir_path, 0)
  end
  
  local file = io.open(counts_path, 'w')
  if not file then
    return -- Failed to open file for writing
  end
  
  -- Sort by count (descending) then by name for consistent output
  local sorted = {}
  for name, count in pairs(SelectionCounts) do
    table.insert(sorted, {name = name, count = count})
  end
  table.sort(sorted, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.name < b.name
  end)
  
  -- Write each entry in format: PluginName\tCount
  for _, entry in ipairs(sorted) do
    file:write(entry.name .. "\t" .. tostring(entry.count) .. "\n")
  end
  
  file:close()
end

-- Build direct lookup from FX_LIST names to categories (called after FX_LIST is loaded)
local function BuildFXListCategoryLookup()
  if not FX_LIST or #FX_LIST == 0 then return end
  
  -- Only clear if we're rebuilding (not if cache was already loaded)
  -- Check if cache is empty or if we need to rebuild
  if not FX_LIST_TO_CATEGORIES or not next(FX_LIST_TO_CATEGORIES) then
    FX_LIST_TO_CATEGORIES = {}
  else
    -- Cache exists, but we might need to update it for new plugins
    -- For now, rebuild it completely to ensure accuracy
    FX_LIST_TO_CATEGORIES = {}
  end
  
  -- Build normalized name lookup for category file entries
  local category_normalized = {}
  for cat_fx_name, cat_data in pairs(FX_CATEGORIES) do
    local norm = cat_data.normalized or NormalizeFXName(cat_fx_name)
    if not category_normalized[norm] then
      category_normalized[norm] = {}
    end
    table.insert(category_normalized[norm], cat_data)
    -- Also store original name for exact matching
    category_normalized[cat_fx_name:lower()] = category_normalized[cat_fx_name:lower()] or {}
    table.insert(category_normalized[cat_fx_name:lower()], cat_data)
  end
  
  -- Match FX_LIST entries to categories
  for _, fx_list_name in ipairs(FX_LIST) do
    local normalized = NormalizeFXName(fx_list_name)
    local matched_cat = category_normalized[normalized]
    
    -- If no match found, try multiple matching strategies
    if not matched_cat then
      local name_without_prefix = fx_list_name:match('^[^:]+:(.+)$')
      if name_without_prefix then
        -- Strategy 1: Try exact match with name from FX_LIST (lowercase)
        matched_cat = category_normalized[name_without_prefix:lower()]
        
        -- Strategy 2: Try normalized version without prefix
        if not matched_cat then
          local normalized_no_prefix = NormalizeFXName(name_without_prefix)
          matched_cat = category_normalized[normalized_no_prefix]
        end
        
        -- Strategy 3: Try matching against all category entries (fuzzy match)
        if not matched_cat then
          for cat_fx_name, cat_data in pairs(FX_CATEGORIES) do
            local cat_normalized = cat_data.normalized or NormalizeFXName(cat_fx_name)
            -- Check if normalized names match exactly
            if normalized == cat_normalized then
              matched_cat = {cat_data}
              break
            end
            -- Check if one contains the other (for partial matches)
            if normalized ~= '' and cat_normalized ~= '' then
              if normalized:find(cat_normalized, 1, true) or cat_normalized:find(normalized, 1, true) then
                matched_cat = {cat_data}
                break
              end
            end
          end
        end
        
        -- Strategy 4: Try matching the base name (filename without extension) against category file entries
        if not matched_cat then
          local base_name = name_without_prefix:gsub('%.vst3$', ''):gsub('%.vst$', ''):gsub('%.dll$', ''):gsub('%.jsfx$', ''):gsub('%.au$', ''):lower()
          for cat_fx_name, cat_data in pairs(FX_CATEGORIES) do
            local cat_base = cat_fx_name:gsub('%.vst3$', ''):gsub('%.vst$', ''):gsub('%.dll$', ''):gsub('%.jsfx$', ''):gsub('%.au$', ''):lower()
            if base_name == cat_base or base_name:find(cat_base, 1, true) or cat_base:find(base_name, 1, true) then
              matched_cat = {cat_data}
              break
            end
          end
        end
      else
        -- No prefix, try direct matching
        for cat_fx_name, cat_data in pairs(FX_CATEGORIES) do
          local cat_normalized = cat_data.normalized or NormalizeFXName(cat_fx_name)
          if normalized == cat_normalized then
            matched_cat = {cat_data}
            break
          end
        end
      end
    end
    
    if matched_cat and matched_cat[1] then
      -- Use first match (most likely correct)
      FX_LIST_TO_CATEGORIES[fx_list_name] = matched_cat[1]
    end
  end
  
  -- Save cache to file after building
  SaveCategoryCache()
end

-- Load categories on initialization (before FX_LIST is loaded)
LoadFXCategories()

-- Initialize FX list from saved Sexan files if available (persists across restarts)
-- Try to load category cache from file on startup (fast)
do
  if type(ReadFXFile) == 'function' then
    local list, cat = ReadFXFile()
    if type(list) == 'table' and #list > 0 then
      FX_LIST = list
      CAT = cat or CAT
      -- Try to load category cache from file (fast, no rebuilding needed)
      LoadCategoryCache()
      -- Load plugin usage counts
      LoadPluginCounts()
    end
  end
end

-- Helper function to get FX categories (fast lookup from cache)
local function GetFXCategories(fx_name)
  if not fx_name or fx_name == '' then return nil end
  -- Direct lookup from pre-built cache
  return FX_LIST_TO_CATEGORIES[fx_name]
end

-- Helper function to remove text in parentheses from FX name (for strict filtering)
local function StripParentheses(fx_name)
  if not fx_name then return '' end
  -- Remove all content within parentheses (including nested parentheses)
  local result = fx_name:gsub('%s*%b()%s*', ' ')
  -- Clean up multiple spaces and trim
  result = result:gsub('%s+', ' '):match('^%s*(.-)%s*$')
  return result
end

-- Helper function to collect all FXs in a link group (traverses bidirectional links)
-- Returns a table mapping GUID -> true for all FXs in the group
function CollectLinkedFXs(startGUID)
  if not startGUID or not FX[startGUID] then
    return {} -- Return empty table if FX doesn't exist
  end
  if not FX[startGUID].Link then
    return {[startGUID] = true} -- Return just the starting FX if not linked
  end
  
  local linkedGroup = {}
  local visited = {}
  local toVisit = {startGUID}
  
  -- Breadth-first traversal to find all linked FXs
  while #toVisit > 0 do
    local currentGUID = table.remove(toVisit, 1)
    if not visited[currentGUID] then
      visited[currentGUID] = true
      linkedGroup[currentGUID] = true
      
      -- Check if this FX has a link
      if FX[currentGUID] and FX[currentGUID].Link then
        local linkedGUID = FX[currentGUID].Link
        if not visited[linkedGUID] then
          table.insert(toVisit, linkedGUID)
        end
      end
      
      -- Also check reverse links (FXs that link to this one)
      -- We need to scan all FXs to find ones that link to currentGUID
      for guid, fxData in pairs(FX) do
        if fxData and fxData.Link == currentGUID and not visited[guid] then
          table.insert(toVisit, guid)
        end
      end
    end
  end
  
  return linkedGroup
end

-- Enhanced filter function that supports category filtering (optimized)
local function FilterWithCategories(filter_text, base_filtered_list)
  if not filter_text or filter_text == '' then
    return base_filtered_list
  end
  
  local filter_lower = filter_text:lower()
  -- Normalize filter text: treat hyphens and spaces as equivalent
  local filter_normalized = NormalizeHyphensAndSpaces(filter_lower)
  local category_filter = nil
  
  -- Check for category: prefix or category keyword
  if filter_lower:match('^category:') then
    -- Explicit category filter: category:eq
    category_filter = filter_lower:match('^category:(.+)$')
    if category_filter then
      category_filter = category_filter:match('^%s*(.-)%s*$') -- trim
    end
  elseif filter_lower:match('^cat:') then
    -- Short form: cat:eq
    category_filter = filter_lower:match('^cat:(.+)$')
    if category_filter then
      category_filter = category_filter:match('^%s*(.-)%s*$') -- trim
    end
  end
  
  -- If we have a category filter, filter by category using cached lookup
  if category_filter and category_filter ~= '' then
    local filtered = {}
    -- Use direct lookup instead of nested loops
    for _, fx_name in ipairs(base_filtered_list) do
      local cat_data = FX_LIST_TO_CATEGORIES[fx_name]
      if cat_data then
        -- Check if any category matches the filter
        for _, cat in ipairs(cat_data.categories) do
          if cat:lower():find(category_filter, 1, true) then
            table.insert(filtered, fx_name)
            break
          end
        end
      end
    end
    return filtered
  end
  
  -- No explicit category filter, check if filter text matches any category name
  -- Use fast category set lookup first
  local is_category_match = false
  for cat_lower in pairs(FX_CATEGORY_SET) do
    if cat_lower:find(filter_lower, 1, true) then
      is_category_match = true
      break
    end
  end
  
  -- If filter matches a category, add category matches to results
  if is_category_match then
    local merged = {}
    local seen = {}
    
    -- Add base filtered items (but only if they match with parentheses stripped)
    for _, fx_name in ipairs(base_filtered_list) do
      if not seen[fx_name] then
        local fx_name_no_parens = StripParentheses(fx_name)
        local fx_normalized = NormalizeHyphensAndSpaces(fx_name_no_parens:lower())
        if fx_normalized:find(filter_normalized, 1, true) then
          table.insert(merged, fx_name)
          seen[fx_name] = true
        end
      end
    end
    
    -- Add FXs from matching categories using cached lookup
    for _, fx_name in ipairs(FX_LIST or {}) do
      if not seen[fx_name] then
        local cat_data = FX_LIST_TO_CATEGORIES[fx_name]
        if cat_data then
          for _, cat in ipairs(cat_data.categories) do
            if cat:lower():find(filter_lower, 1, true) then
              table.insert(merged, fx_name)
              seen[fx_name] = true
              break
            end
          end
        end
      end
    end
    
    return merged
  end
  
  -- No category matches - apply strict filtering (strip parentheses before matching)
  -- Filter base_filtered_list again with parentheses removed for stricter matching
  local filtered = {}
  for _, fx_name in ipairs(base_filtered_list) do
    local fx_name_no_parens = StripParentheses(fx_name)
    local fx_normalized = NormalizeHyphensAndSpaces(fx_name_no_parens:lower())
    if fx_normalized:find(filter_normalized, 1, true) then
      table.insert(filtered, fx_name)
    end
  end
  return filtered
end

-- Initialize PluginTypeOrder early so GetPluginTypePriority can use it
PluginTypeOrder = PluginTypeOrder or {"VST3", "VST", "AU", "CLAP", "JS"}

-- Helper function to get plugin type priority based on PluginTypeOrder
-- Returns a high number (low priority) for unknown types, lower numbers (higher priority) for known types
-- Must be defined before FilterBox uses it
local function GetPluginTypePriority(plugin_type)
    if not plugin_type or not PluginTypeOrder then return 999 end
    
    -- Map instrument types to their base types for priority comparison
    local base_type = plugin_type
    if plugin_type == 'VST3i' then base_type = 'VST3'
    elseif plugin_type == 'VSTi' then base_type = 'VST'
    elseif plugin_type == 'AUi' then base_type = 'AU'
    elseif plugin_type == 'CLAPi' then base_type = 'CLAP'
    elseif plugin_type == 'Container' then return 998 -- Container has very low priority
    end
    
    -- Find the index in PluginTypeOrder
    for i, type_name in ipairs(PluginTypeOrder) do
        if type_name == base_type then
            return i -- Lower number = higher priority
        end
    end
    
    -- Unknown type gets lowest priority
    return 999
end

function Lead_Trim_ws(s) return s:match '^%s*(.*)' end

function CheckIf_FX_Special(Track, fx)
  local rv, Name = r.TrackFX_GetFXName(Track, fx)
  if tablefind(SPECIAL_FX, Name) then
    return true 
  end
end





local function AutoFocus(ctx)
  FX_LIST_IS_FOCUSED = FX_LIST_IS_FOCUSED or nil
  if im.IsWindowHovered(ctx, im.HoveredFlags_AnyWindow) and  FX_LIST_IS_FOCUSED ~= true then 
    local fx_list_wnd  = r.JS_Window_Find("FX List", true)
    r.JS_Window_SetFocus(fx_list_wnd)
    FX_LIST_IS_FOCUSED = true
  elseif not im.IsWindowHovered(ctx, im.HoveredFlags_AnyWindow) and FX_LIST_IS_FOCUSED == true then 
    FX_LIST_IS_FOCUSED = nil 
  end
end


local function PanAllActivePans(ctx, PanningTracks, t ,ACTIVE_PAN_V , PanningTracks_INV)
  if im.IsMouseReleased(ctx, 0 ) then 
    Pan_Preset_Active = nil 
    ACTIVE_PAN_V = nil 
    -- Clear the global tables by removing all key-value pairs
    for k in pairs(PanningTracks) do PanningTracks[k] = nil end
    for k in pairs(PanningTracks_INV) do PanningTracks_INV[k] = nil end
    DisableFader = nil
    VERT_PAN_ACCUM = 0
    r.Undo_EndBlock( 'Adjust Pan', 100)
  end
  
  if Pan_Preset_Active ==   1 then
    -- distribute pans across all tracks in PanningTracks
    local trackIndices = {}
    for idx in pairs(PanningTracks) do trackIndices[#trackIndices+1] = idx end
    table.sort(trackIndices)
    local cnt = #trackIndices
    if cnt > 1 then
      local maxVal = math.abs(ACTIVE_PAN_V or 1)  -- Use absolute value for magnitude
      local baseSign = (ACTIVE_PAN_V or 1) >= 0 and 1 or -1  -- Preserve drag direction
      
      for i, idx in ipairs(trackIndices) do
        local tr = r.GetTrack(0, idx)
        if tr then
          -- Evenly distribute pans from -maxVal to +maxVal across all tracks
          -- For 4 tracks: -100, -50, 50, 100
          -- For 6 tracks: -100, -60, -20, 20, 60, 100
          local panVal
          if cnt == 1 then
            panVal = 0
          elseif cnt == 2 then
            -- Special case for 2 tracks: -maxVal and +maxVal
            panVal = (i == 1) and -maxVal or maxVal
          elseif cnt == 4 then
            -- Special case for 4 tracks: -100, -50, 50, 100
            -- Divide range into 4 equal segments: step = 200/4 = 50
            local step = (maxVal * 2) / 4
            if i <= 2 then
              panVal = -maxVal + (i - 1) * step
            else
              panVal = -maxVal + i * step
            end
          else
            -- Standard linear interpolation for all other cases
            -- Position from 0.0 (first) to 1.0 (last)
            local t = (i - 1) / (cnt - 1)  -- 0.0 to 1.0
            -- Map to -maxVal to +maxVal (linear cascade)
            panVal = -maxVal + t * (maxVal * 2)
          end
          
          -- Apply baseSign to preserve drag direction (works both ways)
          panVal = panVal * baseSign
          if PanningTracks_INV[idx]==idx then panVal = -panVal end
          
          -- Round to 2 decimal places to ensure exact symmetry and prevent display rounding issues
          panVal = math.floor(panVal * 100 + 0.5) / 100
          
          r.SetTrackUIPan(tr, panVal, false, false, 0)
        end
      end
    end
  elseif Pan_Preset_Active ==2 then
    -- Preset 2: Progressive panning pairs with diminishing range
    -- 6 tracks: +100, -100, +66, -66, +33, -33
    -- 8 tracks: +100, -100, +75, -75, +50, -50, +25, -25
    -- Works both ways (when dragging left or right)
    local trackIndices={} for idx in pairs(PanningTracks) do trackIndices[#trackIndices+1]=idx end
    table.sort(trackIndices)
    local cnt=#trackIndices
    if cnt>0 then
      local maxVal = math.abs(ACTIVE_PAN_V or 1)  -- Use absolute value for magnitude
      local baseSign = (ACTIVE_PAN_V or 1) >= 0 and 1 or -1  -- Preserve drag direction
      local numPairs = math.ceil(cnt / 2)  -- Number of pairs
      
      for i, idx in ipairs(trackIndices) do
        local tr = r.GetTrack(0, idx)
        if tr then
          local pairIndex = math.ceil(i / 2)  -- 1,1,2,2,3,3... (pair 1, pair 2, pair 3...)
          local isFirstInPair = (i % 2 == 1)  -- true for 1st, 3rd, 5th... (odd indices)
          
          -- Calculate magnitude: pair i gets (numPairs - i + 1) / numPairs of maxVal
          -- Pair 1: 100%, Pair 2: (n-1)/n%, Pair 3: (n-2)/n%, etc.
          local magnitude = maxVal * (numPairs - pairIndex + 1) / numPairs
          
          -- Alternate L/R within each pair: first track goes right, second goes left
          local sign = isFirstInPair and 1 or -1
          local panVal = baseSign * sign * magnitude
          
          -- Apply inversion if needed
          if PanningTracks_INV[idx]==idx then panVal = -panVal end
          
          r.SetTrackUIPan(tr, panVal, false, false, 0)
        end
      end
    end
  elseif Pan_Preset_Active ==3 then
    -- opposite directional panning in pairs (Preset 3)
    -- max pan magnitude determined by horizontal drag (ACTIVE_PAN_V)
    -- min magnitude estimated from vertical drag distance (approximated by number of selected tracks)
    local trackIndices = {}
    for idx in pairs(PanningTracks) do trackIndices[#trackIndices+1] = idx end
    table.sort(trackIndices)
    local cnt = #trackIndices
    if cnt > 0 then
      local maxVal = math.abs(ACTIVE_PAN_V or 1)
      -- vertical drag influence stored in VERT_PAN_ACCUM (pixels); map 0-300px → 0-maxVal
      local dragRatio = math.min(1, (VERT_PAN_ACCUM or 0) / 300)
      local minVal = maxVal * dragRatio
      local pairsCnt = math.ceil(cnt / 2)
      for i, idx in ipairs(trackIndices) do
        local tr = r.GetTrack(0, idx)
        if tr then
          local pairIdx = math.ceil(i / 2) -- 1,1,2,2,3,3...
          local magnitude
          if pairsCnt > 1 then
            magnitude = minVal + (pairIdx - 1) * (maxVal - minVal) / (pairsCnt - 1)
          else
            magnitude = maxVal
          end
          local sign = (i % 2 == 0) and -1 or 1 -- alternate L/R
          local panVal = sign * magnitude
          if PanningTracks_INV[idx] == idx then panVal = -panVal end
          r.SetTrackUIPan(tr, panVal, false, false, 0)
        end
      end
    end
  else 
    -- default behaviour: set all active tracks to ACTIVE_PAN_V
    for t = 0, TrackCount - 1, 1 do
      for i, v in pairs(PanningTracks) do 
        local pan = ACTIVE_PAN_V
        if PanningTracks_INV[i] == v then 
          pan = -pan
        end 
        local Track = r.GetTrack(0, v)
        r.SetTrackUIPan( Track, pan, false, false, 0) 
      end
    end
  end
  
end


local function PanFaderActivation(ctx)
  -- Guard against toggling while typing in any text field
  if (not TypingInTextField) and not im.IsAnyItemActive(ctx) and im.IsKeyPressed(ctx, im.Key_X) then 
    if MIX_MODE then MIX_MODE = false else MIX_MODE = true end
  end

  if Mods == Ctrl+ Alt then 
    MIX_MODE_Temp = true 
  else 
    MIX_MODE_Temp = nil
  end
end
function FX_Btn_Mouse_Interaction(rv,Track, fx,FX_Is_Open,FX_Is_Offline,ctx)
  -- Show X indicator when Alt is pressed and hovering over the button
  if im.IsItemHovered(ctx) and Mods == Alt then
    DrawXIndicator(ctx, 12, 0xFF0000FF) -- Red X with size 12
  end
  
  -- Marquee selection logic
  local trackGUID = r.GetTrackGUID(Track)
  local isSelected = IsFXSelected(trackGUID, fx)
  
  -- Set flag if we're interacting with a selected FX
  if isSelected and (im.IsItemHovered(ctx) or im.IsItemActive(ctx)) then
    InteractingWithSelectedFX = true
  end
  
  -- Check if this FX is within the marquee selection (only when in 'fx' mode)
  if MarqueeSelection.isActive and (MarqueeSelection.mode == 'fx') then
    -- Only check marquee selection for visible items to prevent selecting hidden FXs
    -- when tracks are collapsed/zoomed and coordinates overlap
    if im.IsItemVisible(ctx) then
      local itemMinX, itemMinY = im.GetItemRectMin(ctx)
      local itemW, itemH = im.GetItemRectSize(ctx)
      local itemMaxX = itemMinX + itemW
      local itemMaxY = itemMinY + itemH
      
      -- Extend X bounds to FX pane right edge when sends panel is hidden
      local sendsHidden = false
      if OPEN and OPEN.ShowSends == false then
        sendsHidden = true
      elseif PerTrackSendsHidden and PerTrackSendsHidden[trackGUID] then
        sendsHidden = true
      end
      
      if sendsHidden and Trk and Trk[trackGUID] then
        local fxChildLeftX = Trk[trackGUID].FxChildLeftX
        local fxChildW = Trk[trackGUID].FxChildW
        if fxChildLeftX and fxChildW then
          local fxPaneRightX = fxChildLeftX + fxChildW
          -- Extend itemMaxX to the right edge of the FX pane
          if fxPaneRightX > itemMaxX then
            itemMaxX = fxPaneRightX
          end
        end
      end
      
      -- For parallel groups, also consider X to select only the FX under the marquee's X span
      do
        local _, parStrCur = r.TrackFX_GetNamedConfigParm(Track, fx, 'parallel')
        local parValCur = tonumber(parStrCur or '0') or 0
        local inParallelGroup = parValCur > 0
        if not inParallelGroup then
          local fxCount = r.TrackFX_GetCount(Track) or 0
          if fx + 1 < fxCount then
            local _, parStrNext = r.TrackFX_GetNamedConfigParm(Track, fx + 1, 'parallel')
            local parValNext = tonumber(parStrNext or '0') or 0
            inParallelGroup = parValNext > 0
          end
        end

        if inParallelGroup then
          if IsRectIntersectingMarquee(itemMinX, itemMinY, itemMaxX, itemMaxY) then
            AddFXToSelection(trackGUID, fx)
          elseif not MarqueeSelection.additive then
            RemoveFXFromSelection(trackGUID, fx)
          end
        else
          -- Non-parallel: preserve existing Y-based selection behavior
          if ShouldSelectFXByYPosition(itemMinY, itemMaxY) then
            AddFXToSelection(trackGUID, fx)
          elseif not MarqueeSelection.additive then
            RemoveFXFromSelection(trackGUID, fx)
          end
        end
      end
    elseif not MarqueeSelection.additive then
      -- If item is not visible and not in additive mode, remove from selection
      RemoveFXFromSelection(trackGUID, fx)
    end
    
  end
  
  -- Ctrl+Shift left-click: toggle FX online/offline
  if rv and (Dur or 0) < 0.15 then
    local keyMods = im.GetKeyMods(ctx)
    local ctrlShift  = ((keyMods & Ctrl)  ~= 0) and ((keyMods & Shift) ~= 0)
    local superShift = ((keyMods & Super) ~= 0) and ((keyMods & Shift) ~= 0)
    if ctrlShift or superShift then
      r.TrackFX_SetOffline(Track, fx, not FX_Is_Offline)
      return
    end
  end

  -- If FX is offline and user clicked (simple click, no drag)
  if FX_Is_Offline and rv and (Dur or 0) < 0.15 then
    -- Bring the FX back online
    r.TrackFX_SetOffline(Track, fx, false)
    return -- do not process other interactions this click
  end

  -- Multi-selection drag is disabled; use single-item drag behavior only

  if rv and Dur < 0.15 then
    if Mods == 0 then
      if FX_Is_Open then
        r.TrackFX_Show(Track, fx, 2)
      else
        r.TrackFX_Show(Track, fx, 3)
      end
    elseif Mods == Alt then
      -- Trigger shrink delete animation instead of immediate delete
      local guid = r.TrackFX_GetFXGUID(Track, fx)
      if guid then
        FXDeleteAnim = FXDeleteAnim or {}
        if not FXDeleteAnim[guid] then
          FXDeleteAnim[guid] = { progress = 0, track = Track, index = fx }
        end
      else
        DeleteFX(fx, Track)
      end
      HoveredLinkedFXID = nil
    elseif Mods == Shift then
      -- If multiple FXs are selected, bypass all of them
      if MultiSelectionButtons.visible then
        BypassSelectedFXs()
      else
        ToggleBypassFX(Track, fx)
      end
    end
  end
  
  -- Fallback: if Alt is held and the button item was hovered on mouse release,
  -- trigger delete animation even if rv was false (e.g., special sub-controls)
  if Mods == Alt and im.IsItemHovered(ctx) and im.IsMouseReleased(ctx, 0) then
    local guid = r.TrackFX_GetFXGUID(Track, fx)
    if guid then
      FXDeleteAnim = FXDeleteAnim or {}
      if not FXDeleteAnim[guid] then
        FXDeleteAnim[guid] = { progress = 0, track = Track, index = fx }
      end
    else
      DeleteFX(fx, Track)
    end
    HoveredLinkedFXID = nil
  end
  
  local WDL =im.GetWindowDrawList(ctx)
  if FX_Is_Open then HighlightItem(Clr.GenericHighlightFill, WDL, Clr.GenericHighlightOutline) end
  
  -- Per-item selection border disabled; block highlight is drawn in FX Buttons

end


local function MonitorFXs(ctx, Top_Arrang)
  local Mas = r.GetMasterTrack(0)
  Top_Arrang = Top_Arrang or 0

  im.BeginChild(ctx, 'Montitor FXs', -1, Top_Arrang, nil, im.WindowFlags_NoScrollbar )
  local ct = r.TrackFX_GetCount(Mas)
  local cols = MonitorFX_Columns or 1
  if cols < 1 then cols = 1 end
  if cols > 6 then cols = 6 end

  -- Get the child window width at the start (before any items are drawn)
  local childWidth = im.GetContentRegionAvail(ctx)
  -- Calculate fixed button width based on columns
  local btnWidth = -1
  if cols > 1 then
    local spacing = 6 * (cols - 1)
    btnWidth = (childWidth - spacing) / cols
  end
  -- For single column, btnWidth stays -1 (full width)

  local fxCount = 0
  for  fx = 0 , 10 , 1 do 
    local fx = 0x1000000+fx
    local rv, name  = r.TrackFX_GetNamedConfigParm(Mas, fx, 'fx_name')
    local name = ChangeFX_Name(name)
    if rv then 
      -- Layout in columns: use SameLine for items after the first in each row
      if fxCount > 0 and (fxCount % cols) ~= 0 then
        im.SameLine(ctx, 0, 6)
      end
      
      im.SetNextItemWidth(ctx, btnWidth)

      -- Determine offline status for colour & interaction
      local FX_Offline = r.TrackFX_GetOffline(Mas, fx)
      
      -- Check if this FX is being renamed
      local monitorFXKey = 'MonitorFX_' .. tostring(fx)
      local isRenaming = Changing_FX_Name == monitorFXKey
      
      -- Apply same styling as regular FX buttons
      local rv_fxType, fxType = r.TrackFX_GetNamedConfigParm(Mas, fx, 'fx_type')
      if fxType == 'VST3i' or fxType =='VSTi' or fxType == 'AUi' then 
        local base = Clr.VSTi
        im.PushStyleColor(ctx, im.Col_Button, base)
        im.PushStyleColor(ctx, im.Col_ButtonActive,  deriveActive(base))
        im.PushStyleColor(ctx, im.Col_ButtonHovered,  deriveHover(base))
      else 
        local base = Clr.Buttons
        im.PushStyleColor(ctx, im.Col_Button, base)
        im.PushStyleColor(ctx, im.Col_ButtonActive,  deriveActive(base))
        im.PushStyleColor(ctx, im.Col_ButtonHovered,  deriveHover(base))
      end
      
      im.PushStyleColor(ctx, im.Col_Border, 0x00000000)
      im.PushStyleVar(ctx, im.StyleVar_FrameBorderSize, 1)

      -- Override with dark-red scheme for offline FX
      if FX_Offline then
        im.PushStyleColor(ctx, im.Col_Button,        0x551111ff)
        im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x771111ff)
        im.PushStyleColor(ctx, im.Col_ButtonActive,  0x991111ff)
        im.PushStyleColor(ctx, im.Col_Text,          0xdd4444ff)
      end

      -- Handle renaming input
      if isRenaming then
        im.PushStyleColor(ctx, im.Col_FrameBg, 0xffffff22)
        im.SetNextItemWidth(ctx, btnWidth)
        local retval, renamed = r.TrackFX_GetNamedConfigParm(Mas, fx, 'renamed_name')
        im.SetKeyboardFocusHere(ctx)
        local rv_input, Txt = im.InputText(ctx, '##MonitorFX_Rename' .. fx, Txt or renamed or name, im.InputTextFlags_EnterReturnsTrue)
        im.PopStyleColor(ctx) -- Pop FrameBg
        if rv_input then
          r.TrackFX_SetNamedConfigParm(Mas, fx, 'renamed_name', Txt)
          Txt = nil
          Changing_FX_Name = nil
        end
        -- Pop styles in reverse order (same as button branch)
        if FX_Offline then im.PopStyleColor(ctx, 4) end
        im.PopStyleVar(ctx, 1)
        im.PopStyleColor(ctx, 4) -- Border + 3 button colors
      else
        -- Get renamed name if exists - show renamed name instead of original
        local retval, renamed = r.TrackFX_GetNamedConfigParm(Mas, fx, 'renamed_name')
        local displayName = renamed ~= '' and renamed or name
        
        local rv = im.Button(ctx, displayName .. "##" .. fx, btnWidth)
        
        -- Handle Alt + Right-click for renaming
        if im.IsItemClicked(ctx, 1) then
          if Mods == Alt then
            Changing_FX_Name = monitorFXKey
          end
        end
        
        -- Pop styles in reverse order
        if FX_Offline then im.PopStyleColor(ctx, 4) end
        im.PopStyleVar(ctx, 1)
        im.PopStyleColor(ctx, 4) -- Border + 3 button colors
        
        -- Add dark overlay for bypassed FX (same as regular FX buttons)
        local FX_Enabled = r.TrackFX_GetEnabled(Mas, fx)
        if FX_Enabled == false then
          local L, T = im.GetItemRectMin(ctx)
          local R, B = im.GetItemRectMax(ctx)
          local WDL = im.GetWindowDrawList(ctx)
          im.DrawList_AddRectFilled(WDL, L, T, R, B, 0x000000aa)
        end
        
        FX_Btn_Mouse_Interaction(rv, Mas, fx, r.TrackFX_GetOpen(Mas, fx), FX_Offline, ctx)
      end
      
      fxCount = fxCount + 1
    end
  end
  im.EndChild(ctx)
  if im.IsWindowDocked( ctx) then
    w,  MonitorFX_Height = im.GetWindowSize( ctx)
  end 
  return MonitorFX_Height
end






function FilterBox(ctx,Track, FX_Idx, LyrID, SpaceIsBeforeRackMixer, FxGUID_Container, SpcIsInPre, SpcInPost, SpcIDinPost, showFavorites)
  ---@type integer|nil, boolean|nil
  local FX_Idx_For_AddFX, close, Inserted_FX_Pos
  -- Default showFavorites to true for backward compatibility
  if showFavorites == nil then showFavorites = true end
  im.PushFont(ctx,Font_Andale_Mono_13)
  if AddLastSPCinRack then FX_Idx_For_AddFX = FX_Idx - 1 end
  local MAX_FX_SIZE = 250
  
  -- Load favorites from file (only once per session)
  if not FX_Favorites_Loaded then
      FX_Favorites_Loaded = true
      LoadFXFavorites()
  end

  -- Helper function to parse FX name for filtering (defined early for use in favorites filtering)
  local function ParseFXForFilter(fx)
      local type = 'Unknown'
      local name = fx
      local manufacturer = ''
      
      if fx:find('VST3i:') then type = 'VST3i'; name = fx:sub(7)
      elseif fx:find('VSTi:') then type = 'VSTi'; name = fx:sub(6)
      elseif fx:find('AUi:') then type = 'AUi'; name = fx:sub(5)
      elseif fx:find('CLAPi:') then type = 'CLAPi'; name = fx:sub(7)
      elseif fx:find('VST:') then type = 'VST'; name = fx:sub(5)
      elseif fx:find('VST3:') then type = 'VST3'; name = fx:sub(6)
      elseif fx:find('JS:') then type = 'JS'; name = fx:sub(4)
      elseif fx:find('AU:') then type = 'AU'; name = fx:sub(4)
      elseif fx:find('CLAP:') then type = 'CLAP'; name = fx:sub(6)
      elseif fx == 'Container' then type = 'Container'; name = 'Container'
      end
      
      if type:find('VST') then
           local vst_ext = name:find('.vst')
           if vst_ext then name = name:sub(1, vst_ext-1) end
      end

      -- Extract manufacturer from parentheses
      -- Check if last parenthesis contains channel info (e.g., "32 out", "16 ch", "4-> 16 ch")
      -- If so, use second-to-last parenthesis for manufacturer
      local function isChannelInfo(text)
          -- Pattern to match channel information: numbers followed by "out", "ch", "in", or patterns like "4-> 16 ch"
          return text:match("^%d+%s*%-?>?%s*%d*%s*[choutin]+") ~= nil or
                 text:match("%d+%s*out") ~= nil or
                 text:match("%d+%s*ch") ~= nil or
                 text:match("%d+%s*in") ~= nil or
                 text:match("%->") ~= nil
      end
      
      -- Find all parentheses pairs
      local paren_pairs = {}
      local pos = 1
      while true do
          local open_pos = name:find("%(", pos)
          if not open_pos then break end
          local close_pos = name:find("%)", open_pos + 1)
          if not close_pos then break end
          table.insert(paren_pairs, {
              start = open_pos,
              stop = close_pos,
              content = name:sub(open_pos + 1, close_pos - 1)
          })
          pos = close_pos + 1
      end
      
      if #paren_pairs > 0 then
          local last_paren = paren_pairs[#paren_pairs]
          local manufacturer_paren = last_paren
          
          -- If last parenthesis contains channel info, use second-to-last if available
          if isChannelInfo(last_paren.content) and #paren_pairs > 1 then
              manufacturer_paren = paren_pairs[#paren_pairs - 1]
          end
          
          -- Extract manufacturer
          manufacturer = manufacturer_paren.content
          
          -- Remove manufacturer parenthesis from name
          name = name:sub(1, manufacturer_paren.start - 1) .. name:sub(manufacturer_paren.stop + 1)
          
          -- If we used second-to-last for manufacturer, also remove the channel info parenthesis
          if manufacturer_paren ~= last_paren then
              -- Recalculate last_paren position after removing manufacturer_paren
              local offset = manufacturer_paren.stop - manufacturer_paren.start + 1
              local adjusted_start = last_paren.start - offset
              local adjusted_stop = last_paren.stop - offset
              name = name:sub(1, adjusted_start - 1) .. name:sub(adjusted_stop + 1)
          end
          
          name = name:match("^%s*(.-)%s*$") -- Trim whitespace
      end
      
      return name, manufacturer, type
  end

  --local FxGUID = FXGUID[FX_Idx_For_AddFX or FX_Idx]
  im.SetNextItemWidth(ctx, 180)
  
  -- Always force keyboard focus to search field when popup is open (except in Send FX popup)
  if not im.IsMouseDown(ctx,0) and showFavorites then
      im.SetKeyboardFocusHere(ctx)
  end
  -- Set cursor color to bright cyan for better visibility
  im.PushStyleColor(ctx, r.ImGui_Col_InputTextCursor(), 0x00ffffff)
  _, ADDFX_FILTER = im.InputTextWithHint(ctx, '##input', "SEARCH FX", ADDFX_FILTER,
      im.InputTextFlags_AutoSelectAll)
  im.PopStyleColor(ctx, 1)
  
  -- Set default focus to ensure search field gets focus when popup opens (except in Send FX popup)
  if im.IsPopupOpen(ctx, "##popupp") and showFavorites then
      im.SetItemDefaultFocus(ctx)
  end
  -- Save search-box rectangle for drawing connection arrow from end-slot

  local l,t = im.GetItemRectMin(ctx)
  local R,b = im.GetItemRectMax(ctx)
  AddFX_SearchBoxRect = {L=l, T=t, R=R, B=b}

  local LT_Track = Track
  
  -- Define InsertFX function early so it can be used in favorites list
  local function InsertFX(Name)
    local FX_Idx = FX_Idx
    --- CLICK INSERT
    if SpaceIsBeforeRackMixer == 'End of PreFX' then FX_Idx = FX_Idx + 1 end

    SelectionCounts = SelectionCounts or {}
    -- When inserting at the end of chain, always use the actual track FX count
    -- This is critical when containers with nested FX are present, especially when uncollapsed
    -- r.TrackFX_GetCount returns the count of top-level FX slots (containers count as 1 slot)
    -- Nested FX inside containers are not counted in the top-level count
    -- Get fresh track FX count to avoid issues with modified global FX_Ct variable
    local trackFXCount = r.TrackFX_GetCount(LT_Track)
    local insertPosition
    
    -- When inserting at the end (FX_Idx >= trackFXCount), use -1 to append to end
    -- This ensures correct insertion position even when containers are uncollapsed and nested FX are visible
    -- Using -1 is more reliable than -1000 - count when containers are present
    if FX_Idx >= trackFXCount then
      insertPosition = -1  -- Append to end
    else
      insertPosition = -1000 - FX_Idx  -- Insert before FX at FX_Idx
    end
    
    local fx = r.TrackFX_AddByName(LT_Track, Name, false, insertPosition)
        -- update usage statistics
        SelectionCounts[Name] = (SelectionCounts[Name] or 0) + 1

    -- if Inserted into Layer
    local FxID = r.TrackFX_GetFXGUID(LT_Track, FX_Idx)
    SavePluginCounts()
    --[[ if FX.InLyr[FxGUID] == FXGUID_RackMixer and FX.InLyr[FxGUID] then
        DropFXtoLayerNoMove(FXGUID_RackMixer, LyrID, FX_Idx)
    end
    if SpaceIsBeforeRackMixer == 'SpcInBS' then
        DropFXintoBS(FxID, FxGUID_Container, FX[FxGUID_Container].Sel_Band, FX_Idx + 1, FX_Idx)
    end
    if SpcIsInPre then
        local inspos = FX_Idx + 1
        if SpaceIsBeforeRackMixer == 'End of PreFX' then
            table.insert(Trk[TrkID].PreFX, FxID)
        else
            table.insert(Trk[TrkID].PreFX, FX_Idx + 1, FxID)
        end
        for i, v in pairs(Trk[TrkID].PreFX) do
            r.GetSetMediaTrackInfo_String(LT_Track, 'P_EXT: PreFX ' .. i, v,
                true)
        end
    elseif SpcInPost then
        if r.TrackFX_AddByName(LT_Track, 'FXD Macros', 0, 0) == -1 then offset = -1 else offset = 0 end
        table.insert(Trk[TrkID].PostFX, SpcIDinPost + offset + 1, FxID)
        -- InsertToPost_Src = FX_Idx + offset+2
        for i = 1, #Trk[TrkID].PostFX + 1, 1 do
            r.GetSetMediaTrackInfo_String(LT_Track, 'P_EXT: PostFX ' .. i, Trk[TrkID].PostFX[i] or '', true)
        end
    end ]]


    ADDFX_FILTER = ''
    return fx 
  end

  -- Show favorites directly under search bar when enabled (always, filtered by query if present)
  local filter_text = ADDFX_FILTER or ''
  local has_search_query = filter_text ~= '' and filter_text
  local favorites_display_height = 0
  
  if ShowFavoritesUnderSearchBar and showFavorites then
      -- Collect all favorites in order (using FX_Favorites_Order)
      local all_favorites = {}
      -- First, ensure FX_Favorites_Order is up to date
      if not FX_Favorites_Order or #FX_Favorites_Order == 0 then
          -- Rebuild order from FX_Favorites hash
          FX_Favorites_Order = {}
          for fx_name, is_fav in pairs(FX_Favorites) do
              if is_fav then
                  table.insert(FX_Favorites_Order, fx_name)
              end
          end
      end
      
      -- Collect favorites in order, checking they exist in FX_LIST
      for _, fx_name in ipairs(FX_Favorites_Order) do
          if FX_Favorites[fx_name] then
              -- Check if this FX exists in FX_LIST
              for _, fx in ipairs(FX_LIST or {}) do
                  if fx == fx_name then
                      table.insert(all_favorites, fx_name)
                      break
                  end
              end
          end
      end
      
      -- Filter favorites based on query if present
      local filtered_favorites = {}
      if has_search_query and filter_text ~= '' then
          local filter_lower = filter_text:lower()
          for _, fav_fx in ipairs(all_favorites) do
              -- Parse FX name for matching
              local name, manufacturer, type = ParseFXForFilter(fav_fx)
              local search_text = (name .. ' ' .. (manufacturer or '') .. ' ' .. (type or '')):lower()
              if search_text:find(filter_lower, 1, true) then
                  table.insert(filtered_favorites, fav_fx)
              end
          end
      else
          -- No query, show all favorites
          filtered_favorites = all_favorites
      end
      
      if #filtered_favorites > 0 then
          -- Track which section is active for navigation
          FX_Search_Section = FX_Search_Section or 'favorites'
          
          -- Display favorites in a compact list under the search bar
          local fav_item_height = 24
          local header_height = 22
          local max_fav_items = 5 -- Show max 5 favorites
          local fav_items_to_show = math.min(#filtered_favorites, max_fav_items)
          favorites_display_height = header_height + fav_items_to_show * fav_item_height + 8
          
          -- Create a styled window/child for favorites
          im.SetNextWindowPos(ctx, l, b + 5)
          im.SetNextWindowSize(ctx, 200, favorites_display_height)
          
          -- Push styling for favorites panel
          im.PushStyleVar(ctx, im.StyleVar_ChildRounding, 4)
          im.PushStyleVar(ctx, im.StyleVar_WindowPadding, 4, 4)
          im.PushStyleColor(ctx, im.Col_ChildBg, 0x1A1A1AFF) -- Dark background
          im.PushStyleColor(ctx, im.Col_Border, 0x289F8177) -- Accent border color
          
          if im.BeginChild(ctx, '##favorites_list', 200, favorites_display_height, im.ChildFlags_Border, im.WindowFlags_NoScrollbar) then
              -- Header with title
              im.PushStyleColor(ctx, im.Col_Text, 0x289F81FF) -- Accent color for header
              im.PushFont(ctx, Font_Andale_Mono_13)
              if Img and Img.Star then
                  im.Image(ctx, Img.Star, 14, 14)
                  im.SameLine(ctx, nil, 4)
              end
              im.Text(ctx, 'Favorites')
              im.PopFont(ctx)
              im.PopStyleColor(ctx, 1)
              
              im.Separator(ctx)
              im.Spacing(ctx)
              
              for i = 1, fav_items_to_show do
                  local fav_fx = filtered_favorites[i]
                  if not fav_fx then break end
                  
                  -- Parse FX name (remove plugin type prefixes, including instrument types)
                  local display_name = fav_fx
                  
                  -- Remove plugin type prefixes (including instrument types like VST3i, VSTi, AUi, CLAPi)
                  if fav_fx:find('VST3i:') then 
                      display_name = fav_fx:sub(7)
                  elseif fav_fx:find('VST3:') then 
                      display_name = fav_fx:sub(6)
                  elseif fav_fx:find('VSTi:') then 
                      display_name = fav_fx:sub(6)
                  elseif fav_fx:find('VST:') then 
                      display_name = fav_fx:sub(5)
                  elseif fav_fx:find('AUi:') then 
                      display_name = fav_fx:sub(5)
                  elseif fav_fx:find('AU:') then 
                      display_name = fav_fx:sub(4)
                  elseif fav_fx:find('CLAPi:') then 
                      display_name = fav_fx:sub(7)
                  elseif fav_fx:find('CLAP:') then 
                      display_name = fav_fx:sub(6)
                  elseif fav_fx:find('JS:') then 
                      display_name = fav_fx:sub(4)
                  end
                  
                  -- Remove extension if present
                  display_name = display_name:gsub('%.vst3$', ''):gsub('%.vst$', ''):gsub('%.dll$', '')
                  
                  -- Apply name shortening if enabled
                  if OPEN and OPEN.ShortenFXNames and display_name and display_name ~= '' then
                      local s = display_name
                      s = s:gsub('%b()', ''):gsub('%b[]', ''):gsub('%b{}', '')
                      s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
                      display_name = s
                  end
                  
                  local is_selected = (FX_Search_Section == 'favorites' and (ADDFX_Sel_Entry or 1) == i)
                  
                  -- Style selected item
                  if is_selected then
                      im.PushStyleColor(ctx, im.Col_Header, 0x289F8144) -- Accent color with transparency
                      im.PushStyleColor(ctx, im.Col_HeaderHovered, 0x289F8177)
                      im.PushStyleColor(ctx, im.Col_HeaderActive, 0x289F81AA)
                  else
                      im.PushStyleColor(ctx, im.Col_Header, 0x00000000) -- Transparent
                      im.PushStyleColor(ctx, im.Col_HeaderHovered, 0x33333344)
                      im.PushStyleColor(ctx, im.Col_HeaderActive, 0x33333366)
                  end
                  
                  -- Create invisible selectable for hit testing (empty text, we draw custom content)
                  im.PushStyleVar(ctx, im.StyleVar_FramePadding, 4, 4)
                  im.PushStyleColor(ctx, im.Col_Text, 0x00000000) -- Make text invisible
                  
                  if im.Selectable(ctx, '##fav_item_' .. i, is_selected) then
                      Inserted_FX_Pos = InsertFX(fav_fx)
                      ADDFX_FILTER = ''
                      close = true
                  end
                  
                  -- Set up drag source (must be called after Selectable)
                  if im.BeginDragDropSource(ctx) then
                      im.SetDragDropPayload(ctx, 'FAVORITE_FX', fav_fx)
                      im.Text(ctx, display_name) -- Show name while dragging
                      im.EndDragDropSource(ctx)
                  end
                  
                  -- Set up drop target
                  if im.BeginDragDropTarget(ctx) then
                      local dropped, payload = im.AcceptDragDropPayload(ctx, 'FAVORITE_FX')
                      if dropped and payload then
                          local dragged_fx = tostring(payload) -- Ensure it's a string
                          local target_fx = tostring(fav_fx)  -- Ensure it's a string
                          
                          -- Ensure FX_Favorites_Order exists
                          if not FX_Favorites_Order then
                              FX_Favorites_Order = {}
                          end
                          
                          -- Find the index of the dragged item and target item in FX_Favorites_Order
                          local dragged_idx = nil
                          local target_idx = nil
                          for idx, fx in ipairs(FX_Favorites_Order) do
                              if tostring(fx) == dragged_fx then
                                  dragged_idx = idx
                              end
                              if tostring(fx) == target_fx then
                                  target_idx = idx
                              end
                              if dragged_idx and target_idx then break end
                          end
                          
                          -- Reorder if both indices found and different
                          if dragged_idx and target_idx and dragged_idx ~= target_idx then
                              -- Store the dragged item
                              local dragged_item = FX_Favorites_Order[dragged_idx]
                              
                              -- Remove from old position first
                              table.remove(FX_Favorites_Order, dragged_idx)
                              
                              -- Calculate insertion position
                              local insert_pos = target_idx
                              if dragged_idx < target_idx then
                                  -- Dragging down: target_idx stays the same (we removed before it)
                                  -- Insert at target_idx to place after the target
                                  insert_pos = target_idx
                              else
                                  -- Dragging up: target_idx stays the same (we removed after it)
                                  -- Insert at target_idx to place before the target
                                  insert_pos = target_idx
                              end
                              
                              -- Insert at calculated position
                              table.insert(FX_Favorites_Order, insert_pos, dragged_item)
                              
                              -- Save the new order
                              SaveFXFavorites()
                          end
                      end
                      im.EndDragDropTarget(ctx)
                  end
                  
                  im.PopStyleColor(ctx, 1) -- Pop text color
                  
                  -- Draw custom content on top
                  local item_min_x, item_min_y = im.GetItemRectMin(ctx)
                  
                  -- FX name with proper color (no star icon, no type badge)
                  im.SetCursorScreenPos(ctx, item_min_x + 4, item_min_y + (fav_item_height - im.GetTextLineHeight(ctx)) / 2)
                  im.PushFont(ctx, Font_Andale_Mono_10)
                  if is_selected then
                      im.PushStyleColor(ctx, im.Col_Text, 0xFFFFFFFF) -- Bright white for selected
                  else
                      im.PushStyleColor(ctx, im.Col_Text, 0xCCCCCCFF) -- Light gray for unselected
                  end
                  im.Text(ctx, display_name)
                  im.PopStyleColor(ctx, 1)
                  im.PopFont(ctx)
                  
                  im.PopStyleVar(ctx, 1)
                  im.PopStyleColor(ctx, 3)
                  
                  -- Handle keyboard navigation
                  if is_selected and im.IsKeyPressed(ctx, im.Key_Enter) then
                      Inserted_FX_Pos = InsertFX(fav_fx)
                      ADDFX_FILTER = ''
                      close = true
                  end
                  
                  im.Spacing(ctx)
              end
              
              if #filtered_favorites > max_fav_items then
                  im.Spacing(ctx)
                  im.PushStyleColor(ctx, im.Col_Text, 0x888888FF) -- Dim gray
                  im.Text(ctx, string.format('... and %d more', #filtered_favorites - max_fav_items))
                  im.PopStyleColor(ctx, 1)
              end
              
              im.EndChild(ctx)
          end
          
          im.PopStyleColor(ctx, 2)
          im.PopStyleVar(ctx, 2)
          
          -- Handle up/down arrow navigation in favorites
          if FX_Search_Section == 'favorites' then
              if im.IsKeyPressed(ctx, im.Key_UpArrow) then
                  ADDFX_Sel_Entry = ((ADDFX_Sel_Entry or 1) - 1)
                  ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry, 1, fav_items_to_show)
              elseif im.IsKeyPressed(ctx, im.Key_DownArrow) then
                  ADDFX_Sel_Entry = ((ADDFX_Sel_Entry or 1) + 1)
                  ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry, 1, fav_items_to_show)
              end
          end
          
          -- Handle left/right arrow to switch between favorites (under search bar) and popup results
          if ShowFavoritesUnderSearchBar and showFavorites then
              if im.IsKeyPressed(ctx, im.Key_LeftArrow) then
                  -- Switch to favorites section (under search bar)
                  FX_Search_Section = 'favorites'
                  ADDFX_Sel_Entry = 1
                  -- Clear any selection in regular results by ensuring we're not in regular section
              elseif im.IsKeyPressed(ctx, im.Key_RightArrow) and has_search_query then
                  -- Switch to popup results (only if popup is open)
                  FX_Search_Section = 'regular'
                  -- Set initial selection in regular results
                  if match_row_start and match_row_start > 0 then
                      ADDFX_Sel_Entry = match_row_start + 1
                  else
                      ADDFX_Sel_Entry = 1
                  end
              end
          end
      end
  end

  -- Draw connection arrow from end-of-chain highlight to this search box (foreground layer)
  if EndFXSlot_Rect then
    local LineHeight = im.GetTextLineHeight(ctx)
    local srcX = (EndFXSlot_Rect.L + EndFXSlot_Rect.R) * 0.5
    local srcY = EndFXSlot_Rect.T + LineHeight/2
    local dstX = (l + R) * 0.5 - 180/2
    local dstY = (t + b) * 0.5

    if srcX < dstX then
      im.DrawList_AddLine(FDL, srcX, srcY, srcX, dstY, Clr.PatchLine) -- vertical line
      im.DrawList_AddLine(FDL, srcX, dstY, dstX, dstY, Clr.PatchLine) -- horizontal line
    else 
      im.DrawList_AddLine(FDL, srcX, srcY, srcX, dstY-15, Clr.PatchLine)
    end
  end

  if im.IsWindowAppearing(ctx) and showFavorites then
      local tb = FX_LIST
      im.SetKeyboardFocusHere(ctx, -1)
      
  end
  local LT_Track = Track
  -- Active filters for category and manufacturer (persist during search session)
  FX_Search_ActiveFilters = FX_Search_ActiveFilters or {category = nil, manufacturer = nil}
  
  -- Extract category filter if present, and get base filter text
  local filter_text = ADDFX_FILTER or ''
  local category_filter = FX_Search_ActiveFilters.category
  local manufacturer_filter = FX_Search_ActiveFilters.manufacturer
  local base_filter_text = filter_text
  
  if filter_text ~= '' then
    local filter_lower = filter_text:lower()
    if filter_lower:match('^category:') then
      category_filter = filter_lower:match('^category:(.+)$')
      if category_filter then
        category_filter = category_filter:match('^%s*(.-)%s*$') -- trim
        base_filter_text = '' -- Clear base filter when using category: prefix
      end
    elseif filter_lower:match('^cat:') then
      category_filter = filter_lower:match('^cat:(.+)$')
      if category_filter then
        category_filter = category_filter:match('^%s*(.-)%s*$') -- trim
        base_filter_text = '' -- Clear base filter when using cat: prefix
      end
    end
  end
  
  local base_filtered_fx = Filter_actions(base_filter_text)
  -- Apply category filtering on top of base filter
  local filtered_fx = FilterWithCategories(filter_text, base_filtered_fx)
  
  -- Apply active filters (category/manufacturer) if set
  if category_filter or manufacturer_filter then
      -- When active filters are set, use all available FX (FX_LIST) as the base
      -- instead of filtered_fx, so all matching results are shown even if search query is empty
      local source_list = (filter_text == '' or filter_text == nil) and (FX_LIST or {}) or filtered_fx
      
      local filtered_by_active = {}
      for _, fx_name in ipairs(source_list) do
          local name, manufacturer, type = ParseFXForFilter(fx_name)
          local fx_categories = GetFXCategories(fx_name)
          local category = (fx_categories and fx_categories.primary) or ""
          
          local matches = true
          if category_filter and category:lower():find(category_filter:lower(), 1, true) == nil then
              matches = false
          end
          if manufacturer_filter and manufacturer:lower():find(manufacturer_filter:lower(), 1, true) == nil then
              matches = false
          end
          
          if matches then
              table.insert(filtered_by_active, fx_name)
          end
      end
      filtered_fx = filtered_by_active
  end
  --im.SetNextWindowPos(ctx, im.GetItemRectMin(ctx), ({ im.GetItemRectMax(ctx) })[2])
  local filter_h = #filtered_fx == 0 and 2 or (#filtered_fx > 40 and 20 * 17 or (17 * #filtered_fx))
  -- Show popup if there's a search query OR if there are active filters
  -- Check FX_Search_ActiveFilters directly to get the most current state
  local has_search_query = ADDFX_FILTER ~= '' and ADDFX_FILTER
  local has_active_filters = (FX_Search_ActiveFilters.category or FX_Search_ActiveFilters.manufacturer)
  -- Only show popup when there's a query or active filters (not when just showing favorites under search bar)
  if has_search_query or has_active_filters then
      VP = VP or {}
      CustomColorsDefault = CustomColorsDefault or {}
      SL()
      --[[ im.SetNextWindowSize(ctx, MAX_FX_SIZE, filter_h + 20) ]]
      local x, y = im.GetCursorScreenPos(ctx)

      ParentWinPos_x, ParentWinPos_y = im.GetWindowPos(ctx)
      --[[ local VP_R = VP.X + VP.w
      if x + MAX_FX_SIZE > VP_R then x = ParentWinPos_x - MAX_FX_SIZE end ]]

      -- Store and maintain window size and position to prevent resizing when filters change
      FX_Search_WindowSize = FX_Search_WindowSize or {w = 528, h = 400}
      
      -- Check if popup was already opened before (to determine if we should use stored position)
      local popup_was_open = (FX_Search_WindowPos ~= nil)
      
      if not popup_was_open then
          -- First time opening - use calculated position
          FX_Search_WindowPos = {x = x, y = y - filter_h / 2}
      end
      
      -- Always use stored position and size to prevent resizing
      im.SetNextWindowPos(ctx, FX_Search_WindowPos.x, FX_Search_WindowPos.y)
      -- Always set window size (not just first use) to maintain size when filters change
      im.SetNextWindowSize(ctx, FX_Search_WindowSize.w, FX_Search_WindowSize.h)
      -- Constrain popup to maximum size 528 x 600
      if im.SetNextWindowSizeConstraints then im.SetNextWindowSizeConstraints(ctx, 200, 200, 528, 600) end
      im.PushStyleVar(ctx, im.StyleVar_WindowPadding, 5, 10)
      -- Make window resizable by removing AlwaysAutoResize flag
      if im.BeginPopup(ctx, "##popupp", im.WindowFlags_NoFocusOnAppearing) then
          -- When popup opens, ensure we're in regular section (not favorites)
          if ShowFavoritesUnderSearchBar and showFavorites then
              FX_Search_Section = 'regular'
          end
          -- Update stored window size if user resized it
          local current_w, current_h = im.GetWindowSize(ctx)
          if current_w and current_h then
              FX_Search_WindowSize.w = current_w
              FX_Search_WindowSize.h = current_h
          end
          
          -- When ShowFavoritesUnderSearchBar is enabled, exclude favorites from popup
          -- (favorites are shown in the favorites list under the search bar)
          local filtered_regular = {}
          local regular_count = 0
          
          -- Track which section is active (favorites or regular) for left/right arrow navigation
          FX_Search_Section = FX_Search_Section or 'regular' -- 'favorites' or 'regular'
          
          if ShowFavoritesUnderSearchBar and showFavorites then
              -- Only show non-favorite results in popup
              for _, fx in ipairs(filtered_fx) do
                  if not FX_Favorites[fx] or not FX_Favorites[fx] then
                      table.insert(filtered_regular, fx)
                  end
              end
              regular_count = #filtered_regular
              ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry or 1, 1, regular_count)
          else
              -- Feature disabled - use original behavior
              filtered_regular = filtered_fx
              regular_count = #filtered_fx
              ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry or 1, 1, #filtered_fx)
          end
          
          local function ParseFX(fx)
              local type = 'Unknown'
              local name = fx
              local manufacturer = ''
              
              if fx:find('VST3i:') then type = 'VST3i'; name = fx:sub(7)
              elseif fx:find('VSTi:') then type = 'VSTi'; name = fx:sub(6)
              elseif fx:find('AUi:') then type = 'AUi'; name = fx:sub(5)
              elseif fx:find('CLAPi:') then type = 'CLAPi'; name = fx:sub(7)
              elseif fx:find('VST:') then type = 'VST'; name = fx:sub(5)
              elseif fx:find('VST3:') then type = 'VST3'; name = fx:sub(6)
              elseif fx:find('JS:') then type = 'JS'; name = fx:sub(4)
              elseif fx:find('AU:') then type = 'AU'; name = fx:sub(4)
              elseif fx:find('CLAP:') then type = 'CLAP'; name = fx:sub(6)
              elseif fx == 'Container' then type = 'Container'; name = 'Container'
              end
              
              if type:find('VST') then
                   local vst_ext = name:find('.vst')
                   if vst_ext then name = name:sub(1, vst_ext-1) end
              end

              -- Extract manufacturer from parentheses
              -- Check if last parenthesis contains channel info (e.g., "32 out", "16 ch", "4-> 16 ch")
              -- If so, use second-to-last parenthesis for manufacturer
              local function isChannelInfo(text)
                  -- Pattern to match channel information: numbers followed by "out", "ch", "in", or patterns like "4-> 16 ch"
                  return text:match("^%d+%s*%-?>?%s*%d*%s*[choutin]+") ~= nil or
                         text:match("%d+%s*out") ~= nil or
                         text:match("%d+%s*ch") ~= nil or
                         text:match("%d+%s*in") ~= nil or
                         text:match("%->") ~= nil
              end
              
              -- Find all parentheses pairs
              local paren_pairs = {}
              local pos = 1
              while true do
                  local open_pos = name:find("%(", pos)
                  if not open_pos then break end
                  local close_pos = name:find("%)", open_pos + 1)
                  if not close_pos then break end
                  table.insert(paren_pairs, {
                      start = open_pos,
                      stop = close_pos,
                      content = name:sub(open_pos + 1, close_pos - 1)
                  })
                  pos = close_pos + 1
              end
              
              if #paren_pairs > 0 then
                  local last_paren = paren_pairs[#paren_pairs]
                  local manufacturer_paren = last_paren
                  
                  -- If last parenthesis contains channel info, use second-to-last if available
                  if isChannelInfo(last_paren.content) and #paren_pairs > 1 then
                      manufacturer_paren = paren_pairs[#paren_pairs - 1]
                  end
                  
                  -- Extract manufacturer
                  manufacturer = manufacturer_paren.content
                  
                  -- Remove manufacturer parenthesis from name
                  name = name:sub(1, manufacturer_paren.start - 1) .. name:sub(manufacturer_paren.stop + 1)
                  
                  -- If we used second-to-last for manufacturer, also remove the channel info parenthesis
                  if manufacturer_paren ~= last_paren then
                      -- Recalculate last_paren position after removing manufacturer_paren
                      local offset = manufacturer_paren.stop - manufacturer_paren.start + 1
                      local adjusted_start = last_paren.start - offset
                      local adjusted_stop = last_paren.stop - offset
                      name = name:sub(1, adjusted_start - 1) .. name:sub(adjusted_stop + 1)
                  end
                  
                  name = name:match("^%s*(.-)%s*$") -- Trim whitespace
              end
              
              return name, manufacturer, type
          end

          -- Use regular results only (favorites are shown in favorites list under search bar)
          local combined_fx_list = filtered_regular
          
          -- Cache parsed FX data for performance (only rebuild when filter changes)
          -- Create a stable hash based on filter text and FX count
          -- Use a sorted list of raw_fx strings to create a stable key regardless of order
          local cache_key = filter_text .. '|' .. #combined_fx_list
          if #combined_fx_list > 0 then
              -- Create sorted copy of FX names for stable key
              local fx_names = {}
              for i = 1, #combined_fx_list do
                  table.insert(fx_names, combined_fx_list[i])
              end
              table.sort(fx_names)
              -- Use first and last few to create key (faster than all)
              local key_parts = {}
              for i = 1, math.min(5, #fx_names) do
                  table.insert(key_parts, fx_names[i])
              end
              if #fx_names > 5 then
                  for i = math.max(6, #fx_names - 4), #fx_names do
                      table.insert(key_parts, fx_names[i])
                  end
              end
              cache_key = cache_key .. '|' .. table.concat(key_parts, '|')
          end
          
          if not FX_Search_Cache or FX_Search_Cache.cache_key ~= cache_key then
              FX_Search_Cache = {
                  cache_key = cache_key,
                  filter_hash = filter_text,
                  count = #combined_fx_list,
                  items = {}
              }
              
              -- Parse and cache all FX data (favorites first, then regular)
              for i = 1, #combined_fx_list do
                  local raw_fx = combined_fx_list[i]
                  local name, manufacturer, type = ParseFX(raw_fx)
                  local fx_categories = GetFXCategories(raw_fx)
                  local category = (fx_categories and fx_categories.primary) or ""
                  
                  -- Pre-compute color lookup
                  local clr = 0xFFFFFFFF
                  if type == 'VST3i' then clr = FX_Adder_VST3i or CustomColorsDefault.FX_Adder_VST3i
                  elseif type == 'VSTi' then clr = FX_Adder_VSTi or CustomColorsDefault.FX_Adder_VSTi
                  elseif type == 'AUi' then clr = FX_Adder_AUi or CustomColorsDefault.FX_Adder_AUi
                  elseif type == 'CLAPi' then clr = FX_Adder_CLAPi or CustomColorsDefault.FX_Adder_CLAPi
                  elseif type == 'VST' then clr = FX_Adder_VST or CustomColorsDefault.FX_Adder_VST
                  elseif type == 'VST3' then clr = FX_Adder_VST3 or CustomColorsDefault.FX_Adder_VST3
                  elseif type == 'JS' then clr = FX_Adder_JS or CustomColorsDefault.FX_Adder_JS
                  elseif type == 'AU' then clr = FX_Adder_AU or CustomColorsDefault.FX_Adder_AU
                  elseif type == 'CLAP' then clr = FX_Adder_CLAP or CustomColorsDefault.FX_Adder_CLAP
                  end
                  
                  local is_fav = FX_Favorites[raw_fx] == true
                  FX_Search_Cache.items[i] = {
                      raw_fx = raw_fx,
                      name = name,
                      manufacturer = manufacturer,
                      type = type,
                      category = category,
                      color = clr,
                      is_favorite = is_fav
                  }
              end
          end

          -- Collect unique categories and manufacturers for search matching (before table)
          local unique_categories = {}
          local unique_manufacturers = {}
          local category_set = {}
          local manufacturer_set = {}
          
          if FX_Search_Cache and FX_Search_Cache.items then
              for _, item in ipairs(FX_Search_Cache.items) do
                  if item.category and item.category ~= '' and not category_set[item.category] then
                      category_set[item.category] = true
                      table.insert(unique_categories, item.category)
                  end
                  if item.manufacturer and item.manufacturer ~= '' and not manufacturer_set[item.manufacturer] then
                      manufacturer_set[item.manufacturer] = true
                      table.insert(unique_manufacturers, item.manufacturer)
                  end
              end
          end
          
          -- Find matching categories and manufacturers (require at least 2 characters)
          local matching_categories = {}
          local matching_manufacturers = {}
          local filter_lower = filter_text:lower()
          
          if filter_text ~= '' and #filter_text >= 2 then
              for _, cat in ipairs(unique_categories) do
                  if cat:lower():find(filter_lower, 1, true) then
                      table.insert(matching_categories, cat)
                  end
              end
              for _, mfr in ipairs(unique_manufacturers) do
                  if mfr:lower():find(filter_lower, 1, true) then
                      table.insert(matching_manufacturers, mfr)
                  end
              end
          end
          
          -- Calculate match_row_start (accessible outside table)
          -- Active filters are now badges above table, so they don't count as rows
          local match_row_start = #matching_categories + #matching_manufacturers
          
          -- Adjust ADDFX_Sel_Entry based on match_row_start
          -- (Favorites are handled separately in favorites list under search bar)
          local max_entries = match_row_start + (FX_Search_Cache and #FX_Search_Cache.items or 0)
          ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry or 1, 1, max_entries)
          
          -- Display active filters as badges above the table header
          if category_filter or manufacturer_filter then
              im.PushStyleVar(ctx, im.StyleVar_ItemSpacing, 4, 4)
              im.PushStyleVar(ctx, im.StyleVar_FramePadding, 6, 4)
              im.PushStyleVar(ctx, im.StyleVar_FrameBorderSize, 1.0)
              
              if category_filter then
                  -- Dim background with brighter outline
                  local bg_color = 0x22AA8855 -- Dim green background
                  local outline_color = 0x66CCAAFF -- Brighter green outline
                  local hover_bg = 0x33BB9977 -- Slightly brighter on hover
                  local hover_outline = 0x88DDCCFF -- Even brighter outline on hover
                  
                  im.PushStyleColor(ctx, im.Col_Button, bg_color)
                  im.PushStyleColor(ctx, im.Col_ButtonHovered, hover_bg)
                  im.PushStyleColor(ctx, im.Col_ButtonActive, hover_bg)
                  im.PushStyleColor(ctx, im.Col_Border, outline_color)
                  im.PushStyleColor(ctx, im.Col_Text, 0xFFFFFFFF) -- White text
                  
                  -- Make the whole badge clickable
                  im.PushID(ctx, "cat_badge_" .. category_filter)
                  
                  -- Create button with icon and text using SameLine
                  im.BeginGroup(ctx)
                  if Img and Img.Search then
                      im.Image(ctx, Img.Search, 14, 14)
                      im.SameLine(ctx, nil, 4)
                  end
                  im.Text(ctx, "Category: " .. category_filter)
                  im.EndGroup(ctx)
                  
                  -- Get group bounds and create invisible button covering it
                  local group_min_x, group_min_y = im.GetItemRectMin(ctx)
                  local group_max_x, group_max_y = im.GetItemRectMax(ctx)
                  
                  -- Create invisible button with padding
                  im.SetCursorScreenPos(ctx, group_min_x - 6, group_min_y - 4)
                  if im.InvisibleButton(ctx, "##cat_btn", group_max_x - group_min_x + 12, group_max_y - group_min_y + 8) then
                      FX_Search_ActiveFilters.category = nil
                  end
                  
                  -- Draw border and background after button
                  local dl = im.GetWindowDrawList(ctx)
                  local is_hovered = im.IsItemHovered(ctx)
                  local current_outline = is_hovered and hover_outline or outline_color
                  local current_bg = is_hovered and hover_bg or bg_color
                  local border_thickness = is_hovered and 2.0 or 1.0
                  
                  local badge_min_x = group_min_x - 6
                  local badge_min_y = group_min_y - 4
                  local badge_max_x = group_max_x + 6
                  local badge_max_y = group_max_y + 4
                  
                  -- Draw background rectangle
                  im.DrawList_AddRectFilled(dl, badge_min_x, badge_min_y, badge_max_x, badge_max_y, current_bg)
                  
                  -- Draw border rectangle (brighter and thicker on hover)
                  im.DrawList_AddRect(dl, badge_min_x, badge_min_y, badge_max_x, badge_max_y, current_outline, 0, 0, border_thickness)
                  
                  -- Redraw content on top of background
                  im.SetCursorScreenPos(ctx, group_min_x, group_min_y)
                  im.BeginGroup(ctx)
                  if Img and Img.Search then
                      im.Image(ctx, Img.Search, 14, 14)
                      im.SameLine(ctx, nil, 4)
                  end
                  im.Text(ctx, "Category: " .. category_filter)
                  im.EndGroup(ctx)
                  
                  im.PopID(ctx)
                  
                  im.PopStyleColor(ctx, 5)
                  im.SameLine(ctx, nil, 8)
              end
              
              if manufacturer_filter then
                  -- Dim background with brighter outline
                  local bg_color = 0x2288AA55 -- Dim blue background
                  local outline_color = 0x66AACCFF -- Brighter blue outline
                  local hover_bg = 0x3399BB77 -- Slightly brighter on hover
                  local hover_outline = 0x88CCDDFF -- Even brighter outline on hover
                  
                  im.PushStyleColor(ctx, im.Col_Button, bg_color)
                  im.PushStyleColor(ctx, im.Col_ButtonHovered, hover_bg)
                  im.PushStyleColor(ctx, im.Col_ButtonActive, hover_bg)
                  im.PushStyleColor(ctx, im.Col_Border, outline_color)
                  im.PushStyleColor(ctx, im.Col_Text, 0xFFFFFFFF) -- White text
                  
                  -- Make the whole badge clickable
                  im.PushID(ctx, "mfr_badge_" .. manufacturer_filter)
                  
                  -- Create button with icon and text using SameLine
                  im.BeginGroup(ctx)
                  if Img and Img.Search then
                      im.Image(ctx, Img.Search, 14, 14)
                      im.SameLine(ctx, nil, 4)
                  end
                  im.Text(ctx, "Manufacturer: " .. manufacturer_filter)
                  im.EndGroup(ctx)
                  
                  -- Get group bounds and create invisible button covering it
                  local group_min_x, group_min_y = im.GetItemRectMin(ctx)
                  local group_max_x, group_max_y = im.GetItemRectMax(ctx)
                  
                  -- Create invisible button with padding
                  im.SetCursorScreenPos(ctx, group_min_x - 6, group_min_y - 4)
                  if im.InvisibleButton(ctx, "##mfr_btn", group_max_x - group_min_x + 12, group_max_y - group_min_y + 8) then
                      FX_Search_ActiveFilters.manufacturer = nil
                  end
                  
                  -- Draw border and background after button
                  local dl = im.GetWindowDrawList(ctx)
                  local is_hovered = im.IsItemHovered(ctx)
                  local current_outline = is_hovered and hover_outline or outline_color
                  local current_bg = is_hovered and hover_bg or bg_color
                  local border_thickness = is_hovered and 2.0 or 1.0
                  
                  local badge_min_x = group_min_x - 6
                  local badge_min_y = group_min_y - 4
                  local badge_max_x = group_max_x + 6
                  local badge_max_y = group_max_y + 4
                  
                  -- Draw background rectangle
                  im.DrawList_AddRectFilled(dl, badge_min_x, badge_min_y, badge_max_x, badge_max_y, current_bg)
                  
                  -- Draw border rectangle (brighter and thicker on hover)
                  im.DrawList_AddRect(dl, badge_min_x, badge_min_y, badge_max_x, badge_max_y, current_outline, 0, 0, border_thickness)
                  
                  -- Redraw content on top of background
                  im.SetCursorScreenPos(ctx, group_min_x, group_min_y)
                  im.BeginGroup(ctx)
                  if Img and Img.Search then
                      im.Image(ctx, Img.Search, 14, 14)
                      im.SameLine(ctx, nil, 4)
                  end
                  im.Text(ctx, "Manufacturer: " .. manufacturer_filter)
                  im.EndGroup(ctx)
                  
                  im.PopID(ctx)
                  
                  im.PopStyleColor(ctx, 5)
              end
              
              im.PopStyleVar(ctx, 3)
              im.NewLine(ctx)
          end
          
          -- Table with 5 columns: Favorites, Plugin Name, Manufacturer, Category, Type
          -- Use SizingFixedFit to prevent auto-fitting to content and respect init_width weights
          if im.BeginTable(ctx, '##search_table', 5, im.TableFlags_Resizable | im.TableFlags_SizingFixedFit | im.TableFlags_Sortable | im.TableFlags_ScrollY) then
              -- Set column widths: Favorites (small icon), Plugin Name 40%, Manufacturer 25%, Category 25%, Type 10%
              -- Using init_width for proportional sizing - these are weight values
              -- Favorites column: small fixed width (30px) - not sortable
              im.TableSetupColumn(ctx, ' ', 0, 0, 10)
              -- Plugin Name: 40% of remaining width (use WidthStretch with init_width as weight) - sortable
              im.TableSetupColumn(ctx, 'Plugin Name', im.TableColumnFlags_WidthStretch, 40, 40.0)
              -- Manufacturer: 25% of remaining width - sortable
              im.TableSetupColumn(ctx, 'Manufacturer', im.TableColumnFlags_WidthStretch, 25, 25.0)
              -- Category: 25% of remaining width - sortable
              im.TableSetupColumn(ctx, 'Category', im.TableColumnFlags_WidthStretch, 25, 25.0)
              -- Type: 10% of remaining width - sortable, default sort column
              im.TableSetupColumn(ctx, 'Type', im.TableColumnFlags_WidthStretch | im.TableColumnFlags_DefaultSort, 10, 10.0)
              
              -- Freeze the header row so it stays visible when scrolling
              im.TableSetupScrollFreeze(ctx, 0, 1)
              
              im.TableHeadersRow(ctx)
              
              -- Display matching categories and manufacturers at top (prioritized)
              local current_row = 0
              if #matching_categories > 0 or #matching_manufacturers > 0 then
                  im.PushStyleColor(ctx, im.Col_Text, 0xAAFFFFFF) -- Light blue text
                  for _, cat in ipairs(matching_categories) do
                      im.TableNextRow(ctx)
                      current_row = current_row + 1
                      im.TableNextColumn(ctx) -- Favorites column
                      im.TableNextColumn(ctx) -- Plugin Name column
                      -- Only highlight if we're in regular section
                      local is_selected = (FX_Search_Section == 'regular' and current_row == (ADDFX_Sel_Entry or current_row))
                      if im.Selectable(ctx, "📁 Category: " .. cat .. "##cat_" .. cat, is_selected) then
                          FX_Search_ActiveFilters.category = cat
                          ADDFX_FILTER = '' -- Clear search text
                          ADDFX_Sel_Entry = nil
                          if ShowFavoritesUnderSearchBar then
                              FX_Search_Section = 'regular'
                          end
                      end
                      im.TableNextColumn(ctx) -- Manufacturer column
                      im.TableNextColumn(ctx) -- Category column
                      im.Text(ctx, cat)
                      im.TableNextColumn(ctx) -- Type column
                  end
                  for _, mfr in ipairs(matching_manufacturers) do
                      im.TableNextRow(ctx)
                      current_row = current_row + 1
                      im.TableNextColumn(ctx) -- Favorites column
                      im.TableNextColumn(ctx) -- Plugin Name column
                      -- Only highlight if we're in regular section
                      local is_selected = (FX_Search_Section == 'regular' and current_row == (ADDFX_Sel_Entry or current_row))
                      if im.Selectable(ctx, "🏭 Manufacturer: " .. mfr .. "##mfr_" .. mfr, is_selected) then
                          FX_Search_ActiveFilters.manufacturer = mfr
                          ADDFX_FILTER = '' -- Clear search text
                          ADDFX_Sel_Entry = nil
                          if ShowFavoritesUnderSearchBar then
                              FX_Search_Section = 'regular'
                          end
                      end
                      im.TableNextColumn(ctx) -- Manufacturer column
                      im.Text(ctx, mfr)
                      im.TableNextColumn(ctx) -- Category column
                      im.TableNextColumn(ctx) -- Type column
                  end
                  im.PopStyleColor(ctx, 1)
              end
              
              -- Handle sorting - must check AFTER TableHeadersRow is called
              -- Check if there are active sort specs (even if not dirty, since array is regenerated each frame)
              local has_sort_specs = false
              for sort_idx = 0, math.huge do
                  local ok, col_idx, col_user_id, sort_direction = im.TableGetColumnSortSpecs(ctx, sort_idx)
                  if not ok then break end
                  has_sort_specs = true
                  break -- Just need to know if any exist
              end
              
              -- Sort if specs are dirty OR if we have active sort specs (since array regenerates each frame)
              -- Store sorted state to avoid re-sorting when not needed
              local needs_sort = im.TableNeedSort(ctx) or has_sort_specs
              local sort_key = nil
              if has_sort_specs then
                  -- Create a key from sort specs to detect if sort changed
                  local spec_parts = {}
                  for sort_idx = 0, math.huge do
                      local ok, col_idx, col_user_id, sort_direction = im.TableGetColumnSortSpecs(ctx, sort_idx)
                      if not ok then break end
                      table.insert(spec_parts, col_idx .. ':' .. sort_direction)
                  end
                  sort_key = table.concat(spec_parts, ',')
              end
              
              -- Update favorite status in cache items (in case favorites changed)
              if FX_Search_Cache then
                  for i = 1, #FX_Search_Cache.items do
                      FX_Search_Cache.items[i].is_favorite = FX_Favorites[FX_Search_Cache.items[i].raw_fx] == true
                  end
                  
                  -- Always sort to prioritize favorites, even if no column sort is active
                  -- Create a key that includes favorite status to detect changes
                  local favorite_key = nil
                  local favorite_parts = {}
                  for i = 1, #FX_Search_Cache.items do
                      if FX_Search_Cache.items[i].is_favorite then
                          table.insert(favorite_parts, FX_Search_Cache.items[i].raw_fx)
                      end
                  end
                  table.sort(favorite_parts)
                  favorite_key = table.concat(favorite_parts, '|')
                  
                  local combined_sort_key = (sort_key or 'none') .. '|fav:' .. favorite_key
                  local should_sort = needs_sort or (not FX_Search_Cache.sort_key or FX_Search_Cache.sort_key ~= combined_sort_key)
                  
                  if should_sort then
                      -- Sort cache items array (don't modify filtered_fx as it's regenerated each frame)
                      table.sort(FX_Search_Cache.items, function(a, b)
                          if not a or not b then return false end
                          
                          -- Always prioritize favorites first
                          if a.is_favorite ~= b.is_favorite then
                              return a.is_favorite -- Favorites come first
                          end
                          
                          -- Get sort specs (iterate through all sort specs)
                          local has_sort_specs = false
                          local sort_handled = false
                          for sort_idx = 0, math.huge do
                              local ok, col_idx, col_user_id, sort_direction = im.TableGetColumnSortSpecs(ctx, sort_idx)
                              if not ok then break end
                              has_sort_specs = true
                              sort_handled = true
                              
                              local val_a, val_b
                              -- Column indices: 0=Favorites (not sortable), 1=Plugin Name, 2=Manufacturer, 3=Category, 4=Type
                              if col_idx == 1 then -- Plugin Name
                                  val_a, val_b = a.name:lower(), b.name:lower()
                              elseif col_idx == 2 then -- Manufacturer
                                  val_a, val_b = a.manufacturer:lower(), b.manufacturer:lower()
                              elseif col_idx == 3 then -- Category
                                  val_a, val_b = a.category:lower(), b.category:lower()
                              elseif col_idx == 4 then -- Type
                                  -- When sorting by type, use plugin type priority hierarchy
                                  local priority_a = GetPluginTypePriority(a.type)
                                  local priority_b = GetPluginTypePriority(b.type)
                                  
                                  if priority_a ~= priority_b then
                                      -- Lower priority number = higher preference
                                      if priority_a < priority_b then
                                          return sort_direction == im.SortDirection_Ascending
                                      else
                                          return sort_direction ~= im.SortDirection_Ascending
                                      end
                                  else
                                      -- Same priority, compare type names alphabetically
                                      val_a, val_b = a.type:lower(), b.type:lower()
                                      -- Continue to comparison logic below
                                  end
                              else
                                  -- Fallback to name comparison
                                  val_a, val_b = a.name:lower(), b.name:lower()
                              end
                              
                              -- Compare values (if not already handled by type priority)
                              if val_a and val_b then
                                  if val_a < val_b then
                                      return sort_direction == im.SortDirection_Ascending
                                  elseif val_a > val_b then
                                      return sort_direction ~= im.SortDirection_Ascending
                                  end
                              end
                              -- If equal, continue to next sort spec (if any)
                          end
                          
                          -- If no sort specs, apply plugin type priority as default sort
                          if not has_sort_specs then
                              local priority_a = GetPluginTypePriority(a.type)
                              local priority_b = GetPluginTypePriority(b.type)
                              if priority_a ~= priority_b then
                                  return priority_a < priority_b -- Lower number = higher priority
                              end
                          end
                          
                          -- If all sort specs are equal (or no sort specs and same priority), use name as tiebreaker
                          return a.name:lower() < b.name:lower()
                      end)
                      
                      -- Store sort key to avoid re-sorting next frame
                      FX_Search_Cache.sort_key = combined_sort_key
                  end
              end

              -- Render all rows (using cached data for performance)
              -- Adjust index offset for category/manufacturer matches
              local fx_start_index = match_row_start
              if FX_Search_Cache and FX_Search_Cache.items then
                  for i = 1, #FX_Search_Cache.items do
                      local cached = FX_Search_Cache.items[i]
                      if not cached then break end
                  
                  im.TableNextRow(ctx)
                  
                  -- Favorites column (first column)
                  im.TableNextColumn(ctx)
                  local is_favorite = FX_Favorites[cached.raw_fx] == true
                  local starIcon = is_favorite and Img.Star or Img.StarHollow
                  local iconSize = 14
                  if starIcon and im.ImageButton(ctx, '##fav' .. cached.raw_fx .. i, starIcon, iconSize, iconSize) then
                      -- Toggle favorite state
                      FX_Favorites[cached.raw_fx] = not is_favorite
                      -- Save favorites to file for persistence
                      SaveFXFavorites()
                  end
                  
                  -- Plugin Name column
                  im.TableNextColumn(ctx)
                  -- Only highlight if we're in the regular section, not favorites
                  local is_selected = (FX_Search_Section == 'regular' and (i + fx_start_index) == ADDFX_Sel_Entry)
                  if im.Selectable(ctx, cached.name .. '##' .. i, is_selected) then
                      Inserted_FX_Pos = InsertFX(cached.raw_fx)
                      im.CloseCurrentPopup(ctx)
                      -- Clear cache and filters when popup closes after selection
                      FX_Search_Cache = nil
                      FX_Search_ActiveFilters = {category = nil, manufacturer = nil}
                      if ShowFavoritesUnderSearchBar then
                          FX_Search_Section = 'regular'
                      end
                      close = true
                  end
                  
                  if im.IsItemActive(ctx) and im.IsMouseDragging(ctx, 0) then
                      DRAG_FX = i
                      AddFX_Drag(cached.raw_fx)
                  end

                  -- Manufacturer column (clickable to apply filter - keep search query)
                  im.TableNextColumn(ctx)
                  if cached.manufacturer and cached.manufacturer ~= '' then
                      -- Make manufacturer clickable
                      im.PushStyleColor(ctx, im.Col_Text, 0x88AAFFFF) -- Light blue to indicate clickable
                      im.PushID(ctx, "mfr_" .. i .. "_" .. cached.manufacturer)
                      -- Use Selectable to make it clickable
                      im.Selectable(ctx, cached.manufacturer, false)
                      -- Check if this item was clicked (after Selectable call)
                      if im.IsItemClicked(ctx, 0) and not im.IsItemToggledOpen(ctx) then
                          FX_Search_ActiveFilters.manufacturer = cached.manufacturer
                          -- Don't clear search text when clicking column
                          ADDFX_Sel_Entry = nil
                          -- Note: Cache will be rebuilt next frame automatically due to filter change
                      end
                      im.PopID(ctx)
                      im.PopStyleColor(ctx, 1)
                  else
                      im.Text(ctx, '')
                  end

                  -- Category column (clickable to apply filter - keep search query)
                  im.TableNextColumn(ctx)
                  if cached.category and cached.category ~= '' then
                      -- Make category clickable
                      im.PushStyleColor(ctx, im.Col_Text, 0x88AAFFFF) -- Light blue to indicate clickable
                      im.PushID(ctx, "cat_" .. i .. "_" .. cached.category)
                      -- Use Selectable to make it clickable
                      im.Selectable(ctx, cached.category, false)
                      -- Check if this item was clicked (after Selectable call)
                      if im.IsItemClicked(ctx, 0) and not im.IsItemToggledOpen(ctx) then
                          FX_Search_ActiveFilters.category = cached.category
                          -- Don't clear search text when clicking column
                          ADDFX_Sel_Entry = nil
                          -- Note: Cache will be rebuilt next frame automatically due to filter change
                      end
                      im.PopID(ctx)
                      im.PopStyleColor(ctx, 1)
                  else
                      im.Text(ctx, '')
                  end

                  -- Type column
                  im.TableNextColumn(ctx)
                  if cached.type == 'Container' then
                       if Img and Img.FolderOpen then
                          im.Image(ctx, Img.FolderOpen, HideBtnSz, HideBtnSz)
                          im.SameLine(ctx)
                       end
                       im.Text(ctx, 'Container')
                  else
                       im.PushStyleColor(ctx, im.Col_Text, cached.color)
                       im.Text(ctx, cached.type)
                       im.PopStyleColor(ctx)
                  end
                  end -- Close the for loop
              end -- Close the if FX_Search_Cache check
              im.EndTable(ctx)
          end

          if im.IsKeyPressed(ctx, im.Key_Enter) then
            ADDFX_Sel_Entry = ADDFX_Sel_Entry or 1
            -- Check if selection is a category or manufacturer match
            if match_row_start > 0 and ADDFX_Sel_Entry <= match_row_start then
                -- Handle category/manufacturer selection
                local filter_row_offset = (category_filter or manufacturer_filter) and 1 or 0
                local sel_idx = ADDFX_Sel_Entry - filter_row_offset
                if sel_idx > 0 and sel_idx <= #matching_categories then
                    FX_Search_ActiveFilters.category = matching_categories[sel_idx]
                    ADDFX_FILTER = '' -- Clear search text
                    -- Clear cache to force refresh with new filter
                    FX_Search_Cache = nil
                elseif sel_idx > #matching_categories and sel_idx <= #matching_categories + #matching_manufacturers then
                    local mfr_idx = sel_idx - #matching_categories
                    FX_Search_ActiveFilters.manufacturer = matching_manufacturers[mfr_idx]
                    ADDFX_FILTER = '' -- Clear search text
                    -- Clear cache to force refresh with new filter
                    FX_Search_Cache = nil
                end
                ADDFX_Sel_Entry = nil
                -- Don't close popup - keep it open to show filtered results
            else
                -- Use cached data for correct sorted order (adjust for match rows)
                local fx_index = ADDFX_Sel_Entry - match_row_start
                if fx_index > 0 and fx_index <= #FX_Search_Cache.items then
                    local cached_item = FX_Search_Cache.items[fx_index]
                    if cached_item then
                        Inserted_FX_Pos = InsertFX(cached_item.raw_fx)
                        LAST_USED_FX = cached_item.raw_fx
                    end
                end
                ADDFX_Sel_Entry = nil
                im.CloseCurrentPopup(ctx)
                -- Clear cache and filters when popup closes after Enter key
                FX_Search_Cache = nil
                FX_Search_ActiveFilters = {category = nil, manufacturer = nil}
                close = true
            end

            --FILTER = ''
            --im.CloseCurrentPopup(ctx)
          elseif im.IsKeyPressed(ctx, im.Key_UpArrow) then
              -- Only navigate in popup if we're in regular section
              if not (ShowFavoritesUnderSearchBar and showFavorites) or FX_Search_Section == 'regular' then
                  ADDFX_Sel_Entry = (ADDFX_Sel_Entry or 1) - 1
                  local max_entries = match_row_start + #FX_Search_Cache.items
                  ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry, 1, max_entries)
                  -- Update section tracking - if in popup, we're in regular section
                  if ShowFavoritesUnderSearchBar and showFavorites then
                      FX_Search_Section = 'regular'
                  end
              end
          elseif im.IsKeyPressed(ctx, im.Key_DownArrow) then
              -- Only navigate in popup if we're in regular section
              if not (ShowFavoritesUnderSearchBar and showFavorites) or FX_Search_Section == 'regular' then
                  ADDFX_Sel_Entry = (ADDFX_Sel_Entry or 1) + 1
                  local max_entries = match_row_start + #FX_Search_Cache.items
                  ADDFX_Sel_Entry = SetMinMax(ADDFX_Sel_Entry, 1, max_entries)
                  -- Update section tracking - if in popup, we're in regular section
                  if ShowFavoritesUnderSearchBar and showFavorites then
                      FX_Search_Section = 'regular'
                  end
              end
          elseif ShowFavoritesUnderSearchBar and showFavorites and im.IsKeyPressed(ctx, im.Key_LeftArrow) then
              -- Left arrow: switch to favorites section (under search bar)
              FX_Search_Section = 'favorites'
              ADDFX_Sel_Entry = 1
              -- Clear any selection in regular results
          elseif ShowFavoritesUnderSearchBar and showFavorites and im.IsKeyPressed(ctx, im.Key_RightArrow) then
              -- Right arrow: switch to regular section (in popup)
              FX_Search_Section = 'regular'
              ADDFX_Sel_Entry = match_row_start + 1
              -- Clear any selection in favorites (already handled by section change)
          end
          --im.EndChild(ctx)
          im.EndPopup(ctx)
          -- Clear cache when popup ends (EndPopup is called every frame, so don't clear filters here)
          FX_Search_Cache = nil
      else
          -- Popup is closed (BeginPopup returned false) - clear filters now
          FX_Search_ActiveFilters = {category = nil, manufacturer = nil}
      end
      im.PopStyleVar(ctx)


      im.OpenPopup(ctx, "##popupp")
      im.NewLine(ctx)
  end


  if im.IsKeyPressed(ctx, im.Key_Escape) then
      im.CloseCurrentPopup(ctx)
      ADDFX_FILTER = nil
      -- Clear cache and filters when popup is closed via Escape
      FX_Search_Cache = nil
      FX_Search_ActiveFilters = {category = nil, manufacturer = nil}
      -- Keep window size/position for next time popup opens
  end
  im.PopFont(ctx)

  return close, Inserted_FX_Pos

end

function DrawXIndicator(ctx, size, color)  
  local cursor_x, cursor_y = im.GetMousePos(ctx)
  local draw_list = im.GetForegroundDrawList(ctx)
  local half_size = size / 2
  cursor_x = cursor_x + 10
  -- Draw X shape
  im.DrawList_AddLine(draw_list, 
    cursor_x - half_size, cursor_y - half_size, 
    cursor_x + half_size, cursor_y + half_size, 
    color, 2)
  im.DrawList_AddLine(draw_list, 
    cursor_x - half_size, cursor_y + half_size, 
    cursor_x + half_size, cursor_y - half_size, 
    color, 2)
end

local function Change_Clr_Alpha(CLR, HowMuch)
  local R, G, B, A = im.ColorConvertU32ToDouble4(CLR)
  local A = SetMinMax(A + HowMuch, 0, 1)
  return im.ColorConvertDouble4ToU32(R, G, B, A)
end
-- Draw a soft glow around a rectangle.
function DrawGlowRect(dl, L,T,R,B, colour, layers, maxOfs)
  layers   = layers   or 5
  maxOfs   = maxOfs   or 6
  colour   = colour   or 0xffffcc88

  for i = 1, layers do
    local f   = (layers-i+1)/layers                -- fade outer rings
    local ofs = (i/layers)*maxOfs
    local c   = Change_Clr_Alpha(colour,-(1-f))    -- lower alpha on every ring
    im.DrawList_AddRect(dl, L-ofs, T-ofs, R+ofs, B+ofs, c, nil, nil, 2)
  end
end

-- NEW  dotted rectangle helper ---------------------------------------------------------
function DrawDottedRect(dl, L, T, R, B, colour, spacing, dotSize)
  -- Draws a dotted outline rectangle by stamping small squares along the border.
  colour  = colour  or Clr.SendsPreview
  spacing = spacing or 4  -- pixels between dots
  dotSize = dotSize or 2  -- size of each dot square
  -- horizontal top / bottom
  for x = L, R, spacing do
    im.DrawList_AddRectFilled(dl, x, T, x + dotSize, T + dotSize, colour)
    im.DrawList_AddRectFilled(dl, x, B - dotSize, x + dotSize, B, colour)
  end
  -- vertical left / right
  for y = T, B, spacing do
    im.DrawList_AddRectFilled(dl, L, y, L + dotSize, y + dotSize, colour)
    im.DrawList_AddRectFilled(dl, R - dotSize, y, R, y + dotSize, colour)
  end
end

-- Draw diagonal stripes within a rectangle. Adjustable stripe width and gap.
-- dl        : draw list
-- L,T,R,B   : rectangle bounds
-- color     : stripe color (U32)
-- stripeWidth: thickness of each stripe in pixels
-- gap       : gap between stripes in pixels (defaults to stripeWidth)
-- direction : 1 for \\ (slope +1), -1 for // (slope -1)
function DrawDiagonalStripes(dl, L, T, R, B, color, stripeWidth, gap, direction)
  if not dl then dl = im.GetWindowDrawList(ctx) end
  if not (L and T and R and B) then return end
  local H = B - T
  if H <= 0 then return end
  stripeWidth = math.max(1, stripeWidth or 3)
  gap = gap or stripeWidth
  local step = math.max(1, stripeWidth + gap)
  local dir = (direction == -1) and -1 or 1

  -- Parameterize stripes starting along the top edge with spacing, extending to bottom edge.
  -- For dir=+1: x(t) = x0 + H*t; for dir=-1: x(t) = x0 - H*t; y(t) = T + (B-T)*t, t in [0,1]
  local startX = (dir == 1) and (L - H) or L
  local endX   = (dir == 1) and R       or (R + H)
  for x0 = startX, endX, step do
    local t0, t1
    if dir == 1 then
      -- enforce L <= x0 + H*t <= R
      t0 = math.max(0, (L - x0) / H)
      t1 = math.min(1, (R - x0) / H)
    else
      -- enforce L <= x0 - H*t <= R  => (x0 - R)/H <= t <= (x0 - L)/H
      t0 = math.max(0, (x0 - R) / H)
      t1 = math.min(1, (x0 - L) / H)
    end
    if t0 < t1 then
      local xA = (dir == 1) and (x0 + H * t0) or (x0 - H * t0)
      local yA = T + (B - T) * t0
      local xB = (dir == 1) and (x0 + H * t1) or (x0 - H * t1)
      local yB = T + (B - T) * t1
      im.DrawList_AddLine(dl, xA, yA, xB, yB, color or 0xffffff55, stripeWidth)
    end
  end
end

-- Draw horizontal stripes within a rectangle. Adjustable stripe width and gap.
-- dl        : draw list
-- L,T,R,B   : rectangle bounds
-- color     : stripe color (U32)
-- stripeWidth: thickness of each stripe in pixels
-- gap       : gap between stripes in pixels (defaults to stripeWidth)
function DrawHorizontalStripes(dl, L, T, R, B, color, stripeWidth, gap)
  if not dl then dl = im.GetWindowDrawList(ctx) end
  if not (L and T and R and B) then return end
  local H = B - T
  if H <= 0 then return end
  stripeWidth = math.max(1, stripeWidth or 3)
  gap = gap or stripeWidth
  local step = math.max(1, stripeWidth + gap)
  
  -- Draw horizontal filled rectangles from top to bottom
  for y = T, B, step do
    local stripeBottom = math.min(B, y + stripeWidth)
    im.DrawList_AddRectFilled(dl, L, y, R, stripeBottom, color or 0xffffff55)
  end
end

function Convert_Val2Fader(rea_val)
  if not rea_val then return end
  local rea_val = SetMinMax(rea_val, 0, 4)
  local val
  local gfx_c, coeff = 0.8, 50      -- use coeff to adjust curve
  local real_dB = 20 * math.log(rea_val, 10)
  local lin2 = 10 ^ (real_dB / coeff)
  if lin2 <= 1 then val = lin2 * gfx_c else val = gfx_c + (real_dB / 12) * (1 - gfx_c) end
  if val > 1 then val = 1 end
  return SetMinMax(val, 0.0001, 1)
end

function emptyStrToNil(str)
  if str == '' then return nil else return str end
end

function ColorChangeAnimation(frame, endframe, color, endClr)
  local A, outCLR
  if frame < endframe / 2 then
    A = (frame / endframe) * 2
    outCLR = Change_Clr_Alpha(color, A)
  else
    A = (endframe - frame) * 2 / 100
    outCLR = Change_Clr_Alpha(color, A)
  end

  return outCLR
end


function riseDropAnimation(frame, endframe)
  if frame < endframe / 2 then
    A = (frame / endframe) * 2
  else
    A = (endframe - frame) * 2 / 100
  end
  return A
end

function riseAnimation(frame, endframe, begin, End)
  A = (endframe / frame)
  return A
end

function FindFXFromFxGUID(FxID_To_Find)
  local out = { fx = {}, trk = {} }

  for t = 0, TrackCount - 1 do
    local trk = r.GetTrack(0, t)
    local FX_Ct = r.TrackFX_GetCount(trk)
    for fx = 0, FX_Ct - 1, 1 do
      local FxID = r.TrackFX_GetFXGUID(trk, fx)
      if FxID_To_Find == FxID then
        table.insert(out.fx, fx)
        table.insert(out.trk, trk)
      end
    end
  end


  return out
end

function ToggleTrackSendFav(Track, ID)
  if not ID then ID = TrkID end
  if Trk[ID].SendFav then
    Trk[ID].SendFav = false
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: Track is Send Fav', '', true)
  else
    Trk[ID].SendFav = true
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: Track is Send Fav', 'true', true)
  end
end

-- Refresh per-track Send Favorites from the current project's extstates.
-- Call this when a project switch is detected to keep favorites in sync.
function RefreshSendFavoritesForCurrentProject()
  TrackCount = r.GetNumTracks()
  for t = 0, TrackCount - 1, 1 do
    local Track = r.GetTrack(0, t)
    if Track then
      local ID = r.GetTrackGUID(Track)
      Trk[ID] = Trk[ID] or {}
      Trk[ID].SendFav = StringToBool[select(2, r.GetSetMediaTrackInfo_String(Track, 'P_EXT: Track is Send Fav', '', false))]
    end
  end
end

function Generate_Active_And_Hvr_CLRs(Clr)
  local ActV, HvrV
  local R, G, B, A = im.ColorConvertU32ToDouble4(Clr)
  local H, S, V = im.ColorConvertRGBtoHSV(R, G, B)


  if V then
    if V > 0.9 then
      ActV = V - 0.2
      HvrV = V - 0.1
    end
  end
  local R, G, B = im.ColorConvertHSVtoRGB(H, S, SetMinMax(ActV or V + 0.2, 0, 1))
  local ActClr = im.ColorConvertDouble4ToU32(R, G, B, A)
  local R, G, B = im.ColorConvertHSVtoRGB(H, S, HvrV or V + 0.1)
  local HvrClr = im.ColorConvertDouble4ToU32(R, G, B, A)
  return ActClr, HvrClr
end

RecvClr            = 0x569CD6ff
RecvClr1, RecvClr2 = Generate_Active_And_Hvr_CLRs(RecvClr)
SendClr            = 0xC586C0ff
SendClr1, SendClr2 = Generate_Active_And_Hvr_CLRs(SendClr)



local function getTrackPosAndHeight(track)
  if track then
    assert(track, "getTrackPosAndHeight: invalid parameter - track")

    local height = r.GetMediaTrackInfo_Value(track, "I_WNDH") -- current TCP window height in pixels including envelopes
    local posy = r.GetMediaTrackInfo_Value(track, "I_TCPY")   -- current TCP window Y-position in pixels relative to top of arrange view
    return posy, height
  end
end -- getTrackPosAndHeight()

function DB2VAL(x) return math.exp((x) * 0.11512925464970228420089957273422) end

function VAL2DB(x)
  if not x or x < 0.0000000298023223876953125 then return -150.0 end
  local v = math.log(x) * 8.6858896380650365530225783783321
  return math.max(v, -150)
end

function SendVal_Calc_MouseDrag(ctx)
  local DtX, DtY = im.GetMouseDelta(ctx)
  local scale = 0.8
  if Mods == Shift then scale = 0.15 end
  local adj = VAL2DB(volume) - (-DtX) * scale
  local out = SetMinMax(DB2VAL(adj), 0, 4)
  return out
end

function DragVol(ctx, V, Dir, scale, VOLorPan)
  if Mods == Shift then scale = scale * 0.185 end
  local DtX, DtY = im.GetMouseDelta(ctx)
  if Dir == 'Horiz' then Dt = -DtX else Dt = DtY end
  if VOLorPan ~= 'Pan' then
    local adj = VAL2DB(V) - Dt * scale
    out = SetMinMax(DB2VAL(adj), 0, 4)
  else -- if it's pan
    out = SetMinMax(V - Dt * scale, -1, 1)
  end
  return out
end

function ToggleSolo(Trk)
  if r.GetMediaTrackInfo_Value(Trk, 'I_SOLO') == 0 then
    r.SetMediaTrackInfo_Value(Trk, 'I_SOLO', 1)
  else
    r.SetMediaTrackInfo_Value(Trk, 'I_SOLO', 0)
  end
end

--[[ function ShowSendVolumePopup(ctx,Track , i )
  if im.BeginTooltip(ctx) then 
    local retval, volume, pan = r.GetTrackSendUIVolPan(Track, i)
    local volume = r.GetTrackSendInfo_Value(Track, -1, i, 'D_VOL')


    local ShownVol = ('%.1f'):format(VAL2DB(volume))

    im.Text(ctx,ShownVol)
    im.EndTooltip(ctx)
  end

end ]]

----------------------------------------------------------------------------------------
local ctx = im.CreateContext('FX List', im.ConfigFlags_DockingEnable)
----------------------------------------------------------------------------------------

local AndaleMonoVerticalPath = r.GetResourcePath() .. "/Scripts/BRYAN's SCRIPTS/Vertical FX List Resources/Functions/AndaleMonoVertical.ttf"
local AndaleMonoVertical
if r.file_exists and r.file_exists(AndaleMonoVerticalPath) then
  AndaleMonoVertical = im.CreateFont(AndaleMonoVerticalPath, 12)
  im.Attach(ctx, AndaleMonoVertical)
end

Arial      = im.CreateFont('Arial', 13)
Arial_6    = im.CreateFont('Arial', 6)
Arial_7    = im.CreateFont('Arial', 7)
Arial_8    = im.CreateFont('Arial', 8)
Arial_9    = im.CreateFont('Arial', 9)
Arial_10   = im.CreateFont('Arial', 10)
Arial_11   = im.CreateFont('Arial', 11)
Arial_12   = im.CreateFont('Arial', 12)
Arial_13   = im.CreateFont('Arial', 13)
Arial_14   = im.CreateFont('Arial', 14)
Arial_15   = im.CreateFont('Arial', 15)
Arial_16   = im.CreateFont('Arial', 16)
 
Arial_Black_16 = im.CreateFont('Arial Black', 16)
im.Attach(ctx, Arial_Black_16)
im.Attach(ctx, Arial   )
im.Attach(ctx, Arial_6 )
im.Attach(ctx, Arial_7 )
im.Attach(ctx, Arial_8 )
im.Attach(ctx, Arial_9 )
im.Attach(ctx, Arial_10)
im.Attach(ctx, Arial_11)
im.Attach(ctx, Arial_12)
im.Attach(ctx, Arial_13)
im.Attach(ctx, Arial_14)
im.Attach(ctx, Arial_15)
im.Attach(ctx, Arial_16)









Font_Andale_Mono      = im.CreateFont('andale mono', 13)
Font_Andale_Mono_6    = im.CreateFont('andale mono', 6)
Font_Andale_Mono_7    = im.CreateFont('andale mono', 7)
Font_Andale_Mono_8    = im.CreateFont('andale mono', 8)
Font_Andale_Mono_9    = im.CreateFont('andale mono', 9)
Font_Andale_Mono_10   = im.CreateFont('andale mono', 10)
Font_Andale_Mono_11   = im.CreateFont('andale mono', 11)
Font_Andale_Mono_12   = im.CreateFont('andale mono', 12)
Font_Andale_Mono_13   = im.CreateFont('andale mono', 13)
Font_Andale_Mono_14   = im.CreateFont('andale mono', 14)
Font_Andale_Mono_15   = im.CreateFont('andale mono', 15)
Font_Andale_Mono_16   = im.CreateFont('andale mono', 16)

Font_Andale_Mono_6_B  = im.CreateFont('andale mono', 6,  im.FontFlags_Bold)
Font_Andale_Mono_7_B  = im.CreateFont('andale mono', 7,  im.FontFlags_Bold)
Font_Andale_Mono_8_B  = im.CreateFont('andale mono', 8,  im.FontFlags_Bold)
Font_Andale_Mono_9_B  = im.CreateFont('andale mono', 9,  im.FontFlags_Bold)
Font_Andale_Mono_10_B = im.CreateFont('andale mono', 10, im.FontFlags_Bold)
Font_Andale_Mono_11_B = im.CreateFont('andale mono', 11, im.FontFlags_Bold)
Font_Andale_Mono_12_B = im.CreateFont('andale mono', 12, im.FontFlags_Bold)
Font_Andale_Mono_13_B = im.CreateFont('andale mono', 13, im.FontFlags_Bold)
Font_Andale_Mono_14_B = im.CreateFont('andale mono', 14, im.FontFlags_Bold)
Font_Andale_Mono_15_B = im.CreateFont('andale mono', 15, im.FontFlags_Bold)
Font_Andale_Mono_16_B = im.CreateFont('andale mono', 16, im.FontFlags_Bold)

-- Bold+Italic fonts for selected FX buttons
Font_Andale_Mono_6_BI  = im.CreateFont('andale mono', 6,  im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_7_BI  = im.CreateFont('andale mono', 7,  im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_8_BI  = im.CreateFont('andale mono', 8,  im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_9_BI  = im.CreateFont('andale mono', 9,  im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_10_BI = im.CreateFont('andale mono', 10, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_11_BI = im.CreateFont('andale mono', 11, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_12_BI = im.CreateFont('andale mono', 12, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_13_BI = im.CreateFont('andale mono', 13, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_14_BI = im.CreateFont('andale mono', 14, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_15_BI = im.CreateFont('andale mono', 15, im.FontFlags_Bold | im.FontFlags_Italic)
Font_Andale_Mono_16_BI = im.CreateFont('andale mono', 16, im.FontFlags_Bold | im.FontFlags_Italic)--[[ 



-- Helper function for consistent License UI (Optimized Look)
local function DrawLicenseUI(ctx, is_modal)
    -- Improve spacing
    im.PushStyleVar(ctx, im.StyleVar_ItemSpacing, 0, 8)
    
    -- Header
    if not is_modal then
      if im.SeparatorText then
          im.SeparatorText(ctx, _0x2e3f() .. ' ' .. _0x4a5b())
      else
          im.Separator(ctx)
          im.Text(ctx, _0x2e3f() .. ' ' .. _0x4a5b())
          im.Separator(ctx)
      end
    end
    
    if im.BeginTable(ctx, '##LicenseInfo', 2, im.TableFlags_Borders | im.TableFlags_RowBg) then
        im.TableSetupColumn(ctx, 'Label', im.TableColumnFlags_WidthFixed, 100)
        im.TableSetupColumn(ctx, 'Value', im.TableColumnFlags_WidthStretch)
        
        im.TableNextRow(ctx)
        im.TableSetColumnIndex(ctx, 0)
        im.Text(ctx, _0x2e3f() .. ' ' .. _0x8e9f() .. ':')
        im.TableSetColumnIndex(ctx, 1)
        if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
            im.TextColored(ctx, 0x5EFF63FF, LicenseState.licenseKey)
        else
            im.TextColored(ctx, 0xAAAAAAFF, _0x9j0k())
        end
        
        im.TableNextRow(ctx)
        im.TableSetColumnIndex(ctx, 0)
        im.Text(ctx, _0x1a2c() .. ':')
        im.TableSetColumnIndex(ctx, 1)
        local statusText = LicenseStatusText()
        local statusColor = 0xFFFFFFFF
        if LicenseState.status == 'expired' or LicenseState.status == 'inactive' then
            statusColor = 0xFF4444FF
        elseif LicenseState.status == 'trial' then
            statusColor = 0xFFFF44FF
        elseif LicenseState.status == 'active' then
            statusColor = 0x5EFF63FF
        end
        im.TextColored(ctx, statusColor, statusText)
        
        if LicenseState.expiresAt then
            im.TableNextRow(ctx)
            im.TableSetColumnIndex(ctx, 0)
            im.Text(ctx, _0x3d4e() .. ':')
            im.TableSetColumnIndex(ctx, 1)
            im.Text(ctx, FormatExpiry(LicenseState.expiresAt))
        end
        
        im.TableNextRow(ctx)
        im.TableSetColumnIndex(ctx, 0)
        im.Text(ctx, _0x5f6g() .. ' ' .. _0x7h8i() .. ':')
        im.TableSetColumnIndex(ctx, 1)
        im.Text(ctx, LicenseState.deviceId or _0x1l2m())
        
        im.EndTable(ctx)
    end
    
    if LicenseState.reason and LicenseState.reason ~= '' and LicenseState.status == 'inactive' then
        im.Spacing(ctx)
        im.PushStyleColor(ctx, im.Col_Text, 0xFF4444FF)
        local noteText = string.char(78, 111, 116, 101, 58, 32) .. LicenseState.reason
        im.TextWrapped(ctx, noteText)
        im.PopStyleColor(ctx)
    end
    
    im.Spacing(ctx)
    
    if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
        local disabled = LicenseState.checking
        if disabled then im.BeginDisabled(ctx, true) end
        
        local btnW = is_modal and -1 or 200
        local verifyText = LicenseState.checking and _0x5p6q() or (_0x3n4o() .. ' ' .. _0x2e3f())
        if im.Button(ctx, verifyText, btnW, 0) then
            local success, msg = VerifyLicense(LicenseState.licenseKey)
            if success then
                _0x1a2b._0x7a8b = true
                _0x1a2b._0x9c0d = 0
                if is_modal then
                    if _0x1a2b then _0x1a2b._0x3c4d = false end
                    im.CloseCurrentPopup(ctx)
                end
            elseif not success then
                local failTitle = _0x2e3f() .. ' ' .. _0x4a5b()
                local failMsg = string.char(76, 105, 99, 101, 110, 115, 101, 32, 118, 101, 114, 105, 102, 105, 99, 97, 116, 105, 111, 110, 32, 102, 97, 105, 108, 101, 100, 58, 10, 10) .. (msg or string.char(85, 110, 107, 110, 111, 119, 110, 32, 101, 114, 114, 111, 114))
                r.ShowMessageBox(failMsg, failTitle, 0)
            end
        end
        
        if disabled then im.EndDisabled(ctx) end
        
        local removeText = _0x7r8s() .. ' ' .. _0x2e3f() .. ' ' .. _0x8e9f()
        if im.Button(ctx, removeText, btnW, 0) then
            LicenseState.licenseKey = nil
            SetLicenseResult('inactive', nil, 'License key removed', nil)
            if _0x1a2b then _0x1a2b._0x5e6f = nil end
        end
    else
        local enterText = _0x9t0u() .. ' ' .. string.char(121, 111, 117, 114) .. ' ' .. _0x2e3f() .. ' ' .. _0x8e9f() .. ' ' .. string.char(116, 111) .. ' ' .. _0x1v2w() .. ':'
        im.Text(ctx, enterText)
        local tempKey = (is_modal and _0x1a2b and _0x1a2b._0x5e6f) or OPEN.temp_license_key or ''
        im.SetNextItemWidth(ctx, -1)
        local changed, new_key = im.InputText(ctx, '##license_key_input', tempKey, 256)
        if changed then
            if is_modal and _0x1a2b then _0x1a2b._0x5e6f = new_key end
            OPEN.temp_license_key = new_key
            tempKey = new_key
        end
        
        local activateText = _0x3x4y() .. ' ' .. _0x2e3f()
        if im.Button(ctx, activateText, -1, 0) and tempKey ~= '' then
            local success, msg = VerifyLicense(tempKey)
            if success then
                _0x1a2b._0x7a8b = true
                _0x1a2b._0x9c0d = 0
                if is_modal and _0x1a2b then 
                    _0x1a2b._0x5e6f = nil 
                    _0x1a2b._0x3c4d = false
                    im.CloseCurrentPopup(ctx)
                end
                OPEN.temp_license_key = nil
            else
                local failTitle = _0x2e3f() .. ' ' .. string.char(65, 99, 116, 105, 118, 97, 116, 105, 111, 110)
                local failMsg = string.char(76, 105, 99, 101, 110, 115, 101, 32, 97, 99, 116, 105, 118, 97, 116, 105, 111, 110, 32, 102, 97, 105, 108, 101, 100, 58, 10, 10) .. (msg or string.char(85, 110, 107, 110, 111, 119, 110, 32, 101, 114, 114, 111, 114))
                r.ShowMessageBox(failMsg, failTitle, 0)
            end
        end
    end
    
    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)
    im.PushStyleColor(ctx, im.Col_Text, 0xAAAAAAFF)
    local infoText = string.char(76, 105, 99, 101, 110, 115, 101, 32, 118, 101, 114, 105, 102, 105, 99, 97, 116, 105, 111, 110, 32, 99, 111, 110, 110, 101, 99, 116, 115, 32, 116, 111, 32, 111, 117, 114, 32, 115, 101, 114, 118, 101, 114, 32, 116, 111, 32, 99, 104, 101, 99, 107, 32, 105, 102, 32, 121, 111, 117, 114, 32, 108, 105, 99, 101, 110, 115, 101, 32, 107, 101, 121, 32, 105, 115, 32, 118, 97, 108, 105, 100, 32, 97, 110, 100, 32, 110, 111, 116, 32, 97, 99, 116, 105, 118, 97, 116, 101, 100, 32, 111, 110, 32, 109, 111, 114, 101, 32, 116, 104, 97, 110, 32, 51, 32, 100, 101, 118, 105, 99, 101, 115, 32, 115, 105, 109, 117, 108, 116, 97, 110, 101, 111, 117, 115, 108, 121, 46)
    im.TextWrapped(ctx, infoText)
    im.PopStyleColor(ctx)
    
    im.PopStyleVar(ctx)
end

local function _0x2a3b_Modal()
  local _0x4c5d = _0x7a8b()
  local _0x6e7f = _0x1e2f()
  local _0x8a9b = IsLicenseValid()
  
  if not (_0x4c5d and _0x6e7f and _0x8a9b) or _0x1a2b._0x7a8b then
    local modal_flags = (im.WindowFlags_NoCollapse or 0) |
                       (im.WindowFlags_TopMost or 0)
    
    if not _0x1a2b._0x7a8b then
      modal_flags = modal_flags | (im.WindowFlags_AlwaysAutoResize or 0)
    end
    
    if not _0x1a2b._0x3c4d then
      im.OpenPopup(ctx, '##LicenseVerificationModal')
      _0x1a2b._0x3c4d = true
    end
    
    local modal_was_open = _0x1a2b._0x2a3b
    local modal_is_open = false
    
    if im.BeginPopupModal and im.BeginPopupModal(ctx, '##LicenseVerificationModal', true, modal_flags) then
      modal_is_open = true
      local viewport = im.GetWindowViewport(ctx)
      if viewport then
        local center_x, center_y = im.Viewport_GetCenter(viewport)
        im.SetNextWindowPos(ctx, center_x, center_y, im.Cond_Appearing, 0.5, 0.5)
      end
      
      if _0x1a2b._0x7a8b then
        im.SetNextWindowSize(ctx, 500, 200, im.Cond_Always)
      else
        im.SetNextWindowSize(ctx, 500, 0, im.Cond_Appearing)
      end
      
      if _0x1a2b._0x7a8b then
        im.Spacing(ctx)
        im.PushStyleColor(ctx, im.Col_Text, 0x5EFF63FF)
        im.Text(ctx, _0x5z6a() .. '!')
        im.PopStyleColor(ctx)
        im.Spacing(ctx)
        im.Separator(ctx)
        im.Spacing(ctx)
        
        local msg = string.char(76, 105, 99, 101, 110, 115, 101, 32, 118, 101, 114, 105, 102, 105, 101, 100, 32, 115, 117, 99, 99, 101, 115, 115, 102, 117, 108, 108, 121, 46)
        im.TextWrapped(ctx, msg)
        
        if LicenseState.status == 'trial' and LicenseState.expiresAt then
            im.Spacing(ctx)
            local expiry = LicenseState.expiresAt
            if expiry > 1e11 then expiry = math.floor(expiry / 1000) end
            local now = os.time()
            local daysLeft = math.floor((expiry - now) / 86400)
            if daysLeft > 0 then
                local trialMsg = _0x7b8c() .. ' ' .. _0x1f2g() .. ': ' .. tostring(daysLeft) .. ' ' .. _0x9d0e()
                im.PushStyleColor(ctx, im.Col_Text, 0xFFFF44FF)
                im.TextWrapped(ctx, trialMsg)
                im.PopStyleColor(ctx)
            end
        end
        
        im.Spacing(ctx)
        
        if _0x1a2b._0x9c0d == 0 then
            _0x1a2b._0x9c0d = os.time()
        end
        
        if os.time() - _0x1a2b._0x9c0d >= 3 then
            im.CloseCurrentPopup(ctx)
            _0x1a2b._0x7a8b = false
            _0x1a2b._0x9c0d = 0
            _0x1a2b._0x3c4d = false
        end
      else
        local titleText = _0x2e3f() .. ' ' .. _0x4a5b() .. ' ' .. _0x6c7d()
        im.Text(ctx, titleText)
        im.Separator(ctx)
        im.Spacing(ctx)
        
        -- Explanation and website link for users without a valid license
        local licenseInvalid = not LicenseState.licenseKey or LicenseState.licenseKey == '' or 
                              LicenseState.status == 'inactive' or LicenseState.status == 'expired'
        if licenseInvalid then
          im.TextWrapped(ctx, 'If you don\'t have a license, you can acquire a trial license or purchase a full license at our website.')
          im.Spacing(ctx)
          
          -- Button to open website
          local websiteUrl = 'https://coolreaperscripts.com'
          if im.Button(ctx, 'Visit coolreaperscripts.com', -1, 0) then
            if r.CF_ShellExecute then
              r.CF_ShellExecute(websiteUrl)
            else
              -- Fallback: try to open URL using system command
              local cmd = 'open "' .. websiteUrl .. '"'
              if r.GetOS() == 'Win32' or r.GetOS() == 'Win64' then
                cmd = 'start "" "' .. websiteUrl .. '"'
              elseif r.GetOS() == 'Linux' then
                cmd = 'xdg-open "' .. websiteUrl .. '"'
              end
              os.execute(cmd)
            end
          end
          im.Spacing(ctx)
          im.Separator(ctx)
          im.Spacing(ctx)
        end
        
        DrawLicenseUI(ctx, true)
      end
      
      im.EndPopup(ctx)
    end
    
    -- Check if modal was closed (was open, now closed) and license is still invalid
    -- If so, signal that script should exit
    -- Don't exit if this was the success message closing (license was just verified)
    if modal_was_open and not modal_is_open then
      -- Only exit if license is still invalid (not the success message closing)
      -- Re-check license status to ensure it's still invalid
      local _0x4c5d_check = _0x7a8b()
      local _0x6e7f_check = _0x1e2f()
      local _0x8a9b_check = IsLicenseValid()
      if not (_0x4c5d_check and _0x6e7f_check and _0x8a9b_check) then
        -- License is still invalid, user closed the modal without authorizing - exit script
        _0x1a2b._0x2a3b = false
        return 'exit'  -- Signal to exit script
      end
    end
    
    _0x1a2b._0x2a3b = modal_is_open
    return true
  end
  
  _0x1a2b._0x2a3b = false
  return false
end
 ]]
Impact_10 = im.CreateFont('Tahoma' , 12 , im.FontFlags_Bold)

im.Attach(ctx, Impact_10)
Impact_24 = im.CreateFont('Impact', 24, im.FontFlags_Bold)
im.Attach(ctx, Impact_24)
im.Attach(ctx, Font_Andale_Mono)
im.Attach(ctx, Font_Andale_Mono_6)
im.Attach(ctx, Font_Andale_Mono_7)
im.Attach(ctx, Font_Andale_Mono_8)
im.Attach(ctx, Font_Andale_Mono_9)
im.Attach(ctx, Font_Andale_Mono_10)
im.Attach(ctx, Font_Andale_Mono_11)
im.Attach(ctx, Font_Andale_Mono_12)
im.Attach(ctx, Font_Andale_Mono_13)
im.Attach(ctx, Font_Andale_Mono_14)
im.Attach(ctx, Font_Andale_Mono_15)
im.Attach(ctx, Font_Andale_Mono_16)

im.Attach(ctx, Font_Andale_Mono_6_B)
im.Attach(ctx, Font_Andale_Mono_7_B)
im.Attach(ctx, Font_Andale_Mono_8_B)
im.Attach(ctx, Font_Andale_Mono_9_B)
im.Attach(ctx, Font_Andale_Mono_10_B)
im.Attach(ctx, Font_Andale_Mono_11_B)
im.Attach(ctx, Font_Andale_Mono_12_B)
im.Attach(ctx, Font_Andale_Mono_13_B)
im.Attach(ctx, Font_Andale_Mono_14_B)
im.Attach(ctx, Font_Andale_Mono_15_B)
im.Attach(ctx, Font_Andale_Mono_16_B)

im.Attach(ctx, Font_Andale_Mono_6_BI)
im.Attach(ctx, Font_Andale_Mono_7_BI)
im.Attach(ctx, Font_Andale_Mono_8_BI)
im.Attach(ctx, Font_Andale_Mono_9_BI)
im.Attach(ctx, Font_Andale_Mono_10_BI)
im.Attach(ctx, Font_Andale_Mono_11_BI)
im.Attach(ctx, Font_Andale_Mono_12_BI)
im.Attach(ctx, Font_Andale_Mono_13_BI)
im.Attach(ctx, Font_Andale_Mono_14_BI)
im.Attach(ctx, Font_Andale_Mono_15_BI)
im.Attach(ctx, Font_Andale_Mono_16_BI)

function attachImages()
  local imageFolder = r.GetResourcePath() ..
     '/Scripts/BRYAN\'s SCRIPTS/Vertical FX List Resources/'
  Img = {
    StarHollow = im.CreateImage(imageFolder .. 'starHollow.png'),
    Star = im.CreateImage(imageFolder .. 'star.png'),
    Send = im.CreateImage(imageFolder .. 'send.png'),
    Recv = im.CreateImage(imageFolder .. 'receive.png'),
    Show = im.CreateImage(imageFolder .. 'show.png'),
    Hide = im.CreateImage(imageFolder .. 'hide.png'),
    Link = im.CreateImage(imageFolder .. 'link.png'),
    Snapshot = im.CreateImage(imageFolder .. 'snapshot.png'),
    Camera   = im.CreateImage(imageFolder .. 'camera.png'),
    Folder   = im.CreateImage(imageFolder .. 'folder.png'),
    FolderOpen = im.CreateImage(imageFolder .. 'folder_open.png'),
    Settings = im.CreateImage(imageFolder .. 'settings.png'),
  }
  -- Optional copy icon (fallback to Link if missing)
  do
    local copyPath = imageFolder .. 'copy.png'
    Img.Copy = im.CreateImage(copyPath)
    if not Img.Copy then Img.Copy = Img.Link end
  end
  -- Optional search icon (fallback to Settings if missing)
  do
    local searchPath = imageFolder .. 'search.png'
    Img.Search = im.CreateImage(searchPath)
    if not Img.Search then Img.Search = Img.Settings end
  end
  -- Optional trash icon (fallback to Hide if missing)
  do
    local trashPath = imageFolder .. 'trash.png'
    Img.Trash = im.CreateImage(trashPath)
    if not Img.Trash then Img.Trash = Img.Hide end
  end
  im.Attach(ctx, Img.Star)
  im.Attach(ctx, Img.StarHollow)
  im.Attach(ctx, Img.Send)
  im.Attach(ctx, Img.Recv)
  im.Attach(ctx, Img.Show)
  im.Attach(ctx, Img.Hide)
  im.Attach(ctx, Img.Link)
  im.Attach(ctx, Img.Snapshot)
  im.Attach(ctx, Img.Camera)
  im.Attach(ctx, Img.Folder)
  im.Attach(ctx, Img.FolderOpen)
  if Img.Copy then im.Attach(ctx, Img.Copy) end
  if Img.Trash then im.Attach(ctx, Img.Trash) end
  if Img.Search then im.Attach(ctx, Img.Search) end
  local graphPath = r.GetResourcePath() ..
  '/Scripts/BRYAN\'s SCRIPTS/Vertical FX List Resources/graph.png'
  Img.Graph = im.CreateImage(graphPath)

  im.Attach(ctx, Img.Graph)
end
attachImages()


VP = {}


if OS:find('OSX') then
  Super   = im.Mod_Ctrl
  Alt  = im.Mod_Alt
  Ctrl = im.Mod_Super
  Shift = im.Mod_Shift

else
  Alt   = im.Mod_Alt
  Shift = im.Mod_Shift
  Super = im.Mod_Super
  Ctrl  = im.Mod_Ctrl
end
Trk   = {}


function RefreshUI_HideTrack()
  r.DockWindowRefresh()
  r.TrackList_AdjustWindows(false)
end

function ttp(A)
  im.BeginTooltip(ctx)
  im.SetTooltip(ctx, A)
  im.EndTooltip(ctx)
end

function getClr(f)
  return im.GetStyleColor(ctx, f)
end

-- Color utilities for deriving hover/active variants from a base U32 color
function LightenColorU32(color, amount)
  local r,g,b,a = im.ColorConvertU32ToDouble4(color)
  amount = math.max(0, math.min(1, amount or 0))
  r = r + (1 - r) * amount
  g = g + (1 - g) * amount
  b = b + (1 - b) * amount
  return im.ColorConvertDouble4ToU32(r,g,b,a)
end
function DarkenColorU32(color, amount)
  local r,g,b,a = im.ColorConvertU32ToDouble4(color)
  amount = math.max(0, math.min(1, amount or 0))
  local f = 1 - amount
  r = r * f
  g = g * f
  b = b * f
  return im.ColorConvertDouble4ToU32(r,g,b,a)
end

function DeleteFX(fx, Track)
  -- Get FX GUID before deletion (needed for link cleanup)
  local fxID = r.TrackFX_GetFXGUID(Track, fx)
  
  -- Clean up linked FX if this FX has a link
  if fxID and FX[fxID] and FX[fxID].Link then
    local linkedFxID = FX[fxID].Link
    -- Find the linked FX and remove its link back to this FX
    local out = FindFXFromFxGUID(linkedFxID)
    if out.trk[1] then
      -- Clear the link from the linked FX's track extended state
      r.GetSetMediaTrackInfo_String(out.trk[1], 'P_EXT: FX' .. linkedFxID .. 'Link to ', '', true)
      -- Clear the link from the linked FX's data structure
      if FX[linkedFxID] then
        FX[linkedFxID].Link = nil
      end
    end
    -- Clear this FX's link from its track extended state
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: FX' .. fxID .. 'Link to ', '', true)
    -- Clear the link from this FX's data structure
    FX[fxID].Link = nil
  end
  
  r.TrackFX_Delete(Track, fx)
end

function SetHelpHint(L1, L2, L3, L4, L5, L6)
  if im.IsItemHovered(ctx) then
    HelpHint[1] = L1
    HelpHint[2] = L2
    HelpHint[3] = L3
    HelpHint[4] = L4
    HelpHint[5] = L5
    HelpHint[6] = L6
  else
    HelpHint = {}
  end
end

function HighlightSelectedItem(FillClr, OutlineClr, Padding, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, GetItemRect,
                               Foreground, Thick)
  if GetItemRect == 'GetItemRect' then
    L, T = im.GetItemRectMin(ctx); R, B = im.GetItemRectMax(ctx); w, h = im.GetItemRectSize(ctx)
    --Get item rect
  end
  local P = Padding or 0; local HSC = H_OutlineSc or 4; local VSC = V_OutlineSc or 4; Thick = Thick or 1
  if Foreground == 'Foreground' then
    WinDrawList = Foreground or FDL or im.GetForegroundDrawList(ctx)
  else
    WinDrawList = Foreground
  end
  if not WinDrawList then WinDrawList = im.GetWindowDrawList(ctx) end
  if FillClr then im.DrawList_AddRectFilled(WinDrawList, L, T, R, B, FillClr) end

  if OutlineClr then
    im.DrawList_AddLine(WinDrawList, L - P, T - P, L - P, T + h / VSC - P, OutlineClr, Thick);
    im.DrawList_AddLine(WinDrawList, R + P, T - P, R + P, T + h / VSC - P, OutlineClr, Thick)
    im.DrawList_AddLine(WinDrawList, L - P, B + P, L - P, B + P - h / VSC, OutlineClr, Thick);
    im.DrawList_AddLine(WinDrawList, R + P, B + P, R + P, B - h / VSC + P, OutlineClr, Thick)
    im.DrawList_AddLine(WinDrawList, L - P, T - P, L - P + w / HSC, T - P, OutlineClr, Thick);
    im.DrawList_AddLine(WinDrawList, R + P, T - P, R + P - w / HSC, T - P, OutlineClr, Thick)
    im.DrawList_AddLine(WinDrawList, L - P, B + P, L - P + w / HSC, B + P, OutlineClr, Thick);
    im.DrawList_AddLine(WinDrawList, R + P, B + P, R + P - w / HSC, B + P, OutlineClr, Thick)
  end
  if GetItemRect == 'GetItemRect' then return L, T, R, B, w, h end
end

function HighlightItem(FillClr, WDL, OutlineClr)
  if not WDL then WDL = im.GetWindowDrawList(ctx) end 
  L, T = im.GetItemRectMin(ctx); R, B = im.GetItemRectMax(ctx); w, h = im.GetItemRectSize(ctx)
  --Get item rect
  if FillClr then 
    im.DrawList_AddRectFilled(WDL, L, T, R, B, FillClr)
  end
  if OutlineClr then im.DrawList_AddRect(WDL, L, T, R, B, OutlineClr) end 
  return w,h
end

-- Helper: check if envelope has any data (automation items or points)
local function EnvelopeHasAnyData(env)
  if not env then return false end
  local ai = r.CountAutomationItems and r.CountAutomationItems(env) or 0
  if ai and ai > 0 then return true end
  local pt = r.CountEnvelopePoints and r.CountEnvelopePoints(env) or 0
  return (pt or 0) > 0
end

function Add_WetDryKnob(ctx, label, labeltoShow, p_value, v_min, v_max, FX_Idx, Track, isOffline)
  im.SetNextItemWidth(ctx, 40)
  local radius_outer = WetDryKnobSz
  local pos = { im.GetCursorScreenPos(ctx) }
  local center = { pos[1] + radius_outer, pos[2] + radius_outer }

  local line_height = im.GetTextLineHeight(ctx)
  local draw_list = im.GetWindowDrawList(ctx)
  local item_inner_spacing = { im.GetStyleVar(ctx, im.StyleVar_ItemInnerSpacing) }
  local mouse_delta = { im.GetMouseDelta(ctx) }

  local ANGLE_MIN = 3.141592 * 0.75
  local ANGLE_MAX = 3.141592 * 2.25
  local P_Num = r.TrackFX_GetParamFromIdent(Track, FX_Idx, ':wet')

  --  im.InvisibleButton(ctx, label, radius_outer * 2, radius_outer * 2 + line_height - 10 + item_inner_spacing[2])
  local p_value = r.TrackFX_GetParamNormalized(Track, FX_Idx, P_Num)
  local prev_value = p_value


  local Delta_P = r.TrackFX_GetNumParams(Track, FX_Idx) - 1
  local DeltaP_V =  r.TrackFX_GetParamNormalized(Track, FX_Idx, Delta_P)


  im.InvisibleButton(ctx, label, radius_outer * 2, line_height --[[ + item_inner_spacing[2] ]])
  local value_changed = false
  local is_active = im.IsItemActive(ctx)
  local is_hovered = im.IsItemHovered(ctx)
  if is_active and mouse_delta[2] ~= 0.0 then
    local step = (v_max - v_min) / 200.0

    if im.GetKeyMods(ctx) == im.Mod_Shift then step = step / 5 end
    p_value = p_value + ((-mouse_delta[2]) * step)
    if p_value < v_min then p_value = v_min end
    if p_value > v_max then p_value = v_max end
  end

  -- Get wet/dry envelope and check if it has data
  local wetDryEnv = r.GetFXEnvelope(Track, FX_Idx, P_Num, false)
  local envHasData = wetDryEnv and EnvelopeHasAnyData(wetDryEnv) or false

  -- Handle Ctrl+click to open wet/dry envelope
  if im.IsItemClicked(ctx) then
    local currentMods = im.GetKeyMods(ctx)
    if currentMods == Ctrl or (currentMods & Ctrl) ~= 0 then
      -- Ctrl+Left-click: show wet/dry envelope
      -- Select the track first (required for envelope operations)
      r.SetOnlyTrackSelected(Track)
      
      -- Get or create the envelope
      if not wetDryEnv then
        wetDryEnv = r.GetFXEnvelope(Track, FX_Idx, P_Num, true)
      end
      
      -- Show the envelope if found
      if wetDryEnv and wetDryEnv ~= 0 then
        -- Verify it's a valid envelope object
        local ok, name = r.GetEnvelopeName(wetDryEnv)
        if ok then
          r.GetSetEnvelopeInfo_String(wetDryEnv, 'VISIBLE', '1', true)
          r.GetSetEnvelopeInfo_String(wetDryEnv, 'SHOWLANE', '1', true)
          r.GetSetEnvelopeInfo_String(wetDryEnv, 'ACTIVE', '1', true)
          r.TrackList_AdjustWindows(false)
          -- Refresh envelope check after creating/showing
          envHasData = EnvelopeHasAnyData(wetDryEnv)
        end
      end
    end
  end

  if im.IsItemClicked(ctx, 1) and Mods == Alt then
    if DeltaP_V == 1 then
        r.TrackFX_SetParamNormalized(Track, FX_Idx, Delta_P, 0)
    else
        r.TrackFX_SetParamNormalized(Track, FX_Idx, Delta_P, 1)
    end
end




  if ActiveAny == true then
    if IsLBtnHeld == false then ActiveAny = false end
  end

  local t = (p_value - v_min) / (v_max - v_min)
  local angle = ANGLE_MIN + (ANGLE_MAX - ANGLE_MIN) * t
  local angle_cos, angle_sin = math.cos(angle), math.sin(angle)
  local radius_inner = radius_outer * 0.40

  local circleClr = getClr(im.Col_FrameBgHovered)
  if p_value == 1 then
    circleClr = getClr(im.Col_TextDisabled)
  elseif p_value ~= 1 then
    circleClr = getClr(im.Col_Text)
  end
  
  -- Use attention color if envelope has data
  if envHasData then
    circleClr = Clr.Attention
  end


  if is_active then
    --r.JS_Mouse_SetPosition(integer x, integer y)

    lineClr = (isOffline and 0xdd4444ff) or im.GetColor(ctx, im.Col_SliderGrabActive)
    value_changed = true
    ActiveAny = true
    local delta = (p_value or 0) - (prev_value or 0)
    r.TrackFX_SetParamNormalized(Track, FX_Idx, P_Num, p_value)
    
    -- Sync wet/dry values across selected FXs relatively if multiple are selected
    if MultiSelectionButtons.visible and delta ~= 0 then
      SyncWetDryValuesRelative(Track, FX_Idx, delta, ':wet')
    end
    
    HideCursorTillMouseUp(0, ctx)
    im.SetMouseCursor(ctx, im.MouseCursor_None)
  else
    lineClr = (isOffline and 0xdd4444ff) or circleClr
  end

  -- Ensure marquee selection is preserved while interacting with the knob of a selected FX
  do
    local trackGUID = r.GetTrackGUID(Track)
    if IsFXSelected and IsFXSelected(trackGUID, FX_Idx) then
      if is_active or is_hovered then
        InteractingWithSelectedFX = true
      end
    end
  end



  if DeltaP_V ~= 1 then
    local fillClr = isOffline and 0x771111ff or im.GetColor(ctx, im.Col_Button)
    r.ImGui_DrawList_AddCircleFilled(draw_list, center[1], center[2], radius_outer, fillClr)
    local borderClr = isOffline and 0xdd4444ff or circleClr
    im.DrawList_AddCircle(draw_list, center[1], center[2], radius_outer, borderClr)
    im.DrawList_AddLine(draw_list, center[1], center[2], center[1] + angle_cos * (radius_outer - 2),
      center[2] + angle_sin * (radius_outer - 2), lineClr, 2.0)
    im.DrawList_AddText(draw_list, pos[1], pos[2] + radius_outer * 2 + item_inner_spacing[2],
      im.GetColor(ctx, im.Col_Text), labeltoShow)
  else
      local radius_outer = radius_outer
      im.DrawList_AddTriangleFilled(draw_list, center[1] - radius_outer, center[2] + radius_outer, center[1],
          center[2] - radius_outer, center[1] + radius_outer, center[2] + radius_outer, 0x999900ff)
      im.DrawList_AddText(draw_list, center[1] - radius_outer / 2 + 1, center[2] - radius_outer / 2,
          0xffffffff, 'S')
  end
  


  if (is_active or is_hovered) and not MultiSelMenuVisibleThisFrame then
    local window_padding = { im.GetStyleVar(ctx, im.StyleVar_WindowPadding) }
    im.SetNextWindowPos(ctx, pos[1] + radius_outer * 3,
      pos[2] - 8)

    im.BeginTooltip(ctx)
    im.PushFont(ctx, Impact_24)
    im.Text(ctx, ('%.f'):format(p_value * 100) .. '%')
    im.PopFont(ctx)
    im.EndTooltip(ctx)
  end

  return ActiveAny, value_changed, p_value
end

function AddSpacing(Rpt)
  for i = 1, Rpt, 1 do
    im.Spacing(ctx)
  end
end

function MyText(text, font, color, WrapPosX)
  if WrapPosX then im.PushTextWrapPos(ctx, WrapPosX) end

  if font then im.PushFont(ctx, font) end
  if color then
    im.TextColored(ctx, color, text)
  else
    im.Text(ctx, text)
  end

  if font then im.PopFont(ctx) end
  if WrapPosX then im.PopTextWrapPos(ctx) end
end

function SL(x, w)
  im.SameLine(ctx, x, w)
end

function MoveFX(DragFX_ID, FX_Idx, isMove, AddLastSpace, FromTrack, ToTrack)
  local AltDest, AltDestLow, AltDestHigh, DontMove

  if SpcInPost then SpcIsInPre = false end

  if SpcIsInPre then
    if not tablefind(Trk[TrkID].PreFX, FXGUID[DragFX_ID]) then -- if fx is not in pre fx
      if SpaceIsBeforeRackMixer == 'End of PreFX' then
        table.insert(Trk[TrkID].PreFX, #Trk[TrkID].PreFX + 1, FXGUID[DragFX_ID])
        r.TrackFX_CopyToTrack(Track, DragFX_ID, Track, FX_Idx + 1, true)
        DontMove = true
      else
        table.insert(Trk[TrkID].PreFX, FX_Idx + 1, FXGUID[DragFX_ID])
      end
    else -- if fx is in pre fx
      local offset = 0
      if r.TrackFX_AddByName(Track, 'FXD Macros', 0, 0) ~= -1 then offset = -1 end
      if FX_Idx < DragFX_ID then -- if drag towards left
        table.remove(Trk[TrkID].PreFX, DragFX_ID + 1 + offset)
        table.insert(Trk[TrkID].PreFX, FX_Idx + 1 + offset, FXGUID[DragFX_ID])
      elseif SpaceIsBeforeRackMixer == 'End of PreFX' then
        table.insert(Trk[TrkID].PreFX, #Trk[TrkID].PreFX + 1, FXGUID[DragFX_ID])
        table.remove(Trk[TrkID].PreFX, DragFX_ID + 1 + offset)
        --move fx down
      else
        table.insert(Trk[TrkID].PreFX, FX_Idx + 1 + offset, FXGUID[DragFX_ID])
        table.remove(Trk[TrkID].PreFX, DragFX_ID + 1 + offset)
      end
    end

    for i, v in pairs(Trk[TrkID].PreFX) do
      r.GetSetMediaTrackInfo_String(Track, 'P_EXT: PreFX ' ..
        i, v, true)
    end
    if tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID]) then
      table.remove(Trk[TrkID].PostFX, tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID]))
    end
    FX.InLyr[FXGUID[DragFX_ID]] = nil
  elseif SpcInPost then
    local offset

    if r.TrackFX_AddByName(Track, 'FXD Macros', 0, 0) == -1 then offset = -1 else offset = 0 end

    if not tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID]) then -- if fx is not yet in post-fx chain
      InsertToPost_Src = DragFX_ID + offset + 1

      InsertToPost_Dest = SpcIDinPost


      if tablefind(Trk[TrkID].PreFX, FXGUID[DragFX_ID]) then
        table.remove(Trk[TrkID].PreFX, tablefind(Trk[TrkID].PreFX, FXGUID[DragFX_ID]))
      end
    else                              -- if fx is already in post-fx chain
      local IDinPost = tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID])
      if SpcIDinPost <= IDinPost then -- if drag towards left
        table.remove(Trk[TrkID].PostFX, IDinPost)
        table.insert(Trk[TrkID].PostFX, SpcIDinPost, FXGUID[DragFX_ID])
        table.insert(MovFX.ToPos, FX_Idx + 1)
      else
        table.insert(Trk[TrkID].PostFX, SpcIDinPost, Trk[TrkID].PostFX[IDinPost])
        table.remove(Trk[TrkID].PostFX, IDinPost)
        table.insert(MovFX.ToPos, FX_Idx)
      end
      DontMove = true
      table.insert(MovFX.FromPos, DragFX_ID)
    end
    FX.InLyr[FXGUID[DragFX_ID]] = nil
    --[[ else -- if space is not in pre or post
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: PreFX ' .. DragFX_ID, '', true)
    if not MoveFromPostToNorm then
      if tablefind(Trk[TrkID].PreFX, FXGUID[DragFX_ID]) then
        table.remove(Trk[TrkID].PreFX,
          tablefind(Trk[TrkID].PreFX, FXGUID[DragFX_ID]))
      end
    end
    if tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID]) then
      table.remove(Trk[TrkID].PostFX,
        tablefind(Trk[TrkID].PostFX, FXGUID[DragFX_ID]))
    end ]]
  end
  --[[ for i = 1, #Trk[TrkID].PostFX + 1, 1 do
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: PostFX ' .. i, Trk[TrkID].PostFX[i] or '', true)
  end
  for i = 1, #Trk[TrkID].PreFX + 1, 1 do --remove from pre FX
    r.GetSetMediaTrackInfo_String(Track, 'P_EXT: PreFX ' .. i, Trk[TrkID].PreFX[i] or '', true)
  end ]]
  if not DontMove then
    --[[ if FX_Idx ~= RepeatTimeForWindows and SpaceIsBeforeRackMixer ~= 'End of PreFX' then

      if (FX.Win_Name_S[FX_Idx] or ''):find('Pro%-C 2') then
        AltDestHigh = FX_Idx - 1
      end
      FX_Idx = tonumber(FX_Idx)
      DragFX_ID = tonumber(DragFX_ID)

      if FX_Idx > DragFX_ID then offset = 1 end


      table.insert(MovFX.ToPos, AltDestLow or FX_Idx - (offset or 0))
      table.insert(MovFX.FromPos, DragFX_ID)
    elseif FX_Idx == RepeatTimeForWindows and AddLastSpace == 'LastSpc' or SpaceIsBeforeRackMixer == 'End of PreFX' then
      local offset

      if Trk[TrkID].PostFX[1] then offset = #Trk[TrkID].PostFX end
      table.insert(MovFX.ToPos, FX_Idx - (offset or 0))
      table.insert(MovFX.FromPos, DragFX_ID)
    else ]]
    table.insert(MovFX.ToPos, FX_Idx - (offset or 0))
    table.insert(MovFX.FromPos, DragFX_ID)
    table.insert(MovFX.ToTrack, ToTrack)
    table.insert(MovFX.FromTrack, FromTrack)

    --[[ end
  end ]]
    if isMove == false then
      NeedCopyFX = true
      DropPos = FX_Idx
    end
  end
end

outlineClr = Change_Clr_A(Clr.SelectionOutline or Clr.Send, 1) -- use element-specific selection outline if set




------------Recall Stored Info before Loop --------------------
CurrentProj = select(1, r.EnumProjects(-1, ""))
TrackCount = r.GetNumTracks()
for t = 0, TrackCount - 1 do
  local Track = r.GetTrack(0, t)
  local ID = r.GetTrackGUID(Track)
  Trk[ID] = Trk[ID] or {}
  Trk[ID].SendFav = StringToBool[select(2, r.GetSetMediaTrackInfo_String(Track, 'P_EXT: Track is Send Fav', '', false))]
  local Fx_Ct = r.TrackFX_GetCount(Track)
  for fx = 0, Fx_Ct - 1, 1 do
    local fxID = r.TrackFX_GetFXGUID(Track, fx)
    FX[fxID] = FX[fxID] or {}
    FX[fxID].Link = emptyStrToNil(select(2,
      r.GetSetMediaTrackInfo_String(Track, 'P_EXT: FX' .. fxID .. 'Link to ', '', false)))
  end
end


--[[ ========================= Shortcuts ============================== ]]
-- Allow users to customise their own keyboard shortcuts for common toggles
-- Persisted per-project in extstate so they survive restarts.

local SHORTCUTS_SECTION = 'FXD_Vertical_FX_List_Shortcuts'
local OS_NAME = (r and r.GetOS and (r.GetOS() or '')) or ''
local IS_MAC = OS_NAME:find('OSX') or OS_NAME:find('macOS')

-- Default bindings
Shortcuts = {
  ToggleSends      = { key = im.Key_S, mods = 0               }, -- S
  ToggleSnapshots  = { key = im.Key_S, mods = im.Mod_Shift    }, -- Shift+S
  ToggleMonitorFX  = { key = im.Key_M, mods = im.Mod_Shift    }, -- Shift+M
  ExpandTrack      = { key = im.Key_E, mods = 0               }, -- E
  HoverSendSoloTrack = { key = im.Key_S, mods = 0             }, -- S when hovering a send: solo destination track
  HoverSendSoloSend  = { key = im.Key_S, mods = (IS_MAC and im.Mod_Super or im.Mod_Ctrl) }, -- Cmd/Ctrl+S when hovering a send: solo that send
}

-- Serialise / deserialise helpers -----------------------------------------------------
local function SaveShortcuts()
  local parts = {}
  for act, sc in pairs(Shortcuts) do
    if sc and sc.key then
      parts[#parts+1] = string.format('%s=%d,%d', act, sc.key, sc.mods or 0)
    end
  end
  r.SetProjExtState(0, SHORTCUTS_SECTION, 'keys', table.concat(parts,';'))
end

local function LoadShortcuts()
  local ok, str = r.GetProjExtState(0, SHORTCUTS_SECTION, 'keys')
  if ok == 1 and str ~= '' then
    for pair in string.gmatch(str,'([^;]+)') do
      local act, nums = pair:match('([^=]+)=(.+)')
      if act and nums then
        local k,m = nums:match('(%d+),(%d+)')
        if k and m then
          Shortcuts[act] = { key = tonumber(k), mods = tonumber(m) }
        end
      end
    end
  end
end

LoadShortcuts()

-- Produce human-readable description e.g. "Shift+S"
local modNames = { [im.Mod_Shift]='Shift', [im.Mod_Ctrl]='Ctrl', [im.Mod_Alt]='Alt', [im.Mod_Super]='Cmd' }
local keyNameLookup = {}
for c=string.byte('A'), string.byte('Z') do keyNameLookup[im['Key_'..string.char(c)]] = string.char(c) end
for d=0,9 do keyNameLookup[im['Key_'..d]] = tostring(d) end
keyNameLookup[im.Key_Space]   = 'Space'
keyNameLookup[im.Key_Enter]   = 'Enter'
keyNameLookup[im.Key_Escape]  = 'Esc'
keyNameLookup[im.Key_Tab]     = 'Tab'
keyNameLookup[im.Key_M]       = 'M'
keyNameLookup[im.Key_S]       = 'S'


local function KeyDesc(sc)
  if not sc then return '?' end
  local parts = {}
  for k,v in pairs(modNames) do if sc.mods & k ~= 0 then parts[#parts+1]=v end end
  local kn = keyNameLookup[sc.key] or tostring(sc.key)
  parts[#parts+1] = kn
  return table.concat(parts,'+')
end

-- Global typing guard available before any InputText is used
TypingInTextField = TypingInTextField or false
if not WithTypingGuard then
  function WithTypingGuard(renderFn)
    local beforeActive = im.IsAnyItemActive(ctx)
    renderFn()
    local afterActive = im.IsAnyItemActive(ctx)
    if (not beforeActive) and afterActive then TypingInTextField = true end
    if beforeActive and (not afterActive) then TypingInTextField = false end
  end
end

-- Settings window where user can re-bind ------------------------------------------------
local waitingForBind -- holds action string while waiting for new key combo
-- list of enumerated keys we accept for binding (non-modifier)
local NamedKeyList = {}
-- build alphabet programmatically
for c=string.byte('A'), string.byte('Z') do NamedKeyList[#NamedKeyList+1] = im['Key_'..string.char(c)] end
-- digits
for d=0,9 do NamedKeyList[#NamedKeyList+1] = im['Key_'..d] end
-- others
local extras = { im.Key_Space, im.Key_Enter, im.Key_Escape, im.Key_Tab,
                 im.Key_LeftArrow or im.Key_Left, im.Key_RightArrow or im.Key_Right,
                 im.Key_UpArrow or im.Key_Up, im.Key_DownArrow or im.Key_Down,
                 im.Key_F1, im.Key_F2, im.Key_F3, im.Key_F4, im.Key_F5,
                 im.Key_F6, im.Key_F7, im.Key_F8, im.Key_F9, im.Key_F10,
                 im.Key_F11, im.Key_F12 }
for _,k in ipairs(extras) do NamedKeyList[#NamedKeyList+1] = k end

PluginTypeOrder = PluginTypeOrder or {"VST3", "VST", "AU", "CLAP", "JS"}

local function SavePluginTypeOrder()
    local orderStr = table.concat(PluginTypeOrder, ",")
    r.SetProjExtState(0, "FXD_PluginTypeOrder", "Order", orderStr)
end

local function LoadPluginTypeOrder()
    local retval, orderStr = r.GetProjExtState(0, "FXD_PluginTypeOrder", "Order")
    if retval == 1 and orderStr ~= "" then
        local newOrder = {}
        for type in string.gmatch(orderStr, "([^,]+)") do
            table.insert(newOrder, type)
        end
        -- Validate that we have all required types
        local requiredTypes = {VST3=true, VST=true, AU=true, CLAP=true, JS=true}
        for _, t in ipairs(newOrder) do
            requiredTypes[t] = nil
        end
        -- If we have all types and no extra, use the loaded order
        if next(requiredTypes) == nil and #newOrder == 5 then
            PluginTypeOrder = newOrder
        end
    end
end

LoadPluginTypeOrder()

local function PluginTypeOrder_DragDrop()
    im.Text(ctx, "Plugin Type Preference (drag to reorder):")
    
    -- Draw the preference indicator horizontally
    local startX, startY = im.GetCursorPos(ctx)
    local buttonWidth = 60
    local spacing = 5
    local itemHeight = 28
    local totalWidth = #PluginTypeOrder * (buttonWidth + spacing) - spacing
    
    -- Draw "Most" and "Least" labels horizontally with double-sided arrow
    im.Text(ctx, "Most")
    
    -- Get screen position of "Most" text
    local mostMinX, mostMinY = im.GetItemRectMin(ctx)
    local mostMaxX, mostMaxY = im.GetItemRectMax(ctx)
    
    local textSpacing = 15
    im.SameLine(ctx, 0, textSpacing)
    
    -- Draw double-sided arrow between Most and Least
    local drawlist = im.GetWindowDrawList(ctx)
    local arrowColor = Clr.SelectionOutline or 0x289F81ff
    local lineColor = arrowColor
    
    -- Calculate arrow start position (right after "Most")
    local arrowY = mostMinY + (mostMaxY - mostMinY) / 2
    local arrowStartX = mostMaxX + 5
    
    -- Position "Least" text
    im.SameLine(ctx, 0, totalWidth - 40)
    im.Text(ctx, "Least")
    
    -- Get screen position of "Least" text
    local leastMinX, leastMinY = im.GetItemRectMin(ctx)
    local leastMaxX, leastMaxY = im.GetItemRectMax(ctx)
    
    -- Calculate arrow end position (left before "Least")
    local arrowEndX = leastMinX - 5
    
    -- Draw horizontal line
    im.DrawList_AddLine(drawlist, arrowStartX, arrowY, arrowEndX, arrowY, lineColor, 2)
    
    -- Add left arrowhead (pointing left)
    im.DrawList_AddTriangleFilled(drawlist, 
        arrowStartX, arrowY, 
        arrowStartX + 8, arrowY - 5, 
        arrowStartX + 8, arrowY + 5, 
        arrowColor)
    
    -- Add right arrowhead (pointing right)
    im.DrawList_AddTriangleFilled(drawlist, 
        arrowEndX, arrowY, 
        arrowEndX - 8, arrowY - 5, 
        arrowEndX - 8, arrowY + 5, 
        arrowColor)
    
    im.NewLine(ctx)
    
    -- Position for buttons
    im.SetCursorPos(ctx, startX, startY + 25)
    
    -- Display buttons horizontally
    for i = 1, #PluginTypeOrder do
        if i > 1 then
            im.SameLine(ctx, 0, spacing)
        end
        im.PushID(ctx, i)
        
        -- Get the appropriate color for this plugin type
        local pluginType = PluginTypeOrder[i]
        local textColor = 0xFFFFFFFF
        
        if pluginType == "VST" then
            textColor = CustomColorsDefault.FX_Adder_VST or 0x6FB74BFF
        elseif pluginType == "VST3" then
            textColor = CustomColorsDefault.FX_Adder_VST3 or 0xC3DC5CFF
        elseif pluginType == "JS" then
            textColor = CustomColorsDefault.FX_Adder_JS or 0x9348A9FF
        elseif pluginType == "AU" then
            textColor = CustomColorsDefault.FX_Adder_AU or 0x526D97FF
        elseif pluginType == "CLAP" then
            textColor = CustomColorsDefault.FX_Adder_CLAP or 0xB62424FF
        end
        
        -- Plugin type button
        im.PushStyleColor(ctx, im.Col_Text, textColor)
        im.PushStyleVar(ctx, im.StyleVar_FramePadding, 0, 0)  -- Remove default padding
        im.Button(ctx, PluginTypeOrder[i], buttonWidth, itemHeight)
        im.PopStyleVar(ctx)
        im.PopStyleColor(ctx, 1)
        
        -- Handle drag and drop on the button
        if im.BeginDragDropSource(ctx) then
            im.SetDragDropPayload(ctx, "PLUGIN_TYPE_ORDER", tostring(i))
            im.Text(ctx, "Moving " .. PluginTypeOrder[i])
            im.EndDragDropSource(ctx)
        end
        
        if im.BeginDragDropTarget(ctx) then
            local dropped, payload = im.AcceptDragDropPayload(ctx, "PLUGIN_TYPE_ORDER")
            if dropped then
                local src_idx = tonumber(payload)
                if src_idx ~= i then
                    local moving_val = PluginTypeOrder[src_idx]
                    table.remove(PluginTypeOrder, src_idx)
                    table.insert(PluginTypeOrder, i > src_idx and i or i, moving_val)
                    SavePluginTypeOrder()
                end
            end
            im.EndDragDropTarget(ctx)
        end
        
        im.PopID(ctx)
    end
    
    im.NewLine(ctx)
end

-- Style Editor functions (extracted from demo.lua)
local style_editor_cache = {}

local function EachEnum(enum)
  local enum_cache = style_editor_cache[enum]
  if not enum_cache then
    enum_cache = {}
    style_editor_cache[enum] = enum_cache

    for func_name, value in pairs(im) do
      local enum_name = func_name:match(('^%s_(.+)$'):format(enum))
      if enum_name then
        enum_cache[#enum_cache + 1] = { value, enum_name }
      end
    end

    table.sort(enum_cache, function(a, b) return a[1] < b[1] end)
  end

  return ipairs(enum_cache)
end

-- Specialized function for colors that handles the enumeration correctly
local function EachColor()
  local color_cache = style_editor_cache['Col_Values']
  if not color_cache then
    color_cache = {}
    style_editor_cache['Col_Values'] = color_cache
    
    -- Get all color constants from ImGui
    for i = 0, 100 do -- ImGuiCol_COUNT is typically around 60-70
      local color_name = nil
      for func_name, value in pairs(im) do
        if func_name:match('^Col_.+$') and value == i then
          color_name = func_name:match('^Col_(.+)$')
          break
        end
      end
      if color_name then
        color_cache[#color_cache + 1] = { i, color_name }
      end
    end
  end
  
  return ipairs(color_cache)
end

local function HelpMarker(desc)
  im.TextDisabled(ctx, '(?)')
  if im.BeginItemTooltip(ctx) then
    im.PushTextWrapPos(ctx, im.GetFontSize(ctx) * 35.0)
    im.Text(ctx, desc)
    im.PopTextWrapPos(ctx)
    im.EndTooltip(ctx)
  end
end

local function GetStyleData()
  local data = { vars={}, colors={} }
  local vec2 = {
    'ButtonTextAlign', 'SelectableTextAlign', 'CellPadding', 'ItemSpacing',
    'ItemInnerSpacing', 'FramePadding', 'WindowPadding', 'WindowMinSize',
    'WindowTitleAlign', 'SeparatorTextAlign', 'SeparatorTextPadding',
    'TableAngledHeadersTextAlign',
  }

  -- sizes/style vars no longer tracked in presets
  for _, color_data in EachColor() do
    local i, name = color_data[1], color_data[2]
    data.colors[i] = im.GetStyleColor(ctx, i)
  end
  return data
end

local function CopyStyleData(source, target)
  -- sizes/style vars no longer copied
  for i, value in pairs(source.colors) do
    target.colors[i] = value
  end
  -- carry element-specific colors if present
  target.element_colors = {}
  if source.element_colors then
    for k, v in pairs(source.element_colors) do
      target.element_colors[k] = v
    end
  end
end

-- Cache of the default style preset to avoid reading from file each frame
local Cached_Default_StylePreset = nil

local function CloneStyleData(src)
  local t = { vars = {}, colors = {} }
  CopyStyleData(src, t)
  return t
end

local function CacheDefaultStylePreset()
  -- defaults removed; no-op for backward compatibility
end

local function PushStyle()
  if OPEN.style_editor and not OPEN.style_editor.disabled then
    OPEN.style_editor.push_count = OPEN.style_editor.push_count + 1
    
    -- Define which style variables require two values (vec2)
    local vec2_vars = {
      [im.StyleVar_ButtonTextAlign] = true,
      [im.StyleVar_SelectableTextAlign] = true,
      [im.StyleVar_CellPadding] = true,
      [im.StyleVar_ItemSpacing] = true,
      [im.StyleVar_ItemInnerSpacing] = true,
      [im.StyleVar_FramePadding] = true,
      [im.StyleVar_WindowPadding] = true,
      [im.StyleVar_WindowMinSize] = true,
      [im.StyleVar_WindowTitleAlign] = true,
      [im.StyleVar_SeparatorTextAlign] = true,
      [im.StyleVar_SeparatorTextPadding] = true,
      [im.StyleVar_TableAngledHeadersTextAlign] = true,
    }
    
    local pushed_var_count = 0
    for i, value in pairs(OPEN.style_editor.style.vars) do
      if vec2_vars[i] then
        -- This variable requires two values
        if type(value) == 'table' and #value == 2 then
          im.PushStyleVar(ctx, i, value[1], value[2])
        else
          -- Fallback: use the value twice if it's not a table
          local val = type(value) == 'table' and value[1] or value
          im.PushStyleVar(ctx, i, val, val)
        end
      else
        -- Single value variable
        if type(value) == 'table' then
          im.PushStyleVar(ctx, i, value[1])
        else
          im.PushStyleVar(ctx, i, value)
        end
      end
      pushed_var_count = pushed_var_count + 1
    end
    
    local pushed_color_count = 0
    for i, value in pairs(OPEN.style_editor.style.colors) do
      im.PushStyleColor(ctx, i, value)
      pushed_color_count = pushed_color_count + 1
    end

    OPEN.style_editor._last_var_count = pushed_var_count
    OPEN.style_editor._last_color_count = pushed_color_count
  end
end
local function PopStyle()
  if OPEN.style_editor and OPEN.style_editor.push_count > 0 then
    OPEN.style_editor.push_count = OPEN.style_editor.push_count - 1
    
    local color_count = OPEN.style_editor._last_color_count or 0
    local var_count = OPEN.style_editor._last_var_count or 0
    
    if color_count > 0 then
      im.PopStyleColor(ctx, color_count)
    end
    if var_count > 0 then
      im.PopStyleVar(ctx, var_count)
    end

    OPEN.style_editor._last_color_count = 0
    OPEN.style_editor._last_var_count = 0
  end
end

local function ShowStyleEditor()
  local rv

  if not OPEN.style_editor then
    OPEN.style_editor = {
      style  = GetStyleData(),
      ref    = GetStyleData(),
      output_dest = 0,
      output_prefix = 0,
      output_only_modified = true,
      push_count = 0,
    }
  end

  im.PushItemWidth(ctx, im.GetWindowWidth(ctx) * 0.50)

  -- FX List Colors (always visible)
  -- Bring the Style Editor "Colors" tab UI directly into the Style Editor section
  if not OPEN.style_editor.colors then
    OPEN.style_editor.colors = {
      filter = im.CreateTextFilter(),
      alpha_flags = im.ColorEditFlags_None,
    }
    im.Attach(ctx, OPEN.style_editor.colors.filter)
  end
  im.PushFont(ctx, Font_Andale_Mono_14)

  im.SeparatorText(ctx, 'All Colors')
  im.PopFont(ctx)
  -- Filter input with placeholder
  OPEN.style_editor.colors.filter_text = OPEN.style_editor.colors.filter_text or ''
  do
    im.PushStyleVar(ctx, im.StyleVar_FramePadding, 6, 6)
    im.PushStyleColor(ctx, im.Col_Button, getClr(im.Col_Button))
    im.PushStyleColor(ctx, im.Col_ButtonActive, getClr(im.Col_Button))
    im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_Button))
    -- Leading icon as image button
    local ln = im.GetTextLineHeight(ctx)
    local iconSz = ln 
    im.PushFont(ctx, Font_Andale_Mono_13)
    if Img and Img.Search then
      im.ImageButton(ctx, '##FilterIcon', Img.Search, iconSz, iconSz)
    end
    im.PopStyleColor(ctx,3)
    im.SameLine(ctx, nil, 0)
    im.PushItemWidth(ctx, 460)
          -- Set cursor color to bright cyan for better visibility
          im.PushStyleColor(ctx, r.ImGui_Col_InputTextCursor(), 0x00ffffff)
          WithTypingGuard(function()
            local changed, txt = im.InputText(ctx, '##ColorFilter', OPEN.style_editor.colors.filter_text or '', 256)
            if changed then OPEN.style_editor.colors.filter_text = txt end
          end)
          im.PopStyleColor(ctx, 1)
    local L, T = im.GetItemRectMin(ctx)
    local R, B = im.GetItemRectMax(ctx)
    local dl = im.GetWindowDrawList(ctx)
    local colDim = getClr(im.Col_TextDisabled)
    if (OPEN.style_editor.colors.filter_text or '') == '' and not im.IsItemActive(ctx) then
      im.DrawList_AddText(dl, L + 4, T + 2, colDim, 'type here to filter colors')
    end
    im.PopFont(ctx)
    im.PopStyleVar(ctx)
    im.PopItemWidth(ctx)
  end

  local borders = { 'WindowBorder', 'FrameBorder', 'PopupBorder' }
  for i, name in ipairs(borders) do
    local var = im[('StyleVar_%sSize'):format(name)]
    local cur = OPEN.style_editor.style.vars[var]
    if cur == nil then
      local x = im.GetStyleVar(ctx, var)
      cur = (type(x) == 'table' and x[1]) or x or 0.0
      OPEN.style_editor.style.vars[var] = cur
    end
    local enable = (cur or 0) > 0
    if i > 1 then im.SameLine(ctx) end
    rv, enable = im.Checkbox(ctx, name, enable)
    if rv then OPEN.style_editor.style.vars[var] = enable and 1 or 0 end
    end
    im.SameLine(ctx)
    HelpMarker('In the color list:\nLeft-click on color square to open color picker,\nRight-click to open edit options menu.')

    im.SetNextWindowSizeConstraints(ctx, 0.0, im.GetTextLineHeightWithSpacing(ctx) * 10, 999999, 999999)
    if im.BeginChild(ctx, '##colors_fxlist_header', 0, 0, im.ChildFlags_Border | im.ChildFlags_NavFlattened,
        im.WindowFlags_AlwaysVerticalScrollbar | im.WindowFlags_AlwaysHorizontalScrollbar) then
      im.PushItemWidth(ctx, im.GetFontSize(ctx) * -12)
      local inner_spacing = im.GetStyleVar(ctx, im.StyleVar_ItemInnerSpacing)

      -- FX List element-specific colors (filterable)
      do
        local fx_entries = {
          { 'FX Button (Default)', 'Buttons' },
          { 'VSTi Button (Default)', 'VSTi' },
          { 'Send Button', 'Send' },
          { 'Receive Button', 'ReceiveSend' },
          { 'Selection Outline', 'SelectionOutline' },
          { 'Pane Separator', 'PaneSeparator' },
          { 'Track Boundary Line', 'TrackBoundaryLine' },
          { 'Highlight Fill', 'GenericHighlightFill' },
          { 'Highlight Outline', 'GenericHighlightOutline' },
          { 'Patch Line', 'PatchLine' },
          { 'Sends Preview', 'SendsPreview' },
          { 'Snapshot Overlay', 'SnapshotOverlay' },
          { 'Danger Red', 'Danger' },
          { 'Attention Yellow', 'Attention' },
          { 'Channel Badge BG', 'ChanBadgeBg' },
          { 'Channel Badge Text', 'ChanBadgeText' },
          { 'Pan Text Overlay', 'PanTextOverlay' },
          { 'Pan Slider Fill', 'PanSliderFill' },
          { 'Value Rect (Vol/Pan fill)', 'ValueRect' },
          { 'FX Link', 'LinkCable' },
          { 'Hidden Parent Outline', 'HiddenParentOutline' },
          { 'Hidden Parent Hover', 'HiddenParentHover' },
        }
        im.SeparatorText(ctx, 'FX List Colors')
        for _, entry in ipairs(fx_entries) do
          local label, key = entry[1], entry[2]
        local f = (OPEN.style_editor.colors.filter_text or ''):lower()
        if f == '' or label:lower():find(f, 1, true) then
            im.PushID(ctx, key)
            local cur = Clr[key] or 0xffffffff
          local rv, newCol = im.ColorEdit4(ctx, '##color', cur, im.ColorEditFlags_AlphaBar)
            if rv then Clr[key] = newCol end
            im.SameLine(ctx, 0.0, inner_spacing)
            im.Text(ctx, label)
            im.PopID(ctx)
          end
        end
      end

      -- ImGui style colors (original Colors tab content)
      im.SeparatorText(ctx, 'ImGui Style Colors')
      for _, color_data in EachColor() do
        local i, name = color_data[1], color_data[2]
      local f2 = (OPEN.style_editor.colors.filter_text or ''):lower()
      if f2 == '' or name:lower():find(f2, 1, true) then
          im.PushID(ctx, i)
          if im.Button(ctx, '?') then
            im.DebugFlashStyleColor(ctx, i)
          end
          im.SetItemTooltip(ctx, 'Flash given color to identify places where it is used.')
          im.SameLine(ctx)
        rv, OPEN.style_editor.style.colors[i] = im.ColorEdit4(ctx, '##color', OPEN.style_editor.style.colors[i], im.ColorEditFlags_AlphaBar)
          if OPEN.style_editor.style.colors[i] ~= OPEN.style_editor.ref.colors[i] then
          im.SameLine(ctx, nil, nil)
            if im.Button(ctx, 'Save') then
              OPEN.style_editor.ref.colors[i] = OPEN.style_editor.style.colors[i]
            end
          im.SameLine(ctx, nil, nil)
            if im.Button(ctx, 'Revert') then
              OPEN.style_editor.style.colors[i] = OPEN.style_editor.ref.colors[i]
            end
          end
        im.SameLine(ctx, nil)
          im.Text(ctx, name)
          im.PopID(ctx)
        end
      end

      im.PopItemWidth(ctx)
      im.EndChild(ctx)
  end

  if im.BeginTabBar(ctx, '##tabs', im.TabBarFlags_None) then
    im.EndTabBar(ctx)
  end

  im.PopItemWidth(ctx)
end

-- Style preset management
local function GetStylePresetsDir()
  return r.GetResourcePath() .. '/Scripts/BRYAN\'s SCRIPTS/'
end

local function GetStylePresetsJsonPath()
  return GetStylePresetsDir() .. 'style_presets.json'
end

local function GetStylePresetsLuaPath()
  return GetStylePresetsDir() .. 'style_presets.lua'
end

local function SaveStylePresetsToFile()
   if not OPEN.style_presets then return end
   
   -- Write Lua file (robust to read)
   do
     local lua_file = io.open(GetStylePresetsLuaPath(), 'w')
     if lua_file then
       lua_file:write('return {\n')
       local first_preset = true
       for preset_name, preset_data in pairs(OPEN.style_presets) do
         if not first_preset then lua_file:write(',\n') end
         first_preset = false
         lua_file:write(('  ["%s"] = {\n'):format(preset_name))
         lua_file:write('    vars = {\n')
         local first_var = true
         for i, value in pairs(preset_data.vars) do
           if not first_var then lua_file:write(',\n') end
           first_var = false
           if type(value) == 'table' then
             lua_file:write(('      [%d] = { %s, %s }'):format(i, tostring(value[1]), tostring(value[2])))
           else
             lua_file:write(('      [%d] = %s'):format(i, tostring(value)))
           end
         end
         lua_file:write('\n    },\n')
         lua_file:write('    colors = {\n')
         local first_color = true
         for i, value in pairs(preset_data.colors) do
           if not first_color then lua_file:write(',\n') end
           first_color = false
           lua_file:write(('      [%d] = %s'):format(i, tostring(value)))
         end
         lua_file:write('\n    },\n')
         -- element-specific colors
         lua_file:write('    element_colors = {\n')
         local first_elem = true
         for _, key in ipairs(ElementColorKeys) do
           if not first_elem then lua_file:write(',\n') end
           first_elem = false
           local v = (preset_data.element_colors and preset_data.element_colors[key]) or (Clr and Clr[key]) or 0
           lua_file:write(('      ["%s"] = %d'):format(key, v))
         end
         lua_file:write('\n    }\n  }')
       end
       lua_file:write('\n}\n')
       lua_file:close()
     end
   end

   -- Mirror JSON (optional, for human readability/compat)
   do
     local file = io.open(GetStylePresetsJsonPath(), 'w')
     if file then
       file:write('{\n')
       local first_preset = true
       for preset_name, preset_data in pairs(OPEN.style_presets) do
         if not first_preset then file:write(',\n') end
         first_preset = false
         file:write('  "' .. preset_name .. '": {\n')
         file:write('    "vars": {\n')
         local first_var = true
         for i, value in pairs(preset_data.vars) do
           if not first_var then file:write(',\n') end
           first_var = false
           if type(value) == 'table' then
             file:write('      "' .. i .. '": [' .. value[1] .. ', ' .. value[2] .. ']')
           else
             file:write('      "' .. i .. '": ' .. value)
           end
         end
         file:write('\n    },\n')
         file:write('    "colors": {\n')
         local first_color = true
         for i, value in pairs(preset_data.colors) do
           if not first_color then file:write(',\n') end
           first_color = false
           file:write('      "' .. i .. '": ' .. value)
         end
         file:write('\n    },\n')
         -- element-specific colors (JSON)
         file:write('    "element_colors": {\n')
         local first_elem = true
         for _, key in ipairs(ElementColorKeys) do
           if not first_elem then file:write(',\n') end
           first_elem = false
           local v = (preset_data.element_colors and preset_data.element_colors[key]) or (Clr and Clr[key]) or 0
           file:write('      "' .. key .. '": ' .. tostring(v))
         end
         file:write('\n    }\n  }')
       end
       file:write('\n}\n')
       file:close()
     end
   end
 end

local function SaveStylePreset(name)
  if not OPEN.style_presets then
    OPEN.style_presets = {}
  end
  
  if OPEN.style_editor then
    OPEN.style_presets[name] = {
      vars = {},
      colors = {},
      element_colors = GetCustomClrPreset()
    }
    
    for i, value in pairs(OPEN.style_editor.style.colors) do
      OPEN.style_presets[name].colors[i] = value
    end
    
    -- Save to file
    SaveStylePresetsToFile()
  end
end

local function LoadStylePreset(name)
  if OPEN.style_presets and OPEN.style_presets[name] then
    if not OPEN.style_editor then
      OPEN.style_editor = { style = GetStyleData(), ref = GetStyleData(), output_dest = 0, output_prefix = 0, output_only_modified = true, push_count = 0 }
    end
    for i, value in pairs(OPEN.style_presets[name].colors) do
      OPEN.style_editor.style.colors[i] = value
    end
    ApplyCustomClrPreset(OPEN.style_presets[name].element_colors)
  end
end

-- Check if current style differs from the loaded preset
local function IsStyleDirty()
  local name = OPEN and OPEN.loaded_preset_name
  if not name then return false end
  local p = OPEN.style_presets and OPEN.style_presets[name]
  if not p or not OPEN.style_editor then return false end
  for i, v in pairs(p.colors or {}) do
    if OPEN.style_editor.style.colors[i] ~= v then return true end
  end
  local curElems = GetCustomClrPreset and GetCustomClrPreset()
  if p.element_colors and curElems then
    for k, v in pairs(curElems) do
      local pv = p.element_colors[k] or 0
      if pv ~= v then return true end
    end
  end
  return false
end

local function GetStylePresets()
  local presets = {}
  if OPEN.style_presets then
    for name, _ in pairs(OPEN.style_presets) do
      table.insert(presets, name)
    end
  end
  table.sort(presets)

  return presets
end

-- Global chosen preset (persists across restarts via ExtState)
local CHOSEN_PRESET_SECTION = 'FXD_StylePreset_Global'
local CHOSEN_PRESET_KEY = 'chosen_name'

local function SaveChosenPresetGlobal(name)
  if name and name ~= '' then
    r.SetExtState(CHOSEN_PRESET_SECTION, CHOSEN_PRESET_KEY, name, true)
  end
end

local function LoadChosenPresetGlobal()
  local val = r.GetExtState(CHOSEN_PRESET_SECTION, CHOSEN_PRESET_KEY)

  if val and val ~= '' then return val end
  local ok, projVal = r.GetProjExtState(0, CHOSEN_PRESET_SECTION, CHOSEN_PRESET_KEY)
  if ok == 1 and projVal and projVal ~= '' then return projVal end
  return nil
end

local function LoadStylePresetsFromFile()

  if not OPEN.style_presets then
    
    OPEN.style_presets = {}
  end
  
  -- 1) Prefer Lua file

    local lua_path = GetStylePresetsLuaPath()
    local chunk, load_err = loadfile(lua_path)
    if not chunk then
      local fh = io.open(lua_path, 'r')
      if fh then
        local src = fh:read('*all')
        fh:close()
        if src and #src > 0 then
          local chunk2, err2 = load(src, '@style_presets.lua')
          if chunk2 then
            chunk = chunk2
          end
        end
      end
    end

    if chunk then
      local ok, data = pcall(chunk)
      if ok and type(data) == 'table' then
        local loaded_count = 0
        for preset_name, preset_data in pairs(data) do
          if preset_data and type(preset_data) == 'table' and preset_data.vars and preset_data.colors then
            OPEN.style_presets[preset_name] = { vars = {}, colors = {}, element_colors = preset_data.element_colors }
            for k, v in pairs(preset_data.vars) do
              OPEN.style_presets[preset_name].vars[tonumber(k)] = v
            end
            for k, v in pairs(preset_data.colors) do
              OPEN.style_presets[preset_name].colors[tonumber(k)] = v
            end
            loaded_count = loaded_count + 1
          end
        end
        if loaded_count > 0 then return end
      end
    end

  
  -- 2) Fallback to JSON file (legacy)
  local file_path = GetStylePresetsJsonPath()
  local file = io.open(file_path, 'r')
  
  if file then
    local content = file:read('*all')
    file:close()
    
    local function parse_value(str)
      str = str:match('^%s*(.-)%s*$')
      
      local x, y = str:match('^%[(%d+%.?%d*),%s*(%d+%.?%d*)%]$')
      if x and y then
        return {tonumber(x), tonumber(y)}
      end
      
      local num = tonumber(str)
      if num then
        return num
      end
      
      local str_val = str:match('^"(.-)"$')
      if str_val then
        return str_val
      end
      
      return str
    end
    
    local pos = 1
    local function skip_whitespace()
      while pos <= #content and content:sub(pos, pos):match('%s') do
        pos = pos + 1
      end
    end
    
    local function parse_object()
      skip_whitespace()
      if content:sub(pos, pos) ~= '{' then return nil end
      pos = pos + 1
      
      local obj = {}
      skip_whitespace()
      
      while pos <= #content and content:sub(pos, pos) ~= '}' do
        skip_whitespace()
        if content:sub(pos, pos) == ',' then
          pos = pos + 1
          skip_whitespace()
        end
        
        local key_start = content:find('"', pos)
        if not key_start then break end
        local key_end = content:find('"', key_start + 1)
        if not key_end then break end
        
        local key = content:sub(key_start + 1, key_end - 1)
        pos = key_end + 1
        
        skip_whitespace()
        if content:sub(pos, pos) ~= ':' then break end
        pos = pos + 1
        
        local value_start = pos
        local brace_count = 0
        local bracket_count = 0
        local in_string = false
        local escape_next = false
        
        while pos <= #content do
          local char = content:sub(pos, pos)
          
          if escape_next then
            escape_next = false
          elseif char == '\\' then
            escape_next = true
          elseif char == '"' then
            in_string = not in_string
          elseif not in_string then
            if char == '{' then
              brace_count = brace_count + 1
            elseif char == '}' then
              if brace_count == 0 then break end
              brace_count = brace_count - 1
            elseif char == '[' then
              bracket_count = bracket_count + 1
            elseif char == ']' then
              bracket_count = bracket_count - 1
            elseif char == ',' and brace_count == 0 and bracket_count == 0 then
              break
            end
          end
          
          pos = pos + 1
        end
        
        local value_str = content:sub(value_start, pos - 1)
        
        if value_str:find('^{') then
          pos = value_start
          local nested_obj = parse_object()
          obj[key] = nested_obj
          if content:sub(pos, pos) == '}' then
            pos = pos + 1
          end
        else
          obj[key] = parse_value(value_str)
        end
        
        skip_whitespace()
      end
      
      if content:sub(pos, pos) == '}' then
        pos = pos + 1
      end
      
      return obj
    end
    
    local parsed = parse_object()
    if parsed then
      for preset_name, preset_data in pairs(parsed) do
        if preset_data.vars and preset_data.colors then
          OPEN.style_presets[preset_name] = {
            vars = {},
            colors = {},
            element_colors = preset_data.element_colors
          }
          
          for var_key, var_value in pairs(preset_data.vars) do
            local num_key = tonumber(var_key)
            if num_key then
              OPEN.style_presets[preset_name].vars[num_key] = var_value
            end
          end
          
          for color_key, color_value in pairs(preset_data.colors) do
            local num_key = tonumber(color_key)
            if num_key then
              OPEN.style_presets[preset_name].colors[num_key] = color_value
            end
          end
        end
      end
    end
  end
end

function EnsureStylePresetsLoaded()
    LoadStylePresetsFromFile()
   
   
end

EnsureStylePresetsLoaded()
CacheDefaultStylePreset()

if not OPEN.loaded_preset_name then
  local list = GetStylePresets()
  local saved = LoadChosenPresetGlobal()

  local picked = nil
  if saved and #list > 0 then
    for _, nm in ipairs(list) do if nm == saved then picked = nm break end end
  end
  if not picked and #list > 0 then picked = list[1] end
  if picked then
    OPEN.loaded_preset_name = picked
    for idx, nm in ipairs(list) do if nm == picked then OPEN.selected_preset_index = idx - 1 break end end
    LoadStylePreset(OPEN.loaded_preset_name)
  end
end

local function DeleteStylePreset(name)
  if OPEN.style_presets then
    OPEN.style_presets[name] = nil
    SaveStylePresetsToFile()
  end
end

local function RescanPluginList()
  if type(MakeFXFiles) == 'function' then
    FX_LIST, CAT = MakeFXFiles()
  end
  FX_LIST = FX_LIST or {}
  -- Rebuild category lookup after FX_LIST is updated
  BuildFXListCategoryLookup()
  if type(SelectionCounts) == 'table' then
    local present = {}
    for i = 1, #FX_LIST do present[FX_LIST[i]] = true end
    for name in pairs(SelectionCounts) do
      if not present[name] then SelectionCounts[name] = nil end
    end
    if type(SavePluginCounts) == 'function' then SavePluginCounts() end
  end
end

local function LicenseSettingsTab(ctx)
  im.SeparatorText(ctx, 'License Verification')

  if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
    -- Show license key info
    im.Text(ctx, 'License Key:')
    im.SameLine(ctx)
    im.TextColored(ctx, im.GetStyleColor(ctx, im.Col_CheckMark), LicenseState.licenseKey)
    
    im.Spacing(ctx)
    
    -- Status display
    local statusText = LicenseStatusText()
    if not statusText or statusText == '' then
      statusText = LicenseState.status or 'Unknown'
    end
    
    im.Text(ctx, 'License Status:')
    im.SameLine(ctx)
    
    -- Determine color based on status
    local statusColor = 0xFFFFFFFF -- Default white
    if LicenseState.status == 'expired' or LicenseState.status == 'inactive' then
      statusColor = 0xFF4444FF -- Red
    elseif LicenseState.status == 'trial' then
      statusColor = 0xFFFF44FF -- Yellow
    elseif LicenseState.status == 'active' then
      statusColor = 0x5EFF63FF -- Green
    end
    
    -- Display the status text with color
    im.TextColored(ctx, statusColor, statusText)

    if LicenseState.expiresAt then
      im.Text(ctx, 'Expires:')
      im.SameLine(ctx)
      im.Text(ctx, FormatExpiry(LicenseState.expiresAt))
    end

    if LicenseState.reason and LicenseState.reason ~= '' and LicenseState.status == 'inactive' then
      im.Spacing(ctx)
      im.TextColored(ctx, 0xFF4444FF, 'Note: ' .. LicenseState.reason)
    end

    im.Spacing(ctx)

    -- Verify button
    local disabled = LicenseState.checking
    if disabled and im.BeginDisabled then im.BeginDisabled(ctx, true) end
    if im.Button(ctx, LicenseState.checking and 'Checking...' or 'Verify License') then
      local success, msg = VerifyLicense(LicenseState.licenseKey)
      if not success then
        r.ShowMessageBox('License verification failed:\n\n' .. (msg or 'Unknown error'), 'License Verification', 0)
      end
    end
    if disabled and im.EndDisabled then im.EndDisabled(ctx) end
    
    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)
    
    if im.Button(ctx, 'Remove License Key') then
      LicenseState.licenseKey = nil
      SetLicenseResult('inactive', nil, 'License key removed', nil)
    end
    
    im.Spacing(ctx)
    im.Text(ctx, 'Device ID:')
    im.SameLine(ctx)
    im.Text(ctx, LicenseState.deviceId or 'Not generated')
  else
    -- No license key - show input UI
    im.Text(ctx, 'Enter your license key to activate:')
    im.Spacing(ctx)
    
    WithTypingGuard(function()
      im.PushItemWidth(ctx, 400)
      local licenseKey = OPEN.temp_license_key or ''
      local changed, new_key = im.InputText(ctx, '##license_key', licenseKey, 256)
      im.PopItemWidth(ctx)
      if changed then
        OPEN.temp_license_key = new_key
        licenseKey = new_key
      end
      
      im.Spacing(ctx)
      if im.Button(ctx, 'Activate License') and licenseKey ~= '' then
        local success, msg = VerifyLicense(licenseKey)
        if success then
          OPEN.temp_license_key = nil
        else
          r.ShowMessageBox('License activation failed:\n\n' .. (msg or 'Unknown error'), 'License Activation', 0)
        end
      end
    end)
  end

  im.Spacing(ctx)
  im.TextWrapped(ctx, 'License verification connects to our server to check if your license key is valid and not activated on more than 3 devices simultaneously.')

  -- Lightweight auto-check (once per interval) when tab is visible
  if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
    MaybeAutoVerifyLicense()
  end
end

local function SettingsWindow()
  -- Detect close attempts
  local prevOpen = OPEN.Settings and true or false
  -- Store the window open state
  Settings_Visible, OPEN.Settings =  im.Begin(ctx, 'Settings', OPEN.Settings, im.WindowFlags_None)
  if Settings_Visible then
    -- If user clicked the close button, and current preset is dirty, prompt to save and keep window open
    do
      local function IsCurrentPresetDirty()
        local name = OPEN and OPEN.loaded_preset_name
        if not name or not OPEN or not OPEN.style_editor or not OPEN.style_presets then return false end
        local p = OPEN.style_presets[name]
        if not p then return false end
        for i, v in pairs(p.colors or {}) do
          if OPEN.style_editor.style.colors[i] ~= v then return true end
        end
        local curElems = GetCustomClrPreset and GetCustomClrPreset()
        if p.element_colors and curElems then
          for k, v in pairs(curElems) do
            local pv = p.element_colors[k] or 0
            if pv ~= v then return true end
          end
        end
        return false
      end
      if prevOpen and (OPEN.Settings == false) and IsCurrentPresetDirty() then

        OPEN.Settings = true -- keep open
        OPEN.prompt_save_style_changes = true
        OPEN.prompt_save_style_changes_CLOSEWIN = true
      end
    end
    -- reset per-frame flag; we'll set it true if Style Editor tab is active
    OPEN.style_editor_tab_active_this_frame = nil
    -- Initialize settings tab state
    if not OPEN.settings_tab then
      OPEN.settings_tab = 0
    end
    
    -- Tab bar for different settings sections
    if im.BeginTabBar(ctx, 'SettingsTabs', im.TabBarFlags_None) then
      
      -- General Settings Tab
      local wantSwitchTabs = false
      if im.BeginTabItem(ctx, 'General') then
        -- Display Options
        im.SeparatorText(ctx, 'Display Options')
        local rv, v = im.Checkbox(ctx, 'Shorten FX names (remove text in parentheses)', OPEN.ShortenFXNames and true or false)
        if rv then OPEN.ShortenFXNames = v and true or false; SaveOpenState() end

        local rv2, v2 = im.Checkbox(ctx, 'Show button to unhide hidden parents', OPEN.ShowHiddenParents and true or false)
        if rv2 then
          OPEN.ShowHiddenParents = v2 and true or false
          SaveGlobalBool('ShowHiddenParents', OPEN.ShowHiddenParents)
        end
        
        local rv3, v3 = im.Checkbox(ctx, 'Show pan knobs for sends/receives', ShowSendPanKnobs and true or false)
        if rv3 then
          ShowSendPanKnobs = v3 and true or false
          SaveGlobalBool('ShowSendPanKnobs', ShowSendPanKnobs)
        end
        
        local rv4, v4 = im.Checkbox(ctx, 'Show favorite FXs under search bar', ShowFavoritesUnderSearchBar and true or false)
        if rv4 then
          ShowFavoritesUnderSearchBar = v4 and true or false
          SaveGlobalBool('ShowFavoritesUnderSearchBar', ShowFavoritesUnderSearchBar)
        end
        
        -- Hidden parent button size
        local minH, maxH = 3, 30
        local curH = Folder_Btn_Compact or 5
        im.PushItemWidth(ctx, 180)
        local changed, newH = im.SliderInt(ctx, 'Hidden parent button height', curH, minH, maxH, '%d px')
        im.PopItemWidth(ctx)
        if changed then
          Folder_Btn_Compact = newH
          SaveGlobalNumber('HiddenParentBtnH', Folder_Btn_Compact)
        end
        
        im.Separator(ctx)
        
        -- Layout Settings
        im.SeparatorText(ctx, 'Layout Settings')
        -- Monitor FX columns (global)
        do
          local curCols = MonitorFX_Columns or 1
          im.PushItemWidth(ctx, 180)
          local chg, newCols = im.SliderInt(ctx, 'Monitor FX columns', curCols, 1, 6, '%d')
          im.PopItemWidth(ctx)
          if chg then
            if newCols < 1 then newCols = 1 end
            if newCols > 6 then newCols = 6 end
            MonitorFX_Columns = newCols
            SaveGlobalNumber('MonitorFX_Columns', MonitorFX_Columns)
          end
        end
        
        im.Separator(ctx)
        
        -- Animation Settings
        im.SeparatorText(ctx, 'Animation Settings')
        -- FX delete animation speed (global)
        do
          local stepInt = math.floor((DELETE_ANIM_STEP or 0.750) * 1000 + 0.5)
          local minStep, maxStep = 100, 1600 -- 0.100 .. 1.600 per frame
          im.PushItemWidth(ctx, 220)
          local chg, newInt = im.SliderInt(ctx, 'FX delete animation speed', stepInt, minStep, maxStep, '%d (x0.001)')
          im.PopItemWidth(ctx)
          if chg then
            if newInt < minStep then newInt = minStep end
            if newInt > maxStep then newInt = maxStep end
            SaveGlobalNumber('FXDeleteAnimStep', newInt)
            DELETE_ANIM_STEP = newInt / 1000
          end
        end
        -- Send delete animation speed (global, wide range)
        do
          local stepInt = math.floor((SEND_DELETE_ANIM_STEP or 0.750) * 1000 + 0.5)
          -- Allow very slow: down to 10% of current default (0.075), and very fast up to 3.000
          local minStep, maxStep = 75, 3000 -- 0.075 .. 3.000 per frame
          im.PushItemWidth(ctx, 220)
          local chg, newInt = im.SliderInt(ctx, 'Send delete animation speed', stepInt, minStep, maxStep, '%d (x0.001)')
          im.PopItemWidth(ctx)
          if chg then
            if newInt < minStep then newInt = minStep end
            if newInt > maxStep then newInt = maxStep end
            SaveGlobalNumber('SendDeleteAnimStep', newInt)
            SEND_DELETE_ANIM_STEP = newInt / 1000
          end
        end
        
        im.Separator(ctx)
        
        -- Plugin Management
        im.SeparatorText(ctx, 'Plugin Management')
        PluginTypeOrder_DragDrop()
        -- Rescan installed plugins for FX adder
        local accentBase = Clr.SelectionOutline or 0x289F81ff
        im.PushStyleColor(ctx, im.Col_Button, accentBase)
        im.PushStyleColor(ctx, im.Col_ButtonHovered, deriveHover(accentBase))
        im.PushStyleColor(ctx, im.Col_ButtonActive, deriveActive(accentBase))
        if im.Button(ctx, 'Rescan plugin list') then
          RescanPluginList()
        end
        im.PopStyleColor(ctx, 3)
        im.SameLine(ctx, 0, 10)
        im.Text(ctx, string.format('Plugins indexed: %d', (FX_LIST and #FX_LIST or 0)))
        
        im.Separator(ctx)
        
        -- Test Link Section
        im.SeparatorText(ctx, 'Test Link')
        im.Text(ctx, 'Click the link below to test opening a webpage:')
        ShowLink(ctx, 'https://www.reaper.fm', 'Visit REAPER Website')
        
        im.EndTabItem(ctx)
      end
      
      -- License Tab
      if im.BeginTabItem(ctx, 'License') then
        LicenseSettingsTab(ctx)
        im.EndTabItem(ctx)
      end
      
      -- Keyboard Shortcuts Tab
      if im.BeginTabItem(ctx, 'Keyboard Shortcuts') then
        im.Text(ctx,'Click a button, then press the new key combination')
        im.Separator(ctx)
        -- Search/filter (modeled after Style Editor color filter)
        OPEN.shortcuts_ui = OPEN.shortcuts_ui or {}
        OPEN.shortcuts_ui.filter_text = OPEN.shortcuts_ui.filter_text or ''
        do
          im.PushStyleVar(ctx, im.StyleVar_FramePadding, 6, 6)
          im.PushStyleColor(ctx, im.Col_Button, getClr(im.Col_Button))
          im.PushStyleColor(ctx, im.Col_ButtonActive, getClr(im.Col_Button))
          im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_Button))
          local ln = im.GetTextLineHeight(ctx)
          local iconSz = ln
          im.PushFont(ctx, Font_Andale_Mono_13)
          if Img and Img.Search then
            im.ImageButton(ctx, '##ShortcutFilterIcon', Img.Search, iconSz, iconSz)
          end
          im.PopStyleColor(ctx,3)
          im.SameLine(ctx, nil, 0)
          im.PushItemWidth(ctx, 460)
          WithTypingGuard(function()
            local changed, txt = im.InputText(ctx, '##ShortcutFilter', OPEN.shortcuts_ui.filter_text or '', 256)
            if changed then OPEN.shortcuts_ui.filter_text = txt end
          end)
          local L, T = im.GetItemRectMin(ctx)
          local R, B = im.GetItemRectMax(ctx)
          local dl = im.GetWindowDrawList(ctx)
          local colDim = getClr(im.Col_TextDisabled)
          if (OPEN.shortcuts_ui.filter_text or '') == '' and not im.IsItemActive(ctx) then
            im.DrawList_AddText(dl, L + 4, T + 2, colDim, 'type here to filter shortcuts')
          end
          im.PopFont(ctx)
          im.PopStyleVar(ctx)
          im.PopItemWidth(ctx)
        end
        im.Separator(ctx)
        -- Child wrapping the table
        local child_flags = (im.ChildFlags_Border or 0) | (im.ChildFlags_NavFlattened or 0)
        if im.BeginChild(ctx, 'ShortcutsChild', 0, 280, nil, child_flags) then
          local tblFlags = (im.TableFlags_BordersInnerV or 0) | (im.TableFlags_Resizable or 0) | (im.TableFlags_SizingStretchProp or 0)
          if im.BeginTable(ctx, 'ShortcutsTable', 3, tblFlags) then
            if im.TableSetupColumn then
              im.TableSetupColumn(ctx, 'Context', (im.TableColumnFlags_WidthFixed or 0), 90)
              im.TableSetupColumn(ctx, 'Action', (im.TableColumnFlags_WidthStretch or 0))
              im.TableSetupColumn(ctx, 'Binding', (im.TableColumnFlags_WidthFixed or 0), 220)
              im.TableHeadersRow(ctx)
            end
            -- Build stable list of actions
            local list = {}
            for act,_ in pairs(Shortcuts) do list[#list+1] = act end
            table.sort(list)
            local filter = (OPEN.shortcuts_ui.filter_text or ''):lower()
            for _,act in ipairs(list) do
              if filter == '' or string.find(act:lower(), filter, 1, true) then
                im.TableNextRow(ctx)
                -- Badge column
                local clr1 = 0xAB3C0BFF
                local clr2 = 0xAB990BFF
                im.TableSetColumnIndex(ctx, 0)
                if act == 'HoverSendSoloTrack' or act == 'HoverSendSoloSend' then
                  im.PushStyleVar(ctx, im.StyleVar_FramePadding, 2, 2)
                  im.PushStyleColor(ctx, im.Col_Button, Change_Clr_A( clr1, 0.14))
                  im.PushStyleColor(ctx, im.Col_ButtonHovered, Change_Clr_A( clr1, 0.20))
                  im.PushStyleColor(ctx, im.Col_ButtonActive, Change_Clr_A( clr1, 0.26))
                  im.SmallButton(ctx, 'Send')
                  im.PopStyleColor(ctx,3)
                  im.PopStyleVar(ctx)
                elseif act == 'ExpandTrack' then
                  im.PushStyleVar(ctx, im.StyleVar_FramePadding, 2, 2)
                  im.PushStyleColor(ctx, im.Col_Button, Change_Clr_A(clr2, 0.14))
                  im.PushStyleColor(ctx, im.Col_ButtonHovered, Change_Clr_A(clr2, 0.20))
                  im.PushStyleColor(ctx, im.Col_ButtonActive, Change_Clr_A(clr2, 0.26))
                  im.SmallButton(ctx, 'Track')
                  im.PopStyleColor(ctx,3)
                  im.PopStyleVar(ctx)
                else
                  im.Dummy(ctx, 1, 1)
                end
                -- Action name column
                im.TableSetColumnIndex(ctx, 1)
                im.AlignTextToFramePadding(ctx)
                im.Text(ctx, act)
                -- Binding column
                im.TableSetColumnIndex(ctx, 2)
                im.PushID(ctx, act)
                local label = waitingForBind==act and 'Press...' or KeyDesc(Shortcuts[act])
                if im.Button(ctx, label, -1) then waitingForBind = act end
                -- capture new binding
                if waitingForBind == act then
                  local modsNow = im.GetKeyMods(ctx)
                  for _,key in ipairs(NamedKeyList) do
                    if key and im.IsKeyPressed(ctx, key) then
                      Shortcuts[act] = { key = key, mods = modsNow }
                      SaveShortcuts()
                      waitingForBind = nil
                      break
                    end
                  end
                end
                im.PopID(ctx)
              end
            end
            im.EndTable(ctx)
          end
          im.EndChild(ctx)
        end
        im.EndTabItem(ctx)
      end
      
      -- Style Editor Tab
      local tryingOpenStyleEditor = im.BeginTabItem(ctx, 'Style Editor')
      if tryingOpenStyleEditor then
        OPEN.style_editor_tab_active_this_frame = true
        -- Ensure presets are loaded when opening this tab
        --[[ EnsureStylePresetsLoaded() ]]
        
        -- Apply style live while editing in Style Editor
        if OPEN.style_editor then OPEN.style_editor.disabled = nil end
        
        -- One-time init: select default preset in dropdown on first open of this tab
        if not OPEN.style_editor_dropdown_initialized then
          EnsureStylePresetsLoaded()
          local list = GetStylePresets()
          if (not OPEN.loaded_preset_name) and #list > 0 then
            OPEN.loaded_preset_name = list[1]
            OPEN.selected_preset_index = 0
            LoadStylePreset(OPEN.loaded_preset_name)
          end
          OPEN.style_editor_dropdown_initialized = true
        end

        -- Style preset controls (larger heading)
        do
          im.PushFont(ctx, Font_Andale_Mono_14)
          im.SeparatorText(ctx, 'Style Presets')
          im.PopFont(ctx)
        im.Separator(ctx)
        end
        
        -- Preset selection and controls
        local presets = GetStylePresets()
        if not OPEN.selected_preset_index then OPEN.selected_preset_index = 0 end
        if OPEN.selected_preset_index >= #presets then OPEN.selected_preset_index = 0 end

        -- Track currently loaded preset name
        if not OPEN.loaded_preset_name and #presets > 0 and OPEN.selected_preset_index >= 0 then
          OPEN.loaded_preset_name = presets[OPEN.selected_preset_index + 1]
        end

        local function IsDirtyAgainstPreset(name)
          if not name then return false end
          local p = OPEN.style_presets and OPEN.style_presets[name]
          if not p or not OPEN.style_editor then return false end
          -- Compare ImGui colors
          for i, v in pairs(p.colors or {}) do
            if OPEN.style_editor.style.colors[i] ~= v then return true end
          end
          -- Compare element-specific colors
          local curElems = GetCustomClrPreset()
          if p.element_colors and curElems then
            for k, v in pairs(curElems) do
              local pv = p.element_colors[k] or 0
              if pv ~= v then return true end
            end
          end
          return false
        end

        -- Preview label with dirty suffix (only in preview, not in dropdown items)

        local preview = OPEN.loaded_preset_name or ''
        if preview ~= '' and IsDirtyAgainstPreset(preview) then
          preview = preview .. ' *Edited*'
        end

        im.PushItemWidth(ctx, 250)
        if im.BeginCombo(ctx, '##PresetCombo', preview, im.ComboFlags_None) then
          local ln = im.GetTextLineHeight(ctx)
          local tblFlags = (im.TableFlags_SizingStretchProp or 0) | (im.TableFlags_NoPadInnerX or 0) | (im.TableFlags_NoPadOuterX or 0)
          if im.BeginTable(ctx, 'PresetComboTable', 2, tblFlags) then
            if im.TableSetupColumn then
              im.TableSetupColumn(ctx, 'Name', (im.TableColumnFlags_WidthStretch or 0))
              im.TableSetupColumn(ctx, 'Del',  (im.TableColumnFlags_WidthFixed or 0), ln + 6)
            end
            for i, name in ipairs(presets) do
              im.TableNextRow(ctx)
              -- Column 1: selectable label
              im.TableSetColumnIndex(ctx, 0)
              local isSel = (OPEN.loaded_preset_name == name)
              local chosen = im.Selectable(ctx, name, isSel)
              -- Column 2: trash icon
              im.TableSetColumnIndex(ctx, 1)
              if Img and Img.Trash then
                -- dim unless hovered
                local hovered = im.IsItemHovered and im.IsItemHovered(ctx) -- will re-evaluate after placing button
                -- we need to place button first to evaluate hover; so compute tint by checking mouse pos in cell rect
                local cellL, cellT = im.GetCursorScreenPos(ctx)
                local cellR = cellL + ln
                local cellB = cellT + ln
                local isHvr = im.IsMouseHoveringRect(ctx, cellL, cellT, cellR, cellB)
                local tint = isHvr and 0xffffffff or 0x55555577
                im.PushStyleColor(ctx, im.Col_Button, 0x00000022)
                im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000022)

                if im.ImageButton(ctx, '##del_' .. name, Img.Trash, ln, ln, nil, nil, nil, nil, nil, tint) then
                  OPEN.confirm_delete_preset = name
                  OPEN.open_confirm_delete_next_frame = true
                  if im.CloseCurrentPopup then im.CloseCurrentPopup(ctx) end
                end
                im.PopStyleColor(ctx,2)
              else
                im.Dummy(ctx, ln, ln)
              end
              if chosen then
                OPEN.selected_preset_index = i - 1
                OPEN.loaded_preset_name = name
                LoadStylePreset(name)
                SaveChosenPresetGlobal(name)
              end
            end
            im.EndTable(ctx)
          else
            -- Fallback simple list
            for i, name in ipairs(presets) do
              local isSel = (OPEN.loaded_preset_name == name)
              local label = name
              if IsDirtyAgainstPreset(name) then label = label .. ' *Edited*' end
              if im.Selectable(ctx, label, isSel) then
                OPEN.selected_preset_index = i - 1
                OPEN.loaded_preset_name = name
                LoadStylePreset(name)
                SaveChosenPresetGlobal(name)
              end
            end
          end
          im.EndCombo(ctx)
        end
        im.PopItemWidth(ctx)

        -- Defer opening modal after combo has closed or on settings close
        if OPEN.open_confirm_delete_next_frame then
          -- Place the modal near the mouse cursor
          local mx, my = im.GetMousePos(ctx)
          im.SetNextWindowPos(ctx, mx, my, im.Cond_Always)
          im.OpenPopup(ctx, '##ConfirmDeletePreset')
          OPEN.open_confirm_delete_next_frame = nil
        end
        if OPEN.prompt_preset_dirty then
          local mx, my = im.GetMousePos(ctx)
          im.SetNextWindowPos(ctx, mx, my, im.Cond_Always)
          im.OpenPopup(ctx, '##SaveStyleChanges')
          OPEN.prompt_preset_dirty = nil
        end
        -- Confirm delete modal
        if im.BeginPopupModal and im.BeginPopupModal(ctx, '##ConfirmDeletePreset', true, (im.WindowFlags_AlwaysAutoResize or 0)) then
          local name = OPEN.confirm_delete_preset
          im.Text(ctx, 'Delete preset "' .. tostring(name or '') .. '"? This cannot be undone.')
          im.Separator(ctx)
          -- Space out buttons
          if im.Button(ctx, 'Cancel') then
            OPEN.confirm_delete_preset = nil
            im.CloseCurrentPopup(ctx)
          end
          im.SameLine(ctx, nil, 10)
          if im.Button(ctx, 'Delete') then
            if name then
              DeleteStylePreset(name)
              -- If we deleted the chosen preset, clear global saved value
              local saved = LoadChosenPresetGlobal()
              if saved == name then SaveChosenPresetGlobal('') end
              if OPEN.loaded_preset_name == name then OPEN.loaded_preset_name = nil end
              OPEN.selected_preset_index = 0
            end
            OPEN.confirm_delete_preset = nil
            im.CloseCurrentPopup(ctx)
          end
          im.EndPopup(ctx)
        end


        -- Save and Save As controls
        local canSave = OPEN.loaded_preset_name and IsDirtyAgainstPreset(OPEN.loaded_preset_name)
        im.SameLine(ctx,nil,10)
        if not canSave and im.BeginDisabled then im.BeginDisabled(ctx) end
        if im.Button(ctx, 'Save') and canSave then
          SaveStylePreset(OPEN.loaded_preset_name)
        end
        if not canSave and im.EndDisabled then im.EndDisabled(ctx) end
        
        im.SameLine(ctx, nil, 10)
        if im.Button(ctx, 'Save As...') then
          OPEN.new_preset_name = OPEN.new_preset_name or ''
          OPEN.open_save_as_next_frame = true
        end
        -- Open Save As modal next frame at mouse position
        if OPEN.open_save_as_next_frame then
          local mx, my = im.GetMousePos(ctx)
          im.SetNextWindowPos(ctx, mx, my, im.Cond_Always)
          im.OpenPopup(ctx, '##SaveAsPreset')
          OPEN.open_save_as_next_frame = nil
        end
        if im.BeginPopupModal and im.BeginPopupModal(ctx, '##SaveAsPreset', true, (im.WindowFlags_AlwaysAutoResize or 0)) then
          im.Text(ctx, 'Preset name:')
          im.SameLine(ctx)
          WithTypingGuard(function()
            local rv, new_name = im.InputText(ctx, '##SaveAsName', OPEN.new_preset_name or '', 256)
            if rv then OPEN.new_preset_name = new_name end
          end)
          im.Separator(ctx)
          if im.Button(ctx, 'Cancel') then
            im.CloseCurrentPopup(ctx)
          end
          im.SameLine(ctx, nil, 10)
          if im.Button(ctx, 'Save') and OPEN.new_preset_name and OPEN.new_preset_name ~= '' then
            SaveStylePreset(OPEN.new_preset_name)
            OPEN.loaded_preset_name = OPEN.new_preset_name
            local list2 = GetStylePresets()
            for idx, nm in ipairs(list2) do if nm == OPEN.loaded_preset_name then OPEN.selected_preset_index = idx - 1 break end end
            SaveChosenPresetGlobal(OPEN.loaded_preset_name)
            OPEN.new_preset_name = ''
            im.CloseCurrentPopup(ctx)
          end
          im.EndPopup(ctx)
        end

        -- removed default badge and Set Default button
        
        -- Removed legacy "Save Current Style" section
        
        -- Style Editor
        ShowStyleEditor()
        
        -- Keep style push enabled so changes remain visible immediately
        if OPEN.style_editor then OPEN.style_editor.disabled = nil end
        
        im.EndTabItem(ctx)
      end

      -- Detect tab switching away from Style Editor (dirty prompt)
      do
        OPEN._style_editor_was_active = OPEN._style_editor_was_active or false
        local was = OPEN._style_editor_was_active
        local now = OPEN.style_editor_tab_active_this_frame and true or false
        if was and not now and IsStyleDirty() then
          OPEN.prompt_save_style_changes = true
        end
        OPEN._style_editor_was_active = now
      end
      
      im.EndTabBar(ctx)
    end
    -- Persist whether Style Editor tab was open this frame for next frame's logic
    OPEN.style_editor_tab_open = OPEN.style_editor_tab_active_this_frame and true or nil
    
    -- Always call End regardless of the window's open state
    -- If settings window is closing and style is dirty, show prompt
    if not Settings_Visible and IsStyleDirty() then
      OPEN.prompt_save_style_changes = true
    end
    -- Render modal prompt if requested
    if OPEN.prompt_save_style_changes then
      local mx, my = im.GetMousePos(ctx)
      im.SetNextWindowPos(ctx, mx, my, im.Cond_Always)
      im.OpenPopup(ctx, '##SaveStyleChanges')
      OPEN.prompt_save_style_changes = nil
    end
    if im.BeginPopupModal and im.BeginPopupModal(ctx, '##SaveStyleChanges', true, (im.WindowFlags_AlwaysAutoResize or 0) | (im.WindowFlags_NoTitleBar or 0)) then
      local curName = OPEN.loaded_preset_name or ''
      local function close()
        if OPEN.prompt_save_style_changes_CLOSEWIN then
          OPEN.Settings = nil
          OPEN.prompt_save_style_changes_CLOSEWIN = nil 
        end
      end
      -- Editable name field (if changed, Save becomes Save As)
      OPEN._dirty_modal_name = OPEN._dirty_modal_name or curName
      im.Text(ctx, 'You have unsaved style changes. Save them?')
      WithTypingGuard(function()

        local rv, new_name = im.InputText(ctx, '##DirtyPresetName', OPEN._dirty_modal_name, 256)
        if rv then OPEN._dirty_modal_name = new_name end
      end)
      im.Separator(ctx)
      -- Buttons on one line: Save | Discard
      local nameToSave = (OPEN._dirty_modal_name or '')
      local targetName = (nameToSave ~= '' and nameToSave) or curName
      local canSave = targetName ~= ''
      if not canSave and im.BeginDisabled then im.BeginDisabled(ctx) end
      local SaveBtnTxt = OPEN._dirty_modal_name ==OPEN.loaded_preset_name and 'Save (overwrite '..OPEN.loaded_preset_name..')' or 'Save'
      if im.Button(ctx, SaveBtnTxt) and canSave then
        SaveStylePreset(targetName)
        OPEN.loaded_preset_name = targetName
        local list2 = GetStylePresets()
        for idx, nm in ipairs(list2) do if nm == OPEN.loaded_preset_name then OPEN.selected_preset_index = idx - 1 break end end
        SaveChosenPresetGlobal(OPEN.loaded_preset_name)
        OPEN._dirty_modal_name = nil
        im.CloseCurrentPopup(ctx)
        close()
      end
      if not canSave and im.EndDisabled then im.EndDisabled(ctx) end
      im.SameLine(ctx, nil, 10)
      if im.Button(ctx, 'Discard') then
        OPEN._dirty_modal_name = nil
        -- Reload the saved preset to discard changes
        if OPEN and OPEN.loaded_preset_name and OPEN.loaded_preset_name ~= '' then
          LoadStylePreset(OPEN.loaded_preset_name)
        end
        im.CloseCurrentPopup(ctx)
        close()
      end
      im.EndPopup(ctx)
      
    end

    im.End(ctx)
  end
  -- If settings window not visible, Style Editor cannot be open
  if not Settings_Visible then OPEN.style_editor_tab_open = nil end
  

end

-- duplicate guard removed; using global WithTypingGuard defined earlier

function KeyboardShortcuts()
  -- Suppress when typing in any text field
  if not im.IsAnyItemActive(ctx) and not TypingInTextField then
    -- play/stop via spacebar remains hard-wired
    if im.IsKeyPressed(ctx, im.Key_Space) then
      r.Main_OnCommand(r.NamedCommandLookup(40044), 0)
    end

    function ExpandTrackHeight(track)
      if not track then return end
    
      -- Calculate total height needed for all FX and sends
      local fx_count = r.TrackFX_GetCount(track)
      local send_count = r.GetTrackNumSends(track, 0)  -- 0 for sends, -1 for receives
      local send_count = send_count +  r.GetTrackNumSends(track, -1)  -- 0 for sends, -1 for receives
      local item_height = 15  -- Approximate height per FX/send item
      local padding = 10      -- Additional padding
      -- Use the larger of FX or Send count (when sends are shown)
      local item_count = math.max(fx_count, (OPEN and OPEN.ShowSends and send_count or 0))
      local target_height = item_count * item_height + padding
      -- Set track height (minimum 100 pixels, maximum 1000 pixels)
      target_height = math.max(100, math.min(1000, target_height))
      r.SetMediaTrackInfo_Value(track, "I_HEIGHTOVERRIDE", target_height)
      reaper.TrackList_AdjustWindows(false)
    end
    
    -- First: handle hover-based send solo shortcuts so they don't conflict with general S bindings
    local keyHandled = false
    do
      local scTrack = Shortcuts.HoverSendSoloTrack
      local scSend  = Shortcuts.HoverSendSoloSend
      local modsNow = im.GetKeyMods(ctx)
      -- Normalize Ctrl/Cmd equivalence for macOS when user expects Ctrl+S behavior
      local function modsMatch(required, actual)
        if required == (actual or 0) then return true end
        if IS_MAC and required == im.Mod_Ctrl and (actual or 0) == im.Mod_Super then return true end
        if IS_MAC and required == im.Mod_Super and (actual or 0) == im.Mod_Ctrl then return true end
        return false
      end
      -- both actions share the same key by default (S) with different modifiers; check distinctly
      if scTrack and im.IsKeyPressed(ctx, scTrack.key) and modsMatch(scTrack.mods or 0, modsNow) then
        if HoverSend and HoverSend_Src and HoverSend_Dest then
          ToggleSolo(HoverSend_Dest)
          keyHandled = true
        end
      elseif scSend and im.IsKeyPressed(ctx, scSend.key) and modsMatch(scSend.mods or 0, modsNow) then
        if HoverSend and HoverSend_Src and HoverSend_Index ~= nil then
          local Track = HoverSend_Src
          local i = HoverSend_Index
          local NumSends = r.GetTrackNumSends(Track, 0)
          if NumSends and NumSends > 1 then
            Trk = Trk or {}
            local TrkID = r.GetTrackGUID(Track)
            Trk[TrkID] = Trk[TrkID] or {}
            Trk[TrkID].alreadyMutedSend = Trk[TrkID].alreadyMutedSend or {}
            local unmute
            for S = 0, NumSends - 1, 1 do
              if i ~= S then
                Trk[TrkID].alreadyMutedSend[S] = Trk[TrkID].alreadyMutedSend[S] or r.GetTrackSendInfo_Value(Track, 0, S, 'B_MUTE')
              end
            end
            for S = 0, NumSends - 1, 1 do
              if i ~= S then
                if r.GetTrackSendInfo_Value(Track, 0, S, 'B_MUTE') == 1 and Trk[TrkID].alreadyMutedSend[S] == 0 then
                  r.SetTrackSendInfo_Value(Track, 0, S, 'B_MUTE', 0)
                  unmute = true
                else
                  r.SetTrackSendInfo_Value(Track, 0, S, 'B_MUTE', 1)
                end
              end
            end
            if unmute then Trk[TrkID].alreadyMutedSend = {} end
            keyHandled = true
          end
        end
      end
    end

    local actions = {
      ToggleSends     = function() OPEN.ShowSends = toggle(OPEN.ShowSends); SaveOpenState() end,
      ToggleSnapshots = function() OPEN.Snapshots = toggle(OPEN.Snapshots); SaveOpenState() end,
      ToggleMonitorFX = function() OPEN.MonitorFX = toggle(OPEN.MonitorFX); SaveOpenState() end,
      ExpandTrack     = function()

      end,
    }
    if not keyHandled then
      for act,fn in pairs(actions) do
        local sc = Shortcuts[act]
        if sc and im.IsKeyPressed(ctx, sc.key) and im.GetKeyMods(ctx) == (sc.mods or 0) then
          fn()
        end
      end
    end
  end
end

function ApplyColors(ctx)
im.PushStyleColor(ctx, im.Col_FrameBg, Clr.FrameBG)
im.PushStyleColor(ctx, im.Col_FrameBgHovered, Clr.FrameBGHvr)
im.PushStyleColor(ctx, im.Col_FrameBgActive, Clr.FrameBGAct)


im.PushStyleColor(ctx, im.Col_Button, Clr.Buttons)
im.PushStyleColor(ctx, im.Col_ButtonHovered, Clr.ButtonsHvr)
im.PushStyleColor(ctx, im.Col_ButtonActive, Clr.ButtonsAct)

im.PushStyleColor(ctx, im.Col_SliderGrab, Clr.SliderGrb)
im.PushStyleColor(ctx, im.Col_SliderGrabActive, Clr.SliderGrbAct)




return 8
end

local function ApplyDefaultStylePresetIfAny()
  -- Only apply default when explicitly requested via flag
  if not OPEN.apply_default_style_next_frame then return end

  -- Ensure our cached copy is up-to-date with the chosen default
  local currentName = OPEN.style_default_preset
  if (not currentName or currentName == '') and OPEN.style_presets and OPEN.style_presets['default'] then
    currentName = 'default'
  end
  -- defaults removed; skip refreshing cache

  if Cached_Default_StylePreset then
    if not OPEN.style_editor then
  OPEN.style_editor = { style = GetStyleData(), ref = GetStyleData(), output_dest = 0, output_prefix = 0, output_only_modified = true, push_count = 0 }
    end
    CopyStyleData(Cached_Default_StylePreset, OPEN.style_editor.style)
    -- Apply element-specific colors if present on default preset
    if Cached_Default_StylePreset.element_colors then
      ApplyCustomClrPreset(Cached_Default_StylePreset.element_colors)
    end
    OPEN.apply_default_style_next_frame = nil
  end
end
----------====================================================================================================
local _0x8f9a = 0
local _0x9b0c = 300

function loop()

--[[   _0x8f9a = _0x8f9a + 1
  if _0x8f9a >= _0x9b0c then
    _0x8f9a = 0
    if LicenseState.licenseKey and LicenseState.licenseKey ~= '' then
      local _0xa1b2 = _0x7a8b()
      local _0xc3d4 = _0x1e2f()
      local _0xe5f6 = IsLicenseValid()
      -- Only reset modal state if license becomes invalid AND modal is not currently showing
      -- This prevents the modal from refreshing/reopening when it's already open
      if not (_0xa1b2 and _0xc3d4 and _0xe5f6) and not _0x1a2b._0x3c4d then
        _0x1a2b._0x3c4d = false
      end
    end
  end
 ]]  
  -- Ensure visibility toggles default to true
  if OPEN.ShowSends == nil then OPEN.ShowSends = true end
  
  -- keep global TrackCount updated and detect project switches
  TrackCount = r.GetNumTracks()
  do
    local curProj = select(1, r.EnumProjects(-1, ""))
    if curProj ~= CurrentProj then
      CurrentProj = curProj
      RefreshSendFavoritesForCurrentProject()
    end
  end
  
  -- advance patch-line animation phase each frame
  PatchLineShift = (PatchLineShift + PatchLineSpeed) % (Patch_Thick * 2)

  Top_Arrang = tonumber(select(2, r.BR_Win32_GetPrivateProfileString("REAPER", "toppane", "", r.get_ini_file()))) + 5
  KeyboardShortcuts(ctx)
  -- Reset/update per-frame UI suppression flags
  if WetDryKnobDragging and not im.IsMouseDown(ctx, 0) then WetDryKnobDragging = false end
  SuppressMultiSelMenuThisFrame = WetDryKnobDragging or false
  MultiSelMenuVisibleThisFrame = false

  visible, open = im.Begin(ctx, 'My window', true,
    im.WindowFlags_NoScrollWithMouse + im.WindowFlags_NoScrollbar + im.WindowFlags_MenuBar)

--[[   local _0x1f2a = false
  if visible and ctx then
    _0x1f2a = _0x2a3b_Modal()
    -- If modal returns 'exit', user closed the window without authorization - exit script
    if _0x1f2a == 'exit' then
      if visible then
        im.End(ctx)
      end
      return  -- Exit script by not calling r.defer(loop)
    end
  end
  
  local _0x3b4c = _0x7a8b()
  local _0x5d6e = _0x1e2f()
  local _0x7f8a = IsLicenseValid()
  
  if _0x1f2a or not (_0x3b4c and _0x5d6e and _0x7f8a) then
    if visible then
      im.End(ctx)
    end
    r.defer(loop)
    return
  end
 ]]
  if HelpHint then
    im.PushFont(ctx, Font_Andale_Mono_10)

    for i, v in ipairs(HelpHint) do
      im.Text(ctx, v)
    end
    im.PopFont(ctx)
  end


  ------ menu bar -------
  if im.BeginMenuBar( ctx) then 
    if im.MenuItem( ctx, 'Monitor FX') then 
      OPEN.MonitorFX = not (OPEN.MonitorFX == true)
      SaveOpenState()
    end
    if OPEN.MonitorFX then HighlightItem(Clr.GenericHighlightFill,nil, Clr.GenericHighlightOutline)end 
    
    
    
    if im.MenuItem(ctx, 'Sends') then
      OPEN.ShowSends = not (OPEN.ShowSends == true)
      SaveOpenState()
    end
    if (OPEN.ShowSends ~= false) then HighlightItem(Clr.GenericHighlightFill,nil, Clr.GenericHighlightOutline) end
    
    if im.MenuItem(ctx, 'Snapshots') then
      OPEN.Snapshots = not (OPEN.Snapshots == true)
      SaveOpenState()
    end
    if OPEN.Snapshots then HighlightItem(Clr.GenericHighlightFill,nil, Clr.GenericHighlightOutline) end
    ---------------------------------------------------------------------
    ---
    im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
    if im.ImageButton(ctx,'settings icon', Img.Settings, 16, 16) then
      OPEN.Settings = not (OPEN.Settings == true)
      SaveOpenState()
    end
    im.PopStyleColor(ctx)
   if OPEN.Settings then HighlightItem(Clr.GenericHighlightFill,nil, Clr.GenericHighlightOutline)end 
    

    im.EndMenuBar(ctx)
  end

  -- Multi-selection top buttons removed; floating menu handled near first selected FX

  MonitorFX_Height = 0  -- IMPORTANT: reset height to 0 each frame


  if OPEN.MonitorFX then 
    if im.Begin(ctx, 'Monitor FXs   ',true, im.WindowFlags_NoScrollbar) then 
        MonitorFX_Height = MonitorFXs(ctx, 0)
      im.End(ctx)
    end
  end

  -- Apply default preset once before pushing any styles/colors so first frame matches
  ApplyDefaultStylePresetIfAny()
  local PopClrTimes = ApplyColors(ctx)
  PushStyle() -- Apply style editor styles
  im.PushFont(ctx, Font_Andale_Mono_12)
  -- Capture root window screen-space bounds for later outline drawing
  RootWinL, RootWinT = im.GetWindowPos(ctx)
  RootWinW, RootWinH = im.GetWindowSize(ctx)


  VP.vp = im.GetWindowViewport(ctx)
  VP.w, VP.h = im.Viewport_GetSize(VP.vp)
  -- Apply any pending global drag from previous frame before rendering tracks
  if PendingGlobalDragDX and PendingGlobalDragDX ~= 0 then
    FXPane_W = FXPane_W + PendingGlobalDragDX
    local maxGlobal = VP.w - (OPEN.Snapshots and SnapshotPane_W or 0) - 1
    if FXPane_W > maxGlobal then FXPane_W = maxGlobal end
    if FXPane_W < 100 then FXPane_W = 100 end
    PendingGlobalDragDX = 0
  end

  -- Auto-resize FX pane if Sends panel hidden
  -- Save previous width before expanding, restore when Sends is shown again
  if OPEN then
    if (OPEN.ShowSends == false) then
      -- Expand FX pane and remember previous width only once
      if not FXPane_IsMaximised then
        PrevFXPane_W   = FXPane_W
      end
      FXPane_W          = VP.w - 10   -- fill full window minus small gap
      FXPane_IsMaximised = true

    elseif (OPEN.ShowSends ~= false) then  -- Sends panel visible again
      if FXPane_IsMaximised and PrevFXPane_W then
        FXPane_W = PrevFXPane_W        -- restore prior width
      end
      FXPane_IsMaximised = false
    end
  end

  LBtnDC = im.IsMouseDoubleClicked(ctx, 0)

  Mods = im.GetKeyMods(ctx)


  if visible then
    HiddenParentHoveredGUID = nil
    if not FDL then FDL = im.GetForegroundDrawList(ctx) end
    im.PushStyleVar(ctx, im.StyleVar_ItemSpacing, 0, SpaceBtwnFXs)
    im.PushStyleVar(ctx, im.StyleVar_FramePadding, 0, 1)
    --AutoFocus(ctx)
    
    TrackCount = r.GetNumTracks()

    ----move fx -----
    if MovFX.FromPos[1] then
      -- Single undo step for multi-move/copy
      local undoLabel = 'Move FXs'
      r.Undo_BeginBlock()
      for i, v in ipairs(MovFX.FromPos) do
        if NeedCopyFX then
          -- Use GUID to find current index (indices shift when copying to same track)
          local fromIdx = v
          if MovFX.GUID and MovFX.GUID[i] then
            -- Look up current index by GUID
            local cnt = r.TrackFX_GetCount(MovFX.FromTrack[i])
            for j = 0, cnt - 1 do
              if r.TrackFX_GetFXGUID(MovFX.FromTrack[i], j) == MovFX.GUID[i] then
                fromIdx = j
                break
              end
            end
          end
          
          local offset = 0
          if MovFX.FromTrack[i] == MovFX.ToTrack[i] then
            if fromIdx >= DropPos then offset = 0 else offset = -1 end
          end
          local topos = math.max(MovFX.ToPos[i] - (offset or 0), 0)

          r.TrackFX_CopyToTrack(MovFX.FromTrack[i], fromIdx, MovFX.ToTrack[i], topos, false)
          local dstIdx = math.min(topos, r.TrackFX_GetCount(MovFX.ToTrack[i]) - 1)
          -- If dropping onto a non-first parallel FX, make the inserted FX parallel to previous
          if SetParallelForNextDrop then
            local parVal = tostring(SetParallelToValue or 1)
            r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], dstIdx, 'parallel', parVal)
            SetParallelForNextDrop = nil
            SetParallelToValue = nil
          elseif SetParallelClearForNextDrop then
            -- Dropping onto non-parallel space/target: ensure inserted FX is not parallel
            r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], dstIdx, 'parallel', '0')
            SetParallelClearForNextDrop = nil
          end
          CopyFXAutomation(MovFX.FromTrack[i], fromIdx, MovFX.ToTrack[i], dstIdx)
          
          -- Handle linking: either single FX link (NeedLinkFXsID) or multi-FX link (NeedLinkFXsGUIDs)
          local originalGUID = nil
          if NeedLinkFXsGUIDs and MovFX.GUID and MovFX.GUID[i] and NeedLinkFXsGUIDs[MovFX.GUID[i]] then
            -- Multi-selection Ctrl+drag: link each copied FX to its original
            originalGUID = MovFX.GUID[i]
          elseif NeedLinkFXsID then
            -- Single FX Ctrl+drag: use the stored GUID
            originalGUID = NeedLinkFXsID
          end
          
          if originalGUID then
            local Ct = r.TrackFX_GetCount(MovFX.ToTrack[i]) - 1
            local copiedGUID = r.TrackFX_GetFXGUID(MovFX.ToTrack[i], math.min(topos, Ct))
            
            if copiedGUID then
              FX[copiedGUID] = FX[copiedGUID] or {}
              FX[originalGUID] = FX[originalGUID] or {}
              FX[copiedGUID].Link = originalGUID
              FX[originalGUID].Link = copiedGUID
              r.GetSetMediaTrackInfo_String(MovFX.FromTrack[i], 'P_EXT: FX' .. originalGUID .. 'Link to ', copiedGUID, true)
              r.GetSetMediaTrackInfo_String(MovFX.ToTrack[i], 'P_EXT: FX' .. copiedGUID .. 'Link to ', originalGUID, true)
            end
          end
          
          -- Clear single FX link flag after first use
          if NeedLinkFXsID then
            NeedLinkFXsID = nil
          end
        end
      end
      
      -- Clear multi-link flag after all copies are done
      if NeedLinkFXsGUIDs then
        NeedLinkFXsGUIDs = nil
      end

      if not NeedCopyFX then
        for i = 1, #MovFX.FromPos do
          -- Look up current index by GUID (indices shift after each move)
          local fromIdx = MovFX.FromPos[i]
          if MovFX.GUID and MovFX.GUID[i] then
            local cnt = r.TrackFX_GetCount(MovFX.FromTrack[i])
            for j = 0, cnt - 1 do
              if r.TrackFX_GetFXGUID(MovFX.FromTrack[i], j) == MovFX.GUID[i] then
                fromIdx = j
                break
              end
            end
          end
          local toPos = MovFX.ToPos[i]
          r.TrackFX_CopyToTrack(MovFX.FromTrack[i], fromIdx, MovFX.ToTrack[i], toPos, true)
          
          -- After move, apply parallel flag if requested only for the primary dragged FX
          if SetParallelForNextDrop or SetParallelClearForNextDrop then
            local appliedToDraggedOnly = false
            if DraggedMultiMove then
              local movedIdx = math.min(math.max(toPos, 0), r.TrackFX_GetCount(MovFX.ToTrack[i]) - 1)
              local guidAtDst = r.TrackFX_GetFXGUID(MovFX.ToTrack[i], movedIdx)
              if guidAtDst == DraggedMultiMove then
                if SetParallelForNextDrop then
                  local parVal = tostring(SetParallelToValue or 1)
                  r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], movedIdx, 'parallel', parVal)
                elseif SetParallelClearForNextDrop then
                  r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], movedIdx, 'parallel', '0')
                end
                appliedToDraggedOnly = true
              end
            end
            -- Fallback: if we couldn't match GUID, apply to this iteration (likely the dragged one)
            if not appliedToDraggedOnly then
              local dstIdxMove = math.min(math.max(toPos, 0), r.TrackFX_GetCount(MovFX.ToTrack[i]) - 1)
              if SetParallelForNextDrop then
                local parVal = tostring(SetParallelToValue or 1)
                r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], dstIdxMove, 'parallel', parVal)
              elseif SetParallelClearForNextDrop then
                r.TrackFX_SetNamedConfigParm(MovFX.ToTrack[i], dstIdxMove, 'parallel', '0')
              end
            end
          end
        end
      end




      r.Undo_EndBlock(undoLabel, -1)
      MovFX = { FromPos = {}, ToPos = {}, Lbl = {}, Copy = {}, FromTrack = {}, ToTrack = {} }
      NeedCopyFX = nil
      DropPos = nil
      DraggedMultiMove = nil
      MultiMoveSnapshot = nil
      MultiMoveSourceGUID = nil
      
      -- Refresh selection indices after moves
      -- Removed selection index refresh for multi-move


      --[[  MovFX.ToPos = {}
      MovFX.Lbl = {} ]]
    end

    if Mods == Ctrl + Shift + Alt then
      DebugMode = true
    else
      DebugMode = false
    end

    if not im.IsMouseDown(ctx,0) then 
      Send_Drag_Prev = { }
    end

    -- Marquee selection handling with drag detection
    if im.IsMouseDown(ctx, 1) and not MarqueeSelection.isActive then -- Right mouse button down
      if MarqueeSelection.initialMouseX == 0 then -- First frame of mouse down
        local mouseX, mouseY = im.GetMousePos(ctx)
        MarqueeSelection.initialMouseX = mouseX
        MarqueeSelection.initialMouseY = mouseY
        MarqueeSelection.hasDragged = false
        MarqueeSelection.startingOnVolDrag = false -- Will be set during send rendering
      else -- Subsequent frames, check for drag
        local mouseX, mouseY = im.GetMousePos(ctx)
        local deltaX = math.abs(mouseX - MarqueeSelection.initialMouseX)
        local deltaY = math.abs(mouseY - MarqueeSelection.initialMouseY)
        
        -- Allow immediate start if starting on volume drag area, otherwise use threshold
        if MarqueeSelection.startingOnVolDrag or deltaX > MarqueeSelection.dragThreshold or deltaY > MarqueeSelection.dragThreshold then
          MarqueeSelection.hasDragged = true
          StartMarqueeSelection(ctx)
        end
      end
    elseif MarqueeSelection.isActive then
      if im.IsMouseDown(ctx, 1) then
        UpdateMarqueeSelection(ctx)
      else
        EndMarqueeSelection(ctx)
      end
    elseif im.IsMouseClicked(ctx, 1) and not MarqueeSelection.hasDragged then
      -- This is a right-click (not a drag), handle it separately
      -- The actual right-click handling will be done in the individual components
    end
    
    -- Reset drag detection when mouse is released
    if not im.IsMouseDown(ctx, 1) and MarqueeSelection.initialMouseX ~= 0 then
      MarqueeSelection.hasDragged = false
      MarqueeSelection.initialMouseX = 0
      MarqueeSelection.initialMouseY = 0
      MarqueeSelection.startingOnVolDrag = false
    end

    -- Clear selection on left click (only if not interacting with selected FXs/Sends or clicking the multi-select menu)
    do
      local hoveringMenu = false
      if MultiSelMenuRect then
        hoveringMenu = im.IsMouseHoveringRect(ctx, MultiSelMenuRect.L, MultiSelMenuRect.T, MultiSelMenuRect.R, MultiSelMenuRect.B)
      end
      if im.IsMouseClicked(ctx, 0) and not MarqueeSelection.isActive and not InteractingWithSelectedFX and not InteractingWithSelectedSends and not hoveringMenu then
        ClearSelection()
      end
    end
    
    -- Reset the interaction flags
    InteractingWithSelectedFX = false
    InteractingWithSelectedSends = false

    rv, Payload_Type, Payload, is_preview, is_delivery = im.GetDragDropPayload(ctx)
    PanFaderActivation(ctx)



    for t = -1, TrackCount - 1, 1 do
      Trk[t] = Trk[t] or {}

      local T = Trk[t]
      if t == -1 then
        Track = r.GetMasterTrack(0)
      else
        Track = r.GetTrack(0, t)
      end

      CacheTrackPointer(Track)


      TrkID      = r.GetTrackGUID(Track)
      Trk[TrkID] = Trk[TrkID] or {}

      local hide = 0
      local TrkClr = im.ColorConvertNative(r.GetTrackColor(Track))
      TrkClr = ((TrkClr or 0) << 8) | 0x66
      local TrkClr_Low_Alpha = Change_Clr_A(TrkClr, -0.3)
      


      if t == -1 then
        Trk[t].PosY, Trk[t].H = getTrackPosAndHeight(Track)
       --MonitorFXs(ctx, Top_Arrang-30)
       --SL(nil,50)
       
       if OPEN.Settings then 
          SettingsWindow()
        end

        im.SetCursorPosY(ctx, Top_Arrang + Trk[t].PosY - (MonitorFX_Height or 0))
        local masterVisibility = r.GetMasterTrackVisibility()
        if masterVisibility == 2 or masterVisibility == 0 then hide = 0 else hide = 1 end
      else
        hide = r.GetMediaTrackInfo_Value(Track, 'B_SHOWINTCP')
      end






      WheelV = im.GetMouseWheel(ctx)
      if WheelV ~= 0 then
        local windowHWND = r.GetMainHwnd()
        retval, position, pageSize, min, max, trackPos = r.JS_Window_GetScrollInfo(windowHWND, 'v')

        r.JS_Window_SetScrollPos(windowHWND, 'VERT', math.ceil(position + WheelV))
        r.UpdateArrange()
      end

      if hide == 0 then 

        local Folder_Depth = r.GetMediaTrackInfo_Value( Track,'I_FOLDERDEPTH')
        --if it's a folder
        if Folder_Depth ==1 then 
          --local id = r.GetMediaTrackInfo_Value( Track,'IP_TRACKNUMBER')
          if not FOLDER then 
          elseif FOLDER  then -- if this is a folder within a folder
            local rv, name = r.GetSetMediaTrackInfo_String(Track, 'P_NAME' ,'', false)
          end 
          FOLDER = r.GetTrack(0, t)
          Folder_Clr = im.ColorConvertNative(r.GetTrackColor(Track))
          Folder_Clr = ((Folder_Clr or 0) << 8) | 0x66
          FOLDER_Icon_Has_Been_Created = nil 
        end

      end 
      if Track and hide ~= 0 then
        local HeightOfs = 0

        Trk[t].PosY, Trk[t].H = getTrackPosAndHeight(Track)
        Trk[t].H = Trk[t].H - 1


        local x, y = im.GetCursorScreenPos(ctx)

        -- When showing full-size hidden parents, accumulate bounds for ALL hidden ancestor folders using screen-space Y
        if OPEN.ShowHiddenParents then
          local anc = r.GetMediaTrackInfo_Value(Track, 'P_PARTRACK')
          local childLeft = (Trk and Trk[TrkID] and Trk[TrkID].FxChildLeftX) or select(1, im.GetWindowPos(ctx))
          local leftX = (RootWinL or select(1, im.GetWindowPos(ctx)))
          local rightX = (RootWinL or select(1, im.GetWindowPos(ctx))) + (RootWinW or select(1, im.GetWindowSize(ctx)) or 0)
          local topY = y + (Folder_Btn_Compact or 0) * 0.5
          local bottomY = y + (Trk[t].H or 0)
          while anc and anc ~= 0 do
            local ancDepth = r.GetMediaTrackInfo_Value(anc, 'I_FOLDERDEPTH')
            local ancVis   = r.GetMediaTrackInfo_Value(anc, 'B_SHOWINTCP')
            if ancDepth == 1 and ancVis == 0 then
              local guid = r.GetTrackGUID(anc)
              local b = HiddenParentBounds[guid]
              if not b then
                HiddenParentBounds[guid] = { left = leftX, right = rightX, top = topY, bottom = bottomY }
              else
                if topY < b.top then b.top = topY end
                if bottomY > b.bottom then b.bottom = bottomY end
                if leftX < b.left then b.left = leftX end
                if rightX > b.right then b.right = rightX end
              end
            end
            anc = r.GetMediaTrackInfo_Value(anc, 'P_PARTRACK')
          end
        end

        if FOLDER and OPEN.ShowHiddenParents then 
          local P_trk = r.GetMediaTrackInfo_Value( Track, 'P_PARTRACK')
          local rv, name = r.GetSetMediaTrackInfo_String(Track, 'P_NAME' ,'', false)
          if P_trk ==FOLDER then 
            
            --im.DrawList_AddLine(WDL, x-2, y, x-2 , y+ Trk[t].H, 0xffffffff)

            local Parent = r.GetMediaTrackInfo_Value( FOLDER, 'P_PARTRACK')
            if Parent~= 0 then 
              local rv, name = r.GetSetMediaTrackInfo_String(Parent, 'P_NAME' ,'', false)
              --im.Button(ctx, name..'1', 10, Trk[t].H)
              --SL()
            end 

            if OPEN.ShowHiddenParents then 
              -- Accumulate bounds for all hidden children of the current folder
              local folderGUID = r.GetTrackGUID(FOLDER)
              local childLeft = (Trk and Trk[TrkID] and Trk[TrkID].FxChildLeftX) or select(1, im.GetWindowPos(ctx))
              local leftX = (RootWinL or select(1, im.GetWindowPos(ctx))) 
              local rightX = (RootWinL or select(1, im.GetWindowPos(ctx))) + (RootWinW or select(1, im.GetWindowSize(ctx)) or 0)
              local topY = y + (Folder_Btn_Compact or 0) * 0.5
              local bottomY = y + (Trk[t].H or 0)

              local b = HiddenParentBounds[folderGUID]
              if not b then
                HiddenParentBounds[folderGUID] = { left = leftX, right = rightX, top = topY, bottom = bottomY }
              else
                if topY < b.top then b.top = topY end
                if bottomY > b.bottom then b.bottom = bottomY end
                if leftX < b.left then b.left = leftX end
                if rightX > b.right then b.right = rightX end
              end
            end
            
            if not FOLDER_Icon_Has_Been_Created then 
              im.PushStyleColor(ctx, im.Col_Button, Folder_Clr)
              if HiddenParentHoveredGUID and r.GetTrackGUID(FOLDER) == HiddenParentHoveredGUID then
                im.PushStyleColor(ctx, im.Col_Text, (Clr and Clr.HiddenParentHover) or 0x2ECC71ff)
              end
              local _, parentName = r.GetSetMediaTrackInfo_String(FOLDER, 'P_NAME' ,'', false)
              local btnLabel = (parentName ~= '' and parentName or 'Parent') .. '##ShowHiddenParentBtn'..t
              im.PushStyleColor(ctx, im.Col_ButtonHovered,  0x00000000)
              -- Choose nearest font size to match desired button height
              local targetH = Folder_Btn_Compact or 5
              local fontToUse = Font_Andale_Mono_12
              if targetH <= 7 then fontToUse = Font_Andale_Mono_6
              elseif targetH <= 8 then fontToUse = Font_Andale_Mono_7
              elseif targetH <= 9 then fontToUse = Font_Andale_Mono_8
              elseif targetH <= 10 then fontToUse = Font_Andale_Mono_9
              elseif targetH <= 11 then fontToUse = Font_Andale_Mono_10
              elseif targetH <= 12 then fontToUse = Font_Andale_Mono_11
              elseif targetH <= 13 then fontToUse = Font_Andale_Mono_12
              elseif targetH <= 14 then fontToUse = Font_Andale_Mono_13
              elseif targetH <= 15 then fontToUse = Font_Andale_Mono_14
              elseif targetH <= 16 then fontToUse = Font_Andale_Mono_15
              else fontToUse = Font_Andale_Mono_16 end
              -- Precompute hover for this button area (before creating the item)
              local curL, curT = im.GetCursorScreenPos(ctx)
              local availW = select(1, im.GetContentRegionAvail(ctx)) or 0
              local mx, my = im.GetMousePos(ctx)
              local isBtnHovered = (mx >= curL and mx <= curL + availW and my >= curT and my <= curT + targetH)
              local useFont = fontToUse
              if isBtnHovered then
                if     targetH <= 7  then useFont = Font_Andale_Mono_6_B
                elseif targetH <= 8  then useFont = Font_Andale_Mono_7_B
                elseif targetH <= 9  then useFont = Font_Andale_Mono_8_B
                elseif targetH <= 10 then useFont = Font_Andale_Mono_9_B
                elseif targetH <= 11 then useFont = Font_Andale_Mono_10_B
                elseif targetH <= 12 then useFont = Font_Andale_Mono_11_B
                elseif targetH <= 13 then useFont = Font_Andale_Mono_12_B
                elseif targetH <= 14 then useFont = Font_Andale_Mono_13_B
                elseif targetH <= 15 then useFont = Font_Andale_Mono_14_B
                elseif targetH <= 16 then useFont = Font_Andale_Mono_15_B
                else                      useFont = Font_Andale_Mono_16_B end
              end
              im.PushFont(ctx, useFont)
              local rv = im.Button(ctx, btnLabel, -1, targetH)
              im.PopFont(ctx)
              if im.IsItemHovered(ctx) then
                SetHelpHint('LMB = Open Destination Track', 'RMB = Show Hidden Parent Track')
              end
              im.PopStyleColor(ctx)
              if HiddenParentHoveredGUID and r.GetTrackGUID(FOLDER) == HiddenParentHoveredGUID then
                im.PopStyleColor(ctx)
              end
              im.PopStyleColor(ctx)
              HeightOfs = Folder_Btn_Compact
              if rv then  
                OpenedDestSendWin = i 
                OpenedDestTrkWin = FOLDER
              end
              -- record button rect for top gap calculation
              do
                local L,T = im.GetItemRectMin(ctx)
                local R,B = im.GetItemRectMax(ctx)
                HiddenParentBtnRect[r.GetTrackGUID(FOLDER)] = {L=L, T=T, R=R, B=B}
              end
              if OpenedDestTrkWin == FOLDER and OpenedDestSendWin == i then 
                if OpenDestTrackPopup(ctx,FOLDER, t) then 
                  OpenedDestSendWin = i 
                  OpenedDestTrkWin = FOLDER
                end
              end
              
              if im.IsItemClicked(ctx, 1) then 
                r.SetMediaTrackInfo_Value(FOLDER, 'B_SHOWINTCP',1 )
                reaper.UpdateArrange()
                r.TrackList_AdjustWindows(false)

              end 
              FOLDER_Icon_Has_Been_Created = true 
            end 
          

          end 
          
          
        end
        --if it's last track in folder
        if r.GetMediaTrackInfo_Value( Track,'I_FOLDERDEPTH') < 0 then 
          --im.DrawList_AddLine(WDL, x-2, y+ Trk[t].H , x+FXPane_W , y+ Trk[t].H, 0xffffffff)
          -- Draw enclosing rectangle for the hidden children accumulated for this folder
          if OPEN.ShowHiddenParents and FOLDER then
            -- Draw rectangles for this folder and ALL hidden ancestors still open, with offsets per nesting level
            local dl = im.GetWindowDrawList(ctx)
            local padBase = 2
            local stroke = 3

            -- Build list of hidden ancestor folders including this closing folder
            local stack = {}
            local anc = FOLDER
            while anc and anc ~= 0 do
              local vis = r.GetMediaTrackInfo_Value(anc, 'B_SHOWINTCP')
              local depth = r.GetMediaTrackInfo_Value(anc, 'I_FOLDERDEPTH')
              if depth == 1 and vis == 0 then
                stack[#stack+1] = anc
              end
              anc = r.GetMediaTrackInfo_Value(anc, 'P_PARTRACK')
            end

            -- Color palette for hover highlight per level (cycle if deeper than palette)
            local baseOutlineCol = (Clr and Clr.HiddenParentOutline) or 0x2222ff
            local hoverOutlineCol = (Clr and Clr.HiddenParentHover) or 0x2ECC71ff

            -- Determine which level (if any) is hovered; prioritize deepest (index 1)
            local mx, my = im.GetMousePos(ctx)
            local hoveredIndex = nil
            for i = 1, #stack do
              local tr = stack[i] -- deepest first
              local guid = r.GetTrackGUID(tr)
              local b = HiddenParentBounds and HiddenParentBounds[guid]
              if b and mx >= b.left and mx <= b.right and my >= b.top and my <= b.bottom then
                hoveredIndex = i
                break
              end
            end

            -- Queue outlines to draw at end of frame (neutral and hovered color pass with top gap)
            local neutral = baseOutlineCol
            for i = 1, #stack do
              local tr = stack[i]
              local guid = r.GetTrackGUID(tr)
              local b = HiddenParentBounds and HiddenParentBounds[guid]
              if b and b.top and b.bottom and b.left and b.right then
                HiddenOutlinesToDraw[#HiddenOutlinesToDraw+1] = {
                  L = b.left - padBase,
                  T = b.top - padBase,
                  R = b.right + padBase,
                  B = b.bottom + padBase,
                  col = neutral,
                  thick = stroke,
                  guid = guid,
                  level = i,
                  levels = #stack
                }
              end
            end
            if hoveredIndex then
              local tr = stack[hoveredIndex]
              local guid = r.GetTrackGUID(tr)
              local b = HiddenParentBounds and HiddenParentBounds[guid]
              if b and b.top and b.bottom and b.left and b.right then
              HiddenParentHoveredGUID = guid
                HiddenOutlinesToDraw[#HiddenOutlinesToDraw+1] = {
                  L = b.left - padBase,
                  T = b.top - padBase,
                  R = b.right + padBase,
                  B = b.bottom + padBase,
                  col = hoverOutlineCol,
                  thick = stroke,
                  priority = 1,
                  guid = guid,
                  level = hoveredIndex,
                  levels = #stack
                }
              end
            end

            -- Clear bounds after collecting at this closure
            for i = 1, #stack do
              local tr = stack[i]
              local guid = r.GetTrackGUID(tr)
              if HiddenParentBounds and guid then HiddenParentBounds[guid] = nil end
            end
          end
          FOLDER_Icon_Has_Been_Created = nil 
          FOLDER=nil
        end 







        FXPane_W = FXPane_W or 200
        -- push # 3 track-tinted colors (child bg, hover, active)
        local TrkClr_Act, TrkClr_Hvr = Generate_Active_And_Hvr_CLRs(TrkClr_Low_Alpha)
        im.PushStyleColor(ctx, im.Col_ChildBg,  TrkClr_Low_Alpha)
        im.PushStyleColor(ctx, im.Col_FrameBgHovered, TrkClr_Hvr)
        im.PushStyleColor(ctx, im.Col_FrameBgActive,  TrkClr_Act)
        local fxPaneW
        do
          -- If send panel is hidden (globally or per-track), ignore separate width and use global width
          local sendsHidden = (OPEN and OPEN.ShowSends == false) or PerTrackSendsHidden[TrkID]
          local base = (sendsHidden and FXPane_W) or (PerTrackFXPane_W[TrkID] or FXPane_W)
          local availW = select(1, im.GetContentRegionAvail(ctx)) or (VP.w - (OPEN.Snapshots and SnapshotPane_W or 0))
          local hiddenTarget = math.max(100, (availW or 0) - 5)
          local tween = PerTrackSendsTween and PerTrackSendsTween[TrkID]
          if tween then
            tween.progress = math.min(1, (tween.progress or 0) + TWEEN_STEP)
            local p = EaseOutCubic(tween.progress)
            if tween.goalHidden then
              fxPaneW = base + (hiddenTarget - base) * p
            else
              fxPaneW = hiddenTarget + (base - hiddenTarget) * p
            end
            if tween.progress >= 1 then PerTrackSendsTween[TrkID] = nil end
          else
            if sendsHidden then fxPaneW = hiddenTarget else fxPaneW = base end
          end
          if fxPaneW < 100 then fxPaneW = 100 end
        end
        function FX_List()

          local __prevFXPaneW = FXPane_W
          FXPane_W = fxPaneW
          local __opened = im.BeginChild(ctx, 'Track' .. t, fxPaneW, Trk[t].H - HeightOfs, nil, im.WindowFlags_NoScrollbar + im.WindowFlags_NoScrollWithMouse)
          if __opened then
            do
              local childPosX, childPosY = im.GetWindowPos(ctx)
              local childW, childH = im.GetWindowSize(ctx)
              if Trk and TrkID then
                Trk[TrkID] = Trk[TrkID] or {}
                Trk[TrkID].FxChildLeftX = childPosX
                Trk[TrkID].FxChildTopY  = childPosY
                Trk[TrkID].FxChildW     = childW
                Trk[TrkID].FxChildH     = childH
              end
            end
            im.Dummy(ctx, 0, 1) -- top margin inside FX child
            --im.Text(ctx, 'track' .. t .. '     ' .. Trk[t].PosY)
            if not WDL then WDL = im.GetWindowDrawList(ctx) end
            --------------------------------------------
            ------Repeat for Every fx-------------------
            --------------------------------------------




            FXBtns(Track, nil,nil, t, ctx, nil, OPEN)


            function VolumeBar(ctx,BtnSize, i, SendOrRecv, animHeight )
              local X, Y = im.GetCursorScreenPos(ctx)
              local _, T = im.GetItemRectMin(ctx)
              local _, B = im.GetItemRectMax(ctx)
              local H = animHeight or (B - T)
              local v = r.GetTrackSendInfo_Value(Track, SendOrRecv, i, 'D_VOL')
              local v = Convert_Val2Fader(v)



              if im.IsItemActive(ctx) then
                -- choose colour: sends (0) vs returns (-1)
                local baseClr = (SendOrRecv == 0) and Clr.Send or Clr.ReceiveSend
                -- suppress glow when Alt is held (for send deletion gesture)
                if not (SendOrRecv == 0 and Mods == Alt) then
                  DrawGlowRect( im.GetWindowDrawList(ctx), X + BtnSize * v - 2, T, X + BtnSize * v, T + H, Change_Clr_Alpha(baseClr, 0.5), 6, 4)
                end

                -- Fill anchored at top (T) so it shrinks upward with the row height
                im.DrawList_AddRectFilled(WDL, X, T, X + BtnSize * v, T + H, 0xffffff55)
                  
              else 
                -- Fill anchored at top (T)
                im.DrawList_AddRectFilled(WDL, X, T, X + BtnSize * v, T + H, 0xffffff22)

              end

            end


            Empty_FX_Space_Btn(ctx, T)
            im.EndChild(ctx)
            -- If the track FX chain is disabled, draw a translucent red overlay over the FX pane
            do
              local fxen = r.GetMediaTrackInfo_Value(Track, 'I_FXEN')
              local chainDisabled = (fxen ~= nil and fxen < 0.5)
              if fxen == nil then
                -- Fallback: consider disabled if there are FX but none enabled
                local cnt = r.TrackFX_GetCount(Track)
                local anyEnabled = false
                for i = 0, (cnt or 0) - 1 do
                  if r.TrackFX_GetEnabled(Track, i) then anyEnabled = true break end
                end
                chainDisabled = (cnt or 0) > 0 and (not anyEnabled)
              end
              if chainDisabled and Trk and TrkID and Trk[TrkID] and Trk[TrkID].FxChildLeftX and Trk[TrkID].FxChildTopY then
                local x = Trk[TrkID].FxChildLeftX
                local y = Trk[TrkID].FxChildTopY
                local w = Trk[TrkID].FxChildW or fxPaneW
                local h = Trk[TrkID].FxChildH
                if x and y and w and h then
                  local dl = im.GetForegroundDrawList(ctx)
                  local fillCol = im.ColorConvertDouble4ToU32(0.0, 0.0, 0.0, 0.44)
                  im.DrawList_AddRectFilled(dl, x, y, x + w, y + h, fillCol)
                end
              end
            end
            -- Immediately after FX list pane, draw a 15px reveal button when Sends is hidden
            if PerTrackSendsHidden[TrkID] then
              im.SameLine(ctx, nil, 0)
              im.PushStyleColor(ctx, im.Col_Button,        getClr(im.Col_FrameBgHovered))
              im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_Button))
              im.PushStyleColor(ctx, im.Col_ButtonActive,  getClr(im.Col_ButtonActive))
              local btnH = Trk[t].H - HeightOfs
              if im.Button(ctx, '<##RevealSends' .. t, 15, btnH) then
                PerTrackSendsHidden[TrkID] = nil
                PerTrackSendsTween[TrkID] = { progress = 0, goalHidden = false }
                SavePerTrackSendsHidden()
                -- revert to global width when revealing sends
                PerTrackFXPane_W[TrkID] = nil
                SavePerTrackWidths()
              end
              im.PopStyleColor(ctx, 3)
            end
          end
          FXPane_W = __prevFXPaneW
        end
        if OPEN.Snapshots then
          Snapshots_Pane(ctx, Track, TrkID, Trk[t].H - HeightOfs)
          -- handle to resize snapshot pane
          local function Snapshot_Reszie_Handle()
            -- use local track-height variables already in scope
            im.SameLine(ctx, nil, 0)
            local btnH = Trk[t].H - HeightOfs
            im.Button(ctx, '##SnapSep' .. t, 3, btnH)

            if im.IsItemActive(ctx) then
              -- highlight
              local L, T = im.GetItemRectMin(ctx)
              local R, B = im.GetItemRectMax(ctx)
              im.DrawList_AddRect(im.GetWindowDrawList(ctx), L, T, R, B, getClr(im.Col_ButtonActive))

              local dtX = im.GetMouseDelta(ctx)
              if Mods == 0 then
                SnapshotPane_W = SnapshotPane_W + dtX
                FXPane_W       = FXPane_W - dtX
                -- clamp
                if SnapshotPane_W < 60 then
                  FXPane_W = FXPane_W - (60 - SnapshotPane_W)
                  SnapshotPane_W = 60
                end
                if FXPane_W < 100 then
                  SnapshotPane_W = SnapshotPane_W - (100 - FXPane_W)
                  FXPane_W = 100
                end
              end
            end

            if im.IsItemHovered(ctx) or im.IsItemActive(ctx) then
              im.SetMouseCursor(ctx, im.MouseCursor_ResizeEW)
            end
            im.SameLine(ctx, nil, 0)
          end
          Snapshot_Reszie_Handle()
        end
         FX_List()
        function Separator_Reszie_Handle()
          im.SameLine(ctx, nil, 0)
          --SeparateX = im.CursorPos(ctx)
           -- If send panel is hidden (globally or per-track), ignore separate width and use global width
           local sendsHidden = (OPEN and OPEN.ShowSends == false) or PerTrackSendsHidden[TrkID]
           local baseFXW = (sendsHidden and FXPane_W) or (PerTrackFXPane_W[TrkID] or FXPane_W)
           local availW = select(1, im.GetContentRegionAvail(ctx)) or (VP.w - (OPEN.Snapshots and SnapshotPane_W or 0))
           local hiddenFXW = math.max(100, (availW or 0) - 5)
           local tweenSep = PerTrackSendsTween and PerTrackSendsTween[TrkID]
           local curFXPaneW
           local H_OutlineSc , V_OutlineSc = 1, 1
           if tweenSep then
             local p = EaseOutCubic(math.min(1, tweenSep.progress or 0))
             if tweenSep.goalHidden then
               curFXPaneW = baseFXW + (hiddenFXW - baseFXW) * p
             else
               curFXPaneW = hiddenFXW + (baseFXW - hiddenFXW) * p
             end
           else
             curFXPaneW = (sendsHidden and hiddenFXW) or baseFXW
           end
           Send_W = VP.w - curFXPaneW - (OPEN.Snapshots and SnapshotPane_W or 0)
           if Send_W < 0 then Send_W = 0 end
           if not sendsHidden and (not tweenSep) and Send_W < MIN_SEND_W then Send_W = MIN_SEND_W end


          --im.PushStyleColor(ctx, im.Col_Button(), getClr(im.Col_ButtonActive()))

           Sep_H = Trk[t].H
          if t == TrackCount - 1 then
            Sep_H = Trk[t].H
          end
          local sepHeight = Sep_H - HeightOfs
          if PerTrackSendsHidden[TrkID] then
            -- Draw a 15px reveal button at the right edge when sends hidden
            im.PushStyleColor(ctx, im.Col_Button,        getClr(im.Col_FrameBgHovered))
            im.PushStyleColor(ctx, im.Col_ButtonHovered, getClr(im.Col_Button))
            im.PushStyleColor(ctx, im.Col_ButtonActive,  getClr(im.Col_ButtonActive))
            -- Align this button to the far right of the row
            local rowStartX = select(1, im.GetCursorScreenPos(ctx))
            local rowWidth  = (select(1, im.GetContentRegionAvail(ctx)) or 0)
            local btnX      = rowStartX + math.max(0, rowWidth - 15)
            local curY      = select(2, im.GetCursorScreenPos(ctx))
            im.SetCursorScreenPos(ctx, btnX, curY)
            im.Button(ctx, '##RevealSends' .. t, 15, sepHeight)
            im.PopStyleColor(ctx, 3)
            if im.IsItemClicked(ctx) then
              PerTrackSendsHidden[TrkID] = nil
              PerTrackSendsTween[TrkID] = { progress = 0, goalHidden = false }
              SavePerTrackSendsHidden()
              -- revert to global width when revealing sends
              PerTrackFXPane_W[TrkID] = nil
              SavePerTrackWidths()
            end
            if im.IsItemHovered(ctx) then im.SetMouseCursor(ctx, im.MouseCursor_Hand) end
            im.SameLine(ctx, nil, 0)
          end
          -- draw the separator with a custom color behind the invisible button for consistent theming
          do
            local x, y = im.GetCursorScreenPos(ctx)
            local w, h = 3, sepHeight
            local dl = im.GetWindowDrawList(ctx)
            local base = (Clr and Clr.PaneSeparator) or 0xffffffff
            local col = base
            if im.IsItemHovered(ctx) and not im.IsItemActive(ctx) then
              col = LightenColorU32(base, 0.15)
            elseif im.IsItemActive(ctx) then
              col = DarkenColorU32(base, 0.10)
            end
            im.DrawList_AddRectFilled(dl, x, y, x + w, y + h, col)
          end
          -- Make the separator button background invisible so the custom color shows
          im.PushStyleColor(ctx, im.Col_Button, 0x00000000)
          im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00000000)
          im.PushStyleColor(ctx, im.Col_ButtonActive, 0x00000000)
          im.Button(ctx, '##Separator' .. t, 3, sepHeight)
          im.PopStyleColor(ctx, 3)

          if im.IsItemActive(ctx) then
            local sepBase = (Clr and Clr.PaneSeparator) or 0xffffffff
            local sepActive = DarkenColorU32(sepBase, 0.10)
            HighlightSelectedItem(sepActive, nil, Padding, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, 'GetItemRect')
            local DtX = im.GetMouseDelta(ctx)
            if Mods == 0 then
              -- If this track already has independent width, allow direct adjustment without Shift
              if PerTrackFXPane_W[TrkID] ~= nil then
                local minFX = 100
                local maxFX = VP.w - (OPEN.Snapshots and SnapshotPane_W or 0) - 1
                local newW = PerTrackFXPane_W[TrkID] + DtX
                if newW < minFX then newW = minFX end
                if newW > maxFX then newW = maxFX end
                -- New rule: For already-independent track, no snapping during normal drag
                PerTrackSnappedToGlobal[TrkID] = false
                PerTrackFXPane_W[TrkID] = newW
                PerTrackWidth_DragActive = true
                PerTrackDragGUID = TrkID
                SeparatorDragGUID = TrkID
                SeparatorDragIsIndependent = true
                -- Visual cue: only for current track; if within 10px of global, draw dotted guide at global
                if PerTrackDragGUID == TrkID and SeparatorDragIsIndependent then
                  local perW = PerTrackFXPane_W[TrkID] or FXPane_W
                  local diff = math.abs(perW - FXPane_W)
          if diff <= 10 then
                    local dl = im.GetWindowDrawList(ctx)
                    local childLeft = (Trk and Trk[TrkID] and Trk[TrkID].FxChildLeftX) or select(1, im.GetWindowPos(ctx))
                    local childTop  = (Trk and Trk[TrkID] and Trk[TrkID].FxChildTopY)  or select(2, im.GetWindowPos(ctx))
                    local childH    = (Trk and Trk[TrkID] and Trk[TrkID].FxChildH)     or select(2, im.GetWindowSize(ctx))
                    local xGlobal = childLeft + FXPane_W
                    local y = childTop
                    local sepB = childTop + (childH or 0)
                    local clr = (Clr and Clr.PaneSeparatorGuide) or (getClr and getClr(im.Col_ButtonActive)) or 0xffffffff
                    while y < sepB do
                      local y2 = math.min(y + 3, sepB)
                      im.DrawList_AddLine(dl, xGlobal, y, xGlobal, y2, clr, 1)
                      y = y + 6
                    end
                  end
                end
                -- Check for hide threshold
                local newSendW = VP.w - newW - (OPEN.Snapshots and SnapshotPane_W or 0)
                local delta = (MIN_SEND_W - newSendW)
                if newSendW <= MIN_SEND_W then
                  PerTrackFXPane_W[TrkID] = VP.w - (OPEN.Snapshots and SnapshotPane_W or 0) - MIN_SEND_W
                  local prev = PerTrackHideOvershoot[TrkID] or 0
                  local next = prev + math.max(0, delta)
                  if HIDE_DRAG_PX and HIDE_DRAG_PX > 0 then next = math.min(next, HIDE_DRAG_PX) end
                  PerTrackHideOvershoot[TrkID] = next
                else
                  local prev = PerTrackHideOvershoot[TrkID] or 0
                  local next = prev + math.min(0, delta)
                  if next <= 0 then next = nil end
                  PerTrackHideOvershoot[TrkID] = next
                end
              else
                -- Global width adjustment for non-independent tracks: queue delta for next frame to avoid flicker
                PendingGlobalDragDX = (PendingGlobalDragDX or 0) + DtX
                SeparatorDragGUID = -1 -- global
                SeparatorDragIsIndependent = false
                PerTrackWidth_DragActive = true -- mark active so highlights remain regardless of mouse
              end
            elseif Mods == Shift then
              local minFX = 100
              local maxFX = VP.w - (OPEN.Snapshots and SnapshotPane_W or 0) - 1
              local cur = PerTrackFXPane_W[TrkID] or FXPane_W
              local newW  = cur + DtX
              if newW < minFX then newW = minFX end
              if newW > maxFX then newW = maxFX end
              -- New rule: Do NOT snap during Shift-drag; apply independent width directly
              PerTrackSnappedToGlobal[TrkID] = false
              PerTrackFXPane_W[TrkID] = newW
              PerTrackWidth_DragActive = true
              PerTrackDragGUID = TrkID
              SeparatorDragGUID = TrkID
              SeparatorDragIsIndependent = true
              -- Visual cue: only for the track being dragged; if within 10px of global, draw dotted guide at global
              if PerTrackDragGUID == TrkID and SeparatorDragIsIndependent then
                local perW = PerTrackFXPane_W[TrkID] or FXPane_W
                local diff = math.abs(perW - FXPane_W)
                if diff <= 10 then
                  local dl = im.GetWindowDrawList(ctx)
                  local childLeft = (Trk and Trk[TrkID] and Trk[TrkID].FxChildLeftX) or select(1, im.GetWindowPos(ctx))
                  local childTop  = (Trk and Trk[TrkID] and Trk[TrkID].FxChildTopY)  or select(2, im.GetWindowPos(ctx))
                  local childH    = (Trk and Trk[TrkID] and Trk[TrkID].FxChildH)     or select(2, im.GetWindowSize(ctx))
                  local xGlobal = childLeft + FXPane_W
                  local y = childTop
                  local sepB = childTop + (childH or 0)
                  local clr = (Clr and Clr.PaneSeparatorGuide) or (getClr and getClr(im.Col_ButtonActive)) or 0xffffffff
                  while y < sepB do
                    local y2 = math.min(y + 3, sepB)
                    im.DrawList_AddLine(dl, xGlobal, y, xGlobal, y2, clr, 1)
                    y = y + 6
                  end
                end
              end
              -- Right-edge threshold: auto-hide Sends when too small (per-track)
              local newSendW = VP.w - (PerTrackFXPane_W[TrkID] or FXPane_W) - (OPEN.Snapshots and SnapshotPane_W or 0)
              local delta = (MIN_SEND_W - newSendW)
              if newSendW <= MIN_SEND_W then
                -- clamp at MIN_SEND_W
                PerTrackFXPane_W[TrkID] = VP.w - (OPEN.Snapshots and SnapshotPane_W or 0) - MIN_SEND_W
                -- accumulate overshoot (do not reset each frame)
                local prev = PerTrackHideOvershoot[TrkID] or 0
                local next = prev + math.max(0, delta)
                if HIDE_DRAG_PX and HIDE_DRAG_PX > 0 then next = math.min(next, HIDE_DRAG_PX) end
                PerTrackHideOvershoot[TrkID] = next
              else
                -- reduce overshoot when dragging back left
                local prev = PerTrackHideOvershoot[TrkID] or 0
                local next = prev + math.min(0, delta) -- delta negative here
                if next <= 0 then next = nil end
                PerTrackHideOvershoot[TrkID] = next
              end
            end
          end

          if im.IsItemHovered(ctx) or im.IsItemActive(ctx) then
            im.SetMouseCursor(ctx, im.MouseCursor_ResizeEW)
            Sep_Hvr = t
          end
          if Sep_Hvr and not PerTrackWidth_DragActive then
            -- Only highlight if this track's boundary state matches the hovered track's state
            local hoveredTrack = r.GetTrack(0, Sep_Hvr)
            local hoveredTrkID = hoveredTrack and r.GetTrackGUID(hoveredTrack)
            local isHoveredIndependent = hoveredTrkID and PerTrackFXPane_W[hoveredTrkID] ~= nil
            local isThisIndependent = PerTrackFXPane_W[TrkID] ~= nil
            
            if isHoveredIndependent == isThisIndependent then
              -- If hovering over an independent track, only highlight that specific track
              if isHoveredIndependent then
                if t == Sep_Hvr then
                  local sepBase = (Clr and Clr.PaneSeparator) or 0xffffffff
                  local sepHover = LightenColorU32(sepBase, 0.15)
                  HighlightSelectedItem(sepHover, sepHover, Padding, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, 'GetItemRect')
                end
              else
                -- For global tracks, highlight all global tracks
                local sepBase = (Clr and Clr.PaneSeparator) or 0xffffffff
                local sepHover = LightenColorU32(sepBase, 0.15)
                HighlightSelectedItem(sepHover, sepHover, Padding, L, T, R, B, h, w, 1, 1, 'GetItemRect')
              end
            end
          end
          -- While dragging: stabilize highlight using cached drag state (independent of mouse position)
          if PerTrackWidth_DragActive and SeparatorDragIsIndependent ~= nil then
            local isThisIndependent = PerTrackFXPane_W[TrkID] ~= nil
            if SeparatorDragIsIndependent then
              -- dragging an independent boundary: only highlight the dragged track
              if SeparatorDragGUID and SeparatorDragGUID ~= -1 then
                local trCandidate = (t >= 0) and r.GetTrack(0, t) or nil
                if trCandidate and r.GetTrackGUID(trCandidate) == SeparatorDragGUID then
                  local sepBase = (Clr and Clr.PaneSeparator) or 0xffffffff
                  local sepActive = DarkenColorU32(sepBase, 0.10)
                  HighlightSelectedItem(sepActive, sepHover, Padding, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, 'GetItemRect')
                end
              end
            else
              -- dragging a global boundary: highlight all global boundaries
               if not isThisIndependent then
                local sepBase = (Clr and Clr.PaneSeparator) or 0xffffffff
                local sepActive = DarkenColorU32(sepBase, 0.10)
                HighlightSelectedItem(nil, sepActive, Padding, L, T, R, B, h, w, H_OutlineSc, V_OutlineSc, 'GetItemRect')
              end
            end
          end
          if Sep_Hvr == t then
            if not im.IsItemHovered(ctx) then Sep_Hvr = nil end
          end
          im.SameLine(ctx, nil, 0)
        end

        if not PerTrackSendsHidden[TrkID] then
          Sends_List(ctx, t, HeightOfs, T)
        end
        im.PopStyleColor(ctx, 3)
      end


       
    end
    FOLDER = nil


    if im.IsMouseReleased(ctx,0 ) then 
      SendBtnDragTime = 0 
      DraggingRecvVol = nil 
      if PerTrackWidth_DragActive then 
        -- If last-dragged track is snapped at release, clear its individual size
        if PerTrackDragGUID then
          local isSnapped = PerTrackSnappedToGlobal[PerTrackDragGUID]
          local trkW = PerTrackFXPane_W[PerTrackDragGUID] or FXPane_W
          local diff = math.abs(trkW - FXPane_W)
          -- New rule: For Shift-drag, if released within 10px of global, clear independence
          if isSnapped or diff < 10 then
            PerTrackFXPane_W[PerTrackDragGUID] = nil
          end
        end
        -- If overshoot beyond min send width exceeded threshold, hide on release
        if PerTrackDragGUID and PerTrackHideOvershoot then
          local ov = PerTrackHideOvershoot[PerTrackDragGUID] or 0
          if ov >= (HIDE_DRAG_PX or 10) then
            PerTrackSendsHidden[PerTrackDragGUID] = true
            PerTrackSendsTween[PerTrackDragGUID] = { progress = 0, goalHidden = true }
            SavePerTrackSendsHidden()
            PerTrackHideOvershoot[PerTrackDragGUID] = nil
          elseif ov > 0 then
            -- Not enough to hide: start a fade-out of the red/X indicator
            local frac = (HIDE_DRAG_PX and HIDE_DRAG_PX > 0) and (ov / HIDE_DRAG_PX) or 0
            if frac > 0 then PerTrackHideFade[PerTrackDragGUID] = math.min(1, frac) end
            PerTrackHideOvershoot[PerTrackDragGUID] = nil
          end
        end
        -- reset snap break accumulator only on release (keep during drag)
        SnapBreakAccum = 0
        SnapDragPrevAbsDX = 0
        SnapBreakActiveGUID = nil
        SavePerTrackWidths()
        PerTrackWidth_DragActive = false
        PerTrackDragGUID = nil
        SeparatorDragGUID = nil
        SeparatorDragIsIndependent = nil
      end
    end 
    
    -- Clean up container right-click tracking when mouse button is released
    -- Clear entries that are stale (mouse released but not on release frame, so IsItemClicked already processed them)
    if not im.IsMouseDown(ctx, 1) and not im.IsMouseReleased(ctx, 1) then
      ContainerRightClickStart = {}
    end
    -- Also clean up entries that are too old (user held button down for too long)
    if ContainerRightClickStart then
      local now = r.time_precise()
      for fxID, data in pairs(ContainerRightClickStart) do
        if data.time and (now - data.time) > 1.0 then -- Clear if older than 1 second
          ContainerRightClickStart[fxID] = nil
        end
      end
    end

    PanAllActivePans(ctx,PanningTracks, t ,ACTIVE_PAN_V, PanningTracks_INV)


    im.PopStyleVar(ctx)

    im.PopStyleVar(ctx)
    PopStyle() -- Pop style editor styles
    im.PopStyleColor(ctx, PopClrTimes)
    im.PopFont(ctx)
    -- Draw marquee selection rectangle
    DrawMarqueeRect(ctx)
    -- Draw hidden parent outlines last to ensure on top
    if HiddenOutlinesToDraw and #HiddenOutlinesToDraw > 0 then
      local dlTop = im.GetForegroundDrawList(ctx)
      -- Ensure hovered priority drawn last
      table.sort(HiddenOutlinesToDraw, function(a,b)
        return (a.priority or 0) < (b.priority or 0)
      end)
      for _, rct in ipairs(HiddenOutlinesToDraw) do
        local thick = 1
        -- Draw sides and bottom (ensure fully opaque neutral if needed)
        -- Expand vertical lines by 1px outward to avoid overlap with adjacent fills
        -- Deeper level => larger indent. Compute indent so level=1 (deepest) is smallest

        local total = rct.levels or 1
        local this = rct.level or 1
        local step = 2 -- px per level
        local Pd = (this - 1) * step
        if Pd < 0 then Pd = 0 end
        local L = rct.L + 6 - Pd
        local R = rct.R - 4
        local B = rct.B - 2
        im.DrawList_AddLine(dlTop, R, rct.T, R, B, rct.col, thick)

        im.DrawList_AddLine(dlTop, L, rct.T, L, B, rct.col, thick)
        im.DrawList_AddLine(dlTop, L, B, R, B, rct.col, thick)
        -- Top line with center gap around the button text width
        local gapL, gapR
        if rct.guid then
          local tr = GetTrackByGUIDCached(rct.guid)
          if tr then
            local _, name = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
            local label = (name ~= '' and name) or 'Parent'
            -- choose the same font used for the button height
            local targetH = Folder_Btn_Compact or 12
            local fontToUse = Font_Andale_Mono_12
            if targetH <= 7 then fontToUse = Font_Andale_Mono_6
            elseif targetH <= 8 then fontToUse = Font_Andale_Mono_7
            elseif targetH <= 9 then fontToUse = Font_Andale_Mono_8
            elseif targetH <= 10 then fontToUse = Font_Andale_Mono_9
            elseif targetH <= 11 then fontToUse = Font_Andale_Mono_10
            elseif targetH <= 12 then fontToUse = Font_Andale_Mono_11
            elseif targetH <= 13 then fontToUse = Font_Andale_Mono_12
            elseif targetH <= 14 then fontToUse = Font_Andale_Mono_13
            elseif targetH <= 15 then fontToUse = Font_Andale_Mono_14
            elseif targetH <= 16 then fontToUse = Font_Andale_Mono_15
            else fontToUse = Font_Andale_Mono_16 end
            im.PushFont(ctx, fontToUse)
            local textW = im.CalcTextSize(ctx, label) or 0
            im.PopFont(ctx)
            local gapW = textW + 12 -- padding around text
            local cx = (rct.L + rct.R) * 0.5
            gapL = cx - gapW * 0.5
            gapR = cx + gapW * 0.5
          end
        end
        gapL = gapL or (rct.L + rct.R) * 0.5 - 24
        gapR = gapR or (rct.L + rct.R) * 0.5 + 24
        im.DrawList_AddLine(dlTop, L, rct.T, gapL, rct.T, rct.col, thick)
        im.DrawList_AddLine(dlTop, gapR, rct.T, R, rct.T, rct.col, thick)
        -- Do not draw new text; on-hover color is applied on the actual button via PushStyleColor
      end
      -- clear for next frame
      HiddenOutlinesToDraw = {}
    end

    im.End(ctx)
  end --end for Visible


  -- Linked Plugin parameters ---------

  rv, tracknumber, fxnumber, paramnumber = r.GetLastTouchedFX()

  -- if there's a focused fx
  if tracknumber and fxnumber  then
    local trk = r.GetTrack(0, math.max(tracknumber - 1, 0))
    if trk then 
      local FxID = r.TrackFX_GetFXGUID(trk, fxnumber)
      if FxID then 
        FX[FxID] = FX[FxID] or {}
        if FxID and FX[FxID].Link then
          Sync = FindFXFromFxGUID(FX[FxID].Link)

          local PrmV = r.TrackFX_GetParamNormalized(trk, fxnumber, paramnumber)

          if Sync then
            for i, v in ipairs(Sync.fx) do
              r.TrackFX_SetParamNormalized(Sync.trk[i], v, paramnumber, PrmV)
            end
          end
        end
      end
    end
  end

  if open then
    -- write snapshots file if something changed during this frame
    if SaveNow then
      SaveSnapshotsToFile()
      SaveNow = nil
    end
    r.defer(loop)
  else --on script close
    -- final save on shutdown
    if SaveNow then SaveSnapshotsToFile() end
    -- always persist latest snapshots on exit
    SaveSnapshotsToFile()
    im.DestroyContext(ctx)
  end
end

r.defer(loop)

-- Adjust corresponding send/return volumes on other selected tracks while user drags
-- refTrack    : the track being edited
-- sendType    : 0 for send, -1 for receive
-- idx         : send/recv slot index on refTrack
-- newVal      : new volume value to apply (linear)
function AdjustSelectedSendVolumes(refTrack, sendType, idx, newVal)
  local selCnt = r.CountSelectedTracks(0)
  if selCnt <= 1 then return end -- only reference track selected

  for s = 0, selCnt-1 do
    local selTrk = r.GetSelectedTrack(0, s)
    if selTrk and selTrk ~= refTrack then
      if sendType == 0 then -- send side; sync same slot index
        if idx < r.GetTrackNumSends(selTrk, 0) then
          r.BR_GetSetTrackSendInfo(selTrk, 0, idx, 'D_VOL', true, newVal)
        end
      else -- receive side; sync same slot index
        if idx < r.GetTrackNumSends(selTrk, -1) then
          r.BR_GetSetTrackSendInfo(selTrk, -1, idx, 'D_VOL', true, newVal)
        end
      end
    end
  end
end

-- NEW: detect if any parameter of an FX has an active envelope with points
function FX_HasAutomation(track, fx)
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt - 1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
    local env = r.GetFXEnvelope(track, fx, p, false)
      local aiCnt = r.CountAutomationItems and r.CountAutomationItems(env) or 0
      if aiCnt > 0 then return true end
    end
  end
  return false
end

-- NEW: toggle visibility of all parameter envelopes for given FX (native API)
function ToggleFXAutomationVisibility(track, fx)
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt-1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
    local env = r.GetFXEnvelope(track, fx, p, false)
      if ok then
        local newVis = (visStr == '1') and '0' or '1'
        r.GetSetEnvelopeInfo_String(env, 'VISIBLE', newVis, true)
      end
    end
  end
  r.TrackList_AdjustWindows(false)
end

-- NEW: delete all automation points (and hides envelopes) for given FX
function DeleteFXAutomation(track, fx)
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt - 1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
    local env = r.GetFXEnvelope(track, fx, p, false)
      if ultraschall and ultraschall.AutomationItem_Delete then
        local cntAI = r.CountAutomationItems(env)
        for ai = cntAI-1, 0, -1 do
          ultraschall.AutomationItem_Delete(env, ai, false) -- do not preserve points
        end
      end

      -- now remove all envelope points (underlying envelope)
      r.DeleteEnvelopePointRange(env, 0, math.huge)
      -- hide the envelope lane
      r.GetSetEnvelopeInfo_String(env, 'VISIBLE', '0', true)
      -- keep envelope well-formed
      r.GetSetEnvelopeInfo_String(env, 'ACTIVE', '0', true)
      r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', '0', true) 

      r.Envelope_SortPoints(env)
    end
  end
  r.TrackList_AdjustWindows(false)
end

-- Helpers: FX envelope state inspection/toggles
function FX_AnyEnvelopeStates(track, fx)
  local anyHasEnv, anyVisible, anyBypassed = false, false, false
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt - 1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
      anyHasEnv = true
      local _, vis = r.GetSetEnvelopeInfo_String(env, 'VISIBLE', '', false)
      local _, shw = r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', '', false)
      local _, act = r.GetSetEnvelopeInfo_String(env, 'ACTIVE', '', false)
      if vis == '1' and shw == '1' then anyVisible = true end
      if act == '0' then anyBypassed = true end
    end
  end
  return anyHasEnv, anyVisible, anyBypassed
end

function FX_ToggleAllEnvelopesVisible(track, fx)
  local _, anyVisible = FX_AnyEnvelopeStates(track, fx)
  local new = anyVisible and '0' or '1'
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt - 1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
      r.GetSetEnvelopeInfo_String(env, 'VISIBLE', new, true)
      r.GetSetEnvelopeInfo_String(env, 'SHOWLANE', new, true)
    end
  end
  r.TrackList_AdjustWindows(false)
end

function FX_ToggleAllEnvelopesActive(track, fx)
  local _, _, anyBypassed = FX_AnyEnvelopeStates(track, fx)
  local new = anyBypassed and '1' or '0'
  local paramCnt = r.TrackFX_GetNumParams(track, fx)
  for p = 0, paramCnt - 1 do
    local env = r.GetFXEnvelope(track, fx, p, false)
    if env then
      r.GetSetEnvelopeInfo_String(env, 'ACTIVE', new, true)
    end
  end
  r.TrackList_AdjustWindows(false)
end

function CopyFXAutomation(srcTrk, srcFx, dstTrk, dstFx)
  local paramCnt = r.TrackFX_GetNumParams(srcTrk, srcFx)
  for p = 0, paramCnt-1 do
    local srcEnv = r.GetFXEnvelope(srcTrk, srcFx, p, false)
    if srcEnv then
    local srcEnv = r.GetFXEnvelope(srcTrk, srcFx, p, false)
      local dstEnv = r.GetFXEnvelope(dstTrk, dstFx, p, true)
      if dstEnv then
      local dstEnv = r.GetFXEnvelope(dstTrk, dstFx, p, true)
        if rv and chunk and chunk ~= '' then
          r.SetEnvelopeStateChunk(dstEnv, chunk, false)
        end
      end
    end
  end
end

-- just before loop function definition or earlier define toggle helper if not exist

function toggle(v, val)
  if v then v = false else v = val or true end
  return v
end

-- Add constant width for Snapshots pane
SnapshotPane_W = 140  -- pixels width of the Snapshot column when visible

-- Table holding snapshots per track: Snapshots[trackGUID] = { {label=string, chunk=string}, ... }
Snapshots = {}

-- ===== Snapshot persistence =====
SaveNow = SaveNow or nil   -- global flag set when we need to write snapshots file

-- build full path to per-project snapshots file
local function GetSnapshotsFilePath()
  local projDir = r.GetProjectPath()  -- current project directory of active project
  return projDir .. '/FXD_Snapshots.lua'
end

-- turn Snapshots table into valid Lua code that returns the table when doscripted
local function SerializeSnapshots()
  local out = { 'local Snapshots = {\n' }
  for guid, list in pairs(Snapshots) do
    out[#out+1] = string.format('  [%q] = {\n', guid)
    for _, snap in ipairs(list) do
      if snap.chunk then  -- only store snapshots that actually hold data
        out[#out+1] = string.format('    {label=%q, chunk=%q},\n', snap.label or '', snap.chunk)
      end
    end
    out[#out+1] = '  },\n'
  end
  out[#out+1] = '}\nreturn Snapshots\n'
  return table.concat(out)
end

function SaveSnapshotsToFile()
  local path = GetSnapshotsFilePath()
  local f, err = io.open(path, 'w')
  if f then
    f:write(SerializeSnapshots())
    f:close()
  end
end

local function LoadSnapshotsFromFile()
  local path = GetSnapshotsFilePath()
  local f = io.open(path, 'r')
  if f then f:close() end
  if f then
    local ok, tbl = pcall(dofile, path)
    if ok and type(tbl)=='table' then
      Snapshots = tbl
    end
  end
end

-- load any previously-saved snapshots on startup
LoadSnapshotsFromFile()

function Snapshots_Pane(ctx, Track, TrkGUID, rowHeight)
  if not OPEN.Snapshots then return end
  Snapshots[TrkGUID] = Snapshots[TrkGUID] or { {label = '', chunk = nil} }
  local snaps = Snapshots[TrkGUID]

  -- ensure at least one entry exists
  if #snaps == 0 then
    snaps[1] = {label = '', chunk = nil}
  end

  -- make sure there is always one empty row at the end
  if snaps[#snaps].chunk then
    table.insert(snaps, {label = '', chunk = nil})
  end

  if im.BeginChild(ctx, 'Snapshots' .. tostring(TrkGUID), SnapshotPane_W, rowHeight, nil, im.WindowFlags_NoScrollbar + im.WindowFlags_NoScrollWithMouse) then
    im.Dummy(ctx, 0, 1) -- top margin
    for i, snap in ipairs(snaps) do
      im.PushID(ctx, i)
      -- Capture / overwrite / recall button
      if not snap.chunk then
        -- entire row acts as capture button with snapshot icon
        local rowH = 18
        if im.Button(ctx, '##caprow', SnapshotPane_W, rowH) then
          local ok, chunk = r.GetTrackStateChunk(Track, '', false)
          if ok then snap.chunk = chunk; SaveNow=true end
        end
        -- draw a thick plus sign centered instead of an image
        local L,T = im.GetItemRectMin(ctx)
        local W,H = im.GetItemRectSize(ctx)
        local cx, cy = L + W*0.5, T + H*0.5
        local sz      = math.min(W, H) * 0.35  -- half-length of plus arms
        local dl      = im.GetWindowDrawList(ctx)
        -- base tint: dim, brighten on hover, brightest when active
        local tint = 0x444444ff
        if im.IsItemActive(ctx) then
          tint = 0xffffffff
        elseif im.IsItemHovered(ctx) then
          tint = 0xccccccff
        end
        local thick = 2.0
        -- horizontal line
        im.DrawList_AddLine(dl, cx - sz, cy, cx + sz, cy, tint, thick)
        -- vertical line
        im.DrawList_AddLine(dl, cx, cy - sz, cx, cy + sz, tint, thick)
      else
        -- Capture / recall small button as camera image
        local clicked = im.ImageButton(ctx, '##cap'..tostring(i)..tostring(TrkGUID), Img.Camera, 16, 16, nil,nil,nil,nil, nil, Clr.SnapshotOverlay)
        -- Overlay brighter tint on hover/active
        local baseColor = Clr.SnapshotOverlay
        local overlayTint
        if im.IsItemActive(ctx) then
          overlayTint = (baseColor & 0x00FFFFFF) | 0xFF000000 -- fully opaque when pressed
        elseif im.IsItemHovered(ctx) then
          overlayTint = (baseColor & 0x00FFFFFF) | 0xCC000000 -- less transparent on hover
        end
        if overlayTint then
          local L,T = im.GetItemRectMin(ctx)
          local R,B = im.GetItemRectMax(ctx)
          im.DrawList_AddImage(im.GetWindowDrawList(ctx), Img.Camera, L, T, R, B, nil, nil, nil, nil, overlayTint)
        end
        if clicked then
          r.Undo_BeginBlock()
          r.SetTrackStateChunk(Track, snap.chunk, true)
          r.Undo_EndBlock('Recall Snapshot', -1)
          r.TrackList_AdjustWindows(false)
          r.UpdateArrange()
        end
        im.SameLine(ctx, nil, 2)
        local labelAreaW = SnapshotPane_W - 18
        -- label editing logic as before
        if snap.editing then
          im.SetNextItemWidth(ctx, labelAreaW)
          im.SetKeyboardFocusHere(ctx)
          WithTypingGuard(function()
            local changed, txt = im.InputText(ctx, '##lbl', snap.label or '', im.InputTextFlags_AutoSelectAll)
            if changed then snap.label = txt; SaveNow = true end
          end)
          if im.IsItemDeactivated(ctx) then snap.editing = nil end
        else
          local disp = (snap.label ~= '' and snap.label) or tostring(i)
          im.Button(ctx, disp .. '##lbl', labelAreaW, 18)
          
           
            if im.IsItemClicked(ctx) then
              if Mods == 0 then 
                r.Undo_BeginBlock()
                r.SetTrackStateChunk(Track, snap.chunk, true)
                r.Undo_EndBlock('Recall Snapshot', -1)
                r.TrackList_AdjustWindows(false)
                r.UpdateArrange()

              elseif Mods == Ctrl then
                  
                snap.editing = true 
              end
            end
            -- Alt+RMB to rename snapshot
            if im.IsItemClicked(ctx, 1) then
              if Mods == Alt then
                snap.editing = true
              end
            end

        end
      end
      im.PopID(ctx)
    end
    im.EndChild(ctx)
  end
end

-- Calculate the special index used by REAPER to refer to an FX _inside_ a container.
-- track           : MediaTrack* that owns the container
-- containerIndex  : FX index (0-based) of the container itself on that track
-- insertPosInside : 1-based position _inside the container_ where the new FX should be
--                   (1 = first,     currentCount+1 = append at end)
-- Returns the index value that can be passed to TrackFX_CopyToTrack/TrackFX_AddByName
-- See REAPER API notes: idx = 0x2000000 + subItem * (FX_Count+1) + (containerIndex+1)
function Calc_Container_FX_Index(track, containerIndex, insertPosInside)
  if not track or not containerIndex then return nil end
  local ok, cntStr = r.TrackFX_GetNamedConfigParm(track, containerIndex, 'container_count')
  local curCnt     = tonumber(cntStr) or 0
  insertPosInside  = insertPosInside or (curCnt + 1)       -- default: append
  local fxTotal    = r.TrackFX_GetCount(track)              -- FX count **before** addressing container path
  local idx = 0x2000000 + insertPosInside * (fxTotal + 1) + (containerIndex + 1)
  return idx
end

-- Marquee selection helper functions
function StartMarqueeSelection(ctx)
  -- Use the initial mouse position (where the button was first pressed) instead of current position
  -- This ensures the marquee starts exactly where the user clicked, not where the mouse is after drag threshold
  local mouseX = MarqueeSelection.initialMouseX
  local mouseY = MarqueeSelection.initialMouseY
  MarqueeSelection.isActive = true
  MarqueeSelection.startX = mouseX
  MarqueeSelection.startY = mouseY
  MarqueeSelection.endX = mouseX
  MarqueeSelection.endY = mouseY
  -- Set additive mode if Shift is held at start
  MarqueeSelection.additive = (im.GetKeyMods(ctx) & im.Mod_Shift) ~= 0
  -- Clear previous selection only if not additive
  if not MarqueeSelection.additive then
    MarqueeSelection.selectedFXs = {}
    MarqueeSelection.selectedSends = {}
    MultiSelectionButtons.visible = false
  end
  -- Determine marquee mode based on initial mouse position: inside any Sends child rect? => 'sends' else 'fx'
  MarqueeSelection.mode = 'fx'
  -- Only check SendsChildRect if sends are visible (globally and per-track)
  local sendsVisible = OPEN and OPEN.ShowSends ~= false
  if sendsVisible and Trk then
    local mx, my = mouseX, mouseY
    for trGUID, tr in pairs(Trk) do
      -- Skip if sends are hidden for this specific track
      if not (PerTrackSendsHidden and PerTrackSendsHidden[trGUID]) then
        if tr and tr.SendsChildRect then
          local rct = tr.SendsChildRect
          if mx >= rct.L and mx <= rct.R and my >= rct.T and my <= rct.B then
            MarqueeSelection.mode = 'sends'
            break
          end
        end
      end
    end
  end
end

function UpdateMarqueeSelection(ctx)
  if not MarqueeSelection.isActive then return end
  
  local mouseX, mouseY = im.GetMousePos(ctx)
  MarqueeSelection.endX = mouseX
  MarqueeSelection.endY = mouseY
  -- Re-evaluate marquee mode dynamically based on current mouse position
  -- Only check SendsChildRect if sends are visible (globally and per-track)
  local sendsVisible = OPEN and OPEN.ShowSends ~= false
  if sendsVisible and Trk then
    local mx, my = mouseX, mouseY
    local inSends = false
    for trGUID, tr in pairs(Trk) do
      -- Skip if sends are hidden for this specific track
      if not (PerTrackSendsHidden and PerTrackSendsHidden[trGUID]) then
        if tr and tr.SendsChildRect then
          local rct = tr.SendsChildRect
          if mx >= rct.L and mx <= rct.R and my >= rct.T and my <= rct.B then
            inSends = true
            break
          end
        end
      end
    end
    MarqueeSelection.mode = inSends and 'sends' or 'fx'
  else
    -- If sends are hidden globally, force FX mode
    MarqueeSelection.mode = 'fx'
  end
end

function EndMarqueeSelection(ctx)
  if not MarqueeSelection.isActive then return end
  
  MarqueeSelection.isActive = false
  MarqueeSelection.additive = false
  -- Reset drag detection variables
  MarqueeSelection.hasDragged = false
  MarqueeSelection.initialMouseX = 0
  MarqueeSelection.initialMouseY = 0
  MarqueeSelection.startingOnVolDrag = false
  -- Update multi-selection button visibility
  local hasSelection = false
  if MarqueeSelection.mode == 'fx' then
    for trackGUID, fxIndices in pairs(MarqueeSelection.selectedFXs) do
      if #fxIndices > 0 then hasSelection = true break end
    end
  else
    for trackGUID, sendEntries in pairs(MarqueeSelection.selectedSends or {}) do
      if type(sendEntries) == 'table' and #sendEntries > 0 then hasSelection = true break end
    end
  end
  MultiSelectionButtons.visible = hasSelection
end

function IsPointInMarquee(x, y)
  if not MarqueeSelection.isActive then return false end
  
  local minX = math.min(MarqueeSelection.startX, MarqueeSelection.endX)
  local maxX = math.max(MarqueeSelection.startX, MarqueeSelection.endX)
  local minY = math.min(MarqueeSelection.startY, MarqueeSelection.endY)
  local maxY = math.max(MarqueeSelection.startY, MarqueeSelection.endY)
  
  -- Ensure minimum marquee size to allow selection even with minimal drag
  local minSize = 5 -- Minimum 5 pixels in each direction
  if maxX - minX < minSize then
    local centerX = (minX + maxX) / 2
    minX = centerX - minSize / 2
    maxX = centerX + minSize / 2
  end
  if maxY - minY < minSize then
    local centerY = (minY + maxY) / 2
    minY = centerY - minSize / 2
    maxY = centerY + minSize / 2
  end
  
  return x >= minX and x <= maxX and y >= minY and y <= maxY
end

function IsRectIntersectingMarquee(rectMinX, rectMinY, rectMaxX, rectMaxY)
  if not MarqueeSelection.isActive then return false end
  
  local marqueeMinX = math.min(MarqueeSelection.startX, MarqueeSelection.endX)
  local marqueeMaxX = math.max(MarqueeSelection.startX, MarqueeSelection.endX)
  local marqueeMinY = math.min(MarqueeSelection.startY, MarqueeSelection.endY)
  local marqueeMaxY = math.max(MarqueeSelection.startY, MarqueeSelection.endY)
  
  -- Ensure minimum marquee size to allow selection even with minimal drag
  local minSize = 5 -- Minimum 5 pixels in each direction
  if marqueeMaxX - marqueeMinX < minSize then
    local centerX = (marqueeMinX + marqueeMaxX) / 2
    marqueeMinX = centerX - minSize / 2
    marqueeMaxX = centerX + minSize / 2
  end
  if marqueeMaxY - marqueeMinY < minSize then
    local centerY = (marqueeMinY + marqueeMaxY) / 2
    marqueeMinY = centerY - minSize / 2
    marqueeMaxY = centerY + minSize / 2
  end
  
  -- Check if rectangles intersect
  return not (rectMaxX < marqueeMinX or rectMinX > marqueeMaxX or 
              rectMaxY < marqueeMinY or rectMinY > marqueeMaxY)
end

function AddFXToSelection(trackGUID, fxIndex)
  if not MarqueeSelection.selectedFXs[trackGUID] then
    MarqueeSelection.selectedFXs[trackGUID] = {}
  end
  
  -- Convert index to GUID for stable selection across moves
  local track = GetTrackByGUIDCached(trackGUID)
  if not track then return end
  local guid = r.TrackFX_GetFXGUID(track, fxIndex)
  if not guid then return end
  -- Check if already selected
  for i, g in ipairs(MarqueeSelection.selectedFXs[trackGUID]) do
    if g == guid then return end
  end
  table.insert(MarqueeSelection.selectedFXs[trackGUID], guid)
end

function RemoveFXFromSelection(trackGUID, fxIndex)
  if not MarqueeSelection.selectedFXs[trackGUID] then return end
  
  local track = GetTrackByGUIDCached(trackGUID)
  if not track then return end
  local guid = r.TrackFX_GetFXGUID(track, fxIndex)
  if not guid then return end
  for i, g in ipairs(MarqueeSelection.selectedFXs[trackGUID]) do
    if g == guid then table.remove(MarqueeSelection.selectedFXs[trackGUID], i) break end
  end
end

function ShouldSelectFXByYPosition(fxMinY, fxMaxY)
  if not MarqueeSelection.isActive then return false end
  
  local startY = MarqueeSelection.startY
  local currentY = MarqueeSelection.endY
  
  -- Check if button's Y range overlaps with marquee's Y range (touching counts)
  local marqueeMinY = math.min(startY, currentY)
  local marqueeMaxY = math.max(startY, currentY)
  
  -- Ensure minimum marquee size to allow selection even with minimal drag
  local minSize = 5
  if marqueeMaxY - marqueeMinY < minSize then
    local centerY = (marqueeMinY + marqueeMaxY) / 2
    marqueeMinY = centerY - minSize / 2
    marqueeMaxY = centerY + minSize / 2
  end
  
  -- Check if Y ranges overlap (button touches marquee)
  return not (fxMaxY < marqueeMinY or fxMinY > marqueeMaxY)
end

function IsFXSelected(trackGUID, fxIndex)
  if not MarqueeSelection.selectedFXs[trackGUID] then return false end
  local track = GetTrackByGUIDCached(trackGUID)
  if not track then return false end
  local guid = r.TrackFX_GetFXGUID(track, fxIndex)
  if not guid then return false end
  for i, g in ipairs(MarqueeSelection.selectedFXs[trackGUID]) do
    if g == guid then return true end
  end
  return false
end

function ClearSelection()
  MarqueeSelection.selectedFXs = {}
  MarqueeSelection.selectedSends = {}
  MultiSelectionButtons.visible = false
end

function DrawMarqueeRect(ctx)
  if not MarqueeSelection.isActive then return end
  
  local drawList = im.GetForegroundDrawList(ctx)
  local minX = math.min(MarqueeSelection.startX, MarqueeSelection.endX)
  local maxX = math.max(MarqueeSelection.startX, MarqueeSelection.endX)
  local minY = math.min(MarqueeSelection.startY, MarqueeSelection.endY)
  local maxY = math.max(MarqueeSelection.startY, MarqueeSelection.endY)
  
  -- Apply minimum size logic (same as IsPointInMarquee)
  local minSize = 5 -- Minimum 5 pixels in each direction
  if maxX - minX < minSize then
    local centerX = (minX + maxX) / 2
    minX = centerX - minSize / 2
    maxX = centerX + minSize / 2
  end
  if maxY - minY < minSize then
    local centerY = (minY + maxY) / 2
    minY = centerY - minSize / 2
    maxY = centerY + minSize / 2
  end
  
  -- Draw marquee rectangle with dotted border
  local col = (MarqueeSelection.mode == 'sends') and 0xffffffff or ((Clr and Clr.SendsPreview) or 0xffffffff)
  DrawDottedRect(drawList, minX, minY, maxX, maxY, col, 4, 2)
end

function ToggleBypassFX(Track, fx)
  if r.TrackFX_GetEnabled(Track, fx) then
    r.TrackFX_SetEnabled(Track, fx, false)
  else
    r.TrackFX_SetEnabled(Track, fx, true)
  end
end

local function FindFXIndexByGUID(track, fxGUID)
  if not track or not fxGUID then return -1 end
  local cnt = r.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    if r.TrackFX_GetFXGUID(track, i) == fxGUID then return i end
  end
  return -1
end

function BypassSelectedFXs()
  r.PreventUIRefresh(1)  -- Prevent intermediate UI updates to ensure single undo step
  r.Undo_BeginBlock()
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    local track = GetTrackByGUIDCached(trackGUID)
    if track then
      -- Toggle bypass for the entire block consistently: if majority are enabled, bypass all; otherwise enable all
      local enabledCt, total = 0, 0
      for _, g in ipairs(fxGUIDs) do
        local idx = FindFXIndexByGUID(track, g)
        if idx >= 0 then total = total + 1 if r.TrackFX_GetEnabled(track, idx) then enabledCt = enabledCt + 1 end end
      end
      local targetEnable = enabledCt < (total - enabledCt) -- if fewer enabled, enable all; else bypass all
      for _, g in ipairs(fxGUIDs) do
        local idx = FindFXIndexByGUID(track, g)
        if idx >= 0 then r.TrackFX_SetEnabled(track, idx, targetEnable) end
      end
    end
  end
  r.Undo_EndBlock('Bypass selected FXs', -1)
  r.PreventUIRefresh(-1)  -- Re-enable UI updates
end

function AddFX_HideWindow(track, fx_name, position)
  local val = r.SNM_GetIntConfigVar("fxfloat_focus", 0)
  if val & 4 == 0 then
    local id = r.TrackFX_AddByName(track, fx_name, false, position)
    return id
  else
    r.SNM_SetIntConfigVar("fxfloat_focus", val & (~4))  -- temporarily disable Auto-float newly created FX windows
    local id = r.TrackFX_AddByName(track, fx_name, false, position)
    r.SNM_SetIntConfigVar("fxfloat_focus", val | 4)     -- re-enable Auto-float
    return id
  end
end

function PutSelectedFXsInContainer()
  r.PreventUIRefresh(1)  -- Prevent intermediate UI updates to ensure single undo step
  r.Undo_BeginBlock()
  -- For each track with a selection, wrap the contiguous selection block into a new Reaper FX Container
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    local track = GetTrackByGUIDCached(trackGUID)
    if track and fxGUIDs and #fxGUIDs > 0 then
      -- Build list of selected FX with their original indices, then sort ascending
      local selected = {}
      local cnt = r.TrackFX_GetCount(track)
      for i = 0, cnt - 1 do
        local g = r.TrackFX_GetFXGUID(track, i)
        for _, sg in ipairs(fxGUIDs) do
          if sg == g then
            selected[#selected + 1] = { idx = i, guid = g }
            break
          end
        end
      end
      table.sort(selected, function(a, b) return a.idx < b.idx end)
      if #selected == 0 then goto continue end

      -- Create an empty container at the position of the first selected FX
      local insertPos = selected[1].idx
      local contIdx = AddFX_HideWindow(track, 'Container', -1000 - insertPos)
      if not contIdx or contIdx < 0 then goto continue end

      -- Move each selected FX (by GUID) into the container, appending inside
      for _, entry in ipairs(selected) do
        local cur = FindFXIndexByGUID(track, entry.guid)
        if cur and cur >= 0 then
          local into = Calc_Container_FX_Index(track, contIdx)
          if into then
            r.TrackFX_CopyToTrack(track, cur, track, into, true)
          end
        end
      end
    end
    ::continue::
  end
  r.Undo_EndBlock('Put selected FXs in Container', -1)
  r.PreventUIRefresh(-1)  -- Re-enable UI updates
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
end
function LoudnessMatchSelectedFXs()
  r.PreventUIRefresh(1)  -- Prevent intermediate UI updates to ensure single undo step
  r.Undo_BeginBlock()
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    local track = GetTrackByGUIDCached(trackGUID)
    if track and type(fxGUIDs) == 'table' and #fxGUIDs > 0 then
      local idxs = {}
      local cnt = r.TrackFX_GetCount(track)
      for i = 0, cnt - 1 do
        local g = r.TrackFX_GetFXGUID(track, i)
        for _, sg in ipairs(fxGUIDs) do if sg == g then idxs[#idxs+1] = i break end end
      end
      table.sort(idxs)
      local contiguous = #idxs > 0
      for i = 2, #idxs do if idxs[i] ~= idxs[i-1] + 1 then contiguous = false break end end
      if contiguous then
        local first = idxs[1]
        local last = idxs[#idxs]
        local function addAndMove(trackRef, names, targetPos)
          -- Add at end, then move into place to be robust across REAPER versions
          local addedIdx = -1
          for _, name in ipairs(names) do
            addedIdx = AddFX_HideWindow(trackRef, name, -1)
            if addedIdx >= 0 then break end
          end
          if addedIdx and addedIdx >= 0 then
            r.TrackFX_CopyToTrack(trackRef, addedIdx, trackRef, targetPos, true)
            return targetPos
          end
          return -1
        end
        local sourceNames = { 'JS: AB Level Matching Source JSFX V3.1e', 'AB Level Matching Source JSFX V3.1e' }
        local controlNames = { 'JS: AB Level Matching Control JSFX V3.1e', 'AB Level Matching Control JSFX V3.1e' }

        -- Insert source before the block and control after the block
        local srcIdx = addAndMove(track, sourceNames, first)
        -- After inserting source before first, indices at/after first shift by +1; adjust last accordingly
        local ctrlIdx = addAndMove(track, controlNames, last + 2)

        -- Compute LinkID for this new pair by scanning all tracks for existing pairs
        local function isNameLike(trackRef, fxIdx, needle)
          local _, nm = r.TrackFX_GetFXName(trackRef, fxIdx)
          return (nm or ''):lower():find(needle, 1, true) ~= nil
        end
        local maxLink = -1
        local proj = 0
        local trCnt = r.CountTracks(proj)
        for ti = 0, trCnt - 1 do
          local tr = r.GetTrack(proj, ti)
          local c = r.TrackFX_GetCount(tr)
          for fi = 0, c - 1 do
            if isNameLike(tr, fi, 'ab level matching') then
              -- heuristic: read param index for LinkID. Try 0..4 to find an integer-like value in [0, 64]
              local candidate = -1
              for pi = 0, 8 do
                local _, pName = r.TrackFX_GetParamName(tr, fi, pi)
                if pName and pName:lower():find('link', 1, true) then
                  candidate = pi; break
                end
              end
              if candidate < 0 then candidate = 0 end
              local val = r.TrackFX_GetParamNormalized(tr, fi, candidate) or 0
              local approx = math.floor(val * 64 + 0.5)
              if approx > maxLink then maxLink = approx end
            end
          end
        end
        local newLink = maxLink + 1
        -- Set LinkID param for both newly inserted FX if we can find a Link parameter
        local function setLinkParam(trackRef, fxIdx)
          if not fxIdx or fxIdx < 0 then return end
          local candidate = -1
          for pi = 0, 8 do
            local _, pName = r.TrackFX_GetParamName(trackRef, fxIdx, pi)
            if pName and pName:lower():find('link', 1, true) then candidate = pi; break end
          end
          if candidate >= 0 then
            local norm = newLink / 64
            if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
            r.TrackFX_SetParamNormalized(trackRef, fxIdx, candidate, norm)
          end
        end
        setLinkParam(track, srcIdx)
        setLinkParam(track, ctrlIdx)
      end
    end
  end
  r.Undo_EndBlock('Loudness Match (insert Source and Control JSFX)', -1)
  r.PreventUIRefresh(-1)  -- Re-enable UI updates
  r.UpdateArrange()  -- Update arrange view after all operations
end

-- Legacy top buttons removed

-- Removed selection index refresh used by multi-move

function SyncWetDryValues(sourceTrack, sourceFX, newValue, paramIdent)
  -- Sync wet/dry values across all selected FXs (selection stored as GUIDs)
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    local track = GetTrackByGUIDCached(trackGUID)
    if track then
      for _, g in ipairs(fxGUIDs) do
        local fxIndex = FindFXIndexByGUID(track, g)
        if fxIndex >= 0 and not (track == sourceTrack and fxIndex == sourceFX) then
          local paramNum = r.TrackFX_GetParamFromIdent(track, fxIndex, paramIdent)
          if paramNum >= 0 then
            r.TrackFX_SetParamNormalized(track, fxIndex, paramNum, newValue)
          end
        end
      end
    end
  end
end

function SyncWetDryValuesRelative(sourceTrack, sourceFX, delta, paramIdent)
  -- Apply a relative delta to wet/dry across all selected FXs (skip the source)
  for trackGUID, fxGUIDs in pairs(MarqueeSelection.selectedFXs) do
    local track = GetTrackByGUIDCached(trackGUID)
    if track then
      for _, g in ipairs(fxGUIDs) do
        local fxIndex = FindFXIndexByGUID(track, g)
        if fxIndex >= 0 and not (track == sourceTrack and fxIndex == sourceFX) then
          local paramNum = r.TrackFX_GetParamFromIdent(track, fxIndex, paramIdent)
          if paramNum >= 0 then
            local cur = r.TrackFX_GetParamNormalized(track, fxIndex, paramNum)
            local out = cur + delta
            if out < 0 then out = 0 end
            if out > 1 then out = 1 end
            r.TrackFX_SetParamNormalized(track, fxIndex, paramNum, out)
          end
        end
      end
    end
  end
end

-- Multi-selection drag disabled; fallback to single-item drag only

-- Multi-selection move syncing removed to mirror FX Devices behavior